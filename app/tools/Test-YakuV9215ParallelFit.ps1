$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$fail=0
function Check([bool]$Condition,[string]$Message){if($Condition){Write-Host ('  ok   '+$Message)}else{Write-Host ('  FAIL '+$Message);$script:fail++}}
foreach($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','EdgeLaunch.ps1','CopilotBudget.ps1','CopilotClient.ps1','PromptBuilder.ps1','BriefStyle.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CatProject.ps1')){. (Join-Path (Join-Path $root 'src') $name)}

Check ((Get-YakuCatCopilotMaxWorkers ([pscustomobject]@{})) -eq 4) 'parallel CAT defaults to four Copilot workers'
Check ((Get-YakuCatCopilotMaxWorkers ([pscustomobject]@{cat_copilot_max_workers=0})) -eq 1) 'worker count is clamped to one'
Check ((Get-YakuCatCopilotMaxWorkers ([pscustomobject]@{cat_copilot_max_workers=99})) -eq 8) 'worker count is clamped to eight'

$items=1..9|ForEach-Object{[pscustomobject]@{Index=$_}}
$packets=@(Split-YakuCatWorkerPackets -Items $items -Workers 4)
$packetIds=@($packets|ForEach-Object{@($_.Ids)})
Check ($packets.Count -eq 5 -and $packetIds.Count -eq 9) 'worker queue splits work into stealable packets without losing rows'
Check ((@($packetIds|Sort-Object -Unique)-join ',') -eq '1,2,3,4,5,6,7,8,9') 'every row belongs to exactly one initial packet'

$client=[IO.File]::ReadAllText((Join-Path $root 'src\CopilotClient.ps1'))
$translation=[IO.File]::ReadAllText((Join-Path $root 'src\CatTranslation.ps1'))
$budget=[IO.File]::ReadAllText((Join-Path $root 'src\CopilotBudget.ps1'))
$server=[IO.File]::ReadAllText((Join-Path $root 'src\Server.ps1'))
$project=[IO.File]::ReadAllText((Join-Path $root 'src\CatProject.ps1'))
$ui=[IO.File]::ReadAllText((Join-Path $root 'www\assets\cat.js'))
$template=[IO.File]::ReadAllText((Join-Path $root 'config\settings.template.json'))|ConvertFrom-Json
$compress=[IO.File]::ReadAllText((Join-Path $root 'prompts\cat_fit_compress_to_en.txt'))

Check ($template.cat_copilot_max_workers -eq 4) 'distributed settings expose the four-worker default'
Check ($client.Contains('newWindow=$true') -and $client.Contains('(48*$worker)')) 'workers use separate offset top-level windows'
Check ($client.Contains("'Target.closeTarget'") -and $client.Contains('for ($worker = 1; $worker -lt $list.Count; $worker++)')) 'cleanup closes only created worker windows'
Check ($translation.Contains('ConcurrentQueue[int]') -and $translation.Contains('ConcurrentDictionary[int,int]')) 'parallel stages use a shared queue and packet-attempt ledger'
Check ($translation.Contains('$Queue.Enqueue([int]$packetIndex)') -and $translation.Contains('CAT worker packet requeued.')) 'one failed packet is leased back to the queue'
Check ($translation.Contains('Test-YakuCopilotLimitError -Message $errorMessage')) 'rate-limit failures are never requeued'
Check ($translation.Contains('CAT worker lease expired; packet requeued.') -and $translation.Contains('$handles.Add((& $startWorker $staleWorker $state))')) 'expired worker lease requeues its packet and starts a replacement worker'
Check ($translation.Contains('finally{') -and $translation.Contains('Close-YakuCopilotWorkerPages')) 'normal and exceptional exits share worker cleanup'
Check ($budget.Contains('Local\YakuLingo-CopilotBudget') -and $budget.Contains('WaitOne')) 'Copilot usage writes are protected by a named mutex'
Check ($server.Contains('worker_progress') -and $server.Contains('fit_pipeline')) 'job and completed-line metadata cross the server contract'
Check ($ui.Contains('worker_progress') -and $ui.Contains('fit_pipeline')) 'CAT UI renders worker progress and fit completion metadata'
Check ($compress.Contains('PipelineCandidateCount distinct alternatives in one numbered item') -and $compress.Contains('⟦YAKU_ALT⟧')) 'candidate alternatives are requested in one Copilot call'
Check ($project.Contains("'acronym-inconsistency'") -and $project.Contains('abbreviation_used')) 'document QC reports inconsistent abbreviation use'

$acronymItem=[pscustomobject]@{Index=3;Text='上期売上';MaskedText='上期売上';OriginalText='上期売上';MaxChars=8;Terminology=@()}
Check (Test-YakuCatAcronymCandidate -Item $acronymItem -Translation '1H sales') 'known digitful abbreviation is accepted after semantic numeric normalization'
$acronymProject=[pscustomobject]@{Segments=@(
    [pscustomobject]@{SegmentId='a';Text='上期売上';Translation='1H sales'},
    [pscustomobject]@{SegmentId='b';Text='上期利益';Translation='H1 profit'}
)}
Check (Test-YakuCatAcronymInconsistent -Project $acronymProject -Segment $acronymProject.Segments[0]) 'document-wide QC detects two forms for the same source abbreviation'
$numericSegment=[pscustomobject]@{FitPipeline=[pscustomobject]@{abbreviation_used=$true}}
Check ((ConvertTo-YakuCatAcronymNumericQcText -Segment $numericSegment -Source '上期売上' -Target '1H sales') -eq 'H sales') 'numeric QC ignores only the supported abbreviation digit'

$parseErrors=New-Object System.Collections.Generic.List[object]
foreach($path in @('src\CopilotClient.ps1','src\CopilotBudget.ps1','src\CatTranslation.ps1','src\CatProject.ps1','src\Runtime.ps1','src\Server.ps1','src\Settings.ps1')){
    $tokens=$null;$errors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $path),[ref]$tokens,[ref]$errors)
    foreach($error in @($errors)){$parseErrors.Add([pscustomobject]@{Path=$path;Message=$error.Message})|Out-Null}
}
Check ($parseErrors.Count -eq 0) 'all changed PowerShell modules parse cleanly'

if($fail){Write-Host ('Issue 144 parallel fit regression failed: '+$fail);exit 1}
Write-Host 'Issue 144 parallel fit regression passed.'
