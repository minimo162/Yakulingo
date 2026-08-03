<#
.SYNOPSIS
  共有フォルダの配布物をローカルへ複製し、manifest.json で検証してから起動する。

.DESCRIPTION
  アプリ本体を共有フォルダ上で直接実行すると、実行中ずっと共有フォルダが
  クリティカルパスに乗る（prompts/glossary の都度読込、FileWorker などの
  別プロセス起動、build.txt の再照合）。そのため利用中のバージョンフォルダを
  差し替えられず、N-1 世代の保持が必要になっていた。

  本スクリプトは配布物をローカルへ複製してから起動する。実行中の $Root は
  他利用者が触れないローカルになるため、共有フォルダ側はいつでも更新できる。

  ローカルの配置先はバージョン名と manifest ハッシュで決まるため、同じ
  バージョン名で中身が差し替わっても別フォルダになる。使用中のフォルダを
  上書きすることはない。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -SharedRoot \\server\share\ECM資料英訳ツール
#>
[CmdletBinding()]
param(
    [string]$SharedRoot = '',
    [string]$LocalRoot = '',
    [switch]$NoLaunch,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

function Write-YakuBootstrapInfo { param([string]$Message) Write-Host "[YakuLingo] $Message" }
function Write-YakuBootstrapWarn { param([string]$Message) Write-Host "[YakuLingo] $Message" -ForegroundColor Yellow }

function Join-YakuPath {
    # 区切りをOSに任せる。テストをWindows以外でも実行できるようにするため。
    param([Parameter(Mandatory=$true)][string]$Base, [Parameter(Mandatory=$true)][string]$Relative)
    $native = $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar).Replace('\', [IO.Path]::DirectorySeparatorChar)
    return (Join-Path $Base $native)
}

function Get-YakuLocalRoot {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return [IO.Path]::GetFullPath($Override) }
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }
    return (Join-Path $base 'YakuLingo')
}

function Test-YakuVersionDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-YakuPath -Base $Path -Relative 'app/Start-YakuLingo.ps1') -PathType Leaf)
}

function Read-YakuCurrentVersionName {
    param([string]$Root)
    $path = Join-Path $Root 'current.txt'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($path) } catch { return '' }
    $line = (($raw -replace "`r", "`n") -split "`n")[0]
    # フォルダ名として安全な文字だけを採用する（既存ランチャーと同じ方針）。
    $clean = ''
    foreach ($ch in $line.ToCharArray()) {
        if ('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-'.IndexOf($ch) -ge 0) { $clean += $ch }
    }
    return $clean
}

function Resolve-YakuSharedVersionDir {
    param([string]$Root)
    $name = Read-YakuCurrentVersionName -Root $Root
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $candidate = Join-Path $Root $name
        if (Test-YakuVersionDir -Path $candidate) { return $candidate }
        Write-YakuBootstrapWarn "current.txt が指す $name を利用できません。最新のバージョンフォルダを探します。"
    }
    $best = $null
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-YakuVersionDir -Path $dir.FullName)) { continue }
        if ($null -eq $best -or $dir.LastWriteTimeUtc -gt $best.LastWriteTimeUtc) { $best = $dir }
    }
    if ($best) { return $best.FullName }
    return ''
}

function Get-YakuHashHex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-YakuTreeRelativePaths {
    param([string]$Root)
    $prefix = (Resolve-Path -LiteralPath $Root).Path
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($prefix.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        $list.Add($relative) | Out-Null
    }
    return $list
}

function Test-YakuTreeAgainstManifest {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][ref]$Reason
    )
    $expected = @{}
    foreach ($item in @($Manifest.files)) { $expected[[string]$item.path] = $item }
    foreach ($relative in @($expected.Keys)) {
        $item = $expected[$relative]
        $full = Join-YakuPath -Base $Root -Relative $relative
        if (!(Test-Path -LiteralPath $full -PathType Leaf)) { $Reason.Value = "欠落: $relative"; return $false }
        if ([long](Get-Item -LiteralPath $full).Length -ne [long]$item.size) { $Reason.Value = "サイズ不一致: $relative"; return $false }
        if ((Get-YakuHashHex -Path $full) -ne ([string]$item.sha256).ToLowerInvariant()) { $Reason.Value = "内容不一致: $relative"; return $false }
    }
    # 一覧にないファイルが紛れ込んでいないことも確認する。
    foreach ($relative in @(Get-YakuTreeRelativePaths -Root $Root)) {
        if ($relative -eq 'manifest.json') { continue }
        if ($relative -eq '.installed') { continue }
        if (-not $expected.ContainsKey($relative)) { $Reason.Value = "manifest未記載: $relative"; return $false }
    }
    return $true
}

function Read-YakuManifest {
    param([Parameter(Mandatory=$true)][string]$Path)
    $raw = [IO.File]::ReadAllText($Path)
    $manifest = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$manifest.build_id)) { throw 'MANIFEST_BUILD_ID_MISSING: manifest.json に build_id がありません。' }
    if (@($manifest.files).Count -eq 0) { throw 'MANIFEST_FILES_EMPTY: manifest.json にファイル一覧がありません。' }
    return $manifest
}

function Get-YakuInstalledMarker {
    param([string]$VersionDir)
    $path = Join-Path $VersionDir '.installed'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return $null }
}

function Unblock-YakuTree {
    param([string]$Root)
    # UNC由来のMark-of-the-Webを外す。Windows以外では何もしない。
    if (-not (Get-Command Unblock-File -ErrorAction SilentlyContinue)) { return }
    try { Get-ChildItem -LiteralPath $Root -Recurse -File | Unblock-File -ErrorAction SilentlyContinue } catch {}
}

function Install-YakuVersion {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$TargetDir,
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$ManifestHash
    )
    $stage = $TargetDir + '.stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    try {
        Write-YakuBootstrapInfo "複製しています: $SourceDir"
        Copy-Item -LiteralPath $SourceDir -Destination $stage -Recurse -Force

        $reason = ''
        if (-not (Test-YakuTreeAgainstManifest -Root $stage -Manifest $Manifest -Reason ([ref]$reason))) {
            throw "INSTALL_VERIFY_FAILED: 複製結果がmanifestと一致しません。$reason"
        }
        Unblock-YakuTree -Root $stage

        $marker = [ordered]@{
            build_id        = [string]$Manifest.build_id
            manifest_sha256 = $ManifestHash
            file_count      = [int]$Manifest.file_count
            source          = $SourceDir
            installed_at    = (Get-Date).ToUniversalTime().ToString('o')
        }
        [IO.File]::WriteAllText((Join-Path $stage '.installed'), ($marker | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($true)))

        # 検証済みの状態になってから初めて正式な名前で公開する。
        # 中途半端な複製を起動対象にしないため、公開は必ずリネームで行う。
        Move-Item -LiteralPath $stage -Destination $TargetDir
        Write-YakuBootstrapInfo "導入しました: $TargetDir"
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-YakuStaleVersions {
    param([Parameter(Mandatory=$true)][string]$VersionsDir, [Parameter(Mandatory=$true)][string]$KeepName)
    foreach ($dir in @(Get-ChildItem -LiteralPath $VersionsDir -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -eq $KeepName) { continue }
        # 使用中のフォルダはリネームできない。リネームできたものだけ削除する。
        $trash = Join-Path $VersionsDir ('.trash-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { Move-Item -LiteralPath $dir.FullName -Destination $trash -ErrorAction Stop }
        catch { Write-YakuBootstrapInfo "使用中のため残します: $($dir.Name)"; continue }
        try { Remove-Item -LiteralPath $trash -Recurse -Force -ErrorAction Stop } catch {}
    }
}

function Get-YakuNewestInstalledVersion {
    param([string]$VersionsDir)
    $best = $null
    foreach ($dir in @(Get-ChildItem -LiteralPath $VersionsDir -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-YakuVersionDir -Path $dir.FullName)) { continue }
        if ($null -eq (Get-YakuInstalledMarker -VersionDir $dir.FullName)) { continue }
        if ($null -eq $best -or $dir.LastWriteTimeUtc -gt $best.LastWriteTimeUtc) { $best = $dir }
    }
    if ($best) { return $best.FullName }
    return ''
}

# ---------------------------------------------------------------- main

if ([string]::IsNullOrWhiteSpace($SharedRoot)) { $SharedRoot = $PSScriptRoot }
$SharedRoot = [IO.Path]::GetFullPath($SharedRoot)
$localRootPath = Get-YakuLocalRoot -Override $LocalRoot
$versionsDir = Join-Path $localRootPath 'versions'
if (!(Test-Path -LiteralPath $versionsDir)) { New-Item -ItemType Directory -Path $versionsDir -Force | Out-Null }

$runDir = ''
$legacyMode = $false

$sharedVersionDir = ''
try { $sharedVersionDir = Resolve-YakuSharedVersionDir -Root $SharedRoot }
catch { Write-YakuBootstrapWarn "共有フォルダを参照できません: $($_.Exception.Message)" }

if ([string]::IsNullOrWhiteSpace($sharedVersionDir)) {
    # 共有フォルダへ到達できない場合でも、導入済みのローカル版で作業を継続できるようにする。
    $runDir = Get-YakuNewestInstalledVersion -VersionsDir $versionsDir
    if ([string]::IsNullOrWhiteSpace($runDir)) {
        throw "SHARED_VERSION_NOT_FOUND: 共有フォルダに起動できるバージョンがなく、ローカルにも導入済みの版がありません。共有ルート: $SharedRoot"
    }
    Write-YakuBootstrapWarn "共有フォルダを参照できないため、導入済みのローカル版で起動します: $(Split-Path -Leaf $runDir)"
} else {
    $manifestPath = Join-Path $sharedVersionDir 'manifest.json'
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        # manifest を持たない旧パッケージ（V91.58以前）へロールバックした場合の互換動作。
        Write-YakuBootstrapWarn "manifest.json がないため、共有フォルダ上で直接起動します（旧方式）: $(Split-Path -Leaf $sharedVersionDir)"
        $runDir = $sharedVersionDir
        $legacyMode = $true
    } else {
        $manifest = Read-YakuManifest -Path $manifestPath
        $manifestHash = Get-YakuHashHex -Path $manifestPath
        # バージョン名が同じでも中身が違えば別フォルダへ導入する。
        # これにより使用中のローカル版を差し替える必要がなくなる。
        $targetName = '{0}-{1}' -f [string]$manifest.build_id, $manifestHash.Substring(0, 8)
        $targetDir = Join-Path $versionsDir $targetName

        $marker = Get-YakuInstalledMarker -VersionDir $targetDir
        if ($null -ne $marker -and [string]$marker.manifest_sha256 -eq $manifestHash -and (Test-YakuVersionDir -Path $targetDir)) {
            Write-YakuBootstrapInfo "導入済みです: $targetName"
        } else {
            $mutex = New-Object System.Threading.Mutex($false, 'Local\YakuLingoBootstrapInstall')
            $held = $false
            try {
                try { $held = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) } catch [System.Threading.AbandonedMutexException] { $held = $true }
                if (-not $held) { throw 'INSTALL_LOCK_TIMEOUT: 別の導入処理が終わりません。しばらく待って再試行してください。' }
                # 待機中に他プロセスが導入を終えている場合がある。
                $marker = Get-YakuInstalledMarker -VersionDir $targetDir
                if ($null -eq $marker -or [string]$marker.manifest_sha256 -ne $manifestHash -or -not (Test-YakuVersionDir -Path $targetDir)) {
                    if (Test-Path -LiteralPath $targetDir) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
                    Install-YakuVersion -SourceDir $sharedVersionDir -TargetDir $targetDir -Manifest $manifest -ManifestHash $manifestHash
                }
            } finally {
                if ($held) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }
        $runDir = $targetDir
        Remove-YakuStaleVersions -VersionsDir $versionsDir -KeepName $targetName
    }
}

$startScript = Join-YakuPath -Base $runDir -Relative 'app/Start-YakuLingo.ps1'
if (!(Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "START_SCRIPT_NOT_FOUND: 起動スクリプトがありません: $startScript"
}

$env:YAKULINGO_SHARED_ROOT = $SharedRoot
Write-YakuBootstrapInfo ("起動します: {0}{1}" -f (Split-Path -Leaf $runDir), $(if ($legacyMode) { '（共有フォルダ上・旧方式）' } else { '（ローカル）' }))
Write-Host ''

if ($NoLaunch) { return $runDir }
& $startScript -NoBrowser:$NoBrowser
