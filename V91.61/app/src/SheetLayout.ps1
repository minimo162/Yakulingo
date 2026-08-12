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
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = $null
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($Path) } catch { return @() }
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

        $workbookXml = Read-YakuZipText -Archive $zip -Name 'xl/workbook.xml'
        $names = @()
        foreach ($sheet in [regex]::Matches($workbookXml, '<sheet\b[^>]*name="([^"]*)"')) { $names += $sheet.Groups[1].Value }

        $sheets = New-Object System.Collections.Generic.List[object]
        $ordinal = 0
        foreach ($name in $names) {
            $ordinal++
            $sheetXml = Read-YakuZipText -Archive $zip -Name ('xl/worksheets/sheet' + $ordinal + '.xml')
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
