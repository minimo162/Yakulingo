<# V91.70: canonical translation and Excel publication variant separation. #>
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path);$script:fail=0
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach($name in $script:YakuSrcModuleFiles){. (Join-Path (Join-Path $root 'src') $name)}
function Chk{param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('yaku-publication-'+[guid]::NewGuid().ToString('N').Substring(0,8));$null=New-Item -ItemType Directory -Path $temp -Force
$oldData=$env:YAKULINGO_DATA_DIR;$env:YAKULINGO_DATA_DIR=Join-Path $temp 'data';$script:YakuPublicationStore=Join-Path $temp 'store'
function Get-YakuCatProjectStoreDir{return $script:YakuPublicationStore}
try{
  $settings=Read-YakuSettings -Root $root
  $project=New-YakuCatTextProject -Root $root -Text '売上高は123百万円でした。' -Settings $settings -Direction to_en -Register:$false
  $segment=$project.Segments[0];$segment.Translation='Net sales were 123 million yen.';$segment.Kind='cell';$segment.Sheet='Sheet1';$segment.BlockIds=@('block-a');$segment.Cells=@([pscustomobject]@{Text=[string]$segment.Text;Address='A1'})
  $project.Blocks=@([pscustomobject]@{Id='block-a';Text=[string]$segment.Text;Location='Sheet1!A1';Meta=$null});$segment.Confirmed=$true;$segment.State='reviewed';$segment.TmRegistered=$true;$segment.TmRegistrationEventId='existing-tm'
  $null=Initialize-YakuCatProjectState -Project $project;$null=Sync-YakuCatPlacementPlans -Project $project;$project.PlacementPlans[0].placement_kind='human_confirmed';$project.PlacementPlans[0].status='current'
  $canonicalHash=Get-YakuCatCanonicalTranslationSetHash -Project $project;$tmOutboxCount=@($project.TmOutbox).Count
  $entry=Register-YakuCatAbbreviationEntry -Project $project -FullForm 'Net sales' -Abbreviation 'NS' -Meaning '売上高' -Scope document -FirstUseRule define_first
  Chk ([bool]$entry.approved_by_human -and [string]$entry.allowed_scope -eq 'document') '略語は人の明示操作で文書scopeへ登録する'
  $request=New-YakuCatProtectedPublicationCandidateRequest -Root $root -Project $project -Index 0 -PlacementBudget ([pscustomobject]@{max_chars=40;destination_count=1})
  Chk ([string]$request.Envelope.ContractVersion -eq 'protected-prompt-v2' -and [string]$request.Envelope.Prompt -match 'compaction-candidate-v1') '候補生成は専用protected prompt contractを使う'
  Chk ([string]$request.Envelope.Prompt -match 'Every candidates\[\]\.text MUST be English only' -and [string]$request.Envelope.Prompt -match 'Never translate.+back') '候補の出力言語を基準訳側へ固定する'
  Chk (-not ([string]$request.Envelope.Prompt).Contains('123') -and [string]$request.Envelope.Prompt -match '\[\[N\d+\]\]') '原文・基準訳・配置条件を送信前に数値マスクする'
  $badAbbreviationPayload=[ordered]@{contract='compaction-candidate-v1';request_id=[string]$request.RequestId;candidates=@([ordered]@{text='Sales are [[N1]] million yen.';used_abbreviations=@([ordered]@{entry_id=[string]$entry.entry_id;version=1});transformations=@();claimed_preserved_facts=@();fit_estimate='likely';warnings=@()});cannot_fit_reason=''}
  $abbreviationRejected=$false;try{$null=ConvertFrom-YakuPublicationCandidateResponse -Response ('COMPACTION_JSON:'+($badAbbreviationPayload|ConvertTo-Json -Depth 8 -Compress)) -Request $request}catch{$abbreviationRejected=($_.Exception.Message -match 'ABBREVIATION_NOT_USED')}
  Chk $abbreviationRejected '使用を申告した略語が候補本文に無ければ拒否する'
  $protected=$request.ProtectedSidecar|ConvertFrom-Json;$candidateText=([string]$protected.canonical_translation).Replace(' were ',': ')
  $payload=[ordered]@{contract='compaction-candidate-v1';request_id=[string]$request.RequestId;candidates=@([ordered]@{text=$candidateText;used_abbreviations=@();transformations=@('removed copula');claimed_preserved_facts=@('sales amount');fit_estimate='likely';warnings=@()});cannot_fit_reason=''}
  $parsed=ConvertFrom-YakuPublicationCandidateResponse -Response ('COMPACTION_JSON:'+($payload|ConvertTo-Json -Depth 8 -Compress)) -Request $request
  $set=Complete-YakuCatPublicationCandidateSet -Project $project -Request $request -Parsed $parsed
  Chk (@($set.candidates).Count -eq 1 -and [string]$set.candidates[0].text -match '123' -and [string]$set.candidates[0].deterministic_qc_status -eq 'passed') '候補を復号後に現在の原文へ決定論QCする'
  $wrongLanguagePayload=[ordered]@{contract='compaction-candidate-v1';request_id=[string]$request.RequestId;candidates=@([ordered]@{text='売上高は百万円でした。';used_abbreviations=@();transformations=@('逆翻訳');claimed_preserved_facts=@();fit_estimate='likely';warnings=@()});cannot_fit_reason=''}
  $wrongParsed=ConvertFrom-YakuPublicationCandidateResponse -Response ('COMPACTION_JSON:'+($wrongLanguagePayload|ConvertTo-Json -Depth 8 -Compress)) -Request $request;$wrongSet=Complete-YakuCatPublicationCandidateSet -Project $project -Request $request -Parsed $wrongParsed
  Chk ([string]$wrongSet.candidates[0].deterministic_qc_status -eq 'failed') '英訳案件へ日本語候補が返っても採用可能にしない'
  $originalTerminologyHash=[string]$project.TerminologySnapshotHash;$project.TerminologySnapshotHash='changed-after-candidate'
  $staleRejected=$false;try{$null=Apply-YakuCatPublicationCandidate -Project $project -CandidateSet $set -CandidateSetId ([string]$set.candidate_set_id) -CandidateId ([string]$set.candidates[0].candidate_id) -CandidateTextHash ([string]$set.candidates[0].text_hash) -MeaningPreservationConfirmed $true -Reason '原文と基準訳を比較した'}catch{$staleRejected=($_.Exception.Message -match 'CANDIDATE_STALE')}
  Chk $staleRejected '候補生成後に用語依存が変われば採用を拒否する';$project.TerminologySnapshotHash=$originalTerminologyHash
  $meaningRejected=$false;try{$null=Apply-YakuCatPublicationCandidate -Project $project -CandidateSet $set -CandidateSetId ([string]$set.candidate_set_id) -CandidateId ([string]$set.candidates[0].candidate_id) -CandidateTextHash ([string]$set.candidates[0].text_hash) -MeaningPreservationConfirmed $false -Reason '未確認'}catch{$meaningRejected=($_.Exception.Message -match 'MEANING_CONFIRMATION_REQUIRED')};Chk $meaningRejected '人の意味保持確認が無ければAPIでも採用しない'
  $variant=Apply-YakuCatPublicationCandidate -Project $project -CandidateSet $set -CandidateSetId ([string]$set.candidate_set_id) -CandidateId ([string]$set.candidates[0].candidate_id) -CandidateTextHash ([string]$set.candidates[0].text_hash) -MeaningPreservationConfirmed $true -Reason '原文と基準訳を比較した'
  Chk ([string]$segment.Translation -eq 'Net sales were 123 million yen.' -and $segment.Confirmed -and $segment.TmRegistered) '掲載訳採用後も基準訳・確認・TM登録状態を変更しない'
  Chk ([string]$variant.status -eq 'active' -and [string]((Resolve-YakuCatPublicationText -Project $project -Segment $segment).Text) -eq 'Net sales: 123 million yen.') '人が採用した候補だけをactive掲載訳にする'
  Chk ((Get-YakuCatCanonicalTranslationSetHash -Project $project) -eq $canonicalHash -and (Get-YakuCatPublicationTranslationSetHash -Project $project) -ne $canonicalHash -and @($project.TmOutbox).Count -eq $tmOutboxCount) '掲載訳hashだけが変わりTM outboxへ書かない'
  Chk ([string]$project.PlacementPlans[0].status -eq 'stale') '人が確認した既存配置を黙って再利用せずstaleにする'
  $variantHash=[string]$variant.variant_hash;$variant.variant_hash='tampered';$integrityRejected=$false;try{$null=Resolve-YakuCatPublicationText -Project $project -Segment $segment}catch{$integrityRejected=($_.Exception.Message -match 'INTEGRITY_INVALID')};$variant.variant_hash=$variantHash
  Chk $integrityRejected 'active掲載訳の不変hashを利用直前に再検証する'
  $null=Set-YakuCatPlacementSlices -Project $project -Index 0 -Slices @([string]$variant.text);$currentPlan=$project.PlacementPlans[0]
  $currentPlan.source_contract.publication_variant_revision=99;$currentPlan.plan_hash=Get-YakuCatPlacementPlanHash -Plan $currentPlan;$bindingRejected=$false;try{$null=Get-YakuCatPlacementTranslationByBlockId -Project $project -TranslationBySegmentIndex @{0=[string]$segment.Translation}}catch{$bindingRejected=($_.Exception.Message -match 'PLACEMENT_(?:STALE|PRECONDITION)')}
  Chk $bindingRejected 'variant ID・revision・hashと異なる配置をwrite前に拒否する'
  $currentPlan.source_contract.publication_variant_revision=[int]$variant.revision;$currentPlan.plan_hash=Get-YakuCatPlacementPlanHash -Plan $currentPlan
  $variantRenderFingerprint=Get-YakuCatRenderInputFingerprint -Project $project;$null=Revert-YakuCatPublicationVariant -Project $project -SegmentId ([string]$segment.SegmentId) -Reason '基準訳へ戻す試験';$canonicalRenderFingerprint=Get-YakuCatRenderInputFingerprint -Project $project
  Chk ($variantRenderFingerprint -ne $canonicalRenderFingerprint -and [string]$project.PlacementPlans[0].status -eq 'stale') '基準訳へ戻しても旧variant PDFと配置をcurrentにしない'
  $variant=Apply-YakuCatPublicationCandidate -Project $project -CandidateSet $set -CandidateSetId ([string]$set.candidate_set_id) -CandidateId ([string]$set.candidates[0].candidate_id) -CandidateTextHash ([string]$set.candidates[0].text_hash) -MeaningPreservationConfirmed $true -Reason '再採用してidentityを確認';$secondVariantFingerprint=Get-YakuCatRenderInputFingerprint -Project $project
  Chk ($secondVariantFingerprint -ne $variantRenderFingerprint) '同本文を再採用しても新variant identityで旧PDFを復活させない'
  $project.Revision=0;Chk (Save-YakuCatProject -Project $project) 'variantをgenerationへ原子的に保存する';$restored=Restore-YakuCatProject -Id ([string]$project.Id)
  Chk (@($restored.PublicationVariants).Count -eq 2 -and @($restored.AbbreviationEntries).Count -eq 1 -and [string]((Resolve-YakuCatPublicationText -Project $restored -Segment $restored.Segments[0]).Text) -match 'Net sales:') 'variant・略語registry・active pointerを保存復元する'
  $beforeTm=[bool]$restored.Segments[0].TmRegistered;$null=Revert-YakuCatPublicationVariant -Project $restored -SegmentId ([string]$restored.Segments[0].SegmentId) -Reason '基準訳へ戻す'
  Chk (-not [bool]((Resolve-YakuCatPublicationText -Project $restored -Segment $restored.Segments[0]).IsVariant) -and [bool]$restored.Segments[0].TmRegistered -eq $beforeTm) '掲載訳を戻しても基準訳とTMを維持する'
  $idempotencyKey='publication-test-'+[guid]::NewGuid().ToString('N');$expectedRevision=[int]$restored.Revision
  $requestHash=Get-YakuCatSourceIntegrityHash -Text 'register|Operating profit|OP|営業利益'
  $receiptMutation={param($candidate);Register-YakuCatAbbreviationEntry -Project $candidate -FullForm 'Operating profit' -Abbreviation 'OP' -Meaning '営業利益' -Scope project -FirstUseRule define_first}
  $firstCommit=Invoke-YakuCatProjectMutation -ProjectId ([string]$restored.Id) -ExpectedRevision $expectedRevision -Mutation $receiptMutation -IdempotencyKey $idempotencyKey -Action abbreviation-register -RequestHash $requestHash
  $firstRevision=[int]$firstCommit.Project.Revision;$firstEntryCount=@($firstCommit.Project.AbbreviationEntries).Count;$firstEventCount=@($firstCommit.Project.ReviewEvents).Count
  $secondCommit=Invoke-YakuCatProjectMutation -ProjectId ([string]$restored.Id) -ExpectedRevision $expectedRevision -Mutation $receiptMutation -IdempotencyKey $idempotencyKey -Action abbreviation-register -RequestHash $requestHash
  Chk ([bool]$secondCommit.Replayed -and [int]$secondCommit.Project.Revision -eq $firstRevision -and @($secondCommit.Project.AbbreviationEntries).Count -eq $firstEntryCount -and @($secondCommit.Project.ReviewEvents).Count -eq $firstEventCount) '同じkey・payloadの再送は古いrevisionでも二重登録しない'
  $restoredReceipt=Restore-YakuCatProject -Id ([string]$restored.Id)
  $preJobReplay=Get-YakuCatProjectMutationReplay -ProjectId ([string]$restored.Id) -IdempotencyKey $idempotencyKey -Action abbreviation-register -RequestHash $requestHash
  $firstOperationJson=$firstCommit.Result|ConvertTo-Json -Depth 20 -Compress;$replayedOperationJson=$preJobReplay.Result|ConvertTo-Json -Depth 20 -Compress
  Chk ([bool]$preJobReplay.Replayed -and $replayedOperationJson -ceq $firstOperationJson -and [int]$preJobReplay.Receipt.committed_revision -eq [int]$firstCommit.Receipt.committed_revision) '一時jobを参照しない永続receipt replayも初回と同じoperation resultを返す'
  $thirdCommit=Invoke-YakuCatProjectMutation -ProjectId ([string]$restored.Id) -ExpectedRevision $expectedRevision -Mutation $receiptMutation -IdempotencyKey $idempotencyKey -Action abbreviation-register -RequestHash $requestHash
  Chk ([bool]$thirdCommit.Replayed -and @($restoredReceipt.MutationReceipts).Count -eq 1 -and [string]$thirdCommit.Receipt.result_hash -eq [string]$firstCommit.Receipt.result_hash) '再起動相当の復元後もreceiptから同じ結果を返す'
  $keyReuseRejected=$false;try{$null=Invoke-YakuCatProjectMutation -ProjectId ([string]$restored.Id) -ExpectedRevision $expectedRevision -Mutation $receiptMutation -IdempotencyKey $idempotencyKey -Action abbreviation-register -RequestHash (Get-YakuCatSourceIntegrityHash -Text 'different')}catch{$keyReuseRejected=($_.Exception.Message -match 'IDEMPOTENCY_KEY_REUSED')}
  Chk $keyReuseRejected '同じkeyを異なるpayloadへ使った場合は競合として拒否する'
  $staleCopy=Copy-YakuCatProjectForMutation -Project $thirdCommit.Project;$advanceMutation={param($candidate);$candidate.PromotedAt=(Get-Date).ToString('o');return 'advanced'}
  $advanced=Invoke-YakuCatProjectMutation -ProjectId ([string]$restored.Id) -ExpectedRevision ([int]$thirdCommit.Project.Revision) -Mutation $advanceMutation
  $staleSaveAccepted=Save-YakuCatProject -Project $staleCopy
  $afterConflict=Restore-YakuCatProject -Id ([string]$restored.Id)
  Chk (-not $staleSaveAccepted -and [int]$afterConflict.Revision -eq [int]$advanced.Project.Revision -and [string]$afterConflict.ActiveGenerationId -eq [string]$advanced.Project.ActiveGenerationId) 'disk manifest CASが古い別projectの後勝ち上書きを拒否する'
  $serverSource=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
  $publicationApplyStart=$serverSource.IndexOf("'publication-apply' {");$publicationApplyEnd=$serverSource.IndexOf("'publication-revert' {",$publicationApplyStart);$publicationApplySource=$serverSource.Substring($publicationApplyStart,$publicationApplyEnd-$publicationApplyStart)
  Chk ($serverSource -match 'CAT_IDEMPOTENCY_KEY_REQUIRED' -and $serverSource -match 'function ConvertTo-YakuCatMutationResponseJson' -and $serverSource -match 'operation_result' -and $serverSource -match 'mutation_result_hash') 'receipt対象APIはkeyを必須化し、保存済みoperation resultとhashを返す'
  Chk ($publicationApplySource.IndexOf('Get-YakuCatProjectMutationReplay') -ge 0 -and $publicationApplySource.IndexOf('Get-YakuCatProjectMutationReplay') -lt $publicationApplySource.IndexOf('YakuTranslateJobs.ContainsKey')) 'publication applyは一時job tableより先に永続receiptを照合する'
  Chk ($serverSource -match "'CAT_REBASE_APPLY_CAS_MISMATCH'.*'CAT_REBASE_APPLY_TARGET_MISMATCH'.*'CAT_COMMIT_MANIFEST_CONFLICT'") 'source-updateとmanifest CAS競合をtyped HTTP 409へ分類する'
}finally{if($null -eq $oldData){Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue}else{$env:YAKULINGO_DATA_DIR=$oldData};if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
if($script:fail){throw ($script:fail.ToString()+' publication checks failed')};Write-Host 'Publication variant contract tests passed.' -ForegroundColor Green
