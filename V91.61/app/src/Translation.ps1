function Remove-YakuMarkdownEscapes {
    param([AllowNull()][string]$Text)
    # Copilot sometimes emits defensive Markdown escapes in plain-text answers.
    # Remove only punctuation escapes; keep backslashes before letters/digits intact.
    return [regex]::Replace([string]$Text, '\\([\\\[\]_*<>#+\-.!()`~|{}])', '$1')
}

function Normalize-YakuCopilotPlainResponse {
    param([AllowNull()][string]$Raw, [AllowNull()][string]$RequestId = '')
    $text = Remove-YakuMarkdownEscapes -Text ([string]$Raw)
    # Copilot response DOM can contain invisible editor/direction controls just
    # like the Lexical input DOM. Remove controls, never visible punctuation.
    $text = [regex]::Replace($text, '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', '')
    $text = $text.Trim()
    $text = [regex]::Replace($text, '(?is)^\s*```(?:text|plain)?\s*', '')
    $text = [regex]::Replace($text, '(?is)\s*```\s*$', '')
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $labels = 'FULL_TEXT|BRIEF_TEXT|JAPANESE_TEXT'
    $text = [regex]::Replace($text, "(?im)^\s*\*\*\s*($labels)\s*[:：]\s*\*\*\s*", '$1: ')
    $text = [regex]::Replace($text, "(?im)^\s*\*\*\s*($labels)\s*\*\*\s*[:：]\s*", '$1: ')
    $text = [regex]::Replace($text, "(?im)^\s*($labels)\s*：\s*", '$1: ')
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
        $marker = 'YAKULINGO_END:' + $RequestId
        $markerMatch = [regex]::Match($text, [regex]::Escape($marker), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($markerMatch.Success) {
            $beforeMarker = $text.Substring(0, $markerMatch.Index)
            # Strip Markdown emphasis surrounding the marker, place the marker
            # on its own line, and discard all scraped UI text after it.
            $beforeMarker = [regex]::Replace($beforeMarker, '\*\*\s*$', '')
            $beforeMarker = $beforeMarker.TrimEnd()
            $text = if ($beforeMarker.Length -gt 0) { $beforeMarker + "`n" + $marker } else { $marker }
        }
    }
    $text = [regex]::Replace($text, "[ \t]+`n", "`n")
    $text = [regex]::Replace($text, "`n{4,}", "`n`n`n")
    return $text.Trim()
}



function Get-YakuTranslationCacheStore {
    $name = 'YakuLingoTranslationCache'
    try {
        $store = [AppDomain]::CurrentDomain.GetData($name)
        if ($null -eq $store) {
            $store = [hashtable]::Synchronized(@{})
            [AppDomain]::CurrentDomain.SetData($name, $store)
        }
        return $store
    } catch {
        if ($null -eq $script:YakuTranslationMemoryCache) { $script:YakuTranslationMemoryCache = [hashtable]::Synchronized(@{}) }
        return $script:YakuTranslationMemoryCache
    }
}

function Get-YakuProcessHmacKey {
    $name = 'YakuLingoProcessHmacKeyV1'
    $key = [AppDomain]::CurrentDomain.GetData($name)
    if ($null -eq $key -or @($key).Count -ne 32) {
        $key = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($key) } finally { $rng.Dispose() }
        [AppDomain]::CurrentDomain.SetData($name, $key)
    }
    return [byte[]]$key
}

function Get-YakuTextHmacSha256 {
    param([AllowNull()][string]$Text)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (,(Get-YakuProcessHmacKey))
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return [BitConverter]::ToString($hmac.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
    } finally { $hmac.Dispose() }
}

function Test-YakuTranslationCacheEnabled {
    param([AllowNull()]$Settings)
    try {
        if ($Settings -and ($Settings.PSObject.Properties.Name -contains 'translation_cache_enabled')) {
            $v = $Settings.translation_cache_enabled
            if ($v -is [bool]) { return [bool]$v }
            return ([string]$v -in @('true','on','1','yes'))
        }
    } catch {}
    return $true
}

function Clear-YakuTranslationCache {
    try { (Get-YakuTranslationCacheStore).Clear() } catch {}
    $script:YakuTranslationContractFingerprintCache = $null
}

function Get-YakuTranslationContractFingerprint {
    param([AllowNull()][string]$Root, [AllowNull()]$Settings)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        try { $Root = Get-YakuRoot } catch { $Root = '' }
    }
    $names = @('prompts\text_translate_full_to_en.txt','prompts\text_translate_brief_to_en.txt','prompts\text_translate_to_jp.txt','prompts\cat_translate_to_en.txt','prompts\cat_translate_to_jp.txt','prompts\style_brief_rules.txt')
    $settingParts = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('copilot_model','glossary_prompt_limit','max_chars_per_batch','max_chars_per_batch_file')) {
        try { $settingParts.Add($key + '=' + [string]$Settings.$key) | Out-Null } catch { $settingParts.Add($key + '=') | Out-Null }
    }
    # V91.60 §7: マスキング仕様の識別子と有効・無効の状態を契約へ含める。
    # マスクなしで作られた訳文をマスク経路で再利用すると復元が壊れる。
    # メモ化の判定にも入れないと、状態が変わっても古い指紋を返してしまう。
    $maskContract = 'numeric-mask-v9160=' + $(if (Test-YakuNumericMaskingEnabled) { 'on' } else { 'off' })
    $settingParts.Add($maskContract) | Out-Null
    $settingsSignature = $Root + '|' + (($settingParts.ToArray()) -join '|')
    $fileSignatureParts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $path = Join-Path $Root $name
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $fileSignatureParts.Add($name + '|' + $item.Length + '|' + $item.LastWriteTimeUtc.Ticks) | Out-Null
        } catch { $fileSignatureParts.Add($name + '|missing') | Out-Null }
    }
    $fileSignature = ($fileSignatureParts.ToArray()) -join '|'
    try {
        $cached = $script:YakuTranslationContractFingerprintCache
        if ($cached -and [string]$cached.SettingsSignature -eq $settingsSignature -and [string]$cached.FileSignature -eq $fileSignature) {
            $cached.CheckedAt = Get-Date
            return [string]$cached.Fingerprint
        }
    } catch {}

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('translation-contract-v87') | Out-Null
    foreach ($name in $names) {
        try {
            $path = Join-Path $Root $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $parts.Add((Get-YakuTextSha256 -Text (Get-Content -LiteralPath $path -Raw -Encoding UTF8))) | Out-Null
            }
        } catch { $parts.Add('missing') | Out-Null }
    }
    foreach ($setting in $settingParts.ToArray()) { $parts.Add([string]$setting) | Out-Null }
    $fingerprint = Get-YakuTextSha256 -Text (($parts.ToArray()) -join '|')
    $script:YakuTranslationContractFingerprintCache = [pscustomobject]@{ SettingsSignature=$settingsSignature; FileSignature=$fileSignature; Fingerprint=$fingerprint; CheckedAt=(Get-Date) }
    return $fingerprint
}

function Get-YakuTranslationCacheKey {
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$Style = '',
        [AllowNull()][string]$Root,
        [AllowNull()]$Settings
    )
    # Cache keys are process-local because the cache itself is process-local. Use a
    # keyed digest so a leaked key cannot be used as a dictionary of source text.
    $hash = Get-YakuTextHmacSha256 -Text $Text
    $contract = Get-YakuTranslationContractFingerprint -Root $Root -Settings $Settings
    return ($Kind + '|' + $Direction + '|' + $Style + '|' + $contract + '|' + $hash)
}

function Get-YakuTranslationCacheValue {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [AllowNull()]$Settings
    )
    if (-not (Test-YakuTranslationCacheEnabled -Settings $Settings)) { return $null }
    $store = Get-YakuTranslationCacheStore
    try { if ($store.ContainsKey($Key)) { return [string]$store[$Key] } } catch {}
    return $null
}

function Set-YakuTranslationCacheValue {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [AllowNull()][string]$Value,
        [AllowNull()]$Settings,
        [int]$MaxEntries = 5000
    )
    if (-not (Test-YakuTranslationCacheEnabled -Settings $Settings)) { return }
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $store = Get-YakuTranslationCacheStore
    try {
        if ($store.Count -ge $MaxEntries) { $store.Clear() }
        $store[$Key] = [string]$Value
    } catch {}
}

function Get-YakuLabeledResponseField {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][string]$Label
    )
    $labels = 'FULL_TEXT|BRIEF_TEXT|JAPANESE_TEXT|FULL_NOTES|BRIEF_NOTES|JAPANESE_NOTES|YAKULINGO_END|YAKULINGO_DONE'
    $labelEsc = [regex]::Escape($Label)
    $pattern = "(?is)(?:^|`n)\s*(?:\*\*)?$labelEsc(?:\*\*)?\s*:\s*(.*?)(?=`n\s*(?:(?:\*\*)?(?:$labels)(?:\*\*)?\s*:|YAKULINGO\\?_(?:END|DONE)\b)|\z)"
    $m = [regex]::Match([string]$Text, $pattern)
    if (!$m.Success) { return '' }
    $value = $m.Groups[1].Value
    $value = [regex]::Replace($value, '(?im)^\s*YAKULINGO\\?_(?:END|DONE)\s*$', '')
    return $value.Trim()
}

function Get-YakuTextRequiredLabels {
    <#
      その依頼が Copilot に出させるラベル。

      V91.61（2026-08-06）: 完全訳と開示用の電文体を別々の依頼にした。
      電文体は完全訳を短くしたものではなく、同じ原文に対する別の成果物である。
      通常は完全訳だけを求め、「短く」の専用処理だけが brief を求める。
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [ValidateSet('full','brief')][string]$Mode = 'full'
    )
    if ($Direction -ne 'to_en') { return @('JAPANESE_TEXT') }
    switch ([string]$Mode) {
        'full'  { return @('FULL_TEXT') }
        'brief' { return @('BRIEF_TEXT') }
        default { return @('FULL_TEXT') }
    }
}

function Test-YakuTextResponseContract {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId,
        [ValidateSet('full','brief')][string]$Mode = 'full'
    )
    $rawText = [string]$Text
    if ($rawText -match '(?s)^\s*```[^\r\n]*\r?\n.*\r?\n```\s*$') {
        return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_NOT_PLAIN_TEXT'; Message='コードフェンス付き応答は受理できません。' }
    }
    $rawEndPattern = [regex]::Escape('YAKULINGO_END:' + $RequestId)
    if ([regex]::Matches($rawText, $rawEndPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -gt 1) {
        return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_END_MARKER_DUPLICATE'; Message='終端マーカーが重複しています。' }
    }
    $clean = Normalize-YakuCopilotPlainResponse -Raw $rawText -RequestId $RequestId
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_EMPTY'; Message='Copilotの応答が空です。' }
    }
    $lines = @($clean.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n")
    $nonEmpty = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $end = 'YAKULINGO_END:' + $RequestId
    $endPattern = '^\s*(?:\*\*)?' + [regex]::Escape($end) + '(?:\*\*)?\s*$'
    if ($nonEmpty.Count -eq 0 -or (([string]$nonEmpty[-1]) -notmatch $endPattern)) {
        return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_END_MARKER_MISSING'; Message='要求ID付き終端マーカーが最終行にありません。' }
    }
    $endCount = @($lines | Where-Object { ([string]$_) -match $endPattern }).Count
    if ($endCount -ne 1) {
        return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_END_MARKER_DUPLICATE'; Message='終端マーカーが重複しています。' }
    }
    # Wrap the complete if expression: PowerShell otherwise unwraps the
    # one-element to_jp result into a string, making $required[0] equal "J".
    $required = @(Get-YakuTextRequiredLabels -Direction $Direction -Mode $Mode)
    if ($required -isnot [array]) { throw 'CONTRACT_INTERNAL: $required must be an array.' }
    $firstLabelPattern = '^\s*(?:\*\*)?' + [regex]::Escape(([string]$required[0])) + '(?:\*\*)?\s*:\s*'
    $warningCode = ''
    $warningMessage = ''
    if (([string]$nonEmpty[0]) -notmatch $firstLabelPattern) {
        $candidateMatch = [regex]::Match($clean, '(?im)^\s*(?:\*\*)?' + [regex]::Escape(([string]$required[0])) + '(?:\*\*)?\s*:\s*')
        if (-not $candidateMatch.Success -or $candidateMatch.Index -le 0) {
            return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_PREFIX_INVALID'; Message='応答は必須ラベルから開始する必要があります。' }
        }
        $clean = $clean.Substring($candidateMatch.Index).Trim()
        $lines = @($clean -split "`n")
        $nonEmpty = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $warningCode = 'RESPONSE_PREFIX_RECOVERED'
        $warningMessage = '必須ラベルより前の非契約テキストを除外して応答を復旧しました。'
    }
    $lastRequiredIndex = -1
    foreach ($label in $required) {
        $matchingIndexes = @()
        $labelLinePattern = '^\s*(?:\*\*)?' + [regex]::Escape(([string]$label)) + '(?:\*\*)?\s*:\s*'
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if (([string]$lines[$lineIndex]) -match $labelLinePattern) { $matchingIndexes += $lineIndex }
        }
        $count = $matchingIndexes.Count
        if ($count -ne 1) {
            return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_LABEL_COUNT_INVALID'; Message="$label は1回だけ必要です。" }
        }
        if ([int]$matchingIndexes[0] -le $lastRequiredIndex) {
            return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_LABEL_ORDER_INVALID'; Message='必須ラベルの順序が不正です。' }
        }
        $lastRequiredIndex = [int]$matchingIndexes[0]
        $value = Get-YakuLabeledResponseField -Text $clean -Label $label
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Trim() -eq '...') {
            return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_FIELD_EMPTY'; Message="$label が空です。" }
        }
    }
    $unexpected = if ($Direction -ne 'to_en') {
        'FULL_TEXT|BRIEF_TEXT'
    } elseif ($Mode -eq 'brief') {
        'FULL_TEXT|JAPANESE_TEXT'
    } else {
        'BRIEF_TEXT|JAPANESE_TEXT'
    }
    if ($clean -match ("(?im)^\s*(?:\*\*)?(?:$unexpected)(?:\*\*)?\s*:")) {
        return [pscustomobject]@{ Valid=$false; ErrorCode='RESPONSE_STYLE_UNEXPECTED'; Message='要求していない翻訳スタイルが含まれています。' }
    }
    return [pscustomobject]@{ Valid=$true; ErrorCode=''; Message=''; WarningCode=$warningCode; WarningMessage=$warningMessage; NormalizedText=$clean }
}

function ConvertFrom-YakuTextFullWidthAngle {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ([string]$Text).Replace('＜', '<').Replace('＞', '>')
}


function Get-YakuNumberedHeadingSequence {
    param([AllowNull()][string]$Text)
    $items = New-Object System.Collections.Generic.List[object]
    $lines = @(([string]$Text).Replace("`r`n","`n").Replace("`r","`n") -split "`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match([string]$lines[$i], '^\s*(?:#{1,6}\s+)?(\d+)([\.．])(?:\s+\S.*?)?\s*$')
        if ($m.Success) {
            $items.Add([pscustomobject]@{ LineIndex=[int]$i; Number=[string]$m.Groups[1].Value; Separator=[string]$m.Groups[2].Value }) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Repair-YakuNumberedHeadingSequence {
    param(
        [Parameter(Mandatory=$true)][string]$SourceText,
        [AllowNull()][string]$TranslatedText,
        [Parameter(Mandatory=$true)][string]$Style
    )
    $source = @(Get-YakuNumberedHeadingSequence -Text $SourceText)
    $target = @(Get-YakuNumberedHeadingSequence -Text $TranslatedText)
    $result = [pscustomobject]@{ Text=[string]$TranslatedText; Restored=$false; Detail="numberedHeadings source=$($source.Count) target=$($target.Count)" }
    if ($source.Count -lt 2 -or $target.Count -ne $source.Count) {
        $targetNumbersForSkip = @($target | ForEach-Object { [string]$_.Number } | Select-Object -Unique)
        $repeatedTargetWithoutSource = ($source.Count -eq 0 -and $target.Count -ge 2 -and $targetNumbersForSkip.Count -eq 1)
        if (($source.Count -gt 0 -and $target.Count -ne $source.Count) -or $repeatedTargetWithoutSource) {
            try { Write-YakuLog "Text numbered headings mismatch; restore skipped. style=$Style source=$($source.Count) target=$($target.Count) repeatedTarget=$repeatedTargetWithoutSource" 'WARN' } catch {}
        }
        return $result
    }
    $sourceNumbers = @($source | ForEach-Object { [string]$_.Number })
    $targetNumbers = @($target | ForEach-Object { [string]$_.Number })
    if (($sourceNumbers -join ',') -eq ($targetNumbers -join ',')) { return $result }
    $lines = @(([string]$TranslatedText).Replace("`r`n","`n").Replace("`r","`n") -split "`n")
    for ($i = 0; $i -lt $target.Count; $i++) {
        $lineIndex = [int]$target[$i].LineIndex
        $headingPrefixRegex = New-Object System.Text.RegularExpressions.Regex('^(\s*(?:#{1,6}\s+)?)\d+([\.．])(\s*)')
        $lines[$lineIndex] = $headingPrefixRegex.Replace([string]$lines[$lineIndex], ('${1}' + [string]$source[$i].Number + '${2}${3}'), 1)
    }
    $restoredText = ($lines -join "`n")
    try { Write-YakuLog "Text numbered headings restored from source. style=$Style count=$($source.Count) sourceNumbers=$($sourceNumbers -join ',') targetNumbers=$($targetNumbers -join ',')" 'WARN' } catch {}
    return [pscustomobject]@{ Text=$restoredText; Restored=$true; Detail="numberedHeadings restored=$($source.Count)" }
}
function ConvertTo-YakuInvariantNumberText {
    param([Parameter(Mandatory=$true)][decimal]$Value, [switch]$UseGrouping)
    if ($Value -eq [decimal]::Truncate($Value)) {
        $fmt = if ($UseGrouping) { '#,0' } else { '0' }
        return ([decimal]::Truncate($Value)).ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
    }
    $fmt = if ($UseGrouping) { '#,0.################' } else { '0.################' }
    return $Value.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-YakuJapaneseNumberText {
    param([AllowNull()][string]$Text)
    $s = (ConvertTo-YakuMaskNormalizedText -Text ([string]$Text)).Trim()
    $s = $s.Replace('壱','一').Replace('弐','二').Replace('参','三').Replace('拾','十').Replace('零','〇')
    if ($s -notmatch '^[〇一二三四五六七八九十百千万億兆]+$') { return [pscustomobject]@{ Ok=$false; Value=[decimal]0 } }
    $digits = @{ '〇'=0; '一'=1; '二'=2; '三'=3; '四'=4; '五'=5; '六'=6; '七'=7; '八'=8; '九'=9 }
    $small = @{ '十'=[decimal]10; '百'=[decimal]100; '千'=[decimal]1000 }
    $large = @{ '万'=[decimal]10000; '億'=[decimal]100000000; '兆'=[decimal]1000000000000 }
    [decimal]$total = 0; [decimal]$section = 0; [decimal]$current = 0
    foreach ($ch in $s.ToCharArray()) {
        $key = [string]$ch
        if ($digits.ContainsKey($key)) { $current = [decimal]$digits[$key]; continue }
        if ($small.ContainsKey($key)) {
            if ($current -eq 0) { $current = 1 }
            $section += $current * [decimal]$small[$key]
            $current = 0
            continue
        }
        if ($large.ContainsKey($key)) {
            $section += $current
            if ($section -eq 0) { $section = 1 }
            $total += $section * [decimal]$large[$key]
            $section = 0; $current = 0
        }
    }
    return [pscustomobject]@{ Ok=$true; Value=($total + $section + $current) }
}

function ConvertFrom-YakuEnglishNumberText {
    param([AllowNull()][string]$Text)
    $s = ([string]$Text).ToLowerInvariant().Replace('-', ' ')
    $words = @($s -split '\s+' | Where-Object { $_ -and $_ -ne 'and' })
    if ($words.Count -eq 0) { return [pscustomobject]@{ Ok=$false; Value=[decimal]0 } }
    $values = @{
        a=1; zero=0; one=1; two=2; three=3; four=4; five=5; six=6; seven=7; eight=8; nine=9; ten=10
        eleven=11; twelve=12; thirteen=13; fourteen=14; fifteen=15; sixteen=16; seventeen=17; eighteen=18; nineteen=19
        twenty=20; thirty=30; forty=40; fifty=50; sixty=60; seventy=70; eighty=80; ninety=90
    }
    $large = @{ thousand=[decimal]1000; million=[decimal]1000000; billion=[decimal]1000000000; trillion=[decimal]1000000000000 }
    [decimal]$total=0; [decimal]$current=0
    foreach ($word in $words) {
        if ($values.ContainsKey($word)) { $current += [decimal]$values[$word]; continue }
        if ($word -eq 'hundred') { if ($current -eq 0) { $current=1 }; $current *= 100; continue }
        if ($large.ContainsKey($word)) { if ($current -eq 0) { $current=1 }; $total += $current * [decimal]$large[$word]; $current=0; continue }
        return [pscustomobject]@{ Ok=$false; Value=[decimal]0 }
    }
    return [pscustomobject]@{ Ok=$true; Value=($total + $current) }
}

function Get-YakuNumericContextDescriptor {
    <#
      [[N1]] の前後から、値に掛かる桁と通貨を一度だけ解釈する。
      復元とCAT QCが別々の正規表現を持つと、同じ誤表記を同時に見逃すため、
      `120 million yen` と `120-million-yen` をこの共通入口へ集約する。
    #>
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Token,
        [int]$Start = -1
    )
    $whole=[string]$Text; $marker=[string]$Token
    $at=$Start
    if($at -lt 0 -and -not [string]::IsNullOrEmpty($marker)){$at=$whole.IndexOf($marker,[StringComparison]::Ordinal)}
    if($at -lt 0){return [pscustomobject]@{Scale=[decimal]1;ScaleName='';Currency='';Before='';After='';IsCurrency=$false;Found=$false}}
    $markerLength=$(if([string]::IsNullOrEmpty($marker)){0}else{$marker.Length})
    $before=$whole.Substring([Math]::Max(0,$at-32),[Math]::Min(32,$at))
    $afterAt=$at+$markerLength
    $after=$whole.Substring($afterAt,[Math]::Min(64,$whole.Length-$afterAt))
    $join='[\s\-\u2010-\u2015]*'
    $scaleName='';[decimal]$scale=1
    $scaleMatch=$null
    # 「k yen」「k units」も日本語の文中へ差し込まれる（「18万6千台」→「186 k units」）。
    # ここの \b も日本語との間に境界を作らないので、英数字が続かないことで判定する。
    if($after -match ('(?i)^\s*\)?'+$join+'(?<scale>trillion|billion|million|thousand|oku|k(?=\s*(?:yen|units?)(?![A-Za-z0-9])))\b')){$scaleMatch=$Matches['scale']}
    # 単位変換は日本語の文の中へ oku を差し込む（「1兆3,150億円」→「13,150 oku」）。
    # \b は「oku」と日本語の間に境界を作らないので 433行では拾えない。
    # 以前はここで「です・でした・句読点」を列挙していたが、「となりました」
    # 「に達しました」などが漏れ、その行は確認済みにできなかった。
    # 活用を列挙し切ることはできないので、「後ろが英数字でなければ単位」と規則にする。
    elseif($after -match ('(?i)^\s*\)?'+$join+'(?<scale>oku)(?![A-Za-z0-9])')){$scaleMatch=$Matches['scale']}
    elseif($after -match ('^\s*\)?'+$join+'(?<scale>兆|億|百万|万|千|百)')){$scaleMatch=$Matches['scale']}
    if($null -ne $scaleMatch){
        $scaleName=[string]$scaleMatch
        switch -Regex ($scaleName.ToLowerInvariant()) {
            '^(trillion|兆)$' {$scale=[decimal]1000000000000;break}
            '^billion$' {$scale=[decimal]1000000000;break}
            '^(million|百万)$' {$scale=[decimal]1000000;break}
            '^oku$|^億$' {$scale=[decimal]100000000;break}
            '^万$' {$scale=[decimal]10000;break}
            '^(thousand|k|千)$' {$scale=[decimal]1000;break}
            '^百$' {$scale=[decimal]100;break}
        }
    }
    $currency=''
    $scalePart='(?:(?:trillion|billion|million|thousand|oku|k|兆|億|百万|万|千|百)'+$join+')?'
    if($after -match ('(?i)^\s*\)?'+$join+$scalePart+'yen\b') -or $after -match ('^\s*\)?'+$join+$scalePart+'円')){$currency='yen'}
    elseif($after -match ('(?i)^\s*\)?'+$join+$scalePart+'dollars?\b') -or $after -match ('^\s*\)?'+$join+$scalePart+'ドル')){$currency='dollar'}
    elseif($after -match ('(?i)^\s*\)?'+$join+$scalePart+'euros?\b') -or $after -match ('^\s*\)?'+$join+$scalePart+'ユーロ')){$currency='euro'}
    elseif($after -match ('(?i)^\s*\)?'+$join+$scalePart+'pounds?\b') -or $after -match ('^\s*\)?'+$join+$scalePart+'ポンド')){$currency='pound'}
    elseif($before -match '(?i)(?:\bJPY|¥)\s*$'){$currency='yen'}
    elseif($before -match '(?i)(?:\bUSD|\$)\s*$'){$currency='dollar'}
    elseif($before -match '(?i)(?:\bEUR|€)\s*$'){$currency='euro'}
    elseif($before -match '(?i)(?:\bGBP|£)\s*$'){$currency='pound'}
    elseif($scaleName -ieq 'oku'){$currency='yen'}
    return [pscustomobject]@{Scale=$scale;ScaleName=$scaleName;Currency=$currency;Before=$before;After=$after;IsCurrency=(-not [string]::IsNullOrEmpty($currency));Found=$true}
}

function ConvertTo-YakuNumericRestoreValue {
    <#
      漢数字や英語綴り数は、そのまま異言語の文へ戻すと「一億 yen」や
      「two billion円」になる。値を変えず、言語に依存しないアラビア数字へ
      正規化してから復元する。
    #>
    param(
        [AllowNull()][string]$Text,
        [ValidateSet('auto','to_en','to_jp')][string]$Direction='auto',
        [AllowNull()][string]$Context,
        [AllowNull()][string]$Token,
        [AllowNull()][string]$SourceContext
    )
    $raw = [string]$Text
    [decimal]$value=0; $parsed=$false; $includesScale=$false
    if ($raw -match '[〇零一二三四五六七八九十百千万億兆壱弐参拾]') {
        $jp = ConvertFrom-YakuJapaneseNumberText -Text $raw
        if ([bool]$jp.Ok) {
            $value=[decimal]$jp.Value;$parsed=$true;$includesScale=$true
        }
    }
    if (-not $parsed -and $raw -match '(?i)\b(?:a|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)\b') {
        $en = ConvertFrom-YakuEnglishNumberText -Text $raw
        if ([bool]$en.Ok) {$value=[decimal]$en.Value;$parsed=$true;$includesScale=$true}
    }
    if(-not $parsed){
        $normalized=(ConvertTo-YakuMaskNormalizedText -Text $raw).Replace(',','')
        $parsed=[decimal]::TryParse($normalized,[Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)
    }
    if($parsed){
        $sourceDescriptor=Get-YakuNumericContextDescriptor -Text $SourceContext -Token $Token
        [decimal]$absolute=$value
        if(-not $includesScale -and $null -ne $sourceDescriptor){$absolute=$value*[decimal]$sourceDescriptor.Scale}
        $targetDescriptor=Get-YakuNumericContextDescriptor -Text $Context -Token $Token
        $canRenderFinancial=(($includesScale -and -not [bool]$sourceDescriptor.Found -and [bool]$targetDescriptor.IsCurrency) -or
            ([bool]$sourceDescriptor.IsCurrency -and [bool]$targetDescriptor.IsCurrency))
        if($Direction -eq 'to_en' -and $canRenderFinancial -and $null -ne $targetDescriptor){
            if([decimal]$targetDescriptor.Scale -gt 1){return (ConvertTo-YakuInvariantNumberText -Value ($absolute/[decimal]$targetDescriptor.Scale) -UseGrouping)}
            if([bool]$targetDescriptor.IsCurrency -and [Math]::Abs($absolute) -ge [decimal]1000000){
                $scaleName='million';[decimal]$scale=[decimal]1000000
                if([Math]::Abs($absolute) -ge [decimal]1000000000000){$scaleName='trillion';$scale=[decimal]1000000000000}
                elseif([Math]::Abs($absolute) -ge [decimal]1000000000){$scaleName='billion';$scale=[decimal]1000000000}
                return ((ConvertTo-YakuInvariantNumberText -Value ($absolute/$scale))+' '+$scaleName)
            }
        }
        if($includesScale){return (ConvertTo-YakuInvariantNumberText -Value $value -UseGrouping)}
    }
    return $raw
}

function ConvertTo-YakuNaturalEnglishNotation {
    <# 数値を伏せたためモデルから見えなかった「四半期・年度・時刻」の役割を、
       復元後に原文へ拘束してローカル整形する。金額・数量の値は変えない。 #>
    param([AllowNull()][string]$SourceText,[AllowNull()][string]$Translation)
    $result=[string]$Translation
    if([string]::IsNullOrWhiteSpace($result)){return $result}
    $normalizedSource=ConvertTo-YakuMaskNormalizedText -Text ([string]$SourceText)
    foreach($match in [regex]::Matches($normalizedSource,'第\s*(?<quarter>[1-4])\s*四半期')){
        $quarter=[string]$match.Groups['quarter'].Value
        $pattern='(?i)\b(?:the\s+)?'+[regex]::Escape($quarter)+'(?:st|nd|rd|th)?\s+quarter\b'
        $result=[regex]::Replace($result,$pattern,('Q'+$quarter))
    }
    foreach($match in [regex]::Matches($normalizedSource,'(?<year>\d{4})\s*年度')){
        $year=[string]$match.Groups['year'].Value
        $escapedYear=[regex]::Escape($year)
        $yearFirst='(?i)\b(?:the\s+)?'+$escapedYear+'\s+(?:fiscal\s+year|fiscal-year)\b'
        $fiscalFirst='(?i)\bfiscal\s+year\s+'+$escapedYear+'\b'
        $result=[regex]::Replace($result,$yearFirst,('FY'+$year),1)
        $result=[regex]::Replace($result,$fiscalFirst,('FY'+$year),1)
    }
    foreach($match in [regex]::Matches($normalizedSource,'(?:(?<meridiem>午前|午後)\s*)?(?<hour>[01]?\d|2[0-3])\s*時(?:\s*(?<minute>[0-5]?\d)\s*分)?')){
        $hour=[int]$match.Groups['hour'].Value
        $minute=if($match.Groups['minute'].Success){[int]$match.Groups['minute'].Value}else{0}
        $meridiem=[string]$match.Groups['meridiem'].Value
        $suffix=if($meridiem -eq '午後'){'p.m.'}elseif($meridiem -eq '午前'){'a.m.'}elseif($hour -lt 12){'a.m.'}else{'p.m.'}
        $hour12=$hour%12;if($hour12 -eq 0){$hour12=12}
        $natural=('{0}:{1:00} {2}' -f $hour12,$minute,$suffix)
        $minutePattern=if($minute -eq 0){'0{1,2}'}else{[regex]::Escape([string]$minute)}
        $hourPattern=if($hour12 -ne $hour){'(?:'+[regex]::Escape([string]$hour)+'|'+[regex]::Escape([string]$hour12)+')'}else{[regex]::Escape([string]$hour)}
        $marker='(?:a\.?m\.?|p\.?m\.?|hours?|o''clock)'
        $end='(?=\s|[.,;:!?)\]]|$)'
        # まず、コロンまたは午前・午後などにより時刻と分かる候補を探す。
        # 同じ15が「15 points」「15 oku」として先に出ても、その数量を触らない。
        $colonPattern='(?i)(?<prefix>\b(?:at|by)\s+)'+$hourPattern+'(?:(?::|\.)\s*'+$minutePattern+')(?:(?:\s*'+$marker+')){0,2}'+$end
        $markedPattern='(?i)(?<prefix>\b(?:at|by)\s+)'+$hourPattern+'(?:(?::|\.)\s*'+$minutePattern+')?(?:(?:\s*'+$marker+')){1,2}'+$end
        $before=$result
        $result=[regex]::Replace($result,$colonPattern,{param($m)([string]$m.Groups['prefix'].Value+$natural)},1)
        if($result -eq $before){$result=[regex]::Replace($result,$markedPattern,{param($m)([string]$m.Groups['prefix'].Value+$natural)},1)}
        if($result -eq $before){
            # 裸の「by 15」は tomorrow/today 等が直後にある期限表現だけを許す。
            # 文末や数量単位の前は曖昧なので、誤変換するより人の確認へ残す。
            $barePattern='(?i)(?<prefix>\b(?:at|by)\s+)'+$hourPattern+'(?=\s+(?:today|tomorrow|tonight|this\s+(?:morning|afternoon|evening)|at\s+the\s+latest)\b)'
            $result=[regex]::Replace($result,$barePattern,{param($m)([string]$m.Groups['prefix'].Value+$natural)},1)
        }
    }
    return $result
}

function Convert-YakuNumericUnits {
    param([AllowNull()][string]$Text, [string]$Location='unknown')
    $result = [string]$Text
    $tokens = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $num = '(?:[\d０-９][\d０-９,，\.．]*|[xXｘＸ]{2,})'
    $normalizeNumber = { param($v)
        $text = [string]$v
        $full = '０１２３４５６７８９，．ｘＸ'
        $half = '0123456789,.xX'
        for ($i = 0; $i -lt $full.Length; $i++) { $text = $text.Replace([string]$full[$i], [string]$half[$i]) }
        return $text
    }
    $addToken = { param($t) if (-not [string]::IsNullOrWhiteSpace($t)) { $tokens.Add([string]$t) | Out-Null }; return [string]$t }
    $warn = { param($m) $warnings.Add([string]$m) | Out-Null; try { Write-YakuLog "Numeric unit preprocessing warning. location=$Location $m" 'WARN' } catch {} }
    $parse = { param($v) $normalized = & $normalizeNumber $v; $d=[decimal]0; $ok=[decimal]::TryParse($normalized.Replace(',',''), [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$d); return @($ok,$d) }

    # Ranges share the unit: 10〜20億円 -> 10 oku〜20 oku.
    $result = [regex]::Replace($result, "(?<a>$num)\s*(?<sep>[〜~～])\s*(?<b>$num)\s*億円", { param($m) & $addToken ((& $normalizeNumber $m.Groups['a'].Value) + ' oku') | Out-Null; & $addToken ((& $normalizeNumber $m.Groups['b'].Value) + ' oku') | Out-Null; return ((& $normalizeNumber $m.Groups['a'].Value) + ' oku' + [string]$m.Groups['sep'].Value + (& $normalizeNumber $m.Groups['b'].Value) + ' oku') })
    # Compound trillion + oku.
    $result = [regex]::Replace($result, "(?<t>$num)\s*兆\s*(?<o>$num)\s*億円", { param($m)
        if ((& $normalizeNumber $m.Groups['t'].Value) -match '^[xX]') { & $warn "masked compound trillion amount left unchanged: $($m.Value)"; return $m.Value }
        $a=&$parse $m.Groups['t'].Value; $b=&$parse $m.Groups['o'].Value
        if (-not $a[0] -or -not $b[0]) { return $m.Value }
        $token=(ConvertTo-YakuInvariantNumberText -Value (([decimal]$a[1]*10000)+[decimal]$b[1]) -UseGrouping)+' oku'; return (&$addToken $token)
    })
    $result = [regex]::Replace($result, "(?<n>$num)\s*兆円", { param($m)
        if ((& $normalizeNumber $m.Groups['n'].Value) -match '^[xX]') { & $warn "masked trillion amount left unchanged: $($m.Value)"; return $m.Value }
        $a=&$parse $m.Groups['n'].Value; if (-not $a[0]) { return $m.Value }
        $token=(ConvertTo-YakuInvariantNumberText -Value ([decimal]$a[1]*10000) -UseGrouping)+' oku'; return (&$addToken $token)
    })
    # 億 + 万 の複合。兆+億 と同じ理由で、単独の規則より先に畳む必要がある。
    # 畳まないと 億 が日本語のまま英文へ残り、モデルが "1 oku 20,000 k yen" のように訳す。
    $result = [regex]::Replace($result, "(?<o>$num)\s*億\s*(?<m>$num)\s*千万円", { param($m)
        if ((& $normalizeNumber $m.Groups['o'].Value) -match '^[xX]' -or (& $normalizeNumber $m.Groups['m'].Value) -match '^[xX]') { & $warn "masked compound oku amount left unchanged: $($m.Value)"; return $m.Value }
        $a=&$parse $m.Groups['o'].Value; $b=&$parse $m.Groups['m'].Value
        if (-not $a[0] -or -not $b[0]) { return $m.Value }
        $token=(ConvertTo-YakuInvariantNumberText -Value ([decimal]$a[1]+([decimal]$b[1]*1000/10000)) -UseGrouping)+' oku'; return (&$addToken $token)
    })
    $result = [regex]::Replace($result, "(?<o>$num)\s*億\s*(?<m>$num)\s*万円", { param($m)
        if ((& $normalizeNumber $m.Groups['o'].Value) -match '^[xX]' -or (& $normalizeNumber $m.Groups['m'].Value) -match '^[xX]') { & $warn "masked compound oku amount left unchanged: $($m.Value)"; return $m.Value }
        $a=&$parse $m.Groups['o'].Value; $b=&$parse $m.Groups['m'].Value
        if (-not $a[0] -or -not $b[0]) { return $m.Value }
        $token=(ConvertTo-YakuInvariantNumberText -Value ([decimal]$a[1]+([decimal]$b[1]/10000)) -UseGrouping)+' oku'; return (&$addToken $token)
    })
    $result = [regex]::Replace($result, "(?<n>$num)\s*億円", { param($m) $token=(& $normalizeNumber $m.Groups['n'].Value)+' oku'; return (&$addToken $token) })
    # 万 + 千 の複合。18万6千台 が「18万6 k units」になり、残った 万 を
    # モデルが ten thousand と訳していた（2026-08-05 実機）。
    # 千を伴う形を先に、素の端数を後に当てる。順番を逆にすると端数側が先に食う。
    foreach ($spec in @(@{Unit='台'; Out='k units'}, @{Unit='円'; Out='k yen'})) {
        $unit=[string]$spec.Unit; $out=[string]$spec.Out
        foreach ($tail in @(@{Sep='千'; Div=[decimal]1}, @{Sep=''; Div=[decimal]1000})) {
            $sep=[string]$tail.Sep; $div=[decimal]$tail.Div
            $result = [regex]::Replace($result, "(?<a>$num)\s*万\s*(?<b>$num)\s*$sep$unit", { param($m)
                if ((& $normalizeNumber $m.Groups['a'].Value) -match '^[xX]' -or (& $normalizeNumber $m.Groups['b'].Value) -match '^[xX]') { & $warn "masked compound scaled unit left unchanged: $($m.Value)"; return $m.Value }
                $a=&$parse $m.Groups['a'].Value; $b=&$parse $m.Groups['b'].Value
                if (-not $a[0] -or -not $b[0]) { return $m.Value }
                $token=(ConvertTo-YakuInvariantNumberText -Value (([decimal]$a[1]*10)+([decimal]$b[1]/$div)) -UseGrouping)+" $out"; return (&$addToken $token)
            })
        }
    }
    foreach ($spec in @(@{Unit='万台'; Out='k units'; Factor=10}, @{Unit='千台'; Out='k units'; Factor=1}, @{Unit='万円'; Out='k yen'; Factor=10}, @{Unit='千円'; Out='k yen'; Factor=1})) {
        $unit=[string]$spec.Unit; $out=[string]$spec.Out; $factor=[decimal]$spec.Factor
        $result = [regex]::Replace($result, "(?<n>$num)\s*$unit", { param($m)
            if ((& $normalizeNumber $m.Groups['n'].Value) -match '^[xX]' -and $factor -ne 1) { & $warn "masked scaled unit left unchanged: $($m.Value)"; return $m.Value }
            if ((& $normalizeNumber $m.Groups['n'].Value) -match '^[xX]') { $token=(& $normalizeNumber $m.Groups['n'].Value)+" $out"; return (&$addToken $token) }
            $a=&$parse $m.Groups['n'].Value; if (-not $a[0]) { return $m.Value }
            $v=[decimal]$a[1]*$factor
            if ($unit -eq '万円' -and $v -ne [decimal]::Truncate($v)) { & $warn "non-integral man-yen conversion left unchanged: $($m.Value)"; return $m.Value }
            $token=(ConvertTo-YakuInvariantNumberText -Value $v -UseGrouping)+" $out"; return (&$addToken $token)
        })
    }
    try { Write-YakuLog "Numeric unit preprocessing. location=$Location generated=$($tokens.Count) warnings=$($warnings.Count)" 'INFO' } catch {}
    return [pscustomobject]@{ Text=$result; Tokens=@($tokens.ToArray()); Warnings=@($warnings.ToArray()) }
}

# ---------------------------------------------------------------------------
# V91.60 数値マスキング
#
# 未公開財務数値を含む文書はそのままでは「極秘」だが、社内規程上、数値を
# 完全にマスクすれば「機密」としてCopilotへ送信できる。そのため大きさだけを
# プレースホルダー[[N1]]へ置き換えて送信し、受信後に復元する。
# 符号(+ / ▲ / △ / 括弧)と単位(oku / k yen / % など)は外に残す。依頼元の許可により
# 符号は保持してよく、単位を残すとモデルが金額・数量・比率を区別できるため。
#
# 適用位置は Convert-YakuNumericUnits の直後。単位変換は桁の換算(兆→oku)を伴うため、
# 先にマスクすると換算できなくなる。
# ---------------------------------------------------------------------------

function Test-YakuNumericMaskingEnabled {
    # 常時有効。機密要件は利用者が個別に無効化できるべきではない。
    # 回帰テスト用の抜け道としてのみ環境変数を見る。設定画面には出さない。
    return (-not ([string]$env:YAKULINGO_NUMERIC_MASKING -eq 'off'))
}

function Assert-YakuNumericPromptProtected {
    <#
      legacyの追加検査。canonical package は各可変fieldを再scanして全数字を
      fail-closedにする。ここで1桁値まで最終prompt全体とsubstring比較すると、
      固定指示の番号や [[N8]] のtoken番号を元値8と誤認するため、3桁以上の
      値だけを補助的に検査する。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Prompt,
        [AllowNull()][hashtable]$MaskMap
    )
    if (-not (Test-YakuNumericMaskingEnabled)) { throw 'EXTERNAL_SEND_NUMERIC_PROTECTION_DISABLED' }
    foreach ($token in @($(if ($null -ne $MaskMap) { $MaskMap.Keys }))) {
        $rawValue = [string]$MaskMap[$token]
        if ([string]::IsNullOrWhiteSpace($rawValue)) { continue }
        $rawDigits = [regex]::Replace((ConvertTo-YakuMaskNormalizedText -Text $rawValue), '\D', '')
        if ($rawDigits.Length -lt 3) { continue }
        $pattern = '(?<![0-9A-Za-z])' + [regex]::Escape($rawValue) + '(?![0-9A-Za-z])'
        if ([regex]::IsMatch($Prompt, $pattern)) { throw 'EXTERNAL_SEND_UNMASKED_NUMERIC_VALUE' }
    }
    return $true
}

function Protect-YakuPromptField {
    <# 最終promptへ差し込む補助欄の数値を、原文と同じmapへ衝突なく統合する。 #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$NumericMap,
        [Parameter(Mandatory=$true)][string]$Location,
        [switch]$AllowExistingTokens
    )
    if ([string]::IsNullOrEmpty([string]$Text)) { return '' }
    $protected = [string]$Text
    $numericResult = New-YakuNumericMaskMap -Text $protected -Root $Root -Direction $Direction -Location $Location -AllowExistingTokens:$AllowExistingTokens
    $protected = [string]$numericResult.Text
    $numericOffset = [int]$NumericMap.Count
    # N1→N2 を先にすると元の N2 も後続置換の対象になる。同じ金額tokenへ
    # 潰れないよう、元tokenの番号を使って後ろから一度だけ振り替える。
    foreach ($token in @($numericResult.Map.Keys | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) } -Descending)) {
        $tokenIndex = [int]([regex]::Match([string]$token, '\d+').Value)
        $newToken = '[[N' + [string]($numericOffset + $tokenIndex) + ']]'
        $protected = $protected.Replace([string]$token, $newToken)
        $NumericMap[$newToken] = [string]$numericResult.Map[$token]
    }
    return $protected
}

function ConvertTo-YakuMaskNormalizedText {
    # 分類は全角を半角へ正規化した写像の上で行う。1文字→1文字の対応なので
    # 位置は原文と一致し、求めた範囲をそのまま原文へ適用できる。
    # 置換そのものは原文に対して行い、非マスク部分の字形は変えない。
    param([AllowNull()][string]$Text)
    $s = [string]$Text
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $full = '０１２３４５６７８９，．／％＋－ｘＸ　ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ'
    $half = "0123456789,./%+-xX ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $i = $full.IndexOf($ch)
        if ($i -ge 0) { $null = $sb.Append($half[$i]) } else { $null = $sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-YakuNumericMaskExemptPatterns {
    # 外部送信する利用者入力の数字には例外を設けない。年度、日付、四半期、
    # 電話番号、証券コード、バージョン、用語中の数字もすべて token 化する。
    # 非数値部分（FY、区切り記号、会社名等）はそのまま残るため、翻訳文脈は
    # 維持できる。既存 token の二重マスクだけは ProtectedSpans 側で防ぐ。
    return @()
}

function Test-YakuMaskSpanCovered {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Spans,
        [int]$Start,
        [int]$End
    )
    foreach ($sp in $Spans) {
        # 数値の一部でも保護範囲に重なっていれば、その数値はマスクしない。
        if ($Start -lt [int]$sp.End -and $End -gt [int]$sp.Start) { return $true }
    }
    return $false
}

function Get-YakuNumericMaskProtectedSpans {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Root,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [switch]$AllowExistingTokens
    )
    $spans = New-Object System.Collections.Generic.List[object]
    $normalized = ConvertTo-YakuMaskNormalizedText -Text $Text
    if ([string]::IsNullOrEmpty($normalized)) { return @() }

    # ヘルパー関数へ List を渡すと、空のときにパラメータ束縛が失敗する。直接追加する。
    # V91.60(決定事項#7): 手動マスク【…非開示】は廃止した。数値は自動でマスクされる
    # ため手で伏せる必要がなく、二重の仕組みを残すと保護範囲の判断が分かれる。
    # 【】は強調・見出しの括弧として扱い、中の数値は通常どおりマスクする。
    # 内部で保護済みと明示された[[N1]]だけは保護する。生入力の予約記法は
    # 迂回に使えないよう、その中の数字も通常どおりマスクする。
    if ($AllowExistingTokens) {
        foreach ($m in [regex]::Matches([string]$Text, '\[\[N\d+\]\]')) {
            if ($m.Length -gt 0) { $spans.Add([pscustomobject]@{ Start = [int]$m.Index; End = [int]($m.Index + $m.Length) }) | Out-Null }
        }
    }
    # 用語集一致も例外にしない。例えば CX-50 は CX-[[N1]] とし、数字以外は
    # 保ったまま復元する。用語の完全一致より外部送信境界を優先する。
    return @($spans.ToArray())
}

function New-YakuNumericMaskMap {
    <#
      数値の「大きさ」だけを[[N1]]へ置き換える。符号と単位は外に残す。
      戻り値: Text=マスク済み / Map=@{'[[N1]]'='72'} / MaskedCount / KeptCount
    #>
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Root,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$Location = 'unknown',
        [switch]$AllowExistingTokens
    )
    $source = [string]$Text
    $map = @{}
    if ([string]::IsNullOrEmpty($source) -or -not (Test-YakuNumericMaskingEnabled)) {
        return [pscustomobject]@{ Text = $source; Map = $map; MaskedCount = 0; KeptCount = 0 }
    }

    $protected = @(Get-YakuNumericMaskProtectedSpans -Text $source -Root $Root -Direction $Direction -AllowExistingTokens:$AllowExistingTokens)
    $normalized = ConvertTo-YakuMaskNormalizedText -Text $source

    $targets = New-Object System.Collections.Generic.List[object]
    $targetKeys = @{}
    $kept = 0
    $targetStats = @{ Kept = 0 }
    $addTarget = {
        param([int]$Start, [int]$Length, [bool]$Force = $false)
        if ($Length -le 0) { return }
        if (-not $Force -and (Test-YakuMaskSpanCovered -Spans $protected -Start $Start -End ($Start + $Length))) { $targetStats.Kept++; return }
        $key = [string]$Start + ':' + [string]$Length
        if ($targetKeys.ContainsKey($key)) { return }
        $targetKeys[$key] = $true
        $targets.Add([pscustomobject]@{ Start = $Start; Length = $Length }) | Out-Null
    }
    foreach ($m in [regex]::Matches($normalized, '\d[\d,]*(?:\.\d+)?')) {
        & $addTarget $m.Index $m.Length
    }
    # 漢数字も数値である。これを拾わないと「一億二千万円」のような未公開値が
    # map空のまま外部へ出る。曖昧な「一方」「十分」は、金額・数量の単位が
    # 直後にある場合だけ対象にして通常の文章を壊さない。
    foreach ($m in [regex]::Matches($normalized, '(?<![\]0-9〇零一二三四五六七八九十百千万億兆壱弐参拾])[〇零一二三四五六七八九十百千万億兆壱弐参拾]+(?=(?:円|元|台|株|件|人|ポイント|％|%))')) {
        # Arabic値や既存tokenの直後に残る「億」「百」等は単位であり、二重に
        # token化しない。一方「十円」「百億円」は数量そのものなので伏せる。
        if ($m.Length -eq 1 -and $m.Value -match '^[十百千万億兆]$') {
            $prefixStart = [Math]::Max(0, $m.Index - 24)
            $prefix = $normalized.Substring($prefixStart, $m.Index - $prefixStart)
            if ($prefix -match '(?:\d|\[\[N\d+\]\])[^。．.!?！？]*$') { continue }
        }
        # 「億円」などの単位が用語集にあっても、数量本体を保護対象から外さない。
        & $addTarget $m.Index $m.Length $true
    }
    # 英語の綴り数も同じ扱いにする。hundred 以上の位を含む並び、または
    # 通貨・数量単位の直前にある並びだけを対象にし、ordinary “one way” 等は除く。
    $cardinalWord = '(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)'
    $numberWord = '(?:' + $cardinalWord + '|hundred|thousand|million|billion|trillion)'
    $wordOptions = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    # scale語単独（Arabic値の後ろにある “1,111 million” の million）は
    # 単位なので伏せない。必ず a/cardinal から始まる綴り数だけを対象にする。
    $magnitudePattern = '\b(?:a|' + $cardinalWord + ')(?:[\s-]+(?:and[\s-]+)?' + $numberWord + ')*\b'
    foreach ($m in [regex]::Matches($normalized, $magnitudePattern, $wordOptions)) {
        if ($m.Value -notmatch '(?i)\b(?:hundred|thousand|million|billion|trillion)\b') { continue }
        & $addTarget $m.Index $m.Length $true
    }
    $unitPattern = $magnitudePattern + '(?=\s+(?:yen|dollars?|euros?|pounds?|units?|shares?|vehicles?|cars?|points?|percent|percentage)\b)'
    foreach ($m in [regex]::Matches($normalized, $unitPattern, $wordOptions)) {
        & $addTarget $m.Index $m.Length $true
    }
    $kept = [int]$targetStats.Kept
    if ($targets.Count -eq 0) {
        try { Write-YakuLog "Numeric masking. location=$Location masked=0 kept=$kept" 'INFO' } catch {}
        return [pscustomobject]@{ Text = $source; Map = $map; MaskedCount = 0; KeptCount = $kept }
    }

    # 番号は本文の出現順。置換は後ろから行い、前方の位置をずらさない。
    $ordered = @($targets.ToArray() | Sort-Object Start)
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $map['[[N' + ($i + 1) + ']]'] = $source.Substring([int]$ordered[$i].Start, [int]$ordered[$i].Length)
    }
    $result = $source
    for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
        $token = '[[N' + ($i + 1) + ']]'
        $result = $result.Remove([int]$ordered[$i].Start, [int]$ordered[$i].Length).Insert([int]$ordered[$i].Start, $token)
    }
    try { Write-YakuLog "Numeric masking. location=$Location masked=$($ordered.Count) kept=$kept" 'INFO' } catch {}
    return [pscustomobject]@{ Text = $result; Map = $map; MaskedCount = [int]$ordered.Count; KeptCount = [int]$kept }
}

function Get-YakuNumericMaskTokens {
    param([AllowNull()][string]$Text)
    return @([regex]::Matches([string]$Text, '\[\[N\d+\]\]') | ForEach-Object { [string]$_.Value })
}

function Restore-YakuNumericMask {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][hashtable]$Map,
        [ValidateSet('auto','to_en','to_jp')][string]$Direction='auto',
        [AllowNull()][string]$SourceText
    )
    $result = [string]$Text
    if ([string]::IsNullOrEmpty($result) -or $null -eq $Map -or $Map.Count -eq 0) { return $result }
    # 番号の大きい順に置換する。[[N1]]が[[N10]]の一部を壊さないため。
    foreach ($token in @($Map.Keys | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) } -Descending)) {
        $replacement=ConvertTo-YakuNumericRestoreValue -Text ([string]$Map[$token]) -Direction $Direction -Context $result -Token ([string]$token) -SourceContext $SourceText
        $result = $result.Replace([string]$token, $replacement)
    }
    return $result
}

function Get-YakuFiscalPeriodMaskTokens {
    <#
      会計期を指すマスクトークンを集める。

      英語では「2027年3月期 第1四半期」が "the first quarter of the fiscal year
      ending March 2027" のように語順が変わる。これは訳として正しいので、
      順序の比較から外す。

      年度・年月期・四半期の書き方は資料ごとに揺れるため、ここ1箇所に集める。
      以前は年度だけを見る実装が Translation.ps1 と CatProject.ps1 に別々にあり、
      「2027年3月期」を両方とも取りこぼしていた。
    #>
    param([AllowNull()][string]$MaskedSource)
    $tokens = @{}
    if ([string]::IsNullOrEmpty($MaskedSource)) { return $tokens }
    $patterns = @(
        # 2027年度第1四半期
        '(?<a>\[\[N\d+\]\])\s*年度\s*第\s*(?<b>\[\[N\d+\]\])\s*四半期',
        # 2027年3月期 第1四半期 / 2027年3月期
        '(?<a>\[\[N\d+\]\])\s*年\s*(?<b>\[\[N\d+\]\])\s*月期(?:\s*第\s*(?<c>\[\[N\d+\]\])\s*四半期)?',
        # 2027年度
        '(?<a>\[\[N\d+\]\])\s*年度'
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches([string]$MaskedSource, $pattern)) {
            foreach ($name in @('a','b','c')) {
                $value = [string]$match.Groups[$name].Value
                if (-not [string]::IsNullOrWhiteSpace($value)) { $tokens[$value] = $true }
            }
        }
    }
    return $tokens
}

function Test-YakuNumericMaskIntegrity {
    <#
      復元の安全のため、プレースホルダーが過不足なく1対1であることを確認する。
      数値整合監査は「必要数以上あるか」しか見ないため、これを別に通す。
    #>
    param(
        [AllowNull()][string]$MaskedSource,
        [AllowNull()][string]$Translated,
        [string]$Location = 'unknown'
    )
    $sourceCounts = @{}
    $targetCounts = @{}
    foreach ($t in (Get-YakuNumericMaskTokens -Text $MaskedSource)) { if (-not $sourceCounts.ContainsKey($t)) { $sourceCounts[$t] = 0 }; $sourceCounts[$t]++ }
    foreach ($t in (Get-YakuNumericMaskTokens -Text $Translated))   { if (-not $targetCounts.ContainsKey($t)) { $targetCounts[$t] = 0 }; $targetCounts[$t]++ }

    $missing = New-Object System.Collections.Generic.List[string]
    $duplicated = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($sourceCounts.Keys)) {
        $actual = if ($targetCounts.ContainsKey($key)) { [int]$targetCounts[$key] } else { 0 }
        if ($actual -lt [int]$sourceCounts[$key]) { $missing.Add($key) | Out-Null }
        elseif ($actual -gt [int]$sourceCounts[$key]) { $duplicated.Add($key) | Out-Null }
    }
    foreach ($key in @($targetCounts.Keys)) {
        if (-not $sourceCounts.ContainsKey($key)) { $unexpected.Add($key) | Out-Null }
    }
    # 順序の食い違いを見る。ただしこれは復元の安全とは関係がない。
    # Restore-YakuNumericMask はトークン名で置換するので（861行）、[[N2]] は
    # 文中のどこにあっても N2 の実値に戻る。順序が変わっても実値は取り違えない。
    #
    # ここで見ているのは「モデルが勘定と数値の対応を取り違えたかもしれない」という
    # 意味の疑いである。日英では語順が変わるのが自然で（「138億円から10.1%増」→
    # "up 10.1% from 138 oku"）、トークン列だけでは自然な語順変更と取り違えを区別できない。
    # したがって OutOfOrder は戻り値として返すだけにし、Ok には含めない。
    # 疑わしい行を止めるのは確認時のQC（numeric-value-order-mismatch）の役目で、
    # そちらは訳文を残したまま確定を止めるので、人が見て直せる。
    $sourceSequence=@(Get-YakuNumericMaskTokens -Text $MaskedSource)
    $targetSequence=@(Get-YakuNumericMaskTokens -Text $Translated)
    $outOfOrder=$false
    if($sourceSequence.Count -eq $targetSequence.Count -and $sourceSequence.Count -gt 1){
        # 英語では「2027年度第1四半期」が "FY2027 ... in Q1" のように
        # 文頭と文末へ分かれる。原文で年度・四半期に直接結び付いたtokenだけを
        # 順序比較から外し、売上高・利益など残りの数値順序は厳密に維持する。
        $fiscalTokens=Get-YakuFiscalPeriodMaskTokens -MaskedSource $MaskedSource
        $sourceComparable=@($sourceSequence | Where-Object { -not $fiscalTokens.ContainsKey([string]$_) })
        $targetComparable=@($targetSequence | Where-Object { -not $fiscalTokens.ContainsKey([string]$_) })
        if($sourceComparable.Count -ne $targetComparable.Count){$outOfOrder=$true}
        else{
            for($i=0;$i -lt $sourceComparable.Count;$i++){
                if([string]$sourceComparable[$i] -ne [string]$targetComparable[$i]){$outOfOrder=$true;break}
            }
        }
    }
    # Ok は「実値へ戻して安全か」だけを表す。順序は含めない（上のコメント）。
    $ok = ($missing.Count -eq 0 -and $duplicated.Count -eq 0 -and $unexpected.Count -eq 0)
    $detail = "placeholders source=$($sourceCounts.Count) missing=$($missing.Count) duplicated=$($duplicated.Count) unexpected=$($unexpected.Count) outOfOrder=$outOfOrder"
    if (-not $ok) {
        $parts = New-Object System.Collections.Generic.List[string]
        if ($missing.Count -gt 0)    { $parts.Add('missing=' + (@($missing.ToArray()) -join ',')) | Out-Null }
        if ($duplicated.Count -gt 0) { $parts.Add('duplicated=' + (@($duplicated.ToArray()) -join ',')) | Out-Null }
        if ($unexpected.Count -gt 0) { $parts.Add('unexpected=' + (@($unexpected.ToArray()) -join ',')) | Out-Null }
        if ($outOfOrder) { $parts.Add('order=' + ($targetSequence -join ',')) | Out-Null }
        $detail = $detail + ' [' + (@($parts.ToArray()) -join '; ') + ']'
    }
    try { Write-YakuLog "Numeric mask integrity. location=$Location $detail" $(if ($ok) { 'DEBUG' } else { 'WARN' }) } catch {}
    return [pscustomobject]@{
        Ok = [bool]$ok; Detail = $detail
        Missing = @($missing.ToArray()); Duplicated = @($duplicated.ToArray()); Unexpected = @($unexpected.ToArray()); OutOfOrder=[bool]$outOfOrder
    }
}

function Restore-YakuMaskedTranslationOptions {
    <#
      V91.60: 各訳文の[[N1]]を実値へ戻す。戻す前に1対1を確かめ、崩れていれば
      警告を立てる。無言で数値が消えるのを避けるのがここの目的。
      復元自体は失敗させない。一部が欠けても残りは戻す。

      段階6(決定事項#3): BRIEF は原文の20〜30%へ圧縮するため、数値そのものが
      落ちることがある。省略が正当か事故かを区別できないので、BRIEF の欠落は
      再試行の理由にせず確認警告に留める(再試行の判断は呼び出し側)。
      欠落した数値は訳文へ挿入しない。省略された文脈へ数値だけを戻すと
      誤読を招くため。代わりに平文つきで警告表示する(決定事項#12)。

      応答が原文に無い番号を作った場合は、対応する実値が存在しない。
      [[N9]]のまま画面へ出すより取り除くほうが安全なので削除する。
    #>
    param(
        [AllowNull()][object[]]$Options,
        [AllowNull()][string]$MaskedSource,
        [AllowNull()][hashtable]$Map,
        [AllowNull()]$Warnings,
        [string]$Location = 'text',
        [ValidateSet('auto','to_en','to_jp')][string]$Direction='auto'
    )
    if ($null -eq $Options) { return @() }
    # V91.61（2026-08-06）: 修正の依頼はマスク後の訳文を送り返してもらう。
    # 画面に出ているのは実値に戻した訳文なので、それを送れば実値が外へ出る。
    # 戻す前の姿をここで控えておく。マスクが無いときは両者が同じになる。
    foreach ($o in @($Options)) {
        if ($null -eq $o) { continue }
        try { $o | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue ([string]$o.Translation) -Force } catch {}
    }
    $hasNumeric = ($null -ne $Map -and $Map.Count -gt 0)
    if (-not $hasNumeric) { return @($Options) }
    foreach ($option in $Options) {
        $style = [string]$option.Style
        $label = [string]$option.Label
        $translated = [string]$option.Translation
        $integrity = if ($hasNumeric) {
            Test-YakuNumericMaskIntegrity -MaskedSource $MaskedSource -Translated $translated -Location ($Location + '-' + $style)
        } else {
            [pscustomobject]@{ Ok = $true; Detail = ''; Missing = @(); Duplicated = @(); Unexpected = @() }
        }
        $restored = $translated
        if ($hasNumeric) {
            $restored = Restore-YakuNumericMask -Text $restored -Map $Map -Direction $Direction -SourceText $MaskedSource
            # 原文に無い番号は実値が無い。残すと画面へ内部トークンが出る。
            $leftover = @(Get-YakuNumericMaskTokens -Text $restored | Select-Object -Unique)
            if ($leftover.Count -gt 0) {
                foreach ($token in $leftover) { $restored = $restored.Replace([string]$token, '') }
                $restored = [regex]::Replace($restored, '[ \t]{2,}', ' ')
            }
        }
        $option.Translation = $restored

        if ([bool]$integrity.Ok) { continue }
        try {
            if ($null -eq $Warnings -or -not (Get-Command Add-YakuWarning -ErrorAction SilentlyContinue)) { continue }
            $details = @{ Detail=[string]$integrity.Detail; Missing=@($integrity.Missing); Duplicated=@($integrity.Duplicated); Unexpected=@($integrity.Unexpected) }
            if ($style -eq 'brief' -and @($integrity.Missing).Count -gt 0 -and @($integrity.Duplicated).Count -eq 0 -and @($integrity.Unexpected).Count -eq 0) {
                # 平文つきで示す。どの数値が落ちたか分からないと確認しようがない。
                # この平文は画面表示のみ。ログ・診断ファイルへは出さない(§8)。
                $dropped = @(@($integrity.Missing) | ForEach-Object {
                    $tok = [string]$_
                    $value = if ($Map.ContainsKey($tok)) { [string]$Map[$tok] } else { '' }
                    if ([string]::IsNullOrEmpty($value)) { $tok } else { "$tok（$value）" }
                })
                # 数値が落ちたものは「短い訳」ではなく、事実が欠けた訳である。
                # 社内資料であっても致命的なので、意図した省略かを利用者に
                # 判断させない（利用者の判断 2026-08-08）。使えない印を付けて、
                # 画面でそれと分かるようにする。
                try { $option | Add-Member -NotePropertyName 'NumbersDropped' -NotePropertyValue $true -Force } catch {}
                try { $option | Add-Member -NotePropertyName 'DroppedNumbers' -NotePropertyValue (@($dropped) -join '、') -Force } catch {}
                Add-YakuWarning -Warnings $Warnings -Category 'numeric-placeholder-dropped-brief' -Location $label -Details $details -Message ("短い訳から次の数値が抜けています: " + (@($dropped) -join '、') + "。この訳は使わず、長いほうをお使いください。")
            } else {
                Add-YakuWarning -Warnings $Warnings -Category 'numeric-placeholder-unresolved' -Location $label -Details $details -Message "数値プレースホルダーの個数が原文と一致しません。該当箇所の数値を必ずご確認ください。($([string]$integrity.Detail))"
            }
        } catch {}
    }
    return @($Options)
}

function Get-YakuNumericAuditExpectations {
    param([AllowNull()][string]$SourceText)
    $items = New-Object System.Collections.Generic.List[object]
    # V91.60: マスク後は数値が[[N1]]に置き換わるため、監査対象へ加える。
    # これにより既存の数値整合監査・補正・再試行の仕組みがそのまま使える。
    $pattern = '(?<![0-9])(?<num>\[\[N\d+\]\]|[0-9][0-9,]*(?:\.[0-9]+)?|[xX]{2,})\s+(?<unit>oku|k units|k yen)'
    foreach ($m in [regex]::Matches([string]$SourceText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $token = (([string]$m.Groups['num'].Value) + ' ' + ([string]$m.Groups['unit'].Value).ToLowerInvariant())
        $plain = ([string]$m.Groups['num'].Value).Replace(',','')
        $scaleToken = ''
        $v=[decimal]0
        if ([decimal]::TryParse($plain,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$v)) {
            $scaleToken=(ConvertTo-YakuInvariantNumberText -Value ($v/10))+' '+([string]$m.Groups['unit'].Value).ToLowerInvariant()
        }
        $items.Add([pscustomobject]@{ Source=[string]$m.Value; Expected=$token; ScaleCandidate=$scaleToken }) | Out-Null
    }
    foreach ($m in [regex]::Matches([string]$SourceText, '(?<![0-9])(?<num>\[\[N\d+\]\]|[0-9][0-9,]*(?:\.[0-9]+)?)\s*[%％]')) {
        $token=([string]$m.Groups['num'].Value)+'%'; $items.Add([pscustomobject]@{ Source=[string]$m.Value; Expected=$token; ScaleCandidate='' }) | Out-Null
    }
    return @($items.ToArray())
}

function Get-YakuTokenOccurrenceCount {
    param([AllowNull()][string]$Text,[Parameter(Mandatory=$true)][string]$Token)
    $normalized=([string]$Text).Replace('，',',').Replace('％','%')
    $numPart=$Token; $unitPart=''
    $sep=$Token.IndexOf(' ')
    if ($sep -gt 0) { $numPart=$Token.Substring(0,$sep); $unitPart=$Token.Substring($sep+1) }
    elseif ($Token.EndsWith('%')) { $numPart=$Token.Substring(0,$Token.Length-1); $unitPart='%' }
    $pattern='\(?\s*'+[regex]::Escape($numPart)+'\s*\)?'
    if ($unitPart -eq '%') { $pattern += '\s*%' }
    elseif ($unitPart -ne '') { $pattern += '\s+'+[regex]::Escape($unitPart).Replace('\ ','\s+') }
    return [regex]::Matches($normalized,$pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
}

function Test-YakuNumericIntegrity {
    param([Parameter(Mandatory=$true)][string]$SourceText,[AllowNull()][string]$TranslatedText,[Parameter(Mandatory=$true)][string]$Location)
    $expectedItems=@(Get-YakuNumericAuditExpectations -SourceText $SourceText)
    $expectedCounts=@{}; foreach($i in $expectedItems){ if(-not $expectedCounts.ContainsKey($i.Expected)){$expectedCounts[$i.Expected]=0};$expectedCounts[$i.Expected]++ }
    $mismatches=New-Object System.Collections.Generic.List[object];$scaleErrors=0
    foreach($key in $expectedCounts.Keys){
        $actual=Get-YakuTokenOccurrenceCount -Text $TranslatedText -Token $key; $need=[int]$expectedCounts[$key]
        if($actual -ge $need){continue}
        $sample=@($expectedItems|Where-Object{$_.Expected -eq $key}|Select-Object -First 1)[0]
        $scaleCount=0;if(-not [string]::IsNullOrWhiteSpace([string]$sample.ScaleCandidate)){$scaleCount=Get-YakuTokenOccurrenceCount -Text $TranslatedText -Token ([string]$sample.ScaleCandidate)}
        $isScale=($scaleCount -gt 0);if($isScale){$scaleErrors+=($need-$actual)}
        $mismatches.Add([pscustomobject]@{Source=$sample.Source;Expected=$key;Observed=$(if($isScale){$sample.ScaleCandidate}else{'<missing>'});MissingCount=($need-$actual);ScaleError=$isScale})|Out-Null
    }
    $checked=$expectedItems.Count;$missing=(@($mismatches.ToArray()|ForEach-Object{$_.MissingCount}|Measure-Object -Sum).Sum);if($null-eq$missing){$missing=0};$matched=$checked-[int]$missing
    $detail=(@($mismatches.ToArray()|ForEach-Object{"$($_.Source) -> expected $($_.Expected), observed $($_.Observed)"})-join '; ');$ok=($mismatches.Count-eq0)
    try{Write-YakuLog "Numeric integrity audit. location=$Location checked=$checked matched=$matched scaleErrors=$scaleErrors corrected=0 mismatches=$($mismatches.Count)" $(if($ok){'INFO'}else{'WARN'})}catch{}
    return [pscustomobject]@{Ok=$ok;Checked=$checked;Matched=$matched;ScaleErrors=$scaleErrors;Mismatches=@($mismatches.ToArray());Detail=$detail}
}

function New-YakuNumericCorrectionInstruction {
    <#
      V91.60: 再送プロンプトへ平文の数値を載せない。
      本文をマスクしても、この指示文から素の数値が出れば対策が無効になる。
      プレースホルダーを含む項目だけを指示にし、それ以外は落とす。
      落とすのは非マスク数値（年号・用語集の保護範囲など）であり、
      いずれも機密ではないが、経路として平文を通さないことを優先する。
    #>
    param([Parameter(Mandatory=$true)]$Audit)
    $all=@($Audit.Mismatches)
    $items=@($all|Where-Object{ [string]$_.Expected -match '\[\[N\d+\]\]' })
    $dropped=$all.Count-$items.Count
    if($dropped -gt 0){ try{ Write-YakuLog "Numeric correction instruction. dropped=$dropped (plain numbers withheld from the prompt)" 'INFO' }catch{} }
    if($items.Count -eq 0){ return '' }
    $lines=@($items|ForEach-Object{
        if([bool]$_.ScaleError){"- $($_.Source): reproduce the token $($_.Expected) exactly; do not output $($_.Observed)."}
        else{"- $($_.Source): include the token $($_.Expected) exactly as written; it is currently missing from the translation."}
    })
    return ("NUMERIC CORRECTION (mandatory): Correct only the following numeric token mismatches while preserving all other wording:`n"+($lines-join "`n"))
}

function Repair-YakuTextResponsePostParse {
    param(
        [Parameter(Mandatory=$true)][string]$SourceText,
        [Parameter(Mandatory=$true)][object[]]$Options,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    if ($Direction -ne 'to_en') { return @($Options) }
    foreach ($option in $Options) {
        if ([string]$option.Style -notin @('full','brief')) { continue }
        $repair = Repair-YakuNumberedHeadingSequence -SourceText $SourceText -TranslatedText ([string]$option.Translation) -Style ([string]$option.Style)
        if ([bool]$repair.Restored) { $option.Translation = [string]$repair.Text }

    }
    return @($Options)
}

function Parse-YakuV25PlainTranslationResponse {
    param(
        [Parameter(Mandatory=$true)][string]$Raw,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId,
        [AllowNull()]$Warnings,
        [ValidateSet('full','brief')][string]$Mode = 'full'
    )
    $contract = Test-YakuTextResponseContract -Text $Raw -Direction $Direction -RequestId $RequestId -Mode $Mode
    if (-not [bool]$contract.Valid) { throw "$($contract.ErrorCode): $($contract.Message)" }
    $clean = [string]$contract.NormalizedText
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = Normalize-YakuCopilotPlainResponse -Raw $Raw -RequestId $RequestId }
    if (-not [string]::IsNullOrWhiteSpace([string]$contract.WarningCode)) {
        try {
            if ($null -ne $Warnings -and (Get-Command Add-YakuWarning -ErrorAction SilentlyContinue)) {
                Add-YakuWarning -Warnings $Warnings -Category 'response-contract-recovery' -Location 'Copilot' -Details @{ Code=[string]$contract.WarningCode } -Message ([string]$contract.WarningMessage)
            }
        } catch {}
    }
    $items = @()
    if ($Direction -eq 'to_en') {
        $wanted = @(Get-YakuTextRequiredLabels -Direction $Direction -Mode $Mode)
        $fullText = if ($wanted -contains 'FULL_TEXT') { Get-YakuLabeledResponseField -Text $clean -Label 'FULL_TEXT' } else { '' }
        $briefText = if ($wanted -contains 'BRIEF_TEXT') { Get-YakuLabeledResponseField -Text $clean -Label 'BRIEF_TEXT' } else { '' }
        $fullText = ConvertFrom-YakuTextFullWidthAngle -Text $fullText
        $briefText = ConvertFrom-YakuTextFullWidthAngle -Text $briefText
        if (![string]::IsNullOrWhiteSpace($fullText) -and $fullText.Trim() -ne '...') {
            $items += [pscustomobject]@{ Style='full'; Label='そのまま'; Translation=$fullText; Explanation='' }
        }
        if (![string]::IsNullOrWhiteSpace($briefText) -and $briefText.Trim() -ne '...') {
            $items += [pscustomobject]@{ Style='brief'; Label='短く'; Translation=$briefText; Explanation='' }
        }
    } else {
        $jpText = Get-YakuLabeledResponseField -Text $clean -Label 'JAPANESE_TEXT'
        if (![string]::IsNullOrWhiteSpace($jpText) -and $jpText.Trim() -ne '...') {
            $items += [pscustomobject]@{ Style='jp'; Label='JAPANESE'; Translation=$jpText; Explanation='' }
        }
    }
    return $items
}

function Parse-YakuTextTranslationResponse {
    param(
        [Parameter(Mandatory=$true)][string]$Raw,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId,
        [AllowNull()]$Warnings,
        [ValidateSet('full','brief')][string]$Mode = 'full'
    )
    $options = @(Parse-YakuV25PlainTranslationResponse -Raw $Raw -Direction $Direction -RequestId $RequestId -Warnings $Warnings -Mode $Mode)
    $expected = @(Get-YakuTextRequiredLabels -Direction $Direction -Mode $Mode).Count
    if ($options.Count -ne $expected) { throw 'RESPONSE_FIELDS_MISSING: 必須の翻訳フィールドが不足しています。' }
    return $options
}

function Get-YakuTextStructureCounts {
    param([AllowNull()][string]$Text)
    $lines = @(([string]$Text).Replace("`r`n","`n").Replace("`r","`n") -split "`n")
    $headings = @($lines | Where-Object { ([string]$_) -match '^\s*[＜<【].*[＞>】]\s*$' }).Count
    $bullets = @($lines | Where-Object { ([string]$_) -match '^\s*[■●◆]' }).Count
    return [pscustomobject]@{ Headings = [int]$headings; Bullets = [int]$bullets }
}

function Test-YakuTextStructureIntegrity {
    param(
        [Parameter(Mandatory=$true)][string]$SourceText,
        [Parameter(Mandatory=$true)][string]$FullText,
        [Parameter(Mandatory=$true)][string]$BriefText
    )
    $src = Get-YakuTextStructureCounts -Text $SourceText
    if ($src.Headings -lt 1 -and $src.Bullets -lt 2) {
        return [pscustomobject]@{ Ok = $true; Skipped = $true; Detail = '' }
    }
    $full = Get-YakuTextStructureCounts -Text $FullText
    $brief = Get-YakuTextStructureCounts -Text $BriefText
    $ok = ($full.Headings -eq $src.Headings) -and ($brief.Headings -eq $src.Headings) -and
          ($full.Bullets -eq $src.Bullets) -and ($brief.Bullets -eq $src.Bullets)
    $detail = "headings src=$($src.Headings) full=$($full.Headings) brief=$($brief.Headings); bullets src=$($src.Bullets) full=$($full.Bullets) brief=$($brief.Bullets)"
    return [pscustomobject]@{ Ok = [bool]$ok; Skipped = $false; Detail = [string]$detail }
}

function Get-YakuTranslationAttemptErrorCode {
    param([AllowNull()][string]$Message)
    $text = [string]$Message
    if ($text -match '^([A-Z][A-Z0-9_]+)\s*:') { return [string]$Matches[1] }
    if ($text -match 'Reason=verified-send-button' -or $text -match 'Copilotへの送信を確認できません') { return 'COPILOT_SEND_NOT_CONFIRMED' }
    if ($text -match 'COPILOT_SILENT_START_TIMEOUT') { return 'COPILOT_SILENT_START_TIMEOUT' }
    return 'TRANSLATION_ATTEMPT_FAILED'
}

function Get-YakuUnicodeCodePointSequence {
    param([AllowNull()][string]$Text, [int]$Limit = 16)
    $items = New-Object System.Collections.Generic.List[string]
    $value = [string]$Text
    for ($i = 0; $i -lt $value.Length -and $items.Count -lt $Limit; $i++) {
        $codePoint = [int][char]$value[$i]
        if ([char]::IsHighSurrogate($value[$i]) -and ($i + 1) -lt $value.Length -and [char]::IsLowSurrogate($value[$i + 1])) {
            $codePoint = [char]::ConvertToUtf32($value[$i], $value[$i + 1])
            $i++
        }
        $formatted = if ($codePoint -gt 0xFFFF) { 'U+{0:X6}' -f $codePoint } else { 'U+{0:X4}' -f $codePoint }
        $items.Add($formatted) | Out-Null
    }
    return (($items.ToArray()) -join ' ')
}

function Get-YakuResponseCharacterSketch {
    param([AllowNull()][string]$Text, [int]$Limit = 64)
    $value = [string]$Text
    $out = New-Object System.Text.StringBuilder
    $count = [Math]::Min($Limit, $value.Length)
    for ($i = 0; $i -lt $count; $i++) {
        $ch = $value[$i]
        $code = [int][char]$ch
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A) -or ($code -ge 0x61 -and $code -le 0x7A)) { $null = $out.Append('A'); continue }
        if (($code -ge 0x3040 -and $code -le 0x30FF) -or ($code -ge 0x3400 -and $code -le 0x9FFF) -or ($code -ge 0xFF66 -and $code -le 0xFF9F)) { $null = $out.Append('J'); continue }
        if ($ch -eq "`n" -or $ch -eq "`r") { $null = $out.Append('↵'); continue }
        if ([char]::IsWhiteSpace($ch)) { $null = $out.Append('W'); continue }
        if ([char]::IsLetterOrDigit($ch)) { $null = $out.Append('L'); continue }
        $null = $out.Append($ch)
    }
    return $out.ToString()
}

function Get-YakuTextResponseStructureMetadata {
    param([AllowNull()][string]$Raw, [Parameter(Mandatory=$true)][string]$RequestId)
    $text = [string]$Raw
    $marker = 'YAKULINGO_END:' + $RequestId
    $markerEsc = [regex]::Escape($marker)
    $positions = [ordered]@{}
    foreach ($label in @('FULL_TEXT','BRIEF_TEXT','JAPANESE_TEXT','YAKULINGO_END')) {
        $positions[$label.ToLowerInvariant()] = $text.IndexOf($label, [System.StringComparison]::OrdinalIgnoreCase)
    }
    $markerPresent = [regex]::IsMatch($text, $markerEsc, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $markerStandalone = [regex]::IsMatch($text, '(?im)^\s*(?:\*\*)?' + $markerEsc + '(?:\*\*)?\s*$')
    return [ordered]@{
        leading_code_points = Get-YakuUnicodeCodePointSequence -Text $text -Limit 16
        leading_character_sketch = Get-YakuResponseCharacterSketch -Text $text -Limit 64
        label_indexes = $positions
        end_marker_present = [bool]$markerPresent
        end_marker_standalone_line = [bool]$markerStandalone
        end_marker_inline = [bool]($markerPresent -and -not $markerStandalone)
        has_markdown_bold = $text.Contains('**')
        has_markdown_heading = [regex]::IsMatch($text, '(?m)^\s*#{1,6}\s')
        has_code_fence = $text.Contains('```')
        has_fullwidth_colon = $text.Contains('：')
        has_stopped_ui_text = ($text -match 'この会話を停止しました|conversation (?:was )?stopped|stopped this conversation')
    }
}

function Write-YakuTextResponseContractDiagnostic {
    param(
        [AllowNull()][string]$Raw,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId,
        [Parameter(Mandatory=$true)][string]$ErrorCode,
        [AllowNull()][string]$ErrorMessage,
        [ValidateSet('full','brief')][string]$Mode = 'full',
        [int]$Attempt = 0
    )
    $path = ''
    try {
        $path = Join-Path (Get-YakuSubDir 'logs') ("copilot-text-response-diagnostic-" + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.jsonl')
        $rawText = [string]$Raw
        $normalized = Normalize-YakuCopilotPlainResponse -Raw $rawText -RequestId $RequestId
        $signatureText = $normalized.Replace($RequestId, '<request-id>')
        $structure = Get-YakuTextResponseStructureMetadata -Raw $rawText -RequestId $RequestId
        $requiredLabels = @(Get-YakuTextRequiredLabels -Direction $Direction -Mode $Mode)
        $structure['required_labels'] = @($requiredLabels)
        # clean_head contains response text, so retain it only under the same
        # explicit full-text diagnostics gate as raw/normalized responses.
        if (Test-YakuFullTextDiagnosticsEnabled) {
            $structure['clean_head'] = if ($normalized.Length -gt 160) { $normalized.Substring(0, 160) } else { $normalized }
        }
        $entry = [ordered]@{
            time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            event = 'text-response-contract-rejected'
            direction = $Direction
            request_id = $RequestId
            attempt = [int]$Attempt
            error_code = $ErrorCode
            error_message = [string]$ErrorMessage
            response_length = [int]$rawText.Length
            response_sha256 = (Get-YakuTextSha256 -Text $rawText)
            response_signature_sha256 = (Get-YakuTextSha256 -Text $signatureText)
            structure = $structure
            label_counts = [ordered]@{
                full_text = [regex]::Matches($normalized, '(?im)^\s*(?:\*\*)?FULL_TEXT(?:\*\*)?\s*:').Count
                brief_text = [regex]::Matches($normalized, '(?im)^\s*(?:\*\*)?BRIEF_TEXT(?:\*\*)?\s*:').Count
                japanese_text = [regex]::Matches($normalized, '(?im)^\s*(?:\*\*)?JAPANESE_TEXT(?:\*\*)?\s*:').Count
                end_marker = [regex]::Matches($normalized, '(?im)^\s*(?:\*\*)?YAKULINGO_END:').Count
            }
        }
        if (Test-YakuFullTextDiagnosticsEnabled) {
            $entry['raw_response'] = $rawText
            $entry['normalized_response'] = $normalized
        }
        Add-Content -LiteralPath $path -Value ($entry | ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
        Write-YakuLog "Text response contract metadata. attempt=$Attempt errorCode=$ErrorCode structure=$(ConvertTo-YakuCompactJson $structure)" 'WARN'
        Write-YakuLog "Text response contract diagnostic saved. attempt=$Attempt errorCode=$ErrorCode responseLength=$($rawText.Length) path=$path" 'INFO'
    } catch {
        try { Write-YakuLog "Text response contract diagnostic write failed. attempt=$Attempt error=$($_.Exception.Message)" 'WARN' } catch {}
        $path = ''
    }
    return $path
}

function Set-YakuTranslationProgress {
    param(
        [AllowNull()]$ProgressState,
        [string]$Mode = 'working',
        [string]$Label = 'Translating',
        [int]$Progress = 0,
        [string]$Detail = '',
        [AllowNull()][string]$Phase = $null
    )
    if ($null -eq $ProgressState) { return }
    try {
        $pct = [Math]::Max(0, [Math]::Min(100, $Progress))
        $currentPct = 0
        try { $currentPct = [int]$ProgressState['progress'] } catch { $currentPct = 0 }
        $pct = [Math]::Max($currentPct, $pct)
        $ProgressState['mode'] = $Mode
        $ProgressState['label'] = $Label
        $ProgressState['class'] = if ($Mode -eq 'done') { 'ok' } elseif ($Mode -eq 'error') { 'warn' } else { 'warn' }
        $ProgressState['progress'] = [int]$pct
        $ProgressState['detail'] = $Detail
        if ($null -ne $Phase) { $ProgressState['phase'] = $Phase }
        $ProgressState['updated_at'] = (Get-Date).ToString('s')
    } catch {}
}

function Get-YakuDirectionLabel {
    param([Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction)
    if ($Direction -eq 'to_en') { return '日本語 → 英語' }
    return '英語/その他 → 日本語'
}

function Get-YakuMaxCharsPerBatch {
    param([Parameter(Mandatory=$true)]$Settings)
    $max = 0
    try { $max = [int]$Settings.max_chars_per_batch } catch { $max = 0 }
    if ($max -lt 400) { return 0 }
    return $max
}

function Split-YakuHardChunk {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][int]$MaxChars
    )
    $chunks = New-Object System.Collections.Generic.List[string]
    $remaining = [string]$Text
    while ($remaining.Length -gt $MaxChars) {
        $cut = $MaxChars
        $window = $remaining.Substring(0, $MaxChars)
        $sentence = [regex]::Match($window, '(?s)^.*[。．.!?！？]\s*')
        if ($sentence.Success -and $sentence.Value.Length -ge [int]($MaxChars * 0.45)) {
            $cut = $sentence.Value.Length
        } else {
            $lastSpace = $window.LastIndexOf(' ')
            if ($lastSpace -ge [int]($MaxChars * 0.55)) { $cut = $lastSpace + 1 }
        }
        $chunks.Add($remaining.Substring(0, $cut)) | Out-Null
        $remaining = $remaining.Substring($cut)
    }
    if ($remaining.Length -gt 0) { $chunks.Add($remaining) | Out-Null }
    return @($chunks.ToArray())
}

function Split-YakuLongSegment {
    param(
        [Parameter(Mandatory=$true)][string]$Segment,
        [Parameter(Mandatory=$true)][int]$MaxChars
    )
    if ($Segment.Length -le $MaxChars) { return @($Segment) }
    $chunks = New-Object System.Collections.Generic.List[string]
    $parts = [regex]::Split($Segment, "(`n)")
    $buf = ''
    foreach ($part in $parts) {
        if ($part.Length -gt $MaxChars) {
            if ($buf.Length -gt 0) { $chunks.Add($buf) | Out-Null; $buf = '' }
            foreach ($hard in (Split-YakuHardChunk -Text $part -MaxChars $MaxChars)) {
                if ($hard.Length -gt 0) { $chunks.Add($hard) | Out-Null }
            }
            continue
        }
        if (($buf.Length + $part.Length) -gt $MaxChars -and $buf.Length -gt 0) {
            $chunks.Add($buf) | Out-Null
            $buf = $part
        } else {
            $buf += $part
        }
    }
    if ($buf.Length -gt 0) { $chunks.Add($buf) | Out-Null }
    return @($chunks.ToArray())
}

function Split-YakuTextBatches {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][int]$MaxChars
    )
    $normalized = ([string]$Text).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($MaxChars -le 0 -or $normalized.Length -le $MaxChars) {
        return @([pscustomobject]@{ Index=1; Total=1; Text=$normalized; CharCount=$normalized.Length })
    }

    $chunks = New-Object System.Collections.Generic.List[string]
    $parts = [regex]::Split($normalized, "(`n{2,})")
    $buf = ''
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $segment = [string]$parts[$i]
        if (($i + 1) -lt $parts.Count) { $segment += [string]$parts[$i + 1] }
        if ($segment.Length -eq 0) { continue }

        if ($segment.Length -gt $MaxChars) {
            if ($buf.Length -gt 0) { $chunks.Add($buf) | Out-Null; $buf = '' }
            foreach ($piece in (Split-YakuLongSegment -Segment $segment -MaxChars $MaxChars)) {
                if ($piece.Length -gt 0) { $chunks.Add($piece) | Out-Null }
            }
            continue
        }

        if (($buf.Length + $segment.Length) -gt $MaxChars -and $buf.Length -gt 0) {
            $chunks.Add($buf) | Out-Null
            $buf = $segment
        } else {
            $buf += $segment
        }
    }
    if ($buf.Length -gt 0) { $chunks.Add($buf) | Out-Null }

    $total = $chunks.Count
    $batches = @()
    for ($i = 0; $i -lt $total; $i++) {
        $t = [string]$chunks[$i]
        $batches += [pscustomobject]@{ Index=($i + 1); Total=$total; Text=$t; CharCount=$t.Length }
    }
    return $batches
}

function Get-YakuStyleReferenceFromOptions {
    param(
        [AllowNull()][object[]]$Options,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    $preferred = if ($Direction -eq 'to_en') { 'full' } else { 'jp' }
    $opt = @($Options | Where-Object { $_.Style -eq $preferred } | Select-Object -First 1)
    if ($opt.Count -eq 0) { $opt = @($Options | Select-Object -First 1) }
    if ($opt.Count -eq 0) { return '' }
    $text = [string]$opt[0].Translation
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $lines = @($text.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 5)
    $ref = ($lines -join "`n").Trim()
    if ($ref.Length -gt 900) { $ref = $ref.Substring(0, 900).Trim() }
    return $ref
}

function Merge-YakuBatchTranslationResults {
    param(
        [Parameter(Mandatory=$true)][object[]]$BatchResults,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    $merged = @()
    if ($Direction -eq 'to_en') {
        foreach ($spec in @(@{Style='full';Label='そのまま'})) {
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($br in $BatchResults) {
                $hit = @($br.Options | Where-Object { $_.Style -eq $spec.Style } | Select-Object -First 1)
                if ($hit.Count -gt 0 -and ![string]::IsNullOrWhiteSpace([string]$hit[0].Translation)) {
                    $parts.Add(([string]$hit[0].Translation).Trim()) | Out-Null
                }
            }
            if ($parts.Count -gt 0) {
                $merged += [pscustomobject]@{ Style=$spec.Style; Label=$spec.Label; Translation=(($parts.ToArray()) -join "`n`n"); Explanation='' }
            }
        }
    } else {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($br in $BatchResults) {
            $hit = @($br.Options | Where-Object { $_.Style -eq 'jp' } | Select-Object -First 1)
            if ($hit.Count -gt 0 -and ![string]::IsNullOrWhiteSpace([string]$hit[0].Translation)) {
                $parts.Add(([string]$hit[0].Translation).Trim()) | Out-Null
            }
        }
        if ($parts.Count -gt 0) {
            $merged += [pscustomobject]@{ Style='jp'; Label='JAPANESE'; Translation=(($parts.ToArray()) -join "`n`n"); Explanation='' }
        }
    }
    $expected = 1
    if ($merged.Count -ne $expected) { throw 'RESPONSE_BATCH_INCOMPLETE: バッチ結果の必須スタイルが不足しています。' }
    return $merged
}

function Invoke-YakuSingleTranslationBatch {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()][string]$StyleReference,
        [switch]$SkipFreshChatWait,
        [AllowNull()]$ProgressState,
        [AllowNull()]$Warnings,
        # V91.61 段階3: ジョブごとに1回だけ引いた文例。バッチ間で共通。
        [AllowNull()][string]$CorpusSection,
        [ValidateSet('default','none')][string]$CachePolicy = 'default',
        [ValidateSet('full','brief')][string]$Mode = 'full'
    )
    $requestId = ''
    # V91.60 段階3: 外部へ送る前に数値をマスクする。
    # バッチ分割の後にマスクするのは、分割が[[N12]]の途中を
    # 切ることを構造的に防ぐため。Split-YakuHardChunk は文境界が
    # 見つからなければ文字数で切るので、先にマスクすると壊れ得る。
    # 以降この関数の中では $sourceText(マスク後) を原文として扱う。
    # プロンプト・キャッシュキー・各監査を同じ土俵に乗せるため。
    $maskResult = New-YakuNumericMaskMap -Text $InputText -Root $Root -Direction $Direction -Location 'text'
    $sourceText = [string]$maskResult.Text
    $maskMap = $maskResult.Map
    $protectedStyleReference = Protect-YakuPromptField -Text $StyleReference -Root $Root -Direction $Direction -NumericMap $maskMap -Location 'text-style-reference'
    $protectedCorpusSection = Protect-YakuPromptField -Text $CorpusSection -Root $Root -Direction $Direction -NumericMap $maskMap -Location 'text-corpus-section'
    $protectedFields = New-Object System.Collections.Generic.List[object]
    $protectedFields.Add([pscustomobject]@{ Name='source'; OriginalText=$InputText; ProtectedText=$sourceText; NumericMaskMaps=@($maskMap) }) | Out-Null
    if (-not [string]::IsNullOrEmpty([string]$StyleReference)) {
        $protectedFields.Add([pscustomobject]@{ Name='style_reference'; OriginalText=[string]$StyleReference; ProtectedText=$protectedStyleReference; NumericMaskMaps=@($maskMap) }) | Out-Null
    }
    if (-not [string]::IsNullOrEmpty([string]$CorpusSection)) {
        $protectedFields.Add([pscustomobject]@{ Name='corpus_section'; OriginalText=[string]$CorpusSection; ProtectedText=$protectedCorpusSection; NumericMaskMaps=@($maskMap) }) | Out-Null
    }
    # Text/Quick is intentionally self-contained: it does not consult the CAT
    # terminology base, translation memory, or past examples. Terminology is
    # applied only after an explicit promotion to a CAT project.
    $glossarySw = [System.Diagnostics.Stopwatch]::StartNew()
    $glossarySw.Stop()
    $promptSw = [System.Diagnostics.Stopwatch]::StartNew()
    $promptPackage = New-YakuProtectedPromptPackage -Kind text -Root $Root -Direction $Direction -Fields @($protectedFields.ToArray()) `
        -Arguments ([pscustomobject]@{ Settings=$Settings; Mode=$Mode })
    $requestId = [string]$promptPackage.RequestId
    $built = $promptPackage.Built
    $built.Prompt = [string]$promptPackage.Prompt
    $null = Assert-YakuNumericPromptProtected -Prompt ([string]$built.Prompt) -MaskMap $maskMap
    $promptSw.Stop()
    $styleReferenceHash = if ([string]::IsNullOrEmpty([string]$StyleReference)) { '' } else { Get-YakuTextSha256 -Text ([string]$StyleReference) }
    # 文例が変われば訳文も変わる。鍵に入れないと、文例なしで作った訳文を
    # 文例ありの依頼へ返してしまう。
    $corpusHash = if ([string]::IsNullOrEmpty([string]$CorpusSection)) { '' } else { Get-YakuTextSha256 -Text ([string]$CorpusSection) }
    $cacheSw = [System.Diagnostics.Stopwatch]::StartNew()
    # マスク状態は Get-YakuTranslationContractFingerprint が持つ(§7)。
    # ここは版だけ上げ、マスクなし時代のキーと衝突しないようにする。
    $cacheKey = ''
    $cachedRaw = $null
    if ($CachePolicy -ne 'none') {
        $cacheKey = Get-YakuTranslationCacheKey -Kind 'text' -Direction $Direction -Text $sourceText -Style ('plain-v9160|' + $styleReferenceHash + '|corpus-v9161:' + $corpusHash + '|mode-v9161:' + [string]$Mode) -Root $Root -Settings $Settings
        $cachedRaw = Get-YakuTranslationCacheValue -Key $cacheKey -Settings $Settings
    }
    $cacheSw.Stop()
    Write-YakuLog "Translation preparation timings. glossary-load elapsedMs=$($glossarySw.ElapsedMilliseconds) prompt-build elapsedMs=$($promptSw.ElapsedMilliseconds) cache-lookup elapsedMs=$($cacheSw.ElapsedMilliseconds)" 'INFO'
    if ($null -ne $cachedRaw -and -not [string]::IsNullOrWhiteSpace([string]$cachedRaw)) {
        try {
            $cachedEnvelope = [string]$cachedRaw | ConvertFrom-Json
            $cachedRequestId = [string]$cachedEnvelope.request_id
            $optionsCached = @(Parse-YakuTextTranslationResponse -Raw ([string]$cachedEnvelope.raw) -Direction $Direction -RequestId $cachedRequestId -Warnings $Warnings -Mode $Mode)
            $optionsCached = @(Repair-YakuTextResponsePostParse -SourceText $sourceText -Options $optionsCached -Direction $Direction)
            if (-not ($Direction -eq 'to_jp' -and $maskMap.Count -gt 0)) {
                foreach ($cachedOption in $optionsCached) {
                    $cachedNumeric = Test-YakuNumericIntegrity -SourceText $sourceText -TranslatedText ([string]$cachedOption.Translation) -Location ("text-cache-" + [string]$cachedOption.Style)
                    if (-not [bool]$cachedNumeric.Ok -and [int]$cachedNumeric.ScaleErrors -gt 0) { throw "NUMERIC_SCALE_MISMATCH: $([string]$cachedNumeric.Detail)" }
                }
            }
            # 依頼を分けた場合、1回の応答には片方しか無い。突き合わせは2つ揃うときだけ。
            if ($Direction -eq 'to_en' -and $optionsCached.Count -ge 2) {
                $cachedIntegrity = Test-YakuTextStructureIntegrity -SourceText $sourceText -FullText ([string]$optionsCached[0].Translation) -BriefText ([string]$optionsCached[1].Translation)
                if (-not [bool]$cachedIntegrity.Ok) {
                    try { Write-YakuLog "Text response structure mismatch. attempt=cache detail=$([string]$cachedIntegrity.Detail); cache=discard" 'WARN' } catch {}
                    throw "RESPONSE_STRUCTURE_MISMATCH: $([string]$cachedIntegrity.Detail)"
                }
            }
            # V91.61: BRIEF の略語はアプリ側で当てる。プロンプトの指示は保証にならない。
            # BriefStyle.ps1 を読み込んでいない経路でも止めない。当たらなければ
            # 従来どおりモデルの出力のままになるだけで、翻訳は成立する。
            if (Get-Command Convert-YakuBriefTranslationOptions -ErrorAction SilentlyContinue) {
                $optionsCached = @(Convert-YakuBriefTranslationOptions -Options $optionsCached)
            }
            $optionsCached = @(Restore-YakuMaskedTranslationOptions -Options $optionsCached -MaskedSource $sourceText -Map $maskMap -Warnings $Warnings -Location 'text-cache' -Direction $Direction)
            return [pscustomobject]@{ Direction=$Direction; Options=$optionsCached; Raw=[string]$cachedEnvelope.raw; Prompt=$built.Prompt; CacheHit=$true; RequestId=$cachedRequestId; MaskedCount=[int]$maskResult.MaskedCount; KeptCount=[int]$maskResult.KeptCount }
        } catch {
            if ($CachePolicy -ne 'none') { try { (Get-YakuTranslationCacheStore).Remove($cacheKey) } catch {} }
        }
    }
    $maxAttempts = 2
    try { $maxAttempts = [Math]::Max(1, [Math]::Min(3, ([int]$Settings.max_retries + 1))) } catch { $maxAttempts = 2 }
    $raw = ''
    $options = @()
    $lastError = $null
    $silentStartFailures = 0
    $structureMismatchAccepted = $false
    $numericCorrectionInstruction = ''
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            $attemptFields = New-Object System.Collections.Generic.List[object]
            foreach ($field in @($protectedFields.ToArray())) { $attemptFields.Add($field) | Out-Null }
            if (-not [string]::IsNullOrWhiteSpace($numericCorrectionInstruction)) {
                $attemptFields.Add([pscustomobject]@{ Name='additional_instruction'; OriginalText=$numericCorrectionInstruction; ProtectedText=$numericCorrectionInstruction }) | Out-Null
            }
            $promptPackage = New-YakuProtectedPromptPackage -Kind text -Root $Root -Direction $Direction -Fields @($attemptFields.ToArray()) `
                -Arguments ([pscustomobject]@{ Settings=$Settings; Mode=$Mode })
            $requestId = [string]$promptPackage.RequestId
            $built = $promptPackage.Built
            $built.Prompt = [string]$promptPackage.Prompt
        }
        try {
            $raw = Invoke-YakuProtectedCopilotPrompt -Envelope $promptPackage.Envelope -Settings $Settings -SkipFreshChatWait:($SkipFreshChatWait -or $attempt -gt 1) -PreserveEndMarker -ProgressState $ProgressState -Warnings $Warnings
            $options = @(Parse-YakuTextTranslationResponse -Raw $raw -Direction $Direction -RequestId $requestId -Warnings $Warnings -Mode $Mode)
            $options = @(Repair-YakuTextResponsePostParse -SourceText $sourceText -Options $options -Direction $Direction)
            $numericFailures = New-Object System.Collections.Generic.List[object]
            # V91.60 段階4: to_jp では [[N1]] oku が [[N1]]億円 へ訳されるため、
            # 「数値+単位」トークンの照合は成立しない。プレースホルダーの
            # 過不足は Restore-YakuMaskedTranslationOptions 側で確認する。
            # マスクが無い場合(検証用に無効化したときなど)は従来どおり照合する。
            $skipNumericTokenAudit = ($Direction -eq 'to_jp' -and $maskMap.Count -gt 0)
            if (-not $skipNumericTokenAudit) {
                foreach ($option in $options) {
                    $numericAudit = Test-YakuNumericIntegrity -SourceText $sourceText -TranslatedText ([string]$option.Translation) -Location ("text-" + [string]$option.Style)
                    if (-not [bool]$numericAudit.Ok) { $numericFailures.Add($numericAudit) | Out-Null }
                }
            }
            if ($numericFailures.Count -gt 0) {
                $scaleErrTotal = 0
                foreach ($f in $numericFailures) { $scaleErrTotal += [int]$f.ScaleErrors }
                $combinedAudit = [pscustomobject]@{ Mismatches=@($numericFailures.ToArray() | ForEach-Object { $_.Mismatches }) }
                $numericDetail = (@($numericFailures.ToArray() | ForEach-Object { $_.Detail }) -join '; ')
                if ($scaleErrTotal -gt 0) {
                    $numericCorrectionInstruction = New-YakuNumericCorrectionInstruction -Audit $combinedAudit
                    if ($attempt -lt $maxAttempts) { throw "NUMERIC_SCALE_MISMATCH_RETRY: $numericDetail" }
                    throw "NUMERIC_SCALE_MISMATCH: $numericDetail"
                }
                try {
                    if ($null -ne $Warnings -and (Get-Command Add-YakuWarning -ErrorAction SilentlyContinue)) {
                        Add-YakuWarning -Warnings $Warnings -Category 'numeric-integrity' -Location 'FULL/BRIEF' -Details @{ Attempt=[int]$attempt; Detail=$numericDetail } -Message "原文の数値トークンの一部が訳文中に見つかりません。表現の統合による可能性がありますが、該当数値をご確認ください。($numericDetail)"
                    }
                } catch {}
            }
            # V91.60 段階6: FULL / JAPANESE のプレースホルダー欠落は再試行対象。
            # BRIEF は圧縮で数値ごと落ちるのが正当な場合があり区別できないため
            # 対象外とする(決定事項#3)。警告は復元時にまとめて出す。
            if ($maskMap.Count -gt 0) {
                $maskMismatchDetail = ''
                foreach ($option in $options) {
                    if ([string]$option.Style -eq 'brief') { continue }
                    $optionMask = Test-YakuNumericMaskIntegrity -MaskedSource $sourceText -Translated ([string]$option.Translation) -Location ("text-mask-" + [string]$option.Style)
                    if (-not [bool]$optionMask.Ok) { $maskMismatchDetail = ([string]$option.Label) + ': ' + [string]$optionMask.Detail; break }
                }
                if (-not [string]::IsNullOrWhiteSpace($maskMismatchDetail) -and $attempt -lt $maxAttempts) {
                    throw "RESPONSE_PLACEHOLDER_MISMATCH: numeric placeholders: $maskMismatchDetail"
                }
            }
            if ($Direction -eq 'to_en' -and $options.Count -ge 2) {
                $integrity = Test-YakuTextStructureIntegrity -SourceText $sourceText -FullText ([string]$options[0].Translation) -BriefText ([string]$options[1].Translation)
                if (-not [bool]$integrity.Ok) {
                    $integrityDetail = [string]$integrity.Detail
                    try { Write-YakuLog "Text response structure mismatch. attempt=$attempt/$maxAttempts detail=$integrityDetail" 'WARN' } catch {}
                    if ($attempt -lt $maxAttempts) {
                        throw "RESPONSE_STRUCTURE_MISMATCH: $integrityDetail"
                    }
                    $structureMismatchAccepted = $true
                    try {
                        if ($null -ne $Warnings -and (Get-Command Add-YakuWarning -ErrorAction SilentlyContinue)) {
                            Add-YakuWarning -Warnings $Warnings -Category 'structure-integrity' -Location 'FULL/BRIEF' -Details @{ Counts=$integrityDetail; Attempt=[int]$attempt; MaxAttempts=[int]$maxAttempts } -Message "原文の見出し・箇条書きの一部が訳文から欠落している可能性があります(詳細: $integrityDetail)。該当箇所をご確認ください。"
                        }
                    } catch {}
                }
            }
            $lastError = $null
            break
        } catch {
            $lastError = $_
            $errorMessage = [string]$_.Exception.Message
            $attemptErrorCode = Get-YakuTranslationAttemptErrorCode -Message $errorMessage
            # 使いすぎに見える失敗は、もう一度頼んでも同じである。
            # リトライは残りの回数を削るだけで害しかない
            # （独立評価の指摘 2026-08-08）。ここで打ち切る。
            if ((Get-Command Test-YakuCopilotLimitError -ErrorAction SilentlyContinue) -and (Test-YakuCopilotLimitError -Message $errorMessage)) {
                $used = 0
                try { $used = Get-YakuCopilotCallCount } catch { $used = 0 }
                try { Write-YakuLog "Copilot usage limit suspected. attempt=$attempt/$maxAttempts callsInWindow=$used retry=stop" 'WARN' } catch {}
                throw
            }
            if ($errorMessage -match 'COPILOT_SILENT_START_TIMEOUT') {
                $silentStartFailures++
                try { Write-YakuLog "Copilot silent start retry. attempt=$attempt/$maxAttempts silentFailures=$silentStartFailures" 'WARN' } catch {}
                if ($silentStartFailures -ge 2) { throw }
                if ($attempt -ge $maxAttempts) { $maxAttempts = [Math]::Min(4, $attempt + 1) }
            } else {
                $isContractError = ($attemptErrorCode -match '^(RESPONSE_|COPILOT_REFUSAL_OR_LOGIN)')
                if ($isContractError) {
                    $rawHash = if ([string]::IsNullOrEmpty([string]$raw)) { '' } else { try { Get-YakuTextSha256 -Text ([string]$raw) } catch { '' } }
                    $diagnosticPath = Write-YakuTextResponseContractDiagnostic -Raw $raw -Direction $Direction -RequestId $requestId -ErrorCode $attemptErrorCode -ErrorMessage $errorMessage -Mode $Mode -Attempt $attempt
                    try { Write-YakuLog "Text response contract rejected. attempt=$attempt/$maxAttempts errorCode=$attemptErrorCode responseLength=$(([string]$raw).Length) responseHash=$rawHash diagnosticPath=$diagnosticPath" 'WARN' } catch {}
                    if ($attempt -lt $maxAttempts) {
                        Set-YakuCopilotProgressPhase -ProgressState $ProgressState -Phase 'retrying' -Label "応答形式エラーのため再試行します ($attempt/$maxAttempts)" -Detail "エラーコード: $attemptErrorCode" -Progress 42
                    }
                } else {
                    try { Write-YakuLog "Text translation attempt failed. attempt=$attempt/$maxAttempts errorCode=$attemptErrorCode responseLength=$(([string]$raw).Length)" 'WARN' } catch {}
                }
            }
        }
    }
    if ($lastError) { throw $lastError }
    if (-not $structureMismatchAccepted -and $CachePolicy -ne 'none') {
        $cacheEnvelope = [ordered]@{ request_id=$requestId; raw=$raw } | ConvertTo-Json -Depth 4 -Compress
        Set-YakuTranslationCacheValue -Key $cacheKey -Value $cacheEnvelope -Settings $Settings
    }
    # キャッシュへはマスク後の raw を保存する。ディスク上に実値を
    # 残さないことにもなる。復元はその後のこの位置で行う。
    # V91.61: BRIEF の略語はアプリ側で当てる。マスク復元の前に置くのは、
    # 復元後の数字（12,340 など）を語として拾わせないため。
    if (Get-Command Convert-YakuBriefTranslationOptions -ErrorAction SilentlyContinue) {
        $options = @(Convert-YakuBriefTranslationOptions -Options $options)
    }
    $options = @(Restore-YakuMaskedTranslationOptions -Options $options -MaskedSource $sourceText -Map $maskMap -Warnings $Warnings -Location 'text' -Direction $Direction)
    return [pscustomobject]@{
        Direction = $Direction
        Options = $options
        Raw = $raw
        Prompt = $built.Prompt
        CacheHit = $false
        RequestId = $requestId
        # V91.60 §9: 何件マスクして送ったかを画面へ出すため運ぶ。件数のみ。
        # 対応表(Map)は結果オブジェクトへ載せない(§8)。
        MaskedCount = [int]$maskResult.MaskedCount
        KeptCount = [int]$maskResult.KeptCount
    }
}

function Invoke-YakuTextRevision {
    <#
      できあがった訳文に、利用者の指示を1つ当てて直す。

      なぜ翻訳と別の経路なのか:

        利用者の使い方は「一文を訳す → 目で見る → 何度か直す → 確定」である
        （利用者の説明 2026-08-06）。従来のアプリにはこの「直す」が無く、
        直したければ原文を書き換えて訳し直すしかなかった。それでは
        直していない箇所まで毎回変わるので、確定へ向かって収束しない。

        ここでは規則集を送らない。理由は New-YakuRevisePrompt に書いた。
        送るのは 原文・現訳・指示 の3つだけである。

      マスクの扱い:

        画面に出ている訳文は実値へ戻した後のものなので、そのまま送ると
        伏せた数値が外へ出る。呼び出し側にはマスク後の訳文
        （Option.MaskedTranslation）を送り返してもらい、ここではそれを
        そのまま現訳として使う。原文からは同じ手順でマスク表を作り直す。
        原文が同じなら割り当ても同じなので、対応表を持ち回らなくて済む。

      再試行はしない。指示どおりに直らなかったかどうかは人が見て決める
      ことであり、機械が判定できない。もう一度頼めばよい。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        # マスク後の現訳。実値の入った訳文を渡してはならない。
        [Parameter(Mandatory=$true)][string]$CurrentText,
        [Parameter(Mandatory=$true)][string]$Instruction,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [ValidateSet('full','brief')][string]$Style = 'full',
        [AllowNull()]$ProgressState,
        [AllowNull()]$Warnings
    )
    $requestId = ''
    # 原文から同じ手順でマスク表を作り直す。割り当ては原文だけで決まるので、
    # 翻訳したときと同じトークンになり、現訳の[[N1]]とかみ合う。
    #
    $maskResult = New-YakuNumericMaskMap -Text $InputText -Root $Root -Direction $Direction -Location 'text-revise'
    $sourceText = [string]$maskResult.Text
    $maskMap = $maskResult.Map

    # 現訳と自由入力の修正指示も最終promptの一部なので、原文と同じmapへ統合する。
    $protectedCurrentText = Protect-YakuPromptField -Text $CurrentText -Root $Root -Direction $Direction -NumericMap $maskMap -Location 'text-revise-current' -AllowExistingTokens
    $maskedInstruction = Protect-YakuPromptField -Text $Instruction -Root $Root -Direction $Direction -NumericMap $maskMap -Location 'text-revise-instruction'
    $protectedFields = @(
        [pscustomobject]@{ Name='source'; OriginalText=$InputText; ProtectedText=$sourceText; NumericMaskMaps=@($maskMap) },
        [pscustomobject]@{ Name='current'; OriginalText=$CurrentText; ProtectedText=$protectedCurrentText; NumericMaskMaps=@($maskMap) },
        [pscustomobject]@{ Name='instruction'; OriginalText=$Instruction; ProtectedText=$maskedInstruction; NumericMaskMaps=@($maskMap) }
    )
    $promptPackage = New-YakuProtectedPromptPackage -Kind revision -Root $Root -Direction $Direction -Fields $protectedFields `
        -Arguments ([pscustomobject]@{ Style=$Style })
    $requestId = [string]$promptPackage.RequestId
    $built = $promptPackage.Built
    $built.Prompt = [string]$promptPackage.Prompt
    $null = Assert-YakuNumericPromptProtected -Prompt ([string]$built.Prompt) -MaskMap $maskMap
    # 電文体（brief）は英訳のときだけ意味を持つ。和訳では Get-YakuTextRequiredLabels が
    # Mode を見ずに JAPANESE_TEXT を返すので、既定の full を渡す。
    # ここで '' を渡すと ValidateSet('full','brief') で弾かれ、和訳の作業では
    # 「短くする」も「この指示で直す」も一切使えなかった。
    $mode = if ($Direction -eq 'to_en') { $Style } else { 'full' }
    $raw = Invoke-YakuProtectedCopilotPrompt -Envelope $promptPackage.Envelope -Settings $Settings -PreserveEndMarker -ProgressState $ProgressState -Warnings $Warnings
    $options = @(Parse-YakuTextTranslationResponse -Raw $raw -Direction $Direction -RequestId $requestId -Warnings $Warnings -Mode $mode)
    if ($options.Count -eq 0) { throw 'RESPONSE_EMPTY: 修正後の訳文を取り出せませんでした。' }

    # 伏せた数値が落ちていないかを見る。直す指示で数値が消えるのは事故なので、
    # 電文体でも見る（翻訳時は圧縮で落ちうるため見送っていた）。
    if ($maskMap.Count -gt 0) {
        foreach ($option in $options) {
            $integrity = Test-YakuNumericMaskIntegrity -MaskedSource $protectedCurrentText -Translated ([string]$option.Translation) -Location ('text-revise-' + [string]$option.Style)
            if ([bool]$integrity.Ok) { continue }
            try {
                if ($null -ne $Warnings -and (Get-Command Add-YakuWarning -ErrorAction SilentlyContinue)) {
                    Add-YakuWarning -Warnings $Warnings -Category 'numeric-integrity' -Location '修正' -Details @{ Detail=[string]$integrity.Detail } -Message "修正の前後で数値の数が変わっています。指示どおりか確認してください。($([string]$integrity.Detail))"
                }
            } catch {}
        }
    }

    if (Get-Command Convert-YakuBriefTranslationOptions -ErrorAction SilentlyContinue) {
        $options = @(Convert-YakuBriefTranslationOptions -Options $options)
    }
    $options = @(Restore-YakuMaskedTranslationOptions -Options $options -MaskedSource $sourceText -Map $maskMap -Warnings $Warnings -Location 'text-revise' -Direction $Direction)
    return [pscustomobject]@{
        Direction   = $Direction
        Options     = $options
        Raw         = $raw
        Prompt      = $built.Prompt
        RequestId   = $requestId
        MaskedCount = [int]$maskResult.MaskedCount
        KeptCount   = [int]$maskResult.KeptCount
    }
}

function Invoke-YakuTextShorten {
    <#
      できあがった訳文を短くする。押されたときだけ走る。

      なぜ既定で走らせないのか。Copilot は短時間に集中して送ると弾かれる。
      毎回2本作れば使える文の数が半分になる。標準の訳で足りる場面のほうが
      多いので、要る人が押したときだけ払う（独立評価 2026-08-08、3本が
      別々の理由で同じ結論）。

      門を置く。プロンプトに「長さだけ変えろ」と書いても守られるかは
      確率的である。守らせるのはアプリ側の検査だけである
      （BriefStyle.ps1 冒頭と同じ原則）。

        - 行数が変わっていない（勝手に文を統合・分割していない）
        - 伏せた数値の過不足が無い
        - 固有名詞が落ちていない
        - 短くなっている

      どれかを破ったら短い訳は返さない。派生なので、いつでも元の訳へ
      戻れる。これは独立に訳す作りには無かった強みである。

      マスクの扱いは修正の経路と同じ。現訳はマスク後のものを受け取り、
      原文からマスク表を作り直す。画面に出ている訳文を送り返させると、
      伏せた数値が外へ出る。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        # マスク後の現訳。実値の入った訳文を渡してはならない。
        [Parameter(Mandatory=$true)][string]$MaskedCurrentText,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()]$ProgressState,
        [AllowNull()]$Warnings
    )
    $requestId = ''
    $maskResult = New-YakuNumericMaskMap -Text $InputText -Root $Root -Direction 'to_en' -Location 'text-shorten'
    $sourceText = [string]$maskResult.Text
    $maskMap = $maskResult.Map

    # 実値入りの現訳を受け取ったら、そこで止める。コメントや規約と違って、
    # 書き換えたときに必ず落ちる（独立評価の助言 2026-08-08）。
    foreach ($token in @($maskMap.Keys)) {
        $value = [string]$maskMap[[string]$token]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($MaskedCurrentText.IndexOf($value, [StringComparison]::Ordinal) -ge 0 -and $MaskedCurrentText.IndexOf([string]$token, [StringComparison]::Ordinal) -lt 0) {
            throw 'SHORTEN_UNMASKED_CURRENT: マスク前の訳文が渡されました。伏せた数値が外部へ出るため送信しません。'
        }
    }

    $protectedCurrentText = Protect-YakuPromptField -Text $MaskedCurrentText -Root $Root -Direction 'to_en' -NumericMap $maskMap -Location 'text-shorten-current' -AllowExistingTokens
    $protectedFields = @(
        [pscustomobject]@{ Name='source'; OriginalText=$InputText; ProtectedText=$sourceText; NumericMaskMaps=@($maskMap) },
        [pscustomobject]@{ Name='current'; OriginalText=$MaskedCurrentText; ProtectedText=$protectedCurrentText; NumericMaskMaps=@($maskMap) }
    )
    $promptPackage = New-YakuProtectedPromptPackage -Kind shorten -Root $Root -Direction to_en -Fields $protectedFields `
        -Arguments ([pscustomobject]@{ Settings=$Settings })
    $requestId = [string]$promptPackage.RequestId
    $built = $promptPackage.Built
    $built.Prompt = [string]$promptPackage.Prompt
    $null = Assert-YakuNumericPromptProtected -Prompt ([string]$built.Prompt) -MaskMap $maskMap
    $raw = Invoke-YakuProtectedCopilotPrompt -Envelope $promptPackage.Envelope -Settings $Settings -PreserveEndMarker -ProgressState $ProgressState -Warnings $Warnings
    $options = @(Parse-YakuTextTranslationResponse -Raw $raw -Direction 'to_en' -RequestId $requestId -Warnings $Warnings -Mode 'brief')
    if ($options.Count -eq 0) { throw 'SHORTEN_RESPONSE_EMPTY: 短くした訳文を取り出せませんでした。' }
    $shortened = [string]$options[0].Translation

    # --- 門 ---
    $rejected = Test-YakuShortenResult -MaskedCurrentText $protectedCurrentText -Shortened $shortened
    if (-not [string]::IsNullOrWhiteSpace($rejected)) {
        try { Write-YakuLog "Shorten rejected. reason=$rejected requestId=$requestId" 'WARN' } catch {}
        throw ('SHORTEN_REJECTED: ' + $rejected)
    }

    # 略語はここで当てる。モデルに選ばせない。
    if (Get-Command Convert-YakuBriefTranslationOptions -ErrorAction SilentlyContinue) {
        $options = @(Convert-YakuBriefTranslationOptions -Options $options)
    }
    $options = @(Restore-YakuMaskedTranslationOptions -Options $options -MaskedSource $sourceText -Map $maskMap -Warnings $Warnings -Location 'text-shorten' -Direction 'to_en')
    foreach ($o in $options) {
        try { $o.Style = 'brief' } catch {}
        try { $o.Label = '短め' } catch {}
    }
    return [pscustomobject]@{
        Direction   = 'to_en'
        Options     = $options
        Raw         = $raw
        Prompt      = $built.Prompt
        RequestId   = $requestId
        MaskedCount = [int]$maskResult.MaskedCount
    }
}

function Test-YakuShortenResult {
    <#
      短くした訳を受け取ってよいかを決める。

      受け取れない理由を文字列で返す。空なら通す。
      判定できることだけを見る。「良い圧縮か」は機械では決まらないので見ない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$MaskedCurrentText,
        # 空の応答も検査させる。空文字を弾く形にすると、空を弾く枝へ
        # そもそも辿り着かない（2026-08-08 に実行して気づいた）。
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Shortened
    )
    $cur = [string]$MaskedCurrentText
    $new = [string]$Shortened
    if ([string]::IsNullOrWhiteSpace($new)) { return '短くした訳文が空です。' }

    # 行数。文を勝手に統合・分割していないか。見出しや箇条書きが潰れると、
    # 貼った先のレイアウトが崩れる。
    $curLines = @(($cur -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $newLines = @(($new -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($curLines.Count -ne $newLines.Count) {
        return ('行の数が変わっています（' + [string]$curLines.Count + ' → ' + [string]$newLines.Count + '）。')
    }

    # 伏せた数値。過不足があれば事実が欠けている。短い訳ではなく壊れた訳。
    #
    # 並べ替えてから比べてはいけない。[[N1]] と [[N2]] が入れ替わっても
    # 個数は合うので通ってしまい、復元すると営業利益の欄に売上高の数字が入る。
    # 2段階にすると原文と現訳の両方を見せるので、モデルが対応を付け直す。
    # 最も危険な壊れ方であり、実際に並べ替え比較では通った（2026-08-08）。
    # 出てくる順そのものを比べる。
    $curOrder = (@(Get-YakuNumericMaskTokens -Text $cur)) -join ','
    $newOrder = (@(Get-YakuNumericMaskTokens -Text $new)) -join ','
    if ($curOrder -ne $newOrder) { return '数値が増減または入れ替わっています。' }

    # 短くなっていること。同じか長いなら、押した意味が無い。
    # 完全に同一なのは「これ以上短くできない」という正しい答えなので通す。
    if ($new.Length -gt $cur.Length) { return '短くなっていません。' }

    return ''
}

function Invoke-YakuTextTranslationRequests {
    <#
      1つの原文に対して、必要な依頼を出して訳文を揃える。

      通常翻訳は成果物を1つだけ作る。JA→EN は完全訳、EN→JA は日本語訳。
      短い英訳は、通常訳の後で利用者が「短く」を押したときだけ作る。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()][string]$StyleReference,
        [switch]$SkipFreshChatWait,
        [AllowNull()]$ProgressState,
        [AllowNull()]$Warnings,
        [AllowNull()][string]$CorpusSection,
        [ValidateSet('default','none')][string]$CachePolicy = 'default'
    )
    if ($Direction -ne 'to_en') {
        return (Invoke-YakuSingleTranslationBatch -Root $Root -InputText $InputText -Settings $Settings -Direction $Direction -StyleReference $StyleReference -SkipFreshChatWait:$SkipFreshChatWait -ProgressState $ProgressState -Warnings $Warnings -CorpusSection $CorpusSection -CachePolicy $CachePolicy)
    }

    # 1本だけ訳す。短くするのは押されたときだけ走る（Invoke-YakuTextShorten）。
    #
    # Copilot は短時間に集中して送ると弾かれる。毎回2本作れば往復が2倍になり、
    # 半分になる。標準の訳で足りる場面のほうが多いので、要る人が押したときに
    # 払う（独立評価 2026-08-08、3本が別々の理由で同じ結論に来た）。
    #
    # 短くするのを派生にしたのは、速さのためではない。原文→BRIEF を並べて
    # 頼むと圧縮が「日本語を読みながら縮める」作業になり、実測で圧縮率が
    # 用語集のカバー有無で 0.55 と 0.75 に割れていた（要件整理 §5-A）。
    # できた英文から縮めれば、この語彙依存は原理的に消える。
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $results = @(
        Invoke-YakuSingleTranslationBatch -Root $Root -InputText $InputText -Settings $Settings -Direction $Direction `
            -StyleReference $StyleReference -SkipFreshChatWait:$SkipFreshChatWait -ProgressState $ProgressState `
            -Warnings $Warnings -CorpusSection $CorpusSection -CachePolicy $CachePolicy -Mode 'full'
    )
    $sw.Stop()

    $options = New-Object System.Collections.Generic.List[object]
    $raws = New-Object System.Collections.Generic.List[string]
    $prompts = New-Object System.Collections.Generic.List[string]
    $requestIds = New-Object System.Collections.Generic.List[string]
    $cacheHits = 0
    $maskedCount = 0
    $keptCount = 0
    foreach ($r in @($results)) {
        if ($null -eq $r) { continue }
        foreach ($o in @($r.Options)) { [void]$options.Add($o) }
        [void]$raws.Add([string]$r.Raw)
        [void]$prompts.Add([string]$r.Prompt)
        [void]$requestIds.Add([string]$r.RequestId)
        if ([bool]$r.CacheHit) { $cacheHits++ }
        $maskedCount = [int]$r.MaskedCount
        $keptCount = [int]$r.KeptCount
        if ($null -ne $Warnings -and $null -ne $r.PSObject.Properties['Warnings']) {
            foreach ($w in @($r.Warnings)) { if ($null -ne $w) { try { [void]$Warnings.Add($w) } catch {} } }
        }
    }
    $index = @($results).Count
    try { Write-YakuLog "Text translation requests completed. direction=$Direction requests=$index options=$($options.Count) cacheHits=$cacheHits execution=sequential elapsedMs=$($sw.ElapsedMilliseconds)" 'INFO' } catch {}
    return [pscustomobject]@{
        Direction = $Direction
        Options = @($options.ToArray())
        # 記録と診断のため、依頼ごとの生応答を区切って残す。
        Raw = (@($raws.ToArray()) -join "`n---`n")
        Prompt = (@($prompts.ToArray()) -join "`n---`n")
        # 全ての依頼がキャッシュから返ったときだけ「命中」とする。
        CacheHit = ($cacheHits -ge $index)
        RequestId = (@($requestIds.ToArray()) -join ',')
        MaskedCount = [int]$maskedCount
        KeptCount = [int]$keptCount
    }
}


function Test-YakuTextGlossaryDiagnosticContains {
    param([AllowNull()][string]$Text, [AllowNull()][string]$Term)
    $haystack = ConvertTo-YakuGlossaryMatchKey -Value ([string]$Text)
    $needle = ConvertTo-YakuGlossaryMatchKey -Value ([string]$Term)
    if ([string]::IsNullOrWhiteSpace($haystack) -or [string]::IsNullOrWhiteSpace($needle)) { return $false }
    return ($haystack.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0)
}

function Invoke-YakuTextTranslation {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()]$ProgressState,
        [AllowNull()][string]$DirectionOverride = '',
        # Quick はその場限りの翻訳であり、過去例/TM/コーパス候補を返さない。
        [ValidateSet('display','none')][string]$ReferencePolicy = 'display',
        [ValidateSet('default','none')][string]$CachePolicy = 'default'
    )
    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return [pscustomobject]@{ Error='翻訳するテキストを入力してください。' }
    }

    $preBatchSw = [System.Diagnostics.Stopwatch]::StartNew()
    $warnings = New-Object System.Collections.Generic.List[object]
    $sectionSw = [System.Diagnostics.Stopwatch]::StartNew()
    $analysis = Get-YakuDirectionAnalysis -Text $InputText
    $manualDirection = @('to_en','to_jp') -contains $DirectionOverride
    $direction = if ($manualDirection) { $DirectionOverride } else { [string]$analysis.Direction }
    if ($manualDirection) {
        Write-YakuLog "Text translation direction selected. direction=$direction direction-source=manual" 'INFO'
    } else {
        Write-YakuLog "Text translation direction selected. direction=$direction direction-source=auto reason=$([string]$analysis.Reason) confidence=$([string]$analysis.Confidence)" 'INFO'
    }
    $directionLabel = Get-YakuDirectionLabel -Direction $direction
    $processingInput = [string]$InputText
    # V91.60 段階4: 方向によらず単位を正規化トークン(oku / k yen / k units)へ揃える。
    # 日英混在の資料では to_jp の入力にも日本語単位が現れるため、
    # プレースホルダーと単位の並びが方向によらず一定になる。
    $numericPre = Convert-YakuNumericUnits -Text $processingInput -Location ('text-' + $direction); $processingInput = [string]$numericPre.Text
    $maxChars = Get-YakuMaxCharsPerBatch -Settings $Settings
    $sectionSw.Stop(); $directionSettingsMs = $sectionSw.ElapsedMilliseconds
    $sectionSw.Restart()
    $batches = @(Split-YakuTextBatches -Text $processingInput.Trim() -MaxChars $maxChars)
    $sectionSw.Stop(); $batchingMs = $sectionSw.ElapsedMilliseconds
    $sectionSw.Restart()
    $sectionSw.Stop(); $glossaryMatchMs = $sectionSw.ElapsedMilliseconds
    $styleReferenceSw = [System.Diagnostics.Stopwatch]::StartNew()
    $initialStyleReference = ''
    $styleReferenceSw.Stop()
    # V91.61 段階3: 参考資料コーパスの文例を引く。
    #
    # ジョブごとに1回だけ。バッチごとに引くと Copilot への往復がバッチ数だけ増え、
    # 文例もバッチごとに変わって訳語が揃わなくなる。
    # 分割の前に置くのは、原文全体を見て検索語を作らせるため。
    #
    # 失敗しても Get-YakuCorpusReference は投げない。引けなければ空が返り、
    # 従来どおりの翻訳になる。コーパスは足しであって前提ではない。
    #
    # CorpusReference.ps1 が読み込まれていない経路（別ランスペース・ワーカー・
    # 部分的に読み込む回帰テスト）でも翻訳が止まらないようにする。
    # 「コーパスは足しであって前提ではない」を、依存関係の面でも守る。
    $corpusSw = [System.Diagnostics.Stopwatch]::StartNew()
    # V91.61（2026-08-06）: 簡易翻訳ではコーパスを引かない。
    #
    # 検索語を Copilot に作らせる往復が1回増えるため、その場で1つ訳したい
    # ときには重すぎる（利用者の判断 2026-08-06）。効きも弱く、用語集が
    # 有効なときはコーパスの言い回しが通らないことを実機で確かめている
    # （実機検証結果 §3-2）。
    #
    # 仕組みは消していない。腰を据えて訳す CAT 側へ移した。
    # 参照する価値があるのは、資料をまとめて仕上げるときである。
    # Experience quick/none: skip CorpusSection, Find-YakuCorpusPairsByTerms, and TM reuse.
    $corpusReference = [pscustomobject]@{ Section = ''; Terms = @(); Examples = @(); Count = 0; Reason = $(if ($ReferencePolicy -eq 'none') { 'quick-no-reuse' } else { 'text-mode-disabled' }); Used = $false }
    $corpusSw.Stop()
    $corpusSection = [string]$corpusReference.Section
    # 検索語の生成で新規チャットを1度使っているなら、最初のバッチは短い待ちでよい。
    $corpusQueryUsed = [bool]$corpusReference.Used
    $preBatchSw.Stop()
    $preBatchOtherMs = [Math]::Max(0, $preBatchSw.ElapsedMilliseconds - $directionSettingsMs - $batchingMs - $glossaryMatchMs - $styleReferenceSw.ElapsedMilliseconds)
    Write-YakuLog "Translation pre-batch timings. direction-settings elapsedMs=$directionSettingsMs batching elapsedMs=$batchingMs glossary-match elapsedMs=$glossaryMatchMs style-reference elapsedMs=$($styleReferenceSw.ElapsedMilliseconds) corpus-reference elapsedMs=$($corpusSw.ElapsedMilliseconds) reason=$([string]$corpusReference.Reason) examples=$([int]$corpusReference.Count) other elapsedMs=$preBatchOtherMs total elapsedMs=$($preBatchSw.ElapsedMilliseconds)" 'INFO'

    try {
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '準備中' -Progress 5 -Detail $directionLabel -Phase 'preparing'
        $batchResults = @()
        $styleReference = $initialStyleReference
        for ($i = 0; $i -lt $batches.Count; $i++) {
            $batch = $batches[$i]
            $startPct = [int](8 + [Math]::Floor(($i / [Math]::Max(1, $batches.Count)) * 84))
            $endPct = [int](8 + [Math]::Floor((($i + 1) / [Math]::Max(1, $batches.Count)) * 84))
            if ($ProgressState) {
                $ProgressState['batch_current'] = [int]$batch.Index
                $ProgressState['batch_total'] = [int]$batch.Total
                $ProgressState['batch_progress_start'] = $startPct
                $ProgressState['batch_progress_end'] = $endPct
                $ProgressState['batch_input_length'] = [int]$batch.CharCount
                # Kind-specific affine estimate: expected = base + input * ratio.
                if ($Kind -eq 'text') {
                    $ratio = 4.0; $base = 150.0
                    try { if ($Settings.copilotAnswerRatioText) { $ratio = [double]$Settings.copilotAnswerRatioText } } catch {}
                    try { if ($Settings.copilotAnswerBaseText)  { $base  = [double]$Settings.copilotAnswerBaseText } } catch {}
                } else {
                    $ratio = 1.7; $base = 0.0
                    try { if ($Settings.copilotAnswerRatioFile) { $ratio = [double]$Settings.copilotAnswerRatioFile } } catch {}
                    try { if ($Settings.copilotAnswerBaseFile)  { $base  = [double]$Settings.copilotAnswerBaseFile } } catch {}
                }
                $ratioCount = 0; $ratioSum = 0.0
                try { $ratioCount = [int]$ProgressState['answer_ratio_count']; $ratioSum = [double]$ProgressState['answer_ratio_sum'] } catch {}
                if ($ratioCount -gt 0) {
                    $ratio = $ratioSum / $ratioCount
                    $base = 0.0
                }
                $ProgressState['batch_expected_chars'] = [Math]::Max(1.0, $base + ([double]$batch.CharCount * $ratio))
            }
            $batchPrefix = if ($batches.Count -gt 1) { "バッチ $($batch.Index)/$($batch.Total)`: " } else { '' }
            $detail = "入力 $($batch.CharCount)字"
            Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label ($batchPrefix + '準備中') -Progress $startPct -Detail $detail -Phase 'preparing'
            $batchStyleReference = [string]$styleReference
            $br = Invoke-YakuTextTranslationRequests -Root $Root -InputText ([string]$batch.Text) -Settings $Settings -Direction $direction -StyleReference $batchStyleReference -SkipFreshChatWait:($i -gt 0 -or $corpusQueryUsed) -ProgressState $ProgressState -Warnings $warnings -CorpusSection $corpusSection -CachePolicy $CachePolicy
            $batchResults += [pscustomobject]@{
                Index = $batch.Index
                Total = $batch.Total
                CharCount = $batch.CharCount
                Options = $br.Options
                Raw = $br.Raw
                Prompt = $br.Prompt
                RequestId = $br.RequestId
                MaskedCount = $(try { [int]$br.MaskedCount } catch { 0 })
                KeptCount = $(try { [int]$br.KeptCount } catch { 0 })
            }
            if ($ProgressState -and [int]$batch.CharCount -gt 0) {
                $answerLength = ([string]$br.Raw).Length
                $actualRatio = [double]$answerLength / [double]$batch.CharCount
                $ratioCount = 0; $ratioSum = 0.0
                try { $ratioCount = [int]$ProgressState['answer_ratio_count']; $ratioSum = [double]$ProgressState['answer_ratio_sum'] } catch {}
                $ProgressState['answer_ratio_count'] = $ratioCount + 1
                $ProgressState['answer_ratio_sum'] = $ratioSum + $actualRatio
                try { Write-YakuLog ("Copilot answer ratio measured. batch={0}/{1} inputChars={2} answerChars={3} actualRatio={4:N3}" -f $batch.Index, $batch.Total, $batch.CharCount, $answerLength, $actualRatio) 'INFO' } catch {}
            }
            $styleReference = Get-YakuStyleReferenceFromOptions -Options $br.Options -Direction $direction
            Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label ($batchPrefix + '完了') -Progress $endPct -Detail $detail -Phase 'batch-complete'
        }

        $indexes = @($batchResults | ForEach-Object { [int]$_.Index })
        for ($expectedIndex = 1; $expectedIndex -le $batches.Count; $expectedIndex++) {
            if ($indexes[$expectedIndex - 1] -ne $expectedIndex) { throw 'RESPONSE_BATCH_ORDER_INVALID: バッチ順序が一致しません。' }
        }
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '検証中' -Progress 94 -Detail '' -Phase 'validating'
        if ($ProgressState) {
            foreach ($key in @('batch_current','batch_total','batch_progress_start','batch_progress_end','batch_input_length','batch_expected_chars','answer_ratio_count','answer_ratio_sum')) { try { $ProgressState.Remove($key) } catch {} }
        }
        if ($batchResults.Count -eq 1) {
            $options = @($batchResults[0].Options)
            $raw = [string]$batchResults[0].Raw
            $prompt = [string]$batchResults[0].Prompt
        } else {
            $options = @(Merge-YakuBatchTranslationResults -BatchResults $batchResults -Direction $direction)
            $raw = (($batchResults | ForEach-Object { [string]$_.Raw }) -join "`n`n--- BATCH ---`n`n")
            $prompt = (($batchResults | ForEach-Object { [string]$_.Prompt }) -join "`n`n--- BATCH PROMPT ---`n`n")
        }

        # 文中の用語監査は廃止した（利用者の判断 2026-08-06）。
        # テキスト翻訳の文中は、用語集ではなくコーパスの文例で寄せる。

        $maskedTotal = 0
        $keptTotal = 0
        foreach ($br2 in $batchResults) { $maskedTotal += [int]$br2.MaskedCount; $keptTotal += [int]$br2.KeptCount }

        # Quick and generic text translation never consult corpus/TM/history.
        # Deliberately keep the response shape empty for old clients.
        $pastPairs = @()

        $result = [pscustomobject]@{
            Direction = $direction
            DirectionLabel = $directionLabel
            MaskedCount = [int]$maskedTotal
            KeptCount = [int]$keptTotal
            InputLength = $InputText.Length
            # V91.61（2026-08-06）: 修正の依頼が原文を必要とする。画面の入力欄から
            # 取り直すと、利用者が入力欄を書き換えた後に「別の原文と現訳」を
            # 突き合わせることになる。訳した時の原文を結果に固定しておく。
            SourceText = [string]$InputText
            Options = $options
            # V91.61 段階3: 何を参照して訳したかを画面へ出すため。
            CorpusExamples = @($corpusReference.Examples)
            CorpusTerms = @($corpusReference.Terms)
            # 過去に公表した英訳。日英そろえて画面へ出す（往復ゼロ）。
            PastPairs = @($pastPairs)
            Raw = $raw
            Prompt = $prompt
            BatchCount = $batches.Count
            Batches = $batchResults
            Warnings = @($warnings.ToArray())
            Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '仕上げ中' -Progress 99 -Detail '結果を表示しています' -Phase 'finalizing'
        return $result
    } catch {
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label 'エラー処理中' -Progress 99 -Detail $_.Exception.Message -Phase 'finalizing'
        return [pscustomobject]@{
            Error = $_.Exception.Message
            Prompt = if ($prompt) { $prompt } else { '' }
            Direction = $direction
            DirectionLabel = $directionLabel
        }
    }
}
