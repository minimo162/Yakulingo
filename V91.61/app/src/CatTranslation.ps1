function Get-YakuCatPromptContractVersion {
    return 'cat-canonical-v1'
}

function Assert-YakuCatProtectedItems {
    param([Parameter(Mandatory=$true)][object[]]$Items)
    foreach ($item in @($Items)) {
        if ($null -eq $item) { throw 'CAT_PROTECTED_PAYLOAD_NULL_ITEM' }
        $names = @($item.PSObject.Properties.Name)
        foreach ($required in @('OriginalText','MaskedText','NumericMaskMap','ProtectionContractVersion')) {
            if ($names -notcontains $required) { throw ('CAT_PROTECTED_PAYLOAD_MISSING_' + $required.ToUpperInvariant()) }
        }
        if ([string]$item.ProtectionContractVersion -ne 'cat-protection-v1') { throw 'CAT_PROTECTED_PAYLOAD_VERSION_UNSUPPORTED' }
        if (-not [string]::Equals([string]$item.Text, [string]$item.MaskedText, [System.StringComparison]::Ordinal)) {
            throw 'CAT_PROTECTED_PAYLOAD_MUTATED_AFTER_MASKING'
        }
    }
}

function Test-YakuCatProtectionMapEqual {
    param([AllowNull()]$Actual, [AllowNull()]$Expected)
    $actualKeys = @($(if ($null -ne $Actual) { $Actual.Keys }))
    $expectedKeys = @($(if ($null -ne $Expected) { $Expected.Keys }))
    if ($actualKeys.Count -ne $expectedKeys.Count) { return $false }
    foreach ($key in $expectedKeys) {
        if ($actualKeys -notcontains $key -or -not [string]::Equals([string]$Actual[$key], [string]$Expected[$key], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Assert-YakuCatProtectedItemsMatchOriginal {
    param(
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    foreach ($item in @($Items)) {
        $expected = [pscustomobject]@{ Index=$item.Index; Text=[string]$item.OriginalText }
        $null = Protect-YakuCatItems -Items @($expected) -Root $Root -Direction $Direction
        if (-not [string]::Equals([string]$item.MaskedText, [string]$expected.MaskedText, [StringComparison]::Ordinal) -or
            -not (Test-YakuCatProtectionMapEqual -Actual $item.NumericMaskMap -Expected $expected.NumericMaskMap)) {
            throw 'CAT_PROTECTED_PAYLOAD_NONCANONICAL'
        }
    }
}

function Assert-YakuCatPromptHasNoUnmaskedValues {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][object[]]$Items
    )
    foreach ($item in @($Items)) {
        $numericMap = $null
        try { $numericMap = $item.NumericMaskMap } catch {}
        foreach ($token in @($(if ($null -ne $numericMap) { $numericMap.Keys }))) {
            $value = [string]$numericMap[$token]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $pattern = '(?<![0-9A-Za-z])' + [regex]::Escape($value) + '(?![0-9A-Za-z])'
            if ([regex]::IsMatch($Prompt, $pattern)) { throw 'CAT_PROMPT_CONTAINS_UNMASKED_NUMERIC_VALUE' }
        }
    }
}

function Test-YakuCatCachedTranslation {
    param(
        [Parameter(Mandatory=$true)]$Item,
        [AllowNull()][string]$Translation,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    $invalid = if (Get-Command Test-YakuCatTranslationInvalid -ErrorAction SilentlyContinue) { Test-YakuCatTranslationInvalid -Source ([string]$Item.Text) -Translation $Translation -Direction $Direction } else { Test-YakuFileTranslationInvalid -Source ([string]$Item.Text) -Translation $Translation -Direction $Direction }
    if ($invalid) { return $false }
    try {
        $numeric = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$Item.MaskedText) -Translated ([string]$Translation) -Location ('cat-cache-' + [string]$Item.Index)
        if (-not [bool]$numeric.Ok) { return $false }
    } catch { return $false }
    return $true
}

function New-YakuCatPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId
    )
    $sourceList = New-YakuFileSourceList -Items $Items
    $templateName = if ($Direction -eq 'to_en') { 'cat_translate_to_en.txt' } else { 'cat_translate_to_jp.txt' }
    $template = Get-YakuPromptTemplate -Root $Root -Name $templateName
    $vars = @{
        source_list = $sourceList
        numeric_rules = Get-YakuNumericRulesSection -InputText $sourceList -Direction $Direction
        request_id = $RequestId
    }
    $prompt = Expand-YakuTemplate -Template $template -Variables $vars
    Assert-YakuCatPromptHasNoUnmaskedValues -Prompt $prompt -Items $Items
    return $prompt
}

function Invoke-YakuCatTranslationItems {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][int]$MaxChars,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$ProgressState,
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [int]$Depth = 0,
        [string]$Reason = 'normal'
    )
    Assert-YakuCatProtectedItems -Items $Items
    Assert-YakuCatProtectedItemsMatchOriginal -Items $Items -Root $Root -Direction $Direction
    $Context['Workflow'] = 'cat'
    $Context['PromptContractVersion'] = Get-YakuCatPromptContractVersion
    return Invoke-YakuTranslationBatchItems -Root $Root -Items $Items -Settings $Settings -Direction $Direction -MaxChars $MaxChars -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth $Depth -Reason $Reason
}
