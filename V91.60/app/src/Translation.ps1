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
    $names = @('glossary.csv','prompt_glossary.csv','prompts\text_translate_to_en.txt','prompts\text_translate_to_jp.txt','prompts\file_translate_to_en.txt','prompts\file_translate_to_jp.txt','prompts\style_brief_rules.txt')
    $settingParts = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('copilot_model','use_bundled_glossary','glossary_prompt_limit','max_chars_per_batch','max_chars_per_batch_file')) {
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
    $hash = if (Get-Command Get-YakuTextSha256 -ErrorAction SilentlyContinue) { Get-YakuTextSha256 -Text $Text } else {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    }
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

function Test-YakuTextResponseContract {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId
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
    $required = @(if ($Direction -eq 'to_en') { 'FULL_TEXT','BRIEF_TEXT' } else { 'JAPANESE_TEXT' })
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
    $unexpected = if ($Direction -eq 'to_en') { 'JAPANESE_TEXT' } else { 'FULL_TEXT|BRIEF_TEXT' }
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
    $result = [regex]::Replace($result, "(?<n>$num)\s*億円", { param($m) $token=(& $normalizeNumber $m.Groups['n'].Value)+' oku'; return (&$addToken $token) })
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
# Copilot は外部サーバーであるため、機密性のある数値の「大きさ」だけを
# プレースホルダー【N1】へ置き換えて送信し、受信後に復元する。
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
    # 非マスクにする形。§1-2 / §1-5 のとおり、実サンプルでは全角と半角が
    # 混在するため、判定は正規化後のテキストに対して行う。
    # 例外は狭く厳密に書く。広い例外は機密数値を素通しする。
    # 数字で始まる例外には (?<![0-9,.]) を付ける。付けないと「1,250台当たり」の
    # 「0台当たり」だけが一致し、重なり判定で 1,250 全体が保護されてしまう。
    return @(
        # --- 決算期・年度・年月日・四半期 ---
        '(?<![0-9,.])\d{2,4}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日',
        '(?<![0-9,.])\d{2,4}\s*年\s*\d{1,2}\s*月期',
        '(?<![0-9,.])\d{2,4}\s*年\s*\d{1,2}\s*月',
        '(?<![0-9,.])\d{2,4}\s*年度',
        '(?:令和|平成|昭和)\s*\d{1,2}\s*年',
        '(?<![0-9,.])\d{2,4}\s*年',
        'FY\s?\d{2,4}(?:\s?/\s?\d{1,2})?',
        '(?<![0-9,.])\d{2,4}\s?/\s?\d{1,2}\s?期',
        '第\s*\d{1,3}\s*期',
        '第\s*\d\s*四半期',
        '(?<![0-9])\d\s?[Qq](?![0-9A-Za-z])',
        '(?<![0-9A-Za-z])[Qq]\s?\d(?![0-9])',
        '(?<![0-9])\d{1,2}\s*月(?!期)',
        '第\s*\d{1,3}\s*(?:章|条|項|号)',
        # --- 「1株当たり」型の定型句。直後の金額はマスクされる ---
        '(?:(?<![0-9,.])\d|一)\s*株\s*(?:当たり|あたり)',
        '(?:(?<![0-9,.])\d|一)\s*(?:台|人|件|名)\s*(?:当たり|あたり)',
        # --- 電話番号 ---
        '(?<![0-9,.\-])(?:\+\d{1,3}[-\s])?\d{2,4}-\d{2,4}-\d{4}(?![0-9])',
        # --- 証券コード。ラベルが付く形だけを除外する。
        #     裸の (7261) は負数表記 (50) と区別できないためマスクする。 ---
        '(?:コード番号|証券コード)\s*\d{4}',
        # --- バージョン番号 ---
        '(?<![0-9A-Za-z])[Vv]\d+(?:\.\d+)*'
    )
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
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en'
    )
    $spans = New-Object System.Collections.Generic.List[object]
    $normalized = ConvertTo-YakuMaskNormalizedText -Text $Text
    if ([string]::IsNullOrEmpty($normalized)) { return @() }

    # ヘルパー関数へ List を渡すと、空のときにパラメータ束縛が失敗する。直接追加する。
    foreach ($pattern in (Get-YakuNumericMaskExemptPatterns)) {
        foreach ($m in [regex]::Matches($normalized, $pattern)) {
            if ($m.Length -gt 0) { $spans.Add([pscustomobject]@{ Start = [int]$m.Index; End = [int]($m.Index + $m.Length) }) | Out-Null }
        }
    }

    # 行頭の箇条書き番号。全角の「１．」も正規化後は「1.」になる。
    # 直後が数字なら箇条書きではなく小数(0.7 など)。除外しない。
    foreach ($m in [regex]::Matches($normalized, '(?m)^[ \t]*\(?\d{1,2}\)?[\.\)、](?!\d)')) {
        if ($m.Length -gt 0) { $spans.Add([pscustomobject]@{ Start = [int]$m.Index; End = [int]($m.Index + $m.Length) }) | Out-Null }
    }

    # V91.60(決定事項#7): 手動マスク【…非開示】は廃止した。数値は自動でマスクされる
    # ため手で伏せる必要がなく、二重の仕組みを残すと保護範囲の判断が分かれる。
    # 【】は強調・見出しの括弧として扱い、中の数値は通常どおりマスクする。
    # 自分が入れた【N1】だけは保護する。二重マスクを避けるため。
    foreach ($m in [regex]::Matches([string]$Text, '【N\d+】')) {
        if ($m.Length -gt 0) { $spans.Add([pscustomobject]@{ Start = [int]$m.Index; End = [int]($m.Index + $m.Length) }) | Out-Null }
    }

    # 用語集に一致した範囲。数字を含む語(FY26/3 1Q、AAT 営業利益(50%)、
    # MTMUS製(CX-50) 等)を壊さないため、マスク前のテキストから求める。
    # 件数制限は掛けない。制限すると上限を超えた用語が保護されない。
    if (-not [string]::IsNullOrWhiteSpace($Root) -and (Get-Command Get-YakuRelevantGlossaryMatches -ErrorAction SilentlyContinue)) {
        foreach ($path in @((Get-YakuGlossaryPath -Root $Root), (Get-YakuPromptGlossaryPath -Root $Root))) {
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                $matches = @(Get-YakuRelevantGlossaryMatches -Root $Root -InputText $Text -Direction $Direction -Limit ([int]::MaxValue) -Path $path)
            } catch { $matches = @() }
            foreach ($g in $matches) {
                $len = [int]$g.MatchLength
                if ($len -le 0) { continue }
                foreach ($pos in @($g.Positions)) { $spans.Add([pscustomobject]@{ Start = [int]$pos; End = [int]$pos + $len }) | Out-Null }
            }
        }
    }
    return @($spans.ToArray())
}

function New-YakuNumericMaskMap {
    <#
      数値の「大きさ」だけを【N1】へ置き換える。符号と単位は外に残す。
      戻り値: Text=マスク済み / Map=@{'【N1】'='72'} / MaskedCount / KeptCount
    #>
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Root,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$Location = 'unknown'
    )
    $source = [string]$Text
    $map = @{}
    if ([string]::IsNullOrEmpty($source) -or -not (Test-YakuNumericMaskingEnabled)) {
        return [pscustomobject]@{ Text = $source; Map = $map; MaskedCount = 0; KeptCount = 0 }
    }

    $protected = @(Get-YakuNumericMaskProtectedSpans -Text $source -Root $Root -Direction $Direction)
    $normalized = ConvertTo-YakuMaskNormalizedText -Text $source

    $targets = New-Object System.Collections.Generic.List[object]
    $kept = 0
    foreach ($m in [regex]::Matches($normalized, '\d[\d,]*(?:\.\d+)?')) {
        if (Test-YakuMaskSpanCovered -Spans $protected -Start $m.Index -End ($m.Index + $m.Length)) { $kept++; continue }
        $targets.Add([pscustomobject]@{ Start = $m.Index; Length = $m.Length }) | Out-Null
    }
    if ($targets.Count -eq 0) {
        try { Write-YakuLog "Numeric masking. location=$Location masked=0 kept=$kept" 'INFO' } catch {}
        return [pscustomobject]@{ Text = $source; Map = $map; MaskedCount = 0; KeptCount = $kept }
    }

    # 番号は本文の出現順。置換は後ろから行い、前方の位置をずらさない。
    $ordered = @($targets.ToArray() | Sort-Object Start)
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $map['【N' + ($i + 1) + '】'] = $source.Substring([int]$ordered[$i].Start, [int]$ordered[$i].Length)
    }
    $result = $source
    for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
        $token = '【N' + ($i + 1) + '】'
        $result = $result.Remove([int]$ordered[$i].Start, [int]$ordered[$i].Length).Insert([int]$ordered[$i].Start, $token)
    }
    try { Write-YakuLog "Numeric masking. location=$Location masked=$($ordered.Count) kept=$kept" 'INFO' } catch {}
    return [pscustomobject]@{ Text = $result; Map = $map; MaskedCount = [int]$ordered.Count; KeptCount = [int]$kept }
}

function Get-YakuNumericMaskTokens {
    param([AllowNull()][string]$Text)
    return @([regex]::Matches([string]$Text, '【N\d+】') | ForEach-Object { [string]$_.Value })
}

function Restore-YakuNumericMask {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][hashtable]$Map
    )
    $result = [string]$Text
    if ([string]::IsNullOrEmpty($result) -or $null -eq $Map -or $Map.Count -eq 0) { return $result }
    # 番号の大きい順に置換する。【N1】が【N10】の一部を壊さないため。
    foreach ($token in @($Map.Keys | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) } -Descending)) {
        $result = $result.Replace([string]$token, [string]$Map[$token])
    }
    return $result
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
    $ok = ($missing.Count -eq 0 -and $duplicated.Count -eq 0 -and $unexpected.Count -eq 0)
    $detail = "placeholders source=$($sourceCounts.Count) missing=$($missing.Count) duplicated=$($duplicated.Count) unexpected=$($unexpected.Count)"
    if (-not $ok) {
        $parts = New-Object System.Collections.Generic.List[string]
        if ($missing.Count -gt 0)    { $parts.Add('missing=' + (@($missing.ToArray()) -join ',')) | Out-Null }
        if ($duplicated.Count -gt 0) { $parts.Add('duplicated=' + (@($duplicated.ToArray()) -join ',')) | Out-Null }
        if ($unexpected.Count -gt 0) { $parts.Add('unexpected=' + (@($unexpected.ToArray()) -join ',')) | Out-Null }
        $detail = $detail + ' [' + (@($parts.ToArray()) -join '; ') + ']'
    }
    try { Write-YakuLog "Numeric mask integrity. location=$Location $detail" $(if ($ok) { 'DEBUG' } else { 'WARN' }) } catch {}
    return [pscustomobject]@{
        Ok = [bool]$ok; Detail = $detail
        Missing = @($missing.ToArray()); Duplicated = @($duplicated.ToArray()); Unexpected = @($unexpected.ToArray())
    }
}

function Restore-YakuMaskedTranslationOptions {
    <#
      V91.60: 各訳文の【N1】を実値へ戻す。戻す前に1対1を確かめ、崩れていれば
      警告を立てる。無言で数値が消えるのを避けるのがここの目的。
      復元自体は失敗させない。一部が欠けても残りは戻す。

      段階6(決定事項#3): BRIEF は原文の20〜30%へ圧縮するため、数値そのものが
      落ちることがある。省略が正当か事故かを区別できないので、BRIEF の欠落は
      再試行の理由にせず確認警告に留める(再試行の判断は呼び出し側)。
      欠落した数値は訳文へ挿入しない。省略された文脈へ数値だけを戻すと
      誤読を招くため。代わりに平文つきで警告表示する(決定事項#12)。

      応答が原文に無い番号を作った場合は、対応する実値が存在しない。
      【N9】のまま画面へ出すより取り除くほうが安全なので削除する。
    #>
    param(
        [AllowNull()][object[]]$Options,
        [AllowNull()][string]$MaskedSource,
        [AllowNull()][hashtable]$Map,
        [AllowNull()]$Warnings,
        [string]$Location = 'text'
    )
    if ($null -eq $Options) { return @() }
    if ($null -eq $Map -or $Map.Count -eq 0) { return @($Options) }
    foreach ($option in $Options) {
        $style = [string]$option.Style
        $label = [string]$option.Label
        $translated = [string]$option.Translation
        $integrity = Test-YakuNumericMaskIntegrity -MaskedSource $MaskedSource -Translated $translated -Location ($Location + '-' + $style)
        $restored = Restore-YakuNumericMask -Text $translated -Map $Map
        # 原文に無い番号は実値が無い。残すと画面へ内部トークンが出る。
        $leftover = @(Get-YakuNumericMaskTokens -Text $restored | Select-Object -Unique)
        if ($leftover.Count -gt 0) {
            foreach ($token in $leftover) { $restored = $restored.Replace([string]$token, '') }
            $restored = [regex]::Replace($restored, '[ \t]{2,}', ' ')
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
                Add-YakuWarning -Warnings $Warnings -Category 'numeric-placeholder-dropped-brief' -Location $label -Details $details -Message ("BRIEF は要約のため、次の数値が省略されました: " + (@($dropped) -join '、') + "。意図した省略か確認してください。")
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
    # V91.60: マスク後は数値が【N1】に置き換わるため、監査対象へ加える。
    # これにより既存の数値整合監査・補正・再試行の仕組みがそのまま使える。
    $pattern = '(?<![0-9])(?<num>【N\d+】|[0-9][0-9,]*(?:\.[0-9]+)?|[xX]{2,})\s+(?<unit>oku|k units|k yen)'
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
    foreach ($m in [regex]::Matches([string]$SourceText, '(?<![0-9])(?<num>【N\d+】|[0-9][0-9,]*(?:\.[0-9]+)?)\s*[%％]')) {
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
    try{Write-YakuLog "Numeric integrity audit. location=$Location checked=$checked matched=$matched scaleErrors=$scaleErrors corrected=0 detail=$detail" $(if($ok){'INFO'}else{'WARN'})}catch{}
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
    $items=@($all|Where-Object{ [string]$_.Expected -match '【N\d+】' })
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
        [AllowNull()]$Warnings
    )
    $contract = Test-YakuTextResponseContract -Text $Raw -Direction $Direction -RequestId $RequestId
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
        $fullText = Get-YakuLabeledResponseField -Text $clean -Label 'FULL_TEXT'
        $briefText = Get-YakuLabeledResponseField -Text $clean -Label 'BRIEF_TEXT'
        $fullText = ConvertFrom-YakuTextFullWidthAngle -Text $fullText
        $briefText = ConvertFrom-YakuTextFullWidthAngle -Text $briefText
        if (![string]::IsNullOrWhiteSpace($fullText) -and $fullText.Trim() -ne '...') {
            $items += [pscustomobject]@{ Style='full'; Label='FULL'; Translation=$fullText; Explanation='' }
        }
        if (![string]::IsNullOrWhiteSpace($briefText) -and $briefText.Trim() -ne '...') {
            $items += [pscustomobject]@{ Style='brief'; Label='BRIEF'; Translation=$briefText; Explanation='' }
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
        [AllowNull()]$Warnings
    )
    $options = @(Parse-YakuV25PlainTranslationResponse -Raw $Raw -Direction $Direction -RequestId $RequestId -Warnings $Warnings)
    $expected = if ($Direction -eq 'to_en') { 2 } else { 1 }
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
        [int]$Attempt = 0
    )
    $path = ''
    try {
        $path = Join-Path (Get-YakuSubDir 'logs') ("copilot-text-response-diagnostic-" + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.jsonl')
        $rawText = [string]$Raw
        $normalized = Normalize-YakuCopilotPlainResponse -Raw $rawText -RequestId $RequestId
        $signatureText = $normalized.Replace($RequestId, '<request-id>')
        $structure = Get-YakuTextResponseStructureMetadata -Raw $rawText -RequestId $RequestId
        $requiredLabels = @(if ($Direction -eq 'to_en') { 'FULL_TEXT','BRIEF_TEXT' } else { 'JAPANESE_TEXT' })
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
    # V91.60 修正: ここに来る訳文は復元済みで実値を含む。そのまま次のバッチの
    # STYLE_REFERENCE に入れると、平文の数値が外部へ送られる。送る前に伏せる。
    # 【N1】のままだと次のバッチの番号と衝突するため、番号なしの【#】にする。
    $maskedRef = New-YakuNumericMaskMap -Text $ref -Direction $Direction -Location 'style-reference'
    $ref = [regex]::Replace([string]$maskedRef.Text, '【N\d+】', '【#】')
    return $ref
}

function Merge-YakuBatchTranslationResults {
    param(
        [Parameter(Mandatory=$true)][object[]]$BatchResults,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    $merged = @()
    if ($Direction -eq 'to_en') {
        foreach ($spec in @(@{Style='full';Label='FULL'}, @{Style='brief';Label='BRIEF'})) {
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
    $expected = if ($Direction -eq 'to_en') { 2 } else { 1 }
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
        [AllowNull()]$Warnings
    )
    $requestId = [guid]::NewGuid().ToString('N')
    # V91.60 段階3: 外部へ送る前に数値をマスクする。
    # バッチ分割の後にマスクするのは、分割が【N12】の途中を
    # 切ることを構造的に防ぐため。Split-YakuHardChunk は文境界が
    # 見つからなければ文字数で切るので、先にマスクすると壊れ得る。
    # 以降この関数の中では $sourceText(マスク後) を原文として扱う。
    # プロンプト・キャッシュキー・各監査を同じ土俵に乗せるため。
    $maskResult = New-YakuNumericMaskMap -Text $InputText -Root $Root -Direction $Direction -Location 'text'
    $sourceText = [string]$maskResult.Text
    $maskMap = $maskResult.Map
    $glossarySw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = @(Get-YakuGlossaryEntries -Root $Root)
    $glossarySw.Stop()
    $promptSw = [System.Diagnostics.Stopwatch]::StartNew()
    $built = New-YakuTextPrompt -Root $Root -InputText $sourceText -Settings $Settings -DirectionOverride $Direction -StyleReference $StyleReference -RequestId $requestId
    $promptSw.Stop()
    $styleReferenceHash = if ([string]::IsNullOrEmpty([string]$StyleReference)) { '' } else { Get-YakuTextSha256 -Text ([string]$StyleReference) }
    $cacheSw = [System.Diagnostics.Stopwatch]::StartNew()
    # マスク状態は Get-YakuTranslationContractFingerprint が持つ(§7)。
    # ここは版だけ上げ、マスクなし時代のキーと衝突しないようにする。
    $cacheKey = Get-YakuTranslationCacheKey -Kind 'text' -Direction $Direction -Text $sourceText -Style ('plain-v9160|' + $styleReferenceHash) -Root $Root -Settings $Settings
    $cachedRaw = Get-YakuTranslationCacheValue -Key $cacheKey -Settings $Settings
    $cacheSw.Stop()
    Write-YakuLog "Translation preparation timings. glossary-load elapsedMs=$($glossarySw.ElapsedMilliseconds) prompt-build elapsedMs=$($promptSw.ElapsedMilliseconds) cache-lookup elapsedMs=$($cacheSw.ElapsedMilliseconds)" 'INFO'
    if ($null -ne $cachedRaw -and -not [string]::IsNullOrWhiteSpace([string]$cachedRaw)) {
        try {
            $cachedEnvelope = [string]$cachedRaw | ConvertFrom-Json
            $cachedRequestId = [string]$cachedEnvelope.request_id
            $optionsCached = @(Parse-YakuTextTranslationResponse -Raw ([string]$cachedEnvelope.raw) -Direction $Direction -RequestId $cachedRequestId -Warnings $Warnings)
            $optionsCached = @(Repair-YakuTextResponsePostParse -SourceText $sourceText -Options $optionsCached -Direction $Direction)
            if (-not ($Direction -eq 'to_jp' -and $maskMap.Count -gt 0)) {
                foreach ($cachedOption in $optionsCached) {
                    $cachedNumeric = Test-YakuNumericIntegrity -SourceText $sourceText -TranslatedText ([string]$cachedOption.Translation) -Location ("text-cache-" + [string]$cachedOption.Style)
                    if (-not [bool]$cachedNumeric.Ok -and [int]$cachedNumeric.ScaleErrors -gt 0) { throw "NUMERIC_SCALE_MISMATCH: $([string]$cachedNumeric.Detail)" }
                }
            }
            if ($Direction -eq 'to_en') {
                $cachedIntegrity = Test-YakuTextStructureIntegrity -SourceText $sourceText -FullText ([string]$optionsCached[0].Translation) -BriefText ([string]$optionsCached[1].Translation)
                if (-not [bool]$cachedIntegrity.Ok) {
                    try { Write-YakuLog "Text response structure mismatch. attempt=cache detail=$([string]$cachedIntegrity.Detail); cache=discard" 'WARN' } catch {}
                    throw "RESPONSE_STRUCTURE_MISMATCH: $([string]$cachedIntegrity.Detail)"
                }
            }
            $optionsCached = @(Restore-YakuMaskedTranslationOptions -Options $optionsCached -MaskedSource $sourceText -Map $maskMap -Warnings $Warnings -Location 'text-cache')
            return [pscustomobject]@{ Direction=$Direction; Options=$optionsCached; Raw=[string]$cachedEnvelope.raw; Prompt=$built.Prompt; CacheHit=$true; RequestId=$cachedRequestId; MaskedCount=[int]$maskResult.MaskedCount; KeptCount=[int]$maskResult.KeptCount }
        } catch {
            try { (Get-YakuTranslationCacheStore).Remove($cacheKey) } catch {}
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
            $requestId = [guid]::NewGuid().ToString('N')
            $built = New-YakuTextPrompt -Root $Root -InputText $sourceText -Settings $Settings -DirectionOverride $Direction -StyleReference $StyleReference -RequestId $requestId
            if (-not [string]::IsNullOrWhiteSpace($numericCorrectionInstruction)) { $built.Prompt += "`n`n$numericCorrectionInstruction" }
        }
        try {
            $raw = Invoke-YakuCopilotPrompt -Prompt $built.Prompt -Settings $Settings -SkipFreshChatWait:($SkipFreshChatWait -or $attempt -gt 1) -PreserveEndMarker -ProgressState $ProgressState -Warnings $Warnings
            $options = @(Parse-YakuTextTranslationResponse -Raw $raw -Direction $Direction -RequestId $requestId -Warnings $Warnings)
            $options = @(Repair-YakuTextResponsePostParse -SourceText $sourceText -Options $options -Direction $Direction)
            $numericFailures = New-Object System.Collections.Generic.List[object]
            # V91.60 段階4: to_jp では 【N1】 oku が 【N1】億円 へ訳されるため、
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
            if ($Direction -eq 'to_en') {
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
            if ($errorMessage -match 'COPILOT_SILENT_START_TIMEOUT') {
                $silentStartFailures++
                try { Write-YakuLog "Copilot silent start retry. attempt=$attempt/$maxAttempts silentFailures=$silentStartFailures" 'WARN' } catch {}
                if ($silentStartFailures -ge 2) { throw }
                if ($attempt -ge $maxAttempts) { $maxAttempts = [Math]::Min(4, $attempt + 1) }
            } else {
                $isContractError = ($attemptErrorCode -match '^(RESPONSE_|COPILOT_REFUSAL_OR_LOGIN)')
                if ($isContractError) {
                    $rawHash = if ([string]::IsNullOrEmpty([string]$raw)) { '' } else { try { Get-YakuTextSha256 -Text ([string]$raw) } catch { '' } }
                    $diagnosticPath = Write-YakuTextResponseContractDiagnostic -Raw $raw -Direction $Direction -RequestId $requestId -ErrorCode $attemptErrorCode -ErrorMessage $errorMessage -Attempt $attempt
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
    if (-not $structureMismatchAccepted) {
        $cacheEnvelope = [ordered]@{ request_id=$requestId; raw=$raw } | ConvertTo-Json -Depth 4 -Compress
        Set-YakuTranslationCacheValue -Key $cacheKey -Value $cacheEnvelope -Settings $Settings
    }
    # キャッシュへはマスク後の raw を保存する。ディスク上に実値を
    # 残さないことにもなる。復元はその後のこの位置で行う。
    $options = @(Restore-YakuMaskedTranslationOptions -Options $options -MaskedSource $sourceText -Map $maskMap -Warnings $Warnings -Location 'text')
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

function Save-YakuHistory {
    param(
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Result
    )
    try {
        $storeName = 'YakuLingoSessionHistoryV64'
        $store = [AppDomain]::CurrentDomain.GetData($storeName)
        if ($null -eq $store) {
            $store = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            [AppDomain]::CurrentDomain.SetData($storeName, $store)
        }
        $sessionRecord = [pscustomobject]@{
            timestamp = (Get-Date).ToString('s')
            input = $InputText
            direction = $Result.Direction
            direction_label = $Result.DirectionLabel
            options = $Result.Options
        }
        [void]$store.Add($sessionRecord)
        while ($store.Count -gt 10) { $store.RemoveAt(0) }

        $dir = Get-YakuSubDir 'history'
        $path = Join-Path $dir 'history.jsonl'
        $record = [ordered]@{
            timestamp = (Get-Date).ToString('s')
            input_sha256 = Get-YakuTextSha256 -Text $InputText
            input_length = $InputText.Length
            direction = $Result.Direction
            option_count = @($Result.Options).Count
            output_lengths = @($Result.Options | ForEach-Object { ([string]$_.Translation).Length })
        }
        $line = $record | ConvertTo-Json -Depth 8 -Compress
        $mutex = New-Object System.Threading.Mutex($false, 'Local\YakuLingo-HistoryWrite')
        $locked = $false
        try {
            $locked = $mutex.WaitOne(3000)
            if ($locked) { Add-Content -LiteralPath $path -Value $line -Encoding UTF8 }
        } finally {
            if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
            $mutex.Dispose()
        }
    } catch {
        Write-Warning "Failed to save history: $($_.Exception.Message)"
    }
}

function Invoke-YakuHistoryRotation {
    param([int]$RetentionDays = 30, [int64]$MaxBytes = 1048576)
    $path = Join-Path (Get-YakuSubDir 'history') 'history.jsonl'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try {
        $cutoff = (Get-Date).AddDays(-[Math]::Max(1, $RetentionDays))
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
            try {
                $record = $line | ConvertFrom-Json
                if ([datetime]::Parse([string]$record.timestamp) -ge $cutoff) { $kept.Add([string]$line) | Out-Null }
            } catch {}
        }
        while (([System.Text.Encoding]::UTF8.GetByteCount(($kept.ToArray() -join "`n"))) -gt $MaxBytes -and $kept.Count -gt 1) { $kept.RemoveAt(0) }
        $rotatedText = if ($kept.Count -gt 0) { (($kept.ToArray()) -join "`n") + "`n" } else { '' }
        if (Get-Command Write-YakuTextAtomic -ErrorAction SilentlyContinue) { Write-YakuTextAtomic -Path $path -Text $rotatedText }
        else { Set-Content -LiteralPath $path -Value $kept.ToArray() -Encoding UTF8 }
    } catch {}
}

function Clear-YakuHistory {
    $sessionCount = 0
    $metadataCount = 0
    try {
        $store = [AppDomain]::CurrentDomain.GetData('YakuLingoSessionHistoryV64')
        if ($store) { $sessionCount = [int]$store.Count; $store.Clear() }
    } catch {}
    $path = Join-Path (Get-YakuSubDir 'history') 'history.jsonl'
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $metadataCount = @(Get-Content -LiteralPath $path -Encoding UTF8).Count
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    } catch {}
    Clear-YakuTranslationCache
    return [pscustomobject]@{ Count=$metadataCount; SessionCount=$sessionCount; MetadataCount=$metadataCount; Path=$path }
}

function Get-YakuHistoryHtml {
    param([int]$Limit = 10)
    $store = [AppDomain]::CurrentDomain.GetData('YakuLingoSessionHistoryV64')
    if ($null -eq $store -or $store.Count -eq 0) {
        return New-YakuAlertHtml -Kind info -Message '履歴はまだありません。'
    }
    $records = @($store | Select-Object -Last $Limit)
    [array]::Reverse($records)
    $html = "<section class='history-list'>"
    foreach ($r in $records) {
        $first = @($r.options)[0]
        $input = [string]$r.input
        $output = if ($first) { [string]$first.Translation } else { '' }
        $dir = if ($r.direction_label) { [string]$r.direction_label } else { [string]$r.direction }
        $html += @"
<article class='history-item'>
  <div class='history-head'>
  <div class='history-time'>$(ConvertTo-YakuHtml $r.timestamp) / $(ConvertTo-YakuHtml $dir) / $(ConvertTo-YakuHtml $input.Length)字</div>
    <div class='history-actions'>
      <button type='button' class='secondary-button history-fill-button' data-yaku-fill-b64="$(ConvertTo-YakuHtml (ConvertTo-YakuUtf8Base64 $input))">入力に戻す</button>
      $(New-YakuCopyButtonHtml -Text $output -Label '出力をコピー')
    </div>
  </div>
  <pre class='history-input'>$(ConvertTo-YakuHtml $input)</pre>
  <pre class='history-output'>$(ConvertTo-YakuHtml $output)</pre>
</article>
"@
    }
    $html += "</section>"
    return $html
}

function Test-YakuTextGlossaryDiagnosticContains {
    param([AllowNull()][string]$Text, [AllowNull()][string]$Term)
    $haystack = ConvertTo-YakuGlossaryMatchKey -Value ([string]$Text)
    $needle = ConvertTo-YakuGlossaryMatchKey -Value ([string]$Term)
    if ([string]::IsNullOrWhiteSpace($haystack) -or [string]::IsNullOrWhiteSpace($needle)) { return $false }
    return ($haystack.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0)
}

function Write-YakuTextGlossaryDiagnosticLog {
    param(
        [AllowNull()][object[]]$Matches,
        [AllowNull()][object[]]$Options,
        [AllowNull()][string]$InputText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()][string]$JobId
    )
    if (@($Matches).Count -le 0 -or @($Options).Count -le 0) { return }
    $violations = New-Object System.Collections.Generic.List[object]
    $checked = 0
    foreach ($option in @($Options)) {
        if ($null -eq $option) { continue }
        $style = [string]$option.Style
        $translated = [string]$option.Translation
        foreach ($match in @($Matches)) {
            if ($null -eq $match) { continue }
            $from = if ($match.PSObject.Properties.Name -contains 'From') { [string]$match.From } else { [string]$match.Source }
            $to = if ($match.PSObject.Properties.Name -contains 'To') { [string]$match.To } else { [string]$match.Target }
            if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
            if (-not (Test-YakuTextGlossaryDiagnosticContains -Text $InputText -Term $from)) { continue }
            $checked++
            $variantValues = if ($match.PSObject.Properties.Name -contains 'Variants') { @($match.Variants) } else { @($to) }
            $variantHit = $false
            foreach ($variant in $variantValues) {
                if (Test-YakuTextGlossaryDiagnosticContains -Text $translated -Term ([string]$variant)) { $variantHit = $true; break }
            }
            if ($variantHit) { continue }
            $row = 0
            try { $row = [int]$match.Row } catch { $row = 0 }
            $violations.Add([pscustomobject]@{ Style=$style; From=$from; To=$to; Row=$row; SourceText=[string]$InputText; TranslatedText=$translated }) | Out-Null
        }
    }

    $diagnosticsEnabled = Test-YakuFullTextDiagnosticsEnabled
    try { Write-YakuLog "Text glossary occurrence audit: jobId=$JobId direction=$Direction optionCount=$(@($Options).Count) checked=$checked violated=$($violations.Count) diagnosticEnabled=$diagnosticsEnabled" 'INFO' } catch {}
    if ($violations.Count -le 0) { return }

    $diagnosticPath = ''
    if ($diagnosticsEnabled) {
        try {
            $dir = Get-YakuSubDir 'logs'
            $diagnosticPath = Join-Path $dir ("copilot-glossary-diagnostic-" + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.jsonl')
        } catch { $diagnosticPath = '' }
    }
    $ordinal = 0
    foreach ($violation in @($violations.ToArray())) {
        $ordinal++
        $from = [string]$violation.From
        $to = [string]$violation.To
        $source = [string]$violation.SourceText
        $translated = [string]$violation.TranslatedText
        $fromHash = try { Get-YakuTextSha256 -Text $from } catch { '' }
        $toHash = try { Get-YakuTextSha256 -Text $to } catch { '' }
        $sourceHash = try { Get-YakuTextSha256 -Text $source } catch { '' }
        $translationHash = try { Get-YakuTextSha256 -Text $translated } catch { '' }
        try {
            Write-YakuLog "Text glossary occurrence violation: jobId=$JobId direction=$Direction ordinal=$ordinal style=$($violation.Style) row=$($violation.Row) fromLength=$($from.Length) fromHash=$fromHash expectedLength=$($to.Length) expectedHash=$toHash sourceLength=$($source.Length) sourceHash=$sourceHash translationLength=$($translated.Length) translationHash=$translationHash" 'INFO'
        } catch {}
        if ($diagnosticPath) {
            try {
                $entry = [ordered]@{
                    time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                    event = 'text-glossary-occurrence-violation'
                    job_id = [string]$JobId
                    direction = [string]$Direction
                    ordinal = [int]$ordinal
                    style = [string]$violation.Style
                    glossary = [ordered]@{ from=$from; expected=$to; row=[int]$violation.Row }
                    source_text = $source
                    translated_text = $translated
                    normalized = [ordered]@{ source=(ConvertTo-YakuGlossaryMatchKey -Value $source); translated=(ConvertTo-YakuGlossaryMatchKey -Value $translated); expected=(ConvertTo-YakuGlossaryMatchKey -Value $to) }
                }
                Add-Content -LiteralPath $diagnosticPath -Value ($entry | ConvertTo-Json -Depth 30 -Compress) -Encoding UTF8
            } catch {
                try { Write-YakuLog "Text glossary diagnostic event write failed. jobId=$JobId ordinal=$ordinal error=$($_.Exception.Message)" 'WARN' } catch {}
            }
        }
    }
    if ($diagnosticPath) {
        try { Write-YakuLog "Text glossary occurrence diagnostic saved. jobId=$JobId records=$ordinal path=$diagnosticPath" 'INFO' } catch {}
    }
}

function Invoke-YakuTextTranslation {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()]$ProgressState,
        [AllowNull()][string]$DirectionOverride = ''
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
    $appliedGlossary = @(Get-YakuAppliedGlossaryEntries -Root $Root -InputText $processingInput -Direction $direction -Settings $Settings)
    $sectionSw.Stop(); $glossaryMatchMs = $sectionSw.ElapsedMilliseconds
    $styleReferenceSw = [System.Diagnostics.Stopwatch]::StartNew()
    $initialStyleReference = ''
    $styleReferenceSw.Stop()
    $preBatchSw.Stop()
    $preBatchOtherMs = [Math]::Max(0, $preBatchSw.ElapsedMilliseconds - $directionSettingsMs - $batchingMs - $glossaryMatchMs - $styleReferenceSw.ElapsedMilliseconds)
    Write-YakuLog "Translation pre-batch timings. direction-settings elapsedMs=$directionSettingsMs batching elapsedMs=$batchingMs glossary-match elapsedMs=$glossaryMatchMs style-reference elapsedMs=$($styleReferenceSw.ElapsedMilliseconds) other elapsedMs=$preBatchOtherMs total elapsedMs=$($preBatchSw.ElapsedMilliseconds)" 'INFO'

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
            $br = Invoke-YakuSingleTranslationBatch -Root $Root -InputText ([string]$batch.Text) -Settings $Settings -Direction $direction -StyleReference $batchStyleReference -SkipFreshChatWait:($i -gt 0) -ProgressState $ProgressState -Warnings $warnings
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

        $jobId = ''
        try { if ($ProgressState -and -not [string]::IsNullOrWhiteSpace([string]$ProgressState['id'])) { $jobId = [string]$ProgressState['id'] } } catch { $jobId = '' }
        try {
            Write-YakuTextGlossaryDiagnosticLog -Matches $appliedGlossary -Options $options -InputText $InputText -Direction $direction -JobId $jobId
        } catch {
            try { Write-YakuLog "Text glossary diagnostic audit failed without affecting translation. jobId=$jobId error=$($_.Exception.Message)" 'WARN' } catch {}
        }

        $maskedTotal = 0
        $keptTotal = 0
        foreach ($br2 in $batchResults) { $maskedTotal += [int]$br2.MaskedCount; $keptTotal += [int]$br2.KeptCount }
        $result = [pscustomobject]@{
            Direction = $direction
            DirectionLabel = $directionLabel
            MaskedCount = [int]$maskedTotal
            KeptCount = [int]$keptTotal
            InputLength = $InputText.Length
            Options = $options
            AppliedGlossary = $appliedGlossary
            Raw = $raw
            Prompt = $prompt
            BatchCount = $batches.Count
            Batches = $batchResults
            Warnings = @($warnings.ToArray())
            Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        Save-YakuHistory -InputText $InputText -Result $result
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '仕上げ中' -Progress 99 -Detail '結果を保存しています' -Phase 'finalizing'
        return $result
    } catch {
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label 'エラー処理中' -Progress 99 -Detail $_.Exception.Message -Phase 'finalizing'
        return [pscustomobject]@{
            Error = $_.Exception.Message
            Prompt = if ($prompt) { $prompt } else { '' }
            Direction = $direction
            DirectionLabel = $directionLabel
            AppliedGlossary = $appliedGlossary
        }
    }
}
