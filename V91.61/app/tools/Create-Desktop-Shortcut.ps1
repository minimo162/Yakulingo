<#
Create a desktop shortcut for the installed YakuLingo desktop shell.

共有フォルダの cmd ではなく、検証してローカルへ配置済みの C# shell を指す。
通常は初回チュートリアルから設定する。このスクリプトは管理用の補助手段。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
$target = Join-Path $appRoot 'desktop\YakuLingo.exe'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "DESKTOP_SHELL_MISSING: YakuLingo.exe が見つかりません: $target"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'YakuLingo.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = Split-Path -Parent $target
$shortcut.Description = 'YakuLingo'
$shortcut.Save()
Write-Host "Created shortcut: $shortcutPath" -ForegroundColor Green
Write-Host "Target          : $target"
