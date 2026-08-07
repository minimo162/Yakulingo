<#
  CAT: Excel を取り込み、セグメントで並べ、置換・翻訳・出力を段階に分ける。

  なぜ段階に分けるのか:

    ファイル翻訳の精度が低いもう半分の理由は、**途中が見えない**ことにある。
    出来上がった Excel が一見良さげに見えるので崩壊に気づけず、
    あとの修正作業が増える（利用者の診断 2026-08-06）。

    やることはファイル翻訳とほぼ同じである。違うのは、
      取り込む → 用語集で置換する → 残りを訳す → 出力する
    を1つの塊にせず、押した分だけ進み、左右に並べて見えるようにする点だけ。

  ここに無いもの:

    翻訳メモリ、確定の状態、事前翻訳の仕組みは入れない。
    まずは「ファイル翻訳と同じことが、確認しやすくなっただけ」を作る
    （利用者の判断 2026-08-06）。段階を分けておけば、あとから
    段階を足すのは easy になる。

  保持の仕方:

    プロジェクトはメモリに置く。作業中しか使わないので、保存の形を
    先に決めなくてよい。決めていない設計をファイルへ書き出すと、
    あとで移行が要る。
#>

$script:YakuCatProjects = [hashtable]::Synchronized(@{})

function New-YakuCatSegmentView {
    <#
      画面へ渡すセグメント1件分。中身は保持しているものの写しである。
    #>
    param([Parameter(Mandatory=$true)]$Segment, [Parameter(Mandatory=$true)][int]$Index)
    return [pscustomobject]@{
        Index       = $Index
        Source      = [string]$Segment.Text
        Translation = [string]$Segment.Translation
        Origin      = [string]$Segment.Origin
        Joined      = [bool]$Segment.Joined
        CellCount   = @($Segment.BlockIds).Count
        Kind        = [string]$Segment.Kind
        Location    = [string]$Segment.Location
    }
}

function New-YakuCatProject {
    <#
      Excel を取り込み、セグメントに分ける。訳はまだ付けない。
      まず原文だけを並べて見せる、という段取りに合わせている。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [AllowNull()][string[]]$Sheets,
        [AllowNull()]$ProgressState
    )
    $extract = Get-YakuExcelTextBlocks -Path $Path -Direction $Direction -Settings $Settings -Sheets $Sheets -ProgressState $ProgressState
    $blocks = @($extract.Blocks)

    # 行の埋まり具合は実際のシートから数える。翻訳対象だけを数えると
    # 「営業利益 | 1,234」の行が単独に見え、表の行を文章として繋いでしまう。
    $occ = @{}
    $ctx = New-YakuExcelApplication
    try {
        $wb = Open-YakuWorkbookWithManualCalc -Context $ctx -Path $Path -ReadOnly $true
        try { $occ = Get-YakuExcelRowOccupancy -Workbook $wb } finally {
            try { $wb.Close($false) | Out-Null } catch {}
            Release-YakuComObject $wb
        }
    } finally {
        Close-YakuExcelObjects -Workbook $null -Application $ctx.Application `
            -OldScreenUpdating $ctx.OldScreenUpdating -OldEnableEvents $ctx.OldEnableEvents `
            -OldDisplayStatusBar $ctx.OldDisplayStatusBar -OldFormatConditionsCalc $ctx.OldFormatConditionsCalc `
            -OldBackgroundChecking $ctx.OldBackgroundChecking
    }

    $segments = @(Group-YakuTextBlocksIntoSegments -Blocks $blocks -RowOccupancy $occ)
    foreach ($s in $segments) {
        $s | Add-Member -NotePropertyName 'Translation' -NotePropertyValue '' -Force
        # どこから来た訳文か。用語集／Copilot／手直し を区別して画面に出す。
        $s | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '' -Force
    }

    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = [string]$Path
        FileName  = [System.IO.Path]::GetFileName($Path)
        Direction = [string]$Direction
        Blocks    = $blocks
        Segments  = $segments
        Warnings  = @($extract.Warnings)
        CreatedAt = (Get-Date).ToString('s')
    }
    $script:YakuCatProjects[$project.Id] = $project
    return $project
}

function New-YakuCatTextProject {
    <#
      貼り付けたテキストから CAT のプロジェクトを作る。

      簡易翻訳と入力の作法を揃えるための経路である（利用者の懸念 2026-08-06）。
      貼って押す、までは同じで、変わるのは出口だけになる。
      Excel を知らなくても CAT を使えるようにする。

      出口も違う。書き戻す元のファイルが無いので、出力は訳文を繋いだもの
      （画面でコピーする）。簡易翻訳と同じ終わり方になる。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en'
    )
    $segments = New-Object System.Collections.Generic.List[object]
    foreach ($s in @(Split-YakuTextIntoSegments -Text $Text)) {
        $seg = [pscustomobject]@{
            Text = [string]$s
            BlockIds = @()
            Cells = @()
            Joined = $false
            Kind = 'text'
            Sheet = ''
            Location = '本文'
            Translation = ''
            Origin = ''
        }
        [void]$segments.Add($seg)
    }
    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = ''
        FileName  = '貼り付けたテキスト'
        Direction = [string]$Direction
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @()
        Source    = 'text'
        CreatedAt = (Get-Date).ToString('s')
    }
    $script:YakuCatProjects[$project.Id] = $project
    return $project
}

function New-YakuCatAlignProject {
    <#
      日本語と英語のひと組から CAT のプロジェクトを作る。訳す代わりに、
      既にある訳と突き合わせる。市販ツールの「文書のアライメント」に当たる。

      管理画面に取り込み専用の画面を作るのではなく、CAT の画面をそのまま
      使う（利用者の指摘 2026-08-07「今の管理画面は使いづらい」）。
      利点は作りの節約ではなく、確認の質のほうにある。

        - 対応は原文と訳文が左右に並ぶ、いつものグリッドで見える
        - ずれていれば、いつもの結合・分割で直せる
        - 直してからコーパスへ入れられる

      機械が作った対応をそのまま貯めるのではなく、人が一度見てから貯める。
      誤った対訳は完全一致で機械置換され続けるので、入口で見るのが安い。

      どのファイルとどのファイルが組かは、利用者が2つ選ぶことで決まる。
      名前から機械的に推測はしない。間違った組で突き合わせると、もっともらしい
      誤った対訳ができてしまう。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceText,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetText,
        [Parameter(Mandatory=$true)][AllowNull()]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$FileName = '対訳の突き合わせ',
        [int]$MinLineLength = 4
    )
    $clean = {
        param([string]$Text)
        return @(($Text -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim().Length -ge $MinLineLength })
    }
    $toEn = ([string]$Direction -eq 'to_en')
    $srcLines = @(& $clean $SourceText)
    $tgtLines = @(& $clean $TargetText)
    # アライメントは日本語を軸に切る。実測した壁（50行）が日本語基準のため。
    $jaLines = if ($toEn) { $srcLines } else { $tgtLines }
    $enLines = if ($toEn) { $tgtLines } else { $srcLines }

    $warnings = New-Object System.Collections.Generic.List[string]
    $segments = New-Object System.Collections.Generic.List[object]
    $aligned = $null
    if ($jaLines.Count -eq 0 -or $enLines.Count -eq 0) {
        [void]$warnings.Add('日本語と英語の両方が必要です。片方が空でした。')
    }
    else {
        $aligned = Invoke-YakuDocumentAlignment -JaLines $jaLines -EnLines $enLines -Settings $Settings
        foreach ($p in @($aligned.Pairs)) {
            $ja = [string]$p.JaText; $en = [string]$p.EnText
            [void]$segments.Add([pscustomobject]@{
                Text        = [string]$(if ($toEn) { $ja } else { $en })
                BlockIds    = @()
                Cells       = @()
                Joined      = $false
                Kind        = 'align'
                Sheet       = ''
                Location    = '対訳'
                Translation = [string]$(if ($toEn) { $en } else { $ja })
                # 機械が作った対応であることを残す。人が直せば manual になる。
                Origin      = 'align'
            })
        }
        $cov = [Math]::Round($aligned.JaCoverage, 2)
        if ($aligned.JaCoverage -lt 0.9) {
            [void]$warnings.Add(('対応を取れなかった行があります（網羅率 ' + [string]([int]($cov * 100)) + '%）。抽出が崩れていないか確かめてください。'))
        }
        if ([int]$aligned.Dropped -gt 0) {
            [void]$warnings.Add(('数値が食い違う対を ' + [string]$aligned.Dropped + ' 組はずしました。'))
        }
    }
    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = ''
        FileName  = [string]$FileName
        Direction = [string]$Direction
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @($warnings.ToArray())
        Source    = 'align'
        CreatedAt = (Get-Date).ToString('s')
        Alignment = $aligned
    }
    $script:YakuCatProjects[$project.Id] = $project
    return $project
}

function Save-YakuCatProjectToCorpus {
    <#
      グリッドで確かめた対訳をコーパスへ入れる。人が直した対も、直していない
      対も、この時点の中身をそのまま貯める。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$Database,
        [string]$Source = '',
        # 保存先。既定は管理者の取り込み場所。試験は別の場所を指す。
        [AllowNull()][string]$Dir,
        [switch]$Public
    )
    if ([string]::IsNullOrWhiteSpace($Dir)) { $Dir = Get-YakuCorpusBuildDir }
    $toEn = ([string]$Project.Direction -eq 'to_en')
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($seg in @($Project.Segments)) {
        $a = [string]$seg.Text; $b = [string]$seg.Translation
        if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { continue }
        [void]$pairs.Add([pscustomobject]@{
            JaText        = [string]$(if ($toEn) { $a } else { $b })
            EnText        = [string]$(if ($toEn) { $b } else { $a })
            # 人が直した対は、機械の数値照合を通していなくても信用してよい。
            NumberChecked = $true
            NumberAgree   = $true
        })
    }
    $src = [string]$Source
    if ([string]::IsNullOrWhiteSpace($src)) { $src = [string]$Project.FileName }
    return (Add-YakuCorpusPairs -Dir $Dir -Database $Database -Source $src -Pairs @($pairs.ToArray()) -Public:$Public)
}

function Get-YakuCatProject {
    param([Parameter(Mandatory=$true)][string]$Id)
    if (-not $script:YakuCatProjects.ContainsKey($Id)) { return $null }
    return $script:YakuCatProjects[$Id]
}

function Remove-YakuCatProject {
    param([Parameter(Mandatory=$true)][string]$Id)
    try { $script:YakuCatProjects.Remove($Id) } catch {}
}

function Get-YakuCatProjectSummary {
    param([Parameter(Mandatory=$true)]$Project)
    $segs = @($Project.Segments)
    $done = @($segs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
    return [pscustomobject]@{
        Id        = [string]$Project.Id
        FileName  = [string]$Project.FileName
        Direction = [string]$Project.Direction
        Total     = $segs.Count
        Translated = $done
        Remaining = ($segs.Count - $done)
        Joined    = @($segs | Where-Object { [bool]$_.Joined }).Count
    }
}

function ConvertTo-YakuCatProjectJson {
    <#
      画面へ渡す形。原文・訳文・出どころ・場所だけを出す。
      元の塊やセルの座標は画面に用が無いので載せない。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $segs = @($Project.Segments)
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        [void]$rows.Add([ordered]@{
            index       = $i
            source      = [string]$segs[$i].Text
            translation = [string]$segs[$i].Translation
            origin      = [string]$segs[$i].Origin
            joined      = [bool]$segs[$i].Joined
            cells       = @($segs[$i].BlockIds).Count
            kind        = [string]$segs[$i].Kind
            location    = [string]$segs[$i].Location
            # 次と繋げるか。シートが違う・図形が挟まる場合は繋げない。
            can_merge   = ($i -lt ($segs.Count - 1)) -and ([string]$segs[$i].Kind -eq [string]$segs[$i + 1].Kind) -and (
                           ([string]$segs[$i].Kind -eq 'text') -or
                           ([string]$segs[$i].Kind -eq 'cell' -and [string]$segs[$i].Sheet -eq [string]$segs[$i + 1].Sheet))
            can_split   = (([string]$segs[$i].Kind -eq 'cell' -and @($segs[$i].Cells).Count -gt 1) -or
                           ([string]$segs[$i].Kind -eq 'text' -and @(Get-YakuCatTextPieces -Segment $segs[$i]).Count -gt 1))
        })
    }
    $summary = Get-YakuCatProjectSummary -Project $Project
    # 引いた文例。検索したときだけ入る。何が引けたかを見てから
    # 使うかどうか決められるようにするため（利用者の判断 2026-08-06）。
    $corpusExamples = @()
    try { $corpusExamples = @($Project.CorpusExamples) } catch { $corpusExamples = @() }
    $corpusRows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $corpusExamples) {
        if ($null -eq $e) { continue }
        # 出どころは Database / Source / Page。どの資料の何ページかが分からないと、
        # 文例を採るかどうか判断できない。
        $text = ''; $db = ''; $doc = ''; $page = ''
        try { $text = [string]$e.Text } catch {}
        try { $db = [string]$e.Database } catch {}
        try { $doc = [string]$e.Source } catch {}
        try { $page = [string]$e.Page } catch {}
        # Source が既にデータベース名で始まっていることがある。二重に付けない。
        if ((-not [string]::IsNullOrWhiteSpace($db)) -and $doc.StartsWith($db)) { $db = '' }
        $where = (@($db, $doc) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '/'
        if (-not [string]::IsNullOrWhiteSpace($page)) { $where = ($where + ' p.' + $page).Trim() }
        [void]$corpusRows.Add([ordered]@{ text = $text; where = $where })
    }
    return ([ordered]@{
        id         = [string]$Project.Id
        source     = $(try { if ([string]$Project.Source -eq 'text') { 'text' } else { 'file' } } catch { 'file' })
        corpus_ready = $(try { -not [string]::IsNullOrWhiteSpace([string]$Project.CorpusSection) } catch { $false })
        corpus     = @($corpusRows.ToArray())
        file_name  = [string]$Project.FileName
        direction  = [string]$Project.Direction
        total      = [int]$summary.Total
        translated = [int]$summary.Translated
        remaining  = [int]$summary.Remaining
        joined     = [int]$summary.Joined
        segments   = @($rows.ToArray())
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Invoke-YakuCatGlossaryPass {
    <#
      登録された用語集で、機械的に置換する。

      当たるのは**完全一致だけ**である。表のラベルはそのために登録して
      あるので、ここで大半の項目が片付く。文中の語を置き換えることは
      しない（活用と一致が壊れるため。実機検証結果 §3-2 に記録）。

      既に訳が入っているセグメントは触らない。人が直したものを
      機械が上書きしてはならない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Settings
    )
    $segs = @($Project.Segments)
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
        [void]$items.Add([pscustomobject]@{ Index = $i; Text = [string]$segs[$i].Text; BlockIds = (New-Object System.Collections.Generic.List[string]) })
    }
    $map = @{}
    if ($items.Count -gt 0) {
        $null = Resolve-YakuFileExactGlossaryTranslations -Root $Root -Items @($items.ToArray()) -Direction ([string]$Project.Direction) -Settings $Settings -TranslationByIndex $map
    }
    $hits = 0
    foreach ($k in @($map.Keys)) {
        $i = [int]$k
        if ($i -lt 0 -or $i -ge $segs.Count) { continue }
        $segs[$i].Translation = [string]$map[$k]
        $segs[$i].Origin = 'glossary'
        $hits++
    }
    return [pscustomobject]@{ Applied = $hits; Remaining = @($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count }
}

function Invoke-YakuCatCopilotPass {
    <#
      用語集で埋まらなかったセグメントを Copilot で訳す。

      同じ原文が何度出ても1回しか送らない。ファイル翻訳と同じ扱いである。
      既に訳が入っているものは送らない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()]$ProgressState,
        [AllowNull()]$Warnings
    )
    $segs = @($Project.Segments)
    if ($null -eq $Warnings) { $Warnings = New-Object System.Collections.Generic.List[object] }

    # 同じ原文をまとめる。送る回数を減らすためで、割り戻しは後で行う。
    $byText = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
        $text = [string]$segs[$i].Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if (-not $byText.ContainsKey($text)) {
            $item = [pscustomobject]@{ Index = ($items.Count + 1); Text = $text; BlockIds = (New-Object System.Collections.Generic.List[string]); SegmentIndexes = (New-Object System.Collections.Generic.List[int]) }
            $byText[$text] = $item
            [void]$items.Add($item)
        }
        [void]$byText[$text].SegmentIndexes.Add($i)
    }
    if ($items.Count -eq 0) { return [pscustomobject]@{ Translated = 0; Remaining = 0; Sent = 0 } }

    $maxChars = Get-YakuSettingInt -Settings $Settings -Name 'file_batch_chars' -Default 3000
    $context = @{ BatchOrdinal = 0; TotalBatches = 0; MaxRetryDepth = 0 }
    $batches = @(Split-YakuFileTranslationItems -Items @($items.ToArray()) -MaxChars $maxChars)
    $context['TotalBatches'] = [int]$batches.Count
    $map = Invoke-YakuFileTranslationItems -Root $Root -Items @($items.ToArray()) -Settings $Settings `
        -Direction ([string]$Project.Direction) -MaxChars $maxChars -Warnings $Warnings `
        -ProgressState $ProgressState -Context $context

    $filled = 0
    foreach ($item in @($items.ToArray())) {
        $idx = [int]$item.Index
        if (-not $map.ContainsKey($idx)) { continue }
        $translation = [string]$map[$idx]
        if ([string]::IsNullOrWhiteSpace($translation)) { continue }
        foreach ($si in @($item.SegmentIndexes)) {
            $segs[[int]$si].Translation = $translation
            $segs[[int]$si].Origin = 'copilot'
            $filled++
        }
    }
    return [pscustomobject]@{
        Translated = $filled
        Sent = $items.Count
        Remaining = @($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
    }
}

function Get-YakuCatTextPieces {
    <#
      テキストのセグメントが抱えている元の文を返す。

      繋いだものは Pieces を持ち、繋いでいないものは持たない。
      @($null) は「空」ではなく「null が1つ入った配列」になるので、
      件数で判断する前に必ず空要素を落とす。
    #>
    param([Parameter(Mandatory=$true)]$Segment)
    $pieces = @()
    try { $pieces = @(@($Segment.Pieces) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) } catch { $pieces = @() }
    if ($pieces.Count -eq 0) { $pieces = @([string]$Segment.Text) }
    return @($pieces)
}

function Set-YakuCatSegments {
    # 並べ替えたセグメントを差し戻す。訳文と出どころは各セグメントが持つ。
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Segments)
    $Project.Segments = @($Segments)
}

function Merge-YakuCatSegments {
    <#
      隣り合うセグメントを1つに繋ぐ。

      なぜ手で繋げるようにするのか:

        繋ぐ判定は「同じ列で行が連続し、他に埋まったセルが無く、句点で
        終わっていない」という目に見える事実だけで決めている。それでも
        自動で完璧に分けるのは無理である（利用者の指摘 2026-08-06）。
        外れたときに人が直せることが、この作りの前提になっている。

      訳文は消す:

        繋いだ後の原文は、繋ぐ前とは別の文である。前の訳文は断片の訳
        なので、残すと「一見良さげだが中身が合っていない」状態を自分で
        作ることになる。それはこの作り直しがいちばん避けたかったものである。

      繋げるのはセルどうし、同じシートのものだけ。図形はレイアウト上の
      位置で並ぶので、セルの並びへ混ぜられない。
    #>
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][int]$Index)
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge ($segs.Count - 1)) { throw '次のセグメントがありません。' }
    $a = $segs[$Index]
    $b = $segs[$Index + 1]
    if ([string]$a.Kind -ne [string]$b.Kind) { throw '種類が違うため結合できません。' }
    if ([string]$a.Kind -eq 'text') {
        # 貼り付けたテキスト。戻すセルが無いので、本文を繋ぐだけでよい。
        # 元の文は覚えておく。解除して1文ずつへ戻せるようにするため。
        $pieces = @(@(Get-YakuCatTextPieces -Segment $a) + @(Get-YakuCatTextPieces -Segment $b))
        $joiner = if ((@($pieces) -join '') -match '[぀-ヿ一-鿿]') { '' } else { ' ' }
        $merged = [pscustomobject]@{
            Text = (@($pieces) -join $joiner); BlockIds = @(); Cells = @(); Joined = $true
            Kind = 'text'; Sheet = ''; Location = '本文'; Pieces = @($pieces)
            Translation = ''; Origin = ''
        }
        $out = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($i -eq $Index) { [void]$out.Add($merged); continue }
            if ($i -eq ($Index + 1)) { continue }
            [void]$out.Add($segs[$i])
        }
        Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
        return $Project
    }
    if ([string]$a.Kind -ne 'cell') { throw 'セル以外は結合できません。' }
    if ([string]$a.Sheet -ne [string]$b.Sheet) { throw 'シートが違うため結合できません。' }
    $merged = New-YakuCellSegment -Sheet ([string]$a.Sheet) -Cells (@($a.Cells) + @($b.Cells)) -Joined $true
    $merged | Add-Member -NotePropertyName 'Translation' -NotePropertyValue '' -Force
    $merged | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '' -Force
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($i -eq $Index) { [void]$out.Add($merged); continue }
        if ($i -eq ($Index + 1)) { continue }
        [void]$out.Add($segs[$i])
    }
    Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
    return $Project
}

function Split-YakuCatSegment {
    <#
      繋がっているセグメントを、元のセル1つずつへ戻す。

      「隣と繋ぐ」と「元へ戻す」の2つがあれば、どんなまとめ方にも
      到達できる。途中で切る操作は入れない。操作が増えるだけで、
      できることは変わらない。

      訳文は消す。理由は Merge-YakuCatSegments と同じ。
    #>
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][int]$Index)
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'セグメントが見つかりません。' }
    $target = $segs[$Index]
    if ([string]$target.Kind -eq 'text') {
        $pieces = @(Get-YakuCatTextPieces -Segment $target)
        if ($pieces.Count -le 1) { throw 'このセグメントは繋がっていません。' }
        $out = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($i -ne $Index) { [void]$out.Add($segs[$i]); continue }
            foreach ($p in $pieces) {
                [void]$out.Add([pscustomobject]@{
                    Text = [string]$p; BlockIds = @(); Cells = @(); Joined = $false
                    Kind = 'text'; Sheet = ''; Location = '本文'
                    Translation = ''; Origin = ''
                })
            }
        }
        Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
        return $Project
    }
    if ([string]$target.Kind -ne 'cell') { throw 'セル以外は解除できません。' }
    $cells = @($target.Cells)
    if ($cells.Count -le 1) { throw 'このセグメントは繋がっていません。' }
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($i -ne $Index) { [void]$out.Add($segs[$i]); continue }
        foreach ($c in $cells) {
            $one = New-YakuCellSegment -Sheet ([string]$target.Sheet) -Cells @($c) -Joined $false
            $one | Add-Member -NotePropertyName 'Translation' -NotePropertyValue '' -Force
            $one | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '' -Force
            [void]$out.Add($one)
        }
    }
    Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
    return $Project
}

function Get-YakuCatSegmentCandidates {
    <#
      1つのセグメントに対する候補を返す。CAT エディタの中核にあたる部分。

      市販ツールはここに 翻訳メモリ・用語集・機械翻訳 を一致率つきで並べ、
      Ctrl+数字 で差し込めるようにしている。訳す前に「過去はどう訳したか」が
      目に入ることが、一貫性を保つ仕組みそのものになっている。

      出せるのは用語集と、過去の対訳（コーパスの対）である。

      対訳のほうは長く出せなかった。コーパスが英文しか持たず、日本語の
      原文から英語の検索語を作るのに Copilot への往復が要ったためで、
      行を移るたびには引けなかった（利用者の指摘 2026-08-06）。
      Copilot によるアライメントで日英の対が取れるようになり、日本語の
      まま引けるようになったので、ここへ出す。

      翻訳メモリ（この利用者自身が確定した訳）はまだ無い。

      完全一致だけでなく部分一致も出す。表のラベルは完全一致で機械置換
      できるが、文の中に現れた語は置換しない（活用と一致が壊れるため。
      実機検証結果 §3-2）。置換しないからこそ、目に入る場所へ出す値打ちがある。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [int]$Max = 8
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { return @() }
    $text = [string]$segs[$Index].Text
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $toEn = ([string]$Project.Direction -eq 'to_en')
    $sourceKey = ConvertTo-YakuGlossaryMatchKey -Value (ConvertTo-YakuGlossaryField -Value $text)

    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($entry in @(Get-YakuGlossaryEntries -Root $Root)) {
        $from = if ($toEn) { ConvertTo-YakuGlossaryField -Value $entry.Source } else { ConvertTo-YakuGlossaryField -Value $entry.Target }
        $to   = if ($toEn) { ConvertTo-YakuGlossaryField -Value $entry.Target } else { ConvertTo-YakuGlossaryField -Value $entry.Source }
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
        $exact = [string]::Equals((ConvertTo-YakuGlossaryMatchKey -Value $from), $sourceKey, [System.StringComparison]::Ordinal)
        if (-not $exact) {
            # 部分一致。1文字の語で拾いすぎないよう、ある程度の長さを求める。
            if ($from.Length -lt 2) { continue }
            $at = $text.IndexOf($from, [System.StringComparison]::Ordinal)
            if ($at -lt 0) { continue }
            # 短い漢字語が、前の漢字と続いて別の語になっている場合は拾わない。
            # 「四半期」の中の「半期」が Half-year として出ると、かえって誤らせる。
            # 日本語には語の切れ目が無いので、これ以上のことは字面から分からない。
            if ($from.Length -le 2 -and $from -match '^[一-鿿]' -and $at -gt 0 -and [string]$text[$at - 1] -match '[一-鿿]') { continue }
        }
        $key = $from + [string][char]31 + $to
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$out.Add([pscustomobject]@{
            Kind   = 'glossary'
            Source = $from
            Target = $to
            Exact  = $exact
            # 長い語ほど手掛かりとして強い。並べ替えに使う。
            Weight = $(if ($exact) { 10000 } else { $from.Length })
        })
    }

    # 過去の対訳。用語集より上に出す。市販ツールも翻訳メモリを先頭へ置く。
    # 語の対応より、文まるごとの前例のほうが強い手掛かりだからである。
    try {
        $pairsDir = Get-YakuCorpusBuildDir
        foreach ($hit in @(Find-YakuCorpusPairsForSegment -Dir $pairsDir -Text $text -SourceLanguage $(if ($toEn) { 'ja' } else { 'en' }) -Limit 5)) {
            $key = 'pair' + [string][char]31 + [string]$hit.Source + [string][char]31 + [string]$hit.Target
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$out.Add([pscustomobject]@{
                Kind     = 'corpus'
                Source   = [string]$hit.Source
                Target   = [string]$hit.Target
                Exact    = [bool]$hit.Exact
                Database = [string]$hit.Database
                # 数値の裏取りが通っていない対は、通ったものより下に置く。
                Verified = [bool]$hit.Verified
                Ratio    = [double]$hit.Ratio
                Weight   = 20000 + [int]([double]$hit.Ratio * 1000) + $(if ($hit.Verified) { 100 } else { 0 })
            })
        }
    } catch {
        # コーパスが無い環境でも用語集は出す。候補ペインごと落ちるほうが困る。
        try { Write-YakuLog ('Corpus pair candidates unavailable: ' + $_.Exception.Message) 'WARN' } catch {}
    }

    return @(@($out.ToArray()) | Sort-Object -Property @{ Expression = { [int]$_.Weight }; Descending = $true } | Select-Object -First $Max)
}

function Set-YakuCatSegmentTranslation {
    <#
      人が直した訳文を入れる。以後、機械の処理はここを触らない。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [AllowNull()][string]$Text
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw ('セグメントが見つかりません: ' + $Index) }
    $segs[$Index].Translation = [string]$Text
    $segs[$Index].Origin = 'manual'
    return $segs[$Index]
}

function Export-YakuCatProject {
    <#
      元の Excel をコピーし、そこへ訳文を書き戻す。

      繋いだセグメントは元のセルの長さを重みにして割り振る。
      訳の無いセグメントは書かない。既存の書き戻しは
      「訳文が原文と同じなら触らない」を守るので、原文のまま残る。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        # 貼り付けたテキストのときは空。書き戻す元のファイルが無い。
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$OutputPath,
        [AllowNull()]$Settings,
        [AllowNull()]$Warnings,
        [AllowNull()]$ProgressState
    )
    if ($null -eq $Warnings) { $Warnings = New-Object System.Collections.Generic.List[object] }
    $segs = @($Project.Segments)
    # 貼り付けたテキストは書き戻す元のファイルが無い。訳文を繋いで返すだけ。
    # 簡易翻訳と同じ終わり方（画面でコピーする）にして、覚えることを増やさない。
    if ([string]$Project.Source -eq 'text') {
        $lines = @($segs | ForEach-Object {
            $t = [string]$_.Translation
            if ([string]::IsNullOrWhiteSpace($t)) { [string]$_.Text } else { $t }
        })
        return [pscustomobject]@{
            OutputPath = ''
            OutputName = ''
            Text       = (@($lines) -join "`n")
            Written    = @($segs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
            Skipped    = @($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
        }
    }
    $bySegment = @{}
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $t = [string]$segs[$i].Translation
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $bySegment[$i] = $t
    }
    $byBlock = Get-YakuSegmentTranslationByBlockId -Segments $segs -TranslationBySegmentIndex $bySegment
    Copy-Item -LiteralPath ([string]$Project.Path) -Destination $OutputPath -Force
    Clear-YakuOutputReadOnlyAttribute -Path $OutputPath
    $null = Write-YakuExcelTranslations -OutputPath $OutputPath -Blocks @($Project.Blocks) `
        -TranslationByBlockId $byBlock -Warnings $Warnings -Settings $Settings -ProgressState $ProgressState
    return [pscustomobject]@{
        OutputPath = $OutputPath
        OutputName = [System.IO.Path]::GetFileName($OutputPath)
        Written    = $byBlock.Count
        Skipped    = (@($segs).Count - $bySegment.Count)
    }
}
