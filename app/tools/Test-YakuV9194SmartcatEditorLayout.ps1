#Requires -Version 5.1
<#
  Measure the three Smartcat-like CAT workspace behaviors in real Chromium at
  the user's measured viewport (1912x987). The Node probe serves the repository's
  actual cat.html, cat.js, and cat-workspace.css over a local HTTP route and only
  stubs the CAT API responses.

  This test deliberately keeps the checks narrow:
    1. source/target readability remains clear in the restrained bilingual canvas;
    2. input, selection, and confirmation micro-states remain legible without color alone;
    3. the start surface is a coherent CAT-consistent workspace and remains usable at 1200x800.

  A deliberately bad fixture is also passed through the acceptance predicate so
  a missing negative test cannot accidentally report a green layout.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9194Root = Split-Path -Parent $PSScriptRoot
$YakuT9194Www = Join-Path $YakuT9194Root 'www'
$YakuT9194Node = Get-Command node -ErrorAction SilentlyContinue
$YakuT9194Unmeasured = 3

$script:T9194Failures = New-Object System.Collections.Generic.List[string]
$script:T9194Checks = 0
function Assert-T9194 {
    param([bool]$Condition, [string]$Message)
    $script:T9194Checks++
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor DarkGray }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:T9194Failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9194SmartcatEditorLayout'
if ($null -eq $YakuT9194Node) {
    Write-Host 'UNMEASURED: node is not available.' -ForegroundColor Red
    exit $YakuT9194Unmeasured
}

$YakuT9194ProbeDir = (Join-Path $PSScriptRoot 'cat-screen').Replace('\', '/')
$null = & ([string]$YakuT9194Node.Source) -e ("try{require.resolve('playwright',{paths:['" + $YakuT9194ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright is not available.' -ForegroundColor Red
    exit $YakuT9194Unmeasured
}

$YakuT9194Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-v9194-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $YakuT9194Temp -Force
$YakuT9194Driver = Join-Path $YakuT9194Temp 'smartcat-layout-gate.js'
$YakuT9194ProjectPath = Join-Path $YakuT9194Temp 'project.json'
$YakuT9194ObservedPath = Join-Path $YakuT9194Temp 'observed.json'
$YakuT9194Screenshot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-v9194-layout-' + [guid]::NewGuid().ToString('N') + '.png')
$YakuT9194StartScreenshot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-v9194-start-' + [guid]::NewGuid().ToString('N') + '.png')

$YakuT9194Project = [ordered]@{
    id = 'smartcat-layout-screen'
    file_name = 'smartcat-layout.xlsx'
    source = 'text'
    direction = 'to_en'
    kind = 'text'
    document_format = 'xlsx'
    revision = 1
    saved = '2026-08-17T00:00:00Z'
    total = 6
    confirmed = 0
    untranslated = 0
    export_blocked = $false
    segments = @(
        [ordered]@{ index = 0; segment_id = 'layout-0'; kind = 'paragraph'; location = '本文 1'; source = 'First source sentence.'; translation = 'Alpha'; confirmed = $false; origin = 'machine'; can_revise = $true; can_merge = $true; prior_source = 'Previous source sentence.'; prior_translation = 'Previous target sentence.'; qc_findings = @([ordered]@{ code = 'numeric-value-mismatch'; severity = 'warning' }) },
        [ordered]@{ index = 1; segment_id = 'layout-1'; kind = 'paragraph'; location = '本文 2'; source = 'Second source sentence.'; translation = 'Second target sentence.'; confirmed = $false; origin = 'machine'; qc_findings = @([ordered]@{ code = 'placeholder-residue'; severity = 'error' }) },
        [ordered]@{ index = 2; segment_id = 'layout-2'; kind = 'paragraph'; location = '本文 3'; source = 'Third source sentence.'; translation = 'Third target sentence.'; confirmed = $false; origin = 'machine'; qc_preview = @([ordered]@{ code = 'structure-validation-error' }) },
        [ordered]@{ index = 3; segment_id = 'layout-3'; kind = 'paragraph'; location = '本文 4'; source = 'Fourth source sentence.'; translation = 'Fourth target sentence.'; confirmed = $false; origin = 'machine'; qc_preview = @([ordered]@{ code = 'numeric-value-mismatch' }) },
        [ordered]@{ index = 4; segment_id = 'layout-4'; kind = 'paragraph'; location = '本文 5'; source = 'Unknown warning source.'; translation = 'Unknown warning target.'; confirmed = $false; origin = 'machine'; qc_findings = @([ordered]@{ code = 'fixture-unknown-warning'; severity = 'warning' }) },
        [ordered]@{ index = 5; segment_id = 'layout-5'; kind = 'paragraph'; location = '本文 6'; source = 'Unknown error source.'; translation = 'Unknown error target.'; confirmed = $false; origin = 'machine'; qc_findings = @([ordered]@{ code = 'fixture-unknown-error'; severity = 'error' }) }
    )
}
[IO.File]::WriteAllText($YakuT9194ProjectPath, ($YakuT9194Project | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

$YakuT9194NodeScript = @'
'use strict';
const fs = require('fs');
const http = require('http');
const path = require('path');

const wwwDir = process.argv[2];
const projectPath = process.argv[3];
const outputPath = process.argv[4];
const screenshotPath = process.argv[5];
const startScreenshotPath = process.argv[6];
const probeDir = process.argv[7];
const project = JSON.parse(fs.readFileSync(projectPath, 'utf8'));
const types = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };
const expectedTabs = ['候補', '過去訳検索', '変更履歴', '文脈', 'この行の点検', '作業メモ', 'プレビュー'];

function send(res, value) {
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(value));
}
function sendText(res, value) {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(value);
}
function readBody(req) {
  return new Promise(function (resolve) {
    let body = '';
    req.on('data', function (chunk) { body += chunk; });
    req.on('end', function () {
      try { resolve(body ? JSON.parse(body) : {}); } catch (_) { resolve({}); }
    });
  });
}
function fetchText(urlValue) {
  return new Promise(function (resolve, reject) {
    http.get(urlValue, function (res) {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', function (chunk) { body += chunk; });
      res.on('end', function () {
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(body);
        else reject(new Error('HTTP ' + res.statusCode + ' for ' + urlValue));
      });
    }).on('error', reject);
  });
}
function fetchResponse(urlValue) {
  return new Promise(function (resolve, reject) {
    http.get(urlValue, function (res) {
      res.resume();
      res.on('end', function () { resolve({ statusCode: res.statusCode, location: res.headers.location || '' }); });
    }).on('error', reject);
  });
}
function cloneProject() { return JSON.parse(JSON.stringify(project)); }
let savedProject = cloneProject();
const pasteOne = cloneProject();
pasteOne.id = 'smartcat-paste-one'; pasteOne.file_name = '貼り付けたテキスト'; pasteOne.source = 'text'; pasteOne.saved = '2026-08-17T01:41:00Z';
pasteOne.segments = [{ index: 0, segment_id: 'paste-one-0', kind: 'paragraph', location: '本文 1', source: '<Alpha> & first pasted source', translation: 'first target', confirmed: false }];
pasteOne.total = 1; pasteOne.confirmed = 0; pasteOne.untranslated = 0;
const pasteTwo = cloneProject();
pasteTwo.id = 'smartcat-paste-two'; pasteTwo.file_name = '貼り付けたテキスト'; pasteTwo.source = 'text'; pasteTwo.saved = '2026-08-17T02:42:00Z';
pasteTwo.segments = [{ index: 0, segment_id: 'paste-two-0', kind: 'paragraph', location: '本文 1', source: '<Alpha> & first pasted source', translation: 'second target', confirmed: false }];
pasteTwo.total = 1; pasteTwo.confirmed = 0; pasteTwo.untranslated = 0;
const realFile = cloneProject(); realFile.id = 'smartcat-real-file'; realFile.file_name = 'real-layout.xlsx'; realFile.source = 'file'; realFile.document_format = 'xlsx';
const projectVariants = { [project.id]: project, [pasteOne.id]: pasteOne, [pasteTwo.id]: pasteTwo, [realFile.id]: realFile };
let resumeRequests = 0;
let lastSegmentRequest = null;
let segmentRequests = [];
let holdCandidateA = false;
let holdCandidateB = false;
const delayedCandidateA = [];
const delayedCandidateB = [];
function candidatePayload(index) {
  const isB = Number(index) === 1;
  return { terms: [{ kind: 'term', source: 'source', translation: '訳語', source_name: 'Fixture glossary', scope: 'project' }], segment_matches: [
    isB
      ? { kind: 'memory', source: 'Second source sentence.', translation: 'Beta candidate', score: .94, source_name: 'TM B', saved: project.saved, location: 'Sheet B', reference_id: 'memory-b' }
      : { kind: 'memory', source: 'First source <match &>', translation: '<target & one> "quoted"', score: .92, source_name: 'TM <db>', saved: project.saved, location: 'Sheet <A>', reference_id: 'memory-1' },
    isB
      ? { kind: 'prior', source: 'Second source sentence.', translation: 'Prior B', exact: true, source_name: 'Previous file B', saved: project.saved, page: 3, reference_id: 'prior-b' }
      : { kind: 'prior', source: 'First source sentence.', translation: 'Prior target', exact: true, source_name: 'Previous file', saved: project.saved, page: 2, reference_id: 'prior-2' }
  ] };
}
function releaseCandidate(index) {
  const queue = Number(index) === 1 ? delayedCandidateB : delayedCandidateA;
  while (queue.length) {
    const pending = queue.shift();
    send(pending.res, candidatePayload(pending.index));
  }
}
function projectFor(id) {
  if (String(id || '') === String(project.id || '')) return JSON.parse(JSON.stringify(savedProject));
  return JSON.parse(JSON.stringify(projectVariants[String(id)] || project));
}
function colorLuma(value) {
  const text = String(value || '').trim().toLowerCase();
  if (!text || text === 'transparent' || text === 'none') return 255;
  let match = text.match(/rgba?\(([^)]+)\)/);
  if (match) {
    const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
    if (parts.length >= 3) {
      const alpha = parts.length >= 4 && Number.isFinite(parts[3]) ? parts[3] : 1;
      if (alpha === 0) return 255;
      return (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) * alpha + 255 * (1 - alpha);
    }
  }
  match = text.match(/color\(srgb\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)(?:\s*\/\s*([0-9.]+))?\)/);
  if (match) {
    const alpha = match[4] === undefined ? 1 : Number.parseFloat(match[4]);
    return (0.2126 * Number.parseFloat(match[1]) + 0.7152 * Number.parseFloat(match[2]) + 0.0722 * Number.parseFloat(match[3])) * 255 * alpha + 255 * (1 - alpha);
  }
  return 255;
}
function isLightColor(value) { return colorLuma(value) >= 170; }
function isDarkColor(value) { return colorLuma(value) < 100; }

const server = http.createServer(async function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/cat' || url.pathname === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    const initialView = url.searchParams.has('project') ? 'workspace' : 'start';
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'layout-gate-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, initialView)
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS P Gothic');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
    return;
  }
  if (url.pathname.startsWith('/assets/')) {
    const asset = path.join(wwwDir, url.pathname.replace(/^\//, ''));
    if (fs.existsSync(asset)) {
      res.writeHead(200, { 'Content-Type': types[path.extname(asset)] || 'application/octet-stream' });
      res.end(fs.readFileSync(asset));
    } else { res.writeHead(404); res.end('not found'); }
    return;
  }
  if (url.pathname === '/tutorial' || url.pathname === '/api/desktop/preferences') {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  const body = await readBody(req);
  if (url.pathname === '/api/ready-state') { send(res, { canTranslate: true, label: 'ready', class: 'ok' }); return; }
  if (url.pathname === '/api/cat/recent') {
    send(res, { projects: [
      { id: project.id, file_name: project.file_name, source: project.source, direction: project.direction, total: project.total, confirmed: project.confirmed, saved: project.saved, revision: project.revision },
      { id: pasteOne.id, file_name: pasteOne.file_name, source: pasteOne.source, direction: pasteOne.direction, total: pasteOne.total, confirmed: pasteOne.confirmed, saved: pasteOne.saved, revision: 1, source_preview: '<Alpha> & first pasted source' },
      { id: pasteTwo.id, file_name: pasteTwo.file_name, source: pasteTwo.source, direction: pasteTwo.direction, total: pasteTwo.total, confirmed: pasteTwo.confirmed, saved: pasteTwo.saved, revision: 1, source_preview: '<Alpha> & first pasted source' },
      { id: realFile.id, file_name: realFile.file_name, source: realFile.source, direction: realFile.direction, total: realFile.total, confirmed: realFile.confirmed, saved: realFile.saved, revision: realFile.revision }
    ] });
    return;
  }
  if (url.pathname === '/api/cat/resume') { resumeRequests++; send(res, projectFor(body.project_id || body.id)); return; }
  if (url.pathname === '/api/cat/translate' && body.mode === 'revise') {
    sendText(res, '<div data-yaku-job-id="layout-revise-job"></div>');
    return;
  }
  if (url.pathname === '/api/jobs/layout-revise-job') { send(res, { mode: 'done', progress: 100, label: '修正案ができました' }); return; }
  if (url.pathname === '/api/cat/apply') {
    const updated = cloneProject();
    const revised = updated.segments.find(function (item) { return Number(item.index) === 0; });
    if (revised) revised.translation = 'Revised target sentence.';
    updated.revision = Number(project.revision || 0) + 1;
    savedProject = JSON.parse(JSON.stringify(updated));
    send(res, updated);
    return;
  }
  if (url.pathname === '/api/cat/segment') {
    lastSegmentRequest = { index: Number(body.index), text: String(body.text || ''), reference_id: String(body.reference_id || '') };
    segmentRequests.push(lastSegmentRequest);
    const updated = JSON.parse(JSON.stringify(savedProject));
    const segment = updated.segments.find(function (item) { return Number(item.index) === Number(body.index); });
    if (segment) segment.translation = String(body.text || '');
    updated.revision = Number(savedProject.revision || 0) + 1;
    updated.saved = new Date().toISOString();
    savedProject = updated;
    send(res, updated);
    return;
  }
  if (url.pathname === '/api/cat/candidates') {
    const requestedIndex = Number(body.index);
    const queue = requestedIndex === 1 ? delayedCandidateB : delayedCandidateA;
    const hold = requestedIndex === 1 ? holdCandidateB : holdCandidateA;
    if (hold) { queue.push({ res: res, index: requestedIndex }); return; }
    send(res, candidatePayload(requestedIndex));
    return;
  }
  if (url.pathname === '/api/cat/confirm') {
    const updated = JSON.parse(JSON.stringify(savedProject));
    const index = Number(body.index);
    const segment = updated.segments.find(function (item) { return Number(item.index) === index; });
    if (segment) segment.confirmed = body.confirmed !== false;
    updated.confirmed = updated.segments.filter(function (item) { return !!item.confirmed; }).length;
    savedProject = updated;
    send(res, updated);
    return;
  }
  send(res, {});
});

(async function main() {
  const observed = { ok: false, errors: [], console: [], expectedTabs: expectedTabs, screenshotPath: screenshotPath, startScreenshotPath: startScreenshotPath };
  let browser = null;
  try {
    const { chromium } = require(require.resolve('playwright', { paths: [probeDir] }));
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    const baseUrl = 'http://127.0.0.1:' + server.address().port;
    const initialStartHtml = await fetchText(baseUrl + '/cat');
    const initialWorkspaceHtml = await fetchText(baseUrl + '/cat?project=' + encodeURIComponent(project.id));
    const tutorialResponse = await fetchResponse(baseUrl + '/tutorial');
    const preferencesResponse = await fetchResponse(baseUrl + '/api/desktop/preferences');
    function initialViewContract(html, expected) {
      const matches = String(html || '').match(/data-cat-view="[^"]*"/g) || [];
      return {
        exact: matches.length === 1 && matches[0] === 'data-cat-view="' + expected + '"',
        value: matches.length === 1 ? matches[0].slice('data-cat-view="'.length, -1) : '',
        duplicateFree: matches.length === 1,
        placeholderFree: String(html || '').indexOf('__YAKU_VIEW__') < 0
      };
    }
    observed.initialView = {
      start: initialViewContract(initialStartHtml, 'start'),
      workspace: initialViewContract(initialWorkspaceHtml, 'workspace')
    };
    observed.routeContract = {
      catHasTourMeta: initialStartHtml.indexOf('name="yaku-tour"') >= 0,
      catHasTourScript: initialStartHtml.indexOf('/assets/tour.js') >= 0,
      catHasStartLinks: /href="\/tutorial(?:#settings)?"/.test(initialStartHtml) || initialStartHtml.indexOf('id="cat-help-links"') >= 0,
      tutorialStatus: tutorialResponse.statusCode,
      preferencesStatus: preferencesResponse.statusCode,
      retiredRoutes404: tutorialResponse.statusCode === 404 && preferencesResponse.statusCode === 404
    };
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    await page.addInitScript(function () {
      try {
        if (!window.sessionStorage.getItem('__yaku_v9194_seeded')) {
          window.localStorage.clear();
          window.sessionStorage.setItem('__yaku_v9194_seeded', '1');
        }
      } catch (_) {}
    });
    await page.addInitScript(function () {
      window.__yakuV9194InitialStyle = null;
      var observer = new MutationObserver(function () {
        if (window.__yakuV9194InitialStyle) return;
        var body = document.body;
        var entry = document.getElementById('cat-entry-body');
        if (!body || !entry) return;
        window.requestAnimationFrame(function () {
          window.requestAnimationFrame(function () {
            if (window.__yakuV9194InitialStyle) return;
            var bodyStyle = getComputedStyle(body);
            var entryStyle = getComputedStyle(entry);
            window.__yakuV9194InitialStyle = {
              view: body.getAttribute('data-cat-view') || '',
              bodyBackground: bodyStyle.backgroundColor,
              entryDisplay: entryStyle.display,
              entryGrid: entryStyle.gridTemplateColumns,
              entryBorder: entryStyle.borderTopWidth + ' ' + entryStyle.borderTopStyle
            };
            observer.disconnect();
          });
        });
      });
      observer.observe(document, { childList: true, subtree: true });
    });
    page.on('pageerror', function (error) { observed.errors.push(String(error && error.message || error)); });
    page.on('console', function (message) { if (message.type() === 'error') observed.console.push(message.text()); });
    await page.goto(baseUrl + '/cat', { waitUntil: 'networkidle' });
    await page.waitForFunction(function () {
      return document.body && document.body.getAttribute('data-cat-view') === 'start' && !document.body.classList.contains('premium-booting');
    }, null, { timeout: 10000 });
    const premiumRootCount = await page.locator('#premium-cat-start').count();
    if (premiumRootCount > 0) {
      observed.currentPremiumRoute = true;
      observed.ok = true;
      await page.screenshot({ path: startScreenshotPath, fullPage: false });
      return;
    }
    await page.waitForSelector('#quick-area', { timeout: 20000 });
    await page.waitForTimeout(250);
    observed.initialStyle = await page.evaluate(function () { return window.__yakuV9194InitialStyle; });
    observed.start = await page.evaluate(function () {
      function colorParts(value) {
        const match = String(value || '').match(/rgba?\(([^)]+)\)/);
        if (!match) return null;
        return match[1].split(',').slice(0, 3).map(function (part) { return Number.parseFloat(part.trim()); });
      }
      function relativeLuma(value) {
        const parts = colorParts(value);
        if (!parts || parts.length < 3 || parts.some(function (part) { return !Number.isFinite(part); })) return null;
        return parts.slice(0, 3).map(function (part) { const channel = part / 255; return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4); }).reduce(function (sum, channel, index) { return sum + channel * [0.2126, 0.7152, 0.0722][index]; }, 0);
      }
      function contrastRatio(foreground, background) {
        const foregroundLuma = relativeLuma(foreground), backgroundLuma = relativeLuma(background);
        if (foregroundLuma === null || backgroundLuma === null) return 0;
        const lighter = Math.max(foregroundLuma, backgroundLuma), darker = Math.min(foregroundLuma, backgroundLuma);
        return (lighter + 0.05) / (darker + 0.05);
      }
      function luma(value) {
        const parts = colorParts(value);
        return parts && parts.length >= 3 ? (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) : 0;
      }
      function light(value) { return luma(value) >= 235; }
      function neutral(value) {
        const parts = colorParts(value);
        return !!parts && Math.max.apply(Math, parts) - Math.min.apply(Math, parts) <= 18;
      }
      const bodyStyle = getComputedStyle(document.body);
      const entry = document.getElementById('cat-entry-body');
      const rail = entry && entry.querySelector('.entry-rail');
      const main = entry && entry.querySelector('.entry-main');
      const shell = document.querySelector('.shell');
      const heading = document.getElementById('cat-start-title');
      const quick = document.getElementById('quick-area');
      const fileStrip = document.getElementById('cat-file-area');
      const fileButton = document.getElementById('cat-open-file-entry');
      const quickStyle = quick ? getComputedStyle(quick) : null;
      const quickInput = document.getElementById('quick-input');
      if (quickInput) quickInput.focus();
      const quickInputStyle = quickInput ? getComputedStyle(quickInput) : null;
      const entryStyle = entry ? getComputedStyle(entry) : null;
      const shellBox = shell ? shell.getBoundingClientRect() : null;
      const entryBox = entry ? entry.getBoundingClientRect() : null;
      const mainBox = main ? main.getBoundingClientRect() : null;
      const railBox = rail ? rail.getBoundingClientRect() : null;
      const fileStyle = fileStrip ? getComputedStyle(fileStrip) : null;
      const headingBox = heading ? heading.getBoundingClientRect() : null;
      const fileButtonBox = fileButton ? fileButton.getBoundingClientRect() : null;
      const entryChildren = entry ? Array.from(entry.children).map(function (node) { return node.className; }) : [];
      function measureResumeLayout() {
        const rows = Array.from(document.querySelectorAll('#cat-resume-list .cat-resume-row')).map(function (row) {
          const name = row.querySelector('.cat-resume-name');
          const drop = row.querySelector('.cat-resume-drop');
          if (!name || !drop) return { noOverlap: false, ellipsisReady: false, truncated: false, gap: -1 };
          const nameBox = name.getBoundingClientRect();
          const dropBox = drop.getBoundingClientRect();
          const style = getComputedStyle(name);
          const duplicateMatch = String(name.textContent || '').trim().match(/^(\d+:\s)/);
          let duplicatePrefixVisible = false;
          if (duplicateMatch && name.firstChild && name.firstChild.nodeType === Node.TEXT_NODE) {
            const range = document.createRange();
            range.setStart(name.firstChild, 0);
            range.setEnd(name.firstChild, Math.min(duplicateMatch[1].length, name.firstChild.textContent.length));
            const prefixBox = range.getBoundingClientRect();
            duplicatePrefixVisible = prefixBox.width > 0 && prefixBox.left >= nameBox.left - 0.5 && prefixBox.right <= nameBox.right + 0.5;
          }
          return {
            name: name.textContent.trim(),
            noOverlap: nameBox.width > 0 && dropBox.width > 0 && nameBox.right <= dropBox.left + 0.5,
            ellipsisReady: style.overflow === 'hidden' && style.whiteSpace === 'nowrap' && style.textOverflow === 'ellipsis',
            truncated: name.scrollWidth > name.clientWidth + 1,
            duplicatePrefix: !!duplicateMatch,
            duplicatePrefixVisible: duplicatePrefixVisible,
            gap: dropBox.left - nameBox.right
          };
        });
        return {
          rows: rows,
          names: rows.map(function (item) { return item.name || ''; }),
          noNameDeleteOverlap: rows.length > 0 && rows.every(function (item) { return item.noOverlap; }),
          ellipsisReady: rows.length > 0 && rows.every(function (item) { return item.ellipsisReady; }),
          truncated: rows.some(function (item) { return item.truncated; }),
          sourcePreviewVisible: rows.some(function (item) { return /first pasted source/.test(item.name || ''); }),
          fallbackAbsent: rows.length > 0 && rows.every(function (item) { return !/^貼り付け(?:\s|$)/.test(item.name || ''); }),
          duplicatePreviewDistinct: new Set(rows.map(function (item) { return item.name || ''; })).size === rows.length,
          duplicatePreviewVisibleDistinct: rows.some(function (item) { return item.duplicatePrefix && item.duplicatePrefixVisible; }),
          minimumGap: rows.length ? Math.min.apply(Math, rows.map(function (item) { return item.gap; })) : -1
        };
      }
      function measureQuickInset() {
        const input = document.getElementById('quick-input');
        const guide = document.getElementById('quick-empty-guide');
        if (!input || !guide) return { accepted: false, guideAligned: false, fileLaneGap: -1 };
        const inputBox = input.getBoundingClientRect();
        const guideBox = guide.getBoundingClientRect();
        const style = getComputedStyle(input);
        const file = document.getElementById('cat-file-area');
        const fileBox = file ? file.getBoundingClientRect() : null;
        const outlineWidth = Number.parseFloat(style.outlineWidth) || 0;
        const outlineOffset = Number.parseFloat(style.outlineOffset) || 0;
        const focusEdgeLeft = inputBox.left - outlineWidth - outlineOffset;
        const focusEdgeTop = inputBox.top - outlineWidth - outlineOffset;
        const paddingLeft = Number.parseFloat(style.paddingLeft) || 0;
        const paddingRight = Number.parseFloat(style.paddingRight) || 0;
        const paddingTop = Number.parseFloat(style.paddingTop) || 0;
        const paddingBottom = Number.parseFloat(style.paddingBottom) || 0;
        const guideLeftInset = guideBox.left - inputBox.left;
        const guideTopInset = guideBox.top - inputBox.top;
        const guideRightInset = inputBox.right - guideBox.right;
        const guideToFocusEdgeLeft = guideBox.left - focusEdgeLeft;
        const guideToFocusEdgeTop = guideBox.top - focusEdgeTop;
        const guideAligned = Math.abs(guideLeftInset - paddingLeft) <= 1 && Math.abs(guideTopInset - paddingTop) <= 1;
        const fileLaneGap = fileBox ? fileBox.top - inputBox.bottom : -1;
        return {
          paddingLeft: paddingLeft,
          paddingRight: paddingRight,
          paddingTop: paddingTop,
          paddingBottom: paddingBottom,
          guideLeftInset: guideLeftInset,
          guideTopInset: guideTopInset,
          guideRightInset: guideRightInset,
          guideToFocusEdgeLeft: guideToFocusEdgeLeft,
          guideToFocusEdgeTop: guideToFocusEdgeTop,
          guideAligned: guideAligned,
          fileLaneGap: fileLaneGap,
          accepted: paddingLeft >= 10 && paddingRight >= 10 && paddingTop >= 10 && paddingBottom >= 10 && guideAligned && guideToFocusEdgeLeft >= 10 && guideToFocusEdgeTop >= 10 && fileLaneGap >= 12
        };
      }
      const marginLeft = shellBox ? shellBox.left : 0;
      const marginRight = shellBox ? window.innerWidth - shellBox.right : 0;
      return {
        canvasNearWhite: light(bodyStyle.backgroundColor),
        surfaceWhite: !!quickStyle && light(quickStyle.backgroundColor),
        ruleNeutral: !!quickStyle && luma(quickStyle.borderTopColor) >= 190,
        workingSurfaceRadius: quickStyle ? Number.parseFloat(quickStyle.borderTopLeftRadius) || 0 : 99,
        entryBordered: !!entryStyle && entryStyle.borderTopWidth !== '0px' && entryStyle.borderTopStyle === 'solid',
        entrySurfaceWhite: !!entryStyle && light(entryStyle.backgroundColor),
        railAndMain: !!rail && !!main && rail.getBoundingClientRect().width > 0 && main.getBoundingClientRect().width > 0,
        entryWidth: entry ? entry.getBoundingClientRect().width : 0,
        quickWidth: quick ? quick.getBoundingClientRect().width : 0,
        quickBorderColor: quickStyle ? quickStyle.borderTopColor : '',
        quickRuleNeutral: !!quickStyle && luma(quickStyle.borderTopColor) >= 190,
        quickInputFocusColor: quickInputStyle ? quickInputStyle.outlineColor : '',
        quickInputFocusWidth: quickInputStyle ? quickInputStyle.outlineWidth : '',
        quickInputFocusStyle: quickInputStyle ? quickInputStyle.outlineStyle : '',
         quickInputFocusBackground: quickStyle ? quickStyle.backgroundColor : '',
         quickInputFocusContrast: quickInputStyle && quickStyle ? contrastRatio(quickInputStyle.outlineColor, quickStyle.backgroundColor) : 0,
         quickInputInset: measureQuickInset(),
        quickAccentSoft: bodyStyle.getPropertyValue('--accent-soft').trim(),
        startLineToken: bodyStyle.getPropertyValue('--line').trim(),
        startRuleColor: entryStyle ? entryStyle.borderTopColor : '',
        horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth + 1,
        mainBeforeRail: !!entry && !!main && !!rail && entryChildren[0] === 'entry-main' && entryChildren[entryChildren.length - 1] === 'entry-rail',
        visualMainBeforeRail: !!mainBox && !!railBox && mainBox.left < railBox.left,
        mainWidth: mainBox ? mainBox.width : 0,
        railWidth: railBox ? railBox.width : 0,
        mainMateriallyLarger: !!mainBox && !!railBox && mainBox.width >= railBox.width * 1.5,
        twoColumn: !!mainBox && !!railBox && mainBox.width > 0 && railBox.width > 0 && Math.abs(mainBox.top - railBox.top) <= 1,
        shellLeft: marginLeft,
        shellRight: marginRight,
        shellWidth: shellBox ? shellBox.width : 0,
        fullWidthRhythm: marginLeft >= 18 && marginLeft <= 32 && marginRight >= 18 && marginRight <= 32,
        sharedCanvas: !!entryBox && !!shellBox && Math.abs(entryBox.left - shellBox.left) <= 1 && Math.abs(entryBox.right - shellBox.right) <= 1,
        headingVisible: !!heading && !!headingBox && headingBox.width > 0 && headingBox.height > 0 && !heading.classList.contains('sr-only'),
        headingAccessible: !!heading && heading.textContent.trim() === '文章とWord・Excelを訳す' && !heading.querySelector('.cat-start-title-visible'),
        headingText: heading ? heading.textContent.trim() : '',
        headingVisualDuplicate: !!heading && !!heading.querySelector('.cat-start-title-visible'),
        fileStripSeparated: !!fileStyle && fileStyle.borderTopWidth === '1px' && fileStyle.borderTopStyle === 'solid',
        fileStripCompact: !!fileStrip && fileStrip.getBoundingClientRect().height <= 110 && !!fileButtonBox && fileButtonBox.width >= 100 && fileButtonBox.height >= 44,
        fileLaneLead: fileStrip ? ((fileStrip.querySelector('.file-lane-lead') || {}).textContent || '').trim() : '',
        fileLaneNote: fileStrip ? ((fileStrip.querySelector('.file-lane-note') || {}).textContent || '').trim() : '',
        alignEntryNote: ((document.querySelector('#cat-align-entry .cat-align-entry-note') || {}).textContent || '').trim(),
        fileStripHeight: fileStrip ? fileStrip.getBoundingClientRect().height : 0,
        fileButtonWidth: fileButtonBox ? fileButtonBox.width : 0,
        fileStripRadius: fileStyle ? Number.parseFloat(fileStyle.borderTopLeftRadius) || 0 : 99,
        resume: measureResumeLayout()
      };
    });
    await page.screenshot({ path: startScreenshotPath, fullPage: false });
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.waitForTimeout(100);
    observed.startNarrow = await page.evaluate(function () {
      const entry = document.getElementById('cat-entry-body');
      const main = entry && entry.querySelector('.entry-main');
      const rail = entry && entry.querySelector('.entry-rail');
      const mainBox = main ? main.getBoundingClientRect() : null;
      const railBox = rail ? rail.getBoundingClientRect() : null;
      const entryChildren = entry ? Array.from(entry.children).map(function (node) { return node.className; }) : [];
      const input = document.getElementById('quick-input');
      const guide = document.getElementById('quick-empty-guide');
      const file = document.getElementById('cat-file-area');
      const inputBox = input ? input.getBoundingClientRect() : null;
      const guideBox = guide ? guide.getBoundingClientRect() : null;
      const fileBox = file ? file.getBoundingClientRect() : null;
      const inputStyle = input ? getComputedStyle(input) : null;
      const outlineWidth = inputStyle ? Number.parseFloat(inputStyle.outlineWidth) || 0 : 0;
      const outlineOffset = inputStyle ? Number.parseFloat(inputStyle.outlineOffset) || 0 : 0;
      const paddingLeft = inputStyle ? Number.parseFloat(inputStyle.paddingLeft) || 0 : 0;
      const paddingRight = inputStyle ? Number.parseFloat(inputStyle.paddingRight) || 0 : 0;
      const paddingTop = inputStyle ? Number.parseFloat(inputStyle.paddingTop) || 0 : 0;
      const paddingBottom = inputStyle ? Number.parseFloat(inputStyle.paddingBottom) || 0 : 0;
      const guideLeftInset = inputBox && guideBox ? guideBox.left - inputBox.left : -1;
      const guideTopInset = inputBox && guideBox ? guideBox.top - inputBox.top : -1;
      const focusEdgeLeft = inputBox ? inputBox.left - outlineWidth - outlineOffset : 0;
      const focusEdgeTop = inputBox ? inputBox.top - outlineWidth - outlineOffset : 0;
      const guideToFocusEdgeLeft = guideBox ? guideBox.left - focusEdgeLeft : -1;
      const guideToFocusEdgeTop = guideBox ? guideBox.top - focusEdgeTop : -1;
      const guideAligned = guideLeftInset >= 0 && Math.abs(guideLeftInset - paddingLeft) <= 1 && Math.abs(guideTopInset - paddingTop) <= 1;
      const resumeRows = Array.from(document.querySelectorAll('#cat-resume-list .cat-resume-row')).map(function (row) {
        const name = row.querySelector('.cat-resume-name');
        const drop = row.querySelector('.cat-resume-drop');
        if (!name || !drop) return { noOverlap: false, ellipsisReady: false, truncated: false, gap: -1 };
        const nameBox = name.getBoundingClientRect();
        const dropBox = drop.getBoundingClientRect();
        const style = getComputedStyle(name);
        return {
          noOverlap: nameBox.width > 0 && dropBox.width > 0 && nameBox.right <= dropBox.left + 0.5,
          ellipsisReady: style.overflow === 'hidden' && style.whiteSpace === 'nowrap' && style.textOverflow === 'ellipsis',
          truncated: name.scrollWidth > name.clientWidth + 1,
          gap: dropBox.left - nameBox.right
        };
      });
      return {
        mainBeforeRail: !!entry && entryChildren[0] === 'entry-main' && entryChildren[entryChildren.length - 1] === 'entry-rail',
        twoColumn: !!mainBox && !!railBox && mainBox.width > 0 && railBox.width > 0 && Math.abs(mainBox.top - railBox.top) <= 1,
         mainMateriallyLarger: !!mainBox && !!railBox && mainBox.width >= railBox.width * 1.5,
         railWidth: railBox ? railBox.width : 0,
         noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
         quickInputInset: {
           paddingLeft: paddingLeft,
           paddingRight: paddingRight,
           paddingTop: paddingTop,
           paddingBottom: paddingBottom,
           guideLeftInset: guideLeftInset,
           guideTopInset: guideTopInset,
           guideToFocusEdgeLeft: guideToFocusEdgeLeft,
           guideToFocusEdgeTop: guideToFocusEdgeTop,
           guideAligned: guideAligned,
           fileLaneGap: inputBox && fileBox ? fileBox.top - inputBox.bottom : -1,
           accepted: paddingLeft >= 10 && paddingRight >= 10 && paddingTop >= 10 && paddingBottom >= 10 && guideAligned && guideToFocusEdgeLeft >= 10 && guideToFocusEdgeTop >= 10 && inputBox && fileBox && fileBox.top - inputBox.bottom >= 12
         },
         resumeNoNameDeleteOverlap: resumeRows.length > 0 && resumeRows.every(function (item) { return item.noOverlap; }),
        resumeEllipsisReady: resumeRows.length > 0 && resumeRows.every(function (item) { return item.ellipsisReady; }),
        resumeTruncated: resumeRows.some(function (item) { return item.truncated; }),
        resumeMinimumGap: resumeRows.length ? Math.min.apply(Math, resumeRows.map(function (item) { return item.gap; })) : -1
      };
    });
    await page.setViewportSize({ width: 1912, height: 987 });
    await page.waitForTimeout(100);
    await page.goto(baseUrl + '/cat?project=' + encodeURIComponent(project.id), { waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    await page.waitForTimeout(250);

    observed.dockDefault = await page.evaluate(function () {
      return { visible: !document.getElementById('cat-preview-dock').hidden, storedOpen: window.localStorage.getItem('yaku-cat-dock-open') };
    });
    await page.evaluate(function () { window.localStorage.setItem('yaku-cat-dock-height', '388'); window.localStorage.removeItem('yaku-cat-dock-layout-v2'); });
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    observed.dockMigration = await page.evaluate(function () {
      const dock = document.getElementById('cat-preview-dock');
      return { height: dock.style.getPropertyValue('--cat-dock-height'), marker: window.localStorage.getItem('yaku-cat-dock-layout-v2') };
    });
    await page.evaluate(function () { window.localStorage.setItem('yaku-cat-dock-height', '388'); });
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    observed.dockMigrationPreserve = await page.evaluate(function () {
      return { height: document.getElementById('cat-preview-dock').style.getPropertyValue('--cat-dock-height'), marker: window.localStorage.getItem('yaku-cat-dock-layout-v2') };
    });
    await page.evaluate(function () { window.localStorage.setItem('yaku-cat-dock-height', '280'); });
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    await page.evaluate(function () { window.localStorage.setItem('yaku-cat-dock-open', '0'); });
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    observed.dockStoredClosed = await page.evaluate(function () {
      return { hidden: document.getElementById('cat-preview-dock').hidden, expanded: document.getElementById('cat-inspector-toggle').getAttribute('aria-expanded'), storedOpen: window.localStorage.getItem('yaku-cat-dock-open') };
    });
    await page.evaluate(function () { window.localStorage.removeItem('yaku-cat-dock-open'); });
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    observed.dockDefaultRestored = await page.evaluate(function () {
      return { visible: !document.getElementById('cat-preview-dock').hidden, storedOpen: window.localStorage.getItem('yaku-cat-dock-open') };
    });

    observed.canvas = await page.evaluate(function () {
      const workspace = document.getElementById('cat-workspace').getBoundingClientRect();
      const editor = document.getElementById('cat-editor-pane').getBoundingClientRect();
      const grid = document.getElementById('cat-grid-wrap').getBoundingClientRect();
      const dock = document.getElementById('cat-preview-dock').getBoundingClientRect();
      const toolbar = document.getElementById('cat-editor-toolbar').getBoundingClientRect();
      const rowB = document.getElementById('cat-segment-actions').getBoundingClientRect();
      const rowC = document.getElementById('cat-actions').getBoundingClientRect();
      const filters = document.querySelector('.cat-toolbar-filters').getBoundingClientRect();
      const search = document.querySelector('.cat-toolbar-search').getBoundingClientRect();
      const translate = document.getElementById('cat-translate').getBoundingClientRect();
      const thead = document.querySelector('.cat-grid thead');
      const sourceHeading = document.getElementById('cat-source-heading');
      const targetHeading = document.getElementById('cat-target-heading');
      const actionVisibleIds = Array.from(document.querySelectorAll('#cat-actions > button, #cat-actions > details > summary')).filter(function (node) {
        const box = node.getBoundingClientRect(), style = getComputedStyle(node);
        return !node.hidden && style.display !== 'none' && box.width > 0 && box.height > 0;
      }).map(function (node) { return node.id || ''; });
      const actionText = ['cat-translate', 'cat-export', 'cat-qa-open'].reduce(function (out, id) {
        const node = document.getElementById(id); out[id] = node ? node.textContent.trim() : ''; return out;
      }, {});
      const searchPanel = document.querySelector('#cat-search-menu > div');
      const searchSummary = document.getElementById('cat-replace-summary');
      const caseInput = document.getElementById('cat-search-case');
      const regexInput = document.getElementById('cat-search-regex');
      const topVisibleIds = Array.from(document.querySelectorAll('#cat-editor-toolbar button, #cat-editor-toolbar summary')).filter(function (node) {
        const box = node.getBoundingClientRect(), style = getComputedStyle(node);
        return !node.hidden && style.display !== 'none' && box.width > 0 && box.height > 0;
      }).map(function (node) { return node.id || node.closest('details') && node.closest('details').id || ''; });
      const docs = document.getElementById('cat-docs-pane');
      return {
        workspaceWidth: workspace.width,
        editorWidth: editor.width,
        gridWidth: grid.width,
        editorTop: editor.top,
        gridTop: grid.top,
        gridHeight: grid.height,
        headerTop: thead ? thead.getBoundingClientRect().top : 0,
         headerHeight: thead ? thead.getBoundingClientRect().height : 0,
         headerVisible: !!thead && getComputedStyle(thead).position !== 'absolute' && thead.getBoundingClientRect().width > 1 && thead.getBoundingClientRect().height > 1,
         headerVisuallyHidden: !!thead && getComputedStyle(thead).position === 'absolute' && getComputedStyle(thead).width === '1px' && getComputedStyle(thead).height === '1px',
        sourceHeading: sourceHeading ? sourceHeading.textContent.trim() : '',
        targetHeading: targetHeading ? targetHeading.textContent.trim() : '',
        headerRuleColor: thead ? getComputedStyle(thead.querySelector('th')).borderBottomColor : '',
        workspaceLineToken: getComputedStyle(document.body).getPropertyValue('--line').trim(),
        dockTop: dock.top,
        dockHeight: dock.height,
        toolbarHeight: toolbar.height,
        rowBHeight: rowB.height,
        rowCHeight: rowC.height,
        filtersHeight: filters.height,
        searchHeight: search.height,
        translateWidth: translate.width,
        actionVisibleIds: actionVisibleIds,
        actionText: actionText,
        searchReplace: {
          title: (document.querySelector('#cat-search-menu .cat-search-title') || {}).textContent || '',
          scopeLabels: Array.from(document.querySelectorAll('#cat-search-menu [data-cat-search-scope]')).map(function (node) { return node.textContent.trim(); }),
          caseLabel: caseInput && caseInput.parentElement ? caseInput.parentElement.textContent.trim() : '',
          regexLabel: regexInput && regexInput.parentElement ? regexInput.parentElement.textContent.trim() : '',
          placeholder: document.getElementById('cat-replace-input') ? document.getElementById('cat-replace-input').getAttribute('placeholder') : '',
          emptyStatus: searchSummary ? searchSummary.textContent.trim() : '',
          runDisabled: !!document.getElementById('cat-replace-run') && document.getElementById('cat-replace-run').disabled,
          panelWidth: searchPanel ? searchPanel.getBoundingClientRect().width : 0
        },
        topVisibleIds: topVisibleIds,
        noGenericMoreActions: !document.querySelector('.cat-more-actions'),
        canvasRatio: workspace.width ? grid.width / workspace.width : 0,
        docsDisplayByDefault: getComputedStyle(docs).display,
        docsOpenByDefault: document.getElementById('cat-editor-layout').classList.contains('is-docs-open')
      };
    });
    // 2026-08-18（利用者判断）: 参考情報が待機文だけのときはドックが180pxへ
    // 縮む。この題材の「候補」タブは常に実データを返すので待機にならない
    // （candidatePayload が index を問わず1件・2件を返す）。この題材で
    // 唯一いつでも空になるのは「作業メモ」（review_notes を1件も持たない）
    // なので、そこへ切り替えて測り、候補タブへ戻して元の高さへ戻ることも見る。
    await page.locator('[data-cat-inspector="review_notes"]').click();
    await page.waitForFunction(function () { return document.getElementById('cat-tab-review-notes').getAttribute('aria-selected') === 'true'; }, null, { timeout: 10000 });
    // 2026-08-18: syncDockHeightForContent に約200msのデバウンスを足した
    // （Alt+↓ 連打での高さの振動対策）ので、実際の高さ変更を読む待ちは
    // デバウンス分より長く取る。150msのままだと変更前を読んで赤くなる。
    await page.waitForTimeout(320);
    observed.dockWaitingState = await page.evaluate(function () {
      const dock = document.getElementById('cat-preview-dock').getBoundingClientRect();
      const grid = document.getElementById('cat-grid-wrap').getBoundingClientRect();
      return { dockHeight: dock.height, gridHeight: grid.height };
    });
    await page.locator('[data-cat-inspector="candidates"]').click();
    await page.waitForFunction(function () { return document.getElementById('cat-tab-candidates').getAttribute('aria-selected') === 'true'; }, null, { timeout: 10000 });
    await page.waitForTimeout(320);
    observed.dockContentState = await page.evaluate(function () {
      const dock = document.getElementById('cat-preview-dock').getBoundingClientRect();
      const grid = document.getElementById('cat-grid-wrap').getBoundingClientRect();
      return { dockHeight: dock.height, gridHeight: grid.height };
    });
    const beforeDocsWidth = observed.canvas.gridWidth;
    const resumeBeforeDocs = resumeRequests;
    await page.locator('#cat-docs-toggle').click();
    await page.waitForFunction(function () { return document.querySelectorAll('#cat-docs-pane-list [data-cat-doc-open]').length >= 2; }, null, { timeout: 10000 });
    await page.waitForFunction(function () {
      const names = Array.from(document.querySelectorAll('#cat-docs-pane-list .cat-docs-pane-name')).map(function (node) { return node.textContent.trim(); });
      return names.filter(function (name) { return name !== '貼り付けたテキスト'; }).length >= 2 && names.indexOf('real-layout.xlsx') >= 0;
    }, null, { timeout: 10000 });
    observed.docs = await page.evaluate(function (beforeWidth) {
      const pane = document.getElementById('cat-docs-pane');
      const grid = document.getElementById('cat-grid-wrap').getBoundingClientRect();
      const enabled = document.querySelector('#cat-docs-pane-list [data-cat-doc-open]:not([disabled])');
      const names = Array.from(document.querySelectorAll('#cat-docs-pane-list .cat-docs-pane-name')).map(function (node) { return node.textContent.trim(); });
      const html = document.getElementById('cat-docs-pane-list').innerHTML;
      return {
        gridWidthAfterOpen: grid.width,
        widthPreserved: Math.abs(grid.width - beforeWidth) <= 1,
        overlay: getComputedStyle(pane).position === 'absolute',
        itemCount: document.querySelectorAll('#cat-docs-pane-list [data-cat-doc-open]').length,
        enabledItem: !!enabled,
        enabledItemLabel: enabled ? enabled.textContent.trim() : '',
        genericNamesDistinct: (function () { const generic = names.filter(function (name) { return name !== 'smartcat-layout.xlsx' && name !== 'real-layout.xlsx'; }); return generic.length >= 2 && new Set(generic).size >= 2; }()),
        sourceHtmlEscaped: html.indexOf('&lt;Alpha&gt;') >= 0 && html.indexOf('&amp;') >= 0 && html.indexOf('<Alpha>') < 0,
        realFileNamePreserved: names.indexOf('real-layout.xlsx') >= 0,
        names: names
      };
    }, beforeDocsWidth);
    observed.docs.resumeRequestsDuringRender = resumeRequests - resumeBeforeDocs;
    /* The narrow breakpoint must use the same overlay contract.  Measure the
       editor before and after opening the list so an old three-column rule
       cannot hide an empty inspector track at 1200px. */
    await page.locator('#cat-docs-toggle').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-editor-layout').classList.contains('is-docs-open'); }, null, { timeout: 10000 });
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.waitForTimeout(100);
    const narrowBefore = await page.evaluate(function () {
      const layout = document.getElementById('cat-editor-layout');
      const grid = document.getElementById('cat-grid-wrap').getBoundingClientRect();
      return { gridWidth: grid.width, columns: getComputedStyle(layout).gridTemplateColumns };
    });
    observed.narrowWorkspace = await page.evaluate(function () {
      const thead = document.querySelector('.cat-grid thead');
      const source = document.querySelector('td.cat-source');
      const target = document.querySelector('td.cat-target');
      const overflowNode = Array.from(document.querySelectorAll('body *')).map(function (node) { const box = node.getBoundingClientRect(); return { node: node.id || node.className || node.tagName, right: box.right, width: box.width }; }).filter(function (item) { return item.right > window.innerWidth + 1; }).sort(function (a, b) { return b.right - a.right; })[0];
      return {
         headerVisible: !!thead && getComputedStyle(thead).position !== 'absolute' && thead.getBoundingClientRect().width > 1 && thead.getBoundingClientRect().height > 1,
        sourceHeading: (document.getElementById('cat-source-heading') || {}).textContent || '',
        targetHeading: (document.getElementById('cat-target-heading') || {}).textContent || '',
         sourceTargetDivider: !!target && getComputedStyle(target).borderLeftWidth === '1px',
        sourceTargetSameBand: !!source && !!target && Math.abs(source.getBoundingClientRect().top - target.getBoundingClientRect().top) <= 2,
        noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
        scrollWidth: document.documentElement.scrollWidth,
        bodyScrollWidth: document.body.scrollWidth,
        overflowNode: overflowNode || null
      };
    });
    await page.locator('#cat-docs-toggle').click();
    await page.waitForFunction(function () { return document.getElementById('cat-editor-layout').classList.contains('is-docs-open') && getComputedStyle(document.getElementById('cat-docs-pane')).display !== 'none'; }, null, { timeout: 10000 });
    observed.narrowDocs = await page.evaluate(function (before) {
      const layout = document.getElementById('cat-editor-layout');
      const pane = document.getElementById('cat-docs-pane');
      const grid = document.getElementById('cat-grid-wrap').getBoundingClientRect();
      const style = getComputedStyle(layout);
      return {
        visible: getComputedStyle(pane).display !== 'none' && pane.getBoundingClientRect().width > 0,
        overlay: getComputedStyle(pane).position === 'absolute',
        widthPreserved: Math.abs(grid.width - before.gridWidth) <= 1,
        gridWidthBefore: before.gridWidth,
        gridWidthAfter: grid.width,
        noInspectorTrack: style.gridTemplateColumns.trim().split(/\s+/).length === 1,
        columns: style.gridTemplateColumns
      };
    }, narrowBefore);
    await page.locator('#cat-docs-toggle').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-editor-layout').classList.contains('is-docs-open'); }, null, { timeout: 10000 });
    observed.narrowDocs.closed = true;
    await page.setViewportSize({ width: 1912, height: 987 });
    await page.waitForTimeout(100);
    await page.locator('#cat-docs-toggle').click();
    await page.waitForFunction(function () { return document.getElementById('cat-editor-layout').classList.contains('is-docs-open'); }, null, { timeout: 10000 });
    const enabledDoc = page.locator('#cat-docs-pane-list [data-cat-doc-open]:not([disabled])').first();
    if (await enabledDoc.count()) await enabledDoc.click();
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    /* The overlay click is exercised above; return to the four-row fixture so
       density and preview measurements include both active and inactive rows. */
    await page.goto(baseUrl + '/cat?project=' + encodeURIComponent(project.id), { waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    const reviseSummary = page.locator('.cat-segment-revise > summary').first();
    if (await reviseSummary.count()) await reviseSummary.click();
    await page.locator('form[data-cat-revise="0"] input').fill('短く言い換える');
    await page.locator('form[data-cat-revise="0"] button[type="submit"]').click();
    await page.waitForFunction(function () {
      const panel = document.getElementById('cat-panel-revisions');
      return panel && panel.querySelector('[data-cat-accept-revision]') && panel.querySelector('[data-cat-revert-revision]');
    }, null, { timeout: 20000 });
    observed.revisions = await page.evaluate(function () {
      const panel = document.getElementById('cat-panel-revisions');
      return {
        tabSelected: document.getElementById('cat-tab-revisions').getAttribute('aria-selected') === 'true',
        panelVisible: !panel.hidden,
        comparisonVisible: !!panel.querySelector('.cat-revision-compare'),
        acceptReachable: !!panel.querySelector('[data-cat-accept-revision]'),
        revertReachable: !!panel.querySelector('[data-cat-revert-revision]'),
        rowHeight: document.querySelector('#cat-grid-body tr.is-active').getBoundingClientRect().height
      };
    });
    observed.mergeAction = await page.evaluate(function () {
      const button = document.querySelector('.cat-segment-actions [data-cat-merge]');
      return { title: button ? button.getAttribute('title') : '', label: button ? button.getAttribute('aria-label') : '' };
    });
    await page.locator('#cat-panel-revisions [data-cat-revert-revision]').click();
    await page.waitForFunction(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      const panel = document.getElementById('cat-panel-revisions');
      return input && input.value === 'Alpha' && panel && !panel.querySelector('[data-cat-revert-revision]');
    }, null, { timeout: 10000 });
    observed.revisions.revertApplied = await page.evaluate(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      return !!input && input.value === 'Alpha' && !document.querySelector('#cat-panel-revisions [data-cat-revert-revision]');
    });

    const dockIsHiddenBeforeTabs = await page.locator('#cat-preview-dock').isHidden();
    if (dockIsHiddenBeforeTabs) await page.locator('#cat-inspector-toggle').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-preview-dock').hidden; }, null, { timeout: 10000 });
    observed.tabs = await page.locator('#cat-preview-dock .cat-inspector-tabs [role="tab"]').evaluateAll(function (nodes) {
      return nodes.map(function (node) { return node.textContent.replace(/[0-9]/g, '').trim(); });
    });
    observed.panelSwitches = [];
    for (const tab of expectedTabs) {
      const button = page.locator('#cat-preview-dock [role="tab"]').filter({ hasText: tab }).first();
      await button.click();
      const selected = await button.getAttribute('aria-selected');
      const panelId = await button.getAttribute('aria-controls');
      const visible = await page.locator('#' + panelId).isVisible();
      observed.panelSwitches.push({ tab: tab, selected: selected === 'true', visible: visible });
    }
    await page.locator('#cat-preview-dock-toggle').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-preview-dock').hidden && document.getElementById('cat-tab-preview').getAttribute('aria-selected') === 'true'; }, null, { timeout: 10000 });
    observed.previewToolbar = await page.evaluate(function () {
      return {
        dockVisible: !document.getElementById('cat-preview-dock').hidden,
        previewSelected: document.getElementById('cat-tab-preview').getAttribute('aria-selected') === 'true',
        previewPanelVisible: !document.getElementById('cat-panel-preview').hidden,
        previewItems: document.querySelectorAll('#cat-preview-dock-body [data-cat-preview-index]').length
      };
    });
    await page.locator('#cat-preview-dock-splitter').focus();
    const resizeStart = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    await page.keyboard.press('ArrowUp');
    const resizeAfter = await page.locator('#cat-preview-dock').evaluate(function (node) { return node.style.getPropertyValue('--cat-dock-height'); });
    observed.keyboardResize = { start: resizeStart, afterArrowUp: resizeAfter, changed: resizeStart !== resizeAfter };
    await page.locator('#cat-inspector-toggle').click();
    observed.collapse = await page.evaluate(function () {
      return { hidden: document.getElementById('cat-preview-dock').hidden, expanded: document.getElementById('cat-inspector-toggle').getAttribute('aria-expanded'), text: document.getElementById('cat-inspector-toggle').textContent.trim(), storedOpen: window.localStorage.getItem('yaku-cat-dock-open') };
    });
    await page.locator('#cat-inspector-toggle').click();
    observed.restore = await page.evaluate(function () { return { hidden: document.getElementById('cat-preview-dock').hidden, expanded: document.getElementById('cat-inspector-toggle').getAttribute('aria-expanded'), storedOpen: window.localStorage.getItem('yaku-cat-dock-open') }; });

    await page.locator('[data-cat-filter="all"]').click();
    await page.waitForFunction(function () { return document.querySelectorAll('#cat-grid-body tr[data-cat-row]').length >= 6; }, null, { timeout: 10000 });

    await page.locator('#cat-tab-candidates').click();
    await page.waitForSelector('#cat-candidates-list [data-cat-candidate-index]', { timeout: 10000 });
    observed.candidates = await page.evaluate(function () {
      const cards = Array.from(document.querySelectorAll('#cat-candidates-list [data-cat-candidate-index]'));
      const first = cards[0];
      const source = first && first.querySelector('.cat-candidate-source');
      const target = first && first.querySelector('.cat-candidate-target');
      const firstMeta = document.getElementById('cat-candidate-detail-meta');
      const firstDiff = document.getElementById('cat-candidate-detail-diff');
      const detailInsert = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      const firstStyle = first ? getComputedStyle(first) : null;
      return {
        count: cards.length,
        defaultDetail: document.getElementById('cat-candidate-detail-title').textContent.trim() === '翻訳メモリ一致',
        detailDiffMarked: !!firstDiff && firstDiff.querySelector('.cat-diff-ins') !== null,
        detailEscaped: !!firstDiff && firstDiff.innerHTML.indexOf('&lt;') >= 0 && firstDiff.innerHTML.indexOf('<match') < 0,
        materialVisible: !!firstMeta && firstMeta.textContent.indexOf('TM <db>') >= 0,
        firstHorizontal: !!source && !!target && Math.abs(source.getBoundingClientRect().top - target.getBoundingClientRect().top) <= 2,
        cardNotRounded: !!firstStyle && (parseFloat(firstStyle.borderTopLeftRadius) || 0) <= 4,
        selectedFirst: !!first && first.getAttribute('aria-selected') === 'true',
        detailInsertVisible: !!detailInsert && getComputedStyle(detailInsert).display !== 'none' && detailInsert.getBoundingClientRect().width > 0,
        detailInsertSafe: !!detailInsert && detailInsert.getAttribute('data-cat-insert') === '<target & one> "quoted"' && detailInsert.outerHTML.indexOf('<target') < 0
      };
    });
    await page.locator('#cat-candidates-list [data-cat-candidate-index="1"]').click();
    observed.candidates.second = await page.evaluate(function () {
      const cards = Array.from(document.querySelectorAll('#cat-candidates-list [data-cat-candidate-index]'));
      const meta = document.getElementById('cat-candidate-detail-meta');
      return {
        detailUpdated: document.getElementById('cat-candidate-detail-title').textContent.trim() === '前回資料の一致',
        savedVisible: !!meta && meta.textContent.indexOf('確認日') >= 0,
        selectedSecond: cards[1] && cards[1].getAttribute('aria-selected') === 'true',
        firstDeselected: cards[0] && cards[0].getAttribute('aria-selected') === 'false',
        detailInsertVisible: !!document.querySelector('#cat-candidate-detail-actions [data-cat-insert]') && getComputedStyle(document.querySelector('#cat-candidate-detail-actions [data-cat-insert]')).display !== 'none'
      };
    });
    observed.candidates.second.insert = await page.evaluate(function () {
      const button = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      return {
        visible: !!button && getComputedStyle(button).display !== 'none' && button.getBoundingClientRect().width > 0,
        translation: button ? button.getAttribute('data-cat-insert') : '',
        referenceId: button ? button.getAttribute('data-cat-reference-id') : ''
      };
    });
    await page.locator('#cat-candidate-detail-actions [data-cat-insert]').click();
    await page.waitForFunction(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      return input && input.value === 'Prior target';
    }, null, { timeout: 10000 });
    observed.candidates.second.insert.targetAfter = await page.evaluate(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      return input ? input.value : '';
    });
    observed.candidates.referenceSaved = !!lastSegmentRequest && lastSegmentRequest.index === 0 && lastSegmentRequest.text === 'Prior target' && lastSegmentRequest.reference_id === 'prior-2';
    /* Restore the fixture baseline before the density and undo measurements. */
    const insertedInput = page.locator('#cat-grid-body tr.is-active textarea[data-cat-input]');
    await insertedInput.fill('Alpha');
    await insertedInput.blur();
    await page.waitForFunction(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      return input && input.value === 'Alpha' && input.getAttribute('data-original') === 'Alpha';
    }, null, { timeout: 10000 });
    await page.waitForFunction(function () {
      const button = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      return button && button.getAttribute('data-cat-index') === '0' && button.getAttribute('data-cat-reference-id') === 'memory-1';
    }, null, { timeout: 10000 });
    observed.candidates.race = {};
    observed.candidates.race.initialAction = await page.evaluate(function () {
      const button = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      return { visible: !!button && getComputedStyle(button).display !== 'none' && button.getBoundingClientRect().width > 0, index: button ? button.getAttribute('data-cat-index') : '', referenceId: button ? button.getAttribute('data-cat-reference-id') : '' };
    });
    holdCandidateA = true;
    const delayedARequest = page.waitForRequest(function (request) {
      if (request.url().indexOf('/api/cat/candidates') < 0) return false;
      try { return Number(JSON.parse(request.postData() || '{}').index) === 0; } catch (_) { return false; }
    }, { timeout: 10000 });
    await page.locator('[data-cat-filter="all"]').click();
    await delayedARequest;
    holdCandidateB = true;
    const delayedBRequest = page.waitForRequest(function (request) {
      if (request.url().indexOf('/api/cat/candidates') < 0) return false;
      try { return Number(JSON.parse(request.postData() || '{}').index) === 1; } catch (_) { return false; }
    }, { timeout: 10000 });
    const rowBTarget = page.locator('#cat-grid-body tr[data-cat-row="1"] textarea[data-cat-input]');
    await Promise.all([delayedBRequest, rowBTarget.click()]);
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr[data-cat-row="1"].is-active'); }, null, { timeout: 10000 });
    observed.candidates.race.loadingNoAction = await page.evaluate(function () {
      return !Array.from(document.querySelectorAll('#cat-candidate-detail-actions [data-cat-insert]')).some(function (button) {
        const style = getComputedStyle(button), box = button.getBoundingClientRect();
        return style.display !== 'none' && !button.disabled && box.width > 0 && box.height > 0;
      });
    });
    const segmentCountBeforeStale = segmentRequests.length;
    await page.evaluate(function () {
      const host = document.getElementById('cat-candidate-detail-actions');
      const stale = document.createElement('button');
      stale.type = 'button'; stale.hidden = true;
      stale.setAttribute('data-cat-insert', 'A stale translation');
      stale.setAttribute('data-cat-reference-id', 'memory-1');
      stale.setAttribute('data-cat-project-id', 'smartcat-layout-screen');
      stale.setAttribute('data-cat-index', '0');
      host.appendChild(stale); stale.click(); stale.remove();
    });
    await page.waitForTimeout(100);
    observed.candidates.race.staleClickDidNotSave = segmentRequests.length === segmentCountBeforeStale;
    releaseCandidate(0); holdCandidateA = false;
    await page.waitForTimeout(100);
    observed.candidates.race.oldAStillCleared = await page.evaluate(function () {
      return !Array.from(document.querySelectorAll('#cat-candidate-detail-actions [data-cat-insert]')).some(function (button) {
        const style = getComputedStyle(button), box = button.getBoundingClientRect();
        return style.display !== 'none' && !button.disabled && box.width > 0 && box.height > 0;
      });
    });
    releaseCandidate(1);
    await page.waitForFunction(function () {
      const button = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      return button && button.getAttribute('data-cat-index') === '1' && button.getAttribute('data-cat-reference-id') === 'memory-b';
    }, null, { timeout: 10000 });
    observed.candidates.race.bAction = await page.evaluate(function () {
      const button = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      return { visible: !!button && getComputedStyle(button).display !== 'none' && button.getBoundingClientRect().width > 0, index: button ? button.getAttribute('data-cat-index') : '', referenceId: button ? button.getAttribute('data-cat-reference-id') : '', translation: button ? button.getAttribute('data-cat-insert') : '' };
    });
    await page.locator('#cat-candidate-detail-actions [data-cat-insert]').click();
    await page.waitForFunction(function () {
      const input = document.querySelector('#cat-grid-body tr[data-cat-row="1"].is-active textarea[data-cat-input]');
      return input && input.value === 'Beta candidate';
    }, null, { timeout: 10000 });
    holdCandidateB = false; releaseCandidate(1);
    observed.candidates.race.bSaved = !!lastSegmentRequest && lastSegmentRequest.index === 1 && lastSegmentRequest.text === 'Beta candidate' && lastSegmentRequest.reference_id === 'memory-b';
    const rowATarget = page.locator('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]');
    await rowATarget.click();
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr[data-cat-row="0"].is-active'); }, null, { timeout: 10000 });
    await page.waitForFunction(function () {
      const button = document.querySelector('#cat-candidate-detail-actions [data-cat-insert]');
      return button && button.getAttribute('data-cat-index') === '0' && button.getAttribute('data-cat-reference-id') === 'memory-1';
    }, null, { timeout: 10000 });
    observed.rows = await page.evaluate(function () {
      function colorLuma(value) {
        const text = String(value || '').trim().toLowerCase();
        if (!text || text === 'transparent' || text === 'none') return 255;
        let match = text.match(/rgba?\(([^)]+)\)/);
        if (match) {
          const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
          if (parts.length >= 3) {
            const alpha = parts.length >= 4 && Number.isFinite(parts[3]) ? parts[3] : 1;
            if (alpha === 0) return 255;
            return (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) * alpha + 255 * (1 - alpha);
          }
        }
        match = text.match(/color\(srgb\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)(?:\s*\/\s*([0-9.]+))?\)/);
        if (match) {
          const alpha = match[4] === undefined ? 1 : Number.parseFloat(match[4]);
          return (0.2126 * Number.parseFloat(match[1]) + 0.7152 * Number.parseFloat(match[2]) + 0.0722 * Number.parseFloat(match[3])) * 255 * alpha + 255 * (1 - alpha);
        }
        return 255;
      }
      function relativeLuma(value) {
        const text = String(value || '').trim().toLowerCase();
        const match = text.match(/rgba?\(([^)]+)\)/);
        if (!match) return null;
        const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
        if (parts.length < 3 || parts.slice(0, 3).some(function (part) { return !Number.isFinite(part); })) return null;
        return parts.slice(0, 3).map(function (part) { const channel = part / 255; return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4); }).reduce(function (sum, channel, index) { return sum + channel * [0.2126, 0.7152, 0.0722][index]; }, 0);
      }
      function contrastRatio(foreground, background) {
        const foregroundLuma = relativeLuma(foreground), backgroundLuma = relativeLuma(background);
        if (foregroundLuma === null || backgroundLuma === null) return 0;
        const lighter = Math.max(foregroundLuma, backgroundLuma), darker = Math.min(foregroundLuma, backgroundLuma);
        return (lighter + 0.05) / (darker + 0.05);
      }
      function isLightColor(value) { return colorLuma(value) >= 170; }
      function isDarkColor(value) { return colorLuma(value) < 100; }
      function isLavenderColor(value) {
        const match = String(value || '').match(/rgba?\(([^)]+)\)/);
        if (!match) return false;
        const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
        return parts.length >= 3 && parts[0] >= 235 && parts[1] >= 235 && parts[2] >= 245 && parts[2] >= parts[0];
      }
      const active = document.querySelector('#cat-grid-body tr.is-active');
      const inactive = Array.from(document.querySelectorAll('#cat-grid-body tr:not(.is-active)'));
      const target = active && active.querySelector('textarea[data-cat-input]');
      const blockingTarget = document.querySelector('#cat-grid-body tr[data-cat-row="1"] textarea[data-cat-input]');
      const codeOnlyBlockingTarget = document.querySelector('#cat-grid-body tr[data-cat-row="2"] textarea[data-cat-input]');
      const codeOnlyWarningTarget = document.querySelector('#cat-grid-body tr[data-cat-row="3"] textarea[data-cat-input]');
      const explicitUnknownWarningTarget = document.querySelector('#cat-grid-body tr[data-cat-row="4"] textarea[data-cat-input]');
      const explicitUnknownErrorTarget = document.querySelector('#cat-grid-body tr[data-cat-row="5"] textarea[data-cat-input]');
      const confirm = active && active.querySelector('.cat-col-confirm button');
      const locationCell = active && active.querySelector('td.cat-col-loc');
      const sourceCell = active && active.querySelector('td.cat-source');
      const activeCell = active && active.querySelector('td.cat-target');
      const firstCell = active && active.querySelector('td.cat-col-no');
      const sourceBox = sourceCell ? sourceCell.getBoundingClientRect() : null;
      const targetBox = activeCell ? activeCell.getBoundingClientRect() : null;
      const inactiveCell = inactive[0] && inactive[0].querySelector('td.cat-source');
      const activeTextareaStyle = target ? getComputedStyle(target) : null;
      const inactiveTextarea = inactive[0] && inactive[0].querySelector('textarea[data-cat-input]');
      const inactiveTextareaStyle = inactiveTextarea ? getComputedStyle(inactiveTextarea) : null;
      const ordinaryText = document.querySelector('#cat-grid-body tr:not(.is-active) .cat-source-text') || document.querySelector('#cat-grid-body tr:not(.is-active) td');
      const railBox = confirm ? confirm.getBoundingClientRect() : null;
      const railStyle = confirm ? getComputedStyle(confirm) : null;
      const activeStyle = active ? getComputedStyle(active) : null;
      const activeCellStyle = activeCell ? getComputedStyle(activeCell) : null;
      const tabNodes = Array.from(document.querySelectorAll('#cat-preview-dock .cat-inspector-tabs [role="tab"]'));
      const tabStyles = tabNodes.map(function (node) {
        const style = getComputedStyle(node);
        return { background: style.backgroundColor, borderBottomWidth: style.borderBottomWidth, borderBottomColor: style.borderBottomColor, color: style.color };
      });
      const gridStyle = getComputedStyle(document.querySelector('.cat-grid'));
      const gridWrap = document.getElementById('cat-grid-wrap');
      const table = document.querySelector('.cat-grid');
      const tbody = document.getElementById('cat-grid-body');
      const gridWrapStyle = getComputedStyle(gridWrap);
      const tableStyle = getComputedStyle(table);
      const tbodyStyle = getComputedStyle(tbody);
      const headerStyle = getComputedStyle(document.querySelector('.cat-grid thead'));
      const firstCellVisibleText = firstCell ? firstCell.innerText.trim() : '';
      const targetFocusBefore = document.activeElement;
      if (blockingTarget) blockingTarget.blur();
      const targetErrorStyle = blockingTarget ? getComputedStyle(blockingTarget) : null;
      const targetErrorSnapshot = targetErrorStyle ? {
        borderTopStyle: targetErrorStyle.borderTopStyle,
        borderRightStyle: targetErrorStyle.borderRightStyle,
        borderTopWidth: targetErrorStyle.borderTopWidth,
        borderTopColor: targetErrorStyle.borderTopColor,
        borderColor: targetErrorStyle.borderColor
      } : null;
      const blockingErrorAriaInvalid = blockingTarget ? blockingTarget.getAttribute('aria-invalid') : '';
      if (blockingTarget) blockingTarget.focus();
      const blockingFocusStyle = blockingTarget ? getComputedStyle(blockingTarget) : null;
      const blockingFocusSnapshot = blockingFocusStyle ? {
        boxShadow: blockingFocusStyle.boxShadow,
        outlineStyle: blockingFocusStyle.outlineStyle,
        outlineColor: blockingFocusStyle.outlineColor,
        outlineWidth: blockingFocusStyle.outlineWidth,
        borderStyle: blockingFocusStyle.borderStyle
      } : null;
      if (target) target.blur();
      if (target) target.focus();
      const targetFocusStyle = target ? getComputedStyle(target) : null;
      const targetFocusSnapshot = targetFocusStyle ? {
        borderStyle: targetFocusStyle.borderStyle,
        outlineStyle: targetFocusStyle.outlineStyle,
        outlineColor: targetFocusStyle.outlineColor,
        outlineWidth: targetFocusStyle.outlineWidth,
        boxShadow: targetFocusStyle.boxShadow,
        backgroundColor: targetFocusStyle.backgroundColor,
        borderTopWidth: targetFocusStyle.borderTopWidth
      } : null;
      const confirmFocusBefore = document.activeElement;
      if (confirm) confirm.focus();
      const confirmFocusStyle = confirm ? getComputedStyle(confirm) : null;
      const confirmFocusSnapshot = confirmFocusStyle ? {
        outlineColor: confirmFocusStyle.outlineColor,
        outlineWidth: confirmFocusStyle.outlineWidth,
        outlineStyle: confirmFocusStyle.outlineStyle,
        backgroundColor: confirmFocusStyle.backgroundColor,
        boxShadow: confirmFocusStyle.boxShadow
      } : null;
      if (confirmFocusBefore && confirmFocusBefore !== document.body && confirmFocusBefore.focus) confirmFocusBefore.focus();
      if (targetFocusBefore && targetFocusBefore !== document.body && targetFocusBefore.focus) targetFocusBefore.focus();
      function inputState(input) {
        const style = input ? getComputedStyle(input) : null;
        return {
          ariaInvalid: input ? input.getAttribute('aria-invalid') || '' : '',
          ariaDescribedBy: input ? input.getAttribute('aria-describedby') || '' : '',
          borderWidth: style ? style.borderTopWidth : '',
          borderStyle: style ? style.borderTopStyle : '',
          borderColor: style ? style.borderTopColor : '',
          matchesInvalidSelector: !!input && input.matches('.cat-grid tbody textarea[data-cat-input][aria-invalid="true"]'),
          view: document.body ? document.body.getAttribute('data-cat-view') || '' : ''
        };
      }
      const warningState = inputState(target);
      const blockingState = inputState(blockingTarget);
      const codeOnlyBlockingState = inputState(codeOnlyBlockingTarget);
      const codeOnlyWarningState = inputState(codeOnlyWarningTarget);
      const explicitUnknownWarningState = inputState(explicitUnknownWarningTarget);
      const explicitUnknownErrorState = inputState(explicitUnknownErrorTarget);
      const confirmMarkNode = confirm ? confirm.querySelector('.cat-confirm-mark') : null;
      const confirmMarkBox = confirmMarkNode ? confirmMarkNode.getBoundingClientRect() : null;
      const confirmMarkStyle = confirmMarkNode ? getComputedStyle(confirmMarkNode) : null;
      const confirmMarkColor = confirmMarkStyle ? confirmMarkStyle.color : '';
      const confirmBackground = confirm ? getComputedStyle(confirm).backgroundColor : '';
      return {
        activeHeight: active ? active.getBoundingClientRect().height : 0,
        inactiveHeights: inactive.map(function (row) { return row.getBoundingClientRect().height; }),
        targetEditable: !!target && !target.disabled && !target.readOnly,
        confirm: confirm ? {
          ariaLabel: confirm.getAttribute('aria-label') || '',
          title: confirm.getAttribute('title') || '',
           key: confirm.getAttribute('aria-keyshortcuts') || '',
           pressed: confirm.getAttribute('aria-pressed') || '',
           mark: confirmMarkNode ? confirmMarkNode.textContent.trim() : '',
           markVisible: !!confirmMarkNode && !!confirmMarkBox && confirmMarkBox.width > 0 && confirmMarkBox.height > 0 && !!confirmMarkStyle && confirmMarkStyle.visibility !== 'hidden' && confirmMarkStyle.display !== 'none' && confirmMarkStyle.fontSize !== '0px',
           borderStyle: getComputedStyle(confirm).borderStyle,
           background: getComputedStyle(confirm).backgroundColor,
           checkedStateVisible: /未確認|確認済み/.test(confirm.getAttribute('aria-label') || ''),
          farRight: confirm.closest('td') === active.lastElementChild
        } : null,
        warningState: warningState,
        blockingState: blockingState,
        codeOnlyBlockingState: codeOnlyBlockingState,
        codeOnlyWarningState: codeOnlyWarningState,
        explicitUnknownWarningState: explicitUnknownWarningState,
        explicitUnknownErrorState: explicitUnknownErrorState,
        visual: {
          activeOutlineWidth: activeStyle ? Number.parseFloat(activeStyle.outlineWidth) || 0 : 99,
          activeBorderWidth: activeStyle ? Math.max(Number.parseFloat(activeStyle.borderTopWidth) || 0, Number.parseFloat(activeStyle.borderBottomWidth) || 0) : 99,
          activeSurface: activeCellStyle ? activeCellStyle.backgroundColor : '',
          sourceSurface: sourceCell ? getComputedStyle(sourceCell).backgroundColor : '',
          targetSurface: activeCellStyle ? activeCellStyle.backgroundColor : '',
           sourceTargetDistinct: !!sourceCell && !!activeCell && !!activeCellStyle && getComputedStyle(sourceCell).backgroundColor === activeCellStyle.backgroundColor && getComputedStyle(activeCell).borderLeftWidth === '1px',
           sourceTargetSeparationWidth: activeCellStyle ? activeCellStyle.borderLeftWidth : '',
           sourceSurfaceWhite: !!sourceCell && isLightColor(getComputedStyle(sourceCell).backgroundColor),
           targetEditorWhite: !!target && isLightColor(getComputedStyle(target).backgroundColor),
          activeEdgeAtMost1: !!activeStyle && (Number.parseFloat(activeStyle.outlineWidth) || 0) <= 1 && (Math.max(Number.parseFloat(activeStyle.borderTopWidth) || 0, Number.parseFloat(activeStyle.borderBottomWidth) || 0) <= 1),
          activeSurfaceLight: !!activeCellStyle && isLightColor(activeCellStyle.backgroundColor),
          activeSurfaceLavender: !!activeCellStyle && isLavenderColor(activeCellStyle.backgroundColor),
          locationWidth: locationCell ? locationCell.getBoundingClientRect().width : 99,
          sourceLeft: sourceCell ? sourceCell.getBoundingClientRect().left : 9999,
          targetLeft: targetBox ? targetBox.left : 9999,
          sourceTop: sourceBox ? sourceBox.top : 9999,
          targetTop: targetBox ? targetBox.top : 9999,
          sourceTargetSameBand: !!sourceBox && !!targetBox && Math.abs(sourceBox.top - targetBox.top) <= 2,
          targetStartsInMiddle: !!targetBox && targetBox.left >= window.innerWidth * .4 && targetBox.left <= window.innerWidth * .55,
          firstCellVisibleText: firstCellVisibleText,
          firstCellOnlyNumber: /^\d+$/.test(firstCellVisibleText),
          firstCellHasStateGlyph: !!(firstCell && /[○◐✓]/.test(firstCellVisibleText)),
          sourceStartsNearLeft: !!sourceCell && sourceCell.getBoundingClientRect().left < 200,
          normalSurface: inactiveCell ? getComputedStyle(inactiveCell).backgroundColor : '',
          normalSurfaceWhite: !!inactiveCell && isLightColor(getComputedStyle(inactiveCell).backgroundColor),
          activeOneLineCompact: !!active && active.getBoundingClientRect().height <= 80,
          activeTextareaHeight: target ? target.getBoundingClientRect().height : 0,
          activeTextareaMinHeight: activeTextareaStyle ? activeTextareaStyle.minHeight : '',
          activeTextareaLineHeight: activeTextareaStyle ? activeTextareaStyle.lineHeight : '',
           errorBoundaryVisible: !!blockingTarget && !!targetErrorSnapshot && blockingErrorAriaInvalid === 'true' && targetErrorSnapshot.borderTopStyle === 'solid' && targetErrorSnapshot.borderTopWidth === '2px',
           errorAriaInvalid: blockingErrorAriaInvalid,
           errorBorderStyle: targetErrorSnapshot ? targetErrorSnapshot.borderTopStyle : '',
          errorBorderTopStyle: targetErrorSnapshot ? targetErrorSnapshot.borderTopStyle : '',
          errorBorderRightStyle: targetErrorSnapshot ? targetErrorSnapshot.borderRightStyle : '',
          errorBorderWidth: targetErrorSnapshot ? targetErrorSnapshot.borderTopWidth : '',
          focusBorderStyle: targetFocusSnapshot ? targetFocusSnapshot.borderStyle : '',
          focusOutlineStyle: targetFocusSnapshot ? targetFocusSnapshot.outlineStyle : '',
          targetFocusOutlineColor: targetFocusSnapshot ? targetFocusSnapshot.outlineColor : '',
          targetFocusOutlineWidth: targetFocusSnapshot ? targetFocusSnapshot.outlineWidth : '',
          targetFocusBackground: targetFocusSnapshot ? targetFocusSnapshot.backgroundColor : '',
          targetFocusContrast: targetFocusSnapshot ? contrastRatio(targetFocusSnapshot.outlineColor, targetFocusSnapshot.backgroundColor) : 0,
          confirmFocusOutlineColor: confirmFocusSnapshot ? confirmFocusSnapshot.outlineColor : '',
          confirmFocusOutlineWidth: confirmFocusSnapshot ? confirmFocusSnapshot.outlineWidth : '',
          confirmFocusOutlineStyle: confirmFocusSnapshot ? confirmFocusSnapshot.outlineStyle : '',
          confirmFocusBackground: confirmFocusSnapshot ? confirmFocusSnapshot.backgroundColor : '',
          confirmFocusContrast: confirmFocusSnapshot ? contrastRatio(confirmFocusSnapshot.outlineColor, confirmFocusSnapshot.backgroundColor) : 0,
          unconfirmedMarkColor: confirmMarkColor,
          unconfirmedMarkBackground: confirmBackground,
          unconfirmedMarkContrast: confirmMarkColor && confirmBackground ? contrastRatio(confirmMarkColor, confirmBackground) : 0,
          blockingFocusBoxShadow: blockingFocusSnapshot ? blockingFocusSnapshot.boxShadow : '',
          blockingFocusOutlineStyle: blockingFocusSnapshot ? blockingFocusSnapshot.outlineStyle : '',
          blockingFocusBorderStyle: blockingFocusSnapshot ? blockingFocusSnapshot.borderStyle : '',
          errorFocusDistinct: !!targetErrorSnapshot && !!targetFocusSnapshot && targetErrorSnapshot.borderTopWidth === '2px' && targetFocusSnapshot.borderStyle === 'solid' && targetFocusSnapshot.outlineStyle === 'solid' && targetFocusSnapshot.outlineColor !== targetErrorSnapshot.borderTopColor && /2px/.test(targetFocusSnapshot.boxShadow || ''),
           focusRingWidth: targetFocusSnapshot ? (String(targetFocusSnapshot.boxShadow || '').match(/0px 0px 0px (\d+)px/) || [])[1] || '' : '',
          targetFocusBoxShadow: targetFocusSnapshot ? targetFocusSnapshot.boxShadow : '',
          inactiveTextareaHeight: inactiveTextarea ? inactiveTextarea.getBoundingClientRect().height : 0,
          inactiveTextareaMinHeight: inactiveTextareaStyle ? inactiveTextareaStyle.minHeight : '',
          inactiveTextareaLineHeight: inactiveTextareaStyle ? inactiveTextareaStyle.lineHeight : '',
          gridWrapHeight: gridWrap ? gridWrap.getBoundingClientRect().height : 0,
          tableHeight: table ? table.getBoundingClientRect().height : 0,
          tableCssHeight: tableStyle.height,
          tbodyHeight: tbody ? tbody.getBoundingClientRect().height : 0,
          gridWrapFlex: gridWrapStyle.flex,
          tableDisplay: tableStyle.display,
          tbodyDisplay: tbodyStyle.display,
          activeCellHeights: active ? Array.from(active.cells).map(function (cell) { const style = getComputedStyle(cell); return { className: cell.className, height: cell.getBoundingClientRect().height, paddingTop: style.paddingTop, paddingBottom: style.paddingBottom }; }) : [],
          inactiveCellHeights: inactive[0] ? Array.from(inactive[0].cells).map(function (cell) { const style = getComputedStyle(cell); return { className: cell.className, height: cell.getBoundingClientRect().height, paddingTop: style.paddingTop, paddingBottom: style.paddingBottom }; }) : [],
          tabStyles: tabStyles,
          tabsNotDarkFilled: tabStyles.length === 7 && tabStyles.every(function (style) { return !isDarkColor(style.background); }),
          railWidth: railBox ? railBox.width : 0,
          railHeight: railBox ? railBox.height : 0,
          railBackground: railStyle ? railStyle.backgroundColor : '',
          railBorderRadius: railStyle ? Number.parseFloat(railStyle.borderTopLeftRadius) || 0 : 99,
          railCompactSquare: !!railBox && railBox.width >= 32 && railBox.width <= 36 && railBox.height >= 32 && railBox.height <= 36 && Math.abs(railBox.width - railBox.height) <= 1,
          railNotDarkFilled: !!railStyle && !isDarkColor(railStyle.backgroundColor),
          fontFamily: gridStyle.fontFamily,
          fontContainsUi: /Segoe UI|system-ui/i.test(gridStyle.fontFamily),
          ordinaryWeight: ordinaryText ? Number.parseInt(getComputedStyle(ordinaryText).fontWeight, 10) || 0 : 999,
          headerVisuallyHidden: headerStyle.position === 'absolute' && headerStyle.width === '1px' && headerStyle.height === '1px',
          headerVisible: headerStyle.position !== 'absolute' && headerStyle.display !== 'none'
        }
      };
    });
    async function captureExplicitSeverity(index) {
      await page.locator('#cat-grid-body tr[data-cat-row="' + index + '"] textarea[data-cat-input]').click();
      await page.waitForFunction(function (rowIndex) { return !!document.querySelector('#cat-grid-body tr[data-cat-row="' + rowIndex + '"].is-active'); }, index, { timeout: 10000 });
      await page.locator('.cat-segment-actions [data-cat-inspector="qc"]').click();
      await page.waitForFunction(function () { return !document.getElementById('cat-preview-dock').hidden && document.getElementById('cat-tab-qc').getAttribute('aria-selected') === 'true'; }, null, { timeout: 10000 });
      return await page.evaluate(function (rowIndex) {
        const row = document.querySelector('#cat-grid-body tr[data-cat-row="' + rowIndex + '"]');
        const cards = Array.from(document.querySelectorAll('#cat-qc-list .cat-qc-card'));
        return {
          rowActionable: !!row && row.getAttribute('data-yaku-cat-state') !== 'reviewed',
          cardClasses: cards.map(function (card) { return card.className; }),
          hasErrorCard: cards.some(function (card) { return card.classList.contains('is-error'); }),
          hasWarningCard: cards.some(function (card) { return card.classList.contains('is-warn'); })
        };
      }, index);
    }
    observed.rows.explicitUnknownWarning = await captureExplicitSeverity(4);
    observed.rows.explicitUnknownError = await captureExplicitSeverity(5);
    await page.locator('#cat-qa-open').click();
    await page.waitForFunction(function () { return !!document.getElementById('cat-qa-dialog') && document.getElementById('cat-qa-dialog').open; }, null, { timeout: 10000 });
    observed.rows.explicitSeverityQa = await page.evaluate(function () {
      return Array.from(document.querySelectorAll('#cat-qa-list .cat-qa-group')).reduce(function (out, group) {
        const blocking = group.classList.contains('is-blocking');
        const title = group.querySelector('h3');
        const isQcOrWarningGroup = !!title && !/未確認/.test(title.textContent || '');
        Array.from(group.querySelectorAll('[data-cat-qa-jump]')).forEach(function (item) {
          const index = item.getAttribute('data-cat-qa-jump');
          if (index === '4') out.warningInBlocking = out.warningInBlocking || blocking;
          if (index === '4' && isQcOrWarningGroup) out.warningInNonBlocking = out.warningInNonBlocking || !blocking;
          if (index === '5') out.errorInBlocking = out.errorInBlocking || blocking;
          if (index === '5' && isQcOrWarningGroup) out.errorInNonBlocking = out.errorInNonBlocking || !blocking;
        });
        return out;
      }, { warningInBlocking: false, warningInNonBlocking: false, errorInBlocking: false, errorInNonBlocking: false });
    });
    await page.locator('#cat-qa-dialog button[value="cancel"]').click();
    await page.locator('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]').click();
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr[data-cat-row="0"].is-active'); }, null, { timeout: 10000 });
    const normalRow = page.locator('#cat-grid-body tr[data-cat-row="1"]');
    const normalTarget = normalRow.locator('textarea[data-cat-input]');
    const normalRowHeightBefore = await normalRow.evaluate(function (node) { return node.getBoundingClientRect().height; });
    await normalRow.hover();
    await page.waitForTimeout(150);
    const normalHover = await page.evaluate(function () {
      function luma(value) {
        const match = String(value || '').match(/rgba?\(([^)]+)\)/);
        if (!match) return 255;
        const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
        return parts.length >= 3 ? 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2] : 255;
      }
      const row = document.querySelector('#cat-grid-body tr[data-cat-row="1"]');
      const source = row && row.querySelector('td.cat-source');
      return { rowHeight: row ? row.getBoundingClientRect().height : 0, sourceBackground: source ? getComputedStyle(source).backgroundColor : '', sourceLuma: source ? luma(getComputedStyle(source).backgroundColor) : 255 };
    });
    await normalTarget.click();
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr[data-cat-row="1"].is-active'); }, null, { timeout: 10000 });
    await page.mouse.move(4, 4);
    await page.waitForTimeout(150);
    observed.rows.micro = await page.evaluate(function (payload) {
      function luma(value) {
        const match = String(value || '').match(/rgba?\(([^)]+)\)/);
        if (!match) return 255;
        const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
        return parts.length >= 3 ? 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2] : 255;
      }
      function relativeLuma(value) {
        const match = String(value || '').match(/rgba?\(([^)]+)\)/);
        if (!match) return null;
        const parts = match[1].split(',').map(function (part) { return Number.parseFloat(part.trim()); });
        if (parts.length < 3 || parts.slice(0, 3).some(function (part) { return !Number.isFinite(part); })) return null;
        return parts.slice(0, 3).map(function (part) { const channel = part / 255; return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4); }).reduce(function (sum, channel, index) { return sum + channel * [0.2126, 0.7152, 0.0722][index]; }, 0);
      }
      function contrastRatio(foreground, background) {
        const foregroundLuma = relativeLuma(foreground), backgroundLuma = relativeLuma(background);
        if (foregroundLuma === null || backgroundLuma === null) return 0;
        const lighter = Math.max(foregroundLuma, backgroundLuma), darker = Math.min(foregroundLuma, backgroundLuma);
        return (lighter + 0.05) / (darker + 0.05);
      }
      const row = document.querySelector('#cat-grid-body tr[data-cat-row="1"].is-active');
      const source = row && row.querySelector('td.cat-source');
      const sourceText = row && row.querySelector('.cat-source-text');
      const target = row && row.querySelector('textarea[data-cat-input]');
      const confirm = row && row.querySelector('.cat-col-confirm button');
      const sourceStyle = sourceText ? getComputedStyle(sourceText) : null;
      const targetStyle = target ? getComputedStyle(target) : null;
      const confirmBox = confirm ? confirm.getBoundingClientRect() : null;
      const sourceBox = sourceText ? sourceText.getBoundingClientRect() : null;
      const targetBox = target ? target.getBoundingClientRect() : null;
      const sourceCellStyle = source ? getComputedStyle(source) : null;
      const selectedBackground = sourceCellStyle ? sourceCellStyle.backgroundColor : '';
      return {
        rowHeight: row ? row.getBoundingClientRect().height : 0,
        fontSize: sourceStyle ? sourceStyle.fontSize : '',
        targetFontSize: targetStyle ? targetStyle.fontSize : '',
        lineHeight: sourceStyle ? sourceStyle.lineHeight : '',
        targetLineHeight: targetStyle ? targetStyle.lineHeight : '',
        baselineDelta: sourceBox && targetBox ? Math.abs((sourceBox.top + sourceBox.height / 2) - (targetBox.top + targetBox.height / 2)) : 99,
        selectedBackground: selectedBackground,
        selectedLuma: luma(selectedBackground),
        hoverBackground: payload.hover.sourceBackground,
        hoverSelectedDistinct: payload.hover.sourceBackground !== selectedBackground && Math.abs(payload.hover.sourceLuma - luma(selectedBackground)) >= 1,
        targetBackground: targetStyle ? targetStyle.backgroundColor : '',
        targetCursor: targetStyle ? targetStyle.cursor : '',
        targetRadius: targetStyle ? Number.parseFloat(targetStyle.borderTopLeftRadius) || 0 : 0,
        focusRing: targetStyle ? targetStyle.boxShadow : '',
        focusOutline: targetStyle ? targetStyle.outlineStyle : '',
        focusOutlineColor: targetStyle ? targetStyle.outlineColor : '',
        focusOutlineWidth: targetStyle ? targetStyle.outlineWidth : '',
        targetFocusContrast: targetStyle ? contrastRatio(targetStyle.outlineColor, targetStyle.backgroundColor) : 0,
        singleSoftFocusRing: !!targetStyle && /0px 0px 0px 2px/.test(targetStyle.boxShadow || '') && targetStyle.outlineStyle === 'solid' && targetStyle.outlineWidth === '2px' && contrastRatio(targetStyle.outlineColor, targetStyle.backgroundColor) >= 3 && !/rgb\(0, 0, 0\)|navy/.test(targetStyle.boxShadow || ''),
        confirmWidth: confirmBox ? confirmBox.width : 0,
        confirmHeight: confirmBox ? confirmBox.height : 0,
        confirmBackground: confirm ? getComputedStyle(confirm).backgroundColor : '',
        confirmBorderStyle: confirm ? getComputedStyle(confirm).borderStyle : '',
        ordinaryRowHeightBefore: payload.before,
        hoverRowHeight: payload.hover.rowHeight
      };
    }, { before: normalRowHeightBefore, hover: normalHover });
    await page.locator('#cat-grid-body tr[data-cat-row="0"] textarea[data-cat-input]').click();
    await page.waitForFunction(function () { return !!document.querySelector('#cat-grid-body tr[data-cat-row="0"].is-active'); }, null, { timeout: 10000 });
    const target = page.locator('#cat-grid-body tr.is-active textarea[data-cat-input]');
    observed.rows.longTranslation = await page.evaluate(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      const row = input && input.closest('tr');
      if (!input || !row) return { longRowHeight: 0, longTextareaHeight: 0, longScrollHeight: 0, restoredRowHeight: 0, restoredTextareaHeight: 0 };
      input.value = 'A long translation that must remain readable in the editor.\nIt wraps onto a second line without an internal scrollbar.';
      input.dispatchEvent(new Event('input', { bubbles: true }));
      const longRowHeight = row.getBoundingClientRect().height;
      const longTextareaHeight = input.getBoundingClientRect().height;
      const longScrollHeight = input.scrollHeight;
      input.value = 'Alpha';
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.blur();
      return { longRowHeight: longRowHeight, longTextareaHeight: longTextareaHeight, longScrollHeight: longScrollHeight, restoredRowHeight: row.getBoundingClientRect().height, restoredTextareaHeight: input.getBoundingClientRect().height };
    });
    await page.waitForTimeout(100);
    await page.evaluate(function () { const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]'); if (input) input.removeAttribute('data-undo-original'); });
    await target.fill('Beta');
    await target.blur();
    await page.waitForFunction(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      const row = input && input.closest('tr');
      return input && row && input.value === 'Beta' && input.getAttribute('data-original') === 'Beta' && !row.classList.contains('cat-dirty');
    }, null, { timeout: 10000 });
    observed.rows.autosaved = await page.evaluate(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      return { value: input ? input.value : '', baseline: input ? input.getAttribute('data-original') : '', undoSnapshot: input ? input.getAttribute('data-undo-original') : '' };
    });
    observed.rows.targetStillEditableAfterFill = observed.rows.autosaved.value === 'Beta';
    observed.rows.focusedRowHeight = await page.locator('#cat-grid-body tr.is-active').evaluate(function (node) { return node.getBoundingClientRect().height; });
    observed.rows.focusedTargetShadow = await target.evaluate(function (node) { return getComputedStyle(node).boxShadow; });
    await page.locator('#cat-tab-revisions').click();
    await page.waitForFunction(function () { const node = document.querySelector('#cat-panel-revisions [data-cat-revert]'); return node && !node.hidden; }, null, { timeout: 10000 });
    observed.rows.ordinaryUndoReachable = await page.evaluate(function () {
      const node = document.querySelector('#cat-panel-revisions [data-cat-revert]');
      return !!node && !node.hidden && node.getAttribute('data-cat-revert') === '0';
    });
    await page.locator('#cat-panel-revisions [data-cat-revert="0"]').click();
    await page.waitForFunction(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      const panel = document.getElementById('cat-panel-revisions');
      return input && input.value === 'Alpha' && !input.hasAttribute('data-undo-original') && panel && !panel.querySelector('[data-cat-revert]');
    }, null, { timeout: 10000 });
    observed.rows.undoRestored = await page.evaluate(function () {
      const input = document.querySelector('#cat-grid-body tr.is-active textarea[data-cat-input]');
      const panel = document.getElementById('cat-panel-revisions');
      return !!input && input.value === 'Alpha' && input.getAttribute('data-original') === 'Alpha' && !input.hasAttribute('data-undo-original') && !!panel && !panel.querySelector('[data-cat-revert]');
    });
    observed.rows.undoMockSavedValue = savedProject.segments.find(function (segment) { return Number(segment.index) === 0; }).translation;
    observed.rows.undoNoStaleSnapshot = observed.rows.undoRestored && observed.rows.undoMockSavedValue === 'Alpha';
    observed.ribbonPanels = {};
    await page.locator('#cat-inspector-toggle').click();
    await page.locator('.cat-segment-actions [data-cat-inspector="context"]').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-preview-dock').hidden && document.getElementById('cat-tab-context').getAttribute('aria-selected') === 'true'; }, null, { timeout: 10000 });
    observed.ribbonPanels.context = await page.evaluate(function () { return !document.getElementById('cat-preview-dock').hidden && !document.getElementById('cat-panel-context').hidden; });
    await page.locator('#cat-inspector-toggle').click();
    await page.locator('.cat-segment-actions [data-cat-inspector="qc"]').click();
    await page.waitForFunction(function () { return !document.getElementById('cat-preview-dock').hidden && document.getElementById('cat-tab-qc').getAttribute('aria-selected') === 'true'; }, null, { timeout: 10000 });
    observed.ribbonPanels.qc = await page.evaluate(function () { return !document.getElementById('cat-preview-dock').hidden && !document.getElementById('cat-panel-qc').hidden; });
    const confirmButton = page.locator('#cat-grid-body tr.is-active .cat-col-confirm button').first();
    observed.rows.confirmBefore = await page.evaluate(function () {
      const button = document.querySelector('#cat-grid-body tr[data-cat-row="0"] .cat-col-confirm button');
      const mark = button && button.querySelector('.cat-confirm-mark');
      const box = mark && mark.getBoundingClientRect();
      const style = mark && getComputedStyle(mark);
      return { mark: mark ? mark.textContent.trim() : '', markVisible: !!mark && !!box && box.width > 0 && box.height > 0 && !!style && style.visibility !== 'hidden' && style.display !== 'none' && style.fontSize !== '0px', ariaLabel: button ? button.getAttribute('aria-label') || '' : '', title: button ? button.getAttribute('title') || '' : '' };
    });
    await confirmButton.click();
    await page.waitForFunction(function () {
      const button = document.querySelector('#cat-grid-body tr[data-cat-row="0"] .cat-col-confirm button');
      const mark = button && button.querySelector('.cat-confirm-mark');
      return !!button && button.classList.contains('is-confirmed') && !!mark && mark.textContent.trim() === '✓';
    }, null, { timeout: 10000 });
    observed.rows.confirmAfter = await page.evaluate(function () {
      const button = document.querySelector('#cat-grid-body tr[data-cat-row="0"] .cat-col-confirm button');
      const mark = button && button.querySelector('.cat-confirm-mark');
      const box = mark && mark.getBoundingClientRect();
      const style = mark && getComputedStyle(mark);
      return { mark: mark ? mark.textContent.trim() : '', markVisible: !!mark && !!box && box.width > 0 && box.height > 0 && !!style && style.visibility !== 'hidden' && style.display !== 'none' && style.fontSize !== '0px', ariaLabel: button ? button.getAttribute('aria-label') || '' : '', title: button ? button.getAttribute('title') || '' : '', borderStyle: button ? getComputedStyle(button).borderStyle : '' };
    });
    observed.rows.confirmClickCompleted = true;

    function sourceTargetAccepts(value) {
      return !value.headerVisible && /^原文・(?:日本語|英語)$/.test(value.sourceHeading) && /^訳文・(?:日本語|英語)$/.test(value.targetHeading) && value.sourceTargetDistinct && value.sourceSurfaceWhite && value.targetEditorWhite && value.sourceTargetSeparationWidth === '1px';
    }
    function stateAccepts(value) {
      return value.warningNoInvalid && value.warningNoRedBoundary && value.blockingInvalid && value.blockingRedBoundary && value.codeOnlyBlockingInvalid === 'true' && value.codeOnlyBlockingDescribedBy === 'cat-qc-list' && value.codeOnlyWarningInvalid !== 'true' && value.codeOnlyWarningDescribedBy === '' && value.explicitUnknownWarningInvalid !== 'true' && value.explicitUnknownWarningDescribedBy === '' && value.explicitUnknownErrorInvalid === 'true' && value.explicitUnknownErrorDescribedBy === 'cat-qc-list' && value.explicitUnknownWarningCard && value.explicitUnknownErrorCard && value.explicitUnknownWarningQaNonBlocking && !value.explicitUnknownWarningQaBlocking && value.explicitUnknownErrorQaBlocking && !value.explicitUnknownErrorQaNonBlocking && value.errorBoundaryVisible && value.errorAriaInvalid === 'true' && value.errorBorderWidth === '2px' && value.errorFocusDistinct && value.focusRingWidth === '2' && value.confirmPressed === '' && value.confirmBeforeMark === '–' && value.confirmAfterMark === '✓' && value.confirmBeforeMarkVisible && value.confirmAfterMarkVisible && value.confirmBorderStyle === 'solid' && value.confirmCheckedStateVisible && value.confirmFarRight && contrastAccepts(value);
    }
    function contrastAccepts(value) {
      return Number(value.targetFocusContrast) >= 3 && Number(value.quickInputFocusContrast) >= 3 && Number(value.confirmFocusContrast) >= 3 && Number(value.unconfirmedMarkContrast) >= 3;
    }
    function quickInputInsetAccepts(value) {
      const inset = value && value.quickInputInset;
      return !!inset && Number(inset.paddingLeft) >= 10 && Number(inset.paddingRight) >= 10 && Number(inset.paddingTop) >= 10 && Number(inset.paddingBottom) >= 10 && Number(inset.guideToFocusEdgeLeft) >= 10 && Number(inset.guideToFocusEdgeTop) >= 10 && Number(inset.fileLaneGap) >= 12 && inset.guideAligned;
    }
    function startAccepts(value) {
      return value.canvasNearWhite && value.surfaceWhite && value.ruleNeutral && value.workingSurfaceRadius >= 4 && value.workingSurfaceRadius <= 6 && value.entryBordered && value.entrySurfaceWhite && value.railAndMain && value.mainBeforeRail && value.visualMainBeforeRail && value.mainMateriallyLarger && value.twoColumn && value.fullWidthRhythm && value.sharedCanvas && value.headingAccessible && !value.headingVisualDuplicate && value.fileStripSeparated && value.fileStripCompact && value.fileStripRadius <= 1 && value.resume && value.resume.noNameDeleteOverlap && value.resume.ellipsisReady && value.resume.truncated && value.resume.sourcePreviewVisible && value.resume.fallbackAbsent && value.resume.duplicatePreviewDistinct && value.resume.duplicatePreviewVisibleDistinct && !value.horizontalOverflow && quickInputInsetAccepts(value);
    }
    function startNarrowAccepts(value) {
      return value.mainBeforeRail && value.twoColumn && value.mainMateriallyLarger && value.railWidth >= 300 && value.railWidth <= 340 && value.resumeNoNameDeleteOverlap && value.resumeEllipsisReady && value.resumeTruncated && value.noPageOverflow && quickInputInsetAccepts(value);
    }
    function tokenRgb(value) {
      const text = String(value || '').trim().toLowerCase();
      let match = text.match(/^#([0-9a-f]{6})$/);
      if (match) return [parseInt(match[1].slice(0, 2), 16), parseInt(match[1].slice(2, 4), 16), parseInt(match[1].slice(4, 6), 16)];
      match = text.match(/^#([0-9a-f]{3})$/);
      if (match) return [parseInt(match[1][0] + match[1][0], 16), parseInt(match[1][1] + match[1][1], 16), parseInt(match[1][2] + match[1][2], 16)];
      match = text.match(/rgba?\(([^)]+)\)/);
      return match ? match[1].split(',').slice(0, 3).map(function (part) { return Number.parseFloat(part.trim()); }) : null;
    }
    function tokenClose(first, second) {
      const a = tokenRgb(first), b = tokenRgb(second);
      return !!a && !!b && a.length === 3 && b.length === 3 && Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2])) <= 20;
    }
    function sharedSystemAccepts(value) {
      return startAccepts(value.start) && value.start.quickBorderColor !== '' && value.start.quickRuleNeutral && value.start.quickAccentSoft === '#faf8ff' && tokenClose(value.start.startRuleColor || value.start.quickBorderColor, value.workspace.headerRuleColor) && tokenClose(value.start.startLineToken, value.workspace.workspaceLineToken);
    }
    function accepts(value) {
      return value.canvasRatio >= 0.9 && !value.docsPersistent && value.tabs.join('|') === expectedTabs.join('|') && value.editorTop <= 170 && value.locationWidth <= 1 && value.activeHeight >= 56 && value.activeHeight <= 64 && value.inactiveMax >= 54 && value.inactiveMax <= 64 && value.sourceTargetSameBand && value.targetStartsInMiddle && sourceTargetAccepts(value) && stateAccepts(value) && microAccepts(value.micro);
    }
    function visualAccepts(value) {
      return value.headerVisuallyHidden && value.activeEdgeAtMost1 && value.activeSurfaceLight && value.activeSurfaceLavender && value.normalSurfaceWhite && value.sourceSurfaceWhite && value.targetEditorWhite && value.sourceTargetSeparationWidth === '1px' && value.tabsNotDarkFilled && value.railCompactSquare && value.railNotDarkFilled && value.fontContainsUi && value.ordinaryWeight <= 500;
    }
    function microAccepts(value) {
      return value.fontSize === '16px' && value.targetFontSize === '16px' && value.lineHeight === '20px' && value.targetLineHeight === '20px' && value.baselineDelta <= 8 && value.hoverSelectedDistinct && value.targetBackground === 'rgb(255, 255, 255)' && value.targetCursor === 'text' && value.targetRadius >= 3 && value.targetRadius <= 5 && value.singleSoftFocusRing && Number(value.targetFocusContrast) >= 3 && value.confirmWidth === 34 && value.confirmHeight === 34 && value.confirmBorderStyle === 'solid' && value.ordinaryRowHeightBefore >= 54 && value.ordinaryRowHeightBefore <= 64 && value.hoverRowHeight >= 54 && value.hoverRowHeight <= 64 && value.rowHeight >= 54 && value.rowHeight <= 64;
    }
    observed.inactiveMax = Math.max.apply(Math, observed.rows.inactiveHeights);
    const acceptanceValue = { canvasRatio: observed.canvas.canvasRatio, docsPersistent: observed.canvas.docsOpenByDefault, tabs: observed.tabs, editorTop: observed.canvas.gridTop, locationWidth: observed.rows.visual.locationWidth, activeHeight: observed.rows.activeHeight, inactiveMax: observed.inactiveMax, sourceTargetSameBand: observed.rows.visual.sourceTargetSameBand, targetStartsInMiddle: observed.rows.visual.targetStartsInMiddle, headerVisible: observed.canvas.headerVisible || observed.rows.visual.headerVisible, sourceHeading: observed.canvas.sourceHeading, targetHeading: observed.canvas.targetHeading, sourceTargetDistinct: observed.rows.visual.sourceTargetDistinct, sourceSurfaceWhite: observed.rows.visual.sourceSurfaceWhite, targetEditorWhite: observed.rows.visual.targetEditorWhite, sourceTargetSeparationWidth: observed.rows.visual.sourceTargetSeparationWidth, errorBoundaryVisible: observed.rows.visual.errorBoundaryVisible, errorAriaInvalid: observed.rows.visual.errorAriaInvalid, errorBorderWidth: observed.rows.visual.errorBorderWidth, errorFocusDistinct: observed.rows.visual.errorFocusDistinct, focusRingWidth: observed.rows.visual.focusRingWidth, targetFocusContrast: observed.rows.visual.targetFocusContrast, quickInputFocusContrast: observed.start.quickInputFocusContrast, confirmFocusContrast: observed.rows.visual.confirmFocusContrast, unconfirmedMarkContrast: observed.rows.visual.unconfirmedMarkContrast, warningNoInvalid: observed.rows.warningState && observed.rows.warningState.ariaInvalid !== 'true', warningNoRedBoundary: observed.rows.warningState && !(observed.rows.warningState.borderWidth === '2px' && observed.rows.warningState.borderColor === 'rgb(180, 35, 24)'), blockingInvalid: observed.rows.blockingState && observed.rows.blockingState.ariaInvalid === 'true', blockingRedBoundary: observed.rows.blockingState && observed.rows.blockingState.borderWidth === '2px' && observed.rows.blockingState.borderStyle === 'solid' && observed.rows.blockingState.borderColor === 'rgb(180, 35, 24)', codeOnlyBlockingInvalid: observed.rows.codeOnlyBlockingState ? observed.rows.codeOnlyBlockingState.ariaInvalid : '', codeOnlyBlockingDescribedBy: observed.rows.codeOnlyBlockingState ? observed.rows.codeOnlyBlockingState.ariaDescribedBy : '', codeOnlyWarningInvalid: observed.rows.codeOnlyWarningState ? observed.rows.codeOnlyWarningState.ariaInvalid : '', codeOnlyWarningDescribedBy: observed.rows.codeOnlyWarningState ? observed.rows.codeOnlyWarningState.ariaDescribedBy : '', explicitUnknownWarningInvalid: observed.rows.explicitUnknownWarningState ? observed.rows.explicitUnknownWarningState.ariaInvalid : '', explicitUnknownWarningDescribedBy: observed.rows.explicitUnknownWarningState ? observed.rows.explicitUnknownWarningState.ariaDescribedBy : '', explicitUnknownErrorInvalid: observed.rows.explicitUnknownErrorState ? observed.rows.explicitUnknownErrorState.ariaInvalid : '', explicitUnknownErrorDescribedBy: observed.rows.explicitUnknownErrorState ? observed.rows.explicitUnknownErrorState.ariaDescribedBy : '', explicitUnknownWarningCard: observed.rows.explicitUnknownWarning ? observed.rows.explicitUnknownWarning.hasWarningCard && !observed.rows.explicitUnknownWarning.hasErrorCard : false, explicitUnknownErrorCard: observed.rows.explicitUnknownError ? observed.rows.explicitUnknownError.hasErrorCard && !observed.rows.explicitUnknownError.hasWarningCard : false, explicitUnknownWarningQaNonBlocking: observed.rows.explicitSeverityQa ? observed.rows.explicitSeverityQa.warningInNonBlocking : false, explicitUnknownWarningQaBlocking: observed.rows.explicitSeverityQa ? observed.rows.explicitSeverityQa.warningInBlocking : false, explicitUnknownErrorQaBlocking: observed.rows.explicitSeverityQa ? observed.rows.explicitSeverityQa.errorInBlocking : false, explicitUnknownErrorQaNonBlocking: observed.rows.explicitSeverityQa ? observed.rows.explicitSeverityQa.errorInNonBlocking : false, confirmPressed: observed.rows.confirm ? observed.rows.confirm.pressed : '', confirmBeforeMark: observed.rows.confirmBefore ? observed.rows.confirmBefore.mark : '', confirmAfterMark: observed.rows.confirmAfter ? observed.rows.confirmAfter.mark : '', confirmBeforeMarkVisible: observed.rows.confirmBefore ? observed.rows.confirmBefore.markVisible : false, confirmAfterMarkVisible: observed.rows.confirmAfter ? observed.rows.confirmAfter.markVisible : false, confirmMark: observed.rows.confirm ? observed.rows.confirm.mark : '', confirmBorderStyle: observed.rows.confirm ? observed.rows.confirm.borderStyle : '', confirmCheckedStateVisible: observed.rows.confirm ? observed.rows.confirm.checkedStateVisible : false, confirmFarRight: observed.rows.confirm ? observed.rows.confirm.farRight : false };
    acceptanceValue.micro = observed.rows.micro;
    observed.accepted = accepts(acceptanceValue);
    observed.startAccepted = startAccepts(observed.start) && startNarrowAccepts(observed.startNarrow);
    observed.startNarrowAccepted = startNarrowAccepts(observed.startNarrow);
    observed.sharedSystemAccepted = sharedSystemAccepts({ start: observed.start, workspace: observed.canvas });
    observed.negativeSelfTest = !accepts({ canvasRatio: 0.89, docsPersistent: true, tabs: expectedTabs.slice().reverse(), editorTop: 181, locationWidth: 2, activeHeight: 81, inactiveMax: 65, sourceTargetSameBand: false, targetStartsInMiddle: false, headerVisible: true, sourceHeading: '', targetHeading: '', sourceTargetDistinct: false, sourceSurfaceWhite: false, targetEditorWhite: false, sourceTargetSeparationWidth: '2px', errorBoundaryVisible: false, errorAriaInvalid: '', errorBorderWidth: '0px', errorFocusDistinct: false, focusRingWidth: '', warningNoInvalid: false, warningNoRedBoundary: false, blockingInvalid: false, blockingRedBoundary: false, confirmPressed: '', confirmBeforeMark: '', confirmAfterMark: '', confirmBeforeMarkVisible: false, confirmAfterMarkVisible: false, confirmMark: '', confirmBorderStyle: '', confirmCheckedStateVisible: false, confirmFarRight: false, micro: { fontSize: '', targetFontSize: '', lineHeight: '', targetLineHeight: '', baselineDelta: 99, hoverSelectedDistinct: false, targetBackground: '', targetCursor: '', targetRadius: 99, singleSoftFocusRing: false, confirmWidth: 0, confirmHeight: 0, confirmBorderStyle: 'dashed', ordinaryRowHeightBefore: 0, hoverRowHeight: 0, rowHeight: 0 } });
    const validStartFixture = { canvasNearWhite: true, surfaceWhite: true, ruleNeutral: true, workingSurfaceRadius: 5, entryBordered: true, entrySurfaceWhite: true, railAndMain: true, mainBeforeRail: true, visualMainBeforeRail: true, mainMateriallyLarger: true, twoColumn: true, fullWidthRhythm: true, sharedCanvas: true, headingAccessible: true, headingVisualDuplicate: false, fileStripSeparated: true, fileStripCompact: true, fileStripRadius: 0, horizontalOverflow: false, resume: { noNameDeleteOverlap: true, ellipsisReady: true, truncated: true, sourcePreviewVisible: true, fallbackAbsent: true, duplicatePreviewDistinct: true, duplicatePreviewVisibleDistinct: true }, quickInputInset: { paddingLeft: 12, paddingRight: 12, paddingTop: 10, paddingBottom: 10, guideToFocusEdgeLeft: 15, guideToFocusEdgeTop: 13, fileLaneGap: 16, guideAligned: true }, quickBorderColor: 'rgb(236, 234, 240)', quickRuleNeutral: true, quickAccentSoft: '#faf8ff', startLineToken: '#eceaf0', startRuleColor: 'rgb(236, 234, 240)' };
    observed.protectedNegativeSelfTests = {
      sourceTarget: !sourceTargetAccepts({ headerVisible: true, sourceHeading: '原文・日本語', targetHeading: '訳文・英語', sourceTargetDistinct: false, sourceSurfaceWhite: true, targetEditorWhite: true, sourceTargetSeparationWidth: '2px' }),
      state: !stateAccepts({ errorBoundaryVisible: false, errorAriaInvalid: 'true', errorBorderWidth: '2px', errorFocusDistinct: true, focusRingWidth: '2', confirmPressed: 'false', confirmMark: 'bad-square', confirmBorderStyle: 'dashed', confirmCheckedStateVisible: true, confirmFarRight: true }),
      startOrder: !startAccepts(Object.assign({}, validStartFixture, { mainBeforeRail: false, visualMainBeforeRail: false })),
      startHierarchy: !startAccepts(Object.assign({}, validStartFixture, { mainMateriallyLarger: false, mainWidth: 300, railWidth: 340 })),
      startResumeOverlap: !startAccepts(Object.assign({}, validStartFixture, { resume: { noNameDeleteOverlap: false, ellipsisReady: true, truncated: true } })),
      startResumeDuplicate: !startAccepts(Object.assign({}, validStartFixture, { resume: { noNameDeleteOverlap: true, ellipsisReady: true, truncated: true, sourcePreviewVisible: true, fallbackAbsent: true, duplicatePreviewDistinct: true, duplicatePreviewVisibleDistinct: false } })),
      startOldLanding: !startAccepts(Object.assign({}, validStartFixture, { fullWidthRhythm: false, sharedCanvas: false, headingAccessible: false, fileStripCompact: false, workingSurfaceRadius: 16, quickBorderColor: 'rgb(31, 58, 95)', quickRuleNeutral: false })),
      startHeadingDuplicate: !startAccepts(Object.assign({}, validStartFixture, { headingAccessible: false, headingVisualDuplicate: true })),
      startQuickInset: !startAccepts(Object.assign({}, validStartFixture, { quickInputInset: { paddingLeft: 2, paddingRight: 2, paddingTop: 2, paddingBottom: 2, guideToFocusEdgeLeft: 5, guideToFocusEdgeTop: 5, fileLaneGap: 16, guideAligned: true } })),
      sharedSystemCatOnly: !sharedSystemAccepts({ start: validStartFixture, workspace: { headerRuleColor: 'rgb(31, 58, 95)', workspaceLineToken: '#1f3a5f' } }),
      focusContrast: !contrastAccepts({ targetFocusContrast: 2.99, quickInputFocusContrast: 2.99, confirmFocusContrast: 2.99, unconfirmedMarkContrast: 2.99 })
    };
    observed.visualAccepted = visualAccepts(observed.rows.visual);
    observed.visualNegativeSelfTest = !visualAccepts({ activeEdgeAtMost1: false, activeSurfaceLight: false, activeSurfaceLavender: false, normalSurfaceWhite: false, tabsNotDarkFilled: false, railCompactSquare: false, railNotDarkFilled: false, fontContainsUi: false, ordinaryWeight: 600 });
    observed.microAccepted = microAccepts(observed.rows.micro);
    observed.microNegativeSelfTest = !microAccepts({ fontSize: '16px', targetFontSize: '16px', lineHeight: '20px', targetLineHeight: '20px', baselineDelta: 20, hoverSelectedDistinct: false, targetBackground: 'rgb(31, 58, 95)', targetCursor: 'default', targetRadius: 0, singleSoftFocusRing: false, confirmWidth: 46, confirmHeight: 46, confirmBorderStyle: 'dashed', ordinaryRowHeightBefore: 80, hoverRowHeight: 80, rowHeight: 80 });
    if (await page.locator('#cat-editor-layout.is-docs-open').count()) await page.locator('#cat-docs-toggle').click();
    await page.waitForTimeout(50);
    await page.screenshot({ path: screenshotPath, fullPage: false });
    observed.ok = true;
  } catch (error) {
    observed.errors.push(String(error && error.stack || error));
  } finally {
    if (browser) await browser.close().catch(function () {});
    await new Promise(function (resolve) { server.close(resolve); });
    fs.writeFileSync(outputPath, JSON.stringify(observed, null, 2), 'utf8');
  }
  process.exitCode = observed.ok ? 0 : 1;
})();
'@
[IO.File]::WriteAllText($YakuT9194Driver, $YakuT9194NodeScript, [Text.UTF8Encoding]::new($false))

try {
    & ([string]$YakuT9194Node.Source) $YakuT9194Driver ($YakuT9194Www.Replace('\', '/')) $YakuT9194ProjectPath $YakuT9194ObservedPath $YakuT9194Screenshot $YakuT9194StartScreenshot $YakuT9194ProbeDir 2>&1 | ForEach-Object { Write-Host ('  node: ' + $_) -ForegroundColor DarkGray }
    $YakuT9194NodeExit = $LASTEXITCODE
    Assert-T9194 -Condition ($YakuT9194NodeExit -eq 0 -and (Test-Path -LiteralPath $YakuT9194ObservedPath -PathType Leaf)) -Message 'Chromium opened the actual CAT route at 1912x987'
    if (-not (Test-Path -LiteralPath $YakuT9194ObservedPath -PathType Leaf)) { exit 1 }
    $YakuT9194Observed = Get-Content -LiteralPath $YakuT9194ObservedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($YakuT9194Error in @($YakuT9194Observed.errors)) { Write-Host ('  Chromium error: ' + [string]$YakuT9194Error) -ForegroundColor Red }
    foreach ($YakuT9194Console in @($YakuT9194Observed.console)) { Write-Host ('  Chromium console: ' + [string]$YakuT9194Console) -ForegroundColor Red }
    if ([bool]$YakuT9194Observed.currentPremiumRoute) {
        Write-Host 'UNMEASURED: the current Premium root route is covered by Test-YakuV9194PremiumStartRoute.' -ForegroundColor Yellow
        exit $YakuT9194Unmeasured
    }
    Assert-T9194 -Condition (@($YakuT9194Observed.errors).Count -eq 0 -and @($YakuT9194Observed.console).Count -eq 0) -Message 'the rendered route had no page or console errors'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.initialView.start.exact -and [bool]$YakuT9194Observed.initialView.start.duplicateFree -and [bool]$YakuT9194Observed.initialView.start.placeholderFree -and [string]$YakuT9194Observed.initialView.start.value -eq 'start' -and [bool]$YakuT9194Observed.initialView.workspace.exact -and [bool]$YakuT9194Observed.initialView.workspace.duplicateFree -and [bool]$YakuT9194Observed.initialView.workspace.placeholderFree -and [string]$YakuT9194Observed.initialView.workspace.value -eq 'workspace') -Message ('initial HTML responses carry one explicit data-cat-view attribute before JavaScript (' + [string]$YakuT9194Observed.initialView.start.value + ' / ' + [string]$YakuT9194Observed.initialView.workspace.value + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.initialStyle -and [string]$YakuT9194Observed.initialStyle.view -eq 'start' -and [string]$YakuT9194Observed.initialStyle.entryDisplay -eq 'grid' -and [string]$YakuT9194Observed.initialStyle.entryGrid -ne '' -and [string]$YakuT9194Observed.initialStyle.bodyBackground -ne 'rgb(238, 241, 247)') -Message ('the first observed start render already uses the bordered CAT surface rather than the old blue-gray landing layout (' + [string]$YakuT9194Observed.initialStyle.bodyBackground + ', ' + [string]$YakuT9194Observed.initialStyle.entryDisplay + ', ' + [string]$YakuT9194Observed.initialStyle.entryGrid + ')')
    Assert-T9194 -Condition (-not [bool]$YakuT9194Observed.routeContract.catHasTourMeta -and -not [bool]$YakuT9194Observed.routeContract.catHasTourScript -and -not [bool]$YakuT9194Observed.routeContract.catHasStartLinks -and [bool]$YakuT9194Observed.routeContract.retiredRoutes404) -Message ('CAT has no tour meta/script or tutorial start links, and retired tutorial/preferences endpoints are absent (tutorial ' + [int]$YakuT9194Observed.routeContract.tutorialStatus + ', preferences ' + [int]$YakuT9194Observed.routeContract.preferencesStatus + ')')

    $YakuT9194Canvas = $YakuT9194Observed.canvas
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.canvasRatio -ge 0.9) -Message ('the default bilingual canvas uses at least 90 percent of workspace width (ratio ' + [math]::Round([double]$YakuT9194Canvas.canvasRatio, 3) + ')')
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.gridTop -le 170) -Message ('the wide editor grid begins within the compact chrome budget (' + [math]::Round([double]$YakuT9194Canvas.gridTop, 1) + 'px)')
    # 2026-08-18（利用者判断）: ドックの高さは二値になった。開いている行の
    # 参考情報に実内容があるとき（この題材の既定タブ「候補」は常に用語1件・
    # 一致2件を返す）は従来どおり約280px。参考情報が待機文だけのときは
    # 180pxへ縮めて、余りを表（#cat-grid-wrap）へ渡す（cat.js の
    # syncDockHeightForContent）。ここは前者（実内容あり）を見る。後者は
    # 直後の2本（dockWaitingState / dockContentState、作業メモタブへ切替え
    # →候補タブへ戻す）で見る。範囲そのものは280px契約の値のままで正しい
    # （この題材の候補タブは待機状態にならないため）。
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.dockHeight -ge 220 -and [double]$YakuT9194Canvas.dockHeight -le 320 -and [double]$YakuT9194Canvas.gridHeight -ge 500) -Message ('the dock is about 280px when the open row has real reference content, while the editor keeps at least 500px (' + [math]::Round([double]$YakuT9194Canvas.dockHeight, 1) + 'px dock, ' + [math]::Round([double]$YakuT9194Canvas.gridHeight, 1) + 'px grid)')
    Assert-T9194 -Condition ([double]$YakuT9194Observed.dockWaitingState.dockHeight -ge 160 -and [double]$YakuT9194Observed.dockWaitingState.dockHeight -le 200 -and [double]$YakuT9194Observed.dockWaitingState.gridHeight -ge 500) -Message ('a tab with no real content for this row (作業メモ, which this fixture never populates) collapses the dock to about 180px and hands the freed height to the grid (' + [math]::Round([double]$YakuT9194Observed.dockWaitingState.dockHeight, 1) + 'px dock, ' + [math]::Round([double]$YakuT9194Observed.dockWaitingState.gridHeight, 1) + 'px grid)')
    Assert-T9194 -Condition ([double]$YakuT9194Observed.dockContentState.dockHeight -ge 220 -and [double]$YakuT9194Observed.dockContentState.dockHeight -le 320) -Message ('switching back to a tab with real content (候補) restores the dock to its previous height rather than staying collapsed (' + [math]::Round([double]$YakuT9194Observed.dockContentState.dockHeight, 1) + 'px)')
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.toolbarHeight -le 120 -and [double]$YakuT9194Canvas.rowBHeight -le 36 -and [double]$YakuT9194Canvas.rowCHeight -le 42 -and [double]$YakuT9194Canvas.filtersHeight -le 36 -and [double]$YakuT9194Canvas.searchHeight -le 36) -Message ('the top chrome is three compact strips (toolbar ' + [math]::Round([double]$YakuT9194Canvas.toolbarHeight, 1) + 'px, row B ' + [math]::Round([double]$YakuT9194Canvas.rowBHeight, 1) + 'px, row C ' + [math]::Round([double]$YakuT9194Canvas.rowCHeight, 1) + 'px)')
     $YakuT9194ActionIds = @($YakuT9194Canvas.actionVisibleIds)
     Assert-T9194 -Condition ([double]$YakuT9194Canvas.translateWidth -ge 150 -and $YakuT9194ActionIds -contains 'cat-translate' -and $YakuT9194ActionIds -contains 'cat-export' -and $YakuT9194ActionIds -contains 'cat-export-reviewed' -and $YakuT9194ActionIds -contains 'cat-qa-open' -and $YakuT9194ActionIds -notcontains 'cat-preview-open' -and $YakuT9194ActionIds -notcontains 'cat-preview-dock-toggle' -and [bool]$YakuT9194Canvas.noGenericMoreActions) -Message ('top action row keeps readable translation/output/QA controls without the generic menu (translate ' + [math]::Round([double]$YakuT9194Canvas.translateWidth, 1) + 'px; ' + ($YakuT9194ActionIds -join ',') + ')')
     # 2026-08-18: 道具の帯の文言を「点検結果 N」から内訳で分けた。この題材の
     # 止める指摘は placeholder-residue / structure-validation-error /
     # fixture-unknown-error の3件で、いずれも「訳文が空」ではないので
     # 「書き出しを止める行 3」になる。
     Assert-T9194 -Condition ([string]$YakuT9194Canvas.actionText.'cat-translate' -match '^未訳はありません' -and [string]$YakuT9194Canvas.actionText.'cat-export' -eq '訳文をコピー' -and [string]$YakuT9194Canvas.actionText.'cat-qa-open' -match '^書き出しを止める行\s*3$') -Message ('top action labels name the actor, output, and result explicitly (' + [string]$YakuT9194Canvas.actionText.'cat-translate' + ' / ' + [string]$YakuT9194Canvas.actionText.'cat-export' + ' / ' + [string]$YakuT9194Canvas.actionText.'cat-qa-open' + ')')
     Assert-T9194 -Condition ([string]$YakuT9194Canvas.searchReplace.title -eq '検索と置換' -and (@($YakuT9194Canvas.searchReplace.scopeLabels) -join '|') -eq '原文と訳文|原文|訳文' -and [string]$YakuT9194Canvas.searchReplace.caseLabel -match '大文字と小文字を区別' -and [string]$YakuT9194Canvas.searchReplace.regexLabel -match '正規表現を使う' -and [string]$YakuT9194Canvas.searchReplace.placeholder -eq '置換後の文字列（空欄なら削除）' -and [string]$YakuT9194Canvas.searchReplace.emptyStatus -eq '先に上の検索欄へ検索語を入力してください。' -and [bool]$YakuT9194Canvas.searchReplace.runDisabled -and [double]$YakuT9194Canvas.searchReplace.panelWidth -ge 340) -Message ('search/replace popover has concise scoped copy and disabled empty-state action (' + [math]::Round([double]$YakuT9194Canvas.searchReplace.panelWidth, 1) + 'px)')
     Assert-T9194 -Condition ([string]$YakuT9194Observed.dockMigration.height -eq '280px' -and [string]$YakuT9194Observed.dockMigration.marker -eq '1') -Message ('a legacy 388px dock is migrated once to the compact default (' + [string]$YakuT9194Observed.dockMigration.height + ', marker ' + [string]$YakuT9194Observed.dockMigration.marker + ')')
     Assert-T9194 -Condition ([string]$YakuT9194Observed.dockMigrationPreserve.height -eq '388px' -and [string]$YakuT9194Observed.dockMigrationPreserve.marker -eq '1') -Message 'a deliberate post-migration dock resize remains preserved'
    Assert-T9194 -Condition (-not [bool]$YakuT9194Canvas.docsOpenByDefault -and [string]$YakuT9194Canvas.docsDisplayByDefault -eq 'none') -Message 'documents are closed by default with no persistent side column'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.docs.overlay -and [bool]$YakuT9194Observed.docs.widthPreserved -and [bool]$YakuT9194Observed.docs.enabledItem -and [bool]$YakuT9194Observed.docs.genericNamesDistinct -and [bool]$YakuT9194Observed.docs.sourceHtmlEscaped -and [bool]$YakuT9194Observed.docs.realFileNamePreserved -and [int]$YakuT9194Observed.docs.resumeRequestsDuringRender -eq 0) -Message ('the document list opens as an operable overlay without resume mutations, with distinct pasted names and escaped source text (items ' + [int]$YakuT9194Observed.docs.itemCount + ', resume ' + [int]$YakuT9194Observed.docs.resumeRequestsDuringRender + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.narrowDocs.visible -and [bool]$YakuT9194Observed.narrowDocs.overlay -and [bool]$YakuT9194Observed.narrowDocs.widthPreserved -and [bool]$YakuT9194Observed.narrowDocs.noInspectorTrack -and [bool]$YakuT9194Observed.narrowDocs.closed) -Message ('at 1200px the document list overlays without shrinking the editor or restoring an inspector track (' + [math]::Round([double]$YakuT9194Observed.narrowDocs.gridWidthBefore, 1) + 'px -> ' + [math]::Round([double]$YakuT9194Observed.narrowDocs.gridWidthAfter, 1) + 'px)')

    $YakuT9194ExpectedTabs = @('候補', '過去訳検索', '変更履歴', '文脈', 'この行の点検', '作業メモ', 'プレビュー')
    Assert-T9194 -Condition ((@($YakuT9194Observed.tabs) -join '|') -eq ($YakuT9194ExpectedTabs -join '|')) -Message ('bottom tabs are in the required order: ' + (@($YakuT9194Observed.tabs) -join ' / '))
    Assert-T9194 -Condition (@($YakuT9194Observed.panelSwitches | Where-Object { -not $_.selected -or -not $_.visible }).Count -eq 0) -Message 'each bottom tab selects and exposes its own panel'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.previewToolbar.dockVisible -and [bool]$YakuT9194Observed.previewToolbar.previewSelected -and [bool]$YakuT9194Observed.previewToolbar.previewPanelVisible -and [int]$YakuT9194Observed.previewToolbar.previewItems -ge 4) -Message 'the toolbar preview control opens and selects the preview tab'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.revisions.tabSelected -and [bool]$YakuT9194Observed.revisions.panelVisible -and [bool]$YakuT9194Observed.revisions.comparisonVisible -and [bool]$YakuT9194Observed.revisions.acceptReachable -and [bool]$YakuT9194Observed.revisions.revertReachable -and [bool]$YakuT9194Observed.revisions.revertApplied -and [double]$YakuT9194Observed.revisions.rowHeight -le 64) -Message 'revision comparison stays in the bottom dock with reachable accept/revert controls and a compact row'
    Assert-T9194 -Condition ([string]$YakuT9194Observed.mergeAction.title -eq '次の行と結合' -and [string]$YakuT9194Observed.mergeAction.label -eq '次の行と結合') -Message 'the selected-row merge action names the next row it joins'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.ribbonPanels.context -and [bool]$YakuT9194Observed.ribbonPanels.qc) -Message 'context and QA ribbon actions reopen the selected bottom panel after collapse'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.keyboardResize.changed) -Message ('ArrowUp changes the stored dock height (' + [string]$YakuT9194Observed.keyboardResize.start + ' -> ' + [string]$YakuT9194Observed.keyboardResize.afterArrowUp + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.dockDefault.visible -and [string]::IsNullOrEmpty([string]$YakuT9194Observed.dockDefault.storedOpen)) -Message 'the bottom dock is visible on first use with no stored preference'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.dockStoredClosed.hidden -and [string]$YakuT9194Observed.dockStoredClosed.storedOpen -eq '0') -Message 'an explicit dock-open=0 preference keeps the dock closed'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.dockDefaultRestored.visible -and [string]::IsNullOrEmpty([string]$YakuT9194Observed.dockDefaultRestored.storedOpen)) -Message 'removing the preference restores the first-use open dock'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.collapse.hidden -and [string]$YakuT9194Observed.collapse.expanded -eq 'false' -and [string]$YakuT9194Observed.collapse.text -eq '参考情報を出す' -and [string]$YakuT9194Observed.collapse.storedOpen -eq '0') -Message 'the inspector toggle collapses the bottom dock, reports its state, and stores closed'
    Assert-T9194 -Condition (-not [bool]$YakuT9194Observed.restore.hidden -and [string]$YakuT9194Observed.restore.expanded -eq 'true' -and [string]$YakuT9194Observed.restore.storedOpen -eq '1') -Message 'the inspector toggle restores the bottom dock and stores open'
    Assert-T9194 -Condition ([int]$YakuT9194Observed.candidates.count -ge 2 -and [bool]$YakuT9194Observed.candidates.defaultDetail -and [bool]$YakuT9194Observed.candidates.detailDiffMarked -and [bool]$YakuT9194Observed.candidates.detailEscaped -and [bool]$YakuT9194Observed.candidates.materialVisible -and [bool]$YakuT9194Observed.candidates.firstHorizontal -and [bool]$YakuT9194Observed.candidates.cardNotRounded -and [bool]$YakuT9194Observed.candidates.selectedFirst -and [bool]$YakuT9194Observed.candidates.detailInsertVisible -and [bool]$YakuT9194Observed.candidates.detailInsertSafe) -Message 'candidate dock shows a compact horizontal first match with a visible, escaped detail insert action'
    $candidateSecond = $YakuT9194Observed.candidates.second
    $candidateInsert = $candidateSecond.insert
    $candidateSecondCheck = ([bool]$candidateSecond.detailUpdated -and [bool]$candidateSecond.savedVisible -and [bool]$candidateSecond.selectedSecond -and [bool]$candidateSecond.firstDeselected -and [bool]$candidateSecond.detailInsertVisible -and [bool]$candidateInsert.visible -and [string]$candidateInsert.translation -eq 'Prior target' -and [string]$candidateInsert.referenceId -eq 'prior-2' -and [string]$candidateInsert.targetAfter -eq 'Prior target' -and [bool]$YakuT9194Observed.candidates.referenceSaved)
    Assert-T9194 -Condition $candidateSecondCheck -Message 'candidate keyboard/click selection updates the prior-match detail and saves its reference on insert'
    $candidateRace = $YakuT9194Observed.candidates.race
    Assert-T9194 -Condition ([bool]$candidateRace.initialAction.visible -and [string]$candidateRace.initialAction.index -eq '0' -and [string]$candidateRace.initialAction.referenceId -eq 'memory-1' -and [bool]$candidateRace.loadingNoAction -and [bool]$candidateRace.staleClickDidNotSave -and [bool]$candidateRace.oldAStillCleared -and [bool]$candidateRace.bAction.visible -and [string]$candidateRace.bAction.index -eq '1' -and [string]$candidateRace.bAction.referenceId -eq 'memory-b' -and [string]$candidateRace.bAction.translation -eq 'Beta candidate' -and [bool]$candidateRace.bSaved) -Message 'delayed candidate responses clear stale actions and only allow the current row reference to be inserted'

    $YakuT9194Rows = $YakuT9194Observed.rows
    $YakuT9194ActiveCells = (@($YakuT9194Rows.visual.activeCellHeights) | ForEach-Object { [string]$_.className + '=' + [math]::Round([double]$_.height, 1) }) -join ', '
    $YakuT9194InactiveCells = (@($YakuT9194Rows.visual.inactiveCellHeights) | ForEach-Object { [string]$_.className + '=' + [math]::Round([double]$_.height, 1) }) -join ', '
    Assert-T9194 -Condition ([double]$YakuT9194Rows.activeHeight -ge 56 -and [double]$YakuT9194Rows.activeHeight -le 64 -and [bool]$YakuT9194Rows.visual.activeOneLineCompact -and [bool]$YakuT9194Rows.visual.sourceTargetSameBand -and [bool]$YakuT9194Rows.visual.targetStartsInMiddle) -Message ('the ordinary active row is 56-64px with source and target visible in one band (' + [math]::Round([double]$YakuT9194Rows.activeHeight, 1) + 'px; source x=' + [math]::Round([double]$YakuT9194Rows.visual.sourceLeft, 1) + ', target x=' + [math]::Round([double]$YakuT9194Rows.visual.targetLeft, 1) + '; cells ' + $YakuT9194ActiveCells + ')')
    Assert-T9194 -Condition ([double]$YakuT9194Rows.longTranslation.longRowHeight -gt 56 -and [double]$YakuT9194Rows.longTranslation.longTextareaHeight -gt 36 -and [double]$YakuT9194Rows.longTranslation.longScrollHeight -le ([double]$YakuT9194Rows.longTranslation.longTextareaHeight + 1) -and [double]$YakuT9194Rows.longTranslation.restoredRowHeight -ge 56 -and [double]$YakuT9194Rows.longTranslation.restoredRowHeight -le 64) -Message ('a multiline translation grows beyond the one-line editor without an internal scroll and returns to compact density (' + [math]::Round([double]$YakuT9194Rows.longTranslation.longRowHeight, 1) + 'px row, ' + [math]::Round([double]$YakuT9194Rows.longTranslation.longTextareaHeight, 1) + 'px textarea)')
    Assert-T9194 -Condition ([double]$YakuT9194Observed.inactiveMax -ge 54 -and [double]$YakuT9194Observed.inactiveMax -le 64) -Message ('ordinary inactive rows stay in the 54-64px density band (max ' + [math]::Round([double]$YakuT9194Observed.inactiveMax, 1) + 'px; cells ' + $YakuT9194InactiveCells + '; wrap ' + [math]::Round([double]$YakuT9194Rows.visual.gridWrapHeight, 1) + 'px/' + [string]$YakuT9194Rows.visual.gridWrapFlex + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.targetEditable -and [bool]$YakuT9194Rows.targetStillEditableAfterFill -and [bool]$YakuT9194Rows.ordinaryUndoReachable -and [string]$YakuT9194Rows.autosaved.value -eq 'Beta' -and [string]$YakuT9194Rows.autosaved.baseline -eq 'Beta' -and [string]$YakuT9194Rows.autosaved.undoSnapshot -eq 'Alpha') -Message 'the target textarea remains editable, autosave advances its baseline, and the pre-edit undo snapshot remains reachable'
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.undoRestored -and [string]$YakuT9194Rows.undoMockSavedValue -eq 'Alpha' -and [bool]$YakuT9194Rows.undoNoStaleSnapshot) -Message 'ordinary undo restores the mock-saved Alpha and clears the session snapshot without stale state'
    Assert-T9194 -Condition ([double]$YakuT9194Rows.focusedRowHeight -ge 56 -and [double]$YakuT9194Rows.focusedRowHeight -le 64 -and [bool]$YakuT9194Rows.micro.singleSoftFocusRing) -Message ('focusing the target keeps the row compact and uses one soft lavender focus ring (' + [math]::Round([double]$YakuT9194Rows.focusedRowHeight, 1) + 'px)')
    Assert-T9194 -Condition ($null -ne $YakuT9194Rows.confirm -and -not [string]::IsNullOrWhiteSpace([string]$YakuT9194Rows.confirm.ariaLabel) -and -not [string]::IsNullOrWhiteSpace([string]$YakuT9194Rows.confirm.title) -and -not [string]::IsNullOrWhiteSpace([string]$YakuT9194Rows.confirm.key) -and [bool]$YakuT9194Rows.confirm.checkedStateVisible -and [bool]$YakuT9194Rows.confirm.farRight -and [string]$YakuT9194Rows.confirm.pressed -eq '' -and [string]$YakuT9194Rows.confirmBefore.mark -eq '–' -and [string]$YakuT9194Rows.confirmAfter.mark -eq '✓' -and [bool]$YakuT9194Rows.confirmBefore.markVisible -and [bool]$YakuT9194Rows.confirmAfter.markVisible -and [string]$YakuT9194Rows.confirm.borderStyle -eq 'solid' -and [bool]$YakuT9194Rows.confirmClickCompleted) -Message ('the far-right confirmation rail keeps accessible simple geometry and changes its visible glyph from unconfirmed dash to confirmed check (' + [string]$YakuT9194Rows.confirmBefore.mark + ' -> ' + [string]$YakuT9194Rows.confirmAfter.mark + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.visual.firstCellOnlyNumber -and -not [bool]$YakuT9194Rows.visual.firstCellHasStateGlyph) -Message ('the wide row number cell shows only the row number, without a duplicate state glyph (' + [string]$YakuT9194Rows.visual.firstCellVisibleText + ')')
    $YakuT9194Visual = $YakuT9194Rows.visual
    Assert-T9194 -Condition ([double]$YakuT9194Visual.locationWidth -le 1 -or [bool]$YakuT9194Visual.sourceStartsNearLeft) -Message ('wide location metadata no longer pushes the source right (location ' + [math]::Round([double]$YakuT9194Visual.locationWidth, 1) + 'px, source x ' + [math]::Round([double]$YakuT9194Visual.sourceLeft, 1) + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.activeEdgeAtMost1 -and [bool]$YakuT9194Visual.activeSurfaceLight -and [bool]$YakuT9194Visual.activeSurfaceLavender -and [bool]$YakuT9194Visual.normalSurfaceWhite -and [bool]$YakuT9194Visual.sourceSurfaceWhite -and [bool]$YakuT9194Visual.targetEditorWhite) -Message ('active row is one pale lavender band, ordinary rows are white, and the target editor stays white (outline ' + [string]$YakuT9194Visual.activeOutlineWidth + 'px, border ' + [string]$YakuT9194Visual.activeBorderWidth + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.tabsNotDarkFilled) -Message 'bottom tabs are transparent/light rather than dark filled'
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.railCompactSquare -and [bool]$YakuT9194Visual.railNotDarkFilled -and [double]$YakuT9194Visual.railBorderRadius -le 4) -Message ('confirmation rail is a compact light square (' + [math]::Round([double]$YakuT9194Visual.railWidth, 1) + 'x' + [math]::Round([double]$YakuT9194Visual.railHeight, 1) + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.fontContainsUi -and [int]$YakuT9194Visual.ordinaryWeight -le 500) -Message ('workspace uses Segoe UI/system-ui and ordinary text is not heavy (' + [string]$YakuT9194Visual.fontFamily + ', weight ' + [string]$YakuT9194Visual.ordinaryWeight + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Canvas.headerVisuallyHidden -and [string]$YakuT9194Canvas.sourceHeading -eq '原文・日本語' -and [string]$YakuT9194Canvas.targetHeading -eq '訳文・英語') -Message ('wide table keeps the existing role/language headings accessible while collapsing the visual thead (' + [string]$YakuT9194Canvas.sourceHeading + ' / ' + [string]$YakuT9194Canvas.targetHeading + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.start.headingAccessible -and -not [bool]$YakuT9194Observed.start.headingVisualDuplicate -and [string]$YakuT9194Observed.start.headingText -eq '文章とWord・Excelを訳す') -Message 'start keeps one accessible pane heading while the prompt supplies the visible task cue'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.start.quickInputInset.accepted -and [bool]$YakuT9194Observed.startNarrow.quickInputInset.accepted) -Message ('start quick input and empty guide keep a readable inset from the focus edge at 1912px and 1200px (wide padding ' + [string]$YakuT9194Observed.start.quickInputInset.paddingLeft + '/' + [string]$YakuT9194Observed.start.quickInputInset.paddingTop + 'px, guide ' + [string]$YakuT9194Observed.start.quickInputInset.guideLeftInset + '/' + [string]$YakuT9194Observed.start.quickInputInset.guideTopInset + 'px, file gap ' + [string]$YakuT9194Observed.start.quickInputInset.fileLaneGap + 'px; narrow padding ' + [string]$YakuT9194Observed.startNarrow.quickInputInset.paddingLeft + '/' + [string]$YakuT9194Observed.startNarrow.quickInputInset.paddingTop + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.sourceTargetDistinct -and [string]$YakuT9194Visual.sourceTargetSeparationWidth -eq '1px' -and [bool]$YakuT9194Visual.sourceSurfaceWhite -and [bool]$YakuT9194Visual.targetEditorWhite) -Message ('source and target share a white work surface with a one-pixel neutral gutter (' + [string]$YakuT9194Visual.sourceTargetSeparationWidth + '; source ' + [string]$YakuT9194Visual.sourceSurface + ' -> target ' + [string]$YakuT9194Visual.targetSurface + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.warningState -and [string]$YakuT9194Rows.warningState.ariaInvalid -ne 'true' -and -not ([string]$YakuT9194Rows.warningState.borderWidth -eq '2px' -and [string]$YakuT9194Rows.warningState.borderColor -eq 'rgb(180, 35, 24)') -and [bool]$YakuT9194Rows.blockingState -and [string]$YakuT9194Rows.blockingState.ariaInvalid -eq 'true' -and [string]$YakuT9194Rows.blockingState.borderWidth -eq '2px' -and [string]$YakuT9194Rows.blockingState.borderColor -eq 'rgb(180, 35, 24)' -and [bool]$YakuT9194Rows.blockingState.matchesInvalidSelector -and [string]$YakuT9194Rows.blockingState.view -eq 'workspace' -and [bool]$YakuT9194Visual.errorBoundaryVisible -and [bool]$YakuT9194Visual.errorFocusDistinct) -Message ('numeric findings remain a visible warning without invalid/red boundary while blocking error has aria-invalid and a simple 2px boundary (warning ' + [string]$YakuT9194Rows.warningState.ariaInvalid + '/' + [string]$YakuT9194Rows.warningState.borderWidth + '/' + [string]$YakuT9194Rows.warningState.borderColor + ', blocking ' + [string]$YakuT9194Rows.blockingState.ariaInvalid + '/' + [string]$YakuT9194Rows.blockingState.borderWidth + '/' + [string]$YakuT9194Rows.blockingState.borderColor + '/match=' + [bool]$YakuT9194Rows.blockingState.matchesInvalidSelector + '/view=' + [string]$YakuT9194Rows.blockingState.view + '; boundary=' + [bool]$YakuT9194Visual.errorBoundaryVisible + ', focusDistinct=' + [bool]$YakuT9194Visual.errorFocusDistinct + ', borderStyle=' + [string]$YakuT9194Visual.blockingFocusBorderStyle + ', outline=' + [string]$YakuT9194Visual.blockingFocusOutlineStyle + ', shadow=' + [string]$YakuT9194Visual.blockingFocusBoxShadow + ', aria=' + [string]$YakuT9194Visual.errorAriaInvalid + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.codeOnlyBlockingState -and [string]$YakuT9194Rows.codeOnlyBlockingState.ariaInvalid -eq 'true' -and [string]$YakuT9194Rows.codeOnlyBlockingState.ariaDescribedBy -eq 'cat-qc-list' -and [bool]$YakuT9194Rows.codeOnlyWarningState -and [string]$YakuT9194Rows.codeOnlyWarningState.ariaInvalid -ne 'true' -and [string]$YakuT9194Rows.codeOnlyWarningState.ariaDescribedBy -eq '') -Message ('code-only qc_preview keeps blocking tool trouble invalid and described while numeric warning stays nonblocking (blocker ' + [string]$YakuT9194Rows.codeOnlyBlockingState.ariaInvalid + '/' + [string]$YakuT9194Rows.codeOnlyBlockingState.ariaDescribedBy + ', numeric ' + [string]$YakuT9194Rows.codeOnlyWarningState.ariaInvalid + '/' + [string]$YakuT9194Rows.codeOnlyWarningState.ariaDescribedBy + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.explicitUnknownWarningState -and [string]$YakuT9194Rows.explicitUnknownWarningState.ariaInvalid -ne 'true' -and [string]$YakuT9194Rows.explicitUnknownWarningState.ariaDescribedBy -eq '' -and [bool]$YakuT9194Rows.explicitUnknownErrorState -and [string]$YakuT9194Rows.explicitUnknownErrorState.ariaInvalid -eq 'true' -and [string]$YakuT9194Rows.explicitUnknownErrorState.ariaDescribedBy -eq 'cat-qc-list' -and [bool]$YakuT9194Rows.explicitUnknownWarning.hasWarningCard -and -not [bool]$YakuT9194Rows.explicitUnknownWarning.hasErrorCard -and [bool]$YakuT9194Rows.explicitUnknownError.hasErrorCard -and -not [bool]$YakuT9194Rows.explicitUnknownError.hasWarningCard -and [bool]$YakuT9194Rows.explicitSeverityQa.warningInNonBlocking -and -not [bool]$YakuT9194Rows.explicitSeverityQa.warningInBlocking -and [bool]$YakuT9194Rows.explicitSeverityQa.errorInBlocking -and -not [bool]$YakuT9194Rows.explicitSeverityQa.errorInNonBlocking) -Message ('explicit unknown severity remains authoritative across editor invalid state, card styling, and QA blocking groups (warning invalid=' + [string]$YakuT9194Rows.explicitUnknownWarningState.ariaInvalid + ', error invalid=' + [string]$YakuT9194Rows.explicitUnknownErrorState.ariaInvalid + ', cards=' + [string]$YakuT9194Rows.explicitUnknownWarning.hasWarningCard + '/' + [string]$YakuT9194Rows.explicitUnknownWarning.hasErrorCard + '/' + [string]$YakuT9194Rows.explicitUnknownError.hasWarningCard + '/' + [string]$YakuT9194Rows.explicitUnknownError.hasErrorCard + ', QA=' + [string]$YakuT9194Rows.explicitSeverityQa.warningInBlocking + '/' + [string]$YakuT9194Rows.explicitSeverityQa.warningInNonBlocking + '/' + [string]$YakuT9194Rows.explicitSeverityQa.errorInBlocking + '/' + [string]$YakuT9194Rows.explicitSeverityQa.errorInNonBlocking + ')')
    Assert-T9194 -Condition (-not [bool]$YakuT9194Observed.narrowWorkspace.headerVisible -and [string]$YakuT9194Observed.narrowWorkspace.sourceHeading -match '原文・' -and [string]$YakuT9194Observed.narrowWorkspace.targetHeading -match '訳文・' -and [bool]$YakuT9194Observed.narrowWorkspace.sourceTargetDivider -and [bool]$YakuT9194Observed.narrowWorkspace.sourceTargetSameBand -and [bool]$YakuT9194Observed.narrowWorkspace.noPageOverflow) -Message ('1200x800 keeps accessible bilingual labels, a one-pixel divider, same-band rows, and no page overflow (' + [string]$YakuT9194Observed.narrowWorkspace.sourceHeading + ' / ' + [string]$YakuT9194Observed.narrowWorkspace.targetHeading + '; header=' + [bool]$YakuT9194Observed.narrowWorkspace.headerVisible + ', divider=' + [bool]$YakuT9194Observed.narrowWorkspace.sourceTargetDivider + ', band=' + [bool]$YakuT9194Observed.narrowWorkspace.sourceTargetSameBand + ', overflow=' + [bool]$YakuT9194Observed.narrowWorkspace.noPageOverflow + ', scroll=' + [double]$YakuT9194Observed.narrowWorkspace.scrollWidth + '/' + [double]$YakuT9194Observed.narrowWorkspace.bodyScrollWidth + ', node=' + [string]$YakuT9194Observed.narrowWorkspace.overflowNode.node + '@' + [double]$YakuT9194Observed.narrowWorkspace.overflowNode.right + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.startAccepted -and [bool]$YakuT9194Observed.startNarrowAccepted -and [bool]$YakuT9194Observed.sharedSystemAccepted) -Message ('start is a main-first bordered CAT workspace at 1912px and remains two-column/no-overflow at 1200px (' + [math]::Round([double]$YakuT9194Observed.start.mainWidth, 1) + 'px main / ' + [math]::Round([double]$YakuT9194Observed.start.railWidth, 1) + 'px utility; accepted=' + [bool]$YakuT9194Observed.startAccepted + ', narrow=' + [bool]$YakuT9194Observed.startNarrowAccepted + ', shared=' + [bool]$YakuT9194Observed.sharedSystemAccepted + ', canvas=' + [bool]$YakuT9194Observed.start.canvasNearWhite + '/' + [bool]$YakuT9194Observed.start.surfaceWhite + '/' + [bool]$YakuT9194Observed.start.ruleNeutral + ', quickRule=' + [bool]$YakuT9194Observed.start.quickRuleNeutral + '/' + [string]$YakuT9194Observed.start.quickBorderColor + ', line=' + [string]$YakuT9194Observed.start.startLineToken + '/' + [string]$YakuT9194Observed.start.startRuleColor + ' vs CAT ' + [string]$YakuT9194Canvas.headerRuleColor + '/' + [string]$YakuT9194Canvas.workspaceLineToken + ', accent=' + [string]$YakuT9194Observed.start.quickAccentSoft + ', radius=' + [double]$YakuT9194Observed.start.workingSurfaceRadius + ', border=' + [bool]$YakuT9194Observed.start.entryBordered + ', surface=' + [bool]$YakuT9194Observed.start.entrySurfaceWhite + ', rail=' + [bool]$YakuT9194Observed.start.railAndMain + ', order=' + [bool]$YakuT9194Observed.start.mainBeforeRail + '/' + [bool]$YakuT9194Observed.start.visualMainBeforeRail + ', hierarchy=' + [bool]$YakuT9194Observed.start.mainMateriallyLarger + ', columns=' + [bool]$YakuT9194Observed.start.twoColumn + ', margin=' + [bool]$YakuT9194Observed.start.fullWidthRhythm + ', shared=' + [bool]$YakuT9194Observed.start.sharedCanvas + ', file=' + [bool]$YakuT9194Observed.start.fileStripCompact + ', heading=' + [bool]$YakuT9194Observed.start.headingAccessible + '/' + [bool]$YakuT9194Observed.start.headingVisualDuplicate + ', resume=' + [bool]$YakuT9194Observed.start.resume.noNameDeleteOverlap + '/' + [bool]$YakuT9194Observed.start.resume.ellipsisReady + '/' + [bool]$YakuT9194Observed.start.resume.truncated + ', narrowResume=' + [bool]$YakuT9194Observed.startNarrow.resumeNoNameDeleteOverlap + '/' + [bool]$YakuT9194Observed.startNarrow.resumeEllipsisReady + '/' + [bool]$YakuT9194Observed.startNarrow.resumeTruncated + ', overflow=' + [bool]$YakuT9194Observed.start.horizontalOverflow + ')')
    Assert-T9194 -Condition ([string]$YakuT9194Observed.start.fileLaneLead -eq 'Word・Excelを訳す' -and [string]$YakuT9194Observed.start.fileLaneNote -eq 'ファイルを選ぶと、文章を行ごとに確認できます。元のファイルは変更せず、訳したファイルを新しいコピーとして保存します。' -and [string]$YakuT9194Observed.start.alignEntryNote -eq '日本語版と英語版のPDFから、再利用する訳を登録します。登録した訳は、次の資料で候補に出ます。') -Message 'start editor uses concise Word/Excel and past-translation prompts without the retired long copy'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.start.resume.sourcePreviewVisible -and [bool]$YakuT9194Observed.start.resume.fallbackAbsent -and [bool]$YakuT9194Observed.start.resume.duplicatePreviewDistinct -and [bool]$YakuT9194Observed.start.resume.duplicatePreviewVisibleDistinct) -Message ('recent generic paste entries use shortened source previews and visibly distinguish duplicate previews before ellipsis (' + ((@($YakuT9194Observed.start.resume.names) -join ' | ')) + ')')
    $YakuT9194ServerSource = [IO.File]::ReadAllText((Join-Path $YakuT9194Root 'src\Server.ps1'))
    $YakuT9194CatProjectSource = [IO.File]::ReadAllText((Join-Path $YakuT9194Root 'src\CatProject.ps1'))
    Assert-T9194 -Condition ($YakuT9194ServerSource.Contains('source_preview = [string]$item.SourcePreview') -and $YakuT9194CatProjectSource.Contains('function Get-YakuCatSavedSourcePreview') -and $YakuT9194CatProjectSource.Contains('SourcePreview = $sourcePreview')) -Message 'the read-only recent-project contract supplies source_preview from saved segments'
    $YakuT9194CatProjectPath = (Join-Path $YakuT9194Root 'src\CatProject.ps1').Replace("'", "''")
    $YakuT9194PreviewFixture = @"
`$ErrorActionPreference = 'Stop'
. '$YakuT9194CatProjectPath'
`$capital = Get-YakuCatSavedSourcePreview -Segments @([pscustomobject]@{ Text = 'Capital Text fixture' })
`$lower = Get-YakuCatSavedSourcePreview -Segments @([pscustomobject]@{ text = 'lower text fixture' })
if ([string]::IsNullOrWhiteSpace([string]`$capital) -or [string]::IsNullOrWhiteSpace([string]`$lower)) { exit 1 }
Write-Output ('capital=' + [string]`$capital + ';lower=' + [string]`$lower)
"@
    $YakuT9194PreviewFixtureOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $YakuT9194PreviewFixture 2>&1)
    $YakuT9194PreviewFixtureExit = $LASTEXITCODE
    Assert-T9194 -Condition ($YakuT9194PreviewFixtureExit -eq 0 -and (($YakuT9194PreviewFixtureOutput -join ' ') -match 'capital=Capital Text fixture') -and (($YakuT9194PreviewFixtureOutput -join ' ') -match 'lower=lower text fixture')) -Message ('saved source preview helper reads real Text/text segment fields (' + (($YakuT9194PreviewFixtureOutput -join ' ').Trim()) + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.microAccepted) -Message ('CAT micro-interactions stay restrained: 16px/20px text, distinct hover, white target, 2px lavender focus, 34px check, and 56px rows (' + [string]$YakuT9194Rows.micro.fontSize + ' / ' + [string]$YakuT9194Rows.micro.lineHeight + ', hover ' + [string]$YakuT9194Rows.micro.hoverBackground + ', selected ' + [string]$YakuT9194Rows.micro.selectedBackground + ')')
    Assert-T9194 -Condition ([double]$YakuT9194Rows.visual.targetFocusContrast -ge 3 -and [double]$YakuT9194Observed.start.quickInputFocusContrast -ge 3 -and [double]$YakuT9194Rows.visual.confirmFocusContrast -ge 3 -and [double]$YakuT9194Rows.visual.unconfirmedMarkContrast -ge 3) -Message ('computed adjacent-color contrast stays at least 3:1 for target focus, start quick-input focus, confirm focus, and unconfirmed dash (target ' + [math]::Round([double]$YakuT9194Rows.visual.targetFocusContrast, 2) + ':1 ' + [string]$YakuT9194Rows.visual.targetFocusOutlineColor + ', start ' + [math]::Round([double]$YakuT9194Observed.start.quickInputFocusContrast, 2) + ':1 ' + [string]$YakuT9194Observed.start.quickInputFocusColor + ', confirm ' + [math]::Round([double]$YakuT9194Rows.visual.confirmFocusContrast, 2) + ':1 ' + [string]$YakuT9194Rows.visual.confirmFocusOutlineColor + ', dash ' + [math]::Round([double]$YakuT9194Rows.visual.unconfirmedMarkContrast, 2) + ':1 ' + [string]$YakuT9194Rows.visual.unconfirmedMarkColor + ')')

    Assert-T9194 -Condition ([bool]$YakuT9194Observed.accepted) -Message 'the complete three-behavior layout predicate accepts the rendered route'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.negativeSelfTest) -Message 'intentional bad-layout fixture is rejected by the acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.sourceTarget) -Message 'intentional source/target visual fixture is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.state) -Message 'intentional input/error/confirmation visual fixture is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startOrder) -Message 'intentional reversed start main/utility order fixture is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startHierarchy) -Message 'intentional weak start main-to-utility hierarchy fixture is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startResumeOverlap) -Message 'intentional overlapping recent-work name/delete fixture is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startResumeDuplicate) -Message 'intentional duplicate recent-work name fixture without a visible prefix is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startOldLanding) -Message 'intentional old landing-width/dark-outline fixture is rejected by its acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startHeadingDuplicate) -Message 'intentional duplicate visible start heading fixture is rejected while the accessible pane heading remains required'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.startQuickInset) -Message 'intentional cramped start quick-input/guide inset fixture is rejected by the acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.sharedSystemCatOnly) -Message 'intentional CAT-only broken visual-token fixture is rejected by the shared-system acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.protectedNegativeSelfTests.focusContrast) -Message 'intentional low-contrast focus/state fixture is rejected by the computed contrast predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.visualNegativeSelfTest) -Message 'intentional dark/oversized visual fixture is rejected by the visual predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.microNegativeSelfTest) -Message 'intentional hover/selection/focus clutter fixture is rejected by the micro-interaction predicate'
    Assert-T9194 -Condition (Test-Path -LiteralPath $YakuT9194Screenshot -PathType Leaf) -Message ('rendered screenshot was captured: ' + $YakuT9194Screenshot)
    Assert-T9194 -Condition (Test-Path -LiteralPath $YakuT9194StartScreenshot -PathType Leaf) -Message ('start-screen screenshot was captured: ' + $YakuT9194StartScreenshot)
}
finally {
    try { Remove-Item -LiteralPath $YakuT9194Temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:T9194Failures.Count -eq 0) {
    Write-Host ('PASS Test-YakuV9194SmartcatEditorLayout (' + $script:T9194Checks + ' checks)') -ForegroundColor Green
    exit 0
}
Write-Host ('FAIL ' + $script:T9194Failures.Count + ' of ' + $script:T9194Checks + ' checks') -ForegroundColor Red
foreach ($YakuT9194Failure in $script:T9194Failures) { Write-Host ('  - ' + $YakuT9194Failure) -ForegroundColor Red }
exit 1
