param(
    [Parameter(Mandatory=$true, Position=0)][string]$InputPath,
    [Parameter(Mandatory=$true, Position=1)][string]$OutputPath,
    [string]$CsvPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-FormulaMap {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $map = @{}
        foreach ($entry in @($archive.Entries | Where-Object { $_.FullName -match '^xl/(?:worksheets|macrosheets)/[^/]+\.xml$' })) {
            $stream = $null; $reader = $null
            try {
                $settings = New-Object System.Xml.XmlReaderSettings
                $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                $settings.XmlResolver = $null
                $settings.IgnoreWhitespace = $true
                $stream = $entry.Open()
                $reader = [System.Xml.XmlReader]::Create($stream, $settings)
                $cell = ''
                while ($reader.Read()) {
                    if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                    if ($reader.LocalName -eq 'c') { $cell = [string]$reader.GetAttribute('r'); continue }
                    if ($reader.LocalName -ne 'f') { continue }
                    $t = [string]$reader.GetAttribute('t'); $si = [string]$reader.GetAttribute('si'); $ref = [string]$reader.GetAttribute('ref')
                    $formula = if ($reader.IsEmptyElement) { '' } else { [string]$reader.ReadElementContentAsString() }
                    $key = ([string]$entry.FullName) + '!' + $cell
                    $map[$key] = [pscustomobject]@{ Location=$key; Formula=$formula; Type=$t; SharedIndex=$si; Ref=$ref }
                }
            } finally {
                if ($null -ne $reader) { $reader.Dispose() }
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
        return $map
    } finally { $archive.Dispose() }
}

$before = Get-FormulaMap -Path $InputPath
$after = Get-FormulaMap -Path $OutputPath
$rows = New-Object System.Collections.Generic.List[object]
foreach ($key in @($before.Keys + $after.Keys | Sort-Object -Unique)) {
    $b = $before[$key]; $a = $after[$key]
    $bf = if ($null -ne $b) { [string]$b.Formula } else { '<missing>' }
    $af = if ($null -ne $a) { [string]$a.Formula } else { '<missing>' }
    if ($bf -eq $af -and [string]$b.Type -eq [string]$a.Type -and [string]$b.SharedIndex -eq [string]$a.SharedIndex -and [string]$b.Ref -eq [string]$a.Ref) { continue }
    $kind = if ($null -ne $b -and $null -eq $a) { 'missing-output' } elseif ($null -eq $b -and $null -ne $a) { 'added-output' } else { 'modified' }
    $rows.Add([pscustomobject]@{
        Location=$key; Difference=$kind; InputFormula=$bf; OutputFormula=$af
        InputType=if($b){$b.Type}else{''}; OutputType=if($a){$a.Type}else{''}
        InputSharedIndex=if($b){$b.SharedIndex}else{''}; OutputSharedIndex=if($a){$a.SharedIndex}else{''}
        InputRef=if($b){$b.Ref}else{''}; OutputRef=if($a){$a.Ref}else{''}
    }) | Out-Null
}

$result = @($rows.ToArray())
Write-Host ("Input formulas : {0}" -f $before.Count)
Write-Host ("Output formulas: {0}" -f $after.Count)
Write-Host ("Differences    : {0}" -f $result.Count)
$result | Format-Table -AutoSize
if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
    $result | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV written: $CsvPath"
}
if ($result.Count -gt 0) { exit 2 }
