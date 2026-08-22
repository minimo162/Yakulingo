<#
.SYNOPSIS
  Shows current Edge/CDP/Copilot readiness without sending a prompt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\Paths.ps1')
. (Join-Path $root 'src\Settings.ps1')
. (Join-Path $root 'src\CopilotClient.ps1')

$settings = Read-YakuSettings -Root $root
$diag = Get-YakuCopilotDiagnostics -Settings $settings
Write-Host 'YakuLingo Copilot diagnostics' -ForegroundColor Cyan
Write-Host "Port              : $($diag.Port)"
Write-Host "DevToolsReachable : $($diag.DevToolsReachable)"
Write-Host "Browser           : $($diag.Browser)"
Write-Host "PageUrl           : $($diag.PageUrl)"
Write-Host "Title             : $($diag.Title)"
Write-Host "LoginDetected     : $($diag.LoginDetected)"
Write-Host "InputReady        : $($diag.InputReady)"
Write-Host "InputSelector     : $($diag.InputSelector)"
Write-Host "InputTextLength   : $($diag.InputTextLength)"
Write-Host "ResponseCount     : $($diag.ResponseCount)"
Write-Host "Message           : $($diag.Message)"
Write-Host "LogPath           : $($diag.LogPath)"
Write-Host ''
if ($diag.InputReady) {
    Write-Host 'OK: Copilot自動化の前提条件は満たされています。' -ForegroundColor Green
} elseif ($diag.LoginDetected) {
    Write-Host 'ログインが必要です。YakuLingo画面の「Copilotを開く/ログイン」 を実行してください。' -ForegroundColor Yellow
} else {
    Write-Host 'YakuLingo画面の「Copilotを開く/ログイン」 を実行して、チャット入力欄が表示される状態にしてください。' -ForegroundColor Yellow
}
pause
