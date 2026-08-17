<#
.SYNOPSIS
  画面の床（美しさの下限）を機械で測る。**2つの窓幅**で 4 つを判定する。

.DESCRIPTION
  1. pageerror が 0 件
  2. 文字が乗っている要素のコントラスト比が 4.5:1 以上
  3. ラベルが 1 行に収まる（折り返さない・切り取られない）
  4. documentElement.scrollWidth <= clientWidth（横スクロールしない）

  ~~実機の窓幅は約 1380px。~~ **これは誤りだった（2026-08-16 に訂正）。**
  利用者の機械で実測した値は次のとおりで、**狭い版のレイアウトは一度も当たらない**。

      screen 1920x1200 / 最大化した窓 inner 1912x987 / devicePixelRatio 1 / zoom 1
      matchMedia('(max-width: 1400px)').matches = false

  1380 は測定ではなく、`@media (max-width: 1400px)` を踏ませたくて選んだ値だった。
  それがこの道具に「実機」として書かれ、繰り返しによって事実になっていた。
  実際、1380 で測ると上部の操作ブロックが折り返して 184px → 408px になり、
  「格子より上が画面の 64%」という、**利用者が決して見ない数字**が出る
  （実機の 1912px では 36%。2倍近く外していた）。

  そこで**両方を測る**。狭い版を守る意味はあるので消さないが、それを「実機」と
  呼ばない。既定は次の2つで、報告にはどちらの窓で測ったかを必ず添える。

      1912x987  利用者の機械（実測）
      1380x900  狭い版のレイアウトを踏ませる守り

  片方でも床を割ったら赤にする。**画面の寸法を語るときは、実機側の値を使うこと。**

  この試験は毎回、床を故意に割った版も測る。割ったのに赤にならなければ、
  その門は門ではないので試験そのものを赤にする（CLAUDE.md「待つ前に、この条件は
  本当に発火するか一度確かめる」）。割る操作は開いたページの DOM に対してだけ行い、
  www/assets の css も html も書き換えない。

  データは使い捨ての場所へ隔離する（YAKULINGO_DATA_DIR）。共有フォルダへは書かない。

  **これは回帰試験ではない。手で回す診断具である。** 名前を Test-Yaku* にしないのは
  そのためで、回帰の掃引（tools/Test-Yaku*.ps1）へ黙って混ざらないようにしている。
  2026-08-14 に Test-YakuUiFloor.ps1 という名前で作ったところ、掃引の中で5回中2回
  赤になった。原因は Server.ps1 の単一起動 mutex がユーザー名だけで決まり、
  ポートでもデータ置き場でも隔離されないため、掃引中の別の試験とぶつかること。
  単独で回せば緑になるので、掃引に入れると原因不明の赤が常設されることになる。

  終了コード: 0=床を守れている / 1=床を割った / 3=未測定（環境が無い・測定が失敗）。
  3 を赤に数えないこと。「測れなかった」と「壊れている」は別物である。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Measure-YakuUiFloor.ps1

.EXAMPLE
  # 今の床を記録し直す（違反を認めるという意味。減らしたときだけ使う）
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Measure-YakuUiFloor.ps1 -UpdateBaseline
#>
[CmdletBinding()]
param(
    [int]$Port = 18791,
    [int]$Width = 1380,
    [int]$Height = 900,
    [string]$BaselinePath = '',
    # 記録済みの違反も許さず、0 件を要求する
    [switch]$Strict,
    # 今の測定値を基準値として書き直す
    [switch]$UpdateBaseline,
    # 門の発火確認を飛ばす（普段は使わない。飛ばした試験に価値は無い）
    [switch]$SkipGateFireCheck,
    # 測った全要素を報告に載せる（調べるとき用。報告が数百KBになる）
    [switch]$Dump,
    # 使い捨てのデータ置き場を消さずに残す（サーバのログを読むとき用）
    [switch]$KeepDataDir,
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$toolDir = Join-Path (Join-Path $root 'tools') 'ui-floor'
$measureScript = Join-Path $toolDir 'measure-ui-floor.js'
if (-not (Test-Path -LiteralPath $measureScript -PathType Leaf)) { throw "測定スクリプトがありません: $measureScript" }
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path $toolDir 'ui-floor-baseline.json' }

# 終了コードの取り決め。ここを分けないと「床が割れた」と「測れなかった」が
# 同じ赤になり、原因不明の赤が回帰へ常設される。
#   0 = 床を守れている
#   1 = 床を割った（直すべき欠陥）
#   3 = 測定環境が無い / 測定そのものが失敗した（未測定。欠陥ではない）
$YAKU_UI_FLOOR_ENV_MISSING = 3

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Write-Host 'UNMEASURED: node が見つかりません。UI 床の測定には node が要ります。' -ForegroundColor Yellow
    exit $YAKU_UI_FLOOR_ENV_MISSING
}
$nodeExe = [string]$nodeCmd.Source

# playwright はこのリポジトリにも npm global にも無い。2026-08-14 の実測では、
# 解決できたのは開発時のエージェント実行環境のキャッシュだけだった
# （C:\Users\<user>\.cache\... 配下）。つまり利用者の環境では動かない。
# 無いことは欠陥ではないので、赤ではなく「未測定」で抜ける。
$probe = & $nodeExe -e "try{require.resolve('playwright');process.exit(0)}catch(e){process.exit(9)}" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が見つかりません。UI 床は測っていません。' -ForegroundColor Yellow
    Write-Host '  導入するまで、この装置の結果を「床を守れている」根拠に使わないこと。' -ForegroundColor Yellow
    exit $YAKU_UI_FLOOR_ENV_MISSING
}

$fixture = Join-Path (Join-Path $root 'tools') 'regression\V91.38_file数値前処理ミニブック.xlsx'
if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) { throw "取り込み用の見本がありません: $fixture" }

$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-ui-floor-' + $stamp)
}
$null = New-Item -ItemType Directory -Path $OutputDir -Force
# 実データを汚さない。書き込み先はローカルの使い捨て領域だけ。
# データ置き場は必ず TEMP 直下の短い名前にする。-OutputDir の下に作ると、
# 取り込んだ資料の版管理が掘る深い階層で MAX_PATH を越えて保存に失敗する
# （実測: 呼び出し側が長い -OutputDir を渡したとき「作業内容を保存できませんでした」）。
$dataDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-uifloor-' + $stamp)
$null = New-Item -ItemType Directory -Path $dataDir -Force

function Invoke-YakuUiFloorMeasure {
    param(
        [Parameter(Mandatory=$true)][string]$BaseUrl,
        [Parameter(Mandatory=$true)][string]$Inject,
        [Parameter(Mandatory=$true)][string]$OutFile
    )
    $argList = @(
        ('"{0}"' -f $measureScript),
        '--url', ('"{0}"' -f $BaseUrl),
        '--width', [string]$Width,
        '--height', [string]$Height,
        '--fixture', ('"{0}"' -f $fixture),
        '--inject', $Inject,
        '--out', ('"{0}"' -f $OutFile),
        '--screenshot-dir', ('"{0}"' -f $OutputDir)
    )
    if ($Dump) { $argList += '--dump' }
    $stdoutPath = Join-Path $OutputDir ('node-' + $Inject + '.out.txt')
    $stderrPath = Join-Path $OutputDir ('node-' + $Inject + '.err.txt')
    # Start-Process -PassThru の ExitCode は当てにならない（実測: node が 1 で
    # 落ちても 0 が返った）。ProcessStartInfo で自前に起動して待つ。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodeExe
    $psi.Arguments = ($argList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $code = [int]$proc.ExitCode
    [IO.File]::WriteAllText($stdoutPath, [string]$stdoutTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stderrPath, [string]$stderrTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    $proc.Dispose()
    $report = $null
    if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
        $raw = [IO.File]::ReadAllText($OutFile)
        try { $report = $raw | ConvertFrom-Json } catch { $report = $null }
    }
    if ($code -eq 1 -or $null -eq $report) {
        $err = ''
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { $err = [IO.File]::ReadAllText($stderrPath) }
        # 説明を立てる前に、相手が実際に何を返したかを読む。ここで落ちる原因の
        # ほとんどは試験サーバー側なので、生きているかと、そのログの末尾を付ける。
        $serverState = 'unknown'
        try { if ($server) { $serverState = if ($server.HasExited) { 'exited code=' + $server.ExitCode } else { 'alive' } } } catch {}
        $logTail = ''
        $logPath = Join-Path (Join-Path $dataDir 'logs') 'yakulingo.log'
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            try { $logTail = (@(Get-Content -LiteralPath $logPath -Tail 15) -join "`n") } catch {}
        }
        throw ("測定スクリプトが失敗しました (inject={0}, exit={1}) server={2}`n{3}`n--- server log tail ---`n{4}" -f $Inject, $code, $serverState, $err, $logTail)
    }
    return $report
}

# 違反 1 件を 1 本の指紋にする。数だけでなく中身で突き合わせる。
function Get-YakuUiFloorFingerprints {
    param([Parameter(Mandatory=$true)]$Report)
    $set = New-Object System.Collections.Generic.List[string]
    foreach ($state in @($Report.states)) {
        $stateName = [string]$state.state
        foreach ($msg in @($state.pageerror.violations)) {
            $set.Add(('{0}|pageerror|{1}' -f $stateName, [string]$msg)) | Out-Null
        }
        if ($state.contrast) {
            foreach ($v in @($state.contrast.violations)) {
                $set.Add(('{0}|contrast|{1}|{2}' -f $stateName, [string]$v.selector, [string]$v.text)) | Out-Null
            }
        }
        if ($state.label) {
            foreach ($v in @($state.label.violations)) {
                $set.Add(('{0}|label|{1}|{2}|{3}' -f $stateName, [string]$v.selector, [string]$v.text, [string]$v.reason)) | Out-Null
            }
        }
        if ($state.overflow) {
            foreach ($v in @($state.overflow.violations)) {
                $set.Add(('{0}|overflow|{1}' -f $stateName, [string]$v.reason)) | Out-Null
            }
        }
    }
    # 要素1のコレクションを return すると展開されて単体になる。, で止める。
    return ,$set.ToArray()
}

function Get-YakuUiFloorGateCount {
    param([Parameter(Mandatory=$true)]$Report, [Parameter(Mandatory=$true)][string]$Gate)
    $total = 0
    foreach ($state in @($Report.states)) {
        switch ($Gate) {
            'pageerror' { $total += @($state.pageerror.violations).Count }
            'contrast'  { if ($state.contrast) { $total += @($state.contrast.violations).Count } }
            'label'     { if ($state.label) { $total += @($state.label.violations).Count } }
            'overflow'  { if ($state.overflow) { $total += @($state.overflow.violations).Count } }
        }
    }
    return [int]$total
}

$server = $null
$oldDataDir = $env:YAKULINGO_DATA_DIR
$failures = New-Object System.Collections.Generic.List[string]
$summary = $null
try {
    $env:YAKULINGO_DATA_DIR = $dataDir

    $exe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { $exe = 'powershell.exe' }
    $startScript = Join-Path $root 'Start-YakuLingo.ps1'
    $startArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -NoBrowser -UseMockTranslator' -f $startScript, $Port
    $server = Start-Process -FilePath $exe -ArgumentList $startArgs -PassThru -WindowStyle Hidden

    $runtimePath = Join-Path (Join-Path $dataDir 'runtime') 'server.json'
    $deadline = (Get-Date).AddSeconds(60)
    $info = $null
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) { throw ('試験サーバーが終了しました。ExitCode={0}（別の YakuLingo が起動中かもしれません）' -f $server.ExitCode) }
        if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
            try { $info = [IO.File]::ReadAllText($runtimePath) | ConvertFrom-Json } catch { $info = $null }
            if ($info -and [int]$info.pid -eq [int]$server.Id) { break }
            $info = $null
        }
        Start-Sleep -Milliseconds 300
    }
    if ($null -eq $info) { throw '試験サーバーの runtime 情報を取得できませんでした。' }
    $baseUrl = [string]$info.url

    # --- 本番の測定 ---------------------------------------------------------
    $reportPath = Join-Path $OutputDir 'ui-floor.json'
    $report = Invoke-YakuUiFloorMeasure -BaseUrl $baseUrl -Inject 'none' -OutFile $reportPath

    # --- 門が発火するかを確かめる -------------------------------------------
    $gateFire = [ordered]@{}
    if (-not $SkipGateFireCheck) {
        # 割り方 → 反応するはずの門。label は「折り返し」と「切り取り」の
        # 2 通りで割れるので、両方を別々に確かめる。
        $injections = @(
            @{ inject = 'contrast';  gate = 'contrast' },
            @{ inject = 'label';     gate = 'label' },
            @{ inject = 'clip';      gate = 'label' },
            @{ inject = 'overflow';  gate = 'overflow' },
            @{ inject = 'pageerror'; gate = 'pageerror' }
        )
        foreach ($item in $injections) {
            $inject = [string]$item.inject
            $gate = [string]$item.gate
            $injPath = Join-Path $OutputDir ('ui-floor-inject-' + $inject + '.json')
            $injected = Invoke-YakuUiFloorMeasure -BaseUrl $baseUrl -Inject $inject -OutFile $injPath
            $before = Get-YakuUiFloorGateCount -Report $report -Gate $gate
            $after = Get-YakuUiFloorGateCount -Report $injected -Gate $gate
            $fired = ($after -gt $before)
            $gateFire[$inject] = [pscustomobject]@{ gate = $gate; before = $before; after = $after; fired = $fired }
            if (-not $fired) {
                $failures.Add(("門が発火しません: {0} を故意に割っても {1} の違反が増えませんでした (before={2} after={3})" -f $inject, $gate, $before, $after)) | Out-Null
            }
        }
    }

    # --- 基準値との突き合わせ ----------------------------------------------
    $current = Get-YakuUiFloorFingerprints -Report $report
    if ($UpdateBaseline) {
        $payload = [pscustomobject]@{
            note = '画面の床の基準値。ここに載っている違反は「今もある」という記録であって、正しいという意味ではない。'
            viewport = [pscustomobject]@{ width = $Width; height = $Height }
            recorded_at = (Get-Date).ToString('s')
            violations = $current
        }
        $json = $payload | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($BaselinePath, $json, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("基準値を書き直しました: {0}（{1} 件）" -f $BaselinePath, @($current).Count) -ForegroundColor Yellow
    } elseif ($Strict) {
        foreach ($v in @($current)) { $failures.Add('床を割っています: ' + $v) | Out-Null }
    } elseif (Test-Path -LiteralPath $BaselinePath -PathType Leaf) {
        $baselineRaw = [IO.File]::ReadAllText($BaselinePath)
        $baseline = $baselineRaw | ConvertFrom-Json
        $known = @{}
        foreach ($v in @($baseline.violations)) { $known[[string]$v] = $true }
        foreach ($v in @($current)) {
            if (-not $known.ContainsKey([string]$v)) { $failures.Add('新しく床を割りました: ' + $v) | Out-Null }
        }
        $seen = @{}
        foreach ($v in @($current)) { $seen[[string]$v] = $true }
        foreach ($v in @($baseline.violations)) {
            if (-not $seen.ContainsKey([string]$v)) {
                Write-Host ('基準値にあった違反が消えました（-UpdateBaseline で記録し直せます）: ' + [string]$v) -ForegroundColor Green
            }
        }
    } else {
        foreach ($v in @($current)) { $failures.Add('床を割っています: ' + $v) | Out-Null }
    }

    $summary = [pscustomobject]@{
        ok = ($failures.Count -eq 0)
        viewport = ('{0}x{1}' -f $Width, $Height)
        url = $baseUrl
        totals = $report.totals
        states = @(@($report.states) | ForEach-Object {
            [pscustomobject]@{
                state = [string]$_.state
                pageerror = @($_.pageerror.violations).Count
                contrast_checked = if ($_.contrast) { [int]$_.contrast.checked } else { 0 }
                contrast_violations = if ($_.contrast) { @($_.contrast.violations).Count } else { 0 }
                worst_contrast = if ($_.contrast -and $_.contrast.worst) { [double]$_.contrast.worst.ratio } else { $null }
                labels_checked = if ($_.label) { [int]$_.label.checked } else { 0 }
                label_violations = if ($_.label) { @($_.label.violations).Count } else { 0 }
                scroll_width = if ($_.overflow) { [int]$_.overflow.metrics.scrollWidth } else { 0 }
                client_width = if ($_.overflow) { [int]$_.overflow.metrics.clientWidth } else { 0 }
            }
        })
        gate_fire = $gateFire
        report = $reportPath
        failures = @($failures.ToArray())
    }
} finally {
    if ($server) {
        try { if (-not $server.HasExited) { $server.Kill() } } catch {}
        try { $server.WaitForExit(5000) | Out-Null } catch {}
        try { $server.Dispose() } catch {}
    }
    # 孤児を残さない。自分が起動した使い捨てデータ配下の runtime だけを見る。
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        $cl = [string]$p.CommandLine
        if ($cl -like ('*Start-YakuLingo.ps1*-Port {0} *' -f $Port)) {
            try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    if ($null -eq $oldDataDir) { Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $oldDataDir }
    if ($KeepDataDir) { Write-Host ('データ置き場を残しました: ' + $dataDir) -ForegroundColor Yellow }
    else { try { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}

if ($null -ne $summary) { $summary | ConvertTo-Json -Depth 6 }
if ($failures.Count -gt 0) {
    foreach ($f in @($failures.ToArray())) { Write-Host $f -ForegroundColor Red }
    exit 1
}
Write-Host ('UI 床の試験に通りました（{0}x{1}）。' -f $Width, $Height) -ForegroundColor Green
exit 0
