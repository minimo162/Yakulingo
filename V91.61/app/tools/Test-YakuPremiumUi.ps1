[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Read-YakuPremiumText {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "PREMIUM_UI_FILE_MISSING: $RelativePath" }
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}
function Assert-YakuPremiumContains {
    param([string]$Text,[string]$Pattern,[string]$Code)
    if ($Text -notmatch $Pattern) { throw $Code }
}
function Assert-YakuPremiumCount {
    param([string]$Text,[string]$Literal,[int]$Expected,[string]$Code)
    $count = ([regex]::Matches($Text, [regex]::Escape($Literal))).Count
    if ($count -ne $Expected) { throw ($Code + ': expected=' + $Expected + ' actual=' + $count) }
}

$cat = Read-YakuPremiumText 'www\cat.html'
$palette = Read-YakuPremiumText 'www\palette.html'
$catJs = Read-YakuPremiumText 'www\assets\cat.js'
$js = Read-YakuPremiumText 'www\assets\premium-ui.js'
$css = Read-YakuPremiumText 'www\assets\premium-ui.css'

foreach ($html in @($cat, $palette)) {
    Assert-YakuPremiumCount $html '/assets/premium-ui.css' 1 'PREMIUM_UI_CSS_REFERENCE_INVALID'
    Assert-YakuPremiumCount $html '/assets/premium-ui.js' 1 'PREMIUM_UI_JS_REFERENCE_INVALID'
}
Assert-YakuPremiumContains $cat '<title>Excel翻訳 - YakuLingo</title>' 'PREMIUM_UI_CAT_TITLE_MISSING'
Assert-YakuPremiumContains $palette '<title>チャット翻訳 - YakuLingo</title>' 'PREMIUM_UI_CHAT_TITLE_MISSING'
Assert-YakuPremiumContains $cat 'premium-booting' 'PREMIUM_UI_CAT_BOOTING_CLASS_MISSING'
Assert-YakuPremiumContains $palette 'premium-booting' 'PREMIUM_UI_PALETTE_BOOTING_CLASS_MISSING'

foreach ($id in @('cat-picker','cat-workspace','cat-grid-body','cat-preview-dock','cat-export','cat-translate','cat-qa-open')) {
    Assert-YakuPremiumContains $cat ('id=["'']' + [regex]::Escape($id) + '["'']') ('PREMIUM_UI_CAT_CONTRACT_MISSING: ' + $id)
}
foreach ($id in @('palette-form','palette-input','palette-direction-select','palette-handoff','palette-context-select','palette-result')) {
    Assert-YakuPremiumContains $palette ('id=["'']' + [regex]::Escape($id) + '["'']') ('PREMIUM_UI_PALETTE_CONTRACT_MISSING: ' + $id)
}

foreach ($label in @('Excel翻訳','チャット翻訳','過去訳','作業一覧','セル幅に合わせる','文章を貼ってすぐ訳す','確認済みを再利用','保存済みの作業')) {
    Assert-YakuPremiumContains $js ([regex]::Escape($label)) ('PREMIUM_UI_NAV_LABEL_MISSING: ' + $label)
}
if ($js -match 'クイック翻訳') { throw 'PREMIUM_UI_OLD_CHAT_LABEL_REINTRODUCED' }
Assert-YakuPremiumContains $js 'premium-chat-cta' 'PREMIUM_UI_CHAT_CTA_MISSING'
Assert-YakuPremiumContains $js 'href="/palette"' 'PREMIUM_UI_CHAT_CTA_HREF_MISSING'
Assert-YakuPremiumContains $js '文章をすぐ訳す|ファイルなしで、文章を貼って翻訳' 'PREMIUM_UI_CHAT_CTA_COPY_MISSING'
Assert-YakuPremiumContains $js 'finally[\s\S]*premium-booting' 'PREMIUM_UI_BOOTING_FINALLY_MISSING'
if ($js -match '枠に収める|サクッと翻訳') { throw 'PREMIUM_UI_REJECTED_NAV_LABEL_REINTRODUCED' }
if ($js -match 'カジュアル') { throw 'PREMIUM_UI_UNSUPPORTED_TONE_EXPOSED' }
Assert-YakuPremiumContains $js 'data-length=.brief' 'PREMIUM_UI_BRIEF_MODE_MISSING'
Assert-YakuPremiumContains $js 'data-tone=.polite' 'PREMIUM_UI_POLITE_MODE_MISSING'
Assert-YakuPremiumContains $js "form\.addEventListener\('submit'" 'PREMIUM_UI_QUICK_SUBMIT_DELEGATION_MISSING'
Assert-YakuPremiumContains $js 'palette-result' 'PREMIUM_UI_QUICK_RESULT_WIRING_MISSING'
Assert-YakuPremiumContains $js '/api/cat/open' 'PREMIUM_UI_EXCEL_OPEN_WIRING_MISSING'
Assert-YakuPremiumContains $js '/api/cat/recent' 'PREMIUM_UI_RECENT_WIRING_MISSING'
Assert-YakuPremiumContains $js 'initialImport|premium-mode-import|cat-source-align' 'PREMIUM_UI_PAST_IMPORT_WIRING_MISSING'
Assert-YakuPremiumContains $js 'Excel翻訳と過去訳の対応確認|Excel翻訳や過去訳の対応確認を始めると' 'PREMIUM_UI_MIXED_WORK_COPY_MISSING'
Assert-YakuPremiumContains $js "setTopbar\('作業一覧', '保存済みの作業'" 'PREMIUM_UI_MIXED_WORK_TOPBAR_MISSING'
Assert-YakuPremiumContains $cat 'cat-source-align|日本語版のPDF|英語版のPDF' 'PREMIUM_UI_PAST_IMPORT_SURFACE_MISSING'
Assert-YakuPremiumContains $catJs 'function syncLocation\(projectId, preserveImport, preserveWork\)' 'PREMIUM_UI_IMPORT_LOCATION_SYNC_MISSING'
Assert-YakuPremiumContains $catJs "preserveImport \? '/cat\?import=1' : preserveWork \? '/cat\?view=work' : '/cat'" 'PREMIUM_UI_IMPORT_LOCATION_FALLBACK_MISSING'
Assert-YakuPremiumContains $catJs 'showPicker\(importMode\)' 'PREMIUM_UI_IMPORT_START_ORDER_MISSING'
Assert-YakuPremiumContains $catJs 'retryPending = eligible === 0 && pending > 0|翻訳メモリへの反映を再試行' 'PREMIUM_UI_TM_PENDING_RETRY_WIRING_MISSING'
Assert-YakuPremiumContains $catJs "data-cat-source.*project\.source" 'PREMIUM_UI_PROJECT_SOURCE_MARKER_MISSING'
Assert-YakuPremiumContains $js 'premium-mode-align-workspace|removeExcelWorkspaceUi' 'PREMIUM_UI_ALIGN_WORKSPACE_BRANCH_MISSING'
Assert-YakuPremiumContains $js "classList\.contains\('premium-mode-align-workspace'\)" 'PREMIUM_UI_ALIGN_TOOLS_ACTIVE_WIRING_MISSING'
Assert-YakuPremiumContains $js "setTopbar\('過去訳', '過去訳の対応確認', \{ 'premium-tools': true \}\)" 'PREMIUM_UI_ALIGN_TOOLS_BUTTON_MISSING'
Assert-YakuPremiumContains $js 'data-cat-fit-candidates|cat-fit-risk-badge' 'PREMIUM_UI_FIT_FOCUS_MISSING'
Assert-YakuPremiumContains $js "(?s)\[el\('cat-grid-body'\), el\('cat-editor-toolbar'\)\]\.forEach" 'PREMIUM_UI_TARGETED_OBSERVERS_MISSING'
if ($js -match "MutationObserver\(refresh\)\.observe\(workspace") { throw 'PREMIUM_UI_BROAD_WORKSPACE_OBSERVER_REINTRODUCED' }
Assert-YakuPremiumContains $js '#cat-editor-toolbar,#premium-tools' 'PREMIUM_UI_TOOLS_DISMISS_GUARD_MISSING'
Assert-YakuPremiumContains $js 'syncToolsExpanded' 'PREMIUM_UI_TOOLS_ARIA_SYNC_MISSING'
Assert-YakuPremiumContains $js 'focusFirstTool' 'PREMIUM_UI_TOOLS_FOCUS_MISSING'
Assert-YakuPremiumContains $js 'proxy\.hidden = !!original\.hidden' 'PREMIUM_UI_HIDDEN_PROXY_SYNC_MISSING'
Assert-YakuPremiumContains $js 'Number\(file\.size \|\| 0\) <= 0' 'PREMIUM_UI_EMPTY_FILE_GUARD_MISSING'
Assert-YakuPremiumContains $js 'premium-file-drop.*role="group"' 'PREMIUM_UI_FILE_DROP_ROLE_MISSING'
Assert-YakuPremiumContains $js "input\.dispatchEvent\(new Event\('focusin'" 'PREMIUM_UI_FIT_ROW_ACTIVATION_MISSING'
Assert-YakuPremiumContains $js 'aria-pressed' 'PREMIUM_UI_TOGGLE_ARIA_STATE_MISSING'
Assert-YakuPremiumContains $js "toast\.setAttribute\('role', 'status'\)" 'PREMIUM_UI_TOAST_STATUS_MISSING'
Assert-YakuPremiumContains $js 'function waitForPremiumRow' 'PREMIUM_UI_FIT_ROW_CONDITION_WAIT_MISSING'
Assert-YakuPremiumContains $js 'MutationObserver\(inspect\)' 'PREMIUM_UI_FIT_ROW_OBSERVER_MISSING'
Assert-YakuPremiumContains $js '30000' 'PREMIUM_UI_FIT_ROW_TEARDOWN_GUARD_MISSING'
Assert-YakuPremiumContains $js 'function openTools|function closeTools' 'PREMIUM_UI_TOOLS_CLOSE_PATH_MISSING'
Assert-YakuPremiumContains $js 'toolsInvoker' 'PREMIUM_UI_TOOLS_INVOKER_MISSING'
Assert-YakuPremiumContains $js 'toolbar\.contains\(active\)' 'PREMIUM_UI_TOOLS_FOCUS_GUARD_MISSING'
Assert-YakuPremiumContains $js 'pagehide.*cancelPremiumRowWait' 'PREMIUM_UI_FIT_ROW_CLEANUP_MISSING'
Assert-YakuPremiumContains $js 'function premiumViewIdentity' 'PREMIUM_UI_FIT_ROW_IDENTITY_MISSING'
Assert-YakuPremiumContains $js 'premiumViewIdentity\(\) !== identity' 'PREMIUM_UI_FIT_ROW_IDENTITY_GUARD_MISSING'
Assert-YakuPremiumContains $js '(?s)cat-toolbar-title.*cat-toolbar-direction' 'PREMIUM_UI_FIT_ROW_STABLE_MARKER_MISSING'
Assert-YakuPremiumContains $js 'removeAttribute\(''aria-controls''\)' 'PREMIUM_UI_DISCLOSURE_CLEANUP_MISSING'

Assert-YakuPremiumContains $css 'body\.premium-cat #cat-workspace' 'PREMIUM_UI_CAT_WORKSPACE_STYLE_MISSING'
Assert-YakuPremiumContains $css 'body\.premium-palette \.premium-quick-layout' 'PREMIUM_UI_QUICK_WORKSPACE_STYLE_MISSING'
Assert-YakuPremiumContains $css '--premium-brand:\s*#1f3a5f' 'PREMIUM_UI_COLOR_TOKEN_MISSING'
Assert-YakuPremiumContains $css '--premium-canvas:\s*#fafafa' 'PREMIUM_UI_CANVAS_TOKEN_MISSING'
Assert-YakuPremiumContains $css '--premium-ink:\s*#18181b' 'PREMIUM_UI_INK_TOKEN_MISSING'
Assert-YakuPremiumContains $css '--premium-muted:\s*#55565f' 'PREMIUM_UI_MUTED_TOKEN_MISSING'
Assert-YakuPremiumContains $css 'BIZ UDPGothic' 'PREMIUM_UI_JP_FONT_STACK_MISSING'
Assert-YakuPremiumContains $css 'font-size:\s*16px' 'PREMIUM_UI_BODY_FONT_FLOOR_MISSING'
Assert-YakuPremiumContains $css 'premium-booting' 'PREMIUM_UI_BOOTING_STYLE_MISSING'
Assert-YakuPremiumContains $css 'premium-chat-cta' 'PREMIUM_UI_CHAT_CTA_STYLE_MISSING'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { throw 'PREMIUM_UI_NODE_NOT_FOUND' }
& $node.Source --check (Join-Path $Root 'www\assets\premium-ui.js')
if ($LASTEXITCODE -ne 0) { throw 'PREMIUM_UI_JAVASCRIPT_SYNTAX_FAILED' }

$harness = @'
const assert = require('assert');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const premiumPath = process.argv[2];
const wwwPath = process.argv[3];
if (!premiumPath || !wwwPath) throw new Error('PREMIUM_UI_BROWSER_SCRIPT_PATH_MISSING');

const alignProject = {
  id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', revision: 1, source: 'align', lifecycle: 'saved', file_name: 'alignment.pdf', document_format: 'text', direction: 'to_en',
  total: 1, translated: 1, remaining: 0, joined: 0, confirmed: 1, unconfirmed: 0, source_chars: 12, remaining_chars: 0, untranslated: 0, draft: 0,
  export_blocked: false, translation_list_eligibility: true, excel_draft_eligibility: false, word_draft_eligibility: false, tm_pending: 0, tm_bulk_eligible_count: 1,
  segments: [{ index: 0, segment_id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', source: '日本語の原文', translation: 'English source', origin: 'manual', state: 'reviewed', qc_status: 'passed', confirmed: true, kind: 'text', location: 'page 1', qc_findings: [], qc_preview: [], tm_registered: false, repetition_count: 1, repetition_first: true, can_merge: false, can_split: false, can_split_at: false, split_group: '', split_part: 0, split_parts: 0, cells: 0, joined: false, publication_translation: 'English source', has_publication_variant: false }]
};
const pendingAlignProject = Object.assign({}, alignProject, {
  id: 'dddddddddddddddddddddddddddddddd', revision: 4, tm_pending: 1, tm_bulk_eligible_count: 0
});
const excelRecent = {
  id: 'cccccccccccccccccccccccccccccccc', source: 'file', file_name: 'budget.xlsx', direction: 'to_en', revision: 3,
  total: 4, confirmed: 2, saved: '2026-08-21T10:00:00'
};
const recentFixture = { projects: [
  { id: alignProject.id, source: 'align', file_name: alignProject.file_name, direction: 'to_en', revision: 1, total: 3, confirmed: 1, saved: '2026-08-21T09:00:00' },
  excelRecent
] };
const assetTypes = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8', '.wasm': 'application/wasm', '.json': 'application/json; charset=utf-8' };
function sendJson(response, value) {
  response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
}

(async () => {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const isAlignProject = url.pathname === '/cat' && url.searchParams.get('project') === alignProject.id;
    const isPendingAlignProject = url.pathname === '/cat' && url.searchParams.get('project') === pendingAlignProject.id;
    const isCatStartPage = url.pathname === '/cat' && !url.searchParams.has('project') && !url.searchParams.has('import') && !url.searchParams.has('view');
    const isImportPage = url.pathname === '/cat' && url.searchParams.get('import') === '1';
    const isWorkListPage = url.pathname === '/cat' && url.searchParams.get('view') === 'work';
    if (isCatStartPage || isAlignProject || isPendingAlignProject || isImportPage || isWorkListPage) {
      let html = fs.readFileSync(path.join(wwwPath, 'cat.html'), 'utf8');
      html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'premium-align-test')
        .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
        .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
        .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
        .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
        .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS P\\u30b4\\u30b7\\u30c3\\u30af')
        .replace(/__YAKU_TOUR__/g, '0')
        .replace(/__YAKU_IMPORT__/g, isImportPage ? '1' : '0')
        .replace(/__YAKU_VIEW__/g, isCatStartPage ? 'start' : isAlignProject || isPendingAlignProject ? 'workspace' : isWorkListPage ? 'work' : '');
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', ...(isImportPage ? { 'Content-Security-Policy': "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" } : {}) });
      response.end(html);
      return;
    }
    if (url.pathname.startsWith('/assets/')) {
      const asset = path.join(wwwPath, url.pathname.replace(/^\//, ''));
      if (fs.existsSync(asset)) {
        response.writeHead(200, { 'Content-Type': assetTypes[path.extname(asset)] || 'application/octet-stream' });
        response.end(fs.readFileSync(asset));
        return;
      }
      response.writeHead(404); response.end(); return;
    }
    if (url.pathname.startsWith('/api/')) {
      let raw = '';
      request.on('data', chunk => { raw += chunk; });
      request.on('end', () => {
        let body = {};
        try { body = JSON.parse(raw || '{}'); } catch (_) {}
        if (url.pathname === '/api/cat/resume') return sendJson(response, body.project_id === pendingAlignProject.id ? pendingAlignProject : alignProject);
        if (url.pathname === '/api/cat/recent') return sendJson(response, recentFixture);
        if (url.pathname === '/api/cat/tm-register-bulk') return sendJson(response, Object.assign({}, pendingAlignProject, {
          tm_pending: 0, tm_bulk_eligible_count: 0, tm_registered_count: 0, tm_skipped_count: 0, tm_registered: [], tm_skipped: []
        }));
        if (url.pathname === '/api/cat/project-presence') return sendJson(response, { ok: true });
        if (url.pathname === '/api/ready-state') return sendJson(response, { canTranslate: true, label: 'ready', class: 'ok' });
        return sendJson(response, {});
      });
      return;
    }
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end('<!doctype html><html><body></body></html>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const baseUrl = 'http://127.0.0.1:' + address.port;
  let browser = null;
  let primaryError = null;
  try {
    try {
      browser = await chromium.launch({ headless: true });
      const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
      const pageErrors = [];
      page.on('pageerror', error => pageErrors.push(error.message));
      const startPage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
      const startErrors = [];
      startPage.on('pageerror', error => startErrors.push(error.message));
      await startPage.goto(baseUrl + '/cat', { waitUntil: 'domcontentloaded' });
      await startPage.waitForFunction(() => {
        const start = document.getElementById('premium-cat-start');
        return start && !document.body.classList.contains('premium-booting') &&
          getComputedStyle(start).display !== 'none' && start.getBoundingClientRect().width > 0;
      }, null, { timeout: 20000 });
      const measureStart = () => startPage.evaluate(() => {
        const visible = node => {
          if (!node) return false;
          const style = getComputedStyle(node), box = node.getBoundingClientRect();
          return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
        };
        const box = id => {
          const node = document.getElementById(id), rect = node && node.getBoundingClientRect();
          return { visible: visible(node), width: rect ? rect.width : 0, height: rect ? rect.height : 0,
            focusable: !!node && node.tabIndex >= 0 && !node.disabled };
        };
        const start = document.getElementById('premium-cat-start');
        const rect = start && start.getBoundingClientRect();
        const textNodes = start ? Array.from(start.querySelectorAll('h1,h2,p,a,button,strong,span,small')).filter(node => visible(node) && node.textContent.trim()) : [];
        const fontSizes = textNodes.map(node => parseFloat(getComputedStyle(node).fontSize)).filter(Number.isFinite);
        const cta = document.getElementById('premium-chat-cta');
        const ctaRect = cta && cta.getBoundingClientRect();
        const logo = document.querySelector('.premium-logo');
        const flowArrows = Array.from(document.querySelectorAll('.premium-flow-arrow')).filter(visible);
        const logoFont = logo && visible(logo) ? parseFloat(getComputedStyle(logo).fontSize) : 0;
        const flowArrowFonts = flowArrows.map(node => parseFloat(getComputedStyle(node).fontSize)).filter(Number.isFinite);
        const direction = Array.from(document.querySelectorAll('#premium-direction-switch button')).map(node => {
          const item = node.getBoundingClientRect();
          return { text: node.textContent.trim(), pressed: node.getAttribute('aria-pressed'), active: node.classList.contains('is-active'), visible: visible(node), width: item.width, height: item.height };
        });
        const overflow = document.documentElement.scrollWidth > window.innerWidth + 1 || document.body.scrollWidth > window.innerWidth + 1;
        return {
          viewport: { width: innerWidth, height: innerHeight }, booting: document.body.classList.contains('premium-booting'),
          startVisible: visible(start), startWidth: rect ? rect.width : 0, startHeight: rect ? rect.height : 0,
          grid: box('premium-direction-switch'), fileDrop: box('premium-file-drop'), excel: box('premium-file-select'),
          reference: box('premium-reference-open'), cta: { visible: visible(cta), href: cta && cta.getAttribute('href'), width: ctaRect ? ctaRect.width : 0, height: ctaRect ? ctaRect.height : 0, focusable: !!cta && cta.tabIndex >= 0 },
          logoFont, flowArrowFont: flowArrowFonts.length ? Math.min.apply(Math, flowArrowFonts) : 0,
          direction: direction, activeDirection: direction.filter(item => item.pressed === 'true' && item.active).length,
          minFont: fontSizes.length ? Math.min.apply(Math, fontSizes) : 0, bodyFont: parseFloat(getComputedStyle(document.body).fontSize),
          overflow: overflow, scrollWidth: document.documentElement.scrollWidth
        };
      });
      const startWide = await measureStart();
      assert.strictEqual(startWide.booting, false, JSON.stringify(startWide));
      assert.ok(startWide.startVisible && startWide.cta.visible && startWide.cta.href === '/palette' && startWide.cta.focusable && startWide.cta.width >= 180 && startWide.cta.height >= 44, JSON.stringify(startWide));
      assert.ok(startWide.excel.visible && startWide.excel.focusable && startWide.excel.width >= 120 && startWide.excel.height >= 44, JSON.stringify(startWide));
      assert.ok(startWide.reference.visible && startWide.reference.focusable && startWide.reference.width >= 120 && startWide.reference.height >= 44, JSON.stringify(startWide));
      assert.strictEqual(startWide.direction.length, 2, JSON.stringify(startWide));
      assert.strictEqual(startWide.activeDirection, 1, JSON.stringify(startWide));
      assert.ok(startWide.direction.every(item => item.visible && item.width >= 120 && item.height >= 44) && startWide.direction[0].text !== startWide.direction[1].text, JSON.stringify(startWide));
      assert.ok(startWide.minFont >= 12 && startWide.bodyFont >= 16 && !startWide.overflow, JSON.stringify(startWide));
      assert.ok(startWide.logoFont >= 17 && startWide.flowArrowFont >= 26, JSON.stringify(startWide));
      await startPage.locator('#premium-chat-cta').focus();
      assert.strictEqual(await startPage.evaluate(() => document.activeElement && document.activeElement.id), 'premium-chat-cta');
      const [chooser] = await Promise.all([startPage.waitForEvent('filechooser'), startPage.locator('#premium-file-select').click()]);
      assert.ok(chooser, 'Excel chooser did not open');
      await startPage.locator('#premium-direction-switch button[data-direction="to_jp"]').click();
      let directionState = await startPage.evaluate(() => Array.from(document.querySelectorAll('#premium-direction-switch button')).map(node => [node.getAttribute('data-direction'), node.getAttribute('aria-pressed'), node.classList.contains('is-active')]));
      assert.deepStrictEqual(directionState, [['to_en', 'false', false], ['to_jp', 'true', true]], JSON.stringify(directionState));
      await startPage.locator('#premium-direction-switch button[data-direction="to_en"]').click();
      directionState = await startPage.evaluate(() => Array.from(document.querySelectorAll('#premium-direction-switch button')).map(node => [node.getAttribute('data-direction'), node.getAttribute('aria-pressed'), node.classList.contains('is-active')]));
      assert.deepStrictEqual(directionState, [['to_en', 'true', true], ['to_jp', 'false', false]], JSON.stringify(directionState));
      await startPage.locator('#premium-reference-open').click();
      await startPage.waitForFunction(() => new URL(location.href).searchParams.get('import') === '1' && document.getElementById('cat-source-align') && !document.getElementById('cat-source-align').hidden, null, { timeout: 20000 });
      const importStartState = await startPage.evaluate(() => ({ query: new URL(location.href).searchParams.get('import'), panel: !document.getElementById('cat-source-align').hidden, japanese: document.body.textContent.includes('\u65e5\u672c\u8a9e\u7248\u306ePDF'), english: document.body.textContent.includes('\u82f1\u8a9e\u7248\u306ePDF') }));
      assert.deepStrictEqual(importStartState, { query: '1', panel: true, japanese: true, english: true }, JSON.stringify(importStartState));
      await startPage.goto(baseUrl + '/cat', { waitUntil: 'domcontentloaded' });
      await startPage.waitForSelector('#premium-cat-start');
      await startPage.setViewportSize({ width: 1200, height: 800 });
      await startPage.waitForFunction(() => document.getElementById('premium-cat-start').getBoundingClientRect().width > 0 && !document.body.classList.contains('premium-booting'));
      const startNarrow = await measureStart();
      assert.ok(startNarrow.startVisible && startNarrow.cta.visible && startNarrow.cta.width >= 180 && startNarrow.cta.height >= 44 && startNarrow.excel.height >= 44 && startNarrow.reference.height >= 44 && startNarrow.direction.every(item => item.visible && item.height >= 44) && startNarrow.minFont >= 12 && !startNarrow.overflow, JSON.stringify(startNarrow));
      console.log('Premium start 1912x987:', JSON.stringify(startWide));
      console.log('Premium start 1200x800:', JSON.stringify(startNarrow));
      if (startErrors.length) throw new Error('PREMIUM_UI_START_PAGEERROR: ' + startErrors.join(' | '));
      await startPage.close();
      await page.goto(baseUrl + '/cat?project=project-old');
    await page.setContent(`<!doctype html><html><head><title>test</title><link rel="stylesheet" href="/assets/premium-ui.css"></head><body class="app-cat" data-cat-view="workspace">
      <main class="shell">
        <section id="cat-picker"></section>
        <section id="cat-workspace">
          <div id="cat-editor-layout">
            <div id="cat-editor-pane"><div id="cat-grid-wrap"><div id="cat-grid-body">
              <div data-cat-row="1" data-render-generation="initial" class="is-active"><span class="cat-source-text">one</span><textarea data-cat-input="1" data-cat-project-id="project-old">ONE</textarea></div>
              <div data-cat-row="2" data-render-generation="initial"><span class="cat-source-text">two</span><span class="cat-fit-risk-badge">risk</span><textarea data-cat-input="2" data-cat-project-id="project-old">TWO</textarea></div>
            </div></div>
          </div>
          <div id="cat-editor-toolbar"><strong id="cat-toolbar-title">Project Old</strong><span id="cat-toolbar-direction">to-en</span><button id="tool-first" type="button">Tool</button></div>
        </section>
        <section id="cat-preview-dock" class="cat-preview-dock">
          <div class="cat-bottom-dock-bar"><div class="cat-inspector-tabs" role="tablist"><button id="cat-tab-preview" type="button" role="tab" aria-selected="true" data-cat-inspector="preview">プレビュー</button></div></div>
          <aside id="cat-inspector-pane" class="cat-inspector-pane"><section id="cat-panel-preview" role="tabpanel"><strong class="cat-preview-dock-title">体裁プレビュー</strong><p class="cat-preview-dock-note">表示中の行を確認します。</p></section></aside>
        </section>
        <div id="cat-output-row"><span>訳文を入れたコピーを作りました</span><button id="cat-open-folder" type="button">フォルダを開く</button></div>
        <div id="premium-toast" class="premium-toast is-showing" role="status">確認メッセージ</div>
        <button id="cat-translate" type="button" hidden>Translate</button>
        <button id="cat-qa-open" type="button" hidden>QA</button>
        <button id="cat-export" type="button" hidden>Export</button>
        <button data-cat-filter="all" type="button">All</button>
        <button data-cat-filter="fit" type="button">Fit</button>
        <button id="outside-focus" type="button">Outside</button>
      </main>
    </body></html>`);
    await page.evaluate(() => history.replaceState(null, '', '/cat?project=project-old'));
    await page.evaluate(() => {
      window.__activationRerendered = {};
      window.__activationRerenderCount = 0;
      window.__focusEvents = 0;
      window.__gridWasEmpty = false;
      document.addEventListener('focusin', event => {
      const input = event.target.closest('textarea[data-cat-input]');
      if (!input) return;
      const row = input.closest('[data-cat-row]');
      if (!row) return;
      window.__focusEvents += 1;
      const key = row.getAttribute('data-cat-row');
      if (window.__activationRerendered[key]) return;
      window.__activationRerendered[key] = true;
      window.setTimeout(() => {
        if (!row.isConnected) return;
        document.querySelectorAll('#cat-grid-body [data-cat-row]').forEach(item => item.classList.remove('is-active'));
        const replacement = row.cloneNode(true);
        replacement.setAttribute('data-render-generation', 'final');
        replacement.classList.add('is-active');
        row.replaceWith(replacement);
        window.__finalRow = replacement;
        window.__activationRerenderCount += 1;
      }, 25);
      });
    });
    await page.addScriptTag({ path: premiumPath });
    await page.waitForSelector('#premium-tools');
    await page.waitForSelector('#premium-fit-list .premium-fit-row');
    await page.evaluate(() => {
      const workspace = document.getElementById('cat-workspace');
      const preview = document.getElementById('cat-preview-dock');
      if (workspace && preview && preview.parentElement !== workspace) workspace.appendChild(preview);
    });

    const workspaceTypography = await page.evaluate(() => {
      const workspace = document.getElementById('cat-workspace');
      const visible = node => {
        if (!node) return false;
        const style = getComputedStyle(node), box = node.getBoundingClientRect();
        return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
      };
      const directText = node => Array.from(node.childNodes).some(child => child.nodeType === Node.TEXT_NODE && child.textContent.trim());
      const font = node => parseFloat(getComputedStyle(node).fontSize);
      const sourceNodes = workspace ? Array.from(workspace.querySelectorAll('.cat-source-text')).filter(visible) : [];
      const targetNodes = workspace ? Array.from(workspace.querySelectorAll('textarea[data-cat-input]')).filter(visible) : [];
      const utilityNodes = workspace ? Array.from(workspace.querySelectorAll('*')).filter(node => visible(node) && directText(node) && node.getAttribute('aria-hidden') !== 'true' && !node.matches('.cat-source-text,textarea[data-cat-input]') && !node.closest('.cat-source-text')) : [];
      const output = document.getElementById('cat-output-row');
      const outputButton = document.getElementById('cat-open-folder');
      const toast = document.getElementById('premium-toast');
      const utilityFonts = utilityNodes.map(font).filter(Number.isFinite);
      const sourceFonts = sourceNodes.map(font).filter(Number.isFinite);
      const targetFonts = targetNodes.map(font).filter(Number.isFinite);
      const utilityLowest = utilityNodes.map(node => ({ tag: node.tagName, id: node.id, className: String(node.className || ''), text: node.textContent.trim().slice(0, 40), font: font(node) })).sort((a, b) => a.font - b.font).slice(0, 8);
      return {
        utilityFontFloor: utilityFonts.length ? Math.min.apply(Math, utilityFonts) : 0,
        sourceFont: sourceFonts.length ? Math.min.apply(Math, sourceFonts) : 0,
        targetFont: targetFonts.length ? Math.min.apply(Math, targetFonts) : 0,
        outputFont: output && visible(output) ? font(output) : 0,
        outputButtonFont: outputButton && visible(outputButton) ? font(outputButton) : 0,
        outputButtonHeight: outputButton && visible(outputButton) ? outputButton.getBoundingClientRect().height : 0,
        toastFont: toast && visible(toast) ? font(toast) : 0,
        utilityNodes: utilityNodes.length,
        utilityLowest,
        sourceNodes: sourceNodes.length,
        targetNodes: targetNodes.length,
        overflow: document.documentElement.scrollWidth > innerWidth + 1 || document.body.scrollWidth > innerWidth + 1,
        scrollWidth: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth)
      };
    });
    assert.ok(workspaceTypography.utilityFontFloor >= 12 && workspaceTypography.sourceFont >= 16 && workspaceTypography.targetFont >= 16 && workspaceTypography.outputFont >= 12 && workspaceTypography.outputButtonFont >= 12 && workspaceTypography.outputButtonHeight >= 44 && workspaceTypography.toastFont >= 12 && !workspaceTypography.overflow, JSON.stringify(workspaceTypography));
    console.log('Premium CAT workspace 1912x987 typography:', JSON.stringify(workspaceTypography));
    const measureWorkspaceFrame = () => page.evaluate(() => {
      const workspace = document.getElementById('cat-workspace');
      const workspaceBox = workspace && workspace.getBoundingClientRect();
      const visible = node => {
        if (!node) return false;
        const style = getComputedStyle(node), box = node.getBoundingClientRect();
        return !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
      };
      const region = id => {
        const node = document.getElementById(id), box = node && node.getBoundingClientRect();
        const inViewport = !!box && box.left >= -1 && box.top >= -1 && box.right <= innerWidth + 1 && box.bottom <= innerHeight + 1;
        const inWorkspace = !!box && !!workspaceBox && box.left >= workspaceBox.left - 1 && box.top >= workspaceBox.top - 1 && box.right <= workspaceBox.right + 1 && box.bottom <= workspaceBox.bottom + 1;
        return { visible: visible(node), left: box ? box.left : 0, top: box ? box.top : 0, right: box ? box.right : 0, bottom: box ? box.bottom : 0, width: box ? box.width : 0, height: box ? box.height : 0, inViewport, inWorkspace };
      };
      const regions = { summary: region('premium-work-summary'), fit: region('premium-fit-panel'), editor: region('cat-editor-layout'), preview: region('cat-preview-dock') };
      const workspaceInViewport = !!workspaceBox && workspaceBox.left >= -1 && workspaceBox.right <= innerWidth + 1 && workspaceBox.top >= -1 && workspaceBox.bottom <= innerHeight + 1;
      return {
        viewport: { width: innerWidth, height: innerHeight },
        workspace: workspaceBox ? { left: workspaceBox.left, right: workspaceBox.right, top: workspaceBox.top, bottom: workspaceBox.bottom, width: workspaceBox.width, height: workspaceBox.height } : null,
        regions,
        previewVisible: regions.preview.visible,
        noClip: workspaceInViewport && Object.keys(regions).every(key => regions[key].visible && regions[key].inViewport && regions[key].inWorkspace),
        overflow: document.documentElement.scrollWidth > innerWidth + 1 || document.body.scrollWidth > innerWidth + 1,
        scrollWidth: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth)
      };
    });
    const workspaceWide = await measureWorkspaceFrame();
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.waitForTimeout(80);
    const workspaceNarrow = await measureWorkspaceFrame();
    assert.ok(!workspaceWide.overflow, JSON.stringify(workspaceWide));
    assert.ok(workspaceNarrow.noClip && workspaceNarrow.previewVisible && !workspaceNarrow.overflow, JSON.stringify(workspaceNarrow));
    console.log('Premium CAT workspace 1912x987 frame:', JSON.stringify(workspaceWide));
    console.log('Premium CAT workspace 1200x800 frame:', JSON.stringify(workspaceNarrow));
    await page.setViewportSize({ width: 1912, height: 987 });

    let state = await page.evaluate(() => ({
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded')
    }));
    assert.deepStrictEqual(state, { toolsControls: 'cat-editor-toolbar', toolsExpanded: 'false' }, JSON.stringify(state));

    await page.locator('#premium-tools').evaluate(node => node.click());
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: true, toolsControls: 'cat-editor-toolbar', toolsExpanded: 'true', active: 'tool-first' }, JSON.stringify(state));

    await page.evaluate(() => document.body.dispatchEvent(new MouseEvent('click', { bubbles: true })));
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: false, toolsControls: 'cat-editor-toolbar', toolsExpanded: 'false', active: 'premium-tools' }, JSON.stringify(state));

    await page.locator('#premium-tools').evaluate(node => node.click());
    await page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: false, active: 'premium-tools' }, JSON.stringify(state));

    await page.locator('#premium-tools').evaluate(node => node.click());
    await page.locator('#outside-focus').focus();
    await page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: false, active: 'outside-focus' }, JSON.stringify(state));

    assert.strictEqual(await page.locator('#premium-translate').isHidden(), true);
    assert.strictEqual(await page.locator('#premium-file-drop').getAttribute('role'), 'group');
    assert.strictEqual(await page.locator('#premium-file-drop').evaluate(node => node.tabIndex), -1);
    assert.strictEqual(await page.locator('#premium-file-drop button').count(), 1);

    await page.locator('#premium-direction-switch [data-direction="to_jp"]').evaluate(node => node.click());
    assert.strictEqual(await page.locator('#premium-direction-switch [data-direction="to_jp"]').getAttribute('aria-pressed'), 'true');
    assert.strictEqual(await page.locator('#premium-direction-switch [data-direction="to_en"]').getAttribute('aria-pressed'), 'false');

    await page.evaluate(() => {
      const input = document.getElementById('premium-file-input');
      const transfer = new DataTransfer();
      transfer.items.add(new File([], 'empty.xlsx', { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
      input.files = transfer.files;
      input.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.waitForFunction(() => {
      const toast = document.getElementById('premium-toast');
      return !!toast && toast.classList.contains('is-warning');
    }, null, { timeout: 1000 });
    assert.strictEqual(await page.locator('#premium-toast').getAttribute('role'), 'status');
    assert.strictEqual(await page.locator('#premium-toast').evaluate(node => node.classList.contains('is-warning')), true);
    assert.strictEqual(await page.locator('body').evaluate(node => node.classList.contains('premium-file-busy')), false);

    await page.evaluate(() => {
      document.querySelector('[data-cat-filter="all"]').addEventListener('click', () => {
        if (!window.__restorePremiumRow) return;
        window.setTimeout(() => {
          document.getElementById('cat-grid-body').insertAdjacentHTML('beforeend', '<div data-cat-row="2" data-render-generation="delayed"><span class="cat-source-text">two</span><span class="cat-fit-risk-badge">risk</span><textarea data-cat-input="2" data-cat-project-id="project-old">TWO</textarea></div>');
          window.__rowRestoredAt = performance.now();
        }, 1200);
      });
      document.addEventListener('click', event => {
        const premiumRow = event.target.closest('[data-premium-row="2"]');
        if (!premiumRow) return;
        window.__rowRemovedAt = performance.now();
        window.__restorePremiumRow = true;
        const grid = document.getElementById('cat-grid-body');
        grid.innerHTML = '';
        window.__gridWasEmpty = grid.querySelector('[data-cat-row]') === null;
      }, true);
    });
    await page.locator('#premium-fit-list .premium-fit-row[data-premium-row="2"]').evaluate(node => node.click());
    await page.waitForFunction(() => {
      const row = document.querySelector('#cat-grid-body [data-cat-row="2"]');
      const active = document.activeElement;
      return !!row && row.getAttribute('data-render-generation') === 'final' && window.__finalRow === row &&
        row.classList.contains('is-active') && !!active && active.getAttribute('data-cat-input') === '2' &&
        active.closest('[data-cat-row="2"]') === row;
    }, null, { timeout: 5000 });
    state = await page.evaluate(() => ({
      activeRow: document.querySelector('#cat-grid-body [data-cat-row="2"]').classList.contains('is-active'),
      finalNode: document.querySelector('#cat-grid-body [data-cat-row="2"]') === window.__finalRow,
      activeElement: document.activeElement && document.activeElement.getAttribute('data-cat-input') === '2',
      activeBelongsToFinal: document.activeElement && document.activeElement.closest('[data-cat-row="2"]') === window.__finalRow,
      delay: window.__rowRestoredAt - window.__rowRemovedAt,
      focusEvents: window.__focusEvents,
      activationRerenders: window.__activationRerenderCount,
      gridWasEmpty: window.__gridWasEmpty
    }));
    assert.strictEqual(state.activeRow, true, JSON.stringify(state));
    assert.strictEqual(state.finalNode, true, JSON.stringify(state));
    assert.strictEqual(state.activeElement, true, JSON.stringify(state));
    assert.strictEqual(state.activeBelongsToFinal, true, JSON.stringify(state));
    assert.strictEqual(state.activationRerenders, 1, JSON.stringify(state));
    assert.strictEqual(state.gridWasEmpty, true, JSON.stringify(state));
    assert.ok(state.delay >= 1000, JSON.stringify(state));

    const focusEventsBeforeProjectExit = state.focusEvents;
    await page.evaluate(() => {
      window.__activationRerendered['2'] = false;
      window.__finalRow = null;
      window.__rowRestoredAt = 0;
      window.__rowRemovedAt = 0;
    });
    await page.locator('#premium-fit-list .premium-fit-row[data-premium-row="2"]').evaluate(node => node.click());
    await page.evaluate(() => history.replaceState(null, '', '/cat?project=project-new'));
    await page.waitForFunction(() => window.__rowRestoredAt > window.__rowRemovedAt && window.__rowRestoredAt > 0, null, { timeout: 5000 });
    state = await page.evaluate(() => {
      const row = document.querySelector('#cat-grid-body [data-cat-row="2"]');
      const active = document.activeElement;
      return {
        project: new URLSearchParams(location.search).get('project'),
        view: document.body.getAttribute('data-cat-view'),
        workspaceHidden: document.getElementById('cat-workspace').hidden,
        title: document.getElementById('cat-toolbar-title').textContent,
        direction: document.getElementById('cat-toolbar-direction').textContent,
        rowArrived: window.__rowRestoredAt > window.__rowRemovedAt && !!row,
        rowActive: !!row && row.classList.contains('is-active'),
        focusedTarget: !!active && active.getAttribute('data-cat-input') === '2',
        focusEvents: window.__focusEvents,
        activationRerenders: window.__activationRerenderCount,
        gridWasEmpty: window.__gridWasEmpty
      };
    });
    assert.deepStrictEqual(state, { project: 'project-new', view: 'workspace', workspaceHidden: false, title: 'Project Old', direction: 'to-en', rowArrived: true, rowActive: false, focusedTarget: false, focusEvents: focusEventsBeforeProjectExit, activationRerenders: 1, gridWasEmpty: true }, JSON.stringify(state));

    await page.evaluate(() => history.replaceState(null, '', '/cat?project=project-old'));
    await page.waitForFunction(() => !!document.querySelector('#premium-fit-list .premium-fit-row[data-premium-row="2"]'), null, { timeout: 5000 });
    const focusEventsBeforeViewExit = await page.evaluate(() => window.__focusEvents);
    await page.evaluate(() => {
      window.__activationRerendered['2'] = false;
      window.__finalRow = null;
      window.__rowRestoredAt = 0;
      window.__rowRemovedAt = 0;
    });
    await page.locator('#premium-fit-list .premium-fit-row[data-premium-row="2"]').evaluate(node => node.click());
    await page.evaluate(() => {
      document.body.setAttribute('data-cat-view', 'start');
      document.getElementById('cat-workspace').hidden = true;
    });
    await page.waitForFunction(() => window.__rowRestoredAt > window.__rowRemovedAt && window.__rowRestoredAt > 0, null, { timeout: 5000 });
    state = await page.evaluate(() => {
      const row = document.querySelector('#cat-grid-body [data-cat-row="2"]');
      const active = document.activeElement;
      return {
        project: new URLSearchParams(location.search).get('project'),
        view: document.body.getAttribute('data-cat-view'),
        workspaceHidden: document.getElementById('cat-workspace').hidden,
        title: document.getElementById('cat-toolbar-title').textContent,
        direction: document.getElementById('cat-toolbar-direction').textContent,
        rowArrived: window.__rowRestoredAt > window.__rowRemovedAt && !!row,
        rowActive: !!row && row.classList.contains('is-active'),
        focusedTarget: !!active && active.getAttribute('data-cat-input') === '2',
        focusEvents: window.__focusEvents,
        activationRerenders: window.__activationRerenderCount,
        gridWasEmpty: window.__gridWasEmpty
      };
    });
    assert.deepStrictEqual(state, { project: 'project-old', view: 'start', workspaceHidden: true, title: 'Project Old', direction: 'to-en', rowArrived: true, rowActive: false, focusedTarget: false, focusEvents: focusEventsBeforeViewExit, activationRerenders: 1, gridWasEmpty: true }, JSON.stringify(state));

    const importPage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    const importErrors = [];
    importPage.on('pageerror', error => importErrors.push(error.message));
    await importPage.goto(baseUrl + '/cat?import-test=1');
    await importPage.setContent(`<!doctype html><html><head><title>import-test</title><meta name="yaku-import" content="1"></head><body class="app-cat" data-cat-view="start">
      <main class="shell"><section id="cat-picker"><section id="cat-align-entry"><button id="cat-open-align-entry" type="button">過去のPDFを読み込む</button></section>
        <section id="cat-source-align" class="cat-start-panel"><h3>過去の訳を登録する</h3><p>日本語版と英語版のPDFから、再利用する訳を登録します。</p>
          <div class="field-label">日本語版のPDF<button type="button">ファイルを選ぶ</button></div>
          <div class="field-label">英語版のPDF<button type="button">ファイルを選ぶ</button></div>
          <button id="cat-align-paste-open" type="button">テキストを貼り付ける</button>
        </section></section><section id="cat-workspace" hidden><div id="cat-editor-toolbar"></div></section></main></body></html>`);
    await importPage.evaluate(() => history.replaceState(null, '', '/cat?import=1'));
    await importPage.addScriptTag({ path: premiumPath });
    await importPage.waitForFunction(() => {
      const past = document.querySelector('[data-premium-nav="past"]');
      const start = document.getElementById('premium-cat-start');
      const work = document.getElementById('premium-work-list');
      const align = document.getElementById('cat-source-align');
      return past && past.classList.contains('is-active') && past.getAttribute('href') === '/cat?import=1' &&
        document.body.classList.contains('premium-mode-import') && start && start.hidden && work && work.hidden &&
        align && !align.hidden && new URL(location.href).searchParams.get('import') === '1';
    }, null, { timeout: 20000 });
    const importState = await importPage.evaluate(() => ({
      activePast: document.querySelector('[data-premium-nav="past"]').classList.contains('is-active'),
      href: document.querySelector('[data-premium-nav="past"]').getAttribute('href'),
      search: location.search,
      importMode: document.body.classList.contains('premium-mode-import'),
      excelStartHidden: document.getElementById('premium-cat-start').hidden,
      workListHidden: document.getElementById('premium-work-list').hidden,
      alignVisible: !document.getElementById('cat-source-align').hidden,
      japanesePdf: document.body.textContent.includes('日本語版のPDF'),
      englishPdf: document.body.textContent.includes('英語版のPDF'),
      primaryAction: document.body.textContent.includes('テキストを貼り付ける'),
      viewport: [window.innerWidth, window.innerHeight]
    }));
    assert.deepStrictEqual(importState, { activePast: true, href: '/cat?import=1', search: '?import=1', importMode: true, excelStartHidden: true, workListHidden: true, alignVisible: true, japanesePdf: true, englishPdf: true, primaryAction: true, viewport: [1912, 987] }, JSON.stringify(importState));
    if (importErrors.length) throw new Error('PREMIUM_UI_IMPORT_PAGEERROR: ' + importErrors.join(' | '));
    await importPage.close();

    const alignPage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    const alignErrors = [];
    const alignConsole = [];
    alignPage.on('pageerror', error => alignErrors.push(error.message));
    alignPage.on('console', message => { if (message.type() === 'error') alignConsole.push(message.text()); });
    await alignPage.goto(baseUrl + '/cat?project=' + alignProject.id, { waitUntil: 'domcontentloaded' });
    await alignPage.waitForFunction(() => document.body.getAttribute('data-cat-source') === 'align' && document.body.classList.contains('premium-mode-align-workspace'), null, { timeout: 20000 });
    const alignState = await alignPage.evaluate(() => ({
      workspaceHidden: document.getElementById('cat-workspace').hidden,
      workspaceVisible: getComputedStyle(document.getElementById('cat-workspace')).display !== 'none',
      gridVisible: getComputedStyle(document.getElementById('cat-grid-wrap')).display !== 'none',
      activePast: document.querySelector('[data-premium-nav="past"]').classList.contains('is-active'),
      source: document.body.getAttribute('data-cat-source'),
      mode: document.body.classList.contains('premium-mode-align-workspace'),
      context: document.getElementById('premium-top-context').textContent,
      pageTitle: document.getElementById('cat-page-title').textContent,
      summaryPresent: !!document.getElementById('premium-work-summary'),
      fitPanelPresent: !!document.getElementById('premium-fit-panel'),
      fitListPresent: !!document.getElementById('premium-fit-list'),
      cellIntroPresent: !!document.getElementById('premium-editor-intro'),
      viewport: [window.innerWidth, window.innerHeight]
    }));
    const expectedAlignState = { workspaceHidden: false, workspaceVisible: true, gridVisible: true, activePast: true, source: 'align', mode: true, context: '\u904e\u53bb\u8a33\u306e\u5bfe\u5fdc\u78ba\u8a8d', pageTitle: '\u904e\u53bb\u8a33\u306e\u5bfe\u5fdc\u78ba\u8a8d', summaryPresent: false, fitPanelPresent: false, fitListPresent: false, cellIntroPresent: false, viewport: [1912, 987] };
    assert.deepStrictEqual(alignState, expectedAlignState, JSON.stringify({ actual: alignState, expected: expectedAlignState }));
    if (alignErrors.length) throw new Error('PREMIUM_UI_ALIGN_PAGEERROR: ' + alignErrors.join(' | '));
    if (alignConsole.length) throw new Error('PREMIUM_UI_ALIGN_CONSOLE: ' + alignConsole.join(' | '));
    const alignToolsBefore = await alignPage.evaluate(() => ({
      visible: !document.getElementById('premium-tools').hidden && getComputedStyle(document.getElementById('premium-tools')).display !== 'none',
      controls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      expanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
      excelProxyHidden: document.getElementById('premium-export').hidden,
      qaProxyHidden: document.getElementById('premium-qa').hidden
    }));
    assert.deepStrictEqual(alignToolsBefore, { visible: true, controls: 'cat-editor-toolbar', expanded: 'false', excelProxyHidden: true, qaProxyHidden: true }, JSON.stringify(alignToolsBefore));
    console.log('align tools open wait: start');
    await alignPage.locator('#premium-tools').click();
    try {
      await alignPage.waitForFunction(() => document.body.classList.contains('premium-tools-open') &&
        document.getElementById('cat-editor-toolbar') && getComputedStyle(document.getElementById('cat-editor-toolbar')).display !== 'none', null, { timeout: 20000 });
    } catch (error) {
      const diagnostic = await alignPage.evaluate(() => ({
        url: location.href,
        source: document.body.getAttribute('data-cat-source'),
        view: document.body.getAttribute('data-cat-view'),
        toolsOpen: document.body.classList.contains('premium-tools-open'),
        toolsHidden: document.getElementById('premium-tools') && document.getElementById('premium-tools').hidden,
        controls: document.getElementById('premium-tools') && document.getElementById('premium-tools').getAttribute('aria-controls'),
        expanded: document.getElementById('premium-tools') && document.getElementById('premium-tools').getAttribute('aria-expanded'),
        toolbarDisplay: document.getElementById('cat-editor-toolbar') && getComputedStyle(document.getElementById('cat-editor-toolbar')).display
      }));
      throw new Error('PREMIUM_UI_ALIGN_TOOLS_OPEN_TIMEOUT: ' + JSON.stringify({ diagnostic, cause: error.message }));
    }
    console.log('align tools open wait: ready');
    const alignNativeTools = await alignPage.evaluate(() => {
      const visible = id => {
        const node = document.getElementById(id);
        return !!node && !node.hidden && getComputedStyle(node).display !== 'none';
      };
      const filter = document.querySelector('[data-cat-filter="all"]');
      const segmentActions = document.getElementById('cat-segment-actions');
      return {
        toolbarVisible: getComputedStyle(document.getElementById('cat-editor-toolbar')).display !== 'none',
        controls: document.getElementById('premium-tools').getAttribute('aria-controls'),
        expanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
        docSwitch: visible('cat-doc-switch'),
        search: visible('cat-search'),
        qa: visible('cat-qa-open'),
        export: visible('cat-export'),
        filterVisible: !!filter && !filter.hidden && getComputedStyle(filter).display !== 'none' && !filter.disabled,
        segmentActions: !!segmentActions && !segmentActions.hidden && segmentActions.querySelectorAll('button').length > 0
      };
    });
    assert.deepStrictEqual(alignNativeTools, { toolbarVisible: true, controls: 'cat-editor-toolbar', expanded: 'true', docSwitch: true, search: true, qa: true, export: true, filterVisible: true, segmentActions: true }, JSON.stringify(alignNativeTools));
    console.log('align tools close wait: start');
    await alignPage.keyboard.press('Escape');
    try {
      await alignPage.waitForFunction(() => !document.body.classList.contains('premium-tools-open') &&
        document.getElementById('premium-tools').getAttribute('aria-expanded') === 'false', null, { timeout: 20000 });
    } catch (error) {
      const diagnostic = await alignPage.evaluate(() => ({
        url: location.href,
        source: document.body.getAttribute('data-cat-source'),
        view: document.body.getAttribute('data-cat-view'),
        toolsOpen: document.body.classList.contains('premium-tools-open'),
        controls: document.getElementById('premium-tools') && document.getElementById('premium-tools').getAttribute('aria-controls'),
        expanded: document.getElementById('premium-tools') && document.getElementById('premium-tools').getAttribute('aria-expanded'),
        active: document.activeElement && document.activeElement.id,
        toolbarDisplay: document.getElementById('cat-editor-toolbar') && getComputedStyle(document.getElementById('cat-editor-toolbar')).display
      }));
      throw new Error('PREMIUM_UI_ALIGN_TOOLS_CLOSE_TIMEOUT: ' + JSON.stringify({ diagnostic, cause: error.message }));
    }
    console.log('align tools close wait: ready');
    const alignToolsAfter = await alignPage.evaluate(() => ({
      toolbarVisible: getComputedStyle(document.getElementById('cat-editor-toolbar')).display !== 'none',
      expanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(alignToolsAfter, { toolbarVisible: false, expanded: 'false', active: 'premium-tools' }, JSON.stringify(alignToolsAfter));
    await alignPage.close();

    const tmRetryLabel = '\u7ffb\u8a33\u30e1\u30e2\u30ea\u3078\u306e\u53cd\u6620\u3092\u518d\u8a66\u884c';
    const tmRetryDone = '\u7ffb\u8a33\u30e1\u30e2\u30ea\u3078\u306e\u53cd\u6620\u304c\u5b8c\u4e86\u3057\u307e\u3057\u305f';
    const tmNoPending = '\u53cd\u6620\u5f85\u3061\u306f\u3042\u308a\u307e\u305b\u3093';
    const tmNoPast = '\u767b\u9332\u3067\u304d\u308b\u904e\u53bb\u8a33\u306f\u3042\u308a\u307e\u305b\u3093';
    const pendingPage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    const pendingErrors = [];
    pendingPage.on('pageerror', error => pendingErrors.push(error.message));
    await pendingPage.goto(baseUrl + '/cat?project=' + pendingAlignProject.id, { waitUntil: 'domcontentloaded' });
    try {
      await pendingPage.waitForFunction(() => document.body.getAttribute('data-cat-source') === 'align' &&
        document.getElementById('cat-align-register-bulk') &&
        !document.getElementById('cat-align-register-bulk').disabled &&
        document.getElementById('cat-align-register-bulk').getAttribute('aria-disabled') === 'false', null, { timeout: 20000 });
    } catch (error) {
      const diagnostic = await pendingPage.evaluate(() => ({
        url: location.href,
        source: document.body.getAttribute('data-cat-source'),
        view: document.body.getAttribute('data-cat-view'),
        button: document.getElementById('cat-align-register-bulk') && {
          text: document.getElementById('cat-align-register-bulk').textContent,
          disabled: document.getElementById('cat-align-register-bulk').disabled
        },
        status: document.getElementById('cat-status') && document.getElementById('cat-status').textContent
      }));
      throw new Error('PREMIUM_UI_TM_PENDING_TIMEOUT: ' + JSON.stringify({ diagnostic, pendingErrors, cause: error.message }));
    }
    const pendingBefore = await pendingPage.evaluate(() => {
      const button = document.getElementById('cat-align-register-bulk');
      return { text: button.textContent, disabled: button.disabled, ariaDisabled: button.getAttribute('aria-disabled') };
    });
    assert.deepStrictEqual(pendingBefore, {
      text: tmRetryLabel, disabled: false, ariaDisabled: 'false'
    }, JSON.stringify(pendingBefore));
    await pendingPage.evaluate(() => {
      window.__premiumConfirmMessages = [];
      window.confirm = message => { window.__premiumConfirmMessages.push(message); return false; };
    });
    await pendingPage.locator('#cat-align-register-bulk').click();
    await pendingPage.waitForFunction(expected => document.getElementById('cat-align-register-bulk').disabled &&
      document.getElementById('cat-align-register-bulk').textContent === expected, tmNoPast, { timeout: 20000 });
    const pendingAfter = await pendingPage.evaluate(() => ({
      status: document.getElementById('cat-status').textContent,
      buttonText: document.getElementById('cat-align-register-bulk').textContent,
      buttonDisabled: document.getElementById('cat-align-register-bulk').disabled,
      confirmMessages: window.__premiumConfirmMessages.slice()
    }));
    assert.ok(pendingAfter.status.includes(tmRetryDone) && pendingAfter.status.includes(tmNoPending), JSON.stringify(pendingAfter));
    assert.strictEqual(pendingAfter.buttonText, tmNoPast, JSON.stringify(pendingAfter));
    assert.strictEqual(pendingAfter.buttonDisabled, true, JSON.stringify(pendingAfter));
    assert.deepStrictEqual(pendingAfter.confirmMessages, [], JSON.stringify(pendingAfter));
    if (pendingErrors.length) throw new Error('PREMIUM_UI_TM_PENDING_PAGEERROR: ' + pendingErrors.join(' | '));
    await pendingPage.close();

    const importRuntimePage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    const importRuntimeErrors = [];
    const importRuntimeConsole = [];
    importRuntimePage.on('pageerror', error => importRuntimeErrors.push(error.message));
    importRuntimePage.on('console', message => { if (message.type() === 'error') importRuntimeConsole.push(message.text()); });
    const importResponse = await importRuntimePage.goto(baseUrl + '/cat?import=1', { waitUntil: 'domcontentloaded' });
    const importCsp = importResponse ? (importResponse.headers()['content-security-policy'] || '') : '';
    await importRuntimePage.waitForFunction(() => {
      const meta = document.querySelector('meta[name="yaku-import"]');
      const align = document.getElementById('cat-source-align');
      return location.search === '?import=1' && meta && meta.getAttribute('content') === '1' &&
        document.body.classList.contains('premium-mode-import') && align && !align.hidden;
    }, null, { timeout: 20000 });
    let importRuntimeState = await importRuntimePage.evaluate(() => ({
      search: location.search,
      importMeta: document.querySelector('meta[name="yaku-import"]').getAttribute('content'),
      alignVisible: !document.getElementById('cat-source-align').hidden,
      activePast: document.querySelector('[data-premium-nav="past"]').classList.contains('is-active'),
      importMode: document.body.classList.contains('premium-mode-import')
    }));
    assert.deepStrictEqual(importRuntimeState, { search: '?import=1', importMeta: '1', alignVisible: true, activePast: true, importMode: true }, JSON.stringify(importRuntimeState));
    assert.ok(importCsp.includes('wasm-unsafe-eval'), importCsp);

    await importRuntimePage.evaluate(() => {
      history.pushState(null, '', '/cat?project=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      history.back();
    });
    await importRuntimePage.waitForFunction(() => location.search === '?import=1' &&
      document.body.classList.contains('premium-mode-import') &&
      document.getElementById('cat-source-align') && !document.getElementById('cat-source-align').hidden, null, { timeout: 10000 });
    importRuntimeState = await importRuntimePage.evaluate(() => ({
      search: location.search,
      alignVisible: !document.getElementById('cat-source-align').hidden,
      activePast: document.querySelector('[data-premium-nav="past"]').classList.contains('is-active'),
      importMode: document.body.classList.contains('premium-mode-import')
    }));
    assert.deepStrictEqual(importRuntimeState, { search: '?import=1', alignVisible: true, activePast: true, importMode: true }, JSON.stringify(importRuntimeState));

    const reloadResponse = await importRuntimePage.reload({ waitUntil: 'domcontentloaded' });
    const reloadCsp = reloadResponse ? (reloadResponse.headers()['content-security-policy'] || '') : '';
    await importRuntimePage.waitForFunction(() => location.search === '?import=1' &&
      document.querySelector('meta[name="yaku-import"]').getAttribute('content') === '1' &&
      document.body.classList.contains('premium-mode-import') &&
      document.getElementById('cat-source-align') && !document.getElementById('cat-source-align').hidden, null, { timeout: 20000 });
    importRuntimeState = await importRuntimePage.evaluate(() => ({
      search: location.search,
      importMeta: document.querySelector('meta[name="yaku-import"]').getAttribute('content'),
      alignVisible: !document.getElementById('cat-source-align').hidden,
      activePast: document.querySelector('[data-premium-nav="past"]').classList.contains('is-active'),
      importMode: document.body.classList.contains('premium-mode-import')
    }));
    assert.deepStrictEqual(importRuntimeState, { search: '?import=1', importMeta: '1', alignVisible: true, activePast: true, importMode: true }, JSON.stringify(importRuntimeState));
    assert.ok(reloadCsp.includes('wasm-unsafe-eval'), reloadCsp);
    if (importRuntimeErrors.length) throw new Error('PREMIUM_UI_IMPORT_RUNTIME_PAGEERROR: ' + importRuntimeErrors.join(' | '));
    if (importRuntimeConsole.length) throw new Error('PREMIUM_UI_IMPORT_RUNTIME_CONSOLE: ' + importRuntimeConsole.join(' | '));
    await importRuntimePage.close();

    const pastLabel = '\u904e\u53bb\u8a33\u306e\u5bfe\u5fdc\u78ba\u8a8d';
    const pastResumeLabel = pastLabel + '\u3092\u518d\u958b';
    const remainingLabel = '\u3042\u30682\u884c';
    const excelDirectionLabel = '\u65e5\u672c\u8a9e \u2192 \u82f1\u8a9e';
    const excelResumeLabel = '\u7d9a\u304d\u304b\u3089\u958b\u304f';
    const originalPdfLabel = '\u5143\u306ePDF';
    const originalExcelLabel = '\u5143\u306eExcel';
    const workPage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
    const workErrors = [];
    const workConsole = [];
    workPage.on('pageerror', error => workErrors.push(error.message));
    workPage.on('console', message => { if (message.type() === 'error') workConsole.push(message.text()); });
    await workPage.goto(baseUrl + '/cat?view=work', { waitUntil: 'domcontentloaded' });
    try {
      await workPage.waitForFunction(() => document.body.classList.contains('premium-mode-worklist') &&
        document.querySelectorAll('#premium-work-cards .premium-work-card').length === 2, null, { timeout: 20000 });
    } catch (error) {
      const diagnostic = await workPage.evaluate(() => ({
        url: location.href,
        bodyClass: document.body.className,
        catView: document.body.getAttribute('data-cat-view'),
        cards: document.querySelectorAll('#premium-work-cards .premium-work-card').length,
        workList: !!document.getElementById('premium-work-list'),
        workListHidden: document.getElementById('premium-work-list') && document.getElementById('premium-work-list').hidden
      }));
      throw new Error('PREMIUM_UI_WORK_LIST_TIMEOUT: ' + JSON.stringify({ diagnostic, workErrors, workConsole, cause: error.message }));
    }
    const workState = await workPage.evaluate(() => {
      const align = document.querySelector('[data-work-id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]');
      const excel = document.querySelector('[data-work-id="cccccccccccccccccccccccccccccccc"]');
      return {
        alignText: align.textContent,
        alignIcon: align.querySelector('.premium-work-file-icon').textContent,
        alignMeta: align.querySelector('.premium-work-card-meta').textContent,
        alignOpen: align.querySelector('a').textContent.replace(/\s+/g, ' ').trim(),
        alignHref: align.querySelector('a').getAttribute('href'),
        excelText: excel.textContent,
        excelIcon: excel.querySelector('.premium-work-file-icon').textContent,
        excelOpen: excel.querySelector('a').textContent.replace(/\s+/g, ' ').trim(),
        sidebarAlignMeta: document.querySelector('.premium-recent-item[href*="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] span').textContent,
        pageDescription: document.querySelector('.premium-work-list-head p').textContent,
        topContext: document.getElementById('premium-top-context').textContent
      };
    });
    assert.ok(workState.alignText.includes(pastLabel) && !workState.alignText.includes('Excel') && !workState.alignText.includes('XLS'), 'align card text: ' + JSON.stringify(workState));
    assert.strictEqual(workState.alignIcon, '\u2194', 'align card icon: ' + JSON.stringify(workState));
    assert.ok(workState.alignMeta.includes(pastLabel) && workState.alignMeta.includes(remainingLabel), 'align card meta: ' + JSON.stringify(workState));
    assert.strictEqual(workState.alignOpen, pastResumeLabel, 'align reopen label: ' + JSON.stringify(workState));
    assert.strictEqual(workState.alignHref, '/cat?project=' + alignProject.id, 'align reopen href: ' + JSON.stringify(workState));
    assert.ok(workState.excelText.includes(excelDirectionLabel) && workState.excelText.includes(excelResumeLabel), 'Excel card text: ' + JSON.stringify(workState));
    assert.strictEqual(workState.excelIcon, 'XLS', 'Excel card icon: ' + JSON.stringify(workState));
    assert.strictEqual(workState.excelOpen, excelResumeLabel, 'Excel reopen label: ' + JSON.stringify(workState));
    assert.ok(workState.sidebarAlignMeta.includes(pastLabel) && !workState.sidebarAlignMeta.includes(excelDirectionLabel), 'sidebar align meta: ' + JSON.stringify(workState));
    assert.ok(workState.pageDescription.includes('\u0045\u0078\u0063\u0065\u006c\u7ffb\u8a33') && workState.pageDescription.includes(pastLabel), 'mixed work page description: ' + JSON.stringify(workState));
    assert.strictEqual(workState.topContext, '\u4fdd\u5b58\u6e08\u307f\u306e\u4f5c\u696d', 'mixed work topbar context: ' + JSON.stringify(workState));
    await workPage.evaluate(() => {
      window.confirm = message => { window.__premiumConfirmMessages.push(message); return false; };
      window.__premiumConfirmMessages = [];
    });
    await workPage.locator('[data-work-id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] [data-work-delete]').click();
    await workPage.locator('[data-work-id="cccccccccccccccccccccccccccccccc"] [data-work-delete]').click();
    const deleteState = await workPage.evaluate(() => ({ messages: window.__premiumConfirmMessages.slice() }));
    assert.strictEqual(deleteState.messages.length, 2, JSON.stringify(deleteState));
    assert.ok(deleteState.messages[0].includes(pastLabel) && deleteState.messages[0].includes(originalPdfLabel) && !deleteState.messages[0].includes(originalExcelLabel), JSON.stringify(deleteState));
    assert.ok(deleteState.messages[1].includes(originalExcelLabel), JSON.stringify(deleteState));
    await workPage.locator('[data-work-id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] a').click();
    await workPage.waitForFunction(() => new URLSearchParams(location.search).get('project') === 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', null, { timeout: 20000 });
    assert.strictEqual(new URL(workPage.url()).searchParams.get('project'), alignProject.id, workPage.url());
    if (workErrors.length) throw new Error('PREMIUM_UI_WORK_PAGEERROR: ' + workErrors.join(' | '));
    if (workConsole.length) throw new Error('PREMIUM_UI_WORK_CONSOLE: ' + workConsole.join(' | '));
    await workPage.close();

    await page.setContent(`<!doctype html><html><head><title>palette-test</title><link rel="stylesheet" href="/assets/premium-ui.css"></head><body class="app-palette premium-booting">
      <main class="palette-shell"><div class="palette-main">
        <form id="palette-form"><textarea id="palette-input">これは貼り付けた原文です。</textarea><div class="palette-input-row">入力 16 / 2000</div><div class="palette-direction-row"><div class="palette-direction-field"><label class="palette-direction-select-label" for="palette-direction-select">翻訳方向</label><select id="palette-direction-select"><option value="">自動判定</option><option value="to_en">日本語 → 英語</option></select></div><div class="palette-action-group"><button id="palette-submit" type="submit" aria-label="翻訳する">翻訳</button></div></div><div class="palette-context-field"><label class="palette-context-select-label" for="palette-context-select">用途</label><select id="palette-context-select"><option>一般</option></select></div></form>
        <div id="palette-instant"><div class="result-card"><div class="translation">すぐ使える訳文</div><div class="result-actions"><span class="result-kind">短訳</span><button type="button">コピー</button></div></div></div>
        <div id="palette-chips"><span>候補 3件</span><button type="button">候補を使う</button></div>
        <div id="palette-result"><div class="result-card"><div class="translation">これは貼り付けた原文の訳です。</div><div class="result-actions"><span class="result-kind">翻訳結果</span><button type="button">コピー</button></div><p class="masking-notice">数値は送信前に保護されています。</p><p class="batch-note">結果を確認してから使えます。</p><div class="result-alts"><p class="result-alts-lead">別の言い方</p><button type="button" class="result-alt"><span class="result-alt-head">候補</span><span class="result-alt-body">別の訳文</span></button></div></div></div>
        <div class="palette-footer"><span class="palette-copy-status">コピーしました</span></div><p class="palette-fineprint">入力内容はこの画面で処理します。</p><p class="palette-long-notice">長い文章は分けて処理します。</p>
      </div></main>
    </body></html>`);
    await page.addScriptTag({ path: premiumPath });
    await page.waitForFunction(() => document.getElementById('premium-quick-layout') && !document.body.classList.contains('premium-booting'), null, { timeout: 10000 });
    const measurePalette = () => page.evaluate(() => {
      const visible = node => { const box = node && node.getBoundingClientRect(), style = node && getComputedStyle(node); return !!node && !node.hidden && style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0; };
      const directText = node => Array.from(node.childNodes).some(child => child.nodeType === Node.TEXT_NODE && child.textContent.trim());
      const textNodes = Array.from(document.querySelectorAll('.premium-quick-layout h1,.premium-quick-layout h2,.premium-quick-layout h3,.premium-quick-layout p,.premium-quick-layout a,.premium-quick-layout button,.premium-quick-layout strong,.premium-quick-layout span,.premium-quick-layout small,.premium-quick-layout em,.premium-quick-layout label,.premium-quick-layout textarea,.premium-quick-layout select')).filter(node => visible(node) && (directText(node) || node.matches('textarea,select')) && node.id !== 'palette-submit' && node.getAttribute('aria-hidden') !== 'true');
      const fonts = textNodes.map(node => parseFloat(getComputedStyle(node).fontSize)).filter(Number.isFinite);
      const actions = Array.from(document.querySelectorAll('#palette-submit,#palette-direction-select,#palette-context-select,#premium-quick-handoff,.premium-quick-prompts button,.premium-segmented button,#palette-result .result-actions button,#palette-instant .result-actions button,#palette-chips button,.premium-result-link,.premium-answer-turn button,.result-alt')).filter(visible);
      const actionMetrics = actions.map(node => ({ id: node.id, className: String(node.className || ''), height: node.getBoundingClientRect().height, font: parseFloat(getComputedStyle(node).fontSize), text: node.textContent.trim().slice(0, 30) }));
      const meaningfulActionFonts = actionMetrics.map(item => item.font).filter(value => Number.isFinite(value) && value > 0);
      const lowest = textNodes.map(node => ({ tag: node.tagName, id: node.id, className: String(node.className || ''), text: node.textContent.trim().slice(0, 40), font: parseFloat(getComputedStyle(node).fontSize) })).sort((a, b) => a.font - b.font).slice(0, 8);
      return {
        viewport: { width: innerWidth, height: innerHeight },
        booting: document.body.classList.contains('premium-booting'),
        title: document.title,
        heading: document.querySelector('.premium-quick-head h1').textContent.trim(),
        description: document.querySelector('.premium-quick-head p').textContent.trim(),
        minFont: fonts.length ? Math.min.apply(Math, fonts) : 0,
        lowest,
        inputFont: parseFloat(getComputedStyle(document.getElementById('palette-input')).fontSize),
        actionFontFloor: meaningfulActionFonts.length ? Math.min.apply(Math, meaningfulActionFonts) : 0,
        actionMinHeight: actionMetrics.length ? Math.min.apply(Math, actionMetrics.map(item => item.height)) : 0,
        actionMetrics,
        bodyFont: parseFloat(getComputedStyle(document.body).fontSize),
        overflow: document.documentElement.scrollWidth > innerWidth + 1 || document.body.scrollWidth > innerWidth + 1,
        scrollWidth: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth)
      };
    });
    const paletteWide = await measurePalette();
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.waitForTimeout(80);
    const paletteNarrow = await measurePalette();
    [paletteWide, paletteNarrow].forEach(paletteState => {
      assert.ok(paletteState.booting === false && paletteState.title === '\u30c1\u30e3\u30c3\u30c8\u7ffb\u8a33 - YakuLingo' && paletteState.heading === '\u30c1\u30e3\u30c3\u30c8\u7ffb\u8a33' && paletteState.description.includes('\u6587\u7ae0\u3092\u8cbc\u3063\u3066\u3059\u3050\u8a33') && paletteState.minFont >= 12 && paletteState.inputFont >= 16 && paletteState.actionFontFloor >= 12 && paletteState.actionMinHeight >= 44 && paletteState.bodyFont >= 16 && paletteState.overflow === false, JSON.stringify(paletteState));
    });
    console.log('Premium palette 1912x987 typography:', JSON.stringify(paletteWide));
    console.log('Premium palette 1200x800 typography:', JSON.stringify(paletteNarrow));
    await page.setViewportSize({ width: 1912, height: 987 });
    await page.waitForSelector('#premium-tools', { state: 'attached' });
    state = await page.evaluate(() => ({
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded')
    }));
    assert.deepStrictEqual(state, { toolsControls: null, toolsExpanded: null }, JSON.stringify(state));

    if (pageErrors.length) throw new Error('PREMIUM_UI_BROWSER_PAGEERROR: ' + pageErrors.join(' | '));
    console.log('Premium specialized UI browser contract passed.');
    } catch (error) {
      primaryError = error;
      throw error;
    } finally {
      if (browser) {
        try {
          await browser.close();
        } catch (error) {
          if (!primaryError) primaryError = error;
        }
      }
    }
  } finally {
    await new Promise(resolve => {
      if (!server.listening) {
        resolve();
        return;
      }
      try {
        server.close(() => resolve());
      } catch (_) {
        resolve();
      }
    });
  }
  if (primaryError) throw primaryError;
})().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
'@
$harnessOutput = $harness | & $node.Source - (Join-Path $Root 'www\assets\premium-ui.js') (Join-Path $Root 'www') 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ('PREMIUM_UI_BROWSER_HARNESS_FAILED: ' + (@($harnessOutput) -join ' '))
}
foreach ($line in @($harnessOutput)) { Write-Host $line }

Write-Host 'Premium specialized UI contract passed.' -ForegroundColor Green
