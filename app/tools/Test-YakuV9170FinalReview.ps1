<# V91.70: 最終確認判断を成果物・coverage・finding・generationへ束縛する回帰テスト。 #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$script:fail=0
foreach($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1','Render.ps1','VersionUpdate.ps1','SourceRebase.ps1','Review.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
function Chk{param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++}}
function Add-CompleteCopilotProfileRun{param($Project)
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project;$ids=@($Project.Segments|ForEach-Object{[string]$_.SegmentId}|Sort-Object);$items=New-Object Collections.Generic.List[object]
    if($null -eq $Project.DocumentIndexSnapshot){$Project.DocumentIndexSnapshot=New-YakuCatDocumentIndexSnapshot -Project $Project}
    foreach($lens in @('bilingual_block','names_terms_abbreviations','structure_notes','gap')){foreach($id in $ids){$items.Add([pscustomobject]@{coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('test|'+$lens+'|'+$id));scope='local';lens=$lens;target_kind='semantic_segment';target_ids=@($id);state='checked';finding_ids=@();reason='';dependency_fingerprint=$dependency;human_decision_current=$false})|Out-Null}}
    foreach($group in @($Project.DocumentIndexSnapshot.groups)){if([string]$group.lens -notin @('translation_consistency','target_document_consistency')){continue};$items.Add([pscustomobject]@{coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('test|'+[string]$group.group_id));scope='document';lens=[string]$group.lens;target_kind='document_index_group';target_ids=@($group.segment_ids);index_group_id=[string]$group.group_id;state='checked';finding_ids=@();reason='';dependency_fingerprint=$dependency;human_decision_current=$false})|Out-Null}
    $rows=@($items.ToArray());$universe=Get-YakuCatSourceIntegrityHash -Text (@($rows|ForEach-Object{[string]$_.coverage_item_id}|Sort-Object)-join '|');foreach($item in $rows){$item|Add-Member -NotePropertyName target_universe_hash -NotePropertyValue $universe -Force}
    $run=[pscustomobject]@{review_run_id=[guid]::NewGuid().ToString('N');contract_version='document-review-copilot-v2';detector='copilot';dependency_fingerprint=$dependency;status='completed';target_universe_hash=$universe;coverage_items=$rows;coverage_summary=(Get-YakuCatReviewCoverageSummary -Items $rows);finding_ids=@();started_at=(Get-Date).ToString('o');completed_at=(Get-Date).ToString('o')}
    $Project.ReviewRuns=@($Project.ReviewRuns)+@($run);return $run
}

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('yaku-final-review-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-Item -ItemType Directory -Path $tempRoot -Force
$previousDataDir=$env:YAKULINGO_DATA_DIR;$env:YAKULINGO_DATA_DIR=Join-Path $tempRoot 'data'
$script:YakuFinalReviewStore=Join-Path $tempRoot 'cat-store'
function Get-YakuCatProjectStoreDir{return $script:YakuFinalReviewStore}
try{
    $settings=Read-YakuSettings -Root $root
    $noRun=New-YakuCatTextProject -Root $root -Text '単独行' -Settings $settings -Direction to_en -Register:$false
    $noRun.Segments[0].Translation='One line.'
    $runRequired=$false;try{$null=New-YakuCatFinalReviewDecision -Project $noRun -ArtifactKind copied_text -Reason '確認した'}catch{$runRequired=$_.Exception.Message -eq 'CAT_FINAL_REVIEW_RUN_REQUIRED'}
    Chk $runRequired '文書確認runなしで最終確認済みにしない'

    $project=New-YakuCatTextProject -Root $root -Text "売上高`n売上高" -Settings $settings -Direction to_en -Register:$false
    $project.Segments[0].Translation='Net sales';$project.Segments[1].Translation='Revenue'
    $null=Invoke-YakuCatDeterministicDocumentReview -Project $project
    $profileRequired=$false;try{$null=New-YakuCatFinalReviewDecision -Project $project -ArtifactKind copied_text -Reason '出力内容を確認した' -AcknowledgeUnresolved}catch{$profileRequired=$_.Exception.Message -match 'CAT_FINAL_REVIEW_PROFILE_INCOMPLETE'}
    Chk $profileRequired '一部の観点だけのrunで文書全体を確認済みにしない'
    $null=Add-CompleteCopilotProfileRun -Project $project
    $ackRequired=$false;try{$null=New-YakuCatFinalReviewDecision -Project $project -ArtifactKind copied_text -Reason '出力内容を確認した'}catch{$ackRequired=$_.Exception.Message -eq 'CAT_FINAL_REVIEW_UNRESOLVED_ACK_REQUIRED'}
    Chk $ackRequired '未処理findingがある場合は明示確認なしで最終判断を作らない'
    $output=Get-YakuCatTextOutput -Project $project
    $decision=New-YakuCatFinalReviewDecision -Project $project -ArtifactKind copied_text -ArtifactText $output -Reason '残っている訳語差も確認し、この内容を使用する' -AcknowledgeUnresolved
    Chk ([string]$decision.artifact_kind -eq 'copied_text' -and @($decision.final_artifacts).Count -eq 1 -and @($decision.unresolved_finding_ids).Count -eq 1) '成果物hashと未解決findingを同じ最終確認判断へ束縛する'
    Chk ([bool]$decision.coverage_enumeration_complete -and [bool]$decision.coverage_evidence_complete -and [bool]$decision.coverage_decision_complete) 'coverageの列挙・証拠・人判断を別々に記録する'
    Chk ([string](Get-YakuCatFinalReviewDecisionStatus -Project $project -Decision $decision).status -eq 'current') '内容が同じ間だけ最終確認判断をcurrentとする'
    $profileChangedDecision=$decision.PSObject.Copy();$profileChangedDecision.required_review_profile_hash='old-required-profile'
    $profileChangedStatus=Get-YakuCatFinalReviewDecisionStatus -Project $project -Decision $profileChangedDecision
    Chk ([string]$profileChangedStatus.status -eq 'stale' -and @($profileChangedStatus.reasons) -contains 'required_review_profile_changed') '必須review profile契約が変わった最終確認判断を失効する'
    $project=Commit-YakuNewCatProject -Project $project;$decision=$project.FinalReviewDecisions[0]
    $manifest=Get-Content -LiteralPath (Join-Path (Join-Path $script:YakuFinalReviewStore ([string]$project.Id)) 'project.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $generation=Join-Path (Join-Path (Join-Path $script:YakuFinalReviewStore ([string]$project.Id)) 'generations') ([string]$manifest.generation_id)
    Chk ([int]$manifest.schema_version -eq 8 -and (Test-Path -LiteralPath (Join-Path $generation 'final-review-decisions.jsonl')) -and (Test-Path -LiteralPath (Join-Path $generation 'mutation-receipts.jsonl'))) '最終確認判断と更新receiptをschema 8の同一commit generationへ保存する'
    Chk (-not [string]::IsNullOrWhiteSpace([string]$decision.source_generation_id) -and [string]$decision.source_generation_id -eq [string]$manifest.generation_id) '成果物判断を可視化したproject generationへ束縛する'
    $restored=Restore-YakuCatProject -Id ([string]$project.Id)
    $restoredDecisionStatus=Get-YakuCatFinalReviewDecisionStatus -Project $restored -Decision $restored.FinalReviewDecisions[0]
    if([string]$restoredDecisionStatus.status -ne 'current'){Write-Host ('    reasons: '+(@($restoredDecisionStatus.reasons)-join ',')) -ForegroundColor DarkYellow}
    Chk (@($restored.FinalReviewDecisions).Count -eq 1 -and [string]$restoredDecisionStatus.status -eq 'current') '再起動後も最終確認判断を検証して復元する'
    $restored.Segments[0].Translation='Sales';$stale=Get-YakuCatFinalReviewDecisionStatus -Project $restored -Decision $restored.FinalReviewDecisions[0]
    Chk ([string]$stale.status -eq 'stale' -and @($stale.reasons) -contains 'translation_changed') '訳文編集後は旧最終確認判断を自動失効する'
    $reopenProject=New-YakuCatTextProject -Root $root -Text "利益`n利益" -Settings $settings -Direction to_en -Register:$false;$reopenProject.Segments[0].Translation='Profit';$reopenProject.Segments[1].Translation='Earnings';$null=Invoke-YakuCatDeterministicDocumentReview -Project $reopenProject;$null=Add-CompleteCopilotProfileRun -Project $reopenProject
    $finding=$reopenProject.DocumentFindings[0];$null=Set-YakuCatDocumentFindingDecision -Project $reopenProject -FindingId ([string]$finding.finding_id) -FindingRevision ([int]$finding.finding_revision) -Action accepted_risk -ReasonCode context_specific -Note '文脈上の訳し分けとして確認'
    $reopenDecision=New-YakuCatFinalReviewDecision -Project $reopenProject -ArtifactKind copied_text -Reason '訳し分けを含めて確認した';$null=Set-YakuCatDocumentFindingDecision -Project $reopenProject -FindingId ([string]$finding.finding_id) -FindingRevision ([int]$finding.finding_revision) -Action reopen -ReasonCode needs_recheck -Note '再確認する'
    $reopenStatus=Get-YakuCatFinalReviewDecisionStatus -Project $reopenProject -Decision $reopenDecision
    Chk ([string]$reopenStatus.status -eq 'stale' -and @($reopenStatus.reasons) -contains 'review_decisions_changed') 'findingを再openしたら同じ成果物でも最終確認判断を失効する'

    $artifactProject=New-YakuCatTextProject -Root $root -Text "帳票`n帳票" -Settings $settings -Direction to_en -Register:$false;$artifactProject.Segments[0].Translation='Report';$artifactProject.Segments[1].Translation='Report'
    $null=Invoke-YakuCatDeterministicDocumentReview -Project $artifactProject;$null=Add-CompleteCopilotProfileRun -Project $artifactProject
    $draftPath=Join-Path $tempRoot 'DRAFT_test.xlsx';$pdfPath=Join-Path $tempRoot 'preview.pdf';[IO.File]::WriteAllBytes($draftPath,[byte[]](1,2,3,4));[IO.File]::WriteAllBytes($pdfPath,[byte[]](5,6,7,8))
    $draftHash=(Get-FileHash -LiteralPath $draftPath -Algorithm SHA256).Hash.ToLowerInvariant();$pdfHash=(Get-FileHash -LiteralPath $pdfPath -Algorithm SHA256).Hash.ToLowerInvariant();$renderId='7'*32
    $renderDependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $artifactProject;$coverageId=Get-YakuCatSourceIntegrityHash -Text ('render-test|'+$renderId)
    $renderItem=[pscustomobject]@{coverage_item_id=$coverageId;scope='render';lens='rendered_output_completeness';target_kind='placement_plan';target_ids=@('p1');state='unmapped';finding_ids=@();reason='text_present_but_position_unassociated';dependency_fingerprint=$renderDependency;human_decision_current=$true;human_decision_event_id='visual-event'}
    $artifactProject.ReviewRuns=@($artifactProject.ReviewRuns)+@([pscustomobject]@{review_run_id=[guid]::NewGuid().ToString('N');contract_version='pdf-text-presence-v2';detector='pdfjs-deterministic';dependency_fingerprint=$renderDependency;document_dependency_fingerprint=$renderDependency;render_id=$renderId;status='completed';coverage_items=@($renderItem);coverage_summary=(Get-YakuCatReviewCoverageSummary -Items @($renderItem));finding_ids=@()})
    $null=Sync-YakuCatPlacementPlans -Project $artifactProject
    $script:FinalRenderManifest=[pscustomobject]@{source_snapshot_id=[string]$artifactProject.ActiveSourceId;input_fingerprint=(Get-YakuCatRenderInputFingerprint -Project $artifactProject);canonical_pdf_sha256=$pdfHash;expected_print_fingerprint='print';print_conformance_status='verified';output_xlsx_sha256=('0'*64)}
    function Resolve-YakuCatRenderPdf{param([string]$ProjectId,[string]$RenderId);[pscustomobject]@{Path=$script:FinalRenderPdf;DraftPath=$script:FinalRenderDraft;Manifest=$script:FinalRenderManifest}}
    $script:FinalRenderPdf=$pdfPath;$script:FinalRenderDraft=$draftPath
    $artifactMismatch=$false;try{$null=New-YakuCatFinalReviewDecision -Project $artifactProject -ArtifactKind draft_xlsx -ArtifactPath $draftPath -RenderId $renderId -Reason 'ExcelとPDFを確認'}catch{$artifactMismatch=$_.Exception.Message -eq 'CAT_FINAL_REVIEW_RENDER_ARTIFACT_MISMATCH'}
    Chk $artifactMismatch '確認PDFと異なるExcelを同じ最終確認判断へ組み合わせない'
    $script:FinalRenderManifest.output_xlsx_sha256=$draftHash
    $artifactDecision=New-YakuCatFinalReviewDecision -Project $artifactProject -ArtifactKind draft_xlsx -ArtifactPath $draftPath -RenderId $renderId -Reason '同じExcelから作成したPDFを目視確認'
    Chk ([bool]$artifactDecision.render_reviewed -and @($artifactDecision.final_artifacts|Where-Object{[string]$_.role -eq 'deliverable' -and [string]$_.sha256 -eq $draftHash}).Count -eq 1) '同一render manifestのExcelとPDFに明示目視eventがある場合だけPDF確認済みにする'
    $serverText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
    $clientText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
    $pageText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
    Chk ($serverText -match "'final-review-decision'" -and $serverText -match 'CAT_FINAL_REVIEW_OUTPUT_TOKEN_INVALID' -and $serverText -match 'output_token') '直前にサーバーが生成した成果物tokenとrevisionを最終確認APIで検証する'
    Chk ($serverText -match "'final-review-readiness'" -and $clientText -match "post\('final-review-readiness'" -and $clientText -match '機械比較、2\. Copilot確認') '成果物を作る前に最終確認記録の未完手順を利用者へ案内する'
    Chk ($clientText -match "post\('final-review-decision'" -and $pageText -match '組織上の承認や正式版を意味するものではありません') '任意の理由付き確認として表示し、正式承認と誤表示しない'
}finally{
    $env:YAKULINGO_DATA_DIR=$previousDataDir
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if($script:fail){throw ($script:fail.ToString()+' final review checks failed')}
Write-Host 'Final review checks passed.' -ForegroundColor Green
