<#
.SYNOPSIS
  V91.61: 通常訳と、利用者が明示的に実行する短縮の応答契約テスト。

.DESCRIPTION
  通常の英訳は FULL_TEXT を1件だけ返す。短縮は通常訳の後で明示的に実行し、
  BRIEF_TEXT を1件だけ返す。旧来の同時応答は受理しない。

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

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$rid = 'deadbeefdeadbeefdeadbeefdeadbeef'

# ---------------------------------------------------------------- 求めるラベル
Write-Host '依頼ごとに求めるラベル'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_en' -Mode 'full') -join ',') -eq 'FULL_TEXT') '完全訳の依頼は FULL_TEXT だけ'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_en' -Mode 'brief') -join ',') -eq 'BRIEF_TEXT') '電文体の依頼は BRIEF_TEXT だけ'
Chk ((@(Get-YakuTextRequiredLabels -Direction 'to_en') -join ',') -eq 'FULL_TEXT') 'Mode 省略時も完全訳だけ'
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
$both = "FULL_TEXT:`nOperating profit increased.`nBRIEF_TEXT:`nOP up.`nYAKULINGO_END:$rid"
Chk (-not [bool](Test-YakuTextResponseContract -Text $both -Direction 'to_en' -RequestId $rid).Valid) '旧来の同時応答は受理しない'

# ---------------------------------------------------------------- 取り出し
Write-Host '取り出す訳文'
$f = @(Parse-YakuTextTranslationResponse -Raw $fullOnly -Direction 'to_en' -RequestId $rid -Warnings $null -Mode 'full')
Chk ($f.Count -eq 1 -and [string]$f[0].Style -eq 'full') ('完全訳が1件だけ取れる: ' + $f.Count)
Chk ([string]$f[0].Translation -match 'Operating profit increased') '本文が取れる'
$b = @(Parse-YakuTextTranslationResponse -Raw $briefOnly -Direction 'to_en' -RequestId $rid -Warnings $null -Mode 'brief')
Chk ($b.Count -eq 1 -and [string]$b[0].Style -eq 'brief') ('電文体が1件だけ取れる: ' + $b.Count)
# 電文体の依頼では、後処理の略語が当たる側であること。
Chk ([string]$b[0].Style -eq 'brief') '電文体は brief として扱われる（略語の後処理が当たる側）'

# ---------------------------------------------------------------- 依頼ごとの雛形
# 電文体の雛形は、完全訳を参照せずに単独で成立していなければならない。
# 旧 BRIEF 規則は「BRIEF is telegraphic FULL」で始まり、係り受けも引用も長さも
# 「FULL と比べて」で定義していたため、依頼を分けると成立しなかった（FULL への言及18か所）。
Write-Host '依頼ごとの雛形'
$src = '当第1四半期の営業利益は前年同期比20億円の増益となりました。'
$pFull  = (New-YakuTextPrompt -Root $root -InputText $src -Settings (Read-YakuSettings -Root $root) -DirectionOverride 'to_en' -RequestId $rid -Mode 'full').Prompt
$pBrief = (New-YakuTextPrompt -Root $root -InputText $src -Settings (Read-YakuSettings -Root $root) -DirectionOverride 'to_en' -RequestId $rid -Mode 'brief').Prompt
Chk ($pFull -match 'FULL_TEXT:') '完全訳の雛形は FULL_TEXT を出させる'
Chk ($pFull -notmatch 'BRIEF_TEXT') '完全訳の雛形は電文体に触れない'
Chk ($pBrief -match 'BRIEF_TEXT:') '電文体の雛形は BRIEF_TEXT を出させる'
Chk ($pBrief -notmatch 'FULL_TEXT') '電文体の雛形は完全訳に触れない'
Chk ((Get-Content -LiteralPath (Join-Path $root 'prompts\text_translate_full_to_en.txt') -Raw -Encoding UTF8).Length -lt 2600) '短文を埋めないよう完全訳の固定指示を2600字未満に保つ'
Chk ($pFull.Length -lt 4200) ('数値規則を含む短文用プロンプトを4200字未満に保つ: ' + $pFull.Length)
Chk ($pBrief -notmatch 'telegraphic FULL') '「FULL を電文体にしたもの」という定義が残っていない'
Chk ($pBrief -match 'not a shortened version') '電文体は独立した成果物として定義されている'
Chk ($pBrief -match 'attaches to in SOURCE') '係り受けの基準が FULL ではなく原文になっている'
Chk ($pBrief -match $src) '原文が入る'
Chk ($pFull -match $src) '原文が入る（完全訳）'

# ---------------------------------------------------------------- 節の条件化
# 規則を1節ずつ外して実機で測ったところ、B1-B7 と WHAT は 5事例すべてで
# 出力が変わらなかった（scratchpad の測定）。だが 0/5 は「効かない」証拠ではなく
# 「その原文が引き金を引かなかった」だけである。引用の規則は引用の原文でしか、
# 月名は月が出る原文でしか出番が無い。
# そこで規則は残し、引き金が原文に無いときだけ出さない。
# 実機で 6事例すべて、圧縮前と出力が一致することを確認済み（-757〜-1,634字）。
Write-Host '電文体の節を原文に応じて出す'
$briefSettings = Read-YakuSettings -Root $root
function BriefPrompt { param([string]$Src) (New-YakuTextPrompt -Root $root -InputText $Src -Settings $briefSettings -DirectionOverride 'to_en' -RequestId $rid -Mode 'brief').Prompt }

$plain = BriefPrompt '通期見通しへの影響は限定的と見込まれます。'
Chk ($plain -notmatch '\{brief_\w+\}') '差し込み口が残らない'
Chk ($plain -notmatch 'B6\. Quotations') '引用の無い原文に引用の規則を出さない'
Chk ($plain -notmatch 'Months: Jan\.') '月の無い原文に月名の規則を出さない'
Chk ($plain -notmatch 'FULL-WIDTH') '山括弧の無い原文に山括弧の作法を出さない'
Chk ($plain -notmatch 'Signed breakdowns') '内訳の無い原文に符号付き内訳の規則を出さない'

Chk ((BriefPrompt '社長は「連携が不可欠だ」と述べました。') -match 'B6\. Quotations') '引用があれば引用の規則を出す'
Chk ((BriefPrompt '社長は「連携が不可欠だ」と述べました。') -match '推進していくと述べた') '引用があれば引用の文例も出す'
Chk ((BriefPrompt '4月の生産台数は前年を上回りました。') -match 'Months: Jan\.') '月があれば月名の規則を出す'
Chk ((BriefPrompt "＜要約＞`n生産は堅調です。") -match 'FULL-WIDTH') '山括弧があれば山括弧の作法を出す'
Chk ((BriefPrompt '増減要因は、数量が+91億円です。') -match 'Signed breakdowns') '内訳があれば符号付き内訳の規則を出す'
Chk ((BriefPrompt '増減要因は、数量が+91億円です。') -match 'Breakdown: vol\.') '内訳があれば内訳の文例も出す'
Chk ((BriefPrompt '追加関税導入以降で最大の課税額となりました。') -match 'Attachment fidelity') '係り受けの規則は原文に依らず常に出す'
Chk ((BriefPrompt '追加関税導入以降で最大の課税額となりました。') -match 'trigger for stronger fin\. controls') '係り受けの文例も常に出す'
# 条件化は電文体だけ。完全訳の雛形には枠が無いので、通り抜けても跡が残らないこと。
Chk (((New-YakuTextPrompt -Root $root -InputText '生産は堅調です。' -Settings $briefSettings -DirectionOverride 'to_en' -RequestId $rid -Mode 'full').Prompt) -notmatch '\{brief_\w+\}') '完全訳の雛形に跡が残らない'

# ---------------------------------------------------------------- 略語の後処理
# 文脈に依らない略語はプロンプトの一覧から外し、アプリで当てる。
# 一覧に書くのは確率的だが、当てれば必ず揃う。
Write-Host '文脈に依らない略語はアプリが当てる'
# 略語は「綴ると入らない」かつ「一般的である」の両方を満たすものだけに絞った
# （2026-08-08）。rev. は revised とも読めて多義的、redn. は一般的な略記では
# ないので外した。綴っても入るものは略さない。
Chk ((Convert-YakuBriefAbbreviations -Text 'Revenue increased.') -eq 'Revenue increased.') 'revenue は略さない（rev. は revised とも読める）'
Chk ((Convert-YakuBriefAbbreviations -Text 'FC reduction 0.5 oku.') -eq 'FC reduction 0.5 oku.') 'reduction は略さない（redn. は一般的でない）'
Chk ((Convert-YakuBriefAbbreviations -Text 'Higher volume drove it.') -eq 'Higher vol. drove it.') 'volume -> vol.'
Chk ((Convert-YakuBriefAbbreviations -Text 'Consolidated OP up.') -eq 'Consol. OP up.') 'consolidated -> consol.'
# 動詞・形容詞の用法があるものは移さない。機械的に当てると読みにくくなる。
Chk ((Convert-YakuBriefAbbreviations -Text 'We forecast growth.') -eq 'We forecast growth.') 'forecast は当てない（動詞の用法がある）'
Chk ((Convert-YakuBriefAbbreviations -Text 'The actual figure.') -eq 'The actual figure.') 'actual は当てない（形容詞の用法がある）'
# 引用の中は従来どおり触らない。
Chk ((Convert-YakuBriefAbbreviations -Text 'He said "revenue increased".') -eq 'He said "revenue increased".') '引用の中の略語は当てない'
# プロンプト側の一覧から消えていること。二重に書くと、外した意味が無い。
$briefTpl = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'prompts') 'text_translate_brief_to_en.txt'))
Chk ($briefTpl -notmatch 'revenue -> rev\.') 'プロンプトの一覧から revenue が消えている'
Chk ($briefTpl -match 'rev\., vol\., consol\., redn\.') '「呼び出し側が当てるのでどちらでもよい」側に載っている'

# ---------------------------------------------------------------- 1回の通常翻訳
Write-Host '通常翻訳は1回だけ'
$translationText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Translation.ps1'))
Chk ($translationText -notmatch 'YAKULINGO_PARALLEL') '休眠中の並列切替が無い'
Chk ($translationText -notmatch 'Invoke-YakuTextRequestsInParallel') '休眠中の並列関数が無い'
Chk ($translationText -match "Invoke-YakuSingleTranslationBatch[\s\S]*-Mode 'full'") '通常英訳は完全訳を1回だけ要求する'

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
