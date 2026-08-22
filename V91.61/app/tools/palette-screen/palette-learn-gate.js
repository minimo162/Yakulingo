'use strict';
/*
  「覚える」（用語登録先行、V9200）を、本物のChromiumで開いて確かめる。

  palette-gate.js（V9195/V9199が実測でピンしている行を持つ）は変更しない。
  ここは題材をterm-learnの学習ボタン一本に絞った、独立したドライバ。

  判定はしない。判定は呼び出し側の PowerShell(Test-YakuV9200PaletteLearn.ps1)
  が行う。ここは観察した結果をJSONで書き出すだけ（既存の流儀）。

  使い方: node palette-learn-gate.js <wwwDir> <outJson>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const outPath = process.argv[3];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

const JOB_ID = 'aaaa000000000000000000000000001';
const JOB_ID_NOTERM = 'bbbb000000000000000000000000002';
const MAIN_TEXT = 'Revenue was 1,234 million yen.';
const ALT_TEXT = 'Sales reached 1,234 million yen.';
const TM_TARGET = 'TM memory phrase for the pasted text.';
const FAIL_TARGET = 'FAILTARGET-should-error';
const DUP_TARGET = 'DUPTARGET-already-registered';
const SLOW_TARGET = 'SLOWTARGET-delayed-response';
const CONFLICT_TARGET = 'CONFLICTTARGET-another-translation-exists';
const CONFLICT_MESSAGE = '登録しました。ただしこの語には別の訳がすでに登録されており、どちらが即答に出るかは登録の順番では決まりません。古い方は用語一覧から削除してください。';
const PLAIN_SUCCESS_MESSAGE = '覚えました。次から同じ訳が出ます。';
// CoD審査 REWORK-2 NEW-4: 既に同じ内容(=同じsource+target)で登録済みだが、
// 同じsourceの別targetがまだactiveで残っている場合。「すでに同じ内容で
// 登録されています」だけでは、勝者が登録順で決まらない事実を隠す。
const UNCHANGED_CONFLICT_TARGET = 'UNCHANGEDCONFLICTTARGET-rival-still-active';
const UNCHANGED_CONFLICT_MESSAGE = 'すでに同じ内容で登録されています。ただしこの語には別の訳も登録されており、どちらが即答に出るかは登録の順番では決まりません。古い方は用語一覧から削除してください。';

function b64(text) { return Buffer.from(text, 'utf8').toString('base64'); }

const doneHtml =
  "<div class='batch-note masking-note'>数値 0 件をマスクして送信しました。符号と単位は送信しています。</div>" +
  "<section class='result-stack' data-yaku-state='done'>" +
  "<article class='result-card result-card-translation' data-yaku-main-card>" +
  "  <pre class='translation' data-yaku-main-text>" + MAIN_TEXT + "</pre>" +
  "  <div class='result-actions'><span class='result-kind' data-yaku-main-kind>標準訳案（Copilot訳・未確認）</span>" +
  "  <button type='button' class='secondary-button copy-button' data-yaku-copy-b64='" + b64(MAIN_TEXT) + "'>コピー</button></div>" +
  "</article>" +
  "<div class='result-alts'><p class='result-alts-lead'>枠に入らないときは、こちらを押すと上と入れ替わります。</p>" +
  "<div class='result-alts-list'>" +
  "<button type='button' class='result-alt' data-yaku-swap='" + b64(ALT_TEXT) + "' data-yaku-swap-kind='電文体'>" +
  "<span class='result-alt-head'>電文体<span class='result-alt-chars'>" + ALT_TEXT.length + " 字</span></span>" +
  "<span class='result-alt-body'>" + ALT_TEXT + "</span></button></div></div>" +
  "</section>";

let learnDelayMs = 0;
const instantRequests = [];
const learnRequests = [];
let pollCountA = 0;
let pollCountB = 0;

const server = http.createServer(function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/palette' || url.pathname === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'palette.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'palette-learn-test-token')
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
      instantRequests.push(payload);
      const text = String(payload.text || '');
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (text.indexOf('TMHIT') >= 0) {
        res.end(JSON.stringify({ direction: 'to_en', tm: { source: text, target: TM_TARGET, exact: true }, terms: [] }));
      } else {
        // NOTERM: TM無し・用語無し。即答欄は開かない(hidden=true)ままになる
        // ——「即答欄が開いていなければ再取得しない」側の題材。
        res.end(JSON.stringify({ direction: 'to_en', tm: null, terms: [] }));
      }
      return;
    }
    if (url.pathname === '/api/palette/translate') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      const text = String(payload.text || '');
      if (text.indexOf('NOTERM') >= 0) { res.end(JSON.stringify({ job_id: JOB_ID_NOTERM })); return; }
      res.end(JSON.stringify({ job_id: JOB_ID }));
      return;
    }
    if (url.pathname === '/api/palette/term-learn') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      learnRequests.push(payload);
      const target = String(payload.target || '');
      if (target === FAIL_TARGET) {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: 'テスト用の失敗です。' }));
        return;
      }
      const respond = function () {
        if (target === DUP_TARGET) {
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: true, status: 'unchanged', message: 'すでに同じ内容で登録されています。', term_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }));
          return;
        }
        if (target === CONFLICT_TARGET) {
          // CoD審査 REWORK-1 MAJOR-2: 同じ原文に既に別の訳がある場合の応答。
          // 足すのは止めない(データを失わない)が、文言は単純な成功文言とは
          // 別にする(即答の勝者は登録順で決まらないため)。
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: true, status: 'conflict-added', message: CONFLICT_MESSAGE, term_id: 'cccccccccccccccccccccccccccccc' }));
          return;
        }
        if (target === UNCHANGED_CONFLICT_TARGET) {
          // CoD審査 REWORK-2 NEW-4。
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: true, status: 'unchanged-conflict', message: UNCHANGED_CONFLICT_MESSAGE, term_id: 'dddddddddddddddddddddddddddddd' }));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true, status: 'added', message: PLAIN_SUCCESS_MESSAGE, term_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }));
      };
      if (target === SLOW_TARGET && learnDelayMs > 0) { setTimeout(respond, learnDelayMs); } else { respond(); }
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_ID) {
      pollCountA++;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (pollCountA < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: doneHtml,
        source_text: 'Source text', masked_translation: MAIN_TEXT, direction: 'to_en', style: 'full'
      }));
      return;
    }
    if (url.pathname === '/api/jobs/' + JOB_ID_NOTERM) {
      pollCountB++;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (pollCountB < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
      res.end(JSON.stringify({
        mode: 'done', progress: 100, label: 'Done', class: 'ok', html: doneHtml,
        source_text: 'Source text', masked_translation: MAIN_TEXT, direction: 'to_en', style: 'full'
      }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end('{}');
  });
});

function measureGeometry(page) {
  return page.evaluate(function () {
    function rectOf(node) { if (!node) return null; var r = node.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right }; }
    return {
      innerHeight: window.innerHeight,
      main: rectOf(document.querySelector('#palette-result [data-yaku-main-card]')),
      footer: rectOf(document.querySelector('.palette-footer')),
      input: rectOf(document.getElementById('palette-input')),
      tm: rectOf(document.getElementById('palette-tm-candidate'))
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
      window.__yakuConfirmCalls = [];
      window.__yakuConfirmAnswer = true;
      window.confirm = function (message) {
        window.__yakuConfirmCalls.push(String(message || ''));
        return window.__yakuConfirmAnswer;
      };
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
    async function confirmCalls() { return page.evaluate(function () { return window.__yakuConfirmCalls.slice(); }); }
    async function resetConfirmCalls() { return page.evaluate(function () { window.__yakuConfirmCalls = []; }); }
    // CoD審査 REWORK-1 MINOR-B: 詳細な文言は釦ではなく帯の共有行
    // (#palette-copy-status)へ出る。
    async function statusLineText() { return page.$eval('#palette-copy-status', function (node) { return node.textContent; }); }
    // CoD審査 REWORK-2 NEW-3: 色は#palette-copy-statusのクラスで決まる
    // (is-error/is-warning、既定はvar(--success))。
    async function statusLineClass() { return page.$eval('#palette-copy-status', function (node) { return node.className; }); }
    // CoD審査 REWORK-2 NEW-2: 帯(.palette-footer)が文言で伸びても、今
    // 見えているべき候補(主訳が有れば主訳、無ければTM)の下端が帯の裏へ
    // 沈んでいないこと。measureGeometryは常にmain/tmの両方を返すので、
    // ここではどちらが「今の主役」かも一緒に返す(主訳があれば主訳)。
    // CoD審査 REWORK-2 NOTE-6: MINOR-A(丸1)で直した「圧縮時カードの下端を
    // 釦がはみ出す/候補本文と重なる」を、今後の文言変更でも機械的に検知
    // できるようにする。TM候補カードと学習釦、両方の矩形を返す
    // (呼び出し側でオーバーラップ/はみ出し/重なりを計算する)。
    async function measureLearnButtonFit() {
      return page.evaluate(function () {
        var card = document.getElementById('palette-tm-candidate');
        var btn = card ? card.querySelector('[data-yaku-term-learn]') : null;
        var text = card ? card.querySelector('.translation') : null;
        if (!card || !btn || !text) return null;
        var cr = card.getBoundingClientRect(), br = btn.getBoundingClientRect(), tr = text.getBoundingClientRect();
        return {
          label: btn.textContent,
          cardTop: cr.top, cardBottom: cr.bottom,
          btnTop: br.top, btnBottom: br.bottom, btnLeft: br.left, btnRight: br.right,
          textRight: tr.right,
          overhang: br.bottom - cr.bottom, // >0なら釦がカードの下端をはみ出す
          overlap: tr.right - br.left // >0なら候補本文と釦が重なる
        };
      });
    }

    async function measureFooterFit() {
      return page.evaluate(function () {
        function rectOf(node) { if (!node) return null; var r = node.getBoundingClientRect(); return { top: r.top, bottom: r.bottom }; }
        var main = document.querySelector('#palette-result [data-yaku-main-card]');
        var tm = document.getElementById('palette-tm-candidate');
        var target = main || tm;
        var footer = document.querySelector('.palette-footer');
        if (!target || !footer) return null;
        var tr = target.getBoundingClientRect();
        var fr = footer.getBoundingClientRect();
        return {
          usedMain: !!main, bottom: tr.bottom, footerTop: fr.top, footerHeight: fr.height,
          clearance: fr.top - tr.bottom
        };
      });
    }

    // ============================================================ シナリオ1
    // TMHIT: 句点を含む「文っぽい」原文。TM候補が即答で出て、即答欄は開く。
    await pasteText('TMHIT 御社の今期の売上高は増加しました。');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    out.tmLearnButtonExists = true;
    out.tmLearnButtonIsCorner = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.classList.contains('term-learn-corner'); });

    // 幾何: 即答のみの段階でも学習釦が入って崩れていないこと。
    out.geometryAfterInstantWithLearnButton = await measureGeometry(page);
    // CoD審査 REWORK-2 NEW-2: 帯の共有行が空文字のベースライン(比較の基準)。
    out.footerFitEmptyStatus = await measureFooterFit();

    const beforeTmClick = await copiedSnapshot();
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.confirmCallsForSentenceSource = await confirmCalls();
    out.copiedAfterTmLearnClick = (await copiedSnapshot()).length - beforeTmClick.length;
    out.tmLearnRequestCountAfterClick = learnRequests.length;
    out.tmLearnRequestBody = learnRequests[learnRequests.length - 1];
    // 登録成功の表示は、instantの取り直し(TERM_LEARN_REFRESH_DELAY_MS後)
    // より先に読めること——取り直しはTM候補のDOMを丸ごと作り直すので、
    // 間を置かずに読むと既に消えている(実測、この遅延を入れる前は常に
    // "覚える"のまま)。釦自体は短い状態語(「済み」)だけを示し、詳細な
    // 文言(サーバのmessage)は帯の共有行(#palette-copy-status)へ出る
    // (CoD審査 REWORK-1 MINOR-A/B)。
    out.instantRequestCountRightAfterTmLearn = instantRequests.length;
    out.tmLearnButtonTextAfterSuccess = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.textContent; });
    out.tmLearnStatusLineAfterSuccess = await statusLineText();
    out.tmLearnStatusClassAfterSuccess = await statusLineClass();
    out.footerFitAfterTmSuccess = await measureFooterFit();
    await page.waitForTimeout(1000);
    out.instantRequestCountAfterTmLearnDelay = instantRequests.length;
    await resetConfirmCalls();

    // ジョブ完了を待つ(主訳・添えが揃う)。
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(300);
    // 無言スワップのピン。premium画面の長さ設定が、利用者が触るより前に
    // 描画のたびに効き、主札と添え札の中身を黙って入れ替えていた欠陥
    // (issue #104)を見るため、何も押していない完了直後の主札の本文・種別と
    // 添え札の入れ替え用データをそのまま残す。判定は呼び出し側が行う。
    out.mainPreTextAfterDone = await page.$eval('[data-yaku-main-text]', function (node) { return node.textContent; });
    out.mainKindAfterDone = await page.$eval('[data-yaku-main-kind]', function (node) { return node.textContent; });
    // atob は Latin-1 復号なので、ALT_TEXT が非ASCIIになった瞬間に化けて
    // 恒久的な偽赤になる。製品の decodeAltText(YakuCommon)と同じ UTF-8 復号を
    // ドライバ内で行う(製品コードへは結合しない)。
    out.altSwapDecodedAfterDone = await page.$eval('.result-alt[data-yaku-swap]', function (node) {
      var bytes = Uint8Array.from(window.atob(node.getAttribute('data-yaku-swap') || ''), function (c) { return c.charCodeAt(0); });
      return new TextDecoder('utf-8').decode(bytes);
    });
    out.mainLearnButtonExists = (await page.$('[data-yaku-main-card] [data-yaku-term-learn]')) !== null;
    out.altLearnButtonExists = (await page.$('.result-alt-shell [data-yaku-term-learn]')) !== null;
    // button-in-button回避: 添え札(.result-alt)は覚える釦の祖先ではない(兄弟)。
    out.altLearnButtonIsSiblingNotChild = await page.evaluate(function () {
      var learnBtn = document.querySelector('.result-alt-shell [data-yaku-term-learn]');
      var altBtn = document.querySelector('.result-alt[data-yaku-swap]');
      return !!(learnBtn && altBtn && !altBtn.contains(learnBtn) && !learnBtn.contains(altBtn));
    });

    // ============================================================ シナリオ2
    // 主訳の「覚える」。押してもコピー/入れ替えは起きない(伝播を止めている)。
    const beforeMainLearnClick = await copiedSnapshot();
    await page.click('[data-yaku-main-card] [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.copiedAfterMainLearnClick = (await copiedSnapshot()).length - beforeMainLearnClick.length;
    out.mainLearnRequestBody = learnRequests[learnRequests.length - 1];
    out.instantRequestCountRightAfterMainLearn = instantRequests.length;
    out.mainLearnButtonTextAfterSuccess = await page.$eval('[data-yaku-main-card] [data-yaku-term-learn]', function (node) { return node.textContent; });
    out.mainLearnStatusLineAfterSuccess = await statusLineText();
    out.mainLearnStatusClassAfterSuccess = await statusLineClass();
    out.footerFitAfterMainSuccess = await measureFooterFit();
    await page.waitForTimeout(1000);
    out.instantRequestCountAfterMainLearnDelay = instantRequests.length;
    // CoD審査 REWORK-1 MINOR-C: 主訳は次の翻訳までDOMが作り直されない
    // ——復帰の仕組み(TERM_LEARN_RESTORE_DELAY_MS)が無いと「済み」の
    // ままdisabledではない状態で残り続けていた。復帰後の文言を見る
    // (クリックから合計4000ms以上待つ、上の1000msぶんは既に消化済み)。
    await page.waitForTimeout(3200);
    out.mainLearnButtonTextAfterRestore = await page.$eval('[data-yaku-main-card] [data-yaku-term-learn]', function (node) { return node.textContent; });

    // ============================================================ シナリオ3
    // 添え候補の「覚える」。押しても入れ替え(swap)は起きない。
    const mainTextBeforeAltLearn = await page.$eval('[data-yaku-main-text]', function (node) { return node.textContent; });
    const beforeAltLearnClick = await copiedSnapshot();
    await page.click('.result-alt-shell [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.copiedAfterAltLearnClick = (await copiedSnapshot()).length - beforeAltLearnClick.length;
    out.mainTextUnchangedAfterAltLearn = (await page.$eval('[data-yaku-main-text]', function (node) { return node.textContent; })) === mainTextBeforeAltLearn;
    out.altLearnRequestBody = learnRequests[learnRequests.length - 1];

    // 幾何: 3つとも押した後でも主札が画面内(帯より上)に収まっている。
    out.geometryAfterAllLearnClicks = await measureGeometry(page);

    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ4
    // 短い語句(句点なし・40字以下)は確認を挟まない。
    // ついでにNOTE-6(MINOR-Aの丸1固定): この時点でTM候補は既にis-compact
    // (実測、ここまでのpollCountAの消化で背景ジョブが1回のpollで終わる)。
    // 4つの状態(覚える/登録中/済み/エラー)ぶんの釦とカードの矩形を残す。
    await pasteText('TMHIT2 短い語句');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await resetConfirmCalls();
    out.buttonFitIdle = await measureLearnButtonFit();
    learnDelayMs = 200;
    await page.evaluate(function (slow) {
      var node = document.getElementById('palette-tm-candidate');
      if (node) node.setAttribute('data-yaku-candidate-text', slow);
    }, SLOW_TARGET);
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    out.buttonFitPending = await measureLearnButtonFit();
    out.confirmCallsForShortSource = await confirmCalls();
    await page.waitForTimeout(400);
    out.buttonFitSuccess = await measureLearnButtonFit();
    out.learnRequestCountAfterShortSourceClick = learnRequests.length;
    learnDelayMs = 0;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ4.5
    // 既に同じ内容が登録済み(status=unchanged)の応答は、その旨を表示する
    // （added とは違う文言になること）。
    await pasteText('TMHIT2 重複の的');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await page.evaluate(function (dup) {
      var node = document.getElementById('palette-tm-candidate');
      if (node) node.setAttribute('data-yaku-candidate-text', dup);
    }, DUP_TARGET);
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.tmLearnButtonTextAfterUnchanged = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.textContent; });
    out.tmLearnStatusLineAfterUnchanged = await statusLineText();
    out.tmLearnStatusClassAfterUnchanged = await statusLineClass();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ4.6
    // MAJOR-2: 同じ語に別の訳が既にある場合(conflict-added)は、単純な
    // 成功文言(PLAIN_SUCCESS_MESSAGE)を出さず、重複の案内を出す。
    // NEW-2: この文言は3行に折り返す(実測)——足す前に主札/TM候補が
    // 帯の裏へ沈んでいないことも測る。
    await pasteText('TMHIT2 衝突の的');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await page.evaluate(function (conflict) {
      var node = document.getElementById('palette-tm-candidate');
      if (node) node.setAttribute('data-yaku-candidate-text', conflict);
    }, CONFLICT_TARGET);
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.tmLearnButtonTextAfterConflict = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.textContent; });
    out.tmLearnStatusLineAfterConflict = await statusLineText();
    out.tmLearnStatusClassAfterConflict = await statusLineClass();
    out.footerFitAfterConflict = await measureFooterFit();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ4.65
    // NEW-4: 同じ内容(unchanged)でも、別targetの既存語がまだactiveなら
    // status=unchanged-conflictにして、単純な「登録済みです」より詳しい
    // 案内を出す。
    await pasteText('TMHIT2 未変更衝突の的');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await page.evaluate(function (uc) {
      var node = document.getElementById('palette-tm-candidate');
      if (node) node.setAttribute('data-yaku-candidate-text', uc);
    }, UNCHANGED_CONFLICT_TARGET);
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.tmLearnButtonTextAfterUnchangedConflict = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.textContent; });
    out.tmLearnStatusLineAfterUnchangedConflict = await statusLineText();
    out.tmLearnStatusClassAfterUnchangedConflict = await statusLineClass();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ4.7
    // MINOR-D: 'U.S.'のような略語は、句点扱いされて確認ダイアログが出ない
    // こと(短い語句なので長さのしきい値にも掛からない)。
    await pasteText('TMHIT2 U.S.');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await resetConfirmCalls();
    const learnCountBeforeAbbrev = learnRequests.length;
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.confirmCallsForAbbreviation = await confirmCalls();
    out.learnRequestCountAfterAbbreviationClick = learnRequests.length - learnCountBeforeAbbrev;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ5
    // 文っぽい原文で確認を「いいえ」にすると送らない。
    await pasteText('TMHIT これは長さも十分にある、確認が要る文章です。');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await resetConfirmCalls();
    const learnCountBeforeDecline = learnRequests.length;
    await page.evaluate(function () { window.__yakuConfirmAnswer = false; });
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.confirmCallsForDeclinedSentence = await confirmCalls();
    out.learnRequestCountAfterDecline = learnRequests.length - learnCountBeforeDecline;
    await page.evaluate(function () { window.__yakuConfirmAnswer = true; });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ6
    // 即答欄が開いていない(TMも用語も無い)ときは、学習成功後もinstantを
    // 再取得しない。
    await pasteText('NOTERM 用語もTM一致も無い原文です。');
    await page.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await page.waitForTimeout(300);
    out.instantHiddenWhenNoTmNoTerms = await page.$eval('#palette-instant', function (node) { return node.hidden; });
    const instantCountBeforeNoTermLearn = instantRequests.length;
    await page.click('[data-yaku-main-card] [data-yaku-term-learn]');
    await page.waitForTimeout(150);
    out.instantRequestDeltaWhenClosedAfterLearn = instantRequests.length - instantCountBeforeNoTermLearn;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ7
    // 二重送信ガード: 遅い応答の最中に2回連続でクリックしても、送るのは1回。
    // FAILTARGETやDUPTARGETは句点なしの短い語句として学習させ、確認ダイアログ
    // を絡めない(このシナリオの主眼はガードなので、他要因を混ぜない)。
    learnDelayMs = 400;
    await pasteText('TMHIT3 二重送信の的');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await page.evaluate(function (slow) {
      var node = document.getElementById('palette-tm-candidate');
      if (node) node.setAttribute('data-yaku-candidate-text', slow);
    }, SLOW_TARGET);
    const learnCountBeforeDoubleClick = learnRequests.length;
    const learnButtonHandle = await page.$('#palette-tm-candidate [data-yaku-term-learn]');
    await learnButtonHandle.click();
    out.learnButtonDisabledRightAfterFirstClick = await learnButtonHandle.evaluate(function (node) { return node.disabled; });
    await learnButtonHandle.click({ force: true }).catch(function () {});
    await page.waitForTimeout(700);
    out.learnRequestCountAfterDoubleClick = learnRequests.length - learnCountBeforeDoubleClick;
    learnDelayMs = 0;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);

    // ============================================================ シナリオ8
    // 失敗応答: 釦は短い状態語(「エラー」)だけ、全文はサーバのエラー本文
    // そのまま帯(#palette-copy-status)へ出る(MINOR-B、12字への切り詰め廃止)。
    // しばらくすると釦は元の文言へ戻る(MINOR-C)。
    await pasteText('TMHIT4 失敗の的');
    await page.waitForSelector('#palette-tm-candidate [data-yaku-term-learn]', { timeout: 5000 });
    await page.evaluate(function (fail) {
      var node = document.getElementById('palette-tm-candidate');
      if (node) node.setAttribute('data-yaku-candidate-text', fail);
    }, FAIL_TARGET);
    await page.click('#palette-tm-candidate [data-yaku-term-learn]');
    await page.waitForTimeout(200);
    out.tmLearnButtonTextAfterFailure = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.textContent; });
    out.tmLearnStatusLineAfterFailure = await statusLineText();
    out.tmLearnStatusClassAfterFailure = await statusLineClass();
    out.buttonFitError = await measureLearnButtonFit();
    out.tmLearnButtonDisabledAfterFailure = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.disabled; });
    await page.waitForTimeout(4000);
    out.tmLearnButtonTextAfterFailureRestore = await page.$eval('#palette-tm-candidate [data-yaku-term-learn]', function (node) { return node.textContent; });
  } catch (error) {
    out.errors.push(String((error && error.stack) || error));
  } finally {
    try { if (browser) await browser.close(); } catch (closeError) {}
    try { server.close(); } catch (closeError) {}
  }
  fs.writeFileSync(outPath, JSON.stringify(out), 'utf8');
})();
