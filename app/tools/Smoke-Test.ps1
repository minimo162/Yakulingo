param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

foreach ($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','Html.ps1','EdgeLaunch.ps1','CopilotClient.ps1','PromptBuilder.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','Translation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1')) {
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
    # 漢字だけの短い見出しは日本語と中国語を安全に区別できないため、
    # 新しい方向契約では送信前に利用者へ確認する。
    @{ Text='経済対策関連'; Direction='to_en'; Confidence='low' },
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
Assert-Yaku -Condition (Test-YakuCopilotModelLabelMatch -Label '自動' -ModelPriority @('自動','Auto')) -Message 'default automatic model must skip the model menu from ready state'
Assert-Yaku -Condition (-not (Test-YakuCopilotModelLabelMatch -Label '' -ModelPriority @('GPT 5.6 Think deeper'))) -Message 'missing model label must fall back to the full selector path'
Assert-Yaku -Condition ($null -ne (Get-Command Wait-YakuCopilotComposerStable -ErrorAction SilentlyContinue)) -Message 'fresh chat must wait for a stable composer before inserting the prompt'

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

$textPrompt = New-YakuTextPrompt -Root $root -InputText 'これはテストです。' -Settings $settings -DirectionOverride 'to_en' -RequestId $requestId -Mode 'full'
Assert-Yaku -Condition $textPrompt.Prompt.Contains("YAKULINGO_END:$requestId") -Message 'text prompt must carry random contract ID'
$textRaw = "FULL_TEXT:`nThis is a test.`nYAKULINGO_END:$requestId"
$textResult = @(Parse-YakuTextTranslationResponse -Raw $textRaw -Direction 'to_en' -RequestId $requestId -Mode 'full')
Assert-Yaku -Condition ($textResult.Count -eq 1) -Message 'valid full text response must parse'
Assert-YakuThrows -Action { Parse-YakuTextTranslationResponse -Raw $textRaw -Direction 'to_en' -RequestId ('f' * 32) } -Pattern 'RESPONSE_END_MARKER_MISSING' -Message 'wrong text contract ID must fail'
$inlineResult = @(Parse-YakuTextTranslationResponse -Raw ("FULL_TEXT:`nA YAKULINGO_END:${requestId}この会話を停止しました。") -Direction 'to_en' -RequestId $requestId -Mode 'full')
Assert-Yaku -Condition ($inlineResult.Count -eq 1 -and [string]$inlineResult[0].Translation -eq 'A') -Message 'inline marker and trailing stopped UI text must normalize and parse'
Assert-YakuThrows -Action { Parse-YakuTextTranslationResponse -Raw ("FULL_TEXT:`nA`nYAKULINGO_END:$requestId`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId -Mode 'full' } -Pattern 'RESPONSE_END_MARKER_DUPLICATE' -Message 'duplicate exact request marker must remain invalid'
Assert-YakuThrows -Action { Parse-YakuTextTranslationResponse -Raw ("FULL_TEXT:`nA`nFULL_TEXT:`nB`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId -Mode 'full' } -Pattern 'RESPONSE_LABEL_COUNT_INVALID' -Message 'duplicate style must fail'

$actualV85Raw = ([char]0x200C) + "JAPANESE_TEXT：完全な翻訳です。 YAKULINGO_END:${requestId}この会話を停止しました。"
$actualV85Result = @(Parse-YakuTextTranslationResponse -Raw $actualV85Raw -Direction 'to_jp' -RequestId $requestId)
Assert-Yaku -Condition ($actualV85Result.Count -eq 1 -and [string]$actualV85Result[0].Translation -eq '完全な翻訳です。') -Message 'V85 invisible-prefix/fullwidth-colon/inline-marker response must parse'
$decoratedRaw = "**FULL_TEXT:** Full. **YAKULINGO_END:$requestId**"
$decoratedResult = @(Parse-YakuTextTranslationResponse -Raw $decoratedRaw -Direction 'to_en' -RequestId $requestId -Mode 'full')
Assert-Yaku -Condition ($decoratedResult.Count -eq 1 -and [string]$decoratedResult[0].Translation -eq 'Full.') -Message 'Markdown-decorated label and fullwidth colon must parse'
$recoveredContract = Test-YakuTextResponseContract -Text ("先頭UI文言`nFULL_TEXT: Full.`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId -Mode 'full'
Assert-Yaku -Condition ([bool]$recoveredContract.Valid -and [string]$recoveredContract.WarningCode -eq 'RESPONSE_PREFIX_RECOVERED') -Message 'leading junk rescue must be explicit and warning-bearing'
$recoveryWarnings = New-Object System.Collections.Generic.List[object]
$null = @(Parse-YakuTextTranslationResponse -Raw ("先頭UI文言`nFULL_TEXT: Full.`nYAKULINGO_END:$requestId") -Direction 'to_en' -RequestId $requestId -Warnings $recoveryWarnings -Mode 'full')
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
Assert-Yaku -Condition ([int]$progressState.progress -eq 44 -and [string]$progressState.label -eq '生成中（1/2 回目）' -and [string]$progressState.detail -match '入力 940字') -Message 'batch one local progress must map into its overall range using input characters'
Set-YakuTranslationProgress -ProgressState $progressState -Label '完了（1/2 回目）' -Progress 50
$progressState.batch_current=2; $progressState.batch_progress_start=50; $progressState.batch_progress_end=92; $progressState.batch_input_length=937
Set-YakuCopilotProgressPhase -ProgressState $progressState -Phase 'inputting' -Label '入力中' -Detail '' -Progress 25
Assert-Yaku -Condition ([int]$progressState.progress -eq 60 -and [string]$progressState.label -eq '入力中（2/2 回目）' -and [string]$progressState.detail -eq '入力 937字') -Message 'batch two progress must remain monotonic and use its overall range'

$fileItems = @(
    [pscustomobject]@{ Index=11; Text='売上高'; BlockIds=@('a') },
    [pscustomobject]@{ Index=22; Text='営業利益'; BlockIds=@('b') }
)
$null = Protect-YakuCatItems -Items $fileItems -Root $root -Direction 'to_en'
$filePrompt = New-YakuCatPrompt -Root $root -Items $fileItems -Settings $settings -Direction 'to_en' -RequestId $requestId
Assert-Yaku -Condition ($filePrompt.Contains('[[ID:1]] 1.') -and $filePrompt.Contains('[[ID:2]] 2.') -and $filePrompt.Contains("YAKULINGO_END:$requestId")) -Message 'CAT prompt must define ordered IDs and contract ID'
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

Assert-Yaku -Condition (@(Find-YakuExactTermIndexes -InputText '四半期推移' -Term '半期').Count -eq 0) -Message 'half-year must not match inside quarter'
Assert-Yaku -Condition (@(Find-YakuExactTermIndexes -InputText '上半期実績' -Term '半期').Count -eq 1) -Message 'half-year must still match valid half-year compounds'

$env:YAKULINGO_MOCK = '1'
try {
    $mock = Invoke-YakuMockCopilotPrompt -Prompt $filePrompt
    Assert-Yaku -Condition $mock.TrimEnd().EndsWith("YAKULINGO_END:$requestId") -Message 'mock must echo the contract ID'
} finally { Remove-Item Env:YAKULINGO_MOCK -ErrorAction SilentlyContinue }

$catIndex = Get-Content -LiteralPath (Join-Path $root 'www\cat.html') -Raw -Encoding UTF8
$catClient = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat.js') -Raw -Encoding UTF8
# テキスト翻訳とExcel翻訳は別画面で、共有通信層だけを共用する。
$quickIndex = Get-Content -LiteralPath (Join-Path $root 'www\quick.html') -Raw -Encoding UTF8
$quickClient = Get-Content -LiteralPath (Join-Path $root 'www\assets\quick-page.js') -Raw -Encoding UTF8
$commonClient = Get-Content -LiteralPath (Join-Path $root 'www\assets\common.js') -Raw -Encoding UTF8
$premiumUiJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\premium-ui.js') -Raw -Encoding UTF8
# 2026-08-12: 全行確認を条件から外したので、出口を「確認済み訳文」とは呼べない。
# 呼び名ではなく、出せるものが訳文一覧であることを見る。
Assert-Yaku -Condition (($catIndex + $catClient).Contains('訳文をコピー') -and -not ($catClient -match "'確認済み訳文をコピー'")) -Message 'CAT output must be offered as the translation list it actually is'

$appJs = @(
    $commonClient
    $quickClient
    $catClient
) -join "`n"
$indexSource = @(
    $quickIndex
    $catIndex
) -join "`n"
$stylesSource = @(
    Get-Content -LiteralPath (Join-Path $root 'www\assets\styles.css') -Raw -Encoding UTF8
    Get-Content -LiteralPath (Join-Path $root 'www\assets\cat-workspace.css') -Raw -Encoding UTF8
) -join "`n"
$catProjectSource = Get-Content -LiteralPath (Join-Path $root 'src\CatProject.ps1') -Raw -Encoding UTF8
$server = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8
$settingsSource = Get-Content -LiteralPath (Join-Path $root 'src\Settings.ps1') -Raw -Encoding UTF8
$fileWorkerPresent = Test-Path -LiteralPath (Join-Path $root 'src\FileWorker.ps1') -PathType Leaf
$copilot = Get-Content -LiteralPath (Join-Path $root 'src\CopilotClient.ps1') -Raw -Encoding UTF8
$translationSource = Get-Content -LiteralPath (Join-Path $root 'src\Translation.ps1') -Raw -Encoding UTF8
$fileTranslationSource = Get-Content -LiteralPath (Join-Path $root 'src\CatBatch.ps1') -Raw -Encoding UTF8
$fileProcessors = Get-Content -LiteralPath (Join-Path $root 'src\FileProcessors.ps1') -Raw -Encoding UTF8
$promptBuilder = Get-Content -LiteralPath (Join-Path $root 'src\PromptBuilder.ps1') -Raw -Encoding UTF8
$edgeLaunch = Get-Content -LiteralPath (Join-Path $root 'src\EdgeLaunch.ps1') -Raw -Encoding UTF8
$warmupWorker = Get-Content -LiteralPath (Join-Path $root 'tools\Prepare-Copilot.ps1') -Raw -Encoding UTF8
$copilotAutomationTest = Get-Content -LiteralPath (Join-Path $root 'tools\Test-CopilotAutomation.ps1') -Raw -Encoding UTF8
Assert-Yaku -Condition ($appJs -match 'X-Yaku-Session' -and $appJs -match 'application/octet-stream' -and $appJs -match '/api/jobs/') -Message 'browser client must use token, binary upload, and per-job polling'
Assert-Yaku -Condition (-not ($appJs -match "localStorage\.setItem\([^\r\n]*(job|artifact)|sessionStorage\.setItem\([^\r\n]*(job|artifact)")) -Message 'Quick and CAT job or artifact identifiers must not leak into cross-session browser persistence'
Assert-Yaku -Condition ($appJs -notmatch 'readAsDataURL|file_b64|application/x-www-form-urlencoded') -Message 'browser client must not Base64/urlencode file uploads'
# 2026-08-21: 選ぶためだけの入口画面は置かず、通常の翻訳面をrootの左右画面へ一本化する。
Assert-Yaku -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'www\index.html')) -and -not (Test-Path -LiteralPath (Join-Path $root 'www\home.html'))) -Message 'the launcher must not present a translation choice screen'
Assert-Yaku -Condition ($server.Contains("`$path -in @('/', '/quick', '/palette')") -and $server.Contains("PageName 'quick.html'") -and $server.Contains("`$path -eq '/cat'") -and $server.Contains("PageName 'cat.html'")) -Message 'text and Excel routes must remain separate'
# 使い方・設定・ツアーのユーザー向け入口は退役した。
# 開始画面から辿れるリンクや CAT の tour hook は残さない。
Assert-Yaku -Condition (-not $catIndex.Contains('href="/tutorial') -and -not $catIndex.Contains('id="cat-help-links"') -and -not $catIndex.Contains('name="yaku-tour"') -and -not $catIndex.Contains('/assets/tour.js')) -Message 'the start screen must not expose retired tutorial/settings/tour entries'
# 文章とWord・Excelは同じ枠から入る。開始画面には確認を促す重複文を置かない。
$entryBlock = ''
if ($quickIndex -match '(?s)<section id="cat-picker".*?<section id="cat-workspace"') { $entryBlock = $Matches[0] }
Assert-Yaku -Condition ($entryBlock.Contains('id="quick-form"') -and $entryBlock.Contains('id="quick-area"') -and $entryBlock.Contains('id="cat-file-area"') -and -not $entryBlock.Contains('確認画面へ進みます')) -Message 'text and file inputs must share one start surface without redundant review guidance'
Assert-Yaku -Condition ($quickIndex -notmatch 'id="cat-instant"[^>]*\shidden' -and $quickIndex -match 'id="cat-workspace"[^>]*\shidden') -Message 'the paste box is available on the start view while the review workspace waits for a document'
# 貼り付け先は1つ。「保存する／しない」で入口を分けない（2026-08-11）。初見の人は
# 訳案を見る前に1文ずつ直したいかを決められないので、選択は訳案のあとへ置く。
# 2026-08-12: 「訳したい文章を貼り付けてください」という説明文で貼り付け口を数えていたが、
# 見出しと同じことを繰り返す一文だったので消した。数えるのは説明文ではなく貼り付け欄そのもの。
Assert-Yaku -Condition ($catIndex.Contains('Word・Excelを訳す') -and $catIndex.Contains('id="quick-input"') -and $catIndex.Contains('最近の作業') -and $catIndex.IndexOf('class="entry-main"') -lt $catIndex.IndexOf('class="entry-rail"')) -Message 'the start screen must connect paste, file, and recent work in main-first order'
Assert-Yaku -Condition ((([regex]::Matches($catIndex, 'id="cat-open-file-entry"')).Count -eq 1) -and (([regex]::Matches($catIndex, 'id="quick-input"')).Count -eq 1)) -Message 'the front door must keep exactly one file entry and one text entry'
# 長さの境目は画面が決めない。確認作業が分割に使っている設定値をそのまま使う。
Assert-Yaku -Condition ($catIndex.Contains('__YAKU_MAX_BATCH_CHARS__') -and $quickClient.Contains('yaku-max-batch-chars') -and $quickClient -notmatch 'length > 3000|length > 2000') -Message 'the long-text threshold must come from the server batch budget, not a number chosen in the page'
# 2026-08-17: PDF取り込みは、過去訳を登録する理由が分かる二次入口として見せる。
# PR #55 のカード class と既存IDはそのまま使い、実装を二重に持たない。
# 2026-08-18: 右レール最下段のボタン文言が「む」だけで折り返していた
# （実測 1912x987）。「過去の日本語版・英語版PDFを読み込む」→「過去のPDFを
# 読み込む」に詰めた。何を読み込むかは直前の見出しと本文が既に言っている。
Assert-Yaku -Condition (([regex]::Matches($catIndex, '過去のPDFを読み込む').Count -eq 1) -and ([regex]::Matches($catIndex, 'id="cat-open-align-entry"').Count -eq 1) -and $catIndex.Contains('entry-more-pdf-card') -and $catIndex -match '(?s)<section id="cat-align-entry"[\s\S]*?<h2 id="cat-align-entry-title">過去の訳を登録</h2>[\s\S]*?日本語版と英語版のPDF[\s\S]*?id="cat-open-align-entry"' -and -not $catIndex.Contains('そのほかの始め方')) -Message 'the visible PDF entry must explain past-translation registration and keep the existing card action'
Assert-Yaku -Condition (-not $catIndex.Contains('id="cat-source-prior"') -and -not $catIndex.Contains('id="cat-prior-open"') -and -not $catIndex.Contains('data-cat-source-show="file"') -and -not $catClient.Contains('cat-prior-open') -and -not $catClient.Contains('data-cat-source-show')) -Message 'retired prior and source-show entries must be absent'
Assert-Yaku -Condition (-not (($indexSource + "`n" + $quickClient) -match '確認画面へ進みます|文章を入力してください')) -Message 'removed start-screen guidance phrases must stay absent'
Assert-Yaku -Condition ($catProjectSource -match "Source\s*=\s*'text'[\s\S]{0,500}?Lifecycle\s*=\s*'saved'[\s\S]{0,120}?RetentionUntil\s*=\s*''" -and
    -not $server.Contains('Invoke-YakuExpiredTransientProjectCleanup') -and -not $server.Contains('YakuTransientCleanupNotBeforeUtc')) -Message 'new pasted CAT work is saved without a retention deadline and production has no timed cleanup path'
# 訳案カードを外したので「訳案」の見出しは無い。呼び名で守っていたのは
# 「未確認のものを完成訳と呼ばない」ことなので、そちらを直接見る（2026-08-13）。
Assert-Yaku -Condition (-not $indexSource.Contains('すぐ訳した完成訳') -and -not $indexSource.Contains('完成訳')) -Message 'unreviewed output must never be called a finished translation'
# 2026-08-13、利用者の指摘「余計な文章が多い」。機能の否定を2文重ねていた
# （「3つのWordを体裁付きで更新する機能ではありません」等）。守るのは
# 「前回の英語を自動で採らない」ことなので、そこだけを見る。
Assert-Yaku -Condition ($server.Contains('from-prior-version') -and -not $catIndex.Contains('前回の資料をもとに、今回の分だけ訳す') -and
    -not $catIndex.Contains('cat-prior-evidence') -and -not $catClient.Contains('prior_evidence:')) -Message 'backend prior-version compatibility remains while its retired start entry stays unreachable'
# 昇格は 2026-08-13 に廃止（移るもとが無くなった）。守るものは変わらない＝
# ブラウザーから訳文を送り返さない。原文だけは、もともと「長い文章を貼り付ける」が
# 通っていた経路と同じで、/api/cat/open が受ける。
Assert-Yaku -Condition ($quickClient.Contains('/api/cat/open') -and -not $quickClient.Contains('/api/cat/promote') -and -not $quickClient.Contains('translation:')) -Message 'the paste box must create work through one route without reposting a translation from the browser'
Assert-Yaku -Condition ($commonClient.Contains('function plainError') -and $commonClient.Contains("box.textContent || box.innerText") -and $commonClient.Contains('new Error(plainError(body)')) -Message 'HTML API errors must be reduced to readable text before rendering'
Assert-Yaku -Condition ($catClient.Contains('dirty = new Map()') -and $catClient.Contains('function flush()') -and $catClient.Contains('return flush().then') -and $catClient.Contains('dirty.set(dirtyKey(')) -Message 'CAT edits must become dirty on input and pass through the shared save barrier before commands'
Assert-Yaku -Condition ($catClient.Contains('var projectId = input.getAttribute(') -and $catClient.Contains('scopeIsCurrent(packet.scope, true)') -and $catClient.Contains("String(packet.data.id || '') !== projectId")) -Message 'late CAT save responses must remain scoped to their originating project and revision'
Assert-Yaku -Condition ($catClient.Contains('data-cat-resume') -and $catClient.Contains('cat-resume-name') -and $catClient.Contains('cat-resume-time') -and $catClient.Contains('savedLabel(item.saved)')) -Message 'saved CAT projects must show a distinct name and saved metadata in the chooser'
Assert-Yaku -Condition ($catClient.Contains('function clearOutputDisplay()') -and $catClient.Contains('data-cat-output-project') -and $catClient.Contains('function outputGuidance()') -and -not $catClient.Contains("'出力条件を満たしていません: '")) -Message 'CAT output display and blockers must be project-scoped and actionable without internal reason codes'
Assert-Yaku -Condition ($indexSource.Contains('cat-save-status') -and $indexSource.Contains('cat-output-help') -and $indexSource.Contains('role="status"')) -Message 'CAT save and output readiness must be announced accessibly'
# 独自の「文字を大きく」は 2026-08-11 に廃止した。本文は既に 17px、原文と訳文は
# 19.04px で市販CAT（MateCat 18px）より大きい。拡大は Edge の Ctrl+スクロールが
# 担う。保証すべきは「文字寸法が1か所の基準から比率で決まること」で、そうなって
# いれば拡大しても主役と脇役の差が崩れない。切替UIの有無ではない。
Assert-Yaku -Condition ($stylesSource -match 'html\s*\{[^}]*font-size:\s*\d+px' -and $stylesSource.Contains('--font-segment') -and $stylesSource -match '--font-segment:\s*[\d.]+rem' -and -not $indexSource.Contains('id="text-size-toggle"')) -Message 'type scale must derive from one root size in rem, with no bespoke text-size toggle to keep in sync'
Assert-Yaku -Condition ($stylesSource.Contains('min-height: 44px') -and $stylesSource.Contains('@media (max-width: 900px)') -and $stylesSource.Contains('.cat-card-label')) -Message 'primary controls must retain large targets and CAT rows must reflow to labelled cards'
Assert-Yaku -Condition ($indexSource.Contains('cat-current-summary') -and $indexSource.Contains('cat-switch-project') -and $catClient.Contains("el('cat-workspace').hidden = false") -and $catClient.Contains('if (busy) return')) -Message 'active CAT work must use a focused summary and reject duplicate commands'
# 2026-08-12、利用者の判断で言い方を変えた。「いちいち言われなくても、そのまま
# 社外に送るひとなんていない」「社内確認用のファイルというのもよくわからない」。
# 説教はやめ、事実だけを1回言う。守るのは「完成版に見せない」ことであって、
# 社外配布を戒める文そのものではない。
Assert-Yaku -Condition ($indexSource.Contains('原本はそのままで、訳文を入れたコピーを作ります。名前の先頭に「DRAFT_」が付きます。') -and $indexSource.Contains('訳文を入れたコピーを作りました') -and $appJs.Contains('訳文入りWordを作る') -and -not $appJs.Contains('成果物を作成できます') -and -not $appJs.Contains('完成版')) -Message 'DRAFT output must be named as a copy with a DRAFT_ prefix and never as a finished deliverable'
# 出したあとに同じことを2度言わない。ファイル名を出す行だけにする。
Assert-Yaku -Condition (-not $indexSource.Contains('cat-draft-warning') -and -not $appJs.Contains('cat-draft-warning')) -Message 'the post-export notice must not repeat what the pre-export dialog already said'
Assert-Yaku -Condition ($indexSource.Contains('id="cat-delete-dialog"') -and $indexSource.Contains('autofocus>削除しない') -and -not $appJs.Contains("window.confirm('この翻訳作業")) -Message 'project deletion must use a cancel-first named confirmation dialog'
Assert-Yaku -Condition ($indexSource.Contains('id="cat-text-output-value"') -and $commonClient.Contains('コピーできませんでした。全文を選択したので、Ctrl+Cでコピーしてください') -and $catClient.Contains("el('cat-text-output-value').select()")) -Message 'clipboard failure must preserve the assembled translation and provide a keyboard recovery path'
$qcEditorBoundaryPattern = "(?s)var blockingError = segmentHasBlockingError\(segment\);[\s\S]{0,600}aria-invalid=.*?blockingError \? 'true' : 'false'.*?blockingError \? ' aria-describedby=`"cat-qc-list`"' : ''"
$qcEditorBoundaryContract = [regex]::IsMatch($catClient, $qcEditorBoundaryPattern) -and
    $catClient.Contains("function qcFindingSeverity(view)") -and
    $catClient.Contains("if (severity === 'error') return 'error';") -and
    $catClient.Contains("if (severity === 'warning' || severity === 'warn') return 'warning';") -and
    $catClient.Contains("function segmentHasBlockingError(segment)") -and
    $catClient.Contains("qcFindingViews(segment).some(function (view) { return qcFindingSeverity(view) === 'error'; });")
$qcWarningVisibleContract = $catClient.Contains("var QC_WARNING_CODES = ['numeric-value-mismatch'") -and
    $catClient.Contains('function qcWarningGroupKey(code)') -and
    $catClient.Contains('var warned = numericWarnings + labelWarnings + delimiterWarnings + genericWarnings;') -and
    $catClient -match '(?s)\bwarned\s*\?'
Assert-Yaku -Condition ($qcEditorBoundaryContract -and $qcWarningVisibleContract -and $catClient.Contains('data.review_blocked') -and $catClient.Contains('function focusAfter(index)')) -Message 'QC warnings must remain visible without invalid/error semantics, blocking errors must describe the QA list, and confirmation focus must advance by segment index'
Assert-Yaku -Condition ($indexSource.Contains('<caption class="sr-only">') -and $stylesSource.Contains('@media (prefers-reduced-motion: reduce)') -and -not $indexSource.Contains('class="input-meta" aria-live="polite"')) -Message 'CAT semantics and reduced-motion support must remain accessible without noisy character-count announcements'
Assert-Yaku -Condition ($catClient.Contains("type: 'translate', scope: jobScope") -and $catClient.Contains("post('apply', { job_id: jobId }, true, context.scope)") -and $server.Contains('CAT_JOB_PROJECT_MISMATCH') -and $server.Contains('CAT_JOB_SOURCE_MISMATCH')) -Message 'CAT job results must stay bound to their starting project, revision, and source text'
# 2026-08-12: 一覧のその場でも消せるようにした。開いている作業を消すときは
# これまでどおり「表示中のものと同じか」を確かめる。一覧から消すときは開いて
# いないので比べる相手が無く、代わりに一覧が持っている revision をそのまま送る。
# 一覧が古ければ revision が合わず、サーバが断る。
Assert-Yaku -Condition ($catClient.Contains('deleteTarget = currentScope()') -and $catClient.Contains('if (!target.fromList && !scopeIsCurrent(target, true))') -and $catClient.Contains("post('delete', { id: target.id, memory_policy:") -and $catClient.Contains('client_id: YakuCommon.clientId()')) -Message 'delete confirmation must remain bound to the project name and ID shown in the dialog'
Assert-Yaku -Condition ($catClient.Contains('data-cat-resume-drop') -and $catClient -match "revision: Number\(drop\.getAttribute\('data-cat-resume-revision'\)\)") -Message 'deleting from the saved list must carry that entry own revision so a stale list cannot delete changed work'
Assert-Yaku -Condition ($catClient.Contains('saveChain = saveChain.catch') -and $catClient -match 'function redrawAfterFlush\(\)[\s\S]*?return flush\(\)\.then' -and $catClient -match "button\.hasAttribute\('data-cat-filter'\)[\s\S]{0,180}redrawAfterFlush\(\)") -Message 'CAT saves and local filter redraws must be serialized behind the project save barrier'
Assert-Yaku -Condition ($catClient.Contains('data.review_blocked') -and $catClient.Contains('検索条件の外に未確認の行があります')) -Message 'failed review and filtered confirmation must retain a logical keyboard focus target'
Assert-Yaku -Condition ($catIndex -match 'id="cat-workspace"[^>]*\shidden(?:\s|>)' -and $catClient.Contains("el('cat-workspace').hidden = false") -and $catClient.Contains("el('cat-workspace').hidden = true")) -Message 'opening another project must hide the current workspace instead of mixing two work contexts'
Assert-Yaku -Condition ($catClient.Contains("document.querySelectorAll('textarea[data-cat-input], input.revise-input')") -and $catClient.Contains('処理中は参考訳を挿入できません') -and $catClient.Contains('scopeIsCurrent(context.scope, true)')) -Message 'CAT job lock must survive redraws, shortcuts, candidate insertion, and defensive apply checks'
# 2026-08-12: 左の絞り込み列を廃止し、帯を表の上へ移した（市販CATと同じ）。
Assert-Yaku -Condition ($catIndex.Contains('id="cat-editor-toolbar"') -and $catIndex.Contains('id="cat-editor-pane"') -and (-not $catIndex.Contains('id="cat-inspector-pane"')) -and (-not $catIndex.Contains('id="cat-nav-pane"')) -and $catIndex.Contains('class="cat-toolbar-filters"') -and $stylesSource -match '(?s)\.cat-editor-toolbar\s*\{[^}]*position:\s*sticky') -Message 'CAT review must filter from a bar above the grid without a permanent side column'
Assert-Yaku -Condition ($catClient.Contains('activeSegmentId') -and $catClient.Contains('data-cat-segment-id') -and $catClient.Contains("esc(segment.location || '本文')") -and $catClient.Contains('function locationGroup(segment)')) -Message 'CAT active row and actual document location must survive redraw and drive navigation'
Assert-Yaku -Condition ($catClient.Contains('event.isComposing') -and $catClient.Contains("event.key === 'ArrowUp'") -and $catClient.Contains("event.key.toLowerCase() === 'f'")) -Message 'CAT keyboard workflow must be IME-safe and include row movement and local search'
Assert-Yaku -Condition ($catIndex.Contains('id="cat-complete-state"') -and $catClient.Contains("currentFilter = 'all'")) -Message 'completed CAT work must show its reviewed rows instead of an empty actionable grid'
Assert-Yaku -Condition ($catIndex.Contains('id="cat-export-dialog"') -and $catClient.Contains("post('preflight', {}, true, requestScope)") -and $catClient.Contains("String(data.project_id || '') !== requestScope.id") -and $catClient.Contains('Number(data.revision) !== requestScope.revision')) -Message 'CAT output dialog must consume server preflight for the exact project revision'
Assert-Yaku -Condition ($catClient.Contains("el('cat-export-dialog').addEventListener('close'") -and $catClient.Contains('if (!scopeIsCurrent(scope, true))') -and $catClient.Contains('exportProject();')) -Message 'CAT export must recheck the preflight scope before producing a DRAFT or copied text'
Assert-Yaku -Condition (-not ($indexSource -match '122 oku|設定とデータ管理|直近の翻訳|用語集（読取専用）')) -Message 'unused utility controls must be absent from the main screen'
# 2026-08-12: 金額の書き方の選択だけ戻した。billion を開けたが、設定を変える画面が
# 他に無く、選べない対応は対応にならない。最初の画面には置かない（訳す前に迷わせない）。
# 置くのは訳す画面の1か所だけ。値は設定から読み、画面側で既定を決めない。
# 2026-08-12: 「どこがメインでどこがサブか分からない」への手当て。実機 1380px で測った事実。
#  - 塗ったボタンが2つ並んでいた（訳す=押せない灰色、Word・Excel取り込み=accent）。
#    押せるほうが主役に見えるので、取り込みは輪郭線のボタンにする
#  - 保存した作業が10件で685px、画面1555pxの44%を占めていた。既定は直近3件
#  - この作業を削除は .danger-button なのに accent で塗られていた。基本ルールの
#    :not() リストに入れて、詳細度を上げずに部品側へ勝たせる
Assert-Yaku -Condition ($catIndex -match 'id="cat-open-file-entry"[^>]*class="secondary-button"' -and -not $catIndex.Contains('data-cat-source-show="file"')) -Message 'the file entry must not compete with the paste action as a second filled button'
Assert-Yaku -Condition ($catClient.Contains('var RESUME_VISIBLE = 3') -and $catIndex.Contains('id="cat-resume-more"')) -Message 'the saved work list must fold to the most recent few with a count of the rest'
# 2026-08-12（同日追記）: 除外する名前を字面で丸ごと固定していたため、名前を1つ
# 足すたびに落ちていた。見たいのは2つ。除外が入っていること、そして詳細度を
# 上げていないこと（:not() を連ねると1つにつき class 1個ぶん積む）。
$filledBaseRule = ''
if ($stylesSource -match '(?m)^(button:not\([^
]*?\{)') { $filledBaseRule = $Matches[1] }
$requiredExclusions = @('.secondary-button','.tab-button','.file-clear-button','.link-button','.danger-button','[disabled]')
Assert-Yaku -Condition ($filledBaseRule -ne '' -and (@($requiredExclusions | Where-Object { -not $filledBaseRule.Contains($_) }).Count -eq 0)) -Message 'the filled base style must exclude secondary, tab, file-clear, link and danger buttons'
# 連ねた :not() が1つでもあれば詳細度が上がっている。
Assert-Yaku -Condition ($stylesSource -notmatch '\):not\(') -Message 'exclusions must stay in one :not() list so the base specificity does not creep'
# a.button（リンクのボタン）も同じ除外を持つ。持たないと secondary-button が塗られる。
Assert-Yaku -Condition ($stylesSource -match '\.button:not\(\.secondary-button, \.danger-button, \[disabled\]\)') -Message 'link-shaped buttons must honour the secondary and danger variants'
# 2026-08-12: 実機のCAT往復で、billion を選んだ作業が oku で訳された。
# 翻訳ジョブは別のランスペースで走るため、この JSON に載せたものしか届かない。
# 受け側（Protect-YakuCatItems / Invoke-YakuCatTranslationItems）は
# $cat.amount_notation を見ているので、送り側が積んでいるかを字面で押さえる。
Assert-Yaku -Condition ($server -match 'mode = \$catMode; amount_notation = \(Get-YakuCatProjectAmountNotation -Project \$project\)') -Message 'the CAT translation job payload must carry the project amount notation into the worker runspace'
Assert-Yaku -Condition ($stylesSource.Contains('.entry-more-pdf-card') -and $stylesSource.Contains('border-radius: var(--radius-control)') -and $stylesSource -notmatch '--yk-r-control') -Message 'the single PDF entry must be a prominent card with the defined control radius'
Assert-Yaku -Condition ($catClient.Contains("exportButton.classList.toggle('secondary-button', drafting)") -and $catClient.Contains("translate.classList.toggle('secondary-button', !drafting)")) -Message 'the toolbar filled button must follow the next step instead of staying on a finished action'
Assert-Yaku -Condition (([regex]::Matches($catIndex, 'id="amount-notation"').Count -eq 1) -and
    $quickClient.Contains('meta[name="yaku-amount-notation"]') -and
    $server.Contains('__YAKU_AMOUNT_NOTATION__')) -Message 'the amount notation choice must live once on the translation screen and read its value from settings'
Assert-Yaku -Condition ($server -match 'INVALID_SESSION_TOKEN' -and $server -match 'UNSUPPORTED_CONTENT_TYPE' -and $server -match 'Local\\YakuLingo') -Message 'server boundary and single-instance controls must be present'
Assert-Yaku -Condition ($server -notmatch 'ProcessStopper\.ps1|Type\s*=\s*''Process''') -Message 'legacy process-backed file jobs must be absent'
Assert-Yaku -Condition ($server -notmatch 'Save-YakuIncomingFileFromForm|Parse-YakuUrlEncodedForm') -Message 'legacy Base64/form upload path must be removed'
Assert-Yaku -Condition (-not ($server -match '/api/glossary|/api/settings-form|/api/settings''|/api/amount-notation|/api/history|/api/privacy-status')) -Message 'removed utility panels must have no public UI endpoints'
Assert-Yaku -Condition ($server.Contains('diagnosticsLevel=') -and $server.Contains('settingsSnapshot=job-start')) -Message 'per-job diagnostic setting value must remain traceable internally'
Assert-Yaku -Condition ($settingsSource.Contains('Read-YakuUserSettingsStrict') -and $settingsSource.Contains('SETTINGS_SAVE_RESULT_INVALID') -and $settingsSource.Contains('SETTINGS_SAVE_VERIFY_FAILED')) -Message 'settings save must enforce strict disk readback and a single verified result object'
$pathsSource = Get-Content -LiteralPath (Join-Path $root 'src\Paths.ps1') -Raw -Encoding UTF8
Assert-Yaku -Condition (-not $settingsSource.Contains('Join-Path $Root ''config\user_settings.json''')) -Message 'user settings must never be written inside the app folder'
Assert-Yaku -Condition ($pathsSource.Contains('function Get-YakuUserSettingsPath') -and $settingsSource.Contains('Resolve-YakuUserSettingsPath')) -Message 'user settings path must resolve through the user data directory with one-time legacy migration'
Assert-Yaku -Condition (-not $fileWorkerPresent -and -not $server.Contains('Start-YakuFileProcessJob')) -Message 'legacy file worker must remain removed and unreachable'
Assert-Yaku -Condition ($copilot -notmatch '--remote-allow-origins=\*') -Message 'CDP wildcard origin switch must be absent'
Assert-Yaku -Condition ($copilot -match 'Get-NetTCPConnection' -and $copilot -match 'OwningProcess') -Message 'CDP port owner PID must be verified'
Assert-Yaku -Condition ($copilot.Contains('[bool]$Evidence') -and $copilot.Contains('if (-not [bool]$ownership.Evidence)') -and $copilot.Contains('証拠なし')) -Message 'an unknown CDP ownership result with zero process-enumeration evidence must not be adopted (R2-6)'
# R3-1: RETRY_MODES（common.js）に並べたmode文字列は、必ずbackendが実際に
# 書き得るmodeでなければならない。存在しないmode文字列を並べても、ボタンは
# 永遠に出ない（'not-ready' がまさにこれで踏んだ：D2-2の降格が書くmodeなのに
# RETRY_MODESに無く、心拍で updated_at が新鮮なのでstaleにも落ちず、
# 「準備をやり直す」を押してくださいという案内だけがdetailに残ってボタンが
# 無い、という詰みになっていた）。
$retryModesMatch = [regex]::Match($commonClient, 'var RETRY_MODES = \{([^}]*)\};')
Assert-Yaku -Condition $retryModesMatch.Success -Message 'common.js must define RETRY_MODES as a single-line object literal (required for this static consistency check)'
if ($retryModesMatch.Success) {
    $retryModeKeys = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ($retryModesMatch.Groups[1].Value -split ',')) {
        $key = ($entry -split ':')[0].Trim().Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($key)) { $retryModeKeys.Add($key) | Out-Null }
    }
    # -Mode 'xxx' というcmdletパラメータの形（Write-YakuWarmupStatus等）と、
    # $mode = 'xxx' / mode='xxx' という素の代入・オブジェクトリテラルの形
    # （'stale'・'not-started' はこちら側でしか書かれない）の両方を拾う。
    $backendModeLiteralMatches = [regex]::Matches($server + $warmupWorker, "(?i)mode\s*[=:]\s*'([a-z][a-z-]*)'|Mode\s+'([a-z][a-z-]*)'")
    $backendModeLiterals = @($backendModeLiteralMatches | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Sort-Object -Unique)
    $missingFromBackend = @($retryModeKeys.ToArray() | Where-Object { $backendModeLiterals -notcontains $_ })
    Assert-Yaku -Condition ($retryModeKeys.Count -gt 0 -and $missingFromBackend.Count -eq 0) ('every RETRY_MODES key in common.js must be a mode literal the backend actually writes via Write-YakuWarmupStatus/Write-YakuCopilotWarmupStatus (backend mode set must be a superset of RETRY_MODES; missing: ' + ($missingFromBackend -join ',') + ')')
}
Assert-Yaku -Condition ($edgeLaunch.Contains('Get-Process -Name') -and $edgeLaunch.Contains("if (`$hasAnyEdge)") -and $edgeLaunch.Contains("if ([int]`$stopResult.Stopped -gt 0) { Start-Sleep -Milliseconds 700 }")) -Message 'cold Edge startup must skip WMI and the fixed sleep when no Edge process exists'
# R2-4残り: $hasAnyEdge（ふだんのEdgeも数える）だけで3秒粘りに入ると、Windows
# 通常状態ではほぼ常に真になり、専用プロファイルと無関係な起動でも毎回3秒
# ブロックする。粘り（Wait-YakuDevTools）とWMI Stopの両方が、専用プロファイル
# の実際の保持者（$holders）が実在するときだけに絞られていることを見る。
Assert-Yaku -Condition ($edgeLaunch.Contains('$holders = @(Get-YakuCopilotEdgeProfileProcesses -UserDataDir $spec.UserDataDir)') -and $edgeLaunch.Contains('if ($holders.Count -gt 0)') -and ($edgeLaunch.IndexOf('if ($hasAnyEdge)') -lt $edgeLaunch.IndexOf('if ($holders.Count -gt 0)')) -and ($edgeLaunch.IndexOf('if ($holders.Count -gt 0)') -lt $edgeLaunch.IndexOf('Wait-YakuDevTools -Port $Port -TimeoutSeconds 3'))) -Message 'the pre-kill 3-second Wait-YakuDevTools retry (and the WMI Stop it guards) must be scoped to actual dedicated-profile holders, not to "any msedge process exists" (R2-4)'
Assert-Yaku -Condition ($edgeLaunch.Contains('--remote-debugging-port=') -and $edgeLaunch.Contains('--user-data-dir=') -and $copilot.Contains('Start-YakuEdgeLaunch')) -Message 'early warmup and normal translation must share one Edge launch argument definition'
Assert-Yaku -Condition ($edgeLaunch.Contains('--window-size=') -and $copilot.Contains('Browser.getWindowForTarget') -and $copilot.Contains('Browser.setWindowBounds') -and $copilot.Contains('YakuEdgeNeedsWindowNormalization')) -Message 'new Edge windows must be normalized once through launch arguments and CDP'
Assert-Yaku -Condition ($edgeLaunch.Contains('--start-minimized') -and $edgeLaunch.Contains("-WindowStyle `$StartWindowStyle") -and $warmupWorker.Contains("-DisplayMode 'background'")) -Message 'normal Copilot warmup must start the dedicated Edge window minimized'
Assert-Yaku -Condition ($copilot.Contains("if (`$ForceForeground) { 'foreground' } else { 'background' }") -and $copilot.Contains("windowState='minimized'") -and $edgeLaunch.Contains("`$StartWindowStyle -eq 'Minimized' -or `$Spec.WindowSize.Enabled")) -Message 'normal startup must minimize the dedicated Edge after readiness while explicit login may foreground it'
Assert-Yaku -Condition ($edgeLaunch.Contains('FindTopLevelWindows') -and $edgeLaunch.Contains('ShowWindowAsync($window, 0)') -and $edgeLaunch.Contains("ValidateSet('hidden','foreground')")) -Message 'only dedicated-profile Edge windows must be hidden natively so their taskbar buttons disappear'
Assert-Yaku -Condition ($warmupWorker.Contains("Show-YakuEdgeWindow -Mode hidden") -and $warmupWorker.Contains('Copilot：準備完了') -and $warmupWorker.Contains('Copilot：サインインが必要')) -Message 'warmup must hide Edge after login and publish explicit readiness and login labels'
Assert-Yaku -Condition ($warmupWorker.Contains('function Watch-YakuCopilotReadiness') -and $warmupWorker.Contains('active_job_running') -and $warmupWorker.Contains('Test-YakuProcessIdentity')) -Message 'the readiness monitor must stop with its server and skip CDP checks during active translations'
Assert-Yaku -Condition ($server.Contains('-ParentProcessId') -and $server.Contains('-ParentStartedUtc')) -Message 'the server must bind the Copilot readiness monitor to its exact process identity'
# R3-2: 15分打ち切り後の 'timeout' 表示が、次の1周で無条件に 'loading' へ
# 上書きされ、「準備をやり直す」ボタンの表示条件が最短20秒で消えていた。
# 上書きしない側の枝が $notReadyMode（$timedOut を見る三項）を使っている
# ことと、CDP例外が3回連続したら専用Edgeを1回だけ呼び直す設計が
# 入っていることを見る。
Assert-Yaku -Condition (
    $warmupWorker.Contains("`$notReadyMode = if (`$timedOut) { 'timeout' } else { 'loading' }") -and
    $warmupWorker.Contains('-Mode $notReadyMode -Label $notReadyLabel') -and
    ($warmupWorker.IndexOf('-Mode $notReadyMode -Label $notReadyLabel') -gt 0) -and
    (@([regex]::Matches($warmupWorker, [regex]::Escape('-Mode $notReadyMode -Label $notReadyLabel'))).Count -ge 2)
) -Message 'the timeout status must not be silently overwritten by the next loading/catch poll cycle while timed out (R3-2)'
Assert-Yaku -Condition ($warmupWorker.Contains('$cdpFailureStreak -ge 3 -and -not $edgeRelaunchAttempted') -and $warmupWorker.Contains('Start-YakuCopilotEdge -Port $port')) -Message 'the warmup worker must relaunch the dedicated Edge itself once after 3 consecutive CDP failures, before Copilot ever reaches ready (R3-2)'
Assert-Yaku -Condition ($edgeLaunch.Contains("Canonical='none'") -and $settingsSource.Contains('edge_window_size')) -Message 'Edge window normalization must be configurable and disableable'
Assert-Yaku -Condition ($edgeLaunch.IndexOf('if ($alreadyReachable)') -lt $edgeLaunch.IndexOf('$script:YakuEdgeNeedsWindowNormalization =') -and $edgeLaunch.Contains('DisplayMode=$DisplayMode')) -Message 'already-running Edge must return before startup-only foreground or minimized normalization is scheduled'
Assert-Yaku -Condition ($warmupWorker.IndexOf('Start-YakuEdgeLaunch') -lt $warmupWorker.IndexOf("src\CopilotClient.ps1") -and $warmupWorker.Contains('-NoWait')) -Message 'warmup must launch Edge before loading the large Copilot module'
Assert-Yaku -Condition ($warmupWorker.Contains('ready from fresh-chat after state') -and $warmupWorker.Contains("fresh-chat after state was insufficient; using polling fallback")) -Message 'fresh-chat warmup must use a verified immediate-ready path with the legacy polling fallback'
Assert-Yaku -Condition ($warmupWorker.Contains('for ($attempt = 1; $attempt -le 5; $attempt++)') -and $warmupWorker.Contains('copilot-warmup.{0}.tmp') -and $warmupWorker.Contains('Ready status write failed; staying in polling loop to retry.')) -Message 'warmup status writes must be atomic and retry before terminal ready exit'
Assert-Yaku -Condition ($server.Contains('[System.IO.FileShare]::ReadWrite') -and $server.Contains('$script:YakuWarmupLastGood = $status') -and $server.Contains('if ($null -ne $script:YakuWarmupLastGood)')) -Message 'warmup reads must tolerate concurrent writes and retain the last good status'
Assert-Yaku -Condition ($server.LastIndexOf('Start-YakuCopilotWarmup') -lt $server.LastIndexOf('Invoke-YakuDiagnosticLogRotation') -and $server.Contains('phase=warmup-worker-dispatch')) -Message 'server startup must dispatch Copilot warmup before maintenance and log its timing'
Assert-Yaku -Condition ($translationSource.Contains('Math]::Max($currentPct, $pct)')) -Message 'text translation progress must remain monotonic across multiple batches'
Assert-Yaku -Condition ($translationSource.Contains('Get-YakuTextResponseStructureMetadata') -and $translationSource.Contains('leading_code_points') -and $translationSource.Contains("event = 'text-response-contract-rejected'")) -Message 'contract errors must always retain privacy-safe response structure metadata'
Assert-Yaku -Condition ($translationSource.Contains("'RESPONSE_PREFIX_RECOVERED'") -and $translationSource.Contains("Category 'response-contract-recovery'")) -Message 'leading response junk may only be rescued with a visible warning'
Assert-Yaku -Condition ($translationSource.Contains('$required = @(Get-YakuTextRequiredLabels -Direction $Direction -Mode $Mode)') -and $translationSource.Contains('CONTRACT_INTERNAL: $required must be an array.')) -Message 'to_jp required labels must not be unwrapped into a scalar string'
Assert-Yaku -Condition ($translationSource.Contains("`$structure['required_labels']") -and $translationSource.Contains("`$structure['clean_head']") -and $translationSource.Contains('Test-YakuFullTextDiagnosticsEnabled')) -Message 'contract diagnostics must record required labels while gating clean response text'
Assert-Yaku -Condition ($translationSource.Contains("Phase 'retrying'") -and $translationSource.Contains('応答形式エラーのため再試行します')) -Message 'contract retries must be visible in progress state'
Assert-Yaku -Condition ($translationSource.Contains('function Get-YakuTextStructureCounts') -and $translationSource.Contains('function Test-YakuTextStructureIntegrity') -and $translationSource.Contains('RESPONSE_STRUCTURE_MISMATCH')) -Message 'text heading and bullet integrity must be validated through the existing response retry path'
Assert-Yaku -Condition ($translationSource.Contains("Category 'structure-integrity'") -and $translationSource.Contains('原文の見出し・箇条書きの一部が訳文から欠落している可能性')) -Message 'final structure mismatch must return a visible warning instead of failing the translation'
Assert-Yaku -Condition ($translationSource.Contains('function ConvertFrom-YakuTextFullWidthAngle') -and $translationSource.Contains("Replace('＜', '<').Replace('＞', '>')") -and $translationSource.IndexOf('ConvertFrom-YakuTextFullWidthAngle -Text $fullText') -lt $translationSource.IndexOf('Test-YakuTextStructureIntegrity -SourceText $sourceText')) -Message 'to_en angle restoration must occur before structure integrity validation'
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
# 配布版は用語も翻訳メモリも空から始める。同梱CSVを置換表として読む
# 旧経路が戻っていないことと、利用者が登録したcell_exactだけを明示適用
# できることを見る。
Assert-Yaku -Condition (-not $promptBuilder.Contains('GLOSSARY (mandatory)') -and -not $promptBuilder.Contains('function Get-YakuPromptGlossaryPath') -and -not $promptBuilder.Contains('function Get-YakuReferenceSection')) -Message 'prompt glossary injection must stay removed'
Assert-Yaku -Condition (-not $fileTranslationSource.Contains('function Get-YakuFileGlossaryOccurrenceAudit') -and -not $translationSource.Contains('function Write-YakuTextGlossaryDiagnosticLog')) -Message 'in-sentence glossary audit must stay removed'
Assert-Yaku -Condition ($fileTranslationSource.Contains('function Resolve-YakuFileExactGlossaryTranslations') -and $fileTranslationSource.Contains('Find-YakuCellExactTerminologyMatch') -and -not $fileTranslationSource.Contains('Get-YakuGlossaryEntries')) -Message 'cell-exact replacement must use only user-registered governed terminology'
Assert-Yaku -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'glossary.csv')) -and -not (Test-Path -LiteralPath (Join-Path $root 'propernouns.csv'))) -Message 'release tree must contain no bundled glossary or proper-name seed'
Assert-Yaku -Condition ($translationSource.Contains("Unit='万台'; Out='k units'; Factor=10") -and $translationSource.Contains('function Convert-YakuNumericUnits')) -Message 'man-unit conversion must be performed deterministically before translation'
Assert-Yaku -Condition (-not $promptBuilder.Contains('function Add-YakuGlossaryEntry') -and -not $promptBuilder.Contains('function Remove-YakuGlossaryEntryByRow') -and -not $promptBuilder.Contains('glossary-add-form') -and -not $promptBuilder.Contains('glossary-delete')) -Message 'glossary write functions and edit controls must be removed'
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
Assert-Yaku -Condition ($catIndex.Contains('id="cat-job"') -and $catIndex.Contains('aria-live="polite"') -and $commonClient.Contains('prefers-reduced-motion: reduce') -and $catClient.Contains('render(data, true)')) -Message 'terminal CAT results must be announced and return focus without forced motion'
# 2026-08-13: 貼り付け側は自分で翻訳を回さなくなった（作業を作って移るだけ）ので、
# 進み具合の欄は「取り込んでいます」を出すために残っている。翻訳の進み具合は
# 確認画面の cat-job が持つ。別々の状態に置く、という形だけが残った。
Assert-Yaku -Condition ($quickIndex.Contains('id="quick-job"') -and $catIndex.Contains('id="cat-job"') -and -not $quickClient.Contains('/api/quick/jobs/') -and $catClient.Contains('/api/jobs/')) -Message 'progress for creating work and for translating must stay in their own places'
Assert-Yaku -Condition ($copilot.Contains("`$sliceLimit = if (`$firstActivitySeen) { 3 } else { 2 }")) -Message 'active response completion polling must use three-second slices'
Assert-Yaku -Condition ($copilot.Contains("reason:'already-fresh'") -and $copilot.Contains('const seenCandidatesThisRound = new Set();')) -Message 'fresh-chat and watcher duplicate work must be eliminated'
Assert-Yaku -Condition ($copilot.Contains('FRESH_MAIN_TEXT_MAX = 4000') -and $copilot.Contains("reason:freshVerified ? 'fresh-state-confirmed' : 'fresh-state-not-confirmed'")) -Message 'fresh-chat acceptance must reject stale main content even when response selectors report zero'
Assert-Yaku -Condition ($copilot.Contains('Copilot input diagnostic log created:') -and $copilot.Contains('full-text diagnostics disabled for this request.')) -Message 'diagnostic paths must only be reported as created when full-text diagnostics are enabled'
Assert-Yaku -Condition ($copilot.Contains('[int]$FirstActivityTimeoutMs = 10000') -and $copilot.Contains('$silentConfirmMs = 2000') -and $settingsSource.Contains('copilotFirstActivityTimeoutMs')) -Message 'Copilot silent-start watchdog must retain the configurable ten-second default plus two-second confirmation'
Assert-Yaku -Condition ($copilot.Contains('[data-testid="loading-message"]') -and $copilot.Contains("kind:'stop-button-visible'") -and $copilot.Contains('misdetected:true')) -Message 'thinking UI and stop-button activity must prevent a false silent-start decision'
Assert-Yaku -Condition ($copilot.Contains('Copilot fresh chat diagnostic:') -and $copilot.Contains('Copilot fresh chat accepted.') -and $copilot.Contains('beforeResponseCount=') -and $copilot.Contains('afterResponseCount=')) -Message 'fresh-chat decisions must log compact before/after evidence'
Assert-Yaku -Condition ($translationSource.Contains('silentStartFailures') -and $translationSource.Contains('COPILOT_SILENT_START_TIMEOUT')) -Message 'text translation must retry silent start once with a new request ID'
Assert-Yaku -Condition (-not $translationSource.Contains('Text glossary occurrence audit:') -and -not $translationSource.Contains("event = 'text-glossary-occurrence-violation'")) -Message 'removed in-sentence text glossary auditing must stay absent'
Assert-Yaku -Condition ($fileTranslationSource.Contains('silentStartFailures') -and $fileTranslationSource.Contains('COPILOT_SILENT_START_TIMEOUT')) -Message 'file translation must retry the current silent batch once'
Assert-Yaku -Condition (-not $fileTranslationSource.Contains('Glossary occurrence audit:') -and -not $fileTranslationSource.Contains("event = 'glossary-occurrence-violation'") -and -not $fileTranslationSource.Contains('basis=item-occurrence')) -Message 'removed in-sentence CAT glossary auditing must stay absent'
Assert-Yaku -Condition ($fileTranslationSource -match 'function Resolve-YakuFileBracketGlossaryTranslation[\s\S]{0,700}Found=\$false') -Message 'retired bracket glossary composition must always fall through to protected translation'
Assert-Yaku -Condition (-not $fileTranslationSource.Contains("Category 'glossary-compliance'")) -Message 'removed final in-sentence glossary compliance warnings must stay absent'
Assert-Yaku -Condition ($settingsSource.Contains('expected=$expectedPreview actual=$actualPreview')) -Message 'internal settings persistence must retain safe key/value mismatch details'
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
