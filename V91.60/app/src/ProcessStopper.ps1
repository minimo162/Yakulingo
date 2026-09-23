[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [int]$WorkerPid = 0,
    [AllowEmptyString()][string]$WorkerStartedAt = '',
    [int]$ExcelPid = 0,
    [AllowEmptyString()][string]$ExcelStartedAt = '',
    [AllowEmptyString()][string]$UploadDir = '',
    [AllowEmptyString()][string]$OutputTempDir = '',
    [AllowEmptyString()][string]$SpecPath = '',
    [ValidateRange(250,10000)][int]$GraceMilliseconds = 1500
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $Root 'src\Runtime.ps1')

# Give cooperative cancellation a short grace period. Only the recorded worker
# and dedicated Excel identities may be terminated; unrelated user Excel stays.
Start-Sleep -Milliseconds $GraceMilliseconds
if (Test-YakuProcessIdentity -Id $WorkerPid -StartTimeUtc $WorkerStartedAt) {
    Stop-Process -Id $WorkerPid -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500
if (Test-YakuProcessIdentity -Id $ExcelPid -StartTimeUtc $ExcelStartedAt) {
    Stop-Process -Id $ExcelPid -Force -ErrorAction SilentlyContinue
}
foreach ($path in @($UploadDir, $OutputTempDir)) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Container)) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not [string]::IsNullOrWhiteSpace($SpecPath) -and (Test-Path -LiteralPath $SpecPath -PathType Leaf)) {
    Remove-Item -LiteralPath $SpecPath -Force -ErrorAction SilentlyContinue
}
