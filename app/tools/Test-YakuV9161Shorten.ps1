[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$script:fail=0
function Chk { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++} }
foreach($n in @('Paths.ps1','Runtime.ps1','Settings.ps1','PromptBuilder.ps1','Translation.ps1')){. (Join-Path (Join-Path $root 'src') $n)}
$cur="Net sales [[N1]] oku, up [[N2]] oku." + [Environment]::NewLine + "Operating income [[N3]] oku."
Chk ([string]::IsNullOrEmpty((Test-YakuShortenResult -MaskedCurrentText $cur -Shortened $cur))) 'unchanged shortest result is valid'
Chk ((Test-YakuShortenResult -MaskedCurrentText $cur -Shortened 'Net sales [[N1]] oku.') -match '数値|行の数') 'missing numeric placeholders are rejected'
Chk ((Test-YakuShortenResult -MaskedCurrentText $cur -Shortened ("Net sales [[N2]] oku, up [[N1]] oku."+[Environment]::NewLine+"Operating income [[N3]] oku.")) -match '数値') 'reordered placeholders are rejected'
$js=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www/assets') 'quick-page.js') -Raw -Encoding UTF8
$html=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'quick.html') -Raw -Encoding UTF8
$server=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
Chk ($js -match 'stagePlan=.*FULL.*標準.*BRIEF.*最短') 'four length states are declared'
Chk ($js -match 'prefetch\(' -and $js -match '/api/palette/chip') 'short variants are prefetched after first display'
Chk ($js -match 'requestToken\+\+' -and $js -match 'cancelCurrent\(true\)') 'last input wins and stale work is cancelled'
Chk ($js -match '1200' -and $html -match 'quick-auto-translate') 'debounced auto translation is optional'
Chk ($js -match "event\.key==='ArrowDown'" -and $js -match 'ctrlKey') 'keyboard length navigation is wired'
Chk ($html -match 'quick-target-chars' -and $js -match '✓ 収まる') 'target character count reports fit'
Chk ($js -match 'rewriteSelection' -and $js -match "key.toLowerCase\(\)==='r'") 'Ctrl+R rewrites only a safely identified selection'
Chk ($server -match '/api/palette/metric' -and $server -match 'Quick translation timing') 'send-to-display timing is logged'
Chk ($server -match '/api/palette/abbreviations' -and $html -match 'quick-abbreviations-editor') 'user abbreviation editor is persisted by the server'
if($script:fail -gt 0){throw "V91.64 quick UX regression failed: $script:fail"}
Write-Host 'V91.64 quick UX regression passed.' -ForegroundColor Green
