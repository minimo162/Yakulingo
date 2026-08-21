[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$srcRoot = Join-Path $appRoot 'src'
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('yakulingo-feature-pruning-' + [guid]::NewGuid().ToString('N'))
$oldDataDir = [string]$env:YAKULINGO_DATA_DIR
$script:passed = 0

function Assert-YakuFeature {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Feature pruning test failed: ' + $Message) }
    $script:passed++
    Write-Host ('PASS: ' + $Message)
}

function Get-YakuFeatureServerRouteBody {
    param([Parameter(Mandatory=$true)][string]$ServerPath,[Parameter(Mandatory=$true)][string]$Route)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ServerPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { return $null }
    foreach ($switchAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true))) {
        foreach ($clause in $switchAst.Clauses) {
            if ([string]$clause.Item1.Extent.Text -ne ("'" + $Route + "'")) { continue }
            $body = [string]$clause.Item2.Extent.Text
            if ($body.Length -lt 3 -or $body[0] -ne '{' -or $body[$body.Length - 1] -ne '}') { return $null }
            return $body.Substring(1, $body.Length - 2)
        }
    }
    return $null
}

$script:YakuFeatureRouteResponse = ''
function Send-YakuTextResponse {
    param($Context,[string]$Text,[string]$ContentType='',[int]$StatusCode=200,[switch]$AllowWasm)
    $script:YakuFeatureRouteResponse = [string]$Text
}
function Invoke-YakuFeatureServerRoute {
    param([Parameter(Mandatory=$true)][string]$BodyText)
    $script:YakuFeatureRouteResponse = ''
    . ([scriptblock]::Create($BodyText))
    return [string]$script:YakuFeatureRouteResponse
}

try {
    $env:YAKULINGO_DATA_DIR = Join-Path $tmpRoot 'data'
    $null = New-Item -ItemType Directory -Path $tmpRoot -Force
    . (Join-Path $srcRoot 'SrcModules.ps1')
    foreach ($name in @($script:YakuSrcModuleFiles)) {
        . (Join-Path $srcRoot $name)
    }

    $serverText = [IO.File]::ReadAllText((Join-Path $srcRoot 'Server.ps1'))
    Assert-YakuFeature ($serverText -match "'tm-register-bulk'" -and
        $serverText -match 'ExpectedRevision \$expectedRevision' -and
        $serverText -match 'Sync-YakuCatTranslationMemoryOutbox' -and
        $serverText -match 'tm_registered_count' -and
        $serverText -match 'tm_skipped_count' -and
        $serverText -match "tm-register-bulk'[\s\S]*?-NoCommitWhenNoMutation") 'bulk endpoint uses the revision, outbox, and no-op commit contracts'

    $catText = [IO.File]::ReadAllText((Join-Path $appRoot 'www\assets\cat.js'))
    Assert-YakuFeature ($catText -match 'function syncLocation\(projectId, preserveImport, preserveWork\)' -and
        $catText -match "preserveImport \? '/cat\?import=1' : preserveWork \? '/cat\?view=work' : '/'" -and
        $catText -notmatch "preserveImport \? '/cat\?import=1' : preserveWork \? '/cat\?view=work' : '/cat'") 'CAT start routes keep root, import, and work URLs'
    Assert-YakuFeature ($catText -match 'function showPicker\(preserveImport, preserveWork, refreshRecent\)' -and
        $catText -match 'if \(refreshRecent !== false\) loadRecent\(true\);' -and
        $catText -match 'function applyLocationFromUrl\(\)' -and
        $catText -match "var startSurface = !project && document\.body\.getAttribute\('data-cat-view'\) === 'start';" -and
        $catText -match 'var refreshRecent = !startSurface;' -and
        $catText -match "showPicker\(true, false, refreshRecent\)" -and
        $catText -match "showPicker\(false, true, refreshRecent\)" -and
        $catText -match "showPicker\(false, false, refreshRecent\)") 'CAT start-to-start history reuses recent while workspace exit refreshes it'
    Assert-YakuFeature ($catText -match 'var importMeta = document\.querySelector\(' -and
        $catText -match "if \(importMode\) \{ showPicker\(importMode\); showStart\('align'\); return; \}" -and
        $catText -match "if \(workMode\) \{ showPicker\(false, true\); return; \}" -and
        $catText -match 'retryPending = eligible === 0 && pending > 0' -and
        $catText -match '翻訳メモリへの反映を再試行') 'import/work startup and pending TM retry contracts are present'
    Assert-YakuFeature ($catText -match 'function navigateStart\(view\) \{\s*if \(busy\) return false;' -and
        $catText -match 'function restoreBusyHistory\(\)' -and
        $catText -match 'history\.go\(delta\)' -and
        $catText -match 'history\.replaceState\(historyStateFor' -and
        $catText -match 'pendingHistoryResume' -and
        $catText -match 'function resumeFromHistory\(id\)' -and
        $catText -match 'function rollbackPendingHistoryResume\(token\)' -and
        $catText -match 'if \(busy\) \{' -and
        $catText -match 'restoreBusyHistory\(\); return;') 'busy navigation restores the applied entry without stale CAT state'

    $repoRoot = Split-Path -Parent (Split-Path -Parent $appRoot)
    $retiredRuntimePaths = @(
        'src\Corpus.ps1', 'src\CorpusPairs.ps1', 'src\CorpusReference.ps1', 'src\CorpusSearch.ps1',
        'src\DesktopIntegration.ps1', 'prompts\corpus_query_to_en.txt',
        'www\admin.html', 'www\assets\admin.js', 'www\assets\tour.js',
        'www\assets\tutorial.css', 'www\assets\tutorial.js', 'www\tutorial.html'
    )
    $missingRetired = @($retiredRuntimePaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $appRoot $_)) })
    Assert-YakuFeature ($missingRetired.Count -eq $retiredRuntimePaths.Count) 'retired corpus, administrator, tutorial, and tour runtime files are absent'
    Assert-YakuFeature (@($script:YakuSrcModuleFiles | Where-Object { $_ -match '(?i)Corpus|DesktopIntegration' }).Count -eq 0) 'retired modules are absent from the exact source-module list'
    Assert-YakuFeature ($serverText -notmatch '(?i)corpus|save-corpus|/tutorial|desktopintegration') 'retired corpus and tutorial server routes are absent'
    $premiumText = [IO.File]::ReadAllText((Join-Path $appRoot 'www\assets\premium-ui.js'))
    Assert-YakuFeature ($premiumText -notmatch 'premium-settings|使い方|tour\.js|/tutorial') 'retired settings, help, and tour UI hooks are absent'
    Assert-YakuFeature ($premiumText -match 'event\.defaultPrevented' -and $premiumText -match 'event\.button !== 0' -and $premiumText -match 'hasAttribute\(''download''\)') 'CAT start interception preserves modified, target, and download navigation'
    $packageText = [IO.File]::ReadAllText((Join-Path $appRoot 'tools\New-YakuPackage.ps1'))
    $uploadText = [IO.File]::ReadAllText((Join-Path $repoRoot 'New-YakuUploadFolder.ps1'))
    Assert-YakuFeature ($packageText -match '(?i)corpus' -and $packageText -match '管理者用_コーパス作成' -and
        $uploadText -match '(?i)corpus' -and $uploadText -match '管理者用_コーパス作成') 'package and upload corpus safety bans remain'

    $makeSegment = {
        param([string]$Text, [string]$Translation, [string]$State, [bool]$Confirmed, [bool]$Registered)
        return [pscustomobject]@{
            SegmentId = ([guid]::NewGuid().ToString('N'))
            Text = $Text
            Translation = $Translation
            MaskedTranslation = ''
            Direction = 'to_en'
            Location = 'page 1'
            Page = 1
            Kind = 'text'
            State = $State
            Confirmed = $Confirmed
            TmRegistered = $Registered
            TmRegistrationEventId = ''
            SourceRevision = 1
            SourceIntegrityHash = ''
            QcStatus = 'not_run'
            QcSourceRevision = 0
            QcSourceHash = ''
            QcTargetHash = ''
            QcContractVersion = ''
            QcTerminologyHash = ''
            QcFindings = @()
            BlockIds = @()
            Cells = @()
        }
    }
    $segments = @(
        (& $makeSegment 'source eligible' 'English eligible' 'reviewed' $true $false),
        (& $makeSegment 'source unconfirmed' 'English unconfirmed' 'machine_draft' $false $false),
        (& $makeSegment 'source empty' '' 'reviewed' $true $false),
        (& $makeSegment 'source stale' 'English stale' 'reviewed' $true $false),
        (& $makeSegment 'source registered' 'English registered' 'reviewed' $true $true)
    )
    $project = [pscustomobject]@{
        Id = ([guid]::NewGuid().ToString('N'))
        Revision = 7
        SchemaVersion = 8
        Lifecycle = 'saved'
        RetentionUntil = ''
        FileName = 'alignment-fixture.pdf'
        Path = ''
        Source = 'align'
        Direction = 'to_en'
        Blocks = @()
        Segments = $segments
        TmOutbox = @()
        ReviewEvents = @()
        TerminologySnapshotHash = ''
    }
    $null = Initialize-YakuCatProjectState -Project $project
    $currentTerminologyHash = [string]$project.TerminologySnapshotHash
    foreach ($segment in @($project.Segments)) {
        $segment.State = 'reviewed'
        $segment.Confirmed = $true
        $segment.QcStatus = 'passed'
        $segment.QcSourceRevision = [int]$segment.SourceRevision
        $segment.QcSourceHash = Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Text)
        $segment.QcTargetHash = Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Translation)
        $segment.QcContractVersion = Get-YakuCatQcContractVersion
        $segment.QcTerminologyHash = $currentTerminologyHash
    }
    @($project.Segments)[1].State = 'machine_draft'
    @($project.Segments)[1].Confirmed = $false
    @($project.Segments)[3].QcSourceRevision = 0

    $nonAlign = Copy-YakuCatProjectForMutation -Project $project
    $nonAlign.Source = 'text'
    $nonAlignError = $false
    try { $null = Register-YakuCatAlignmentTranslationMemoryBulk -Project $nonAlign }
    catch { $nonAlignError = ([string]$_.Exception.Message -match 'CAT_TM_BULK_REQUIRES_ALIGN') }
    Assert-YakuFeature $nonAlignError 'bulk registration rejects non-align projects'

    $result = Register-YakuCatAlignmentTranslationMemoryBulk -Project $project
    Assert-YakuFeature ([int]$result.RegisteredCount -eq 1 -and [int]$result.SkippedCount -eq 4) 'bulk registration returns one eligible and four skipped rows'
    $reasons = @{}
    foreach ($item in @($result.Skipped)) { $reasons[[int]$item.index] = [string]$item.reason }
    $reasonSummary = (($reasons.GetEnumerator() | Sort-Object Name | ForEach-Object { [string]$_.Name + '=' + [string]$_.Value }) -join ',')
    Assert-YakuFeature ($reasons[1] -eq 'unconfirmed' -and $reasons[2] -eq 'empty' -and
        $reasons[3] -eq 'stale-qc' -and $reasons[4] -eq 'already-registered') ('bulk registration skips unconfirmed, empty, stale, and registered rows by reason (' + $reasonSummary + ')')
    Assert-YakuFeature (@($project.TmOutbox).Count -eq 1 -and [bool]@($project.Segments)[0].TmRegistered) 'eligible rows are marked and placed in the existing outbox'

    $pending = Sync-YakuCatTranslationMemoryOutbox -Project $project
    Assert-YakuFeature ([int]$pending -eq 0 -and @($project.TmOutbox).Count -eq 0) 'bulk registration synchronizes the outbox'
    $tmPath = Get-YakuTranslationMemoryPath -Direction 'to_en'
    Assert-YakuFeature (Test-Path -LiteralPath $tmPath -PathType Leaf) 'synchronized registration reaches the local translation memory'

    $second = Register-YakuCatAlignmentTranslationMemoryBulk -Project $project
    $secondSummary = (@($second.Skipped | ForEach-Object { [string]$_.index + '=' + [string]$_.reason }) -join ',')
    Assert-YakuFeature ([int]$second.RegisteredCount -eq 0 -and [int]$second.SkippedCount -eq 5 -and
        (@($second.Skipped | Where-Object { [string]$_.reason -eq 'already-registered' }).Count -ge 2)) ('repeating bulk registration does not register an eligible row twice (' + $secondSummary + ')')

    $routeBody = Get-YakuFeatureServerRouteBody -ServerPath (Join-Path $srcRoot 'Server.ps1') -Route 'tm-register-bulk'
    Assert-YakuFeature (-not [string]::IsNullOrWhiteSpace($routeBody)) 'HTTP bulk route body is extracted from Server.ps1'
    $boundaryProject = Copy-YakuCatProjectForMutation -Project $project
    $boundarySegment = @($boundaryProject.Segments)[0]
    $boundarySegment.TmRegistered = $false
    $boundarySegment.TmRegistrationEventId = ''
    $boundaryProject.TmOutbox = @()
    $boundaryProject.ReviewEvents = @($boundaryProject.ReviewEvents | Where-Object { [string]$_.decision_scope -ne 'translation_memory' -or [string]$_.action -ne 'registered' })
    # The fixture above was intentionally kept in memory for the direct helper
    # checks.  Seed this HTTP-boundary copy as a new persisted project so the
    # first route call has a real manifest/generation to compare against.
    $boundaryProject.Revision = 0
    $boundaryProject.ActiveGenerationId = ''
    $boundaryProject = Commit-YakuNewCatProject -Project $boundaryProject
    $script:YakuRoot = $appRoot
    $Context = $null
    $payload = @{}
    $project = $boundaryProject
    $expectedRevision = [int]$project.Revision
    $firstRoute = (Invoke-YakuFeatureServerRoute -BodyText $routeBody) | ConvertFrom-Json
    Assert-YakuFeature ([int]$firstRoute.tm_registered_count -eq 1 -and [int]$firstRoute.revision -eq $expectedRevision + 1) 'HTTP bulk route commits the first eligible row once'
    $project = Get-YakuCatProject -Id ([string]$boundaryProject.Id)
    $expectedRevision = [int]$project.Revision
    $manifestPath = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) ([string]$project.Id)) 'project.json'
    $beforeSecondManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $secondRoute = (Invoke-YakuFeatureServerRoute -BodyText $routeBody) | ConvertFrom-Json
    $afterSecondManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-YakuFeature ([int]$secondRoute.tm_registered_count -eq 0 -and [int]$secondRoute.tm_bulk_eligible_count -eq 0 -and
        [int]$secondRoute.revision -eq $expectedRevision -and
        [int]$afterSecondManifest.revision -eq [int]$beforeSecondManifest.revision -and
        [string]$afterSecondManifest.generation_id -eq [string]$beforeSecondManifest.generation_id -and
        [string]$afterSecondManifest.active_generation_id -eq [string]$beforeSecondManifest.active_generation_id) 'HTTP eligible-0 retry leaves revision and active generation unchanged'

    $pendingEvent = [pscustomobject]@{
        event_id = ([guid]::NewGuid().ToString('N'))
        source = 'pending retry source'
        target = 'pending retry target'
        direction = 'to_en'
        origin_project_id = [string]$project.Id
        origin_file_name = [string]$project.FileName
        origin_segment_id = [string]@($project.Segments)[0].SegmentId
        origin_location = 'page 1'
        origin_page = 1
        review_revision = [int]$project.Revision
        created = (Get-Date).ToString('s')
    }
    $project.TmOutbox = @($pendingEvent)
    $project | Add-Member -NotePropertyName TmPendingCount -NotePropertyValue 1 -Force
    $beforePendingRetryManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pendingRetryRoute = (Invoke-YakuFeatureServerRoute -BodyText $routeBody) | ConvertFrom-Json
    $afterPendingRetryManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-YakuFeature ([int]$pendingRetryRoute.tm_pending -eq 0 -and
        [int]$pendingRetryRoute.revision -eq [int]$beforePendingRetryManifest.revision -and
        [string]$afterPendingRetryManifest.generation_id -eq [string]$beforePendingRetryManifest.generation_id -and
        [string]$afterPendingRetryManifest.active_generation_id -eq [string]$beforePendingRetryManifest.active_generation_id) 'HTTP pending TM retry synchronizes the outbox without advancing revision or generation'

    Write-Host ('Feature pruning and bulk TM tests passed: ' + $script:passed) -ForegroundColor Green
} finally {
    if ([string]::IsNullOrWhiteSpace($oldDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $oldDataDir }
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
