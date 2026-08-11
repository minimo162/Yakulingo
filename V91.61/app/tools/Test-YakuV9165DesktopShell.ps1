[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$desktop = Join-Path $appRoot 'desktop'
$source = Join-Path $desktop 'Program.cs'
$exe = Join-Path $desktop 'YakuLingo.exe'
$passed = 0
function Assert-YakuDesktopShell {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Desktop shell test failed: ' + $Message) }
    $script:passed++
}

# YakuLingo.exe はビルド成果物で、git では追跡しない（csc が毎回異なる build stamp を
# 埋めるため、ビルドのたびに差分が出て pull や切り替えを止めていた）。クローン直後や
# 掃除のあとでもこの検査が通るよう、無ければここで作る。
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    Write-Host 'desktop\YakuLingo.exe が無いのでビルドします。' -ForegroundColor Yellow
    & (Join-Path $desktop 'Build-DesktopShell.ps1')
}

foreach ($name in @('YakuLingo.exe','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll','WebView2Loader.dll','WebView2.LICENSE.txt','WebView2.NOTICE.txt')) {
    Assert-YakuDesktopShell (Test-Path -LiteralPath (Join-Path $desktop $name) -PathType Leaf) ("missing dependency: $name")
}
$text = Get-Content -LiteralPath $source -Raw -Encoding UTF8
$serverText = Get-Content -LiteralPath (Join-Path $appRoot 'src\Server.ps1') -Raw -Encoding UTF8
Assert-YakuDesktopShell ($text -match 'ModControl \| ModAlt \| ModNoRepeat, VkJ') 'Ctrl+Alt+J must use RegisterHotKey with MOD_NOREPEAT'
Assert-YakuDesktopShell ($text -notmatch 'SetWindowsHookEx|Clipboard|SendKeys|keybd_event') 'shell must not monitor input or simulate copy'
Assert-YakuDesktopShell ($text -match 'IsTrustedOrigin' -and $text -match 'e\.Cancel = true') 'non-loopback navigation must be blocked'
Assert-YakuDesktopShell ($text -match 'AreDevToolsEnabled = false' -and $text -match 'AreDefaultContextMenusEnabled = false') 'WebView2 developer surfaces must be disabled'
Assert-YakuDesktopShell ($text -match 'desktop-preferences-changed' -and $text -match 'message\.Count != 1') 'WebMessage input must use an exact metadata-only shape'
Assert-YakuDesktopShell ($text -match 'pendingRequested' -and $text -match '文章はまだ送信されていません') 'cold Quick must accept input without automatic send'
Assert-YakuDesktopShell ($text -match 'pendingSnapshot=x\.value' -and $text -match 'window\.__yakuPendingQuickSubmit=true') 'cold Quick must bind the explicit snapshot and wait for readiness'
Assert-YakuDesktopShell ($text -match 'if \(!tutorialCompleted\) desiredRoute = "/tutorial"' -and $text -match 'if \(!tutorialCompleted\) return;\s+string exe') 'first run must show the tutorial before creating shortcuts'
Assert-YakuDesktopShell ($text -match 'TryRunCleanupWatcher' -and $text -match 'PurgeStaleWebViewData' -and $text -match 'ClearBrowsingDataAsync') 'ephemeral WebView data must be cleaned after normal and forced exit'
Assert-YakuDesktopShell ($text -match 'backendProcess\.HasExited' -and $text -match 'backendRetryAfter') 'backend startup failure must be detected and retried'
Assert-YakuDesktopShell ($text -notmatch 'Process\.Start\(uri\.AbsoluteUri\)') 'external WebView navigation must remain blocked instead of opening a browser'
Assert-YakuDesktopShell ($text -match 'CloseReason\.WindowsShutDown') 'Windows shutdown must not be converted into tray hide'
Assert-YakuDesktopShell (([regex]::Matches($text, 'if \(!tutorialCompleted\) \{ OpenHome\(\); return; \}')).Count -ge 2) 'Quick and CAT entry points must not bypass the first-run tutorial'
Assert-YakuDesktopShell ($text -match '画面を準備できませんでした' -and $text -match 'InitializeWebViewAsync') 'WebView2 initialization failure must leave a native recovery message'
Assert-YakuDesktopShell ($text -match 'api/instance' -and $text -match 'active_job_running' -and $serverText -match 'active_job_running') 'exit warning must read active-job metadata from the verified public instance endpoint'
Assert-YakuDesktopShell ($text -match 'MessageBoxDefaultButton\.Button2') 'exit confirmation must default to continuing work'
Assert-YakuDesktopShell ($text -match 'PipeSecurity' -and $text -match 'WindowsIdentity\.GetCurrent\(\)\.User') 'single-instance pipe must be limited to the current user'

$process = Start-Process -FilePath $exe -ArgumentList '--self-test' -Wait -PassThru
Assert-YakuDesktopShell ($process.ExitCode -eq 0) ("WebView2 self-test exit code: $($process.ExitCode)")
Write-Host ("Desktop shell tests passed: {0}" -f $passed) -ForegroundColor Green
