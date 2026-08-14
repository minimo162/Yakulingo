[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$versionRoot = Split-Path -Parent $appRoot
$repoRoot = Split-Path -Parent $versionRoot
$passed = 0
function Assert-YakuBrowserTabMode {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Edge browser-tab mode test failed: ' + $Message) }
    $script:passed++
}

$launcher = Get-Content -LiteralPath (Join-Path $appRoot 'Start-YakuLingoApp.ps1') -Raw -Encoding UTF8
$bootstrap = Get-Content -LiteralPath (Join-Path $repoRoot 'bootstrap.ps1') -Raw -Encoding UTF8
$cmd = Get-Content -LiteralPath (Join-Path $versionRoot 'YakuLingo起動.cmd') -Raw -Encoding UTF8
$common = Get-Content -LiteralPath (Join-Path $appRoot 'www\assets\common.js') -Raw -Encoding UTF8
$server = Get-Content -LiteralPath (Join-Path $appRoot 'src\Server.ps1') -Raw -Encoding UTF8
$cat = Get-Content -LiteralPath (Join-Path $appRoot 'www\assets\cat.js') -Raw -Encoding UTF8
$desktop = Get-Content -LiteralPath (Join-Path $appRoot 'src\DesktopIntegration.ps1') -Raw -Encoding UTF8
$package = Get-Content -LiteralPath (Join-Path $appRoot 'tools\New-YakuPackage.ps1') -Raw -Encoding UTF8
$shortcut = Get-Content -LiteralPath (Join-Path $appRoot 'tools\Create-Desktop-Shortcut.ps1') -Raw -Encoding UTF8

Assert-YakuBrowserTabMode ($launcher.Contains("'--new-tab'") -and $launcher.Contains("'/cat'") -and -not $launcher.Contains("'--app=' + `$url") -and -not $launcher.Contains('edge-app-profile')) 'main UI must open the canonical /cat URL in the normal Edge profile as a regular tab'
Assert-YakuBrowserTabMode ($launcher.Contains("'Local\YakuLingo-BrowserTabLauncher'") -and $launcher.Contains('if (-not $ownsLauncher) { return }') -and $launcher.Contains('ui_client_count') -and $launcher.Contains('ui_all_closing')) 'only one launcher may open Edge and monitor browser presence before shutdown'
Assert-YakuBrowserTabMode ($common.Contains("sessionStorage.getItem('yaku-ui-client-id')") -and $common.Contains("reportUiPresence('open'") -and $common.Contains("reportUiPresence('closing', true)")) 'each tab must report open and closing presence with a tab-scoped ID'
Assert-YakuBrowserTabMode ($server.Contains("'/api/ui/presence'") -and $server.Contains('ui_client_count') -and $server.Contains('ui_all_closing')) 'server must expose only aggregate tab lifecycle state to the launcher'
Assert-YakuBrowserTabMode ($launcher.Contains('& $stopScript') -and $launcher.Contains('Remove-YakuLegacyStartupShortcut')) 'closing all YakuLingo tabs must stop YakuLingo and remove legacy auto-start'
Assert-YakuBrowserTabMode ($bootstrap.Contains('Start-YakuLingoApp.ps1') -and -not $bootstrap.Contains('app/desktop/YakuLingo.exe')) 'shared bootstrap must not launch the custom EXE'
Assert-YakuBrowserTabMode ($cmd.Contains('Start-YakuLingoApp.ps1')) 'the direct CMD launcher must use the browser-tab launcher'
Assert-YakuBrowserTabMode (-not (Test-Path -LiteralPath (Join-Path $versionRoot 'YakuLingo起動.vbs')) -and -not (Test-Path -LiteralPath (Join-Path $repoRoot 'YakuLingo起動.vbs'))) 'current and shared launch surfaces must not expose a second VBScript entry point'
Assert-YakuBrowserTabMode ($common.Contains("window.addEventListener('beforeunload'") -and $common.Contains('translationIsRunning()')) 'close confirmation must be tied to active translation'
Assert-YakuBrowserTabMode ($cat.Contains('window.YakuCat = { isBusy:') -and ($cat -split "window.addEventListener\('beforeunload'").Count -eq 1) 'CAT must expose busy state without a separate unsaved-edit close prompt'
Assert-YakuBrowserTabMode ($desktop.Contains('startup = $false') -and $desktop.Contains('startup_enabled = $false')) 'background startup must remain disabled'
Assert-YakuBrowserTabMode ($package.Contains("^app/(desktop|experiments)(/|`$)") -and $package.Contains('PACKAGE_APP_LAUNCHER_MISSING')) 'packages must omit the custom desktop shell and require the script launcher'
Assert-YakuBrowserTabMode ($desktop.Contains("'YakuLingo起動.cmd'") -and -not $desktop.Contains("'YakuLingo起動.vbs'")) 'desktop and start-menu shortcuts must target the supported CMD launcher'
Assert-YakuBrowserTabMode ($shortcut.Contains("'YakuLingo起動.cmd'") -and -not $shortcut.Contains("'YakuLingo起動.vbs'") -and -not $shortcut.Contains("'desktop\YakuLingo.exe'")) 'the administrative desktop shortcut helper must target the supported CMD launcher'

Write-Host "Edge browser-tab mode tests passed: $passed" -ForegroundColor Green
