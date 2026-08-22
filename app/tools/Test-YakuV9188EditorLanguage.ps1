#Requires -Version 5.1
<##
  Exercise the real CAT page in Chromium and verify editor language semantics.

  This deliberately uses the existing width-preview driver because it opens
  cat.html and runs cat.js. The driver waits for preview index 2, so each probe
  contains three rows. Missing Node, Playwright, or Chromium is not a product
  failure: this script reports it as UNMEASURED (exit 3).
##>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9188Unmeasured = 3
$YakuT9188Root = Split-Path -Parent $PSScriptRoot
$YakuT9188Driver = Join-Path $PSScriptRoot 'cat-screen\cat-screen-gate.js'
$YakuT9188Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $YakuT9188Node -or -not (Test-Path -LiteralPath $YakuT9188Driver -PathType Leaf)) {
    Write-Host 'UNMEASURED: node or the Chromium driver is unavailable.'
    exit $YakuT9188Unmeasured
}
$YakuT9188NodeExe = [string]$YakuT9188Node.Source
$YakuT9188ProbeDir = (Split-Path -Parent $YakuT9188Driver).Replace('\', '/')
$null = & $YakuT9188NodeExe -e ("try{require.resolve('playwright',{paths:['" + $YakuT9188ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: Playwright is unavailable.'
    exit $YakuT9188Unmeasured
}
$YakuT9188ChromiumPath = & $YakuT9188NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $YakuT9188ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
$YakuT9188ChromiumExit = $LASTEXITCODE
if ($YakuT9188ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$YakuT9188ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$YakuT9188ChromiumPath) -PathType Leaf)) {
    Write-Host 'UNMEASURED: Playwright Chromium is unavailable.'
    exit $YakuT9188Unmeasured
}

$script:YakuT9188Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9188 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); $script:YakuT9188Failures.Add($Message) | Out-Null }
}

function New-YakuT9188Project {
    param([Parameter(Mandatory=$true)][string]$Direction, [Parameter(Mandatory=$true)][string]$Id)
    $segments = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 3; $i++) {
        $segments.Add([ordered]@{
            index = $i; segment_id = ($Id + '-segment-' + $i); source = ('SOURCE-' + $i); translation = ('TARGET-' + $i)
            kind = 'cell'; location = ('S1, ' + [char](65 + $i) + '1'); confirmed = $false
        }) | Out-Null
    }
    return [ordered]@{
        id = $Id; revision = 1; file_name = 'language-9188.xlsx'; document_format = 'xlsx'; direction = $Direction
        source = 'file'; total = 3; confirmed = 0; segments = $segments.ToArray()
        sheet_layout = @([ordered]@{
            name = 'S1'; default_width = 8.43; default_height = 18.75
            columns = @([ordered]@{ min = 1; max = 3; width = 12; hidden = $false })
            unknown_width_columns = @(); rows = @(); merges = @(); cells = @()
        })
    }
}

function Invoke-YakuT9188Probe {
    param([Parameter(Mandatory=$true)][string]$Direction, [Parameter(Mandatory=$true)][string]$ExpectedSource, [Parameter(Mandatory=$true)][string]$ExpectedTarget, [Parameter(Mandatory=$true)][string]$Work)
    $id = 'language-preview-9188-' + $Direction
    $projectPath = Join-Path $Work ($Direction + '-project.json')
    $outputPath = Join-Path $Work ($Direction + '-result.json')
    $project = New-YakuT9188Project -Direction $Direction -Id $id
    [IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 12 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    & $YakuT9188NodeExe $YakuT9188Driver '--width-preview' (Join-Path $YakuT9188Root 'www') $projectPath $outputPath
    $driverExit = $LASTEXITCODE
    Assert-T9188 -Condition ($driverExit -eq 0 -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) -Message ($Direction + ': Chromium opened cat.html and cat.js')
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { return }
    $result = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($pageError in @($result.errors)) { Write-Host ('  Chromium error: ' + [string]$pageError) }
    foreach ($consoleError in @($result.console)) { Write-Host ('  Chromium console: ' + [string]$consoleError) }
    Assert-T9188 -Condition (@($result.errors).Count -eq 0) -Message ($Direction + ': page errors are empty')
    Assert-T9188 -Condition (@($result.console).Count -eq 0) -Message ($Direction + ': console errors are empty')
    $probe = $result.editorLanguage
    Assert-T9188 -Condition ($null -ne $probe) -Message ($Direction + ': language probe was returned by the real page')
    if ($null -eq $probe) { return }

    $sources = if ($null -eq $probe.sourceLanguages) { @() } else { @($probe.sourceLanguages) }
    $targets = if ($null -eq $probe.targetLanguages) { @() } else { @($probe.targetLanguages) }
    $spellcheckAttributes = if ($null -eq $probe.spellcheckAttributes) { @() } else { @($probe.spellcheckAttributes) }
    $labels = if ($null -eq $probe.accessibleLabels) { @() } else { @($probe.accessibleLabels) }
    $expectedLabel = [string]::Concat('1', [char]0x884C, [char]0x76EE, [char]0x306E, [char]0x8A33, [char]0x6587)
    Assert-T9188 -Condition ($probe.rootLanguage -eq 'ja') -Message ($Direction + ': document root remains lang=ja')
    Assert-T9188 -Condition ($probe.sourceLanguage -eq $ExpectedSource -and $sources.Count -eq 3 -and (@($sources | Where-Object { [string]$_ -ne $ExpectedSource }).Count -eq 0)) -Message ($Direction + ': every source span has lang=' + $ExpectedSource)
    Assert-T9188 -Condition ($probe.targetLanguage -eq $ExpectedTarget -and $targets.Count -eq 3 -and (@($targets | Where-Object { [string]$_ -ne $ExpectedTarget }).Count -eq 0)) -Message ($Direction + ': every target textarea has lang=' + $ExpectedTarget)
    Assert-T9188 -Condition ([bool]$probe.spellcheck -and $spellcheckAttributes.Count -eq 3 -and (@($spellcheckAttributes | Where-Object { [string]$_ -ne 'true' }).Count -eq 0)) -Message ($Direction + ': every target textarea has native spellcheck enabled')
    $labelMismatchCount = 0
    for ($labelIndex = 0; $labelIndex -lt $labels.Count; $labelIndex++) {
        $expectedRowLabel = [string]::Concat([string]($labelIndex + 1), [char]0x884C, [char]0x76EE, [char]0x306E, [char]0x8A33, [char]0x6587)
        if ([string]$labels[$labelIndex] -ne $expectedRowLabel) { $labelMismatchCount++ }
    }
    $accessibleLabelMatches = ([string]$probe.accessibleLabel -eq $expectedLabel)
    if ($labels.Count -ne 3 -or $labelMismatchCount -gt 0 -or -not $accessibleLabelMatches) {
        $expectedCodes = (([char[]]$expectedLabel | ForEach-Object { [int]$_ }) -join ',')
        $actualCodes = (([char[]]([string]$probe.accessibleLabel) | ForEach-Object { [int]$_ }) -join ',')
        Write-Host ('  Accessible labels: ' + ($labels -join '|') + ' expected=' + $expectedLabel + ' first=' + [string]$probe.accessibleLabel + ' count=' + $labels.Count + ' mismatch=' + $labelMismatchCount + ' matches=' + $accessibleLabelMatches + ' expectedLength=' + $expectedLabel.Length + ' firstLength=' + ([string]$probe.accessibleLabel).Length + ' expectedCodes=' + $expectedCodes + ' actualCodes=' + $actualCodes)
    }
    Assert-T9188 -Condition ($labels.Count -eq 3 -and $labelMismatchCount -eq 0 -and $accessibleLabelMatches) -Message ($Direction + ': Japanese accessible label is stable and nonempty')
}

Write-Host 'Test-YakuV9188EditorLanguage'
$YakuT9188Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9188-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $YakuT9188Work -Force
try {
    Invoke-YakuT9188Probe -Direction 'to_en' -ExpectedSource 'ja' -ExpectedTarget 'en' -Work $YakuT9188Work
    Invoke-YakuT9188Probe -Direction 'to_jp' -ExpectedSource 'en' -ExpectedTarget 'ja' -Work $YakuT9188Work
} finally {
    try { Remove-Item -LiteralPath $YakuT9188Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:YakuT9188Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9188EditorLanguage'
    exit 0
}
Write-Host ('FAIL ' + $script:YakuT9188Failures.Count + ' assertion(s)')
foreach ($failure in $script:YakuT9188Failures) { Write-Host ('  - ' + $failure) }
exit 1
