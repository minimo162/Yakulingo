<#
.SYNOPSIS
  体裁プレビューの右隣空白へのはみ出し描き（issue #107）の回帰試験。

.DESCRIPTION
  判定側（autoSpillColumns・segmentFitRisk）はスピル対応済みで、描画だけが
  自セル幅のボタン＋overflow:hidden のために境界で切れて見えていた状態を
  直したあとの形を固定する。見るのは2つ。

  (a) 静的部。previewCellHtml が is-spill を付け、表示テキストを内側の
      cat-spill-flow へ包むこと。corridor（見せる幅）は判定が使った
      displayWidthPx から実行時の計測値（previewCellChromePx）を引いたもので、
      CSS の数値を写していないこと。契約のピン:
        - var fit = segmentFitRisk(segment, layout, row, column, span, value.text,
          の行は Test-YakuV9196FitVisibility がピンなので字面ごと保持する
        - ボタンの textContent は変わらない（cat-screen-gate.js の cellTexts 系が
          そのまま通る。span で包むのは文字列の外側である）
        - 基本ルール（overflow:hidden の行）は触らない。追加は .is-spill と
          .cat-spill-flow の2ルールだけで、:not() は連ねない

  (b) 実機Chromium部。本物の cat.html/cat.js を配り、6題材の作業を開いて
      「体裁で見る」を実測する（運転席は tools/cat-screen/preview-spill-gate.js）。
        - 右隣空き＋長文(index0): 文字矩形が自セル右端を超え、判定幅（456px）
          以内に収まる。途中の切り抜き箱（overflow が visible 以外の祖先）は
          どれも文字の右端より右にあり、そこまで描き切れている
        - 押し場: 全セルボタンの中心が自分自身で受ける。はみ出しspanは
          pointer-events:none なので、流れた先の右の狭いセルも押せる
          （奪う実装だと V9196 の題材で cell13 のクリックが通らなかった。
          実機実測 2026-08-23）
        - 右隣占有(index1): is-spill は付かず、computed style の overflow は
          hidden、scrollWidth は clientWidth を超える（箱の中で切れている）。
          自セルの右外の当たり判定は他人のセルである
        - 中央寄せ(index2)・折返し(index3)・縮小(index4): is-spill は付かない。
          中央寄せは「収まり要確認」の印も従来どおり付く
        - 右隣空きでも自セルに収まる短さ(index5): is-spill は付き、文字矩形は
          自セルの中にとどまる
      註: Range の矩形はレイアウト箱であって塗りの切り抜きを映さない
      （2026-08-23 の実機実測: overflow:hidden の内側の文で 矩形right 298.9px ／
      クリップ右端 68px）。だから「切れて見える」は Range の矩形だけでは測れず、
      切り抜き箱（overflow計算・scrollWidth）と当たり判定（elementFromPoint）の
      組で測る。index0 の「流れて見える」は、当たり判定が自分であることと
      レイアウト上の文字矩形が自セルを超えることの両立で証明する
      （overflow:hidden は塗りと当たりの両方を切る。当たっている以上、
      そこは切り抜かれておらず、連続する文字列はそこまで描かれている）。
      node/Playwright/Chromium が無い環境では UNMEASURED（exit 3）にする。
      「測れなかった」を赤に畳まない。

  (c) 突然変異の実証。cat.js の is-spill 付与か css の overflow:visible を外すと
      (b) が赤へ落ちる（このファイルの実行だけでは行わない。呼び出し側の手順で
      別プロセス確証を取り、結果をログへ残す）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9212PreviewSpill.ps1
#>
[CmdletBinding()]
param(
    # 既定は利用者の機械の実測（inner 1912x987）。測るのはプレビュー表の内側の
    # 幾何であってアプリ外枠の寸法ではないので、狭い窓での追試は任意とする。
    [string]$Viewport = '1912x987'
)

$ErrorActionPreference = 'Stop'
$N9212Root = Split-Path -Parent $PSScriptRoot
$N9212Www = Join-Path $N9212Root 'www'
$script:N9212Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9212 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9212Failures.Add($Message) }
}

Write-Host 'Test-YakuV9212PreviewSpill'

# ============================================================ (a) 静的部
Write-Host '-- static --'

$N9212CatJsPath = Join-Path $N9212Www 'assets\cat.js'
$N9212CssPath = Join-Path $N9212Www 'assets\cat-workspace.css'
$N9212CatJs = [IO.File]::ReadAllText($N9212CatJsPath, [Text.Encoding]::UTF8)
$N9212Css = [IO.File]::ReadAllText($N9212CssPath, [Text.Encoding]::UTF8)

Assert-N9212 ($N9212CatJs.Contains('var fit = segmentFitRisk(segment, layout, row, column, span, value.text,')) '契約のピン: previewCellHtml の segmentFitRisk 呼び出し行は字面ごと残っている（V9196）'
Assert-N9212 ($N9212CatJs.Contains("canSpill ? ' is-spill' : ''")) 'is-spill は描画側の条件（canSpill）で付く'
Assert-N9212 ($N9212CatJs.Contains('<span class="cat-spill-flow"')) '表示テキストを内側の cat-spill-flow へ包む'
Assert-N9212 ($N9212CatJs.Contains('function previewCellChromePx()')) 'ボタンの左右の余白は実行時に計る（previewCellChromePx）'
Assert-N9212 ($N9212CatJs.Contains('fit.displayWidthPx - previewCellChromePx()')) 'corridor は判定幅から実測の余白を引いたもの（CSSの数値を写さない）'
Assert-N9212 ($N9212CatJs.Contains('(canSpill ? spillFlow : esc(value.text))')) '包まないときは従来どおり素のテキスト（textContent不変）'

Assert-N9212 ($N9212Css.Contains('.app-cat .cat-preview-cell { overflow: hidden; text-overflow: clip; white-space: nowrap; }')) '基本ルール（自セルで切れる）は触っていない'
Assert-N9212 ($N9212Css.Contains('.app-cat .cat-preview-cell.is-spill { position: relative; z-index: 1; overflow: visible; }')) 'is-spill は自セルの外へ見せる（詳細度 (0,3,0)。:not() なし）'
Assert-N9212 ($N9212Css.Contains('.cat-spill-flow { white-space: nowrap; overflow: hidden; text-overflow: clip; pointer-events: none; }')) '内側spanはcorridor幅で切り、押し場は奪わない（pointer-events: none）'

# ============================================================ (b) 実機Chromium部
Write-Host '-- chromium --'

$YAKU_SPILL_UNMEASURED = 3
$N9212Driver = Join-Path $PSScriptRoot 'cat-screen\preview-spill-gate.js'
$N9212Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $N9212Node -or -not (Test-Path -LiteralPath $N9212Driver -PathType Leaf)) {
    Write-Host 'UNMEASURED: node または Chromium 運転席が無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9212Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9212Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_SPILL_UNMEASURED
}
$N9212NodeExe = [string]$N9212Node.Source
$N9212ProbeDir = (Split-Path -Parent $N9212Driver).Replace('\', '/')
$null = & $N9212NodeExe -e ("try{require.resolve('playwright',{paths:['" + $N9212ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9212Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9212Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_SPILL_UNMEASURED
}
$N9212ChromiumPath = & $N9212NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $N9212ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$N9212ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$N9212ChromiumPath) -PathType Leaf)) {
    Write-Host 'UNMEASURED: Playwright Chromium 実行ファイルが無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9212Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9212Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_SPILL_UNMEASURED
}

# --- 題材 ------------------------------------------------------------------
# シート Spill1。列幅は「標準フォントの文字数」（px式は 幅*7+5、24px下限）:
#   A(1)=幅3 → 26px / B,C(2-3)=幅30 → 215px / D(4)=幅10 → 75px
# 行はすべて同じ列並びを使い、題材だけが違う。
#   行1 A1: 右隣空き＋長文（スピルで収まる。risk=false になるのが要点）
#   行2 A2: 右隣占有（B2・C2 を占有にする。今日どおり自セルで切れる）
#   行3 A3: 中央寄せ（右に空きがあってもスピル扱いにしない）
#   行4 A4: 折返し ON
#   行5 A5: 縮小 ON
#   行6 A6: 右隣空きでも自セルに収まる短さ
# 占有セルは歩きの止め金でもある（最終内容列は D=4 になる）。B〜Dには
# セルを置いて格子を描かせる（buildPreview は segment のある列だけ描く）。
# 判定の歩きは layout.occupied（occupied_cells）で止めるので、B/C の segment は
# 歩きを妨げない。B2・C2 だけは占有リストに入れてある（A2 の題材のため）。
$N9212LongText = 'Net sales for the quarter are listed here.'
function New-N9212Segment {
    param([int]$Index, [string]$Id, [string]$Source, [string]$Translation, [string]$Location)
    return [ordered]@{
        index = $Index; segment_id = $Id; source = $Source; translation = $Translation
        kind = 'cell'; location = $Location; confirmed = $false
    }
}
$N9212Segments = New-Object System.Collections.Generic.List[object]
$N9212Segments.Add((New-N9212Segment -Index 0 -Id 'spill-open' -Source 'src open' -Translation $N9212LongText -Location 'Spill1, A1')) | Out-Null
$N9212Segments.Add((New-N9212Segment -Index 1 -Id 'spill-occ' -Source 'src occ' -Translation $N9212LongText -Location 'Spill1, A2')) | Out-Null
$N9212Segments.Add((New-N9212Segment -Index 2 -Id 'spill-center' -Source 'src center' -Translation $N9212LongText -Location 'Spill1, A3')) | Out-Null
$N9212Segments.Add((New-N9212Segment -Index 3 -Id 'spill-wrap' -Source 'src wrap' -Translation $N9212LongText -Location 'Spill1, A4')) | Out-Null
$N9212Segments.Add((New-N9212Segment -Index 4 -Id 'spill-shrink' -Source 'src shrink' -Translation $N9212LongText -Location 'Spill1, A5')) | Out-Null
$N9212Segments.Add((New-N9212Segment -Index 5 -Id 'spill-short' -Source 'src short' -Translation 'OK' -Location 'Spill1, A6')) | Out-Null
# 格子を描くための埋め草。中身は空の文字列にする。Excel の「右隣の空きセル」は
# 値が無いセルであり、何も描かない。埋め草にまで文字を入れると、そのセルも
# is-spill（relative + z-index 1）になってしまい、木順であとの隣セルが
# 手前に来る。Excel の意味論では隣接するはみ出し描きは重なり得ない
# （値のあるセルは歩きの止め金になる）ので、空の文字列が正しい。
# 判定の歩きは layout.occupied（occupied_cells）で止めるので、空の埋め草は
# 歩きを妨げない。B2 だけは「右隣に内容がある」題材なので文字を持つ。
$N9212Fillers = @(
    @('B1', ''), @('C1', ''), @('D1', ''),
    @('B2', 'NEIGHBOR'), @('C2', ''), @('D2', ''),
    @('B3', ''), @('C3', ''), @('D3', ''),
    @('B4', ''), @('C4', ''), @('D4', ''),
    @('B5', ''), @('C5', ''), @('D5', ''),
    @('B6', ''), @('C6', ''), @('D6', '')
)
$N9212Next = 6
foreach ($f in $N9212Fillers) {
    $N9212Segments.Add((New-N9212Segment -Index $N9212Next -Id ('fill-' + $f[0]) -Source ([string]$f[1]) -Translation ([string]$f[1]) -Location ('Spill1, ' + $f[0]))) | Out-Null
    $N9212Next++
}
$N9212Project = [ordered]@{
    id = 'preview-spill-9212'; revision = 1; file_name = 'spill.xlsx'; document_format = 'xlsx'; direction = 'to_en'
    segments = $N9212Segments.ToArray()
    sheet_layout = @(
        [ordered]@{
            name = 'Spill1'; default_width = 8.43; default_height = 18.75
            columns = @(
                [ordered]@{ min = 1; max = 1; width = 3; hidden = $false }
                [ordered]@{ min = 2; max = 3; width = 30; hidden = $false }
                [ordered]@{ min = 4; max = 4; width = 10; hidden = $false }
            )
            unknown_width_columns = @()
            merges = @()
            occupied_cells = @('D1', 'B2', 'C2', 'D2', 'D3', 'D4', 'D5', 'D6')
            formula_cells = @()
            rows = @()
            cells = @(
                [ordered]@{ address = 'A3'; align = 'center' },
                [ordered]@{ address = 'A4'; wrap = $true },
                [ordered]@{ address = 'A5'; shrink = $true }
            )
        }
    )
}

# 判定幅（displayWidthPx）の基準。cat.js の列幅の式（幅*7+5、24px下限）を
# 題材の既知の列幅から独立に出す（実装を呼ばない・覗かない）。
function Get-N9212ColumnPx {
    param([double]$CharWidth)
    return [Math]::Max(24, [int][Math]::Round($CharWidth * 7 + 5))
}
$N9212OwnPx = Get-N9212ColumnPx -CharWidth 3
$N9212EmptyPx = Get-N9212ColumnPx -CharWidth 30
$N9212DisplayWidthOpen = $N9212OwnPx + (2 * $N9212EmptyPx)

$N9212Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9212-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $N9212Work -Force
$N9212OutJson = Join-Path $N9212Work 'out.json'
try {
    $payloadPath = Join-Path $N9212Work 'payload.json'
    [IO.File]::WriteAllText($payloadPath, ([ordered]@{ main = $N9212Project } | ConvertTo-Json -Depth 16 -Compress), (New-Object Text.UTF8Encoding($false)))

    & $N9212NodeExe $N9212Driver $N9212Www $payloadPath $N9212OutJson $Viewport
    $N9212DriverExit = $LASTEXITCODE
    Assert-N9212 ($N9212DriverExit -eq 0 -and (Test-Path -LiteralPath $N9212OutJson -PathType Leaf)) 'headless Chromium が実際の CAT 画面を開き、「体裁で見る」を測れた'

    $N9212Result = $null
    if (Test-Path -LiteralPath $N9212OutJson -PathType Leaf) { $N9212Result = [IO.File]::ReadAllText($N9212OutJson, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    if ($null -ne $N9212Result) {
        foreach ($e in @($N9212Result.errors)) { Write-Host ('  Chromium error: ' + [string]$e) -ForegroundColor Red }
        foreach ($c in @($N9212Result.console)) { Write-Host ('  Chromium console: ' + [string]$c) -ForegroundColor Red }
        if ($N9212Result.fatal) { Write-Host ('  Chromium fatal: ' + [string]$N9212Result.fatal) -ForegroundColor Red }
    }
    Assert-N9212 ($null -ne $N9212Result -and @($N9212Result.errors).Count -eq 0 -and @($N9212Result.console).Count -eq 0 -and -not $N9212Result.fatal) '画面にエラーが出ていない'

    if ($null -ne $N9212Result -and $null -ne $N9212Result.cells) {
        $N9212Cells = @($N9212Result.cells)
        # 戻り値は ,@(...) で包む。包まないと要素1個のとき関数の外へ解かれて
        # スカラーになり、PS 5.1 の PSCustomObject には .Count が無い
        # （実測: $open.Count は空。@($open).Count なら 1）ので、件数の比較が
        # 黙って偽になる。
        function Get-N9212Cell { param([int]$Index) return ,@($N9212Cells | Where-Object { [int]$_.index -eq $Index }) }

        # --- 右隣空き＋長文: 隣セル上へ流れ、判定幅以内に収まる -------------------
        $open = Get-N9212Cell -Index 0
        Assert-N9212 ($open.Count -eq 1 -and [bool]$open[0].onScreen) 'index0 のセルが1個あり、画面内で測れた'
        if ($open.Count -eq 1) {
            $o = $open[0]
            Assert-N9212 ([bool]$o.isSpill -and [bool]$o.hasFlow) 'index0: is-spill が付き、テキストは cat-spill-flow に包まれる'
            Assert-N9212 ([string]$o.text -ceq $N9212LongText) 'index0: textContent は変わらない（包みは外側）'
            $flowedPast = ([double]$o.textRect.right - [double]$o.rect.right)
            Assert-N9212 ($flowedPast -gt 20) ('index0: 文字矩形が自セル右端を超える（超過量 ' + [Math]::Round($flowedPast, 1) + 'px。自セル ' + $N9212OwnPx + 'px／判定幅 ' + $N9212DisplayWidthOpen + 'px）')
            $withinCorridor = ([double]$o.rect.left + $N9212DisplayWidthOpen + 1) - [double]$o.textRect.right
            Assert-N9212 ($withinCorridor -ge -1) ('index0: 文字矩形は判定幅（' + $N9212DisplayWidthOpen + 'px）以内にとどまる（余裕 ' + [Math]::Round($withinCorridor, 1) + 'px）')
            Assert-N9212 (([double]$o.flowRect.right + 0.6) -ge [double]$o.textRect.right) 'index0: 内側spanの切り抜き右端が文字矩形を覆う'
            Assert-N9212 (([double]$o.flowRect.right + 1) -le ([double]$o.rect.left + $N9212DisplayWidthOpen)) 'index0: 内側spanの右端は判定幅を超えない'
            # 途中の切り抜き箱（overflow が visible 以外の祖先）は、どれも文字の
            # 右端より右になければならない。ひとつでも手前に切れたら、そこで見えなくなる。
            $cutByClip = @(@($o.clips) | Where-Object { [double]$_.right + 0.6 -lt [double]$o.textRect.right })
            Assert-N9212 (@($cutByClip).Count -eq 0) ('index0: 途中の切り抜きは文字を切らない（切る箱 ' + @($cutByClip).Count + '個）')
            Assert-N9212 ([string]$o.overflowStyle -eq 'visible') 'index0: computed style の overflow は visible'
            Assert-N9212 ([bool]$o.hitBeyondSelf.ours -eq $false) ('index0: 自セル右外の当たり判定は他人（spanは押し場を奪わない。実測 tag=' + $o.hitBeyondSelf.tag + '）')
            Assert-N9212 (-not [bool]$o.overflowRiskClass -and [string]$o.ariaLabel -eq '') 'index0: スピルで収まるので「収まり要確認」の印は付かない（判定どおり）'
        }

        # --- 右隣占有: 従来どおり自セルの中で切れる --------------------------------
        $occ = Get-N9212Cell -Index 1
        Assert-N9212 ($occ.Count -eq 1 -and [bool]$occ[0].onScreen) 'index1 のセルが1個あり、画面内で測れた'
        if ($occ.Count -eq 1) {
            $p = $occ[0]
            Assert-N9212 (-not [bool]$p.isSpill -and -not [bool]$p.hasFlow) 'index1: is-spill は付かない'
            Assert-N9212 ([string]$p.overflowStyle -eq 'hidden') 'index1: computed style の overflow は hidden（基本ルールのまま）'
            Assert-N9212 ([int]$p.scrollWidth -gt [int]$p.clientWidth) ('index1: 文字は箱より広い（scrollWidth ' + $p.scrollWidth + ' / clientWidth ' + $p.clientWidth + '）。そして箱の中で切れる')
            Assert-N9212 ($null -ne $p.hitBeyondSelf -and -not [bool]$p.hitBeyondSelf.ours) ('index1: 自セル右外は他人のセル（実測 tag=' + $p.hitBeyondSelf.tag + '）')
            $sweep = $p.sweepLastInsideDx
            Assert-N9212 ($null -eq $sweep -or [int]$sweep -le 4) ('index1: 自分の部品は自セル右外に出ていない（実測 dx=' + $(if ($null -eq $sweep) { 'none' } else { $sweep }) + 'px）')
            Assert-N9212 ([string]$p.text -ceq $N9212LongText) 'index1: textContent は従来どおり'
        }

        # --- 中央寄せ・折返し・縮小: スピル扱いにしない -----------------------------
        $center = Get-N9212Cell -Index 2
        if ($center.Count -eq 1) {
            Assert-N9212 (-not [bool]$center[0].isSpill -and -not [bool]$center[0].hasFlow) 'index2: 中央寄せは is-spill にならない'
            Assert-N9212 ([bool]$center[0].overflowRiskClass) 'index2: 中央寄せは自セル幅で判定される（「収まり要確認」のまま）'
        } else { Assert-N9212 $false 'index2 のセルが見つかる' }
        $wrap = Get-N9212Cell -Index 3
        if ($wrap.Count -eq 1) {
            Assert-N9212 (-not [bool]$wrap[0].isSpill -and -not [bool]$wrap[0].hasFlow) 'index3: 折返しは is-spill にならない'
            Assert-N9212 ([string]$wrap[0].whiteSpaceStyle -eq 'pre-wrap') 'index3: 折返しは従来どおり pre-wrap'
        } else { Assert-N9212 $false 'index3 のセルが見つかる' }
        $shrink = Get-N9212Cell -Index 4
        if ($shrink.Count -eq 1) {
            Assert-N9212 (-not [bool]$shrink[0].isSpill -and -not [bool]$shrink[0].hasFlow) 'index4: 縮小は is-spill にならない'
        } else { Assert-N9212 $false 'index4 のセルが見つかる' }

        # --- 右隣空きでも収まる短さ: 印は付き、文字は自セルの中 ---------------------
        $short = Get-N9212Cell -Index 5
        if ($short.Count -eq 1) {
            Assert-N9212 ([bool]$short[0].isSpill -and [bool]$short[0].hasFlow) 'index5: 条件を満たすので is-spill は付く（描画側の条件は収まりの有無を見ない）'
            $overhang = ([double]$short[0].textRect.right - [double]$short[0].rect.right)
            Assert-N9212 ($overhang -le 1.0) ('index5: 文字矩形は自セルの中（超過 ' + [Math]::Round($overhang, 1) + 'px、1px未満の測定誤差）')
        } else { Assert-N9212 $false 'index5 のセルが見つかる' }

        # --- 押し場: はみ出しspanが右のセルの押し場を奪っていないこと -------------
        Assert-N9212 ($null -ne $N9212Result.notReceivable -and @($N9212Result.notReceivable).Count -eq 0) '全セルボタンの中心は自分自身で受ける（pointer-events:none の効き目）'
    }
} finally {
    try { Remove-Item -LiteralPath $N9212Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:N9212Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9212PreviewSpill'
    exit 0
}
Write-Host ("FAIL " + $script:N9212Failures.Count + ' assertion(s)')
foreach ($f in @($script:N9212Failures)) { Write-Host ('  - ' + $f) }
exit 1
