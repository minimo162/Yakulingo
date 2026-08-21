[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Assert-YakuNavigationContract {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

$serverPath = Join-Path $Root 'src\Server.ps1'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw 'NAVIGATION_SERVER_FILE_MISSING' }
$server = [IO.File]::ReadAllText($serverPath, [Text.Encoding]::UTF8)
$parseErrors = New-Object 'System.Collections.ObjectModel.Collection[System.Management.Automation.Language.ParseError]'
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrors)
Assert-YakuNavigationContract ($parseErrors.Count -eq 0) 'NAVIGATION_SERVER_POWERSHELL_PARSE_FAILED'

$responseFunctions = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -in @('Send-YakuResponse','Serve-YakuStaticFile','Serve-YakuAppPage')
}, $true))
$routeFunctions = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq 'Invoke-YakuRoute'
}, $true))
Assert-YakuNavigationContract ($responseFunctions.Count -eq 3 -and $routeFunctions.Count -eq 1) 'NAVIGATION_SERVER_FUNCTION_CONTRACT_MISSING'

$response = [string](@($responseFunctions | Where-Object { $_.Name -eq 'Send-YakuResponse' })[0].Extent.Text)
$static = [string](@($responseFunctions | Where-Object { $_.Name -eq 'Serve-YakuStaticFile' })[0].Extent.Text)
$page = [string](@($responseFunctions | Where-Object { $_.Name -eq 'Serve-YakuAppPage' })[0].Extent.Text)
$route = [string]$routeFunctions[0].Extent.Text

Assert-YakuNavigationContract ($response -match '\[switch\]\$StaticAsset' -and $response -match '\[string\]\$ETag') 'NAVIGATION_STATIC_RESPONSE_SWITCH_MISSING'
Assert-YakuNavigationContract ($response -match "Cache-Control.*private, no-cache" -and $response -match "Cache-Control.*no-store, no-cache, max-age=0") 'NAVIGATION_CACHE_CONTROL_CONTRACT_MISSING'
Assert-YakuNavigationContract ($response -match "If-None-Match" -and $response -match 'StatusCode = 304' -and $response -match 'ContentLength64 = 0') 'NAVIGATION_CONDITIONAL_304_CONTRACT_MISSING'
Assert-YakuNavigationContract ($static -match 'SHA256' -and $static -match 'ComputeHash' -and $static -match '-StaticAsset' -and $static -match '-ETag') 'NAVIGATION_STATIC_ETAG_WIRING_MISSING'
Assert-YakuNavigationContract ($page -match 'Send-YakuTextResponse -Context \$Context -Text \$html' -and $page -match 'AllowWasm:\$AllowWasm') 'NAVIGATION_HTML_RESPONSE_WIRING_MISSING'
Assert-YakuNavigationContract ($route -match '\$method -eq ''POST'' -and \$path -eq ''/api/upload''' -and $route -match 'Clear-YakuExpiredUploads') 'NAVIGATION_UPLOAD_SWEEP_ROUTE_GUARD_MISSING'
Assert-YakuNavigationContract ($route -notmatch '\$skipUploadSweep' -and $route -notmatch 'Clear-YakuExpiredUploads\s*\r?\n\s*Recover-YakuInterruptedJobs') 'NAVIGATION_UPLOAD_SWEEP_BROAD_GUARD_REINTRODUCED'

$clearCalls = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Clear-YakuExpiredUploads'
}, $true))
Assert-YakuNavigationContract ($clearCalls.Count -eq 1 -and $clearCalls[0].Extent.Text -match 'Clear-YakuExpiredUploads') 'NAVIGATION_UPLOAD_SWEEP_CALL_SCOPE_INVALID'

Write-Host 'Navigation performance server contract passed.'
