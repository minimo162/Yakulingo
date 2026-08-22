'use strict';
/*
  標準の左右翻訳面(/)に埋め込まれたチャット翻訳を、本物のChromiumで開いて確かめる。

  cat-screen-gate.js と同じ考え方（本物のhtml/js/cssをローカルHTTPで配り、
  /api/* は決め打ちの応答で記録し、実際に押す・打つ）。ここでは題材を
  チャット翻訳一本に絞り、cat-screen-gate.js を肥大化させない。

  判定はしない。判定は呼び出し側の PowerShell が行う（観察と判定を分ける、
  既存の流儀）。ここは観察した結果をJSONで書き出すだけ。

  レビュー2周目からの追加分:
    - MAJOR-A: ボタンをクリックした直後（activeElementがそのボタンのまま）
      でも、数字キー(1〜9)は生きていること。添え札クリック(スワップ)の後・
      コピー釦クリックの後の両方で確かめる。
    - MAJOR-B: 結果を挿し込んだ後も、原文欄(#palette-input)の一部が画面内に
      残ること（原文併記）。480x640・1912x987の両方で測る。
    - MINOR-C: Enterでコピーされる「既定候補」が実際に何かを、帯の案内文
      (#palette-hint-target)が名指ししていること。
    - NIT-D: 方向確認ボタンを押す前に原文を書き換えたら、確定方向を古い
      原文へ当てはめず、書き換え後の原文で自動判定へ戻ること。

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

const editedDoneHtml =
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>Edited text translation.</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64('Edited text translation.') + "'>コピー</button></div>" +
  "</article></section>";

let pollCount = 0;
const chipRequests = [];
const translateRequests = [];

const server = http.createServer(function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/palette' || url.pathname === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'palette-test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS P\\u30b4\\u30b7\\u30c3\\u30af')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, 'start');
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
    if (url.pathname === '/api/cat/recent') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ projects: [] })); return;
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
      if (text.indexOf('EDITEDAFTERCONFIRM') >= 0) { res.end(JSON.stringify({ job_id: 'edited0000000000000000000000003' })); return; }
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
    if (url.pathname === '/api/jobs/edited0000000000000000000000003') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ mode: 'done', progress: 100, label: 'Done', class: 'ok', html: editedDoneHtml, source_text: 'EDITEDAFTERCONFIRM text', masked_translation: 'Edited text translation.', direction: 'to_en', style: 'full' }));
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
    function rectOf(node) {
      if (!node) return null;
      var r = node.getBoundingClientRect();
      return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
    }
    var main = document.querySelector('#palette-result [data-yaku-main-card]');
    var hint = document.querySelector('.palette-hint');
    var footer = document.querySelector('.palette-footer');
    var input = document.getElementById('palette-input');
    var result = document.getElementById('palette-result');
    var resultStyle = result ? getComputedStyle(result) : null;
    var candidate1 = document.querySelector('[data-yaku-candidate-index="1"]');
    var hintTarget = document.getElementById('palette-hint-target');
    return {
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      main: rectOf(main),
      hint: rectOf(hint),
      footer: rectOf(footer),
      input: rectOf(input),
      result: rectOf(result),
      resultMaxHeight: resultStyle ? resultStyle.maxHeight : '',
      resultOverflowY: resultStyle ? resultStyle.overflowY : '',
      candidate1: rectOf(candidate1),
      hintTargetText: hintTarget ? hintTarget.textContent : ''
    };
  });
}

(async function () {
  const out = { errors: [], console: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 480, height: 640 }, reducedMotion: 'reduce' });
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

    async function copiedSnapshot() {
      return page.evaluate(function () { return window.__yakuCopied.slice(); });
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
    // NIT-E: 即答が出た段階の幾何も使う。原文欄はまだこの時点でも
    // (MAJOR-Bの圧縮が効いた後も)見えているべき。
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
    out.inputRowsAfterJob = await page.$eval('#palette-input', function (node) { return node.rows; });

    // MINOR-6続き: ジョブ完了後は止めない。
    out.beforeUnloadAfterDone = await dispatchBeforeUnloadProbe();

    // 1キー: 先頭候補(TM完全一致)をコピー。
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterDigitOne = await copiedSnapshot();

    // Enter: 既定候補(先頭=TM)をコピー。
    await page.keyboard.press('Enter');
    await page.waitForTimeout(120);
    out.copiedAfterEnter = await copiedSnapshot();

    // 3キー: Copilotの添え(alt, TM=1 main=2 alt=3)をコピー。まだ入れ替えていない。
    await page.keyboard.press('3');
    await page.waitForTimeout(120);
    out.copiedAfterDigitThree = await copiedSnapshot();

    // --- MAJOR-A: ボタンをクリックした直後でも数字キーが生きている ----------
    // まず主札のコピー釦をクリック(マウス)する。クリック後、activeElement は
    // その<button>のまま——ここで数字キーが死ぬのが今回の欠陥だった。
    const beforeMainCopyClick = await copiedSnapshot();
    await page.click('[data-yaku-main-card] [data-yaku-copy-b64]');
    await page.waitForTimeout(80);
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    const afterMainCopyClickDigit = await copiedSnapshot();
    out.copiedCountBeforeMainCopyClick = beforeMainCopyClick.length;
    out.copiedCountAfterMainCopyClickThenDigit = afterMainCopyClickDigit.length;
    out.copiedLastAfterMainCopyClickThenDigit = afterMainCopyClickDigit[afterMainCopyClickDigit.length - 1] || '';

    // MINOR-5: 添え札(alt)をクリックすると、主札と中身が入れ替わる。
    await page.click('.result-alt[data-yaku-swap]');
    await page.waitForTimeout(80);
    out.mainTextAfterSwap = await page.$eval('[data-yaku-main-text]', function (node) { return node.textContent; });
    out.altBodyAfterSwap = await page.$eval('.result-alt-body', function (node) { return node.textContent; });

    // MAJOR-A続き: スワップ(クリック)の直後、activeElementはその添え札の
    // <button>のまま。ここでも数字キーが生きていること(実測: 修正前は
    // 2/3を押してもクリップボードへ一切書かれなかった)。
    const beforeSwapDigit = await copiedSnapshot();
    await page.keyboard.press('2');
    await page.waitForTimeout(120);
    const afterSwapDigit = await copiedSnapshot();
    out.copiedCountBeforeSwapDigit = beforeSwapDigit.length;
    out.copiedCountAfterSwapDigit = afterSwapDigit.length;
    out.copiedLastAfterSwapDigit = afterSwapDigit[afterSwapDigit.length - 1] || '';
    out.copyStatusAfterSwapDigit = await page.$eval('#palette-copy-status', function (node) { return node.textContent; });

    // チップ「丁寧に」。current_text が masked_translation と一致することを見る
    // (画面の表示文字列=DISPLAY_TRANSLATIONを送っていたら不一致になる)。
    // スワップ後でも、チップはジョブが持つ標準訳(masked_translation)を使う。
    await page.click('[data-yaku-chip="revise"]');
    await page.waitForTimeout(400);
    out.chipRequests = chipRequests.slice();

    // Esc: 入力と結果をクリア。原文欄の圧縮(is-compact)も元へ戻ること。
    await page.evaluate(function () { document.getElementById('palette-input').focus(); });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(100);
    out.inputValueAfterEscape = await page.$eval('#palette-input', function (node) { return node.value; });
    out.resultHtmlAfterEscape = await page.$eval('#palette-result', function (node) { return node.innerHTML; });
    out.chipsHiddenAfterEscape = await page.$eval('#palette-chips', function (node) { return node.hidden; });
    out.candidateCountAfterEscape = (await page.$$('[data-yaku-candidate-index]')).length;
    out.beforeUnloadAfterEscape = await dispatchBeforeUnloadProbe();
    out.inputRowsAfterEscape = await page.$eval('#palette-input', function (node) { return node.rows; });

    // --- MAJOR-2 + NIT-10: 方向確認、Enterでそのボタンを押す ----------------
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

    // --- NIT-D: 確認ボタンを押す前に原文を書き換えたら、古い判定を当てない ---
    await pasteText('AMBIGUOUSXY 書き換え前の原文です。');
    await page.waitForSelector('[data-yaku-direction-confirm]', { timeout: 5000 });
    // ボタンへは触れず、原文だけ書き換える(貼り付けではなく直接編集を模す。
    // 自動翻訳の再始動はここでは要らないので input イベントは送らない)。
    await page.evaluate(function () {
      document.getElementById('palette-input').value = 'EDITEDAFTERCONFIRM 書き換え後の原文です。';
    });
    await page.click('[data-yaku-direction-confirm]');
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 5000 });
    out.translateRequestsAfterEdit = translateRequests.filter(function (row) { return String(row.text || '').indexOf('EDITEDAFTERCONFIRM') >= 0; });
    out.afterEditConfirmHtml = await page.$eval('#palette-result', function (node) { return node.innerHTML; });

    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // --- MAJOR-4/MAJOR-B: 通常窓(1912x987)でも崩れない ------------------------
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
