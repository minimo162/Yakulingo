<#
.SYNOPSIS
  Verifies YakuLingo PowerShell, prompt, web UI, and selected edited config/docs files are UTF-8 BOM and parse cleanly.

.DESCRIPTION
  Windows PowerShell 5.1 reads BOM-less .ps1 files as the system ANSI code page.
  This gate checks BOM bytes directly before AST parsing so UTF-8 Japanese literals
  cannot be silently misread on Japanese Windows environments.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = 'Stop'

function Get-YakuCheckRelativePath {
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

function Test-YakuUtf8BomBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$targets = New-Object System.Collections.Generic.List[object]
$seen = @{}

foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Filter '*.ps1' -ErrorAction Stop | Sort-Object FullName)) {
    if (-not $seen.ContainsKey($file.FullName)) {
        $seen[$file.FullName] = $true
        $targets.Add($file) | Out-Null
    }
}

$promptDir = Join-Path $rootPath 'prompts'
if (Test-Path -LiteralPath $promptDir -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $promptDir -Filter '*.txt' -ErrorAction Stop | Sort-Object FullName)) {
        if (-not $seen.ContainsKey($file.FullName)) {
            $seen[$file.FullName] = $true
            $targets.Add($file) | Out-Null
        }
    }
}

$wwwDir = Join-Path $rootPath 'www'
if (Test-Path -LiteralPath $wwwDir -PathType Container) {
    foreach ($pattern in @('*.html','*.css','*.js')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $wwwDir -Recurse -Filter $pattern -ErrorAction Stop | Sort-Object FullName)) {
            if (-not $seen.ContainsKey($file.FullName)) {
                $seen[$file.FullName] = $true
                $targets.Add($file) | Out-Null
            }
        }
    }
}
$extraBomTargets = @(
    'glossary.csv',
    'prompt_glossary.csv',
    'config\settings.template.json',
    'docs\UI_REDESIGN_V33.md',
    'docs\WRITEBACK_FIX_V34.md',
    'docs\MD_ESCAPE_FIX_V35.md'
)
foreach ($rel in $extraBomTargets) {
    $path = Join-Path $rootPath $rel
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $file = Get-Item -LiteralPath $path
        if (-not $seen.ContainsKey($file.FullName)) {
            $seen[$file.FullName] = $true
            $targets.Add($file) | Out-Null
        }
    }
}


$violations = New-Object System.Collections.Generic.List[string]
foreach ($file in @($targets.ToArray())) {
    $full = [string]$file.FullName
    if (-not (Test-YakuUtf8BomBytes -Path $full)) {
        $rel = Get-YakuCheckRelativePath -Root $rootPath -Path $full
        $violations.Add("BOM missing: $rel") | Out-Null
    }
}

$parserType = [type]'System.Management.Automation.Language.Parser'
if ($null -eq $parserType) {
    $violations.Add('AST parser not available: System.Management.Automation.Language.Parser') | Out-Null
} else {
    foreach ($file in @($targets.ToArray() | Where-Object { $_.Name -like '*.ps1' })) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            foreach ($err in @($errors)) {
                $rel = Get-YakuCheckRelativePath -Root $rootPath -Path $file.FullName
                $violations.Add(("Parse error: {0}: Line {1}, Column {2}: {3}" -f $rel, $err.Extent.StartLineNumber, $err.Extent.StartColumnNumber, $err.Message)) | Out-Null
            }
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host 'Encoding/syntax check failed:' -ForegroundColor Red
    foreach ($v in @($violations.ToArray())) { Write-Host ('- ' + $v) -ForegroundColor Red }
    throw ("Encoding/syntax check failed: {0} issue(s)." -f $violations.Count)
}

Write-Host ("Encoding/syntax check passed: {0} file(s) verified." -f $targets.Count) -ForegroundColor Green
