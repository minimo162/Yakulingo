<#
  セルではなくセグメントで訳せるようにする。続いているセルを繋ぎ、
  訳したあと元のセルへ戻す。

  なぜ要るのか:

    ファイル翻訳の精度が低い原因は、用語集でもプロンプトでもなく、
    **入力の切り方**にある（利用者の診断 2026-08-06）。

      体裁のために、1つの長い文を複数のセルに分けて入力している。
      セルごとに訳すと、文の途中で切れた断片をそれぞれ訳すことになり、
      訳が崩壊する。しかも出来上がった Excel は一見良さげに見えるので、
      崩壊に気づけず、あとの修正作業が増える。

    これは ECM 固有の話ではない。体裁のために文をセルへ割るのは
    日本の社内資料に普遍的で、直せば汎用の直しになる。

  繋ぐ判定は完璧でなくてよい:

    以前「表と散文を綺麗に分類できるか」を実測し、当てにならないと
    結論した。あれは分類が自動で、しかも人に見えないところで効いていた
    ためである。ここでは繋いだ結果をグリッドに出して人が直せるので、
    外れても取り返しがつく。**見えるなら、外れてよい。**

  何を手掛かりにするか:

    「散文か表か」ではなく、目に見える事実だけを使う。

      - 同じ列で、行が連続していること
      - その行に、他の埋まったセルが無いこと
        （他に数値が並んでいれば、それは表の行であって文章ではない）
      - 前のセルが句点で終わっていないこと
        （終わっていれば、そこで文が閉じている）
      - 次のセルが箇条書きの印で始まっていないこと

    どれも「文章らしさ」の推測ではなく、その場で確かめられる事実である。

  戻し方:

    訳文を元のセルの数に割り振る。割り振りの重みは元のセルの長さにする。
    元の長さは、そこに入る見た目の幅を表しているためである。
    切る位置は語の切れ目に寄せる。英語を語の途中で切ると読めなくなる。
#>

# 文が閉じたとみなす字。閉じ括弧が後ろに付く場合も見る（「…です。」）。
$script:YakuSentenceEndPattern = '[。．！？!?]\s*[」』）\)”"]*\s*$'
# 箇条書きの印。ここで始まるセルは前と繋がない。
$script:YakuBulletStartPattern = '^\s*([・･\-–—\*●○■◆①-⑳]|\(?[0-9０-９]{1,2}[\.\)．）]|[（\(][0-9０-９]{1,2}[）\)])\s*'

function Test-YakuCellEndsSentence {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace([string]$Text)) { return $true }
    return ([string]$Text -match $script:YakuSentenceEndPattern)
}

function Test-YakuCellStartsNewItem {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace([string]$Text)) { return $true }
    return ([string]$Text -match $script:YakuBulletStartPattern)
}

function New-YakuSegmentCell {
    param(
        [Parameter(Mandatory=$true)][int]$Row,
        [Parameter(Mandatory=$true)][int]$Column,
        [AllowNull()][string]$Text,
        [bool]$IsText = $true
    )
    return [pscustomobject]@{
        Row = [int]$Row; Column = [int]$Column
        Text = [string]$Text; IsText = [bool]$IsText
    }
}

function Group-YakuCellsIntoSegments {
    <#
      セルの一覧を、訳す単位（セグメント）へまとめる。

      繋ぐのは、同じ列で行が連続し、どちらの行にも他の埋まったセルが無く、
      前のセルが句点で終わっていない場合だけ。それ以外は1セル1セグメント。

      MaxJoin を超えて繋がない。判定を外したときに、シート全体が
      1つのセグメントになるのを防ぐ歯止めである。
    #>
    param(
        [AllowNull()][object[]]$Cells,
        [int]$MaxJoin = 12,
        # 行に埋まったセルがいくつあるか（行番号→件数）。
        # **翻訳対象のセルだけを数えてはいけない。** 数値セルは抽出されないので、
        # 「営業利益 | 1,234」の行が「1つだけ」に見え、次の行と繋いでしまう。
        # 渡されなければ手元のセルから数えるが、それは近似でしかない。
        [AllowNull()][hashtable]$RowOccupancy
    )
    $list = @($Cells | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Text) })
    if ($list.Count -eq 0) { return @() }

    # その行に埋まったセルがいくつあるか。1つだけなら「行に単独で置かれた文字」。
    $rowCount = @{}
    if ($null -ne $RowOccupancy -and $RowOccupancy.Count -gt 0) {
        $rowCount = $RowOccupancy
    } else {
        foreach ($c in $list) {
            $r = [int]$c.Row
            if (-not $rowCount.ContainsKey($r)) { $rowCount[$r] = 0 }
            $rowCount[$r]++
        }
    }

    $segments = New-Object System.Collections.Generic.List[object]
    $ordered = @($list | Sort-Object -Property @{Expression={[int]$_.Column}}, @{Expression={[int]$_.Row}})
    $current = New-Object System.Collections.Generic.List[object]

    function Flush {
        param($Buffer, $Sink)
        if ($Buffer.Count -eq 0) { return }
        $cells = @($Buffer.ToArray())
        # 日本語は詰めて繋ぐ。英語は空白で繋ぐ。
        $joiner = if ((@($cells | ForEach-Object { [string]$_.Text }) -join '') -match '[぀-ヿ一-鿿]') { '' } else { ' ' }
        [void]$Sink.Add([pscustomobject]@{
            Text   = (@($cells | ForEach-Object { ([string]$_.Text).Trim() }) -join $joiner)
            Cells  = $cells
            Joined = ($cells.Count -gt 1)
        })
    }

    $prev = $null
    foreach ($c in $ordered) {
        $join = $false
        if ($null -ne $prev -and $current.Count -gt 0 -and $current.Count -lt $MaxJoin) {
            $sameColumn = ([int]$c.Column -eq [int]$prev.Column)
            $nextRow    = ([int]$c.Row -eq ([int]$prev.Row + 1))
                $prevAlone  = ($rowCount.ContainsKey([int]$prev.Row) -and ([int]$rowCount[[int]$prev.Row] -eq 1))
            $curAlone   = ($rowCount.ContainsKey([int]$c.Row) -and ([int]$rowCount[[int]$c.Row] -eq 1))
            $bothAlone  = ($prevAlone -and $curAlone)
            $bothText   = ([bool]$prev.IsText -and [bool]$c.IsText)
            $open       = (-not (Test-YakuCellEndsSentence -Text ([string]$prev.Text)))
            $notNewItem = (-not (Test-YakuCellStartsNewItem -Text ([string]$c.Text)))
            $join = ($sameColumn -and $nextRow -and $bothAlone -and $bothText -and $open -and $notNewItem)
        }
        if (-not $join) { Flush -Buffer $current -Sink $segments; $current = New-Object System.Collections.Generic.List[object] }
        [void]$current.Add($c)
        $prev = $c
    }
    Flush -Buffer $current -Sink $segments
    return @($segments.ToArray())
}

function Get-YakuExcelRowOccupancy {
    <#
      シートごとに、各行がいくつのセルで埋まっているかを数える。

      翻訳対象のセルだけを数えては**いけない**。数値セルは抽出されないので、
      「営業利益 | 1,234」の行が「1つだけ埋まっている」ように見え、
      次の行の文字と繋いでしまう。表の行を文章として繋ぐのは最悪の外し方
      なので、ここは実際のシートから数える。

      返すのは シート名 → @{ 行番号 = 件数 }。
    #>
    param(
        [Parameter(Mandatory=$true)]$Workbook,
        [int]$MaxCellsPerSheet = 200000
    )
    $out = @{}
    foreach ($ws in $Workbook.Worksheets) {
        $name = ''
        try { $name = [string]$ws.Name } catch { $name = '' }
        if ([string]::IsNullOrWhiteSpace($name)) { Release-YakuComObject $ws; continue }
        $rows = @{}
        $used = $null
        try { $used = $ws.UsedRange } catch { $used = $null }
        if ($null -ne $used) {
            try {
                $rowCount = [int]$used.Rows.Count
                $colCount = [int]$used.Columns.Count
                $firstRow = [int]$used.Row
                if (($rowCount * $colCount) -le $MaxCellsPerSheet) {
                    $values = $used.Value2
                    for ($rr = 1; $rr -le $rowCount; $rr++) {
                        $n = 0
                        for ($cc = 1; $cc -le $colCount; $cc++) {
                            $v = Get-YakuRangeArrayValue -Values $values -RowOffset $rr -ColOffset $cc
                            if ($null -eq $v) { continue }
                            if ([string]::IsNullOrWhiteSpace([string]$v)) { continue }
                            $n++
                        }
                        if ($n -gt 0) { $rows[($firstRow + $rr - 1)] = $n }
                    }
                }
            } catch {}
            Release-YakuComObject $used
        }
        Release-YakuComObject $ws
        $out[$name] = $rows
    }
    return $out
}

function Group-YakuTextBlocksIntoSegments {
    <#
      抽出した文字の塊（Get-YakuExcelTextBlocks の出力）を、訳す単位へまとめる。

      セルの塊だけをシートごとに繋ぐ。図形・グラフ・コメントは1つずつ訳す。
      図形は位置で並ぶので、行優先の並びに混ぜると順序が壊れるためである。

      返すセグメントは BlockIds を持つ。訳したあと、これで元の塊へ戻す。
    #>
    param(
        [AllowNull()][object[]]$Blocks,
        [AllowNull()][hashtable]$RowOccupancy,
        [int]$MaxJoin = 12
    )
    $all = @($Blocks | Where-Object { $null -ne $_ })
    $segments = New-Object System.Collections.Generic.List[object]
    $cellsBySheet = @{}
    $blockById = @{}

    foreach ($b in $all) {
        $blockById[[string]$b.Id] = $b
        $kind = ''
        try { $kind = [string]$b.Meta.Kind } catch { $kind = '' }
        if ($kind -ne 'cell') {
            [void]$segments.Add([pscustomobject]@{
                Text     = [string]$b.Text
                BlockIds = @([string]$b.Id)
                Cells    = @()
                Joined   = $false
                Kind     = $(if ([string]::IsNullOrWhiteSpace($kind)) { 'other' } else { $kind })
                Location = [string]$b.Location
            })
            continue
        }
        $sheet = [string]$b.Meta.Sheet
        if (-not $cellsBySheet.ContainsKey($sheet)) { $cellsBySheet[$sheet] = New-Object System.Collections.Generic.List[object] }
        $entry = New-YakuSegmentCell -Row ([int]$b.Meta.Row) -Column ([int]$b.Meta.Col) -Text ([string]$b.Text) -IsText $true
        $entry | Add-Member -NotePropertyName 'BlockId' -NotePropertyValue ([string]$b.Id) -Force
        [void]$cellsBySheet[$sheet].Add($entry)
    }

    foreach ($sheet in @($cellsBySheet.Keys)) {
        $occ = $null
        if ($null -ne $RowOccupancy -and $RowOccupancy.ContainsKey($sheet)) { $occ = $RowOccupancy[$sheet] }
        foreach ($s in @(Group-YakuCellsIntoSegments -Cells @($cellsBySheet[$sheet].ToArray()) -MaxJoin $MaxJoin -RowOccupancy $occ)) {
            $cells = @($s.Cells)
            [void]$segments.Add([pscustomobject]@{
                Text     = [string]$s.Text
                BlockIds = @($cells | ForEach-Object { [string]$_.BlockId })
                Cells    = $cells
                Joined   = [bool]$s.Joined
                Kind     = 'cell'
                Location = ($sheet + ', ' + (@($cells | ForEach-Object { [string]$_.BlockId }) -join '+'))
            })
        }
    }
    return @($segments.ToArray())
}

function Get-YakuSegmentTranslationByBlockId {
    <#
      セグメントの訳文を、元の塊ごとの訳文へ割り戻す。
      返すのは Write-YakuExcelTranslations がそのまま受け取れる形。

      繋いだセグメントは、元のセルの長さを重みにして割り振る。
      繋いでいないものは1対1。
    #>
    param(
        [AllowNull()][object[]]$Segments,
        [Parameter(Mandatory=$true)][hashtable]$TranslationBySegmentIndex
    )
    $map = @{}
    $segs = @($Segments)
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not $TranslationBySegmentIndex.ContainsKey($i)) { continue }
        $translation = [string]$TranslationBySegmentIndex[$i]
        $ids = @($segs[$i].BlockIds)
        if ($ids.Count -eq 0) { continue }
        if ($ids.Count -eq 1) { $map[[string]$ids[0]] = $translation; continue }
        $cells = @($segs[$i].Cells)
        $weights = @($cells | ForEach-Object { [Math]::Max(1, ([string]$_.Text).Trim().Length) })
        $parts = @(Split-YakuTextAcrossCells -Text $translation -Weights $weights)
        for ($k = 0; $k -lt $ids.Count; $k++) {
            $map[[string]$ids[$k]] = $(if ($k -lt $parts.Count) { [string]$parts[$k] } else { '' })
        }
    }
    return $map
}

function Find-YakuBreakPosition {
    <#
      おおよそ Near の位置で、語を割らずに切れる場所を返す。

      英語は空白で切る。語の途中で切ると読めなくなる。
      空白が無い文（日本語）は、読点・句点の後ろを優先し、無ければ
      その位置でそのまま切る。日本語は語の間に印が無いので、
      これ以上のことは元の入力からは分からない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][int]$Near,
        [int]$Min = 1
    )
    $n = [int]$Text.Length
    if ($Near -ge $n) { return $n }
    if ($Near -lt $Min) { $Near = $Min }
    $hasSpace = ($Text -match '\s')
    if ($hasSpace) {
        # Near 以下でいちばん近い空白。無ければ Near より後ろのいちばん近い空白。
        for ($i = $Near; $i -ge $Min; $i--) { if ([char]::IsWhiteSpace($Text[$i - 1])) { return $i } }
        for ($i = $Near + 1; $i -lt $n; $i++) { if ([char]::IsWhiteSpace($Text[$i - 1])) { return $i } }
        return $n
    }
    # 読点・句点の直後を探す。前後どちらも同じだけ見る。
    for ($d = 0; $d -le 6; $d++) {
        # カンマは引き算より強く結び付くので、括弧で囲む。
        # @($Near - $d, $Near + $d) は $Near - ($d, $Near) + $d と読まれる。
        foreach ($p in @(($Near - $d), ($Near + $d))) {
            if ($p -lt $Min -or $p -ge $n) { continue }
            if ([string]$Text[$p - 1] -match '[、。，．]') { return $p }
        }
    }
    return $Near
}

function Split-YakuTextAcrossCells {
    <#
      訳文を、元のセルの数へ割り振る。

      重みは元のセルの長さ。そこに入る見た目の幅を表しているためである。
      重みが取れない場合は等分にする。
      訳文が短くてセルが余ったら、余ったセルは空文字を返す。
      元の文字を残すと、日本語と英語が混ざった表になる。
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][int[]]$Weights
    )
    $t = [string]$Text
    $w = @($Weights)
    if ($w.Count -eq 0) { return @() }
    if ($w.Count -eq 1) { return @($t) }
    if ([string]::IsNullOrEmpty($t)) { return @(@(1..$w.Count) | ForEach-Object { '' }) }

    $total = 0
    foreach ($x in $w) { $total += [Math]::Max(1, [int]$x) }
    $out = New-Object System.Collections.Generic.List[string]
    $pos = 0
    $cum = 0
    for ($i = 0; $i -lt ($w.Count - 1); $i++) {
        $cum += [Math]::Max(1, [int]$w[$i])
        $target = [int][Math]::Round(($t.Length * $cum) / $total)
        if ($target -le $pos) { $target = $pos }
        $cut = Find-YakuBreakPosition -Text $t -Near $target -Min ($pos + 1)
        if ($cut -lt $pos) { $cut = $pos }
        if ($cut -gt $t.Length) { $cut = $t.Length }
        [void]$out.Add($t.Substring($pos, $cut - $pos).Trim())
        $pos = $cut
    }
    [void]$out.Add($t.Substring($pos).Trim())
    return @($out.ToArray())
}

function Get-YakuSegmentWriteBack {
    <#
      セグメント1つ分の訳文を、元のセルへ戻す形にして返す。
      返るのは @{ Row; Column; Text } の並び。書き込みは呼び出し側で行う。

      繋いでいないセグメントはそのまま1対1。繋いだものだけ割り振る。
    #>
    param(
        [Parameter(Mandatory=$true)]$Segment,
        [AllowNull()][string]$Translation
    )
    $cells = @($Segment.Cells)
    if ($cells.Count -eq 0) { return @() }
    if ($cells.Count -eq 1) {
        return @([pscustomobject]@{ Row = [int]$cells[0].Row; Column = [int]$cells[0].Column; Text = [string]$Translation })
    }
    $weights = @($cells | ForEach-Object { [Math]::Max(1, ([string]$_.Text).Trim().Length) })
    $parts = @(Split-YakuTextAcrossCells -Text $Translation -Weights $weights)
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $cells.Count; $i++) {
        $text = if ($i -lt $parts.Count) { [string]$parts[$i] } else { '' }
        [void]$out.Add([pscustomobject]@{ Row = [int]$cells[$i].Row; Column = [int]$cells[$i].Column; Text = $text })
    }
    return @($out.ToArray())
}
