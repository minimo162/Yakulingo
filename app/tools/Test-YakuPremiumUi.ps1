Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
$htmlPath = Join-Path $appRoot 'www\cat.html'
$jsPath = Join-Path $appRoot 'www\assets\premium-ui.js'
$cssPath = Join-Path $appRoot 'www\assets\premium-ui.css'
$designPath = Join-Path $appRoot 'DESIGN.md'

$html = [IO.File]::ReadAllText($htmlPath)
$js = [IO.File]::ReadAllText($jsPath)
$css = [IO.File]::ReadAllText($cssPath)
$design = [IO.File]::ReadAllText($designPath)

function Assert-YakuUi {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

# The Excel route owns one clear start action. Text translation remains a
# separate route and must not be mounted into cat.html.
Assert-YakuUi ($html -match '<h1 id="premium-start-title">Excelを翻訳</h1>') 'PREMIUM_UI_EXCEL_START_MISSING'
Assert-YakuUi ($html -match 'Excelファイルをここにドロップ') 'PREMIUM_UI_EXCEL_DROP_MISSING'
Assert-YakuUi (([regex]::Matches($html, 'id="premium-file-input"')).Count -eq 1) 'PREMIUM_UI_EXCEL_INPUT_NOT_UNIQUE'
Assert-YakuUi ($html -notmatch '/assets/(palette|quick)\.(js|css)') 'PREMIUM_UI_RETIRED_ASSET_EMBEDDED'
Assert-YakuUi ($html -notmatch '文章もExcelも、ひとつの画面で') 'PREMIUM_UI_COMBINED_START_REINTRODUCED'

# The final structure is explicit in HTML: one cell list and one selected-cell
# editor. JavaScript binds state and actions but does not reconstruct the page.
foreach ($id in @('premium-app','premium-topbar','premium-cat-start','premium-cell-list-pane','premium-cell-list','premium-editor-intro','premium-row-actions','premium-export')) {
    Assert-YakuUi ($html -match ('id="' + [regex]::Escape($id) + '"')) ('PREMIUM_UI_STATIC_DOM_MISSING_' + $id)
}
foreach ($filter in @('untranslated','review','all')) {
    Assert-YakuUi ($html -match ('data-premium-filter="' + $filter + '"')) ('PREMIUM_UI_FILTER_MISSING_' + $filter)
}
Assert-YakuUi ($js -notmatch '3ステップで仕上げる') 'PREMIUM_UI_STAGE_NAV_REINTRODUCED'
Assert-YakuUi ($js -notmatch '確認するセル') 'PREMIUM_UI_DUPLICATE_LIST_REINTRODUCED'
Assert-YakuUi ($js -notmatch "create\('section', 'premium-cat-start'\)") 'PREMIUM_UI_START_RECONSTRUCTION_REINTRODUCED'
Assert-YakuUi ($html -match 'id="premium-apply-summary"') 'PREMIUM_UI_REAPPLY_SUMMARY_MISSING'
Assert-YakuUi ($html -match 'id="premium-unresolved-count"') 'PREMIUM_UI_UNRESOLVED_SUMMARY_MISSING'
Assert-YakuUi ($html -match 'id="cat-export"') 'PREMIUM_UI_EXPORT_MISSING'

# Responsive and disclosure contracts.
Assert-YakuUi ($css -match '@media \(max-width: 1260px\)') 'PREMIUM_UI_1200_CONTRACT_MISSING'
Assert-YakuUi (($html + $js + $css) -notmatch '(cat-preview-dialog|cat-inspector|cat-placement|cat-publication|premium-fit)') 'PREMIUM_UI_RETIRED_EXCEL_SURFACE_PRESENT'
Assert-YakuUi ($design -match 'deterministic confirmed-bilingual reapply') 'PREMIUM_UI_LIMITED_EXCEL_INTENT_MISSING'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source (Join-Path $toolsRoot 'Test-YakuV9213ExcelFirstUi.mjs')
    if ($LASTEXITCODE -ne 0) { throw ('PREMIUM_UI_NODE_CONTRACT_FAILED exit=' + $LASTEXITCODE) }
}

Write-Host 'ok - limited premium Excel UI'
