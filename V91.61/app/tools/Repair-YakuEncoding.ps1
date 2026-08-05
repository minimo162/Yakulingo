<#
.SYNOPSIS
  Detects and repairs BOM-less YakuLingo source/prompt files by rewriting them as UTF-8 with BOM.
.DESCRIPTION
  - Strict UTF-8 decode first; falls back to CP932 (Shift_JIS) if the bytes are not valid UTF-8.
  - Refuses to write when the decoded text contains U+FFFD (replacement char) = already-corrupted file.
  - -WhatIfOnly lists violations without modifying anything.
#>
[CmdletBinding()]
param(
    # Check-Encoding.ps1 と同じ理由で既定値の式では解決しない。
    # [CmdletBinding()] 付き .ps1 の param() 既定値では 5.1 が $MyInvocation.MyCommand.Path を $null にする。
    [string]$Root = '',
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$rootPath = (Resolve-Path -LiteralPath $Root).Path

$targets = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Filter '*.ps1')) { $targets.Add($f.FullName) | Out-Null }
$promptDir = Join-Path $rootPath 'prompts'
if (Test-Path -LiteralPath $promptDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $promptDir -Filter '*.txt')) { $targets.Add($f.FullName) | Out-Null }
}

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$cp932 = [System.Text.Encoding]::GetEncoding(932)

$fixed = 0; $skipped = 0; $failed = 0
foreach ($path in @($targets.ToArray())) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $skipped++; continue }

    $text = $null; $sourceEnc = ''
    try { $text = $utf8Strict.GetString($bytes); $sourceEnc = 'utf8-nobom' }
    catch {
        try { $text = $cp932.GetString($bytes); $sourceEnc = 'cp932' } catch { $text = $null }
    }
    if ($null -eq $text -or $text.IndexOf([char]0xFFFD) -ge 0) {
        Write-Host "REPAIR FAILED (corrupted, fix manually): $path" -ForegroundColor Red
        $failed++
        continue
    }
    if ($WhatIfOnly) {
        Write-Host "WOULD FIX [$sourceEnc -> utf8-bom]: $path" -ForegroundColor Yellow
    } else {
        $temp = $path + '.encfix.tmp'
        [System.IO.File]::WriteAllText($temp, $text, $utf8Bom)
        Move-Item -LiteralPath $temp -Destination $path -Force
        Write-Host "FIXED [$sourceEnc -> utf8-bom]: $path" -ForegroundColor Green
    }
    $fixed++
}
Write-Host ("Done. fixed={0} alreadyOk={1} failed={2}" -f $fixed, $skipped, $failed)
if ($failed -gt 0) { exit 1 }
