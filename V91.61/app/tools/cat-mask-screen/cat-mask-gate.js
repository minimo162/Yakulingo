'use strict';
/*
  マスク件数見える化(2026-08-18)を、本物の Chromium で確かめる。

  cat-screen-gate.js / palette-gate.js と同じ考え方（本物の cat.html/cat.js/
  cat-workspace.css をローカル HTTP で配り、/api/* は決め打ちの応答を返し、
  実際に押す・打つ）。ここでは題材を「翻訳完了時のマスク件数表示」一本に
  絞り、cat-screen-gate.js を肥大化させない。

  判定はしない。判定は呼び出し側の PowerShell が行う（既存の流儀）。

  見るのは4つ。
    (1) まとめて翻訳が終わると、#cat-mask-notice に「数値 N 件をマスクして
        送信しました。」が出る（サーバが返す masked_count をそのまま使う）
    (2) N=0 のときは「この翻訳で外部へ送った数値はありません。」と明示する
        （何も出さないのではない）
    (3) 出した通知は、その後の別の操作（この行を確認済みにする＝
        mutate('confirm', ...) の render()）でも消えない（自動で消えない）
    (4) 資料を切り替えると通知は消える。#cat-doc-switch(cat.html)を押して
        開くダイアログから、もう一方の資料(data-cat-doc-open、cat.js)を
        実際に押す。page.goto の再読み込みでは cat.js の render() 内の
        「資料が変わったら消す」分岐（previousProjectId !== 新id）を一度も
        通らないため、REWORK-1(MEDIUM-1)の指摘どおり in-app の切り替えで
        確かめる。/api/cat/recent は両方の資料を返す必要がある。

  使い方:
    node cat-mask-gate.js <wwwDir> <projectWithMaskPath> <projectZeroMaskPath> <outJson>

  projectWithMaskPath: ConvertTo-YakuCatProjectJson の出力。翻訳後に
    masked_count > 0 を返す題材で使う。切り替え元の資料でもある。
  projectZeroMaskPath: 同じ形。masked_count = 0 を返す題材で使う。
    切り替え先の資料として、翻訳もここで行う（2回目の goto は使わない）。
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const projectWithMaskPath = process.argv[3];
const projectZeroMaskPath = process.argv[4];
const outPath = process.argv[5];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

const projectWithMask = JSON.parse(fs.readFileSync(projectWithMaskPath, 'utf8'));
const projectZeroMask = JSON.parse(fs.readFileSync(projectZeroMaskPath, 'utf8'));
const MASKED_COUNT_NONZERO = 3;
const JOB_ID_NONZERO = 'aaaaaaaa00000000000000000000001';
const JOB_ID_ZERO = 'bbbbbbbb00000000000000000000002';

const projectsById = {};
projectsById[String(projectWithMask.id)] = projectWithMask;
projectsById[String(projectZeroMask.id)] = projectZeroMask;

// 直近に /api/cat/translate を受けた project id で、どちらのジョブID・
// masked_count を返すか決める（逐次実行前提、cat-screen-gate.js の
// 単純化と同じ考え方）。
let lastTranslateProjectId = '';

function readBody(req) {
  return new Promise(function (resolve) {
    let body = '';
    req.on('data', function (chunk) { body += chunk; });
    req.on('end', function () { resolve(body); });
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
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
      res.end(fs.readFileSync(file));
      return;
    }
    res.writeHead(404); res.end('not found'); return;
  }
  const body = await readBody(req);
  let parsed = null;
  try { parsed = body ? JSON.parse(body) : null; } catch (_) { parsed = null; }

  if (p === '/api/ready-state') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ canTranslate: true, label: '準備完了', class: 'ok' })); return;
  }
  if (p === '/api/cat/recent') {
    // 切り替えダイアログ(#cat-doc-switch)が両方の資料を選べる必要がある
    // （REWORK-1 MEDIUM-1）。本物の資料JSONをそのまま並べる（写経しない）。
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ projects: [projectWithMask, projectZeroMask] })); return;
  }
  if (p === '/api/cat/resume') {
    const wanted = parsed ? String(parsed.project_id || '') : '';
    const project = projectsById[wanted] || projectWithMask;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(project)); return;
  }
  if (p === '/api/cat/glossary' || p === '/api/cat/confirm' || p === '/api/cat/apply') {
    // このゲートは masked_count の見える化だけを見る。訳文の中身・確認状態の
    // 反映は別の題材（cat-screen-gate.js）が担うので、ここでは呼ばれた資料の
    // 現在の姿をそのまま返し、render() を素通りさせるだけにする。
    const wanted = parsed ? String(parsed.id || '') : '';
    const project = projectsById[wanted] || projectWithMask;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(project)); return;
  }
  if (p === '/api/cat/translate') {
    lastTranslateProjectId = parsed ? String(parsed.id || '') : '';
    const jobId = lastTranslateProjectId === String(projectZeroMask.id) ? JOB_ID_ZERO : JOB_ID_NONZERO;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end("<div class='result-loading job-loading' data-yaku-job-id='" + jobId + "' data-yaku-kind='cat'></div>");
    return;
  }
  if (p.startsWith('/api/jobs/')) {
    const jobId = decodeURIComponent(p.substring('/api/jobs/'.length));
    const isZero = jobId === JOB_ID_ZERO;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    // 実装と同じ枝(mode='done')を最初の応答から返す。ポーリングの往復回数は
    // この題材の関心事ではない（待つ側の作りは cat-screen-gate.js が別途見る）。
    res.end(JSON.stringify({
      jobId: jobId, mode: 'done', label: '完了', class: 'ok', detail: '', progress: 100,
      html: '', kind: 'cat', phase: '', unique_done: 1, unique_total: 1, updated_at: '',
      error_code: '', completion_status: '',
      masked_count: isZero ? 0 : MASKED_COUNT_NONZERO
    }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end('{}');
});

(async function () {
  const out = { errors: [], console: [] };
  await new Promise(function (r) { server.listen(0, '127.0.0.1', r); });
  const port = server.address().port;
  const browser = await chromium.launch();
  // 実機の窓 inner 1912x987（CLAUDE.md「画面を変えたら、実機で開いて確かめる」）。
  const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
  page.on('pageerror', function (e) { out.errors.push(String((e && e.message) || e)); });
  page.on('console', function (m) { if (m.type() === 'error') out.console.push(m.text()); });

  try {
    // -------------------------------------------------- (1)(3) masked_count > 0
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + encodeURIComponent(projectWithMask.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-workspace:not([hidden])', { timeout: 10000 });
    out.noticeBeforeTranslate = await page.$eval('#cat-mask-notice', function (el) { return el.textContent; });
    await page.waitForFunction(function () { var b = document.getElementById('cat-translate'); return b && !b.disabled; }, null, { timeout: 10000 });
    await page.click('#cat-translate');
    await page.waitForFunction(function () {
      var el = document.getElementById('cat-mask-notice');
      return !!(el && el.textContent && el.textContent.trim().length > 0);
    }, null, { timeout: 10000 });
    out.noticeAfterTranslate = await page.$eval('#cat-mask-notice', function (el) { return el.textContent; });

    // (3) 別の render() を経由する操作(行の確認)でも消えないこと。
    const confirmButton = await page.$('[data-cat-confirm]');
    out.confirmButtonFound = !!confirmButton;
    if (confirmButton) {
      await confirmButton.click();
      // mutate('confirm', ...) の render() が走り切るのを、確認状態の変化で待つ。
      await page.waitForFunction(function () {
        var row = document.querySelector('[data-cat-row="1"]');
        return !!(row && row.getAttribute('data-cat-confirmed') === '1');
      }, null, { timeout: 10000 }).catch(function () {});
      out.noticeAfterConfirm = await page.$eval('#cat-mask-notice', function (el) { return el.textContent; });
    } else {
      out.noticeAfterConfirm = null;
    }

    // -------------------------------------------------- (4) 資料を切り替えると消える
    // page.goto の再読み込みでは previousProjectId が常に空になり、cat.js の
    // render() 内「資料が変わったら消す」分岐を一度も通らない
    // （REWORK-1 MEDIUM-1: cat-doc-switch.js が同じ穴を踏んでいた）。
    // ここでは実際にダイアログを開いて、もう一方の資料を押す。
    await page.click('#cat-doc-switch');
    const otherId = String(projectZeroMask.id);
    const otherChoiceSelector = '#cat-doc-dialog-list [data-cat-doc-open="' + otherId + '"]';
    await page.waitForSelector(otherChoiceSelector, { timeout: 10000 });
    await page.click(otherChoiceSelector);
    // resume() の render() が終わり、URLのproject=が切り替わるまで待つ
    // （syncLocation、cat.js:197-206）。dialogが閉じることも確認する。
    await page.waitForFunction(function (id) { return location.search.indexOf(id) >= 0; }, otherId, { timeout: 10000 });
    await page.waitForFunction(function () { var d = document.getElementById('cat-doc-dialog'); return !d || !d.open; }, null, { timeout: 10000 });
    out.noticeAfterDocSwitch = await page.$eval('#cat-mask-notice', function (el) { return el.textContent; });

    // -------------------------------------------------- (2) masked_count = 0
    // 既に(4)で切り替え先の資料（projectZeroMask）を開いているので、
    // 2回目の goto は使わず、そのまま翻訳する。
    await page.waitForFunction(function () { var b = document.getElementById('cat-translate'); return b && !b.disabled; }, null, { timeout: 10000 });
    await page.click('#cat-translate');
    await page.waitForFunction(function () {
      var el = document.getElementById('cat-mask-notice');
      return !!(el && el.textContent && el.textContent.trim().length > 0);
    }, null, { timeout: 10000 });
    out.noticeZeroCase = await page.$eval('#cat-mask-notice', function (el) { return el.textContent; });
  } catch (e) {
    out.fatal = String((e && e.stack) || e);
  } finally {
    await browser.close();
    server.close();
  }

  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
})();
