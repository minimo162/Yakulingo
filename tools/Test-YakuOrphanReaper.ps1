<#
.SYNOPSIS
  tools\Clear-YakuOrphans.ps1 の判定を検証する。

.DESCRIPTION
  プロセスを落とす道具なので、誤爆の代償が大きい。落とすことより
  「落とさないもの」を先に固定する。実物のプロセスを立てて確かめる。

  CASE 1  コマンドラインの分解（実測した3つの引用形）
  CASE 2  文字列 'Server.ps1' を含むだけの行を -File 起動とみなさない
  CASE 3  -File の指す実体を見て種類を決める
  CASE 4  本物の Edge プロファイルを使い捨てとみなさない
  CASE 5  親が生きているサーバーは落とさない（実プロセス）
  CASE 6  親が消えたサーバーは落とす（実プロセス）
  CASE 7  対象0件でも exit 0
  CASE 8  いま動いている本物の Edge は1つも kill 計画に入らない（実プロセス）
  CASE 9  使い捨てプロファイルの Edge は落とし、残骸も消す（実プロセス）

.NOTES
  -ReaperPath は、故意に壊した写しを指して「赤になること」を確かめるために要る。
#>
[CmdletBinding()]
param(
    [string]$ReaperPath = '',
    # CASE 9 は実際に Edge を起動する。Edge が無い環境では明示的に外す。
    [switch]$SkipEdgeLaunch
)

$ErrorActionPreference = 'Stop'
$script:Failed = 0
$script:Passed = 0

if ([string]::IsNullOrWhiteSpace($ReaperPath)) {
    $ReaperPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Clear-YakuOrphans.ps1'
}
$ReaperPath = [System.IO.Path]::GetFullPath($ReaperPath)
if (-not (Test-Path -LiteralPath $ReaperPath -PathType Leaf)) { throw "reaper not found: $ReaperPath" }

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { $script:Passed++; Write-Host ("  ok   " + $Name) -ForegroundColor DarkGreen; return }
    $script:Failed++
    Write-Host ("  FAIL " + $Name + $(if ($Detail) { " : $Detail" } else { '' })) -ForegroundColor Red
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    Assert-True -Condition ([string]$Expected -eq [string]$Actual) -Name $Name -Detail ("expected=[{0}] actual=[{1}]" -f $Expected, $Actual)
}

function Get-YakuPlanFor {
    param([array]$Plan, [int]$ProcessId)
    foreach ($item in $Plan) { if ([int]$item.ProcessId -eq $ProcessId) { return $item } }
    return $null
}

function Start-YakuStubProcess {
    <#
      作り物のサーバーを立てる。立たなかったときは理由を持って返す。
      この機械では、コマンドラインに Server.ps1 を含むプロセスが外から落とされることが
      ある（並行して動く別の作業が、文字列一致で刈っている）。試験の判定を緩めずに
      「立て直す」ことで、外からの妨害と判定の誤りを区別する。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [int]$Attempts = 3
    )
    $lastError = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $errFile = Join-Path $LogDir ("stub-$tag.err.txt")
        $outFile = Join-Path $LogDir ("stub-$tag.out.txt")
        $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -RedirectStandardError $errFile -RedirectStandardOutput $outFile `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"'), '-Port', [string]$Port)
        Start-Sleep -Milliseconds 700
        if (-not $proc.HasExited) { return [pscustomobject]@{ Process = $proc; Error = '' } }
        $text = ''
        try { $text = ([string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)).Trim() } catch {}
        $lastError = ("attempt {0}: exit={1} stderr=[{2}]" -f $attempt, $proc.ExitCode, ($text -replace "`r?`n", ' '))
    }
    return [pscustomobject]@{ Process = $null; Error = $lastError }
}

function New-YakuOrphanProcess {
    # 親が消えたプロセスを作る。孫を立てた親（launcher）が終了することで孤児にする。
    param(
        [Parameter(Mandatory = $true)][string]$Launcher,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$Attempts = 3
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }
        $spawner = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Launcher + '"'),
            '-Stub', ('"' + $Script + '"'), '-PidFile', ('"' + $PidFile + '"'), '-Port', [string]$Port
        )
        $spawner.WaitForExit(20000) | Out-Null
        Start-Sleep -Milliseconds 500
        $orphanPid = 0
        if (Test-Path -LiteralPath $PidFile) {
            try { $orphanPid = [int]([string](Get-Content -LiteralPath $PidFile -Raw)).Trim() } catch { $orphanPid = 0 }
        }
        if ($orphanPid -gt 0 -and (Get-Process -Id $orphanPid -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ ProcessId = $orphanPid; ParentId = [int]$spawner.Id; Error = '' }
        }
    }
    return [pscustomobject]@{ ProcessId = 0; ParentId = 0; Error = ("孤児を作れなかった（外から落とされた可能性）。attempts={0}" -f $Attempts) }
}

function Wait-YakuProcessGone {
    param([int]$ProcessId, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

. $ReaperPath

$stampId = [guid]::NewGuid().ToString('N').Substring(0, 8)
# 作り物のアプリ木は、使い捨てプロファイルの名前規則に「当てない」場所へ置く。
# 同じ場所に置いたとき、CASE 9 の掃除が木ごと消して CASE 11 が動かなくなった。
$treeRoot = Join-Path $env:TEMP ('yaku-reaper-tree-' + $stampId)
$workRoot = Join-Path $env:TEMP ('yakulingo-reaper-selftest-' + $stampId)
$started = New-Object System.Collections.Generic.List[int]
$tempDirs = New-Object System.Collections.Generic.List[string]
$tempDirs.Add($workRoot) | Out-Null
$tempDirs.Add($treeRoot) | Out-Null

try {
    # --- 作り物のアプリ木 -------------------------------------------------
    # 本物の Server.ps1 を回すと Copilot まで巻き込む。判定が見ているのは
    # 「src\Server.ps1 で、隣に SrcModules.ps1 があり、1つ上に Start-YakuLingo.ps1 がある」
    # という構造なので、それだけを持つ木を作る。
    $appDir = Join-Path $treeRoot 'app'
    $srcDir = Join-Path $appDir 'src'
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    $stubServer = Join-Path $srcDir 'Server.ps1'
    Set-Content -LiteralPath $stubServer -Encoding ascii -Value @(
        'param([int]$Port = 0)',
        'Start-Sleep -Seconds 300'
    )
    Set-Content -LiteralPath (Join-Path $srcDir 'SrcModules.ps1') -Encoding ascii -Value '# stub'
    $stubLauncher = Join-Path $appDir 'Start-YakuLingo.ps1'
    Set-Content -LiteralPath $stubLauncher -Encoding ascii -Value @(
        'param([int]$Port = 0)',
        'Start-Sleep -Seconds 300'
    )

    $pidFile = Join-Path $treeRoot 'orphan.pid'
    $launcher = Join-Path $treeRoot 'launch-orphan.ps1'
    Set-Content -LiteralPath $launcher -Encoding ascii -Value @(
        'param([string]$Stub, [string]$PidFile, [int]$Port)',
        '$child = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",("""" + $Stub + """"),"-Port",[string]$Port) -PassThru -WindowStyle Hidden',
        'Set-Content -LiteralPath $PidFile -Encoding ascii -Value ([string]$child.Id)'
    )

    Write-Host 'CASE 1: コマンドラインの分解' -ForegroundColor Cyan
    $t1 = Split-YakuCommandLine -CommandLine '"C:\Windows\powershell.exe" -NoProfile -File "C:\path with spaces\Start-YakuLingo.ps1" -Port 18790 -UseMockTranslator'
    Assert-Equal 'C:\path with spaces\Start-YakuLingo.ps1' (Get-YakuFileArgument -Tokens $t1) '-File の値（値だけが引用された形）'
    Assert-Equal 18790 (Get-YakuPortArgument -Tokens $t1) '-Port の値'
    Assert-True -Condition (Test-YakuSwitchToken -Tokens $t1 -Name '-UseMockTranslator') -Name '-UseMockTranslator を見つける'
    $t2 = Split-YakuCommandLine -CommandLine '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --type=crashpad-handler "--user-data-dir=C:\Users\u\AppData\Local\Microsoft\Edge\User Data" /prefetch:4'
    Assert-Equal 'C:\Users\u\AppData\Local\Microsoft\Edge\User Data' (Get-YakuUserDataDirArgument -Tokens $t2) '--user-data-dir（引数全体が引用された形）'
    $t3 = Split-YakuCommandLine -CommandLine 'msedge.exe --remote-debugging-port=9433 --user-data-dir="C:\Users\u\.yakulingo-ps\edge-profile" about:blank'
    Assert-Equal 'C:\Users\u\.yakulingo-ps\edge-profile' (Get-YakuUserDataDirArgument -Tokens $t3) '--user-data-dir（値だけが引用された形）'

    Write-Host 'CASE 2: 文字列一致で殺しにいかない' -ForegroundColor Cyan
    # 実際に踏んだ誤検出。Win32_Process を調べる自分のコマンド自身が
    # -like '*Server.ps1*' に一致した。-File の値として現れたときだけ拾う。
    $probe = Split-YakuCommandLine -CommandLine 'powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*Server.ps1*'' }"'
    Assert-Equal '' (Get-YakuFileArgument -Tokens $probe) '-Command の中の Server.ps1 は -File ではない'
    Assert-Equal '' (Get-YakuServerScriptKind -ScriptPath (Get-YakuFileArgument -Tokens $probe)) '調査用プロセスは対象外'

    Write-Host 'CASE 3: -File の指す実体で種類を決める' -ForegroundColor Cyan
    Assert-Equal 'server-script' (Get-YakuServerScriptKind -ScriptPath $stubServer) 'src\Server.ps1 は server-script'
    Assert-Equal 'launcher-script' (Get-YakuServerScriptKind -ScriptPath (Join-Path $appDir 'Start-YakuLingo.ps1')) 'Start-YakuLingo.ps1 は launcher-script'
    Assert-Equal '' (Get-YakuServerScriptKind -ScriptPath (Join-Path $srcDir 'SrcModules.ps1')) '関係ない .ps1 は対象外'
    Assert-Equal '' (Get-YakuServerScriptKind -ScriptPath 'src\Server.ps1') '相対パスは判定しない'
    Assert-Equal '' (Get-YakuServerScriptKind -ScriptPath (Join-Path $workRoot 'no-such\src\Server.ps1')) '実体の無いパスは対象外'
    # 木はあるが Server.ps1 だけ消えている形。消えたファイルを指すコマンドラインは
    # 対象外にする（隣の SrcModules.ps1 だけでは、その .ps1 が在ることの証拠にならない）。
    $goneSrc = Join-Path $treeRoot 'gone\app\src'
    New-Item -ItemType Directory -Path $goneSrc -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $goneSrc 'SrcModules.ps1') -Encoding ascii -Value '# stub'
    Set-Content -LiteralPath (Join-Path (Split-Path -Parent $goneSrc) 'Start-YakuLingo.ps1') -Encoding ascii -Value '# stub'
    Assert-Equal '' (Get-YakuServerScriptKind -ScriptPath (Join-Path $goneSrc 'Server.ps1')) '隣の物が揃っていても、本体が無ければ対象外'
    # パスに使えない文字を含む -File で例外を投げない。投げると掃除が途中で止まり、
    # 掃除できたのかどうかが分からなくなる（故意に壊した写しで実際に踏んだ）。
    $illegal = ''
    try { $illegal = Get-YakuServerScriptKind -ScriptPath 'C:\bad|path\src\Server.ps1' }
    catch { $illegal = 'THREW:' + $_.Exception.GetType().Name }
    Assert-Equal '' $illegal '不正な文字を含むパスでも例外にしない'

    Write-Host 'CASE 4: 本物の Edge プロファイルを守る' -ForegroundColor Cyan
    $realProfile = Get-YakuRealEdgeProfilePath
    Assert-True -Condition (-not (Test-YakuDisposableEdgeProfile -UserDataDir $realProfile -Pattern @('yakulingo*'))) -Name 'ログイン済みプロファイルは使い捨てではない' -Detail $realProfile
    Assert-True -Condition (Test-YakuProtectedEdgeProfile -UserDataDir $realProfile) -Name 'ログイン済みプロファイルは保護対象'
    Assert-True -Condition (-not (Test-YakuDisposableEdgeProfile -UserDataDir (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') -Pattern @('*'))) -Name '通常の Edge プロファイルは使い捨てではない'
    Assert-True -Condition (-not (Test-YakuDisposableEdgeProfile -UserDataDir 'C:\Users\u\yakulingo-ui-audit-1\edge-profile' -Pattern @('yakulingo-ui-audit-*'))) -Name 'Temp 配下でなければ落とさない'
    Assert-True -Condition (Test-YakuDisposableEdgeProfile -UserDataDir (Join-Path $env:TEMP 'yakulingo-ui-audit-1\edge-profile') -Pattern @('yakulingo-ui-audit-*')) -Name 'Temp 配下の yakulingo-ui-audit-* は使い捨て'

    Write-Host 'CASE 5: 親が生きているサーバーは落とさない' -ForegroundColor Cyan
    $spawn = Start-YakuStubProcess -Script $stubServer -Port 19998 -LogDir $treeRoot
    Assert-True -Condition ($null -ne $spawn.Process) -Name '親が生きているサーバーを立てられた' -Detail $spawn.Error
    if ($null -ne $spawn.Process) {
        $alive = $spawn.Process
        $started.Add([int]$alive.Id) | Out-Null
        $planAlive = @((Invoke-YakuOrphanCleanup -ListOnly -OnlyProcessId @([int]$alive.Id) -Scope @('servers')).Plan)
        $itemAlive = Get-YakuPlanFor -Plan $planAlive -ProcessId ([int]$alive.Id)
        Assert-True -Condition ($null -ne $itemAlive) -Name '親が生きているサーバーも列挙はされる' -Detail ("pid={0} hasExited={1}" -f $alive.Id, $alive.HasExited)
        if ($null -ne $itemAlive) {
            Assert-Equal 'skip' $itemAlive.Action '親が生きていれば skip'
            Assert-Equal 'parent-alive' $itemAlive.Reason 'skip の理由は parent-alive'
        }
        Assert-True -Condition ($null -ne (Get-Process -Id ([int]$alive.Id) -ErrorAction SilentlyContinue)) -Name '生きたまま残っている' -Detail ("pid={0} hasExited={1}" -f $alive.Id, $alive.HasExited)
    }

    Write-Host 'CASE 6: 親が消えたサーバーは落とす' -ForegroundColor Cyan
    $orphan = New-YakuOrphanProcess -Launcher $launcher -Script $stubServer -PidFile $pidFile -Port 19999
    $orphanPid = [int]$orphan.ProcessId
    Assert-True -Condition ($orphanPid -gt 0) -Name '孤児を1つ作れた' -Detail ("pid={0} {1}" -f $orphanPid, $orphan.Error)
    if ($orphanPid -gt 0) {
        $started.Add($orphanPid) | Out-Null
        Assert-True -Condition (-not (Get-Process -Id ([int]$orphan.ParentId) -ErrorAction SilentlyContinue)) -Name '親は消えている'
        $planOrphan = @((Invoke-YakuOrphanCleanup -ListOnly -OnlyProcessId @($orphanPid) -Scope @('servers')).Plan)
        $itemOrphan = Get-YakuPlanFor -Plan $planOrphan -ProcessId $orphanPid
        Assert-True -Condition ($null -ne $itemOrphan) -Name '孤児が計画に載る'
        if ($null -ne $itemOrphan) {
            Assert-Equal 'kill' $itemOrphan.Action '孤児は kill'
            Assert-True -Condition ([string]$itemOrphan.Reason -like '*server-script-direct*') -Name '理由に server-script-direct が入る' -Detail ([string]$itemOrphan.Reason)
        }
        Assert-True -Condition ($null -ne (Get-Process -Id $orphanPid -ErrorAction SilentlyContinue)) -Name '列挙だけでは落ちていない'
        $applied = Invoke-YakuOrphanCleanup -OnlyProcessId @($orphanPid) -Scope @('servers') -Cmdlet $null
        Assert-Equal 1 $applied.KilledServers '1件落とした'
        Assert-True -Condition (Wait-YakuProcessGone -ProcessId $orphanPid) -Name '孤児は消えた'
    }

    Write-Host 'CASE 7: 対象0件でも exit 0' -ForegroundColor Cyan
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ReaperPath -OnlyProcessId 999999 2>&1
    $code = $LASTEXITCODE
    Assert-Equal 0 $code '0件で exit 0'
    Assert-True -Condition ((($out -join "`n") -match 'ORPHAN-CLEANUP-DONE') -and (($out -join "`n") -match 'planned=0')) -Name '0件の目印を出す' -Detail (($out | Select-Object -Last 1) -join '')

    Write-Host 'CASE 8: 動いている本物の Edge は kill 計画に入らない' -ForegroundColor Cyan
    # 「本物側」の選び方に、試験対象の関数を使わない。使うと、判定を壊したときに
    # 選び方も一緒に壊れ、対象0件で無条件に通ってしまう。
    # 使い捨てプロファイルのパスには必ず yakulingo が入るので、入っていないものを本物とする。
    $realEdgePids = New-Object System.Collections.Generic.List[int]
    foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue)) {
        if (([string]$proc.CommandLine) -notmatch '(?i)yakulingo') { $realEdgePids.Add([int]$proc.ProcessId) | Out-Null }
    }
    $table = Get-YakuProcessTable
    $edgePlan = @(Get-YakuDisposableEdgePlan -Table $table -Pattern @('yakulingo-ui-audit-*', 'yakulingo-reaper-selftest-*'))
    $edgeKillPids = @($edgePlan | Where-Object { $_.Action -eq 'kill' } | ForEach-Object { [int]$_.ProcessId })
    $hit = @($edgeKillPids | Where-Object { $realEdgePids.Contains([int]$_) })
    Assert-Equal 0 $hit.Count '本物の Edge の PID は1つも kill 計画に入らない'
    if ($realEdgePids.Count -eq 0) {
        # 利用者の Edge が閉じている状態でも、この試験は空振りにしない。
        # 触ってはならない Edge は CASE 9 で自分で立てて確かめる。
        Write-Host '  note 利用者の Edge が動いていない。実物での確認は CASE 9 が行う。' -ForegroundColor Yellow
    }

    if (-not $SkipEdgeLaunch) {
        Write-Host 'CASE 9: 使い捨てプロファイルの Edge と残骸' -ForegroundColor Cyan
        $edgeExe = ''
        foreach ($candidate in @(
                $(try { Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -Name '(default)' -ErrorAction Stop } catch { '' }),
                $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe' } else { '' }),
                $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' } else { '' })
            )) {
            if ((-not [string]::IsNullOrWhiteSpace([string]$candidate)) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $edgeExe = [string]$candidate; break }
        }
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($edgeExe)) -Name 'Edge を見つけた'
        if (-not [string]::IsNullOrWhiteSpace($edgeExe)) {
            # 本物の CDP ポート(9433)は使わない。実アプリの Edge と衝突させない。
            # 2つ立てる。名前規則に当たる方（落とす）と、当たらない方（落としてはならない）。
            # 「触ってはならない Edge」を利用者のブラウザに頼らず、自分で用意する。
            # 利用者が Edge を閉じている間だけ確認が空振りになる、という穴を塞ぐ。
            $throwProfile = Join-Path $workRoot 'edge-profile'
            $neutralProfile = Join-Path $treeRoot 'neutral-edge-profile'
            New-Item -ItemType Directory -Path $throwProfile -Force | Out-Null
            New-Item -ItemType Directory -Path $neutralProfile -Force | Out-Null
            # 本物の CDP ポート(9433)は使わない。実アプリの Edge と衝突させない。
            $edgeProc = Start-Process -FilePath $edgeExe -PassThru -ArgumentList (
                '--headless=new --disable-gpu --no-first-run --user-data-dir="{0}" --remote-debugging-port=9598 about:blank' -f $throwProfile)
            $started.Add([int]$edgeProc.Id) | Out-Null
            $neutralProc = Start-Process -FilePath $edgeExe -PassThru -ArgumentList (
                '--headless=new --disable-gpu --no-first-run --user-data-dir="{0}" --remote-debugging-port=9596 about:blank' -f $neutralProfile)
            $started.Add([int]$neutralProc.Id) | Out-Null
            Start-Sleep -Seconds 4

            $neutralPids = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { ([string]$_.CommandLine).Contains($neutralProfile) } | ForEach-Object { [int]$_.ProcessId })
            Assert-True -Condition ($neutralPids.Count -gt 0) -Name '触ってはならない Edge を立てた' -Detail ("count=" + $neutralPids.Count)

            $table2 = Get-YakuProcessTable
            $plan2 = @(Get-YakuDisposableEdgePlan -Table $table2 -Pattern @('yakulingo-reaper-selftest-*'))
            $mineKill = @($plan2 | Where-Object { $_.Action -eq 'kill' -and [string]$_.Detail -eq $throwProfile })
            Assert-True -Condition ($mineKill.Count -gt 0) -Name '使い捨てプロファイルの Edge が kill 計画に載る' -Detail ("count=" + $mineKill.Count)
            $killPids = @($plan2 | Where-Object { $_.Action -eq 'kill' } | ForEach-Object { [int]$_.ProcessId })
            $neutralHit = @($killPids | Where-Object { $neutralPids -contains [int]$_ })
            Assert-Equal 0 $neutralHit.Count '名前規則に当たらない Edge は kill 計画に入らない'

            # -Scope で edge と dirs に限る。試験が自分の作った物以外へ手を出さないため。
            # これを付けずに回したとき、無関係な孤児サーバー（別の作業が残した PID 26992）
            # まで落とした。試験は掃除道具ではない。
            $applied2 = Invoke-YakuOrphanCleanup -Scope @('edge', 'dirs') -DisposableProfilePattern @('yakulingo-reaper-selftest-*') -ProfileIdleMinutes 0 -Cmdlet $null
            Assert-True -Condition ($applied2.KilledEdge -gt 0) -Name '使い捨て Edge を落とした' -Detail ("killed=" + $applied2.KilledEdge)
            Start-Sleep -Milliseconds 800
            $leftMine = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { ([string]$_.CommandLine).Contains($throwProfile) }).Count
            Assert-Equal 0 $leftMine '使い捨てプロファイルの msedge は残っていない'
            $leftNeutral = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { ([string]$_.CommandLine).Contains($neutralProfile) }).Count
            Assert-True -Condition ($leftNeutral -gt 0) -Name '触ってはならない Edge は生きている' -Detail ("count=" + $leftNeutral)
            Assert-True -Condition (Test-Path -LiteralPath $neutralProfile) -Name '触ってはならない Edge のプロファイルも残っている'
            Assert-True -Condition (-not (Test-Path -LiteralPath $workRoot)) -Name '使い捨てプロファイルの残骸も消えた' -Detail $workRoot
        }
    }

    Write-Host 'CASE 10: 残骸を消す条件（ここが一番壊すと痛い）' -ForegroundColor Cyan
    # edge-profile を含むことを条件から外すと、Temp にある同名系のデータ置き場
    # （yakulingo-ui-audit-* には logs/ と runtime/ が入っていた）まで消える。
    $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dirProfile = Join-Path $env:TEMP ('yakulingo-reaper-selftest-' + $stamp + '-a')
    $dirData = Join-Path $env:TEMP ('yakulingo-reaper-selftest-' + $stamp + '-b')
    $dirFresh = Join-Path $env:TEMP ('yakulingo-reaper-selftest-' + $stamp + '-c')
    $tempDirs.Add($dirProfile) | Out-Null
    $tempDirs.Add($dirData) | Out-Null
    $tempDirs.Add($dirFresh) | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dirProfile 'edge-profile') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dirData 'logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dirData 'server.out.txt') -Encoding ascii -Value 'test log'
    New-Item -ItemType Directory -Path (Join-Path $dirFresh 'edge-profile') -Force | Out-Null
    foreach ($old in @($dirProfile, $dirData)) { (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddHours(-1) }

    $dirPlan = @(Get-YakuStaleProfileDirPlan -Table (Get-YakuProcessTable) -Pattern @('yakulingo-reaper-selftest-*') -IdleMinutes 5)
    $planProfile = @($dirPlan | Where-Object { [string]$_.Detail -eq $dirProfile })
    $planData = @($dirPlan | Where-Object { [string]$_.Detail -eq $dirData })
    $planFresh = @($dirPlan | Where-Object { [string]$_.Detail -eq $dirFresh })
    Assert-Equal 1 $planProfile.Count 'edge-profile を持つ残骸が計画に載る'
    if ($planProfile.Count -eq 1) { Assert-Equal 'remove' $planProfile[0].Action 'edge-profile を持つ残骸は remove' }
    Assert-Equal 1 $planData.Count 'データ置き場も計画には載る（判断を隠さない）'
    if ($planData.Count -eq 1) {
        Assert-Equal 'skip' $planData[0].Action 'edge-profile が無ければ消さない'
        Assert-Equal 'no-edge-profile' $planData[0].Reason 'skip の理由は no-edge-profile'
    }
    if ($planFresh.Count -eq 1) { Assert-Equal 'too-fresh' $planFresh[0].Reason '作りたてのものは消さない' }

    $applied3 = Invoke-YakuOrphanCleanup -Scope @('dirs') -DisposableProfilePattern @('yakulingo-reaper-selftest-*') -ProfileIdleMinutes 5 -Cmdlet $null
    Assert-Equal 1 $applied3.RemovedDirs '消したのは1つだけ'
    Assert-True -Condition (-not (Test-Path -LiteralPath $dirProfile)) -Name 'プロファイルの残骸は消えた'
    Assert-True -Condition (Test-Path -LiteralPath $dirData) -Name 'データ置き場は残っている' -Detail $dirData
    Assert-True -Condition (Test-Path -LiteralPath $dirFresh) -Name '作りたてのものは残っている' -Detail $dirFresh

    Write-Host 'CASE 11: 印の無いサーバー孤児は落とさない（利用者の実アプリの形）' -ForegroundColor Cyan
    # 利用者の実アプリは Start-YakuLingo.ps1 を -File で起動し、既定ポート 8765、
    # mock なしで動く（app\Start-YakuLingoApp.ps1:108）。孤児になっても、この形は
    # 落とさない。落としてよいのは「テストが立てた」と言い切れる印があるものだけ。
    $appOrphan = New-YakuOrphanProcess -Launcher $launcher -Script $stubLauncher -PidFile $pidFile -Port 8765
    $appPid = [int]$appOrphan.ProcessId
    Assert-True -Condition ($appPid -gt 0) -Name '実アプリの形の孤児を作れた' -Detail ("pid={0} {1}" -f $appPid, $appOrphan.Error)
    if ($appPid -gt 0) {
        $started.Add($appPid) | Out-Null
        $planApp = @((Invoke-YakuOrphanCleanup -ListOnly -OnlyProcessId @($appPid) -Scope @('servers')).Plan)
        $itemApp = Get-YakuPlanFor -Plan $planApp -ProcessId $appPid
        Assert-True -Condition ($null -ne $itemApp) -Name '実アプリの形も列挙はされる'
        if ($null -ne $itemApp) {
            Assert-Equal 'skip' $itemApp.Action '印が無ければ skip'
            Assert-Equal 'no-test-marker' $itemApp.Reason 'skip の理由は no-test-marker'
        }
        $keep = Invoke-YakuOrphanCleanup -OnlyProcessId @($appPid) -Scope @('servers') -Cmdlet $null
        Assert-Equal 0 $keep.KilledServers '既定では1件も落とさない'
        Assert-True -Condition ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) -Name '実アプリの形は生きたまま'

        # 明示的に頼まれたときだけ落とす。
        $forced = Invoke-YakuOrphanCleanup -OnlyProcessId @($appPid) -Scope @('servers') -IncludeAppServer -Cmdlet $null
        Assert-Equal 1 $forced.KilledServers '-IncludeAppServer なら落とす'
        Assert-True -Condition (Wait-YakuProcessGone -ProcessId $appPid) -Name '-IncludeAppServer で消えた'
    }
} finally {
    foreach ($processId in $started.ToArray()) {
        try { Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue } catch {}
    }
    # 自分で立てた Edge は、子プロセスまで含めて片付ける。プロファイルの場所で選ぶ。
    foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue)) {
        $cl = [string]$proc.CommandLine
        if ($cl.Contains($treeRoot) -or $cl.Contains($workRoot)) {
            try { Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    # 作り物のプロセスが掴んでいることがあるので、少し待ってから消す。
    Start-Sleep -Milliseconds 300
    foreach ($dir in $tempDirs.ToArray()) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        # 自分が作った Temp 配下のものだけを消す。
        if (-not $dir.StartsWith(([string]$env:TEMP), [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-Path -LiteralPath $dir) {
            try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host ("Orphan reaper tests FAILED: {0} failed, {1} passed." -f $script:Failed, $script:Passed) -ForegroundColor Red
    exit 1
}
Write-Host ("Orphan reaper tests passed: {0} assertion(s)." -f $script:Passed) -ForegroundColor Green
exit 0
