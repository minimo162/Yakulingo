'use strict';
/* 常設の体裁（格子の下のプレビュー）を、実機と同じ Chromium で実際に押して測る。
   観測した事実を JSON で返すだけで、合否は呼び出し側（PowerShell）が決める。

   www は**リポジトリの実物**を配る。写した複製を測ると、実物が壊れていても緑になる。
   /api/* だけを差し替える（tools/cat-screen/cat-screen-gate.js と同じ考え方）。 */
const http = require('http');
const fs = require('fs');
const path = require('path');

const wwwDir = process.argv[2];
const projectJson = fs.readFileSync(process.argv[3], 'utf8');
const outputPath = process.argv[4];

const types = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8', '.wasm': 'application/wasm' };

const server = http.createServer(function (req, res) {
  const p = new URL(req.url, 'http://127.0.0.1').pathname;
  if (p === '/cat' || p === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'gate-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0').replace(/__YAKU_IMPORT__/g, '0').replace(/__YAKU_VIEW__/g, '');
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
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (p === '/api/ready-state') { res.end(JSON.stringify({ canTranslate: true, label: 'Copilot ready', class: 'ok' })); return; }
  if (p === '/api/cat/recent') { res.end(JSON.stringify({ projects: [] })); return; }
  if (p === '/api/cat/resume') { res.end(projectJson); return; }
  if (p === '/api/cat/candidates') { res.end(JSON.stringify({ candidates: [] })); return; }
  res.end('{}');
});

(async function main() {
  const observed = { ok: false, error: '' };
  let browser = null;
  try {
    const { chromium } = require('playwright');
    await new Promise(function (r) { server.listen(0, '127.0.0.1', r); });
    const port = server.address().port;
    const id = JSON.parse(projectJson).id;

    browser = await chromium.launch();
    /* 利用者の機械で実測した窓（screen 1920x1200 / 最大化した窓 inner 1912x987）。
       1380 は「狭い版を踏ませたくて選んだ値」であって実機ではない
       （2026-08-16 に CLAUDE.md を訂正した）。 */
    const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + id, { waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr', { timeout: 15000 });

    observed.hiddenByDefault = await page.$eval('#cat-preview-dock', function (el) { return el.hidden; });
    observed.toggleLabelClosed = await page.$eval('#cat-preview-dock-toggle', function (el) { return el.textContent.trim(); });

    // 開く。details の中にあるので、まず開く。
    await page.evaluate(function () {
      const d = document.querySelector('.cat-more-actions'); if (d) d.open = true;
      document.getElementById('cat-preview-dock-toggle').click();
    });
    await page.waitForTimeout(300);

    observed.hiddenAfterToggle = await page.$eval('#cat-preview-dock', function (el) { return el.hidden; });
    observed.toggleLabelOpen = await page.$eval('#cat-preview-dock-toggle', function (el) { return el.textContent.trim(); });
    observed.bodyLength = await page.$eval('#cat-preview-dock-body', function (el) { return el.innerHTML.length; });
    observed.itemCount = await page.$$eval('#cat-preview-dock-body [data-cat-preview-index]', function (els) { return els.length; });

    // 仕切りの姿。Smartcat の実測は 4px・全幅・row-resize。
    observed.splitter = await page.$eval('#cat-preview-dock-splitter', function (el) {
      const cs = getComputedStyle(el);
      return {
        role: el.getAttribute('role'),
        ariaOrientation: el.getAttribute('aria-orientation'),
        tabindex: el.getAttribute('tabindex'),
        height: Math.round(el.getBoundingClientRect().height),
        cursor: cs.cursor,
        valuemin: el.getAttribute('aria-valuemin'),
        valuemax: el.getAttribute('aria-valuemax'),
        valuenow: el.getAttribute('aria-valuenow')
      };
    });

    /* **選択を動かしても組み直していないこと。** buildPreview() は全行ぶんの
       HTML を作るので、行を移るたびに走らせると行数に比例した費用を毎回払う。
       同じ HTML のままで印だけが動いていることを、文字列そのもので確かめる。 */
    /* **測り方に注意。** 「印を外した HTML が同じ」では組み直しを見つけられない。
       組み直しても同じ HTML が出るので、その表明はどちらでも緑になる（空振り）。
       **要素そのものが生き残っているか**で見る。innerHTML を入れ直すと、
       前に掴んでいたノードは文書から外れる（isConnected が false になる）。 */
    const before = await page.evaluate(function () {
      const body = document.getElementById('cat-preview-dock-body');
      const active = body.querySelector('.is-active');
      window.__yakuDockProbe = body.firstElementChild;
      return { index: active ? active.getAttribute('data-cat-preview-index') : null };
    });
    await page.evaluate(function () { document.querySelectorAll('[data-cat-input]')[1].focus(); });
    await page.waitForTimeout(300);
    const after = await page.evaluate(function () {
      const body = document.getElementById('cat-preview-dock-body');
      const active = body.querySelector('.is-active');
      const probe = window.__yakuDockProbe;
      return {
        index: active ? active.getAttribute('data-cat-preview-index') : null,
        probeStillConnected: !!(probe && probe.isConnected),
        probeIsStillFirst: !!(probe && probe === body.firstElementChild)
      };
    });
    observed.activeBefore = before.index;
    observed.activeAfter = after.index;
    observed.nodesSurvived = after.probeStillConnected && after.probeIsStillFirst;

    /* 対の表明。**組み直すと本当にノードが入れ替わることを、その場で示す。**
       これが無いと「isConnected はいつも true」という実装でも上が緑になる。 */
    observed.rebuildDetaches = await page.evaluate(function () {
      const body = document.getElementById('cat-preview-dock-body');
      const probe = body.firstElementChild;
      body.innerHTML = body.innerHTML;   // 同じ中身で組み直す
      return !(probe && probe.isConnected);
    });

    /* **掴めない人のための道（WCAG 2.2 SC 2.5.7）。** 矢印キーで高さが変わること。 */
    const heights = await page.evaluate(async function () {
      const sp = document.getElementById('cat-preview-dock-splitter');
      const dock = document.getElementById('cat-preview-dock');
      const read = function () { return dock.style.getPropertyValue('--cat-dock-height'); };
      const send = function (key, shift) { sp.dispatchEvent(new KeyboardEvent('keydown', { key: key, shiftKey: !!shift, bubbles: true })); };
      const start = read();
      send('ArrowUp'); const up = read();
      send('ArrowDown'); send('ArrowDown'); const down = read();
      send('Home'); const home = read();
      send('End'); const end = read();
      return { start: start, up: up, down: down, home: home, end: end, aria: sp.getAttribute('aria-valuenow') };
    });
    observed.keyboardResize = heights;

    // 畳めること。
    await page.evaluate(function () { document.getElementById('cat-preview-dock-close').click(); });
    await page.waitForTimeout(200);
    observed.hiddenAfterClose = await page.$eval('#cat-preview-dock', function (el) { return el.hidden; });

    observed.ok = true;
  } catch (error) {
    observed.error = String((error && error.stack) || error);
  } finally {
    try { if (browser) await browser.close(); } catch (_) {}
    try { server.close(); } catch (_) {}
  }
  fs.writeFileSync(outputPath, JSON.stringify(observed, null, 2), 'utf8');
  process.exit(observed.ok ? 0 : 1);
})();
