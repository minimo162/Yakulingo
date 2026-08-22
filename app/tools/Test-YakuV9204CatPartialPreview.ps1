<#
.SYNOPSIS
  V91.61: CAT翻訳の部分結果先出しの回帰試験。

.DESCRIPTION
  見るのは5つ((a)〜(e)。MAJOR-Aは(e)の中で見る)。

  (a) Add-YakuCatPartialPreviewRows(CatProject.ps1、ConvertTo-YakuCatCheckpointRows
      の直後に置いた新関数)。累積は1回の代入で丸ごと差し替えること。index/source/text
      だけを運び、masked/saved は運ばないこと(設計判断3)。

  (b) OnBatchCompleted相当の経路を、実際のバッチ翻訳(スタブ transport)で端から端まで
      通す。checkpoint行がジョブ state へ積まれること、重複排除で1 item が複数
      セグメントへ展開される場合に rows が展開後(1行=1セグメント)であること、
      実値へ復元済みで [[N が残らないことを、本物のマスク・復元パイプラインで確認する。
      題材の3item目はわざと数値マスクの個数整合を崩す応答を返させ、
      ConvertTo-YakuCatCheckpointRows が text='' のまま emit する行(数値不整合で
      棄却された行)を Add-YakuCatPartialPreviewRows が弾くこと、partial_total が
      Save-YakuCatBatchCheckpoint の戻り値と一致することを固定する(CoD審査
      REWORK-1 MAJOR-1)。items は手組みではなく ConvertTo-YakuCatDedupedItems
      から作る(NIT-5)。

  (c) Convert-YakuTranslationJobResultJson(Server.ps1からAST抽出)。partial_after の
      差分カーソル(負値・範囲外・省略時デフォルト0・Int32上限を含む)、partial_total が
      常に累積総数であること、cancelled/error等の terminal 分岐でも同じ形で返ること、
      kind=text 等 partial_* を持たない State では 0/空配列に落ちること。

  (d) Server.ps1 の静的配線。/api/jobs/ ルートの一致行($path = AbsolutePath、
      正規表現)が変わっていないこと(クエリ文字列はそもそも $path に乗らないため
      ルート自体の変更は不要という実装前確認の結果を、以後の変更から守るピン)。
      partial_after の読み出しに Get-YakuQueryValue を使っていること。分母
      (partial_expected_total)の算出式のピン(MINOR-3)。partial_after を
      Int64で受けてからInt32へ丸める経路のピン(NIT-8)。

  (e) 実機Chromium(tools/cat-partial-screen/cat-partial-gate.js)。
      working(部分rows有)→doneの順で返すpollスタブで:
        - 該当行に先出しが表示される(a)
        - working中に絞り込みボタン(すべて)を押してrenderRows()が走っても、
          先出しの訳文・印は残る(MINOR-2)
        - 訳文欄が非空の行は触らない(b)
        - source不一致の行は触らない(c)
        - 全面再描画が起きていない(tick前後で無関係な行の要素同一性が保たれる)(d)
        - done→apply→render後は先出しの印が消え、apply結果で上書きされる(e)
        - cancelled で先出し表示が画面に残る(f)
        - MAJOR-A: cancelled後、page.gotoでの再読み込みではなく#cat-doc-switch
          から**同じページ内で**別資料へ切り替える(jobContextは
          cancelled/errorでもnullにならない設計のため、再読み込みしないと
          再現しない)。切り替え先資料のindex=0はcancelProjectと**同一原文**
          （source一致ガードだけでは防げない題材、金融資料の「(単位:百万円)」
          相当）。applyPartialPreviewRow の資料一致ガード
          (jobContext.scope.id === project.id)が効き、切り替え先の行へは
          前資料の先出しが書き込まれないことを見る。

  突然変異4種(壊して赤・戻して緑、diffで復元がクリーンなことも確認):
    1. Add-YakuCatPartialPreviewRows が text の代わりに masked を運ぶよう変異
       → (b)の「[[N が残らない」assertが赤になる
    2. Convert-YakuTranslationJobResultJson の差分カーソルを無効化(常に全件)する
       よう変異 → (c)の差分assertが赤になる
    3. Add-YakuCatPartialPreviewRows の空白述語ガード(MAJOR-1で足した1行)を
       外す変異 → (b)の「数値不整合で棄却された行(index=3)は先出しに載らない」
       assertと「partial_totalはSave-YakuCatBatchCheckpointの戻り値と一致する」
       assertが赤になる
    4. applyPartialPreviewRow の資料一致ガード(MAJOR-Aで足した1行)を外す変異
       → MAJOR-Aの「切り替え後も前資料の先出し訳文が書き込まれない」assertが
       赤になる(既存3種はどれも資料をまたがないため検出しない)
  この4つは tools/Mutate-V9204*.ps1 ではなく、このファイルの実行前後で
  手動再現した記録として README 相当を持たない(CoD運用メモに実行ログを残す)。

  node/Playwright/Chromium が無い環境では(e)を**緑にしない**。終了コード3
  (未測定)で抜ける。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9204CatPartialPreview.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0
$YAKU_SCREEN_UNMEASURED = 3

function Chk { param([bool]$c, [string]$m) $script:checks++; if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

Write-Host 'Test-YakuV9204CatPartialPreview'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9204-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT = '1'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }
$script:YakuRoot = $root

foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotBudget.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1')) {
    . (Join-Path (Join-Path $root 'src') $name)
}
$settings = Read-YakuSettings -Root $root
Clear-YakuTranslationCache

# ============================================================ (a) Add-YakuCatPartialPreviewRows
Write-Host '-- (a) Add-YakuCatPartialPreviewRows: 累積・単一代入・フィールドの絞り込み --'

$jobStateA = [hashtable]::Synchronized(@{})
Add-YakuCatPartialPreviewRows -JobState $jobStateA -CheckpointRows @()
Chk (-not $jobStateA.ContainsKey('partial_rows')) '0件の checkpoint 行では何も書かない(初期状態のまま)'

$firstBatchRows = @(
    [ordered]@{ index = 0; source = '原文A'; text = '訳文A'; masked = '訳文A' }
    [ordered]@{ index = 1; source = '原文B'; text = '訳文B'; masked = '[[N1]]台' }
)
Add-YakuCatPartialPreviewRows -JobState $jobStateA -CheckpointRows $firstBatchRows
Chk ([int]$jobStateA['partial_total'] -eq 2) ('1回目のバッチ後、累積2件(実際 ' + [int]$jobStateA['partial_total'] + ')')
Chk (@($jobStateA['partial_rows']).Count -eq 2) '積んだ配列も2件'
$rowsAfterFirst = @($jobStateA['partial_rows'])
foreach ($r in $rowsAfterFirst) {
    Chk (@($r.Keys) -notcontains 'masked') ('先出し行は masked を運ばない(index=' + $r.index + ')')
    Chk (@($r.Keys) -notcontains 'saved') ('先出し行は saved を運ばない(index=' + $r.index + ')')
    Chk (@($r.Keys).Count -eq 3 -and (@($r.Keys) -contains 'index') -and (@($r.Keys) -contains 'source') -and (@($r.Keys) -contains 'text')) ('先出し行は index/source/text の3項目だけ(index=' + $r.index + ')')
}

$secondBatchRows = @([ordered]@{ index = 2; source = '原文C'; text = '訳文C'; masked = '訳文C' })
$referenceBeforeSecond = $jobStateA['partial_rows']
Add-YakuCatPartialPreviewRows -JobState $jobStateA -CheckpointRows $secondBatchRows
Chk ([int]$jobStateA['partial_total'] -eq 3) ('2回目のバッチ後、累積3件(実際 ' + [int]$jobStateA['partial_total'] + ')')
Chk (-not [object]::ReferenceEquals($referenceBeforeSecond, $jobStateA['partial_rows'])) '2回目は配列を新しく作って丸ごと差し替える(同じ配列を in-place 追記しない)'
Chk ([string]$rowsAfterFirst[0].text -eq '訳文A' -and [string]$rowsAfterFirst[1].text -eq '訳文B') '差し替え後も、以前に取り出した参照の中身は変わらない(古い配列を書き換えていない証拠)'
$rowsAfterSecond = @($jobStateA['partial_rows'])
Chk (([string]$rowsAfterSecond[0].index -eq '0') -and ([string]$rowsAfterSecond[1].index -eq '1') -and ([string]$rowsAfterSecond[2].index -eq '2')) '累積は到着順(index 0,1,2)のまま保たれる'

# ============================================================ (b) OnBatchCompleted相当を端から端まで
Write-Host '-- (b) OnBatchCompleted相当: 実バッチ翻訳→checkpoint→先出し行 --'

$source1 = 'We shipped 120 units this quarter.'
$source2 = 'Operating profit was 296 million yen.'
# segment 3 はわざと数値マスクの整合が壊れる訳文を返させる題材(下記)。
# ConvertTo-YakuCatCheckpointRows は数値不整合で棄却した item も text='' の
# ままrowsへ載せる(実際に捨てるのはSave-YakuCatBatchCheckpointの空白述語)。
# Add-YakuCatPartialPreviewRows が同じ述語で弾かないと、この行にまで
# 「先出し」バッジが付き、訳了 n/N が水増しされる(CoD審査 REWORK-1 MAJOR-1)。
$source3 = 'Net sales grew 45 percent.'
$segments = @(
    [pscustomobject]@{ Text=$source1; Translation=''; MaskedTranslation=''; Origin=''; Confirmed=$false; Joined=$false; Kind='text'; Sheet=''; Location='本文'; BlockIds=@(); Cells=@() },
    [pscustomobject]@{ Text=$source1; Translation=''; MaskedTranslation=''; Origin=''; Confirmed=$false; Joined=$false; Kind='text'; Sheet=''; Location='本文'; BlockIds=@(); Cells=@() },
    [pscustomobject]@{ Text=$source2; Translation=''; MaskedTranslation=''; Origin=''; Confirmed=$false; Joined=$false; Kind='text'; Sheet=''; Location='本文'; BlockIds=@(); Cells=@() },
    [pscustomobject]@{ Text=$source3; Translation=''; MaskedTranslation=''; Origin=''; Confirmed=$false; Joined=$false; Kind='text'; Sheet=''; Location='本文'; BlockIds=@(); Cells=@() }
)
$project = [pscustomobject]@{ Id='partial-preview'; Path=''; FileName='貼り付け'; Direction='to_jp'; Source='text'; CreatedAt=(Get-Date).ToString('s'); CorpusSection=''; Blocks=@(); Segments=$segments }
$script:YakuCatProjects[$project.Id] = $project
Chk (Save-YakuCatProject -Project $project) '空のProjectを先に永続化する'

# 重複排除で1 item が複数セグメントへ展開される場合を、手組みではなく
# 実装(ConvertTo-YakuCatDedupedItems)から作る(正解が自分の出力由来に
# ならないよう、CoD審査 REWORK-1 NIT-5 の指摘どおり実装へ委ねる)。
# segment 0・1 は同じ原文なので1つの item(Targets=@(0,1))へ畳まれる
# (実装前確認の結論: checkpoint rows は Targets 展開後=1行=1セグメント)。
$rawItems = @(
    [pscustomobject]@{ index = 0; text = $source1 }
    [pscustomobject]@{ index = 1; text = $source1 }
    [pscustomobject]@{ index = 2; text = $source2 }
    [pscustomobject]@{ index = 3; text = $source3 }
)
$items = New-Object System.Collections.Generic.List[object]
foreach ($dedupedEntry in @(ConvertTo-YakuCatDedupedItems -RawItems $rawItems)) { [void]$items.Add($dedupedEntry) }
Chk (@($items.ToArray()).Count -eq 3) ('dedupeで3 item になる(実際 ' + @($items.ToArray()).Count + ')')
$null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $root -Direction 'to_jp'
$warnings = New-Object System.Collections.Generic.List[object]

function Invoke-YakuProtectedTransportTestHook {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat, [switch]$PreserveEndMarker, $Warnings, $ProgressState)
    $requestId = [regex]::Match($Prompt, 'YAKULINGO_END:([0-9a-f]{32})').Groups[1].Value
    # Copilotは伏せた数値トークンをそのまま返す(意味を知らないため)。
    # 復元(Restore-YakuCatItemTranslations)がここで [[N1]] を実値へ戻す。
    # ID:3(source3、数値1個をマスク済み)だけは、わざとトークンを落として
    # 返す。数値マスクの個数整合が崩れ、Restore側がこの item を
    # $copyMap から取り除く(数値が抜けた訳は欠陥、CLAUDE.md)。
    return ("[[ID:1]] 1. 今四半期の出荷台数は[[N1]]台です。`n[[ID:2]] 2. 営業利益は[[N1]]百万円でした。`n[[ID:3]] 3. 純売上高は増加しました。`nYAKULINGO_END:$requestId")
}

$jobStateB = [hashtable]::Synchronized(@{ _test_checkpoint_saved_count = -1 })
$callback = {
    param($completedItems, $completedMap)
    # Server.ps1 の onCatBatchCompleted closure と同じ形(1203行台)。
    $rows = @(ConvertTo-YakuCatCheckpointRows -Items @($completedItems) -Translations $completedMap -Warnings $warnings -Direction 'to_jp')
    if ($rows.Count -gt 0) {
        # .GetNewClosure() は $script: スカラーへの代入をこの closure の
        # 私有スコープへ止め、呼び出し元へ伝播させない(実測して確認した罠)。
        # 参照型($jobStateB自体、既にpartial_rows/partial_totalの書き込みに
        # 使っている)へ載せることで確実に外へ伝える。
        $jobStateB['_test_checkpoint_saved_count'] = Save-YakuCatBatchCheckpoint -ProjectId $project.Id -ProjectRevision ([int]$project.Revision) -Translations $rows
        Add-YakuCatPartialPreviewRows -JobState $jobStateB -CheckpointRows $rows
    }
}.GetNewClosure()
$context = @{
    BatchOrdinal=0; TotalBatches=1; MaxRetryDepth=0
    CacheHits=0; TranslatedSoFar=0; UniqueTotal=3; CopilotCalls=0
    CompletedMap=@{}; OnBatchCompleted=$callback
}
$null = Invoke-YakuCatTranslationItems -Root $root -Items @($items.ToArray()) -Settings $settings -Direction 'to_jp' -MaxChars 3000 -Warnings $warnings -Context $context

Chk ([int]$jobStateB['partial_total'] -eq 3) ('3 item(展開後4セグメントのうち数値不整合の1行を除いた3件)が積まれる(実際 ' + [int]$jobStateB['partial_total'] + ')')
$partialRowsB = @($jobStateB['partial_rows'] | Sort-Object { [int]$_.index })
Chk (@($partialRowsB).Count -eq 3) '積んだ行も3件(1行=1セグメント、item単位ではない)'
Chk ([int]$partialRowsB[0].index -eq 0 -and [int]$partialRowsB[1].index -eq 1 -and [int]$partialRowsB[2].index -eq 2) 'indexはプロジェクトのセグメントindex(0,1,2)そのもの'
Chk ((@($partialRowsB.index)) -notcontains 3) ('[MAJOR-1] 数値不整合で棄却された行(index=3)は先出しに載らない(実際のindex一覧: ' + (($partialRowsB.index) -join ',') + ')')
Chk ([int]$jobStateB['partial_total'] -eq [int]$jobStateB['_test_checkpoint_saved_count']) ('[MAJOR-1] partial_totalはSave-YakuCatBatchCheckpointの戻り値と一致する(実際 partial_total=' + [int]$jobStateB['partial_total'] + ' / checkpoint保存件数=' + [int]$jobStateB['_test_checkpoint_saved_count'] + ')')
Chk ([string]$partialRowsB[0].text -eq [string]$partialRowsB[1].text) '重複した原文(segment 0,1)は同じ訳文を持つ(1 item→複数行への正しい展開)'
Chk ([string]$partialRowsB[0].source -eq $source1 -and [string]$partialRowsB[2].source -eq $source2) 'sourceは実際のプロジェクト原文と一致する'
foreach ($r in $partialRowsB) {
    Chk (([string]$r.text) -notmatch '\[\[N') ('先出しtextにマスク残留[[Nが無い(index=' + $r.index + '、実際「' + [string]$r.text + '」)')
    Chk (([string]$r.text) -notmatch '\[\[P') ('先出しtextにマスク残留[[Pが無い(index=' + $r.index + '、実際「' + [string]$r.text + '」)')
    Chk (-not [string]::IsNullOrWhiteSpace([string]$r.text)) ('[MAJOR-1] 先出しtextは空でない(index=' + $r.index + ')')
}
Chk (([string]$partialRowsB[0].text) -match '120') '数値そのものは実値へ復元されている(index0、120)'
Chk (([string]$partialRowsB[2].text) -match '296') '数値そのものは実値へ復元されている(index2、296)'

# ============================================================ (c) Convert-YakuTranslationJobResultJson
Write-Host '-- (c) Convert-YakuTranslationJobResultJson: 差分カーソル・累積total --'

function Get-N9204FunctionText {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Language.ScriptBlockAst]$Ast, [Parameter(Mandatory=$true)][string]$Name)
    $found = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return $null }
    return [string]$found[0].Extent.Text
}
$serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
$serverTokens = $null; $serverParseErrors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$serverTokens, [ref]$serverParseErrors)
Chk (@($serverParseErrors).Count -eq 0) 'Server.ps1 が構文エラー無く解析できる'

$convertText = Get-N9204FunctionText -Ast $serverAst -Name 'Convert-YakuTranslationJobResultJson'
Chk (-not [string]::IsNullOrWhiteSpace($convertText)) 'Server.ps1 から Convert-YakuTranslationJobResultJson を取り出せる'
if (-not [string]::IsNullOrWhiteSpace($convertText)) { Invoke-Expression $convertText }
Set-Item -Path Function:Update-YakuTranslationJobs -Value { param() }

function New-N9204JobState {
    param([string]$Kind = 'cat', [string]$Mode = 'working', [array]$PartialRows = $null, [int]$PartialTotal = 0, [int]$PartialExpectedTotal = 0, [switch]$OmitPartialFields)
    $s = @{
        id = 'job-n9204'; mode = $Mode; label = 'Working'; class = 'warn'; detail = ''; progress = 40
        kind = $Kind; phase = 'translating'; unique_done = 0; unique_total = 0; updated_at = ''; error_code = ''; completion_status = ''
        result_json = ''
    }
    if (-not $OmitPartialFields) {
        $s['partial_rows'] = if ($null -ne $PartialRows) { $PartialRows } else { @() }
        $s['partial_total'] = $PartialTotal
        $s['partial_expected_total'] = $PartialExpectedTotal
    }
    return $s
}

$threeRows = @(
    [ordered]@{ index = 0; source = 'S0'; text = 'T0' }
    [ordered]@{ index = 1; source = 'S1'; text = 'T1' }
    [ordered]@{ index = 2; source = 'S2'; text = 'T2' }
)

$stateAll = New-N9204JobState -PartialRows $threeRows -PartialTotal 3 -PartialExpectedTotal 5
$jsonAfter0 = Convert-YakuTranslationJobResultJson -State $stateAll -PartialAfter 0 | ConvertFrom-Json
Chk (@($jsonAfter0.partial_rows).Count -eq 3) ('partial_after=0 は全件を返す(実際 ' + @($jsonAfter0.partial_rows).Count + ')')
Chk ([int]$jsonAfter0.partial_total -eq 3 -and [int]$jsonAfter0.partial_expected_total -eq 5) 'partial_total/partial_expected_totalも返す'

$jsonAfter2 = Convert-YakuTranslationJobResultJson -State $stateAll -PartialAfter 2 | ConvertFrom-Json
Chk (@($jsonAfter2.partial_rows).Count -eq 1 -and [int]$jsonAfter2.partial_rows[0].index -eq 2) ('partial_after=2 は3件目だけを返す(実際 ' + @($jsonAfter2.partial_rows).Count + '件、index=' + $(if(@($jsonAfter2.partial_rows).Count -gt 0){$jsonAfter2.partial_rows[0].index}else{'-'}) + ')')
Chk ([int]$jsonAfter2.partial_total -eq 3) 'partial_totalはカーソル位置に関わらず累積総数のまま(3)'

$jsonAfterAll = Convert-YakuTranslationJobResultJson -State $stateAll -PartialAfter 3 | ConvertFrom-Json
Chk (@($jsonAfterAll.partial_rows).Count -eq 0) 'partial_after=累積件数と同じなら0件(まだ次が無い)'

$jsonAfterOver = Convert-YakuTranslationJobResultJson -State $stateAll -PartialAfter 99 | ConvertFrom-Json
Chk (@($jsonAfterOver.partial_rows).Count -eq 0) '範囲外の大きい partial_after でも例外にならず0件'

$jsonAfterNeg = Convert-YakuTranslationJobResultJson -State $stateAll -PartialAfter (-5) | ConvertFrom-Json
Chk (@($jsonAfterNeg.partial_rows).Count -eq 3) '負のpartial_afterは0扱いで全件返す'

$jsonDefault = Convert-YakuTranslationJobResultJson -State $stateAll | ConvertFrom-Json
Chk (@($jsonDefault.partial_rows).Count -eq 3) '-PartialAfterを省略した既存呼び出し(/api/cancel-translation等)は既定0で全件返す(後方互換)'

# terminal分岐(cancelled/error)でも同じ形で返る(設計判断5: キャンセル後も画面へ残す)
$stateCancelled = New-N9204JobState -Mode 'cancelled' -PartialRows $threeRows -PartialTotal 3 -PartialExpectedTotal 5
$jsonCancelled = Convert-YakuTranslationJobResultJson -State $stateCancelled -PartialAfter 0 | ConvertFrom-Json
Chk (@($jsonCancelled.partial_rows).Count -eq 3 -and [int]$jsonCancelled.partial_total -eq 3) 'mode=cancelled でも partial_rows/partial_total を返す(terminal分岐の外で読むため)'

$stateFailed = New-N9204JobState -Mode 'failed' -PartialRows $threeRows -PartialTotal 3 -PartialExpectedTotal 5
$stateFailed['result_json'] = ''
$jsonFailed = Convert-YakuTranslationJobResultJson -State $stateFailed -PartialAfter 1 | ConvertFrom-Json
Chk (@($jsonFailed.partial_rows).Count -eq 2) 'mode=failed でも partial_after の差分カーソルが効く'

# kind=text(パレット/簡易翻訳) 相当。partial_*キーを一切持たない State でも
# 例外にならず 0/空配列に落ちる(Start-YakuTranslationJobの初期値と同じ既定)。
$stateText = New-N9204JobState -Kind 'text' -Mode 'done' -OmitPartialFields
$stateText['result_json'] = ([ordered]@{ Kind='text'; Direction='to_en'; SourceText='src'; Options=@() } | ConvertTo-Json -Depth 6 -Compress)
$jsonText = Convert-YakuTranslationJobResultJson -State $stateText -PartialAfter 0 | ConvertFrom-Json
Chk ([int]$jsonText.partial_total -eq 0) 'kind=textでpartial_*キーを持たないStateは partial_total=0'
Chk (@($jsonText.partial_rows).Count -eq 0) 'kind=textでpartial_*キーを持たないStateは partial_rows=空配列'
Chk ([int]$jsonText.masked_count -eq 0) '既存フィールド(masked_count)は変わらず0(V9198との非干渉)'

# ============================================================ (d) Server.ps1 静的配線
Write-Host '-- (d) Server.ps1: /api/jobs/ ルートとクエリ読み出しの配線 --'
$serverSource = [IO.File]::ReadAllText($serverPath)
Chk ($serverSource.Contains("`$path -match '^/api/jobs/([a-f0-9]{32})`$'")) 'GET /api/jobs/{id} のルート一致は32桁16進のまま変わっていない(クエリ文字列を通す変更をしていない)'
Chk ($serverSource.Contains('$path = $req.Url.AbsolutePath')) '$path は引き続き AbsolutePath(クエリを含まない)から作る(実装前確認の前提)'
Chk ($serverSource.Contains("Get-YakuQueryValue -Request `$req -Name 'partial_after'")) 'partial_after の読み出しは Get-YakuQueryValue 経由(QueryStringのCP932化けを避ける既存流儀を踏襲)'
Chk ($serverSource.Contains('-PartialAfter $partialAfter')) 'ルートは読み取った partial_after を Convert-YakuTranslationJobResultJson へ渡す'
# 分母(partial_expected_total)はジョブ scriptblock 内のローカル代入で、
# 試験からは端から端まで叩けない(分子=partial_rowsの積み上げ方は
# Add-YakuCatPartialPreviewRows へ切り出して(b)で叩いているのに、分母だけ
# 同じ穴に残っていた。CoD審査 REWORK-1 MINOR-3)。せめて式そのものを
# ピンし、以後の変更が黙って書き換えないようにする。
Chk ($serverSource.Contains("`$JobState['partial_expected_total'] = @(`$cat.items).Count")) '[MINOR-3] partial_expected_totalの算出式(cat.items件数=展開前・1行=1セグメントの生の依頼件数)がピンどおり'
# [int]直接castはInt32の桁を超える数字列で例外→catchで0→「先頭から全部」に
# 反転する(CoD審査 REWORK-1 NIT-8)。Int64で受けてからInt32へ丸める経路が
# 実装に残っていることをピンする(500にならないことは経路自体が例外を
# 投げない作りであることで担保する)。
Chk ($serverSource.Contains('[int64]::TryParse($partialAfterRaw, [ref]$partialAfterInt64)')) '[NIT-8] partial_afterはInt64で受けてからInt32へ丸める(直接[int]castで例外→0フォールバックしない)'
Chk ($serverSource.Contains('$partialAfterRaw.Length -gt 15')) '[NIT-8] Int64の桁も超える文字列はTryParseへ渡さず、長さで大きい値と判定する'

# 実測: NIT-8のとおり、境界値をConvert-YakuTranslationJobResultJson側で
# 確かめる(ルート側の文字列→Int32丸めが正しく動けば、渡ってくる
# PartialAfterはInt32範囲に収まるので、ここでは丸め後の値を模して
# 「範囲外の巨大値=0件」を再確認する。実際のルート解析はソースピンで守る)。
$jsonAfterHuge = Convert-YakuTranslationJobResultJson -State $stateAll -PartialAfter ([int]::MaxValue) | ConvertFrom-Json
Chk (@($jsonAfterHuge.partial_rows).Count -eq 0) '[NIT-8] Int32範囲に丸めた最大値でも例外にならず0件(全件返りに反転しない)'

# ============================================================ (e) 実機Chromium部
Write-Host '-- (e) chromium --'

$driver = Join-Path (Join-Path $toolsRoot 'cat-partial-screen') 'cat-partial-gate.js'
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) {
    Write-Host ('UNMEASURED: 運転席がありません: ' + $driver) -ForegroundColor Red
    if ($script:fail -gt 0) { exit 1 }
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Write-Host 'UNMEASURED: node が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    if ($script:fail -gt 0) { exit 1 }
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeExe = [string]$nodeCmd.Source
$probeDir = (Split-Path -Parent $driver).Replace('\', '/')
$null = & $nodeExe -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    if ($script:fail -gt 0) { exit 1 }
    exit $YAKU_SCREEN_UNMEASURED
}

# 実際に開く資料(done→apply/f キャンセル/MAJOR-A 切り替え先)を、本物の関数で
# 作る(写経しない)。MAJOR-A用のswitchTargetProjectは、cancelProjectの1行目と
# **同じ原文**を持つ(金融資料の「(単位:百万円)」のような先頭行一致は日常で、
# source一致ガードだけでは資料またぎの誤書き込みを防げないことを実証する)。
$sharedFirstLine = '(単位:百万円)を含む中止用の原文です。'
$doneProject = New-YakuCatTextProject -Root $root -Text ('先出し原文Aです。' + "`n" + '先出し原文Bです。' + "`n" + '先出し原文Cです。') -Settings $settings -Direction 'to_en'
$cancelProject = New-YakuCatTextProject -Root $root -Text ($sharedFirstLine + "`n" + '中止用の原文Yです。' + "`n" + '中止用の原文Zです。') -Settings $settings -Direction 'to_en'
$switchTargetProject = New-YakuCatTextProject -Root $root -Text ($sharedFirstLine + "`n" + '乗り換え先の原文Bです。' + "`n" + '乗り換え先の原文Cです。') -Settings $settings -Direction 'to_en'
Chk ([string]$cancelProject.Segments[0].Text -eq $sharedFirstLine -and [string]$switchTargetProject.Segments[0].Text -eq $sharedFirstLine) '[MAJOR-A前提] cancelProjectとswitchTargetProjectのindex=0は同一原文(source一致ガードだけでは防げない題材)'
$doneProjectJson = ConvertTo-YakuCatProjectJson -Project $doneProject
$cancelProjectJson = ConvertTo-YakuCatProjectJson -Project $cancelProject
$switchTargetProjectJson = ConvertTo-YakuCatProjectJson -Project $switchTargetProject

# apply後の「正本」snapshot。先出しの値とは別の文字列にして、apply結果で
# 確実に上書きされたことを見分けられるようにする。まず先出し前の姿を
# 直列化してから、同じオブジェクトを書き換えてapply後の姿を作る
# (revision等は本試験のスタブでは検証しないので揃えなくてよい)。
$doneProject.Segments[0].Translation = 'Final applied zero.'
$doneProject.Segments[0].Origin = 'copilot'
$doneProject.Segments[1].Translation = 'Final applied one.'
$doneProject.Segments[1].Origin = 'copilot'
$doneProject.Segments[2].Translation = 'Final applied two.'
$doneProject.Segments[2].Origin = 'copilot'
$applyDoneProjectJson = ConvertTo-YakuCatProjectJson -Project $doneProject

$utf8 = New-Object System.Text.UTF8Encoding($false)
$doneProjectPath = Join-Path $tmp 'project-done.json'
$cancelProjectPath = Join-Path $tmp 'project-cancel.json'
$applyDoneProjectPath = Join-Path $tmp 'project-done-applied.json'
$switchTargetProjectPath = Join-Path $tmp 'project-switch-target.json'
[IO.File]::WriteAllText($doneProjectPath, $doneProjectJson, $utf8)
[IO.File]::WriteAllText($cancelProjectPath, $cancelProjectJson, $utf8)
[IO.File]::WriteAllText($applyDoneProjectPath, $applyDoneProjectJson, $utf8)
[IO.File]::WriteAllText($switchTargetProjectPath, $switchTargetProjectJson, $utf8)
$observedPath = Join-Path $tmp 'observed.json'
$stderrPath = Join-Path $tmp 'node-stderr.txt'

$arguments = @($driver, (Join-Path $root 'www'), $doneProjectPath, $cancelProjectPath, $applyDoneProjectPath, $switchTargetProjectPath, $observedPath) | ForEach-Object { '"' + $_ + '"' }
$proc = Start-Process -FilePath $nodeExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
$nodeErr = ''
if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
Chk ([int]$proc.ExitCode -eq 0) ('運転席が走り切る' + $(if ($nodeErr) { ' / ' + $nodeErr.Substring(0, [Math]::Min(400, $nodeErr.Length)) } else { '' }))

$o = $null
if (Test-Path -LiteralPath $observedPath) { $o = [IO.File]::ReadAllText($observedPath, $utf8) | ConvertFrom-Json }
Chk ($null -ne $o) '画面で観測した事実を受け取れた'
if ($null -eq $o) { throw 'CAT_PARTIAL_GATE_NO_OBSERVATION' }
Chk ([string]::IsNullOrEmpty([string]$o.fatal)) ('画面の操作が途中で止まっていない' + $(if ($o.fatal) { ' / ' + ([string]$o.fatal).Substring(0, [Math]::Min(400, ([string]$o.fatal).Length)) } else { '' }))
Chk (@($o.errors).Count -eq 0) ('ページ例外が無い(実測: ' + (($o.errors -join ' | ')) + ')')
Chk (@($o.console).Count -eq 0) ('console.errorが無い(実測: ' + (($o.console -join ' | ')) + ')')

Chk ([bool]$o.observedPartialAfterFirstMissingOrZero) '(実装前確認3) 最初のpollはpartial_afterを付けない、または0(初回に累積は無い)'
Chk ([string]$o.observedPartialAfterSecond -eq '1') '2回目のpollはpartial_after=1(1件目を受け取った直後の値)'
Chk ([string]$o.observedPartialAfterThird -eq '3') '3回目のpollはpartial_after=3(2件受け取った後の累積)'

Chk ([bool]$o.row0HasPartialClass) '(a) 該当行(index=0)にcat-partial-previewの印が付く'
Chk ([string]$o.row0Value -eq 'Translated shipment zero.') ('(a) 該当行の訳文欄へ先出しのtextが書き込まれる(実際: ' + [string]$o.row0Value + ')')
Chk ([bool]$o.row0BadgeFound) '(a) 先出しバッジが訳文欄側に見える'

Chk ([string]$o.row0ValueAfterFilterClick -eq 'Translated shipment zero.') ('[MINOR-2] working中に絞り込みボタン(すべて)を押してrenderRows()が走っても、先出しの訳文は残る(実際: ' + [string]$o.row0ValueAfterFilterClick + ')')
Chk ([bool]$o.row0HasPartialClassAfterFilterClick) '[MINOR-2] 絞り込みで作り直された行にも先出しの印が付き直す'

Chk ([string]$o.row1ValueAfterTick -eq 'manually typed by user') ('(b) 訳文欄が非空の行(index=1)は先出しで上書きされない(実際: ' + [string]$o.row1ValueAfterTick + ')')
Chk (-not [bool]$o.row1HasPartialClassAfterTick) '(b) 触らなかった行には先出しの印も付かない'

Chk ([string]$o.row2ValueAfterTick -eq '') ('(c) source不一致の行(index=2)は触らない(実際: 「' + [string]$o.row2ValueAfterTick + '」)')
Chk (-not [bool]$o.row2HasPartialClassAfterTick) '(c) source不一致の行には印も付かない'

Chk ([bool]$o.domIdentityPreservedAfterTicks) '(d) working中は行要素のDOM同一性が保たれる(全面再描画=renderRows/renderをtickから呼んでいない)'

Chk ([string]$o.row0ValueAfterApply -eq 'Final applied zero.') ('(e) done→apply後は正本の訳文で上書きされる(実際: ' + [string]$o.row0ValueAfterApply + ')')
Chk (-not [bool]$o.row0HasPartialClassAfterApply) '(e) apply後はrender()が行を作り直すので先出しの印は自然に消える'
Chk (-not [bool]$o.row0BadgeFoundAfterApply) '(e) 先出しバッジも apply 後は残らない'

Chk ([bool]$o.cancelRow0HasPartialClass) '(f) キャンセル後も先出しの印が画面に残る'
Chk ([string]$o.cancelRow0Value -eq 'Translated cancel zero.') ('(f) キャンセル後も先出しの訳文が画面に残る(実際: ' + [string]$o.cancelRow0Value + ')')
Chk ([string]$o.cancelStatusText -match '保存されています') '(f) 既存のキャンセル文言(保存されています)と矛盾しない'

Chk ([string]$o.switchTargetSharedSource -eq $sharedFirstLine) '[MAJOR-A前提] 切り替え先資料のindex=0はcancelProjectと同一原文が画面にも出ている(題材が成立している)'
Chk ([string]$o.switchTargetRow0Value -eq '') ('[MAJOR-A] キャンセル後に別資料へ切り替えても、前の資料の先出し訳文が新しい資料の同一原文行へ書き込まれない(実際: 「' + [string]$o.switchTargetRow0Value + '」)')
Chk (-not [bool]$o.switchTargetRow0HasPartialClass) '[MAJOR-A] 切り替え先の行に先出しの印も付かない'

Write-Host ('checks=' + $script:checks + ' fail=' + $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
