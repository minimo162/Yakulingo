$ErrorActionPreference='Stop'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT='1'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$fail=0
function Check([bool]$Condition,[string]$Message){if($Condition){Write-Host ('  ok   '+$Message)}else{Write-Host ('  FAIL '+$Message);$script:fail++}}
foreach($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','EdgeLaunch.ps1','CopilotBudget.ps1','CopilotClient.ps1','PromptBuilder.ps1','BriefStyle.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1')){. (Join-Path (Join-Path $root 'src') $name)}

$marker=' '+[char]0x27E6+'YAKU_FIT'+[char]0x27E7+' '
$parsed=Split-YakuCatCompressionResult ('Chosen'+$marker+'dropped=scope; need_chars=17')
Check ($parsed.Translation -eq 'Chosen' -and $parsed.Dropped -eq 'scope' -and $parsed.NeedChars -eq 17) 'fit marker metadata is parsed'
$missing=Split-YakuCatCompressionResult 'Markerless'
Check ($missing.Translation -eq 'Markerless' -and $missing.Dropped -eq 'unreported') 'markerless response stays usable and is marked unreported'
Check (Test-YakuCatBackJudgeRequiresRetry '  RETRY_REQUIRED: chosen') 'retry prefix survives leading whitespace from numbered parsing'
Check (Test-YakuCatBackJudgePassed ' PASS ') 'back judge accepts explicit PASS'
Check (-not (Test-YakuCatBackJudgePassed 'REVIEW_REQUIRED: missing output')) 'back judge rejects non-PASS review output'
Check (-not (Test-YakuCatBackJudgePassed 'looks good')) 'back judge rejects malformed output'

function New-YakuNumericMaskMap {
    param([string]$Text,[string]$Direction,[string]$Location,[switch]$AllowExistingTokens)
    return [pscustomobject]@{MaskedCount=$(if($Text -match '2 digits'){1}else{0})}
}
$warnings=New-Object System.Collections.Generic.List[object]
$safeContext=@{}
$safe=[pscustomobject]@{Index=1;PipelineClaims='claim [[N1]]'}
$unsafe=[pscustomobject]@{Index=2;PipelineClaims='claim grew by 2 digits'}
$kept=@(Get-YakuCatPromptSafePipelineItems -Items @($safe,$unsafe) -Warnings $warnings -Context $safeContext)
Check ($kept.Count -eq 1 -and $kept[0].Index -eq 1) 'unsafe model claim skips only its row'
Check (@($warnings|Where-Object{$_.Category -eq 'fit-backcheck-skipped'}).Count -eq 1) 'unsafe model claim leaves a visible advisory'

function Test-YakuNumericMaskIntegrity { return [pscustomobject]@{Ok=$true} }
$boundary=[pscustomobject]@{Index=3;Text='[[N1]]';OriginalText='原文';MaxChars=6;Terminology=@()}
Check (Test-YakuCatCompressionCandidate $boundary '123456') 'Length equal to MaxChars is accepted'
Check (-not (Test-YakuCatCompressionCandidate $boundary '1234567')) 'Length above MaxChars is rejected'
$exact=[pscustomobject]@{Index=4;Text='[[N1]]';OriginalText='売上高';MaxChars=20;Terminology=@([pscustomobject]@{enforcement='cell_exact';source='売上高';preferred='Net sales'})}
Check (-not (Test-YakuCatCompressionCandidate $exact 'Sales')) 'cell-exact mismatch is rejected'

$metadata=@{5=@{'first'=[pscustomobject]@{Dropped='first-drop'};'chosen'=[pscustomobject]@{Dropped='chosen-drop'}}}
Check ((Get-YakuCatSelectedCompressionMeta -Metadata $metadata -Index 5 -Translation 'chosen').Dropped -eq 'chosen-drop') 'selected candidate metadata follows selected text'

$compressPath=Join-Path $root 'prompts\cat_fit_compress_to_en.txt'
$template=[IO.File]::ReadAllText($compressPath,[Text.Encoding]::UTF8)
function Get-YakuPromptTemplate { param($Root,$Name) return $template }
function New-YakuFileSourceList { return 'protected source' }
function Get-YakuNumericRulesSection { return 'numeric rules' }
function New-YakuCatTerminologyRules { return 'term rules' }
function New-YakuCatPipelineData { return '[{"item":6,"max_chars":24}]' }
function Assert-YakuCatPromptHasNoUnmaskedValues {}
function Expand-YakuTemplate {
    param($Template,$Variables)
    foreach($key in @($Variables.Keys)){$Template=$Template.Replace(('{'+$key+'}'),[string]$Variables[$key])}
    return $Template
}
$promptItem=[pscustomobject]@{Index=6;MaxChars=24;PipelineStage='compress'}
$prompt=New-YakuCatPrompt -Root $root -Items @($promptItem) -Settings @{} -Direction 'to_en' -RequestId 'review'
foreach($rule in @('headline style','Never invent','report the required length')){Check ($prompt -match [regex]::Escape($rule)) ('expanded compress prompt contains '+$rule)}

$parent=@{AmountNotation='oku';BatchOrdinal=2;TotalBatches=9;TranslatedSoFar=3;UniqueTotal=12;CopilotCalls=0}
function Get-YakuCatPromptSafePipelineItems { param($Items,$Warnings,$Context) return @($Items) }
function Invoke-YakuTranslationBatchItems {
    param($Root,$Items,$Settings,$Direction,$MaxChars,$Warnings,$ProgressState,$Context,$Depth,$Reason)
    $Context.BatchOrdinal=[int]$Context.BatchOrdinal+1;$Context.TranslatedSoFar=[int]$Context.TranslatedSoFar+$Items.Count
    return @{1='done'}
}
$result=Invoke-YakuCatPipelineBatch $root @([pscustomobject]@{Index=1}) @{} 'to_en' 100 $warnings $null $parent
Check ($parent.BatchOrdinal -eq 3 -and $parent.TranslatedSoFar -eq 4 -and $parent.TotalBatches -eq 9) 'pipeline stages share one progress denominator'

function Assert-YakuCatProtectedItems {}
function Assert-YakuCatProtectedItemsMatchOriginal {}
$script:metricStatuses=New-Object System.Collections.Generic.List[string]
function Write-YakuCatFitMetrics { param($Root,$Context,$Status) $script:metricStatuses.Add([string]$Status)|Out-Null }
$alt=' '+[char]0x27E6+'YAKU_ALT'+[char]0x27E7+' '
$script:compressRound=0
$script:backJudgeRound=0
$script:backJudgeSawEnglish=$false
$script:stageCounts=@{}
function Invoke-YakuTranslationBatchItems {
    param($Root,$Items,$Settings,$Direction,$MaxChars,$Warnings,$ProgressState,$Context,$Depth,$Reason)
    $Context.BatchOrdinal=[int]$Context.BatchOrdinal+1
    $Context.TranslatedSoFar=[int]$Context.TranslatedSoFar+$Items.Count
    $stage=Get-YakuCatPipelineStage $Items
    if(-not $script:stageCounts.ContainsKey($stage)){$script:stageCounts[$stage]=0}
    $script:stageCounts[$stage]=[int]$script:stageCounts[$stage]+1
    $map=@{}
    foreach($item in @($Items)){
        if($stage -eq 'back_judge' -and $item.PSObject.Properties.Name -contains 'PipelineSelected'){$script:backJudgeSawEnglish=$true}
        $value=switch($stage){
            'draft' {'Long draft [[N1]]'}
            'compress' {
                $script:compressRound++
                'First [[N1]]'+$marker+'dropped=first; need_chars=0'+$alt+'Best [[N1]]'+$marker+'dropped=chosen; need_chars=0'
            }
            'retry' {'Retry [[N1]]'+$marker+'dropped=retry; need_chars=0'}
            'select' {'Best [[N1]]'}
            'back_reconstruct' {'claim [[N1]]'}
            'back_judge' {$script:backJudgeRound++;if($script:backJudgeRound -eq 1){'  RETRY_REQUIRED: Best [[N1]]'}else{'PASS'}}
        }
        $map[[int]$item.Index]=[string]$value
    }
    return $map
}
$pipelineWarnings=New-Object System.Collections.Generic.List[object]
$pipelineContext=@{BatchOrdinal=0;TotalBatches=0;TranslatedSoFar=0;UniqueTotal=1;CopilotCalls=0;CompletedMap=@{}}
$pipelineItem=[pscustomobject]@{Index=1;Text='source [[N1]]';MaskedText='source [[N1]]';OriginalText='source 123';NumericMaskMap=@{'[[N1]]'='123'};ProtectionContractVersion='cat-protection-v1';MaxChars=12;Terminology=@()}
$pipelineSettings=[pscustomobject]@{cat_fit_candidate_count=2}
$pipelineResult=Invoke-YakuCatTranslationItems -Root $root -Items @($pipelineItem) -Settings $pipelineSettings -Direction 'to_en' -MaxChars 1000 -Warnings $pipelineWarnings -Context $pipelineContext
Check ($pipelineResult[1] -eq 'Retry [[N1]]') 'full pipeline accepts numbered retry prefix and replaces the selected candidate once'
Check ($script:compressRound -eq 1 -and $script:stageCounts['select'] -eq 1 -and $script:stageCounts['retry'] -eq 1) 'candidate alternatives use one compression call and one selection call'
Check ($script:backJudgeRound -eq 2 -and $pipelineContext.FitBackCheckStatus[1] -eq 'retry-passed') 'retry replacement is back-checked again before acceptance'
Check (-not $script:backJudgeSawEnglish) 'difference judge never receives the English candidate'
Check (@($pipelineWarnings|Where-Object{$_.Category -in @('fit-backcheck-unverified','fit-backcheck-failed')}).Count -eq 0) 'verified retry does not leave a stale back-check warning'
$oneList=New-Object System.Collections.Generic.List[string];$oneList.Add('Only [[N1]]')|Out-Null
$oneCandidates=[pscustomobject]@{Lists=@{1=$oneList};Metadata=@{1=@{'Only [[N1]]'=[pscustomobject]@{Dropped='none'}}}}
$oneFinal=@{};$selectBefore=[int]$script:stageCounts['select']
$null=Invoke-YakuCatFitSelection $root @($pipelineItem) @{1='draft'} $oneCandidates $pipelineSettings 1000 $pipelineWarnings $null $pipelineContext $oneFinal
Check ($oneFinal[1] -eq 'Only [[N1]]' -and [int]$script:stageCounts['select'] -eq $selectBefore) 'one valid candidate skips the selection agent'
Check (($script:metricStatuses -join ',') -eq 'baseline,completed') 'job metrics records baseline and result phases'
$clientText=[IO.File]::ReadAllText((Join-Path $root 'src\CopilotClient.ps1'))
Check ($clientText.Contains('Copilot numbered wait failure recovered') -and $clientText.Contains('$waitOk = $true')) 'validated numbered salvage overrides the stale watcher failure'

$salvageId='issue142'
$nl=[Environment]::NewLine
$salvageTail='[[ID:1]] 1. source prompt'+$nl+'YAKULINGO_END:'+$salvageId+$nl+$nl+'  Copilot said:  '+$nl+'RETRY_REQUIRED: chosen'+$nl+'YAKULINGO_END:'+$salvageId
$salvaged=Get-YakuNumberedMainTailSalvageText -Tail $salvageTail -RequestId $salvageId
Check ($salvaged.StartsWith('RETRY_REQUIRED: chosen') -and -not $salvaged.Contains('source prompt')) 'mainTail salvage keeps only the latest Copilot answer block'

$cleaned=Clean-YakuCopilotAnswer -Text ('source prompt'+$nl+$nl+'  Copilot said:  '+$nl+'RETRY_REQUIRED: chosen') -RequestId '' -PreserveEndMarker
Check ($cleaned -eq 'RETRY_REQUIRED: chosen') 'common Copilot answer cleaning removes prompt text before the latest assistant boundary'

if($fail){Write-Host ('Issue 142 regression failed: '+$fail);exit 1}
Write-Host 'Issue 142 agentic fit regression passed.'
