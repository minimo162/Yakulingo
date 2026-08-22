param([string]$Root = (Split-Path -Parent $PSScriptRoot), [string]$JobLog = '')
$path = Join-Path $Root 'src/FileProcessors.ps1'
$text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
$fail = New-Object System.Collections.Generic.List[string]
if ($text -match 'SpecialCells\(-4123\).*Address') { $fail.Add('SpecialCells.Address formula mask remains') | Out-Null }
if (-not $text.Contains('FormulaSet underreport blocked bulk write')) { $fail.Add('bulk execution HasFormula guard missing') | Out-Null }
if (-not $text.Contains("Category 'formula-set-underreport'")) { $fail.Add('formula-set-underreport warning missing') | Out-Null }
if (-not $text.Contains('Excel bulk plan aborted early')) { $fail.Add('restore-limit early abort missing') | Out-Null }
if (-not $text.Contains('msPerCell=')) { $fail.Add('msPerCell log missing') | Out-Null }
if (-not [string]::IsNullOrWhiteSpace($JobLog) -and (Test-Path -LiteralPath $JobLog)) {
  $log = Get-Content -LiteralPath $JobLog -Raw -Encoding UTF8
  if ($log -match 'OUTPUT_VALIDATION_FORMULA') { $fail.Add('job log contains OUTPUT_VALIDATION_FORMULA') | Out-Null }
}
if ($fail.Count -gt 0) { $fail | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Host 'V91.10 static bulk/formula guard checks passed.'
