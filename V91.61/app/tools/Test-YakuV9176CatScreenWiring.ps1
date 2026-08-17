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

  見るのは15。
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
   (j) 訳を入れただけ・未確定で用語の点検に落ちた行で、書き出しを止めた理由が
       案内する「点検の指摘」が**実際に描かれ、押すと絞り込め、一覧が空でない**
   (k) 止める指摘が1件も無く未確認だけがある作業で、点検の要約が
       「調べたが直すところは無かった」と言い、古い言い方をしないこと
   (l) 点検そのものが走らなかった行（validation-unavailable）が、
       利用者の訳の欠陥（赤）ではなく**道具の不調**として塗られること
   (m) 数字の点検が最後まで走らなかった行（numeric-validation-error）も同じこと。
       止める条件は変えない（その行は塗り分けても止まったまま）
   (n) 用語集に無い短いラベル（label-not-in-glossary）が、**止めない警告**として
       出ること。点検一覧にその行数が件数として出て、群は「ファイルを作れない
       指摘」ではなく、点検欄の色は赤でも道具の不調でもない。同じ画面で
       取り出しボタンが押せたままで、「要対応」には数えず、確認し終えた資料は
       「全部終わりました」と言う
   (o) 原文の数字が、キー操作（Ctrl+D → 番号キー）で**カーソル位置へ**入る。
       一覧は出現順で、表記は原文のまま（桁区切り・小数点を均さない）。
       IME 変換中は効かず、**変換中でなければ効く**（対で採る。キーを丸ごと
       殺すと前者だけが無条件に真になる）。入れる前と入れた後の訳文そのものを
       本物の点検へ掛け、numeric-value-mismatch が立つ／立たないを対で見る。
       数字を1つも含まない題材では後者が無条件に真になるので、原文が
       `1,234` と `5.6` を持ち、訳文はその2つだけが欠けた形にしてある。

  (j) の表明そのものも 2026-08-15 に作り直した。**「一覧が空でないこと」は
  この題材では測れない。** 2行とも訳文ありで未確定なので、cat.js の qaFindings が
  未確認を必ず2件積み、写しの点検（qc_preview）の合流を丸ごと落としても
  一覧は2件残る。無傷の走行が自ら「実際 3 件」と書いていたのがその証拠で、
  内訳は用語1件＋未確認2件だった。いまは群（`自動点検の指摘`）を名指しし、
  その見出しの数字で見る。cat.js の openQaList が items 0件の群を捨てるので、
  合流が消えれば群ごと消えて赤になる。
  併せて「直すところは見つかりませんでした」を見る表明を、一覧の中身から
  **要約**（#cat-qa-summary）へ移した。cat.html:471-472 のとおり要約は
  #cat-qa-list の兄弟なので、一覧の textContent には絶対に入らない。
  要約なら、合流を落とした瞬間に blocking が 0 になって
  「未確認は 2 行です。自動点検では、直すところは見つかりませんでした。」へ落ち、
  同じ画面が用語で止まったままであることと食い違う。**それが矛盾そのものである。**

  なお、一覧の**中身**に落とし文が出るのは3群すべてが空のときだけで、
  写しの点検が1件でもあれば未確認が必ず1行以上ある（点検の写しは未確定の行にしか
  掛からない。src/CatProject.ps1 の Get-YakuCatOutputEligibility は
  State='reviewed' の行を continue で飛ばす）。つまり
  「写しの指摘があり、かつ未確認が0行」は作れない。落とし文を一覧の中身で
  見る表明は、この直しの範囲では原理的に成立しない。

  (k) は 2026-08-15 に見つけた「原理的に落ちない表明」の始末である。
  要約の枝は4本（まだ訳していない／止める指摘がある／未確認だけ／全部終わった）で、
  (j) の題材は blocking>=1 なので必ず2本目へ入る。3本目の文言を禁じていた表明は、
  到達できない枝を見ていたので**取り除いても緑のまま**だった。表明は消さず、
  到達する題材をこちらへ足して生かす。

  (l) も同じ日の欠陥。未確認の行の点検を画面へ渡すようにした結果、
  Get-YakuCatOutputEligibility が合成する validation-unavailable が
  cat.js のラベル引きへ届くようになった。cat.js に説明文が無いと汎用文へ落ち、
  qcGroup が 'error'（赤）で塗る。**道具の不調が、利用者の訳の欠陥の顔で出る。**
  題材は Invoke-YakuCatSegmentValidation を試験の中で一時的に落として作る。
  写しの JSON を手で書かないのは、合成そのものが実装の枝だからである。

  (m) は 2026-08-16 の欠陥。src/CatProject.ps1 は4種を道具の不調と分類して
  いたのに、cat.js の qcGroup はそのうち2種しか道具の色にしておらず、
  numeric-validation-error と structure-validation-error は赤のままだった。
  (l) と同じ形の欠陥が、同じ註の内側に残っていた。
  題材は Test-YakuNumericIntegrity を落として作る。**合成される
  validation-unavailable ではなく、点検の中の枝で積まれる種別**なので、
  (l) の題材ではこの枝へ一度も入らない。
  顔ぶれの一致そのもの（src の Get-YakuCatQcToolTroubleCodes と cat.js の
  QC_TOOL_TROUBLE_CODES）は tools/Test-YakuV9171CatQcLabelCoverage.ps1 が見る。
  ここでは、その分類が**実機の画面の class に本当に出る**ことだけを見る。

  (j) は 2026-08-15 の欠陥（5-3 の宿題の残り半分）。止めた理由の文言19本のうち
  15本が「左の『点検の指摘』を押すと、その行だけ表示できます」と案内するのに、
  その絞り込みは segment.qc_findings の件数で出し入れしており、findings を行へ
  書くのは Set-YakuCatSegmentConfirmed だけだった。書き出し前の点検は写しに
  走らせるので、未確定で止まった行では案内先が1件も無く、ボタンは hidden の
  ままだった。同じ書き出しの窓の「点検一覧を開く」も同じ出どころなので、
  「用語で N 行止まっています」と言った直後に「直すところは見つかりませんでした」
  と出ていた。字面照合では、この矛盾は1件も落ちない（文言も器も実在するため）。
  実際に開いて押すことでしか測れない。

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
function Get-YakuFirstString {
    <# 空集合を [0] で引くと $null になり、その先の .Contains() が
       $ErrorActionPreference='Stop' の下で試験そのものを落とす。落ちると
       残りの節が走らないまま終了コード1だけが返り、赤の内訳が消える。 #>
    param([AllowNull()][object[]]$Items)
    $list = @($Items)
    if ($list.Count -lt 1) { return '' }
    return [string]$list[0]
}
function Test-YakuAnyContains {
    <# 一覧のどこかにその文字が出ているか。表示の文言を機械で数えるときは、
       塊の切り出し方に依存しない形で見る。 #>
    param([AllowNull()][object[]]$Items, [Parameter(Mandatory=$true)][string]$Needle)
    foreach ($item in @($Items)) { if ([string]$item -and ([string]$item).Contains($Needle)) { return $true } }
    return $false
}
function Get-YakuQaGroup {
    <#
      点検一覧の群を、見出しの名前で1つ引く。無ければ $null を返す。

      なぜ群で引くか（2026-08-15）。「一覧が空でないこと」を見る表明は、
      未確認の群だけで満たされる。(j) の題材は2行とも訳文ありで未確定なので、
      cat.js の qaFindings が未確認を必ず2件積み、**写しの点検（qc_preview）を
      1件も描かなくても一覧は空にならない**。合流を落とす改変で落ちる形にするには、
      その群そのものと見出しの数字を見るほかない。cat.js の openQaList は
      items が0件の群を捨てるので、合流が消えれば群ごと消える。
    #>
    param([AllowNull()][object[]]$Groups, [Parameter(Mandatory=$true)][string]$Title)
    foreach ($group in @($Groups)) {
        if ($null -eq $group) { continue }
        if ([string]$group.title -eq $Title) { return $group }
    }
    return $null
}

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

    # 止まった行の案内先を見る題材。**訳文は入っているが未確定**で、1行目だけが
    # 用語の点検に落ちる。確定処理を1度も通していないので、行の qc_findings は
    # 空のままである。それでも書き出しは止まる（サーバが写しに点検を掛けるため）。
    # 2026-08-15 まで、この場面で案内文が指す「点検の指摘」は
    # counts.qc < 1 で隠れており、押す先が存在しなかった。
    Write-Host '(0d) 未確定のまま用語の点検に落ちる行の題材を用意する' -ForegroundColor Cyan
    $qcBadSource = '固定費を圧縮しました。'
    $qcGoodSource = '売上高は100億円でした。'
    $qcProject = New-YakuCatTextProject -Root $root -Text ($qcBadSource + "`n" + $qcGoodSource) -Settings $settings -Direction 'to_en'
    $qcSegs = @($qcProject.Segments)
    Chk ($qcSegs.Count -eq 2) ('題材は2行（実際 ' + $qcSegs.Count + '）')
    $null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$qcProject.Id) -Kind occurrence -Enforcement required `
        -JapanesePreferred '固定費' -EnglishPreferred 'fixed costs' -Origin 'cat-screen-gate' `
        -OriginProjectId ([string]$qcProject.Id) -OriginFileName ([string]$qcProject.FileName) -OriginSegmentId ([string]$qcSegs[0].SegmentId) `
        -OriginLocation ([string]$qcSegs[0].Location) -OriginRevision ([int]$qcProject.Revision)
    $null = Set-YakuCatSegmentTranslation -Project $qcProject -Index 0 -Text 'We cut overhead.'
    $null = Set-YakuCatSegmentTranslation -Project $qcProject -Index 1 -Text 'Revenue was 100 oku yen.'
    $qcEligibility = Get-YakuCatOutputEligibility -Project $qcProject
    Chk (-not [bool]$qcEligibility.TranslationListEligible) '題材は書き出しが止まっている'
    $qcCodes = @(@($qcEligibility.QcFailures) | ForEach-Object { [string]$_.Code })
    Chk ($qcCodes.Count -eq 1 -and $qcCodes[0] -eq 'terminology-missing') ('止まった種別は用語だけ（実際: ' + ($qcCodes -join ',') + '）')
    # ここが要点。**実セグメントには点検結果が1件も無い**。この題材が
    # 「確定して落ちた行」になっていたら、直した欠陥を測れない。
    Chk (@(@($qcProject.Segments) | Where-Object { @($_.QcFindings).Count -gt 0 }).Count -eq 0) '行そのものには点検結果が1件も無い（確定を通していないから）'
    $qcProjectJson = ConvertTo-YakuCatProjectJson -Project $qcProject
    $qcView = $qcProjectJson | ConvertFrom-Json
    $qcViewRows = @($qcView.segments)
    Chk ($qcViewRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $qcViewRows.Count + '）')
    Chk (@($qcViewRows[0].qc_findings).Count -eq 0 -and @($qcViewRows[1].qc_findings).Count -eq 0) 'JSON の qc_findings は両方とも空（旧実装ならここで案内先が消える）'
    Chk (@($qcViewRows[0].qc_preview).Count -eq 1 -and [string]@($qcViewRows[0].qc_preview)[0].code -eq 'terminology-missing') '1行目には写しの点検結果（用語）が載っている'
    Chk (@($qcViewRows[1].qc_preview).Count -eq 0) '通った行には1件も載っていない'
    Chk ([bool]$qcView.export_blocked) '画面へ渡す値でも、書き出しは止まっている'
    # 画面が読む出力前確認は、実装が作ったものをそのまま使う（文言を写経しない）。
    $qcPreflight = Get-YakuCatOutputPreflight -Project $qcProject
    $qcPreflightPayload = [ordered]@{
        project_id = [string]$qcPreflight.ProjectId
        revision = [int]$qcPreflight.Revision
        eligible = [bool]$qcPreflight.Eligible
        mode = [string]$qcPreflight.Mode
        output_name = [string]$qcPreflight.OutputName
        unconfirmed_count = [int]$qcPreflight.UnconfirmedCount
        blockers = @($qcPreflight.Blockers)
        warnings = @($qcPreflight.Warnings)
        draft_notice = [string]$qcPreflight.DraftNotice
    }
    $qcBlockerMessages = @(@($qcPreflight.Blockers) | ForEach-Object { [string]$_.message })
    Chk ($qcBlockerMessages.Count -eq 1) ('止めた理由は1本（実際 ' + $qcBlockerMessages.Count + ' 本）')
    Chk ($qcBlockerMessages.Count -eq 1 -and $qcBlockerMessages[0].Contains('点検の指摘')) ('その文言は「点検の指摘」を案内している: ' + (Get-YakuFirstString -Items $qcBlockerMessages))

    # ------------------------------------------------------------------ (k)
    # 点検の要約は枝が4本ある。上の題材は blocking>=1 なので必ず2本目へ入り、
    # 3本目（止める指摘は無いが未確認はある）の文言は**決して出ない**。
    # 3本目を見る表明を生かすため、そこへ到達する題材をここで作る。
    Write-Host '(0e) 止める指摘が1件も無く、未確認だけが残る題材を用意する' -ForegroundColor Cyan
    $cleanSourceA = '売上高は100億円でした。'
    $cleanSourceB = '営業利益は20億円でした。'
    $qcCleanProject = New-YakuCatTextProject -Root $root -Text ($cleanSourceA + "`n" + $cleanSourceB) -Settings $settings -Direction 'to_en'
    Chk (@($qcCleanProject.Segments).Count -eq 2) ('題材は2行（実際 ' + @($qcCleanProject.Segments).Count + '）')
    $null = Set-YakuCatSegmentTranslation -Project $qcCleanProject -Index 0 -Text 'Net sales were 100 oku yen.'
    $null = Set-YakuCatSegmentTranslation -Project $qcCleanProject -Index 1 -Text 'Operating profit was 20 oku yen.'
    $qcCleanEligibility = Get-YakuCatOutputEligibility -Project $qcCleanProject
    Chk (@($qcCleanEligibility.QcFailures).Count -eq 0) ('この題材では止める指摘が1件も無い（実際 ' + @($qcCleanEligibility.QcFailures).Count + ' 種）')
    Chk ([int]$qcCleanEligibility.UnconfirmedCount -eq 2) ('未確認は2行（実際 ' + [int]$qcCleanEligibility.UnconfirmedCount + '）')
    $qcCleanProjectJson = ConvertTo-YakuCatProjectJson -Project $qcCleanProject
    $qcCleanView = $qcCleanProjectJson | ConvertFrom-Json
    Chk (@(@($qcCleanView.segments) | Where-Object { @($_.qc_preview).Count -gt 0 }).Count -eq 0) '写しの点検結果も1行も付いていない（3本目の枝へ入る条件）'

    # ------------------------------------------------------------------ (l)
    # 点検そのものが最後まで走らなかったときの題材。
    # Get-YakuCatOutputEligibility は try/catch の中で点検を呼び、落ちたら
    # 種別が取れないので validation-unavailable を**合成する**。その枝を
    # 実際に通すために、点検の関数をこの試験の中だけ差し替える。
    # 写しの JSON を手で書くと、合成の枝を通らないまま「出た形」だけを見ることになる。
    Write-Host '(0f) 点検そのものが走らなかった行の題材を用意する' -ForegroundColor Cyan
    $toolSourceA = '調達費は横ばいでした。'
    $toolSourceB = '人件費は増加しました。'
    $qcToolProject = New-YakuCatTextProject -Root $root -Text ($toolSourceA + "`n" + $toolSourceB) -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $qcToolProject -Index 0 -Text 'Procurement costs were flat.'
    $null = Set-YakuCatSegmentTranslation -Project $qcToolProject -Index 1 -Text 'Personnel costs increased.'
    $originalValidation = ${function:Invoke-YakuCatSegmentValidation}
    Chk ($null -ne $originalValidation) '差し替える前の点検の関数を掴めた（掴めなければ戻せない）'
    $qcToolProjectJson = ''
    $qcToolEligibility = $null
    try {
        ${function:Invoke-YakuCatSegmentValidation} = { param($Project, $Segment) throw 'yaku-probe: validation unavailable' }
        $qcToolEligibility = Get-YakuCatOutputEligibility -Project $qcToolProject
        $qcToolProjectJson = ConvertTo-YakuCatProjectJson -Project $qcToolProject
    } finally {
        ${function:Invoke-YakuCatSegmentValidation} = $originalValidation
    }
    # 戻したことを、次の題材へ進む前に確かめる。戻し損ねると以降の判定が全部嘘になる。
    $qcRestoreCheck = Get-YakuCatOutputEligibility -Project $qcCleanProject
    Chk (@($qcRestoreCheck.QcFailures).Count -eq 0) '点検の関数を元に戻せている（差し替えが後の題材へ漏れていない）'
    $qcToolCodes = @(@($qcToolEligibility.QcFailures) | ForEach-Object { [string]$_.Code })
    Chk ($qcToolCodes.Count -eq 1 -and $qcToolCodes[0] -eq 'validation-unavailable') ('サーバが合成した種別は validation-unavailable（実際: ' + ($qcToolCodes -join ',') + '）')
    $qcToolView = $qcToolProjectJson | ConvertFrom-Json
    $qcToolViewRows = @($qcToolView.segments)
    Chk ($qcToolViewRows.Count -eq 2 -and @($qcToolViewRows[0].qc_preview).Count -eq 1 -and [string]@($qcToolViewRows[0].qc_preview)[0].code -eq 'validation-unavailable') '画面へ渡す行にも、合成された種別が載っている'
    Chk (@(@($qcToolProject.Segments) | Where-Object { @($_.QcFindings).Count -gt 0 }).Count -eq 0) '合成した種別を、行そのものへは書いていない（監査を汚さない）'

    # 数字の点検そのものが落ちた行の題材（(m) 用）。
    # Invoke-YakuCatSegmentValidation は Test-YakuNumericIntegrity を try で囲み、
    # 落ちたら numeric-validation-error を積む。合成ではなく**点検の中の枝**なので、
    # 落とす相手は点検そのものではなく、その中で呼ぶ数字の照合にする。
    # ここも写しの JSON を手で書かない。枝を通らないまま「出た形」だけを見ることになる。
    Write-Host '(0g) 数字の点検が最後まで走らなかった行の題材を用意する' -ForegroundColor Cyan
    # 題材が正しい枝を指していることを、src の宣言そのもので確かめる。
    # 名前をここで手書きしても、道具の不調かどうかは src が決める。
    Chk (@(Get-YakuCatQcToolTroubleCodes) -contains 'numeric-validation-error') 'src は numeric-validation-error を道具の不調と分類している（画面の色はこの宣言に従う）'
    Chk (@(Get-YakuCatQcToolTroubleCodes) -contains 'structure-validation-error') 'src は structure-validation-error も道具の不調と分類している'
    $numSourceA = '販売費は横ばいでした。'
    $numSourceB = '研究費も横ばいでした。'
    $qcNumProject = New-YakuCatTextProject -Root $root -Text ($numSourceA + "`n" + $numSourceB) -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $qcNumProject -Index 0 -Text 'Selling expenses were flat.'
    $null = Set-YakuCatSegmentTranslation -Project $qcNumProject -Index 1 -Text 'Research expenses were also flat.'
    $originalNumeric = ${function:Test-YakuNumericIntegrity}
    Chk ($null -ne $originalNumeric) '差し替える前の数字の点検を掴めた（掴めなければ戻せない）'
    $qcNumProjectJson = ''
    $qcNumEligibility = $null
    try {
        ${function:Test-YakuNumericIntegrity} = { param($SourceText, $TranslatedText, $Location) throw 'yaku-probe: numeric integrity unavailable' }
        $qcNumEligibility = Get-YakuCatOutputEligibility -Project $qcNumProject
        $qcNumProjectJson = ConvertTo-YakuCatProjectJson -Project $qcNumProject
    } finally {
        ${function:Test-YakuNumericIntegrity} = $originalNumeric
    }
    # 戻したことを、次へ進む前に確かめる。戻し損ねると以降の判定が全部嘘になる。
    $qcNumRestoreCheck = Get-YakuCatOutputEligibility -Project $qcCleanProject
    Chk (@($qcNumRestoreCheck.QcFailures).Count -eq 0) '数字の点検を元に戻せている（差し替えが後の題材へ漏れていない）'
    $qcNumCodes = @(@($qcNumEligibility.QcFailures) | ForEach-Object { [string]$_.Code })
    # ここが要点。**合成された validation-unavailable ではなく**、点検の中で積まれた
    # numeric-validation-error であること。(l) と同じ枝を見ていたら、この題材は空振りする。
    Chk ($qcNumCodes.Count -eq 1 -and $qcNumCodes[0] -eq 'numeric-validation-error') ('止まった種別は numeric-validation-error だけ（実際: ' + ($qcNumCodes -join ',') + '）')
    Chk (-not [bool]$qcNumEligibility.TranslationListEligible) '題材は書き出しが止まっている'
    $qcNumView = $qcNumProjectJson | ConvertFrom-Json
    $qcNumViewRows = @($qcNumView.segments)
    Chk ($qcNumViewRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $qcNumViewRows.Count + '）')
    Chk (@($qcNumViewRows[0].qc_preview).Count -eq 1 -and [string]@($qcNumViewRows[0].qc_preview)[0].code -eq 'numeric-validation-error') '画面へ渡す1行目に、その種別が載っている（この題材が空振りでないこと）'

    Write-Host '(0h) 用語集に無い短いラベルの題材を用意する（止めない警告）' -ForegroundColor Cyan
    # 題材が正しい群を指していることを、src の宣言そのもので確かめる。
    # 名前をここで手書きしても、止めない警告かどうかは src が決める。
    Chk (@(Get-YakuCatQcWarningCodes) -contains 'label-not-in-glossary') 'src は label-not-in-glossary を止めない警告と分類している（画面の色はこの宣言に従う）'
    Chk (@(Get-YakuCatQcToolTroubleCodes) -notcontains 'label-not-in-glossary') 'それは道具の不調ではない（第3の群である）'
    $labelSourceA = '営業利益'
    $labelSourceB = '研究開発費'
    $qcLabelProject = New-YakuCatTextProject -Root $root -Text ($labelSourceA + "`n" + $labelSourceB) -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $qcLabelProject -Index 0 -Text 'Operating profit'
    $null = Set-YakuCatSegmentTranslation -Project $qcLabelProject -Index 1 -Text 'R&D expenses'
    # 列に収める場所であることが検出の条件。Kind は実装が読む唯一の鍵なので、
    # ここを実際に切り替えて枝へ入れる（Excel が無くても同じ入力になる）。
    foreach ($labelSegment in @($qcLabelProject.Segments)) { $labelSegment.Kind = 'cell' }
    Chk ((@(@($qcLabelProject.Segments) | Where-Object { [string]$_.Kind -eq 'cell' })).Count -eq 2) '2行とも Kind=cell（この枝へ入る題材である）'
    # **2行とも確定済みにする。** 未確定が1行でも残ると「全部終わりました」の帯は
    # 警告と関係なく隠れ、その表明は空回りする。確定できること自体も、
    # 警告が blocker でない証拠である。
    $null = Set-YakuCatSegmentConfirmed -Project $qcLabelProject -Index 0 -Confirmed $true
    $null = Set-YakuCatSegmentConfirmed -Project $qcLabelProject -Index 1 -Confirmed $true
    $qcLabelEligibility = Get-YakuCatOutputEligibility -Project $qcLabelProject
    Chk (@($qcLabelEligibility.Reasons).Count -eq 0) ('この題材では止める理由が1つも無い（実際: ' + (@($qcLabelEligibility.Reasons) -join ',') + '）')
    Chk ([bool]$qcLabelEligibility.TranslationListEligible) '題材は書き出しが止まっていない（警告は止めない）'
    Chk ([int]$qcLabelEligibility.UnconfirmedCount -eq 0) ('未確認は0行（実際 ' + [int]$qcLabelEligibility.UnconfirmedCount + '）')
    $qcLabelProjectJson = ConvertTo-YakuCatProjectJson -Project $qcLabelProject
    $qcLabelView = $qcLabelProjectJson | ConvertFrom-Json
    $qcLabelViewRows = @($qcLabelView.segments)
    $qcLabelRowCodes = @(@($qcLabelViewRows) | ForEach-Object { @($_.qc_findings) } | ForEach-Object { [string]$_.Code })
    Chk ($qcLabelViewRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $qcLabelViewRows.Count + '）')
    Chk (@($qcLabelRowCodes | Where-Object { $_ -eq 'label-not-in-glossary' }).Count -eq 2) `
        ('2行とも警告を持って画面へ渡る（この題材が空振りでないこと。実際: ' + ($qcLabelRowCodes -join ',') + '）')
    Chk (-not [bool]$qcLabelView.export_blocked) '画面の取り出しボタンは押せる状態で渡る'

    # ------------------------------------------------------------------ (o)
    # 原文の数字を訳文へ入れるキー操作の題材。原文は `1,234`（桁区切り）と
    # `5.6`（小数）を持つ。訳文はその2つ**だけ**が欠けた形にして、入れる前と
    # 入れた後の同じ画面の値を、本物の点検（Invoke-YakuCatSegmentValidation）へ
    # 掛ける。数字を1つも含まない題材だと「入れたら立たない」は無条件に真になる。
    Write-Host '(0i) 原文の数字を訳文へ入れる題材を用意する' -ForegroundColor Cyan
    $placeableSource = '売上高は1,234円で、前年から5.6%増えました。'
    $placeableOther = '営業利益も増えました。'
    $placeableFirst = '1,234'
    $placeableSecond = '5.6'
    Chk ($placeableSource.Contains($placeableFirst) -and $placeableSource.Contains($placeableSecond)) '題材の原文が2つの数字を持っている'
    Chk ($placeableSource.IndexOf($placeableFirst) -lt $placeableSource.IndexOf($placeableSecond)) ('原文での出現順は ' + $placeableFirst + ' が先')
    $placeableProject = New-YakuCatTextProject -Root $root -Text ($placeableSource + "`n" + $placeableOther) -Settings $settings -Direction 'to_en'
    Chk (@($placeableProject.Segments).Count -eq 2) ('題材は2行（実際 ' + @($placeableProject.Segments).Count + '）')
    Chk ([string]@($placeableProject.Segments)[0].Text -eq $placeableSource) '1行目の原文は題材どおり'
    # 実装が取り出す一覧そのもの。表記を均していないこと（桁区切り・小数点）を、
    # 原文の文字と突き合わせて見る。
    $placeableList = Get-YakuCatSegmentPlaceables -Project $placeableProject -Index 0
    Chk ([bool]$placeableList.Ok) '原文から数字を取り出せている'
    $placeableTexts = @(@($placeableList.Items) | ForEach-Object { [string]$_.text })
    Chk ($placeableTexts.Count -eq 2) ('取り出した数字は2つ（実際 ' + $placeableTexts.Count + '）')
    Chk ($placeableTexts.Count -eq 2 -and $placeableTexts[0] -eq $placeableFirst) ('1つ目は原文どおりの表記（桁区切りを均していない）: ' + (Get-YakuFirstString -Items $placeableTexts))
    Chk ($placeableTexts.Count -eq 2 -and $placeableTexts[1] -eq $placeableSecond) ('2つ目も原文どおりの表記（小数点を均していない）: ' + $(if ($placeableTexts.Count -eq 2) { $placeableTexts[1] } else { '' }))
    # 数字を持たない行では空であること。「いつでも2件返す」実装では通らない。
    $placeableEmpty = Get-YakuCatSegmentPlaceables -Project $placeableProject -Index 1
    Chk ([bool]$placeableEmpty.Ok -and @($placeableEmpty.Items).Count -eq 0) ('数字の無い行では0件（実際 ' + @($placeableEmpty.Items).Count + '）')
    # 点検側の対。入れなければ立ち、入れれば立たない。**同じ関数・同じ行**で見る。
    $placeableBareTarget = 'Net sales were  yen, up % from a year earlier.'
    $placeableFullTarget = 'Net sales were 1,234 yen, up 5.6% from a year earlier.'
    $placeableSegment = @($placeableProject.Segments)[0]
    $null = Set-YakuCatSegmentTranslation -Project $placeableProject -Index 0 -Text $placeableBareTarget
    $placeableBareCodes = @(@((Invoke-YakuCatSegmentValidation -Project $placeableProject -Segment $placeableSegment).Findings) | ForEach-Object { [string]$_.Code })
    Chk ($placeableBareCodes -contains 'numeric-value-mismatch') ('数字を入れないと numeric-value-mismatch が立つ（実際: ' + ($placeableBareCodes -join ',') + '）')
    $null = Set-YakuCatSegmentTranslation -Project $placeableProject -Index 0 -Text $placeableFullTarget
    $placeableFullCodes = @(@((Invoke-YakuCatSegmentValidation -Project $placeableProject -Segment $placeableSegment).Findings) | ForEach-Object { [string]$_.Code })
    Chk ($placeableFullCodes -notcontains 'numeric-value-mismatch') ('入れると立たない（実際: ' + ($placeableFullCodes -join ',') + '）')
    # 画面へは訳文を空で渡す。運転席が自分で打ち込むところから始める。
    $null = Set-YakuCatSegmentTranslation -Project $placeableProject -Index 0 -Text ''
    $null = Set-YakuCatSegmentTranslation -Project $placeableProject -Index 1 -Text ''
    $placeableProjectJson = ConvertTo-YakuCatProjectJson -Project $placeableProject
    # 口の応答は実装が作る（ConvertTo-YakuCatSegmentPlaceablesJson）。Server.ps1 の
    # 口も同じ関数を呼ぶので、応答の形は1か所にしかない。
    $placeableResponseJson = ConvertTo-YakuCatSegmentPlaceablesJson -Project $placeableProject -Index 0

    $projectPath = Join-Path $tmp 'project.json'
    $candidatePath = Join-Path $tmp 'candidates.json'
    $observedPath = Join-Path $tmp 'observed.json'
    $previewPath = Join-Path $tmp 'preview-project.json'
    $cellPath = Join-Path $tmp 'cell-project.json'
    $qcPath = Join-Path $tmp 'qc-project.json'
    $qcPreflightPath = Join-Path $tmp 'qc-preflight.json'
    $qcCleanPath = Join-Path $tmp 'qc-clean-project.json'
    $qcToolPath = Join-Path $tmp 'qc-tool-project.json'
    $qcNumPath = Join-Path $tmp 'qc-numeric-project.json'
    $qcLabelPath = Join-Path $tmp 'qc-label-project.json'
    $placeablePath = Join-Path $tmp 'placeable-project.json'
    $placeableResponsePath = Join-Path $tmp 'placeable-response.json'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($placeablePath, $placeableProjectJson, $utf8)
    [IO.File]::WriteAllText($placeableResponsePath, $placeableResponseJson, $utf8)
    [IO.File]::WriteAllText($qcCleanPath, $qcCleanProjectJson, $utf8)
    [IO.File]::WriteAllText($qcToolPath, $qcToolProjectJson, $utf8)
    [IO.File]::WriteAllText($qcNumPath, $qcNumProjectJson, $utf8)
    [IO.File]::WriteAllText($qcLabelPath, $qcLabelProjectJson, $utf8)
    [IO.File]::WriteAllText($qcPath, $qcProjectJson, $utf8)
    [IO.File]::WriteAllText($qcPreflightPath, ($qcPreflightPayload | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText($projectPath, $projectJson, $utf8)
    [IO.File]::WriteAllText($previewPath, $previewProjectJson, $utf8)
    [IO.File]::WriteAllText($cellPath, $cellProjectJson, $utf8)
    [IO.File]::WriteAllText($candidatePath, ($candidates | ConvertTo-Json -Depth 8), $utf8)

    Write-Host '(1) 本物の画面を Chromium で開いて、実際に押す' -ForegroundColor Cyan
    $stderrPath = Join-Path $tmp 'node-stderr.txt'
    # 既定は利用者の機械の実測（inner 1912x987）。1380 は「狭い版を踏ませたくて
    # 選んだ値」であって実機ではない（2026-08-16 に CLAUDE.md を訂正した）。
    $primaryViewport = '1912x987'
    $arguments = @($driver, (Join-Path $root 'www'), $projectPath, $candidatePath, $observedPath, $previewPath, $cellPath, $qcPath, $qcPreflightPath, $qcCleanPath, $qcToolPath, $qcNumPath, $qcLabelPath, $placeablePath, $placeableResponsePath, $primaryViewport) | ForEach-Object { '"' + $_ + '"' }
    $proc = Start-Process -FilePath $nodeExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
    $nodeErr = ''
    if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
    Chk ([int]$proc.ExitCode -eq 0) ('運転席が走り切る' + $(if($nodeErr){' / ' + $nodeErr.Substring(0,[Math]::Min(400,$nodeErr.Length))}else{''}))
    $o = $null
    if (Test-Path -LiteralPath $observedPath) { $o = [IO.File]::ReadAllText($observedPath, $utf8) | ConvertFrom-Json }
    Chk ($null -ne $o) '画面で観測した事実を受け取れた'
    if ($null -eq $o) { throw 'CAT_SCREEN_GATE_NO_OBSERVATION' }
    Chk ([string]::IsNullOrEmpty([string]$o.fatal)) ('画面の操作が途中で止まっていない' + $(if($o.fatal){' / ' + ([string]$o.fatal).Substring(0,[Math]::Min(400,([string]$o.fatal).Length))}else{''}))

    # ---------------------------------------------------------------- (開始画面)
    Write-Host '(開始画面) 統合した入口の状態と操作を実ブラウザーで守る' -ForegroundColor Cyan
    Chk ([string]$o.startScreen.buttonText -eq '英語に訳す') '空の主ボタンも行為の名前を名乗る'
    Chk ([bool]$o.startScreen.disabled) '準備完了後も文章が空なら主ボタンは押せない'
    Chk ([string]$o.startScreen.reason -eq '文章を入力してください') '押せない理由をボタンの外に出す'
    Chk ([bool]$o.startScreen.guideVisible) '空の入力欄には貼り付け案内が見える'
    Chk ([bool]$o.startScreen.unified) 'ファイルの入口は文章と同じ外枠の中にある'
    Chk ([int]$o.startScreen.fileClicksFromTextareaEnter -eq 0) '文章欄のEnterでファイル選択を開かない'
    Chk ([int]$o.startScreen.changesFromNestedDrop -eq 1) '子要素へ落としてもファイル変更は1回だけ起きる'

    # ---------------------------------------------------------------- (幅)
    # **畳んだ帯が、窓の中に収まって開くか。ここだけ2つの幅で測る。**
    #
    # 2026-08-15 に「検索と置換」へ上へ開く指定を固定で付けた。根拠は「実機の窓
    # 1380x860 では帯が y=574 にあり、下へ開くと画面の外」だったが、**その 1380 が
    # 実機ではなかった**（CLAUDE.md を 2026-08-16 に訂正）。利用者の機械
    # （inner 1912x987）では操作ブロックが折り返さないので帯は y=309 にあり、
    # 高さ 427 のパネルを上へ開くと top=-127。中のボタンは y=-37〜-5 で
    # 完全に画面の外にあり、押せなかった（2026-08-17 に実測）。
    #
    # **利用者が見ない幅のために入れた対策が、利用者が見る幅で同じ不具合を作っていた。**
    # だから両方で測る。狭い版を守る意味はあるので消さないが、それを「実機」と呼ばない。
    Write-Host '(幅) 畳んだ帯が、狭い窓でも実機の窓でも中に収まって開く' -ForegroundColor Cyan
    $narrowObservedPath = Join-Path $tmp 'observed-narrow.json'
    $narrowStderrPath = Join-Path $tmp 'node-stderr-narrow.txt'
    $narrowArgs = @($driver, (Join-Path $root 'www'), $projectPath, $candidatePath, $narrowObservedPath, $previewPath, $cellPath, $qcPath, $qcPreflightPath, $qcCleanPath, $qcToolPath, $qcNumPath, $qcLabelPath, $placeablePath, $placeableResponsePath, '1380x900') | ForEach-Object { '"' + $_ + '"' }
    $narrowProc = Start-Process -FilePath $nodeExe -ArgumentList $narrowArgs -NoNewWindow -Wait -PassThru -RedirectStandardError $narrowStderrPath
    Chk ([int]$narrowProc.ExitCode -eq 0) '狭い窓でも運転席が走り切る'
    $narrow = $null
    if (Test-Path -LiteralPath $narrowObservedPath) { $narrow = [IO.File]::ReadAllText($narrowObservedPath, $utf8) | ConvertFrom-Json }
    Chk ($null -ne $narrow) '狭い窓の観測も受け取れた'

    foreach ($pair in @(
        @{ Label = '実機 1912x987'; Data = $o },
        @{ Label = '狭い版 1380x900'; Data = $narrow }
    )) {
        $data = $pair.Data
        if ($null -eq $data) { continue }
        $menus = @($data.menus)
        Chk ($menus.Count -ge 1) ($pair.Label + ': 畳んだ帯を1つ以上見つけた')
        # この題材で中身を持つ帯だけを見る。場所の一覧と変更の絞り込みは、
        # 貼り付け本文の作業では空になる（そこへ「押せるものがある」を要求すると、
        # 題材の性質を欠陥として数えることになる）。
        $withContent = @($menus | Where-Object { [int]$_.buttons -ge 1 })
        Chk ($withContent.Count -ge 1) ($pair.Label + ': 中身を持つ帯が1つ以上ある（この表明が空振りでないこと）')
        foreach ($menu in $withContent) {
            $name = if ([string]$menu.id) { [string]$menu.id } else { '(名前なし)' }
            Chk ([bool]$menu.fits) ($pair.Label + ': ' + $name + ' のパネルが窓の中に収まる（top=' + [int]$menu.panelTop + ' bottom=' + [int]$menu.panelBottom + '）')
            Chk ([int]$menu.offscreenButtons -eq 0) ($pair.Label + ': ' + $name + ' のボタンが1つも画面の外に出ない（外 ' + [int]$menu.offscreenButtons + ' 個）')
        }
    }
    # **どちらの窓でも下へ開く。** これは「上へ開く指定が復活していない」ことの表明である。
    #
    # 測ってみると、この帯の起点は両方の窓で y≈309 にあり、パネルの高さ 427 より
    # 小さい。つまり**上には物理的に入らない**ので、上へ開けば必ず窓の外へ出る。
    # 2026-08-15 に固定で付けた is-drop-up は、この帯についてはどの窓でも誤りだった。
    #
    # 向きを決める仕組みそのもの（下に入らず上に入るときだけ上へ開く）は、
    # **この題材では発火しない。** 起点がもっと下にある帯が要る。そういう帯は
    # いま画面に無いので、ここでは測れないと正直に書いておく。
    $narrowSearch = @(@($narrow.menus) | Where-Object { [string]$_.id -eq 'cat-search-menu' })
    $wideSearch = @(@($o.menus) | Where-Object { [string]$_.id -eq 'cat-search-menu' })
    Chk ($narrowSearch.Count -eq 1 -and $wideSearch.Count -eq 1) '検索と置換の帯を両方の窓で観測できた'
    if ($narrowSearch.Count -eq 1 -and $wideSearch.Count -eq 1) {
        Chk (-not [bool]$wideSearch[0].dropUp) '実機の窓では下へ開く（上には入らないため）'
        Chk (-not [bool]$narrowSearch[0].dropUp) '狭い窓でも下へ開く（同じ理由）'
        Chk ([int]$wideSearch[0].panelTop -gt 0 -and [int]$narrowSearch[0].panelTop -gt 0) ('どちらの窓でもパネルの上端が窓の中にある（実機 ' + [int]$wideSearch[0].panelTop + ' / 狭い版 ' + [int]$narrowSearch[0].panelTop + '）')
    }

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

    # ------------------------------------------------------------------ (j)
    Write-Host '(j) 未確定のまま止まった行で、案内文が指す「点検の指摘」が実際に開く' -ForegroundColor Cyan
    $qcScreen = $o.qcScreen
    Chk (@($qcScreen.rows).Count -eq 2) ('題材の作業が開けている。表は2行（実際 ' + @($qcScreen.rows).Count + '）')
    Chk (@($qcScreen.rows).Count -eq 2 -and [string]@($qcScreen.rows)[0].source -eq $qcBadSource) '表の1行目は用語で落ちる行（別の作業を見ていない）'
    # ここが宿題そのもの。旧実装ではこのボタンが hidden のままだった。
    Chk (-not [bool]$qcScreen.filterHidden) '「点検の指摘」の絞り込みが隠れていない'
    Chk ([bool]$qcScreen.filterVisible) '「点検の指摘」の絞り込みが画面上で面積を持っている（CSSで消しても緑にならない）'
    Chk ([string]$qcScreen.filterCount -eq '1') ('件数は 1（実際 ' + [string]$qcScreen.filterCount + '）')
    Chk ([string]$qcScreen.qaButtonLabel -match '点検\s*1') ('道具の帯の「点検」も件数を出す（実際: ' + [string]$qcScreen.qaButtonLabel + '）')
    Chk ([bool]$qcScreen.qaButtonHasBlockers) '「点検」が、止めている指摘があると分かる見た目になる'
    # 止める条件は変えていない。押せないままであること。
    Chk ([bool]$qcScreen.exportDisabled) '取り出しボタンは従来どおり押せない（止める条件を緩めていない）'
    Chk ([string]$qcScreen.exportTitle -ne '') ('押せない理由がボタンに書いてある: ' + [string]$qcScreen.exportTitle)
    Chk ([string]$qcScreen.outputReason -ne '') '読み上げ用の理由も空でない'
    # 押すと本当に絞り込めるか。出るだけの飾りになっていないこと。
    $qcFiltered = $o.qcFiltered
    Chk ([string]$qcFiltered.pressed -eq 'true') '押すと、その絞り込みが選ばれた状態になる'
    Chk (@($qcFiltered.rows).Count -eq 1) ('絞り込むと1行だけになる（実際 ' + @($qcFiltered.rows).Count + ' 行）')
    Chk (@($qcFiltered.rows).Count -eq 1 -and [string]@($qcFiltered.rows)[0].source -eq $qcBadSource) '残るのは用語で落ちた行'
    Chk ([bool]$qcFiltered.emptyHidden) '「該当なし」の表示は出ない（案内先が空振りでない）'
    # 開いた行の点検欄。種別を名指しし、かつ免除ボタンは出さない。
    $qcInspector = $o.qcInspector
    Chk ([string]$qcInspector.count -eq '1') ('点検欄の件数は 1（実際 ' + [string]$qcInspector.count + '）')
    $qcCards = @($qcInspector.cards)
    Chk ($qcCards.Count -eq 1) ('点検欄に指摘が1件出る（実際 ' + $qcCards.Count + ' 件）')
    Chk (Test-YakuAnyContains -Items @($qcCards | ForEach-Object { [string]$_.text }) -Needle '登録した訳語が使われていません') ('用語であることを名指しする: ' + (Get-YakuFirstString -Items @($qcCards | ForEach-Object { [string]$_.text })))
    Chk (-not (Test-YakuAnyContains -Items @($qcCards | ForEach-Object { [string]$_.text }) -Needle '見つかりませんでした')) '「気になる点は見つかりませんでした」にはならない'
    Chk ($qcCards.Count -eq 1 -and [bool]$qcCards[0].preview) '写しの点検から来た指摘であると印が付いている'
    # 用語の免除（訳文を書き換える操作）は、確定を1度も通していない行には出さない。
    Chk ((@($qcCards | ForEach-Object { [int]$_.exceptionButtons }) | Measure-Object -Sum).Sum -eq 0) '「この行では別の表現を使う」は出さない（見ることと決めることを混ぜない）'
    Chk ([string]$qcInspector.inputInvalid -eq 'true') '訳文欄が aria-invalid になる（読み上げにも伝わる）'
    Chk ([string]$qcInspector.rowFindingText -ne '') '行の中にも指摘の文が出る'
    # 道具の帯の「点検」から開く一覧（F8 と同じ入口）。ここが実際の案内先である。
    $qaList = $o.qaList
    Chk ([bool]$qaList.open) '「点検」を押すと一覧が開く'
    # **「一覧が空でない」では測れない。** この題材は2行とも訳文ありで未確定なので、
    # cat.js の qaFindings が未確認を必ず2件積む。写しの点検（qc_preview）の合流を
    # 丸ごと落としても一覧は2件残り、「空でない」も `-ge 1` も成立し続ける
    # （2026-08-15 に、無傷の走行が「実際 3 件」と自ら書いていた）。
    # 群を名指しし、その群の見出しの数字で見る。合流を落とすと、cat.js の
    # openQaList が items 0件の群を捨てるので、この群ごと消えて赤になる。
    $qaQcGroup = Get-YakuQaGroup -Groups @($qaList.groupDetails) -Title '自動点検の指摘'
    Chk ($null -ne $qaQcGroup) ('「自動点検の指摘」の群が描かれる（実際の見出し: ' + (@($qaList.groups) -join ' / ') + '）')
    Chk ($null -ne $qaQcGroup -and [int]$qaQcGroup.count -eq 1) ('その群の見出しの件数は 1（実際 ' + $(if ($null -ne $qaQcGroup) { [string]$qaQcGroup.count } else { 'その群が無い' }) + '）')
    Chk ($null -ne $qaQcGroup -and @($qaQcGroup.items).Count -eq 1) ('その群の行も1つ（見出しの数字と実物が一致する。実際 ' + $(if ($null -ne $qaQcGroup) { [string]@($qaQcGroup.items).Count } else { '0' }) + '）')
    Chk ($null -ne $qaQcGroup -and [bool]$qaQcGroup.blocking) 'その群は「止める」側として描かれる'
    Chk ($null -ne $qaQcGroup -and (Test-YakuAnyContains -Items @($qaQcGroup.items) -Needle '登録した訳語が使われていません')) ('その群の行が種別を名指しする: ' + (Get-YakuFirstString -Items @($(if ($null -ne $qaQcGroup) { @($qaQcGroup.items) } else { @() }))))
    Chk ($null -ne $qaQcGroup -and (Test-YakuAnyContains -Items @($qaQcGroup.items) -Needle '1行目')) '何行目かを言う（行へ飛べる）'
    # 対で見る。上の件数が「未確認の群」で満たされたのではないことを、こちらで示す。
    $qaUnconfirmedGroup = Get-YakuQaGroup -Groups @($qaList.groupDetails) -Title '未確認'
    Chk ($null -ne $qaUnconfirmedGroup -and [int]$qaUnconfirmedGroup.count -eq 2) ('未確認の群は別に2件ある（実際 ' + $(if ($null -ne $qaUnconfirmedGroup) { [string]$qaUnconfirmedGroup.count } else { 'その群が無い' }) + '）')
    Chk (-not (Test-YakuAnyContains -Items @($qaList.groups) -Needle '数字の点検')) ('群の見出しが「数字の点検」になっていない（実際: ' + (@($qaList.groups) -join ' / ') + '）')
    Chk (Test-YakuAnyContains -Items @($qaList.groups) -Needle '自動点検の指摘') '群の見出しが、数字以外も入る名前になっている'
    # 「直すところは見つかりませんでした」は**要約**（#cat-qa-summary）の枝であって、
    # 一覧の中身（#cat-qa-list）ではない。cat.html:471-472 のとおり兄弟なので、
    # 一覧の textContent を見ていた旧表明は原理的に落ちなかった。要約を見る。
    # 合流を落とすと blocking が 0 になり、要約は「未確認は 2 行です。自動点検では、
    # 直すところは見つかりませんでした。」へ落ちる。**それが 2026-08-15 の矛盾そのもの**で、
    # 同じ画面の取り出しボタンは用語で止まったままである。
    Chk (-not ([string]$qaList.summary).Contains('直すところは見つかりませんでした')) ('要約が「直すところは見つかりませんでした」と言わない（窓は用語で止まったと言っている）: ' + [string]$qaList.summary)
    Chk (([string]$qaList.summary).Contains('ファイルを作れない指摘が 1 件あります')) ('要約が、止めた指摘の件数を出す: ' + [string]$qaList.summary)
    # 書き出しの窓の中でも、言っていることと開く先が食い違わない。
    $qcExport = $o.qcExportDialog
    Chk ([bool]$qcExport.open) '出力前の確認の窓が開く'
    Chk ([bool]$qcExport.confirmDisabled) 'その窓の「これで取り出す」は押せないまま（止める条件を緩めていない）'
    Chk (Test-YakuAnyContains -Items @($qcExport.checks) -Needle '登録した訳語が使われていない') ('窓は用語で止まったと言う: ' + (Get-YakuFirstString -Items @($qcExport.checks)))
    Chk (-not [bool]$qcExport.qaHidden) 'その窓に「点検一覧を開く」が出る'
    $qaFromExport = $o.qaFromExport
    Chk ([bool]$qaFromExport.open) 'その場のボタンで一覧が開く'
    # ここも「空でない」では測れない（同じ題材・同じ理由）。群で見る。
    $qaExportQcGroup = Get-YakuQaGroup -Groups @($qaFromExport.groupDetails) -Title '自動点検の指摘'
    Chk ($null -ne $qaExportQcGroup) ('その一覧にも「自動点検の指摘」の群が描かれる（実際の見出し: ' + (@($qaFromExport.groups) -join ' / ') + '）')
    Chk ($null -ne $qaExportQcGroup -and [int]$qaExportQcGroup.count -eq 1) ('その群の件数は 1（実際 ' + $(if ($null -ne $qaExportQcGroup) { [string]$qaExportQcGroup.count } else { 'その群が無い' }) + '）')
    Chk ($null -ne $qaExportQcGroup -and (Test-YakuAnyContains -Items @($qaExportQcGroup.items) -Needle '登録した訳語が使われていません')) '一覧の行も、窓と同じ種別を名指しする'
    # 矛盾そのもの。窓は「登録した訳語が使われていない」で止めたと言っている。
    # 同じ操作で開いた一覧の要約が「直すところは見つかりませんでした」と言ったら赤。
    Chk (-not ([string]$qaFromExport.summary).Contains('直すところは見つかりませんでした')) ('同じ窓の中で「用語で止まっています」と「直すところは見つかりませんでした」が同時に出ない: ' + [string]$qaFromExport.summary)
    Chk (([string]$qaFromExport.summary).Contains('ファイルを作れない指摘が 1 件あります')) ('その要約も、止めた指摘の件数を出す: ' + [string]$qaFromExport.summary)

    # ------------------------------------------------------------------ (k)
    Write-Host '(k) 止める指摘が無く未確認だけの作業で、点検の要約が実装どおりに言う' -ForegroundColor Cyan
    $qcClean = $o.qcCleanScreen
    Chk (@($qcClean.rows).Count -eq 2) ('題材の作業が開けている。表は2行（実際 ' + @($qcClean.rows).Count + '）')
    Chk (@($qcClean.rows).Count -eq 2 -and [string]@($qcClean.rows)[0].source -eq $cleanSourceA) '別の作業を見ていない'
    # (j) で「出る」ことを見た絞り込みが、指摘が無いときは隠れていること。
    # 常時出す実装にしても (j) は緑になるので、こちらが対になる。
    Chk ([bool]$qcClean.filterHidden) '指摘が1件も無いときは「点検の指摘」の絞り込みは隠れている'
    Chk ([string]$qcClean.qaButtonLabel -eq '点検') ('道具の帯の「点検」は件数を出さない（実際: ' + [string]$qcClean.qaButtonLabel + '）')
    Chk (-not [bool]$qcClean.qaButtonHasBlockers) '止めている指摘がある見た目にはならない'
    Chk (-not [bool]$qcClean.exportDisabled) '未確認だけでは取り出しを止めない（未確認は止める条件ではない）'
    $qaClean = $o.qaCleanList
    Chk ([bool]$qaClean.open) '「点検」を押すと一覧が開く'
    # ここが要点。上の題材では決して通らない枝を、実機で通している。
    Chk (-not ([string]$qaClean.summary).Contains('ファイルを作れない指摘')) ('止める指摘がある枝には入っていない: ' + [string]$qaClean.summary)
    Chk (([string]$qaClean.summary).Contains('未確認は 2 行です。')) ('要約が未確認の行数を出す: ' + [string]$qaClean.summary)
    Chk (([string]$qaClean.summary).Contains('自動点検では、直すところは見つかりませんでした。')) ('要約が「調べて通った」と言う: ' + [string]$qaClean.summary)
    Chk (-not ([string]$qaClean.summary).Contains('数字の点検は、確認済みにするときに行います')) '「点検は確認済みにするときに行います」と言わない（未確認の行でも点検は走っている）'
    Chk (-not (Test-YakuAnyContains -Items @($qaClean.groups) -Needle '自動点検の指摘')) ('止める群は出ない（実際: ' + (@($qaClean.groups) -join ' / ') + '）')
    Chk (Test-YakuAnyContains -Items @($qaClean.groups) -Needle '未確認') '未確認の群は出る'

    # ------------------------------------------------------------------ (l)
    Write-Host '(l) 点検そのものが走らなかった行は、道具の不調として出る' -ForegroundColor Cyan
    $qcTool = $o.qcToolInspector
    $qcToolCards = @($qcTool.cards)
    Chk ($qcToolCards.Count -eq 1) ('点検欄に指摘が1件出る（実際 ' + $qcToolCards.Count + ' 件）')
    Chk (Test-YakuAnyContains -Items @($qcToolCards | ForEach-Object { [string]$_.text }) -Needle '自動点検が最後まで終わりませんでした') ('何が起きたかを名指しする: ' + (Get-YakuFirstString -Items @($qcToolCards | ForEach-Object { [string]$_.text })))
    Chk (-not (Test-YakuAnyContains -Items @($qcToolCards | ForEach-Object { [string]$_.text }) -Needle '自動点検で気になる点が見つかりました')) '汎用文へ落ちていない（種別に説明文がある）'
    Chk (-not (Test-YakuAnyContains -Items @($qcToolCards | ForEach-Object { [string]$_.text }) -Needle '原文と見比べて')) '「原文と見比べて直せ」と言わない（訳を直しても消えない）'
    # ここが直した表示の欠陥そのもの。色は class にしか出ない。
    Chk (Test-YakuAnyContains -Items @($qcToolCards | ForEach-Object { [string]$_.classes }) -Needle 'is-tool') ('道具の不調として塗られる（実際の class: ' + (Get-YakuFirstString -Items @($qcToolCards | ForEach-Object { [string]$_.classes })) + '）')
    Chk (-not (Test-YakuAnyContains -Items @($qcToolCards | ForEach-Object { [string]$_.classes }) -Needle 'is-error')) '利用者の訳の欠陥（赤）としては塗らない'
    Chk ((@($qcToolCards | ForEach-Object { [int]$_.exceptionButtons }) | Measure-Object -Sum).Sum -eq 0) '用語の免除ボタンは出さない'
    $qaTool = $o.qaToolList
    Chk ([bool]$qaTool.open) 'その作業でも点検の一覧は開く'
    Chk (Test-YakuAnyContains -Items @($qaTool.items) -Needle '自動点検が最後まで終わりませんでした') ('一覧の行も同じことを言う: ' + (Get-YakuFirstString -Items @($qaTool.items)))

    # ------------------------------------------------------------------ (m)
    Write-Host '(m) 数字の点検が走らなかった行も、道具の不調として出る' -ForegroundColor Cyan
    $qcNum = $o.qcNumInspector
    $qcNumCards = @($qcNum.cards)
    # 観測点そのものが空でないことを先に見る。空のまま下の -not を並べると、
    # 「1件も出ていない」が緑になる（測れなかったものを緑へ畳まない）。
    Chk ($qcNumCards.Count -eq 1) ('点検欄に指摘が1件出る（実際 ' + $qcNumCards.Count + ' 件）')
    Chk (Test-YakuAnyContains -Items @($qcNumCards | ForEach-Object { [string]$_.text }) -Needle '数字の点検が最後まで終わりませんでした') ('何が起きたかを名指しする: ' + (Get-YakuFirstString -Items @($qcNumCards | ForEach-Object { [string]$_.text })))
    Chk (-not (Test-YakuAnyContains -Items @($qcNumCards | ForEach-Object { [string]$_.text }) -Needle '自動点検で気になる点が見つかりました')) '汎用文へ落ちていない（種別に説明文がある）'
    Chk (-not (Test-YakuAnyContains -Items @($qcNumCards | ForEach-Object { [string]$_.text }) -Needle '原文と見比べて')) '「原文と見比べて直せ」と言わない（訳を直しても消えない）'
    # ここが直した欠陥そのもの。色は class にしか出ない。
    Chk (Test-YakuAnyContains -Items @($qcNumCards | ForEach-Object { [string]$_.classes }) -Needle 'is-tool') ('道具の不調として塗られる（実際の class: ' + (Get-YakuFirstString -Items @($qcNumCards | ForEach-Object { [string]$_.classes })) + '）')
    Chk (-not (Test-YakuAnyContains -Items @($qcNumCards | ForEach-Object { [string]$_.classes }) -Needle 'is-error')) '利用者の訳の欠陥（赤）としては塗らない'
    # 色は表示だけの話である。止める条件は1つも減らしていない。
    Chk ([bool]$o.qcNumScreen.exportDisabled) '取り出しボタンは従来どおり押せない（赤をやめても、その行は止まったまま）'
    Chk ([string]$o.qcNumScreen.exportTitle -ne '') ('押せない理由がボタンに書いてある: ' + [string]$o.qcNumScreen.exportTitle)

    # ------------------------------------------------------------------ (n)
    Write-Host '(n) 用語集に無い短いラベルは、止めない警告として件数まで出る' -ForegroundColor Cyan
    $qcLabel = $o.qcLabelScreen
    Chk (@($qcLabel.rows).Count -eq 2) ('題材の作業が開けている。表は2行（実際 ' + @($qcLabel.rows).Count + '）')
    Chk (@($qcLabel.rows).Count -eq 2 -and [string]@($qcLabel.rows)[0].source -eq $labelSourceA) '別の作業を見ていない'
    $qcLabelCards = @($o.qcLabelInspector.cards)
    # 観測点そのものが空でないことを先に見る。空のまま下の -not を並べると
    # 「1件も出ていない」が緑になる。
    Chk ($qcLabelCards.Count -eq 1) ('点検欄に指摘が1件出る（実際 ' + $qcLabelCards.Count + ' 件）')
    Chk (Test-YakuAnyContains -Items @($qcLabelCards | ForEach-Object { [string]$_.text }) -Needle '用語集に無い短いラベルです') ('何が起きたかを名指しする: ' + (Get-YakuFirstString -Items @($qcLabelCards | ForEach-Object { [string]$_.text })))
    Chk (-not (Test-YakuAnyContains -Items @($qcLabelCards | ForEach-Object { [string]$_.text }) -Needle '自動点検で気になる点が見つかりました')) '汎用文へ落ちていない（種別に説明文がある）'
    # 色は class にしか出ない。赤（訳の欠陥）でも道具の不調でもない第3の群である。
    Chk (Test-YakuAnyContains -Items @($qcLabelCards | ForEach-Object { [string]$_.classes }) -Needle 'is-warn') ('止めない警告として塗られる（実際の class: ' + (Get-YakuFirstString -Items @($qcLabelCards | ForEach-Object { [string]$_.classes })) + '）')
    Chk (-not (Test-YakuAnyContains -Items @($qcLabelCards | ForEach-Object { [string]$_.classes }) -Needle 'is-error')) '利用者の訳の欠陥（赤）としては塗らない'
    Chk (-not (Test-YakuAnyContains -Items @($qcLabelCards | ForEach-Object { [string]$_.classes }) -Needle 'is-tool')) '道具の不調としても塗らない（直せる警告である）'
    # 受容条件の本体。**その行数が点検一覧に件数として出る。**
    $qaLabel = $o.qaLabelList
    Chk ([bool]$qaLabel.open) 'その作業でも点検の一覧は開く'
    $qaLabelGroup = Get-YakuQaGroup -Groups @($qaLabel.groupDetails) -Title '用語集に無い短いラベル'
    Chk ($null -ne $qaLabelGroup) ('一覧に「用語集に無い短いラベル」の群が描かれる（実際の見出し: ' + (@($qaLabel.groups) -join ' / ') + '）')
    Chk ($null -ne $qaLabelGroup -and [int]$qaLabelGroup.count -eq 2) ('その群の件数は 2（実際 ' + $(if ($null -ne $qaLabelGroup) { [string]$qaLabelGroup.count } else { 'その群が無い' }) + '）')
    Chk ($null -ne $qaLabelGroup -and -not [bool]$qaLabelGroup.blocking) 'その群は「ファイルを作れない指摘」として描かれない'
    Chk (-not (Test-YakuAnyContains -Items @($qaLabel.groups) -Needle '自動点検の指摘')) ('止める群は出ない（実際: ' + (@($qaLabel.groups) -join ' / ') + '）')
    Chk (-not ([string]$qaLabel.summary).Contains('ファイルを作れない指摘が')) ('要約が止めた件数を言わない: ' + [string]$qaLabel.summary)
    Chk (([string]$qaLabel.summary).Contains('書き出しは止まりません')) ('要約が、止まらないことを言う: ' + [string]$qaLabel.summary)
    Chk (-not ([string]$qaLabel.summary).Contains('直すところは見つかりませんでした')) ('警告を出しながら「直すところは見つかりませんでした」と言わない: ' + [string]$qaLabel.summary)
    # 止める条件は1つも増やしていない。同じ画面で、押せることを見る。
    Chk (-not [bool]$qcLabel.exportDisabled) '取り出しボタンは押せたまま（警告は止めない）'
    Chk ([string]$qcLabel.qaButtonLabel -eq '点検') ('道具の帯の「点検」は件数を出さない（止めた指摘は0件。実際: ' + [string]$qcLabel.qaButtonLabel + '）')
    Chk (-not [bool]$qcLabel.qaButtonHasBlockers) '止めている指摘がある見た目にはならない'
    # 「要対応」に数えない。数えると、確認し終えた資料が永久に終わらない。
    Chk ([string]$qcLabel.actionableCount -eq '0') ('要対応は 0 行（実際: ' + [string]$qcLabel.actionableCount + '）')
    Chk (-not [bool]$qcLabel.completeHidden) '「全部終わりました」の帯が出る'
    # 一方で、指摘そのものは数える。件数が消えたら、画面から見えなくなる。
    Chk (-not [bool]$qcLabel.filterHidden) '「点検の指摘」の絞り込みは出る（件数が画面に出ている）'
    Chk ([string]$qcLabel.filterCount -eq '2') ('その件数は 2（実際: ' + [string]$qcLabel.filterCount + '）')

    # ------------------------------------------------------------------ (o)
    Write-Host '(o) 原文の数字が、キー操作でカーソル位置へ入る' -ForegroundColor Cyan
    Chk (@($o.placeableRows).Count -eq 2) ('題材の作業が開けている。表は2行（実際 ' + @($o.placeableRows).Count + '）')
    Chk (@($o.placeableRows).Count -eq 2 -and [string]@($o.placeableRows)[0].source -eq $placeableSource) '別の作業を見ていない'
    Chk ([string]$o.placeableBefore -eq $placeableBareTarget) ('打ち込んだ訳文は、数字だけが欠けた形: ' + [string]$o.placeableBefore)
    # ---- (c) の対。IME 変換中は効かず、変換中でなければ効く。
    Chk ([bool]$o.placeableComposing.hidden) 'IME 変換中の Ctrl+D では一覧が出ない'
    Chk ([int]$o.placeableComposingCalls -eq 0) ('変換中は口も叩かない（実際 ' + [int]$o.placeableComposingCalls + ' 回）')
    # ここが対。キーを丸ごと殺しても上の2本は緑になるので、こちらが要る。
    Chk (-not [bool]$o.placeableNotComposing.hidden) '変換中でなければ、同じキーで一覧が出る'
    Chk ([int]$o.placeableNotComposingCalls -eq 1) ('そのときだけ口を1回叩く（実際 ' + [int]$o.placeableNotComposingCalls + ' 回）')
    Chk ([bool]$o.placeableAfterEscape.hidden) 'Esc で畳める'
    # ---- (a) 出現順に、原文どおりの表記で並ぶ
    $shownPlaceables = @($o.placeableOpened.items)
    Chk (-not [bool]$o.placeableOpened.hidden) '実キーの Ctrl+D でも一覧が出る'
    Chk ([bool]$o.placeableOpened.visible) '一覧が画面上で面積を持っている（CSSで消しても緑にならない）'
    Chk ($shownPlaceables.Count -eq 2) ('一覧は2件（実際 ' + $shownPlaceables.Count + '）')
    Chk ($shownPlaceables.Count -eq 2 -and [string]$shownPlaceables[0] -eq $placeableFirst) ('1件目は原文の1つ目の数字: ' + (Get-YakuFirstString -Items $shownPlaceables))
    Chk ($shownPlaceables.Count -eq 2 -and [string]$shownPlaceables[1] -eq $placeableSecond) ('2件目は原文の2つ目の数字: ' + $(if ($shownPlaceables.Count -eq 2) { [string]$shownPlaceables[1] } else { '' }))
    Chk ((@($o.placeableOpened.shown) -join '|') -eq (($shownPlaceables) -join '|')) ('画面に出ている文字も同じ（属性だけ正しい状態ではない）: ' + (@($o.placeableOpened.shown) -join '|'))
    Chk ((@($o.placeableOpened.numbers) -join '') -eq '12') ('番号は 1・2 と振られる（実際: ' + (@($o.placeableOpened.numbers) -join '') + '）')
    Chk ($null -ne $o.placeableRequest -and [int]$o.placeableRequest.index -eq 0) ('口へ送った行番号が正しい（実際 ' + [string]$o.placeableRequest.index + '）')
    Chk ($null -ne $o.placeableRequest -and [string]$o.placeableRequest.id -eq [string]$placeableProject.Id) '口へ送った作業の番号が正しい'
    # ---- (a) カーソル位置へ入る。末尾へ足す実装では通らない題材である。
    Chk ([int]$o.placeableCaret1.at -gt 0 -and [int]$o.placeableCaret1.at -lt ([string]$o.placeableBefore).Length) ('カーソルは訳文の途中に置いた（' + [string]$o.placeableCaret1.at + ' / ' + ([string]$o.placeableBefore).Length + '）')
    Chk ([string]$o.placeableAfterFirst -eq 'Net sales were 1,234 yen, up % from a year earlier.') ('番号キー 1 で、その位置へ1つ目が入る: ' + [string]$o.placeableAfterFirst)
    Chk ([bool]$o.placeableClosedAfterInsert.hidden) '入れたら一覧は畳む'
    Chk ([string]$o.placeableAfterSecond -eq $placeableFullTarget) ('番号キー 2 で、2つ目もその位置へ入る: ' + [string]$o.placeableAfterSecond)
    Chk ([bool]$o.placeableRowDirty) '入れた行は未保存の印が付く（保存の道は手入力と同じ）'
    # ---- 一覧を閉じているあいだは、番号キーはただの文字である。
    # 入れた直後のカーソルは、入れた数字の右にある。そこへ 7 が1文字打たれる。
    Chk ([string]$o.placeableAfterPlainDigit -eq 'Net sales were 1,234 yen, up 5.67% from a year earlier.') ('一覧を閉じた後の 7 は、カーソル位置へ1文字として打たれる: ' + [string]$o.placeableAfterPlainDigit)
    Chk (([string]$o.placeableAfterPlainDigit).Length -eq (([string]$o.placeableAfterSecond).Length + 1)) '番号キーを食べたままにしていない（訳文が1文字だけ増えている）'
    # ---- (b) 画面が作った訳文そのものを、本物の点検へ掛ける。
    #      入れる前は立ち、入れた後は立たない。**同じ行・同じ関数**で見る。
    $screenSegment = @($placeableProject.Segments)[0]
    $null = Set-YakuCatSegmentTranslation -Project $placeableProject -Index 0 -Text ([string]$o.placeableBefore)
    $screenBareCodes = @(@((Invoke-YakuCatSegmentValidation -Project $placeableProject -Segment $screenSegment).Findings) | ForEach-Object { [string]$_.Code })
    Chk ($screenBareCodes -contains 'numeric-value-mismatch') ('画面で打った「数字の無い訳文」は点検に落ちる（実際: ' + ($screenBareCodes -join ',') + '）')
    $null = Set-YakuCatSegmentTranslation -Project $placeableProject -Index 0 -Text ([string]$o.placeableAfterSecond)
    $screenFullCodes = @(@((Invoke-YakuCatSegmentValidation -Project $placeableProject -Segment $screenSegment).Findings) | ForEach-Object { [string]$_.Code })
    Chk ($screenFullCodes -notcontains 'numeric-value-mismatch') ('画面が入れた訳文では立たない（実際: ' + ($screenFullCodes -join ',') + '）')
    Chk ($screenFullCodes.Count -eq 0) ('その訳文は点検に1件も引っかからない（実際: ' + ($screenFullCodes -join ',') + '）')
    # ---- (d) 押したキーが、画面のキー一覧にも載っている。
    #      両向きの集合一致は tools/Test-YakuV9169UsabilityFixes.ps1 が見る。
    #      ここでは「実際に効いたキー」が一覧に実在することだけを確かめる。
    $catHtmlForKeys = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
    Chk ($catHtmlForKeys -match '<kbd>Ctrl</kbd>\+<kbd>D</kbd>') '画面のキー一覧に Ctrl+D が載っている'
    Chk ($catHtmlForKeys -match ('<kbd>1' + [string][char]0xFF5E + '9</kbd>')) '画面のキー一覧に、続けて押す番号キーが載っている'
    # 実機の口が、上と同じ関数から応答を作っていること。運転席へ返した応答は
    # ConvertTo-YakuCatSegmentPlaceablesJson が作ったものなので、Server.ps1 が
    # 別の作り方をしていたら実機だけ違う形を返す。**ここは字面でしか見られない**
    # （HTTP を立てて叩く門はこの試験の範囲外）。そのつもりで読むこと。
    $serverSource = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
    Chk ($serverSource -match "'placeables' \{") '/api/cat/placeables の口が実装にある'
    Chk ($serverSource -match 'ConvertTo-YakuCatSegmentPlaceablesJson -Project \$project -Index \$index') '口の応答も、同じ関数1つから作っている'

    if ($script:fail -eq 0) { Write-Host ('V91.76 画面の描画と配線の回帰テストに合格しました。検査 ' + $script:checks + ' 件。') -ForegroundColor Green }
    else { Write-Host ('FAILED: ' + $script:fail + ' / ' + $script:checks) -ForegroundColor Red }
} finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
exit ([int]($script:fail -gt 0))
