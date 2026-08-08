<#
.SYNOPSIS
  V91.61: 社内表記の金額を公表表記へ書き換える処理の回帰テスト。

.DESCRIPTION
  同じ訳文を2通りに書き分けるための処理。訳し直しではない。
  数値はマスクして送っているので、手元のマップから2通りに書き戻せる。

  「社内は oku」と決めつけない（利用者の指摘 2026-08-08）。どちらを使うかは
  利用者がトグルで選ぶ。アプリは推測しない。

  見るのは3つ。
   - 桁の変換が正しいか（億円 = 0.1 billion）
   - 符号・括弧・桁区切りを壊さないか
   - oku 以外を巻き込まないか

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161PublishedUnits.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

# Translation.ps1 は依存が多いので、関数の本体だけを取り出して読み込む。
$src = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Translation.ps1') -Raw -Encoding UTF8
$m = [regex]::Match($src, '(?ms)^function ConvertTo-YakuPublishedUnitText \{.*?^\}')
if (-not $m.Success) { Write-Host '  FAIL ConvertTo-YakuPublishedUnitText が見つからない' -ForegroundColor Red; exit 1 }
. ([scriptblock]::Create($m.Value))

function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }
function Conv { param([string]$t) return (ConvertTo-YakuPublishedUnitText -Text $t) }

Write-Host '桁の変換' -ForegroundColor Cyan
Chk ((Conv 'OP 122 oku.') -eq 'OP ¥12.2 billion.') '122 oku を ¥12.2 billion にする'
Chk ((Conv 'Sales 1,500 oku.') -eq 'Sales ¥150.0 billion.') '桁区切りのあるものを換算する'
Chk ((Conv 'Net 10 oku.') -eq 'Net ¥1.0 billion.') '10 oku は ¥1.0 billion'
Chk ((Conv 'Total 12,345 oku.') -eq 'Total ¥1,234.5 billion.') '兆を超えても billion のまま出す'

Write-Host '壊さない' -ForegroundColor Cyan
Chk ((Conv 'OP ▲12.0 oku.') -eq 'OP ▲¥1.2 billion.') '負号を残す'
Chk ((Conv 'OP (45) oku.') -eq 'OP (45) oku.') '括弧つきは数として拾わない（誤変換より無変換を選ぶ）'
Chk ((Conv 'We will advance electrification.') -eq 'We will advance electrification.') '金額が無い文は変えない'
Chk ((Conv '') -eq '') '空文字でも落ちない'
Chk ((Conv $null) -eq '') 'null でも落ちない'

Write-Host '巻き込まない' -ForegroundColor Cyan
Chk ((Conv 'Okura Hotel opened.') -eq 'Okura Hotel opened.') '固有名詞の Oku を巻き込まない'
Chk ((Conv '15 okura') -eq '15 okura') 'oku で始まる別の語を巻き込まない'
Chk ((Conv '3,501,499 million yen') -eq '3,501,499 million yen') 'million 表記は触らない'

if ($script:fail -gt 0) {
    Write-Host "V91.61 published units regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 published units regression passed.' -ForegroundColor Green
