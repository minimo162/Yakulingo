[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $tools)
$uploadTool = Join-Path $repo 'New-YakuUploadFolder.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('YakuLingo-upload-boundary-' + [guid]::NewGuid().ToString('N'))
$utf8Bom = New-Object Text.UTF8Encoding($true)
$passed = 0

function Check-YakuUploadBoundary {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "UPLOAD_BOUNDARY_ASSERTION_FAILED: $Message" }
    $script:passed++
}

try {
    $source = Join-Path $work 'source'
    New-Item -ItemType Directory -Path (Join-Path $source 'app\config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $source 'app\tools') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'YakuLingo起動.cmd'), "@echo off`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $source 'bootstrap.ps1'), "param()`r`n", $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $source 'app\Start-YakuLingo.ps1'), "param()`r`n", $utf8Bom)
    # V91.61 added the Edge app-mode launcher and New-YakuPackage.ps1 now refuses
    # to build without it.  This fixture kept only the older launcher, so the test
    # failed on PACKAGE_APP_LAUNCHER_MISSING.  The fixture was stale, not the
    # check: the packaging boundary is what this test exists to protect.
    [IO.File]::WriteAllText((Join-Path $source 'app\Start-YakuLingoApp.ps1'), "param()`r`n", $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $source 'app\config\build.txt'), "TEST`r`n", $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $source 'app\empty-state.txt'), "No bundled language data.`r`n", $utf8Bom)
    Copy-Item -LiteralPath (Join-Path $tools 'New-YakuPackage.ps1') -Destination (Join-Path $source 'app\tools\New-YakuPackage.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $tools 'Test-YakuPackage.ps1') -Destination (Join-Path $source 'app\tools\Test-YakuPackage.ps1') -Force

    New-Item -ItemType Directory -Path (Join-Path $source '_docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $source 'corpus\legacy') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source '_docs\internal.pdf'), 'internal PDF', $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $source 'corpus\legacy\example.md'), 'legacy corpus', $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $source '管理者用_コーパス作成.cmd'), '@echo off', $utf8Bom)

    # A former version folder can still contain historical seeds.  Flat-layout
    # upload must ignore the obsolete folder instead of reviving it.
    $legacy = Join-Path $source 'V00.legacy'
    New-Item -ItemType Directory -Path (Join-Path $legacy 'app') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacy 'app\Start-YakuLingo.ps1'), "param()`r`n", $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $legacy 'app\glossary.csv'), 'old seed,old translation', $utf8Bom)

    $destination = Join-Path $work 'upload'
    $result = & $uploadTool -SourceRoot $source -Destination $destination
    Check-YakuUploadBoundary ([string]$result -eq [string]$destination) 'upload builder must return the requested destination'
    Check-YakuUploadBoundary (-not (Test-Path -LiteralPath (Join-Path $destination '_docs'))) 'root _docs must not be copied'
    Check-YakuUploadBoundary (-not (Test-Path -LiteralPath (Join-Path $destination 'corpus'))) 'root corpus must not be copied'
    Check-YakuUploadBoundary (-not (Test-Path -LiteralPath (Join-Path $destination '管理者用_コーパス作成.cmd'))) 'corpus administrator launcher must not be copied'
    Check-YakuUploadBoundary (-not (Test-Path -LiteralPath (Join-Path $destination 'V00.legacy'))) 'default upload must not revive a seeded previous release'
    Check-YakuUploadBoundary (Test-Path -LiteralPath (Join-Path $destination 'manifest.json') -PathType Leaf) 'clean flat package must receive a root manifest'
    Check-YakuUploadBoundary (Test-Path -LiteralPath (Join-Path $destination 'app\Start-YakuLingo.ps1') -PathType Leaf) 'app must be copied directly under the shared root'

    [IO.File]::WriteAllText((Join-Path $source 'app\glossary.csv'), 'internal term,internal translation', $utf8Bom)
    $caught = ''
    try { $null = & $uploadTool -SourceRoot $source -Destination (Join-Path $work 'rejected-upload') } catch { $caught = [string]$_.Exception.Message }
    Check-YakuUploadBoundary ($caught -match '^PACKAGE_BUNDLED_LANGUAGE_ASSET:') 'a seeded app must fail instead of producing an upload folder'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("Upload folder zero-seed boundary regression passed: {0}" -f $passed) -ForegroundColor Green
