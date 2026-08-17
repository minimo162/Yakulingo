#Requires -Version 5.1
<# V91.61: 訳文内の対応する括弧を、書き出しを止めない warning として扱う回帰。 #>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9191Root = Split-Path -Parent $PSScriptRoot
$YakuT9191Src = Join-Path $YakuT9191Root 'src'
$script:YakuT9191Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9191 { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message)}else{Write-Host ('  NG   '+$Message);[void]$script:YakuT9191Failures.Add($Message)} }
function Test-T9191Code { param($Findings,[string]$Code) return @($Findings|Where-Object{[string]$_.Code -eq $Code}).Count -gt 0 }

Write-Host 'Test-YakuV9191PairedDelimiterQa'
. (Join-Path $YakuT9191Src 'SrcModules.ps1')
foreach($YakuT9191File in $script:YakuSrcModuleFiles){if($YakuT9191File -eq 'DesktopIntegration.ps1'){continue};. (Join-Path $YakuT9191Src $YakuT9191File)}
$YakuT9191Temp=Join-Path ([IO.Path]::GetTempPath()) ('yaku9191-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $YakuT9191Temp -Force
$YakuT9191OldData=[string]$env:YAKULINGO_DATA_DIR;$env:YAKULINGO_DATA_DIR=Join-Path $YakuT9191Temp 'user-data'

try {
    $settings=Read-YakuSettings -Root $YakuT9191Root
    $pairs=@(@('(',')'),@('[',']'),@('{','}'),@('（','）'),@('［','］'),@('｛','｝'),@('「','」'),@('『','』'),@('【','】'),@('〔','〕'),@('〈','〉'),@('《','》'),@('“','”'))
    foreach($pair in $pairs){$nested=[string]$pair[0]+'outer '+[string]$pair[0]+'inner'+[string]$pair[1]+[string]$pair[1];Assert-T9191 ($null -eq (Find-YakuCatPairedDelimiterMismatch -Text $nested)) ('all supported pairs accept a valid nested form: '+[string]$pair[0]+[string]$pair[1])}
    $curlySingle=[string]::Concat([char]0x2018,'single quote is excluded',[char]0x2019)
    $valid=@('Sales (revised [draft]).','【概要】「売上高（連結）」','“quoted [note]”','Revenue [[N1]] and [[P22]].','O''Brien said "yes".',$curlySingle,'a < b and x > y')
    foreach($text in $valid){Assert-T9191 ($null -eq (Find-YakuCatPairedDelimiterMismatch -Text $text)) ('valid or excluded text has no mismatch: '+$text)}
    $bad=@(
        @{Text='Sales (revised';Reason='missing-closing'},
        @{Text='Sales revised）';Reason='unexpected-closing'},
        @{Text='Sales ([revised)]';Reason='mismatched-closing'},
        @{Text='【概要」';Reason='mismatched-closing'},
        @{Text='（Sales)';Reason='mismatched-closing'}
    )
    foreach($case in $bad){$finding=Find-YakuCatPairedDelimiterMismatch -Text ([string]$case.Text);Assert-T9191 ($null -ne $finding -and [string]$finding.Reason -eq [string]$case.Reason) ('mismatch detects '+[string]$case.Reason+': '+[string]$case.Text)}
    Assert-T9191 ((Get-YakuCatQcContractVersion) -eq 'cat-qc-v3-terminology') 'warning rollout does not change the blocking QC contract version'

    $project=New-YakuCatTextProject -Root $YakuT9191Root -Text 'Source text.' -Settings $settings -Direction to_en -Register:$false
    $segment=$project.Segments[0];$null=Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'Sales (provisional'
    $validation=Invoke-YakuCatSegmentValidation -Project $project -Segment $segment
    Assert-T9191 ([bool]$validation.Passed -and (Test-T9191Code -Findings @($validation.Findings) -Code 'paired-delimiter-mismatch') -and @($validation.Findings|Where-Object{[string]$_.Severity -eq 'error'}).Count -eq 0) 'paired delimiter is a warning only and does not fail segment validation'
    $confirmed=Set-YakuCatSegmentConfirmed -Project $project -Index 0 -Confirmed $true
    Assert-T9191 ([bool]$confirmed.Confirmed -and [string]$confirmed.QcStatus -eq 'passed' -and (Test-T9191Code -Findings @($confirmed.QcFindings) -Code 'paired-delimiter-mismatch')) 'confirm persists the warning while retaining passed QC'
    $eligible=Get-YakuCatOutputEligibility -Project $project
    Assert-T9191 ([bool]$eligible.TranslationListEligible -and @($eligible.Reasons).Count -eq 0 -and @($eligible.QcFailures).Count -eq 0) 'warning does not become an export blocker'
    $toJp=New-YakuCatTextProject -Root $YakuT9191Root -Text 'English source.' -Settings $settings -Direction to_jp -Register:$false
    $null=Set-YakuCatSegmentTranslation -Project $toJp -Index 0 -Text '売上高（暫定'
    $toJpValidation=Invoke-YakuCatSegmentValidation -Project $toJp -Segment $toJp.Segments[0]
    Assert-T9191 ([bool]$toJpValidation.Passed -and (Test-T9191Code -Findings @($toJpValidation.Findings) -Code 'paired-delimiter-mismatch') -and @($toJpValidation.Findings|Where-Object{[string]$_.Severity -eq 'error'}).Count -eq 0) 'to_jp also treats a paired delimiter mismatch as warning only'

    $legacy=New-YakuCatTextProject -Root $YakuT9191Root -Text 'Legacy source.' -Settings $settings -Direction to_en -Register:$false
    $legacySegment=$legacy.Segments[0];$null=Set-YakuCatSegmentTranslation -Project $legacy -Index 0 -Text 'Legacy (target'
    $legacySegment.State='reviewed';$legacySegment.Confirmed=$true;$legacySegment.QcStatus='passed';$legacySegment.QcSourceRevision=[int]$legacySegment.SourceRevision
    $legacySegment.QcSourceHash=Get-YakuCatSourceIntegrityHash -Text ([string]$legacySegment.Text);$legacySegment.QcTargetHash=Get-YakuCatSourceIntegrityHash -Text ([string]$legacySegment.Translation)
    $legacySegment.QcContractVersion=Get-YakuCatQcContractVersion;$legacySegment.QcTerminologyHash=[string]$legacy.TerminologySnapshotHash;$legacySegment.QcFindings=@()
    $legacyRevision=[int]$legacy.Revision;$legacyEvents=@($legacy.ReviewEvents|ConvertTo-Json -Depth 12 -Compress);$legacyEligibility=Get-YakuCatOutputEligibility -Project $legacy
    $legacyView=ConvertTo-YakuCatProjectJson -Project $legacy|ConvertFrom-Json
    $legacyRow=@($legacyView.segments|Where-Object{[string]$_.segment_id -eq [string]$legacySegment.SegmentId})[0]
    Assert-T9191 ([bool]$legacyEligibility.TranslationListEligible -and @($legacyEligibility.Reasons).Count -eq 0 -and (Test-YakuCatSegmentQcCurrent -Segment $legacySegment -TerminologySnapshotHash ([string]$legacy.TerminologySnapshotHash))) 'legacy confirmed row stays current and exportable'
    Assert-T9191 ((Test-T9191Code -Findings @($legacyRow.qc_preview) -Code 'paired-delimiter-mismatch') -and @($legacyRow.qc_findings).Count -eq 0) 'legacy confirmed row receives a read-only preview warning instead of a rewritten finding'
    $legacyEventsAfter=@($legacy.ReviewEvents|ConvertTo-Json -Depth 12 -Compress)
    $legacyStable=([int]$legacy.Revision -eq $legacyRevision -and (($legacyEventsAfter -join '|') -eq ($legacyEvents -join '|')) -and @($legacySegment.QcFindings).Count -eq 0)
    if(-not $legacyStable){Write-Host ('  legacy mutation evidence revision='+[string]$legacy.Revision+'/'+[string]$legacyRevision+' events='+($legacyEventsAfter -join '|')+'/'+($legacyEvents -join '|')+' findings='+[string]@($legacySegment.QcFindings).Count)}
    Assert-T9191 $legacyStable 'legacy preview does not mutate revision, audit, or persistent QC findings'

    $watch=[Diagnostics.Stopwatch]::StartNew();$largeFinding=Find-YakuCatPairedDelimiterMismatch -Text (('a'*1000000)+'（x）');$watch.Stop()
    Assert-T9191 ($null -eq $largeFinding -and $watch.ElapsedMilliseconds -lt 2000) ('one million UTF-16 code units scan linearly in under 2 seconds (actual '+$watch.ElapsedMilliseconds+'ms)')

    $YakuT9191Node=Get-Command node -ErrorAction SilentlyContinue
    $YakuT9191Probe=(Join-Path $YakuT9191Root 'tools\cat-screen').Replace('\','/')
    $YakuT9191BrowserReady=($null -ne $YakuT9191Node)
    if($YakuT9191BrowserReady){$null=& ([string]$YakuT9191Node.Source) -e ("try{const fs=require('fs');const p=require.resolve('playwright',{paths:['"+$YakuT9191Probe+"']});const e=require(p).chromium.executablePath();process.exit(e&&fs.existsSync(e)?0:9)}catch(_){process.exit(9)}") 2>$null;$YakuT9191BrowserReady=($LASTEXITCODE -eq 0)}
    if(-not $YakuT9191BrowserReady){Write-Host 'UNMEASURED: Playwright Chromium is unavailable.';exit 3}

    $browserProject=[ordered]@{
        id='delimiter-screen-9191';revision=1;source='text';file_name='delimiter.txt';document_format='text';direction='to_en';total=2;translated=2;remaining=0;joined=0;confirmed=2;unconfirmed=0;source_chars=24;remaining_chars=0;untranslated=0;draft=0;export_blocked=$false;translation_list_eligibility=$true;excel_draft_eligibility=$false;word_draft_eligibility=$false;tm_pending=0
        segments=@(
            [ordered]@{index=0;segment_id='delimiter-preview';source='Legacy source.';translation='Sales (provisional';origin='manual';state='reviewed';qc_status='passed';confirmed=$true;kind='text';location='1';qc_findings=@();qc_preview=@([ordered]@{code='paired-delimiter-mismatch'})},
            [ordered]@{index=1;segment_id='delimiter-persisted';source='New source.';translation='Revenue [draft';origin='manual';state='reviewed';qc_status='passed';confirmed=$true;kind='text';location='2';qc_findings=@([ordered]@{code='paired-delimiter-mismatch';severity='warning'});qc_preview=@()}
        )
    }
    $browserProjectPath=Join-Path $YakuT9191Temp 'project.json';$browserOutPath=Join-Path $YakuT9191Temp 'browser.json';$browserDriverPath=Join-Path $YakuT9191Temp 'screen.js'
    [IO.File]::WriteAllText($browserProjectPath,($browserProject|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)))
    $browserDriver=@'
'use strict';
const fs=require('fs'),http=require('http'),path=require('path');
const www=process.argv[2],project=fs.readFileSync(process.argv[3],'utf8'),outPath=process.argv[4],probe=process.argv[5];
const {chromium}=require(require.resolve('playwright',{paths:[probe]}));
const out={errors:[],console:[],qaLabel:'',hasBlockers:false,groups:[],summary:'',cards:[],clickedRow:-1};
const types={'.js':'application/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.html':'text/html; charset=utf-8'};
const server=http.createServer((req,res)=>{const u=new URL(req.url,'http://127.0.0.1');if(u.pathname==='/'||u.pathname==='/cat'){let h=fs.readFileSync(path.join(www,'cat.html'),'utf8');h=h.replace(/__YAKU_SESSION_TOKEN__/g,'delimiter-test').replace(/__YAKU_MAX_UPLOAD_BYTES__/g,'52428800').replace(/__YAKU_MAX_BATCH_CHARS__/g,'4000').replace(/__YAKU_AMOUNT_NOTATION__/g,'oku').replace(/__YAKU_OUTPUT_FONT__/g,'Arial').replace(/__YAKU_OUTPUT_FONT_JP__/g,'MS P\u30b4\u30b7\u30c3\u30af').replace(/__YAKU_TOUR__/g,'0').replace(/__YAKU_IMPORT__/g,'0').replace(/__YAKU_VIEW__/g,'');res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(h);return;}if(u.pathname.startsWith('/assets/')){const f=path.join(www,u.pathname.replace(/^\//,''));if(fs.existsSync(f)){res.writeHead(200,{'Content-Type':types[path.extname(f)]||'application/octet-stream'});res.end(fs.readFileSync(f));return;}res.writeHead(404);res.end();return;}let raw='';req.on('data',c=>raw+=c);req.on('end',()=>{let answer={};if(u.pathname==='/api/cat/resume')answer=JSON.parse(project);else if(u.pathname==='/api/ready-state')answer={canTranslate:true,label:'ready',class:'ok'};else if(u.pathname==='/api/cat/recent')answer={projects:[]};else if(u.pathname==='/api/cat/project-presence')answer={ok:true};res.writeHead(200,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(answer));});});
(async()=>{let browser;try{await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch();const page=await browser.newPage({viewport:{width:1912,height:987}});page.on('pageerror',e=>out.errors.push(String(e.message||e)));page.on('console',m=>{if(m.type()==='error')out.console.push(m.text());});await page.goto('http://127.0.0.1:'+server.address().port+'/cat?project=delimiter-screen-9191',{waitUntil:'domcontentloaded'});await page.waitForSelector('#cat-grid-body tr[data-cat-row]',{timeout:20000});out.qaLabel=await page.locator('#cat-qa-open').textContent();out.hasBlockers=await page.locator('#cat-qa-open').evaluate(n=>n.classList.contains('cat-qa-has-blockers'));await page.locator('#cat-qa-open').click();await page.waitForSelector('#cat-qa-dialog[open]',{timeout:10000});out.summary=await page.locator('#cat-qa-summary').textContent();out.groups=await page.locator('.cat-qa-group').evaluateAll(nodes=>nodes.map(n=>({title:(n.querySelector('h3').firstChild.textContent||'').trim(),count:Number(n.querySelector('h3 span').textContent),blocking:n.classList.contains('is-blocking'),text:n.textContent})));const delimiterGroup=page.locator('.cat-qa-group').filter({hasText:'括弧・引用符の対応'});await delimiterGroup.locator('.cat-qa-item').first().click();await page.waitForSelector('#cat-grid-body tr.is-active',{timeout:10000});out.clickedRow=Number(await page.locator('#cat-grid-body tr.is-active').getAttribute('data-cat-row'));await page.locator('textarea[data-cat-input="0"]').focus();await page.locator('[data-cat-inspector="qc"]').click();await page.waitForTimeout(150);out.cards=await page.locator('#cat-qc-list .cat-qc-card').evaluateAll(nodes=>nodes.map(n=>({text:n.textContent,classes:n.className,preview:n.getAttribute('data-cat-qc-preview')})));}catch(e){out.errors.push(String(e&&e.stack||e));process.exitCode=1;}finally{try{if(browser)await browser.close();}catch(_){}await new Promise(r=>server.close(r));fs.writeFileSync(outPath,JSON.stringify(out));}})();
'@
    [IO.File]::WriteAllText($browserDriverPath,$browserDriver,(New-Object Text.UTF8Encoding($false)))
    & ([string]$YakuT9191Node.Source) $browserDriverPath (Join-Path $YakuT9191Root 'www') $browserProjectPath $browserOutPath $YakuT9191Probe
    $browserExit=$LASTEXITCODE;$browser=$null;if(Test-Path -LiteralPath $browserOutPath){$browser=[IO.File]::ReadAllText($browserOutPath,[Text.Encoding]::UTF8)|ConvertFrom-Json}
    if($null -ne $browser){foreach($error in @($browser.errors)){Write-Host ('  Chromium error: '+[string]$error)};foreach($error in @($browser.console)){Write-Host ('  Chromium console: '+[string]$error)}}
    $delimiterGroup=if($null -ne $browser){@($browser.groups|Where-Object{[string]$_.title -eq '括弧・引用符の対応'})[0]}else{$null}
    Assert-T9191 ($browserExit -eq 0 -and $null -ne $browser -and @($browser.errors).Count -eq 0 -and @($browser.console).Count -eq 0) 'Chromium opens the actual CAT page without page or console errors'
    Assert-T9191 ($null -ne $browser -and [string]$browser.qaLabel -eq '点検' -and -not [bool]$browser.hasBlockers) 'Chromium warning does not add a blocker count or red blocker appearance'
    Assert-T9191 ($null -ne $delimiterGroup -and [int]$delimiterGroup.count -eq 2 -and -not [bool]$delimiterGroup.blocking -and [string]$delimiterGroup.text -match '開き括弧・閉じ括弧') 'Chromium puts preview and persisted warnings in the dedicated nonblocking group'
    Assert-T9191 ($null -ne $browser -and [int]$browser.clickedRow -eq 0) 'Chromium clicking the dedicated warning group moves to its target row'
    Assert-T9191 ($null -ne $browser -and [string]$browser.summary -match '書き出しは止まりません' -and @($browser.cards|Where-Object{[string]$_.preview -eq '1' -and [string]$_.classes -match 'is-warn'}).Count -eq 1) 'Chromium shows the advisory wording and preview warning appearance'
} finally {
    $env:YAKULINGO_DATA_DIR=$YakuT9191OldData
    if(Test-Path -LiteralPath $YakuT9191Temp){Remove-Item -LiteralPath $YakuT9191Temp -Recurse -Force}
}

Write-Host ''
if($script:YakuT9191Failures.Count -eq 0){Write-Host 'PASS Test-YakuV9191PairedDelimiterQa';exit 0}
Write-Host ('FAIL '+$script:YakuT9191Failures.Count+' assertion(s)');foreach($YakuT9191Failure in $script:YakuT9191Failures){Write-Host ('  - '+$YakuT9191Failure)};exit 1
