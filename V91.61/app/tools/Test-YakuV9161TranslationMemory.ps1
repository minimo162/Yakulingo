<#
.SYNOPSIS
  V91.61: 翻訳メモリの回帰テスト。

.DESCRIPTION
  候補ペインの3本柱の最後の1本。利用者が確定した訳を貯め、次に同じ文が
  来たら差し込めるようにする。市販ツールの Ctrl+Enter と同じ作法で、
  確定＝記憶にする。

  一番効くのはこれである。公表訳から取った対訳は「読ませる訳」で意訳が
  多く、そのままは使いにくい。翻訳メモリは自分の文体で、自分が正しいと
  判断したものだけが入る。

  ここで見るのは4つ。
   - 確定したものが貯まること
   - 同じ原文を訳し直したら、あとの訳が優先されること
   - 完全一致が最優先で出ること
   - 壊れた行があっても残りが読めること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161TranslationMemory.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'TranslationMemory.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-tm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$tm = Join-Path $tmp 'tm-to_en.jsonl'
$oldDataDir = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'data'
function Add-TestTranslationMemoryEntry {
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target,
        [string]$Path,
        [int]$ReviewRevision = 7,
        [string]$Location = 'Sheet1, A1',
        [int]$Page = 3,
        [string]$ProjectId = '11111111111111111111111111111111',
        [string]$SegmentId = '',
        [string]$FileName = 'FY2025-results.xlsx'
    )
    if ([string]::IsNullOrWhiteSpace($SegmentId)) { $SegmentId = (Get-YakuTranslationMemoryHash -Text ([string]$Source)).Substring(0, 32) }
    return (Add-YakuTranslationMemoryEntry -Source $Source -Target $Target -Path $Path `
        -OriginProjectId $ProjectId -OriginFileName $FileName -OriginSegmentId $SegmentId `
        -OriginLocation $Location -OriginPage $Page -ReviewRevision $ReviewRevision)
}
try {
    Write-Host '貯める' -ForegroundColor Cyan
    $r = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm
    Chk ([bool]$r.Added -and $r.Reason -eq 'new') '確定した訳を貯める'
    $r = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'same') '同じ内容は二度貯めない'
    $r = Add-TestTranslationMemoryEntry -Source '' -Target 'x' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'empty') '原文が空なら貯めない'
    $r = Add-TestTranslationMemoryEntry -Source 'x' -Target '  ' -Path $tm
    Chk (-not [bool]$r.Added) '訳文が空白だけなら貯めない'
    $r = Add-YakuTranslationMemoryEntry -Source '出典の無い文です。' -Target 'No provenance.' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'provenance-required') '出典の無い新規TM行を作らない'

    $stored = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -Last 1) | ConvertFrom-Json
    Chk ([int]$stored.schema_version -eq 3 -and [string]$stored.event_type -eq 'upsert' -and [string]$stored.origin_project_id -eq '11111111111111111111111111111111') 'schema v3 upsertとorigin project idを永続化する'
    Chk ([string]$stored.unit_id -match '^[a-f0-9]{64}$' -and [string]$stored.event_id -match '^[a-f0-9]{64}$') '翻訳単位と追記eventを安定IDへ束縛する'
    Chk ([string]$stored.origin_file_name -eq 'FY2025-results.xlsx' -and [string]$stored.origin_location -eq 'Sheet1, A1' -and [int]$stored.origin_page -eq 3) '資料名・箇所・ページを永続化する'
    Chk ([string]$stored.origin_segment_id -match '^[a-f0-9]{32}$' -and [int]$stored.review_revision -eq 7) 'stable segment id・確認revisionを永続化する'
    Chk ([string]$stored.source_hash -eq (Get-YakuTranslationMemoryHash -Text ([string]$stored.source)) -and [string]$stored.target_hash -eq (Get-YakuTranslationMemoryHash -Text ([string]$stored.target))) '原文・訳文ハッシュを永続化する'

    Write-Host '訳し直し' -ForegroundColor Cyan
    $r = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will promote electrification.' -Path $tm -ReviewRevision 8
    Chk ([bool]$r.Added -and $r.Reason -eq 'updated') '訳し直しは上書きとして貯まる'
    $h = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk ($h.Count -eq 1) '同じ原文の候補は1件にまとまる'
    Chk ($h[0].Target -eq 'We will promote electrification.') 'あとから確定した訳が出る'
    Chk ($h[0].SourceName -eq 'FY2025-results.xlsx' -and $h[0].Location -eq 'Sheet1, A1' -and [int]$h[0].Page -eq 3) '候補へ資料名・箇所・ページを返す'
    Chk ([int]$h[0].ReviewRevision -eq 8 -and [string]$h[0].ReferenceId -match '^[a-f0-9]{64}$') '候補を確認revisionと安定reference idへ束縛する'
    $beforeReplay = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    $replayed = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm -ReviewRevision 7
    $afterReplay = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    $afterReplayHit = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk (-not [bool]$replayed.Added -and $replayed.Reason -eq 'same' -and $afterReplay -eq $beforeReplay -and $afterReplayHit[0].Target -eq 'We will promote electrification.') '古いoutbox eventの再送は最新訳を巻き戻さない'

    Write-Host '同じ原文の複数確認訳' -ForegroundColor Cyan
    $variantProject = '22222222222222222222222222222222'
    $variantSegment = '33333333333333333333333333333333'
    $r = Add-TestTranslationMemoryEntry -Source '当社は 電動化を進めます 。' -Target 'We will pursue electrification.' `
        -Path $tm -ProjectId $variantProject -SegmentId $variantSegment -FileName 'FY2026-plan.docx' `
        -Location '本文 段落 4' -Page 2 -ReviewRevision 3
    Chk ([bool]$r.Added -and $r.Reason -eq 'new') '別project・segmentの確認訳を別unitとして貯める'
    $variants = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk ($variants.Count -eq 2) '同じ正規化原文の複数候補を失わない'
    Chk (@($variants.Target) -contains 'We will promote electrification.' -and @($variants.Target) -contains 'We will pursue electrification.') '異なる確認訳を双方表示する'
    Chk (@($variants | Where-Object { $_.SourceName -eq 'FY2026-plan.docx' -and $_.Location -eq '本文 段落 4' }).Count -eq 1) '複数候補ごとに出典を維持する'

    Write-Host '引く' -ForegroundColor Cyan
    Chk ([bool]$h[0].Exact -and [Math]::Abs([double]$h[0].Ratio - 1.0) -lt 0.001) '完全一致は一致率1.0'
    $h = @(Find-YakuTranslationMemory -Text '当社は 電動化を進めます 。' -Path $tm)
    Chk (@($h | Where-Object { [bool]$_.Exact }).Count -eq 2) '空白の違いは同じ文とみなす'
    $fuzzySource = '当社は中期経営計画に基づき電動化への投資を着実に進めています。'
    $fuzzyQuery = '当社は中期経営計画に基づき電動化への投資を着実に推進しています。'
    $null = Add-TestTranslationMemoryEntry -Source $fuzzySource -Target 'We are steadily investing in electrification under our mid-term plan.' `
        -Path $tm -ProjectId '44444444444444444444444444444444' -SegmentId '55555555555555555555555555555555' `
        -FileName 'mid-term-plan.docx' -Location '本文 段落 9' -Page 5
    $h = @(Find-YakuTranslationMemory -Text $fuzzyQuery -Path $tm)
    Chk ($h.Count -ge 1 -and -not [bool]$h[0].Exact -and $h[0].MatchType -eq 'fuzzy') '包含関係にない類似文をfuzzy候補に出す'
    Chk ([double]$h[0].Score -ge 0.70 -and [Math]::Abs([double]$h[0].Score - [double]$h[0].Ratio) -lt 0.0001) 'fuzzy候補へ70%以上のscoreを返す'
    Chk (@(Find-YakuTranslationMemory -Text '短い' -Path $tm).Count -eq 0) '短すぎる原文では引かない'
    Chk (@(Find-YakuTranslationMemory -Text 'まったく関係のない文章です。' -Path $tm).Count -eq 0) '当たらなければ空'
    Chk (@(Find-YakuTranslationMemory -Text 'x' -Path (Join-Path $tmp 'no-such.jsonl')).Count -eq 0) 'メモリが無くても落ちない'

    Write-Host '完全一致を先に出す' -ForegroundColor Cyan
    # 3文字以下は最小長に届かず引かない（語は用語集の役目）。
    # ここは文として成り立つ長さで試す。
    $null = Add-TestTranslationMemoryEntry -Source '電動化を進めます。' -Target 'We advance electrification.' -Path $tm -Location 'Sheet1, A2'
    $h = @(Find-YakuTranslationMemory -Text '電動化を進めます。' -Path $tm)
    Chk ($h.Count -ge 1 -and [bool]$h[0].Exact -and $h[0].Target -eq 'We advance electrification.') '完全一致が先頭に来る'
    Chk (@(Find-YakuTranslationMemory -Text '電動化' -Path $tm).Count -eq 0) '語は翻訳メモリでは引かない（用語集の役目）'

    Write-Host '追記型tombstone' -ForegroundColor Cyan
    $beforeTombstone = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    $r = Add-YakuTranslationMemoryTombstone -Path $tm -OriginProjectId $variantProject `
        -OriginSegmentId $variantSegment -ReviewRevision 4 -Reason 'translation-corrected'
    Chk ([bool]$r.Added -and $r.Reason -eq 'tombstoned') '確認訳を物理削除せずtombstoneで撤回する'
    $afterTombstone = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    Chk ($afterTombstone -eq ($beforeTombstone + 1)) 'tombstoneをJSONL末尾へ1行追記する'
    $variants = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    $exactVariants = @($variants | Where-Object { [bool]$_.Exact })
    Chk ($exactVariants.Count -eq 1 -and $exactVariants[0].Target -eq 'We will promote electrification.') 'tombstone対象だけを候補から隠す'
    $r = Add-YakuTranslationMemoryTombstone -Path $tm -OriginProjectId $variantProject `
        -OriginSegmentId $variantSegment -ReviewRevision 4 -Reason 'translation-corrected'
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'same' -and @(Get-Content -LiteralPath $tm -Encoding UTF8).Count -eq $afterTombstone) '同じtombstone要求は冪等にする'

    Write-Host '壊れた行' -ForegroundColor Cyan
    [IO.File]::AppendAllLines($tm, [string[]]@('{壊れた行', ''), [Text.UTF8Encoding]::new($false))
    Chk ((Read-YakuTranslationMemory -Path $tm).Count -eq 4) '壊れた行を捨ててactive eventをunitごとに読む'

    Write-Host '出典不明を閉じる' -ForegroundColor Cyan
    $legacy = Join-Path $tmp 'legacy.jsonl'
    [IO.File]::WriteAllLines($legacy, [string[]]@('{"key":"旧形式の文です。","source":"旧形式の文です。","target":"Legacy entry","direction":"to_en"}'), [Text.UTF8Encoding]::new($false))
    Chk ((Read-YakuTranslationMemory -Path $legacy).Count -eq 1) '旧形式は移行調査のため読み取れる'
    Chk (@(Find-YakuTranslationMemory -Text '旧形式の文です。' -Path $legacy).Count -eq 0) '出典不明の旧形式は候補に表示しない'
    $v2 = Join-Path $tmp 'schema-v2.jsonl'
    $v2Record = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $v2Record.schema_version = 2
    foreach ($field in @('event_type','event_id','unit_id')) { $v2Record.PSObject.Properties.Remove($field) }
    [IO.File]::WriteAllLines($v2, [string[]]@(($v2Record | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$v2Record.source) -Path $v2).Count -eq 1) '出典検証できるschema v2は読み取り互換を保つ'
    $tampered = Join-Path $tmp 'tampered.jsonl'
    $tamperedRecord = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $tamperedRecord.target = 'Tampered target'
    [IO.File]::WriteAllLines($tampered, [string[]]@(($tamperedRecord | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$tamperedRecord.source) -Path $tampered).Count -eq 0) '内容とハッシュが違うTM行は候補に表示しない'
    $tamperedOrigin = Join-Path $tmp 'tampered-origin.jsonl'
    $tamperedOriginRecord = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $tamperedOriginRecord.origin_location = '偽の出典箇所'
    [IO.File]::WriteAllLines($tamperedOrigin, [string[]]@(($tamperedOriginRecord | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$tamperedOriginRecord.source) -Path $tamperedOrigin).Count -eq 0) '出典表示だけを書き換えたTM行も候補に表示しない'

    Write-Host '確定と結びついているか' -ForegroundColor Cyan
    $cat = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CatProject.ps1') -Raw -Encoding UTF8
    $server = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
    Chk ($server -match 'Add-YakuCatTranslationMemoryOutboxEvent' -and $server -match 'Sync-YakuCatTranslationMemoryOutbox') 'プロジェクト保存後に確認訳を翻訳メモリへ貯める'
    Chk ($server -match 'OriginProjectId' -and $server -match 'OriginFileName' -and $server -match 'OriginSegmentId' -and $server -match 'OriginLocation' -and $server -match 'ReviewRevision') '確定時に出典契約をTMへ渡す'
    Chk ($server -match 'location\s*=\s*\[string\]\$_\.Location') '候補APIがlocationを返す'
    Chk ($cat -match 'Find-YakuTranslationMemory') '候補ペインが翻訳メモリを引く'
    Chk ($cat -match "Kind\s*=\s*'memory'") '翻訳メモリの候補に印を付ける'
    # 自分が確定した訳を先頭に置く。公表訳より自分の文体に合うため。
    Chk ($cat -match 'Weight   = 30000') '自分の訳を先に出す'
    Chk ($cat -notmatch 'Find-YakuCorpusPairsForSegment' -and $cat -notmatch "Kind\s*=\s*'corpus'") '同梱コーパスを候補へ混ぜない'
    # 文例を作るのは開発者。突き合わせた資料からだけ保存できる。
    Chk ($cat -match "Project\.Source -ne 'align'") '文例は突き合わせからだけ保存できる'

    Write-Host '確定の状態' -ForegroundColor Cyan
    foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'Settings.ps1', 'PromptBuilder.ps1', 'Translation.ps1',  'CatTranslation.ps1', 'CellSegments.ps1', 'Corpus.ps1', 'CorpusPairs.ps1', 'CatProject.ps1')) {
        . (Join-Path (Join-Path $root 'src') $mod)
    }
    $proj = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "当社は電動化を進めます。" -Translation "We will advance electrification."
    $sum = Get-YakuCatProjectSummary -Project $proj
    Chk ([int]$sum.Translated -eq 1 -and [int]$sum.Confirmed -eq 0) '訳が入っていても、見るまでは確定にしない'
    Chk ([string]@($proj.Segments)[0].Origin -eq 'copilot') '簡易翻訳から来た訳は機械の訳として印を付ける'

    $null = Set-YakuCatSegmentConfirmed -Project $proj -Index 0
    $sum = Get-YakuCatProjectSummary -Project $proj
    Chk ([int]$sum.Confirmed -eq 1 -and [int]$sum.Unconfirmed -eq 0) '直さずに確定できる'

    $empty = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' -Text "訳の無い文です。"
    $threw = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $empty -Index 0 } catch { $threw = $true }
    Chk $threw '訳が空の行は確定できない'

    $cleared = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "一度訳した文です。" -Translation "This sentence was translated once."
    $null = Set-YakuCatSegmentTranslation -Project $cleared -Index 0 -Text ''
    Chk ([string]@($cleared.Segments)[0].Translation -eq '') '訳文を空へ戻せる'
    Chk (-not [bool]@($cleared.Segments)[0].Confirmed) '空へ戻した行は確認済みにしない'
    Chk ([string]@($cleared.Segments)[0].Origin -eq '') '空へ戻した行に手直し済みの印を残さない'

    # 行数が合わない訳文は割り当てない。ずれた対応を見せるより空欄がよい。
    $mismatch = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "一つ目の文です。二つ目の文です。" -Translation "Only one sentence."
    Chk ([string]@($mismatch.Segments)[0].Translation -eq '') '行数が合わない訳文は割り当てない'

    Write-Host '作業内容の保存と復元' -ForegroundColor Cyan
    Chk (Save-YakuCatProject -Project $proj) 'ディスクへ保存できる'
    $file = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) ([string]$proj.Id)) 'project.json'
    Chk (Test-Path -LiteralPath $file -PathType Leaf) '保存先にファイルができる'

    Write-Host 'CAT候補の出典' -ForegroundColor Cyan
    $reviewedSegment = @($proj.Segments)[0]
    $tmSaved = Add-YakuTranslationMemoryEntry -Source ([string]$reviewedSegment.Text) -Target ([string]$reviewedSegment.Translation) `
        -Direction ([string]$proj.Direction) -Origin 'cat-reviewed-qc-v1' `
        -OriginProjectId ([string]$proj.Id) -OriginFileName 'FY2025-results.docx' `
        -OriginSegmentId ([string]$reviewedSegment.SegmentId) -OriginLocation '本文 段落 12' `
        -OriginPage 4 -ReviewRevision ([int]$proj.Revision)
    Chk ([bool]$tmSaved.Added) '保存済みCAT revisionから出典付きTMを作る'
    $candidateProject = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' -Text ([string]$reviewedSegment.Text)
    $memoryCandidates = @(Get-YakuCatSegmentCandidates -Root $root -Project $candidateProject -Index 0 -PairsDir (Join-Path $tmp 'no-pairs') | Where-Object { [string]$_.Kind -eq 'memory' })
    Chk ($memoryCandidates.Count -eq 1) '出典付きTMだけがCAT候補へ出る'
    Chk ([string]$memoryCandidates[0].SourceName -eq 'FY2025-results.docx' -and [string]$memoryCandidates[0].Location -eq '本文 段落 12' -and [int]$memoryCandidates[0].Page -eq 4) 'CAT候補がどの資料のどの箇所かを返す'
    $null = Set-YakuCatSegmentTranslation -Project $candidateProject -Index 0 -Text ([string]$memoryCandidates[0].Target)
    $null = Set-YakuCatSegmentReferenceUsage -Project $candidateProject -Index 0 -Candidate $memoryCandidates[0]
    Chk ([string]@($candidateProject.Segments)[0].ReferenceUsage.location -eq '本文 段落 12') '明示挿入の記録にも出典箇所を残す'

    # メモリから消したうえで復元する。再起動を模している。
    Remove-YakuCatProject -Id ([string]$proj.Id)
    Chk ($null -eq (Get-YakuCatProject -Id ([string]$proj.Id))) 'メモリからは消えている'
    $back = Restore-YakuCatProject -Id ([string]$proj.Id)
    Chk ($null -ne $back) '保存したものを戻せる'
    Chk (@($back.Segments).Count -eq @($proj.Segments).Count) '行数が保たれる'
    Chk ([bool]@($back.Segments)[0].Confirmed) '確定の状態が残る'
    Chk ([string]@($back.Segments)[0].Translation -eq 'We will advance electrification.') '訳文が残る'
    Chk ([string]$back.Direction -eq 'to_en') '翻訳方向が残る'

    $recent = @(Get-YakuCatSavedProjects -Limit 10)
    Chk (@($recent | Where-Object { [string]$_.Id -eq [string]$proj.Id }).Count -eq 1) '前回の続きの一覧に出る'
    $entry = @($recent | Where-Object { [string]$_.Id -eq [string]$proj.Id })[0]
    Chk ([int]$entry.Confirmed -eq 1 -and [int]$entry.Total -eq 1) '一覧に確認済みの数が出る'

    Chk ($null -eq (Restore-YakuCatProject -Id 'no-such-project')) '無いものを戻そうとしても落ちない'
    try { Remove-Item -LiteralPath $file -Force } catch {}

    Write-Host '言葉で探す（コンコーダンス）' -ForegroundColor Cyan
    # 市販のCATツールでいうコンコーダンス。いまの行に対して自動で出る候補
    # （Find-YakuTranslationMemory）とは別で、利用者が言葉を入れて過去訳を引く。
    $null = Add-TestTranslationMemoryEntry -Source '固定費を圧縮しました。' -Target 'We reduced fixed costs.' -Path $tm
    $concordance = @(Search-YakuTranslationMemoryConcordance -Query '固定費' -Direction 'to_en' -Path $tm)
    Chk ($concordance.Count -ge 1) '原文に含む言葉で引ける'
    Chk ([string]$concordance[0].Target -eq 'We reduced fixed costs.') '訳文が一緒に返る'
    Chk ([string]$concordance[0].MatchedIn -eq 'source') 'どちら側に当たったかが分かる'
    $byTarget = @(Search-YakuTranslationMemoryConcordance -Query 'fixed costs' -Direction 'to_en' -Path $tm)
    Chk ($byTarget.Count -ge 1 -and [string]$byTarget[0].MatchedIn -eq 'target') '訳文に含む言葉でも引ける'
    $byCase = @(Search-YakuTranslationMemoryConcordance -Query 'FIXED COSTS' -Direction 'to_en' -Path $tm)
    Chk ($byCase.Count -ge 1) '英語は大文字小文字を畳む'
    Chk (@(Search-YakuTranslationMemoryConcordance -Query '固' -Direction 'to_en' -Path $tm).Count -eq 0) '1文字では引かない（何にでも当たる）'
    Chk (@(Search-YakuTranslationMemoryConcordance -Query '存在しない言葉' -Direction 'to_en' -Path $tm).Count -eq 0) '無いものは無いと返す'
}
finally {
    $env:YAKULINGO_DATA_DIR = $oldDataDir
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 translation memory regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 translation memory regression passed.' -ForegroundColor Green
