#Requires -Version 5.1
<#
  Verify the current Premium CAT root route in real Chromium.

  The former V9194 gate waited for #quick-area, which is intentionally hidden
  inside the preserved legacy DOM. The current root route is the visible
  #premium-cat-start surface created by premium-ui.js. This gate waits for that
  surface and checks the actual start and workspace entry contracts.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'www'
$node = Get-Command node -ErrorAction SilentlyContinue
$unmeasured = 3
$failures = New-Object System.Collections.Generic.List[string]
$checks = 0

function Assert-Route {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor DarkGray }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9194PremiumStartRoute'
if ($null -eq $node) {
    Write-Host 'UNMEASURED: node is not available.' -ForegroundColor Red
    exit $unmeasured
}

$probeDir = (Join-Path $PSScriptRoot 'cat-screen').Replace('\', '/')
$null = & ([string]$node.Source) -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright is not available.' -ForegroundColor Red
    exit $unmeasured
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-v9194-premium-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp -Force
$driver = Join-Path $temp 'premium-start-route.js'
$projectPath = Join-Path $temp 'project.json'
$observedPath = Join-Path $temp 'observed.json'
$startScreenshot = Join-Path $temp 'start.png'
$workspaceScreenshot = Join-Path $temp 'workspace.png'

$project = [ordered]@{
    id = 'v9194-premium-route'
    file_name = 'premium-route.xlsx'
    source = 'file'
    direction = 'to_en'
    kind = 'file'
    document_format = 'xlsx'
    revision = 1
    saved = '2026-08-23T00:00:00Z'
    total = 2
    confirmed = 0
    untranslated = 0
    export_blocked = $false
    segments = @(
        [ordered]@{ index = 0; segment_id = 'premium-route-0'; kind = 'paragraph'; location = 'Sheet1!A1'; source = 'First source sentence.'; translation = 'First target sentence.'; confirmed = $false; origin = 'machine'; can_revise = $true; can_merge = $true; qc_findings = @() },
        [ordered]@{ index = 1; segment_id = 'premium-route-1'; kind = 'paragraph'; location = 'Sheet1!A2'; source = 'Second source sentence.'; translation = 'Second target sentence.'; confirmed = $false; origin = 'machine'; can_revise = $true; can_merge = $true; qc_findings = @() }
    )
}
[IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

$nodeScript = @'
'use strict';
const fs = require('fs');
const http = require('http');
const path = require('path');

const wwwDir = path.resolve(process.argv[2]);
const projectPath = process.argv[3];
const outputPath = process.argv[4];
const startScreenshot = process.argv[5];
const workspaceScreenshot = process.argv[6];
const probeDir = process.argv[7];
const project = JSON.parse(fs.readFileSync(projectPath, 'utf8'));
const contentTypes = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

function sendJson(res, value, statusCode) {
  res.writeHead(statusCode || 200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(value));
}
function cloneProject() { return JSON.parse(JSON.stringify(project)); }
function visible(node) {
  if (!node) return false;
  const style = getComputedStyle(node), box = node.getBoundingClientRect();
  return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
}
function serveHtml(req, res) {
  let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
  const view = new URL(req.url, 'http://127.0.0.1').searchParams.has('project') ? 'workspace' : 'start';
  html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'v9194-premium-token')
    .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
    .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
    .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
    .replace(/__YAKU_IMPORT__/g, '0')
    .replace(/__YAKU_VIEW__/g, view)
    .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
    .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS P Gothic');
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
}
const server = http.createServer(function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/' || url.pathname === '/cat') { serveHtml(req, res); return; }
  if (url.pathname.startsWith('/assets/')) {
    const asset = path.resolve(wwwDir, url.pathname.slice(1));
    if (asset.indexOf(wwwDir + path.sep) !== 0 || !fs.existsSync(asset)) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': contentTypes[path.extname(asset)] || 'application/octet-stream' });
    fs.createReadStream(asset).pipe(res);
    return;
  }
  if (url.pathname === '/tutorial' || url.pathname === '/api/desktop/preferences') { res.writeHead(404); res.end('not found'); return; }
  if (url.pathname === '/api/ready-state') { sendJson(res, { canTranslate: true, label: 'ready', class: 'ok' }); return; }
  if (url.pathname === '/api/cat/recent') {
    sendJson(res, { projects: [{ id: project.id, file_name: project.file_name, source: project.source, direction: project.direction, total: project.total, confirmed: project.confirmed, saved: project.saved, revision: project.revision }] });
    return;
  }
  if (url.pathname === '/api/cat/resume') { sendJson(res, cloneProject()); return; }
  if (url.pathname === '/api/cat/candidates') { sendJson(res, { terms: [], segment_matches: [] }); return; }
  if (url.pathname.startsWith('/api/cat/')) { sendJson(res, cloneProject()); return; }
  sendJson(res, {});
});

(async function main() {
  const observed = { ok: false, errors: [], console: [] };
  let browser = null;
  try {
    const { chromium } = require(require.resolve('playwright', { paths: [probeDir] }));
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    const baseUrl = 'http://127.0.0.1:' + server.address().port;
    const initialHtml = await new Promise(function (resolve, reject) {
      http.get(baseUrl + '/cat', function (res) { let body = ''; res.setEncoding('utf8'); res.on('data', function (chunk) { body += chunk; }); res.on('end', function () { resolve(body); }); }).on('error', reject);
    });
    const viewMatches = initialHtml.match(/data-cat-view="[^"]*"/g) || [];
    observed.initialHtml = { oneView: viewMatches.length === 1, startView: viewMatches[0] === 'data-cat-view="start"', noPlaceholder: initialHtml.indexOf('__YAKU_VIEW__') < 0 };
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    page.on('pageerror', function (error) { observed.errors.push(String(error && error.message || error)); });
    page.on('console', function (message) { if (message.type() === 'error') observed.console.push(message.text()); });
    await page.goto(baseUrl + '/cat', { waitUntil: 'networkidle' });
    await page.waitForFunction(function () { return document.body.getAttribute('data-cat-view') === 'start' && !document.body.classList.contains('premium-booting'); }, null, { timeout: 10000 });
    await page.waitForSelector('#premium-cat-start', { state: 'visible', timeout: 20000 });
    observed.start = await page.evaluate(function () {
      function isVisible(node) {
        if (!node) return false;
        const style = getComputedStyle(node), box = node.getBoundingClientRect();
        return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
      }
      const root = document.getElementById('premium-cat-start');
      const grid = root && root.querySelector('.premium-combined-grid');
      const chat = root && root.querySelector('.premium-combined-chat');
      const excel = root && root.querySelector('.premium-combined-excel');
      const fileButton = document.getElementById('premium-file-select');
      const input = document.getElementById('palette-input');
      const heading = root && root.querySelector('h1');
      const gridStyle = grid && getComputedStyle(grid);
      const chatBox = chat && chat.getBoundingClientRect();
      const excelBox = excel && excel.getBoundingClientRect();
      return {
        visible: isVisible(root),
        heading: heading ? heading.textContent.trim() : '',
        gridDisplay: gridStyle ? gridStyle.display : '',
        panelCount: root ? root.querySelectorAll('.premium-combined-panel').length : 0,
        panelsVisible: isVisible(chat) && isVisible(excel),
        panelsSameBand: !!chatBox && !!excelBox && Math.abs(chatBox.top - excelBox.top) <= 1,
        chatWidth: chatBox ? chatBox.width : 0,
        excelWidth: excelBox ? excelBox.width : 0,
        fileButtonVisible: isVisible(fileButton),
        fileButtonHeight: fileButton ? fileButton.getBoundingClientRect().height : 0,
        fileInputPresent: !!document.getElementById('premium-file-input'),
        chatInputVisible: isVisible(input),
        noOverflow: document.documentElement.scrollWidth <= window.innerWidth + 1
      };
    });
    await page.screenshot({ path: startScreenshot, fullPage: false });
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.waitForTimeout(150);
    observed.narrowStart = await page.evaluate(function () {
      function isVisible(node) {
        if (!node) return false;
        const style = getComputedStyle(node), box = node.getBoundingClientRect();
        return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
      }
      const root = document.getElementById('premium-cat-start');
      const grid = root && root.querySelector('.premium-combined-grid');
      const panels = root ? Array.from(root.querySelectorAll('.premium-combined-panel')) : [];
      return { visible: isVisible(root), gridDisplay: grid ? getComputedStyle(grid).display : '', panelCount: panels.length, panelsVisible: panels.every(isVisible), noOverflow: document.documentElement.scrollWidth <= window.innerWidth + 1 };
    });
    await page.setViewportSize({ width: 1912, height: 987 });
    await page.goto(baseUrl + '/cat?project=' + encodeURIComponent(project.id), { waitUntil: 'networkidle' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });
    await page.waitForSelector('#premium-stage-nav', { state: 'visible', timeout: 10000 });
    observed.workspace = await page.evaluate(function () {
      function isVisible(node) {
        if (!node) return false;
        const style = getComputedStyle(node), box = node.getBoundingClientRect();
        return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
      }
      const stages = Array.from(document.querySelectorAll('#premium-stage-nav [data-premium-stage]'));
      const output = document.getElementById('premium-output-summary');
      const dock = document.getElementById('cat-preview-dock');
      return {
        view: document.body.getAttribute('data-cat-view') || '',
        stageCount: stages.length,
        stageKeys: stages.map(function (node) { return node.getAttribute('data-premium-stage') || ''; }),
        outputSummaryVisible: isVisible(output),
        previewClosedByDefault: !!dock && dock.hidden,
        noOverflow: document.documentElement.scrollWidth <= window.innerWidth + 1
      };
    });
    await page.screenshot({ path: workspaceScreenshot, fullPage: false });
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
[IO.File]::WriteAllText($driver, $nodeScript, [Text.UTF8Encoding]::new($false))

try {
    & ([string]$node.Source) $driver ($www.Replace('\', '/')) $projectPath $observedPath $startScreenshot $workspaceScreenshot $probeDir 2>&1 | ForEach-Object { Write-Host ('  node: ' + $_) -ForegroundColor DarkGray }
    $nodeExit = $LASTEXITCODE
    Assert-Route -Condition ($nodeExit -eq 0 -and (Test-Path -LiteralPath $observedPath -PathType Leaf)) -Message 'Chromium reached the current Premium CAT root route and workspace'
    if (-not (Test-Path -LiteralPath $observedPath -PathType Leaf)) { exit 1 }
    $observed = Get-Content -LiteralPath $observedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($errorText in @($observed.errors)) { Write-Host ('  Chromium error: ' + [string]$errorText) -ForegroundColor Red }
    foreach ($consoleText in @($observed.console)) { Write-Host ('  Chromium console: ' + [string]$consoleText) -ForegroundColor Red }
    Assert-Route -Condition (@($observed.errors).Count -eq 0 -and @($observed.console).Count -eq 0) -Message 'the root and workspace routes have no page or console errors'
    Assert-Route -Condition ([bool]$observed.initialHtml.oneView -and [bool]$observed.initialHtml.startView -and [bool]$observed.initialHtml.noPlaceholder) -Message 'the initial HTML carries one explicit start view without a placeholder'
    Assert-Route -Condition ([bool]$observed.start.visible -and [string]$observed.start.heading -eq '文章もExcelも、ひとつの画面で。' -and [string]$observed.start.gridDisplay -eq 'grid' -and [int]$observed.start.panelCount -eq 2 -and [bool]$observed.start.panelsVisible -and [bool]$observed.start.panelsSameBand -and [double]$observed.start.chatWidth -gt 0 -and [double]$observed.start.excelWidth -gt 0) -Message 'the visible root surface has both the chat and Excel entry panels at 1912x987'
    Assert-Route -Condition ([bool]$observed.start.fileButtonVisible -and [double]$observed.start.fileButtonHeight -ge 44 -and [bool]$observed.start.fileInputPresent -and [bool]$observed.start.chatInputVisible -and [bool]$observed.start.noOverflow) -Message 'the root route exposes usable file and text entry controls without horizontal overflow at 1912x987'
    Assert-Route -Condition ([bool]$observed.narrowStart.visible -and [string]$observed.narrowStart.gridDisplay -eq 'grid' -and [int]$observed.narrowStart.panelCount -eq 2 -and [bool]$observed.narrowStart.panelsVisible -and [bool]$observed.narrowStart.noOverflow) -Message 'the root route remains usable without horizontal overflow at 1200x800'
    Assert-Route -Condition ([string]$observed.workspace.view -eq 'workspace' -and [int]$observed.workspace.stageCount -eq 3 -and ((@($observed.workspace.stageKeys) -join '|') -eq 'translate|review|export') -and [bool]$observed.workspace.outputSummaryVisible -and [bool]$observed.workspace.previewClosedByDefault -and [bool]$observed.workspace.noOverflow) -Message 'the workspace opens with the three Excel stages, output summary, and closed preview'
    Assert-Route -Condition ((Test-Path -LiteralPath $startScreenshot -PathType Leaf) -and (Test-Path -LiteralPath $workspaceScreenshot -PathType Leaf)) -Message 'start and workspace screenshots were captured'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Host ('FAIL ' + $failures.Count + ' of ' + $checks + ' checks') -ForegroundColor Red
    exit 1
}
Write-Host ('PASS Test-YakuV9194PremiumStartRoute (' + $checks + ' checks)') -ForegroundColor Green
exit 0
