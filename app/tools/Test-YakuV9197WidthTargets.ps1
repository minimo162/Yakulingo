#Requires -Version 5.1
<#
  幅を知って最初から訳す。Excelセルの初回翻訳プロンプトへ、そのセルの
  「使える幅」から出した概算文字目標を添える機能の回帰試験。

  V9187CompactionBudget と同じ流儀（プロンプト文字列の直接assert、Copilot・
  Excelは要らない）に加えて、算出そのもの（列幅→pxの gate・avgCharPx概算・
  autoSpillColumns・寄せの扱い）は本物の cat.html/cat.js を headless
  Chromium で開いて確かめる（node/Playwright/Chromium が無い環境では
  UNMEASURED＝exit 3 にする。「測れなかった」を赤に畳まない）。

  見るのは5つ。
    (a) ConvertTo-YakuCatValidFitTargets: サーバが受け取る fit_targets の
        検証（8..99の整数のみ・実在index・indexの欠落/nullを拒む・上限件数は
        受理した件数で数える＝水増しされた不正な行に締め出されない）。
    (b) Resolve-YakuCatFitTargetForDuplicates: 同じ原文の複製へ複数の目標が
        付いたときの畳み方（全複製に目標があるときだけ最小値、1つでも
        無指定なら目標そのものを付けない）。
    (c) ConvertTo-YakuCatDedupedItems: 生のpending items（重複あり）を渡し、
        重複排除→(b)の畳み→**実物の New-YakuCatPrompt** へ通し、畳んだ結果が
        正しいitem番号でプロンプトへ出ることを端から端まで確かめる
        （CoD審査 2026-08-18 REWORK-1: worker本体はジョブの別ランスペースに
        あり試験から届かないため、この関数を切り出して直接検証する）。
    (d) New-YakuCatCharacterTargets / New-YakuCatPrompt: 目標を持つitemだけを
        列挙する・前置文が「省略・要約・圧縮せず、収まらなければ超えてよい」と
        言っている・無指定時は固定文・雛形のプレースホルダ展開・マスク済み
        プロンプトに生の資料数値が混ざらないこと。
    (e) 実機Chromium: previewOutputAvgCharPx・segmentSourceFitTarget・
        buildFitTargets が、translate()/translateRow() の POST body へ
        正しい fit_targets を積むこと（既知幅・非wrap・非shrink・寄せの
        ゲート、8..99の外は送らない、訳済み行は対象にしない、1件も無ければ
        フィールド自体を省略する）。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9197Root = Split-Path -Parent $PSScriptRoot
$YakuT9197Src = Join-Path $YakuT9197Root 'src'
$script:T9197Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9197 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9197Failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9197WidthTargets'

. (Join-Path $YakuT9197Src 'SrcModules.ps1')
foreach ($YakuT9197File in $script:YakuSrcModuleFiles) {
    . (Join-Path $YakuT9197Src $YakuT9197File)
}

# ============================================================ (a) サーバ側の検証
Write-Host '-- ConvertTo-YakuCatValidFitTargets --'

function New-T9197FitTarget { param($Index, $MaxChars) return [pscustomobject]@{ index = $Index; max_chars = $MaxChars } }

$T9197RawFitTargets = @(
    (New-T9197FitTarget -Index 0 -MaxChars 8),
    (New-T9197FitTarget -Index 1 -MaxChars 99),
    (New-T9197FitTarget -Index 2 -MaxChars 7),
    (New-T9197FitTarget -Index 3 -MaxChars 100),
    (New-T9197FitTarget -Index 4 -MaxChars 12.5),
    (New-T9197FitTarget -Index 99 -MaxChars 20),
    (New-T9197FitTarget -Index 5 -MaxChars 'not-a-number'),
    $null
) | ConvertTo-Json -Depth 4 | ConvertFrom-Json
# SegmentCount は7（配列内の実在index0..5すべてが有効範囲に収まる数）にする。
# 6のままだと「受理した2件」で上限に達し、7番目（'not-a-number'の行）が
# 検証されないまま素通りする空振りの表明になっていた（CoD審査 2026-08-18
# REWORK-1 の指摘。LOW-2）。
$T9197Validated = ConvertTo-YakuCatValidFitTargets -RawFitTargets $T9197RawFitTargets -SegmentCount 7
Assert-T9197 -Condition ($T9197Validated.Count -eq 2) ('境界内の2件だけが残る（実測 ' + $T9197Validated.Count + ' 件）')
Assert-T9197 -Condition ($T9197Validated.ContainsKey(0) -and [int]$T9197Validated[0] -eq 8) '8は最初に許される目標'
Assert-T9197 -Condition ($T9197Validated.ContainsKey(1) -and [int]$T9197Validated[1] -eq 99) '99は最後に許される目標'
Assert-T9197 -Condition (-not $T9197Validated.ContainsKey(2)) '7は境界の外（捨てる）'
Assert-T9197 -Condition (-not $T9197Validated.ContainsKey(3)) '100は境界の外（捨てる）'
Assert-T9197 -Condition (-not $T9197Validated.ContainsKey(4)) '12.5は非整数（捨てる）'
Assert-T9197 -Condition (-not $T9197Validated.ContainsKey(99)) '実在しないindex（SegmentCountの外）は捨てる'
Assert-T9197 -Condition (-not $T9197Validated.ContainsKey(5)) '数値に変換できない値は捨てる（このassertは実際に7件目まで検証されて初めて意味を持つ）'

# indexの欠落・nullは、[int]キャストが例外を投げず0になることを悪用して
# 暗黙にセグメント0を狙わせてはいけない（CatTranslation.ps1のindex検証。
# CoD審査 2026-08-18 REWORK-1 の指摘。LOW-2）。
$T9197MissingIndexRaw = @([pscustomobject]@{ max_chars = 20 }) | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$T9197MissingIndexValidated = ConvertTo-YakuCatValidFitTargets -RawFitTargets @($T9197MissingIndexRaw) -SegmentCount 6
Assert-T9197 -Condition ($T9197MissingIndexValidated.Count -eq 0) 'indexが欠落した行は、暗黙にセグメント0を狙わず捨てられる'
$T9197NullIndexJson = @'
[{"index":null,"max_chars":20}]
'@
$T9197NullIndexRaw = $T9197NullIndexJson | ConvertFrom-Json
$T9197NullIndexValidated = ConvertTo-YakuCatValidFitTargets -RawFitTargets $T9197NullIndexRaw -SegmentCount 6
Assert-T9197 -Condition ($T9197NullIndexValidated.Count -eq 0) 'indexが明示的にnullの行も同様に捨てられる'

# 上限件数は「受理した件数」で数える（examined countではない）。捨てた行の
# 数で打ち切ると、水増しされた不正な行の後ろに続く正しい行が締め出される
# （CoD審査 2026-08-18 REWORK-1 の指摘。LOW-2）。ここでは不正な行（index=-1、
# 範囲外で必ず捨てられる）を10件並べたあとに正しい行を1件置く。
$T9197PaddedRaw = @(
    @(1..10 | ForEach-Object { New-T9197FitTarget -Index -1 -MaxChars 10 }) +
    (New-T9197FitTarget -Index 2 -MaxChars 15)
) | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$T9197PaddedValidated = ConvertTo-YakuCatValidFitTargets -RawFitTargets $T9197PaddedRaw -SegmentCount 3
Assert-T9197 -Condition ($T9197PaddedValidated.ContainsKey(2) -and [int]$T9197PaddedValidated[2] -eq 15) '水増しされた不正な行の後ろに来る正しい行も、上限に締め出されず受理される'

# 上限件数そのものはSegmentCountで頭打ちになる（際限のない配列を受け付けない）。
$T9197ManyRaw = @(0..49 | ForEach-Object { New-T9197FitTarget -Index ($_ % 3) -MaxChars 10 }) | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$T9197ManyValidated = ConvertTo-YakuCatValidFitTargets -RawFitTargets $T9197ManyRaw -SegmentCount 3
Assert-T9197 -Condition ($T9197ManyValidated.Count -le 3) ('件数の上限がSegmentCountで打ち切られる（実測 ' + $T9197ManyValidated.Count + ' 件）')

# 何も渡らなければ空（従来どおり何も送らない）。
$T9197EmptyValidated = ConvertTo-YakuCatValidFitTargets -RawFitTargets $null -SegmentCount 6
Assert-T9197 -Condition ($T9197EmptyValidated.Count -eq 0) 'fit_targetsが無ければ空のまま（従来どおり）'

# ============================================================ (b) 複製の畳み方
Write-Host '-- Resolve-YakuCatFitTargetForDuplicates --'

Assert-T9197 -Condition ((Resolve-YakuCatFitTargetForDuplicates -MaxCharsValues @(20, 15, 30)) -eq 15) '全複製に目標があれば最小値を採る'
Assert-T9197 -Condition ($null -eq (Resolve-YakuCatFitTargetForDuplicates -MaxCharsValues @(20, $null, 30))) '1つでも無指定が混ざれば目標を付けない'
Assert-T9197 -Condition ($null -eq (Resolve-YakuCatFitTargetForDuplicates -MaxCharsValues @())) '複製が無ければ目標も無い'
Assert-T9197 -Condition ((Resolve-YakuCatFitTargetForDuplicates -MaxCharsValues @(42)) -eq 42) '単独なら自分の値がそのまま採られる'
Assert-T9197 -Condition ($null -eq (Resolve-YakuCatFitTargetForDuplicates -MaxCharsValues @($null))) '唯一の複製が無指定なら目標は無い'

# ============================================================ (c) 重複排除→畳み→実プロンプトの通し試験
Write-Host '-- ConvertTo-YakuCatDedupedItems（端から端まで） --'

# CoD審査 2026-08-18 REWORK-1: worker本体（Server.ps1のジョブscriptblock）は
# 別ランスペースにあり、試験からは直接届かない。手作りのitemsだけを
# New-YakuCatPrompt / New-YakuCatCharacterTargets へ渡す試験では、
# dedupe→MaxChars代入→prompt という配線そのもの（Resolve-
# YakuCatFitTargetForDuplicates の戻り値を .MaxChars へ代入するその1行）を
# 一度も実行しない。ここでは生のpending items（Server.ps1の'translate'
# アクションが作る素の形: index/text/terminology/max_chars）を渡し、
# 重複排除→畳み→実物の New-YakuCatPrompt で、正しいitem番号に正しい目標が
# 出ることまで確かめる。
#
# index0とindex2は同じ原文（複製）。index0だけに目標があり、index2には無い
# ので、規則（全複製に目標があるときだけ採用）により畳んだ後は目標が消える
# はず。index1は単独の原文で、自分の目標がそのまま残るはず。
$T9197DupedSourceText = [string]::Concat([char]0x58F2, [char]0x4E0A, [char]0x9AD8, [char]0x306F, [char]0x5897, [char]0x52A0, [char]0x3057, [char]0x305F, [char]0x3002)
$T9197SoloSourceText = [string]::Concat([char]0x8CBB, [char]0x7528, [char]0x306F, [char]0x6E1B, [char]0x5C11, [char]0x3057, [char]0x305F, [char]0x3002)
$T9197RawPendingItems = @(
    [pscustomobject]@{ index = 0; text = $T9197DupedSourceText; terminology = @(); max_chars = 30 },
    [pscustomobject]@{ index = 1; text = $T9197SoloSourceText; terminology = @(); max_chars = 18 },
    [pscustomobject]@{ index = 2; text = $T9197DupedSourceText; terminology = @() }
) | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$T9197Deduped = @(ConvertTo-YakuCatDedupedItems -RawItems @($T9197RawPendingItems))
Assert-T9197 -Condition ($T9197Deduped.Count -eq 2) ('同じ原文は1つに畳まれる（実測 ' + $T9197Deduped.Count + ' 件）')
$T9197DupEntry = $T9197Deduped | Where-Object { [string]$_.Text -eq $T9197DupedSourceText } | Select-Object -First 1
$T9197SoloEntry = $T9197Deduped | Where-Object { [string]$_.Text -eq $T9197SoloSourceText } | Select-Object -First 1
Assert-T9197 -Condition ($null -ne $T9197DupEntry -and ((@($T9197DupEntry.Targets) | Sort-Object) -join ',') -eq '0,2') '複製した行の両方のindexがTargetsへ残る'
Assert-T9197 -Condition ($null -ne $T9197DupEntry -and $null -eq $T9197DupEntry.MaxChars) '複製の片方に目標が無ければ、畳んだ後も目標が付かない'
Assert-T9197 -Condition ($null -ne $T9197SoloEntry -and [int]$T9197SoloEntry.MaxChars -eq 18) '単独の行は自分の目標がそのまま残る'

# 畳んだ結果を実物の New-YakuCatPrompt へそのまま通す。ここが緑であることは
# 「dedupe→畳み→prompt」の配線全体が実際に動いていることの証明であり、
# Resolve-YakuCatFitTargetForDuplicates の戻り値を .MaxChars へ代入し損なう
# 変異（レビュアが実証した変異）が入っていれば、単独行の目標が消えて
# 下のassertが赤くなる。
$T9197WiredItems = @($T9197Deduped | ForEach-Object {
    [pscustomobject]@{ Index = [int]$_.Index; Text = [string]$_.Text; MaskedText = [string]$_.Text; Terminology = @($_.Terminology); MaxChars = $_.MaxChars }
})
$T9197DedupeSettings = Read-YakuSettings -Root $YakuT9197Root
$T9197WiredPrompt = New-YakuCatPrompt -Root $YakuT9197Root -Items $T9197WiredItems -Settings $T9197DedupeSettings -Direction 'to_en' -RequestId 'b2c3d4e5f60718293a4b5c6d7e8f90a1'
Assert-T9197 -Condition ($T9197WiredPrompt -match ('"item":' + [int]$T9197SoloEntry.Index + ',"approximate_max_chars":18')) '畳んだ結果が実プロンプトのCHARACTER_TARGETSへ正しいitem番号・正しい目標で出る（dedupe→MaxChars代入→promptの配線そのものを実行して確かめる）'
Assert-T9197 -Condition ($T9197WiredPrompt -notmatch ('"item":' + [int]$T9197DupEntry.Index + ',')) '目標を失った複製の行はプロンプトへ出ない'

# ============================================================ (d) プロンプトへの描画
Write-Host '-- New-YakuCatCharacterTargets / New-YakuCatPrompt --'

$T9197Items = @(
    [pscustomobject]@{ Index = 1; MaxChars = 20 },
    [pscustomobject]@{ Index = 2; MaxChars = $null },
    [pscustomobject]@{ Index = 3; MaxChars = 8 },
    [pscustomobject]@{ Index = 4; MaxChars = 7 },
    [pscustomobject]@{ Index = 5; MaxChars = 100 }
)
$T9197Targets = New-YakuCatCharacterTargets -Items $T9197Items
Assert-T9197 -Condition ($T9197Targets -match '"item":1,"approximate_max_chars":20') '目標を持つitem 1が列挙される'
Assert-T9197 -Condition ($T9197Targets -match '"item":3,"approximate_max_chars":8') '境界の8は列挙される'
Assert-T9197 -Condition ($T9197Targets -notmatch '"item":2,') '目標の無いitem 2は列挙されない'
Assert-T9197 -Condition ($T9197Targets -notmatch '"item":4,') '7（境界の外）は列挙されない'
Assert-T9197 -Condition ($T9197Targets -notmatch '"item":5,') '100（境界の外）は列挙されない'
Assert-T9197 -Condition ($T9197Targets -match '(?i)layout-derived targets, not measured cell capacities') '前置文: 実測ではないと明示する'
# 雛形自身の情報保持の指示（Do not abbreviate, summarize, compress, merge,
# omit, or add information）と同じ動詞を並べる。summarize/compress を
# 省くと「省いた分は免除される」と読めてしまうため、雛形と揃える
# （CoD審査 2026-08-18 REWORK-1 の指摘。LOW-4）。
Assert-T9197 -Condition ($T9197Targets -match '(?i)never omit, abbreviate, summarize, compress, or drop information') '前置文: 省略・要約・圧縮せずに削って収めることは指示しない（雛形の動詞と揃える）'
Assert-T9197 -Condition ($T9197Targets -match '(?i)accuracy and completeness always win') '前置文: 正確さ・網羅性が最優先だと明示する'
Assert-T9197 -Condition ($T9197Targets -match '(?i)exceed it') '前置文: 収まらなければ超えてよいと明示する'

$T9197NoTargetItems = @([pscustomobject]@{ Index = 1; MaxChars = $null })
Assert-T9197 -Condition ((New-YakuCatCharacterTargets -Items $T9197NoTargetItems) -eq 'No character targets apply.') '目標が1件も無ければ固定文だけを返す'

# --- 雛形のプレースホルダ展開・cat雛形の既存文言と矛盾しないこと -----------
foreach ($T9197Direction in @('to_en', 'to_jp')) {
    $T9197TemplateName = if ($T9197Direction -eq 'to_en') { 'cat_translate_to_en.txt' } else { 'cat_translate_to_jp.txt' }
    $T9197TemplateText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $YakuT9197Root 'prompts') $T9197TemplateName))
    Assert-T9197 -Condition ($T9197TemplateText.Contains('{character_targets}')) ($T9197TemplateName + ' が character_targets のプレースホルダを持つ')
    Assert-T9197 -Condition ($T9197TemplateText.Contains('Do not abbreviate') -or $T9197TemplateText.Contains('Do not summarize')) ($T9197TemplateName + ' の情報保持の指示が残っている（矛盾しない前提）')
}

$T9197Settings = Read-YakuSettings -Root $YakuT9197Root
$T9197PromptItems = @(
    [pscustomobject]@{ Index = 1; Text = 'Net sales were [[N1]] million yen.'; MaskedText = 'Net sales were [[N1]] million yen.'; Terminology = @(); MaxChars = 42 }
    [pscustomobject]@{ Index = 2; Text = 'No amount here.'; MaskedText = 'No amount here.'; Terminology = @(); MaxChars = $null }
)
$T9197Prompt = New-YakuCatPrompt -Root $YakuT9197Root -Items $T9197PromptItems -Settings $T9197Settings -Direction 'to_en' -RequestId 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
Assert-T9197 -Condition ($T9197Prompt.Contains('===CHARACTER_TARGETS:a1b2c3d4e5f60718293a4b5c6d7e8f90===')) 'CHARACTER_TARGETSの区切りが展開される'
Assert-T9197 -Condition ($T9197Prompt -match '"item":1,"approximate_max_chars":42') 'item 1の目標42が本文に出る'
Assert-T9197 -Condition ($T9197Prompt -notmatch '"item":2,') '目標の無いitem 2は列挙されない'
# 原文の実額（120）はマスク済みitem.Textには決して現れない。ここで登場する
# 唯一の生数値は、CHARACTER_TARGETSの42（幅の目標。数値マスクの対象外、
# V9187と同じ8..99の安全な2桁）だけであることを確かめる
# （出典: cat.js 側で 8..99 へクランプ済み。V9187CompactionBudgetの
# 「伏せた数値の扱いは変えていない」試験と同じ考え方）。
Assert-T9197 -Condition ($T9197Prompt.Contains('[[N1]]')) '原文の金額はトークンのまま出る（伏せたまま）'
Assert-T9197 -Condition (-not ($T9197Prompt -match '(?<![0-9])120(?![0-9])')) '伏せた実額（120）は本文のどこにも出ない'

# ============================================================ 配線（サーバ側ソース）
Write-Host '-- Server.ps1 配線 --'

$T9197ServerText = [System.IO.File]::ReadAllText((Join-Path $YakuT9197Src 'Server.ps1'))
Assert-T9197 -Condition ($T9197ServerText.Contains('ConvertTo-YakuCatValidFitTargets')) 'translateアクションがfit_targetsを検証関数へ通す'
# 単なる文字列一致は「実際に呼ばれているか」を証明しない（コメントに名前を
# 書くだけでも通ってしまう。CoD審査 2026-08-18 REWORK-1 の指摘。MEDIUM-1）。
# ここでは実際の呼び出し形（-RawItems 引数付き）を固定し、この関数が確かに
# 呼ばれていることの根拠にする。配線が本当に効くかどうかは、この関数自体を
# 上の (c) 節で end-to-end に検証している（呼ばれているかはここ、正しく
# 動くかはそちら、で役割を分ける）。
Assert-T9197 -Condition ($T9197ServerText -match 'ConvertTo-YakuCatDedupedItems\s+-RawItems\b') 'workerが重複排除・複製の畳み方を共通関数（ConvertTo-YakuCatDedupedItems）へ実際に渡している'
Assert-T9197 -Condition ($T9197ServerText -match "幅の目標を \`$fitTargetRowCount 行に添えています") '翻訳開始時の進捗detailに1行添える文言がある'
# 進捗detailの件数は「畳んだ後」でなければならない（畳んだ前の生の件数で
# 数えると、複製で目標が消えた行まで「添えた」と言ってしまう。CoD審査
# 2026-08-18 REWORK-1 の指摘。LOW-3）。畳んだ結果（$items）から数えている
# ことをソースの並び順で確かめる: 件数計算が dedupe 呼び出しより後にある。
$T9197DedupeCallAt = $T9197ServerText.IndexOf('ConvertTo-YakuCatDedupedItems -RawItems')
$T9197CountAt = $T9197ServerText.IndexOf('$fitTargetRowCount = 0')
Assert-T9197 -Condition ($T9197DedupeCallAt -ge 0 -and $T9197CountAt -gt $T9197DedupeCallAt) '幅の目標の行数は、重複排除で畳んだ後に数えている（畳む前の生の件数ではない）'
Assert-T9197 -Condition ($T9197ServerText -match '\$countedEntry\.MaxChars') '行数の数え方が畳んだ後のitemのMaxChars（$null=目標消滅）を見ている'
Assert-T9197 -Condition ($T9197ServerText.Contains("mode = `$catMode; amount_notation = (Get-YakuCatProjectAmountNotation -Project `$project)")) 'catJson構築のピン（Smoke-Test.ps1:388-390）を壊していない'

# CatBatch.ps1のCATプロンプト生成経路は増やしていない
# （V9161CorpusReference.ps1:265-266 が正確に3箇所を固定する。ここでも
# 同じ数を確かめ、この機能の変更で崩れていないことを明示的に見る）。
$T9197CatBatchText = [System.IO.File]::ReadAllText((Join-Path $YakuT9197Src 'CatBatch.ps1'))
$T9197CatPromptCalls = @(($T9197CatBatchText -split '\r?\n') | Where-Object { [string]$_ -match 'New-YakuProtectedPromptPackage\s+-Kind\s+cat\b' })
Assert-T9197 -Condition ($T9197CatPromptCalls.Count -eq 3) ('CATプロンプトの生成経路を増やしていない（実測 ' + $T9197CatPromptCalls.Count + ' 箇所）')

# キャッシュ契約の版に足した印（実際の再利用可否は変えていない。理由は
# Get-YakuCatCacheStyleの註を参照）。V9161CatProject.ps1:448 が固定する
# reference:none は保つ。
$T9197CacheStyle = Get-YakuCatCacheStyle
Assert-T9197 -Condition ($T9197CacheStyle -match 'reference:none') 'キャッシュ契約のピン（reference:none）を壊していない'
Assert-T9197 -Condition ($T9197CacheStyle -match 'fit-target:v1') 'キャッシュ契約の版へ文字目標の印を足した'

Write-Host ''
if ($script:T9197Failures.Count -gt 0) {
    Write-Host ("FAIL " + $script:T9197Failures.Count + ' assertion(s) in static part')
    foreach ($YakuT9197F in $script:T9197Failures) { Write-Host ('  - ' + $YakuT9197F) }
    exit 1
}

# ============================================================ (e) 実機Chromium部
Write-Host '-- chromium --'

$YAKU_WIDTH_UNMEASURED = 3
$T9197Driver = Join-Path $PSScriptRoot 'width-screen\width-screen-gate.js'
$T9197Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $T9197Node -or -not (Test-Path -LiteralPath $T9197Driver -PathType Leaf)) {
    Write-Host 'UNMEASURED: node または Chromium 運転席が無いため実機を測れません。' -ForegroundColor Red
    exit $YAKU_WIDTH_UNMEASURED
}
$T9197NodeExe = [string]$T9197Node.Source
$T9197ProbeDir = (Split-Path -Parent $T9197Driver).Replace('\', '/')
$null = & $T9197NodeExe -e ("try{require.resolve('playwright',{paths:['" + $T9197ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が無いため実機を測れません。' -ForegroundColor Red
    exit $YAKU_WIDTH_UNMEASURED
}
$T9197ChromiumPath = & $T9197NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $T9197ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
$T9197ChromiumExit = $LASTEXITCODE
if ($T9197ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$T9197ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$T9197ChromiumPath) -PathType Leaf)) {
    Write-Host 'UNMEASURED: Playwright Chromium 実行ファイルが無いため実機を測れません。' -ForegroundColor Red
    exit $YAKU_WIDTH_UNMEASURED
}

# --- 題材を組む ------------------------------------------------------------
# 列は previewColumnPx と同じ式（max(24, round(width*7+5))）で手計算した。
#   A(1,width2)=24px 単独（below-min想定）        B(2,width50) 占有で止める
#   D(4,width15)=110px + E(5,width50)=355px = 465px（measured想定）  F(6) 占有で止める
#   H(8,width90)=635px + I(9,width50)=355px + J(10,width50)=355px = 1345px（above-max想定）  K(11) 占有で止める
#   M(13) wrap=true（ゲートで除外）                N(14,width50) 開いていても無関係
#   P(16) shrink=true（ゲートで除外）              Q(17,width50) 同上
#   R=18列は unknown_width_columns（既知幅ではないので除外）
#   T(20,width90)=635px 単独・右寄せ（自動spillを使わない想定）  U(21,width50) 開いている・V(22) 占有で
#   歩きを止める（占有が遠すぎるとシート全体のlastContentColumnがUより手前で
#   切れてしまい、寄せゲートを外しても歩き自体が始まらず突然変異が見えなく
#   なる。V を占有にして初めて「歩けるのに寄せで足さない」を検証できる）
#   W(23) は訳文が既にある行（訳す対象ではないので目標も対象外）
$T9197Segments = @(
    [ordered]@{ index = 0; segment_id = 'w-below'; source = 'src below'; translation = ''; kind = 'cell'; location = 'Width1, A1'; confirmed = $false }
    [ordered]@{ index = 1; segment_id = 'w-measured'; source = 'src measured'; translation = ''; kind = 'cell'; location = 'Width1, D1'; confirmed = $false }
    [ordered]@{ index = 2; segment_id = 'w-above'; source = 'src above'; translation = ''; kind = 'cell'; location = 'Width1, H1'; confirmed = $false }
    [ordered]@{ index = 3; segment_id = 'w-wrap'; source = 'src wrap'; translation = ''; kind = 'cell'; location = 'Width1, M1'; confirmed = $false }
    [ordered]@{ index = 4; segment_id = 'w-shrink'; source = 'src shrink'; translation = ''; kind = 'cell'; location = 'Width1, P1'; confirmed = $false }
    [ordered]@{ index = 5; segment_id = 'w-unknown'; source = 'src unknown'; translation = ''; kind = 'cell'; location = 'Width1, R1'; confirmed = $false }
    [ordered]@{ index = 6; segment_id = 'w-rightalign'; source = 'src right align'; translation = ''; kind = 'cell'; location = 'Width1, T1'; confirmed = $false }
    [ordered]@{ index = 7; segment_id = 'w-alreadytranslated'; source = 'src already'; translation = 'already translated text here'; kind = 'cell'; location = 'Width1, W1'; confirmed = $false }
)
$T9197SheetLayout = [ordered]@{
    name = 'Width1'; default_width = 8.43; default_height = 18.75
    columns = @(
        [ordered]@{ min = 1; max = 1; width = 2; hidden = $false }
        [ordered]@{ min = 2; max = 2; width = 50; hidden = $false }
        [ordered]@{ min = 4; max = 4; width = 15; hidden = $false }
        [ordered]@{ min = 5; max = 5; width = 50; hidden = $false }
        [ordered]@{ min = 6; max = 6; width = 50; hidden = $false }
        [ordered]@{ min = 8; max = 8; width = 90; hidden = $false }
        [ordered]@{ min = 9; max = 9; width = 50; hidden = $false }
        [ordered]@{ min = 10; max = 10; width = 50; hidden = $false }
        [ordered]@{ min = 11; max = 11; width = 50; hidden = $false }
        [ordered]@{ min = 13; max = 13; width = 50; hidden = $false }
        [ordered]@{ min = 14; max = 14; width = 50; hidden = $false }
        [ordered]@{ min = 16; max = 16; width = 50; hidden = $false }
        [ordered]@{ min = 17; max = 17; width = 50; hidden = $false }
        [ordered]@{ min = 20; max = 20; width = 90; hidden = $false }
        [ordered]@{ min = 21; max = 21; width = 50; hidden = $false }
        [ordered]@{ min = 22; max = 22; width = 50; hidden = $false }
        [ordered]@{ min = 23; max = 23; width = 50; hidden = $false }
    )
    unknown_width_columns = @([ordered]@{ min = 18; max = 18; hidden = $false })
    merges = @()
    occupied_cells = @('B1', 'F1', 'K1', 'V1')
    formula_cells = @()
    rows = @()
    cells = @(
        [ordered]@{ address = 'M1'; wrap = $true }
        [ordered]@{ address = 'P1'; shrink = $true }
        [ordered]@{ address = 'T1'; align = 'right' }
    )
}
$T9197MainProject = [ordered]@{
    id = 'width-main-9197'; revision = 1; file_name = 'width.xlsx'; document_format = 'xlsx'; direction = 'to_en'
    untranslated = 7
    segments = $T9197Segments
    sheet_layout = @($T9197SheetLayout)
}
$T9197EmptyProject = [ordered]@{
    id = 'width-empty-9197'; revision = 1; file_name = 'width-empty.xlsx'; document_format = 'xlsx'; direction = 'to_en'
    untranslated = 1
    segments = @([ordered]@{ index = 0; segment_id = 'e-nolayout'; source = 'src no layout'; translation = ''; kind = 'cell'; location = 'NoSheet, A1'; confirmed = $false })
    sheet_layout = @()
}
$T9197Payload = [ordered]@{ main = $T9197MainProject; empty = $T9197EmptyProject }

$T9197Tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-width-9197-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $T9197Tmp -Force
$T9197PayloadPath = Join-Path $T9197Tmp 'payload.json'
$T9197OutPath = Join-Path $T9197Tmp 'out.json'
($T9197Payload | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath $T9197PayloadPath -Encoding UTF8

$T9197WwwDir = Join-Path $YakuT9197Root 'www'
& $T9197NodeExe $T9197Driver $T9197WwwDir $T9197PayloadPath $T9197OutPath
$T9197DriverExit = $LASTEXITCODE
$T9197Out = $null
if (Test-Path -LiteralPath $T9197OutPath -PathType Leaf) { $T9197Out = Get-Content -LiteralPath $T9197OutPath -Raw -Encoding UTF8 | ConvertFrom-Json }

$script:T9197ChromiumFailures = New-Object System.Collections.Generic.List[string]
function Assert-T9197Chromium {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9197ChromiumFailures.Add($Message) | Out-Null }
}

Assert-T9197Chromium -Condition ($null -ne $T9197Out) '運転席が結果ファイルを書き出す'
if ($null -ne $T9197Out) {
    Assert-T9197Chromium -Condition (@($T9197Out.errors).Count -eq 0) ('ページ例外が無い（実測: ' + ((@($T9197Out.errors)) -join ' | ') + '）')
    Assert-T9197Chromium -Condition (@($T9197Out.console).Count -eq 0) ('console.error が無い（実測: ' + ((@($T9197Out.console)) -join ' | ') + '）')
    Assert-T9197Chromium -Condition ([string]::IsNullOrWhiteSpace([string]$T9197Out.fatal)) ('致命的エラーが無い（実測: ' + [string]$T9197Out.fatal + '）')

    function Get-T9197FitTargetsMap {
        param($Body)
        $map = @{}
        if ($null -eq $Body) { return $map }
        if (-not ($Body.PSObject.Properties.Name -contains 'fit_targets')) { return $map }
        foreach ($row in @($Body.fit_targets)) { $map[[int]$row.index] = [int]$row.max_chars }
        return $map
    }

    $T9197BulkMap = Get-T9197FitTargetsMap -Body $T9197Out.bulkBody
    Assert-T9197Chromium -Condition ($null -ne $T9197Out.bulkBody -and [string]$T9197Out.bulkBody.mode -eq 'translate' -and -not ($T9197Out.bulkBody.PSObject.Properties.Name -contains 'index')) '一括翻訳のbodyはindexを持たない（従来どおり全件対象）'

    # below-min（index0）・above-max（index2）: 実測がその環境の書体でも
    # 境界の外であれば送らない。万一その環境の平均字幅で境界内に収まって
    # いたら、送られた値がoracleと一致することを見る（環境依存の数値を
    # ここで決め打ちしない）。
    if ([bool]$T9197Out.oracleBelowMin.inRange) {
        Assert-T9197Chromium -Condition ($T9197BulkMap.ContainsKey(0) -and $T9197BulkMap[0] -eq [int]$T9197Out.oracleBelowMin.raw) 'below-min想定の行がこの環境ではoracleと一致して送られる'
    } else {
        Assert-T9197Chromium -Condition (-not $T9197BulkMap.ContainsKey(0)) '既知幅でも生の容量が8を下回る行は送らない（20字下限へ切り上げない）'
    }
    if ([bool]$T9197Out.oracleAboveMax.inRange) {
        Assert-T9197Chromium -Condition ($T9197BulkMap.ContainsKey(2) -and $T9197BulkMap[2] -eq [int]$T9197Out.oracleAboveMax.raw) 'above-max想定の行がこの環境ではoracleと一致して送られる'
    } else {
        Assert-T9197Chromium -Condition (-not $T9197BulkMap.ContainsKey(2)) '生の容量が99を超える行は99へクランプせず送らない'
    }
    # measured（index1）: 8..99に収まる設計。oracleと厳密一致することを見る。
    Assert-T9197Chromium -Condition ($T9197BulkMap.ContainsKey(1) -and $T9197BulkMap[1] -eq [int]$T9197Out.oracleMeasured.raw) ('既知幅・非wrap・非shrinkの行はoracleと一致する実測値を送る（実測 ' + $(if ($T9197BulkMap.ContainsKey(1)) { $T9197BulkMap[1] } else { '(無し)' }) + ' / oracle ' + [int]$T9197Out.oracleMeasured.raw + '）')
    Assert-T9197Chromium -Condition (-not $T9197BulkMap.ContainsKey(3)) 'wrapの行は目標を送らない'
    Assert-T9197Chromium -Condition (-not $T9197BulkMap.ContainsKey(4)) 'shrinkの行は目標を送らない'
    Assert-T9197Chromium -Condition (-not $T9197BulkMap.ContainsKey(5)) '未知幅の列は目標を送らない'
    # 右寄せ（index6）: 自動spillを足さない。足していたら値が上振れてoracleと
    # 食い違う（oracleRightAlignOwnOnly＝自列のみ）ので、それと一致することで
    # 「寄せゲート」が効いていることを確かめる。
    Assert-T9197Chromium -Condition ($T9197BulkMap.ContainsKey(6) -and $T9197BulkMap[6] -eq [int]$T9197Out.oracleRightAlignOwnOnly.raw) '右寄せの行は自動spillを足さない自列だけの幅で計算する'
    Assert-T9197Chromium -Condition (-not $T9197BulkMap.ContainsKey(7)) '訳文が既にある行は対象にしない'

    # translateRow（この行だけ訳す, index=1）は、その1件だけを積む。
    $T9197RowMap = Get-T9197FitTargetsMap -Body $T9197Out.rowBody
    Assert-T9197Chromium -Condition ($null -ne $T9197Out.rowBody -and [int]$T9197Out.rowBody.index -eq 1) 'この行だけ訳す経路がindex=1を指定する'
    Assert-T9197Chromium -Condition ($T9197RowMap.Count -eq 1 -and $T9197RowMap.ContainsKey(1) -and $T9197RowMap[1] -eq [int]$T9197Out.oracleMeasured.raw) 'この行だけ訳す経路はその1行だけのfit_targetsを積む'

    # 目標が1件も出せない資料（層が無い）: fit_targets自体を省略する。
    Assert-T9197Chromium -Condition ($null -ne $T9197Out.emptyBody -and -not ($T9197Out.emptyBody.PSObject.Properties.Name -contains 'fit_targets')) '目標が1件も無ければbodyにfit_targets自体を付けない'
}

Write-Host ''
if ($T9197DriverExit -ne 0 -and $script:T9197ChromiumFailures.Count -eq 0) {
    # 運転席そのものが失敗コードを返したが、書き出した結果からは何も
    # 拾えなかった場合。中身が見えないまま安全側の失敗として扱う。
    Write-Host ('FAIL width-screen-gate.js exited ' + $T9197DriverExit + ' with no diagnosable output')
    exit 1
}
if ($script:T9197ChromiumFailures.Count -gt 0) {
    Write-Host ("FAIL " + $script:T9197ChromiumFailures.Count + ' chromium assertion(s)')
    foreach ($YakuT9197F in $script:T9197ChromiumFailures) { Write-Host ('  - ' + $YakuT9197F) }
    exit 1
}
Write-Host 'PASS Test-YakuV9197WidthTargets'
exit 0
