[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$desktop = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw "CSC_NOT_FOUND: $csc" }
$required = @(
    (Join-Path $desktop 'Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $desktop 'Microsoft.Web.WebView2.WinForms.dll'),
    (Join-Path $desktop 'WebView2Loader.dll')
)
foreach ($path in $required) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "WEBVIEW2_DEPENDENCY_MISSING: $path" } }
$references = @(
    'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll',
    'System.Web.Extensions.dll','Microsoft.CSharp.dll',
    (Join-Path $desktop 'Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $desktop 'Microsoft.Web.WebView2.WinForms.dll')
)
$arguments = @('/nologo','/target:winexe','/platform:x64','/optimize+','/warn:4',('/out:' + (Join-Path $desktop 'YakuLingo.exe')))
foreach ($reference in $references) { $arguments += ('/reference:' + $reference) }
$arguments += (Join-Path $desktop 'Program.cs')
& $csc @arguments
if ($LASTEXITCODE -ne 0) { throw "DESKTOP_SHELL_BUILD_FAILED: exit=$LASTEXITCODE" }
Write-Host 'Desktop shell built: desktop\YakuLingo.exe' -ForegroundColor Green
