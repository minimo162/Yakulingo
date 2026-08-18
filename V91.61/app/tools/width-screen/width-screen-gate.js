'use strict';
/*
  幅を知って最初から訳す。本物の cat.html / cat.js を headless Chromium で開き、
  translate() / translateRow() が実際に POST する body の fit_targets を見る
  運転席（tools/fit-screen/fit-screen-gate.js と同じ形。判定は呼び出し側の
  PowerShell が行う。ここでやることは3つだけ）:
    1. 本物の cat.html / cat.js / cat-workspace.css / styles.css / common.js を、
       その場のローカル HTTP で配る
    2. /api/cat/glossary はプロジェクトをそのまま返す（用語集の適用は
       この機能の対象外）。/api/cat/translate は来た body をそのまま記録し、
       ジョブが即終わったことにする stub を返す
    3. 実際に「Copilotで未訳を翻訳」・「この行だけ訳す」を押し、飛んだ
       要求の中身を JSON で書き出す

  使い方:
    node width-screen-gate.js <wwwDir> <payloadJsonPath> <outJsonPath>

  payloadJson は { main: <project>, empty: <project> } の形。
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const payloadJsonPath = process.argv[3];
const outputPath = process.argv[4];

const payloadJson = fs.readFileSync(payloadJsonPath, 'utf8');
const payload = JSON.parse(payloadJson);
const mainProject = payload.main;
const emptyProject = payload.empty;
const mainProjectJson = JSON.stringify(mainProject);
const emptyProjectJson = emptyProject ? JSON.stringify(emptyProject) : '';

const types = {
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8'
};

const translateCalls = [];

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
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'width-test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
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
  if (p === '/api/cat/resume') {
    const wanted = parsed ? String(parsed.project_id || '') : '';
    if (emptyProject && wanted === String(emptyProject.id || '')) { res.end(emptyProjectJson); return; }
    res.end(mainProjectJson);
    return;
  }
  if (p === '/api/cat/glossary') {
    // 用語集の適用はこの機能の対象外。渡されたプロジェクトをそのまま返す。
    const wanted = parsed ? String(parsed.id || '') : '';
    if (emptyProject && wanted === String(emptyProject.id || '')) { res.end(emptyProjectJson); return; }
    res.end(mainProjectJson);
    return;
  }
  if (p === '/api/cat/translate') {
    translateCalls.push(parsed);
    res.end('<div data-yaku-job-id="width-job-' + translateCalls.length + '"></div>');
    return;
  }
  if (p.indexOf('/api/jobs/') === 0) {
    // すぐ終わったことにする。fit_targets の中身以外は見ない。
    res.end(JSON.stringify({ mode: 'cancelled' }));
    return;
  }
  res.end('{}');
});

/* cat.js の previewOutputAvgCharPx / segmentSourceFitTarget と同じ式を、
   呼び出さず・覗かずに独立して求める（V9187/V9196 と同じ oracle の作法）。
   ここで使う代表文字列とフォントは cat.js 側のものと一致させる必要がある
   （実装を変えたら、ここも合わせて直す）。 */
async function computeOracle(page, displayWidthPx) {
  return await page.evaluate(function (args) {
    var ctx = document.createElement('canvas').getContext('2d');
    ctx.font = '14.7px "Arial", Calibri, Arial, sans-serif';
    var sample = 'The quick brown fox jumps over the lazy dog 0123456789';
    var avgCharPx = ctx.measureText(sample).width / sample.length;
    var raw = Math.floor((args.displayWidthPx - 8) / avgCharPx);
    return { avgCharPx: avgCharPx, raw: raw, inRange: raw >= 8 && raw <= 99 };
  }, { displayWidthPx: displayWidthPx });
}

(async function () {
  const out = { errors: [], console: [], translateCalls: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(mainProject.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });

    // 独立計算した期待値。列幅 px は previewColumnPx と同じ式
    // （max(24, round(width*7+5)) の列ごとの和）で、フィクスチャの列定義から
    // 手で計算した値（below-min: A(2)単独=24。measured: D(15)+E(50)=110+355=
    // 465。above-max: H(90)+I(50)+J(50)=635+355+355=1345。right-align:
    // T(90)単独=635。U(50)を足したら990になり、寄せで足さないことの反証にもなる）。
    out.oracleBelowMin = await computeOracle(page, 24);
    out.oracleMeasured = await computeOracle(page, 465);
    out.oracleAboveMax = await computeOracle(page, 1345);
    out.oracleRightAlignOwnOnly = await computeOracle(page, 635);
    out.oracleRightAlignWithSpillWouldBe = await computeOracle(page, 990);

    // -------------------------------------------------------------- 一括翻訳
    await page.waitForFunction(function () { var b = document.getElementById('cat-translate'); return b && !b.disabled; }, { timeout: 10000 });
    await page.click('#cat-translate');
    const deadline1 = Date.now() + 10000;
    while (translateCalls.length < 1 && Date.now() < deadline1) { await page.waitForTimeout(50); }
    out.bulkBody = translateCalls[0] || null;

    // ---------------------------------------------------------- この行だけ訳す
    // index=1（measured。単独では翻訳対象。訳が空なので data-cat-translate-row
    // のボタンが出る）を1行だけ訳す経路で確かめる。選択行の操作パネルは
    // 選んだ行にしか出ないので、先に該当行の訳文欄へフォーカスする
    // （tools/fit-screen/fit-screen-gate.js の1クリック導線チェックと同じ形）。
    await page.focus('#cat-grid-body tr[data-cat-row="1"] textarea[data-cat-input]');
    await page.waitForTimeout(200);
    const rowButton = await page.$('[data-cat-translate-row="1"]');
    if (rowButton) {
      await rowButton.click();
      const deadline2 = Date.now() + 10000;
      while (translateCalls.length < 2 && Date.now() < deadline2) { await page.waitForTimeout(50); }
      out.rowBody = translateCalls[1] || null;
    } else {
      out.rowButtonMissing = true;
    }

    // --------------------------------------------------- 目標が1件も出せない資料
    if (emptyProject) {
      await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(emptyProject.id), { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
      await page.waitForFunction(function () { var b = document.getElementById('cat-translate'); return b && !b.disabled; }, { timeout: 10000 });
      await page.click('#cat-translate');
      const deadline3 = Date.now() + 10000;
      while (translateCalls.length < 3 && Date.now() < deadline3) { await page.waitForTimeout(50); }
      out.emptyBody = translateCalls[2] || null;
    }

    out.translateCalls = translateCalls;
  } catch (error) {
    out.fatal = String((error && error.stack) || error);
  } finally {
    if (browser) await browser.close().catch(function () {});
    await new Promise(function (resolve) { server.close(resolve); });
    fs.writeFileSync(outputPath, JSON.stringify(out, null, 1), 'utf8');
  }
  if (out.errors.length || out.console.length || out.fatal) process.exitCode = 1;
})();
