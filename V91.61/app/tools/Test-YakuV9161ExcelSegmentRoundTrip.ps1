<#
.SYNOPSIS
  V91.61: Excel を読んでセグメントにし、元のコピーへ書き戻す往復の回帰テスト。

.DESCRIPTION
  ファイル翻訳は廃止し、CAT へ統合する（利用者の判断 2026-08-06）。
  「エクセルで読み込んだものを元のエクセルをコピーしたものに戻す機能」が
  要る、という指示に対応する経路である。

  抽出（Get-YakuExcelTextBlocks）と書き戻し（Write-YakuExcelTranslations）は
  既にある。新しいのはその間に挟むセグメント層だけで、ここではその往復が
  崩れないことを確かめる。土台が崩れていると、上に載せるものが全部
  信用できなくなる。

  いちばん見たいのは、**表の行を文章として繋がないこと**である。
  数値セルは抽出されないので、翻訳対象だけを数えると
  「営業利益 | 1,234」の行が単独に見え、次の行と繋いでしまう。
  実際のシートから行の埋まり具合を数えているかを確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161ExcelSegmentRoundTrip.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','FileProcessors.ps1','CellSegments.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

if (-not (Test-YakuExcelAvailable)) {
    Write-Host 'Excel が無いため飛ばす' -ForegroundColor Yellow
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-rt-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$srcPath = Join-Path $tmp 'in.xlsx'
$outPath = Join-Path $tmp 'out.xlsx'

# ------------------------------------------------------------------ 素材を作る
# 1〜3行目 … 体裁のために1つの文を3セルへ割ったもの（繋ぐべき）
# 5〜6行目 … 表の行。ラベルの隣に数値がある（繋いではいけない）
$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false; $xl.DisplayAlerts = $false
try {
    $wb = $xl.Workbooks.Add()
    $ws = $wb.Worksheets.Item(1); $ws.Name = '説明'
    $ws.Cells.Item(1,1).Value2 = '当第1四半期は、生産体制の見直しと調達費の削減により'
    $ws.Cells.Item(2,1).Value2 = '固定費を圧縮した一方、為替の影響を受けたことから'
    $ws.Cells.Item(3,1).Value2 = '営業利益は前年同期比で20億円の増益にとどまりました。'
    $ws.Cells.Item(5,1).Value2 = '営業利益'
    $ws.Cells.Item(5,2).Value2 = 1234
    $ws.Cells.Item(6,1).Value2 = '経常利益'
    $ws.Cells.Item(6,2).Value2 = 2345
    $wb.SaveAs($srcPath, 51); $wb.Close($false)
} finally {
    try { $xl.Quit() } catch {}
    Release-YakuComObject $xl
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

$settings = Read-YakuSettings -Root $root

# ------------------------------------------------------------------ 抽出とセグメント化
Write-Host '抽出してセグメントにする'
$extract = Get-YakuExcelTextBlocks -Path $srcPath -Direction 'to_en' -Settings $settings -Sheets $null
$blocks = @($extract.Blocks)
Chk ($blocks.Count -eq 5) ('文字の塊が5つ取れる（数値は対象外）: ' + $blocks.Count)

# 行の埋まり具合は実際のシートから数える。翻訳対象だけを数えると表の行が単独に見える。
$ctx = New-YakuExcelApplication
$occ = $null
try {
    $wbR = Open-YakuWorkbookWithManualCalc -Context $ctx -Path $srcPath -ReadOnly $true
    $occ = Get-YakuExcelRowOccupancy -Workbook $wbR
    try { $wbR.Close($false) | Out-Null } catch {}
    Release-YakuComObject $wbR
} finally {
    Close-YakuExcelObjects -Workbook $null -Application $ctx.Application `
        -OldScreenUpdating $ctx.OldScreenUpdating -OldEnableEvents $ctx.OldEnableEvents `
        -OldDisplayStatusBar $ctx.OldDisplayStatusBar -OldFormatConditionsCalc $ctx.OldFormatConditionsCalc `
        -OldBackgroundChecking $ctx.OldBackgroundChecking
}
Chk ($null -ne $occ -and $occ.ContainsKey('説明')) '行の埋まり具合が取れる'
Chk ([int]$occ['説明'][1] -eq 1) '1行目は単独（文章）'
Chk ([int]$occ['説明'][5] -eq 2) '5行目は2つ埋まっている（表の行）'

$segments = @(Group-YakuTextBlocksIntoSegments -Blocks $blocks -RowOccupancy $occ)
Chk ($segments.Count -eq 3) ('3セグメントになる（文章1＋表2）: ' + $segments.Count)
$joined = @($segments | Where-Object { [bool]$_.Joined })
Chk ($joined.Count -eq 1) ('繋がれたのは1つだけ: ' + $joined.Count)
Chk ([string]$joined[0].Text -eq '当第1四半期は、生産体制の見直しと調達費の削減により固定費を圧縮した一方、為替の影響を受けたことから営業利益は前年同期比で20億円の増益にとどまりました。') '文章が1つに繋がる'
Chk (@($joined[0].BlockIds).Count -eq 3) '元の3つの塊を覚えている'
# ここが本題。表の行は繋がないこと。
$tableSegs = @($segments | Where-Object { -not [bool]$_.Joined })
Chk ($tableSegs.Count -eq 2) '表のラベルは1つずつのまま'
Chk ((@($tableSegs | ForEach-Object { [string]$_.Text }) -contains '営業利益')) '営業利益 が単独のセグメント'
Chk ((@($tableSegs | ForEach-Object { [string]$_.Text }) -contains '経常利益')) '経常利益 が単独のセグメント'

# 行の埋まり具合を渡さないと、表の行を繋いでしまうことを示す。
# （数値セルが抽出されないため、翻訳対象だけでは行が単独に見える）
$naive = @(Group-YakuTextBlocksIntoSegments -Blocks $blocks -RowOccupancy $null)
Chk ($naive.Count -lt $segments.Count) ('渡さないと表の行まで繋いでしまう（' + $naive.Count + ' セグメント）')

# ------------------------------------------------------------------ 書き戻し
Write-Host '元のコピーへ書き戻す'
Copy-Item -LiteralPath $srcPath -Destination $outPath -Force
$translations = @{}
for ($i = 0; $i -lt $segments.Count; $i++) {
    $s = $segments[$i]
    if ([bool]$s.Joined) {
        $translations[$i] = 'In the first quarter under review, fixed costs were reduced through a review of production and lower procurement costs. However, due to foreign exchange, the increase in operating profit was limited to 20 oku.'
    } elseif ([string]$s.Text -eq '営業利益') { $translations[$i] = 'Operating profit' }
    elseif ([string]$s.Text -eq '経常利益') { $translations[$i] = 'Ordinary profit' }
}
$byBlock = Get-YakuSegmentTranslationByBlockId -Segments $segments -TranslationBySegmentIndex $translations
Chk ($byBlock.Count -eq 5) ('5つの塊すべてに訳文が割り戻る: ' + $byBlock.Count)

$warnings = New-Object System.Collections.Generic.List[object]
$null = Write-YakuExcelTranslations -OutputPath $outPath -Blocks $blocks -TranslationByBlockId $byBlock -Warnings $warnings -Settings $settings

# ------------------------------------------------------------------ 結果を読み返す
Write-Host '書き戻した結果を読み返す'
$xl2 = New-Object -ComObject Excel.Application
$xl2.Visible = $false; $xl2.DisplayAlerts = $false
$read = @{}
try {
    $wb2 = $xl2.Workbooks.Open($outPath, 0, $true)
    $ws2 = $wb2.Worksheets.Item(1)
    foreach ($r in @(1,2,3,5,6)) {
        $read["A$r"] = [string]$ws2.Cells.Item($r,1).Value2
    }
    $read['B5'] = [string]$ws2.Cells.Item(5,2).Value2
    $wb2.Close($false)
} finally {
    try { $xl2.Quit() } catch {}
    Release-YakuComObject $xl2
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

$rejoined = ((@($read['A1'], $read['A2'], $read['A3']) -join ' ') -replace '\s+', ' ').Trim()
Chk ($rejoined -eq 'In the first quarter under review, fixed costs were reduced through a review of production and lower procurement costs. However, due to foreign exchange, the increase in operating profit was limited to 20 oku.') '3セルを繋ぎ直すと訳文に戻る'
Chk (-not [string]::IsNullOrWhiteSpace($read['A1'])) '1セルへ寄せず、3セルに分けて書く'
Chk (-not [string]::IsNullOrWhiteSpace($read['A2'])) '2セル目にも入る'
Chk (-not [string]::IsNullOrWhiteSpace($read['A3'])) '3セル目にも入る'
Chk (@($read['A1'], $read['A2'], $read['A3']) -notcontains '当第1四半期は、生産体制の見直しと調達費の削減により') '元の日本語が残らない'
Chk ($read['A5'] -eq 'Operating profit') '表のラベルも訳される'
Chk ($read['A6'] -eq 'Ordinary profit') '表のラベル（2行目）も訳される'
Chk ($read['B5'] -eq '1234') '数値セルは触らない'

try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}

if ($script:fail -gt 0) {
    Write-Host "V91.61 excel segment round-trip regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 excel segment round-trip regression passed.' -ForegroundColor Green
