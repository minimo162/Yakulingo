<#
.SYNOPSIS
  「平文だと証明できたセルだけを一括の箱に入れる」判定の回帰テスト。Excel を使わない。

.DESCRIPTION
  訳文を書き戻すとき、速い一括代入（bounding box への Value2 代入）を使うと、
  **訳す対象ではないセルの部分書式が消える**。本文は1バイトも変わらないので、
  文字列を比べる検査では絶対に見つからない（被害D）。

  守りは `Get-YakuXlsxNonPlainCells`（src/SheetLayout.ps1）。**平文だと証明
  できたセルだけ**が箱に入る。証明できなかったものはここに載り、箱から外れる。

  **この試験は Excel を起動しない。** ZIP と XML だけを組んで検出器へ渡す。
  実機での被害Dの再現は `Test-YakuV9178RichTextRuns.ps1` が持っている。
  そちらは1件あたり数秒かかるので、**形の網羅はこちらで速く回す**
  （1件あたりミリ秒）。守りの穴はどれも XML の読み方の問題なので、
  Excel を通さなくても証明できる。

  題材はすべて「Excel は部分書式として描くのに、検出器が平文だと言った」形。
  2026-08-16 に敵対的検証で見つかった4件を含む。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9181PlainProof.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
. (Join-Path (Join-Path $root 'src') 'SheetLayout.ps1')

$script:fail = 0
function Chk {
    param([bool]$Ok, [string]$Message)
    if ($Ok) { Write-Host ('  ok   ' + $Message) -ForegroundColor DarkGray; return }
    Write-Host ('  FAIL ' + $Message) -ForegroundColor Red
    $script:fail++
}

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-plain-proof-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force

function New-YakuTestXlsx {
    <#
      指定した部品だけを持つ最小の xlsx を組む。Excel は使わない。
      $Parts は「パート名 → 中身」の順序付きハッシュ。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Parts
    )
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Parts.Keys) {
            $entry = $zip.CreateEntry([string]$name)
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Parts[$name])
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $Path
}

$XmlDecl = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'

function New-YakuTestParts {
    <#
      共有文字列表と1枚のシートを持つブックを組む。
      $SharedName で共有表のパート名を変えられる（別名の題材のため）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$SharedXml,
        [Parameter(Mandatory=$true)][string]$SheetXml,
        [string]$SharedName = 'xl/sharedStrings.xml'
    )
    $sharedTarget = $SharedName -replace '^xl/', ''
    $parts = [ordered]@{}
    $parts['[Content_Types].xml'] = $XmlDecl + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>' +
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
        '<Override PartName="/' + $SharedName + '" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>' +
        '</Types>'
    $parts['_rels/.rels'] = $XmlDecl + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'
    $parts['xl/workbook.xml'] = $XmlDecl + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
    $parts['xl/_rels/workbook.xml.rels'] = $XmlDecl + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="' + $sharedTarget + '"/>' +
        '</Relationships>'
    $parts['xl/worksheets/sheet1.xml'] = $SheetXml
    $parts[$SharedName] = $SharedXml
    return $parts
}

# 部分太字の <si>。Excel はこれを BOLD だけ太字にして描く。
$RichSi = '<si><r><rPr><b/><sz val="11"/><name val="Calibri"/></rPr><t>BOLD</t></r>' +
          '<r><rPr><sz val="11"/><name val="Calibri"/></rPr><t>plaintail</t></r></si>'
$PlainSi = { param([string]$Text) '<si><t>' + $Text + '</t></si>' }

function New-YakuTestSheet {
    <# 与えた共有文字列番号を A1/B1/C1 へ置く。 #>
    param([int[]]$Indexes)
    $cells = ''
    $cols = @('A', 'B', 'C', 'D', 'E')
    for ($i = 0; $i -lt $Indexes.Count; $i++) {
        $cells += '<c r="' + $cols[$i] + '1" t="s"><v>' + $Indexes[$i] + '</v></c>'
    }
    return $XmlDecl + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<sheetData><row r="1">' + $cells + '</row></sheetData></worksheet>'
}

function Get-YakuNonPlainAddresses {
    <# 検出器を呼び、シート1枚ぶんの住所（scope='sheet' なら (sheet)）を返す。 #>
    param([string]$Path)
    $sheets = @(Get-YakuXlsxNonPlainCells -Path $Path)
    if ($sheets.Count -eq 0) { return @() }
    return @(@($sheets[0].non_plain_cells) | ForEach-Object { [string]$_.address })
}

try {
    Write-Host '対照: 素直なブックでは、平文は箱に入り、rich は外れる' -ForegroundColor Cyan

    # A1=平文 / B1=部分太字 / C1=平文。Excel は B1 だけを部分太字で描く。
    $plainOnly = New-YakuTestParts -SharedXml ($XmlDecl + '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">' +
        (& $PlainSi 'HDR') + (& $PlainSi 'TGT') + (& $PlainSi 'MORE') + '</sst>') -SheetXml (New-YakuTestSheet -Indexes @(0, 1, 2))
    $addrs = Get-YakuNonPlainAddresses (New-YakuTestXlsx -Path (Join-Path $tmp 'plain.xlsx') -Parts $plainOnly)
    Chk ($addrs.Count -eq 0) ('平文だけのブックは1件も外れない（実際 ' + $addrs.Count + ' 件: ' + ($addrs -join ',') + '）')

    $withRich = New-YakuTestParts -SharedXml ($XmlDecl + '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">' +
        (& $PlainSi 'HDR') + $RichSi + (& $PlainSi 'TGT') + '</sst>') -SheetXml (New-YakuTestSheet -Indexes @(0, 1, 2))
    $addrs = Get-YakuNonPlainAddresses (New-YakuTestXlsx -Path (Join-Path $tmp 'rich.xlsx') -Parts $withRich)
    Chk (@($addrs | Where-Object { $_ -eq 'B1' }).Count -eq 1) ('部分太字のセル B1 が外れる（実際 ' + ($addrs -join ',') + '）')
    Chk (@($addrs | Where-Object { $_ -eq 'A1' -or $_ -eq 'C1' }).Count -eq 0) '同じシートの平文セルは箱に残る（守りすぎていない）'

    Write-Host '穴: <si> を content 以外の場所へ置いて、番号をずらす' -ForegroundColor Cyan

    # (1) コメントの中の <si>。Excel は読まないので、実番号が1つずれる。
    #     数だけの門は、両方の正規表現が等しく1つ数えるので釣り合って通る。
    $sstOpen = '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">'
    # **住所で照合する。件数では見つからない。** 番号がずれると、外れるのは
    # 「部分太字のセル」ではなく「その隣」になる。件数だけを見ると 1 件外れて
    # いるので緑になり、太字のセルは箱に入ったまま消える（2026-08-16 に
    # この試験自身がその形で書かれていて、穴を素通しした）。
    #
    # rich は表の中で何番目か、Excel が読む番号で数える。コメント・処理命令の
    # 中身は Excel にとって存在しないので、番号から外れる。
    $cases = @(
        @{ n='コメントの中の <si>'
           sst = ($sstOpen + '<!--' + (& $PlainSi 'DECOY') + '-->' + $RichSi + (& $PlainSi 'HDR') + (& $PlainSi 'TGT') + '</sst>')
           rich = 'A1' }   # 実番号 0=RICH 1=HDR 2=TGT
        @{ n='処理命令の中の <si>'
           sst = ($sstOpen + '<?yaku ' + (& $PlainSi 'DECOY') + ' ?>' + $RichSi + (& $PlainSi 'HDR') + (& $PlainSi 'TGT') + '</sst>')
           rich = 'A1' }
        @{ n='コメントが前・平文と釣合う'
           sst = ($sstOpen + '<!--' + (& $PlainSi 'D1') + '-->' + (& $PlainSi 'P0') + $RichSi + (& $PlainSi 'TGT') + '</sst>')
           rich = 'B1' }   # 実番号 0=P0 1=RICH 2=TGT
        @{ n='CDATA の中の <si>'
           sst = ($sstOpen + '<si><t><![CDATA[' + (& $PlainSi 'DECOY') + ']]></t></si>' + $RichSi + (& $PlainSi 'TGT') + '</sst>')
           rich = 'B1' }   # 実番号 0=CDATAのsi 1=RICH 2=TGT
        @{ n='DOCTYPE 宣言つき'
           sst = ('<?xml version="1.0"?><!DOCTYPE sst>' + $sstOpen.Substring($sstOpen.IndexOf('<sst')) + (& $PlainSi 'HDR') + $RichSi + (& $PlainSi 'TGT') + '</sst>')
           rich = 'B1' }
        # **知らない要素が <si> を包んでいる形。** 要素そのものは <si> でないので
        # 数は釣り合う。しかし Excel が番号を振るのは <sst> の直下の <si> だけで、
        # 包まれたものは数えない。つまりコメントと同じずれ方をする。
        @{ n='知らない要素が <si> を包む'
           sst = ($sstOpen + (& $PlainSi 'HDR') + '<ext>' + (& $PlainSi 'DECOY') + '</ext>' + $RichSi + (& $PlainSi 'TGT') + '</sst>')
           rich = 'B1' }   # 実番号 0=HDR 1=RICH 2=TGT
        # 包んでいない知らない要素は、番号をずらさない（守りすぎの確認は下の対照で見る）。
        @{ n='知らない要素が隙間にある'
           sst = ($sstOpen + (& $PlainSi 'HDR') + '<ext/>' + $RichSi + (& $PlainSi 'TGT') + '</sst>')
           rich = 'B1' }   # 実番号 0=HDR 1=RICH 2=TGT
    )
    $caseIndex = 0
    foreach ($case in $cases) {
        $caseIndex++
        $parts = New-YakuTestParts -SharedXml $case.sst -SheetXml (New-YakuTestSheet -Indexes @(0, 1, 2))
        $addrs = Get-YakuNonPlainAddresses (New-YakuTestXlsx -Path (Join-Path $tmp ('hole' + $caseIndex + '.xlsx')) -Parts $parts)
        $shown = if ($addrs.Count) { ($addrs -join ',') } else { '0件＝素通し' }
        # 守りすぎ（シート丸ごと、全セル）は安全側なので通す。
        # 通してはいけないのは「部分太字のセルが箱に残る」ことだけ。
        $covered = (@($addrs | Where-Object { $_ -eq [string]$case.rich -or $_ -eq '(sheet)' }).Count -ge 1)
        Chk $covered ($case.n + ' … 部分太字の ' + $case.rich + ' が箱から外れる（外れたのは ' + $shown + '）')
    }

    Write-Host '穴: 共有文字列表が別の名前にある' -ForegroundColor Cyan
    # Excel は xl/_rels/workbook.xml.rels の関係を辿って読む。パートの名前は
    # sharedStrings.xml でなくてよい。決め打ちで探すと、表そのものが見えない。
    $altParts = New-YakuTestParts -SharedName 'xl/strtable.xml' -SheetXml (New-YakuTestSheet -Indexes @(0, 1, 2)) `
        -SharedXml ($sstOpen + (& $PlainSi 'HDR') + $RichSi + (& $PlainSi 'TGT') + '</sst>')
    $altPath = New-YakuTestXlsx -Path (Join-Path $tmp 'altpart.xlsx') -Parts $altParts
    Chk (-not (@($altParts.Keys) -contains 'xl/sharedStrings.xml')) '題材に xl/sharedStrings.xml は存在しない（決め打ちが当たらない形）'
    $addrs = Get-YakuNonPlainAddresses $altPath
    $shown = if ($addrs.Count) { ($addrs -join ',') } else { '0件＝シートごと素通し' }
    Chk (@($addrs | Where-Object { $_ -eq 'B1' -or $_ -eq '(sheet)' }).Count -ge 1) ('別名の共有表でも、部分太字の B1 が箱から外れる（外れたのは ' + $shown + '）')

    Write-Host '穴: 関係は「ここにある」と言うのに、共有表が読めない' -ForegroundColor Cyan
    # 空を返すと「表が無い＝共有の rich text は存在しえない＝全部平文」の枝へ
    # 落ちる。表が読めないことと、表が無いことは違う。読めないほうは、
    # そこに部分書式があったかどうかを**言えない**のだから、証明できない側へ倒す。
    $brokenCases = @(
        @{ n='関係の指す先が入っていない'
           mutate = { param($p) $q = [ordered]@{}; foreach ($k in $p.Keys) { if ($k -ne 'xl/sharedStrings.xml') { $q[$k] = $p[$k] } }; return $q } }
        @{ n='workbook の関係そのものが壊れている'
           mutate = { param($p) $q = [ordered]@{}; foreach ($k in $p.Keys) { $q[$k] = $p[$k] }; $q['xl/_rels/workbook.xml.rels'] = '<Relationships><broken'; return $q } }
    )
    $brokenIndex = 0
    foreach ($broken in $brokenCases) {
        $brokenIndex++
        # 中身は「平文3つ」。表が読めていれば0件になる題材である。
        # つまり**外れるのは表が読めないことだけが理由**だと言える。
        $base = New-YakuTestParts -SheetXml (New-YakuTestSheet -Indexes @(0, 1, 2)) `
            -SharedXml ($sstOpen + (& $PlainSi 'HDR') + (& $PlainSi 'TGT') + (& $PlainSi 'MORE') + '</sst>')
        $addrs = Get-YakuNonPlainAddresses (New-YakuTestXlsx -Path (Join-Path $tmp ('broken' + $brokenIndex + '.xlsx')) -Parts (& $broken.mutate $base))
        $shown = if ($addrs.Count) { ($addrs -join ',') } else { '0件＝素通し' }
        Chk ($addrs.Count -ge 3) ($broken.n + ' … 共有文字列のセルは箱から外れる（外れたのは ' + $shown + '）')
    }

    Write-Host '対照: 守りが効きすぎて、普通のブックまで遅くなっていないか' -ForegroundColor Cyan
    # 平文だけのブックは、上の1件目で0件を確かめてある。ここでは
    # 「表が無いブック」も箱を使えることを見る（共有の rich は存在しえない）。
    $noSst = [ordered]@{}
    foreach ($k in $plainOnly.Keys) { if ($k -ne 'xl/sharedStrings.xml') { $noSst[$k] = $plainOnly[$k] } }
    $noSst['xl/worksheets/sheet1.xml'] = $XmlDecl + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>2</v></c></row></sheetData></worksheet>'
    $addrs = Get-YakuNonPlainAddresses (New-YakuTestXlsx -Path (Join-Path $tmp 'nosst.xlsx') -Parts $noSst)
    Chk ($addrs.Count -eq 0) ('共有表を持たない数値だけのブックは1件も外れない（実際 ' + $addrs.Count + ' 件）')
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'V9181 plain proof: PASS' -ForegroundColor Green; exit 0 }
Write-Host ('V9181 plain proof: FAIL (' + $script:fail + ')') -ForegroundColor Red
exit 1
