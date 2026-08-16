<#
.SYNOPSIS
  V91.61: セル内部分書式（run）が、書き戻しで巻き添えにならないことを確かめる。

.DESCRIPTION
  2026-08-16 に Excel COM で実測した被害は2つある。どちらも文字は1文字も
  変わらないので、**本文を比べる検査では永久に見つからない**。

    A（滲み出し） 1〜4文字目だけ太字のセルへ Value2 で書くと、1文字目の書式が
                  新しい文字列全体へ広がり、29文字すべてが太字になった。
    D（巻き添え） 翻訳対象ではない隣のセルが一括の箱に入っていると、元の値を
                  そのまま書き戻すだけで run が消えた。

  ここで見るのは3つ。
    1. 検出器が run セルを**比べて**選ぶこと（数えると偽陽性になる）
    2. run セルを含む箱が一括経路へ入らないこと（D）
    3. 書いた後にセル全体が支配的な書式へ揃うこと（A）

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

function Get-YakuRunCellByAddress {
    param([AllowNull()][object[]]$RunCells,[Parameter(Mandatory=$true)][string]$Address)
    foreach ($cell in @($RunCells)) {
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

function Invoke-YakuRunBoxProbe {
    # 箱 B8:D8 へ一括で書く。C8 は**翻訳対象ではない**のに箱の中にいる。
    param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][object[]]$RunCells)
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
        $written = Invoke-YakuExcelBulkBoundingBoxWrite -Worksheet $ws -Items $items -OutputFontName '' -Warnings $warnings -SheetName 'S1' -RunCells $RunCells
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
        [AllowNull()][object[]]$RunCells,
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
        $levelled = Set-YakuExcelRunCellDominantFormat -Worksheet $ws -RunCells $RunCells -TargetKeys $TargetKeys -OutputFontName '' -SheetName 'S1'
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
    '</sheetData></worksheet>'
New-YakuRunFixtureXlsx -Path $fixturePath -Parts @{
    'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="明細" sheetId="1" r:id="rId7"/></sheets></workbook>'
    'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/run-source.xml"/></Relationships>'
    'xl/styles.xml' = $stylesXml
    'xl/sharedStrings.xml' = $sharedXml
    'xl/worksheets/run-source.xml' = $sheetXml
}

$sheets = @(Get-YakuXlsxRunCells -Path $fixturePath)
Chk ($sheets.Count -eq 1) ('run を持つシートが1枚返る: ' + $sheets.Count)
$runCells = @()
if ($sheets.Count -eq 1) {
    Chk ([string]$sheets[0].name -eq '明細') 'relationship で解決したシート名を持つ'
    $runCells = @($sheets[0].run_cells)
}
$addresses = @($runCells | ForEach-Object { [string]$_.address })

# 所属で見る。件数だけを見ると、B2 が C2 の代わりに入っても気づけない。
Chk ($addresses -contains 'C8') '太字の run を持つセルを拾う'
Chk ($addresses -contains 'C23') '下線の run を持つセルを拾う'
Chk (-not ($addresses -contains 'C7')) 'rPr がセル自身の字体を言い直しているだけの run は拾わない（罠3）'
Chk (-not ($addresses -contains 'B23')) '自己終端の空セルが、次のセルの中身を名乗らない（罠1）'
Chk ($addresses.Count -eq 5) ('拾うのは5件だけ（C8 / C23 / C31 / C40 / C50）: ' + ($addresses -join ','))

# 同じ共有文字列でも、参照するセルの字体が違えば答えが変わる。
# 「run を数える」実装はここで必ず外す（C30 も C31 も run は2つある）。
Chk (-not ($addresses -contains 'C30')) '太字のセルの中で <b/> を言い直す run は、混在ではない'
Chk ($addresses -contains 'C31') '同じ共有文字列でも、普通のセルから参照すれば混在になる'

# Excel が実際に書く形。セルの字体が太字で、あとの run が
# 「太字を含まない rPr」で打ち消している。rPr を差分として扱うと拾えない。
$c50 = Get-YakuRunCellByAddress -RunCells $runCells -Address 'C50'
Chk ($null -ne $c50) 'セルの字体が太字で、rPr が太字を書かずに打ち消す形を拾う'
Chk ($null -ne $c50 -and (@($c50.differing_properties) -join ',') -eq 'b') 'その食い違いも太字だと分かる'
Chk ($null -ne $c50 -and -not $c50.dominant_properties.ContainsKey('b')) '支配的な書式は打ち消した側（11文字 対 4文字）'

$c8 = Get-YakuRunCellByAddress -RunCells $runCells -Address 'C8'
Chk ($null -ne $c8 -and [int]$c8.row -eq 8 -and [int]$c8.col -eq 3) 'C8 を行8・列3として返す'
Chk ($null -ne $c8 -and @($c8.runs).Count -eq 3) 'run を3つとも返す'
# 符号化が壊れていれば、ここで文字数が変わる（BOM 無しで書くと日本語が化ける）。
Chk ($null -ne $c8 -and @($c8.runs)[0].length -eq 6 -and @($c8.runs)[1].length -eq 3 -and @($c8.runs)[2].length -eq 6) 'run の文字数が 6 / 3 / 6 で返る'
Chk ($null -ne $c8 -and (@($c8.differing_properties) -join ',') -eq 'b') '食い違っている項目は太字だけだと分かる'
# 支配的な書式＝文字数の合計がいちばん多いほう（太字ではない側が 12 文字）。
Chk ($null -ne $c8 -and -not $c8.dominant_properties.ContainsKey('b')) '支配的な書式は「太字ではない」ほう（12文字 対 3文字）'

$c23 = Get-YakuRunCellByAddress -RunCells $runCells -Address 'C23'
Chk ($null -ne $c23 -and (@($c23.differing_properties) -join ',') -eq 'u') 'C23 で食い違っているのは下線だけ'

# 読めないものを渡しても、書き戻しは続く（体裁は足しであって前提ではない）。
$brokenPath = Join-Path $workDir 'broken.xlsx'
Set-Content -LiteralPath $brokenPath -Value 'this is not a zip' -Encoding ASCII
Chk (@(Get-YakuXlsxRunCells -Path $brokenPath).Count -eq 0) '壊れたファイルは空で返る（例外を投げない）'
Chk (@(Get-YakuXlsxRunCells -Path (Join-Path $workDir 'nope.xlsx')).Count -eq 0) '無いファイルは空で返る'

# ===========================================================================
# 2. 巻き添え（D）の判断。Excel は要らない
# ===========================================================================
Write-Host '対象ではない run セルを挟む箱を、一括経路へ入れない' -ForegroundColor Cyan

# B8 と D8 だけが翻訳対象。C8 は対象ではないのに、箱 B8:D8 の中にいる。
$straddlingItems = @(
    [pscustomobject]@{ Row=8; Col=2; Translation='Heading'; Block=$null },
    [pscustomobject]@{ Row=8; Col=4; Translation='FX'; Block=$null }
)
$straddlingBounds = New-YakuExcelCellItemsBounds -Items $straddlingItems
$hit = Get-YakuExcelRunCellInBounds -RunCells $runCells -Bounds $straddlingBounds
Chk ($null -ne $hit -and [string]$hit.address -eq 'C8') '対象を1つも含まなくても、箱の中にいる run セルを見つける'

# 対の表明。**箱に run セルが入っていなければ素通しする。**
# これが無いと「無条件に止める」実装でも通ってしまう。
$clearItems = @(
    [pscustomobject]@{ Row=8; Col=6; Translation='x'; Block=$null },
    [pscustomobject]@{ Row=8; Col=7; Translation='y'; Block=$null }
)
$clearBounds = New-YakuExcelCellItemsBounds -Items $clearItems
Chk ($null -eq (Get-YakuExcelRunCellInBounds -RunCells $runCells -Bounds $clearBounds)) 'run セルを含まない箱は止めない（一括を殺さない）'
Chk ($null -eq (Get-YakuExcelRunCellInBounds -RunCells @() -Bounds $straddlingBounds)) 'run セルが1つも無いブックでは止めない'

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
$c40 = Get-YakuRunCellByAddress -RunCells $runCells -Address 'C40'
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

    $liveSheets = @(Get-YakuXlsxRunCells -Path $livePath)
    $liveRunCells = @()
    foreach ($sheet in $liveSheets) {
        if ([string]$sheet.name -eq 'S1') { $liveRunCells = @($sheet.run_cells) }
    }
    Chk ($liveRunCells.Count -eq 1) ('Excel が書き出したブックからも run セルは1件だけ: ' + $liveRunCells.Count)
    Chk ((@($liveRunCells | ForEach-Object { [string]$_.address })) -contains 'C8') '拾うのは C8（全体が太字の B8 は拾わない）'

    # 原本を Excel で開いたまま書き出す場面は珍しくない。ZipFile::OpenRead は
    # そこで落ちるが Copy-Item は通るので、**守りだけが黙って外れる**。
    # 2026-08-16 に利用者のテストファイルで実測した。
    $holder = New-Object -ComObject Excel.Application
    $holder.Visible = $false; $holder.DisplayAlerts = $false
    $heldCount = -1
    try {
        $heldWorkbook = $holder.Workbooks.Open($livePath)
        $heldCount = 0
        foreach ($sheet in @(Get-YakuXlsxRunCells -Path $livePath)) {
            if ([string]$sheet.name -eq 'S1') { $heldCount = @($sheet.run_cells).Count }
        }
        $heldWorkbook.Close($false)
    } finally {
        try { $holder.Quit() } catch {}
        Release-YakuComObject $holder
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    Chk ($heldCount -eq 1) ('原本を Excel で開いたままでも run セルを読める: ' + $heldCount)

    # --- D: 対象ではない C8 を挟む箱 -------------------------------------
    $damagedPath = Join-Path $workDir 'live-damaged.xlsx'
    $guardedPath = Join-Path $workDir 'live-guarded.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $damagedPath -Force
    Copy-Item -LiteralPath $livePath -Destination $guardedPath -Force

    $damaged = Invoke-YakuRunBoxProbe -Path $damagedPath -RunCells @()
    $guarded = Invoke-YakuRunBoxProbe -Path $guardedPath -RunCells $liveRunCells

    Chk ([string]$damaged.Before -eq 'BBBB...........') ('元は1〜4文字目だけ太字: ' + [string]$damaged.Before)
    # 対の表明。守りを外せば**実際に壊れる**。壊れないなら、この門は何も見ていない。
    Chk ([bool]$damaged.Used) '守りを外すと、run セルを挟む箱でも一括で書く'
    Chk (([string]$damaged.After) -ne ([string]$damaged.Before)) ('守りを外すと、対象ではない C8 の部分太字が壊れる: ' + [string]$damaged.After)
    Chk (-not [bool]$guarded.Used) 'run セルを挟む箱は一括経路へ入らない'
    Chk (([string]$guarded.After) -eq ([string]$guarded.Before)) ('巻き添えにならない: ' + [string]$guarded.After)

    # --- A: 滲み出しと、揃え直し ----------------------------------------
    # 箱を外した先の経路（矩形）でも滲み出すことを、まず測る。ここが滲まないなら
    # あとの「直った」は箱を外した効果でしかなく、揃え直しは何もしていない。
    $levelPath = Join-Path $workDir 'live-level.xlsx'
    $untouchedPath = Join-Path $workDir 'live-untouched.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $levelPath -Force
    Copy-Item -LiteralPath $livePath -Destination $untouchedPath -Force
    $levelProbe = Invoke-YakuRunLevelProbe -Path $levelPath -RunCells $liveRunCells -TargetKeys @{ '8,2'=$true; '8,3'=$true; '8,4'=$true }
    Chk ([string]$levelProbe.AfterWrite -eq 'bold') ('矩形の2次元配列代入でも、1文字目の太字が全体へ滲み出す: ' + [string]$levelProbe.AfterWrite)
    Chk ([string]$levelProbe.AfterLevel -eq 'plain') ('揃え直しで、支配的な書式（太字ではない）へ戻る: ' + [string]$levelProbe.AfterLevel)
    Chk ([int]$levelProbe.Levelled -eq 1) '揃え直したセルは1つ'

    # 訳文を書いていない run セルには触らない。
    $untouchedProbe = Invoke-YakuRunLevelProbe -Path $untouchedPath -RunCells $liveRunCells -TargetKeys @{ '99,99'=$true }
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
