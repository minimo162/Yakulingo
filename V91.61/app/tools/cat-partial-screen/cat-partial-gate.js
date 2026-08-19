'use strict';
/*
  CAT翻訳の部分結果先出しを、本物の Chromium で確かめる。

  cat-mask-screen/cat-mask-gate.js と同じ考え方（本物の cat.html/cat.js/
  cat-workspace.css をローカル HTTP で配り、/api/* は決め打ちの応答を返し、
  実際に押す・打つ）。判定はしない。判定は呼び出し側の PowerShell が行う。

  見るのは6つ（(a)〜(f)、Test-YakuV9204CatPartialPreview.ps1 のコメント参照）。
  ジョブは2本使う。1本目(JOB_ID_DONE)は working→working→done→apply まで進め、
  2本目(JOB_ID_CANCEL、別の資料)は working→cancelled で止める。

  working の1回目・2回目は、応答に partial_rows を混ぜる:
    1回目: index=0（正しいsource）だけ。押す前に index=1 の訳文欄へ
      あらかじめ「人が打った」値を入れておき、2回目の応答に index=1（source は
      正しい）を混ぜても上書きされないことを見る((b))。
    2回目: index=1（source正しいが訳文欄が非空）と index=2（source不一致）を
      混ぜる。どちらも触られないことを見る((b)(c))。

  使い方:
    node cat-partial-gate.js <wwwDir> <projectDonePath> <projectCancelPath>
      <projectDoneAppliedPath> <outJson>

  projectDonePath: 先出し前の姿(ConvertTo-YakuCatProjectJson)。3セグメント、
    すべて訳文が空。
  projectDoneAppliedPath: apply後の「正本」の姿。同じ資料IDで、3行とも
    先出しの値とは別の文字列に訳文が入っている。
  projectCancelPath: 別資料。3セグメント、すべて訳文が空。
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const projectDonePath = process.argv[3];
const projectCancelPath = process.argv[4];
const projectDoneAppliedPath = process.argv[5];
const outPath = process.argv[6];

const MIME = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

const projectDone = JSON.parse(fs.readFileSync(projectDonePath, 'utf8'));
const projectCancel = JSON.parse(fs.readFileSync(projectCancelPath, 'utf8'));
const projectDoneApplied = JSON.parse(fs.readFileSync(projectDoneAppliedPath, 'utf8'));

const JOB_ID_DONE = 'aaaaaaaa111111111111111111111111';
const JOB_ID_CANCEL = 'bbbbbbbb222222222222222222222222';

const projectsById = {};
projectsById[String(projectDone.id)] = projectDone;
projectsById[String(projectCancel.id)] = projectCancel;

// どちらの資料を翻訳中か（直近の /api/cat/translate 呼び出し）で、どちらの
// ジョブ台本を再生するか決める（逐次実行前提、cat-mask-gate.js と同じ単純化）。
let lastTranslateProjectId = '';
const pollCountByJob = {};
const observedPartialAfterByJob = {};

function readBody(req) {
  return new Promise(function (resolve) {
    let body = '';
    req.on('data', function (chunk) { body += chunk; });
    req.on('end', function () { resolve(body); });
  });
}

function doneWorkingRow(index, source, text) {
  return { index: index, source: source, text: text };
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
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ projects: [projectDone, projectCancel] })); return;
  }
  if (p === '/api/cat/resume') {
    const wanted = parsed ? String(parsed.project_id || '') : '';
    const project = projectsById[wanted] || projectDone;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(project)); return;
  }
  if (p === '/api/cat/glossary' || p === '/api/cat/confirm') {
    // このゲートは部分結果先出しだけを見る。用語集・確認の中身は別の題材
    // （cat-screen-gate.js）が担うので、呼ばれた資料の現在の姿をそのまま返す。
    const wanted = parsed ? String(parsed.id || '') : '';
    const project = projectsById[wanted] || projectDone;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(project)); return;
  }
  if (p === '/api/cat/apply') {
    // (e) done→apply後は正本で上書きされる。JOB_ID_DONE の apply だけ、
    // 先出しの値とは別の文字列を持つ「正本」を返す。
    const jobId = parsed ? String(parsed.job_id || '') : '';
    if (jobId === JOB_ID_DONE) {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(projectDoneApplied)); return;
    }
    const wanted = parsed ? String(parsed.id || '') : '';
    const project = projectsById[wanted] || projectDone;
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(project)); return;
  }
  if (p === '/api/cat/translate') {
    lastTranslateProjectId = parsed ? String(parsed.id || '') : '';
    const jobId = lastTranslateProjectId === String(projectCancel.id) ? JOB_ID_CANCEL : JOB_ID_DONE;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end("<div class='result-loading job-loading' data-yaku-job-id='" + jobId + "' data-yaku-kind='cat'></div>");
    return;
  }
  if (p.startsWith('/api/jobs/')) {
    const jobId = decodeURIComponent(p.substring('/api/jobs/'.length));
    const partialAfterRaw = url.searchParams.has('partial_after') ? url.searchParams.get('partial_after') : null;
    const tick = pollCountByJob[jobId] || 0;
    pollCountByJob[jobId] = tick + 1;
    observedPartialAfterByJob[jobId] = observedPartialAfterByJob[jobId] || [];
    observedPartialAfterByJob[jobId].push(partialAfterRaw);

    const base = {
      jobId: jobId, label: '翻訳中', class: 'warn', detail: '', kind: 'cat', phase: 'translating',
      unique_done: 0, unique_total: 3, updated_at: '', error_code: '', completion_status: '', masked_count: 0
    };

    if (jobId === JOB_ID_DONE) {
      const srcDone = projectDone.segments;
      if (tick === 0) {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(Object.assign({}, base, {
          mode: 'working', progress: 40,
          partial_total: 1, partial_expected_total: 3,
          partial_rows: [doneWorkingRow(0, srcDone[0].source, 'Translated shipment zero.')]
        })));
        return;
      }
      if (tick === 1) {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(Object.assign({}, base, {
          mode: 'working', progress: 70,
          partial_total: 3, partial_expected_total: 3,
          partial_rows: [
            // (b) 訳文欄が既に非空(人が打った)なので触られてはならない。
            doneWorkingRow(1, srcDone[1].source, 'should not appear (index1)'),
            // (c) source が現在のプロジェクトの原文と一致しないので触られてはならない。
            doneWorkingRow(2, 'WRONG SOURCE TEXT THAT WILL NEVER MATCH', 'should not appear (index2)')
          ]
        })));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(Object.assign({}, base, {
        mode: 'done', label: '完了', class: 'ok', progress: 100, html: "<div class='alert alert-info'>完了しました。</div>",
        unique_done: 3,
        partial_total: 3, partial_expected_total: 3, partial_rows: []
      })));
      return;
    }

    if (jobId === JOB_ID_CANCEL) {
      const srcCancel = projectCancel.segments;
      if (tick === 0) {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(Object.assign({}, base, {
          mode: 'working', progress: 40,
          partial_total: 1, partial_expected_total: 3,
          partial_rows: [doneWorkingRow(0, srcCancel[0].source, 'Translated cancel zero.')]
        })));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(Object.assign({}, base, {
        mode: 'cancelled', label: '', progress: 40,
        partial_total: 1, partial_expected_total: 3, partial_rows: []
      })));
      return;
    }

    res.writeHead(404); res.end('{}'); return;
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
    // -------------------------------------------------- (a)(b)(c)(d) working中
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + encodeURIComponent(projectDone.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-workspace:not([hidden])', { timeout: 10000 });
    await page.waitForFunction(function () { return !!document.querySelector('[data-cat-row="0"] textarea[data-cat-input]'); }, null, { timeout: 10000 });

    // (d)の前提: working中に触るのはindex=0の行だけなので、他の行のDOM要素を
    // ここで捕まえておき、あとで参照の同一性を見る。
    await page.evaluate(function () {
      window.__n9204Probe = {};
      [0, 1, 2].forEach(function (i) {
        var row = document.querySelector('[data-cat-row="' + i + '"]');
        var input = row ? row.querySelector('textarea[data-cat-input]') : null;
        window.__n9204Probe[i] = { row: row, input: input };
      });
    });

    // (b) の前提: index=1 の訳文欄へ、押す前に「人が打った」値を入れておく。
    // input/changeを発火させず、そのままにする（renderRows由来のdirty化を避ける）。
    await page.evaluate(function () {
      var input = document.querySelector('[data-cat-row="1"] textarea[data-cat-input]');
      if (input) input.value = 'manually typed by user';
    });

    await page.waitForFunction(function () { var b = document.getElementById('cat-translate'); return b && !b.disabled; }, null, { timeout: 10000 });
    await page.click('#cat-translate');

    // tick0 (index=0のみ)が反映されるのを待つ。
    await page.waitForFunction(function () {
      var input = document.querySelector('[data-cat-row="0"] textarea[data-cat-input]');
      return !!(input && input.value === 'Translated shipment zero.');
    }, null, { timeout: 10000 });

    out.row0Value = await page.$eval('[data-cat-row="0"] textarea[data-cat-input]', function (el) { return el.value; });
    out.row0HasPartialClass = await page.$eval('[data-cat-row="0"]', function (el) { return el.classList.contains('cat-partial-preview'); });
    out.row0BadgeFound = await page.$eval('[data-cat-row="0"] .cat-target', function (el) { return !!el.querySelector('.cat-partial-badge'); });
    out.domIdentityAfterTick0 = await page.evaluate(function () {
      var ok = true;
      [0, 1, 2].forEach(function (i) {
        var row = document.querySelector('[data-cat-row="' + i + '"]');
        var input = row ? row.querySelector('textarea[data-cat-input]') : null;
        if (window.__n9204Probe[i].row !== row || window.__n9204Probe[i].input !== input) ok = false;
      });
      return ok;
    });

    // tick1 (index=1,2の混在)が反映されるのを待つ。partial_total=3が
    // 進捗ブロックに出た時点で、まだ次のtick(done)は起きていない
    // （clientの1秒ポーリング間隔の中で、ここが唯一安全に覗ける窓）。
    await page.waitForFunction(function () {
      var el = document.querySelector('.job-partial-progress');
      return !!(el && el.textContent.indexOf('3/3') >= 0);
    }, null, { timeout: 10000 });

    out.row1ValueAfterTick = await page.$eval('[data-cat-row="1"] textarea[data-cat-input]', function (el) { return el.value; });
    out.row1HasPartialClassAfterTick = await page.$eval('[data-cat-row="1"]', function (el) { return el.classList.contains('cat-partial-preview'); });
    out.row2ValueAfterTick = await page.$eval('[data-cat-row="2"] textarea[data-cat-input]', function (el) { return el.value; });
    out.row2HasPartialClassAfterTick = await page.$eval('[data-cat-row="2"]', function (el) { return el.classList.contains('cat-partial-preview'); });
    var domIdentityAfterTick1 = await page.evaluate(function () {
      var ok = true;
      [0, 1, 2].forEach(function (i) {
        var row = document.querySelector('[data-cat-row="' + i + '"]');
        var input = row ? row.querySelector('textarea[data-cat-input]') : null;
        if (window.__n9204Probe[i].row !== row || window.__n9204Probe[i].input !== input) ok = false;
      });
      return ok;
    });
    out.domIdentityPreservedAfterTicks = !!(out.domIdentityAfterTick0 && domIdentityAfterTick1);

    // (MINOR-2) working中でも絞り込みボタンはdisabledにならず
    // （setBusyはtextarea/inputだけを読み取り専用にする）、押すと
    // redrawAfterFlush→renderRows()が走る。renderRows()自体はDOMを
    // 作り直す正当な再描画（tickからの毎秒再描画とは別物）なので、
    // ここでのDOM要素同一性の喪失は想定どおり——だから(d)のDOM同一性
    // 検証(tick前後の要素参照比較)より後で行う。見るのは、作り直された
    // 後の行にも先出しの内容（値・印）が残っていること。
    await page.click('[data-cat-filter="all"]');
    await page.waitForFunction(function () {
      var b = document.querySelector('[data-cat-filter="all"]');
      return !!(b && b.getAttribute('aria-pressed') === 'true');
    }, null, { timeout: 10000 });
    out.row0ValueAfterFilterClick = await page.$eval('[data-cat-row="0"] textarea[data-cat-input]', function (el) { return el.value; });
    out.row0HasPartialClassAfterFilterClick = await page.$eval('[data-cat-row="0"]', function (el) { return el.classList.contains('cat-partial-preview'); });

    // -------------------------------------------------- (e) done -> apply -> render
    await page.waitForFunction(function () {
      var input = document.querySelector('[data-cat-row="0"] textarea[data-cat-input]');
      return !!(input && input.value === 'Final applied zero.');
    }, null, { timeout: 10000 });
    out.row0ValueAfterApply = await page.$eval('[data-cat-row="0"] textarea[data-cat-input]', function (el) { return el.value; });
    out.row0HasPartialClassAfterApply = await page.$eval('[data-cat-row="0"]', function (el) { return el.classList.contains('cat-partial-preview'); });
    out.row0BadgeFoundAfterApply = await page.$eval('[data-cat-row="0"] .cat-target', function (el) { return !!el.querySelector('.cat-partial-badge'); });

    // partial_after を観測した通りに記録(実装前確認3の裏付け)。
    var seq = observedPartialAfterByJob[JOB_ID_DONE] || [];
    out.observedPartialAfterFirstMissingOrZero = (seq.length > 0) && (seq[0] === null || seq[0] === '0');
    out.observedPartialAfterSecond = seq.length > 1 ? seq[1] : null;
    out.observedPartialAfterThird = seq.length > 2 ? seq[2] : null;

    // -------------------------------------------------- (f) キャンセル後も先出しが残る
    await page.goto('http://127.0.0.1:' + port + '/cat?project=' + encodeURIComponent(projectCancel.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-workspace:not([hidden])', { timeout: 10000 });
    await page.waitForFunction(function () { var b = document.getElementById('cat-translate'); return b && !b.disabled; }, null, { timeout: 10000 });
    await page.click('#cat-translate');
    await page.waitForFunction(function () {
      var input = document.querySelector('[data-cat-row="0"] textarea[data-cat-input]');
      return !!(input && input.value === 'Translated cancel zero.');
    }, null, { timeout: 10000 });
    // cancelled tick後、ジョブ帯が消えて既存のキャンセル文言が出るのを待つ。
    await page.waitForFunction(function () {
      var s = document.getElementById('cat-status');
      return !!(s && s.textContent && s.textContent.indexOf('保存されています') >= 0);
    }, null, { timeout: 10000 });
    out.cancelRow0Value = await page.$eval('[data-cat-row="0"] textarea[data-cat-input]', function (el) { return el.value; });
    out.cancelRow0HasPartialClass = await page.$eval('[data-cat-row="0"]', function (el) { return el.classList.contains('cat-partial-preview'); });
    out.cancelStatusText = await page.$eval('#cat-status', function (el) { return el.textContent; });
  } catch (e) {
    out.fatal = String((e && e.stack) || e);
  } finally {
    await browser.close();
    server.close();
  }

  fs.writeFileSync(outPath, JSON.stringify(out, null, 2), 'utf8');
})();
