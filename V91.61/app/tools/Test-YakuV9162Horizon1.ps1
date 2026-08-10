<#
.SYNOPSIS
  Horizon 1 architecture and safety regression tests.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT = '1'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuH1 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

foreach ($name in @(
    'Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1',
    'FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CorpusReference.ps1','ProperNoun.ps1',
    'CellSegments.ps1','CellAlign.ps1','CatProject.ps1'
)) { . (Join-Path (Join-Path $root 'src') $name) }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-h1-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
function Get-YakuCatProjectStoreDir { return $tempRoot }
function Add-YakuTranslationMemoryEntry { return [pscustomobject]@{ Added=$true; Reason='test' } }

try {
    Write-Host 'Legacy route removal' -ForegroundColor Cyan
    $server = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
    $client = @(
        [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'common.js'))
        [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'quick.js'))
        [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'cat.js'))
    ) -join "`n"
    Check-YakuH1 ($server -notmatch '/api/translate-file') 'legacy API route is absent'
    Check-YakuH1 ($server -notmatch 'Start-YakuFileProcessJob') 'legacy file worker launcher is absent'
    Check-YakuH1 ($client -notmatch 'yakuSubmitFileTranslation|/api/translate-file') 'legacy browser submit route is absent'
    Check-YakuH1 (-not (Test-Path -LiteralPath (Join-Path (Join-Path $root 'src') 'FileWorker.ps1'))) 'legacy file worker file is absent'
    Check-YakuH1 (-not (Test-Path -LiteralPath (Join-Path (Join-Path $root 'prompts') 'file_translate_to_en.txt'))) 'legacy English prompt is absent'
    Check-YakuH1 (-not (Test-Path -LiteralPath (Join-Path (Join-Path $root 'prompts') 'file_translate_to_jp.txt'))) 'legacy Japanese prompt is absent'
    Check-YakuH1 ($server -match 'Invoke-YakuCatTranslationItems') 'production CAT job uses the CAT facade'
    Check-YakuH1 ($server -notmatch 'Invoke-YakuFileTranslationItems') 'production CAT job has no legacy relay call'

    Check-YakuH1 (-not (Get-Command Invoke-YakuFileTranslation -ErrorAction SilentlyContinue)) 'legacy high-level function is absent'

    Write-Host 'Protected CAT prompt and external-send gate' -ForegroundColor Cyan
    $item = [pscustomobject]@{ Index=1; Text='売上高は1,234百万円でした。'; BlockIds=(New-Object System.Collections.Generic.List[string]) }
    $null = Protect-YakuCatItems -Items @($item) -Root $root -Direction 'to_en'
    Check-YakuH1 ([string]$item.ProtectionContractVersion -eq 'cat-protection-v1') 'protected payload is versioned'
    Check-YakuH1 ([string]$item.Text -notmatch '1,234') 'raw numeric value is masked before prompt creation'
    $prompt = New-YakuCatPrompt -Root $root -Items @($item) -Settings ([pscustomobject]@{}) -Direction 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
    Check-YakuH1 ($prompt -notmatch '1,234') 'serialized CAT prompt contains no raw protected numeric value'
    Check-YakuH1 ($prompt -match 'complete|省略') 'CAT prompt requests a complete translation'
    $fiscalItem = [pscustomobject]@{ Index=9; Text='2027年度第1四半期の売上高は1,234億円です。'; BlockIds=(New-Object System.Collections.Generic.List[string]) }
    $null = Protect-YakuCatItems -Items @($fiscalItem) -Root $root -Direction 'to_en'
    $fiscalTokens = @(Get-YakuNumericMaskTokens -Text ([string]$fiscalItem.Text))
    $fiscalTarget = 'FY' + [string]$fiscalTokens[0] + ' revenue was ' + [string]$fiscalTokens[2] + ' oku in Q' + [string]$fiscalTokens[1] + '.'
    $fiscalIntegrity = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$fiscalItem.Text) -Translated $fiscalTarget -Location 'h1-fiscal-period'
    Check-YakuH1 ([bool]$fiscalIntegrity.Ok) 'CAT allows fiscal year and quarter to move naturally while preserving financial-value order'
    $naturalFiscal = ConvertTo-YakuNaturalEnglishNotation -SourceText '2027年度第1四半期の売上高は1,234億円です。' `
        -Translation 'For the 2027 fiscal year, revenue was 1,234 oku in the 1 quarter.'
    Check-YakuH1 ($naturalFiscal -eq 'For FY2027, revenue was 1,234 oku in Q1.') 'CAT apply boundary formats fiscal year and quarter naturally from the canonical source'
    $groupedOku = Restore-YakuNumericMask -Text 'Revenue was [[N1]] oku.' -Map @{ '[[N1]]'='1,234' } -Direction 'to_en' -SourceText '売上高は[[N1]]億円です。'
    Check-YakuH1 ($groupedOku -eq 'Revenue was 1,234 oku.') 'numeric restoration preserves readable grouping in oku output'
    $forgedItem = $item.PSObject.Copy()
    $forgedItem.NumericMaskMap = @{ '[[N1]]' = '9,999' }
    $fakeMapBlocked = $false
    try { Assert-YakuCatProtectedItemsMatchOriginal -Items @($forgedItem) -Root $root -Direction to_en }
    catch { $fakeMapBlocked = ($_.Exception.Message -match '^CAT_PROTECTED_PAYLOAD_NONCANONICAL') }
    Check-YakuH1 $fakeMapBlocked 'CAT rejects a fake mask map that would restore a different value'
    $jpProperItem = [pscustomobject]@{ Index=2; Text='MAZDA MOTOR CORPORATION reported results.'; BlockIds=(New-Object System.Collections.Generic.List[string]) }
    $null = Protect-YakuCatItems -Items @($jpProperItem) -Root $root -Direction 'to_jp'
    Check-YakuH1 ([string]$jpProperItem.Text -match 'MAZDA MOTOR CORPORATION' -and
        @($jpProperItem.PSObject.Properties.Name) -notcontains 'ProperMaskMap') `
        'CAT leaves registered proper nouns unchanged because only numbers are masked'
    Write-Host 'Single protected-prompt transport boundary' -ForegroundColor Cyan
    $sourceDir = Join-Path $root 'src'
    $productionFiles = @(Get-ChildItem -LiteralPath $sourceDir -File -Filter '*.ps1')
    $productionText = ($productionFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Check-YakuH1 ($productionText -notmatch '\bAssert-YakuExternalSendAllowed\b') 'legacy external-send assertion is absent from production code'
    Check-YakuH1 ($productionText -notmatch '(?i)(?:^|\s)-Preflight\b') 'preflight send branch is absent from production code'
    Check-YakuH1 ($productionText -notmatch '(?i)(?:^|\s)-ProtectedPayload\b') 'caller-declared protected-payload branch is absent from production code'

    $legacyRawCalls = New-Object System.Collections.Generic.List[object]
    $protectedCalls = New-Object System.Collections.Generic.List[object]
    $packageCalls = New-Object System.Collections.Generic.List[object]
    foreach ($file in $productionFiles) {
        $lineNo = 0
        foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
            $lineNo++
            if ($line -match '\bInvoke-YakuCopilotPrompt(?:\s+-[A-Za-z]|\s+@[A-Za-z])') {
                $legacyRawCalls.Add([pscustomobject]@{ Path=$file.FullName; Line=$lineNo; Text=$line.Trim() })
            }
            if ($line -match '\bInvoke-YakuProtectedCopilotPrompt(?:\s+-[A-Za-z]|\s+@[A-Za-z])') {
                $protectedCalls.Add([pscustomobject]@{ Path=$file.FullName; Line=$lineNo; Text=$line.Trim() })
            }
            if ($line -match '\bNew-YakuProtectedPromptPackage(?:\s+-[A-Za-z]|\s+@[A-Za-z])') {
                $packageCalls.Add([pscustomobject]@{ Path=$file.FullName; Line=$lineNo; Text=$line.Trim() })
            }
        }
    }
    Check-YakuH1 ($legacyRawCalls.Count -eq 0) 'legacy raw Copilot prompt calls are absent from production code'
    Check-YakuH1 ($null -eq (Get-Command Invoke-YakuCopilotPromptUnsafe -ErrorAction SilentlyContinue)) 'raw Copilot transport is not publicly callable after boundary initialization'

    $requiredProtectedCallSites = @{
        'Translation.ps1' = 3
        'CatBatch.ps1' = 3
        'CorpusReference.ps1' = 1
        'Alignment.ps1' = 1
        'CopilotClient.ps1' = 1
    }
    foreach ($entry in $requiredProtectedCallSites.GetEnumerator()) {
        $actualCount = @($protectedCalls | Where-Object { [IO.Path]::GetFileName([string]$_.Path) -eq [string]$entry.Key }).Count
        Check-YakuH1 ($actualCount -ge [int]$entry.Value) ("production sends use protected adapter: {0} ({1}/{2})" -f $entry.Key,$actualCount,$entry.Value)
    }
    Check-YakuH1 ($packageCalls.Count -ge 9) 'all production prompts are serialized by the canonical protected package builder'

    Check-YakuH1 ($null -ne (Get-Command New-YakuProtectedPromptPackage -ErrorAction SilentlyContinue)) 'canonical protected prompt package builder is available'
    Check-YakuH1 ($null -ne (Get-Command Invoke-YakuProtectedCopilotPrompt -ErrorAction SilentlyContinue)) 'protected Copilot adapter is available'
    Check-YakuH1 ($null -eq (Get-Command New-YakuPromptProtectionReceipt -ErrorAction SilentlyContinue) -and $null -eq (Get-Command New-YakuProtectedPromptEnvelope -ErrorAction SilentlyContinue)) 'receipt issuer and arbitrary-prompt envelope factory are private'
    $adapterCommand = Get-Command Invoke-YakuProtectedCopilotPrompt
    $adapterSession = $adapterCommand.ScriptBlock.Module.SessionState
    $exposedAuthorityNames = @('rawTransport','key','registry','newReceipt','newEnvelope') | Where-Object {
        $null -ne $adapterSession.PSVariable.GetValue($_)
    }
    Check-YakuH1 ($exposedAuthorityNames.Count -eq 0) 'public adapter DynamicModule does not expose raw transport or protection authority state'
    $adapterRawCommand = $adapterSession.InvokeCommand.GetCommand('Invoke-YakuBoundaryTransport', [System.Management.Automation.CommandTypes]::Function)
    Check-YakuH1 ($null -eq $adapterRawCommand) 'adapter-local raw transport is not callable outside a validated invocation'

    $numericMap = @{ '[[N1]]' = '1,234' }
    $rawNumericBlocked = $false
    try {
        $null = New-YakuProtectedPromptPackage -Kind corpus -Root $root -Direction to_en `
            -Fields @([pscustomobject]@{ Name='source'; OriginalText='売上高は1,234百万円でした。'; ProtectedText='売上高は1,234百万円でした。'; NumericMaskMaps=@($numericMap) }) `
            -Arguments ([pscustomobject]@{ RequestId=[guid]::NewGuid().ToString('N') })
    }
    catch { $rawNumericBlocked = $true }
    Check-YakuH1 $rawNumericBlocked 'canonical package independently rejects a raw numeric value left in a dynamic field'
    $packageCommand = Get-Command New-YakuProtectedPromptPackage
    Check-YakuH1 (-not $packageCommand.Parameters.ContainsKey('Prompt')) 'public package builder cannot accept an arbitrary final prompt or append uncovered raw text'
    $wrongRootBlocked = $false
    try {
        $null = New-YakuProtectedPromptPackage -Kind corpus -Root ([IO.Path]::GetTempPath()) -Direction to_en `
            -Fields @([pscustomobject]@{ Name='source'; OriginalText='SAFE'; ProtectedText='SAFE' }) `
            -Arguments ([pscustomobject]@{ RequestId=[guid]::NewGuid().ToString('N') })
    } catch { $wrongRootBlocked = $true }
    Check-YakuH1 $wrongRootBlocked 'canonical package rejects caller-selected roots'
    $callerRequestId = 'deadbeefdeadbeefdeadbeefdeadbeef'
    $authorityIdPackage = New-YakuProtectedPromptPackage -Kind corpus -Root $root -Direction to_en `
        -Fields @([pscustomobject]@{ Name='source'; OriginalText='SAFE'; ProtectedText='SAFE' }) `
        -Arguments ([pscustomobject]@{ RequestId=$callerRequestId })
    Check-YakuH1 ($authorityIdPackage.Prompt.IndexOf($callerRequestId, [StringComparison]::Ordinal) -lt 0 -and
        [string]$authorityIdPackage.RequestId -match '^[a-f0-9]{32}$' -and [string]$authorityIdPackage.RequestId -ne $callerRequestId) `
        'canonical serializer generates RequestId internally and ignores caller-supplied values'
    $rawRequestId = "abc`n極秘売上高は1,234百万円"
    $rawIdPackage = New-YakuProtectedPromptPackage -Kind corpus -Root $root -Direction to_en `
        -Fields @([pscustomobject]@{ Name='source'; OriginalText='SAFE'; ProtectedText='SAFE' }) `
        -Arguments ([pscustomobject]@{ RequestId=$rawRequestId })
    Check-YakuH1 (-not ([string]$rawIdPackage.Prompt).Contains($rawRequestId) -and -not ([string]$rawIdPackage.Prompt).Contains('1,234')) `
        'caller RequestId cannot inject an uncovered confidential value into the serialized prompt'
    $unrelatedFieldBlocked = $false
    try {
        $null = New-YakuProtectedPromptPackage -Kind corpus -Root $root -Direction to_en `
            -Fields @(
                [pscustomobject]@{ Name='source'; OriginalText='SAFE'; ProtectedText='SAFE' },
                [pscustomobject]@{ Name='unrelated'; OriginalText='NOT_IN_PROMPT'; ProtectedText='NOT_IN_PROMPT' }
            ) -Arguments ([pscustomobject]@{})
    } catch { $unrelatedFieldBlocked = ($_.Exception.Message -match '^PROTECTED_PROMPT_RECEIPT_UNRELATED') }
    Check-YakuH1 $unrelatedFieldBlocked 'canonical package rejects an unrelated protected field instead of treating it as send authority'
    $englishProperPackage = New-YakuProtectedPromptPackage -Kind corpus -Root $root -Direction to_jp `
        -Fields @([pscustomobject]@{ Name='source'; OriginalText='MAZDA MOTOR CORPORATION'; ProtectedText='MAZDA MOTOR CORPORATION' }) `
        -Arguments ([pscustomobject]@{})
    Check-YakuH1 ([string]$englishProperPackage.Prompt -match 'MAZDA MOTOR CORPORATION') `
        'canonical package permits registered proper nouns because only numbers are masked'
    foreach ($protectionError in @('PROTECTED_PROMPT_MUTATED','CAT_PROTECTED_PAYLOAD_MUTATED_AFTER_MASKING','SHORTEN_UNMASKED_CURRENT')) {
        Check-YakuH1 ((ConvertTo-YakuUserFacingError $protectionError) -match '原文は送信されていません.*YK-PROTECT-01') `
            ('protection failure is converted to the user-facing unsent message: ' + $protectionError)
    }

    $script:captureCount = 0
    $script:capturedPrompt = ''
    $hookCommand = Get-Command Invoke-YakuProtectedTransportTestHook -ErrorAction SilentlyContinue
    $hookOriginal = if ($null -ne $hookCommand) { $hookCommand.ScriptBlock } else { $null }
    function Invoke-YakuProtectedTransportTestHook {
        param(
            [Parameter(Mandatory=$true)][string]$Prompt,
            [Parameter(Mandatory=$true)]$Settings,
            [switch]$SkipFreshChatWait,
            [ValidateSet('labeled','numbered')][string]$AnswerFormat = 'labeled',
            [switch]$PreserveEndMarker,
            [AllowNull()]$Warnings,
            [AllowNull()]$ProgressState
        )
        $script:captureCount++
        $script:capturedPrompt = $Prompt
        return 'CAPTURED'
    }
    try {
        $protectedPrompt = '売上高は[[N1]]百万円でした。'
        $validPackage = New-YakuProtectedPromptPackage -Kind corpus -Root $root -Direction to_en `
            -Fields @([pscustomobject]@{ Name='source'; OriginalText='売上高は1,234百万円でした。'; ProtectedText=$protectedPrompt; NumericMaskMaps=@($numericMap) }) `
            -Arguments ([pscustomobject]@{ RequestId=[guid]::NewGuid().ToString('N') })
        $mutatedEnvelope = $validPackage.Envelope.PSObject.Copy()
        $mutatedEnvelope.Prompt = ([string]$mutatedEnvelope.Prompt + "`nUNVALIDATED CHANGE")
        $mutatedEnvelope.PromptSha256 = Get-YakuProtectedPromptSha256 -Text ([string]$mutatedEnvelope.Prompt)
        $mutationBlocked = $false
        try { $null = Invoke-YakuProtectedCopilotPrompt -Envelope $mutatedEnvelope -Settings ([pscustomobject]@{}) }
        catch { $mutationBlocked = $true }
        Check-YakuH1 ($mutationBlocked -and $script:captureCount -eq 0) 'prompt mutation after envelope validation is rejected before raw transport'

        $oldMaskSetting = [string]$env:YAKULINGO_NUMERIC_MASKING
        $maskDisabledBlocked = $false
        try {
            $env:YAKULINGO_NUMERIC_MASKING = 'off'
            try { $null = Invoke-YakuProtectedCopilotPrompt -Envelope $validPackage.Envelope -Settings ([pscustomobject]@{}) }
            catch { $maskDisabledBlocked = $true }
        } finally {
            if ([string]::IsNullOrEmpty($oldMaskSetting)) { Remove-Item Env:\YAKULINGO_NUMERIC_MASKING -ErrorAction SilentlyContinue } else { $env:YAKULINGO_NUMERIC_MASKING = $oldMaskSetting }
        }
        Check-YakuH1 ($maskDisabledBlocked -and $script:captureCount -eq 0) 'masking-off state is rejected before raw transport'

        $captured = Invoke-YakuProtectedCopilotPrompt -Envelope $validPackage.Envelope -Settings ([pscustomobject]@{})
        Check-YakuH1 ($script:captureCount -eq 1 -and $script:capturedPrompt -eq [string]$validPackage.Prompt -and [string]$captured -eq 'CAPTURED') 'valid canonical package reaches protected transport exactly once'
    } finally {
        if ($null -ne $hookOriginal) { Set-Item -Path Function:Invoke-YakuProtectedTransportTestHook -Value $hookOriginal }
        else { Remove-Item -Path Function:Invoke-YakuProtectedTransportTestHook -ErrorAction SilentlyContinue }
    }
    $facadeBlocked = $false
    try {
        $null = Invoke-YakuTranslationBatchItems -Root $root -Items @($item) -Settings ([pscustomobject]@{}) -Direction 'to_en' -MaxChars 1000 -Warnings (New-Object System.Collections.Generic.List[object]) -Context @{}
    } catch { $facadeBlocked = ($_.Exception.Message -match 'CAT_TRANSLATION_FACADE_REQUIRED') }
    Check-YakuH1 $facadeBlocked 'batch runner cannot bypass the CAT facade'

    Write-Host 'Review, QC, and output state' -ForegroundColor Cyan
    $project = New-YakuCatTextProject -Root $root -Text '売上高は100百万円でした。' -Settings $null -Direction 'to_en' -Translation 'Revenue was 100 million yen.'
    $segment = @($project.Segments)[0]
    Check-YakuH1 ([string]$segment.State -eq 'machine_draft' -and -not [bool]$segment.Confirmed) 'imported draft is not reviewed'
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'Revenue was 100 million yen.'
    Check-YakuH1 ([string]$segment.State -eq 'human_edited' -and -not [bool]$segment.Confirmed) 'manual editing does not imply review'
    $before = Get-YakuCatOutputEligibility -Project $project
    Check-YakuH1 (-not [bool]$before.TranslationListEligible) 'unreviewed translation cannot be exported'
    $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0
    Check-YakuH1 ([string]$segment.State -eq 'reviewed' -and [string]$segment.QcStatus -eq 'passed') 'review runs current QC and records reviewed state'
    $after = Get-YakuCatOutputEligibility -Project $project
    Check-YakuH1 ([bool]$after.TranslationListEligible) 'fully reviewed text project can produce a translation list'

    # 承認は「その時点の原文と訳文」にだけ有効でなければならない。メモリ上の
    # オブジェクトが別経路で書き換わっても、古いQCを使って出力してはいけない。
    $segment.Translation = 'Revenue was 999 million yen.'
    $afterMutation = Get-YakuCatOutputEligibility -Project $project
    Check-YakuH1 (-not [bool]$afterMutation.TranslationListEligible -and [string]$segment.State -ne 'reviewed') 'target mutation invalidates review and output eligibility'
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'Revenue was 100 million yen.'
    $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0
    $segment.QcContractVersion = 'cat-qc-v1'
    $afterOldContract = Get-YakuCatOutputEligibility -Project $project
    Check-YakuH1 (-not [bool]$afterOldContract.TranslationListEligible) 'old QC contract cannot authorize current output'
    $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0

    $bad = New-YakuCatTextProject -Root $root -Text '売上高は200百万円でした。' -Settings $null -Direction 'to_en' -Translation 'Revenue increased.'
    $qcBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $bad -Index 0 } catch { $qcBlocked = ($_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
    Check-YakuH1 $qcBlocked 'numeric-integrity failure blocks review'
    Check-YakuH1 ([string]@($bad.Segments)[0].State -ne 'reviewed') 'failed QC cannot be overridden into reviewed state'

    foreach ($case in @(
        @{ Source='営業損失は(100)百万円でした。'; Target='Operating profit was 100 million yen.'; Direction='to_en'; Label='accounting negative sign' },
        @{ Source='Revenue was 100 million yen.'; Target='売上高は100億円でした。'; Direction='to_jp'; Label='Japanese unit scale' },
        @{ Source='Revenue was 100 million dollars.'; Target='売上高は100億ドルでした。'; Direction='to_jp'; Label='non-yen unit scale' },
        @{ Source='売上高は一億二千万円でした。'; Target='Revenue was 999 million yen.'; Direction='to_en'; Label='Japanese written amount' },
        @{ Source='Revenue was two billion yen.'; Target='売上高は100億円でした。'; Direction='to_jp'; Label='English written amount' },
        @{ Source='The company recorded a loss of 100 million yen.'; Target='当社は100百万円の利益を計上しました。'; Direction='to_jp'; Label='accounting polarity' },
        @{ Source='売上高は100百万円でした。'; Target='Revenue was 100 million yen and profit was 100 million yen.'; Direction='to_en'; Label='invented extra number' }
    )) {
        $p = New-YakuCatTextProject -Root $root -Text $case.Source -Settings $null -Direction $case.Direction -Translation $case.Target
        $blocked = $false
        try { $null = Set-YakuCatSegmentConfirmed -Project $p -Index 0 } catch { $blocked = ($_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
        Check-YakuH1 $blocked ($case.Label + ' blocks review')
    }
    foreach ($case in @(
        @{ Source='売上高は一億二千万円でした。'; Target='Revenue was 120 million yen.'; Direction='to_en'; Label='Japanese written amount equivalent' },
        @{ Source='Revenue was two billion yen.'; Target='売上高は20億円でした。'; Direction='to_jp'; Label='English written amount equivalent' },
        @{ Source='売上高は1,234億円でした。'; Target='Revenue was 1,234 oku.'; Direction='to_en'; Label='oku yen-equivalent currency' },
        @{ Source='2027年度第1四半期の売上高は1,234億円、営業利益は120億円です。'; Target='For Q1 of FY2027, revenue was 1,234 oku and operating profit was 120 oku.'; Direction='to_en'; Label='fiscal-period order with financial order preserved' }
    )) {
        $p = New-YakuCatTextProject -Root $root -Text $case.Source -Settings $null -Direction $case.Direction -Translation $case.Target
        $allowed = $true
        try { $null = Set-YakuCatSegmentConfirmed -Project $p -Index 0 } catch { $allowed = $false }
        Check-YakuH1 $allowed ($case.Label + ' passes review')
    }

    Write-Host 'Financial scale, numeric lineage, and semantic sign' -ForegroundColor Cyan

    # A hyphenated attributive amount is ordinary financial English.  The
    # restorer must rescale the protected Japanese value before inserting it;
    # otherwise 120 million becomes the nonsensical 120,000,000 million.
    $hyphenSource = '売上高は一億二千万円増加しました。'
    $hyphenMask = New-YakuNumericMaskMap -Text $hyphenSource -Root $root -Direction to_en -Location 'h1-hyphenated-scale'
    $hyphenMaskedTarget = 'Net sales recorded a [[N1]]-million-yen increase.'
    $hyphenRestored = Restore-YakuNumericMask -Text $hyphenMaskedTarget -Map $hyphenMask.Map -Direction to_en
    Check-YakuH1 ([string]$hyphenRestored -eq 'Net sales recorded a 120-million-yen increase.') `
        'hyphenated financial scale restores the canonical amount without multiplying it'
    $hyphenBad = New-YakuCatTextProject -Root $root -Text $hyphenSource -Settings $null -Direction to_en `
        -Translation 'Net sales recorded a 120,000,000-million-yen increase.'
    $hyphenBadBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $hyphenBad -Index 0 } catch { $hyphenBadBlocked = ($_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
    Check-YakuH1 $hyphenBadBlocked 'QC rejects a multiplied hyphenated financial amount'

    # Counts alone are insufficient: N1 and N2 still exist after a swap, but
    # restoring them assigns the figures to the wrong financial metrics.
    $swapItem = [pscustomobject]@{ Index=91; Text='売上高は100百万円、営業利益は10百万円でした。' }
    $null = Protect-YakuCatItems -Items @($swapItem) -Root $root -Direction to_en
    $swappedMaskedTarget = 'Net sales were [[N2]] million yen and operating profit was [[N1]] million yen.'
    $swapIntegrity = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$swapItem.MaskedText) -Translated $swappedMaskedTarget -Location 'h1-token-swap'
    Check-YakuH1 (-not [bool]$swapIntegrity.Ok) 'numeric placeholder order swap is rejected before restoration'
    $swappedManual = New-YakuCatTextProject -Root $root -Text '売上高は100百万円、営業利益は10百万円でした。' -Settings $null -Direction to_en `
        -Translation 'Net sales were 10 million yen and operating profit was 100 million yen.'
    $swappedManualBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $swappedManual -Index 0 } catch { $swappedManualBlocked = ($_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
    Check-YakuH1 $swappedManualBlocked 'QC rejects manually swapped financial amounts after restoration'

    # Accounting signs may be rendered semantically rather than as a minus
    # glyph.  A decrease is equivalent to △; an increase or omitted direction
    # is not.
    $negativeSource = '営業利益は前年同期比△100百万円でした。'
    $negativeCorrect = New-YakuCatTextProject -Root $root -Text $negativeSource -Settings $null -Direction to_en `
        -Translation 'Operating profit decreased by 100 million yen year on year.'
    $negativeCorrectAllowed = $true
    try { $null = Set-YakuCatSegmentConfirmed -Project $negativeCorrect -Index 0 } catch { $negativeCorrectAllowed = $false }
    Check-YakuH1 $negativeCorrectAllowed 'semantic decrease is equivalent to a triangle-negative amount'
    foreach ($negativeBadTarget in @(
        'Operating profit increased by 100 million yen year on year.',
        'Operating profit was 100 million yen year on year.'
    )) {
        $negativeBad = New-YakuCatTextProject -Root $root -Text $negativeSource -Settings $null -Direction to_en -Translation $negativeBadTarget
        $negativeBadBlocked = $false
        try { $null = Set-YakuCatSegmentConfirmed -Project $negativeBad -Index 0 } catch { $negativeBadBlocked = ($_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
        Check-YakuH1 $negativeBadBlocked ('triangle-negative amount rejects wrong or missing direction: ' + $negativeBadTarget)
    }

    foreach ($case in @(
        @{ Source='東亜システムズは新工場を建設します。'; Target='Toa Systems will build a new plant.' },
        @{ Source='東亜未公表技研株式会社は新工場を建設します。'; Target='Toa Confidential Technology will build a new plant.' }
    )) {
        $p = New-YakuCatTextProject -Root $root -Text $case.Source -Settings $null -Direction 'to_en' -Translation $case.Target
        $allowed = $true
        try { $null = Set-YakuCatSegmentConfirmed -Project $p -Index 0 } catch { $allowed = $false }
        Check-YakuH1 $allowed 'unregistered proper noun remains reviewable because names are not masking targets'
    }

    Write-Host 'Revisioned split persistence' -ForegroundColor Cyan
    Check-YakuH1 (Save-YakuCatProject -Project $project) 'project save succeeds'
    $projectDir = Join-Path $tempRoot ([string]$project.Id)
    Check-YakuH1 (Test-Path -LiteralPath (Join-Path $projectDir 'project.json')) 'project metadata is stored separately'
    $manifest = Get-Content -LiteralPath (Join-Path $projectDir 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $generationDir = Join-Path (Join-Path $projectDir 'generations') ([string]$manifest.generation_id)
    Check-YakuH1 (Test-Path -LiteralPath (Join-Path $generationDir 'segments.jsonl')) 'segments are stored in the committed generation'
    Check-YakuH1 (Test-Path -LiteralPath (Join-Path $generationDir 'qc.jsonl')) 'QC results are stored in the committed generation'
    Check-YakuH1 (-not (Test-Path -LiteralPath (Join-Path $tempRoot ([string]$project.Id + '.json')))) 'new saves do not use the legacy monolithic JSON file'
    Check-YakuH1 (Save-YakuCatProject -Project $project) 'subsequent project save succeeds'
    Check-YakuH1 (@(Get-ChildItem -LiteralPath (Join-Path $projectDir 'generations') -Directory).Count -eq 1) 'committed generations are garbage-collected'
    $savedRevision = [int]$project.Revision
    Remove-YakuCatProject -Id ([string]$project.Id)
    $restored = Restore-YakuCatProject -Id ([string]$project.Id)
    Check-YakuH1 ($null -ne $restored -and [int]$restored.Revision -eq $savedRevision) 'project revision survives restart restore'
    Check-YakuH1 ([string]@($restored.Segments)[0].SegmentId -eq [string]$segment.SegmentId) 'stable segment ID survives restart restore'

    $revisionBeforeFault = [int]$restored.Revision
    $translationBeforeFault = [string]@($restored.Segments)[0].Translation
    @($restored.Segments)[0].Translation = 'Unsaved generation must not become current.'
    $script:yakuOriginalAtomicWriter = (Get-Command Write-YakuTextAtomic).ScriptBlock
    function Write-YakuTextAtomic {
        param([string]$Path, [AllowNull()][string]$Text)
        if ([IO.Path]::GetFileName($Path) -eq 'qc.jsonl') { throw 'forced generation write failure' }
        & $script:yakuOriginalAtomicWriter -Path $Path -Text $Text
    }
    try { $faultSave = Save-YakuCatProject -Project $restored }
    finally { Set-Item -Path Function:Write-YakuTextAtomic -Value $script:yakuOriginalAtomicWriter }
    Check-YakuH1 (-not $faultSave -and [int]$restored.Revision -eq $revisionBeforeFault) 'failed generation write does not advance the in-memory revision'
    Remove-YakuCatProject -Id ([string]$restored.Id)
    $afterFault = Restore-YakuCatProject -Id ([string]$restored.Id)
    Check-YakuH1 ([int]$afterFault.Revision -eq $revisionBeforeFault -and [string]@($afterFault.Segments)[0].Translation -eq $translationBeforeFault) 'failed generation write leaves the previous committed snapshot intact'
    Check-YakuH1 (@(Get-ChildItem -LiteralPath (Join-Path $projectDir 'generations') -Directory).Count -eq 1) 'failed uncommitted generation is garbage-collected'

    Write-Host 'Transactional CAT project mutations' -ForegroundColor Cyan
    $transactionProject = New-YakuCatTextProject -Root $root -Text '取引境界の原文' -Settings $null -Direction 'to_en' -Register $false
    $transactionProject = Commit-YakuNewCatProject -Project $transactionProject
    $transactionRevision = [int]$transactionProject.Revision
    $transactionCommittedObject = Get-YakuCatProject -Id ([string]$transactionProject.Id)
    $editMutation = {
        param($candidate,$innerText)
        $null = Set-YakuCatSegmentTranslation -Project $candidate -Index 0 -Text $innerText
    }
    $script:yakuOriginalAtomicWriter = (Get-Command Write-YakuTextAtomic).ScriptBlock
    function Write-YakuTextAtomic {
        param([string]$Path, [AllowNull()][string]$Text)
        if ([IO.Path]::GetFileName($Path) -eq 'qc.jsonl') { throw 'forced transactional generation failure' }
        & $script:yakuOriginalAtomicWriter -Path $Path -Text $Text
    }
    $transactionFailed = $false
    try {
        try { $null = Invoke-YakuCatProjectMutation -ProjectId ([string]$transactionProject.Id) -ExpectedRevision $transactionRevision -Mutation $editMutation -Arguments @('GHOST EDIT') }
        catch { $transactionFailed = ([string]$_.Exception.Message -match 'CAT_PROJECT_SAVE_FAILED') }
    } finally { Set-Item -Path Function:Write-YakuTextAtomic -Value $script:yakuOriginalAtomicWriter }
    $transactionAfterFailure = Get-YakuCatProject -Id ([string]$transactionProject.Id)
    Check-YakuH1 ($transactionFailed -and [object]::ReferenceEquals($transactionCommittedObject,$transactionAfterFailure) -and
        [int]$transactionAfterFailure.Revision -eq $transactionRevision -and
        [string]::IsNullOrWhiteSpace([string]$transactionAfterFailure.Segments[0].Translation)) 'failed mutation leaves the committed registry object, revision, and segment unchanged'
    $metadataMutation = { param($candidate) $candidate | Add-Member -NotePropertyName 'CorpusSection' -NotePropertyValue 'later unrelated save' -Force }
    $laterCommit = Invoke-YakuCatProjectMutation -ProjectId ([string]$transactionProject.Id) -ExpectedRevision $transactionRevision -Mutation $metadataMutation
    Remove-YakuCatProject -Id ([string]$transactionProject.Id)
    $transactionRestored = Restore-YakuCatProject -Id ([string]$transactionProject.Id)
    Check-YakuH1 ([int]$transactionRestored.Revision -eq ($transactionRevision + 1) -and
        [string]::IsNullOrWhiteSpace([string]$transactionRestored.Segments[0].Translation)) 'a later successful save cannot persist a rejected ghost edit'

    $conflictProject = New-YakuCatTextProject -Root $root -Text '競合する原文' -Settings $null -Direction 'to_en' -Register $false
    $conflictProject = Commit-YakuNewCatProject -Project $conflictProject
    $staleRevision = [int]$conflictProject.Revision
    $firstCommit = Invoke-YakuCatProjectMutation -ProjectId ([string]$conflictProject.Id) -ExpectedRevision $staleRevision -Mutation $editMutation -Arguments @('first commit')
    $secondConflict = $false
    try { $null = Invoke-YakuCatProjectMutation -ProjectId ([string]$conflictProject.Id) -ExpectedRevision $staleRevision -Mutation $editMutation -Arguments @('stale second commit') }
    catch { $secondConflict = ([string]$_.Exception.Message -match 'CAT_PROJECT_REVISION_CONFLICT') }
    $conflictCommitted = Get-YakuCatProject -Id ([string]$conflictProject.Id)
    Check-YakuH1 ($secondConflict -and [int]$conflictCommitted.Revision -eq ($staleRevision + 1) -and
        [string]$conflictCommitted.Segments[0].Translation -eq 'first commit') 'lock-internal revision check allows only one stale-revision mutation to commit'

    $checkpointTx = New-YakuCatTextProject -Root $root -Text 'checkpoint transactional source' -Settings $null -Direction 'to_en' -Register $false
    $checkpointTx = Commit-YakuNewCatProject -Project $checkpointTx
    $checkpointTxRevision = [int]$checkpointTx.Revision
    $null = Save-YakuCatBatchCheckpoint -ProjectId ([string]$checkpointTx.Id) -ProjectRevision $checkpointTxRevision -Translations @(
        [ordered]@{ index=0; source='checkpoint transactional source'; text='checkpoint result'; masked='checkpoint result' })
    $checkpointPath = Get-YakuCatCheckpointPath -ProjectId ([string]$checkpointTx.Id)
    $script:yakuOriginalProjectSaver = (Get-Command Save-YakuCatProject).ScriptBlock
    Set-Item -Path Function:Save-YakuCatProject -Value { param($Project) return $false }
    try { $failedCheckpointApply = Apply-YakuCatBatchCheckpoint -Project $checkpointTx }
    finally { Set-Item -Path Function:Save-YakuCatProject -Value $script:yakuOriginalProjectSaver }
    $checkpointAfterFailure = Get-YakuCatProject -Id ([string]$checkpointTx.Id)
    Check-YakuH1 ($failedCheckpointApply -eq 0 -and (Test-Path -LiteralPath $checkpointPath -PathType Leaf) -and
        [int]$checkpointAfterFailure.Revision -eq $checkpointTxRevision -and
        [string]::IsNullOrWhiteSpace([string]$checkpointAfterFailure.Segments[0].Translation)) 'failed checkpoint commit keeps checkpoint and leaves the project unchanged'
    $checkpointApplied = Apply-YakuCatBatchCheckpoint -Project $checkpointAfterFailure
    $checkpointCommitted = Get-YakuCatProject -Id ([string]$checkpointTx.Id)
    Check-YakuH1 ($checkpointApplied -eq 1 -and -not (Test-Path -LiteralPath $checkpointPath -PathType Leaf) -and
        [int]$checkpointCommitted.Revision -eq ($checkpointTxRevision + 1) -and
        [string]$checkpointCommitted.Segments[0].Translation -eq 'checkpoint result') 'checkpoint swaps committed state and is deleted only after successful persistence'

    $uncommittedProject = New-YakuCatTextProject -Root $root -Text 'new project must not leak' -Settings $null -Direction 'to_en' -Register $false
    $script:yakuOriginalProjectSaver = (Get-Command Save-YakuCatProject).ScriptBlock
    Set-Item -Path Function:Save-YakuCatProject -Value { param($Project) return $false }
    $newCommitFailed = $false
    try { try { $null = Commit-YakuNewCatProject -Project $uncommittedProject } catch { $newCommitFailed = $true } }
    finally { Set-Item -Path Function:Save-YakuCatProject -Value $script:yakuOriginalProjectSaver }
    Check-YakuH1 ($newCommitFailed -and $null -eq (Get-YakuCatProject -Id ([string]$uncommittedProject.Id))) 'failed new-project commit does not publish an in-memory project'

    $incomingWorkbook = Join-Path $tempRoot 'incoming-source.xlsx'
    [IO.File]::WriteAllBytes($incomingWorkbook, [byte[]](1,2,3,4,5,6,7,8))
    $fileProject = New-YakuCatTextProject -Root $root -Text '原本保存テスト' -Settings $null -Direction 'to_en' -Translation 'Source retention test'
    $fileProject.Source = 'file'
    $fileProject.Path = $incomingWorkbook
    $fileProject.FileName = 'incoming-source.xlsx'
    Check-YakuH1 (Save-YakuCatProject -Project $fileProject) 'file project save claims a project-owned source artifact'
    $ownedSource = [string]$fileProject.Path
    $ownedManifest = Get-Content -LiteralPath (Join-Path (Join-Path $tempRoot ([string]$fileProject.Id)) 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check-YakuH1 ($ownedSource -ne $incomingWorkbook -and (Test-Path -LiteralPath $ownedSource -PathType Leaf) -and
        [string]$ownedManifest.source_artifact_relative_path -match '^source/original\.xlsx$' -and
        -not [string]::IsNullOrWhiteSpace([string]$ownedManifest.source_artifact_sha256)) 'manifest binds the owned source path, hash, and size'
    Remove-Item -LiteralPath $incomingWorkbook -Force
    Remove-YakuCatProject -Id ([string]$fileProject.Id)
    $restoredFileProject = Restore-YakuCatProject -Id ([string]$fileProject.Id)
    Check-YakuH1 ($null -ne $restoredFileProject -and [string]$restoredFileProject.Path -eq $ownedSource -and
        (Test-Path -LiteralPath ([string]$restoredFileProject.Path) -PathType Leaf)) 'file project survives source upload removal and restart restore'
    [IO.File]::WriteAllBytes($ownedSource, [byte[]](9,9,9))
    Remove-YakuCatProject -Id ([string]$fileProject.Id)
    $tamperedSourceBlocked = $false
    try { $null = Restore-YakuCatProject -Id ([string]$fileProject.Id) } catch { $tamperedSourceBlocked = ($_.Exception.Message -match 'CAT_SOURCE_ARTIFACT_INTEGRITY_FAILED') }
    Check-YakuH1 $tamperedSourceBlocked 'tampered project-owned source artifact is rejected on restore'
    Remove-YakuCatProject -Id ([string]$fileProject.Id) -DeleteStored

    $deleteProject = New-YakuCatTextProject -Root $root -Text '削除テスト' -Settings $null -Direction 'to_en' -Translation 'Deletion test'
    Check-YakuH1 (Save-YakuCatProject -Project $deleteProject) 'project to delete is persisted'
    $legacyDeletePath = Join-Path $tempRoot ([string]$deleteProject.Id + '.json')
    Write-YakuTextAtomic -Path $legacyDeletePath -Text '{}'
    $null = Save-YakuCatBatchCheckpoint -ProjectId ([string]$deleteProject.Id) -ProjectRevision ([int]$deleteProject.Revision) -Translations @([pscustomobject]@{ index=0; source='削除テスト'; text='Deletion test'; masked='Deletion test' })
    Remove-YakuCatProject -Id ([string]$deleteProject.Id) -DeleteStored
    $deletedCheckpoint = Get-YakuCatCheckpointPath -ProjectId ([string]$deleteProject.Id)
    Check-YakuH1 (-not (Test-Path -LiteralPath (Join-Path $tempRoot ([string]$deleteProject.Id))) -and -not (Test-Path -LiteralPath $legacyDeletePath) -and -not (Test-Path -LiteralPath $deletedCheckpoint)) 'delete removes current, legacy, and checkpoint storage'
    $lateCheckpointBlocked = $false
    try { $null = Save-YakuCatBatchCheckpoint -ProjectId ([string]$deleteProject.Id) -ProjectRevision ([int]$deleteProject.Revision) -Translations @([pscustomobject]@{ index=0; source='削除テスト'; text='late'; masked='late' }) } catch { $lateCheckpointBlocked = ($_.Exception.Message -match 'CAT_PROJECT_DELETED') }
    Check-YakuH1 $lateCheckpointBlocked 'delete tombstone blocks late worker checkpoints'

    $sourceSentinel = 'sensitive-source-原文'
    $key1 = Get-YakuTranslationCacheKey -Kind 'cat' -Direction 'to_en' -Text $sourceSentinel -Style (Get-YakuCatCacheStyle) -Root $root -Settings ([pscustomobject]@{})
    $key2 = Get-YakuTranslationCacheKey -Kind 'cat' -Direction 'to_en' -Text $sourceSentinel -Style (Get-YakuCatCacheStyle) -Root $root -Settings ([pscustomobject]@{})
    $digestPart = @($key1 -split '\|')[-1]
    Check-YakuH1 (-not [string]::IsNullOrWhiteSpace($key1) -and $key1 -eq $key2 -and $key1.IndexOf($sourceSentinel, [StringComparison]::Ordinal) -lt 0 -and $digestPart -match '^[0-9a-f]{64}$') 'cache key uses a stable keyed digest without source text'

    $processors = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'FileProcessors.ps1'))
    Check-YakuH1 ($processors -match 'YakuLingoArtifactStatus' -and $processors -match 'CAT_DRAFT_MARKER_FAILED') 'DRAFT Excel requires an in-workbook marker'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failed -gt 0) { throw ("Horizon 1 tests failed: " + $script:failed) }
Write-Host 'Horizon 1 tests passed.' -ForegroundColor Green
