#Requires -Version 5.1
<#
  現訳の長さからの概算文字目標が、安全にモデルへ届くこと。

  2026-08-17 に実行して確かめた欠陥の回帰。sidecar の
  `placement_budget.max_chars` は JSON 丸ごとが数値マスクを通るので、
  "40" は "[[N21]]" として外へ出ていた。

    モデルは「予算がある」と言われ、「越えるなら断れ」と言われ、
    数だけ見せられずに、後からその数（マスクしていない実数）で裁かれていた
    （`Complete-YakuCatPublicationCandidateSet`、`.Length -gt $maxChars`）。

  `max_chars` はクライアントが現訳の長さから作る概算目標で、ワークブックの幅や
  セル容量の測定値ではない。`Assert-YakuNumericPromptProtected` と衝突しない
  8..99 の2桁だけを、数値マスク済みsidecarとは別の固定プロンプト文へ渡す。

  Copilot も Excel も要らない。プロンプトを組んで文字列を見るだけである。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9187Root = Split-Path -Parent $PSScriptRoot
$YakuT9187Src = Join-Path $YakuT9187Root 'src'
$script:T9187Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9187 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9187Failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9187CompactionBudget'

. (Join-Path $YakuT9187Src 'SrcModules.ps1')
foreach ($YakuT9187File in $script:YakuSrcModuleFiles) {
    if ($YakuT9187File -eq 'DesktopIntegration.ps1') { continue }
    . (Join-Path $YakuT9187Src $YakuT9187File)
}

$YakuT9187RequestId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
$YakuT9187Sidecar = '{"segment_id":"s","canonical_translation":"Net sales were [[N1]] million yen.","placement_budget":{"max_chars":"[[N2]]"}}'

# --- 安全な2桁だけ、概算目標として本文に出る ---------------------------------
$withBudget = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 32
Assert-T9187 -Condition ($withBudget -match '(?i)requested approximate character target is 32 characters') -Message 'a two-digit approximate target appears in the prompt'
Assert-T9187 -Condition ($withBudget -match '(?i)not a measured cell capacity') -Message 'the prompt does not claim measured cell capacity'
Assert-T9187 -Condition ($withBudget -match '(?i)cannot_fit_reason') -Message 'refusing is still offered as an answer'

# --- 渡さなければ、何も言わない -----------------------------------------------
$withoutBudget = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId
Assert-T9187 -Condition ($withoutBudget -notmatch '(?i)requested approximate character target') -Message 'no target is stated when none was supplied'
Assert-T9187 -Condition ($withoutBudget -match '(?i)placement budget') -Message 'the existing wording is untouched when no number travels'

# --- 8..99 の外は指示しない ---------------------------------------------------------
# 小さすぎる目標は破壊的であり、3桁以上は圧縮が必要な状態とは言えない。
$threeDigits = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 160
Assert-T9187 -Condition ($threeDigits -notmatch '\b160\b') -Message 'a three-digit budget is NOT written into the prompt'
Assert-T9187 -Condition ($threeDigits -notmatch '(?i)requested approximate character target') -Message 'and no target sentence is produced for it'
$zero = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 0
Assert-T9187 -Condition ($zero -notmatch '(?i)requested approximate character target') -Message 'zero means "say nothing"'
$boundaryLow = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 7
Assert-T9187 -Condition ($boundaryLow -notmatch '(?i)requested approximate character target') -Message '7 does not become a target instruction'
$firstAllowed = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 8
Assert-T9187 -Condition ($firstAllowed -match '(?i)requested approximate character target is 8 characters') -Message '8 is the first allowed target'
$boundaryHigh = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 99
Assert-T9187 -Condition ($boundaryHigh -match '(?i)requested approximate character target is 99 characters') -Message '99 is the last allowed target'
$justOver = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 100
Assert-T9187 -Condition ($justOver -notmatch '(?i)requested approximate character target') -Message '100 does not become a target instruction'
$invalid = New-YakuCompactionCandidatePrompt -ProtectedSidecar $YakuT9187Sidecar -RequestId $YakuT9187RequestId -MaxChars 'not-an-integer'
Assert-T9187 -Condition ($invalid -notmatch '(?i)requested approximate character target') -Message 'an invalid target does not become an instruction'

# --- 伏せた数値の扱いは変えていない -------------------------------------------
Assert-T9187 -Condition ($withBudget.Contains('[[N1]]')) -Message 'the masked document numbers still go out masked'
Assert-T9187 -Condition ($withBudget.Contains('[[N2]]')) -Message 'the sidecar budget stays masked; the plain number is a separate sentence'

# --- 配線（実際のprotected packageまで） -----------------------------------------------
$YakuT9187Settings = Read-YakuSettings -Root $YakuT9187Root
$YakuT9187SourceText = [string]::Concat([char]0x58F2, [char]0x4E0A, [char]0x9AD8, [char]0x306F, '123', [char]0x767E, [char]0x4E07, [char]0x5186, [char]0x3067, [char]0x3057, [char]0x305F, [char]0x3002)
Assert-T9187 -Condition ($YakuT9187SourceText.Length -eq 14 -and [int][char]$YakuT9187SourceText[0] -eq 0x58F2 -and [int][char]$YakuT9187SourceText[13] -eq 0x3002) -Message 'the Unicode-built source fixture has the intended length and endpoints'
$YakuT9187Project = New-YakuCatTextProject -Root $YakuT9187Root -Text $YakuT9187SourceText -Settings $YakuT9187Settings -Direction to_en -Register:$false
$YakuT9187Segment = $YakuT9187Project.Segments[0]
$YakuT9187Segment.Translation = 'Net sales were 123 million yen.'
$YakuT9187Segment.Kind = 'cell'; $YakuT9187Segment.Sheet = 'Sheet1'; $YakuT9187Segment.BlockIds = @('block-a')
$YakuT9187Segment.Cells = @([pscustomobject]@{ Text = [string]$YakuT9187Segment.Text; Address = 'A1' })
$YakuT9187Project.Blocks = @([pscustomobject]@{ Id = 'block-a'; Text = [string]$YakuT9187Segment.Text; Location = 'Sheet1!A1'; Meta = $null })
$null = Initialize-YakuCatProjectState -Project $YakuT9187Project
$null = Sync-YakuCatPlacementPlans -Project $YakuT9187Project
$wiredRequest = New-YakuCatProtectedPublicationCandidateRequest -Root $YakuT9187Root -Project $YakuT9187Project -Index 0 -PlacementBudget ([pscustomobject]@{ max_chars = 32; destination_count = 1 })
Assert-T9187 -Condition ([string]$wiredRequest.Envelope.Prompt -match '(?i)requested approximate character target is 32 characters') -Message 'the protected package carries the approximate target to the prompt'
Assert-T9187 -Condition (-not ([string]$wiredRequest.ProtectedSidecar).Contains('32') -and [string]$wiredRequest.ProtectedSidecar -match '\[\[N\d+\]\]') -Message 'the protected sidecar keeps placement numbers masked'

Write-Host ''
if ($script:T9187Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9187CompactionBudget'
    exit 0
}
Write-Host ("FAIL " + $script:T9187Failures.Count + ' assertion(s)')
foreach ($YakuT9187F in $script:T9187Failures) { Write-Host ('  - ' + $YakuT9187F) }
exit 1
