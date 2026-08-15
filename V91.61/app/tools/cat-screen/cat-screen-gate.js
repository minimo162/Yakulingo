'use strict';
/*
  画面の描画と配線を、実機と同じ Chromium で確かめる。

  なぜ要るか。ここまで画面側の表明は `-match 'data-cat-split-at'` のような
  字面の在否だけだった。分割ボタンを描かなくしても、Alt+S を殺しても、
  Ctrl+H を殺しても、「訳文を置き換える」ボタンを runReplace から外しても、
  285件の表明が全部緑のまま通った（2026-08-15 の実測）。字面は
  「描かれているか」も「つながっているか」も見ていない。

  ここでやることは3つだけである。
    1. 本物の cat.html / cat.js / cat-workspace.css を、その場のローカル
       HTTP で配る（写経はしない）
    2. /api/* は決め打ちの応答を返し、来た要求を全部記録する
    3. 実際に押す・打つ。出た DOM と、飛んだ要求の中身を JSON で書き出す

  判定はしない。判定は呼び出し側の PowerShell が行う。

  使い方:
    node cat-screen-gate.js <wwwDir> <projectJson> <candidatesJson> <outJson> <previewProjectJson> <cellProjectJson> <qcProjectJson> <qcPreflightJson> <qcCleanProjectJson> <qcToolProjectJson> <qcNumericProjectJson>

  5番目は「体裁で見る」を見るための別の作業（貼り付け本文を原文の途中で
  割ったもの）。配置先が無い行なので、画面はサーバが繋いだ訳文を使うほかない。

  6番目は配置先のある cell 行の作業。1つの意味単位が2つのセル（A1・A2）へ
  分かれて載るので、画面は placement.destinations[].text をそのまま置くほか
  ない。行そのものの訳文（whole.translation）を置くと、A1 に全文が出て A2 が
  空になる。この枝には今まで振る舞いの門が1つも無く、text を空にしても
  全部緑のまま通った（2026-08-15 の実測）。

  7・8番目は「訳を入れただけ・未確定で、用語の点検に落ちる行」がある作業と、
  その作業に対して実装が作った出力前確認（preflight）の応答である。
  書き出しが止まった理由の文言は「左の『点検の指摘』を押すと、その行だけ
  表示できます」と案内するが、その絞り込みは segment.qc_findings の件数で
  出し入れしており、findings を行へ書くのは確定処理だけだった。つまり
  **未確定で止まった行では、案内先のボタンがそもそも描かれない**。
  ここでは実際に開いて、ボタンが出るか・押すと絞り込めるか・点検一覧が
  空でないかを見る。字面ではなく、描かれた DOM と押した結果で測る。

  9番目は「止める指摘は1つも無いが、未確認の行はある」作業。点検一覧の要約は
  枝が4本あり（まだ訳していない／止める指摘がある／未確認だけ／全部終わった）、
  7番目の題材は必ず2本目へ入る。3本目の文言を表明していた行は、到達できない
  枝を見ていたので**取り除いても緑のまま**だった（2026-08-15 の実測）。
  到達する題材をここで足して、その表明を生かす。

  10番目は「点検そのものが最後まで走らなかった」作業。サーバは種別を持たない
  ので validation-unavailable を合成する（src/CatProject.ps1 の
  Get-YakuCatOutputEligibility）。これは利用者の訳の欠陥ではなく道具の不調で、
  訳を直しても消えない。画面が赤（欠陥）で塗ると、直せないものを探させる。
  ここでは、その行の点検欄が道具の不調の見た目になっているかを見る。

  11番目は「数字の点検が最後まで走らなかった」作業。こちらは合成ではなく、
  点検の中の枝（Test-YakuNumericIntegrity が落ちたときの
  numeric-validation-error）である。src はこれも道具の不調と分類しているのに、
  画面は赤（訳の欠陥）で塗っていた（2026-08-16）。10番目の題材ではこの枝へ
  一度も入らないので、別の作業として開く。同じ画面で、取り出しボタンが
  従来どおり押せないことも採る。**色を変えても止める条件は変えていない。**
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const projectJson = fs.readFileSync(process.argv[3], 'utf8');
const candidatesJson = fs.readFileSync(process.argv[4], 'utf8');
const outputPath = process.argv[5];
const previewProjectJson = fs.readFileSync(process.argv[6], 'utf8');
const cellProjectJson = fs.readFileSync(process.argv[7], 'utf8');
const qcProjectJson = fs.readFileSync(process.argv[8], 'utf8');
const qcPreflightJson = fs.readFileSync(process.argv[9], 'utf8');
const qcCleanProjectJson = fs.readFileSync(process.argv[10], 'utf8');
const qcToolProjectJson = fs.readFileSync(process.argv[11], 'utf8');
const qcNumProjectJson = fs.readFileSync(process.argv[12], 'utf8');
const project = JSON.parse(projectJson);
const previewProject = JSON.parse(previewProjectJson);
const cellProject = JSON.parse(cellProjectJson);
const qcProject = JSON.parse(qcProjectJson);
const qcCleanProject = JSON.parse(qcCleanProjectJson);
const qcToolProject = JSON.parse(qcToolProjectJson);
const qcNumProject = JSON.parse(qcNumProjectJson);

/* 押した位置の題材。原文の <mark> より後ろに落ちる位置を選ぶ。
   1文字目（印より前）で一度押してから2回目を押すので、位置を拾えない実装だと
   1回目の位置が残ったまま割れる（それがこの試験で見たい壊れ方である）。 */
const FIRST_CLICK_CHAR = 1;
const SECOND_CLICK_CHAR = 12;

const seen = [];
const types = {
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.wasm': 'application/wasm'
};

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
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '');
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
  seen.push({ path: p, body: parsed });
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (p === '/api/ready-state') { res.end(JSON.stringify({ canTranslate: true, label: 'Copilot：準備完了', class: 'ok' })); return; }
  if (p === '/api/cat/recent') { res.end(JSON.stringify({ projects: [] })); return; }
  /* 開く作業は要求に書いてある id で選ぶ。決め打ちで1つだけ返すと、
     「体裁で見る」の題材を開いたつもりで別の作業を見ることになる。 */
  if (p === '/api/cat/resume') {
    const wanted = parsed ? String(parsed.project_id || '') : '';
    if (wanted && wanted === String(previewProject.id || '')) { res.end(previewProjectJson); return; }
    if (wanted && wanted === String(cellProject.id || '')) { res.end(cellProjectJson); return; }
    if (wanted && wanted === String(qcProject.id || '')) { res.end(qcProjectJson); return; }
    if (wanted && wanted === String(qcCleanProject.id || '')) { res.end(qcCleanProjectJson); return; }
    if (wanted && wanted === String(qcToolProject.id || '')) { res.end(qcToolProjectJson); return; }
    if (wanted && wanted === String(qcNumProject.id || '')) { res.end(qcNumProjectJson); return; }
    res.end(projectJson);
    return;
  }
  /* 出力前の確認。中身は実装（Get-YakuCatOutputPreflight）が作ったものを
     そのまま返す。手で書くと、止まった理由の文言を写経することになる。 */
  if (p === '/api/cat/preflight') { res.end(qcPreflightJson); return; }
  if (p === '/api/cat/candidates') { res.end(candidatesJson); return; }
  if (p === '/api/cat/split-at') { res.end(projectJson); return; }
  if (p === '/api/cat/replace-estimate') { res.end(JSON.stringify({ rows: 2, occurrences: 2, confirmed_rows: 0, scanned_rows: 2 })); return; }
  if (p === '/api/cat/replace') {
    const merged = JSON.parse(projectJson);
    merged.replace_rows = 2; merged.replace_occurrences = 2; merged.replace_unconfirmed = 0;
    res.end(JSON.stringify(merged));
    return;
  }
  res.end('{}');
});

function calls(name) { return seen.filter(function (s) { return s.path === '/api/cat/' + name; }); }
function lastBody(name) { const c = calls(name); return c.length ? c[c.length - 1].body : null; }

(async function () {
  const out = { errors: [], console: [], firstClickChar: FIRST_CLICK_CHAR, secondClickChar: SECOND_CLICK_CHAR };
  await new Promise(function (r) { server.listen(0, '127.0.0.1', r); });
  const port = server.address().port;
  const browser = await chromium.launch();
  /* 実機の窓幅は約 1380px（cat-workspace.css の @media 1400px に当たる）。 */
  const page = await browser.newPage({ viewport: { width: 1380, height: 900 } });
  page.on('pageerror', function (e) { out.errors.push(String((e && e.message) || e)); });
  page.on('console', function (m) { if (m.type() === 'error') out.console.push(m.text()); });
  const dialogs = [];
  page.on('dialog', function (d) { dialogs.push({ type: d.type(), message: d.message() }); d.accept().catch(function () {}); });

  try {
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + project.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });

    /* 押した位置を、アプリとは別に測るための覗き窓。capture で先に走らせるので、
       アプリ側の listener が何をしていても、ブラウザが決めたキャレット位置が取れる。
       「押した位置」と「アプリが記録した位置」を別々に採るのがこの試験の要点。 */
    await page.evaluate(function () {
      window.__probe = { offsets: [], targets: [] };
      document.addEventListener('mouseup', function (event) {
        var span = event.target.closest ? event.target.closest('span.cat-source-text') : null;
        window.__probe.targets.push({ tag: event.target.tagName, inSpan: !!span });
        if (!span) return;
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) { window.__probe.offsets.push(-1); return; }
        var r = sel.getRangeAt(0);
        var m = document.createRange();
        m.setStart(span, 0);
        m.setEnd(r.startContainer, r.startOffset);
        window.__probe.offsets.push(m.toString().length);
      }, true);
    });

    // -------------------------------------------------- 描画（分割ボタンが出るか）
    out.rows = await page.evaluate(function () {
      return Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
        return {
          index: Number(tr.getAttribute('data-cat-row')),
          active: tr.classList.contains('is-active'),
          source: tr.querySelector('.cat-source-text').textContent
        };
      });
    });
    function splitButtons() {
      return page.evaluate(function () {
        return Array.from(document.querySelectorAll('[data-cat-split-at]')).map(function (b) {
          return { index: b.getAttribute('data-cat-split-at'), text: b.textContent, keys: b.getAttribute('aria-keyshortcuts') };
        });
      });
    }
    out.splitButtonsOnSplittableRow = await splitButtons();

    // 割れない行へ移る（Alt+↓）。ボタンが出ないこと・Alt+S が断ることを見る。
    await page.keyboard.down('Alt'); await page.keyboard.press('ArrowDown'); await page.keyboard.up('Alt');
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr.is-active[data-cat-row="1"]'); }, null, { timeout: 10000 });
    out.splitButtonsOnUnsplittableRow = await splitButtons();
    await page.keyboard.down('Alt'); await page.keyboard.press('s'); await page.keyboard.up('Alt');
    await page.waitForTimeout(250);
    out.altSOnUnsplittableRow = { status: await page.textContent('#cat-status'), splitCalls: calls('split-at').length };

    // 割れる行へ戻る（Alt+↑）。用語の印が原文へ入るのを待つ。
    await page.keyboard.down('Alt'); await page.keyboard.press('ArrowUp'); await page.keyboard.up('Alt');
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr.is-active[data-cat-row="0"]'); }, null, { timeout: 10000 });
    await page.waitForFunction(function () {
      var host = document.querySelector('tr.is-active .cat-source-text');
      return !!(host && host.querySelector('mark.cat-term-hit'));
    }, null, { timeout: 10000 });
    out.splitButtonsBackOnSplittableRow = await splitButtons();
    out.marks = await page.evaluate(function () {
      var host = document.querySelector('tr.is-active .cat-source-text');
      return {
        count: host.querySelectorAll('mark.cat-term-hit').length,
        text: Array.from(host.querySelectorAll('mark.cat-term-hit')).map(function (m) { return m.textContent; }),
        plain: host.getAttribute('data-plain'),
        rendered: host.textContent,
        childNodes: host.childNodes.length,
        firstChildText: host.firstChild ? host.firstChild.textContent : ''
      };
    });

    // -------------------------------------------------- 押した位置で割れるか
    async function locateChar(index) {
      return await page.evaluate(function (i) {
        var host = document.querySelector('tr.is-active .cat-source-text');
        var walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT, null);
        var seenLen = 0, node = null, offset = 0;
        while (walker.nextNode()) {
          var t = walker.currentNode;
          if (seenLen + t.length > i) { node = t; offset = i - seenLen; break; }
          seenLen += t.length;
        }
        if (!node) return null;
        var r = document.createRange();
        r.setStart(node, offset); r.setEnd(node, offset + 1);
        var rect = r.getBoundingClientRect();
        var x = rect.left + 2, y = rect.top + rect.height / 2;
        var hit = document.elementFromPoint(x, y);
        return { x: x, y: y, onSpan: !!(hit && hit.closest && hit.closest('span.cat-source-text') === host), hitTag: hit ? hit.tagName : '' };
      }, index);
    }
    async function clickAtChar(index) {
      let box = await locateChar(index);
      if (!box) throw new Error('char rect not found: ' + index);
      if (!box.onSpan) {
        /* 行が固定ヘッダーの下に隠れていると、押した先がヘッダーになる。
           見えるところへ寄せてから測り直す（実測でここを踏んだ）。 */
        await page.evaluate(function () {
          document.querySelector('tr.is-active .cat-source-text').scrollIntoView({ block: 'center', behavior: 'instant' });
        });
        await page.waitForTimeout(150);
        box = await locateChar(index);
      }
      if (!box || !box.onSpan) throw new Error('char ' + index + ' is not clickable (hit=' + (box ? box.hitTag : 'none') + ')');
      await page.mouse.click(box.x, box.y);
      await page.waitForTimeout(150);
    }
    await clickAtChar(FIRST_CLICK_CHAR);
    await clickAtChar(SECOND_CLICK_CHAR);
    out.probe = await page.evaluate(function () { return { offsets: window.__probe.offsets.slice(), targets: window.__probe.targets.slice() }; });

    await page.keyboard.down('Alt'); await page.keyboard.press('s'); await page.keyboard.up('Alt');
    await page.waitForTimeout(600);
    out.altSSplit = {
      calls: calls('split-at').length,
      body: lastBody('split-at'),
      dialog: dialogs.length ? dialogs[dialogs.length - 1].message : '',
      status: await page.textContent('#cat-status')
    };

    // -------------------------------------------------- Ctrl+H（検索と置換を開く）
    await page.evaluate(function () { var m = document.getElementById('cat-search-menu'); if (m) m.open = false; });
    await page.keyboard.press('Control+h');
    await page.waitForTimeout(250);
    out.ctrlH = await page.evaluate(function () {
      var m = document.getElementById('cat-search-menu');
      return { menuOpen: !!(m && m.open), focused: document.activeElement ? document.activeElement.id : '' };
    });
    /* Ctrl+H が効かないと帯が閉じたままで、この先の「押す」が全部 30 秒待ちの
       時間切れになる。何が壊れているかが時間切れの山に埋もれるので、観測だけ
       先に採ってから手で開ける。Ctrl+H が効いたかどうかは上の1行が持っている。 */
    if (!out.ctrlH.menuOpen) {
      await page.evaluate(function () { var m = document.getElementById('cat-search-menu'); if (m) m.open = true; });
      await page.waitForTimeout(200);
    }

    // -------------------------------------------------- 「訳文を置き換える」の配線
    await page.fill('#cat-search', 'The Company');
    await page.waitForTimeout(400);
    out.replaceReady = await page.evaluate(function () {
      var b = document.getElementById('cat-replace-run');
      return { disabled: !!b.disabled, label: b.textContent, summary: document.getElementById('cat-replace-summary').textContent };
    });
    await page.click('#cat-replace-run');
    await page.waitForTimeout(900);
    out.replaceRun = {
      estimateCalls: calls('replace-estimate').length,
      estimateBody: lastBody('replace-estimate'),
      replaceCalls: calls('replace').length,
      replaceBody: lastBody('replace'),
      dialog: dialogs.length ? dialogs[dialogs.length - 1].message : ''
    };

    // -------------------------------------------------- 探す場所が「原文だけ」のとき
    await page.click('[data-cat-search-scope="source"]');
    await page.waitForTimeout(400);
    const beforeEstimate = calls('replace-estimate').length;
    const beforeReplace = calls('replace').length;
    out.scopeSource = await page.evaluate(function () {
      var b = document.getElementById('cat-replace-run');
      return { disabled: !!b.disabled, label: b.textContent, summary: document.getElementById('cat-replace-summary').textContent };
    });
    /* ボタンが無効でも、配線そのものを試す。3つある歯止めのうち runReplace の
       1つだけが残っているかどうかは、押してみないと分からない。 */
    await page.evaluate(function () {
      document.getElementById('cat-replace-run').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await page.waitForTimeout(800);
    out.scopeSourceForcedClick = {
      estimateCalls: calls('replace-estimate').length - beforeEstimate,
      replaceCalls: calls('replace').length - beforeReplace,
      status: await page.textContent('#cat-status')
    };

    // -------------------------------------------------- 「体裁で見る」（配置先の無い行）
    /* 別の作業を開き直す。貼り付け本文を原文の途中で割ったもので、配置先
       （placement.destinations）が無い。配置先のある cell 行はサーバが計算した
       destination.text を使うので前から正しかった。壊れていたのはこちらで、
       画面だけが part 1 の訳文を描き、後半の訳が消えていた。 */
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + previewProject.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    out.previewRows = await page.evaluate(function () {
      return Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
        return {
          index: Number(tr.getAttribute('data-cat-row')),
          source: tr.querySelector('.cat-source-text').textContent
        };
      });
    });
    /* 「体裁で見る」は「そのほか」の折りたたみの中にある。実際に開いて押す。 */
    await page.click('details.cat-more-actions > summary');
    await page.click('#cat-preview-open');
    await page.waitForSelector('#cat-preview-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(250);
    function previewBody() {
      return page.evaluate(function () {
        var host = document.getElementById('cat-preview-body');
        return {
          open: !!document.getElementById('cat-preview-dialog').open,
          blocks: Array.from(host.querySelectorAll('button')).map(function (b) { return b.textContent; }),
          missing: Array.from(host.querySelectorAll('button.is-missing')).length,
          cells: host.querySelectorAll('.cat-preview-cell').length,
          /* 窓に出ている文字そのもの。繋ぎ方の規則（`AB-1234` か `AB- 1234` か）は
             1つの塊の中で起きるので、塊ごとの一致だけでなく地の文でも見る。 */
          text: host.textContent,
          /* 配置先のあるセルは、番地ごとに1つの押しボタンになる。どこに何が
             出たかを見るため、番地と文字と「訳文が無い扱い」を組で採る。 */
          cellTexts: Array.from(host.querySelectorAll('.cat-preview-cell')).map(function (b) {
            var td = b.closest ? b.closest('td') : null;
            var tr = td && td.closest ? td.closest('tr') : null;
            var column = td && tr ? Array.prototype.indexOf.call(tr.children, td) : -1;
            var head = tr && tr.querySelector('th') ? tr.querySelector('th').textContent : '';
            return { text: b.textContent, missing: b.classList.contains('is-missing'), row: head, column: column };
          }),
          paragraphs: Array.from(host.querySelectorAll('.cat-preview-paragraph')).map(function (b) { return b.textContent; }),
          sheets: Array.from(host.querySelectorAll('.cat-preview-sheet h3')).map(function (h) { return h.textContent; })
        };
      });
    }
    out.previewTarget = await previewBody();
    await page.click('[data-cat-preview-side="source"]');
    await page.waitForTimeout(250);
    out.previewSource = await previewBody();

    // -------------------------------------------------- 「体裁で見る」（配置先のある cell 行）
    /* もう1つ別の作業を開く。1つの意味単位が A1・A2 の2セルへ分かれて載るので、
       画面が置ける文字列は placement.destinations[].text しかない。行そのものの
       訳文には「どこで切るか」が入っていないからである。ここは今まで振る舞いの
       門が無く、text を空にしても全部緑のまま通った枝である。 */
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + cellProject.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    out.cellRows = await page.evaluate(function () {
      return Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
        return {
          index: Number(tr.getAttribute('data-cat-row')),
          source: tr.querySelector('.cat-source-text').textContent
        };
      });
    });
    await page.click('details.cat-more-actions > summary');
    await page.click('#cat-preview-open');
    await page.waitForSelector('#cat-preview-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(250);
    out.cellPreviewTarget = await previewBody();
    await page.click('[data-cat-preview-side="source"]');
    await page.waitForTimeout(250);
    out.cellPreviewSource = await previewBody();

    // ------------------------------- 止まった行の案内先が、実際に開くか
    /* 題材: 2行とも訳文は入っていて未確定。1行目だけが用語の点検に落ちる。
       確定処理を1度も通していないので、行の qc_findings は両方とも空である。
       それでも書き出しは止まる（サーバが写しに点検を掛けているため）。
       このとき案内文が指す「点検の指摘」が本当に出るかを見る。 */
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + qcProject.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    out.qcScreen = await page.evaluate(function () {
      var filter = document.querySelector('[data-cat-filter="qc"]');
      var count = document.querySelector('[data-cat-count="qc"]');
      var exportButton = document.getElementById('cat-export');
      return {
        rows: Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
          return { index: Number(tr.getAttribute('data-cat-row')), source: tr.querySelector('.cat-source-text').textContent };
        }),
        /* hidden 属性だけでなく、実際に画面上で面積を持っているかも見る。
           CSS で消しても緑になる門にしない。 */
        filterHidden: !filter || filter.hidden,
        filterVisible: !!(filter && filter.getClientRects().length > 0),
        filterLabel: filter ? filter.textContent : '',
        filterCount: count ? count.textContent : '',
        qaButtonLabel: document.getElementById('cat-qa-open').textContent,
        qaButtonHasBlockers: document.getElementById('cat-qa-open').classList.contains('cat-qa-has-blockers'),
        exportDisabled: !!(exportButton && exportButton.disabled),
        exportTitle: exportButton ? exportButton.title : '',
        outputReason: document.getElementById('cat-output-reason').textContent
      };
    });

    /* 押して絞り込む。出るだけで押せない／押しても絞れない実装を落とす。
       ボタンが隠れていると click は 30 秒待って時間切れになり、その先の
       観測が全部 undefined になる。何が壊れているかが時間切れの山に埋もれるので、
       隠れているかどうかは上の1行が持たせたうえで、手で見えるようにしてから
       押す（既存の Ctrl+H と同じ手当て）。件数も絞り込み結果も、これで
       誤魔化されはしない。 */
    await page.evaluate(function () {
      var filter = document.querySelector('[data-cat-filter="qc"]');
      if (filter && filter.hidden) filter.hidden = false;
    });
    await page.click('[data-cat-filter="qc"]');
    await page.waitForTimeout(300);
    out.qcFiltered = await page.evaluate(function () {
      return {
        rows: Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
          return { index: Number(tr.getAttribute('data-cat-row')), source: tr.querySelector('.cat-source-text').textContent };
        }),
        pressed: document.querySelector('[data-cat-filter="qc"]').getAttribute('aria-pressed'),
        emptyHidden: document.getElementById('cat-empty-state').hidden
      };
    });

    /* 絞り込んだ行を開いて、右の点検欄に何が出るか。絞り込みが空振りしたときは
       ここに行が1つも無い。時間切れで先を潰さず、観測を続ける。 */
    const qcHasRow = await page.evaluate(function () { return !!document.querySelector('#cat-grid-body tr[data-cat-row] textarea[data-cat-input]'); });
    if (qcHasRow) { await page.focus('#cat-grid-body tr[data-cat-row] textarea[data-cat-input]'); }
    else { out.qcNoRowAfterFilter = true; await page.click('[data-cat-filter="all"]'); await page.waitForTimeout(250); await page.focus('#cat-grid-body tr[data-cat-row] textarea[data-cat-input]'); }
    await page.waitForTimeout(200);
    await page.click('[data-cat-inspector="qc"]');
    await page.waitForTimeout(250);
    function qcInspectorBody() {
      return page.evaluate(function () {
      var host = document.getElementById('cat-qc-list');
      return {
        count: document.getElementById('cat-qc-count').textContent,
        cards: Array.from(host.querySelectorAll('.cat-qc-card')).map(function (card) {
          return {
            text: card.textContent,
            preview: card.getAttribute('data-cat-qc-preview') === '1',
            /* 何色で塗られたか。cat.js の qcGroup が 'error'（訳の欠陥）と
               'tool'（道具の不調）を分けており、そのどちらになったかは
               class にしか出ない。文言だけ見ても色は分からない。 */
            classes: card.className,
            /* 用語の免除は訳文を書き換える操作である。見るだけの場面で出て
               いないことを、ボタンの実在で測る。 */
            exceptionButtons: card.querySelectorAll('[data-cat-term-exception]').length
          };
        }),
        activeRow: (function () {
          var active = document.querySelector('#cat-grid-body tr.is-active');
          return active ? Number(active.getAttribute('data-cat-row')) : -1;
        })(),
        /* 読み上げ環境にも同じことが伝わっているか。訳文欄の aria-invalid と
           aria-describedby は行の指摘から作られるので、指摘が0件のままだと
           「問題なし」と読み上げられていた。 */
        inputInvalid: (function () {
          var input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
          return input ? input.getAttribute('aria-invalid') : '';
        })(),
        rowFindingText: (function () {
          var row = document.querySelector('#cat-grid-body tr.is-active');
          var host = row ? row.querySelector('.cat-qc-findings') : null;
          return host ? host.textContent : '';
        })()
      };
      });
    }
    out.qcInspector = await qcInspectorBody();

    // 道具の帯の「点検」（F8 と同じ入口）。ここが実際に開く一覧である。
    await page.click('#cat-qa-open');
    await page.waitForSelector('#cat-qa-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(300);
    function qaBody() {
      return page.evaluate(function () {
        var host = document.getElementById('cat-qa-list');
        return {
          open: !!document.getElementById('cat-qa-dialog').open,
          /* 要約は #cat-qa-list の**兄弟**（cat.html の #cat-qa-summary）なので、
             下の text には絶対に入らない。要約の文言を測るときは必ずこちらを見る。
             2026-08-15 に、要約の枝を見るつもりの表明が text を見ており、
             原理的に落ちない状態になっていた。 */
          summary: document.getElementById('cat-qa-summary').textContent,
          groups: Array.from(host.querySelectorAll('.cat-qa-group h3')).map(function (h) { return h.textContent; }),
          /* 群ごとの内訳。「一覧が空でない」だけを見ると、未確認の群だけで
             満たされてしまい、写しの点検（qc_preview）を1文字も見ない表明になる。
             見出しの数字（cat.js が group.items.length をそのまま書く）と、
             その群に属する行だけを別々に採る。合流を落とす改変では、
             `自動点検の指摘` の群そのものが描かれなくなる（cat.js の
             openQaList が items.length===0 の群を捨てるため）。 */
          groupDetails: Array.from(host.querySelectorAll('.cat-qa-group')).map(function (section) {
            var head = section.querySelector('h3');
            var badge = head ? head.querySelector('span') : null;
            var title = '';
            if (head) { title = String((head.firstChild && head.firstChild.textContent) || head.textContent || '').trim(); }
            return {
              title: title,
              count: badge ? Number(badge.textContent) : -1,
              blocking: section.classList.contains('is-blocking'),
              items: Array.from(section.querySelectorAll('.cat-qa-item')).map(function (b) { return b.textContent; })
            };
          }),
          items: Array.from(host.querySelectorAll('.cat-qa-item')).map(function (b) { return b.textContent; }),
          text: host.textContent
        };
      });
    }
    out.qaList = await qaBody();
    await page.evaluate(function () { document.getElementById('cat-qa-dialog').close('cancel'); });
    await page.waitForTimeout(200);

    /* 書き出しの窓そのもの。止まっているとボタンは無効なので、配線だけを試す
       （既存の「無理やり押す」と同じ手）。同じ窓の中で「用語で N 行止まって
       います」と「直すところは見つかりませんでした」が同時に出ていた、
       という矛盾がここで消えたかを見る。 */
    await page.evaluate(function () {
      document.getElementById('cat-export').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
    await page.waitForSelector('#cat-export-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(250);
    out.qcExportDialog = await page.evaluate(function () {
      return {
        open: !!document.getElementById('cat-export-dialog').open,
        checks: Array.from(document.querySelectorAll('#cat-export-checks .cat-preflight-item')).map(function (d) { return d.textContent; }),
        qaHidden: document.getElementById('cat-export-qa').hidden,
        confirmDisabled: !!document.getElementById('cat-export-confirm').disabled
      };
    });
    // その窓のボタンで一覧を開く。ここが「必ず開く明細表」に当たる。
    await page.click('#cat-export-qa');
    await page.waitForSelector('#cat-qa-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(300);
    out.qaFromExport = await qaBody();

    // --------------- 止める指摘は無いが、未確認の行はある（要約の3本目の枝）
    /* 題材: 2行とも訳文が入っていて、点検に落ちる行が1つも無い。未確認は2行。
       上の題材（blocking>=1）では決して入らない枝なので、別の作業で開く。 */
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + qcCleanProject.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    out.qcCleanScreen = await page.evaluate(function () {
      var filter = document.querySelector('[data-cat-filter="qc"]');
      var count = document.querySelector('[data-cat-count="qc"]');
      return {
        rows: Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
          return { index: Number(tr.getAttribute('data-cat-row')), source: tr.querySelector('.cat-source-text').textContent };
        }),
        /* 指摘が1件も無いときは、この絞り込みは隠れているのが正しい。
           上の題材で「出る」ことだけを見ていると、常時出す実装でも緑になる。 */
        filterHidden: !filter || filter.hidden,
        filterCount: count ? count.textContent : '',
        qaButtonLabel: document.getElementById('cat-qa-open').textContent,
        qaButtonHasBlockers: document.getElementById('cat-qa-open').classList.contains('cat-qa-has-blockers'),
        exportDisabled: !!document.getElementById('cat-export').disabled
      };
    });
    await page.click('#cat-qa-open');
    await page.waitForSelector('#cat-qa-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(300);
    out.qaCleanList = await qaBody();
    await page.evaluate(function () { document.getElementById('cat-qa-dialog').close('cancel'); });
    await page.waitForTimeout(200);

    // ------------------- 点検そのものが走らなかった行（道具の不調）の見た目
    /* 題材: サーバ側で点検が例外になり、種別が取れなかった作業。
       サーバは validation-unavailable を合成して qc_preview へ載せる。
       この種別は「訳を直しても消えない」ので、訳の欠陥（赤）と同じ顔で
       出してはいけない。ここでは点検欄の card の class を見る。 */
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + qcToolProject.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    await page.focus('#cat-grid-body tr[data-cat-row] textarea[data-cat-input]');
    await page.waitForTimeout(200);
    await page.click('[data-cat-inspector="qc"]');
    await page.waitForTimeout(250);
    out.qcToolInspector = await qcInspectorBody();
    await page.click('#cat-qa-open');
    await page.waitForSelector('#cat-qa-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(300);
    out.qaToolList = await qaBody();
    await page.evaluate(function () { document.getElementById('cat-qa-dialog').close('cancel'); });
    await page.waitForTimeout(200);

    // --------- 数字の点検そのものが落ちた行（道具の不調。合成ではなく点検の枝）
    /* 題材: Test-YakuNumericIntegrity が落ちた作業。点検は
       numeric-validation-error を積む（src/CatProject.ps1 の
       Invoke-YakuCatSegmentValidation）。これも訳を直しても消えないので、
       赤（訳の欠陥）で塗ってはいけない。上の validation-unavailable とは
       別の枝なので、同じ観測点（点検欄の card の class）で別に見る。
       あわせて、取り出しボタンが従来どおり押せないことも採る。
       **色を変えても止める条件は変えていない**ことを、同じ画面で示すため。 */
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + qcNumProject.id, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    out.qcNumScreen = await page.evaluate(function () {
      var exportButton = document.getElementById('cat-export');
      return {
        rows: Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) {
          return { index: Number(tr.getAttribute('data-cat-row')), source: tr.querySelector('.cat-source-text').textContent };
        }),
        exportDisabled: !!(exportButton && exportButton.disabled),
        exportTitle: exportButton ? exportButton.title : ''
      };
    });
    await page.focus('#cat-grid-body tr[data-cat-row] textarea[data-cat-input]');
    await page.waitForTimeout(200);
    await page.click('[data-cat-inspector="qc"]');
    await page.waitForTimeout(250);
    out.qcNumInspector = await qcInspectorBody();
  } catch (e) {
    out.fatal = String((e && e.stack) || e);
  } finally {
    try { await browser.close(); } catch (_) {}
    server.close();
  }
  fs.writeFileSync(outputPath, JSON.stringify(out, null, 1), 'utf8');
})();
