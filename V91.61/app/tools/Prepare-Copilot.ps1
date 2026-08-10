[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$StatusPath,
    [int]$TimeoutSeconds = 900
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
            try { $currentPage = Get-YakuCopilotPage -Port $Port -Url $Url } catch {
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


try {
    $settings = Read-YakuSettings -Root $script:YakuRoot
    $port = Get-YakuCdpPort -Settings $settings
    $copilotUrl = Get-YakuCopilotUrl -Settings $settings
    $timeout = [Math]::Max(60, $TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($timeout)
    $freshPrepared = $false
    $lastLog = [datetime]'2000-01-01'

    $null = Write-YakuWarmupStatus -Mode 'starting' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Edgeを起動して、Microsoft 365 Copilotを開いています。' -Ready $false
    Write-YakuEdgeLaunchLog "Copilot warmup started. port=$port timeout=$timeout" 'INFO'

    # W2: fire Edge before loading the large Copilot automation module so the
    # browser startup and SMB-backed dot-source happen in parallel.
    $earlyLaunchSw = [System.Diagnostics.Stopwatch]::StartNew()
    $earlyLaunch = Start-YakuEdgeLaunch -Port $port -DisplayMode ([string]$settings.browser_display_mode) -Url $copilotUrl -WindowSize ([string]$settings.edge_window_size) -NoWait
    $earlyLaunchSw.Stop()

    $moduleLoadSw = [System.Diagnostics.Stopwatch]::StartNew()
    . (Join-Path $script:YakuRoot 'src\CopilotClient.ps1')
    $moduleLoadSw.Stop()
    Write-YakuLog "Copilot warmup startup timings. early-edge-launch elapsedMs=$($earlyLaunchSw.ElapsedMilliseconds) copilot-module-load elapsedMs=$($moduleLoadSw.ElapsedMilliseconds) edgeStarted=$([bool]$earlyLaunch.Started) edgeAlreadyReachable=$([bool]$earlyLaunch.AlreadyReachable)" 'INFO'

    $port = Start-YakuCopilotEdge -Port $port -DisplayMode ([string]$settings.browser_display_mode) -Url $copilotUrl -WindowSize ([string]$settings.edge_window_size)
    $null = Write-YakuWarmupStatus -Mode 'loading' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Copilotの入力欄が開くのを待っています。あと1〜2分ほどかかります。' -Ready $false

    while ((Get-Date) -lt $deadline) {
        try {
            $page = Get-YakuCopilotPage -Port $port -Url $copilotUrl
            $state = Get-YakuCopilotState -Page $page -TimeoutSeconds 6
            $url = ConvertTo-YakuSafeString -Value $state.url
            $title = ConvertTo-YakuSafeString -Value $state.title

            if ($state.inputReady -eq $true) {
                if (-not $freshPrepared) {
                    $freshPrepared = $true
                    $selectedTargetId = ConvertTo-YakuSafeString -Value (Get-YakuObjectPropertyValue -Object $page -Name 'id' -Default '')
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
                        if (Write-YakuWarmupStatus -Mode 'ready' -Label '使えます' -Class 'ok' -Detail $freshAfterUrl -Ready $true) {
                            Write-YakuLog "Copilot warmup ready from fresh-chat after state. url=$freshAfterUrl title=$freshAfterTitle" 'INFO'
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

                if (Write-YakuWarmupStatus -Mode 'ready' -Label '使えます' -Class 'ok' -Detail $url -Ready $true) {
                    Write-YakuLog "Copilot warmup ready. url=$url title=$title" 'INFO'
                    exit 0
                }
                Write-YakuLog 'Ready status write failed; staying in polling loop to retry.' 'WARN'
                Start-Sleep -Milliseconds 1200
                continue
            }

            if ($state.loginDetected -eq $true) {
                $null = Write-YakuWarmupStatus -Mode 'login' -Label 'サインインが必要です' -Class 'warn' -Detail '別に開いたEdgeの画面で、Microsoft 365 Copilotにサインインしてください。サインインが済むと、この表示は自動で「使えます」に変わります。' -Ready $false
            } elseif ($state.generating -eq $true) {
                $null = Write-YakuWarmupStatus -Mode 'busy' -Label 'Copilotの返事を待っています' -Class 'warn' -Detail 'Copilotが前の回答を書き終えるのを待っています。そのままお待ちください。' -Ready $false
            } else {
                $null = Write-YakuWarmupStatus -Mode 'loading' -Label 'Copilotを準備しています' -Class 'warn' -Detail 'Copilotの入力欄が開くのを待っています。あと1〜2分ほどかかります。' -Ready $false
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
