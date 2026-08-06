<#
.SYNOPSIS
  過去の対訳 Excel から、表ラベル置換表の候補を取り出す。

.DESCRIPTION
  表の変わらない部分は AI を使うまでもなく機械置換で足りる
  （利用者の判断 2026-08-06）。置換の仕組みは既にある
  （glossary.csv のセル完全一致）。足りないのは置換表そのものの供給で、
  いまは開発者が一人で書いている。

  過去の ECM 資料には英訳がある。そこから対応を吸い出せば、
  置換表は人手で書くものではなく、過去の成果物から採るものになる。

  番地では突き合わせない。体裁のために行や列を出し入れするため、
  1本入っただけで以降が全部ずれる（利用者の説明 2026-08-06）。
  代わりに、両側で1回だけ現れる数値を錨にし、その直前のテキストを
  項目名として対応付ける。詳細は src/CellAlign.ps1 に書いた。

  **出てくるのは候補であって置換表ではない。**
  置換表は完全一致で機械置換する先なので、誤りが1件混ざれば以後ずっと
  当たり続ける。CSV を人が見て、採るものだけを glossary.csv へ移すこと。
  このツールは glossary.csv を書き換えない。

.PARAMETER Pair
  「日本語版のパス=英語版のパス」。複数指定できる。

.PARAMETER OutputPath
  候補を書き出す CSV。既定は tools\cell-glossary-candidates.csv。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Extract-YakuCellGlossary.ps1 `
    -Pair 'C:\ecm\2025_06_JP.xlsx=C:\ecm\2025_06_EN.xlsx' `
    -Pair 'C:\ecm\2025_07_JP.xlsx=C:\ecm\2025_07_EN.xlsx'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string[]]$Pair,
    [string]$OutputPath = '',
    # 確度の低いものも書き出す。何が落ちたかを確かめたいとき用。
    [switch]$IncludeLowConfidence
)

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','FileProcessors.ps1','CellAlign.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $toolsRoot 'cell-glossary-candidates.csv' }

# 既に登録済みの語は候補から外す。同じものを何度も見せない。
$known = @{}
try {
    $glossaryPath = Join-Path $root 'glossary.csv'
    if (Test-Path -LiteralPath $glossaryPath) {
        foreach ($row in (Import-Csv -LiteralPath $glossaryPath -Encoding UTF8)) {
            $s = ''
            foreach ($col in @('Source','source','原文','日本語')) {
                try { if ($row.PSObject.Properties.Name -contains $col) { $s = [string]$row.$col; break } } catch {}
            }
            if (-not [string]::IsNullOrWhiteSpace($s)) { $known[$s.Trim()] = $true }
        }
    }
} catch { Write-Host ('用語集を読めませんでした（候補の絞り込みのみ影響します）: ' + $_.Exception.Message) -ForegroundColor Yellow }
Write-Host ('登録済み: ' + $known.Count + ' 件')

$all = New-Object System.Collections.Generic.List[object]
$context = New-YakuExcelApplication
try {
    foreach ($spec in $Pair) {
        $parts = [string]$spec -split '=', 2
        if ($parts.Count -ne 2) { throw ('-Pair は「日本語版=英語版」の形で指定してください: ' + $spec) }
        $src = $parts[0].Trim('"').Trim()
        $tgt = $parts[1].Trim('"').Trim()
        if (-not (Test-Path -LiteralPath $src)) { throw ('見つかりません: ' + $src) }
        if (-not (Test-Path -LiteralPath $tgt)) { throw ('見つかりません: ' + $tgt) }
        Write-Host ''
        Write-Host ('■ ' + (Split-Path -Leaf $src) + '  ↔  ' + (Split-Path -Leaf $tgt))
        $r = Get-YakuWorkbookPairCandidates -SourcePath $src -TargetPath $tgt -Context $context
        foreach ($s in @($r.Sheets)) {
            if (-not [bool]$s.Matched) {
                Write-Host ('    ' + [string]$s.Sheet + ' … 英語版に同名のシートが無い（対象外）') -ForegroundColor Yellow
                continue
            }
            Write-Host ('    ' + [string]$s.Sheet + ' … 錨 ' + [string]$s.Anchors + ' / 候補 ' + [string]$s.Pairs)
        }
        foreach ($p in @($r.Pairs)) { [void]$all.Add($p) }
    }
} finally {
    Close-YakuExcelObjects -Workbook $null -Application $context.Application `
        -OldScreenUpdating $context.OldScreenUpdating -OldEnableEvents $context.OldEnableEvents `
        -OldDisplayStatusBar $context.OldDisplayStatusBar -OldFormatConditionsCalc $context.OldFormatConditionsCalc `
        -OldBackgroundChecking $context.OldBackgroundChecking
}

$usable = @(@($all.ToArray()) | Where-Object {
    if ($IncludeLowConfidence) { return $true }
    Test-YakuCellPairUsableAsGlossary -Pair $_
})
$merged = @(Merge-YakuCellPairOccurrences -Pairs $usable)
$fresh = @($merged | Where-Object { -not $known.ContainsKey([string]$_.Source) })

$rows = New-Object System.Collections.Generic.List[object]
foreach ($e in $fresh) {
    [void]$rows.Add([pscustomobject]@{
        採用       = ''
        Source     = [string]$e.Source
        Target     = [string]$e.Target
        出現数     = [int]$e.Count
        競合       = $(if ([bool]$e.Conflict) { 'あり' } else { '' })
        確度       = [string]$e.Confidence
        参照セル   = (@($e.Samples) -join ' / ')
    })
}
$rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host ('候補（生）        : ' + $all.Count + ' 件')
Write-Host ('置換表に使える形  : ' + $usable.Count + ' 件')
Write-Host ('まとめた後        : ' + $merged.Count + ' 件')
Write-Host ('登録済みを除く    : ' + $fresh.Count + ' 件')
$conflicts = @($fresh | Where-Object { [bool]$_.Conflict }).Count
if ($conflicts -gt 0) { Write-Host ('うち訳が割れているもの: ' + $conflicts + ' 件（どちらを採るか人が決めること）') -ForegroundColor Yellow }
Write-Host ''
Write-Host ('書き出しました: ' + $OutputPath) -ForegroundColor Green
Write-Host '採用する行の「採用」列に印を付けてから、glossary.csv へ移してください。'
Write-Host 'このツールは glossary.csv を書き換えません。誤りが1件混ざると完全一致で当たり続けるためです。'
