param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$path = Join-Path $Root 'src/FileProcessors.ps1'
$text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
$fail = New-Object System.Collections.Generic.List[string]
if ($text.Contains('if ($hasFormulaCells -or $ForceFormulaPatch)')) { $fail.Add('ForceFormulaPatch still disables formula-free Value2 plans') | Out-Null }
if (-not $text.Contains('function Add-YakuExcelFormulaFreeColumnBandPlans')) { $fail.Add('formula-free column band splitter missing') | Out-Null }
if (-not $text.Contains('Excel writeback formula-free column band.')) { $fail.Add('formula-free band diagnostic log missing') | Out-Null }
if ($text.Contains('formula-patch-banded')) { $fail.Add('obsolete formula-patch-banded mode remains') | Out-Null }
if (-not $text.Contains("Mode = 'value2-banded'")) { $fail.Add('value2-banded mode missing') | Out-Null }
if ($fail.Count -gt 0) { $fail | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Host 'V91.17 static banded/formula-free checks passed.'
