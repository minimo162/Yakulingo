<#
Create a desktop shortcut for the installed YakuLingo launcher.

共有フォルダではなく、検証してローカルへ配置済みの起動CMDを指す。
通常は初回チュートリアルから設定する。このスクリプトは管理用の補助手段。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
$versionRoot = Split-Path -Parent $appRoot
$target = Join-Path $versionRoot 'YakuLingo起動.cmd'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "APP_LAUNCHER_MISSING: YakuLingo起動.cmd が見つかりません: $target"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'YakuLingo.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $versionRoot
$shortcut.Description = 'YakuLingo'
$shortcut.Save()
Write-Host "Created shortcut: $shortcutPath" -ForegroundColor Green
Write-Host "Target          : $target"
