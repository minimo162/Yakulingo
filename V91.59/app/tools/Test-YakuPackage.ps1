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
    $leaked = @($names | Where-Object { $_ -match '/user_settings[^/]*$' -or $_ -match '\.(bak|tmp)$' })
    if ($leaked.Count -gt 0) { throw "PACKAGE_FORBIDDEN_FILE: $($leaked -join ', ')" }
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

    # manifest.json はローカル複製後の完全性検証に使うため、パッケージ時点で
    # 実体と一致していることを保証する。
    $manifestEntry = $zip.Entries | Where-Object { $_.FullName -match '(^|/)manifest\.json$' } | Select-Object -First 1
    if (-not $manifestEntry) { throw 'PACKAGE_MANIFEST_MISSING: manifest.json がありません。New-YakuPackage.ps1 で作成してください。' }
    $reader = New-Object IO.StreamReader($manifestEntry.Open(), [Text.Encoding]::UTF8, $true)
    try { $manifestRaw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    try { $manifest = $manifestRaw | ConvertFrom-Json } catch { throw 'PACKAGE_MANIFEST_INVALID: manifest.json を解析できません。' }
    if ([string]$manifest.build_id -ne $build) { throw "PACKAGE_MANIFEST_BUILD_MISMATCH: manifest=$([string]$manifest.build_id) build.txt=$build" }
    if ([string]$manifest.version -ne $build) { throw "PACKAGE_MANIFEST_VERSION_MISMATCH: manifest=$([string]$manifest.version) build.txt=$build" }

    $prefix = $manifestEntry.FullName.Substring(0, $manifestEntry.FullName.Length - 'manifest.json'.Length)
    $byPath = @{}
    foreach ($entry in @($zip.Entries)) {
        if ($entry.FullName.EndsWith('/')) { continue }
        if ($entry.FullName -eq $manifestEntry.FullName) { continue }
        if (-not $entry.FullName.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            throw "PACKAGE_MANIFEST_SCOPE: manifest.json の階層外にファイルがあります: $($entry.FullName)"
        }
        $byPath[$entry.FullName.Substring($prefix.Length)] = $entry
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($item in @($manifest.files)) {
            $relative = [string]$item.path
            if (-not $byPath.ContainsKey($relative)) { throw "PACKAGE_MANIFEST_FILE_MISSING: $relative" }
            $entry = $byPath[$relative]
            if ([long]$entry.Length -ne [long]$item.size) {
                throw "PACKAGE_MANIFEST_SIZE_MISMATCH: $relative manifest=$([long]$item.size) actual=$([long]$entry.Length)"
            }
            $stream = $entry.Open()
            try { $actual = (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $stream.Dispose() }
            if ($actual -ne ([string]$item.sha256).ToLowerInvariant()) {
                throw "PACKAGE_MANIFEST_HASH_MISMATCH: $relative"
            }
            $null = $byPath.Remove($relative)
        }
    } finally { $sha.Dispose() }
    if ($byPath.Count -gt 0) {
        throw "PACKAGE_MANIFEST_UNLISTED: manifest.json に未記載のファイルがあります: $((@($byPath.Keys) | Sort-Object) -join ', ')"
    }
    if ([int]$manifest.file_count -ne @($manifest.files).Count) {
        throw "PACKAGE_MANIFEST_COUNT_MISMATCH: file_count=$([int]$manifest.file_count) files=$(@($manifest.files).Count)"
    }

    Write-Host "PASS: build=$build entries=$($zip.Entries.Count) manifest=$([int]$manifest.file_count) escapedNames=0 UTF8BOM=OK SHA256=OK" -ForegroundColor Green
} finally { $zip.Dispose() }
