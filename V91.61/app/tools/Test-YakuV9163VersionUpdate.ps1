<# .SYNOPSIS Horizon 2 prior-version reuse regression. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0
function Check-YakuVersionUpdate { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:failed++} }
foreach($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','PromptBuilder.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1','VersionUpdate.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('yaku-version-update-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tempRoot -Force
function Get-YakuCatProjectStoreDir { return $tempRoot }
try {
    Write-Host 'Verified prior version reuses only unchanged Japanese' -ForegroundColor Cyan
    $priorJa="売上高は100百万円でした。`n営業利益は20百万円でした。`n従業員数は300人です。"
    $priorEn="Net sales were 100 million yen.`nOperating income was 20 million yen.`nThe number of employees was 300."
    $currentJa="売上高は100百万円でした。`n営業損益は25百万円でした。`n従業員数は300人です。"
    $project=New-YakuCatProjectFromPriorVersion -CurrentJa $currentJa -PriorJa $priorJa -PriorEn $priorEn -PriorEvidence verified_release -DocumentName 'Q1 update'
    $segs=@($project.Segments)
    Check-YakuVersionUpdate ($segs.Count -eq 3 -and [string]$segs[0].Origin -eq 'carried_forward' -and [string]$segs[2].Origin -eq 'carried_forward') 'unchanged paragraphs carry the prior English verbatim'
    Check-YakuVersionUpdate ([string]$segs[1].Translation -eq '' -and [string]$segs[1].ChangeKind -eq 'changed' -and [string]$segs[1].PriorTranslation -eq 'Operating income was 20 million yen.') 'changed paragraph stays untranslated with prior context'
    Check-YakuVersionUpdate (@($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count -eq 1) 'only changed content remains for translation'
    Check-YakuVersionUpdate (@($segs | Where-Object { [string]$_.State -eq 'reviewed' }).Count -eq 0 -and @($segs | Where-Object { [bool]$_.Confirmed }).Count -eq 0) 'carried translations do not inherit review or approval'
    $null=Set-YakuCatSegmentConfirmed -Project $project -Index 0
    Check-YakuVersionUpdate ([string]$segs[0].State -eq 'reviewed' -and [string]$segs[0].QcStatus -eq 'passed') 'carried translation passes current QC only when reviewed now'

    Write-Host 'Provenance, persistence, and first-year fallback' -ForegroundColor Cyan
    Check-YakuVersionUpdate (Save-YakuCatProject -Project $project) 'version-update project persists'
    $savedId=[string]$project.Id
    Remove-YakuCatProject -Id $savedId
    $restored=Restore-YakuCatProject -Id $savedId
    Check-YakuVersionUpdate ([string]$restored.PriorVersion.ContractVersion -eq 'version-update-v2' -and [int]$restored.VersionUpdateSummary.CarriedForward -eq 2) 'baseline hashes and reuse summary survive restart'
    Check-YakuVersionUpdate ([string]@($restored.Segments)[1].PriorTranslation -eq 'Operating income was 20 million yen.' -and [string]@($restored.Segments)[1].ChangeKind -eq 'changed') 'segment-level prior context survives restart'

    $reference=New-YakuCatProjectFromPriorVersion -CurrentJa $currentJa -PriorJa $priorJa -PriorEn $priorEn -PriorEvidence reference_only
    Check-YakuVersionUpdate (@($reference.Segments | Where-Object { [string]$_.Origin -eq 'carried_forward' }).Count -eq 0 -and [int]$reference.VersionUpdateSummary.ReferenceOnly -eq 2) 'unverified prior English is reference-only and never auto-reused'
    $priorCandidates=@(Get-YakuCatSegmentCandidates -Root $root -Project $reference -Index 1)
    $priorCandidate=@($priorCandidates | Where-Object { [string]$_.Kind -eq 'prior' })[0]
    Check-YakuVersionUpdate ($null -ne $priorCandidate -and [string]$priorCandidate.Source -eq '営業利益は20百万円でした。' -and
        [string]$priorCandidate.Target -eq 'Operating income was 20 million yen.' -and
        [string]$priorCandidate.SourceName -match '前回版' -and [string]$priorCandidate.Location -eq '前回版 段落 2' -and
        -not [string]::IsNullOrWhiteSpace([string]$priorCandidate.ReferenceId)) 'reference-only prior English is an explicit provenance-bound CAT candidate'
    $null=Set-YakuCatSegmentTranslation -Project $reference -Index 1 -Text ([string]$priorCandidate.Target)
    $null=Set-YakuCatSegmentReferenceUsage -Project $reference -Index 1 -Candidate $priorCandidate
    Check-YakuVersionUpdate ([string]$reference.Segments[1].ReferenceUsage.kind -eq 'prior' -and
        [string]$reference.Segments[1].ReferenceUsage.source_name -match '前回版' -and
        [string]$reference.Segments[1].ReferenceUsage.location -eq '前回版 段落 2') 'explicit prior insertion records the exact prior material and location used'
    $mismatch=New-YakuCatProjectFromPriorVersion -CurrentJa $currentJa -PriorJa $priorJa -PriorEn "Only one prior English paragraph." -PriorEvidence verified_release
    Check-YakuVersionUpdate (-not [bool]$mismatch.PriorVersion.BaselineAligned -and @($mismatch.Segments | Where-Object { [string]$_.Origin -eq 'carried_forward' }).Count -eq 0) 'paragraph-count mismatch disables automatic reuse fail-closed'
    $firstYear=New-YakuCatProjectFromPriorVersion -CurrentJa $currentJa -PriorJa '' -PriorEn '' -PriorEvidence none
    Check-YakuVersionUpdate ([int]$firstYear.VersionUpdateSummary.CarriedForward -eq 0 -and @($firstYear.Segments | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count -eq 3) 'first year without prior assets enters normal full translation'

    Write-Host 'Strict local numeric update' -ForegroundColor Cyan
    $numeric=New-YakuCatProjectFromPriorVersion -CurrentJa '売上高は120百万円でした。' -PriorJa '売上高は100百万円でした。' -PriorEn 'Net sales were 100 million yen.' -PriorEvidence verified_release
    Check-YakuVersionUpdate ([string]$numeric.Segments[0].Translation -eq 'Net sales were 120 million yen.' -and [string]$numeric.Segments[0].ChangeKind -eq 'numeric_updated') 'numeric-only change updates the prior English locally without rewriting its style'
    Check-YakuVersionUpdate ([string]$numeric.Segments[0].Origin -eq 'numeric_update' -and [string]$numeric.Segments[0].State -eq 'machine_draft' -and -not [bool]$numeric.Segments[0].Confirmed) 'local numeric update remains an unreviewed draft'
    $null=Set-YakuCatSegmentConfirmed -Project $numeric -Index 0
    $numericOutput=Export-YakuCatProject -Project $numeric -OutputPath '' -Settings $null
    Check-YakuVersionUpdate ([string]$numericOutput.Text -eq 'Net sales were 120 million yen.') 'reviewed prior-version project exports a translation list'
    $unsafeNumeric=New-YakuCatProjectFromPriorVersion -CurrentJa '営業利益は120百万円でした。' -PriorJa '売上高は100百万円でした。' -PriorEn 'Net sales were 100 million yen.' -PriorEvidence verified_release
    Check-YakuVersionUpdate ([string]::IsNullOrWhiteSpace([string]$unsafeNumeric.Segments[0].Translation) -and [string]$unsafeNumeric.Segments[0].ChangeKind -eq 'changed') 'text plus numeric change never uses the numeric-only fast path'

    $server=[IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
    $ui=[IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'cat.html'))
    $client=[IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'cat.js'))
    Check-YakuVersionUpdate ($server -match "from-prior-version" -and $ui -match '前回の資料をもとに、今回の分だけ訳す' -and $client -match '/api/cat/') 'API and user entry are connected'

    Write-Host 'HTTP paste cannot self-assert approval evidence' -ForegroundColor Cyan
    $routeStart=$server.IndexOf("if (`$action -eq 'from-prior-version')",[StringComparison]::Ordinal)
    $routeEnd=if($routeStart -ge 0){$server.IndexOf("if (`$action -eq 'recent')",$routeStart,[StringComparison]::Ordinal)}else{-1}
    $priorRoute=if($routeStart -ge 0 -and $routeEnd -gt $routeStart){$server.Substring($routeStart,$routeEnd-$routeStart)}else{''}
    Check-YakuVersionUpdate (-not [string]::IsNullOrWhiteSpace($priorRoute)) 'prior-version HTTP route is found for authority inspection'
    Check-YakuVersionUpdate ($priorRoute -notmatch 'payload\s*\[\s*[''"]prior_evidence[''"]\s*\]') `
        'HTTP verified_release/verified_internal claims are not read as reuse authority'
    Check-YakuVersionUpdate ($priorRoute -match '-PriorEvidence\s+(?:[''"]reference_only[''"]|reference_only\b)') `
        'pasted prior bilingual text is forced to reference_only at the HTTP boundary'
    Check-YakuVersionUpdate ($ui -notmatch 'cat-prior-evidence|value="verified_(?:release|internal)"' -and $client -notmatch 'prior_evidence\s*:') `
        'browser UI cannot submit a self-declared approval classification'

    foreach($forgedClaim in @('verified_release','verified_internal')){
        # The public HTTP contract intentionally discards forgedClaim.  Exercise
        # the exact downstream value that the route is required to pass.
        $pastedReference=New-YakuCatProjectFromPriorVersion -CurrentJa $priorJa -PriorJa $priorJa -PriorEn $priorEn `
            -PriorEvidence reference_only -DocumentName ('forged-'+$forgedClaim)
        Check-YakuVersionUpdate (-not [bool]$pastedReference.PriorVersion.AutomaticReuseAllowed -and
            @($pastedReference.Segments | Where-Object { [string]$_.Origin -in @('carried_forward','numeric_update') }).Count -eq 0 -and
            [int]$pastedReference.VersionUpdateSummary.ReferenceOnly -eq 3) `
            ('HTTP '+$forgedClaim+' claim is downgraded to reference_only and cannot auto-reuse')
    }

    $httpFirstYear=New-YakuCatProjectFromPriorVersion -CurrentJa $currentJa -PriorJa '' -PriorEn '' -PriorEvidence none -DocumentName 'first-year-http'
    Check-YakuVersionUpdate ([int]$httpFirstYear.VersionUpdateSummary.CarriedForward -eq 0 -and
        [int]$httpFirstYear.VersionUpdateSummary.NumericUpdated -eq 0 -and
        @($httpFirstYear.Segments | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count -eq 0) `
        'first-year HTTP flow without prior material keeps every segment for full translation'
} finally {
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
if($script:failed -gt 0){throw ("Version update tests failed: $script:failed")}
Write-Host 'V91.63 version update regression passed.' -ForegroundColor Green
