[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$probeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$programPath = Join-Path $probeRoot 'Program.cs'
$readmePath = Join-Path $probeRoot 'README.md'
$program = [IO.File]::ReadAllText($programPath)
$readme = [IO.File]::ReadAllText($readmePath)
$passed = 0
$mojibakeMarkers = @('騾', '繧', '荳', '縺', '蛹', '莠', '隱', '髫', '譁', '螟')

function Assert-ProbeContract {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "PROBE_CONTRACT_FAILED: $Name" }
    $script:passed++
    Write-Host "PASS $Name"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $probeRoot 'Build-Probe.ps1')
if ($LASTEXITCODE -ne 0) { throw "PROBE_BUILD_FAILED: exit=$LASTEXITCODE" }

$bin = Join-Path $probeRoot 'bin'
Assert-ProbeContract (Test-Path -LiteralPath (Join-Path $bin 'WebView2CopilotProbe.exe') -PathType Leaf) 'probe exe exists'
Assert-ProbeContract (Test-Path -LiteralPath (Join-Path $bin 'Microsoft.Web.WebView2.Core.dll') -PathType Leaf) 'WebView2 Core copied'
Assert-ProbeContract (Test-Path -LiteralPath (Join-Path $bin 'Microsoft.Web.WebView2.WinForms.dll') -PathType Leaf) 'WebView2 WinForms copied'
Assert-ProbeContract (Test-Path -LiteralPath (Join-Path $bin 'WebView2Loader.dll') -PathType Leaf) 'native loader copied'
Assert-ProbeContract ($program.Contains('https://m365.cloud.microsoft/chat/')) 'Copilot URL is explicit'
Assert-ProbeContract ($program.Contains('primary.EnsureCoreWebView2Async(environment)') -and $program.Contains('secondary.EnsureCoreWebView2Async(environment)')) 'both controls share one environment'
Assert-ProbeContract ($program.Contains('String.Equals(aPath, bPath, StringComparison.OrdinalIgnoreCase)')) 'profile paths are compared'
Assert-ProbeContract ($program.Contains('browserSplit.Panel2Collapsed')) 'secondary hide and restore control exists'
Assert-ProbeContract ($program.Contains('ExecuteScriptAsync(script)') -and -not $program.Contains('.value')) 'DOM probe avoids input values'
Assert-ProbeContract ($program.Contains('GetCookiesAsync') -and -not $program.Contains('cookie.Value')) 'cookie probe avoids cookie values'
Assert-ProbeContract (-not $program.Contains('submit()') -and -not $program.Contains('dispatchEvent')) 'no scripted submit path'
Assert-ProbeContract ($readme.Contains('SAME_PROFILE=True') -and $readme.Contains('COOKIE_A/B')) 'README states diagnostic verification contract'
Assert-ProbeContract ($readme.Contains('MFA') -and $readme.Contains('8,000')) 'README documents migration gates'
Assert-ProbeContract ($program.Contains('--auto-diagnose') -and $program.Contains('RunAutoDiagnoseAsync')) 'auto diagnose command exists'
Assert-ProbeContract ($program.Contains('TimeSpan.FromSeconds(60)') -and $program.Contains('WaitForBothDocumentsAsync')) 'auto navigation has 60 second limit'
Assert-ProbeContract ($program.Contains('domBeforeHide') -and $program.Contains('hiddenRestore') -and $program.Contains('cookies')) 'auto result covers required diagnostics'
Assert-ProbeContract ($program.Contains('File.WriteAllText(autoDiagnosePath') -and $readme.Contains('--auto-diagnose')) 'auto JSON output is documented'
foreach ($marker in $mojibakeMarkers) {
    Assert-ProbeContract (-not $program.Contains($marker) -and -not $readme.Contains($marker)) ("no mojibake marker U+{0:X4}" -f [int][char]$marker)
}

$textFiles = @(
    (Join-Path $probeRoot 'Program.cs'),
    (Join-Path $probeRoot 'README.md'),
    (Join-Path $probeRoot 'Build-Probe.ps1'),
    (Join-Path $probeRoot 'Test-Probe.ps1'),
    (Join-Path $probeRoot '.gitignore')
)
foreach ($textFile in $textFiles) {
    $bytes = [IO.File]::ReadAllBytes($textFile)
    Assert-ProbeContract ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) ((Split-Path -Leaf $textFile) + ' has UTF-8 BOM')
    $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    Assert-ProbeContract (-not [Text.RegularExpressions.Regex]::IsMatch($text, '(?<!\r)\n')) ((Split-Path -Leaf $textFile) + ' uses CRLF')
}

Write-Host "WebView2 Copilot probe checks passed: $passed" -ForegroundColor Green
