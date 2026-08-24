[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$oldData=[string]$env:YAKULINGO_DATA_DIR
$temp=Join-Path ([IO.Path]::GetTempPath()) ('yaku-v9164-brief-'+[guid]::NewGuid().ToString('N'))
$env:YAKULINGO_DATA_DIR=$temp
$script:fail=0
function Chk { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++} }
try {
  foreach($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1')){. (Join-Path (Join-Path $root 'src') $n)}
  Write-Host 'Default is disabled' -ForegroundColor Cyan
  $default=Get-YakuBriefAbbreviationPreferences
  Chk (-not [bool]$default.enabled) 'user abbreviation replacement is off by default'
  Chk ((Convert-YakuBriefAbbreviations -Text 'operating profit approximately [[N1]] oku') -eq 'operating profit approximately [[N1]] oku') 'default does not rewrite output'

  Write-Host 'User dictionary' -ForegroundColor Cyan
  $saved=Save-YakuBriefAbbreviationPreferences -Enabled $true -Entries @(
    [pscustomobject]@{from='operating profit';to='OP'},
    [pscustomobject]@{from='approximately';to='approx.'}
  )
  Chk ([bool]$saved.enabled -and @($saved.entries).Count -eq 2) 'saves only user-approved entries'
  Chk ((Convert-YakuBriefAbbreviations -Text 'Operating profit approximately [[N1]] oku') -eq 'OP approx. [[N1]] oku') 'applies approved entries deterministically'
  Chk ((Convert-YakuBriefAbbreviations -Text 'He said "operating profit" was flat.') -eq 'He said "operating profit" was flat.') 'does not rewrite quotations'
  Chk ((Convert-YakuBriefAbbreviations -Text 'approximately [[N1]] and [[N2]]') -eq 'approx. [[N1]] and [[N2]]') 'preserves numeric placeholders'
  Chk ((Get-YakuBriefAbbreviationPreferencePath).StartsWith((Get-YakuDataDir),[StringComparison]::OrdinalIgnoreCase)) 'stores preferences below the local YakuLingo data directory'

  Write-Host 'Prompt is generic' -ForegroundColor Cyan
  $rules=Get-Content -LiteralPath (Join-Path (Join-Path $root 'prompts') 'style_brief_rules.txt') -Raw -Encoding UTF8
  $template=Get-Content -LiteralPath (Join-Path (Join-Path $root 'prompts') 'text_translate_brief_to_en.txt') -Raw -Encoding UTF8
  Chk ($rules -match 'every numeric placeholder') 'numeric absolute rule remains'
  Chk ($rules -notmatch 'Fixed MKT|AIST|VM /|1H operating profit') 'niche rules and fixed examples are absent'
  Chk ($template -notmatch 'EXAMPLES|1H営業利益|Fixed MKT') 'static few-shot examples are absent'
  Chk ($template -match 'Do not invent abbreviations') 'model does not invent dictionary entries'
} finally {
  if($oldData){$env:YAKULINGO_DATA_DIR=$oldData}else{Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
if($script:fail -gt 0){throw "V91.64 brief preference regression failed: $script:fail"}
Write-Host 'V91.64 brief preference regression passed.' -ForegroundColor Green
