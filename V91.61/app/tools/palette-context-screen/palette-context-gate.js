'use strict';
/*
  パレットの文脈ポインタ(/palette)を、本物のChromiumで開いて確かめる。

  cat-screen-gate.js / palette-gate.js と同じ考え方（本物のhtml/js/cssを
  ローカルHTTPで配り、/api/* は決め打ちの応答で記録し、実際に押す・打つ）。
  判定はしない。観察した結果をJSONで書き出すだけ（呼び出し側のPowerShellが
  判定する、既存の流儀）。

  見る筋（設計仕様どおり）:
    - 起動時に /api/cat/recent の一覧が選べる形で並ぶ
    - 選ぶと localStorage へ id・表示名だけが残る(本文は残さない)
    - 選んだ状態で貼ると、/api/palette/instant へ context_project_id が乗る
    - 一致すれば project_hit が「この資料の確定訳」ラベルで候補1になり、
      同じ原文でTM完全一致(tm)も同時に返っていてもproject_hitが勝つ
      (既存のTM欄を奪い合う、新しいカードを増やさない)
    - Enter/1キーのコピーは既存の候補機構のまま(新しい配線を作らない)
    - 文脈を「なし」へ戻すと、以後の貼り付けは従来どおり(TMがそのまま出る)
    - 資料が一覧から消えていれば(recentに無い)、無言で「なし」へ戻り、
      localStorageの古い記録も消える(次回また出さない)
    - 資料が一覧にまだあれば、再読み込みだけで操作ゼロのまま選択が戻る

  使い方: node palette-context-gate.js <wwwDir> <outJson>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const outPath = process.argv[3];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

const PROJ_A_ID = 'aaaa1111aaaa1111aaaa1111aaaa1111';
const PROJ_B_ID = 'bbbb2222bbbb2222bbbb2222bbbb2222';
const STALE_ID = 'cccc3333cccc3333cccc3333cccc3333';

const CONTEXT_MATCH_TEXT = '御社の今期決算の言い回しは確定済みの表現でご案内します。';
const PROJECT_HIT_TARGET = 'We will describe this fiscal year\'s results using the finalized wording for this document.';
const TM_DECOY_TARGET = 'TM decoy translation (must not be shown once project_hit wins).';
const PROJECT_A_NAME = 'A社_決算資料.xlsx';

const recentRows = [
  { id: PROJ_A_ID, file_name: PROJECT_A_NAME, direction: 'to_en', source: 'text', revision: 1, total: 3, confirmed: 2, saved: '2026-08-18T00:00:00', source_preview: '御社の今期決算', export_blocked: false },
  { id: PROJ_B_ID, file_name: 'B社_契約書.xlsx', direction: 'to_en', source: 'file', revision: 1, total: 5, confirmed: 1, saved: '2026-08-17T00:00:00', source_preview: '契約書ドラフト', export_blocked: false }
];

const instantRequests = [];

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
    if (url.pathname === '/api/cat/recent') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ projects: recentRows })); return;
    }
    if (url.pathname === '/api/palette/instant') {
      let payload = {};
      try { payload = JSON.parse(body || '{}'); } catch (parseError) {}
      instantRequests.push(payload);
      const text = String(payload.text || '');
      const ctx = String(payload.context_project_id || '');
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      if (text === CONTEXT_MATCH_TEXT) {
        // TM完全一致(tm)は文脈の有無に関わらず常に引ける題材にする——
        // project_hitがある場合でも同時に返り、それでもproject_hitが勝つ
        // ことを見るため(サーバ側は両方を独立に計算する設計)。
        const tm = { source: text, target: TM_DECOY_TARGET, exact: true };
        const projectHit = (ctx === PROJ_A_ID) ? { source: text, target: PROJECT_HIT_TARGET, project_name: PROJECT_A_NAME } : null;
        res.end(JSON.stringify({ direction: 'to_en', tm: tm, terms: [], project_hit: projectHit }));
        return;
      }
      res.end(JSON.stringify({ direction: 'to_en', tm: null, terms: [], project_hit: null }));
      return;
    }
    if (url.pathname === '/api/palette/translate') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ job_id: 'deadbeef00000000000000000000009' }));
      return;
    }
    if (url.pathname === '/api/jobs/deadbeef00000000000000000000009') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ mode: 'done', progress: 100, label: 'Done', class: 'ok', html: '', source_text: '', masked_translation: '', direction: 'to_en', style: 'full' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end('{}');
  });
});

(async function () {
  const out = { errors: [], console: [] };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const baseUrl = 'http://127.0.0.1:' + server.address().port + '/palette';

    async function newPalettePage(initScript) {
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
      });
      if (initScript) await page.addInitScript(initScript);
      await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('#palette-input');
      return page;
    }

    async function pasteText(page, text) {
      await page.evaluate(function (value) {
        var target = document.getElementById('palette-input');
        target.focus();
        target.value = value;
        target.dispatchEvent(new InputEvent('input', { inputType: 'insertFromPaste', bubbles: true }));
      }, text);
    }

    async function copiedSnapshot(page) {
      return page.evaluate(function () { return window.__yakuCopied.slice(); });
    }

    // --- A) 起動時: 選べる資料が並ぶ -------------------------------------
    let page = await newPalettePage();
    await page.waitForFunction(function () {
      var sel = document.getElementById('palette-context-select');
      return !!sel && sel.options.length >= 3;
    }, { timeout: 5000 });
    out.initialOptionValues = await page.$$eval('#palette-context-select option', function (nodes) {
      return nodes.map(function (node) { return { value: node.value, text: node.textContent }; });
    });

    // --- B) 選ぶと localStorage へ id・表示名だけ ------------------------
    await page.selectOption('#palette-context-select', PROJ_A_ID);
    out.localStorageAfterSelect = await page.evaluate(function (key) {
      var raw = window.localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    }, 'yaku.palette.context');

    // --- C) 選んだ状態で貼る: project_hitが候補1、tmは同時に来ても負ける --
    instantRequests.length = 0;
    await pasteText(page, CONTEXT_MATCH_TEXT);
    await page.waitForSelector('#palette-tm-candidate[data-yaku-context-hit="1"]', { timeout: 5000 });
    out.instantRequestsWithContext = instantRequests.slice();
    out.cardAfterContextHit = await page.evaluate(function () {
      var card = document.getElementById('palette-tm-candidate');
      if (!card) return null;
      var kind = card.querySelector('.result-kind');
      return {
        hasContextHit: card.hasAttribute('data-yaku-context-hit'),
        candidateText: card.getAttribute('data-yaku-candidate-text'),
        candidateIndex: card.getAttribute('data-yaku-candidate-index'),
        kindText: kind ? kind.textContent : '',
        preText: card.querySelector('pre') ? card.querySelector('pre').textContent : ''
      };
    });
    out.hintTargetAfterContextHit = await page.$eval('#palette-hint-target', function (node) { return node.textContent; });

    await page.keyboard.press('1');
    await page.waitForTimeout(80);
    out.copiedAfterDigitOneContext = (await copiedSnapshot(page)).slice(-1)[0] || '';

    await page.keyboard.press('Enter');
    await page.waitForTimeout(80);
    out.copiedAfterEnterContext = (await copiedSnapshot(page)).slice(-1)[0] || '';

    // --- D) 「なし」へ戻す: 以後は従来どおり(TMがそのまま出る) -----------
    await page.selectOption('#palette-context-select', '');
    out.localStorageAfterNone = await page.evaluate(function (key) { return window.localStorage.getItem(key); }, 'yaku.palette.context');

    instantRequests.length = 0;
    await page.keyboard.press('Escape');
    await page.waitForTimeout(50);
    await pasteText(page, CONTEXT_MATCH_TEXT);
    await page.waitForSelector('#palette-tm-candidate', { timeout: 5000 });
    await page.waitForTimeout(150);
    out.instantRequestsWithoutContext = instantRequests.slice();
    out.cardAfterNoContext = await page.evaluate(function () {
      var card = document.getElementById('palette-tm-candidate');
      if (!card) return null;
      var kind = card.querySelector('.result-kind');
      return {
        hasContextHit: card.hasAttribute('data-yaku-context-hit'),
        candidateText: card.getAttribute('data-yaku-candidate-text'),
        kindText: kind ? kind.textContent : ''
      };
    });

    await page.close();

    // --- E) 資料が一覧から消えていた場合: 無言で「なし」へ、localStorageも消す --
    page = await browser.newPage({ viewport: { width: 480, height: 640 }, reducedMotion: 'reduce' });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    // page.addInitScriptは(script, arg)の2引数までしか渡せない(arg1個のみ)。
    // 3引数の呼び方(fn, a, b)は2つ目以降が無視される——ここで一度踏んだ実装地図
    // の罠なので、複数値は1つのオブジェクトへまとめて渡す。
    await page.addInitScript(function (seed) {
      try { window.localStorage.setItem(seed.key, JSON.stringify({ id: seed.id, name: '消えた資料.xlsx' })); } catch (error) {}
    }, { key: 'yaku.palette.context', id: STALE_ID });
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#palette-input');
    await page.waitForFunction(function () {
      var sel = document.getElementById('palette-context-select');
      return !!sel && sel.options.length >= 3;
    }, { timeout: 5000 });
    await page.waitForTimeout(150);
    out.selectValueAfterStale = await page.$eval('#palette-context-select', function (node) { return node.value; });
    out.localStorageAfterStale = await page.evaluate(function (key) { return window.localStorage.getItem(key); }, 'yaku.palette.context');
    await page.close();

    // --- F) 資料がまだ一覧にある場合: 再読み込みだけで操作ゼロのまま復元 ---
    page = await browser.newPage({ viewport: { width: 480, height: 640 }, reducedMotion: 'reduce' });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    await page.addInitScript(function (seed) {
      try { window.localStorage.setItem(seed.key, JSON.stringify({ id: seed.id, name: seed.name })); } catch (error) {}
    }, { key: 'yaku.palette.context', id: PROJ_A_ID, name: PROJECT_A_NAME });
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#palette-input');
    await page.waitForFunction(function () {
      var sel = document.getElementById('palette-context-select');
      return !!sel && sel.options.length >= 3;
    }, { timeout: 5000 });
    await page.waitForTimeout(150);
    out.selectValueAfterRestore = await page.$eval('#palette-context-select', function (node) { return node.value; });

    instantRequests.length = 0;
    await pasteText(page, CONTEXT_MATCH_TEXT);
    await page.waitForSelector('#palette-tm-candidate[data-yaku-context-hit="1"]', { timeout: 5000 });
    out.instantRequestsAfterRestore = instantRequests.slice();
    await page.close();
  } catch (error) {
    out.errors.push(String((error && error.stack) || error));
  } finally {
    try { if (browser) await browser.close(); } catch (closeError) {}
    try { server.close(); } catch (closeError) {}
  }
  fs.writeFileSync(outPath, JSON.stringify(out), 'utf8');
})();
