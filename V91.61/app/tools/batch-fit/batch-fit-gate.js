'use strict';
/*
  まとめて収める（V9201）を、本物の cat.html / cat.js を headless Chromium で
  開いて確かめる運転席（tools/fit-screen/fit-screen-gate.js と同じ形）。

  判定はしない。判定は呼び出し側の PowerShell が行う。ここでやることは3つだけ:
    1. 本物の cat.html / cat.js / cat-workspace.css / styles.css / common.js を
       その場のローカル HTTP で配る
    2. /api/* は決め打ちの応答を返す（Copilotは呼ばない。ジョブ完了を
       fetchスタブで順に返す）。同時に複数ジョブが飛んでいないかを
       サーバ側の到着順イベントログで見る
    3. 実際に開く・押す。出た DOM と、飛んだ要求の中身・順序を JSON で書き出す

  使い方:
    node batch-fit-gate.js <wwwDir> <outJsonPath>
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const outputPath = process.argv[3];

const types = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };

function longText(seed) {
  return 'This translated sentence is deliberately long enough to overflow a narrow column regardless of exact font metrics used to measure it, seed ' + seed + ' padding padding.';
}

function makeSegment(index, id, addr, opts) {
  opts = opts || {};
  var translation = opts.translation !== undefined ? opts.translation : longText(id);
  var seg = {
    index: index, segment_id: id, source: 'src ' + id, translation: translation,
    kind: 'cell', location: 'S1, ' + addr, confirmed: false
  };
  if (opts.placement !== false) {
    seg.placement = { destinations: [{ sheet: 'S1', address: addr, text: translation, mode: 'replace_source_block' }] };
  }
  return seg;
}

// 各区画は3列: anchor(width1) / neighbor(widthW、開いている) / stopper(占有、
// ここで自動spillの歩きを止める)。stopperを置かないと、右の列が全部
// 「中身の無い列」に見えて隣の区画まで歩き続けてしまう（実測で確認した。
// previewLayout の lastContentColumn は occupied_cells 等からしか求まらず
// [cat.js:2736-2749]、columns の定義だけでは決まらないため）。
function columnBlock(startCol, neighborWidth) {
  return [
    { min: startCol, max: startCol, width: 1, hidden: false },
    { min: startCol + 1, max: startCol + 1, width: neighborWidth, hidden: false }
  ];
}
// ---- projectA: 直列性・JOB_RUNNINGリトライ・対象選定・max_chars・要約・
//      キャッシュ再利用・鮮度・適用失敗フォールバックを1つの資料で見る。
var columnsA = [].concat(
  columnBlock(1, 40),   // idx0 A1/B1, stopper C1
  columnBlock(4, 40),   // idx1 D1/E1, stopper F1
  columnBlock(7, 40),   // idx2 G1/H1, stopper I1
  columnBlock(10, 90),  // idx3 J1/K1, stopper L1 (neighborが広い。max_charsがidx0と違う値になる)
  columnBlock(13, 40)   // idx4 M1/N1, stopper O1 (配置計画を持たせない。対象から外れる)
);
columnsA.push({ min: 16, max: 16, width: 200, hidden: false }); // idx5 P1: 収まる制御行
var occupiedA = ['C1', 'F1', 'I1', 'L1', 'O1', 'R1'];

var sheetLayoutA = { name: 'S1', default_width: 8.43, default_height: 18.75, columns: columnsA, unknown_width_columns: [], merges: [], occupied_cells: occupiedA, formula_cells: [], rows: [], cells: [] };

var seg0 = makeSegment(0, 'row0', 'A1');
var seg1 = makeSegment(1, 'row1', 'D1');
var seg2 = makeSegment(2, 'row2', 'G1');
var seg3 = makeSegment(3, 'row3', 'J1');
var seg4 = makeSegment(4, 'row4', 'M1', { placement: false });
var seg5 = makeSegment(5, 'row5', 'P1', { translation: 'This fits fine.', placement: false });

var projectA = {
  id: 'batchfit-a', revision: 1, file_name: 'batchfit-a.xlsx', document_format: 'xlsx', direction: 'to_en',
  segments: [seg0, seg1, seg2, seg3, seg4, seg5],
  sheet_layout: [sheetLayoutA]
};

// ---- projectB: 中止だけを見る、素材の小さい別資料。
var columnsB = [].concat(columnBlock(1, 40), columnBlock(4, 40), columnBlock(7, 40));
var occupiedB = ['C1', 'F1', 'I1'];
var sheetLayoutB = { name: 'S1', default_width: 8.43, default_height: 18.75, columns: columnsB, unknown_width_columns: [], merges: [], occupied_cells: occupiedB, formula_cells: [], rows: [], cells: [] };
var projectB = {
  id: 'batchfit-b', revision: 1, file_name: 'batchfit-b.xlsx', document_format: 'xlsx', direction: 'to_en',
  segments: [makeSegment(0, 'b-row0', 'A1'), makeSegment(1, 'b-row1', 'D1'), makeSegment(2, 'b-row2', 'G1')],
  sheet_layout: [sheetLayoutB]
};

// ---- 可変のサーバ内状態 ----
var stateA = JSON.parse(JSON.stringify(projectA));
var stateB = JSON.parse(JSON.stringify(projectB));
function projectFor(id) { if (id === projectA.id) return stateA; if (id === projectB.id) return stateB; return null; }

var events = [];              // {type:'start'|'terminal', projectId, index, attempt}
var jobs = {};                 // job_id -> {projectId,index,ticksRemaining,cannotFit,stall,cancelled}
var jobSeq = 0;
var publicationCalls = [];     // {projectId,index,max_chars,attempt}
var attemptCounts = {};        // "projectId:index" -> count
var cancelCalls = [];
var applyCalls = [];
var segmentCalls = [];

function candidateSetFor(projectId, index, empty) {
  if (empty) return { candidate_set_id: 'cs-' + projectId + '-' + index, dependency_fingerprint: 'fp-' + projectId + '-' + index, candidates: [] };
  return {
    candidate_set_id: 'cs-' + projectId + '-' + index,
    dependency_fingerprint: 'fp-' + projectId + '-' + index,
    candidates: [{ candidate_id: 'cand-' + projectId + '-' + index, text: 'Short version.', text_hash: 'th-' + projectId + '-' + index, deterministic_qc_status: 'passed', fit_verification_status: 'fits', used_abbreviations: [], warnings: [] }]
  };
}

function readBody(req) {
  return new Promise(function (resolve) {
    var data = '';
    req.on('data', function (c) { data += c; });
    req.on('end', function () { resolve(data); });
  });
}

function sendJson(res, status, obj) { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(obj)); }

var server = http.createServer(async function (req, res) {
  var url = new URL(req.url, 'http://127.0.0.1');
  var p = url.pathname;
  if (p === '/cat' || p === '/') {
    var html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'batchfit-test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS Pゴシック');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
    return;
  }
  if (p.indexOf('/assets/') === 0) {
    var file = path.join(wwwDir, p.replace(/^\//, ''));
    if (fs.existsSync(file)) { res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' }); res.end(fs.readFileSync(file)); return; }
    res.writeHead(404); res.end('not found'); return;
  }
  var body = await readBody(req);
  var parsed = null; try { parsed = body ? JSON.parse(body) : null; } catch (_) { parsed = null; }

  if (p === '/api/ready-state') { sendJson(res, 200, { canTranslate: true, label: 'ready', class: 'ok' }); return; }
  if (p === '/api/cat/recent') { sendJson(res, 200, { projects: [] }); return; }
  if (p === '/api/cat/resume') {
    var wanted = parsed ? String(parsed.project_id || '') : '';
    sendJson(res, 200, projectFor(wanted) || stateA);
    return;
  }
  if (p === '/api/cat/segment') {
    var proj1 = projectFor(String(parsed.id || '')) || stateA;
    var idx1 = Number(parsed.index);
    var seg1found = proj1.segments.filter(function (s) { return Number(s.index) === idx1; })[0];
    if (seg1found) seg1found.translation = String(parsed.text || '');
    proj1.revision = Number(proj1.revision || 1) + 1;
    segmentCalls.push({ projectId: proj1.id, index: idx1 });
    sendJson(res, 200, proj1);
    return;
  }
  if (p === '/api/cat/publication-candidates') {
    var proj2 = projectFor(String(parsed.id || ''));
    var projectId = proj2 ? proj2.id : String(parsed.id || '');
    var index = Number(parsed.index);
    var key = projectId + ':' + index;
    attemptCounts[key] = (attemptCounts[key] || 0) + 1;
    var attempt = attemptCounts[key];
    publicationCalls.push({ projectId: projectId, index: index, max_chars: Number(parsed.max_chars), attempt: attempt });
    events.push({ type: 'start', projectId: projectId, index: index, attempt: attempt });
    // JOB_RUNNINGリトライの題材: projectA index=1 の1回目だけ、サーバの直列
    // 契約違反（src/Server.ps1:949）を模す。実際のCAT actionラッパー
    // （:4186-4189）はcode付与を試みるがCAT_接頭辞が無いため
    // code=CAT_REQUEST_FAILED・400へ落ちる。ここはその実測どおりの応答を返す。
    if (projectId === projectA.id && index === 1 && attempt === 1) {
      sendJson(res, 400, { code: 'CAT_REQUEST_FAILED', error: '別の翻訳が実行中です。完了してから再実行してください。' });
      return;
    }
    jobSeq++;
    var jobId = 'job-' + jobSeq;
    var ticksNeeded = (projectId === projectA.id && index === 0) ? 2 : 0; // 直列性の題材
    var cannotFit = (projectId === projectA.id && index === 2);
    var stall = (projectId === projectB.id && index === 0); // 中止の題材
    jobs[jobId] = { projectId: projectId, index: index, ticksRemaining: ticksNeeded, cannotFit: cannotFit, stall: stall, cancelled: false };
    sendJson(res, 200, { job_id: jobId });
    return;
  }
  if (p === '/api/cancel-translation') {
    var jobId2 = String((parsed || {}).job_id || '');
    cancelCalls.push(jobId2);
    if (jobs[jobId2]) jobs[jobId2].cancelled = true;
    sendJson(res, 200, { ok: true });
    return;
  }
  if (p === '/api/cat/publication-apply') {
    applyCalls.push(parsed);
    sendJson(res, 404, { code: 'CAT_PUBLICATION_JOB_NOT_FOUND', error: 'この候補の作成記録が見つかりません。もう一度候補を作り直してください。' });
    return;
  }
  if (p.indexOf('/api/jobs/') === 0) {
    var jobId3 = decodeURIComponent(p.slice('/api/jobs/'.length));
    var job = jobs[jobId3];
    if (!job) { sendJson(res, 200, { mode: 'error', detail: 'unknown job' }); return; }
    if (job.cancelled) {
      events.push({ type: 'terminal', projectId: job.projectId, index: job.index, kind: 'cancelled' });
      sendJson(res, 200, { mode: 'cancelled', detail: '翻訳をキャンセルしました。' });
      return;
    }
    if (job.stall) { sendJson(res, 200, { mode: 'working', progress: 10, label: '待機中' }); return; }
    if (job.ticksRemaining > 0) { job.ticksRemaining--; sendJson(res, 200, { mode: 'working', progress: 40, label: '処理中' }); return; }
    events.push({ type: 'terminal', projectId: job.projectId, index: job.index, kind: 'done' });
    sendJson(res, 200, { mode: 'done', application_status: 'current', candidate_set: candidateSetFor(job.projectId, job.index, job.cannotFit) });
    return;
  }
  sendJson(res, 200, {});
});

// 直列性: 別indexのstartが、直前indexのterminalより先に来ていないか。
// 同indexの再送(JOB_RUNNINGリトライ)はcurrentIndexが変わらないので問題にしない。
function computeSerialOk(list) {
  var lastTerminalIndex = -1, currentIndex = -1, ok = true, problems = [];
  list.forEach(function (e) {
    if (e.type === 'start') {
      if (currentIndex !== -1 && currentIndex !== e.index && lastTerminalIndex !== currentIndex) {
        ok = false;
        problems.push('index=' + e.index + ' の start が index=' + currentIndex + ' の terminal より先に来た');
      }
      currentIndex = e.index;
    } else if (e.type === 'terminal') {
      lastTerminalIndex = e.index;
    }
  });
  return { ok: ok, problems: problems };
}

(async function () {
  var out = { errors: [], console: [] };
  var browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    var page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });

    // ============================================================ projectA
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(projectA.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });

    // --- 対象行の選定・N の表示 ---
    out.toolbarButton = await page.evaluate(function () {
      var b = document.getElementById('cat-fit-batch-open');
      return { hidden: !!b.hidden, text: b.textContent };
    });
    await page.click('#cat-fit-batch-open');
    await page.waitForSelector('#cat-fit-batch-dialog[open]', { timeout: 10000 });
    out.confirmText = await page.evaluate(function () { return document.getElementById('cat-fit-batch-confirm').textContent; });

    // --- 開始。直列性・JOB_RUNNINGリトライ・cannot-fit・要約表示を1回の実行で見る ---
    await page.click('#cat-fit-batch-start');
    var deadline = Date.now() + 25000;
    var finished = false;
    while (Date.now() < deadline) {
      finished = await page.evaluate(function () { return !document.getElementById('cat-fit-batch-summary').hidden; });
      if (finished) break;
      await page.waitForTimeout(150);
    }
    out.batchFinished = finished;
    out.summaryText = await page.evaluate(function () { return document.getElementById('cat-fit-batch-summary').textContent; });
    await page.click('#cat-fit-batch-close');

    out.publicationCalls = publicationCalls.filter(function (c) { return c.projectId === projectA.id; });
    var serial = computeSerialOk(events.filter(function (e) { return e.projectId === projectA.id; }));
    out.serialOk = serial.ok;
    out.serialProblems = serial.problems;
    out.index1Attempts = attemptCounts[projectA.id + ':1'] || 0;
    out.index4Called = out.publicationCalls.some(function (c) { return c.index === 4; });
    out.index5Called = out.publicationCalls.some(function (c) { return c.index === 5; });
    var callIdx0 = out.publicationCalls.filter(function (c) { return c.index === 0; })[0];
    var callIdx3 = out.publicationCalls.filter(function (c) { return c.index === 3; })[0];
    out.maxCharsIdx0 = callIdx0 ? callIdx0.max_chars : null;
    out.maxCharsIdx3 = callIdx3 ? callIdx3.max_chars : null;

    // --- キャッシュ再利用: idx0 を選び、行の1クリック導線で開くと、
    //     再生成なしでキャッシュ済みの候補がそのまま出る。 ---
    var callsBeforeCacheOpen = publicationCalls.length;
    await page.focus('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]');
    await page.waitForTimeout(150);
    await page.click('[data-cat-fit-candidates="0"]');
    await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(150);
    out.cacheServed = await page.evaluate(function () {
      return {
        statusText: document.getElementById('cat-publication-status').textContent,
        generateHidden: !!document.getElementById('cat-publication-generate').hidden,
        regenerateHidden: !!document.getElementById('cat-publication-regenerate').hidden,
        candidateCount: document.querySelectorAll('.cat-publication-candidate').length
      };
    });
    out.callsDuringCacheOpen = publicationCalls.length - callsBeforeCacheOpen;
    await page.evaluate(function () { document.getElementById('cat-publication-dialog').close(); document.getElementById('cat-placement-dialog').close(); });

    // --- 鮮度: 訳文を変えると、キャッシュは無効になり再生成へ戻る。 ---
    var segmentCallsBefore = segmentCalls.length;
    await page.focus('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]');
    await page.fill('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]', 'This is a completely different edited translation, long enough to still overflow the narrow column after the edit.');
    await page.keyboard.press('Tab');
    var segDeadline = Date.now() + 8000;
    while (Date.now() < segDeadline && segmentCalls.length <= segmentCallsBefore) { await page.waitForTimeout(100); }
    out.segmentCommitObserved = segmentCalls.length > segmentCallsBefore;
    await page.focus('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]');
    await page.waitForTimeout(150);
    await page.click('[data-cat-fit-candidates="0"]');
    await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(150);
    out.freshnessAfterEdit = await page.evaluate(function () {
      return {
        statusText: document.getElementById('cat-publication-status').textContent,
        generateHidden: !!document.getElementById('cat-publication-generate').hidden,
        regenerateHidden: !!document.getElementById('cat-publication-regenerate').hidden,
        candidateCount: document.querySelectorAll('.cat-publication-candidate').length
      };
    });
    var callsBeforeRegenerate = publicationCalls.length;
    await page.click('#cat-publication-generate');
    var regenDeadline = Date.now() + 8000;
    while (Date.now() < regenDeadline && publicationCalls.length <= callsBeforeRegenerate) { await page.waitForTimeout(100); }
    out.freshRegenerateCallObserved = publicationCalls.length > callsBeforeRegenerate;
    await page.waitForTimeout(150);
    await page.evaluate(function () { document.getElementById('cat-publication-dialog').close(); document.getElementById('cat-placement-dialog').close(); });

    // --- 適用失敗フォールバック: idx3(未編集・キャッシュ健在)で候補を適用しようと
    //     すると、サーバが404を返す。キャッシュを消し、「作り直す」で回復できる
    //     状態にする。 ---
    await page.focus('#cat-grid-body tr[data-cat-row="3"] textarea[data-cat-input]');
    await page.waitForTimeout(150);
    await page.click('[data-cat-fit-candidates="3"]');
    await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(150);
    out.idx3ServedFromCache = await page.evaluate(function () { return !document.getElementById('cat-publication-generate').hidden === false; });
    var candidateId = 'cand-' + projectA.id + '-3';
    await page.click('[data-publication-reviewed="' + candidateId + '"]');
    await page.click('[data-publication-apply="' + candidateId + '"]');
    var applyDeadline = Date.now() + 8000;
    while (Date.now() < applyDeadline && applyCalls.length < 1) { await page.waitForTimeout(100); }
    out.applyFailureObserved = applyCalls.length >= 1;
    await page.waitForTimeout(150);
    out.afterApplyFailure = await page.evaluate(function () {
      return {
        statusText: document.getElementById('cat-publication-status').textContent,
        generateHidden: !!document.getElementById('cat-publication-generate').hidden,
        regenerateHidden: !!document.getElementById('cat-publication-regenerate').hidden
      };
    });
    await page.evaluate(function () { document.getElementById('cat-publication-dialog').close(); document.getElementById('cat-placement-dialog').close(); });
    // 消えたキャッシュのまま再度開くと、もうキャッシュからは出ない。
    await page.focus('#cat-grid-body tr[data-cat-row="3"] textarea[data-cat-input]');
    await page.waitForTimeout(150);
    await page.click('[data-cat-fit-candidates="3"]');
    await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
    await page.waitForTimeout(150);
    out.idx3AfterFailureReopen = await page.evaluate(function () {
      return { generateHidden: !!document.getElementById('cat-publication-generate').hidden, regenerateHidden: !!document.getElementById('cat-publication-regenerate').hidden };
    });
    await page.evaluate(function () { document.getElementById('cat-publication-dialog').close(); document.getElementById('cat-placement-dialog').close(); });

    // ============================================================ projectB (中止)
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(projectB.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    await page.click('#cat-fit-batch-open');
    await page.waitForSelector('#cat-fit-batch-dialog[open]', { timeout: 10000 });
    await page.click('#cat-fit-batch-start');
    var callDeadline = Date.now() + 10000;
    while (Date.now() < callDeadline && publicationCalls.filter(function (c) { return c.projectId === projectB.id; }).length < 1) { await page.waitForTimeout(100); }
    await page.waitForTimeout(300);
    await page.click('#cat-fit-batch-abort');
    var cancelDeadline = Date.now() + 10000;
    while (Date.now() < cancelDeadline && cancelCalls.length < 1) { await page.waitForTimeout(100); }
    out.abortCancelObserved = cancelCalls.length >= 1;
    var abortSummaryDeadline = Date.now() + 15000;
    var abortFinished = false;
    while (Date.now() < abortSummaryDeadline) {
      abortFinished = await page.evaluate(function () { return !document.getElementById('cat-fit-batch-summary').hidden; });
      if (abortFinished) break;
      await page.waitForTimeout(150);
    }
    out.abortFinished = abortFinished;
    out.abortSummaryText = await page.evaluate(function () { return document.getElementById('cat-fit-batch-summary').textContent; });
    out.projectBCalls = publicationCalls.filter(function (c) { return c.projectId === projectB.id; }).length;

  } catch (error) {
    out.fatal = String((error && error.stack) || error);
  } finally {
    try { if (browser) await browser.close(); } catch (_) {}
    try { server.close(); } catch (_) {}
  }
  fs.writeFileSync(outputPath, JSON.stringify(out));
})();
