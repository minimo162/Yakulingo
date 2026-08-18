'use strict';
/*
  お手軽翻訳(/palette)を、本物のChromiumで開いて確かめる。

  cat-screen-gate.js と同じ考え方（本物のhtml/js/cssをローカルHTTPで配り、
  /api/* は決め打ちの応答で記録し、実際に押す・打つ）。ここでは題材を
  palette 一本に絞り、cat-screen-gate.js を肥大化させない。

  判定はしない。判定は呼び出し側の PowerShell が行う（観察と判定を分ける、
  既存の流儀）。ここは観察した結果をJSONで書き出すだけ。

  レビュー1周目からの追加分:
    - 「短く」チップは無い（BLOCKER-1）。DOMに存在しないことを見る。
    - 方向確認（MAJOR-2）: 曖昧な原文は /api/palette/translate が409を
      返す決め打ちにしておき、確認ボタンが出ること・Enterでそのボタンが
      押されること（数字/Enterへ奪われないこと=NIT-10）を見る。
    - 添え札(alt)クリックは主札と入れ替わる（MINOR-5）。数字キーでの
      コピーは変えない。
    - beforeunload はジョブ実行中だけ有効（MINOR-6）。実ナビゲーションを
      伴わず、合成イベントの defaultPrevented で見る。
    - 480x640・1912x987 の両方で、結果カードの矩形が窓の中に収まること
      （MAJOR-4）。scrollIntoView を無効化すると赤くなることを、
      呼び出し側のPowerShellが「壊して赤・戻して緑」で確認する。

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
const CONFIRM_JOB_ID = 'cccccccc00000000000000000000002';
// 「画面に見えている訳文」と「マスク後の現訳」をわざと別の文字列にする。
// チップ(丁寧に)が current_text にどちらを送るかを、文字列の一致で
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

const confirmDoneHtml =
  "<div class='batch-note masking-note'>数値 0 件をマスクして送信しました。符号と単位は送信しています。</div>" +
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>Confirmed direction translation.</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64('Confirmed direction translation.') + "'>コピー</button></div>" +
  "</article></section>";

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
    if (url.pathname === '/api/ready-state') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ canTranslate: true, label: '準備完了', class: 'ok' })); return;
    }
    if (url.pathname === '/api/palette/instant') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      const text = String(payload.text || '');
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
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
      const text = String(payload.text || '');
      const intent = String(payload.direction_intent || 'auto');
      // MAJOR-2: 曖昧な原文(このドライバでは AMBIGUOUSXY と決め打ち)は、
      // 明示方向が来るまで409で止める。palette.js 側の確認UIと、
      // Enterがその確認ボタンを押す(NIT-10)ことを見るための仕掛け。
      if (text.indexOf('AMBIGUOUSXY') >= 0 && intent === 'auto') {
        res.writeHead(409, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ code: 'DIRECTION_CONFIRMATION_REQUIRED', error: '翻訳先を選んでください。', suggested_direction: 'to_en', confidence: 'low' }));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (text.indexOf('AMBIGUOUSXY') >= 0) { res.end(JSON.stringify({ job_id: CONFIRM_JOB_ID })); return; }
      res.end(JSON.stringify({ job_id: JOB_ID }));
      return;
    }
    if (url.pathname === '/api/palette/chip') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      chipRequests.push(payload);
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ job_id: JOB_ID }));
      return;
    }
    if (url.pathname === '/api/jobs/' + CONFIRM_JOB_ID) {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ mode: 'done', progress: 100, label: 'Done', class: 'ok', html: confirmDoneHtml, source_text: 'AMBIGUOUSXY text', masked_translation: 'Confirmed direction translation.', direction: 'to_en', style: 'full' }));
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_ID) {
      pollCount++;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (pollCount < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: doneHtml,
        source_text: SOURCE_TEXT, masked_translation: MASKED_TRANSLATION, direction: 'to_en', style: 'full'
      }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end('{}');
  });
});

function measureGeometry(page) {
  return page.evaluate(function () {
    var innerWidth = window.innerWidth;
    var innerHeight = window.innerHeight;
    var main = document.querySelector('#palette-result [data-yaku-main-card]');
    var hint = document.querySelector('.palette-hint');
    var mainRect = main ? main.getBoundingClientRect() : null;
    var hintRect = hint ? hint.getBoundingClientRect() : null;
    return {
      innerWidth: innerWidth,
      innerHeight: innerHeight,
      main: mainRect ? { top: mainRect.top, bottom: mainRect.bottom, left: mainRect.left, right: mainRect.right } : null,
      hint: hintRect ? { top: hintRect.top, bottom: hintRect.bottom } : null
    };
  });
}

(async function () {
  const out = { errors: [], console: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 480, height: 640 } });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    // MAJOR-2 の題材(AMBIGUOUSXY)はわざと409を1回起こす。Chromiumはfetchの
    // 非2xxを「Failed to load resource: ... 409」としてconsoleへ流すので、
    // それだけは既知・意図した1件として除く（他のconsole.errorはそのまま拾う）。
    page.on('console', function (message) {
      if (message.type() !== 'error') return;
      var text = message.text();
      if (/Failed to load resource:.*409/.test(text)) return;
      out.console.push(text);
    });
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

    // BLOCKER-1: 「短く」チップはDOMに無い。
    out.shortenChipCount = (await page.$$('[data-yaku-chip="shorten"]')).length;

    // 貼り付け(paste)を模す。palette.js は 'paste' イベントではなく
    // inputType='insertFromPaste' の input イベントで見分けているので、
    // それを直接送る（headlessでOSクリップボード権限に依存しない）。
    async function pasteText(text) {
      await page.evaluate(function (value) {
        var target = document.getElementById('palette-input');
        target.focus();
        target.value = value;
        target.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', bubbles: true }));
      }, text);
    }

    async function dispatchBeforeUnloadProbe() {
      return page.evaluate(function () {
        var event = new Event('beforeunload', { cancelable: true });
        window.dispatchEvent(event);
        return event.defaultPrevented;
      });
    }

    await pasteText('TMHIT 御社の今期の売上高は増加しました。');
    await page.waitForTimeout(80);

    out.activeIsInputAfterPaste = await page.evaluate(function () {
      return !!(document.activeElement && document.activeElement.id === 'palette-input');
    });

    // MINOR-6: ジョブが動いている間だけ beforeunload を止める。
    // この時点(pollCount<2)ではまだ 'working' のはずなので true が期待値。
    out.beforeUnloadWhileRunning = await dispatchBeforeUnloadProbe();

    await page.waitForSelector('#palette-instant:not([hidden])', { timeout: 5000 });
    await page.waitForTimeout(400);
    out.instantHtml = await page.$eval('#palette-instant', function (node) { return node.innerHTML; });
    out.geometryAfterInstant480 = await measureGeometry(page);

    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    // scrollIntoView({behavior:'smooth'}) はアニメーションで、直後の計測だと
    // 途中の座標を拾う。落ち着くまで少し待つ（reduced-motionなら不要だが
    // 待っても実害は無い）。
    await page.waitForTimeout(400);
    out.resultHtml = await page.$eval('#palette-result', function (node) { return node.innerHTML; });
    out.geometryAfterJob480 = await measureGeometry(page);
    out.candidateIndexes = await page.$$eval('[data-yaku-candidate-index]', function (nodes) {
      return nodes.map(function (node) { return node.getAttribute('data-yaku-candidate-index'); });
    });
    out.chipsHidden = await page.$eval('#palette-chips', function (node) { return node.hidden; });

    // MINOR-6続き: ジョブ完了後は止めない。
    out.beforeUnloadAfterDone = await dispatchBeforeUnloadProbe();

    // 1キー: 先頭候補(TM完全一致)をコピー。
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterDigitOne = await page.evaluate(function () { return window.__yakuCopied.slice(); });

    // Enter: 既定候補(先頭=TM)をコピー。
    await page.keyboard.press('Enter');
    await page.waitForTimeout(120);
    out.copiedAfterEnter = await page.evaluate(function () { return window.__yakuCopied.slice(); });

    // 3キー: Copilotの添え(alt, TM=1 main=2 alt=3)をコピー。まだ入れ替えていない。
    await page.keyboard.press('3');
    await page.waitForTimeout(120);
    out.copiedAfterDigitThree = await page.evaluate(function () { return window.__yakuCopied.slice(); });

    // MINOR-5: 添え札(alt)をクリックすると、主札と中身が入れ替わる。
    await page.click('.result-alt[data-yaku-swap]');
    await page.waitForTimeout(80);
    out.mainTextAfterSwap = await page.$eval('[data-yaku-main-text]', function (node) { return node.textContent; });
    out.altBodyAfterSwap = await page.$eval('.result-alt-body', function (node) { return node.textContent; });

    // チップ「丁寧に」。current_text が masked_translation と一致することを見る
    // (画面の表示文字列=DISPLAY_TRANSLATIONを送っていたら不一致になる)。
    // スワップ後でも、チップはジョブが持つ標準訳(masked_translation)を使う。
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
    out.beforeUnloadAfterEscape = await dispatchBeforeUnloadProbe();

    // --- MAJOR-2: 方向確認 -------------------------------------------------
    await pasteText('AMBIGUOUSXY これは方向が曖昧な短い原文です。');
    await page.waitForSelector('[data-yaku-direction-confirm]', { timeout: 5000 });
    out.directionConfirmVisible = true;
    out.directionConfirmIsFocused = await page.evaluate(function () {
      var button = document.querySelector('[data-yaku-direction-confirm]');
      return !!button && document.activeElement === button;
    });
    // NIT-10: Enterはフォーカスしているボタンを押す(候補コピーへ奪われない)。
    await page.keyboard.press('Enter');
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 5000 });
    out.afterDirectionConfirmHtml = await page.$eval('#palette-result', function (node) { return node.innerHTML; });
    out.translateRequestsAfterConfirm = translateRequests.filter(function (row) { return String(row.text || '').indexOf('AMBIGUOUSXY') >= 0; });

    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // --- MAJOR-4: 通常窓(1912x987)でも崩れない ------------------------------
    await page.setViewportSize({ width: 1912, height: 987 });
    await pasteText('TMHIT 御社の今期の売上高は増加しました。');
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(400);
    out.geometryAfterJob1912 = await measureGeometry(page);
  } catch (error) {
    out.errors.push(String((error && error.stack) || error));
  } finally {
    try { if (browser) await browser.close(); } catch (closeError) {}
    try { server.close(); } catch (closeError) {}
  }
  fs.writeFileSync(outPath, JSON.stringify(out), 'utf8');
})();
