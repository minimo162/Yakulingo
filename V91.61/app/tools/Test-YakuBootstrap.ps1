<#
.SYNOPSIS
  共有フォルダ→ローカル複製起動（bootstrap.ps1）の回帰テスト。

.DESCRIPTION
  一時フォルダに共有ルートを模擬し、初回導入・再利用・更新・改ざん検出・
  オフライン継続・旧版互換・不正ポインタ・ローカル破損修復・manifest境界を検証する。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuBootstrap.ps1
#>
[CmdletBinding()]
param(
    [string]$VersionRoot = '',
    [string]$BootstrapPath = ''
)

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
if ([string]::IsNullOrWhiteSpace($VersionRoot)) { $VersionRoot = Split-Path -Parent $appRoot }
if ([string]::IsNullOrWhiteSpace($BootstrapPath)) { $BootstrapPath = Join-Path (Split-Path -Parent $VersionRoot) 'bootstrap.ps1' }
if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
    throw "BOOTSTRAP_NOT_FOUND: bootstrap.ps1 が見つかりません: $BootstrapPath"
}

$script:Failures = 0
function Assert-YakuBootstrap {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}
function Assert-YakuBootstrapThrows {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = [string]$_.Exception.Message }
    Assert-YakuBootstrap (-not [string]::IsNullOrWhiteSpace($caught) -and $caught -match $Pattern) $Message
}
function Copy-YakuPublishedTree {
    param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        if ($relative -match '(?i)^app/experiments(/|$)') { continue }
        $target = Join-Path $Destination $relative.Replace('/', '\')
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

$versionName = Split-Path -Leaf $VersionRoot
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('Yaku-bootstrap-' + [guid]::NewGuid().ToString('N'))
$shared = Join-Path $sandbox 'shared'
$local = Join-Path $sandbox 'local'
try {
    New-Item -ItemType Directory -Path $shared -Force | Out-Null
    Copy-YakuPublishedTree -Source $VersionRoot -Destination (Join-Path $shared $versionName)
    [IO.File]::WriteAllText((Join-Path $shared 'current.txt'), ($versionName + "`r`n"), (New-Object Text.UTF8Encoding($true)))
    $sharedVersion = Join-Path $shared $versionName
    $newPackage = Join-Path $sharedVersion 'app\tools\New-YakuPackage.ps1'
    & $newPackage -SourceRoot $sharedVersion -OutputPath (Join-Path $sandbox 'pkg.zip') -BuildId $versionName | Out-Null

    Write-Host 'CASE 0: package生成側も危険なbuild_idを拒否する'
    $buildBefore = [IO.File]::ReadAllText((Join-Path $sharedVersion 'app\config\build.txt'))
    Assert-YakuBootstrapThrows { & $newPackage -SourceRoot $sharedVersion -BuildId '..\escape' -ManifestOnly } 'PACKAGE_BUILD_ID_INVALID' 'パスへ使えないBuildIdをmanifest生成前に拒否する'
    Assert-YakuBootstrap ([IO.File]::ReadAllText((Join-Path $sharedVersion 'app\config\build.txt')) -eq $buildBefore) '不正BuildIdではbuild.txtを書き換えない'

    Write-Host 'CASE 1: 初回導入'
    $run1 = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run1 -like (Join-Path (Join-Path $local 'versions') ($versionName + '-*'))) 'ローカルへ導入される'
    Assert-YakuBootstrap (-not $run1.StartsWith($shared)) '起動対象が共有フォルダではない'
    Assert-YakuBootstrap (Test-Path -LiteralPath (Join-Path $run1 '.installed')) '.installed マーカーが作られる'

    Write-Host 'CASE 2: 正常な導入済み版は再複製せず再利用する'
    $markerPath = Join-Path $run1 '.installed'
    $markerBefore = [IO.File]::ReadAllText($markerPath)
    $markerTimeBefore = (Get-Item -LiteralPath $markerPath).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    $run2 = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run2 -eq $run1) '同じフォルダを再利用する'
    Assert-YakuBootstrap ([IO.File]::ReadAllText($markerPath) -eq $markerBefore) '正常なら導入マーカーを書き直さない'
    Assert-YakuBootstrap ((Get-Item -LiteralPath $markerPath).LastWriteTimeUtc -eq $markerTimeBefore) '正常なら再インストールしない'

    Write-Host 'CASE 2B: 導入後にローカル版が壊れたら共有側から自己修復する'
    $localVictim = Join-Path $run1 'app\prompts\text_translate_full_to_en.txt'
    $sharedVictim = Join-Path $sharedVersion 'app\prompts\text_translate_full_to_en.txt'
    $expectedVictimHash = (Get-FileHash -LiteralPath $sharedVictim -Algorithm SHA256).Hash
    $bytes = [IO.File]::ReadAllBytes($localVictim)
    $bytes[100] = [byte]($bytes[100] -bxor 0x01)
    [IO.File]::WriteAllBytes($localVictim, $bytes)
    $extraLocalFile = Join-Path $run1 'app\UNLISTED-PROBE.txt'
    [IO.File]::WriteAllText($extraLocalFile, 'must be removed by repair')
    $run2b = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run2b -eq $run1) '同じmanifestの正式フォルダへ修復する'
    Assert-YakuBootstrap ((Get-FileHash -LiteralPath $localVictim -Algorithm SHA256).Hash -eq $expectedVictimHash) '改変された列挙ファイルを共有側の正しい内容へ戻す'
    Assert-YakuBootstrap (-not (Test-Path -LiteralPath $extraLocalFile)) 'manifest未記載ファイルも修復時に除去する'

    Write-Host 'CASE 3: 共有側の更新で別フォルダへ導入し、旧版を掃除する'
    Add-Content -LiteralPath (Join-Path $sharedVersion 'app\DESIGN.md') -Value "`nbootstrap update probe"
    & $newPackage -SourceRoot $sharedVersion -OutputPath (Join-Path $sandbox 'pkg2.zip') -BuildId $versionName | Out-Null
    $run3 = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run3 -ne $run1) '内容が変われば別フォルダへ導入する'
    Assert-YakuBootstrap (-not (Test-Path -LiteralPath $run1)) '使用中でない旧ローカル版を削除する'

    Write-Host 'CASE 4: 共有へ到達できなくても完全性確認済みのローカル版で起動する'
    $brokenShared = Join-Path $sandbox 'shared-broken'
    New-Item -ItemType Directory -Path $brokenShared -Force | Out-Null
    Assert-YakuBootstrap ((& $BootstrapPath -SharedRoot $brokenShared -LocalRoot $local -NoLaunch) -eq $run3) '正常なローカル版へフォールバックする'
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $brokenShared -LocalRoot (Join-Path $sandbox 'local-empty') -NoLaunch } 'SHARED_VERSION_NOT_FOUND' '共有もローカルも無ければ停止する'

    Write-Host 'CASE 4B: オフライン時は壊れたローカル版を起動しない'
    $offlineCorrupt = Join-Path $sandbox 'local-offline-corrupt'
    Copy-Item -LiteralPath $local -Destination $offlineCorrupt -Recurse -Force
    $offlineVersion = @(Get-ChildItem -LiteralPath (Join-Path $offlineCorrupt 'versions') -Directory | Select-Object -First 1)[0].FullName
    $offlineVictim = Join-Path $offlineVersion 'app\prompts\text_translate_full_to_en.txt'
    [IO.File]::AppendAllText($offlineVictim, 'corrupt')
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $brokenShared -LocalRoot $offlineCorrupt -NoLaunch } 'SHARED_VERSION_NOT_FOUND' '共有が無いとき改変済みローカル版へフォールバックしない'

    Write-Host 'CASE 5: 改ざんされた共有パッケージは導入しない'
    $tampered = Join-Path $sandbox 'shared-tampered'
    Copy-Item -LiteralPath $shared -Destination $tampered -Recurse -Force
    $victim = Join-Path $tampered ($versionName + '\app\prompts\text_translate_full_to_en.txt')
    $bytes = [IO.File]::ReadAllBytes($victim)
    $bytes[100] = [byte]($bytes[100] -bxor 0x01)
    [IO.File]::WriteAllBytes($victim, $bytes)
    $tamperLocal = Join-Path $sandbox 'local-tampered'
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $tampered -LocalRoot $tamperLocal -NoLaunch } 'INSTALL_VERIFY_FAILED' '内容不一致を検出して導入を中止する'
    Assert-YakuBootstrap (@(Get-ChildItem -LiteralPath (Join-Path $tamperLocal 'versions') -Directory -ErrorAction SilentlyContinue).Count -eq 0) '失敗時に中途半端なフォルダを残さない'

    Write-Host 'CASE 5B: manifestのパストラバーサルと不正build_idを配布境界で拒否する'
    $unsafePathShared = Join-Path $sandbox 'shared-unsafe-path'
    Copy-Item -LiteralPath $shared -Destination $unsafePathShared -Recurse -Force
    $unsafePathManifestPath = Join-Path $unsafePathShared ($versionName + '\manifest.json')
    $unsafePathManifest = [IO.File]::ReadAllText($unsafePathManifestPath) | ConvertFrom-Json
    $unsafePathManifest.files[0].path = '../escaped.txt'
    [IO.File]::WriteAllText($unsafePathManifestPath, ($unsafePathManifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
    $unsafePathLocal = Join-Path $sandbox 'local-unsafe-path'
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $unsafePathShared -LocalRoot $unsafePathLocal -NoLaunch } 'MANIFEST_PATH_INVALID|MANIFEST_PATH_ESCAPE' '.. を含むmanifestパスをコピー前に拒否する'
    Assert-YakuBootstrap (-not (Test-Path -LiteralPath (Join-Path $unsafePathLocal 'escaped.txt'))) '拒否したmanifestからインストール先外へ書き込まない'

    $unsafeBuildShared = Join-Path $sandbox 'shared-unsafe-build'
    Copy-Item -LiteralPath $shared -Destination $unsafeBuildShared -Recurse -Force
    $unsafeBuildManifestPath = Join-Path $unsafeBuildShared ($versionName + '\manifest.json')
    $unsafeBuildManifest = [IO.File]::ReadAllText($unsafeBuildManifestPath) | ConvertFrom-Json
    $unsafeBuildManifest.build_id = '../escape'
    $unsafeBuildManifest.version = '../escape'
    [IO.File]::WriteAllText($unsafeBuildManifestPath, ($unsafeBuildManifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $unsafeBuildShared -LocalRoot (Join-Path $sandbox 'local-unsafe-build') -NoLaunch } 'MANIFEST_BUILD_ID_INVALID' 'フォルダ名へ使えないmanifest build_idを拒否する'

    Write-Host 'CASE 5C: manifestの重複パスと不正SHAを拒否する'
    $duplicateShared = Join-Path $sandbox 'shared-duplicate-manifest'
    Copy-Item -LiteralPath $shared -Destination $duplicateShared -Recurse -Force
    $duplicateManifestPath = Join-Path $duplicateShared ($versionName + '\manifest.json')
    $duplicateManifest = [IO.File]::ReadAllText($duplicateManifestPath) | ConvertFrom-Json
    $duplicateManifest.files[1].path = [string]$duplicateManifest.files[0].path
    [IO.File]::WriteAllText($duplicateManifestPath, ($duplicateManifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $duplicateShared -LocalRoot (Join-Path $sandbox 'local-duplicate') -NoLaunch } 'MANIFEST_PATH_DUPLICATE' '大文字小文字を同一視してmanifest重複パスを拒否する'

    $badShaShared = Join-Path $sandbox 'shared-bad-sha'
    Copy-Item -LiteralPath $shared -Destination $badShaShared -Recurse -Force
    $badShaManifestPath = Join-Path $badShaShared ($versionName + '\manifest.json')
    $badShaManifest = [IO.File]::ReadAllText($badShaManifestPath) | ConvertFrom-Json
    $badShaManifest.files[0].sha256 = 'not-a-sha256'
    [IO.File]::WriteAllText($badShaManifestPath, ($badShaManifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $badShaShared -LocalRoot (Join-Path $sandbox 'local-bad-sha') -NoLaunch } 'MANIFEST_SHA256_INVALID' '形式不正のSHA256を検証前に拒否する'

    Write-Host 'CASE 6: manifest の無い旧版は共有フォルダ上で直接起動する'
    $legacyShared = Join-Path $sandbox 'shared-legacy'
    Copy-Item -LiteralPath $shared -Destination $legacyShared -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $legacyShared 'manifest.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $legacyShared ($versionName + '\manifest.json')) -Force
    $run6 = & $BootstrapPath -SharedRoot $legacyShared -LocalRoot (Join-Path $sandbox 'local-legacy') -NoLaunch
    Assert-YakuBootstrap ($run6 -eq (Join-Path $legacyShared $versionName)) '旧方式（共有フォルダ上で実行）へ退避する'

    Write-Host 'CASE 7: current.txt が不正でも実在する版で起動する'
    $badPointer = Join-Path $sandbox 'shared-badptr'
    Copy-Item -LiteralPath $shared -Destination $badPointer -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $badPointer 'current.txt'), "V99.99`r`n", (New-Object Text.UTF8Encoding($true)))
    $badLocal = Join-Path $sandbox 'local-badptr'
    $run7 = & $BootstrapPath -SharedRoot $badPointer -LocalRoot $badLocal -NoLaunch
    Assert-YakuBootstrap ($run7 -like (Join-Path (Join-Path $badLocal 'versions') ($versionName + '-*'))) '実在する版へフォールバックする'

    Write-Host 'CASE 8: 旧共有コーパスがあっても読み込まず、環境変数を消す'
    Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue
    $corpusLocal = Join-Path $sandbox 'local-corpus'
    $corpusShared = Join-Path $shared 'corpus'
    New-Item -ItemType Directory -Path (Join-Path $corpusShared '2026-08-04\英文短信') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $corpusShared '2026-08-04\英文短信\a.md'), "<!--yaku-page:1-->`nEquity ratio increased.")
    [IO.File]::WriteAllText((Join-Path $corpusShared '2026-08-04\manifest.json'),
        (@{ schema='yaku-corpus-1'; corpus_version='2026-08-04'; entries=@(@{ id='aaaaaaaa'; markdown='英文短信/a.md' }) } | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $corpusShared 'current.txt'), "2026-08-04`r`n")
    $cachedCorpus = Join-Path $corpusLocal 'corpus\2025-legacy\英文短信'
    New-Item -ItemType Directory -Path $cachedCorpus -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cachedCorpus 'cached.md'), 'cached legacy corpus')
    $env:YAKULINGO_CORPUS_DIR = Join-Path $corpusLocal 'corpus\2025-legacy'
    $null = & $BootstrapPath -SharedRoot $shared -LocalRoot $corpusLocal -NoLaunch
    Assert-YakuBootstrap ([string]::IsNullOrWhiteSpace([string]$env:YAKULINGO_CORPUS_DIR)) '共有・キャッシュのコーパスがあっても環境変数を設定しない'
    Assert-YakuBootstrap (-not (Test-Path -LiteralPath (Join-Path $corpusLocal 'corpus\2026-08-04'))) '共有コーパスをローカルへ複製しない'
    Assert-YakuBootstrap (Test-Path -LiteralPath (Join-Path $cachedCorpus 'cached.md') -PathType Leaf) '旧キャッシュは利用せず、利用者データとして勝手に削除もしない'
    Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -gt 0) {
    Write-Host "Bootstrap test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'Bootstrap regression passed.' -ForegroundColor Green