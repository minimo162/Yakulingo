<#
Static regression tests for the V64 response watcher. The authoritative
accept/reject decision remains in Translation.ps1 and CatBatch.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Get-Content -LiteralPath (Join-Path $root 'src\CopilotClient.ps1') -Raw -Encoding UTF8
$runtimeSource = Get-Content -LiteralPath (Join-Path $root 'src\Runtime.ps1') -Raw -Encoding UTF8
$serverSource = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8
$translationSource = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
$fileTranslationSource = Get-Content -LiteralPath (Join-Path $root 'src\CatBatch.ps1') -Raw -Encoding UTF8
$buildId = (Get-Content -LiteralPath (Join-Path $root 'config\build.txt') -Raw -Encoding UTF8).Trim()
$freshGateStart = $source.IndexOf('$freshTimeout =')
$fillStart = $source.IndexOf('$fillResult = ConvertTo-YakuCdpResultObject -Value (Invoke-YakuCopilotFillPrompt')
$preFillGateSource = if ($freshGateStart -ge 0 -and $fillStart -gt $freshGateStart) { $source.Substring($freshGateStart, $fillStart - $freshGateStart) } else { '' }

function Assert-YakuWatcherSource {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "WATCHER ASSERTION FAILED: $Message" }
}

Assert-YakuWatcherSource -Condition $source.Contains("const requestId = String(baseline.requestId || '');") -Message 'watcher must receive the request ID'
Assert-YakuWatcherSource -Condition $source.Contains("new RegExp('YAKULINGO_END:' + requestId, 'i')") -Message 'watcher must wait for the full request-specific marker'
Assert-YakuWatcherSource -Condition $source.Contains('return idMarkerRe.test(t) && numberedItemRe.test(t);') -Message 'numbered watcher must require ID tags'
Assert-YakuWatcherSource -Condition $source.Contains("[regex]::Match(`$Prompt, 'YAKULINGO_END:([a-fA-F0-9]{32})')") -Message 'prompt request ID must be extracted before waiting'
Assert-YakuWatcherSource -Condition $source.Contains('if ($RequestId -and -not $PreserveEndMarker)') -Message 'preserved responses must retain the request ID'
Assert-YakuWatcherSource -Condition ($source -notmatch 'Accept numbered output without \[\[ID:n\]\]') -Message 'legacy ID-less acceptance must be absent'
Assert-YakuWatcherSource -Condition $source.Contains('const seenCandidatesThisRound = new Set();') -Message 'duplicate DOM sources must be deduplicated within each watcher poll'
Assert-YakuWatcherSource -Condition $source.Contains('if (seenCandidatesThisRound.has(candidate)) continue;') -Message 'stability must not advance twice in one watcher poll'
Assert-YakuWatcherSource -Condition $source.Contains('const state = (includeResponseText = false) =>') -Message 'normal Copilot state polling must use the lightweight response path'
Assert-YakuWatcherSource -Condition $source.Contains('const responseElementCount = () =>') -Message 'lightweight state polling must count responses without cloning all answer DOM'
Assert-YakuWatcherSource -Condition $source.Contains('if (Test-YakuFullTextDiagnosticsEnabled) {') -Message 'full input snapshots must be gated by the diagnostic setting'
Assert-YakuWatcherSource -Condition $source.Contains("reason:'already-fresh'") -Message 'an already empty fresh chat must not be clicked again'
Assert-YakuWatcherSource -Condition ($source.Contains('FRESH_MAIN_TEXT_MAX = 4000') -and $source.Contains('fresh-state-not-confirmed')) -Message 'stale main content must prevent a false already-fresh result'
Assert-YakuWatcherSource -Condition (-not $source.Contains('s.inputReady && s.sendButtonReady && (s.inputTextLength|0) === 0') -and -not $source.Contains('initialState.inputReady && initialState.sendButtonReady &&')) -Message 'empty fresh chat must be accepted while the send button is replaced by voice chat'
Assert-YakuWatcherSource -Condition (-not $source.Contains('!!after.inputReady && !!(domState && domState.sendButtonReady)')) -Message 'final fresh-chat verification must not require a send button in an empty composer'
Assert-YakuWatcherSource -Condition ($preFillGateSource.Length -gt 0 -and -not $preFillGateSource.Contains('$stateSendReady') -and -not $preFillGateSource.Contains("-Name 'sendButtonReady' -Default `$false) -eq `$true")) -Message 'ready, fresh-chat, and model paths before fill must not require sendButtonReady'
Assert-YakuWatcherSource -Condition ($source.Contains('function Test-YakuCopilotFreshReadyState') -and $source.Contains('voiceChatButtonReady') -and $source.Contains('composerReady: !!input && (!!sendInfo || !!voiceChatInfo)')) -Message 'empty-composer acceptance and send-or-voice diagnostics must remain explicit'
Assert-YakuWatcherSource -Condition ($source.Contains("unverified-send-aria-label:") -and $source.Contains('/^(送信|Send)$/i.test(sendAriaLabel)')) -Message 'voice-chat and other non-send controls must be rejected immediately before clicking'
Assert-YakuWatcherSource -Condition ($source.Contains('switcherWaitedMs += 500') -and $source.Contains('i < 10 && !btn')) -Message 'model selection must wait up to five seconds after navigation'
Assert-YakuWatcherSource -Condition $source.Contains('const thinkingInfo = () =>') -Message 'thinking/status text must count as first Copilot activity'
Assert-YakuWatcherSource -Condition ($source.Contains('[data-testid="loading-message"]') -and $source.Contains('情報を整理')) -Message 'current Copilot loading message must count as thinking activity'
Assert-YakuWatcherSource -Condition ($source.Contains('|| busy)') -and $source.Contains("kind:'stop-button-visible'")) -Message 'a visible stop button must count as first Copilot activity'
Assert-YakuWatcherSource -Condition $source.Contains('[int]$FirstActivityTimeoutMs = 10000') -Message 'silent-start detection must retain the ten-second default and remain configurable'
Assert-YakuWatcherSource -Condition $source.Contains('$silentConfirmMs = 2000') -Message 'silent-start detection must use a two-second confirmation window'
Assert-YakuWatcherSource -Condition $source.Contains('Invoke-YakuCopilotSilentStartConfirmation') -Message 'silent start must be confirmed before stop is attempted'
Assert-YakuWatcherSource -Condition ($source.Contains("`$silentReason = if (`$misdetected) { 'silent-start-timeout-but-generating' } else { 'silent-start-timeout' }") -and $source.Contains('reason = $silentReason')) -Message 'confirmed silence must return the dedicated watcher reason'
Assert-YakuWatcherSource -Condition ($source.Contains('silent-start-timeout-but-generating') -and $source.Contains('misdetected:true')) -Message 'a stop-button race must be logged as a misdetected silent start'
Assert-YakuWatcherSource -Condition $source.Contains("errorCode = 'COPILOT_SILENT_START_TIMEOUT'") -Message 'confirmed silence must return a retryable error code'
Assert-YakuWatcherSource -Condition $source.Contains('stopResult = await YakuCopilotDom.clickStopButton();') -Message 'confirmed silence must stop Copilot before retry'
Assert-YakuWatcherSource -Condition $source.Contains('[int]$TimeoutMs = 6000') -Message 'send establishment must allow normal Copilot UI latency'
Assert-YakuWatcherSource -Condition $source.Contains('sendButtonMissingSamples >= 3') -Message 'send-button transition must be stable across multiple polls'
Assert-YakuWatcherSource -Condition $source.Contains("reason = 'full-prompt-still-present-and-send-button-ready'") -Message 'send retry must require the complete prompt and a verified send button'
Assert-YakuWatcherSource -Condition ($source.Contains('synthetic-click-send-button') -and $source.Contains('native-mouse-click-send-button-stage2')) -Message 'synthetic and trusted native send stages must be diagnosable'
Assert-YakuWatcherSource -Condition $source.Contains('retryAttempted = [bool]$retryAttempted') -Message 'send result must expose whether a retry occurred'
Assert-YakuWatcherSource -Condition ($source.Contains('guarded-enter-send-stage3') -and $source.Contains('guarded-enter-inserted-newline-rolled-back')) -Message 'guarded Enter fallback must roll back an inserted newline'
Assert-YakuWatcherSource -Condition (-not [string]::IsNullOrWhiteSpace($buildId) -and $runtimeSource.Contains('config\build.txt') -and -not $runtimeSource.Contains("return 'V91.2-20260717'")) -Message 'build ID must come from config/build.txt'
Assert-YakuWatcherSource -Condition ($source.Contains("Add-Member -NotePropertyName ok -NotePropertyValue `$true -Force") -and $source.Contains("`$normalized['ok'] = `$true") -and $source.Contains("-Name 'ok' -Default `$true")) -Message 'successful state results without an ok property must normalize and remain trusted'
Assert-YakuWatcherSource -Condition ($source.Contains('\{translation for item') -and $source.Contains('Output format\s*:')) -Message 'current file-prompt placeholders must be rejected as prompt echoes'
Assert-YakuWatcherSource -Condition (-not $source.Contains("completedBy:'stable-not-busy'") -and -not $source.Contains("completedBy:'stopped-with-output'")) -Message 'incomplete stable/stopped output must not be accepted'
Assert-YakuWatcherSource -Condition ($serverSource.Contains('BUILD_ID_WARM_RUNSPACE_MISMATCH') -and $serverSource.Contains('build_id=$script:YakuBuildId')) -Message 'server and warm runspace build mismatch must be rejected'
Assert-YakuWatcherSource -Condition ($serverSource.Contains('[System.IO.FileShare]::ReadWrite') -and $serverSource.Contains('$script:YakuWarmupLastGood = $status') -and $serverSource.Contains('copilot-warmup.{0}.tmp')) -Message 'Copilot warmup status must use shared reads, last-known-good fallback, and atomic replacement'
Assert-YakuWatcherSource -Condition ($translationSource.Contains('Text response contract diagnostic saved.') -and $translationSource.Contains('Get-YakuTranslationAttemptErrorCode')) -Message 'text contract rejection must preserve its concrete reason and diagnostic response'
Assert-YakuWatcherSource -Condition ($fileTranslationSource.Contains("ContainsKey('OnBatchCompleted')") -and $serverSource.Contains('Save-YakuCatBatchCheckpoint')) -Message 'completed batch results must survive a later batch failure'

Write-Host 'V64/V67/V68/V71/V72/V73/V74/V75/V76/V77/V78/V79/V80/V81/V82/V83/V84/V85/V86/V87/V87.1/V88/V89/V90/V90.1/V90.2/V90.3/V90.4/V90.5/V90.6/V90.7/V90.8/V90.9/V90.9.1/V91/V91.1/V91.2 watcher, silent-start, send recovery, fresh-chat, window normalization, glossary audit scope, warmup status, and build identity tests passed.' -ForegroundColor Green
