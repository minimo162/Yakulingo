// 生成済み確認PDFを、ブラウザ内の専用PDF.js workerで文字抽出する。
// PDFそのものも抽出本文もCopilotへ送らない。結果は同じ端末のローカルserverへ戻し、
// serverがrender hash・project fingerprintを再検証してからcoverageへ投影する。
import * as pdfjsLib from '/assets/vendor/pdfjs/pdf.min.mjs';

pdfjsLib.GlobalWorkerOptions.workerSrc = '/assets/vendor/pdfjs/pdf.worker.min.mjs';
const BUNDLED_PDFJS_VERSION = '5.7.284';

function viewportTextBbox(tx, itemWidth) {
  const originX = Number(tx[4]) || 0;
  const originY = Number(tx[5]) || 0;
  const axisLength = Math.hypot(Number(tx[0]) || 0, Number(tx[1]) || 0);
  const width = Math.max(0, Number(itemWidth) || 0);
  const widthX = axisLength > 0 ? ((Number(tx[0]) || 0) / axisLength) * width : width;
  const widthY = axisLength > 0 ? ((Number(tx[1]) || 0) / axisLength) * width : 0;
  const heightX = Number(tx[2]) || 0;
  const heightY = Number(tx[3]) || 0;
  const corners = [
    [originX, originY],
    [originX + widthX, originY + widthY],
    [originX + heightX, originY + heightY],
    [originX + widthX + heightX, originY + widthY + heightY]
  ];
  const xs = corners.map(function (point) { return point[0]; });
  const ys = corners.map(function (point) { return point[1]; });
  const minX = Math.min.apply(null, xs);
  const minY = Math.min.apply(null, ys);
  return { x: minX, y: minY, w: Math.max.apply(null, xs) - minX, h: Math.max.apply(null, ys) - minY };
}

export async function extractReviewPdfPages(bytes, options) {
  const input = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
  const maxBytes = Number((options || {}).maxBytes || 80 * 1024 * 1024);
  const maxPages = Number((options || {}).maxPages || 1000);
  if (!input.byteLength || input.byteLength > maxBytes) throw new Error('PDFの大きさが確認上限を超えています。');
  const extractorVersion = String(pdfjsLib.version || 'unknown');
  if (extractorVersion !== BUNDLED_PDFJS_VERSION) throw new Error('PDF文字抽出モジュールの版が一致しません。再読み込みしてください。');
  const task = pdfjsLib.getDocument({ data: input, isEvalSupported: false, disableFontFace: true, useWorkerFetch: false });
  let doc = null;
  try {
    doc = await task.promise;
    if (doc.numPages < 1 || doc.numPages > maxPages) throw new Error('PDFのページ数が確認上限を超えています。');
    const pages = [];
    for (let pageNumber = 1; pageNumber <= doc.numPages; pageNumber++) {
      const page = await doc.getPage(pageNumber);
      const content = await page.getTextContent({ disableNormalization: false });
      const viewport = page.getViewport({ scale: 1 });
      const items = (content.items || []).map(function (item) {
        const str = String(item && item.str || '');
        const tx = pdfjsLib.Util.transform(viewport.transform, item.transform || [1, 0, 0, 1, 0, 0]);
        const box = viewportTextBbox(tx, item.width);
        return { text: str, bbox: { space: 'viewport_points', x: box.x, y: box.y, w: box.w, h: box.h, page_width: viewport.width, page_height: viewport.height, rotation: viewport.rotation, crop_box: Array.from(page.view || []) } };
      });
      const text = items.map(function (item) { return item.text; }).join(' ');
      pages.push({ page: pageNumber, text: text, page_box: { width: viewport.width, height: viewport.height, rotation: viewport.rotation, crop_box: Array.from(page.view || []) }, items: items });
      if (typeof page.cleanup === 'function') page.cleanup();
    }
    return { extractor_contract: 'pdfjs-text-v2@' + extractorVersion, page_count: doc.numPages, pages: pages };
  } finally {
    try { if (doc) await doc.destroy(); else await task.destroy(); } catch (_) {}
  }
}
