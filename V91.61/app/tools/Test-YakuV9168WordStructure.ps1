<#
.SYNOPSIS
  Word の見出しの段と、表の中の位置を読めていることを確かめる。

.DESCRIPTION
  体裁で見るとき、Word は「見出しの深さ」と「表の格子」が分からないと、
  ただの段落の列にしかならない。2026-08-13 まで、見出しかどうかは
  Location（'見出し N'）でしか分からず、段（Heading1 か Heading2 か）は
  読んだ直後に捨てていた。表は '表内 N' という通し番号だけで、行と列が無かった。

  Location は画面の「場所」列と保存済みの作業が見ているので触っていない。
  位置は Meta へ足しただけである。ここではその Meta を見る。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuWord {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

. (Join-Path $root 'src\WordAdapter.ps1')

$w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
function New-YakuTestParagraph {
    param([string]$Text,[string]$Style)
    $pPr = if ($Style) { '<w:pPr><w:pStyle w:val="' + $Style + '"/></w:pPr>' } else { '' }
    return '<w:p>' + $pPr + '<w:r><w:t>' + $Text + '</w:t></w:r></w:p>'
}
function New-YakuTestCell {
    param([string]$Text,[int]$Span = 1)
    $pr = if ($Span -gt 1) { '<w:tcPr><w:gridSpan w:val="' + $Span + '"/></w:tcPr>' } else { '' }
    return '<w:tc>' + $pr + (New-YakuTestParagraph -Text $Text) + '</w:tc>'
}

# 見出し2段 + 本文、そのあとに表2つ。2つ目の表は横結合を含む。
$body = (New-YakuTestParagraph -Text '第1章' -Style 'Heading1') +
        (New-YakuTestParagraph -Text '1.1 節' -Style 'Heading2') +
        (New-YakuTestParagraph -Text 'ふつうの本文') +
        (New-YakuTestParagraph -Text '見出し 3 の書き方' -Style '見出し 3') +
        '<w:tbl><w:tr>' + (New-YakuTestCell -Text '表1r0c0') + (New-YakuTestCell -Text '表1r0c1') + '</w:tr>' +
        '<w:tr>' + (New-YakuTestCell -Text '表1r1c0') + (New-YakuTestCell -Text '表1r1c1') + '</w:tr></w:tbl>' +
        '<w:tbl><w:tr>' + (New-YakuTestCell -Text '表2見出し' -Span 2) + (New-YakuTestCell -Text '表2r0c2') + '</w:tr>' +
        '<w:tr>' + (New-YakuTestCell -Text '表2r1c0') + (New-YakuTestCell -Text '表2r1c1') + (New-YakuTestCell -Text '表2r1c2') + '</w:tr></w:tbl>'
$documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document ' + $w + '><w:body>' + $body + '</w:body></w:document>'

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-word-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDir -Force
$docxPath = Join-Path $workDir 'fixture.docx'
try {
    $stream = New-Object System.IO.FileStream($docxPath, 'Create')
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, 'Create')
        try {
            $entry = $zip.CreateEntry('word/document.xml')
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.Write($documentXml) } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }

    Write-Host 'Word headings carry their level and table cells carry their position' -ForegroundColor Cyan

    $blocks = @((Get-YakuWordDocumentInventory -Path $docxPath).Blocks)
    # 本文4段落 + 表1（2行×2列=4）+ 表2（1行目2つ・2行目3つ=5）で 13。
    Check-YakuWord ($blocks.Count -eq 13) '段落と表のセルを全部読む'

    # 見出しの段。Heading1/2 と、日本語の「見出し 3」の両方から取れる。
    $h1 = $blocks | Where-Object { $_.Text -eq '第1章' } | Select-Object -First 1
    $h2 = $blocks | Where-Object { $_.Text -eq '1.1 節' } | Select-Object -First 1
    $h3 = $blocks | Where-Object { $_.Text -eq '見出し 3 の書き方' } | Select-Object -First 1
    $plain = $blocks | Where-Object { $_.Text -eq 'ふつうの本文' } | Select-Object -First 1
    Check-YakuWord ($null -ne $h1 -and [int]$h1.Meta.HeadingLevel -eq 1) 'Heading1 は1段目'
    Check-YakuWord ($null -ne $h2 -and [int]$h2.Meta.HeadingLevel -eq 2) 'Heading2 は2段目'
    Check-YakuWord ($null -ne $h3 -and [int]$h3.Meta.HeadingLevel -eq 3) '日本語の「見出し 3」も段を取る'
    Check-YakuWord ($null -ne $plain -and [int]$plain.Meta.HeadingLevel -eq 0) '本文は見出しではない'

    # Location は変えていない（保存済みの作業と画面の「場所」列が見ている）。
    Check-YakuWord ($null -ne $h1 -and [string]$h1.Location -like '見出し *') 'Location の書き方は今までどおり'
    Check-YakuWord ($null -ne $plain -and [string]$plain.Location -like '本文 *') '本文の Location も今までどおり'

    # 表の位置。表ごとに 0 から数え直す。
    $cells = @($blocks | Where-Object { $_.Meta.Kind -eq 'word_table' })
    Check-YakuWord ($cells.Count -eq 9) '表のセルを9つとも読む'
    $t0 = @($cells | Where-Object { $_.Meta.TableIndex -eq 0 })
    $t1 = @($cells | Where-Object { $_.Meta.TableIndex -eq 1 })
    Check-YakuWord ($t0.Count -eq 4 -and $t1.Count -eq 5) '表2つに分かれる'

    $c11 = $t0 | Where-Object { $_.Text -eq '表1r1c1' } | Select-Object -First 1
    Check-YakuWord ($null -ne $c11 -and [int]$c11.Meta.RowIndex -eq 1 -and [int]$c11.Meta.ColumnIndex -eq 1) '行と列を取る'

    # 横結合。結合したセルの幅と、そのあとの列番号がずれないこと。
    $merged = $t1 | Where-Object { $_.Text -eq '表2見出し' } | Select-Object -First 1
    $after = $t1 | Where-Object { $_.Text -eq '表2r0c2' } | Select-Object -First 1
    Check-YakuWord ($null -ne $merged -and [int]$merged.Meta.ColumnSpan -eq 2) '横に結合したセルの幅を取る'
    Check-YakuWord ($null -ne $merged -and [int]$merged.Meta.ColumnIndex -eq 0) '結合したセルは0列目から始まる'
    Check-YakuWord ($null -ne $after -and [int]$after.Meta.ColumnIndex -eq 2) '結合のぶんだけ次のセルの列番号がずれる'

    # 表でない段落に、表の位置が紛れ込まない。
    Check-YakuWord ($null -ne $plain -and [int]$plain.Meta.TableIndex -eq -1) '本文には表の位置が付かない'
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) { Write-Host ('Word structure tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Word structure tests passed.' -ForegroundColor Green
