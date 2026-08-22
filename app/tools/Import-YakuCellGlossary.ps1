<#
.SYNOPSIS
  候補CSVのうち「採用」列に印を付けた行を、表ラベル置換表（cell-exact）へ登録する。

.DESCRIPTION
  tools\Extract-YakuCellGlossary.ps1 が書き出した候補CSVを受け取り、
  「採用」列に印の付いた行だけを個人の用語記録へ足す。
  登録先は %USERPROFILE%\.yakulingo-ps\terminology\personal-v2.jsonl だけで、
  共有フォルダへは書かない。

  出典（どのファイルのどのセルから採ったか）は候補CSVの「参照セル」列から採る。
  この列が空の行は、出典が無いので登録しない。代わりの値は作らない。

  同じCSVを何度取り込んでも、内容が変わっていなければ何も足さない。
  訳を直して取り込み直したときだけ、版を上げて足す（前の版は残る）。

.PARAMETER CandidatePath
  候補CSV。既定は tools\cell-glossary-candidates.csv。

.PARAMETER TerminologyPath
  登録先の JSONL。既定は個人の用語記録。ローカルの terminology フォルダの外は受け付けない。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Import-YakuCellGlossary.ps1 `
    -CandidatePath .\tools\cell-glossary-candidates.csv
#>
[CmdletBinding()]
param(
    [string]$CandidatePath = '',
    [string]$TerminologyPath = ''
)

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
foreach ($n in @('Paths.ps1', 'Runtime.ps1', 'Terminology.ps1', 'PersonalGlossary.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
if ([string]::IsNullOrWhiteSpace($CandidatePath)) { $CandidatePath = Join-Path $toolsRoot 'cell-glossary-candidates.csv' }

$result = Import-YakuCellGlossaryCandidates -Path $CandidatePath -TerminologyPath $TerminologyPath

Write-Host ''
Write-Host ('候補CSV      : ' + [string]$result.CandidatePath)
Write-Host ('登録先       : ' + [string]$result.TerminologyPath)
Write-Host ('行数         : ' + [string]$result.Rows + ' 件')
Write-Host ('採用の印あり : ' + [string]$result.Adopted + ' 件')
Write-Host ('新しく登録   : ' + [string]$result.Imported + ' 件') -ForegroundColor Green
Write-Host ('訳を更新     : ' + [string]$result.Updated + ' 件')
Write-Host ('登録済みで据置: ' + [string]$result.Skipped + ' 件')
if ([int]$result.Withdrawn -gt 0) {
    Write-Host ('取り消し済みのため入れないもの: ' + [string]$result.Withdrawn + ' 件') -ForegroundColor Yellow
}

$unknown = @($result.UnrecognizedMarks)
if ($unknown.Count -gt 0) {
    Write-Host ''
    Write-Host ('採用の印として読めなかった行: ' + $unknown.Count + ' 件（登録していません）') -ForegroundColor Yellow
    foreach ($u in $unknown) {
        Write-Host ('  ' + [string]$u.Row + ' 行目  印=「' + [string]$u.Mark + '」  ' + [string]$u.Source) -ForegroundColor Yellow
    }
    Write-Host '  印は o / 〇 / ○ / y / yes / 1 / true / ✓ / 採用 のいずれかにしてください。' -ForegroundColor Yellow
}

$bad = @($result.Rejected)
if ($bad.Count -gt 0) {
    Write-Host ''
    Write-Host ('登録できなかった行: ' + $bad.Count + ' 件') -ForegroundColor Red
    foreach ($b in $bad) {
        Write-Host ('  ' + [string]$b.Row + ' 行目  ' + [string]$b.Code + '  ' + [string]$b.Source + ' → ' + [string]$b.Target) -ForegroundColor Red
        Write-Host ('      ' + [string]$b.Message) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host 'CSV を直してから、もう一度この取り込みを実行してください。' -ForegroundColor Red
    Write-Host '既に登録できた行は二重には入りません。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '登録しました。次の翻訳から、これらのセルは完全一致で置き換わります。' -ForegroundColor Green
exit 0
