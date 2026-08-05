$script:YakuLoadedBuildId = $null

function Get-YakuBuildId {
    if ($null -eq $script:YakuLoadedBuildId) {
        if ([string]::IsNullOrWhiteSpace([string]$script:YakuRoot)) {
            throw 'BUILD_ID_ROOT_MISSING: アプリのルートフォルダを特定できません。アプリを展開し直してください。'
        }
        $path = Join-Path $script:YakuRoot 'config\build.txt'
        try { $script:YakuLoadedBuildId = ([string](Get-Content -LiteralPath $path -Raw -Encoding UTF8)).Trim() }
        catch { $script:YakuLoadedBuildId = '' }
        if ([string]::IsNullOrWhiteSpace($script:YakuLoadedBuildId)) {
            throw 'BUILD_ID_MISSING: config\build.txt を読み込めません。アプリを展開し直してください。'
        }
    }
    return $script:YakuLoadedBuildId
}

function Get-YakuDiskBuildId {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'config\build.txt'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return ([string](Get-Content -LiteralPath $path -Raw -Encoding UTF8)).Trim() }
    catch { return '' }
}

function Get-YakuExistingServerProcessHint {
    try {
        $path = Join-Path (Get-YakuSubDir 'runtime') 'server.json'
        $state = Read-YakuJsonFile -Path $path
        if ($state -and (Test-YakuProcessIdentity -Id ([int]$state.pid) -StartTimeUtc ([string]$state.process_started_at))) {
            return " 前回プロセス候補: PID=$([int]$state.pid), 開始=$([string]$state.process_started_at)。"
        }
    } catch {}
    return ''
}

function Assert-YakuBuildIdentity {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$ExpectedBuildId
    )
    $loaded = Get-YakuBuildId
    $disk = Get-YakuDiskBuildId -Root $Root
    if ([string]::IsNullOrWhiteSpace($disk)) {
        throw 'BUILD_ID_MISSING: config\build.txt を読み込めません。アプリを展開し直してください。'
    }
    $hint = Get-YakuExistingServerProcessHint
    $action = '旧プロセスが残っているか、起動中にパッケージが差し替えられた可能性があります。既存のYakuLingoを終了し、同じフォルダ内のファイルを一式展開し直してから再起動してください。'
    if (-not [string]::Equals($loaded, $disk, [System.StringComparison]::Ordinal)) {
        throw "BUILD_ID_DISK_MISMATCH: 読込済み=$loaded 配置済み=$disk。$action$hint"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedBuildId) -and -not [string]::Equals($loaded, $ExpectedBuildId, [System.StringComparison]::Ordinal)) {
        throw "BUILD_ID_PROCESS_MISMATCH: サーバー=$ExpectedBuildId 実行側=$loaded。$action$hint"
    }
    return $loaded
}

function New-YakuSecureToken {
    param([int]$ByteLength = 32)
    if ($ByteLength -lt 16) { $ByteLength = 16 }
    $bytes = New-Object byte[] $ByteLength
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_'))
}

function Get-YakuSha256Hex {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Write-YakuTextAtomic {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and !(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $temp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($temp, [string]$Text, $utf8Bom)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = $temp + '.bak'
            $replaced = $false
            for ($attempt = 0; $attempt -lt 5 -and -not $replaced; $attempt++) {
                try {
                    [System.IO.File]::Replace($temp, $Path, $backup, $true)
                    $replaced = $true
                } catch {
                    if ($attempt -ge 4) { break }
                    Start-Sleep -Milliseconds (30 * ($attempt + 1))
                }
            }
            if (-not $replaced) {
                # Keep a valid pathname throughout fallback: old -> backup, new -> target.
                [System.IO.File]::Move($Path, $backup)
                try { [System.IO.File]::Move($temp, $Path) }
                catch { try { [System.IO.File]::Move($backup, $Path) } catch {}; throw }
            }
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-YakuJsonAtomic {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Value,
        [int]$Depth = 40
    )
    Write-YakuTextAtomic -Path $Path -Text ($Value | ConvertTo-Json -Depth $Depth)
}

function Read-YakuJsonFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Get-YakuProcessStartTimeIso {
    param([int]$Id = $PID)
    try { return (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') }
    catch { return '' }
}

function Test-YakuProcessIdentity {
    param(
        [int]$Id,
        [AllowNull()][string]$StartTimeUtc
    )
    if ($Id -le 0 -or [string]::IsNullOrWhiteSpace($StartTimeUtc)) { return $false }
    try {
        $actual = (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime()
        $expected = [datetime]::Parse($StartTimeUtc).ToUniversalTime()
        return ([Math]::Abs(($actual - $expected).TotalSeconds) -lt 1.5)
    } catch { return $false }
}

function ConvertTo-YakuStateHashtable {
    param([AllowNull()]$State)
    $copy = [ordered]@{}
    if ($null -eq $State) { return $copy }
    if ($State -is [System.Collections.IDictionary]) {
        foreach ($key in @($State.Keys)) { $copy[[string]$key] = $State[$key] }
    } else {
        foreach ($prop in @($State.PSObject.Properties)) { $copy[[string]$prop.Name] = $prop.Value }
    }
    return $copy
}

function Write-YakuProgressStateFile {
    param([AllowNull()]$ProgressState)
    if ($null -eq $ProgressState) { return }
    $path = ''
    try { $path = [string]$ProgressState['state_path'] } catch { $path = '' }
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $allowed = @(
        'id','kind','mode','label','class','detail','progress','phase','input_length','file_name',
        'output_path','output_name','blocks_total','blocks_translated','blocks_retained','unique_done',
        'unique_total','cells','shapes','charts','created_at','started_at','completed_at','updated_at',
        'worker_pid','worker_started_at','excel_pid','excel_started_at','error_code','completion_status',
        'result_path','cancel_path','uploaded_input','diagnostics_enabled','build_id'
    )
    $safe = [ordered]@{}
    foreach ($key in $allowed) {
        try { if ($ProgressState.ContainsKey($key)) { $safe[$key] = $ProgressState[$key] } } catch {}
    }
    Write-YakuJsonAtomic -Path $path -Value $safe -Depth 12
}

function Test-YakuCancellationRequested {
    param([AllowNull()]$ProgressState)
    if ($null -eq $ProgressState) { return $false }
    $path = ''
    try { $path = [string]$ProgressState['cancel_path'] } catch { $path = '' }
    return (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf))
}

function Assert-YakuJobNotCancelled {
    param([AllowNull()]$ProgressState)
    if (Test-YakuCancellationRequested -ProgressState $ProgressState) {
        throw [System.OperationCanceledException]::new('翻訳をキャンセルしました。')
    }
}
