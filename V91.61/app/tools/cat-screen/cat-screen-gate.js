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
    node cat-screen-gate.js <wwwDir> <projectJson> <candidatesJson> <outJson>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const projectJson = fs.readFileSync(process.argv[3], 'utf8');
const candidatesJson = fs.readFileSync(process.argv[4], 'utf8');
const outputPath = process.argv[5];
const project = JSON.parse(projectJson);

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
  if (p === '/api/cat/resume') { res.end(projectJson); return; }
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
  } catch (e) {
    out.fatal = String((e && e.stack) || e);
  } finally {
    try { await browser.close(); } catch (_) {}
    server.close();
  }
  fs.writeFileSync(outputPath, JSON.stringify(out, null, 1), 'utf8');
})();
