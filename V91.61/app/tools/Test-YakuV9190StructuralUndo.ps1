<# V91.90: 行IDを作り替える結合/分割の直前1回だけを安全に戻す回帰。 #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$YakuT9190Root=Split-Path -Parent $PSScriptRoot;$YakuT9190Src=Join-Path $YakuT9190Root 'src'
$script:YakuT9190Failures=New-Object System.Collections.Generic.List[string]
function Assert-T9190 { param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message)}else{Write-Host ('  NG   '+$Message);[void]$script:YakuT9190Failures.Add($Message)} }
function New-T9190Project {
    param([int]$Count=3)
    $rows=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt $Count;$i++){[void]$rows.Add([pscustomobject]@{Text=('source '+$i+' text');Translation=('target '+$i);Kind='text';Location=[string]$i;Joined=$false;BlockIds=@();Cells=@();Origin='manual';Confirmed=$true})}
    $p=[pscustomobject]@{Id=([guid]::NewGuid().ToString('N'));Segments=$rows.ToArray();Blocks=@();ReviewEvents=@();PublicationVariants=@();ActivePublicationVariantBySegment=[pscustomobject]@{};Source='text';Direction='to_en';Revision=0;FileName='structural.txt'}
    $null=Initialize-YakuCatProjectState -Project $p
    return $p
}
function New-T9190CellProject {
    $safe=[pscustomobject]@{contract_version='excel-cell-structure-v2';read_status='verified';merge_kind='none';merge_area='';has_formula=$false;has_array_formula=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none';wrap_text='False'}
    $safeHash=Get-YakuCatSourceIntegrityHash -Text ($safe|ConvertTo-Json -Depth 6 -Compress)
    $rows=New-Object System.Collections.Generic.List[object];$blocks=New-Object System.Collections.Generic.List[object]
    foreach($entry in @(@('a','A1'),@('long unrelated source text','A2'),@('unrelated source','A3'))){
        $text=[string]$entry[0];$address=[string]$entry[1];$blockId=('cell-'+$address);$row=[int]$address.Substring(1)
        $cell=[pscustomobject]@{Text=$text;Address=$address;Row=$row;Column=1;IsText=$true;IsMerged=$false;BlockId=$blockId;SheetCodeName='Sheet1';StructureContract=$safe;StructureFingerprint=$safeHash}
        [void]$rows.Add([pscustomobject]@{SegmentId='';Text=$text;Translation='';Origin='manual';Kind='cell';BlockIds=@($blockId);Cells=@($cell);Sheet='Sheet1';Location=('Sheet1, '+$address);Joined=$false;Confirmed=$true})
        [void]$blocks.Add([pscustomobject]@{Id=$blockId;Text=$text;Location=('Sheet1, '+$address);Meta=[pscustomobject]@{Kind='cell';Sheet='Sheet1';Row=$row;Col=1;A1=$address;Merged=$false;SheetCodeName='Sheet1';StructureContract=$safe;StructureFingerprint=$safeHash}})
    }
    $p=[pscustomobject]@{Id=([guid]::NewGuid().ToString('N'));Segments=$rows.ToArray();Blocks=$blocks.ToArray();ReviewEvents=@();PublicationVariants=@();ActivePublicationVariantBySegment=[pscustomobject]@{};Source='text';Direction='to_en';Revision=0;FileName='structural-cells.txt'}
    $null=Initialize-YakuCatProjectState -Project $p
    return $p
}
function Invoke-T9190Structure {param($Project,[string]$Operation,[int]$Index,[int]$Position=-1)
    $m={param($candidate,$op,$i,$pos)Invoke-YakuCatStructuralEdit -Project $candidate -Operation $op -Index $i -Position $pos}
    return (Invoke-YakuCatProjectMutation -ProjectId ([string]$Project.Id) -ExpectedRevision ([int]$Project.Revision) -Mutation $m -Arguments @($Operation,$Index,$Position) -Action $Operation)
}
function Invoke-T9190Undo {param($Project)
    return (Invoke-YakuCatProjectMutation -ProjectId ([string]$Project.Id) -ExpectedRevision ([int]$Project.Revision) -Mutation {param($candidate)Undo-YakuCatStructuralEdit -Project $candidate} -Action structure-undo)
}

Write-Host 'Test-YakuV9190StructuralUndo'
. (Join-Path $YakuT9190Src 'SrcModules.ps1')
foreach($YakuT9190File in $script:YakuSrcModuleFiles){if($YakuT9190File -eq 'DesktopIntegration.ps1'){continue};. (Join-Path $YakuT9190Src $YakuT9190File)}
$YakuT9190Temp=Join-Path ([IO.Path]::GetTempPath()) ('yaku-structural-undo-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $YakuT9190Temp -Force;$script:YakuT9190Store=Join-Path $YakuT9190Temp 'store'
function Get-YakuCatProjectStoreDir {return $script:YakuT9190Store}
try {
    $project=New-T9190Project;$null=Commit-YakuNewCatProject -Project $project;$project=Get-YakuCatProject -Id ([string]$project.Id)
    $rich=$project.Segments[0];$rich|Add-Member -NotePropertyName MaskedTranslation -NotePropertyValue 'masked-fixture' -Force;$rich|Add-Member -NotePropertyName State -NotePropertyValue 'reviewed' -Force;$rich|Add-Member -NotePropertyName Confirmed -NotePropertyValue $true -Force;$rich|Add-Member -NotePropertyName QcStatus -NotePropertyValue 'failed' -Force;$rich|Add-Member -NotePropertyName QcSourceRevision -NotePropertyValue ([int]$rich.SourceRevision) -Force;$rich|Add-Member -NotePropertyName QcSourceHash -NotePropertyValue ([string]$rich.SourceIntegrityHash) -Force;$rich|Add-Member -NotePropertyName QcTargetHash -NotePropertyValue 'qc-target' -Force;$rich|Add-Member -NotePropertyName QcContractVersion -NotePropertyValue 'fixture-qc' -Force;$rich|Add-Member -NotePropertyName QcTerminologyHash -NotePropertyValue 'fixture-terms' -Force;$rich|Add-Member -NotePropertyName QcFindings -NotePropertyValue @([pscustomobject]@{code='fixture';severity='error'}) -Force;$rich|Add-Member -NotePropertyName TmRegistered -NotePropertyValue $true -Force;$rich|Add-Member -NotePropertyName TmRegistrationEventId -NotePropertyValue 'fixture-tm' -Force;$rich|Add-Member -NotePropertyName ReferenceUsage -NotePropertyValue ([pscustomobject]@{reference_id='fixture-ref';edited_after_insert=$false}) -Force;$rich|Add-Member -NotePropertyName ReferenceEvents -NotePropertyValue @([pscustomobject]@{action='inserted';target_hash='fixture-target'}) -Force;$rich|Add-Member -NotePropertyName TerminologyUsages -NotePropertyValue @([pscustomobject]@{term_id='fixture-term'}) -Force;$rich|Add-Member -NotePropertyName TerminologyExceptions -NotePropertyValue @([pscustomobject]@{term_id='fixture-exception'}) -Force;$rich|Add-Member -NotePropertyName TerminologyGeneration -NotePropertyValue @([pscustomobject]@{term_id='fixture-generation'}) -Force;$rich|Add-Member -NotePropertyName ChangeKind -NotePropertyValue 'fixture-change' -Force;$rich|Add-Member -NotePropertyName PriorSourceText -NotePropertyValue 'prior source' -Force;$rich|Add-Member -NotePropertyName PriorTranslation -NotePropertyValue 'prior target' -Force;$rich|Add-Member -NotePropertyName ReuseEvidence -NotePropertyValue 'fixture evidence' -Force
    $variant=[pscustomobject]@{variant_id='fixture-variant';segment_id=[string]$rich.SegmentId;revision=1;canonical_target_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$rich.Translation));text=[string]$rich.Translation;text_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$rich.Translation));change_kind='fixture';abbreviation_use_ids=@();generation_origin='fixture';semantic_review_status='approved';source_facts_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$rich.Text));candidate_context_hash='fixture';status='active';variant_hash=''};$variant.variant_hash=Get-YakuCatPublicationVariantHash -Variant $variant
    $variantSecond=Copy-YakuCatStructuralUndoValue -Value $variant;$variantSecond.variant_id='fixture-variant-b';$variantSecond.segment_id=[string]$project.Segments[1].SegmentId;$variantSecond.text=[string]$project.Segments[1].Translation;$variantSecond.text_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$variantSecond.text);$variantSecond.canonical_target_hash=[string]$variantSecond.text_hash;$variantSecond.source_facts_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$project.Segments[1].Text);$variantSecond.variant_hash=Get-YakuCatPublicationVariantHash -Variant $variantSecond
    $variantUnrelated=Copy-YakuCatStructuralUndoValue -Value $variant;$variantUnrelated.variant_id='fixture-variant-unrelated';$variantUnrelated.segment_id=[string]$project.Segments[2].SegmentId;$variantUnrelated.text=[string]$project.Segments[2].Translation;$variantUnrelated.text_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$variantUnrelated.text);$variantUnrelated.canonical_target_hash=[string]$variantUnrelated.text_hash;$variantUnrelated.source_facts_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$project.Segments[2].Text);$variantUnrelated.variant_hash=Get-YakuCatPublicationVariantHash -Variant $variantUnrelated;$unrelatedVariantJson=$variantUnrelated|ConvertTo-Json -Depth 24 -Compress
    $project | Add-Member -NotePropertyName PublicationVariants -NotePropertyValue @($variant,$variantUnrelated,$variantSecond) -Force;foreach($v in @($variant,$variantSecond,$variantUnrelated)){$project.ActivePublicationVariantBySegment | Add-Member -NotePropertyName ([string]$v.segment_id) -NotePropertyValue ([string]$v.variant_id) -Force}
    $before=Get-YakuCatStructuralUndoSegmentsHash -Segments @($project.Segments);$idsBefore=@($project.Segments|ForEach-Object{$_.SegmentId})
    $merge=Invoke-T9190Structure -Project $project -Operation merge -Index 0;$project=$merge.Project
    Assert-T9190 ($null -ne $project.PendingStructuralUndo -and [string]$project.PendingStructuralUndo.operation -eq 'merge' -and [int]$project.PendingStructuralUndo.affected_count -eq 2 -and $null -eq $project.PendingBulkReplaceUndo) 'merge issues one structural ticket and invalidates bulk undo'
    Assert-T9190 (@($project.Segments).Count -eq 2 -and @($project.PublicationVariants|Where-Object{[string]$_.status -eq 'active'}).Count -eq 1 -and [string]@($project.PublicationVariants|Where-Object{[string]$_.variant_id -eq 'fixture-variant-unrelated'})[0].status -eq 'active') 'merge stales only active variants for removed SegmentIds'
    Assert-T9190 (@($project.ReviewEvents|Where-Object{$_.action -eq 'structure_merge'}).Count -eq 1) 'original structural edit is audited'
    $tampered=Copy-YakuCatProjectForMutation -Project $project;$tampered.PendingStructuralUndo.before_state_hash='0'*64;$tamperedRejected=$false;try{Undo-YakuCatStructuralEdit -Project $tampered|Out-Null}catch{$tamperedRejected=$_.Exception.Message -match '^CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID'}
    Assert-T9190 $tamperedRejected 'tampered pre-operation whole-state hash fails closed before commit'
    $id=[string]$project.Id;Remove-YakuCatProject -Id $id;$project=Restore-YakuCatProject -Id $id
    Assert-T9190 ($null -ne $project.PendingStructuralUndo -and [bool]((ConvertTo-YakuCatProjectJson -Project $project|ConvertFrom-Json).structural_undo.available)) 'generation save/restore retains structural ticket and view availability'
    $undo=Invoke-T9190Undo -Project $project;$project=$undo.Project
    Assert-T9190 ([int]$undo.Result.Restored -eq 2 -and $null -eq $project.PendingStructuralUndo -and (Get-YakuCatStructuralUndoSegmentsHash -Segments @($project.Segments)) -eq $before -and ((@($project.Segments|ForEach-Object{$_.SegmentId}) -join '|') -eq ($idsBefore -join '|'))) 'merge undo restores the exact ordered full segment state and consumes its one opportunity'
    Assert-T9190 ([string]$project.Segments[0].MaskedTranslation -eq 'masked-fixture' -and [string]$project.Segments[0].QcStatus -eq 'failed' -and [bool]$project.Segments[0].TmRegistered -and [string]$project.Segments[0].ReferenceUsage.reference_id -eq 'fixture-ref' -and @($project.Segments[0].TerminologyUsages).Count -eq 1 -and [string]$project.Segments[0].ChangeKind -eq 'fixture-change') 'undo restores non-default mask, QC, TM, reference, terminology, and reuse state'
    Assert-T9190 (@($project.PublicationVariants|Where-Object{[string]$_.variant_id -eq 'fixture-variant' -and [string]$_.status -eq 'active'}).Count -eq 1 -and [string]$project.ActivePublicationVariantBySegment.([string]$project.Segments[0].SegmentId) -eq 'fixture-variant' -and ((@($project.PublicationVariants|ForEach-Object{[string]$_.variant_id}) -join '|') -ceq 'fixture-variant|fixture-variant-unrelated|fixture-variant-b') -and ((@($project.PublicationVariants|Where-Object{[string]$_.variant_id -eq 'fixture-variant-unrelated'})[0]|ConvertTo-Json -Depth 24 -Compress) -ceq $unrelatedVariantJson) -and @($project.ReviewEvents|Where-Object{$_.action -eq 'structure_undone'}).Count -eq 1) 'undo restores active publication variant/map, keeps interleaved history order, and appends audit'

    $splitBase=New-T9190Project;$null=Commit-YakuNewCatProject -Project $splitBase;$splitBase=Get-YakuCatProject -Id ([string]$splitBase.Id)
    $merged=Invoke-T9190Structure -Project $splitBase -Operation merge -Index 0;$splitBase=$merged.Project;$splitBefore=Get-YakuCatStructuralUndoSegmentsHash -Segments @($splitBase.Segments)
    $split=Invoke-T9190Structure -Project $splitBase -Operation split -Index 0;$splitBase=$split.Project
    Assert-T9190 ([string]$splitBase.PendingStructuralUndo.operation -eq 'split' -and $null -eq $splitBase.PendingBulkReplaceUndo) 'a later split supersedes the earlier structural ticket'
    $splitUndo=Invoke-T9190Undo -Project $splitBase;$splitBase=$splitUndo.Project
    Assert-T9190 ((Get-YakuCatStructuralUndoSegmentsHash -Segments @($splitBase.Segments)) -eq $splitBefore) 'split undo restores its immediate pre-split state exactly'

    $at=New-T9190Project;$null=Commit-YakuNewCatProject -Project $at;$at=Get-YakuCatProject -Id ([string]$at.Id);$atBefore=Get-YakuCatStructuralUndoSegmentsHash -Segments @($at.Segments)
    $atChange=Invoke-T9190Structure -Project $at -Operation split-at -Index 0 -Position 7;$at=$atChange.Project
    Assert-T9190 (@($at.Segments).Count -eq 4 -and [string]$at.PendingStructuralUndo.operation -eq 'split-at') 'split-at creates its own pending structural ticket'
    $atUndo=Invoke-T9190Undo -Project $at;$at=$atUndo.Project
    Assert-T9190 ((Get-YakuCatStructuralUndoSegmentsHash -Segments @($at.Segments)) -eq $atBefore) 'split-at undo restores source, translation, QC, TM, reference, and terminology state as one row'

    # cell の human_confirmed は auto_weighted と違い、人が決めた掲載セル境界である。
    # 2セルを結合してから分割し、再起動をまたいだ undo でも plan JSON/順序/hash を
    # 丸ごと戻せることを測る。A3 は対象外なので触れてはならない。
    $cell=New-T9190CellProject;$null=Merge-YakuCatSegments -Project $cell -Index 0;$null=Set-YakuCatSegmentTranslation -Project $cell -Index 0 -Text 'MANUAL-FIRST-MANUAL-SECOND';$null=Set-YakuCatSegmentTranslation -Project $cell -Index 1 -Text 'unrelated target';$null=Sync-YakuCatPlacementPlans -Project $cell
    $autoCellPlan=Copy-YakuCatStructuralUndoValue -Value @($cell.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$cell.Segments[0].SegmentId})[0]
    $null=Set-YakuCatPlacementSlices -Project $cell -Index 0 -Slices @('MANUAL-FIRST-','MANUAL-SECOND')
    $manualCellPlan=Copy-YakuCatStructuralUndoValue -Value @($cell.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$cell.Segments[0].SegmentId})[0]
    $unrelatedCellPlan=Copy-YakuCatStructuralUndoValue -Value @($cell.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$cell.Segments[1].SegmentId})[0]
    $cellPlanJson=$manualCellPlan|ConvertTo-Json -Depth 30 -Compress;$unrelatedCellPlanJson=$unrelatedCellPlan|ConvertTo-Json -Depth 30 -Compress;$cellSetHash=[string]$cell.PlacementSetHash
    Assert-T9190 ([string]$manualCellPlan.placement_kind -eq 'human_confirmed' -and [string]$manualCellPlan.status -eq 'current' -and ((@($manualCellPlan.destinations|ForEach-Object{[string]$_.text})-join '|') -eq 'MANUAL-FIRST-|MANUAL-SECOND') -and (($autoCellPlan.destinations|ConvertTo-Json -Depth 20 -Compress) -cne ($manualCellPlan.destinations|ConvertTo-Json -Depth 20 -Compress))) 'cell fixture has a non-auto human-confirmed two-cell placement boundary'
    $null=Commit-YakuNewCatProject -Project $cell;$cell=Get-YakuCatProject -Id ([string]$cell.Id);$cellId=[string]$cell.Id
    $cellSplit=Invoke-T9190Structure -Project $cell -Operation split -Index 0;$cell=$cellSplit.Project;Remove-YakuCatProject -Id $cellId;$cell=Restore-YakuCatProject -Id $cellId
    $tamperedPlacement=Copy-YakuCatProjectForMutation -Project $cell;$tamperedPlacement.PendingStructuralUndo.before_placement_plans[0].placement_kind='tampered';$tamperedPlacementRejected=$false;try{Undo-YakuCatStructuralEdit -Project $tamperedPlacement|Out-Null}catch{$tamperedPlacementRejected=$_.Exception.Message -match '^CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID'}
    Assert-T9190 $tamperedPlacementRejected 'tampered human-confirmed placement snapshot fails closed before restoration'
    $cellUndo=Invoke-T9190Undo -Project $cell;$cell=$cellUndo.Project
    $restoredCellPlan=@($cell.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$cell.Segments[0].SegmentId})[0];$restoredUnrelatedPlan=@($cell.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$cell.Segments[1].SegmentId})[0]
    Assert-T9190 (($restoredCellPlan|ConvertTo-Json -Depth 30 -Compress) -ceq $cellPlanJson -and [string]$restoredCellPlan.placement_kind -eq 'human_confirmed' -and [string]$restoredCellPlan.status -eq 'current' -and ((@($restoredCellPlan.destinations|ForEach-Object{[string]$_.text})-join '|') -eq 'MANUAL-FIRST-|MANUAL-SECOND') -and [string]$cell.PlacementSetHash -ceq $cellSetHash) 'restart plus split undo restores exact human-confirmed placement JSON, destination text, kind, status, and set hash'
    Assert-T9190 (($restoredUnrelatedPlan|ConvertTo-Json -Depth 30 -Compress) -ceq $unrelatedCellPlanJson) 'structural placement undo preserves an unrelated plan exactly'

    $many=New-T9190Project -Count 600;$null=Commit-YakuNewCatProject -Project $many;$many=Get-YakuCatProject -Id ([string]$many.Id);$manyBefore=Get-YakuCatStructuralUndoSegmentsHash -Segments @($many.Segments)
    $manyChange=Invoke-T9190Structure -Project $many -Operation merge -Index 512;$many=$manyChange.Project;$manyUndo=Invoke-T9190Undo -Project $many;$many=$manyUndo.Project
    Assert-T9190 ((Get-YakuCatStructuralUndoSegmentsHash -Segments @($many.Segments)) -eq $manyBefore) 'a 600-row project can structure-edit and undo without copying the whole document'

    $over=New-T9190Project -Count 2;$over.Segments[0].Text=('x'*1100000);$over.Segments[0].SourceIntegrityHash=Get-YakuCatSourceIntegrityHash -Text ([string]$over.Segments[0].Text);$script:YakuCatProjects[[string]$over.Id]=$over;$overRevision=[int]$over.Revision;$overHash=Get-YakuCatStructuralUndoSegmentsHash -Segments @($over.Segments);$overEvents=@($over.ReviewEvents).Count;$overRejected=$false;try{Invoke-T9190Structure -Project $over -Operation merge -Index 0|Out-Null}catch{$overRejected=$_.Exception.Message -match '^CAT_STRUCTURAL_UNDO_SNAPSHOT_TOO_LARGE'}
    Assert-T9190 ($overRejected -and [int]$over.Revision -eq $overRevision -and (Get-YakuCatStructuralUndoSegmentsHash -Segments @($over.Segments)) -eq $overHash -and @($over.ReviewEvents).Count -eq $overEvents -and $null -eq $over.PendingStructuralUndo) 'over-1MiB structural snapshot fails before revision, segment, audit, or ticket mutation'

    $interaction=New-T9190Project;$null=Commit-YakuNewCatProject -Project $interaction;$interaction=Get-YakuCatProject -Id ([string]$interaction.Id)
    $bulk={param($candidate)Invoke-YakuCatSearchReplace -Project $candidate -Indexes @(0) -Find 'target' -Replace 'changed'}
    $bulkCommit=Invoke-YakuCatProjectMutation -ProjectId ([string]$interaction.Id) -ExpectedRevision ([int]$interaction.Revision) -Mutation $bulk -Action replace;$interaction=$bulkCommit.Project
    $struct=Invoke-T9190Structure -Project $interaction -Operation merge -Index 0;$interaction=$struct.Project
    Assert-T9190 ($null -eq $interaction.PendingBulkReplaceUndo -and $null -ne $interaction.PendingStructuralUndo) 'structural success invalidates a pending bulk-replace ticket'
    $newBulk=Invoke-YakuCatProjectMutation -ProjectId ([string]$interaction.Id) -ExpectedRevision ([int]$interaction.Revision) -Mutation {param($candidate)$candidate.Segments[0].Translation='changed';Invoke-YakuCatSearchReplace -Project $candidate -Indexes @(0) -Find 'changed' -Replace 'again'} -Action replace;$interaction=$newBulk.Project
    Assert-T9190 ($null -eq $interaction.PendingStructuralUndo -and $null -ne $interaction.PendingBulkReplaceUndo) 'bulk replace success invalidates a pending structural ticket'
    $preserved=$interaction.PendingBulkReplaceUndo|ConvertTo-Json -Depth 40 -Compress;$failed=$false;try{Invoke-T9190Structure -Project $interaction -Operation split-at -Index 0 -Position 0|Out-Null}catch{$failed=$true}
    Assert-T9190 ($failed -and (($interaction.PendingBulkReplaceUndo|ConvertTo-Json -Depth 40 -Compress) -eq $preserved)) 'failed structural edit preserves committed tickets'
    $stale=$false;try{Invoke-YakuCatProjectMutation -ProjectId ([string]$interaction.Id) -ExpectedRevision ([int]$interaction.Revision-1) -Mutation {param($candidate)Undo-YakuCatStructuralEdit -Project $candidate} -Action structure-undo|Out-Null}catch{$stale=$_.Exception.Message -match '^CAT_PROJECT_REVISION_CONFLICT'}
    Assert-T9190 $stale 'stale CAS fails closed before structural undo mutation'

    $corruptProject=New-T9190Project;$null=Commit-YakuNewCatProject -Project $corruptProject;$corruptProject=Get-YakuCatProject -Id ([string]$corruptProject.Id);$corruptChange=Invoke-T9190Structure -Project $corruptProject -Operation merge -Index 0;$corruptProject=$corruptChange.Project;$corruptId=[string]$corruptProject.Id
    $manifest=Get-Content -LiteralPath (Join-Path (Join-Path $script:YakuT9190Store $corruptId) 'project.json') -Raw -Encoding UTF8|ConvertFrom-Json;$artifact=Join-Path (Join-Path (Join-Path (Join-Path $script:YakuT9190Store $corruptId) 'generations') ([string]$manifest.generation_id)) 'structural-undo.json';$originalArtifact=[IO.File]::ReadAllText($artifact)
    [IO.File]::WriteAllText($artifact,'{}',(New-Object Text.UTF8Encoding($false)));Remove-YakuCatProject -Id $corruptId;$corrupt=$false;try{Restore-YakuCatProject -Id $corruptId|Out-Null}catch{$corrupt=$_.Exception.Message -match '^CAT_PROJECT_SNAPSHOT_INCOMPLETE'}
    Assert-T9190 $corrupt 'corrupt structural undo artifact fails closed through the generation manifest'
    [IO.File]::WriteAllText($artifact,$originalArtifact,(New-Object Text.UTF8Encoding($false)));Remove-Item -LiteralPath $artifact -Force;$missing=$false;try{Restore-YakuCatProject -Id $corruptId|Out-Null}catch{$missing=$_.Exception.Message -match '^CAT_PROJECT_SNAPSHOT_INCOMPLETE'}
    Assert-T9190 $missing 'missing structural undo artifact fails closed through the generation manifest'

    $legacy=New-T9190Project;$null=Commit-YakuNewCatProject -Project $legacy;$legacyId=[string]$legacy.Id;$legacyManifestPath=Join-Path (Join-Path $script:YakuT9190Store $legacyId) 'project.json';$legacyManifest=Get-Content -LiteralPath $legacyManifestPath -Raw -Encoding UTF8|ConvertFrom-Json;$legacyManifest.PSObject.Properties.Remove('structural_undo_sha256');$legacyManifest.PSObject.Properties.Remove('structural_undo_count');$legacyGeneration=Join-Path (Join-Path (Join-Path $script:YakuT9190Store $legacyId) 'generations') ([string]$legacyManifest.generation_id);Remove-Item -LiteralPath (Join-Path $legacyGeneration 'structural-undo.json') -Force;[IO.File]::WriteAllText($legacyManifestPath,($legacyManifest|ConvertTo-Json -Depth 30 -Compress),(New-Object Text.UTF8Encoding($false)));Remove-YakuCatProject -Id $legacyId;$legacyRestored=Restore-YakuCatProject -Id $legacyId
    Assert-T9190 ($null -ne $legacyRestored -and $null -eq $legacyRestored.PendingStructuralUndo) 'schema v8 generation without the optional structural ticket remains readable'

    # 実際の cat.html/cat.js を Chromium で開き、結合・分割・途中分割の各ボタンを
    # 画面から押す。検索と置換の詳細（Ctrl+H）を閉じたままでも、構造編集の
    # 直前1回だけを戻す入口が見えること、復元時に古い行本文をクライアントが
    # 送らないことを、同じ JSON 契約を返す HTTP stub で測る。
    $YakuT9190Unmeasured = 3
    $YakuT9190Node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $YakuT9190Node) { Write-Host 'UNMEASURED: node is unavailable for Chromium CAT screen.'; exit $YakuT9190Unmeasured }
    $YakuT9190NodeExe = [string]$YakuT9190Node.Source
    $YakuT9190ProbeDir = (Join-Path $YakuT9190Root 'tools\cat-screen').Replace('\','/')
    $null = & $YakuT9190NodeExe -e ("try{require.resolve('playwright',{paths:['"+$YakuT9190ProbeDir+"']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host 'UNMEASURED: Playwright is unavailable for Chromium CAT screen.'; exit $YakuT9190Unmeasured }
    $YakuT9190ChromiumPath = & $YakuT9190NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['"+$YakuT9190ProbeDir+"']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
    $YakuT9190ChromiumExit = $LASTEXITCODE
    if ($YakuT9190ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$YakuT9190ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$YakuT9190ChromiumPath) -PathType Leaf)) { Write-Host 'UNMEASURED: Playwright Chromium is unavailable.'; exit $YakuT9190Unmeasured }

    function New-T9190BrowserSegment {
        param([int]$Index,[string]$Id,[string]$Source,[string]$Translation,[bool]$CanMerge=$false,[bool]$CanSplit=$false,[bool]$CanSplitAt=$false)
        return [ordered]@{
            index=$Index;segment_id=$Id;source=$Source;translation=$Translation;origin='manual';state='human_edited';qc_status='not_run';confirmed=$false;kind='text';location='本文';qc_findings=@();qc_preview=@();can_merge=$CanMerge;can_split=$CanSplit;can_split_at=$CanSplitAt
        }
    }
    $browserSegments = @(
        (New-T9190BrowserSegment 0 'screen-base-a' 'Alpha source Beta source' 'alpha beta target' $true $true $true),
        (New-T9190BrowserSegment 1 'screen-base-b' 'Gamma source' 'gamma target' $false $false $false),
        (New-T9190BrowserSegment 2 'screen-base-c' 'Delta source' 'delta target' $false $false $false)
    )
    function New-T9190BrowserProject {
        param([int]$Revision,[object[]]$Segments,[object]$StructuralUndo)
        $rows=@($Segments)
        return [ordered]@{
            id='structural-screen-9190';revision=$Revision;source='text';lifecycle='saved';file_name='structural.txt';document_format='text';direction='to_en';total=$rows.Count;translated=$rows.Count;remaining=0;joined=0;confirmed=0;unconfirmed=$rows.Count;source_chars=100;remaining_chars=0;untranslated=0;draft=$rows.Count;export_blocked=$false;translation_list_eligibility=$true;excel_draft_eligibility=$false;word_draft_eligibility=$false;tm_pending=0
            bulk_replace_undo=[ordered]@{available=$false;affected_count=0};structural_undo=$StructuralUndo;segments=$rows
        }
    }
    $browserInitial = New-T9190BrowserProject 40 $browserSegments ([ordered]@{available=$false;operation='';affected_count=0})
    $browserMergeRows = @(
        (New-T9190BrowserSegment 0 'screen-merge-a' 'Alpha source Beta source' '' $false $false $false),
        (New-T9190BrowserSegment 1 'screen-merge-c' 'Delta source' 'delta target' $false $false $false)
    )
    $browserMerge = New-T9190BrowserProject 41 $browserMergeRows ([ordered]@{available=$true;operation='merge';affected_count=2})
    $browserSplitRows = @(
        (New-T9190BrowserSegment 0 'screen-split-a' 'Alpha source' '' $false $false $false),
        (New-T9190BrowserSegment 1 'screen-split-b' 'Beta source' '' $false $false $false),
        (New-T9190BrowserSegment 2 'screen-split-b0' 'Gamma source' 'gamma target' $false $false $false),
        (New-T9190BrowserSegment 3 'screen-split-c' 'Delta source' 'delta target' $false $false $false)
    )
    $browserSplit = New-T9190BrowserProject 43 $browserSplitRows ([ordered]@{available=$true;operation='split';affected_count=1})
    $browserSplitAtRows = @(
        (New-T9190BrowserSegment 0 'screen-split-at-a' 'Alpha source' '' $false $false $false),
        (New-T9190BrowserSegment 1 'screen-split-at-b' 'Beta source' '' $false $false $false),
        (New-T9190BrowserSegment 2 'screen-split-at-b0' 'Gamma source' 'gamma target' $false $false $false),
        (New-T9190BrowserSegment 3 'screen-split-at-c' 'Delta source' 'delta target' $false $false $false)
    )
    $browserSplitAt = New-T9190BrowserProject 45 $browserSplitAtRows ([ordered]@{available=$true;operation='split-at';affected_count=1})
    $browserRestored42 = New-T9190BrowserProject 42 $browserSegments ([ordered]@{available=$false;operation='';affected_count=0})
    $browserRestored44 = New-T9190BrowserProject 44 $browserSegments ([ordered]@{available=$false;operation='';affected_count=0})
    $browserRestored46 = New-T9190BrowserProject 46 $browserSegments ([ordered]@{available=$false;operation='';affected_count=0})
    $browserBeforePath=Join-Path $YakuT9190Temp 'structural-before.json';$browserMergePath=Join-Path $YakuT9190Temp 'structural-merge.json';$browserRestored42Path=Join-Path $YakuT9190Temp 'structural-restored-42.json';$browserSplitPath=Join-Path $YakuT9190Temp 'structural-split.json';$browserRestored44Path=Join-Path $YakuT9190Temp 'structural-restored-44.json';$browserSplitAtPath=Join-Path $YakuT9190Temp 'structural-split-at.json';$browserRestored46Path=Join-Path $YakuT9190Temp 'structural-restored-46.json';$browserDriverPath=Join-Path $YakuT9190Temp 'structural-screen.js';$browserResultPath=Join-Path $YakuT9190Temp 'structural-screen-result.json'
    [IO.File]::WriteAllText($browserBeforePath,($browserInitial|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserMergePath,($browserMerge|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserRestored42Path,($browserRestored42|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserSplitPath,($browserSplit|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserRestored44Path,($browserRestored44|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserSplitAtPath,($browserSplitAt|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserRestored46Path,($browserRestored46|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)))
    $browserDriver = @'
'use strict';
const fs=require('fs'),http=require('http'),path=require('path');
const {chromium}=require(require.resolve('playwright',{paths:[process.cwd()]}));
const www=process.argv[2],before=JSON.parse(fs.readFileSync(process.argv[3],'utf8')),merge=JSON.parse(fs.readFileSync(process.argv[4],'utf8')),restored42=JSON.parse(fs.readFileSync(process.argv[5],'utf8')),split=JSON.parse(fs.readFileSync(process.argv[6],'utf8')),restored44=JSON.parse(fs.readFileSync(process.argv[7],'utf8')),splitAt=JSON.parse(fs.readFileSync(process.argv[8],'utf8')),restored46=JSON.parse(fs.readFileSync(process.argv[9],'utf8')),outPath=process.argv[10];
const result={errors:[],console:[],requests:[],dialogs:[],operationDialogs:[],operationViews:[],undoViews:[]};
let phase='initial';
let page;
const types={'.js':'application/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.html':'text/html; charset=utf-8'};
function readBody(req,done){let raw='';req.on('data',c=>raw+=c);req.on('end',()=>{let body={};try{body=JSON.parse(raw||'{}')}catch(_){}done(body);});}
const server=http.createServer((req,res)=>{const url=new URL(req.url,'http://127.0.0.1');
  if(url.pathname==='/'||url.pathname==='/cat'){let html=fs.readFileSync(path.join(www,'cat.html'),'utf8');html=html.replace(/__YAKU_SESSION_TOKEN__/g,'structural-test-token').replace(/__YAKU_MAX_UPLOAD_BYTES__/g,'52428800').replace(/__YAKU_MAX_BATCH_CHARS__/g,'4000').replace(/__YAKU_AMOUNT_NOTATION__/g,'oku').replace(/__YAKU_OUTPUT_FONT__/g,'Arial').replace(/__YAKU_OUTPUT_FONT_JP__/g,'MS P\u30b4\u30b7\u30c3\u30af').replace(/__YAKU_TOUR__/g,'0').replace(/__YAKU_IMPORT__/g,'0').replace(/__YAKU_VIEW__/g,'');res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(html);return;}
  if(url.pathname.startsWith('/assets/')){const f=path.join(www,url.pathname.replace(/^\//,''));if(fs.existsSync(f)){res.writeHead(200,{'Content-Type':types[path.extname(f)]||'application/octet-stream'});res.end(fs.readFileSync(f));return;}res.writeHead(404);res.end();return;}
  readBody(req,body=>{let response={};const action=url.pathname.indexOf('/api/cat/')===0?url.pathname.slice('/api/cat/'.length):'';
    if(action==='resume')response=before;
    else if(action==='merge'){result.requests.push({action,body});phase='merge';response=merge;}
    else if(action==='split'){result.requests.push({action,body});phase='split';response=split;}
    else if(action==='split-at'){result.requests.push({action,body});phase='split-at';response=splitAt;}
    else if(action==='structure-undo'){result.requests.push({action,body});if(phase==='merge')response=restored42;else if(phase==='split')response=restored44;else if(phase==='split-at')response=restored46;else response=restored46;phase='initial';}
    else if(action==='project-presence')response={ok:true};
    else if(action==='candidates')response={items:[]};
    else if(action==='recent')response={projects:[]};
    else if(url.pathname==='/api/ready-state')response={canTranslate:true,label:'ready',class:'ok'};
    res.writeHead(200,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(response));
  });
});
async function pageState(){return {rows:await page.locator('#cat-grid-body tr').count(),sources:await page.locator('.cat-source-text').evaluateAll(nodes=>nodes.map(n=>n.textContent)),translations:await page.locator('textarea[data-cat-input]').evaluateAll(nodes=>nodes.map(n=>n.value)),undoVisible:await page.locator('#cat-structure-undo').count()>0,undoText:await page.locator('#cat-structure-undo').count()?await page.locator('#cat-structure-undo').textContent():'',outside:await page.evaluate(()=>{const b=document.querySelector('#cat-structure-undo'),m=document.querySelector('#cat-search-menu');return !!b&&!!m&&!m.contains(b)&&!m.open;})};}
async function waitUndo(text){await page.waitForFunction(expected=>{const b=document.getElementById('cat-structure-undo');return !!b&&b.textContent===expected;},text,{timeout:20000});return pageState();}
async function clickOperation(operation,selector,label){const row=page.locator('[data-cat-row="0"]');await row.locator('details.cat-more-row summary').first().click();const start=result.dialogs.length;await row.locator(selector).click();await page.waitForFunction(expected=>{const b=document.getElementById('cat-structure-undo');return !!b&&b.textContent===expected;},label,{timeout:20000});result.operationDialogs.push({operation,message:result.dialogs[start]||''});result.operationViews.push(Object.assign({operation},await pageState()));}
async function clickUndo(operation){await page.locator('#cat-structure-undo').click();await page.waitForFunction(()=>!document.getElementById('cat-structure-undo'),null,{timeout:20000});result.undoViews.push(Object.assign({operation},await pageState()));}
let browser;
(async()=>{try{await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch();page=await browser.newPage({viewport:{width:1912,height:987}});page.on('pageerror',e=>result.errors.push(String(e.message||e)));page.on('console',m=>{if(m.type()==='error')result.console.push(m.text());});page.on('dialog',d=>{result.dialogs.push(d.message());d.accept();});await page.goto('http://127.0.0.1:'+server.address().port+'/cat?project=structural-screen-9190',{waitUntil:'domcontentloaded'});await page.waitForSelector('[data-cat-merge="0"]',{state:'attached',timeout:20000});
  await clickOperation('merge','[data-cat-merge="0"]','直前の行の結合を元に戻す（2行）');await clickUndo('merge');
  await clickOperation('split','[data-cat-split="0"]','直前の行の分割解除を元に戻す（1行）');await clickUndo('split');
  await page.evaluate(()=>{const span=document.querySelector('[data-cat-row="0"] .cat-source-text');const text=span&&span.firstChild;if(!text)throw new Error('source text node missing');const range=document.createRange();range.setStart(text,6);range.collapse(true);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);span.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));});
  await clickOperation('split-at','[data-cat-split-at="0"]','直前の原文の途中での分割を元に戻す（1行）');await clickUndo('split-at');
}catch(e){result.errors.push(String(e&&e.stack||e));process.exitCode=1;}finally{try{if(browser)await browser.close();}catch(_){}await new Promise(r=>server.close(r));fs.writeFileSync(outPath,JSON.stringify(result));}})();
'@
    [IO.File]::WriteAllText($browserDriverPath,$browserDriver,(New-Object Text.UTF8Encoding($false)))
    & $YakuT9190NodeExe $browserDriverPath (Join-Path $YakuT9190Root 'www') $browserBeforePath $browserMergePath $browserRestored42Path $browserSplitPath $browserRestored44Path $browserSplitAtPath $browserRestored46Path $browserResultPath
    $browserExit=$LASTEXITCODE;$browserResult=$null;if(Test-Path -LiteralPath $browserResultPath){$browserResult=[IO.File]::ReadAllText($browserResultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json}
    if($null -ne $browserResult){foreach($browserError in @($browserResult.errors)){Write-Host ('  Chromium error: '+[string]$browserError)};foreach($browserConsole in @($browserResult.console)){Write-Host ('  Chromium console: '+[string]$browserConsole)}}
    Assert-T9190 ($browserExit -eq 0 -and $null -ne $browserResult -and @($browserResult.errors).Count -eq 0 -and @($browserResult.console).Count -eq 0) 'Chromium CAT screen completes without page or console errors'
    $expectedDialogRules=@(
        [pscustomobject]@{operation='merge';phrase='完了後、直前のこの結合だけを元に戻せます'},
        [pscustomobject]@{operation='split';phrase='完了後、直前のこの分割解除だけを元に戻せます'},
        [pscustomobject]@{operation='split-at';phrase='完了後、直前のこの分割だけを元に戻せます'}
    )
    foreach($rule in $expectedDialogRules){$dialogView=@($browserResult.operationDialogs|Where-Object{$_.operation -eq $rule.operation})[0];Assert-T9190 ($null -ne $dialogView -and [string]$dialogView.message -like ('*'+$rule.phrase+'*') -and [string]$dialogView.message -notlike '*元に戻せません*') ('Chromium '+$rule.operation+' confirmation explains the immediate edit can be restored')}
    $expectedViews=@(
        [pscustomobject]@{operation='merge';label='直前の行の結合を元に戻す（2行）';requestAction='merge';index=0;position=$null;revision=40;rows=2},
        [pscustomobject]@{operation='split';label='直前の行の分割解除を元に戻す（1行）';requestAction='split';index=0;position=$null;revision=42;rows=4},
        [pscustomobject]@{operation='split-at';label='直前の原文の途中での分割を元に戻す（1行）';requestAction='split-at';index=0;position=6;revision=44;rows=4}
    )
    foreach($view in $expectedViews){$operationView=@($browserResult.operationViews|Where-Object{$_.operation -eq $view.operation})[0];$request=@($browserResult.requests|Where-Object{$_.action -eq $view.requestAction})[0];$body=$request.body;Assert-T9190 ($null -ne $operationView -and [bool]$operationView.undoVisible -and [string]$operationView.undoText -eq $view.label -and [bool]$operationView.outside -and [int]$operationView.rows -eq [int]$view.rows) ('Chromium '+$view.operation+' exposes the exact Japanese undo label/count outside collapsed Ctrl+H');Assert-T9190 ($null -ne $request -and [int]$body.expected_revision -eq $view.revision -and [int]$body.index -eq $view.index -and (($null -eq $view.position) -or [int]$body.position -eq [int]$view.position)) ('Chromium '+$view.operation+' sends action, index, expected_revision, and split position contract')}
    $undoRequests=@($browserResult.requests|Where-Object{$_.action -eq 'structure-undo'});Assert-T9190 ($undoRequests.Count -eq 3 -and (@($undoRequests|ForEach-Object{[int]$_.body.expected_revision}) -join '|') -eq '41|43|45' -and (@($undoRequests|ForEach-Object{[string]$_.body.id}) -join '|') -eq 'structural-screen-9190|structural-screen-9190|structural-screen-9190') 'Chromium structural undo sends CAS/revision for every immediate restore'
    $oldContentKeys=@('segments','rows','source','translation','text','segment_id','old_segments','before_segments');$undoBodiesClean=$true;foreach($request in $undoRequests){foreach($key in $oldContentKeys){if($request.body.PSObject.Properties.Name -contains $key){$undoBodiesClean=$false}}};Assert-T9190 ($undoBodiesClean) 'Chromium structural undo never sends old segment content or IDs from the client'
    $expectedRestores=@('merge','split','split-at');foreach($operation in $expectedRestores){$restore=@($browserResult.undoViews|Where-Object{$_.operation -eq $operation})[0];Assert-T9190 ($null -ne $restore -and -not [bool]$restore.undoVisible -and [int]$restore.rows -eq 3 -and (@($restore.sources)-join '|') -eq 'Alpha source Beta source|Gamma source|Delta source' -and (@($restore.translations)-join '|') -eq 'alpha beta target|gamma target|delta target') ('Chromium '+$operation+' undo renders the exact restored source, translation, row count, and no undo button')}
} finally {if(Test-Path -LiteralPath $YakuT9190Temp){Remove-Item -LiteralPath $YakuT9190Temp -Recurse -Force}}
Write-Host ''
if($script:YakuT9190Failures.Count -eq 0){Write-Host 'PASS Test-YakuV9190StructuralUndo';exit 0}
Write-Host ('FAIL '+$script:YakuT9190Failures.Count+' assertion(s)');foreach($f in $script:YakuT9190Failures){Write-Host ('  - '+$f)};exit 1
