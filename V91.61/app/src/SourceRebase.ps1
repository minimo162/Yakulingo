<#
  原本差し替えを、Base（現在の原本）+ Ours（人の訳と判断）+ Theirs（新版原本）
  の3-way rebaseとして扱う。ここでは対応計画を純粋に作り、projectは変更しない。
#>

function ConvertTo-YakuRebaseComparableText {
    param([AllowNull()][string]$Text)
    $value = [string]$Text
    try { $value = $value.Normalize([Text.NormalizationForm]::FormKC) } catch {}
    return ([regex]::Replace($value.Replace("`r`n","`n").Replace("`r","`n"), '[\s\u3000]+', ' ')).Trim()
}

function Get-YakuCatSemanticContextHash {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Segments,
        [Parameter(Mandatory=$true)][int]$Index
    )
    $items = @($Segments)
    if ($Index -lt 0 -or $Index -ge $items.Count) { return '' }
    $current = $items[$Index]
    $previous = if ($Index -gt 0) { ConvertTo-YakuRebaseComparableText -Text ([string]$items[$Index - 1].Text) } else { '<start>' }
    $next = if ($Index + 1 -lt $items.Count) { ConvertTo-YakuRebaseComparableText -Text ([string]$items[$Index + 1].Text) } else { '<end>' }
    $sheet = [string]$(try { $current.Sheet } catch { '' })
    $kind = [string]$(try { $current.Kind } catch { '' })
    return (Get-YakuCatSourceIntegrityHash -Text ('semantic-context-v1|' + $kind + '|' + $sheet + '|' + $previous + '|' + (ConvertTo-YakuRebaseComparableText -Text ([string]$current.Text)) + '|' + $next))
}

function Get-YakuCatRebaseTranslationProvenance {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)]$Segment)
    if ([string]::IsNullOrWhiteSpace([string]$Segment.Translation)) { return 'none' }
    $sourceHash = [string]$Segment.SourceIntegrityHash
    $targetHash = Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation)
    $validReview = @($Project.ReviewEvents | Where-Object {
        [string]$_.decision_scope -eq 'translation' -and [string]$_.action -eq 'reviewed' -and
        [string]$_.segment_id -eq [string]$Segment.SegmentId -and [string]$_.source_hash -eq $sourceHash -and [string]$_.target_hash -eq $targetHash
    }).Count -gt 0
    if ($validReview -and [bool]$Segment.Confirmed -and (Test-YakuCatSegmentQcCurrent -Segment $Segment)) { return 'reviewed_current_project' }
    if ([string]$Segment.Origin -eq 'manual' -or [string]$Segment.State -eq 'human_edited') { return 'reference_only' }
    return 'machine_unreviewed'
}

function Get-YakuCatRebaseLocationKey {
    param([AllowNull()]$Segment)
    if ($null -eq $Segment) { return '' }
    $sheet = [string]$(try { $Segment.Sheet } catch { '' })
    $location = [string]$(try { $Segment.Location } catch { '' })
    return ($sheet + '|' + $location).ToLowerInvariant()
}

function Get-YakuCatRebaseDependencyFingerprint {
    param([Parameter(Mandatory=$true)]$Project)
    return (Get-YakuCatSourceIntegrityHash -Text ('source-rebase-dependency-v1|' + [string]$Project.Id + '|' + [int]$Project.Revision + '|' + [string]$Project.ActiveSourceId + '|' + [string]$Project.SourceArtifactSha256))
}

function Test-YakuCatRebaseTextExact {
    param([AllowNull()][string]$Left,[AllowNull()][string]$Right)
    $a=([string]$Left).Replace("`r`n","`n").Replace("`r","`n")
    $b=([string]$Right).Replace("`r`n","`n").Replace("`r","`n")
    return [string]::Equals($a,$b,[StringComparison]::Ordinal)
}

function New-YakuCatPlacementRebaseCandidate {
    <#
      原文mappingとは別に、セルへの配置を再利用できるかを判定する。
      StructureFingerprintには結合・保護・数式だけでなく、wrap、style、
      行高、列幅、非表示状態も含まれる。取得不能を一致とは扱わない。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$TargetProject,
        [Parameter(Mandatory=$true)]$Mapping,
        [Parameter(Mandatory=$true)][string]$TargetSourceId
    )
    if([string]$Mapping.kind -notin @('unchanged','moved_unchanged')){return $null}
    $sourceIds=@($Mapping.source_segment_ids);$targetGroups=@($Mapping.target_block_groups)
    if($sourceIds.Count -ne 1 -or $targetGroups.Count -ne 1){return $null}
    $sourceSegment=@($Project.Segments|Where-Object{[string]$_.SegmentId -eq [string]$sourceIds[0]}|Select-Object -First 1)
    $targetIndex=[int]$targetGroups[0].target_index;$targetSegments=@($TargetProject.Segments)
    if($sourceSegment.Count -ne 1 -or $targetIndex -lt 0 -or $targetIndex -ge $targetSegments.Count){return $null}
    $targetSegment=$targetSegments[$targetIndex]
    # mapping本体は比較用正規化を使うが、配置の継承はlosslessな原文一致だけに絞る。
    if(-not (Test-YakuCatRebaseTextExact -Left ([string]$sourceSegment[0].Text) -Right ([string]$targetSegment.Text))){return $null}
    $oldPlans=@($Project.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$sourceIds[0]})
    if($oldPlans.Count -ne 1){return $null}
    $old=$oldPlans[0];$reasons=New-Object System.Collections.Generic.List[string]
    if([string]$old.status -ne 'current'){$reasons.Add('placement_not_current')|Out-Null}
    try{if(-not [bool](Test-YakuCatPlacementPlanBinding -Project $Project -Segment $sourceSegment[0] -Plan $old).Passed){$reasons.Add('base_placement_binding')|Out-Null}}catch{$reasons.Add('base_placement_binding')|Out-Null}
    $sourceCanonical=[string]$sourceSegment[0].Translation
    if((@($old.destinations|ForEach-Object{[string]$_.text}) -join '') -cne $sourceCanonical){$reasons.Add('publication_variant_invalidated')|Out-Null}
    $oldDestinations=@($old.destinations);$targetIds=@($targetSegment.BlockIds|ForEach-Object{[string]$_});$targetCells=@($targetSegment.Cells)
    if($oldDestinations.Count -ne $targetIds.Count -or $targetCells.Count -ne $targetIds.Count){
        $reasons.Add('cell_count_changed')|Out-Null
        return [pscustomobject]@{placement_id=[string]$old.placement_id;source_segment_id=[string]$sourceIds[0];target_index=$targetIndex;mapping_id=[string]$Mapping.mapping_id;decision='stale';reasons=@($reasons.ToArray());remapped_plan=$null}
    }
    $destinations=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt $targetIds.Count;$i++){
        $oldDestination=$oldDestinations[$i];$targetCell=$targetCells[$i]
        $oldStructure=[string]$(try{$oldDestination.expected_structure_fingerprint}catch{''})
        $targetStructure=[string]$(try{$targetCell.StructureFingerprint}catch{''})
        if([string]::IsNullOrWhiteSpace($oldStructure) -or [string]::IsNullOrWhiteSpace($targetStructure)){$reasons.Add(('structure_fingerprint_missing:'+ $i))|Out-Null}
        elseif($oldStructure -cne $targetStructure){$reasons.Add(('structure_fingerprint_changed:'+ $i))|Out-Null}
        $oldCellText=[string]$(try{$sourceSegment[0].Cells[$i].Text}catch{''});$targetCellText=[string]$(try{$targetCell.Text}catch{''})
        if(-not (Test-YakuCatRebaseTextExact -Left $oldCellText -Right $targetCellText)){$reasons.Add(('cell_source_changed:'+ $i))|Out-Null}
        $targetStructureContract=$(try{$targetCell.StructureContract}catch{$null})
        $destinations.Add([pscustomobject]@{
            block_id=$targetIds[$i];sheet=[string]$targetSegment.Sheet;address=[string]$(try{$targetCell.Address}catch{''});text=[string]$oldDestination.text
            expected_source_hash=(Get-YakuCatSourceIntegrityHash -Text $targetCellText)
            expected_cell_fingerprint=(Get-YakuCatSourceIntegrityHash -Text ($targetIds[$i]+'|'+$targetCellText))
            expected_sheet_code_name=[string]$(try{$targetCell.SheetCodeName}catch{''})
            expected_structure_fingerprint=$targetStructure;structure_contract=$targetStructureContract
            merge_contract=[pscustomobject]@{expected_kind=[string]$(try{$targetStructureContract.merge_kind}catch{'unknown'});expected_area=[string]$(try{$targetStructureContract.merge_area}catch{''});write_anchor_address=[string]$(try{$targetCell.Address}catch{''})}
            mode='replace_source_block'
        })|Out-Null
    }
    $decision=$(if($reasons.Count -eq 0){'reuse_current'}else{'stale'})
    $remapped=[pscustomobject]@{
        placement_id=[string]$old.placement_id;segment_id=[string]$sourceIds[0];source_snapshot_id=$TargetSourceId
        placement_revision=([int]$old.placement_revision+1);placement_kind=[string]$old.placement_kind;status=$(if($decision -eq 'reuse_current'){'current'}else{'stale'})
        publication_text_hash=(Get-YakuCatSourceIntegrityHash -Text $sourceCanonical)
        source_contract=[pscustomobject]@{source_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$targetSegment.Text));source_revision=[int]$targetSegment.SourceRevision;canonical_target_hash=(Get-YakuCatSourceIntegrityHash -Text $sourceCanonical);publication_variant_id='';publication_variant_revision=0;publication_variant_hash='';block_ids=$targetIds}
        destinations=@($destinations.ToArray());display_regions=@($(try{$old.display_regions}catch{@()}));layout_adjustments=@($(try{$old.layout_adjustments}catch{@()}))
        created_at=[string]$(try{$old.created_at}catch{(Get-Date).ToString('o')});rebase_mapping_id=[string]$Mapping.mapping_id;rebase_decision=$decision;rebase_reasons=@($reasons.ToArray());plan_hash=''
    }
    $remapped.plan_hash=Get-YakuCatPlacementPlanHash -Plan $remapped
    return [pscustomobject]@{placement_id=[string]$old.placement_id;source_segment_id=[string]$sourceIds[0];target_index=$targetIndex;mapping_id=[string]$Mapping.mapping_id;decision=$decision;reasons=@($reasons.ToArray());remapped_plan=$remapped}
}

function New-YakuCatPreRebaseCheckpoint {
    <# active manifestとgenerationを、通常generation cleanupの外へ退避する。 #>
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$RebaseId)
    $generationId=[string]$(try{$Project.ActiveGenerationId}catch{''})
    if([string]::IsNullOrWhiteSpace($generationId)){return $null}
    $store=[IO.Path]::GetFullPath((Get-YakuCatProjectStoreDir)).TrimEnd('\')
    $projectDir=[IO.Path]::GetFullPath((Join-Path $store ([string]$Project.Id)))
    if(-not $projectDir.StartsWith($store+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'CAT_REBASE_CHECKPOINT_PATH_INVALID'}
    $manifestPath=Join-Path $projectDir 'project.json';$generationDir=Join-Path (Join-Path $projectDir 'generations') $generationId
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not(Test-Path -LiteralPath $generationDir -PathType Container)){throw 'CAT_REBASE_CHECKPOINT_SOURCE_MISSING'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$manifest.project_revision -ne [int]$Project.Revision -or [string]$manifest.active_generation_id -cne $generationId -or [string]$manifest.active_source_id -cne [string]$Project.ActiveSourceId -or [string]$manifest.source_artifact_sha256 -cne [string]$Project.SourceArtifactSha256){throw 'CAT_REBASE_CHECKPOINT_SOURCE_STALE'}
    $manifestSha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $root=Join-Path $projectDir 'rebase-checkpoints';$final=Join-Path $root ([string][int]$Project.Revision)
    if(Test-Path -LiteralPath $final -PathType Container){
        $existingPath=Join-Path $final 'checkpoint.json';if(-not(Test-Path -LiteralPath $existingPath -PathType Leaf)){throw 'CAT_REBASE_CHECKPOINT_CONFLICT'}
        $existing=Get-Content -LiteralPath $existingPath -Raw -Encoding UTF8|ConvertFrom-Json
        if([int]$existing.checkpoint_revision -ne [int]$Project.Revision -or [string]$existing.active_generation_id -cne $generationId -or [string]$existing.active_source_id -cne [string]$Project.ActiveSourceId -or [string]$existing.source_artifact_sha256 -cne [string]$Project.SourceArtifactSha256 -or [string]$existing.manifest_sha256 -cne $manifestSha){throw 'CAT_REBASE_CHECKPOINT_CONFLICT'}
        return $existing
    }
    if(-not(Test-Path -LiteralPath $root -PathType Container)){$null=New-Item -ItemType Directory -Path $root -Force}
    $stage=Join-Path $root ('.checkpoint-'+[guid]::NewGuid().ToString('N'));$stageGeneration=Join-Path $stage 'generation'
    try{
        $null=New-Item -ItemType Directory -Path $stageGeneration -Force
        [IO.File]::Copy($manifestPath,(Join-Path $stage 'manifest.json'),$false)
        $files=New-Object System.Collections.Generic.List[object]
        foreach($file in @(Get-ChildItem -LiteralPath $generationDir -File)){
            $destination=Join-Path $stageGeneration $file.Name;[IO.File]::Copy($file.FullName,$destination,$false)
            $files.Add([pscustomobject]@{name=[string]$file.Name;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant();size=[int64]$file.Length})|Out-Null
        }
        $checkpoint=[pscustomobject]@{contract_version='cat-rebase-checkpoint-v1';checkpoint_revision=[int]$Project.Revision;rebase_id=$RebaseId;project_id=[string]$Project.Id;active_generation_id=$generationId;active_source_id=[string]$Project.ActiveSourceId;source_artifact_sha256=[string]$Project.SourceArtifactSha256;source_artifact_relative_path=[string]$(try{$Project.SourceArtifactRelativePath}catch{''});manifest_sha256=$manifestSha;generation_files=@($files.ToArray());created_at=(Get-Date).ToString('o')}
        Write-YakuJsonAtomic -Path (Join-Path $stage 'checkpoint.json') -Value $checkpoint -Depth 10
        [IO.Directory]::Move($stage,$final)
        return $checkpoint
    }finally{if(Test-Path -LiteralPath $stage -PathType Container){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}}
}

function New-YakuCatRebaseArchivedSegmentEvidence {
    param([Parameter(Mandatory=$true)]$Segment)
    return [pscustomobject]@{
        segment_id = [string]$Segment.SegmentId
        source_text = [string]$Segment.Text
        source_hash = [string]$Segment.SourceIntegrityHash
        translation = [string]$Segment.Translation
        target_hash = $(if ([string]::IsNullOrWhiteSpace([string]$Segment.Translation)) { '' } else { Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation) })
        translation_provenance = ''
        confirmed = [bool]$Segment.Confirmed
        source_revision = [int]$Segment.SourceRevision
    }
}

function New-YakuCatRebasePlan {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$TargetProject,
        [Parameter(Mandatory=$true)][string]$TargetSourceId,
        [Parameter(Mandatory=$true)][string]$TargetSourceHash,
        [string]$TargetArtifactRelativePath = ''
    )
    $sourceSegments = @($Project.Segments)
    $targetSegments = @($TargetProject.Segments)
    $targetByText = @{}
    $targetByLocation = @{}
    for ($i = 0; $i -lt $targetSegments.Count; $i++) {
        $textKey = ConvertTo-YakuRebaseComparableText -Text ([string]$targetSegments[$i].Text)
        if (-not $targetByText.ContainsKey($textKey)) { $targetByText[$textKey] = New-Object System.Collections.Generic.List[int] }
        $targetByText[$textKey].Add($i)
        $locationKey = Get-YakuCatRebaseLocationKey -Segment $targetSegments[$i]
        if (-not [string]::IsNullOrWhiteSpace($locationKey)) {
            if (-not $targetByLocation.ContainsKey($locationKey)) { $targetByLocation[$locationKey] = New-Object System.Collections.Generic.List[int] }
            $targetByLocation[$locationKey].Add($i)
        }
    }
    $usedTargets = @{}
    $consumedSources = @{}
    $splitBySource = @{}
    $mergeBySourceStart = @{}
    # 1対N / N対1は、連続する最大4単位を連結して一意な場合だけ構造競合として検出する。
    for ($sourceIndex = 0; $sourceIndex -lt $sourceSegments.Count; $sourceIndex++) {
        $sourceText = ConvertTo-YakuRebaseComparableText -Text ([string]$sourceSegments[$sourceIndex].Text)
        $splitCandidates = New-Object System.Collections.Generic.List[object]
        for ($targetStart = 0; $targetStart -lt $targetSegments.Count; $targetStart++) {
            for ($length = 2; $length -le 4 -and ($targetStart + $length) -le $targetSegments.Count; $length++) {
                $joined = ConvertTo-YakuRebaseComparableText -Text (@($targetSegments[$targetStart..($targetStart + $length - 1)] | ForEach-Object { [string]$_.Text }) -join '')
                if ($joined -ceq $sourceText) { $splitCandidates.Add([pscustomobject]@{ Start=$targetStart; Length=$length }) | Out-Null }
            }
        }
        if ($splitCandidates.Count -eq 1) { $splitBySource[$sourceIndex] = $splitCandidates[0] }
    }
    for ($targetIndex = 0; $targetIndex -lt $targetSegments.Count; $targetIndex++) {
        $targetText = ConvertTo-YakuRebaseComparableText -Text ([string]$targetSegments[$targetIndex].Text)
        $mergeCandidates = New-Object System.Collections.Generic.List[object]
        for ($sourceStart = 0; $sourceStart -lt $sourceSegments.Count; $sourceStart++) {
            for ($length = 2; $length -le 4 -and ($sourceStart + $length) -le $sourceSegments.Count; $length++) {
                $joined = ConvertTo-YakuRebaseComparableText -Text (@($sourceSegments[$sourceStart..($sourceStart + $length - 1)] | ForEach-Object { [string]$_.Text }) -join '')
                if ($joined -ceq $targetText) { $mergeCandidates.Add([pscustomobject]@{ Start=$sourceStart; Length=$length }) | Out-Null }
            }
        }
        if ($mergeCandidates.Count -eq 1) {
            $candidate = $mergeCandidates[0]
            $mergeBySourceStart[[int]$candidate.Start] = [pscustomobject]@{ Target=$targetIndex; Length=[int]$candidate.Length }
        }
    }
    $mappings = New-Object System.Collections.Generic.List[object]
    $conflicts = New-Object System.Collections.Generic.List[object]
    for ($sourceIndex = 0; $sourceIndex -lt $sourceSegments.Count; $sourceIndex++) {
        if ($consumedSources.ContainsKey($sourceIndex)) { continue }
        $sourceSegment = $sourceSegments[$sourceIndex]
        $structuralKind = ''
        $structuralSourceIndexes = @($sourceIndex)
        $structuralTargetIndexes = @()
        if ($mergeBySourceStart.ContainsKey($sourceIndex)) {
            $merge = $mergeBySourceStart[$sourceIndex]
            $structuralTargetIndexes = @([int]$merge.Target)
            if (-not $usedTargets.ContainsKey([int]$merge.Target)) {
                $structuralKind = 'merged'
                $structuralSourceIndexes = @($sourceIndex..($sourceIndex + [int]$merge.Length - 1))
            }
        } elseif ($splitBySource.ContainsKey($sourceIndex)) {
            $split = $splitBySource[$sourceIndex]
            $candidateTargets = @([int]$split.Start..([int]$split.Start + [int]$split.Length - 1))
            if (@($candidateTargets | Where-Object { $usedTargets.ContainsKey([int]$_) }).Count -eq 0) {
                $structuralKind = 'split'; $structuralTargetIndexes = $candidateTargets
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($structuralKind)) {
            foreach ($index in $structuralSourceIndexes) { $consumedSources[[int]$index] = $true }
            foreach ($index in $structuralTargetIndexes) { $usedTargets[[int]$index] = $true }
            $sourceIds = @($structuralSourceIndexes | ForEach-Object { [string]$sourceSegments[[int]$_].SegmentId })
            $mappingId = (Get-YakuCatSourceIntegrityHash -Text ('rebase-structure-v1|' + ($sourceIds -join ',') + '|' + $structuralKind + '|' + ($structuralTargetIndexes -join ','))).Substring(0,32)
            $groups = @($structuralTargetIndexes | ForEach-Object { $targetIndex=[int]$_; [pscustomobject]@{ group_id=('target-' + $targetIndex); block_ids=@($targetSegments[$targetIndex].BlockIds); proposed_segment_id=[string]$targetSegments[$targetIndex].SegmentId; target_index=$targetIndex } })
            $archivedEvidence = @($structuralSourceIndexes | ForEach-Object {
                $item = New-YakuCatRebaseArchivedSegmentEvidence -Segment $sourceSegments[[int]$_]
                $item.translation_provenance = Get-YakuCatRebaseTranslationProvenance -Project $Project -Segment $sourceSegments[[int]$_]
                $item
            })
            $mappings.Add([pscustomobject]@{
                mapping_id=$mappingId; source_segment_ids=$sourceIds; source_index=$sourceIndex; target_block_groups=$groups
                kind=$structuralKind; confidence=1.0; evidence=@([pscustomobject]@{type='contiguous_exact_concatenation';source_indexes=$structuralSourceIndexes;target_indexes=$structuralTargetIndexes})
                reuse_decision='requires_human_structure_resolution'; numeric_translation_candidate=''; archived_source_evidence=$archivedEvidence
            }) | Out-Null
            $conflicts.Add([pscustomobject]@{
                conflict_id=(Get-YakuCatSourceIntegrityHash -Text ('rebase-conflict-v1|' + $mappingId)).Substring(0,32)
                mapping_id=$mappingId; kind=$structuralKind; blocking=$true; source_segment_ids=$sourceIds
                message='原文の分割・結合が変わりました。対応を確認してください。'
            }) | Out-Null
            continue
        }
        $sourceText = ConvertTo-YakuRebaseComparableText -Text ([string]$sourceSegment.Text)
        $candidates = @($(if ($targetByText.ContainsKey($sourceText)) { @($targetByText[$sourceText]) } else { @() }) | Where-Object { -not $usedTargets.ContainsKey([int]$_) })
        $kind = ''; $confidence = 0.0; $targetIndexes = @(); $reuse = 'none'; $evidence = New-Object System.Collections.Generic.List[object]
        $numericCandidate = ''
        if ($candidates.Count -eq 1) {
            $targetIndex = [int]$candidates[0]; $targetIndexes = @($targetIndex); $usedTargets[$targetIndex] = $true
            $sameLocation = (Get-YakuCatRebaseLocationKey -Segment $sourceSegment) -eq (Get-YakuCatRebaseLocationKey -Segment $targetSegments[$targetIndex])
            $kind = if ($sameLocation) { 'unchanged' } else { 'moved_unchanged' }
            $confidence = 1.0
            $oldContext = Get-YakuCatSemanticContextHash -Segments $sourceSegments -Index $sourceIndex
            $newContext = Get-YakuCatSemanticContextHash -Segments $targetSegments -Index $targetIndex
            $provenance = Get-YakuCatRebaseTranslationProvenance -Project $Project -Segment $sourceSegment
            $reuse = if ($oldContext -eq $newContext -and $provenance -eq 'reviewed_current_project') { 'reuse_reviewed' }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$sourceSegment.Translation)) { 'preserve_as_candidate' } else { 'none' }
            $evidence.Add([pscustomobject]@{ type='exact_text'; source_index=$sourceIndex; target_index=$targetIndex; semantic_context_equal=($oldContext -eq $newContext); provenance=$provenance }) | Out-Null
        } elseif ($candidates.Count -gt 1) {
            $kind = 'ambiguous'; $confidence = 0.0; $targetIndexes = @($candidates)
        } else {
            $locationKey = Get-YakuCatRebaseLocationKey -Segment $sourceSegment
            $locationCandidates = @($(if ($targetByLocation.ContainsKey($locationKey)) { @($targetByLocation[$locationKey]) } else { @() }) | Where-Object { -not $usedTargets.ContainsKey([int]$_) })
            if ($locationCandidates.Count -eq 1) {
                $targetIndex = [int]$locationCandidates[0]; $targetIndexes = @($targetIndex); $usedTargets[$targetIndex] = $true
                if (-not [string]::IsNullOrWhiteSpace([string]$sourceSegment.Translation) -and (Get-Command Try-YakuVersionNumericUpdate -ErrorAction SilentlyContinue)) {
                    $numericCandidate = [string](Try-YakuVersionNumericUpdate -PriorJa ([string]$sourceSegment.Text) -PriorEn ([string]$sourceSegment.Translation) -CurrentJa ([string]$targetSegments[$targetIndex].Text))
                }
                if (-not [string]::IsNullOrWhiteSpace($numericCandidate)) {
                    $kind = 'numeric_changed'; $confidence = 1.0; $reuse = 'numeric_update_candidate'
                } else {
                    $kind = 'changed'; $confidence = 0.75
                    $reuse = if (-not [string]::IsNullOrWhiteSpace([string]$sourceSegment.Translation)) { 'preserve_as_candidate' } else { 'none' }
                }
                $evidence.Add([pscustomobject]@{ type='same_location'; source_index=$sourceIndex; target_index=$targetIndex }) | Out-Null
            } else {
                $kind = if ($locationCandidates.Count -gt 1) { 'ambiguous' } else { 'removed' }
                $confidence = if ($kind -eq 'removed') { 1.0 } else { 0.0 }
                $targetIndexes = @($locationCandidates)
                $reuse = if (-not [string]::IsNullOrWhiteSpace([string]$sourceSegment.Translation)) { 'archive_translation' } else { 'none' }
            }
        }
        $mappingId = (Get-YakuCatSourceIntegrityHash -Text ('rebase-mapping-v1|' + [string]$sourceSegment.SegmentId + '|' + $kind + '|' + (@($targetIndexes) -join ','))).Substring(0,32)
        $groups = @($targetIndexes | ForEach-Object { $targetIndex = [int]$_; [pscustomobject]@{ group_id=('target-' + $targetIndex); block_ids=@($targetSegments[$targetIndex].BlockIds); proposed_segment_id=[string]$targetSegments[$targetIndex].SegmentId; target_index=$targetIndex } })
        $mapping = [pscustomobject]@{
            mapping_id=$mappingId; source_segment_ids=@([string]$sourceSegment.SegmentId); source_index=$sourceIndex
            target_block_groups=$groups; kind=$kind; confidence=$confidence; evidence=@($evidence.ToArray())
            reuse_decision=$reuse; numeric_translation_candidate=$numericCandidate
            archived_source_evidence=@($(if ($kind -in @('changed','removed','ambiguous')) {
                $item = New-YakuCatRebaseArchivedSegmentEvidence -Segment $sourceSegment
                $item.translation_provenance = $provenance
                $item
            }))
        }
        $mappings.Add($mapping) | Out-Null
        if ($kind -in @('ambiguous','changed','removed','split','merged')) {
            $conflictMessage = if ($kind -eq 'ambiguous') { '対応先を一意に決められません。' }
                elseif ($kind -eq 'changed') { '日本語の文言が変わりました。現在の英訳を参考に修正してください。' }
                elseif ($kind -eq 'removed') { '日本語から削除されています。訳を出力対象から外すか確認してください。' }
                else { '構造が変わりました。対応を確認してください。' }
            $conflicts.Add([pscustomobject]@{
                conflict_id=(Get-YakuCatSourceIntegrityHash -Text ('rebase-conflict-v1|' + $mappingId)).Substring(0,32)
                mapping_id=$mappingId; kind=$kind; blocking=$true; source_segment_ids=@([string]$sourceSegment.SegmentId)
                message=$conflictMessage
            }) | Out-Null
        }
    }
    for ($targetIndex = 0; $targetIndex -lt $targetSegments.Count; $targetIndex++) {
        if ($usedTargets.ContainsKey($targetIndex)) { continue }
        $targetSegment = $targetSegments[$targetIndex]
        $mappingId = (Get-YakuCatSourceIntegrityHash -Text ('rebase-added-v1|' + $TargetSourceId + '|' + $targetIndex + '|' + [string]$targetSegment.SourceIntegrityHash)).Substring(0,32)
        $mappings.Add([pscustomobject]@{
            mapping_id=$mappingId; source_segment_ids=@(); source_index=-1
            target_block_groups=@([pscustomobject]@{ group_id=('target-' + $targetIndex); block_ids=@($targetSegment.BlockIds); proposed_segment_id=[string]$targetSegment.SegmentId; target_index=$targetIndex })
            kind='added'; confidence=1.0; evidence=@([pscustomobject]@{type='unmatched_target';target_index=$targetIndex}); reuse_decision='new_untranslated'; numeric_translation_candidate=''
            archived_source_evidence=@()
        }) | Out-Null
    }
    $placementRebases=New-Object System.Collections.Generic.List[object]
    foreach($mapping in @($mappings.ToArray())){
        $candidate=New-YakuCatPlacementRebaseCandidate -Project $Project -TargetProject $TargetProject -Mapping $mapping -TargetSourceId $TargetSourceId
        if($null -ne $candidate){$placementRebases.Add($candidate)|Out-Null}
    }
    $counts = [ordered]@{}
    foreach ($name in @('unchanged','moved_unchanged','numeric_changed','changed','added','removed','split','merged','ambiguous')) { $counts[$name] = @($mappings | Where-Object { [string]$_.kind -eq $name }).Count }
    $plan = [pscustomobject]@{
        rebase_id=[guid]::NewGuid().ToString('N'); plan_hash=''; base_source_id=[string]$Project.ActiveSourceId
        old_source_hash=[string]$Project.SourceArtifactSha256; target_source_id=$TargetSourceId; new_source_hash=$TargetSourceHash
        target_artifact_relative_path=$TargetArtifactRelativePath
        base_project_revision=[int]$Project.Revision; contract_version='cat-source-rebase-v1'; sheet_mappings=@()
        segment_mappings=@($mappings.ToArray()); placement_rebases=@($placementRebases.ToArray()); conflicts=@($conflicts.ToArray())
        render_profile_rebase=[pscustomobject]@{ source_faithful_base_print_fingerprint=''; explicit_profile_status='needs_reconfirmation'; reasons=@('source_snapshot_changed') }
        summary=$counts; created_at=(Get-Date).ToString('o')
    }
    $plan.plan_hash = Get-YakuCatSourceIntegrityHash -Text (($plan | Select-Object * -ExcludeProperty plan_hash) | ConvertTo-Json -Depth 18 -Compress)
    return $plan
}

function Get-YakuCatRebaseStoreDir {
    param([Parameter(Mandatory=$true)][string]$ProjectId, [Parameter(Mandatory=$true)][string]$RebaseId)
    if ($ProjectId -notmatch '^[a-f0-9]{32}$' -or $RebaseId -notmatch '^[a-f0-9]{32}$') { throw 'CAT_REBASE_ID_INVALID' }
    $store = [IO.Path]::GetFullPath((Get-YakuCatProjectStoreDir)).TrimEnd('\')
    $path = [IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $store $ProjectId) 'rebases') $RebaseId))
    if (-not $path.StartsWith($store + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_REBASE_PATH_INVALID' }
    return $path
}

function New-YakuCatSourceUpdatePreview {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [Parameter(Mandatory=$true)]$Settings
    )
    if ([string]$Project.Source -ne 'file') { throw 'CAT_SOURCE_UPDATE_FILE_PROJECT_REQUIRED' }
    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { throw 'CAT_SOURCE_UPDATE_TARGET_MISSING' }
    $targetFull = [IO.Path]::GetFullPath($TargetPath)
    $extension = [IO.Path]::GetExtension($targetFull).ToLowerInvariant()
    if ($extension -ne [IO.Path]::GetExtension([string]$Project.Path).ToLowerInvariant()) { throw 'CAT_SOURCE_UPDATE_TYPE_MISMATCH' }
    $hashBefore = (Get-FileHash -LiteralPath $targetFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hashBefore -eq ([string]$Project.SourceArtifactSha256).ToLowerInvariant()) { throw 'CAT_SOURCE_UPDATE_NO_CHANGES' }
    $targetProject = New-YakuCatProject -Root $Root -Path $targetFull -Settings $Settings -Direction ([string]$Project.Direction) -Register:$false
    $hashAfter = (Get-FileHash -LiteralPath $targetFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hashAfter -ne $hashBefore) { throw 'CAT_SOURCE_UPDATE_CHANGED_DURING_READ' }
    $targetSourceId = $hashBefore.Substring(0,32)
    $ownedTarget = Get-YakuCatOwnedSourceArtifactPath -ProjectId ([string]$Project.Id) -Extension $extension -SourceSnapshotId $targetSourceId
    $ownedDir = Split-Path -Parent $ownedTarget
    if (-not (Test-Path -LiteralPath $ownedDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $ownedDir -Force }
    if (Test-Path -LiteralPath $ownedTarget -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $ownedTarget -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashBefore) { throw 'CAT_SOURCE_UPDATE_SNAPSHOT_CONFLICT' }
    } else {
        $temp = Join-Path $ownedDir ('.rebase-source-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy($targetFull,$temp,$false)
            if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashBefore) { throw 'CAT_SOURCE_UPDATE_COPY_MISMATCH' }
            [IO.File]::Move($temp,$ownedTarget)
        } finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
    }
    $relative = 'source/revisions/' + $targetSourceId + '/original' + $extension
    $plan = New-YakuCatRebasePlan -Project $Project -TargetProject $targetProject -TargetSourceId $targetSourceId -TargetSourceHash $hashBefore -TargetArtifactRelativePath $relative
    $rebaseDir = Get-YakuCatRebaseStoreDir -ProjectId ([string]$Project.Id) -RebaseId ([string]$plan.rebase_id)
    if (-not (Test-Path -LiteralPath $rebaseDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $rebaseDir -Force }
    $targetProject | Add-Member -NotePropertyName Path -NotePropertyValue $ownedTarget -Force
    Write-YakuJsonAtomic -Path (Join-Path $rebaseDir 'plan.json') -Value $plan -Depth 20
    Write-YakuTextAtomic -Path (Join-Path $rebaseDir 'target-project.clixml') -Text ([Management.Automation.PSSerializer]::Serialize($targetProject,50))
    return $plan
}

function Get-YakuCatSourceUpdatePreview {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][string]$RebaseId)
    $rebaseDir = Get-YakuCatRebaseStoreDir -ProjectId ([string]$Project.Id) -RebaseId $RebaseId
    $planPath = Join-Path $rebaseDir 'plan.json'
    $targetPath = Join-Path $rebaseDir 'target-project.clixml'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf) -or -not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw 'CAT_REBASE_PREVIEW_NOT_FOUND' }
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedPlanHash = Get-YakuCatSourceIntegrityHash -Text (($plan | Select-Object * -ExcludeProperty plan_hash) | ConvertTo-Json -Depth 18 -Compress)
    if ($expectedPlanHash -ne [string]$plan.plan_hash) { throw 'CAT_REBASE_PLAN_INTEGRITY_FAILED' }
    if ([string]$plan.base_source_id -ne [string]$Project.ActiveSourceId -or [string]$plan.old_source_hash -ne [string]$Project.SourceArtifactSha256 -or [int]$plan.base_project_revision -ne [int]$Project.Revision) {
        throw 'CAT_REBASE_PLAN_STALE'
    }
    $projectDir = Split-Path -Parent (Split-Path -Parent $rebaseDir)
    $artifact = [IO.Path]::GetFullPath((Join-Path $projectDir ([string]$plan.target_artifact_relative_path).Replace('/','\')))
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$plan.new_source_hash) { throw 'CAT_REBASE_TARGET_INTEGRITY_FAILED' }
    $targetProject = [Management.Automation.PSSerializer]::Deserialize((Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8))
    return [pscustomobject]@{ Plan=$plan; TargetProject=$targetProject; TargetArtifactPath=$artifact }
}

function ConvertTo-YakuCatRebasePlanView {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][string]$RebaseId)
    $loaded = Get-YakuCatSourceUpdatePreview -Project $Project -RebaseId $RebaseId
    $plan = $loaded.Plan
    $sourceById = @{}; foreach($segment in @($Project.Segments)){$sourceById[[string]$segment.SegmentId]=$segment}
    $targetSegments = @($loaded.TargetProject.Segments)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach($mapping in @($plan.segment_mappings)){
        $sourceSegments = @($mapping.source_segment_ids | ForEach-Object { $sourceById[[string]$_] } | Where-Object { $null -ne $_ })
        $targetIndexes = @($mapping.target_block_groups | ForEach-Object { [int]$_.target_index })
        $targetRows = @($targetIndexes | ForEach-Object { if($_ -ge 0 -and $_ -lt $targetSegments.Count){$targetSegments[$_]} })
        $conflict = @($plan.conflicts | Where-Object { [string]$_.mapping_id -eq [string]$mapping.mapping_id } | Select-Object -First 1)
        $rows.Add([ordered]@{
            mapping_id=[string]$mapping.mapping_id; kind=[string]$mapping.kind; confidence=[double]$mapping.confidence
            old_source=(@($sourceSegments | ForEach-Object { [string]$_.Text }) -join "`n")
            current_translation=(@($sourceSegments | ForEach-Object { [string]$_.Translation }) -join "`n")
            new_source=(@($targetRows | ForEach-Object { [string]$_.Text }) -join "`n")
            targets=@($targetIndexes | ForEach-Object { $targetIndex=[int]$_; [ordered]@{target_index=$targetIndex;text=$(if($targetIndex -ge 0 -and $targetIndex -lt $targetSegments.Count){[string]$targetSegments[$targetIndex].Text}else{''})} })
            reuse_decision=[string]$mapping.reuse_decision; numeric_translation_candidate=[string]$mapping.numeric_translation_candidate
            blocking=($conflict.Count -gt 0 -and [bool]$conflict[0].blocking); message=$(if($conflict.Count){[string]$conflict[0].message}else{''})
        }) | Out-Null
    }
    return [ordered]@{
        rebase_id=[string]$plan.rebase_id; plan_hash=[string]$plan.plan_hash; base_project_revision=[int]$plan.base_project_revision
        base_source_id=[string]$plan.base_source_id; base_source_hash=[string]$plan.old_source_hash; target_source_id=[string]$plan.target_source_id; target_source_hash=[string]$plan.new_source_hash
        summary=$plan.summary; conflicts=@($plan.conflicts); rows=@($rows.ToArray())
    }
}

function New-YakuCatRebaseResolution {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$RebaseId,
        [Parameter(Mandatory=$true)][string]$PlanHash,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Decisions
    )
    $loaded=Get-YakuCatSourceUpdatePreview -Project $Project -RebaseId $RebaseId
    $plan=$loaded.Plan
    if([string]$plan.plan_hash -ne $PlanHash){throw 'CAT_REBASE_PLAN_HASH_MISMATCH'}
    $mappingById=@{};foreach($mapping in @($plan.segment_mappings)){$mappingById[[string]$mapping.mapping_id]=$mapping}
    $normalized=New-Object System.Collections.Generic.List[object]
    $seen=@{}
    foreach($decision in @($Decisions)){
        $mappingId=[string]$decision.mapping_id;$action=[string]$decision.action
        if(-not $mappingById.ContainsKey($mappingId) -or $seen.ContainsKey($mappingId)){throw 'CAT_REBASE_RESOLUTION_MAPPING_INVALID'}
        $mapping=$mappingById[$mappingId];$kind=[string]$mapping.kind;$targetIndex=-1;try{$targetIndex=[int]$decision.target_index}catch{}
        $allowed=$false
        if($kind -eq 'changed' -and $action -in @('preserve_as_candidate','retranslate')){$allowed=$true}
        elseif($kind -eq 'removed' -and $action -eq 'confirm_removed'){$allowed=$true}
        elseif($kind -in @('split','merged') -and $action -eq 'accept_structure_untranslated'){$allowed=$true}
        elseif($kind -eq 'ambiguous' -and $action -eq 'select_target'){
            $allowed=@($mapping.target_block_groups|Where-Object{[int]$_.target_index -eq $targetIndex}).Count -eq 1
        }
        if(-not $allowed){throw 'CAT_REBASE_RESOLUTION_ACTION_INVALID'}
        $reason=([string]$decision.reason).Trim();if($reason.Length -gt 500 -or $reason -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){throw 'CAT_REBASE_RESOLUTION_REASON_INVALID'}
        $normalized.Add([pscustomobject]@{mapping_id=$mappingId;conflict_id=[string]@($plan.conflicts|Where-Object{[string]$_.mapping_id -eq $mappingId}|Select-Object -First 1)[0].conflict_id;action=$action;target_index=$targetIndex;reason=$reason})|Out-Null
        $seen[$mappingId]=$true
    }
    $blockingIds=@($plan.conflicts|Where-Object{[bool]$_.blocking}|ForEach-Object{[string]$_.mapping_id})
    if(@($blockingIds|Where-Object{-not $seen.ContainsKey($_)}).Count -gt 0){throw 'CAT_REBASE_RESOLUTION_INCOMPLETE'}
    $resolution=[pscustomobject]@{
        resolution_id=[guid]::NewGuid().ToString('N');resolution_hash='';rebase_id=[string]$plan.rebase_id;plan_hash=[string]$plan.plan_hash
        base_project_revision=[int]$plan.base_project_revision;decisions=@($normalized.ToArray());decisions_hash='';completed_at=(Get-Date).ToString('o')
    }
    $resolution.decisions_hash=Get-YakuCatSourceIntegrityHash -Text (@($resolution.decisions)|ConvertTo-Json -Depth 8 -Compress)
    $resolution.resolution_hash=Get-YakuCatSourceIntegrityHash -Text (($resolution|Select-Object * -ExcludeProperty resolution_hash)|ConvertTo-Json -Depth 12 -Compress)
    $rebaseDir=Get-YakuCatRebaseStoreDir -ProjectId ([string]$Project.Id) -RebaseId $RebaseId
    $resolutionDir=Join-Path $rebaseDir 'resolutions';if(-not(Test-Path -LiteralPath $resolutionDir -PathType Container)){$null=New-Item -ItemType Directory -Path $resolutionDir -Force}
    Write-YakuJsonAtomic -Path (Join-Path $resolutionDir ([string]$resolution.resolution_id+'.json')) -Value $resolution -Depth 14
    return $resolution
}

function Get-YakuCatRebaseResolution {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$RebaseId,[Parameter(Mandatory=$true)][string]$ResolutionId)
    if($ResolutionId -notmatch '^[a-f0-9]{32}$'){throw 'CAT_REBASE_RESOLUTION_ID_INVALID'}
    $path=Join-Path (Join-Path (Get-YakuCatRebaseStoreDir -ProjectId ([string]$Project.Id) -RebaseId $RebaseId) 'resolutions') ($ResolutionId+'.json')
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'CAT_REBASE_RESOLUTION_NOT_FOUND'}
    $resolution=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    $hash=Get-YakuCatSourceIntegrityHash -Text (($resolution|Select-Object * -ExcludeProperty resolution_hash)|ConvertTo-Json -Depth 12 -Compress)
    if($hash -ne [string]$resolution.resolution_hash){throw 'CAT_REBASE_RESOLUTION_INTEGRITY_FAILED'}
    return $resolution
}

function Apply-YakuCatSourceUpdatePlan {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$RebaseId,
        [Parameter(Mandatory=$true)][string]$PlanHash,
        [string]$ResolutionId='',
        [string]$ResolutionHash=''
    )
    $loaded = Get-YakuCatSourceUpdatePreview -Project $Project -RebaseId $RebaseId
    $plan = $loaded.Plan
    if ([string]$plan.plan_hash -ne $PlanHash) { throw 'CAT_REBASE_PLAN_HASH_MISMATCH' }
    $resolution=$null;$decisionByMapping=@{}
    if(@($plan.conflicts|Where-Object{[bool]$_.blocking}).Count -gt 0){
        if([string]::IsNullOrWhiteSpace($ResolutionId)){throw 'CAT_REBASE_UNRESOLVED_CONFLICTS'}
        $resolution=Get-YakuCatRebaseResolution -Project $Project -RebaseId $RebaseId -ResolutionId $ResolutionId
        if([string]$resolution.resolution_hash -ne $ResolutionHash -or [string]$resolution.plan_hash -ne [string]$plan.plan_hash -or [int]$resolution.base_project_revision -ne [int]$Project.Revision){throw 'CAT_REBASE_RESOLUTION_STALE'}
        foreach($decision in @($resolution.decisions)){$decisionByMapping[[string]$decision.mapping_id]=$decision}
    }
    $checkpoint=New-YakuCatPreRebaseCheckpoint -Project $Project -RebaseId ([string]$plan.rebase_id)
    $oldById = @{}; foreach($segment in @($Project.Segments)){$oldById[[string]$segment.SegmentId]=$segment}
    $targetSegments = @($loaded.TargetProject.Segments)
    foreach($mapping in @($plan.segment_mappings)){
        $groups = @($mapping.target_block_groups)
        $decision=$decisionByMapping[[string]$mapping.mapping_id]
        if([string]$mapping.kind -eq 'ambiguous' -and $null -ne $decision){$groups=@($groups|Where-Object{[int]$_.target_index -eq [int]$decision.target_index})}
        if($groups.Count -ne 1){continue}
        $targetIndex=[int]$groups[0].target_index
        if($targetIndex -lt 0 -or $targetIndex -ge $targetSegments.Count){throw 'CAT_REBASE_TARGET_MAPPING_INVALID'}
        $target=$targetSegments[$targetIndex]
        if([string]$mapping.kind -eq 'added'){continue}
        $sourceIds=@($mapping.source_segment_ids)
        if($sourceIds.Count -ne 1 -or -not $oldById.ContainsKey([string]$sourceIds[0])){throw 'CAT_REBASE_SOURCE_MAPPING_INVALID'}
        $old=$oldById[[string]$sourceIds[0]]
        $target.SegmentId=[string]$old.SegmentId
        if([string]$mapping.kind -in @('unchanged','moved_unchanged')){
            $target.Translation=[string]$old.Translation
            if([string]$mapping.reuse_decision -eq 'reuse_reviewed'){
                $target.SourceRevision=[int]$old.SourceRevision; $target.Origin=[string]$old.Origin; $target.State=[string]$old.State; $target.Confirmed=[bool]$old.Confirmed
                foreach($name in @('QcStatus','QcSourceRevision','QcSourceHash','QcTargetHash','QcContractVersion','QcTerminologyHash','QcFindings','TerminologyUsages','TerminologyExceptions','TerminologyGeneration','TmRegistered','TmRegistrationEventId')){
                    $target | Add-Member -NotePropertyName $name -NotePropertyValue $old.$name -Force
                }
            } elseif(-not [string]::IsNullOrWhiteSpace([string]$old.Translation)){
                $target.Origin='rebase_candidate';$target.State='machine_draft';$target.Confirmed=$false
                $target|Add-Member -NotePropertyName PriorSourceText -NotePropertyValue ([string]$old.Text) -Force
                $target|Add-Member -NotePropertyName PriorTranslation -NotePropertyValue ([string]$old.Translation) -Force
                Reset-YakuCatSegmentQc -Segment $target -KeepState
            }
        } elseif([string]$mapping.kind -eq 'numeric_changed'){
            $target.Translation=[string]$mapping.numeric_translation_candidate;$target.Origin='rebase_numeric_candidate';$target.State='machine_draft';$target.Confirmed=$false
            $target|Add-Member -NotePropertyName PriorSourceText -NotePropertyValue ([string]$old.Text) -Force
            $target|Add-Member -NotePropertyName PriorTranslation -NotePropertyValue ([string]$old.Translation) -Force
            Reset-YakuCatSegmentQc -Segment $target -KeepState
        } elseif([string]$mapping.kind -in @('changed','ambiguous') -and $null -ne $decision){
            if([string]$decision.action -in @('preserve_as_candidate','select_target')){
                $target.Translation=[string]$old.Translation;$target.Origin='rebase_candidate';$target.State='machine_draft';$target.Confirmed=$false
                $target|Add-Member -NotePropertyName PriorSourceText -NotePropertyValue ([string]$old.Text) -Force
                $target|Add-Member -NotePropertyName PriorTranslation -NotePropertyValue ([string]$old.Translation) -Force
                Reset-YakuCatSegmentQc -Segment $target -KeepState
            }
        }
    }
    $oldSourceId=[string]$Project.ActiveSourceId
    $oldSnapshots=@($Project.SourceSnapshots)
    $targetArtifact=[string]$loaded.TargetArtifactPath
    $targetSize=[int64](Get-Item -LiteralPath $targetArtifact).Length
    $extension=[IO.Path]::GetExtension($targetArtifact).ToLowerInvariant()
    $snapshots=New-Object System.Collections.Generic.List[object]
    foreach($snapshot in $oldSnapshots){$snapshots.Add($snapshot)|Out-Null}
    if(@($snapshots|Where-Object{[string]$_.source_snapshot_id -eq [string]$plan.target_source_id}).Count -eq 0){
        $fingerprints=Get-YakuCatSourceSnapshotFingerprints -Project $loaded.TargetProject -ArtifactPath $targetArtifact
        $snapshots.Add([pscustomobject]@{
            source_snapshot_id=[string]$plan.target_source_id;parent_id=$oldSourceId;sha256=[string]$plan.new_source_hash;size=$targetSize
            extension=$extension;artifact_path=[string]$plan.target_artifact_relative_path
            inventory_hash=[string]$fingerprints.InventoryHash;layout_hash=[string]$fingerprints.LayoutHash;print_hash=[string]$fingerprints.PrintHash
            inventory_state=[string]$fingerprints.InventoryState;layout_state=[string]$fingerprints.LayoutState;print_state=[string]$fingerprints.PrintState
            created_at=(Get-Date).ToString('o');contract_version='cat-source-snapshot-v2'
        })|Out-Null
    }
    $Project | Add-Member -NotePropertyName Blocks -NotePropertyValue @($loaded.TargetProject.Blocks) -Force
    $Project.Segments=@($targetSegments)
    $Project | Add-Member -NotePropertyName Path -NotePropertyValue $targetArtifact -Force
    $Project | Add-Member -NotePropertyName FileName -NotePropertyValue ([string]$(try{$loaded.TargetProject.FileName}catch{$Project.FileName})) -Force
    $Project | Add-Member -NotePropertyName ActiveSourceId -NotePropertyValue ([string]$plan.target_source_id) -Force
    $Project | Add-Member -NotePropertyName SourceSnapshots -NotePropertyValue @($snapshots.ToArray()) -Force
    $Project | Add-Member -NotePropertyName AppliedRebaseId -NotePropertyValue ([string]$plan.rebase_id) -Force
    $Project | Add-Member -NotePropertyName SourceArtifactRelativePath -NotePropertyValue ([string]$plan.target_artifact_relative_path) -Force
    $Project | Add-Member -NotePropertyName SourceArtifactSha256 -NotePropertyValue ([string]$plan.new_source_hash) -Force
    $Project | Add-Member -NotePropertyName SourceArtifactSize -NotePropertyValue $targetSize -Force
    $Project | Add-Member -NotePropertyName SourceArtifactContractVersion -NotePropertyValue 'cat-source-v2' -Force
    # 掲載訳は旧原本の文脈・略語初出・配置へ束縛されている。新版採用時は
    # 本文が同じ箇所も履歴として残すだけにし、再確認までactiveにしない。
    foreach($variant in @($Project.PublicationVariants|Where-Object{[string]$_.status -eq 'active'})){$variant.status='stale'}
    $Project|Add-Member -NotePropertyName ActivePublicationVariantBySegment -NotePropertyValue ([pscustomobject]@{}) -Force
    $remappedPlacements=New-Object System.Collections.Generic.List[object]
    foreach($placementRebase in @($plan.placement_rebases)){
        if($null -ne $placementRebase.remapped_plan){$remappedPlacements.Add($placementRebase.remapped_plan)|Out-Null}
    }
    $Project.PlacementPlans=@($remappedPlacements.ToArray());$null=Update-YakuCatPlacementSetHash -Project $Project
    $resolutionHash=$(if($null -ne $resolution){[string]$resolution.resolution_hash}else{''})
    $decisionEvent=Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'rebase' -Action 'source_update_applied' -DependencyFingerprint ([string]$plan.plan_hash+'|'+$resolutionHash)
    $records=New-Object System.Collections.Generic.List[object];foreach($record in @($Project.RebaseRecords)){$records.Add($record)|Out-Null}
    $records.Add([pscustomobject]@{
        rebase_id=[string]$plan.rebase_id;base_source_id=[string]$plan.base_source_id;target_source_id=[string]$plan.target_source_id
        base_project_revision=[int]$plan.base_project_revision;status='applied';algorithm_version=[string]$plan.contract_version
        rebase_plan_hash=[string]$plan.plan_hash;rebase_resolution_hash=$resolutionHash;target_source_hash=[string]$plan.new_source_hash
        plan_relative_path=('rebases/' + [string]$plan.rebase_id + '/plan.json')
        resolution_id=$(if($null -ne $resolution){[string]$resolution.resolution_id}else{''})
        summary=$plan.summary;applied_revision=([int]$Project.Revision+1)
        checkpoint_revision=$(if($null -ne $checkpoint){[int]$checkpoint.checkpoint_revision}else{0})
        checkpoint_relative_path=$(if($null -ne $checkpoint){'rebase-checkpoints/'+[string]$checkpoint.checkpoint_revision+'/checkpoint.json'}else{''})
        checkpoint_manifest_sha256=$(if($null -ne $checkpoint){[string]$checkpoint.manifest_sha256}else{''})
        applied_at=(Get-Date).ToString('o');decision_event_ids=@([string]$decisionEvent)
    })|Out-Null
    $Project.RebaseRecords=@($records.ToArray())
    return [pscustomobject]@{ RebaseId=[string]$plan.rebase_id; Summary=$plan.summary; DecisionEventId=[string]$decisionEvent }
}
