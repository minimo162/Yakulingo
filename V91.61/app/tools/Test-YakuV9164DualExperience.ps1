<#
.SYNOPSIS
  V91.64 dual-experience contract regression.

.DESCRIPTION
  This is intentionally a forward contract.  It is expected to fail until the
  Quick/CAT split, ephemeral QuickArtifact handoff, and reuse boundaries exist.
  Production files are read or invoked, but never modified by this test.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT = '1'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$srcRoot = Join-Path $root 'src'
$wwwRoot = Join-Path $root 'www'
$script:failed = 0

function Check-YakuDual {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

function Read-YakuDualText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($Path)
}

function Get-YakuDualSlice {
    param([string]$Text, [string]$Start, [string]$End)
    $a = $Text.IndexOf($Start, [StringComparison]::Ordinal)
    if ($a -lt 0) { return '' }
    $b = $Text.IndexOf($End, $a + $Start.Length, [StringComparison]::Ordinal)
    if ($b -lt 0) { return $Text.Substring($a) }
    return $Text.Substring($a, $b - $a)
}

$serverPath = Join-Path $srcRoot 'Server.ps1'
$translationPath = Join-Path $srcRoot 'Translation.ps1'
$catBatchPath = Join-Path $srcRoot 'CatBatch.ps1'
$catProjectPath = Join-Path $srcRoot 'CatProject.ps1'
$translationMemoryPath = Join-Path $srcRoot 'TranslationMemory.ps1'
$htmlPath = Join-Path $srcRoot 'Html.ps1'
$landingPath = Join-Path $wwwRoot 'index.html'
$quickPagePath = Join-Path $wwwRoot 'quick.html'
$catPagePath = Join-Path $wwwRoot 'cat.html'
$assetsRoot = Join-Path $wwwRoot 'assets'
$homeClientPath = Join-Path $assetsRoot 'home.js'
$quickClientPath = Join-Path $assetsRoot 'quick.js'
$catClientPath = Join-Path $assetsRoot 'cat.js'
$catWorkspaceStylePath = Join-Path $assetsRoot 'cat-workspace.css'
$quickArtifactPath = Join-Path $srcRoot 'QuickArtifact.ps1'

$server = Read-YakuDualText $serverPath
$translationSource = Read-YakuDualText $translationPath
$catBatchSource = Read-YakuDualText $catBatchPath
$catProjectSource = Read-YakuDualText $catProjectPath
$translationMemorySource = Read-YakuDualText $translationMemoryPath
$rendererSource = Read-YakuDualText $htmlPath
$landing = Read-YakuDualText $landingPath
$quickPage = Read-YakuDualText $quickPagePath
$catPage = Read-YakuDualText $catPagePath
$homeClient = Read-YakuDualText $homeClientPath
$quickClient = Read-YakuDualText $quickClientPath
$catClient = Read-YakuDualText $catClientPath
$catWorkspaceStyle = Read-YakuDualText $catWorkspaceStylePath
$client = $homeClient + "`n" + $quickClient + "`n" + $catClient

Write-Host 'Single launch, landing, and DOM separation' -ForegroundColor Cyan
Check-YakuDual (($server -split '\[System\.Net\.HttpListener\]::new\(\)').Count -eq 2) 'one listener instance serves both experiences'
Check-YakuDual ($server -match '(?i)[\x22\x27]?/quick[\x22\x27]?' -and $server -match '(?i)[\x22\x27]?/cat[\x22\x27]?') 'server exposes /quick and /cat from the same launch'
Check-YakuDual ($landing -match '(?i)href\s*=\s*[\x22\x27][^\x22\x27]*/quick[\x22\x27]' -and $landing -match '(?i)href\s*=\s*[\x22\x27][^\x22\x27]*/cat[\x22\x27]') 'large landing links to /quick and /cat'
Check-YakuDual ($landing -notmatch 'id\s*=\s*[\x22\x27](?:text-form|cat-open-button)[\x22\x27]') 'landing contains no translator DOM'
Check-YakuDual (Test-Path -LiteralPath $quickPagePath -PathType Leaf) 'dedicated Quick page exists'
Check-YakuDual (Test-Path -LiteralPath $catPagePath -PathType Leaf) 'dedicated CAT page exists'
Check-YakuDual ($quickPage -match '<body[^>]+class\s*=\s*[\x22\x27][^\x22\x27]*app-quick' -and $quickPage -match 'id\s*=\s*[\x22\x27]quick-form[\x22\x27]') 'Quick page declares only the Quick experience'
Check-YakuDual ($quickPage -notmatch 'id\s*=\s*[\x22\x27](?:panel-cat|cat-open-button|cat-grid)[\x22\x27]') 'Quick DOM has no CAT controls'
Check-YakuDual ($catPage -match '<body[^>]+class\s*=\s*[\x22\x27][^\x22\x27]*app-cat' -and $catPage -match 'id\s*=\s*[\x22\x27]cat-picker[\x22\x27]') 'CAT page declares only the CAT experience'
Check-YakuDual ($catPage -notmatch 'id\s*=\s*[\x22\x27](?:panel-text|text-form|input-text)[\x22\x27]') 'CAT DOM has no Quick controls'
Check-YakuDual ($quickClient -notmatch '/api/cat/(?!promote)' -and $catClient -notmatch '/api/quick/') 'active clients cannot call the other experience API'

Write-Host 'Load production helpers for dynamic contracts' -ForegroundColor Cyan
foreach ($name in @(
    'Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1',
    'CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1',
    'CorpusReference.ps1','ProperNoun.ps1','CellSegments.ps1','CellAlign.ps1','TranslationMemory.ps1','CatProject.ps1','QuickArtifact.ps1'
)) {
    $path = Join-Path $srcRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { . $path }
}

Write-Host 'Low-confidence direction is stopped before transport' -ForegroundColor Cyan
$lowText = -join @([char]0x5229,[char]0x76CA) # two-kanji heading
$decision = Resolve-YakuDirectionDecision -Text $lowText -Intent auto
Check-YakuDual ([bool]$decision.RequiresConfirmation -and [string]::IsNullOrWhiteSpace([string]$decision.Resolved)) 'low-confidence direction is unresolved'
$simulatedTransportCalls = 0
if (-not [bool]$decision.RequiresConfirmation) { $simulatedTransportCalls++ }
Check-YakuDual ($simulatedTransportCalls -eq 0) 'low-confidence decision produces zero transport calls'
$textRoute = Get-YakuDualSlice -Text $server -Start "if (`$method -eq 'POST' -and `$path -eq '/api/translate-text')" -End "if (`$method -eq 'POST' -and `$path.StartsWith('/api/cat/'))"
$directionGateAt = $textRoute.IndexOf('RequiresConfirmation', [StringComparison]::Ordinal)
$jobStartAt = $textRoute.IndexOf('Start-YakuTranslationJob', [StringComparison]::Ordinal)
Check-YakuDual ($directionGateAt -ge 0 -and $jobStartAt -gt $directionGateAt) 'Quick route gates direction before starting a job'
Check-YakuDual ($quickClient -notmatch 'function\s+analysis\s*\(|YakuZhSimplifiedChars|YAKU_ZH_ONLY' -and $quickClient -match "direction_intent:\s*explicitDirection\s*\|\|\s*'auto'") 'browser delegates automatic direction decisions to the single server classifier'
$noLanguage = Resolve-YakuDirectionDecision -Text '123' -Intent auto
Check-YakuDual ([bool]$noLanguage.RequiresConfirmation -and [string]::IsNullOrWhiteSpace([string]$noLanguage.Resolved)) 'numeric-only input is stopped for confirmation before transport'

Write-Host 'Quick is ephemeral and has no content cache' -ForegroundColor Cyan
Check-YakuDual (Test-Path -LiteralPath $quickArtifactPath -PathType Leaf) 'QuickArtifact implementation exists'
$quickArtifactSource = Read-YakuDualText $quickArtifactPath
Check-YakuDual ($quickArtifactSource -match '\$script:YakuQuickArtifacts|ConcurrentDictionary|Synchronized') 'QuickArtifact uses an in-memory store'
Check-YakuDual ($quickArtifactSource -match 'ExpiresAt|TtlSeconds|TTL') 'QuickArtifact has an explicit TTL'
Check-YakuDual ($quickArtifactSource -notmatch '(?i)WriteAllText|WriteAllLines|Set-Content|Add-Content|Out-File|Write-Yaku(?:Json|Text)Atomic|Save-YakuQuickArtifact') 'QuickArtifact has no disk writer'
Check-YakuDual ($translationSource -match 'DisableCache|CachePolicy' -and $server -match '(?s)/api/translate-text.*?(?:DisableCache|CachePolicy)') 'Quick translation explicitly disables content cache'
Check-YakuDual ($server -match 'if \(\$Kind -(?:eq ''quick''|in @\(''quick'',''quick_revise''\))\)[\s\S]{0,700}Add-Member -NotePropertyName ''diagnostics_level'' -NotePropertyValue ''standard''[\s\S]{0,300}full_text_diagnostics_enabled'' -NotePropertyValue \$false[\s\S]{0,300}YakuFullTextDiagnosticsEnabled = \$false') 'Quick and Quick revision override the settings object and content diagnostics even when the user setting is full'
$quickDiagnosticSettings = [pscustomobject]@{ diagnostics_level='full'; full_text_diagnostics_enabled=$true }
$quickDiagnosticSettings | Add-Member -NotePropertyName 'diagnostics_level' -NotePropertyValue 'standard' -Force
$quickDiagnosticSettings | Add-Member -NotePropertyName 'full_text_diagnostics_enabled' -NotePropertyValue $false -Force
Check-YakuDual ((Get-YakuDiagnosticsLevel -Settings $quickDiagnosticSettings) -eq 'standard') 'raw transport re-reading Quick settings cannot reactivate full-text diagnostics'
Check-YakuDual ($server -match 'ConvertTo-YakuQuickResultView|New-YakuQuickArtifact') 'Quick result is reduced before job publication'
$quickResultBlock = Get-YakuDualSlice -Text $server -Start 'function Convert-YakuQuickJobResultJson' -End 'function Serve-YakuIndex'
Check-YakuDual ($quickResultBlock -notmatch '(?m)^\s*(?:Raw|Prompt|Batches)\s*=') 'published Quick result excludes raw prompt/response/batches'
Check-YakuDual ($server -match 'Clear-YakuExpiredQuickArtifacts' -and $quickArtifactSource -match 'Clear-YakuExpiredQuickArtifacts') 'Quick artifacts are purged by TTL'

Write-Host 'Reuse is opt-in in CAT and absent from Quick' -ForegroundColor Cyan
$quickRoute = Get-YakuDualSlice -Text $server -Start "if (`$method -eq 'POST' -and `$path -eq '/api/quick/translate')" -End "if (`$method -eq 'GET' -and `$path -match '^/api/quick/jobs/"
$quickHasNoReusePolicy = ($quickRoute -match '(?i)(?:ReusePolicy\s+none|Experience\s+quick|Disable(?:Reuse|Corpus|PastExamples))')
Check-YakuDual $quickHasNoReusePolicy 'Quick route explicitly selects a no-reuse translation policy'
$translationHasNoReuseBranch = ($translationSource -match '(?i)(?:ReusePolicy|Experience).*(?:quick|none)' -and $translationSource -match '(?i)(?:quick|none).*(?:Find-YakuCorpusPairsByTerms|CorpusSection)')
Check-YakuDual $translationHasNoReuseBranch 'Quick production call graph has an explicit branch that cannot query corpus, TM, or past examples'
Check-YakuDual ($quickResultBlock -notmatch '(?i)Corpus(?:Reference|Section|Examples)|TranslationMemory|Past(?:Pairs|Examples)') 'Quick response contains no corpus, TM, or past-example field'
Check-YakuDual ($quickClient -notmatch '(?i)Corpus(?:Reference|Section|Examples)|TranslationMemory|Past(?:Pairs|Examples)|/api/cat/candidates') 'Quick UI has no reuse lookup or past-example surface'
Check-YakuDual (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'app.js')) -and $rendererSource -notmatch 'data-yaku-to-cat|data-yaku-shorten') 'legacy shared UI and DOM/base64 handoff are removed'
$catTranslateRoute = Get-YakuDualSlice -Text $server -Start "'translate' {" -End "'apply' {"
Check-YakuDual ($catTranslateRoute -notmatch '(?i)CorpusSection|CorpusExamples|PastPairs|ReferenceUsage') 'CAT translation request does not automatically inject a past example'

Write-Host 'CAT candidate provenance and explicit reference use' -ForegroundColor Cyan
$candidateRoute = Get-YakuDualSlice -Text $server -Start "'candidates' {" -End "'glossary-add' {"
Check-YakuDual ($candidateRoute -match '(?i)source_name' -and $candidateRoute -match '(?i)location' -and $candidateRoute -match '(?i)page' -and $candidateRoute -match '(?i)source_match_ratio' -and $candidateRoute -match '(?i)source' -and $candidateRoute -match '(?i)translation') 'candidate API returns normalized material, location, page, source, translation, and match basis'
Check-YakuDual ($translationMemorySource -match '(?i)origin_project_id' -and $translationMemorySource -match '(?i)origin_file_name' -and $translationMemorySource -match '(?i)origin_segment_id' -and $translationMemorySource -match '(?i)origin_location' -and $translationMemorySource -match '(?i)review_revision') 'self-confirmed translation persists its project, material, segment, location, and review revision'
Check-YakuDual ($translationMemorySource -match '(?i)source_hash' -and $translationMemorySource -match '(?i)target_hash' -and $translationMemorySource -match 'Test-YakuTranslationMemoryProvenance') 'self-confirmed candidate is content-bound and provenance-validated'
Check-YakuDual ($catClient -match '(?i)item\.source_name' -and $catClient -match '(?i)item\.location' -and $catClient -match '(?i)item\.page' -and $catClient -match 'item\.source' -and $catClient -match 'item\.translation') 'CAT candidate UI displays normalized material, location, page, source, and translation'
Check-YakuDual ($candidateRoute -notmatch 'Get-YakuCorpusSearchDir|Find-YakuCorpusPairs' -and $catClient -notmatch "item\.kind === 'corpus'") 'CAT candidates cannot revive a bundled or cached corpus'
Check-YakuDual ($catClient -match '(?i)reference_usage' -and $catClient -match '(?i)reference_id' -and $catClient -match '(?i)data-cat-reference-id') 'candidate insertion sends reference_id and displays reference_usage'
Check-YakuDual ($catClient -match "function renderRows\(\)[\s\S]*?el\('cat-candidates'\)\.hidden = true") 'candidate panel closes when its row leaves the current grid'
Check-YakuDual ($candidateRoute -match '(?i)reference_id' -and $server -match '(?i)Set-YakuCatSegmentReferenceUsage' -and $catProjectSource -match '(?i)ReferenceUsage') 'server persists reference_usage through the explicit segment mutation'
$activeUi = $landing + "`n" + $quickPage + "`n" + $catPage + "`n" + $client
Check-YakuDual ($activeUi -notmatch '(?i)(?:quality|translation|\u8a33|\u516c\u8868|\u78ba\u8a8d)[^\r\n]{0,40}100\s*[%\uff05]') 'active UI never presents 100 percent as translation quality'

Write-Host 'CAT client state and keyboard regression' -ForegroundColor Cyan
Check-YakuDual ($catClient -match 'scopeIsCurrent\(packet\.scope, true\)' -and $catClient -match 'data-cat-project-id' -and $catClient -match 'expected_revision') 'late saves stay bound to the starting project and revision'
Check-YakuDual ($catClient -match 'deleteTarget = currentScope\(\)' -and $catClient -match "post\('delete', \{ id: target\.id \}, true, target\)") 'delete confirmation stays bound to its displayed project'
Check-YakuDual ($catClient -match "type: 'translate', scope: jobScope" -and $catClient -match "post\('apply', \{ job_id: jobId \}, true, context\.scope\)") 'job apply stays bound to its starting project and revision'
Check-YakuDual ($catClient -match "event\.key === 'Enter'" -and $catClient -match '処理中は確認できません' -and $catClient -match 'function focusAfter\(index\)') 'Ctrl+Enter is guarded while busy and advances after confirmation'
Check-YakuDual ($catClient -match "bindFileDrop\(el\('cat-drop'\), el\('cat-file-input'\)\)" -and $catClient -match "event\.key === 'Enter' \|\| event\.key === ' '") 'file drop supports drag-drop and keyboard activation'
Check-YakuDual ($catClient -match 'data-cat-loss' -and $catClient -match '結合すると、対象行の訳文が消えます。結合しますか？' -and $catClient -match '解除すると、この行の訳文が消えます。解除しますか？') 'merge and split warn before discarding a translation'
Check-YakuDual ($catClient -match 'data\.review_blocked' -and $catClient -match 'var same = document\.querySelector') 'QC-blocked confirmation returns focus to the same row'
Check-YakuDual ($catClient -match 'function redrawAfterFlush\(\)[\s\S]*?return flush\(\)\.then' -and $catClient -match "button\.hasAttribute\('data-cat-filter'\)[\s\S]{0,180}redrawAfterFlush\(\)") 'filter redraw waits for the shared save barrier'

Write-Host 'CAT H1 focused workspace contract' -ForegroundColor Cyan
Check-YakuDual ($catPage -match 'cat-workspace\.css' -and $catPage -match 'id="cat-editor-toolbar"' -and $catPage -match 'id="cat-nav-pane"' -and $catPage -match 'id="cat-editor-pane"' -and $catPage -match 'id="cat-inspector-pane"') 'CAT uses one WebView workspace with sticky toolbar and three named regions'
Check-YakuDual ($catWorkspaceStyle -match '(?s)\.cat-editor-toolbar\s*\{[^}]*position:\s*sticky' -and $catWorkspaceStyle -match 'grid-template-columns:\s*220px\s+minmax\(560px,\s*1fr\)\s+380px') 'desktop CAT workspace has the approved sticky three-region layout'
Check-YakuDual ($catClient -match "activeSegmentId\s*=\s*''" -and $catClient -match 'data-cat-segment-id' -and $catClient -match 'String\(segment\.segment_id') 'active row survives redraws by stable segment_id'
Check-YakuDual ($catClient -match "esc\(segment\.location \|\| '本文'\)" -and $catClient -match 'function locationGroup\(segment\)') 'rows display the actual source location and navigation groups it locally'
Check-YakuDual ($catClient -match 'cat-candidate-number' -and $catClient -match 'itemIndex \+ 1' -and $catClient -match 'data-cat-reference-id') 'numbered candidate controls preserve explicit reference insertion'
Check-YakuDual ($catClient -match 'event\.isComposing' -and $catClient -match "event\.key === 'ArrowUp'" -and $catClient -match "event\.key\.toLowerCase\(\) === 'f'") 'keyboard navigation is IME-safe and exposes confirm, movement, candidate, and search paths'
Check-YakuDual ($catClient -match "currentFilter = 'all'" -and $catPage -match 'id="cat-complete-state"') 'completed projects show reviewed rows instead of an empty default grid'
Check-YakuDual ($catPage -match 'id="cat-export-dialog"' -and $catClient -match "post\('preflight', \{\}, true, requestScope\)" -and $catClient -match 'data\.project_id' -and $catClient -match 'Number\(data\.revision\) !== requestScope\.revision') 'DRAFT dialog uses the server preflight bound to the current project revision'
Check-YakuDual ($catPage -match 'data-cat-change="unchanged"' -and $catPage -match 'data-cat-change="changed"' -and $catPage -match 'data-cat-change="new"' -and $catClient -match 'changeGroup\(segment\)' -and $catClient -match 'segment\.prior_source') '3-way workspace exposes prior-same, changed, and new counts with previous/current context'
Check-YakuDual ($catClient -match 'data-cat-shorten' -and $catClient -match '修正結果を確認' -and $catClient -match 'data-cat-revert-revision' -and $catClient -match 'data-cat-accept-revision') 'CAT offers a dedicated shorten action with before/after review and revert controls'
Check-YakuDual ($catPage -match '数値・単位など' -and $catPage -match '表現の適切さは' -and $catClient -match '機械チェックで問題は見つかりません') 'CAT labels mechanical checks without implying translation quality approval'
Check-YakuDual ($catClient -match "el\('cat-export-dialog'\)\.addEventListener\('close'" -and $catClient -match 'scopeIsCurrent\(scope, true\)' -and $catClient -match 'exportProject\(\)') 'export runs only after an unchanged preflight scope is confirmed'

Write-Host 'QuickArtifact promotion contract' -ForegroundColor Cyan
$artifactFunctions = @('New-YakuQuickArtifact','Get-YakuQuickArtifact','Clear-YakuExpiredQuickArtifacts','Invoke-YakuQuickArtifactPromotion','New-YakuCatProjectFromQuickArtifact')
foreach ($fn in $artifactFunctions) {
    Check-YakuDual ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) ('QuickArtifact helper exists: ' + $fn)
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-dual-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
function Get-YakuCatProjectStoreDir { return $tempRoot }
try {
    $referenceProject = New-YakuCatProjectFromPairs -Pairs @([pscustomobject]@{ JaText='参照元の原文'; EnText='' }) -Direction to_en -FileName 'reference-usage-test' -Register:$false
    $referenceCandidate = [pscustomobject]@{
        ReferenceId = '0123456789abcdef'; SourceName = '前年度資料.docx'; Page = 7
        Source = '参照元の原文'; Target = 'Inserted translation.'
    }
    $null = Set-YakuCatSegmentTranslation -Project $referenceProject -Index 0 -Text ([string]$referenceCandidate.Target)
    $null = Set-YakuCatSegmentReferenceUsage -Project $referenceProject -Index 0 -Candidate $referenceCandidate
    $referenceView = (ConvertTo-YakuCatProjectJson -Project $referenceProject | ConvertFrom-Json)
    Check-YakuDual (-not [bool]$referenceView.segments[0].reference_usage.edited_after_insert) 'inserted example is initially recorded as not edited'
    $null = Set-YakuCatSegmentTranslation -Project $referenceProject -Index 0 -Text 'Edited translation.'
    Check-YakuDual ([bool]$referenceProject.Segments[0].ReferenceUsage.edited_after_insert) 'editing after insertion updates reference_usage'
    $referenceProject.Segments[0].ReferenceUsage.edited_after_insert = $false
    $null = Update-YakuCatSegmentReferenceEditState -Segment $referenceProject.Segments[0] -Text 'Copilot revised translation.'
    Check-YakuDual ([bool]$referenceProject.Segments[0].ReferenceUsage.edited_after_insert -and [string]$referenceProject.Segments[0].ReferenceUsage.source_name -eq '前年度資料.docx' -and [string]$referenceProject.Segments[0].ReferenceUsage.source -eq '参照元の原文' -and [string]$referenceProject.Segments[0].ReferenceUsage.translation -eq 'Inserted translation.') 'Copilot revision marks the inserted example edited without changing its provenance snapshot'
    $savedReference = Save-YakuCatProject -Project $referenceProject
    $script:YakuCatProjects.Remove([string]$referenceProject.Id)
    $restoredReference = Restore-YakuCatProject -Id ([string]$referenceProject.Id)
    Check-YakuDual ($savedReference -and [bool]$restoredReference.Segments[0].ReferenceUsage.edited_after_insert -and [string]$restoredReference.Segments[0].ReferenceUsage.source_name -eq '前年度資料.docx' -and [int]$restoredReference.Segments[0].ReferenceUsage.page -eq 7) 'reference_usage survives save and resume'

    $allArtifactFunctions = @($artifactFunctions | Where-Object { $null -ne (Get-Command $_ -ErrorAction SilentlyContinue) }).Count -eq $artifactFunctions.Count
    if ($allArtifactFunctions) {
        $sourceText = (-join @([char]0x58F2,[char]0x4E0A,[char]0x9AD8)) + "`n" + (-join @([char]0x55B6,[char]0x696D,[char]0x5229,[char]0x76CA))
        $targetText = 'Net sales and operating profit improved.'
        $filesBeforeArtifact = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -ErrorAction SilentlyContinue).Count
        $artifact = New-YakuQuickArtifact -JobId ([guid]::NewGuid().ToString('N')) -SourceText $sourceText -Direction to_en -TtlMinutes 30
        $artifact.Translation = $targetText
        $artifact.Status = 'ready'
        $artifactId = [string]$artifact.Id
        Check-YakuDual (-not [string]::IsNullOrWhiteSpace($artifactId)) 'QuickArtifact receives an opaque id'
        Check-YakuDual (@(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -ErrorAction SilentlyContinue).Count -eq $filesBeforeArtifact) 'creating a QuickArtifact writes no file'
        $operation = { param($innerArtifact,$innerRoot,$innerSettings) New-YakuCatProjectFromQuickArtifact -Root $innerRoot -Artifact $innerArtifact -Settings $innerSettings }
        $first = Invoke-YakuQuickArtifactPromotion -ArtifactId $artifactId -Operation $operation -Arguments @($root,[pscustomobject]@{})
        $second = Invoke-YakuQuickArtifactPromotion -ArtifactId $artifactId -Operation $operation -Arguments @($root,[pscustomobject]@{})
        $firstProject = if ($first.PSObject.Properties.Name -contains 'Project') { $first.Project } else { $first }
        $secondProject = if ($second.PSObject.Properties.Name -contains 'Project') { $second.Project } else { $second }
        Check-YakuDual ([string]$first.ProjectId -eq [string]$second.ProjectId -and [bool]$second.Reused) 'promotion is idempotent'
        Check-YakuDual (@($firstProject.Segments | Where-Object { [string]$_.State -eq 'reviewed' -or [bool]$_.Confirmed }).Count -eq 0) 'promotion never inherits reviewed state'
        $serialized = $firstProject | ConvertTo-Json -Depth 30 -Compress
        Check-YakuDual ($serialized.Contains($targetText)) 'split-mismatched draft is preserved instead of discarded'
        $eligibility = Get-YakuCatOutputEligibility -Project $firstProject
        Check-YakuDual (-not [bool]$eligibility.TranslationListEligible) 'promoted draft is output-blocked until review and current QC'

        $expiring = New-YakuQuickArtifact -JobId ([guid]::NewGuid().ToString('N')) -SourceText 'SAFE' -Direction to_en -TtlMinutes 1
        $expiringId = [string]$expiring.Id
        $expiring.ExpiresAtUtc = [datetime]::UtcNow.AddSeconds(-1)
        Clear-YakuExpiredQuickArtifacts
        Check-YakuDual ($null -eq (Get-YakuQuickArtifact -Id $expiringId)) 'expired QuickArtifact is unavailable'
    } else {
        Check-YakuDual $false 'dynamic promotion checks are pending QuickArtifact helpers'
    }
} finally {
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host 'User-facing reuse vocabulary and no classification input' -ForegroundColor Cyan
$normalUi = $landing + "`n" + $quickPage + "`n" + $catPage + "`n" + $client + "`n" + $rendererSource
$selfConfirmedPattern = '\u81ea\u5206\u304c\u78ba\u8a8d\u3057\u305f\u8a33'
$pastExamplePattern = '\u904e\u53bb\u306e\u7ffb\u8a33\u4f8b'
Check-YakuDual ($normalUi -match $selfConfirmedPattern) 'normal UI says self-confirmed translation'
Check-YakuDual ($normalUi -match $pastExamplePattern) 'normal UI says past translation example'
Check-YakuDual ($normalUi -notmatch '\u81ea\u5206\u306e\u8a33\s*100%|\u516c\u8868\u8a33\s*100%|Verified\s*=\s*\$true') 'normal UI has no 100-percent or Verified quality claim'
$allHtml = @($landingPath,$quickPagePath,$catPagePath) | ForEach-Object { Read-YakuDualText $_ }
$classificationMarkup = ($allHtml -join "`n")
Check-YakuDual ($classificationMarkup -notmatch '(?i)<(?:input|select|option)[^>]+(?:name|id|value)\s*=\s*[\x22\x27][^\x22\x27]*(?:public|internal|verified_release|verified_internal|prior_evidence|document_type)[^\x22\x27]*[\x22\x27]') 'production UI has no public/internal/document classification input'
Check-YakuDual ($client -notmatch '(?i)prior_evidence\s*:|verified_(?:release|internal)') 'browser payload cannot self-assert reuse classification'

Write-Host 'Numeric protection remains mandatory for both experiences' -ForegroundColor Cyan
$sensitive = 'Sales 1,234; phone 090-1234-5678; FY2027; date 2026/8/10.'
$masked = New-YakuNumericMaskMap -Text $sensitive -Root $root -Direction to_en -Location 'dual-experience-test'
Check-YakuDual (-not ([string]$masked.Text).Contains('1,234')) 'ordinary numeric value is masked'
Check-YakuDual (-not ([string]$masked.Text).Contains('090-1234-5678')) 'phone number is masked'
Check-YakuDual (-not ([string]$masked.Text).Contains('FY2027')) 'fiscal year number is masked'
Check-YakuDual (-not ([string]$masked.Text).Contains('2026/8/10')) 'date numbers are masked'
$packageSafe = $false
try {
    $package = New-YakuProtectedPromptPackage -Kind text -Root $root -Direction to_en `
        -Fields @([pscustomobject]@{ Name='source'; OriginalText=$sensitive; ProtectedText=[string]$masked.Text; NumericMaskMaps=@($masked.Map) }) `
        -Arguments ([pscustomobject]@{ Settings=[pscustomobject]@{}; Mode='full' })
    $packageSafe = -not ([string]$package.Prompt).Contains('1,234') -and -not ([string]$package.Prompt).Contains('090-1234-5678') -and -not ([string]$package.Prompt).Contains('FY2027') -and -not ([string]$package.Prompt).Contains('2026/8/10')
} catch { $packageSafe = $false }
Check-YakuDual $packageSafe 'canonical protected package contains no user numeric value'

Write-Host 'Cross-project machine cache is forbidden' -ForegroundColor Cyan
Check-YakuDual ($catBatchSource -notmatch '\bAdd-YakuFileTranslationsToCache\b|\bSet-YakuTranslationCacheValue\b') 'CAT machine drafts are not written to a cross-project cache'
$catWorker = Get-YakuDualSlice -Text $server -Start "if (`$Kind -eq 'cat')" -End "elseif (`$Kind -eq 'shorten')"
Check-YakuDual ($catWorker -notmatch '\bGet-YakuTranslationCacheValue\b|\bSet-YakuTranslationCacheValue\b') 'CAT worker does not read or write cross-project machine cache'
Check-YakuDual ($catProjectSource -match 'Find-YakuTranslationMemory' -and $catProjectSource -notmatch 'Find-YakuCorpusPairsForSegment') 'CAT exposes only self-confirmed translations as cross-project segment candidates'
Check-YakuDual ($server -match "requestedMode -eq 'corpus'[\s\S]{0,220}CAT_CORPUS_MODE_RETIRED" -and $server -match "result\.Mode -eq 'corpus'[\s\S]{0,220}CAT_CORPUS_MODE_RETIRED") 'retired corpus job cannot bypass explicit candidate insertion or persist hidden references'

if ($script:failed -gt 0) { throw ('Dual experience contract tests failed: ' + $script:failed) }
Write-Host 'V91.64 dual experience regression passed.' -ForegroundColor Green
