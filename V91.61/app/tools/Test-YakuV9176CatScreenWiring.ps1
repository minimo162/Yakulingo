<#
.SYNOPSIS
  画面の描画と配線を、実機と同じ Chromium で**実際に押して**確かめる回帰テスト。

.DESCRIPTION
  なぜ要るか。ここまで画面側の表明は `-match 'data-cat-split-at'` のような
  字面の在否だけだった。2026-08-15 に19通り壊して測ったところ、次の6通りが
  **全部緑のまま**通った。

   - 分割ボタンを描かない（`if (segment.can_split_at)` を `if (false && …)`）
   - Alt+S を殺す（キー分岐の `!event.ctrlKey` を `event.ctrlKey` へ）
   - Ctrl+H を殺す（キー分岐条件を `false && …` へ）
   - 「訳文を置き換える」ボタンを runReplace から外す
   - 「探す場所が原文だけなら訳文を書き換えない」歯止めを3か所とも外す
   - 用語の印が入った行で、押した位置が拾えない（前の位置で黙って割れる）

  字面は「描かれているか」も「つながっているか」も見ていない。ここでは
  本物の cat.html / cat.js を Chromium へ読ませ、実際に押し、出た DOM と
  飛んだ要求の中身を見る。判定はこのファイルが行い、ブラウザ側
  （tools/cat-screen/cat-screen-gate.js）は観測した事実を JSON で返すだけである。

  見るのは9つ。
   (a) can_split_at の行にだけ分割ボタンが**実際に出る**
   (b) Alt+S がその分割ボタンを押す。割れない行では断る
   (c) 用語の印が入った原文でも、押した位置で割れる（位置が一致する）
   (d) Ctrl+H が検索と置換を開き、入力欄へ入る
   (e) 「訳文を置き換える」ボタンが置換の口へつながっている
   (f) 探す場所が原文だけのとき、押しても要求が飛ばない
   (g) 画面が JavaScript の例外を出していない
   (h) 「体裁で見る」が、配置先の無い行でも**後半の訳文まで**出し、しかも
       **繋ぎ方の規則どおり**に出す（`AB-1234` であって `AB- 1234` ではない）
   (i) 「体裁で見る」が、配置先のある cell 行では destination.text をそのまま置く

  (h) は 2026-08-15 の欠陥（引き継ぎ 5-2）。原文の途中で割った行を1つへまとめる
  ときに、原文だけを繋いで訳文は part 1 のままにしていた。配置先のある cell 行は
  サーバが計算した destination.text を使うので正しく出るが、貼り付け本文や Word の
  ように**配置先が無い行**は後半の訳が画面から消えた。書き出しは
  Group-YakuCatSplitSegments を通るので正しい。つまり「画面で見た通りに出る」
  という前提だけが破れる、いちばん見つけにくい壊れ方である。

  (h) の題材は**2組**入れる。1組目（`当社は…、|調達費も…`）は日本語の文の
  切れ目なので空白1つで繋ぐ。**この組だけでは、素朴な `.join(' ')` でも
  Join-YakuCatSplitTranslations でも同じ文字列になり、「サーバの値を使ったか」
  しか測れなかった**（2026-08-15 に見つけた門そのものの欠陥）。2組目
  （`型式はAB-|1234を採用します。`）はトークンの内側なので詰めて繋ぐ。
  これで繋ぎ方を写経した実装が実機で赤になる。

  (i) は 2026-08-15 時点で振る舞いの門が1つも無かった枝。placement.destinations
  の text を空文字にしても、当時の54本は全部緑のまま通った。(h) を直したときに
  whole.translation が「組を繋いだ値」を運ぶようになったので、この2つを
  入れ替える1行の書き換えで壊れる距離にある。1つの意味単位を A1・A2 の2セルへ
  分けて載せる題材にして、行そのものの訳文とは違う文字が各セルに出ることを見る。

  (c) は「押した位置」をアプリとは別に測る。ブラウザが決めたキャレット位置を
  capture 段の覗き窓で採り、アプリが送った位置と突き合わせる。どちらか一方の
  実装で両方を作ると、同じように壊せば何も落ちない。

  node と playwright が無い環境では**緑にしない**。走らせられない門を緑に
  すると、字面の表明と同じものになる。終了コード 3（未測定）で抜ける。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9176CatScreenWiring.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0
$YAKU_SCREEN_UNMEASURED = 3

function Chk { param([bool]$c,[string]$m) $script:checks++; if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$driver = Join-Path (Join-Path $toolsRoot 'cat-screen') 'cat-screen-gate.js'
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) { Write-Host ('UNMEASURED: 運転席がありません: ' + $driver) -ForegroundColor Red; exit $YAKU_SCREEN_UNMEASURED }

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Write-Host 'UNMEASURED: node が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    Write-Host '  この結果を「画面はつながっている」根拠に使わないこと。' -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeExe = [string]$nodeCmd.Source
# playwright は配布物には入らない開発用の依存（リポジトリ直下の package.json）。
# 解決の起点は運転席のあるディレクトリにする（node の探索と同じ順で上へ辿る）。
$probeDir = (Split-Path -Parent $driver).Replace('\', '/')
$null = & $nodeExe -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    Write-Host '  リポジトリ直下で npm install / npx playwright install chromium を通してから、もう一度。' -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}

# 読み込み順序は SrcModules.ps1 が唯一の出典。写すと写し間違いが静かに効く。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-screen-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

$settings = Read-YakuSettings -Root $root
$script:YakuRoot = $root

# セル1つぶんの最小 project。Excel が無くても配置計画（PlacementPlan）まで
# 通せる形にする。中身は Test-YakuV9173SegmentSplitAt.ps1 の同名の作りと同じ。
$screenSafeStructure = [pscustomobject]@{contract_version='excel-cell-structure-v2';read_status='verified';merge_kind='none';merge_area='';has_formula=$false;has_array_formula=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none';wrap_text='False'}
$screenSafeStructureHash = Get-YakuCatSourceIntegrityHash -Text ($screenSafeStructure | ConvertTo-Json -Depth 6 -Compress)
function New-YakuCatScreenCellProject {
    param([Parameter(Mandatory=$true)][string[]]$Texts)
    $segments = New-Object System.Collections.Generic.List[object]
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Texts.Count; $i++) {
        $address = 'A' + [string]($i + 1)
        $blockId = 'b' + [string]($i + 1)
        $cell = [pscustomobject]@{Text=[string]$Texts[$i];Address=$address;Row=($i+1);Column=1;IsText=$true;IsMerged=$false;BlockId=$blockId;SheetCodeName='Sheet1';StructureContract=$screenSafeStructure;StructureFingerprint=$screenSafeStructureHash}
        [void]$segments.Add([pscustomobject]@{
            SegmentId=''; Text=[string]$Texts[$i]; Translation=''; Origin=''; Kind='cell'
            BlockIds=@($blockId); Cells=@($cell); Sheet='Sheet1'; Location=('Sheet1, ' + $address); Joined=$false
        })
        [void]$blocks.Add([pscustomobject]@{Id=$blockId;Text=[string]$Texts[$i];Location=('Sheet1, ' + $address);Meta=[pscustomobject]@{Kind='cell';Sheet='Sheet1';Row=($i+1);Col=1;A1=$address;Merged=$false;SheetCodeName='Sheet1';StructureContract=$screenSafeStructure;StructureFingerprint=$screenSafeStructureHash}})
    }
    $project = [pscustomobject]@{
        Id=([guid]::NewGuid().ToString('N')); Path=(Join-Path $tmp 'nonexistent.xlsx'); FileName='in.xlsx'
        ActiveSourceId=('1'*32); SourceArtifactSha256=('5'*64); Revision=1; Source='file'; DocumentFormat='xlsx'
        Direction='to_en'; TerminologySnapshotHash=''; Segments=@($segments.ToArray()); Blocks=@($blocks.ToArray())
        PlacementPlans=@(); PlacementSetHash=''; DocumentFindings=@(); ReviewRuns=@(); ReviewEvents=@(); FinalReviewDecisions=@()
        CreatedAt=(Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    return $project
}

# 題材。1行目は割れる行で、登録用語が**先頭ではなく途中**に入る。
# 押す位置（12文字目）は、その印より後ろに落ちる。ここが要点で、印より前だけを
# 見ていた実装は、この位置を拾えないまま「前に拾えた位置」で割っていた。
$source = '当社は生産体制を見直し、調達費も削減しました。'
$term = '生産体制'
$termEnd = $source.IndexOf($term) + $term.Length
$clickChar = 12

try {
    Write-Host '(0) 題材を、実装が作る応答そのものから用意する' -ForegroundColor Cyan
    $project = New-YakuCatTextProject -Root $root -Text ($source + "`n" + '営業利益は増えました。' + "`n" + '設備投資も進めました。') -Settings $settings -Direction 'to_en'
    Chk (@($project.Segments).Count -eq 3) ('貼り付け本文は3行に切り分けられる（実際 ' + @($project.Segments).Count + '）')
    # 2行目と3行目を繋いで「割れない行」を作る。can_split_at=false を人が書かない。
    $null = Merge-YakuCatSegments -Project $project -Index 1
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'The Company reviewed its production system and cut procurement costs.'
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 1 -Text 'The Company posted higher operating profit and more capital spending.'
    $projectJson = ConvertTo-YakuCatProjectJson -Project $project
    $view = $projectJson | ConvertFrom-Json
    $viewRows = @($view.segments)
    Chk ($viewRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $viewRows.Count + '）')
    Chk ([bool]$viewRows[0].can_split_at -and -not [bool]$viewRows[1].can_split_at) '1行目は割れる・2行目は割れない（描き分けを見る題材である）'
    Chk ([string]$viewRows[0].source -eq $source) '1行目の原文は題材どおり'

    $candidates = [ordered]@{
        terms = @(
            [ordered]@{
                kind='term'; source=$term; translation='production system'; target='production system'
                source_name='用語集'; scope='project'; term_id=('t'*32); term_version=1; reference_id=('a'*32)
                allowed_targets=@(); forbidden_targets=@()
            }
        )
        segment_matches = @()
    }
    # 「体裁で見る」の題材は別に作る。上の作業は分割ボタンの描き分けを見るために
    # わざと割っていないので、割った状態を混ぜると (a) の題材が崩れる。
    # こちらは**貼り付け本文を実際に割った**もの。配置先（placement）が無い行で、
    # 画面はサーバが繋いだ訳文を使うほかない。
    #
    # 組は2つ入れる。1つ目（`当社は…、|調達費も…`）は日本語の文の切れ目なので
    # 空白1つで繋ぐ。2つ目（`型式はAB-|1234を採用します。`）はトークンの内側なので
    # 詰めて繋ぐ。**1つ目だけでは、素朴な `.join(' ')` と
    # Join-YakuCatSplitTranslations が同じ答えを返す**ので、繋ぎ方の規則が
    # 測れていなかった（2026-08-15 の門の欠陥）。2つ目が入って初めて、写経した
    # 実装が実機で赤になる。
    Write-Host '(0b) 「体裁で見る」の題材を、原文の途中で実際に割って用意する' -ForegroundColor Cyan
    $previewHeadText = 'We reviewed our production system.'
    $previewTailText = 'We also reduced procurement costs.'
    $previewJoinedText = $previewHeadText + ' ' + $previewTailText
    $previewOtherText = 'Operating profit rose.'
    $previewSplitAt = $source.IndexOf([char]'、') + 1
    Chk ($previewSplitAt -gt 0 -and $previewSplitAt -lt $source.Length) ('割る位置は原文の途中（' + $previewSplitAt + ' / ' + $source.Length + '）')
    # トークンの内側で割った組。位置6は `-` と `1` の間である。
    $tokenText = '型式はAB-1234を採用します。'
    $tokenSplitAt = 6
    $tokenHeadText = 'The model is AB-'
    $tokenTailText = '1234 will be adopted.'
    $tokenJoinedText = 'The model is AB-1234 will be adopted.'
    $tokenLooseText = 'The model is AB- 1234 will be adopted.'
    Chk ($tokenText.Substring(0, $tokenSplitAt) -eq '型式はAB-' -and $tokenText.Substring($tokenSplitAt) -eq '1234を採用します。') ('位置' + $tokenSplitAt + 'で割ると `型式はAB-` と `1234を採用します。` になる')
    Chk (Test-YakuCatSplitPositionInsideToken -Text $tokenText -Position $tokenSplitAt) 'その位置はトークンの内側である（だから Split-YakuCatSegmentAt では作れず、手で組む）'
    # ここが要点。**2つの繋ぎ方が違う答えを返す題材であること**を先に確かめる。
    # これが同じなら、この先の (h) は「サーバの値を使ったか」しか測れない。
    Chk ((Join-YakuCatSplitTranslations -Parts @($tokenHeadText, $tokenTailText)) -eq $tokenLooseText) ('素朴に繋ぐと空白が入る（写経した実装が出す文字列）: ' + $tokenLooseText)
    Chk ((Join-YakuCatSplitTranslations -Parts @($tokenHeadText, $tokenTailText) -Sources @($tokenText.Substring(0, $tokenSplitAt), $tokenText.Substring($tokenSplitAt))) -eq $tokenJoinedText) ('規則どおり繋ぐと詰まる: ' + $tokenJoinedText)
    Chk ($tokenJoinedText -ne $tokenLooseText) '2つの繋ぎ方は違う答えを返す（この題材は繋ぎ方そのものを測れる）'
    Chk ((Join-YakuCatSplitTranslations -Parts @($previewHeadText, $previewTailText)) -eq (Join-YakuCatSplitTranslations -Parts @($previewHeadText, $previewTailText) -Sources @($source.Substring(0, $previewSplitAt), $source.Substring($previewSplitAt)))) '1つ目の組はどちらの繋ぎ方でも同じ（この組だけでは繋ぎ方を測れない、という事実そのもの）'
    $previewProject = New-YakuCatTextProject -Root $root -Text ($source + "`n" + $tokenText + "`n" + '営業利益は増えました。') -Settings $settings -Direction 'to_en'
    $previewIndex = -1
    $previewSegs = @($previewProject.Segments)
    for ($i = 0; $i -lt $previewSegs.Count; $i++) { if ([string]$previewSegs[$i].Text -eq $source) { $previewIndex = $i } }
    Chk ($previewIndex -ge 0) '割る対象の行が取れる'
    $null = Split-YakuCatSegmentAt -Project $previewProject -Index $previewIndex -Position $previewSplitAt
    Chk (@($previewProject.Segments).Count -eq 4) ('割ると4行になる（実際 ' + @($previewProject.Segments).Count + '）')
    # トークンの内側は Split-YakuCatSegmentAt が正しく止めるので、**既に割ってある
    # 資料**と同じ形（New-YakuCatSplitPart）で組み立てる。利用者の作業を巻き戻さない
    # と決めた以上、この形は実際に画面へ来る（決定 2026-08-15）。
    $tokenIndex = -1
    $tokenSegs = @($previewProject.Segments)
    for ($i = 0; $i -lt $tokenSegs.Count; $i++) { if ([string]$tokenSegs[$i].Text -eq $tokenText) { $tokenIndex = $i } }
    Chk ($tokenIndex -ge 0) 'トークンを含む行が取れる'
    $tokenRefused = $false
    try { $null = Split-YakuCatSegmentAt -Project $previewProject -Index $tokenIndex -Position $tokenSplitAt } catch { $tokenRefused = $true }
    Chk $tokenRefused '今の実装は、この位置での分割を断る（だから手で組む。門を緩めるためではない）'
    Chk (@($previewProject.Segments).Count -eq 4) '断られたので行は増えていない'
    $tokenGroup = [guid]::NewGuid().ToString('N')
    $tokenOrigin = $tokenSegs[$tokenIndex]
    $tokenOut = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $tokenSegs.Count; $i++) {
        if ($i -ne $tokenIndex) { [void]$tokenOut.Add($tokenSegs[$i]); continue }
        foreach ($piece in @($tokenText.Substring(0, $tokenSplitAt), $tokenText.Substring($tokenSplitAt))) {
            [void]$tokenOut.Add((New-YakuCatSplitPart -Source $tokenOrigin -Text $piece -GroupId $tokenGroup -OriginSegmentId ([string]$tokenOrigin.SegmentId)))
        }
    }
    $null = Set-YakuCatSegments -Project $previewProject -Segments $tokenOut.ToArray()
    $null = Update-YakuCatSplitOrdinals -Project $previewProject
    Chk (@($previewProject.Segments).Count -eq 5) ('手で割った組を足して5行になる（実際 ' + @($previewProject.Segments).Count + '）')
    Chk ([string]@($previewProject.Segments)[$tokenIndex].Text -eq $tokenText.Substring(0, $tokenSplitAt)) '手で割った1行目の原文は `型式はAB-`'
    $null = Set-YakuCatSegmentTranslation -Project $previewProject -Index $previewIndex -Text $previewHeadText
    $null = Set-YakuCatSegmentTranslation -Project $previewProject -Index ($previewIndex + 1) -Text $previewTailText
    $null = Set-YakuCatSegmentTranslation -Project $previewProject -Index $tokenIndex -Text $tokenHeadText
    $null = Set-YakuCatSegmentTranslation -Project $previewProject -Index ($tokenIndex + 1) -Text $tokenTailText
    for ($i = 0; $i -lt @($previewProject.Segments).Count; $i++) {
        if ([string]::IsNullOrWhiteSpace([string]@($previewProject.Segments)[$i].Translation)) { $null = Set-YakuCatSegmentTranslation -Project $previewProject -Index $i -Text $previewOtherText }
    }
    $previewProjectJson = ConvertTo-YakuCatProjectJson -Project $previewProject
    $previewView = $previewProjectJson | ConvertFrom-Json
    $previewRowsPs = @($previewView.segments)
    Chk ($previewRowsPs.Count -eq 5) ('画面へ渡す行は5行（実際 ' + $previewRowsPs.Count + '）')
    Chk ([string]$previewRowsPs[$previewIndex].split_group -ne '' -and [int]$previewRowsPs[$previewIndex].split_part -eq 1) '割った組の1行目である'
    Chk ($null -eq $previewRowsPs[$previewIndex].placement) '配置先が無い行である（この題材が空振りでないこと）'
    Chk ([string]$previewRowsPs[$previewIndex].translation -eq $previewHeadText) '行そのものの訳文は前半だけ（画面がこれを描くと後半が消える）'
    Chk ([string]$previewRowsPs[$previewIndex].split_translation -eq $previewJoinedText) ('応答は繋いだ訳文を持っている: ' + [string]$previewRowsPs[$previewIndex].split_translation)
    Chk ([string]$previewRowsPs[$tokenIndex].split_group -ne '' -and [int]$previewRowsPs[$tokenIndex].split_part -eq 1) 'トークンの組も、割った組の1行目として渡る'
    Chk ($null -eq $previewRowsPs[$tokenIndex].placement) 'トークンの組にも配置先が無い（画面は繋いだ訳文を使うほかない）'
    Chk ([string]$previewRowsPs[$tokenIndex].translation -eq $tokenHeadText) 'トークンの組も、行そのものの訳文は前半だけ'
    Chk ([string]$previewRowsPs[$tokenIndex].split_translation -eq $tokenJoinedText) ('トークンの組の繋いだ訳文は詰まっている: ' + [string]$previewRowsPs[$tokenIndex].split_translation)
    Chk ([string]$previewRowsPs[$tokenIndex].split_translation -notmatch 'AB- 1234') '画面へ渡す値の時点で `AB- 1234` になっていない'

    # 配置先のある cell 行の題材。1つの意味単位が A1・A2 の2セルへ分かれて載るので、
    # 画面が置ける文字列は placement.destinations[].text しか無い。行そのものの
    # 訳文には「どこで切るか」が入っていないからである。この枝には振る舞いの門が
    # 1つも無く、text を空にしても全部緑のまま通っていた（2026-08-15 の門の欠陥）。
    Write-Host '(0c) 配置先のある cell 行の題材を、実装が作る配置計画から用意する' -ForegroundColor Cyan
    $cellHeadSource = '当社は生産体制を見直し、'
    $cellTailSource = '調達費も削減しました。'
    $cellTranslation = 'The Company reviewed its production system and cut procurement costs.'
    $cellProject = New-YakuCatScreenCellProject -Texts @($cellHeadSource, $cellTailSource)
    Chk (@($cellProject.Segments).Count -eq 2) ('セル2つぶんの作業を作れた（実際 ' + @($cellProject.Segments).Count + '）')
    # 2セルを1つの意味単位へ繋ぐ。can_merge と同じ判定を通る実装で繋ぐ（手で
    # Joined を立てない）。
    $null = Merge-YakuCatSegments -Project $cellProject -Index 0
    Chk (@($cellProject.Segments).Count -eq 1) '繋ぐと1行になる'
    Chk (@(@($cellProject.Segments)[0].Cells).Count -eq 2) '1行が2つのセルを指している（この題材が空振りでないこと）'
    $null = Set-YakuCatSegmentTranslation -Project $cellProject -Index 0 -Text $cellTranslation
    $null = Sync-YakuCatPlacementPlans -Project $cellProject
    Chk (@($cellProject.PlacementPlans).Count -eq 1) ('配置計画が1つできる（実際 ' + @($cellProject.PlacementPlans).Count + '）')
    $cellProjectJson = ConvertTo-YakuCatProjectJson -Project $cellProject
    $cellView = $cellProjectJson | ConvertFrom-Json
    $cellRowsPs = @($cellView.segments)
    Chk ($cellRowsPs.Count -eq 1) ('画面へ渡す行は1行（実際 ' + $cellRowsPs.Count + '）')
    Chk ([string]$cellRowsPs[0].kind -eq 'cell') '行の種類は cell'
    $cellDests = @($cellRowsPs[0].placement.destinations)
    Chk ($cellDests.Count -eq 2) ('配置先は2つ（実際 ' + $cellDests.Count + '）')
    $cellDestA = [string]$cellDests[0].text
    $cellDestB = [string]$cellDests[1].text
    Chk ([string]$cellDests[0].address -eq 'A1' -and [string]$cellDests[1].address -eq 'A2') ('配置先の番地は A1 と A2（実際 ' + [string]$cellDests[0].address + ' / ' + [string]$cellDests[1].address + '）')
    Chk ($cellDestA -ne '' -and $cellDestB -ne '') '配置先の文字が両方とも空でない'
    # ここが要点。**配置先の文字は、行そのものの訳文とは違う**。同じなら
    # 「destination.text を使ったか」と「translation を使ったか」が区別できない。
    Chk ($cellDestA -ne $cellTranslation -and $cellDestB -ne $cellTranslation) ('配置先の文字は行の訳文とは別物（A1: ' + $cellDestA + ' / A2: ' + $cellDestB + '）')
    Chk (($cellDestA + $cellDestB) -eq $cellTranslation) '2つを繋ぐと行の訳文へ戻る（切り分けであって書き換えではない）'
    Chk ([string]$cellRowsPs[0].location -eq ('Sheet1, A1+A2')) ('行そのものは番地を1つに絞れない: ' + [string]$cellRowsPs[0].location)

    $projectPath = Join-Path $tmp 'project.json'
    $candidatePath = Join-Path $tmp 'candidates.json'
    $observedPath = Join-Path $tmp 'observed.json'
    $previewPath = Join-Path $tmp 'preview-project.json'
    $cellPath = Join-Path $tmp 'cell-project.json'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($projectPath, $projectJson, $utf8)
    [IO.File]::WriteAllText($previewPath, $previewProjectJson, $utf8)
    [IO.File]::WriteAllText($cellPath, $cellProjectJson, $utf8)
    [IO.File]::WriteAllText($candidatePath, ($candidates | ConvertTo-Json -Depth 8), $utf8)

    Write-Host '(1) 本物の画面を Chromium で開いて、実際に押す' -ForegroundColor Cyan
    $stderrPath = Join-Path $tmp 'node-stderr.txt'
    $arguments = @($driver, (Join-Path $root 'www'), $projectPath, $candidatePath, $observedPath, $previewPath, $cellPath) | ForEach-Object { '"' + $_ + '"' }
    $proc = Start-Process -FilePath $nodeExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
    $nodeErr = ''
    if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
    Chk ([int]$proc.ExitCode -eq 0) ('運転席が走り切る' + $(if($nodeErr){' / ' + $nodeErr.Substring(0,[Math]::Min(400,$nodeErr.Length))}else{''}))
    $o = $null
    if (Test-Path -LiteralPath $observedPath) { $o = [IO.File]::ReadAllText($observedPath, $utf8) | ConvertFrom-Json }
    Chk ($null -ne $o) '画面で観測した事実を受け取れた'
    if ($null -eq $o) { throw 'CAT_SCREEN_GATE_NO_OBSERVATION' }
    Chk ([string]::IsNullOrEmpty([string]$o.fatal)) ('画面の操作が途中で止まっていない' + $(if($o.fatal){' / ' + ([string]$o.fatal).Substring(0,[Math]::Min(400,([string]$o.fatal).Length))}else{''}))

    # ------------------------------------------------------------------ (g)
    Write-Host '(g) 画面が JavaScript の例外を出していない' -ForegroundColor Cyan
    Chk (@($o.errors).Count -eq 0) ('例外0件（実際: ' + (@($o.errors) -join ' / ') + '）')
    Chk (@($o.console).Count -eq 0) ('コンソールのエラー0件（実際: ' + (@($o.console) -join ' / ') + '）')

    # ------------------------------------------------------------------ (a)
    Write-Host '(a) can_split_at の行にだけ分割ボタンが実際に出る' -ForegroundColor Cyan
    $drawn = @($o.rows)
    Chk ($drawn.Count -eq 2) ('表に2行が描かれる（実際 ' + $drawn.Count + '）')
    Chk ([string]$drawn[0].source -eq $source) '描かれた原文が題材どおり（描画の当て先を取り違えていない）'
    $onSplittable = @($o.splitButtonsOnSplittableRow)
    $onUnsplittable = @($o.splitButtonsOnUnsplittableRow)
    Chk ($onSplittable.Count -eq 1) ('割れる行では分割ボタンが1つ描かれる（実際 ' + $onSplittable.Count + '）')
    Chk ($onSplittable.Count -eq 1 -and [string]$onSplittable[0].index -eq '0') '描かれたボタンは、その行を指している'
    Chk ($onSplittable.Count -eq 1 -and [string]$onSplittable[0].keys -eq 'Alt+S') 'ボタンに Alt+S が書いてある（キー一覧と実物が一致する）'
    Chk ($onUnsplittable.Count -eq 0) ('割れない行では1つも描かれない（実際 ' + $onUnsplittable.Count + '）')
    Chk (@($o.splitButtonsBackOnSplittableRow).Count -eq 1) '行を移って戻ると、また描かれる'

    # ------------------------------------------------------------------ (b)
    Write-Host '(b) Alt+S が分割ボタンを押す' -ForegroundColor Cyan
    Chk ([string]$o.altSOnUnsplittableRow.status -match '原文の途中では分けられません') ('割れない行の Alt+S は断る: ' + [string]$o.altSOnUnsplittableRow.status)
    Chk ([int]$o.altSOnUnsplittableRow.splitCalls -eq 0) '断ったときは口を叩かない'
    Chk ([int]$o.altSSplit.calls -eq 1) ('割れる行の Alt+S で split-at の口へ1回だけ飛ぶ（実際 ' + [int]$o.altSSplit.calls + ' 回）')
    Chk ($null -ne $o.altSSplit.body -and [int]$o.altSSplit.body.index -eq 0) '送った行番号が正しい'

    # ------------------------------------------------------------------ (c)
    Write-Host '(c) 用語の印が入った原文でも、押した位置で割れる' -ForegroundColor Cyan
    Chk ([int]$o.marks.count -eq 1) ('原文に用語の印が1つ入っている（実際 ' + [int]$o.marks.count + '）')
    Chk ([string]$o.marks.plain -eq $source) '印を入れても生原文（data-plain）は元のまま'
    Chk ([string]$o.marks.rendered -eq $source) '印を入れても見える文字は増減しない'
    Chk ([int]$o.marks.childNodes -ge 3) ('印で原文が複数の子ノードに割れている（実際 ' + [int]$o.marks.childNodes + ' 個。これが無いと、この検査は空振りする）')
    Chk ([string]$o.marks.firstChildText -eq $source.Substring(0, $source.IndexOf($term))) '最初の子ノードは印より前の部分だけ'
    $offsets = @($o.probe.offsets)
    Chk ($offsets.Count -eq 2) ('原文の上で2回押せている（実際 ' + $offsets.Count + ' 回）')
    Chk ($offsets.Count -eq 2 -and [int]$offsets[0] -eq [int]$o.firstClickChar) ('1回目に押した位置は ' + [int]$o.firstClickChar + '（印より前）')
    Chk ($offsets.Count -eq 2 -and [int]$offsets[1] -eq $clickChar) ('2回目に押した位置は ' + $clickChar)
    Chk ($clickChar -gt $termEnd) ('2回目は印の終わり（' + $termEnd + '）より後ろである。前だけを見ている実装が通らない題材になっている')
    # ここが本体。ブラウザが決めた位置と、アプリが送った位置が一致すること。
    # かつては1回目の位置が残り、押した場所とは違う位置で黙って割れていた。
    Chk ($null -ne $o.altSSplit.body -and [int]$o.altSSplit.body.position -eq $clickChar) ('アプリが送った位置が、最後に押した位置と一致する（送った値 ' + [string]$o.altSSplit.body.position + '）')
    Chk ($null -ne $o.altSSplit.body -and [int]$o.altSSplit.body.position -ne [int]$o.firstClickChar) '1回目に押した位置が残っていない'
    # 押す前に見せる文面も、その位置で割ったものであること。
    Chk ([string]$o.altSSplit.dialog -match [regex]::Escape($source.Substring(0, $clickChar))) '確認の窓に出る前半が、その位置で割ったもの'
    Chk ([string]$o.altSSplit.dialog -match [regex]::Escape($source.Substring($clickChar))) '確認の窓に出る後半が、その位置で割ったもの'

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) Ctrl+H が検索と置換を開く' -ForegroundColor Cyan
    Chk ([bool]$o.ctrlH.menuOpen) 'Ctrl+H で検索と置換の折りたたみが開く'
    Chk ([string]$o.ctrlH.focused -eq 'cat-search') ('そのまま検索欄へ入る（実際の焦点: ' + [string]$o.ctrlH.focused + '）')

    # ------------------------------------------------------------------ (e)
    Write-Host '(e) 「訳文を置き換える」が置換の口へつながっている' -ForegroundColor Cyan
    Chk (-not [bool]$o.replaceReady.disabled) '対象がある状態でボタンが押せる'
    Chk ([string]$o.replaceReady.label -match '表示中の2行の訳文を置き換える') ('押す前に対象行数を札に出す: ' + [string]$o.replaceReady.label)
    Chk ([int]$o.replaceRun.estimateCalls -eq 1) ('押すと、まず数える口を1回叩く（実際 ' + [int]$o.replaceRun.estimateCalls + ' 回）')
    Chk ([int]$o.replaceRun.replaceCalls -eq 1) ('確認のあと、置換の口を1回叩く（実際 ' + [int]$o.replaceRun.replaceCalls + ' 回）')
    Chk ($null -ne $o.replaceRun.replaceBody -and [string]$o.replaceRun.replaceBody.find -eq 'The Company') '送った検索語が画面のとおり'
    Chk ($null -ne $o.replaceRun.replaceBody -and @($o.replaceRun.replaceBody.indexes).Count -eq 2) '送った対象行が絞り込み結果のとおり'
    Chk ($null -ne $o.replaceRun.replaceBody -and [string]$o.replaceRun.replaceBody.scope -eq 'both') '探す場所をサーバへも渡している'
    Chk ([string]$o.replaceRun.dialog -match '原文は変わりません') '押す前に、原文は変わらないと告げる'

    # ------------------------------------------------------------------ (f)
    Write-Host '(f) 探す場所が原文だけのときは、押しても訳文を書き換えない' -ForegroundColor Cyan
    Chk ([bool]$o.scopeSource.disabled) 'ボタンが押せない状態になる'
    Chk ([string]$o.scopeSource.label -eq '訳文を置き換える') ('札に対象行数を出さない（実際: ' + [string]$o.scopeSource.label + '）')
    Chk ([string]$o.scopeSource.summary -match '原文は書き換えません') ('理由を書く: ' + [string]$o.scopeSource.summary)
    Chk ([int]$o.scopeSourceForcedClick.estimateCalls -eq 0) '無理やり押しても、数える口を叩かない'
    Chk ([int]$o.scopeSourceForcedClick.replaceCalls -eq 0) '無理やり押しても、置換の口を叩かない'
    Chk ([string]$o.scopeSourceForcedClick.status -match '原文は書き換えません') '押した人に理由を返す'

    # ------------------------------------------------------------------ (h)
    Write-Host '(h) 「体裁で見る」が、配置先の無い行でも後半の訳文まで出す' -ForegroundColor Cyan
    $previewGridRows = @($o.previewRows)
    Chk ($previewGridRows.Count -eq 5) ('題材の作業が開けている。表は5行（実際 ' + $previewGridRows.Count + '）')
    Chk ($previewGridRows.Count -eq 5 -and [string]$previewGridRows[0].source -eq $source.Substring(0, $previewSplitAt)) '表の1行目は割った前半（別の作業を見ていない）'
    Chk ($previewGridRows.Count -eq 5 -and [string]$previewGridRows[$tokenIndex].source -eq $tokenText.Substring(0, $tokenSplitAt)) 'トークンの組も表に来ている（この題材が空振りでないこと）'
    Chk ([bool]$o.previewTarget.open) '「体裁で見る」を押すと窓が開く'
    $previewBlocks = @($o.previewTarget.blocks)
    # 割った2行が1つへまとまること。まとまらないと同じ内容が2度出る。
    Chk ($previewBlocks.Count -eq 3) ('割った2組はそれぞれ1つにまとまり、表示は3つ（実際 ' + $previewBlocks.Count + '）')
    Chk ($previewBlocks.Count -ge 1 -and [string]$previewBlocks[0] -eq $previewJoinedText) ('まとめた行に、前半と後半の訳文が両方出る: ' + [string]$previewBlocks[0])
    # ここが欠陥そのもの。前半だけが出ていたら赤にする。
    Chk ($previewBlocks.Count -ge 1 -and [string]$previewBlocks[0] -ne $previewHeadText) '前半の訳文だけになっていない'
    Chk ($previewBlocks.Count -ge 1 -and [string]$previewBlocks[0] -match 'procurement') '後半の訳文が画面に出ている'
    Chk ($previewBlocks.Count -eq 3 -and [string]$previewBlocks[2] -eq $previewOtherText) '割っていない行はそのまま出る'
    Chk ([int]$o.previewTarget.missing -eq 0) ('訳文が無い扱いの行は0（実際 ' + [int]$o.previewTarget.missing + '）')
    # ------ 繋ぎ方の規則そのもの。ここが素朴な `.join(' ')` 写経を実機で落とす。
    # 上の1つ目の組は、どちらの繋ぎ方でも同じ文字列になるので、これが要る。
    Chk ($previewBlocks.Count -ge 2 -and [string]$previewBlocks[1] -eq $tokenJoinedText) ('トークンの内側で割った組は、詰めて繋いだ形で画面に出る: ' + [string]$previewBlocks[1])
    Chk ($previewBlocks.Count -ge 2 -and [string]$previewBlocks[1] -ne $tokenLooseText) '素朴に空白で繋いだ形になっていない'
    Chk ($previewBlocks.Count -ge 2 -and [string]$previewBlocks[1] -ne $tokenHeadText) 'トークンの組も、前半の訳文だけになっていない'
    # 窓の地の文でも見る。塊の切り出し方を変えられても、`AB- 1234` が画面の
    # どこかに出ていれば赤になる。
    Chk ([string]$o.previewTarget.text -match [regex]::Escape('AB-1234')) ('画面の文字に `AB-1234` が出ている')
    Chk ([string]$o.previewTarget.text -notmatch [regex]::Escape('AB- 1234')) ('画面の文字に `AB- 1234` が出ていない')
    # 原文側は前からできていた。直したときに壊していないことを見る。
    $previewSourceBlocks = @($o.previewSource.blocks)
    Chk ($previewSourceBlocks.Count -eq 3) ('原文側も3つ（実際 ' + $previewSourceBlocks.Count + '）')
    Chk ($previewSourceBlocks.Count -ge 1 -and [string]$previewSourceBlocks[0] -eq $source) ('原文側は割る前の原文へ戻って出る: ' + [string]$previewSourceBlocks[0])
    Chk ($previewSourceBlocks.Count -ge 2 -and [string]$previewSourceBlocks[1] -eq $tokenText) ('トークンの組も、原文側は割る前へ戻って出る: ' + [string]$previewSourceBlocks[1])

    # ------------------------------------------------------------------ (i)
    Write-Host '(i) 「体裁で見る」が、配置先のある cell 行では destination.text をそのまま置く' -ForegroundColor Cyan
    Chk (@($o.cellRows).Count -eq 1) ('配置先のある題材の作業が開けている。表は1行（実際 ' + @($o.cellRows).Count + '）')
    Chk (@($o.cellRows).Count -eq 1 -and [string]@($o.cellRows)[0].source -eq ($cellHeadSource + $cellTailSource)) '表の原文は2セルを繋いだもの（別の作業を見ていない）'
    Chk ([bool]$o.cellPreviewTarget.open) '「体裁で見る」を押すと窓が開く'
    Chk (@($o.cellPreviewTarget.sheets).Count -eq 1 -and [string]@($o.cellPreviewTarget.sheets)[0] -eq 'Sheet1') ('シートの格子として描かれる（実際: ' + (@($o.cellPreviewTarget.sheets) -join ' / ') + '）')
    # 番地へ置けなかった行は「そのほかの流し込み」へ落ちる。落ちていたら、
    # destination の番地を使わずに行そのものの場所（A1+A2）を見たということ。
    Chk (@($o.cellPreviewTarget.paragraphs).Count -eq 0) ('番地の無い流し込みへ落ちていない（実際 ' + @($o.cellPreviewTarget.paragraphs).Count + ' 個）')
    $cellCells = @($o.cellPreviewTarget.cellTexts)
    Chk ($cellCells.Count -eq 2) ('セルは2つ描かれる（実際 ' + $cellCells.Count + '）')
    # ここが本体。行そのものの訳文ではなく、配置先ごとの文字が出ていること。
    Chk ($cellCells.Count -eq 2 -and [string]$cellCells[0].text -eq $cellDestA) ('A1 には1つ目の配置先の文字が出る: ' + [string]$cellCells[0].text)
    Chk ($cellCells.Count -eq 2 -and [string]$cellCells[1].text -eq $cellDestB) ('A2 には2つ目の配置先の文字が出る: ' + [string]$cellCells[1].text)
    Chk ($cellCells.Count -eq 2 -and [string]$cellCells[0].text -ne $cellTranslation) 'A1 に行そのものの訳文が丸ごと出ていない'
    Chk ($cellCells.Count -eq 2 -and [string]$cellCells[0].row -eq '1' -and [string]$cellCells[1].row -eq '2') ('セルの行番号は 1 と 2（実際 ' + [string]$cellCells[0].row + ' / ' + [string]$cellCells[1].row + '）')
    # 配置先の文字が空なら、画面は原文へ落ちて薄い字になる。0 件であることが、
    # 「text をそのまま置いた」ことの裏返しになる。
    Chk ([int]$o.cellPreviewTarget.missing -eq 0) ('訳文が無い扱いのセルは0（実際 ' + [int]$o.cellPreviewTarget.missing + '）')
    Chk ((@($cellCells | ForEach-Object { [string]$_.text }) -join '') -eq $cellTranslation) '2つのセルを繋ぐと行の訳文へ戻る（片方だけを描いていない）'
    # 原文側は配置先を使わない。切り替えても格子のまま、原文がそのまま出ること。
    $cellSourceCells = @($o.cellPreviewSource.cellTexts)
    Chk ($cellSourceCells.Count -eq 2) ('原文側もセルは2つ（実際 ' + $cellSourceCells.Count + '）')
    Chk ($cellSourceCells.Count -eq 2 -and [string]$cellSourceCells[0].text -eq ($cellHeadSource + $cellTailSource)) ('原文側は繋いだ原文が出る: ' + [string]$cellSourceCells[0].text)

    if ($script:fail -eq 0) { Write-Host ('V91.76 画面の描画と配線の回帰テストに合格しました。検査 ' + $script:checks + ' 件。') -ForegroundColor Green }
    else { Write-Host ('FAILED: ' + $script:fail + ' / ' + $script:checks) -ForegroundColor Red }
} finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
exit ([int]($script:fail -gt 0))
