$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Assert-YakuBatch {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $failures.Add($Message) | Out-Null }
}

$changed = @(
    'src\Translation.ps1','src\Review.ps1','src\Publication.ps1','src\CatProject.ps1',
    'src\Server.ps1','src\SourceRebase.ps1','src\FileProcessors.ps1','src\SheetLayout.ps1',
    'src\ProductSpines.ps1','src\CopilotClient.ps1','src\CellAlign.ps1','src\EdgeLaunch.ps1',
    'src\WordAdapter.ps1','src\Terminology.ps1'
)
foreach ($relative in $changed) {
    $path = Join-Path $appRoot $relative
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-YakuBatch (@($errors).Count -eq 0) ("PowerShell parse failed: " + $relative + " " + (@($errors | ForEach-Object Message) -join '; '))
}

. (Join-Path $appRoot 'src\Translation.ps1')
$shared = @{'[[N1]]'='138';'[[N2]]'='10.1'}
$protected = Protect-YakuPromptField -Text 'Q1 rev up [[N2]]% to [[N1]] oku' -Root $appRoot -Direction to_en -NumericMap $shared -Location 'issue-190' -AllowExistingTokens
Assert-YakuBatch ($protected -match '^Q\[\[N3\]\]') 'new raw number did not receive N3'
Assert-YakuBatch ($protected -match '\[\[N2\]\]% to \[\[N1\]\] oku$') 'existing numeric tokens were renamed'
Assert-YakuBatch ([string]$shared['[[N1]]'] -eq '138') 'N1 map entry changed'
Assert-YakuBatch ([string]$shared['[[N3]]'] -eq '1') 'new N3 map entry missing'

$review = Get-Content -LiteralPath (Join-Path $appRoot 'src\Review.ps1') -Raw
$publication = Get-Content -LiteralPath (Join-Path $appRoot 'src\Publication.ps1') -Raw
Assert-YakuBatch ($review -match "Replace\('\\u0027'") 'review JSON escape normalization missing'
Assert-YakuBatch ($publication -match "Replace\('\\u0027'") 'publication JSON escape normalization missing'

$catProject = Get-Content -LiteralPath (Join-Path $appRoot 'src\CatProject.ps1') -Raw
Assert-YakuBatch ($catProject -match "'fit-overflow'") 'fit-overflow warning code missing'
Assert-YakuBatch ($catProject -match "'acronym-inconsistency'") 'acronym-inconsistency warning code missing'
Assert-YakuBatch ($catProject -match 'ConvertTo-YakuCatValidIndexes') 'strict CAT index parser missing'
Assert-YakuBatch ($catProject -notmatch "'segment-not-reviewed'\s*=") 'retired segment-not-reviewed message remains'
$terminology = Get-Content -LiteralPath (Join-Path $appRoot 'src\Terminology.ps1') -Raw
Assert-YakuBatch ($terminology -match 'direction = \(\[string\]\$Direction\)') 'terminology direction is not persisted'

$server = Get-Content -LiteralPath (Join-Path $appRoot 'src\Server.ps1') -Raw
Assert-YakuBatch ($server -match 'New-YakuCatProtectedDocumentReviewRequest -Root \$script:YakuRoot') 'review preview still depends on dynamic Root scope'
Assert-YakuBatch ($server -match "mode'\] -notin @\('done','completed_with_warnings'\)") 'completed job can still be overwritten by cancel'
foreach ($retired in @('/api/download','/api/file-info','/api/direction-preview','/api/settings/amount-notation','/api/palette/instant','/api/palette/term-learn','/api/palette/abbreviations')) {
    Assert-YakuBatch ($server -notmatch [regex]::Escape("path -eq '$retired'")) ("retired route remains: " + $retired)
}

$quick = Get-Content -LiteralPath (Join-Path $appRoot 'www\assets\quick-page.js') -Raw
Assert-YakuBatch ($quick -match 'error\.status === 404') 'quick page does not terminate a missing job'
$catJs = Get-Content -LiteralPath (Join-Path $appRoot 'www\assets\cat.js') -Raw
Assert-YakuBatch ($catJs -notmatch 'candidates\(index\)') 'TM deletion still calls undefined candidates()'

$fileProcessors = Get-Content -LiteralPath (Join-Path $appRoot 'src\FileProcessors.ps1') -Raw
Assert-YakuBatch ($fileProcessors -match '__YAKU_READ_FAILED__') 'rich-text read failure sentinel missing'
Assert-YakuBatch ($fileProcessors -notmatch 'ForceFormulaPatch') 'retired formula patch switch remains'
Assert-YakuBatch ($fileProcessors -match 'YakuLingo: 未確認') 'Excel unconfirmed count metadata missing'
$word = Get-Content -LiteralPath (Join-Path $appRoot 'src\WordAdapter.ps1') -Raw
Assert-YakuBatch ($word -match 'YakuLingo: 未確認') 'Word unconfirmed count metadata missing'

if (Get-Command node -ErrorAction SilentlyContinue) {
    foreach ($js in @('www\assets\quick-page.js','www\assets\cat.js')) {
        & node --check (Join-Path $appRoot $js)
        Assert-YakuBatch ($LASTEXITCODE -eq 0) ("JavaScript parse failed: " + $js)
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host ("not ok - " + $_) }
    exit 1
}
Write-Host 'ok - issues 190-201 regression batch'
exit 0
