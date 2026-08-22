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
        [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowTextLength(IntPtr hWnd);
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
            # 記録ファイル頼みにしない（D2-7）。SW_HIDE した窓の記録が、後続の
            # kill失敗やプロセス再起動で失われても、いま実際に存在する専用Edge
            # プロセス（$pids、プロファイルのコマンドラインで絞っているので
            # 利用者ふだんの Edge には触れない）の最上位ウィンドウを直接数え直し、
            # 見つかった分を前面へ戻す。記録は「参考」に留める。
            # 補足(D2-7): タイトル長0の窓（GPU/utilityプロセス等の非表示ヘルパー窓）
            # まで対象に含めないよう、タイトルが付いている窓に絞る。
            foreach ($window in @([YakuLingo.EdgeWindowApi]::FindTopLevelWindows($pids))) {
                if ($window -eq [IntPtr]::Zero) { continue }
                if ([YakuLingo.EdgeWindowApi]::GetWindowTextLength($window) -le 0) { continue }
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

function Get-YakuCopilotEdgeProfileProcesses {
    param([Parameter(Mandatory=$true)][string]$UserDataDir)
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and ($_.CommandLine.IndexOf($UserDataDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        })
    } catch { return @() }
}

function Stop-YakuCopilotEdgeProfile {
    <#
      戻り値は [pscustomobject]@{ Stopped=[int]; Survivors=[int[]] }。
      Stopped>0 の判定にしか使わない既存の呼び出し元は $null= で捨てているので、
      戻り値の形を変えても壊れない（EdgeLaunch.ps1 の1箇所だけが Stopped を見る）。
    #>
    param([Parameter(Mandatory=$true)][string]$UserDataDir)
    try { if (Get-Command Clear-YakuCdpSocketCache -ErrorAction SilentlyContinue) { $null = Clear-YakuCdpSocketCache } } catch {}
    try { $script:YakuCdpOwnershipCache = $null } catch {}
    try { $script:YakuCopilotTargetCache = $null } catch {}
    try { Remove-YakuCdpOwnershipFileCache } catch {}
    try {
        $targetCachePath = Join-Path (Get-YakuSubDir 'runtime') 'cdp-copilot-target.json'
        if (Test-Path -LiteralPath $targetCachePath -PathType Leaf) { Remove-Item -LiteralPath $targetCachePath -Force -ErrorAction SilentlyContinue }
    } catch {}
    $stopped = 0
    $survivors = @()
    try {
        if ($env:OS -and $env:OS -notlike '*Windows*') { return [pscustomobject]@{ Stopped = 0; Survivors = @() } }
        $matches = @(Get-YakuCopilotEdgeProfileProcesses -UserDataDir $UserDataDir)
        foreach ($proc in $matches) {
            try {
                Write-YakuEdgeLaunchLog "Stopping stale YakuLingo Edge process. pid=$($proc.ProcessId)" 'INFO'
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                $stopped++
            } catch {}
        }
        if ($matches.Count -gt 0) {
            # kill を投げただけで消えたとみなさない（D2-3）。実際に消えたかを
            # 再列挙で確かめてから先へ進む。生き残りは呼び出し元へPID付きで返す。
            $deadline = (Get-Date).AddMilliseconds(1500)
            do {
                Start-Sleep -Milliseconds 150
                $survivors = @(Get-YakuCopilotEdgeProfileProcesses -UserDataDir $UserDataDir)
            } while ($survivors.Count -gt 0 -and (Get-Date) -lt $deadline)
        }
    } catch {
        Write-YakuEdgeLaunchLog "Stop-YakuCopilotEdgeProfile failed: $($_.Exception.Message)" 'DEBUG'
    }
    if ($survivors.Count -gt 0) {
        $detail = (($survivors | ForEach-Object { "pid=$($_.ProcessId)" }) -join ', ')
        Write-YakuEdgeLaunchLog "Edge processes for this profile could not be stopped. survivors=$detail" 'WARN'
    } else {
        # 隠した窓の記録は、当該プロセスが実際に消えたと確認できてから捨てる。
        # kill が失敗した場合は記録を残し、次回 foreground 復元（FindTopLevelWindows）
        # がその生存プロセスの窓を拾えるようにする（D2-7）。
        try { Remove-Item -LiteralPath (Get-YakuEdgeHiddenWindowsPath) -Force -ErrorAction SilentlyContinue } catch {}
    }
    return [pscustomobject]@{ Stopped = [int]$stopped; Survivors = @($survivors | ForEach-Object { [int]$_.ProcessId }) }
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
    # R2-4: D2-9の粘り（Wait-YakuDevTools 3秒）をここへ入れると、誰もEdgeを
    # 掴んでいない通常のコールド起動（従来 ~3ms）まで毎回3秒待つことになる
    # （実測+6.2秒の逆行）。ここは速い1発の判定に戻す。D2-9の本旨（「殺す」判断は
    # 「起こす」判断より慎重に）は、実際にプロファイル保持プロセスを殺す直前
    # （下のMutex内、$hasAnyEdge のとき）にだけ粘りを挿入して満たす。
    $alreadyReachable = $false
    try { $null = Get-YakuDevToolsVersion -Port $Port -TimeoutSec 1; $alreadyReachable = $true } catch { $alreadyReachable = $false }
    if ($alreadyReachable) {
        return [pscustomobject]@{ Ready=$true; Started=$false; AlreadyReachable=$true; ProcessId=0; Spec=$spec }
    }

    $inProgress = $script:YakuEdgeLaunchInProgress
    # 「進行中」を無期限に信じない（D2-6）。前回の起動試行が実際には終わって
    # いるのに、この変数だけが残ると、次の呼び出しが「誰かが起動中」と誤解して
    # 無駄な30秒待ちを毎回払う。起動には長くても数十秒あれば決着するはずなので、
    # 35秒より古い記録は無視する。
    $inProgressFresh = $inProgress -and (((Get-Date) - [datetime]$inProgress.StartedAt).TotalSeconds -lt 35)
    if ($inProgressFresh -and [int]$inProgress.Port -eq $Port -and
        [string]::Equals([string]$inProgress.UserDataDir, [string]$spec.UserDataDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($NoWait) { return [pscustomobject]@{ Ready=$false; Started=$false; AlreadyReachable=$false; ProcessId=[int]$inProgress.ProcessId; Spec=$spec } }
        if (Wait-YakuDevTools -Port $Port -TimeoutSeconds $WaitForReadySeconds) {
            return [pscustomobject]@{ Ready=$true; Started=$false; AlreadyReachable=$false; ProcessId=[int]$inProgress.ProcessId; Spec=$spec }
        }
    }

    # D2-6: 起動・停止をプロセスをまたいで排他する。Prepare-Copilot.ps1・
    # Server.ps1（/api/copilot/window）・CopilotClient.ps1（毎プロンプト）の
    # 3経路が別プロセス/ランスペースから同じ専用Edgeプロファイルを無断で
    # 殺し合っていた。名前付き Mutex は他の用途でも同じ書き方をしている
    # （EdgeLaunch.ps1 の Local\YakuLingo-LogWrite、Server.ps1 の単一インスタンス、
    # Start-YakuLingoApp.ps1 のランチャー排他）。
    $edgeMutex = New-Object System.Threading.Mutex($false, 'Local\YakuLingo-EdgeLaunch')
    $edgeLocked = $false
    try {
        try { $edgeLocked = $edgeMutex.WaitOne(60000) }
        catch [System.Threading.AbandonedMutexException] { $edgeLocked = $true }
        if (-not $edgeLocked) {
            throw 'EDGE_LAUNCH_BUSY: Edgeの起動・停止が混み合っています。少し待ってからもう一度お試しください。'
        }

        # 待っている間に別の呼び出しが起動を終えているかもしれない。取り直す
        # （ここも速い1発でよい。R2-4）。
        $mutexRecheck = $false
        try { $null = Get-YakuDevToolsVersion -Port $Port -TimeoutSec 1; $mutexRecheck = $true } catch { $mutexRecheck = $false }
        if ($mutexRecheck) {
            return [pscustomobject]@{ Ready=$true; Started=$false; AlreadyReachable=$true; ProcessId=0; Spec=$spec }
        }

        # W1: avoid the expensive WMI profile scan when no Edge process exists.
        # R2-4残り: $hasAnyEdge を「msedge.exeが1つでもあるか」（利用者ふだんの
        # Edgeも数える）で判定すると、Windows通常状態ではほぼ常に真になり、
        # 下の3秒粘りが専用プロファイルと無関係な起動でも毎回発生していた
        # （実測+3.1秒）。粘るべきは「専用プロファイルを実際に保持している
        # プロセスが実在するとき」だけ。ふだんのEdgeの有無とは無関係にする。
        $hasAnyEdge = (@(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue).Count -gt 0)
        if ($hasAnyEdge) {
            $holders = @(Get-YakuCopilotEdgeProfileProcesses -UserDataDir $spec.UserDataDir)
            if ($holders.Count -gt 0) {
                # D2-9の本旨はここ。既存の専用プロファイル保持者を実際に殺す直前
                # だけ、500ms間隔で3秒粘って確かめる（起こす側の粘りに合わせる）。
                # 誤って健全な専用Edgeを落とす方が、cold-startの数秒より実害が
                # 大きい。無関係な（ふだんの）Edgeしか無ければ、この粘りもWMIの
                # 空振り Stop も両方スキップする。
                if (Wait-YakuDevTools -Port $Port -TimeoutSeconds 3) {
                    return [pscustomobject]@{ Ready=$true; Started=$false; AlreadyReachable=$true; ProcessId=0; Spec=$spec }
                }
                $stopResult = Stop-YakuCopilotEdgeProfile -UserDataDir $spec.UserDataDir
                if ([int]$stopResult.Stopped -gt 0) { Start-Sleep -Milliseconds 700 }
            }
        }

        $null = Set-YakuEdgeProfileCleanExit -UserDataDir $spec.UserDataDir
        Write-YakuEdgeLaunchLog "Starting Edge. port=$Port display=$DisplayMode" 'INFO'
        $startWindowStyle = if ([string]::Equals($DisplayMode, 'foreground', [System.StringComparison]::OrdinalIgnoreCase)) { 'Normal' } else { 'Minimized' }
        $attempt = Start-YakuEdgeLaunchAttempt -Spec $spec -Port $Port -StartWindowStyle $startWindowStyle -DisplayMode $DisplayMode -NoWait:$NoWait -WaitForReadySeconds $WaitForReadySeconds
        # NoWaitは「起こすだけ起こして待たない」呼び出し。即死したときの
        # 片付け＋再試行はここでは行わない（ブロックしない、という約束を破らない
        # ため）。呼び出し元は後続の Wait-YakuDevTools 等で改めて確かめる。
        if ($NoWait) { return $attempt }
        if ($attempt.Ready) { return $attempt }

        if ($attempt.ImmediateExit) {
            Write-YakuEdgeLaunchLog 'Edge exited immediately; closing the same-profile holder and retrying once.' 'WARN'
        } else {
            Write-YakuEdgeLaunchLog 'Edge DevTools did not become reachable. Retrying after closing dedicated profile processes.' 'WARN'
        }
        $stopResult = Stop-YakuCopilotEdgeProfile -UserDataDir $spec.UserDataDir
        if (@($stopResult.Survivors).Count -gt 0) {
            $survivorDetail = (@($stopResult.Survivors) -join ', ')
            throw "EDGE_PROFILE_LOCKED: 専用Edge用プロファイルを使っているプロセスを終了できませんでした。pid=$survivorDetail タスクマネージャーで終了してから、もう一度お試しください。"
        }
        Start-Sleep -Seconds 2
        $null = Set-YakuEdgeProfileCleanExit -UserDataDir $spec.UserDataDir
        $retryAttempt = Start-YakuEdgeLaunchAttempt -Spec $spec -Port $Port -StartWindowStyle $startWindowStyle -DisplayMode $DisplayMode -NoWait:$NoWait -WaitForReadySeconds $WaitForReadySeconds
        return $retryAttempt
    } finally {
        if ($edgeLocked) { try { $edgeMutex.ReleaseMutex() } catch {} }
        try { $edgeMutex.Dispose() } catch {}
    }
}

function Start-YakuEdgeLaunchAttempt {
    <#
      1回ぶんの起動を行う。即死（同一プロファイルの二重起動が ProcessSingleton で
      弾かれた場合など）を検出し、その場合は30秒の無駄待ちをせず即座に知らせる
      （D2-3）。呼び出し元のリトライ（Stop→再起動）はそのまま使う。
    #>
    param(
        [Parameter(Mandatory=$true)]$Spec,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$StartWindowStyle,
        [Parameter(Mandatory=$true)][string]$DisplayMode,
        [switch]$NoWait,
        [int]$WaitForReadySeconds = 30
    )
    $process = Start-Process -FilePath $Spec.EdgePath -ArgumentList $Spec.Arguments -WindowStyle $StartWindowStyle -PassThru
    # -PassThru は Handle を読んでおかないと状態が安定して読めないことがある
    # （CLAUDE.md: Start-Process -PassThru の落とし穴）。
    try { $null = $process.Handle } catch {}
    $script:YakuEdgeLaunchInProgress = [pscustomobject]@{ Port=$Port; UserDataDir=$Spec.UserDataDir; ProcessId=[int]$process.Id; StartedAt=(Get-Date) }
    if ($StartWindowStyle -eq 'Minimized' -or $Spec.WindowSize.Enabled) { $script:YakuEdgeNeedsWindowNormalization = [pscustomobject]@{ Port=$Port; WindowSize=$Spec.WindowSize; DisplayMode=$DisplayMode; ProcessId=[int]$process.Id } }
    if ($NoWait) {
        return [pscustomobject]@{ Ready=$false; Started=$true; AlreadyReachable=$false; ImmediateExit=$false; ProcessId=[int]$process.Id; Spec=$Spec }
    }
    # R2-4: 固定 WaitForExit(2000) を先に払ってから Wait-YakuDevTools を始めると、
    # 健全な起動でも常に2秒の税を払う（実測+6.2秒の逆行の一因）。即死判定と
    # 起動判定を同じ250ms巡回にまとめる。即死は実測155-241msなので250ms巡回で
    # 十分に検出できる。
    $deadline = (Get-Date).AddSeconds($WaitForReadySeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            $exitCode = -1
            try { $exitCode = [int]$process.ExitCode } catch {}
            Write-YakuEdgeLaunchLog "Edge process exited immediately after launch (a same-profile instance is likely already running). exitcode=$exitCode port=$Port" 'WARN'
            return [pscustomobject]@{ Ready=$false; Started=$true; AlreadyReachable=$false; ImmediateExit=$true; ProcessId=0; Spec=$Spec }
        }
        try {
            $null = Get-YakuDevToolsVersion -Port $Port -TimeoutSec 2
            return [pscustomobject]@{ Ready=$true; Started=$true; AlreadyReachable=$false; ImmediateExit=$false; ProcessId=[int]$process.Id; Spec=$Spec }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    return [pscustomobject]@{ Ready=$false; Started=$true; AlreadyReachable=$false; ImmediateExit=$false; ProcessId=[int]$process.Id; Spec=$Spec }
}
