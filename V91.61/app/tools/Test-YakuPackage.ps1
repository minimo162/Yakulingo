[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackagePath)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw "PACKAGE_NOT_FOUND: $PackagePath" }

function Test-YakuPackageRelativePath {
    param([Parameter(Mandatory=$true)][string]$Relative, [Parameter(Mandatory=$true)][ref]$Reason)
    if ([string]::IsNullOrWhiteSpace($Relative)) { $Reason.Value = '空のパス'; return $false }
    if ($Relative.IndexOf('\') -ge 0) { $Reason.Value = '区切りは / のみ使用できます'; return $false }
    if ($Relative.StartsWith('/') -or $Relative.StartsWith('//') -or $Relative -match '^[A-Za-z]:' -or $Relative.IndexOf(':') -ge 0) { $Reason.Value = '絶対パス・ドライブ・ADS は使用できません'; return $false }
    if ($Relative.IndexOfAny([char[]]@('<','>','"','|','?','*')) -ge 0) { $Reason.Value = 'Windowsで使用できない文字を含みます'; return $false }
    foreach ($ch in $Relative.ToCharArray()) { if ([int][char]$ch -lt 32) { $Reason.Value = '制御文字を含みます'; return $false } }
    foreach ($segment in @($Relative -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..')) { $Reason.Value = '空・.・.. の要素は使用できません'; return $false }
        if ($segment.EndsWith(' ') -or $segment.EndsWith('.')) { $Reason.Value = '末尾の空白・ピリオドは使用できません'; return $false }
        $baseName = ($segment -split '\.')[0]
        if ($baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $Reason.Value = 'Windows予約名は使用できません'; return $false }
    }
    return $true
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $PackagePath).Path)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    $seenArchiveNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        if (-not $seenArchiveNames.Add([string]$name)) { throw "PACKAGE_DUPLICATE_ENTRY: $name" }
    }
    $escaped = @($names | Where-Object { $_ -match '#U[0-9A-Fa-f]{4}' })
    if ($escaped.Count -gt 0) { throw "PACKAGE_ESCAPED_NAME: $($escaped -join ', ')" }
    $leaked = @($names | Where-Object { $_ -match '/user_settings[^/]*$' -or $_ -match '\.(bak|tmp)$' })
    if ($leaked.Count -gt 0) { throw "PACKAGE_FORBIDDEN_FILE: $($leaked -join ', ')" }
    $seedAssets = @($names | Where-Object {
        $_ -match '(?i)(^|/)(glossary|propernouns)\.csv$' -or
        $_ -match '(?i)(^|/)corpus(/|$)' -or
        $_ -match '(?i)(^|/)_docs(/|$)' -or
        $_ -match '(^|/)管理者用_コーパス作成\.cmd$'
    })
    if ($seedAssets.Count -gt 0) { throw "PACKAGE_BUNDLED_LANGUAGE_ASSET: $($seedAssets -join ', ')" }
    $buildEntry = $zip.Entries | Where-Object { $_.FullName -match '/app/config/build\.txt$' } | Select-Object -First 1
    if (-not $buildEntry) { throw 'PACKAGE_BUILD_MISSING: config/build.txt がありません。' }
    $reader = New-Object IO.StreamReader($buildEntry.Open(), [Text.Encoding]::UTF8, $true)
    try { $build = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($build)) { throw 'PACKAGE_BUILD_EMPTY: config/build.txt が空です。' }
    if ($build -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $build -in @('.', '..') -or $build.EndsWith('.')) { throw "PACKAGE_BUILD_ID_INVALID: $build" }
    foreach ($entry in @($zip.Entries)) {
        # 翻訳プロンプトは app/prompts/ 配下だけ。評価ハーネスの生成物(tools/eval/prompts/)を拾わない。
        $check = $entry.FullName -match '\.ps1$' -or $entry.FullName -match '/app/prompts/[^/]+\.txt$'
        if (-not $check) { continue }
        $stream = $entry.Open()
        try { $b = New-Object byte[] 3; $n = $stream.Read($b,0,3) } finally { $stream.Dispose() }
        if ($n -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { throw "PACKAGE_UTF8_BOM_MISSING: $($entry.FullName)" }
    }

    # manifest.json はローカル複製後の完全性検証に使うため、パッケージ時点で
    # 実体と一致していることを保証する。
    $manifestEntries = @($zip.Entries | Where-Object { $_.FullName -match '(^|/)manifest\.json$' })
    if ($manifestEntries.Count -eq 0) { throw 'PACKAGE_MANIFEST_MISSING: manifest.json がありません。New-YakuPackage.ps1 で作成してください。' }
    if ($manifestEntries.Count -ne 1) { throw 'PACKAGE_MANIFEST_DUPLICATE: manifest.json が複数あります。' }
    $manifestEntry = $manifestEntries[0]
    $reader = New-Object IO.StreamReader($manifestEntry.Open(), [Text.Encoding]::UTF8, $true)
    try { $manifestRaw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    try { $manifest = $manifestRaw | ConvertFrom-Json } catch { throw 'PACKAGE_MANIFEST_INVALID: manifest.json を解析できません。' }
    if ([int]$manifest.schema -ne 1) { throw "PACKAGE_MANIFEST_SCHEMA_UNSUPPORTED: $([string]$manifest.schema)" }
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
        $relative = $entry.FullName.Substring($prefix.Length)
        $pathReason = ''
        if (-not (Test-YakuPackageRelativePath -Relative $relative -Reason ([ref]$pathReason))) { throw "PACKAGE_MANIFEST_PATH_INVALID: $relative ($pathReason)" }
        if ($byPath.ContainsKey($relative)) { throw "PACKAGE_MANIFEST_PATH_DUPLICATE: $relative" }
        $byPath[$relative] = $entry
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    $manifestPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $totalBytes = 0L
    try {
        foreach ($item in @($manifest.files)) {
            $relative = [string]$item.path
            $pathReason = ''
            if (-not (Test-YakuPackageRelativePath -Relative $relative -Reason ([ref]$pathReason))) { throw "PACKAGE_MANIFEST_PATH_INVALID: $relative ($pathReason)" }
            if (-not $manifestPaths.Add($relative)) { throw "PACKAGE_MANIFEST_PATH_DUPLICATE: $relative" }
            if ([string]$item.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "PACKAGE_MANIFEST_SHA256_INVALID: $relative" }
            $size = 0L
            try { $size = [long]$item.size } catch { throw "PACKAGE_MANIFEST_SIZE_INVALID: $relative" }
            if ($size -lt 0) { throw "PACKAGE_MANIFEST_SIZE_INVALID: $relative" }
            $totalBytes += $size
            if (-not $byPath.ContainsKey($relative)) { throw "PACKAGE_MANIFEST_FILE_MISSING: $relative" }
            $entry = $byPath[$relative]
            if ([long]$entry.Length -ne $size) {
                throw "PACKAGE_MANIFEST_SIZE_MISMATCH: $relative manifest=$size actual=$([long]$entry.Length)"
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
    if ($manifest.PSObject.Properties.Name -contains 'total_bytes' -and [long]$manifest.total_bytes -ne $totalBytes) {
        throw "PACKAGE_MANIFEST_TOTAL_BYTES_MISMATCH: total_bytes=$([long]$manifest.total_bytes) files=$totalBytes"
    }

    Write-Host "PASS: build=$build entries=$($zip.Entries.Count) manifest=$([int]$manifest.file_count) escapedNames=0 UTF8BOM=OK SHA256=OK paths=SAFE" -ForegroundColor Green
} finally { $zip.Dispose() }