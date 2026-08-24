[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$packageRoot = Split-Path -Parent $appRoot
$passed = 0
function Assert-YakuBrowserTabMode {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Edge browser-tab mode test failed: ' + $Message) }
    $script:passed++
}

$launcher = Get-Content -LiteralPath (Join-Path $appRoot 'Start-YakuLingoApp.ps1') -Raw -Encoding UTF8
$bootstrap = Get-Content -LiteralPath (Join-Path $packageRoot 'bootstrap.ps1') -Raw -Encoding UTF8
$cmd = Get-Content -LiteralPath (Join-Path $packageRoot 'YakuLingo起動.cmd') -Raw -Encoding UTF8
$common = Get-Content -LiteralPath (Join-Path $appRoot 'www\assets\common.js') -Raw -Encoding UTF8
$server = Get-Content -LiteralPath (Join-Path $appRoot 'src\Server.ps1') -Raw -Encoding UTF8
$cat = Get-Content -LiteralPath (Join-Path $appRoot 'www\assets\cat.js') -Raw -Encoding UTF8
$package = Get-Content -LiteralPath (Join-Path $appRoot 'tools\New-YakuPackage.ps1') -Raw -Encoding UTF8
$shortcut = Get-Content -LiteralPath (Join-Path $appRoot 'tools\Create-Desktop-Shortcut.ps1') -Raw -Encoding UTF8

Assert-YakuBrowserTabMode ($launcher.Contains("'--new-tab'") -and $launcher.Contains("+ '/'") -and -not $launcher.Contains("'/cat'") -and -not $launcher.Contains("'--app=' + `$url") -and -not $launcher.Contains('edge-app-profile')) 'main UI must open the independent chooser at / in the normal Edge profile as a regular tab'
Assert-YakuBrowserTabMode ($launcher.Contains("'Local\YakuLingo-BrowserTabLauncher'") -and $launcher.Contains('if (-not $ownsLauncher) { return }') -and $launcher.Contains('ui_client_count') -and $launcher.Contains('ui_all_closing')) 'only one launcher may open Edge and monitor browser presence before shutdown'
Assert-YakuBrowserTabMode ($launcher.Contains('function Test-YakuVisibleEdgeWindow') -and $launcher.Contains('MainWindowHandle') -and $launcher.Contains('$noUiClientSince') -and $launcher.Contains('$noVisibleEdgeSince')) 'the lifecycle owner must release a stale mutex after the YakuLingo UI or every visible Edge window disappears'
Assert-YakuBrowserTabMode ($common.Contains("sessionStorage.getItem('yaku-ui-client-id')") -and $common.Contains("reportUiPresence('open'") -and $common.Contains("reportUiPresence('closing', true)")) 'each tab must report open and closing presence with a tab-scoped ID'
Assert-YakuBrowserTabMode ($server.Contains("'/api/ui/presence'") -and $server.Contains('ui_client_count') -and $server.Contains('ui_all_closing')) 'server must expose only aggregate tab lifecycle state to the launcher'
Assert-YakuBrowserTabMode ($launcher.Contains('& $stopScript') -and $launcher.Contains('Remove-YakuLegacyStartupShortcut')) 'closing all YakuLingo tabs must stop YakuLingo and remove legacy auto-start'
Assert-YakuBrowserTabMode ($bootstrap.Contains('Start-YakuLingoApp.ps1') -and -not $bootstrap.Contains('app/desktop/YakuLingo.exe')) 'shared bootstrap must not launch the custom EXE'
Assert-YakuBrowserTabMode ($cmd.Contains('bootstrap.ps1') -and -not $cmd.Contains('Start-YakuLingoApp.ps1')) 'the single root CMD launcher must enter through bootstrap'
Assert-YakuBrowserTabMode (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'YakuLingo起動.vbs'))) 'the flat launch surface must not expose a second VBScript entry point'
Assert-YakuBrowserTabMode ($common.Contains("window.addEventListener('beforeunload'") -and $common.Contains('translationIsRunning()')) 'close confirmation must be tied to active translation'
Assert-YakuBrowserTabMode ($cat -match 'window\.YakuCat\s*=\s*\{\s*isBusy\s*:' -and ($cat -split "window.addEventListener\('beforeunload'").Count -eq 1) 'CAT must expose busy state without a separate unsaved-edit close prompt'
Assert-YakuBrowserTabMode ($launcher.Contains('Remove-YakuLegacyStartupShortcut') -and -not $launcher.Contains('Create-YakuStartupShortcut')) 'background startup must remain disabled while legacy startup is cleaned safely'
Assert-YakuBrowserTabMode ($package.Contains("^app/(desktop|experiments)(/|`$)") -and $package.Contains('PACKAGE_APP_LAUNCHER_MISSING')) 'packages must omit the custom desktop shell and require the script launcher'
Assert-YakuBrowserTabMode ($launcher.Contains("'YakuLingo起動.cmd'") -and $launcher.Contains("'YakuLingo起動.vbs'")) 'legacy shortcut cleanup must remove both current CMD and retired VBS startup entries'
Assert-YakuBrowserTabMode ($shortcut.Contains("'YakuLingo起動.cmd'") -and -not $shortcut.Contains("'YakuLingo起動.vbs'") -and -not $shortcut.Contains("'desktop\YakuLingo.exe'")) 'the administrative desktop shortcut helper must target the supported CMD launcher'

Write-Host "Edge browser-tab mode tests passed: $passed" -ForegroundColor Green
