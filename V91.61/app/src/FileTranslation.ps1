function Get-YakuMaxCharsPerFileBatch {
    param([Parameter(Mandatory=$true)]$Settings)
    $max = 3000
    try { $max = [int]$Settings.max_chars_per_batch_file } catch { $max = 3000 }
    if ($max -lt 300) { $max = 3000 }
    return $max
}

function Get-YakuTranslatedOutputPath {
    param([Parameter(Mandatory=$true)][string]$InputPath)
    $dir = Get-YakuSubDir 'outputs'
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $ext = [System.IO.Path]::GetExtension($InputPath)
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'file' }
    $safeBase = New-SafeFileName -FileName $base
    $candidate = Join-Path $dir ($safeBase + '_translated' + $ext)
    $i = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $dir ($safeBase + '_translated(' + $i + ')' + $ext)
        $i++
    }
    return $candidate
}

function Set-YakuFileTranslationProgress {
    param(
        [AllowNull()]$ProgressState,
        [string]$Phase = '',
        [string]$Label = 'Translating file',
        [int]$Progress = 0,
        [string]$Detail = '',
        [AllowNull()][hashtable]$Fields
    )
    if ($null -eq $ProgressState) { return }
    Assert-YakuJobNotCancelled -ProgressState $ProgressState
    try {
        $pct = [Math]::Max(0, [Math]::Min(100, $Progress))
        $ProgressState['mode'] = 'working'
        $ProgressState['label'] = $Label
        $ProgressState['class'] = 'warn'
        $ProgressState['progress'] = [int]$pct
        $ProgressState['detail'] = $Detail
        $ProgressState['phase'] = $Phase
        if ($Fields) {
            foreach ($key in $Fields.Keys) { $ProgressState[$key] = $Fields[$key] }
        }
        $ProgressState['updated_at'] = (Get-Date).ToString('s')
        Write-YakuProgressStateFile -ProgressState $ProgressState
    } catch [System.OperationCanceledException] { throw }
    catch {}
}


function Get-YakuFileRemainingHint {
    <#
      残りどれくらいかを言葉で返す。

      数十分かかる処理なのに、これまで所要の予告も残り時間も出していなかった。
      利用者は「進んでいるのか、止まっているのか」を推測するしかない。
      実測（ここまでにかかった時間 ÷ 済んだ回数）から見当を出す。

      1回目は材料が無いので何も言わない。分からないときに数字を出すより、
      黙っているほうがよい。
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total
    )
    if ($Current -le 1 -or $Total -le $Current) { return '' }
    try {
        $started = $Context['StartedAt']
        if (-not $started) { return '' }
        $elapsed = ((Get-Date) - [datetime]$started).TotalSeconds
        if ($elapsed -le 0) { return '' }
        $perBatch = $elapsed / [double]($Current - 1)
        $remain = $perBatch * ($Total - $Current + 1)
        if ($remain -lt 90) { return '残り1分ほどです' }
        $minutes = [int][Math]::Ceiling($remain / 60)
        # ぴったりの数字は出さない。外れたときに嘘になる。
        if ($minutes -le 5) { return '残り5分ほどです' }
        if ($minutes -le 15) { return '残り10〜15分ほどです' }
        if ($minutes -le 30) { return '残り20〜30分ほどです' }
        return ('残り ' + [int]([Math]::Ceiling($minutes / 10.0) * 10) + ' 分ほどです')
    } catch { return '' }
}

function Get-YakuFileUniqueProgressPercent {
    param([Parameter(Mandatory=$true)][hashtable]$Context)
    $uniqueTotal = 1
    $done = 0
    try { $uniqueTotal = [int]$Context['UniqueTotal'] } catch { $uniqueTotal = 1 }
    try { $done = [int]$Context['TranslatedSoFar'] } catch { $done = 0 }
    if ($uniqueTotal -lt 1) { $uniqueTotal = 1 }
    if ($done -lt 0) { $done = 0 }
    if ($done -gt $uniqueTotal) { $done = $uniqueTotal }
    return [int](8 + [Math]::Floor(($done / [double]$uniqueTotal) * 82))
}

function Get-YakuFileUniqueProgressFields {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [int]$BatchCurrent = 0,
        [int]$BatchTotal = 0
    )
    $uniqueTotal = 1
    $done = 0
    try { $uniqueTotal = [int]$Context['UniqueTotal'] } catch { $uniqueTotal = 1 }
    try { $done = [int]$Context['TranslatedSoFar'] } catch { $done = 0 }
    if ($uniqueTotal -lt 1) { $uniqueTotal = 1 }
    if ($done -lt 0) { $done = 0 }
    return @{ unique_done=$done; unique_total=$uniqueTotal; batch_current=$BatchCurrent; batch_total=$BatchTotal }
}

function Update-YakuFileMaxRetryDepth {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [int]$Depth
    )
    try {
        if (-not $Context.ContainsKey('MaxRetryDepthReached')) { $Context['MaxRetryDepthReached'] = 0 }
        if ([int]$Context['MaxRetryDepthReached'] -lt [int]$Depth) { $Context['MaxRetryDepthReached'] = [int]$Depth }
    } catch {}
}

function New-YakuFileUniqueItems {
    param([Parameter(Mandatory=$true)][object[]]$Blocks)
    $byText = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($block in @($Blocks)) {
        $text = [string]$block.Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if (-not $byText.ContainsKey($text)) {
            $item = [pscustomobject]@{ Index=($items.Count + 1); Text=$text; BlockIds=(New-Object System.Collections.Generic.List[string]) }
            $byText[$text] = $item
            $items.Add($item) | Out-Null
        }
        $byText[$text].BlockIds.Add([string]$block.Id) | Out-Null
    }
    return [pscustomobject]@{ Items=@($items.ToArray()); ByText=$byText }
}

function Split-YakuFileTranslationItems {
    param(
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][int]$MaxChars
    )
    $batches = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[object]
    $chars = 0
    foreach ($item in @($Items)) {
        $text = [string]$item.Text
        $len = $text.Length + 24
        if ($current.Count -gt 0 -and ($chars + $len) -gt $MaxChars) {
            $batches.Add([pscustomobject]@{ Items=@($current.ToArray()); CharCount=$chars }) | Out-Null
            $current = New-Object System.Collections.Generic.List[object]
            $chars = 0
        }
        $current.Add($item) | Out-Null
        $chars += $len
        if ($text.Length -gt $MaxChars -and $current.Count -gt 0) {
            $batches.Add([pscustomobject]@{ Items=@($current.ToArray()); CharCount=$chars }) | Out-Null
            $current = New-Object System.Collections.Generic.List[object]
            $chars = 0
        }
    }
    if ($current.Count -gt 0) { $batches.Add([pscustomobject]@{ Items=@($current.ToArray()); CharCount=$chars }) | Out-Null }
    return @($batches.ToArray())
}

function New-YakuFileSourceList {
    param([Parameter(Mandatory=$true)][object[]]$Items)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $n = $i + 1
        $text = ([string]$Items[$i].Text).Replace("`r`n", "`n").Replace("`r", "`n")
        $parts = $text -split "`n", -1
        $first = if ($parts.Count -gt 0) { [string]$parts[0] } else { '' }
        $lines.Add("[[ID:$n]] $n. $first") | Out-Null
        if ($parts.Count -gt 1) {
            for ($j = 1; $j -lt $parts.Count; $j++) {
                $lines.Add('    ' + [string]$parts[$j]) | Out-Null
            }
        }
    }
    return (($lines.ToArray()) -join "`n")
}

function New-YakuFilePrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId,
        # 参考資料から引いた文例。CAT からのみ渡る（利用者の判断 2026-08-06）。
        # 簡易翻訳では検索の往復が1回増えて重いので外した。腰を据えて訳す
        # CAT 側でだけ使う。
        [AllowNull()][string]$CorpusSection
    )
    $sourceList = New-YakuFileSourceList -Items $Items
    $templateName = if ($Direction -eq 'to_en') { 'file_translate_to_en.txt' } else { 'file_translate_to_jp.txt' }
    $template = Get-YakuPromptTemplate -Root $Root -Name $templateName
    $vars = @{
        source_list = $sourceList
        # V91.60 段階5: テキスト経路と同じ数値規則を使う。
        # ファイル用テンプレートは規則を直書きしていたため、方向差分と
        # プレースホルダー保護が二重管理になっていた。1箇所へ寄せる。
        numeric_rules = Get-YakuNumericRulesSection -InputText $sourceList -Direction $Direction
        corpus_section = [string]$CorpusSection
        request_id = $RequestId
    }
    return Expand-YakuTemplate -Template $template -Variables $vars
}

function Test-YakuSplitRequestResponse {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $markers = @(
        '入力テキスト量が非常に多いため',
        '複数回に分割',
        '分割して',
        'too much text',
        'too large',
        'split into multiple',
        'please send',
        '続き'
    )
    $count = 0
    foreach ($m in $markers) {
        if ([regex]::IsMatch($Text, [regex]::Escape($m), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $count++ }
    }
    return ($count -ge 2)
}

function Test-YakuFileResponseCompleted {
    param([AllowNull()][string]$Text, [Parameter(Mandatory=$true)][string]$RequestId)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = [string]$Text
    try {
        if (Get-Command Remove-YakuMarkdownEscapes -ErrorAction SilentlyContinue) {
            $normalized = Remove-YakuMarkdownEscapes -Text $normalized
        }
    } catch {}
    $lines = @($normalized.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return $false }
    $expected = 'YAKULINGO_END:' + $RequestId
    $count = @($lines | Where-Object { [string]::Equals(([string]$_).Trim(), $expected, [System.StringComparison]::Ordinal) }).Count
    return ($count -eq 1 -and [string]::Equals(([string]$lines[-1]).Trim(), $expected, [System.StringComparison]::Ordinal))
}


function Get-YakuShortTextPreview {
    param([AllowNull()][string]$Text, [int]$MaxLength = 60)
    $s = ([string]$Text).Replace("`r", ' ').Replace("`n", ' ').Trim()
    if ($s.Length -le $MaxLength) { return $s }
    return $s.Substring(0, $MaxLength) + '...'
}


function Convert-YakuFileTranslationBrackets {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $dq = [string][char]34
    $s = $s.Replace('＜', '<').Replace('＞', '>')
    $s = $s.Replace('〈', '<').Replace('〉', '>')
    $s = $s.Replace('《', '<').Replace('》', '>')
    $s = $s.Replace('「', $dq).Replace('」', $dq)
    $s = $s.Replace('『', $dq).Replace('』', $dq)
    $s = $s.Replace('｢', $dq).Replace('｣', $dq)
    $s = $s.Replace('“', $dq).Replace('”', $dq)
    $s = $s.Replace('＂', $dq)
    $s = $s.Replace('（', '(').Replace('）', ')')
    return $s
}

function Get-YakuFileBracketPairs {
    $dq = [string][char]34
    $sq = [string][char]39
    return @(
        [pscustomobject]@{ Open='＜'; Close='＞'; TargetOpen='<'; TargetClose='>' },
        [pscustomobject]@{ Open='〈'; Close='〉'; TargetOpen='<'; TargetClose='>' },
        [pscustomobject]@{ Open='《'; Close='》'; TargetOpen='<'; TargetClose='>' },
        [pscustomobject]@{ Open='【'; Close='】'; TargetOpen='【'; TargetClose='】' },
        [pscustomobject]@{ Open='「'; Close='」'; TargetOpen=$dq; TargetClose=$dq },
        [pscustomobject]@{ Open='『'; Close='』'; TargetOpen=$dq; TargetClose=$dq },
        [pscustomobject]@{ Open='｢'; Close='｣'; TargetOpen=$dq; TargetClose=$dq },
        [pscustomobject]@{ Open='“'; Close='”'; TargetOpen=$dq; TargetClose=$dq },
        [pscustomobject]@{ Open='＂'; Close='＂'; TargetOpen=$dq; TargetClose=$dq },
        [pscustomobject]@{ Open='（'; Close='）'; TargetOpen='('; TargetClose=')' },
        [pscustomobject]@{ Open='('; Close=')'; TargetOpen='('; TargetClose=')' },
        [pscustomobject]@{ Open='['; Close=']'; TargetOpen='['; TargetClose=']' },
        [pscustomobject]@{ Open=$dq; Close=$dq; TargetOpen=$dq; TargetClose=$dq },
        [pscustomobject]@{ Open=$sq; Close=$sq; TargetOpen=$dq; TargetClose=$dq }
    )
}

function Get-YakuFileBracketStrippedTerm {
    param([AllowNull()][string]$Source)
    $text = ([string]$Source).Trim()
    $wrappers = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ HasBracket = $false; Inner = ''; Wrappers = @() }
    }

    for ($layer = 1; $layer -le 3; $layer++) {
        $matched = $false
        foreach ($pair in @(Get-YakuFileBracketPairs)) {
            $open = [string]$pair.Open
            $close = [string]$pair.Close
            if ([string]::IsNullOrEmpty($open) -or [string]::IsNullOrEmpty($close)) { continue }
            if ($text.Length -lt ($open.Length + $close.Length)) { continue }
            if ($text.StartsWith($open, [System.StringComparison]::Ordinal) -and $text.EndsWith($close, [System.StringComparison]::Ordinal)) {
                $innerLen = $text.Length - $open.Length - $close.Length
                if ($innerLen -lt 0) { continue }
                $inner = $text.Substring($open.Length, $innerLen).Trim()
                $wrappers.Add($pair) | Out-Null
                $text = $inner
                $matched = $true
                break
            }
        }
        if (-not $matched) { break }
    }

    return [pscustomobject]@{ HasBracket = ($wrappers.Count -gt 0); Inner = $text; Wrappers = @($wrappers.ToArray()) }
}

function New-YakuFileBracketWrappedTranslation {
    param(
        [AllowNull()][string]$InnerText,
        [AllowNull()][object[]]$Wrappers
    )
    $result = Convert-YakuFileTranslationBrackets -Text ([string]$InnerText)
    $wrapperList = @($Wrappers)
    for ($i = $wrapperList.Count - 1; $i -ge 0; $i--) {
        $w = $wrapperList[$i]
        $result = ([string]$w.TargetOpen) + $result + ([string]$w.TargetClose)
    }
    return (Convert-YakuFileTranslationBrackets -Text $result)
}


function Get-YakuFileAngleBracketPairs {
    return @(
        [pscustomobject]@{ Open='＜'; Close='＞'; TargetOpen='<'; TargetClose='>' },
        [pscustomobject]@{ Open='〈'; Close='〉'; TargetOpen='<'; TargetClose='>' },
        [pscustomobject]@{ Open='<'; Close='>'; TargetOpen='<'; TargetClose='>' },
        [pscustomobject]@{ Open='《'; Close='》'; TargetOpen='<'; TargetClose='>' }
    )
}

function Get-YakuFileAngleBracketUnwrap {
    param([AllowNull()][string]$Source)
    $text = ([string]$Source).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ HasAngleBracket=$false; Inner=''; WrapOpen=''; WrapClose=''; TargetOpen=''; TargetClose='' }
    }
    foreach ($pair in @(Get-YakuFileAngleBracketPairs)) {
        $open = [string]$pair.Open
        $close = [string]$pair.Close
        if ([string]::IsNullOrEmpty($open) -or [string]::IsNullOrEmpty($close)) { continue }
        if ($text.Length -lt ($open.Length + $close.Length + 1)) { continue }
        if (-not $text.StartsWith($open, [System.StringComparison]::Ordinal)) { continue }
        if (-not $text.EndsWith($close, [System.StringComparison]::Ordinal)) { continue }
        $innerLen = $text.Length - $open.Length - $close.Length
        if ($innerLen -le 0) { continue }
        $inner = $text.Substring($open.Length, $innerLen)
        if ([string]::IsNullOrWhiteSpace($inner)) { continue }
        # Safe-side rule: do not unwrap nested or ambiguous labels containing the same angle pair inside.
        if ($inner.IndexOf($open, [System.StringComparison]::Ordinal) -ge 0 -or $inner.IndexOf($close, [System.StringComparison]::Ordinal) -ge 0) { continue }
        return [pscustomobject]@{ HasAngleBracket=$true; Inner=$inner.Trim(); WrapOpen=$open; WrapClose=$close; TargetOpen=[string]$pair.TargetOpen; TargetClose=[string]$pair.TargetClose }
    }
    return [pscustomobject]@{ HasAngleBracket=$false; Inner=''; WrapOpen=''; WrapClose=''; TargetOpen=''; TargetClose='' }
}

function Get-YakuFileItemOriginalText {
    param([Parameter(Mandatory=$true)]$Item)
    try {
        if ($Item.PSObject.Properties.Name -contains 'OriginalText') { return [string]$Item.OriginalText }
    } catch {}
    return [string]$Item.Text
}

function Test-YakuFileItemAngleBracketUnwrapped {
    param([AllowNull()]$Item)
    try {
        if ($null -eq $Item) { return $false }
        if ($Item.PSObject.Properties.Name -notcontains 'AngleBracketUnwrapped') { return $false }
        return ([bool]$Item.AngleBracketUnwrapped)
    } catch { return $false }
}

function Write-YakuFileAngleBracketUnwrapLog {
    param(
        [AllowNull()][hashtable]$Context,
        [int]$Id,
        [AllowNull()][string]$Inner
    )
    try {
        if ($null -ne $Context) {
            if (-not $Context.ContainsKey('AngleBracketUnwrapLogged') -or $null -eq $Context['AngleBracketUnwrapLogged']) { $Context['AngleBracketUnwrapLogged'] = @{} }
            $key = [string]$Id
            if ($Context['AngleBracketUnwrapLogged'].ContainsKey($key)) { return }
            $Context['AngleBracketUnwrapLogged'][$key] = $true
        }
        $innerLog = (Get-YakuShortTextPreview -Text ([string]$Inner) -MaxLength 120).Replace("'", "''")
        Write-YakuLog "Angle-bracket unwrap applied. id=$Id inner='$innerLog'" 'INFO'
    } catch {}
}

function New-YakuFileAngleBracketUnwrappedItems {
    param(
        [AllowNull()][object[]]$Items,
        [AllowNull()][hashtable]$Context
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $source = Get-YakuFileItemOriginalText -Item $item
        $unwrap = Get-YakuFileAngleBracketUnwrap -Source $source
        if (-not $unwrap.HasAngleBracket) {
            $result.Add($item) | Out-Null
            continue
        }
        $blockIds = $null
        try { $blockIds = $item.BlockIds } catch { $blockIds = $null }
        if ($null -eq $blockIds) { $blockIds = New-Object System.Collections.Generic.List[string] }
        $unwrapped = [pscustomobject]@{
            Index = [int]$item.Index
            Text = [string]$unwrap.Inner
            BlockIds = $blockIds
            OriginalText = [string]$source
            AngleBracketUnwrapped = $true
            AngleBracketWrapOpen = [string]$unwrap.WrapOpen
            AngleBracketWrapClose = [string]$unwrap.WrapClose
            AngleBracketTargetOpen = [string]$unwrap.TargetOpen
            AngleBracketTargetClose = [string]$unwrap.TargetClose
        }
        Write-YakuFileAngleBracketUnwrapLog -Context $Context -Id ([int]$item.Index) -Inner ([string]$unwrap.Inner)
        $result.Add($unwrapped) | Out-Null
    }
    return @($result.ToArray())
}

function New-YakuFileBracketUnwrappedItems {
    param([AllowNull()][object[]]$Items, [AllowNull()][hashtable]$Context)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $source = Get-YakuFileItemOriginalText -Item $item
        $stripped = Get-YakuFileBracketStrippedTerm -Source $source
        if (-not $stripped.HasBracket -or [string]::IsNullOrWhiteSpace([string]$stripped.Inner)) { $result.Add($item) | Out-Null; continue }
        $blockIds = $null
        try { $blockIds = $item.BlockIds } catch { $blockIds = $null }
        if ($null -eq $blockIds) { $blockIds = New-Object System.Collections.Generic.List[string] }
        $result.Add([pscustomobject]@{
            Index=[int]$item.Index; Text=[string]$stripped.Inner; BlockIds=$blockIds
            OriginalText=[string]$source; BracketUnwrapped=$true; BracketWrappers=@($stripped.Wrappers)
        }) | Out-Null
        Write-YakuFileAngleBracketUnwrapLog -Context $Context -Id ([int]$item.Index) -Inner ([string]$stripped.Inner)
    }
    return @($result.ToArray())
}

function Test-YakuFileItemBracketUnwrapped {
    param([AllowNull()]$Item)
    try { return ($null -ne $Item -and $Item.PSObject.Properties.Name -contains 'BracketUnwrapped' -and [bool]$Item.BracketUnwrapped) } catch { return $false }
}

function Convert-YakuFileItemTranslationForOutput {
    param(
        [Parameter(Mandatory=$true)]$Item,
        [AllowNull()][string]$Translation
    )
    $result = Convert-YakuFileTranslationBrackets -Text ([string]$Translation)
    if (Test-YakuFileItemBracketUnwrapped -Item $Item) {
        $inner = $result.Trim()
        $result = New-YakuFileBracketWrappedTranslation -InnerText $inner -Wrappers @($Item.BracketWrappers)
    } elseif (Test-YakuFileItemAngleBracketUnwrapped -Item $Item) {
        $inner = $result.Trim()
        $alreadyWrapped = Get-YakuFileAngleBracketUnwrap -Source $inner
        if ($alreadyWrapped.HasAngleBracket) { $inner = [string]$alreadyWrapped.Inner }
        $result = ([string]$Item.AngleBracketTargetOpen) + $inner + ([string]$Item.AngleBracketTargetClose)
    }
    return (Convert-YakuFileTranslationBrackets -Text $result)
}

function Invoke-YakuFilePreBatchAngleBracketGlossaryFallback {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByIndex,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][int]$MaxChars,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$ProgressState,
        [Parameter(Mandatory=$true)][hashtable]$Context
    )
    $resolved = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $idx = [int]$item.Index
        $source = Get-YakuFileItemOriginalText -Item $item
        $unwrap = Get-YakuFileAngleBracketUnwrap -Source $source
        if (-not $unwrap.HasAngleBracket) { continue }
        $needsTranslation = (-not $TranslationByIndex.ContainsKey($idx)) -or (Test-YakuFileTranslationInvalid -Source $source -Translation ([string]$TranslationByIndex[$idx]) -Direction $Direction)
        if (-not $needsTranslation) { continue }

        $glossary = Resolve-YakuFileBracketGlossaryTranslation -Root $Root -Inner ([string]$unwrap.Inner) -Direction $Direction -Settings $Settings -Id $idx
        if (-not $glossary.Found) { continue }
        $innerTranslation = Convert-YakuFileTranslationBrackets -Text ([string]$glossary.Value)
        $candidate = Convert-YakuFileTranslationBrackets -Text (([string]$unwrap.TargetOpen) + $innerTranslation + ([string]$unwrap.TargetClose))
        if (Test-YakuFileTranslationInvalid -Source $source -Translation $candidate -Direction $Direction) { continue }

        $TranslationByIndex[$idx] = [string]$candidate
        $appliedMatches = New-Object System.Collections.Generic.List[object]
        foreach ($m in @($glossary.Matches)) {
            if ($null -eq $m) { continue }
            $row = 0
            try { $row = [int]$m.Row } catch { $row = 0 }
            $appliedMatches.Add([pscustomobject]@{ Source=[string]$m.Source; Target=[string]$m.Target; From=[string]$m.From; To=[string]$m.To; Row=$row; Via='bracket-fallback'; ItemIndex=$idx }) | Out-Null
        }
        if ($appliedMatches.Count -le 0) { $appliedMatches.Add([pscustomobject]@{ Source=[string]$unwrap.Inner; Target=[string]$glossary.Value; From=[string]$unwrap.Inner; To=[string]$glossary.Value; Via='bracket-fallback'; ItemIndex=$idx }) | Out-Null }
        Add-YakuFileAppliedGlossaryContext -Context $Context -Matches @($appliedMatches.ToArray())
        Set-YakuFileFallbackCacheValue -Item $item -Translation ([string]$candidate) -Settings $Settings -Direction $Direction
        Write-YakuFileBracketFallbackLog -Id $idx -Source $source -Result ([string]$candidate) -Via 'glossary'
        $resolved++
    }
    return [int]$resolved
}

function Get-YakuFileSupplementIdsPreview {
    param([AllowNull()][object[]]$Items, [int]$MaxCount = 30)
    $ids = @($Items | Select-Object -First $MaxCount | ForEach-Object { [string]([int]$_.Index) })
    $joined = ($ids -join ',')
    if (@($Items).Count -gt $MaxCount) { $joined += ',...' }
    return $joined
}

function Get-YakuFileSupplementTextPreview {
    param([AllowNull()][object[]]$Items, [int]$MaxCount = 5)
    $parts = @($Items | Select-Object -First $MaxCount | ForEach-Object {
        $source = Get-YakuFileItemOriginalText -Item $_
        ([string]([int]$_.Index)) + ':' + (Get-YakuShortTextPreview -Text $source -MaxLength 40)
    })
    $joined = ($parts -join '; ')
    if (@($Items).Count -gt $MaxCount) { $joined += '; ...' }
    return $joined
}

function Get-YakuFileExactGlossaryTranslation {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$Term,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()]$Settings
    )
    $useGlossary = $true
    try { $useGlossary = [bool]$Settings.use_bundled_glossary } catch { $useGlossary = $true }
    if (-not $useGlossary) { return [pscustomobject]@{ Found = $false; Value = '' } }

    $cleanTerm = ConvertTo-YakuGlossaryField -Value $Term
    if ([string]::IsNullOrWhiteSpace($cleanTerm)) { return [pscustomobject]@{ Found = $false; Value = '' } }
    $cleanKey = ConvertTo-YakuGlossaryMatchKey -Value $cleanTerm
    if ([string]::IsNullOrWhiteSpace($cleanKey)) { return [pscustomobject]@{ Found = $false; Value = '' } }

    foreach ($entry in @(Get-YakuGlossaryEntries -Root $Root -IncludeDuplicates | Sort-Object Row)) {
        $from = ''
        $to = ''
        if ($Direction -eq 'to_jp') {
            $from = ConvertTo-YakuGlossaryField -Value $entry.Target
            $to = ConvertTo-YakuGlossaryField -Value $entry.Source
        } else {
            $from = ConvertTo-YakuGlossaryField -Value $entry.Source
            $to = ConvertTo-YakuGlossaryField -Value $entry.Target
        }
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
        $fromKey = ConvertTo-YakuGlossaryMatchKey -Value $from
        if ([string]::Equals($fromKey, $cleanKey, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Found = $true; Value = [string]$to }
        }
    }

    return [pscustomobject]@{ Found = $false; Value = '' }
}

function Add-YakuFileAppliedGlossaryContext {
    param(
        [AllowNull()][hashtable]$Context,
        [AllowNull()][object[]]$Matches
    )
    if ($null -eq $Context) { return }
    if ($null -eq $Matches -or @($Matches).Count -le 0) { return }
    try {
        if (-not $Context.ContainsKey('AppliedGlossaryMatches') -or $null -eq $Context['AppliedGlossaryMatches']) {
            $Context['AppliedGlossaryMatches'] = New-Object System.Collections.Generic.List[object]
        }
        foreach ($match in @($Matches)) {
            if ($null -ne $match) { $Context['AppliedGlossaryMatches'].Add($match) | Out-Null }
        }
    } catch {}
}

function ConvertTo-YakuFileItemScopedGlossaryMatches {
    param(
        [AllowNull()][object[]]$Matches,
        [AllowNull()][object[]]$Items
    )
    $scoped = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $itemIndex = 0
        try { $itemIndex = [int]$item.Index } catch { $itemIndex = 0 }
        if ($itemIndex -le 0) { continue }
        $sourceText = [string]$item.Text
        foreach ($match in @($Matches)) {
            if ($null -eq $match) { continue }
            $from = if ($match.PSObject.Properties.Name -contains 'From') { [string]$match.From } else { [string]$match.Source }
            $to = if ($match.PSObject.Properties.Name -contains 'To') { [string]$match.To } else { [string]$match.Target }
            if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
            $scope = if ($match.PSObject.Properties.Name -contains 'Scope') { [string]$match.Scope } else { 'occurrence' }
            if ($scope -eq 'cell-exact') {
                $sourceKey = ConvertTo-YakuGlossaryMatchKey -Value $sourceText
                $fromExactKey = ConvertTo-YakuGlossaryMatchKey -Value $from
                if (-not [string]::Equals($sourceKey, $fromExactKey, [System.StringComparison]::Ordinal)) { continue }
                $positions = @(0)
            } else {
                $positions = @(Find-YakuExactTermIndexes -InputText $sourceText -Term $from)
                if ($positions.Count -le 0) { continue }
            }
            $key = ([string]$itemIndex) + '|' + (ConvertTo-YakuGlossaryMatchKey -Value $from) + '=>' + (ConvertTo-YakuGlossaryMatchKey -Value $to)
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $row = 0
            try { $row = [int]$match.Row } catch { $row = 0 }
            $via = ''
            try { $via = [string]$match.Via } catch { $via = '' }
            $scoped.Add([pscustomobject]@{
                Source = if ($match.PSObject.Properties.Name -contains 'Source') { [string]$match.Source } else { $from }
                Target = if ($match.PSObject.Properties.Name -contains 'Target') { [string]$match.Target } else { $to }
                From = $from
                To = $to
                Row = $row
                Via = $via
                Variants = if ($match.PSObject.Properties.Name -contains 'Variants') { [string[]]@($match.Variants) } else { [string[]]@($to) }
                Scope = [string]$scope
                ItemIndex = $itemIndex
                Positions = [int[]]@($positions)
                OccurrenceCount = [int]$positions.Count
            }) | Out-Null
        }
    }
    return @($scoped.ToArray())
}

function Join-YakuAppliedGlossaryEntries {
    param(
        [AllowNull()][object[]]$Primary,
        [AllowNull()][object[]]$Secondary
    )
    $items = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($entry in (@($Primary) + @($Secondary))) {
        if ($null -eq $entry) { continue }
        $from = if ($entry.PSObject.Properties.Name -contains 'From') { [string]$entry.From } else { [string]$entry.Source }
        $to = if ($entry.PSObject.Properties.Name -contains 'To') { [string]$entry.To } else { [string]$entry.Target }
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
        $itemIndex = 0
        try { if ($entry.PSObject.Properties.Name -contains 'ItemIndex') { $itemIndex = [int]$entry.ItemIndex } } catch { $itemIndex = 0 }
        $scopeKey = if ($itemIndex -gt 0) { "item:$itemIndex" } else { 'global' }
        $key = $scopeKey + '|' + (ConvertTo-YakuGlossaryMatchKey -Value $from) + '=>' + (ConvertTo-YakuGlossaryMatchKey -Value $to)
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $items.Add($entry) | Out-Null
    }
    return @($items.ToArray())
}

function Resolve-YakuFileExactGlossaryTranslations {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByIndex
    )
    $useGlossary = $true
    try { $useGlossary = [bool]$Settings.use_bundled_glossary } catch { $useGlossary = $true }
    if (-not $useGlossary) { return [pscustomobject]@{ Count=0; AppliedGlossary=@() } }

    $map = @{}
    foreach ($entry in @(Get-YakuGlossaryEntries -Root $Root | Sort-Object Row)) {
        $from = ''
        $to = ''
        if ($Direction -eq 'to_jp') {
            $from = ConvertTo-YakuGlossaryField -Value $entry.Target
            $to = ConvertTo-YakuGlossaryField -Value $entry.Source
        } else {
            $from = ConvertTo-YakuGlossaryField -Value $entry.Source
            $to = ConvertTo-YakuGlossaryField -Value $entry.Target
        }
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
        $key = ConvertTo-YakuGlossaryMatchKey -Value $from
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $map[$key] = [pscustomobject]@{ Source=[string]$entry.Source; Target=[string]$entry.Target; From=[string]$from; To=[string]$to; Row=[int]$entry.Row; Via='exact' }
    }

    $hits = 0
    $applied = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        $idx = [int]$item.Index
        if ($TranslationByIndex.ContainsKey($idx)) { continue }
        $cleanText = ConvertTo-YakuGlossaryField -Value ([string]$item.Text)
        if ([string]::IsNullOrWhiteSpace($cleanText)) { continue }
        $key = ConvertTo-YakuGlossaryMatchKey -Value $cleanText
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $map.ContainsKey($key)) { continue }
        $entry = $map[$key]
        $candidate = Convert-YakuFileTranslationBrackets -Text ([string]$entry.To)
        if (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation $candidate -Direction $Direction) { continue }
        $TranslationByIndex[$idx] = [string]$candidate
        $hits++
        $applied.Add([pscustomobject]@{ Source=[string]$entry.Source; Target=[string]$entry.Target; From=[string]$entry.From; To=[string]$candidate; Row=[int]$entry.Row; Via='exact'; ItemIndex=$idx }) | Out-Null
        try {
            $cacheKey = Get-YakuTranslationCacheKey -Kind 'file' -Direction $Direction -Text ([string]$item.Text) -Style 'concise' -Root $Root -Settings $Settings
            Set-YakuTranslationCacheValue -Key $cacheKey -Value ([string]$candidate) -Settings $Settings
        } catch {}
    }
    if ($hits -gt 0) {
        try { Write-YakuLog "File glossary exact hits: count=$hits" 'INFO' } catch {}
    }
    return [pscustomobject]@{ Count=[int]$hits; AppliedGlossary=@($applied.ToArray()) }
}

# 文であることを示す手がかり。ラベルにはまず現れない。
#
# 長さだけでは足りない。セルの中の短文は句点を持たないことが多く
# （「為替影響により営業利益が減少」）、文字数の上限だけでは拾ってしまう。
# 文の印。**途中一致**で見るので、正当なラベルに現れる語を入れてはいけない。
#
# 「による」を外した理由（2026-08-05 実機）:
#   連体修飾なので、後ろに名詞が来る。つまりラベルの一部である。
#     営業活動によるキャッシュ・フロー / 投資活動による… / 財務活動による…
#     持分法による投資利益 / 事業譲渡による損失 / 原価改善による増益
#   これらは英語にすると長くなる＝はみ出しやすい行そのものなのに、
#   途中一致で弾かれて一覧に出ず、取りこぼしに気づけなかった。
#   実機のファイル翻訳で 5/5 取りこぼすことを確認した。
#
#   「により」「によって」は連用修飾で、後ろに用言が来る＝文なので残す。
#   外して増える誤検出は「原価改善による増益」のような体言止めで、
#   これは増減要因表の行として実在するため、拾って困るものではない。
#   本当の文（為替影響により営業利益が減少）は、が/を と句読点の規則で従来どおり落ちる。
$script:YakuLabelSentenceMarkers = @(
    'により', 'によって', 'に伴い', 'に伴う', 'のため', 'ものの',
    'したが', 'ことで', 'ことにより', 'となり', 'となった', 'に対し'
)

# 述語で終わるもの。**末尾だけ**を見る。
# 途中に現れる活用（「非支配株主に帰属する当期純利益」の「帰属する」）は
# 正当なラベルの一部なので、途中一致で弾いてはいけない。
$script:YakuLabelPredicateEndings = @(
    'した', 'して', 'します', 'しました', 'される', 'された', 'できる', 'できない',
    'ている', 'ており', 'であった', 'である', 'だった', 'ました', 'ます', 'です',
    'ない', 'なった', 'なる'
)

function Test-YakuFileLabelLike {
    <#
      「列に収まることが求められる短いラベル」らしいか。

      拾いたいもの: 販売促進費 / 子会社 固定販促費 / 非支配株主に帰属する当期純利益
      拾いたくないもの: 為替影響により営業利益が減少 / コストを削減した

      判定は完全でなくてよい。ここで拾うのは「用語集へ足す候補」であり、
      間違って拾っても人が捨てるだけである。逆に取りこぼすと気づけない。

      ただし短すぎるものは別で、**短い順に並べる以上いちばん上に来てしまう。**
      実機では 科目・当期・前期 が上位を占めた（2026-08-05）。表の見出しであり
      用語集へ足したいものではないので、下限で落とす（利用者の指示）。
      下限は3文字。4にすると 売上高 が落ちる。

      MaxChars の既定は呼び出し側（Get-YakuFileUnmatchedLabels）と揃える。
      揃っていなかったため、引き継ぎ書が上限を 16 と誤って記録していた。
    #>
    param([AllowNull()][string]$Text, [int]$MaxChars = 24, [int]$MinChars = 3)
    $clean = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return $false }
    if ($clean.Length -lt $MinChars) { return $false }
    if ($clean.Length -gt $MaxChars) { return $false }
    # 改行を含むもの、文末記号や読点を持つものは文である。
    if ($clean -match "[`r`n]") { return $false }
    if ($clean -match '[。．！？、，]') { return $false }
    # 格助詞「を」「が」は文の印。ラベルにはまず現れない。
    if ($clean -match '[をが]') { return $false }
    foreach ($marker in $script:YakuLabelSentenceMarkers) {
        if ($clean.Contains($marker)) { return $false }
    }
    foreach ($ending in $script:YakuLabelPredicateEndings) {
        if ($clean.EndsWith($ending, [System.StringComparison]::Ordinal)) { return $false }
    }
    # 訳す対象が無いもの（数字・記号だけ）は除く。
    if ($clean -notmatch '[ぁ-んァ-ヶ一-龯㐀-䶵々〆]') { return $false }
    return $true
}

function Get-YakuFileUnmatchedLabels {
    <#
      完全一致の用語集に載っていなかった短いラベルを集める。

      なぜこれを出すのか:
        ファイル翻訳の完全一致置換（cell-exact）は、実運用では
        **「はみ出さないことの保証」**として使われている。過去のラベルは
        その列に収まっていたから採用されたので、同じ訳語なら必ず収まる。

        したがって保証が効くのは「ラベルが変わらない限り」であり、
        **新しいラベルが出た瞬間に保証が消える。しかもそれが見えない。**

        用語集を網羅的に書こうとすると終わらないが、資料1本ごとに
        新しく出るラベルは有限である。それを見せれば運用が閉じる。

      JA→EN のときだけ出す。英語のほうが長くなりやすく、
      はみ出しが問題になるのはその向きだから。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [AllowNull()][object[]]$ExactApplied,
        [AllowNull()][string]$Direction,
        [int]$MaxChars = 24,
        # 短すぎるものは表の見出し（科目・当期・前期）で、用語集へ足す候補ではない。
        # 短い順に並べる以上いちばん上へ来てしまうので、ここで落とす。
        [int]$MinChars = 3
    )
    $result = New-Object System.Collections.Generic.List[object]
    if ([string]$Direction -ne 'to_en') { return @($result.ToArray()) }
    $matched = @{}
    foreach ($applied in @($ExactApplied)) {
        if ($null -eq $applied) { continue }
        try { $matched[[int]$applied.ItemIndex] = $true } catch {}
    }
    $seen = @{}
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $idx = 0
        try { $idx = [int]$item.Index } catch { continue }
        if ($matched.ContainsKey($idx)) { continue }
        # マスク前の原文で見る。置換の突き合わせも原文で行っているため。
        $text = ''
        try { $text = [string]$item.OriginalText } catch { $text = '' }
        if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$item.Text }
        if (-not (Test-YakuFileLabelLike -Text $text -MaxChars $MaxChars -MinChars $MinChars)) { continue }
        $key = ConvertTo-YakuGlossaryMatchKey -Value $text
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$result.Add([pscustomobject]@{ Index = $idx; Text = ([string]$text).Trim() })
    }
    # 短い順に出す。判定が完全でない以上、誤って拾ったもの（長めの短文）が
    # 上位を占めないようにしておく。上から見れば用が足りる並びにする。
    return @(@($result.ToArray()) | Sort-Object -Property @{Expression={ ([string]$_.Text).Length }}, @{Expression='Index'})
}

function Write-YakuFileBracketFallbackLog {
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Result,
        [Parameter(Mandatory=$true)][ValidateSet('glossary','copilot-retry')][string]$Via
    )
    try {
        $src = (Get-YakuShortTextPreview -Text ([string]$Source) -MaxLength 120).Replace("'", "''")
        $res = (Get-YakuShortTextPreview -Text ([string]$Result) -MaxLength 120).Replace("'", "''")
        Write-YakuLog "Bracket-glossary fallback applied. id=$Id source='$src' result='$res' via=$Via" 'INFO'
    } catch {}
}

function Add-YakuSupplementPassFailure {
    param(
        [Parameter(Mandatory=$true)]$Warnings,
        [int]$RemainingCount = 0,
        [AllowNull()][string]$ErrorMessage,
        [AllowNull()][string]$Location = 'supplement',
        [switch]$AddUserWarning
    )
    $remaining = [Math]::Max(0, [int]$RemainingCount)
    $err = [string]$ErrorMessage
    if ([string]::IsNullOrWhiteSpace($err)) { $err = 'unknown error' }
    $err = $err.Replace("`r", ' ').Replace("`n", ' ')
    try { Write-YakuLog "Supplement pass failed (non-fatal). remaining=$remaining error=$err" 'WARN' } catch {}
    if ($AddUserWarning) {
        Add-YakuSupplementOriginalRetainedWarning -Warnings $Warnings -Count $remaining -Location $Location -ErrorMessage $err
    }
}

function Add-YakuSupplementFailureRetainCandidate {
    param(
        [AllowNull()][hashtable]$Context,
        [AllowNull()][object[]]$Items,
        [AllowNull()][int[]]$Indexes
    )
    if ($null -eq $Context) { return }
    try {
        if (-not $Context.ContainsKey('SupplementFailureRetainLookup') -or $null -eq $Context['SupplementFailureRetainLookup']) {
            $Context['SupplementFailureRetainLookup'] = @{}
        }
        foreach ($item in @($Items)) {
            if ($null -eq $item) { continue }
            $Context['SupplementFailureRetainLookup'][[string]([int]$item.Index)] = $true
        }
        foreach ($idx in @($Indexes)) { if ($null -ne $idx) { $Context['SupplementFailureRetainLookup'][[string]([int]$idx)] = $true } }
    } catch {}
}

function Test-YakuSupplementFailureRetainCandidate {
    param(
        [AllowNull()][hashtable]$Context,
        [int]$Index
    )
    try {
        if ($null -eq $Context) { return $false }
        if (-not $Context.ContainsKey('SupplementFailureRetainLookup') -or $null -eq $Context['SupplementFailureRetainLookup']) { return $false }
        return [bool]$Context['SupplementFailureRetainLookup'].ContainsKey([string]$Index)
    } catch { return $false }
}

function Add-YakuSupplementOriginalRetainedWarning {
    param(
        [Parameter(Mandatory=$true)]$Warnings,
        [int]$Count = 0,
        [AllowNull()][string]$Location = 'original-retain',
        [AllowNull()][string]$ErrorMessage = ''
    )
    $countValue = [Math]::Max(0, [int]$Count)
    if ($countValue -le 0) { return }
    $details = @{ Count=$countValue; NonFatal=$true }
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorMessage)) { $details['Error'] = [string]$ErrorMessage }
    Add-YakuWarning -Warnings $Warnings -Category 'supplement-pass' -Location $Location -Details $details -Message "${countValue}件は翻訳を取得できなかったため原文を保持しました(補完パス失敗)"
}

function Set-YakuFileFallbackCacheValue {
    param(
        [Parameter(Mandatory=$true)]$Item,
        [Parameter(Mandatory=$true)][string]$Translation,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    try {
        $cacheKey = Get-YakuTranslationCacheKey -Kind 'file' -Direction $Direction -Text ([string]$Item.Text) -Style 'concise' -Settings $Settings
        Set-YakuTranslationCacheValue -Key $cacheKey -Value $Translation -Settings $Settings
    } catch {}
}

function Test-YakuFileAsciiJoinBoundary {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )
    $l = [string]$Left
    $r = [string]$Right
    if ([string]::IsNullOrEmpty($l) -or [string]::IsNullOrEmpty($r)) { return $false }
    $last = [string]$l[$l.Length - 1]
    $first = [string]$r[0]
    return (($last -match '[A-Za-z0-9]') -and ($first -match '[A-Za-z0-9]'))
}

function Join-YakuFileGlossaryTranslatedSegments {
    param([Parameter(Mandatory=$true)][object[]]$Segments)
    $result = New-Object System.Text.StringBuilder
    foreach ($seg in @($Segments)) {
        if ($null -eq $seg) { continue }
        $text = [string]$seg.Text
        if ([string]::IsNullOrEmpty($text)) { continue }
        if ($result.Length -gt 0) {
            $current = $result.ToString()
            if (Test-YakuFileAsciiJoinBoundary -Left $current -Right $text) { [void]$result.Append(' ') }
        }
        [void]$result.Append($text)
    }
    $joined = [string]$result.ToString()
    $joined = [regex]::Replace($joined, '[\s　]+', ' ')
    $joined = [regex]::Replace($joined, '\s+([,.;:!?)\]}>】])', '$1')
    $joined = [regex]::Replace($joined, '([(<\[{【])\s+', '$1')
    return $joined.Trim()
}

function Resolve-YakuFileBracketGlossaryTranslation {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$Inner,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()]$Settings,
        [int]$Id = 0
    )
    $innerText = ConvertTo-YakuGlossaryField -Value $Inner
    if ([string]::IsNullOrWhiteSpace($innerText)) { return [pscustomobject]@{ Found=$false; Value=''; Matches=@() } }

    $exact = Get-YakuFileExactGlossaryTranslation -Root $Root -Term $innerText -Direction $Direction -Settings $Settings
    if ($exact.Found) {
        return [pscustomobject]@{ Found=$true; Value=[string]$exact.Value; Matches=@([pscustomobject]@{ Source=[string]$innerText; Target=[string]$exact.Value; From=[string]$innerText; To=[string]$exact.Value; Row=0 }) }
    }

    $matches = @(Get-YakuRelevantGlossaryMatches -Root $Root -InputText $innerText -Direction $Direction -Limit 12)
    if ($matches.Count -le 0) { return [pscustomobject]@{ Found=$false; Value=''; Matches=@() } }

    $normalizedInner = ConvertTo-YakuGlossaryField -Value $innerText
    try { $normalizedInner = $normalizedInner.Normalize([System.Text.NormalizationForm]::FormKC) } catch {}
    if ([string]::IsNullOrWhiteSpace($normalizedInner)) { return [pscustomobject]@{ Found=$false; Value=''; Matches=@() } }

    $intervals = New-Object System.Collections.Generic.List[object]
    foreach ($match in @($matches | Sort-Object -Property @{ Expression = { 999999 - [int]$_.NormLength } }, Row)) {
        $from = ConvertTo-YakuGlossaryField -Value ([string]$match.From)
        if ([string]::IsNullOrWhiteSpace($from)) { continue }
        $fromNorm = $from
        try { $fromNorm = $fromNorm.Normalize([System.Text.NormalizationForm]::FormKC) } catch {}
        $positions = @(Find-YakuExactTermIndexes -InputText $normalizedInner -Term $fromNorm)
        foreach ($pos in @($positions)) {
            $start = [int]$pos
            $end = [int]($start + [int]$fromNorm.Length)
            $overlap = $false
            foreach ($existing in @($intervals.ToArray())) {
                if ($start -lt [int]$existing.End -and [int]$existing.Start -lt $end) { $overlap = $true; break }
            }
            if ($overlap) { continue }
            $intervals.Add([pscustomobject]@{ Start=$start; End=$end; To=(Convert-YakuFileTranslationBrackets -Text ([string]$match.To)); Match=$match }) | Out-Null
        }
    }
    if ($intervals.Count -le 0) { return [pscustomobject]@{ Found=$false; Value=''; Matches=@() } }

    $segments = New-Object System.Collections.Generic.List[object]
    $applied = New-Object System.Collections.Generic.List[object]
    $cursor = 0
    foreach ($interval in @($intervals.ToArray() | Sort-Object Start)) {
        $start = [int]$interval.Start
        $end = [int]$interval.End
        if ($start -gt $cursor) { $segments.Add([pscustomobject]@{ Text=$normalizedInner.Substring($cursor, $start - $cursor); Replacement=$false }) | Out-Null }
        $segments.Add([pscustomobject]@{ Text=[string]$interval.To; Replacement=$true }) | Out-Null
        $m = $interval.Match
        $row = 0
        try { $row = [int]$m.Row } catch { $row = 0 }
        $applied.Add([pscustomobject]@{ Source=[string]$m.Source; Target=[string]$m.Target; From=[string]$m.From; To=[string]$m.To; Row=$row }) | Out-Null
        $cursor = $end
    }
    if ($cursor -lt $normalizedInner.Length) { $segments.Add([pscustomobject]@{ Text=$normalizedInner.Substring($cursor); Replacement=$false }) | Out-Null }

    $uncoveredText = (@($segments.ToArray() | Where-Object { -not [bool]$_.Replacement } | ForEach-Object { [string]$_.Text }) -join '')
    $partialCoverage = if ($Direction -eq 'to_en') {
        Test-YakuHasJapaneseChars -Text $uncoveredText
    } else {
        [regex]::IsMatch($uncoveredText, '[A-Za-z]{4,}')
    }
    if ($partialCoverage) {
        try {
            $innerPreview = (Get-YakuShortTextPreview -Text $normalizedInner -MaxLength 120).Replace("'", "''")
            $uncoveredPreview = (Get-YakuShortTextPreview -Text $uncoveredText -MaxLength 120).Replace("'", "''")
            Write-YakuLog "Bracket-glossary fallback skipped (partial coverage). id=$Id inner='$innerPreview' uncovered='$uncoveredPreview'" 'INFO'
        } catch {}
        return [pscustomobject]@{ Found=$false; Value=''; Matches=@() }
    }

    $candidate = Join-YakuFileGlossaryTranslatedSegments -Segments @($segments.ToArray())
    if ([string]::IsNullOrWhiteSpace($candidate)) { return [pscustomobject]@{ Found=$false; Value=''; Matches=@() } }
    return [pscustomobject]@{ Found=$true; Value=[string]$candidate; Matches=@($applied.ToArray()) }
}

function Invoke-YakuFileBracketFallback {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Item,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByIndex,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][int]$MaxChars,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$ProgressState,
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [switch]$GlossaryOnly
    )
    $idx = [int]$Item.Index
    $source = [string]$Item.Text
    $stripped = Get-YakuFileBracketStrippedTerm -Source $source
    if (-not $stripped.HasBracket) { return $false }
    $inner = ([string]$stripped.Inner).Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) { return $false }

    $glossary = Resolve-YakuFileBracketGlossaryTranslation -Root $Root -Inner $inner -Direction $Direction -Settings $Settings -Id $idx
    if ($glossary.Found) {
        $candidate = New-YakuFileBracketWrappedTranslation -InnerText ([string]$glossary.Value) -Wrappers @($stripped.Wrappers)
        if (-not (Test-YakuFileTranslationInvalid -Source $source -Translation $candidate -Direction $Direction)) {
            $TranslationByIndex[$idx] = [string]$candidate
            $appliedMatches = New-Object System.Collections.Generic.List[object]
            foreach ($m in @($glossary.Matches)) {
                if ($null -eq $m) { continue }
                $row = 0
                try { $row = [int]$m.Row } catch { $row = 0 }
                $appliedMatches.Add([pscustomobject]@{ Source=[string]$m.Source; Target=[string]$m.Target; From=[string]$m.From; To=[string]$m.To; Row=$row; Via='bracket-fallback'; ItemIndex=$idx }) | Out-Null
            }
            if ($appliedMatches.Count -le 0) { $appliedMatches.Add([pscustomobject]@{ Source=[string]$inner; Target=[string]$glossary.Value; From=[string]$inner; To=[string]$glossary.Value; Via='bracket-fallback'; ItemIndex=$idx }) | Out-Null }
            Add-YakuFileAppliedGlossaryContext -Context $Context -Matches @($appliedMatches.ToArray())
            Set-YakuFileFallbackCacheValue -Item $Item -Translation ([string]$candidate) -Settings $Settings -Direction $Direction
            Write-YakuFileBracketFallbackLog -Id $idx -Source $source -Result ([string]$candidate) -Via 'glossary'
            return $true
        }
    }
    if ($GlossaryOnly) { return $false }

    try {
        $supplementMax = [Math]::Max(300, [int][Math]::Floor($MaxChars / 2))
        $retryItem = [pscustomobject]@{ Index = $idx; Text = $inner; BlockIds = (New-Object System.Collections.Generic.List[string]) }
        $Context['FailedItems'] = New-Object System.Collections.Generic.List[object]
        $Context['FailedLookup'] = @{}
        $translated = Invoke-YakuFileTranslationItems -Root $Root -Items @($retryItem) -Settings $Settings -Direction $Direction -MaxChars $supplementMax -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth 0 -Reason 'supplement'
        if ($translated.ContainsKey($idx)) {
            $innerTranslation = Convert-YakuFileTranslationBrackets -Text ([string]$translated[$idx])
            if (-not (Test-YakuFileTranslationInvalid -Source $inner -Translation $innerTranslation -Direction $Direction)) {
                $candidate = New-YakuFileBracketWrappedTranslation -InnerText $innerTranslation -Wrappers @($stripped.Wrappers)
                if (-not (Test-YakuFileTranslationInvalid -Source $source -Translation $candidate -Direction $Direction)) {
                    $TranslationByIndex[$idx] = [string]$candidate
                    Set-YakuFileFallbackCacheValue -Item $Item -Translation ([string]$candidate) -Settings $Settings -Direction $Direction
                    Write-YakuFileBracketFallbackLog -Id $idx -Source $source -Result ([string]$candidate) -Via 'copilot-retry'
                    return $true
                }
            }
        }
    } catch {
        Add-YakuSupplementPassFailure -Warnings $Warnings -RemainingCount 1 -ErrorMessage ([string]$_.Exception.Message) -Location ("ID $idx")
        Add-YakuSupplementFailureRetainCandidate -Context $Context -Indexes @($idx)
    }

    return $false
}

function Parse-YakuNumberedBatchResponse {
    param(
        [Parameter(Mandatory=$true)][string]$Raw,
        [Parameter(Mandatory=$true)][int[]]$ExpectedIds,
        [Parameter(Mandatory=$true)][string]$RequestId
    )
    $expectedIdList = @($ExpectedIds | ForEach-Object { [int]$_ })
    if ($expectedIdList.Count -le 0) { throw 'FILE_RESPONSE_EXPECTED_IDS_EMPTY: 期待する応答IDがありません。' }
    if (@($expectedIdList | Sort-Object -Unique).Count -ne $expectedIdList.Count) { throw 'FILE_RESPONSE_EXPECTED_IDS_DUPLICATE: 期待する応答IDが重複しています。' }
    $hasEndMarker = Test-YakuFileResponseCompleted -Text $Raw -RequestId $RequestId
    if (-not $hasEndMarker) { throw 'FILE_RESPONSE_END_MARKER_INVALID: 要求ID付き終端マーカーが最終行にありません。' }
    if ($Raw -match '(?i)\b(i\s+cannot|i\s+can''t|unable\s+to|as\s+an\s+ai|sign\s+in|log\s*in|required\s+login|content\s+policy|against\s+(?:the\s+)?policy|due\s+to\s+(?:the\s+)?policy|policy\s+(?:prevents|does\s+not\s+allow))\b|申し訳|ログインしてください|対応できません') {
        throw 'COPILOT_REFUSAL_OR_LOGIN: 翻訳ではない拒否・ログイン要求を検出しました。'
    }
    $clean = Normalize-YakuCopilotPlainResponse -Raw $Raw
    $clean = [regex]::Replace($clean, ('(?im)^\s*' + [regex]::Escape('YAKULINGO_END:' + $RequestId) + '\s*$'), '')
    $clean = [regex]::Replace($clean, '(?is)^\s*```(?:text|plain)?\s*', '')
    $clean = [regex]::Replace($clean, '(?is)\s*```\s*$', '')
    $clean = $clean.Replace("`r`n", "`n").Replace("`r", "`n").Trim()
    if (-not [regex]::IsMatch($clean, '^\s*\[\[ID:\d+\]\]\s*\d+\.')) { throw 'FILE_RESPONSE_PREFIX_INVALID: 応答は最初のIDタグから開始する必要があります。' }

    $items = @{}
    $duplicateIds = New-Object System.Collections.Generic.List[int]
    $observedIds = New-Object System.Collections.Generic.List[int]

    if (-not [regex]::IsMatch($clean, '\[\[ID:\d+\]\]')) { throw 'FILE_RESPONSE_ID_TAG_MISSING: 応答IDタグがありません。' }
    $segments = [regex]::Split($clean, '(?=\[\[ID:\d+\]\])')
    foreach ($segment in @($segments)) {
        if ([string]::IsNullOrWhiteSpace([string]$segment)) { continue }
        $m = [regex]::Match([string]$segment, '(?s)^\s*\[\[ID:(\d+)\]\]\s*(\d+)\.\s*(.*)$')
        if (-not $m.Success) { throw 'FILE_RESPONSE_SEGMENT_INVALID: ID区切りの形式が不正です。' }
        $id = [int]$m.Groups[1].Value
        if ([int]$m.Groups[2].Value -ne $id) { throw 'FILE_RESPONSE_NUMBER_ID_MISMATCH: 応答番号とIDが一致しません。' }
        if ($items.ContainsKey($id)) { $duplicateIds.Add($id) | Out-Null; continue }
        $observedIds.Add($id) | Out-Null
        $value = [string]$m.Groups[3].Value
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'FILE_RESPONSE_ITEM_EMPTY: 翻訳文が空のIDがあります。' }
        $items[$id] = Convert-YakuFileTranslationBrackets -Text ($value.Trim())
    }

    $missingIds = New-Object System.Collections.Generic.List[int]
    foreach ($expectedId in $expectedIdList) {
        if (-not $items.ContainsKey([int]$expectedId)) { $missingIds.Add([int]$expectedId) | Out-Null }
    }
    $extraIds = New-Object System.Collections.Generic.List[int]
    foreach ($key in @($items.Keys)) {
        if ($expectedIdList -notcontains [int]$key) { $extraIds.Add([int]$key) | Out-Null; $items.Remove($key) }
    }
    $orderValid = $true
    if ($observedIds.Count -ne $expectedIdList.Count) { $orderValid = $false }
    else {
        for ($i = 0; $i -lt $observedIds.Count; $i++) { if ([int]$observedIds[$i] -ne [int]$expectedIdList[$i]) { $orderValid = $false; break } }
    }
    if ($duplicateIds.Count -gt 0) { throw 'FILE_RESPONSE_DUPLICATE_ID: 応答IDが重複しています。' }
    if ($missingIds.Count -gt 0) { throw 'FILE_RESPONSE_MISSING_ID: 必須の応答IDが不足しています。' }
    if ($extraIds.Count -gt 0) { throw 'FILE_RESPONSE_UNEXPECTED_ID: 要求していない応答IDが含まれています。' }
    if (-not $orderValid) { throw 'FILE_RESPONSE_ORDER_INVALID: 応答IDの順序が不正です。' }
    return [pscustomobject]@{
        Items = $items
        MissingIds = @($missingIds.ToArray())
        MissingCount = $missingIds.Count
        ExtraIds = @($extraIds.ToArray())
        ExtraCount = $extraIds.Count
        ReceivedCount = $items.Count
        HasEndMarker = $hasEndMarker
        DuplicateIds = @($duplicateIds.ToArray())
        OrderValid = $orderValid
        RawClean = $clean.Trim()
    }
}

function Test-YakuProtectedFileText {
    param([AllowNull()][string]$Text)
    $s = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    if ($s.StartsWith('=')) { return $true }
    if ($s -match '^(?i:https?://|mailto:|www\.)\S+$' -or $s -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') { return $true }
    if ($s -match '^[\d\s.,%+\-()△▲▼＋−]+$') { return $true }
    if ($s -match '^[A-Z0-9][A-Z0-9._+%/&()\-]{0,40}$') { return $true }
    return $false
}

function Test-YakuFileTranslationInvalid {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [AllowNull()][string]$Translation,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    return (-not [string]::IsNullOrWhiteSpace((Get-YakuFileTranslationInvalidReason -Source $Source -Translation $Translation -Direction $Direction)))
}

function Get-YakuFileTranslationInvalidReason {
    param([Parameter(Mandatory=$true)][string]$Source, [AllowNull()][string]$Translation, [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction)
    if ([string]::IsNullOrWhiteSpace($Translation)) { return 'empty' }
    $t = ([string]$Translation).Trim()
    $sourceTrimmed = ([string]$Source).Trim()
    if ($t -eq $sourceTrimmed) {
        if (Test-YakuProtectedFileText -Text $sourceTrimmed) { return '' }
        return 'same-as-source'
    }
    if ($t -match '(?i)\b(i\s+cannot|i\s+can''t|unable\s+to|as\s+an\s+ai|sign\s+in|log\s*in|required\s+login|content\s+policy|against\s+(?:the\s+)?policy|due\s+to\s+(?:the\s+)?policy|policy\s+(?:prevents|does\s+not\s+allow))\b|申し訳|ログインしてください|対応できません') { return 'error-or-refusal-text' }
    if ($Direction -eq 'to_en' -and (Test-YakuHasJapaneseChars -Text $t)) {
        $jpMatches = @([regex]::Matches($t, '[ぁ-んァ-ヶ一-龯]+'))
        $jp = [regex]::Matches($t, '[ぁ-んァ-ヶ一-龯]').Count
        $latin = [regex]::Matches($t, '[A-Za-z]').Count
        $unprotectedJp = 0
        foreach ($match in $jpMatches) {
            if (-not $sourceTrimmed.Contains([string]$match.Value)) { $unprotectedJp += ([string]$match.Value).Length }
        }
        $ratio = $jp / [double][Math]::Max(1, $jp + $latin)
        $protectedProperNounException = ($unprotectedJp -eq 0 -and $jp -le 12 -and $latin -ge 6)
        if ($latin -le 0 -or (($ratio -gt 0.35 -or ($unprotectedJp / [double][Math]::Max(1, $unprotectedJp + $latin)) -gt 0.20) -and -not $protectedProperNounException)) { return 'unexpected-language-ratio' }
    }
    if ($Direction -eq 'to_en' -and (Test-YakuHasHangulChars -Text $t)) { return 'hangul-chars' }
    if ($Direction -eq 'to_jp' -and (Test-YakuHasLatinChars -Text $Source) -and -not (Test-YakuHasJapaneseChars -Text $t) -and [regex]::Matches($t, '[A-Za-z]').Count -ge 4) { return 'unexpected-language-ratio' }
    return ''
}

function Write-YakuFileInvalidItemLog {
    param([Parameter(Mandatory=$true)]$Item, [Parameter(Mandatory=$true)][string]$Source, [AllowNull()][string]$Translation, [Parameter(Mandatory=$true)][string]$Direction)
    $reason = Get-YakuFileTranslationInvalidReason -Source $Source -Translation $Translation -Direction $Direction
    if ([string]::IsNullOrWhiteSpace($reason)) { return }
    $src = (Get-YakuShortTextPreview -Text $Source -MaxLength 60).Replace("'", "''")
    $preview = (Get-YakuShortTextPreview -Text ([string]$Translation) -MaxLength 60).Replace("'", "''")
    try { Write-YakuLog "File item invalid. id=$([int]$Item.Index) reason=$reason source='$src' translationPreview='$preview'" 'INFO' } catch {}
}

function Add-YakuFileFailedItem {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)]$Item
    )
    if (-not $Context.ContainsKey('FailedItems') -or $null -eq $Context['FailedItems']) { $Context['FailedItems'] = New-Object System.Collections.Generic.List[object] }
    if (-not $Context.ContainsKey('FailedLookup') -or $null -eq $Context['FailedLookup']) { $Context['FailedLookup'] = @{} }
    $key = [string]$Item.Index
    if (-not $Context['FailedLookup'].ContainsKey($key)) {
        $Context['FailedItems'].Add($Item) | Out-Null
        $Context['FailedLookup'][$key] = $true
    }
}

function Get-YakuCopilotCompletedByForLastCall {
    try {
        if ($script:YakuLastCopilotWaitResult) {
            $v = $script:YakuLastCopilotWaitResult.completedBy
            if (![string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
            $r = $script:YakuLastCopilotWaitResult.reason
            if (![string]::IsNullOrWhiteSpace([string]$r)) { return [string]$r }
        }
    } catch {}
    return 'mock-or-unavailable'
}

function Invoke-YakuFileTranslationItems {
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
    $map = @{}
    if ($Items.Count -le 0) { return $map }
    if (-not $Context.ContainsKey('FailedItems') -or $null -eq $Context['FailedItems']) { $Context['FailedItems'] = New-Object System.Collections.Generic.List[object] }
    if (-not $Context.ContainsKey('FailedLookup') -or $null -eq $Context['FailedLookup']) { $Context['FailedLookup'] = @{} }
    $batches = @(Split-YakuFileTranslationItems -Items $Items -MaxChars $MaxChars)
    if ($Depth -gt 0 -or $Reason -eq 'supplement') {
        # リトライ/補完で発生した追加バッチ分を分母へ計上する。
        # 消費済みの親バッチ1件はすでに BatchOrdinal に計上されている。
        $Context['TotalBatches'] = [int]$Context['TotalBatches'] + [int]$batches.Count
    }
    foreach ($batch in $batches) {
        $Context['BatchOrdinal'] = [int]$Context['BatchOrdinal'] + 1
        $ord = [int]$Context['BatchOrdinal']
        $total = [int]$Context['TotalBatches']
        if ($total -lt $ord) {
            try { Write-YakuLog "File batch progress total clamped. ordinal=$ord totalBefore=$total reason=$Reason depth=$Depth" 'DEBUG' } catch {}
            $total = $ord
            $Context['TotalBatches'] = $total
        }
        if (-not $Context.ContainsKey('StartedAt')) { $Context['StartedAt'] = Get-Date }
        $pct = Get-YakuFileUniqueProgressPercent -Context $Context
        $cacheHits = 0
        try { $cacheHits = [int]$Context['CacheHits'] } catch { $cacheHits = 0 }
        $phaseLabel = if ($Reason -eq 'supplement') { '翻訳中（補完）' } else { '翻訳中' }
        # 数十分のあいだ、利用者が見つづける唯一の行になる。日本語で書く。
        # 「cache hits」は「前回の結果を使い回した件数」のこと。
        $detail = "$total 回のうち $ord 回目を翻訳中（$($batch.CharCount)字）"
        if ($cacheHits -gt 0) { $detail += "。$cacheHits 件は前回の結果を再利用しました" }
        $detail += "。" + (Get-YakuFileRemainingHint -Context $Context -Current $ord -Total $total)
        Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'translate' -Label $phaseLabel -Progress $pct -Detail $detail -Fields (Get-YakuFileUniqueProgressFields -Context $Context -BatchCurrent $ord -BatchTotal $total)
        if ($ProgressState) {
            $nextPct = [Math]::Min(90, [Math]::Max($pct + 1, [int](8 + [Math]::Floor((($Context['TranslatedSoFar'] + @($batch.Items).Count) / [double][Math]::Max(1, $Context['UniqueTotal'])) * 82))))
            $ProgressState['batch_progress_start'] = $pct
            $ProgressState['batch_progress_end'] = $nextPct
            $ProgressState['file_progress_prefix'] = "$phaseLabel (バッチ $ord/$total)"
        }

        $sourceList = New-YakuFileSourceList -Items @($batch.Items)
        $batchInputChars = [int]([string]$sourceList).Length
        if ($ProgressState) {
            $ratio = 1.7; $base = 0.0
            try { if ($Settings.copilotAnswerRatioFile) { $ratio = [double]$Settings.copilotAnswerRatioFile } } catch {}
            try { if ($Settings.copilotAnswerBaseFile)  { $base  = [double]$Settings.copilotAnswerBaseFile } } catch {}
            $ratioCount = 0; $ratioSum = 0.0
            try { $ratioCount = [int]$ProgressState['answer_ratio_count']; $ratioSum = [double]$ProgressState['answer_ratio_sum'] } catch {}
            if ($ratioCount -gt 0) { $ratio = $ratioSum / $ratioCount; $base = 0.0 }
            $ProgressState['batch_input_length'] = $batchInputChars
            $ProgressState['batch_expected_chars'] = [Math]::Max(1.0, $base + ([double]$batchInputChars * $ratio))
        }
        # プロンプト用語集からの照合は廃止した（利用者の判断 2026-08-06）。
        # 置換していない語を「適用された用語」として集めていただけで、保証ではない。
        # 実際に置換したもの（セル完全一致・括弧フォールバック）だけを記録する。
        $raw = ''
        $requestId = ''
        $parsed = $null
        $contractError = $null
        $contractMaxAttempts = 2
        $silentStartFailures = 0
        $sendStartFailures = 0
        for ($contractAttempt = 1; $contractAttempt -le $contractMaxAttempts; $contractAttempt++) {
            $requestId = [guid]::NewGuid().ToString('N')
            $prompt = New-YakuFilePrompt -Root $Root -Items @($batch.Items) -Settings $Settings -Direction $Direction -RequestId $requestId -CorpusSection ([string]$Context['CorpusSection'])
            $skipFresh = ([int]$Context['CopilotCalls'] -gt 0)
            $Context['CopilotCalls'] = [int]$Context['CopilotCalls'] + 1
            try {
                $raw = Invoke-YakuCopilotPrompt -Prompt $prompt -Settings $Settings -SkipFreshChatWait:$skipFresh -AnswerFormat numbered -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
            } catch {
                $copilotError = [string]$_.Exception.Message
                $isSendStartFailure = ($copilotError -match 'COPILOT_SEND_NOT_CONFIRMED|verified-send-button.*did-not-start-send|all-send-stages-did-not-start-send')
                if ($isSendStartFailure) {
                    $sendStartFailures++
                    $contractError = $_
                    try { Write-YakuLog "File Copilot send-start recovery retry. batch=$ord/$total attempt=$contractAttempt sendFailures=$sendStartFailures maxRetries=2 recovery=clear-input+fresh-chat+refill" 'WARN' } catch {}
                    if ($sendStartFailures -ge 3) {
                        throw "FILE_BATCH_SEND_FAILED: Batch $ord/$total で送信を開始できませんでした（2回の回復再試行後）。ここまでのファイル抽出・翻訳結果は出力前のため破棄されました。内部理由: $copilotError"
                    }
                    $remainingSendAttempts = 3 - $sendStartFailures
                    $contractMaxAttempts = [Math]::Min(5, [Math]::Max($contractMaxAttempts, $contractAttempt + $remainingSendAttempts))
                    continue
                }
                if ($copilotError -match 'COPILOT_SILENT_START_TIMEOUT') {
                    $silentStartFailures++
                    $contractError = $_
                    try { Write-YakuLog "File Copilot silent start retry. batch=$ord attempt=$contractAttempt/$contractMaxAttempts silentFailures=$silentStartFailures" 'WARN' } catch {}
                    if ($silentStartFailures -ge 2) { throw }
                    if ($contractAttempt -ge $contractMaxAttempts) { $contractMaxAttempts = [Math]::Min(3, $contractAttempt + 1) }
                    continue
                }
                throw
            }
            if (Test-YakuSplitRequestResponse -Text $raw) { break }
            try {
                $parsed = Parse-YakuNumberedBatchResponse -Raw $raw -ExpectedIds @(1..([int]@($batch.Items).Count)) -RequestId $requestId
                $contractError = $null
                break
            } catch {
                $contractError = $_
                try { Write-YakuLog "File response contract rejected. batch=$ord attempt=$contractAttempt/$contractMaxAttempts errorCode=FILE_RESPONSE_CONTRACT_INVALID" 'WARN' } catch {}
            }
        }

        if ((-not (Test-YakuFileResponseCompleted -Text $raw -RequestId $requestId)) -and $Depth -lt 2) {
            $smaller = [Math]::Max(300, [int][Math]::Floor($MaxChars / 2))
            Add-YakuWarning -Warnings $Warnings -Category 'truncated-retry' -Location "Batch $ord" -Details @{ Batch=$ord; Depth=$Depth; NewMaxChars=$smaller } -Message "Batch $ord はYAKULINGO_ENDなしの途中切れと判定したため、文字数上限 $smaller で再試行しました。"
            if (-not $Context.ContainsKey('TruncatedBatches')) { $Context['TruncatedBatches'] = 0 }
            $Context['TruncatedBatches'] = [int]$Context['TruncatedBatches'] + 1
            $nextDepth = [int]($Depth + 1)
            Update-YakuFileMaxRetryDepth -Context $Context -Depth $nextDepth
            try { Write-YakuLog "File batch truncated retry. batch=$ord depth=$Depth maxChars=$MaxChars newMaxChars=$smaller truncated=$($Context['TruncatedBatches']) nextDepth=$nextDepth" 'WARN' } catch {}
            $sub = Invoke-YakuFileTranslationItems -Root $Root -Items @($batch.Items) -Settings $Settings -Direction $Direction -MaxChars $smaller -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth $nextDepth -Reason 'truncated'
            foreach ($k in $sub.Keys) { $map[[int]$k] = [string]$sub[$k] }
            continue
        }

        if ((Test-YakuSplitRequestResponse -Text $raw) -and $Depth -lt 2 -and @($batch.Items).Count -gt 1) {
            $smaller = [Math]::Max(300, [int][Math]::Floor($MaxChars / 2))
            Add-YakuWarning -Warnings $Warnings -Category 'split-retry' -Location "Batch $ord" -Details @{ Batch=$ord; Depth=$Depth; NewMaxChars=$smaller } -Message "Copilotが分割要求を返したため、Batch $ord を半分のサイズで再試行しました。"
            $nextDepth = [int]($Depth + 1)
            Update-YakuFileMaxRetryDepth -Context $Context -Depth $nextDepth
            $sub = Invoke-YakuFileTranslationItems -Root $Root -Items @($batch.Items) -Settings $Settings -Direction $Direction -MaxChars $smaller -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth $nextDepth -Reason 'split-retry'
            foreach ($k in $sub.Keys) { $map[[int]$k] = [string]$sub[$k] }
            continue
        }

        if ($null -eq $parsed) {
            if ($contractError) { throw $contractError }
            throw 'FILE_RESPONSE_CONTRACT_INVALID: 応答形式を検証できませんでした。'
        }
        $parsedTranslationByIndex = @{}
        try {
            for ($pi = 0; $pi -lt @($batch.Items).Count; $pi++) {
                $localId = $pi + 1
                if ($parsed.Items.ContainsKey($localId)) {
                    $parsedItem = $batch.Items[$pi]
                    $parsedTranslationByIndex[[int]$parsedItem.Index] = Convert-YakuFileItemTranslationForOutput -Item $parsedItem -Translation ([string]$parsed.Items[$localId])
                }
            }
        } catch {
            try { Write-YakuLog "Glossary compliance translation map failed. error=$($_.Exception.Message)" 'WARN' } catch {}
            $parsedTranslationByIndex = @{}
        }
        $batchJobId = ''
        try { if ($Context.ContainsKey('JobId')) { $batchJobId = [string]$Context['JobId'] } } catch { $batchJobId = '' }
        if ($ProgressState -and $batchInputChars -gt 0) {
            $answerLength = ([string]$raw).Length
            $actualRatio = [double]$answerLength / [double]$batchInputChars
            $ratioCount = 0; $ratioSum = 0.0
            try { $ratioCount = [int]$ProgressState['answer_ratio_count']; $ratioSum = [double]$ProgressState['answer_ratio_sum'] } catch {}
            $ProgressState['answer_ratio_count'] = $ratioCount + 1
            $ProgressState['answer_ratio_sum'] = $ratioSum + $actualRatio
            try { Write-YakuLog ("Copilot answer ratio measured. kind=file jobId={0} batch={1}/{2} inputChars={3} answerChars={4} actualRatio={5:N3}" -f $batchJobId, $ord, $total, $batchInputChars, $answerLength, $actualRatio) 'INFO' } catch {}
        }
        $missingText = ((@($parsed.MissingIds) | Select-Object -First 10) -join ',')
        $completedBy = Get-YakuCopilotCompletedByForLastCall
        try { Write-YakuLog "File batch parsed. expected=$(@($batch.Items).Count) received=$($parsed.ReceivedCount) missingIds=$missingText completedBy=$completedBy reason=$Reason" 'INFO' } catch {}
        if ($parsed.MissingCount -gt 0 -or $parsed.ExtraCount -gt 0) {
            try {
                $rawTail = [string]$raw
                if ($rawTail.Length -gt 500) { $rawTail = $rawTail.Substring($rawTail.Length - 500) }
                $rawTailForLog = $rawTail.Replace("`r", '\r').Replace("`n", '\n')
                Write-YakuLog "File batch count mismatch raw tail. batch=$ord expected=$(@($batch.Items).Count) received=$($parsed.ReceivedCount) tail=$rawTailForLog" 'DEBUG'
            } catch {}
            Add-YakuWarning -Warnings $Warnings -Category 'batch-count' -Location "Batch $ord" -Details @{ Batch=$ord; Expected=@($batch.Items).Count; Received=$parsed.ReceivedCount; MissingIds=@($parsed.MissingIds); ExtraIds=@($parsed.ExtraIds); CompletedBy=$completedBy } -Message "Batch $ord の応答件数が一致しませんでした。不足=$($parsed.MissingCount), 過剰=$($parsed.ExtraCount)。不足IDは補完パスで再翻訳します。"
        }
        for ($i = 0; $i -lt @($batch.Items).Count; $i++) {
            $localId = $i + 1
            $item = $batch.Items[$i]
            if (-not $parsed.Items.ContainsKey($localId)) {
                Add-YakuFileFailedItem -Context $Context -Item $item
                continue
            }
            $sourceForValidation = [string]$item.Text
            $translation = Convert-YakuFileItemTranslationForOutput -Item $item -Translation ([string]$parsed.Items[$localId])
            $needsHangulRetry = ($Direction -eq 'to_en' -and (Test-YakuHasHangulChars -Text $translation))
            if ($needsHangulRetry) {
                try {
                    Add-YakuWarning -Warnings $Warnings -Category 'hangul-retry' -Location ("ID $($item.Index)") -Message "Hangul混入を検出したため再翻訳しました: $(Get-YakuShortTextPreview -Text $sourceForValidation -MaxLength 40)"
                    $retryRequestId = [guid]::NewGuid().ToString('N')
                    $retryPrompt = New-YakuFilePrompt -Root $Root -Items @($item) -Settings $Settings -Direction $Direction -RequestId $retryRequestId -CorpusSection ([string]$Context['CorpusSection'])
                    $retrySkipFresh = ([int]$Context['CopilotCalls'] -gt 0)
                    $Context['CopilotCalls'] = [int]$Context['CopilotCalls'] + 1
                    $retryRaw = Invoke-YakuCopilotPrompt -Prompt $retryPrompt -Settings $Settings -SkipFreshChatWait:$retrySkipFresh -AnswerFormat numbered -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
                    $retryParsed = Parse-YakuNumberedBatchResponse -Raw $retryRaw -ExpectedIds @(1) -RequestId $retryRequestId
                    $retryTranslation = if ($retryParsed.Items.ContainsKey(1)) { Convert-YakuFileItemTranslationForOutput -Item $item -Translation ([string]$retryParsed.Items[1]) } else { '' }
                    if (-not (Test-YakuFileTranslationInvalid -Source $sourceForValidation -Translation $retryTranslation -Direction $Direction)) { $translation = $retryTranslation }
                } catch {
                    Add-YakuWarning -Warnings $Warnings -Category 'hangul-retry' -Location ("ID $($item.Index)") -Message "Hangul混入再翻訳に失敗しました: $($_.Exception.Message)"
                }
            }
            if ($Direction -eq 'to_en') {
                $numericAudit = Test-YakuNumericIntegrity -SourceText $sourceForValidation -TranslatedText $translation -Location ("file-ID-" + [string]$item.Index)
                if (-not [bool]$numericAudit.Ok -and [int]$numericAudit.ScaleErrors -gt 0) {
                    try {
                        $numericRetryRequestId = [guid]::NewGuid().ToString('N')
                        $numericRetryPrompt = New-YakuFilePrompt -Root $Root -Items @($item) -Settings $Settings -Direction $Direction -RequestId $numericRetryRequestId -CorpusSection ([string]$Context['CorpusSection'])
                        $numericRetryPrompt += "`n`n" + (New-YakuNumericCorrectionInstruction -Audit $numericAudit)
                        $Context['CopilotCalls'] = [int]$Context['CopilotCalls'] + 1
                        $numericRetryRaw = Invoke-YakuCopilotPrompt -Prompt $numericRetryPrompt -Settings $Settings -SkipFreshChatWait -AnswerFormat numbered -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
                        $numericRetryParsed = Parse-YakuNumberedBatchResponse -Raw $numericRetryRaw -ExpectedIds @(1) -RequestId $numericRetryRequestId
                        if ($numericRetryParsed.Items.ContainsKey(1)) { $translation = Convert-YakuFileItemTranslationForOutput -Item $item -Translation ([string]$numericRetryParsed.Items[1]) }
                        $numericAudit = Test-YakuNumericIntegrity -SourceText $sourceForValidation -TranslatedText $translation -Location ("file-ID-" + [string]$item.Index + '-corrected')
                    } catch {
                        throw "NUMERIC_SCALE_MISMATCH: ID $($item.Index): $([string]$numericAudit.Detail); correction failed: $($_.Exception.Message)"
                    }
                    if (-not [bool]$numericAudit.Ok -and [int]$numericAudit.ScaleErrors -gt 0) { throw "NUMERIC_SCALE_MISMATCH: ID $($item.Index): $([string]$numericAudit.Detail)" }
                    try { Write-YakuLog "Numeric integrity correction completed. location=file-ID-$($item.Index) corrected=1" 'INFO' } catch {}
                }
                if (-not [bool]$numericAudit.Ok -and [int]$numericAudit.ScaleErrors -eq 0) {
                    try {
                        Add-YakuWarning -Warnings $Warnings -Category 'numeric-integrity' -Location ("ID $($item.Index)") -Details @{ Detail=[string]$numericAudit.Detail } -Message "原文の数値トークンの一部が訳文中に見つかりません。表現の統合による可能性がありますが、該当数値をご確認ください。($([string]$numericAudit.Detail))"
                    } catch {}
                }
            }
            if (Test-YakuFileTranslationInvalid -Source $sourceForValidation -Translation $translation -Direction $Direction) {
                Write-YakuFileInvalidItemLog -Item $item -Source $sourceForValidation -Translation $translation -Direction $Direction
                Add-YakuFileFailedItem -Context $Context -Item $item
                continue
            }
            $map[[int]$item.Index] = Convert-YakuFileTranslationBrackets -Text $translation
            $Context['TranslatedSoFar'] = [int]$Context['TranslatedSoFar'] + 1
        }
        $donePct = Get-YakuFileUniqueProgressPercent -Context $Context
        $doneFields = Get-YakuFileUniqueProgressFields -Context $Context -BatchCurrent $ord -BatchTotal $total
        $uniqueDone = [int]$doneFields['unique_done']
        $uniqueTotal = [int]$doneFields['unique_total']
        $doneDetail = "$total 回のうち $ord 回目が終わりました（$uniqueDone / $uniqueTotal 件）"
        if ($cacheHits -gt 0) { $doneDetail += "。$cacheHits 件は前回の結果を再利用" }
        $hint = Get-YakuFileRemainingHint -Context $Context -Current ($ord + 1) -Total $total
        if ($hint) { $doneDetail += "。$hint" }
        Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'translate' -Label $phaseLabel -Progress $donePct -Detail $doneDetail -Fields $doneFields
    }
    return $map
}

function Add-YakuFileTranslationsToCache {
    param(
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][hashtable]$Translations,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    foreach ($item in @($Items)) {
        $idx = [int]$item.Index
        if (-not $Translations.ContainsKey($idx)) { continue }
        # V91.60: 読み出し側(Invoke-YakuFileTranslation)と Set-YakuFileFallbackCacheValue は
        # $item.Text をキーにしている。ここだけ原文を使っていたため書き込みが
        # 読み出しに当たらなかった。3箇所を $item.Text へ揃える。
        # 単位変換・マスク後のテキストなので、値もマスク後で整合する(§7)。
        $sourceForCache = [string]$item.Text
        $value = Convert-YakuFileTranslationBrackets -Text ([string]$Translations[$idx])
        if (Test-YakuFileTranslationInvalid -Source $sourceForCache -Translation $value -Direction $Direction) { continue }
        $cacheKey = Get-YakuTranslationCacheKey -Kind 'file' -Direction $Direction -Text $sourceForCache -Style 'concise' -Settings $Settings
        Set-YakuTranslationCacheValue -Key $cacheKey -Value $value -Settings $Settings
    }
}

function Invoke-YakuFilePreSupplementBracketGlossaryFallback {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByIndex,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][int]$MaxChars,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$ProgressState,
        [Parameter(Mandatory=$true)][hashtable]$Context
    )
    $resolved = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $idx = [int]$item.Index
        $needsTranslation = (-not $TranslationByIndex.ContainsKey($idx)) -or (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation ([string]$TranslationByIndex[$idx]) -Direction $Direction)
        if (-not $needsTranslation) { continue }
        if (Invoke-YakuFileBracketFallback -Root $Root -Item $item -TranslationByIndex $TranslationByIndex -Settings $Settings -Direction $Direction -MaxChars $MaxChars -Warnings $Warnings -ProgressState $ProgressState -Context $Context -GlossaryOnly) {
            $resolved++
        }
    }
    return [int]$resolved
}

function Invoke-YakuFileCompletionPass {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByIndex,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][int]$MaxChars,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$ProgressState,
        [Parameter(Mandatory=$true)][hashtable]$Context
    )
    $supplementMax = [Math]::Max(300, [int][Math]::Floor($MaxChars / 2))
    for ($attempt = 1; $attempt -le 1; $attempt++) {
        $remaining = @($Items | Where-Object {
            $idx = [int]$_.Index
            (-not $TranslationByIndex.ContainsKey($idx)) -or (Test-YakuFileTranslationInvalid -Source ([string]$_.Text) -Translation ([string]$TranslationByIndex[$idx]) -Direction $Direction)
        })
        if ($remaining.Count -le 0) { break }
        foreach ($invalidItem in @($remaining)) {
            $invalidIdx = [int]$invalidItem.Index
            $invalidValue = if ($TranslationByIndex.ContainsKey($invalidIdx)) { [string]$TranslationByIndex[$invalidIdx] } else { '' }
            Write-YakuFileInvalidItemLog -Item $invalidItem -Source ([string]$invalidItem.Text) -Translation $invalidValue -Direction $Direction
        }
        $preResolved = Invoke-YakuFilePreSupplementBracketGlossaryFallback -Root $Root -Items $remaining -TranslationByIndex $TranslationByIndex -Settings $Settings -Direction $Direction -MaxChars $MaxChars -Warnings $Warnings -ProgressState $ProgressState -Context $Context
        if ($preResolved -gt 0) {
            $remaining = @($Items | Where-Object {
                $idx = [int]$_.Index
                (-not $TranslationByIndex.ContainsKey($idx)) -or (Test-YakuFileTranslationInvalid -Source ([string]$_.Text) -Translation ([string]$TranslationByIndex[$idx]) -Direction $Direction)
            })
            if ($remaining.Count -le 0) { break }
        }
        $remainingIds = Get-YakuFileSupplementIdsPreview -Items $remaining
        $remainingPreview = Get-YakuFileSupplementTextPreview -Items $remaining
        Add-YakuWarning -Warnings $Warnings -Category 'supplement-pass' -Location ("Attempt $attempt") -Details @{ Attempt=$attempt; Count=$remaining.Count; MaxChars=$supplementMax; BracketGlossaryPreResolved=$preResolved; Ids=$remainingIds; Preview=$remainingPreview } -Message "不足ID/未翻訳候補 $($remaining.Count) 件を補完パス $attempt で再翻訳します。ids=$remainingIds"
        try {
            $previewForLog = ([string]$remainingPreview).Replace("'", "''")
            Write-YakuLog "Supplement pass attempt. attempt=$attempt count=$($remaining.Count) ids=$remainingIds previews='$previewForLog'" 'INFO'
        } catch {}
        # V63: 括弧付き残件は同じ内容を再送せず、全件をunwrapして1回の補完バッチへまとめる。
        $supplementItems = @(New-YakuFileBracketUnwrappedItems -Items $remaining -Context $Context)
        $Context['FailedItems'] = New-Object System.Collections.Generic.List[object]
        $Context['FailedLookup'] = @{}
        try {
            $translated = Invoke-YakuFileTranslationItems -Root $Root -Items $supplementItems -Settings $Settings -Direction $Direction -MaxChars $supplementMax -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth 0 -Reason 'supplement'
            foreach ($k in @($translated.Keys)) { $TranslationByIndex[[int]$k] = [string]$translated[$k] }
            Add-YakuFileTranslationsToCache -Items $supplementItems -Translations $translated -Settings $Settings -Direction $Direction
        } catch {
            Add-YakuSupplementPassFailure -Warnings $Warnings -RemainingCount $remaining.Count -ErrorMessage ([string]$_.Exception.Message) -Location ("Attempt $attempt")
            Add-YakuSupplementFailureRetainCandidate -Context $Context -Items $remaining
            break
        }
    }
}

function Invoke-YakuFileTranslation {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()]$ProgressState,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [AllowNull()][string[]]$Sheets,
        [AllowNull()][string]$JobId
    )
    if (!(Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw '翻訳対象ファイルが見つかりません。' }
    $kind = Get-YakuSupportedFileKind -Path $InputPath
    $directionLabel = Get-YakuDirectionLabel -Direction $Direction
    $warnings = New-Object System.Collections.Generic.List[object]
    $started = Get-Date
    $outputPath = Get-YakuTranslatedOutputPath -InputPath $InputPath

    Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'extract' -Label '抽出中' -Progress 3 -Detail 'ファイル読込・テキスト抽出中' -Fields @{ file_name=[System.IO.Path]::GetFileName($InputPath); output_path=$outputPath }
    $extractStarted = Get-Date
    $extracted = Get-YakuFileTextBlocks -Path $InputPath -Direction $Direction -Settings $Settings -Sheets $Sheets -ProgressState $ProgressState -OnProgress {
        param($info)
        $progressIndex = if ($info.PSObject.Properties.Name -contains 'SelectedIndex') { [int]$info.SelectedIndex } else { [int]$info.SheetIndex }
        $progressTotal = if ($info.PSObject.Properties.Name -contains 'SelectedTotal') { [int]$info.SelectedTotal } else { [int]$info.SheetTotal }
        Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'extract' -Label '抽出中' `
            -Progress (3 + [int](7 * $progressIndex / [Math]::Max(1, $progressTotal))) `
            -Detail ("テキスト抽出中: {0}/{1} {2}" -f $progressIndex, $progressTotal, $info.SheetName) `
            -Fields @{ file_name=[System.IO.Path]::GetFileName($InputPath) }
    }
    $extractSeconds = [Math]::Round(((Get-Date) - $extractStarted).TotalSeconds, 2)
    foreach ($w in @($extracted.Warnings)) {
        try { $warnings.Add($w) | Out-Null } catch { Add-YakuWarning -Warnings $warnings -Message ([string]$w) -Category 'general' }
    }
    $blocks = @($extracted.Blocks)
    $unmatched = @(); $actualSheetNames = @()
    try { $unmatched = @($extracted.UnmatchedSheets) } catch { $unmatched = @() }
    try { $actualSheetNames = @($extracted.ActualSheetNames) } catch { $actualSheetNames = @() }
    $sheetsSpecified = (@($Sheets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
    if ($sheetsSpecified -and $unmatched.Count -gt 0 -and $blocks.Count -eq 0) {
        $actualList = ($actualSheetNames -join '、')
        throw ("SHEET_NOT_FOUND: 指定シートが見つかりません: {0}。このファイルのシート: {1}" -f ($unmatched -join '、'), $actualList)
    }
    $stats = $extracted.Stats
    Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'dedupe' -Label 'バッチ準備中' -Progress 10 -Detail "翻訳対象 $($blocks.Count) 件" -Fields @{ cells=$stats.cells; shapes=$stats.shapes; charts=$stats.charts }

    if ($blocks.Count -eq 0) {
        $applyStarted = Get-Date
        $writeResult = Write-YakuFileTranslations -InputPath $InputPath -OutputPath $outputPath -Blocks @() -TranslationByBlockId @{} -Settings $Settings -Warnings $warnings -ProgressState $ProgressState
        $applySeconds = [Math]::Round(((Get-Date) - $applyStarted).TotalSeconds, 2)
        $publishedPath = [string]$writeResult.PublishedPath
        $completionStatus = [string]$writeResult.CompletionStatus
        $completionDetail = '翻訳対象テキストがなかったため、原本のコピーを出力しました。'
        Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase $completionStatus -Label 'Done' -Progress 100 -Detail $completionDetail -Fields @{ output_path=$publishedPath; output_name=[System.IO.Path]::GetFileName($publishedPath); completion_status=$completionStatus; blocks_total=0; blocks_translated=0; blocks_written=0; blocks_write_target=0 }
        return [pscustomobject]@{
            Kind='file'; JobId=$JobId; Direction=$Direction; DirectionLabel=$directionLabel; InputName=[System.IO.Path]::GetFileName($InputPath); OutputPath=$publishedPath; OutputName=[System.IO.Path]::GetFileName($publishedPath); CompletionStatus=$completionStatus; CompletionDetail=$completionDetail; Validation=$writeResult.Validation; MaskedCount=0; MaskedItemCount=0;
            BlocksTotal=0; BlocksTranslated=0; BlocksWriteTarget=0; BlocksWritten=0; OriginalKept=0; BlocksRetained=0; BlocksRetainedOriginal=0; UniqueTextCount=0; CacheHits=0; GlossaryExactHits=0; AppliedGlossary=@(); BatchCount=0; BatchTotal=0; TruncatedBatches=0; TruncatedBatchRate=0; MaxRetryDepthReached=0; Stats=$stats; Warnings=@($warnings.ToArray()); ExtractSeconds=$extractSeconds; ApplySeconds=$applySeconds; DurationSeconds=[int]((Get-Date) - $started).TotalSeconds; Timestamp=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    $unique = New-YakuFileUniqueItems -Blocks $blocks
    $items = @($unique.Items)
    # V91.60 段階4/5: 方向によらず単位を正規化トークンへ揃える。
    foreach ($item in $items) {
        $item | Add-Member -NotePropertyName OriginalText -NotePropertyValue ([string]$item.Text) -Force
        $numericPre = Convert-YakuNumericUnits -Text ([string]$item.Text) -Location ("file-ID-" + [string]$item.Index)
        $item.Text = [string]$numericPre.Text
    }
    $translationByIndex = @{}
    $sourceListAll = New-YakuFileSourceList -Items $items
    $exactGlossary = Resolve-YakuFileExactGlossaryTranslations -Root $Root -Items $items -Direction $Direction -Settings $Settings -TranslationByIndex $translationByIndex
    $glossaryExactHits = 0
    try { $glossaryExactHits = [int]$exactGlossary.Count } catch { $glossaryExactHits = 0 }
    # セル完全一致で実際に置換したものだけ。プロンプトへ渡しただけの語は集めない。
    $appliedGlossary = @($exactGlossary.AppliedGlossary)

    # 完全一致で置換できなかった短いラベルを知らせる。
    # cell-exact は実運用では「はみ出さないことの保証」なので、
    # 用語集に無いラベルは保証の外にある。見えないと気づけない。
    $unmatchedLabels = @(Get-YakuFileUnmatchedLabels -Items $items -ExactApplied @($exactGlossary.AppliedGlossary) -Direction $Direction)
    if ($unmatchedLabels.Count -gt 0) {
        $preview = @(@($unmatchedLabels) | Select-Object -First 30 | ForEach-Object { [string]$_.Text })
        $more = if ($unmatchedLabels.Count -gt 30) { ' ほか' + [string]($unmatchedLabels.Count - 30) + '件' } else { '' }
        Add-YakuWarning -Warnings $warnings -Category 'label-not-in-glossary' -Location '用語集の網羅' `
            -Detail @{ Count = [int]$unmatchedLabels.Count; Labels = @($preview); Items = @(@($unmatchedLabels) | Select-Object -First 30 | ForEach-Object { [ordered]@{ id = [int]$_.Index; text = [string]$_.Text } }) } `
            -Message ("用語集に無い短いラベルが " + [string]$unmatchedLabels.Count + " 件ありました。列幅からはみ出す可能性があります。次回以降のために用語集への追加を検討してください: " + (($preview) -join '、') + $more)
        try { Write-YakuLog ("File labels not in glossary. count=" + [string]$unmatchedLabels.Count) 'INFO' } catch {}
    }

    # V91.60 段階5: ここで各項目をマスクする。用語集の解決より後に置くのは、
    # 完全一致置換 (Resolve-YakuFileExactGlossaryTranslations) が原文の見出し語と
    # 突き合わせるため。先にマスクすると一致しなくなる。
    # 以降 $item.Text はマスク後になり、キャッシュキー・プロンプト・
    # 各監査・補完再依頼がすべてマスク後で動く。復元は最後にまとめて行う。
    # 固有名詞も同じ場所で伏せる。数値より先に掛ける（住所の全角数字を
    # 数値マスクに取られないため）。この経路にも固有名詞マスクが無く、
    # 人名・法人名が素のまま Copilot へ出ていた（独立評価の指摘、2026-08-08）。
    $maskedItemCount = 0
    $maskedTokenCount = 0
    $properItemCount = 0
    foreach ($item in $items) {
        $text = [string]$item.Text
        $properMap = $null
        if (Get-Command New-YakuProperNounMaskMap -ErrorAction SilentlyContinue) {
            $properResult = New-YakuProperNounMaskMap -Text $text -Root $Root
            $properMap = $properResult.Map
            $text = [string]$properResult.Text
            if ($null -ne $properMap -and $properMap.Count -gt 0) { $properItemCount++ }
        }
        $maskResult = New-YakuNumericMaskMap -Text $text -Root $Root -Direction $Direction -Location ("file-ID-" + [string]$item.Index)
        $item | Add-Member -NotePropertyName ProperMaskMap -NotePropertyValue $properMap -Force
        $item | Add-Member -NotePropertyName NumericMaskMap -NotePropertyValue $maskResult.Map -Force
        $item | Add-Member -NotePropertyName MaskedText -NotePropertyValue ([string]$maskResult.Text) -Force
        $item.Text = [string]$maskResult.Text
        if ([int]$maskResult.MaskedCount -gt 0) { $maskedItemCount++; $maskedTokenCount += [int]$maskResult.MaskedCount }
    }
    try { Write-YakuLog "File masking. jobId=$JobId items=$($items.Count) maskedItems=$maskedItemCount maskedTokens=$maskedTokenCount properItems=$properItemCount" 'INFO' } catch {}

    $pending = New-Object System.Collections.Generic.List[object]
    $cacheHits = 0
    foreach ($item in $items) {
        $idx = [int]$item.Index
        if ($translationByIndex.ContainsKey($idx)) { continue }
        $cacheKey = Get-YakuTranslationCacheKey -Kind 'file' -Direction $Direction -Text ([string]$item.Text) -Style 'concise' -Root $Root -Settings $Settings
        $cached = Get-YakuTranslationCacheValue -Key $cacheKey -Settings $Settings
        $cachedText = if ($null -ne $cached) { Convert-YakuFileTranslationBrackets -Text ([string]$cached) } else { '' }
        if ($null -ne $cached -and -not (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation $cachedText -Direction $Direction)) {
            $translationByIndex[$idx] = [string]$cachedText
            $cacheHits++
        } else {
            $pending.Add($item) | Out-Null
        }
    }

    $maxChars = Get-YakuMaxCharsPerFileBatch -Settings $Settings
    $initialDone = [int]($cacheHits + $glossaryExactHits)
    $script:YakuGlossaryContainmentLogged = @{}
    $context = @{ JobId=[string]$JobId; BatchOrdinal=0; TotalBatches=1; UniqueTotal=[Math]::Max(1, $items.Count); CacheHits=$cacheHits; GlossaryExactHits=$glossaryExactHits; TranslatedSoFar=$initialDone; CopilotCalls=0; TruncatedBatches=0; MaxRetryDepthReached=0; FailedItems=(New-Object System.Collections.Generic.List[object]); FailedLookup=@{}; AppliedGlossaryMatches=(New-Object System.Collections.Generic.List[object]); AngleBracketUnwrapLogged=@{}; GlossaryMatchCache=@{} }
    Add-YakuFileAppliedGlossaryContext -Context $context -Matches $appliedGlossary

    $preBatchBracketResolved = 0
    if ($pending.Count -gt 0) {
        $preBatchBracketResolved = Invoke-YakuFilePreBatchAngleBracketGlossaryFallback -Root $Root -Items @($pending.ToArray()) -TranslationByIndex $translationByIndex -Settings $Settings -Direction $Direction -MaxChars $maxChars -Warnings $warnings -ProgressState $ProgressState -Context $context
        if ($preBatchBracketResolved -gt 0) { $context['TranslatedSoFar'] = [int]$context['TranslatedSoFar'] + [int]$preBatchBracketResolved }
    }

    $copilotPendingOriginal = @($pending.ToArray() | Where-Object {
        $idx = [int]$_.Index
        (-not $translationByIndex.ContainsKey($idx)) -or (Test-YakuFileTranslationInvalid -Source ([string]$_.Text) -Translation ([string]$translationByIndex[$idx]) -Direction $Direction)
    })
    $copilotPending = @(New-YakuFileBracketUnwrappedItems -Items $copilotPendingOriginal -Context $context)
    $initialBatches = @(Split-YakuFileTranslationItems -Items $copilotPending -MaxChars $maxChars)
    $context['TotalBatches'] = [Math]::Max(1, $initialBatches.Count)
    $initialDone = [int]$context['TranslatedSoFar']
    Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'translate' -Label '翻訳中' -Progress (Get-YakuFileUniqueProgressPercent -Context $context) -Detail "ユニーク翻訳 $initialDone/$($items.Count) 件（用語完全一致 $glossaryExactHits, キャッシュ $cacheHits, bracket glossary $preBatchBracketResolved）" -Fields ((Get-YakuFileUniqueProgressFields -Context $context -BatchCurrent 0 -BatchTotal ([int]$context['TotalBatches'])) + @{ glossary_exact_hits=$glossaryExactHits; bracket_glossary_hits=$preBatchBracketResolved })
    if ($copilotPending.Count -gt 0) {
        $translatedPending = Invoke-YakuFileTranslationItems -Root $Root -Items $copilotPending -Settings $Settings -Direction $Direction -MaxChars $maxChars -Warnings $warnings -ProgressState $ProgressState -Context $context -Depth 0
        foreach ($k in @($translatedPending.Keys)) { $translationByIndex[[int]$k] = [string]$translatedPending[$k] }
        Add-YakuFileTranslationsToCache -Items $copilotPending -Translations $translatedPending -Settings $Settings -Direction $Direction
    }

    Invoke-YakuFileCompletionPass -Root $Root -Items $items -TranslationByIndex $translationByIndex -Settings $Settings -Direction $Direction -MaxChars $maxChars -Warnings $warnings -ProgressState $ProgressState -Context $context

    $originalKeptUnique = 0
    $supplementFailureOriginalKept = 0
    foreach ($item in $items) {
        $idx = [int]$item.Index
        if (-not $translationByIndex.ContainsKey($idx) -or (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation ([string]$translationByIndex[$idx]) -Direction $Direction)) {
            $fallbackApplied = Invoke-YakuFileBracketFallback -Root $Root -Item $item -TranslationByIndex $translationByIndex -Settings $Settings -Direction $Direction -MaxChars $maxChars -Warnings $warnings -ProgressState $ProgressState -Context $context
            if ($fallbackApplied -and $translationByIndex.ContainsKey($idx) -and -not (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation ([string]$translationByIndex[$idx]) -Direction $Direction)) { continue }
            Add-YakuWarning -Warnings $warnings -Category 'untranslated-retained' -Location ("ID $idx") -Details @{ Id=$idx; Text=[string]$item.Text } -Message "補完後も翻訳できなかったため原文保持しました: $(Get-YakuShortTextPreview -Text ([string]$item.Text) -MaxLength 60)"
            $translationByIndex[$idx] = Get-YakuFileItemOriginalText -Item $item
            $originalKeptUnique++
            if (Test-YakuSupplementFailureRetainCandidate -Context $context -Index $idx) { $supplementFailureOriginalKept++ }
        }
    }
    if ($supplementFailureOriginalKept -gt 0) {
        Add-YakuSupplementOriginalRetainedWarning -Warnings $warnings -Count $supplementFailureOriginalKept -Location 'original-retain'
    }

    # V91.36 final numeric audit also covers cache/glossary/fallback routes.
    # V91.60: to_jp では [[N1]] oku が [[N1]]億円 へ訳されるため
    # 「数値+単位」トークンの照合が成立しない(§6)。プレースホルダーの
    # 過不足は下の復元ループで確認する。
    if ($Direction -eq 'to_en') {
        foreach ($item in $items) {
            $idx = [int]$item.Index
            if (-not $translationByIndex.ContainsKey($idx)) { continue }
            $sourceNumeric = [string]$item.Text
            $translatedNumeric = [string]$translationByIndex[$idx]
            $finalNumericAudit = Test-YakuNumericIntegrity -SourceText $sourceNumeric -TranslatedText $translatedNumeric -Location ("file-final-ID-" + [string]$idx)
            if (-not [bool]$finalNumericAudit.Ok -and [int]$finalNumericAudit.ScaleErrors -gt 0) {
                try {
                    $numericRequestId = [guid]::NewGuid().ToString('N')
                    $numericPrompt = New-YakuFilePrompt -Root $Root -Items @($item) -Settings $Settings -Direction $Direction -RequestId $numericRequestId -CorpusSection ([string]$Context['CorpusSection'])
                    $numericPrompt += "`n`n" + (New-YakuNumericCorrectionInstruction -Audit $finalNumericAudit)
                    $context['CopilotCalls'] = [int]$context['CopilotCalls'] + 1
                    $numericRaw = Invoke-YakuCopilotPrompt -Prompt $numericPrompt -Settings $Settings -SkipFreshChatWait -AnswerFormat numbered -PreserveEndMarker -Warnings $warnings -ProgressState $ProgressState
                    $numericParsed = Parse-YakuNumberedBatchResponse -Raw $numericRaw -ExpectedIds @(1) -RequestId $numericRequestId
                    if ($numericParsed.Items.ContainsKey(1)) { $translationByIndex[$idx] = Convert-YakuFileItemTranslationForOutput -Item $item -Translation ([string]$numericParsed.Items[1]) }
                    $finalNumericAudit = Test-YakuNumericIntegrity -SourceText $sourceNumeric -TranslatedText ([string]$translationByIndex[$idx]) -Location ("file-final-ID-" + [string]$idx + '-corrected')
                } catch {
                    throw "NUMERIC_SCALE_MISMATCH: ID ${idx}: $([string]$finalNumericAudit.Detail); correction failed: $($_.Exception.Message)"
                }
                if (-not [bool]$finalNumericAudit.Ok -and [int]$finalNumericAudit.ScaleErrors -gt 0) { throw "NUMERIC_SCALE_MISMATCH: ID ${idx}: $([string]$finalNumericAudit.Detail)" }
                try { Write-YakuLog "Numeric integrity correction completed. location=file-final-ID-$idx corrected=1" 'INFO' } catch {}
            }
            if (-not [bool]$finalNumericAudit.Ok -and [int]$finalNumericAudit.ScaleErrors -eq 0) {
                try {
                    Add-YakuWarning -Warnings $warnings -Category 'numeric-integrity' -Location ("ID $idx") -Details @{ Detail=[string]$finalNumericAudit.Detail } -Message "原文の数値トークンの一部が訳文中に見つかりません。表現の統合による可能性がありますが、該当数値をご確認ください。($([string]$finalNumericAudit.Detail))"
                } catch {}
            }
        }
    }

    # V91.60 段階5: プレースホルダーを実値へ戻す。
    # ここより後ろは原文保持判定(訳文が原文と同一かの比較)と書き戻しに入るため、
    # マスクを残したままにできない。復元前に1対1を確認し、崩れていれば
    # 警告を立てる。無言で数値が消えるのを避けるのが目的。
    $maskIntegrityFailures = 0
    foreach ($item in $items) {
        $idx = [int]$item.Index
        if (-not $translationByIndex.ContainsKey($idx)) { continue }
        $map = $null
        try { $map = $item.NumericMaskMap } catch { $map = $null }
        $properMap = $null
        try { $properMap = $item.ProperMaskMap } catch { $properMap = $null }
        # 数値と固有名詞は別々に見る。まとめて「無ければ次へ」とすると、
        # 数字を含まない項目で固有名詞が戻らず、出力へ [[P1]] が残る。
        $hasNumeric = ($null -ne $map -and $map.Count -gt 0)
        $hasProper = ($null -ne $properMap -and $properMap.Count -gt 0)
        if (-not $hasNumeric -and -not $hasProper) { continue }
        $translated = [string]$translationByIndex[$idx]
        # 原文保持になった項目は untranslated-retained で既に警告済み。
        # プレースホルダーが無いのは当然なので、二重に警告しない。
        if ($translated -eq (Get-YakuFileItemOriginalText -Item $item)) { continue }
        if ($hasNumeric) {
            $maskIntegrity = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$item.MaskedText) -Translated $translated -Location ("file-ID-" + [string]$idx)
            if (-not [bool]$maskIntegrity.Ok) {
                $maskIntegrityFailures++
                try {
                    Add-YakuWarning -Warnings $warnings -Category 'numeric-mask-integrity' -Location ("ID $idx") -Details @{ Detail=[string]$maskIntegrity.Detail; Missing=@($maskIntegrity.Missing); Duplicated=@($maskIntegrity.Duplicated); Unexpected=@($maskIntegrity.Unexpected) } -Message "数値プレースホルダーの個数が原文と一致しません。該当箇所の数値を必ずご確認ください。($([string]$maskIntegrity.Detail))"
                } catch {}
            }
            $translated = Restore-YakuNumericMask -Text $translated -Map $map
        }
        if ($hasProper) {
            try {
                $pInt = Test-YakuProperNounMaskIntegrity -MaskedSource ([string]$item.MaskedText) -Translated $translated -Map $properMap
                if (-not [bool]$pInt.Ok) {
                    $lost = @(@($pInt.Missing) | ForEach-Object { [string]$properMap[[string]$_] })
                    Add-YakuWarning -Warnings $warnings -Category 'proper-noun-dropped' -Location ("ID $idx") -Details @{ Missing = @($pInt.Missing) } -Message ("固有名詞が訳文から抜けています: " + (@($lost) -join '、') + "。必ずご確認ください。")
                }
            } catch {}
            $translated = Restore-YakuProperNounMask -Text $translated -Map $properMap
        }
        $translationByIndex[$idx] = $translated
    }
    if ($maskIntegrityFailures -gt 0) {
        try { Write-YakuLog "File numeric mask integrity. jobId=$JobId failures=$maskIntegrityFailures" 'WARN' } catch {}
    }
    # 原文保持判定・書き戻しはマスク前の原文と比較する必要があるため、
    # $item.Text をここで戻す。
    foreach ($item in $items) {
        try { if ($item.PSObject.Properties.Name -contains 'MaskedText') { $item.Text = Restore-YakuNumericMask -Text ([string]$item.Text) -Map $item.NumericMaskMap } } catch {}
        # 固有名詞も戻す。戻さないと原文保持の判定が [[P1]] 入りの文字列と
        # 比べることになり、書き戻し先の照合も狂う。
        try { if ($item.PSObject.Properties.Name -contains 'ProperMaskMap') { $item.Text = Restore-YakuProperNounMask -Text ([string]$item.Text) -Map $item.ProperMaskMap } } catch {}
    }

    # 文中の用語監査は廃止した（利用者の判断 2026-08-06）。
    # 用語集の目的はレイアウトの保証であり、文中の言い回しの統一ではない。
    # セル完全一致の置換だけが保証で、それは Resolve-YakuFileExactGlossaryTranslations が行う。
    try {
        $collectedGlossary = @()
        if ($context.ContainsKey('AppliedGlossaryMatches') -and $null -ne $context['AppliedGlossaryMatches']) { $collectedGlossary = @($context['AppliedGlossaryMatches'].ToArray()) }
        $appliedGlossary = @(Join-YakuAppliedGlossaryEntries -Primary $appliedGlossary -Secondary $collectedGlossary)
    } catch {}

    $translationByBlockId = @{}
    $blocksTranslated = 0
    $blocksOriginalKept = 0
    foreach ($block in $blocks) {
        $item = $unique.ByText[[string]$block.Text]
        $tr = ''
        if ($item -and $translationByIndex.ContainsKey([int]$item.Index)) { $tr = [string]$translationByIndex[[int]$item.Index] }
        if ([string]::IsNullOrWhiteSpace($tr)) { $tr = [string]$block.Text }
        if ($tr -eq [string]$block.Text) {
            # 原文保持対象には触れない。コピー済み出力ファイルに元値が残るため、
            # 書き戻し対象へ入れず、フォント変更も適用しない。
            $blocksOriginalKept++
            continue
        }
        $blocksTranslated++
        $translationByBlockId[[string]$block.Id] = $tr
    }

    Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'apply' -Label '書き戻し中' -Progress 92 -Detail '翻訳結果を書き戻しています' -Fields @{ output_path=$outputPath; output_name=[System.IO.Path]::GetFileName($outputPath); blocks_write_target=$blocksTranslated }
    $applyStarted = Get-Date
    $writeResult = Write-YakuFileTranslations -InputPath $InputPath -OutputPath $outputPath -Blocks $blocks -TranslationByBlockId $translationByBlockId -Settings $Settings -Warnings $warnings -ProgressState $ProgressState
    $applySeconds = [Math]::Round(((Get-Date) - $applyStarted).TotalSeconds, 2)
    $blocksWriteTarget = [int]$translationByBlockId.Count
    $blocksWritten = 0
    try { if ($writeResult -and ($writeResult.PSObject.Properties.Name -contains 'WriteTargetCount')) { $blocksWriteTarget = [int]$writeResult.WriteTargetCount } } catch {}
    try { if ($writeResult -and ($writeResult.PSObject.Properties.Name -contains 'WrittenCount')) { $blocksWritten = [int]$writeResult.WrittenCount } } catch {}
    if ($blocksWriteTarget -ne $blocksWritten) {
        throw "OUTPUT_VALIDATION_WRITE_COUNT: 翻訳あり件数と実際の書き込み件数が一致しません。翻訳あり=$blocksWriteTarget, 書き込み=$blocksWritten"
    }
    $truncatedBatches = 0
    try { $truncatedBatches = [int]$context['TruncatedBatches'] } catch { $truncatedBatches = 0 }
    $batchTotal = 0
    try { $batchTotal = [int]$context['BatchOrdinal'] } catch { $batchTotal = 0 }
    $truncatedRate = if ($batchTotal -gt 0) { [Math]::Round(($truncatedBatches / [double]$batchTotal), 4) } else { 0 }
    $maxRetryDepth = 0
    try { $maxRetryDepth = [int]$context['MaxRetryDepthReached'] } catch { $maxRetryDepth = 0 }
    try { Write-YakuLog "File translation truncation rate: $truncatedBatches/$batchTotal ($truncatedRate), maxRetryDepth=$maxRetryDepth" 'INFO' } catch {}

    $publishedPath = [string]$writeResult.PublishedPath
    $completionStatus = [string]$writeResult.CompletionStatus
    $completionLabel = if ($completionStatus -eq 'completed_with_warnings') { 'Completed with warnings' } else { 'Done' }
    $completionDetail = if ($completionStatus -eq 'completed_with_warnings') { '不完全な項目があります。警告を確認してください。' } else { 'ファイル翻訳が完了しました。' }
    Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase $completionStatus -Label $completionLabel -Progress 100 -Detail $completionDetail -Fields @{ output_path=$publishedPath; output_name=[System.IO.Path]::GetFileName($publishedPath); completion_status=$completionStatus; blocks_total=$blocks.Count; blocks_translated=$blocksTranslated; blocks_written=$blocksWritten; blocks_write_target=$blocksWriteTarget; original_kept=$blocksOriginalKept; unique_done=$items.Count; unique_total=$items.Count }
    return [pscustomobject]@{
        Kind = 'file'
        JobId = $JobId
        Direction = $Direction
        DirectionLabel = $directionLabel
        # V91.60 §9: 件数のみ。対応表(Map)は載せない(§8)。
        MaskedCount = [int]$maskedTokenCount
        MaskedItemCount = [int]$maskedItemCount
        InputName = [System.IO.Path]::GetFileName($InputPath)
        OutputPath = $publishedPath
        OutputName = [System.IO.Path]::GetFileName($publishedPath)
        CompletionStatus = $completionStatus
        CompletionDetail = $completionDetail
        Validation = $writeResult.Validation
        BlocksTotal = $blocks.Count
        BlocksTranslated = $blocksTranslated
        BlocksWriteTarget = $blocksWriteTarget
        BlocksWritten = $blocksWritten
        BlocksRetainedOriginal = $blocksOriginalKept
        OriginalKept = $blocksOriginalKept
        BlocksRetained = $blocksOriginalKept
        UniqueTextCount = $items.Count
        UniqueOriginalKept = $originalKeptUnique
        CacheHits = $cacheHits
        GlossaryExactHits = $glossaryExactHits
        AppliedGlossary = @($appliedGlossary)
        BatchCount = [int]$context['BatchOrdinal']
        BatchTotal = $batchTotal
        TruncatedBatches = $truncatedBatches
        TruncatedBatchRate = $truncatedRate
        MaxRetryDepthReached = $maxRetryDepth
        Stats = $stats
        Warnings = @($warnings.ToArray())
        ExtractSeconds = $extractSeconds
        ApplySeconds = $applySeconds
        DurationSeconds = [int]((Get-Date) - $started).TotalSeconds
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}
