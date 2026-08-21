<# V91.89: Ctrl+H の直前1回だけを、generation に保存した状態から戻す回帰。 #>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9189Root = Split-Path -Parent $PSScriptRoot
$YakuT9189Src = Join-Path $YakuT9189Root 'src'
$script:T9189Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9189 { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message)}else{Write-Host ('  NG   '+$Message);[void]$script:T9189Failures.Add($Message)} }
function Invoke-T9189Replace {
    param($Project,[string]$Find,[string]$Replace)
    $mutation = { param($candidate,$innerFind,$innerReplace) Invoke-YakuCatSearchReplace -Project $candidate -Indexes @(0,1) -Find $innerFind -Replace $innerReplace }
    return (Invoke-YakuCatProjectMutation -ProjectId ([string]$Project.Id) -ExpectedRevision ([int]$Project.Revision) -Mutation $mutation -Arguments @($Find,$Replace) -Action replace -NoCommitWhenNoMutation)
}

Write-Host 'Test-YakuV9189SearchReplaceUndo'
. (Join-Path $YakuT9189Src 'SrcModules.ps1')
foreach($YakuT9189File in $script:YakuSrcModuleFiles){ . (Join-Path $YakuT9189Src $YakuT9189File) }
$YakuT9189Unmeasured = 3
$YakuT9189Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $YakuT9189Node) { Write-Host 'UNMEASURED: node is unavailable.'; exit $YakuT9189Unmeasured }
$YakuT9189NodeExe = [string]$YakuT9189Node.Source
$YakuT9189ProbeDir = (Join-Path $YakuT9189Root 'tools\cat-screen').Replace('\','/')
$null = & $YakuT9189NodeExe -e ("try{require.resolve('playwright',{paths:['"+$YakuT9189ProbeDir+"']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host 'UNMEASURED: Playwright is unavailable.'; exit $YakuT9189Unmeasured }
$YakuT9189ChromiumPath = & $YakuT9189NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['"+$YakuT9189ProbeDir+"']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
$YakuT9189ChromiumExit = $LASTEXITCODE
if ($YakuT9189ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$YakuT9189ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$YakuT9189ChromiumPath) -PathType Leaf)) { Write-Host 'UNMEASURED: Playwright Chromium is unavailable.'; exit $YakuT9189Unmeasured }

$YakuT9189Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-undo-'+[guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $YakuT9189Temp -Force
$YakuT9189OldData = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $YakuT9189Temp 'user-data'
$script:YakuT9189Store = Join-Path $YakuT9189Temp 'cat-store'
function Get-YakuCatProjectStoreDir { return $script:YakuT9189Store }

try {
    $settings = Read-YakuSettings -Root $YakuT9189Root
    $project = New-YakuCatTextProject -Root $YakuT9189Root -Text "source one`nsource two`nsource untouched" -Settings $settings -Direction to_en -Register:$false
    $project.Segments = @($project.Segments | Select-Object -First 3)
    if (@($project.Segments).Count -lt 3) {
        $project.Segments = @(
            [pscustomobject]@{Text='source one';Translation='alpha first';Kind='text';Location='1'},
            [pscustomobject]@{Text='source two';Translation='alpha second';Kind='text';Location='2'},
            [pscustomobject]@{Text='source untouched';Translation='untouched';Kind='text';Location='3'}
        )
    }
    $null = Initialize-YakuCatProjectState -Project $project
    $segments = @($project.Segments)
    foreach($segment in $segments){foreach($name in @('Translation','MaskedTranslation','Origin')){if(-not($segment.PSObject.Properties.Name -contains $name)){$segment|Add-Member -NotePropertyName $name -NotePropertyValue '' -Force}}}
    $segments[0].Translation='alpha first';$segments[0].MaskedTranslation='masked-before';$segments[0].Origin='copilot';$segments[0].State='reviewed';$segments[0].Confirmed=$true
    $segments[0].QcStatus='failed';$segments[0].QcSourceRevision=[int]$segments[0].SourceRevision;$segments[0].QcSourceHash=[string]$segments[0].SourceIntegrityHash;$segments[0].QcTargetHash='pre-qc-target';$segments[0].QcContractVersion='fixture-v1';$segments[0].QcTerminologyHash='fixture-terms';$segments[0].QcFindings=@([pscustomobject]@{Code='fixture-qc';Severity='error'})
    $segments[0].TmRegistered=$true;$segments[0].TmRegistrationEventId='fixture-tm';$segments[0].ReferenceUsage=[pscustomobject]@{reference_id='fixture-ref';edited_after_insert=$false};$segments[0].ReferenceEvents=@([pscustomobject]@{action='inserted';target_hash='fixture-target';edited_after_insert=$false})
    $segments[1].Translation='alpha second';$segments[1].MaskedTranslation='second-mask';$segments[1].Origin='manual';$segments[1].State='human_edited';$segments[1].Confirmed=$false;$segments[1].QcStatus='not_run'
    $unaffectedBefore = Get-YakuCatBulkReplaceUndoSegmentState -Segment $segments[2]
    $null = Commit-YakuNewCatProject -Project $project
    $project = Get-YakuCatProject -Id ([string]$project.Id)
    $firstBefore = Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[0]
    Assert-T9189 ([string]$firstBefore.reference_usage.reference_id -eq 'fixture-ref' -and @($firstBefore.reference_events).Count -eq 1) 'fixture reaches the committed pre-replace segment'

    $first = Invoke-T9189Replace -Project $project -Find 'alpha' -Replace 'beta';$project=$first.Project
    Assert-T9189 ($null -ne $project.PendingBulkReplaceUndo -and [int]$project.PendingBulkReplaceUndo.affected_count -eq 2) 'replace creates exactly one pending undo for two rows'
    Assert-T9189 ([string]$project.PendingBulkReplaceUndo.rows[0].before.reference_usage.reference_id -eq 'fixture-ref' -and -not [bool]$project.PendingBulkReplaceUndo.rows[0].before.reference_usage.edited_after_insert) 'undo snapshot retains the pre-replace reference usage'
    $noOpRevision=[int]$project.Revision;$noOpTicket=$project.PendingBulkReplaceUndo|ConvertTo-Json -Depth 28 -Compress;$noOpState=Get-YakuCatBulkReplaceUndoStateHash -State (Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[0]);$noOpEvents=@($project.ReviewEvents).Count
    $noOp=Invoke-T9189Replace -Project $project -Find 'not-in-any-translation' -Replace 'ignored';$project=$noOp.Project
    Assert-T9189 ([int]$noOp.Result.Replaced -eq 0 -and [int]$noOp.Result.Occurrences -eq 0 -and [int]$noOp.Result.Unconfirmed -eq 0 -and [int]$noOp.Result.ScannedRows -eq 2 -and [int]$project.Revision -eq $noOpRevision -and ($project.PendingBulkReplaceUndo|ConvertTo-Json -Depth 28 -Compress) -eq $noOpTicket -and (Get-YakuCatBulkReplaceUndoStateHash -State (Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[0])) -eq $noOpState -and @($project.ReviewEvents).Count -eq $noOpEvents) 'no-op replace preserves project state, audit, and the existing undo ticket'
    Assert-T9189 ([string]$project.Segments[0].Translation -eq 'beta first' -and -not [bool]$project.Segments[0].Confirmed -and [string]$project.Segments[0].QcStatus -eq 'not_run') 'replace uses the normal translation/QC reset path'
    Assert-T9189 ((Get-YakuCatBulkReplaceUndoStateHash -State (Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[2])) -eq (Get-YakuCatBulkReplaceUndoStateHash -State $unaffectedBefore) -and [string]$project.Segments[2].Text -eq 'source untouched') 'unaffected row and every source text remain unchanged'
    $eventsAfterReplace=@($project.ReviewEvents);Assert-T9189 (@($eventsAfterReplace|Where-Object{$_.action -eq 'search_replaced'}).Count -eq 2) 'original replace decision events are retained'

    $undoMutation={param($candidate) Undo-YakuCatSearchReplace -Project $candidate}
    $undo=Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision ([int]$project.Revision) -Mutation $undoMutation -Action replace-undo;$project=$undo.Project
    Assert-T9189 ([int]$undo.Result.Restored -eq 2 -and $null -eq $project.PendingBulkReplaceUndo) 'undo restores both rows and consumes its one opportunity'
    $firstAfter = Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[0]
    Assert-T9189 ([string]$firstAfter.translation -eq [string]$firstBefore.translation -and [string]$firstAfter.masked_translation -eq [string]$firstBefore.masked_translation -and [string]$firstAfter.origin -eq [string]$firstBefore.origin -and [string]$firstAfter.state -eq [string]$firstBefore.state -and [bool]$firstAfter.confirmed -eq [bool]$firstBefore.confirmed) 'confirmed row translation, mask, origin, and state restore exactly'
    Assert-T9189 ([string]$firstAfter.qc_status -eq [string]$firstBefore.qc_status -and [string]$firstAfter.qc_target_hash -eq [string]$firstBefore.qc_target_hash -and [string]$firstAfter.qc_contract_version -eq [string]$firstBefore.qc_contract_version -and (($firstAfter.qc_findings|ConvertTo-Json -Compress) -eq ($firstBefore.qc_findings|ConvertTo-Json -Compress))) 'QC state, findings, and fingerprint restore exactly'
    Assert-T9189 ([bool]$firstAfter.tm_registered -eq [bool]$firstBefore.tm_registered -and [string]$firstAfter.tm_registration_event_id -eq [string]$firstBefore.tm_registration_event_id) 'translation-memory registration state restores exactly'
    Assert-T9189 ([string]$firstAfter.reference_usage.reference_id -eq [string]$firstBefore.reference_usage.reference_id -and [bool]$firstAfter.reference_usage.edited_after_insert -eq [bool]$firstBefore.reference_usage.edited_after_insert) 'reference usage restores exactly'
    Assert-T9189 (@($firstAfter.reference_events).Count -eq @($firstBefore.reference_events).Count -and [string]$firstAfter.reference_events[0].action -eq [string]$firstBefore.reference_events[0].action -and [string]$firstAfter.reference_events[0].target_hash -eq [string]$firstBefore.reference_events[0].target_hash -and [bool]$firstAfter.reference_events[0].edited_after_insert -eq [bool]$firstBefore.reference_events[0].edited_after_insert) 'reference event edit state restores exactly'
    Assert-T9189 (@($project.ReviewEvents|Where-Object{$_.action -eq 'search_replaced'}).Count -eq 2 -and @($project.ReviewEvents|Where-Object{$_.action -eq 'search_replace_undone'}).Count -eq 2) 'undo appends audit events without erasing replace events'

    $one=Invoke-T9189Replace -Project $project -Find 'alpha' -Replace 'beta';$project=$one.Project
    $two=Invoke-T9189Replace -Project $project -Find 'beta' -Replace 'gamma';$project=$two.Project
    $undo2=Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision ([int]$project.Revision) -Mutation $undoMutation -Action replace-undo;$project=$undo2.Project
    Assert-T9189 ([string]$project.Segments[0].Translation -eq 'beta first' -and [string]$project.Segments[1].Translation -eq 'beta second') 'a second replace supersedes the first undo opportunity'

    $third=Invoke-T9189Replace -Project $project -Find 'beta' -Replace 'delta';$project=$third.Project
    $failed=$false;try{Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision ([int]$project.Revision) -Mutation {param($candidate)throw 'CAT_TEST_FORCED_FAILURE'} -Action segment|Out-Null}catch{$failed=$_.Exception.Message -match 'CAT_TEST_FORCED_FAILURE'}
    Assert-T9189 ($failed -and $null -ne (Get-YakuCatProject -Id ([string]$project.Id)).PendingBulkReplaceUndo) 'failed later mutation preserves the committed undo'
    $project=Get-YakuCatProject -Id ([string]$project.Id)
    $later={param($candidate)Set-YakuCatSegmentTranslation -Project $candidate -Index 2 -Text 'later change'|Out-Null}
    $laterCommit=Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision ([int]$project.Revision) -Mutation $later -Action segment;$project=$laterCommit.Project
    Assert-T9189 ($null -eq $project.PendingBulkReplaceUndo) 'later successful mutation invalidates undo'
    $stale=$false;try{Invoke-YakuCatProjectMutation -ProjectId ([string]$project.Id) -ExpectedRevision ([int]$project.Revision-1) -Mutation {param($candidate)$null} -Action replace-undo|Out-Null}catch{$stale=$_.Exception.Message -match '^CAT_PROJECT_REVISION_CONFLICT'}
    Assert-T9189 $stale 'stale expected revision fails closed before undo mutation'

    $restartBefore=Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[0]
    $persist=Invoke-T9189Replace -Project $project -Find 'delta' -Replace 'epsilon';$project=$persist.Project;$id=[string]$project.Id
    Remove-YakuCatProject -Id $id;$restored=Restore-YakuCatProject -Id $id
    Assert-T9189 ($null -ne $restored.PendingBulkReplaceUndo -and [bool]((ConvertTo-YakuCatProjectJson -Project $restored|ConvertFrom-Json).bulk_replace_undo.available)) 'generation save/restore retains the pending undo and view availability'
    $restoredUndo=Invoke-YakuCatProjectMutation -ProjectId ([string]$restored.Id) -ExpectedRevision ([int]$restored.Revision) -Mutation $undoMutation -Action replace-undo;$project=$restoredUndo.Project
    Assert-T9189 ([int]$restoredUndo.Result.Restored -eq 2 -and [string]$project.Segments[0].Translation -eq 'delta first' -and (Get-YakuCatBulkReplaceUndoStateHash -State (Get-YakuCatBulkReplaceUndoSegmentState -Segment $project.Segments[0])) -eq (Get-YakuCatBulkReplaceUndoStateHash -State $restartBefore)) 'restored project can execute undo and recover the exact pre-replace state'
    $recreated=Invoke-T9189Replace -Project $project -Find 'delta' -Replace 'epsilon';$project=$recreated.Project;$id=[string]$project.Id
    $manifest=Get-Content -LiteralPath (Join-Path (Join-Path $script:YakuT9189Store $id) 'project.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $undoPath=Join-Path (Join-Path (Join-Path (Join-Path $script:YakuT9189Store $id) 'generations') ([string]$manifest.generation_id)) 'bulk-replace-undo.json'
    $undoOriginal=[IO.File]::ReadAllText($undoPath);[IO.File]::WriteAllText($undoPath,'{}',(New-Object Text.UTF8Encoding($false)));Remove-YakuCatProject -Id $id
    $corrupt=$false;try{Restore-YakuCatProject -Id $id|Out-Null}catch{$corrupt=$_.Exception.Message -match '^CAT_PROJECT_SNAPSHOT_INCOMPLETE'}
    Assert-T9189 $corrupt 'corrupt undo artifact fails closed through manifest verification'
    [IO.File]::WriteAllText($undoPath,$undoOriginal,(New-Object Text.UTF8Encoding($false)));Remove-Item -LiteralPath $undoPath -Force
    $missing=$false;try{Restore-YakuCatProject -Id $id|Out-Null}catch{$missing=$_.Exception.Message -match '^CAT_PROJECT_SNAPSHOT_INCOMPLETE'}
    Assert-T9189 $missing 'missing undo artifact fails closed through manifest verification'

    $many=[pscustomobject]@{Id=([guid]::NewGuid().ToString('N'));Segments=@();Blocks=@();ReviewEvents=@();Source='text';Direction='to_en';Revision=0}
    $manyRows=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt 513;$i++){[void]$manyRows.Add([pscustomobject]@{Text=('source '+$i);Translation=('alpha '+$i);Kind='text';Location=[string]$i})}
    $many.Segments=$manyRows.ToArray();$null=Initialize-YakuCatProjectState -Project $many;$overCap=$false
    try{Invoke-YakuCatSearchReplace -Project $many -Indexes (0..512) -Find 'alpha' -Replace 'beta'|Out-Null}catch{$overCap=$_.Exception.Message -match '^CAT_REPLACE_UNDO_SNAPSHOT_TOO_LARGE'}
    Assert-T9189 ($overCap -and [string]$many.Segments[0].Translation -eq 'alpha 0') 'over-cap replace fails before any partial change'

    # 実際の cat.html/cat.js を Chromium で開く。backend は上で直接検証した同じ
    # JSON 契約を返す小さな HTTP stub で、画面が client-side の古い訳を戻さず
    # replace-undo を送って、返った状態だけを描画することをここで測る。
    $browserBefore = [ordered]@{
        id='undo-screen-9189';revision=31;source='text';lifecycle='saved';file_name='undo.txt';document_format='text';direction='to_en';total=2;translated=2;remaining=0;joined=0;confirmed=0;unconfirmed=2;source_chars=20;remaining_chars=0;untranslated=0;draft=2;export_blocked=$false;translation_list_eligibility=$true;excel_draft_eligibility=$false;word_draft_eligibility=$false;tm_pending=0;bulk_replace_undo=[ordered]@{available=$true;affected_count=2}
        segments=@([ordered]@{index=0;segment_id='undo-a';source='source one';translation='beta first';origin='manual';state='human_edited';qc_status='not_run';confirmed=$false;kind='text';location='1';qc_findings=@();qc_preview=@()},[ordered]@{index=1;segment_id='undo-b';source='source two';translation='beta second';origin='manual';state='human_edited';qc_status='not_run';confirmed=$false;kind='text';location='2';qc_findings=@();qc_preview=@()})
    }
    $browserAfter = $browserBefore | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $browserAfter.revision=32;$browserAfter.segments[0].translation='alpha first';$browserAfter.segments[1].translation='alpha second';$browserAfter.bulk_replace_undo=[pscustomobject]@{available=$false;affected_count=0};$browserAfter|Add-Member -NotePropertyName replace_undo_restored -NotePropertyValue 2 -Force
    $browserBeforePath=Join-Path $YakuT9189Temp 'undo-before.json';$browserAfterPath=Join-Path $YakuT9189Temp 'undo-after.json';$browserDriverPath=Join-Path $YakuT9189Temp 'undo-screen.js';$browserResultPath=Join-Path $YakuT9189Temp 'undo-screen-result.json'
    [IO.File]::WriteAllText($browserBeforePath,($browserBefore|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($browserAfterPath,($browserAfter|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)))
    $browserDriver = @'
'use strict';
const fs=require('fs'),http=require('http'),path=require('path');
const {chromium}=require(require.resolve('playwright',{paths:[process.cwd()]}));
const www=process.argv[2],before=fs.readFileSync(process.argv[3],'utf8'),after=fs.readFileSync(process.argv[4],'utf8'),outPath=process.argv[5];
const result={errors:[],console:[],undoRequests:[],visibleBefore:false,labelBefore:'',visibleAfter:false,translationsAfter:[]};
const types={'.js':'application/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.html':'text/html; charset=utf-8'};
const server=http.createServer((req,res)=>{const url=new URL(req.url,'http://127.0.0.1');if(url.pathname==='/'||url.pathname==='/cat'){let html=fs.readFileSync(path.join(www,'cat.html'),'utf8');html=html.replace(/__YAKU_SESSION_TOKEN__/g,'undo-test-token').replace(/__YAKU_MAX_UPLOAD_BYTES__/g,'52428800').replace(/__YAKU_MAX_BATCH_CHARS__/g,'4000').replace(/__YAKU_AMOUNT_NOTATION__/g,'oku').replace(/__YAKU_OUTPUT_FONT__/g,'Arial').replace(/__YAKU_OUTPUT_FONT_JP__/g,'MS P\u30b4\u30b7\u30c3\u30af').replace(/__YAKU_TOUR__/g,'0').replace(/__YAKU_IMPORT__/g,'0').replace(/__YAKU_VIEW__/g,'');res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(html);return;}if(url.pathname.startsWith('/assets/')){const f=path.join(www,url.pathname.replace(/^\//,''));if(fs.existsSync(f)){res.writeHead(200,{'Content-Type':types[path.extname(f)]||'application/octet-stream'});res.end(fs.readFileSync(f));return;}res.writeHead(404);res.end();return;}let raw='';req.on('data',c=>raw+=c);req.on('end',()=>{let body={};try{body=JSON.parse(raw||'{}')}catch(_){}let response={};if(url.pathname==='/api/cat/resume')response=JSON.parse(before);else if(url.pathname==='/api/cat/replace-undo'){result.undoRequests.push(body);response=JSON.parse(after);}else if(url.pathname==='/api/ready-state')response={canTranslate:true,label:'ready',class:'ok'};else if(url.pathname==='/api/cat/recent')response={projects:[]};else if(url.pathname==='/api/cat/project-presence')response={ok:true};res.writeHead(200,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(response));});});
(async()=>{let browser;try{await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch();const page=await browser.newPage({viewport:{width:1912,height:987}});page.on('pageerror',e=>result.errors.push(String(e.message||e)));page.on('console',m=>{if(m.type()==='error')result.console.push(m.text());});page.on('dialog',d=>d.accept());await page.goto('http://127.0.0.1:'+server.address().port+'/cat?project=undo-screen-9189',{waitUntil:'domcontentloaded'});await page.waitForSelector('#cat-replace-undo',{state:'visible',timeout:20000});result.visibleBefore=await page.locator('#cat-replace-undo').isVisible();result.labelBefore=await page.locator('#cat-replace-undo').textContent();await page.locator('#cat-replace-undo').click();await page.waitForFunction(()=>!document.getElementById('cat-replace-undo'),null,{timeout:20000});result.visibleAfter=await page.locator('#cat-replace-undo').count()>0;result.translationsAfter=await page.locator('textarea[data-cat-input]').evaluateAll(nodes=>nodes.map(n=>n.value));}catch(e){result.errors.push(String(e&&e.stack||e));process.exitCode=1;}finally{try{if(browser)await browser.close();}catch(_){}await new Promise(r=>server.close(r));fs.writeFileSync(outPath,JSON.stringify(result));}})();
'@
    [IO.File]::WriteAllText($browserDriverPath,$browserDriver,(New-Object Text.UTF8Encoding($false)))
    & $YakuT9189NodeExe $browserDriverPath (Join-Path $YakuT9189Root 'www') $browserBeforePath $browserAfterPath $browserResultPath
    $browserExit=$LASTEXITCODE;$browserResult=$null;if(Test-Path -LiteralPath $browserResultPath){$browserResult=[IO.File]::ReadAllText($browserResultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json}
    if($null -ne $browserResult){foreach($browserError in @($browserResult.errors)){Write-Host ('  Chromium error: '+[string]$browserError)};foreach($browserConsole in @($browserResult.console)){Write-Host ('  Chromium console: '+[string]$browserConsole)}}
    Assert-T9189 ($browserExit -eq 0 -and $null -ne $browserResult -and @($browserResult.errors).Count -eq 0 -and @($browserResult.console).Count -eq 0) 'Chromium CAT screen completes without page or console errors'
    Assert-T9189 ($null -ne $browserResult -and [bool]$browserResult.visibleBefore -and [string]$browserResult.labelBefore -match '直前の一括置換を元に戻す（2行）') 'Chromium visibly shows the Japanese one-step undo control and count'
    Assert-T9189 ($null -ne $browserResult -and @($browserResult.undoRequests).Count -eq 1 -and [int]$browserResult.undoRequests[0].expected_revision -eq 31 -and [string]$browserResult.undoRequests[0].id -eq 'undo-screen-9189') 'click sends only replace-undo with the current CAS scope'
    Assert-T9189 ($null -ne $browserResult -and -not [bool]$browserResult.visibleAfter -and ((@($browserResult.translationsAfter) -join '|') -eq 'alpha first|alpha second')) 'Chromium click restores returned translations and removes the undo control'
} finally {
    $env:YAKULINGO_DATA_DIR=$YakuT9189OldData
    if(Test-Path -LiteralPath $YakuT9189Temp){Remove-Item -LiteralPath $YakuT9189Temp -Recurse -Force}
}

Write-Host ''
if($script:T9189Failures.Count -eq 0){Write-Host 'PASS Test-YakuV9189SearchReplaceUndo';exit 0}
Write-Host ('FAIL '+$script:T9189Failures.Count+' assertion(s)');foreach($YakuT9189Failure in $script:T9189Failures){Write-Host ('  - '+$YakuT9189Failure)};exit 1
