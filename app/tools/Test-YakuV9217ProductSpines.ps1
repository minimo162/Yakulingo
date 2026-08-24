$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:YakuRoot=$root
. (Join-Path $root 'src\SrcModules.ps1')
foreach($name in $script:YakuSrcModuleFiles){. (Join-Path $root ('src\'+$name))}
$fail=0
function Check($condition,$message){if($condition){Write-Host ('ok '+$message)}else{$script:fail++;Write-Host ('not ok '+$message)}}

$source='売上高は1兆3,150億円だった。'
$oku=[string](Convert-YakuNumericUnits -Text $source -Notation oku).Text
$mask=New-YakuNumericMaskMap -Text $oku -Root $root -Direction to_en -Location test
$masked='Sales were ¥[[N1]] oku.'
$billion=Convert-YakuTranslationNotationLocal -Root $root -SourceText $source -MaskedTranslation $masked -Direction to_en -Notation billion
Check ($billion -match '1,315 billion') 'text notation toggles locally with magnitude conversion'
Check ((Convert-YakuRenderedAmountNotationLocal -Text 'Sales were 13,150 oku.' -SourceText $source -From oku -To billion) -match '1,315 billion') 'confirmed-pair notation toggles without Copilot'

$quick=Get-Content -LiteralPath (Join-Path $root 'www\quick.html') -Raw
$js=Get-Content -LiteralPath (Join-Path $root 'www\assets\quick-page.js') -Raw
Check ($quick.Contains('数字は送らない。訳はAIが推敲する。')) 'catch copy is visible'
Check ($quick.Contains('貼る → 数字を隠す → 訳す → コピー')) 'text spine names numeric masking explicitly'
Check ($quick.Contains('もっと短く') -and $quick.Contains('全文で') -and -not $quick.Contains('BRIEF')) 'one default plus two actions'
Check ($quick.Contains('data-quick-chip="full"') -and -not $quick.Contains('data-quick-chip="revise">全文で')) 'full action requests a source-based full translation'
Check ($js.Contains("input.addEventListener('paste'") -and $js.Contains("metric('copy_complete')") -and $js.Contains('edited_chars')) 'paste-to-copy time starts at paste and includes edit distance'
Check ($js.Contains("output.addEventListener('input', function () { setReview('', false)") -and $js.Contains('setReview(String(data.review_badge')) 'review badge is cleared on manual edit and refreshed after rewrites'
Check ($js.Contains('/api/palette/notation') -and $js.Contains('renderInCurrentNotation')) 'notation toggle and rewrites use local rendering'
Check (($js -split 'notation: notation').Count -ge 3) 'translation and both rewrite actions carry the selected notation'
$nodeCode="const fs=require('fs'),s=fs.readFileSync(process.argv[1],'utf8');const a=s.indexOf('function shiftNotationNumber'),b=s.indexOf('function metric',a);eval(s.slice(a,b));const edited='Adjusted sales were 100 oku, not forecast.';const billion=convertRenderedNotationLocal(edited,'oku','billion');const back=convertRenderedNotationLocal(billion,'billion','oku');if(billion!=='Adjusted sales were 10 billion yen, not forecast.'||back!==edited)process.exit(1);"
$null=& node -e $nodeCode (Join-Path $root 'www\assets\quick-page.js')
Check ($LASTEXITCODE -eq 0) 'notation toggle changes only amount notation and preserves edited wording'
Check (-not $js.Contains('output.value = String(data.translation); displayedBaseline = output.value')) 'notation toggle preserves the edit-distance baseline'

$server=Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw
$catProject=Get-Content -LiteralPath (Join-Path $root 'src\CatProject.ps1') -Raw
$productSpines=Get-Content -LiteralPath (Join-Path $root 'src\ProductSpines.ps1') -Raw
$catCss=Get-Content -LiteralPath (Join-Path $root 'www\assets\cat-workspace.css') -Raw
Check ($server.Contains("'notation' {") -and $server.Contains('Invoke-YakuTextAgenticReview')) 'server wires notation and agentic review'
Check ($server.Contains("-TextMode 'full'") -and $server.Contains('$Kind -ne ''cat''')) 'full action translates the source and every text result is reviewed'
Check (($server -split 'Add-Member -NotePropertyName amount_notation').Count -ge 3) 'palette requests override stale global notation with the visible selection'
Check ($catProject.Contains('legacy-glossary-confirmed-pair')) 'cell-exact is absorbed as a confirmed-pair source'
Check ($catProject.Contains('amount_notation = (Get-YakuCatProjectAmountNotation -Project $Project)')) 'project response remembers amount notation'
Check ($productSpines.Contains('New-YakuCopilotWorkerPages -Settings $Settings -Count 2') -and $productSpines.Contains("'meaning'") -and $productSpines.Contains("'readability'")) 'meaning and readability use isolated parallel lanes'
Check ($catCss.Contains('#premium-tools') -and $catCss.Contains('#cat-search-menu')) 'concepts outside the file spine stay hidden'
$catHtml=Get-Content -LiteralPath (Join-Path $root 'www\cat.html') -Raw
$catJs=Get-Content -LiteralPath (Join-Path $root 'www\assets\cat.js') -Raw
Check (-not $catHtml.Contains('<kbd>Alt</kbd>+<kbd>M</kbd>') -and -not $catHtml.Contains('<kbd>Ctrl</kbd>+<kbd>H</kbd>')) 'hidden merge split and replace concepts are absent from keyboard help'
Check (-not $catJs.Contains("event.key.toLowerCase() === 'h' && !el('cat-workspace').hidden") -and -not $catJs.Contains("event.key.toLowerCase() === 'm' || event.key.toLowerCase() === 'k'")) 'hidden concept shortcuts are disabled'
Check (Test-Path (Join-Path $root 'tools\Measure-YakuAgenticPrerequisites.ps1')) 'agentic prerequisite measurement is reproducible'

$projectId='11111111111111111111111111111111';$segmentId='22222222222222222222222222222222'
$entryA=New-YakuTerminologyEntry -Scope project -ProjectId $projectId -Kind cell_exact -JapanesePreferred '売上' -EnglishPreferred 'Sales' -OriginProjectId $projectId -OriginFileName 'a.xlsx' -OriginSegmentId $segmentId -OriginLocation 'A1'
$entryB=New-YakuTerminologyEntry -Scope project -ProjectId $projectId -Kind cell_exact -JapanesePreferred '売上' -EnglishPreferred 'Revenue' -OriginProjectId $projectId -OriginFileName 'b.xlsx' -OriginSegmentId $segmentId -OriginLocation 'A1'
$script:testCellExactEntries=@($entryA,$entryB)
function Get-YakuCatTerminologyEntries { @($script:testCellExactEntries) }
function Get-YakuCatTranslationMemoryExactMatch { [pscustomobject]@{Source='売上';Target='Turnover';Exact=$true} }
$testProject=[pscustomobject]@{Id=$projectId;Direction='to_en';Source='file';Segments=@([pscustomobject]@{Text='売上';Translation='';Origin='';State=''})}
$conflictClosed=$false
try { $null=Get-YakuCatTranslationMemoryPretranslatePlan -Project $testProject -Path '' } catch { $conflictClosed=([string]$_.Exception.Message -match 'TERMINOLOGY_CELL_EXACT_CONFLICT') }
Check $conflictClosed 'cell-exact conflict fails closed even when translation memory has a hit'
$productionConflictClosed=$false
try { $null=Invoke-YakuCatTranslationMemoryPass -Project $testProject -Path '' } catch { $productionConflictClosed=([string]$_.Exception.Message -match 'TERMINOLOGY_CELL_EXACT_CONFLICT') }
Check $productionConflictClosed 'production pretranslate caller propagates cell-exact conflict'
$script:testCellExactEntries=@($entryA)
function Get-YakuCatTranslationMemoryExactMatch { throw 'TM_UNREADABLE' }
$legacyPlan=Get-YakuCatTranslationMemoryPretranslatePlan -Project $testProject -Path ''
Check (@($legacyPlan.Rows).Count -eq 1 -and [string]$legacyPlan.Rows[0].Hit.Origin -eq 'legacy-glossary-confirmed-pair') 'valid cell-exact hit survives unavailable translation memory'
Check ([bool]$legacyPlan.MemoryUnavailable) 'unavailable translation memory remains observable beside cell-exact hit'
Check ($server.Contains('if ([string]$_.Exception.Message -match ''TERMINOLOGY_CELL_EXACT_CONFLICT'') { throw }')) 'estimate route propagates cell-exact conflict'
Check ($productSpines.Contains('$brevityApplicable') -and $productSpines.Contains('-not $brevityApplicable')) 'full translation treats the shortness axis as not applicable'

if($fail){Write-Host ('Product spine regression failed: '+$fail);exit 1}
Write-Host 'Product spine regression passed.'
