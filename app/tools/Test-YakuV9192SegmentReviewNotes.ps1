<# V91.92: durable per-segment local review notes. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$N9192Root = Split-Path -Parent $PSScriptRoot
$N9192Src = Join-Path $N9192Root 'src'
$script:N9192Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9192 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9192Failures.Add($Message) }
}

function Expect-N9192Code {
    param([scriptblock]$Action, [string]$Code, [string]$Message)
    $matched = $false
    try { & $Action | Out-Null }
    catch { $matched = [string]$_.Exception.Message -match ('^' + [regex]::Escape($Code)) }
    Assert-N9192 $matched $Message
}

function New-N9192Project {
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 3; $i++) {
        [void]$rows.Add([pscustomobject]@{
            Text = ('source ' + $i + ' text'); Translation = ('target ' + $i)
            Kind = 'text'; Location = ('本文 ' + ($i + 1)); Joined = $false
            BlockIds = @(); Cells = @(); Origin = 'manual'; Confirmed = $false
        })
    }
    $project = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N'); Segments = $rows.ToArray(); Blocks = @()
        ReviewEvents = @(); PublicationVariants = @(); ActivePublicationVariantBySegment = [pscustomobject]@{}
        Source = 'text'; Direction = 'to_en'; Revision = 0; FileName = 'review-notes.txt'; SchemaVersion = 8
    }
    $null = Initialize-YakuCatProjectState -Project $project
    return $project
}

function Invoke-N9192NoteMutation {
    param($Project, [string]$Action, [object[]]$Arguments)
    $mutation = $null
    if ($Action -eq 'review-note-add') {
        $mutation = { param($candidate, $index, $text) Add-YakuCatSegmentReviewNote -Project $candidate -Index $index -Text $text }
    } elseif ($Action -eq 'review-note-state') {
        $mutation = { param($candidate, $index, $noteId, $state) Set-YakuCatSegmentReviewNoteState -Project $candidate -Index $index -NoteId $noteId -State $state }
    } else { throw 'test action is invalid' }
    return Invoke-YakuCatProjectMutation -ProjectId ([string]$Project.Id) -ExpectedRevision ([int]$Project.Revision) -Mutation $mutation -Arguments $Arguments -Action $Action
}

function Invoke-N9192Structure {
    param($Project, [string]$Operation, [int]$Index, [int]$Position = -1)
    $mutation = { param($candidate, $operation, $index, $position) Invoke-YakuCatStructuralEdit -Project $candidate -Operation $operation -Index $index -Position $position }
    return Invoke-YakuCatProjectMutation -ProjectId ([string]$Project.Id) -ExpectedRevision ([int]$Project.Revision) -Mutation $mutation -Arguments @($Operation, $Index, $Position) -Action $Operation
}

Write-Host 'Test-YakuV9192SegmentReviewNotes'
. (Join-Path $N9192Src 'SrcModules.ps1')
foreach ($N9192File in @($script:YakuSrcModuleFiles)) {
    . (Join-Path $N9192Src $N9192File)
}
$N9192Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-review-notes-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $N9192Temp -Force
$script:N9192Store = Join-Path $N9192Temp 'store'
function Get-YakuCatProjectStoreDir { return $script:N9192Store }

try {
    $project = New-N9192Project
    $null = Commit-YakuNewCatProject -Project $project
    $project = Get-YakuCatProject -Id ([string]$project.Id)

    $addText = "  first note`nsecond line`tend  "
    $addCommit = Invoke-N9192NoteMutation -Project $project -Action review-note-add -Arguments @([int]0, $addText)
    $project = $addCommit.Project
    $note = @($project.Segments[0].ReviewNotes)[0]
    Assert-N9192 ([int]$project.Revision -gt 0 -and $note.Text -eq "first note`nsecond line`tend" -and $note.State -eq 'open' -and $note.ResolvedAt -eq '') 'add trims text, permits CR/LF/TAB, and creates an open note'
    Assert-N9192 ([string]$note.NoteId -match '^[a-f0-9]{32}$' -and [string]$note.CreatedAt -match 'Z$') 'add creates a stable lowercase 32-hex ID and UTC timestamp'

    $view = ConvertTo-YakuCatProjectJson -Project $project | ConvertFrom-Json
    Assert-N9192 ([string]$view.segments[0].review_notes[0].note_id -eq [string]$note.NoteId -and [string]$view.segments[0].review_notes[0].text -eq [string]$note.Text -and [int]$view.review_notes_open -eq 1 -and [int]$view.review_notes_total -eq 1) 'project view exposes normalized review_notes and unresolved totals'
    Assert-N9192 ([int]$view.segments[1].review_notes.Count -eq 0) 'legacy and untouched segments expose an empty review_notes array'

    $resolveCommit = Invoke-N9192NoteMutation -Project $project -Action review-note-state -Arguments @([int]0, [string]$note.NoteId, 'resolved')
    $project = $resolveCommit.Project
    $resolved = @($project.Segments[0].ReviewNotes)[0]
    Assert-N9192 ($resolved.State -eq 'resolved' -and [string]$resolved.ResolvedAt -match 'Z$') 'resolve records a UTC resolved_at timestamp'
    $reopenCommit = Invoke-N9192NoteMutation -Project $project -Action review-note-state -Arguments @([int]0, [string]$note.NoteId, 'open')
    $project = $reopenCommit.Project
    $reopened = @($project.Segments[0].ReviewNotes)[0]
    Assert-N9192 ($reopened.State -eq 'open' -and $reopened.ResolvedAt -eq '') 'reopen clears resolved_at and returns the note to open'

    Expect-N9192Code { Add-YakuCatSegmentReviewNote -Project $project -Index 0 -Text $null } 'CAT_REVIEW_NOTE_TEXT_REQUIRED' 'empty note text fails closed'
    Expect-N9192Code { Add-YakuCatSegmentReviewNote -Project $project -Index 0 -Text ('x' * 1001) } 'CAT_REVIEW_NOTE_TEXT_TOO_LONG' 'text over 1000 UTF-16 code units fails closed'
    Expect-N9192Code { Add-YakuCatSegmentReviewNote -Project $project -Index 0 -Text ([string]::Concat('bad', [char]0x0001)) } 'CAT_REVIEW_NOTE_TEXT_INVALID' 'disallowed C0 controls fail closed'
    Expect-N9192Code { Add-YakuCatSegmentReviewNote -Project $project -Index 0 -Text ([string]::Concat('bad', [char]0x007f)) } 'CAT_REVIEW_NOTE_TEXT_INVALID' 'DEL fails closed'
    Expect-N9192Code { Set-YakuCatSegmentReviewNoteState -Project $project -Index 0 -NoteId 'not-a-note-id' -State 'open' } 'CAT_REVIEW_NOTE_ID_INVALID' 'invalid note IDs fail closed'
    Expect-N9192Code { Set-YakuCatSegmentReviewNoteState -Project $project -Index 0 -NoteId ([string]$note.NoteId) -State 'pending' } 'CAT_REVIEW_NOTE_STATE_INVALID' 'invalid note states fail closed'
    Expect-N9192Code { Set-YakuCatSegmentReviewNoteState -Project $project -Index 0 -NoteId ('a' * 32) -State 'open' } 'CAT_REVIEW_NOTE_NOT_FOUND' 'unknown valid note IDs fail closed'

    $duplicateSegment = $project.Segments[1]
    $duplicateSegment.ReviewNotes = @($note, (Copy-YakuCatReviewNote -Note $note))
    Expect-N9192Code { Initialize-YakuCatProjectState -Project $project } 'CAT_REVIEW_NOTE_DUPLICATE_ID' 'duplicate note IDs fail closed during normalization'
    $project.Segments[1].ReviewNotes = @()

    $capNotes = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 200; $i++) {
        [void]$capNotes.Add((ConvertTo-YakuCatReviewNote -Note ([pscustomobject]@{
            NoteId = ('{0:x32}' -f $i); Text = ('cap ' + $i); State = 'open'
            CreatedAt = '2026-01-01T00:00:00.000Z'; ResolvedAt = ''
        })))
    }
    $project.Segments[1].ReviewNotes = $capNotes.ToArray()
    Expect-N9192Code { Add-YakuCatSegmentReviewNote -Project $project -Index 1 -Text 'cap overflow' } 'CAT_REVIEW_NOTE_CAP_EXCEEDED' 'the 200-note segment cap fails closed'
    $project.Segments[1].ReviewNotes = @()

    $legacy = New-N9192Project
    $legacy.Segments[0].PSObject.Properties.Remove('ReviewNotes')
    $null = Initialize-YakuCatProjectState -Project $legacy
    Assert-N9192 ($null -ne $legacy.Segments[0].ReviewNotes -and @($legacy.Segments[0].ReviewNotes).Count -eq 0) 'legacy segments without ReviewNotes normalize to an empty array'

    $roundTripId = [string]$project.Id
    $roundTripFields = @([string]$reopened.NoteId, [string]$reopened.Text, [string]$reopened.State, [string]$reopened.CreatedAt, [string]$reopened.ResolvedAt)
    Remove-YakuCatProject -Id $roundTripId
    $restored = Restore-YakuCatProject -Id $roundTripId
    $roundTripNote = @($restored.Segments[0].ReviewNotes)[0]
    $roundTripActual = @([string]$roundTripNote.NoteId, [string]$roundTripNote.Text, [string]$roundTripNote.State, [string]$roundTripNote.CreatedAt, [string]$roundTripNote.ResolvedAt)
    $fieldSeparator = [string][char]0x001f
    Assert-N9192 (($roundTripFields -join $fieldSeparator) -ceq ($roundTripActual -join $fieldSeparator)) 'save and load preserve every normalized note field exactly'
    $project = $restored

    $splitProject = New-N9192Project
    $null = Commit-YakuNewCatProject -Project $splitProject
    $splitProject = Get-YakuCatProject -Id ([string]$splitProject.Id)
    $splitNoteCommit = Invoke-N9192NoteMutation -Project $splitProject -Action review-note-add -Arguments @([int]0, 'split note')
    $splitProject = $splitNoteCommit.Project
    $splitBeforeHash = Get-YakuCatStructuralUndoSegmentsHash -Segments @($splitProject.Segments)
    $splitBeforeNote = ConvertTo-YakuCatReviewNoteJsonValue -Note (@($splitProject.Segments[0].ReviewNotes)[0]) | ConvertTo-Json -Depth 8 -Compress
    $splitCommit = Invoke-N9192Structure -Project $splitProject -Operation 'split-at' -Index 0 -Position 7
    $splitProject = $splitCommit.Project
    $splitFirstNotes = @($splitProject.Segments[0].ReviewNotes)
    $splitSecondNotes = @($splitProject.Segments[1].ReviewNotes)
    Assert-N9192 ($splitFirstNotes.Count -eq 1 -and $splitSecondNotes.Count -eq 0 -and [string]$splitFirstNotes[0].Text -eq 'split note') 'split-at assigns existing notes to exactly the first child'
    $undoCommit = Invoke-YakuCatProjectMutation -ProjectId ([string]$splitProject.Id) -ExpectedRevision ([int]$splitProject.Revision) -Mutation { param($candidate) Undo-YakuCatStructuralEdit -Project $candidate } -Action structure-undo
    $splitProject = $undoCommit.Project
    $undoNote = ConvertTo-YakuCatReviewNoteJsonValue -Note (@($splitProject.Segments[0].ReviewNotes)[0]) | ConvertTo-Json -Depth 8 -Compress
    Assert-N9192 ((Get-YakuCatStructuralUndoSegmentsHash -Segments @($splitProject.Segments)) -eq $splitBeforeHash -and $undoNote -ceq $splitBeforeNote) 'structural undo restores the exact prior notes and segment snapshot'
    $broken = Copy-YakuCatProjectForMutation -Project $splitProject
    $broken.Segments[0].ReviewNotes = @()
    Assert-N9192 ((Get-YakuCatStructuralUndoSegmentsHash -Segments @($broken.Segments)) -ne (Get-YakuCatStructuralUndoSegmentsHash -Segments @($splitProject.Segments))) 'negative self-test detects a controlled in-memory note loss'

    $mergeProject = New-N9192Project
    $firstAdded = Add-YakuCatSegmentReviewNote -Project $mergeProject -Index 0 -Text 'first merge note'
    $secondAdded = Add-YakuCatSegmentReviewNote -Project $mergeProject -Index 1 -Text 'second merge note'
    $null = Merge-YakuCatSegments -Project $mergeProject -Index 0
    $mergedNotes = @($mergeProject.Segments[0].ReviewNotes)
    Assert-N9192 ($mergedNotes.Count -eq 2 -and [string]$mergedNotes[0].NoteId -eq [string]$firstAdded.NoteId -and [string]$mergedNotes[1].NoteId -eq [string]$secondAdded.NoteId) 'merge combines note arrays in source order'
    $reverse = New-N9192Project
    $reverse.Segments[0].ReviewNotes = @($firstAdded)
    $reverse.Segments[1].ReviewNotes = @($secondAdded)
    $null = Merge-YakuCatSegments -Project $reverse -Index 0
    $null = Split-YakuCatSegment -Project $reverse -Index 0
    Assert-N9192 (@($reverse.Segments[0].ReviewNotes).Count -eq 2 -and @($reverse.Segments[1].ReviewNotes).Count -eq 0) 'reversing a prior merge/split keeps notes on one first child without duplication'
    $duplicateMerge = New-N9192Project
    $duplicateMerge.Segments[0].ReviewNotes = @($firstAdded)
    $duplicateMerge.Segments[1].ReviewNotes = @((Copy-YakuCatReviewNote -Note $firstAdded))
    Expect-N9192Code { Merge-YakuCatSegments -Project $duplicateMerge -Index 0 } 'CAT_REVIEW_NOTE_DUPLICATE_ID' 'merge rejects duplicate note IDs'

    $rebaseProject = New-N9192Project
    $null = Commit-YakuNewCatProject -Project $rebaseProject
    $rebaseProject = Get-YakuCatProject -Id ([string]$rebaseProject.Id)
    $rebaseNote = Add-YakuCatSegmentReviewNote -Project $rebaseProject -Index 0 -Text 'rebase note'
    $oldSegmentId = [string]$rebaseProject.Segments[0].SegmentId
    $rebaseMutation = {
        param($candidate, $oldId)
        $candidate.Segments = @([pscustomobject]@{ SegmentId = $oldId; Text = 'updated source'; Translation = ''; Kind = 'text'; Location = '本文'; ReviewNotes = @() })
    }
    $rebaseCommit = Invoke-YakuCatProjectMutation -ProjectId ([string]$rebaseProject.Id) -ExpectedRevision ([int]$rebaseProject.Revision) -Mutation $rebaseMutation -Arguments @($oldSegmentId) -Action source-update-apply
    $rebaseNotes = @($rebaseCommit.Project.Segments[0].ReviewNotes)
    $rebaseActualId = [string]($rebaseNotes[0].NoteId)
    $rebaseExpectedId = [string]($rebaseNote.NoteId)
    if ($rebaseNotes.Count -eq 1) { $rebaseNotesPreserved = $rebaseActualId -eq $rebaseExpectedId } else { $rebaseNotesPreserved = $false }
    Assert-N9192 -Condition $rebaseNotesPreserved -Message 'matched source-update rows carry existing notes forward'

    $staleBefore = [int]$rebaseCommit.Project.Revision
    $staleAction = { Invoke-YakuCatProjectMutation -ProjectId ([string]$rebaseProject.Id) -ExpectedRevision ($staleBefore - 1) -Mutation { param($candidate) Add-YakuCatSegmentReviewNote -Project $candidate -Index 0 -Text 'stale' } -Action review-note-add }
    Expect-N9192Code $staleAction 'CAT_PROJECT_REVISION_CONFLICT' 'review-note mutations use the existing expected-revision contract'

    $serverText = [IO.File]::ReadAllText((Join-Path $N9192Src 'Server.ps1'), [Text.Encoding]::UTF8)
    Assert-N9192 ($serverText -match "'review-note-add'" -and $serverText -match "'review-note-state'") 'server switch wires both review-note routes'
    Assert-N9192 ($serverText -match '\$revisionActions\s*=.*review-note-add.*review-note-state' -and $serverText -match '\$expectedRevision\s*-ne\s*\[int\]\$project\.Revision') 'server routes include review-note actions in expected-revision validation'

    # AST-backed route contract check: the route labels and their mutation call
    # sites must both remain in the production switch, not in a test-only stub.
    $serverAstErrors = $null; $serverTokens = $null
    $serverAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $N9192Src 'Server.ps1'), [ref]$serverTokens, [ref]$serverAstErrors)
    $astText = $serverAst.Extent.Text
    Assert-N9192 ($serverAstErrors.Count -eq 0 -and $astText -match "review-note-add" -and $astText -match "Add-YakuCatSegmentReviewNote" -and $astText -match "Set-YakuCatSegmentReviewNoteState") 'Server.ps1 parses and contains real mutation route calls'

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -ne $node) {
        $driverPath = Join-Path $N9192Temp 'review-notes-screen.js'
        $resultPath = Join-Path $N9192Temp 'review-notes-screen-result.json'
        $beforePath = Join-Path $N9192Temp 'review-notes-screen-before.json'
        $afterAddPath = Join-Path $N9192Temp 'review-notes-screen-add.json'
        $afterStatePath = Join-Path $N9192Temp 'review-notes-screen-state.json'
        $otherPath = Join-Path $N9192Temp 'review-notes-screen-other.json'
        $screenBefore = [ordered]@{
            id='review-notes-screen';revision=40;source='text';lifecycle='saved';file_name='review-notes.txt';document_format='text';direction='to_en';total=2;translated=2;remaining=0;joined=0;confirmed=0;unconfirmed=2;source_chars=30;remaining_chars=0;untranslated=0;draft=2;export_blocked=$false;translation_list_eligibility=$true;excel_draft_eligibility=$false;word_draft_eligibility=$false;tm_pending=0;review_notes_open=1;review_notes_total=1
            segments=@(
                [ordered]@{index=0;segment_id='screen-note-a';source='Alpha source';translation='alpha target';origin='manual';state='human_edited';qc_status='not_run';confirmed=$false;kind='text';location='本文 1';qc_findings=@();qc_preview=@();review_notes=@([ordered]@{note_id='11111111111111111111111111111111';text='initial note';state='open';created_at='2026-01-01T00:00:00.000Z';resolved_at=''});can_merge=$false;can_split=$false;can_split_at=$false},
                [ordered]@{index=1;segment_id='screen-note-b';source='Beta source';translation='beta target';origin='manual';state='human_edited';qc_status='not_run';confirmed=$false;kind='text';location='本文 2';qc_findings=@();qc_preview=@();review_notes=@();can_merge=$false;can_split=$false;can_split_at=$false}
            )
        }
        $screenState = $screenBefore | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $screenState.revision = 41; $screenState.review_notes_open = 0; $screenState.review_notes_total = 1
        $screenState.segments[0].review_notes[0].state = 'resolved'; $screenState.segments[0].review_notes[0].resolved_at = '2026-01-01T00:02:00.000Z'
        $screenAdd = $screenState | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $screenAdd.revision = 42; $screenAdd.review_notes_open = 1; $screenAdd.review_notes_total = 2
        $screenAdd.segments[0].review_notes = @($screenAdd.segments[0].review_notes) + @([pscustomobject]@{note_id='22222222222222222222222222222222';text='new screen note';state='open';created_at='2026-01-01T00:01:00.000Z';resolved_at=''})
        $screenOther = $screenBefore | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $screenOther.id = 'review-notes-screen-other'; $screenOther.revision = 50; $screenOther.file_name = 'review-notes-other.txt'; $screenOther.review_notes_open = 0; $screenOther.review_notes_total = 0
        $screenOther.segments[0].segment_id = 'screen-other-a'; $screenOther.segments[0].source = 'Other Alpha source'; $screenOther.segments[0].translation = 'other alpha target'; $screenOther.segments[0].review_notes = @()
        $screenOther.segments[1].segment_id = 'screen-other-b'; $screenOther.segments[1].source = 'Other Beta source'; $screenOther.segments[1].translation = 'other beta target'; $screenOther.segments[1].review_notes = @()
        [IO.File]::WriteAllText($beforePath, ($screenBefore | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($afterAddPath, ($screenAdd | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($afterStatePath, ($screenState | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($otherPath, ($screenOther | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
        $driver = @'
'use strict';
const fs=require('fs'),http=require('http'),path=require('path');
const {chromium}=require(require.resolve('playwright',{paths:[process.cwd()]}));
const www=process.argv[2],before=JSON.parse(fs.readFileSync(process.argv[3],'utf8')),afterAdd=JSON.parse(fs.readFileSync(process.argv[4],'utf8')),afterState=JSON.parse(fs.readFileSync(process.argv[5],'utf8')),other=JSON.parse(fs.readFileSync(process.argv[6],'utf8')),outPath=process.argv[7];
let currentA=before;
const result={errors:[],console:[],addRequests:[],stateRequests:[],filterVisible:false,filterPressed:false,filterRowsBefore:0,filterHiddenAfterResolve:false,filterRowsAfterResolve:0,filterCountAfterResolve:'',badgeVisible:false,initialNote:false,inputCleared:false,displayedDate:'',rawIsoInText:false,stateNoWrap:false,rowBDraftEmpty:false,rowADraftRestored:false,rowBlankSubmitUnsent:false,rowAddSegmentId:'',rowAddText:'',projectBDraftEmpty:false,projectADraftRestored:false,projectBDraftRestored:false};
const types={'.js':'application/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.html':'text/html; charset=utf-8'};
const send=(res,obj)=>{res.writeHead(200,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(obj));};
const server=http.createServer((req,res)=>{const url=new URL(req.url,'http://127.0.0.1');if(url.pathname==='/'||url.pathname==='/cat'){let html=fs.readFileSync(path.join(www,'cat.html'),'utf8');html=html.replace(/__YAKU_SESSION_TOKEN__/g,'review-notes-test-token').replace(/__YAKU_MAX_UPLOAD_BYTES__/g,'52428800').replace(/__YAKU_MAX_BATCH_CHARS__/g,'4000').replace(/__YAKU_AMOUNT_NOTATION__/g,'oku').replace(/__YAKU_OUTPUT_FONT__/g,'Arial').replace(/__YAKU_OUTPUT_FONT_JP__/g,'MS P\u30b4\u30b7\u30c3\u30af').replace(/__YAKU_TOUR__/g,'0').replace(/__YAKU_IMPORT__/g,'0').replace(/__YAKU_VIEW__/g,'');res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(html);return;}if(url.pathname.startsWith('/assets/')){const f=path.join(www,url.pathname.replace(/^\//,''));if(fs.existsSync(f)){res.writeHead(200,{'Content-Type':types[path.extname(f)]||'application/octet-stream'});res.end(fs.readFileSync(f));return;}res.writeHead(404);res.end();return;}let raw='';req.on('data',c=>raw+=c);req.on('end',()=>{let body={};try{body=JSON.parse(raw||'{}')}catch(_){}if(url.pathname==='/api/cat/resume')return send(res,String(body.project_id||'')===String(other.id) ? other : currentA);if(url.pathname==='/api/cat/review-note-add'){result.addRequests.push(body);currentA=afterAdd;return send(res,afterAdd);}if(url.pathname==='/api/cat/review-note-state'){result.stateRequests.push(body);currentA=afterState;return send(res,afterState);}if(url.pathname==='/api/ready-state')return send(res,{canTranslate:true,label:'ready',class:'ok'});if(url.pathname==='/api/cat/recent')return send(res,{projects:[{id:before.id,file_name:before.file_name,source:before.source,direction:before.direction,total:before.total,confirmed:before.confirmed,saved:'2026-01-01T00:00:00.000Z'},{id:other.id,file_name:other.file_name,source:other.source,direction:other.direction,total:other.total,confirmed:other.confirmed,saved:'2026-01-01T00:00:00.000Z'}]});if(url.pathname==='/api/cat/project-presence')return send(res,{ok:true});if(url.pathname==='/api/cat/candidates')return send(res,{candidates:[]});return send(res,{});});});
 (async()=>{let browser;try{await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch();const page=await browser.newPage({viewport:{width:1912,height:987}});page.on('pageerror',e=>result.errors.push(String(e.message||e)));page.on('console',m=>{if(m.type()==='error')result.console.push(m.text());});await page.goto('http://127.0.0.1:'+server.address().port+'/cat?project=review-notes-screen',{waitUntil:'domcontentloaded'});await page.waitForSelector('#cat-tab-review-notes',{state:'visible',timeout:20000});const noteFilter=page.locator('[data-cat-filter="review_notes"]');result.filterVisible=await noteFilter.isVisible();await page.locator('#cat-tab-review-notes').click();result.initialNote=(await page.locator('#cat-review-notes-list').textContent()).includes('initial note');result.badgeVisible=await page.locator('.cat-review-note-badge').count()>0;result.displayedDate=await page.locator('.cat-review-note-time').first().textContent();result.rawIsoInText=result.displayedDate.includes('2026-01-01T00:00:00.000Z');result.stateNoWrap=await page.locator('.cat-review-note-state').first().evaluate(node=>getComputedStyle(node).whiteSpace==='nowrap');await noteFilter.click();result.filterPressed=(await noteFilter.getAttribute('aria-pressed'))==='true';result.filterRowsBefore=await page.locator('[data-cat-row]').count();await page.locator('[data-cat-review-note-state="resolved"]').first().click();await page.waitForFunction(()=>{const filter=document.querySelector('[data-cat-filter="review_notes"]'),actionable=document.querySelector('[data-cat-filter="actionable"]');return filter&&filter.hidden&&actionable&&actionable.getAttribute('aria-pressed')==='true';},null,{timeout:20000});result.filterHiddenAfterResolve=await noteFilter.isHidden();result.filterRowsAfterResolve=await page.locator('[data-cat-row]').count();result.filterCountAfterResolve=await page.locator('#cat-filter-count').textContent();await page.locator('[data-cat-input="0"]').focus();await page.locator('#cat-review-notes-input').fill('row A draft');await page.locator('[data-cat-input="1"]').focus();result.rowBDraftEmpty=(await page.locator('#cat-review-notes-input').inputValue())==='';await page.locator('#cat-review-notes-form button[type="submit"]').click();await page.waitForTimeout(100);result.rowBlankSubmitUnsent=result.addRequests.length===0;await page.locator('[data-cat-input="0"]').focus();result.rowADraftRestored=(await page.locator('#cat-review-notes-input').inputValue())==='row A draft';result.rowAddSegmentId=String(await page.locator('.is-active').getAttribute('data-cat-segment-id'));await page.locator('#cat-review-notes-form button[type="submit"]').click();await page.waitForFunction(()=>document.getElementById('cat-review-notes-list').textContent.includes('new screen note'),null,{timeout:20000});result.rowAddText=String((result.addRequests[0]||{}).text||'');result.inputCleared=(await page.locator('#cat-review-notes-input').inputValue())==='';await page.locator('#cat-review-notes-input').fill('project A draft');await page.locator('#cat-doc-switch').click();await page.waitForSelector('#cat-doc-dialog[open] [data-cat-doc-open="review-notes-screen-other"]',{state:'visible',timeout:20000});await page.locator('#cat-doc-dialog[open] [data-cat-doc-open="review-notes-screen-other"]').click();await page.waitForFunction(()=>!!document.querySelector('[data-cat-segment-id="screen-other-a"]'),null,{timeout:20000});result.projectBDraftEmpty=(await page.locator('#cat-review-notes-input').inputValue())==='';await page.locator('#cat-review-notes-input').fill('project B draft');await page.locator('#cat-doc-switch').click();await page.waitForSelector('#cat-doc-dialog[open] [data-cat-doc-open="review-notes-screen"]',{state:'visible',timeout:20000});await page.locator('#cat-doc-dialog[open] [data-cat-doc-open="review-notes-screen"]').click();await page.waitForFunction(()=>!!document.querySelector('[data-cat-segment-id="screen-note-a"]'),null,{timeout:20000});result.projectADraftRestored=(await page.locator('#cat-review-notes-input').inputValue())==='project A draft';await page.locator('#cat-doc-switch').click();await page.waitForSelector('#cat-doc-dialog[open] [data-cat-doc-open="review-notes-screen-other"]',{state:'visible',timeout:20000});await page.locator('#cat-doc-dialog[open] [data-cat-doc-open="review-notes-screen-other"]').click();await page.waitForFunction(()=>!!document.querySelector('[data-cat-segment-id="screen-other-a"]'),null,{timeout:20000});result.projectBDraftRestored=(await page.locator('#cat-review-notes-input').inputValue())==='project B draft';}catch(e){result.errors.push(String(e&&e.stack||e));process.exitCode=1;}finally{try{if(browser)await browser.close();}catch(_){}await new Promise(r=>server.close(r));fs.writeFileSync(outPath,JSON.stringify(result));}})();
'@
        [IO.File]::WriteAllText($driverPath, $driver, (New-Object Text.UTF8Encoding($false)))
        $probeDir = (Join-Path $N9192Root 'tools\cat-screen').Replace('\','/')
        $null = & $node.Source -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
        if ($LASTEXITCODE -eq 0) {
            & $node.Source $driverPath (Join-Path $N9192Root 'www') $beforePath $afterAddPath $afterStatePath $otherPath $resultPath
            $browserExit = $LASTEXITCODE
            $browserResult = $null
            if (Test-Path -LiteralPath $resultPath) { $browserResult = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }
            Assert-N9192 ($browserExit -eq 0 -and $null -ne $browserResult -and @($browserResult.errors).Count -eq 0 -and @($browserResult.console).Count -eq 0) 'Chromium CAT review-note screen has no page or console errors'
            Assert-N9192 ($null -ne $browserResult -and [bool]$browserResult.filterVisible -and [bool]$browserResult.initialNote -and [bool]$browserResult.badgeVisible) 'Chromium shows the 作業メモ filter, tab, open note, and row badge'
            Assert-N9192 ($null -ne $browserResult -and [string]$browserResult.displayedDate -match '(今日|昨日|[0-9]+月[0-9]+日) [0-9]{2}:[0-9]{2}' -and -not [bool]$browserResult.rawIsoInText) 'Chromium displays a compact local note time instead of the raw UTC ISO string'
            Assert-N9192 ($null -ne $browserResult -and [bool]$browserResult.stateNoWrap) 'Chromium keeps the 作業メモ state label on one line'
            Assert-N9192 ($null -ne $browserResult -and [bool]$browserResult.filterPressed -and [int]$browserResult.filterRowsBefore -eq 1 -and [bool]$browserResult.filterHiddenAfterResolve -and [int]$browserResult.filterRowsAfterResolve -eq 2 -and [string]$browserResult.filterCountAfterResolve -match '2 / 2') 'Chromium resolves the last filtered note and immediately renders exactly the two fallback rows/count consistently'
            Assert-N9192 ($null -ne $browserResult -and [bool]$browserResult.inputCleared -and @($browserResult.addRequests).Count -eq 1 -and [int]$browserResult.addRequests[0].expected_revision -eq 41 -and [string]$browserResult.addRequests[0].id -eq 'review-notes-screen') 'Chromium add form sends text with the current expected revision and clears after commit'
            Assert-N9192 ($null -ne $browserResult -and @($browserResult.stateRequests).Count -eq 1 -and [int]$browserResult.stateRequests[0].expected_revision -eq 40 -and [string]$browserResult.stateRequests[0].state -eq 'resolved') 'Chromium state button sends resolve through the same CAS mutation path'
            Assert-N9192 ($null -ne $browserResult -and [bool]$browserResult.rowBDraftEmpty -and [bool]$browserResult.rowBlankSubmitUnsent -and [bool]$browserResult.rowADraftRestored -and [string]$browserResult.rowAddSegmentId -eq 'screen-note-a' -and [string]$browserResult.rowAddText -eq 'row A draft') 'Chromium keeps row drafts bound to their segment and never submits row A text from row B'
            Assert-N9192 ($null -ne $browserResult -and [bool]$browserResult.projectBDraftEmpty -and [bool]$browserResult.projectADraftRestored -and [bool]$browserResult.projectBDraftRestored) 'Chromium keeps separate project drafts isolated and restores each after switching back'
        } else { Assert-N9192 $false 'Chromium CAT review-note screen requires Playwright' }
    } else { Assert-N9192 $false 'Chromium CAT review-note screen requires node' }
} finally {
    if (Test-Path -LiteralPath $N9192Temp) { Remove-Item -LiteralPath $N9192Temp -Recurse -Force }
}

Write-Host ''
if ($script:N9192Failures.Count -eq 0) { Write-Host 'PASS Test-YakuV9192SegmentReviewNotes'; exit 0 }
Write-Host ('FAIL ' + $script:N9192Failures.Count + ' assertion(s)')
foreach ($failure in $script:N9192Failures) { Write-Host ('  - ' + $failure) }
exit 1
