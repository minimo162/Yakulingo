function Convert-YakuTranslationNotationLocal {
    <# Rebuild a displayed translation from the protected translation. No external call. #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$SourceText,
        [Parameter(Mandatory=$true)][string]$MaskedTranslation,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [ValidateSet('oku','billion')][string]$Notation = 'oku'
    )
    $normalized = [string](Convert-YakuNumericUnits -Text $SourceText -Location 'notation-toggle' -Notation $Notation).Text
    $mask = New-YakuNumericMaskMap -Text $normalized -Root $Root -Direction $Direction -Location 'notation-toggle'
    $protectedTranslation = [string]$MaskedTranslation
    if ($Notation -eq 'billion') {
        $protectedTranslation = [regex]::Replace($protectedTranslation, '(\[\[N\d+\]\])\s*oku\b', '$1 billion yen', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } else {
        $protectedTranslation = [regex]::Replace($protectedTranslation, '(\[\[N\d+\]\])\s*billion(?:\s+yen)?\b', '$1 oku', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $integrity = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$mask.Text) -Translated $protectedTranslation -Location 'notation-toggle'
    if (-not [bool]$integrity.Ok) { throw ('NOTATION_MASK_MISMATCH: ' + [string]$integrity.Detail) }
    return [string](Restore-YakuNumericMask -Text $protectedTranslation -Map $mask.Map -Direction $Direction -SourceText $normalized)
}

function Convert-YakuRenderedAmountNotationLocal {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$SourceText,
        [ValidateSet('oku','billion')][string]$From,
        [ValidateSet('oku','billion')][string]$To
    )
    $result = [string]$Text
    if ($From -eq $To -or [string]::IsNullOrWhiteSpace($result) -or [string]$SourceText -notmatch '(?:億|兆)円') { return $result }
    $numberPattern = '(?<prefix>¥?\s*)(?<number>[+-]?[\d,]+(?:\.\d+)?)'
    if ($To -eq 'billion') {
        return [regex]::Replace($result, $numberPattern + '\s*oku\b', {
            param($match)
            $value = [decimal]0
            if (-not [decimal]::TryParse($match.Groups['number'].Value.Replace(',',''), [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $match.Value }
            return ([string]$match.Groups['prefix'].Value + (ConvertTo-YakuInvariantNumberText -Value ($value / 10) -UseGrouping) + ' billion yen')
        })
    }
    return [regex]::Replace($result, $numberPattern + '\s*billion(?:\s+yen)?\b', {
        param($match)
        $value = [decimal]0
        if (-not [decimal]::TryParse($match.Groups['number'].Value.Replace(',',''), [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $match.Value }
        return ([string]$match.Groups['prefix'].Value + (ConvertTo-YakuInvariantNumberText -Value ($value * 10) -UseGrouping) + ' oku')
    })
}

function Set-YakuCatProjectAmountNotationLocal {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$Root,
        [ValidateSet('oku','billion')][string]$Notation
    )
    $current = Get-YakuCatProjectAmountNotation -Project $Project
    if ($current -eq $Notation) { return 0 }
    $changed = 0
    foreach ($segment in @($Project.Segments)) {
        if ([string]::IsNullOrWhiteSpace([string]$segment.Translation)) { continue }
        $next = [string]$segment.Translation
        if (-not [string]::IsNullOrWhiteSpace([string]$segment.MaskedTranslation)) {
            try {
                $next = Convert-YakuTranslationNotationLocal -Root $Root -SourceText ([string]$segment.Text) -MaskedTranslation ([string]$segment.MaskedTranslation) -Direction ([string]$Project.Direction) -Notation $Notation
            } catch {
                $next = Convert-YakuRenderedAmountNotationLocal -Text $next -SourceText ([string]$segment.Text) -From $current -To $Notation
            }
        } else {
            $next = Convert-YakuRenderedAmountNotationLocal -Text $next -SourceText ([string]$segment.Text) -From $current -To $Notation
        }
        if ($next -eq [string]$segment.Translation) { continue }
        $segment.Translation = $next
        $changed++
    }
    $Project.AmountNotation = $Notation
    if ($changed -gt 0) {
        $acronymIndex = New-YakuCatAcronymUsageIndex -Project $Project
        foreach ($segment in @($Project.Segments)) {
            if ([string]::IsNullOrWhiteSpace([string]$segment.Translation)) { continue }
            $null = Invoke-YakuCatSegmentValidation -Project $Project -Segment $segment -AcronymIndex $acronymIndex
        }
    }
    return $changed
}

function New-YakuAgenticReviewItem {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$SourceText,
        [Parameter(Mandatory=$true)][string]$MaskedTranslation,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [ValidateSet('oku','billion')][string]$Notation = 'oku',
        [int]$Index = 1
    )
    $normalized = [string](Convert-YakuNumericUnits -Text $SourceText -Location 'text-agentic-review' -Notation $Notation).Text
    $mask = New-YakuNumericMaskMap -Text $normalized -Root $Root -Direction $Direction -Location 'text-agentic-review'
    return [pscustomobject]@{
        Index=$Index; Text=[string]$mask.Text; MaskedText=[string]$mask.Text; OriginalText=$normalized
        NumericMaskMap=$mask.Map; ProtectionContractVersion='cat-protection-v1'; MaxChars=$null; Terminology=@()
        PipelineSelected=$MaskedTranslation
    }
}

function Invoke-YakuTextAgenticReview {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$SourceText,
        [Parameter(Mandatory=$true)]$Option,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [AllowNull()]$ProgressState
    )
    $notation = Get-YakuAmountNotation -Settings $Settings
    $item = New-YakuAgenticReviewItem -Root $Root -SourceText $SourceText -MaskedTranslation ([string]$Option.MaskedTranslation) -Direction $Direction -Notation $notation
    $numeric = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$item.Text) -Translated ([string]$Option.MaskedTranslation) -Location 'text-agentic-review'
    # 短さは既定の brief にだけ適用する軸。「全文で」は完全性を選んだ結果なので、
    # full であること自体を不合格にしない（空の結果だけは共通で不合格）。
    $brevityApplicable = ($Direction -eq 'to_en' -and [string]$Option.Style -eq 'brief')
    $translationText = [string]$Option.Translation
    $short = -not [string]::IsNullOrWhiteSpace($translationText)
    if ($short -and $brevityApplicable) {
        # A brief result must meet an actual size bound; checking Style again
        # makes this axis tautological. Keep enough room for short source text.
        $briefLimit = [Math]::Max(80, [int][Math]::Ceiling(([string]$SourceText).Length * 2.4))
        $short = ($translationText.Length -le $briefLimit)
    }
    Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '意味を照合しています' -Progress 72 -Detail '意味と読みやすさを別の文脈で同時に点検しています' -Phase 'agent_review'
    $warnings = New-Object System.Collections.Generic.List[object]
    $readItem = Copy-YakuCatPipelineItem $item
    $readItem | Add-Member -NotePropertyName PipelineStage -NotePropertyValue 'readability' -Force
    $readItem.Text = [string]$Option.MaskedTranslation
    $readItem.MaskedText = [string]$Option.MaskedTranslation
    $readItem.OriginalText = [string]$Option.Translation
    $pages = @()
    $handles = New-Object System.Collections.Generic.List[object]
    $laneResults = New-Object 'System.Collections.Concurrent.ConcurrentBag[object]'
    $laneScript = {
        param($Root,$Settings,$Page,$Lane,$Item,$Direction,$Notation,$LaneResults)
        $ErrorActionPreference = 'Stop'
        $script:YakuRoot = $Root
        . (Join-Path $Root 'src\SrcModules.ps1')
        foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }
        $port = Get-YakuCdpPort -Settings $Settings
        $script:YakuCopilotTargetCache = [pscustomobject]@{Port=[int]$port;TargetId=[string]$Page.id}
        $localWarnings = New-Object System.Collections.Generic.List[object]
        $context = @{Workflow='text-agentic';AmountNotation=$Notation;BatchOrdinal=0;TotalBatches=2;TranslatedSoFar=0;UniqueTotal=2;CopilotCalls=0;CompletedMap=@{};JobId=[guid]::NewGuid().ToString('N')}
        try {
            if ($Lane -eq 'meaning') {
                $retry = Invoke-YakuCatFitBackCheck -Root $Root -Items @($Item) -Final @{1=[string]$Item.PipelineSelected} -Settings $Settings -MaxChars 16000 -Warnings $localWarnings -ProgressState $null -Context $context
                $LaneResults.Add([pscustomobject]@{Lane=$Lane;Passed=(-not $retry.ContainsKey(1));Detail='';Warnings=@($localWarnings.ToArray())})
            } else {
                $map = Invoke-YakuCatPipelineBatch -Root $Root -Items @($Item) -Settings $Settings -Direction $Direction -MaxChars 16000 -Warnings $localWarnings -ProgressState $null -Parent $context
                $text = if ($map.ContainsKey(1)) {[string]$map[1]} else {'REVIEW_REQUIRED: 読みやすさを点検できませんでした。'}
                $LaneResults.Add([pscustomobject]@{Lane=$Lane;Passed=[bool]($text -match '(?i)^\s*PASS\s*$');Detail=$text;Warnings=@($localWarnings.ToArray())})
            }
        } catch {
            $LaneResults.Add([pscustomobject]@{Lane=$Lane;Passed=$false;Detail=('点検できませんでした: '+[string]$_.Exception.Message);Warnings=@($localWarnings.ToArray())})
        }
    }
    try {
        $pages = @(New-YakuCopilotWorkerPages -Settings $Settings -Count 2)
        foreach ($laneIndex in 0,1) {
            $lane = if ($laneIndex -eq 0) {'meaning'} else {'readability'}
            $laneItem = if ($laneIndex -eq 0) {$item} else {$readItem}
            $ps = [powershell]::Create()
            $null = $ps.AddScript($laneScript.ToString()).AddArgument($Root).AddArgument($Settings).AddArgument($pages[$laneIndex]).AddArgument($lane).AddArgument($laneItem).AddArgument($Direction).AddArgument($notation).AddArgument($laneResults)
            $handles.Add([pscustomobject]@{PowerShell=$ps;Async=$ps.BeginInvoke()}) | Out-Null
        }
        foreach ($handle in @($handles.ToArray())) { $null = $handle.PowerShell.EndInvoke($handle.Async) }
    } finally {
        foreach ($handle in @($handles.ToArray())) { try {$handle.PowerShell.Dispose()} catch {} }
        if ($pages.Count -gt 0) { try {$null = Close-YakuCopilotWorkerPages -Settings $Settings -Pages $pages} catch {} }
    }
    foreach ($laneResult in @($laneResults.ToArray())) { foreach ($warning in @($laneResult.Warnings)) { $warnings.Add($warning) | Out-Null } }
    $meaningResult = @($laneResults.ToArray() | Where-Object Lane -eq 'meaning' | Select-Object -Last 1)
    $readResult = @($laneResults.ToArray() | Where-Object Lane -eq 'readability' | Select-Object -Last 1)
    $semantic = ($meaningResult.Count -eq 1 -and [bool]$meaningResult[0].Passed)
    $readable = ($readResult.Count -eq 1 -and [bool]$readResult[0].Passed)
    $readText = if ($readResult.Count -eq 1) {[string]$readResult[0].Detail} else {'REVIEW_REQUIRED: 読みやすさを点検できませんでした。'}
    $readable = ($readText -match '(?i)^\s*PASS\s*$')
    Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '数字を検算しています' -Progress 96 -Detail '数値トークンをローカルで照合しています' -Phase 'numeric_check'
    $passed = ([bool]$numeric.Ok -and $short -and $semantic -and $readable)
    try { Write-YakuLog ("Text review axes. short=$short meaning=$semantic readability=$readable numeric=$([bool]$numeric.Ok)") 'INFO' } catch {}
    return [pscustomobject]@{
        Passed=$passed
        Badge=$(if($passed){'機械とAIの点検を通過'}else{'確認ポイントがあります'})
        Numeric=[bool]$numeric.Ok; Short=$short; Meaning=$semantic; Readability=$readable
        ReadabilityDetail=$(if($readable){''}else{$readText})
        Warnings=@($warnings.ToArray())
    }
}
