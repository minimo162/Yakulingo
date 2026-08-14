<#
.SYNOPSIS
  V91.64 dual-experience contract regression.

.DESCRIPTION
  もとは Quick/CAT の分離と一時 artifact の受け渡しを固定するための契約だった。
  分離は 2026-08-11 に、その場で訳す状態そのものは 2026-08-13 に取り消されたので、
  いま残っているのは「入口は1つ」「向きは送る前に決める」「数値保護は必ず通る」
  「機械キャッシュを跨がない」といった、廃止に依らない不変条件のほうである。
  Production files are read or invoked, but never modified by this test.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT = '1'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$srcRoot = Join-Path $root 'src'
$wwwRoot = Join-Path $root 'www'
$script:failed = 0

function Check-YakuDual {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

function Read-YakuDualText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($Path)
}

function Get-YakuDualSlice {
    param([string]$Text, [string]$Start, [string]$End)
    $a = $Text.IndexOf($Start, [StringComparison]::Ordinal)
    if ($a -lt 0) { return '' }
    $b = $Text.IndexOf($End, $a + $Start.Length, [StringComparison]::Ordinal)
    if ($b -lt 0) { return $Text.Substring($a) }
    return $Text.Substring($a, $b - $a)
}

$serverPath = Join-Path $srcRoot 'Server.ps1'
$translationPath = Join-Path $srcRoot 'Translation.ps1'
$catBatchPath = Join-Path $srcRoot 'CatBatch.ps1'
$catProjectPath = Join-Path $srcRoot 'CatProject.ps1'
$translationMemoryPath = Join-Path $srcRoot 'TranslationMemory.ps1'
$htmlPath = Join-Path $srcRoot 'Html.ps1'
$quickPagePath = Join-Path $wwwRoot 'cat.html'
$catPagePath = Join-Path $wwwRoot 'cat.html'
$assetsRoot = Join-Path $wwwRoot 'assets'
$quickClientPath = Join-Path $assetsRoot 'quick.js'
$catClientPath = Join-Path $assetsRoot 'cat.js'
$catWorkspaceStylePath = Join-Path $assetsRoot 'cat-workspace.css'

$server = Read-YakuDualText $serverPath
$translationSource = Read-YakuDualText $translationPath
$catBatchSource = Read-YakuDualText $catBatchPath
$catProjectSource = Read-YakuDualText $catProjectPath
$translationMemorySource = Read-YakuDualText $translationMemoryPath
$rendererSource = Read-YakuDualText $htmlPath
$quickPage = Read-YakuDualText $quickPagePath
$catPage = Read-YakuDualText $catPagePath
$quickClient = Read-YakuDualText $quickClientPath
$catClient = Read-YakuDualText $catClientPath
$catWorkspaceStyle = Read-YakuDualText $catWorkspaceStylePath
$client = $quickClient + "`n" + $catClient

Write-Host 'Single launch, landing, and DOM separation' -ForegroundColor Cyan
Check-YakuDual (($server -split '\[System\.Net\.HttpListener\]::new\(\)').Count -eq 2) 'one listener instance serves both experiences'
Check-YakuDual ($server -match '(?i)[\x22\x27]?/quick[\x22\x27]?' -and $server -match '(?i)[\x22\x27]?/cat[\x22\x27]?') 'server exposes /quick and /cat from the same launch'
# 2026-08-12: 選ばせる開始画面を削除し、起動直後に翻訳画面へ着地させる。
Check-YakuDual (-not (Test-Path -LiteralPath (Join-Path $wwwRoot 'index.html'))) 'no separate landing screen stands between launch and translating'
Check-YakuDual ($catPage.Contains('id="quick-input"')) 'the screen the launcher opens contains the paste box itself'
# 2026-08-11 に利用者判断で画面を一つにした（「画面を一つにするのでokです」）。
# 分かれているのは DOM ではなく状態になったので、検査もそちらへ移す。守るべき
# ものは変わらない: その場で訳す状態は保存しない、確認作業と同時には出ない、
# /quick から来ても同じ画面が出る。
Check-YakuDual (-not (Test-Path -LiteralPath (Join-Path $wwwRoot 'quick.html'))) 'the separate Quick page is gone'
Check-YakuDual (Test-Path -LiteralPath $catPagePath -PathType Leaf) 'the single translation page exists'
Check-YakuDual ($catPage -match '<body[^>]+class\s*=\s*[\x22\x27][^\x22\x27]*app-cat') 'the single page keeps one body class'
Check-YakuDual ($catPage -match 'id\s*=\s*[\x22\x27]cat-picker[\x22\x27]' -and $catPage -match 'id\s*=\s*[\x22\x27]cat-instant[\x22\x27]' -and $catPage -match 'id\s*=\s*[\x22\x27]cat-workspace[\x22\x27]') 'the single page holds all three states'
# 2026-08-12: 状態を3つ→2つにした。貼り付け欄は「別の状態」ではなく、始める画面の
# 中身になった。以前は押すと画面ごと入れ替わり、画面を一つにしたと言いながら
# 実際は入れ替えていただけだった（利用者の指摘）。
Check-YakuDual ($catPage -notmatch 'id="cat-instant"[^>]*\shidden') 'the paste box is part of the start view, not a separate state'
# 2026-08-13 に帯（タブ）を足し、同じ日に外した。貼り付けた文章も資料と同じ
# 確認作業になったので、切り替える相手そのものが無くなったため（利用者判断
# 「保存しない約束は要らない」）。08-12 の指摘「入れ替わったことが画面に出ない」は、
# 資料を開いたら資料名が出て、そこから一覧に戻れることで満たす。
$catCssText = Get-Content -LiteralPath (Join-Path $wwwRoot 'assets\cat-workspace.css') -Raw -Encoding UTF8
Check-YakuDual ($catPage -notmatch 'class="cat-tabs"' -and $catCssText -notmatch 'data-cat-tab=') 'no tab bar is left behind once there is nothing to switch between'
Check-YakuDual ($catPage -match 'id="cat-doc-dialog-paste"') 'a new paste can still be started while a document is open'
Check-YakuDual ($catPage -match 'id="cat-workspace"[^>]*\shidden') 'the review workspace stays hidden until a document is open'
Check-YakuDual ($catClient -notmatch 'hideInstant' -and $catClient -notmatch 'yaku-instant-close') 'the swap between the paste box and the picker is gone'
Check-YakuDual ($catClient -match "setView\('start'\)" -and $catClient -match "setView\('workspace'\)") 'the screen names only the two states it still has'
# 短いメールは保存しない訳、あとで続ける文章は確認作業へ進む。同じ貼り付け欄で
# 明示的に選び、既定は保存しない。
Check-YakuDual ($quickClient -match "post\('/api/quick/jobs'" -and $quickClient -match '/api/cat/open') '貼り付け欄は保存しない訳と確認作業を明示して分ける'
Check-YakuDual ($catPage -match 'id="quick-save-work"' -and $catPage -match '作業や翻訳メモリには残しません') '保存の有無を送る前に読める'
Check-YakuDual ($catClient -notmatch '/api/quick/') '確認画面は貼り付け側のAPIを呼ばない'

Write-Host 'Load production helpers for dynamic contracts' -ForegroundColor Cyan
foreach ($name in @(
    'Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1',
    'CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1',
    'CorpusReference.ps1','CellSegments.ps1','CellAlign.ps1','TranslationMemory.ps1','CatProject.ps1'
)) {
    $path = Join-Path $srcRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { . $path }
}

Write-Host 'Low-confidence direction is stopped before transport' -ForegroundColor Cyan
$lowText = -join @([char]0x5229,[char]0x76CA) # two-kanji heading
$decision = Resolve-YakuDirectionDecision -Text $lowText -Intent auto
Check-YakuDual ([bool]$decision.RequiresConfirmation -and [string]::IsNullOrWhiteSpace([string]$decision.Resolved)) 'low-confidence direction is unresolved'
$simulatedTransportCalls = 0
if (-not [bool]$decision.RequiresConfirmation) { $simulatedTransportCalls++ }
Check-YakuDual ($simulatedTransportCalls -eq 0) 'low-confidence decision produces zero transport calls'
# 向きを決める門は /api/cat/open へ移った（2026-08-13）。貼り付けた文章も資料も
# 同じ口を通るので、門も1つで足りる。順序は変わらない: 決まってから仕事を始める。
$textRoute = Get-YakuDualSlice -Text $server -Start "if (`$action -eq 'open')" -End "if (`$action -eq 'translate')"
$directionGateAt = $textRoute.IndexOf('RequiresConfirmation', [StringComparison]::Ordinal)
$projectAt = $textRoute.IndexOf('New-YakuCatTextProject', [StringComparison]::Ordinal)
Check-YakuDual ($directionGateAt -ge 0 -and $projectAt -gt $directionGateAt) 'the single open route gates direction before it creates work'
Check-YakuDual ($quickClient -notmatch 'function\s+analysis\s*\(|YakuZhSimplifiedChars|YAKU_ZH_ONLY' -and $quickClient -match "direction_intent:\s*explicitDirection\s*\|\|\s*'auto'") 'browser delegates automatic direction decisions to the single server classifier'
$noLanguage = Resolve-YakuDirectionDecision -Text '123' -Intent auto
Check-YakuDual ([bool]$noLanguage.RequiresConfirmation -and [string]::IsNullOrWhiteSpace([string]$noLanguage.Resolved)) 'numeric-only input is stopped for confirmation before transport'

# 「その場で訳す」は保存せず、用語集も過去訳も引かない、という契約を固定していた節を
# ここから外した（2026-08-13、利用者判断「保存しない約束は要らない」）。契約の対象が
# 無くなったのであって、緩めたのではない。貼り付けた文章は資料と同じ道を通るので、
# 保存も用語集も過去訳も、資料と同じに効く。残す不変条件は「一時の店を持たない」。
Check-YakuDual (-not (Test-Path -LiteralPath (Join-Path $srcRoot 'QuickArtifact.ps1'))) 'no ephemeral artifact store is left behind'
Check-YakuDual ($server -notmatch 'QuickArtifact' -and $server -notmatch "path -eq '/api/cat/promote'") 'the server keeps no route that can only feed the removed store'
Check-YakuDual ($server -match "\[ValidateSet\('text','quick','revise','shorten','cat'\)\]\[string\]\`$Kind" -and $server -match "-Kind 'quick' -CachePolicy 'none' -ReferencePolicy 'none'") 'the quick job kind is reachable and explicitly disables stored reuse'

Write-Host 'Reuse in CAT stays opt-in' -ForegroundColor Cyan
Check-YakuDual (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'app.js')) -and $rendererSource -notmatch 'data-yaku-to-cat|data-yaku-shorten') 'legacy shared UI and DOM/base64 handoff are removed'
$catTranslateRoute = Get-YakuDualSlice -Text $server -Start "'translate' {" -End "'apply' {"
Check-YakuDual ($catTranslateRoute -notmatch '(?i)CorpusSection|CorpusExamples|PastPairs|ReferenceUsage') 'CAT translation request does not automatically inject a past example'

Write-Host 'CAT candidate provenance and explicit reference use' -ForegroundColor Cyan
$candidateRoute = Get-YakuDualSlice -Text $server -Start "'candidates' {" -End "'glossary-add' {"
Check-YakuDual ($candidateRoute -match '(?i)source_name' -and $candidateRoute -match '(?i)location' -and $candidateRoute -match '(?i)page' -and $candidateRoute -match '(?i)source_match_ratio' -and $candidateRoute -match '(?i)source' -and $candidateRoute -match '(?i)translation') 'candidate API returns normalized material, location, page, source, translation, and match basis'
Check-YakuDual ($translationMemorySource -match '(?i)origin_project_id' -and $translationMemorySource -match '(?i)origin_file_name' -and $translationMemorySource -match '(?i)origin_segment_id' -and $translationMemorySource -match '(?i)origin_location' -and $translationMemorySource -match '(?i)review_revision') 'self-confirmed translation persists its project, material, segment, location, and review revision'
Check-YakuDual ($translationMemorySource -match '(?i)source_hash' -and $translationMemorySource -match '(?i)target_hash' -and $translationMemorySource -match 'Test-YakuTranslationMemoryProvenance') 'self-confirmed candidate is content-bound and provenance-validated'
Check-YakuDual ($catClient -match '(?i)item\.source_name' -and $catClient -match '(?i)item\.location' -and $catClient -match '(?i)item\.page' -and $catClient -match 'item\.source' -and $catClient -match 'item\.translation') 'CAT candidate UI displays normalized material, location, page, source, and translation'
Check-YakuDual ($candidateRoute -notmatch 'Get-YakuCorpusSearchDir|Find-YakuCorpusPairs' -and $catClient -notmatch "item\.kind === 'corpus'") 'CAT candidates cannot revive a bundled or cached corpus'
Check-YakuDual ($catClient -match '(?i)reference_usage' -and $catClient -match '(?i)reference_id' -and $catClient -match '(?i)data-cat-reference-id') 'candidate insertion sends reference_id and displays reference_usage'
Check-YakuDual ($catClient -match "function renderRows\(\)[\s\S]*?el\('cat-candidates'\)\.hidden = true") 'candidate panel closes when its row leaves the current grid'
Check-YakuDual ($candidateRoute -match '(?i)reference_id' -and $server -match '(?i)Set-YakuCatSegmentReferenceUsage' -and $catProjectSource -match '(?i)ReferenceUsage') 'server persists reference_usage through the explicit segment mutation'
$activeUi = $quickPage + "`n" + $catPage + "`n" + $client
Check-YakuDual ($activeUi -notmatch '(?i)(?:quality|translation|\u8a33|\u516c\u8868|\u78ba\u8a8d)[^\r\n]{0,40}100\s*[%\uff05]') 'active UI never presents 100 percent as translation quality'

Write-Host 'CAT client state and keyboard regression' -ForegroundColor Cyan
Check-YakuDual ($catClient -match 'scopeIsCurrent\(packet\.scope, true\)' -and $catClient -match 'data-cat-project-id' -and $catClient -match 'expected_revision') 'late saves stay bound to the starting project and revision'
Check-YakuDual ($catClient -match 'deleteTarget = currentScope\(\)' -and $catClient -match "post\('delete', \{ id: target\.id \}, true, target\)") 'delete confirmation stays bound to its displayed project'
Check-YakuDual ($catClient -match "type: 'translate', scope: jobScope" -and $catClient -match "post\('apply', \{ job_id: jobId \}, true, context\.scope\)") 'job apply stays bound to its starting project and revision'
Check-YakuDual ($catClient -match "event\.key === 'Enter'" -and $catClient -match '処理中は確認できません' -and $catClient -match 'function focusAfter\(index\)') 'Ctrl+Enter is guarded while busy and advances after confirmation'
# 2026-08-13: ドロップ先は取り込みボタン自身になった（枠を1つ減らした）。
Check-YakuDual ($catClient -match "bindFileDrop\(el\('cat-open-file-entry'\), el\('cat-file-input'\)\)" -and $catClient -match "event\.key === 'Enter' \|\| event\.key === ' '") 'file drop supports drag-drop and keyboard activation'
Check-YakuDual ($catClient -match 'data-cat-loss' -and $catClient -match 'この行と次の行をつなげて1文にします。' -and $catClient -match 'つなげた行を元の2行に戻します。' -and ([regex]::Matches($catClient, '消えた訳文は元に戻せません').Count -ge 2)) 'merge and split warn before discarding a translation'
Check-YakuDual ($catClient -match 'data\.review_blocked' -and $catClient -match 'var same = document\.querySelector') 'QC-blocked confirmation returns focus to the same row'
Check-YakuDual ($catClient -match 'function redrawAfterFlush\(\)[\s\S]*?return flush\(\)\.then' -and $catClient -match "button\.hasAttribute\('data-cat-filter'\)[\s\S]{0,180}redrawAfterFlush\(\)") 'filter redraw waits for the shared save barrier'

Write-Host 'CAT H1 focused workspace contract' -ForegroundColor Cyan
Check-YakuDual ($catPage -match 'cat-workspace\.css' -and $catPage -match 'id="cat-editor-toolbar"' -and $catPage -match 'id="cat-editor-pane"' -and $catPage -match 'id="cat-inspector-pane"') 'CAT uses one WebView workspace with a sticky toolbar and named regions'
# 2026-08-12: 左の絞り込み列を廃止し、帯を表の上へ移した。右の参考情報は畳める。
Check-YakuDual ($catWorkspaceStyle -match '(?s)\.cat-editor-toolbar\s*\{[^}]*position:\s*sticky' -and $catWorkspaceStyle -match 'grid-template-columns:\s*minmax\(0,\s*1fr\)\s+var\(--pane-inspector\)' -and $catWorkspaceStyle -match '--pane-inspector:\s*clamp\(' -and $catWorkspaceStyle -match '\.cat-editor-layout\.is-inspector-hidden' -and $catWorkspaceStyle -notmatch '--pane-nav') 'desktop CAT workspace filters above the grid and can fold the reference pane'
# ツールバーは行数が3桁（200行など）になっても壊れてはいけない。実測（窓1380px）で
# 2つの壊れ方を踏んだ。1つは進捗が min-width: 0 で枠より小さくなり検索欄の上へ
# 重なる。もう1つは使う量の1文がボタンと同じ列で幅を奪い、列の合計が 1,460px と
# なって「そのほか」が画面外へ出る。どちらも「省略する当てが無いものを潰した」形。
Check-YakuDual ($catWorkspaceStyle -match '(?s)\.cat-toolbar-progress\s*\{[^}]*min-width:\s*max-content') 'toolbar progress must not be squeezed below its own text'
Check-YakuDual ($catWorkspaceStyle -notmatch '(?s)\.cat-toolbar-document,\s*\r?\n?\.cat-toolbar-progress\s*\{[^}]*min-width:\s*0') 'the shrink rule must not be shared with the progress cell'
# 2026-08-12: 使う量の1文は画面から外した（押す前に読んでも判断が変わらない）。
# 画面に出す情報を減らす（2026-08-12、利用者の指摘「不要な情報が多すぎて必要な情報が
# 紛れてしまっている」）。数えたら、4セルの資料で「要対応4 / 未翻訳4 / 未確認4」と
# 同じ数字が3つ並んでいた（actionable = 未確認 or 点検の指摘、未翻訳 ⊂ 未確認）。
# 2026-08-12（同日追記）: 数を4つに縛っていたが、縛るべきは数ではなく意味だった。
# 「同じ原文」は状態ではなく資料の性質で、ほかのどれとも重ならない。点検の指摘と
# 同じく、当てはまる行が無い資料では出さない。数えるのは「意味の重なり」のほう。
$catFilterNames = @([regex]::Matches($catPage, 'data-cat-filter="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value })
$allowedFilters = @('actionable','qc','repetition','reviewed','all')
Check-YakuDual (@($catFilterNames | Where-Object { $allowedFilters -notcontains $_ }).Count -eq 0) 'the row filter must only offer the agreed entries'
# 未翻訳 ⊂ 未確認 ⊂ 要対応。同じ数字が並ぶので、この3つは並べない。
Check-YakuDual (@($catFilterNames | Where-Object { @('untranslated','unconfirmed') -contains $_ }).Count -eq 0) 'overlapping state filters must stay removed'
# 例外の入口は、当てはまる行が無いときに出さない（既定で hidden）。
Check-YakuDual ($catPage -match 'data-cat-filter="qc"[^>]*hidden' -and $catPage -match 'data-cat-filter="repetition"[^>]*hidden') 'exception filters must be hidden until they have rows'
Check-YakuDual ($catPage -notmatch 'data-cat-filter="untranslated"' -and $catPage -notmatch 'data-cat-filter="unconfirmed"') 'filters that always duplicate each other are gone'
Check-YakuDual ($catPage -match 'data-cat-filter="qc"[^>]*hidden' -and $catClient -match 'qcFilter\.hidden = counts\.qc < 1') 'the exception filter stays hidden while there is nothing to see'
Check-YakuDual (@([regex]::Matches($catWorkspaceStyle, 'cat-state-filters button\[data-cat-filter=')).Count -le 3) 'the filter colour bands must stay within three meanings'
# 場所は「選べる」ときだけ出す。1種類しかなければ、すべての場所と同じものを指す。
Check-YakuDual ($catClient -match 'locationNames\.length < 2') 'the location list hides itself when it offers no choice'
# セルはシートでまとめる。番地まで見ると1セル1グループになり、500セルで500個並ぶ。
Check-YakuDual ($catClient -match "location\.match\(/\^\(\.\*\?\)\\s\*\[!,\]") 'cells group by sheet, accepting both separators'
# 言い切って終わる。同じ注意を重ねない。
Check-YakuDual ($catPage -match '<strong>すべての行を確認し終えました</strong></div>') 'the completion line does not carry a second caveat'
# 出す文言の検査なので、注釈は外してから見る。消した文言を注釈で説明していると、
# 自分の説明に引っかかって落ちる（2026-08-12 に実際に落ちた）。
$catClientCode = [regex]::Replace($catClient, '(?s)/\*.*?\*/', '')
Check-YakuDual ($catClientCode -notmatch '原文が似ているというだけです' -and $catClientCode -notmatch 'ページ情報なし' -and $catClientCode -notmatch '文書内の場所情報なし') 'reference cards drop the restated caveat and the empty-field placeholders'
# 2026-08-12: 全行確認をファイル作成の条件から外した（memoQ・Phrase・Trados は
# どれも「書き出す」と「完了にする」を分けている）。緩めた以上、未確認が何行
# あるかは押す前の画面とファイルの中の両方に必ず出す。
Check-YakuDual ($server -match 'unconfirmed_count = \[int\]\$preflight\.UnconfirmedCount') 'the preflight reports how many rows are still unconfirmed'
Check-YakuDual ($catClient -match 'data\.unconfirmed_count') 'the confirm dialog reads that count instead of assuming everything is confirmed'
# 出す文言の検査なので注釈は外してから見る（消した文言を注釈で説明しているため）。
Check-YakuDual (([regex]::Replace($catClient, '(?s)/\*.*?\*/', '')) -notmatch '確認済みの内容を出力できます') 'the dialog no longer claims the output is fully reviewed'
$catProjectSrc = Read-YakuDualText (Join-Path $srcRoot 'CatProject.ps1')
Check-YakuDual ($catProjectSrc -match "segment-qc-failed") 'a row failing the numeric check still blocks the file'
Check-YakuDual ($catProjectSrc -match 'Copy-YakuCatProjectSegmentForProbe') 'unconfirmed rows are checked on a copy so the work is not altered'
$wordSrc = Read-YakuDualText (Join-Path $srcRoot 'WordAdapter.ps1')
# 2026-08-12: 進み具合はファイルへ書かない（利用者の指摘「ファイルに出したら
# 完成品にならないのでは」）。ファイルに残すのは DRAFT の帯だけで、未確認の数は
# 画面と出力前の確認に出す。
Check-YakuDual ($wordSrc -notmatch '未確認 .*行を含む' -and $wordSrc -match 'DRAFT — YakuLingo') 'the produced file carries the DRAFT mark but not the working progress'
Check-YakuDual ($catClient -match "activeSegmentId\s*=\s*''" -and $catClient -match 'data-cat-segment-id' -and $catClient -match 'String\(segment\.segment_id') 'active row survives redraws by stable segment_id'
Check-YakuDual ($catClient -match "esc\(segment\.location \|\| '本文'\)" -and $catClient -match 'function locationGroup\(segment\)') 'rows display the actual source location and navigation groups it locally'
Check-YakuDual ($catClient -match 'cat-candidate-number' -and $catClient -match 'itemIndex \+ 1' -and $catClient -match 'data-cat-reference-id') 'numbered candidate controls preserve explicit reference insertion'
Check-YakuDual ($catClient -match 'event\.isComposing' -and $catClient -match "event\.key === 'ArrowUp'" -and $catClient -match "event\.key\.toLowerCase\(\) === 'f'") 'keyboard navigation is IME-safe and exposes confirm, movement, candidate, and search paths'
Check-YakuDual ($catClient -match "currentFilter = 'all'" -and $catPage -match 'id="cat-complete-state"') 'completed projects show reviewed rows instead of an empty default grid'
Check-YakuDual ($catPage -match 'id="cat-export-dialog"' -and $catClient -match "post\('preflight', \{\}, true, requestScope\)" -and $catClient -match 'data\.project_id' -and $catClient -match 'Number\(data\.revision\) !== requestScope\.revision') 'DRAFT dialog uses the server preflight bound to the current project revision'
Check-YakuDual ($catPage -match 'data-cat-change="unchanged"' -and $catPage -match 'data-cat-change="changed"' -and $catPage -match 'data-cat-change="new"' -and $catClient -match 'changeGroup\(segment\)' -and $catClient -match 'segment\.prior_source') '3-way workspace exposes prior-same, changed, and new counts with previous/current context'
Check-YakuDual ($catClient -match 'data-cat-shorten' -and $catClient -match '修正結果を確認' -and $catClient -match 'data-cat-revert-revision' -and $catClient -match 'data-cat-accept-revision') 'CAT offers a dedicated shorten action with before/after review and revert controls'
# 2026-08-13、利用者の指摘「余計な文章が多い」。「言い回しが適切かどうかは、ご自身で
# お確かめください。」は責任放棄に読める一文で、前半（何を点検しているか）だけで
# 同じことが伝わる。守るのは「機械の点検を、訳の良し悪しの保証に見せない」ことなので、
# 点検の範囲を言い切っていることを見る。
Check-YakuDual ($catPage -match '自動で点検しているのは、数字と単位の写しちがいだけです' -and $catPage -notmatch 'ご自身でお確かめください' -and $catClient -match '気になる点は見つかりませんでした') 'CAT states what the mechanical check covers, without claiming quality'
Check-YakuDual ($catClient -match "el\('cat-export-dialog'\)\.addEventListener\('close'" -and $catClient -match 'scopeIsCurrent\(scope, true\)' -and $catClient -match 'exportProject\(\)') 'export runs only after an unchanged preflight scope is confirmed'

Write-Host 'Inserted reference keeps its provenance through save and resume' -ForegroundColor Cyan
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-dual-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
function Get-YakuCatProjectStoreDir { return $tempRoot }
try {
    $referenceProject = New-YakuCatProjectFromPairs -Pairs @([pscustomobject]@{ JaText='参照元の原文'; EnText='' }) -Direction to_en -FileName 'reference-usage-test' -Register:$false
    $referenceCandidate = [pscustomobject]@{
        ReferenceId = '0123456789abcdef'; SourceName = '前年度資料.docx'; Page = 7
        Source = '参照元の原文'; Target = 'Inserted translation.'
    }
    $null = Set-YakuCatSegmentTranslation -Project $referenceProject -Index 0 -Text ([string]$referenceCandidate.Target)
    $null = Set-YakuCatSegmentReferenceUsage -Project $referenceProject -Index 0 -Candidate $referenceCandidate
    $referenceView = (ConvertTo-YakuCatProjectJson -Project $referenceProject | ConvertFrom-Json)
    Check-YakuDual (-not [bool]$referenceView.segments[0].reference_usage.edited_after_insert) 'inserted example is initially recorded as not edited'
    $null = Set-YakuCatSegmentTranslation -Project $referenceProject -Index 0 -Text 'Edited translation.'
    Check-YakuDual ([bool]$referenceProject.Segments[0].ReferenceUsage.edited_after_insert) 'editing after insertion updates reference_usage'
    $referenceProject.Segments[0].ReferenceUsage.edited_after_insert = $false
    $null = Update-YakuCatSegmentReferenceEditState -Segment $referenceProject.Segments[0] -Text 'Copilot revised translation.'
    Check-YakuDual ([bool]$referenceProject.Segments[0].ReferenceUsage.edited_after_insert -and [string]$referenceProject.Segments[0].ReferenceUsage.source_name -eq '前年度資料.docx' -and [string]$referenceProject.Segments[0].ReferenceUsage.source -eq '参照元の原文' -and [string]$referenceProject.Segments[0].ReferenceUsage.translation -eq 'Inserted translation.') 'Copilot revision marks the inserted example edited without changing its provenance snapshot'
    $savedReference = Save-YakuCatProject -Project $referenceProject
    $script:YakuCatProjects.Remove([string]$referenceProject.Id)
    $restoredReference = Restore-YakuCatProject -Id ([string]$referenceProject.Id)
    Check-YakuDual ($savedReference -and [bool]$restoredReference.Segments[0].ReferenceUsage.edited_after_insert -and [string]$restoredReference.Segments[0].ReferenceUsage.source_name -eq '前年度資料.docx' -and [int]$restoredReference.Segments[0].ReferenceUsage.page -eq 7) 'reference_usage survives save and resume'

    # ここにあった昇格（一時 artifact -> 作業）の動的検査は 2026-08-13 に外した。
    # 昇格するもとが無く、貼り付けた文章は最初から作業として作られる。
    # 「確認済みを引き継がない」「出力できない状態から始まる」は、いま
    # New-YakuCatTextProject 側の検査（Test-YakuV9161CatProject）が見ている。
} finally {
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host 'User-facing reuse vocabulary and no classification input' -ForegroundColor Cyan
$normalUi = $quickPage + "`n" + $catPage + "`n" + $client + "`n" + $rendererSource
$selfConfirmedPattern = '\u81ea\u5206\u304c\u78ba\u8a8d\u3057\u305f\u8a33'
$pastExamplePattern = '\u904e\u53bb\u306e\u7ffb\u8a33\u4f8b'
Check-YakuDual ($normalUi -match $selfConfirmedPattern) 'normal UI says self-confirmed translation'
Check-YakuDual ($normalUi -match $pastExamplePattern) 'normal UI says past translation example'
Check-YakuDual ($normalUi -notmatch '\u81ea\u5206\u306e\u8a33\s*100%|\u516c\u8868\u8a33\s*100%|Verified\s*=\s*\$true') 'normal UI has no 100-percent or Verified quality claim'
$allHtml = @($quickPagePath,$catPagePath) | ForEach-Object { Read-YakuDualText $_ }
$classificationMarkup = ($allHtml -join "`n")
Check-YakuDual ($classificationMarkup -notmatch '(?i)<(?:input|select|option)[^>]+(?:name|id|value)\s*=\s*[\x22\x27][^\x22\x27]*(?:public|internal|verified_release|verified_internal|prior_evidence|document_type)[^\x22\x27]*[\x22\x27]') 'production UI has no public/internal/document classification input'
Check-YakuDual ($client -notmatch '(?i)prior_evidence\s*:|verified_(?:release|internal)') 'browser payload cannot self-assert reuse classification'

Write-Host 'Numeric protection remains mandatory for both experiences' -ForegroundColor Cyan
$sensitive = 'Sales 1,234; phone 090-1234-5678; FY2027; date 2026/8/10.'
$masked = New-YakuNumericMaskMap -Text $sensitive -Root $root -Direction to_en -Location 'dual-experience-test'
Check-YakuDual (-not ([string]$masked.Text).Contains('1,234')) 'ordinary numeric value is masked'
Check-YakuDual (-not ([string]$masked.Text).Contains('090-1234-5678')) 'phone number is masked'
Check-YakuDual (-not ([string]$masked.Text).Contains('FY2027')) 'fiscal year number is masked'
Check-YakuDual (-not ([string]$masked.Text).Contains('2026/8/10')) 'date numbers are masked'
$packageSafe = $false
try {
    $package = New-YakuProtectedPromptPackage -Kind text -Root $root -Direction to_en `
        -Fields @([pscustomobject]@{ Name='source'; OriginalText=$sensitive; ProtectedText=[string]$masked.Text; NumericMaskMaps=@($masked.Map) }) `
        -Arguments ([pscustomobject]@{ Settings=[pscustomobject]@{}; Mode='full' })
    $packageSafe = -not ([string]$package.Prompt).Contains('1,234') -and -not ([string]$package.Prompt).Contains('090-1234-5678') -and -not ([string]$package.Prompt).Contains('FY2027') -and -not ([string]$package.Prompt).Contains('2026/8/10')
} catch { $packageSafe = $false }
Check-YakuDual $packageSafe 'canonical protected package contains no user numeric value'

Write-Host 'Cross-project machine cache is forbidden' -ForegroundColor Cyan
Check-YakuDual ($catBatchSource -notmatch '\bAdd-YakuFileTranslationsToCache\b|\bSet-YakuTranslationCacheValue\b') 'CAT machine drafts are not written to a cross-project cache'
$catWorker = Get-YakuDualSlice -Text $server -Start "if (`$Kind -eq 'cat')" -End "elseif (`$Kind -eq 'shorten')"
Check-YakuDual ($catWorker -notmatch '\bGet-YakuTranslationCacheValue\b|\bSet-YakuTranslationCacheValue\b') 'CAT worker does not read or write cross-project machine cache'
Check-YakuDual ($catProjectSource -match 'Find-YakuTranslationMemory' -and $catProjectSource -notmatch 'Find-YakuCorpusPairsForSegment') 'CAT exposes only self-confirmed translations as cross-project segment candidates'
Check-YakuDual ($server -match "requestedMode -eq 'corpus'[\s\S]{0,220}CAT_CORPUS_MODE_RETIRED" -and $server -match "result\.Mode -eq 'corpus'[\s\S]{0,220}CAT_CORPUS_MODE_RETIRED") 'retired corpus job cannot bypass explicit candidate insertion or persist hidden references'

if ($script:failed -gt 0) { throw ('Dual experience contract tests failed: ' + $script:failed) }
Write-Host 'V91.64 dual experience regression passed.' -ForegroundColor Green
