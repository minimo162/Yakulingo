<#
.SYNOPSIS
  Copilot tab reuse, OpenXML null safety, and CAT import UI regression checks.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuRegression {
  param([bool]$Condition, [string]$Message)
  if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
  else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}
$client = [IO.File]::ReadAllText((Join-Path $root 'src/CopilotClient.ps1'))
$processors = [IO.File]::ReadAllText((Join-Path $root 'src/FileProcessors.ps1'))
$cat = [IO.File]::ReadAllText((Join-Path $root 'www/assets/cat.js'))
Write-Host 'CASE 2a: malformed OpenXML input reports a package error without a null-method exception' -ForegroundColor Cyan
. (Join-Path $root 'src/FileProcessors.ps1')
$badPackage = Join-Path ([IO.Path]::GetTempPath()) ('yaku-invalid-' + [guid]::NewGuid().ToString('N') + '.xlsx')
$packageError = $null
try {
  [IO.File]::WriteAllBytes($badPackage, [Text.Encoding]::ASCII.GetBytes('not an OpenXML package'))
  try { $null = Get-YakuOpenXmlFileInfo -Path $badPackage } catch { $packageError = [string]$_.Exception.Message }
} finally { Remove-Item -LiteralPath $badPackage -Force -ErrorAction SilentlyContinue }
Assert-YakuRegression ($packageError -match 'FILE_PACKAGE_OPEN_FAILED' -and $packageError -notmatch 'null-valued') 'malformed package fails with a meaningful error'
$page = [IO.File]::ReadAllText((Join-Path $root 'www/cat.html'))
$styles = [IO.File]::ReadAllText((Join-Path $root 'www/assets/styles.css'))
Write-Host 'CASE 1: startup Copilot target reuse is serialized and recognizes a transitioning existing page' -ForegroundColor Cyan
Assert-YakuRegression ($client -match 'YakuCopilotTargetMutex') 'Copilot target resolution has an inter-process mutex'
Assert-YakuRegression ($client -match 'Get-YakuCopilotKnownTarget') 'runtime-known target can be reused before creating a tab'
Assert-YakuRegression ($client -match 'Page.navigate') 'an existing non-final page can be navigated to Copilot'
Assert-YakuRegression ($client -notmatch 'Copilot tab grace wait timed out; creating a new tab\.' -or $client -match 'YakuCopilotTargetMutex') 'new-tab fallback is behind target reuse protection'
Write-Host 'CASE 2: file import reports a real package failure instead of calling a method on null' -ForegroundColor Cyan
Assert-YakuRegression ($processors -match 'FILE_PACKAGE_OPEN_FAILED') 'OpenXML package open failure has a specific error'
Assert-YakuRegression ($processors -match 'if \(\$null -ne \$archive\).*Dispose' -or $processors -match 'if \(\$archive\) \{.*Dispose') 'OpenXML archive Dispose is null-safe'
Assert-YakuRegression ($processors -match 'inventory.*\$null' -or $processors -match '\$null.*inventory') 'Word inventory is checked before reading Blocks'
Write-Host 'CASE 3: file loading is visible immediately and Copilot detail wraps' -ForegroundColor Cyan
Assert-YakuRegression ($cat -match 'setFileLoading') 'CAT has a dedicated file loading state'
Assert-YakuRegression ($cat -match 'setFileLoading\(true' -and $cat -match 'setFileLoading\(false') 'file loading state starts and ends on both paths'
Assert-YakuRegression ($page -match 'cat-file-loading' -and $page -match 'aria-live') 'loading status is present in the document'
Assert-YakuRegression ($styles -match 'status-detail[^\r\n]*overflow-wrap\s*:\s*anywhere' -or $styles -match 'overflow-wrap\s*:\s*anywhere[^\r\n]*status-detail') 'Copilot detail wraps long text'
if ($script:Failures -gt 0) { throw ('Copilot/import regression test failed. failures=' + $script:Failures) }
Write-Host 'Copilot/import regression test passed.' -ForegroundColor Green
