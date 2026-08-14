<#
.SYNOPSIS
  共有フォルダ→ローカル複製起動（bootstrap.ps1）の回帰テスト。

.DESCRIPTION
  一時フォルダに共有ルートを模擬し、初回導入・再利用・更新・改ざん検出・
  オフライン継続・旧版互換・不正ポインタの各経路を検証する。

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
    & (Join-Path $sharedVersion 'app\tools\New-YakuPackage.ps1') -SourceRoot $sharedVersion -OutputPath (Join-Path $sandbox 'pkg.zip') -BuildId $versionName | Out-Null

    Write-Host 'CASE 1: 初回導入'
    $run1 = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run1 -like (Join-Path (Join-Path $local 'versions') ($versionName + '-*'))) 'ローカルへ導入される'
    Assert-YakuBootstrap (-not $run1.StartsWith($shared)) '起動対象が共有フォルダではない'
    Assert-YakuBootstrap (Test-Path -LiteralPath (Join-Path $run1 '.installed')) '.installed マーカーが作られる'

    Write-Host 'CASE 2: 2回目は再複製しない'
    $probe = Join-Path $run1 'app\PROBE.txt'
    [IO.File]::WriteAllText($probe, 'probe')
    $run2 = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run2 -eq $run1) '同じフォルダを再利用する'
    Assert-YakuBootstrap (Test-Path -LiteralPath $probe) '導入済みなら再複製しない'
    Remove-Item -LiteralPath $probe -Force

    Write-Host 'CASE 3: 共有側の更新で別フォルダへ導入し、旧版を掃除する'
    Add-Content -LiteralPath (Join-Path $sharedVersion 'app\DESIGN.md') -Value "`nbootstrap update probe"
    & (Join-Path $sharedVersion 'app\tools\New-YakuPackage.ps1') -SourceRoot $sharedVersion -OutputPath (Join-Path $sandbox 'pkg2.zip') -BuildId $versionName | Out-Null
    $run3 = & $BootstrapPath -SharedRoot $shared -LocalRoot $local -NoLaunch
    Assert-YakuBootstrap ($run3 -ne $run1) '内容が変われば別フォルダへ導入する'
    Assert-YakuBootstrap (-not (Test-Path -LiteralPath $run1)) '使用中でない旧ローカル版を削除する'

    Write-Host 'CASE 4: 共有へ到達できなくても導入済みローカル版で起動する'
    $brokenShared = Join-Path $sandbox 'shared-broken'
    New-Item -ItemType Directory -Path $brokenShared -Force | Out-Null
    Assert-YakuBootstrap ((& $BootstrapPath -SharedRoot $brokenShared -LocalRoot $local -NoLaunch) -eq $run3) 'ローカル版へフォールバックする'
    Assert-YakuBootstrapThrows { & $BootstrapPath -SharedRoot $brokenShared -LocalRoot (Join-Path $sandbox 'local-empty') -NoLaunch } 'SHARED_VERSION_NOT_FOUND' '共有もローカルも無ければ停止する'

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
