'use strict';
/*
  パレット(/palette)の昇格(「CATで開く」)を、本物のChromiumで両側から見る。

  palette-gate.js・cat-screen-gate.js と同じ考え方(本物のhtml/js/cssを
  ローカルHTTPで配り、/api/* は決め打ちの応答で記録し、実際に押す)。
  判定はしない。判定は呼び出し側のPowerShellが行う。ここは観察した結果を
  JSONで書き出すだけ。

  見るのは2枚の画面にまたがる橋渡しなので、片方だけでは検証できない。

  A) /palette 側: 本文があるときだけ「CATで開く」が押せること。押すと
     sessionStorage の専用キーへ {text, direction_intent} を退避し、
     /cat?handoff=palette へ遷移しようとすること(実際の遷移は
     window.location.assign を差し替えて止め、渡された引数を記録する
     ——同一originの本番遷移を試験の中で本当に起こすと、後続の
     read-once検証(D)で「1回目の遷移」を作るために別のpage/contextが
     要り、稼働開始のタイミングが余計に複雑になるため)。
     翻訳ジョブ実行中は押せないことも見る(貼り付けで実際にジョブを
     起こし、進行中→完了で押せる/押せないが切り替わることを見る)。

     A':MAJOR-A(CoD審査 REWORK-1)。80msで1回サンプルするだけの上の
     busy確認では、jobRunning=trueへ変わった直後にupdateHandoffButton
     を呼び直しているか(このRE-WORKで足した箇所)を掴めない
     ——サンプルした時点でたまたま押せない状態だっただけかもしれない。
     ここでは/api/palette/translateをわざと遅らせ(RACETEST)、
     その往復の最中に(jobRunningがまだfalseのうちに)#palette-inputへ
     もう1文字打つ入力イベントを送る。startTranslationの
     updateHandoffButton(true)は打鍵のupdateCount()に上書きされて消える
     のが仕様どおりの弱点で、そのあとjobRunningが実際にtrueへ変わった
     瞬間にupdateHandoffButtonを呼び直していなければ、押せない状態は
     一度も戻ってこない。突然変異(このRE-WORKで足したupdateHandoffButton
     呼び出しを消す)を当てると赤くなる想定の題材。

  B) /cat 側、キー欠落: sessionStorage に何も無いまま ?handoff=palette で
     開いても、quick-inputは空のまま・/api/cat/openは飛ばず・通常起動する。

  C) /cat 側、本文あり: 事前に本文と方向(to_en)をsessionStorageへ仕込んで
     から開くと、quick-inputへ本文が入り、/api/cat/openへ実際に
     text・direction_intent が飛ぶこと(既存の yaku-instant-handoff受け口
     への引き渡しが本当に効いていることを、字面ではなく実際の要求で見る)。

  D) 読み捨て: Cの直後、sessionStorageのキーは消えていること。同じ
     ?handoff=palette をもう一度開いても(戻る/再読み込みを模す)、
     2回目は何も起きない(/api/cat/openの回数が増えない)こと。

  E) 壊れたJSON: sessionStorageの中身がJSONとして壊れていても、例外を
     投げずに通常起動へ落ちること。

  使い方: node palette-handoff-gate.js <wwwDir> <projectJson> <outJson>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const projectJsonPath = process.argv[3];
const outPath = process.argv[4];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };
const HANDOFF_KEY = 'yaku.palette.handoff';
const JOB_ID = 'ddeeff0000000000000000000000009';
// MAJOR-A(CoD審査 REWORK-1)の題材専用。/api/palette/translate をわざと
// 遅らせ、その往復の最中に「もう1文字打つ」隙間を作る。完了はさせない
// (完了させなくても、jobRunning=trueへ変わった直後の再締めが効いているか
// だけを見れば足りる。完了まで見るのは既存のJOB_IDが既に担っている)。
const RACE_JOB_ID = 'race00000000000000000000000000a';
const RACE_TRANSLATE_DELAY_MS = 350;

const projectJsonText = fs.readFileSync(projectJsonPath, 'utf8');

const openRequests = [];
let recentCalls = 0;
let pollCount = 0;

function readBody(req) {
  return new Promise(function (resolve) {
    let body = '';
    req.on('data', function (chunk) { body += chunk; });
    req.on('end', function () { resolve(body); });
  });
}

const server = http.createServer(async function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');

  if (url.pathname === '/palette') {
    let html = fs.readFileSync(path.join(wwwDir, 'palette.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'palette-handoff-token')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); return;
  }
  if (url.pathname === '/cat' || url.pathname === '/quick') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'palette-handoff-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS Pゴシック');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); return;
  }
  if (url.pathname.startsWith('/assets/')) {
    const asset = path.join(wwwDir, url.pathname.replace(/^\//, ''));
    if (fs.existsSync(asset)) { res.writeHead(200, { 'Content-Type': MIME[path.extname(asset)] || 'application/octet-stream' }); res.end(fs.readFileSync(asset)); return; }
    res.writeHead(404); res.end('not found'); return;
  }

  const body = await readBody(req);
  let payload = {};
  try { payload = JSON.parse(body || '{}'); } catch (parseError) {}

  if (url.pathname === '/api/ready-state') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ canTranslate: true, label: '準備完了', class: 'ok' })); return;
  }
  if (url.pathname === '/api/cat/recent') {
    recentCalls++;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ projects: [] })); return;
  }
  if (url.pathname === '/api/cat/open') {
    openRequests.push(payload);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(projectJsonText); return;
  }
  // 貼り付け(paste)からの通常のジョブ進行(A の busy 確認に使う)。
  if (url.pathname === '/api/palette/instant') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ direction: 'to_en', tm: null, terms: [] })); return;
  }
  if (url.pathname === '/api/palette/translate') {
    // MAJOR-A題材(RACETEST)だけ、応答をわざと遅らせる。それ以外は
    // 従来どおり即応答する(他の検証の待ち時間を増やさない)。
    if (String(payload.text || '').indexOf('RACETEST') >= 0) {
      setTimeout(function () {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ job_id: RACE_JOB_ID }));
      }, RACE_TRANSLATE_DELAY_MS);
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ job_id: JOB_ID })); return;
  }
  if (url.pathname === '/api/jobs/' + RACE_JOB_ID) {
    // わざと完了させない(見出しコメント参照)。ポーリング中(jobRunning=true)
    // であり続けることだけが要る。
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ mode: 'working', progress: 10, label: '翻訳中', detail: '', html: '' })); return;
  }
  if (url.pathname === '/api/jobs/' + JOB_ID) {
    pollCount++;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    if (pollCount < 2) { res.end(JSON.stringify({ mode: 'working', progress: 40, label: '翻訳中', detail: '', html: '' })); return; }
    res.end(JSON.stringify({
      mode: 'done', progress: 100, label: 'Done', class: 'ok',
      html: "<section class='result-stack' data-yaku-state='done'><article class='result-card result-card-translation' data-yaku-main-card><pre class='translation' data-yaku-main-text>Done.</pre></article></section>",
      source_text: 'busy probe source', masked_translation: 'Done.', direction: 'to_en', style: 'full'
    }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end('{}');
});

async function seedSessionStorage(page, key, value) {
  await page.evaluate(function (args) {
    if (args.value === null) { window.sessionStorage.removeItem(args.key); return; }
    window.sessionStorage.setItem(args.key, args.value);
  }, { key: key, value: value });
}

async function readSessionStorage(page, key) {
  return page.evaluate(function (k) { return window.sessionStorage.getItem(k); }, key);
}

(async function () {
  const out = { errors: [], console: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    const base = 'http://127.0.0.1:' + server.address().port;
    browser = await chromium.launch();

    // ==================================================== A) /palette
    const palettePage = await browser.newPage({ viewport: { width: 480, height: 640 } });
    palettePage.on('pageerror', function (error) { out.errors.push('palette:' + String((error && error.message) || error)); });
    palettePage.on('console', function (message) { if (message.type() === 'error') out.console.push('palette:' + message.text()); });
    // 実際のページ遷移はここでは起こさない(A の見出しコメント参照)。
    // location.assign はUnforgeable(仕様上、上書きできない)なので、
    // JS側での差し替えは効かない(実測: 上書きしたつもりで実際は無視され、
    // 本物の遷移が起きた)。遷移先の要求そのものをルーティングで止める。
    const assignCalls = [];
    await palettePage.route(function (url) { return url.pathname === '/cat' && url.searchParams.get('handoff') === 'palette'; }, function (route) {
      assignCalls.push(route.request().url().replace(base, ''));
      return route.abort();
    });
    await palettePage.goto(base + '/palette', { waitUntil: 'domcontentloaded' });
    await palettePage.waitForSelector('#palette-input');

    out.handoffDisabledWhenEmpty = await palettePage.$eval('#palette-handoff', function (node) { return node.disabled; });

    // 本文を打つ(貼り付けではない=自動翻訳を起こさない)。updateCount経由で
    // ボタンが押せるようになることだけを見る。
    await palettePage.fill('#palette-input', 'エスカレーション対象の長文本文です。');
    out.handoffEnabledWithText = await palettePage.$eval('#palette-handoff', function (node) { return !node.disabled; });

    // busy(翻訳ジョブ実行中)は押せない。貼り付けで実ジョブを起こす
    // (押す=遷移する検証より先にやる。押すと本物のナビゲーションが
    // 始まってしまい、そのあとはこのページを使えない)。
    await palettePage.evaluate(function () {
      var target = document.getElementById('palette-input');
      target.focus();
      target.value = 'busy probe source text';
      target.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', bubbles: true }));
    });
    await palettePage.waitForTimeout(80);
    out.handoffDisabledWhileJobRunning = await palettePage.$eval('#palette-handoff', function (node) { return node.disabled; });
    await palettePage.waitForSelector('#palette-result [data-yaku-main-card]', { timeout: 10000 });
    await palettePage.waitForTimeout(80);
    out.handoffEnabledAfterJobDone = await palettePage.$eval('#palette-handoff', function (node) { return !node.disabled; });

    // --- A': MAJOR-A(CoD審査 REWORK-1)。ジョブ開始の往復の最中に
    // もう1文字打つ隙間を作り、jobRunning=trueへ変わった瞬間に
    // updateHandoffButtonを呼び直しているかを見る(見出しコメント参照)。
    await palettePage.evaluate(function () {
      var target = document.getElementById('palette-input');
      target.focus();
      target.value = 'RACETEST race probe source text';
      target.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', bubbles: true }));
    });
    // startTranslationの同期部分(updateHandoffButton(true))が走った直後、
    // まだ/api/palette/translateの応答(RACE_TRANSLATE_DELAY_MS後)は
    // 届いていない=jobRunningはまだfalseのはずの窓。ここでもう1文字打ち、
    // updateCount()にbusy=jobRunning(false)で再計算させる
    // (打鍵後の一時的なdisabled=falseそのものは、この試験のassertの
    // 対象ではない——直せる弱点ではなく、直すのは「jobRunning=trueへ
    // 変わった瞬間に締め直しているか」のほう)。
    await palettePage.waitForTimeout(60);
    await palettePage.evaluate(function () {
      var target = document.getElementById('palette-input');
      target.value += '!';
      target.dispatchEvent(new InputEvent('input', { bubbles: true }));
    });
    // RACE_TRANSLATE_DELAY_MSより長く待ち、jobRunning=trueへ実際に変わった
    // (=ポーリング中になった)直後を狙ってサンプルする。打鍵はまだしない
    // ——ここでdisabled=falseなら、jobRunning=trueへ変わった箇所で
    // updateHandoffButtonを呼び直していない(MAJOR-A本体)。
    await palettePage.waitForTimeout(RACE_TRANSLATE_DELAY_MS + 150);
    out.handoffDisabledWhilePolling = await palettePage.$eval('#palette-handoff', function (node) { return node.disabled; });
    // ポーリング中(jobRunning=true)にもう1文字打っても、押せないままで
    // あること(既定のbusy=jobRunningの読みが正しく効いていることの傍証。
    // MAJOR-A自体の再現ではないが、直した箇所を挟んで壊していないかを見る)。
    await palettePage.evaluate(function () {
      var target = document.getElementById('palette-input');
      target.value += '?';
      target.dispatchEvent(new InputEvent('input', { bubbles: true }));
    });
    out.handoffDisabledWhileTypingDuringPolling = await palettePage.$eval('#palette-handoff', function (node) { return node.disabled; });
    // 後始末。Escでクリアし、次の検証(押す→退避)を汚さない
    // (RACE_JOB_IDはわざと完了させないので、Escで明示的にjobRunningを
    // falseへ戻す必要がある)。
    await palettePage.keyboard.press('Escape');
    await palettePage.waitForTimeout(50);

    // 押した本文へ戻す。方向を明示してから押す。
    await palettePage.fill('#palette-input', 'エスカレーション対象の長文本文です。');
    await palettePage.selectOption('#palette-direction-select', 'to_en');
    // クリックそのものと、退避された値の読み出しを、1回の evaluate の中で
    // 同期的に行う。location.assign() が投げるナビゲーションは別タスクとして
    // 後回しにされる(仕様上、この関数呼び出しの中では起きない)ため、
    // click() の直後に読めば退避された値は必ずまだ残っている。
    //
    // page.click() (実クリックの模擬、複数回のCDP往復を要する) や、
    // この後であらためて sessionStorage を読みにいく方式は使わない
    // ——ルーティングでナビゲーションを止めても(下のroute参照)、
    // Chromiumはその時点でページを「失敗した文書」の状態へ進めてしまい、
    // 以降の sessionStorage アクセスが SecurityError で拒否される
    // (実測: page.evaluate: SecurityError: Failed to read the
    // 'sessionStorage' property from 'Window': Access is denied for
    // this document.)。
    out.storedHandoffPayload = await palettePage.evaluate(function (key) {
      document.getElementById('palette-handoff').click();
      var raw = window.sessionStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    }, HANDOFF_KEY);
    await palettePage.waitForTimeout(150);
    out.assignCallsAfterClick = assignCalls.slice();

    try { await palettePage.close(); } catch (closeError) {}

    // ==================================================== B) /cat, キー欠落
    const catEmptyPage = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    catEmptyPage.on('pageerror', function (error) { out.errors.push('cat-empty:' + String((error && error.message) || error)); });
    catEmptyPage.on('console', function (message) { if (message.type() === 'error') out.console.push('cat-empty:' + message.text()); });
    const openCountBeforeEmpty = openRequests.length;
    await catEmptyPage.goto(base + '/cat?handoff=palette', { waitUntil: 'domcontentloaded' });
    await catEmptyPage.waitForSelector('#quick-input');
    await catEmptyPage.waitForTimeout(150);
    out.quickInputAfterEmptyKey = await catEmptyPage.$eval('#quick-input', function (node) { return node.value; });
    out.openRequestsAfterEmptyKey = openRequests.length - openCountBeforeEmpty;
    await catEmptyPage.close();

    // ==================================================== E) 壊れたJSON
    const catBrokenPage = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    catBrokenPage.on('pageerror', function (error) { out.errors.push('cat-broken:' + String((error && error.message) || error)); });
    catBrokenPage.on('console', function (message) { if (message.type() === 'error') out.console.push('cat-broken:' + message.text()); });
    // 同一origin内でまず素の/catを開き、そこでsessionStorageへ壊れたJSONを
    // 仕込んでから ?handoff=palette へ移る(同じタブ内の遷移ならsessionStorage
    // は引き継がれる。addInitScriptで仕込むと再読み込みのたびに再注入されて
    // しまい、後述Dの「2回目は何も起きない」を検証できなくなる)。
    await catBrokenPage.goto(base + '/cat', { waitUntil: 'domcontentloaded' });
    await seedSessionStorage(catBrokenPage, HANDOFF_KEY, 'これはJSONとして壊れています{{{');
    const openCountBeforeBroken = openRequests.length;
    await catBrokenPage.goto(base + '/cat?handoff=palette', { waitUntil: 'domcontentloaded' });
    await catBrokenPage.waitForSelector('#quick-input');
    await catBrokenPage.waitForTimeout(150);
    out.quickInputAfterBrokenJson = await catBrokenPage.$eval('#quick-input', function (node) { return node.value; });
    out.openRequestsAfterBrokenJson = openRequests.length - openCountBeforeBroken;
    await catBrokenPage.close();

    // ==================================================== C) + D) 本文あり・読み捨て
    const catPage = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    catPage.on('pageerror', function (error) { out.errors.push('cat:' + String((error && error.message) || error)); });
    catPage.on('console', function (message) { if (message.type() === 'error') out.console.push('cat:' + message.text()); });
    await catPage.goto(base + '/cat', { waitUntil: 'domcontentloaded' });
    const handoffText = 'パレットから昇格した長文の本文です。数値は伏せて送ります。';
    await seedSessionStorage(catPage, HANDOFF_KEY, JSON.stringify({ text: handoffText, direction_intent: 'to_en' }));

    const openCountBeforeFirst = openRequests.length;
    await catPage.goto(base + '/cat?handoff=palette', { waitUntil: 'domcontentloaded' });
    // quick-inputへの反映はstart()の同期部分で終わっている(dispatchEventは
    // 同期。openSourceの先の/api/cat/openだけが非同期)。
    out.quickInputAfterHandoff = await catPage.$eval('#quick-input', function (node) { return node.value; });
    // 既存受け口(yaku-instant-handoff)を経由した本当の往復が起きたことを、
    // 実際に飛んだ要求の中身で見る(字面の合成ではない)。
    await catPage.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    out.openRequestsAfterFirstHandoff = openRequests.slice(openCountBeforeFirst);
    out.sessionStorageAfterFirstHandoff = await readSessionStorage(catPage, HANDOFF_KEY);
    // URLの?handoff=paletteは、showPicker()内のsyncLocation('')が/cat
    // (クエリ無し)へreplaceStateした時点で既に消えている。その後、
    // 作業が開けるとrender()経由のsyncLocation(project.id)があらためて
    // /cat?project=<id>へpushStateする(戻る操作で?handoff=palette付きの
    // 状態へは戻らない——最終的なアドレスにそれが残っていないことで見る)。
    out.urlAfterFirstHandoff = catPage.url();

    // D) 読み捨て: 同じURLをもう一度開く(戻る/再読み込みを模す)。
    // sessionStorageは1回目で既に消えている前提。
    const openCountBeforeSecond = openRequests.length;
    await catPage.goto(base + '/cat?handoff=palette', { waitUntil: 'domcontentloaded' });
    await catPage.waitForSelector('#quick-input');
    await catPage.waitForTimeout(150);
    out.quickInputAfterSecondHandoff = await catPage.$eval('#quick-input', function (node) { return node.value; });
    out.openRequestsAfterSecondHandoff = openRequests.length - openCountBeforeSecond;
    await catPage.close();

    out.recentCallsTotal = recentCalls;
  } catch (error) {
    out.errors.push(String((error && error.stack) || error));
  } finally {
    try { if (browser) await browser.close(); } catch (closeError) {}
    try { server.close(); } catch (closeError) {}
  }
  fs.writeFileSync(outPath, JSON.stringify(out), 'utf8');
})();
