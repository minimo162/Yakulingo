<#
.SYNOPSIS
  回帰テストを1本ずつ別プロセスで回し、緑・赤・未測定の3状態で数える。

.DESCRIPTION
  **これが無かったので、掃引の範囲は毎回その場で打つ字面で決まっていた。**
  実際には `Test-YakuV91*` と打つ習慣ができており、その形に合わない4本が
  黙って外れていた（`Test-YakuBootstrap` `Test-YakuEdgeAppMode`
  `Test-YakuPackageLanguageBoundary` `Test-YakuUploadFolderBoundary`）。
  起動・配布の検証がそこに含まれていたので、**いちばん壊れて困るところが
  いちばん回っていなかった**（2026-08-16 に判明）。

  名前をパターンへ合わせる改名は採らない。`Test-YakuBootstrap.ps1` は
  `manifest.json` に載っていて、改名すると配布時の照合が壊れる。
  **範囲のほうをリポジトリに置く。**

  守っている決まりは3つ。出典は CLAUDE.md。

    1. **1本ずつ別プロセス。** `foreach` の中で `& $_.FullName` すると
       `$LASTEXITCODE` と状態が引き継がれ、緑の試験が赤に見える
       （実際に33本中3本を誤って赤と報告した）
    2. **`Start-Process -PassThru` の直後に `$null = $p.Handle`。**
       付けないと `.ExitCode` が `$null` になる。空を「0以外」として赤へ
       畳むと、緑54本を「54本赤」と報告することになる（実際にやりかけた）
    3. **「測れなかった」を「赤」に畳まない。** 緑・赤・未測定は3つの状態
       として数える。畳むと、道具の故障が対象の欠陥に化ける

  件数は補助情報として扱い、**判定は終了コードで行う**。
  `RedirectStandardOutput` の改行が CR 単独になり `Get-Content` が複数行を
  1行に畳むことがあるので、出力を数えて判定してはいけない
  （2026-08-15 に実測183件を55件と数えた）。

  終了コード: 0 = 全部緑 / 1 = 赤あり / 3 = 未測定あり（赤は無い）

.PARAMETER SkipEncoding
  符号化検査を飛ばす。既定では最初に `Check-Encoding.ps1` を通す。

.PARAMETER TimeoutSeconds
  1本あたりの上限。既定 900 秒。超えたものは**赤ではなく未測定**にする。

.PARAMETER MarkerPath
  終わりの目印を書くファイル。中身は ASCII だけなので、読み方（UTF-8 / CP932）を
  間違えても当たる。監視から待つときに使う。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Invoke-YakuSweep.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipEncoding,
    [int]$TimeoutSeconds = 900,
    [string]$MarkerPath = ''
)

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# 掃引に入れない試験と、その理由。**理由を書けないものは外さない。**
# 実在しないものが並んでいたら、この一覧のほうが腐っている合図なので赤にする。
$excluded = [ordered]@{
    'Test-YakuPackage.ps1' = '-PackagePath が要る手動ツール。作った配布物を後から確かめる用で、回帰ではない'
}

$all = @(Get-ChildItem -LiteralPath $toolsRoot -Filter 'Test-Yaku*.ps1' -File | Sort-Object Name)
$roster = New-Object System.Collections.Generic.List[object]
foreach ($file in $all) {
    if ($excluded.Contains($file.Name)) { continue }
    $roster.Add($file) | Out-Null
}

$setupProblems = New-Object System.Collections.Generic.List[string]
foreach ($name in @($excluded.Keys)) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot $name) -PathType Leaf)) {
        $setupProblems.Add(('除外一覧に実在しない試験がある: ' + $name)) | Out-Null
    }
}
if ($roster.Count -eq 0) { $setupProblems.Add('回す試験が1本も見つからない') | Out-Null }

Write-Host ('掃引の対象: ' + $roster.Count + ' 本 / 除外 ' + $excluded.Count + ' 本') -ForegroundColor Cyan
foreach ($name in @($excluded.Keys)) {
    Write-Host ('  除外 ' + $name + ' — ' + [string]$excluded[$name]) -ForegroundColor DarkGray
}
if ($setupProblems.Count -gt 0) {
    foreach ($problem in @($setupProblems.ToArray())) { Write-Host ('  段取りの問題: ' + $problem) -ForegroundColor Red }
}

$encodingState = 'SKIPPED'
if (-not $SkipEncoding) {
    $encodingScript = Join-Path $toolsRoot 'Check-Encoding.ps1'
    if (-not (Test-Path -LiteralPath $encodingScript -PathType Leaf)) {
        $encodingState = 'MISSING'
        $setupProblems.Add('Check-Encoding.ps1 が見つからない') | Out-Null
    }
    else {
        $encodingProcess = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $encodingScript `
            -RedirectStandardOutput (Join-Path $env:TEMP 'yaku-sweep-encoding.out') `
            -RedirectStandardError (Join-Path $env:TEMP 'yaku-sweep-encoding.err')
        $null = $encodingProcess.Handle
        if ($encodingProcess.WaitForExit($TimeoutSeconds * 1000)) {
            $encodingState = if ([int]$encodingProcess.ExitCode -eq 0) { 'GREEN' } else { 'RED' }
        }
        else { $encodingState = 'UNMEASURED' }
    }
    Write-Host ('符号化検査: ' + $encodingState) -ForegroundColor $(if ($encodingState -eq 'GREEN') { 'DarkGray' } else { 'Red' })
}

$green = 0
$red = 0
$unmeasured = 0
$results = New-Object System.Collections.Generic.List[object]
foreach ($file in @($roster.ToArray())) {
    $outPath = Join-Path $env:TEMP ('yaku-sweep-' + $file.BaseName + '.out')
    $errPath = Join-Path $env:TEMP ('yaku-sweep-' + $file.BaseName + '.err')
    $process = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file.FullName `
        -RedirectStandardOutput $outPath -RedirectStandardError $errPath
    # これが無いとプロセスハンドルが保たれず、.ExitCode が $null になる。
    $null = $process.Handle
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    $code = $null
    if ($finished) { $code = [int]$process.ExitCode }

    $state = 'UNMEASURED'
    if ($null -eq $code) { $state = 'UNMEASURED' }
    elseif ($code -eq 0) { $state = 'GREEN' }
    elseif ($code -eq 3) { $state = 'UNMEASURED' }   # 3 は「測れなかった」の合図
    else { $state = 'RED' }

    if ($state -eq 'GREEN') { $green++ } elseif ($state -eq 'RED') { $red++ } else { $unmeasured++ }
    $results.Add([pscustomobject]@{ Name = $file.Name; State = $state; Code = $code }) | Out-Null

    $colour = switch ($state) { 'GREEN' { 'DarkGray' } 'RED' { 'Red' } default { 'Yellow' } }
    # 表示は Write-Host で出す。関数の中で書式化した文字列を裸で置くと戻り値に混ざる。
    Write-Host ('  {0,-10} {1}{2}' -f $state, $file.Name, $(if ($null -ne $code -and $code -ne 0) { ' (exit=' + $code + ')' } else { '' })) -ForegroundColor $colour
}

Write-Host ''
Write-Host ('緑 {0} / 赤 {1} / 未測定 {2}（対象 {3} 本）' -f $green, $red, $unmeasured, $roster.Count) -ForegroundColor Cyan
if ($red -gt 0) {
    Write-Host '赤の内訳:' -ForegroundColor Red
    foreach ($r in @($results.ToArray() | Where-Object { $_.State -eq 'RED' })) {
        Write-Host ('  ' + $r.Name + ' exit=' + $r.Code + ' — 出力は ' + (Join-Path $env:TEMP ('yaku-sweep-' + [IO.Path]::GetFileNameWithoutExtension($r.Name) + '.out'))) -ForegroundColor Red
    }
}
if ($unmeasured -gt 0) {
    Write-Host '未測定の内訳（赤ではない。道具が答えを出せなかった側）:' -ForegroundColor Yellow
    foreach ($r in @($results.ToArray() | Where-Object { $_.State -eq 'UNMEASURED' })) {
        Write-Host ('  ' + $r.Name + ' exit=' + $(if ($null -eq $r.Code) { '(取れず)' } else { [string]$r.Code })) -ForegroundColor Yellow
    }
}

$hasRed = ($red -gt 0) -or ($encodingState -eq 'RED') -or ($setupProblems.Count -gt 0)
$hasUnmeasured = ($unmeasured -gt 0) -or ($encodingState -eq 'UNMEASURED') -or ($encodingState -eq 'MISSING')

# 目印は ASCII だけにする。読み方を間違えても当たる。
$marker = if ($hasRed) { 'SWEEP-DONE-WITH-RED' } elseif ($hasUnmeasured) { 'SWEEP-DONE-WITH-UNMEASURED' } else { 'SWEEP-DONE-ALL-GREEN' }
$summary = ('{0} green={1} red={2} unmeasured={3} encoding={4}' -f $marker, $green, $red, $unmeasured, $encodingState)
Write-Host $summary -ForegroundColor $(if ($hasRed) { 'Red' } elseif ($hasUnmeasured) { 'Yellow' } else { 'Green' })
if (-not [string]::IsNullOrWhiteSpace($MarkerPath)) {
    Set-Content -LiteralPath $MarkerPath -Value $summary -Encoding utf8
}

if ($hasRed) { exit 1 }
if ($hasUnmeasured) { exit 3 }
exit 0
