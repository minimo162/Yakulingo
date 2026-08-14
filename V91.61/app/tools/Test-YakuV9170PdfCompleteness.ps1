<# V91.70: PDF掲載文字の抽出照合、未確認扱い、人の目視判断の回帰テスト。 #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path;$root=Split-Path -Parent $toolsRoot;$script:fail=0
foreach($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1','Render.ps1','VersionUpdate.ps1','SourceRebase.ps1','Review.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
function Chk{param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++}}

$sourceId='1'*32;$projectId='2'*32;$pdfHash='3'*64;$renderId='4'*32
$safeStructure=[pscustomobject]@{contract_version='excel-cell-structure-v2';read_status='verified';merge_kind='none';merge_area='';has_formula=$false;has_array_formula=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none'}
$safeStructureHash=Get-YakuCatSourceIntegrityHash -Text ($safeStructure|ConvertTo-Json -Depth 6 -Compress)
$segments=@(
    [pscustomobject]@{SegmentId='a'*32;SourceRevision=1;SourceIntegrityHash=(Get-YakuCatSourceIntegrityHash -Text '原文A');Text='原文A';Translation='Published sentence A.';Kind='cell';BlockIds=@('b1');Cells=@([pscustomobject]@{Text='原文A';Address='A1';StructureContract=$safeStructure;StructureFingerprint=$safeStructureHash});Sheet='Sheet1'},
    [pscustomobject]@{SegmentId='b'*32;SourceRevision=1;SourceIntegrityHash=(Get-YakuCatSourceIntegrityHash -Text '原文B');Text='原文B';Translation='Published sentence B.';Kind='cell';BlockIds=@('b2');Cells=@([pscustomobject]@{Text='原文B';Address='A2';StructureContract=$safeStructure;StructureFingerprint=$safeStructureHash});Sheet='Sheet1'}
)
$project=[pscustomobject]@{Id=$projectId;ActiveSourceId=$sourceId;SourceArtifactSha256=('5'*64);Revision=7;Source='file';DocumentFormat='xlsx';Direction='to_en';TerminologySnapshotHash='';Segments=$segments;Blocks=@();PlacementPlans=@();PlacementSetHash='';DocumentFindings=@();ReviewRuns=@();ReviewEvents=@();FinalReviewDecisions=@()}
$null=Initialize-YakuCatProjectState -Project $project;$null=Sync-YakuCatPlacementPlans -Project $project
$initialBinding=Test-YakuCatPlacementPlanBinding -Project $project -Segment $project.Segments[0] -Plan $project.PlacementPlans[0]
Chk ([bool]$initialBinding.Passed) ('生成直後のPlacementPlanが自己整合する '+(@($initialBinding.Reasons)-join ','))
Chk ([string]$project.PlacementPlans[0].destinations[0].text -eq 'Published sentence A.') '単一セルのPlacementPlanへ先頭1文字でなく掲載訳全文を保持する'
$renderFingerprint=Get-YakuCatRenderInputFingerprint -Project $project
function Resolve-YakuCatRenderPdf { param([string]$ProjectId,[string]$RenderId) return [pscustomobject]@{Path='C:\fake\preview.pdf';Manifest=[pscustomobject]@{canonical_pdf_sha256=$script:PdfReviewHash;source_snapshot_id=$script:PdfReviewSource;input_fingerprint=$script:PdfReviewFingerprint;print_conformance_status='verified'}} }
$script:PdfReviewHash=$pdfHash;$script:PdfReviewSource=$sourceId;$script:PdfReviewFingerprint=$renderFingerprint
function New-TestPdfPage { param([int]$Page,[string[]]$Texts) $x=10.0;$items=@();foreach($value in $Texts){$items+= [pscustomobject]@{text=$value;bbox=[pscustomobject]@{space='viewport_points';x=$x;y=20.0;w=120.0;h=12.0;page_width=600.0;page_height=800.0;rotation=0;crop_box=@(0,0,600,800)}};$x+=130};return [pscustomobject]@{page=$Page;text=($Texts -join ' ');page_box=[pscustomobject]@{width=600.0;height=800.0;rotation=0;crop_box=@(0,0,600,800)};items=$items} }
$versionBlocked=$false;try{$null=Invoke-YakuCatPdfTextCompletenessReview -Project $project -RenderId $renderId -PdfSha256 $pdfHash -ExtractorContract 'pdfjs-text-v2@9.9.9' -PageCount 1 -Pages @(New-TestPdfPage -Page 1 -Texts @('x'))}catch{$versionBlocked=$_.Exception.Message -match 'CAT_PDF_REVIEW_EXTRACTOR_INVALID'}
Chk $versionBlocked '同梱版と異なるPDF抽出器の結果を拒否する'
$countBlocked=$false;try{$null=Invoke-YakuCatPdfTextCompletenessReview -Project $project -RenderId $renderId -PdfSha256 $pdfHash -ExtractorContract 'pdfjs-text-v2@5.7.284' -PageCount 2 -Pages @(New-TestPdfPage -Page 1 -Texts @('x'))}catch{$countBlocked=$_.Exception.Message -match 'CAT_PDF_REVIEW_PAGE_COUNT_INVALID'}
Chk $countBlocked 'PDF.jsが報告したページ数と送信page配列の欠落・追加を拒否する'
$run=Invoke-YakuCatPdfTextCompletenessReview -Project $project -RenderId $renderId -PdfSha256 $pdfHash -ExtractorContract 'pdfjs-text-v2@5.7.284' -PageCount 1 -Pages @(New-TestPdfPage -Page 1 -Texts @('Published sentence A.'))
Chk (@($run.coverage_items).Count -eq 2 -and @($run.coverage_items|Where-Object{$_.state -eq 'unmapped'}).Count -eq 2 -and @($run.coverage_items|Where-Object{$_.reason -eq 'text_present_but_position_unassociated'}).Count -eq 1) '文字が一意に存在しても期待セルとの対応がない限り掲載確認済みにしない'
Chk (@($project.DocumentFindings).Count -eq 2 -and @($project.DocumentFindings|Where-Object{[string]$_.category -eq 'rendered_output_completeness' -and [string]$_.message -match '欠落が確定したという意味ではありません'}).Count -eq 2) '抽出結果だけで掲載完了や欠落確定と断定しない'
Chk (-not [bool]$run.coverage_summary.evidence_complete -and -not [bool]$run.coverage_summary.decision_complete) '自動確認不能を証拠完了・人判断完了と区別する'
$unmapped=@($run.coverage_items|Where-Object{$_.state -eq 'unmapped'})
$decision=Set-YakuCatReviewCoverageDecision -Project $project -ReviewRunId ([string]$run.review_run_id) -CoverageItemIds @($unmapped|ForEach-Object{[string]$_.coverage_item_id}) -Note 'PDF画面で全文を確認した'
Chk (-not [bool]$decision.coverage_summary.evidence_complete -and [bool]$decision.coverage_summary.decision_complete -and @($project.ReviewEvents|Where-Object{[string]$_.action -eq 'human_visual_reviewed'}).Count -eq 2) '全掲載箇所への人の目視判断を束縛し、客観的evidence不足はfalseのまま残す'
$duplicateProject=[System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($project));$duplicateProject.DocumentFindings=@();$duplicateProject.ReviewRuns=@();$duplicateProject.ReviewEvents=@()
$duplicateFingerprint=Get-YakuCatRenderInputFingerprint -Project $duplicateProject
Chk ($duplicateFingerprint -eq $renderFingerprint) '監査判断や保存復元だけではrender成果物fingerprintを変えない'
$duplicateRun=Invoke-YakuCatPdfTextCompletenessReview -Project $duplicateProject -RenderId $renderId -PdfSha256 $pdfHash -ExtractorContract 'pdfjs-text-v2@5.7.284' -PageCount 1 -Pages @(New-TestPdfPage -Page 1 -Texts @('Published sentence A.','Published sentence A.'))
$duplicateCoverage=@($duplicateRun.coverage_items|Where-Object{$_.target_ids -contains ('a'*32)})[0]
Chk ([string]$duplicateCoverage.state -eq 'unmapped' -and [string]$duplicateCoverage.reason -eq 'duplicate_text_not_uniquely_mapped' -and [int]$duplicateCoverage.match_count -eq 2) '同一文が複数箇所にある場合は誤って掲載確認済みにしない'
$server=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8;$client=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8;$page=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
$extractor=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'pdf-review.js') -Raw -Encoding UTF8
Chk ($server -match "'pdf-review-apply'" -and $server -match "'coverage-decision'" -and $server -match "'\.mjs'") 'PDF.js抽出結果と目視判断をrevisioned APIで受け、mjsを正しいMIMEで配信する'
Chk ($client -match "import\('/assets/pdf-review.js'\)" -and $page -match '掲載文字を照合' -and $page -match 'PDFを目で確認した') 'PDF表示から抽出照合と人の目視確認へ進める'
Chk ((Test-Path -LiteralPath (Join-Path $root 'www\assets\vendor\pdfjs\pdf.min.mjs')) -and (Test-Path -LiteralPath (Join-Path $root 'www\assets\vendor\pdfjs\pdf.worker.min.mjs')) -and (Test-Path -LiteralPath (Join-Path $root 'www\assets\vendor\pdfjs\LICENSE'))) 'ReportBinderで検証済みのPDF.jsとライセンスをローカル同梱する'
Chk ($extractor -match "BUNDLED_PDFJS_VERSION = '5\.7\.284'" -and $extractor -match 'extractorVersion !== BUNDLED_PDFJS_VERSION' -and $extractor -match 'page_count: doc\.numPages') '抽出結果を同梱PDF.jsの厳密な版と実ページ数へ束縛する'
Chk ($extractor -match 'originX \+ widthX \+ heightX' -and $extractor -match 'originY \+ widthY \+ heightY' -and $extractor -match 'Math\.min\.apply\(null, xs\)' -and $extractor -match 'Math\.max\.apply\(null, ys\)') '回転・縦書きでもtext matrixの4隅からviewport bboxを求める'
if($script:fail){throw ($script:fail.ToString()+' PDF completeness checks failed')}
Write-Host 'PDF completeness checks passed.' -ForegroundColor Green
