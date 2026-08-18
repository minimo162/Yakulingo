'use strict';
/*
  収まりの見える化を、本物の cat.html / cat.js を headless Chromium で開いて
  確かめる運転席（tools/cat-screen/cat-screen-gate.js の --width-preview と
  同じ形。既存の総合門は肥大化させず、専用の小ドライバとして新設する）。

  判定はしない。判定は呼び出し側の PowerShell が行う（ps1 judges / JS driver
  observes の decisions）。ここでやることは3つだけ:
    1. 本物の cat.html / cat.js / cat-workspace.css / styles.css / common.js /
       quick.js を、その場のローカル HTTP で配る
    2. /api/* は決め打ちの応答を返し、来た要求（本文）を記録する
    3. 実際に開く・押す。出た DOM と、飛んだ要求の中身を JSON で書き出す

  使い方:
    node fit-screen-gate.js <wwwDir> <projectJsonPath> <outJsonPath>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const projectJsonPath = process.argv[3];
const outputPath = process.argv[4];
const projectJson = fs.readFileSync(projectJsonPath, 'utf8');
const project = JSON.parse(projectJson);

const types = {
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8'
};

const publicationCalls = [];

function readBody(req) {
  return new Promise(function (resolve) {
    let data = '';
    req.on('data', function (c) { data += c; });
    req.on('end', function () { resolve(data); });
  });
}

const server = http.createServer(async function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  const p = url.pathname;
  if (p === '/cat' || p === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'fit-test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
      /* previewOutputFont() の配線先。実測値の再現（下の canvas 計測）と
         同じ書体にする。 */
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS Pゴシック');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
    return;
  }
  if (p.startsWith('/assets/')) {
    const file = path.join(wwwDir, p.replace(/^\//, ''));
    if (fs.existsSync(file)) {
      res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
      res.end(fs.readFileSync(file));
      return;
    }
    res.writeHead(404); res.end('not found'); return;
  }
  const body = await readBody(req);
  let parsed = null;
  try { parsed = body ? JSON.parse(body) : null; } catch (_) { parsed = null; }
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (p === '/api/ready-state') { res.end(JSON.stringify({ canTranslate: true, label: 'ready', class: 'ok' })); return; }
  if (p === '/api/cat/recent') { res.end(JSON.stringify({ projects: [] })); return; }
  if (p === '/api/cat/resume') { res.end(projectJson); return; }
  if (p === '/api/cat/publication-candidates') {
    publicationCalls.push(parsed);
    res.end(JSON.stringify({ job_id: 'fit-job-' + publicationCalls.length }));
    return;
  }
  if (p.indexOf('/api/jobs/') === 0) {
    /* 正確さの検証は候補の中身までは要らない（見るのは max_chars の配線）。
       候補0件でも「収まりません」の状態行が出るだけで、押した事実は残る。 */
    res.end(JSON.stringify({ mode: 'done', application_status: 'current', candidate_set: { candidate_set_id: 'cs-1', dependency_fingerprint: 'fp-1', candidates: [] } }));
    return;
  }
  res.end('{}');
});

function fitSegments() {
  return (project.segments || []).filter(function (s) { return s.kind === 'cell'; });
}

(async function () {
  const out = { errors: [], console: [], publicationCalls: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(project.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });

    // ---------------------------------------------------- プレビューの印（自動spill）
    await page.click('#cat-preview-open');
    await page.waitForSelector('#cat-preview-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(250);
    out.previewCells = await page.evaluate(function () {
      return Array.from(document.querySelectorAll('#cat-preview-body .cat-preview-cell')).map(function (cell) {
        return {
          index: Number(cell.getAttribute('data-cat-preview-index')),
          overflowRisk: cell.classList.contains('is-overflow-risk'),
          ariaLabel: cell.getAttribute('aria-label') || '',
          title: cell.getAttribute('title') || ''
        };
      });
    });

    // ------------------------------------------------- 文字目標（実測 vs フォールバック）
    /* 実測できる行（index=8）。previewSide=target が既定なので、配置つきの
       セルは data-cat-placement-edit を持つ。押すと配置ダイアログが直接開く。 */
    async function runPublicationFromPreviewCell(index) {
      await page.click('#cat-preview-body .cat-preview-cell[data-cat-preview-index="' + index + '"]');
      await page.waitForSelector('#cat-placement-dialog[open]', { timeout: 10000 });
      await page.click('#cat-publication-open');
      await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
      const before = publicationCalls.length;
      await page.click('#cat-publication-generate');
      // publicationCalls はNode側配列。ブラウザ側からは見えないので、要求が
      // サーバへ届くまで素直に待つ（ポーリング）。
      const deadline = Date.now() + 10000;
      while (publicationCalls.length <= before && Date.now() < deadline) { await page.waitForTimeout(50); }
      const note = await page.evaluate(function () { var n = document.getElementById('cat-publication-maxchars-note'); return n ? n.textContent : ''; });
      await page.evaluate(function () {
        document.getElementById('cat-publication-dialog').close();
        document.getElementById('cat-placement-dialog').close();
      });
      return { requestBody: publicationCalls[publicationCalls.length - 1] || null, note: note };
    }
    const measuredIndex = 8, fallbackIndex = 9;
    out.measured = await runPublicationFromPreviewCell(measuredIndex);
    out.fallback = await runPublicationFromPreviewCell(fallbackIndex);

    /* 実測の期待値を、cat.js の実装と同じ式で独立に出す（呼び出さない・覗かない）。
       previewOutputFont() は「"Arial", Calibri, Arial, sans-serif」を組む
       （direction=to_en・設定値=Arial のとき）。列幅の式（幅*7+5、24px下限）は
       仕様として固定されているので、ここでは自分で組む値ではなく、テスト側が
       用意した既知の列幅（narrow=1, wide=50, 個数）から出す。 */
    const measuredSegment = (project.segments || []).find(function (s) { return Number(s.index) === measuredIndex; });
    const measuredText = String((measuredSegment && measuredSegment.translation) || '');
    const oracle = await page.evaluate(function (text) {
      var c = document.createElement('canvas');
      var ctx = c.getContext('2d');
      ctx.font = '14.7px "Arial", Calibri, Arial, sans-serif';
      var textWidth = ctx.measureText(text).width;
      // narrow(=1) 1列 + wide(=50) 2列。previewColumnPx と同じ式（幅*7+5、Math.max(24,round)）。
      var narrow = Math.max(24, Math.round(1 * 7 + 5));
      var wide = Math.max(24, Math.round(50 * 7 + 5));
      var displayWidth = narrow + wide + wide;
      var expected = Math.max(20, Math.floor(text.length * Math.max(0, displayWidth - 8) / textWidth));
      return { textWidth: textWidth, displayWidth: displayWidth, expectedMaxChars: expected };
    }, measuredText);
    out.measuredOracle = oracle;
    const fallbackSegment = (project.segments || []).find(function (s) { return Number(s.index) === fallbackIndex; });
    const fallbackText = String((fallbackSegment && fallbackSegment.translation) || '');
    out.fallbackExpected = Math.max(20, Math.floor(fallbackText.length * 0.8));

    await page.evaluate(function () { document.getElementById('cat-preview-dialog').close(); });

    // -------------------------------------------------------------- 絞り込み
    out.fitFilterBefore = await page.evaluate(function () {
      var button = document.querySelector('[data-cat-filter="fit"]');
      var count = document.querySelector('[data-cat-count="fit"]');
      return { hidden: !button || button.hidden, visible: !!(button && button.getClientRects().length > 0), count: count ? count.textContent : '' };
    });
    await page.evaluate(function () { var b = document.querySelector('[data-cat-filter="fit"]'); if (b) b.hidden = false; });
    await page.click('[data-cat-filter="fit"]');
    await page.waitForTimeout(250);
    out.fitFilterAfter = await page.evaluate(function () {
      var button = document.querySelector('[data-cat-filter="fit"]');
      return {
        pressed: button ? button.getAttribute('aria-pressed') : '',
        rows: Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) { return Number(tr.getAttribute('data-cat-row')); })
      };
    });
    await page.click('[data-cat-filter="all"]');
    await page.waitForTimeout(200);

    // -------------------------------------------------------------- 行の1クリック導線
    /* index=7 の行（scenario "row-action"）を選び、選択行リボンにボタンが
       出るか・押すと配置ダイアログ＋公開候補の両方が開くかを見る。 */
    await page.focus('#cat-grid-body tr[data-cat-row="7"] textarea[data-cat-input]');
    await page.waitForTimeout(200);
    out.rowActionButton = await page.evaluate(function () {
      var button = document.querySelector('[data-cat-fit-candidates="7"]');
      return { exists: !!button, visible: !!(button && button.getClientRects().length > 0) };
    });
    await page.click('[data-cat-fit-candidates="7"]');
    await page.waitForSelector('#cat-placement-dialog[open]', { timeout: 10000 });
    await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
    out.rowActionOpened = await page.evaluate(function () {
      return {
        placementOpen: !!document.getElementById('cat-placement-dialog').open,
        publicationOpen: !!document.getElementById('cat-publication-dialog').open,
        placementIndex: document.getElementById('cat-placement-index').value
      };
    });
    await page.evaluate(function () {
      document.getElementById('cat-publication-dialog').close();
      document.getElementById('cat-placement-dialog').close();
    });

    out.publicationCalls = publicationCalls;
  } catch (error) {
    out.fatal = String((error && error.stack) || error);
  } finally {
    if (browser) await browser.close().catch(function () {});
    await new Promise(function (resolve) { server.close(resolve); });
    fs.writeFileSync(outputPath, JSON.stringify(out, null, 1), 'utf8');
  }
  if (out.errors.length || out.console.length || out.fatal) process.exitCode = 1;
})();
