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
  さらに本物の cat.html / cat.js を headless Chromium で開き、消費側が
  shrink と未知幅を overflow 印へ誤用しないことを DOM で確かめる。
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

$YAKU_WIDTH_UNMEASURED = 3
$YakuT9185Driver = Join-Path $PSScriptRoot 'cat-screen\cat-screen-gate.js'
$YakuT9185Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $YakuT9185Node -or -not (Test-Path -LiteralPath $YakuT9185Driver -PathType Leaf)) {
    Write-Host 'UNMEASURED: node または Chromium 運転席が無いため CAT 消費側を測れません。' -ForegroundColor Red
    exit $YAKU_WIDTH_UNMEASURED
}
$YakuT9185NodeExe = [string]$YakuT9185Node.Source
$YakuT9185ProbeDir = (Split-Path -Parent $YakuT9185Driver).Replace('\', '/')
$null = & $YakuT9185NodeExe -e ("try{require.resolve('playwright',{paths:['" + $YakuT9185ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が無いため CAT 消費側を測れません。' -ForegroundColor Red
    exit $YAKU_WIDTH_UNMEASURED
}
$YakuT9185ChromiumPath = & $YakuT9185NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $YakuT9185ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
$YakuT9185ChromiumExit = $LASTEXITCODE
if ($YakuT9185ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$YakuT9185ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$YakuT9185ChromiumPath) -PathType Leaf)) {
    Write-Host 'UNMEASURED: Playwright Chromium 実行ファイルが無いため CAT 消費側を測れません。' -ForegroundColor Red
    exit $YAKU_WIDTH_UNMEASURED
}

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

# --- CAT 消費側（実際の Chromium） -------------------------------------------
# A1 は既知の細い列で、B1 は同じ細さだが原本の shrink、C1 は未知幅の列である。
# どの文字列も細い既知列なら明らかに溢れる長さにして、抑制だけが緑になる空振りを防ぐ。
$YakuT9185Long = (('W' * 80) -join '')
$YakuT9185KnownText = 'KNOWN-' + $YakuT9185Long
$YakuT9185ShrinkText = 'SHRINK-' + $YakuT9185Long
$YakuT9185UnknownText = 'UNKNOWN-' + $YakuT9185Long
Assert-T9185 -Condition ($YakuT9185KnownText.Length -gt 80 -and $YakuT9185ShrinkText.Length -gt 80 -and $YakuT9185UnknownText.Length -gt 80) `
    -Message 'all three Chromium controls contain text that exceeds a narrow known column'
$YakuT9185PreviewProject = [ordered]@{
    id = 'width-preview-9185'; revision = 1; file_name = 'width-preview.xlsx'; document_format = 'xlsx'; direction = 'to_en'
    segments = @(
        [ordered]@{ index = 0; segment_id = 'width-a'; source = 'source-a'; translation = $YakuT9185KnownText; kind = 'cell'; location = 'S1, A1' },
        [ordered]@{ index = 1; segment_id = 'width-b'; source = 'source-b'; translation = $YakuT9185ShrinkText; kind = 'cell'; location = 'S1, B1' },
        [ordered]@{ index = 2; segment_id = 'width-c'; source = 'source-c'; translation = $YakuT9185UnknownText; kind = 'cell'; location = 'S1, C1' }
    )
    sheet_layout = @([ordered]@{
        name = 'S1'; default_width = 1; default_height = 18.75
        columns = @([ordered]@{ min = 1; max = 1; width = 1; hidden = $false }, [ordered]@{ min = 2; max = 2; width = 1; hidden = $false })
        unknown_width_columns = @([ordered]@{ min = 3; max = 3; hidden = $true })
        rows = @(); merges = @(); cells = @([ordered]@{ address = 'B1'; shrink = $true })
    })
}
$YakuT9185PreviewJson = Join-Path $YakuT9185Work 'preview-project.json'
$YakuT9185PreviewOut = Join-Path $YakuT9185Work 'preview-result.json'
[IO.File]::WriteAllText($YakuT9185PreviewJson, ($YakuT9185PreviewProject | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
& $YakuT9185NodeExe $YakuT9185Driver '--width-preview' (Join-Path $YakuT9185Root 'www') $YakuT9185PreviewJson $YakuT9185PreviewOut
$YakuT9185DriverExit = $LASTEXITCODE
Assert-T9185 -Condition ($YakuT9185DriverExit -eq 0 -and (Test-Path -LiteralPath $YakuT9185PreviewOut -PathType Leaf)) `
    -Message 'headless Chromium opened the actual CAT preview consumer'
$YakuT9185PreviewResult = $null
if (Test-Path -LiteralPath $YakuT9185PreviewOut -PathType Leaf) { $YakuT9185PreviewResult = [IO.File]::ReadAllText($YakuT9185PreviewOut, [Text.Encoding]::UTF8) | ConvertFrom-Json }
if ($null -ne $YakuT9185PreviewResult) {
    foreach ($YakuT9185Error in @($YakuT9185PreviewResult.errors)) { Write-Host ('  Chromium error: ' + [string]$YakuT9185Error) -ForegroundColor Red }
    foreach ($YakuT9185Console in @($YakuT9185PreviewResult.console)) { Write-Host ('  Chromium console: ' + [string]$YakuT9185Console) -ForegroundColor Red }
}
Assert-T9185 -Condition ($null -ne $YakuT9185PreviewResult -and @($YakuT9185PreviewResult.errors).Count -eq 0 -and @($YakuT9185PreviewResult.console).Count -eq 0) `
    -Message 'the CAT preview had no page or console errors'
$YakuT9185PreviewCells = @($(if ($null -ne $YakuT9185PreviewResult) { $YakuT9185PreviewResult.cells } else { @() }))
$YakuT9185KnownCell = @($YakuT9185PreviewCells | Where-Object { [int]$_.index -eq 0 })
$YakuT9185ShrinkCell = @($YakuT9185PreviewCells | Where-Object { [int]$_.index -eq 1 })
$YakuT9185UnknownCell = @($YakuT9185PreviewCells | Where-Object { [int]$_.index -eq 2 })
Assert-T9185 -Condition ($YakuT9185KnownCell.Count -eq 1 -and $YakuT9185ShrinkCell.Count -eq 1 -and $YakuT9185UnknownCell.Count -eq 1) `
    -Message 'all three width controls were rendered by the CAT preview'
if ($YakuT9185KnownCell.Count -eq 1) {
    Assert-T9185 -Condition ([bool]$YakuT9185KnownCell[0].overflowRisk -and [string]$YakuT9185KnownCell[0].ariaLabel -match '収まり要確認') `
        -Message 'a known-width non-wrap non-shrink overflow receives the risk class and aria label'
}
if ($YakuT9185ShrinkCell.Count -eq 1) {
    Assert-T9185 -Condition (-not [bool]$YakuT9185ShrinkCell[0].overflowRisk -and [string]::IsNullOrEmpty([string]$YakuT9185ShrinkCell[0].ariaLabel)) `
        -Message 'a shrink-to-fit cell does not receive an overflow risk marker'
}
if ($YakuT9185UnknownCell.Count -eq 1) {
    Assert-T9185 -Condition (-not [bool]$YakuT9185UnknownCell[0].overflowRisk -and [string]::IsNullOrEmpty([string]$YakuT9185UnknownCell[0].ariaLabel)) `
        -Message 'an unknown-width cell does not receive an overflow risk marker'
}

try { Remove-Item -LiteralPath $YakuT9185Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ''
if ($script:T9185Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9185WidthMeasurement'
    exit 0
}
Write-Host ("FAIL " + $script:T9185Failures.Count + ' assertion(s)')
foreach ($YakuT9185F in $script:T9185Failures) { Write-Host ('  - ' + $YakuT9185F) }
exit 1
