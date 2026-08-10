<#
.SYNOPSIS
  Verifies the first-run tutorial and desktop preference UX contract.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]
$checks = 0

function Check-YakuTutorial {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures.Add($Message) | Out-Null }
}

function Read-YakuTutorialFile {
    param([string]$RelativePath)
    $path = Join-Path $root $RelativePath
    Check-YakuTutorial (Test-Path -LiteralPath $path -PathType Leaf) "$RelativePath exists"
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($path)
}

$html = Read-YakuTutorialFile 'www\tutorial.html'
$js = Read-YakuTutorialFile 'www\assets\tutorial.js'
$css = Read-YakuTutorialFile 'www\assets\tutorial.css'
$homeHtml = Read-YakuTutorialFile 'www\index.html'
$homeJs = Read-YakuTutorialFile 'www\assets\home.js'
$commonJs = Read-YakuTutorialFile 'www\assets\common.js'

Check-YakuTutorial ([regex]::Matches($html, 'class="tutorial-step"').Count -eq 4) 'tutorial has exactly four stages'
Check-YakuTutorial ($html.Contains('1 / 4') -and $js.Contains("String(currentStep + 1) + ' / 4'")) 'tutorial exposes progress in text'
Check-YakuTutorial ($html.Contains('設定画面へ進む') -and -not $html.Contains('>スキップ<')) 'skip action leads explicitly to settings'
Check-YakuTutorial ($html.Contains('文章は自動では読み取りません') -and $html.Contains('貼り付けて「翻訳」を押すまで')) 'tutorial states the no-monitoring and explicit-send boundary'
Check-YakuTutorial ($html -match 'id="startup-enabled"[^>]*type="checkbox"[^>]*checked') 'startup is visibly ON by default'
Check-YakuTutorial ($html -match 'id="desktop-shortcut"[^>]*type="checkbox"[^>]*checked') 'desktop shortcut is visibly ON by default'
Check-YakuTutorial ($html.Contains('それまではパソコンの設定を変更しません') -and $html.Contains('この設定で始める')) 'final confirmation explains the side-effect boundary'
Check-YakuTutorial ($html.Contains('tabindex="-1"') -and $html.Contains('aria-live="polite"') -and $html.Contains('aria-label="使い方の画面移動"')) 'focus and live-region semantics are present'

Check-YakuTutorial ([regex]::Matches($js, [regex]::Escape("YakuCommon.post('/api/desktop/preferences'")).Count -eq 1) 'desktop preferences have one POST call site'
Check-YakuTutorial ($js.Contains("form.addEventListener('submit', applyPreferences)") -and -not ($js -match '(?m)^\s*applyPreferences\(\);')) 'preference POST is bound only to form confirmation'
Check-YakuTutorial ($js.Contains('startup_enabled: !!startupInput.checked') -and $js.Contains('desktop_shortcut: !!desktopInput.checked')) 'POST carries both explicit checkbox values'
Check-YakuTutorial ($js.Contains("YakuCommon.json('/api/desktop/preferences')")) 'existing preferences are read without changing them'
Check-YakuTutorial ($js.Contains("data.tutorial_completed !== true")) 'first run retains the visibly ON defaults until the tutorial has been confirmed'
Check-YakuTutorial (-not ($js -match 'clipboard|execCommand|localStorage|sessionStorage')) 'tutorial neither reads clipboard nor persists text in browser storage'
Check-YakuTutorial ($js.Contains('data.message') -and $js.Contains('data.warnings') -and $js.Contains('data.available')) 'server response, warnings, and availability are surfaced'
Check-YakuTutorial ($js.Contains("YakuCommon.notifyDesktopShell('desktop-preferences-changed')") -and
    -not ($js -match 'chrome\.webview\.postMessage')) 'successful tutorial save uses the shared metadata-only shell notifier'

Check-YakuTutorial ($css.Contains('min-height: 48px') -and $css.Contains('width: 26px') -and $css.Contains('height: 26px')) 'interactive controls remain large enough to target'
Check-YakuTutorial ($css.Contains('@media (max-width: 640px)') -and $css.Contains('@media (prefers-reduced-motion: reduce)')) 'narrow and reduced-motion layouts are defined'
Check-YakuTutorial ($css.Contains('font-size: clamp(2rem') -and $css.Contains('font-size: 1.25rem')) 'headings and instructional text remain readable at high zoom'

Check-YakuTutorial ($homeHtml.Contains('起動とショートカット') -and $homeHtml.Contains('使い方を見る') -and $homeHtml.Contains('/tutorial#settings')) 'home exposes help and direct preference routes'
Check-YakuTutorial ($homeHtml.Contains('id="background-disabled-banner"') -and $homeJs.Contains("data.tutorial_completed === true") -and $homeJs.Contains("data.startup_enabled === false")) 'home explains disabled startup only after first-run confirmation'
# 開始画面は状態を変えない。読み取り専用の一覧取得（/api/cat/recent）だけを許し、
# それ以外の POST（とくに起動設定の書き換え）は今までどおり禁止する。
$homePostTargets = @([regex]::Matches($homeJs, "YakuCommon\.post\('([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Check-YakuTutorial ($homeJs.Contains("YakuCommon.json('/api/desktop/preferences')") -and (@($homePostTargets | Where-Object { $_ -ne '/api/cat/recent' }).Count -eq 0)) 'home checks preferences without changing them'

Check-YakuTutorial ($commonJs.Contains("data.type !== 'set-startup-enabled'") -and
    $commonJs.Contains("typeof data.enabled !== 'boolean'") -and $commonJs.Contains("keys !== 'enabled,type'")) 'shell handler accepts only the exact startup-toggle message contract'
Check-YakuTutorial ($commonJs.Contains("json('/api/desktop/preferences')") -and
    $commonJs.Contains('desktop_shortcut: current.desktop_shortcut') -and
    $commonJs.Contains('startup_enabled: enabled')) 'shell toggle preserves the current desktop shortcut value'
Check-YakuTutorial ($commonJs.Contains("notifyDesktopShell('desktop-preferences-changed')") -and
    $commonJs.Contains("notifyDesktopShell('desktop-preferences-error')")) 'shell receives metadata-only success or failure events'
Check-YakuTutorial ($commonJs.Contains("type !== 'desktop-preferences-changed' && type !== 'desktop-preferences-error'") -and
    $commonJs.Contains('postMessage({ type: type })')) 'outbound WebMessage is restricted to an allowlisted type with no settings or token'
Check-YakuTutorial ($commonJs.Contains('desktopPreferenceMessageQueue.then')) 'rapid tray changes are serialized in arrival order'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source '--check' (Join-Path $root 'www\assets\tutorial.js')
    Check-YakuTutorial ($LASTEXITCODE -eq 0) 'tutorial JavaScript parses with node --check'
} else {
    Write-Host 'SKIP: node is unavailable; JavaScript syntax check not run.' -ForegroundColor Yellow
}

if ($failures.Count -gt 0) {
    Write-Host "Tutorial regression failed: $($failures.Count) / $checks" -ForegroundColor Red
    exit 1
}
Write-Host "Tutorial regression passed: $checks checks" -ForegroundColor Cyan
