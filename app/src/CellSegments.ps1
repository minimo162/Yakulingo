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
        [bool]$IsText = $true,
        [bool]$IsMerged = $false
    )
    return [pscustomobject]@{
        Row = [int]$Row; Column = [int]$Column
        Text = [string]$Text; IsText = [bool]$IsText; IsMerged = [bool]$IsMerged
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
            # 結合セルは見出しやサブタイトルとして独立して置かれることが多い。
            # 別々の結合行を自動で繋ぐと、訳文を文字数で再分配してレイアウトも意味も崩れる。
            $neitherMerged = (-not [bool]$prev.IsMerged -and -not [bool]$c.IsMerged)
            $open       = (-not (Test-YakuCellEndsSentence -Text ([string]$prev.Text)))
            $notNewItem = (-not (Test-YakuCellStartsNewItem -Text ([string]$c.Text)))
            $join = ($sameColumn -and $nextRow -and $bothAlone -and $bothText -and $neitherMerged -and $open -and $notNewItem)
        }
        if (-not $join) { Flush -Buffer $current -Sink $segments; $current = New-Object System.Collections.Generic.List[object] }
        [void]$current.Add($c)
        $prev = $c
    }
    Flush -Buffer $current -Sink $segments
    return @($segments.ToArray())
}

function Split-YakuTextIntoSegments {
    <#
      貼り付けたテキストを、訳す単位へ分ける。

      なぜ要るのか:

        簡易翻訳を使っている人に CAT のほうが便利でも、急に画面が変わると
        覚え直しの負担を負わせることになる（利用者の懸念 2026-08-06）。
        入力の作法を揃えるのが橋渡しになる。**貼って押す**が両方で同じなら、
        変わるのは出口だけになり、覚えることが1つで済む。

        ファイルを開く経路と、貼り付ける経路の両方を用意する話は、
        以前から挙がっていた（利用者の希望 2026-08-06）。

      分け方:

        まず行で切る。見出しや箇条書きは1行が1つの単位である。
        次に行の中を句点で切る。文ごとに見比べたいのが CAT の目的なので、
        1文が既定の単位になる。

        分け方が外れても、グリッドで結合・解除できる。ここでも
        「当てる」ではなく「直せる」を前提に置く。
    #>
    param([AllowNull()][string]$Text)
    $t = [string]$Text
    if ([string]::IsNullOrWhiteSpace($t)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($t -split "`r?`n")) {
        $l = [string]$line
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        # 句点・感嘆符・疑問符の後ろで切る。閉じ括弧が続く場合はそこまで含める。
        # 英語は終止符の後に空白と大文字が続くときだけ切る。小数点や Inc. で切らない。
        $parts = [regex]::Split($l, '(?<=[。！？][」』）\)”"]?)(?!\s*$)|(?<=[.!?][”"]?)\s+(?=[A-Z])')
        foreach ($p in $parts) {
            $s = [string]$p
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            [void]$out.Add($s.Trim())
        }
    }
    return @($out.ToArray())
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
    $otherBySheet = @{}
    # シートの出てくる順。ブックの並びのまま一覧へ出すため。
    # 並びが読み順でないと、隣どうしを繋ぐ操作が意味を持たなくなる。
    $sheetOrder = New-Object System.Collections.Generic.List[string]

    foreach ($b in $all) {
        $kind = ''
        try { $kind = [string]$b.Meta.Kind } catch { $kind = '' }
        $sheet = ''
        try { $sheet = [string]$b.Meta.Sheet } catch { $sheet = '' }
        if (-not $sheetOrder.Contains($sheet)) { [void]$sheetOrder.Add($sheet) }
        if ($kind -ne 'cell') {
            if (-not $otherBySheet.ContainsKey($sheet)) { $otherBySheet[$sheet] = New-Object System.Collections.Generic.List[object] }
            [void]$otherBySheet[$sheet].Add([pscustomobject]@{
                Text     = [string]$b.Text
                BlockIds = @([string]$b.Id)
                Cells    = @()
                Joined   = $false
                Kind     = $(if ([string]::IsNullOrWhiteSpace($kind)) { 'other' } else { $kind })
                Sheet    = $sheet
                Location = [string]$b.Location
            })
            continue
        }
        if (-not $cellsBySheet.ContainsKey($sheet)) { $cellsBySheet[$sheet] = New-Object System.Collections.Generic.List[object] }
        $isMerged = $false
        try { $isMerged = [bool]$b.Meta.Merged } catch { $isMerged = $false }
        $entry = New-YakuSegmentCell -Row ([int]$b.Meta.Row) -Column ([int]$b.Meta.Col) -Text ([string]$b.Text) -IsText $true -IsMerged $isMerged
        $entry | Add-Member -NotePropertyName 'BlockId' -NotePropertyValue ([string]$b.Id) -Force
        # A1 番地。どのセルを繋いだかを画面で見せるために持つ。
        $a1 = ''
        try { $a1 = [string]$b.Meta.A1 } catch { $a1 = '' }
        $entry | Add-Member -NotePropertyName 'Address' -NotePropertyValue $a1 -Force
        try { $entry | Add-Member -NotePropertyName 'SheetCodeName' -NotePropertyValue ([string]$b.Meta.SheetCodeName) -Force } catch {}
        try { $entry | Add-Member -NotePropertyName 'StructureContract' -NotePropertyValue $b.Meta.StructureContract -Force } catch {}
        try { $entry | Add-Member -NotePropertyName 'StructureFingerprint' -NotePropertyValue ([string]$b.Meta.StructureFingerprint) -Force } catch {}
        [void]$cellsBySheet[$sheet].Add($entry)
    }

    foreach ($sheet in $sheetOrder) {
        if ($cellsBySheet.ContainsKey($sheet)) {
            $occ = $null
            if ($null -ne $RowOccupancy -and $RowOccupancy.ContainsKey($sheet)) { $occ = $RowOccupancy[$sheet] }
            foreach ($s in @(Group-YakuCellsIntoSegments -Cells @($cellsBySheet[$sheet].ToArray()) -MaxJoin $MaxJoin -RowOccupancy $occ)) {
                [void]$segments.Add((New-YakuCellSegment -Sheet $sheet -Cells @($s.Cells) -Joined ([bool]$s.Joined)))
            }
        }
        # 図形・グラフはシートのセルの後ろへ置く。位置で並ぶので、
        # 行優先の並びの中へ差し込むと順序が入れ替わる。
        if ($otherBySheet.ContainsKey($sheet)) {
            foreach ($o in @($otherBySheet[$sheet].ToArray())) { [void]$segments.Add($o) }
        }
    }
    return @($segments.ToArray())
}

function New-YakuCellSegment {
    <#
      セルの並びからセグメントを1つ作る。繋ぎ直したあとにも使う。
      本文の繋ぎ方（日本語は詰める・英語は空白）を1か所に集めておく。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Sheet,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Cells,
        [bool]$Joined
    )
    $list = @($Cells)
    $joiner = if ((@($list | ForEach-Object { [string]$_.Text }) -join '') -match '[぀-ヿ一-鿿]') { '' } else { ' ' }
    $addresses = @($list | ForEach-Object { [string]$_.Address })
    if (@($addresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
        $addresses = @($list | ForEach-Object { 'R' + [string]$_.Row + 'C' + [string]$_.Column })
    }
    return [pscustomobject]@{
        Text     = (@($list | ForEach-Object { ([string]$_.Text).Trim() }) -join $joiner)
        BlockIds = @($list | ForEach-Object { [string]$_.BlockId })
        Cells    = $list
        Joined   = $(if ($PSBoundParameters.ContainsKey('Joined')) { [bool]$Joined } else { $list.Count -gt 1 })
        Kind     = 'cell'
        Sheet    = [string]$Sheet
        Location = ([string]$Sheet + ', ' + (@($addresses) -join '+'))
    }
}

function Get-YakuCatSegmentSplitGroupId {
    <#
      任意位置で割った行が持つ「組」の目印を返す。持っていなければ空。

      古い作業には項目そのものが無いので、必ず try で受ける。
      ここを1か所にしておかないと、Excel・Word・貼り付け本文の各出口で
      別々の判定が生えて、片方だけ直り忘れる。
    #>
    param([Parameter(Mandatory=$true)]$Segment)
    $value = ''
    try { $value = [string]$Segment.SplitGroupId } catch { $value = '' }
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    return $value
}

function Test-YakuCatSplitPositionInsideToken {
    <#
      原文のこの位置は、単語・数字・記号列の「内側」か。

      なぜ要るか（2026-08-15 の欠陥）:
        原文 `型式はAB-1234を採用します。` を位置6（`-` と `1` の間）で割ると、
        書き戻しで訳文が `The model is AB- 1234 will be adopted.` になり、
        トークンの内側へ空白が1つ入る。数字 1234 は1桁も欠けないので
        数値QCに掛からず、割った後は片側ずつしか点検しないので原理的に
        見えない。Get-YakuCatOutputEligibility も止めない。つまり利用者に
        見えないまま資料が壊れる。

      判定は「原文の境目に空白があったか」ではやってはいけない。日本語の
      原文にはどこにも空白が無いので、それだと to_en が常に詰めになり、
      節で割った普通の文（`…見直しました。` ＋ `調達費も…`）まで
      `system.We also…` と繋がってしまう。見るのは境目の両隣の字種である。

      規則（この1か所だけが持つ。写経しないこと）:
        1. 位置が範囲の外、または原文が1文字以下 → 内側ではない（別の門が弾く）
        2. サロゲートペアの真ん中 → 内側。1文字を半分に割るので無条件に守る
        3. どちらかが空白 → 内側ではない（原文がそこで切れている）
        4. どちらかが CJK（漢字・かな・全角の句読点・半角カナ） → 内側ではない。
           日本語の文の切れ目なので、訳文どうしは空白1つで繋ぐのが正しい
        5. 少なくとも一方が英数字 → 内側。`AB-|1234` `3.|14` `1,|234` `100|km`
           `2026-08|-15` `example.com/|a` が全部これに入る。全角英数
           （`ＡＢ－|１２３４`）も IsLetterOrDigit が真なので同じ扱いになる
        6. それ以外（記号どうし、例 `..|.`） → 内側ではない。空白を1つ入れる側へ
           倒す。ここを「内側」に倒すと、記号で終わる文の切れ目まで詰まる

      5 は `system.|We`（空白の無い文末）も「内側」と見なす。これは承知の
      うえで受ける。`example.com` `3.14` を守るほうを採ると、`.` の左右だけ
      では両者を区別できないからである。しかも原文が Latin で訳文も Latin に
      なる場面は、この道具（to_en / to_jp）ではまず起きない。to_jp では
      繋ぎ文字がそもそも '' である。
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory=$true)][int]$Position
    )
    $s = [string]$Text
    if ($s.Length -lt 2) { return $false }
    if ($Position -le 0 -or $Position -ge $s.Length) { return $false }
    $left = $s[$Position - 1]
    $right = $s[$Position]
    if ([char]::IsHighSurrogate($left) -and [char]::IsLowSurrogate($right)) { return $true }
    if ([char]::IsWhiteSpace($left) -or [char]::IsWhiteSpace($right)) { return $false }
    # CJK の範囲。全角英数（U+FF01..U+FF60）は入れない。`ＡＢ－１２３４` を
    # トークンとして守るためである。半角カナ（U+FF61..U+FF9F）は日本語なので入れる。
    $isCjk = {
        param([char]$c)
        $code = [int]$c
        return (($code -ge 0x3000 -and $code -le 0x30FF) -or `
                ($code -ge 0x3400 -and $code -le 0x4DBF) -or `
                ($code -ge 0x4E00 -and $code -le 0x9FFF) -or `
                ($code -ge 0xF900 -and $code -le 0xFAFF) -or `
                ($code -ge 0xFF61 -and $code -le 0xFF9F))
    }
    if ((& $isCjk $left) -or (& $isCjk $right)) { return $false }
    if (-not ([char]::IsLetterOrDigit($left) -or [char]::IsLetterOrDigit($right))) { return $false }
    return $true
}

function Join-YakuCatSplitTranslations {
    <#
      任意位置で割った行の訳文を、元の1つのセル（段落）へ戻すときの繋ぎ方。

      原文の割り方は「そのままの部分文字列」なので、繋げば1文字も足さずに
      元へ戻る。訳文はそうはいかない。訳文どうしの間には原文由来の文字が
      無いので、ここで決めるほかない。決め方は New-YakuCellSegment と同じ
      規則にそろえる（日本語が混じれば詰める・そうでなければ空白1つ）。
      すでに端が空白の側には足さない。二重空白は Excel のセルで目に見える。

      Sources（各行の原文）を渡すと、もう1段守る。原文の境目がトークンの
      内側だった箇所には繋ぎ文字を入れない。既に割ってある資料を後から
      弾いたりはしないので（利用者判断 2026-08-15）、繋ぎ方のほうで直す。
      渡さなければ今までどおり。Sources の本数が Parts と合わないときも
      今までどおりにする（対応づけを推測しない）。
    #>
    param([AllowNull()][object[]]$Parts, [AllowNull()][object[]]$Sources)
    $list = @(@($Parts) | ForEach-Object { [string]$_ })
    $sourceList = @(@($Sources) | ForEach-Object { [string]$_ })
    $useSources = ($list.Count -gt 1 -and $sourceList.Count -eq $list.Count)
    $sourceWhole = ''
    $sourceOffsets = @()
    if ($useSources) {
        $sb = New-Object System.Text.StringBuilder
        $offsets = New-Object System.Collections.Generic.List[int]
        foreach ($src in $sourceList) { [void]$offsets.Add([int]$sb.Length); [void]$sb.Append([string]$src) }
        $sourceWhole = $sb.ToString()
        $sourceOffsets = $offsets.ToArray()
    }
    $joiner = if ((@($list) -join '') -match '[぀-ヿ一-鿿]') { '' } else { ' ' }
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $list.Count; $i++) {
        $part = [string]$list[$i]
        if ([string]::IsNullOrEmpty($part)) { continue }
        if ($builder.Length -gt 0 -and $joiner -ne '') {
            $left = [char]$builder.Chars($builder.Length - 1)
            $glued = $false
            # 見るのは「この行の原文が、繋いだ原文のどこから始まるか」。
            # 途中の行の訳文が空でも、境目そのものは原文の側で決まる。
            if ($useSources) { $glued = [bool](Test-YakuCatSplitPositionInsideToken -Text $sourceWhole -Position ([int]$sourceOffsets[$i])) }
            if (-not $glued -and -not [char]::IsWhiteSpace($left) -and -not [char]::IsWhiteSpace($part[0])) { [void]$builder.Append($joiner) }
        }
        [void]$builder.Append($part)
    }
    return $builder.ToString()
}

function Group-YakuCatSplitSegments {
    <#
      任意位置で割った行を、元の1行へ畳んで返す。

      なぜ要るか: 割った2行は同じセル（段落）を指す。書き戻しは「塊1つに
      訳文1つ」で対応づけるので、畳まずに渡すと後の行が前の行を上書きし、
      前半の訳が黙って消える。畳む場所を1か所にして、Excel・Word・貼り付け
      本文のどの出口も同じ規則で通す。

      返すのは単位（unit）の並び。割っていない行は元の行そのものを返す
      （呼ぶ側が同一性のまま扱えるようにするため）。

      同じ組が離れて現れたら、畳むと順序が崩れる。黙って続けず止める。
    #>
    param([AllowNull()][object[]]$Segments)
    $list = @($Segments)
    $units = New-Object System.Collections.Generic.List[object]
    $closed = @{}
    $i = 0
    while ($i -lt $list.Count) {
        $groupId = Get-YakuCatSegmentSplitGroupId -Segment $list[$i]
        if ([string]::IsNullOrWhiteSpace($groupId)) {
            [void]$units.Add([pscustomobject]@{
                Segment = $list[$i]; Indices = @($i)
                MemberSegmentIds = @([string]$list[$i].SegmentId); IsSplitGroup = $false
            })
            $i++
            continue
        }
        if ($closed.ContainsKey($groupId)) { throw 'CAT_SPLIT_GROUP_NOT_CONTIGUOUS: 途中で分けた行が離れています。安全のため処理を止めました。' }
        $members = New-Object System.Collections.Generic.List[object]
        $indices = New-Object System.Collections.Generic.List[int]
        $j = $i
        while ($j -lt $list.Count -and (Get-YakuCatSegmentSplitGroupId -Segment $list[$j]) -eq $groupId) {
            [void]$members.Add($list[$j]); [void]$indices.Add($j); $j++
        }
        $closed[$groupId] = $true
        $memberArray = $members.ToArray()
        $first = $memberArray[0]
        $maxRevision = 1
        foreach ($m in $memberArray) { $r = 1; try { $r = [int]$m.SourceRevision } catch { $r = 1 }; if ($r -gt $maxRevision) { $maxRevision = $r } }
        $pseudo = [pscustomobject]@{
            SegmentId   = $groupId
            Text        = (@($memberArray | ForEach-Object { [string]$_.Text }) -join '')
            # 原文も渡す。境目がトークンの内側（`AB-` ＋ `1234`）だった箇所へ
            # 空白を入れると、数値QCに掛からないまま資料が壊れる。
            Translation = (Join-YakuCatSplitTranslations -Parts @($memberArray | ForEach-Object { [string]$_.Translation }) -Sources @($memberArray | ForEach-Object { [string]$_.Text }))
            SourceRevision = $maxRevision
            Kind        = [string]$first.Kind
            Sheet       = [string]$first.Sheet
            Location    = [string]$first.Location
            BlockIds    = @($first.BlockIds)
            Cells       = @($first.Cells)
            Joined      = [bool]$first.Joined
            Origin      = [string]$first.Origin
            SplitGroupId = ''
            SplitOrdinal = 0
            SplitOriginSegmentId = [string]$(try { $first.SplitOriginSegmentId } catch { '' })
        }
        [void]$units.Add([pscustomobject]@{
            Segment = $pseudo; Indices = @($indices.ToArray())
            MemberSegmentIds = @($memberArray | ForEach-Object { [string]$_.SegmentId }); IsSplitGroup = $true
        })
        $i = $j
    }
    # 呼ぶ側は必ず @() で受ける。ここで `,` を付けると二重に包まれ、
    # PS5.1 の member enumeration で $unit.Segment が配列になる（実測 2026-08-15）。
    return @($units.ToArray())
}

function Get-YakuSegmentTranslationByBlockId {
    <#
      セグメントの訳文を、元の塊ごとの訳文へ割り戻す。
      返すのは Write-YakuExcelTranslations がそのまま受け取れる形。

      繋いだセグメントは、元のセルの長さを重みにして割り振る。
      繋いでいないものは1対1。
      任意位置で割った行は、先に元の1行へ畳んでから割り振る（同じセルを
      指す2行をそのまま渡すと、後の行が前の行を上書きする）。
    #>
    param(
        [AllowNull()][object[]]$Segments,
        [Parameter(Mandatory=$true)][hashtable]$TranslationBySegmentIndex
    )
    $map = @{}
    $segs = @($Segments)
    foreach ($unit in @(Group-YakuCatSplitSegments -Segments $segs)) {
        $indices = @($unit.Indices)
        if (@($indices | Where-Object { $TranslationBySegmentIndex.ContainsKey($_) }).Count -eq 0) { continue }
        $translation = if ([bool]$unit.IsSplitGroup) {
            Join-YakuCatSplitTranslations -Parts @($indices | ForEach-Object { if ($TranslationBySegmentIndex.ContainsKey($_)) { [string]$TranslationBySegmentIndex[$_] } else { '' } }) -Sources @($indices | ForEach-Object { [string]$segs[$_].Text })
        } else { [string]$TranslationBySegmentIndex[$indices[0]] }
        $segment = $unit.Segment
        $ids = @($segment.BlockIds)
        if ($ids.Count -eq 0) { continue }
        if ($ids.Count -eq 1) { $map[[string]$ids[0]] = $translation; continue }
        $cells = @($segment.Cells)
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
