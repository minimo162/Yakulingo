#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\CatTranslation.ps1')

$script:Failures = 0
function Assert-FitFirst {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

Write-Host 'Test-YakuFitFirstPrompt'

$targets = New-YakuCatCharacterTargets -Items @([pscustomobject]@{ Index = 1; MaxChars = 24 })
Assert-FitFirst ($targets -match '(?i)space budget') 'character target is explicitly a space budget'
Assert-FitFirst ($targets -match '(?i)compress the wording') 'targeted items explicitly compress wording'
Assert-FitFirst ($targets -match '(?i)stay at or below') 'targeted items aim to stay within the budget'
Assert-FitFirst ($targets -match '(?i)exceed it only as a last resort') 'overflow is a last-resort fallback, not the default'
Assert-FitFirst ($targets -match '(?i)Never omit, abbreviate, summarize, compress, or drop information') 'facts remain protected while wording is compressed'
Assert-FitFirst ((New-YakuCatCharacterTargets -Items @([pscustomobject]@{ Index = 1; MaxChars = $null })) -eq 'No character targets apply.') 'untargeted items retain the normal translation path'
Assert-FitFirst ((Get-YakuCatPromptContractVersion) -eq 'cat-fit-first-v1-terminology') 'prompt contract version invalidates pre-fit-first cached prompts'

$en = [IO.File]::ReadAllText((Join-Path $root 'prompts\cat_translate_to_en.txt'), [Text.Encoding]::UTF8)
$jp = [IO.File]::ReadAllText((Join-Path $root 'prompts\cat_translate_to_jp.txt'), [Text.Encoding]::UTF8)
foreach ($case in @(@{ Name='English'; Text=$en }, @{ Name='Japanese'; Text=$jp })) {
    $text = [string]$case.Text
    Assert-FitFirst ($text -match '(?i)space budget') ($case.Name + ' template treats CHARACTER_TARGETS as a space budget')
    Assert-FitFirst ($text -match '(?i)shorten the wording, not the meaning') ($case.Name + ' template shortens wording instead of facts')
    Assert-FitFirst ($text -match '(?i)no target') ($case.Name + ' template preserves a normal path for untargeted items')
    Assert-FitFirst ($text -match '(?i)primary layout goal') ($case.Name + ' template makes fitting the primary targeted-item goal')
    Assert-FitFirst (-not ($text -match '(?i)Do not abbreviate, summarize, compress, merge, omit, or add information\.')) ($case.Name + ' template no longer globally forbids compact translation')
}

if ($script:Failures -gt 0) { throw "Fit-first prompt regression failed: $script:Failures assertion(s)." }
Write-Host 'Fit-first prompt regression passed.' -ForegroundColor Green
