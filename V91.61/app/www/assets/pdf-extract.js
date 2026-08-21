// PDF からテキストを取り出す共通部品。
//
// PDF取り込みで共通に使うため、ブラウザ側の部品として独立させている。
// 写すと、段組みの判定のような測って決めた実装が2つに分かれて必ず食い違う。
//
// 動かすには CSP に 'wasm-unsafe-eval' が要る。取り込みで開いた画面
//（?import=1）だけがそれを受け取る。
import init, { LiteParse } from '/assets/vendor/liteparse/liteparse_wasm.js';
export { LiteParse };

let wasmReady = null;

async function reportEnvironment() {
  const csp = await fetch(location.pathname + location.search, { method: 'GET' })
    .then(function (r) { return r.headers.get('content-security-policy') || '(なし)'; })
    .catch(function () { return '(取得できず)'; });
  const build = (document.querySelector('meta[name="yaku-build"]') || {}).content || '(不明)';
  return { csp: csp, build: build, wasmOk: /wasm-unsafe-eval/.test(csp) };
}

export function ensureWasm() {
  // 初期化は実測 369ms。押されるまで走らせない（起動を遅くしないため）。
  //
  // .wasm を自分で取得してバイト列で渡す。init() に任せると取得と
  // コンパイルのどちらで失敗したか分からず、原因の切り分けができない。
  if (!wasmReady) {
    wasmReady = (async function () {
      const url = '/assets/vendor/liteparse/liteparse_wasm_bg.wasm';
      let res;
      try { res = await fetch(url); }
      catch (e) { throw new Error('WASM を取得できません: ' + url + ' (' + e.message + ')'); }
      if (!res.ok) throw new Error('WASM を取得できません: ' + url + ' (HTTP ' + res.status + ')');
      const buf = await res.arrayBuffer();
      if (buf.byteLength < 1000000) throw new Error('WASM のサイズが不正です: ' + buf.byteLength + ' bytes');
      try {
        await init({ module_or_path: buf });
      } catch (e) {
        // CSP に 'wasm-unsafe-eval' が無いとここで落ちる。原因を名指しする。
        const msg = (e && e.message) ? e.message : String(e);
        if (/unsafe-eval|Content Security Policy/i.test(msg)) {
          // この画面が実際に受け取った CSP を添える。推測せずに切り分けられるようにする。
          const env = await reportEnvironment();
          throw new Error(
            'WebAssembly がブラウザの制限で実行できません。\n' +
            'この画面が受け取った CSP: ' + env.csp + '\n' +
            'アプリの版: ' + env.build + '\n' +
            (env.wasmOk
              ? 'CSP には wasm-unsafe-eval が入っています。ブラウザが対応していない可能性があります（Edge 97 以降が必要）。'
              : 'CSP に wasm-unsafe-eval がありません。古い版が動いているか、以前に開いた画面が残っています。'
                + ' Ctrl+Shift+R で再読み込みするか、アプリを再起動してください。') +
            '\n(' + msg + ')');
        }
        throw new Error('WASM を初期化できません: ' + msg);
      }
    })();
    // 失敗を握りつぶすと次回も同じ Promise を返してしまう。捨てて作り直せるようにする。
    wasmReady.catch(function () { wasmReady = null; });
  }
  return wasmReady;
}

function yakuGroupTextItemsByY(items, lineHeight) {
  const tolerance = Math.max(3, lineHeight * 0.65);
  const sorted = items.slice().sort(function (a, b) {
    return (Number(a.y) || 0) - (Number(b.y) || 0);
  });
  const rows = [];
  for (const item of sorted) {
    const y = Number(item.y) || 0;
    let row = rows.length ? rows[rows.length - 1] : null;
    if (!row || Math.abs(y - row.y) > tolerance) {
      row = { index: rows.length, y: y, items: [], anchorIds: [] };
      rows.push(row);
    }
    row.items.push(item);
    row.y = ((row.y * (row.items.length - 1)) + y) / row.items.length;
  }
  return rows;
}

function yakuLooksNumericCell(value) {
  const text = String(value || '').trim();
  if (!/[0-9０-９]/.test(text)) return false;
  const digits = (text.match(/[0-9０-９]/g) || []).length;
  const letters = (text.match(/[A-Za-zぁ-んァ-ヶ一-鿿]/g) || []).length;
  // A numeric cell may carry a short unit (for example 百万円), but a sentence
  // containing a date must not turn an ordinary prose row into a table.
  return letters === 0 || digits >= letters;
}

function yakuTableRows(items, fallback, lineHeight) {
  const rows = yakuGroupTextItemsByY(items, lineHeight);
  if (rows.length < 3) return null;

  // Cluster left edges with a small coordinate tolerance.  A cluster must occur
  // on several different visual rows; one long heading at the page margin is
  // therefore not enough to create a table column.
  const xTolerance = Math.max(4, Math.min(8, lineHeight * 0.8));
  const anchors = [];
  for (const row of rows) {
    row.anchorIds = [];
    for (const item of row.items) {
      const x = Number(item.x) || 0;
      let best = -1;
      let bestDistance = Infinity;
      for (let i = 0; i < anchors.length; i++) {
        const distance = Math.abs(x - anchors[i].x);
        if (distance <= xTolerance && distance < bestDistance) {
          best = i;
          bestDistance = distance;
        }
      }
      if (best < 0) {
        best = anchors.length;
        anchors.push({ x: x, sum: x, observations: 1, rows: new Set() });
      } else {
        anchors[best].sum += x;
        anchors[best].observations++;
      }
      anchors[best].rows.add(row.index);
      // Keep the observed edge stable when a PDF has small per-row jitter.
      anchors[best].x = anchors[best].sum / anchors[best].observations;
      row.anchorIds.push(best);
    }
  }

  const repeatedIds = new Set();
  for (let i = 0; i < anchors.length; i++) {
    if (anchors[i].rows.size >= 3) repeatedIds.add(i);
  }
  if (repeatedIds.size < 3) return null;

  function repeatedAnchorIds(row) {
    return Array.from(new Set(row.anchorIds.filter(function (id) { return repeatedIds.has(id); })));
  }

  // At least three repeated body rows, each with two numeric cells, keeps
  // ordinary two-column prose and date-heavy paragraphs out of this path.
  const bodyRows = rows.filter(function (row) {
    return repeatedAnchorIds(row).length >= 3 &&
      row.items.filter(function (item) { return yakuLooksNumericCell(item.text); }).length >= 2;
  });
  if (bodyRows.length < 3) return null;

  // Use the observed body spacing rather than a fixed page-coordinate cutoff.
  // The lower median is stable when one or more gaps are outliers; a ratio
  // guard catches a detached region while the line-height guard tolerates the
  // roughly 51px body spacing in the real fixture despite 9px text height.
  const bodyGaps = [];
  for (let i = 1; i < bodyRows.length; i++) {
    const gap = bodyRows[i].y - bodyRows[i - 1].y;
    if (gap > 0) bodyGaps.push(gap);
  }
  if (bodyGaps.length) {
    const sortedGaps = bodyGaps.slice().sort(function (a, b) { return a - b; });
    const lowerMedian = sortedGaps[Math.floor((sortedGaps.length - 1) / 2)];
    const maximumContinuousGap = Math.max(lineHeight * 8, lowerMedian * 3);
    if (bodyGaps.some(function (gap) { return gap > maximumContinuousGap; })) return fallback;
  }

  // Do not bridge two independent numeric table bodies.  If the first and
  // last body rows are separated by ordinary page content, tableStart..tableEnd
  // would otherwise make that content look like row-major table text.
  let bodyRegions = 0;
  let previousBodyRow = null;
  for (const row of bodyRows) {
    let separatedByNonTable = false;
    if (previousBodyRow && row.index > previousBodyRow.index + 1) {
      const between = rows.slice(previousBodyRow.index + 1, row.index);
      separatedByNonTable = between.some(function (middleRow) { return repeatedAnchorIds(middleRow).length < 3; });
    }
    if (!previousBodyRow || separatedByNonTable) bodyRegions++;
    previousBodyRow = row;
  }
  if (bodyRegions > 1) return fallback;

  // The same three (or more) anchors must survive every body row.  This is the
  // high-precision part: repeated x positions in unrelated page regions do not
  // get stitched into one table merely because they are individually common.
  const commonBodyAnchors = repeatedAnchorIds(bodyRows[0]).filter(function (id) {
    return bodyRows.every(function (row) { return repeatedAnchorIds(row).indexOf(id) >= 0; });
  });
  if (commonBodyAnchors.length < 3) return null;

  // A short row immediately after the last numeric body, aligned to the final
  // table column, is usually a wrapped continuation.  It cannot safely become
  // a new logical line; fail closed only for a tight gap so the real footer
  // roughly 66px below the body remains ordinary page text.  LiteParse may
  // split one visual continuation into several text items on the same y row.
  const finalBodyAnchorId = commonBodyAnchors.reduce(function (best, id) {
    return anchors[id].x > anchors[best].x ? id : best;
  }, commonBodyAnchors[0]);
  const finalBodyX = anchors[finalBodyAnchorId].x;
  const immediatePostBody = rows.filter(function (row) { return row.index === bodyRows[bodyRows.length - 1].index + 1; })[0];
  if (immediatePostBody && repeatedAnchorIds(immediatePostBody).length < 3) {
    const continuationGap = immediatePostBody.y - bodyRows[bodyRows.length - 1].y;
    const firstContinuationItem = immediatePostBody.items.slice().sort(function (a, b) {
      return (Number(a.x) || 0) - (Number(b.x) || 0);
    })[0];
    const firstContinuationX = firstContinuationItem ? Number(firstContinuationItem.x) : NaN;
    const alignedToFinalColumn = isFinite(firstContinuationX) && Math.abs(firstContinuationX - finalBodyX) <= xTolerance;
    if (continuationGap > 0 && continuationGap <= lineHeight * 3 && alignedToFinalColumn) return fallback;
  }

  const geometryRows = rows.filter(function (row) { return repeatedAnchorIds(row).length >= 3; });
  const firstBody = bodyRows[0].index;
  const lastBody = bodyRows[bodyRows.length - 1].index;
  let tableStart = firstBody;
  let tableEnd = lastBody;
  // Include a compact header immediately above and a non-numeric table row
  // immediately below the numeric body, but never reach unrelated page prose.
  while (tableStart > 0 && tableStart > firstBody - 2 && geometryRows.some(function (row) { return row.index === tableStart - 1; })) tableStart--;
  while (tableEnd + 1 < rows.length && tableEnd < lastBody + 2 && geometryRows.some(function (row) { return row.index === tableEnd + 1; })) tableEnd++;

  // A table may be surrounded by a title, period, and footer (one item per
  // row), but repeated two-column prose must keep the existing column-major
  // reconstruction.  Returning null here safely hands the whole page back to
  // that path instead of interleaving prose rows around the detected table.
  const outsideRows = rows.filter(function (row) { return row.index < tableStart || row.index > tableEnd; });
  const outsideAnchors = [];
  const outsideAnchorRows = [];
  for (const row of outsideRows) {
    const ids = [];
    for (const item of row.items) {
      const x = Number(item.x) || 0;
      let best = -1;
      let bestDistance = Infinity;
      for (let i = 0; i < outsideAnchors.length; i++) {
        const distance = Math.abs(x - outsideAnchors[i].x);
        if (distance <= xTolerance && distance < bestDistance) {
          best = i;
          bestDistance = distance;
        }
      }
      if (best < 0) {
        best = outsideAnchors.length;
        outsideAnchors.push({ x: x, sum: x, observations: 1, rows: new Set() });
      } else {
        outsideAnchors[best].sum += x;
        outsideAnchors[best].observations++;
      }
      outsideAnchors[best].rows.add(row.index);
      outsideAnchors[best].x = outsideAnchors[best].sum / outsideAnchors[best].observations;
      ids.push(best);
    }
    outsideAnchorRows.push({ row: row, ids: Array.from(new Set(ids)) });
  }
  const repeatedOutsideIds = new Set();
  for (let i = 0; i < outsideAnchors.length; i++) {
    if (outsideAnchors[i].rows.size >= 2) repeatedOutsideIds.add(i);
  }
  const outsideMultiColumnRows = outsideAnchorRows.filter(function (entry) {
    return entry.ids.filter(function (id) { return repeatedOutsideIds.has(id); }).length >= 2;
  });
  if (outsideMultiColumnRows.length >= 2) {
    for (let i = 0; i < outsideMultiColumnRows.length - 1; i++) {
      for (let j = i + 1; j < outsideMultiColumnRows.length; j++) {
        const commonOutsideAnchors = outsideMultiColumnRows[i].ids.filter(function (id) {
          return repeatedOutsideIds.has(id) && outsideMultiColumnRows[j].ids.indexOf(id) >= 0;
        });
        if (commonOutsideAnchors.length >= 2) return null;
      }
    }
  }

  function renderRow(row, useCellGaps) {
    if (!useCellGaps) {
      return row.items.slice().sort(function (a, b) {
        return (Number(a.x) || 0) - (Number(b.x) || 0);
      }).map(function (item) { return String(item.text).trim(); }).join(' ');
    }
    const cells = [];
    for (let i = 0; i < row.items.length; i++) {
      const item = row.items[i];
      const anchorId = row.anchorIds[i];
      let cell = cells.filter(function (candidate) { return candidate.anchorId === anchorId; })[0];
      if (!cell) {
        cell = { anchorId: anchorId, x: Number(item.x) || 0, texts: [] };
        cells.push(cell);
      }
      cell.x = Math.min(cell.x, Number(item.x) || 0);
      cell.texts.push(String(item.text).trim());
    }
    cells.sort(function (a, b) { return a.x - b.x; });
    return cells.map(function (cell) { return cell.texts.join(' '); }).join('  ');
  }

  const out = [];
  for (const row of rows) {
    const inTable = row.index >= tableStart && row.index <= tableEnd && repeatedAnchorIds(row).length >= 3;
    const line = renderRow(row, inTable).trim();
    if (line) out.push(line);
  }
  const text = out.join('\n');
  // Keep the existing character-yield guard: if reconstruction loses too much
  // text, the safer result is LiteParse's original page text.
  if (text.replace(/\s/g, '').length < fallback.replace(/\s/g, '').length * 0.8) return null;
  return text;
}

export function yakuPageTextByColumns(page) {
  const items = (page.textItems || []).filter(function (t) { return t && t.text && t.text.trim(); });
  const fallback = page.text || page.markdown || '';
  if (items.length < 8) return fallback;
  let minX = Infinity, maxX = -Infinity, hSum = 0;
  for (const t of items) {
    const x = Number(t.x) || 0, w = Number(t.width) || 0;
    if (x < minX) minX = x;
    if (x + w > maxX) maxX = x + w;
    hSum += Number(t.height) || 0;
  }
  const width = maxX - minX;
  if (!isFinite(width) || width <= 0) return fallback;
  const lineHeight = (hSum / items.length) || 10;

  const tableText = yakuTableRows(items, fallback, lineHeight);
  if (tableText !== null) return tableText;

  // x 方向を細かい升目に落とし、何個の文字片が載っているかを数える。
  const BINS = 240;
  const occ = new Array(BINS).fill(0);
  for (const t of items) {
    const x = Number(t.x) || 0, w = Number(t.width) || 0;
    let a = Math.floor((x - minX) / width * BINS);
    let b = Math.ceil((x + w - minX) / width * BINS);
    if (a < 0) a = 0;
    if (b > BINS - 1) b = BINS - 1;
    for (let i = a; i <= b; i++) occ[i]++;
  }
  // 段をまたぐ見出しが1本あるだけで谷が埋まる。完全な空白ではなく
  // 「ほとんど載っていない」を谷とみなす。
  const peak = Math.max.apply(null, occ);
  const floorLevel = Math.max(1, Math.floor(peak * 0.04));
  const minGap = Math.max(4, Math.round(BINS * 0.022));

  const bands = [];
  let start = null;
  for (let i = 0; i < BINS; i++) {
    if (occ[i] > floorLevel) {
      if (start === null) start = i;
      continue;
    }
    let j = i;
    while (j < BINS && occ[j] <= floorLevel) j++;
    if (start !== null && (j - i) >= minGap) { bands.push([start, i - 1]); start = null; }
    i = j - 1;
  }
  if (start !== null) bands.push([start, BINS - 1]);

  // 1段なら今までと同じ。刻まれすぎたときは表の可能性が高いので触らない。
  if (bands.length < 2 || bands.length > 5) return fallback;

  const edges = bands.map(function (b) {
    return { lo: minX + (b[0] / BINS) * width, hi: minX + ((b[1] + 1) / BINS) * width, items: [] };
  });
  for (const t of items) {
    const cx = (Number(t.x) || 0) + (Number(t.width) || 0) / 2;
    let band = edges[0];
    for (const e of edges) { if (cx >= e.lo && cx <= e.hi) { band = e; break; } }
    band.items.push(t);
  }

  // 表と段組みを見分ける。
  //
  // 行の揃い方では見分けられない。段組みの本文も左右の行は同じ高さに並ぶ
  // （2026-08-07 に一度これで誤り、統合報告書まで表と判定した）。
  // 見分けるのは中身のほうである。
  //   表      セルが短い。「現金及び預金」「1,001,379」
  //   段組み  1行が文の一部で長い
  // 表を段として割ると科目と金額が別の行になり、行が意味を失う。
  // 決算短信は大半が表なので、誤ると既に取れていたものを壊す。
  const cellLens = [];
  let numericCells = 0;
  for (const e of edges) {
    const rows = new Map();
    for (const t of e.items) {
      const key = Math.round((Number(t.y) || 0) / Math.max(1, lineHeight * 0.6));
      rows.set(key, (rows.get(key) || '') + String(t.text).trim());
    }
    for (const v of rows.values()) {
      cellLens.push(v.length);
      if (v.length && !/[ぁ-んァ-ヶ一-鿿A-Za-z]{3}/.test(v)) numericCells++;
    }
  }
  if (!cellLens.length) return fallback;
  cellLens.sort(function (a, b) { return a - b; });
  const median = cellLens[Math.floor(cellLens.length / 2)];
  // セルが短い、または数字だけの升目が多いページは表とみなして触らない。
  if (median < 12 || numericCells / cellLens.length > 0.35) return fallback;
  const out = [];
  for (const e of edges) {
    if (!e.items.length) continue;
    e.items.sort(function (a, b) {
      const dy = (Number(a.y) || 0) - (Number(b.y) || 0);
      if (Math.abs(dy) > lineHeight * 0.6) return dy;
      return (Number(a.x) || 0) - (Number(b.x) || 0);
    });
    let line = [], lastY = null;
    for (const t of e.items) {
      const y = Number(t.y) || 0;
      if (lastY !== null && Math.abs(y - lastY) > lineHeight * 0.6) { out.push(line.join(' ')); line = []; }
      line.push(String(t.text).trim());
      lastY = y;
    }
    if (line.length) out.push(line.join(' '));
  }
  const text = out.join('\n');
  // 取れ高が明らかに減ったときは信用しない。元の取り出しへ戻す。
  if (text.replace(/\s/g, '').length < fallback.replace(/\s/g, '').length * 0.8) return fallback;
  return text;
}

/* PDF のバイト列から、ページごとのテキストを取り出す。
   返すのは { pages: [{ page, text }], lowText } だけ。画像は返さない。
   lowText は「半数以上のページで文字がほとんど取れない」＝スキャンPDFの目印で、
   PowerShell 側の低抽出判定と同じ考え方（閾値200字）。 */
export async function extractPdfPages(bytes) {
  await ensureWasm();
  const lp = new LiteParse({ outputFormat: 'json', ocrEnabled: false, quiet: true });
  const parsed = await lp.parse(bytes);
  const pages = (parsed.pages || []).map(function (p, i) {
    return { page: i + 1, text: yakuPageTextByColumns(p) };
  });
  const low = pages.filter(function (p) { return String(p.text || '').length < 200; }).length;
  return { pages: pages, lowText: pages.length > 0 && low * 2 > pages.length };
}
