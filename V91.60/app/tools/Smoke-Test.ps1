param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

foreach ($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','Html.ps1','EdgeLaunch.ps1','CopilotClient.ps1','PromptBuilder.ps1','FileProcessors.ps1','FileTranslation.ps1','Translation.ps1')) {
    . (Join-Path $root ('src\' + $name))
}

$script:Passed = 0
function Assert-Yaku {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Passed++
}
function Assert-YakuThrows {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = [string]$_.Exception.Message }
    Assert-Yaku -Condition (-not [string]::IsNullOrWhiteSpace($caught) -and $caught -match $Pattern) -Message $Message
}

$settings = Read-YakuSettings -Root $root
$requestId = '0123456789abcdef0123456789abcdef'

$emptyFreshMock = [pscustomobject]@{ inputReady=$true; inputTextLength=0; sendButtonReady=$false; voiceChatButtonReady=$true; composerReady=$true }
Assert-Yaku -Condition (Test-YakuCopilotFreshReadyState -ReadyOk $true -State $emptyFreshMock) -Message 'empty fresh chat must be accepted when input is ready and the text send button is absent'
Assert-Yaku -Condition (-not (Test-YakuCopilotFreshReadyState -ReadyOk $false -State $emptyFreshMock)) -Message 'fresh chat must still reject a failed outer ready result'

$defaultWindow = ConvertTo-YakuEdgeWindowSize -Value '1280,900'
$disabledWindow = ConvertTo-YakuEdgeWindowSize -Value 'none'
Assert-Yaku -Condition ($defaultWindow.Enabled -and $defaultWindow.Width -eq 1280 -and $defaultWindow.Height -eq 900) -Message 'default Edge window size must normalize to 1280x900'
Assert-Yaku -Condition (-not $disabledWindow.Enabled -and $disabledWindow.Canonical -eq 'none') -Message 'edge_window_size=none must disable startup normalization'

Assert-Yaku -Condition (-not (ConvertTo-YakuBoolSetting -Value 'false' -Default $true)) -Message 'string false must stay false for privacy-sensitive settings'
Assert-Yaku -Condition (-not (ConvertTo-YakuBoolSetting -Value 'unexpected' -Default $false)) -Message 'unknown Boolean text must fail closed'
Assert-Yaku -Condition ((Get-YakuDirection -Text 'ﾃﾞｰﾀｲﾁﾗﾝ') -eq 'to_en') -Message 'half-width Katakana must be detected as Japanese'
Assert-Yaku -Condition ((Get-YakuDirection -Text 'Please contact Tanaka様 for details') -eq 'to_jp') -Message 'one Japanese honorific in English must not flip direction'
$directionCases = @(
    @{ Text='通常の日本語ビジネス文です。'; Direction='to_en'; Confidence='high' },
    @{ Text='我们将在下季度调整经营计划'; Direction='to_jp'; Confidence='high' },
    @{ Text='営業利益増減要因'; Direction='to_en'; Confidence='low' },
    @{ Text='経済対策関連'; Direction='to_en'; Confidence='high' },
    @{ Text='This is an English business sentence.'; Direction='to_jp'; Confidence='high' }
)
foreach ($case in $directionCases) {
    $analysis = Get-YakuDirectionAnalysis -Text $case.Text
    Assert-Yaku -Condition ([string]$analysis.Direction -eq [string]$case.Direction) -Message ('direction mismatch: ' + $case.Text)
    Assert-Yaku -Condition ([string]$analysis.Confidence -eq [string]$case.Confidence) -Message ('confidence mismatch: ' + $case.Text)
}
foreach ($ch in $script:YakuZhSimplifiedChars.ToCharArray()) {
    Assert-Yaku -Condition ($script:YakuJaSpecificChars.IndexOf($ch) -lt 0) -Message ('direction character sets overlap: ' + $ch)
}
$sheetWarnings = New-Object System.Collections.Generic.List[object]
Add-YakuWarning -Warnings $sheetWarnings -Category 'sheet-not-found' -Location 'TypoSheet' -Message '指定シートが見つかりません: TypoSheet'
Assert-Yaku -Condition (Test-YakuIncompleteWarnings -Warnings $sheetWarnings) -Message 'sheet-not-found must produce completed_with_warnings'
$singlePass = Expand-YakuTemplate -Template 'X={input_text}; ID={request_id}' -Variables @{ input_text='{request_id}'; request_id='SAFE' }
Assert-Yaku -Condition ($singlePass -eq 'X={request_id}; ID=SAFE') -Message 'template replacement values must not be expanded recursively'

$settingsTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('YakuLingo-settings-' + [guid]::NewGuid().ToString('N'))
$settingsTestDataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('YakuLingo-data-' + [guid]::NewGuid().ToString('N'))
$settingsTestPreviousDataDir = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = $settingsTestDataDir
try {
    $settingsTestConfig = Join-Path $settingsTestRoot 'config'
    New-Item -ItemType Directory -Path $settingsTestConfig -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config\settings.template.json') -Destination (Join-Path $settingsTestConfig 'settings.template.json') -Force

    $legacySettingsPath = Join-Path $settingsTestConfig 'user_settings.json'
    [System.IO.File]::WriteAllText($legacySettingsPath, '{"max_chars_per_batch":1000}', (New-Object System.Text.UTF8Encoding($true)))
    $migratedSettings = Read-YakuSettings -Root $settingsTestRoot
    $userSettingsPath = Get-YakuUserSettingsPath
    Assert-Yaku -Condition ($userSettingsPath.StartsWith($settingsTestDataDir, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'user settings must be stored under the user data directory, not the app folder'
    Assert-Yaku -Condition (Test-Path -LiteralPath $userSettingsPath -PathType Leaf) -Message 'legacy app-folder settings must be migrated to the user data directory'
    $legacyDisk = Get-Content -LiteralPath $legacySettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Yaku -Condition ([int]$legacyDisk.max_chars_per_batch -eq 1000) -Message 'migration must not write back into the app folder'
    $migratedDisk = Get-Content -LiteralPath $userSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Yaku -Condition ([int]$migratedSettings.max_chars_per_batch -eq 3000 -and [int]$migratedDisk.max_chars_per_batch -eq 3000) -Message 'saved legacy text batch default 1000 must migrate once to 3000'

    $dictionarySource = [ordered]@{ outer = [ordered]@{ inner = 'preserved' } }
    $dictionaryCopy = ConvertTo-YakuHashtable $dictionarySource
    Assert-Yaku -Condition ($dictionaryCopy -is [System.Collections.IDictionary] -and $dictionaryCopy.outer.inner -eq 'preserved') -Message 'ordered dictionaries and nested dictionaries must retain their keys during conversion'
    Assert-Yaku -Condition (-not [object]::ReferenceEquals($dictionarySource, $dictionaryCopy)) -Message 'dictionary conversion must return a copy instead of sharing the input instance'

    $enabledItems = @(Save-YakuUserSettings -Root $settingsTestRoot -Form @{ request_timeout = 600; full_text_diagnostics_enabled = $true })
    Assert-Yaku -Condition ($enabledItems.Count -eq 1) -Message 'settings save must return exactly one settings object'
    Assert-Yaku -Condition ($enabledItems[0].full_text_diagnostics_enabled -is [bool] -and [bool]$enabledItems[0].full_text_diagnostics_enabled) -Message 'diagnostic setting true must persist as Boolean true'
    Assert-Yaku -Condition ([int]$enabledItems[0].request_timeout -eq 600) -Message 'non-default numeric setting must persist'
    $enabledDisk = Get-Content -LiteralPath $userSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Yaku -Condition ($enabledDisk.full_text_diagnostics_enabled -is [bool] -and [bool]$enabledDisk.full_text_diagnostics_enabled) -Message 'diagnostic setting true must be written to disk as Boolean true'
    Assert-Yaku -Condition ([int]$enabledDisk.request_timeout -eq 600) -Message 'non-default numeric setting must be written to disk'

    $reloaded = Read-YakuSettings -Root $settingsTestRoot
    Assert-Yaku -Condition ([bool]$reloaded.full_text_diagnostics_enabled -and [int]$reloaded.request_timeout -eq 600) -Message 'saved non-default settings must survive disk reload'

    $disabledItems = @(Save-YakuUserSettings -Root $settingsTestRoot -Form @{ full_text_diagnostics_enabled = $false })
    Assert-Yaku -Condition ($disabledItems.Count -eq 1) -Message 'repeated settings save must return exactly one settings object'
    Assert-Yaku -Condition ($disabledItems[0].full_text_diagnostics_enabled -is [bool] -and -not [bool]$disabledItems[0].full_text_diagnostics_enabled) -Message 'diagnostic setting false must persist as Boolean false'
    $disabledDisk = Get-Content -LiteralPath $userSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Yaku -Condition ($disabledDisk.full_text_diagnostics_enabled -is [bool] -and -not [bool]$disabledDisk.full_text_diagnostics_enabled) -Message 'diagnostic setting false must be written to disk as Boolean false'
    Assert-Yaku -Condition ([int]$disabledDisk.request_timeout -eq 600) -Message 'saving one setting must not reset another saved setting to its default'

    $stringEnabled = Save-YakuUserSettings -Root $settingsTestRoot -Form @{ full_text_diagnostics_enabled = 'true' }
    Assert-Yaku -Condition ($stringEnabled.full_text_diagnostics_enabled -is [bool] -and [bool]$stringEnabled.full_text_diagnostics_enabled) -Message 'legacy string true must normalize to Boolean true'
    Assert-YakuThrows -Action { Save-YakuUserSettings -Root $settingsTestRoot -Form @{ full_text_diagnostics_enabled = 'invalid' } } -Pattern 'true/false' -Message 'invalid diagnostic Boolean must fail instead of silently becoming false'
} finally {
    if ([string]::IsNullOrEmpty($settingsTestPreviousDataDir)) {
        Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue
    } else {
        $env:YAKULINGO_DATA_DIR = $settingsTestPreviousDataDir
    }
    if (Test-Path -LiteralPath $settingsTestRoot) { Remove-Item -LiteralPath $settingsTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $settingsTestDataDir) { Remove-Item -LiteralPath $settingsTestDataDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-Yaku -Condition (Test-YakuCopilotUrl -Url 'https://m365.cloud.microsoft/chat/') -Message 'approved Copilot URL must pass'
Assert-Yaku -Condition (-not (Test-YakuCopilotUrl -Url 'http://m365.cloud.microsoft/chat/')) -Message 'HTTP Copilot URL must fail'
Assert-Yaku -Condition (-not (Test-YakuCopilotUrl -Url 'https://m365.cloud.microsoft.evil.example/chat/')) -Message 'lookalike host must fail'
Assert-Yaku -Condition (-not (Test-YakuCopilotUrl -Url 'https://m365.cloud.microsoft/chat/?next=https://evil.example')) -Message 'query string must fail'
Assert-Yaku -Condition (Test-YakuCopilotModelLabelMatch -Label 'GPT 5.6 Think deeper' -ModelPriority @('GPT 5.6 Think deeper','Opus')) -Message 'ready-state model label must match the configured primary model'
Assert-Yaku -Condition (-not (Test-YakuCopilotModelLabelMatch -Label '' -ModelPriority @('GPT 5.6 Think deeper'))) -Message 'missing model label must fall back to the full selector path'

$originalGetCopilotState = (Get-Item Function:\Get-YakuCopilotState).ScriptBlock
try {
    Set-Item Function:\Get-YakuCopilotState -Value { param($Page, [int]$TimeoutSeconds = 8) return [pscustomobject]@{ url='https://m365.cloud.microsoft/chat/'; inputReady=$true } }
    $legacyTrusted = Assert-YakuCopilotPageTrusted -Page ([pscustomobject]@{}) -Stage 'smoke-legacy-success'
    Assert-Yaku -Condition ([string]$legacyTrusted.url -eq 'https://m365.cloud.microsoft/chat/') -Message 'successful legacy state without ok must remain trusted'

    Set-Item Function:\Get-YakuCopilotState -Value { param($Page, [int]$TimeoutSeconds = 8) return [pscustomobject]@{ ok=$false; url='https://m365.cloud.microsoft/chat/' } }
    Assert-YakuThrows -Action { Assert-YakuCopilotPageTrusted -Page ([pscustomobject]@{}) -Stage 'smoke-explicit-failure' } -Pattern '^COPILOT_PAGE_STATE_UNKNOWN:' -Message 'explicit state failure must be retryable rather than trusted'

    Set-Item Function:\Get-YakuCopilotState -Value { param($Page, [int]$TimeoutSeconds = 8) return [pscustomobject]@{ url='https://example.invalid/chat/' } }
    Assert-YakuThrows -Action { Assert-YakuCopilotPageTrusted -Page ([pscustomobject]@{}) -Stage 'smoke-origin-mismatch' } -Pattern '^COPILOT_ORIGIN_MISMATCH:' -Message 'a real unapproved URL must remain an origin mismatch'
} finally {
    Set-Item Function:\Get-YakuCopilotState -Value $originalGetCopilotState
}

$textPrompt = New-YakuTextPrompt -Root $root -InputText 'これはテストです。' -Settings $settings -DirectionOverride 'to_en' -RequestId $requestId
Assert-Yaku -Condition $textPrompt.Prompt.Contains("YAKULINGO_END:$requestId") -Message 'text prompt must carry random contract ID'
$textRaw = "FULL_TEXT:`nThis is a test.`nBRIEF_TEXT:`nTest.`nYAKULINGO_END:$requestId"
$textResult = @(Parse-YakuTextTranslationResponse -Raw $textRaw -Direction 'to_en' -RequestId $requestId)
Assert-Yaku -Condition ($textResult.Count -eq 2) -Message 'valid two-style text response must parse'
Assert-YakuThrows -Action { Parse-YakuTextTranslationResponse -Raw $textRaw -Direction 'to_en' -RequestId ('f' * 32) } -Pattern 'RESPONSE_END_MARKER_MISSING' -Message 'wrong text contract ID must fail'
$inlineResult = @(Parse-YakuTextTranslationResponse -Raw ("FULL_TEXT:`nA`nBRIEF_TEXT:`nB YAKULINGO_END:${requestId}この会話を停止しました。") -Direction 'to_en' -RequestId $requestId)
Assert-Yaku -Condition ($inlineResult.Count -eq 2 -and [string]$inlineResult[1].Translation -eq 'B') -Message 'inline marker and trailing stopped UI text must normalize and parse'
Assert-YakuThrows -Action { Parse-YakuTextTranslationResponse -Raw ("FULL_TEXT:`nA`nBRIEF_TEXT:`nB`nYAKULINGO_END:$requestId`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId } -Pattern 'RESPONSE_END_MARKER_DUPLICATE' -Message 'duplicate exact request marker must remain invalid'
Assert-YakuThrows -Action { Parse-YakuTextTranslationResponse -Raw ("FULL_TEXT:`nA`nFULL_TEXT:`nB`nBRIEF_TEXT:`nC`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId } -Pattern 'RESPONSE_LABEL_COUNT_INVALID' -Message 'duplicate style must fail'

$actualV85Raw = ([char]0x200C) + "JAPANESE_TEXT：完全な翻訳です。 YAKULINGO_END:${requestId}この会話を停止しました。"
$actualV85Result = @(Parse-YakuTextTranslationResponse -Raw $actualV85Raw -Direction 'to_jp' -RequestId $requestId)
Assert-Yaku -Condition ($actualV85Result.Count -eq 1 -and [string]$actualV85Result[0].Translation -eq '完全な翻訳です。') -Message 'V85 invisible-prefix/fullwidth-colon/inline-marker response must parse'
$decoratedRaw = "**FULL_TEXT:** Full.`n**BRIEF_TEXT**： Brief. **YAKULINGO_END:$requestId**"
$decoratedResult = @(Parse-YakuTextTranslationResponse -Raw $decoratedRaw -Direction 'to_en' -RequestId $requestId)
Assert-Yaku -Condition ($decoratedResult.Count -eq 2 -and [string]$decoratedResult[1].Translation -eq 'Brief.') -Message 'Markdown-decorated labels and fullwidth colon must parse'
$recoveredContract = Test-YakuTextResponseContract -Text ("先頭UI文言`nFULL_TEXT: Full.`nBRIEF_TEXT: Brief.`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId
Assert-Yaku -Condition ([bool]$recoveredContract.Valid -and [string]$recoveredContract.WarningCode -eq 'RESPONSE_PREFIX_RECOVERED') -Message 'leading junk rescue must be explicit and warning-bearing'
$recoveryWarnings = New-Object System.Collections.Generic.List[object]
$null = @(Parse-YakuTextTranslationResponse -Raw ("先頭UI文言`nFULL_TEXT: Full.`nBRIEF_TEXT: Brief.`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId -Warnings $recoveryWarnings)
Assert-Yaku -Condition ($recoveryWarnings.Count -eq 1 -and [string]$recoveryWarnings[0].Category -eq 'response-contract-recovery') -Message 'rescued prefix must be surfaced in the result warning list'
$structure = Get-YakuTextResponseStructureMetadata -Raw $actualV85Raw -RequestId $requestId
Assert-Yaku -Condition ($structure.leading_code_points.StartsWith('U+200C') -and $structure.end_marker_inline -and $structure.has_fullwidth_colon -and $structure.has_stopped_ui_text) -Message 'privacy-safe response structure metadata must expose contract-shape evidence'

$diagnosticRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('YakuLingo-contract-diag-' + [guid]::NewGuid().ToString('N'))
$originalGetSubDir = (Get-Item Function:\Get-YakuSubDir).ScriptBlock
$originalDiagnosticsEnabled = (Get-Item Function:\Test-YakuFullTextDiagnosticsEnabled).ScriptBlock
$originalWriteLog = (Get-Item Function:\Write-YakuLog).ScriptBlock
try {
    New-Item -ItemType Directory -Path $diagnosticRoot -Force | Out-Null
    $script:V85DiagnosticRoot = $diagnosticRoot
    Set-Item Function:\Get-YakuSubDir -Value { param([string]$Name) return $script:V85DiagnosticRoot }
    Set-Item Function:\Test-YakuFullTextDiagnosticsEnabled -Value { return $false }
    Set-Item Function:\Write-YakuLog -Value { param([string]$Message, [string]$Level = 'INFO') }
    $diagnosticPath = Write-YakuTextResponseContractDiagnostic -Raw $actualV85Raw -Direction 'to_jp' -RequestId $requestId -ErrorCode 'RESPONSE_PREFIX_INVALID' -ErrorMessage 'mock' -Attempt 1
    $diagnosticEntry = Get-Content -LiteralPath $diagnosticPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Yaku -Condition ((Test-Path -LiteralPath $diagnosticPath) -and $diagnosticEntry.structure.leading_code_points.StartsWith('U+200C') -and ([string](@($diagnosticEntry.structure.required_labels)[0]) -eq 'JAPANESE_TEXT') -and -not ($diagnosticEntry.structure.PSObject.Properties.Name -contains 'clean_head') -and -not ($diagnosticEntry.PSObject.Properties.Name -contains 'raw_response')) -Message 'full diagnostics off must write required-label metadata without response text'
} finally {
    Set-Item Function:\Get-YakuSubDir -Value $originalGetSubDir
    Set-Item Function:\Test-YakuFullTextDiagnosticsEnabled -Value $originalDiagnosticsEnabled
    Set-Item Function:\Write-YakuLog -Value $originalWriteLog
    Remove-Variable -Name V85DiagnosticRoot -Scope Script -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $diagnosticRoot) { Remove-Item -LiteralPath $diagnosticRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$progressState = [hashtable]::Synchronized(@{ progress=8; batch_current=1; batch_total=2; batch_progress_start=8; batch_progress_end=50; batch_input_length=940 })
Set-YakuCopilotProgressPhase -ProgressState $progressState -Phase 'generating' -Label '生成中' -Detail 'Copilot応答待ち' -Progress 88
Assert-Yaku -Condition ([int]$progressState.progress -eq 44 -and [string]$progressState.label -eq 'バッチ 1/2: 生成中' -and [string]$progressState.detail -match '入力 940字') -Message 'batch one local progress must map into its overall range using input characters'
Set-YakuTranslationProgress -ProgressState $progressState -Label 'バッチ 1/2: 完了' -Progress 50
$progressState.batch_current=2; $progressState.batch_progress_start=50; $progressState.batch_progress_end=92; $progressState.batch_input_length=937
Set-YakuCopilotProgressPhase -ProgressState $progressState -Phase 'inputting' -Label '入力中' -Detail '' -Progress 25
Assert-Yaku -Condition ([int]$progressState.progress -eq 60 -and [string]$progressState.label -eq 'バッチ 2/2: 入力中' -and [string]$progressState.detail -eq '入力 937字') -Message 'batch two progress must remain monotonic and use its overall range'

$fileItems = @(
    [pscustomobject]@{ Index=11; Text='売上高'; BlockIds=@('a') },
    [pscustomobject]@{ Index=22; Text='営業利益'; BlockIds=@('b') }
)
$filePrompt = New-YakuFilePrompt -Root $root -Items $fileItems -Settings $settings -Direction 'to_en' -RequestId $requestId
Assert-Yaku -Condition ($filePrompt.Contains('[[ID:1]] 1.') -and $filePrompt.Contains('[[ID:2]] 2.') -and $filePrompt.Contains("YAKULINGO_END:$requestId")) -Message 'file prompt must define ordered IDs and contract ID'
$fileRaw = "[[ID:1]] 1. Revenue`n[[ID:2]] 2. Operating profit`nYAKULINGO_END:$requestId"
$fileResult = Parse-YakuNumberedBatchResponse -Raw $fileRaw -ExpectedIds @(1,2) -RequestId $requestId
Assert-Yaku -Condition ($fileResult.ReceivedCount -eq 2 -and $fileResult.Items[2] -eq 'Operating profit') -Message 'valid file response must parse'
Assert-YakuThrows -Action { Parse-YakuNumberedBatchResponse -Raw ("[[ID:2]] 2. B`n[[ID:1]] 1. A`nYAKULINGO_END:$requestId") -ExpectedIds @(1,2) -RequestId $requestId } -Pattern 'FILE_RESPONSE_ORDER_INVALID' -Message 'out-of-order IDs must fail'
Assert-YakuThrows -Action { Parse-YakuNumberedBatchResponse -Raw ("[[ID:1]] 1. A`nYAKULINGO_END:$requestId") -ExpectedIds @(1,2) -RequestId $requestId } -Pattern 'FILE_RESPONSE_MISSING_ID' -Message 'missing file ID must fail'
Assert-YakuThrows -Action { Parse-YakuNumberedBatchResponse -Raw ("[[ID:1]] 1. A`n[[ID:1]] 1. B`nYAKULINGO_END:$requestId") -ExpectedIds @(1) -RequestId $requestId } -Pattern 'FILE_RESPONSE_DUPLICATE_ID' -Message 'duplicate file ID must fail'
Assert-Yaku -Condition (-not (Test-YakuFileTranslationInvalid -Source '株式会社デンソーの業績' -Translation '株式会社デンソー performance improved' -Direction 'to_en')) -Message 'protected Japanese company name in normal English must pass'
Assert-Yaku -Condition (Test-YakuFileTranslationInvalid -Source 'Please review this.' -Translation 'I cannot translate this due to policy.' -Direction 'to_jp') -Message 'English refusal instead of Japanese must fail'
Assert-Yaku -Condition (-not (Test-YakuFileTranslationInvalid -Source '配当方針' -Translation 'Dividend policy' -Direction 'to_en')) -Message 'ordinary business use of policy must not be treated as a refusal'
Assert-Yaku -Condition (-not (Test-YakuFileTranslationInvalid -Source '123.4%' -Translation '123.4%' -Direction 'to_en')) -Message 'numeric-only text must remain unchanged without a false failure'
Assert-Yaku -Condition (-not (Test-YakuFileTranslationInvalid -Source 'EBITDA' -Translation 'EBITDA' -Direction 'to_jp')) -Message 'protected abbreviation must remain unchanged without a false failure'

$auditItems = @(
    [pscustomobject]@{ Index=1; Text='営業利益率'; BlockIds=@('a') },
    [pscustomobject]@{ Index=2; Text='売上高'; BlockIds=@('b') }
)
$auditTranslations = @{ 1='Operating margin'; 2='Sales' }
$auditMatches = @(
    [pscustomobject]@{ From='営業利益率'; To='Operating margin'; Row=1 },
    [pscustomobject]@{ From='利益'; To='Profit'; Row=2 },
    [pscustomobject]@{ From='売上高'; To='Revenue'; Row=3 }
)
$audit = Get-YakuFileGlossaryOccurrenceAudit -Matches $auditMatches -Items $auditItems -TranslationByIndex $auditTranslations -Blocks @()
Assert-Yaku -Condition ($audit.Checked -eq 2 -and $audit.Violated -eq 1) -Message 'item occurrence glossary audit must use one canonical checked/violated result'
Assert-Yaku -Condition ($audit.ExcludedContained -eq 1) -Message 'short glossary terms fully covered by a longer term must be excluded'
Assert-Yaku -Condition ($audit.Violations[0].ItemIndex -eq 2 -and $audit.Violations[0].Reason -eq 'missing-expected-term') -Message 'glossary violation must identify the exact item and reason'

$scopeItems = @(
    [pscustomobject]@{ Index=1; Text='タイ'; BlockIds=@('thai') },
    [pscustomobject]@{ Index=2; Text='タイミング変更'; BlockIds=@('timing') },
    [pscustomobject]@{ Index=3; Text='仕向地別営業利益 四半期推移'; BlockIds=@('quarter') }
)
$scopeMatches = @(
    [pscustomobject]@{ From='タイ'; To='Thailand'; Row=173 },
    [pscustomobject]@{ From='半期'; To='Half-year'; Row=90 }
)
$scopedMatches = @(ConvertTo-YakuFileItemScopedGlossaryMatches -Matches $scopeMatches -Items $scopeItems)
Assert-Yaku -Condition ($scopedMatches.Count -eq 1 -and $scopedMatches[0].ItemIndex -eq 1 -and $scopedMatches[0].From -eq 'タイ') -Message 'glossary audit matches must be scoped to the item where the exact term occurs'
Assert-Yaku -Condition (@(Find-YakuExactTermIndexes -InputText '四半期推移' -Term '半期').Count -eq 0) -Message 'half-year must not match inside quarter'
Assert-Yaku -Condition (@(Find-YakuExactTermIndexes -InputText '上半期実績' -Term '半期').Count -eq 1) -Message 'half-year must still match valid half-year compounds'

$perfItems = New-Object System.Collections.Generic.List[object]
$perfMatches = New-Object System.Collections.Generic.List[object]
$perfTranslations = @{}
for ($i = 1; $i -le 250; $i++) {
    $perfItems.Add([pscustomobject]@{ Index=$i; Text=("テスト文書 $i"); BlockIds=@() }) | Out-Null
    $perfTranslations[$i] = "Test document $i"
}
for ($i = 1; $i -le 130; $i++) { $perfMatches.Add([pscustomobject]@{ From=("未使用用語$i"); To=("Unused term $i"); Row=$i }) | Out-Null }
$perfSw = [System.Diagnostics.Stopwatch]::StartNew()
$null = Get-YakuFileGlossaryOccurrenceAudit -Matches @($perfMatches.ToArray()) -Items @($perfItems.ToArray()) -TranslationByIndex $perfTranslations -Blocks @()
$perfSw.Stop()
Assert-Yaku -Condition ($perfSw.ElapsedMilliseconds -lt 5000) -Message 'normalized glossary audit benchmark must complete within five seconds'

$env:YAKULINGO_MOCK = '1'
try {
    $mock = Invoke-YakuMockCopilotPrompt -Prompt $filePrompt
    Assert-Yaku -Condition $mock.TrimEnd().EndsWith("YAKULINGO_END:$requestId") -Message 'mock must echo the contract ID'
} finally { Remove-Item Env:YAKULINGO_MOCK -ErrorAction SilentlyContinue }

$warningResult = [pscustomobject]@{
    JobId='0123456789abcdef0123456789abcdef'; OutputName='sample_INCOMPLETE.xlsx'; InputName='sample.xlsx'; DirectionLabel='日本語 → 英語'
    OutputPath='C:\Temp\sample_INCOMPLETE.xlsx'; CompletionStatus='completed_with_warnings'
    Validation=[pscustomobject]@{ Reopenable=$true; FormulaCount=4; MacroPreserved=$true }
    Stats=[pscustomobject]@{ cells=2; shapes=0; charts=0; skipped_formula_cells=4; skipped_smartart=0 }
    Warnings=@(
        [pscustomobject]@{ Category='untranslated-retained'; Message='原文保持'; Location='A1' }
        [pscustomobject]@{ Category='glossary-compliance'; Message='用語集の訳語が反映されていない箇所が 8 件あります（行: 90, 174, 189, 196, 210, 212）。'; Location='最終用語監査' }
    )
    BlocksTotal=2; BlocksTranslated=1; BlocksWriteTarget=1; BlocksWritten=1; BlocksRetainedOriginal=1
    UniqueTextCount=2; CacheHits=0; GlossaryExactHits=0; AppliedGlossary=@(); BatchCount=1; BatchTotal=1
    TruncatedBatches=0; MaxRetryDepthReached=0; DurationSeconds=1
}
$warningHtml = Convert-YakuFileResultToHtml -Result $warningResult
Assert-Yaku -Condition ($warningHtml.Contains('completed_with_warnings') -and $warningHtml.Contains('_INCOMPLETE') -and $warningHtml.Contains('data-yaku-download-job')) -Message 'incomplete output must be visibly distinct'
Assert-Yaku -Condition ($warningHtml.Contains('最終用語監査') -and $warningHtml.Contains('行: 90, 174, 189, 196, 210, 212')) -Message 'final glossary compliance warning must be visible in result HTML'

$appJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\app.js') -Raw -Encoding UTF8
$server = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8
$settingsSource = Get-Content -LiteralPath (Join-Path $root 'src\Settings.ps1') -Raw -Encoding UTF8
$fileWorkerSource = Get-Content -LiteralPath (Join-Path $root 'src\FileWorker.ps1') -Raw -Encoding UTF8
$copilot = Get-Content -LiteralPath (Join-Path $root 'src\CopilotClient.ps1') -Raw -Encoding UTF8
$translationSource = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
$fileTranslationSource = Get-Content -LiteralPath (Join-Path $root 'src\FileTranslation.ps1') -Raw -Encoding UTF8
$fileProcessors = Get-Content -LiteralPath (Join-Path $root 'src\FileProcessors.ps1') -Raw -Encoding UTF8
$promptBuilder = Get-Content -LiteralPath (Join-Path $root 'src\PromptBuilder.ps1') -Raw -Encoding UTF8
$edgeLaunch = Get-Content -LiteralPath (Join-Path $root 'src\EdgeLaunch.ps1') -Raw -Encoding UTF8
$warmupWorker = Get-Content -LiteralPath (Join-Path $root 'tools\Prepare-Copilot.ps1') -Raw -Encoding UTF8
$copilotAutomationTest = Get-Content -LiteralPath (Join-Path $root 'tools\Test-CopilotAutomation.ps1') -Raw -Encoding UTF8
Assert-Yaku -Condition ($appJs -match 'X-Yaku-Session' -and $appJs -match 'application/octet-stream' -and $appJs -match '/api/jobs/') -Message 'browser client must use token, binary upload, and per-job polling'
Assert-Yaku -Condition ($appJs -match "sessionStorage\.setItem\('yaku-job-id'" -and $appJs -notmatch 'yakuMaybeRestoreJobFromReadyState') -Message 'job restoration must remain scoped to the originating browser tab'
Assert-Yaku -Condition ($appJs -notmatch 'readAsDataURL|file_b64|application/x-www-form-urlencoded') -Message 'browser client must not Base64/urlencode file uploads'
Assert-Yaku -Condition ($appJs.Contains('yakuConfirmUnsavedSettings') -and $appJs.Contains('data-yaku-settings-saved')) -Message 'unsaved settings must be visible and confirmed before translation'
Assert-Yaku -Condition ($appJs.Contains('data[element.name] = !!element.checked;')) -Message 'checkbox settings must be sent as JSON Boolean values'
Assert-Yaku -Condition ($server -match 'INVALID_SESSION_TOKEN' -and $server -match 'UNSUPPORTED_CONTENT_TYPE' -and $server -match 'Local\\YakuLingo') -Message 'server boundary and single-instance controls must be present'
Assert-Yaku -Condition ($server -match 'ProcessStopper\.ps1' -and $server -match 'cancel_requested') -Message 'file cancellation must be delegated asynchronously'
Assert-Yaku -Condition ($server -notmatch 'Save-YakuIncomingFileFromForm|Parse-YakuUrlEncodedForm') -Message 'legacy Base64/form upload path must be removed'
Assert-Yaku -Condition ($server.Contains("`$method -eq 'GET' -and `$path -eq '/api/glossary'") -and -not $server.Contains("`$method -eq 'POST' -and `$path -eq '/api/glossary'") -and -not $server.Contains('/api/glossary-delete') -and $server.Contains('Add-YakuUserGlossaryEntry')) -Message 'bundled glossary API stays read-only; additions go only to the user glossary'
Assert-Yaku -Condition ($server.Contains('diagnosticsLevel=$diagnosticsLevel settingsSnapshot=job-start') -and $server.Contains('diagnosticsLevel=$script:YakuDiagnosticsLevel')) -Message 'saved and per-job diagnostic setting values must be logged and verified'
Assert-Yaku -Condition ($server.Contains('verificationSource=disk-readback') -and $server.Contains('SETTINGS_DIAGNOSTICS_VALUE_MISSING') -and $server.Contains('SETTINGS_SAVE_READBACK_FAILED')) -Message 'settings save must distinguish missing input and verify the disk readback'
Assert-Yaku -Condition ($settingsSource.Contains('data-yaku-dirty=') -and $settingsSource.Contains('ログ診断レベル：$diagnosticsLevel（保存済み）')) -Message 'settings form must display the persisted diagnostic state'
Assert-Yaku -Condition ($settingsSource.Contains('Read-YakuUserSettingsStrict') -and $settingsSource.Contains('SETTINGS_SAVE_RESULT_INVALID') -and $settingsSource.Contains('SETTINGS_SAVE_VERIFY_FAILED')) -Message 'settings save must enforce strict disk readback and a single verified result object'
$pathsSource = Get-Content -LiteralPath (Join-Path $root 'src\Paths.ps1') -Raw -Encoding UTF8
Assert-Yaku -Condition (-not $settingsSource.Contains('Join-Path $Root ''config\user_settings.json''')) -Message 'user settings must never be written inside the app folder'
Assert-Yaku -Condition ($pathsSource.Contains('function Get-YakuUserSettingsPath') -and $settingsSource.Contains('Resolve-YakuUserSettingsPath')) -Message 'user settings path must resolve through the user data directory with one-time legacy migration'
Assert-Yaku -Condition ($fileWorkerSource.Contains('File worker settings snapshot.') -and $fileWorkerSource.Contains('YakuFullTextDiagnosticsEnabled')) -Message 'file worker must apply the job diagnostic snapshot before extraction and audit logging'
Assert-Yaku -Condition ($copilot -notmatch '--remote-allow-origins=\*') -Message 'CDP wildcard origin switch must be absent'
Assert-Yaku -Condition ($copilot -match 'Get-NetTCPConnection' -and $copilot -match 'OwningProcess') -Message 'CDP port owner PID must be verified'
Assert-Yaku -Condition ($edgeLaunch.Contains('Get-Process -Name') -and $edgeLaunch.Contains("if (`$hasAnyEdge)") -and $edgeLaunch.Contains("if (`$stopped -gt 0) { Start-Sleep -Milliseconds 700 }")) -Message 'cold Edge startup must skip WMI and the fixed sleep when no Edge process exists'
Assert-Yaku -Condition ($edgeLaunch.Contains('--remote-debugging-port=') -and $edgeLaunch.Contains('--user-data-dir=') -and $copilot.Contains('Start-YakuEdgeLaunch')) -Message 'early warmup and normal translation must share one Edge launch argument definition'
Assert-Yaku -Condition ($edgeLaunch.Contains('--window-size=') -and $copilot.Contains('Browser.getWindowForTarget') -and $copilot.Contains('Browser.setWindowBounds') -and $copilot.Contains('YakuEdgeNeedsWindowNormalization')) -Message 'new Edge windows must be normalized once through launch arguments and CDP'
Assert-Yaku -Condition ($edgeLaunch.Contains("Canonical='none'") -and $settingsSource.Contains('edge_window_size')) -Message 'Edge window normalization must be configurable and disableable'
Assert-Yaku -Condition ($edgeLaunch.IndexOf('if ($alreadyReachable)') -lt $edgeLaunch.IndexOf('$script:YakuEdgeNeedsWindowNormalization =') -and $edgeLaunch.Contains('if ($spec.WindowSize.Enabled)')) -Message 'already-running Edge must return before startup-only normalization is scheduled'
Assert-Yaku -Condition ($warmupWorker.IndexOf('Start-YakuEdgeLaunch') -lt $warmupWorker.IndexOf("src\CopilotClient.ps1") -and $warmupWorker.Contains('-NoWait')) -Message 'warmup must launch Edge before loading the large Copilot module'
Assert-Yaku -Condition ($warmupWorker.Contains('ready from fresh-chat after state') -and $warmupWorker.Contains("fresh-chat after state was insufficient; using polling fallback")) -Message 'fresh-chat warmup must use a verified immediate-ready path with the legacy polling fallback'
Assert-Yaku -Condition ($warmupWorker.Contains('for ($attempt = 1; $attempt -le 5; $attempt++)') -and $warmupWorker.Contains('copilot-warmup.{0}.tmp') -and $warmupWorker.Contains('Ready status write failed; staying in polling loop to retry.')) -Message 'warmup status writes must be atomic and retry before terminal ready exit'
Assert-Yaku -Condition ($server.Contains('[System.IO.FileShare]::ReadWrite') -and $server.Contains('$script:YakuWarmupLastGood = $status') -and $server.Contains('if ($null -ne $script:YakuWarmupLastGood)')) -Message 'warmup reads must tolerate concurrent writes and retain the last good status'
Assert-Yaku -Condition ($server.LastIndexOf('Start-YakuCopilotWarmup') -lt $server.LastIndexOf('Invoke-YakuDiagnosticLogRotation') -and $server.Contains('phase=warmup-worker-dispatch')) -Message 'server startup must dispatch Copilot warmup before maintenance and log its timing'
Assert-Yaku -Condition ($translationSource.Contains('Math]::Max($currentPct, $pct)')) -Message 'text translation progress must remain monotonic across multiple batches'
Assert-Yaku -Condition ($translationSource.Contains('Get-YakuTextResponseStructureMetadata') -and $translationSource.Contains('leading_code_points') -and $translationSource.Contains("event = 'text-response-contract-rejected'")) -Message 'contract errors must always retain privacy-safe response structure metadata'
Assert-Yaku -Condition ($translationSource.Contains("'RESPONSE_PREFIX_RECOVERED'") -and $translationSource.Contains("Category 'response-contract-recovery'")) -Message 'leading response junk may only be rescued with a visible warning'
Assert-Yaku -Condition ($translationSource.Contains("`$required = @(if (`$Direction -eq 'to_en')") -and $translationSource.Contains('CONTRACT_INTERNAL: $required must be an array.')) -Message 'to_jp required labels must not be unwrapped into a scalar string'
Assert-Yaku -Condition ($translationSource.Contains("`$structure['required_labels']") -and $translationSource.Contains("`$structure['clean_head']") -and $translationSource.Contains('Test-YakuFullTextDiagnosticsEnabled')) -Message 'contract diagnostics must record required labels while gating clean response text'
Assert-Yaku -Condition ($translationSource.Contains("Phase 'retrying'") -and $translationSource.Contains('応答形式エラーのため再試行します')) -Message 'contract retries must be visible in progress state'
Assert-Yaku -Condition ($translationSource.Contains('function Get-YakuTextStructureCounts') -and $translationSource.Contains('function Test-YakuTextStructureIntegrity') -and $translationSource.Contains('RESPONSE_STRUCTURE_MISMATCH')) -Message 'text heading and bullet integrity must be validated through the existing response retry path'
Assert-Yaku -Condition ($translationSource.Contains("Category 'structure-integrity'") -and $translationSource.Contains('原文の見出し・箇条書きの一部が訳文から欠落している可能性')) -Message 'final structure mismatch must return a visible warning instead of failing the translation'
Assert-Yaku -Condition ($translationSource.Contains('function ConvertFrom-YakuTextFullWidthAngle') -and $translationSource.Contains("Replace('＜', '<').Replace('＞', '>')") -and $translationSource.IndexOf('ConvertFrom-YakuTextFullWidthAngle -Text $fullText') -lt $translationSource.IndexOf('$integrity = Test-YakuTextStructureIntegrity -SourceText $sourceText')) -Message 'to_en angle restoration must occur before structure integrity validation'
Assert-Yaku -Condition ($copilot.Contains("`$ProgressState['batch_progress_start']") -and $copilot.Contains('入力 $($batchInputLength)字')) -Message 'Copilot phase progress must map into overall batch ranges using input length'
Assert-Yaku -Condition ($settingsSource.Contains("Default=3000") -and $settingsSource.Contains("max_chars_per_batch=1000 -> 3000")) -Message 'text batch default and legacy-default migration must be 3000'
Assert-Yaku -Condition ($copilot.Contains('let rootsCache = null;') -and $copilot.Contains('(now - rootsCacheAt) < 250')) -Message 'Copilot DOM roots must be reused within a polling tick'
Assert-Yaku -Condition ($copilot.Contains('const state = (includeResponseText = false) =>') -and $copilot.Contains('responseElementCount()')) -Message 'normal Copilot state polling must avoid full response extraction'
Assert-Yaku -Condition ($copilot.Contains('Get-YakuCopilotState -Page $Page -TimeoutSeconds 10 -IncludeResponseText') -and $copilot.Contains("Get-YakuObjectPropertyValue -Object `$fillResult -Name 'state'")) -Message 'final fill snapshot must retain and reuse the previous answer text as watcher baseline'
Assert-Yaku -Condition ($copilot.Contains('YakuCdpOwnershipCache') -and $copilot.Contains('StartTimeUtcTicks') -and $copilot.Contains('falling back to full verification')) -Message 'CDP ownership cache must bind port, PID and start time with a full-verification fallback'
Assert-Yaku -Condition ($copilot.Contains('cdp-ownership.json') -and $copilot.Contains('CDP ownership file cache hit') -and $copilot.Contains('Write-YakuJsonAtomic')) -Message 'CDP ownership verification must be shared across warm runspaces through a revalidated local file cache'
Assert-Yaku -Condition ($warmupWorker.IndexOf('src\Paths.ps1') -lt $warmupWorker.IndexOf('src\Runtime.ps1') -and $warmupWorker.IndexOf('src\Runtime.ps1') -lt $warmupWorker.IndexOf('src\Settings.ps1')) -Message 'warmup worker must load Paths, Runtime, then Settings in dependency order'
Assert-Yaku -Condition ($copilot.Contains('blockingDialogCount') -and $copilot.Contains('closeBlockingDialog') -and $copilot.Contains('unsafe-send-control-rejected')) -Message 'blocking dialogs must be detected and only safely closed'
Assert-Yaku -Condition (-not $copilot.Contains("reasons.push('outside-chat-input-scope')") -and $copilot.Contains('pageWideFallback') -and $copilot.Contains('inside-non-chat-dialog') -and $copilot.Contains('obf-survey-control')) -Message 'send buttons must use exclusion-based page-wide fallback while rejecting survey dialog controls'
Assert-Yaku -Condition ($copilot.Contains('Clear-YakuCopilotInputVerified') -and $copilot.Contains('Reset-YakuCopilotChatByNavigation') -and $copilot.Contains("Page.navigate")) -Message 'send-not-confirmed retries must clear input and support navigation recovery'
Assert-Yaku -Condition ($copilot.Contains('設定モデルを選択できず') -and $translationSource.Contains('Warnings = @($warnings.ToArray())')) -Message 'model mismatch must be visible in text and file job warnings'
Assert-Yaku -Condition ($promptBuilder.Contains('YakuPromptFileCache') -and $promptBuilder.Contains('LastWriteTimeUtc.Ticks') -and $promptBuilder.Contains("Get-YakuPromptFileText -Path `$path")) -Message 'prompt files must use an mtime-and-length-aware in-memory cache'
Assert-Yaku -Condition ($promptBuilder.Contains('Casing: keep all-caps acronyms and proper nouns') -and $promptBuilder.Contains('abbreviations of ordinary words (e.g. Vol., Act.)') -and $promptBuilder.Contains('capitalized as listed only when the term stands alone as a heading or label line') -and $promptBuilder.Contains('including signed breakdown lists')) -Message 'glossary injection must distinguish all-caps acronyms and ordinary-word abbreviations'
Assert-Yaku -Condition ($promptBuilder.Contains('function Get-YakuPromptGlossaryPath') -and $promptBuilder.Contains("Join-Path `$Root 'prompt_glossary.csv'") -and $promptBuilder.Contains('return (Get-YakuGlossaryPath -Root $Root)')) -Message 'prompt glossary must have a backward-compatible glossary.csv fallback'
Assert-Yaku -Condition ($promptBuilder.Contains('[AllowNull()][string]$Path') -and $promptBuilder.Contains('YakuGlossaryEntriesCache -is [hashtable]') -and $promptBuilder.Contains('YakuGlossaryEntriesCache[$cachePathKey]')) -Message 'two glossary files must use path-aware independent cache entries'
Assert-Yaku -Condition ($translationSource.Contains("'prompt_glossary.csv'") -and $fileTranslationSource.Contains('-Path $promptGlossaryPath')) -Message 'translation fingerprint and file prompt audit must follow prompt_glossary.csv'
# 「万」の換算はプロンプトの規則ではなく、送る前のコード側の前処理が受け持つ。
$manUnitsSmoke = [string](Convert-YakuNumericUnits -Text '出荷台数は2万台です。' -Location 'smoke').Text
Assert-Yaku -Condition ($manUnitsSmoke.Contains('20 k units') -and -not $manUnitsSmoke.Contains('万台') -and $translationSource.Contains('$numericPre = Convert-YakuNumericUnits -Text $processingInput')) -Message 'man-unit conversion rule must be injected for text translation'
Assert-Yaku -Condition ($promptBuilder.Contains('表ラベル置換用 — glossary.csv') -and $promptBuilder.Contains('Copilot翻訳用 — prompt_glossary.csv') -and $promptBuilder.Contains('未作成(glossary.csv にフォールバック中)')) -Message 'read-only glossary panel must show both sources and fallback state'
Assert-Yaku -Condition (-not $promptBuilder.Contains('function Add-YakuGlossaryEntry ') -and -not $promptBuilder.Contains('function Remove-YakuGlossaryEntryByRow') -and -not $promptBuilder.Contains('glossary-delete') -and $promptBuilder.Contains("Get-YakuSubDir 'glossary'")) -Message 'bundled glossary has no write functions; user additions are stored under the user data dir'
Assert-Yaku -Condition ($copilot.Contains('Wait-YakuCopilotInputCondition') -and $copilot.Contains("Condition focused") -and $copilot.Contains("Condition empty")) -Message 'fixed fill sleeps must be replaced by focused and empty input condition waits'
Assert-Yaku -Condition ($copilot.Contains('modelSwitcherLabel') -and $copilot.Contains('already_selected_from_ready_state')) -Message 'ready state must allow already-selected model work to be skipped'
Assert-Yaku -Condition ($copilot.Contains('currentModelLabel=') -and $copilot.Contains('targets=')) -Message 'model skip misses must log the observed and configured labels'
Assert-Yaku -Condition ($copilot.Contains("Phase 'generating'") -and -not $copilot.Contains('生成中（約{0}文字）') -and $server.Contains('input_length') -and $server.Contains('aria-live')) -Message 'visible text character counts must use user input rather than prompt or response lengths'
Assert-Yaku -Condition ($copilot.Contains('Copilot send button found only by page-wide fallback.') -and $copilot.Contains('Copilot send button missing immediately after fill.') -and $copilot.Contains('送信ボタン検出: 0件')) -Message 'send discovery fallback and zero-candidate failures must be immediately diagnosable'
Assert-Yaku -Condition ($copilot.Contains('.fai-BebopLiteChatInput__inputWrapper') -and $copilot.Contains('button[type="submit"][aria-label="送信"]') -and $copilot.Contains('comparableInputText')) -Message 'known Copilot composer DOM and zero-width-normalized input lengths must be primary'
Assert-Yaku -Condition ($copilot.Contains('synthetic-click-send-button') -and $copilot.Contains('native-mouse-click-send-button-stage2') -and $copilot.Contains('guarded-enter-send-stage3') -and $copilot.Contains('Invoke-YakuCdpPressBackspace')) -Message 'send start must use synthetic, trusted native, then guarded Enter stages with rollback'
Assert-Yaku -Condition ($fileTranslationSource.Contains('File Copilot send-start recovery retry.') -and $fileTranslationSource.Contains('FILE_BATCH_SEND_FAILED') -and $fileTranslationSource.Contains('sendStartFailures -ge 3')) -Message 'file batches must retry send-start failures twice and identify the failed batch'
Assert-Yaku -Condition ($copilot.Contains('a.fai-CopilotNavItem[href="/chat"]') -and $copilot.Contains('hit.primary')) -Message 'current anchor-based New chat control must be a primary selector'
Assert-Yaku -Condition (-not $copilot.Contains('s.inputReady && s.sendButtonReady && (s.inputTextLength|0) === 0') -and -not $copilot.Contains('initialState.inputReady && initialState.sendButtonReady &&')) -Message 'empty fresh chat must not require the text-only send button'
Assert-Yaku -Condition ($copilot.Contains('function Test-YakuCopilotFreshReadyState') -and -not $copilot.Contains('$stateSendReady')) -Message 'PowerShell fresh-chat acceptance must be centralized and must not restore the send-button gate'
Assert-Yaku -Condition ($copilot.Contains('voiceChatButtonInfo') -and $copilot.Contains('composerReady: !!input && (!!sendInfo || !!voiceChatInfo)')) -Message 'state diagnostics must expose send-or-voice composer readiness'
Assert-Yaku -Condition ($copilot.Contains('unverified-send-aria-label:') -and $copilot.Contains('/^(送信|Send)$/i.test(sendAriaLabel)')) -Message 'voice-chat controls must be rejected by exact send aria-label verification'
Assert-Yaku -Condition ($copilot.Contains('switcherWaitedMs += 500') -and $copilot.Contains('i < 10 && !btn')) -Message 'model switcher must be allowed five seconds to appear after navigation'
Assert-Yaku -Condition ($copilotAutomationTest.Contains('V83_TEST_REAL_SEND_BUTTON_NOT_FOUND_AFTER_FILL') -and $copilotAutomationTest.Contains('obf-YakuRegression') -and $copilotAutomationTest.Contains('V83_TEST_SURVEY_SEND_BUTTON_NOT_REJECTED') -and $copilotAutomationTest.Contains('V83_TEST_VOICE_CHAT_BUTTON_NOT_REJECTED')) -Message 'live automation gate must verify real send discovery and reject injected survey and voice-chat buttons'
Assert-Yaku -Condition ($appJs.Contains('yakuScrollCompletionIntoView') -and $appJs.Contains('prefers-reduced-motion: reduce') -and $appJs.Contains('yakuLastManualScrollAt < 2000')) -Message 'terminal results must auto-scroll accessibly without overriding recent manual scrolling'
Assert-Yaku -Condition ($appJs.Contains('yakuResultByTab') -and $appJs.Contains('if (!yakuTranslating)') -and $appJs.Contains('yakuActiveJobKind')) -Message 'text and file results must be retained separately while active job progress remains shared'
Assert-Yaku -Condition ($copilot.Contains("`$sliceLimit = if (`$firstActivitySeen) { 3 } else { 2 }")) -Message 'active response completion polling must use three-second slices'
Assert-Yaku -Condition ($copilot.Contains("reason:'already-fresh'") -and $copilot.Contains('const seenCandidatesThisRound = new Set();')) -Message 'fresh-chat and watcher duplicate work must be eliminated'
Assert-Yaku -Condition ($copilot.Contains('FRESH_MAIN_TEXT_MAX = 4000') -and $copilot.Contains("reason:freshVerified ? 'fresh-state-confirmed' : 'fresh-state-not-confirmed'")) -Message 'fresh-chat acceptance must reject stale main content even when response selectors report zero'
Assert-Yaku -Condition ($copilot.Contains('Copilot input diagnostic log created:') -and $copilot.Contains('full-text diagnostics disabled for this request.')) -Message 'diagnostic paths must only be reported as created when full-text diagnostics are enabled'
Assert-Yaku -Condition ($copilot.Contains('[int]$FirstActivityTimeoutMs = 10000') -and $copilot.Contains('$silentConfirmMs = 2000') -and $settingsSource.Contains('copilotFirstActivityTimeoutMs')) -Message 'Copilot silent-start watchdog must retain the configurable ten-second default plus two-second confirmation'
Assert-Yaku -Condition ($copilot.Contains('[data-testid="loading-message"]') -and $copilot.Contains("kind:'stop-button-visible'") -and $copilot.Contains('misdetected:true')) -Message 'thinking UI and stop-button activity must prevent a false silent-start decision'
Assert-Yaku -Condition ($copilot.Contains('Copilot fresh chat diagnostic:') -and $copilot.Contains('Copilot fresh chat accepted.') -and $copilot.Contains('beforeResponseCount=') -and $copilot.Contains('afterResponseCount=')) -Message 'fresh-chat decisions must log compact before/after evidence'
Assert-Yaku -Condition ($translationSource.Contains('silentStartFailures') -and $translationSource.Contains('COPILOT_SILENT_START_TIMEOUT')) -Message 'text translation must retry silent start once with a new request ID'
Assert-Yaku -Condition ($translationSource.Contains('Text glossary occurrence audit:') -and $translationSource.Contains("event = 'text-glossary-occurrence-violation'") -and $translationSource.Contains('copilot-glossary-diagnostic-')) -Message 'text glossary violations must expose safe summaries and gated full diagnostics'
Assert-Yaku -Condition ($fileTranslationSource.Contains('silentStartFailures') -and $fileTranslationSource.Contains('COPILOT_SILENT_START_TIMEOUT')) -Message 'file translation must retry the current silent batch once'
Assert-Yaku -Condition ($fileTranslationSource.Contains('Glossary occurrence audit:') -and $fileTranslationSource.Contains("event = 'glossary-occurrence-violation'") -and $fileTranslationSource.Contains('Locations =')) -Message 'file glossary violations must expose occurrence and location diagnostics'
Assert-Yaku -Condition ($fileTranslationSource.Contains('basis=item-occurrence') -and $fileTranslationSource.Contains('ExcludedContained') -and $fileTranslationSource.Contains("Reason = `$reason")) -Message 'batch and final glossary diagnostics must share the item-occurrence audit and reason classification'
Assert-Yaku -Condition ($fileTranslationSource.Contains('Bracket-glossary fallback skipped (partial coverage).') -and $fileTranslationSource.Contains("[A-Za-z]{4,}")) -Message 'bracket glossary fallback must reject incomplete language coverage'
Assert-Yaku -Condition ($fileTranslationSource.Contains("Category 'glossary-compliance'") -and $fileTranslationSource.Contains("'WARN' } else { 'INFO' }")) -Message 'final glossary violations must be user-visible and logged as warnings'
Assert-Yaku -Condition ($server.Contains('detail=$errorText') -and $settingsSource.Contains('expected=$expectedPreview actual=$actualPreview')) -Message 'settings save failures must retain safe key/value mismatch details'
Assert-Yaku -Condition ($fileProcessors.Contains('[System.Xml.XmlReader]::Create') -and -not $fileProcessors.Contains("[regex]::Matches(`$xml, '(?is)<c")) -Message 'saving validation must use linear XmlReader formula scanning'
Assert-Yaku -Condition ($fileProcessors.Contains("Phase 'validating'") -and $fileProcessors.Contains("Phase 'publishing'")) -Message 'saving validation and publishing must expose distinct progress phases'
Assert-Yaku -Condition (-not $fileProcessors.Contains('Test-YakuExcelCandidateReopen -Path')) -Message 'post-save validation must not launch a second unbounded Excel COM session'
Assert-Yaku -Condition (-not $fileProcessors.Contains("Category 'merge-check-skip'")) -Message 'merge-check performance fallback must not appear as a user-facing warning'
Assert-Yaku -Condition ($fileProcessors -match "Excel merge check simplified\.[^\r\n]+ 'DEBUG'") -Message 'merge-check performance fallback must remain available in the internal debug log'

$psFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1')
foreach ($file in $psFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    Assert-Yaku -Condition ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -Message ("UTF-8 BOM required: " + $file.FullName)
}

Write-Host ("V64/V65/V66/V67/V68/V69/V70/V73/V74/V75/V76/V77/V78/V79/V80/V81/V82/V83/V84/V85/V86/V87/V87.1/V88/V89/V90/V90.1/V90.2/V90.3/V90.4/V90.5/V90.6/V90.7/V90.8/V90.9/V90.9.1/V91/V91.1/V91.2 smoke tests passed: {0}" -f $script:Passed) -ForegroundColor Green
