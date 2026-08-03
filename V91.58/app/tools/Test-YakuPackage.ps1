[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackagePath)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw "PACKAGE_NOT_FOUND: $PackagePath" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $PackagePath).Path)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    $escaped = @($names | Where-Object { $_ -match '#U[0-9A-Fa-f]{4}' })
    if ($escaped.Count -gt 0) { throw "PACKAGE_ESCAPED_NAME: $($escaped -join ', ')" }
    $buildEntry = $zip.Entries | Where-Object { $_.FullName -match '/app/config/build\.txt$' } | Select-Object -First 1
    if (-not $buildEntry) { throw 'PACKAGE_BUILD_MISSING: config/build.txt がありません。' }
    $reader = New-Object IO.StreamReader($buildEntry.Open(), [Text.Encoding]::UTF8, $true)
    try { $build = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($build)) { throw 'PACKAGE_BUILD_EMPTY: config/build.txt が空です。' }
    foreach ($entry in @($zip.Entries)) {
        $check = $entry.FullName -match '\.ps1$' -or $entry.FullName -match '/prompts/[^/]+\.txt$'
        if (-not $check) { continue }
        $stream = $entry.Open()
        try { $b = New-Object byte[] 3; $n = $stream.Read($b,0,3) } finally { $stream.Dispose() }
        if ($n -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { throw "PACKAGE_UTF8_BOM_MISSING: $($entry.FullName)" }
    }
    Write-Host "PASS: build=$build entries=$($zip.Entries.Count) escapedNames=0 UTF8BOM=OK" -ForegroundColor Green
} finally { $zip.Dispose() }
