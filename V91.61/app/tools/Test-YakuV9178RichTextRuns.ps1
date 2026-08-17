<#
.SYNOPSIS
  V91.61: セルの中の書式とふりがなが、書き戻しで巻き添えにならないことを確かめる。

.DESCRIPTION
  2026-08-16 に Excel COM で実測した被害は2つある。どちらも文字は1文字も
  変わらないので、**本文を比べる検査では永久に見つからない**。

    A（滲み出し） 1〜4文字目だけ太字のセルへ Value2 で書くと、1文字目の書式が
                  新しい文字列全体へ広がり、29文字すべてが太字になった。
    D（巻き添え） 翻訳対象ではない隣のセルが一括の箱に入っていると、元の値を
                  そのまま書き戻すだけで run が消えた。ふりがなも同じで、
                  `東京` のまま `Phonetics.Count` が 1 → 0 になった。

  D の守りは**判定を反転**してある（2026-08-16 の利用者判断）。

      いま  リッチだと分かったセルを箱から外す   → 見落としたら壊す
      反転  平文だと証明できたセルだけ箱に入れる → 見落としたら遅くなるだけ

  ここで見るのは4つ。
    1. 検出器が「平文だと証明できたセル」だけを箱に通すこと（狭さ）
    2. 平文だけのブックで箱が死なないこと（狭すぎないことの対の表明）
    3. 証明できないセルを含む箱が一括経路へ入らないこと（D）
    4. 書いた後にセル全体が支配的な書式へ揃うこと（A）

  **対の表明を必ず置く。** 守りを外した側で実際に壊れることを見ていないと、
  「何も見ていない門」が緑のまま残る。

  **Excel が要る表明と、要らない表明を分ける。** 検出器は ZIP だけで測れるので
  Excel の無い機械でも緑になる。Excel が要る表明は、Excel が無ければ
  **未測定（exit 3）**として返す。赤へ畳むと、道具の不在が対象の欠陥に化ける。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9178RichTextRuns.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:excelMeasured = $false

foreach ($moduleName in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','FileProcessors.ps1','SheetLayout.ps1')) {
    . (Join-Path (Join-Path $root 'src') $moduleName)
}
# ZipFile は System.IO.Compression.FileSystem、ZipArchive は System.IO.Compression。
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Chk {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:fail++ }
}

function New-YakuRunFixtureXlsx {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][hashtable]$Parts)
    $stream = New-Object System.IO.FileStream($Path, 'Create')
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, 'Create')
        try {
            foreach ($name in $Parts.Keys) {
                $entry = $zip.CreateEntry($name)
                $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
                try { $writer.Write([string]$Parts[$name]) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-YakuNonPlainCellByAddress {
    param([AllowNull()][object[]]$NonPlainCells,[Parameter(Mandatory=$true)][string]$Address)
    foreach ($cell in @($NonPlainCells)) {
        if ($null -eq $cell) { continue }
        if ([string]$cell.address -eq $Address) { return $cell }
    }
    return $null
}

# --- 実機の測り方 ----------------------------------------------------------
# セルの Font.Bold は、run が混在していると [System.DBNull] を返す。
# 「太字である／ない／混ざっている」を1つに畳むと被害が見えなくなるので分ける。
function Get-YakuRunBoldState {
    param([Parameter(Mandatory=$true)]$Worksheet,[int]$Row,[int]$Col)
    $cell = $null
    try {
        $cell = $Worksheet.Cells.Item($Row,$Col)
        $value = $cell.Font.Bold
        if ($null -eq $value) { return 'null' }
        if ($value -is [System.DBNull]) { return 'mixed' }
        if ([bool]$value) { return 'bold' }
        return 'plain'
    } catch { return 'error' } finally { Release-YakuComObject $cell }
}

# 1文字ずつ測る。セル単位の Font.Bold だけでは「どこが太字か」が消える。
function Get-YakuRunPerCharBold {
    param([Parameter(Mandatory=$true)]$Worksheet,[int]$Row,[int]$Col)
    $cell = $null
    $map = ''
    try {
        $cell = $Worksheet.Cells.Item($Row,$Col)
        $text = [string]$cell.Value2
        for ($i = 1; $i -le $text.Length; $i++) {
            $value = $cell.Characters($i,1).Font.Bold
            if ($value -is [System.DBNull]) { $map += '?' }
            elseif ($null -ne $value -and [bool]$value) { $map += 'B' }
            else { $map += '.' }
        }
    } catch { return 'error' } finally { Release-YakuComObject $cell }
    return $map
}

# ふりがなは本文とは別の入れ物にある。**本文だけを比べても消えたことが分からない**
# ので、件数と読みと本文を1つに畳まず、そろえて持ち帰る。
function Get-YakuPhoneticState {
    param([Parameter(Mandatory=$true)]$Worksheet,[int]$Row,[int]$Col)
    $cell = $null
    try {
        $cell = $Worksheet.Cells.Item($Row,$Col)
        $count = -1
        try { $count = [int]$cell.Phonetics.Count } catch { $count = -1 }
        $text = ''
        if ($count -ge 1) { try { $text = [string]$cell.Phonetics.Item(1).Text } catch { $text = '<error>' } }
        return [pscustomobject]@{ Count = [int]$count; Text = [string]$text; Value = [string]$cell.Value2 }
    } catch {
        return [pscustomobject]@{ Count = -1; Text = '<error>'; Value = '<error>' }
    } finally { Release-YakuComObject $cell }
}

function Invoke-YakuRunBoxProbe {
    # 箱 B8:D8 へ一括で書く。C8 は**翻訳対象ではない**のに箱の中にいる。
    param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][object[]]$NonPlainCells,[AllowNull()][hashtable]$TargetKeys = $null)
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    $result = $null
    try {
        $wb = $xl.Workbooks.Open($Path)
        $ws = $wb.Worksheets.Item('S1')
        $before = Get-YakuRunPerCharBold -Worksheet $ws -Row 8 -Col 3
        $items = @(
            [pscustomobject]@{ Row=8; Col=2; Translation='Heading'; Block=$null },
            [pscustomobject]@{ Row=8; Col=4; Translation='FX'; Block=$null }
        )
        $warnings = New-Object System.Collections.Generic.List[object]
        $written = Invoke-YakuExcelBulkBoundingBoxWrite -Worksheet $ws -Items $items -OutputFontName '' -Warnings $warnings -SheetName 'S1' -NonPlainCells $NonPlainCells -TargetKeys $TargetKeys
        $after = Get-YakuRunPerCharBold -Worksheet $ws -Row 8 -Col 3
        $result = [pscustomobject]@{ Used = [bool]($null -ne $written); Before = [string]$before; After = [string]$after }
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    return $result
}

function Invoke-YakuRunLevelProbe {
    # 一括の箱を外した先で通る書き込み（矩形の2次元配列代入）だけを走らせ、
    # **揃え直しの前と後**を測る。これが無いと「箱を外したから直った」のか
    # 「揃え直したから直った」のかを分けられない。
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][object[]]$NonPlainCells,
        [Parameter(Mandatory=$true)][hashtable]$TargetKeys
    )
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    $result = $null
    try {
        $wb = $xl.Workbooks.Open($Path)
        $ws = $wb.Worksheets.Item('S1')
        $range = $ws.Range('B8:D8')
        $values = [System.Array]::CreateInstance([object], 1, 3)
        $values.SetValue('Heading', 0, 0)
        $values.SetValue('Test test test test test', 0, 1)
        $values.SetValue('FX', 0, 2)
        Set-YakuExcelRangeArrayValue2 -Range $range -Values2D $values
        $afterWrite = Get-YakuRunBoldState -Worksheet $ws -Row 8 -Col 3
        $levelled = Set-YakuExcelRunCellDominantFormat -Worksheet $ws -NonPlainCells $NonPlainCells -TargetKeys $TargetKeys -OutputFontName '' -SheetName 'S1'
        $afterLevel = Get-YakuRunBoldState -Worksheet $ws -Row 8 -Col 3
        $result = [pscustomobject]@{ AfterWrite=[string]$afterWrite; AfterLevel=[string]$afterLevel; Levelled=[int]$levelled }
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    return $result
}

function Invoke-YakuRunSheetWriteback {
    <#
      本番のシート単位の入口（Write-YakuExcelCellTranslationsForSheet）を通す。
      **対象の集合を差し替えられる**ようにしてあるので、同じシート・同じ run セルで
      「一括を使う側」と「一括を捨てる側」の両方を測れる。対象表を箱まで引き回す
      配線が切れれば、一括を使う側がここで落ちる。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][object[]]$NonPlainCells,
        [Parameter(Mandatory=$true)][int[]]$TargetCols
    )
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    $result = $null
    try {
        $wb = $xl.Workbooks.Open($Path)
        $ws = $wb.Worksheets.Item('S1')
        $before = Get-YakuRunPerCharBold -Worksheet $ws -Row 8 -Col 3
        $sources = @{ 2 = '見出し'; 3 = 'テストテストテストテストテスト'; 4 = '為替' }
        $targets = @{ 2 = 'Heading'; 3 = 'Test test test test test'; 4 = 'FX' }
        $blocks = New-Object System.Collections.Generic.List[object]
        $byBlock = @{}
        foreach ($col in $TargetCols) {
            $id = 'c' + [string]$col
            $blocks.Add([pscustomobject]@{
                Id = $id; Text = [string]$sources[$col]; Location = 'S1'
                Meta = [pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=8; Col=[int]$col; A1=''; Merged=$false }
            }) | Out-Null
            $byBlock[$id] = [string]$targets[$col]
        }
        $warnings = New-Object System.Collections.Generic.List[object]
        $metrics = @{}
        $written = Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks ([object[]]@($blocks.ToArray())) -TranslationByBlockId $byBlock -OutputFontName '' -Warnings $warnings -Metrics $metrics -NonPlainCells $NonPlainCells
        $result = [pscustomobject]@{
            Written  = [int]$written
            BulkBox  = [int]$metrics['bulk_box']
            Mode     = [string]$metrics['bulk_mode']
            RunSkips = [int]$metrics['bulk_non_plain_skips']
            Levelled = [int]$metrics['run_cells_levelled']
            Before   = [string]$before
            After    = [string](Get-YakuRunPerCharBold -Worksheet $ws -Row 8 -Col 3)
            C8Value  = [string]$ws.Cells.Item(8,3).Value2
            B8Bold   = [string](Get-YakuRunBoldState -Worksheet $ws -Row 8 -Col 2)
        }
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    return $result
}

function Invoke-YakuRunWriteback {
    # 本番と同じ入口を通す。3ホップの引き回しが切れていれば、ここで落ちる。
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [AllowNull()]$Settings
    )
    $blocks = @(
        [pscustomobject]@{ Id='b8'; Text='見出し'; Location='S1, B8'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=8; Col=2; A1='B8'; Merged=$false } },
        [pscustomobject]@{ Id='c8'; Text='テストテストテストテストテスト'; Location='S1, C8'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=8; Col=3; A1='C8'; Merged=$false } },
        [pscustomobject]@{ Id='d8'; Text='為替'; Location='S1, D8'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=8; Col=4; A1='D8'; Merged=$false } }
    )
    $byBlock = @{ 'b8' = 'Heading'; 'c8' = 'Test test test test test'; 'd8' = 'FX' }
    $warnings = New-Object System.Collections.Generic.List[object]
    $null = Write-YakuExcelTranslations -OutputPath $Path -Blocks $blocks -TranslationByBlockId $byBlock -Warnings $warnings -Settings $Settings -SourcePath $SourcePath
}

function Get-YakuRunCellState {
    param([Parameter(Mandatory=$true)][string]$Path)
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    $state = $null
    try {
        $wb = $xl.Workbooks.Open($Path, 0, $true)
        $ws = $wb.Worksheets.Item('S1')
        $state = [pscustomobject]@{
            B8Value = [string]$ws.Cells.Item(8,2).Value2
            C8Value = [string]$ws.Cells.Item(8,3).Value2
            D8Value = [string]$ws.Cells.Item(8,4).Value2
            B8Bold = [string](Get-YakuRunBoldState -Worksheet $ws -Row 8 -Col 2)
            C8Bold = [string](Get-YakuRunBoldState -Worksheet $ws -Row 8 -Col 3)
            C8PerChar = [string](Get-YakuRunPerCharBold -Worksheet $ws -Row 8 -Col 3)
        }
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    return $state
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-run-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $workDir -Force
try {

# ===========================================================================
# 1. 検出器（Excel は要らない）
# ===========================================================================
Write-Host 'run を持つセルを、数えるのではなく比べて選ぶ' -ForegroundColor Cyan

$fixturePath = Join-Path $workDir 'runs-fixture.xlsx'
# font 0 … 普通（sz 11 / theme 1 / 游ゴシック）
# font 1 … ふりがな用（phoneticPr が指すだけ。セルは使わない）
# font 2 … 太字。中身は font 0 と太字以外そろえてある
# xf 0 -> font 0、xf 1 -> font 2
$stylesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><color theme="1"/><name val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></font><font><sz val="6"/><name val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></font><font><b/><sz val="11"/><color theme="1"/><name val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></font></fonts><cellXfs count="2"><xf numFmtId="0" fontId="0" xfId="0"/><xf numFmtId="0" fontId="2" applyFont="1" xfId="0"/></cellXfs></styleSheet>'
# si 0 … 利用者のテストファイル C7 の写し。run は3つあるが、rPr は
#        **セル自身の字体を言い直しているだけ**（family だけ 2/3 で違う）。
#        見た目の差はゼロなので、これを拾ったら偽陽性である。
# si 1 … 太字の run（C8 相当）
# si 2 … 下線の run（C23 相当）
# si 3 … run1 に rPr が無く、run2 が <b/>。**参照するセルの字体しだいで答えが変わる**
# si 4 … 書体（rFont）が食い違う run
# si 5 … **Excel 16.0 が実際に書いた形をそのまま写したもの。** 1〜4文字目だけを
#        太字にすると、Excel はセルの字体のほうを太字にして、1つ目の run には
#        rPr を書かず、残りへ「太字を含まない rPr」を書く。rPr を差分として
#        扱う実装はここで必ず外す（外した状態を実測してからこの枝を足した）。
$sharedXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="6" uniqueCount="6">' +
    '<si><r><t xml:space="preserve">1. </t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テスト1</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></rPr><t>　太字</t></r><rPh sb="8" eb="10"><t>フトジ</t></rPh><phoneticPr fontId="1"/></si>' +
    '<si><r><t>テストテスト</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テスト</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></rPr><t>テストテスト</t></r><phoneticPr fontId="1"/></si>' +
    '<si><r><t>テストテスト</t></r><r><rPr><u/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テスト</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></rPr><t>テストテスト</t></r><phoneticPr fontId="1"/></si>' +
    '<si><r><t>テストテスト</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テス</t></r></si>' +
    '<si><r><rPr><sz val="11"/><color theme="1"/><rFont val="Meiryo"/><family val="3"/><charset val="128"/></rPr><t>ABCDEF</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/></rPr><t>GH</t></r></si>' +
    '<si><r><t>テストテ</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></rPr><t>ストテストテストテスト</t></r></si>' +
    '</sst>'
# B23 は**自己終端の空セル**で、その直後に C23 を置いてある。正規表現が
# 自己終端を飲むと `.*?</c>` が C23 の中身を盗み、B23 が C23 の共有文字列を
# 名乗って報告される。**件数は変わらない**ので、所属で見るしかない。
$sheetXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' +
    '<row r="7"><c r="C7" s="0" t="s"><v>0</v></c></row>' +
    '<row r="8"><c r="C8" s="0" t="s"><v>1</v></c></row>' +
    '<row r="23"><c r="B23" s="0"/><c r="C23" s="0" t="s"><v>2</v></c></row>' +
    '<row r="30"><c r="C30" s="1" t="s"><v>3</v></c></row>' +
    '<row r="31"><c r="C31" s="0" t="s"><v>3</v></c></row>' +
    '<row r="40"><c r="C40" s="0" t="s"><v>4</v></c></row>' +
    '<row r="50"><c r="C50" s="1" t="s"><v>5</v></c></row>' +
    # --- セルの中へ直に書く形（t="inlineStr"）。**共有文字列とまったく同じ判定を当てる** ---
    # 上の si 0〜5 と同じ罠を、置き場所だけ変えて並べてある。
    # B60 は自己終端の空セル。`<c>` の正規表現が自己終端を後回しにすると、
    # ここが C60 の中身を盗んで C60 が走査から消える（罠1、B23 と同じ）。
    '<row r="60"><c r="B60" s="0"/><c r="C60" s="0" t="inlineStr"><is><r><t>テストテスト</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テスト</t></r></is></c></row>' +
    # C61 … rPr がセル自身の字体を言い直しているだけ（family だけ違う）。見た目の差はゼロ（罠2・罠3）
    '<row r="61"><c r="C61" s="0" t="inlineStr"><is><r><t>テストテスト</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></rPr><t>テスト</t></r></is></c></row>' +
    # C62 と C63 は**中身が1文字も違わない**。違うのは参照するセルの字体だけ。
    # C62（太字のセル）は混在ではなく、C63（普通のセル）は混在である（罠3）。
    '<row r="62"><c r="C62" s="1" t="inlineStr"><is><r><t>テストテスト</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テス</t></r></is></c></row>' +
    '<row r="63"><c r="C63" s="0" t="inlineStr"><is><r><t>テストテスト</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テス</t></r></is></c></row>' +
    # C64 … セルの字体が太字で、あとの run が「太字を書かない rPr」で打ち消す形（罠4）
    '<row r="64"><c r="C64" s="1" t="inlineStr"><is><r><t>テストテ</t></r><r><rPr><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="2"/><charset val="128"/><scheme val="minor"/></rPr><t>ストテストテストテスト</t></r></is></c></row>' +
    '</sheetData></worksheet>'
New-YakuRunFixtureXlsx -Path $fixturePath -Parts @{
    'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="明細" sheetId="1" r:id="rId7"/></sheets></workbook>'
    'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/run-source.xml"/></Relationships>'
    'xl/styles.xml' = $stylesXml
    'xl/sharedStrings.xml' = $sharedXml
    'xl/worksheets/run-source.xml' = $sheetXml
}

$sheets = @(Get-YakuXlsxNonPlainCells -Path $fixturePath)
Chk ($sheets.Count -eq 1) ('証明できないセルを持つシートが1枚返る: ' + $sheets.Count)
$nonPlainCells = @()
if ($sheets.Count -eq 1) {
    Chk ([string]$sheets[0].name -eq '明細') 'relationship で解決したシート名を持つ'
    $nonPlainCells = @($sheets[0].non_plain_cells)
}
$addresses = @($nonPlainCells | ForEach-Object { [string]$_.address })

function Get-YakuDiffering {
    param([AllowNull()][object[]]$Cells,[Parameter(Mandatory=$true)][string]$Address)
    $cell = Get-YakuNonPlainCellByAddress -NonPlainCells $Cells -Address $Address
    if ($null -eq $cell) { return '<missing>' }
    return ((@($cell.differing_properties)) -join ',')
}

# 所属で見る。件数だけを見ると、B2 が C2 の代わりに入っても気づけない。
Chk ($addresses -contains 'C8') '太字の run を持つセルは、平文だと証明できない'
Chk ($addresses -contains 'C23') '下線の run を持つセルも、平文だと証明できない'
# **反転した。** 見た目の差がゼロでも、`<r>` が並んでいる時点で平文ではない。
# 箱から外すのは正しい（安全側）。ただし**揃え直しは1つも代入しない**。
# そこが「数える／比べる」の分かれ目で、下の代入表の表明で押さえている。
Chk ($addresses -contains 'C7') 'rPr がセル自身の字体を言い直しているだけでも、平文だとは証明できない'
Chk ((Get-YakuDiffering -Cells $nonPlainCells -Address 'C7') -eq '') ('その C7 は食い違いゼロなので、揃え直しは何もしない（罠3）: [' + (Get-YakuDiffering -Cells $nonPlainCells -Address 'C7') + ']')
Chk (-not ($addresses -contains 'B23')) '自己終端の空セルは平文だと証明でき、次のセルの中身も名乗らない（罠1）'
Chk (($addresses -join ',') -eq 'C7,C8,C23,C30,C31,C40,C50,C60,C61,C62,C63,C64') ('証明できないのは12件（空の B23 / B60 は平文として通る）: ' + ($addresses -join ','))

# --- セルの中へ直に書く形（t="inlineStr"）--------------------------------
# **ここが長らく穴だった。** 検出器は共有文字列の `<si><r><rPr>` しか見ておらず、
# inlineStr の rich text は1件も映らなかった。映らないセルは「非対象の run セル」
# として数えられないので、一括の箱がそのセルごと書き戻し、**本文は1バイトも
# 変わらないまま書式だけ消えた**（被害D）。Excel 自身は inlineStr で rich text を
# 書かないが、一部の ERP・帳票出力・ライブラリは書く。
# **利用者のファイルがその形かは測っていない。頻度をここで語らないこと。**
Write-Host 'セルの中へ直に書いた run にも、共有文字列と同じ判定を当てる' -ForegroundColor Cyan
Chk ($addresses -contains 'C60') 'inlineStr の中の太字 run を持つセルを拾う'
$c60 = Get-YakuNonPlainCellByAddress -NonPlainCells $nonPlainCells -Address 'C60'
Chk ($null -ne $c60 -and [int]$c60.row -eq 60 -and [int]$c60.col -eq 3) 'C60 を行60・列3として返す'
Chk ($null -ne $c60 -and @($c60.runs).Count -eq 2) 'inlineStr の run を2つとも返す'
Chk ($null -ne $c60 -and @($c60.runs)[0].length -eq 6 -and @($c60.runs)[1].length -eq 3) 'run の文字数が 6 / 3 で返る（符号化が壊れていればここで変わる）'
Chk ($null -ne $c60 -and (@($c60.differing_properties) -join ',') -eq 'b') 'inlineStr でも、食い違っているのは太字だけだと分かる'
Chk ($null -ne $c60 -and -not $c60.dominant_properties.ContainsKey('b')) '支配的な書式は「太字ではない」ほう（6文字 対 3文字）'
Chk (-not ($addresses -contains 'B60')) '自己終端の空セルが inlineStr セルの中身を名乗らない（罠1）'

# 罠2: 見える属性の許可リスト。family / charset / scheme は見た目に出ない。
# **反転後は「拾うか」ではなく「揃え直すか」で見る。** inlineStr はどのみち
# 平文だと証明できないので箱からは外れる。見た目の差の有無は代入表に出る。
Chk ((Get-YakuDiffering -Cells $nonPlainCells -Address 'C61') -eq '') ('inlineStr でも、rPr がセル自身の字体を言い直しているだけなら食い違いはゼロ（罠2・罠3）: [' + (Get-YakuDiffering -Cells $nonPlainCells -Address 'C61') + ']')

# 罠3: **セルの字体を基準に解く。** C62 と C63 は中身が1文字も違わない。
# 字体を見ない実装は、この2つを同じ答えにするので必ずどちらかで落ちる。
Chk ((Get-YakuDiffering -Cells $nonPlainCells -Address 'C62') -eq '') ('太字のセルの中で <b/> を言い直す inlineStr の run は、混在ではない（罠3）: [' + (Get-YakuDiffering -Cells $nonPlainCells -Address 'C62') + ']')
Chk ((Get-YakuDiffering -Cells $nonPlainCells -Address 'C63') -eq 'b') ('同じ中身でも、普通のセルなら混在になる（罠3の対）: [' + (Get-YakuDiffering -Cells $nonPlainCells -Address 'C63') + ']')

# 罠4: rPr は差分ではない。書いていない切り替えは「切ってある」。
$c64 = Get-YakuNonPlainCellByAddress -NonPlainCells $nonPlainCells -Address 'C64'
Chk ($null -ne $c64) 'inlineStr でも、セルの字体が太字で rPr が太字を書かずに打ち消す形を拾う（罠4）'
Chk ($null -ne $c64 -and (@($c64.differing_properties) -join ',') -eq 'b') 'その食い違いも太字だと分かる'
Chk ($null -ne $c64 -and -not $c64.dominant_properties.ContainsKey('b')) '支配的な書式は打ち消した側（11文字 対 4文字）'

# **共有文字列が1つも無いブック。** 以前の実装は共有表に rPr が無い時点で
# 空を返していたので、inlineStr しか無いブックは丸ごと素通りだった。
$inlineOnlyPath = Join-Path $workDir 'inline-only.xlsx'
New-YakuRunFixtureXlsx -Path $inlineOnlyPath -Parts @{
    'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="明細" sheetId="1" r:id="rId7"/></sheets></workbook>'
    'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/run-source.xml"/></Relationships>'
    'xl/styles.xml' = $stylesXml
    'xl/worksheets/run-source.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' +
        '<row r="60"><c r="C60" s="0" t="inlineStr"><is><r><t>テストテスト</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="游ゴシック"/><family val="3"/><charset val="128"/><scheme val="minor"/></rPr><t>テスト</t></r></is></c></row>' +
        '</sheetData></worksheet>'
}
$inlineOnlySheets = @(Get-YakuXlsxNonPlainCells -Path $inlineOnlyPath)
$inlineOnlyAddresses = @()
if ($inlineOnlySheets.Count -eq 1) { $inlineOnlyAddresses = @(@($inlineOnlySheets[0].non_plain_cells) | ForEach-Object { [string]$_.address }) }
Chk (($inlineOnlyAddresses -join ',') -eq 'C60') ('共有文字列が1つも無いブックでも inlineStr の run を拾う: [' + ($inlineOnlyAddresses -join ',') + ']')

# 同じ共有文字列でも、参照するセルの字体が違えば答えが変わる。
# 「run を数える」実装はここで必ず外す（C30 も C31 も run は2つある）。
# 箱から外すのはどちらも同じ。分かれるのは**揃え直しの代入表**である。
Chk ((Get-YakuDiffering -Cells $nonPlainCells -Address 'C30') -eq '') ('太字のセルの中で <b/> を言い直す run は、混在ではない: [' + (Get-YakuDiffering -Cells $nonPlainCells -Address 'C30') + ']')
Chk ((Get-YakuDiffering -Cells $nonPlainCells -Address 'C31') -eq 'b') ('同じ共有文字列でも、普通のセルから参照すれば混在になる: [' + (Get-YakuDiffering -Cells $nonPlainCells -Address 'C31') + ']')

# Excel が実際に書く形。セルの字体が太字で、あとの run が
# 「太字を含まない rPr」で打ち消している。rPr を差分として扱うと拾えない。
$c50 = Get-YakuNonPlainCellByAddress -NonPlainCells $nonPlainCells -Address 'C50'
Chk ($null -ne $c50) 'セルの字体が太字で、rPr が太字を書かずに打ち消す形を拾う'
Chk ($null -ne $c50 -and (@($c50.differing_properties) -join ',') -eq 'b') 'その食い違いも太字だと分かる'
Chk ($null -ne $c50 -and -not $c50.dominant_properties.ContainsKey('b')) '支配的な書式は打ち消した側（11文字 対 4文字）'

$c8 = Get-YakuNonPlainCellByAddress -NonPlainCells $nonPlainCells -Address 'C8'
Chk ($null -ne $c8 -and [int]$c8.row -eq 8 -and [int]$c8.col -eq 3) 'C8 を行8・列3として返す'
Chk ($null -ne $c8 -and @($c8.runs).Count -eq 3) 'run を3つとも返す'
# 符号化が壊れていれば、ここで文字数が変わる（BOM 無しで書くと日本語が化ける）。
Chk ($null -ne $c8 -and @($c8.runs)[0].length -eq 6 -and @($c8.runs)[1].length -eq 3 -and @($c8.runs)[2].length -eq 6) 'run の文字数が 6 / 3 / 6 で返る'
Chk ($null -ne $c8 -and (@($c8.differing_properties) -join ',') -eq 'b') '食い違っている項目は太字だけだと分かる'
# 支配的な書式＝文字数の合計がいちばん多いほう（太字ではない側が 12 文字）。
Chk ($null -ne $c8 -and -not $c8.dominant_properties.ContainsKey('b')) '支配的な書式は「太字ではない」ほう（12文字 対 3文字）'

$c23 = Get-YakuNonPlainCellByAddress -NonPlainCells $nonPlainCells -Address 'C23'
Chk ($null -ne $c23 -and (@($c23.differing_properties) -join ',') -eq 'u') 'C23 で食い違っているのは下線だけ'

# 読めないものを渡しても、書き戻しは続く（体裁は足しであって前提ではない）。
$brokenPath = Join-Path $workDir 'broken.xlsx'
Set-Content -LiteralPath $brokenPath -Value 'this is not a zip' -Encoding ASCII
Chk (@(Get-YakuXlsxNonPlainCells -Path $brokenPath).Count -eq 0) '壊れたファイルは空で返る（例外を投げない）'
Chk (@(Get-YakuXlsxNonPlainCells -Path (Join-Path $workDir 'nope.xlsx')).Count -eq 0) '無いファイルは空で返る'


# ===========================================================================
# 1b. 反転そのものの門（Excel は要らない）
#
#     いま  リッチだと分かったセルを箱から外す   → 見落としたら壊す
#     反転  平文だと証明できたセルだけ箱に入れる → 見落としたら遅くなるだけ
#
#     ここで見るのは「証明できる形が狭いこと」と「狭すぎないこと」の両方である。
#     片方だけだと、全部を証明できないことにした実装でも緑になる。
# ===========================================================================
Write-Host '平文だと証明できたセルだけを、箱に入れる' -ForegroundColor Cyan

$mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$pkgNs = 'http://schemas.openxmlformats.org/package/2006/relationships'
# **`<fills>` `<borders>` `<cellStyleXfs>` を省くと Excel が開かない。** ZIP として
# 読めるので検出器の表明は通り、実機の表明だけが `Workbooks.Open` で落ちる
# （実測 2026-08-16: COMException「Workbooks クラスの Open プロパティを取得できません」）。
$proofStyles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="' + $mainNs + '"><fonts count="2"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font><font><sz val="6"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>'
$proofBoldRpr = '<rPr><b/><sz val="11"/><color theme="1"/><rFont val="Calibri"/><family val="2"/></rPr>'

function New-YakuProofWorkbook {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$SheetBody,
        [AllowNull()][string]$SharedBody = $null,
        [string]$SheetElement = '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    )
    # **Excel で開ける形にしておく。** `[Content_Types].xml` と `_rels/.rels` が
    # 無い書庫は ZIP としては読めるが、Excel は Workbooks.Open で撥ねる。
    # 検出器だけを測る題材と、実機で開く題材を分けると、同じ題材で両方を
    # 測れなくなるので、はじめから完全な包みにする。
    $overrides = '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    $sheetRels = '<Relationship Id="rId3" Type="' + $relNs + '/styles" Target="styles.xml"/>'
    if ($null -ne $SharedBody) {
        $overrides += '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        $sheetRels += '<Relationship Id="rId2" Type="' + $relNs + '/sharedStrings" Target="sharedStrings.xml"/>'
    }
    $parts = @{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>' + $overrides + '</Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="' + $pkgNs + '"><Relationship Id="rId1" Type="' + $relNs + '/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="' + $mainNs + '" xmlns:r="' + $relNs + '"><sheets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></workbook>'
        'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="' + $pkgNs + '"><Relationship Id="rId1" Type="' + $relNs + '/worksheet" Target="worksheets/sheet1.xml"/>' + $sheetRels + '</Relationships>'
        'xl/styles.xml' = $proofStyles
        'xl/worksheets/sheet1.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + $SheetElement + '<sheetData>' + $SheetBody + '</sheetData></worksheet>'
    }
    if ($null -ne $SharedBody) {
        $parts['xl/sharedStrings.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="' + $mainNs + '">' + $SharedBody + '</sst>'
    }
    New-YakuRunFixtureXlsx -Path $Path -Parts $parts
}

function Get-YakuProofAddresses {
    param([Parameter(Mandatory=$true)][string]$Path)
    $out = @()
    foreach ($sheet in @(Get-YakuXlsxNonPlainCells -Path $Path)) {
        if ([string]$sheet.name -eq 'S1') { $out = @(@($sheet.non_plain_cells) | ForEach-Object { [string]$_.address }) }
    }
    return $out
}

function Get-YakuProofCells {
    param([Parameter(Mandatory=$true)][string]$Path)
    foreach ($sheet in @(Get-YakuXlsxNonPlainCells -Path $Path)) {
        if ([string]$sheet.name -eq 'S1') { return @($sheet.non_plain_cells) }
    }
    return @()
}

# --- 証明できる形と、証明できない形を1枚に並べる ---------------------------
# si 0 … 平文（<t> 1つだけ）
# si 1 … `<t>` と `<r>` の混在。**Excel は部分太字として描く**のに、直下の `<r>` しか
#         集めない実装では run が1つになって「差は無い」に化ける（実測 2026-08-16）
# si 2 … ふりがな（`<rPh>`）。**Excel 自身が書く形である**
# si 3 … `<phoneticPr>` だけ。ふりがなの本文は無いが、`<t>` 1つではない
$proofShared =
    '<si><t>PLAIN</t></si>' +
    '<si><t xml:space="preserve">MIXED</t><r>' + $proofBoldRpr + '<t>BOLDPART</t></r></si>' +
    '<si><t>TOKYO</t><rPh sb="0" eb="5"><t>YOMI</t></rPh><phoneticPr fontId="1"/></si>' +
    '<si><t>PHONLY</t><phoneticPr fontId="1"/></si>'
$proofSheet =
    '<row r="2">' +
    '<c r="B2" s="0" t="s"><v>0</v></c>' +
    '<c r="C2" s="0" t="s"><v>1</v></c>' +
    '<c r="D2" s="0" t="s"><v>2</v></c>' +
    '<c r="E2" s="0" t="s"><v>3</v></c>' +
    '<c r="F2" s="0"><v>123.5</v></c>' +
    '<c r="G2" s="0" t="str"><f>A1</f><v>calculated</v></c>' +
    '<c r="H2" s="0" t="inlineStr"><is><t>PLAINLINE</t></is></c>' +
    '<c r="I2" s="0" t="inlineStr"><is><t xml:space="preserve">MIXED</t><r>' + $proofBoldRpr + '<t>BOLDPART</t></r></is></c>' +
    "<c r='J2' s='0' t='s'><v>1</v></c>" +
    '<c r="K2" s="0" t="q"><v>0</v></c>' +
    '<c r="L2" s="0"/>' +
    '<c r="M2" s="0" t="b"><v>1</v></c>' +
    '<c r="N2" s="0" t="e"><v>#N/A</v></c>' +
    '</row>'
$proofPath = Join-Path $workDir 'proof.xlsx'
New-YakuProofWorkbook -Path $proofPath -SheetBody $proofSheet -SharedBody $proofShared
$proofCells = @(Get-YakuProofCells -Path $proofPath)
$proofAddresses = @($proofCells | ForEach-Object { [string]$_.address })

Chk (($proofAddresses -join ',') -eq 'C2,D2,E2,H2,I2,J2,K2') ('証明できないのは7件（C2 D2 E2 H2 I2 J2 K2）: [' + ($proofAddresses -join ',') + ']')
# 対の表明。**狭すぎたらここが赤になる。** 平文の共有文字列・数値・数式・真偽・
# 誤り・空セルは、1つも箱から外れてはいけない。
Chk (-not ($proofAddresses -contains 'B2')) '平文の共有文字列（<t> 1つだけ）は箱に入れてよい'
Chk (-not ($proofAddresses -contains 'F2')) '数値のセルは箱に入れてよい'
Chk (-not ($proofAddresses -contains 'G2')) '数式の文字列結果（t="str"）は箱に入れてよい'
Chk (-not ($proofAddresses -contains 'L2')) '空のセルは箱に入れてよい'
Chk (-not ($proofAddresses -contains 'M2')) '真偽のセルは箱に入れてよい'
Chk (-not ($proofAddresses -contains 'N2')) '誤り値のセルは箱に入れてよい'

# 穴1: `<t>` と `<r>` の混在。共有文字列側とセル内直書き側の**両方**。
Chk ((Get-YakuDiffering -Cells $proofCells -Address 'C2') -eq 'b') ('共有文字列の <t>+<r> 混在を、太字の食い違いとして解く（穴1）: [' + (Get-YakuDiffering -Cells $proofCells -Address 'C2') + ']')
Chk ((Get-YakuDiffering -Cells $proofCells -Address 'I2') -eq 'b') ('inlineStr の <t>+<r> 混在も同じ（穴1）: [' + (Get-YakuDiffering -Cells $proofCells -Address 'I2') + ']')
$c2Proof = Get-YakuNonPlainCellByAddress -NonPlainCells $proofCells -Address 'C2'
Chk ($null -ne $c2Proof -and @($c2Proof.runs).Count -eq 2) ('裸の <t> も run として数える（数えないと1つになり、Count の門で消える）: ' + @($c2Proof.runs).Count)
Chk ($null -ne $c2Proof -and @($c2Proof.runs)[0].length -eq 5 -and @($c2Proof.runs)[1].length -eq 8) 'その run の文字数は 5 / 8'

# 穴2: 単引用符の属性。J2 は C2 と同じ共有文字列を、引用符だけ変えて指している。
Chk ($proofAddresses -contains 'J2') "単引用符で書いた属性のセルも住所を取り出せる（穴2）"
$j2Proof = Get-YakuNonPlainCellByAddress -NonPlainCells $proofCells -Address 'J2'
Chk ($null -ne $j2Proof -and [int]$j2Proof.row -eq 2 -and [int]$j2Proof.col -eq 10) ('その J2 を行2・列10として返す（引用符で住所がずれない）: ' + [string]$j2Proof.row + ',' + [string]$j2Proof.col)

# 穴3: ふりがな。**Excel 自身が書く形である。** 本文は1バイトも変わらないので、
# 文字を比べる検査では永久に見つからない。実機の表明は下の 4 節にある。
Chk ($proofAddresses -contains 'D2') 'ふりがな（<rPh>）を持つセルは平文だと証明できない（穴3）'
Chk ((Get-YakuDiffering -Cells $proofCells -Address 'D2') -eq '') 'そのセルに揃え直しの代入は無い（run が無いので当然）'
Chk ($proofAddresses -contains 'E2') '<phoneticPr> だけを持つセルも、<t> 1つではないので証明できない'

# 知らない形はすべて「証明できない」へ落ちる。ここが反転の要点である。
Chk ($proofAddresses -contains 'K2') '知らない型（t="q"）のセルは証明できない'
Chk ($proofAddresses -contains 'H2') 'inlineStr は中身が <t> 1つでも証明できない（置き場所そのものを信用しない）'

# --- 想定外の書き方に当たったら、そのシート全体を証明できないと扱う ---------
# 住所が分からないセルが1つでもあれば、どの箱が安全かを言えない。
$badQuotePath = Join-Path $workDir 'proof-badquote.xlsx'
New-YakuProofWorkbook -Path $badQuotePath -SharedBody $proofShared -SheetBody (
    '<row r="2"><c r="B2" s="0" t="s"><v>0</v></c><c r=C2 s="0" t="s"><v>0</v></c></row>')
$badQuoteCells = @(Get-YakuProofCells -Path $badQuotePath)
Chk ($badQuoteCells.Count -eq 1 -and [string]$badQuoteCells[0].scope -eq 'sheet') ('引用符の無い属性に当たったら、そのシートを丸ごと証明できないとする: ' + $badQuoteCells.Count + '件 scope=' + [string]$badQuoteCells[0].scope)

$noRefPath = Join-Path $workDir 'proof-noref.xlsx'
New-YakuProofWorkbook -Path $noRefPath -SharedBody $proofShared -SheetBody (
    '<row r="2"><c r="B2" s="0" t="s"><v>0</v></c><c s="0" t="s"><v>1</v></c></row>')
$noRefCells = @(Get-YakuProofCells -Path $noRefPath)
Chk ($noRefCells.Count -eq 1 -and [string]$noRefCells[0].scope -eq 'sheet') ('住所を持たないセルに当たっても同じ: ' + $noRefCells.Count + '件 scope=' + [string]$noRefCells[0].scope)

# シート丸ごとの1件は、箱の行と列によらず必ず一括を捨てさせる。
$farBounds = New-YakuExcelCellItemsBounds -Items @(
    [pscustomobject]@{ Row=900; Col=40; Translation='x'; Block=$null },
    [pscustomobject]@{ Row=901; Col=41; Translation='y'; Block=$null }
)
Chk ($null -ne (Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $noRefCells -Bounds $farBounds -TargetKeys @{ '900,40'=$true; '901,41'=$true })) 'シート丸ごとの1件は、遠く離れた箱でも一括を捨てさせる'
Chk (@(Get-YakuExcelRunCellFontAssignments -RunCell $noRefCells[0] -OutputFontName '').Count -eq 0) 'そのシート丸ごとの1件は、揃え直しには1つも代入しない'

# --- 断片を解析できないとき（前任者が入れたが表明が1件も無かった枝）--------
# `<worksheet>` 側で宣言した接頭辞を `<is>` の中で使うと、断片だけを切り出した
# ところで未宣言になり LoadXml が投げる。**投げたものを握りつぶして空を返すと、
# 守りが丸ごと消える。** だからここは「箱から外れていること」を先に見る。
$prefixedSheetElement = '<worksheet xmlns="' + $mainNs + '" xmlns:x="' + $mainNs + '">'
$brokenFragPath = Join-Path $workDir 'proof-brokenfrag.xlsx'
New-YakuProofWorkbook -Path $brokenFragPath -SheetElement $prefixedSheetElement -SheetBody (
    '<row r="2"><c r="B2" s="0" t="inlineStr"><is><x:t>MIXED</x:t><x:r><x:rPr><x:b/></x:rPr><x:t>BOLDPART</x:t></x:r></is></c></row>')
$brokenFragCells = @(Get-YakuProofCells -Path $brokenFragPath)
Chk (@($brokenFragCells | ForEach-Object { [string]$_.address }) -contains 'B2') '断片を解析できなくても、そのセルは箱から外れたままである'
$b2Broken = Get-YakuNonPlainCellByAddress -NonPlainCells $brokenFragCells -Address 'B2'
Chk ($null -ne $b2Broken -and @($b2Broken.runs).Count -eq 0) '解析できなかった断片からは run を作らない（当てずっぽうで揃えない）'
Chk (@(Get-YakuExcelRunCellFontAssignments -RunCell $b2Broken -OutputFontName '').Count -eq 0) 'そのセルへ代入する項目も1つも無い'

# 対の表明。**同じ中身でも、接頭辞が断片の中で宣言されていれば解ける。**
# これが無いと「いつも解けない」実装でも上の3つは緑になる。
$okFragPath = Join-Path $workDir 'proof-okfrag.xlsx'
New-YakuProofWorkbook -Path $okFragPath -SheetElement $prefixedSheetElement -SheetBody (
    '<row r="2"><c r="B2" s="0" t="inlineStr"><is xmlns:x="' + $mainNs + '"><x:t>MIXED</x:t><x:r><x:rPr><x:b/></x:rPr><x:t>BOLDPART</x:t></x:r></is></c></row>')
$okFragCells = @(Get-YakuProofCells -Path $okFragPath)
$b2Ok = Get-YakuNonPlainCellByAddress -NonPlainCells $okFragCells -Address 'B2'
Chk ($null -ne $b2Ok -and @($b2Ok.runs).Count -eq 2) ('接頭辞が断片の中で宣言されていれば、同じ中身から run を2つ解く: ' + (@($b2Ok.runs).Count))
Chk ((Get-YakuDiffering -Cells $okFragCells -Address 'B2') -eq 'b') ('その食い違いは太字だと分かる: [' + (Get-YakuDiffering -Cells $okFragCells -Address 'B2') + ']')

# --- 過剰な安全側倒れを弾く対の表明 ---------------------------------------
# **平文だけのブックでは、証明できないセルが1件も出てはいけない。**
# ここが赤なら、証明できる形が狭すぎて普通のブックの箱まで死んでいる。
$allPlainPath = Join-Path $workDir 'proof-allplain.xlsx'
$plainRows = New-Object System.Text.StringBuilder
$plainShared = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 40; $i++) { $null = $plainShared.Append('<si><t>Shared value ' + $i + '</t></si>') }
for ($r = 1; $r -le 40; $r++) {
    $null = $plainRows.Append('<row r="' + $r + '"><c r="A' + $r + '" s="0" t="s"><v>' + ($r - 1) + '</v></c><c r="B' + $r + '" s="0"><v>' + ($r * 2) + '</v></c><c r="C' + $r + '" s="0"/></row>')
}
New-YakuProofWorkbook -Path $allPlainPath -SharedBody $plainShared.ToString() -SheetBody $plainRows.ToString()
$allPlainSheets = @(Get-YakuXlsxNonPlainCells -Path $allPlainPath)
Chk ($allPlainSheets.Count -eq 0) ('平文だけのブックからは、証明できないセルが1件も出ない: シート ' + $allPlainSheets.Count + '枚')
# ===========================================================================
# 2. 巻き添え（D）の判断。Excel は要らない
# ===========================================================================
Write-Host '**対象ではない** run セルを挟む箱だけを、一括経路から外す' -ForegroundColor Cyan

# B8 と D8 だけが翻訳対象。C8 は対象ではないのに、箱 B8:D8 の中にいる。
$straddlingItems = @(
    [pscustomobject]@{ Row=8; Col=2; Translation='Heading'; Block=$null },
    [pscustomobject]@{ Row=8; Col=4; Translation='FX'; Block=$null }
)
$straddlingBounds = New-YakuExcelCellItemsBounds -Items $straddlingItems
$straddlingTargets = @{ '8,2' = $true; '8,4' = $true }
$hit = Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $nonPlainCells -Bounds $straddlingBounds -TargetKeys $straddlingTargets
Chk ($null -ne $hit -and [string]$hit.address -eq 'C8') '対象を1つも含まなくても、箱の中にいる非対象の run セルを見つける'

# **ここが今回の直しの中身。** 同じ箱・同じ run セルでも、そのセルが翻訳対象なら
# 捨てない。対象セルの run は経路によらず Value2 で消え、そのあと分岐の外の
# 揃え直しが支配的書式へ戻す。捨てても得るものが無い。
$c8AsTarget = @{ '8,2' = $true; '8,3' = $true; '8,4' = $true }
Chk ($null -eq (Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $nonPlainCells -Bounds $straddlingBounds -TargetKeys $c8AsTarget)) '同じ箱でも、その run セルが翻訳対象なら止めない'

# 対象表そのものが無いときは、遅いほうへ倒す（判断の材料が無い）。
Chk ($null -ne (Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $nonPlainCells -Bounds $straddlingBounds)) '対象表を渡さなければ、従来どおり全部を非対象とみなす'

# **所属で見る。件数で見ると入れ替わりに気づけない。** 箱 B8:D23 には C8 と C23 の
# 2件が入っている。C8 だけを対象にすれば、返るのは C23 でなければならない。
# 「1件見つけた」を数えるだけの実装は、C8 を返してここで赤になる。
$twoRunItems = @(
    [pscustomobject]@{ Row=8; Col=2; Translation='x'; Block=$null },
    [pscustomobject]@{ Row=23; Col=4; Translation='y'; Block=$null }
)
$twoRunBounds = New-YakuExcelCellItemsBounds -Items $twoRunItems
$mixedHit = Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $nonPlainCells -Bounds $twoRunBounds -TargetKeys @{ '8,2'=$true; '8,3'=$true; '23,4'=$true }
Chk ($null -ne $mixedHit -and [string]$mixedHit.address -eq 'C23') ('対象の run セルを飛ばして、非対象のほうを返す（C8 ではなく C23）: ' + [string]$mixedHit.address)
Chk ($null -eq (Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $nonPlainCells -Bounds $twoRunBounds -TargetKeys @{ '8,2'=$true; '8,3'=$true; '23,3'=$true; '23,4'=$true })) '箱の中の run セルが全部対象なら、2件あっても止めない'

# 対の表明。**箱に run セルが入っていなければ素通しする。**
# これが無いと「無条件に止める」実装でも通ってしまう。
$clearItems = @(
    [pscustomobject]@{ Row=8; Col=6; Translation='x'; Block=$null },
    [pscustomobject]@{ Row=8; Col=7; Translation='y'; Block=$null }
)
$clearBounds = New-YakuExcelCellItemsBounds -Items $clearItems
Chk ($null -eq (Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells $nonPlainCells -Bounds $clearBounds -TargetKeys @{ '8,6'=$true; '8,7'=$true })) 'run セルを含まない箱は止めない（一括を殺さない）'
Chk ($null -eq (Get-YakuExcelNonTargetNonPlainCellInBounds -NonPlainCells @() -Bounds $straddlingBounds -TargetKeys $straddlingTargets)) 'run セルが1つも無いブックでは止めない'

# ===========================================================================
# 3. 滲み出し（A）の直し方。代入表そのものは Excel 無しで測れる
# ===========================================================================
Write-Host '書いた後に揃える書式を、食い違った項目だけに絞る' -ForegroundColor Cyan

$c8Assignments = @(Get-YakuExcelRunCellFontAssignments -RunCell $c8 -OutputFontName '')
Chk ($c8Assignments.Count -eq 1) ('触るのは1項目だけ（色も大きさも書体も触らない）: ' + $c8Assignments.Count)
Chk ($c8Assignments.Count -eq 1 -and [string]$c8Assignments[0].Property -eq 'Bold') '太字を揃える'
Chk ($c8Assignments.Count -eq 1 -and -not [bool]$c8Assignments[0].Value) '揃える先は「太字ではない」（滲み出した全体太字を戻す）'

$c23Assignments = @(Get-YakuExcelRunCellFontAssignments -RunCell $c23 -OutputFontName '')
Chk ($c23Assignments.Count -eq 1 -and [string]$c23Assignments[0].Property -eq 'Underline' -and [int]$c23Assignments[0].Value -eq -4142) '下線は xlUnderlineStyleNone へ戻す'

# 書体が食い違う run は、出力書体の設定と衝突する。設定があるほうを立てる。
$c40 = Get-YakuNonPlainCellByAddress -NonPlainCells $nonPlainCells -Address 'C40'
$c40Free = @(Get-YakuExcelRunCellFontAssignments -RunCell $c40 -OutputFontName '')
$c40Fixed = @(Get-YakuExcelRunCellFontAssignments -RunCell $c40 -OutputFontName 'Arial')
Chk (@($c40Free | Where-Object { [string]$_.Property -eq 'Name' }).Count -eq 1) '出力書体の指定が無ければ、支配的な書体へ揃える'
Chk ([string](@($c40Free | Where-Object { [string]$_.Property -eq 'Name' })[0].Value) -eq 'Meiryo') '支配的な書体は文字数の多いほう（6文字 対 2文字）'
Chk (@($c40Fixed | Where-Object { [string]$_.Property -eq 'Name' }).Count -eq 0) '出力書体の指定があれば、書体には触らない'

Chk (@(Get-YakuExcelRunCellFontAssignments -RunCell $null -OutputFontName '').Count -eq 0) 'run セルでなければ1つも代入しない'

# ===========================================================================
# 4. 実機（Excel が要る）
# ===========================================================================
if (-not (Test-YakuExcelAvailable)) {
    Write-Host 'Excel が無いため、実機の表明は未測定にする（赤へ畳まない）' -ForegroundColor Yellow
} else {
    $script:excelMeasured = $true
    Write-Host 'Excel が実際に書いたブックで、被害と直りを測る' -ForegroundColor Cyan

    $livePath = Join-Path $workDir 'live.xlsx'
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        $wb = $xl.Workbooks.Add()
        $ws = $wb.Worksheets.Item(1); $ws.Name = 'S1'
        # 実験B。セル全体が太字（run ではない）。これは壊してはならない。
        $ws.Cells.Item(8,2).Value2 = '見出し'
        $ws.Cells.Item(8,2).Font.Bold = $true
        # 実験A。**1文字目から**太字にする。滲み出しは1文字目の書式が広がる形で
        # 起きるので、ここを太字にしないと被害が「太字が消える」向きに出ず、
        # 直っていない実装でも通ってしまう。
        $ws.Cells.Item(8,3).Value2 = 'テストテストテストテストテスト'
        $ws.Cells.Item(8,3).Characters(1,4).Font.Bold = $true
        $ws.Cells.Item(8,4).Value2 = '為替'
        $wb.SaveAs($livePath, 51)
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }

    $liveSheets = @(Get-YakuXlsxNonPlainCells -Path $livePath)
    $liveNonPlainCells = @()
    foreach ($sheet in $liveSheets) {
        if ([string]$sheet.name -eq 'S1') { $liveNonPlainCells = @($sheet.non_plain_cells) }
    }
    Chk ($liveNonPlainCells.Count -eq 1) ('Excel が書き出したブックで証明できないのは1件だけ（残りは平文として通る）: ' + $liveNonPlainCells.Count)
    Chk ((@($liveNonPlainCells | ForEach-Object { [string]$_.address })) -contains 'C8') '拾うのは C8（全体が太字の B8 は拾わない）'

    # 原本を Excel で開いたまま書き出す場面は珍しくない。ZipFile::OpenRead は
    # そこで落ちるが Copy-Item は通るので、**守りだけが黙って外れる**。
    # 2026-08-16 に利用者のテストファイルで実測した。
    $holder = New-Object -ComObject Excel.Application
    $holder.Visible = $false; $holder.DisplayAlerts = $false
    $heldCount = -1
    try {
        $heldWorkbook = $holder.Workbooks.Open($livePath)
        $heldCount = 0
        foreach ($sheet in @(Get-YakuXlsxNonPlainCells -Path $livePath)) {
            if ([string]$sheet.name -eq 'S1') { $heldCount = @($sheet.non_plain_cells).Count }
        }
        $heldWorkbook.Close($false)
    } finally {
        try { $holder.Quit() } catch {}
        Release-YakuComObject $holder
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    Chk ($heldCount -eq 1) ('原本を Excel で開いたままでも読める: ' + $heldCount)

    # --- D: 対象ではない C8 を挟む箱 -------------------------------------
    $damagedPath = Join-Path $workDir 'live-damaged.xlsx'
    $guardedPath = Join-Path $workDir 'live-guarded.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $damagedPath -Force
    Copy-Item -LiteralPath $livePath -Destination $guardedPath -Force

    $boxTargets = @{ '8,2' = $true; '8,4' = $true }
    $damaged = Invoke-YakuRunBoxProbe -Path $damagedPath -NonPlainCells @() -TargetKeys $boxTargets
    $guarded = Invoke-YakuRunBoxProbe -Path $guardedPath -NonPlainCells $liveNonPlainCells -TargetKeys $boxTargets

    Chk ([string]$damaged.Before -eq 'BBBB...........') ('元は1〜4文字目だけ太字: ' + [string]$damaged.Before)
    # 対の表明。守りを外せば**実際に壊れる**。壊れないなら、この門は何も見ていない。
    Chk ([bool]$damaged.Used) '守りを外すと、run セルを挟む箱でも一括で書く'
    Chk (([string]$damaged.After) -ne ([string]$damaged.Before)) ('守りを外すと、対象ではない C8 の部分太字が壊れる: ' + [string]$damaged.After)
    Chk (-not [bool]$guarded.Used) '非対象の run セルを挟む箱は一括経路へ入らない'
    Chk (([string]$guarded.After) -eq ([string]$guarded.Before)) ('巻き添えにならない: ' + [string]$guarded.After)

    # --- 直し: 対象だけが run セルなら、箱を捨てない ----------------------
    # ここは本番のシート単位の入口を通す。対象表を箱まで引き回す配線が
    # どこかで切れれば、一括を使う側が落ちる。
    $bulkPath = Join-Path $workDir 'live-bulk.xlsx'
    $skipPath = Join-Path $workDir 'live-skip.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $bulkPath -Force
    Copy-Item -LiteralPath $livePath -Destination $skipPath -Force
    $bulkRun = Invoke-YakuRunSheetWriteback -Path $bulkPath -NonPlainCells $liveNonPlainCells -TargetCols @(2,3,4)
    $skipRun = Invoke-YakuRunSheetWriteback -Path $skipPath -NonPlainCells $liveNonPlainCells -TargetCols @(2,4)

    # **題材がその枝へ本当に届いているかを先に確かめる。** 箱が使われない理由は
    # 面積・数式・結合・run と4つある。`bulk_box` だけを見ると、run とは関係ない
    # 理由で落ちていても「守りが効いた」に見えてしまう。理由ごとの目印で分ける。
    Chk ([string]$bulkRun.Before -eq 'BBBB...........') ('題材は1〜4文字目だけ太字で始まる: ' + [string]$bulkRun.Before)
    Chk ([int]$bulkRun.BulkBox -eq 1) ('対象だけが run セルである箱は、一括経路を使う: bulkBox=' + [string]$bulkRun.BulkBox + ' mode=' + [string]$bulkRun.Mode)
    # **速さは時計ではなく名札で守る。** 機械の負荷で揺れる ms を表明にすると
    # 偽の赤を生む。経路の名札（bulk_box / bulk_mode / bulk_run_cell_skips）は
    # 揺れない。ここは `-ne 'fallback'` の否定ではなく、**value2 の系統である**と
    # 名指しする（否定だけだと、別の遅い経路の名前が入っても緑のまま通る）。
    Chk ([string]$bulkRun.Mode -match '^value2') ('その一括が value2 の経路だと名札に残る: mode=' + [string]$bulkRun.Mode)
    Chk ([int]$bulkRun.RunSkips -eq 0) 'run を理由に箱を捨てていない（面積・数式・結合とは別勘定）'
    Chk ([string]$bulkRun.C8Value -eq 'Test test test test test') '一括経路でも訳文がちゃんと入る'
    # 一括で書いた対象 run セルも、**文字ごとに測って**支配的書式へ揃っている。
    Chk ([string]$bulkRun.After -eq ('.' * ([string]$bulkRun.C8Value).Length)) ('一括経路で書いた対象 run セルも、1文字ずつ測って太字が残らない: ' + [string]$bulkRun.After)
    Chk ([int]$bulkRun.Levelled -eq 1) '揃え直したのは1セル'
    Chk ([string]$bulkRun.B8Bold -eq 'bold') 'セル全体が太字だったセルは、一括経路でも太字のまま（実験B を壊さない）'

    # 対の表明。**非対象**の run セルが箱にいれば、従来どおり一括を捨てる。
    Chk ([int]$skipRun.BulkBox -eq 0) ('非対象の run セルが箱にいれば、一括を使わない: bulkBox=' + [string]$skipRun.BulkBox)
    Chk ([int]$skipRun.RunSkips -eq 1) ('しかもその理由が run である: runSkips=' + [string]$skipRun.RunSkips)
    Chk ([string]$skipRun.After -eq [string]$skipRun.Before) ('巻き添えが起きない。非対象セルの部分太字が1文字ずつ残る: ' + [string]$skipRun.After)
    Chk ([string]$skipRun.C8Value -eq 'テストテストテストテストテスト') '訳していないセルは本文も変わらない'
    Chk ([int]$skipRun.Levelled -eq 0) '訳していない run セルは揃え直しの対象でもない'

    # --- A: 滲み出しと、揃え直し ----------------------------------------
    # 箱を外した先の経路（矩形）でも滲み出すことを、まず測る。ここが滲まないなら
    # あとの「直った」は箱を外した効果でしかなく、揃え直しは何もしていない。
    $levelPath = Join-Path $workDir 'live-level.xlsx'
    $untouchedPath = Join-Path $workDir 'live-untouched.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $levelPath -Force
    Copy-Item -LiteralPath $livePath -Destination $untouchedPath -Force
    $levelProbe = Invoke-YakuRunLevelProbe -Path $levelPath -NonPlainCells $liveNonPlainCells -TargetKeys @{ '8,2'=$true; '8,3'=$true; '8,4'=$true }
    Chk ([string]$levelProbe.AfterWrite -eq 'bold') ('矩形の2次元配列代入でも、1文字目の太字が全体へ滲み出す: ' + [string]$levelProbe.AfterWrite)
    Chk ([string]$levelProbe.AfterLevel -eq 'plain') ('揃え直しで、支配的な書式（太字ではない）へ戻る: ' + [string]$levelProbe.AfterLevel)
    Chk ([int]$levelProbe.Levelled -eq 1) '揃え直したセルは1つ'

    # 訳文を書いていない run セルには触らない。
    $untouchedProbe = Invoke-YakuRunLevelProbe -Path $untouchedPath -NonPlainCells $liveNonPlainCells -TargetKeys @{ '99,99'=$true }
    Chk ([int]$untouchedProbe.Levelled -eq 0) '訳文を書いていない run セルには1つも代入しない'
    Chk ([string]$untouchedProbe.AfterLevel -eq [string]$untouchedProbe.AfterWrite) '触らないセルは、揃え直しの前後で変わらない'

    # --- A: 本番の入口を通す --------------------------------------------
    $settings = Read-YakuSettings -Root $root
    $fixedPath = Join-Path $workDir 'live-fixed.xlsx'
    $smearPath = Join-Path $workDir 'live-smear.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $fixedPath -Force
    Copy-Item -LiteralPath $livePath -Destination $smearPath -Force

    Invoke-YakuRunWriteback -Path $fixedPath -SourcePath $livePath -Settings $settings
    # 対の表明。原本を読めなければ run セルは分からず、滲み出しはそのまま出る。
    Invoke-YakuRunWriteback -Path $smearPath -SourcePath (Join-Path $workDir 'no-such-source.xlsx') -Settings $settings

    $fixedState = Get-YakuRunCellState -Path $fixedPath
    $smearState = Get-YakuRunCellState -Path $smearPath

    Chk ([string]$fixedState.C8Value -eq 'Test test test test test') '訳文はちゃんと書けている'
    Chk ([string]$fixedState.B8Value -eq 'Heading' -and [string]$fixedState.D8Value -eq 'FX') '同じ行の他のセルも書けている（一括を外しても取りこぼさない）'
    Chk ([string]$smearState.C8Bold -eq 'bold') ('守りが無ければ、1文字目の太字が全体へ滲み出す: ' + [string]$smearState.C8Bold)
    Chk ([string]$fixedState.C8Bold -eq 'plain') ('書いた後に、支配的な書式（太字ではない）へ揃う: ' + [string]$fixedState.C8Bold)
    Chk ([string]$fixedState.B8Bold -eq 'bold') 'セル全体が太字だったセルは太字のまま（実験B を壊さない）'

    # --- D: セルの中へ直に書いた run（inlineStr）でも巻き添えにならない ----
    # **Excel はこの形を書かない。** 書くのは一部の ERP・帳票出力・ライブラリで、
    # 利用者のファイルがその形かは測っていない。だから題材は手で組む。
    # 中身は検証者が実測に使ったものと同じ:
    #   B2 … 共有文字列の部分太字・**翻訳対象**
    #   C2 … inlineStr の部分太字・**非対象**（見た目は B2 と同じ）
    #   D2 … 対象。これで箱が B2:D2 になり、C2 が真ん中に挟まる
    # 検出器が inlineStr を見ていなかったとき、C2 は本文が1バイトも変わらないまま
    # `......BBBBBBBB` → `..............` になった。
    Write-Host 'セルの中へ直に書いた run が、箱の巻き添えで消えない' -ForegroundColor Cyan
    $ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $rns = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $pns = 'http://schemas.openxmlformats.org/package/2006/relationships'
    $inlineBoldRpr = '<rPr><b/><sz val="11"/><color theme="1"/><rFont val="Calibri"/><family val="2"/></rPr>'
    $inlineParts = @{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="' + $pns + '"><Relationship Id="rId1" Type="' + $rns + '/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="' + $ns + '" xmlns:r="' + $rns + '"><sheets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></workbook>'
        'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="' + $pns + '"><Relationship Id="rId1" Type="' + $rns + '/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="' + $rns + '/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId3" Type="' + $rns + '/styles" Target="styles.xml"/></Relationships>'
        'xl/styles.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="' + $ns + '"><fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>'
        'xl/sharedStrings.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="' + $ns + '" count="1" uniqueCount="1"><si><r><t xml:space="preserve">SHARED</t></r><r>' + $inlineBoldRpr + '<t xml:space="preserve">BOLDPART</t></r></si></sst>'
        'xl/worksheets/sheet1.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="' + $ns + '"><sheetData><row r="2"><c r="B2" s="0" t="s"><v>0</v></c><c r="C2" s="0" t="inlineStr"><is><r><t xml:space="preserve">INLINE</t></r><r>' + $inlineBoldRpr + '<t xml:space="preserve">BOLDPART</t></r></is></c><c r="D2" s="0" t="inlineStr"><is><t xml:space="preserve">PLAIN</t></is></c></row></sheetData></worksheet>'
    }
    $inlineSrc = Join-Path $workDir 'inline-src.xlsx'
    New-YakuRunFixtureXlsx -Path $inlineSrc -Parts $inlineParts

    $inlineDetected = @()
    foreach ($sheet in @(Get-YakuXlsxNonPlainCells -Path $inlineSrc)) {
        if ([string]$sheet.name -eq 'S1') { $inlineDetected = @($sheet.non_plain_cells) }
    }
    $inlineAddresses = @($inlineDetected | ForEach-Object { [string]$_.address })
    Chk (($inlineAddresses -join ',') -eq 'B2,C2,D2') ('共有文字列の B2 と inlineStr の C2 / D2 を全部拾う（inlineStr は中身が平文でも証明できない）: [' + ($inlineAddresses -join ',') + ']')

    function Invoke-YakuInlineBoxProbe {
        param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][object[]]$NonPlainCells)
        $xl = New-Object -ComObject Excel.Application
        $xl.Visible = $false; $xl.DisplayAlerts = $false
        $result = $null
        try {
            $wb = $xl.Workbooks.Open($Path)
            $ws = $wb.Worksheets.Item('S1')
            $before = Get-YakuRunPerCharBold -Worksheet $ws -Row 2 -Col 3
            $blocks = @(
                [pscustomobject]@{ Id='b2'; Text='SHAREDBOLDPART'; Location='S1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=2; Col=2; A1='B2'; Merged=$false } },
                [pscustomobject]@{ Id='d2'; Text='PLAIN'; Location='S1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=2; Col=4; A1='D2'; Merged=$false } }
            )
            $warnings = New-Object System.Collections.Generic.List[object]
            $metrics = @{}
            $null = Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks ([object[]]$blocks) `
                -TranslationByBlockId @{ 'b2' = 'Translated B2'; 'd2' = 'Translated D2' } `
                -OutputFontName '' -Warnings $warnings -Metrics $metrics -NonPlainCells $NonPlainCells
            $result = [pscustomobject]@{
                Before   = [string]$before
                After    = [string](Get-YakuRunPerCharBold -Worksheet $ws -Row 2 -Col 3)
                C2Value  = [string]$ws.Cells.Item(2,3).Value2
                BulkBox  = [int]$metrics['bulk_box']
                RunSkips = [int]$metrics['bulk_non_plain_skips']
            }
            $wb.Close($false)
        } finally {
            try { $xl.Quit() } catch {}
            Release-YakuComObject $xl
            try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
        }
        return $result
    }

    $inlineGuardedPath = Join-Path $workDir 'inline-guarded.xlsx'
    $inlineBlindPath = Join-Path $workDir 'inline-blind.xlsx'
    Copy-Item -LiteralPath $inlineSrc -Destination $inlineGuardedPath -Force
    Copy-Item -LiteralPath $inlineSrc -Destination $inlineBlindPath -Force
    $inlineGuarded = Invoke-YakuInlineBoxProbe -Path $inlineGuardedPath -NonPlainCells $inlineDetected
    # 対の表明。**検出器に映らなければ実際に壊れる。** 壊れないなら、この門は
    # 何も見ていない（inlineStr を見ていなかった実装の再現がこちら）。
    $inlineBlind = Invoke-YakuInlineBoxProbe -Path $inlineBlindPath -NonPlainCells @()

    Chk ([string]$inlineGuarded.Before -eq '......BBBBBBBB') ('題材は Excel から見ても後半だけ太字: ' + [string]$inlineGuarded.Before)
    Chk ([int]$inlineBlind.BulkBox -eq 1) '検出器に映らなければ、C2 を挟んだ箱でも一括で書く'
    Chk (([string]$inlineBlind.After) -ne ([string]$inlineBlind.Before)) ('そのとき C2 の部分太字は実際に消える: ' + [string]$inlineBlind.After)
    Chk ([string]$inlineBlind.C2Value -eq 'INLINEBOLDPART') '消えても本文は1バイトも変わらない（本文の照合では永久に見つからない）'
    Chk ([int]$inlineGuarded.BulkBox -eq 0 -and [int]$inlineGuarded.RunSkips -eq 1) ('検出器が拾えば、run を理由に箱を捨てる: bulkBox=' + [string]$inlineGuarded.BulkBox + ' runSkips=' + [string]$inlineGuarded.RunSkips)
    Chk ([string]$inlineGuarded.After -eq '......BBBBBBBB') ('C2 の1文字ずつが元のまま残る: ' + [string]$inlineGuarded.After)

    # --- D: ふりがな（<rPh>）が箱の巻き添えで消えない --------------------
    # **これは Excel 自身が書く形である。** 本文 `東京` は1バイトも変わらないまま、
    # `Phonetics.Count` が 1 → 0 になった（実測 2026-08-16、本番の入口を通した）。
    # 日英の道具として、和文原本のふりがなは想定しうる母集団である。
    # **頻度は語らない。** 利用者のファイルがどの形かは測っていない。
    Write-Host 'ふりがなが、箱の巻き添えで消えない' -ForegroundColor Cyan
    # 日本語は符号位置から組み立てて、使う前に印字して確かめる。
    $tokyo = -join (@(0x6771, 0x4EAC) | ForEach-Object { [char]$_ })
    $yomi = -join (@(0x30C8, 0x30A6, 0x30AD, 0x30E7, 0x30A6) | ForEach-Object { [char]$_ })
    Write-Host ('  題材の符号位置: value=' + (($tokyo.ToCharArray() | ForEach-Object { [int][char]$_ }) -join '.') + ' yomi=' + (($yomi.ToCharArray() | ForEach-Object { [int][char]$_ }) -join '.'))
    Chk ($tokyo.Length -eq 2 -and $yomi.Length -eq 5) ('組み立てた文字列の長さが 2 / 5: ' + $tokyo.Length + ' / ' + $yomi.Length)

    # B2 と D2 が対象、C2 は**非対象**でふりがなを持つ。箱は B2:D2 になる。
    $phoneticShared =
        '<si><t>HEAD</t></si>' +
        '<si><t>' + $tokyo + '</t><rPh sb="0" eb="2"><t>' + $yomi + '</t></rPh><phoneticPr fontId="1"/></si>' +
        '<si><t>TAIL</t></si>'
    $phoneticSheet = '<row r="2"><c r="B2" s="0" t="s"><v>0</v></c><c r="C2" s="0" t="s"><v>1</v></c><c r="D2" s="0" t="s"><v>2</v></c></row>'
    $phoneticSrc = Join-Path $workDir 'phonetic-src.xlsx'
    New-YakuProofWorkbook -Path $phoneticSrc -SharedBody $phoneticShared -SheetBody $phoneticSheet

    $phoneticCells = @(Get-YakuProofCells -Path $phoneticSrc)
    Chk ((@($phoneticCells | ForEach-Object { [string]$_.address }) -join ',') -eq 'C2') ('ふりがなを持つ C2 だけが証明できない: [' + (@($phoneticCells | ForEach-Object { [string]$_.address }) -join ',') + ']')

    function Invoke-YakuPhoneticBoxProbe {
        param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][object[]]$NonPlainCells)
        $xl = New-Object -ComObject Excel.Application
        $xl.Visible = $false; $xl.DisplayAlerts = $false
        $result = $null
        try {
            $wb = $xl.Workbooks.Open($Path)
            $ws = $wb.Worksheets.Item('S1')
            $before = Get-YakuPhoneticState -Worksheet $ws -Row 2 -Col 3
            $blocks = @(
                [pscustomobject]@{ Id='b2'; Text='HEAD'; Location='S1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=2; Col=2; A1='B2'; Merged=$false } },
                [pscustomobject]@{ Id='d2'; Text='TAIL'; Location='S1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=2; Col=4; A1='D2'; Merged=$false } }
            )
            $warnings = New-Object System.Collections.Generic.List[object]
            $metrics = @{}
            $null = Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks ([object[]]$blocks) `
                -TranslationByBlockId @{ 'b2' = 'Head EN'; 'd2' = 'Tail EN' } `
                -OutputFontName '' -Warnings $warnings -Metrics $metrics -NonPlainCells $NonPlainCells
            $result = [pscustomobject]@{
                Before   = $before
                After    = (Get-YakuPhoneticState -Worksheet $ws -Row 2 -Col 3)
                BulkBox  = [int]$metrics['bulk_box']
                RunSkips = [int]$metrics['bulk_non_plain_skips']
            }
            $wb.Close($false)
        } finally {
            try { $xl.Quit() } catch {}
            Release-YakuComObject $xl
            try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
        }
        return $result
    }

    $phoneticGuardedPath = Join-Path $workDir 'phonetic-guarded.xlsx'
    $phoneticBlindPath = Join-Path $workDir 'phonetic-blind.xlsx'
    Copy-Item -LiteralPath $phoneticSrc -Destination $phoneticGuardedPath -Force
    Copy-Item -LiteralPath $phoneticSrc -Destination $phoneticBlindPath -Force
    $phoneticGuarded = Invoke-YakuPhoneticBoxProbe -Path $phoneticGuardedPath -NonPlainCells $phoneticCells
    # 対の表明。**検出器に映らなければ実際に消える。** 消えないなら、この門は
    # 何も見ていない（ふりがなを見ていなかった実装の再現がこちら）。
    $phoneticBlind = Invoke-YakuPhoneticBoxProbe -Path $phoneticBlindPath -NonPlainCells @()

    Chk ([int]$phoneticGuarded.Before.Count -eq 1) ('題材は Excel から見てもふりがなを1件持つ: ' + [int]$phoneticGuarded.Before.Count)
    Chk ([string]$phoneticGuarded.Before.Text -eq $yomi) ('その読みは組み立てた文字列と一致する: ' + [string]$phoneticGuarded.Before.Text)
    Chk ([int]$phoneticBlind.BulkBox -eq 1) '検出器に映らなければ、C2 を挟んだ箱でも一括で書く'
    Chk ([int]$phoneticBlind.After.Count -eq 0) ('そのとき C2 のふりがなは実際に消える: phonetics=' + [int]$phoneticBlind.After.Count)
    Chk ([string]$phoneticBlind.After.Value -eq $tokyo) '消えても本文は1バイトも変わらない（本文の照合では永久に見つからない）'
    Chk ([int]$phoneticGuarded.BulkBox -eq 0 -and [int]$phoneticGuarded.RunSkips -eq 1) ('検出器が拾えば、箱を捨てる: bulkBox=' + [string]$phoneticGuarded.BulkBox + ' skips=' + [string]$phoneticGuarded.RunSkips)
    Chk ([int]$phoneticGuarded.After.Count -eq 1) ('C2 のふりがなが書込後も1件のまま残る: phonetics=' + [int]$phoneticGuarded.After.Count)
    Chk ([string]$phoneticGuarded.After.Text -eq $yomi) ('その読みも変わらない: ' + [string]$phoneticGuarded.After.Text)
    Chk ([string]$phoneticGuarded.After.Value -eq $tokyo) '訳していない C2 の本文も変わらない'

    # --- 速さ: 平文だけのブックは value2 の経路を使う ---------------------
    # **証明できる形が狭すぎると、普通のブックでも箱が死ぬ。** 時計は機械の負荷で
    # 揺れるので表明にしない。代わりに経路の名札を見る。
    Write-Host '平文だけのブックは、これまでどおり value2 の一括経路を使う' -ForegroundColor Cyan
    $plainLivePath = Join-Path $workDir 'live-plain.xlsx'
    $xlPlain = New-Object -ComObject Excel.Application
    $xlPlain.Visible = $false; $xlPlain.DisplayAlerts = $false
    try {
        $wbPlain = $xlPlain.Workbooks.Add()
        $wsPlain = $wbPlain.Worksheets.Item(1); $wsPlain.Name = 'S1'
        # 300行×3列＝900セル。部分書式もふりがなも無い、Excel が普通に作るブック。
        $plainValues = [System.Array]::CreateInstance([object], 300, 3)
        for ($r = 1; $r -le 300; $r++) {
            $plainValues.SetValue(('Row ' + $r), $r - 1, 0)
            $plainValues.SetValue(($tokyo + [string]$r), $r - 1, 1)
            $plainValues.SetValue([double]($r * 1.5), $r - 1, 2)
        }
        $wsPlain.Range('A1:C300').Value2 = $plainValues
        $wbPlain.SaveAs($plainLivePath, 51)
        $wbPlain.Close($false)
    } finally {
        try { $xlPlain.Quit() } catch {}
        Release-YakuComObject $xlPlain
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    $plainLiveSheets = @(Get-YakuXlsxNonPlainCells -Path $plainLivePath)
    Chk ($plainLiveSheets.Count -eq 0) ('Excel が普通に作った900セルのブックから、証明できないセルは1件も出ない: シート ' + $plainLiveSheets.Count + '枚')

    function Invoke-YakuPlainSpeedProbe {
        param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][object[]]$NonPlainCells)
        $xl = New-Object -ComObject Excel.Application
        $xl.Visible = $false; $xl.DisplayAlerts = $false
        $result = $null
        try {
            $wb = $xl.Workbooks.Open($Path)
            $ws = $wb.Worksheets.Item('S1')
            $blocks = New-Object System.Collections.Generic.List[object]
            $byBlock = @{}
            for ($r = 1; $r -le 300; $r++) {
                $id = 'p' + [string]$r
                $blocks.Add([pscustomobject]@{ Id=$id; Text='x'; Location='S1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=$r; Col=2; A1=''; Merged=$false } }) | Out-Null
                $byBlock[$id] = ('Translated ' + [string]$r)
            }
            # D1 も対象にして、箱を B..D へ広げる。こうしないと C 列（数値）が
            # 箱の中に入らず、「証明できないセルを1つ入れる」対の表明が作れない。
            $blocks.Add([pscustomobject]@{ Id='pd1'; Text='x'; Location='S1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=1; Col=4; A1=''; Merged=$false } }) | Out-Null
            $byBlock['pd1'] = 'Translated D1'
            $warnings = New-Object System.Collections.Generic.List[object]
            $metrics = @{}
            $written = Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks ([object[]]@($blocks.ToArray())) -TranslationByBlockId $byBlock -OutputFontName '' -Warnings $warnings -Metrics $metrics -NonPlainCells $NonPlainCells
            $result = [pscustomobject]@{
                Written = [int]$written
                BulkBox = [int]$metrics['bulk_box']
                Mode = [string]$metrics['bulk_mode']
                Skips = [int]$metrics['bulk_non_plain_skips']
                NonPlain = [int]$metrics['non_plain_cells']
            }
            $wb.Close($false)
        } finally {
            try { $xl.Quit() } catch {}
            Release-YakuComObject $xl
            try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
        }
        return $result
    }
    $plainWritePath = Join-Path $workDir 'live-plain-write.xlsx'
    Copy-Item -LiteralPath $plainLivePath -Destination $plainWritePath -Force
    $plainSpeed = Invoke-YakuPlainSpeedProbe -Path $plainWritePath -NonPlainCells @()
    Chk ([int]$plainSpeed.Written -eq 301) ('301セル全部に訳文が入る: ' + [string]$plainSpeed.Written)
    Chk ([int]$plainSpeed.NonPlain -eq 0) ('証明できないセルは0件のまま: ' + [string]$plainSpeed.NonPlain)
    Chk ([int]$plainSpeed.BulkBox -eq 1) ('平文だけのブックは一括の箱を使う: bulkBox=' + [string]$plainSpeed.BulkBox)
    Chk ([string]$plainSpeed.Mode -match '^value2') ('その経路が value2 の系統だと名札に残る: mode=' + [string]$plainSpeed.Mode)
    Chk ([int]$plainSpeed.Skips -eq 0) '証明できないセルを理由に箱を捨てていない'

    # 対の表明。**証明できないセルを1つ入れると fallback へ落ちる。**
    # 上の表明だけだと「いつも一括を使う」実装でも緑になる。
    $oneNonPlain = @(
        [ordered]@{ address='C150'; row=150; col=3; scope='cell'; runs=@(); dominant_signature=''; dominant_properties=$null; differing_properties=[string[]]@() }
    )
    $plainWritePath2 = Join-Path $workDir 'live-plain-write2.xlsx'
    Copy-Item -LiteralPath $plainLivePath -Destination $plainWritePath2 -Force
    $plainSpeed2 = Invoke-YakuPlainSpeedProbe -Path $plainWritePath2 -NonPlainCells $oneNonPlain
    Chk ([int]$plainSpeed2.BulkBox -eq 0 -and [int]$plainSpeed2.Skips -eq 1) ('証明できないセルを1つ入れると fallback になる: bulkBox=' + [string]$plainSpeed2.BulkBox + ' skips=' + [string]$plainSpeed2.Skips)
    Chk ([int]$plainSpeed2.Written -eq 301) ('落ちた先でも301セル全部に訳文が入る: ' + [string]$plainSpeed2.Written)
    Chk ([string]$inlineGuarded.C2Value -eq 'INLINEBOLDPART') '訳していない C2 の本文も変わらない'
}

}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) {
    Write-Host ('V91.61 rich text run regression failed. failures=' + $script:fail) -ForegroundColor Red
    exit 1
}
if (-not $script:excelMeasured) {
    Write-Host 'V91.61 rich text run: Excel の要る表明は未測定（exit 3）。それ以外は緑。' -ForegroundColor Yellow
    exit 3
}
Write-Host 'V91.61 rich text run regression passed.' -ForegroundColor Green
exit 0
