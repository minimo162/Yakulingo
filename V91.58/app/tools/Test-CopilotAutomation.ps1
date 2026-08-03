<#
.SYNOPSIS
  Sends a very small prompt to Copilot through the same automation path used by YakuLingo.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\Paths.ps1')
. (Join-Path $root 'src\Settings.ps1')
. (Join-Path $root 'src\EdgeLaunch.ps1')
. (Join-Path $root 'src\CopilotClient.ps1')
. (Join-Path $root 'src\Translation.ps1')

$settings = Read-YakuSettings -Root $root
Write-Host 'YakuLingo Copilot automation test' -ForegroundColor Cyan
Write-Host 'Copilotへ短いテスト文を送信します。'
Write-Host ''
try {
    $port = Get-YakuCdpPort -Settings $settings
    $copilotUrl = Get-YakuCopilotUrl -Settings $settings
    $port = Start-YakuCopilotEdge -Port $port -DisplayMode ([string]$settings.browser_display_mode) -Url $copilotUrl -WindowSize ([string]$settings.edge_window_size)
    $page = Get-YakuCopilotPage -Port $port -Url $copilotUrl
    $ready = Wait-YakuCopilotInputReadyState -Page $page -TimeoutSeconds 60 -Label 'V83 send-button and voice-chat regression test' -Port $port -Url $copilotUrl
    if ((Get-YakuObjectPropertyValue -Object $ready -Name 'Ok' -Default $false) -ne $true) { throw 'V83_TEST_INPUT_NOT_READY' }
    $readyPage = Get-YakuObjectPropertyValue -Object $ready -Name 'Page' -Default $null
    if ($readyPage) { $page = $readyPage }
    $readyState = Get-YakuObjectPropertyValue -Object $ready -Name 'State' -Default $null
    $probe = 'YAKULINGO_V83_SEND_BUTTON_PROBE'
    $fillProbe = Invoke-YakuCopilotFillPrompt -Page $page -Prompt $probe -ReadyState $readyState
    if ((Get-YakuObjectPropertyValue -Object $fillProbe -Name 'ok' -Default $false) -ne $true) { throw 'V83_TEST_FILL_FAILED' }
    $normalState = Get-YakuCopilotState -Page $page -TimeoutSeconds 10
    if (-not (Get-YakuObjectPropertyValue -Object $normalState -Name 'sendButton' -Default $null)) { throw 'V83_TEST_REAL_SEND_BUTTON_NOT_FOUND_AFTER_FILL' }

    $dialogProbeBody = @'
const fake = document.createElement('div');
fake.id = 'yaku-v81-obf-dialog-test'; fake.setAttribute('role','dialog'); fake.className = 'fui-DialogSurface obf-YakuRegression';
fake.style.cssText = 'position:fixed;right:10px;bottom:10px;width:220px;height:120px;z-index:2147483647;background:white';
const fakeSend = document.createElement('button'); fakeSend.type = 'submit'; fakeSend.className = 'obf-DxTFormSubmitButton'; fakeSend.textContent = '送信'; fake.appendChild(fakeSend); document.body.appendChild(fake);
const fakeVoice = document.createElement('button'); fakeVoice.id = 'yaku-v83-voice-chat-test'; fakeVoice.type = 'submit'; fakeVoice.className = 'fai-SendButton'; fakeVoice.setAttribute('aria-label','新しいボイス チャットを開始します'); fakeVoice.textContent = 'ボイス チャット'; document.body.appendChild(fakeVoice);
const state = YakuCopilotDom.state();
const candidates = YakuCopilotDom.sendButtonCandidates();
return {
  selected:state.sendButton,
  fakeRejected:candidates.some(c => /obf-/.test(c.className || '') && c.rejected && (c.rejectReasons || []).some(r => r === 'obf-survey-control' || r === 'inside-non-chat-dialog')),
  voiceRejected:candidates.some(c => /ボイス チャット/.test(c.ariaLabel || c.label || '') && c.rejected && (c.rejectReasons || []).some(r => /^unverified-send-aria-label:/.test(r)))
};
'@
    $dialogProbe = Invoke-YakuCdpEval -Page $page -Expression (New-YakuCopilotDomExpression -Body $dialogProbeBody) -TimeoutSeconds 10
    if (-not (Get-YakuObjectPropertyValue -Object $dialogProbe -Name 'selected' -Default $null)) { throw 'V83_TEST_REAL_SEND_BUTTON_LOST_WITH_FAKE_CONTROLS' }
    $selectedClass = ConvertTo-YakuSafeString -Value (Get-YakuObjectPropertyValue -Object (Get-YakuObjectPropertyValue -Object $dialogProbe -Name 'selected' -Default $null) -Name 'className' -Default '')
    if ($selectedClass -match 'obf-' -or (Get-YakuObjectPropertyValue -Object $dialogProbe -Name 'fakeRejected' -Default $false) -ne $true) { throw 'V83_TEST_SURVEY_SEND_BUTTON_NOT_REJECTED' }
    if ((Get-YakuObjectPropertyValue -Object $dialogProbe -Name 'voiceRejected' -Default $false) -ne $true) { throw 'V83_TEST_VOICE_CHAT_BUTTON_NOT_REJECTED' }
    Write-Host 'OK: 本物の送信ボタンのみを検出し、疑似アンケートとボイスチャットのボタンを除外しました。' -ForegroundColor Green
    $null = Invoke-YakuCdpEval -Page $page -Expression (New-YakuAsyncJsExpression -Body "document.getElementById('yaku-v81-obf-dialog-test')?.remove(); document.getElementById('yaku-v83-voice-chat-test')?.remove(); return true;") -TimeoutSeconds 10
    $null = Clear-YakuCopilotInputVerified -Page $page

    $requestId = [guid]::NewGuid().ToString('N')
    $prompt = "Reply in this exact plain-text contract and add nothing else:`nFULL_TEXT:`nYAKULINGO_OK`nBRIEF_TEXT:`nYAKULINGO_OK`nYAKULINGO_END:$requestId"
    $reply = Invoke-YakuCopilotPrompt -Prompt $prompt -Settings $settings -PreserveEndMarker
    $parsed = @(Parse-YakuTextTranslationResponse -Raw $reply -Direction 'to_en' -RequestId $requestId)
    Write-Host '--- Copilot response ---' -ForegroundColor Green
    Write-Host $reply
    Write-Host '------------------------'
    if ($parsed.Count -eq 2 -and [string]$parsed[0].Translation -eq 'YAKULINGO_OK' -and [string]$parsed[1].Translation -eq 'YAKULINGO_OK') {
        Write-Host 'OK: 自動入力・送信・回答取得に成功しました。' -ForegroundColor Green
    } else {
        Write-Host '注意: 回答は取得できましたが、期待文字列と完全一致しませんでした。上の応答を確認してください。' -ForegroundColor Yellow
    }
} catch {
    $failure = $_
    try { $null = Invoke-YakuCdpEval -Page $page -Expression (New-YakuAsyncJsExpression -Body "document.getElementById('yaku-v81-obf-dialog-test')?.remove(); document.getElementById('yaku-v83-voice-chat-test')?.remove(); return true;") -TimeoutSeconds 5 } catch {}
    Write-Host 'NG: Copilot自動化テストに失敗しました。' -ForegroundColor Red
    Write-Host $failure.Exception.Message -ForegroundColor Red
    $log = Join-Path (Get-YakuSubDir 'logs') 'yakulingo.log'
    Write-Host "ログ: $log" -ForegroundColor Yellow
    throw $failure
}
pause
