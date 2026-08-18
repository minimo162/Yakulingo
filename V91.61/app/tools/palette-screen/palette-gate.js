'use strict';
/*
  お手軽翻訳(/palette)を、本物のChromiumで開いて確かめる。

  cat-screen-gate.js と同じ考え方（本物のhtml/js/cssをローカルHTTPで配り、
  /api/* は決め打ちの応答で記録し、実際に押す・打つ）。ここでは題材を
  palette 一本に絞り、cat-screen-gate.js を肥大化させない。

  判定はしない。判定は呼び出し側の PowerShell が行う（観察と判定を分ける、
  既存の流儀）。ここは観察した結果をJSONで書き出すだけ。

  使い方: node palette-gate.js <wwwDir> <outJson>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const outPath = process.argv[3];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

const JOB_ID = 'deadbeef00000000000000000000001';
// 「画面に見えている訳文」と「マスク後の現訳」をわざと別の文字列にする。
// チップ(丁寧に/短く)が current_text にどちらを送るかを、文字列の一致で
// そのまま検出するため（マスクを外して送れば MASKED と一致しなくなる）。
const MASKED_TRANSLATION = 'Revenue was [[N1]] million yen.';
const DISPLAY_TRANSLATION = 'Revenue was 1,234 million yen.';
const ALT_TRANSLATION = 'Sales reached 1,234 million yen.';
const SOURCE_TEXT = 'Revenue source text';

function b64(text) { return Buffer.from(text, 'utf8').toString('base64'); }

const doneHtml =
  "<div class='batch-note masking-note'>数値 1 件をマスクして送信しました。符号と単位は送信しています。</div>" +
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>" + DISPLAY_TRANSLATION + "</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64(DISPLAY_TRANSLATION) + "'>コピー</button></div>" +
  "</article>" +
  "<div class='result-alts'><p class='result-alts-lead'>枠に入らないときは、こちらを押すと上と入れ替わります。</p>" +
  "<div class='result-alts-list'>" +
  "<button type='button' class='result-alt' data-yaku-swap='" + b64(ALT_TRANSLATION) + "' data-yaku-swap-kind='電文体'>" +
  "<span class='result-alt-head'>電文体<span class='result-alt-chars'>" + ALT_TRANSLATION.length + " 字</span></span>" +
  "<span class='result-alt-body'>" + ALT_TRANSLATION + "</span></button></div></div>" +
  "</section>";

let pollCount = 0;
const chipRequests = [];
const translateRequests = [];

const server = http.createServer(function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/palette' || url.pathname === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'palette.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'palette-test-token')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); return;
  }
  if (url.pathname.startsWith('/assets/')) {
    const asset = path.join(wwwDir, url.pathname.replace(/^\//, ''));
    if (fs.existsSync(asset)) { res.writeHead(200, { 'Content-Type': MIME[path.extname(asset)] || 'application/octet-stream' }); res.end(fs.readFileSync(asset)); return; }
    res.writeHead(404); res.end('not found'); return;
  }
  let body = '';
  req.on('data', function (chunk) { body += chunk; });
  req.on('end', function () {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    if (url.pathname === '/api/ready-state') { res.end(JSON.stringify({ canTranslate: true, label: '準備完了', class: 'ok' })); return; }
    if (url.pathname === '/api/palette/instant') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      const text = String(payload.text || '');
      if (text.indexOf('TMHIT') >= 0) {
        res.end(JSON.stringify({ direction: 'to_en', tm: { source: text, target: 'TM exact translation.', exact: true }, terms: [{ source: '御社', target: 'your company' }] }));
      } else {
        res.end(JSON.stringify({ direction: 'to_en', tm: null, terms: [] }));
      }
      return;
    }
    if (url.pathname === '/api/palette/translate') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      translateRequests.push(payload);
      res.end(JSON.stringify({ job_id: JOB_ID }));
      return;
    }
    if (url.pathname === '/api/palette/chip') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      chipRequests.push(payload);
      res.end(JSON.stringify({ job_id: JOB_ID }));
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_ID) {
      pollCount++;
      if (pollCount < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: doneHtml,
        source_text: SOURCE_TEXT, masked_translation: MASKED_TRANSLATION, direction: 'to_en', style: 'full'
      }));
      return;
    }
    res.end('{}');
  });
});

(async function () {
  const out = { errors: [], console: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 480, height: 640 } });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    // OSクリップボードを介さない。headlessでは許可が絡んで不安定になるため、
    // navigator.clipboard.writeText を差し替えて呼び出しをそのまま記録する。
    await page.addInitScript(function () {
      window.__yakuCopied = [];
      Object.defineProperty(navigator, 'clipboard', {
        value: { writeText: function (text) { window.__yakuCopied.push(text); return Promise.resolve(); } },
        configurable: true
      });
    });
    await page.goto('http://127.0.0.1:' + server.address().port + '/palette', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#palette-input');

    // 貼り付け(paste)を模す。palette.js は 'paste' イベントではなく
    // inputType='insertFromPaste' の input イベントで見分けているので、
    // それを直接送る（headlessでOSクリップボード権限に依存しない）。
    await page.evaluate(function () {
      var target = document.getElementById('palette-input');
      target.focus();
      target.value = 'TMHIT 御社の今期の売上高は増加しました。';
      target.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', bubbles: true }));
    });
    await page.waitForTimeout(80);

    out.activeIsInputAfterPaste = await page.evaluate(function () {
      return !!(document.activeElement && document.activeElement.id === 'palette-input');
    });

    await page.waitForSelector('#palette-instant:not([hidden])', { timeout: 5000 });
    out.instantHtml = await page.$eval('#palette-instant', function (node) { return node.innerHTML; });

    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    out.resultHtml = await page.$eval('#palette-result', function (node) { return node.innerHTML; });
    out.candidateIndexes = await page.$$eval('[data-yaku-candidate-index]', function (nodes) {
      return nodes.map(function (node) { return node.getAttribute('data-yaku-candidate-index'); });
    });
    out.chipsHidden = await page.$eval('#palette-chips', function (node) { return node.hidden; });
    out.shortenChipHidden = await page.$eval('[data-yaku-chip="shorten"]', function (node) { return node.hidden; });

    // 1キー: 先頭候補(TM完全一致)をコピー。
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterDigitOne = await page.evaluate(function () { return window.__yakuCopied.slice(); });

    // Enter: 既定候補(先頭=TM)をコピー。
    await page.keyboard.press('Enter');
    await page.waitForTimeout(120);
    out.copiedAfterEnter = await page.evaluate(function () { return window.__yakuCopied.slice(); });

    // 3キー: Copilotの添え(alt, TM=1 main=2 alt=3)をコピー。
    await page.keyboard.press('3');
    await page.waitForTimeout(120);
    out.copiedAfterDigitThree = await page.evaluate(function () { return window.__yakuCopied.slice(); });

    // チップ「丁寧に」。current_text が masked_translation と一致することを見る
    // (画面の表示文字列=DISPLAY_TRANSLATIONを送っていたら不一致になる)。
    await page.click('[data-yaku-chip="revise"]');
    await page.waitForTimeout(400);
    out.chipRequests = chipRequests.slice();

    // Esc: 入力と結果をクリア。
    await page.evaluate(function () { document.getElementById('palette-input').focus(); });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(100);
    out.inputValueAfterEscape = await page.$eval('#palette-input', function (node) { return node.value; });
    out.resultHtmlAfterEscape = await page.$eval('#palette-result', function (node) { return node.innerHTML; });
    out.chipsHiddenAfterEscape = await page.$eval('#palette-chips', function (node) { return node.hidden; });
    out.candidateCountAfterEscape = (await page.$$('[data-yaku-candidate-index]')).length;
  } catch (error) {
    out.errors.push(String((error && error.stack) || error));
  } finally {
    try { if (browser) await browser.close(); } catch (closeError) {}
    try { server.close(); } catch (closeError) {}
  }
  fs.writeFileSync(outPath, JSON.stringify(out), 'utf8');
})();
