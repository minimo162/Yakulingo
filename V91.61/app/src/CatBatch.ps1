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

function Get-YakuCatDraftOutputPath {
    <#
      project配下の原本は安全のため original.ext という固定名にするが、
      利用者に返すDRAFT名まで original にしない。取込時に保存した FileName を
      表示名として使い、同名出力がある場合は上書きせず連番にする。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowEmptyString()][string]$OutputDirectory = ''
    )
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Get-YakuSubDir 'outputs' }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    $displayName = [string]$Project.FileName
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [System.IO.Path]::GetFileName([string]$Project.Path) }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($displayName)
    $ext = [System.IO.Path]::GetExtension($displayName)
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = [System.IO.Path]::GetExtension([string]$Project.Path) }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'file' }
    $safeBase = New-SafeFileName -FileName $base

    $candidate = Join-Path $OutputDirectory ('DRAFT_' + $safeBase + '_translated' + $ext)
    $i = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $OutputDirectory ('DRAFT_' + $safeBase + '_translated(' + $i + ')' + $ext)
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

function Split-YakuFileTranslationItems {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
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

function New-YakuTranslationBatchPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$RequestId,
        [ValidateSet('cat')][string]$Workflow = 'cat'
    )
    if (-not (Get-Command New-YakuCatPrompt -ErrorAction SilentlyContinue)) { throw 'CAT_PROMPT_CONTRACT_UNAVAILABLE' }
    return New-YakuCatPrompt -Root $Root -Items $Items -Settings $Settings -Direction $Direction -RequestId $RequestId
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
        Write-YakuLog "Angle-bracket unwrap applied. id=$Id innerLength=$(([string]$Inner).Length)" 'INFO'
    } catch {}
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

function Get-YakuFileSupplementIdsPreview {
    param([AllowNull()][object[]]$Items, [int]$MaxCount = 30)
    $ids = @($Items | Select-Object -First $MaxCount | ForEach-Object { [string]([int]$_.Index) })
    $joined = ($ids -join ',')
    if (@($Items).Count -gt $MaxCount) { $joined += ',...' }
    return $joined
}

function Get-YakuFileExactGlossaryTranslation {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$Term,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()]$Settings,
        [AllowNull()][object[]]$TerminologyEntries,
        [AllowNull()][string]$ProjectId
    )
    if (-not (Get-Command Find-YakuCellExactTerminologyMatch -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Found = $false; Value = '' }
    }
    $match = Find-YakuCellExactTerminologyMatch -Text $Term -Direction $Direction -Entries $TerminologyEntries -ProjectId $ProjectId
    if ($null -eq $match) { return [pscustomobject]@{ Found = $false; Value = '' } }
    return [pscustomobject]@{ Found = $true; Value = [string]$match.Target; Entry=$match.Entry; ReferenceId=[string]$match.ReferenceId }
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

function Resolve-YakuFileExactGlossaryTranslations {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByIndex,
        [AllowNull()][object[]]$TerminologyEntries,
        [AllowNull()][string]$ProjectId
    )
    $hits = 0
    $applied = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        $idx = [int]$item.Index
        if ($TranslationByIndex.ContainsKey($idx)) { continue }
        $cleanText = ConvertTo-YakuGlossaryField -Value ([string]$item.Text)
        if ([string]::IsNullOrWhiteSpace($cleanText)) { continue }
        $entry = Find-YakuCellExactTerminologyMatch -Text $cleanText -Direction $Direction -Entries $TerminologyEntries -ProjectId $ProjectId
        if ($null -eq $entry) { continue }
        $candidate = Convert-YakuFileTranslationBrackets -Text ([string]$entry.Target)
        if (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation $candidate -Direction $Direction) { continue }
        $TranslationByIndex[$idx] = [string]$candidate
        $hits++
        $applied.Add([pscustomobject]@{
            Source=[string]$entry.Source; Target=[string]$entry.Target; From=[string]$entry.Source; To=[string]$candidate
            Row=0; Via='terminology-cell-exact'; ItemIndex=$idx; ReferenceId=[string]$entry.ReferenceId
            TermId=[string]$entry.TermId; TermVersion=[int]$entry.Version; Scope=[string]$entry.Scope
        }) | Out-Null
    }
    if ($hits -gt 0) {
        try { Write-YakuLog "CAT terminology cell-exact hits: count=$hits" 'INFO' } catch {}
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

      MaxChars の既定は短いラベル判定向けの値にする。
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

function Write-YakuFileBracketFallbackLog {
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Result,
        [Parameter(Mandatory=$true)][ValidateSet('glossary','copilot-retry')][string]$Via
    )
    try {
        Write-YakuLog "Bracket-glossary fallback applied. id=$Id sourceLength=$(([string]$Source).Length) resultLength=$(([string]$Result).Length) via=$Via" 'INFO'
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
    # Bundled glossary composition is retired.  Whole-cell terminology is
    # applied only by the explicit CAT project pass, where project scope and
    # provenance are available.  Bracket recovery therefore falls through to
    # the normal protected translation request.
    return [pscustomobject]@{ Found=$false; Value=''; Matches=@() }
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
        $translated = Invoke-YakuTranslationBatchItems -Root $Root -Items @($retryItem) -Settings $Settings -Direction $Direction -MaxChars $supplementMax -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth 0 -Reason 'supplement'
        if ($translated.ContainsKey($idx)) {
            $innerTranslation = Convert-YakuFileTranslationBrackets -Text ([string]$translated[$idx])
            if (-not (Test-YakuFileTranslationInvalid -Source $inner -Translation $innerTranslation -Direction $Direction)) {
                $candidate = New-YakuFileBracketWrappedTranslation -InnerText $innerTranslation -Wrappers @($stripped.Wrappers)
                if (-not (Test-YakuFileTranslationInvalid -Source $source -Translation $candidate -Direction $Direction)) {
                    $TranslationByIndex[$idx] = [string]$candidate
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
    try { Write-YakuLog "CAT item invalid. id=$([int]$Item.Index) reason=$reason sourceLength=$($Source.Length) translationLength=$(([string]$Translation).Length)" 'INFO' } catch {}
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

function Invoke-YakuTranslationBatchItems {
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
    $workflow = ''
    try { $workflow = [string]$Context['Workflow'] } catch { $workflow = '' }
    if ($workflow -ne 'cat') { throw 'CAT_TRANSLATION_FACADE_REQUIRED: バッチ送信はCAT専用入口からのみ実行できます。' }
    Assert-YakuCatProtectedItems -Items $Items
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
            # 1回で終わるときに「（1/1 回目）」と出しても意味が無く、雑音になる。
            $ProgressState['file_progress_prefix'] = if ($total -gt 1) { "$phaseLabel（$ord/$total 回目）" } else { $phaseLabel }
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
        $batchNumericMaps = @($batch.Items | ForEach-Object { $_.NumericMaskMap })
        $batchProtectedFields = New-Object System.Collections.Generic.List[object]
        $batchFieldIndex = 0
        foreach ($protectedItem in @($batch.Items)) {
            $batchProtectedFields.Add([pscustomobject]@{ Name=('item:' + [string]$batchFieldIndex); OriginalText=[string]$protectedItem.OriginalText; ProtectedText=[string]$protectedItem.Text; NumericMaskMaps=@($protectedItem.NumericMaskMap) }) | Out-Null
            $batchFieldIndex++
        }
        for ($contractAttempt = 1; $contractAttempt -le $contractMaxAttempts; $contractAttempt++) {
            $promptPackage = New-YakuProtectedPromptPackage -Kind cat -Root $Root -Direction $Direction -Fields @($batchProtectedFields.ToArray()) `
                -Arguments ([pscustomobject]@{ Items=@($batch.Items); Settings=$Settings; Workflow=$workflow })
            $requestId = [string]$promptPackage.RequestId
            $prompt = [string]$promptPackage.Prompt
            $skipFresh = ([int]$Context['CopilotCalls'] -gt 0)
            $Context['CopilotCalls'] = [int]$Context['CopilotCalls'] + 1
            try {
                $raw = Invoke-YakuProtectedCopilotPrompt -Envelope $promptPackage.Envelope -Settings $Settings -SkipFreshChatWait:$skipFresh -AnswerFormat numbered -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
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
            $sub = Invoke-YakuTranslationBatchItems -Root $Root -Items @($batch.Items) -Settings $Settings -Direction $Direction -MaxChars $smaller -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth $nextDepth -Reason 'truncated'
            foreach ($k in $sub.Keys) { $map[[int]$k] = [string]$sub[$k] }
            continue
        }

        if ((Test-YakuSplitRequestResponse -Text $raw) -and $Depth -lt 2 -and @($batch.Items).Count -gt 1) {
            $smaller = [Math]::Max(300, [int][Math]::Floor($MaxChars / 2))
            Add-YakuWarning -Warnings $Warnings -Category 'split-retry' -Location "Batch $ord" -Details @{ Batch=$ord; Depth=$Depth; NewMaxChars=$smaller } -Message "Copilotが分割要求を返したため、Batch $ord を半分のサイズで再試行しました。"
            $nextDepth = [int]($Depth + 1)
            Update-YakuFileMaxRetryDepth -Context $Context -Depth $nextDepth
            $sub = Invoke-YakuTranslationBatchItems -Root $Root -Items @($batch.Items) -Settings $Settings -Direction $Direction -MaxChars $smaller -Warnings $Warnings -ProgressState $ProgressState -Context $Context -Depth $nextDepth -Reason 'split-retry'
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
            try { Write-YakuLog "CAT batch count mismatch. batch=$ord expected=$(@($batch.Items).Count) received=$($parsed.ReceivedCount)" 'DEBUG' } catch {}
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
                    $retryFields = @([pscustomobject]@{ Name='item:0'; OriginalText=[string]$item.OriginalText; ProtectedText=[string]$item.Text; NumericMaskMaps=@($item.NumericMaskMap) })
                    $retryPackage = New-YakuProtectedPromptPackage -Kind cat -Root $Root -Direction $Direction -Fields $retryFields `
                        -Arguments ([pscustomobject]@{ Items=@($item); Settings=$Settings; Workflow=$workflow })
                    $retryRequestId = [string]$retryPackage.RequestId
                    $retryPrompt = [string]$retryPackage.Prompt
                    $retrySkipFresh = ([int]$Context['CopilotCalls'] -gt 0)
                    $Context['CopilotCalls'] = [int]$Context['CopilotCalls'] + 1
                    $retryRaw = Invoke-YakuProtectedCopilotPrompt -Envelope $retryPackage.Envelope -Settings $Settings -SkipFreshChatWait:$retrySkipFresh -AnswerFormat numbered -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
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
                        $numericCorrection = New-YakuNumericCorrectionInstruction -Audit $numericAudit
                        $numericRetryFields = @(
                            [pscustomobject]@{ Name='item:0'; OriginalText=[string]$item.OriginalText; ProtectedText=[string]$item.Text; NumericMaskMaps=@($item.NumericMaskMap) },
                            [pscustomobject]@{ Name='additional_instruction'; OriginalText=$numericCorrection; ProtectedText=$numericCorrection }
                        )
                        $numericRetryPackage = New-YakuProtectedPromptPackage -Kind cat -Root $Root -Direction $Direction -Fields $numericRetryFields `
                            -Arguments ([pscustomobject]@{ Items=@($item); Settings=$Settings; Workflow=$workflow })
                        $numericRetryRequestId = [string]$numericRetryPackage.RequestId
                        $numericRetryPrompt = [string]$numericRetryPackage.Prompt
                        $Context['CopilotCalls'] = [int]$Context['CopilotCalls'] + 1
                        $numericRetryRaw = Invoke-YakuProtectedCopilotPrompt -Envelope $numericRetryPackage.Envelope -Settings $Settings -SkipFreshChatWait -AnswerFormat numbered -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
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
        # CAT は内側のこの関数を直接呼ぶ。バッチが終わるたびに結果を外側へ
        # 公開し、次のバッチで制限に当たっても完了分を保存・再利用できるようにする。
        if ($Context.ContainsKey('CompletedMap') -and $null -ne $Context['CompletedMap']) {
            foreach ($doneItem in @($batch.Items)) {
                $doneIndex = [int]$doneItem.Index
                if ($map.ContainsKey($doneIndex)) { $Context['CompletedMap'][$doneIndex] = [string]$map[$doneIndex] }
            }
        }
        if ($Context.ContainsKey('OnBatchCompleted') -and $null -ne $Context['OnBatchCompleted']) {
            $onBatchCompleted = $Context['OnBatchCompleted']
            & $onBatchCompleted @($batch.Items) $map
        }
    }
    return $map
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
