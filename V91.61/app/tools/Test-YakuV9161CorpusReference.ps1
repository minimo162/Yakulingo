<#
.SYNOPSIS
  V91.61 段階3: 参考資料コーパスを翻訳へ渡す経路の回帰テスト。

.DESCRIPTION
  検索語の取り出し・文例の伏せ字・プロンプトへの差し込み・適用範囲を検証する。
  Copilot への往復は差し替えて確かめる（実機の Edge には接続しない）。

  この段階を作る理由は、現状の翻訳が網羅的でない用語集に依存していること
  （_docs/要件整理_汎用翻訳アプリとRAG翻訳.md §3-1）。詳細は
  _docs/V91.61_段階3_コーパス翻訳.md を参照。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CorpusReference.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-cr-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$prevData = [string]$env:YAKULINGO_DATA_DIR
$prevCorpus = [string]$env:YAKULINGO_CORPUS_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $work 'data'
Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue

try {
foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','FileTranslation.ps1','Corpus.ps1','CorpusSearch.ps1','CorpusReference.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$settings = Read-YakuSettings -Root $root

# ---------------------------------------------------------------- 適用範囲
Write-Host '適用範囲'
Chk (Test-YakuCorpusReferenceApplicable -Direction 'to_en') 'JA→EN では使う'
Chk (-not (Test-YakuCorpusReferenceApplicable -Direction 'to_jp')) 'EN→JA では使わない（コーパスは英語側だけ）'
Chk (-not (Test-YakuCorpusReferenceApplicable -Direction '')) '方向が空なら使わない'

# ---------------------------------------------------------------- 検索語の取り出し
Write-Host '検索語の取り出し'
$t1 = @(Get-YakuCorpusQueryTerms -Answer "SEARCH_TERMS: equity ratio retained earnings`nYAKULINGO_END:abc")
Chk ($t1.Count -eq 4) ('ラベル行から取れる: ' + ($t1 -join ' '))
Chk ($t1[0] -eq 'equity') '並びを保つ'
$t2 = @(Get-YakuCorpusQueryTerms -Answer 'The relevant terms would be: operating income and shipment volume.')
Chk ($t2 -contains 'operating') 'ラベルが無くても英語の語を拾う'
Chk (-not ($t2 -contains 'and')) '機能語は落ちる'
Chk (@(Get-YakuCorpusQueryTerms -Answer 'SEARCH_TERMS:').Count -eq 0) '空の答えは0語'
Chk (@(Get-YakuCorpusQueryTerms -Answer '売上高と営業利益').Count -eq 0) '日本語だけなら0語'
Chk (@(Get-YakuCorpusQueryTerms -Answer $null).Count -eq 0) 'null でも落ちない'
$t3 = @(Get-YakuCorpusQueryTerms -Answer 'SEARCH_TERMS: equity equity equity ratio')
Chk ($t3.Count -eq 2) '同じ語は重ねない'
$many = 'SEARCH_TERMS: ' + ((1..30 | ForEach-Object { 'term' + $_ }) -join ' ')
Chk (@(Get-YakuCorpusQueryTerms -Answer $many).Count -le 12) '検索語には上限がある'
# 実機の Copilot は検索語と終端マーカーを同じ行に返すことがある（2026-08-05 実測）。
$sameLine = @(Get-YakuCorpusQueryTerms -Answer 'SEARCH_TERMS: full year outlook foreign exchange YAKULINGO_END:deadbeef')
Chk ($sameLine -contains 'outlook') '終端マーカーが同じ行に来ても取れる'

# ---------------------------------------------------------------- 応答の受け取り契約
# ここが素通しになっていたため、段階3 は出荷状態で一度も成立していなかった。
# Copilot は正しく答えていたのに、labeled 契約が SEARCH_TERMS を知らず、
# 候補として認めないまま待ち続けて時間切れになっていた。
# 往復を差し替える回帰では実際の契約を通らないので、契約そのものを読んで確かめる。
Write-Host '応答の受け取り契約'
$clientText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CopilotClient.ps1'))

# プロンプトが Copilot に出させるラベルを、当てずっぽうではなく prompts から集める。
# 入力側の枠と終端マーカーは出力ラベルではないので除く。
$frameLabels = @('SOURCE_BEGIN','SOURCE_END','SOURCE_ITEMS_END','YAKULINGO_END','YAKULINGO_OK','YAKULINGO_DONE')
$askedLabels = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'prompts') -Filter '*.txt')) {
    $body = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($body, '(?m)^\s*([A-Z][A-Z_]{3,})\s*:')) {
        $name = [string]$m.Groups[1].Value
        if ($frameLabels -contains $name) { continue }
        if (-not $askedLabels.Contains($name)) { [void]$askedLabels.Add($name) }
    }
}
Chk ($askedLabels.Count -ge 4) ('prompts が出させるラベルを集められた: ' + ($askedLabels -join ', '))
Chk ($askedLabels -contains 'SEARCH_TERMS') 'コーパス検索語のラベルが含まれている'

$labelReLine = [regex]::Match($clientText, '(?m)^const labelRe = .*$').Value
$startLabelReLine = [regex]::Match($clientText, '(?m)^const startLabelRe = .*$').Value
$usefulBlock = [regex]::Match($clientText, '(?s)const hasUsefulLabeledOutput = \(text\) => \{.*?\n\};').Value
Chk (-not [string]::IsNullOrWhiteSpace($labelReLine)) 'labelRe を見つけられる'
Chk (-not [string]::IsNullOrWhiteSpace($usefulBlock)) 'hasUsefulLabeledOutput を見つけられる'
foreach ($name in $askedLabels) {
    Chk ($labelReLine -match [regex]::Escape($name)) ('labelRe が ' + $name + ' を知っている')
    Chk ($usefulBlock -match [regex]::Escape($name)) ('hasUsefulLabeledOutput が ' + $name + ' を扱う')
}
Chk ($startLabelReLine -match 'SEARCH_TERMS') 'startLabelRe が SEARCH_TERMS を知っている（答えの切り出しに要る）'

# ---------------------------------------------------------------- 文例の伏せ字
Write-Host '文例の数字を伏せる'
$red = ConvertTo-YakuCorpusExampleText -Text 'Operating income increased 12.3% to 45,600 million yen in 2026.'
Chk ($red -notmatch '\d') '数字が残らない'
Chk ($red -match 'Operating income increased') '言い回しは残る'
Chk ($red -notmatch '【N\d') 'V91.60 のプレースホルダー形式は使わない（原文側と名前空間が衝突するため）'
Chk ((ConvertTo-YakuCorpusExampleText -Text '') -eq '') '空文字でも落ちない'

# ---------------------------------------------------------------- 文例の組み立て
Write-Host '文例の組み立て'
$hits = @(
    [pscustomobject]@{ Score=3.0; Database='英文短信'; Source='英文短信/2027-1Q_en.pdf'; Page=3; Text='The equity ratio improved to 45.6% as retained earnings accumulated.' }
    [pscustomobject]@{ Score=2.0; Database='英文短信'; Source='英文短信/2026-4Q_en.pdf'; Page=1; Text='Operating income rose 12,340 million yen on higher shipment volumes.' }
)
$section = Get-YakuCorpusExampleSection -Hits $hits
Chk ($section -match 'CORPUS_EXAMPLES') '見出しが付く'
Chk ($section -match '2027-1Q_en\.pdf p\.3') '出典とページが付く（あとで確かめられる）'
Chk ($section -notmatch '45\.6') '本文の数字は伏せられている'
Chk ($section -match 'equity ratio improved') '言い回しは見える'
Chk ($section -match 'never be copied') '数字を写すなと明示している'
Chk ((Get-YakuCorpusExampleSection -Hits @()) -eq '') '0件なら空'
Chk ((Get-YakuCorpusExampleSection -Hits $null) -eq '') 'null でも空'
$long = @([pscustomobject]@{ Score=1.0; Database='db'; Source='db/a.pdf'; Page=1; Text=('word ' * 400) })
$cut = Get-YakuCorpusExampleSection -Hits $long
Chk ($cut.Length -lt 1200) ('長すぎる一節は切り詰める: ' + $cut.Length)
Chk ($cut -match '\.\.\.$') '切ったことが分かる'

# ---------------------------------------------------------------- 検索語生成の依頼
Write-Host '検索語生成の依頼'
$qp = New-YakuCorpusQueryPrompt -Root $root -InputText '当期の自己資本比率は45.6%となった。' -RequestId 'deadbeef'
Chk ($qp -match 'SEARCH_TERMS') '答えの形を指定している'
Chk ($qp -match 'YAKULINGO_END:deadbeef') '終端マーカーが入る'
Chk ($qp -match '当期の自己資本比率') '原文が入る'
Chk ($qp -notmatch 'FULL_TEXT') '翻訳の依頼ではない'

# ---------------------------------------------------------------- 経路全体（Copilot は差し替える）
Write-Host '経路全体'
$corpus = Join-Path $work 'corpus'
$db = Join-Path $corpus '英文短信'
New-Item -ItemType Directory -Path $db -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $db 'tanshin.md'),
    "<!--yaku-page:1-->`n" + ('The equity ratio improved to a comfortable level as retained earnings accumulated over the period. ' * 8))
$manifest = New-YakuCorpusManifest
$manifest['corpus_version'] = '2026-08-05'
$manifest['entries'] = @([pscustomobject]@{ id='aaaaaaaa'; database='英文短信'; source='英文短信/tanshin.pdf'; markdown='英文短信/tanshin.md'; status='ok' })
Write-YakuCorpusManifest -Dir $corpus -Manifest $manifest
$env:YAKULINGO_CORPUS_DIR = $corpus

# Copilot への往復を差し替える。実機の Edge には接続しない。
$script:LastQueryPrompt = ''
function Invoke-YakuCopilotPrompt {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat = 'labeled', [switch]$PreserveEndMarker, $Warnings, $ProgressState)
    $script:LastQueryPrompt = [string]$Prompt
    return "SEARCH_TERMS: equity ratio retained earnings`nYAKULINGO_END:x"
}

$ref = Get-YakuCorpusReference -Root $root -InputText '当期の自己資本比率は45.6%となり、利益剰余金の積み上がりにより改善した。' -Settings $settings -Direction 'to_en' -Warnings $null -ProgressState $null
Chk ($ref.Reason -eq 'ok') ('引けた: ' + $ref.Reason)
Chk ($ref.Count -gt 0) '文例が返る'
Chk ($ref.Used) 'Copilot への往復が発生したことが分かる（新規チャット待ちの判断に使う）'
Chk (@($ref.Terms) -contains 'equity') '検索語が記録される'
Chk ($ref.Section -match 'CORPUS_EXAMPLES') '差し込む文字列ができる'

Write-Host '検索語生成の依頼にも数値マスキングが効くこと'
# ここを素通しにすると V91.60 の「数値を外部へ出さない」保証がこの経路だけ抜ける。
Chk ($script:LastQueryPrompt -notmatch '45\.6') '原文の数値がそのまま送られていない'
Chk ($script:LastQueryPrompt -match '【N\d+】') 'マスク済みの本文が送られている'
Chk ($script:LastQueryPrompt -match '自己資本比率') 'マスク以外の本文は送られている'

Write-Host '使わない条件'
$refJp = Get-YakuCorpusReference -Root $root -InputText 'The equity ratio improved.' -Settings $settings -Direction 'to_jp' -Warnings $null -ProgressState $null
Chk ($refJp.Reason -eq 'direction') 'EN→JA では引かない'
Chk (-not $refJp.Used) 'EN→JA では Copilot への往復も発生しない'
Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue
$refNone = Get-YakuCorpusReference -Root $root -InputText '自己資本比率' -Settings $settings -Direction 'to_en' -Warnings $null -ProgressState $null
Chk ($refNone.Reason -eq 'no-corpus') 'コーパスが無ければ引かない'
Chk (-not $refNone.Used) 'コーパスが無ければ往復も発生しない（無駄に1回増やさない）'
$env:YAKULINGO_CORPUS_DIR = $corpus

function Invoke-YakuCopilotPrompt { param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat = 'labeled', [switch]$PreserveEndMarker, $Warnings, $ProgressState) return 'SEARCH_TERMS:' }
$refNoTerms = Get-YakuCorpusReference -Root $root -InputText '自己資本比率' -Settings $settings -Direction 'to_en' -Warnings $null -ProgressState $null
Chk ($refNoTerms.Reason -eq 'no-terms') '検索語が作れなければ素通し'

function Invoke-YakuCopilotPrompt { param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat = 'labeled', [switch]$PreserveEndMarker, $Warnings, $ProgressState) return 'SEARCH_TERMS: zzzznotpresent' }
$refNoHits = Get-YakuCorpusReference -Root $root -InputText '自己資本比率' -Settings $settings -Direction 'to_en' -Warnings $null -ProgressState $null
Chk ($refNoHits.Reason -eq 'no-hits') '当たらなければ素通し'

function Invoke-YakuCopilotPrompt { param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat = 'labeled', [switch]$PreserveEndMarker, $Warnings, $ProgressState) throw 'Copilot unreachable' }
$refErr = Get-YakuCorpusReference -Root $root -InputText '自己資本比率' -Settings $settings -Direction 'to_en' -Warnings $null -ProgressState $null
Chk ($refErr.Reason -eq 'error') '往復が失敗しても投げない'
Chk ($refErr.Section -eq '') '失敗時は空を返す（従来どおり訳せる）'

# ---------------------------------------------------------------- プロンプトへの差し込み
Write-Host 'プロンプトへの差し込み'
$sec = "CORPUS_EXAMPLES: test`n[1] db/a.pdf p.1`nThe equity ratio improved."
$withCorpus = New-YakuTextPrompt -Root $root -InputText '自己資本比率は改善した。' -Settings $settings -DirectionOverride 'to_en' -RequestId 'aaaa' -CorpusSection $sec
Chk ($withCorpus.Prompt -match 'CORPUS_EXAMPLES') 'to_en のプロンプトへ入る'
Chk ($withCorpus.Prompt -match 'The equity ratio improved\.') '文例の本文が入る'
$withoutCorpus = New-YakuTextPrompt -Root $root -InputText '自己資本比率は改善した。' -Settings $settings -DirectionOverride 'to_en' -RequestId 'aaaa'
Chk ($withoutCorpus.Prompt -notmatch 'CORPUS_EXAMPLES') '渡さなければ入らない'
Chk ($withoutCorpus.Prompt -notmatch '\{corpus_section\}') '枠が展開されずに残らない'
$jpPrompt = New-YakuTextPrompt -Root $root -InputText 'The equity ratio improved.' -Settings $settings -DirectionOverride 'to_jp' -RequestId 'aaaa' -CorpusSection $sec
Chk ($jpPrompt.Prompt -notmatch 'CORPUS_EXAMPLES') 'to_jp のテンプレートには枠が無いので入らない'

# ---------------------------------------------------------------- 画面への表示
Write-Host '何を参照したかを画面へ出す'
# 出典が見えないと、訳語がどこから来たのか確かめようがない。
$resultWith = [pscustomobject]@{
    CorpusExamples = @(
        [pscustomobject]@{ Database='英文短信'; Source='英文短信/2027-1Q_en.pdf'; Page=3; Text='The equity ratio improved to #%.' }
    )
    CorpusTerms = @('equity','ratio')
}
$refHtml = New-YakuCorpusReferenceHtml -Result $resultWith
Chk ($refHtml -match '参照した社内資料') '見出しが出る'
Chk ($refHtml -match '2027-1Q_en\.pdf p\.3') '出典とページが出る'
Chk ($refHtml -match 'equity ratio') '使った検索語も見える（入力と違うことがあるため）'
Chk ($refHtml -match 'The equity ratio improved') '参照した本文を確かめられる'
Chk ($refHtml -match '伏せて送っています') '数字を伏せたことを明示する'
Chk ($refHtml -match "<details") '既定では畳んでおく（普段は視界に入れない）'
Chk ($refHtml -notmatch '<script') 'HTML を素通ししない'
$resultNone = [pscustomobject]@{ CorpusExamples = @(); CorpusTerms = @() }
Chk ((New-YakuCorpusReferenceHtml -Result $resultNone) -eq '') '引けなければ何も出さない（利用者は仕組みを知らない）'
Chk ((New-YakuCorpusReferenceHtml -Result ([pscustomobject]@{})) -eq '') '項目が無くても落ちない'
$escaped = New-YakuCorpusReferenceHtml -Result ([pscustomobject]@{
    CorpusExamples = @([pscustomobject]@{ Database='db'; Source='<img src=x>'; Page=1; Text='<b>bold</b>' }); CorpusTerms=@() })
Chk ($escaped -notmatch '<img') '出典を逃がしている'
Chk ($escaped -notmatch '<b>bold') '本文を逃がしている'

Write-Host '引いた結果に参照した箇所が入る'
$env:YAKULINGO_CORPUS_DIR = $corpus
function Invoke-YakuCopilotPrompt { param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat = 'labeled', [switch]$PreserveEndMarker, $Warnings, $ProgressState) return 'SEARCH_TERMS: equity ratio' }
$refEx = Get-YakuCorpusReference -Root $root -InputText '自己資本比率' -Settings $settings -Direction 'to_en' -Warnings $null -ProgressState $null
Chk (@($refEx.Examples).Count -gt 0) '参照した一節が戻る'
Chk (@($refEx.Examples)[0].Text -notmatch '\d') '画面へ出す本文も数字が伏せてある（送ったものと同じ）'
Chk (-not [string]::IsNullOrWhiteSpace([string]@($refEx.Examples)[0].Source)) '出典が入る'
$refNoneEx = Get-YakuCorpusReference -Root $root -InputText 'x' -Settings $settings -Direction 'to_jp' -Warnings $null -ProgressState $null
Chk (@($refNoneEx.Examples).Count -eq 0) '使わなかったときは空（呼び出し側で場合分けしない）'

# ---------------------------------------------------------------- 触っていないこと
Write-Host 'ファイル翻訳を触っていないこと'
$fileText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'FileTranslation.ps1'))
Chk ($fileText -notmatch 'CorpusSection') 'ファイル翻訳へは差し込まない'
Chk ($fileText -notmatch 'Get-YakuCorpusReference') 'ファイル翻訳はコーパスを引かない'
$fileTemplate = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'prompts') 'file_translate_to_en.txt'))
Chk ($fileTemplate -notmatch 'corpus_section') 'ファイル用テンプレートに枠を足していない'
$jpTemplate = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'prompts') 'text_translate_to_jp.txt'))
Chk ($jpTemplate -notmatch 'corpus_section') 'to_jp のテンプレートにも足していない'

Write-Host '設定項目を増やしていないこと'
$settingsText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Settings.ps1'))
Chk ($settingsText -notmatch 'corpus') '設定へコーパスの項目を足していない'
$indexHtml = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'index.html'))
Chk ($indexHtml -notmatch 'corpus') '一般利用者の画面にも出さない'

Write-Host 'キャッシュ鍵'
$translationText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Translation.ps1'))
# 文例なしで作った訳文を文例ありの依頼へ返さないため。
Chk ($translationText -match "corpus-v9161:") 'キャッシュ鍵に文例が含まれる'
Chk ($translationText -match 'Get-YakuCorpusReference -Root \$Root -InputText \$processingInput') 'ジョブごとに1回、分割前に引く'

} finally {
    if (-not [string]::IsNullOrWhiteSpace($prevData)) { $env:YAKULINGO_DATA_DIR = $prevData } else { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    if (-not [string]::IsNullOrWhiteSpace($prevCorpus)) { $env:YAKULINGO_CORPUS_DIR = $prevCorpus } else { Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 corpus reference regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 corpus reference regression passed.' -ForegroundColor Green
