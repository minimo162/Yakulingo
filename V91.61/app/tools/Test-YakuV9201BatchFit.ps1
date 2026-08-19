<#
.SYNOPSIS
  「まとめて収める」（V9201）の回帰試験。

.DESCRIPTION
  見るのは2つ。

  (a) 静的部。cat.js に共有関数（isFitBatchEligible・fitBatchTargets・
      computeFitBudget・requestFitCandidateJobStart）が実在し、1行ダイアログ
      （generatePublicationCandidates）と行の1クリック導線（renderSegmentActions
      の data-cat-fit-candidates 判定）の両方が同じ isFitBatchEligible /
      computeFitBudget を呼んでいること（純粋な抽出。二重実装をしていない）。
      openFitPublicationFlow は変えていない（V9196がその本体を固定する）。
      JOB_RUNNING検出（isJobRunningConflict）が実在し、実際のサーバ応答文言
      （別の翻訳が実行中です）を拾うこと。busy中はまとめて収めるボタンも
      止まること。キャッシュの鮮度判定が Ordinal 一致（===）で行われて
      いること。まとめて適用（自動適用）の口を新設していないこと
      （publication-apply への複数candidate一括送信が無い）。

  (b) 実機Chromium部。本物の cat.html/cat.js を配り、fetchスタブでジョブ完了を
      順に返す（tools/batch-fit/batch-fit-gate.js）。見るのは:
        - 対象行の選定: 配置計画の無い行(index=4)・fitリスクの無い行(index=5)は
          対象に数えない・呼ばない。件数はボタン・確認文の両方に出る
        - 直列性: 同時に2ジョブ投げない（前の行が terminal になってから
          次を投げる。ジョブが2tick後にdoneを返す行を混ぜて検証）
        - JOB_RUNNINGリトライ: サーバの直列契約違反(400/CAT_REQUEST_FAILED、
          文言「別の翻訳が実行中です」)を1回だけ返す行があっても、キューは
          同じ行へ黙って再試行し、エラーとして数えない
        - max_chars: 行ごとに異なる実幅由来の値になる（固定値でも、従来の
          0.8倍フォールバックでもない）
        - 要約表示: 候補を作った行／収まる候補が無かった行の件数が出る
        - キャッシュ再利用: バッチが作った候補を、1行ダイアログが再生成
          せずにそのまま表示する（ネットワーク呼び出しが増えない）
        - 鮮度: キャッシュ後に訳文を変えると、キャッシュは使われず、
          「候補を作る」を押すと実際に新しいジョブが飛ぶ
        - 適用失敗フォールバック: publication-apply が失敗（ジョブ紛失を
          模した404）したら、キャッシュを消し、「作り直す」で回復できる
          状態にする
        - 中断: 実行中に「中止」を押すと /api/cancel-translation が飛び、
          残りの行へは1件も進まない
      node/Playwright/Chromium が無い環境では UNMEASURED（exit 3）にする。

  突然変異の実証（このファイルの実行だけでは行わない。呼び出し側の手順で
  実施し、結果をログへ残す。CLAUDE.md「悪い結果が出たら、まず自分の道具を
  疑う」に合わせ、3種を用意する）:
    M1: runFitBatchStep の直列待ちを外して並行化 → serialOk が false へ落ちる
    M2: isFitBatchEligible から配置計画の条件を外す → 対象行数・除外検証が崩れる
    M3: fitBatchCacheEntry の訳文一致判定を外す（常にキャッシュを返す）→
        鮮度検証（編集後は非キャッシュ表示に戻ること）が崩れる

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9201BatchFit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$N9201Root = Split-Path -Parent $PSScriptRoot
$N9201Www = Join-Path $N9201Root 'www'
$script:N9201Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9201 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9201Failures.Add($Message) }
}

Write-Host 'Test-YakuV9201BatchFit'

# ============================================================ (a) 静的部
Write-Host '-- static --'

$N9201CatJsPath = Join-Path $N9201Www 'assets\cat.js'
$N9201CatHtmlPath = Join-Path $N9201Www 'cat.html'
$N9201CatJs = [IO.File]::ReadAllText($N9201CatJsPath, [Text.Encoding]::UTF8)
$N9201CatHtml = [IO.File]::ReadAllText($N9201CatHtmlPath, [Text.Encoding]::UTF8)

Assert-N9201 ($N9201CatJs.Contains('function isFitBatchEligible(segment)')) 'isFitBatchEligible（対象行の唯一の判定）が実在する'
Assert-N9201 ($N9201CatJs.Contains('function fitBatchTargets()')) 'fitBatchTargets（対象行の一覧）が実在する'
Assert-N9201 ($N9201CatJs.Contains('function computeFitBudget(segment)')) 'computeFitBudget（文字目標の共有算出）が実在する'
Assert-N9201 ($N9201CatJs.Contains('function requestFitCandidateJobStart(index, maxChars, destinationCount)')) 'requestFitCandidateJobStart（ジョブ起動の共有口）が実在する'
Assert-N9201 ($N9201CatJs.Contains('function pollFitCandidateJob(jobId, onTick)')) 'pollFitCandidateJob（キュー専用ポーラー、DOM非依存）が実在する'
Assert-N9201 ($N9201CatJs.Contains('function isJobRunningConflict(error)')) 'isJobRunningConflict（JOB_RUNNING検出）が実在する'
Assert-N9201 ($N9201CatJs -match "isJobRunningConflict[\s\S]{0,120}別の翻訳が実行中です") 'JOB_RUNNING検出はサーバの実際の応答文言（別の翻訳が実行中です）を拾う'

# 1行ダイアログ（generatePublicationCandidates）とキュー（runFitBatchStep）の
# 両方が、同じ computeFitBudget / requestFitCandidateJobStart を呼んでいること
# （純粋な抽出。二重実装していない）。
$N9201GenerateBody = [regex]::Match($N9201CatJs, '(?s)function generatePublicationCandidates\(\) \{(.*?)\n  \}')
Assert-N9201 $N9201GenerateBody.Success 'generatePublicationCandidates が実在する'
if ($N9201GenerateBody.Success) {
    $N9201GenerateText = $N9201GenerateBody.Groups[1].Value
    Assert-N9201 ($N9201GenerateText.Contains('computeFitBudget(segment)')) '1行ダイアログが computeFitBudget を呼ぶ'
    Assert-N9201 ($N9201GenerateText.Contains('requestFitCandidateJobStart(index, maxChars, destinationCount)')) '1行ダイアログが requestFitCandidateJobStart を呼ぶ'
}
$N9201StepBody = [regex]::Match($N9201CatJs, '(?s)function runFitBatchStep\(\) \{(.*?)\n  \}')
Assert-N9201 $N9201StepBody.Success 'runFitBatchStep が実在する'
if ($N9201StepBody.Success) {
    $N9201StepText = $N9201StepBody.Groups[1].Value
    Assert-N9201 ($N9201StepText.Contains('computeFitBudget(segment)')) 'キューが computeFitBudget を呼ぶ（1行ダイアログと同じ関数）'
    Assert-N9201 ($N9201StepText.Contains('requestFitCandidateJobStart(index, budget.maxChars, destinationCount)')) 'キューが requestFitCandidateJobStart を呼ぶ（1行ダイアログと同じ関数）'
    Assert-N9201 ($N9201StepText.Contains('runFitBatchStep();')) '前の行の完了後に自分自身を呼び直す（直列の形）'
}

# openFitPublicationFlow は変えていない（V9196がこの本体を固定する。ここでは
# 「まだ post( を含まない」ことだけ重ねて確認する。二重に固定しても壊れない）。
$N9201FlowBody = [regex]::Match($N9201CatJs, '(?s)function openFitPublicationFlow\(index\) \{(.*?)\n  \}')
Assert-N9201 $N9201FlowBody.Success 'openFitPublicationFlow が実在する（V9196と同じ本体）'
if ($N9201FlowBody.Success) { Assert-N9201 (-not $N9201FlowBody.Groups[1].Value.Contains('post(')) 'openFitPublicationFlow は新しい /api/cat/* を呼んでいない（V9196と同じ）' }

# 行の1クリック導線が isFitBatchEligible を使っていること（対象行の判定が
# 1箇所だけであることの裏付け）。
Assert-N9201 ($N9201CatJs.Contains('if (isFitBatchEligible(segment)) {') -and $N9201CatJs.Contains("data-cat-fit-candidates=")) '行のボタンの表示条件が isFitBatchEligible を使う'
Assert-N9201 ($N9201CatJs.Contains('return (project && project.segments || []).filter(isFitBatchEligible);')) 'fitBatchTargets が isFitBatchEligible だけで絞る（判定を2つに増やさない）'

# busy中はまとめて収めるボタンも翻訳中と同じ歯止めに乗る（V9196が固定する
# busyゲートの1行へ追記する形。この行自体はV9196側でも別途確認される）。
Assert-N9201 ($N9201CatJs -match "busy && \(button\.id === 'cat-confirm-bulk' \|\| button\.id === 'cat-fit-batch-open'") 'busy中は「まとめて収める」ボタンも止まる'
Assert-N9201 ($N9201CatJs.Contains("if (button.id === 'cat-fit-batch-open') return openFitBatchDialog();")) 'ボタンの配線が既存のクリック委譲に乗っている'

# キャッシュの鮮度判定（Ordinal一致）。JSの === は元々Ordinal相当。
$N9201CacheEntryBody = [regex]::Match($N9201CatJs, '(?s)function fitBatchCacheEntry\(segment\) \{(.*?)\n  \}')
Assert-N9201 $N9201CacheEntryBody.Success 'fitBatchCacheEntry が実在する'
if ($N9201CacheEntryBody.Success) {
    Assert-N9201 ($N9201CacheEntryBody.Groups[1].Value.Contains("String(segment.translation || '') !== entry.translationAtGeneration")) 'キャッシュは訳文の完全一致(===)だけで有効性を見る'
}
Assert-N9201 ($N9201CatJs.Contains("{ jobId: jobId, candidateSet: candidateSet || null, revisionAtGeneration: revision(), translationAtGeneration: String(segment.translation || '') }")) 'キャッシュのエントリ形が {jobId,candidateSet,revisionAtGeneration,translationAtGeneration} と一致する'

# 実装前調査の記録（サーバ側に永続化は無いこと）がコードにも残っていること。
Assert-N9201 ($N9201CatJs -match 'YakuTranslateJobRetentionMinutes = 30' -or $N9201CatJs -match '既定30分で失効') 'サーバ側に永続化が無いことの根拠がコメントに残っている'

# 適用失敗フォールバック（決定4）。
$N9201ApplyBody = [regex]::Match($N9201CatJs, '(?s)function applyPublicationCandidate\(candidateId\) \{(.*?)\n  \}')
Assert-N9201 $N9201ApplyBody.Success 'applyPublicationCandidate が実在する'
if ($N9201ApplyBody.Success) {
    $N9201ApplyText = $N9201ApplyBody.Groups[1].Value
    Assert-N9201 ($N9201ApplyText.Contains('delete fitBatchCandidateCache[String(segment.segment_id)];')) '適用失敗でキャッシュを消す'
    Assert-N9201 ($N9201ApplyText -match "regenerateButton\.hidden = false") '適用失敗で「作り直す」を出す'
}

# まとめて適用（自動適用）は作らない: publication-apply へ複数candidateを
# 一括で送る新しい経路が無いこと（呼ぶのは1件ずつの applyPublicationCandidate
# だけ）。
Assert-N9201 (([regex]::Matches($N9201CatJs, "post\('publication-apply'")).Count -eq 1) 'publication-apply を呼ぶ箇所は1つだけ（まとめて適用を作っていない）'

# HTML側の骨組み。
Assert-N9201 ($N9201CatHtml.Contains('id="cat-fit-batch-open"')) 'トグルボタンがcat.htmlにある'
Assert-N9201 ($N9201CatHtml.Contains('id="cat-fit-batch-dialog"')) '確認・進捗ダイアログがcat.htmlにある'
Assert-N9201 ($N9201CatHtml.Contains('id="cat-publication-regenerate"')) '作り直すボタンがcat.htmlにある'

# ============================================================ (b) 実機Chromium部
Write-Host '-- chromium --'

$YAKU_BATCHFIT_UNMEASURED = 3
$N9201Driver = Join-Path $PSScriptRoot 'batch-fit\batch-fit-gate.js'
$N9201Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $N9201Node -or -not (Test-Path -LiteralPath $N9201Driver -PathType Leaf)) {
    Write-Host 'UNMEASURED: node または Chromium 運転席が無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9201Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9201Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_BATCHFIT_UNMEASURED
}
$N9201NodeExe = [string]$N9201Node.Source
$N9201ProbeDir = (Split-Path -Parent $N9201Driver).Replace('\', '/')
$null = & $N9201NodeExe -e ("try{require.resolve('playwright',{paths:['" + $N9201ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9201Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9201Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_BATCHFIT_UNMEASURED
}
$N9201ChromiumPath = & $N9201NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $N9201ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
$N9201ChromiumExit = $LASTEXITCODE
if ($N9201ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$N9201ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$N9201ChromiumPath) -PathType Leaf)) {
    Write-Host 'UNMEASURED: Playwright Chromium 実行ファイルが無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9201Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9201Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_BATCHFIT_UNMEASURED
}

$N9201Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9201-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $N9201Work -Force
$N9201OutJson = Join-Path $N9201Work 'out.json'

& $N9201NodeExe $N9201Driver $N9201Www $N9201OutJson
$N9201DriverExit = $LASTEXITCODE
Assert-N9201 ($N9201DriverExit -eq 0 -and (Test-Path -LiteralPath $N9201OutJson -PathType Leaf)) 'headless Chromium が実際の CAT 画面を開き、運転席が最後まで走った'

$N9201Result = $null
if (Test-Path -LiteralPath $N9201OutJson -PathType Leaf) { $N9201Result = [IO.File]::ReadAllText($N9201OutJson, [Text.Encoding]::UTF8) | ConvertFrom-Json }
if ($null -ne $N9201Result) {
    foreach ($e in @($N9201Result.errors)) { Write-Host ('  Chromium error: ' + [string]$e) -ForegroundColor Red }
    if ($N9201Result.fatal) { Write-Host ('  Chromium fatal: ' + [string]$N9201Result.fatal) -ForegroundColor Red }
}
# console は見ない: この題材はJOB_RUNNING(400)・publication-apply失敗(404)を
# わざと起こすので、失敗したリソース読み込みのconsoleエラーが出るのは想定内
# （V9196の「エラー0件」規約とは前提が違う）。実際のJS例外(errors)とfatalだけを見る。
Assert-N9201 ($null -ne $N9201Result -and @($N9201Result.errors).Count -eq 0 -and -not $N9201Result.fatal) '画面でJavaScript例外が出ていない（fatalも無い）'

if ($null -ne $N9201Result) {
    # --- 対象行の選定・件数表示 ---
    Assert-N9201 (-not [bool]$N9201Result.toolbarButton.hidden) '対象行が1件以上あるのでボタンが自動で現れる'
    Assert-N9201 ([string]$N9201Result.toolbarButton.text -match '4行') ('ボタンの件数は4行（実測: ' + [string]$N9201Result.toolbarButton.text + '）')
    Assert-N9201 ([string]$N9201Result.confirmText -match '4行の短縮候補を順番に作ります。Copilotを4回呼びます。') ('確認文の文言・件数（実測: ' + [string]$N9201Result.confirmText + '）')
    Assert-N9201 (-not [bool]$N9201Result.index4Called) '配置計画の無い行(index=4)はまとめて収めるの対象から外れる(1件も呼ばれない)'
    Assert-N9201 (-not [bool]$N9201Result.index5Called) 'fitリスクの無い行(index=5)は対象から外れる'

    # --- 直列性 ---
    Assert-N9201 ([bool]$N9201Result.serialOk) ('同時に2ジョブ投げていない(直列)。問題: ' + (($N9201Result.serialProblems) -join ' / '))

    # --- JOB_RUNNINGリトライ ---
    Assert-N9201 ([int]$N9201Result.index1Attempts -eq 2) ('JOB_RUNNING(1回目)のあと、同じ行へ黙って再試行して2回目で成功する(実測 ' + [string]$N9201Result.index1Attempts + '回)')

    # --- max_chars: 行ごとの実幅由来値(固定値でも0.8倍フォールバックでもない) ---
    Assert-N9201 ($null -ne $N9201Result.maxCharsIdx0 -and $null -ne $N9201Result.maxCharsIdx3) 'max_chars を送っている行が2つとも観測できた'
    if ($null -ne $N9201Result.maxCharsIdx0 -and $null -ne $N9201Result.maxCharsIdx3) {
        Assert-N9201 ([int]$N9201Result.maxCharsIdx0 -ne [int]$N9201Result.maxCharsIdx3) ('列幅が違う2行のmax_charsが異なる値になる(実測 idx0=' + [string]$N9201Result.maxCharsIdx0 + ' / idx3=' + [string]$N9201Result.maxCharsIdx3 + ')')
        Assert-N9201 ([int]$N9201Result.maxCharsIdx0 -ge 8 -and [int]$N9201Result.maxCharsIdx0 -le 99) 'idx0のmax_charsはサーバの使える窓[8,99]の中'
        Assert-N9201 ([int]$N9201Result.maxCharsIdx3 -ge 8 -and [int]$N9201Result.maxCharsIdx3 -le 99) 'idx3のmax_charsはサーバの使える窓[8,99]の中'
        Assert-N9201 ([int]$N9201Result.maxCharsIdx0 -ne 20 -and [int]$N9201Result.maxCharsIdx3 -ne 20) '従来の20字下限フォールバック値ではない(実測由来である裏付け)'
    }

    # --- 要約表示 ---
    Assert-N9201 ([bool]$N9201Result.batchFinished) 'キューが最後まで走り、要約が表示される'
    Assert-N9201 ([string]$N9201Result.summaryText -match '候補を作った行: 3件') ('要約: 候補を作った行3件(idx0,1,3。実測: ' + [string]$N9201Result.summaryText + ')')
    Assert-N9201 ([string]$N9201Result.summaryText -match '収まる候補が無かった行: 1件') '要約: 収まる候補が無かった行1件(idx2)'

    # --- キャッシュ再利用(idx0) ---
    Assert-N9201 ([int]$N9201Result.callsDuringCacheOpen -eq 0) 'バッチが作った候補は、1行ダイアログを開いても再生成の通信をしない'
    Assert-N9201 ([string]$N9201Result.cacheServed.statusText -match '「まとめて収める」で作成済みの候補です') 'キャッシュ由来であることを状態行が明示する'
    Assert-N9201 ([bool]$N9201Result.cacheServed.generateHidden) 'キャッシュ表示中は「候補を作る」を隠す'
    Assert-N9201 (-not [bool]$N9201Result.cacheServed.regenerateHidden) 'キャッシュ表示中は「作り直す」を出す'
    Assert-N9201 ([int]$N9201Result.cacheServed.candidateCount -eq 1) 'キャッシュの候補カードが実際に描かれる'

    # --- 鮮度(idx0を編集) ---
    Assert-N9201 ([bool]$N9201Result.segmentCommitObserved) '訳文の編集がサーバへ保存された(前提が空振りでないこと)'
    Assert-N9201 (-not [bool]$N9201Result.freshnessAfterEdit.generateHidden) '訳文を変えた後は「候補を作る」に戻る(キャッシュを出さない)'
    Assert-N9201 ([bool]$N9201Result.freshnessAfterEdit.regenerateHidden) '訳文を変えた後は「作り直す」を出さない(キャッシュ表示ではない)'
    Assert-N9201 ([int]$N9201Result.freshnessAfterEdit.candidateCount -eq 0) '訳文を変えた後は古い候補カードを出さない'
    Assert-N9201 ([bool]$N9201Result.freshRegenerateCallObserved) '「候補を作る」を押すと実際に新しいジョブが飛ぶ(空振りのボタンではない)'

    # --- 適用失敗フォールバック(idx3) ---
    Assert-N9201 ([bool]$N9201Result.idx3ServedFromCache) 'idx3もキャッシュから開けている(前提)'
    Assert-N9201 ([bool]$N9201Result.applyFailureObserved) '適用が実際にサーバへ送られ、失敗を観測できた'
    Assert-N9201 ([string]$N9201Result.afterApplyFailure.statusText -match 'この候補の作成記録が見つかりません') '適用失敗のエラーがそのまま状態行に出る'
    Assert-N9201 (-not [bool]$N9201Result.afterApplyFailure.regenerateHidden) '適用失敗後は「作り直す」で回復できる状態になる'
    Assert-N9201 (-not [bool]$N9201Result.idx3AfterFailureReopen.generateHidden) '適用失敗後、キャッシュは消えている(再度開くと「候補を作る」に戻る)'
    Assert-N9201 ([bool]$N9201Result.idx3AfterFailureReopen.regenerateHidden) '適用失敗後、再度開いても「作り直す」は出ない(もうキャッシュ扱いではない)'

    # --- 中断 ---
    Assert-N9201 ([bool]$N9201Result.abortCancelObserved) '中止を押すと /api/cancel-translation が飛ぶ'
    Assert-N9201 ([bool]$N9201Result.abortFinished) '中止後に要約表示へ落ち着く(画面が壊れない)'
    Assert-N9201 ([string]$N9201Result.abortSummaryText -match '中断しました') '要約が中断したことを言う'
    Assert-N9201 ([int]$N9201Result.projectBCalls -eq 1) ('中止後、残りの行へは1件も進まない(実測 呼ばれた行数=' + [string]$N9201Result.projectBCalls + ')')
}

try { Remove-Item -LiteralPath $N9201Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ''
if ($script:N9201Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9201BatchFit'
    exit 0
}
Write-Host ("FAIL " + $script:N9201Failures.Count + ' assertion(s)')
foreach ($f in @($script:N9201Failures)) { Write-Host ('  - ' + $f) }
exit 1
