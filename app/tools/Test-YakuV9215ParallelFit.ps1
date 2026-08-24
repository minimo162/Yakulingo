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
Check ($translation.Contains("`$staleHandle[0].Lease['abandoned']=`$true") -and $translation.Contains('$replacementState=[hashtable]::Synchronized(') -and $translation.Contains('$handles.Add((& $startWorker $staleWorker $replacementState $replacementLease))')) 'expired lease abandons one worker incarnation and starts its replacement with isolated state'
Check ($translation.Contains('finally{') -and $translation.Contains('Close-YakuCopilotWorkerPages')) 'normal and exceptional exits share worker cleanup'
Check ($budget.Contains('Local\YakuLingo-CopilotBudget') -and $budget.Contains('WaitOne')) 'Copilot usage writes are protected by a named mutex'
Check ($budget.Contains('YakuCopilotBudgetLockTimeoutMilliseconds = 30000') -and $budget.Contains('budget lock timeout')) 'budget lock waits longer and reports any skipped record'
Check ($translation.Contains("`$state['alive_at']") -and $client.Contains("`$ProgressState['alive_at']")) 'worker liveness uses a dedicated heartbeat refreshed by the response wait'
Check ($translation.Contains('continuing serially') -and $translation.Contains("`$Context.Remove('WorkerPages')")) 'worker-window preparation failure falls back to the serial pipeline'
Check ($client.Contains('COPILOT_WORKER_TARGET_LOST') -and $client.Contains('COPILOT_WORKER_TARGET_OWNERSHIP_VIOLATION')) 'worker target recovery fails closed instead of adopting another window'
Check ($project.Contains('New-YakuCatAcronymUsageIndex') -and $project.Contains('-AcronymIndex $acronymIndex')) 'export preflight builds one acronym index and reuses it for every row'
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
$acronymIndex=New-YakuCatAcronymUsageIndex -Project $acronymProject
Check ($acronymIndex['上期'].Count -eq 2 -and (Test-YakuCatAcronymInconsistent -Project $acronymProject -Segment $acronymProject.Segments[1] -AcronymIndex $acronymIndex)) 'precomputed acronym index preserves the inconsistency verdict'
$numericSegment=[pscustomobject]@{FitPipeline=[pscustomobject]@{abbreviation_used=$true}}
Check ((ConvertTo-YakuCatAcronymNumericQcText -Segment $numericSegment -Source '上期売上' -Target '1H sales') -eq 'H sales') 'numeric QC ignores only the supported abbreviation digit'

$mergeWarnings=New-Object System.Collections.Generic.List[object]
$mergeParent=@{CopilotCalls=0}
$merged=Merge-YakuCatParallelResults -Results @(
    [pscustomobject]@{Packet=4;Map=@{};Warnings=@('stale');Context=@{CopilotCalls=1};Error='stopped worker error'},
    [pscustomobject]@{Packet=4;Map=@{17='replacement success'};Warnings=@('kept');Context=@{CopilotCalls=1};Error=''}
) -Warnings $mergeWarnings -Parent $mergeParent
$mergedErrors=[object[]]$merged.Errors
$mergedWarningItems=[object[]]$mergeWarnings.ToArray()
Check ($mergedErrors.Count -eq 0 -and [string]($merged.Map[17]) -eq 'replacement success' -and $mergedWarningItems.Count -eq 1) 'a successful replacement result suppresses the abandoned packet error'

$budgetReady=New-Object System.Threading.ManualResetEventSlim($false)
$budgetHolder=[powershell]::Create()
$null=$budgetHolder.AddScript({
    param($Ready)
    $held=New-Object System.Threading.Mutex($false,'Local\YakuLingo-CopilotBudget')
    $taken=$false
    try{$taken=$held.WaitOne(5000);$Ready.Set();Start-Sleep -Milliseconds 800}finally{if($taken){$held.ReleaseMutex()};$held.Dispose()}
}).AddArgument($budgetReady)
$budgetAsync=$budgetHolder.BeginInvoke()
$originalBudgetLog=${function:Write-YakuLog}
$originalBudgetTimeout=$script:YakuCopilotBudgetLockTimeoutMilliseconds
try{
    $null=$budgetReady.Wait(2000)
    $script:budgetTimeoutWarning=''
    ${function:Write-YakuLog}={param($Message,$Level) $script:budgetTimeoutWarning=[string]$Message}
    $script:YakuCopilotBudgetLockTimeoutMilliseconds=50
    $budgetResult=Add-YakuCopilotCall -Now ([datetime]'2026-08-24T12:00:00')
    Check ($budgetResult -eq 0 -and $script:budgetTimeoutWarning -match 'budget lock timeout') 'budget mutex timeout is observable instead of silently dropping the call record'
}finally{
    $script:YakuCopilotBudgetLockTimeoutMilliseconds=$originalBudgetTimeout
    ${function:Write-YakuLog}=$originalBudgetLog
    try{$null=$budgetHolder.EndInvoke($budgetAsync)}catch{}
    $budgetHolder.Dispose();$budgetReady.Dispose()
    Remove-Variable -Name budgetTimeoutWarning -Scope Script -ErrorAction SilentlyContinue
}

$originalWorkerPages=${function:New-YakuCopilotWorkerPages}
$originalWorkerLog=${function:Write-YakuLog}
try{
    ${function:New-YakuCopilotWorkerPages}={param($Settings,[int]$Count) throw 'worker-window-probe'}
    $workerLog=''
    ${function:Write-YakuLog}={param($Message,$Level) $script:workerLog=[string]$Message}
    $serialContext=@{WorkerPages=@('stale')}
    $serialPages=@(Get-YakuCatFitWorkerPagesOrSerial -Settings ([pscustomobject]@{}) -WorkerCount 4 -Context $serialContext)
    Check ($serialPages.Count -eq 0 -and -not $serialContext.ContainsKey('WorkerPages') -and $workerLog -match 'continuing serially') 'worker-window creation failure clears parallel state and returns the serial route'
}finally{
    ${function:New-YakuCopilotWorkerPages}=$originalWorkerPages
    ${function:Write-YakuLog}=$originalWorkerLog
}

$stageProgress=[hashtable]::Synchronized(@{})
$oldWorker=[hashtable]::Synchronized(@{worker=1;state='lease_expired';items=@(1)})
$replacementWorker=[hashtable]::Synchronized(@{worker=1;state='running';items=@(2)})
Set-YakuCatPipelineStageProgress -ProgressState $stageProgress -Stage 'draft' -WorkerStates @($oldWorker,$replacementWorker)
Check (@($stageProgress['worker_progress']).Count -eq 1 -and [string]$stageProgress['worker_progress'][0].state -eq 'running') 'progress snapshot exposes only the newest incarnation for a worker slot'

$heartbeat=[hashtable]::Synchronized(@{progress=0})
Set-YakuCopilotProgressPhase -ProgressState $heartbeat -Phase 'sent' -Label 'wait' -Progress 1
Check (-not [string]::IsNullOrWhiteSpace([string]$heartbeat['alive_at'])) 'response phase refreshes the dedicated worker heartbeat'

$originalPages=${function:Get-YakuCdpPages}
$originalLog=${function:Write-YakuLog}
try{
    ${function:Get-YakuCdpPages}={param([int]$Port) return @([pscustomobject]@{id='other-worker';type='page';url='https://m365.cloud.microsoft/chat/';webSocketDebuggerUrl='ws://other'})}
    ${function:Write-YakuLog}={param($Message,$Level)}
    $script:YakuWorkerIndex=2
    $script:YakuCopilotTargetCache=[pscustomobject]@{Port=9433;TargetId='pinned-worker'}
    $lost=''
    try{$null=Get-YakuCopilotPage -Port 9433}catch{$lost=[string]$_.Exception.Message}
    Check ($lost -match '^COPILOT_WORKER_TARGET_LOST:' -and $lost -match 'pinned-worker') 'lost worker target cannot fall back to another Copilot page'
    $ownership=''
    try{Save-YakuCopilotTargetRuntimeCache -Port 9433 -TargetId 'other-worker'}catch{$ownership=[string]$_.Exception.Message}
    Check ($ownership -match '^COPILOT_WORKER_TARGET_OWNERSHIP_VIOLATION:') 'worker cannot replace its in-memory target ownership pin'
}finally{
    Remove-Variable -Name YakuWorkerIndex -Scope Script -ErrorAction SilentlyContinue
    $script:YakuCopilotTargetCache=$null
    ${function:Get-YakuCdpPages}=$originalPages
    ${function:Write-YakuLog}=$originalLog
}

$originalAcronymUsages=${function:Get-YakuCatAcronymUsages}
$script:acronymUsageCalls=0
try{
    ${function:Get-YakuCatAcronymUsages}={
        param([AllowNull()][string]$Source,[AllowNull()][string]$Target)
        $script:acronymUsageCalls++
        return (& $originalAcronymUsages -Source $Source -Target $Target)
    }
    $largeProject=[pscustomobject]@{Segments=@(1..1000|ForEach-Object{[pscustomobject]@{SegmentId=[string]$_;Text='上期売上';Translation=$(if($_%2){'1H sales'}else{'H1 sales'})}})}
    $largeIndex=New-YakuCatAcronymUsageIndex -Project $largeProject
    foreach($segment in @($largeProject.Segments)){$null=Test-YakuCatAcronymInconsistent -Project $largeProject -Segment $segment -AcronymIndex $largeIndex}
    Check ($script:acronymUsageCalls -eq 2000) '1,000-row acronym validation performs one index scan plus one constant-size row lookup'
}finally{
    ${function:Get-YakuCatAcronymUsages}=$originalAcronymUsages
    Remove-Variable -Name acronymUsageCalls -Scope Script -ErrorAction SilentlyContinue
}

$parseErrors=New-Object System.Collections.Generic.List[object]
foreach($path in @('src\CopilotClient.ps1','src\CopilotBudget.ps1','src\CatTranslation.ps1','src\CatProject.ps1','src\Runtime.ps1','src\Server.ps1','src\Settings.ps1')){
    $tokens=$null;$errors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $path),[ref]$tokens,[ref]$errors)
    foreach($error in @($errors)){$parseErrors.Add([pscustomobject]@{Path=$path;Message=$error.Message})|Out-Null}
}
Check ($parseErrors.Count -eq 0) 'all changed PowerShell modules parse cleanly'

if($fail){Write-Host ('Issue 144 parallel fit regression failed: '+$fail);exit 1}
Write-Host 'Issue 144 parallel fit regression passed.'
