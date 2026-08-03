[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$SourceRoot,
 [Parameter(Mandatory=$true)][string]$OutputPath,
 [Parameter(Mandatory=$true)][string]$BuildId
)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
$build=$BuildId.Trim()
if ([string]::IsNullOrWhiteSpace($build)) { throw 'PACKAGE_BUILD_ID_EMPTY: BuildId を指定してください。' }
$buildPath=Join-Path $source 'app\config\build.txt'
$utf8Bom=New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($buildPath, $build+"`r`n", $utf8Bom)

# 配布物へ利用者データや作業ファイルを混入させない。V91.59以降 user_settings.json は
# ユーザープロファイル配下だが、開発ツリーに旧版由来の残骸があると全利用者の初回起動で
# 開発端末の設定が引き継がれてしまう。
$forbidden = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force | Where-Object {
    $_.Name -like 'user_settings*' -or $_.Extension -in @('.bak','.tmp') -or $_.Name -like '~$*'
})
if ($forbidden.Count -gt 0) {
    $names = ($forbidden | ForEach-Object { $_.FullName.Substring($source.Length).TrimStart([char[]]@('\','/')) }) -join ', '
    throw "PACKAGE_FORBIDDEN_FILE: 配布物に含められないファイルがあります: $names"
}

# manifest.json は自分自身を一覧へ含めないため、列挙より前に消しておく。
$manifestPath = Join-Path $source 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }

$map = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)) {
    $relative = $file.FullName.Substring($source.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
    $map[$relative] = $file.FullName
}
if ($map.Count -eq 0) { throw "PACKAGE_SOURCE_EMPTY: 配布対象のファイルがありません: $source" }

# 生成環境によらず同じ並びにするため、序数順で固定する。
$paths = [string[]]@($map.Keys)
[array]::Sort($paths, [System.StringComparer]::Ordinal)

$entries = New-Object System.Collections.Generic.List[object]
$totalBytes = 0L
foreach ($relative in $paths) {
    $full = [string]$map[$relative]
    $length = [long](Get-Item -LiteralPath $full).Length
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    $entries.Add([ordered]@{ path = $relative; size = $length; sha256 = $hash }) | Out-Null
    $totalBytes += $length
}

$manifest = [ordered]@{
    schema       = 1
    version      = $build
    build_id     = $build
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    file_count   = $entries.Count
    total_bytes  = $totalBytes
    files        = @($entries.ToArray())
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8Bom)
Write-Host ("manifest.json generated. build={0} files={1} bytes={2}" -f $build, $entries.Count, $totalBytes) -ForegroundColor Cyan

if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
# Compress-Archive は隠しファイルの扱いがプラットフォームで異なる。manifest の一覧から
# 直接ZIPを組み立て、ZIPの中身とmanifestが構造的に一致することを保証する。
Add-Type -AssemblyName System.IO.Compression.FileSystem
$rootName = Split-Path -Leaf $source
$zip = [IO.Compression.ZipFile]::Open($OutputPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $manifestPath, "$rootName/manifest.json", [IO.Compression.CompressionLevel]::Optimal)
    foreach ($entry in $entries) {
        $relative = [string]$entry.path
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, ([string]$map[$relative]), "$rootName/$relative", [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $zip.Dispose() }

& (Join-Path $source 'app\tools\Test-YakuPackage.ps1') -PackagePath $OutputPath
