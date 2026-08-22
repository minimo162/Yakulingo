<#
.SYNOPSIS
  Start YakuLingo without a custom executable.

.DESCRIPTION
  Starts the PowerShell HTTP server in the background and opens the local UI as
  a tab in the user's normal Microsoft Edge profile. When the YakuLingo tab is
  closed, the server and the dedicated Copilot Edge profile are stopped.
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$UseMockTranslator
)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $appRoot 'Start-YakuLingo.ps1'
$stopScript = Join-Path $appRoot 'tools\Stop-YakuLingo.ps1'
$script:YakuRoot = $appRoot
. (Join-Path $appRoot 'src\Paths.ps1')
. (Join-Path $appRoot 'src\Runtime.ps1')

function Get-YakuAppEdgePath {
    $candidates = @(
        $(try { (Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -Name '(default)' -ErrorAction Stop) } catch { '' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe' }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe' })
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath([string]$candidate)
        }
    }
    throw 'EDGE_NOT_FOUND: Microsoft Edgeが見つかりません。会社のPCでは、Edgeが利用可能かIT部門へ確認してください。'
}

function Remove-YakuLegacyStartupShortcut {
    # Notification-area/background startup was removed. Delete only a shortcut
    # that can be proven to belong to a YakuLingo tree; leave same-name links
    # owned by anything else untouched.
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        if ([string]::IsNullOrWhiteSpace($startup)) { return }
        $linkPath = Join-Path $startup 'YakuLingo.lnk'
        if (-not (Test-Path -LiteralPath $linkPath -PathType Leaf)) { return }
        $shell = New-Object -ComObject WScript.Shell
        try {
            $link = $shell.CreateShortcut($linkPath)
            if (-not [string]::Equals([string]$link.Description, 'YakuLingo', [StringComparison]::Ordinal)) { return }
            $target = [IO.Path]::GetFullPath([string]$link.TargetPath)
            $name = [IO.Path]::GetFileName($target)
            $owned = $false
            if ([string]::Equals($name, 'YakuLingo.exe', [StringComparison]::OrdinalIgnoreCase)) {
                $candidateApp = Split-Path -Parent (Split-Path -Parent $target)
                $owned = Test-Path -LiteralPath (Join-Path $candidateApp 'Start-YakuLingo.ps1') -PathType Leaf
            } elseif ($name -in @('YakuLingo起動.vbs','YakuLingo起動.cmd')) {
                $owned = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $target) 'app\Start-YakuLingo.ps1') -PathType Leaf
            }
            if ($owned) { Remove-Item -LiteralPath $linkPath -Force }
        } finally {
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch {}
        }
    } catch {}
}

function Read-YakuRunningServer {
    # -RequireHttpProbe を付けない呼び出しは、server.json とプロセス身元だけを見る
    # （HTTPは投げない）。listener.Start() の直後から GetContext() を回し始める
    # までに、サーバー起動の他の下ごしらえ（Copilot準備の起動指示・古いジョブの
    # 復元など）が挟まる区間があり、そこへ250ms刻みでHTTPを投げ続けると、
    # 接続はできてもGetContext()に届くまで応答が来ず、ポーリングのたびに
    # 待たされていた（D2-10）。ここを待つあいだはプロセスの実在だけで足りる。
    param([switch]$RequireHttpProbe)
    $runtimePath = Join-Path (Get-YakuSubDir 'runtime') 'server.json'
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { return $null }
    try {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not (Test-YakuProcessIdentity -Id ([int]$runtime.pid) -StartTimeUtc ([string]$runtime.process_started_at))) { return $null }
        $uri = [uri]([string]$runtime.url)
        if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1') { return $null }
        if (-not $RequireHttpProbe) { return $runtime }
        $probe = Invoke-RestMethod -UseBasicParsing -Uri ([string]$runtime.url + 'api/instance') -TimeoutSec 10
        if ([string]$probe.instance_id -ne [string]$runtime.instance_id) { return $null }
        return $runtime
    } catch { return $null }
}

function Wait-YakuRunningServer {
    param([int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $runtime = $null
    do {
        $runtime = Read-YakuRunningServer
        if ($runtime) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (-not $runtime) { throw 'SERVER_START_TIMEOUT: YakuLingoの準備が時間内に終わりませんでした。ログを確認してください。' }
    # プロセスは立っている。ここから先だけ、実際にHTTPで答えることを確かめる。
    # 起動直後の下ごしらえがまだ終わっていない場合があるので、残り時間の中で
    # 何度か待つ（1回で諦めない）。
    do {
        $confirmed = Read-YakuRunningServer -RequireHttpProbe
        if ($confirmed) { return $confirmed }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw 'SERVER_START_TIMEOUT: YakuLingoの準備が時間内に終わりませんでした。ログを確認してください。'
}

$serverStartedHere = $false
$edgeProcess = $null
$launcherMutex = New-Object System.Threading.Mutex($false, 'Local\YakuLingo-BrowserTabLauncher')
$ownsLauncher = $false
try { $ownsLauncher = $launcherMutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $ownsLauncher = $true }
$runtime = Read-YakuRunningServer -RequireHttpProbe
try {
    Remove-YakuLegacyStartupShortcut
    # Only the launcher that owns the lifecycle mutex may start the server or
    # open Edge. Re-running the shortcut must not add another YakuLingo tab.
    if (-not $ownsLauncher) { return }

    if (-not $runtime) {
        $powerShell = Join-Path $PSHOME 'powershell.exe'
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $serverScript + '"'),'-NoBrowser','-Port',[string]$Port)
        if ($UseMockTranslator) { $arguments += '-UseMockTranslator' }
        Start-Process -FilePath $powerShell -ArgumentList ($arguments -join ' ') -WorkingDirectory $appRoot -WindowStyle Hidden | Out-Null
        $serverStartedHere = $true
        $runtime = Wait-YakuRunningServer
    }

    $edge = Get-YakuAppEdgePath
    $baseUrl = [string]$runtime.url
    $uiUrl = $baseUrl.TrimEnd('/') + '/'
    $edgeArguments = @(
        '--new-tab',
        $uiUrl
    ) -join ' '
    $edgeProcess = Start-Process -FilePath $edge -ArgumentList $edgeArguments -PassThru

    $deadline = (Get-Date).AddSeconds(30)
    $sawUiClient = $false
    $allClosingSince = $null
    $firstPoll = $true
    do {
        # 1回目は待たずに確かめる（D2-10）。以降は500msずつ空ける。
        if (-not $firstPoll) { Start-Sleep -Milliseconds 500 }
        $firstPoll = $false
        $instance = $null
        try {
            $instance = Invoke-RestMethod -UseBasicParsing -Uri ($baseUrl + 'api/instance') -TimeoutSec 10
        } catch {
            # サーバーの応答が一時的に遅れているだけなら、プロセスが生きている限り
            # 待ち続ける。ここで即座に打ち切ってサーバーごと止めていたのが
            # D2-1 の不具合（1リクエストの遅れで監視役がアプリごと殺していた）。
            # プロセスが本当に落ちているときだけ止める。
            #
            # R2-1: $deadline（Edge起動から30秒、延長しない）を、タブが出たあとの
            # 失敗にまで適用していたため、起動から30秒過ぎてから10秒超かかる
            # ハンドラ（/api/cat/export の初回Excel COM起動、/api/copilot/window の
            # 「つながっている」側の待ち等）に一度でも当たると、利用中の監視役が
            # アプリごと落としていた。deadline はタブ初出まで（$sawUiClient が
            # まだ立っていない間）だけに効かせる。タブが一度でも出たあとは、
            # プロセスが生きている限り何度失敗しても待つ。
            if (-not (Test-YakuProcessIdentity -Id ([int]$runtime.pid) -StartTimeUtc ([string]$runtime.process_started_at))) {
                throw 'SERVER_LOST: YakuLingoのサーバーが応答しなくなりました。'
            }
            if (-not $sawUiClient -and (Get-Date) -ge $deadline) { throw 'EDGE_TAB_START_TIMEOUT: YakuLingoのEdgeタブを確認できませんでした。' }
            continue
        }
        $clientCount = [int]$instance.ui_client_count
        if ($clientCount -gt 0) { $sawUiClient = $true }
        if (-not $sawUiClient) {
            if ((Get-Date) -ge $deadline) { throw 'EDGE_TAB_START_TIMEOUT: YakuLingoのEdgeタブを確認できませんでした。' }
            continue
        }
        if ([bool]$instance.ui_all_closing) {
            if ($null -eq $allClosingSince) { $allClosingSince = Get-Date }
            if (((Get-Date) - $allClosingSince).TotalSeconds -ge 3) { break }
        } else { $allClosingSince = $null }
    } while ($true)
} finally {
    # Stop only YakuLingo's server and dedicated Copilot profile. The user's
    # normal Edge process and other tabs remain open.
    if ($ownsLauncher -and (Test-Path -LiteralPath $stopScript -PathType Leaf)) {
        & $stopScript -Port $(if ($runtime) { [int]$runtime.port } else { $Port })
    }
    if ($ownsLauncher) { try { $launcherMutex.ReleaseMutex() } catch {} }
    try { $launcherMutex.Dispose() } catch {}
}
