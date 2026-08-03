<#
Mini regression corpus for prompt/parser contract.
By default this does not call Copilot. It verifies the v25 plain-text labels,
representative output patterns, glossary matching, and batch prompt style reference wiring.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\Paths.ps1')
. (Join-Path $root 'src\Html.ps1')
. (Join-Path $root 'src\Settings.ps1')
. (Join-Path $root 'src\PromptBuilder.ps1')
. (Join-Path $root 'src\Translation.ps1')
. (Join-Path $root 'src\FileProcessors.ps1')
. (Join-Path $root 'src\FileTranslation.ps1')

function Assert-YakuTrue {
    param(
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$true)][string]$Message
    )
    if (!$Condition) { throw $Message }
}

function Assert-YakuMatch {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [Parameter(Mandatory=$true)][string]$Message
    )
    if ($Text -notmatch $Pattern) { throw $Message }
}

$settings = Read-YakuSettings -Root $root
$contractRequestId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
$jpContract = Test-YakuTextResponseContract -Text ("JAPANESE_TEXT:`n訳文です。`nYAKULINGO_END:$contractRequestId") -Direction 'to_jp' -RequestId $contractRequestId
Assert-YakuTrue -Condition ([bool]$jpContract.Valid) -Message 'to_jp contract must accept a valid JAPANESE_TEXT response'
$enContract = Test-YakuTextResponseContract -Text ("FULL_TEXT:`nFull.`nBRIEF_TEXT:`nBrief.`nYAKULINGO_END:$contractRequestId") -Direction 'to_en' -RequestId $contractRequestId
Assert-YakuTrue -Condition ([bool]$enContract.Valid) -Message 'to_en contract must accept a valid FULL_TEXT/BRIEF_TEXT response'
$jpRecoveredContract = Test-YakuTextResponseContract -Text ("前置き`nJAPANESE_TEXT:`n訳文`nYAKULINGO_END:$contractRequestId") -Direction 'to_jp' -RequestId $contractRequestId
Assert-YakuTrue -Condition ([bool]$jpRecoveredContract.Valid -and [string]$jpRecoveredContract.WarningCode -eq 'RESPONSE_PREFIX_RECOVERED') -Message 'to_jp leading text recovery must carry an explicit warning'
$jpMissingContract = Test-YakuTextResponseContract -Text ("訳文のみ`nYAKULINGO_END:$contractRequestId") -Direction 'to_jp' -RequestId $contractRequestId
Assert-YakuTrue -Condition (-not [bool]$jpMissingContract.Valid) -Message 'to_jp contract must reject a missing label'
$reverseContract = Test-YakuTextResponseContract -Text ("JAPANESE_TEXT:`n訳文`nYAKULINGO_END:$contractRequestId") -Direction 'to_en' -RequestId $contractRequestId
Assert-YakuTrue -Condition (-not [bool]$reverseContract.Valid) -Message 'to_en contract must reject the opposite-direction label'
$translationContractSource = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($translationContractSource.Contains("`$required = @(if (`$Direction -eq 'to_en')") -and $translationContractSource.Contains('CONTRACT_INTERNAL: $required must be an array.')) -Message 'required labels must retain an array type in both directions'
$cases = @(
    [pscustomobject]@{
        Name = 'heading-plus-body'
        Input = "決算ハイライト`n上期の売上は前年同期比で増加しました"
        Direction = 'to_en'
        Raw = "FULL_TEXT:`nEarnings Highlights`n1H sales increased YoY.`nBRIEF_TEXT:`nEarnings Highlights`n1H sales increased YoY.`nYAKULINGO_END"
        FullPattern = 'Earnings Highlights\r?\n1H sales increased YoY\.'
    },
    [pscustomobject]@{
        Name = 'triangle-number'
        Input = '営業利益は▲72千台でした'
        Direction = 'to_en'
        Raw = "FULL_TEXT:`nOperating profit was (72) k units.`nBRIEF_TEXT:`nOperating profit: (72) k units.`nYAKULINGO_END"
        FullPattern = '\(72\) k units'
    },
    [pscustomobject]@{
        Name = 'oku-cho-yen'
        Input = '売上高は1兆円でした'
        Direction = 'to_en'
        Raw = "FULL_TEXT:`nRevenue was 10,000 oku.`nBRIEF_TEXT:`nRevenue: 10,000 oku.`nYAKULINGO_END"
        FullPattern = '10,000 oku'
    },
    [pscustomobject]@{
        Name = 'sentence-without-japanese-period'
        Input = 'これはテストです'
        Direction = 'to_en'
        Raw = "FULL_TEXT:`nThis is a test.`nBRIEF_TEXT:`nTest.`nYAKULINGO_END"
        FullPattern = 'This is a test\.$'
    },
    [pscustomobject]@{
        Name = 'to-japanese'
        Input = 'Please review the latest estimate.'
        Direction = 'to_jp'
        Raw = "JAPANESE_TEXT:`n最新の見積もりを確認してください。`nYAKULINGO_END"
        FullPattern = '最新の見積もり'
    }
)

foreach ($case in $cases) {
    $requestId = [guid]::NewGuid().ToString('N')
    $prompt = New-YakuTextPrompt -Root $root -InputText $case.Input -Settings $settings -DirectionOverride $case.Direction -RequestId $requestId
    Assert-YakuTrue -Condition ($prompt.Prompt.Contains('SOURCE_BEGIN') -and $prompt.Prompt.Contains('SOURCE_END')) -Message "$($case.Name): SOURCE block missing"
    Assert-YakuTrue -Condition ($prompt.Prompt.Contains('YAKULINGO_END')) -Message "$($case.Name): end marker missing"
    Assert-YakuTrue -Condition (!$prompt.Prompt.Contains('<section') -and !$prompt.Prompt.Contains('```json')) -Message "$($case.Name): old parser format leaked into prompt"

    $contractRaw = ([string]$case.Raw).Replace('YAKULINGO_END', ('YAKULINGO_END:' + $requestId))
    $options = @(Parse-YakuTextTranslationResponse -Raw $contractRaw -Direction $case.Direction -RequestId $requestId)
    if ($case.Direction -eq 'to_en') {
        Assert-YakuTrue -Condition ($options.Count -eq 2) -Message "$($case.Name): expected full+brief options, got $($options.Count)"
        Assert-YakuMatch -Text ([string]$options[0].Translation) -Pattern $case.FullPattern -Message "$($case.Name): full text pattern mismatch"
        Assert-YakuTrue -Condition (([string]$options[0].Translation) -notmatch '\([^)]+\s+(k units|oku|%)\)') -Message "$($case.Name): numeric parenthesis scope regression"
    } else {
        Assert-YakuTrue -Condition ($options.Count -eq 1) -Message "$($case.Name): expected one Japanese option, got $($options.Count)"
        Assert-YakuMatch -Text ([string]$options[0].Translation) -Pattern $case.FullPattern -Message "$($case.Name): Japanese text pattern mismatch"
    }
}

$flexRequestId = [guid]::NewGuid().ToString('N')
$flexRaw = "**FULL_TEXT**: Full text on the label line.`n**BRIEF_TEXT**: Brief text on the label line.`n**YAKULINGO_END:$flexRequestId**"
$flexOptions = @(Parse-YakuTextTranslationResponse -Raw $flexRaw -Direction 'to_en' -RequestId $flexRequestId)
Assert-YakuTrue -Condition ($flexOptions.Count -eq 2) -Message 'common bold-label/same-line Copilot response must be accepted'
Assert-YakuTrue -Condition ([string]$flexOptions[0].Translation -eq 'Full text on the label line.') -Message 'same-line FULL_TEXT extraction failed'

$actualRequestId = [guid]::NewGuid().ToString('N')
$actualRaw = ([char]0x200C) + "JAPANESE_TEXT：限定プレビューに続き、完全な翻訳です。 YAKULINGO_END:$actualRequestIdこの会話を停止しました。"
$actualOptions = @(Parse-YakuTextTranslationResponse -Raw $actualRaw -Direction 'to_jp' -RequestId $actualRequestId)
Assert-YakuTrue -Condition ($actualOptions.Count -eq 1 -and [string]$actualOptions[0].Translation -match '完全な翻訳') -Message 'actual V85 response shape must be normalized and accepted'

$decoratedRequestId = [guid]::NewGuid().ToString('N')
$decoratedRaw = "**FULL_TEXT:** Full output.`n**BRIEF_TEXT**： Brief output. **YAKULINGO_END:$decoratedRequestId**"
$decoratedOptions = @(Parse-YakuTextTranslationResponse -Raw $decoratedRaw -Direction 'to_en' -RequestId $decoratedRequestId)
Assert-YakuTrue -Condition ($decoratedOptions.Count -eq 2 -and [string]$decoratedOptions[1].Translation -eq 'Brief output.') -Message 'decorated labels, fullwidth colon, and inline marker must normalize'

$angleRequestId = [guid]::NewGuid().ToString('N')
$angleRaw = "FULL_TEXT:`n＜Operating Profit by Market＞`nValue (72) k units.`nBRIEF_TEXT:`n＜OP by Mkt.＞`nValue (72) k units.`nYAKULINGO_END:$angleRequestId"
$angleOptions = @(Parse-YakuTextTranslationResponse -Raw $angleRaw -Direction 'to_en' -RequestId $angleRequestId)
Assert-YakuTrue -Condition ([string]$angleOptions[0].Translation -match '^<Operating Profit by Market>' -and [string]$angleOptions[1].Translation -match '^<OP by Mkt\.>' -and [string]$angleOptions[0].Translation -match '\(72\) k units') -Message 'to_en full-width angle restoration must preserve numeric parentheses'
$jpAngleRequestId = [guid]::NewGuid().ToString('N')
$jpAngleRaw = "JAPANESE_TEXT:`n＜営業利益＞`nYAKULINGO_END:$jpAngleRequestId"
$jpAngleOptions = @(Parse-YakuTextTranslationResponse -Raw $jpAngleRaw -Direction 'to_jp' -RequestId $jpAngleRequestId)
Assert-YakuTrue -Condition ([string]$jpAngleOptions[0].Translation -eq '＜営業利益＞') -Message 'to_jp must retain full-width angle brackets'

$structureSource = "＜見出し1＞`n■項目A`n【見出し2】`n●項目B"
$structureMatch = Test-YakuTextStructureIntegrity -SourceText $structureSource -FullText "<Heading 1>`n■Item A`n【Heading 2】`n●Item B" -BriefText "<Hd. 1>`n■Item A`n【Hd. 2】`n●Item B"
$structureFullMissing = Test-YakuTextStructureIntegrity -SourceText $structureSource -FullText "<Heading 1>`n■Item A`n●Item B" -BriefText "<Hd. 1>`n■Item A`n【Hd. 2】`n●Item B"
$structureBriefMissing = Test-YakuTextStructureIntegrity -SourceText $structureSource -FullText "<Heading 1>`n■Item A`n【Heading 2】`n●Item B" -BriefText "<Hd. 1>`n■Item A`n●Item B"
$structureSkipped = Test-YakuTextStructureIntegrity -SourceText '通常の短文です。' -FullText 'A normal sentence.' -BriefText 'Normal sentence.'
Assert-YakuTrue -Condition ([bool]$structureMatch.Ok -and -not [bool]$structureMatch.Skipped) -Message 'matching headings and bullets must pass structure integrity'
Assert-YakuTrue -Condition (-not [bool]$structureFullMissing.Ok -and ([string]$structureFullMissing.Detail).Contains('full=1')) -Message 'FULL-only heading loss must fail structure integrity'
Assert-YakuTrue -Condition (-not [bool]$structureBriefMissing.Ok -and ([string]$structureBriefMissing.Detail).Contains('brief=1')) -Message 'BRIEF-only heading loss must fail structure integrity'
Assert-YakuTrue -Condition ([bool]$structureSkipped.Ok -and [bool]$structureSkipped.Skipped) -Message 'ordinary text without structural markers must skip integrity validation'
$numberedMarkdownSource = "### 1. 資金`n### 2. 経理`n### 3. 内部統制"
$numberedMarkdownRepair = Repair-YakuNumberedHeadingSequence -SourceText $numberedMarkdownSource -TranslatedText "1. Funding`n1. Acctg.`n1. Internal Control" -Style 'full'
Assert-YakuTrue -Condition ([bool]$numberedMarkdownRepair.Restored -and ([string]$numberedMarkdownRepair.Text).Contains("2. Acctg.") -and ([string]$numberedMarkdownRepair.Text).Contains("3. Internal Control")) -Message 'V91.24 Markdown-prefixed source headings must be restored from source numbers'
$numberedSource = "1. 資金`n2. 経理`n3. 内部統制"
$numberedRepeated = "1. Funding`n1. Acctg.`n1. Internal Control"
$numberedRepair = Repair-YakuNumberedHeadingSequence -SourceText $numberedSource -TranslatedText $numberedRepeated -Style 'full'
Assert-YakuTrue -Condition ([bool]$numberedRepair.Restored -and ([string]$numberedRepair.Text).Contains("2. Acctg.") -and ([string]$numberedRepair.Text).Contains("3. Internal Control")) -Message 'V91.23 repeated Markdown heading numbers must be restored from source'
$numberedEightSource = ((1..8 | ForEach-Object { "$_. 見出し$_" }) -join "`n")
$numberedEightTarget = ((1..8 | ForEach-Object { "1. Heading $_" }) -join "`n")
$numberedEightRepair = Repair-YakuNumberedHeadingSequence -SourceText $numberedEightSource -TranslatedText $numberedEightTarget -Style 'full'
$numberedEightExpected = ((1..8 | ForEach-Object { "$_. Heading $_" }) -join "`n")
Assert-YakuTrue -Condition ([bool]$numberedEightRepair.Restored -and ([string]$numberedEightRepair.Text -eq $numberedEightExpected) -and ([string]$numberedEightRepair.Text -notmatch '\$1[1-8]')) -Message 'V91.25 heading restoration must use braced regex groups and restore exact numbers 1 through 8'
$numberedMismatch = Repair-YakuNumberedHeadingSequence -SourceText $numberedSource -TranslatedText "1. Funding`n1. Acctg." -Style 'brief'
Assert-YakuTrue -Condition (-not [bool]$numberedMismatch.Restored) -Message 'V91.23 heading restoration must not run when heading counts differ'
$placeholderOk = Test-YakuMaskingPlaceholderIntegrity -SourceText '対象は【非開示】および【第3四半期(3か月)】。' -TranslatedText 'Covered: 【非開示】 and 【Third Quarter (3 months)】.' -Style 'full'
$placeholderMissing = Test-YakuMaskingPlaceholderIntegrity -SourceText '対象は【非開示】。' -TranslatedText 'The item covered is.' -Style 'brief'
Assert-YakuTrue -Condition ([bool]$placeholderOk.Ok -and -not [bool]$placeholderMissing.Ok -and $placeholderMissing.Missing.Count -eq 1) -Message 'V91.23 masking placeholder validation must detect a bare-token omission'


$toEnTemplateV9124 = Get-Content -LiteralPath (Join-Path $root 'prompts\text_translate_to_en.txt') -Raw
Assert-YakuTrue -Condition ($toEnTemplateV9124.Contains('never add a direction word') -and $toEnTemplateV9124.Contains('forecast to reach a further')) -Message 'V91.24 neutral figure wording rule must be present'
Assert-YakuTrue -Condition ($toEnTemplateV9124.Contains('recognized as [account item] under [P/L section]') -and $toEnTemplateV9124.Contains('valuation loss on investment securities under extraordinary losses') -and $toEnTemplateV9124.Contains('never invert hierarchy')) -Message 'V91.27 account-item under P/L-section hierarchy rule must be present'

$twoBatch = @(Split-YakuTextBatches -Text (('第一段落。' * 60) + "`n`n" + ('第二段落。' * 60)) -MaxChars 400)
$threeBatch = @(Split-YakuTextBatches -Text (('第一文です。' * 45) + ('第二文です。' * 45) + ('第三文です。' * 45)) -MaxChars 400)
Assert-YakuTrue -Condition ($twoBatch.Count -eq 2 -and ($twoBatch | Where-Object { $_.CharCount -gt 400 }).Count -eq 0) -Message 'two-batch paragraph boundary split failed'
Assert-YakuTrue -Condition ($threeBatch.Count -eq 3 -and ($threeBatch | Where-Object { $_.CharCount -gt 400 }).Count -eq 0) -Message 'three-batch sentence boundary split failed'

$glossaryMatches = @(Get-YakuAppliedGlossaryEntries -Root $root -InputText '上期の売上は1億円でした。' -Direction 'to_en')
Assert-YakuTrue -Condition ($glossaryMatches.Count -gt 0) -Message 'glossary matching failed'
$overlapMatches = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText '上期 仕向地別営業利益 利益率分析' -Direction 'to_en' -Limit 4)
Assert-YakuTrue -Condition ($overlapMatches.Count -gt 0) -Message 'glossary overlap matching failed'
Assert-YakuTrue -Condition (([string]$overlapMatches[0].From) -eq '上期 仕向地別営業利益 利益率分析') -Message 'longest glossary term was not prioritized'
$splitReference = Get-YakuReferenceSection -Root $root -Settings $settings -InputText '関税影響 仕向地別営業利益' -Direction 'to_en'
Assert-YakuTrue -Condition ($splitReference.Contains('- 関税影響 = tariffs impact') -and -not $splitReference.Contains('仕向地別営業利益')) -Message 'prompt injection must use prompt_glossary.csv without heading-only glossary.csv terms'
$exactHeading = Get-YakuFileExactGlossaryTranslation -Root $root -Term '仕向地別営業利益' -Direction 'to_en' -Settings $settings
Assert-YakuTrue -Condition ([bool]$exactHeading.Found -and ([string]$exactHeading.Value) -eq 'Operating Profit by Market') -Message 'file exact replacement must continue to use glossary.csv'
$promptGlossaryEntries = @(Get-YakuGlossaryEntries -Root $root -Path (Get-YakuPromptGlossaryPath -Root $root))
$machineGlossaryEntries = @(Get-YakuGlossaryEntries -Root $root)
$promptTariffs = @($promptGlossaryEntries | Where-Object { [string]$_.Source -eq '関税影響' } | Select-Object -First 1)
$machineTariffs = @($machineGlossaryEntries | Where-Object { [string]$_.Source -eq '関税影響' } | Select-Object -First 1)
Assert-YakuTrue -Condition ($promptTariffs.Count -eq 1 -and ([string]$promptTariffs[0].Target) -eq 'tariffs impact' -and $machineTariffs.Count -eq 1 -and ([string]$machineTariffs[0].Target) -eq 'Tariffs impact') -Message 'two glossary files must retain independent cache entries and casing'

$fallbackGlossaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('YakuGlossaryFallback-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fallbackGlossaryRoot -Force | Out-Null
    Copy-Item -LiteralPath (Get-YakuGlossaryPath -Root $root) -Destination (Join-Path $fallbackGlossaryRoot 'glossary.csv') -Force
    $fallbackPath = Get-YakuPromptGlossaryPath -Root $fallbackGlossaryRoot
    Assert-YakuTrue -Condition ([System.IO.Path]::GetFileName($fallbackPath) -eq 'glossary.csv' -and @(Get-YakuGlossaryEntries -Root $fallbackGlossaryRoot -Path $fallbackPath).Count -gt 0) -Message 'missing prompt_glossary.csv must fall back to glossary.csv'
    $fallbackPanel = Convert-YakuGlossaryManagerToHtml -Root $fallbackGlossaryRoot
    Assert-YakuTrue -Condition ($fallbackPanel.Contains('未作成(glossary.csv にフォールバック中)')) -Message 'read-only glossary panel must expose prompt glossary fallback state'
} finally {
    if (Test-Path -LiteralPath $fallbackGlossaryRoot) { Remove-Item -LiteralPath $fallbackGlossaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$glossaryPanel = Convert-YakuGlossaryManagerToHtml -Root $root
$lastMachineEntry = @(Get-YakuGlossaryEntries -Root $root | Sort-Object Row | Select-Object -Last 1)[0]
Assert-YakuTrue -Condition ($glossaryPanel.Contains('表ラベル置換用 — glossary.csv') -and $glossaryPanel.Contains('Copilot翻訳用 — prompt_glossary.csv') -and $glossaryPanel.Contains('編集は各CSVファイルを直接編集してください') -and $glossaryPanel.Contains((ConvertTo-YakuHtml ([string]$lastMachineEntry.Source)))) -Message 'read-only glossary panel must show both complete glossary sections and direct-edit guidance'
Assert-YakuTrue -Condition (-not $glossaryPanel.Contains('<form') -and -not $glossaryPanel.Contains('glossary-delete') -and -not $glossaryPanel.Contains('>追加<') -and -not $glossaryPanel.Contains('>削除<')) -Message 'read-only glossary panel must not render edit controls'
$duplicateHtml = Get-YakuGlossaryDuplicateSummaryHtml -Entries @(
    [pscustomobject]@{ Source='A'; Target='Alpha'; Row=1 },
    [pscustomobject]@{ Source='A'; Target='Alpha'; Row=2 },
    [pscustomobject]@{ Source='A'; Target='Another'; Row=3 }
)
Assert-YakuTrue -Condition ($duplicateHtml.Contains('重複:') -and $duplicateHtml.Contains('競合:')) -Message 'read-only glossary panel warning summary must report duplicates and conflicts'

$partialBracket = Resolve-YakuFileBracketGlossaryTranslation -Root $root -Inner '単価差内訳' -Direction 'to_en' -Settings $settings -Id 117
Assert-YakuTrue -Condition (-not [bool]$partialBracket.Found) -Message 'partial Japanese glossary coverage must not produce a mixed-language bracket translation'
$asciiRemainderBracket = Resolve-YakuFileBracketGlossaryTranslation -Root $root -Inner '単価ver' -Direction 'to_en' -Settings $settings -Id 118
Assert-YakuTrue -Condition ([bool]$asciiRemainderBracket.Found -and ([string]$asciiRemainderBracket.Value) -eq 'per unit ver') -Message 'ASCII-only remainder after a to_en glossary match must remain allowed'
$englishRemainderBracket = Resolve-YakuFileBracketGlossaryTranslation -Root $root -Inner 'per unit variance' -Direction 'to_jp' -Settings $settings -Id 119
Assert-YakuTrue -Condition (-not [bool]$englishRemainderBracket.Found) -Message 'four-or-more uncovered English letters must reject a to_jp bracket glossary fallback'


$promptGlossaryV9123 = Get-Content -LiteralPath (Join-Path $root 'prompt_glossary.csv') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($promptGlossaryV9123.Contains('全本部,all divs.') -and $promptGlossaryV9123.Contains('財務本部,Financial Services Div.') -and $promptGlossaryV9123.Contains('本部,div.')) -Message 'V91.23 organization glossary entries missing'
Assert-YakuTrue -Condition ($promptGlossaryV9123.Contains('子会社,subs.') -and $promptGlossaryV9123.Contains('親会社,parent') -and $promptGlossaryV9123.Contains('関係会社,affil.')) -Message 'V91.24 additional company-relation glossary entries missing'
Assert-YakuTrue -Condition ($promptGlossaryV9123.Contains('出荷,W/S') -and $promptGlossaryV9123.Contains('営業利益,OP') -and $promptGlossaryV9123.Contains('出荷台数,W/S vol.') -and $promptGlossaryV9123.Contains('連結出荷台数,consol. W/S vol.')) -Message 'V91.27 shipment and operating-profit glossary entries missing or existing shipment-volume mappings changed'
$shipmentMatchesV9127 = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText '連結出荷台数 出荷状況 営業利益 連結営業利益' -Direction 'to_en' -Limit 10)
$shipmentMapV9127 = @{}
foreach ($entry in $shipmentMatchesV9127) { $shipmentMapV9127[[string]$entry.From] = [string]$entry.To }
Assert-YakuTrue -Condition ($shipmentMapV9127['連結出荷台数'] -eq 'consol. W/S vol.' -and $shipmentMapV9127['出荷'] -eq 'W/S' -and $shipmentMapV9127['営業利益'] -eq 'OP') -Message 'V91.27 longest-match glossary behavior for shipment and OP failed'

$briefRules = Get-YakuBriefRules -Root $root
Assert-YakuTrue -Condition ($briefRules.Contains('Priority: complete facts, telegraphic form, brevity') -and $briefRules.Contains('Apply to every sentence, heading, and label') -and $briefRules.Contains('B1.') -and $briefRules.Contains('B6.') -and $briefRules.Contains('Length is diagnostic, not a target')) -Message 'V91.19 compact BRIEF operations not loaded'
Assert-YakuTrue -Condition ($briefRules.Contains('Standard abbreviations:') -and $briefRules.Contains('semiconductors=semis') -and $briefRules.Contains('pre-X/post-X') -and $briefRules.Contains('GHG')) -Message 'V91.19 abbreviation or noun-stack rules missing'
Assert-YakuTrue -Condition ($briefRules.Contains('Signed breakdowns: term + source') -and $briefRules.Contains('Only a sentence-level period-change predicate') -and $briefRules.Contains('never breakdowns')) -Message 'V91.19 signed-figure exception missing'
Assert-YakuTrue -Condition ($briefRules.Contains('quote-like headlines') -and $briefRules.Contains('retain attribution/reporting verb') -and $briefRules.Contains('If ambiguous, use (a)')) -Message 'V91.19 quotation protection or attribution missing'
Assert-YakuTrue -Condition ($briefRules.Contains('Context-only items such as semis') -and $briefRules.Contains('never mix spelled and abbreviated forms')) -Message 'V91.19 abbreviation consistency missing'

Assert-YakuTrue -Condition ($briefRules.Contains('FC, VC, VP') -and $briefRules.Contains('fixed costs / fixed cost -> FC') -and $briefRules.Contains('variable costs / variable cost -> VC') -and $briefRules.Contains('vehicle variable profit -> VP (Veh.)')) -Message 'V91.56 FC/VC/VP BRIEF definitions missing'
Assert-YakuTrue -Condition ($briefRules.Contains('BRIEF “FC redn. 0.5 oku:') -and $briefRules.Contains('BRIEF “VC up on higher material prices.”') -and $briefRules.Contains('BRIEF “FC & VC up.”')) -Message 'V91.56 BRIEF examples missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('FULL must spell out ordinary-word and internal shorthand abbreviations') -and $textTemplate.Contains('Glossary candidate order does not by itself authorize an abbreviation in FULL') -and $textTemplate.Contains('FULL uses fixed costs, variable costs, variable profit, and vehicle variable profit') -and $textTemplate.Contains('BRIEF uses FC, VC, VP, and VP (Veh.)')) -Message 'V91.56 FULL/BRIEF contrast rules missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('approved financial acronyms, formal metric names, proper nouns, or source-defined abbreviations') -and $textTemplate.Contains('FCF or OP')) -Message 'V91.56 approved financial acronym exception missing'

Assert-YakuTrue -Condition ($briefRules.Contains('whose subject differs from the preceding clause must state its subject') -or $briefRules.Contains('NOT “...; intends to advance.”')) -Message 'V91.19 semicolon-subject example missing'

$textTemplate = Get-YakuPromptTemplate -Root $root -Name 'text_translate_to_en.txt'
$textTemplateJp = Get-YakuPromptTemplate -Root $root -Name 'text_translate_to_jp.txt'
Assert-YakuTrue -Condition ($textTemplate.Contains('Priority: complete facts, telegraphic form, brevity') -and $textTemplate.Contains('Apply to every sentence, heading, and label') -and $textTemplate.Contains('1H OP up 2.0 oku YoY, mainly') -and $textTemplate.Contains('FULL_TEXT: natural business English')) -Message 'V91.19 compact BRIEF rules not injected into to_en text prompt'
Assert-YakuTrue -Condition ($textTemplate.Contains('Shared rules (FULL_TEXT and BRIEF_TEXT)') -and $textTemplate.Contains('R4. Signed breakdowns') -and $textTemplate.Contains('term + one space + source sign and figure/unit') -and $textTemplate.Contains('decreased by X') -and $textTemplate.Contains('Join top-level items with semicolons')) -Message 'V91.19 shared signed-breakdown rules missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('Numbered headings: reproduce the exact source number') -and $textTemplate.Contains('never renumber, restart at 1.') -and $textTemplate.Contains('Reproduce every 【...非開示】 masking placeholder exactly') -and $textTemplate.Contains('Other 【...】 are emphasis/heading brackets')) -Message 'V91.23 numbered-heading or masking-placeholder prompt rules missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('R3. Use one English rendering') -and $textTemplate.Contains('R5. Semicolons may join clauses') -and $textTemplate.Contains('R10. Verify both outputs')) -Message 'V91.19 shared consistency, semicolon, or structure rules missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('R6. Intention vs. expectation') -and $textTemplate.Contains('plans to/intends to/is set to') -and $textTemplate.Contains('is expected to/is forecast to')) -Message 'V91.19 modality rule missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('R7. Attach “centered on X / led by X”') -and $textTemplate.Contains('〜を中心に -> “led by X”')) -Message 'V91.19 modifier-attachment rule missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('quote-like headlines') -and $textTemplate.Contains('retain attribution/reporting verb') -and $textTemplate.Contains('Context-only items such as semis')) -Message 'V91.19 quotation attribution or abbreviation consistency rule missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('Never output half-width < or >') -and $textTemplate.Contains('FULL-WIDTH ＜ and ＞')) -Message 'Angle-bracket transport rule missing'
Assert-YakuTrue -Condition (!$textTemplate.Contains('Reproduce a numeric A→B transition as-is in both FULL_TEXT and BRIEF_TEXT') -and !$textTemplate.Contains('A numeric transition written with an arrow')) -Message 'Arrow rule must exist only in numeric rules'
Assert-YakuTrue -Condition ($textTemplateJp.Contains('JAPANESE_TEXT:') -and !$textTemplateJp.Contains('BRIEF_TEXT:')) -Message 'to_jp text prompt contract is invalid'
$noNumberPrompt = New-YakuTextPrompt -Root $root -InputText 'これは数値を含まない文章です。' -Settings $settings -DirectionOverride 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuTrue -Condition (!$noNumberPrompt.Prompt.Contains('Numeric tokens already in English')) -Message 'numeric rules must be omitted for text without numeric cues'
$numberPrompt = New-YakuTextPrompt -Root $root -InputText '前年差▲3億円、410万円から451万円へ増加。' -Settings $settings -DirectionOverride 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuTrue -Condition ($numberPrompt.Prompt.Contains('Numeric tokens already in English') -and $numberPrompt.Prompt.Contains('never rescale') -and $numberPrompt.Prompt.Contains('Never million, billion, trillion') -and $numberPrompt.Prompt.Contains('reproduce ONLY when SOURCE writes A→B') -and $numberPrompt.Prompt.Contains('never create one')) -Message 'V91.37 token-preservation or arrow numeric rules missing'
$manUnitsPrompt = New-YakuTextPrompt -Root $root -InputText '出荷台数は2万台です。' -Settings $settings -DirectionOverride 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuTrue -Condition ($manUnitsPrompt.Prompt.Contains('2万台 = 20 k units') -and $manUnitsPrompt.Prompt.Contains('"ten thousand"')) -Message 'Man-unit conversion rule missing'

$fileTemplate = Get-YakuPromptTemplate -Root $root -Name 'file_translate_to_en.txt'
Assert-YakuTrue -Condition ($fileTemplate.Contains('Task: Translate every item from Japanese to English in BRIEF style.')) -Message 'File prompt task is not BRIEF style'
Assert-YakuTrue -Condition ($fileTemplate.Contains('Priority: complete facts, telegraphic form, brevity') -and $fileTemplate.Contains('Length is diagnostic, not a target') -and $fileTemplate.Contains('standalone label of about three words or fewer')) -Message 'V91.19 compact BRIEF rules or short-label rule not injected into file prompt'
Assert-YakuTrue -Condition ($fileTemplate.Contains('2万台 = 20 k units') -and $fileTemplate.Contains('Never million, billion, trillion')) -Message 'V91.19 numeric conversion rule missing from file prompt'
$fileTemplateJp = Get-YakuPromptTemplate -Root $root -Name 'file_translate_to_jp.txt'
foreach ($contractTemplate in @($textTemplate, $textTemplateJp, $fileTemplate, $fileTemplateJp)) {
    Assert-YakuTrue -Condition ($contractTemplate.Contains('YAKULINGO_END:{request_id}')) -Message 'every translation prompt must contain the final marker contract'
}

$promptCacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('YakuPromptCache-' + [guid]::NewGuid().ToString('N'))
try {
    $promptCacheDir = Join-Path $promptCacheRoot 'prompts'
    New-Item -ItemType Directory -Path $promptCacheDir -Force | Out-Null
    $promptCachePath = Join-Path $promptCacheDir 'cache_test.txt'
    [System.IO.File]::WriteAllText($promptCachePath, 'CACHE_A', (New-Object System.Text.UTF8Encoding($true)))
    $firstCachedTemplate = Get-YakuPromptTemplate -Root $promptCacheRoot -Name 'cache_test.txt'
    $originalStamp = (Get-Item -LiteralPath $promptCachePath).LastWriteTimeUtc
    [System.IO.File]::WriteAllText($promptCachePath, 'CACHE_B', (New-Object System.Text.UTF8Encoding($true)))
    (Get-Item -LiteralPath $promptCachePath).LastWriteTimeUtc = $originalStamp.AddSeconds(2)
    $updatedCachedTemplate = Get-YakuPromptTemplate -Root $promptCacheRoot -Name 'cache_test.txt'
    Assert-YakuTrue -Condition ($firstCachedTemplate -eq 'CACHE_A' -and $updatedCachedTemplate -eq 'CACHE_B') -Message 'prompt template cache must reload after mtime changes'
} finally {
    if (Test-Path -LiteralPath $promptCacheRoot) { Remove-Item -LiteralPath $promptCacheRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$mandatoryGlossary = Get-YakuReferenceSection -Root $root -Settings $settings -InputText '上期' -Direction 'to_en'
Assert-YakuTrue -Condition ($mandatoryGlossary.Contains('GLOSSARY (mandatory)') -and $mandatoryGlossary.Contains('use the mapped target term exactly')) -Message 'glossary mappings must be stated as mandatory exact output terms'
Assert-YakuTrue -Condition ($mandatoryGlossary.Contains('keep all-caps acronyms and proper nouns') -and $mandatoryGlossary.Contains('abbreviations of ordinary words (e.g. Vol., Act.)') -and $mandatoryGlossary.Contains('capitalized as listed only when the term stands alone as a heading or label line') -and $mandatoryGlossary.Contains('including signed breakdown lists') -and $mandatoryGlossary.Contains('running text (lowercase)')) -Message 'glossary casing must distinguish all-caps acronyms from ordinary-word abbreviations and in-sentence breakdowns'

$stylePrompt = New-YakuTextPrompt -Root $root -InputText '追加の文章です。' -Settings $settings -DirectionOverride 'to_en' -StyleReference 'Prior translation style sample.' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuTrue -Condition ($stylePrompt.Prompt.Contains('STYLE_REFERENCE') -and $stylePrompt.Prompt.Contains('Prior translation style sample.')) -Message 'STYLE_REFERENCE not injected'

$factorGlossary = @(Get-YakuAppliedGlossaryEntries -Root $root -InputText '為替 台数構成 構成差 原材料・物流 コスト改善 構造的原低 固定費 固定費他' -Direction 'to_en' -Limit 20)
$factorMap = @{}
foreach ($entry in $factorGlossary) { $factorMap[[string]$entry.From] = [string]$entry.To }
Assert-YakuTrue -Condition ($factorMap['為替'] -eq 'FX' -and $factorMap['台数構成'] -eq 'vol./mix' -and $factorMap['構成差'] -eq 'mix difference' -and $factorMap['原材料・物流'] -eq 'raw materials/logistics' -and $factorMap['コスト改善'] -eq 'cost improvements' -and $factorMap['構造的原低'] -eq 'structural cost reduction' -and $factorMap['固定費'] -eq 'fixed costs' -and -not $factorMap.ContainsKey('固定費他')) -Message 'V90.9 prompt glossary mappings or heading-label separation missing'

$v9156PromptGlossary = Get-Content -LiteralPath (Join-Path $root 'prompt_glossary.csv') -Raw -Encoding UTF8
$v9156MainGlossary = Get-Content -LiteralPath (Join-Path $root 'glossary.csv') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($v9156PromptGlossary.Contains('固定費,fixed costs|fixed cost|FC') -and $v9156PromptGlossary.Contains('変動費用,variable costs|variable cost|VC') -and $v9156PromptGlossary.Contains('変動利益,variable profit|VP') -and $v9156PromptGlossary.Contains('車両変動利益,vehicle variable profit|VP (Veh.)')) -Message 'V91.56 prompt glossary FULL-first candidate order missing'
Assert-YakuTrue -Condition ($v9156MainGlossary.Contains('固定費,Fixed Costs|Fixed Cost|FC') -and $v9156MainGlossary.Contains('変動費用,Variable Costs|Variable Cost|VC') -and $v9156MainGlossary.Contains('変動利益,Variable Profit|VP') -and $v9156MainGlossary.Contains('車両変動利益,Vehicle Variable Profit|VP (Veh.)')) -Message 'V91.56 main glossary FULL-first candidate order missing'

# V91.57 promotion-cost terminology and exact-match contract
Assert-YakuTrue -Condition ($briefRules.Contains('sales promotion costs / promotion costs -> Promo. Costs') -and $briefRules.Contains('fixed sales promotion costs -> Fixed Promo. Costs') -and $briefRules.Contains('Do not abbreviate sales promotion costs as MKT')) -Message 'V91.57 BRIEF promotion-cost rules missing'
Assert-YakuTrue -Condition ($textTemplate.Contains('FULL also uses sales promotion costs, fixed sales promotion costs') -and $textTemplate.Contains('Do not output MKT merely as an abbreviation of promotion costs')) -Message 'V91.57 FULL promotion-cost expansion rule missing'
Assert-YakuTrue -Condition ($fileTemplate.Contains('子会社 固定販促費 / 子会社固定販促費 -> Subs. Fixed Promo. Costs') -and $fileTemplate.Contains('販売奨励金/固定販促費 -> VM / Fixed Promo. Costs')) -Message 'V91.57 file exact-match promotion labels missing'
$v9157PromptGlossary = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\prompt_glossary.csv') -Raw -Encoding UTF8
$v9157MainGlossary = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\glossary.csv') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($v9157PromptGlossary.Contains('固定販促費,fixed sales promotion costs|fixed promo. costs') -and $v9157PromptGlossary.Contains('販促費,sales promotion costs|promo. costs') -and $v9157PromptGlossary.Contains("子会社 固定販促費,subsidiaries' fixed sales promotion costs|subs. fixed promo. costs")) -Message 'V91.57 prompt glossary promotion-cost mappings missing'
Assert-YakuTrue -Condition ($v9157MainGlossary.Contains('固定販促費,Fixed Promo. Costs') -and $v9157MainGlossary.Contains('子会社 固定販促費,Subs. Fixed Promo. Costs') -and $v9157MainGlossary.Contains('子会社固定販促費,Subs. Fixed Promo. Costs') -and $v9157MainGlossary.Contains('販売奨励金/固定販促費,VM / Fixed Promo. Costs')) -Message 'V91.57 exact-match promotion-cost mappings missing'
Assert-YakuTrue -Condition (-not $v9157MainGlossary.Contains('固定販促費,Fixed MKT') -and -not $v9157MainGlossary.Contains('販売奨励金/固定販促費,VM / Fixed Marketing')) -Message 'V91.57 obsolete promotion-cost MKT mappings remain'


$v9125Glossary = Get-YakuReferenceSection -Root $root -Settings $settings -InputText '財務部門' -Direction 'to_en'
Assert-YakuTrue -Condition ($v9125Glossary.Contains('部門 => dept.')) -Message 'V91.25 department glossary addition missing'
$v9122Glossary = Get-YakuReferenceSection -Root $root -Settings $settings -InputText 'フリーCF 信用力 職務分離' -Direction 'to_en'
Assert-YakuTrue -Condition ($v9122Glossary.Contains('フリーCF => FCF') -and $v9122Glossary.Contains('信用力 => creditworthiness') -and $v9122Glossary.Contains('職務分離 => segregation of duties')) -Message 'V91.22 prompt glossary additions missing'
$v9122BriefRules = Get-YakuPromptTemplate -Root $root -Name 'style_brief_rules.txt'
Assert-YakuTrue -Condition ($v9122BriefRules.Contains('accounting -> acctg.') -and $v9122BriefRules.Contains('financial institutions -> FIs') -and $v9122BriefRules.Contains('subsidiaries must be subs.') -and $v9122BriefRules.Contains('replace and with &')) -Message 'V91.22 abbreviation whitelist or mandatory-use check missing'

$translationSourceForGlossary = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($translationSourceForGlossary.Contains("'prompt_glossary.csv'")) -Message 'translation cache fingerprint must include prompt_glossary.csv'



$promptGlossaryV9128 = Get-Content -LiteralPath (Join-Path $root 'prompt_glossary.csv') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($promptGlossaryV9128.Contains('親会社株主に帰属する当期純利益,PAT attributable to owners of parent')) -Message 'V91.29 attributable PAT glossary entry missing'
$v9128Longest = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText '親会社株主に帰属する当期純利益' -Direction 'to_en' -Limit 10)
Assert-YakuTrue -Condition ($v9128Longest.Count -gt 0 -and ([string]$v9128Longest[0].From) -eq '親会社株主に帰属する当期純利益' -and ([string]$v9128Longest[0].To) -eq 'PAT attributable to owners of parent') -Message 'V91.29 longest-match attributable PAT mapping must take priority'
$v9128QuarterPrompt = New-YakuTextPrompt -Root $root -InputText '1Qの営業利益は前年同期比3%増加。' -Settings $settings -DirectionOverride 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuTrue -Condition ($v9128QuarterPrompt.Prompt.Contains('Q1-Q4') -and $v9128QuarterPrompt.Prompt.Contains('Keep YoY, QoQ, CAGR, Jan. to Dec.') -and -not $v9128QuarterPrompt.Prompt.Contains('Keep YoY, QoQ, CAGR, 3Q')) -Message 'V91.29 Q1-Q4 normalization and Keep 3Q removal regression failed'

$v9130BriefRules = Get-YakuPromptTemplate -Root $root -Name 'style_brief_rules.txt'
Assert-YakuTrue -Condition ($v9130BriefRules.Contains('If SOURCE gives a name acronym') -and $v9130BriefRules.Contains('BRIEF may use ABBR alone') -and $v9130BriefRules.Contains('Never invent/import one or shorten companies')) -Message 'V91.30 source-provided acronym rule missing'
Assert-YakuTrue -Condition ($v9130BriefRules.Contains('write “A, B & C,” not “A, B, & C.”')) -Message 'V91.30 Oxford comma removal rule missing'
$v9131WordCount = ((Get-YakuPromptTemplate -Root $root -Name 'text_translate_to_en.txt') + ' ' + $v9130BriefRules -split '\s+' | Where-Object { $_ }).Count
Assert-YakuTrue -Condition ($v9131WordCount -le 1350) -Message ("V91.31 prompt word count exceeds 1,350: {0}" -f $v9131WordCount)


# V91.31: led-by distinction and measured progress wiring.
Assert-YakuTrue -Condition ($textTemplate.Contains('〜をはじめとする -> “including / such as,” never “led by”') -and $textTemplate.Contains('44 companies including Sony')) -Message 'V91.31 including-vs-led-by rule missing'
$copilotClientV9131 = Get-Content -LiteralPath (Join-Path $root 'src\CopilotClient.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($copilotClientV9131.Contains('$expectedChars = 0.0') -and $copilotClientV9131.Contains('$approxChars / $expectedChars') -and $copilotClientV9131.Contains('$timeFloor = [Math]::Min(60, 42 + $sliceCount)')) -Message 'V91.31 response-length progress calculation missing'
Assert-YakuTrue -Condition ($copilotClientV9131.Contains('if ($batchCurrent -ge 1 -and $batchEnd -gt $batchStart)') -and $copilotClientV9131.Contains('if ($batchTotal -gt 1) { $displayLabel')) -Message 'V91.31 single-batch mapping or multi-batch label condition missing'
$translationV9131 = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($translationV9131.Contains("copilotAnswerRatioText") -and $translationV9131.Contains("answer_ratio_count") -and $translationV9131.Contains('Copilot answer ratio measured.')) -Message 'V91.31 in-job answer-ratio learning missing'
Write-Host "V91.31 prompt refactor and progress regression passed: $($cases.Count) corpus cases plus both contract directions. Prompt words=$v9131WordCount" -ForegroundColor Green

# V91.32: kind-specific affine expected-answer calibration.
$settingsV9132 = Get-Content -LiteralPath (Join-Path $root 'src\Settings.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($settingsV9132.Contains("copilotAnswerRatioText            = @{ Type='double'; Default=4.0") -and $settingsV9132.Contains("copilotAnswerBaseText             = @{ Type='double'; Default=150.0") -and $settingsV9132.Contains("copilotAnswerRatioFile            = @{ Type='double'; Default=1.7") -and $settingsV9132.Contains("copilotAnswerBaseFile             = @{ Type='double'; Default=0.0")) -Message 'V91.32 kind-specific answer estimate settings missing'
$translationV9132 = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($translationV9132.Contains("if ($Kind -eq 'text')") -and $translationV9132.Contains("$ratio = 4.0; $base = 150.0") -and $translationV9132.Contains("$ratio = 1.7; $base = 0.0") -and $translationV9132.Contains("$base + ([double]$batch.CharCount * $ratio)")) -Message 'V91.32 affine expected-answer calculation missing'
Assert-YakuTrue -Condition (-not $settingsV9132.Contains('copilotAnswerRatio                =') -and -not $translationV9132.Contains('$Settings.copilotAnswerRatio ')) -Message 'V91.32 legacy copilotAnswerRatio must be ignored'
Write-Host 'V91.32 expected-answer calibration regression passed.' -ForegroundColor Green


# V91.33: response-only progress numerator and file-path calibration.
$copilotClientV9133 = Get-Content -LiteralPath (Join-Path $root 'src\CopilotClient.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($copilotClientV9133.Contains('const responseTextSoFar = () =>') -and $copilotClientV9133.Contains('if (cutIndex < 0) return') -and $copilotClientV9133.Contains('const answerLengthSoFar = () => responseTextSoFar().length') -and $copilotClientV9133.Contains('answerLengthSoFar: answerLengthSoFar()')) -Message 'V91.33 response-only JavaScript length helper missing'
Assert-YakuTrue -Condition ($copilotClientV9133.Contains("-Name 'answerLengthSoFar' -Default 0") -and -not $copilotClientV9133.Contains('$approxChars = [Math]::Max($sliceTail.Length, $lastMainTail.Length)')) -Message 'V91.33 PowerShell progress numerator must not use diagnostic mainTail lengths'
$fileTranslationV9133 = Get-Content -LiteralPath (Join-Path $root 'src\FileTranslation.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($fileTranslationV9133.Contains('$batchInputChars = [int]([string]$sourceList).Length') -and $fileTranslationV9133.Contains("$Settings.copilotAnswerRatioFile") -and $fileTranslationV9133.Contains("$Settings.copilotAnswerBaseFile") -and $fileTranslationV9133.Contains("$ProgressState['batch_expected_chars']")) -Message 'V91.33 file expected-answer calculation missing'
Assert-YakuTrue -Condition ($fileTranslationV9133.Contains('Copilot answer ratio measured. kind=file') -and $fileTranslationV9133.Contains("$ProgressState['answer_ratio_count']") -and $fileTranslationV9133.Contains("$ProgressState['answer_ratio_sum']")) -Message 'V91.33 file answer-ratio logging or in-job learning missing'
Write-Host 'V91.33 response numerator and file calibration regression passed.' -ForegroundColor Green


# V91.34: folded prompt echo, file live progress, and prompt-length guard.
$copilotClientV9134 = Get-Content -LiteralPath (Join-Path $srcRoot 'CopilotClient.ps1') -Raw -Encoding UTF8
$fileTranslationV9134 = Get-Content -LiteralPath (Join-Path $srcRoot 'FileTranslation.ps1') -Raw -Encoding UTF8
$settingsV9134 = Get-Content -LiteralPath (Join-Path $srcRoot 'Settings.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($copilotClientV9134.Contains("if (cutIndex < 0) return after;") -and $copilotClientV9134.Contains('$echoBaseLen = -1') -and $copilotClientV9134.Contains('$netAnswerLen = [Math]::Max(0, $sliceAnswerLen - $echoBaseLen)') -and $copilotClientV9134.Contains('$approxChars = $maxAnswerLen')) -Message 'V91.34 visible-echo subtraction progress numerator missing'
Assert-YakuTrue -Condition ($fileTranslationV9134.Contains('-ProgressState $ProgressState') -and $fileTranslationV9134.Contains("$ProgressState['batch_progress_start']") -and $fileTranslationV9134.Contains("$ProgressState['file_progress_prefix']")) -Message 'V91.34 file live-generation progress propagation missing'
Assert-YakuTrue -Condition ($settingsV9134.Contains('copilotPromptCharLimit') -and $copilotClientV9134.Contains('PROMPT_TRUNCATED_BY_INPUT_LIMIT') -and $copilotClientV9134.Contains('actualInputComparableLength')) -Message 'V91.34 prompt length guard or post-fill validation missing'
Write-Host 'V91.34 progress and prompt-length guard regression passed.' -ForegroundColor Green


# V91.35/V91.36 window-recovery and numeric-audit guards.
$numberPromptV9135 = New-YakuTextPrompt -Root $root -InputText '連結売上高11,577億円、122億円。' -Settings $settings -DirectionOverride 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
$copilotClientV9135 = Get-Content -LiteralPath (Join-Path $srcRoot 'CopilotClient.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($copilotClientV9135.Contains('Repair-YakuCopilotPageResponsiveness') -and $copilotClientV9135.Contains("-Expression '1+1' -TimeoutSeconds 3") -and $copilotClientV9135.Contains('Copilot target ping recovered after CDP reconnect.')) -Message 'V91.36 frozen-target ping recovery missing'
Assert-YakuTrue -Condition ($copilotClientV9135.Contains('Request-path surplus Copilot tab cleanup') -and $copilotClientV9135.Contains('Close-YakuSurplusCopilotTargets -Port $port -KeepTargetId $keepTargetId')) -Message 'V91.36 request-path surplus-tab cleanup missing'
Assert-YakuTrue -Condition ($copilotClientV9135.Contains('Residual Copilot input detected before fill; clearing') -and $copilotClientV9135.Contains('INPUT_RESIDUAL_CONFLICT') -and $copilotClientV9135.Contains('PROMPT_TRUNCATED_BY_INPUT_LIMIT')) -Message 'V91.36 residual-input clearing or error separation missing'
$v9135WordCount = ((Get-YakuPromptTemplate -Root $root -Name 'text_translate_to_en.txt') + ' ' + (Get-YakuPromptTemplate -Root $root -Name 'style_brief_rules.txt') -split '\s+' | Where-Object { $_ }).Count
Assert-YakuTrue -Condition ($v9135WordCount -le 1270) -Message ("V91.36 prompt word count exceeds 1,270: {0}" -f $v9135WordCount)
Write-Host "V91.36 numeric-scale and window-recovery regression passed. Prompt words=$v9135WordCount" -ForegroundColor Green

# V91.36 numeric integrity and masking scope
$numericOk = Test-YakuNumericIntegrity -SourceText '売上高11,577 oku、販売659 k units、比率12.2%。' -TranslatedText 'Revenue was 11,577 oku, sales were 659 k units, and the ratio was 12.2%.' -Location 'regression-ok'
$numericBad = Test-YakuNumericIntegrity -SourceText '損失400 oku。' -TranslatedText 'A negative 40 oku.' -Location 'regression-bad'
Assert-YakuTrue -Condition ([bool]$numericOk.Ok -and -not [bool]$numericBad.Ok -and [int]$numericBad.ScaleErrors -ge 1) -Message 'V91.36 numeric integrity audit missing or scale mismatch undetected'
$emphasisScope = Test-YakuMaskingPlaceholderIntegrity -SourceText '【第3四半期(3か月)】と【金額非開示】' -TranslatedText '【Third Quarter (3 months)】 and 【金額非開示】' -Style 'full'
Assert-YakuTrue -Condition ([bool]$emphasisScope.Ok -and [int]$emphasisScope.SourceCount -eq 1) -Message 'V91.36 masking placeholder scope is not limited to ...非開示'

# V91.37 deterministic numeric-unit preprocessing
$u = Convert-YakuNumericUnits -Text '1兆1,577億円 / 2兆円 / 2.5億円 / 100万台 / 659千台 / 410万円 / 575千円 / 数億円 / xxx億円 / xxx万台 / ▲638億円 / 10〜20億円' -Location 'regression-v9137'
Assert-YakuTrue -Condition ($u.Text.Contains('11,577 oku') -and $u.Text.Contains('20,000 oku') -and $u.Text.Contains('2.5 oku') -and $u.Text.Contains('1,000 k units') -and $u.Text.Contains('659 k units') -and $u.Text.Contains('4,100 k yen') -and $u.Text.Contains('575 k yen') -and $u.Text.Contains('数億円') -and $u.Text.Contains('xxx oku') -and $u.Text.Contains('xxx万台') -and $u.Text.Contains('▲638 oku') -and $u.Text.Contains('10 oku〜20 oku')) -Message 'V91.37 numeric-unit preprocessing failed'
Assert-YakuTrue -Condition ($u.Warnings.Count -ge 1) -Message 'V91.37 masked scaled-unit warning missing'
$numericTokenOk = Test-YakuNumericIntegrity -SourceText '11,577 oku / 659 k units / 12.2%' -TranslatedText '11,577 oku, 659 k units, and 12.2%' -Location 'regression-v9137-ok'
Assert-YakuTrue -Condition ([bool]$numericTokenOk.Ok) -Message 'V91.37 token audit failed'


# V91.38 ratio, glossary, and full-width file-path numeric preprocessing.
$settingsV9138 = Get-Content -LiteralPath (Join-Path $srcRoot 'Settings.ps1') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($settingsV9138.Contains("copilotAnswerRatioText            = @{ Type='double'; Default=4.0")) -Message 'V91.38 text answer ratio must default to 4.0'
$promptGlossaryV9138 = Get-Content -LiteralPath (Join-Path $root 'prompt_glossary.csv') -Raw -Encoding UTF8
Assert-YakuTrue -Condition ($promptGlossaryV9138.Contains('単価改善,per-unit price improvement')) -Message 'V91.38 unit-price improvement glossary entry missing'
$v9138Glossary = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText 'CX-90単価改善' -Direction 'to_en' -Limit 10)
Assert-YakuTrue -Condition ($v9138Glossary.Count -gt 0 -and (@($v9138Glossary | Where-Object { ([string]$_.From) -eq '単価改善' -and ([string]$_.To) -eq 'per-unit price improvement' }).Count -eq 1)) -Message 'V91.38 longest-match unit-price improvement mapping failed'
$uFull = Convert-YakuNumericUnits -Text '売上高５，６０２億円となった。固定費改善は対前年4Q比２４８億円。ｘｘｘ億円。' -Location 'file-regression-v9138'
Assert-YakuTrue -Condition ($uFull.Text.Contains('5,602 oku') -and $uFull.Text.Contains('248 oku') -and $uFull.Text.Contains('xxx oku') -and $uFull.Tokens.Count -eq 3) -Message 'V91.38 full-width numeric-unit preprocessing failed'
$uFullAudit = Test-YakuNumericIntegrity -SourceText $uFull.Text -TranslatedText 'Revenue was 5,602 oku. Fixed-cost improvement was 248 oku. xxx oku.' -Location 'file-regression-v9138-audit'
Assert-YakuTrue -Condition ([bool]$uFullAudit.Ok -and [int]$uFullAudit.Checked -gt 0) -Message 'V91.38 full-width numeric audit failed'
Write-Host 'V91.38 ratio, glossary, and full-width numeric preprocessing regression passed.' -ForegroundColor Green
