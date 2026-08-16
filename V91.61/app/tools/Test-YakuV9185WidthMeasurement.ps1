#Requires -Version 5.1
<#
  幅の物差し（段階0）。

  2026-08-17 に、収まり判定が2か所で「甘い側」へ外れていることが分かった。
  甘い側の誤りは「収まると判定して実際は切れる」という形で出る。

    (a) 測る書体が出力書体と違う
        www/assets/cat.js は 14.7px Calibri 固定で測っていた。
        書き戻しがセルへ設定するのは Arial（和→英）/ MS Pゴシック（英→和）
        （src/Settings.ps1:97-98、src/FileProcessors.ps1:1750）。
        Arial は同じ字上げで Calibri より広い。

    (b) width 属性の無い <col> を既定幅として数えていた
        <col min="5" max="5" hidden="1"/> は columns[] に現れず、
        消費側が既定幅 8.43 で埋めていた。

    (c) shrinkToFit を読んでいなかった
        原本で既に「縮小して全体を表示」が付いているセルは Excel が収める。
        読まないと、そのセルが「はみ出し」と判定され短縮の対象になる。

  この試験は Excel を使わない。ZIP と XML だけで .xlsx を組み、
  Get-YakuSheetLayoutFromXlsx の**返り値**で確かめる。
  書体の配線は3ファイルにまたがるので、文字列で押さえる。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9185Root = Split-Path -Parent $PSScriptRoot
$YakuT9185Src = Join-Path $YakuT9185Root 'src'
. (Join-Path $YakuT9185Src 'SrcModules.ps1')
foreach ($YakuT9185File in $script:YakuSrcModuleFiles) { . (Join-Path $YakuT9185Src $YakuT9185File) }

$script:T9185Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9185 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9185Failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9185WidthMeasurement'

# --- .xlsx を組む -------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$YakuT9185Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9185-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $YakuT9185Work -Force
$YakuT9185Book = Join-Path $YakuT9185Work 'width.xlsx'

$parts = @{}
$parts['[Content_Types].xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
$parts['_rels/.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
$parts['xl/workbook.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></workbook>'
$parts['xl/_rels/workbook.xml.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
# xf 0 = ふつう / xf 1 = shrinkToFit / xf 2 = wrapText
$parts['xl/styles.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font/></fonts><cellXfs count="3"><xf fontId="0"/><xf fontId="0" applyAlignment="1"><alignment shrinkToFit="1"/></xf><xf fontId="0" applyAlignment="1"><alignment wrapText="1"/></xf></cellXfs></styleSheet>'
# A列 幅12（既知） / E列 width 属性なし・hidden（不明）
$parts['xl/worksheets/sheet1.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetFormatPr defaultColWidth="8.43" defaultRowHeight="18.75"/><cols><col min="1" max="1" width="12"/><col min="5" max="5" hidden="1"/></cols><sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><t>plain</t></is></c><c r="B1" s="1" t="inlineStr"><is><t>shrink</t></is></c><c r="C1" s="2" t="inlineStr"><is><t>wrapped</t></is></c></row></sheetData></worksheet>'

$zip = [IO.Compression.ZipFile]::Open($YakuT9185Book, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in @($parts.Keys)) {
        $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $stream = $entry.Open()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$parts[$name])
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    }
} finally { $zip.Dispose() }

$YakuT9185Sheets = @(Get-YakuSheetLayoutFromXlsx -Path $YakuT9185Book)
Assert-T9185 -Condition ($YakuT9185Sheets.Count -eq 1) -Message ('the workbook was read (' + $YakuT9185Sheets.Count + ' sheet)')
if ($YakuT9185Sheets.Count -ne 1) {
    Write-Host 'FAIL cannot continue without a sheet'
    exit 1
}
$YakuT9185Sheet = $YakuT9185Sheets[0]

# --- (c) shrinkToFit ----------------------------------------------------------
$YakuT9185Cells = @($YakuT9185Sheet.cells)
$YakuT9185B1 = @($YakuT9185Cells | Where-Object { [string]$_.address -eq 'B1' })
Assert-T9185 -Condition ($YakuT9185B1.Count -eq 1) -Message 'the shrinkToFit cell is reported at all'
if ($YakuT9185B1.Count -eq 1) {
    Assert-T9185 -Condition ([bool]$YakuT9185B1[0].shrink) -Message 'B1 carries shrink = true'
    Assert-T9185 -Condition (-not [bool]$YakuT9185B1[0].wrap) -Message 'B1 is not reported as wrapped'
}
$YakuT9185C1 = @($YakuT9185Cells | Where-Object { [string]$_.address -eq 'C1' })
Assert-T9185 -Condition ($YakuT9185C1.Count -eq 1 -and [bool]$YakuT9185C1[0].wrap -and -not [bool]$YakuT9185C1[0].shrink) `
    -Message 'a wrapped cell is still wrap-only (shrink did not leak onto it)'
$YakuT9185A1 = @($YakuT9185Cells | Where-Object { [string]$_.address -eq 'A1' })
Assert-T9185 -Condition ($YakuT9185A1.Count -eq 0) -Message 'a plain cell is still omitted (the payload did not grow for nothing)'

# --- (b) width のない <col> ---------------------------------------------------
$YakuT9185Cols = @($YakuT9185Sheet.columns)
Assert-T9185 -Condition (@($YakuT9185Cols | Where-Object { [int]$_.min -eq 1 }).Count -eq 1) -Message 'a column WITH a width is still reported in columns'
Assert-T9185 -Condition (@($YakuT9185Cols | Where-Object { [int]$_.min -eq 5 }).Count -eq 0) -Message 'a column WITHOUT a width is kept out of columns (consumers read Number(width))'
$YakuT9185Unknown = @($YakuT9185Sheet.unknown_width_columns)
Assert-T9185 -Condition ($YakuT9185Unknown.Count -eq 1) -Message 'the width-less column is recorded as unknown rather than dropped'
if ($YakuT9185Unknown.Count -eq 1) {
    Assert-T9185 -Condition ([int]$YakuT9185Unknown[0].min -eq 5 -and [int]$YakuT9185Unknown[0].max -eq 5) -Message 'the unknown range is the right column'
    Assert-T9185 -Condition ([bool]$YakuT9185Unknown[0].hidden) -Message 'the unknown column keeps its hidden flag'
}

# --- (a) 測る書体の配線 -------------------------------------------------------
$YakuT9185CatJs = [IO.File]::ReadAllText((Join-Path $YakuT9185Root 'www\assets\cat.js'), [Text.Encoding]::UTF8)
$YakuT9185CatHtml = [IO.File]::ReadAllText((Join-Path $YakuT9185Root 'www\cat.html'), [Text.Encoding]::UTF8)
$YakuT9185Server = [IO.File]::ReadAllText((Join-Path $YakuT9185Src 'Server.ps1'), [Text.Encoding]::UTF8)

# 「ファイルのどこにも Calibri と書いていないこと」では駄目である。註にも
# 空設定のときのフォールバックにも出てくる。見るのは代入行そのもの。
$YakuT9185FontAssign = @([regex]::Matches($YakuT9185CatJs, 'context\.font\s*=\s*[^\r\n;]+') | ForEach-Object { $_.Value })
Assert-T9185 -Condition ($YakuT9185FontAssign.Count -ge 1) -Message 'the font assignment was found in cat.js'
foreach ($YakuT9185Line in $YakuT9185FontAssign) {
    Assert-T9185 -Condition ($YakuT9185Line -match 'previewOutputFont\(\)') `
        -Message ('the font is taken from the setting, not written in: ' + $YakuT9185Line.Trim())
    Assert-T9185 -Condition ($YakuT9185Line -notmatch 'Calibri') `
        -Message 'the assignment itself names no font family literally'
}
Assert-T9185 -Condition ($YakuT9185CatJs.Contains('yaku-output-font')) -Message 'cat.js reads the output font from the page'
Assert-T9185 -Condition ($YakuT9185CatJs.Contains("previewOutputFont()")) -Message 'the measurement uses that font'
Assert-T9185 -Condition ($YakuT9185CatJs.Contains('yaku-output-font-jp')) -Message 'the other direction has its own font'
Assert-T9185 -Condition ($YakuT9185CatHtml.Contains('__YAKU_OUTPUT_FONT__') -and $YakuT9185CatHtml.Contains('__YAKU_OUTPUT_FONT_JP__')) `
    -Message 'cat.html carries both placeholders'
Assert-T9185 -Condition ($YakuT9185Server.Contains('__YAKU_OUTPUT_FONT__') -and $YakuT9185Server.Contains('output_font_name')) `
    -Message 'the server fills them from the settings the write-back uses'
Assert-T9185 -Condition ($YakuT9185Server.Contains('__YAKU_OUTPUT_FONT_JP__') -and $YakuT9185Server.Contains('output_font_name_jp')) `
    -Message 'the to_jp font comes from output_font_name_jp'
# 書き戻しが本当にその設定でセルへ書いているか（配線の反対側）
$YakuT9185Fp = [IO.File]::ReadAllText((Join-Path $YakuT9185Src 'FileProcessors.ps1'), [Text.Encoding]::UTF8)
Assert-T9185 -Condition ($YakuT9185Fp.Contains('$cell.Font.Name = [string]$OutputFontName')) `
    -Message 'the write-back really sets that font on the cell (the other end of the wire)'

try { Remove-Item -LiteralPath $YakuT9185Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ''
if ($script:T9185Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9185WidthMeasurement'
    exit 0
}
Write-Host ("FAIL " + $script:T9185Failures.Count + ' assertion(s)')
foreach ($YakuT9185F in $script:T9185Failures) { Write-Host ('  - ' + $YakuT9185F) }
exit 1
