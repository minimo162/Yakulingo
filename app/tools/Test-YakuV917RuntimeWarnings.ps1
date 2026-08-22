param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [string]$JobLogPath = ''
)
$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]
$fileProcessors = Join-Path $Root 'src\FileProcessors.ps1'
$fileTranslation = Join-Path $Root 'src\CatBatch.ps1'
foreach ($path in @($fileProcessors, $fileTranslation)) {
    if (-not (Test-Path -LiteralPath $path)) { $failures.Add("missing source: $path") | Out-Null }
}
if ($failures.Count -eq 0) {
    $processorText = Get-Content -LiteralPath $fileProcessors -Raw -Encoding UTF8
    $translationText = Get-Content -LiteralPath $fileTranslation -Raw -Encoding UTF8
    if ($processorText.Contains('return $false }`n        $end')) { $failures.Add('literal backtick-n remains in Add-YakuAddressRangeToSet') | Out-Null }
    # 同梱CSVは廃止した。文中の用語監査を旧方式へ戻さず、セル完全一致は
    # 利用者が登録した管理対象用語だけを使う。
    if ($translationText -match 'glossary-conflict-review') { $failures.Add('in-sentence glossary conflict review must stay removed') | Out-Null }
    if ($translationText -match 'function Get-YakuFileGlossaryOccurrenceAudit') { $failures.Add('in-sentence glossary audit must stay removed') | Out-Null }
    if ($translationText -notmatch 'function Resolve-YakuFileExactGlossaryTranslations') { $failures.Add('cell-exact replacement (the layout guarantee) is missing') | Out-Null }
    if ($translationText -notmatch 'Find-YakuCellExactTerminologyMatch') { $failures.Add('cell-exact replacement must use governed user terminology') | Out-Null }
    if ($translationText -match 'Get-YakuGlossaryEntries') { $failures.Add('bundled glossary reader must not be reachable from CAT translation') | Out-Null }
}
if (-not [string]::IsNullOrWhiteSpace($JobLogPath)) {
    if (-not (Test-Path -LiteralPath $JobLogPath)) {
        $failures.Add("job log not found: $JobLogPath") | Out-Null
    } else {
        $logText = Get-Content -LiteralPath $JobLogPath -Raw -Encoding UTF8
        foreach ($pattern in @('認識されません', 'is not recognized')) {
            if ($logText.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $failures.Add("runtime recognition error found: $pattern") | Out-Null
            }
        }
    }
}
if ($failures.Count -gt 0) {
    throw ("V91.7 self-test failed:`n - " + ($failures.ToArray() -join "`n - "))
}
Write-Host 'V91.7 self-test passed.'
