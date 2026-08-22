<#
.SYNOPSIS
  共有フォルダへアップロードするためのフォルダを、作業ツリーから新規に作成する。

.DESCRIPTION
  作業ツリー（このリポジトリ）は一切変更しない。アップロードに必要なものだけを
  新しいフォルダへ複製する。

  共有ルート直下は許可リスト方式で、想定した構成物だけを複製する。想定外の
  ファイルは複製せず、理由付きで一覧表示する（消えたことに気付けるようにするため）。

  app フォルダは除外リスト方式で、利用者データ・作業ファイル・OSのゴミ・
  開発ノートを除いて複製する。複製後、共有ルートの manifest.json を作り直す。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\New-YakuUploadFolder.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\New-YakuUploadFolder.ps1 -Destination D:\upload\ECM資料英訳ツール
#>
[CmdletBinding()]
param(
    [string]$SourceRoot = '',
    [string]$Destination = '',
    [string]$DestinationParent = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# 共有ルート直下に置くもの。ここに無いものは複製しない。
$rootAllowList = @(
    'YakuLingo起動.cmd',
    'bootstrap.ps1',
    '共有フォルダ配置手順.md'
)
$rootAllowDirs = @('app')

# app フォルダから除外するもの。
$excludeFilePatterns = @(
    @{ Pattern = 'user_settings*'; Reason = '利用者設定' },
    @{ Pattern = '*.bak';          Reason = 'バックアップ' },
    @{ Pattern = '*.tmp';          Reason = '一時ファイル' },
    @{ Pattern = '*.orig';         Reason = 'マージ残骸' },
    @{ Pattern = '*.rej';          Reason = 'マージ残骸' },
    @{ Pattern = '*.log';          Reason = 'ログ' },
    @{ Pattern = '*.zip';          Reason = 'パッケージ原本' },
    @{ Pattern = '~$*';            Reason = 'Officeの作業ファイル' },
    @{ Pattern = 'Thumbs.db';      Reason = 'エクスプローラーのキャッシュ' },
    @{ Pattern = 'desktop.ini';    Reason = 'エクスプローラーの設定' },
    @{ Pattern = '.DS_Store';      Reason = 'macOSのゴミ' },
    @{ Pattern = 'manifest.json';  Reason = '複製後に作り直す' }
)
# 評価ハーネスの生成物。実行のたびに作り直されるため配布しない。
$excludeRelativePrefixes = @(
    @{ Prefix = 'tools/eval/prompts/';   Reason = '評価ハーネスの生成物' },
    @{ Prefix = 'tools/eval/responses/'; Reason = '評価ハーネスの生成物' }
)
$excludeDirNames = @(
    @{ Name = '.git';         Reason = 'Git管理データ' },
    @{ Name = '.github';      Reason = 'Git管理データ' },
    @{ Name = '.vs';          Reason = 'Visual Studioの作業' },
    @{ Name = 'desktop';      Reason = '廃止したデスクトップshell' },
    @{ Name = 'experiments';  Reason = '開発用ブラウザ実験' },
    @{ Name = 'node_modules'; Reason = '依存パッケージ' },
    @{ Name = '__pycache__';  Reason = 'Pythonのキャッシュ' },
    @{ Name = '_docs';        Reason = '開発ノート（appには複製しない）' },
    @{ Name = 'docs';         Reason = '旧docs（配布物に含めない）' }
)

function Test-YakuPackageRoot {
    param([string]$Dir)
    return (Test-Path -LiteralPath (Join-Path (Join-Path $Dir 'app') 'Start-YakuLingo.ps1') -PathType Leaf)
}

function Format-YakuSize {
    param([long]$Bytes)
    if ($Bytes -ge 1048576) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024) { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    return "$Bytes B"
}

$script:Skipped = New-Object System.Collections.Generic.List[object]
function Add-YakuSkip {
    param([string]$Relative, [string]$Reason)
    $script:Skipped.Add([pscustomobject]@{ Path = $Relative; Reason = $Reason }) | Out-Null
}

function Copy-YakuAppFolder {
    param([string]$Source, [string]$Target, [string]$Label)
    $sourceFull = (Resolve-Path -LiteralPath $Source).Path
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $skipDirs = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @(Get-ChildItem -LiteralPath $sourceFull -Recurse -Directory -Force | Sort-Object FullName)) {
        $relative = $dir.FullName.Substring($sourceFull.Length).TrimStart([char[]]@('\','/'))
        $inSkipped = $false
        foreach ($known in $skipDirs) {
            if ($relative.StartsWith($known + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $inSkipped = $true; break }
        }
        if ($inSkipped) { continue }
        $rule = $excludeDirNames | Where-Object { $_.Name -eq $dir.Name } | Select-Object -First 1
        if ($rule) {
            $skipDirs.Add($relative) | Out-Null
            Add-YakuSkip -Relative "$Label\$relative\" -Reason ([string]$rule.Reason)
            continue
        }
        New-Item -ItemType Directory -Path (Join-Path $Target $relative) -Force | Out-Null
    }

    $copied = 0
    $bytes = 0L
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceFull -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($sourceFull.Length).TrimStart([char[]]@('\','/'))
        $inSkipped = $false
        foreach ($known in $skipDirs) {
            if ($relative.StartsWith($known + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $inSkipped = $true; break }
        }
        if ($inSkipped) { continue }
        $rule = $excludeFilePatterns | Where-Object { $file.Name -like $_.Pattern } | Select-Object -First 1
        if (-not $rule) {
            $forward = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
            $rule = $excludeRelativePrefixes | Where-Object { $forward -like ($_.Prefix + '*') } | Select-Object -First 1
        }
        if ($rule) {
            Add-YakuSkip -Relative "$Label\$relative" -Reason ([string]$rule.Reason)
            continue
        }
        $destination = Join-Path $Target $relative
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copied++
        $bytes += [long]$file.Length
    }
    return [pscustomobject]@{ Files = $copied; Bytes = $bytes }
}

# ---------------------------------------------------------------- main

if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = $PSScriptRoot }
if (!(Test-Path -LiteralPath $SourceRoot -PathType Container)) { throw "SOURCE_NOT_FOUND: 作業ツリーが見つかりません: $SourceRoot" }
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
if (-not (Test-YakuPackageRoot -Dir $source)) { throw "SOURCE_NOT_YAKULINGO: app\Start-YakuLingo.ps1 が見つかりません: $source" }
$buildPath = Join-Path $source 'app\config\build.txt'
if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) { throw "BUILD_ID_MISSING: $buildPath が見つかりません。" }
$buildId = [IO.File]::ReadAllText($buildPath).Trim()
if ($buildId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $buildId -in @('.', '..') -or $buildId.EndsWith('.')) {
    throw "BUILD_ID_INVALID: app\config\build.txt の値が不正です: $buildId"
}

# 出力先を決める。既存を壊さないため、既定は新規のタイムスタンプ付きフォルダ。
if ([string]::IsNullOrWhiteSpace($Destination)) {
    if ([string]::IsNullOrWhiteSpace($DestinationParent)) {
        $DestinationParent = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($DestinationParent)) { $DestinationParent = [IO.Path]::GetTempPath() }
    }
    if (!(Test-Path -LiteralPath $DestinationParent -PathType Container)) { throw "DESTINATION_PARENT_NOT_FOUND: 出力先の親フォルダがありません: $DestinationParent" }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $Destination = Join-Path $DestinationParent ('ECM資料英訳ツール_' + $buildId + '_' + $stamp)
}
$destinationFull = [IO.Path]::GetFullPath($Destination)

if ($destinationFull.StartsWith($source, [StringComparison]::OrdinalIgnoreCase)) {
    throw "DESTINATION_INSIDE_SOURCE: 出力先を作業ツリーの内側にはできません: $destinationFull"
}
if (Test-Path -LiteralPath $destinationFull) {
    $existing = @(Get-ChildItem -LiteralPath $destinationFull -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        if (-not $Force) { throw "DESTINATION_NOT_EMPTY: 出力先が空ではありません。別の場所を指定するか -Force を付けてください: $destinationFull" }
        Remove-Item -LiteralPath $destinationFull -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null

Write-Host ''
Write-Host "作業ツリー: $source" -ForegroundColor Cyan
Write-Host "出力先    : $destinationFull" -ForegroundColor Cyan
Write-Host "ビルドID  : $buildId" -ForegroundColor Cyan
Write-Host ''

$totalFiles = 0
$totalBytes = 0L

# ---- 共有ルート直下（許可リスト） ----
foreach ($entry in @(Get-ChildItem -LiteralPath $source -Force | Sort-Object Name)) {
    if ($entry.PSIsContainer) {
        if ($rootAllowDirs -contains $entry.Name) { continue }
        Add-YakuSkip -Relative ($entry.Name + '\') -Reason '共有ルートの構成物ではない'
        continue
    }
    if ($rootAllowList -notcontains $entry.Name) {
        Add-YakuSkip -Relative $entry.Name -Reason '共有ルートの構成物ではない'
        continue
    }
    Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $destinationFull $entry.Name) -Force
    $totalFiles++
    $totalBytes += [long]$entry.Length
}
foreach ($name in $rootAllowList) {
    if (-not (Test-Path -LiteralPath (Join-Path $destinationFull $name) -PathType Leaf)) {
        Write-Host "  注意: $name が作業ツリーにありません。" -ForegroundColor Yellow
    }
}

# ---- app ----
$targetApp = Join-Path $destinationFull 'app'
$result = Copy-YakuAppFolder -Source (Join-Path $source 'app') -Target $targetApp -Label 'app'
$totalFiles += $result.Files
$totalBytes += $result.Bytes
Write-Host ("複製: app  {0} ファイル / {1}" -f $result.Files, (Format-YakuSize -Bytes $result.Bytes))

# 複製後の実体に合わせて共有ルートの manifest.json を作り直す。
$packager = Join-Path $targetApp 'tools\New-YakuPackage.ps1'
if (-not (Test-Path -LiteralPath $packager -PathType Leaf)) {
    throw "PACKAGER_NOT_FOUND: $packager が見つかりません。"
}
& $packager -SourceRoot $destinationFull -BuildId $buildId -ManifestOnly | Out-Null
Write-Host 'manifest.json を作成しました。' -ForegroundColor DarkGray
$totalFiles++

# ---- 仕上げの点検 ----
$leaks = @(Get-ChildItem -LiteralPath $destinationFull -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like 'user_settings*' -or $_.Extension -in @('.bak','.tmp','.log','.zip','.orig','.rej') -or $_.Name -like '~$*'
})
if ($leaks.Count -gt 0) {
    throw ("UPLOAD_LEAK_DETECTED: 除外できていないファイルがあります: " + (($leaks | ForEach-Object { $_.FullName }) -join ', '))
}
if (Test-Path -LiteralPath (Join-Path $destinationFull '.git')) {
    throw 'UPLOAD_LEAK_DETECTED: .git が残っています。'
}
$languageAssetLeaks = @(Get-ChildItem -LiteralPath $destinationFull -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
    $relative = $_.FullName.Substring($destinationFull.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
    $relative -match '(?i)(^|/)(glossary|propernouns)\.csv$' -or
    $relative -match '(?i)(^|/)corpus(/|$)' -or
    $relative -match '(?i)(^|/)_docs(/|$)' -or
    $relative -match '(^|/)管理者用_コーパス作成\.cmd$'
})
if ($languageAssetLeaks.Count -gt 0) {
    throw ("UPLOAD_BUNDLED_LANGUAGE_ASSET: 配布できない用語・固有名詞・コーパス資産があります: " + (($languageAssetLeaks | ForEach-Object { $_.FullName }) -join ', '))
}

Write-Host ''
Write-Host ("複製しました: {0} ファイル / {1}" -f $totalFiles, (Format-YakuSize -Bytes $totalBytes)) -ForegroundColor Green

if ($script:Skipped.Count -gt 0) {
    Write-Host ''
    Write-Host "複製しなかったもの: $($script:Skipped.Count) 件" -ForegroundColor Yellow
    foreach ($item in $script:Skipped) {
        Write-Host ('  {0}' -f $item.Path)
        Write-Host ('       {0}' -f $item.Reason) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '次の手順:' -ForegroundColor Cyan
Write-Host "  1. 出力先の内容を確認します: $destinationFull"
Write-Host '  2. 共有ルートをこのフォルダの内容で更新します。manifest.json は最後に配置します。'
Write-Host '  3. 詳細は 共有フォルダ配置手順.md を参照してください。'
Write-Host ''
return $destinationFull
