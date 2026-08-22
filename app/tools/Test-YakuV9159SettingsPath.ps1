<#
.SYNOPSIS
  V91.59: 利用者設定がアプリフォルダではなくユーザープロファイルへ保存されることを検証する。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9159SettingsPath.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Failures = 0

function Assert-YakuSettingsPath {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1')) {
    . (Join-Path (Join-Path $root 'src') $name)
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('Yaku-approot-' + [guid]::NewGuid().ToString('N'))
$dataDir  = Join-Path ([System.IO.Path]::GetTempPath()) ('Yaku-data-' + [guid]::NewGuid().ToString('N'))
$previousDataDir = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = $dataDir
try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'config') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config\settings.template.json') -Destination (Join-Path $testRoot 'config\settings.template.json') -Force

    Write-Host 'CASE 1: 旧設定がない利用者'
    $path = Get-YakuUserSettingsPath
    Assert-YakuSettingsPath ($path.StartsWith($dataDir, [System.StringComparison]::OrdinalIgnoreCase)) '設定パスはユーザーデータディレクトリ配下'
    Assert-YakuSettingsPath (-not $path.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)) '設定パスはアプリフォルダ配下ではない'

    $saved = @(Save-YakuUserSettings -Root $testRoot -Form @{ request_timeout = 600 })
    Assert-YakuSettingsPath ($saved.Count -eq 1 -and [int]$saved[0].request_timeout -eq 600) '保存結果が単一の設定オブジェクトで返る'
    Assert-YakuSettingsPath (Test-Path -LiteralPath $path -PathType Leaf) 'ユーザーデータディレクトリへ書き込まれる'
    $appSideFiles = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File | Where-Object { $_.Name -like '*user_settings*' })
    Assert-YakuSettingsPath ($appSideFiles.Count -eq 0) 'アプリフォルダ側に設定ファイルを作らない'
    Assert-YakuSettingsPath ([int](Read-YakuSettings -Root $testRoot).request_timeout -eq 600) '再読込で保存値が復元される'

    Write-Host 'CASE 2: 旧設定からの一度きりの引き継ぎ'
    Remove-Item -LiteralPath $dataDir -Recurse -Force
    $legacy = Get-YakuLegacyUserSettingsPath -Root $testRoot
    [System.IO.File]::WriteAllText($legacy, '{"request_timeout":123,"max_chars_per_batch":1000,"copilot_model":"GPT 5.6 Think deeper,Opus,Think Deeper"}', (New-Object System.Text.UTF8Encoding($true)))

    $migrated = Read-YakuSettings -Root $testRoot
    Assert-YakuSettingsPath ([int]$migrated.request_timeout -eq 123) '旧設定の値が引き継がれる'
    Assert-YakuSettingsPath ([int]$migrated.max_chars_per_batch -eq 3000) '既定値移行(1000 -> 3000)も併せて適用される'
    Assert-YakuSettingsPath ([string]$migrated.copilot_model -eq '自動,Auto') '旧モデル既定値を、毎回切替不要の自動へ移行する'
    Assert-YakuSettingsPath (Test-Path -LiteralPath (Get-YakuUserSettingsPath) -PathType Leaf) '新パスへ複製される'
    $legacyAfter = Get-Content -LiteralPath $legacy -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-YakuSettingsPath ([int]$legacyAfter.max_chars_per_batch -eq 1000) '旧ファイルを書き換えない'
    Assert-YakuSettingsPath ([string]$legacyAfter.copilot_model -eq 'GPT 5.6 Think deeper,Opus,Think Deeper') '旧ファイルのモデル設定を書き換えない'
    Assert-YakuSettingsPath (Test-Path -LiteralPath $legacy -PathType Leaf) '旧ファイルを削除しない'

    Write-Host 'CASE 3: 引き継ぎ後は旧ファイルを参照しない'
    [System.IO.File]::WriteAllText($legacy, '{"request_timeout":999}', (New-Object System.Text.UTF8Encoding($true)))
    Assert-YakuSettingsPath ([int](Read-YakuSettings -Root $testRoot).request_timeout -eq 123) '2回目以降は新パスが優先される'

    Write-Host 'CASE 4: 利用者ごとに独立する'
    $otherDataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('Yaku-data-' + [guid]::NewGuid().ToString('N'))
    $env:YAKULINGO_DATA_DIR = $otherDataDir
    try {
        Assert-YakuSettingsPath ((Get-YakuUserSettingsPath) -ne $path) 'データディレクトリが違えば設定ファイルも別'
        $null = Save-YakuUserSettings -Root $testRoot -Form @{ request_timeout = 300 }
        $env:YAKULINGO_DATA_DIR = $dataDir
        Assert-YakuSettingsPath ([int](Read-YakuSettings -Root $testRoot).request_timeout -eq 123) '他利用者の保存が自分の設定を上書きしない'
    } finally {
        $env:YAKULINGO_DATA_DIR = $dataDir
        if (Test-Path -LiteralPath $otherDataDir) { Remove-Item -LiteralPath $otherDataDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    foreach ($dir in @($testRoot, $dataDir)) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($script:Failures -gt 0) {
    Write-Host "V91.59 settings path test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.59 settings path regression passed.' -ForegroundColor Green
