param(
    [string[]]$WorkerCounts = @('1','2','4'),
    [int]$Requests = 4,
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:YakuRoot = $Root
. (Join-Path $Root 'src\SrcModules.ps1')
foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }

function Write-ProbeStep {
    param([string]$Text)
    Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date),$Text)
}

$settings = Read-YakuSettings -Root $Root
$summary = New-Object System.Collections.Generic.List[object]
$workerScript = {
    param($Root,$Settings,$Page,$Queue,$Results,$WorkerIndex)
    $ErrorActionPreference = 'Stop'
    $script:YakuRoot = $Root
    . (Join-Path $Root 'src\SrcModules.ps1')
    foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }
    $port = Get-YakuCdpPort -Settings $Settings
    $null = Save-YakuCopilotPageTarget -Port $port -Page $Page
    $requestIndex = 0
    while ($Queue.TryDequeue([ref]$requestIndex)) {
        $started = Get-Date
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-YakuCopilotAutomationSelfTest -Settings $Settings
        $sw.Stop()
        $message = [string]$result.Message
        $response = [string]$result.Response
        $Results.Add([pscustomobject]@{
            worker=$WorkerIndex; request=$requestIndex; ok=[bool]$result.Ok
            elapsed_ms=[int]$sw.ElapsedMilliseconds; started_at=$started.ToUniversalTime().ToString('o')
            finished_at=(Get-Date).ToUniversalTime().ToString('o'); message=$message
            rate_limited=[bool](($message+' '+$response) -match '(?i)429|rate limit|too many requests|quota|wait a moment|少し時間をおいて|リクエストが多すぎ')
        })
    }
}

foreach ($requestedWorkers in @($WorkerCounts | ForEach-Object { @([string]$_ -split ',') })) {
    $workers = [Math]::Max(1,[Math]::Min(8,[int]$requestedWorkers))
    $pages = $null
    $handles = New-Object System.Collections.Generic.List[object]
    try {
        Write-ProbeStep "Preparing $workers worker(s) for $Requests protected self-test requests."
        $pages = @(New-YakuCopilotWorkerPages -Settings $settings -Count $workers)
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[int]'
        for ($i=0;$i -lt $Requests;$i++) { $queue.Enqueue($i) }
        $results = New-Object 'System.Collections.Concurrent.ConcurrentBag[object]'
        $overall = [System.Diagnostics.Stopwatch]::StartNew()
        for ($worker=0;$worker -lt $workers;$worker++) {
            $ps = [powershell]::Create()
            $null = $ps.AddScript($workerScript.ToString()).AddArgument($Root).AddArgument($settings).AddArgument($pages[$worker]).AddArgument($queue).AddArgument($results).AddArgument($worker)
            $handles.Add([pscustomobject]@{PowerShell=$ps;Async=$ps.BeginInvoke();Worker=$worker}) | Out-Null
        }
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while (@($handles.ToArray() | Where-Object {-not $_.Async.IsCompleted}).Count -gt 0) {
            Start-Sleep -Seconds 2
            Write-ProbeStep ("workers={0} completed={1}/{2}" -f $workers,$results.Count,$Requests)
            if ((Get-Date) -gt $deadline) {
                foreach ($handle in @($handles.ToArray())) { try {$handle.PowerShell.Stop()} catch {} }
                throw "Concurrency probe timed out for workers=$workers."
            }
        }
        foreach ($handle in @($handles.ToArray())) { $null=$handle.PowerShell.EndInvoke($handle.Async);$handle.PowerShell.Dispose() }
        $overall.Stop()
        $rows = @($results.ToArray() | Sort-Object request)
        foreach ($row in $rows) { Write-Host ('  worker={0} request={1} ok={2} elapsed={3:N1}s rateLimited={4} message={5}' -f $row.worker,$row.request,$row.ok,($row.elapsed_ms/1000),$row.rate_limited,$row.message) }
        $sumSeconds = [double](($rows | Measure-Object elapsed_ms -Sum).Sum)/1000.0
        $wallSeconds = [double]$overall.Elapsed.TotalSeconds
        $record = [pscustomobject]@{
            workers=$workers;requests=$Requests;successes=@($rows|Where-Object{$_.ok}).Count
            rate_limits=@($rows|Where-Object{$_.rate_limited}).Count;wall_seconds=[Math]::Round($wallSeconds,2)
            request_seconds_sum=[Math]::Round($sumSeconds,2);overlap=[Math]::Round($(if($wallSeconds -gt 0){$sumSeconds/$wallSeconds}else{0}),2)
        }
        $summary.Add($record)|Out-Null
        Write-ProbeStep ($record|ConvertTo-Json -Compress)
    } finally {
        foreach ($handle in @($handles.ToArray())) { try {$handle.PowerShell.Dispose()} catch {} }
        if ($pages) { try {$null=Close-YakuCopilotWorkerPages -Settings $settings -Pages $pages} catch {Write-Warning $_.Exception.Message} }
    }
}

$output = [pscustomobject]@{measured_at=(Get-Date).ToUniversalTime().ToString('o');results=@($summary.ToArray())}
$outputPath = Join-Path (Get-YakuSubDir 'runtime') ('copilot-concurrency-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
Write-YakuJsonAtomic -Path $outputPath -Value $output -Depth 8
Write-Host ('RESULT_PATH=' + $outputPath)
$output | ConvertTo-Json -Depth 8
