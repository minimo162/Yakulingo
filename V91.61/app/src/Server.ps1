[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$OpenBrowser,
    [switch]$Admin
)

$ErrorActionPreference = 'Stop'
$script:YakuRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

. (Join-Path $PSScriptRoot 'Paths.ps1')
. (Join-Path $PSScriptRoot 'Runtime.ps1')
. (Join-Path $PSScriptRoot 'Html.ps1')
. (Join-Path $PSScriptRoot 'Settings.ps1')
. (Join-Path $PSScriptRoot 'PromptBuilder.ps1')
. (Join-Path $PSScriptRoot 'EdgeLaunch.ps1')
. (Join-Path $PSScriptRoot 'CopilotClient.ps1')
. (Join-Path $PSScriptRoot 'Translation.ps1')
. (Join-Path $PSScriptRoot 'FileProcessors.ps1')
. (Join-Path $PSScriptRoot 'FileTranslation.ps1')
. (Join-Path $PSScriptRoot 'Corpus.ps1')
. (Join-Path $PSScriptRoot 'CorpusSearch.ps1')
. (Join-Path $PSScriptRoot 'CorpusReference.ps1')
. (Join-Path $PSScriptRoot 'BriefStyle.ps1')
. (Join-Path $PSScriptRoot 'CellSegments.ps1')
. (Join-Path $PSScriptRoot 'CorpusPairs.ps1')
. (Join-Path $PSScriptRoot 'CatProject.ps1')

$script:YakuBuildId = Assert-YakuBuildIdentity -Root $script:YakuRoot -ExpectedBuildId (Get-YakuBuildId)
# V91.61: 管理画面。既定は無効で、無効なら管理用の経路を一切登録しない。
$script:YakuAdminMode = [bool]$Admin
$script:ServerRunning = $true
$script:YakuTranslateJobs = [hashtable]::Synchronized(@{})
$script:YakuTranslateJobHandles = [hashtable]::Synchronized(@{})
$script:YakuActiveTranslateJobId = ''
$script:YakuTranslateJobRetentionMinutes = 30
$script:YakuTranslateJobKeepCompleted = 0
$script:YakuWarmRunspace = $null
$script:YakuWarmRunspaceBuild = $null
$script:YakuWarmupLastGood = $null
$script:YakuUploadHandles = [hashtable]::Synchronized(@{})
$script:YakuSessionToken = New-YakuSecureToken -ByteLength 32
$script:YakuInstanceId = [guid]::NewGuid().ToString('N')
$script:YakuProcessStartedAt = Get-YakuProcessStartTimeIso -Id $PID
$script:YakuInstanceMutex = $null

function Enter-YakuSingleInstance {
    $identity = [Environment]::UserName + '|' + [Environment]::UserDomainName
    $hash = Get-YakuSha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($identity))
    $name = 'Local\YakuLingo-' + $hash.Substring(0, 24)
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0, $false) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if ($acquired) { $script:YakuInstanceMutex = $mutex; return $true }

    $mismatchMessage = ''
    try {
        $runtimePath = Join-Path (Get-YakuSubDir 'runtime') 'server.json'
        $existing = Read-YakuJsonFile -Path $runtimePath
        if ($existing -and (Test-YakuProcessIdentity -Id ([int]$existing.pid) -StartTimeUtc ([string]$existing.process_started_at))) {
            Write-Host "前回のYakuLingoプロセス（PID=$([int]$existing.pid)）が残っています。安全な停止を試みます。" -ForegroundColor Yellow
            $uri = [System.Uri]([string]$existing.url)
            if ($uri.Scheme -eq 'http' -and $uri.Host -eq '127.0.0.1') {
                $probe = Invoke-RestMethod -UseBasicParsing -Uri ([string]$existing.url + 'api/instance') -TimeoutSec 2
                if ($probe -and [string]$probe.instance_id -eq [string]$existing.instance_id) {
                    $existingBuildId = [string]$probe.build_id
                    if (-not [string]::Equals($existingBuildId, [string]$script:YakuBuildId, [System.StringComparison]::Ordinal)) {
                        if ([string]::IsNullOrWhiteSpace($existingBuildId)) { $existingBuildId = '旧版（識別子なし）' }
                        $stopped = $false
                        try {
                            if (-not [string]::IsNullOrWhiteSpace([string]$existing.session_token)) {
                                Invoke-RestMethod -UseBasicParsing -Method Post -Uri ([string]$existing.url + 'shutdown') -Headers @{ 'X-Yaku-Session' = [string]$existing.session_token; 'Origin' = ([string]$existing.url).TrimEnd('/'); 'Referer' = [string]$existing.url } -ContentType 'application/json' -Body '{}' -TimeoutSec 3 | Out-Null
                                Start-Sleep -Milliseconds 800
                                $stopped = -not (Test-YakuProcessIdentity -Id ([int]$existing.pid) -StartTimeUtc ([string]$existing.process_started_at))
                            }
                        } catch {}
                        if ($stopped) { Write-Host '前回プロセスを停止しました。もう一度起動してください。' -ForegroundColor Green }
                        $mismatchMessage = "別バージョンのYakuLingoが起動中です（起動中=$existingBuildId、今回=$($script:YakuBuildId)、PID=$([int]$existing.pid)）。安全停止できない場合は、該当PowerShellプロセスを終了してから再実行してください。"
                    } else {
                        try { Start-Process ([string]$existing.url) | Out-Null } catch {}
                        $mutex.Dispose()
                        return $false
                    }
                }
            }
        }
    } catch {}
    $mutex.Dispose()
    if (-not [string]::IsNullOrWhiteSpace($mismatchMessage)) { throw $mismatchMessage }
    throw '別のYakuLingoプロセスが起動中ですが、既存画面を安全に確認できませんでした。既存プロセスを終了してから再実行してください。'
}

function Exit-YakuSingleInstance {
    if ($script:YakuInstanceMutex) {
        try { $script:YakuInstanceMutex.ReleaseMutex() } catch {}
        try { $script:YakuInstanceMutex.Dispose() } catch {}
        $script:YakuInstanceMutex = $null
    }
}

function Recover-YakuInterruptedJobs {
    $jobsDir = Get-YakuSubDir 'jobs'
    $latest = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $jobsDir -Recurse -Filter 'state.json' -File -ErrorAction SilentlyContinue)) {
        $saved = Read-YakuJsonFile -Path $file.FullName
        if ($null -eq $saved -or [string]::IsNullOrWhiteSpace([string]$saved.id)) { continue }
        $state = [hashtable]::Synchronized(@{})
        foreach ($prop in @($saved.PSObject.Properties)) { $state[[string]$prop.Name] = $prop.Value }
        $state['state_path'] = $file.FullName
        $mode = [string]$state['mode']
        if ($mode -in @('queued','opening','extracting','translating','writing','validating','publishing','working','cancelling')) {
            try {
                $workerPid = [int]$state['worker_pid']; $workerStarted = [string]$state['worker_started_at']
                if (Test-YakuProcessIdentity -Id $workerPid -StartTimeUtc $workerStarted) { Stop-Process -Id $workerPid -Force -ErrorAction Stop }
            } catch { try { Write-YakuLog "Recovery worker stop failed. jobId=$($state['id']) error=$($_.Exception.Message)" 'WARN' } catch {} }
            try {
                $excelPid = [int]$state['excel_pid']; $excelStarted = [string]$state['excel_started_at']
                if (Test-YakuProcessIdentity -Id $excelPid -StartTimeUtc $excelStarted) { Stop-Process -Id $excelPid -Force -ErrorAction Stop }
            } catch { try { Write-YakuLog "Recovery Excel stop failed. jobId=$($state['id']) error=$($_.Exception.Message)" 'WARN' } catch {} }
            $state['mode']='interrupted'; $state['label']='Interrupted'; $state['class']='warn'; $state['detail']='前回の異常終了により処理を中断しました。'; $state['error_code']='RECOVERED_INTERRUPTED_JOB'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''
            try { Write-YakuProgressStateFile -ProgressState $state } catch {}
            try { $candidate = Join-Path (Get-YakuSubDir 'outputs') ('.yakulingo-job-' + [string]$state['id']); if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        }
        $resultPath = Join-Path $file.DirectoryName 'result.json'
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) { try { $state['result_json'] = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 } catch {} }
        $script:YakuTranslateJobs[[string]$state['id']] = $state
        $stamp = Get-YakuTranslationJobStateDate -State $state
        if ($null -eq $latest -or $stamp -gt $latest.Stamp) { $latest = [pscustomobject]@{ Id=[string]$state['id']; Stamp=$stamp } }
    }
    if ($latest) { $script:YakuActiveTranslateJobId = [string]$latest.Id }
}


function Get-YakuCopilotWarmupStatusPath {
    try { return (Join-Path (Get-YakuSubDir 'runtime') 'copilot-warmup.json') }
    catch { return (Join-Path ([System.IO.Path]::GetTempPath()) 'yakulingo-copilot-warmup.json') }
}

function Write-YakuCopilotWarmupStatus {
    param(
        [Parameter(Mandatory=$true)][string]$Mode,
        [Parameter(Mandatory=$true)][string]$Label,
        [string]$Class = 'idle',
        [string]$Detail = '',
        [bool]$Ready = $false
    )
    $path = Get-YakuCopilotWarmupStatusPath
    $json = [pscustomobject]@{
        ready = [bool]$Ready
        mode = $Mode
        label = $Label
        class = $Class
        detail = $Detail
        updated_at = (Get-Date).ToString('s')
    } | ConvertTo-Json -Depth 8
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $dir = Split-Path -Parent $path
            if (!(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $tmp = Join-Path $dir ("copilot-warmup.{0}.tmp" -f $PID)
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
            Move-Item -LiteralPath $tmp -Destination $path -Force
            return $true
        } catch {
            if ($attempt -eq 5) {
                try { Write-YakuLog "Failed to write Copilot warmup status after $attempt attempts: $($_.Exception.Message)" 'WARN' } catch {}
                return $false
            }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
    return $false
}

function Read-YakuCopilotWarmupStatus {
    if ($env:YAKULINGO_MOCK -eq '1') {
        return [pscustomobject]@{ ready=$true; mode='mock'; label='Mock mode'; class='warn'; detail='Copilot is not called.'; updated_at=(Get-Date).ToString('s') }
    }
    $path = Get-YakuCopilotWarmupStatusPath
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = $null
            try {
                $reader = New-Object System.IO.StreamReader($fs, $true)
                $raw = $reader.ReadToEnd()
            } finally {
                if ($reader) { $reader.Dispose() } else { $fs.Dispose() }
            }
            if (![string]::IsNullOrWhiteSpace($raw)) {
                $status = $raw | ConvertFrom-Json
                $script:YakuWarmupLastGood = $status
                return $status
            }
        }
    } catch {
        try { Write-YakuLog "Failed to read Copilot warmup status: $($_.Exception.Message)" 'WARN' } catch {}
    }
    if ($null -ne $script:YakuWarmupLastGood) { return $script:YakuWarmupLastGood }
    return [pscustomobject]@{ ready=$false; mode='not-started'; label='Preparing Copilot'; class='idle'; detail='Copilot preparation has not started yet.'; updated_at='' }
}

function Start-YakuCopilotWarmup {
    if ($env:YAKULINGO_MOCK -eq '1') {
        $null = Write-YakuCopilotWarmupStatus -Mode 'mock' -Label 'Mock mode' -Class 'warn' -Detail 'Copilot is not called.' -Ready $true
        return
    }
    $statusPath = Get-YakuCopilotWarmupStatusPath
    $null = Write-YakuCopilotWarmupStatus -Mode 'starting' -Label 'Preparing Copilot' -Class 'warn' -Detail 'Opening Microsoft Edge and M365 Copilot.' -Ready $false
    $worker = Join-Path $script:YakuRoot 'tools\Prepare-Copilot.ps1'
    if (!(Test-Path -LiteralPath $worker -PathType Leaf)) {
        $null = Write-YakuCopilotWarmupStatus -Mode 'error' -Label 'Copilot preparation failed' -Class 'warn' -Detail 'Prepare-Copilot.ps1 was not found.' -Ready $false
        return
    }
    try {
        $psExe = Join-Path $PSHOME 'powershell.exe'
        if (!(Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        $quote = { param([string]$v) '"' + ($v -replace '"','\"') + '"' }
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -Root {1} -StatusPath {2} -TimeoutSeconds 900' -f (& $quote $worker), (& $quote $script:YakuRoot), (& $quote $statusPath)
        Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        Write-YakuLog "Copilot warmup worker started. status=$statusPath worker=$worker" 'INFO'
    } catch {
        $null = Write-YakuCopilotWarmupStatus -Mode 'error' -Label 'Copilot preparation failed' -Class 'warn' -Detail $_.Exception.Message -Ready $false
        Write-YakuLog "Failed to start Copilot warmup worker: $($_.Exception.Message)" 'ERROR'
    }
}

function Get-YakuCopilotBadgeState {
    $warmup = Read-YakuCopilotWarmupStatus
    $ready = $false
    try { $ready = [bool]$warmup.ready } catch { $ready = $false }
    $label = if ($ready) { 'Ready' } elseif ($warmup.label) { [string]$warmup.label } else { 'Preparing Copilot' }
    $class = if ($ready) { 'ok' } elseif ($warmup.class) { [string]$warmup.class } else { 'idle' }
    $mode = if ($warmup.mode) { [string]$warmup.mode } else { 'not-started' }
    $detail = if ($warmup.detail) { [string]$warmup.detail } else { '' }
    return [pscustomobject]@{ ready=$ready; mode=$mode; label=$label; class=$class; detail=$detail; updated_at=($warmup.updated_at) }
}

function Get-YakuTranslateReadinessState {
    Update-YakuTranslationJobs
    $badge = Get-YakuCopilotBadgeState
    $ready = $false
    try { $ready = [bool]$badge.ready } catch { $ready = $false }

    $job = Get-YakuActiveTranslationJobState
    if ($job) {
        $jobMode = [string]$job['mode']
        $jobId = [string]$job['id']
        $progress = 0
        try { $progress = [int]$job['progress'] } catch { $progress = 0 }
        $detail = [string]$job['detail']
        $kind = [string]$job['kind']
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'text' }
        $phase = ''
        try { $phase = [string]$job['phase'] } catch { $phase = '' }
        if (Test-YakuTranslationJobRunning -State $job) {
            return [pscustomobject]@{ ready=$ready; canTranslate=$false; mode='working'; label=[string]$badge.label; class=[string]$badge.class; detail=$detail; updated_at=(Get-Date).ToString('s'); jobId=$jobId; progress=$progress; kind=$kind; phase=$phase; jobLabel=[string]$job['label'] }
        }
        if ($jobMode -eq 'done' -or $jobMode -eq 'completed_with_warnings') {
            return [pscustomobject]@{ ready=$ready; canTranslate=$ready; mode=$jobMode; label=[string]$badge.label; class=[string]$job['class']; detail=$detail; updated_at=(Get-Date).ToString('s'); jobId=$jobId; progress=100; kind=$kind; phase=$phase; jobLabel=[string]$job['label'] }
        }
        if ($jobMode -in @('error','failed','interrupted')) {
            return [pscustomobject]@{ ready=$ready; canTranslate=$ready; mode='error'; label=[string]$badge.label; class=[string]$badge.class; detail=$detail; updated_at=(Get-Date).ToString('s'); jobId=$jobId; progress=100; kind=$kind; phase=$phase; jobLabel=[string]$job['label'] }
        }
        if ($jobMode -eq 'cancelled') {
            return [pscustomobject]@{ ready=$ready; canTranslate=$ready; mode='cancelled'; label=[string]$badge.label; class=[string]$badge.class; detail=$detail; updated_at=(Get-Date).ToString('s'); jobId=$jobId; progress=100; kind=$kind; phase=$phase; jobLabel=[string]$job['label'] }
        }
    }

    return [pscustomobject]@{ ready=$ready; canTranslate=$ready; mode=[string]$badge.mode; label=[string]$badge.label; class=[string]$badge.class; detail=[string]$badge.detail; updated_at=($badge.updated_at); jobId=''; progress=0; kind='text'; phase=''; jobLabel='' }
}

function Convert-YakuReadinessStateToJson {
    param([Parameter(Mandatory=$true)]$State)
    $progress = 0
    try { $progress = [int]$State.progress } catch { $progress = 0 }
    $jobId = ''
    try { $jobId = [string]$State.jobId } catch { $jobId = '' }
    $kind = 'text'
    try { if ($State.PSObject.Properties.Name -contains 'kind') { $kind = [string]$State.kind } } catch { $kind = 'text' }
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'text' }
    $phase = ''
    try { if ($State.PSObject.Properties.Name -contains 'phase') { $phase = [string]$State.phase } } catch { $phase = '' }
    $jobLabel = ''
    try { if ($State.PSObject.Properties.Name -contains 'jobLabel') { $jobLabel = [string]$State.jobLabel } } catch { $jobLabel = '' }
    return ([ordered]@{
        ready = [bool]$State.ready
        canTranslate = [bool]$State.canTranslate
        mode = [string]$State.mode
        label = [string]$State.label
        class = [string]$State.class
        detail = [string]$State.detail
        updated_at = [string]$State.updated_at
        jobId = $jobId
        progress = $progress
        kind = $kind
        phase = $phase
        jobLabel = $jobLabel
    } | ConvertTo-Json -Depth 8 -Compress)
}

$script:YakuUiJobStatus = [pscustomobject]@{
    Mode = 'idle'
    Label = ''
    Class = 'idle'
    Detail = ''
    Updated = [datetime]::MinValue
}

function Set-YakuUiJobStatus {
    param(
        [Parameter(Mandatory=$true)][string]$Mode,
        [Parameter(Mandatory=$true)][string]$Label,
        [string]$Class = 'idle',
        [string]$Detail = ''
    )
    $script:YakuUiJobStatus = [pscustomobject]@{
        Mode = $Mode
        Label = $Label
        Class = $Class
        Detail = $Detail
        Updated = (Get-Date)
    }
}

function Get-YakuUiJobStatusHtml {
    $state = $script:YakuUiJobStatus
    if ($null -eq $state) { return $null }
    $mode = [string]$state.Mode
    if ($mode -eq 'preparing') {
        return "<span class='status-dot warn'></span><span>Preparing</span>"
    }
    if ($mode -eq 'ready') {
        return "<span class='status-dot ok'></span><span>Ready</span>"
    }
    if ($mode -eq 'login') {
        return "<span class='status-dot warn'></span><span>Login required</span>"
    }
    if ($mode -eq 'not-ready') {
        return "<span class='status-dot warn'></span><span>Not ready</span>"
    }
    if ($mode -eq 'working') { return $null }
    if ($mode -eq 'done') {
        return "<span class='status-dot ok'></span><span>Done</span>"
    }
    if ($mode -eq 'error') {
        return "<span class='status-dot warn'></span><span>Translation error</span>"
    }
    if ($mode -eq 'cancelled') {
        return "<span class='status-dot idle'></span><span>Cancelled</span>"
    }
    return $null
}

function Convert-YakuExceptionToUserMessage {
    param([AllowNull()]$ErrorRecord)
    $message = ''
    try {
        if ($ErrorRecord -and $ErrorRecord.Exception) { $message = [string]$ErrorRecord.Exception.Message }
        elseif ($ErrorRecord) { $message = [string]$ErrorRecord }
    } catch { $message = '不明なエラーが発生しました。' }
    if ([string]::IsNullOrWhiteSpace($message)) { return '不明なエラーが発生しました。' }
    $message = $message -replace '[\r\n\t]+', ' '
    $message = $message.Trim()
    # Do not push huge CDP diagnostic JSON into the UI. Full text is retained
    # only when the user has explicitly enabled full-text diagnostics.
    if ($message.Length -gt 520) { $message = $message.Substring(0, 520) + ' ... 詳細はログを確認してください。' }
    return $message
}

function Get-YakuTranslationJobStateValue {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory=$true)][string]$Key
    )
    if ($null -eq $State) { return $null }
    try {
        if ($State -is [System.Collections.IDictionary]) {
            try { if ($State.Contains($Key)) { return $State[$Key] } } catch {}
            try { if ($State.ContainsKey($Key)) { return $State[$Key] } } catch {}
            return $null
        }
    } catch {}
    try {
        $prop = $State.PSObject.Properties[$Key]
        if ($null -ne $prop) { return $prop.Value }
    } catch {}
    return $null
}

function Get-YakuTranslationJobStateDate {
    param(
        [AllowNull()]$State,
        [string[]]$Keys = @('completed_at', 'updated_at', 'created_at')
    )
    if ($null -eq $State) { return [datetime]::MinValue }
    foreach ($key in $Keys) {
        try {
            $rawValue = Get-YakuTranslationJobStateValue -State $State -Key ([string]$key)
            if ($null -eq $rawValue) { continue }
            if ($rawValue -is [datetime]) { return [datetime]$rawValue }
            $raw = [string]$rawValue
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($raw, [ref]$parsed)) { return $parsed }
        } catch {}
    }
    return [datetime]::MinValue
}


function Get-YakuOutputsFolderPathForMessage {
    try { return [System.IO.Path]::GetFullPath((Get-YakuSubDir 'outputs')) }
    catch {
        try { return [System.IO.Path]::GetFullPath((Join-Path (Get-YakuDataDir) 'outputs')) }
        catch { return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.yakulingo-ps\outputs') }
    }
}

function Get-YakuTranslationJobMissingMessage {
    param([AllowNull()][string]$JobId)
    if (-not [string]::IsNullOrWhiteSpace($JobId)) {
        return ('翻訳ジョブの情報が期限切れです。出力ファイルは outputs フォルダに保存されています: ' + (Get-YakuOutputsFolderPathForMessage))
    }
    return '翻訳ジョブが見つかりません。'
}


function New-YakuWarmTranslationRunspace {
    param([Parameter(Mandatory=$true)][string]$Root)
    $runspace = [runspacefactory]::CreateRunspace()
    try { $runspace.ApartmentState = [System.Threading.ApartmentState]::STA } catch {}
    try {
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        $preload = {
            param($Root, $ExpectedBuildId)
            $ErrorActionPreference = 'Stop'
            $script:YakuRoot = $Root
            . (Join-Path $Root 'src\Paths.ps1')
            . (Join-Path $Root 'src\Runtime.ps1')
            . (Join-Path $Root 'src\Html.ps1')
            . (Join-Path $Root 'src\Settings.ps1')
            . (Join-Path $Root 'src\PromptBuilder.ps1')
            . (Join-Path $Root 'src\CopilotClient.ps1')
            . (Join-Path $Root 'src\Translation.ps1')
            . (Join-Path $Root 'src\FileProcessors.ps1')
            . (Join-Path $Root 'src\FileTranslation.ps1')
            . (Join-Path $Root 'src\Corpus.ps1')
            . (Join-Path $Root 'src\CorpusSearch.ps1')
            . (Join-Path $Root 'src\CorpusReference.ps1')
            . (Join-Path $Root 'src\BriefStyle.ps1')
                . (Join-Path $Root 'src\CellSegments.ps1')
                . (Join-Path $Root 'src\CorpusPairs.ps1')
. (Join-Path $Root 'src\CatProject.ps1')
            $null = Assert-YakuBuildIdentity -Root $Root -ExpectedBuildId $ExpectedBuildId
            $preloadSw = [System.Diagnostics.Stopwatch]::StartNew()
            $settings = Read-YakuSettings -Root $Root
            $null = @(Get-YakuGlossaryEntries -Root $Root)
            $null = Get-YakuPromptTemplate -Root $Root -Name 'text_translate_to_en.txt'
            $null = New-YakuTextPrompt -Root $Root -InputText 'ウォームアップ' -Settings $settings -DirectionOverride 'to_en' -RequestId 'warmup00000000000000000000000000'
            $preloadSw.Stop()
            Write-YakuLog "Warm translation caches preloaded. elapsedMs=$($preloadSw.ElapsedMilliseconds)" 'INFO'
        }
        $null = $ps.AddScript($preload.ToString()).AddArgument($Root).AddArgument($script:YakuBuildId).Invoke()
        if ($ps.HadErrors) {
            $messages = New-Object System.Collections.Generic.List[string]
            foreach ($err in @($ps.Streams.Error)) { $messages.Add([string]$err.ToString()) | Out-Null }
            throw ('Warm translation runspace preload failed: ' + (($messages.ToArray()) -join ' | '))
        }
        $null = $ps.Commands.Clear()
        return [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Root = $Root; BuildId = $script:YakuBuildId }
    } catch {
        try { if ($ps) { $ps.Dispose() } } catch {}
        try { if ($runspace) { $runspace.Close() } } catch {}
        try { if ($runspace) { $runspace.Dispose() } } catch {}
        throw
    }
}

function Dispose-YakuWarmTranslationRunspace {
    param([AllowNull()]$Warm)
    if ($null -eq $Warm) { return }
    try { if ($Warm.PowerShell) { $Warm.PowerShell.Dispose() } } catch {}
    try { if ($Warm.Runspace) { $Warm.Runspace.Close() } } catch {}
    try { if ($Warm.Runspace) { $Warm.Runspace.Dispose() } } catch {}
}

function Dispose-YakuWarmTranslationRunspaceBuild {
    try {
        $build = $script:YakuWarmRunspaceBuild
        if ($null -eq $build) { return }
        try { if ($build.PowerShell) { $build.PowerShell.Stop() } } catch {}
        try { if ($build.PowerShell) { $build.PowerShell.Dispose() } } catch {}
    } catch {
        try { Write-YakuLog "Warm translation runspace build dispose failed: $($_.Exception.Message)" 'DEBUG' } catch {}
    } finally {
        $script:YakuWarmRunspaceBuild = $null
    }
}

function Update-YakuWarmTranslationRunspace {
    try {
        $build = $script:YakuWarmRunspaceBuild
        if ($null -eq $build) { return }
        if (-not $build.Async -or -not $build.Async.IsCompleted) { return }
        $warm = $null
        try {
            $results = $build.PowerShell.EndInvoke($build.Async)
            foreach ($item in @($results)) { if ($item) { $warm = $item } }
            if ($null -eq $warm -or -not $warm.PSObject.Properties['PowerShell'] -or -not $warm.PSObject.Properties['Runspace']) {
                throw 'Warm translation runspace build did not return a valid runspace object.'
            }
            if ($script:YakuWarmRunspace) {
                Dispose-YakuWarmTranslationRunspace -Warm $warm
                Write-YakuLog 'Warm translation runspace build completed but an idle warm runspace already exists; disposed extra instance.' 'DEBUG'
            } else {
                $script:YakuWarmRunspace = $warm
                Write-YakuLog "Warm translation runspace ready. root=$($warm.Root)" 'INFO'
            }
        } catch {
            if ($warm) { Dispose-YakuWarmTranslationRunspace -Warm $warm }
            Write-YakuLog "Warm translation runspace build failed: $($_.Exception.Message)" 'WARN'
        } finally {
            try { if ($build.PowerShell) { $build.PowerShell.Dispose() } } catch {}
            $script:YakuWarmRunspaceBuild = $null
        }
    } catch {
        try { Write-YakuLog "Update-YakuWarmTranslationRunspace failed: $($_.Exception.Message)" 'WARN' } catch {}
        try { Dispose-YakuWarmTranslationRunspaceBuild } catch {}
    }
}

function Start-YakuWarmTranslationRunspaceBuild {
    param([AllowNull()][string]$Root = $script:YakuRoot)
    Update-YakuWarmTranslationRunspace
    if ($script:YakuWarmRunspace -or $script:YakuWarmRunspaceBuild) { return }
    if ([string]::IsNullOrWhiteSpace($Root)) { return }
    $builder = $null
    try {
        $builderScript = {
            param($Root, $ExpectedBuildId)
            $ErrorActionPreference = 'Stop'
            $runspace = [runspacefactory]::CreateRunspace()
            try { $runspace.ApartmentState = [System.Threading.ApartmentState]::STA } catch {}
            try {
                $runspace.Open()
                $ps = [powershell]::Create()
                $ps.Runspace = $runspace
                $preload = {
                    param($Root, $ExpectedBuildId)
                    $ErrorActionPreference = 'Stop'
                    $script:YakuRoot = $Root
                    . (Join-Path $Root 'src\Paths.ps1')
                    . (Join-Path $Root 'src\Runtime.ps1')
                    . (Join-Path $Root 'src\Html.ps1')
                    . (Join-Path $Root 'src\Settings.ps1')
                    . (Join-Path $Root 'src\PromptBuilder.ps1')
                    . (Join-Path $Root 'src\CopilotClient.ps1')
                    . (Join-Path $Root 'src\Translation.ps1')
                    . (Join-Path $Root 'src\FileProcessors.ps1')
                    . (Join-Path $Root 'src\FileTranslation.ps1')
                    . (Join-Path $Root 'src\Corpus.ps1')
                    . (Join-Path $Root 'src\CorpusSearch.ps1')
                    . (Join-Path $Root 'src\CorpusReference.ps1')
                    . (Join-Path $Root 'src\BriefStyle.ps1')
                . (Join-Path $Root 'src\CellSegments.ps1')
                . (Join-Path $Root 'src\CorpusPairs.ps1')
. (Join-Path $Root 'src\CatProject.ps1')
                    $null = Assert-YakuBuildIdentity -Root $Root -ExpectedBuildId $ExpectedBuildId
                    $preloadSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $settings = Read-YakuSettings -Root $Root
                    $null = @(Get-YakuGlossaryEntries -Root $Root)
                    $null = Get-YakuPromptTemplate -Root $Root -Name 'text_translate_to_en.txt'
                    $null = New-YakuTextPrompt -Root $Root -InputText 'ウォームアップ' -Settings $settings -DirectionOverride 'to_en' -RequestId 'warmup00000000000000000000000000'
                    $preloadSw.Stop()
                    Write-YakuLog "Warm translation caches preloaded. elapsedMs=$($preloadSw.ElapsedMilliseconds)" 'INFO'
                }
                $null = $ps.AddScript($preload.ToString()).AddArgument($Root).AddArgument($ExpectedBuildId).Invoke()
                if ($ps.HadErrors) {
                    $messages = New-Object System.Collections.Generic.List[string]
                    foreach ($err in @($ps.Streams.Error)) { $messages.Add([string]$err.ToString()) | Out-Null }
                    throw ('Warm translation runspace preload failed: ' + (($messages.ToArray()) -join ' | '))
                }
                $null = $ps.Commands.Clear()
                return [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Root = $Root; BuildId = $ExpectedBuildId }
            } catch {
                try { if ($ps) { $ps.Dispose() } } catch {}
                try { if ($runspace) { $runspace.Close() } } catch {}
                try { if ($runspace) { $runspace.Dispose() } } catch {}
                throw
            }
        }
        $builder = [powershell]::Create()
        [void]$builder.AddScript($builderScript.ToString()).AddArgument($Root).AddArgument($script:YakuBuildId)
        $async = $builder.BeginInvoke()
        $script:YakuWarmRunspaceBuild = [pscustomobject]@{ PowerShell = $builder; Async = $async; Root = $Root; StartedAt = (Get-Date) }
        Write-YakuLog "Warm translation runspace build started. root=$Root buildId=$($script:YakuBuildId)" 'INFO'
    } catch {
        try { if ($builder) { $builder.Dispose() } } catch {}
        $script:YakuWarmRunspaceBuild = $null
        try { Write-YakuLog "Failed to start warm translation runspace build: $($_.Exception.Message)" 'WARN' } catch {}
    }
}

function Use-YakuWarmTranslationRunspace {
    param([Parameter(Mandatory=$true)][string]$Root)
    Update-YakuWarmTranslationRunspace
    $warm = $script:YakuWarmRunspace
    if ($null -eq $warm) { return $null }
    $script:YakuWarmRunspace = $null
    try {
        if ([string]$warm.Root -ne $Root) {
            Write-YakuLog "Warm translation runspace root mismatch. expected=$Root actual=$($warm.Root)" 'WARN'
            Dispose-YakuWarmTranslationRunspace -Warm $warm
            return $null
        }
        $diskBuildId = Get-YakuDiskBuildId -Root $Root
        if (-not [string]::Equals([string]$warm.BuildId, [string]$script:YakuBuildId, [System.StringComparison]::Ordinal) -or -not [string]::Equals($diskBuildId, [string]$script:YakuBuildId, [System.StringComparison]::Ordinal)) {
            Write-YakuLog "Warm translation runspace build mismatch. server=$($script:YakuBuildId) warm=$($warm.BuildId) disk=$diskBuildId" 'WARN'
            Dispose-YakuWarmTranslationRunspace -Warm $warm
            throw 'BUILD_ID_WARM_RUNSPACE_MISMATCH: アプリを完全終了して再起動してください。'
        }
        $state = $null
        try { $state = $warm.Runspace.RunspaceStateInfo.State } catch { $state = $null }
        if ($state -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
            Write-YakuLog "Warm translation runspace was not open. state=$state" 'WARN'
            Dispose-YakuWarmTranslationRunspace -Warm $warm
            return $null
        }
        Write-YakuLog "Warm translation runspace acquired. root=$Root" 'INFO'
        return $warm
    } catch {
        try { Dispose-YakuWarmTranslationRunspace -Warm $warm } catch {}
        try { Write-YakuLog "Warm translation runspace acquire failed: $($_.Exception.Message)" 'WARN' } catch {}
        return $null
    }
}

function Dispose-YakuTranslationJobHandle {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [switch]$Stop,
        [switch]$SkipEndInvoke
    )
    try {
        if (-not $script:YakuTranslateJobHandles.ContainsKey($JobId)) { return }
        $handle = $script:YakuTranslateJobHandles[$JobId]
        if ($null -eq $handle) {
            try { $script:YakuTranslateJobHandles.Remove($JobId) } catch {}
            return
        }
        $handleType = ''
        try { $handleType = [string]$handle.Type } catch { $handleType = 'Runspace' }
        if ($handleType -eq 'Process') {
            if ($Stop) {
                try { Write-YakuTextAtomic -Path ([string]$handle.CancelPath) -Text 'cancel' } catch {}
                try {
                    if ($handle.Process -and -not $handle.Process.HasExited) { $handle.Process.Kill() }
                } catch { try { Write-YakuLog "File worker terminate failed. jobId=$JobId errorCode=WORKER_TERMINATE_FAILED" 'WARN' } catch {} }
                try {
                    $state = $script:YakuTranslateJobs[$JobId]
                    $excelPid = [int](Get-YakuTranslationJobStateValue -State $state -Key 'excel_pid')
                    $excelStarted = [string](Get-YakuTranslationJobStateValue -State $state -Key 'excel_started_at')
                    if (Test-YakuProcessIdentity -Id $excelPid -StartTimeUtc $excelStarted) { Stop-Process -Id $excelPid -Force -ErrorAction SilentlyContinue }
                } catch {}
                try { if ($handle.UploadDir -and (Test-Path -LiteralPath ([string]$handle.UploadDir))) { Remove-Item -LiteralPath ([string]$handle.UploadDir) -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
                try { if ($handle.JobDir) { Remove-Item -LiteralPath (Join-Path ([string]$handle.JobDir) 'spec.json') -Force -ErrorAction SilentlyContinue } } catch {}
            }
            try { if ($handle.Process) { $handle.Process.Dispose() } } catch {}
            try { $handle.Disposed = $true } catch {}
            try { $script:YakuTranslateJobHandles.Remove($JobId) } catch {}
            return
        }
        if ($Stop) {
            try { $handle.PowerShell.Stop() } catch { try { Write-YakuLog "Translation job stop failed: $($_.Exception.Message)" 'WARN' } catch {} }
        }
        if (-not $SkipEndInvoke) {
            try {
                if ($handle.Async -and $handle.Async.IsCompleted) { $null = $handle.PowerShell.EndInvoke($handle.Async) }
            } catch {
                try { Write-YakuLog "Translation job EndInvoke failed during dispose: $($_.Exception.Message)" 'WARN' } catch {}
            }
        }
        try { $handle.PowerShell.Dispose() } catch {}
        try { $handle.Runspace.Close() } catch {}
        try { $handle.Runspace.Dispose() } catch {}
        try { $handle.Disposed = $true } catch {}
        try { $script:YakuTranslateJobHandles.Remove($JobId) } catch {}
    } catch {
        try { Write-YakuLog "Dispose-YakuTranslationJobHandle failed: $($_.Exception.Message)" 'WARN' } catch {}
    }
}

function Clear-YakuCompletedTranslationJobs {
    try {
        $completed = New-Object System.Collections.Generic.List[object]
        $jobIds = @()
        try { $jobIds = @($script:YakuTranslateJobs.Keys | ForEach-Object { [string]$_ }) } catch { $jobIds = @() }
        foreach ($rawId in @($jobIds)) {
            $id = [string]$rawId
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            try {
                if (-not $script:YakuTranslateJobs.ContainsKey($id)) { continue }
                $state = $script:YakuTranslateJobs[$id]
                if ($null -eq $state) { continue }
                $mode = [string](Get-YakuTranslationJobStateValue -State $state -Key 'mode')
                if ($mode -eq 'queued' -or $mode -eq 'working') { continue }
                $completedAt = Get-YakuTranslationJobStateDate -State $state
                $completed.Add([pscustomobject]@{ Id = $id; CompletedAt = $completedAt }) | Out-Null
            } catch {
                try { Write-YakuLog "Clear-YakuCompletedTranslationJobs skipped job. id=$id error=$($_.Exception.Message)" 'DEBUG' } catch {}
            }
        }
        if ($completed.Count -eq 0) { return }

        $keepIds = @{}
        $keepLimit = 5
        try { $keepLimit = [Math]::Max(0, [int]$script:YakuTranslateJobKeepCompleted) } catch { $keepLimit = 5 }
        if ($keepLimit -gt 0) {
            foreach ($item in @($completed.ToArray() | Sort-Object CompletedAt -Descending | Select-Object -First $keepLimit)) {
                try { $keepIds[[string]$item.Id] = $true } catch {}
            }
        }
        $retentionMinutes = 30
        try { $retentionMinutes = [Math]::Max(0, [int]$script:YakuTranslateJobRetentionMinutes) } catch { $retentionMinutes = 30 }
        $cutoff = (Get-Date).AddMinutes(-1 * $retentionMinutes)
        $removed = 0
        foreach ($item in @($completed.ToArray())) {
            $id = [string]$item.Id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $completedAt = [datetime]::MinValue
            try { $completedAt = [datetime]$item.CompletedAt } catch { $completedAt = [datetime]::MinValue }
            $isOld = ($completedAt -ne [datetime]::MinValue -and $completedAt -lt $cutoff)
            if ($keepIds.ContainsKey($id)) { continue }
            if (-not $isOld) { continue }
            Dispose-YakuTranslationJobHandle -JobId $id -SkipEndInvoke
            try {
                if ($script:YakuTranslateJobs.ContainsKey($id)) {
                    $state = $script:YakuTranslateJobs[$id]
                    $inputPath = [string](Get-YakuTranslationJobStateValue -State $state -Key 'input_file_path')
                    if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
                        $uploadsRoot = [System.IO.Path]::GetFullPath((Get-YakuSubDir 'uploads')).TrimEnd([char[]]@('\','/'))
                        $fullInput = [System.IO.Path]::GetFullPath($inputPath)
                        $inputDir = Split-Path -Parent $fullInput
                        $underUploads = $false
                        try { $underUploads = $fullInput.StartsWith($uploadsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) } catch { $underUploads = $false }
                        if ($underUploads -and -not [string]::IsNullOrWhiteSpace($inputDir) -and (Test-Path -LiteralPath $inputDir)) {
                            Remove-Item -LiteralPath $inputDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $statePath = [string](Get-YakuTranslationJobStateValue -State $state -Key 'state_path')
                    if (-not [string]::IsNullOrWhiteSpace($statePath)) {
                        $jobsRoot = [System.IO.Path]::GetFullPath((Get-YakuSubDir 'jobs')).TrimEnd([char[]]@('\','/'))
                        $jobDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $statePath))
                        if ($jobDir.StartsWith($jobsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $jobDir -PathType Container)) {
                            Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            } catch {
                try { Write-YakuLog "Translation job upload cleanup skipped. id=$id error=$($_.Exception.Message)" 'DEBUG' } catch {}
            }
            try { if ($script:YakuTranslateJobs.ContainsKey($id)) { $script:YakuTranslateJobs.Remove($id) } } catch {}
            if ([string]$script:YakuActiveTranslateJobId -eq $id) { $script:YakuActiveTranslateJobId = '' }
            $removed++
        }
        if ($removed -gt 0) { Write-YakuLog "Translation job cache cleaned: removed=$removed keepRecent=$script:YakuTranslateJobKeepCompleted retentionMinutes=$script:YakuTranslateJobRetentionMinutes" 'INFO' }
    } catch {
        try { Write-YakuLog "Clear-YakuCompletedTranslationJobs failed: $($_.Exception.Message) type=$($_.Exception.GetType().FullName)" 'WARN' } catch {}
    }
}

function Import-YakuJobStateFile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Target)
    $saved = Read-YakuJsonFile -Path $Path
    if ($null -eq $saved) { return $false }
    foreach ($prop in @($saved.PSObject.Properties)) { $Target[[string]$prop.Name] = $prop.Value }
    return $true
}

function Update-YakuTranslationJobs {
    try { Update-YakuWarmTranslationRunspace } catch {}
    try {
        foreach ($id in @($script:YakuTranslateJobHandles.Keys)) {
            $handle = $script:YakuTranslateJobHandles[$id]
            if ($null -eq $handle) { continue }
            $disposed = $false
            try { $disposed = [bool]$handle.Disposed } catch { $disposed = $false }
            if ($disposed) { continue }
            $handleType = ''
            try { $handleType = [string]$handle.Type } catch { $handleType = 'Runspace' }
            if ($handleType -eq 'Process') {
                $state = $script:YakuTranslateJobs[$id]
                try { $null = Import-YakuJobStateFile -Path ([string]$handle.StatePath) -Target $state } catch {}
                # FileWorker writes result.json before publishing a terminal state.json. Load the
                # result as soon as the terminal state is observed; process exit is not required.
                $modeNow = [string]$state['mode']
                if ($modeNow -in @('done','completed_with_warnings','failed') -and
                    [string]::IsNullOrWhiteSpace([string]$state['result_json']) -and
                    (Test-Path -LiteralPath ([string]$handle.ResultPath) -PathType Leaf)) {
                    try {
                        $state['result_json'] = Get-Content -LiteralPath ([string]$handle.ResultPath) -Raw -Encoding UTF8
                    } catch {
                        try { Write-YakuLog "Result lazy-load failed. jobId=$id error=$($_.Exception.Message)" 'WARN' } catch {}
                    }
                }
                $cancelRequested = $false
                try { $cancelRequested = [bool]$state['cancel_requested'] } catch { $cancelRequested = $false }
                if ($cancelRequested) {
                    $state['mode']='cancelling'; $state['label']='Cancelling'; $state['class']='warn'; $state['detail']='専用ワーカーを停止しています。'; $state['output_path']=''
                }
                $heartbeatTimeout = 180
                try {
                    $heartbeatSettings = Read-YakuSettings -Root $script:YakuRoot
                    $heartbeatTimeout = [int]$heartbeatSettings.worker_heartbeat_timeout_seconds
                    $phase = [string]$state['phase']
                    if ($phase -eq 'translate') { $heartbeatTimeout = [Math]::Max($heartbeatTimeout, [int]$heartbeatSettings.request_timeout + 30) }
                    elseif ($phase -eq 'extract') { $heartbeatTimeout = [Math]::Max($heartbeatTimeout, [int]$heartbeatSettings.extract_timeout_seconds + 30) }
                    elseif ($phase -in @('apply','save','validating','publishing')) { $heartbeatTimeout = [Math]::Max($heartbeatTimeout, 600) }
                } catch {}
                $updated = Get-YakuTranslationJobStateDate -State $state -Keys @('updated_at')
                if ($updated -ne [datetime]::MinValue -and ((Get-Date) - $updated).TotalSeconds -gt $heartbeatTimeout -and (Test-YakuTranslationJobRunning -State $state)) {
                    $state['mode']='failed'; $state['label']='Translation error'; $state['class']='warn'; $state['detail']='Excelワーカーの進捗が停止したため終了しました。'; $state['error_code']='WORKER_HEARTBEAT_TIMEOUT'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''
                    Dispose-YakuTranslationJobHandle -JobId ([string]$id) -Stop -SkipEndInvoke
                    continue
                }
                $exited = $false
                try { $handle.Process.Refresh(); $exited = [bool]$handle.Process.HasExited } catch { $exited = $true }
                if ($exited) {
                    try { $null = Import-YakuJobStateFile -Path ([string]$handle.StatePath) -Target $state } catch {}
                    if (Test-Path -LiteralPath ([string]$handle.ResultPath) -PathType Leaf) {
                        try { $state['result_json'] = Get-Content -LiteralPath ([string]$handle.ResultPath) -Raw -Encoding UTF8 } catch {}
                    }
                    if ($cancelRequested) {
                        $state['mode']='cancelled'; $state['label']='Cancelled'; $state['class']='idle'; $state['detail']='翻訳をキャンセルしました。'; $state['error_code']='JOB_CANCELLED'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''; $state['output_name']=''; $state['result_json']=([pscustomobject]@{ Error='翻訳をキャンセルしました。'; Cancelled=$true } | ConvertTo-Json -Depth 10 -Compress)
                    } elseif (Test-YakuTranslationJobRunning -State $state) {
                        $state['mode']='interrupted'; $state['label']='Interrupted'; $state['class']='warn'; $state['detail']='ファイル翻訳ワーカーが予期せず終了しました。'; $state['error_code']='WORKER_EXITED'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''
                    }
                    Dispose-YakuTranslationJobHandle -JobId ([string]$id) -SkipEndInvoke
                    try {
                        if ($handle.UploadDir -and (Test-Path -LiteralPath ([string]$handle.UploadDir))) { Remove-Item -LiteralPath ([string]$handle.UploadDir) -Recurse -Force -ErrorAction SilentlyContinue }
                    } catch {}
                }
                continue
            }
            $async = $handle.Async
            if ($async -and $async.IsCompleted) {
                $state = $script:YakuTranslateJobs[$id]
                $cancelRequested = $false
                try { $cancelRequested = [bool]$state['cancel_requested'] } catch { $cancelRequested = $false }
                try { $null = $handle.PowerShell.EndInvoke($async) }
                catch {
                    if (-not $cancelRequested -and $state -and [string]$state['mode'] -ne 'error' -and [string]$state['mode'] -ne 'cancelled') {
                        $safe = Convert-YakuExceptionToUserMessage $_
                        $state['mode'] = 'error'
                        $state['label'] = 'Translation error'
                        $state['class'] = 'warn'
                        $state['detail'] = $safe
                        $state['progress'] = 100
                        $state['completed_at'] = (Get-Date).ToString('s')
                        $state['updated_at'] = (Get-Date).ToString('s')
                        $state['result_json'] = ([pscustomobject]@{ Error=$safe } | ConvertTo-Json -Depth 10 -Compress)
                    }
                    try { Write-YakuLog "Translation runspace job failed: $($_.Exception.ToString())" 'ERROR' } catch {}
                }
                if ($cancelRequested) {
                    $state['mode']='cancelled'; $state['label']='Cancelled'; $state['class']='idle'; $state['detail']='翻訳をキャンセルしました。'; $state['error_code']='JOB_CANCELLED'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''; $state['result_json']=([pscustomobject]@{ Error='翻訳をキャンセルしました。'; Cancelled=$true } | ConvertTo-Json -Depth 10 -Compress)
                }
                Dispose-YakuTranslationJobHandle -JobId ([string]$id) -SkipEndInvoke
                Start-YakuWarmTranslationRunspaceBuild -Root $script:YakuRoot
            }
        }
        Clear-YakuCompletedTranslationJobs
    } catch {
        try { Write-YakuLog "Update-YakuTranslationJobs failed: $($_.Exception.Message)" 'WARN' } catch {}
    }
}

function Get-YakuActiveTranslationJobState {
    Update-YakuTranslationJobs
    $id = [string]$script:YakuActiveTranslateJobId
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    if ($script:YakuTranslateJobs.ContainsKey($id)) { return $script:YakuTranslateJobs[$id] }
    return $null
}

function Test-YakuTranslationJobRunning {
    param([AllowNull()]$State)
    if ($null -eq $State) { return $false }
    $mode = [string]$State['mode']
    return ($mode -in @('queued','opening','extracting','translating','writing','validating','publishing','working','cancelling'))
}

function Stop-YakuTranslationJob {
    param([string]$JobId = '')
    Update-YakuTranslationJobs
    if ([string]::IsNullOrWhiteSpace($JobId)) { $JobId = [string]$script:YakuActiveTranslateJobId }
    if ([string]::IsNullOrWhiteSpace($JobId) -or -not $script:YakuTranslateJobs.ContainsKey($JobId)) {
        throw '翻訳ジョブが見つかりません。'
    }

    $state = $script:YakuTranslateJobs[$JobId]
    try {
        if ([bool]$state['cancel_requested'] -and (Test-YakuTranslationJobRunning -State $state)) {
            $state['mode']='cancelling'; $state['label']='Cancelling'; $state['class']='warn'; $state['detail']='専用ワーカーを停止しています。'; $state['output_path']=''
            return $state
        }
    } catch {}
    if (Test-YakuTranslationJobRunning -State $state) {
        $message = 'キャンセル処理を開始しました。'
        $state['mode'] = 'cancelling'
        $state['label'] = 'Cancelling'
        $state['class'] = 'warn'
        $state['detail'] = $message
        $state['updated_at'] = (Get-Date).ToString('s')
        $state['cancel_requested'] = $true
        $handle = $script:YakuTranslateJobHandles[$JobId]
        $handleType = ''
        try { $handleType = [string]$handle.Type } catch { $handleType = 'Runspace' }
        if ($handleType -eq 'Process') {
            try { Write-YakuTextAtomic -Path ([string]$handle.CancelPath) -Text 'cancel' } catch {}
            try {
                $stopperPath = Join-Path $script:YakuRoot 'src\ProcessStopper.ps1'
                if (!(Test-Path -LiteralPath $stopperPath -PathType Leaf)) { throw 'ProcessStopper.ps1 が見つかりません。' }
                $workerPid = 0
                $workerStartedAt = ''
                try { $workerPid = [int]$handle.Process.Id; $workerStartedAt = Get-YakuProcessStartTimeIso -Id $workerPid } catch {}
                $excelPid = [int](Get-YakuTranslationJobStateValue -State $state -Key 'excel_pid')
                $excelStartedAt = [string](Get-YakuTranslationJobStateValue -State $state -Key 'excel_started_at')
                $psExe = Join-Path $PSHOME 'powershell.exe'
                if (!(Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
                $q = { param([string]$v) '"' + ($v -replace '"','\"') + '"' }
                $uploadDir = [string]$handle.UploadDir
                $outputTempDir = Join-Path (Get-YakuSubDir 'outputs') ('.yakulingo-job-' + $JobId)
                $specPath = Join-Path ([string]$handle.JobDir) 'spec.json'
                $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -Root {1} -WorkerPid {2} -WorkerStartedAt {3} -ExcelPid {4} -ExcelStartedAt {5} -UploadDir {6} -OutputTempDir {7} -SpecPath {8}' -f (&$q $stopperPath), (&$q $script:YakuRoot), $workerPid, (&$q $workerStartedAt), $excelPid, (&$q $excelStartedAt), (&$q $uploadDir), (&$q $outputTempDir), (&$q $specPath)
                $stopHelper = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
                try { $handle | Add-Member -NotePropertyName StopHelper -NotePropertyValue $stopHelper -Force } catch {}
            } catch {
                try { Write-YakuLog "Asynchronous file-worker stop scheduling failed. jobId=$JobId error=$($_.Exception.Message)" 'ERROR' } catch {}
                throw 'キャンセル処理を開始できませんでした。'
            }
        } else {
            try { $null = $handle.PowerShell.BeginStop($null, $null) } catch {}
        }
        $state['output_path'] = ''
        Write-YakuLog "Translation cancellation accepted. jobId=$JobId" 'INFO'
    }
    return $state
}

function Start-YakuFileProcessJob {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()][string[]]$Sheets,
        [bool]$UploadedInput = $false
    )
    $null = Assert-YakuBuildIdentity -Root $script:YakuRoot -ExpectedBuildId $script:YakuBuildId
    $jobId = [guid]::NewGuid().ToString('N')
    $diagnosticsLevel = 'standard'
    try { $diagnosticsLevel = Get-YakuDiagnosticsLevel -Settings $Settings } catch { $diagnosticsLevel = 'standard' }
    $diagnosticsEnabled = ($diagnosticsLevel -eq 'full')
    $jobDir = Join-Path (Get-YakuSubDir 'jobs') $jobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    $statePath = Join-Path $jobDir 'state.json'
    $resultPath = Join-Path $jobDir 'result.json'
    $specPath = Join-Path $jobDir 'spec.json'
    $cancelPath = Join-Path $jobDir 'cancel.requested'
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $state = [hashtable]::Synchronized(@{
        id=$jobId; kind='file'; mode='queued'; label='Queued'; class='warn'; detail=''; progress=0; phase='queued'
        input_length=0; file_name=$fileName; input_file_path=$FilePath; output_path=''; output_name=''
        blocks_total=0; blocks_translated=0; blocks_retained=0; unique_done=0; unique_total=0; cells=0; shapes=0; charts=0
        created_at=(Get-Date).ToString('s'); started_at=''; completed_at=''; updated_at=(Get-Date).ToString('s')
        result_json=''; result_path=$resultPath; state_path=$statePath; cancel_path=$cancelPath; uploaded_input=$UploadedInput; cancel_requested=$false
        worker_pid=0; worker_started_at=''; excel_pid=0; excel_started_at=''; error_code=''; completion_status=''; diagnostics_enabled=$diagnosticsEnabled; build_id=$script:YakuBuildId
    })
    $uploadDir = if ($UploadedInput) { Split-Path -Parent $FilePath } else { '' }
    $spec = [ordered]@{
        build_id=$script:YakuBuildId; file_path=$FilePath; direction=$Direction; sheets=@($Sheets); settings=$Settings; cancel_path=$cancelPath
        uploaded_input=$UploadedInput; upload_dir=$uploadDir; state=(ConvertTo-YakuStateHashtable -State $state)
    }
    $process = $null
    try {
        Write-YakuJsonAtomic -Path $specPath -Value $spec -Depth 40
        Write-YakuProgressStateFile -ProgressState $state
        $workerPath = Join-Path $script:YakuRoot 'src\FileWorker.ps1'
        if (!(Test-Path -LiteralPath $workerPath -PathType Leaf)) { throw 'FileWorker.ps1 が見つかりません。' }
        $psExe = Join-Path $PSHOME 'powershell.exe'
        if (!(Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        $q = { param([string]$v) '"' + ($v -replace '"','\"') + '"' }
        $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -Root {1} -JobSpecPath {2} -StatePath {3} -ResultPath {4}' -f (&$q $workerPath), (&$q $script:YakuRoot), (&$q $specPath), (&$q $statePath), (&$q $resultPath)
        $process = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 120
        try { $process.Refresh() } catch {}
        if ($process.HasExited) { throw "ファイル翻訳ワーカーを開始できませんでした。ExitCode=$($process.ExitCode)" }
        $state['worker_pid'] = [int]$process.Id
        $state['worker_started_at'] = Get-YakuProcessStartTimeIso -Id ([int]$process.Id)
        # Publish only after process creation succeeds (transactional start).
        $script:YakuTranslateJobs[$jobId] = $state
        $script:YakuTranslateJobHandles[$jobId] = [pscustomobject]@{
            Type='Process'; Process=$process; StatePath=$statePath; ResultPath=$resultPath; CancelPath=$cancelPath
            JobDir=$jobDir; UploadDir=$uploadDir; Disposed=$false
        }
        $script:YakuActiveTranslateJobId = $jobId
        Write-YakuLog "File translation process started. jobId=$jobId workerPid=$($process.Id) fileSize=$((Get-Item -LiteralPath $FilePath).Length) buildId=$($script:YakuBuildId) diagnosticsLevel=$diagnosticsLevel settingsSnapshot=job-start" 'INFO'
        return $state
    } catch {
        try { if ($process -and -not $process.HasExited) { $process.Kill() } } catch {}
        try { if ($process) { $process.Dispose() } } catch {}
        $state['mode']='failed'; $state['label']='Translation error'; $state['class']='warn'; $state['detail']=$_.Exception.Message; $state['error_code']='WORKER_START_FAILED'; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s')
        try { Write-YakuProgressStateFile -ProgressState $state } catch {}
        try { if ($UploadedInput -and $uploadDir -and (Test-Path -LiteralPath $uploadDir)) { Remove-Item -LiteralPath $uploadDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path -LiteralPath $jobDir) { Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        throw
    }
}

function Start-YakuTranslationJob {
    param(
        [AllowNull()][string]$InputText = '',
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()][string]$TextDirectionOverride = '',
        [ValidateSet('text','file','revise','cat')][string]$Kind = 'text',
        [AllowNull()][string]$FilePath = '',
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [AllowNull()][string[]]$Sheets,
        [bool]$UploadedInput = $false,
        # V91.61（2026-08-06）: 修正の依頼。原文・現訳・指示・文体を JSON で運ぶ。
        # 翻訳と同じジョブの仕組みに乗せるのは、Copilot への往復が1度に1つで
        # なければならないため。別経路にすると翻訳中の修正が衝突する。
        [AllowNull()][string]$ReviseJson = '',
        # CAT の「残りを訳す」。訳す原文だけを渡し、訳文だけを返させる。
        # ジョブは別のランスペースで走るため、メモリ上のプロジェクトを触れない。
        [AllowNull()][string]$CatJson = ''
    )
    $null = Assert-YakuBuildIdentity -Root $script:YakuRoot -ExpectedBuildId $script:YakuBuildId
    Update-YakuTranslationJobs
    $active = Get-YakuActiveTranslationJobState
    if (Test-YakuTranslationJobRunning -State $active) { throw '別の翻訳が実行中です。完了してから再実行してください。' }

    if ($Kind -eq 'file') {
        if ([string]::IsNullOrWhiteSpace($FilePath) -or !(Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw '翻訳対象ファイルが見つかりません。' }
        [void](Get-YakuSupportedFileKind -Path $FilePath)
        return (Start-YakuFileProcessJob -FilePath $FilePath -Settings $Settings -Direction $Direction -Sheets $Sheets -UploadedInput:$UploadedInput)
    }

    $jobId = ([guid]::NewGuid().ToString('N'))
    $diagnosticsLevel = 'standard'
    try { $diagnosticsLevel = Get-YakuDiagnosticsLevel -Settings $Settings } catch { $diagnosticsLevel = 'standard' }
    $diagnosticsEnabled = ($diagnosticsLevel -eq 'full')
    $fileName = if ($Kind -eq 'file') { [System.IO.Path]::GetFileName($FilePath) } else { '' }
    $inputLength = if ($Kind -eq 'file') { 0 } else { ([string]$InputText).Length }
    $state = [hashtable]::Synchronized(@{
        id = $jobId
        kind = $Kind
        mode = 'queued'
        label = 'Queued'
        class = 'warn'
        detail = ''
        progress = 0
        phase = ''
        input_length = $inputLength
        file_name = $fileName
        input_file_path = $FilePath
        output_path = ''
        output_name = ''
        blocks_total = 0
        blocks_translated = 0
        blocks_retained = 0
        unique_done = 0
        unique_total = 0
        cells = 0
        shapes = 0
        charts = 0
        created_at = (Get-Date).ToString('s')
        started_at = ''
        completed_at = ''
        updated_at = (Get-Date).ToString('s')
        result_json = ''
        diagnostics_enabled = $diagnosticsEnabled
        build_id = $script:YakuBuildId
        session_token = $script:YakuSessionToken
    })
    $settingsJson = $Settings | ConvertTo-Json -Depth 20 -Compress
    $sheetsJson = @($Sheets) | ConvertTo-Json -Depth 10 -Compress
    $root = [string]$script:YakuRoot
    $worker = {
        param(
            [Parameter(Mandatory=$true)][string]$Root,
            [Parameter(Mandatory=$true)][string]$Kind,
            [AllowNull()][string]$InputText,
            [AllowNull()][string]$TextDirectionOverride,
            [AllowNull()][string]$FilePath,
            [Parameter(Mandatory=$true)][string]$Direction,
            [AllowNull()][string]$SheetsJson,
            [Parameter(Mandatory=$true)][string]$SettingsJson,
            [Parameter(Mandatory=$true)][string]$ExpectedBuildId,
            [Parameter(Mandatory=$true)]$JobState,
            [AllowNull()][string]$ReviseJson,
            [AllowNull()][string]$CatJson
        )
        $ErrorActionPreference = 'Stop'
        $startupSw = [System.Diagnostics.Stopwatch]::StartNew()
        $moduleLoadMs = 0
        $buildIdentityMs = 0
        $settingsReadMs = 0
        try {
            $script:YakuRoot = $Root
            $sectionSw = [System.Diagnostics.Stopwatch]::StartNew()
            if (-not (Get-Command Invoke-YakuCopilotPrompt -ErrorAction SilentlyContinue)) {
                . (Join-Path $Root 'src\Paths.ps1')
                . (Join-Path $Root 'src\Runtime.ps1')
                . (Join-Path $Root 'src\Html.ps1')
                . (Join-Path $Root 'src\Settings.ps1')
                . (Join-Path $Root 'src\PromptBuilder.ps1')
                . (Join-Path $Root 'src\CopilotClient.ps1')
                . (Join-Path $Root 'src\Translation.ps1')
                . (Join-Path $Root 'src\FileProcessors.ps1')
                . (Join-Path $Root 'src\FileTranslation.ps1')
                . (Join-Path $Root 'src\Corpus.ps1')
                . (Join-Path $Root 'src\CorpusSearch.ps1')
                . (Join-Path $Root 'src\CorpusReference.ps1')
                . (Join-Path $Root 'src\BriefStyle.ps1')
                . (Join-Path $Root 'src\CellSegments.ps1')
                . (Join-Path $Root 'src\CorpusPairs.ps1')
. (Join-Path $Root 'src\CatProject.ps1')
            }
            $sectionSw.Stop(); $moduleLoadMs = $sectionSw.ElapsedMilliseconds
            $sectionSw.Restart()
            $null = Assert-YakuBuildIdentity -Root $Root -ExpectedBuildId $ExpectedBuildId
            $sectionSw.Stop(); $buildIdentityMs = $sectionSw.ElapsedMilliseconds

            $sectionSw.Restart()
            $settings = $SettingsJson | ConvertFrom-Json
            $sectionSw.Stop(); $settingsReadMs = $sectionSw.ElapsedMilliseconds
            try { $script:YakuDiagnosticsLevel = Get-YakuDiagnosticsLevel -Settings $settings } catch { $script:YakuDiagnosticsLevel = 'standard' }
            $script:YakuFullTextDiagnosticsEnabled = ($script:YakuDiagnosticsLevel -eq 'full')
            Write-YakuLog "Translation runspace settings snapshot. jobId=$($JobState['id']) buildId=$ExpectedBuildId diagnosticsLevel=$script:YakuDiagnosticsLevel source=job-start" 'INFO'
            $sheets = @()
            try { if (-not [string]::IsNullOrWhiteSpace($SheetsJson)) { $sheets = @($SheetsJson | ConvertFrom-Json) } } catch { $sheets = @() }
            $JobState['mode'] = 'working'
            $JobState['label'] = if ($Kind -eq 'file') { 'Extracting file' } else { 'Preparing prompt' }
            $JobState['class'] = 'warn'
            $JobState['progress'] = 3
            $JobState['phase'] = 'preparing'
            $JobState['started_at'] = (Get-Date).ToString('s')
            $JobState['updated_at'] = (Get-Date).ToString('s')

            $startupSw.Stop()
            $otherStartupMs = [Math]::Max(0, $startupSw.ElapsedMilliseconds - $moduleLoadMs - $buildIdentityMs - $settingsReadMs)
            Write-YakuLog "Translation runspace startup timings. settings-read elapsedMs=$settingsReadMs build-identity elapsedMs=$buildIdentityMs module-load elapsedMs=$moduleLoadMs other elapsedMs=$otherStartupMs total elapsedMs=$($startupSw.ElapsedMilliseconds)" 'INFO'

            if ($Kind -eq 'cat') {
                $cat = $CatJson | ConvertFrom-Json
                $catWarnings = New-Object System.Collections.Generic.List[object]
                $catMode = ''
                try { $catMode = [string]$cat.mode } catch { $catMode = '' }
                if ($catMode -eq 'corpus') {
                    # 文例を引くだけ。訳はしない。何が引けたかを見てから
                    # 使うかどうか決められるようにするため（利用者の判断 2026-08-06）。
                    Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '文例を検索中' -Progress 10 -Detail '' -Phase 'translating'
                    try {
                        $catSample = (@($cat.items | ForEach-Object { [string]$_.text }) -join "`n")
                        $catRef = Get-YakuCorpusReference -Root $Root -InputText $catSample -Settings $settings -Direction ([string]$cat.direction) -Warnings $catWarnings -ProgressState $JobState
                        if ($null -eq $catRef) { $catRef = [pscustomobject]@{ Section=''; Examples=@(); Terms=@(); Count=0; Reason='not-loaded' } }
                        $result = [pscustomobject]@{
                            Kind = 'cat'; Mode = 'corpus'
                            ProjectId = [string]$cat.project_id
                            CorpusSection = [string]$catRef.Section
                            CorpusExamples = @($catRef.Examples)
                            CorpusCount = [int]$catRef.Count
                            CorpusReason = [string]$catRef.Reason
                            Warnings = @($catWarnings.ToArray())
                        }
                    } catch {
                        $result = [pscustomobject]@{ Kind = 'cat'; Mode = 'corpus'; Error = $_.Exception.Message }
                    }
                } else {
                Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '翻訳中' -Progress 10 -Detail '' -Phase 'translating'
                try {
                    # 同じ原文は1回だけ送る。割り戻しはこの中で行う。
                    $byText = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
                    $items = New-Object System.Collections.Generic.List[object]
                    foreach ($it in @($cat.items)) {
                        $text = [string]$it.text
                        if ([string]::IsNullOrWhiteSpace($text)) { continue }
                        if (-not $byText.ContainsKey($text)) {
                            $entry = [pscustomobject]@{ Index = ($items.Count + 1); Text = $text; BlockIds = (New-Object System.Collections.Generic.List[string]); Targets = (New-Object System.Collections.Generic.List[int]) }
                            $byText[$text] = $entry
                            [void]$items.Add($entry)
                        }
                        [void]$byText[$text].Targets.Add([int]$it.index)
                    }
                    $maxChars = Get-YakuSettingInt -Settings $settings -Name 'file_batch_chars' -Default 3000
                    # 文例は自動では引かない。引くかどうかは利用者が別のボタンで決める
                    # （利用者の判断 2026-08-06）。検索の往復が1回増えるので、
                    # 「検索だけ」「翻訳だけ」「検索してから翻訳」を選べるようにしてある。
                    # ここへ渡ってくるのは、既に検索して保持している文例だけ。
                    $catContext = @{ BatchOrdinal = 0; TotalBatches = @(Split-YakuFileTranslationItems -Items @($items.ToArray()) -MaxChars $maxChars).Count; MaxRetryDepth = 0; CorpusSection = ([string]$cat.corpus_section) }
                    $map = Invoke-YakuFileTranslationItems -Root $Root -Items @($items.ToArray()) -Settings $settings `
                        -Direction ([string]$cat.direction) -MaxChars $maxChars -Warnings $catWarnings `
                        -ProgressState $JobState -Context $catContext
                    $pairs = New-Object System.Collections.Generic.List[object]
                    foreach ($entry in @($items.ToArray())) {
                        if (-not $map.ContainsKey([int]$entry.Index)) { continue }
                        $translation = [string]$map[[int]$entry.Index]
                        if ([string]::IsNullOrWhiteSpace($translation)) { continue }
                        foreach ($t in @($entry.Targets)) { [void]$pairs.Add([ordered]@{ index = [int]$t; text = $translation }) }
                    }
                    $result = [pscustomobject]@{
                        Kind = 'cat'
                        Mode = 'translate'
                        ProjectId = [string]$cat.project_id
                        Translations = @($pairs.ToArray())
                        Sent = $items.Count
                        UsedCorpus = (-not [string]::IsNullOrWhiteSpace([string]$cat.corpus_section))
                        Warnings = @($catWarnings.ToArray())
                    }
                } catch {
                    $result = [pscustomobject]@{ Kind = 'cat'; Mode = 'translate'; Error = $_.Exception.Message }
                }
                }
            } elseif ($Kind -eq 'revise') {
                $rev = $ReviseJson | ConvertFrom-Json
                $revWarnings = New-Object System.Collections.Generic.List[object]
                Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '修正を依頼中' -Progress 20 -Detail '' -Phase 'translating'
                try {
                    $rev1 = Invoke-YakuTextRevision -Root $Root -InputText ([string]$rev.source_text) -CurrentText ([string]$rev.current_text) -Instruction ([string]$rev.instruction) -Settings $settings -Direction ([string]$rev.direction) -Style ([string]$rev.style) -ProgressState $JobState -Warnings $revWarnings
                    # 直っていないときに黙って同じ訳文を返すと、壊れたように見える。
                    # 指示が原文に反していれば、雛形は現訳のまま返すよう求めている。
                    $unchanged = ([string](@($rev1.Options)[0].MaskedTranslation).Trim() -eq ([string]$rev.current_text).Trim())
                    if ($unchanged) {
                        Add-YakuWarning -Warnings $revWarnings -Category 'revision' -Location '修正' -Details @{ Instruction=[string]$rev.instruction } -Message '訳文は変わりませんでした。指示が原文の事実と食い違うか、判断できなかった可能性があります。言い換えて、もう一度お試しください。'
                    }
                    $result = [pscustomobject]@{
                        Direction = [string]$rev1.Direction
                        DirectionLabel = $(if ([string]$rev1.Direction -eq 'to_en') { '日本語 → 英語' } else { '英語 → 日本語' })
                        MaskedCount = [int]$rev1.MaskedCount
                        KeptCount = [int]$rev1.KeptCount
                        InputLength = ([string]$rev.source_text).Length
                        SourceText = [string]$rev.source_text
                        Options = @($rev1.Options)
                        Raw = [string]$rev1.Raw
                        Prompt = [string]$rev1.Prompt
                        BatchCount = 1
                        Warnings = @($revWarnings.ToArray())
                        RevisedFrom = [string]$rev.instruction
                        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    }
                } catch {
                    $result = [pscustomobject]@{ Error = $_.Exception.Message; Prompt = ''; Direction = [string]$rev.direction }
                }
            } elseif ($Kind -eq 'file') {
                $result = Invoke-YakuFileTranslation -Root $Root -InputPath $FilePath -Settings $settings -ProgressState $JobState -Direction $Direction -Sheets $sheets -JobId ([string]$JobState['id'])
            } else {
                $result = Invoke-YakuTextTranslation -Root $Root -InputText $InputText -Settings $settings -ProgressState $JobState -DirectionOverride $TextDirectionOverride
            }
            if ([string]$JobState['mode'] -eq 'cancelled') { return }
            $JobState['result_json'] = ($result | ConvertTo-Json -Depth 80 -Compress)
            $terminalMode = 'done'
            if ($result -and ($result.PSObject.Properties.Name -contains 'Error') -and $result.Error) {
                $terminalMode = 'error'
                $JobState['label'] = 'Translation error'
                $JobState['class'] = 'warn'
                $JobState['detail'] = [string]$result.Error
                $JobState['progress'] = 100
            } else {
                $resultCompletionStatus = ''
                $resultCompletionDetail = ''
                try { $resultCompletionStatus = [string]$result.CompletionStatus } catch {}
                try { $resultCompletionDetail = [string]$result.CompletionDetail } catch {}
                $completedWithWarnings = ($Kind -eq 'file' -and $resultCompletionStatus -eq 'completed_with_warnings')
                $terminalMode = if ($completedWithWarnings) { 'completed_with_warnings' } else { 'done' }
                $JobState['label'] = if ($completedWithWarnings) { 'Completed with warnings' } else { 'Done' }
                $JobState['class'] = if ($completedWithWarnings) { 'warn' } else { 'ok' }
                $JobState['detail'] = if (-not [string]::IsNullOrWhiteSpace($resultCompletionDetail)) { $resultCompletionDetail } elseif ($Kind -eq 'file') { 'File translation completed.' } else { 'Translation completed.' }
                $JobState['progress'] = 100
                try {
                    if ($Kind -eq 'file') {
                        $JobState['output_path'] = [string]$result.OutputPath
                        $JobState['output_name'] = [string]$result.OutputName
                        $JobState['blocks_total'] = [int]$result.BlocksTotal
                        $JobState['blocks_translated'] = [int]$result.BlocksTranslated
                        if ($result.PSObject.Properties.Name -contains 'UniqueTextCount') {
                            $JobState['unique_total'] = [int]$result.UniqueTextCount
                            $JobState['unique_done'] = [int]$result.UniqueTextCount
                        }
                        try {
                            if ($result.PSObject.Properties.Name -contains 'BlocksRetainedOriginal') { $JobState['blocks_retained'] = [int]$result.BlocksRetainedOriginal }
                            elseif ($result.PSObject.Properties.Name -contains 'BlocksRetained') { $JobState['blocks_retained'] = [int]$result.BlocksRetained }
                            elseif ($result.PSObject.Properties.Name -contains 'OriginalKept') { $JobState['blocks_retained'] = [int]$result.OriginalKept }
                        } catch {}
                    }
                } catch {}
            }
            $JobState['completed_at'] = (Get-Date).ToString('s')
            $JobState['updated_at'] = (Get-Date).ToString('s')
            # Publish the terminal mode last. Once clients observe it, result_json and completion metadata are guaranteed ready.
            $JobState['mode'] = $terminalMode
        } catch {
            if ([string]$JobState['mode'] -eq 'cancelled') { return }
            $message = $_.Exception.Message
            try { Write-YakuLog "Translation job exception: $($_.Exception.ToString())" 'ERROR' } catch {}
            $JobState['result_json'] = ([pscustomobject]@{ Error=$message; Kind=$Kind } | ConvertTo-Json -Depth 10 -Compress)
            $JobState['label'] = 'Translation error'
            $JobState['class'] = 'warn'
            $JobState['detail'] = $message
            $JobState['progress'] = 100
            $JobState['completed_at'] = (Get-Date).ToString('s')
            $JobState['updated_at'] = (Get-Date).ToString('s')
            # Publish the terminal mode only after the error payload and completion metadata are ready.
            $JobState['mode'] = 'error'
        }
    }

    $warm = $null
    $ps = $null
    $runspace = $null
    $usedWarmRunspace = $false
    try {
        $warm = Use-YakuWarmTranslationRunspace -Root $root
        if ($warm) {
            $ps = $warm.PowerShell
            $runspace = $warm.Runspace
            $usedWarmRunspace = $true
            try { $null = $ps.Commands.Clear() } catch {}
        } else {
            $runspace = [runspacefactory]::CreateRunspace()
            try { $runspace.ApartmentState = [System.Threading.ApartmentState]::STA } catch {}
            $runspace.Open()
            $ps = [powershell]::Create()
            $ps.Runspace = $runspace
        }
        [void]$ps.AddScript($worker.ToString()).AddArgument($root).AddArgument($Kind).AddArgument($InputText).AddArgument($TextDirectionOverride).AddArgument($FilePath).AddArgument($Direction).AddArgument($sheetsJson).AddArgument($settingsJson).AddArgument($script:YakuBuildId).AddArgument($state).AddArgument($ReviseJson).AddArgument($CatJson)
        $async = $ps.BeginInvoke()
        # Publish only after BeginInvoke succeeds (transactional start).
        $script:YakuTranslateJobs[$jobId] = $state
        $script:YakuTranslateJobHandles[$jobId] = [pscustomobject]@{
            Type = 'Runspace'
            PowerShell = $ps
            Runspace = $runspace
            Async = $async
            Disposed = $false
            WarmRunspace = $usedWarmRunspace
        }
        $script:YakuActiveTranslateJobId = $jobId
    } catch {
        try { if ($ps) { $ps.Dispose() } } catch {}
        try { if ($runspace) { $runspace.Close() } } catch {}
        try { if ($runspace) { $runspace.Dispose() } } catch {}
        $state['mode']='failed'; $state['error_code']='RUNSPACE_START_FAILED'; $state['detail']=$_.Exception.Message; $state['completed_at']=(Get-Date).ToString('s')
        throw
    }
    Write-YakuLog "Translation job started. jobId=$jobId kind=$Kind inputLength=$inputLength file=$fileName warmRunspace=$usedWarmRunspace buildId=$($script:YakuBuildId) diagnosticsLevel=$diagnosticsLevel settingsSnapshot=job-start" 'INFO'
    return $state
}

function Convert-YakuTranslationJobStartedHtml {
    param([Parameter(Mandatory=$true)]$State)
    $jobId = [string]$State['id']
    $kind = [string]$State['kind']
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'text' }
    $inputLength = [string]$State['input_length']
    $fileName = [string]$State['file_name']
    $meta = if ($kind -eq 'file') { 'ファイル: ' + $fileName } else { $inputLength + '字' }
    $caption = if ($kind -eq 'file') { '抽出中' } elseif ($kind -eq 'revise') { '修正を依頼中' } elseif ($kind -eq 'cat') { '翻訳中' } else { '準備中' }
    # 修正はテキストの成果物なので、画面上はテキスト側へ描く。
    # ここの kind は「どちらのタブへ結果を入れるか」にしか使われない。
    if ($kind -eq 'revise') { $kind = 'text' }
    $html = @"
<div class='result-loading job-loading' data-yaku-job-id='$(ConvertTo-YakuHtml $jobId)' data-yaku-kind='$(ConvertTo-YakuHtml $kind)' title='Job: $(ConvertTo-YakuHtml $jobId)'>
  <div class='job-loading-inner'>
    <div class='job-topline'><div class='job-phase' role='status' aria-live='polite'>$(ConvertTo-YakuHtml $caption)</div><div class='job-percent'>0%</div></div>
    <div class='job-progress-line' role='progressbar' aria-label='翻訳進捗' aria-valuemin='0' aria-valuemax='100' aria-valuenow='0'><span class='job-progress-bar' style='width:0%'></span></div>
    <div class='job-bottomline'><div class='job-meta'>$(ConvertTo-YakuHtml $meta)</div><button type='button' class='secondary-button compact cancel-button' data-yaku-job-id='$(ConvertTo-YakuHtml $jobId)'>キャンセル</button></div>
  </div>
</div>
"@
    return $html
}

function Convert-YakuResultJsonToHtml {
    param(
        [Parameter(Mandatory=$true)][string]$ResultJson
    )
    $result = $ResultJson | ConvertFrom-Json
    if ($result -and ($result.PSObject.Properties.Name -contains 'Kind') -and [string]$result.Kind -eq 'file') {
        return Convert-YakuFileResultToHtml -Result $result -IncludeStatusOob:$false
    }
    # CAT の訳文はグリッドへ取り込むので、共有の結果欄には出さない。
    # ここでテキスト翻訳の描画へ落ちると、CAT の結果の形を知らないため壊れる。
    if ($result -and ($result.PSObject.Properties.Name -contains 'Kind') -and [string]$result.Kind -eq 'cat') {
        if (($result.PSObject.Properties.Name -contains 'Error') -and $result.Error) {
            return (New-YakuAlertHtml -Kind error -Message ([string]$result.Error))
        }
        return (New-YakuAlertHtml -Kind info -Message ('Copilot翻訳が完了しました。CATタブの一覧へ取り込みます。（' + [string]@($result.Translations).Count + ' セグメント）'))
    }
    return Convert-YakuTextResultToHtml -Result $result -IncludeStatusOob:$false
}

function Convert-YakuTranslationJobResultJson {
    param([Parameter(Mandatory=$true)]$State)
    Update-YakuTranslationJobs
    $mode = [string]$State['mode']
    $progress = 0
    try { $progress = [int]$State['progress'] } catch { $progress = 0 }
    $label = [string]$State['label']
    $detail = [string]$State['detail']
    $html = ''
    if ($mode -eq 'cancelled') {
        $html = New-YakuAlertHtml -Kind warning -Message '翻訳をキャンセルしました。'
    } elseif ($mode -in @('done','completed_with_warnings','error','failed','interrupted')) {
        $resultJson = [string]$State['result_json']
        if ([string]::IsNullOrWhiteSpace($resultJson)) {
            $lazyPath = ''
            try { $lazyPath = [string]$State['result_path'] } catch { $lazyPath = '' }
            if (-not [string]::IsNullOrWhiteSpace($lazyPath) -and (Test-Path -LiteralPath $lazyPath -PathType Leaf)) {
                try {
                    $resultJson = Get-Content -LiteralPath $lazyPath -Raw -Encoding UTF8
                    $State['result_json'] = $resultJson
                } catch {
                    try { Write-YakuLog "Result fallback load failed. jobId=$($State['id']) error=$($_.Exception.Message)" 'WARN' } catch {}
                }
            }
        }
        if (![string]::IsNullOrWhiteSpace($resultJson)) {
            try {
                $html = Convert-YakuResultJsonToHtml -ResultJson $resultJson
            } catch {
                $html = New-YakuAlertHtml -Kind error -Message ('翻訳結果の復元に失敗しました: ' + $_.Exception.Message)
                $mode = 'error'
            }
        } else {
            $lazyPath = ''
            try { $lazyPath = [string]$State['result_path'] } catch { $lazyPath = '' }
            $completedAt = ''
            try { $completedAt = [string]$State['completed_at'] } catch { $completedAt = '' }
            if ([string]::IsNullOrWhiteSpace($resultJson) -and
                [string]::IsNullOrWhiteSpace($lazyPath) -and
                [string]::IsNullOrWhiteSpace($completedAt)) {
                # Defensive downgrade: do not let the client stop polling while terminal publication is still incomplete.
                $mode = 'working'
                $label = '仕上げ中'
                $detail = '結果を保存しています'
                $progress = [Math]::Min(99, [Math]::Max(0, $progress))
                $html = ''
            } else {
                $html = New-YakuAlertHtml -Kind warning -Message '翻訳結果はまだ保存されていません。出力ファイルは outputs フォルダに保存されている場合があります。ツールを再起動すると結果を再表示できます。'
            }
        }
    }
    return ([ordered]@{
        jobId = [string]$State['id']
        mode = $mode
        label = $label
        class = [string]$State['class']
        detail = $detail
        progress = $progress
        html = $html
        kind = [string]$State['kind']
        phase = [string]$State['phase']
        blocks_total = [int]$State['blocks_total']
        blocks_translated = [int]$State['blocks_translated']
        blocks_retained = [int]$State['blocks_retained']
        unique_done = [int]$State['unique_done']
        unique_total = [int]$State['unique_total']
        updated_at = [string]$State['updated_at']
        error_code = [string]$State['error_code']
        completion_status = [string]$State['completion_status']
    } | ConvertTo-Json -Depth 40 -Compress)
}

function Test-YakuSameOriginValue {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -eq 'http' -and $uri.Host -eq '127.0.0.1' -and $uri.Port -eq [int]$script:ActivePort)
}

function Assert-YakuRequestBoundary {
    param([Parameter(Mandatory=$true)]$Request, [Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Method)
    $expectedHost = '127.0.0.1:' + [string]$script:ActivePort
    if (-not [string]::Equals([string]$Request.Headers['Host'], $expectedHost, [System.StringComparison]::OrdinalIgnoreCase)) { throw [System.UnauthorizedAccessException]::new('INVALID_HOST') }
    if ($Path -eq '/api/instance') { return }
    if (-not ($Path.StartsWith('/api/') -or $Path -eq '/shutdown')) { return }
    $providedTokenBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Request.Headers['X-Yaku-Session'])
    $expectedTokenBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$script:YakuSessionToken)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $providedHash = $sha256.ComputeHash($providedTokenBytes); $expectedHash = $sha256.ComputeHash($expectedTokenBytes) } finally { $sha256.Dispose() }
    $tokenDiff = 0
    for ($tokenIndex = 0; $tokenIndex -lt $expectedHash.Length; $tokenIndex++) { $tokenDiff = $tokenDiff -bor ($providedHash[$tokenIndex] -bxor $expectedHash[$tokenIndex]) }
    if ($tokenDiff -ne 0) { throw [System.UnauthorizedAccessException]::new('INVALID_SESSION_TOKEN') }
    if ([string]$Request.Headers['Sec-Fetch-Site'] -eq 'cross-site') { throw [System.UnauthorizedAccessException]::new('CROSS_SITE_REQUEST') }
    if (-not (Test-YakuSameOriginValue -Value ([string]$Request.Headers['Origin']))) { throw [System.UnauthorizedAccessException]::new('INVALID_ORIGIN') }
    if (-not (Test-YakuSameOriginValue -Value ([string]$Request.Headers['Referer']))) { throw [System.UnauthorizedAccessException]::new('INVALID_REFERER') }
    if ($Method -eq 'POST') {
        $contentType = ([string]$Request.ContentType).ToLowerInvariant()
        if (-not ($contentType.StartsWith('application/json') -or $contentType.StartsWith('application/octet-stream'))) {
            throw [System.UnauthorizedAccessException]::new('UNSUPPORTED_CONTENT_TYPE')
        }
    }
}

function Read-YakuRequestJson {
    param([Parameter(Mandatory=$true)]$Request, [int64]$MaxBytes = 2097152)
    $body = Read-YakuRequestBodyText -Request $Request -MaxBytes $MaxBytes
    if ([string]::IsNullOrWhiteSpace($body)) { return @{} }
    $object = $body | ConvertFrom-Json
    if ($null -eq $object -or $object -is [System.Array] -or $object -is [string] -or $object -is [ValueType]) { throw 'JSONオブジェクトを指定してください。' }
    $form = @{}
    foreach ($prop in @($object.PSObject.Properties)) { $form[[string]$prop.Name] = $prop.Value }
    return $form
}

function Clear-YakuExpiredUploads {
    $now = Get-Date
    $protectedDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($job in @($script:YakuTranslateJobs.Values)) {
        try {
            if (-not (Test-YakuTranslationJobRunning -State $job)) { continue }
            $activeInput = [string]$job['input_file_path']
            if (-not [string]::IsNullOrWhiteSpace($activeInput)) { [void]$protectedDirs.Add([System.IO.Path]::GetFullPath((Split-Path -Parent $activeInput))) }
        } catch {}
    }
    foreach ($id in @($script:YakuUploadHandles.Keys)) {
        try {
            $item = $script:YakuUploadHandles[$id]
            if ([datetime]$item.ExpiresAt -gt $now) { continue }
            if ($item.Path -and (Test-Path -LiteralPath ([string]$item.Path))) { Remove-Item -LiteralPath (Split-Path -Parent ([string]$item.Path)) -Recurse -Force -ErrorAction SilentlyContinue }
            $script:YakuUploadHandles.Remove([string]$id)
        } catch {}
    }
    foreach ($state in @($script:YakuTranslateJobs.Values)) {
        try {
            if ((Test-YakuTranslationJobRunning -State $state) -or -not [bool]$state['uploaded_input']) { continue }
            $inputPath = [string]$state['input_file_path']
            if ([string]::IsNullOrWhiteSpace($inputPath)) { continue }
            $uploadsRoot = [System.IO.Path]::GetFullPath((Get-YakuSubDir 'uploads')).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
            $full = [System.IO.Path]::GetFullPath($inputPath)
            if ($full.StartsWith($uploadsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $dir = Split-Path -Parent $full
                if (Test-Path -LiteralPath $dir -PathType Container) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        } catch {}
    }
    try {
        $cutoff = (Get-Date).AddHours(-1)
        foreach ($dir in @(Get-ChildItem -LiteralPath (Get-YakuSubDir 'uploads') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })) {
            $known = $false
            foreach ($item in @($script:YakuUploadHandles.Values)) { if ([string]$item.Path -and (Split-Path -Parent ([string]$item.Path)) -eq $dir.FullName) { $known=$true; break } }
            if (-not $known -and -not $protectedDirs.Contains([System.IO.Path]::GetFullPath($dir.FullName))) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
    try {
        $tempCutoff = (Get-Date).AddDays(-1)
        foreach ($dir in @(Get-ChildItem -LiteralPath (Get-YakuSubDir 'outputs') -Directory -Filter '.yakulingo-job-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $tempCutoff })) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
            try { Write-YakuLog "Stale output temp directory removed. path=$($dir.FullName)" 'INFO' } catch {}
        }
    } catch { try { Write-YakuLog "Stale output temp sweep failed. error=$($_.Exception.Message)" 'WARN' } catch {} }
}

function Save-YakuBinaryUpload {
    param([Parameter(Mandatory=$true)]$Request, [Parameter(Mandatory=$true)]$Settings)
    $maxBytes = Get-YakuFileUploadBodyLimitBytes -Settings $Settings
    $length = [int64]$Request.ContentLength64
    if ($length -gt $maxBytes) { throw "ファイルサイズが上限を超えています。上限=$maxBytes bytes、実サイズ=$length bytes" }
    $encodedName = [string]$Request.Headers['X-Yaku-File-Name']
    if ([string]::IsNullOrWhiteSpace($encodedName)) { throw 'ファイル名がありません。' }
    try { $fileName = [System.Uri]::UnescapeDataString($encodedName) } catch { throw 'ファイル名を解析できません。' }
    $safeName = New-SafeFileName -FileName $fileName
    $ext = [System.IO.Path]::GetExtension($safeName).ToLowerInvariant()
    if (@('.xlsx','.xlsm','.csv') -notcontains $ext) { throw '対応しているファイル形式は .xlsx / .xlsm / .csv です。' }
    $uploadId = [guid]::NewGuid().ToString('N')
    $dir = Join-Path (Get-YakuSubDir 'uploads') $uploadId
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir $safeName
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $total = [int64]0
        while (($read = $Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $maxBytes) { throw 'ファイルサイズが上限を超えています。' }
            $stream.Write($buffer, 0, $read)
        }
        $stream.Flush()
        if ($length -ge 0 -and $total -ne $length) { throw 'アップロードが途中で切断されました。' }
        if ($total -le 0) { throw '空のファイルはアップロードできません。' }
    } catch {
        try { if ($stream) { $stream.Dispose() } } catch {}; $stream=$null
        try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        throw
    } finally { try { if ($stream) { $stream.Dispose() } } catch {} }
    $handle = New-YakuSecureToken -ByteLength 24
    $item = [pscustomobject]@{ Handle=$handle; Path=$path; OriginalName=$safeName; Size=$total; ExpiresAt=(Get-Date).AddHours(1); Uploaded=$true }
    $script:YakuUploadHandles[$handle] = $item
    return $item
}

function Resolve-YakuIncomingFile {
    param([Parameter(Mandatory=$true)][hashtable]$Payload, [Parameter(Mandatory=$true)]$Settings)
    $handle = if ($Payload.ContainsKey('file_handle')) { [string]$Payload['file_handle'] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($handle)) {
        if (-not $script:YakuUploadHandles.ContainsKey($handle)) { throw 'アップロードの有効期限が切れました。ファイルを選び直してください。' }
        $item = $script:YakuUploadHandles[$handle]
        if ([datetime]$item.ExpiresAt -lt (Get-Date) -or !(Test-Path -LiteralPath ([string]$item.Path) -PathType Leaf)) { throw 'アップロードの有効期限が切れました。ファイルを選び直してください。' }
        return $item
    }
    $directPath = if ($Payload.ContainsKey('file_path')) { [string]$Payload['file_path'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($directPath)) { throw '翻訳するファイルを選択してください。' }
    if (-not [bool]$Settings.allow_direct_local_path) { throw '直接パス指定は無効です。' }
    $trimmed = $directPath.Trim().Trim('"')
    if ($trimmed.StartsWith('\\?\') -or $trimmed.StartsWith('\\.\')) { throw 'デバイスパスは使用できません。' }
    if ($trimmed.StartsWith('\\') -and -not [bool]$Settings.allow_network_paths) { throw 'UNCパスは既定で許可されていません。ファイル選択を使用してください。' }
    if (-not [System.IO.Path]::IsPathRooted($trimmed)) { throw '相対パスは使用できません。' }
    $full = [System.IO.Path]::GetFullPath($trimmed)
    if (!(Test-Path -LiteralPath $full -PathType Leaf)) { throw '指定されたファイルパスが見つかりません。' }
    [void](Get-YakuSupportedFileKind -Path $full)
    return [pscustomobject]@{ Handle=''; Path=$full; OriginalName=[System.IO.Path]::GetFileName($full); Size=(Get-Item -LiteralPath $full).Length; ExpiresAt=[datetime]::MaxValue; Uploaded=$false }
}

function Remove-YakuUploadHandle {
    param([AllowNull()][string]$Handle, [switch]$DeleteFile)
    if ([string]::IsNullOrWhiteSpace($Handle) -or -not $script:YakuUploadHandles.ContainsKey($Handle)) { return }
    $item = $script:YakuUploadHandles[$Handle]
    $script:YakuUploadHandles.Remove($Handle)
    if ($DeleteFile) { try { Remove-Item -LiteralPath (Split-Path -Parent ([string]$item.Path)) -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}


function Get-YakuMimeType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.js' { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        # V91.61: WebAssembly.instantiateStreaming は正しい MIME を要求する。
        '.wasm' { 'application/wasm' }
        '.txt' { 'text/plain; charset=utf-8' }
        default { 'application/octet-stream' }
    }
}

function Get-YakuContentSecurityPolicy {
    <#
      既定は script-src 'self' のみ。一般利用者の画面はこれを維持する。

      AllowWasm は管理画面（コーパス作成）専用。ブラウザは CSP に
      script-src がある場合、WebAssembly のコンパイルに 'wasm-unsafe-eval' を要求する。
      無いと WebAssembly.instantiateStreaming が
      「Refused to compile or instantiate WebAssembly module」で失敗する。
      'unsafe-eval' ではなく 'wasm-unsafe-eval' にするのは、
      eval() を許さず WebAssembly だけを許すため。
    #>
    param([switch]$AllowWasm)
    $scriptSrc = if ($AllowWasm) { "script-src 'self' 'wasm-unsafe-eval'" } else { "script-src 'self'" }
    return ("default-src 'self'; " + $scriptSrc + "; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
}

function Send-YakuResponse {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][byte[]]$Bytes,
        [string]$ContentType = 'text/html; charset=utf-8',
        [int]$StatusCode = 200,
        [switch]$AllowWasm
    )
    $resp = $Context.Response
    $resp.StatusCode = $StatusCode
    $resp.ContentType = $ContentType
    $resp.ContentLength64 = $Bytes.Length
    $resp.Headers['Cache-Control'] = 'no-store'
    $resp.Headers['X-Content-Type-Options'] = 'nosniff'
    $resp.Headers['X-Frame-Options'] = 'DENY'
    $resp.Headers['Referrer-Policy'] = 'no-referrer'
    $resp.Headers['Content-Security-Policy'] = Get-YakuContentSecurityPolicy -AllowWasm:$AllowWasm
    $resp.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $resp.OutputStream.Close()
}

function Send-YakuTextResponse {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$ContentType = 'text/html; charset=utf-8',
        [int]$StatusCode = 200,
        [switch]$AllowWasm
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Send-YakuResponse -Context $Context -Bytes $bytes -ContentType $ContentType -StatusCode $StatusCode -AllowWasm:$AllowWasm
}

function Get-YakuQueryValue {
    <#
      クエリ文字列の値を UTF-8 として取り出す。

      HttpListenerRequest.QueryString は、パーセントエンコードの復号に
      システムの ANSI コードページを使う。日本語 Windows では CP932 になるため、
      encodeURIComponent が作った UTF-8 のバイト列が化ける。
      例: 原本フォルダ -> 蜴滓悽繝輔か繝ｫ繝

      そこで RawUrl（生の要求行）から自分で取り出し、
      常に UTF-8 で復号する UnescapeDataString を使う。
    #>
    param(
        [Parameter(Mandatory=$true)]$Request,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $raw = [string]$Request.RawUrl
    $mark = $raw.IndexOf('?')
    if ($mark -lt 0) { return '' }
    $query = $raw.Substring($mark + 1)
    if ([string]::IsNullOrEmpty($query)) { return '' }
    foreach ($pair in $query.Split('&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $eq = $pair.IndexOf('=')
        $key = if ($eq -ge 0) { $pair.Substring(0, $eq) } else { $pair }
        try { $key = [System.Uri]::UnescapeDataString($key) } catch { continue }
        if (-not [string]::Equals($key, $Name, [System.StringComparison]::Ordinal)) { continue }
        if ($eq -lt 0) { return '' }
        try { return [System.Uri]::UnescapeDataString($pair.Substring($eq + 1)) } catch { return '' }
    }
    return ''
}

function Read-YakuRequestBodyText {
    param(
        [Parameter(Mandatory=$true)]$Request,
        [int64]$MaxBytes = 2097152
    )
    $length = [int64]$Request.ContentLength64
    if ($length -lt 0) { throw 'CONTENT_LENGTH_REQUIRED: chunked転送は受け付けていません。' }
    if ($length -eq 0) { return '' }
    if ($length -gt $MaxBytes) { throw 'リクエストサイズが大きすぎます。' }
    $bytes = New-Object byte[] ([int]$length)
    $offset = 0
    $deadline = (Get-Date).AddSeconds(15)
    while ($offset -lt $length) {
        if ((Get-Date) -gt $deadline) { throw 'REQUEST_BODY_TIMEOUT: リクエスト本文の受信がタイムアウトしました。' }
        $read = $Request.InputStream.Read($bytes, $offset, [int]($length - $offset))
        if ($read -le 0) { break }
        $offset += $read
    }
    if ($offset -ne $length) {
        $actual = New-Object byte[] $offset
        [Array]::Copy($bytes, $actual, $offset)
        $bytes = $actual
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-YakuFileUploadBodyLimitBytes {
    param([Parameter(Mandatory=$true)]$Settings)
    $mb = 50
    try { $mb = [int]$Settings.file_upload_max_mb } catch { $mb = 50 }
    if ($mb -lt 1) { $mb = 50 }
    return ([int64]$mb) * 1048576
}

function Get-YakuJobOutputPath {
    param([Parameter(Mandatory=$true)]$State)
    $path = [string]$State['output_path']
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    $resultJson = [string]$State['result_json']
    if (-not [string]::IsNullOrWhiteSpace($resultJson)) {
        try {
            $result = $resultJson | ConvertFrom-Json
            $path = [string]$result.OutputPath
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
        } catch {}
    }
    return ''
}

function Send-YakuDownloadResponse {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$Path
    )
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw '出力ファイルが見つかりません。' }
    $info = Get-Item -LiteralPath $Path
    $resp = $Context.Response
    $resp.StatusCode = 200
    $resp.ContentType = 'application/octet-stream'
    $resp.ContentLength64 = [int64]$info.Length
    $resp.Headers['Cache-Control'] = 'no-store'
    $resp.Headers['X-Content-Type-Options'] = 'nosniff'
    $fileName = [System.IO.Path]::GetFileName($Path)
    $encoded = [System.Uri]::EscapeDataString($fileName)
    $fallbackName = 'YakuLingo-output' + [System.IO.Path]::GetExtension($fileName)
    $resp.Headers['Content-Disposition'] = "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encoded"
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { $stream.CopyTo($resp.OutputStream) }
    finally { $stream.Dispose(); $resp.OutputStream.Close() }
}

function Serve-YakuStaticFile {
    param($Context, [string]$RelativePath)
    $base = Join-Path $script:YakuRoot 'www'
    $full = [System.IO.Path]::GetFullPath((Join-Path $base $RelativePath.TrimStart('/')))
    $baseFull = [System.IO.Path]::GetFullPath($base).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (!$full.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $full -PathType Leaf)) {
        Send-YakuTextResponse -Context $Context -Text 'Not found' -StatusCode 404 -ContentType 'text/plain; charset=utf-8'
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    Send-YakuResponse -Context $Context -Bytes $bytes -ContentType (Get-YakuMimeType -Path $full)
}

function Serve-YakuIndex {
    param([Parameter(Mandatory=$true)]$Context)
    $path = Join-Path $script:YakuRoot 'www\index.html'
    $html = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $settings = Read-YakuSettings -Root $script:YakuRoot
    $maxBytes = Get-YakuFileUploadBodyLimitBytes -Settings $settings
    $html = $html.Replace('__YAKU_SESSION_TOKEN__', (ConvertTo-YakuHtml $script:YakuSessionToken))
    $html = $html.Replace('__YAKU_MAX_UPLOAD_BYTES__', [string]$maxBytes)
    Send-YakuTextResponse -Context $Context -Text $html -ContentType 'text/html; charset=utf-8'
}

function Serve-YakuAdminPage {
    # V91.61: 管理画面。/api/ はセッショントークンを要求するため、
    # index.html と同じ差し込みを行う。差し込まないと画面から API を呼べない。
    param([Parameter(Mandatory=$true)]$Context)
    $path = Join-Path $script:YakuRoot 'www\admin.html'
    $html = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $html = $html.Replace('__YAKU_SESSION_TOKEN__', (ConvertTo-YakuHtml $script:YakuSessionToken))
    # 管理画面だけ WebAssembly を許す。一般利用者の画面は既定のまま。
    Send-YakuTextResponse -Context $Context -Text $html -ContentType 'text/html; charset=utf-8' -AllowWasm
}

function Invoke-YakuRoute {
    param([Parameter(Mandatory=$true)]$Context)
    $req = $Context.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod.ToUpperInvariant()

    try { Assert-YakuRequestBoundary -Request $req -Path $path -Method $method }
    catch [System.UnauthorizedAccessException] {
        Send-YakuTextResponse -Context $Context -Text 'Forbidden' -StatusCode 403 -ContentType 'text/plain; charset=utf-8'
        return
    }
    Clear-YakuExpiredUploads

    if ($method -eq 'GET' -and $path -eq '/') {
        Serve-YakuIndex -Context $Context
        return
    }
    if ($method -eq 'GET' -and $path.StartsWith('/assets/')) {
        Serve-YakuStaticFile -Context $Context -RelativePath $path.TrimStart('/')
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/instance') {
        Send-YakuTextResponse -Context $Context -Text ([ordered]@{ instance_id=$script:YakuInstanceId; pid=$PID; process_started_at=$script:YakuProcessStartedAt; build_id=$script:YakuBuildId } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/ready-state') {
        $state = Get-YakuTranslateReadinessState
        Send-YakuTextResponse -Context $Context -Text (Convert-YakuReadinessStateToJson -State $state) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/settings-form') {
        $settings = Read-YakuSettings -Root $script:YakuRoot
        Send-YakuTextResponse -Context $Context -Text (Convert-YakuSettingsFormToHtml -Settings $settings)
        return
    }
    if ($method -eq 'GET' -and $path -match '^/api/jobs/([a-f0-9]{32})$') {
        $jobId = [string]$Matches[1]
        Update-YakuTranslationJobs
        if (-not $script:YakuTranslateJobs.ContainsKey($jobId)) {
            Send-YakuTextResponse -Context $Context -Text ([ordered]@{ mode='error'; error_code='JOB_NOT_FOUND'; detail=(Get-YakuTranslationJobMissingMessage -JobId $jobId) } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 404
            return
        }
        Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobResultJson -State $script:YakuTranslateJobs[$jobId]) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/cancel-translation') {
        try {
            $payload = Read-YakuRequestJson -Request $req
            $jobId = [string]$payload['job_id']
            $state = Stop-YakuTranslationJob -JobId $jobId
            Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobResultJson -State $state) -ContentType 'application/json; charset=utf-8' -StatusCode 202
        } catch {
            $safe = Convert-YakuExceptionToUserMessage $_
            $payload = [ordered]@{ mode='error'; label='Translation error'; class='warn'; detail=$safe; progress=100; html=(New-YakuAlertHtml -Kind error -Message $safe) }
            Send-YakuTextResponse -Context $Context -Text ($payload | ConvertTo-Json -Depth 20 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 404
        }
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/download') {
        try {
            $jobId = Get-YakuQueryValue -Request $req -Name 'job_id'
            if ([string]::IsNullOrWhiteSpace($jobId)) { throw 'ジョブIDを指定してください。' }
            Update-YakuTranslationJobs
            if ([string]::IsNullOrWhiteSpace($jobId) -or -not $script:YakuTranslateJobs.ContainsKey($jobId)) { throw (Get-YakuTranslationJobMissingMessage -JobId $jobId) }
            $output = Get-YakuJobOutputPath -State $script:YakuTranslateJobs[$jobId]
            if ([string]::IsNullOrWhiteSpace($output)) { throw '出力ファイルが見つかりません。' }
            Send-YakuDownloadResponse -Context $Context -Path $output
        } catch {
            Send-YakuTextResponse -Context $Context -Text (Convert-YakuExceptionToUserMessage $_) -ContentType 'text/plain; charset=utf-8' -StatusCode 404
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/open-output') {
        try {
            $payload = Read-YakuRequestJson -Request $req
            $jobId = [string]$payload['job_id']
            Update-YakuTranslationJobs
            if ([string]::IsNullOrWhiteSpace($jobId) -or -not $script:YakuTranslateJobs.ContainsKey($jobId)) { throw (Get-YakuTranslationJobMissingMessage -JobId $jobId) }
            $output = Get-YakuJobOutputPath -State $script:YakuTranslateJobs[$jobId]
            if ([string]::IsNullOrWhiteSpace($output)) { throw '出力ファイルが見つかりません。' }
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $output + '"') | Out-Null } catch { Start-Process -FilePath (Split-Path -Parent $output) | Out-Null }
            Send-YakuTextResponse -Context $Context -Text (New-YakuAlertHtml -Kind success -Message '出力フォルダを開きました。')
        } catch {
            Send-YakuTextResponse -Context $Context -Text (New-YakuAlertHtml -Kind error -Message (Convert-YakuExceptionToUserMessage $_)) -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/upload') {
        try {
            $settings = Read-YakuSettings -Root $script:YakuRoot
            $upload = Save-YakuBinaryUpload -Request $req -Settings $settings
            $response = [ordered]@{ file_handle=[string]$upload.Handle; file_name=[string]$upload.OriginalName; file_size=[int64]$upload.Size; expires_at=([datetime]$upload.ExpiresAt).ToString('s') }
            Send-YakuTextResponse -Context $Context -Text ($response | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 201
        } catch {
            Send-YakuTextResponse -Context $Context -Text ([ordered]@{ error=(Convert-YakuExceptionToUserMessage $_); error_code='UPLOAD_FAILED' } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/file-info') {
        try {
            $settings = Read-YakuSettings -Root $script:YakuRoot
            $payload = Read-YakuRequestJson -Request $req
            $incoming = Resolve-YakuIncomingFile -Payload $payload -Settings $settings
            $info = Get-YakuFileInfo -Path ([string]$incoming.Path) -Settings $settings
            $info | Add-Member -NotePropertyName FileHandle -NotePropertyValue ([string]$incoming.Handle) -Force
            Send-YakuTextResponse -Context $Context -Text ($info | ConvertTo-Json -Depth 30 -Compress) -ContentType 'application/json; charset=utf-8'
        } catch {
            $payload = [ordered]@{ error=(Convert-YakuExceptionToUserMessage $_) }
            Send-YakuTextResponse -Context $Context -Text ($payload | ConvertTo-Json -Depth 10 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/translate-file') {
        $settings = Read-YakuSettings -Root $script:YakuRoot
        $incoming = $null
        $handle = ''
        try {
            $payload = Read-YakuRequestJson -Request $req
            $incoming = Resolve-YakuIncomingFile -Payload $payload -Settings $settings
            $handle = [string]$incoming.Handle
            $direction = if ($payload.ContainsKey('direction')) { [string]$payload['direction'] } else { 'to_en' }
            if (@('to_en','to_jp') -notcontains $direction) { $direction = 'to_en' }
            $sheets = @()
            if ($payload.ContainsKey('sheets')) {
                $sheets = @($payload['sheets'] | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }

            $readyState = Get-YakuTranslateReadinessState
            if (-not [bool]$readyState.canTranslate) {
                $label = [string]$readyState.label
                if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Preparing Copilot' }
                $klass = [string]$readyState.class
                if ([string]::IsNullOrWhiteSpace($klass)) { $klass = 'warn' }
                $message = if ([string]$readyState.mode -eq 'working') { '翻訳ジョブが実行中です。完了してから再実行してください。' } else { 'Copilotの準備が完了してからファイル翻訳できます。' }
                Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message $message)) -StatusCode 409
                return
            }

            $state = Start-YakuTranslationJob -Kind file -FilePath ([string]$incoming.Path) -Direction $direction -Sheets $sheets -Settings $settings -UploadedInput:([bool]$incoming.Uploaded)
            if (-not [string]::IsNullOrWhiteSpace($handle)) { Remove-YakuUploadHandle -Handle $handle }
            Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobStartedHtml -State $state)
        } catch {
            $safeError = Convert-YakuExceptionToUserMessage $_
            try { Write-YakuLog "File translate job start exception: $($_.Exception.ToString())" 'ERROR' } catch {}
            if ($incoming -and [bool]$incoming.Uploaded -and -not [string]::IsNullOrWhiteSpace($handle)) { Remove-YakuUploadHandle -Handle $handle -DeleteFile }
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind error -Message $safeError)) -StatusCode 400
        }
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/history') {
        Send-YakuTextResponse -Context $Context -Text (Get-YakuHistoryHtml)
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/privacy-status') {
        $historyPath = Join-Path (Get-YakuSubDir 'history') 'history.jsonl'
        $historyCount = 0
        try { if (Test-Path -LiteralPath $historyPath) { $historyCount = @(Get-Content -LiteralPath $historyPath -Encoding UTF8).Count } } catch {}
        $logsDir = Get-YakuSubDir 'logs'
        $diagnosticFiles = @()
        foreach ($pattern in @('copilot-*-diagnostic-*','copilot-wait-diagnostic-*')) { $diagnosticFiles += @(Get-ChildItem -LiteralPath $logsDir -Filter $pattern -File -ErrorAction SilentlyContinue) }
        $response = [ordered]@{ history_count=$historyCount; history_path=$historyPath; diagnostic_count=@($diagnosticFiles | Sort-Object FullName -Unique).Count; diagnostic_path=$logsDir }
        Send-YakuTextResponse -Context $Context -Text ($response | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/clear-history') {
        $cleared = Clear-YakuHistory
        Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$true; count=$cleared.Count; path=$cleared.Path } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/clear-diagnostics') {
        $dir = Get-YakuSubDir 'logs'; $count = 0
        foreach ($pattern in @('copilot-*-diagnostic-*','copilot-wait-diagnostic-*')) {
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue)) { try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $count++ } catch {} }
        }
        Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$true; count=$count; path=$dir } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
        return
    }
    # ---------------------------------------------------------------------
    # V91.61 参考資料コーパス（管理者用）。
    # $script:YakuAdminMode が偽のときは、この塊ごと素通りする。
    # 一般利用者の起動では経路が存在しないのと同じになる。
    # ---------------------------------------------------------------------
    if ($script:YakuAdminMode -and $path.StartsWith('/api/admin/corpus')) {
        if ($method -eq 'GET' -and $path -eq '/api/admin/corpus/status') {
            $sourceRoot = Get-YakuQueryValue -Request $req -Name 'root'
            $state = Get-YakuCorpusState -SourceRoot $sourceRoot
            $payload = [ordered]@{
                source_root = [string]$state.SourceRoot
                reachable   = [bool]$state.Reachable
                build_dir   = [string]$state.BuildDir
                done_count  = [int]$state.DoneCount
                relocated   = [int]$state.RelocatedCount
                stale       = @(@($state.StaleEntries) | ForEach-Object { [string]$_.source })
                databases   = @(@($state.Databases) | ForEach-Object { [ordered]@{ name=[string]$_.Database; done=[int]$_.Done; pending=[int]$_.Pending } })
                pending     = @(@($state.Pending) | ForEach-Object { [ordered]@{ id=[string]$_.id; sha256=[string]$_.sha256; database=[string]$_.database; source=[string]$_.source; bytes=[int64]$_.bytes; relocated=[bool]$_.relocated; previous=[string]$_.previous } })
            }
            Send-YakuTextResponse -Context $Context -Text ($payload | ConvertTo-Json -Depth 6) -ContentType 'application/json; charset=utf-8'
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/admin/corpus/pdf') {
            $sourceRoot = Get-YakuQueryValue -Request $req -Name 'root'
            $id = Get-YakuQueryValue -Request $req -Name 'id'
            # 原本フォルダを列挙し直して id を突き合わせる。パスを直接受け取らない。
            $match = @(Get-YakuCorpusSourceFiles -SourceRoot $sourceRoot | Where-Object { (Get-YakuCorpusFileId -Path $_.FullName).Id -eq $id } | Select-Object -First 1)
            if ($match.Count -eq 0) {
                Send-YakuTextResponse -Context $Context -Text 'Not found' -StatusCode 404 -ContentType 'text/plain; charset=utf-8'
                return
            }
            $bytes = [System.IO.File]::ReadAllBytes([string]$match[0].FullName)
            Send-YakuResponse -Context $Context -Bytes $bytes -ContentType 'application/pdf'
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/admin/corpus/ingest') {
            try {
                $payload = Read-YakuRequestJson -Request $req -MaxBytes 33554432
                $pageChars = @()
                if ($payload.ContainsKey('page_chars')) { $pageChars = @($payload['page_chars']) }
                $status = 'ok'
                if ([string]$payload['status'] -eq 'failed') { $status = 'failed' }
                elseif (Test-YakuCorpusLowText -PageChars $pageChars) { $status = 'low-text' }
                $null = Save-YakuCorpusMarkdown -BuildDir (Get-YakuCorpusBuildDir) `
                    -Id ([string]$payload['id']) -Sha256 ([string]$payload['sha256']) `
                    -Database ([string]$payload['database']) -Source ([string]$payload['source']) `
                    -Markdown ([string]$payload['markdown']) -Pages ([int]$payload['pages']) `
                    -Status $status -Note ([string]$payload['note'])
                Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$true; id=[string]$payload['id']; status=$status } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
            } catch {
                Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress) -StatusCode 400 -ContentType 'application/json; charset=utf-8'
            }
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/admin/corpus/search') {
            # 段階2 の確認用。索引が実データで引けるかを管理者が見るためだけの経路。
            # 一般利用者の画面には出さない（修正指示書 §11「一般利用者の画面は触らない」）。
            try {
                $query = Get-YakuQueryValue -Request $req -Name 'q'
                $dbRaw = Get-YakuQueryValue -Request $req -Name 'db'
                $topRaw = Get-YakuQueryValue -Request $req -Name 'top'
                $top = 5
                if (-not [string]::IsNullOrWhiteSpace($topRaw)) { try { $top = [int]$topRaw } catch { $top = 5 } }
                if ($top -lt 1) { $top = 1 }
                if ($top -gt 20) { $top = 20 }
                $databases = @()
                if (-not [string]::IsNullOrWhiteSpace($dbRaw)) {
                    $databases = @(($dbRaw -split ',') | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
                # 転置索引をやめる前の版が作ったフォルダを片付ける。
                # 作れたのは検索した端末だけなので、検索の経路で始末するのが筋。
                $null = Remove-YakuCorpusLegacyIndex
                $corpusDir = Get-YakuCorpusSearchDir
                if ([string]::IsNullOrWhiteSpace($corpusDir)) {
                    Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$true; corpus_dir=''; hits=@() } | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
                    return
                }
                # 索引を持たないので、件数は台帳から数える。
                $manifest = Read-YakuCorpusManifest -Dir $corpusDir
                $swSearch = [System.Diagnostics.Stopwatch]::StartNew()
                $hits = @(Search-YakuCorpus -Query $query -CorpusDir $corpusDir -Databases $databases -Top $top)
                $swSearch.Stop()
                Send-YakuTextResponse -Context $Context -Text ([ordered]@{
                    ok           = $true
                    corpus_dir   = [string]$corpusDir
                    documents    = @(@($manifest.entries) | Where-Object { [string]$_.status -ne 'failed' }).Count
                    elapsed_ms   = [int]$swSearch.Elapsed.TotalMilliseconds
                    search_terms = @(Get-YakuCorpusTokens -Text $query)
                    hits         = @(@($hits) | ForEach-Object { [ordered]@{ score=[double]$_.Score; database=[string]$_.Database; source=[string]$_.Source; page=[int]$_.Page; text=[string]$_.Text } })
                } | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8'
            } catch {
                Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress) -StatusCode 400 -ContentType 'application/json; charset=utf-8'
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/admin/corpus/publish') {
            try {
                $result = New-YakuCorpusPublishFolder
                Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$true; version=[string]$result.Version; path=[string]$result.Path; corpus_dir=[string]$result.CorpusDir; count=[int]$result.Count } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
            } catch {
                Send-YakuTextResponse -Context $Context -Text ([ordered]@{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress) -StatusCode 400 -ContentType 'application/json; charset=utf-8'
            }
            return
        }
        Send-YakuTextResponse -Context $Context -Text 'Not found' -StatusCode 404 -ContentType 'text/plain; charset=utf-8'
        return
    }
    if ($script:YakuAdminMode -and $method -eq 'GET' -and $path -eq '/admin') {
        Serve-YakuAdminPage -Context $Context
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/glossary') {
        Send-YakuTextResponse -Context $Context -Text (Convert-YakuGlossaryManagerToHtml -Root $script:YakuRoot)
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/settings') {
        try {
            $payload = Read-YakuRequestJson -Request $req
            if (-not $payload.ContainsKey('diagnostics_level')) {
                throw 'SETTINGS_DIAGNOSTICS_VALUE_MISSING: ログ診断レベルの送信値がありません。画面を再読み込みしてから保存してください。'
            }
            $settingsSchema = Get-YakuSettingsSchema
            $rawDiagnostics = $payload['diagnostics_level']
            $rawDiagnosticsType = if ($null -eq $rawDiagnostics) { 'null' } else { $rawDiagnostics.GetType().FullName }
            $requestedDiagnosticsLevel = [string](ConvertTo-YakuSettingValue -Name 'diagnostics_level' -Value $rawDiagnostics -Rule $settingsSchema['diagnostics_level'] -Strict)

            $savedItems = @(Save-YakuUserSettings -Root $script:YakuRoot -Form $payload)
            if ($savedItems.Count -ne 1 -or $null -eq $savedItems[0]) {
                throw 'SETTINGS_SAVE_RESULT_INVALID: 設定保存処理から有効な設定オブジェクトが返されませんでした。'
            }

            $diskItems = @(Read-YakuUserSettingsStrict -Root $script:YakuRoot)
            if ($diskItems.Count -ne 1 -or $null -eq $diskItems[0]) {
                throw 'SETTINGS_SAVE_READBACK_FAILED: 保存後の設定ファイルを読み直せませんでした。'
            }
            $diskSettings = ConvertTo-YakuHashtable $diskItems[0]
            if (-not $diskSettings.Contains('diagnostics_level')) {
                throw 'SETTINGS_SAVE_READBACK_FAILED: 保存後の設定にログ診断レベルがありません。'
            }
            $effectiveDiagnosticsLevel = [string](ConvertTo-YakuSettingValue -Name 'diagnostics_level' -Value $diskSettings['diagnostics_level'] -Rule $settingsSchema['diagnostics_level'] -Strict)
            if (-not [string]::Equals($requestedDiagnosticsLevel, $effectiveDiagnosticsLevel, [System.StringComparison]::Ordinal)) {
                Write-YakuLog "Settings save verification failed. errorCode=SETTINGS_SAVE_VERIFY_FAILED rawType=$rawDiagnosticsType diagnosticsLevelRequested=$requestedDiagnosticsLevel diagnosticsLevelEffective=$effectiveDiagnosticsLevel buildId=$($script:YakuBuildId)" 'ERROR'
                throw 'SETTINGS_SAVE_VERIFY_FAILED: ログ診断レベルを保存しましたが、再読込値が送信値と一致しません。'
            }
            Write-YakuLog "Settings saved. rawType=$rawDiagnosticsType diagnosticsLevelRequested=$requestedDiagnosticsLevel diagnosticsLevelEffective=$effectiveDiagnosticsLevel verified=True verificationSource=disk-readback buildId=$($script:YakuBuildId)" 'INFO'
            Clear-YakuTranslationCache
            Send-YakuTextResponse -Context $Context -Text "<div class='alert alert-success' data-yaku-settings-saved='true' data-yaku-diagnostics-level='$effectiveDiagnosticsLevel'>設定を保存しました。ログ診断レベル：$effectiveDiagnosticsLevel</div>"
        } catch {
            try {
                $errorText = ([string]$_.Exception.Message) -replace '[\r\n\t]+', ' '
                $errorCode = 'SETTINGS_SAVE_FAILED'
                if ($errorText -match '^([A-Z0-9_]+):') { $errorCode = [string]$Matches[1] }
                if ($errorText.Length -gt 300) { $errorText = $errorText.Substring(0, 300) + '...' }
                Write-YakuLog "Settings save failed. errorCode=$errorCode detail=$errorText buildId=$($script:YakuBuildId)" 'WARN'
            } catch {}
            Send-YakuTextResponse -Context $Context -Text (New-YakuAlertHtml -Kind error -Message (Convert-YakuExceptionToUserMessage $_)) -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/translate-text') {
        $payload = Read-YakuRequestJson -Request $req
        $settings = Read-YakuSettings -Root $script:YakuRoot
        $inputText = [string]$payload['input_text']
        $directionRaw = ''
        try { $directionRaw = [string]$payload['direction'] } catch { $directionRaw = '' }
        $directionOverride = ''
        if (@('to_en','to_jp') -contains $directionRaw) { $directionOverride = $directionRaw }
        if ([string]::IsNullOrWhiteSpace($inputText)) {
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message '翻訳するテキストを入力してください。')) -StatusCode 400
            return
        }

        $readyState = Get-YakuTranslateReadinessState
        if (-not [bool]$readyState.canTranslate) {
            $label = [string]$readyState.label
            if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Preparing Copilot' }
            $klass = [string]$readyState.class
            if ([string]::IsNullOrWhiteSpace($klass)) { $klass = 'warn' }
            $message = if ([string]$readyState.mode -eq 'working') { '翻訳ジョブが実行中です。ステータスが完了になるまでお待ちください。' } else { 'Copilotの準備が完了してから翻訳できます。EdgeでCopilotが開いている場合は、ログインと読み込み完了を待ってください。' }
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message $message)) -StatusCode 409
            return
        }

        try {
            $state = Start-YakuTranslationJob -InputText $inputText -Settings $settings -TextDirectionOverride $directionOverride
            Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobStartedHtml -State $state)
        } catch {
            $safeError = Convert-YakuExceptionToUserMessage $_
            try { Write-YakuLog "Translate job start exception: $($_.Exception.ToString())" 'ERROR' } catch {}
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind error -Message $safeError)) -StatusCode 400
        }
        return
    }
    # ---------------------------------------------------------------- CAT
    # ファイル翻訳と同じことを、押した分だけ進む形にする。
    # 段階ごとに口を分けているのは、途中を画面へ出すためである。
    if ($method -eq 'POST' -and $path.StartsWith('/api/cat/')) {
        $settings = Read-YakuSettings -Root $script:YakuRoot
        try {
            $payload = Read-YakuRequestJson -Request $req
            $action = $path.Substring('/api/cat/'.Length)

            if ($action -eq 'open') {
                $direction = 'to_en'
                try { if (@('to_en','to_jp') -contains [string]$payload['direction']) { $direction = [string]$payload['direction'] } } catch {}
                # 貼り付けたテキストからも開ける。簡易翻訳と入力の作法を揃え、
                # 覚え直しの負担を減らすため（利用者の懸念 2026-08-06）。
                $pastedText = ''
                try { $pastedText = [string]$payload['text'] } catch {}
                if (-not [string]::IsNullOrWhiteSpace($pastedText)) {
                    $project = New-YakuCatTextProject -Root $script:YakuRoot -Text $pastedText -Settings $settings -Direction $direction
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                    return
                }
                $incoming = Resolve-YakuIncomingFile -Payload $payload -Settings $settings
                $project = New-YakuCatProject -Root $script:YakuRoot -Path ([string]$incoming.Path) -Settings $settings -Direction $direction
                Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                return
            }

            $projectId = ''
            try { $projectId = [string]$payload['id'] } catch {}
            $project = Get-YakuCatProject -Id $projectId
            if ($null -eq $project) { throw '取り込んだファイルが見つかりません。もう一度「取り込む」を押してください。' }

            switch ($action) {
                'glossary' {
                    $null = Invoke-YakuCatGlossaryPass -Root $script:YakuRoot -Project $project -Settings $settings
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'merge' {
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $null = Merge-YakuCatSegments -Project $project -Index $index
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'split' {
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $null = Split-YakuCatSegment -Project $project -Index $index
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'candidates' {
                    # 現在行の候補。用語集と過去の対訳を手元のファイルから引く。
                    # どちらも Copilot への往復が要らないので、行を移るたびに出せる。
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $items = @(Get-YakuCatSegmentCandidates -Root $script:YakuRoot -Project $project -Index $index)
                    $rows = @($items | ForEach-Object { [ordered]@{ kind = [string]$_.Kind; source = [string]$_.Source; target = [string]$_.Target; exact = [bool]$_.Exact; ratio = [double]$_.Ratio; database = [string]$_.Database; verified = [bool]$_.Verified } })
                    Send-YakuTextResponse -Context $Context -Text (([ordered]@{ index = $index; candidates = @($rows) } | ConvertTo-Json -Depth 5 -Compress)) -ContentType 'application/json; charset=utf-8'
                }
                'segment' {
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $text = ''
                    try { $text = [string]$payload['text'] } catch {}
                    $null = Set-YakuCatSegmentTranslation -Project $project -Index $index -Text $text
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'translate' {
                    # Copilot への往復は他の翻訳と同じくジョブで行う（一度に1つ）。
                    # ジョブは別のランスペースで走るため、メモリ上のプロジェクトを
                    # 直接触れない。訳文だけを返させ、完了後に apply で反映する。
                    $readyState = Get-YakuTranslateReadinessState
                    if (-not [bool]$readyState.canTranslate) {
                        $message = if ([string]$readyState.mode -eq 'working') { '翻訳ジョブが実行中です。完了してからお試しください。' } else { 'Copilotの準備が完了してから翻訳できます。' }
                        Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message $message)) -StatusCode 409
                        return
                    }
                    $pending = @()
                    $segs = @($project.Segments)
                    for ($i = 0; $i -lt $segs.Count; $i++) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
                        $pending += ,([ordered]@{ index = $i; text = [string]$segs[$i].Text })
                    }
                    if (@($pending).Count -eq 0) {
                        Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind info -Message '訳す残りがありません。')) -StatusCode 409
                        return
                    }
                    # 文例は自動では付けない。「文例を検索」を押して引いてあれば使う。
                    # 押さなければ付かない。これで「検索だけ」「翻訳だけ」
                    # 「検索してから翻訳」の3通りが、ボタン1つ足すだけで揃う。
                    $catMode = 'translate'
                    try { if ([string]$payload['mode'] -eq 'corpus') { $catMode = 'corpus' } } catch {}
                    $catCorpus = ''
                    if ($catMode -eq 'translate') { try { $catCorpus = [string]$project.CorpusSection } catch { $catCorpus = '' } }
                    $catJson = ([ordered]@{ project_id = [string]$project.Id; direction = [string]$project.Direction; mode = $catMode; corpus_section = $catCorpus; items = @($pending) } | ConvertTo-Json -Depth 6 -Compress)
                    $state = Start-YakuTranslationJob -InputText '' -Settings $settings -Kind 'cat' -CatJson $catJson
                    Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobStartedHtml -State $state)
                }
                'apply' {
                    $jobId = ''
                    try { $jobId = [string]$payload['job_id'] } catch {}
                    Update-YakuTranslationJobs
                    if ([string]::IsNullOrWhiteSpace($jobId) -or -not $script:YakuTranslateJobs.ContainsKey($jobId)) { throw (Get-YakuTranslationJobMissingMessage -JobId $jobId) }
                    $resultJson = [string]$script:YakuTranslateJobs[$jobId]['result_json']
                    if ([string]::IsNullOrWhiteSpace($resultJson)) { throw '翻訳結果を取得できませんでした。' }
                    $result = $resultJson | ConvertFrom-Json
                    if ($result.PSObject.Properties.Name -contains 'Error' -and $result.Error) { throw [string]$result.Error }
                    # 文例の検索だけだったときは、引いたものを持っておく。
                    # 次に「残りを翻訳」を押したときに使う。押さなければ使わない。
                    if (($result.PSObject.Properties.Name -contains 'Mode') -and [string]$result.Mode -eq 'corpus') {
                        $project | Add-Member -NotePropertyName 'CorpusSection' -NotePropertyValue ([string]$result.CorpusSection) -Force
                        $project | Add-Member -NotePropertyName 'CorpusExamples' -NotePropertyValue (@($result.CorpusExamples)) -Force
                        Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                        return
                    }
                    $segs = @($project.Segments)
                    foreach ($pair in @($result.Translations)) {
                        $i = [int]$pair.index
                        if ($i -lt 0 -or $i -ge $segs.Count) { continue }
                        # 待っている間に人が直したものは踏まない。
                        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
                        $segs[$i].Translation = [string]$pair.text
                        $segs[$i].Origin = 'copilot'
                    }
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'export' {
                    $warnings = New-Object System.Collections.Generic.List[object]
                    # 貼り付けたテキストは書き戻す元が無いので、訳文を繋いで返す。
                    $outputPath = if ([string]$project.Source -eq 'text') { '' } else { Get-YakuTranslatedOutputPath -InputPath ([string]$project.Path) }
                    $exported = Export-YakuCatProject -Project $project -OutputPath $outputPath -Settings $settings -Warnings $warnings
                    $body = [ordered]@{
                        output_path = [string]$exported.OutputPath
                        output_name = [string]$exported.OutputName
                        text = $(try { [string]$exported.Text } catch { '' })
                        written = [int]$exported.Written
                        skipped = [int]$exported.Skipped
                    }
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
                }
                default { throw ('不明な操作です: ' + $action) }
            }
        } catch {
            $body = [ordered]@{ error = (Convert-YakuExceptionToUserMessage $_) }
            Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/revise-text') {
        # V91.61（2026-08-06）: できあがった訳文へ指示を1つ当てて直す。
        # 現訳はマスク後のものを受け取る。画面の訳文（実値入り）を送らせると、
        # 伏せたはずの数値が Copilot へ出る。
        $payload = Read-YakuRequestJson -Request $req
        $settings = Read-YakuSettings -Root $script:YakuRoot
        $srcText = ''
        $curText = ''
        $instruction = ''
        $revStyle = 'full'
        $revDirection = 'to_en'
        try { $srcText = [string]$payload['source_text'] } catch {}
        try { $curText = [string]$payload['current_text'] } catch {}
        try { $instruction = [string]$payload['instruction'] } catch {}
        try { if (@('full','brief') -contains [string]$payload['style']) { $revStyle = [string]$payload['style'] } } catch {}
        try { if (@('to_en','to_jp') -contains [string]$payload['direction']) { $revDirection = [string]$payload['direction'] } } catch {}
        if ([string]::IsNullOrWhiteSpace($instruction)) {
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message '修正の指示を入力してください。')) -StatusCode 400
            return
        }
        if ([string]::IsNullOrWhiteSpace($srcText) -or [string]::IsNullOrWhiteSpace($curText)) {
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message '修正のもとになる原文と訳文を取得できませんでした。もう一度翻訳してからお試しください。')) -StatusCode 400
            return
        }
        $readyState = Get-YakuTranslateReadinessState
        if (-not [bool]$readyState.canTranslate) {
            $message = if ([string]$readyState.mode -eq 'working') { '翻訳ジョブが実行中です。完了してからお試しください。' } else { 'Copilotの準備が完了してから修正を依頼できます。' }
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message $message)) -StatusCode 409
            return
        }
        try {
            $revisePayload = ([ordered]@{
                source_text  = $srcText
                current_text = $curText
                instruction  = $instruction
                style        = $revStyle
                direction    = $revDirection
            } | ConvertTo-Json -Depth 5 -Compress)
            $state = Start-YakuTranslationJob -InputText $srcText -Settings $settings -Kind 'revise' -ReviseJson $revisePayload
            Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobStartedHtml -State $state)
        } catch {
            $safeError = Convert-YakuExceptionToUserMessage $_
            try { Write-YakuLog "Revise job start exception: $($_.Exception.ToString())" 'ERROR' } catch {}
            Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind error -Message $safeError)) -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/shutdown') {
        # 並列用に自分で開いた Copilot ウィンドウを閉じる。開けっ放しにすると溜まる。
        # ジョブごとではなくここで閉じるのは、利用中は使い回したいため
        # （作り直すとウィンドウの生成と読み込みで数秒かかる）。
        try { if (Get-Command Close-YakuCopilotOwnedWindows -ErrorAction SilentlyContinue) { $null = Close-YakuCopilotOwnedWindows } } catch {}
        try { Clear-YakuCdpSocketCache } catch {}
        $script:ServerRunning = $false
        Send-YakuTextResponse -Context $Context -Text (New-YakuAlertHtml -Kind info -Message 'YakuLingoを停止しています。このブラウザタブを閉じてください。')
        return
    }
    Send-YakuTextResponse -Context $Context -Text 'Not found' -StatusCode 404 -ContentType 'text/plain; charset=utf-8'
}

function Start-YakuHttpListenerWithFallback {
    param(
        [int]$PreferredPort,
        [int]$MaxAttempts = 31
    )

    $errors = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        $candidate = $PreferredPort + $i
        $candidatePrefix = "http://127.0.0.1:$candidate/"
        $candidateListener = [System.Net.HttpListener]::new()
        try {
            $candidateListener.Prefixes.Add($candidatePrefix)
            $candidateListener.Start()
            return [pscustomobject]@{
                Listener = $candidateListener
                Prefix = $candidatePrefix
                Port = $candidate
                PreferredPort = $PreferredPort
            }
        } catch {
            $errors.Add("[$candidate] $($_.Exception.Message)") | Out-Null
            try { $candidateListener.Close() } catch {}
            if ($i -eq 0) {
                Write-Warning "ポート $candidate は使用できません。次の空きポートを試します。"
            }
        }
    }

    $lastPort = $PreferredPort + $MaxAttempts - 1
    $detail = ($errors -join "`n")
    throw "ローカルサーバーを開始できませんでした。$PreferredPort から $lastPort の範囲で空きポートがありません。`n$detail"
}

if (-not (Enter-YakuSingleInstance)) { return }
try { $startedServer = Start-YakuHttpListenerWithFallback -PreferredPort $Port }
catch { Exit-YakuSingleInstance; throw }
$listener = $startedServer.Listener
$prefix = [string]$startedServer.Prefix
$script:ActivePrefix = $prefix
$script:ActivePort = [int]$startedServer.Port
$script:YakuRuntimePath = $null

try {
    $runtimeDir = Get-YakuSubDir 'runtime'
    $script:YakuRuntimePath = Join-Path $runtimeDir 'server.json'
    $runtimeInfo = [pscustomobject]@{
        pid = $PID
        url = $prefix
        port = $script:ActivePort
        root = $script:YakuRoot
        started_at = (Get-Date).ToString('s')
        process_started_at = $script:YakuProcessStartedAt
        instance_id = $script:YakuInstanceId
        build_id = $script:YakuBuildId
    }
    Write-YakuJsonAtomic -Path $script:YakuRuntimePath -Value $runtimeInfo -Depth 6
} catch {
    Write-Warning "ランタイム情報を書き込めませんでした: $($_.Exception.Message)"
}

Write-Host "Listening on $prefix" -ForegroundColor Green
Write-YakuLog "YakuLingo server started. buildId=$($script:YakuBuildId) pid=$PID root=$($script:YakuRoot)" 'INFO'
Write-YakuLog 'M365 Copilot license environment required. Fixed prompt is approximately 9,300 characters; 8,000-character input-limit environments are unsupported.' 'INFO'
$serverInitializationSw = [System.Diagnostics.Stopwatch]::StartNew()
if ($script:ActivePort -ne $Port) {
    Write-Host "Preferred port $Port was busy. Using $($script:ActivePort) instead." -ForegroundColor Yellow
}
$warmupDispatchSw = [System.Diagnostics.Stopwatch]::StartNew()
Start-YakuCopilotWarmup
$warmupDispatchSw.Stop()
Write-YakuLog "Server startup timing. phase=warmup-worker-dispatch elapsedMs=$($warmupDispatchSw.ElapsedMilliseconds) sinceServerStartedMs=$($serverInitializationSw.ElapsedMilliseconds)" 'INFO'

$maintenanceSw = [System.Diagnostics.Stopwatch]::StartNew()
$startupSettings = Read-YakuSettings -Root $script:YakuRoot
Invoke-YakuDiagnosticLogRotation -RetentionDays ([int]$startupSettings.diagnostic_retention_days) -MainLogRetentionDays ([int]$startupSettings.log_retention_days)
Invoke-YakuHistoryRotation -RetentionDays ([int]$startupSettings.history_retention_days)
Clear-YakuExpiredUploads
Recover-YakuInterruptedJobs
$maintenanceSw.Stop()
Write-YakuLog "Server startup timing. phase=maintenance elapsedMs=$($maintenanceSw.ElapsedMilliseconds) sinceServerStartedMs=$($serverInitializationSw.ElapsedMilliseconds)" 'INFO'
Start-YakuWarmTranslationRunspaceBuild -Root $script:YakuRoot
$serverInitializationSw.Stop()
Write-YakuLog "Server startup timing. phase=initialization-complete elapsedMs=$($serverInitializationSw.ElapsedMilliseconds)" 'INFO'
if ($OpenBrowser) { Start-Process $prefix | Out-Null }

try {
    try {
        $listener.TimeoutManager.EntityBody = [timespan]::FromSeconds(15)
        $listener.TimeoutManager.DrainEntityBody = [timespan]::FromSeconds(5)
        $listener.TimeoutManager.IdleConnection = [timespan]::FromSeconds(30)
    } catch { try { Write-YakuLog "HttpListener timeout configuration unavailable. error=$($_.Exception.Message)" 'WARN' } catch {} }
    while ($script:ServerRunning) {
        $ctx = $listener.GetContext()
        try {
            Invoke-YakuRoute -Context $ctx
        } catch {
            $message = Convert-YakuExceptionToUserMessage $_
            try { Write-YakuLog "HTTP route exception: $($_.Exception.ToString())" 'ERROR' } catch {}
            try {
                Write-YakuLog "Route error: $message" 'ERROR'
                Send-YakuTextResponse -Context $ctx -StatusCode 500 -Text ((New-YakuAlertHtml -Kind error -Message $message))
            } catch {
                try { $ctx.Response.Close() } catch {}
            }
        }
    }
} finally {
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
    foreach ($id in @($script:YakuTranslateJobHandles.Keys)) { try { Dispose-YakuTranslationJobHandle -JobId ([string]$id) -Stop -SkipEndInvoke } catch {} }
    try { Dispose-YakuWarmTranslationRunspaceBuild } catch {}
    try { Dispose-YakuWarmTranslationRunspace -Warm $script:YakuWarmRunspace } catch {}
    $script:YakuWarmRunspace = $null
    if ($script:YakuRuntimePath) {
        try { Remove-Item -LiteralPath $script:YakuRuntimePath -ErrorAction SilentlyContinue } catch {}
    }
    try {
        $shutdownSettings = Read-YakuSettings -Root $script:YakuRoot
        Invoke-YakuDiagnosticLogRotation -RetentionDays ([int]$shutdownSettings.diagnostic_retention_days) -MainLogRetentionDays ([int]$shutdownSettings.log_retention_days)
        Invoke-YakuHistoryRotation -RetentionDays ([int]$shutdownSettings.history_retention_days)
    } catch {}
    Exit-YakuSingleInstance
    Write-Host 'YakuLingo server stopped.'
}
