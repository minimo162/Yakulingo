[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$newPackage = Join-Path $tools 'New-YakuPackage.ps1'
$testPackage = Join-Path $tools 'Test-YakuPackage.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('YakuLingo-package-language-boundary-' + [guid]::NewGuid().ToString('N'))
$utf8Bom = New-Object Text.UTF8Encoding($true)
$passed = 0

function Check-YakuPackageBoundary {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "PACKAGE_LANGUAGE_BOUNDARY_ASSERTION_FAILED: $Message" }
    $script:passed++
}

function Check-YakuPackageBoundaryThrows {
    param([scriptblock]$Action, [string]$Message)
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = [string]$_.Exception.Message }
    Check-YakuPackageBoundary ($caught -match '^PACKAGE_BUNDLED_LANGUAGE_ASSET:') $Message
}

try {
    $clean = Join-Path $work 'clean'
    New-Item -ItemType Directory -Path (Join-Path $clean 'app\config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $clean 'app\tools') -Force | Out-Null
    Copy-Item -LiteralPath $testPackage -Destination (Join-Path $clean 'app\tools\Test-YakuPackage.ps1') -Force
    [IO.File]::WriteAllText((Join-Path $clean 'app\config\build.txt'), "TEST`r`n", $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $clean 'app\empty-state.txt'), "No bundled language data.`r`n", $utf8Bom)

    $cleanZip = Join-Path $work 'clean.zip'
    & $newPackage -SourceRoot $clean -OutputPath $cleanZip -BuildId 'TEST'
    Check-YakuPackageBoundary (Test-Path -LiteralPath $cleanZip -PathType Leaf) 'zero-seed package must build and verify'

    $cases = @(
        @{ Relative='app\glossary.csv'; Content='内部用語,internal term' },
        @{ Relative='app\propernouns.csv'; Content='内部固有名詞,internal proper name' },
        @{ Relative='corpus\2026-08\sample.md'; Content='historical disclosure corpus' },
        @{ Relative='_docs\internal-review.md'; Content='internal documentation' },
        @{ Relative='管理者用_コーパス作成.cmd'; Content='@echo off' }
    )
    foreach ($case in $cases) {
        $caseRoot = Join-Path $work ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $clean -Destination $caseRoot -Recurse -Force
        $target = Join-Path $caseRoot ([string]$case.Relative)
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($target, [string]$case.Content, $utf8Bom)
        Check-YakuPackageBoundaryThrows { & $newPackage -SourceRoot $caseRoot -BuildId 'TEST' -ManifestOnly } ("package creation must reject " + [string]$case.Relative)
    }

    # The archive verifier is an independent boundary: even a ZIP assembled
    # without New-YakuPackage must be rejected before it reaches bootstrap.
    $tamperedZip = Join-Path $work 'tampered.zip'
    Copy-Item -LiteralPath $cleanZip -Destination $tamperedZip -Force
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($tamperedZip, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.CreateEntry('clean/corpus/legacy/example.md')
        $writer = New-Object IO.StreamWriter($entry.Open(), $utf8Bom)
        try { $writer.Write('legacy corpus') } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    Check-YakuPackageBoundaryThrows { & $testPackage -PackagePath $tamperedZip } 'archive verification must reject a corpus inserted after manifest creation'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("Package zero-seed language boundary regression passed: {0}" -f $passed) -ForegroundColor Green
