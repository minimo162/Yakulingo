<# .SYNOPSIS V91.70 source-faithful render contract regression. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:fail = 0
# CellSegments.ps1 は CatProject.ps1 より先に読む。SrcModules.ps1 の並びと同じ。
# 抜けていると、配置計画が Group-YakuCatSplitSegments を呼んだところで
# CommandNotFoundException になる（2026-08-15 に実際に踏んだ）。
. (Join-Path (Join-Path $root 'src') 'CellSegments.ps1')
. (Join-Path (Join-Path $root 'src') 'CatProject.ps1')
. (Join-Path (Join-Path $root 'src') 'FileProcessors.ps1')
. (Join-Path (Join-Path $root 'src') 'Render.ps1')
function Chk { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++} }
function Copy-TestStructure { param($Value) return [System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($Value)) }
function Test-StructureRejected { param($Value) try { $null=Assert-YakuCatExcelPlacementStructureSafe -Structure $Value -BlockId 'cell|Sheet1|A1'; return $false } catch { return ([string]$_.Exception.Message -match '^CAT_PLACEMENT_PRECONDITION_FAILED:') } }
function Add-TestZipEntry { param($Archive,[string]$Name,[string]$Value) $entry=$Archive.CreateEntry($Name);$stream=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes($Value);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()} }
function New-TestPrintDependencyWorkbook {
    param([string]$Path,[string]$ImagePayload='image-a',[switch]$MissingImage)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
    $archive=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try{
        Add-TestZipEntry $archive 'xl/workbook.xml' '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
        Add-TestZipEntry $archive 'xl/_rels/workbook.xml.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
        Add-TestZipEntry $archive 'xl/worksheets/sheet1.xml' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><pageSetup r:id="rIdPS"/><legacyDrawingHF r:id="rIdHF"/></worksheet>'
        Add-TestZipEntry $archive 'xl/worksheets/_rels/sheet1.xml.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdPS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/printerSettings" Target="../printerSettings/printerSettings1.bin"/><Relationship Id="rIdHF" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing" Target="../drawings/vmlDrawing1.vml"/></Relationships>'
        Add-TestZipEntry $archive 'xl/printerSettings/printerSettings1.bin' 'printer-settings-a'
        Add-TestZipEntry $archive 'xl/drawings/vmlDrawing1.vml' '<xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"><v:shape id="header-image"><v:imagedata o:relid="rIdImage"/></v:shape></xml>'
        Add-TestZipEntry $archive 'xl/drawings/_rels/vmlDrawing1.vml.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdImage" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/></Relationships>'
        if(-not $MissingImage){Add-TestZipEntry $archive 'xl/media/image1.png' $ImagePayload}
    }finally{$archive.Dispose()}
}

$project = [pscustomobject]@{
    ActiveSourceId='11111111111111111111111111111111'; SourceArtifactSha256=('a' * 64); Revision=3
    Segments=@([pscustomobject]@{ SegmentId='22222222222222222222222222222222'; Translation='Translation A' })
}
$first = Get-YakuCatRenderInputFingerprint -Project $project
$project.Segments[0].Translation = 'Translation B'
$targetChanged = Get-YakuCatRenderInputFingerprint -Project $project
$project.Revision++
$revisionChanged = Get-YakuCatRenderInputFingerprint -Project $project
Chk ($first -match '^[a-f0-9]{64}$') 'render input fingerprint is a stable digest'
Chk ($first -ne $targetChanged -and $targetChanged -eq $revisionChanged) 'translation invalidates the render while a decision-only revision does not'
$project|Add-Member -NotePropertyName PlacementSetHash -NotePropertyValue ('b'*64) -Force
$placementChanged=Get-YakuCatRenderInputFingerprint -Project $project
Chk ($placementChanged -ne $revisionChanged) 'placement set hash invalidates the render independently'

$source = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Render.ps1') -Raw -Encoding UTF8
Chk ($source -match 'AutomationSecurity' -or (Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'FileProcessors.ps1') -Raw -Encoding UTF8) -match 'AutomationSecurity\s*=\s*3') 'Excel automation disables macros'
Chk ($source -match 'Open-YakuWorkbookWithManualCalc' -and (Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'FileProcessors.ps1') -Raw -Encoding UTF8) -match 'Workbooks\.Open\(\$Path, 0, \$true\)') 'render opens without link updates and read-only'
Chk ($source -match 'ExportAsFixedFormat\(0,' -and $source -match '\$false, \[Type\]::Missing') 'PDF export honors print areas and does not open the result'
Chk ($source -match 'CAT_RENDER_PRINT_CONFORMANCE_VIOLATED') 'known print-setting mismatch hard-fails'
Chk ($source -match 'PrintTitleRows' -and $source -match 'DifferentFirstPageHeaderFooter' -and $source -match 'HPageBreaks' -and $source -match 'VPageBreaks') 'print fingerprint includes titles, first/even headers, and manual page breaks'
Chk ($source -match 'yaku-print-contract-v3' -and $source -match 'legacyDrawingHF' -and $source -match 'printerSettings' -and $source -match 'content_sha256') 'print contract binds header/footer images and printer settings through OOXML relationships and content hashes'
$knownFields=[pscustomobject][ordered]@{'sheet:1:com:PrintArea'='$A$1:$B$4';'sheet:1:ooxml:page-setup-printer-settings'='none'}
$same=[pscustomobject]@{Contract=[pscustomobject]@{fields=$knownFields};UnknownFields=@()}
$verifiedCompare=Compare-YakuExcelPrintContractSnapshots -Expected $same -Actual $same
Chk ([string]$verifiedCompare.status -eq 'verified' -and @($verifiedCompare.mismatched_fields).Count -eq 0 -and @($verifiedCompare.unknown_fields).Count -eq 0) 'all known equal print fields are verified'
$changedFields=[pscustomobject][ordered]@{'sheet:1:com:PrintArea'='$A$1:$C$4';'sheet:1:ooxml:page-setup-printer-settings'='none'}
$changed=[pscustomobject]@{Contract=[pscustomobject]@{fields=$changedFields};UnknownFields=@()}
$violatedCompare=Compare-YakuExcelPrintContractSnapshots -Expected $same -Actual $changed
Chk ([string]$violatedCompare.status -eq 'violated' -and @($violatedCompare.mismatched_fields) -contains 'sheet:1:com:PrintArea') 'a known print field mismatch is violated'
$unknownExpected=[pscustomobject]@{Contract=[pscustomobject]@{fields=$knownFields};UnknownFields=@('sheet:1:com:PrintArea')}
$unverifiedCompare=Compare-YakuExcelPrintContractSnapshots -Expected $unknownExpected -Actual $changed
Chk ([string]$unverifiedCompare.status -eq 'unverified' -and @($unverifiedCompare.mismatched_fields).Count -eq 0 -and @($unverifiedCompare.unknown_fields) -contains 'sheet:1:com:PrintArea') 'unknown on either side is unverified instead of a false mismatch'
$mixedChanged=[pscustomobject][ordered]@{'sheet:1:com:PrintArea'='$A$1:$C$4';'sheet:1:ooxml:page-setup-printer-settings'='changed'}
$mixed=[pscustomobject]@{Contract=[pscustomobject]@{fields=$mixedChanged};UnknownFields=@('sheet:1:com:PrintArea')}
$mixedCompare=Compare-YakuExcelPrintContractSnapshots -Expected $unknownExpected -Actual $mixed
Chk ([string]$mixedCompare.status -eq 'violated' -and @($mixedCompare.mismatched_fields) -contains 'sheet:1:ooxml:page-setup-printer-settings') 'known mismatch takes precedence over unrelated unknown fields'
$ooxmlFixture=Join-Path (Join-Path $root 'tools\regression') 'V91.38_file数値前処理ミニブック.xlsx';$ooxmlSnapshot=Get-YakuOoxmlPrintDependencySnapshot -Path $ooxmlFixture
Chk (@($ooxmlSnapshot.UnknownFields).Count -eq 0 -and ($ooxmlSnapshot.Fields.PSObject.Properties.Name -contains 'sheet:1:ooxml:page-setup-printer-settings') -and ($ooxmlSnapshot.Fields.PSObject.Properties.Name -contains 'sheet:1:ooxml:header-footer-images')) 'OOXML print dependency extraction reports explicit none for a plain real workbook'
$printFixtureDir=Join-Path ([IO.Path]::GetTempPath()) ('yaku-print-contract-test-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $printFixtureDir
try{
    $printFixtureA=Join-Path $printFixtureDir 'a.xlsx';$printFixtureB=Join-Path $printFixtureDir 'b.xlsx';$printFixtureMissing=Join-Path $printFixtureDir 'missing.xlsx'
    New-TestPrintDependencyWorkbook -Path $printFixtureA -ImagePayload 'image-a';New-TestPrintDependencyWorkbook -Path $printFixtureB -ImagePayload 'image-b';New-TestPrintDependencyWorkbook -Path $printFixtureMissing -MissingImage
    $dependencyA=Get-YakuOoxmlPrintDependencySnapshot -Path $printFixtureA;$dependencyB=Get-YakuOoxmlPrintDependencySnapshot -Path $printFixtureB;$dependencyMissing=Get-YakuOoxmlPrintDependencySnapshot -Path $printFixtureMissing
    $printerRecord=([string]$dependencyA.Fields.'sheet:1:ooxml:page-setup-printer-settings'|ConvertFrom-Json);$headerRecord=([string]$dependencyA.Fields.'sheet:1:ooxml:header-footer-images'|ConvertFrom-Json)
    Chk ($printerRecord.content_sha256 -match '^[a-f0-9]{64}$' -and $headerRecord.content_sha256 -match '^[a-f0-9]{64}$' -and @($headerRecord.images).Count -eq 1 -and [string]$headerRecord.images[0].content_sha256 -match '^[a-f0-9]{64}$') 'OOXML relationship targets include printer, VML, and header image content hashes'
    Chk ([string]$dependencyA.Fields.'sheet:1:ooxml:header-footer-images' -cne [string]$dependencyB.Fields.'sheet:1:ooxml:header-footer-images') 'a changed header image changes the known print dependency field'
    Chk (@($dependencyMissing.UnknownFields) -contains 'sheet:1:ooxml:header-footer-images' -and $null -eq $dependencyMissing.Fields.PSObject.Properties['sheet:1:ooxml:header-footer-images']) 'a missing header image target is unknown rather than silently treated as absent'
}finally{if(Test-Path -LiteralPath $printFixtureDir){Remove-Item -LiteralPath $printFixtureDir -Recurse -Force}}
Chk ($source -match 'Get-YakuCatDraftWritebackCompleteness' -and $source -match 'CAT_RENDER_WRITEBACK_COMPLETENESS_VIOLATED') 'all placement destinations are read back before PDF publication and mismatch hard-fails'
Chk ($source -match 'CAT_RENDER_SOURCE_ARTIFACT_CONFLICT' -and $source -match 'source-input' -and $source -match 'measured_source_sha256' -and $source -match 'Export-YakuCatProject -Project \$renderProject') 'render verifies the project source hash and uses one private source copy for the DRAFT and paired PDFs'
Chk ($source -match "canonical_pdf_sha256" -and $source -match "profile_id='source_faithful'") 'render manifest identifies the canonical PDF and profile'
Chk ($source -match "source_pdf_sha256" -and $source -match "source-preview\.pdf" -and $source -match "ValidateSet\('target','source'\)") 'one render binds separately hashed source and translated PDFs'
Chk ($source -match "writeback_completeness=" -and $source -match "pdf_text_completeness_status='not_checked'") 'manifest distinguishes verified Excel writeback from not-yet-checked PDF text completeness'
$pdfFixtureDir=Join-Path ([IO.Path]::GetTempPath()) ('yaku-pdf-structure-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $pdfFixtureDir
try{
    $validPdf=Join-Path $pdfFixtureDir 'valid.pdf';[IO.File]::WriteAllText($validPdf,"%PDF-1.4`n1 0 obj <</Type /Page>> endobj`n%%EOF`n",[Text.Encoding]::ASCII)
    $pdfSnapshot=Get-YakuGeneratedPdfStructuralSnapshot -Path $validPdf
    Chk ([string]$pdfSnapshot.status -eq 'structurally_verified' -and [int]$pdfSnapshot.page_count_estimate -eq 1) 'generated PDF is signature, EOF, size, and structural page checked before publication'
    $brokenPdf=Join-Path $pdfFixtureDir 'broken.pdf';[IO.File]::WriteAllText($brokenPdf,"not-a-pdf`n%%EOF`n",[Text.Encoding]::ASCII)
    $brokenRejected=$false;try{$null=Get-YakuGeneratedPdfStructuralSnapshot -Path $brokenPdf}catch{$brokenRejected=$_.Exception.Message -match 'CAT_RENDER_PDF_SIGNATURE_INVALID'}
    Chk $brokenRejected 'invalid PDF signature is rejected before manifest publication'
}finally{if(Test-Path -LiteralPath $pdfFixtureDir){Remove-Item -LiteralPath $pdfFixtureDir -Recurse -Force}}
Chk ($source -match 'source_snapshot_id=' -and $source -match 'input_fingerprint=') 'render is bound to source snapshot and dependency fingerprint'
$server = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
$client = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
$page = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
Chk ($server -match "'render-start'" -and $server -match "ResultKind='render'" -and $server -match 'CAT_RENDER_DEPENDENCY_STALE') 'render runs as a typed background job with start-time CAS'
Chk ($server -match "path -eq '/api/cat/render-pdf'" -and $server.Contains('StatusCode = $(if($partial){206}else{200})')) 'authenticated PDF endpoint supports byte ranges'
Chk ($server -match 'currentRenderProject' -and $server -match 'CAT_RENDER_DEPENDENCY_STALE') 'PDF delivery rejects a render whose source or translation dependencies are no longer current'
Chk ($client -match "post\('render-start'" -and $client -match 'application_status' -and $client -match 'URL\.createObjectURL') 'browser rejects stale render and displays authenticated PDF bytes'
Chk ($client -match 'previewDependencyToken' -and $client -match '内容または配置が変わりました。PDFを作り直してください') 'an already displayed PDF blob is cleared when source, translation, publication, or placement changes'
Chk ($client -match 'data-cat-pdf-side' -and $client -match "kind=' \+ encodeURIComponent\(side\)" -and $page -match '訳文PDF' -and $page -match '原文PDF') 'preview switches the source and translated PDFs from the same render'
Chk ($page -match 'Excelへの配置' -and $page -match '印刷結果PDF' -and $page -match 'PDFを作成・更新') 'preview separates structural placement from actual print result'
Chk ($server -match "'placement'" -and $server -match 'Set-YakuCatPlacementSlices') 'manual cell-boundary placement uses a revisioned CAT mutation'
Chk ($server -match "receiptActions = @\('placement'" -and $server -match 'CAT_PLACEMENT_TARGET_CONFLICT' -and $client -match 'placement_plan_hash') 'placement retries are idempotent and bound to the plan the user edited'
Chk ($client -match 'data-cat-placement-edit' -and $client -match "post\('placement'" -and $page -match 'cat-placement-slices') 'preview lets the user adjust cell boundaries without changing the translation'
$fileProcessors=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'FileProcessors.ps1') -Raw -Encoding UTF8
$catProject=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CatProject.ps1') -Raw -Encoding UTF8
Chk ($fileProcessors -match 'excel-cell-structure-v2' -and $fileProcessors -match 'has_spill' -and $fileProcessors -match "validationType='unknown'" -and $fileProcessors -match 'worksheet_protect_contents') 'source extraction fingerprints formula, merge, protection, validation, and spill preconditions without collapsing unknown reads'
Chk ($catProject -match 'expected_structure_fingerprint' -and $catProject -match '配置先セルの結合・保護・書式等が計画作成後に変わりました' -and $catProject -match '同じ原文blockが複数の配置先') 'all placement structure and destination preconditions are checked before the first write'
$safeStructure=[pscustomobject]@{contract_version='excel-cell-structure-v2';merge_kind='none';merge_area='';has_formula=$false;has_array=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none'}
Chk ([bool](Assert-YakuCatExcelPlacementStructureSafe -Structure $safeStructure -BlockId 'cell|Sheet1|A1')) 'a fully observed plain cell passes the write safety gate'
$duplicatePlanRejected=$false
$duplicateProject=[pscustomobject]@{Id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';Source='file';Segments=@();PlacementPlans=@([pscustomobject]@{segment_id='dup'},[pscustomobject]@{segment_id='dup'})}
try{$null=Sync-YakuCatPlacementPlans -Project $duplicateProject}catch{$duplicatePlanRejected=$_.Exception.Message -match 'CAT_PLACEMENT_PLAN_DUPLICATE'}
Chk $duplicatePlanRejected 'duplicate placement plans for one segment fail closed before lookup or mutation'
$emptyPlan=New-YakuExcelCellWritePlan -Blocks @([pscustomobject]@{Id='cell|Sheet1|A1';Text='原文';Meta=[pscustomobject]@{Kind='cell';Row=1;Col=1;Merged=$false}}) -TranslationByBlockId @{'cell|Sheet1|A1'=''}
$spacePlan=New-YakuExcelCellWritePlan -Blocks @([pscustomobject]@{Id='cell|Sheet1|A1';Text='原文';Meta=[pscustomobject]@{Kind='cell';Row=1;Col=1;Merged=$false}}) -TranslationByBlockId @{'cell|Sheet1|A1'=' '}
Chk ([int]$emptyPlan.CellItems.Count -eq 1 -and [string]$emptyPlan.CellItems[0].Translation -eq '' -and [int]$spacePlan.CellItems.Count -eq 1 -and [string]$spacePlan.CellItems[0].Translation -eq ' ') 'explicit empty and whitespace placement slices remain executable cell write items'
$unknownRejected=$true
foreach($field in @('merge_kind','has_formula','has_array','has_spill','worksheet_protect_contents','cell_locked','validation_type')){$candidate=Copy-TestStructure $safeStructure;$candidate.$field='unknown';if(-not (Test-StructureRejected $candidate)){$unknownRejected=$false}}
Chk $unknownRejected 'every safety-critical unknown field fails closed before writeback'
$unsafeRejected=$true
foreach($case in @(
    @{field='merge_kind';value='non_anchor'},@{field='has_formula';value=$true},@{field='has_array';value=$true},@{field='has_spill';value=$true},@{field='validation_type';value='3'}
)){$candidate=Copy-TestStructure $safeStructure;$candidate.($case.field)=$case.value;if(-not (Test-StructureRejected $candidate)){$unsafeRejected=$false}}
$protected=Copy-TestStructure $safeStructure;$protected.worksheet_protect_contents=$true;$protected.cell_locked=$true;if(-not (Test-StructureRejected $protected)){$unsafeRejected=$false}
$mergeWithoutArea=Copy-TestStructure $safeStructure;$mergeWithoutArea.merge_kind='anchor';$mergeWithoutArea.merge_area='unknown';if(-not (Test-StructureRejected $mergeWithoutArea)){$unsafeRejected=$false}
Chk $unsafeRejected 'formula, array, spill, non-anchor merge, protected locked cell, validation, and unreadable merge area are explicitly rejected'
$assertIndex=$catProject.IndexOf('Assert-YakuCatExcelPlacementStructureSafe -Structure $actualStructure');$writeIndex=$catProject.IndexOf('Write-YakuFileTranslations -InputPath')
Chk ($assertIndex -ge 0 -and $writeIndex -gt $assertIndex) 'all structure safety gates run before the writer is invoked'
Chk ($server -match 'down_empty_cells' -and $server -match 'DownEmptyCells' -and $server -match 'CAT_PLACEMENT_EMPTY_COUNT_INVALID') 'placement API accepts only an explicit zero-to-three empty-cell selection'
Chk ($page -match 'cat-placement-down' -and $client -match 'renderPlacementSliceEditors' -and $client -match 'down_empty_cells') 'placement dialog adds and removes one-to-three lower-cell slice editors'
Chk ($catProject -match "mode='use_confirmed_empty'" -and $catProject -match 'empty_selection_ordinal' -and $catProject -match "mode=\[string\].*mode") 'confirmed empty destinations are persisted and exposed with an explicit placement mode'
Chk ($catProject -match 'Get-YakuCatExcelConfirmedEmptyCellSnapshot' -and $catProject -match '\.Value2' -and $catProject -match 'Get-YakuExcelCellStructureContract' -and $catProject -match 'Test-YakuCatExcelCellShapeOverlap') 'empty-cell selection is checked against the actual workbook rather than inferred from extracted text'
$emptySafetyFields=@('has_formula','has_array','has_spill','worksheet_protect_contents','cell_locked','validation_type','row_hidden','column_hidden','merge_kind')
$allEmptySafetyFieldsPresent=$true;foreach($field in $emptySafetyFields){if($catProject -notmatch [regex]::Escape($field)){$allEmptySafetyFieldsPresent=$false}}
Chk $allEmptySafetyFieldsPresent 'confirmed empty cells fail closed on formula, array, spill, protection, validation, hidden, and merge state'
$emptyPreflightIndex=$catProject.IndexOf('Get-YakuCatConfirmedEmptyWriteTargets -Project $Project')
Chk ($emptyPreflightIndex -ge 0 -and $writeIndex -gt $emptyPreflightIndex) 'all confirmed empty destinations are rechecked before the first DRAFT write'

# The COM boundary is mocked here so this contract test is deterministic. The
# production helper above is separately pinned to real Workbook/Worksheet reads.
function Resolve-YakuCatPublicationText {
    param($Project,$Segment)
    $text=[string]$Segment.Translation
    return [pscustomobject]@{Text=$text;TextHash=(Get-YakuCatSourceIntegrityHash -Text $text);VariantId='';VariantRevision=0;VariantHash='';IsVariant=$false}
}
$placementSegment=[pscustomobject]@{
    SegmentId='33333333333333333333333333333333';Kind='cell';Text='原文';Translation='First second third';Sheet='Sheet1'
    BlockIds=@('cell|Sheet1|A1');Cells=@([pscustomobject]@{Text='原文';Address='A1';StructureFingerprint='';StructureContract=$null;SheetCodeName='Sheet1'})
    SourceRevision=1;SourceIntegrityHash=(Get-YakuCatSourceIntegrityHash -Text '原文');TmRegistered=$true;TmRegistrationEventId='tm-event'
}
$placementProject=[pscustomobject]@{
    Id='44444444444444444444444444444444';Source='text';DocumentFormat='xlsx';Path='not-opened-by-mock.xlsx';ActiveSourceId='55555555555555555555555555555555'
    Revision=4;Direction='to_en';TerminologySnapshotHash='';Segments=@($placementSegment);Blocks=@();PlacementPlans=@();ReviewEvents=@();TmOutbox=@([pscustomobject]@{event_id='existing-tm'})
}
$null=Initialize-YakuCatProjectState -Project $placementProject
$null=Sync-YakuCatPlacementPlans -Project $placementProject
function Get-YakuCatConfirmedEmptyDownDestinations {
    param($Project,$Plan,[int]$CellCount)
    $items=New-Object System.Collections.Generic.List[object]
    for($ordinal=1;$ordinal -le $CellCount;$ordinal++){
        $address='A'+[string](1+$ordinal);$blockId='confirmed-empty|'+[string]$ordinal
        $structure=[pscustomobject]@{contract_version='excel-cell-structure-v2';merge_kind='none';merge_area='';has_formula=$false;has_array=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none';row_hidden='False';column_hidden='False'}
        $items.Add([pscustomobject]@{block_id=$blockId;sheet='Sheet1';address=$address;text='';expected_source_hash=(Get-YakuCatSourceIntegrityHash -Text '');expected_cell_fingerprint=(Get-YakuCatSourceIntegrityHash -Text ($blockId+'|'));expected_sheet_code_name='Sheet1';expected_structure_fingerprint=(Get-YakuCatSourceIntegrityHash -Text ($structure|ConvertTo-Json -Compress));structure_contract=$structure;merge_contract=[pscustomobject]@{expected_kind='none';expected_area='';write_anchor_address=$address};mode='use_confirmed_empty';empty_selection_ordinal=$ordinal})|Out-Null
    }
    return @($items.ToArray())
}
$beforeCanonical=[string]$placementSegment.Translation;$beforeSource=[string]$placementSegment.Text;$beforeTmEvent=[string]$placementSegment.TmRegistrationEventId;$beforeTmOutbox=@($placementProject.TmOutbox).Count
$confirmedPlan=Set-YakuCatPlacementSlices -Project $placementProject -Index 0 -Slices @('First ','second ','third') -DownEmptyCells 2
$confirmedDestinations=@($confirmedPlan.destinations);$confirmedExtras=@($confirmedDestinations|Where-Object{[string]$_.mode -eq 'use_confirmed_empty'})
Chk ($confirmedDestinations.Count -eq 3 -and $confirmedExtras.Count -eq 2 -and (@($confirmedDestinations|ForEach-Object{[string]$_.text}) -join '') -ceq 'First second third') 'one-to-three lower slices reconstruct the complete publication translation without loss'
Chk ([string]$placementSegment.Translation -ceq $beforeCanonical -and [string]$placementSegment.Text -ceq $beforeSource -and [bool]$placementSegment.TmRegistered -and [string]$placementSegment.TmRegistrationEventId -ceq $beforeTmEvent -and @($placementProject.TmOutbox).Count -eq $beforeTmOutbox) 'placement changes neither source, canonical translation, nor translation-memory registration'
$bindingAfterEmpty=Test-YakuCatPlacementPlanBinding -Project $placementProject -Segment $placementSegment -Plan $confirmedPlan
Chk ([bool]$bindingAfterEmpty.Passed) 'confirmed empty destinations remain bound by placement hash and lossless slice reconstruction'
$sourceOnlyMap=Get-YakuCatPlacementTranslationByBlockId -Project $placementProject -TranslationBySegmentIndex @{0='First second third'}
Chk ($sourceOnlyMap.Count -eq 1 -and $sourceOnlyMap.ContainsKey('cell|Sheet1|A1') -and -not $sourceOnlyMap.ContainsKey('confirmed-empty|1')) 'confirmed empty destinations are not treated as source blocks or TM-aligned translations'

if($script:fail){throw ($script:fail.ToString()+' render checks failed')}
Write-Host 'Render contract tests passed.' -ForegroundColor Green
