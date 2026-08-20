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

Assert-YakuPremiumContains $css 'body\.premium-cat #cat-workspace' 'PREMIUM_UI_CAT_WORKSPACE_STYLE_MISSING'
Assert-YakuPremiumContains $css 'body\.premium-palette \.premium-quick-layout' 'PREMIUM_UI_QUICK_WORKSPACE_STYLE_MISSING'
Assert-YakuPremiumContains $css '--premium-brand:\s*#1b3a60' 'PREMIUM_UI_COLOR_TOKEN_MISSING'
Assert-YakuPremiumContains $css 'Segoe UI Variable Text' 'PREMIUM_UI_FONT_STACK_MISSING'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { throw 'PREMIUM_UI_NODE_NOT_FOUND' }
& $node.Source --check (Join-Path $Root 'www\assets\premium-ui.js')
if ($LASTEXITCODE -ne 0) { throw 'PREMIUM_UI_JAVASCRIPT_SYNTAX_FAILED' }

Write-Host 'Premium specialized UI contract passed.' -ForegroundColor Green
