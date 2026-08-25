#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$appRoot = Split-Path -Parent $PSScriptRoot
$quickPath = Join-Path $appRoot 'www\quick.html'
$catPath = Join-Path $appRoot 'www\cat.html'
$premiumJsPath = Join-Path $appRoot 'www\assets\premium-ui.js'
$serverPath = Join-Path $appRoot 'src\Server.ps1'

function Assert-YakuContract {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$quick = [IO.File]::ReadAllText($quickPath)
$cat = [IO.File]::ReadAllText($catPath)
$premiumJs = [IO.File]::ReadAllText($premiumJsPath)
$server = [IO.File]::ReadAllText($serverPath)

foreach ($page in @($quick, $cat)) {
    Assert-YakuContract ($page -match '<nav class="translation-mode-nav" aria-label="翻訳モード">') 'Shared translation mode navigation is missing.'
    Assert-YakuContract ($page -match '<a href="/quick"') 'The text translation target is missing.'
    Assert-YakuContract ($page -match '<a href="/cat"') 'The Excel translation target is missing.'
    Assert-YakuContract ($page -match '/assets/translation-mode-nav\.css') 'The shared navigation stylesheet is missing.'
}

Assert-YakuContract ($quick -match '<a href="/quick" aria-current="page">テキスト翻訳</a>') 'The quick page does not expose its current mode.'
Assert-YakuContract ($cat -match '<a href="/cat" aria-current="page">Excel翻訳</a>') 'The CAT page does not expose its current mode.'

$buildStart = $premiumJs.IndexOf('function buildTopbar()')
$buildEnd = $premiumJs.IndexOf('function setTopbar(', $buildStart)
Assert-YakuContract ($buildStart -ge 0 -and $buildEnd -gt $buildStart) 'buildTopbar could not be inspected.'
$fallbackTopbar = $premiumJs.Substring($buildStart, $buildEnd - $buildStart)
Assert-YakuContract ($fallbackTopbar -match "topbar\.id = 'premium-topbar'") 'The rebuilt top bar loses the static top bar identity.'
$previousIndex = -1
foreach ($marker in @('premium-top-brand', 'premium-topbar-left', 'translation-mode-nav', 'premium-copilot-slot', 'premium-top-actions')) {
    $markerIndex = $fallbackTopbar.IndexOf($marker)
    Assert-YakuContract ($markerIndex -gt $previousIndex) ('The rebuilt top bar structure is missing or out of order: ' + $marker)
    $previousIndex = $markerIndex
}
Assert-YakuContract ($fallbackTopbar -match 'href="/quick"') 'The rebuilt top bar cannot open text translation.'
Assert-YakuContract ($fallbackTopbar -match 'href="/cat"') 'The rebuilt top bar cannot open Excel translation.'

Assert-YakuContract ($server -match '\$path -in @\(''/'', ''/quick'', ''/palette''\)') 'The /quick route is not connected to the app page.'
Assert-YakuContract ($server -match '\$path -eq ''/cat''') 'The /cat route is not connected to the app page.'

Write-Host 'ok - translation mode navigation and top bar structure remain connected'
