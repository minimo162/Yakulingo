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
$js = Read-YakuPremiumText 'www\assets\premium-ui.js'
$css = Read-YakuPremiumText 'www\assets\premium-ui.css'

foreach ($html in @($cat, $palette)) {
    Assert-YakuPremiumCount $html '/assets/premium-ui.css' 1 'PREMIUM_UI_CSS_REFERENCE_INVALID'
    Assert-YakuPremiumCount $html '/assets/premium-ui.js' 1 'PREMIUM_UI_JS_REFERENCE_INVALID'
}
Assert-YakuPremiumContains $cat '<title>Excel翻訳 - YakuLingo</title>' 'PREMIUM_UI_CAT_TITLE_MISSING'
Assert-YakuPremiumContains $palette '<title>クイック翻訳 - YakuLingo</title>' 'PREMIUM_UI_QUICK_TITLE_MISSING'

foreach ($id in @('cat-picker','cat-workspace','cat-grid-body','cat-preview-dock','cat-export','cat-translate','cat-qa-open')) {
    Assert-YakuPremiumContains $cat ('id=["'']' + [regex]::Escape($id) + '["'']') ('PREMIUM_UI_CAT_CONTRACT_MISSING: ' + $id)
}
foreach ($id in @('palette-form','palette-input','palette-direction-select','palette-handoff','palette-context-select','palette-result')) {
    Assert-YakuPremiumContains $palette ('id=["'']' + [regex]::Escape($id) + '["'']') ('PREMIUM_UI_PALETTE_CONTRACT_MISSING: ' + $id)
}

foreach ($label in @('Excel翻訳','クイック翻訳','作業一覧','セル幅に合わせる','1文ずつすぐに','保存済みの作業')) {
    Assert-YakuPremiumContains $js ([regex]::Escape($label)) ('PREMIUM_UI_NAV_LABEL_MISSING: ' + $label)
}
if ($js -match '枠に収める|サクッと翻訳') { throw 'PREMIUM_UI_REJECTED_NAV_LABEL_REINTRODUCED' }
if ($js -match 'カジュアル') { throw 'PREMIUM_UI_UNSUPPORTED_TONE_EXPOSED' }
Assert-YakuPremiumContains $js 'data-length=.brief' 'PREMIUM_UI_BRIEF_MODE_MISSING'
Assert-YakuPremiumContains $js 'data-tone=.polite' 'PREMIUM_UI_POLITE_MODE_MISSING'
Assert-YakuPremiumContains $js "form\.addEventListener\('submit'" 'PREMIUM_UI_QUICK_SUBMIT_DELEGATION_MISSING'
Assert-YakuPremiumContains $js 'palette-result' 'PREMIUM_UI_QUICK_RESULT_WIRING_MISSING'
Assert-YakuPremiumContains $js '/api/cat/open' 'PREMIUM_UI_EXCEL_OPEN_WIRING_MISSING'
Assert-YakuPremiumContains $js '/api/cat/recent' 'PREMIUM_UI_RECENT_WIRING_MISSING'
Assert-YakuPremiumContains $js 'data-cat-fit-candidates|cat-fit-risk-badge' 'PREMIUM_UI_FIT_FOCUS_MISSING'
Assert-YakuPremiumContains $js "(?s)\[el\('cat-grid-body'\), el\('cat-editor-toolbar'\)\]\.forEach" 'PREMIUM_UI_TARGETED_OBSERVERS_MISSING'
if ($js -match "MutationObserver\(refresh\)\.observe\(workspace") { throw 'PREMIUM_UI_BROAD_WORKSPACE_OBSERVER_REINTRODUCED' }
Assert-YakuPremiumContains $js '#cat-editor-toolbar,#premium-tools,#premium-settings' 'PREMIUM_UI_SETTINGS_DISMISS_GUARD_MISSING'
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
Assert-YakuPremiumContains $css '--premium-brand:\s*#1b3a60' 'PREMIUM_UI_COLOR_TOKEN_MISSING'
Assert-YakuPremiumContains $css 'Segoe UI Variable Text' 'PREMIUM_UI_FONT_STACK_MISSING'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { throw 'PREMIUM_UI_NODE_NOT_FOUND' }
& $node.Source --check (Join-Path $Root 'www\assets\premium-ui.js')
if ($LASTEXITCODE -ne 0) { throw 'PREMIUM_UI_JAVASCRIPT_SYNTAX_FAILED' }

$harness = @'
const assert = require('assert');
const http = require('http');
const { chromium } = require('playwright');

const premiumPath = process.argv[2];
if (!premiumPath) throw new Error('PREMIUM_UI_BROWSER_SCRIPT_PATH_MISSING');

(async () => {
  const server = http.createServer((request, response) => {
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
      const page = await browser.newPage();
      const pageErrors = [];
      page.on('pageerror', error => pageErrors.push(error.message));
      await page.goto(baseUrl + '/cat?project=project-old');
    await page.setContent(`<!doctype html><html><head><title>test</title></head><body class="app-cat" data-cat-view="workspace">
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
    await page.waitForSelector('#premium-settings');
    await page.waitForSelector('#premium-fit-list .premium-fit-row');

    let state = await page.evaluate(() => ({
      settingsControls: document.getElementById('premium-settings').getAttribute('aria-controls'),
      settingsExpanded: document.getElementById('premium-settings').getAttribute('aria-expanded'),
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded')
    }));
    assert.deepStrictEqual(state, { settingsControls: 'cat-editor-toolbar', settingsExpanded: 'false', toolsControls: 'cat-editor-toolbar', toolsExpanded: 'false' }, JSON.stringify(state));

    await page.locator('#premium-settings').evaluate(node => node.click());
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      settingsControls: document.getElementById('premium-settings').getAttribute('aria-controls'),
      settingsExpanded: document.getElementById('premium-settings').getAttribute('aria-expanded'),
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: true, settingsControls: 'cat-editor-toolbar', settingsExpanded: 'true', toolsControls: 'cat-editor-toolbar', toolsExpanded: 'true', active: 'tool-first' }, JSON.stringify(state));

    await page.evaluate(() => document.body.dispatchEvent(new MouseEvent('click', { bubbles: true })));
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      settingsControls: document.getElementById('premium-settings').getAttribute('aria-controls'),
      settingsExpanded: document.getElementById('premium-settings').getAttribute('aria-expanded'),
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: false, settingsControls: 'cat-editor-toolbar', settingsExpanded: 'false', toolsControls: 'cat-editor-toolbar', toolsExpanded: 'false', active: 'premium-settings' }, JSON.stringify(state));

    await page.locator('#premium-tools').evaluate(node => node.click());
    await page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    state = await page.evaluate(() => ({
      open: document.body.classList.contains('premium-tools-open'),
      active: document.activeElement && document.activeElement.id
    }));
    assert.deepStrictEqual(state, { open: false, active: 'premium-tools' }, JSON.stringify(state));

    await page.locator('#premium-settings').evaluate(node => node.click());
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

    await page.setContent(`<!doctype html><html><head><title>palette-test</title></head><body class="app-palette">
      <main class="palette-shell"><div class="palette-main">
        <form id="palette-form"><textarea id="palette-input"></textarea><div class="palette-direction-row"><select id="palette-direction-select"><option value="">auto</option></select></div></form>
        <div id="palette-instant"></div><div id="palette-chips" hidden></div><div id="palette-result"></div>
      </div></main>
    </body></html>`);
    await page.addScriptTag({ path: premiumPath });
    await page.waitForSelector('#premium-settings');
    await page.waitForSelector('#premium-tools', { state: 'attached' });
    state = await page.evaluate(() => ({
      settingsControls: document.getElementById('premium-settings').getAttribute('aria-controls'),
      settingsExpanded: document.getElementById('premium-settings').getAttribute('aria-expanded'),
      toolsControls: document.getElementById('premium-tools').getAttribute('aria-controls'),
      toolsExpanded: document.getElementById('premium-tools').getAttribute('aria-expanded')
    }));
    assert.deepStrictEqual(state, { settingsControls: null, settingsExpanded: null, toolsControls: null, toolsExpanded: null }, JSON.stringify(state));

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
$harnessOutput = $harness | & $node.Source - (Join-Path $Root 'www\assets\premium-ui.js') 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ('PREMIUM_UI_BROWSER_HARNESS_FAILED: ' + (@($harnessOutput) -join ' '))
}
foreach ($line in @($harnessOutput)) { Write-Host $line }

Write-Host 'Premium specialized UI contract passed.' -ForegroundColor Green
