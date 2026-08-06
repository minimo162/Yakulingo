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
        [int]$MaxJoin = 12
    )
    $list = @($Cells | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Text) })
    if ($list.Count -eq 0) { return @() }

    # その行に埋まったセルがいくつあるか。1つだけなら「行に単独で置かれた文字」。
    $rowCount = @{}
    foreach ($c in $list) {
        $r = [int]$c.Row
        if (-not $rowCount.ContainsKey($r)) { $rowCount[$r] = 0 }
        $rowCount[$r]++
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
            $bothAlone  = (([int]$rowCount[[int]$prev.Row] -eq 1) -and ([int]$rowCount[[int]$c.Row] -eq 1))
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
