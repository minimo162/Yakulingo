<#
  前版日本語・前版英語・現版日本語から、現版のCAT作業を作る。

  Horizon 2 の最小縦断実装では、文書I/Oや曖昧なアライメントをここへ混ぜない。
  1行（1段落）単位の日英対が揃っている場合だけ、同一日本語の英語をそのまま
  候補として継承する。継承した訳も現版では未確認で、QCと人の確認を必須とする。
#>

function ConvertTo-YakuVersionExactText {
    param([AllowNull()][string]$Text)
    $value = [string]$Text
    try { $value = $value.Normalize([Text.NormalizationForm]::FormKC) } catch {}
    $value = $value -replace "`r`n?", "`n"
    $value = [regex]::Replace($value, '[\s\u3000]+', ' ')
    return $value.Trim()
}

function Split-YakuVersionBlocks {
    param([AllowNull()][string]$Text)
    $source = ([string]$Text -replace "`r`n?", "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($source)) { return @() }
    $lines = @($source -split "`n" | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 1) { return $lines }
    if (Get-Command Split-YakuTextIntoSegments -ErrorAction SilentlyContinue) {
        return @(Split-YakuTextIntoSegments -Text $source)
    }
    return @($source)
}

function Get-YakuVersionNumericSkeleton {
    param([AllowNull()][string]$Text,[ValidateSet('to_en','to_jp')][string]$Direction)
    $mask=New-YakuNumericMaskMap -Text ([string]$Text) -Direction $Direction -Location 'version-update-skeleton'
    $value=[string]$mask.Text
    foreach($token in @($mask.Map.Keys)){ $value=$value.Replace([string]$token,'[[NUMBER]]') }
    return [pscustomobject]@{ Text=(ConvertTo-YakuVersionExactText -Text $value); Count=@($mask.Map.Keys).Count; Mask=$mask }
}

function ConvertTo-YakuVersionDecimal {
    param([AllowNull()][string]$Text)
    [decimal]$number=0
    $normalized=(ConvertTo-YakuMaskNormalizedText -Text ([string]$Text)).Replace(',','').Trim()
    $ok=[decimal]::TryParse($normalized,[Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)
    return [pscustomobject]@{Ok=$ok;Value=$number}
}

function Try-YakuVersionNumericUpdate {
    <#
      数値以外が同一で、旧日本語・旧英語の数値事実が完全一致し、全数値を
      一対一に更新できる場合だけ前回英語をローカル更新する。単位・通貨・符号、
      件数、順序が一つでも曖昧なら何も返さず通常翻訳へ回す。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$PriorJa,
        [Parameter(Mandatory=$true)][string]$PriorEn,
        [Parameter(Mandatory=$true)][string]$CurrentJa
    )
    try {
        $oldSkeleton=Get-YakuVersionNumericSkeleton -Text $PriorJa -Direction to_en
        $newSkeleton=Get-YakuVersionNumericSkeleton -Text $CurrentJa -Direction to_en
        if ($oldSkeleton.Count -le 0 -or $oldSkeleton.Count -ne $newSkeleton.Count -or [string]$oldSkeleton.Text -ne [string]$newSkeleton.Text) { return $null }
        $oldFacts=@(Get-YakuCanonicalNumericFacts -Text $PriorJa -Direction to_en -Location 'version-old-ja')
        $newFacts=@(Get-YakuCanonicalNumericFacts -Text $CurrentJa -Direction to_en -Location 'version-new-ja')
        $enFacts=@(Get-YakuCanonicalNumericFacts -Text $PriorEn -Direction to_jp -Location 'version-old-en')
        $enMask=New-YakuNumericMaskMap -Text $PriorEn -Direction to_jp -Location 'version-old-en-mask'
        $tokens=@($enMask.Map.Keys | Sort-Object { [int]([regex]::Match([string]$_,'\d+').Value) })
        if ($oldFacts.Count -ne $newFacts.Count -or $oldFacts.Count -ne $enFacts.Count -or $tokens.Count -ne $enFacts.Count) { return $null }
        $replacement=@{}
        for($i=0;$i -lt $oldFacts.Count;$i++){
            if ([string]$oldFacts[$i].Key -ne [string]$enFacts[$i].Key) { return $null }
            if ([string]$oldFacts[$i].Category -ne [string]$newFacts[$i].Category) { return $null }
            [decimal]$oldValue=0;[decimal]$newValue=0
            if (-not [decimal]::TryParse([string]$enFacts[$i].Value,[Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$oldValue)) { return $null }
            if (-not [decimal]::TryParse([string]$newFacts[$i].Value,[Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$newValue)) { return $null }
            if (($oldValue -lt 0) -ne ($newValue -lt 0)) { return $null }
            $raw=ConvertTo-YakuVersionDecimal -Text ([string]$enMask.Map[[string]$tokens[$i]])
            if (-not [bool]$raw.Ok -or [decimal]$raw.Value -eq 0 -or $oldValue -eq 0) { return $null }
            [decimal]$scale=[Math]::Abs($oldValue / [decimal]$raw.Value)
            if ($scale -le 0) { return $null }
            [decimal]$newRaw=[Math]::Abs($newValue / $scale)
            $oldRawText=[string]$enMask.Map[[string]$tokens[$i]]
            $format=if($oldRawText.Contains(',')){'#,0.############################'}else{'0.############################'}
            $replacement[[string]$tokens[$i]]=$newRaw.ToString($format,[Globalization.CultureInfo]::InvariantCulture)
        }
        $updated=[string]$enMask.Text
        foreach($token in $tokens){$updated=$updated.Replace([string]$token,[string]$replacement[[string]$token])}
        $probe=[pscustomobject]@{Direction='to_en'}
        $probeSegment=[pscustomobject]@{
            Text=$CurrentJa;Translation=$updated;SourceRevision=1;SegmentId='version-numeric-probe'
            QcStatus='not_run';QcSourceRevision=0;QcSourceHash='';QcTargetHash='';QcContractVersion='';QcFindings=@()
        }
        $qc=Invoke-YakuCatSegmentValidation -Project $probe -Segment $probeSegment
        if (-not [bool]$qc.Passed) { return $null }
        return $updated
    } catch { return $null }
}

function New-YakuCatProjectFromPriorVersion {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentJa,
        [AllowNull()][string]$PriorJa,
        [AllowNull()][string]$PriorEn,
        [ValidateSet('verified_release','verified_internal','reference_only','none')][string]$PriorEvidence = 'none',
        [string]$DocumentName = '前版から更新'
    )
    $current = @(Split-YakuVersionBlocks -Text $CurrentJa)
    if ($current.Count -eq 0) { throw 'VERSION_UPDATE_CURRENT_EMPTY: 今回の日本語を入力してください。' }
    $priorSource = @(Split-YakuVersionBlocks -Text $PriorJa)
    $priorTarget = @(Split-YakuVersionBlocks -Text $PriorEn)
    if (($priorSource.Count -eq 0) -xor ($priorTarget.Count -eq 0)) {
        throw 'VERSION_UPDATE_PRIOR_PAIR_REQUIRED: 過去資料は日本語と英語を両方入力してください。'
    }
    $baselineAligned = ($priorSource.Count -gt 0 -and $priorSource.Count -eq $priorTarget.Count)
    $verifiedEvidence = $PriorEvidence -in @('verified_release','verified_internal')
    $automaticReuseAllowed = ($baselineAligned -and $verifiedEvidence)

    $priorByExact = @{}
    for ($i = 0; $i -lt $priorSource.Count; $i++) {
        $key = ConvertTo-YakuVersionExactText -Text ([string]$priorSource[$i])
        if (-not $priorByExact.ContainsKey($key)) { $priorByExact[$key] = New-Object System.Collections.Generic.List[int] }
        $priorByExact[$key].Add($i) | Out-Null
    }

    $segments = New-Object System.Collections.Generic.List[object]
    $carried = 0; $numericUpdated=0; $changed = 0; $newCount = 0; $ambiguous = 0; $referenceOnly = 0
    for ($i = 0; $i -lt $current.Count; $i++) {
        $text = [string]$current[$i]
        $key = ConvertTo-YakuVersionExactText -Text $text
        $candidates = if ($priorByExact.ContainsKey($key)) { @($priorByExact[$key].ToArray()) } else { @() }
        $matchedIndex = -1
        if ($candidates -contains $i) { $matchedIndex = $i }
        elseif ($candidates.Count -eq 1) { $matchedIndex = [int]$candidates[0] }
        elseif ($candidates.Count -gt 1) { $ambiguous++ }

        $translation = ''
        $origin = ''
        $changeKind = 'new'
        $priorSourceText = ''
        $priorTranslation = ''
        $reuseEvidence = ''
        if ($matchedIndex -ge 0 -and $matchedIndex -lt $priorTarget.Count) {
            $priorSourceText = [string]$priorSource[$matchedIndex]
            $priorTranslation = [string]$priorTarget[$matchedIndex]
            $changeKind = if ($matchedIndex -eq $i) { 'unchanged' } else { 'moved_unchanged' }
            if ($automaticReuseAllowed) {
                $translation = $priorTranslation
                $origin = 'carried_forward'
                $reuseEvidence = $PriorEvidence
                $carried++
            } else {
                $changeKind = 'unchanged_reference_only'
                $referenceOnly++
            }
        } elseif ($i -lt $priorSource.Count) {
            $matchedIndex=$i
            $priorSourceText = [string]$priorSource[$i]
            if ($i -lt $priorTarget.Count) { $priorTranslation = [string]$priorTarget[$i] }
            $changeKind = 'changed'
            if ($automaticReuseAllowed -and -not [string]::IsNullOrWhiteSpace($priorTranslation)) {
                $numericTranslation=Try-YakuVersionNumericUpdate -PriorJa $priorSourceText -PriorEn $priorTranslation -CurrentJa $text
                if (-not [string]::IsNullOrWhiteSpace([string]$numericTranslation)) {
                    $translation=[string]$numericTranslation; $origin='numeric_update'; $reuseEvidence=$PriorEvidence
                    $changeKind='numeric_updated'; $numericUpdated++
                } else { $changed++ }
            } else { $changed++ }
        } else {
            $newCount++
        }

        $segment = [pscustomobject]@{
            Text = $text; BlockIds=@(); Cells=@(); Joined=$false; Kind='text'; Sheet=''; Location=('段落 ' + ($i + 1))
            Translation=$translation; Origin=$origin; Confirmed=$false
            ChangeKind=$changeKind; PriorSourceText=$priorSourceText; PriorTranslation=$priorTranslation
            ReuseEvidence=$reuseEvidence; PriorIndex=$matchedIndex
        }
        [void]$segments.Add($segment)
    }

    $project = [pscustomobject]@{
        Id=[guid]::NewGuid().ToString('N'); Path=''; FileName=$(if ([string]::IsNullOrWhiteSpace($DocumentName)) { '前版から更新' } else { $DocumentName })
        Direction='to_en'; Blocks=@(); Segments=@($segments.ToArray()); Warnings=@(); Source='prior_version'; CreatedAt=(Get-Date).ToString('s')
        PriorVersion=[pscustomobject]@{
            Evidence=$PriorEvidence; BaselineAligned=$baselineAligned; AutomaticReuseAllowed=$automaticReuseAllowed
            PriorJaHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$PriorJa)); PriorEnHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$PriorEn))
            CurrentJaHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$CurrentJa)); ContractVersion='version-update-v2'
        }
        VersionUpdateSummary=[pscustomobject]@{
            Current=$current.Count; PriorJa=$priorSource.Count; PriorEn=$priorTarget.Count; CarriedForward=$carried; NumericUpdated=$numericUpdated
            Changed=$changed; New=$newCount; Ambiguous=$ambiguous; ReferenceOnly=$referenceOnly
        }
    }
    $null = Initialize-YakuCatProjectState -Project $project
    return $project
}
