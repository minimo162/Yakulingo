<#
.SYNOPSIS
  Start the YakuLingo HTMX + PowerShell edition.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Start-YakuLingo.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Start-YakuLingo.ps1 -UseMockTranslator
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$UseMockTranslator
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-YakuRelativePathForStartup {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path
    )
    try {
        $base = (Resolve-Path -LiteralPath $Root).Path
        $full = (Resolve-Path -LiteralPath $Path).Path
        if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($base.Length).TrimStart([char[]]@('\','/'))
        }
    } catch {}
    return $Path
}

function Test-YakuUtf8BomForStartup {
    param([Parameter(Mandatory=$true)][string]$Root)

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1' -ErrorAction Stop)) {
        $targets.Add($file.FullName) | Out-Null
    }
    $promptDir = Join-Path $Root 'prompts'
    if (Test-Path -LiteralPath $promptDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $promptDir -Filter '*.txt' -ErrorAction Stop)) {
            $targets.Add($file.FullName) | Out-Null
        }
    }

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($targets.ToArray())) {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) {
            $violations.Add((Get-YakuRelativePathForStartup -Root $Root -Path $file)) | Out-Null
        }
    }
    if ($violations.Count -gt 0) {
        $list = ($violations.ToArray() -join "`n  - ")
        throw ("エンコーディングエラー: 次のファイルをUTF-8 BOM付きで保存してください（tools\Repair-YakuEncoding.ps1 で一括修復できます）:`n  - " + $list)
    }
}

function Test-YakuPowerShellSyntax {
    param([Parameter(Mandatory=$true)][string]$Root)

    $parserType = [type]'System.Management.Automation.Language.Parser'
    if ($null -eq $parserType) { return }

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1' -ErrorAction Stop | Sort-Object FullName)
    foreach ($item in $files) {
        $file = $item.FullName
        if (!(Test-Path -LiteralPath $file)) { throw "必要なファイルがありません: $file" }
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            $first = $errors[0]
            throw "PowerShell構文エラー: $file`n$($first.Message)`nLine $($first.Extent.StartLineNumber), Column $($first.Extent.StartColumnNumber)"
        }
    }
}

if ($UseMockTranslator) {
    $env:YAKULINGO_MOCK = '1'
} elseif ($env:YAKULINGO_MOCK -eq '1') {
    Remove-Item Env:YAKULINGO_MOCK -ErrorAction SilentlyContinue
}

Test-YakuUtf8BomForStartup -Root $root
Test-YakuPowerShellSyntax -Root $root

. (Join-Path $root 'src\JobObject.ps1')
$jobObjectEnabled = Initialize-YakuJobObject

$openBrowser = -not $NoBrowser.IsPresent

Write-Host "YakuLingo" -ForegroundColor Cyan
Write-Host "画面          : http://127.0.0.1:$Port/ （使用中なら次の空き番号を使います）"
if ($env:YAKULINGO_MOCK -eq '1') {
    Write-Host "翻訳          : テストモード（Copilotは呼び出しません）" -ForegroundColor Yellow
} else {
    Write-Host "翻訳          : Edge の M365 Copilot を使います。準備ができると翻訳ボタンが押せるようになります。"
}
Write-Host "終了          : この画面を閉じるか、Ctrl+C を押してください。" -ForegroundColor Yellow
Write-Host "アプリの場所  : $root" -ForegroundColor DarkGray
if ($jobObjectEnabled) { Write-Host "子プロセス    : この画面を閉じると一緒に終了します。" -ForegroundColor DarkGray }
Write-Host ''

& (Join-Path $root 'src\Server.ps1') -Port $Port -OpenBrowser:$openBrowser
