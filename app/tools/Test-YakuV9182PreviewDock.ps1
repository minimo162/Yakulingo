<#
.SYNOPSIS
  格子の下に常設した体裁を、実機と同じ Chromium で実際に押して確かめる回帰テスト。

.DESCRIPTION
  体裁（プレビュー）は 2026-08-16 まで「体裁で見る」ダイアログの中だけにあった。
  開くと格子が見えないので、**訳しながらの手がかりにならなかった。**
  Smartcat はプレビューを下部に常設し、細い仕切りで広げられ、選択に追随する
  （実測。出典 `_docs/対比_Smartcat_2026-08-16.md`）。

  ここで固定するのは4つ。

   (a) 既定では畳んである。開くと出て、畳めば消える
   (b) **選択が動いても組み直さない。** `buildPreview()` は全行ぶんの HTML を
       作るので、行を移るたびに走らせると行数に比例した費用を毎回払う。
       同じ HTML のまま印だけが動いていることを、文字列そのもので確かめる。
       これは速さの話であると同時に、体裁の中で開いた位置が跳ねないことでもある
   (c) 仕切りが `role="separator"` で、姿が Smartcat の実測（4px・row-resize）に沿う
   (d) **掴めない人のための道がある（WCAG 2.2 SC 2.5.7）。**
       ドラッグでしか動かせない仕切りは、それだけで使えない人が出る。
       矢印キー・Home・End で高さが変わること

  **node と playwright が無い環境では緑にしない。** 走らせられない門を緑に
  すると、道具の不在が「画面はつながっている」という根拠に化ける。
  そのときは未測定（exit 3）を返す。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9182PreviewDock.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YAKU_SCREEN_UNMEASURED = 3
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot

$script:fail = 0
$script:checks = 0
function Chk {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor DarkGray; return }
    Write-Host ('  FAIL ' + $Message) -ForegroundColor Red
    $script:fail++
}

$driver = Join-Path (Join-Path $toolsRoot 'cat-screen') 'preview-dock-gate.js'
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) {
    Write-Host ('UNMEASURED: 運転席がありません: ' + $driver) -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Write-Host 'UNMEASURED: node が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeExe = [string]$nodeCmd.Source
$probeDir = (Split-Path -Parent $driver).Replace('\', '/')
$null = & $nodeExe -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-dock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    # 3行の題材。1行目と2行目に訳文があり、3行目は空。
    # 空の行があると「薄い字」の案内が出るので、その枝も通る。
    $project = [ordered]@{
        id = 'dock-gate'; file_name = '体裁の常設'; source = 'text'; direction = 'to_en'
        revision = 1; saved = '2026-08-16T00:00:00Z'; kind = 'text'
        segments = @(
            [ordered]@{ index = 0; segment_id = 's0'; kind = 'paragraph'; source = '当社は生産体制を見直しました。'; translation = 'We revised our production system.'; confirmed = $false; origin = 'machine' },
            [ordered]@{ index = 1; segment_id = 's1'; kind = 'paragraph'; source = '営業利益は前年から増えました。'; translation = 'Operating income rose from a year earlier.'; confirmed = $false; origin = 'machine' },
            [ordered]@{ index = 2; segment_id = 's2'; kind = 'paragraph'; source = '設備投資も計画どおり進めました。'; translation = ''; confirmed = $false; origin = '' }
        )
    }
    $projectPath = Join-Path $tmp 'project.json'
    [IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $outPath = Join-Path $tmp 'observed.json'
    $wwwDir = (Join-Path $root 'www').Replace('\', '/')

    & $nodeExe $driver $wwwDir $projectPath $outPath 2>&1 | ForEach-Object { Write-Host ('  node: ' + $_) -ForegroundColor DarkGray }
    if (-not (Test-Path -LiteralPath $outPath -PathType Leaf)) {
        Write-Host 'UNMEASURED: 観測結果が返りませんでした。' -ForegroundColor Red
        exit $YAKU_SCREEN_UNMEASURED
    }
    $observed = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$observed.ok) {
        Write-Host ('UNMEASURED: 運転席が最後まで走りませんでした: ' + [string]$observed.error) -ForegroundColor Red
        exit $YAKU_SCREEN_UNMEASURED
    }

    Write-Host '(a) 既定では畳んである。開けば出て、畳めば消える' -ForegroundColor Cyan
    Chk ([bool]$observed.hiddenByDefault) '最初は畳んである（勝手に場所を取らない）'
    Chk ([string]$observed.toggleLabelClosed -eq '体裁を下に出す') ('畳んでいるときの札: ' + [string]$observed.toggleLabelClosed)
    Chk (-not [bool]$observed.hiddenAfterToggle) '押すと出る'
    Chk ([string]$observed.toggleLabelOpen -eq '体裁を畳む') ('出ているときの札: ' + [string]$observed.toggleLabelOpen)
    Chk ([int]$observed.itemCount -ge 3) ('題材の3行が体裁に出る（実際 ' + [int]$observed.itemCount + ' 件）')
    Chk ([int]$observed.bodyLength -gt 50) ('中身が空でない（' + [int]$observed.bodyLength + ' 文字）')
    Chk ([bool]$observed.hiddenAfterClose) '「畳む」で消える'

    Write-Host '(b) 選択が動いても組み直さない' -ForegroundColor Cyan
    Chk ([string]$observed.activeBefore -eq '0') ('最初の印は1行目（実際 ' + [string]$observed.activeBefore + '）')
    Chk ([string]$observed.activeAfter -eq '1') ('2行目へ移ると印も移る（実際 ' + [string]$observed.activeAfter + '）')
    # ここが要。**要素そのものが生き残っている＝組み直していない。**
    # 「印を外した HTML が同じ」では見つけられない。組み直しても同じ HTML が
    # 出るので、その測り方はどちらでも緑になる（最初そう書いて空振りだった）。
    Chk ([bool]$observed.nodesSurvived) '体裁の要素が入れ替わっていない（＝組み直していない）'
    # 対の表明。組み直すと本当にノードが外れることを、その場で示す。
    # これが無いと「isConnected はいつも true」という実装でも上が緑になる。
    Chk ([bool]$observed.rebuildDetaches) '組み直せばノードは外れる（上の表明が空振りでないこと）'

    Write-Host '(c) 仕切りの姿' -ForegroundColor Cyan
    Chk ([string]$observed.splitter.role -eq 'separator') ('role=separator（実際 ' + [string]$observed.splitter.role + '）')
    Chk ([string]$observed.splitter.ariaOrientation -eq 'horizontal') '向きを名乗る'
    Chk ([int]$observed.splitter.height -eq 4) ('高さ4px。Smartcat の実測と同じ（実際 ' + [int]$observed.splitter.height + '）')
    Chk ([string]$observed.splitter.cursor -eq 'row-resize') ('カーソルは row-resize（実際 ' + [string]$observed.splitter.cursor + '）')

    Write-Host '(d) 掴めなくても動かせる（WCAG 2.2 SC 2.5.7）' -ForegroundColor Cyan
    Chk ([string]$observed.splitter.tabindex -eq '0') 'キーボードで焦点が当たる'
    $k = $observed.keyboardResize
    Chk ([string]$k.start -ne [string]$k.up) ('上矢印で高さが変わる: ' + [string]$k.start + ' -> ' + [string]$k.up)
    Chk ([string]$k.up -ne [string]$k.down) ('下矢印でも変わる: ' + [string]$k.up + ' -> ' + [string]$k.down)
    Chk ([string]$k.home -eq ([string]$observed.splitter.valuemin + 'px')) ('Home でいちばん低く: ' + [string]$k.home)
    Chk ([string]$k.end -eq ([string]$observed.splitter.valuemax + 'px')) ('End でいちばん高く: ' + [string]$k.end)
    Chk ([string]$k.aria -eq [string]$observed.splitter.valuemax) ('読み上げ値も追随する: aria-valuenow=' + [string]$k.aria)
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ('V9182 preview dock: PASS (' + $script:checks + ' checks)') -ForegroundColor Green
    exit 0
}
Write-Host ('V9182 preview dock: FAIL (' + $script:fail + ' of ' + $script:checks + ')') -ForegroundColor Red
exit 1
