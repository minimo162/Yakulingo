<#
.SYNOPSIS
  V91.61: 完全訳と開示用の電文体を別々の依頼として扱う経路の回帰テスト。

.DESCRIPTION
  電文体は完全訳を短くしたものではなく、同じ原文に対する別の成果物である
  （利用者の判断 2026-08-06）。依頼を分けると、応答は片方のラベルだけを持つ。
  従来は FULL_TEXT と BRIEF_TEXT の両方が揃わないと受理しなかったため、
  受け取り側・契約・取り出しの3か所を Mode で切り替えられるようにした。

  Copilot への往復は行わない。契約と取り出しだけを確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161SplitRequests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$rid = 'deadbeefdeadbeefdeadbeefdeadbeef'

# ---------------------------------------------------------------- 求めるラベル
Write-Host '依頼ごとに求めるラベル'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_en' -Mode 'full') -join ',') -eq 'FULL_TEXT') '完全訳の依頼は FULL_TEXT だけ'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_en' -Mode 'brief') -join ',') -eq 'BRIEF_TEXT') '電文体の依頼は BRIEF_TEXT だけ'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_en' -Mode '') -join ',') -eq 'FULL_TEXT,BRIEF_TEXT') 'Mode 無しは従来どおり両方'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_jp' -Mode 'full') -join ',') -eq 'JAPANESE_TEXT') 'EN→JA は Mode に依らず JAPANESE_TEXT'

# ---------------------------------------------------------------- 契約
Write-Host '片方だけの応答を受理する'
$fullOnly  = "FULL_TEXT:`nOperating profit increased.`nYAKULINGO_END:$rid"
$briefOnly = "BRIEF_TEXT:`nOP up.`nYAKULINGO_END:$rid"
Chk ([bool](Test-YakuTextResponseContract -Text $fullOnly -Direction 'to_en' -RequestId $rid -Mode 'full').Valid) '完全訳だけの応答が通る'
Chk ([bool](Test-YakuTextResponseContract -Text $briefOnly -Direction 'to_en' -RequestId $rid -Mode 'brief').Valid) '電文体だけの応答が通る'
# 求めていないラベルで返ってきたら受理しない。取り違えを見逃さないため。
Chk (-not [bool](Test-YakuTextResponseContract -Text $briefOnly -Direction 'to_en' -RequestId $rid -Mode 'full').Valid) '完全訳を求めたのに電文体が返れば弾く'
Chk (-not [bool](Test-YakuTextResponseContract -Text $fullOnly -Direction 'to_en' -RequestId $rid -Mode 'brief').Valid) '電文体を求めたのに完全訳が返れば弾く'
# 旧経路（1依頼で2つ）は従来どおり両方を要求する。
$both = "FULL_TEXT:`nOperating profit increased.`nBRIEF_TEXT:`nOP up.`nYAKULINGO_END:$rid"
Chk ([bool](Test-YakuTextResponseContract -Text $both -Direction 'to_en' -RequestId $rid -Mode '').Valid) 'Mode 無しなら両方揃った応答が通る'
Chk (-not [bool](Test-YakuTextResponseContract -Text $fullOnly -Direction 'to_en' -RequestId $rid -Mode '').Valid) 'Mode 無しで片方だけなら弾く'

# ---------------------------------------------------------------- 取り出し
Write-Host '取り出す訳文'
$f = @(Parse-YakuTextTranslationResponse -Raw $fullOnly -Direction 'to_en' -RequestId $rid -Warnings $null -Mode 'full')
Chk ($f.Count -eq 1 -and [string]$f[0].Style -eq 'full') ('完全訳が1件だけ取れる: ' + $f.Count)
Chk ([string]$f[0].Translation -match 'Operating profit increased') '本文が取れる'
$b = @(Parse-YakuTextTranslationResponse -Raw $briefOnly -Direction 'to_en' -RequestId $rid -Warnings $null -Mode 'brief')
Chk ($b.Count -eq 1 -and [string]$b[0].Style -eq 'brief') ('電文体が1件だけ取れる: ' + $b.Count)
# 電文体の依頼では、後処理の略語が当たる側であること。
Chk ([string]$b[0].Style -eq 'brief') '電文体は brief として扱われる（略語の後処理が当たる側）'

# ---------------------------------------------------------------- 受け取り契約（JS）
Write-Host '受け取り契約が片方だけを認める'
$clientText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CopilotClient.ps1'))
$usefulBlock = [regex]::Match($clientText, '(?s)const hasUsefulLabeledOutput = \(text\) => \{.*?\n\};').Value
Chk ($usefulBlock -match 'if \(hasFull\)') '完全訳だけでも有効と認める'
Chk ($usefulBlock -match 'if \(hasBrief\)') '電文体だけでも有効と認める'
Chk ($usefulBlock -match 'hasFull && hasBrief') '両方在るときは両方揃うことを求める'

if ($script:fail -gt 0) {
    Write-Host "V91.61 split-request regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 split-request regression passed.' -ForegroundColor Green
