[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BeforePath,
    [Parameter(Mandatory=$true)][string]$AfterPath,
    [AllowNull()][string]$AllowedChangesCsv = '',
    [AllowNull()][string]$ReportPath = '',
    [int]$MaxDifferences = 1000
)

$ErrorActionPreference = 'Stop'

function Release-YakuCompareComObject {
    param([AllowNull()]$Object)
    if ($null -eq $Object) { return }
    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object) } catch {}
}

function Convert-YakuCompareColumnNameToNumber {
    param([Parameter(Mandatory=$true)][string]$Name)
    $n = 0
    foreach ($ch in ([string]$Name).ToUpperInvariant().ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 65 -or $code -gt 90) { continue }
        $n = ([int]$n * 26) + ($code - 64)
    }
    return [int]$n
}

function Convert-YakuCompareA1ToCoord {
    param([Parameter(Mandatory=$true)][string]$Address)
    $a = ([string]$Address).Trim().Replace('$','')
    if ($a.Contains('!')) { $a = $a.Substring($a.LastIndexOf('!') + 1).Trim("'") }
    if ($a -notmatch '^([A-Za-z]+)(\d+)$') { return $null }
    return [pscustomobject]@{ Row=[int]$Matches[2]; Col=(Convert-YakuCompareColumnNameToNumber -Name $Matches[1]) }
}

function Convert-YakuCompareColumnNumberToName {
    param([Parameter(Mandatory=$true)][int]$Column)
    $letters = ''
    $c = [int]$Column
    while ($c -gt 0) {
        $rem = [int](($c - 1) % 26)
        $letters = ([string][char](65 + $rem)) + $letters
        $c = [int][Math]::Floor((([double]$c - 1.0) / 26.0))
    }
    return $letters
}

function Get-YakuCompareCellKey {
    param([string]$Sheet, [int]$Row, [int]$Col)
    return (([string]$Sheet) + '!' + [string]$Row + ',' + [string]$Col)
}

function Get-YakuCompareArrayValue {
    param([AllowNull()]$Source, [bool]$IsArray, [int]$RowIndex, [int]$ColIndex)
    if ($IsArray -and $null -ne $Source) { return $Source.GetValue($RowIndex, $ColIndex) }
    return $Source
}

function Add-YakuCompareAllowedAddress {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Allowed,
        [AllowNull()][string]$DefaultSheet,
        [AllowNull()][string]$Address,
        [int]$Row = 0,
        [int]$Col = 0
    )
    $sheet = [string]$DefaultSheet
    $addr = [string]$Address
    if (-not [string]::IsNullOrWhiteSpace($addr) -and $addr.Contains('!')) {
        $sheet = $addr.Substring(0, $addr.LastIndexOf('!')).Trim("'")
    }
    if (($Row -le 0 -or $Col -le 0) -and -not [string]::IsNullOrWhiteSpace($addr)) {
        $coord = Convert-YakuCompareA1ToCoord -Address $addr
        if ($null -ne $coord) { $Row = [int]$coord.Row; $Col = [int]$coord.Col }
    }
    if (-not [string]::IsNullOrWhiteSpace($sheet) -and $Row -gt 0 -and $Col -gt 0) {
        $Allowed[(Get-YakuCompareCellKey -Sheet $sheet -Row $Row -Col $Col)] = $true
    }
}

$allowed = @{}
if (-not [string]::IsNullOrWhiteSpace([string]$AllowedChangesCsv) -and (Test-Path -LiteralPath $AllowedChangesCsv -PathType Leaf)) {
    foreach ($row in @(Import-Csv -LiteralPath $AllowedChangesCsv)) {
        $sheet = ''
        $addr = ''
        $r = 0
        $c = 0
        try { $sheet = [string]$row.Sheet } catch {}
        try { $addr = [string]$row.Address } catch {}
        try { if ($row.PSObject.Properties.Name -contains 'Row') { $r = [int]$row.Row } } catch {}
        try { if ($row.PSObject.Properties.Name -contains 'Col') { $c = [int]$row.Col } } catch {}
        Add-YakuCompareAllowedAddress -Allowed $allowed -DefaultSheet $sheet -Address $addr -Row $r -Col $c
    }
}

$excel = $null
$before = $null
$after = $null
$differences = New-Object System.Collections.Generic.List[object]
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    try { $excel.ScreenUpdating = $false } catch {}
    try { $excel.EnableEvents = $false } catch {}
    try { $excel.Calculation = -4135 } catch {} # xlCalculationManual
    $before = $excel.Workbooks.Open((Resolve-Path -LiteralPath $BeforePath).Path, 0, $true)
    $after = $excel.Workbooks.Open((Resolve-Path -LiteralPath $AfterPath).Path, 0, $true)

    $beforeSheetCount = [int]$before.Worksheets.Count
    for ($si = 1; $si -le $beforeSheetCount; $si++) {
        $beforeWs = $null
        $afterWs = $null
        $beforeUsed = $null
        $afterUsed = $null
        $beforeStart = $null
        $beforeEnd = $null
        $afterStart = $null
        $afterEnd = $null
        $beforeRange = $null
        $afterRange = $null
        try {
            $beforeWs = $before.Worksheets.Item($si)
            $sheetName = [string]$beforeWs.Name
            try { $afterWs = $after.Worksheets.Item($sheetName) } catch { $afterWs = $null }
            if ($null -eq $afterWs) {
                $differences.Add([pscustomobject]@{ Sheet=$sheetName; Address=''; Kind='missing-sheet'; Before='exists'; After='missing' }) | Out-Null
                continue
            }

            $beforeUsed = $beforeWs.UsedRange
            $afterUsed = $afterWs.UsedRange
            $startRow = [Math]::Min([int]$beforeUsed.Row, [int]$afterUsed.Row)
            $startCol = [Math]::Min([int]$beforeUsed.Column, [int]$afterUsed.Column)
            $endRow = [Math]::Max(([int]$beforeUsed.Row + [int]$beforeUsed.Rows.Count - 1), ([int]$afterUsed.Row + [int]$afterUsed.Rows.Count - 1))
            $endCol = [Math]::Max(([int]$beforeUsed.Column + [int]$beforeUsed.Columns.Count - 1), ([int]$afterUsed.Column + [int]$afterUsed.Columns.Count - 1))
            $rows = [int]($endRow - $startRow + 1)
            $cols = [int]($endCol - $startCol + 1)
            if ($rows -le 0 -or $cols -le 0) { continue }

            $beforeStart = $beforeWs.Cells.Item($startRow, $startCol)
            $beforeEnd = $beforeWs.Cells.Item($endRow, $endCol)
            $afterStart = $afterWs.Cells.Item($startRow, $startCol)
            $afterEnd = $afterWs.Cells.Item($endRow, $endCol)
            $beforeRange = $beforeWs.Range($beforeStart, $beforeEnd)
            $afterRange = $afterWs.Range($afterStart, $afterEnd)
            $beforeFormula = $beforeRange.Formula
            $afterFormula = $afterRange.Formula
            $beforeIsArray = ($beforeFormula -is [System.Array] -and $beforeFormula.Rank -eq 2)
            $afterIsArray = ($afterFormula -is [System.Array] -and $afterFormula.Rank -eq 2)
            $beforeRowBase = if ($beforeIsArray) { [int]$beforeFormula.GetLowerBound(0) } else { 0 }
            $beforeColBase = if ($beforeIsArray) { [int]$beforeFormula.GetLowerBound(1) } else { 0 }
            $afterRowBase = if ($afterIsArray) { [int]$afterFormula.GetLowerBound(0) } else { 0 }
            $afterColBase = if ($afterIsArray) { [int]$afterFormula.GetLowerBound(1) } else { 0 }

            for ($ri = 0; $ri -lt $rows; $ri++) {
                for ($ci = 0; $ci -lt $cols; $ci++) {
                    $rowNumber = [int]($startRow + $ri)
                    $colNumber = [int]($startCol + $ci)
                    $key = Get-YakuCompareCellKey -Sheet $sheetName -Row $rowNumber -Col $colNumber
                    if ($allowed.ContainsKey($key)) { continue }
                    $beforeValue = Get-YakuCompareArrayValue -Source $beforeFormula -IsArray $beforeIsArray -RowIndex ($beforeRowBase + $ri) -ColIndex ($beforeColBase + $ci)
                    $afterValue = Get-YakuCompareArrayValue -Source $afterFormula -IsArray $afterIsArray -RowIndex ($afterRowBase + $ri) -ColIndex ($afterColBase + $ci)
                    if ([string]$beforeValue -ne [string]$afterValue) {
                        $address = (Convert-YakuCompareColumnNumberToName -Column $colNumber) + [string]$rowNumber
                        $differences.Add([pscustomobject]@{ Sheet=$sheetName; Address=$address; Kind='formula-diff'; Before=[string]$beforeValue; After=[string]$afterValue }) | Out-Null
                        if ($differences.Count -ge $MaxDifferences) { break }
                    }
                }
                if ($differences.Count -ge $MaxDifferences) { break }
            }
            if ($differences.Count -ge $MaxDifferences) { break }
        } finally {
            foreach ($obj in @($afterRange, $beforeRange, $afterEnd, $afterStart, $beforeEnd, $beforeStart, $afterUsed, $beforeUsed, $afterWs, $beforeWs)) {
                Release-YakuCompareComObject $obj
            }
        }
    }
} finally {
    try { if ($before) { $before.Close($false) | Out-Null } } catch {}
    try { if ($after) { $after.Close($false) | Out-Null } } catch {}
    try { if ($excel) { $excel.Quit() | Out-Null } } catch {}
    foreach ($obj in @($after, $before, $excel)) { Release-YakuCompareComObject $obj }
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

if (-not [string]::IsNullOrWhiteSpace([string]$ReportPath)) {
    try { $differences.ToArray() | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8 } catch {}
}

if ($differences.Count -gt 0) {
    $differences.ToArray() | Select-Object -First ([Math]::Min($differences.Count, 50)) | Format-Table -AutoSize
    throw "Formula comparison failed: $($differences.Count) difference(s)."
}

Write-Host 'Formula comparison passed: no differences outside allowed cells.' -ForegroundColor Green
