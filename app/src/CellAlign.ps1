<#
  過去の対訳 Excel（日本語版・英語版）から、セルの対応を取り出す。

  何のためか:

    表の変わらない部分は AI を使うまでもなく、機械置換で足りる
    （利用者の判断 2026-08-06）。仕組みは既にある
    （Resolve-YakuFileExactGlossaryTranslations の利用者登録cell_exact）。
    足りないのは**置換表そのものの供給**で、いまは開発者が一人で書いている。

    過去の ECM 資料には英訳がある。そこから対応を吸い出せれば、
    置換表は人手で書くものではなく、過去の成果物から採るものになる。

  なぜ番地で突き合わせないのか:

    「セル番地は基本対応する。ただし体裁のために行や列を足したり
    削ったりするので保証はしない」（利用者の説明 2026-08-06）。

    行が1本入れば、それ以降の番地は全部ずれる。ずれたまま突き合わせると
    **誤った対訳が大量に混ざる**。置換表は完全一致で機械置換する先なので、
    誤りが1件混ざれば、それが以後ずっと当たり続ける。番地は使えない。

  どう解くか（patience 方式）:

    diff が同じ問題を解いている。行の挿入・削除に強い突き合わせは、
    「両側で1回ずつしか出てこない値」を錨にする。

      1. 両方のシートで**ちょうど1回**現れる値を集める（財務表なので
         数値がこれになる。11,577 が日英に1つずつなら、それは同じセル）
      2. 錨のうち、順序が入れ替わらない最大の並びを採る（最長増加部分列）
      3. **錨と錨に挟まれた**テキストセルだけを対応付ける

    行や列の挿入は「錨と錨の間が伸びた」だけとして吸収され、
    次の錨で同期が戻る。ECM は数値が密なので錨が多く取れる。

  出てくるのは候補であって置換表ではない:

    錨に挟まれていない対応、個数が合わない区間は確度を落として返す。
    採否は人が決める。誤りが許されない先へ入れるものなので、
    自動で確定させない。

  この模組は Excel を読まない。並びを受け取って対応を返すだけにしてある。
  実物の ECM に触れない間も、合成した並びで正しさを確かめられるようにするため。
#>

function Get-YakuWorkbookCellSequence {
    <#
      ブック1冊を、対応付けに使える並びへ落とす。

      並べる順は行優先（左上から右へ、次の行へ）。表では「項目名 | 値 | 値」と
      並ぶので、この順なら項目名が自分の数値の直前に来る。
      Get-YakuValueAdjacentPairs がその性質に乗っている。

      図形・テキストボックスは並びに入れない。位置がレイアウトに依り、
      行優先の並びに混ぜると順序が壊れるため。図形は毎回書き換わるので
      置換表の対象にもならない（利用者の説明 2026-08-06）。

      シートは名前で突き合わせる。名前が変わっているシートは、
      ここでは扱わない（対応が付かないものを推測で結ぶと誤りが混ざる）。
    #>
    param(
        [Parameter(Mandatory=$true)]$Workbook,
        [int]$MaxCellsPerSheet = 20000
    )
    $sheets = @{}
    $order = New-Object System.Collections.Generic.List[string]
    $skippedSheets = New-Object System.Collections.Generic.List[object]
    foreach ($ws in $Workbook.Worksheets) {
        $name = ''
        try { $name = [string]$ws.Name } catch { $name = '' }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $cells = New-Object System.Collections.Generic.List[object]
        $used = $null
        try { $used = $ws.UsedRange } catch { $used = $null }
        if ($null -ne $used) {
            $values = $null
            $rows = 0; $cols = 0; $firstRow = 1; $firstCol = 1
            try {
                $rows = [int]$used.Rows.Count
                $cols = [int]$used.Columns.Count
                $firstRow = [int]$used.Row
                $firstCol = [int]$used.Column
                $values = $used.Value2
            } catch { $values = $null }
            $sheetCellCount = [int64]$rows * [int64]$cols
            if ($sheetCellCount -gt $MaxCellsPerSheet) {
                $skippedSheets.Add([pscustomobject]@{ Name=$name; Reason='max-cells-exceeded'; Cells=$sheetCellCount; Limit=$MaxCellsPerSheet }) | Out-Null
                try { Write-YakuLog "Cell alignment sheet skipped. sheet=$name cells=$sheetCellCount limit=$MaxCellsPerSheet" 'WARN' } catch {}
            }
            if ($null -ne $values -and $sheetCellCount -le $MaxCellsPerSheet) {
                for ($rr = 1; $rr -le $rows; $rr++) {
                    for ($cc = 1; $cc -le $cols; $cc++) {
                        $v = Get-YakuRangeArrayValue -Values $values -RowOffset $rr -ColOffset $cc
                        if ($null -eq $v) { continue }
                        $text = [string]$v
                        if ([string]::IsNullOrWhiteSpace($text)) { continue }
                        $isText = ($v -is [string]) -and ($text -match '[^\s0-9,\.\(\)▲△%\-]')
                        $addr = $name + '!' + (Convert-YakuColumnNumberToName -Column ($firstCol + $cc - 1)) + [string]($firstRow + $rr - 1)
                        [void]$cells.Add((New-YakuCellEntry -Address $addr -Text $text -IsText $isText))
                    }
                }
            }
            Release-YakuComObject $used
        }
        Release-YakuComObject $ws
        if ($cells.Count -eq 0) { continue }
        $sheets[$name] = @($cells.ToArray())
        [void]$order.Add($name)
    }
    return [pscustomobject]@{ Sheets = $sheets; Order = @($order.ToArray()); SkippedSheets = @($skippedSheets.ToArray()) }
}

function Get-YakuSheetMatches {
    <#
      日本語版のシートに、英語版のどのシートが対応するかを決める。

      三段で試す。前の段で決まったシートは次の段の対象から外す。

        1. 名前が完全一致
        2. 期の部分を伏せた名前が一致
           シート名は四半期で変わり、日英で表記が揃わないことがある
           （損益_Q1 と 損益_1Q）。利用者の説明 2026-08-06。
        3. 中身が一致
           シート名そのものが訳されていることがある（損益 と PL）。
           名前では結べないので、共有する錨（両側で1回だけ現れる数値）の
           多さで決める。名前に頼らないので、並べ替えにも改名にも強い。

      3段目には歯止めを掛ける。錨が少なすぎるものは結ばない。
      2番手と差が付かないものも結ばない。まるごと別の表を対応付けると、
      誤った対訳が大量に出るためである。決められないなら結ばないほうがよい。
    #>
    param(
        [Parameter(Mandatory=$true)]$Source,
        [Parameter(Mandatory=$true)]$Target,
        # 中身で結ぶときに要る錨の数。これ未満なら偶然の一致とみなす。
        [int]$MinContentAnchors = 3
    )
    $result = @{}
    $usedTarget = @{}

    foreach ($n in @($Source.Order)) {
        if ($Target.Sheets.ContainsKey($n) -and -not $usedTarget.ContainsKey($n)) {
            $result[$n] = [pscustomobject]@{ Target = $n; Basis = '名前' }
            $usedTarget[$n] = $true
        }
    }

    if (Get-Command ConvertTo-YakuPeriodNeutralName -ErrorAction SilentlyContinue) {
        # 伏せた名前が2つ以上の相手で重なる場合は使わない。どれと結ぶか決められない。
        $neutral = @{}
        foreach ($n in @($Target.Order)) {
            if ($usedTarget.ContainsKey($n)) { continue }
            $k = ConvertTo-YakuPeriodNeutralName -Name $n
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            if ($neutral.ContainsKey($k)) { $neutral[$k] = '' } else { $neutral[$k] = $n }
        }
        foreach ($n in @($Source.Order)) {
            if ($result.ContainsKey($n)) { continue }
            $k = ConvertTo-YakuPeriodNeutralName -Name $n
            if ([string]::IsNullOrWhiteSpace($k) -or -not $neutral.ContainsKey($k)) { continue }
            $t = [string]$neutral[$k]
            if ([string]::IsNullOrWhiteSpace($t) -or $usedTarget.ContainsKey($t)) { continue }
            $result[$n] = [pscustomobject]@{ Target = $t; Basis = '期を伏せた名前' }
            $usedTarget[$t] = $true
        }
    }

    foreach ($n in @($Source.Order)) {
        if ($result.ContainsKey($n)) { continue }
        $best = ''; $bestScore = 0; $runnerUp = 0
        foreach ($t in @($Target.Order)) {
            if ($usedTarget.ContainsKey($t)) { continue }
            $score = @(Get-YakuCellAnchors -Left $Source.Sheets[$n] -Right $Target.Sheets[$t]).Count
            if ($score -gt $bestScore) { $runnerUp = $bestScore; $bestScore = $score; $best = $t }
            elseif ($score -gt $runnerUp) { $runnerUp = $score }
        }
        if ([string]::IsNullOrWhiteSpace($best)) { continue }
        if ($bestScore -lt $MinContentAnchors) { continue }
        # 2番手と差が付かないなら決めない。取り違えは誤訳を大量に生む。
        if ($runnerUp -gt 0 -and $bestScore -lt ($runnerUp * 2)) { continue }
        $result[$n] = [pscustomobject]@{ Target = $best; Basis = ('中身（錨 ' + $bestScore + '）') }
        $usedTarget[$best] = $true
    }
    return $result
}

function Get-YakuWorkbookPairCandidates {
    <#
      対訳のブック2冊から、置換表の候補を取り出す。

      シートは名前が一致するものだけを突き合わせる。名前が違うシートを
      位置で結ぶと、まるごと別の表を対応付けかねない。誤りが完全一致で
      機械置換される先へ入るので、推測はしない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [AllowNull()]$Context
    )
    $ownContext = $false
    if ($null -eq $Context) { $Context = New-YakuExcelApplication; $ownContext = $true }
    $wbS = $null; $wbT = $null
    try {
        $wbS = Open-YakuWorkbookWithManualCalc -Context $Context -Path $SourcePath -ReadOnly $true
        $wbT = Open-YakuWorkbookWithManualCalc -Context $Context -Path $TargetPath -ReadOnly $true
        $seqS = Get-YakuWorkbookCellSequence -Workbook $wbS
        $seqT = Get-YakuWorkbookCellSequence -Workbook $wbT
        $matches = Get-YakuSheetMatches -Source $seqS -Target $seqT
        $pairs = New-Object System.Collections.Generic.List[object]
        $sheetReport = New-Object System.Collections.Generic.List[object]
        foreach ($name in $seqS.Order) {
            $targetName = ''
            $basis = ''
            if ($matches.ContainsKey($name)) { $targetName = [string]$matches[$name].Target; $basis = [string]$matches[$name].Basis }
            if ([string]::IsNullOrWhiteSpace($targetName)) {
                [void]$sheetReport.Add([pscustomobject]@{ Sheet = $name; TargetSheet = ''; Basis = ''; Matched = $false; Anchors = 0; Pairs = 0 })
                continue
            }
            $r = Get-YakuBilingualCellPairs -Left $seqS.Sheets[$name] -Right $seqT.Sheets[$targetName]
            foreach ($p in @($r.Pairs)) { [void]$pairs.Add($p) }
            [void]$sheetReport.Add([pscustomobject]@{
                Sheet = $name; TargetSheet = $targetName; Basis = $basis; Matched = $true
                Anchors = [int]$r.AnchorCount
                Pairs = @($r.Pairs).Count
            })
        }
        return [pscustomobject]@{
            Pairs  = @($pairs.ToArray())
            Sheets = @($sheetReport.ToArray())
        }
    } finally {
        try { if ($null -ne $wbS) { $wbS.Close($false) | Out-Null } } catch {}
        try { if ($null -ne $wbT) { $wbT.Close($false) | Out-Null } } catch {}
        Release-YakuComObject $wbS
        Release-YakuComObject $wbT
        if ($ownContext) {
            Close-YakuExcelObjects -Workbook $null -Application $Context.Application `
                -OldScreenUpdating $Context.OldScreenUpdating -OldEnableEvents $Context.OldEnableEvents `
                -OldDisplayStatusBar $Context.OldDisplayStatusBar -OldFormatConditionsCalc $Context.OldFormatConditionsCalc `
                -OldBackgroundChecking $Context.OldBackgroundChecking
        }
    }
}

function New-YakuCellEntry {
    <#
      対応付けの入力になるセル1つ。
        Address … Sheet1!C12 など。人が確かめるときの手掛かり。
        Text    … 表示上の文字列。
        IsText  … 訳の対象か（数値・空白は false）。数値は錨にしか使わない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Address,
        [AllowNull()][string]$Text,
        [bool]$IsText = $true
    )
    return [pscustomobject]@{
        Address = [string]$Address
        Text    = [string]$Text
        IsText  = [bool]$IsText
    }
}

function ConvertTo-YakuAnchorKey {
    <#
      錨として突き合わせるときの鍵。

      日本語版と英語版で書式が違っても同じ値なら同じ鍵になるようにする。
      1,234 と 1234、全角と半角、前後の空白を吸収する。
      ▲ と () は符号の書き分けなので、負号へ寄せる。
    #>
    param([AllowNull()][string]$Text)
    $t = [string]$Text
    if ([string]::IsNullOrWhiteSpace($t)) { return '' }
    # 全角英数を半角へ
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0xFF01 -and $c -le 0xFF5E) { [void]$sb.Append([char]($c - 0xFEE0)) }
        elseif ($c -eq 0x3000) { [void]$sb.Append(' ') }
        else { [void]$sb.Append($ch) }
    }
    $t = $sb.ToString().Trim()
    # 負の書き分けを揃える: ▲123 / △123 / (123) -> -123
    $t = [regex]::Replace($t, '^[▲△]\s*', '-')
    $t = [regex]::Replace($t, '^\(\s*([0-9,\.]+)\s*\)$', '-$1')
    # 桁区切りと通貨・単位の空白を落とす
    $t = $t -replace ',', ''
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t
}

function Test-YakuAnchorCandidate {
    <#
      錨に使ってよい値か。

      使うのは「日英で同じ姿のまま残るもの」だけ。数値・比率・年度記号など。
      日本語の語や英語の語は、訳されるので錨にならない。

      1〜2桁の数だけの値は錨にしない。表の中で何度も出るうえ、
      たまたま一致しても意味が無い。ここで落としておくと、
      「両側で1回だけ」の判定に頼りきらずに済む。
    #>
    param([AllowNull()][string]$Key)
    $k = [string]$Key
    if ([string]::IsNullOrWhiteSpace($k)) { return $false }
    if ($k.Length -lt 3) { return $false }
    # 数字を含まないものは錨にしない（訳される側なので）
    if ($k -notmatch '[0-9]') { return $false }
    # 日本語を含むものは錨にしない（英語版では別の姿になる）
    if ($k -match '[぀-ヿ一-鿿]') { return $false }
    return $true
}

function Get-YakuLongestIncreasingPairs {
    <#
      錨の候補から、順序が入れ替わらない最大の並びを採る。

      両側で1回ずつしか出ない値でも、行を入れ替えた場合には
      順序が逆転する。逆転を含んだまま区間を切ると、間に挟まれた
      セルの対応が総崩れになるので、単調に増える並びだけを残す。

      入力は @(@{L=<左の位置>; R=<右の位置>}) を左位置の昇順で。
      返すのは右位置が増加する最大の部分列（最長増加部分列）。
    #>
    param([AllowNull()][object[]]$Pairs)
    $items = @($Pairs)
    if ($items.Count -eq 0) { return @() }
    # tails[k] = 長さ k+1 の増加列で、末尾の R が最小のものの添字
    $tails = New-Object System.Collections.Generic.List[int]
    $prev = New-Object 'int[]' $items.Count
    for ($i = 0; $i -lt $items.Count; $i++) { $prev[$i] = -1 }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $r = [int]$items[$i].R
        # tails の中で R 以上になる最初の位置を二分探索
        $lo = 0; $hi = $tails.Count
        while ($lo -lt $hi) {
            # [int] は切り捨てではなく丸めなので、[int](3/2) は 2 になる。
            # 中点が範囲を越えて null を引くため、明示的に切り捨てる。
            $mid = [int][Math]::Floor(($lo + $hi) / 2)
            if ([int]$items[$tails[$mid]].R -lt $r) { $lo = $mid + 1 } else { $hi = $mid }
        }
        if ($lo -gt 0) { $prev[$i] = $tails[$lo - 1] }
        if ($lo -eq $tails.Count) { [void]$tails.Add($i) } else { $tails[$lo] = $i }
    }
    if ($tails.Count -eq 0) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    $cur = $tails[$tails.Count - 1]
    while ($cur -ge 0) { [void]$out.Add($items[$cur]); $cur = $prev[$cur] }
    $arr = @($out.ToArray())
    [array]::Reverse($arr)
    return $arr
}

function Get-YakuCellAnchors {
    <#
      2つの並びから錨を取る。

      「両側でちょうど1回」を条件にするのは patience diff と同じ理由による。
      何度も出る値は、どれとどれが対応するかを決められない。
      1回しか出ないなら曖昧さが無く、間違えようがない。
    #>
    param(
        [AllowNull()][object[]]$Left,
        [AllowNull()][object[]]$Right
    )
    $l = @($Left); $r = @($Right)
    $lCount = @{}; $rCount = @{}
    $lIndex = @{}; $rIndex = @{}
    for ($i = 0; $i -lt $l.Count; $i++) {
        $k = ConvertTo-YakuAnchorKey -Text ([string]$l[$i].Text)
        if (-not (Test-YakuAnchorCandidate -Key $k)) { continue }
        if (-not $lCount.ContainsKey($k)) { $lCount[$k] = 0 }
        $lCount[$k]++
        $lIndex[$k] = $i
    }
    for ($i = 0; $i -lt $r.Count; $i++) {
        $k = ConvertTo-YakuAnchorKey -Text ([string]$r[$i].Text)
        if (-not (Test-YakuAnchorCandidate -Key $k)) { continue }
        if (-not $rCount.ContainsKey($k)) { $rCount[$k] = 0 }
        $rCount[$k]++
        $rIndex[$k] = $i
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($k in $lCount.Keys) {
        if ([int]$lCount[$k] -ne 1) { continue }
        if (-not $rCount.ContainsKey($k)) { continue }
        if ([int]$rCount[$k] -ne 1) { continue }
        [void]$pairs.Add([pscustomobject]@{ Key = [string]$k; L = [int]$lIndex[$k]; R = [int]$rIndex[$k] })
    }
    $sorted = @(@($pairs.ToArray()) | Sort-Object -Property L)
    return @(Get-YakuLongestIncreasingPairs -Pairs $sorted)
}

function Get-YakuValueAdjacentPairs {
    <#
      一致した数値の直前にあるテキストを、項目名どうしとして対応付ける。

      なぜこれが要るのか:

        錨と錨に挟まれた区間を「前から順に」対応させるだけだと、
        区間の**内側**に行が増えていたときに総崩れになる。

          日本語版:  営業利益  1,234
          英語版:    Subtotal  9,999  /  Operating profit  1,234

        1,234 は錨になるが、区間の中で日本語1つに対し英語2つが並ぶので、
        順番に取ると 営業利益 -> Subtotal になる。置換表へ入れば誤りが
        固定するので、これは許容できない。

      表の性質を使う:

        表では**項目名は自分の数値の直前にある**。行が
        「項目名 | 前年 | 当年」なら、行を左から右へ読む並びで
        項目名は最初の数値の1つ前に来る。
        したがって、一致した数値から1つ戻れば項目名どうしが対応する。
        上の例では 1,234 の直前が 営業利益 と Operating profit になり、
        Subtotal は相手を持たない。行の増減に左右されない。

      どこまで遡るか:

        1つ前は数値に直付けなので確度が高い。2つ以上前は
        「1つ前が正しかった」という前提に乗るので確度を落とす。
        見出し行（項目名が連続する行）を拾うために遡り自体は続けるが、
        置換表へ入れてよいのは距離1のものだけにする。
    #>
    param(
        [AllowNull()][object[]]$Left,
        [AllowNull()][object[]]$Right,
        [AllowNull()][object[]]$Anchors
    )
    $l = @($Left); $r = @($Right)
    $out = New-Object System.Collections.Generic.List[object]
    $usedL = @{}; $usedR = @{}
    foreach ($p in @($Anchors)) { $usedL[[int]$p.L] = $true; $usedR[[int]$p.R] = $true }
    foreach ($p in @($Anchors)) {
        $li = [int]$p.L - 1
        $ri = [int]$p.R - 1
        $distance = 1
        while ($li -ge 0 -and $ri -ge 0) {
            if ($usedL.ContainsKey($li) -or $usedR.ContainsKey($ri)) { break }
            if (-not [bool]$l[$li].IsText -or -not [bool]$r[$ri].IsText) { break }
            if ([string]::IsNullOrWhiteSpace([string]$l[$li].Text) -or [string]::IsNullOrWhiteSpace([string]$r[$ri].Text)) { break }
            $usedL[$li] = $true; $usedR[$ri] = $true
            [void]$out.Add([pscustomobject]@{
                L = $li; R = $ri
                Confidence = $(if ($distance -eq 1) { 'high' } else { 'medium' })
                Basis = 'value-adjacent'
            })
            $li--; $ri--; $distance++
        }
    }
    return @(@($out.ToArray()) | Sort-Object -Property L)
}

function Get-YakuAlignedCellPairs {
    <#
      錨で区間を切り、区間の中のテキストセルを対応付ける。

      区間の中は、順序が保たれている前提で前から順に対応させる。
      表の体裁替えは「行や列の出し入れ」であって「入れ替え」ではないので、
      区間が短ければこの前提は妥当である。

      確度の付け方:
        high   … 両端が錨で、区間内のテキストセル数が日英で一致する
        medium … 両端が錨だが個数が合わない（何かが増減している）
        low    … 端が錨で閉じていない（先頭より前、末尾より後）

      個数が合わない区間を捨てずに medium で返すのは、そこにこそ
      「今回変わった項目」が居るためである。捨てると、いちばん見たい
      ものが消える。ただし置換表へ入れてよいのは high だけにする。
    #>
    param(
        [AllowNull()][object[]]$Left,
        [AllowNull()][object[]]$Right,
        [AllowNull()][object[]]$Anchors,
        # 数値に直付けで決まった項目名の対。これ自体が対訳であり、
        # 同時に区間の境目にもなる。
        [AllowNull()][object[]]$ValueAdjacent
    )
    $l = @($Left); $r = @($Right)
    $a = @($Anchors)
    $out = New-Object System.Collections.Generic.List[object]

    # 数値に直付けで決まった対を、そのまま結果へ入れる。
    foreach ($p in @($ValueAdjacent)) {
        [void]$out.Add([pscustomobject]@{
            Source        = [string]$l[[int]$p.L].Text
            Target        = [string]$r[[int]$p.R].Text
            SourceAddress = [string]$l[[int]$p.L].Address
            TargetAddress = [string]$r[[int]$p.R].Address
            Confidence    = [string]$p.Confidence
            Basis         = 'value-adjacent'
        })
    }

    # 区間の境目を作る。錨の前後に仮想の端を置いて、同じ処理で回せるようにする。
    # 数値に直付けで決まった対も境目にする。そこで区間が締まるので、
    # 残りの区間が短くなり、順番での対応が当たりやすくなる。
    $bounds = New-Object System.Collections.Generic.List[object]
    [void]$bounds.Add([pscustomobject]@{ L = -1; R = -1; Real = $false })
    foreach ($p in $a) { [void]$bounds.Add([pscustomobject]@{ L = [int]$p.L; R = [int]$p.R; Real = $true }) }
    foreach ($p in @($ValueAdjacent)) { [void]$bounds.Add([pscustomobject]@{ L = [int]$p.L; R = [int]$p.R; Real = $true }) }
    $bounds = New-Object System.Collections.Generic.List[object](,[object[]](@($bounds.ToArray()) | Sort-Object -Property L))
    [void]$bounds.Add([pscustomobject]@{ L = $l.Count; R = $r.Count; Real = $false })

    for ($b = 0; $b -lt ($bounds.Count - 1); $b++) {
        $from = $bounds[$b]
        $to = $bounds[$b + 1]
        $closed = ([bool]$from.Real -and [bool]$to.Real)
        $lSeg = New-Object System.Collections.Generic.List[object]
        $rSeg = New-Object System.Collections.Generic.List[object]
        for ($i = [int]$from.L + 1; $i -lt [int]$to.L; $i++) { if ([bool]$l[$i].IsText) { [void]$lSeg.Add($l[$i]) } }
        for ($j = [int]$from.R + 1; $j -lt [int]$to.R; $j++) { if ([bool]$r[$j].IsText) { [void]$rSeg.Add($r[$j]) } }
        if ($lSeg.Count -eq 0 -or $rSeg.Count -eq 0) { continue }
        $same = ($lSeg.Count -eq $rSeg.Count)
        $confidence = if (-not $closed) { 'low' } elseif ($same) { 'high' } else { 'medium' }
        $n = [Math]::Min($lSeg.Count, $rSeg.Count)
        for ($k = 0; $k -lt $n; $k++) {
            $sourceText = [string]$lSeg[$k].Text
            $targetText = [string]$rSeg[$k].Text
            if ([string]::IsNullOrWhiteSpace($sourceText) -or [string]::IsNullOrWhiteSpace($targetText)) { continue }
            [void]$out.Add([pscustomobject]@{
                Source        = $sourceText
                Target        = $targetText
                SourceAddress = [string]$lSeg[$k].Address
                TargetAddress = [string]$rSeg[$k].Address
                Confidence    = $confidence
                Basis         = 'sequence'
            })
        }
    }
    return @($out.ToArray())
}

function Get-YakuBilingualCellPairs {
    <#
      2つの並びから対訳の候補を返す。ここが入口。
    #>
    param(
        [AllowNull()][object[]]$Left,
        [AllowNull()][object[]]$Right
    )
    $anchors = @(Get-YakuCellAnchors -Left $Left -Right $Right)
    $adjacent = @(Get-YakuValueAdjacentPairs -Left $Left -Right $Right -Anchors $anchors)
    $pairs = @(Get-YakuAlignedCellPairs -Left $Left -Right $Right -Anchors $anchors -ValueAdjacent $adjacent)
    return [pscustomobject]@{
        AnchorCount   = [int]$anchors.Count
        AdjacentCount = [int]$adjacent.Count
        Anchors       = $anchors
        Pairs         = $pairs
    }
}

function Test-YakuCellPairUsableAsGlossary {
    <#
      置換表へ入れてよい対だけを通す。

      通さないもの:
       - 確度が high 以外（錨で閉じていない・個数が合わない）
       - 原文に日本語が無い（数値や記号は置換表の仕事ではない）
       - 訳文に日本語が残っている（訳し漏れ。入れると誤りが固定する）
       - 長すぎるもの（文は置換表ではなく翻訳メモリの仕事）
       - 原文と訳文が同一（置換する意味が無い）
    #>
    param(
        [Parameter(Mandatory=$true)]$Pair,
        [int]$MaxChars = 60
    )
    if ([string]$Pair.Confidence -ne 'high') { return $false }
    $s = [string]$Pair.Source
    $t = [string]$Pair.Target
    if ([string]::IsNullOrWhiteSpace($s) -or [string]::IsNullOrWhiteSpace($t)) { return $false }
    if ($s.Trim() -eq $t.Trim()) { return $false }
    if ($s.Length -gt $MaxChars -or $t.Length -gt $MaxChars) { return $false }
    if ($s -notmatch '[぀-ヿ一-鿿]') { return $false }
    if ($t -match '[぀-ヿ一-鿿]') { return $false }
    return $true
}

function Merge-YakuCellPairOccurrences {
    <#
      複数のファイル・シートから出た候補をまとめる。

      同じ対がいくつのファイルで出たかを数える。何年分もの資料で
      繰り返し現れる対は、たまたまの一致ではない。人が確かめるとき、
      出現数の多いものから見れば少ない手間で多くを片付けられる。

      同じ原文に別の訳が付いている場合は競合として残す。どちらが正しいかは
      機械に決められない。黙って片方を捨てると、誤ったほうが残りうる。
    #>
    param([AllowNull()][object[]]$Pairs)
    $map = @{}
    foreach ($p in @($Pairs)) {
        if ($null -eq $p) { continue }
        $key = ([string]$p.Source).Trim() + [string][char]31 + ([string]$p.Target).Trim()
        if (-not $map.ContainsKey($key)) {
            $map[$key] = [pscustomobject]@{
                Source     = ([string]$p.Source).Trim()
                Target     = ([string]$p.Target).Trim()
                Count      = 0
                Confidence = [string]$p.Confidence
                Samples    = New-Object System.Collections.Generic.List[string]
            }
        }
        $e = $map[$key]
        $e.Count++
        if ($e.Samples.Count -lt 3) { [void]$e.Samples.Add([string]$p.SourceAddress + ' -> ' + [string]$p.TargetAddress) }
    }
    $all = @($map.Values)
    # 同じ原文に別の訳が付いているものへ印を付ける。
    $bySource = @{}
    foreach ($e in $all) {
        $s = [string]$e.Source
        if (-not $bySource.ContainsKey($s)) { $bySource[$s] = 0 }
        $bySource[$s]++
    }
    foreach ($e in $all) {
        $conflict = ([int]$bySource[[string]$e.Source] -gt 1)
        $e | Add-Member -NotePropertyName 'Conflict' -NotePropertyValue $conflict -Force
    }
    return @($all | Sort-Object -Property @{ Expression = { [int]$_.Count }; Descending = $true }, @{ Expression = { [string]$_.Source } })
}
