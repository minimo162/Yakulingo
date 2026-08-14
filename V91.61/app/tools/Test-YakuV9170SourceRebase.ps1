<# .SYNOPSIS V91.70 source replacement three-way rebase planning contract. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$script:fail=0
foreach($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1','VersionUpdate.ps1','SourceRebase.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
function Chk{param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++}}
function Seg{
    param([string]$Id,[string]$Text,[string]$Translation,[string]$Location,[string]$Sheet='Sheet1',[string]$Structure='structure-a')
    $sourceHash=Get-YakuCatSourceIntegrityHash -Text $Text
    $targetHash=Get-YakuCatSourceIntegrityHash -Text $Translation
    return [pscustomobject]@{
        SegmentId=$Id;Text=$Text;Translation=$Translation;SourceRevision=1;SourceIntegrityHash=$sourceHash
        Origin='manual';State=$(if($Translation){'reviewed'}else{'untranslated'});Confirmed=[bool]$Translation
        QcStatus=$(if($Translation){'passed'}else{'not_run'});QcSourceRevision=$(if($Translation){1}else{0})
        QcSourceHash=$(if($Translation){$sourceHash}else{''});QcTargetHash=$(if($Translation){$targetHash}else{''})
        QcContractVersion=$(if($Translation){Get-YakuCatQcContractVersion}else{''});QcTerminologyHash='';QcFindings=@()
        Kind='cell';Sheet=$Sheet;Location=$Location;BlockIds=@('block-'+$Id);Cells=@([pscustomobject]@{BlockId=('block-'+$Id);Text=$Text;Address=($Location -replace '^.*?,\s*','');StructureFingerprint=$Structure;StructureContract=[pscustomobject]@{merge_kind='none';merge_area='';wrap_text='False';style='Normal';row_height='15';column_width='12';row_hidden='False';column_hidden='False'}})
    }
}
function Project{
    param([object[]]$Segments,[string]$SourceId=('a'*32),[string]$SourceHash=('b'*64))
    $events=@()
    foreach($segment in @($Segments|Where-Object{[bool]$_.Confirmed})){
        $events += [pscustomobject]@{decision_scope='translation';action='reviewed';segment_id=[string]$segment.SegmentId;source_hash=[string]$segment.SourceIntegrityHash;target_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Translation))}
    }
    return [pscustomobject]@{Id=([guid]::NewGuid().ToString('N'));ActiveSourceId=$SourceId;SourceArtifactSha256=$SourceHash;Revision=7;Direction='to_en';Segments=@($Segments);ReviewEvents=@($events);TerminologySnapshotHash='';SourceSnapshots=@();PlacementPlans=@();PlacementSetHash='';RebaseRecords=@()}
}
function PreparePlacements{param($Project)$null=Initialize-YakuCatProjectState -Project $Project;$null=Sync-YakuCatPlacementPlans -Project $Project;foreach($placement in @($Project.PlacementPlans)){$placement.status='current';$placement.placement_kind='human_confirmed';$placement.plan_hash=Get-YakuCatPlacementPlanHash -Plan $placement};$null=Update-YakuCatPlacementSetHash -Project $Project}
function Target{param([object[]]$Segments)$blocks=@($Segments|ForEach-Object{[pscustomobject]@{Id=[string]$_.BlockIds[0];Text=[string]$_.Text;Location=[string]$_.Location;Meta=[pscustomobject]@{Sheet=[string]$_.Sheet}}});return [pscustomobject]@{Segments=@($Segments);Blocks=$blocks;FileName='target.csv'}}

$base=Project -Segments @(
    (Seg 's1' '見出し' 'Heading' 'Sheet1, A1'),
    (Seg 's2' '売上高は100百万円でした。' 'Net sales were 100 million yen.' 'Sheet1, A2'),
    (Seg 's3' '注記' 'Note' 'Sheet1, A3')
)
PreparePlacements $base
$same=Target -Segments @((Seg 't1' '見出し' '' 'Sheet1, A1'),(Seg 't2' '売上高は100百万円でした。' '' 'Sheet1, A2'),(Seg 't3' '注記' '' 'Sheet1, A3'))
$samePlan=New-YakuCatRebasePlan -Project $base -TargetProject $same -TargetSourceId ('c'*32) -TargetSourceHash ('d'*64)
Chk (@($samePlan.segment_mappings|Where-Object{$_.kind -eq 'unchanged'}).Count -eq 3) '完全一致を1対1で対応付ける'
Chk (@($samePlan.segment_mappings|Where-Object{$_.reuse_decision -eq 'reuse_reviewed'}).Count -eq 3) '原文・文脈・有効な確認が一致する訳だけ確認状態を再利用候補にする'
Chk ([string]$samePlan.plan_hash -match '^[a-f0-9]{64}$' -and [string]$samePlan.contract_version -eq 'cat-source-rebase-v1') 'preview計画を不変hashへ束縛する'
Chk (@($samePlan.placement_rebases|Where-Object{$_.decision -eq 'reuse_current' -and $_.remapped_plan.status -eq 'current'}).Count -eq 3) '完全一致かつセル構造一致の配置だけをcurrent候補として再対応する'

$moved=Target -Segments @((Seg 't3' '注記' '' 'Sheet1, A1'),(Seg 't1' '見出し' '' 'Sheet1, A2'),(Seg 't2' '売上高は100百万円でした。' '' 'Sheet1, A3'))
$movedPlan=New-YakuCatRebasePlan -Project $base -TargetProject $moved -TargetSourceId ('e'*32) -TargetSourceHash ('f'*64)
Chk (@($movedPlan.segment_mappings|Where-Object{$_.kind -eq 'moved_unchanged'}).Count -eq 3) '移動した完全一致文を番地一致ではなく本文で追跡する'
Chk (@($movedPlan.segment_mappings|Where-Object{$_.reuse_decision -eq 'reuse_reviewed'}).Count -eq 0) '周辺文脈が変わった同文を確認済みとして自動継承しない'
$movedS1=@($movedPlan.placement_rebases|Where-Object{$_.source_segment_id -eq 's1'})[0]
Chk (@($movedPlan.placement_rebases|Where-Object{$_.decision -eq 'reuse_current'}).Count -eq 3 -and [string]$movedS1.remapped_plan.destinations[0].address -eq 'A2') '一意な移動先へ配置セルidentityを作り直す'

$structureChanged=Target -Segments @((Seg 't1' '見出し' '' 'Sheet1, A1' 'Sheet1' 'structure-b'),(Seg 't2' '売上高は100百万円でした。' '' 'Sheet1, A2'),(Seg 't3' '注記' '' 'Sheet1, A3'))
$structurePlan=New-YakuCatRebasePlan -Project $base -TargetProject $structureChanged -TargetSourceId ('e'*32) -TargetSourceHash ('0'*64)
$structurePlacement=@($structurePlan.placement_rebases|Where-Object{$_.source_segment_id -eq 's1'})[0]
Chk ([string]$structurePlacement.decision -eq 'stale' -and [string]$structurePlacement.remapped_plan.status -eq 'stale' -and @($structurePlacement.reasons|Where-Object{$_ -like 'structure_fingerprint_changed:*'}).Count -eq 1) '列幅等を含むセル構造fingerprintが変わった配置はstaleにする'

$numeric=Target -Segments @((Seg 't1' '見出し' '' 'Sheet1, A1'),(Seg 't2' '売上高は120百万円でした。' '' 'Sheet1, A2'),(Seg 't3' '注記' '' 'Sheet1, A3'))
$numericPlan=New-YakuCatRebasePlan -Project $base -TargetProject $numeric -TargetSourceId ('1'*32) -TargetSourceHash ('2'*64)
$numericMapping=@($numericPlan.segment_mappings|Where-Object{$_.source_segment_ids -contains 's2'})[0]
Chk ([string]$numericMapping.kind -eq 'numeric_changed' -and [string]$numericMapping.numeric_translation_candidate -match '120') '人の現在訳を基に数値だけを安全更新候補にする'

$changed=Target -Segments @((Seg 't1' '見出し' '' 'Sheet1, A1'),(Seg 't2' '売上高は大幅に増加しました。' '' 'Sheet1, A2'),(Seg 't3' '注記' '' 'Sheet1, A3'),(Seg 't4' '新しい注記' '' 'Sheet1, A4'))
$changedPlan=New-YakuCatRebasePlan -Project $base -TargetProject $changed -TargetSourceId ('3'*32) -TargetSourceHash ('4'*64)
Chk (@($changedPlan.segment_mappings|Where-Object{$_.kind -eq 'changed'}).Count -eq 1 -and @($changedPlan.conflicts|Where-Object{$_.kind -eq 'changed' -and $_.blocking}).Count -eq 1) '文言変更は人訳を候補として保護しblocking conflictにする'
Chk (@($changedPlan.segment_mappings|Where-Object{$_.kind -eq 'added'}).Count -eq 1) '新版だけの原文を新規未訳として分類する'
$changedMappingForPlacement=@($changedPlan.segment_mappings|Where-Object{$_.kind -eq 'changed'})[0]
Chk (@($changedPlan.placement_rebases|Where-Object{$_.mapping_id -eq [string]$changedMappingForPlacement.mapping_id}).Count -eq 0) 'changed原文の配置は再利用候補にしない'

$removed=Target -Segments @((Seg 't1' '見出し' '' 'Sheet1, A1'),(Seg 't2' '売上高は100百万円でした。' '' 'Sheet1, A2'))
$removedPlan=New-YakuCatRebasePlan -Project $base -TargetProject $removed -TargetSourceId ('5'*32) -TargetSourceHash ('6'*64)
Chk (@($removedPlan.segment_mappings|Where-Object{$_.kind -eq 'removed'}).Count -eq 1 -and @($removedPlan.conflicts|Where-Object{$_.kind -eq 'removed'}).Count -eq 1) '削除された確認済み人訳を黙って別行へ移さず確認事項にする'
$removedMapping=@($removedPlan.segment_mappings|Where-Object{$_.kind -eq 'removed'})[0]
Chk (@($removedMapping.archived_source_evidence).Count -eq 1 -and [string]$removedMapping.archived_source_evidence[0].translation -eq 'Note') '削除された旧日本語と旧訳を不変plan内の監査証拠として保護する'

$ambBase=Project -Segments @((Seg 'dup' '同じ文' 'Same sentence.' 'Sheet1, A1'))
PreparePlacements $ambBase
$ambTarget=Target -Segments @((Seg 'd1' '同じ文' '' 'Sheet1, A2'),(Seg 'd2' '同じ文' '' 'Sheet1, A3'))
$ambPlan=New-YakuCatRebasePlan -Project $ambBase -TargetProject $ambTarget -TargetSourceId ('7'*32) -TargetSourceHash ('8'*64)
Chk (@($ambPlan.segment_mappings|Where-Object{$_.kind -eq 'ambiguous'}).Count -eq 1) '同文重複で対応を一意に決められない場合は自動継承しない'
Chk (@($ambPlan.placement_rebases).Count -eq 0) 'ambiguous mappingの配置は再利用候補にしない'

$splitBase=Project -Segments @((Seg 'joined' '前半後半' 'First and second.' 'Sheet1, A1'))
PreparePlacements $splitBase
$splitTarget=Target -Segments @((Seg 'p1' '前半' '' 'Sheet1, A1'),(Seg 'p2' '後半' '' 'Sheet1, A2'))
$splitPlan=New-YakuCatRebasePlan -Project $splitBase -TargetProject $splitTarget -TargetSourceId ('9'*32) -TargetSourceHash ('0'*64)
Chk (@($splitPlan.segment_mappings|Where-Object{$_.kind -eq 'split' -and $_.source_segment_ids.Count -eq 1 -and $_.target_block_groups.Count -eq 2}).Count -eq 1) '1対Nの分割を構造競合として表現する'
Chk (@(@($splitPlan.segment_mappings|Where-Object{$_.kind -eq 'split'})[0].archived_source_evidence).Count -eq 1) '分割前の旧訳を構造競合の証拠に残す'
Chk (@($splitPlan.placement_rebases).Count -eq 0) 'split mappingの配置は再利用候補にしない'

$mergeBase=Project -Segments @((Seg 'p1' '前半' 'First.' 'Sheet1, A1'),(Seg 'p2' '後半' 'Second.' 'Sheet1, A2'))
PreparePlacements $mergeBase
$mergeTarget=Target -Segments @((Seg 'joined' '前半後半' '' 'Sheet1, A1'))
$mergePlan=New-YakuCatRebasePlan -Project $mergeBase -TargetProject $mergeTarget -TargetSourceId ('a'*32) -TargetSourceHash ('b'*64)
Chk (@($mergePlan.segment_mappings|Where-Object{$_.kind -eq 'merged' -and $_.source_segment_ids.Count -eq 2 -and $_.target_block_groups.Count -eq 1}).Count -eq 1) 'N対1の結合を構造競合として表現する'
Chk (@(@($mergePlan.segment_mappings|Where-Object{$_.kind -eq 'merged'})[0].archived_source_evidence).Count -eq 2) '結合前の複数の旧訳を構造競合の証拠に残す'
Chk (@($mergePlan.placement_rebases).Count -eq 0) 'merge mappingの配置は再利用候補にしない'

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('yaku-rebase-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-Item -ItemType Directory -Path $tempRoot -Force
$script:YakuRebaseStore=Join-Path $tempRoot 'store'
function Get-YakuCatProjectStoreDir{return $script:YakuRebaseStore}
$basePath=Join-Path $tempRoot 'base.csv';$targetPath=Join-Path $tempRoot 'target.csv'
[IO.File]::WriteAllText($basePath,'base',[Text.Encoding]::UTF8);[IO.File]::WriteAllText($targetPath,'target',[Text.Encoding]::UTF8)
$previewBase=Project -Segments @((Seg 's1' '見出し' 'Heading' 'Sheet1, A1')) -SourceHash ((Get-FileHash $basePath -Algorithm SHA256).Hash.ToLowerInvariant())
$previewBase|Add-Member -NotePropertyName Source -NotePropertyValue 'file';$previewBase|Add-Member -NotePropertyName Path -NotePropertyValue $basePath;$previewBase|Add-Member -NotePropertyName FileName -NotePropertyValue 'base.csv'
$previewBase|Add-Member -NotePropertyName DocumentFormat -NotePropertyValue 'csv';$previewBase|Add-Member -NotePropertyName Blocks -NotePropertyValue @((Target -Segments @($previewBase.Segments)).Blocks)
$previewBase.Revision=0
$null=Initialize-YakuCatProjectState -Project $previewBase;$null=Sync-YakuCatPlacementPlans -Project $previewBase
foreach($placement in @($previewBase.PlacementPlans)){$placement.status='current';$placement.placement_kind='human_confirmed';$placement.plan_hash=Get-YakuCatPlacementPlanHash -Plan $placement};$null=Update-YakuCatPlacementSetHash -Project $previewBase
$null=Save-YakuCatProject -Project $previewBase -ThrowOnError
$previewBase.PlacementPlans=@();$previewBase.PlacementSetHash='';$null=Sync-YakuCatPlacementPlans -Project $previewBase
foreach($placement in @($previewBase.PlacementPlans)){$placement.status='current';$placement.placement_kind='human_confirmed';$placement.plan_hash=Get-YakuCatPlacementPlanHash -Plan $placement};$null=Update-YakuCatPlacementSetHash -Project $previewBase
$null=Save-YakuCatProject -Project $previewBase -ThrowOnError
$checkpointRevision=[int]$previewBase.Revision;$checkpointGeneration=[string]$previewBase.ActiveGenerationId;$checkpointSource=[string]$previewBase.ActiveSourceId
function New-YakuCatProject{return (Target -Segments @((Seg 't1' '見出し' '' 'Sheet1, A1')))}
try{
    $preview=New-YakuCatSourceUpdatePreview -Root $root -Project $previewBase -TargetPath $targetPath -Settings @{}
    $previewBase|Add-Member -NotePropertyName PublicationVariants -NotePropertyValue @([pscustomobject]@{variant_id='variant-before-rebase';segment_id='s1';status='active'}) -Force
    $previewBase|Add-Member -NotePropertyName ActivePublicationVariantBySegment -NotePropertyValue ([pscustomobject]@{s1='variant-before-rebase'}) -Force
    $loaded=Get-YakuCatSourceUpdatePreview -Project $previewBase -RebaseId ([string]$preview.rebase_id)
    Chk ((Test-Path -LiteralPath ([string]$loaded.TargetArtifactPath)) -and [string]$loaded.Plan.plan_hash -eq [string]$preview.plan_hash) 'previewは新版原本を不変snapshotへコピーし計画hashを検証して再読込する'
    $previewBase.Revision++
    $stale=$false;try{$null=Get-YakuCatSourceUpdatePreview -Project $previewBase -RebaseId ([string]$preview.rebase_id)}catch{$stale=[string]$_.Exception.Message -eq 'CAT_REBASE_PLAN_STALE'}
    Chk $stale 'preview後にproject revisionが変わった計画を適用候補として再利用しない'
    $previewBase.Revision--
    $applyResult=Apply-YakuCatSourceUpdatePlan -Project $previewBase -RebaseId ([string]$preview.rebase_id) -PlanHash ([string]$preview.plan_hash)
    Chk ([string]$previewBase.ActiveSourceId -eq [string]$preview.target_source_id -and [string]$previewBase.Segments[0].Translation -eq 'Heading') '競合のない新版は人訳を保護したままactive SourceSnapshotへ積み替える'
    $appliedPlacementBinding=$(if(@($previewBase.PlacementPlans).Count -eq 1){Test-YakuCatPlacementPlanBinding -Project $previewBase -Segment $previewBase.Segments[0] -Plan $previewBase.PlacementPlans[0]}else{[pscustomobject]@{Passed=$false;Reasons=@('placement_count')}})
    if(-not [bool]$appliedPlacementBinding.Passed){Write-Host ('       placement binding: '+(@($appliedPlacementBinding.Reasons)-join ',')) -ForegroundColor DarkGray}
    Chk (@($previewBase.PlacementPlans).Count -eq 1 -and [string]$previewBase.PlacementPlans[0].status -eq 'current' -and [bool]$appliedPlacementBinding.Passed) '安全な配置候補を新版segmentへ適用してbindingを再検証できる'
    Chk ([string]$previewBase.PublicationVariants[0].status -eq 'stale' -and @($previewBase.ActivePublicationVariantBySegment.PSObject.Properties).Count -eq 0) '原本差し替え後は旧原本に束縛された掲載訳をactiveのまま再利用しない'
    Chk ([string]$previewBase.AppliedRebaseId -eq [string]$preview.rebase_id -and @($previewBase.RebaseRecords|Where-Object{$_.status -eq 'applied'}).Count -eq 1) 'rebase適用をsource lineageと監査recordへ残す'
    Chk ([string]$previewBase.RebaseRecords[0].plan_relative_path -eq ('rebases/'+[string]$preview.rebase_id+'/plan.json') -and -not ($previewBase.RebaseRecords[0].PSObject.Properties.Name -contains 'mappings')) 'manifestの監査recordは不変planを参照し、全mappingを重複保存しない'
    $checkpointDir=Join-Path (Join-Path (Join-Path $script:YakuRebaseStore ([string]$previewBase.Id)) 'rebase-checkpoints') ([string]$checkpointRevision)
    Chk ((Test-Path -LiteralPath (Join-Path $checkpointDir 'checkpoint.json')) -and (Test-Path -LiteralPath (Join-Path $checkpointDir 'manifest.json')) -and (Test-Path -LiteralPath (Join-Path (Join-Path $checkpointDir 'generation') 'segments.jsonl'))) '適用前manifestとactive generationをrebase checkpointへ退避する'
    $checkpoint=Get-Content -LiteralPath (Join-Path $checkpointDir 'checkpoint.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Chk ([int]$checkpoint.checkpoint_revision -eq $checkpointRevision -and [string]$checkpoint.active_generation_id -eq $checkpointGeneration -and [string]$checkpoint.active_source_id -eq $checkpointSource) 'checkpointを適用前revision・generation・sourceへ束縛する'
    $null=Save-YakuCatProject -Project $previewBase -ThrowOnError
    $restoredAfterRebase=Restore-YakuCatProject -Id ([string]$previewBase.Id)
    Chk ([string]$restoredAfterRebase.RebaseRecords[0].checkpoint_relative_path -eq ('rebase-checkpoints/'+$checkpointRevision+'/checkpoint.json') -and [string]$restoredAfterRebase.RebaseRecords[0].checkpoint_manifest_sha256 -eq [string]$checkpoint.manifest_sha256) 'checkpoint参照を新generationへ保存し再起動後も復元する'
    Chk (-not(Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:YakuRebaseStore ([string]$previewBase.Id)) 'generations') $checkpointGeneration)) -and (Test-Path -LiteralPath (Join-Path $checkpointDir 'generation'))) '通常の旧generation cleanup後もrebase checkpointを保持する'
    $previewBase2=Project -Segments @((Seg 's1' '見出し' 'Heading' 'Sheet1, A1')) -SourceHash ((Get-FileHash $basePath -Algorithm SHA256).Hash.ToLowerInvariant())
    $previewBase2|Add-Member -NotePropertyName Source -NotePropertyValue 'file';$previewBase2|Add-Member -NotePropertyName Path -NotePropertyValue $basePath;$previewBase2|Add-Member -NotePropertyName FileName -NotePropertyValue 'base.csv'
    function New-YakuCatProject{return (Target -Segments @((Seg 't1' '新しい見出し' '' 'Sheet1, A1')))}
    $changedPreview=New-YakuCatSourceUpdatePreview -Root $root -Project $previewBase2 -TargetPath $targetPath -Settings @{}
    $changedMapping=@($changedPreview.segment_mappings|Where-Object{$_.kind -eq 'changed'})[0]
    $resolution=New-YakuCatRebaseResolution -Project $previewBase2 -RebaseId ([string]$changedPreview.rebase_id) -PlanHash ([string]$changedPreview.plan_hash) -Decisions @([pscustomobject]@{mapping_id=[string]$changedMapping.mapping_id;action='preserve_as_candidate';target_index=-1;reason='現訳を元に修正する'})
    $null=Apply-YakuCatSourceUpdatePlan -Project $previewBase2 -RebaseId ([string]$changedPreview.rebase_id) -PlanHash ([string]$changedPreview.plan_hash) -ResolutionId ([string]$resolution.resolution_id) -ResolutionHash ([string]$resolution.resolution_hash)
    Chk ([string]$previewBase2.Segments[0].Translation -eq 'Heading' -and -not [bool]$previewBase2.Segments[0].Confirmed -and [string]$previewBase2.Segments[0].PriorTranslation -eq 'Heading') '文言変更は人の判断後も現訳を消さず未確認候補として保護する'
    Chk ([string]$previewBase2.RebaseRecords[0].rebase_resolution_hash -eq [string]$resolution.resolution_hash) '競合判断をplanとは別hashで適用recordへ束縛する'
}finally{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
$serverText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
$clientText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
$pageText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
Chk ($serverText -match "mode='rebase_preview'" -and $serverText -match "ResultKind='rebase_preview'" -and $serverText -match "'source-update-decision'" -and $serverText -match "'source-update-apply'") '原本比較をtyped background jobとplan/resolution二重CAS経路で公開する'
Chk ($serverText -match "receiptActions = @\([^\r\n]*'source-update-apply'" -and $serverText -match 'target_source_id' -and $serverText -match 'CAT_REBASE_APPLY_TARGET_MISMATCH') '新版適用をsource lineage、対象hash、永続receiptへ束縛する'
Chk ($pageText -match 'id="cat-source-update-open"' -and $clientText -match "post\('source-update-preview'" -and $clientText -match "post\('source-update-decision'" -and $clientText -match "post\('source-update-apply'") '旧原文・現在訳・新原文を見て人が扱いを決める画面を持つ'

if($script:fail){throw ($script:fail.ToString()+' source rebase checks failed')}
Write-Host 'Source rebase planning tests passed.' -ForegroundColor Green
