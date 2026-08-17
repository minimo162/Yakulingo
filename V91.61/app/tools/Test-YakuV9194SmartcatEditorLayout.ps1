#Requires -Version 5.1
<#
  Measure the three Smartcat-like CAT workspace behaviors in real Chromium at
  the user's measured viewport (1912x987). The Node probe serves the repository's
  actual cat.html, cat.js, and cat-workspace.css over a local HTTP route and only
  stubs the CAT API responses.

  This test deliberately keeps the checks narrow:
    1. the bilingual canvas is wide by default and the document list overlays;
    2. one bottom dock has the required tabs, preview routing, resize, and collapse;
    3. normal rows are compact, target text remains editable, and confirmation is
       an accessible far-right control.

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

$YakuT9194Project = [ordered]@{
    id = 'smartcat-layout-screen'
    file_name = 'smartcat-layout.xlsx'
    source = 'text'
    direction = 'to_en'
    kind = 'text'
    document_format = 'xlsx'
    revision = 1
    saved = '2026-08-17T00:00:00Z'
    total = 4
    confirmed = 0
    untranslated = 0
    export_blocked = $false
    segments = @(
        [ordered]@{ index = 0; segment_id = 'layout-0'; kind = 'paragraph'; location = '本文 1'; source = 'First source sentence.'; translation = 'Alpha'; confirmed = $false; origin = 'machine'; can_revise = $true; can_merge = $true; prior_source = 'Previous source sentence.'; prior_translation = 'Previous target sentence.'; qc_findings = @([ordered]@{ code = 'numeric-value-mismatch' }) },
        [ordered]@{ index = 1; segment_id = 'layout-1'; kind = 'paragraph'; location = '本文 2'; source = 'Second source sentence.'; translation = 'Second target sentence.'; confirmed = $false; origin = 'machine' },
        [ordered]@{ index = 2; segment_id = 'layout-2'; kind = 'paragraph'; location = '本文 3'; source = 'Third source sentence.'; translation = 'Third target sentence.'; confirmed = $false; origin = 'machine' },
        [ordered]@{ index = 3; segment_id = 'layout-3'; kind = 'paragraph'; location = '本文 4'; source = 'Fourth source sentence.'; translation = 'Fourth target sentence.'; confirmed = $false; origin = 'machine' }
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
const probeDir = process.argv[6];
const project = JSON.parse(fs.readFileSync(projectPath, 'utf8'));
const types = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8' };
const expectedTabs = ['候補', '過去訳検索', '変更履歴', '文脈', '点検結果', '作業メモ', 'プレビュー'];

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
function cloneProject() { return JSON.parse(JSON.stringify(project)); }
let savedProject = cloneProject();
const pasteOne = cloneProject();
pasteOne.id = 'smartcat-paste-one'; pasteOne.file_name = '貼り付けたテキスト'; pasteOne.source = 'text'; pasteOne.saved = '2026-08-17T01:41:00Z';
pasteOne.segments = [{ index: 0, segment_id: 'paste-one-0', kind: 'paragraph', location: '本文 1', source: '<Alpha> & first pasted source', translation: 'first target', confirmed: false }];
pasteOne.total = 1; pasteOne.confirmed = 0; pasteOne.untranslated = 0;
const pasteTwo = cloneProject();
pasteTwo.id = 'smartcat-paste-two'; pasteTwo.file_name = '貼り付けたテキスト'; pasteTwo.source = 'text'; pasteTwo.saved = '2026-08-17T02:42:00Z';
pasteTwo.segments = [{ index: 0, segment_id: 'paste-two-0', kind: 'paragraph', location: '本文 1', source: 'Second pasted source', translation: 'second target', confirmed: false }];
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
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'layout-gate-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
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
  const body = await readBody(req);
  if (url.pathname === '/api/ready-state') { send(res, { canTranslate: true, label: 'ready', class: 'ok' }); return; }
  if (url.pathname === '/api/cat/recent') {
    send(res, { projects: [
      { id: project.id, file_name: project.file_name, source: project.source, direction: project.direction, total: project.total, confirmed: project.confirmed, saved: project.saved, revision: project.revision },
      { id: pasteOne.id, file_name: pasteOne.file_name, source: pasteOne.source, direction: pasteOne.direction, total: pasteOne.total, confirmed: pasteOne.confirmed, saved: pasteOne.saved, revision: 1, source_preview: '<Alpha> & first pasted source' },
      { id: pasteTwo.id, file_name: pasteTwo.file_name, source: pasteTwo.source, direction: pasteTwo.direction, total: pasteTwo.total, confirmed: pasteTwo.confirmed, saved: pasteTwo.saved, revision: 1, source_preview: 'Second pasted source' },
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
  const observed = { ok: false, errors: [], console: [], expectedTabs: expectedTabs, screenshotPath: screenshotPath };
  let browser = null;
  try {
    const { chromium } = require(require.resolve('playwright', { paths: [probeDir] }));
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
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
    page.on('pageerror', function (error) { observed.errors.push(String(error && error.message || error)); });
    page.on('console', function (message) { if (message.type() === 'error') observed.console.push(message.text()); });
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(project.id), { waitUntil: 'networkidle' });
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
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(project.id), { waitUntil: 'networkidle' });
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
    await page.waitForFunction(function () { return document.querySelectorAll('#cat-grid-body tr[data-cat-row]').length >= 4; }, null, { timeout: 10000 });

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
      if (target) target.focus();
      const targetFocusStyle = target ? getComputedStyle(target) : null;
      if (targetFocusBefore && targetFocusBefore !== document.body && targetFocusBefore.focus) targetFocusBefore.focus();
      return {
        activeHeight: active ? active.getBoundingClientRect().height : 0,
        inactiveHeights: inactive.map(function (row) { return row.getBoundingClientRect().height; }),
        targetEditable: !!target && !target.disabled && !target.readOnly,
        confirm: confirm ? {
          ariaLabel: confirm.getAttribute('aria-label') || '',
          title: confirm.getAttribute('title') || '',
          key: confirm.getAttribute('aria-keyshortcuts') || '',
          checkedStateVisible: /未確認|確認済み/.test(confirm.textContent),
          farRight: confirm.closest('td') === active.lastElementChild
        } : null,
        visual: {
          activeOutlineWidth: activeStyle ? Number.parseFloat(activeStyle.outlineWidth) || 0 : 99,
          activeBorderWidth: activeStyle ? Math.max(Number.parseFloat(activeStyle.borderTopWidth) || 0, Number.parseFloat(activeStyle.borderBottomWidth) || 0) : 99,
          activeSurface: activeCellStyle ? activeCellStyle.backgroundColor : '',
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
          targetFocusBoxShadow: targetFocusStyle ? targetFocusStyle.boxShadow : '',
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
          headerVisuallyHidden: headerStyle.position === 'absolute' && headerStyle.width === '1px' && headerStyle.height === '1px'
        }
      };
    });
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
    await confirmButton.click();
    observed.rows.confirmClickCompleted = true;

    function accepts(value) {
      return value.canvasRatio >= 0.9 && !value.docsPersistent && value.tabs.join('|') === expectedTabs.join('|') && value.editorTop <= 170 && value.locationWidth <= 1 && value.activeHeight >= 56 && value.activeHeight <= 64 && value.inactiveMax >= 54 && value.inactiveMax <= 64 && value.sourceTargetSameBand && value.targetStartsInMiddle;
    }
    function visualAccepts(value) {
      return value.activeEdgeAtMost1 && value.activeSurfaceLight && value.activeSurfaceLavender && value.normalSurfaceWhite && value.tabsNotDarkFilled && value.railCompactSquare && value.railNotDarkFilled && value.fontContainsUi && value.ordinaryWeight <= 500;
    }
    observed.inactiveMax = Math.max.apply(Math, observed.rows.inactiveHeights);
    observed.accepted = accepts({ canvasRatio: observed.canvas.canvasRatio, docsPersistent: observed.canvas.docsOpenByDefault, tabs: observed.tabs, editorTop: observed.canvas.gridTop, locationWidth: observed.rows.visual.locationWidth, activeHeight: observed.rows.activeHeight, inactiveMax: observed.inactiveMax, sourceTargetSameBand: observed.rows.visual.sourceTargetSameBand, targetStartsInMiddle: observed.rows.visual.targetStartsInMiddle });
    observed.negativeSelfTest = !accepts({ canvasRatio: 0.89, docsPersistent: true, tabs: expectedTabs.slice().reverse(), editorTop: 181, locationWidth: 2, activeHeight: 81, inactiveMax: 65, sourceTargetSameBand: false, targetStartsInMiddle: false });
    observed.visualAccepted = visualAccepts(observed.rows.visual);
    observed.visualNegativeSelfTest = !visualAccepts({ activeEdgeAtMost1: false, activeSurfaceLight: false, activeSurfaceLavender: false, normalSurfaceWhite: false, tabsNotDarkFilled: false, railCompactSquare: false, railNotDarkFilled: false, fontContainsUi: false, ordinaryWeight: 600 });
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
    & ([string]$YakuT9194Node.Source) $YakuT9194Driver ($YakuT9194Www.Replace('\', '/')) $YakuT9194ProjectPath $YakuT9194ObservedPath $YakuT9194Screenshot $YakuT9194ProbeDir 2>&1 | ForEach-Object { Write-Host ('  node: ' + $_) -ForegroundColor DarkGray }
    $YakuT9194NodeExit = $LASTEXITCODE
    Assert-T9194 -Condition ($YakuT9194NodeExit -eq 0 -and (Test-Path -LiteralPath $YakuT9194ObservedPath -PathType Leaf)) -Message 'Chromium opened the actual CAT route at 1912x987'
    if (-not (Test-Path -LiteralPath $YakuT9194ObservedPath -PathType Leaf)) { exit 1 }
    $YakuT9194Observed = Get-Content -LiteralPath $YakuT9194ObservedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($YakuT9194Error in @($YakuT9194Observed.errors)) { Write-Host ('  Chromium error: ' + [string]$YakuT9194Error) -ForegroundColor Red }
    foreach ($YakuT9194Console in @($YakuT9194Observed.console)) { Write-Host ('  Chromium console: ' + [string]$YakuT9194Console) -ForegroundColor Red }
    Assert-T9194 -Condition (@($YakuT9194Observed.errors).Count -eq 0 -and @($YakuT9194Observed.console).Count -eq 0) -Message 'the rendered route had no page or console errors'

    $YakuT9194Canvas = $YakuT9194Observed.canvas
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.canvasRatio -ge 0.9) -Message ('the default bilingual canvas uses at least 90 percent of workspace width (ratio ' + [math]::Round([double]$YakuT9194Canvas.canvasRatio, 3) + ')')
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.gridTop -le 170) -Message ('the wide editor grid begins within the compact chrome budget (' + [math]::Round([double]$YakuT9194Canvas.gridTop, 1) + 'px)')
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.dockHeight -ge 220 -and [double]$YakuT9194Canvas.dockHeight -le 320 -and [double]$YakuT9194Canvas.gridHeight -ge 500) -Message ('the default dock is about 280px while the editor keeps at least 500px (' + [math]::Round([double]$YakuT9194Canvas.dockHeight, 1) + 'px dock, ' + [math]::Round([double]$YakuT9194Canvas.gridHeight, 1) + 'px grid)')
    Assert-T9194 -Condition ([double]$YakuT9194Canvas.toolbarHeight -le 120 -and [double]$YakuT9194Canvas.rowBHeight -le 36 -and [double]$YakuT9194Canvas.rowCHeight -le 42 -and [double]$YakuT9194Canvas.filtersHeight -le 36 -and [double]$YakuT9194Canvas.searchHeight -le 36) -Message ('the top chrome is three compact strips (toolbar ' + [math]::Round([double]$YakuT9194Canvas.toolbarHeight, 1) + 'px, row B ' + [math]::Round([double]$YakuT9194Canvas.rowBHeight, 1) + 'px, row C ' + [math]::Round([double]$YakuT9194Canvas.rowCHeight, 1) + 'px)')
     $YakuT9194ActionIds = @($YakuT9194Canvas.actionVisibleIds)
     Assert-T9194 -Condition ([double]$YakuT9194Canvas.translateWidth -ge 150 -and $YakuT9194ActionIds -contains 'cat-translate' -and $YakuT9194ActionIds -contains 'cat-export' -and $YakuT9194ActionIds -contains 'cat-export-reviewed' -and $YakuT9194ActionIds -contains 'cat-qa-open' -and $YakuT9194ActionIds -notcontains 'cat-preview-open' -and $YakuT9194ActionIds -notcontains 'cat-preview-dock-toggle' -and [bool]$YakuT9194Canvas.noGenericMoreActions) -Message ('top action row keeps readable translation/output/QA controls without the generic menu (translate ' + [math]::Round([double]$YakuT9194Canvas.translateWidth, 1) + 'px; ' + ($YakuT9194ActionIds -join ',') + ')')
     Assert-T9194 -Condition ([string]$YakuT9194Canvas.actionText.'cat-translate' -eq '未訳はありません' -and [string]$YakuT9194Canvas.actionText.'cat-export' -eq '訳文をコピー' -and [string]$YakuT9194Canvas.actionText.'cat-qa-open' -eq '点検結果') -Message 'top action labels name the actor, output, and result explicitly'
     Assert-T9194 -Condition ([string]$YakuT9194Canvas.searchReplace.title -eq '検索と置換' -and (@($YakuT9194Canvas.searchReplace.scopeLabels) -join '|') -eq '原文と訳文|原文|訳文' -and [string]$YakuT9194Canvas.searchReplace.caseLabel -match '大文字と小文字を区別' -and [string]$YakuT9194Canvas.searchReplace.regexLabel -match '正規表現を使う' -and [string]$YakuT9194Canvas.searchReplace.placeholder -eq '置換後の文字列（空欄なら削除）' -and [string]$YakuT9194Canvas.searchReplace.emptyStatus -eq '先に上の検索欄へ検索語を入力してください。' -and [bool]$YakuT9194Canvas.searchReplace.runDisabled -and [double]$YakuT9194Canvas.searchReplace.panelWidth -ge 340) -Message ('search/replace popover has concise scoped copy and disabled empty-state action (' + [math]::Round([double]$YakuT9194Canvas.searchReplace.panelWidth, 1) + 'px)')
     Assert-T9194 -Condition ([string]$YakuT9194Observed.dockMigration.height -eq '280px' -and [string]$YakuT9194Observed.dockMigration.marker -eq '1') -Message ('a legacy 388px dock is migrated once to the compact default (' + [string]$YakuT9194Observed.dockMigration.height + ', marker ' + [string]$YakuT9194Observed.dockMigration.marker + ')')
     Assert-T9194 -Condition ([string]$YakuT9194Observed.dockMigrationPreserve.height -eq '388px' -and [string]$YakuT9194Observed.dockMigrationPreserve.marker -eq '1') -Message 'a deliberate post-migration dock resize remains preserved'
    Assert-T9194 -Condition (-not [bool]$YakuT9194Canvas.docsOpenByDefault -and [string]$YakuT9194Canvas.docsDisplayByDefault -eq 'none') -Message 'documents are closed by default with no persistent side column'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.docs.overlay -and [bool]$YakuT9194Observed.docs.widthPreserved -and [bool]$YakuT9194Observed.docs.enabledItem -and [bool]$YakuT9194Observed.docs.genericNamesDistinct -and [bool]$YakuT9194Observed.docs.sourceHtmlEscaped -and [bool]$YakuT9194Observed.docs.realFileNamePreserved -and [int]$YakuT9194Observed.docs.resumeRequestsDuringRender -eq 0) -Message ('the document list opens as an operable overlay without resume mutations, with distinct pasted names and escaped source text (items ' + [int]$YakuT9194Observed.docs.itemCount + ', resume ' + [int]$YakuT9194Observed.docs.resumeRequestsDuringRender + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.narrowDocs.visible -and [bool]$YakuT9194Observed.narrowDocs.overlay -and [bool]$YakuT9194Observed.narrowDocs.widthPreserved -and [bool]$YakuT9194Observed.narrowDocs.noInspectorTrack -and [bool]$YakuT9194Observed.narrowDocs.closed) -Message ('at 1200px the document list overlays without shrinking the editor or restoring an inspector track (' + [math]::Round([double]$YakuT9194Observed.narrowDocs.gridWidthBefore, 1) + 'px -> ' + [math]::Round([double]$YakuT9194Observed.narrowDocs.gridWidthAfter, 1) + 'px)')

    $YakuT9194ExpectedTabs = @('候補', '過去訳検索', '変更履歴', '文脈', '点検結果', '作業メモ', 'プレビュー')
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
    Assert-T9194 -Condition ([double]$YakuT9194Rows.focusedRowHeight -ge 56 -and [double]$YakuT9194Rows.focusedRowHeight -le 64 -and [string]$YakuT9194Rows.focusedTargetShadow -ne 'none') -Message ('focusing the target keeps the row compact and adds a visible focus edge (' + [math]::Round([double]$YakuT9194Rows.focusedRowHeight, 1) + 'px)')
    Assert-T9194 -Condition ($null -ne $YakuT9194Rows.confirm -and -not [string]::IsNullOrWhiteSpace([string]$YakuT9194Rows.confirm.ariaLabel) -and -not [string]::IsNullOrWhiteSpace([string]$YakuT9194Rows.confirm.title) -and -not [string]::IsNullOrWhiteSpace([string]$YakuT9194Rows.confirm.key) -and [bool]$YakuT9194Rows.confirm.checkedStateVisible -and [bool]$YakuT9194Rows.confirm.farRight -and [bool]$YakuT9194Rows.confirmClickCompleted) -Message 'the far-right confirmation rail is named, keyboard-described, visibly stateful, and operable'
    Assert-T9194 -Condition ([bool]$YakuT9194Rows.visual.firstCellOnlyNumber -and -not [bool]$YakuT9194Rows.visual.firstCellHasStateGlyph) -Message ('the wide row number cell shows only the row number, without a duplicate state glyph (' + [string]$YakuT9194Rows.visual.firstCellVisibleText + ')')
    $YakuT9194Visual = $YakuT9194Rows.visual
    Assert-T9194 -Condition ([double]$YakuT9194Visual.locationWidth -le 1 -or [bool]$YakuT9194Visual.sourceStartsNearLeft) -Message ('wide location metadata no longer pushes the source right (location ' + [math]::Round([double]$YakuT9194Visual.locationWidth, 1) + 'px, source x ' + [math]::Round([double]$YakuT9194Visual.sourceLeft, 1) + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.activeEdgeAtMost1 -and [bool]$YakuT9194Visual.activeSurfaceLight -and [bool]$YakuT9194Visual.activeSurfaceLavender -and [bool]$YakuT9194Visual.normalSurfaceWhite) -Message ('active row is lavender/light and ordinary rows are white with at-most-one-pixel edge (outline ' + [string]$YakuT9194Visual.activeOutlineWidth + 'px, border ' + [string]$YakuT9194Visual.activeBorderWidth + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.tabsNotDarkFilled) -Message 'bottom tabs are transparent/light rather than dark filled'
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.railCompactSquare -and [bool]$YakuT9194Visual.railNotDarkFilled -and [double]$YakuT9194Visual.railBorderRadius -le 4) -Message ('confirmation rail is a compact light square (' + [math]::Round([double]$YakuT9194Visual.railWidth, 1) + 'x' + [math]::Round([double]$YakuT9194Visual.railHeight, 1) + 'px)')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.fontContainsUi -and [int]$YakuT9194Visual.ordinaryWeight -le 500) -Message ('workspace uses Segoe UI/system-ui and ordinary text is not heavy (' + [string]$YakuT9194Visual.fontFamily + ', weight ' + [string]$YakuT9194Visual.ordinaryWeight + ')')
    Assert-T9194 -Condition ([bool]$YakuT9194Visual.headerVisuallyHidden) -Message 'wide table headings remain accessible but are visually collapsed'

    Assert-T9194 -Condition ([bool]$YakuT9194Observed.accepted) -Message 'the complete three-behavior layout predicate accepts the rendered route'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.negativeSelfTest) -Message 'intentional bad-layout fixture is rejected by the acceptance predicate'
    Assert-T9194 -Condition ([bool]$YakuT9194Observed.visualNegativeSelfTest) -Message 'intentional dark/oversized visual fixture is rejected by the visual predicate'
    Assert-T9194 -Condition (Test-Path -LiteralPath $YakuT9194Screenshot -PathType Leaf) -Message ('rendered screenshot was captured: ' + $YakuT9194Screenshot)
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
