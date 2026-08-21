<#
.SYNOPSIS
  Regression checks for the runtime file SHA-256 helper.

.DESCRIPTION
  Keeps the product hash path independent from the Get-FileHash cmdlet and
  verifies that direct CatProject loading supplies the runtime helper.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$srcRoot = Join-Path $root 'src'
$script:fail = 0

function Chk {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host ('  PASS ' + $Message) -ForegroundColor Green
    } else {
        Write-Host ('  FAIL ' + $Message) -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-file-hash-' + [guid]::NewGuid().ToString('N'))
$hadDataDir = Test-Path -LiteralPath Env:YAKULINGO_DATA_DIR
$previousDataDir = if ($hadDataDir) { [string]$env:YAKULINGO_DATA_DIR } else { $null }
$hashFunctionPath = 'Function:\Get-FileHash'
$hadHashFunction = Test-Path -LiteralPath $hashFunctionPath
$originalHashFunction = if ($hadHashFunction) { (Get-Item -LiteralPath $hashFunctionPath).ScriptBlock } else { $null }

try {
    $null = New-Item -ItemType Directory -Path $tmp -Force
    $env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'

    . (Join-Path $srcRoot 'Runtime.ps1')
    Set-Item -LiteralPath $hashFunctionPath -Value { throw 'UNEXPECTED_GET_FILE_HASH' } -Force

    try {
        Get-FileHash -LiteralPath (Join-Path $tmp 'missing.bin') -Algorithm SHA256 | Out-Null
        Chk $false 'Get-FileHash shadow throws as intended'
    } catch {
        Chk ([string]$_.Exception.Message -eq 'UNEXPECTED_GET_FILE_HASH') 'Get-FileHash shadow throws as intended'
    }

    $abcPath = Join-Path $tmp 'abc.bin'
    [System.IO.File]::WriteAllBytes($abcPath, [System.Text.Encoding]::ASCII.GetBytes('abc'))
    $abcHash = Get-YakuFileSha256Hex -Path $abcPath
    Chk ($abcHash -eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') 'abc hash matches known SHA-256'
    Chk ($abcHash -cmatch '^[a-f0-9]{64}$') 'abc hash is lowercase hexadecimal'

    $largePath = Join-Path $tmp 'one-megabyte.bin'
    $chunk = New-Object byte[] 65536
    for ($i = 0; $i -lt $chunk.Length; $i++) { $chunk[$i] = [byte]65 }
    $stream = [System.IO.File]::Open($largePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        for ($i = 0; $i -lt 16; $i++) { $stream.Write($chunk, 0, $chunk.Length) }
    } finally {
        $stream.Dispose()
    }
    $largeHash = Get-YakuFileSha256Hex -Path $largePath
    Chk ($largeHash -eq '4e29ad18ab9f42d7c233500771a39d7c852b200baf328fd00fbbe3fecea1eb56') '1 MiB streaming hash matches known SHA-256'

    $sourceFiles = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    $remaining = @($sourceFiles | Select-String -Pattern '\bGet-FileHash\b')
    Chk ($remaining.Count -eq 0) 'src has no Get-FileHash call or reference'

    Remove-Item -LiteralPath 'Function:\Get-YakuFileSha256Hex' -Force -ErrorAction SilentlyContinue
    . (Join-Path $srcRoot 'CatProject.ps1')
    Chk ($null -ne (Get-Command Get-YakuFileSha256Hex -ErrorAction SilentlyContinue)) 'direct CatProject load supplies file hash helper'
    Chk ((Get-YakuFileSha256Hex -Path $abcPath) -eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') 'helper still works after direct CatProject load'
} catch {
    Write-Host ('  FAIL unexpected test error: ' + $_.Exception.Message) -ForegroundColor Red
    $script:fail++
} finally {
    if ($hadHashFunction) {
        Set-Item -LiteralPath $hashFunctionPath -Value $originalHashFunction -Force
    } else {
        Remove-Item -LiteralPath $hashFunctionPath -Force -ErrorAction SilentlyContinue
    }
    if ($hadDataDir) {
        $env:YAKULINGO_DATA_DIR = $previousDataDir
    } else {
        Remove-Item -LiteralPath Env:YAKULINGO_DATA_DIR -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:fail -gt 0) {
    Write-Host ('Yaku file hash runtime regression failed: ' + $script:fail) -ForegroundColor Red
    exit 1
}
Write-Host 'Yaku file hash runtime regression passed.' -ForegroundColor Green
exit 0
