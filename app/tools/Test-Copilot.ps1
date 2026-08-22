<#
.SYNOPSIS
  Open and diagnose the Microsoft 365 Copilot automation profile.
#>
[CmdletBinding()]
param(
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:YakuRoot = $root

. (Join-Path $root 'src\Paths.ps1')
. (Join-Path $root 'src\Settings.ps1')
. (Join-Path $root 'src\CopilotClient.ps1')

$settings = Read-YakuSettings -Root $root
$port = Get-YakuCdpPort -Settings $settings
$url = Get-YakuCopilotUrl -Settings $settings

if ($Open) {
    $port = Start-YakuCopilotEdge -Port $port -DisplayMode 'foreground' -Url $url -WindowSize ([string]$settings.edge_window_size)
    $page = Get-YakuCopilotPage -Port $port -Url $url
    Invoke-YakuCdpBringToFront -Page $page
    Start-Sleep -Seconds 1
}

$diag = Get-YakuCopilotDiagnostics -Settings $settings
$diag | Format-List

Write-Host ''
if ($diag.InputReady) {
    Write-Host 'OK: Copilot入力欄を検出できました。YakuLingoから翻訳できます。' -ForegroundColor Green
} elseif ($diag.LoginDetected) {
    Write-Host 'ACTION: EdgeのCopilot画面でサインイン/認証を完了してから、もう一度診断してください。' -ForegroundColor Yellow
} elseif (-not $diag.DevToolsReachable) {
    Write-Host 'ACTION: -Open を付けて起動するか、YakuLingo画面の「Copilotを開く/ログイン」を押してください。' -ForegroundColor Yellow
} else {
    Write-Host 'ACTION: Copilot画面の読み込み完了を待ってから、もう一度診断してください。' -ForegroundColor Yellow
}
