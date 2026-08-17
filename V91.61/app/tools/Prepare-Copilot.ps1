[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$StatusPath,
    [int]$TimeoutSeconds = 900,
    [int]$ParentProcessId = 0,
    [string]$ParentStartedUtc = '',
    [int]$MonitorIntervalSeconds = 20
)

$ErrorActionPreference = 'Stop'
$script:YakuRoot = [System.IO.Path]::GetFullPath($Root)

. (Join-Path $script:YakuRoot 'src\Paths.ps1')
. (Join-Path $script:YakuRoot 'src\Runtime.ps1')
. (Join-Path $script:YakuRoot 'src\Settings.ps1')
. (Join-Path $script:YakuRoot 'src\EdgeLaunch.ps1')

function Write-YakuWarmupStatus {
    param(
        [Parameter(Mandatory=$true)][string]$Mode,
        [Parameter(Mandatory=$true)][string]$Label,
        [string]$Class = 'idle',
        [string]$Detail = '',
        [bool]$Ready = $false
    )
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
            $dir = Split-Path -Parent $StatusPath
            if (!(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $tmp = Join-Path $dir ("copilot-warmup.{0}.tmp" -f $PID)
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
            Move-Item -LiteralPath $tmp -Destination $StatusPath -Force
            return $true
        } catch {
            if ($attempt -eq 5) {
                try { Write-YakuLog "Warmup status write failed after $attempt attempts: $($_.Exception.Message)" 'WARN' } catch {}
                return $false
            }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
    return $false
}

function Invoke-YakuWarmupFreshChatWithRetry {
    param(
        [Parameter(Mandatory=$true)]$Page,
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][int]$Port
    )
    $currentPage = $Page
    $lastFresh = $null
    for ($attempt = 0; $attempt -le 2; $attempt++) {
        if ($attempt -gt 0) {
            Start-Sleep -Milliseconds 2000
            try {
                # A backgrounded Copilot tab can keep answering CDP pings while
                # its timers/requestAnimationFrame are suspended. Bring it to
                # the foreground before running the fresh-chat wait so the
                # first tab does not need a manual second-tab reopen.
                $currentPage = Get-YakuCopilotPage -Port $Port -Url $Url
                $currentPage = Restore-YakuCopilotTabVisibility -Page $currentPage
            } catch {
                $lastFresh = [pscustomobject]@{ ok=$false; error=$_.Exception.Message; contextDestroyed=$true }
                continue
            }
        }
        $fresh = Invoke-YakuCopilotFreshChat -Page $currentPage -Url $Url -SuppressContextDestroyedWarn
        $lastFresh = $fresh
        $ok = $false
        try { $ok = ($fresh.ok -eq $true) } catch { $ok = $false }
        if ($ok) {
            if ($attempt -gt 0) { Write-YakuLog "Copilot fresh chat retried after context destroyed. attempt=$attempt" 'INFO' }
            Write-YakuLog "Copilot warmup fresh chat result: $(ConvertTo-YakuCompactJson $fresh)" 'INFO'
            return $fresh
        }
        $err = ''
        try { $err = [string]$fresh.error } catch { $err = '' }
        if (-not (Test-YakuCdpContextDestroyedMessage -Message $err)) {
            Write-YakuLog "Copilot warmup fresh chat failed: $err" 'WARN'
            return $fresh
        }
    }
    $finalErr = ''
    try { $finalErr = [string]$lastFresh.error } catch { $finalErr = 'unknown error' }
    if ([string]::IsNullOrWhiteSpace($finalErr)) { $finalErr = 'unknown error' }
    Write-YakuLog "Copilot warmup fresh chat failed: $finalErr" 'WARN'
    return $lastFresh
}

function Watch-YakuCopilotReadiness {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$Url
    )

    if ($ParentProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ParentStartedUtc)) {
        Write-YakuLog 'Copilot readiness monitor was not started because the parent server identity was not supplied.' 'DEBUG'
        return
    }

    $interval = [Math]::Max(10, $MonitorIntervalSeconds)
    $lastMode = 'ready'
    Write-YakuLog "Copilot readiness monitor started. parentPid=$ParentProcessId intervalSeconds=$interval" 'INFO'
    while (Test-YakuProcessIdentity -Id $ParentProcessId -StartTimeUtc $ParentStartedUtc) {
        Start-Sleep -Seconds $interval
        if (-not (Test-YakuProcessIdentity -Id $ParentProcessId -StartTimeUtc $ParentStartedUtc)) { break }

        # CDP access is skipped while a translation is running. Even a read-only
        # second client can disturb a long Copilot interaction at the wrong time.
        try {
            $runtimePath = Join-Path (Get-YakuSubDir 'runtime') 'server.json'
            $runtime = Read-YakuJsonFile -Path $runtimePath
            if (-not $runtime -or -not $runtime.url) { continue }
            $instance = Invoke-RestMethod -UseBasicParsing -Uri (([string]$runtime.url).TrimEnd('/') + '/api/instance') -TimeoutSec 3
            if ([int]$instance.pid -ne $ParentProcessId -or
                -not [string]::Equals([string]$instance.process_started_at, $ParentStartedUtc, [System.StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            if ([bool]$instance.active_job_running) { continue }
        } catch {
            continue
        }

        try {
            $page = Get-YakuCopilotPage -Port $Port -Url $Url
            $state = Get-YakuCopilotState -Page $page -TimeoutSeconds 6
            if ($state.loginDetected -eq $true) {
                if ($lastMode -ne 'login') {
                    $null = Write-YakuWarmupStatus -Mode 'login' -Label 'Copilot：サインインが必要' -Class 'warn' -Detail 'YakuLingo画面の「Copilot画面を開く」を押し、Microsoft 365 Copilotにサインインしてください。サインインが済むとEdge画面は自動で隠れます。' -Ready $false
                    Write-YakuLog 'Copilot readiness monitor detected that sign-in is required.' 'WARN'
                    $lastMode = 'login'
                }
                continue
            }
            if ($state.inputReady -eq $true) {
                if ($lastMode -ne 'ready') {
                    $currentUrl = ConvertTo-YakuSafeString -Value $state.url
                    $null = Write-YakuWarmupStatus -Mode 'ready' -Label 'Copilot：準備完了' -Class 'ok' -Detail $currentUrl -Ready $true
                    $null = Show-YakuEdgeWindow -Mode hidden
                    Write-YakuLog 'Copilot sign-in completed; the dedicated Edge window was hidden again.' 'INFO'
                    $lastMode = 'ready'
                }
            }
        } catch {
            Write-YakuLog "Copilot readiness monitor check skipped. reason=$($_.Exception.Message)" 'DEBUG'
        }
    }
    Write-YakuLog 'Copilot readiness monitor stopped with its parent server.' 'INFO'
}


try {
    $settings = Read-YakuSettings -Root $script:YakuRoot
    $port = Get-YakuCdpPort -Settings $settings
    $copilotUrl = Get-YakuCopilotUrl -Settings $settings
    $timeout = [Math]::Max(60, $TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($timeout)
    $freshPrepared = $false
    $lastLog = [datetime]'2000-01-01'

    # 準備ができたと出したあとに、もう一度だけ余ったタブを閉じる。
    #
    # 2026-08-12 実測: 起動のたびに窓のタブが1枚ずつ増えていた（Copilotの会話 ×2 と
    # 「新しいタブ」）。片付けは入力欄が出た時点で1回だけ走るが、Edge を落として
    # 開き直したときの「前回のタブの復元」はそれより遅れて現れる。片付けの時点では
    # まだ無いので、取り逃がしていた（ログの CDP targets found: 1 がその瞬間）。
    # 表示はもう「Copilot：準備完了」なので、ここで数秒待っても待たされる人はいない。
    $tidyLate = {
        param([int]$Port, [string]$KeepTargetId)
        if ([string]::IsNullOrWhiteSpace($KeepTargetId)) { return }
        Start-Sleep -Seconds 3
        try { Close-YakuSurplusCopilotTargets -Port $Port -KeepTargetId $KeepTargetId } catch {
            Write-YakuLog "Late surplus tab cleanup failed; continuing. error=$($_.Exception.Message)" 'WARN'
        }
    }
    $keepTargetId = ''

    $null = Write-YakuWarmupStatus -Mode 'starting' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Edgeを起動して、Microsoft 365 Copilotを開いています。' -Ready $false
    Write-YakuEdgeLaunchLog "Copilot warmup started. port=$port timeout=$timeout" 'INFO'

    # W2: fire Edge before loading the large Copilot automation module so the
    # browser startup and SMB-backed dot-source happen in parallel.
    #
    # この先行起動が使うポートは、あとで Start-YakuCopilotEdge が選ぶポートと
    # 一致していなければならない。一致しないと、先に出した窓が「古いプロセス」
    # として消され、別ポートで開き直される。利用者には「Edgeが出て、消えて、
    # また出る」と見える。
    #
    # Start-YakuCopilotEdge は Get-YakuCdpPortCandidates を通し、前回使った
    # ポート（runtime\cdp-port.json）を最優先する。設定値ではない。一度でも
    # 別ポートへ切り替わると、キャッシュがそれを保持し続けるため、以後は毎回
    # 「設定値で起動 → 消す → キャッシュのポートで起動」を繰り返す。
    # 2026-08-11 に実測（設定 9433、キャッシュ 9434、毎回2回起動していた）。
    #
    # CopilotClient はまだ読み込んでいないので、同じ規則をここで最小限なぞる。
    $earlyLaunchSw = [System.Diagnostics.Stopwatch]::StartNew()
    $earlyPort = $port
    try {
        $cachePath = Join-Path (Get-YakuSubDir 'runtime') 'cdp-port.json'
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cachedPort = [int]$cache.port
            $expectedProfile = [System.IO.Path]::GetFullPath((Join-Path (Get-YakuDataDir) 'edge-profile'))
            if ($cachedPort -ge 1024 -and $cachedPort -le 65535 -and
                [string]::Equals([string]$cache.userDataDir, $expectedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
                $earlyPort = $cachedPort
            }
        }
    } catch { $earlyPort = $port }
    if ($earlyPort -ne $port) { Write-YakuEdgeLaunchLog "Speculative Edge launch follows the cached port. configured=$port cached=$earlyPort" 'INFO' }
    $earlyLaunch = Start-YakuEdgeLaunch -Port $earlyPort -DisplayMode 'background' -Url $copilotUrl -WindowSize ([string]$settings.edge_window_size) -NoWait
    $earlyLaunchSw.Stop()

    $moduleLoadSw = [System.Diagnostics.Stopwatch]::StartNew()
    . (Join-Path $script:YakuRoot 'src\CopilotClient.ps1')
    $moduleLoadSw.Stop()
    Write-YakuLog "Copilot warmup startup timings. early-edge-launch elapsedMs=$($earlyLaunchSw.ElapsedMilliseconds) copilot-module-load elapsedMs=$($moduleLoadSw.ElapsedMilliseconds) edgeStarted=$([bool]$earlyLaunch.Started) edgeAlreadyReachable=$([bool]$earlyLaunch.AlreadyReachable)" 'INFO'

    $port = Start-YakuCopilotEdge -Port $earlyPort -DisplayMode ([string]$settings.browser_display_mode) -Url $copilotUrl -WindowSize ([string]$settings.edge_window_size)
    $null = Write-YakuWarmupStatus -Mode 'loading' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Copilotの入力欄が開くのを待っています。ふつうは数秒〜十数秒です。' -Ready $false

    while ((Get-Date) -lt $deadline) {
        try {
            $page = Get-YakuCopilotPage -Port $port -Url $copilotUrl
            $page = Restore-YakuCopilotTabVisibility -Page $page
            $state = Get-YakuCopilotState -Page $page -TimeoutSeconds 6
            $url = ConvertTo-YakuSafeString -Value $state.url
            $title = ConvertTo-YakuSafeString -Value $state.title

            if ($state.inputReady -eq $true) {
                if (-not $freshPrepared) {
                    $freshPrepared = $true
                    $selectedTargetId = ConvertTo-YakuSafeString -Value (Get-YakuObjectPropertyValue -Object $page -Name 'id' -Default '')
                    $keepTargetId = $selectedTargetId
                    if (-not [string]::IsNullOrWhiteSpace($selectedTargetId)) {
                        try { Close-YakuSurplusCopilotTargets -Port $port -KeepTargetId $selectedTargetId } catch {
                            Write-YakuLog "Surplus Copilot tab cleanup failed; continuing. error=$($_.Exception.Message)" 'WARN'
                        }
                    }
                    $null = Write-YakuWarmupStatus -Mode 'fresh-chat' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Copilotの新しい会話を開いています。' -Ready $false
                    $fresh = $null
                    try {
                        $fresh = Invoke-YakuWarmupFreshChatWithRetry -Page $page -Url $copilotUrl -Port $port
                    } catch {
                        Write-YakuLog "Copilot warmup fresh chat failed: $($_.Exception.Message)" 'WARN'
                    }
                    # W3: Invoke-YakuCopilotFreshChat already returns the final
                    # state. Accept it immediately when it proves a ready,
                    # non-conversation route; otherwise keep the old fallback.
                    $freshAfter = if ($fresh) { Get-YakuObjectPropertyValue -Object $fresh -Name 'after' -Default $null } else { $null }
                    $freshAfterReady = ($freshAfter -and (Get-YakuObjectPropertyValue -Object $freshAfter -Name 'inputReady' -Default $false) -eq $true)
                    $freshAfterUrl = if ($freshAfter) { ConvertTo-YakuSafeString -Value (Get-YakuObjectPropertyValue -Object $freshAfter -Name 'url' -Default '') } else { '' }
                    $freshOk = ($fresh -and (Get-YakuObjectPropertyValue -Object $fresh -Name 'ok' -Default $false) -eq $true)
                    if ($freshOk -and $freshAfterReady -and -not [string]::IsNullOrWhiteSpace($freshAfterUrl) -and $freshAfterUrl -notmatch '/(?:chat/)?conversation/') {
                        $freshAfterTitle = ConvertTo-YakuSafeString -Value (Get-YakuObjectPropertyValue -Object $freshAfter -Name 'title' -Default '')
                        if (Write-YakuWarmupStatus -Mode 'ready' -Label 'Copilot：準備完了' -Class 'ok' -Detail $freshAfterUrl -Ready $true) {
                            Write-YakuLog "Copilot warmup ready from fresh-chat after state. url=$freshAfterUrl title=$freshAfterTitle" 'INFO'
                            $null = Show-YakuEdgeWindow -Mode hidden
                            & $tidyLate $port $keepTargetId
                            Watch-YakuCopilotReadiness -Port $port -Url $copilotUrl
                            exit 0
                        }
                        Write-YakuLog 'Ready status write failed; staying in polling loop to retry.' 'WARN'
                        Start-Sleep -Milliseconds 1200
                        continue
                    }
                    Write-YakuLog 'Copilot warmup fresh-chat after state was insufficient; using polling fallback.' 'DEBUG'
                    Start-Sleep -Milliseconds 1200
                    continue
                }

                if (Write-YakuWarmupStatus -Mode 'ready' -Label 'Copilot：準備完了' -Class 'ok' -Detail $url -Ready $true) {
                    Write-YakuLog "Copilot warmup ready. url=$url title=$title" 'INFO'
                    $null = Show-YakuEdgeWindow -Mode hidden
                    if ([string]::IsNullOrWhiteSpace($keepTargetId)) {
                        $keepTargetId = ConvertTo-YakuSafeString -Value (Get-YakuObjectPropertyValue -Object $page -Name 'id' -Default '')
                    }
                    & $tidyLate $port $keepTargetId
                    Watch-YakuCopilotReadiness -Port $port -Url $copilotUrl
                    exit 0
                }
                Write-YakuLog 'Ready status write failed; staying in polling loop to retry.' 'WARN'
                Start-Sleep -Milliseconds 1200
                continue
            }

            if ($state.loginDetected -eq $true) {
                $null = Write-YakuWarmupStatus -Mode 'login' -Label 'Copilot：サインインが必要' -Class 'warn' -Detail 'YakuLingo画面の「Copilot画面を開く」を押し、Microsoft 365 Copilotにサインインしてください。サインインが済むとEdge画面は自動で隠れます。' -Ready $false
            } elseif ($state.generating -eq $true) {
                $null = Write-YakuWarmupStatus -Mode 'busy' -Label 'Copilotの返事を待っています' -Class 'warn' -Detail 'Copilotが前の回答を書き終えるのを待っています。そのままお待ちください。' -Ready $false
            } else {
                $null = Write-YakuWarmupStatus -Mode 'loading' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Copilotの入力欄が開くのを待っています。ふつうは数秒〜十数秒です。' -Ready $false
            }

            if (((Get-Date) - $lastLog).TotalSeconds -ge 8) {
                Write-YakuLog "Copilot warmup polling. $(Get-YakuCopilotStateSummary -State $state)" 'DEBUG'
                $lastLog = Get-Date
            }
        } catch {
            $null = Write-YakuWarmupStatus -Mode 'loading' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Copilotの画面を読み込んでいます。そのままお待ちください。' -Ready $false
            if (((Get-Date) - $lastLog).TotalSeconds -ge 8) {
                Write-YakuLog "Copilot warmup polling error: $($_.Exception.Message)" 'DEBUG'
                $lastLog = Get-Date
            }
        }
        Start-Sleep -Milliseconds 1200
    }

    $null = Write-YakuWarmupStatus -Mode 'timeout' -Label '準備が終わりません' -Class 'warn' -Detail "Copilotの準備が $([int]($timeout/60)) 分たっても終わりませんでした。EdgeのCopilot画面が開いていれば、ログインが済んでいるかご確認ください。ログイン済みなら、いったんアプリを終了して開き直してください。" -Ready $false
    Write-YakuLog "Copilot warmup timeout after $timeout seconds." 'WARN'
    exit 2
} catch {
    $null = Write-YakuWarmupStatus -Mode 'error' -Label 'Copilotを準備できませんでした' -Class 'warn' -Detail ("アプリを終了して開き直してください。それでも直らない場合は、記録をご確認ください。（内部の記録: " + $_.Exception.Message + "）") -Ready $false
    try { Write-YakuLog "Copilot warmup exception: $($_.Exception.ToString())" 'ERROR' } catch {}
    exit 1
}
