<#
.SYNOPSIS
  過去の対訳 Excel から、表ラベル置換表の候補を取り出す。

.DESCRIPTION
  表の変わらない部分は AI を使うまでもなく機械置換で足りる
  （利用者の判断 2026-08-06）。置換の仕組みは既にある
  （用語記録の cell_exact による完全一致）。足りないのは置換表そのものの供給で、
  いまは開発者が一人で書いている。

  過去の ECM 資料には英訳がある。そこから対応を吸い出せば、
  置換表は人手で書くものではなく、過去の成果物から採るものになる。

  番地では突き合わせない。体裁のために行や列を出し入れするため、
  1本入っただけで以降が全部ずれる（利用者の説明 2026-08-06）。
  代わりに、両側で1回だけ現れる数値を錨にし、その直前のテキストを
  項目名として対応付ける。詳細は src/CellAlign.ps1 に書いた。

  **出てくるのは候補であって置換表ではない。**
  置換表は完全一致で機械置換する先なので、誤りが1件混ざれば以後ずっと
  当たり続ける。CSV を人が見て、採る行の「採用」列に印を付けてから
  tools\Import-YakuCellGlossary.ps1 に渡すこと。
  このツール自身は用語記録を書き換えない。

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
foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','FileProcessors.ps1','GlossaryVariants.ps1','CellAlign.ps1','Terminology.ps1','PersonalGlossary.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
# 既定の置き場も src\PersonalGlossary.ps1 が決める。ここで綴ると、
# 案内が別のファイルを名指しする変異を、門が文字列の比較でしか追えなくなる。
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Get-YakuCellGlossaryDefaultCandidatePath -Directory $toolsRoot }

# 画面へ出す文言は、このファイルには1つも置かない。ここから渡すのは数と対象だけで、
# 文言の組み立ても印字も src\PersonalGlossary.ps1 の関数が持つ。
# 2026-08-16 の実測: 末尾へ Write-Host を1行足して、置いていないパスを
# 「書き出しました」として出す変異が、門を終了コード0で通り抜けた。
# 印字をこちらに残すかぎり、門は「何を印字したか」を測れない。

# 既に登録済みの語は候補から外す。同じものを何度も見せない。
# 集合の作り方も絞り込みも src\PersonalGlossary.ps1 に置いてある。
# ここに書き下すと、門は「関数を呼んでいるか」しか測れなくなる。
$known = @{}
try {
    $known = Get-YakuCellGlossaryKnownSources -Path (Get-YakuPersonalTerminologyPath)
} catch {
    Write-YakuCellGlossaryLines -Lines (New-YakuCellGlossaryKnownSourceFailureLines -Message $_.Exception.Message)
}
Write-YakuCellGlossaryLines -Lines (New-YakuCellGlossaryKnownSourceLines -Count $known.Count)

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
        Write-YakuCellGlossaryLines -Lines (New-YakuCellGlossaryWorkbookHeadingLines -SourcePath $src -TargetPath $tgt)
        $r = Get-YakuWorkbookPairCandidates -SourcePath $src -TargetPath $tgt -Context $context
        Write-YakuCellGlossaryLines -Lines (New-YakuCellGlossarySheetLines -Sheets $r.Sheets)
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
# 期をずらした版を先に作っておく。最新の四半期から採ると次の四半期に
# 当たらなくなるため（利用者の指示 2026-08-06）。実測は上書きしない。
$withVariants = @(Add-YakuGlossaryPeriodVariants -Entries $merged)
$fresh = @(Select-YakuCellGlossaryUnregisteredEntries -Entries $withVariants -Known $known)

# 行の組み立て・書き出し・そのあとの案内は src\PersonalGlossary.ps1 の1本に任せる。
# 案内は「書いたファイルを開き直した結果」から組み立てられるので、ここで
# $OutputPath を束ね直しても、案内だけが別のファイルを指すことは起きない。
# 置いていないファイルを案内が名指しするのが、この改修が直した欠陥である。
$handoff = New-YakuCellGlossaryCandidateHandoff -Entries $fresh -Path $OutputPath `
    -ImportToolPath (Join-Path $toolsRoot 'Import-YakuCellGlossary.ps1')

$conflicts = @($fresh | Where-Object { [bool]$_.Conflict }).Count
Write-YakuCellGlossaryLines -Lines (New-YakuCellGlossaryTallyLines -Raw $all.Count -Usable $usable.Count `
    -Merged $merged.Count -WithVariants $withVariants.Count -Fresh $fresh.Count -Conflicts $conflicts)
Write-YakuCellGlossaryLines -Lines $handoff.Lines
