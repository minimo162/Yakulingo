[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$SourceRoot,
 [Parameter(Mandatory=$true)][string]$OutputPath,
 [Parameter(Mandatory=$true)][string]$BuildId
)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
$buildPath=Join-Path $source 'app\config\build.txt'
$utf8Bom=New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($buildPath, $BuildId.Trim()+"`r`n", $utf8Bom)
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
Compress-Archive -LiteralPath $source -DestinationPath $OutputPath -CompressionLevel Optimal
& (Join-Path $source 'app\tools\Test-YakuPackage.ps1') -PackagePath $OutputPath
