<#
.SYNOPSIS
  V91.61: 続いているセルを繋いで訳し、元のセルへ戻す仕組みの回帰テスト。

.DESCRIPTION
  ファイル翻訳の精度が低い原因は、用語集でもプロンプトでもなく入力の
  切り方にある（利用者の診断 2026-08-06）。体裁のために1つの長い文を
  複数のセルへ分けて入力しているため、セルごとに訳すと文の途中で切れた
  断片をそれぞれ訳すことになり、訳が崩壊する。しかも出来上がった Excel は
  一見良さげに見えるので、崩壊に気づけず修正作業が増える。

  ここで確かめるのは2つ。
   - 繋ぐべきものを繋ぎ、**繋いではいけないものを繋がない**
   - 訳文を元のセルへ、語を割らずに戻せる

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CellSegments.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'CellSegments.ps1')
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }
function C { param([int]$r,[int]$col,[string]$t,[bool]$isText=$true) New-YakuSegmentCell -Row $r -Column $col -Text $t -IsText $isText }
# 先頭のカンマで配列のまま返す。1件だと中身が剥き出しになり .Count が取れない。
function Segs { param([object[]]$Cells) return ,@(Group-YakuCellsIntoSegments -Cells $Cells) }

# ---------------------------------------------------------------- 繋ぐ
Write-Host '同じ列に続けて置かれた文を繋ぐ'
# 体裁のために3行へ割った1つの文。セルごとに訳すと崩壊する形。
$split = @(
    (C 1 1 '当社は、生産体制の見直しと')
    (C 2 1 '調達費の削減を通じて、')
    (C 3 1 '固定費の圧縮を進めております。')
)
$s = Segs $split
Chk ($s.Count -eq 1) ('3行が1セグメントになる: ' + $s.Count)
Chk ([bool]$s[0].Joined) '繋いだことが分かる'
Chk ([string]$s[0].Text -eq '当社は、生産体制の見直しと調達費の削減を通じて、固定費の圧縮を進めております。') '日本語は詰めて繋ぐ'
Chk (@($s[0].Cells).Count -eq 3) '元のセルを保持する'

Write-Host '英語は空白で繋ぐ'
$en = @((C 1 1 'The Company continued to reduce'), (C 2 1 'fixed costs during the period.'))
$se = Segs $en
Chk ($se.Count -eq 1) '2行が1セグメントになる'
Chk ([string]$se[0].Text -eq 'The Company continued to reduce fixed costs during the period.') '英語は空白で繋ぐ'

# ---------------------------------------------------------------- 繋がない（本題）
Write-Host '繋いではいけないもの'
# 句点で閉じていれば、そこで文が終わっている。
$closed = @((C 1 1 '生産は堅調に推移しました。'), (C 2 1 '販売も計画を上回りました。'))
Chk ((Segs $closed).Count -eq 2) '句点で閉じていれば繋がない'
# 閉じ括弧が後ろに付く場合も、句点で閉じている。
$quoted = @((C 1 1 '社長は「連携が不可欠だ」と述べました。'), (C 2 1 '今後も推進します。'))
Chk ((Segs $quoted).Count -eq 2) '閉じ括弧の付いた句点も文末とみなす'
# 同じ行に他の値があれば、それは表の行であって文章ではない。
$tableRow = @((C 1 1 '営業利益'), (C 1 2 '1,234'), (C 2 1 '経常利益'), (C 2 2 '2,345'))
$st = Segs $tableRow
Chk ($st.Count -eq 4) ('表の行は繋がない: ' + $st.Count)
Chk (@($st | Where-Object { [bool]$_.Joined }).Count -eq 0) '表の行はどれも繋がっていない'
# 行が飛んでいれば別の塊。
$gap = @((C 1 1 '当社は生産体制の見直しと'), (C 5 1 '調達費の削減を進めます。'))
Chk ((Segs $gap).Count -eq 2) '行が飛んでいれば繋がない'
# 列が違えば別の塊。
$col = @((C 1 1 '当社は生産体制の見直しと'), (C 2 2 '調達費の削減を進めます。'))
Chk ((Segs $col).Count -eq 2) '列が違えば繋がない'
# 箇条書きは、前の行が閉じていなくても別の項目。
$bullet = @((C 1 1 '主な施策は次のとおり'), (C 2 1 '・生産体制の見直し'), (C 3 1 '・調達費の削減'))
$sb = Segs $bullet
Chk ($sb.Count -eq 3) ('箇条書きは繋がない: ' + $sb.Count)
# 番号付きも同じ。
$numbered = @((C 1 1 '主な施策'), (C 2 1 '1. 生産体制の見直し'), (C 3 1 '2. 調達費の削減'))
Chk ((Segs $numbered).Count -eq 3) '番号付きも繋がない'
# 数値セルは繋がない。
$num = @((C 1 1 '固定費の削減を進めており'), (C 2 1 '1,234' $false))
Chk ((Segs $num).Count -eq 2) '数値セルは繋がない'
# 歯止め。判定を外してもシート全体が1つにならないこと。
$many = @(1..30 | ForEach-Object { C $_ 1 ('継続的に改善を進めており' + $_) })
$sm = Segs $many
Chk ($sm.Count -ge 3) ('繋ぎすぎない歯止めが効く: ' + $sm.Count + ' セグメント')
Chk ((@($sm | ForEach-Object { @($_.Cells).Count } | Measure-Object -Maximum).Maximum) -le 12) '1セグメントの上限を超えない'

# ---------------------------------------------------------------- 戻す
Write-Host '訳文を元のセルへ戻す'
$parts = @(Split-YakuTextAcrossCells -Text 'The Company is reducing fixed costs through production review and lower procurement costs.' -Weights @(14, 12, 15))
Chk ($parts.Count -eq 3) ('セルの数だけ返る: ' + $parts.Count)
Chk ((($parts -join ' ') -replace '\s+', ' ') -eq 'The Company is reducing fixed costs through production review and lower procurement costs.') '繋ぎ直すと元の訳文に戻る'
Chk ((@($parts | Where-Object { $_ -match '^\s|\s$' }).Count) -eq 0) '前後に空白が残らない'
# 語の途中で切らないこと。切ると読めなくなる。
$allWords = @('The','Company','is','reducing','fixed','costs','through','production','review','and','lower','procurement','costs.')
$got = @((($parts -join ' ') -split '\s+') | Where-Object { $_ })
Chk ((@($got | Where-Object { $allWords -notcontains $_ }).Count) -eq 0) '語を割らずに切る'

Write-Host '重みで割り振る'
# 元のセルが長いほど多くを受け持つ。元の長さは見た目の幅を表している。
$w = @(Split-YakuTextAcrossCells -Text ('a' * 10 + ' ' + 'b' * 10 + ' ' + 'c' * 10) -Weights @(30, 3))
Chk ($w[0].Length -gt $w[1].Length) ('重い側が多くを受け持つ: ' + $w[0].Length + ' / ' + $w[1].Length)

Write-Host '端の場合'
Chk ((Split-YakuTextAcrossCells -Text 'x' -Weights @(5)).Count -eq 1) 'セル1つならそのまま'
$empty = @(Split-YakuTextAcrossCells -Text '' -Weights @(5,5,5))
Chk ($empty.Count -eq 3 -and (@($empty | Where-Object { $_ -ne '' }).Count -eq 0)) '訳文が空ならセルも空にする'
# 訳文が短くてセルが余っても、元の日本語を残さない。混ざった表になる。
$short = @(Split-YakuTextAcrossCells -Text 'Short.' -Weights @(20,20,20))
Chk ($short.Count -eq 3) '短くてもセルの数だけ返る'
Chk ((($short -join '').Trim()) -eq 'Short.') '中身は訳文だけで、元の文字が残らない'

# ---------------------------------------------------------------- 往復
Write-Host '繋いで訳して戻す（往復）'
$seg = (Segs $split)[0]
$back = @(Get-YakuSegmentWriteBack -Segment $seg -Translation 'The Company is reducing fixed costs through a review of production and lower procurement costs.')
Chk ($back.Count -eq 3) ('元の3セルへ戻る: ' + $back.Count)
Chk ([int]$back[0].Row -eq 1 -and [int]$back[2].Row -eq 3) '行と列は元のまま'
$rejoined = ((@($back | ForEach-Object { [string]$_.Text }) -join ' ') -replace '\s+', ' ').Trim()
Chk ($rejoined -eq 'The Company is reducing fixed costs through a review of production and lower procurement costs.') '繋ぎ直すと訳文に戻る'
# 繋いでいないセグメントは1対1のまま。
$single = (Segs @((C 1 1 '営業利益')))[0]
$one = @(Get-YakuSegmentWriteBack -Segment $single -Translation 'Operating profit')
Chk ($one.Count -eq 1 -and [string]$one[0].Text -eq 'Operating profit') '繋いでいないセグメントはそのまま1対1'

if ($script:fail -gt 0) {
    Write-Host "V91.61 cell segment regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 cell segment regression passed.' -ForegroundColor Green
