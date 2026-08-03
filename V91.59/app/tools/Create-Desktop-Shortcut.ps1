<#
Create a desktop shortcut for YakuLingo.

既定では共有ルートの YakuLingo起動.cmd を指す。bootstrap 経由で起動した場合は
YAKULINGO_SHARED_ROOT から共有ルートを自動判別する。
#>
[CmdletBinding()]
param([string]$SharedRoot = '')
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
$packageRoot = Split-Path -Parent $appRoot

if ([string]::IsNullOrWhiteSpace($SharedRoot)) { $SharedRoot = [string]$env:YAKULINGO_SHARED_ROOT }
if ([string]::IsNullOrWhiteSpace($SharedRoot)) { $SharedRoot = $packageRoot }

$target = Join-Path $SharedRoot 'YakuLingo起動.cmd'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    $fallback = Join-Path $packageRoot 'YakuLingo起動.cmd'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { $target = $fallback }
    else { throw "LAUNCHER_NOT_FOUND: YakuLingo起動.cmd が見つかりません: $SharedRoot" }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'YakuLingo.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
# 共有フォルダを作業フォルダにすると cmd.exe が UNC パスの警告を出すため、
# ローカルのパスを作業フォルダにする。起動処理は絶対パスだけを使う。
$shortcut.WorkingDirectory = [Environment]::GetFolderPath('LocalApplicationData')
$shortcut.Description = 'Start YakuLingo HTMX + PowerShell edition'
$shortcut.Save()
Write-Host "Created shortcut: $shortcutPath" -ForegroundColor Green
Write-Host "Target          : $target"
