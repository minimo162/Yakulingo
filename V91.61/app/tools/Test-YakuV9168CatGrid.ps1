<#
.SYNOPSIS
  CAT の表が「その場で直せる格子」であり続けることを確かめる。

.DESCRIPTION
  2026-08-12 まで、訳文を直すには行を押して開く必要があり、開いた行だけ上下2段の
  カードに化けていた。実測（1380x900）で開いた行は 124〜147px、閉じた行は 76px で、
  1画面に 4〜8 行しか出ていなかった。市販の CAT（memoQ・Trados・Phrase）はどれも
  表の形を保ったまま訳文セルをその場で直す。ここで固定するのは字面ではなく、その
  作りである。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuGrid {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

$catJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat.js') -Raw -Encoding UTF8
$catCss = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat-workspace.css') -Raw -Encoding UTF8

Write-Host 'CAT grid stays an in-place editable table' -ForegroundColor Cyan

# 訳文欄は行の作りの一部であって、開いた行だけの持ち物ではない。
Check-YakuGrid ($catJs -match "var editor = '<textarea") '訳文欄は全行ぶん組み立てる'
Check-YakuGrid ($catJs -notmatch 'cat-row-activate') '行を開くための押しボタンは無い'
Check-YakuGrid ($catJs -notmatch 'data-cat-activate') '押して開く経路は残っていない'
Check-YakuGrid ($catJs -notmatch 'cat-target-preview') '訳文の見本表示は無い（欄そのものを出す）'

# 開いている行と閉じている行で、列の並びが変わらない。
Check-YakuGrid ($catJs -notmatch 'colspan="2"') '開いた行だけ列をまたぐ作りではない'
Check-YakuGrid ($catJs -notmatch 'cat-work-source|cat-work-target') '上下2段のカードは残っていない'
Check-YakuGrid ($catCss -notmatch '\.cat-work[-\s{,]') 'CSS 側にも上下2段の残骸が無い'

# 入った行が、開いている行になる。
Check-YakuGrid ($catJs -match "addEventListener\('focusin'") '訳文欄に入ることが行を開く操作である'
Check-YakuGrid ($catJs -match 'setSelectionRange\(caret, caret\)') '行を作り直してもカーソルの位置を戻す'
Check-YakuGrid ($catJs -match "closest\('td\.cat-source'\)") '原文側を押しても同じ行の訳文欄へ入る'

# 一望性。閉じている行は詰める。
Check-YakuGrid ($catCss -match 'tr:not\(\.is-active\) textarea\[data-cat-input\]') '閉じている行の訳文欄には上限がある'
Check-YakuGrid ($catCss -match 'tr:not\(\.is-active\) \.cat-location-kind \{ display: none; \}') '閉じている行では種類を出さない'
Check-YakuGrid ($catCss -match 'tr:not\(\.is-active\) \.cat-col-no') '閉じている行では行番号と状態を1行に収める'

# 確認と操作は、開いている行にだけ出す（閉じた行に並べると表が読めなくなる）。
Check-YakuGrid ($catJs -match "var extras = !isActive \? '' :") '操作と点検結果は開いている行だけに出す'

# 幅は主役（原文と訳文）へ回す。左に絞り込みの列を常時立てない。
$catHtml = Get-Content -LiteralPath (Join-Path $root 'www\cat.html') -Raw -Encoding UTF8
Check-YakuGrid ($catHtml -notmatch 'id="cat-nav-pane"') '左の絞り込み列は無い'
Check-YakuGrid ($catHtml -match 'class="cat-toolbar-filters"') '絞り込みは表の上の帯にある'
Check-YakuGrid ($catHtml -match 'id="cat-location-menu"' -and $catHtml -match 'id="cat-change-filter"[^>]*hidden') '場所と前回からの変更は、押したときだけ開く'
Check-YakuGrid ($catHtml -match 'id="cat-inspector-toggle"') '右の参考情報は畳める'
Check-YakuGrid ($catJs -match "localStorage.setItem\('yaku-cat-inspector-hidden'") '畳んだかどうかを次回も引き継ぐ'
Check-YakuGrid ($catCss -match '\.cat-editor-layout\.is-inspector-hidden \{ grid-template-columns: minmax\(0, 1fr\); \}') '畳んだ分の幅は一覧が使う'

if ($script:failed -gt 0) { Write-Host ('CAT grid tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'CAT grid tests passed.' -ForegroundColor Green
