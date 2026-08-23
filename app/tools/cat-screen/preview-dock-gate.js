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

    /* premium の広い作業画面では、体裁を格子の下の**常設ドック**へ戻す。
       右レールでは高さを変える既存の仕切りが効かず、畳む道も消えていた。
       cat.js の restoreDockState() と premium-ui.js の初回表示はそのまま使い、
       仕切り（#cat-preview-dock-splitter）と「畳む」（#cat-preview-dock-close）を
       実際に見える状態にして、ポインターとキーボードの両方で高さを変えられる
       ことを測る。 */
    await page.waitForFunction(function () {
      var dock = document.getElementById('cat-preview-dock');
      return !!dock && dock.hidden;
    }, null, { timeout: 15000 });
    observed.dockVisibleByDefault = false;
    observed.dockHiddenByDefault = true;
    await page.locator('#cat-preview-dock-toggle').click();
    await page.waitForFunction(function () {
      var dock = document.getElementById('cat-preview-dock');
      return !!dock && !dock.hidden && dock.getClientRects().length > 0;
    }, null, { timeout: 15000 });
    observed.dockState = await page.evaluate(function () {
      var dock = document.getElementById('cat-preview-dock');
      var rect = dock.getBoundingClientRect();
      var splitter = document.getElementById('cat-preview-dock-splitter');
      var closeButton = document.getElementById('cat-preview-dock-close');
      var activeTab = document.querySelector('.cat-bottom-dock-bar [data-cat-inspector][aria-selected="true"]');
      return {
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        activeTab: activeTab ? activeTab.getAttribute('data-cat-inspector') : null,
        toggleAriaPressed: document.getElementById('cat-preview-dock-toggle').getAttribute('aria-pressed'),
        inspectorToggleText: document.getElementById('cat-inspector-toggle').textContent,
        splitterDisplay: getComputedStyle(splitter).display,
        splitterHeight: Math.round(splitter.getBoundingClientRect().height),
        splitterCursor: getComputedStyle(splitter).cursor,
        splitterValueMin: splitter.getAttribute('aria-valuemin'),
        splitterValueMax: splitter.getAttribute('aria-valuemax'),
        closeButtonDisplay: getComputedStyle(closeButton).display,
        closeButtonText: closeButton.textContent.trim()
      };
    });

    await page.locator('#cat-preview-dock-splitter').focus();
    const resizeStart = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    await page.keyboard.press('ArrowUp');
    const resizeUp = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    await page.keyboard.press('ArrowDown');
    const resizeDown = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    await page.keyboard.press('Home');
    const resizeHome = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    await page.keyboard.press('End');
    const resizeEnd = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    observed.keyboardResize = { start: resizeStart, up: resizeUp, down: resizeDown, home: resizeHome, end: resizeEnd,
      aria: await page.locator('#cat-preview-dock-splitter').getAttribute('aria-valuenow') };

    await page.locator('#cat-preview-dock-close').click();
    await page.waitForFunction(function () { return document.getElementById('cat-preview-dock').hidden; }, null, { timeout: 10000 });
    observed.collapse = await page.evaluate(function () {
      return {
        hidden: document.getElementById('cat-preview-dock').hidden,
        expanded: document.getElementById('cat-inspector-toggle').getAttribute('aria-expanded'),
        storedOpen: window.localStorage.getItem('yaku-cat-dock-open')
      };
    });
    await page.locator('#cat-preview-dock-toggle').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-preview-dock').hidden; }, null, { timeout: 10000 });
    observed.restore = await page.evaluate(function () {
      return {
        hidden: document.getElementById('cat-preview-dock').hidden,
        expanded: document.getElementById('cat-inspector-toggle').getAttribute('aria-expanded'),
        storedOpen: window.localStorage.getItem('yaku-cat-dock-open')
      };
    });

    /* **選択を動かしても組み直していないこと。** buildPreview() は全行ぶんの
       HTML を作るので、行を移るたびに走らせると行数に比例した費用を毎回払う。
       同じ HTML のままで印だけが動いていることを、文字列そのもので確かめる。 */
    /* **測り方に注意。** 「印を外した HTML が同じ」では組み直しを見つけられない。
       組み直しても同じ HTML が出るので、その表明はどちらでも緑になる（空振り）。
       **要素そのものが生き残っているか**で見る。innerHTML を入れ直すと、
       前に掴んでいたノードは文書から外れる（isConnected が false になる）。 */
    /* **選び方はキーボード（Alt+↓）。** premium の表は選択中の行だけを描くため、
       ほかの行の訳文欄は DOM にはあっても display:none で、focus を当てても
       選択は動かない（2026-08-23 実測）。 */
    const before = await page.evaluate(function () {
      const body = document.getElementById('cat-preview-dock-body');
      const active = body.querySelector('.is-active');
      window.__yakuDockProbe = body.firstElementChild;
      return { index: active ? active.getAttribute('data-cat-preview-index') : null };
    });
    await page.keyboard.down('Alt'); await page.keyboard.press('ArrowDown'); await page.keyboard.up('Alt');
    await page.waitForFunction(function () {
      var tr = document.querySelector('#cat-grid-body tr.is-active');
      return !!(tr && tr.getAttribute('data-cat-row') === '1');
    }, null, { timeout: 10000 });
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

    /* 対の表明。**組み直すと本当にノードは入れ替わることを、その場で示す。**
       これが無いと「isConnected はいつも true」という実装でも上が緑になる。 */
    observed.rebuildDetaches = await page.evaluate(function () {
      const body = document.getElementById('cat-preview-dock-body');
      const probe = body.firstElementChild;
      body.innerHTML = body.innerHTML;   // 同じ中身で組み直す
      return !(probe && probe.isConnected);
    });

    // 中身の確認は最後に。上の対の表明が本文を入れ替えたあとであるため。
    observed.bodyLength = await page.$eval('#cat-preview-dock-body', function (el) { return el.innerHTML.length; });
    observed.itemCount = await page.$$eval('#cat-preview-dock-body [data-cat-preview-index]', function (els) { return els.length; });

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
