<#
.SYNOPSIS
  共有フォルダへアップロードするためのフォルダを、作業ツリーから新規に作成する。

.DESCRIPTION
  作業ツリー（このリポジトリ）は一切変更しない。アップロードに必要なものだけを
  新しいフォルダへ複製する。

  共有ルート直下は許可リスト方式で、想定した構成物だけを複製する。想定外の
  ファイルは複製せず、理由付きで一覧表示する（消えたことに気付けるようにするため）。

  バージョンフォルダは除外リスト方式で、利用者データ・作業ファイル・OSのゴミ・
  開発ノートを除いて複製する。複製後、各バージョンの manifest.json を作り直す。

  保持するバージョンは既定で「current.txt の現行版」と「その1つ前」の2世代。

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
    [string[]]$Versions = @(),
    [int]$KeepGenerations = 2,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# 共有ルート直下に置くもの。ここに無いものは複製しない。
$rootAllowList = @(
    'YakuLingo起動.cmd',
    'YakuLingo起動.vbs',
    'bootstrap.ps1',
    'current.txt',
    '共有フォルダ配置手順.md'
)
$rootAllowDirs = @('_docs')

# バージョンフォルダから除外するもの。
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
    @{ Prefix = 'app/tools/eval/prompts/';   Reason = '評価ハーネスの生成物' },
    @{ Prefix = 'app/tools/eval/responses/'; Reason = '評価ハーネスの生成物' }
)
$excludeDirNames = @(
    @{ Name = '.git';         Reason = 'Git管理データ' },
    @{ Name = '.github';      Reason = 'Git管理データ' },
    @{ Name = '.vs';          Reason = 'Visual Studioの作業' },
    @{ Name = 'node_modules'; Reason = '依存パッケージ' },
    @{ Name = '__pycache__';  Reason = 'Pythonのキャッシュ' },
    @{ Name = '_docs';        Reason = '開発ノート（版フォルダには複製しない）' },
    @{ Name = 'docs';         Reason = '旧docs（配布物に含めない）' }
)

function Test-YakuVersionFolder {
    param([string]$Dir)
    return (Test-Path -LiteralPath (Join-Path (Join-Path $Dir 'app') 'Start-YakuLingo.ps1') -PathType Leaf)
}

function Format-YakuSize {
    param([long]$Bytes)
    if ($Bytes -ge 1048576) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024) { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    return "$Bytes B"
}

function Read-YakuCurrentVersionName {
    param([string]$Root)
    $path = Join-Path $Root 'current.txt'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($path) } catch { return '' }
    $line = (($raw -replace "`r", "`n") -split "`n")[0]
    $clean = ''
    foreach ($ch in $line.ToCharArray()) {
        if ('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-'.IndexOf($ch) -ge 0) { $clean += $ch }
    }
    return $clean
}

$script:Skipped = New-Object System.Collections.Generic.List[object]
function Add-YakuSkip {
    param([string]$Relative, [string]$Reason)
    $script:Skipped.Add([pscustomobject]@{ Path = $Relative; Reason = $Reason }) | Out-Null
}

function Copy-YakuVersionFolder {
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

$allVersions = @(Get-ChildItem -LiteralPath $source -Directory | Where-Object { Test-YakuVersionFolder -Dir $_.FullName } | Sort-Object Name)
if ($allVersions.Count -eq 0) { throw "SOURCE_NOT_YAKULINGO: バージョンフォルダが見つかりません: $source" }

$currentName = Read-YakuCurrentVersionName -Root $source
if ([string]::IsNullOrWhiteSpace($currentName)) { throw 'CURRENT_TXT_MISSING: current.txt を読めません。現行バージョンを特定できません。' }
if (-not ($allVersions | Where-Object { $_.Name -eq $currentName })) {
    throw "CURRENT_VERSION_NOT_FOUND: current.txt が指す $currentName が見つかりません。"
}

if ($Versions.Count -gt 0) {
    $selected = @()
    foreach ($name in $Versions) {
        $match = $allVersions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $match) { throw "VERSION_NOT_FOUND: 指定されたバージョンがありません: $name" }
        $selected += $match
    }
} else {
    # 現行版と、それより前の新しい順に KeepGenerations 世代まで。
    $ordered = @($allVersions | Where-Object { $_.Name -ne $currentName } | Sort-Object Name -Descending)
    $selected = @($allVersions | Where-Object { $_.Name -eq $currentName })
    $selected += @($ordered | Select-Object -First ([Math]::Max(0, $KeepGenerations - 1)))
}
$selectedNames = @($selected | ForEach-Object { $_.Name })

# 出力先を決める。既存を壊さないため、既定は新規のタイムスタンプ付きフォルダ。
if ([string]::IsNullOrWhiteSpace($Destination)) {
    if ([string]::IsNullOrWhiteSpace($DestinationParent)) {
        $DestinationParent = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($DestinationParent)) { $DestinationParent = [IO.Path]::GetTempPath() }
    }
    if (!(Test-Path -LiteralPath $DestinationParent -PathType Container)) { throw "DESTINATION_PARENT_NOT_FOUND: 出力先の親フォルダがありません: $DestinationParent" }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $Destination = Join-Path $DestinationParent ('ECM資料英訳ツール_' + $currentName + '_' + $stamp)
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
Write-Host "現行版    : $currentName" -ForegroundColor Cyan
Write-Host "複製する版: $($selectedNames -join ', ')" -ForegroundColor Cyan
Write-Host ''

$totalFiles = 0
$totalBytes = 0L

# ---- 共有ルート直下（許可リスト） ----
foreach ($entry in @(Get-ChildItem -LiteralPath $source -Force | Sort-Object Name)) {
    if ($entry.PSIsContainer) {
        if ($selectedNames -contains $entry.Name) { continue }
        if ($rootAllowDirs -contains $entry.Name) { continue }
        if (Test-YakuVersionFolder -Dir $entry.FullName) {
            Add-YakuSkip -Relative ($entry.Name + '\') -Reason '保持世代の対象外'
        } else {
            Add-YakuSkip -Relative ($entry.Name + '\') -Reason '共有ルートの構成物ではない'
        }
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

# ---- 共有ルートの _docs ----
foreach ($dirName in $rootAllowDirs) {
    $sourceDir = Join-Path $source $dirName
    if (!(Test-Path -LiteralPath $sourceDir -PathType Container)) { continue }
    $result = Copy-YakuVersionFolder -Source $sourceDir -Target (Join-Path $destinationFull $dirName) -Label $dirName
    $totalFiles += $result.Files
    $totalBytes += $result.Bytes
}

# ---- バージョンフォルダ ----
foreach ($version in $selected) {
    $target = Join-Path $destinationFull $version.Name
    $result = Copy-YakuVersionFolder -Source $version.FullName -Target $target -Label $version.Name
    $totalFiles += $result.Files
    $totalBytes += $result.Bytes
    Write-Host ("複製: {0}  {1} ファイル / {2}" -f $version.Name, $result.Files, (Format-YakuSize -Bytes $result.Bytes))

    # 複製後の実体に合わせて manifest.json を作り直す。
    # V91.58以前の New-YakuPackage.ps1 は -ManifestOnly を持たない。その版は
    # manifest なしのまま置き、bootstrap 側の旧方式（共有フォルダ上で直接起動）に委ねる。
    $packager = Join-Path $target 'app\tools\New-YakuPackage.ps1'
    $supportsManifest = $false
    if (Test-Path -LiteralPath $packager -PathType Leaf) {
        try { $supportsManifest = (Get-Command $packager -ErrorAction Stop).Parameters.ContainsKey('ManifestOnly') } catch { $supportsManifest = $false }
    }
    if ($supportsManifest) {
        & $packager -SourceRoot $target -BuildId $version.Name -ManifestOnly | Out-Null
        Write-Host '  manifest.json を作成しました。' -ForegroundColor DarkGray
        $totalFiles++
    } else {
        Write-Host ("  {0} は manifest 非対応の版です。共有フォルダ上で直接起動する旧方式で動作します。" -f $version.Name) -ForegroundColor Yellow
    }
}

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
Write-Host '  2. 共有ルートへコピーします。コピー途中を利用者に見せないため、'
Write-Host '     バージョンフォルダは一時名でコピーしてから正式名へリネームします。'
Write-Host "  3. 最後に current.txt を $currentName へ更新します。"
Write-Host '  4. 詳細は 共有フォルダ配置手順.md を参照してください。'
Write-Host ''
return $destinationFull
