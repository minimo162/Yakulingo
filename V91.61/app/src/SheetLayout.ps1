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
            foreach ($col in [regex]::Matches($sheetXml, '<col\b[^>]*/?>')) {
                $min = [regex]::Match($col.Value, 'min="(\d+)"'); $max = [regex]::Match($col.Value, 'max="(\d+)"')
                $width = [regex]::Match($col.Value, 'width="([0-9.]+)"')
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
                $align = [string]$alignByStyle[$style]
                $bold = [bool]$boldByStyle[$style]
                if (-not $wrap -and -not $bold -and [string]::IsNullOrEmpty($align)) { continue }
                [void]$cells.Add([ordered]@{ address = [string]$cell.Groups[1].Value; wrap = $wrap; align = $align; bold = $bold })
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

function Get-YakuXlsxRunCells {
    <#
      .SYNOPSIS
        xlsx から、**見た目に差のある run を持つセルだけ**をシートごとに返す。

      .DESCRIPTION
        Office は使わない。ZIP と XML だけで読む。読めなければ空を返す
        （体裁は足しであって前提ではない。読めなくても書き戻しは今までどおり進む）。

        見るのは共有文字列（`xl/sharedStrings.xml`）の `<si><r><rPr>` だけである。
        セルの中へ直に書く形（`t="inlineStr"`）は今は見ていない。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    # 利用者が原本を Excel で開いたままでも読む。ここが読めないと、守りだけが
    # 黙って外れる（書き出しそのものは Copy-Item で通ってしまうため）。
    $zip = Open-YakuXlsxArchiveForRead -Path $Path
    if ($null -eq $zip) { return @() }
    try {
        $sharedXml = Get-YakuXlsxPartText -Archive $zip -Name 'xl/sharedStrings.xml'
        if ([string]::IsNullOrWhiteSpace($sharedXml)) { return @() }
        # 見た目が食い違うには rPr が最低1つ要る（rPr の無い run どうしは必ず同じ）。
        # 1つも無ければ DOM を組まずに帰る。共有表は大きな資料だと数十MBになるので、
        # 部分書式を1つも持たないブックにその費用を払わせない。
        # 探すのは接頭辞を含まない `rPr` なので、名前空間の書き方に左右されない。
        if ($sharedXml.IndexOf('rPr') -lt 0) { return @() }

        # --- 共有文字列: si 番号 -> run（本文と、rPr に書かれている項目） ---------
        $rawRunsByIndex = @{}
        $sharedDoc = New-Object Xml.XmlDocument
        $sharedDoc.PreserveWhitespace = $true
        $sharedDoc.LoadXml($sharedXml)
        $siIndex = -1
        foreach ($si in @($sharedDoc.SelectNodes("//*[local-name()='si']"))) {
            $siIndex++
            $runs = New-Object System.Collections.Generic.List[object]
            foreach ($child in $si.ChildNodes) {
                # `<rPh>`（ふりがな）も `<t>` を持つが run ではない。直下の `<r>` だけを取る。
                if ([string]$child.LocalName -ne 'r') { continue }
                $runProperties = $null
                $text = ''
                foreach ($grandChild in $child.ChildNodes) {
                    if ([string]$grandChild.LocalName -eq 'rPr') { $runProperties = Get-YakuXlsxFontVisibleProperties -Node $grandChild }
                    elseif ([string]$grandChild.LocalName -eq 't') { $text = [string]$grandChild.InnerText }
                }
                $runs.Add([pscustomobject]@{ Text = [string]$text; Properties = $runProperties }) | Out-Null
            }
            # run が1つなら、そのセルの中で書式が変わりようがない。
            if ($runs.Count -lt 2) { continue }
            $rawRunsByIndex[$siIndex] = $runs.ToArray()
        }
        if ($rawRunsByIndex.Count -le 0) { return @() }

        # --- styles.xml: スタイル番号 -> fontId -> そのセルの字体 -----------------
        $fontProperties = New-Object System.Collections.Generic.List[object]
        $fontIdByStyle = @{}
        $stylesXml = Get-YakuXlsxPartText -Archive $zip -Name 'xl/styles.xml'
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
        $fonts = $fontProperties.ToArray()

        $resolvedCache = @{}
        $sheets = New-Object System.Collections.Generic.List[object]
        foreach ($sheetSpec in @(Get-YakuXlsxSheetParts -Archive $zip)) {
            $sheetXml = Get-YakuXlsxPartText -Archive $zip -Name ([string]$sheetSpec.PartName)
            if (-not $sheetXml) { continue }

            $runCells = New-Object System.Collections.Generic.List[object]
            # 自己終端の形を**先に**置く。中身を持つ形を先に試すと `<c r="B6" s="9"/>` を飲み、
            # `.*?</c>` が**次のセルの中身を盗む**。盗まれた側は走査から消え、盗んだ側は
            # 別のセルの共有文字列番号を名乗る。住所そのものがずれるので、件数では気づけない。
            foreach ($cellNode in [regex]::Matches($sheetXml, '(?s)<c\b[^>]*/>|<c\b[^>]*>.*?</c>')) {
                $element = [string]$cellNode.Value
                if ($element -notmatch '\bt="s"') { continue }
                $addressMatch = [regex]::Match($element, '\br="([A-Z]+\d+)"')
                if (-not $addressMatch.Success) { continue }
                $valueMatch = [regex]::Match($element, '(?s)<v[^>]*>(.*?)</v>')
                if (-not $valueMatch.Success) { continue }
                $index = -1
                if (-not [int]::TryParse(([string]$valueMatch.Groups[1].Value).Trim(), [ref]$index)) { continue }
                if (-not $rawRunsByIndex.ContainsKey($index)) { continue }

                $styleId = 0
                $styleMatch = [regex]::Match($element, '\bs="(\d+)"')
                if ($styleMatch.Success) { $styleId = [int]$styleMatch.Groups[1].Value }
                $fontId = 0
                if ($fontIdByStyle.ContainsKey($styleId)) { $fontId = [int]$fontIdByStyle[$styleId] }

                # 同じ共有文字列でも、参照するセルの字体が違えば結論は変わる。
                # だから覚えるのは (共有文字列, 字体) の組である。
                $cacheKey = [string]$index + '|' + [string]$fontId
                if (-not $resolvedCache.ContainsKey($cacheKey)) {
                    $cellFont = $null
                    if ($fontId -ge 0 -and $fontId -lt $fonts.Length) { $cellFont = $fonts[$fontId] }
                    $resolvedCache[$cacheKey] = New-YakuXlsxRunCellFormat -Runs $rawRunsByIndex[$index] -CellProperties $cellFont
                }
                $format = $resolvedCache[$cacheKey]
                if ($null -eq $format) { continue }

                $address = [string]$addressMatch.Groups[1].Value
                $rowCol = ConvertFrom-YakuXlsxCellAddress -Address $address
                if ($null -eq $rowCol) { continue }
                $runList = New-Object System.Collections.Generic.List[object]
                foreach ($item in @($format.Runs)) {
                    $runList.Add([ordered]@{ text = [string]$item.Text; length = [int]$item.Length; signature = [string]$item.Signature }) | Out-Null
                }
                $runCells.Add([ordered]@{
                    address = $address
                    row = [int]$rowCol.Row
                    col = [int]$rowCol.Col
                    runs = $runList.ToArray()
                    dominant_signature = [string]$format.DominantSignature
                    dominant_properties = $format.DominantProperties
                    differing_properties = [string[]]@($format.DifferingProperties)
                }) | Out-Null
            }
            if ($runCells.Count -le 0) { continue }
            $sheets.Add([ordered]@{ name = [string]$sheetSpec.Name; run_cells = $runCells.ToArray() }) | Out-Null
        }
        return $sheets.ToArray()
    } catch {
        try { Write-YakuLog ('Rich text run read failed; writeback keeps its previous behaviour. reason=' + $_.Exception.Message) 'DEBUG' } catch {}
        return @()
    } finally {
        if ($null -ne $zip) { try { $zip.Dispose() } catch {} }
    }
}
