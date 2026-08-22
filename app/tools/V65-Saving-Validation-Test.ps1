param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

foreach ($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','EdgeLaunch.ps1','CopilotClient.ps1','FileProcessors.ps1','CatBatch.ps1')) {
    . (Join-Path $root ('src\' + $name))
}

function Add-YakuTestZipTextEntry {
    param(
        [Parameter(Mandatory=$true)]$Archive,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Text
    )
    $entry = $Archive.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Fastest)
    $stream = $entry.Open()
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    try { $writer.Write($Text) }
    finally { $writer.Dispose(); $stream.Dispose() }
}

function New-YakuSparseFormulaTestBook {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][string]$SecondFormula = 'A1+2'
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $file = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $archive = [System.IO.Compression.ZipArchive]::new($file, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        Add-YakuTestZipTextEntry -Archive $archive -Name 'xl/workbook.xml' -Text '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="Sparse" sheetId="1"/></sheets></workbook>'
        $xml = New-Object System.Text.StringBuilder
        [void]$xml.Append('<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
        for ($i = 1; $i -le 40000; $i++) {
            [void]$xml.Append('<row r="').Append($i).Append('"><c r="A').Append($i).Append('"><v>').Append($i).Append('</v></c>')
            if ($i -eq 5) { [void]$xml.Append('<c r="B5"><f>A1+1</f><v>2</v></c>') }
            if ($i -eq 39995) { [void]$xml.Append('<c r="B39995"><f>').Append($SecondFormula).Append('</f><v>3</v></c>') }
            [void]$xml.Append('</row>')
        }
        [void]$xml.Append('</sheetData></worksheet>')
        Add-YakuTestZipTextEntry -Archive $archive -Name 'xl/worksheets/sheet1.xml' -Text $xml.ToString()
    } finally { $archive.Dispose(); $file.Dispose() }
}

$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yakulingo-v65-saving-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
try {
    $original = Join-Path $testDir 'original.xlsx'
    $changed = Join-Path $testDir 'changed.xlsx'
    New-YakuSparseFormulaTestBook -Path $original -SecondFormula 'A1+2'
    New-YakuSparseFormulaTestBook -Path $changed -SecondFormula 'A1+3'

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $before = Get-YakuOpenXmlIntegritySnapshot -Path $original
    $watch.Stop()
    if ($before.FormulaCount -ne 2) { throw "Expected 2 formulas, received $($before.FormulaCount)." }
    if (@($before.SheetNames).Count -ne 1 -or [string]$before.SheetNames[0] -ne 'Sparse') { throw 'Sheet-name snapshot failed.' }
    if ($watch.Elapsed.TotalSeconds -gt 30) { throw "Sparse formula scan exceeded 30 seconds: $($watch.Elapsed.TotalSeconds)." }

    $after = Get-YakuOpenXmlIntegritySnapshot -Path $changed
    if ($before.FormulaSha256 -eq $after.FormulaSha256) { throw 'Formula modification was not detected.' }
    Write-Host ("V65 saving validation test passed. elapsed={0:N2}s" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
