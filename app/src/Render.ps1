function Get-YakuExcelPrintContractSnapshot {
    param([Parameter(Mandatory=$true)][string]$Path)
    $context = New-YakuExcelApplication
    $workbook = $null
    try {
        $workbook = Open-YakuWorkbookWithManualCalc -Context $context -Path $Path -ReadOnly $true
        $sheets = New-Object System.Collections.Generic.List[object]
        $unknown = New-Object System.Collections.Generic.List[string]
        $worksheetTotal = [int]$workbook.Worksheets.Count
        for ($worksheetIndex = 1; $worksheetIndex -le $worksheetTotal; $worksheetIndex++) {
            $worksheet = $workbook.Worksheets.Item($worksheetIndex)
            $pageSetup = $null
            try {
                $pageSetup = $worksheet.PageSetup
                $values = [ordered]@{ name=[string]$worksheet.Name; code_name=[string]$worksheet.CodeName; index=[int]$worksheet.Index; visible=[int]$worksheet.Visible }
                foreach ($field in @('PrintArea','PrintTitleRows','PrintTitleColumns','Orientation','PaperSize','Zoom','FitToPagesWide','FitToPagesTall','CenterHorizontally','CenterVertically','LeftMargin','RightMargin','TopMargin','BottomMargin','HeaderMargin','FooterMargin','LeftHeader','CenterHeader','RightHeader','LeftFooter','CenterFooter','RightFooter','FirstPageNumber','Order','BlackAndWhite','Draft','PrintGridlines','PrintHeadings','DifferentFirstPageHeaderFooter','OddAndEvenPagesHeaderFooter','ScaleWithDocHeaderFooter','AlignMarginsHeaderFooter')) {
                    try { $values[$field] = $pageSetup.$field }
                    catch { $values[$field] = $null; $unknown.Add(([string]$worksheet.Name + ':' + $field)) | Out-Null }
                }
                foreach($pageKind in @('FirstPage','EvenPage')){
                    $pageObject=$null
                    try{
                        $pageObject=$pageSetup.$pageKind
                        foreach($part in @('LeftHeader','CenterHeader','RightHeader','LeftFooter','CenterFooter','RightFooter')){
                            $key=$pageKind+$part;try{$values[$key]=$pageObject.$part}catch{$values[$key]=$null;$unknown.Add(([string]$worksheet.Name+':'+$key))|Out-Null}
                        }
                    }catch{$unknown.Add(([string]$worksheet.Name+':'+$pageKind))|Out-Null}
                    finally{Release-YakuComObject $pageObject}
                }
                foreach($axis in @('H','V')){
                    $breaks=$null;$rows=New-Object System.Collections.Generic.List[string]
                    try{
                        $breaks=$(if($axis -eq 'H'){$worksheet.HPageBreaks}else{$worksheet.VPageBreaks})
                        for($breakIndex=1;$breakIndex -le [int]$breaks.Count;$breakIndex++){
                            $break=$null;$location=$null
                            try{$break=$breaks.Item($breakIndex);$breakType=[int]$break.Type;if($breakType -ne -4135){continue};$location=$break.Location;$rows.Add(([string]$location.Address($false,$false,1,$false)+':manual'))|Out-Null}
                            catch{$unknown.Add(([string]$worksheet.Name+':'+$axis+'PageBreak:'+$breakIndex))|Out-Null}
                            finally{Release-YakuComObject $location;Release-YakuComObject $break}
                        }
                        $values[$axis+'PageBreaks']=@($rows.ToArray())
                    }catch{$values[$axis+'PageBreaks']=@();$unknown.Add(([string]$worksheet.Name+':'+$axis+'PageBreaks'))|Out-Null}
                    finally{Release-YakuComObject $breaks}
                }
                $sheets.Add([pscustomobject]$values) | Out-Null
            } finally {
                Release-YakuComObject $pageSetup
                Release-YakuComObject $worksheet
            }
        }
        $sheetCount = 0; $worksheetCount = 0
        try { $sheetCount = [int]$workbook.Sheets.Count } catch { $unknown.Add('workbook:sheets-count') | Out-Null }
        try { $worksheetCount = [int]$workbook.Worksheets.Count } catch { $unknown.Add('workbook:worksheets-count') | Out-Null }
        if ($sheetCount -ne $worksheetCount) { $unknown.Add('workbook:non-worksheet-print-object') | Out-Null }
        $environment=[ordered]@{excel_version='unknown';active_printer='unknown'}
        try{$environment.excel_version=[string]$context.Application.Version}catch{$unknown.Add('environment:excel-version')|Out-Null}
        try{$environment.active_printer=[string]$context.Application.ActivePrinter}catch{$unknown.Add('environment:active-printer')|Out-Null}
        $fieldValues=[ordered]@{}
        $sheetRows=@($sheets.ToArray())
        for($sheetOffset=0;$sheetOffset -lt $sheetRows.Count;$sheetOffset++){
            foreach($property in @($sheetRows[$sheetOffset].PSObject.Properties)){
                $key='sheet:'+($sheetOffset+1)+':com:'+[string]$property.Name;$fieldValues[$key]=$property.Value
                if($unknown.Contains(([string]$sheetRows[$sheetOffset].name+':'+[string]$property.Name))){$unknown.Add($key)|Out-Null}
            }
        }
        $fieldValues['workbook:sheet-count']=$sheetCount;$fieldValues['workbook:worksheet-count']=$worksheetCount
        $fieldValues['environment:excel-version']=[string]$environment.excel_version;$fieldValues['environment:active-printer']=[string]$environment.active_printer
        $ooxml=Get-YakuOoxmlPrintDependencySnapshot -Path $Path
        foreach($property in @($ooxml.Fields.PSObject.Properties)){$fieldValues[[string]$property.Name]=$property.Value}
        foreach($name in @($ooxml.UnknownFields)){$unknown.Add([string]$name)|Out-Null}
        $contract = [ordered]@{ contract_version='yaku-print-contract-v3'; sheets=$sheetRows; fields=[pscustomobject]$fieldValues; unknown_fields=@($unknown.ToArray()|Sort-Object -Unique); sheet_count=$sheetCount; worksheet_count=$worksheetCount; environment=[pscustomobject]$environment }
        $json = $contract | ConvertTo-Json -Depth 8 -Compress
        return [pscustomobject]@{ Contract=[pscustomobject]$contract; Fingerprint=(Get-YakuCatSourceIntegrityHash -Text $json); UnknownFields=@($unknown.ToArray()|Sort-Object -Unique) }
    } finally {
        if ($null -ne $context) {
            Close-YakuExcelObjects -Workbook $workbook -Application $context.Application -Save:$false `
                -OldCalculation $context.OldCalculation -OldCalculateBeforeSave $context.OldCalculateBeforeSave `
                -OldScreenUpdating $context.OldScreenUpdating -OldEnableEvents $context.OldEnableEvents `
                -OldDisplayStatusBar $context.OldDisplayStatusBar -OldFormatConditionsCalc $context.OldFormatConditionsCalc `
                -OldBackgroundChecking $context.OldBackgroundChecking
        }
    }
}

function Get-YakuOoxmlPartSha256 {
    param([Parameter(Mandatory=$true)]$Entry)
    $stream=$null;$sha=$null
    try{$stream=$Entry.Open();$sha=[Security.Cryptography.SHA256]::Create();return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
    finally{if($sha){$sha.Dispose()};if($stream){$stream.Dispose()}}
}

function Resolve-YakuOoxmlPartTarget {
    param([Parameter(Mandatory=$true)][string]$SourcePart,[Parameter(Mandatory=$true)][string]$Target)
    if([string]::IsNullOrWhiteSpace($Target)){return ''}
    try{$base=[Uri]('https://yaku.invalid/'+$SourcePart.TrimStart('/'));$resolved=[Uri]::new($base,$Target);return [Uri]::UnescapeDataString($resolved.AbsolutePath.TrimStart('/'))}catch{return ''}
}

function Get-YakuOoxmlRelationships {
    param([Parameter(Mandatory=$true)]$Archive,[Parameter(Mandatory=$true)][string]$RelationshipPart)
    $entry=$Archive.GetEntry($RelationshipPart);if($null -eq $entry){return $null};$stream=$null
    try{$stream=$entry.Open();$xml=New-Object Xml.XmlDocument;$xml.PreserveWhitespace=$true;$xml.Load($stream);$map=@{};foreach($node in @($xml.SelectNodes("//*[local-name()='Relationship']"))){$map[[string]$node.Id]=[pscustomobject]@{id=[string]$node.Id;type=[string]$node.Type;target=[string]$node.Target;target_mode=[string]$node.TargetMode}};return $map}
    finally{if($stream){$stream.Dispose()}}
}

function Get-YakuOoxmlPrintDependencySnapshot {
    <# Excel COMでは見えない印刷依存物を、OOXML relationshipとpart内容へ束縛する。 #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $fields=[ordered]@{};$unknown=New-Object System.Collections.Generic.List[string];$archive=$null
    try{
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop;$archive=[IO.Compression.ZipFile]::OpenRead($Path)
        $workbookEntry=$archive.GetEntry('xl/workbook.xml');$workbookRels=Get-YakuOoxmlRelationships -Archive $archive -RelationshipPart 'xl/_rels/workbook.xml.rels'
        if($null -eq $workbookEntry -or $null -eq $workbookRels){throw 'workbook relationship is unavailable'}
        $stream=$null;try{$stream=$workbookEntry.Open();$xml=New-Object Xml.XmlDocument;$xml.Load($stream);$sheetNodes=@($xml.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']"))}finally{if($stream){$stream.Dispose()}}
        for($index=0;$index -lt $sheetNodes.Count;$index++){
            $prefix='sheet:'+($index+1)+':ooxml:';$sheetNode=$sheetNodes[$index];$rid=[string]$sheetNode.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships');$sheetRel=$workbookRels[$rid]
            if($null -eq $sheetRel -or [string]$sheetRel.target_mode -eq 'External'){$unknown.Add($prefix+'worksheet-part')|Out-Null;continue}
            $sheetPart=Resolve-YakuOoxmlPartTarget -SourcePart 'xl/workbook.xml' -Target ([string]$sheetRel.target);$sheetEntry=$archive.GetEntry($sheetPart)
            if($null -eq $sheetEntry){$unknown.Add($prefix+'worksheet-part')|Out-Null;continue}
            $sheetStream=$null;try{$sheetStream=$sheetEntry.Open();$sheetXml=New-Object Xml.XmlDocument;$sheetXml.Load($sheetStream)}catch{$unknown.Add($prefix+'worksheet-xml')|Out-Null;continue}finally{if($sheetStream){$sheetStream.Dispose()}}
            $sheetDir=[IO.Path]::GetDirectoryName($sheetPart).Replace('\','/');$sheetFile=[IO.Path]::GetFileName($sheetPart);$sheetRelsPart=$sheetDir+'/_rels/'+$sheetFile+'.rels';$sheetRels=Get-YakuOoxmlRelationships -Archive $archive -RelationshipPart $sheetRelsPart;if($null -eq $sheetRels){$sheetRels=@{}}
            foreach($spec in @([pscustomobject]@{node='pageSetup';field='page-setup-printer-settings';expected='printerSettings'},[pscustomobject]@{node='legacyDrawingHF';field='header-footer-images';expected='vmlDrawing'})){
                $fieldKey=$prefix+[string]$spec.field;$node=$sheetXml.SelectSingleNode("//*[local-name()='"+[string]$spec.node+"']")
                if($null -eq $node){$fields[$fieldKey]='none';continue}
                $nodeRid=[string]$node.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships');$relationship=$sheetRels[$nodeRid]
                if($null -eq $relationship -or [string]$relationship.target_mode -eq 'External' -or [string]$relationship.type -notmatch ('/'+[regex]::Escape([string]$spec.expected)+'$')){$unknown.Add($fieldKey)|Out-Null;continue}
                $targetPart=Resolve-YakuOoxmlPartTarget -SourcePart $sheetPart -Target ([string]$relationship.target);$targetEntry=$archive.GetEntry($targetPart)
                if($null -eq $targetEntry){$unknown.Add($fieldKey)|Out-Null;continue}
                $record=[ordered]@{relationship_id=$nodeRid;relationship_type=[string]$relationship.type;target=$targetPart;content_sha256=(Get-YakuOoxmlPartSha256 -Entry $targetEntry)}
                if([string]$spec.field -eq 'header-footer-images'){
                    $targetDir=[IO.Path]::GetDirectoryName($targetPart).Replace('\','/');$targetFile=[IO.Path]::GetFileName($targetPart);$drawingRelsPart=$targetDir+'/_rels/'+$targetFile+'.rels';$drawingRels=Get-YakuOoxmlRelationships -Archive $archive -RelationshipPart $drawingRelsPart;$images=New-Object System.Collections.Generic.List[object];$imageReferenceIds=New-Object System.Collections.Generic.List[string]
                    $vmlStream=$null
                    try{$vmlStream=$targetEntry.Open();$vmlXml=New-Object Xml.XmlDocument;$vmlXml.Load($vmlStream);foreach($imageNode in @($vmlXml.SelectNodes("//*[local-name()='imagedata']"))){foreach($attribute in @($imageNode.Attributes)){if(([string]$attribute.LocalName -eq 'relid' -or ([string]$attribute.LocalName -eq 'id' -and [string]$attribute.NamespaceURI -match '/relationships$')) -and -not [string]::IsNullOrWhiteSpace([string]$attribute.Value)){$imageReferenceIds.Add([string]$attribute.Value)|Out-Null}}}}
                    catch{$unknown.Add($fieldKey)|Out-Null}
                    finally{if($vmlStream){$vmlStream.Dispose()}}
                    foreach($imageId in @($imageReferenceIds.ToArray()|Sort-Object -Unique)){$imageRel=$(if($null -ne $drawingRels){$drawingRels[$imageId]}else{$null});if($null -eq $imageRel -or [string]$imageRel.type -notmatch '/image$' -or [string]$imageRel.target_mode -eq 'External'){$unknown.Add($fieldKey)|Out-Null;continue};$imagePart=Resolve-YakuOoxmlPartTarget -SourcePart $targetPart -Target ([string]$imageRel.target);$imageEntry=$archive.GetEntry($imagePart);if($null -eq $imageEntry){$unknown.Add($fieldKey)|Out-Null;continue};$images.Add([pscustomobject]@{relationship_id=[string]$imageRel.id;relationship_type=[string]$imageRel.type;target=$imagePart;content_sha256=(Get-YakuOoxmlPartSha256 -Entry $imageEntry)})|Out-Null}
                    $record['image_references']=@($imageReferenceIds.ToArray()|Sort-Object -Unique);$record['images']=@($images.ToArray())
                }
                if(-not $unknown.Contains($fieldKey)){$fields[$fieldKey]=($record|ConvertTo-Json -Depth 6 -Compress)}
            }
        }
    }catch{$unknown.Add('ooxml:print-dependencies')|Out-Null}
    finally{if($archive){$archive.Dispose()}}
    return [pscustomobject]@{Fields=[pscustomobject]$fields;UnknownFields=@($unknown.ToArray())}
}

function Compare-YakuExcelPrintContractSnapshots {
    param([Parameter(Mandatory=$true)]$Expected,[Parameter(Mandatory=$true)]$Actual)
    $expectedFields=$Expected.Contract.fields;$actualFields=$Actual.Contract.fields;$keys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($name in @($expectedFields.PSObject.Properties.Name)+@($actualFields.PSObject.Properties.Name)+@($Expected.UnknownFields)+@($Actual.UnknownFields)){if(-not [string]::IsNullOrWhiteSpace([string]$name)){$null=$keys.Add([string]$name)}}
    $expectedUnknown=@{};foreach($name in @($Expected.UnknownFields)){$expectedUnknown[[string]$name]=$true};$actualUnknown=@{};foreach($name in @($Actual.UnknownFields)){$actualUnknown[[string]$name]=$true}
    $mismatches=New-Object System.Collections.Generic.List[string];$unknown=New-Object System.Collections.Generic.List[string]
    foreach($key in @($keys|Sort-Object)){$expectedProperty=$expectedFields.PSObject.Properties[$key];$actualProperty=$actualFields.PSObject.Properties[$key];if($expectedUnknown.ContainsKey($key) -or $actualUnknown.ContainsKey($key) -or $null -eq $expectedProperty -or $null -eq $actualProperty){$unknown.Add($key)|Out-Null;continue};$left=$expectedProperty.Value|ConvertTo-Json -Depth 10 -Compress;$right=$actualProperty.Value|ConvertTo-Json -Depth 10 -Compress;if($left -cne $right){$mismatches.Add($key)|Out-Null}}
    $status=$(if($mismatches.Count -gt 0){'violated'}elseif($unknown.Count -gt 0){'unverified'}else{'verified'});return [pscustomobject]@{status=$status;mismatched_fields=@($mismatches.ToArray());unknown_fields=@($unknown.ToArray())}
}

function Get-YakuCatRenderInputFingerprint {
    param([Parameter(Mandatory=$true)]$Project, [string]$ProfileId = 'source_faithful')
    $targets = (@($Project.Segments | ForEach-Object { [string]$_.SegmentId + ':' + (Get-YakuCatSourceIntegrityHash -Text ([string]$_.Translation)) }) -join '|')
    $publicationTargets = (@($Project.Segments | ForEach-Object {
        $resolved=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $_}else{[pscustomobject]@{TextHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$_.Translation));VariantId='';VariantRevision=0;VariantHash=''}})
        [string]$_.SegmentId+':'+[string]$resolved.TextHash+':'+[string]$resolved.VariantId+':'+[string]$resolved.VariantRevision+':'+[string]$resolved.VariantHash
    }) -join '|')
    $placementSetHash=$(try{[string]$Project.PlacementSetHash}catch{''})
    # revisionはjob開始時のCASへ使う。確認event等、成果物を変えないmutationで
    # PDFを即staleにしないよう、artifact fingerprintは内容依存だけで作る。
    return (Get-YakuCatSourceIntegrityHash -Text ('cat-render-v4|' + [string]$Project.ActiveSourceId + '|' + [string]$Project.SourceArtifactSha256 + '|' + $ProfileId + '|' + $placementSetHash + '|' + $targets + '|' + $publicationTargets))
}

function Get-YakuCatDraftWritebackCompleteness {
    <# PDF化の前に、PlacementPlanの全sliceがDRAFT Excelの所定セルへ実在するかを読む。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$DraftPath
    )
    $null=Sync-YakuCatPlacementPlans -Project $Project
    $items=New-Object System.Collections.Generic.List[object]
    $context=New-YakuExcelApplication;$workbook=$null
    try{
        $workbook=Open-YakuWorkbookWithManualCalc -Context $context -Path $DraftPath -ReadOnly $true
        foreach($plan in @($Project.PlacementPlans)){
            foreach($destination in @($plan.destinations)){
                $sheetName=[string]$destination.sheet;$address=[string]$destination.address;$actual='';$state='checked';$reason=''
                if([string]::IsNullOrWhiteSpace($sheetName) -or [string]::IsNullOrWhiteSpace($address)){$state='unmapped';$reason='destination_not_mapped'}
                else{
                    $sheet=$null;$range=$null
                    try{$sheet=$workbook.Worksheets.Item($sheetName);$range=$sheet.Range($address);$actual=[string]$range.Value2}
                    catch{$state='unmapped';$reason='destination_not_readable'}
                    finally{Release-YakuComObject $range;Release-YakuComObject $sheet}
                    if($state -eq 'checked' -and $actual -cne [string]$destination.text){$state='finding';$reason='written_text_mismatch'}
                }
                $items.Add([pscustomobject]@{
                    coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('writeback-coverage-v1|'+[string]$plan.placement_id+'|'+[string]$destination.block_id+'|'+$sheetName+'|'+$address))
                    placement_id=[string]$plan.placement_id;segment_id=[string]$plan.segment_id;block_id=[string]$destination.block_id
                    sheet=$sheetName;address=$address;state=$state;reason=$reason;expected_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$destination.text));actual_hash=(Get-YakuCatSourceIntegrityHash -Text $actual)
                })|Out-Null
            }
        }
    }finally{
        if($null -ne $context){Close-YakuExcelObjects -Workbook $workbook -Application $context.Application -Save:$false -OldCalculation $context.OldCalculation -OldCalculateBeforeSave $context.OldCalculateBeforeSave -OldScreenUpdating $context.OldScreenUpdating -OldEnableEvents $context.OldEnableEvents -OldDisplayStatusBar $context.OldDisplayStatusBar -OldFormatConditionsCalc $context.OldFormatConditionsCalc -OldBackgroundChecking $context.OldBackgroundChecking}
    }
    $rows=@($items.ToArray());$bad=@($rows|Where-Object{[string]$_.state -ne 'checked'})
    return [pscustomobject]@{
        contract_version='draft-writeback-completeness-v1';status=$(if($rows.Count -gt 0 -and $bad.Count -eq 0){'verified'}else{'violated'})
        target_count=$rows.Count;checked_count=@($rows|Where-Object{$_.state -eq 'checked'}).Count;items=$rows
    }
}

function Get-YakuGeneratedPdfStructuralSnapshot {
    <# 生成直後の空/破損成果物を、ブラウザへ公開する前に最小限fail-closedで弾く。 #>
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'CAT_RENDER_PDF_MISSING'}
    $length=[int64](Get-Item -LiteralPath $Path).Length
    if($length -lt 8 -or $length -gt 536870912){throw 'CAT_RENDER_PDF_SIZE_INVALID'}
    $stream=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $headerBytes=New-Object byte[] 8;$read=$stream.Read($headerBytes,0,$headerBytes.Length)
        $header=[Text.Encoding]::ASCII.GetString($headerBytes,0,$read)
        if(-not $header.StartsWith('%PDF-',[StringComparison]::Ordinal)){throw 'CAT_RENDER_PDF_SIGNATURE_INVALID'}
        $tailSize=[int][Math]::Min(4096,$length);$tailBytes=New-Object byte[] $tailSize;$null=$stream.Seek(-$tailSize,[IO.SeekOrigin]::End);$tailRead=$stream.Read($tailBytes,0,$tailBytes.Length)
        $tail=[Text.Encoding]::ASCII.GetString($tailBytes,0,$tailRead)
        if($tail -notmatch '%%EOF\s*$'){throw 'CAT_RENDER_PDF_EOF_INVALID'}
    }finally{if($stream){$stream.Dispose()}}
    $pageCount=0;$pageCountStatus='unverified'
    if($length -le 67108864){
        try{
            $bytes=[IO.File]::ReadAllBytes($Path);$ascii=[Text.Encoding]::ASCII.GetString($bytes)
            $pageCount=[regex]::Matches($ascii,'/Type\s*/Page(?!s)\b').Count
            if($pageCount -gt 0){$pageCountStatus='estimated'}
        }catch{$pageCount=0;$pageCountStatus='unverified'}
    }
    return [pscustomobject]@{status=$(if($pageCountStatus -eq 'estimated'){'structurally_verified'}else{'signature_verified'});size=$length;page_count_estimate=$pageCount;page_count_status=$pageCountStatus}
}

function New-YakuCatSourceFaithfulRender {
    <# 原本を変更せず、訳文入り一時copyをExcel自身でPDF化する。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowNull()]$Settings,
        [string]$RenderRoot = ''
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    if ([string]$Project.Source -ne 'file' -or [string]$Project.DocumentFormat -notin @('xlsx','xlsm')) { throw 'CAT_RENDER_EXCEL_REQUIRED' }
    if ([string]::IsNullOrWhiteSpace([string]$Project.ActiveSourceId)) { throw 'CAT_RENDER_SOURCE_SNAPSHOT_REQUIRED' }
    if (-not (Test-Path -LiteralPath ([string]$Project.Path) -PathType Leaf)) { throw 'CAT_RENDER_SOURCE_MISSING' }
    $null=Sync-YakuCatPlacementPlans -Project $Project
    $inputFingerprint = Get-YakuCatRenderInputFingerprint -Project $Project
    $renderId = [guid]::NewGuid().ToString('N')
    if ([string]::IsNullOrWhiteSpace($RenderRoot)) { $RenderRoot = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) ([string]$Project.Id)) 'renders' }
    $renderDir = Join-Path $RenderRoot $renderId
    $null = New-Item -ItemType Directory -Path $renderDir -Force
    $sourceInputPath = Join-Path $renderDir ('source-input' + [IO.Path]::GetExtension([string]$Project.Path))
    # 描画ディレクトリの下書きは提出物ではなく中間成果物である。名前を利用者の
    # ファイル名から作ると、日本語名の原本（本アプリの通常入力）で manifest の
    # output_xlsx が Resolve-YakuCatRenderPdf の文字種検査に落ちる。同じ
    # ディレクトリの source-input / preview.pdf / source-preview.pdf と同様、
    # 固定のASCII名にする。利用者に渡す DRAFT_ 名は Get-YakuCatDraftOutputPath が
    # 別に作るので、見える名前は変わらない。
    $draftPath = Join-Path $renderDir ('draft.' + [string]$Project.DocumentFormat)
    $pdfPath = Join-Path $renderDir 'preview.pdf'
    $sourcePdfPath = Join-Path $renderDir 'source-preview.pdf'
    try {
        $expectedSourceHash=[string]$Project.SourceArtifactSha256
        if($expectedSourceHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'CAT_RENDER_SOURCE_HASH_REQUIRED'}
        $actualSourceHash=Get-YakuFileSha256Hex -Path ([string]$Project.Path)
        if($actualSourceHash -cne $expectedSourceHash.ToLowerInvariant()){throw 'CAT_RENDER_SOURCE_ARTIFACT_CONFLICT'}
        Copy-Item -LiteralPath ([string]$Project.Path) -Destination $sourceInputPath
        $stagedSourceHash=Get-YakuFileSha256Hex -Path $sourceInputPath
        if($stagedSourceHash -cne $actualSourceHash){throw 'CAT_RENDER_SOURCE_COPY_INTEGRITY_FAILED'}
        $renderProject=Copy-YakuCatProjectForMutation -Project $Project
        $renderProject.Path=$sourceInputPath
        $sourcePrint = Get-YakuExcelPrintContractSnapshot -Path $sourceInputPath
        $warnings = New-Object System.Collections.Generic.List[object]
        $draft = Export-YakuCatProject -Project $renderProject -OutputPath $draftPath -Settings $Settings -Warnings $warnings
        $publishedDraft = [string]$draft.OutputPath
        if (-not (Test-Path -LiteralPath $publishedDraft -PathType Leaf)) { throw 'CAT_RENDER_DRAFT_MISSING' }
        # 公開名は Get-YakuAvailableOutputPath が決めるので、こちらの希望どおりとは
        # 限らない（衝突で (2) が付く）。manifest へ書く前に、Resolve-YakuCatRenderPdf が
        # 使うのと同じ規則でここで検査する。作った名前を自分の検証で弾く事故を、
        # 解決時ではなく作った側で落とす。
        $publishedDraftName = [IO.Path]::GetFileName($publishedDraft)
        if ($publishedDraftName -notmatch '^[A-Za-z0-9_.-]+\.(xlsx|xlsm)$' -or (Join-Path $renderDir $publishedDraftName) -cne $publishedDraft) { throw 'CAT_RENDER_DRAFT_NAME_INVALID' }
        $writebackCompleteness=Get-YakuCatDraftWritebackCompleteness -Project $Project -DraftPath $publishedDraft
        if([string]$writebackCompleteness.status -ne 'verified'){throw 'CAT_RENDER_WRITEBACK_COMPLETENESS_VIOLATED'}
        $draftPrint = Get-YakuExcelPrintContractSnapshot -Path $publishedDraft
        $printConformance=Compare-YakuExcelPrintContractSnapshots -Expected $sourcePrint -Actual $draftPrint
        if ([string]$printConformance.status -eq 'violated') { throw ('CAT_RENDER_PRINT_CONFORMANCE_VIOLATED: '+(@($printConformance.mismatched_fields)-join ', ')) }
        $context = New-YakuExcelApplication; $workbook = $null
        try {
            $workbook = Open-YakuWorkbookWithManualCalc -Context $context -Path $publishedDraft -ReadOnly $true
            $workbook.ExportAsFixedFormat(0, $pdfPath, 0, $true, $false, [Type]::Missing, [Type]::Missing, $false, [Type]::Missing)
        } finally {
            if ($null -ne $context) {
                Close-YakuExcelObjects -Workbook $workbook -Application $context.Application -Save:$false `
                    -OldCalculation $context.OldCalculation -OldCalculateBeforeSave $context.OldCalculateBeforeSave `
                    -OldScreenUpdating $context.OldScreenUpdating -OldEnableEvents $context.OldEnableEvents `
                    -OldDisplayStatusBar $context.OldDisplayStatusBar -OldFormatConditionsCalc $context.OldFormatConditionsCalc `
                    -OldBackgroundChecking $context.OldBackgroundChecking
            }
        }
        $pdfStructure=Get-YakuGeneratedPdfStructuralSnapshot -Path $pdfPath
        $sourceContext = New-YakuExcelApplication; $sourceWorkbook = $null
        try {
            $sourceWorkbook = Open-YakuWorkbookWithManualCalc -Context $sourceContext -Path $sourceInputPath -ReadOnly $true
            $sourceWorkbook.ExportAsFixedFormat(0, $sourcePdfPath, 0, $true, $false, [Type]::Missing, [Type]::Missing, $false, [Type]::Missing)
        } finally {
            if ($null -ne $sourceContext) {
                Close-YakuExcelObjects -Workbook $sourceWorkbook -Application $sourceContext.Application -Save:$false `
                    -OldCalculation $sourceContext.OldCalculation -OldCalculateBeforeSave $sourceContext.OldCalculateBeforeSave `
                    -OldScreenUpdating $sourceContext.OldScreenUpdating -OldEnableEvents $sourceContext.OldEnableEvents `
                    -OldDisplayStatusBar $sourceContext.OldDisplayStatusBar -OldFormatConditionsCalc $sourceContext.OldFormatConditionsCalc `
                    -OldBackgroundChecking $sourceContext.OldBackgroundChecking
            }
        }
        $sourcePdfStructure=Get-YakuGeneratedPdfStructuralSnapshot -Path $sourcePdfPath
        if((Get-YakuFileSha256Hex -Path ([string]$Project.Path)) -cne $actualSourceHash){throw 'CAT_RENDER_SOURCE_CHANGED_DURING_RENDER'}
        $unknown = @($printConformance.unknown_fields)
        $status = [string]$printConformance.status
        $manifest = [ordered]@{
            schema_version=1; render_id=$renderId; project_id=[string]$Project.Id; project_revision=[int]$Project.Revision
            source_snapshot_id=[string]$Project.ActiveSourceId; profile_id='source_faithful'; input_fingerprint=$inputFingerprint
            measured_source_sha256=$actualSourceHash; staged_source_sha256=$stagedSourceHash
            expected_print_fingerprint=[string]$sourcePrint.Fingerprint; actual_print_fingerprint=[string]$draftPrint.Fingerprint
            print_conformance_status=$status; unknown_print_fields=$unknown; mismatched_print_fields=@($printConformance.mismatched_fields); origin='generated'
            output_xlsx=[IO.Path]::GetFileName($publishedDraft); output_xlsx_sha256=(Get-YakuFileSha256Hex -Path $publishedDraft)
            canonical_pdf=[IO.Path]::GetFileName($pdfPath); canonical_pdf_sha256=(Get-YakuFileSha256Hex -Path $pdfPath)
            pdf_structure_status=[string]$pdfStructure.status;pdf_size=[int64]$pdfStructure.size;pdf_page_count_estimate=[int]$pdfStructure.page_count_estimate;pdf_page_count_status=[string]$pdfStructure.page_count_status
            source_pdf=[IO.Path]::GetFileName($sourcePdfPath); source_pdf_sha256=(Get-YakuFileSha256Hex -Path $sourcePdfPath)
            source_pdf_structure_status=[string]$sourcePdfStructure.status;source_pdf_size=[int64]$sourcePdfStructure.size;source_pdf_page_count_estimate=[int]$sourcePdfStructure.page_count_estimate;source_pdf_page_count_status=[string]$sourcePdfStructure.page_count_status
            writeback_completeness=$writebackCompleteness
            pdf_text_completeness_status='not_checked'; pdf_text_extractor_contract=''
            created_at=(Get-Date).ToString('o'); warnings=@($warnings.ToArray())
        }
        Write-YakuJsonAtomic -Path (Join-Path $renderDir 'render.json') -Value $manifest -Depth 10
        return [pscustomobject]@{ RenderId=$renderId; RenderDir=$renderDir; PdfPath=$pdfPath; DraftPath=$publishedDraft; Manifest=[pscustomobject]$manifest }
    } catch {
        if (Test-Path -LiteralPath $renderDir -PathType Container) { Remove-Item -LiteralPath $renderDir -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Resolve-YakuCatRenderPdf {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$RenderId,
        [ValidateSet('target','source')][string]$Artifact = 'target'
    )
    if ($ProjectId -notmatch '^[a-f0-9]{32}$' -or $RenderId -notmatch '^[a-f0-9]{32}$') { throw 'CAT_RENDER_ID_INVALID' }
    $store = [IO.Path]::GetFullPath((Get-YakuCatProjectStoreDir)).TrimEnd('\')
    $renderDir = [IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $store $ProjectId) 'renders') $RenderId))
    if (-not $renderDir.StartsWith($store + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_RENDER_PATH_INVALID' }
    $manifestPath = Join-Path $renderDir 'render.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'CAT_RENDER_NOT_FOUND' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.project_id -ne $ProjectId -or [string]$manifest.render_id -ne $RenderId) { throw 'CAT_RENDER_MANIFEST_INVALID' }
    $pdfName = $(if($Artifact -eq 'source'){[string]$manifest.source_pdf}else{[string]$manifest.canonical_pdf})
    if ($pdfName -notmatch '^[A-Za-z0-9_.-]+\.pdf$') { throw 'CAT_RENDER_PATH_INVALID' }
    $pdfPath = [IO.Path]::GetFullPath((Join-Path $renderDir $pdfName))
    if (-not $pdfPath.StartsWith($renderDir + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) { throw 'CAT_RENDER_NOT_FOUND' }
    $actualHash = Get-YakuFileSha256Hex -Path $pdfPath
    $expectedPdfHash=$(if($Artifact -eq 'source'){[string]$manifest.source_pdf_sha256}else{[string]$manifest.canonical_pdf_sha256})
    if ($actualHash -ne $expectedPdfHash) { throw 'CAT_RENDER_INTEGRITY_FAILED' }
    $draftName=[string]$manifest.output_xlsx
    if($draftName -notmatch '^[A-Za-z0-9_.-]+\.(xlsx|xlsm)$'){throw 'CAT_RENDER_PATH_INVALID'}
    $draftPath=[IO.Path]::GetFullPath((Join-Path $renderDir $draftName))
    if(-not $draftPath.StartsWith($renderDir+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $draftPath -PathType Leaf)){throw 'CAT_RENDER_DRAFT_NOT_FOUND'}
    if((Get-YakuFileSha256Hex -Path $draftPath) -ne [string]$manifest.output_xlsx_sha256){throw 'CAT_RENDER_DRAFT_INTEGRITY_FAILED'}
    return [pscustomobject]@{ Path=$pdfPath; DraftPath=$draftPath; Manifest=$manifest }
}
