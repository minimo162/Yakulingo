<#
.SYNOPSIS
  Opens the dedicated YakuLingo Edge profile in the foreground for Microsoft 365 Copilot login.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$CopilotUrl = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\Paths.ps1')
. (Join-Path $root 'src\Settings.ps1')
. (Join-Path $root 'src\CopilotClient.ps1')

$settings = Read-YakuSettings -Root $root
if ($Port -le 0) { $Port = Get-YakuCdpPort -Settings $settings }
if ([string]::IsNullOrWhiteSpace($CopilotUrl)) { $CopilotUrl = Get-YakuCopilotUrl -Settings $settings }

Write-Host 'YakuLingo Copilot login helper' -ForegroundColor Cyan
Write-Host "Copilot URL: $CopilotUrl"
Write-Host "Edge CDP Port: $Port"
Write-Host ''
Write-Host '同じEdgeウィンドウでMicrosoft 365 Copilotにログインし、チャット入力欄が表示されるまで待ってください。' -ForegroundColor Yellow

$Port = Start-YakuCopilotEdge -Port $Port -DisplayMode foreground -Url $CopilotUrl -WindowSize ([string]$settings.edge_window_size) -ForceForeground
$page = Get-YakuCopilotPage -Port $Port -Url $CopilotUrl
Invoke-YakuCdpBringToFront -Page $page
Show-YakuEdgeWindow -Mode foreground

$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    try {
        $state = Get-YakuCopilotState -Page $page -TimeoutSeconds 10
        if ($state.inputReady -eq $true) {
            Write-Host ''
            Write-Host 'OK: Copilotの入力欄を検出しました。このEdge画面を閉じずに YakuLingo を起動してください。' -ForegroundColor Green
            Write-Host "URL: $($state.url)"
            pause
            exit 0
        }
        Write-Host "待機中: 入力欄未検出 / URL=$($state.url)"
    } catch {
        Write-Host "待機中: 状態確認に失敗しました: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 3
}

Write-Host ''
Write-Host '入力欄を検出できませんでした。Edge側でログイン・ポップアップ・利用規約などを完了してから、もう一度このファイルを実行してください。' -ForegroundColor Yellow
pause
