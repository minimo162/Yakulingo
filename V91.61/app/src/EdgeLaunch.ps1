function Write-YakuEdgeLaunchLog {
    param([Parameter(Mandatory=$true)][string]$Message, [string]$Level = 'INFO')
    if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) {
        Write-YakuLog -Message $Message -Level $Level
        return
    }
    try {
        $path = Join-Path (Get-YakuSubDir 'logs') 'yakulingo.log'
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        $mutex = New-Object System.Threading.Mutex($false, 'Local\YakuLingo-LogWrite')
        $locked = $false
        try {
            $locked = $mutex.WaitOne(3000)
            if ($locked) { Add-Content -LiteralPath $path -Value $line -Encoding UTF8 }
        } finally {
            if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
            $mutex.Dispose()
        }
    } catch {}
}

function Get-YakuEdgePath {
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) | Where-Object { $_ }
    $candidates = foreach ($root in $roots) { Join-Path $root 'Microsoft\Edge\Application\msedge.exe' }
    $candidates = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($candidates.Count -gt 0) { return $candidates[0] }
    $cmd = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Microsoft Edge が見つかりません。Edge をインストールするか、PATH に msedge.exe を追加してください。'
}

function Initialize-YakuEdgeWindowApi {
    if ('YakuLingo.EdgeWindowApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace YakuLingo {
    public static class EdgeWindowApi {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int command);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        public static IntPtr[] FindTopLevelWindows(int[] processIds) {
            var wanted = new HashSet<int>(processIds ?? new int[0]);
            var found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr _) {
                uint pid; GetWindowThreadProcessId(hWnd, out pid);
                if (wanted.Contains((int)pid)) found.Add(hWnd);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }
    }
}
'@
}

function Get-YakuDedicatedEdgeProcessIds {
    param([string]$UserDataDir = (Join-Path (Get-YakuDataDir) 'edge-profile'))
    $full = [System.IO.Path]::GetFullPath($UserDataDir)
    try {
        return [int[]]@(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction Stop | Where-Object {
            $_.CommandLine -and $_.CommandLine.IndexOf($full, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        } | ForEach-Object { [int]$_.ProcessId })
    } catch {
        Write-YakuEdgeLaunchLog "Dedicated Edge process enumeration failed. reason=$($_.Exception.Message)" 'WARN'
        return [int[]]@()
    }
}

function Get-YakuEdgeHiddenWindowsPath {
    return (Join-Path (Get-YakuSubDir 'runtime') 'edge-hidden-windows.json')
}

function Set-YakuEdgeWindowVisibility {
    param(
        [ValidateSet('hidden','foreground')][string]$Mode = 'hidden',
        [string]$UserDataDir = (Join-Path (Get-YakuDataDir) 'edge-profile')
    )
    try {
        Initialize-YakuEdgeWindowApi
        $pids = [int[]]@(Get-YakuDedicatedEdgeProcessIds -UserDataDir $UserDataDir)
        if ($pids.Count -eq 0) { return 0 }
        $pidSet = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($pidValue in $pids) { $null = $pidSet.Add([int]$pidValue) }
        $recordPath = Get-YakuEdgeHiddenWindowsPath
        $changed = 0
        if ($Mode -eq 'hidden') {
            $saved = New-Object 'System.Collections.Generic.List[long]'
            if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
                try { foreach ($value in @((Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json).handles)) { $saved.Add([long]$value) } } catch {}
            }
            foreach ($window in @([YakuLingo.EdgeWindowApi]::FindTopLevelWindows($pids))) {
                if ($window -eq [IntPtr]::Zero -or -not [YakuLingo.EdgeWindowApi]::IsWindowVisible($window)) { continue }
                [void][YakuLingo.EdgeWindowApi]::ShowWindowAsync($window, 0) # SW_HIDE removes the taskbar button too.
                if (-not $saved.Contains([long]$window)) { $saved.Add([long]$window) }
                $changed++
            }
            $record = [ordered]@{ handles=@($saved.ToArray()); saved_at=(Get-Date).ToUniversalTime().ToString('o') }
            [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($true)))
        } else {
            $savedHandles = @()
            if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
                try { $savedHandles = @((Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json).handles) } catch { $savedHandles = @() }
            }
            foreach ($handleValue in $savedHandles) {
                $window = [IntPtr]([long]$handleValue)
                if ($window -eq [IntPtr]::Zero) { continue }
                [uint32]$ownerPid = 0
                [void][YakuLingo.EdgeWindowApi]::GetWindowThreadProcessId($window, [ref]$ownerPid)
                if (-not $pidSet.Contains([int]$ownerPid)) { continue }
                [void][YakuLingo.EdgeWindowApi]::ShowWindowAsync($window, 9) # SW_RESTORE
                [void][YakuLingo.EdgeWindowApi]::SetForegroundWindow($window)
                $changed++
            }
            Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
        }
        Write-YakuEdgeLaunchLog "Dedicated Edge window visibility changed. mode=$Mode windows=$changed" 'INFO'
        return $changed
    } catch {
        Write-YakuEdgeLaunchLog "Dedicated Edge window visibility change failed. mode=$Mode reason=$($_.Exception.Message)" 'WARN'
        return 0
    }
}

function Get-YakuDevToolsVersion {
    param([int]$Port = 9433, [int]$TimeoutSec = 2)
    return Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec $TimeoutSec
}

function Get-YakuCdpPort {
    param([AllowNull()]$Settings)
    $port = 9433
    try {
        if ($Settings -and ($Settings.PSObject.Properties.Name -contains 'edge_debug_port')) {
            $settingsPort = 0
            if ([int]::TryParse([string]$Settings.edge_debug_port, [ref]$settingsPort) -and $settingsPort -ge 1024 -and $settingsPort -le 65535) { $port = $settingsPort }
        }
    } catch {}
    if ($env:YAKULINGO_CDP_PORT) {
        $parsed = 0
        if ([int]::TryParse([string]$env:YAKULINGO_CDP_PORT, [ref]$parsed) -and $parsed -ge 1024 -and $parsed -le 65535) { $port = $parsed }
    }
    return $port
}

function Get-YakuCopilotUrl {
    param([AllowNull()]$Settings)
    $approved = 'https://m365.cloud.microsoft/chat/'
    $url = $approved
    try {
        if ($Settings -and ($Settings.PSObject.Properties.Name -contains 'copilot_url') -and -not [string]::IsNullOrWhiteSpace([string]$Settings.copilot_url)) {
            $url = [string]$Settings.copilot_url
        }
    } catch { $url = $approved }
    if (-not [string]::Equals($url, $approved, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Copilot接続先が承認済みURLではありません。'
    }
    return $url
}

function Wait-YakuDevTools {
    param([int]$Port = 9433, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Get-YakuDevToolsVersion -Port $Port -TimeoutSec 2
            return $true
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function ConvertTo-YakuEdgeWindowSize {
    param([AllowNull()][string]$Value)
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '1280,900' }
    if ([string]::Equals($text, 'none', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Enabled=$false; Width=0; Height=0; Canonical='none' }
    }
    $match = [regex]::Match($text, '^\s*(\d{3,5})\s*[,xX]\s*(\d{3,5})\s*$')
    if (-not $match.Success) {
        Write-YakuEdgeLaunchLog "Invalid edge_window_size was replaced with the default. value=$text" 'WARN'
        return [pscustomobject]@{ Enabled=$true; Width=1280; Height=900; Canonical='1280,900' }
    }
    $width = [Math]::Min(7680, [Math]::Max(800, [int]$match.Groups[1].Value))
    $height = [Math]::Min(4320, [Math]::Max(600, [int]$match.Groups[2].Value))
    return [pscustomobject]@{ Enabled=$true; Width=$width; Height=$height; Canonical="$width,$height" }
}

function Get-YakuEdgeLaunchSpec {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$WindowSize = '1280,900',
        [string]$DisplayMode = 'background'
    )
    $edge = Get-YakuEdgePath
    $userData = Join-Path (Get-YakuDataDir) 'edge-profile'
    if (!(Test-Path -LiteralPath $userData)) { New-Item -ItemType Directory -Path $userData -Force | Out-Null }
    $quotedProfile = '"' + $userData.Replace('"','\"') + '"'
    $quotedUrl = '"' + $Url.Replace('"','\"') + '"'
    $window = ConvertTo-YakuEdgeWindowSize -Value $WindowSize
    $windowArgument = if ($window.Enabled) { " --window-size=$($window.Width),$($window.Height)" } else { '' }
    $displayArgument = if ([string]::Equals($DisplayMode, 'foreground', [System.StringComparison]::OrdinalIgnoreCase)) { '' } else { ' --start-minimized' }
    $arguments = "--remote-debugging-port=$Port --remote-debugging-address=127.0.0.1 --user-data-dir=$quotedProfile --no-first-run --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-features=CalculateNativeWinOcclusion,msEdgeTranslate$windowArgument$displayArgument $quotedUrl"
    return [pscustomobject]@{ EdgePath=$edge; UserDataDir=$userData; Arguments=$arguments; Port=$Port; Url=$Url; WindowSize=$window }
}

function Remove-YakuCdpOwnershipFileCache {
    try {
        $path = Join-Path (Get-YakuSubDir 'runtime') 'cdp-ownership.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Stop-YakuCopilotEdgeProfile {
    param([Parameter(Mandatory=$true)][string]$UserDataDir)
    try { if (Get-Command Clear-YakuCdpSocketCache -ErrorAction SilentlyContinue) { $null = Clear-YakuCdpSocketCache } } catch {}
    try { $script:YakuCdpOwnershipCache = $null } catch {}
    try { $script:YakuCopilotTargetCache = $null } catch {}
    try { Remove-YakuCdpOwnershipFileCache } catch {}
    try { Remove-Item -LiteralPath (Get-YakuEdgeHiddenWindowsPath) -Force -ErrorAction SilentlyContinue } catch {}
    try {
        $targetCachePath = Join-Path (Get-YakuSubDir 'runtime') 'cdp-copilot-target.json'
        if (Test-Path -LiteralPath $targetCachePath -PathType Leaf) { Remove-Item -LiteralPath $targetCachePath -Force -ErrorAction SilentlyContinue }
    } catch {}
    $stopped = 0
    try {
        if ($env:OS -and $env:OS -notlike '*Windows*') { return 0 }
        $matches = @()
        try {
            $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and ($_.CommandLine.IndexOf($UserDataDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            })
        } catch { $matches = @() }
        foreach ($proc in $matches) {
            try {
                Write-YakuEdgeLaunchLog "Stopping stale YakuLingo Edge process. pid=$($proc.ProcessId)" 'INFO'
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                $stopped++
            } catch {}
        }
    } catch {
        Write-YakuEdgeLaunchLog "Stop-YakuCopilotEdgeProfile failed: $($_.Exception.Message)" 'DEBUG'
    }
    return [int]$stopped
}

function Set-YakuEdgeProfileCleanExit {
    <#
      当アプリ専用の Edge profile に「前回はきちんと終わった」と書いておく。

      2026-08-12 実測。Edge を落として開き直すたびに窓のタブが1枚ずつ増えていた
      （Copilotの会話が2枚、それに「新しいタブ」）。原因は復元だった。
      profile\Default\Preferences の exit_type が Crashed になっており、Edge は
      前回のタブを復元する。復元されたタブは眠った状態（CDP では pid=0）で戻り、
      Target.closeTarget も /json/close も効かない。閉じるより、作らせない。

      触るのは当アプリの profile だけで、利用者ふだんの Edge には関係しない。
      文字列の置き換えにとどめる（読み直して書き戻すと、Edge が使う細かい型を
      PowerShell の JSON 変換が壊す）。
    #>
    param([Parameter(Mandatory=$true)][string]$UserDataDir)
    try {
        $path = Join-Path (Join-Path $UserDataDir 'Default') 'Preferences'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $text = [IO.File]::ReadAllText($path)
        if ($text -notmatch '"exit_type"\s*:\s*"(?!Normal")') { return $false }
        $updated = [regex]::Replace($text, '"exit_type"\s*:\s*"[^"]*"', '"exit_type":"Normal"')
        if ($updated -eq $text) { return $false }
        [IO.File]::WriteAllText($path, $updated)
        Write-YakuEdgeLaunchLog 'Edge profile marked as cleanly exited so the previous tabs are not restored.' 'INFO'
        return $true
    } catch {
        Write-YakuEdgeLaunchLog ('Edge profile clean-exit mark failed; continuing. reason=' + $_.Exception.Message) 'DEBUG'
        return $false
    }
}

function Start-YakuEdgeLaunch {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$DisplayMode = 'foreground',
        [string]$WindowSize = '1280,900',
        [switch]$NoWait,
        [int]$WaitForReadySeconds = 30
    )
    $spec = Get-YakuEdgeLaunchSpec -Port $Port -Url $Url -WindowSize $WindowSize -DisplayMode $DisplayMode
    $alreadyReachable = $false
    try { $null = Get-YakuDevToolsVersion -Port $Port -TimeoutSec 1; $alreadyReachable = $true } catch { $alreadyReachable = $false }
    if ($alreadyReachable) {
        return [pscustomobject]@{ Ready=$true; Started=$false; AlreadyReachable=$true; ProcessId=0; Spec=$spec }
    }

    $inProgress = $script:YakuEdgeLaunchInProgress
    if ($inProgress -and [int]$inProgress.Port -eq $Port -and
        [string]::Equals([string]$inProgress.UserDataDir, [string]$spec.UserDataDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($NoWait) { return [pscustomobject]@{ Ready=$false; Started=$false; AlreadyReachable=$false; ProcessId=[int]$inProgress.ProcessId; Spec=$spec } }
        if (Wait-YakuDevTools -Port $Port -TimeoutSeconds $WaitForReadySeconds) {
            return [pscustomobject]@{ Ready=$true; Started=$false; AlreadyReachable=$false; ProcessId=[int]$inProgress.ProcessId; Spec=$spec }
        }
    }

    # W1: avoid the expensive WMI profile scan when no Edge process exists.
    $hasAnyEdge = (@(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue).Count -gt 0)
    $stopped = 0
    if ($hasAnyEdge) { $stopped = Stop-YakuCopilotEdgeProfile -UserDataDir $spec.UserDataDir }
    if ($stopped -gt 0) { Start-Sleep -Milliseconds 700 }

    $null = Set-YakuEdgeProfileCleanExit -UserDataDir $spec.UserDataDir
    Write-YakuEdgeLaunchLog "Starting Edge. port=$Port display=$DisplayMode" 'INFO'
    $startWindowStyle = if ([string]::Equals($DisplayMode, 'foreground', [System.StringComparison]::OrdinalIgnoreCase)) { 'Normal' } else { 'Minimized' }
    $process = Start-Process -FilePath $spec.EdgePath -ArgumentList $spec.Arguments -WindowStyle $startWindowStyle -PassThru
    $script:YakuEdgeLaunchInProgress = [pscustomobject]@{ Port=$Port; UserDataDir=$spec.UserDataDir; ProcessId=[int]$process.Id; StartedAt=(Get-Date) }
    if ($startWindowStyle -eq 'Minimized' -or $spec.WindowSize.Enabled) { $script:YakuEdgeNeedsWindowNormalization = [pscustomobject]@{ Port=$Port; WindowSize=$spec.WindowSize; DisplayMode=$DisplayMode; ProcessId=[int]$process.Id } }
    if ($NoWait) {
        return [pscustomobject]@{ Ready=$false; Started=$true; AlreadyReachable=$false; ProcessId=[int]$process.Id; Spec=$spec }
    }
    if (Wait-YakuDevTools -Port $Port -TimeoutSeconds $WaitForReadySeconds) {
        return [pscustomobject]@{ Ready=$true; Started=$true; AlreadyReachable=$false; ProcessId=[int]$process.Id; Spec=$spec }
    }

    Write-YakuEdgeLaunchLog 'Edge DevTools did not become reachable. Retrying after closing dedicated profile processes.' 'WARN'
    $null = Stop-YakuCopilotEdgeProfile -UserDataDir $spec.UserDataDir
    Start-Sleep -Seconds 2
    $null = Set-YakuEdgeProfileCleanExit -UserDataDir $spec.UserDataDir
    $retry = Start-Process -FilePath $spec.EdgePath -ArgumentList $spec.Arguments -WindowStyle $startWindowStyle -PassThru
    $script:YakuEdgeLaunchInProgress = [pscustomobject]@{ Port=$Port; UserDataDir=$spec.UserDataDir; ProcessId=[int]$retry.Id; StartedAt=(Get-Date) }
    if ($startWindowStyle -eq 'Minimized' -or $spec.WindowSize.Enabled) { $script:YakuEdgeNeedsWindowNormalization = [pscustomobject]@{ Port=$Port; WindowSize=$spec.WindowSize; DisplayMode=$DisplayMode; ProcessId=[int]$retry.Id } }
    $ready = Wait-YakuDevTools -Port $Port -TimeoutSeconds $WaitForReadySeconds
    return [pscustomobject]@{ Ready=[bool]$ready; Started=$true; AlreadyReachable=$false; ProcessId=[int]$retry.Id; Spec=$spec }
}
