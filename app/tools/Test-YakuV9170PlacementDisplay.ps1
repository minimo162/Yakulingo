[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path;$root=Split-Path -Parent $toolsRoot;$script:fail=0
. (Join-Path $root 'src\SrcModules.ps1')
foreach($name in $script:YakuSrcModuleFiles){. (Join-Path (Join-Path $root 'src') $name)}
function Chk{param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++}}

$work=Join-Path ([IO.Path]::GetTempPath()) ('yaku-placement-display-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work -Force
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $path=Join-Path $work 'spill.xlsx'
    $parts=@{
        '[Content_Types].xml'='<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>'
        'xl/workbook.xml'='<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
        'xl/_rels/workbook.xml.rels'='<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
        'xl/styles.xml'='<?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/></font></fonts><cellXfs count="1"><xf numFmtId="0" fontId="0"/></cellXfs></styleSheet>'
        'xl/worksheets/sheet1.xml'='<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetFormatPr defaultColWidth="9"/><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>source</t></is></c><c r="D1" t="inlineStr"><is><t>occupied</t></is></c></row></sheetData></worksheet>'
    }
    $stream=New-Object IO.FileStream($path,'Create')
    try{$zip=New-Object IO.Compression.ZipArchive($stream,'Create');try{foreach($name in $parts.Keys){$entry=$zip.CreateEntry($name);$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)));try{$writer.Write([string]$parts[$name])}finally{$writer.Dispose()}}}finally{$zip.Dispose()}}finally{$stream.Dispose()}

    $structure=[pscustomobject]@{contract_version='excel-cell-structure-v2';merge_kind='none';merge_area='';has_formula=$false;has_array=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none';wrap_text='False';style='Normal';number_format='General';row_height='15';column_width='9';row_hidden='False';column_hidden='False'}
    $structureHash=Get-YakuCatSourceIntegrityHash -Text ($structure|ConvertTo-Json -Depth 6 -Compress)
    $segment=[pscustomobject]@{SegmentId=('a'*32);SourceRevision=1;SourceIntegrityHash=(Get-YakuCatSourceIntegrityHash -Text 'source');Text='source';Translation='A sentence that needs visible room.';Kind='cell';BlockIds=@('b1');Cells=@([pscustomobject]@{BlockId='b1';Text='source';Address='A1';Row=1;Column=1;StructureContract=$structure;StructureFingerprint=$structureHash});Sheet='Sheet1';Location='Sheet1, A1';State='machine_draft';Confirmed=$false}
    $project=[pscustomobject]@{Id=([guid]::NewGuid().ToString('N'));Path=$path;FileName='spill.xlsx';Source='file';DocumentFormat='xlsx';Direction='to_en';ActiveSourceId=('1'*32);SourceArtifactSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();SourceSnapshots=@();Segments=@($segment);Blocks=@([pscustomobject]@{Id='b1';Text='source';Location='Sheet1, A1';Meta=[pscustomobject]@{Kind='cell';Sheet='Sheet1';A1='A1';StructureContract=$structure;StructureFingerprint=$structureHash}});PlacementPlans=@();PlacementSetHash='';ReviewEvents=@();DocumentFindings=@();ReviewRuns=@();FinalReviewDecisions=@();Revision=1}
    $null=Initialize-YakuCatProjectState -Project $project
    $fingerprints=Get-YakuCatSourceSnapshotFingerprints -Project $project -ArtifactPath $path
    $project.SourceSnapshots=@([pscustomobject]@{source_snapshot_id=$project.ActiveSourceId;layout_hash=$fingerprints.LayoutHash;inventory_hash=$fingerprints.InventoryHash;print_hash=$fingerprints.PrintHash;contract_version='cat-source-snapshot-v2'})
    $null=Sync-YakuCatPlacementPlans -Project $project
    $plan=Set-YakuCatPlacementSlices -Project $project -Index 0 -Slices @($segment.Translation) -SpillRightCells 2
    $region=@($plan.display_regions)[0]
    Chk ([string]$region.mode -eq 'spill_right_display_only' -and (@($region.cells)-join ',') -eq 'B1,C1') 'records contiguous empty cells as a display-only region'
    Chk ([string]$region.corridor_fingerprint -match '^[a-f0-9]{64}$' -and [string]$region.verification -eq 'requires_pdf_visual_review') 'binds display region to source layout and requires PDF visual review'
    $occupiedBlocked=$false;try{$null=Set-YakuCatPlacementSlices -Project $project -Index 0 -Slices @($segment.Translation) -SpillRightCells 3}catch{$occupiedBlocked=$_.Exception.Message -match 'CAT_PLACEMENT_SPILL_CELL_OCCUPIED'}
    Chk $occupiedBlocked 'blocks expansion when a right-side cell is occupied'
    $planJson=ConvertTo-YakuCatProjectJson -Project $project|ConvertFrom-Json
    Chk (@($planJson.segments[0].placement.display_regions).Count -eq 1) 'returns the display region to the browser editor'
    $project.Segments[0].Cells[0].StructureContract.wrap_text='True';$project.PlacementPlans=@();$project.PlacementSetHash='';$null=Sync-YakuCatPlacementPlans -Project $project
    $wrapBlocked=$false;try{$null=Set-YakuCatPlacementSlices -Project $project -Index 0 -Slices @($segment.Translation) -SpillRightCells 1}catch{$wrapBlocked=$_.Exception.Message -match 'CAT_PLACEMENT_SPILL_WRAP_UNVERIFIED'}
    Chk $wrapBlocked 'does not treat a wrapped cell as right-side spill'
}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
if($script:fail){throw ($script:fail.ToString()+' placement display checks failed')}
Write-Host 'Placement display tests passed.' -ForegroundColor Green
