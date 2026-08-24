Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# V91.94 introduced the premium start route. Issue #123 deliberately replaces
# its combined text/Excel surface with the Excel-first contract, so the former
# two-panel and three-step assertions are no longer valid. Keep this historical
# entry point wired to the current UI contract for local regression sweeps.
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsRoot 'Test-YakuPremiumUi.ps1')
Write-Host 'ok - V91.94 route follows the Excel-first UI contract'
