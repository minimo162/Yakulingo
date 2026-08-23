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

   ~~上記の (a)(c)(d)~~ **2026-08-23 に現行の画面へ合わせて書き直した。**
   premium の作業画面では、体裁は格子の下の帯から**常設の右レール**へ変わった
   （cat.html の下部ドックを premium-ui.js の forcePreviewRail() が強制表示し、
   プレビュータブを選んだ状態にする）。仕切りと「畳む」の釦は常設レールには
   置かない（premium-ui.css が両方を display:none）。だから旧門の「既定では
   畳んでいる」「畳むで消える」「仕切りは4px・掴んで動かす・矢印キーで高さを
   変える」は、現行の画面にはもう無い。代わりに、次の3つを固定する。

    (a) 常設レールの既定の姿。開いた資料には、体裁が右に見えていて、
        プレビュータブを選んだ状態で出る。上部の「プレビュー」釦の
        aria-pressed と「参考情報を隠す」の札がその状態を名乗る。
        仕切りと「畳む」は画面に面積を持たない（置かないのが現行の作り）
    (b) **選択が動いても組み直さない。** 従来どおり。選び方はキーボード
        （Alt+↓）に変えた。premium の表は選択中の行だけを描くため、ほかの行の
        訳文欄は DOM にはあっても display:none で、focus を当てても選択は
        動かない（実測 2026-08-23）
    (c) 対の表明。組み直せば本当にノードが外れることを、その場で示す

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

    Write-Host '(a) 常設レールの既定の姿（2026-08-23 に現行契約へ更新）' -ForegroundColor Cyan
    # 旧門「最初は畳んである」は、常設レール化（forcePreviewRail）のときに
    # 役目を終えた。いまの正は「開けば出ている」。畳む釦と仕切りは置かない。
    Chk ([bool]$observed.railVisibleByDefault) '資料を開くと体裁が右に見えている'
    Chk ([int]$observed.railState.width -gt 0 -and [int]$observed.railState.height -gt 0) ('レールに面積がある（' + [int]$observed.railState.width + 'x' + [int]$observed.railState.height + 'px）')
    Chk ([string]$observed.railState.activeTab -eq 'preview') ('プレビュータブを選んだ状態で出る（実際 ' + [string]$observed.railState.activeTab + '）')
    Chk ([string]$observed.railState.toggleAriaPressed -eq 'true') '上部の「プレビュー」釦が押された状態を名乗る（aria-pressed）'
    Chk ([string]$observed.railState.inspectorToggleText -eq '参考情報を隠す') ('状態の札: ' + [string]$observed.railState.inspectorToggleText)
    Chk ([string]$observed.railState.splitterDisplay -eq 'none') '常設レールには仕切りを置かない（display:none。旧4px仕切りの後継確認）'
    Chk ([string]$observed.railState.closeButtonDisplay -eq 'none') '常設レールには「畳む」を置かない（display:none）'
    Chk ([int]$observed.itemCount -ge 3) ('題材の3行が体裁に出る（実際 ' + [int]$observed.itemCount + ' 件）')
    Chk ([int]$observed.bodyLength -gt 50) ('中身が空でない（' + [int]$observed.bodyLength + ' 文字）')

    Write-Host '(b) 選択が動いても組み直さない（選び方は Alt+↓）' -ForegroundColor Cyan
    Chk ([string]$observed.activeBefore -eq '0') ('最初の印は1行目（実際 ' + [string]$observed.activeBefore + '）')
    Chk ([string]$observed.activeAfter -eq '1') ('2行目へ移ると印も移る（実際 ' + [string]$observed.activeAfter + '）')
    # ここが要。**要素そのものが生き残っている＝組み直していない。**
    # 「印を外した HTML が同じ」では見つけられない。組み直しても同じ HTML が
    # 出るので、その測り方はどちらでも緑になる（最初そう書いて空振りだった）。
    Chk ([bool]$observed.nodesSurvived) '体裁の要素が入れ替わっていない（＝組み直していない）'
    # 対の表明。組み直すと本当にノードが外れることを、その場で示す。
    # これが無いと「isConnected はいつも true」という実装でも上が緑になる。
    Chk ([bool]$observed.rebuildDetaches) '組み直せばノードは外れる（上の表明が空振りでないこと）'
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
