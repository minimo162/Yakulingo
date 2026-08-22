function Open-YakuXlsxArchiveForRead {
    <#
      .SYNOPSIS
        xlsx を ZIP として開く。**利用者が Excel で開いたままのファイルでも読む。**

      .DESCRIPTION
        `[IO.Compression.ZipFile]::OpenRead` は FileShare.Read で開くので、
        Excel が同じファイルを掴んでいると IOException で落ちる。
        実測（2026-08-16、利用者のテストファイルを Excel で開いた状態）:
        `OpenRead` は「別のプロセスが使用中」で失敗し、`Copy-Item` は成功した。
        つまり書き出しそのものは通るのに、体裁の読み取りだけが黙って落ちる。
        読むだけなので、共有は ReadWrite にして開く。読めなければ $null を返す。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    # ZipFile は System.IO.Compression.FileSystem、ZipArchive は System.IO.Compression。
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        # leaveOpen=$false。書庫を Dispose すればストリームも閉じる。
        return (New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false))
    } catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        return $null
    }
}

function Get-YakuSheetLayoutFromXlsx {
    <#
      .SYNOPSIS
        xlsx から、体裁の判断に要る3つだけを読む（列幅・折り返し・結合セル）。

      .DESCRIPTION
        Office は使わない。ZIP と XML だけで読む（docx を解析している経路と同じ）。
        取るのは次の3つに絞る。プレビューで「列に収まらない」を出すには、この3つが
        そろっていないと判定を誤るため。
          - 列幅   … 収まるかどうかの基準
          - 折り返し … ONなら幅を超えても切れず、行の高さが伸びる
          - 結合   … 結合していれば実効幅が広い
        行の高さと寄せも同時に読めるので併せて返す（見た目を寄せるのに使う）。

        列幅の単位は「標準フォントの文字数」。ブラウザ側は文字幅を実測して比べるので、
        ここでは Excel の値をそのまま渡す。境目ぎりぎりは信用しない前提で使う。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $zip = Open-YakuXlsxArchiveForRead -Path $Path
    if ($null -eq $zip) { return @() }
    try {
        function Read-YakuZipText {
            param($Archive, [string]$Name)
            $entry = $Archive.Entries | Where-Object { $_.FullName -eq $Name } | Select-Object -First 1
            if (-not $entry) { return '' }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }

        # スタイル番号 -> 折り返し・寄せ・太字。cellXfs の並び順がそのまま番号になる。
        $wrapByStyle = @{}
        $shrinkByStyle = @{}
        $alignByStyle = @{}
        $boldByStyle = @{}
        $stylesXml = Read-YakuZipText -Archive $zip -Name 'xl/styles.xml'
        if ($stylesXml) {
            # 太字は xf が直接持たず、fontId で fonts の並びを指す。先に font 側を作る。
            # <b/> は太字、<b val="0"/> は太字ではない（既定の font が太字のときに出る）。
            $boldByFont = @{}
            $fonts = [regex]::Match($stylesXml, '(?s)<fonts[^>]*>(.*?)</fonts>')
            if ($fonts.Success) {
                $fontIndex = 0
                foreach ($font in [regex]::Matches($fonts.Groups[1].Value, '(?s)<font\b.*?(?:/>|</font>)')) {
                    $bold = [regex]::Match($font.Value, '<b\s*(?:/>|val="(?<v>[^"]*)")')
                    $boldByFont[$fontIndex] = ($bold.Success -and @('0','false') -notcontains $bold.Groups['v'].Value)
                    $fontIndex++
                }
            }
            $cellXfs = [regex]::Match($stylesXml, '(?s)<cellXfs[^>]*>(.*?)</cellXfs>')
            if ($cellXfs.Success) {
                $index = 0
                foreach ($xf in [regex]::Matches($cellXfs.Groups[1].Value, '(?s)<xf\b.*?(?:/>|</xf>)')) {
                    $wrapByStyle[$index] = ($xf.Value -match 'wrapText="1"')
                    # 縮小して全体を表示（shrinkToFit）。付いているセルは Excel が
                    # 字を縮めて収めるので、幅からのはみ出し判定の対象ではない。
                    # 2026-08-17 まで読んでいなかったため、原本で既に収まっている
                    # セルが「はみ出し」と判定され、短縮の対象になっていた。
                    $shrinkByStyle[$index] = ($xf.Value -match 'shrinkToFit="1"')
                    $horizontal = [regex]::Match($xf.Value, 'horizontal="([a-z]+)"')
                    $alignByStyle[$index] = if ($horizontal.Success) { $horizontal.Groups[1].Value } else { '' }
                    $fontId = [regex]::Match($xf.Value, 'fontId="(\d+)"')
                    $boldByStyle[$index] = ($fontId.Success -and [bool]$boldByFont[[int]$fontId.Groups[1].Value])
                    $index++
                }
            }
        }

        # シート名 -> パート名の解決は、run（セル内部分書式）の読み取りと同じ関数を使う。
        # 写しを2つ持つと、片方だけ直したときに黙ってずれる。
        $sheetSpecs = @(Get-YakuXlsxSheetParts -Archive $zip)

        $sheets = New-Object System.Collections.Generic.List[object]
        foreach ($sheetSpec in $sheetSpecs) {
            $name = [string]$sheetSpec.Name
            $sheetXml = Read-YakuZipText -Archive $zip -Name ([string]$sheetSpec.PartName)
            if (-not $sheetXml) { continue }

            # 既定の列幅は「文字数」、既定の行の高さは「ポイント」。単位が違うので混ぜない。
            $defaultWidth = 8.43
            $defaultHeight = 18.75
            $format = [regex]::Match($sheetXml, '<sheetFormatPr\b[^>]*>')
            if ($format.Success) {
                $value = [regex]::Match($format.Value, 'defaultColWidth="([0-9.]+)"')
                if ($value.Success) { $defaultWidth = [double]$value.Groups[1].Value }
                $heightValue = [regex]::Match($format.Value, 'defaultRowHeight="([0-9.]+)"')
                if ($heightValue.Success) { $defaultHeight = [double]$heightValue.Groups[1].Value }
            }

            $columns = New-Object System.Collections.Generic.List[object]
            # width 属性の無い <col> は幅が分からない。既定幅として数えると、
            # 隠し列などに 8.43 ぶんの余地があることになり、判定が甘い側へ外れる
            # （2026-08-17）。列の範囲だけ別に残し、そこは「測れない」として扱う。
            $unknownWidthColumns = New-Object System.Collections.Generic.List[object]
            foreach ($col in [regex]::Matches($sheetXml, '<col\b[^>]*/?>')) {
                $min = [regex]::Match($col.Value, 'min="(\d+)"'); $max = [regex]::Match($col.Value, 'max="(\d+)"')
                $width = [regex]::Match($col.Value, 'width="([0-9.]+)"')
                if ($min.Success -and $max.Success -and -not $width.Success) {
                    [void]$unknownWidthColumns.Add([ordered]@{
                        min = [int]$min.Groups[1].Value
                        max = [int]$max.Groups[1].Value
                        hidden = ($col.Value -match 'hidden=\"1\"')
                    })
                }
                if (-not ($min.Success -and $max.Success -and $width.Success)) { continue }
                [void]$columns.Add([ordered]@{
                    min = [int]$min.Groups[1].Value
                    max = [int]$max.Groups[1].Value
                    width = [double]$width.Groups[1].Value
                    hidden = ($col.Value -match 'hidden="1"')
                })
            }

            $merges = New-Object System.Collections.Generic.List[string]
            foreach ($merge in [regex]::Matches($sheetXml, '<mergeCell\b[^>]*ref="([^"]+)"')) { [void]$merges.Add($merge.Groups[1].Value) }

            # 右への表示スピルや空白セル再利用の候補を安全に評価するには、
            # 翻訳対象だけでなく値・数式を持つ全セルの占有状態が要る。
            $occupiedCells = New-Object System.Collections.Generic.List[string]
            $formulaCells = New-Object System.Collections.Generic.List[string]
            # 自己終端の形を**先に**置く。中身を持つ形を先に試すと、`[^>]*` が
            # `<c r="B6" s="9"/` まで食べたあと `/>` に外れ、`>` の枝へ落ちて
            # `.*?</c>` が**次のセルの中身を盗む**。空セルが「占有」「数式」に化け、
            # 盗まれた側のセルは走査から丸ごと消える。
            # 実測（テストファイル Sheet1）: 一致 56件（正しくは512件）、
            # occupied の44件が誤り、formula の5件が誤り。B6 は17文字の空セルなのに
            # 336文字を1件として掴んでいた。
            foreach ($cellNode in [regex]::Matches($sheetXml, '(?s)<c\b[^>]*/>|<c\b[^>]*>.*?</c>')) {
                $addressMatch = [regex]::Match($cellNode.Value, '\br="([A-Z]+\d+)"')
                if (-not $addressMatch.Success) { continue }
                $address = [string]$addressMatch.Groups[1].Value
                if ($cellNode.Value -match '<(?:v|is|f)\b') { [void]$occupiedCells.Add($address) }
                if ($cellNode.Value -match '<f\b') { [void]$formulaCells.Add($address) }
            }

            # 行の高さ。既定と違う行だけ持つ（全行ぶん持つと資料しだいで際限なく増える）。
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($row in [regex]::Matches($sheetXml, '<row\b[^>]*>')) {
                $number = [regex]::Match($row.Value, ' r="(\d+)"')
                $height = [regex]::Match($row.Value, ' ht="([0-9.]+)"')
                if (-not ($number.Success -and $height.Success)) { continue }
                [void]$rows.Add([ordered]@{ row = [int]$number.Groups[1].Value; height = [double]$height.Groups[1].Value })
            }

            # 折り返しと寄せは、セル単位で持つ（同じ列でも行によって違う）。
            $cells = New-Object System.Collections.Generic.List[object]
            foreach ($cell in [regex]::Matches($sheetXml, '<c\b[^>]*r="([A-Z]+\d+)"[^>]*s="(\d+)"[^>]*>')) {
                $style = [int]$cell.Groups[2].Value
                $wrap = [bool]$wrapByStyle[$style]
                $shrink = [bool]$shrinkByStyle[$style]
                $align = [string]$alignByStyle[$style]
                $bold = [bool]$boldByStyle[$style]
                if (-not $wrap -and -not $shrink -and -not $bold -and [string]::IsNullOrEmpty($align)) { continue }
                [void]$cells.Add([ordered]@{ address = [string]$cell.Groups[1].Value; wrap = $wrap; shrink = $shrink; align = $align; bold = $bold })
            }

            # ここは @($columns) と書いてはいけない。PowerShell 5.1 の
            # 配列部分式は List[object] に限って ArgumentException（Argument types
            # do not match）を投げる。List[string] も ArrayList も投げない。
            # 実測は 5.1.26100.9168。ToArray() なら通る。
            [void]$sheets.Add([ordered]@{
                name = [string]$name
                default_width = [double]$defaultWidth
                default_height = [double]$defaultHeight
                columns = $columns.ToArray()
                unknown_width_columns = $unknownWidthColumns.ToArray()
                merges = $merges.ToArray()
                occupied_cells = @($occupiedCells.ToArray() | Sort-Object -Unique)
                formula_cells = @($formulaCells.ToArray() | Sort-Object -Unique)
                rows = $rows.ToArray()
                cells = $cells.ToArray()
            })
        }
        return $sheets.ToArray()
    } catch {
        # 体裁は「足し」であって前提ではない。読めなければプレビューは今までどおり出す。
        try { Write-YakuLog ('Sheet layout read failed; preview falls back to plain cells. reason=' + $_.Exception.Message) 'DEBUG' } catch {}
        return @()
    } finally {
        if ($null -ne $zip) { try { $zip.Dispose() } catch {} }
    }
}

# ---------------------------------------------------------------------------
# セル内部分書式（run）の読み取り
#
# なぜ要るか（2026-08-16 に Excel COM で実測。テストファイルの複写に対して実行）:
#   1〜4文字目だけ太字のセルへ Value2 で書くと、**1文字目の書式が新しい文字列
#   全体へ広がる**（29文字すべて太字になった）。一括の2次元配列代入でも同じ。
#   さらに悪いのは、翻訳対象ではない隣のセルが一括の箱に巻き込まれた場合で、
#   元の値をそのまま書き戻すだけでも run が消える（1文字ずつの太字が
#   `....BBBB....` から `............` になった）。**本文は1バイトも変わらない**ので、
#   文字を比べる検査では永久に見つからない。
#
#   だから書き込みの前に「どのセルが run を持つか」を知る必要がある。Excel は
#   使わない。書き込み中の複写は Excel が握っているので、**原本を** ZIP として開く。
# ---------------------------------------------------------------------------

# rPr / font のうち、読み手の目に見えるものだけ。charset・family・scheme は
# rFont に付随する情報で、見た目には出ない。Excel は同一書体でも CJK の run に
# family=3、ASCII の run に family=2 を書くので、これらまで比べると
# 「書式が違う」が量産される。**run を数えるのではなく、run どうしを比べる。**
$script:YakuXlsxRunVisibleProperties = @('b','i','u','strike','color','sz','rFont','vertAlign','outline','shadow')

# 値を持たない切り替え。`<b/>` と `<b val="1"/>` は同じ。`<b val="0"/>` は
# 「太字ではない」で、セル側の字体が太字のときに run 側で打ち消すために出る。
$script:YakuXlsxRunToggleProperties = @('b','i','strike','outline','shadow')

# rPr が書かれていないときだけ、セルの字体から引き継ぐ項目。
# 切り替え（太字・下線など）はここに入れない。**rPr は差分ではない**からである
# （下の Merge-YakuXlsxRunProperties に実測を書いた）。
$script:YakuXlsxRunInheritedProperties = @('color','sz','rFont')

function Get-YakuXlsxPartText {
    param(
        [Parameter(Mandatory=$true)]$Archive,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $entry = $Archive.Entries | Where-Object { $_.FullName -eq $Name } | Select-Object -First 1
    if (-not $entry) { return '' }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-YakuXlsxSheetParts {
    <#
      .SYNOPSIS
        ブックのシート名と、そのシートの XML パート名の対応を返す。

      .DESCRIPTION
        `xl/workbook.xml` の並び順とパート名は一致しない。`r:id` を
        `xl/_rels/workbook.xml.rels` で引いて解決する。引けないときだけ
        並び順から `sheet1.xml` を推測する（それしか手が無いため）。
    #>
    param([Parameter(Mandatory=$true)]$Archive)
    $workbookXml = Get-YakuXlsxPartText -Archive $Archive -Name 'xl/workbook.xml'
    $workbookRelsXml = Get-YakuXlsxPartText -Archive $Archive -Name 'xl/_rels/workbook.xml.rels'
    $relationshipTargets = @{}
    if ($workbookRelsXml) {
        try {
            $relsDoc = New-Object Xml.XmlDocument
            $relsDoc.LoadXml($workbookRelsXml)
            foreach ($relationship in @($relsDoc.SelectNodes("//*[local-name()='Relationship']"))) {
                $relationshipTargets[[string]$relationship.Id] = [string]$relationship.Target
            }
        } catch {}
    }
    $sheetSpecs = New-Object System.Collections.Generic.List[object]
    try {
        $workbookDoc = New-Object Xml.XmlDocument
        $workbookDoc.LoadXml($workbookXml)
        $sheetOrdinal = 0
        foreach ($sheetNode in @($workbookDoc.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']"))) {
            $sheetOrdinal++
            $relationshipId = [string]$sheetNode.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
            $target = [string]$relationshipTargets[$relationshipId]
            $partName = ''
            if (-not [string]::IsNullOrWhiteSpace($target)) {
                try {
                    $base = [Uri]'https://yaku.invalid/xl/workbook.xml'
                    $resolved = [Uri]::new($base,$target)
                    $partName = [Uri]::UnescapeDataString($resolved.AbsolutePath.TrimStart('/'))
                } catch { $partName = '' }
            }
            if ([string]::IsNullOrWhiteSpace($partName)) { $partName = 'xl/worksheets/sheet' + $sheetOrdinal + '.xml' }
            $sheetSpecs.Add([pscustomobject]@{ Name=[string]$sheetNode.GetAttribute('name'); PartName=$partName; Ordinal=$sheetOrdinal }) | Out-Null
        }
    } catch {
        $sheetOrdinal = 0
        foreach ($sheet in [regex]::Matches($workbookXml, '<sheet\b[^>]*name="([^"]*)"')) {
            $sheetOrdinal++
            $sheetSpecs.Add([pscustomobject]@{ Name=$sheet.Groups[1].Value; PartName=('xl/worksheets/sheet' + $sheetOrdinal + '.xml'); Ordinal=$sheetOrdinal }) | Out-Null
        }
    }
    # `@($list)` は List[object] に限って ArgumentException を投げる（実測 5.1.26100.9168）。
    return $sheetSpecs.ToArray()
}

function Get-YakuXlsxFontVisibleProperties {
    <#
      .SYNOPSIS
        `<font>`（styles.xml）または `<rPr>`（sharedStrings.xml）から、見える書式だけを取る。

      .DESCRIPTION
        **要素名が違う。** 書体は `<fonts>` 側が `<name val="..."/>`、`<rPr>` 側が
        `<rFont val="..."/>` である。同じものなので rFont へ寄せる。写像しないと、
        「セル自身の字体を言い直しているだけの run」がセルと別物に見える。
    #>
    param([AllowNull()]$Node)
    $properties = @{}
    if ($null -eq $Node) { return $properties }
    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $name = [string]$child.LocalName
        if ($name -eq 'name') { $name = 'rFont' }
        if ($script:YakuXlsxRunVisibleProperties -notcontains $name) { continue }
        $value = ''
        try { $value = [string]$child.GetAttribute('val') } catch { $value = '' }
        if ($name -eq 'color') {
            # 色は指し方（rgb / theme / indexed）ごと覚える。指し方が違えば別の色である。
            $bits = New-Object System.Collections.Generic.List[string]
            foreach ($attribute in @('rgb','theme','tint','indexed','auto')) {
                $found = ''
                try { $found = [string]$child.GetAttribute($attribute) } catch { $found = '' }
                if (-not [string]::IsNullOrEmpty($found)) { $bits.Add($attribute + ':' + $found) | Out-Null }
            }
            if ($bits.Count -gt 0) { $properties['color'] = ($bits.ToArray() -join ',') }
            continue
        }
        if ($name -eq 'u') {
            $underline = if ([string]::IsNullOrEmpty($value)) { 'single' } else { $value }
            if (@('none','0','false') -contains $underline.ToLowerInvariant()) { $underline = '0' }
            $properties['u'] = $underline
            continue
        }
        if ($script:YakuXlsxRunToggleProperties -contains $name) {
            if ([string]::IsNullOrEmpty($value)) { $properties[$name] = '1' }
            elseif (@('0','false') -contains $value.ToLowerInvariant()) { $properties[$name] = '0' }
            else { $properties[$name] = '1' }
            continue
        }
        $properties[$name] = $value
    }
    return $properties
}

function Merge-YakuXlsxRunProperties {
    <#
      .SYNOPSIS
        run の書式を「そのセルの字体」の上に解いて、見えるかたちへ畳む。

      .DESCRIPTION
        **rPr の無い run は、そのセルの字体そのもの**になる。そこを解かずに
        比べると、セル自身の字体を言い直しているだけの run が別物に見える
        （利用者のテストファイル C7 がまさにこれ。run は3つあるが差はゼロ）。

        **rPr が在るときは、rPr が差分ではなくその run の書式そのものである。**
        実測（Excel 16.0 が保存した xlsx）: セルの1〜4文字目だけを太字にすると、
        Excel は**セルの字体のほうを太字**にし、1つ目の run には rPr を書かず、
        残りの run に「太字を含まない rPr」を書いた。rPr を差分として扱うと、
        1つ目の太字が全 run へ及び「混在ではない」に化ける（実際に化けて、
        Excel が書いた本物のブックで run セルを1件も拾えなかった）。
        だから切り替え（太字・下線など）は、rPr が在るなら書かれていないものを
        「切ってある」とみなす。大きさ・色・書体は、書かれていなければセルの
        字体を引き継ぐ（Excel は必ず書くが、書かない書き手のときに
        既定値を当てずっぽうで入れて差を作らないため）。

        `<b val="0"/>` のような打ち消しと、そもそも書かれていない場合は、
        見た目が同じなのでここで同じ扱いへ畳む。
    #>
    param(
        [AllowNull()][hashtable]$CellProperties,
        [AllowNull()][hashtable]$RunProperties
    )
    $merged = @{}
    if ($null -ne $CellProperties) { foreach ($key in @($CellProperties.Keys)) { $merged[[string]$key] = [string]$CellProperties[$key] } }
    if ($null -ne $RunProperties) {
        foreach ($name in $script:YakuXlsxRunVisibleProperties) {
            if ($script:YakuXlsxRunInheritedProperties -contains $name) { continue }
            $merged.Remove($name)
        }
        foreach ($key in @($RunProperties.Keys)) { $merged[[string]$key] = [string]$RunProperties[$key] }
    }
    $normalized = @{}
    foreach ($name in $script:YakuXlsxRunVisibleProperties) {
        if (-not $merged.ContainsKey($name)) { continue }
        $value = [string]$merged[$name]
        if ([string]::IsNullOrEmpty($value) -or $value -eq '0') { continue }
        $normalized[$name] = $value
    }
    return $normalized
}

function Get-YakuXlsxRunSignature {
    # 見た目の署名。同じ署名なら、読み手には同じに見える。
    param([AllowNull()][hashtable]$Properties)
    if ($null -eq $Properties) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:YakuXlsxRunVisibleProperties) {
        if (-not $Properties.ContainsKey($name)) { continue }
        $value = [string]$Properties[$name]
        if ([string]::IsNullOrEmpty($value) -or $value -eq '0') { continue }
        $parts.Add($name + '=' + $value) | Out-Null
    }
    return ($parts.ToArray() -join ';')
}

function ConvertFrom-YakuXlsxCellAddress {
    param([Parameter(Mandatory=$true)][string]$Address)
    $match = [regex]::Match([string]$Address, '^\$?([A-Z]+)\$?(\d+)$')
    if (-not $match.Success) { return $null }
    $col = 0
    foreach ($letter in ([string]$match.Groups[1].Value).ToCharArray()) { $col = ($col * 26) + ([int][char]$letter - 64) }
    return [pscustomobject]@{ Row = [int]$match.Groups[2].Value; Col = [int]$col }
}

function New-YakuXlsxRunCellFormat {
    <#
      .SYNOPSIS
        1つの共有文字列の run 群を、そのセルの字体の上で解いて比べる。
        見た目に差が無ければ `$null`（run セルではない）を返す。

      .DESCRIPTION
        返すのは3つ。
          - Runs                … 本文・文字数・解いた署名
          - DominantProperties  … **文字数の合計がいちばん多い**書式
          - DifferingProperties … run どうしで食い違っている項目だけ
        書き込み後に揃えるのは DifferingProperties だけである。全部を代入すると、
        セル全体が太字だった（run ではない）セルまで巻き込む。
    #>
    param(
        [AllowNull()][object[]]$Runs,
        [AllowNull()][hashtable]$CellProperties
    )
    if ($null -eq $Runs -or $Runs.Count -lt 2) { return $null }
    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($run in $Runs) {
        $properties = Merge-YakuXlsxRunProperties -CellProperties $CellProperties -RunProperties $run.Properties
        $text = [string]$run.Text
        $resolved.Add([pscustomobject]@{
            Text = $text
            Length = [int]$text.Length
            Properties = $properties
            Signature = [string](Get-YakuXlsxRunSignature -Properties $properties)
        }) | Out-Null
    }
    $items = $resolved.ToArray()

    $lengthBySignature = @{}
    $propertiesBySignature = @{}
    $signatureOrder = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $signature = [string]$item.Signature
        if (-not $lengthBySignature.ContainsKey($signature)) {
            $lengthBySignature[$signature] = 0
            $propertiesBySignature[$signature] = $item.Properties
            $signatureOrder.Add($signature) | Out-Null
        }
        $lengthBySignature[$signature] = [int]$lengthBySignature[$signature] + [int]$item.Length
    }
    # **数えない。比べる。** run が3つあっても、解いた署名が全部同じなら見た目は一様である。
    if ($signatureOrder.Count -lt 2) { return $null }

    $dominantSignature = ''
    $dominantLength = -1
    foreach ($signature in @($signatureOrder.ToArray())) {
        if ([int]$lengthBySignature[$signature] -gt $dominantLength) {
            $dominantSignature = [string]$signature
            $dominantLength = [int]$lengthBySignature[$signature]
        }
    }

    $differing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:YakuXlsxRunVisibleProperties) {
        $seen = @{}
        foreach ($item in $items) {
            $value = ''
            if ($item.Properties.ContainsKey($name)) { $value = [string]$item.Properties[$name] }
            $seen[$value] = $true
        }
        if ($seen.Count -gt 1) { $differing.Add($name) | Out-Null }
    }

    return [pscustomobject]@{
        Runs = $items
        DominantSignature = [string]$dominantSignature
        DominantLength = [int]$dominantLength
        DominantProperties = $propertiesBySignature[$dominantSignature]
        DifferingProperties = [string[]]@($differing.ToArray())
    }
}

function Get-YakuXlsxRunsFromRichNode {
    <#
      .SYNOPSIS
        `<si>`（共有文字列）または `<is>`（セルの中へ直書き）の直下から run を取る。

      .DESCRIPTION
        入れ物の名前が違うだけで、中身の決まりは同じである（`<r>` が並び、
        `<rPr>` がその run の書式、`<t>` が本文）。**同じ判定を当てるために
        1か所へ寄せる。** 2つ書くと、片方だけ直したときに黙って食い違う。

        **裸の `<t>` も run として数える。** `<is><t>MIXED</t><r><rPr><b/></rPr>
        <t>BOLDPART</t></r></is>` のように `<t>` と `<r>` を並べる書き手がいる
        （実測 2026-08-16。共有文字列側でも同じ形が実在した）。Excel はこれを
        部分太字として描くのに、`<r>` だけを集めると run が1つになり、
        `Count -lt 2` の門で「差は無い」に化ける。裸の `<t>` は rPr を持たない
        ので、そのセルの字体そのものとして解く。

        `<rPh>`（ふりがな）も `<t>` を持つが run ではない。見るのは直下の子だけ
        なので、`<rPh>` の中の `<t>` はここに入らない。
    #>
    param([AllowNull()]$Node)
    $runs = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Node) { return $runs.ToArray() }
    foreach ($child in $Node.ChildNodes) {
        $name = [string]$child.LocalName
        if ($name -eq 't') {
            $runs.Add([pscustomobject]@{ Text = [string]$child.InnerText; Properties = $null }) | Out-Null
            continue
        }
        if ($name -ne 'r') { continue }
        $runProperties = $null
        $text = ''
        foreach ($grandChild in $child.ChildNodes) {
            if ([string]$grandChild.LocalName -eq 'rPr') { $runProperties = Get-YakuXlsxFontVisibleProperties -Node $grandChild }
            elseif ([string]$grandChild.LocalName -eq 't') { $text = [string]$grandChild.InnerText }
        }
        $runs.Add([pscustomobject]@{ Text = [string]$text; Properties = $runProperties }) | Out-Null
    }
    # `@($list)` は List[object] に限って ArgumentException を投げる（実測 5.1.26100.9168）。
    return $runs.ToArray()
}

function Get-YakuXlsxStyleFontMap {
    <#
      .SYNOPSIS
        `xl/styles.xml` から「スタイル番号 -> そのセルの字体」を引ける表を作る。

      .DESCRIPTION
        共有文字列でもセル内直書きでも、run は**そのセルの字体の上に**解く
        （rPr の無い run はセルの字体そのものになる）。引き当てる道具は同じなので
        1か所へ寄せる。読むのはシートを1枚でも走査すると決まってからでよい。
    #>
    param([Parameter(Mandatory=$true)]$Archive)
    $fontProperties = New-Object System.Collections.Generic.List[object]
    $fontIdByStyle = @{}
    $stylesXml = Get-YakuXlsxPartText -Archive $Archive -Name 'xl/styles.xml'
    if (-not [string]::IsNullOrWhiteSpace($stylesXml)) {
        $stylesDoc = New-Object Xml.XmlDocument
        $stylesDoc.LoadXml($stylesXml)
        foreach ($fontNode in @($stylesDoc.SelectNodes("//*[local-name()='fonts']/*[local-name()='font']"))) {
            $fontProperties.Add((Get-YakuXlsxFontVisibleProperties -Node $fontNode)) | Out-Null
        }
        $styleIndex = -1
        foreach ($xf in @($stylesDoc.SelectNodes("//*[local-name()='cellXfs']/*[local-name()='xf']"))) {
            $styleIndex++
            $fontId = 0
            try { $fontId = [int]$xf.GetAttribute('fontId') } catch { $fontId = 0 }
            $fontIdByStyle[$styleIndex] = [int]$fontId
        }
    }
    return [pscustomobject]@{ Fonts = $fontProperties.ToArray(); FontIdByStyle = $fontIdByStyle }
}

# ---------------------------------------------------------------------------
# 判定を**反転**するための道具（2026-08-16 の利用者判断）
#
#   いま  リッチだと分かったセルを箱から外す   → 見落としたら壊す
#   反転  平文だと証明できたセルだけ箱に入れる → 見落としたら遅くなるだけ
#
# 「リッチな形を1つずつ列挙する」作りは2回続けて穴が出た（inlineStr の
# `<is><r><rPr>`、そのあと `<t>`+`<r>` 混在・単引用符の属性・`<rPh>` の3つ）。
# XML の書き方は無数にあるので列挙は終わらない。だから**証明できた形だけ**を
# 平文として通す。この筋は `Test-YakuExcelComFalse` が `DBNull` を
# 「偽と確定していない」として安全側へ倒すのと同じである。
#
# 字面を読む道具はここへ寄せる。**属性は二重引用符とは限らない。**
# `<c r='E2' s='0' t='s'>` を書く書き手が実在する（実測 2026-08-16。
# 二重引用符固定の正規表現は1件も拾わなかった）。両対応にするだけでは足りない
# ので、開始タグは属性の並びごと厳密に取り、取れなければ**そのシート全体を
# 証明できない**ものとして扱う（住所が分からない以上、どのセルかを言えない）。
# ---------------------------------------------------------------------------

function New-YakuXlsxRegex {
    # 走査は1シートにつき数十万回まわる。組み立てを取り置く。
    param([Parameter(Mandatory=$true)][string]$Pattern)
    return (New-Object System.Text.RegularExpressions.Regex($Pattern, ([System.Text.RegularExpressions.RegexOptions]::Compiled)))
}

# 名前空間の接頭辞は付いていても付いていなくてもよい（`<is>` と `<x:is>`）。
$script:YakuXlsxNamePrefixPattern = '(?:[\w.\-]+:)?'
# 属性の並び。二重引用符でも単引用符でもよい。**これで取れない書き方は
# 「知らない形」なので、通さない。**
$script:YakuXlsxAttrPattern = '(?:\s+[\w:.\-]+\s*=\s*(?:"[^"]*"|' + "'[^']*'" + '))*'

# 開始タグだけを数える物差し。厳密な切り出しと数が合わなければ、字面の
# 読み方そのものが当たっていない合図である。そのときは丸ごと証明できない。
$script:YakuXlsxCellOpenRegex = New-YakuXlsxRegex ('<' + $script:YakuXlsxNamePrefixPattern + 'c(?=[\s/>])')
$script:YakuXlsxSiOpenRegex = New-YakuXlsxRegex ('<' + $script:YakuXlsxNamePrefixPattern + 'si(?=[\s/>])')
# `<is>`（セルの中へ直書きする文字列）。1つも無いことは字面で確かめられる。
$script:YakuXlsxIsOpenRegex = New-YakuXlsxRegex ('<' + $script:YakuXlsxNamePrefixPattern + 'is(?=[\s/>])')
# `<r>`（run）。`<rPr>` `<rPh>` は次の字が英字なので当たらない。
$script:YakuXlsxRunOpenRegex = New-YakuXlsxRegex ('<' + $script:YakuXlsxNamePrefixPattern + 'r(?=[\s/>])')

# 自己終端を**先に**試す並びにしてある。中身を持つ形を先に置くと
# `<c r="B6" s="9"/>` を飲み、`.*?</c>` が次のセルの中身を盗む。
$script:YakuXlsxCellRegex = New-YakuXlsxRegex ('(?s)<' + $script:YakuXlsxNamePrefixPattern + 'c(?<attrs>' + $script:YakuXlsxAttrPattern + ')\s*(?:/>|>(?<body>.*?)</' + $script:YakuXlsxNamePrefixPattern + 'c>)')
$script:YakuXlsxSiRegex = New-YakuXlsxRegex ('(?s)<' + $script:YakuXlsxNamePrefixPattern + 'si(?<attrs>' + $script:YakuXlsxAttrPattern + ')\s*(?:/>|>(?<inner>.*?)</' + $script:YakuXlsxNamePrefixPattern + 'si>)')
$script:YakuXlsxIsRegex = New-YakuXlsxRegex ('(?s)<' + $script:YakuXlsxNamePrefixPattern + 'is(?<attrs>' + $script:YakuXlsxAttrPattern + ')\s*(?:/>|>(?<inner>.*?)</' + $script:YakuXlsxNamePrefixPattern + 'is>)')

# **「平文だと証明できた」形はこれ1つだけ。** 直下が `<t>` 1つで、`<r>` も
# `<rPh>` も `<phoneticPr>` もその他の子要素も無い。`[^<]*` は「本文に生の
# `<` は現れない」という XML の決まりに拠る（CDATA も入れ子も、ここで外れる）。
$script:YakuXlsxPlainTextPattern = '<' + $script:YakuXlsxNamePrefixPattern + 't' + $script:YakuXlsxAttrPattern + '\s*(?:/>|>[^<]*</' + $script:YakuXlsxNamePrefixPattern + 't>)'
$script:YakuXlsxPlainSiPattern = '<' + $script:YakuXlsxNamePrefixPattern + 'si' + $script:YakuXlsxAttrPattern + '\s*>\s*' + $script:YakuXlsxPlainTextPattern + '\s*</' + $script:YakuXlsxNamePrefixPattern + 'si>'
$script:YakuXlsxPlainSiRegex = New-YakuXlsxRegex $script:YakuXlsxPlainSiPattern
$script:YakuXlsxPlainSiExactRegex = New-YakuXlsxRegex ('\A' + $script:YakuXlsxPlainSiPattern + '\z')

$script:YakuXlsxCellRefRegex = New-YakuXlsxRegex ('\sr\s*=\s*(?:"([^"]*)"|' + "'([^']*)'" + ')')
$script:YakuXlsxCellTypeRegex = New-YakuXlsxRegex ('\st\s*=\s*(?:"([^"]*)"|' + "'([^']*)'" + ')')
$script:YakuXlsxCellStyleRegex = New-YakuXlsxRegex ('\ss\s*=\s*(?:"([^"]*)"|' + "'([^']*)'" + ')')
$script:YakuXlsxCellValueRegex = New-YakuXlsxRegex ('\A<' + $script:YakuXlsxNamePrefixPattern + 'v' + $script:YakuXlsxAttrPattern + '\s*(?:/>|>([^<]*)</' + $script:YakuXlsxNamePrefixPattern + 'v>)\z')

# 共有文字列でもインライン文字列でもない型。`<c>` の子は f / v / is / extLst
# しか無く、文字の書式もふりがなも `<is>` か共有表にしか置けないので、
# ここに挙げた型のセルは中身によらず平文である。
# **知らない型はここに入れない。** 入れないものは全部「証明できない」へ倒れる。
$script:YakuXlsxPlainCellTypes = @('', 'n', 'b', 'e', 'str', 'd')

function Get-YakuXlsxMatchedAttribute {
    # 属性が無ければ $null、在れば値。二重引用符と単引用符のどちらでも取る。
    param($Regex, [AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $match = $Regex.Match($Text)
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return [string]$match.Groups[1].Value }
    return [string]$match.Groups[2].Value
}

function New-YakuXlsxSheetScopeNonPlainCell {
    <#
      .SYNOPSIS
        「このシートは丸ごと証明できない」を表す1件を作る。

      .DESCRIPTION
        住所が分からないセルが1つでもあれば、どの箱が安全かを言えない。
        行も列も 0 なので、揃え直し（`Set-YakuExcelRunCellDominantFormat`）は
        触らない。箱の判定だけが `scope` を見て、無条件に一括経路を捨てる。
    #>
    return [ordered]@{
        address = '(sheet)'
        row = 0
        col = 0
        scope = 'sheet'
        runs = @()
        dominant_signature = ''
        dominant_properties = $null
        differing_properties = [string[]]@()
    }
}

function Resolve-YakuXlsxRichFragmentFormat {
    <#
      .SYNOPSIS
        `<si>` / `<is>` の断片を解いて、揃え直しに使う書式を返す。

      .DESCRIPTION
        返すのは `Format`（解けなければ $null）と `Failed`（断片を読めなかった）。
        **読めなくても被害は増えない。** そのセルはすでに「平文と証明できない」
        側にいるので箱からは外れており、揃え直しをしないだけである。
        断片だけでは接頭辞が未宣言になる場合が実際にある
        （`<worksheet>` 側で宣言した接頭辞を `<is>` の中で使う書き方）。
    #>
    param(
        [Parameter(Mandatory=$true)]$Document,
        [AllowNull()][string]$Fragment,
        [AllowNull()][hashtable]$CellProperties
    )
    if ([string]::IsNullOrEmpty($Fragment)) { return [pscustomobject]@{ Format = $null; Failed = $false } }
    $parsed = $false
    try { $Document.LoadXml($Fragment); $parsed = $true } catch { $parsed = $false }
    $format = $null
    if ($parsed) {
        $runs = @(Get-YakuXlsxRunsFromRichNode -Node $Document.DocumentElement)
        # run が1つなら、そのセルの中で書式が変わりようがない。
        if ($runs.Count -ge 2) { $format = New-YakuXlsxRunCellFormat -Runs $runs -CellProperties $CellProperties }
    }
    return [pscustomobject]@{ Format = $format; Failed = (-not $parsed) }
}

function Get-YakuXlsxSharedStringText {
    <#
      .SYNOPSIS
        共有文字列表の中身を返す。**パート名を決め打ちしない。**

      .DESCRIPTION
        `xl/sharedStrings.xml` は慣習であって決まりではない。Excel は
        `xl/_rels/workbook.xml.rels` の関係（Type が `.../sharedStrings` で
        終わるもの）を辿って読む。名前が違うだけの xlsx を Excel は普通に開く。

        決め打ちで探していたため、`Target="strtable.xml"` のブックでは表そのものが
        見えず、**シートの全セルが「平文だと証明できた」ことになって箱へ入り、
        部分書式が消えた**（2026-08-16 に実測）。シートの側は最初から関係を
        辿っていた（`Get-YakuXlsxSheetSpecs`）ので、ここだけが取り残されていた。

        **関係はあるのに中身が読めないときは、空ではなく「読めない印」を返す。**
        空を返すと「表が無い＝共有の rich text は存在しえない＝全部平文」という
        枝へ落ちてしまい、いちばん危ない側へ倒れる。
    #>
    param([Parameter(Mandatory=$true)]$Archive)

    $relsXml = Get-YakuXlsxPartText -Archive $Archive -Name 'xl/_rels/workbook.xml.rels'
    $target = ''
    if (-not [string]::IsNullOrWhiteSpace($relsXml)) {
        try {
            $relsDoc = New-Object Xml.XmlDocument
            $relsDoc.LoadXml($relsXml)
            foreach ($relationship in @($relsDoc.SelectNodes("//*[local-name()='Relationship']"))) {
                $type = [string]$relationship.GetAttribute('Type')
                if ($type -match '(?i)/sharedStrings$') { $target = [string]$relationship.GetAttribute('Target'); break }
            }
        } catch {
            # 関係が読めないなら、表の在処を言えない。証明できない側へ倒す。
            return '<!--unreadable-workbook-rels-->'
        }
    }

    $partName = ''
    if (-not [string]::IsNullOrWhiteSpace($target)) {
        try {
            $base = [Uri]'https://yaku.invalid/xl/workbook.xml'
            $resolved = [Uri]::new($base, $target)
            $partName = [Uri]::UnescapeDataString($resolved.AbsolutePath.TrimStart('/'))
        } catch { $partName = '' }
        if ([string]::IsNullOrWhiteSpace($partName)) { return '<!--unresolvable-sharedstrings-target-->' }
        $text = Get-YakuXlsxPartText -Archive $Archive -Name $partName
        if ([string]::IsNullOrEmpty($text)) {
            # 関係は「ここにある」と言っているのに読めない。空扱いにしない。
            return '<!--missing-sharedstrings-part-->'
        }
        return $text
    }

    # 関係が sharedStrings を宣言していないブック。慣習の名前だけを見る。
    # 無ければ本当に表が無い（共有の rich text は存在しえない）。
    return (Get-YakuXlsxPartText -Archive $Archive -Name 'xl/sharedStrings.xml')
}

function Resolve-YakuXlsxSharedStringPlainness {
    <#
      .SYNOPSIS
        共有文字列を「平文だと**証明できた**か」で仕分ける。

      .DESCRIPTION
        返すのは4つ。
          - AllPlain     … 表そのものが1つ残らず平文だと証明できた
          - PlainFlags   … 番号ごとの証明結果（AllPlain のときは $null）
          - RunFragments … run を持つ `<si>` の断片。揃え直しのために残す
          - Unproven     … 字面の読み方が当たっていない。**全部を非平文に倒す**

        速い側の道が要る。`<si>` を1つずつ調べる輪は数十万回まわるので、
        まず**数だけで**「全部平文」を確かめる。平文の形で切り出せた数が
        `<si>` の開始タグの数と等しければ、どの `<si>` も平文の形に収まって
        いたことになる（切り出しは重ならず、1つの `<si>` を1回ずつ食べる）。
        等しくないときだけ、番号を数えながら1つずつ見る。

        共有表そのものが無いブックは「全部平文」にする。表が無ければ共有の
        rich text は存在しえず、`t="s"` の参照は宙に浮く（守るべき書式が無い）。

        **数える前に、数が信じられる字面かを確かめる（2026-08-16）。**
        コメント・処理命令・CDATA・DOCTYPE の中に `<si>` を書くと、
        `YakuXlsxSiRegex` も `YakuXlsxSiOpenRegex` も**等しく1つ数える**ので
        門は釣り合ったまま通る。ところが Excel はそれらを読まないので、
        `PlainFlags` の番号が実番号から丸ごとずれる。ずれた先が平文なら、
        部分太字のセルが「証明できた」ことになって箱へ入り、書式が消える。
        本文は1バイトも変わらないので、文字列を比べる検査では見つからない。

        直し方は「落としてから数える」ではなく **「そういう字面なら証明しない」**
        にした。落とす側は、落とし方そのものを間違える余地が残る
        （入れ子のコメント、`--` を含むコメント、CDATA の中の `]]>` など）。
        Excel が書く sharedStrings.xml にこれらは出てこないので、
        出てきたら遅くて安全な道へ落ちればよい。

        先頭の XML 宣言（`<?xml ... ?>`）だけは処理命令の形をしているが、
        これは Excel 自身が必ず書く。1つ目だけを外してから見る。
    #>
    param([AllowNull()][string]$Xml)
    $allPlain = [pscustomobject]@{ AllPlain = $true; PlainFlags = $null; RunFragments = @{}; Count = 0; Unproven = $false }
    $unproven = [pscustomobject]@{ AllPlain = $false; PlainFlags = $null; RunFragments = @{}; Count = 0; Unproven = $true }
    if ([string]::IsNullOrEmpty($Xml)) { return $allPlain }

    $scan = $Xml
    $declaration = [regex]::Match($scan, '^\s*<\?xml\b[^>]*\?>')
    if ($declaration.Success) { $scan = $scan.Substring($declaration.Length) }
    if ($scan.Contains('<!--') -or $scan.Contains('<?') -or $scan.Contains('<![CDATA[') -or $scan.Contains('<!DOCTYPE')) { return $unproven }

    $siMatches = $script:YakuXlsxSiRegex.Matches($Xml)
    $siOpens = $script:YakuXlsxSiOpenRegex.Matches($Xml).Count
    if ($siMatches.Count -ne $siOpens) {
        return [pscustomobject]@{ AllPlain = $false; PlainFlags = $null; RunFragments = @{}; Count = 0; Unproven = $true }
    }
    if ($siOpens -le 0) { return $allPlain }
    # 全部平文なら、番号がずれていても引き当てる先は必ず平文なので害が無い。
    # 速い側の道はここで返してよい（普通のブックはここを通る）。
    if ($script:YakuXlsxPlainSiRegex.Matches($Xml).Count -eq $siOpens) { return $allPlain }

    # **番号を使う前に、番号が Excel と揃っているかを確かめる（2026-08-16）。**
    # Excel が番号を振るのは `<sst>` の直下の `<si>` だけである。ところが
    # `<ext><si>…</si></ext>` のように**知らない要素が `<si>` を包んでいる**と、
    # 字面を数える物差しは包まれたものも1つ数えてしまう。`<ext>` 自体は `<si>` では
    # ないので開始タグの数とも釣り合い、門は通る。結果、番号が丸ごとずれて
    # 部分太字のセルが「証明できた」ことになり、書式が消える（実測で再現）。
    #
    # 見るのは `<si>` と `<si>` のあいだだけでよい。そこが空白以外なら、
    # 何かが挟まっている＝包んでいるかもしれない、ということである。
    # 先頭（`<?xml…?><sst…>`）と末尾（`</sst>` や規格どおりの `<extLst>`）は
    # `<si>` の外側なので見ない。
    for ($gapIndex = 1; $gapIndex -lt $siMatches.Count; $gapIndex++) {
        $gapStart = $siMatches[$gapIndex - 1].Index + $siMatches[$gapIndex - 1].Length
        $gapLength = $siMatches[$gapIndex].Index - $gapStart
        if ($gapLength -le 0) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Xml.Substring($gapStart, $gapLength))) { return $unproven }
    }

    $flags = New-Object 'System.Boolean[]' $siMatches.Count
    $fragments = @{}
    $index = -1
    foreach ($siMatch in $siMatches) {
        $index++
        $fragment = [string]$siMatch.Value
        if ($script:YakuXlsxPlainSiExactRegex.IsMatch($fragment)) { $flags[$index] = $true; continue }
        # 平文ではない理由が run なら、揃え直しのために断片を残す。
        # `<rPh>`（ふりがな）だけが理由なら run は無い。箱から外すには足り、
        # 揃え直しには要らないので、断片は持たない（覚える量を増やさない）。
        if ($script:YakuXlsxRunOpenRegex.IsMatch($fragment)) { $fragments[$index] = $fragment }
    }
    return [pscustomobject]@{ AllPlain = $false; PlainFlags = $flags; RunFragments = $fragments; Count = $siMatches.Count; Unproven = $false }
}

function Get-YakuXlsxNonPlainCells {
    <#
      .SYNOPSIS
        xlsx から、**平文だと証明できなかったセル**をシートごとに返す。

      .DESCRIPTION
        Office は使わない。ZIP と XML だけで読む。

        **箱に入れてよいのは、ここに載らなかったセルだけである。** 載せるのは
        「リッチだと分かったセル」ではなく「平文だと証明できなかったセル」で、
        知らない形は全部こちらへ落ちる。判定を反転したのは、列挙が2回続けて
        穴を出したからである（inlineStr の `<is><r><rPr>` を見ていなかった件の
        あと、さらに3つ見つかった）。XML の書き方は無数にあるので列挙は終わらない。

        平文だと**証明できる**のは次の2つだけ。
          - 共有文字列（`t="s"`）で、指す `<si>` の直下が `<t>` 1つだけ。
            `<r>` も `<rPh>` も `<phoneticPr>` も、その他の子要素も無い
          - 共有文字列でもインライン文字列でもないセル（数値・数式・真偽・空）

        それ以外は全部こちらに載る。inlineStr、`<t>` と `<r>` の混在、
        `<rPh>`（ふりがな）を持つもの、断片を解析できないもの、属性の引用符が
        想定と違うもの、そして**知らない形すべて**。

        返す1件は2つの役目を兼ねる。
          1. 除外集合 … 箱の脱出口（`Invoke-YakuExcelBulkBoundingBoxWrite`）が
             住所で使う。**こちらが主**である
          2. run の中身 … 訳文を書いたセルを支配的な書式へ揃えるのに使う
             （`Set-YakuExcelRunCellDominantFormat`）。読めた範囲でよい。
             読めなければ `runs` が空になり、揃え直しをしないだけで被害は増えない

        住所を取れないセルが1件でもあれば、`scope='sheet'` の1件だけを返して
        そのシートを丸ごと証明できないものとして扱う。どの箱が安全かを
        言えない以上、安全側は「そのシートの箱を全部捨てる」である。

        塞いだ穴（すべて実測。2026-08-16、本番の入口を通したもの）:
          - `<is><t>MIXED</t><r><rPr><b/></rPr><t>BOLDPART</t></r></is>` と、
            同じ形の共有文字列。Excel は部分太字として描く（`.....BBBBBBBB`）のに
            検出器は0件だった。直下の `<r>` しか集めず、run が1つになるため
          - `<c r='E2' s='0' t='s'>`（単引用符の属性）。二重引用符固定の
            正規表現は住所も型も1つも拾わなかった
          - `<rPh>`（ふりがな）。本文 `東京` は1バイトも変わらないまま
            `Phonetics.Count` が 1 → 0 になった。**これは Excel 自身が書く形である**

        速さは名札で守る（時計は機械の負荷で揺れる）。平文だけのブックでは
        シート本文を2回なでるだけで走査へ進まないので、`bulk_box=1
        bulk_mode=value2` のまま変わらない。証明できないセルを1つ入れると
        `bulk_run_cell_skips` が立って fallback へ落ちる。

        費用（実測 2026-08-16 / PowerShell 5.1.26100.9168。同じ題材で、反転前の
        実装と並べて測った）。前任者が入れた「解いた結果を (中身, 字体) の組で
        覚える表（上限20,000）」は効いているので残してある。

          題材（20,000行×12列＝240,000セル）             反転後（各3回）
          平文の共有文字列だけ（シート 10,244,689文字）  124 - 265ms
          24,000の共有文字列のうち1つだけ rich           1,665 - 2,104ms
          全セルが inlineStr の rich・中身は全部別        1,227 / 1,283秒

        3段目は 42,422,517文字のシートで、断片が1つも重ならないので覚える表が
        効かない、いちばん重い端である（2回目は別の試験と同時に回したぶん重い）。

        1段目が普通のブックの道である。共有表が1つ残らず平文で `<is>` も無ければ、
        シート本文を2回なでるだけで走査へ進まない。

        反転前と並べた実測（24,000セルに縮めて両方を同じ題材で回した）:

          題材（2,000行×12列＝24,000セル）   反転前            反転後
          平文の共有文字列だけ                111ms / 0件      68ms / 0件
          1つだけ rich（`<t>`+`<r>` の形）    320ms / **0件**  316ms / 12件
          全セルが inlineStr の rich          95,031ms         103,173ms

        2段目の「反転前 0件」が穴1そのものである（`<t>` と `<r>` が並ぶ形を
        1件も見なかった）。3段目は 8.6% 遅い。いちばん重い端だけの話で、
        普通のブックはむしろ速くなっている。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    # 利用者が原本を Excel で開いたままでも読む。ここが読めないと、守りだけが
    # 黙って外れる（書き出しそのものは Copy-Item で通ってしまうため）。
    $zip = Open-YakuXlsxArchiveForRead -Path $Path
    if ($null -eq $zip) { return @() }
    try {
        $shared = Resolve-YakuXlsxSharedStringPlainness -Xml (Get-YakuXlsxSharedStringText -Archive $zip)

        # styles.xml は、シートを1枚でも走査すると決まってから読む。
        $styleMap = $null
        $fonts = @()
        $fontIdByStyle = @{}

        # 断片ごとに XmlDocument を作り直さない。LoadXml は同じ器へ何度でも読める。
        $fragmentDoc = New-Object Xml.XmlDocument
        $fragmentDoc.PreserveWhitespace = $true
        # 同じ共有文字列でも、参照するセルの字体が違えば結論は変わる。
        # だから覚えるのは (共有文字列, 字体) の組である。
        $sharedFormatCache = @{}
        # inlineStr は共有表を通らないので、同じ文字列でもセルの数だけ書かれる。
        # 覚えないと、そのぶんだけ解き直すことになる（実測 2026-08-16、
        # 20,000行×12列＝240,000セルが全部 inlineStr の rich text で 808,390ms）。
        # 全部ばらばらな資料でこの表が本文と同じ大きさに育たないよう上限を置く。
        $inlineCache = @{}
        $inlineCacheLimit = 20000

        $sheets = New-Object System.Collections.Generic.List[object]
        foreach ($sheetSpec in @(Get-YakuXlsxSheetParts -Archive $zip)) {
            $sheetName = [string]$sheetSpec.Name
            $sheetXml = Get-YakuXlsxPartText -Archive $zip -Name ([string]$sheetSpec.PartName)
            if ([string]::IsNullOrEmpty($sheetXml)) {
                # 本文を読めないシートは、証明のしようが無い。**素通しにしない。**
                try { Write-YakuLog ('Sheet body could not be read; the whole sheet is treated as unproven. sheet=' + $sheetName + ' part=' + [string]$sheetSpec.PartName) 'DEBUG' } catch {}
                $sheets.Add([ordered]@{ name = $sheetName; non_plain_cells = @((New-YakuXlsxSheetScopeNonPlainCell)) }) | Out-Null
                continue
            }

            # --- 速い側の道 ---------------------------------------------------
            # 共有表が1つ残らず平文で、`<is>` が1つも無ければ、このシートの
            # どのセルも文字の書式もふりがなも持てない。`<c>` の子は f / v / is /
            # extLst しか無く、書式もふりがなも `<is>` か共有表にしか置けないので、
            # **これは形の列挙ではなく「置き場所が無い」という証明である。**
            # 要るのは「在るか」だけなので `IsMatch` で問う。`Matches().Count` は
            # 42MB のシートで240,000件を組み上げてから数える（要らない費用）。
            $sheetHasInline = $script:YakuXlsxIsOpenRegex.IsMatch($sheetXml)
            if ([bool]$shared.AllPlain -and -not $sheetHasInline) { continue }

            if ($null -eq $styleMap) {
                $styleMap = Get-YakuXlsxStyleFontMap -Archive $zip
                $fonts = $styleMap.Fonts
                $fontIdByStyle = $styleMap.FontIdByStyle
            }

            $cells = New-Object System.Collections.Generic.List[object]
            $parseFailures = 0
            $unprovenReason = 'cell-shape'
            # 厳密に切り出せた数と、開始タグの数。合わなければ字面の読み方が
            # 当たっていない（引用符の書き方・閉じ忘れ・知らない接頭辞など）。
            # 数えるほうを**先に**捨てる。両方を同時に抱えると、240,000セルの
            # シートで Match の山を2つ持つことになる。
            $cellOpenCount = $script:YakuXlsxCellOpenRegex.Matches($sheetXml).Count
            $cellMatches = $script:YakuXlsxCellRegex.Matches($sheetXml)
            $sheetUnproven = ($cellMatches.Count -ne $cellOpenCount)
            # **この輪はセルの数だけまわる。** PowerShell の関数呼び出しと
            # `$script:` の引き当ては1回あたりでは小さいが、240,000回では効く。
            # 実測（2026-08-16 / 5.1.26100.9168、共有文字列24,000のうち1つだけ
            # rich、240,000セル）: 型の取り出しと平文判定を関数のまま呼ぶと
            # 7,407 / 7,510ms、ここへ畳むと 1,710 / 1,674 / 1,665ms。
            # **判定の中身は1文字も変えていない**（畳んだ先に同じ式を写してある）。
            $typeRegex = $script:YakuXlsxCellTypeRegex
            $valueRegex = $script:YakuXlsxCellValueRegex
            $isOpenRegex = $script:YakuXlsxIsOpenRegex
            $plainTypes = $script:YakuXlsxPlainCellTypes
            $sharedAllPlain = [bool]$shared.AllPlain
            $sharedFlags = $shared.PlainFlags
            $sharedRunFragments = $shared.RunFragments
            if (-not $sheetUnproven) {
                foreach ($cellMatch in $cellMatches) {
                    $attrs = [string]$cellMatch.Groups['attrs'].Value
                    $body = [string]$cellMatch.Groups['body'].Value
                    $type = ''
                    $typeMatch = $typeRegex.Match($attrs)
                    if ($typeMatch.Success) {
                        if ($typeMatch.Groups[1].Success) { $type = [string]$typeMatch.Groups[1].Value }
                        else { $type = [string]$typeMatch.Groups[2].Value }
                    }

                    # --- 平文だと証明できるか。できたセルはここで捨てる --------
                    $sharedIndex = -1
                    $proven = $false
                    if ($type -eq 's') {
                        $valueMatch = $valueRegex.Match($body)
                        if ($valueMatch.Success) {
                            $parsedIndex = 0
                            if ([int]::TryParse(([string]$valueMatch.Groups[1].Value).Trim(), [ref]$parsedIndex)) {
                                $sharedIndex = [int]$parsedIndex
                                # 番号を引けない（表の外・負）ときは証明できない。
                                # **この4行が「共有文字列は平文か」の唯一の判定である。**
                                # 関数へ切り出して呼ぶと 240,000回ぶんの呼び出し費用が
                                # 乗るので畳んである。写しは他所に置かない。
                                if ($sharedAllPlain) { $proven = $true }
                                elseif ($null -ne $sharedFlags -and $sharedIndex -ge 0 -and $sharedIndex -lt $sharedFlags.Length) {
                                    $proven = [bool]$sharedFlags[$sharedIndex]
                                }
                            }
                        }
                    } elseif ($plainTypes -contains $type) {
                        # 型を名乗らずに `<is>` を書く書き手がいるので、入れ物の
                        # 有無でも確かめる。シートに `<is>` が1つも無ければ調べない。
                        $proven = (-not $sheetHasInline) -or (-not $isOpenRegex.IsMatch($body))
                    }
                    if ($proven) { continue }

                    # --- 住所。取れなければ、そのシート全体を証明できない -------
                    $address = [string](Get-YakuXlsxMatchedAttribute -Regex $script:YakuXlsxCellRefRegex -Text $attrs)
                    $rowCol = $null
                    if (-not [string]::IsNullOrEmpty($address)) { $rowCol = ConvertFrom-YakuXlsxCellAddress -Address $address }
                    if ($null -eq $rowCol) { $sheetUnproven = $true; $unprovenReason = 'cell-address'; break }

                    # --- 揃え直しに使う run。読めた範囲でよい -------------------
                    # スタイル番号 -> 字体の引き当ては、共有文字列でも inlineStr でも同じ。
                    $styleId = 0
                    $styleText = [string](Get-YakuXlsxMatchedAttribute -Regex $script:YakuXlsxCellStyleRegex -Text $attrs)
                    if (-not [string]::IsNullOrEmpty($styleText)) {
                        $parsedStyle = 0
                        if ([int]::TryParse($styleText, [ref]$parsedStyle)) { $styleId = [int]$parsedStyle }
                    }
                    $fontId = 0
                    if ($fontIdByStyle.ContainsKey($styleId)) { $fontId = [int]$fontIdByStyle[$styleId] }
                    $cellFont = $null
                    if ($fontId -ge 0 -and $fontId -lt $fonts.Length) { $cellFont = $fonts[$fontId] }

                    $entry = $null
                    if ($type -eq 's') {
                        if ($sharedIndex -ge 0 -and $null -ne $sharedRunFragments -and $sharedRunFragments.ContainsKey($sharedIndex)) {
                            $cacheKey = [string]$sharedIndex + '|' + [string]$fontId
                            if (-not $sharedFormatCache.ContainsKey($cacheKey)) {
                                $sharedFormatCache[$cacheKey] = Resolve-YakuXlsxRichFragmentFormat -Document $fragmentDoc -Fragment ([string]$sharedRunFragments[$sharedIndex]) -CellProperties $cellFont
                            }
                            $entry = $sharedFormatCache[$cacheKey]
                        }
                    } else {
                        # `<c>` と同じ罠。自己終端 `<is/>` を先に試す並びである。
                        $isMatch = $script:YakuXlsxIsRegex.Match($body)
                        if ($isMatch.Success) {
                            $fragment = [string]$isMatch.Value
                            # 同じ中身でも、そのセルの字体が違えば結論は変わる。
                            $inlineKey = [string]$fontId + '|' + $fragment
                            if ($inlineCache.ContainsKey($inlineKey)) { $entry = $inlineCache[$inlineKey] }
                            else {
                                $entry = Resolve-YakuXlsxRichFragmentFormat -Document $fragmentDoc -Fragment $fragment -CellProperties $cellFont
                                if ($inlineCache.Count -lt $inlineCacheLimit) { $inlineCache[$inlineKey] = $entry }
                            }
                        }
                    }

                    $runList = New-Object System.Collections.Generic.List[object]
                    $dominantSignature = ''
                    $dominantProperties = $null
                    $differing = [string[]]@()
                    if ($null -ne $entry) {
                        if ([bool]$entry.Failed) { $parseFailures++ }
                        $format = $entry.Format
                        if ($null -ne $format) {
                            foreach ($item in @($format.Runs)) {
                                $runList.Add([ordered]@{ text = [string]$item.Text; length = [int]$item.Length; signature = [string]$item.Signature }) | Out-Null
                            }
                            $dominantSignature = [string]$format.DominantSignature
                            $dominantProperties = $format.DominantProperties
                            $differing = [string[]]@($format.DifferingProperties)
                        }
                    }
                    $cells.Add([ordered]@{
                        address = $address
                        row = [int]$rowCol.Row
                        col = [int]$rowCol.Col
                        scope = 'cell'
                        runs = $runList.ToArray()
                        dominant_signature = $dominantSignature
                        dominant_properties = $dominantProperties
                        differing_properties = $differing
                    }) | Out-Null
                }
            }
            if ($sheetUnproven) {
                try { Write-YakuLog ('Sheet could not be proven plain; every bulk box on it is dropped. sheet=' + $sheetName + ' reason=' + $unprovenReason) 'DEBUG' } catch {}
                $cells = New-Object System.Collections.Generic.List[object]
                $cells.Add((New-YakuXlsxSheetScopeNonPlainCell)) | Out-Null
            }
            if ($parseFailures -gt 0) {
                try { Write-YakuLog ('Rich text fragments could not be parsed; those cells stay outside the bulk box without levelling. sheet=' + $sheetName + ' cells=' + [string]$parseFailures) 'DEBUG' } catch {}
            }
            if ($cells.Count -le 0) { continue }
            $sheets.Add([ordered]@{ name = $sheetName; non_plain_cells = $cells.ToArray() }) | Out-Null
        }
        return $sheets.ToArray()
    } catch {
        try { Write-YakuLog ('Non-plain cell read failed; writeback keeps its previous behaviour. reason=' + $_.Exception.Message) 'DEBUG' } catch {}
        return @()
    } finally {
        if ($null -ne $zip) { try { $zip.Dispose() } catch {} }
    }
}
