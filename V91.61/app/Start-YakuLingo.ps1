<#
.SYNOPSIS
  Start the YakuLingo HTMX + PowerShell edition.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Start-YakuLingo.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Start-YakuLingo.ps1 -UseMockTranslator
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$UseMockTranslator,
    # V91.61: コーパス作成用の管理画面を開く。管理者用ランチャーからのみ渡す。
    # 一般利用者の起動経路では常に無効であり、管理用の API も画面も登録されない。
    [switch]$Admin,
    # D2-5: .installed スタンプがあっても全量検査したいとき（開発・調査用）に付ける。
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-YakuRelativePathForStartup {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path
    )
    try {
        $base = (Resolve-Path -LiteralPath $Root).Path
        $full = (Resolve-Path -LiteralPath $Path).Path
        if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($base.Length).TrimStart([char[]]@('\','/'))
        }
    } catch {}
    return $Path
}

function Get-YakuStartupGateBomTargets {
    <#
      D2-5: 起動のたびに141本(.ps1)+9本(prompts)を検査していたが、実行時に読むのは
      その一部だけだった（tools は102本中2本のみ）。対象を実際に読むファイルへ
      絞る。src配下は SrcModules.ps1 の一覧＋Server.ps1＋JobObject.ps1＋一覧自身で
      全37本（= src の全ファイル。tools\Test-YakuV9161SrcModuleLoad.ps1 が
      「一覧から漏れた src ファイルが無い」ことを別途守っている）。
    #>
    param([Parameter(Mandatory=$true)][string]$Root)
    $targets = New-Object System.Collections.Generic.List[string]
    $srcDir = Join-Path $Root 'src'
    if (Test-Path -LiteralPath $srcDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' -ErrorAction Stop)) {
            $targets.Add($file.FullName) | Out-Null
        }
    }
    foreach ($rel in @('Start-YakuLingo.ps1', 'Start-YakuLingoApp.ps1', 'tools\Prepare-Copilot.ps1', 'tools\Stop-YakuLingo.ps1')) {
        $path = Join-Path $Root $rel
        if (Test-Path -LiteralPath $path -PathType Leaf) { $targets.Add($path) | Out-Null }
    }
    $promptDir = Join-Path $Root 'prompts'
    if (Test-Path -LiteralPath $promptDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $promptDir -Filter '*.txt' -ErrorAction Stop)) {
            $targets.Add($file.FullName) | Out-Null
        }
    }
    return $targets.ToArray()
}

function Test-YakuUtf8BomForStartup {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Files)

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($Files)) {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) {
            $violations.Add((Get-YakuRelativePathForStartup -Root $Root -Path $file)) | Out-Null
        }
    }
    if ($violations.Count -gt 0) {
        $list = ($violations.ToArray() -join "`n  - ")
        throw ("エンコーディングエラー: 次のファイルをUTF-8 BOM付きで保存してください（tools\Repair-YakuEncoding.ps1 で一括修復できます）:`n  - " + $list)
    }
}

function Test-YakuPowerShellSyntax {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Files)

    $parserType = [type]'System.Management.Automation.Language.Parser'
    if ($null -eq $parserType) { return }

    foreach ($file in @($Files)) {
        if ($file -notlike '*.ps1') { continue }
        if (!(Test-Path -LiteralPath $file)) { throw "必要なファイルがありません: $file" }
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            $first = $errors[0]
            throw "PowerShell構文エラー: $file`n$($first.Message)`nLine $($first.Extent.StartLineNumber), Column $($first.Extent.StartColumnNumber)"
        }
    }
}

function Test-YakuStartupInstalledStamp {
    <#
      D2-5 (2)(3): bootstrap.ps1 は導入時に manifest 記載の全ファイルを個別に
      SHA-256+サイズで照合してから .installed を書く（Test-YakuTreeAgainstManifest）。
      配置先はバージョン名とmanifestハッシュで決まり、中身が変われば別フォルダに
      なる（同じ内容が後から静かに書き換わることはない）ので、.installed が
      そのフォルダに存在し、manifest_sha256 が空でなければ、この app/ 配下は
      既に全量検査済みと信頼できる。ここで再びハッシュを取り直すと、避けたい
      重い検査そのものを再現してしまうので、スタンプの実在だけを見る
      （「検証済みスタンプ」方式。-Verify で無視して常に検査できる）。
    #>
    param([Parameter(Mandatory=$true)][string]$Root)
    try {
        $versionDir = Split-Path -Parent $Root
        $markerPath = Join-Path $versionDir '.installed'
        if (!(Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
        $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$marker.manifest_sha256)) { return $false }
        # 補足(D2-5): スタンプの build_id と、いま実際に起動しようとしている
        # config\build.txt を1回だけ突き合わせる。重いSHA-256の再照合はしないが、
        # 「別バージョンのスタンプを読んでいないか」という単純な取り違えだけは
        # ここで拾える。
        $buildTxtPath = Join-Path $Root 'config\build.txt'
        if (!(Test-Path -LiteralPath $buildTxtPath -PathType Leaf)) { return $false }
        $diskBuildId = ([string](Get-Content -LiteralPath $buildTxtPath -Raw -Encoding UTF8)).Trim()
        if ([string]::IsNullOrWhiteSpace($diskBuildId)) { return $false }
        return [string]::Equals([string]$marker.build_id, $diskBuildId, [System.StringComparison]::Ordinal)
    } catch { return $false }
}

if ($UseMockTranslator) {
    $env:YAKULINGO_MOCK = '1'
} elseif ($env:YAKULINGO_MOCK -eq '1') {
    Remove-Item Env:YAKULINGO_MOCK -ErrorAction SilentlyContinue
}

if ($Verify -or -not (Test-YakuStartupInstalledStamp -Root $root)) {
    $gateFiles = Get-YakuStartupGateBomTargets -Root $root
    Test-YakuUtf8BomForStartup -Root $root -Files $gateFiles
    Test-YakuPowerShellSyntax -Root $root -Files $gateFiles
} else {
    Write-Host 'Startup file verification skipped (installed stamp present; pass -Verify to force it).' -ForegroundColor DarkGray
}

. (Join-Path $root 'src\JobObject.ps1')
$jobObjectEnabled = Initialize-YakuJobObject

$openBrowser = -not $NoBrowser.IsPresent

Write-Host "YakuLingo HTMX + PowerShell edition" -ForegroundColor Cyan
Write-Host "App Root      : $root"
Write-Host "Preferred URL : http://127.0.0.1:$Port/"
Write-Host "Port fallback : enabled. If $Port is busy, the next available port will be used." -ForegroundColor Yellow
if ($env:YAKULINGO_MOCK -eq '1') {
    Write-Host "Translator    : mock mode (Copilot is not called)" -ForegroundColor Yellow
} else {
    Write-Host "Translator    : Microsoft Edge + M365 Copilot automation"
    Write-Host "Startup      : opens Copilot and enables Translate after the input box is ready."
}
Write-Host "Stop          : Ctrl+C or close this console."
if ($jobObjectEnabled) { Write-Host "Process guard : enabled (child processes stop with this console)." -ForegroundColor Green }
Write-Host ''

& (Join-Path $root 'src\Server.ps1') -Port $Port -OpenBrowser:$openBrowser -Admin:$Admin
