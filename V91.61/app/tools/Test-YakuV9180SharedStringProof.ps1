<#
.SYNOPSIS
  V91.61: 共有文字列を「平文だと**証明できた**」と言い切るための門。
  数えることを証明に使っていた4つの穴を、実機の被害Dで押さえる。

.DESCRIPTION
  被害D（巻き添え）は、翻訳対象ではない隣のセルが一括の箱に入っていると、
  元の値をそのまま書き戻すだけでセル内の部分書式が消える、というものである。
  **本文は1バイトも変わらない**ので、文字を比べる検査では永久に見つからない。

  守りは「平文だと証明できたセルだけを箱に入れる」という反転で入っている。
  その証明が、次の4つで破れていた（すべて実測。本番の最外入口
  `Write-YakuExcelTranslations` を通し、Excel COM で1文字ずつ測った）。

    穴1 `<sst>` の直後に **XMLコメント**で `<si>` を1つ書くと、`<si>` の開始タグを
        数える物差しと、平文の形を切り出す物差しが**等しく1つ数える**ので釣り合いが
        保たれ、番号が丸ごと1つずれる。Excel はコメントを読まないので、
        `t="s"` の `<v>0</v>` が別の（平文の）flags を引き当てて「証明できた」になる
    穴2 同じことが**処理命令**（`<?yaku ... ?>`）でも起きる
    穴3 コメントの decoy が平文で、ずれた先が平文の `<si>` になる並び。
        穴1と向きが違うだけで、原因は同じ「数で対応づけている」ことである
    穴4 共有文字列表が `xl/sharedStrings.xml` **ではない名前**に置かれ、
        `xl/_rels/workbook.xml.rels` の関係と `[Content_Types].xml` の宣言で
        指されているブック。読み取りがパスを決め打ちしていたので sheets=0 entries=0 に
        なり、**シートごと一括の箱を素通し**した

  塞ぎ方は3つ（2026-08-16 に実装した形。**落とすのではなく諦める**）。
    - コメント・処理命令・CDATA・DOCTYPE があれば、**その表は証明しない**。
      落として数え直す道は採らなかった。落とし方そのものを間違える余地
      （入れ子のコメント、`--` を含むコメント、CDATA の中の `]]>`）が残るためで、
      Excel が書く sharedStrings.xml にこれらは出てこない
    - `<si>` と `<si>` の**あいだが空白以外なら証明しない**。知らない要素が
      `<si>` を包んでいると（`<ext><si>…</si></ext>`）、要素そのものは `<si>` では
      ないので数は釣り合うのに、Excel は包まれたものを数えないため番号がずれる。
      **これは5つ目の穴で、上の4つを塞いだあとに見つかった**
      （速い試験 `Test-YakuV9181PlainProof.ps1` が持っている）
    - 共有表の場所は `xl/_rels/workbook.xml.rels` の関係から引く。既定名の
      決め打ちをやめた。**関係が「ここにある」と言うのに読めなければ、
      空ではなく「読めない」を返す**（空は「表が無い＝全部平文」へ落ちる）

  **守りを外した側（blind）を必ず並べる。** 外して壊れないなら、その題材は
  守りの枝に届いていない。ここでは原本の場所を存在しないパスにして、
  検出器へ何も渡らない状態を作る（穴4 の被害はまさにその状態そのものだった）。

  **Excel が要る表明と、要らない表明を分ける。** 検出器は ZIP だけで測れる。
  Excel が無ければ実機の表明は**未測定（exit 3）**にする。赤へ畳むと、
  道具の不在が対象の欠陥に化ける。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9180SharedStringProof.ps1
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

$mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$pkgNs = 'http://schemas.openxmlformats.org/package/2006/relationships'

function New-YakuProofZip {
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

function New-YakuSharedProofWorkbook {
    <#
      共有表の**場所**と**中身**を差し替えられるブックを作る。
      `[Content_Types].xml` と `_rels/.rels` まで書くので、Excel が実際に開ける。
      （`<fills>` `<borders>` `<cellStyleXfs>` を省くと ZIP としては読めるのに
      `Workbooks.Open` だけが落ちる。検出器の表明が緑のまま実機だけ死ぬので、
      はじめから完全な包みにする）
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$SheetBody,
        [AllowNull()][string]$SharedInner = $null,
        [string]$SharedPartName = 'xl/sharedStrings.xml',
        # 宣言だけして中身を入れない（読めない共有表）。
        [switch]$OmitSharedPart,
        # `<sst>` の前へ置く前書き（DOCTYPE などを差し込むために使う）。
        [string]$SharedProlog = '',
        [string]$SheetElement = $null
    )
    $ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $rns = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $pns = 'http://schemas.openxmlformats.org/package/2006/relationships'
    if ([string]::IsNullOrEmpty($SheetElement)) { $SheetElement = '<worksheet xmlns="' + $ns + '">' }
    $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="' + $ns + '"><fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>'
    $overrides = '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    $bookRels = '<Relationship Id="rId1" Type="' + $rns + '/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId9" Type="' + $rns + '/styles" Target="styles.xml"/>'
    $parts = @{
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="' + $pns + '"><Relationship Id="rIdBook" Type="' + $rns + '/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="' + $ns + '" xmlns:r="' + $rns + '"><sheets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></workbook>'
        'xl/styles.xml' = $styles
        'xl/worksheets/sheet1.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + $SheetElement + '<sheetData>' + $SheetBody + '</sheetData></worksheet>'
    }
    if ($null -ne $SharedInner) {
        # **場所は関係（rels）と `[Content_Types].xml` の両方で宣言する。**
        # Excel はこの2つを辿って読む。既定名かどうかは見ていない。
        $target = $SharedPartName
        if ($target.StartsWith('xl/')) { $target = $target.Substring(3) }
        $bookRels += '<Relationship Id="rId7" Type="' + $rns + '/sharedStrings" Target="' + $target + '"/>'
        $overrides += '<Override PartName="/' + $SharedPartName + '" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        if (-not $OmitSharedPart) {
            $parts[$SharedPartName] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + $SharedProlog + '<sst xmlns="' + $ns + '">' + $SharedInner + '</sst>'
        }
    }
    $parts['[Content_Types].xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>' + $overrides + '</Types>'
    $parts['xl/_rels/workbook.xml.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="' + $pns + '">' + $bookRels + '</Relationships>'
    New-YakuProofZip -Path $Path -Parts $parts
}

function Get-YakuProofSheetCells {
    param([Parameter(Mandatory=$true)][string]$Path)
    foreach ($sheet in @(Get-YakuXlsxNonPlainCells -Path $Path)) {
        if ([string]$sheet.name -eq 'S1') { return @($sheet.non_plain_cells) }
    }
    return @()
}

function Get-YakuProofAddresses {
    param([Parameter(Mandatory=$true)][string]$Path)
    return @(@(Get-YakuProofSheetCells -Path $Path) | ForEach-Object { [string]$_.address })
}

# --- 実機の測り方 ----------------------------------------------------------
# 1文字ずつ測る。セル単位の Font.Bold は run が混在していると DBNull を返すだけで、
# **どこが太字か**が消える。被害Dは「どこが」でしか見えない。
function Get-YakuProofPerCharBold {
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

function Get-YakuProofState {
    # 開いたときの Saved も返す。修復が入ったブックはここで False になるので、
    # 「題材が壊れていたから守りが働いた」を取り違えずに済む。
    param([Parameter(Mandatory=$true)][string]$Path)
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    $state = $null
    try {
        $wb = $xl.Workbooks.Open($Path, 0, $true)
        $ws = $wb.Worksheets.Item('S1')
        $state = [pscustomobject]@{
            Saved    = [bool]$wb.Saved
            C2Value  = [string]$ws.Cells.Item(2,3).Value2
            C2Bold   = [string](Get-YakuProofPerCharBold -Worksheet $ws -Row 2 -Col 3)
            B2Value  = [string]$ws.Cells.Item(2,2).Value2
            D2Value  = [string]$ws.Cells.Item(2,4).Value2
        }
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    return $state
}

function Invoke-YakuProofWriteback {
    <#
      **本番の最外入口を通す。** B2 と D2 だけが翻訳対象なので、箱は B2:D2 になり
      **対象ではない C2** が真ん中に挟まる。`SourcePath` に存在しないパスを渡すと
      検出器へ何も渡らない（守りを外した側＝blind）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [AllowNull()]$Settings
    )
    $blocks = @(
        [pscustomobject]@{ Id='b2'; Text='src-b2'; Location='S1, B2'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=2; Col=2; A1='B2'; Merged=$false } },
        [pscustomobject]@{ Id='d2'; Text='src-d2'; Location='S1, D2'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=2; Col=4; A1='D2'; Merged=$false } }
    )
    $byBlock = @{ 'b2' = 'Head EN'; 'd2' = 'Tail EN' }
    $warnings = New-Object System.Collections.Generic.List[object]
    $null = Write-YakuExcelTranslations -OutputPath $OutputPath -Blocks $blocks -TranslationByBlockId $byBlock -Warnings $warnings -Settings $Settings -SourcePath $SourcePath
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-sst-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $workDir -Force
try {

# ===========================================================================
# 題材。4つとも「C2 だけが非対象の部分太字」で、見た目はまったく同じである。
# 違うのは共有表の**書き方**と**置き場所**だけ。
# ===========================================================================
$boldRpr = '<rPr><b/><sz val="11"/><color theme="1"/><rFont val="Calibri"/><family val="2"/></rPr>'
$richSi = '<si><r><t xml:space="preserve">PLAINPRT</t></r><r>' + $boldRpr + '<t xml:space="preserve">BOLDPART</t></r></si>'
$expectedBold = '........BBBBBBBB'
$expectedValue = 'PLAINPRTBOLDPART'

# B2 と D2 が対象、C2 は非対象。番号（`<v>`）だけが題材ごとに違う。
function New-YakuProofSheetBody {
    param([int]$B2,[int]$C2,[int]$D2)
    return '<row r="2"><c r="B2" s="0" t="s"><v>' + $B2 + '</v></c><c r="C2" s="0" t="s"><v>' + $C2 + '</v></c><c r="D2" s="0" t="s"><v>' + $D2 + '</v></c></row>'
}

$cases = New-Object System.Collections.Generic.List[object]
# 穴1: `<sst>` の直後の XMLコメントに `<si>` が1つ。Excel の番号では 0=太字入り。
$cases.Add([pscustomobject]@{
    Key = 'hole1-comment'
    Title = '穴1 コメントの中の <si> で番号が1つずれる'
    Shared = '<!--<si><t>DECOY</t></si>-->' + $richSi + '<si><t>HEAD</t></si><si><t>TAIL</t></si>'
    Sheet = (New-YakuProofSheetBody -B2 1 -C2 0 -D2 2)
    PartName = 'xl/sharedStrings.xml'
}) | Out-Null
# 穴2: 同じことを処理命令でやる。
$cases.Add([pscustomobject]@{
    Key = 'hole2-pi'
    Title = '穴2 処理命令の中の <si> で番号が1つずれる'
    Shared = '<?yaku <si><t>DECOY</t></si> ?>' + $richSi + '<si><t>HEAD</t></si><si><t>TAIL</t></si>'
    Sheet = (New-YakuProofSheetBody -B2 1 -C2 0 -D2 2)
    PartName = 'xl/sharedStrings.xml'
}) | Out-Null
# 穴3: decoy が先頭、ずれた先が平文。向きが違うだけで原因は同じ。
$cases.Add([pscustomobject]@{
    Key = 'hole3-shift'
    Title = '穴3 ずれた先が平文の <si> になる並び'
    Shared = '<!--<si><t>D1</t></si>--><si><t>P0</t></si>' + $richSi + '<si><t>TGT</t></si>'
    Sheet = (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2)
    PartName = 'xl/sharedStrings.xml'
}) | Out-Null
# 穴4: 共有表が別の名前。関係と `[Content_Types].xml` が指している。
$cases.Add([pscustomobject]@{
    Key = 'hole4-path'
    Title = '穴4 共有表が xl/strtable.xml にある'
    Shared = '<si><t>HEAD</t></si>' + $richSi + '<si><t>TAIL</t></si>'
    Sheet = (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2)
    PartName = 'xl/strtable.xml'
}) | Out-Null

foreach ($case in $cases.ToArray()) {
    $case | Add-Member -NotePropertyName SourcePath -NotePropertyValue (Join-Path $workDir ($case.Key + '-src.xlsx'))
    New-YakuSharedProofWorkbook -Path ([string]$case.SourcePath) -SheetBody ([string]$case.Sheet) -SharedInner ([string]$case.Shared) -SharedPartName ([string]$case.PartName)
}

# ===========================================================================
# 1. 検出器（Excel は要らない）
#    **住所で見る。件数で見ると、C2 の代わりに別のセルが入っても気づけない。**
# ===========================================================================
Write-Host '共有文字列の番号を、数ではなく位置で対応づける' -ForegroundColor Cyan
foreach ($case in $cases.ToArray()) {
    $addresses = @(Get-YakuProofAddresses -Path ([string]$case.SourcePath))
    Chk ($addresses -contains 'C2') ([string]$case.Title + ' … 部分太字の C2 を「平文だと証明できない」側に置く: [' + ($addresses -join ',') + ']')
}

# 対の表明。**狭すぎないこと。** 同じ道具立てで、番号がずれていない普通の並びなら
# 平文の共有文字列は1つも外れてはいけない。
$sanePath = Join-Path $workDir 'sane-src.xlsx'
New-YakuSharedProofWorkbook -Path $sanePath -SheetBody (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2) `
    -SharedInner ('<si><t>HEAD</t></si>' + $richSi + '<si><t>TAIL</t></si>')
$saneAddresses = @(Get-YakuProofAddresses -Path $sanePath)
Chk (($saneAddresses -join ',') -eq 'C2') ('普通の並びでは、外れるのは部分太字の C2 だけ: [' + ($saneAddresses -join ',') + ']')

# **落とすのではなく、諦める（2026-08-16 の判断）。** コメントで包まれた `<r>` は
# Excel からも見えないので、落として数え直せば平文と認められる。しかし
# **落とし方そのものを間違える余地が残る**（入れ子のコメント、`--` を含む
# コメント、CDATA の中の `]]>`）。Excel が書く sharedStrings.xml にコメントは
# 出てこないので、出てきたら遅くて安全な道へ落ちればよい。
# ここで固定するのは「巻き添えの被害が出ないこと」であって、速さではない。
$commentedRunPath = Join-Path $workDir 'commented-run.xlsx'
New-YakuSharedProofWorkbook -Path $commentedRunPath -SheetBody (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2) `
    -SharedInner ('<si><t>HEAD</t></si><si><t>PLAINONLY</t><!--<r>' + $boldRpr + '<t>BOLDPART</t></r>--></si><si><t>TAIL</t></si>')
$commentedRunAddresses = @(Get-YakuProofAddresses -Path $commentedRunPath)
Chk ($commentedRunAddresses.Count -ge 1) ('コメントがあれば、その表は証明しない（安全側へ倒す）: [' + ($commentedRunAddresses -join ',') + ']')

# ===========================================================================
# 1b. 共有表を特定できないときは、そのシートを丸ごと非平文にする
# ===========================================================================
Write-Host '共有表を特定できないときは、証明できない側へ倒す' -ForegroundColor Cyan

# 宣言はあるのに中身が無い。**素通しにしない。**
$missingPartPath = Join-Path $workDir 'missing-part.xlsx'
New-YakuSharedProofWorkbook -Path $missingPartPath -SheetBody (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2) `
    -SharedInner ('<si><t>HEAD</t></si>' + $richSi + '<si><t>TAIL</t></si>') -OmitSharedPart
$missingCells = @(Get-YakuProofSheetCells -Path $missingPartPath)
# 捨て方はシート単位でも1件ずつでもよい。**確かめるのは t="s" のセルが1つ残らず箱から外れること。**
Chk ($missingCells.Count -ge 1 -and (@($missingCells | Where-Object { [string]$_.scope -eq 'sheet' }).Count -ge 1 -or $missingCells.Count -ge 3)) ('宣言された共有表を読めなければ、t="s" のセルを箱から外す: ' + $missingCells.Count + '件 scope=' + [string](@($missingCells)[0].scope))

# 対の表明。**同じ「読めない共有表」でも、`t="s"` が1つも無いシートは巻き込まない。**
# これが無いと「読めなければ何でも捨てる」実装でも上の1件が緑になる。
$missingNumericPath = Join-Path $workDir 'missing-part-numeric.xlsx'
New-YakuSharedProofWorkbook -Path $missingNumericPath -SharedInner ('<si><t>HEAD</t></si>' + $richSi) -OmitSharedPart `
    -SheetBody '<row r="2"><c r="B2" s="0"><v>1</v></c><c r="C2" s="0"><v>2</v></c><c r="D2" s="0"><v>3</v></c></row>'
Chk (@(Get-YakuProofSheetCells -Path $missingNumericPath).Count -eq 0) '共有表を読めなくても、数値だけのシートは箱を使い続ける'

# DOCTYPE のような知らない宣言は、落とし方が分からない。証明できない側へ倒す。
$doctypePath = Join-Path $workDir 'doctype.xlsx'
New-YakuSharedProofWorkbook -Path $doctypePath -SheetBody (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2) `
    -SharedProlog '<!DOCTYPE sst>' -SharedInner ('<si><t>HEAD</t></si>' + $richSi + '<si><t>TAIL</t></si>')
$doctypeCells = @(Get-YakuProofSheetCells -Path $doctypePath)
Chk ($doctypeCells.Count -ge 3) ('知らない宣言（DOCTYPE）に当たったら、t="s" のセルを箱から外す: ' + $doctypeCells.Count + '件 scope=' + [string](@($doctypeCells)[0].scope))

# `<si>` の並びに知らない要素が挟まれば、番号は当てにならない。
$strayPath = Join-Path $workDir 'stray-element.xlsx'
New-YakuSharedProofWorkbook -Path $strayPath -SheetBody (New-YakuProofSheetBody -B2 0 -C2 1 -D2 2) `
    -SharedInner ('<si><t>HEAD</t></si><ext/>' + $richSi + '<si><t>TAIL</t></si>')
$strayCells = @(Get-YakuProofSheetCells -Path $strayPath)
# `<ext/>` は `<si>` を包んでいないので番号はずれない。外れるのは部分太字の C2 だけでよい。
# **包んでいる形**（`<ext><si>…</si></ext>`）は番号をずらす。そちらは
# Test-YakuV9181PlainProof.ps1 が持っている（Excel を使わないぶん速い）。
Chk ($strayCells.Count -ge 1 -and (@($strayCells | Where-Object { [string]$_.address -eq 'C2' -or [string]$_.scope -eq 'sheet' }).Count -ge 1)) ('`<si>` の隙間に知らない要素があっても、部分太字の C2 は箱から外れる: ' + $strayCells.Count + '件 scope=' + [string](@($strayCells)[0].scope))

# ===========================================================================
# 2. 実機（Excel が要る）。**本番の最外入口を通して被害Dを測る**
# ===========================================================================
if (-not (Test-YakuExcelAvailable)) {
    Write-Host 'Excel が無いため、実機の表明は未測定にする（赤へ畳まない）' -ForegroundColor Yellow
} else {
    $script:excelMeasured = $true
    $settings = Read-YakuSettings -Root $root
    Write-Host '本番の入口を通して、非対象セルの部分書式が残るかを1文字ずつ測る' -ForegroundColor Cyan

    foreach ($case in $cases.ToArray()) {
        Write-Host ('  --- ' + [string]$case.Title) -ForegroundColor DarkCyan
        $before = Get-YakuProofState -Path ([string]$case.SourcePath)
        Chk ([bool]$before.Saved) ([string]$case.Key + ' … Excel が修復せずに開く（Saved=True）: ' + [string]$before.Saved)
        Chk ([string]$before.C2Value -eq $expectedValue) ([string]$case.Key + ' … C2 の本文: ' + [string]$before.C2Value)
        Chk ([string]$before.C2Bold -eq $expectedBold) ([string]$case.Key + ' … 題材は Excel から見ても後半だけ太字: ' + [string]$before.C2Bold)

        $guardedPath = Join-Path $workDir ([string]$case.Key + '-guarded.xlsx')
        $blindPath = Join-Path $workDir ([string]$case.Key + '-blind.xlsx')
        Copy-Item -LiteralPath ([string]$case.SourcePath) -Destination $guardedPath -Force
        Copy-Item -LiteralPath ([string]$case.SourcePath) -Destination $blindPath -Force

        Invoke-YakuProofWriteback -OutputPath $guardedPath -SourcePath ([string]$case.SourcePath) -Settings $settings
        # 守りを外した側。原本を読めなければ検出器は何も返さない。
        Invoke-YakuProofWriteback -OutputPath $blindPath -SourcePath (Join-Path $workDir 'no-such-source.xlsx') -Settings $settings

        $guarded = Get-YakuProofState -Path $guardedPath
        $blind = Get-YakuProofState -Path $blindPath

        Chk ([string]$blind.C2Bold -ne $expectedBold) ([string]$case.Key + ' … 守りを外すと、非対象 C2 の部分太字が実際に壊れる: ' + [string]$blind.C2Bold)
        Chk ([string]$blind.C2Value -eq $expectedValue) ([string]$case.Key + ' … 壊れても本文は1バイトも変わらない: ' + [string]$blind.C2Value)
        Chk ([string]$guarded.C2Bold -eq $expectedBold) ([string]$case.Key + ' … 守りが働けば、1文字ずつが元のまま残る: ' + [string]$guarded.C2Bold)
        Chk ([string]$guarded.C2Value -eq $expectedValue) ([string]$case.Key + ' … 訳していない C2 の本文も変わらない: ' + [string]$guarded.C2Value)
        Chk ([string]$guarded.B2Value -eq 'Head EN' -and [string]$guarded.D2Value -eq 'Tail EN') ([string]$case.Key + ' … 対象の B2 / D2 には訳文が入る: ' + [string]$guarded.B2Value + ' / ' + [string]$guarded.D2Value)
    }

    # =======================================================================
    # 3. 速さ。普通のブックで一括が使われ続けること
    #    **時計は機械の負荷で揺れる。経路の名札で守る。**
    # =======================================================================
    Write-Host '部分書式もふりがなも無い900セルのブックは、これまでどおり value2 の一括経路を使う' -ForegroundColor Cyan
    $plainPath = Join-Path $workDir 'plain-900.xlsx'
    $xlPlain = New-Object -ComObject Excel.Application
    $xlPlain.Visible = $false; $xlPlain.DisplayAlerts = $false
    try {
        $wbPlain = $xlPlain.Workbooks.Add()
        $wsPlain = $wbPlain.Worksheets.Item(1); $wsPlain.Name = 'S1'
        $plainValues = [System.Array]::CreateInstance([object], 300, 3)
        for ($r = 1; $r -le 300; $r++) {
            $plainValues.SetValue(('Row ' + $r), $r - 1, 0)
            $plainValues.SetValue(('Source ' + $r), $r - 1, 1)
            $plainValues.SetValue([double]($r * 1.5), $r - 1, 2)
        }
        # **`.Value2` へ2次元配列を直に代入しない。**
        # PS の COM アダプタは `Object[,]` のプロパティ PUT を通せないことがあり、
        # 「System.Object[,] を System.String へ変換できない」で落ちる。
        # これは既知で、本番は `Set-YakuExcelRangeArrayValue2` が直接代入を試して
        # InvalidCastException なら reflection の SetProperty へ落ちる形にしてある
        # （src/FileProcessors.ps1:1638 の註。V91.14 で入った）。
        # 試験だけ自前で書くと、本番が解いてある罠をもう一度踏む。
        $plainRange = $wsPlain.Range('A1:C300')
        Set-YakuExcelRangeArrayValue2 -Range $plainRange -Values2D $plainValues
        $wbPlain.SaveAs($plainPath, 51)
        $wbPlain.Close($false)
    } finally {
        try { $xlPlain.Quit() } catch {}
        Release-YakuComObject $xlPlain
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }

    $plainSweep = [System.Diagnostics.Stopwatch]::StartNew()
    $plainSheets = @(Get-YakuXlsxNonPlainCells -Path $plainPath)
    $plainSweep.Stop()
    Write-Host ('  走査 ' + [string]$plainSweep.ElapsedMilliseconds + 'ms（時計は表明にしない。補助情報）')
    Chk ($plainSheets.Count -eq 0) ('Excel が普通に作った900セルから、証明できないセルは1件も出ない: シート ' + $plainSheets.Count + '枚')

    function Invoke-YakuPlainBulkProbe {
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
            # D1 も対象にして箱を B..D へ広げる。こうしないと C 列（数値）が箱に
            # 入らず、「証明できないセルを1つ入れる」対の表明が作れない。
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
            }
            $wb.Close($false)
        } finally {
            try { $xl.Quit() } catch {}
            Release-YakuComObject $xl
            try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
        }
        return $result
    }

    # 検出器が実際に返したものを渡す（`@()` を直に渡すと、検出器が過剰に
    # 安全側へ倒れていても緑になってしまう）。
    $plainDetected = @()
    foreach ($sheet in $plainSheets) { if ([string]$sheet.name -eq 'S1') { $plainDetected = @($sheet.non_plain_cells) } }
    $plainWritePath = Join-Path $workDir 'plain-900-write.xlsx'
    Copy-Item -LiteralPath $plainPath -Destination $plainWritePath -Force
    $plainBulk = Invoke-YakuPlainBulkProbe -Path $plainWritePath -NonPlainCells $plainDetected
    Chk ([int]$plainBulk.Written -eq 301) ('301セル全部に訳文が入る: ' + [string]$plainBulk.Written)
    Chk ([int]$plainBulk.BulkBox -eq 1) ('一括の箱を使う: bulkBox=' + [string]$plainBulk.BulkBox)
    Chk ([string]$plainBulk.Mode -match '^value2') ('その経路が value2 の系統だと名札に残る: mode=' + [string]$plainBulk.Mode)
    Chk ([int]$plainBulk.Skips -eq 0) '証明できないセルを理由に箱を捨てていない'

    # 対の表明。**証明できないセルを1つ入れると fallback へ落ちる。**
    # 上だけだと「いつも一括を使う」実装でも緑になる。
    $oneNonPlain = @(
        [ordered]@{ address='C150'; row=150; col=3; scope='cell'; runs=@(); dominant_signature=''; dominant_properties=$null; differing_properties=[string[]]@() }
    )
    $plainWritePath2 = Join-Path $workDir 'plain-900-write2.xlsx'
    Copy-Item -LiteralPath $plainPath -Destination $plainWritePath2 -Force
    $plainBulk2 = Invoke-YakuPlainBulkProbe -Path $plainWritePath2 -NonPlainCells $oneNonPlain
    Chk ([int]$plainBulk2.BulkBox -eq 0 -and [int]$plainBulk2.Skips -eq 1) ('証明できないセルを1つ入れると fallback になる: bulkBox=' + [string]$plainBulk2.BulkBox + ' skips=' + [string]$plainBulk2.Skips)
    Chk ([int]$plainBulk2.Written -eq 301) ('落ちた先でも301セル全部に訳文が入る: ' + [string]$plainBulk2.Written)
}

}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) {
    Write-Host ('V91.61 shared string proof regression failed. failures=' + $script:fail) -ForegroundColor Red
    exit 1
}
if (-not $script:excelMeasured) {
    Write-Host 'V91.61 shared string proof: Excel の要る表明は未測定（exit 3）。それ以外は緑。' -ForegroundColor Yellow
    exit 3
}
Write-Host 'V91.61 shared string proof regression passed.' -ForegroundColor Green
exit 0
