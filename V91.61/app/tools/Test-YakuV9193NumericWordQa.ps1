#Requires -Version 5.1
<# V91.61: CAT numeric meaning warnings and English number-word equivalence. #>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9193Root = Split-Path -Parent $PSScriptRoot
$YakuT9193Src = Join-Path $YakuT9193Root 'src'
$script:YakuT9193Failures = New-Object System.Collections.Generic.List[string]

function Assert-T9193 {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:YakuT9193Failures.Add($Message) }
}
function HasCode-T9193 {
    param($Findings,[string]$Code)
    return @($Findings | Where-Object { [string]$_.Code -eq $Code }).Count -gt 0
}
function GetValue-T9193 {
    param([string]$Text)
    return [decimal](ConvertFrom-YakuEnglishNumberText -Text $Text).Value
}
function NewCase-T9193 {
    param([string]$Source,[string]$Target,[string]$Direction='to_en')
    $project = New-YakuCatTextProject -Root $YakuT9193Root -Text $Source -Settings $YakuT9193Settings -Direction $Direction -Register:$false
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text $Target
    $validation = Invoke-YakuCatSegmentValidation -Project $project -Segment $project.Segments[0]
    $eligibility = Get-YakuCatOutputEligibility -Project $project
    $preflight = Get-YakuCatOutputPreflight -Project $project
    return [pscustomobject]@{ Project=$project; Validation=$validation; Eligibility=$eligibility; Preflight=$preflight }
}

Write-Host 'Test-YakuV9193NumericWordQa'
. (Join-Path $YakuT9193Src 'SrcModules.ps1')
foreach ($YakuT9193File in $script:YakuSrcModuleFiles) {
    . (Join-Path $YakuT9193Src $YakuT9193File)
}
$YakuT9193Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9193-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $YakuT9193Temp -Force
$YakuT9193OldData = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $YakuT9193Temp 'user-data'

try {
    $YakuT9193Settings = Read-YakuSettings -Root $YakuT9193Root

    $parserCases = [ordered]@{
        'five thousand six hundred and two' = [decimal]5602
        'two hundred and forty-eight' = [decimal]248
        'twelve' = [decimal]12
        'one trillion three hundred and fifteen billion' = [decimal]1315000000000
        'one thousand three hundred and fifteen billion' = [decimal]1315000000000
        'thirteen thousand one hundred and fifty' = [decimal]13150
        'five hundred' = [decimal]500
        'minus two hundred and forty-eight' = [decimal]-248
        'five point six' = [decimal]5.6
        'first' = [decimal]1
        'second' = [decimal]2
        'twentieth' = [decimal]20
    }
    foreach ($entry in $parserCases.GetEnumerator()) {
        $parsed = ConvertFrom-YakuEnglishNumberText -Text ([string]$entry.Key)
        Assert-T9193 ([bool]$parsed.Ok -and [decimal]$parsed.Value -eq [decimal]$entry.Value) ('English parser accepts: ' + [string]$entry.Key)
    }
    foreach ($invalid in @('one hundred hundred','point five','five point sixteen','one thousand thousand','five hundred and two and three','twenty twenty four point five')) {
        $parsed = ConvertFrom-YakuEnglishNumberText -Text $invalid
        Assert-T9193 (-not [bool]$parsed.Ok) ('English parser rejects malformed phrase: ' + $invalid)
    }

    $roundTripExact = @(
        [pscustomobject]@{ Text='There is one point to consider.'; Count=1 },
        [pscustomobject]@{ Text='Sections one and two were revised.'; Count=2 },
        [pscustomobject]@{ Text='twenty twenty four'; Count=3 },
        [pscustomobject]@{ Text='between one and two percent'; Count=2 },
        [pscustomobject]@{ Text='one and two percent'; Count=2 },
        [pscustomobject]@{ Text='twenty twenty four percent'; Count=3 },
        [pscustomobject]@{ Text='from one to two percent'; Count=2 },
        [pscustomobject]@{ Text='one or two percent'; Count=2 },
        [pscustomobject]@{ Text='one, two and three percent'; Count=3 }
    )
    foreach ($item in $roundTripExact) {
        $text = [string]$item.Text
        $mask = New-YakuNumericMaskMap -Text $text -Direction to_en -Location '9193-roundtrip'
        $restored = Restore-YakuNumericMask -Text ([string]$mask.Text) -Map $mask.Map -Direction to_en -SourceText $text
        $noPlainRangeNumbers = ([int]$item.Count -eq 0 -or $mask.Text -notmatch '(?i)\b(?:one|two|three|four|twenty)\b')
        Assert-T9193 ([string]$restored -eq $text -and [int]$mask.MaskedCount -eq [int]$item.Count -and $noPlainRangeNumbers) ('range/list masking and exact restore: ' + $text)
    }
    $ordinalSource = 'The first quarter was revised.'
    $ordinalMask = New-YakuNumericMaskMap -Text $ordinalSource -Direction to_jp -Location '9193-ordinal'
    $ordinalRestored = Restore-YakuNumericMask -Text ([string]$ordinalMask.Text) -Map $ordinalMask.Map -Direction to_jp -SourceText $ordinalSource
    $ordinalJapanese = Restore-YakuNumericMask -Text '第[[N1]]四半期が改訂された。' -Map $ordinalMask.Map -Direction to_jp -SourceText $ordinalSource
    Assert-T9193 ([int]$ordinalMask.MaskedCount -eq 1 -and [string]$ordinalMask.Text -notmatch '(?i)\bfirst\b' -and [string]$ordinalRestored -eq $ordinalSource) 'ordinal mask and exact restore: first'
    Assert-T9193 ([string]$ordinalJapanese -notmatch '(?i)\bfirst\b' -and [string]$ordinalJapanese -match '第1四半期') 'ordinal restore to Japanese does not leave English'
    $ordinalCase = NewCase-T9193 -Source 'first' -Target '1' -Direction to_jp
    $ordinalNumericFindings = @($ordinalCase.Validation.Findings | Where-Object { [string]$_.Code -like 'numeric-*' -or [string]$_.Code -eq 'currency-mismatch' })
    Assert-T9193 ([bool]$ordinalCase.Validation.Passed -and $ordinalNumericFindings.Count -eq 0 -and [bool]$ordinalCase.Eligibility.TranslationListEligible -and [bool]$ordinalCase.Preflight.Eligible) 'ordinal canonical fact is numeric and nonblocking'
    $roundTripNumbers = @(
        @{ Text='five thousand six hundred and two'; Expected='5,602' },
        @{ Text='one trillion three hundred and fifteen billion'; Expected='1,315,000,000,000' },
        @{ Text='five point six'; Expected='5.6' }
    )
    foreach ($item in $roundTripNumbers) {
        $mask = New-YakuNumericMaskMap -Text ([string]$item.Text) -Direction to_en -Location '9193-roundtrip'
        $restored = Restore-YakuNumericMask -Text ([string]$mask.Text) -Map $mask.Map -Direction to_en -SourceText ([string]$item.Text)
        Assert-T9193 ([int]$mask.MaskedCount -eq 1 -and [string]$restored -eq [string]$item.Expected) ('number-word masking preserves value: ' + [string]$item.Text)
    }

    $directPairs = @(
        @('5,602','five thousand six hundred and two'),
        @('248','two hundred and forty-eight'),
        @('12％','twelve percent'),
        @('500 k units','five hundred k units'),
        @('△248','minus two hundred and forty-eight')
    )
    foreach ($pair in $directPairs) {
        $left = @(Get-YakuCanonicalNumericFacts -Text ([string]$pair[0]) -Direction to_en | ForEach-Object { [string]$_.Key })
        $right = @(Get-YakuCanonicalNumericFacts -Text ([string]$pair[1]) -Direction to_en | ForEach-Object { [string]$_.Key })
        Assert-T9193 (($left -join '|') -eq ($right -join '|')) ('canonical facts agree: ' + [string]$pair[0] + ' / ' + [string]$pair[1])
    }

    $jpOku = [string]::Concat('1',[char]0x5146,'3,150',[char]0x5104,[char]0x5186)
    $jpTriangle = [string]::Concat([char]0x25B3,'248')
    $counterCases = @(
        [pscustomobject]@{ Source=$jpOku; Target='one trillion three hundred and fifteen billion yen' },
        [pscustomobject]@{ Source='13,150 oku'; Target='thirteen thousand one hundred and fifty oku' },
        [pscustomobject]@{ Source=('3' + [string][char]0x53F0); Target='three vehicles' },
        [pscustomobject]@{ Source=('4' + [string][char]0x4EF6); Target='four cases' },
        [pscustomobject]@{ Source=('5' + [string][char]0x682A); Target='five shares' }
    )
    foreach ($pair in $counterCases) {
        $case = NewCase-T9193 -Source ([string]$pair.Source) -Target ([string]$pair.Target)
        Assert-T9193 ([bool]$case.Validation.Passed -and @($case.Validation.Findings | Where-Object { [string]$_.Code -like 'numeric-*' -or [string]$_.Code -eq 'currency-mismatch' }).Count -eq 0) ('meaning-equivalent unit/counter has no numeric warning: ' + [string]$pair.Source)
        Assert-T9193 ([bool]$case.Eligibility.TranslationListEligible -and [bool]$case.Preflight.Eligible) ('meaning-equivalent unit/counter remains export eligible: ' + [string]$pair.Source)
    }

    $positive = @(
        [pscustomobject]@{ Source='5602'; Target='five thousand six hundred and two' },
        [pscustomobject]@{ Source='248'; Target='two hundred and forty-eight' },
        [pscustomobject]@{ Source='12％'; Target='twelve percent' },
        [pscustomobject]@{ Source='5.6%'; Target='five point six percent' },
        [pscustomobject]@{ Source='500 k units'; Target='five hundred k units' },
        [pscustomobject]@{ Source=$jpTriangle; Target='minus two hundred and forty-eight' }
    )
    foreach ($pair in $positive) {
        $case = NewCase-T9193 -Source ([string]$pair.Source) -Target ([string]$pair.Target)
        Assert-T9193 ([bool]$case.Validation.Passed -and @($case.Validation.Findings | Where-Object { [string]$_.Code -like 'numeric-*' -or [string]$_.Code -eq 'currency-mismatch' }).Count -eq 0) ('meaning-equivalent number is warning free: ' + [string]$pair.Source)
    }

    foreach ($rangeCaseSpec in @(
        @{ Text='between one and two percent'; Code='numeric-value-mismatch' }
        @{ Text='from one to two percent'; Code='numeric-value-mismatch' }
        @{ Text='one or two percent'; Code='numeric-value-mismatch' }
        @{ Text='one, two and three percent'; Code='numeric-value-extra' }
    )) {
        $rangeText = [string]$rangeCaseSpec.Text
        $rangeCase = NewCase-T9193 -Source '3%' -Target $rangeText
        Assert-T9193 (HasCode-T9193 -Findings @($rangeCase.Validation.Findings) -Code ([string]$rangeCaseSpec.Code)) ('range/list wording is not mistaken for the source value: ' + $rangeText)
        Assert-T9193 ([bool]$rangeCase.Validation.Passed -and [bool]$rangeCase.Eligibility.TranslationListEligible -and [bool]$rangeCase.Preflight.Eligible) ('range/list mismatch remains a visible nonblocking warning: ' + $rangeText)
    }

    foreach ($invalidCompound in @(
        [pscustomobject]@{ Source='505%'; Target='five hundred and two and three percent'; Count=4 }
        [pscustomobject]@{ Source='44.5%'; Target='twenty twenty four point five percent'; Count=4 }
    )) {
        $compoundParsed = ConvertFrom-YakuEnglishNumberText -Text ([string]$invalidCompound.Target).Replace(' percent','')
        $compoundMask = New-YakuNumericMaskMap -Text ([string]$invalidCompound.Target) -Direction to_en -Location '9193-strict-compound'
        $compoundRestored = Restore-YakuNumericMask -Text ([string]$compoundMask.Text) -Map $compoundMask.Map -Direction to_en -SourceText ([string]$invalidCompound.Target)
        Assert-T9193 (-not [bool]$compoundParsed.Ok -and [int]$compoundMask.MaskedCount -eq [int]$invalidCompound.Count -and [string]$compoundRestored -eq [string]$invalidCompound.Target -and [string]$compoundMask.Text -notmatch '(?i)\b(?:one|two|three|four|five|twenty|hundred)\b') ('strict compound does not collapse or leak: ' + [string]$invalidCompound.Target)
        $compoundCase = NewCase-T9193 -Source ([string]$invalidCompound.Source) -Target ([string]$invalidCompound.Target)
        $compoundNumericFindings = @($compoundCase.Validation.Findings | Where-Object { [string]$_.Code -like 'numeric-*' -or [string]$_.Code -eq 'currency-mismatch' })
        Assert-T9193 ([bool]$compoundCase.Validation.Passed -and $compoundNumericFindings.Count -gt 0 -and [bool]$compoundCase.Eligibility.TranslationListEligible -and [bool]$compoundCase.Preflight.Eligible) ('strict compound remains a visible nonblocking mismatch: ' + [string]$invalidCompound.Target)
    }

    $negativeCases = @(
        @{Source='5602';Target='five thousand six hundred and three';Code='numeric-value-mismatch'},
        @{Source='5602';Target='five thousand six hundred';Code='numeric-value-mismatch'},
        @{Source='5602';Target='five thousand six hundred and two and 7';Code='numeric-value-extra'},
        @{Source='2, 3';Target='3, 2';Code='numeric-value-order-mismatch'},
        @{Source='100' + [string][char]0x5186;Target='one hundred dollars';Code='currency-mismatch'},
        @{Source='500 k units';Target='five hundred units';Code='numeric-scale-mismatch'},
        @{Source=$jpTriangle;Target='two hundred and forty-eight';Code='numeric-sign-missing'},
        @{Source='Profit is 100 yen';Target='Loss is one hundred yen';Code='accounting-polarity-mismatch'},
        @{Source='100';Target='one hundred hundred';Code='numeric-validation-error'}
    )
    foreach ($item in $negativeCases) {
        $case = NewCase-T9193 -Source ([string]$item.Source) -Target ([string]$item.Target)
        Assert-T9193 (HasCode-T9193 -Findings @($case.Validation.Findings) -Code ([string]$item.Code)) ('mismatch is visible as ' + [string]$item.Code + ': ' + [string]$item.Source)
        Assert-T9193 ([bool]$case.Validation.Passed -and [bool]$case.Eligibility.TranslationListEligible -and [bool]$case.Preflight.Eligible) ('numeric warning does not block confirmation/export: ' + [string]$item.Code)
    }

    $numericToolCase = NewCase-T9193 -Source '100' -Target 'one hundred hundred'
    $numericToolFinding = @($numericToolCase.Validation.Findings | Where-Object { [string]$_.Code -eq 'numeric-validation-error' })[0]
    $toolCodes = @(Get-YakuCatQcToolTroubleCodes)
    $warningCodes = @(Get-YakuCatQcWarningCodes)
    $catJsText = [IO.File]::ReadAllText((Join-Path $YakuT9193Root 'www/assets/cat.js'), (New-Object System.Text.UTF8Encoding($false)))
    $catToolBody = ([regex]::Match($catJsText, 'var\s+QC_TOOL_TROUBLE_CODES\s*=\s*\[([^\]]*)\]')).Groups[1].Value
    $catWarningBody = ([regex]::Match($catJsText, 'var\s+QC_WARNING_CODES\s*=\s*\[([^\]]*)\]')).Groups[1].Value
    $qcGroupBody = ([regex]::Match($catJsText, '(?s)function\s+qcGroup\(code\)\s*\{(.*?)\n\s*\}')).Groups[1].Value
    Assert-T9193 ($null -ne $numericToolFinding -and [string]$numericToolFinding.Severity -eq 'warning') 'numeric-validation-error remains a warning finding'
    Assert-T9193 ($toolCodes -contains 'numeric-validation-error' -and $warningCodes -notcontains 'numeric-validation-error') 'numeric-validation-error belongs only to the server tool-trouble set'
    Assert-T9193 ($catToolBody -match "numeric-validation-error" -and $catWarningBody -notmatch "numeric-validation-error" -and $qcGroupBody -match "QC_TOOL_TROUBLE_CODES[\s\S]*return 'tool'") 'cat.js renders numeric-validation-error as tool trouble, not warning'

    $placeholder = NewCase-T9193 -Source 'Value 100' -Target 'Value [[N1]]'
    Assert-T9193 ((HasCode-T9193 -Findings @($placeholder.Validation.Findings) -Code 'placeholder-residue') -and -not [bool]$placeholder.Validation.Passed -and -not [bool]$placeholder.Eligibility.TranslationListEligible) 'placeholder residue remains an error and export blocker'

    $warningFixture = [pscustomobject]@{ Findings=@([pscustomobject]@{ Code='numeric-value-mismatch'; Severity='warning' }) }
    $warningGate = @($warningFixture.Findings | Where-Object { [string]$_.Severity -eq 'error' }).Count -eq 0
    $warningFixture.Findings[0].Severity = 'error'
    $brokenGate = @($warningFixture.Findings | Where-Object { [string]$_.Severity -eq 'error' }).Count -gt 0
    Assert-T9193 ($warningGate -and $brokenGate) 'negative self-test detects a controlled warning-to-error severity mutation'
} finally {
    $env:YAKULINGO_DATA_DIR = $YakuT9193OldData
    if (Test-Path -LiteralPath $YakuT9193Temp) { Remove-Item -LiteralPath $YakuT9193Temp -Recurse -Force }
}

Write-Host ''
if ($script:YakuT9193Failures.Count -eq 0) { Write-Host 'PASS Test-YakuV9193NumericWordQa'; exit 0 }
Write-Host ('FAIL ' + $script:YakuT9193Failures.Count + ' assertion(s)')
foreach ($failure in $script:YakuT9193Failures) { Write-Host ('  - ' + $failure) }
exit 1
