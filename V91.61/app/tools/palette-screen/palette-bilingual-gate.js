'use strict';
/*
  対訳並置ビュー（V9202）を、本物のChromiumで開いて確かめる。

  palette-gate.js（V9195/V9199がピンする行を持つ）・palette-learn-gate.js
  （V9200がピンする行を持つ）はどちらも変更しない。ここは題材を対訳並置
  ビュー一本に絞った、独立したドライバ（既存の流儀どおり）。

  判定はしない。判定は呼び出し側の PowerShell(Test-YakuV9202PaletteBilingual.ps1)
  が行う。ここは観察した結果をJSONで書き出すだけ。

  題材（3本）:
    - BILINGUALMATCH   : 原文3段落・訳3段落（一致）→対訳が並ぶこと。
        ジョブが返す source_text は、貼り付けたテキスト（1段落の短い合図）
        とはわざと違う内容にする——判定が「貼った瞬間のinput.value」ではなく
        「ジョブJSONのsource_text」を正として使っていることを、値の食い違いで
        証明する（仕様item 1「source_text がジョブJSONにあるならそちらを正」）。
        段落の正規化（空行区切り・空白だけの段落・末尾の空行・署名のような
        改行を含む1段落）も、この1本の題材へ寄せて同時に確かめる。
    - BILINGUALMISMATCH: 原文3段落・訳2段落（不一致）→単一ブロックのまま。
    - BILINGUALSINGLE  : 原文1段落・訳1段落→単一ブロックのまま。

  使い方: node palette-bilingual-gate.js <wwwDir> <outJson>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const outPath = process.argv[3];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

const JOB_MATCH = 'b111000000000000000000000000001';
const JOB_MISMATCH = 'b222000000000000000000000000002';
const JOB_SINGLE = 'b333000000000000000000000000003';

function b64(text) { return Buffer.from(text, 'utf8').toString('base64'); }

// --- BILINGUALMATCH: 原文3段落・訳3段落（一致） -----------------------------
const SOURCE_PARA_1 = 'Thank you for your inquiry.';
const SOURCE_PARA_2 = 'We will confirm the shipping schedule.';
// 署名のような「改行を含むが空行を挟まない」1段落。分割しない(spec item 1)
// ことを確かめる。
const SOURCE_PARA_3 = 'Best regards,\nAlice';
const TARGET_PARA_1 = 'お問い合わせありがとうございます。';
const TARGET_PARA_2 = '出荷予定は確認いたします。';
const TARGET_PARA_3 = '敬具\nアリス';

// source_text: 段落1と2の間に空白だけの「段落」を挟み、末尾に空行を3つ
// 足す。どちらも段落として現れてはならない(正規化の確認)。
const SOURCE_MATCH_TEXT = SOURCE_PARA_1 + '\n\n   \n\n' + SOURCE_PARA_2 + '\n\n' + SOURCE_PARA_3 + '\n\n\n';
// 訳文側にも末尾の空行を1つ足す。pre.textContent はこの文字列そのまま
// （末尾の空行込み）で残るはずで、コピーはこれと完全一致するはず
// ——段落へ分けて表示していても、コピーは分割前の全文のまま、の証明。
const DISPLAY_TRANSLATION_MATCH = TARGET_PARA_1 + '\n\n' + TARGET_PARA_2 + '\n\n' + TARGET_PARA_3 + '\n\n';

// 添え札（スワップ対象）。原文と同じ3段落構成の別訳——スワップ後に対訳が
// 作り直されることを確かめる。
const ALT_PARA_1 = 'ご連絡いただきありがとうございます。';
const ALT_PARA_2 = '発送日程を確認します。';
const ALT_PARA_3 = '敬具\nA';
const ALT_MATCH_TEXT = ALT_PARA_1 + '\n\n' + ALT_PARA_2 + '\n\n' + ALT_PARA_3;

// 貼り付けるテキストはわざと1段落・別内容にする(source_textが正である証明)。
const PASTE_MATCH_TEXT = 'BILINGUALMATCH まとめて訳してください。';

const matchHtml =
  "<div class='batch-note masking-note'>数値 0 件をマスクして送信しました。符号と単位は送信しています。</div>" +
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>" + DISPLAY_TRANSLATION_MATCH + "</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64(DISPLAY_TRANSLATION_MATCH) + "'>コピー</button></div>" +
  "</article>" +
  "<div class='result-alts'><p class='result-alts-lead'>枠に入らないときは、こちらを押すと上と入れ替わります。</p>" +
  "<div class='result-alts-list'>" +
  "<button type='button' class='result-alt' data-yaku-swap='" + b64(ALT_MATCH_TEXT) + "' data-yaku-swap-kind='電文体'>" +
  "<span class='result-alt-head'>電文体<span class='result-alt-chars'>" + ALT_MATCH_TEXT.length + " 字</span></span>" +
  "<span class='result-alt-body'>" + ALT_MATCH_TEXT + "</span></button></div></div>" +
  "</section>";

// --- BILINGUALMISMATCH: 原文3段落・訳2段落（不一致） -------------------------
const MISMATCH_SOURCE = 'Alpha line one.\n\nAlpha line two.\n\nAlpha line three.';
const MISMATCH_TRANSLATION = 'アルファ 1行目。\n\nアルファ 2行目。';
const PASTE_MISMATCH_TEXT = 'BILINGUALMISMATCH 段落数が揃わない題材です。';

const mismatchHtml =
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>" + MISMATCH_TRANSLATION + "</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64(MISMATCH_TRANSLATION) + "'>コピー</button></div>" +
  "</article></section>";

// --- BILINGUALSINGLE: 原文1段落・訳1段落 ------------------------------------
const SINGLE_SOURCE = 'Just one paragraph.';
const SINGLE_TRANSLATION = '一段落だけです。';
const PASTE_SINGLE_TEXT = 'BILINGUALSINGLE 1段落だけの題材です。';

const singleHtml =
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>" + SINGLE_TRANSLATION + "</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64(SINGLE_TRANSLATION) + "'>コピー</button></div>" +
  "</article></section>";

const learnRequests = [];
let pollMatch = 0;
let pollMismatch = 0;
let pollSingle = 0;

const server = http.createServer(function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/palette' || url.pathname === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'palette.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'palette-bilingual-test-token')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '8000');
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
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ direction: 'to_jp', tm: null, terms: [] }));
      return;
    }
    if (url.pathname === '/api/palette/translate') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      const text = String(payload.text || '');
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (text.indexOf('BILINGUALMATCH') >= 0) { res.end(JSON.stringify({ job_id: JOB_MATCH })); return; }
      if (text.indexOf('BILINGUALMISMATCH') >= 0) { res.end(JSON.stringify({ job_id: JOB_MISMATCH })); return; }
      if (text.indexOf('BILINGUALSINGLE') >= 0) { res.end(JSON.stringify({ job_id: JOB_SINGLE })); return; }
      res.end(JSON.stringify({ job_id: JOB_SINGLE }));
      return;
    }
    if (url.pathname === '/api/palette/term-learn') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      learnRequests.push(payload);
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true, status: 'added', message: '覚えました。次から同じ訳が出ます。', term_id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }));
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_MATCH) {
      pollMatch++;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (pollMatch < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: matchHtml,
        source_text: SOURCE_MATCH_TEXT, masked_translation: DISPLAY_TRANSLATION_MATCH, direction: 'to_jp', style: 'full'
      }));
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_MISMATCH) {
      pollMismatch++;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (pollMismatch < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: mismatchHtml,
        source_text: MISMATCH_SOURCE, masked_translation: MISMATCH_TRANSLATION, direction: 'to_jp', style: 'full'
      }));
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_SINGLE) {
      pollSingle++;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (pollSingle < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: singleHtml,
        source_text: SINGLE_SOURCE, masked_translation: SINGLE_TRANSLATION, direction: 'to_jp', style: 'full'
      }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end('{}');
  });
});

function measureGeometry(page) {
  return page.evaluate(function () {
    function rectOf(node) { if (!node) return null; var r = node.getBoundingClientRect(); return { top: r.top, bottom: r.bottom }; }
    return {
      innerHeight: window.innerHeight,
      main: rectOf(document.querySelector('#palette-result [data-yaku-main-card]')),
      hint: rectOf(document.querySelector('.palette-hint')),
      footer: rectOf(document.querySelector('.palette-footer')),
      input: rectOf(document.getElementById('palette-input'))
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
    page.on('console', function (message) {
      if (message.type() !== 'error') return;
      out.console.push(message.text());
    });
    await page.addInitScript(function () {
      window.__yakuCopied = [];
      Object.defineProperty(navigator, 'clipboard', {
        value: { writeText: function (text) { window.__yakuCopied.push(text); return Promise.resolve(); } },
        configurable: true
      });
      // 貼り付ける題材は句点を含む「文っぽい」原文なので、覚える釦は
      // looksLikeSentence()でwindow.confirmを挟む(palette.js)。
      // ここでは常に「はい」を返し、覚えるの配線そのもの(送信対象)を見る。
      window.confirm = function () { return true; };
    });
    await page.goto('http://127.0.0.1:' + server.address().port + '/palette', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#palette-input');

    async function pasteText(text) {
      await page.evaluate(function (value) {
        var target = document.getElementById('palette-input');
        target.focus();
        target.value = value;
        target.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', bubbles: true }));
      }, text);
    }
    async function copiedSnapshot() { return page.evaluate(function () { return window.__yakuCopied.slice(); }); }
    async function bilingualSnapshot() {
      return page.evaluate(function () {
        var card = document.querySelector('#palette-result [data-yaku-main-card]');
        var pre = card ? card.querySelector('[data-yaku-main-text]') : null;
        var view = card ? card.querySelector('[data-yaku-bilingual-view]') : null;
        var pairs = card ? card.querySelectorAll('.bilingual-pair') : [];
        var sourceTexts = [];
        var targetTexts = [];
        for (var i = 0; i < pairs.length; i++) {
          var s = pairs[i].querySelector('.bilingual-source');
          var t = pairs[i].querySelector('.bilingual-target');
          sourceTexts.push(s ? s.textContent : null);
          targetTexts.push(t ? t.textContent : null);
        }
        var bilingualBtn = card ? card.querySelector('[data-yaku-bilingual-mode="bilingual"]') : null;
        var monoBtn = card ? card.querySelector('[data-yaku-bilingual-mode="mono"]') : null;
        return {
          hasCard: !!card,
          hasView: !!view,
          viewHidden: view ? view.hidden : null,
          preExists: !!pre,
          preHidden: pre ? pre.classList.contains('is-bilingual-hidden') : null,
          preText: pre ? pre.textContent : null,
          pairCount: pairs.length,
          sourceTexts: sourceTexts,
          targetTexts: targetTexts,
          hasToggle: !!(bilingualBtn && monoBtn),
          bilingualPressed: bilingualBtn ? bilingualBtn.getAttribute('aria-pressed') : null,
          monoPressed: monoBtn ? monoBtn.getAttribute('aria-pressed') : null
        };
      });
    }

    // ============================================================ シナリオ1: 一致(3段落)
    await pasteText(PASTE_MATCH_TEXT);
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(400);

    out.matchSnapshot = await bilingualSnapshot();
    out.geometryMatch480 = await measureGeometry(page);

    // コピー(1キー): 対訳表示中でも全文のまま。
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterDigitOneBilingual = await copiedSnapshot();

    // コピー釦(クリック): 同じく全文のまま。
    const beforeMainCopyClick = await copiedSnapshot();
    await page.click('[data-yaku-main-card] [data-yaku-copy-b64]');
    await page.waitForTimeout(120);
    out.copiedAfterMainCopyClickBilingual = (await copiedSnapshot()).slice(beforeMainCopyClick.length);

    // トグル: 対訳→訳のみ。
    await page.click('[data-yaku-main-card] [data-yaku-bilingual-mode="mono"]');
    await page.waitForTimeout(100);
    out.snapshotAfterToggleMono = await bilingualSnapshot();

    // 訳のみ表示中でもコピーは全文のまま。
    const beforeMonoDigit = await copiedSnapshot();
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterDigitOneMono = (await copiedSnapshot()).slice(beforeMonoDigit.length);

    // トグル: 訳のみ→対訳(元へ戻す)。
    await page.click('[data-yaku-main-card] [data-yaku-bilingual-mode="bilingual"]');
    await page.waitForTimeout(100);
    out.snapshotAfterToggleBackToBilingual = await bilingualSnapshot();

    // 覚える: 対訳表示中でも、送る対象(target)は全文のまま(段落の1つではない)。
    await page.click('[data-yaku-main-card] [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.mainLearnRequestBodyBilingual = learnRequests[learnRequests.length - 1];

    // スワップ: 添え札クリックで主札の中身が入れ替わり、対訳ビューも
    // 新しい中身で作り直される(既定=対訳へ戻る)。
    await page.click('.result-alt[data-yaku-swap]');
    await page.waitForTimeout(150);
    out.snapshotAfterSwap = await bilingualSnapshot();

    // スワップ後のコピー(1キー)も全文のまま(入れ替わった新しい主訳)。
    const beforeSwapDigit = await copiedSnapshot();
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterSwapDigit = (await copiedSnapshot()).slice(beforeSwapDigit.length);

    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ2: 不一致(3vs2)
    await pasteText(PASTE_MISMATCH_TEXT);
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(300);
    out.mismatchSnapshot = await bilingualSnapshot();
    const beforeMismatchDigit = await copiedSnapshot();
    await page.keyboard.press('1');
    await page.waitForTimeout(120);
    out.copiedAfterMismatchDigit = (await copiedSnapshot()).slice(beforeMismatchDigit.length);

    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ3: 1段落のみ
    await pasteText(PASTE_SINGLE_TEXT);
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(300);
    out.singleSnapshot = await bilingualSnapshot();

    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ 幾何: 通常窓(1912x987)
    await page.setViewportSize({ width: 1912, height: 987 });
    await pasteText(PASTE_MATCH_TEXT);
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(400);
    out.geometryMatch1912 = await measureGeometry(page);
    out.matchSnapshot1912 = await bilingualSnapshot();
  } catch (error) {
    out.errors.push(String((error && error.stack) || error));
  } finally {
    try { if (browser) await browser.close(); } catch (closeError) {}
    try { server.close(); } catch (closeError) {}
  }
  fs.writeFileSync(outPath, JSON.stringify(out), 'utf8');
})();
