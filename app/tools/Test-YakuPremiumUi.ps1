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
Assert-YakuPremiumContains $js 'premium-combined-chat' 'PREMIUM_UI_COMBINED_CHAT_MISSING'
Assert-YakuPremiumContains $js 'premium-combined-excel' 'PREMIUM_UI_COMBINED_EXCEL_MISSING'
Assert-YakuPremiumContains $js 'var combinedStart = !isWorkspace && !workMode && !importMode' 'PREMIUM_UI_SINGLE_TRANSLATION_SURFACE_MISSING'
Assert-YakuPremiumContains $js '翻訳ワークスペース[\s\S]{0,120}?文章もExcelも、ひとつの画面で。' 'PREMIUM_UI_WORKSPACE_COPY_MISSING'
if ($js -match '翻訳を始める|文章もExcelも、ここからすぐに。') { throw 'PREMIUM_UI_ENTRY_PAGE_COPY_REINTRODUCED' }
Assert-YakuPremiumContains $js 'embeddedChatMarkup\(\)' 'PREMIUM_UI_LIVE_CHAT_EMBED_MISSING'
Assert-YakuPremiumContains $cat 'premium-ui\.js[\s\S]{0,240}?palette\.js' 'PREMIUM_UI_LIVE_CHAT_SCRIPT_ORDER_MISSING'
Assert-YakuPremiumContains $css 'premium-combined-grid[\s\S]*grid-template-columns:repeat\(2,minmax\(0,1fr\)\)' 'PREMIUM_UI_COMBINED_EQUAL_SPLIT_MISSING'
Assert-YakuPremiumContains $cat '<title>Excel翻訳 - YakuLingo</title>' 'PREMIUM_UI_CAT_TITLE_MISSING'
Assert-YakuPremiumContains $palette '<title>チャット翻訳 - YakuLingo</title>' 'PREMIUM_UI_CHAT_TITLE_MISSING'
Assert-YakuPremiumContains $palette 'class="brand home-link" href="/"' 'PREMIUM_UI_PALETTE_HOME_ROUTE_MISSING'
Assert-YakuPremiumContains $js 'class="premium-brand" href="/"' 'PREMIUM_UI_SIDEBAR_HOME_ROUTE_MISSING'
Assert-YakuPremiumContains $cat 'premium-booting' 'PREMIUM_UI_CAT_BOOTING_CLASS_MISSING'
Assert-YakuPremiumContains $palette 'premium-booting' 'PREMIUM_UI_PALETTE_BOOTING_CLASS_MISSING'

foreach ($id in @('cat-picker','cat-workspace','cat-grid-body','cat-preview-dock','cat-export','cat-translate','cat-qa-open')) {
    Assert-YakuPremiumContains $cat ('id=["'']' + [regex]::Escape($id) + '["'']') ('PREMIUM_UI_CAT_CONTRACT_MISSING: ' + $id)
}
foreach ($id in @('palette-form','palette-input','palette-direction-select','palette-handoff','palette-context-select','palette-result')) {
    Assert-YakuPremiumContains $palette ('id=["'']' + [regex]::Escape($id) + '["'']') ('PREMIUM_UI_PALETTE_CONTRACT_MISSING: ' + $id)
}

foreach ($label in @('翻訳','文章もExcelもここで','過去訳','作業一覧','確認済みを再利用','保存済みの作業')) {
    Assert-YakuPremiumContains $js ([regex]::Escape($label)) ('PREMIUM_UI_NAV_LABEL_MISSING: ' + $label)
}
if ($js -match 'クイック翻訳') { throw 'PREMIUM_UI_OLD_CHAT_LABEL_REINTRODUCED' }
if ($js -match 'href="/palette"|premium-mode-excel-start.*true|setActiveNav\(''excel''\)') { throw 'PREMIUM_UI_SEPARATE_TRANSLATION_START_REINTRODUCED' }
Assert-YakuPremiumContains $js 'finally[\s\S]*premium-booting' 'PREMIUM_UI_BOOTING_FINALLY_MISSING'
if ($js -match '枠に収める|サクッと翻訳') { throw 'PREMIUM_UI_REJECTED_NAV_LABEL_REINTRODUCED' }
if ($js -match 'カジュアル') { throw 'PREMIUM_UI_UNSUPPORTED_TONE_EXPOSED' }
Assert-YakuPremiumContains $js 'data-length=.brief' 'PREMIUM_UI_BRIEF_MODE_MISSING'
Assert-YakuPremiumContains $js 'data-tone=.polite' 'PREMIUM_UI_POLITE_MODE_MISSING'
Assert-YakuPremiumContains $js "form\.addEventListener\('submit'" 'PREMIUM_UI_QUICK_SUBMIT_DELEGATION_MISSING'
Assert-YakuPremiumContains $js 'palette-result' 'PREMIUM_UI_QUICK_RESULT_WIRING_MISSING'
Assert-YakuPremiumContains $js '/api/cat/open' 'PREMIUM_UI_EXCEL_OPEN_WIRING_MISSING'
Assert-YakuPremiumContains $catJs "post\('recent'|/api/cat/recent" 'PREMIUM_UI_CAT_RECENT_WIRING_MISSING'
Assert-YakuPremiumContains $js 'adoptCatRecentSnapshot|yaku-cat-recent' 'PREMIUM_UI_CAT_RECENT_ADOPTION_MISSING'
Assert-YakuPremiumContains $js 'event\.defaultPrevented|event\.button !== 0|download' 'PREMIUM_UI_NAV_MODIFIER_GUARD_MISSING'
Assert-YakuPremiumContains $catJs 'pendingHistoryResume|resumeFromHistory|rollbackPendingHistoryResume' 'PREMIUM_UI_PROJECT_HISTORY_RESUME_GUARD_MISSING'
Assert-YakuPremiumContains $js 'initialImport|premium-mode-import|cat-source-align' 'PREMIUM_UI_PAST_IMPORT_WIRING_MISSING'
Assert-YakuPremiumContains $js 'Excel翻訳と過去訳の対応確認|Excel翻訳や過去訳の対応確認を始めると' 'PREMIUM_UI_MIXED_WORK_COPY_MISSING'
Assert-YakuPremiumContains $js "setTopbar\('作業一覧', '保存済みの作業'" 'PREMIUM_UI_MIXED_WORK_TOPBAR_MISSING'
Assert-YakuPremiumContains $cat 'cat-source-align|日本語版のPDF|英語版のPDF' 'PREMIUM_UI_PAST_IMPORT_SURFACE_MISSING'
Assert-YakuPremiumContains $catJs 'function syncLocation\(projectId, preserveImport, preserveWork\)' 'PREMIUM_UI_IMPORT_LOCATION_SYNC_MISSING'
Assert-YakuPremiumContains $catJs "preserveImport \? '/cat\?import=1' : preserveWork \? '/cat\?view=work' : '/'" 'PREMIUM_UI_SINGLE_START_LOCATION_MISSING'
if ($catJs -match "keepCombinedRoot|: '/cat'\)" ) { throw 'PREMIUM_UI_SEPARATE_EXCEL_START_REINTRODUCED' }
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
Assert-YakuPremiumContains $css '(?s)body\.premium-ui\s*\{.*?font-size:\s*17px' 'PREMIUM_UI_BODY_FONT_FLOOR_MISSING'
Assert-YakuPremiumContains $css 'premium-booting' 'PREMIUM_UI_BOOTING_STYLE_MISSING'

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
let recentRequestCount = 0;
let refreshRecentOnce = false;
let delayedCatOpen = false;
let recentFailureOnce = false;
let delayedCatResumeMode = '';
const assetTypes = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8', '.wasm': 'application/wasm', '.json': 'application/json; charset=utf-8' };
function sendJson(response, value, statusCode = 200) {
  response.writeHead(statusCode, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
}

(async () => {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const isCombinedPage = url.pathname === '/';
    const isAlignProject = url.pathname === '/cat' && url.searchParams.get('project') === alignProject.id;
    const isPendingAlignProject = url.pathname === '/cat' && url.searchParams.get('project') === pendingAlignProject.id;
    const isLegacyStartPage = ['/quick', '/cat', '/palette'].includes(url.pathname) && !url.searchParams.has('project') && !url.searchParams.has('import') && !url.searchParams.has('view');
    const isImportPage = url.pathname === '/cat' && url.searchParams.get('import') === '1';
    const isWorkListPage = url.pathname === '/cat' && url.searchParams.get('view') === 'work';
    if (url.pathname === '/__enable-recent-refresh') {
      refreshRecentOnce = true;
      response.writeHead(204); response.end(); return;
    }
    if (url.pathname === '/__enable-delayed-cat-open') {
      delayedCatOpen = true;
      response.writeHead(204); response.end(); return;
    }
    if (url.pathname === '/__enable-recent-failure') {
      recentFailureOnce = true;
      response.writeHead(204); response.end(); return;
    }
    if (url.pathname === '/__enable-delayed-cat-resume-success') {
      delayedCatResumeMode = 'success';
      response.writeHead(204); response.end(); return;
    }
    if (url.pathname === '/__enable-delayed-cat-resume-failure') {
      delayedCatResumeMode = 'failure';
      response.writeHead(204); response.end(); return;
    }
    if (isCombinedPage || isLegacyStartPage || isAlignProject || isPendingAlignProject || isImportPage || isWorkListPage) {
      let html = fs.readFileSync(path.join(wwwPath, 'cat.html'), 'utf8');
      html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'premium-align-test')
        .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
        .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
        .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
        .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
        .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS P\\u30b4\\u30b7\\u30c3\\u30af')
        .replace(/__YAKU_TOUR__/g, '0')
        .replace(/__YAKU_IMPORT__/g, isImportPage ? '1' : '0')
        .replace(/__YAKU_VIEW__/g, isCombinedPage || isLegacyStartPage ? 'start' : isAlignProject || isPendingAlignProject ? 'workspace' : isWorkListPage ? 'work' : '');
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
        if (url.pathname === '/api/cat/resume') {
          const resumeResponse = body.project_id === pendingAlignProject.id ? pendingAlignProject : alignProject;
          if (!delayedCatResumeMode) return sendJson(response, resumeResponse);
          const resumeMode = delayedCatResumeMode;
          delayedCatResumeMode = '';
          return setTimeout(() => {
            try { sendJson(response, resumeMode === 'failure' ? { error: 'delayed resume fixture failure' } : resumeResponse, resumeMode === 'failure' ? 503 : 200); } catch (_) {}
          }, 1200);
        }
        if (url.pathname === '/api/upload') return sendJson(response, { file_handle: 'delayed-open-handle' });
        if (url.pathname === '/api/cat/open') {
          const openResponse = Object.assign({}, alignProject, { id: 'ffffffffffffffffffffffffffffffff', file_name: 'delayed-open.xlsx', source: 'file' });
          if (!delayedCatOpen) return sendJson(response, openResponse);
          return setTimeout(() => { try { sendJson(response, { error: 'delayed open fixture failure' }, 503); } catch (_) {} }, 1200);
        }
        if (url.pathname === '/api/cat/recent') {
          recentRequestCount++;
          if (recentFailureOnce) {
            recentFailureOnce = false;
            return sendJson(response, { error: 'recent fixture failure' }, 503);
          }
          if (refreshRecentOnce) {
            refreshRecentOnce = false;
            return sendJson(response, { projects: recentFixture.projects.concat([{ id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', source: 'file', file_name: 'refresh-marker.xlsx', direction: 'to_en', revision: 8, total: 5, confirmed: 4, saved: '2026-08-21T11:00:00' }]) });
          }
          return sendJson(response, recentFixture);
        }
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
      const combinedPage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
      const combinedErrors = [];
      combinedPage.on('pageerror', error => combinedErrors.push(error.message));
      const measureCombined = () => combinedPage.evaluate(() => {
        const visible = node => {
          if (!node) return false;
          const style = getComputedStyle(node), box = node.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
        };
        const chat = document.querySelector('.premium-combined-chat');
        const excel = document.querySelector('.premium-combined-excel');
        const chatBox = chat && chat.getBoundingClientRect();
        const excelBox = excel && excel.getBoundingClientRect();
        const input = document.getElementById('palette-input');
        const quickButton = document.getElementById('palette-submit');
        const excelButton = document.getElementById('premium-file-select');
        const recent = document.getElementById('premium-sidebar-recent');
        const recentItems = recent ? Array.from(recent.querySelectorAll('.premium-recent-item')) : [];
        const textNodes = Array.from(document.querySelectorAll('.premium-combined-grid h2,.premium-combined-grid p,.premium-combined-grid button,.premium-combined-grid select')).filter(node => visible(node) && !node.classList.contains('sr-only') && node.textContent.trim());
        const fonts = textNodes.map(node => parseFloat(getComputedStyle(node).fontSize)).filter(Number.isFinite);
        return {
          viewport: { width: innerWidth, height: innerHeight },
          mode: document.body.classList.contains('premium-mode-combined-start'),
          title: document.title,
          chat: { visible: visible(chat), width: chatBox ? chatBox.width : 0, height: chatBox ? chatBox.height : 0 },
          excel: { visible: visible(excel), width: excelBox ? excelBox.width : 0, height: excelBox ? excelBox.height : 0 },
          splitDelta: chatBox && excelBox ? Math.abs(chatBox.width - excelBox.width) : 999,
          minFont: fonts.length ? Math.min.apply(Math, fonts) : 0,
          bodyFont: parseFloat(getComputedStyle(document.body).fontSize),
          input: { visible: visible(input), font: input ? parseFloat(getComputedStyle(input).fontSize) : 0, form: input && input.form ? input.form.id : '' },
          quickButton: { visible: visible(quickButton), font: quickButton ? parseFloat(getComputedStyle(quickButton).fontSize) : 0, height: quickButton ? quickButton.getBoundingClientRect().height : 0 },
          excelButton: { visible: visible(excelButton), font: excelButton ? parseFloat(getComputedStyle(excelButton).fontSize) : 0, height: excelButton ? excelButton.getBoundingClientRect().height : 0 },
          fileDropVisible: visible(document.getElementById('premium-file-drop')),
          legacyFileLaneVisible: visible(document.getElementById('cat-file-area')),
          sidebarRecent: {
            visible: visible(recent),
            clientWidth: recent ? recent.clientWidth : 0,
            scrollWidth: recent ? recent.scrollWidth : 0,
            itemWidths: recentItems.map(node => ({ clientWidth: node.clientWidth, scrollWidth: node.scrollWidth })),
            noHorizontalOverflow: !!recent && recent.scrollWidth <= recent.clientWidth + 1 && recentItems.every(node => node.scrollWidth <= node.clientWidth + 1)
          },
          overflow: document.documentElement.scrollWidth > innerWidth + 1 || document.body.scrollWidth > innerWidth + 1
        };
      });
      recentRequestCount = 0;
      const combinedDocumentLoads = [];
      combinedPage.on('domcontentloaded', () => combinedDocumentLoads.push(combinedPage.url()));
      await combinedPage.goto(baseUrl + '/', { waitUntil: 'domcontentloaded' });
      await combinedPage.waitForTimeout(300);
      assert.strictEqual(recentRequestCount, 1, 'CAT initial load must request recent exactly once: ' + recentRequestCount);
      await combinedPage.evaluate(() => fetch('/__enable-recent-refresh'));
      await combinedPage.evaluate(() => window.YakuCat.refreshRecent());
      await combinedPage.waitForFunction(() => !!document.querySelector('#premium-work-cards [data-work-id="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]') && !!document.querySelector('.premium-recent-item[href*="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]'), null, { timeout: 10000 });
      assert.strictEqual(recentRequestCount, 2, 'YakuCat.refreshRecent must issue exactly one new recent request: ' + recentRequestCount);
      const recentCountAfterRefresh = recentRequestCount;
      const combinedWide = await measureCombined();
      assert.ok(combinedWide.mode && combinedWide.title === '\u7ffb\u8a33 - YakuLingo' && combinedWide.chat.visible && combinedWide.excel.visible && combinedWide.splitDelta <= 2 && combinedWide.input.visible && combinedWide.input.form === 'palette-form' && combinedWide.input.font >= 18 && combinedWide.quickButton.visible && combinedWide.quickButton.font >= 16 && combinedWide.quickButton.height >= 50 && combinedWide.excelButton.visible && combinedWide.excelButton.font >= 16 && combinedWide.excelButton.height >= 50 && combinedWide.fileDropVisible && !combinedWide.legacyFileLaneVisible && combinedWide.minFont >= 13 && combinedWide.bodyFont >= 17 && combinedWide.sidebarRecent.noHorizontalOverflow && !combinedWide.overflow, JSON.stringify(combinedWide));
      await combinedPage.locator('#palette-input').fill('\u58f2\u4e0a\u304c\u5897\u52a0\u3057\u307e\u3057\u305f\u3002');
      await combinedPage.waitForTimeout(100);
      assert.notStrictEqual(await combinedPage.locator('#palette-count').textContent(), '0\u5b57');
      const [combinedChooser] = await Promise.all([combinedPage.waitForEvent('filechooser'), combinedPage.locator('#premium-file-select').click()]);
      assert.ok(combinedChooser, 'PREMIUM_UI_COMBINED_EXCEL_CHOOSER_MISSING');
      await combinedPage.setViewportSize({ width: 1200, height: 800 });
      const combinedNarrow = await measureCombined();
      assert.ok(combinedNarrow.chat.visible && combinedNarrow.excel.visible && combinedNarrow.splitDelta <= 2 && combinedNarrow.input.visible && combinedNarrow.excelButton.visible && !combinedNarrow.overflow, JSON.stringify(combinedNarrow));
      await combinedPage.locator('#premium-direction-switch button[data-direction="to_jp"]').click();
      let directionState = await combinedPage.evaluate(() => Array.from(document.querySelectorAll('#premium-direction-switch button')).map(node => [node.getAttribute('data-direction'), node.getAttribute('aria-pressed'), node.classList.contains('is-active')]));
      assert.deepStrictEqual(directionState, [['to_en', 'false', false], ['to_jp', 'true', true]], JSON.stringify(directionState));
      await combinedPage.evaluate(() => { window.__catDocument = document; });
      const navCountBeforeStartWork = combinedDocumentLoads.length;
      const readStartNavState = () => combinedPage.evaluate(() => {
        const align = document.getElementById('cat-source-align');
        const active = document.querySelector('[data-premium-nav].is-active');
        return {
          url: location.pathname + location.search,
          active: active ? active.getAttribute('data-premium-nav') : '',
          startHidden: document.getElementById('premium-cat-start').hidden,
          workHidden: document.getElementById('premium-work-list').hidden,
          alignVisible: !!align && !align.hidden,
          view: document.body.getAttribute('data-cat-view'),
          identity: document === window.__catDocument
        };
      });
      const catNavPre = await combinedPage.evaluate(() => ({ view: document.body.getAttribute('data-cat-view'), href: document.querySelector('[data-premium-nav="work"]').getAttribute('href'), navigate: typeof window.YakuCat && typeof window.YakuCat.navigateStart === 'function' }));
      assert.deepStrictEqual(catNavPre, { view: 'start', href: '/cat?view=work', navigate: true }, JSON.stringify(catNavPre));
      await combinedPage.locator('[data-premium-nav="work"]').click();
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist'), null, { timeout: 10000 });
      assert.deepStrictEqual(await readStartNavState(), { url: '/cat?view=work', active: 'work', startHidden: true, workHidden: false, alignVisible: false, view: 'start', identity: true });
      assert.strictEqual(combinedDocumentLoads.length, navCountBeforeStartWork, 'start -> work must not reload the document');
      assert.strictEqual(recentRequestCount, recentCountAfterRefresh, 'start -> work must reuse the CAT recent snapshot');
      assert.strictEqual(await combinedPage.evaluate(() => document === window.__catDocument), true, 'start -> work must preserve document identity');
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 10000 });
      assert.deepStrictEqual(await readStartNavState(), { url: '/', active: 'translate', startHidden: false, workHidden: true, alignVisible: false, view: 'start', identity: true });
      assert.strictEqual(combinedDocumentLoads.length, navCountBeforeStartWork, 'Back must remain in-document');
      assert.strictEqual(await combinedPage.evaluate(() => document === window.__catDocument), true, 'Back must preserve document identity');
      await combinedPage.evaluate(() => history.forward());
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist'), null, { timeout: 10000 });
      assert.deepStrictEqual(await readStartNavState(), { url: '/cat?view=work', active: 'work', startHidden: true, workHidden: false, alignVisible: false, view: 'start', identity: true });
      assert.strictEqual(combinedDocumentLoads.length, navCountBeforeStartWork, 'Forward must remain in-document');
      assert.strictEqual(recentRequestCount, recentCountAfterRefresh, 'Forward must not reload recent projects');
      assert.strictEqual(await combinedPage.evaluate(() => document === window.__catDocument), true, 'Forward must preserve document identity');
      const navInterceptionProbes = await combinedPage.evaluate(() => {
        const source = document.querySelector('[data-premium-nav="work"]');
        return [
          { button: 1 },
          { button: 0, ctrlKey: true },
          { button: 0, shiftKey: true },
          { button: 0, target: '_blank' },
          { button: 0, download: '' }
        ].map(options => {
          const link = source.cloneNode(true);
          link.href = '#navigation-probe';
          if (options.target) link.setAttribute('target', options.target);
          if (options.download !== undefined) link.setAttribute('download', options.download);
          document.body.appendChild(link);
          const event = new MouseEvent('click', Object.assign({ bubbles: true, cancelable: true }, options));
          link.dispatchEvent(event);
          link.remove();
          return { prevented: event.defaultPrevented, href: location.pathname + location.search };
        });
      });
      assert.ok(navInterceptionProbes.every(item => !item.prevented && item.href === '/cat?view=work'), JSON.stringify(navInterceptionProbes));
      const beginDelayedCatOpen = async () => {
        await combinedPage.evaluate(() => {
          const input = document.getElementById('cat-file-input');
          const transfer = new DataTransfer();
          transfer.items.add(new File(['delayed'], 'busy-open.xlsx', { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
          input.files = transfer.files;
          input.dispatchEvent(new Event('change', { bubbles: true }));
        });
        await combinedPage.waitForFunction(() => !!window.YakuCat && YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && !document.getElementById('cat-file-loading').hidden, null, { timeout: 10000 });
      };
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 10000 });
      await combinedPage.evaluate(() => fetch('/__enable-delayed-cat-open'));
      await beginDelayedCatOpen();
      const busyClickLoads = combinedDocumentLoads.length;
      const busyClickDocumentLoad = combinedPage.waitForEvent('domcontentloaded');
      await combinedPage.locator('[data-premium-nav="work"]').click();
      await busyClickDocumentLoad;
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist') && !!window.YakuCat && !YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && document.getElementById('cat-file-loading').hidden, null, { timeout: 20000 });
      assert.ok(combinedDocumentLoads.length > busyClickLoads, 'busy start navigation must perform a native document navigation');
      await combinedPage.waitForTimeout(1500);
      assert.deepStrictEqual(await readStartNavState(), { url: '/cat?view=work', active: 'work', startHidden: true, workHidden: false, alignVisible: false, view: 'start', identity: false });

      /* Native busy navigation leaves a separate document entry. Start the
         same-document Back/Forward assertions from a clean root/work pair so
         the ordered app entries are the only candidates for history.go(). */
      await combinedPage.goto(baseUrl + '/', { waitUntil: 'domcontentloaded' });
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 10000 });
      await combinedPage.locator('[data-premium-nav="work"]').click();
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist'), null, { timeout: 10000 });
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 10000 });
      await combinedPage.evaluate(() => {
        window.__busyPopstateCount = 0;
        window.__busyBeforeUnloadCount = 0;
        window.__busyBeforeUnload = event => { window.__busyBeforeUnloadCount += 1; event.preventDefault(); };
        window.addEventListener('popstate', () => { window.__busyPopstateCount += 1; });
        window.addEventListener('beforeunload', window.__busyBeforeUnload);
      });
      await beginDelayedCatOpen();
      const busyForwardLoads = combinedDocumentLoads.length;
      await combinedPage.evaluate(() => history.forward());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start') && !!window.YakuCat && YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && !document.getElementById('cat-file-loading').hidden, null, { timeout: 10000 });
      assert.strictEqual(combinedDocumentLoads.length, busyForwardLoads, 'busy Forward must restore the applied document entry without a reload');
      assert.strictEqual(await combinedPage.evaluate(() => window.__busyPopstateCount), 2, 'busy Forward must restore once without a popstate loop');
      assert.strictEqual(await combinedPage.evaluate(() => window.__busyBeforeUnloadCount), 0, 'busy Forward must not invoke a dismissible unload');
      await combinedPage.waitForFunction(() => !!window.YakuCat && !YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && document.getElementById('cat-file-loading').hidden && location.pathname === '/' && location.search === '', null, { timeout: 10000 });
      await combinedPage.waitForTimeout(1500);
      assert.strictEqual(await combinedPage.evaluate(() => location.pathname + location.search), '/', 'delayed open must not overwrite the busy Forward destination');

      await combinedPage.locator('[data-premium-nav="work"]').click();
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist'), null, { timeout: 10000 });
      await beginDelayedCatOpen();
      const busyBackLoads = combinedDocumentLoads.length;
      await combinedPage.evaluate(() => { window.__busyPopstateCount = 0; });
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist') && !!window.YakuCat && YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && !document.getElementById('cat-file-loading').hidden, null, { timeout: 10000 });
      assert.strictEqual(combinedDocumentLoads.length, busyBackLoads, 'busy Back must restore the applied document entry without a reload');
      assert.strictEqual(await combinedPage.evaluate(() => window.__busyPopstateCount), 2, 'busy Back must restore once without a popstate loop');
      assert.strictEqual(await combinedPage.evaluate(() => window.__busyBeforeUnloadCount), 0, 'busy Back must not invoke a dismissible unload');
      await combinedPage.waitForFunction(() => !!window.YakuCat && !YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && document.getElementById('cat-file-loading').hidden && location.pathname === '/cat' && location.search === '?view=work', null, { timeout: 10000 });
      await combinedPage.waitForTimeout(1500);
      assert.strictEqual(await combinedPage.evaluate(() => location.pathname + location.search), '/cat?view=work', 'delayed open must not overwrite the busy Back destination');
      await combinedPage.evaluate(() => window.removeEventListener('beforeunload', window.__busyBeforeUnload));
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 10000 });
      const projectHistoryRoute = '/cat?project=' + alignProject.id;
      const prepareProjectHistory = async (mode) => {
        await combinedPage.evaluate(route => {
          const rootState = Object.assign({}, history.state || {}, { yakuCatNavigation: true, sequence: 0, route: '/' });
          history.replaceState(rootState, '', '/');
          history.pushState(Object.assign({}, rootState, { sequence: 1, route }), '', route);
          history.back();
        }, projectHistoryRoute);
        await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start') && !!window.YakuCat && !YakuCat.isBusy(), null, { timeout: 10000 });
        await combinedPage.evaluate(() => {
          window.__catDocument = document;
          window.__resumePopstateCount = 0;
        });
        await combinedPage.evaluate(endpoint => fetch(endpoint), '/__enable-delayed-cat-resume-' + mode);
        await combinedPage.evaluate(() => history.forward());
        await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search.indexOf('?project=') === 0 && document.body.classList.contains('premium-mode-combined-start') && !!window.YakuCat && YakuCat.isBusy() && !document.getElementById('cat-picker').hidden && document.getElementById('cat-workspace').hidden, null, { timeout: 10000 });
      };
      await combinedPage.evaluate(() => { window.__resumePopstateCount = 0; window.addEventListener('popstate', () => { window.__resumePopstateCount += 1; }); });
      await prepareProjectHistory('success');
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start') && !!window.YakuCat && !YakuCat.isBusy() && !document.getElementById('premium-cat-start').hidden && document.getElementById('premium-work-list').hidden, null, { timeout: 10000 });
      assert.strictEqual(await combinedPage.evaluate(() => window.__resumePopstateCount), 2, 'cancelled project resume must not loop history');
      assert.strictEqual(await combinedPage.evaluate(() => document === window.__catDocument), true, 'cancelled project resume must preserve document identity');
      await combinedPage.waitForTimeout(1500);
      const cancelledResumeState = await combinedPage.evaluate(() => ({ url: location.pathname + location.search, busy: YakuCat.isBusy(), start: !document.getElementById('premium-cat-start').hidden, work: document.getElementById('premium-work-list').hidden, workspace: document.getElementById('cat-workspace').hidden, status: document.getElementById('cat-status').textContent }));
      assert.deepStrictEqual(cancelledResumeState, { url: '/', busy: false, start: true, work: true, workspace: true, status: '' }, JSON.stringify(cancelledResumeState));

      await prepareProjectHistory('failure');
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && !!window.YakuCat && !YakuCat.isBusy() && !!document.getElementById('cat-status') && document.getElementById('cat-status').textContent.indexOf('delayed resume fixture failure') >= 0, null, { timeout: 20000 });
      assert.strictEqual(await combinedPage.evaluate(() => window.__resumePopstateCount), 2, 'failed project resume must rollback once without a history loop');
      assert.strictEqual(await combinedPage.evaluate(() => document === window.__catDocument), true, 'failed project resume rollback must preserve document identity');
      const failedResumeState = await combinedPage.evaluate(() => ({ url: location.pathname + location.search, busy: YakuCat.isBusy(), start: !document.getElementById('premium-cat-start').hidden, work: document.getElementById('premium-work-list').hidden, workspace: document.getElementById('cat-workspace').hidden, status: document.getElementById('cat-status').textContent }));
      assert.strictEqual(failedResumeState.url, '/', JSON.stringify(failedResumeState));
      assert.strictEqual(failedResumeState.busy, false, JSON.stringify(failedResumeState));
      assert.strictEqual(failedResumeState.start && failedResumeState.work && failedResumeState.workspace, true, JSON.stringify(failedResumeState));
      assert.ok(failedResumeState.status.indexOf('delayed resume fixture failure') >= 0, JSON.stringify(failedResumeState));
      await combinedPage.goto(baseUrl + '/', { waitUntil: 'domcontentloaded' });
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start') && !!window.YakuCat && !YakuCat.isBusy(), null, { timeout: 10000 });
      await combinedPage.evaluate(() => {
        window.__catDocument = document;
        window.__resumePopstateCount = 0;
        window.addEventListener('popstate', () => { window.__resumePopstateCount += 1; });
      });
      const duplicateProjectRoute = '/cat?project=' + alignProject.id;
      const secondProjectRoute = '/cat?project=' + pendingAlignProject.id;
      await combinedPage.evaluate(route => {
        const rootState = Object.assign({}, history.state || {}, { yakuCatNavigation: true, sequence: 0, route: '/' });
        history.replaceState(rootState, '', '/');
        history.pushState(Object.assign({}, rootState, { sequence: 1, route }), '', route);
        history.back();
      }, duplicateProjectRoute);
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '', null, { timeout: 10000 });
      await combinedPage.evaluate(() => history.forward());
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search.indexOf('?project=') === 0 && document.body.getAttribute('data-cat-view') === 'workspace' && !!window.YakuCat && !YakuCat.isBusy(), null, { timeout: 10000 });
      await combinedPage.evaluate(({ first, second }) => {
        const state = Object.assign({}, history.state || {}, { yakuCatNavigation: true });
        history.pushState(Object.assign({}, state, { sequence: 2, route: second }), '', second);
        history.pushState(Object.assign({}, state, { sequence: 3, route: first }), '', first);
      }, { first: duplicateProjectRoute, second: secondProjectRoute });
      await combinedPage.evaluate(() => fetch('/__enable-delayed-cat-resume-success'));
      await combinedPage.evaluate(() => { window.__resumePopstateCount = 0; history.back(); });
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search.indexOf('dddddddddddddddddddddddddddddddd') >= 0 && !!window.YakuCat && YakuCat.isBusy(), null, { timeout: 10000 });
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search.indexOf('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') >= 0 && document.body.getAttribute('data-cat-view') === 'workspace' && !!window.YakuCat && !YakuCat.isBusy(), null, { timeout: 10000 });
      assert.strictEqual(await combinedPage.evaluate(() => window.__resumePopstateCount), 2, 'duplicate project Back must cancel delayed resume without a history loop');
      const duplicateResumeState = await combinedPage.evaluate(() => ({ url: location.pathname + location.search, state: history.state, title: document.getElementById('cat-current-title').textContent, busy: YakuCat.isBusy(), workspace: !document.getElementById('cat-workspace').hidden, identity: document === window.__catDocument }));
      assert.strictEqual(duplicateResumeState.url, duplicateProjectRoute, JSON.stringify(duplicateResumeState));
      assert.strictEqual(duplicateResumeState.state.sequence, 1, JSON.stringify(duplicateResumeState));
      assert.strictEqual(duplicateResumeState.busy, false, JSON.stringify(duplicateResumeState));
      assert.strictEqual(duplicateResumeState.workspace && duplicateResumeState.identity, true, JSON.stringify(duplicateResumeState));
      await combinedPage.waitForTimeout(1500);
      assert.strictEqual(await combinedPage.evaluate(() => location.pathname + location.search), duplicateProjectRoute, 'stale delayed project response must not overwrite the earlier duplicate entry');
      await combinedPage.evaluate(() => fetch('/__enable-delayed-cat-open'));
      await combinedPage.evaluate(() => { window.__resumePopstateCount = 0; });
      await beginDelayedCatOpen();
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search.indexOf('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') >= 0 && document.body.getAttribute('data-cat-view') === 'workspace' && !!window.YakuCat && YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && !document.getElementById('cat-file-loading').hidden, null, { timeout: 10000 });
      assert.strictEqual(await combinedPage.evaluate(() => window.__resumePopstateCount), 2, 'busy Back after duplicate projects must restore the immediate A entry only');
      assert.strictEqual(await combinedPage.evaluate(() => history.state && history.state.sequence), 1, 'busy Back after duplicate projects must not jump to A3 or B2');
      await combinedPage.waitForFunction(() => !!window.YakuCat && !YakuCat.isBusy() && !!document.getElementById('cat-file-loading') && document.getElementById('cat-file-loading').hidden && location.pathname === '/cat' && location.search.indexOf('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') >= 0, null, { timeout: 10000 });
      await combinedPage.waitForTimeout(1500);
      assert.strictEqual(await combinedPage.evaluate(() => location.pathname + location.search), duplicateProjectRoute, 'delayed busy operation must not overwrite duplicate-project history');
      await combinedPage.evaluate(() => history.back());
      await combinedPage.waitForFunction(() => location.pathname === '/' && location.search === '' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 10000 });
      await combinedPage.locator('[data-premium-nav="work"]').click();
      await combinedPage.waitForFunction(() => location.pathname === '/cat' && location.search === '?view=work' && document.body.classList.contains('premium-mode-worklist'), null, { timeout: 10000 });
      await combinedPage.evaluate(() => history.replaceState(null, '', '/'));
      await combinedPage.evaluate(() => { const event = new PopStateEvent('popstate'); window.dispatchEvent(event); });
      await combinedPage.locator('#premium-reference-open').click();
      await combinedPage.waitForFunction(() => new URL(location.href).searchParams.get('import') === '1' && document.getElementById('cat-source-align') && !document.getElementById('cat-source-align').hidden, null, { timeout: 20000 });
      const importStartState = await combinedPage.evaluate(() => ({ query: new URL(location.href).searchParams.get('import'), panel: !document.getElementById('cat-source-align').hidden, japanese: document.body.textContent.includes('\u65e5\u672c\u8a9e\u7248\u306ePDF'), english: document.body.textContent.includes('\u82f1\u8a9e\u7248\u306ePDF') }));
      assert.deepStrictEqual(importStartState, { query: '1', panel: true, japanese: true, english: true }, JSON.stringify(importStartState));
      for (const legacyPath of ['/cat', '/palette', '/quick']) {
        await combinedPage.goto(baseUrl + legacyPath, { waitUntil: 'domcontentloaded' });
        await combinedPage.waitForFunction(() => location.pathname === '/' && document.body.classList.contains('premium-mode-combined-start'), null, { timeout: 20000 });
        const legacyState = await measureCombined();
        assert.ok(legacyState.chat.visible && legacyState.excel.visible && legacyState.splitDelta <= 2, legacyPath + ': ' + JSON.stringify(legacyState));
      }
      console.log('Premium combined 1912x987:', JSON.stringify(combinedWide));
      console.log('Premium combined 1200x800:', JSON.stringify(combinedNarrow));
      if (combinedErrors.length) throw new Error('PREMIUM_UI_COMBINED_PAGEERROR: ' + combinedErrors.join(' | '));
      await combinedPage.close();
      const recentFailurePage = await browser.newPage({ viewport: { width: 1912, height: 987 } });
      await recentFailurePage.goto(baseUrl + '/', { waitUntil: 'domcontentloaded' });
      await recentFailurePage.waitForFunction(() => document.querySelectorAll('.premium-recent-item').length === 2, null, { timeout: 10000 });
      const recentFailureBaseline = recentRequestCount;
      await recentFailurePage.evaluate(() => fetch('/__enable-recent-failure'));
      await recentFailurePage.reload({ waitUntil: 'domcontentloaded' });
      await recentFailurePage.waitForFunction(() => !!document.querySelector('#premium-sidebar-recent [data-premium-recent-error]') && !!document.querySelector('#premium-work-cards [data-premium-recent-error]'), null, { timeout: 10000 });
      assert.strictEqual(recentRequestCount, recentFailureBaseline + 1, 'recent failure must use one request and publish an explicit error snapshot');
      const recentFailureState = await recentFailurePage.evaluate(() => ({
        sidebarError: !!document.querySelector('#premium-sidebar-recent [data-premium-recent-error]'),
        workError: !!document.querySelector('#premium-work-cards [data-premium-recent-error]'),
        count: document.getElementById('premium-recent-count').textContent,
        workCards: document.querySelectorAll('#premium-work-cards .premium-work-card').length
      }));
      assert.deepStrictEqual(recentFailureState, { sidebarError: true, workError: true, count: '\u8aad\u8fbc\u5931\u6557', workCards: 0 }, JSON.stringify(recentFailureState));
      await recentFailurePage.locator('#premium-sidebar-recent [data-premium-recent-retry]').click();
      await recentFailurePage.waitForFunction(() => !document.querySelector('#premium-sidebar-recent [data-premium-recent-error]') && document.querySelectorAll('.premium-recent-item').length === 2 && document.querySelectorAll('#premium-work-cards .premium-work-card').length === 2, null, { timeout: 10000 });
      assert.strictEqual(recentRequestCount, recentFailureBaseline + 2, 'recent retry must issue one request and update both premium surfaces');
      await recentFailurePage.waitForTimeout(200);
      assert.strictEqual(recentRequestCount, recentFailureBaseline + 2, 'recent failure/retry must not create an API storm');
      await recentFailurePage.close();
      const page = await browser.newPage({ viewport: { width: 1912, height: 987 } });
      const pageErrors = [];
      page.on('pageerror', error => pageErrors.push(error.message));
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
    assert.ok(workspaceTypography.utilityFontFloor >= 13 && workspaceTypography.sourceFont >= 17 && workspaceTypography.targetFont >= 18 && workspaceTypography.outputFont >= 14 && workspaceTypography.outputButtonFont >= 14 && workspaceTypography.outputButtonHeight >= 44 && workspaceTypography.toastFont >= 14 && !workspaceTypography.overflow, JSON.stringify(workspaceTypography));
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
      const past = document.querySelector('[data-premium-nav="past"]');
      const start = document.getElementById('premium-cat-start');
      const work = document.getElementById('premium-work-list');
      const align = document.getElementById('cat-source-align');
      return location.search === '?import=1' && meta && meta.getAttribute('content') === '1' &&
        document.body.classList.contains('premium-mode-import') && past && past.getAttribute('href') === '/cat?import=1' &&
        start && start.hidden && work && work.hidden && align && !align.hidden;
    }, null, { timeout: 20000 });
    let importRuntimeState = await importRuntimePage.evaluate(() => ({
      search: location.search,
      importMeta: document.querySelector('meta[name="yaku-import"]').getAttribute('content'),
      alignVisible: !document.getElementById('cat-source-align').hidden,
      activePast: document.querySelector('[data-premium-nav="past"]').classList.contains('is-active'),
      pastHref: document.querySelector('[data-premium-nav="past"]').getAttribute('href'),
      excelStartHidden: document.getElementById('premium-cat-start').hidden,
      workListHidden: document.getElementById('premium-work-list').hidden,
      importMode: document.body.classList.contains('premium-mode-import')
    }));
    assert.deepStrictEqual(importRuntimeState, { search: '?import=1', importMeta: '1', alignVisible: true, activePast: true, pastHref: '/cat?import=1', excelStartHidden: true, workListHidden: true, importMode: true }, JSON.stringify(importRuntimeState));
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
      assert.ok(paletteState.booting === false && paletteState.title === '\u30c1\u30e3\u30c3\u30c8\u7ffb\u8a33 - YakuLingo' && paletteState.heading === '\u30c1\u30e3\u30c3\u30c8\u7ffb\u8a33' && paletteState.description.includes('\u6587\u7ae0\u3092\u8cbc\u3063\u3066\u3059\u3050\u8a33') && paletteState.minFont >= 14 && paletteState.inputFont >= 18 && paletteState.actionFontFloor >= 14 && paletteState.actionMinHeight >= 44 && paletteState.bodyFont >= 17 && paletteState.overflow === false, JSON.stringify(paletteState));
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
