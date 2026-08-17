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

# 一致の度合いと差分。市販CATは率だけでなく「どこが違うか」を必ず出す。
# 率そのものは当アプリでは出さない（中身が Dice 係数で、翻訳者が「%」から読み取る
# 帯とは別の尺度だった。2026-08-15。表記の中身は Test-YakuV9175FuzzyMatchLabel.ps1）。
Check-YakuGrid ($catJs -match 'function diffMarkup\(') '過去訳の原文といまの原文の差分を作る'
Check-YakuGrid ($catJs -match 'cat-diff-ins') '違うところに印を付ける'
Check-YakuGrid ($catJs -match 'cat-cand-score') '一致の度合いをカードの先頭に出す'
Check-YakuGrid ($catJs -notmatch "'原文が ' \+ Math\.round") '一致の度合いを文章側で繰り返さない'
Check-YakuGrid ($catJs -match 'a\.length \* b\.length > 160000') '長すぎる文では差分をあきらめる（重くしない）'
Check-YakuGrid ($catJs -match 'diffHintShown') '差分の説明は最初の1枚だけに出す'
$styles = Get-Content -LiteralPath (Join-Path $root 'www\assets\styles.css') -Raw -Encoding UTF8
Check-YakuGrid ($styles -match '\.cat-diff-ins \{[^}]*font-weight: 700[^}]*text-decoration: underline') '差分の印は色だけに頼らない'
Check-YakuGrid ($styles -match '\.cat-cand-score\.is-exact') '完全一致は他と見分けが付く'

# 出す前の点検一覧。市販CAT（memoQ・Trados）は書き出し前にこの一覧から行へ飛ぶ。
Check-YakuGrid ($catHtml -match 'id="cat-qa-dialog"' -and $catHtml -match 'id="cat-qa-list"') '点検一覧の器がある'
Check-YakuGrid ($catHtml -match 'id="cat-qa-open"[^>]*class="secondary-button"') '点検一覧は畳んだ menu ではなく道具の帯から開ける'
Check-YakuGrid ($catJs -match 'function qaFindings\(') '指摘を資料ぜんぶから集める'
Check-YakuGrid ($catJs -match "key: 'empty'" -and $catJs -match "key: 'qc'" -and $catJs -match "key: 'unconfirmed'") '出力を止める2つと、止めない未確認を分けて数える'
Check-YakuGrid ($catJs -match 'data-cat-qa-jump') '一覧から行へ飛べる'
Check-YakuGrid ($catJs -match "function jumpFromQa[\s\S]{0,400}currentFilter = 'all'") '飛ぶ前に絞り込みを外す（隠れた行へ飛ばさない）'
Check-YakuGrid ($catJs -match "event.key === 'F8'") 'F8 で開く（Trados の検証キーに合わせる）'
Check-YakuGrid ($catJs -match 'function updateQaButton\(') '止まっている件数をボタンに出す'
Check-YakuGrid ($catJs -match "el\('cat-export'\)\.disabled = !project \|\| !!\(project && project\.export_blocked\)") '点検一覧を足しても、出力を止める条件は緩めない'

# 体裁で見る（Trados のプレビュー、memoQ の Preview に当たる）。
Check-YakuGrid ($catHtml -match 'id="cat-preview-dialog"' -and $catHtml -match 'id="cat-preview-open"') '体裁で見る画面がある'
Check-YakuGrid ($catJs -match 'function previewCellRef\(') 'Excel はセルの位置を場所から読む'
Check-YakuGrid ($catJs -match 'cat-preview-grid' -and $catJs -match 'cat-preview-flow') 'セルの格子と、段落の並びの両方を組む'
Check-YakuGrid ($catJs -match 'data-cat-preview-side') '訳文と原文を切り替えられる'
Check-YakuGrid ($catJs -match 'is-missing') '訳文が無いところは原文を薄く出す（空白にしない）'
# 開く経路は、必ず組み直しを通ってから出す。これを「openPreview から showModal まで
# 200 字以内」で代用していたが、それは作りではなく関数の長さを固定していた。#52 が
# openPreview へ PDF タブの出し入れを4行足した時点で 164 字→577 字になり破れた
# （2026-08-14）。しかも組み直しの呼び出し自体を要求していないので、renderPreview();
# を消しても緑のままだった（b040c4b の cat.js で実測）。本体を切り出し（末尾は2字下げ
# の閉じ括弧）、呼ぶ順序そのものを見る。
$openPreviewBody = ''
if ($catJs -match '(?s)function openPreview\(\) \{.*?\n  \}') { $openPreviewBody = $Matches[0] }
Check-YakuGrid ($openPreviewBody -match '(?s)renderPreview\(\);.*showModal') '開くときに組み直す'
Check-YakuGrid ($catJs -notmatch 'preview[\s\S]{0,40}fetch\(' ) 'プレビューのためにファイルを作らない・開かない'

if ($script:failed -gt 0) { Write-Host ('CAT grid tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'CAT grid tests passed.' -ForegroundColor Green
