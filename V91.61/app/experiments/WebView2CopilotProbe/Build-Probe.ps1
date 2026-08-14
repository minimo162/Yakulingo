[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$probeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $probeRoot '..\..\desktop'))
$bin = Join-Path $probeRoot 'bin'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    throw "CSC_NOT_FOUND: $csc"
}

$webViewFiles = @(
    'Microsoft.Web.WebView2.Core.dll',
    'Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll'
)

New-Item -ItemType Directory -Force -Path $bin | Out-Null
foreach ($file in $webViewFiles) {
    $source = Join-Path $desktopRoot $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "WEBVIEW2_DEPENDENCY_MISSING: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $bin $file) -Force
}

$references = @(
    'System.dll',
    'System.Core.dll',
    'System.Drawing.dll',
    'System.Windows.Forms.dll',
    'System.Web.Extensions.dll',
    (Join-Path $bin 'Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $bin 'Microsoft.Web.WebView2.WinForms.dll')
)

$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/warn:4',
    ('/out:' + (Join-Path $bin 'WebView2CopilotProbe.exe'))
)
foreach ($reference in $references) {
    $arguments += ('/reference:' + $reference)
}
$arguments += (Join-Path $probeRoot 'Program.cs')

& $csc @arguments
if ($LASTEXITCODE -ne 0) {
    throw "WEBVIEW2_COPILOT_PROBE_BUILD_FAILED: exit=$LASTEXITCODE"
}

Write-Host 'Built: experiments\WebView2CopilotProbe\bin\WebView2CopilotProbe.exe' -ForegroundColor Green
