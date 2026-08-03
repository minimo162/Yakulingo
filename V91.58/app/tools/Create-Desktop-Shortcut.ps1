<#
Create a desktop shortcut for YakuLingo.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
$packageRoot = Split-Path -Parent $appRoot
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'YakuLingo.lnk'
$target = Join-Path $packageRoot 'YakuLingo起動.vbs'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $packageRoot
$shortcut.Description = 'Start YakuLingo HTMX + PowerShell edition'
$shortcut.Save()
Write-Host "Created shortcut: $shortcutPath" -ForegroundColor Green
