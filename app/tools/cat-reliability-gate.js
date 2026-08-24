'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const outPath = process.argv[3];
const mime = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };
const jobId = '15515515515515515515515515515515';
let segmentRequests = 0;
let jobPolls = 0;

function segment(index, source, translation) {
  return {
    index, segment_id: 'segment-' + index, source, translation, masked_translation: translation,
    state: translation ? 'human_edited' : 'untranslated', origin: translation ? 'manual' : '',
    confirmed: false, qc_status: 'not_run', qc_findings: [], qc_preview: [], location: 'Sheet1!A' + (index + 1),
    kind: 'text', repetition_count: 1, can_merge: false, can_split: false, can_split_at: false
  };
}
function project(revision, firstTranslation) {
  return {
    id: 'reliability-project', revision, source: 'file', lifecycle: 'saved', file_name: 'reliability.xlsx',
    document_format: 'xlsx', direction: 'to_en', total: 2, translated: firstTranslation ? 1 : 0,
    remaining: firstTranslation ? 1 : 2, untranslated: 1, draft: firstTranslation ? 1 : 0,
    confirmed: 0, unconfirmed: 2, source_chars: 20, remaining_chars: 10, joined: 0,
    export_blocked: true, translation_list_eligibility: false, excel_draft_eligibility: false,
    word_draft_eligibility: false, eligibility_reasons: [{ code: 'segment-untranslated', count: 1 }],
    sheet_layout: [], segments: [segment(0, '保存回復テスト', firstTranslation || 'Initial target'), segment(1, '未訳の行', '')]
  };
}
let currentProject = project(1, 'Initial target');

function readBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => resolve(body));
  });
}
function sendJson(res, value, status) {
  res.writeHead(status || 200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(value));
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const pathname = url.pathname;
  if (pathname === '/cat' || pathname === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0').replace(/__YAKU_IMPORT__/g, '0').replace(/__YAKU_VIEW__/g, '');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); return;
  }
  if (pathname.startsWith('/assets/')) {
    const file = path.join(wwwDir, pathname.substring(1));
    if (fs.existsSync(file)) { res.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream' }); res.end(fs.readFileSync(file)); return; }
    res.writeHead(404); res.end('not found'); return;
  }
  const raw = await readBody(req);
  let body = {};
  try { body = raw ? JSON.parse(raw) : {}; } catch (_) {}
  if (pathname === '/api/ready-state') { sendJson(res, { canTranslate: true, ready: true, label: '準備完了', class: 'ok' }); return; }
  if (pathname === '/api/cat/recent') { sendJson(res, { projects: [currentProject] }); return; }
  if (pathname === '/api/cat/resume' || pathname === '/api/cat/glossary' || pathname === '/api/cat/project-presence') { sendJson(res, currentProject); return; }
  if (pathname === '/api/cat/segment') {
    segmentRequests++;
    if (segmentRequests === 1) { sendJson(res, { error: '一時的に保存できませんでした。' }, 500); return; }
    await new Promise((resolve) => setTimeout(resolve, 350));
    currentProject = project(2, String(body.text || 'Recovered target'));
    sendJson(res, currentProject); return;
  }
  if (pathname === '/api/cat/translate') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end("<div class='result-loading job-loading' data-yaku-job-id='" + jobId + "' data-yaku-kind='cat'></div>"); return;
  }
  if (pathname === '/api/jobs/' + jobId) {
    jobPolls++;
    sendJson(res, { jobId, mode: 'error', label: '翻訳できませんでした', detail: 'モック翻訳が停止しました。', progress: 100, kind: 'cat', worker_progress: [null], partial_rows: [{ index: 1, source: '未訳の行', text: 'Recovered partial target' }] }); return;
  }
  sendJson(res, {});
});

(async () => {
  const result = { errors: [], console: [], segmentRequests: 0, jobPolls: 0 };
  let browser;
  try {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    page.on('pageerror', (error) => result.errors.push(String(error.message || error)));
    page.on('console', (message) => { if (message.type() === 'error') result.console.push(message.text()); });
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=reliability-project', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-cat-input="0"]', { state: 'visible' });

    const input = page.locator('[data-cat-input="0"]');
    await input.fill('Recovered target');
    await input.blur();
    await page.waitForFunction(() => document.getElementById('cat-current-save').textContent.includes('保存できませんでした'));
    await page.locator('#premium-summary-export').click();
    result.disabledGuidance = await page.locator('#cat-status').textContent();

    await page.evaluate(() => { window.__resave = window.YakuCat.resave(); });
    while (segmentRequests < 2) await new Promise((resolve) => setTimeout(resolve, 10));
    await page.evaluate(() => {
      const oldInput = document.querySelector('[data-cat-input="0"]');
      const replacement = oldInput.cloneNode(true);
      oldInput.replaceWith(replacement);
    });
    await page.waitForFunction(() => document.getElementById('cat-current-save').textContent === '保存済み');
    result.saveStatus = await page.locator('#cat-current-save').textContent();
    result.currentOriginal = await page.locator('[data-cat-input="0"]').getAttribute('data-original');
    result.saveFailed = await page.evaluate(() => window.YakuCat.getPremiumSnapshot()[0].saveFailed);

    await page.locator('#premium-translate').click();
    await page.waitForFunction(() => document.getElementById('cat-status').textContent.includes('モック翻訳が停止しました。'));
    result.terminalStatus = await page.locator('#cat-status').textContent();
    result.terminalPartial = await page.locator('[data-cat-input="1"]').inputValue();
    await page.waitForTimeout(1300);
    result.connectionRecovery = (await page.locator('#cat-job').textContent()).includes('接続の回復を待っています');
    result.segmentRequests = segmentRequests;
    result.jobPolls = jobPolls;
  } catch (error) {
    result.errors.push(String(error && error.stack || error));
    process.exitCode = 1;
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
    fs.writeFileSync(outPath, JSON.stringify(result));
  }
})();
