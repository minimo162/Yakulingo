[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$OpenBrowser,
    [switch]$Admin
)

$ErrorActionPreference = 'Stop'
$script:YakuRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

. (Join-Path $PSScriptRoot 'SrcModules.ps1')
foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $PSScriptRoot $yakuSrcModule) }

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
                        # WebView2 shell がバックエンドを確認するための -NoBrowser 起動では、
                        # 既存serverを見つけても既定ブラウザーを勝手に開かない。
                        if ($OpenBrowser) { try { Start-Process ([string]$existing.url) | Out-Null } catch {} }
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
            $state['mode']='interrupted'; $state['label']='前回の異常終了により中断しました'; $state['class']='warn'; $state['detail']='前回の異常終了により処理を中断しました。'; $state['error_code']='RECOVERED_INTERRUPTED_JOB'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''
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
        return [pscustomobject]@{ ready=$true; mode='mock'; label='試験用モード（Copilotへは送りません）'; class='warn'; detail='Copilotへは送信しない設定になっています。'; updated_at=(Get-Date).ToString('s') }
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
    return [pscustomobject]@{ ready=$false; mode='not-started'; label='Copilotを準備しています'; class='idle'; detail='Copilot preparation has not started yet.'; updated_at='' }
}

function Start-YakuCopilotWarmup {
    if ($env:YAKULINGO_MOCK -eq '1') {
        $null = Write-YakuCopilotWarmupStatus -Mode 'mock' -Label '試験用モード（Copilotへは送りません）' -Class 'warn' -Detail 'Copilotへは送信しない設定になっています。' -Ready $true
        return
    }
    $statusPath = Get-YakuCopilotWarmupStatusPath
    $null = Write-YakuCopilotWarmupStatus -Mode 'starting' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Opening Microsoft Edge and M365 Copilot.' -Ready $false
    $worker = Join-Path $script:YakuRoot 'tools\Prepare-Copilot.ps1'
    if (!(Test-Path -LiteralPath $worker -PathType Leaf)) {
        $null = Write-YakuCopilotWarmupStatus -Mode 'error' -Label 'Copilotを準備できませんでした' -Class 'warn' -Detail '準備用のファイルが見つかりませんでした。アプリを一式入れ直してください。' -Ready $false
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
        $null = Write-YakuCopilotWarmupStatus -Mode 'error' -Label 'Copilotを準備できませんでした' -Class 'warn' -Detail 'アプリを閉じて開き直してください。それでも直らない場合は管理者へご連絡ください。' -Ready $false
        Write-YakuLog "Failed to start Copilot warmup worker: $($_.Exception.Message)" 'ERROR'
    }
}

function Get-YakuCopilotBadgeState {
    $warmup = Read-YakuCopilotWarmupStatus
    $ready = $false
    try { $ready = [bool]$warmup.ready } catch { $ready = $false }
    $label = if ($ready) { '使えます' } elseif ($warmup.label) { [string]$warmup.label } else { 'Copilotを準備しています' }
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
            # 実行中はボタンを押せない。ここで Copilot のバッジ（準備完了なら「使えます」）を
            # そのまま返していたので、画面には緑の「使えます」が出たまま操作だけが死んでいた。
            # 押せない理由そのものをバッジに出す。
            $busyLabel = if ($kind -eq 'cat' -or $kind -eq 'file') { '資料の翻訳を実行中' } else { 'ほかの翻訳を実行中' }
            return [pscustomobject]@{ ready=$ready; canTranslate=$false; mode='working'; label=$busyLabel; class='warn'; detail=$detail; updated_at=(Get-Date).ToString('s'); jobId=$jobId; progress=$progress; kind=$kind; phase=$phase; jobLabel=[string]$job['label'] }
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
    $calls3h = 0
    try { $calls3h = [int](Get-YakuCopilotCallCount -WindowHours 3) } catch { $calls3h = 0 }
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
        copilotCalls3h = $calls3h
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
        return "<span class='status-dot warn'></span><span>準備中</span>"
    }
    if ($mode -eq 'ready') {
        return "<span class='status-dot ok'></span><span>使えます</span>"
    }
    if ($mode -eq 'login') {
        return "<span class='status-dot warn'></span><span>ログインが必要</span>"
    }
    if ($mode -eq 'not-ready') {
        return "<span class='status-dot warn'></span><span>準備が終わりません</span>"
    }
    if ($mode -eq 'working') { return $null }
    if ($mode -eq 'done') {
        return "<span class='status-dot ok'></span><span>完了</span>"
    }
    if ($mode -eq 'error') {
        return "<span class='status-dot warn'></span><span>翻訳できませんでした</span>"
    }
    if ($mode -eq 'cancelled') {
        return "<span class='status-dot idle'></span><span>中止しました</span>"
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
    if ($message -match '(?:EXTERNAL_SEND_|PROTECTION_RECEIPT_|PROTECTED_PROMPT_|CAT_PROTECTED_|SHORTEN_UNMASKED_CURRENT)') {
        return '安全に送る準備を完了できなかったため、送信を中止しました。原文は送信されていません。再起動後も続く場合は管理者へ連絡してください。（YK-PROTECT-01）'
    }
    $message = $message -replace '[\r\n\t]+', ' '
    $message = $message.Trim()
    # 内部のエラーコードをそのまま画面へ出すと、利用者には「重大な障害」に見えて
    # そこで手が止まる。日本語の本文だけを残し、番号は問い合わせ用に末尾へ回す。
    if ($message -match '^([A-Z][A-Z0-9_]{4,}):\s*(.+)$') {
        $code = [string]$Matches[1]
        $body = [string]$Matches[2]
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $message = $body.Trim() + '（お問い合わせ番号: ' + $code + '）'
        }
    }
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
    return 'この翻訳の記録が見つかりません。お手数ですが、もう一度最初からお試しください。'
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
            . (Join-Path $Root 'src\SrcModules.ps1')
            foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }
            $null = Assert-YakuBuildIdentity -Root $Root -ExpectedBuildId $ExpectedBuildId
            $preloadSw = [System.Diagnostics.Stopwatch]::StartNew()
            $settings = Read-YakuSettings -Root $Root
            $null = Get-YakuPromptTemplate -Root $Root -Name 'text_translate_full_to_en.txt'
            $null = New-YakuTextPrompt -Root $Root -InputText 'ウォームアップ' -Settings $settings -DirectionOverride 'to_en' -RequestId 'warmup00000000000000000000000000' -Mode 'full'
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
                    . (Join-Path $Root 'src\SrcModules.ps1')
                    foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }
                    $null = Assert-YakuBuildIdentity -Root $Root -ExpectedBuildId $ExpectedBuildId
                    $preloadSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $settings = Read-YakuSettings -Root $Root
                    $null = Get-YakuPromptTemplate -Root $Root -Name 'text_translate_full_to_en.txt'
                    $null = New-YakuTextPrompt -Root $Root -InputText 'ウォームアップ' -Settings $settings -DirectionOverride 'to_en' -RequestId 'warmup00000000000000000000000000' -Mode 'full'
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

function Update-YakuTranslationJobs {
    try { Update-YakuWarmTranslationRunspace } catch {}
    try {
        foreach ($id in @($script:YakuTranslateJobHandles.Keys)) {
            $handle = $script:YakuTranslateJobHandles[$id]
            if ($null -eq $handle) { continue }
            $disposed = $false
            try { $disposed = [bool]$handle.Disposed } catch { $disposed = $false }
            if ($disposed) { continue }
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
                        $state['label'] = '翻訳できませんでした'
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
                    $state['mode']='cancelled'; $state['label']='中止しました'; $state['class']='idle'; $state['detail']='翻訳をキャンセルしました。'; $state['error_code']='JOB_CANCELLED'; $state['progress']=100; $state['completed_at']=(Get-Date).ToString('s'); $state['updated_at']=(Get-Date).ToString('s'); $state['output_path']=''; $state['result_json']=([pscustomobject]@{ Error='翻訳をキャンセルしました。'; Cancelled=$true } | ConvertTo-Json -Depth 10 -Compress)
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
        throw 'この翻訳の記録が見つかりません。お手数ですが、もう一度最初からお試しください。'
    }

    $state = $script:YakuTranslateJobs[$JobId]
    try {
        if ([bool]$state['cancel_requested'] -and (Test-YakuTranslationJobRunning -State $state)) {
            $state['mode']='cancelling'; $state['label']='翻訳をやめています'; $state['class']='warn'; $state['detail']='専用ワーカーを停止しています。'; $state['output_path']=''
            return $state
        }
    } catch {}
    if (Test-YakuTranslationJobRunning -State $state) {
        $message = 'キャンセル処理を開始しました。'
        $state['mode'] = 'cancelling'
        $state['label'] = '翻訳をやめています'
        $state['class'] = 'warn'
        $state['detail'] = $message
        $state['updated_at'] = (Get-Date).ToString('s')
        $state['cancel_requested'] = $true
        $handle = $script:YakuTranslateJobHandles[$JobId]
        try { $null = $handle.PowerShell.BeginStop($null, $null) } catch {}
        $state['output_path'] = ''
        Write-YakuLog "Translation cancellation accepted. jobId=$JobId" 'INFO'
    }
    return $state
}

function Start-YakuTranslationJob {
    param(
        [AllowNull()][string]$InputText = '',
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()][string]$TextDirectionOverride = '',
        # 2026-08-13: 'quick' と 'quick_revise' を外した。訳案を1枚返す状態を
        # 廃止したので、この種類で仕事を始める呼出側が無くなった。
        [ValidateSet('text','revise','shorten','cat')][string]$Kind = 'text',
        [ValidateSet('default','none')][string]$CachePolicy = 'default',
        [ValidateSet('display','none')][string]$ReferencePolicy = 'display',
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

    $jobId = ([guid]::NewGuid().ToString('N'))
    $diagnosticsLevel = 'standard'
    try { $diagnosticsLevel = Get-YakuDiagnosticsLevel -Settings $Settings } catch { $diagnosticsLevel = 'standard' }
    $diagnosticsEnabled = ($diagnosticsLevel -eq 'full')
    $fileName = ''
    $inputLength = ([string]$InputText).Length
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
        output_path = ''
        output_name = ''
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
    $root = [string]$script:YakuRoot
    $worker = {
        param(
            [Parameter(Mandatory=$true)][string]$Root,
            [Parameter(Mandatory=$true)][string]$Kind,
            [AllowNull()][string]$InputText,
            [AllowNull()][string]$TextDirectionOverride,
            [Parameter(Mandatory=$true)][string]$SettingsJson,
            [Parameter(Mandatory=$true)][string]$ExpectedBuildId,
            [Parameter(Mandatory=$true)]$JobState,
            [AllowNull()][string]$ReviseJson,
            [AllowNull()][string]$CatJson,
            [Parameter(Mandatory=$true)][string]$CachePolicy,
            [Parameter(Mandatory=$true)][string]$ReferencePolicy
        )
        $ErrorActionPreference = 'Stop'
        $startupSw = [System.Diagnostics.Stopwatch]::StartNew()
        $moduleLoadMs = 0
        $buildIdentityMs = 0
        $settingsReadMs = 0
        try {
            $script:YakuRoot = $Root
            $sectionSw = [System.Diagnostics.Stopwatch]::StartNew()
            if (-not (Get-Command Invoke-YakuProtectedCopilotPrompt -ErrorAction SilentlyContinue)) {
                . (Join-Path $Root 'src\SrcModules.ps1')
                foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }
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
            $JobState['mode'] = 'working'
            $JobState['label'] = 'Copilotへ送る文章を用意しています'
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
                    throw 'CAT_CORPUS_MODE_RETIRED: 過去の翻訳例は候補一覧から明示的に挿入してください。'
                } elseif ($catMode -eq 'align') {
                    # 既にある訳と突き合わせる。訳はしない。
                    # 数分かかるのでジョブに乗せる。組み立てはサーバー側で行う
                    # （プロジェクトはサーバーの手元に持つため）。
                    Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '対訳を突き合わせ中' -Progress 10 -Detail '' -Phase 'translating'
                    try {
                        $alignClean = {
                            param([string]$Text)
                            return @(($Text -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim().Length -ge 4 })
                        }
                        $alignToEn = ([string]$cat.direction -eq 'to_en')
                        $alignSrc = @(& $alignClean ([string]$cat.source_text))
                        $alignTgt = @(& $alignClean ([string]$cat.target_text))
                        # 切り分けは日本語を軸にする。実測した壁（50行）が日本語基準のため。
                        $alignJa = if ($alignToEn) { $alignSrc } else { $alignTgt }
                        $alignEn = if ($alignToEn) { $alignTgt } else { $alignSrc }
                        if ($alignJa.Count -eq 0 -or $alignEn.Count -eq 0) { throw '日本語と英語の両方が必要です。片方が空でした。' }
                        $alignRes = Invoke-YakuDocumentAlignment -JaLines $alignJa -EnLines $alignEn -Settings $settings
                        $result = [pscustomobject]@{
                            Kind = 'cat'; Mode = 'align'
                            ProjectId = [string]$cat.project_id
                            ProjectRevision = [int]$cat.expected_project_revision
                            FileName = [string]$cat.file_name
                            Direction = [string]$cat.direction
                            Pairs = @(@($alignRes.Pairs) | ForEach-Object { [pscustomobject]@{ JaText = [string]$_.JaText; EnText = [string]$_.EnText } })
                            JaCoverage = [double]$alignRes.JaCoverage
                            Dropped = [int]$alignRes.Dropped
                            Calls = [int]$alignRes.Calls
                            Warnings = @($catWarnings.ToArray())
                        }
                    } catch {
                        $result = [pscustomobject]@{ Kind = 'cat'; Mode = 'align'; Error = $_.Exception.Message }
                    }
                } elseif ($catMode -eq 'revise') {
                    # CAT の現在行へ自由入力の指示を1つ当てる。現訳は実値へ
                    # 戻す前の MaskedTranslation だけを受け取り、修正後も同じ行へ戻す。
                    Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '修正を依頼中' -Progress 20 -Detail '' -Phase 'translating'
                    try {
                        $revItem = @($cat.items)[0]
                        if ($null -eq $revItem) { throw '修正する行を取得できませんでした。' }
                        $rev1 = Invoke-YakuTextRevision -Root $Root -InputText ([string]$revItem.text) `
                            -CurrentText ([string]$revItem.current_text) -Instruction ([string]$revItem.instruction) `
                            -Settings $settings -Direction ([string]$cat.direction) -Style 'full' `
                            -Notation $(if ([string]$cat.amount_notation -eq 'billion') { 'billion' } else { 'oku' }) `
                            -ProgressState $JobState -Warnings $catWarnings
                        $revOption = @($rev1.Options)[0]
                        $result = [pscustomobject]@{
                            Kind = 'cat'; Mode = 'revise'; ProjectId = [string]$cat.project_id; ProjectRevision = [int]$cat.expected_project_revision
                            Translations = @([ordered]@{
                                index = [int]$revItem.index
                                text = [string]$revOption.Translation
                                masked = [string]$revOption.MaskedTranslation
                                previous_masked = [string]$revItem.current_text
                                source = [string]$revItem.text
                            })
                            Sent = 1; Warnings = @($catWarnings.ToArray())
                        }
                    } catch {
                        $result = [pscustomobject]@{ Kind = 'cat'; Mode = 'revise'; Error = $_.Exception.Message }
                    }
                } else {
                Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '翻訳中' -Progress 10 -Detail '' -Phase 'translating'
                $items = $null
                $catContext = $null
                try {
                    # 同じ原文は1回だけ送る。割り戻しはこの中で行う。
                    $byText = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
                    $items = New-Object System.Collections.Generic.List[object]
                    foreach ($it in @($cat.items)) {
                        $text = [string]$it.text
                        if ([string]::IsNullOrWhiteSpace($text)) { continue }
                        if (-not $byText.ContainsKey($text)) {
                            $entry = [pscustomobject]@{ Index = ($items.Count + 1); Text = $text; BlockIds = (New-Object System.Collections.Generic.List[string]); Targets = (New-Object System.Collections.Generic.List[int]); Terminology=@($it.terminology) }
                            $byText[$text] = $entry
                            [void]$items.Add($entry)
                        }
                        [void]$byText[$text].Targets.Add([int]$it.index)
                    }
                    $maxChars = Get-YakuMaxCharsPerFileBatch -Settings $settings
                    $checkpointProjectId = [string]$cat.project_id
                    $checkpointProjectRevision = [int]$cat.expected_project_revision
                    $onCatBatchCompleted = {
                        param($completedItems, $completedMap)
                        $checkpointRows = @(ConvertTo-YakuCatCheckpointRows -Items @($completedItems) -Translations $completedMap -Warnings $catWarnings -Direction ([string]$cat.direction))
                        if ($checkpointRows.Count -gt 0) {
                            $null = Save-YakuCatBatchCheckpoint -ProjectId $checkpointProjectId -ProjectRevision $checkpointProjectRevision -Translations $checkpointRows
                        }
                    }.GetNewClosure()
                    # 文例は自動では引かない。引くかどうかは利用者が別のボタンで決める
                    # （利用者の判断 2026-08-06）。検索の往復が1回増えるので、
                    # 「検索だけ」「翻訳だけ」「検索してから翻訳」を選べるようにしてある。
                    # ここへ渡ってくるのは、既に検索して保持している文例だけ。
                    $catContext = @{
                        BatchOrdinal = 0; TotalBatches = 0; MaxRetryDepth = 0
                        CacheHits = 0; TranslatedSoFar = 0; UniqueTotal = [Math]::Max(1, $items.Count)
                        CopilotCalls = 0; CompletedMap = @{}
                        OnBatchCompleted = $onCatBatchCompleted
                    }
                    # 送る前に伏せる。ここが抜けていたため、CAT の「残りを訳す」は
                    # 実数値と人名を素のまま Copilot へ送っていた（2026-08-08 に判明）。
                    #
                    # ジョブ内で作ったitemsを共通の保護関数へ渡し、送信直前に伏せる。
                    $null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $Root -Direction ([string]$cat.direction) -Notation $(if ([string]$cat.amount_notation -eq 'billion') { 'billion' } else { 'oku' })
                    # machine draft は別projectへ再利用しない。同一project/revisionの
                    # 中断再開はOnBatchCompletedのcheckpointだけを正本にする。
                    $map = @{}
                    $copilotItems = New-Object System.Collections.Generic.List[object]
                    foreach ($entry in @($items.ToArray())) {
                        [void]$copilotItems.Add($entry)
                    }
                    $catContext['TotalBatches'] = @(Split-YakuFileTranslationItems -Items @($copilotItems.ToArray()) -MaxChars $maxChars).Count
                    if ($copilotItems.Count -gt 0) {
                        $translatedMap = Invoke-YakuCatTranslationItems -Root $Root -Items @($copilotItems.ToArray()) -Settings $settings `
                            -Direction ([string]$cat.direction) -MaxChars $maxChars -Warnings $catWarnings -Notation $(if ([string]$cat.amount_notation -eq 'billion') { 'billion' } else { 'oku' }) `
                            -ProgressState $JobState -Context $catContext
                        foreach ($key in $translatedMap.Keys) { $map[[int]$key] = [string]$translatedMap[$key] }
                    }
                    # 訳文を実値へ戻す。戻さないと画面へ [[N1]] が出る。
                    Restore-YakuCatItemTranslations -Items @($items.ToArray()) -Map $map -Warnings $catWarnings -Direction ([string]$cat.direction)
                    $pairs = New-Object System.Collections.Generic.List[object]
                    foreach ($entry in @($items.ToArray())) {
                        if (-not $map.ContainsKey([int]$entry.Index)) { continue }
                        $translation = [string]$map[[int]$entry.Index]
                        if ([string]::IsNullOrWhiteSpace($translation)) { continue }
                        foreach ($t in @($entry.Targets)) {
                            [void]$pairs.Add([ordered]@{
                                index = [int]$t; text = $translation
                                masked = [string]$entry.MaskedTranslation
                                source = [string](Get-YakuFileItemOriginalText -Item $entry)
                                terminology = @($entry.Terminology)
                            })
                        }
                    }
                    $result = [pscustomobject]@{
                        Kind = 'cat'
                        Mode = 'translate'
                        ProjectId = [string]$cat.project_id
                        ProjectRevision = [int]$cat.expected_project_revision
                        Translations = @($pairs.ToArray())
                        Sent = $copilotItems.Count
                        CacheHits = [int]$catContext['CacheHits']
                        Warnings = @($catWarnings.ToArray())
                    }
                } catch {
                    # 完了したバッチとキャッシュ命中分は捨てない。実値へ戻して
                    # グリッドへ反映し、次回はバッチ保存済みキャッシュから再開する。
                    $partial = @{}
                    try {
                        if ($null -ne $catContext -and $catContext.ContainsKey('CompletedMap')) {
                            foreach ($key in @($catContext['CompletedMap'].Keys)) { $partial[[int]$key] = [string]$catContext['CompletedMap'][$key] }
                        }
                    } catch { $partial = @{} }
                    if ($partial.Count -gt 0 -and $null -ne $items) {
                        $failureMessage = [string]$_.Exception.Message
                        try { Add-YakuWarning -Warnings $catWarnings -Category 'cat-partial' -Location 'CAT' -Message ('途中で停止しました。完了済み ' + $partial.Count + ' 件は保存しました。もう一度実行すると続きから再開します。詳細: ' + $failureMessage) } catch {}
                        Restore-YakuCatItemTranslations -Items @($items.ToArray()) -Map $partial -Warnings $catWarnings -Direction ([string]$cat.direction)
                        $partialPairs = New-Object System.Collections.Generic.List[object]
                        foreach ($entry in @($items.ToArray())) {
                            if (-not $partial.ContainsKey([int]$entry.Index)) { continue }
                            foreach ($t in @($entry.Targets)) {
                                [void]$partialPairs.Add([ordered]@{ index=[int]$t; text=[string]$partial[[int]$entry.Index]; masked=[string]$entry.MaskedTranslation; source=[string](Get-YakuFileItemOriginalText -Item $entry) })
                            }
                        }
                        $result = [pscustomobject]@{
                            Kind='cat'; Mode='translate'; ProjectId=[string]$cat.project_id; ProjectRevision=[int]$cat.expected_project_revision
                            Translations=@($partialPairs.ToArray()); Sent=$items.Count; Partial=$true
                            PartialError=$failureMessage; CacheHits=[int]$catContext['CacheHits']
                            Warnings=@($catWarnings.ToArray())
                        }
                    } else {
                        $result = [pscustomobject]@{ Kind = 'cat'; Mode = 'translate'; Error = $_.Exception.Message }
                    }
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
            } elseif ($Kind -eq 'shorten') {
                # 短くするのは押されたときだけ走る。標準の訳は既に画面にある。
                $sh = $ReviseJson | ConvertFrom-Json
                $shWarnings = New-Object System.Collections.Generic.List[object]
                Set-YakuTranslationProgress -ProgressState $JobState -Mode 'working' -Label '短くしています' -Progress 20 -Detail '' -Phase 'translating'
                try {
                    $sh1 = Invoke-YakuTextShorten -Root $Root -InputText ([string]$sh.source_text) -MaskedCurrentText ([string]$sh.current_text) -Settings $settings -ProgressState $JobState -Warnings $shWarnings
                    $result = [pscustomobject]@{
                        Direction = 'to_en'
                        DirectionLabel = '日本語 → 英語'
                        MaskedCount = [int]$sh1.MaskedCount
                        KeptCount = 0
                        InputLength = ([string]$sh.source_text).Length
                        SourceText = [string]$sh.source_text
                        Options = @($sh1.Options)
                        Raw = [string]$sh1.Raw
                        Prompt = [string]$sh1.Prompt
                        BatchCount = 1
                        Warnings = @($shWarnings.ToArray())
                        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    }
                } catch {
                    # 門で弾いたときは、その理由をそのまま伝える。
                    # 「短くできませんでした」だけでは、押した人は何を直せば
                    # よいか分からないまま、もう1回押して回数を使う。
                    $detail = [string]$_.Exception.Message
                    $message =
                        if ($detail -match '^SHORTEN_REJECTED: (.+)$') { '短くした訳を受け取りませんでした。' + $Matches[1] + ' 上の訳をそのままお使いください。' }
                        else { $detail }
                    $result = [pscustomobject]@{ Error = $message; Prompt = ''; Direction = 'to_en' }
                }
            } else {
                $result = Invoke-YakuTextTranslation -Root $Root -InputText $InputText -Settings $settings -ProgressState $JobState -DirectionOverride $TextDirectionOverride
            }
            if ([string]$JobState['mode'] -eq 'cancelled') { return }
            $JobState['result_json'] = ($result | ConvertTo-Json -Depth 80 -Compress)
            $terminalMode = 'done'
            if ($result -and ($result.PSObject.Properties.Name -contains 'Error') -and $result.Error) {
                $terminalMode = 'error'
                $JobState['label'] = '翻訳できませんでした'
                $JobState['class'] = 'warn'
                $JobState['detail'] = [string]$result.Error
                $JobState['progress'] = 100
            } else {
                $resultCompletionStatus = ''
                $resultCompletionDetail = ''
                try { $resultCompletionStatus = [string]$result.CompletionStatus } catch {}
                try { $resultCompletionDetail = [string]$result.CompletionDetail } catch {}
                $completedWithWarnings = ($resultCompletionStatus -eq 'completed_with_warnings')
                $terminalMode = if ($completedWithWarnings) { 'completed_with_warnings' } else { 'done' }
                $JobState['label'] = if ($completedWithWarnings) { 'Completed with warnings' } else { 'Done' }
                $JobState['class'] = if ($completedWithWarnings) { 'warn' } else { 'ok' }
                $JobState['detail'] = if (-not [string]::IsNullOrWhiteSpace($resultCompletionDetail)) { $resultCompletionDetail } else { 'Translation completed.' }
                $JobState['progress'] = 100
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
            $JobState['label'] = '翻訳できませんでした'
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
        [void]$ps.AddScript($worker.ToString()).AddArgument($root).AddArgument($Kind).AddArgument($InputText).AddArgument($TextDirectionOverride).AddArgument($settingsJson).AddArgument($script:YakuBuildId).AddArgument($state).AddArgument($ReviseJson).AddArgument($CatJson).AddArgument($CachePolicy).AddArgument($ReferencePolicy)
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
    $caption = if ($kind -eq 'file') { '抽出中' } elseif ($kind -eq 'revise') { '修正を依頼中' } elseif ($kind -eq 'shorten') { '短くしています' } elseif ($kind -eq 'cat') { '翻訳中' } else { '準備中' }
    # 修正はテキストの成果物なので、画面上はテキスト側へ描く。
    # ここの kind は「どちらのタブへ結果を入れるか」にしか使われない。
    if ($kind -eq 'revise' -or $kind -eq 'shorten') { $kind = 'text' }
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
    # CAT の訳文はグリッドへ取り込むので、共有の結果欄には出さない。
    # ここでテキスト翻訳の描画へ落ちると、CAT の結果の形を知らないため壊れる。
    if ($result -and ($result.PSObject.Properties.Name -contains 'Kind') -and [string]$result.Kind -eq 'cat') {
        if (($result.PSObject.Properties.Name -contains 'Error') -and $result.Error) {
            return (New-YakuAlertHtml -Kind error -Message (ConvertTo-YakuUserFacingError $result.Error))
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
    # 作業中の CAT が読んでいる元ファイルも守る。
    #
    # これが無いと、アップロードの1時間期限が来た時点でフォルダごと消える。
    # CAT は行を触るたびにリクエストを飛ばし、掃除はリクエストの先頭で走るので、
    # 利用者自身の操作が自分の元ファイルを消していた。しかも出力は元ファイルを
    # 読みに行くので、数時間かけて見終わって「出力」を押した瞬間に失敗する。
    # 丁寧に仕事をした人ほど確実に失敗する（2026-08-08 に判明）。
    foreach ($proj in @($script:YakuCatProjects.Values)) {
        try {
            $projPath = [string]$proj.Path
            if ([string]::IsNullOrWhiteSpace($projPath)) { continue }
            [void]$protectedDirs.Add([System.IO.Path]::GetFullPath((Split-Path -Parent $projPath)))
        } catch {}
    }
    # 再起動直後はメモリprojectが空である。旧版が一時uploadのpathをmanifestへ
    # 保存していたため、ディスク上の保存作業も読み、原本をprojectへ移行するまで
    # そのuploadだけは保護する。
    try {
        $catStore = Get-YakuCatProjectStoreDir
        $savedManifests = @(
            @(Get-ChildItem -LiteralPath $catStore -Filter 'project.json' -File -Recurse -ErrorAction SilentlyContinue) +
            @(Get-ChildItem -LiteralPath $catStore -Filter '*.json' -File -ErrorAction SilentlyContinue)
        )
        foreach ($manifest in $savedManifests) {
            try {
                $saved = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $savedPath = [string]$saved.path
                if ([string]$saved.source -ne 'file' -or [string]::IsNullOrWhiteSpace($savedPath)) { continue }
                if (Test-Path -LiteralPath $savedPath -PathType Leaf) {
                    [void]$protectedDirs.Add([System.IO.Path]::GetFullPath((Split-Path -Parent $savedPath)))
                }
            } catch {}
        }
    } catch {}
    foreach ($id in @($script:YakuUploadHandles.Keys)) {
        try {
            $item = $script:YakuUploadHandles[$id]
            if ([datetime]$item.ExpiresAt -gt $now) { continue }
            # 守るべきフォルダは消さない。$protectedDirs を作っておきながら、
            # ここで参照していなかったので、実行中のジョブの入力すら
            # 消し得た（2026-08-08 に判明）。
            $dir = ''
            try { $dir = [System.IO.Path]::GetFullPath((Split-Path -Parent ([string]$item.Path))) } catch { $dir = '' }
            if ($dir -and $protectedDirs.Contains($dir)) {
                # まだ使っている。期限を延ばして次の掃除に回す。
                try { $item.ExpiresAt = $now.AddHours(1) } catch {}
                continue
            }
            if ($item.Path -and (Test-Path -LiteralPath ([string]$item.Path))) { Remove-Item -LiteralPath (Split-Path -Parent ([string]$item.Path)) -Recurse -Force -ErrorAction SilentlyContinue }
            $script:YakuUploadHandles.Remove([string]$id)
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
    if ($length -gt $maxBytes) { throw "ファイルが大きすぎます。取り込めるのは $([Math]::Round($maxBytes/1MB,0))MB までですが、このファイルは $([Math]::Round($length/1MB,1))MB あります。資料を分けてからお試しください。" }
    $encodedName = [string]$Request.Headers['X-Yaku-File-Name']
    if ([string]::IsNullOrWhiteSpace($encodedName)) { throw 'ファイル名がありません。' }
    try { $fileName = [System.Uri]::UnescapeDataString($encodedName) } catch { throw 'ファイル名を解析できません。' }
    $safeName = New-SafeFileName -FileName $fileName
    $ext = [System.IO.Path]::GetExtension($safeName).ToLowerInvariant()
    if (@('.xlsx','.xlsm','.csv','.docx') -notcontains $ext) { throw '対応しているファイル形式は .docx / .xlsx / .xlsm / .csv です。' }
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
            if ($total -gt $maxBytes) { throw "ファイルが大きすぎます。取り込めるのは $([Math]::Round($maxBytes/1MB,0))MB までです。資料を分けてからお試しください。" }
            $stream.Write($buffer, 0, $read)
        }
        $stream.Flush()
        if ($length -ge 0 -and $total -ne $length) { throw 'ファイルの読み込みが途中で止まりました。もう一度ファイルをお選びください。' }
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
    if (-not [bool]$Settings.allow_direct_local_path) { throw '保存場所を直接入力しての取り込みは、この設定では使えません。「ここにファイルをドロップ、またはクリックして選択」からお選びください。' }
    $trimmed = $directPath.Trim().Trim('"')
    if ($trimmed.StartsWith('\\?\') -or $trimmed.StartsWith('\\.\')) { throw 'この保存場所からは取り込めません。「ここにファイルをドロップ、またはクリックして選択」からお選びください。' }
    if ($trimmed.StartsWith('\\') -and -not [bool]$Settings.allow_network_paths) { throw '共有フォルダ上のファイルは、そのままでは取り込めません。いったんデスクトップにコピーしてからお選びください。' }
    if (-not [System.IO.Path]::IsPathRooted($trimmed)) { throw '保存場所は、ドライブ名から始まる形でご指定ください。「ここにファイルをドロップ、またはクリックして選択」からお選びいただくのが確実です。' }
    $full = [System.IO.Path]::GetFullPath($trimmed)
    if (!(Test-Path -LiteralPath $full -PathType Leaf)) { throw 'そのファイルが見つかりません。保存場所と名前をもう一度ご確認ください。' }
    $directExt=[IO.Path]::GetExtension($full).ToLowerInvariant()
    if(@('.docx','.xlsx','.xlsm','.csv') -notcontains $directExt){throw '対応しているファイル形式は .docx / .xlsx / .xlsm / .csv です。'}
    # 原本をそのまま読まず、いったんこのアプリの中へ写してから読む。理由は2つ。
    #
    # 1. Excel や Word で開いたままだと原本は読めない。実測（2026-08-11）では
    #    ZipFile::OpenRead が共有違反で落ち、写したものは 10 entries を読めた。
    #    Ctrl+Alt+J から取り込むときは、開いたままであるのが普通の状態である。
    # 2. 確認作業は数十分続く。そのあいだに原本が編集されると、取り込んだ文と
    #    書き戻す先が食い違う。写しを持てば、この作業が見ているものは動かない。
    #
    # 書き込み先はいつもローカル（uploads）で、原本には触れない。
    $copyId = [guid]::NewGuid().ToString('N')
    $copyDir = Join-Path (Get-YakuSubDir 'uploads') $copyId
    New-Item -ItemType Directory -Path $copyDir -Force | Out-Null
    $copyPath = Join-Path $copyDir (New-SafeFileName -FileName ([System.IO.Path]::GetFileName($full)))
    try { Copy-Item -LiteralPath $full -Destination $copyPath -Force -ErrorAction Stop }
    catch {
        try { Remove-Item -LiteralPath $copyDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        throw 'そのファイルを読み込めませんでした。ほかのプログラムで編集中でないかご確認のうえ、もう一度お試しください。'
    }
    $handle = New-YakuSecureToken -ByteLength 24
    $item = [pscustomobject]@{ Handle=$handle; Path=$copyPath; OriginalName=[System.IO.Path]::GetFileName($full); Size=(Get-Item -LiteralPath $copyPath).Length; ExpiresAt=(Get-Date).AddHours(1); Uploaded=$true }
    $script:YakuUploadHandles[$handle] = $item
    return $item
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
    $resp.Headers['Cache-Control'] = 'no-store, no-cache, max-age=0'
    $resp.Headers['Pragma'] = 'no-cache'
    $resp.Headers['Expires'] = '0'
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
    $resp.Headers['Cache-Control'] = 'no-store, no-cache, max-age=0'
    $resp.Headers['Pragma'] = 'no-cache'
    $resp.Headers['Expires'] = '0'
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

function Serve-YakuAppPage {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][ValidateSet('cat.html','tutorial.html')][string]$PageName,
        [switch]$StartTour
    )
    $path = Join-Path (Join-Path $script:YakuRoot 'www') $PageName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Send-YakuTextResponse -Context $Context -Text 'Not found' -StatusCode 404 -ContentType 'text/plain; charset=utf-8'
        return
    }
    $html = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $settings = Read-YakuSettings -Root $script:YakuRoot
    $maxBytes = Get-YakuFileUploadBodyLimitBytes -Settings $settings
    $html = $html.Replace('__YAKU_SESSION_TOKEN__', (ConvertTo-YakuHtml $script:YakuSessionToken))
    $html = $html.Replace('__YAKU_MAX_UPLOAD_BYTES__', [string]$maxBytes)
    # 1回の依頼に入る文字数。これを超える文章は、確認作業なら分けて送れるが、
    # その場で訳す状態には分ける仕組みが無い（上限超過での再依頼もしない）。
    # 画面が「1文ずつ確認して始める」を勧める境目に使う。勝手な数字は置かない。
    $html = $html.Replace('__YAKU_MAX_BATCH_CHARS__', [string](Get-YakuMaxCharsPerFileBatch -Settings $settings))
    $html = $html.Replace('__YAKU_AMOUNT_NOTATION__', (ConvertTo-YakuHtml (Get-YakuAmountNotation -Settings $settings)))
    $html = $html.Replace('__YAKU_TOUR__', $(if ($StartTour) { '1' } else { '' }))
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
        # 起動したら、選ばせずに貼り付け欄へ着地させる（2026-08-12、利用者の指摘
        # 「アプリ起動すると選択肢が提示されて選ばなくてはいけないのはストレス」）。
        # 「文章を貼り付ける」「資料を取り込む」の2枚のカードは、どちらも同じ画面へ
        # 行き先が同じだった。取り込みは、着地した画面の中に脇役として置いてある。
        # 初回は同じ画面の上で3か所だけ吹き出しを出す（前置きの説明は読み飛ばされ、
        # 作業の成績も上がらないという調査に合わせた）。
        $desktopPreferences = Get-YakuDesktopPreferences
        if ([bool]$desktopPreferences.available -and -not [bool]$desktopPreferences.tutorial_completed) {
            Serve-YakuAppPage -Context $Context -PageName 'cat.html' -StartTour
        } else {
            Serve-YakuAppPage -Context $Context -PageName 'cat.html'
        }
        return
    }
    # 画面は一つ（2026-08-11 の利用者判断「画面を一つにするのでok」）。/quick は
    # 同じ画面の「その場で訳す」状態として残す。Ctrl+Alt+J、外枠、開始画面、
    # チュートリアルがこの経路を持っているため、消さずに同じページを返す。
    if ($method -eq 'GET' -and ($path -eq '/quick' -or $path -eq '/cat')) {
        Serve-YakuAppPage -Context $Context -PageName 'cat.html'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/tutorial') {
        Serve-YakuAppPage -Context $Context -PageName 'tutorial.html'
        return
    }
    if ($method -eq 'GET' -and $path.StartsWith('/assets/')) {
        Serve-YakuStaticFile -Context $Context -RelativePath $path.TrimStart('/')
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/instance') {
        $activeJob = Get-YakuActiveTranslationJobState
        $activeRunning = Test-YakuTranslationJobRunning -State $activeJob
        $activeKind = if ($activeRunning) { [string]$activeJob['kind'] } else { '' }
        Send-YakuTextResponse -Context $Context -Text ([ordered]@{ instance_id=$script:YakuInstanceId; pid=$PID; process_started_at=$script:YakuProcessStartedAt; build_id=$script:YakuBuildId; active_job_running=[bool]$activeRunning; active_job_kind=$activeKind } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/ready-state') {
        $state = Get-YakuTranslateReadinessState
        Send-YakuTextResponse -Context $Context -Text (Convert-YakuReadinessStateToJson -State $state) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/desktop/preferences') {
        $preferences = Get-YakuDesktopPreferences
        Send-YakuTextResponse -Context $Context -Text ($preferences | ConvertTo-Json -Depth 6 -Compress) -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/desktop/tour-complete') {
        # 案内を終えた（または飛ばした）ことだけを記録する。ショートカットは作らない。
        try {
            $preferences = Set-YakuTutorialCompleted
            Send-YakuTextResponse -Context $Context -Text ($preferences | ConvertTo-Json -Depth 6 -Compress) -ContentType 'application/json; charset=utf-8'
        } catch {
            Send-YakuTextResponse -Context $Context -Text ([ordered]@{ message=(Convert-YakuExceptionToUserMessage $_) } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
        }
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/desktop/preferences') {
        try {
            $payload = Read-YakuRequestJson -Request $req -MaxBytes 4096
            if (-not $payload.ContainsKey('startup_enabled') -or $payload['startup_enabled'] -isnot [bool] -or
                -not $payload.ContainsKey('desktop_shortcut') -or $payload['desktop_shortcut'] -isnot [bool]) {
                throw 'DESKTOP_PREFERENCES_INVALID: 設定値を読み取れませんでした。'
            }
            $preferences = Set-YakuDesktopPreferences -StartupEnabled ([bool]$payload['startup_enabled']) -DesktopShortcut ([bool]$payload['desktop_shortcut'])
            Send-YakuTextResponse -Context $Context -Text ($preferences | ConvertTo-Json -Depth 6 -Compress) -ContentType 'application/json; charset=utf-8'
        } catch {
            $body = [ordered]@{ available=$false; startup_enabled=$false; desktop_shortcut=$false; message=(Convert-YakuExceptionToUserMessage $_); warnings=@() }
            Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 5 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
        }
        return
    }
    # 金額の書き方（oku / billion）。設定ファイルを直接開かせないための、
    # 1項目だけの入口。既に始めた作業の書き方は変えない（作業ごとに固定して
    # あり、原文の換算と点検が同じ書き方でそろっている必要があるため）。
    if ($method -eq 'POST' -and $path -eq '/api/settings/amount-notation') {
        try {
            $payload = Read-YakuRequestJson -Request $req -MaxBytes 2048
            $value = [string]$payload['amount_notation']
            if ($value -ne 'oku' -and $value -ne 'billion') { throw 'AMOUNT_NOTATION_INVALID: 金額の書き方は oku か billion のどちらかです。' }
            $saved = @(Save-YakuUserSettings -Root $script:YakuRoot -Form @{ amount_notation = $value })
            $applied = Get-YakuAmountNotation -Settings $saved[0]
            Send-YakuTextResponse -Context $Context -Text ([ordered]@{ amount_notation=$applied } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
        } catch {
            $safe = Convert-YakuExceptionToUserMessage $_
            Send-YakuTextResponse -Context $Context -Text ([ordered]@{ message=$safe } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 400
        }
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
            $payload = [ordered]@{ mode='error'; label='翻訳できませんでした'; class='warn'; detail=$safe; progress=100; html=(New-YakuAlertHtml -Kind error -Message $safe) }
            Send-YakuTextResponse -Context $Context -Text ($payload | ConvertTo-Json -Depth 20 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 404
        }
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/download') {
        try {
            $jobId = Get-YakuQueryValue -Request $req -Name 'job_id'
            if ([string]::IsNullOrWhiteSpace($jobId)) { throw 'どの翻訳の結果か分かりませんでした。画面を読み込み直してから、もう一度お試しください。' }
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
            # CAT の出力はジョブを経由しないので、プロジェクトの id でも開けるようにする。
            # 開くボタンは既にあったのに、CAT の出力からは届かない場所にあった。
            # 数時間かけて見終わった人が、灰色のパス文字列を目で読んで
            # エクスプローラーに打ち込む必要があった（2026-08-08 に判明）。
            $output = ''
            $catId = ''
            try { $catId = [string]$payload['project_id'] } catch {}
            if (-not [string]::IsNullOrWhiteSpace($catId)) {
                $catProject = Get-YakuCatProject -Id $catId
                if ($null -eq $catProject) { throw '作業中のファイルが見つかりません。' }
                try { $output = [string]$catProject.LastOutputPath } catch { $output = '' }
                if ([string]::IsNullOrWhiteSpace($output)) { throw 'まだファイルを作っていません。先に「社内確認用のファイルを作る」を押してください。' }
            }
            else {
                Update-YakuTranslationJobs
                if ([string]::IsNullOrWhiteSpace($jobId) -or -not $script:YakuTranslateJobs.ContainsKey($jobId)) { throw (Get-YakuTranslationJobMissingMessage -JobId $jobId) }
                $output = Get-YakuJobOutputPath -State $script:YakuTranslateJobs[$jobId]
            }
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

    # --------------------------------------------------------------- Quick JSON
    # POST /api/quick/translate、POST /api/quick/jobs、GET /api/quick/jobs/{id}、
    # GET /api/quick/artifacts/{id}、POST /api/quick/artifacts/{id}/revisions、
    # POST /api/cat/promote は 2026-08-13 に外した。訳案を1枚返す状態（その場で訳す）
    # を廃止し、貼り付けた文章も /api/cat/open で作業になったため、呼ぶ側が無くなった。
    # 残すのは選択の読み取りだけ（/api/quick/selection と selection-capture）。
    # これは Ctrl+Alt+J の口で、翻訳とは別の仕事をしている。
    if ($method -eq 'POST' -and $path -eq '/api/quick/selection-capture') {
        # Office 以外は、外枠が疑似 Ctrl+C を送ってクリップボードから読む。その経路は
        # サーバを通らないので、読み込んだことだけを画面から報告してもらって記録する。
        # 本文は受け取らない（受け取る経路を作らないのが /api/quick/selection と同じ方針）。
        $payload = Read-YakuRequestJson -Request $req -MaxBytes 2048
        foreach ($key in @($payload.Keys)) {
            if ([string]$key -notin @('chars')) { throw 'QUICK_SELECTION_CAPTURE_PAYLOAD_INVALID' }
        }
        $capturedChars = 0
        try { $capturedChars = [int]$payload['chars'] } catch { $capturedChars = 0 }
        try { Write-YakuLog ("Selection capture. trigger=hotkey app=other via=clipboard chars=" + $capturedChars) 'INFO' } catch {}
        Send-YakuTextResponse -Context $Context -Text '{"recorded":true}' -ContentType 'application/json; charset=utf-8'
        return
    }
    if ($method -eq 'POST' -and $path -eq '/api/quick/selection') {
        # Ctrl+Alt+J で開いたときに、前面にあった Office の選択範囲を読む。
        # 受け取るのは窓のクラスとハンドルだけで、本文はブラウザーから来ない。
        # 本文が来る経路を作らないのは、ブラウザー側で書き換えたものを載せられる
        # ようにしないため（/api/cat/promote と同じ考え方）。
        $payload = Read-YakuRequestJson -Request $req
        foreach ($key in @($payload.Keys)) {
            if ([string]$key -notin @('window_class','foreground_hwnd')) { throw 'QUICK_SELECTION_PAYLOAD_INVALID' }
        }
        $windowClass = ''
        try { $windowClass = [string]$payload['window_class'] } catch { $windowClass = '' }
        $hwnd = 0
        try { $hwnd = [int]$payload['foreground_hwnd'] } catch { $hwnd = 0 }
        if ($windowClass -notin @('OpusApp','XLMAIN','PPTFrameClass')) {
            Send-YakuTextResponse -Context $Context -Text (([ordered]@{ kind='none'; reason='not_office' } | ConvertTo-Json -Compress)) -ContentType 'application/json; charset=utf-8'
            return
        }
        $result = Get-YakuForegroundSelection -WindowClass $windowClass -ForegroundHwnd $hwnd
        # 取り込みは必ず記録に残す。本文は書かない（時刻・相手アプリ・文字数だけ）。
        # 「押したときだけ読む」を、コードを読まずに確かめられるようにするため。
        # セキュリティの確認では、RegisterHotKey はキーロガーと同じ入口に見える。
        # 説明を「信じてください」から「ログを見てください」へ変える。
        try {
            $capturedChars = 0
            try { $capturedChars = [int]$result.CharCount } catch { $capturedChars = 0 }
            Write-YakuLog ("Selection capture. trigger=hotkey app=" + $windowClass + " via=office kind=" + [string]$result.Kind + " chars=" + $capturedChars) 'INFO'
        } catch {}
        $body = [ordered]@{ kind = [string]$result.Kind; reason = $(try { [string]$result.Reason } catch { '' }) }
        if ([string]$result.Kind -eq 'word_text') {
            $body['text'] = [string]$result.Text
            $body['document_name'] = [string]$result.DocumentName
            $body['char_count'] = [int]$result.CharCount
            # 「この文書を丸ごと取り込む」用。ディスクにある版を読むので、
            # 保存済みかどうかも一緒に返す。
            $body['source_path'] = $(try { [string]$result.DocumentPath } catch { '' })
            $body['saved'] = $(try { [bool]$result.Saved } catch { $false })
        } elseif ([string]$result.Kind -eq 'powerpoint_text') {
            # スライドは丸ごと取り込めない（資料翻訳が .pptx を扱わない）ので
            # source_path は返さない。読んだ本文だけを渡す。
            $body['text'] = [string]$result.Text
            $body['presentation_name'] = [string]$result.PresentationName
            $body['slide_index'] = [int]$result.SlideIndex
            $body['shape_count'] = [int]$result.ShapeCount
            $body['char_count'] = [int]$result.CharCount
        } elseif ([string]$result.Kind -eq 'excel_cells') {
            # 読んだブック・シート・番地を必ず返す。画面へ出さないと、別のブックを
            # 読んでいても利用者が気づけない。
            $body['workbook_name'] = [string]$result.WorkbookName
            $body['sheet_name'] = [string]$result.SheetName
            $body['address'] = [string]$result.Address
            $body['cell_count'] = [int]$result.CellCount
            $body['formula_skipped'] = [int]$result.FormulaSkipped
            $body['saved'] = [bool]$result.Saved
            $body['source_path'] = $(try { [string]$result.WorkbookPath } catch { '' })
            $body['text'] = (@($result.Cells | ForEach-Object { [string]$_.Text }) -join "`n")
        }
        Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
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
                $directionIntent = 'auto'
                try { if (@('auto','to_en','to_jp') -contains [string]$payload['direction_intent']) { $directionIntent = [string]$payload['direction_intent'] } } catch {}
                if ($directionIntent -eq 'auto') {
                    try { if (@('to_en','to_jp') -contains [string]$payload['direction']) { $directionIntent = [string]$payload['direction'] } } catch {}
                }
                $directionBasis = $(if ($directionIntent -eq 'auto') { 'detected' } else { 'explicit' })
                try { if ([string]$payload['direction_basis'] -eq 'inherited') { $directionBasis = 'inherited' } } catch {}
                # 貼り付けたテキストからも開ける。簡易翻訳と入力の作法を揃え、
                # 覚え直しの負担を減らすため（利用者の懸念 2026-08-06）。
                $pastedText = ''
                try { $pastedText = [string]$payload['text'] } catch {}
                if (-not [string]::IsNullOrWhiteSpace($pastedText)) {
                    $directionDecision = Resolve-YakuDirectionDecision -Text $pastedText -Intent $directionIntent -Basis $directionBasis
                    if ([bool]$directionDecision.RequiresConfirmation) {
                        $response = [ordered]@{ code='DIRECTION_CONFIRMATION_REQUIRED'; error='翻訳先を選んでください。'; suggested_direction=[string]$directionDecision.SuggestedDirection; confidence=[string]$directionDecision.Confidence; source_fingerprint=[string]$directionDecision.SourceFingerprint }
                        Send-YakuTextResponse -Context $Context -Text ($response | ConvertTo-Json -Compress) -StatusCode 409 -ContentType 'application/json; charset=utf-8'
                        return
                    }
                    $direction = [string]$directionDecision.Resolved
                    # 簡易翻訳から渡された訳文があれば一緒に取り込む。
                    # 訳文をクライアントから受け取る旧 handoff の受け口は閉じた。
                    # ちょっと翻訳からの引き継ぎは artifact ID だけを渡す経路
                    # （/api/cat/promote）へ一本化してある。ここで訳文を受けると、
                    # ブラウザ側で書き換えた訳をそのまま project に載せられてしまう。
                    $project = New-YakuCatTextProject -Root $script:YakuRoot -Text $pastedText -Settings $settings -Direction $direction -Register $false
                    $project | Add-Member -NotePropertyName DirectionBasis -NotePropertyValue ([string]$directionDecision.Basis) -Force
                    $project | Add-Member -NotePropertyName DirectionConfidence -NotePropertyValue ([string]$directionDecision.Confidence) -Force
                    $project | Add-Member -NotePropertyName DirectionSourceFingerprint -NotePropertyValue ([string]$directionDecision.SourceFingerprint) -Force
                    try { $project | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $script:YakuRoot -Project $project -Settings $settings) -Force } catch {}
                    $project = Commit-YakuNewCatProject -Project $project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                    return
                }
                $incoming = Resolve-YakuIncomingFile -Payload $payload -Settings $settings
                $fileInfo = Get-YakuFileInfo -Path ([string]$incoming.Path) -Settings $settings
                if ($directionIntent -eq 'auto') {
                    $fileConfidence = [string]$fileInfo.DirectionConfidence
                    if ($fileConfidence -ne 'high') {
                        $response = [ordered]@{ code='DIRECTION_CONFIRMATION_REQUIRED'; error='このファイルの翻訳先を選んでください。'; suggested_direction=[string]$fileInfo.DetectedDirection; confidence=$fileConfidence; source_fingerprint='' }
                        Send-YakuTextResponse -Context $Context -Text ($response | ConvertTo-Json -Compress) -StatusCode 409 -ContentType 'application/json; charset=utf-8'
                        return
                    }
                    $direction = [string]$fileInfo.DetectedDirection
                    $directionBasis = 'detected'
                } else { $direction = $directionIntent }
                $project = New-YakuCatProject -Root $script:YakuRoot -Path ([string]$incoming.Path) -Settings $settings -Direction $direction -Register $false
                $project | Add-Member -NotePropertyName DirectionBasis -NotePropertyValue $directionBasis -Force
                $project | Add-Member -NotePropertyName DirectionConfidence -NotePropertyValue $(if($directionIntent -eq 'auto'){[string]$fileInfo.DirectionConfidence}else{'not_applicable'}) -Force
                $project | Add-Member -NotePropertyName DirectionSourceFingerprint -NotePropertyValue '' -Force
                try { $project | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $script:YakuRoot -Project $project -Settings $settings) -Force } catch {}
                try { $project = Commit-YakuNewCatProject -Project $project }
                catch {
                    try { Remove-YakuCatProject -Id ([string]$project.Id) -DeleteStored } catch {}
                    throw
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$incoming.Handle)) { Remove-YakuUploadHandle -Handle ([string]$incoming.Handle) -DeleteFile }
                Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                return
            }

            if ($action -eq 'from-prior-version') {
                $currentJa = ''; $priorJa = ''; $priorEn = ''; $documentName = ''
                try { $currentJa = [string]$payload['current_ja'] } catch {}
                try { $priorJa = [string]$payload['prior_ja'] } catch {}
                try { $priorEn = [string]$payload['prior_en'] } catch {}
                try { $documentName = [string]$payload['document_name'] } catch {}
                # 貼付内容だけでは公表実績・社内承認を検証できない。クライアントの
                # 自己申告は再利用権限にせず、検証済みimport実装までは参考専用。
                $project = New-YakuCatProjectFromPriorVersion -CurrentJa $currentJa -PriorJa $priorJa -PriorEn $priorEn `
                    -PriorEvidence 'reference_only' -DocumentName $documentName
                try { $project | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $script:YakuRoot -Project $project -Settings $settings) -Force } catch {}
                $project = Commit-YakuNewCatProject -Project $project
                Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                return
            }

            if ($action -eq 'recent') {
                # 前回までの作業一覧。取り込む前に「続きから」を選べるようにする。
                $rows = @(Get-YakuCatSavedProjects -Limit 10 | ForEach-Object {
                        [ordered]@{ id = [string]$_.Id; file_name = [string]$_.FileName; direction = [string]$_.Direction
                            revision = [int]$_.Revision
                            total = [int]$_.Total; confirmed = [int]$_.Confirmed; saved = [string]$_.Saved
                            export_blocked = [bool]$_.ExportBlocked }
                    })
                Send-YakuTextResponse -Context $Context -Text (([ordered]@{ projects = @($rows) } | ConvertTo-Json -Depth 4 -Compress)) -ContentType 'application/json; charset=utf-8'
                return
            }

            if ($action -eq 'resume') {
                $wanted = ''
                try { $wanted = [string]$payload['project_id'] } catch {}
                $restored = $null
                if (-not [string]::IsNullOrWhiteSpace($wanted)) {
                    $restored = Get-YakuCatProject -Id $wanted
                    if ($null -eq $restored) { $restored = Restore-YakuCatProject -Id $wanted }
                    elseif ($null -ne $restored) {
                        # workerの完了直後に再読込した場合、同じserver内のメモリprojectが
                        # 先に見つかってもcheckpointを取り込む。ディスク復元時だけ適用
                        # すると、F5後に完了済みの訳案が空欄へ見える。
                        $null = Apply-YakuCatBatchCheckpoint -Project $restored
                        $restored = Get-YakuCatProject -Id $wanted
                    }
                }
                if ($null -eq $restored) { throw '途中保存を読み込めませんでした。「別の資料」から一覧に戻り、もう一度お選びください。' }
                Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $restored) -ContentType 'application/json; charset=utf-8'
                return
            }

            if ($action -eq 'align') {
                # 既にある訳と突き合わせる。まだプロジェクトが無いので open と同じ側に置く。
                # 数分かかるのでジョブで走らせ、完了後に align-apply で組み立てる。
                $direction = 'to_en'
                $srcText = ''; $tgtText = ''; $alignName = '対訳の突き合わせ'
                try { $srcText = [string]$payload['source_text'] } catch {}
                try { $tgtText = [string]$payload['target_text'] } catch {}
                try { if (-not [string]::IsNullOrWhiteSpace([string]$payload['file_name'])) { $alignName = [string]$payload['file_name'] } } catch {}
                if ([string]::IsNullOrWhiteSpace($srcText) -or [string]::IsNullOrWhiteSpace($tgtText)) {
                    Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message '原文と訳文の両方を入れてください。')) -StatusCode 409
                    return
                }
                $jaDecision = Resolve-YakuDirectionDecision -Text $srcText -Intent 'auto'
                $enDecision = Resolve-YakuDirectionDecision -Text $tgtText -Intent 'auto'
                if ([bool]$jaDecision.RequiresConfirmation -or [bool]$enDecision.RequiresConfirmation -or
                    [string]$jaDecision.Resolved -ne 'to_en' -or [string]$enDecision.Resolved -ne 'to_jp') {
                    Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message '左に日本語版、右に対応する英語版を貼り付けてください。言語を安全に確認できないため、取り込みを中止しました。')) -StatusCode 409
                    return
                }
                $readyState = Get-YakuTranslateReadinessState
                if (-not [bool]$readyState.canTranslate) {
                    $message = if ([string]$readyState.mode -eq 'working') { '別のジョブが実行中です。完了してからお試しください。' } else { 'Copilotの準備が完了してから実行できます。' }
                    Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message $message)) -StatusCode 409
                    return
                }
                $catJson = ([ordered]@{ project_id = ''; direction = $direction; mode = 'align'; file_name = $alignName; source_text = $srcText; target_text = $tgtText; items = @() } | ConvertTo-Json -Depth 6 -Compress)
                $state = Start-YakuTranslationJob -InputText '' -Settings $settings -Kind 'cat' -CatJson $catJson
                Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobStartedHtml -State $state)
                return
            }

            if ($action -eq 'align-apply') {
                # ジョブが返した対からプロジェクトを組み立てる。以後はいつもの
                # グリッドなので、結合・分割・手直しがそのまま使える。
                $direction = 'to_en'
                $alignName = '対訳の突き合わせ'
                try { if (-not [string]::IsNullOrWhiteSpace([string]$payload['file_name'])) { $alignName = [string]$payload['file_name'] } } catch {}
                # 対はジョブの結果から読む。画面へ往復させない。数千組になると
                # 送り返すだけで重いうえ、途中で欠けても気づけない。
                $jobId = ''
                try { $jobId = [string]$payload['job_id'] } catch {}
                Update-YakuTranslationJobs
                if ([string]::IsNullOrWhiteSpace($jobId) -or -not $script:YakuTranslateJobs.ContainsKey($jobId)) { throw (Get-YakuTranslationJobMissingMessage -JobId $jobId) }
                $resultJson = [string]$script:YakuTranslateJobs[$jobId]['result_json']
                if ([string]::IsNullOrWhiteSpace($resultJson)) { throw '前回の日本語と英語を並べられませんでした。両方の文章が入っているかご確認ください。' }
                $alignResult = $resultJson | ConvertFrom-Json
                if ($alignResult.PSObject.Properties.Name -contains 'Error' -and $alignResult.Error) { throw [string]$alignResult.Error }
                $incomingPairs = @(@($alignResult.Pairs) | ForEach-Object { [pscustomobject]@{ JaText = [string]$_.JaText; EnText = [string]$_.EnText } })
                $project = New-YakuCatProjectFromPairs -Pairs $incomingPairs -Direction $direction -FileName $alignName `
                    -JaCoverage ([double]$alignResult.JaCoverage) -Dropped ([int]$alignResult.Dropped) -Register $false
                $project | Add-Member -NotePropertyName DirectionBasis -NotePropertyValue 'fixed' -Force
                $project | Add-Member -NotePropertyName DirectionConfidence -NotePropertyValue 'not_applicable' -Force
                $project = Commit-YakuNewCatProject -Project $project
                Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                return
            }

            $projectId = ''
            try { $projectId = [string]$payload['id'] } catch {}
            $project = Get-YakuCatProject -Id $projectId
            # メモリに無ければ、保存してあるものから戻す。アプリを再起動しても
            # 続きから作業できるようにするため。
            if ($null -eq $project -and -not [string]::IsNullOrWhiteSpace($projectId)) {
                try { $project = Restore-YakuCatProject -Id $projectId } catch { $project = $null }
            }
            if ($null -eq $project) { throw '取り込んだファイルが見つかりません。もう一度「取り込んで確認を始める」を押してください。' }

            $revisionActions = @('delete','glossary','merge','split','glossary-add','term-add','term-deactivate','term-insert','term-exception','tm-delete','confirm','confirm-bulk','save-corpus','segment','translate','apply','preflight','export','export-reviewed','personal-glossary-list','personal-glossary-remove')
            if ($revisionActions -contains $action) {
                $expectedRevision = -1
                try { $expectedRevision = [int]$payload['expected_revision'] } catch { $expectedRevision = -1 }
                if ($expectedRevision -ne [int]$project.Revision) { throw 'CAT_PROJECT_REVISION_CONFLICT: 別の操作で作業内容が更新されました。最新状態を読み込んでからやり直してください。' }
            }

            switch ($action) {
                'delete' {
                    Remove-YakuCatProject -Id ([string]$project.Id) -DeleteStored
                    Send-YakuTextResponse -Context $Context -Text '{"deleted":true}' -ContentType 'application/json; charset=utf-8'
                }
                'glossary' {
                    $mutation = {
                        param($candidate,$root,$innerSettings)
                        $null = Invoke-YakuCatGlossaryPass -Root $root -Project $candidate -Settings $innerSettings
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($script:YakuRoot,$settings)
                    $project = $commit.Project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'merge' {
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $mutation = {
                        param($candidate,$innerIndex,$root,$innerSettings)
                        $null = Merge-YakuCatSegments -Project $candidate -Index $innerIndex
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($index,$script:YakuRoot,$settings)
                    $project = $commit.Project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'split' {
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $mutation = {
                        param($candidate,$innerIndex,$root,$innerSettings)
                        $null = Split-YakuCatSegment -Project $candidate -Index $innerIndex
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($index,$script:YakuRoot,$settings)
                    $project = $commit.Project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'candidates' {
                    # 現在行の候補。利用者が登録した用語、確認済みTM、当該
                    # projectへ明示的に取り込んだ前回版だけを手元から引く。
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $items = @(Get-YakuCatSegmentCandidates -Root $script:YakuRoot -Project $project -Index $index)
                    $rows = @($items | ForEach-Object { [ordered]@{
                        kind = [string]$_.Kind
                        reference_id = [string]$_.ReferenceId
                        source_name = [string]$_.SourceName
                        location = [string]$_.Location
                        page = [int]$_.Page
                        source = [string]$_.Source
                        translation = [string]$_.Target
                        matched_terms = @($_.MatchedTerms)
                        source_match_ratio = [double]$_.Ratio
                        # 旧UI互換。新UIは上の正規化名を使う。
                        target = [string]$_.Target
                        exact = [bool]$_.Exact
                        ratio = [double]$_.Ratio
                        match_type = [string]$_.MatchType
                        score = $(try { [double]$_.Score } catch { [double]$_.Ratio })
                        saved = [string]$_.Saved
                        database = [string]$_.Database
                        verified = [bool]$_.Verified
                        term_id = [string]$_.TermId
                        term_version = $(try { [int]$_.TermVersion } catch { 0 })
                        scope = [string]$_.Scope
                        enforcement = [string]$_.Enforcement
                        allowed_targets = @($_.AllowedTargets)
                        forbidden_targets = @($_.ForbiddenTargets)
                        origin_project_id = [string]$_.OriginProjectId
                        origin_segment_id = [string]$_.OriginSegmentId
                        review_revision = $(try { [int]$_.ReviewRevision } catch { 0 })
                    } })
                    $termRows = @($rows | Where-Object { [string]$_.kind -eq 'term' })
                    $segmentRows = @($rows | Where-Object { [string]$_.kind -ne 'term' })
                    Send-YakuTextResponse -Context $Context -Text (([ordered]@{
                        index = $index; terms = @($termRows); segment_matches = @($segmentRows)
                        candidates = @($rows) # 旧UI/テストの読取互換
                    } | ConvertTo-Json -Depth 7 -Compress)) -ContentType 'application/json; charset=utf-8'
                }
                'glossary-add' {
                    # 行全体の固定訳を、利用者所有の出典付きterminologyへ足す。
                    # 旧CSVやアプリ同梱glossaryへは書かない。
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $segs2 = @($project.Segments)
                    if ($index -lt 0 -or $index -ge $segs2.Count) { throw '行が見つかりません。' }
                    $segment = $segs2[$index]
                    $sourceText = ([string]$segment.Text).Trim()
                    $targetText = ([string]$segment.Translation).Trim()
                    if ([string]::IsNullOrWhiteSpace($sourceText) -or [string]::IsNullOrWhiteSpace($targetText)) { throw '訳文を入れてから追加してください。' }
                    if ($sourceText.Length -gt 80 -or $targetText.Length -gt 80 -or $sourceText -match "[`r`n]" -or $targetText -match "[`r`n]") { throw '固定訳は改行を含まない80文字以内で登録してください。' }
                    $originFile = ([string]$project.FileName).Trim()
                    if ([string]::IsNullOrWhiteSpace($originFile)) { $originFile = '貼り付け資料' }
                    $originLocation = ([string]$segment.Location).Trim()
                    if ([string]::IsNullOrWhiteSpace($originLocation)) { $originLocation = '行 ' + [string]($index + 1) }
                    $termParams = @{
                        Scope='personal'; Kind='cell_exact'; Enforcement='advisory'; Origin='cat-cell-exact-editor'
                        OriginProjectId=[string]$project.Id; OriginFileName=$originFile; OriginSegmentId=[string]$segment.SegmentId
                        OriginLocation=$originLocation; OriginRevision=[int]$project.Revision
                    }
                    if ([string]$project.Direction -eq 'to_en') {
                        $termParams.JapanesePreferred=$sourceText; $termParams.EnglishPreferred=$targetText
                    } else {
                        $termParams.EnglishPreferred=$sourceText; $termParams.JapanesePreferred=$targetText
                    }
                    $added = Add-YakuTerminologyEntry @termParams
                    $msg = if ([bool]$added.Added) { '登録した固定訳に追加しました。次から同じセルへ自動で入ります。' } else { 'すでに同じ固定訳が登録されています。' }
                    Send-YakuTextResponse -Context $Context -Text (([ordered]@{ ok = [bool]$added.Added; message = $msg } | ConvertTo-Json -Compress)) -ContentType 'application/json; charset=utf-8'
                }
                'term-add' {
                    $index = -1; try { $index = [int]$payload['index'] } catch {}
                    $segs2 = @($project.Segments)
                    if ($index -lt 0 -or $index -ge $segs2.Count) { throw '用語を登録する行が見つかりません。' }
                    $sourceTerm = ([string]$payload['source_term']).Trim()
                    $preferred = ([string]$payload['preferred_target']).Trim()
                    if ([string]::IsNullOrWhiteSpace($sourceTerm) -or [string]::IsNullOrWhiteSpace($preferred)) { throw '原文の用語と推奨訳を入力してください。' }
                    if ($sourceTerm.Length -gt 80 -or $preferred.Length -gt 80 -or $sourceTerm -match "[`r`n]" -or $preferred -match "[`r`n]") { throw '用語は改行を含まない80文字以内で登録してください。' }
                    $scope = if ([string]$payload['scope'] -eq 'personal') { 'personal' } else { 'project' }
                    $allowed = @([string]$payload['allowed_targets'] -split '[|｜]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $forbidden = @([string]$payload['forbidden_targets'] -split '[|｜]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($allowed.Count -gt 20 -or $forbidden.Count -gt 20) { throw '許容訳と使用しない訳は、それぞれ20件以内にしてください。' }
                    foreach ($variant in @($allowed + $forbidden)) {
                        if ($variant.Length -gt 80 -or $variant -match '[\x00-\x1F\x7F]') { throw '用語の各表現は制御文字を含まない80文字以内にしてください。' }
                    }
                    $overlap = @($allowed | Where-Object { $forbidden -contains $_ })
                    if ($overlap.Count -gt 0) { throw '同じ表現を「許容する別訳」と「使用しない訳」の両方には登録できません。' }
                    if ([string]$payload['note'] -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' -or ([string]$payload['note']).Length -gt 200) { throw '補足は制御文字を含まない200文字以内にしてください。' }
                    $segment = $segs2[$index]
                    $originPage = Get-YakuCatSegmentOriginPage -Project $project -Segment $segment
                    $params = @{
                        Scope=$scope; ProjectId=$(if($scope -eq 'project'){[string]$project.Id}else{''}); Kind='occurrence'; Enforcement='required'
                        Note=[string]$payload['note']; OriginProjectId=[string]$project.Id; OriginFileName=[string]$project.FileName
                        OriginSegmentId=[string]$segment.SegmentId; OriginLocation=[string]$segment.Location; OriginRevision=[int]$project.Revision
                    }
                    if ([string]$project.Direction -eq 'to_en') {
                        $params.JapanesePreferred=$sourceTerm; $params.EnglishPreferred=$preferred
                        $params.EnglishAllowed=$allowed; $params.EnglishForbidden=$forbidden
                    } else {
                        $params.EnglishPreferred=$sourceTerm; $params.JapanesePreferred=$preferred
                        $params.JapaneseAllowed=$allowed; $params.JapaneseForbidden=$forbidden
                    }
                    $termId = ([string]$payload['term_id']).Trim()
                    $termVersion = 0; try { $termVersion = [int]$payload['term_version'] } catch {}
                    $previousEntry = $null
                    if (-not [string]::IsNullOrWhiteSpace($termId)) {
                        if ($termId -notmatch '^[a-f0-9]{32}$') { throw 'TERMINOLOGY_REFERENCE_INVALID' }
                        $currentTerms = @(Get-YakuCatTerminologyEntries -Project $project | Where-Object { [string]$_.term_id -eq $termId })
                        if ($currentTerms.Count -ne 1 -or [int]$currentTerms[0].version -ne $termVersion) { throw 'TERMINOLOGY_REVISION_CONFLICT' }
                        $previousEntry = $currentTerms[0]
                        $params['TermId'] = $termId
                        $added = Update-YakuTerminologyEntry @params
                    } else {
                        $added = Add-YakuTerminologyEntry @params
                    }
                    $entry = $added.Entry
                    $mutation = {
                        param($candidate,$innerEntry)
                        $count = Update-YakuCatProjectForTerminologyChange -Project $candidate -Entry $innerEntry
                        return [int]$count
                    }
                    try {
                        $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($entry)
                    } catch {
                        $commitError = $_
                        # The terminology store is append-only and lives outside the
                        # project snapshot. If the project commit fails after a new
                        # record was appended, immediately add an inactive revision so
                        # the orphan never becomes a candidate in this or another job.
                        if ([bool]$added.Added) {
                            try {
                                if ($null -ne $previousEntry) {
                                    $null = Update-YakuTerminologyEntry -TermId ([string]$entry.term_id) -Scope ([string]$previousEntry.scope) -ProjectId ([string]$previousEntry.project_id) `
                                        -Kind ([string]$previousEntry.kind) -Enforcement ([string]$previousEntry.enforcement) `
                                        -JapanesePreferred ([string]$previousEntry.ja.preferred) -EnglishPreferred ([string]$previousEntry.en.preferred) `
                                        -JapaneseAllowed @($previousEntry.ja.allowed) -JapaneseForbidden @($previousEntry.ja.forbidden) `
                                        -EnglishAllowed @($previousEntry.en.allowed) -EnglishForbidden @($previousEntry.en.forbidden) -Note ([string]$previousEntry.note) `
                                        -OriginProjectId ([string]$project.Id) -OriginFileName ([string]$project.FileName) -OriginSegmentId ([string]$segment.SegmentId) `
                                        -OriginLocation ([string]$segment.Location) -OriginRevision ([int]$project.Revision)
                                } else {
                                    $null = Disable-YakuTerminologyEntry -TermId ([string]$entry.term_id) `
                                        -OriginProjectId ([string]$project.Id) -OriginFileName ([string]$project.FileName) `
                                        -OriginSegmentId ([string]$segment.SegmentId) -OriginLocation ([string]$segment.Location) `
                                        -OriginRevision ([int]$project.Revision)
                                }
                            } catch {
                                try { Write-YakuLog ('Terminology compensation failed. term=' + [string]$entry.term_id) 'ERROR' } catch {}
                            }
                        }
                        throw $commitError.Exception
                    }
                    $project = $commit.Project
                    $body = (ConvertTo-YakuCatProjectJson -Project $project) | ConvertFrom-Json
                    $body | Add-Member -NotePropertyName term_affected_count -NotePropertyValue ([int]$commit.Result) -Force
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 9 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'term-deactivate' {
                    $index = -1; try { $index = [int]$payload['index'] } catch {}
                    $termId = ([string]$payload['term_id']).Trim()
                    if ($termId -notmatch '^[a-f0-9]{32}$') { throw 'TERMINOLOGY_REFERENCE_INVALID' }
                    $segs2 = @($project.Segments)
                    if ($index -lt 0 -or $index -ge $segs2.Count) { throw '用語を変更する行が見つかりません。' }
                    $currentTerms = @(Get-YakuCatTerminologyEntries -Project $project | Where-Object { [string]$_.term_id -eq $termId })
                    if ($currentTerms.Count -ne 1) { throw 'TERMINOLOGY_ENTRY_NOT_FOUND' }
                    $oldEntry = $currentTerms[0]; $segment = $segs2[$index]
                    $disabled = Disable-YakuTerminologyEntry -TermId $termId `
                        -OriginProjectId ([string]$project.Id) -OriginFileName ([string]$project.FileName) `
                        -OriginSegmentId ([string]$segment.SegmentId) -OriginLocation ([string]$segment.Location) `
                        -OriginRevision ([int]$project.Revision)
                    $mutation = {
                        param($candidate,$innerEntry)
                        return (Update-YakuCatProjectForTerminologyChange -Project $candidate -Entry $innerEntry)
                    }
                    try {
                        $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($oldEntry)
                    } catch {
                        $deactivateCommitError = $_
                        try {
                            $null = Update-YakuTerminologyEntry -TermId $termId -Scope ([string]$oldEntry.scope) -ProjectId ([string]$oldEntry.project_id) `
                                -Kind ([string]$oldEntry.kind) -Enforcement ([string]$oldEntry.enforcement) `
                                -JapanesePreferred ([string]$oldEntry.ja.preferred) -EnglishPreferred ([string]$oldEntry.en.preferred) `
                                -JapaneseAllowed @($oldEntry.ja.allowed) -JapaneseForbidden @($oldEntry.ja.forbidden) `
                                -EnglishAllowed @($oldEntry.en.allowed) -EnglishForbidden @($oldEntry.en.forbidden) `
                                -Note ([string]$oldEntry.note) -OriginProjectId ([string]$project.Id) -OriginFileName ([string]$project.FileName) `
                                -OriginSegmentId ([string]$segment.SegmentId) -OriginLocation ([string]$segment.Location) -OriginRevision ([int]$project.Revision)
                        } catch { try { Write-YakuLog ('Terminology restore failed. term=' + $termId) 'ERROR' } catch {} }
                        throw ('TERMINOLOGY_PROJECT_COMMIT_FAILED:' + [string]$deactivateCommitError.Exception.Message)
                    }
                    $project = $commit.Project
                    $body = (ConvertTo-YakuCatProjectJson -Project $project) | ConvertFrom-Json
                    $body | Add-Member -NotePropertyName term_affected_count -NotePropertyValue ([int]$commit.Result) -Force
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 9 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'term-insert' {
                    $index = -1; try { $index = [int]$payload['index'] } catch {}
                    $text = [string]$payload['text']; $referenceId = [string]$payload['reference_id']
                    $matches = @(Get-YakuCatSegmentCandidates -Root $script:YakuRoot -Project $project -Index $index | Where-Object { [string]$_.ReferenceId -eq $referenceId -and [string]$_.Kind -eq 'term' })
                    if ($matches.Count -ne 1) { throw 'CAT_TERM_REFERENCE_NOT_AVAILABLE' }
                    $mutation = {
                        param($candidate,$innerIndex,$innerText,$innerCandidate)
                        $null = Set-YakuCatSegmentTranslation -Project $candidate -Index $innerIndex -Text $innerText
                        $null = Set-YakuCatSegmentTerminologyUsage -Project $candidate -Index $innerIndex -Candidate $innerCandidate
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($index,$text,$matches[0])
                    $project = $commit.Project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'term-exception' {
                    $index=-1; $version=0; try{$index=[int]$payload['index']}catch{}; try{$version=[int]$payload['term_version']}catch{}
                    $mutation = {
                        param($candidate,$innerIndex,$termId,$termVersion,$reason,$alternative,$note)
                        $null = Add-YakuCatTerminologyException -Project $candidate -Index $innerIndex -TermId $termId -TermVersion $termVersion -ReasonCode $reason -Alternative $alternative -Note $note
                    }
                    $reasonCode = if ([string]$payload['reason_code'] -eq 'approved-alternative') { 'approved-alternative' } else { 'not-applicable' }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($index,[string]$payload['term_id'],$version,$reasonCode,[string]$payload['alternative'],[string]$payload['note'])
                    $project=$commit.Project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'tm-delete' {
                    $referenceId = [string]$payload['reference_id']
                    if ($referenceId -notmatch '^[a-f0-9]{64}$') { throw 'TRANSLATION_MEMORY_REFERENCE_INVALID' }
                    $index=-1; try{$index=[int]$payload['index']}catch{}
                    $matches=@(Get-YakuCatSegmentCandidates -Root $script:YakuRoot -Project $project -Index $index | Where-Object { [string]$_.Kind -eq 'memory' -and [string]$_.ReferenceId -eq $referenceId })
                    if($matches.Count -ne 1){throw 'TRANSLATION_MEMORY_REFERENCE_NOT_AVAILABLE'}
                    $deleted = Add-YakuTranslationMemoryTombstone -Direction ([string]$project.Direction) `
                        -OriginProjectId ([string]$matches[0].OriginProjectId) -OriginSegmentId ([string]$matches[0].OriginSegmentId) `
                        -ReviewRevision ([int]$matches[0].ReviewRevision) -Reason 'withdrawn-by-user'
                    Send-YakuTextResponse -Context $Context -Text (([ordered]@{ deleted=[bool]$deleted.Added; reason=[string]$deleted.Reason } | ConvertTo-Json -Compress)) -ContentType 'application/json; charset=utf-8'
                }
                'confirm' {
                    # 「この行は見た」を記録する。訳文が変わっていなくても押せる。
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $flag = $true
                    try { if ($payload.ContainsKey('confirmed')) { $flag = [bool]$payload['confirmed'] } } catch {}
                    $mutation = {
                        param($candidate,$innerIndex,$innerFlag,$root,$innerSettings)
                        $blocked = $false
                        try { $null = Set-YakuCatSegmentConfirmed -Project $candidate -Index $innerIndex -Confirmed $innerFlag }
                        catch {
                            if ([string]$_.Exception.Message -like 'CAT_REVIEW_QC_FAILED:*') { $blocked = $true }
                            else { throw }
                        }
                        $propagated = 0
                        if ($innerFlag -and -not $blocked) {
                            $reviewed = @($candidate.Segments)[$innerIndex]
                            $null = Add-YakuCatTranslationMemoryOutboxEvent -Project $candidate -Segment $reviewed
                            # 同じ原文の行へ配る。空の行にだけ入れ、確認済みにはしない。
                            $propagated = [int](Copy-YakuCatTranslationToRepetitions -Project $candidate -Index $innerIndex)
                        }
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                        return [pscustomobject]@{ ReviewBlocked=$blocked; Propagated=$propagated }
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($index,$flag,$script:YakuRoot,$settings)
                    $project = $commit.Project
                    $reviewBlocked = [bool]$commit.Result.ReviewBlocked
                    if ($flag -and -not $reviewBlocked) {
                        # projectと同じ世代に保存したoutboxを、commit後に冪等反映する。
                        # 失敗しても再開時に再試行でき、確認訳が黙って失われない。
                        $null = Sync-YakuCatTranslationMemoryOutbox -Project $project
                    }
                    $json = ConvertTo-YakuCatProjectJson -Project $project
                    $propagatedRows = [int]$(try { $commit.Result.Propagated } catch { 0 })
                    if ($reviewBlocked -or $propagatedRows -gt 0) {
                        $body = $json | ConvertFrom-Json
                        if ($reviewBlocked) { $body | Add-Member -NotePropertyName review_blocked -NotePropertyValue $true -Force }
                        # 何行に配ったかを画面へ返す。黙って他の行が変わるのがいちばん困る。
                        if ($propagatedRows -gt 0) { $body | Add-Member -NotePropertyName propagated -NotePropertyValue $propagatedRows -Force }
                        $json = $body | ConvertTo-Json -Depth 8 -Compress
                    }
                    Send-YakuTextResponse -Context $Context -Text $json -ContentType 'application/json; charset=utf-8'
                }
                'confirm-bulk' {
                    # 表示中の行をまとめて確認済みにする。市販CATは12本すべてが
                    # 一括確定を持つ。ここも Ctrl+Enter を押し続ければ同じことが
                    # 起きるので、押下回数だけを利用者に負わせる理由が無い。
                    #
                    # QC は Set-YakuCatSegmentConfirmed の内側にあるので、1行ずつと
                    # 同じ検査が全行で走る。通らなかった行は確定せずに数えて返し、
                    # 利用者が絞り込んで直せるようにする。
                    $indexes = @()
                    try { $indexes = @($payload['indexes'] | ForEach-Object { [int]$_ }) } catch { $indexes = @() }
                    if ($indexes.Count -eq 0) { throw 'CAT_BULK_CONFIRM_NO_TARGET: 対象の行がありません。' }
                    $mutation = {
                        param($candidate,$innerIndexes,$root,$innerSettings)
                        $done = 0; $failed = New-Object System.Collections.ArrayList
                        foreach ($one in $innerIndexes) {
                            $blocked = $false
                            try { $null = Set-YakuCatSegmentConfirmed -Project $candidate -Index $one -Confirmed $true }
                            catch {
                                if ([string]$_.Exception.Message -like 'CAT_REVIEW_QC_FAILED:*') { $blocked = $true }
                                else { throw }
                            }
                            if ($blocked) { $null = $failed.Add([int]$one); continue }
                            $done++
                            $reviewed = @($candidate.Segments)[$one]
                            $null = Add-YakuCatTranslationMemoryOutboxEvent -Project $candidate -Segment $reviewed
                        }
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                        return [pscustomobject]@{ Confirmed=$done; Blocked=@($failed.ToArray()) }
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($indexes,$script:YakuRoot,$settings)
                    $project = $commit.Project
                    if ([int]$commit.Result.Confirmed -gt 0) { $null = Sync-YakuCatTranslationMemoryOutbox -Project $project }
                    $body = (ConvertTo-YakuCatProjectJson -Project $project) | ConvertFrom-Json
                    $body | Add-Member -NotePropertyName bulk_confirmed -NotePropertyValue ([int]$commit.Result.Confirmed) -Force
                    $body | Add-Member -NotePropertyName bulk_blocked -NotePropertyValue @($commit.Result.Blocked) -Force
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'save-corpus' {
                    # グリッドで確かめた対訳をコーパスへ入れる。人が一度見てから
                    # 貯める、という順序をここで担保する。
                    throw 'CAT_CORPUS_PUBLIC_ATTESTATION_REQUIRED: 公表実績を検証する取込経路が未実装のため、この版では文例登録を停止しています。'
                }
                'segment' {
                    $index = -1
                    try { $index = [int]$payload['index'] } catch { $index = -1 }
                    $text = ''
                    try { $text = [string]$payload['text'] } catch {}
                    $referenceId = ''
                    try { $referenceId = [string]$payload['reference_id'] } catch {}
                    $mutation = {
                        param($candidate,$innerIndex,$innerText,$innerReferenceId,$root,$innerSettings)
                        $null = Set-YakuCatSegmentTranslation -Project $candidate -Index $innerIndex -Text $innerText
                        if (-not [string]::IsNullOrWhiteSpace($innerReferenceId)) {
                            $matches = @(Get-YakuCatSegmentCandidates -Root $root -Project $candidate -Index $innerIndex | Where-Object { [string]$_.ReferenceId -eq $innerReferenceId })
                            if ($matches.Count -ne 1) { throw 'CAT_REFERENCE_NOT_AVAILABLE' }
                            if ([string]$matches[0].Kind -eq 'term') { throw 'CAT_TERM_CANNOT_REPLACE_SEGMENT' }
                            $null = Set-YakuCatSegmentReferenceUsage -Project $candidate -Index $innerIndex -Candidate $matches[0]
                        }
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($index,$text,$referenceId,$script:YakuRoot,$settings)
                    $project = $commit.Project
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'concordance' {
                    # 過去に確認した訳を言葉で探す（市販CATのコンコーダンス）。
                    # 状態は変えないので revision は要求しない。
                    $query = ''
                    try { $query = [string]$payload['query'] } catch { $query = '' }
                    $hits = @()
                    try { $hits = @(Search-YakuTranslationMemoryConcordance -Query $query -Direction ([string]$project.Direction) -Limit 20) } catch { $hits = @() }
                    $rows = New-Object System.Collections.Generic.List[object]
                    foreach ($hit in $hits) {
                        [void]$rows.Add([ordered]@{
                            source = [string]$hit.Source
                            target = [string]$hit.Target
                            matched_in = [string]$hit.MatchedIn
                            saved = [string]$hit.Saved
                            file_name = [string]$hit.SourceName
                            location = [string]$hit.Location
                        })
                    }
                    $body = [ordered]@{ query = [string]$query; hits = @($rows.ToArray()) }
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 6 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'estimate' {
                    $usage = Get-YakuCatCopilotUsage -Root $script:YakuRoot -Project $project -Settings $settings
                    $body = [ordered]@{
                        unique_remaining = [int]$usage.UniqueRemaining
                        cache_hits = [int]$usage.CacheHits
                        pending = [int]$usage.Pending
                        estimated_calls = [int]$usage.EstimatedCalls
                        calls_last_3h = [int]$usage.CallsLast3h
                        max_chars = [int]$usage.MaxChars
                    }
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'translate' {
                    # Copilot への往復は他の翻訳と同じくジョブで行う（一度に1つ）。
                    # ジョブは別のランスペースで走るため、メモリ上のプロジェクトを
                    # 直接触れない。訳文だけを返させ、完了後に apply で反映する。
                    $readyState = Get-YakuTranslateReadinessState
                    if (-not [bool]$readyState.canTranslate) {
                        $message = if ([string]$readyState.mode -eq 'working') { 'いま別の翻訳を実行中です。そちらが終わってからもう一度お試しください。' } else { 'Copilotの準備が終わってから翻訳できます。画面右上が「使えます」になるまでお待ちください。' }
                        Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind warning -Message $message)) -StatusCode 409
                        return
                    }
                    $catMode = 'translate'
                    try {
                        $requestedMode = [string]$payload['mode']
                        if ($requestedMode -eq 'corpus') { throw 'CAT_CORPUS_MODE_RETIRED: 過去の翻訳例は候補一覧から明示的に挿入してください。' }
                        if ($requestedMode -eq 'revise') { $catMode = $requestedMode }
                    } catch {}
                    $pending = @()
                    $segs = @($project.Segments)
                    if ($catMode -eq 'revise') {
                        $revIndex = -1; $revInstruction = ''
                        try { $revIndex = [int]$payload['index'] } catch { $revIndex = -1 }
                        try { $revInstruction = [string]$payload['instruction'] } catch { $revInstruction = '' }
                        if ($revIndex -lt 0 -or $revIndex -ge $segs.Count) { throw '修正する行が見つかりません。' }
                        if ([string]::IsNullOrWhiteSpace($revInstruction)) { throw '修正の指示を入力してください。' }
                        $maskedCurrent = [string]$segs[$revIndex].MaskedTranslation
                        if ([string]::IsNullOrWhiteSpace([string]$segs[$revIndex].Translation) -or [string]::IsNullOrWhiteSpace($maskedCurrent)) {
                            throw 'この訳文はCopilotで作ったものではないため、直せません。先に「残りの訳案を作る」を押してください。'
                        }
                        $pending += ,([ordered]@{
                            index = $revIndex; text = [string]$segs[$revIndex].Text
                            current_text = $maskedCurrent; instruction = $revInstruction
                        })
                    } else {
                        for ($i = 0; $i -lt $segs.Count; $i++) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
                            $termRows=@()
                            try {
                                $termRows=@(Find-YakuTerminologyMatches -Text ([string]$segs[$i].Text) -Direction ([string]$project.Direction) `
                                    -Entries @(Get-YakuCatTerminologyEntries -Project $project) -ProjectId ([string]$project.Id) | ForEach-Object {
                                        $row = [ordered]@{ term_id=[string]$_.TermId; version=[int]$_.Version; reference_id=[string]$_.ReferenceId; scope=[string]$_.Scope; source=[string]$_.SourceTerm; preferred=[string]$_.PreferredTarget; allowed=@($_.AllowedTargets); forbidden=@($_.ForbiddenTargets); enforcement=[string]$_.Enforcement }
                                        if (Test-YakuCatPromptTerminologyEligible -Term ([pscustomobject]$row) -Direction ([string]$project.Direction)) { $row }
                                    } | Where-Object { $null -ne $_ })
                            } catch { throw ('CAT_TERMINOLOGY_UNAVAILABLE: ' + $_.Exception.Message) }
                            $pending += ,([ordered]@{ index = $i; text = [string]$segs[$i].Text; terminology=@($termRows) })
                        }
                    }
                    if (@($pending).Count -eq 0) {
                        Send-YakuTextResponse -Context $Context -Text ((New-YakuAlertHtml -Kind info -Message '訳す残りがありません。')) -StatusCode 409
                        return
                    }
                    # 文例は候補ペインでの参考表示に限定し、翻訳promptへは入れない。
                    # 金額の書き方を積み忘れていた（2026-08-12、実機のCAT往復で判明）。
                    # ジョブは別のランスペースで走るので、この JSON に載せたものしか
                    # 届かない。載せていなかったため、受け側の
                    # 「$cat.amount_notation が billion なら…」は常に偽になり、
                    # billion を選んだ作業でも oku で換算・指示していた
                    # （実測: 1兆3,150億円 -> 13,150 oku）。
                    $catJson = ([ordered]@{ project_id = [string]$project.Id; expected_project_revision = [int]$project.Revision; direction = [string]$project.Direction; mode = $catMode; amount_notation = (Get-YakuCatProjectAmountNotation -Project $project); items = @($pending) } | ConvertTo-Json -Depth 6 -Compress)
                    $state = Start-YakuTranslationJob -InputText '' -Settings $settings -Kind 'cat' -CatJson $catJson
                    Send-YakuTextResponse -Context $Context -Text (Convert-YakuTranslationJobStartedHtml -State $state)
                }
                'apply' {
                    $jobId = ''
                    try { $jobId = [string]$payload['job_id'] } catch {}
                    Update-YakuTranslationJobs
                    if ([string]::IsNullOrWhiteSpace($jobId) -or -not $script:YakuTranslateJobs.ContainsKey($jobId)) { throw (Get-YakuTranslationJobMissingMessage -JobId $jobId) }
                    $resultJson = [string]$script:YakuTranslateJobs[$jobId]['result_json']
                    if ([string]::IsNullOrWhiteSpace($resultJson)) { throw 'Copilotから訳文を受け取れませんでした。もう一度「残りの訳案を作る」を押してください。' }
                    $result = $resultJson | ConvertFrom-Json
                    if ($result.PSObject.Properties.Name -contains 'Error' -and $result.Error) { throw [string]$result.Error }
                    if (-not ($result.PSObject.Properties.Name -contains 'ProjectId') -or [string]$result.ProjectId -ne [string]$project.Id) {
                        throw 'CAT_JOB_PROJECT_MISMATCH: 翻訳を開始した作業と現在の作業が一致しないため、結果を適用しませんでした。'
                    }
                    if ([int]$result.ProjectRevision -ne [int]$project.Revision) { throw 'CAT_PROJECT_REVISION_CONFLICT: 翻訳中に作業内容が変更されたため、古い結果は適用しませんでした。' }
                    if (($result.PSObject.Properties.Name -contains 'Mode') -and [string]$result.Mode -eq 'corpus') {
                        throw 'CAT_CORPUS_MODE_RETIRED: 旧方式の翻訳例job結果は適用できません。'
                    }
                    $mutation = {
                        param($candidate,$innerResult,$root,$innerSettings)
                        $segs = @($candidate.Segments)
                        $isRevision = (($innerResult.PSObject.Properties.Name -contains 'Mode') -and [string]$innerResult.Mode -eq 'revise')
                        foreach ($pair in @($innerResult.Translations)) {
                            $i = [int]$pair.index
                            if ($i -lt 0 -or $i -ge $segs.Count) { continue }
                            if (-not ($pair.PSObject.Properties.Name -contains 'source') -or [string]$pair.source -ne [string]$segs[$i].Text) {
                                throw 'CAT_JOB_SOURCE_MISMATCH: 翻訳開始時の原文と現在の原文が一致しないため、結果を適用しませんでした。'
                            }
                            if ($isRevision) {
                                # 待っている間に人が直した場合は、古い現訳をもとにした
                                # 修正結果で上書きしない。
                                if ([string]$segs[$i].MaskedTranslation -ne [string]$pair.previous_masked) { continue }
                            } else {
                                # 通常翻訳も、待っている間に人が直したものは踏まない。
                                if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
                            }
                            $appliedText = [string]$pair.text
                            if ([string]$candidate.Direction -eq 'to_en') {
                                # CAT job が持つ item は保護済み表現の場合があるため、表示へ
                                # 反映する最後の境界で、project の正本原文に拘束して年度・
                                # 四半期・時刻を自然な英語表記へ整える。
                                $appliedText = ConvertTo-YakuNaturalEnglishNotation -SourceText ([string]$segs[$i].Text) -Translation $appliedText
                            }
                            if ($isRevision) {
                                $null = Update-YakuCatSegmentReferenceEditState -Segment $segs[$i] -Text $appliedText
                            }
                            $segs[$i].Translation = $appliedText
                            $segs[$i] | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue ([string]$pair.masked) -Force
                            $segs[$i].Origin = 'copilot'
                            $segs[$i].TerminologyGeneration = @($pair.terminology)
                            $segs[$i] | Add-Member -NotePropertyName State -NotePropertyValue 'machine_draft' -Force
                            Reset-YakuCatSegmentQc -Segment $segs[$i] -KeepState
                        }
                        try { $candidate | Add-Member -NotePropertyName 'GlossaryCandidates' -NotePropertyValue (Measure-YakuCatGlossaryCandidates -Root $root -Project $candidate -Settings $innerSettings) -Force } catch {}
                    }
                    $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision $expectedRevision -Mutation $mutation -Arguments @($result,$script:YakuRoot,$settings)
                    $project = $commit.Project
                    try { Remove-Item -LiteralPath (Get-YakuCatCheckpointPath -ProjectId ([string]$project.Id)) -Force -ErrorAction SilentlyContinue } catch {}
                    Send-YakuTextResponse -Context $Context -Text (ConvertTo-YakuCatProjectJson -Project $project) -ContentType 'application/json; charset=utf-8'
                }
                'preflight' {
                    $preflight = Get-YakuCatOutputPreflight -Project $project
                    $body = [ordered]@{
                        project_id = [string]$preflight.ProjectId
                        revision = [int]$preflight.Revision
                        eligible = [bool]$preflight.Eligible
                        mode = [string]$preflight.Mode
                        output_name = [string]$preflight.OutputName
                        unconfirmed_count = [int]$preflight.UnconfirmedCount
                        blockers = @($preflight.Blockers)
                        warnings = @($preflight.Warnings)
                        draft_notice = [string]$preflight.DraftNotice
                    }
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'personal-glossary-list' {
                    # 「今後の資料でも使う」で登録したものの一覧。取り消せるようにするために出す。
                    $rows = @(Read-YakuPersonalTerminologyEntries |
                        Where-Object { [string]$_.scope -eq 'personal' -and [bool]$_.active } |
                        ForEach-Object {
                            [ordered]@{
                                term_id = [string]$_.term_id
                                source = [string]$_.ja.preferred
                                target = [string]$_.en.preferred
                                origin_file_name = [string]$_.origin_file_name
                                origin_location = [string]$_.origin_location
                                created = [string]$_.created
                            }
                        })
                    Send-YakuTextResponse -Context $Context -Text (([ordered]@{ entries = @($rows) } | ConvertTo-Json -Depth 5 -Compress)) -ContentType 'application/json; charset=utf-8'
                }
                'personal-glossary-remove' {
                    $termId = [string]$payload['term_id']
                    $removal = Remove-YakuPersonalGlossaryEntry -TermId $termId
                    $message = if ([bool]$removal.Removed) { '登録を取り消しました。今後の資料では自動で使われません。' } else { 'この登録は、すでに取り消されています。' }
                    Send-YakuTextResponse -Context $Context -Text (([ordered]@{ removed = [bool]$removal.Removed; message = $message } | ConvertTo-Json -Compress)) -ContentType 'application/json; charset=utf-8'
                }
                'export-reviewed' {
                    # 確認済みの行だけを取り出す。全行そろうのを待たずに成果を持ち帰れる。
                    $reviewed = Export-YakuCatReviewedSegments -Project $project
                    $body = [ordered]@{
                        text = [string]$reviewed.Text
                        written = [int]$reviewed.Written
                        skipped = [int]$reviewed.Skipped
                        total = [int]$reviewed.Total
                        partial = [bool]$reviewed.Partial
                    }
                    Send-YakuTextResponse -Context $Context -Text ($body | ConvertTo-Json -Depth 4 -Compress) -ContentType 'application/json; charset=utf-8'
                }
                'export' {
                    $warnings = New-Object System.Collections.Generic.List[object]
                    # 貼り付けたテキストは書き戻す元が無いので、訳文を繋いで返す。
                    $outputPath = if ([string]$project.Source -ne 'file') { '' } else {
                        Get-YakuCatDraftOutputPath -Project $project
                    }
                    $exported = Export-YakuCatProject -Project $project -OutputPath $outputPath -Settings $settings -Warnings $warnings
                    # 出した場所を覚えておく。「フォルダを開く」から使う。
                    try { $project | Add-Member -NotePropertyName 'LastOutputPath' -NotePropertyValue ([string]$exported.OutputPath) -Force } catch {}
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
    } catch {}
    Exit-YakuSingleInstance
    Write-Host 'YakuLingo server stopped.'
}
