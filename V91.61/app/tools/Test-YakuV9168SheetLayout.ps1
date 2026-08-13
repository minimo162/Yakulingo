<#
.SYNOPSIS
  体裁（列幅・折り返し・結合）が、読めた形のまま画面へ届くことを確かめる。

.DESCRIPTION
  2026-08-13 まで、読み取りは1枚も返していなかった。原因は PowerShell 5.1 の
  配列部分式で、`@($list)` は List[object] に限って ArgumentException
  （Argument types do not match）を投げる。List[string] も ArrayList も投げない。
  投げたところが `catch { return @() }` の内側だったので、失敗は無音で、
  プレビューは既定幅（120px）に落ちたまま出ていた。

  だからここは「例外が出ないこと」では足りない。**中身が入って返ること**を見る。
  併せて、画面へ送る深さ（ConvertTo-Json -Depth 6）で列や結合が落ちないことも見る。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuLayout {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

. (Join-Path $root 'src\SheetLayout.ps1')
# ZipFile は System.IO.Compression.FileSystem、ZipArchive は System.IO.Compression。
# 別のアセンブリなので、両方を読む。
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# Office を使わずに、体裁だけを持つ xlsx を組む（読み手が見るのはこの3ファイル）。
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-layout-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDir -Force
$xlsxPath = Join-Path $workDir 'fixture.xlsx'
try {
    $parts = @{
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook><sheets><sheet name="明細" sheetId="1" r:id="rId1"/></sheets></workbook>'
        # font 0 は普通、font 1 は太字、font 2 は <b val="0"/>（太字ではない）。
        # xf 0 は普通、xf 1 は太字＋折り返し＋中央、xf 2 は val="0" を指す。
        'xl/styles.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet><fonts count="3"><font><sz val="11"/></font><font><b/><sz val="11"/></font><font><b val="0"/><sz val="11"/></font></fonts><cellXfs count="3"><xf numFmtId="0" fontId="0"/><xf numFmtId="0" fontId="1" applyAlignment="1"><alignment horizontal="center" wrapText="1"/></xf><xf numFmtId="0" fontId="2"/></cellXfs></styleSheet>'
        'xl/worksheets/sheet1.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet><sheetFormatPr defaultColWidth="9.5" defaultRowHeight="18"/><cols><col min="1" max="1" width="42.5" customWidth="1"/><col min="2" max="3" width="7.25" customWidth="1"/><col min="4" max="4" width="5" hidden="1"/></cols><sheetData><row r="1" ht="48.75" customHeight="1"><c r="A1" s="1" t="s"><v>0</v></c><c r="B1" s="0"><v>1</v></c><c r="C1" s="2"><v>3</v></c></row><row r="2"><c r="A2" s="0"><v>2</v></c></row></sheetData><mergeCells count="2"><mergeCell ref="A1:C1"/><mergeCell ref="A5:A7"/></mergeCells></worksheet>'
    }
    $stream = New-Object System.IO.FileStream($xlsxPath, 'Create')
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, 'Create')
        try {
            foreach ($name in $parts.Keys) {
                $entry = $zip.CreateEntry($name)
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write([string]$parts[$name]) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }

    Write-Host 'Sheet layout reaches the screen with its contents intact' -ForegroundColor Cyan

    $sheets = @(Get-YakuSheetLayoutFromXlsx -Path $xlsxPath)

    # 1枚も返らないのが、実際に起きていた壊れ方。まずそこを見る。
    Check-YakuLayout ($sheets.Count -eq 1) '1枚ぶん返る（空で返らない）'
    if ($sheets.Count -ne 1) {
        Write-Host '  （0枚のときは以降を測っても意味が無いので打ち切る）' -ForegroundColor Yellow
        Write-Host ('Sheet layout tests failed: ' + ($script:failed + 1)) -ForegroundColor Red
        exit 1
    }
    $sheet = $sheets[0]

    Check-YakuLayout ([string]$sheet.name -eq '明細') 'シート名を持つ'
    Check-YakuLayout ([double]$sheet.default_width -eq 9.5) '既定の列幅を sheetFormatPr から読む'

    # 列幅。中身が入っていること（Count だけでなく値）を見る。
    $columns = @($sheet.columns)
    Check-YakuLayout ($columns.Count -eq 3) '列の指定を3件とも読む'
    Check-YakuLayout ([double]$columns[0].width -eq 42.5 -and [int]$columns[0].min -eq 1) '広い列の幅をそのまま持つ'
    Check-YakuLayout ([int]$columns[1].min -eq 2 -and [int]$columns[1].max -eq 3) '範囲指定の列は min/max を保つ'
    Check-YakuLayout ([bool]$columns[2].hidden) '隠し列を隠しとして持つ'

    # 結合。実効幅が広いかどうかの判断に要る。
    $merges = @($sheet.merges)
    Check-YakuLayout ($merges.Count -eq 2 -and $merges -contains 'A1:C1') '結合セルを読む'

    # 折り返し。ON なら切らずに伸ばす、OFF なら Excel と同じく切る。
    $cells = @($sheet.cells)
    $a1 = $cells | Where-Object { $_.address -eq 'A1' } | Select-Object -First 1
    Check-YakuLayout ($null -ne $a1 -and [bool]$a1.wrap) '折り返し ON のセルを拾う'
    Check-YakuLayout ($null -ne $a1 -and [string]$a1.align -eq 'center') '寄せを拾う'
    Check-YakuLayout (-not ($cells | Where-Object { $_.address -eq 'B1' })) '折り返しも寄せも太字も無いセルは持たない（際限なく増やさない）'

    # 太字。xf は太字を直接持たず fontId で fonts を指すので、そこを辿れているか。
    Check-YakuLayout ($null -ne $a1 -and [bool]$a1.bold) '太字を fontId 経由で拾う'
    Check-YakuLayout (-not ($cells | Where-Object { $_.address -eq 'C1' })) '<b val="0"/> は太字として扱わない'

    # 行の高さ。既定と違う行だけ持ち、既定は sheetFormatPr から取る。
    $rows = @($sheet.rows)
    Check-YakuLayout ($rows.Count -eq 1 -and [double]$rows[0].height -eq 48.75) '既定と違う行の高さだけ持つ'
    Check-YakuLayout ([double]$sheet.default_height -eq 18) '既定の行の高さを sheetFormatPr から読む'

    # 画面へ送る深さで落ちない。ここが浅いと、列も結合も静かに消える。
    $json = ([ordered]@{ sheet_layout = $sheets } | ConvertTo-Json -Depth 6 -Compress)
    $back = $json | ConvertFrom-Json
    $backSheet = @($back.sheet_layout)[0]
    Check-YakuLayout (@($backSheet.columns).Count -eq 3) 'Depth 6 の JSON を通っても列が残る'
    Check-YakuLayout ([double](@($backSheet.columns)[0].width) -eq 42.5) 'JSON を通っても幅の値が残る'
    Check-YakuLayout (@($backSheet.merges).Count -eq 2) 'JSON を通っても結合が残る'
    Check-YakuLayout ($json -notmatch 'System\.Collections') '深さ切れで中身が文字列に化けていない'

    # 読めないものを渡しても、翻訳は続く（体裁は足しであって前提ではない）。
    $notXlsx = Join-Path $workDir 'broken.xlsx'
    Set-Content -LiteralPath $notXlsx -Value 'this is not a zip' -Encoding ASCII
    $broken = @(Get-YakuSheetLayoutFromXlsx -Path $notXlsx)
    Check-YakuLayout ($broken.Count -eq 0) '壊れたファイルは空で返る（例外を投げない）'
    $missing = @(Get-YakuSheetLayoutFromXlsx -Path (Join-Path $workDir 'nope.xlsx'))
    Check-YakuLayout ($missing.Count -eq 0) '無いファイルは空で返る'

    # 訳す向きの判定は、共有表（xl/sharedStrings.xml）だけを見ていた。
    # 文字列をセルの中へ直に書くブック（t="inlineStr"）では原文を1文字も読めず、
    # 毎回「このファイルの翻訳先を選んでください。」になっていた（2026-08-13、
    # 実機で確認。13セルすべて inlineStr、共有表そのものが無いブック）。
    # 行の取り出しは最初から読めていて同じブックから10行できていたので、
    # 読めていなかったのは判定だけだった。
    Write-Host '共有表を持たないブックでも、訳す向きを読める' -ForegroundColor Cyan
    # FileProcessors は単体で読めない（Runtime のジョブ中断確認などを呼ぶ）。
    # 一覧のとおり全部読む。並びも一覧に従う。
    . (Join-Path $root 'src\SrcModules.ps1')
    foreach ($moduleName in $script:YakuSrcModuleFiles) { . (Join-Path $root ('src\' + $moduleName)) }
    $inlinePath = Join-Path $workDir 'inline.xlsx'
    $inlineParts = @{
        # r: の名前空間は宣言する。宣言しないと XML として読めず、
        # 判定より手前（整合の読み取り）で落ちる。
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="決算概要" sheetId="1" r:id="rId1"/></sheets></workbook>'
        'xl/styles.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet><fonts count="1"><font><sz val="11"/></font></fonts><cellXfs count="1"><xf numFmtId="0" fontId="0"/></cellXfs></styleSheet>'
        'xl/worksheets/sheet1.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>売上高は1兆3,150億円となりました。</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>営業利益は2,180億円で、前年同期比8.1%の増加です。</t></is></c></row><row r="3"><c r="A3" t="inlineStr"><is><t>為替の影響を含みます。海外売上比率は42%です。</t></is></c></row></sheetData></worksheet>'
    }
    $inlineStream = New-Object System.IO.FileStream($inlinePath, 'Create')
    try {
        $inlineZip = New-Object System.IO.Compression.ZipArchive($inlineStream, 'Create')
        try {
            foreach ($name in $inlineParts.Keys) {
                $entry = $inlineZip.CreateEntry($name)
                $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
                try { $writer.Write([string]$inlineParts[$name]) } finally { $writer.Dispose() }
            }
        } finally { $inlineZip.Dispose() }
    } finally { $inlineStream.Dispose() }

    $inlineInfo = Get-YakuOpenXmlFileInfo -Path $inlinePath
    Check-YakuLayout ([string]$inlineInfo.DirectionConfidence -eq 'high') '共有表が無くても、訳す向きを聞き返さない'
    Check-YakuLayout ([string]$inlineInfo.DetectedDirection -eq 'to_en') '日本語のブックは英訳と判定する'
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) { Write-Host ('Sheet layout tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Sheet layout tests passed.' -ForegroundColor Green
