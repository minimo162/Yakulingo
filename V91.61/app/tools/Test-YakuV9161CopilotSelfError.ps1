<#
.SYNOPSIS
  V91.61: Copilot 自身が返したエラー文言を拾えるかの回帰テスト。

.DESCRIPTION
  2026-08-08、Copilot が画面に「申し訳ございません。問題が発生しました」と
  出しているのに、アプリは「解析可能な回答を取得できませんでした」とだけ
  伝えていた。そのため原因をこちら側に求め、劣化・呼び出し回数・応答解析と
  3つの誤った仮説を立てた。診断を有効にして画面の文字を読むまで気づけなかった。

  Copilot が謝っているなら、待って出直すのが正解であり、他の失敗とは対処が
  違う。利用者にも同じ誤解をさせないよう、文言を拾ってそのまま見せる。

  ここで見るのは3つ。
   - 代表的なエラー文言を拾えること
   - 正常な応答を誤ってエラー扱いしないこと
   - 前の応答に紛れた語で誤検知しないこと（画面の末尾だけを見る）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CopilotSelfError.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

# CopilotClient.ps1 は依存が多いので、関数の本体だけを取り出して読み込む。
$src = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CopilotClient.ps1') -Raw -Encoding UTF8
$m = [regex]::Match($src, '(?ms)^function Get-YakuCopilotSelfReportedError \{.*?^\}')
if (-not $m.Success) { Write-Host '  FAIL Get-YakuCopilotSelfReportedError が見つからない' -ForegroundColor Red; exit 1 }
. ([scriptblock]::Create($m.Value))

function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

Write-Host 'Copilot のエラー文言を拾う' -ForegroundColor Cyan
$tail = @'
EN_TEXT_END:69d569425f804682b35a94a28f4e3487

Copilot said:
申し訳ございません。問題が発生しました。もう一度お試しいただけますか?
再試行
'@
$got = Get-YakuCopilotSelfReportedError -MainTail $tail
Chk ($got -match '問題が発生しました') '日本語のエラー文言を拾う'
Chk ($got -notmatch 'EN_TEXT_END') '本文まで巻き込まない'

$got = Get-YakuCopilotSelfReportedError -MainTail "some answer`nSorry, something went wrong. Please try again."
Chk ($got -match 'something went wrong') '英語のエラー文言を拾う'

Write-Host '誤検知しない' -ForegroundColor Cyan
$ok = @'
[[ID:1]] 1. J00+J01 | E00
[[ID:2]] 2. J02 | E01
YAKULINGO_END:abc
'@
Chk ([string]::IsNullOrEmpty((Get-YakuCopilotSelfReportedError -MainTail $ok))) '正常な応答はエラーにしない'
Chk ([string]::IsNullOrEmpty((Get-YakuCopilotSelfReportedError -MainTail ''))) '空文字でも落ちない'
Chk ([string]::IsNullOrEmpty((Get-YakuCopilotSelfReportedError -MainTail $null))) 'null でも落ちない'

# 過去の応答に同じ語が含まれていても、画面の末尾を見るので拾わない。
$old = ('申し訳ございません。問題が発生しました。' + ("`n本文" * 400) + "`n[[ID:1]] 1. J00 | E00`nYAKULINGO_END:abc")
Chk ([string]::IsNullOrEmpty((Get-YakuCopilotSelfReportedError -MainTail $old))) '前の応答に紛れた語では誤検知しない'

Write-Host '呼び出し側' -ForegroundColor Cyan
$client = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CopilotClient.ps1') -Raw -Encoding UTF8
Chk ($client -match 'COPILOT_SERVICE_ERROR') 'Copilot 由来のエラーを別の種類として投げる'
Chk ($client -match 'Get-YakuCopilotSelfReportedError -MainTail') '応答が使えないときに文言を確かめている'

if ($script:fail -gt 0) {
    Write-Host "V91.61 copilot self error regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 copilot self error regression passed.' -ForegroundColor Green
