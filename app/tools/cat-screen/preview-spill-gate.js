'use strict';
/*
  体裁プレビューの「右隣空白へのはみ出し描き」を、本物の cat.html / cat.js を
  headless Chromium で開いて測る運転席（tools/fit-screen/fit-screen-gate.js と
  同じ形。判定はしない。判定は呼び出し側の PowerShell が行う）。

  ここでやることは3つだけ:
    1. 本物の cat.html / cat.js / cat-workspace.css / styles.css / common.js /
       quick.js を、その場のローカル HTTP で配る（写経はしない）
    2. /api/* は決め打ちの応答を返す
    3. 「体裁で見る」を実際に開き、セルごとに次を実測して JSON で書き出す
       - ボタン・文字・内側span（cat-spill-flow）の矩形と、途中の切り抜き箱
         （overflow が visible 以外の祖先の右端。どの切り抜きも文字の右端より
          右にあれば、そこまで描き切れている）
       - is-spill クラス・computed style の overflow
       - 自セルの右外で elementFromPoint が何を指すか（当たり判定。
         Range の矩形はレイアウト箱であって塗りの切り抜きを映さない
         （2026-08-23 実測: overflow:hidden の内側の文で 矩形right 298.9px /
          クリップ右端 68px）。だから「切れて見えるか」は、切り抜き箱の計算と
          当たり判定の組で採る）
       - 全セルボタンの中心が自分自身で受けること（はみ出しspanが押し場を
         奪っていないこと。pointer-events:none の効き目の実測）

  使い方:
    node preview-spill-gate.js <wwwDir> <payloadJsonPath> <outJsonPath> [viewport]

  payloadJson は { main: <project> } の形。viewport は "1912x987"（既定）。
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const payloadJsonPath = process.argv[3];
const outputPath = process.argv[4];
const viewportArg = String(process.argv[5] || '1912x987');
const viewportParts = viewportArg.split('x');
const viewport = { width: Number(viewportParts[0]) || 1912, height: Number(viewportParts[1]) || 987 };

const payload = JSON.parse(fs.readFileSync(payloadJsonPath, 'utf8'));
const mainProjectJson = JSON.stringify(payload.main);

const types = {
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8'
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
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'spill-test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
      /* previewOutputFont() の配線先。実測値の再現（canvas 計測）と同じ書体にする。 */
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS Pゴシック');
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
  await readBody(req);
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (p === '/api/ready-state') { res.end(JSON.stringify({ canTranslate: true, label: 'ready', class: 'ok' })); return; }
  if (p === '/api/cat/recent') { res.end(JSON.stringify({ projects: [] })); return; }
  if (p === '/api/cat/resume') { res.end(mainProjectJson); return; }
  res.end('{}');
});

(async function () {
  const out = { errors: [], console: [], viewport: viewport };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: viewport });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(payload.main.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });

    // 「体裁で見る」はツールバーに直接見えているので、そのまま押す。
    await page.click('#cat-preview-open');
    await page.waitForSelector('#cat-preview-dialog[open]', { timeout: 10000 });
    await page.waitForFunction(function () {
      return document.querySelectorAll('#cat-preview-body .cat-preview-cell').length > 0;
    }, null, { timeout: 10000 });
    await page.waitForTimeout(250);

    const probe = await page.evaluate(function () {
      /* どのセルボタンも、自分の中心の当たり判定を他人に奪われていないこと。
         はみ出し描きの内側spanが押し場を奪うと、右の狭いセルが押せなくなる
         （実機実測 2026-08-23）。span 自身は pointer-events:none なので、
         中心で当たる要素は自分（または自分より後ろの空セル）であるはずだ。 */
      var notReceivable = [];
      Array.from(document.querySelectorAll('#cat-preview-body .cat-preview-cell')).forEach(function (btn) {
        btn.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        var r = btn.getBoundingClientRect();
        var el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        if (!el || !(el === btn || btn.contains(el))) {
          notReceivable.push({ index: Number(btn.getAttribute('data-cat-preview-index')), tag: el ? el.tagName : null, cls: el ? String(el.className || '').slice(0, 60) : '' });
        }
      });
      return { notReceivable: notReceivable, cells: Array.from(document.querySelectorAll('#cat-preview-body .cat-preview-cell')).map(function (btn) {
        btn.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        var rect = btn.getBoundingClientRect();
        var flow = btn.querySelector('.cat-spill-flow');
        var host = flow || btn;
        var range = document.createRange();
        range.selectNodeContents(host);
        var textRect = range.getBoundingClientRect();
        /* 自セルの右外を歩き、上に来る要素が自分の中身のときを記録する。
           塗りの当たり判定（要素の箱）であり、字面そのものではない。
           内側spanが無いセルでは、ボタンの箱より右に自分の部品は出ない。 */
        var sweepLastInsideDx = null;
        var midY = Math.min(Math.max(textRect.top + textRect.height / 2, 1), window.innerHeight - 1);
        for (var x = Math.ceil(rect.right) + 2; x <= Math.min(window.innerWidth - 2, rect.left + 1200); x += 2) {
          var el = document.elementFromPoint(x, midY);
          if (el && (el === btn || (el.nodeType === 1 && btn.contains(el)))) sweepLastInsideDx = Math.round(x - rect.right);
        }
        var beyond = document.elementFromPoint(Math.min(rect.right + 6, window.innerWidth - 2), midY);
        var cs = getComputedStyle(btn);
        /* 文字がそこまで届くための切り抜きの有無。ボタンからプレビューの
           本体（縦横スクロールする箱）までの間で、overflow が visible 以外の
           祖先はその右端を記録する。どの切り抜きも文字の右端より右にあれば、
           描き切れている。 */
        var clips = [];
        var walker = btn.parentElement;
        var body = document.getElementById('cat-preview-body');
        while (walker) {
          var wcs = getComputedStyle(walker);
          if (wcs.overflowX !== 'visible' || wcs.overflowY !== 'visible') {
            var wr = walker.getBoundingClientRect();
            clips.push({ tag: walker.tagName, id: walker.id || '', cls: String(walker.className || '').slice(0, 60), overflowX: wcs.overflowX, right: wr.right, bottom: wr.bottom });
          }
          if (walker === body) break;
          walker = walker.parentElement;
        }
        return {
          index: Number(btn.getAttribute('data-cat-preview-index')),
          text: btn.textContent,
          isSpill: btn.classList.contains('is-spill'),
          hasFlow: !!flow,
          overflowRiskClass: btn.classList.contains('is-overflow-risk'),
          ariaLabel: btn.getAttribute('aria-label') || '',
          title: btn.getAttribute('title') || '',
          rect: { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom },
          textRect: { left: textRect.left, right: textRect.right, top: textRect.top, height: textRect.height },
          flowRect: flow ? (function () { var fr = flow.getBoundingClientRect(); return { left: fr.left, right: fr.right }; })() : null,
          flowStyleWidth: flow ? flow.getAttribute('style') : '',
          overflowStyle: cs.overflow,
          whiteSpaceStyle: cs.whiteSpace,
          scrollWidth: btn.scrollWidth,
          clientWidth: btn.clientWidth,
          sweepLastInsideDx: sweepLastInsideDx,
          hitBeyondSelf: beyond ? { tag: beyond.tagName, cls: String(beyond.className || '').slice(0, 60), ours: beyond === btn || btn.contains(beyond) } : null,
          clips: clips,
          onScreen: rect.width > 0 && rect.right < window.innerWidth - 2 && rect.bottom < window.innerHeight - 2
        };
      }) };
    });
    out.notReceivable = probe.notReceivable;
    out.cells = probe.cells;
  } catch (error) {
    out.fatal = String((error && error.stack) || error);
  } finally {
    if (browser) await browser.close().catch(function () {});
    await new Promise(function (resolve) { server.close(resolve); });
    fs.writeFileSync(outputPath, JSON.stringify(out, null, 1), 'utf8');
  }
  if (out.errors.length || out.console.length || out.fatal) process.exitCode = 1;
})();
