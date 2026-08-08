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

# 文書の種類。内部資料と公表資料では、望ましい出力が単位のレベルから違う
# （利用者の整理 2026-08-08）。
#
#   内部資料  スペースに収まることが第一。億円は oku、略記あり、電文体を使う。
#             公表しないので文例にはできない。毎期同じ資料を作るので、
#             前期に自分がどう訳したかが最も効く。
#   公表資料  会社の公式な言い方に従う。¥12.2 billion、略記なし。
#             公表後は文例として全員で使える。
#
# 同じ「翻訳支援」でも、この2つは候補の並べ方から保存の可否まで逆を向く。
# どちらかを最初に決めることで、下流の判断をまとめて済ませる。
function Test-YakuCatProjectIsPublic {
    param([Parameter(Mandatory=$true)]$Project)
    try { return ([string]$Project.Kind -eq 'public') } catch { return $false }
}

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
        # 人が「これで良い」と判断したか。訳文が入っているかとは別物である。
        Confirmed   = [bool]$Segment.Confirmed
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
        [ValidateSet('internal','public')][string]$Kind = 'internal',
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
        # 人が「これで良い」と見た行かどうか。訳が入っているかとは別に持つ。
        $s | Add-Member -NotePropertyName 'Confirmed' -NotePropertyValue $false -Force
    }

    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = [string]$Path
        FileName  = [System.IO.Path]::GetFileName($Path)
        Direction = [string]$Direction
        Kind      = [string]$Kind
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
        [Parameter(Mandatory=$true)][AllowNull()]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [ValidateSet('internal','public')][string]$Kind = 'internal',
        # 簡易翻訳から持ってきた訳文。原文と同じ規則で分けて並べる。
        # 空のまま渡すと、渡した先で「さっきの訳が消えた」ことになる。
        [AllowNull()][string]$Translation
    )
    $sources = @(Split-YakuTextIntoSegments -Text $Text)
    $targets = @()
    if (-not [string]::IsNullOrWhiteSpace($Translation)) {
        $targets = @(Split-YakuTextIntoSegments -Text $Translation)
    }
    # 行数が合わないときは割り当てない。ずれたまま並べると、対応していない
    # 訳が原文の隣に出る。空欄のほうがまだ分かる。
    $useTargets = ($targets.Count -gt 0 -and $targets.Count -eq $sources.Count)
    $segments = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $seg = [pscustomobject]@{
            Text = [string]$sources[$i]
            BlockIds = @()
            Cells = @()
            Joined = $false
            Kind = 'text'
            Sheet = ''
            Location = '本文'
            Translation = [string]$(if ($useTargets) { $targets[$i] } else { '' })
            Origin = [string]$(if ($useTargets) { 'copilot' } else { '' })
            Confirmed = $false
        }
        [void]$segments.Add($seg)
    }
    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = ''
        FileName  = '貼り付けたテキスト'
        Direction = [string]$Direction
        Kind      = [string]$Kind
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

    if ($jaLines.Count -eq 0 -or $enLines.Count -eq 0) {
        return (New-YakuCatProjectFromPairs -Pairs @() -Direction $Direction -FileName $FileName `
                -Warnings @('日本語と英語の両方が必要です。片方が空でした。'))
    }
    $aligned = Invoke-YakuDocumentAlignment -JaLines $jaLines -EnLines $enLines -Settings $Settings
    return (New-YakuCatProjectFromPairs -Pairs @($aligned.Pairs) -Direction $Direction -FileName $FileName `
            -JaCoverage ([double]$aligned.JaCoverage) -Dropped ([int]$aligned.Dropped))
}

function New-YakuCatProjectFromPairs {
    <#
      取れた対から CAT のプロジェクトを組み立てる。

      突き合わせ自体は時間がかかるのでジョブ側（別のランスペース）で走らせる。
      プロジェクトはサーバーの手元に持つので、組み立ては分けてある。
      New-YakuCatAlignProject も、試験や単独実行のためにこれを呼ぶ。
    #>
    param(
        [AllowNull()][object[]]$Pairs,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$FileName = '対訳の突き合わせ',
        [AllowNull()][string[]]$Warnings,
        [double]$JaCoverage = 1.0,
        [int]$Dropped = 0
    )
    $toEn = ([string]$Direction -eq 'to_en')
    $warn = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($Warnings)) { if (-not [string]::IsNullOrWhiteSpace([string]$w)) { [void]$warn.Add([string]$w) } }
    $segments = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Pairs)) {
        $ja = [string]$p.JaText; $en = [string]$p.EnText
        if ([string]::IsNullOrWhiteSpace($ja) -and [string]::IsNullOrWhiteSpace($en)) { continue }
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
            Confirmed   = $false
        })
    }
    # 黙って少ない結果を返すと、取れているように見えてしまう。
    if ($segments.Count -gt 0 -and $JaCoverage -lt 0.9) {
        [void]$warn.Add(('対応を取れなかった行があります（網羅率 ' + [string]([int]([Math]::Round($JaCoverage * 100))) + '%）。抽出が崩れていないか確かめてください。'))
    }
    if ($Dropped -gt 0) {
        [void]$warn.Add(('数値が食い違う対を ' + [string]$Dropped + ' 組はずしました。'))
    }
    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = ''
        FileName  = [string]$FileName
        Direction = [string]$Direction
        Kind      = [string]$Kind
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @($warn.ToArray())
        Source    = 'align'
        CreatedAt = (Get-Date).ToString('s')
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
    # 文例を作るのは開発者であって、日々の利用者ではない
    # （利用者の整理 2026-08-08「公表資料は数も限られているので、開発者が
    # 最終形を配布用として保存する前提のほうが良い」）。
    # だから入口は突き合わせ（Source='align'）に限る。訳しながら片手間に
    # 文例を作らせると、公表前の資料や作りかけの訳が混ざる。
    if ([string]$Project.Source -ne 'align') {
        throw '文例は、公表済みの資料を突き合わせたときだけ保存できます。'
    }
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

function Get-YakuCatProjectStoreDir {
    return (Get-YakuSubDir 'cat')
}

function Save-YakuCatProject {
    <#
      作業中のプロジェクトをディスクへ書く。

      これまではメモリだけに置いていた。「作業中しか使わないので保存の形を
      先に決めなくてよい」という判断だったが、確定の状態を持つようになって
      前提が変わった。どこまで見たかを記録しても、再読み込みで消えるなら
      記録の意味が無い。数百行を何時間もかけて見る作業で、F5 ひとつで
      全部消えるのは受け入れられない。

      書くのは中身だけ。Blocks（Excel の抽出結果）は大きく、書き戻しには
      元のファイルを読み直すので持たない。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    try {
        $dir = Get-YakuCatProjectStoreDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $segs = @($Project.Segments | ForEach-Object {
                [ordered]@{
                    text = [string]$_.Text
                    translation = [string]$_.Translation
                    origin = [string]$_.Origin
                    confirmed = [bool]$_.Confirmed
                    joined = [bool]$_.Joined
                    kind = [string]$_.Kind
                    sheet = [string]$_.Sheet
                    location = [string]$_.Location
                    block_ids = @($_.BlockIds)
                    cells = @($_.Cells)
                }
            })
        $record = [ordered]@{
            id = [string]$Project.Id
            path = [string]$Project.Path
            file_name = [string]$Project.FileName
            direction = [string]$Project.Direction
            source = [string]$Project.Source
            created = [string]$Project.CreatedAt
            saved = (Get-Date).ToString('s')
            segments = $segs
        }
        $file = Join-Path $dir ([string]$Project.Id + '.json')
        ($record | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $file -Encoding UTF8
        return $true
    } catch {
        try { Write-YakuLog ('CAT project save failed: ' + $_.Exception.Message) 'WARN' } catch {}
        return $false
    }
}

function Get-YakuCatSavedProjects {
    <#
      保存してあるものの一覧。新しい順。
      画面に「前回の続きから」を出すために使う。
    #>
    param([int]$Limit = 10)
    $dir = Get-YakuCatProjectStoreDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Limit)) {
        try {
            $o = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $segs = @($o.segments)
            [void]$out.Add([pscustomobject]@{
                    Id = [string]$o.id
                    FileName = [string]$o.file_name
                    Direction = [string]$o.direction
                    Total = $segs.Count
                    Confirmed = @($segs | Where-Object { [bool]$_.confirmed }).Count
                    Saved = [string]$o.saved
                })
        } catch {
            try { Write-YakuLog ('CAT project unreadable, skipped. file=' + $f.Name) 'WARN' } catch {}
        }
    }
    return @($out.ToArray())
}

function Restore-YakuCatProject {
    <#
      保存したものをメモリへ戻す。書き戻し用の Blocks は持たないので、
      Excel から取り込んだものは「出力」だけが使えない状態になる。
      それでも、確認した内容が残るほうが値打ちがある。
    #>
    param([Parameter(Mandatory=$true)][string]$Id)
    $file = Join-Path (Get-YakuCatProjectStoreDir) ($Id + '.json')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $o = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $segments = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($o.segments)) {
        [void]$segments.Add([pscustomobject]@{
                Text = [string]$s.text
                Translation = [string]$s.translation
                Origin = [string]$s.origin
                Confirmed = [bool]$s.confirmed
                Joined = [bool]$s.joined
                Kind = [string]$s.kind
                Sheet = [string]$s.sheet
                Location = [string]$s.location
                BlockIds = @($s.block_ids)
                Cells = @($s.cells)
            })
    }
    $project = [pscustomobject]@{
        Id        = [string]$o.id
        Path      = [string]$o.path
        FileName  = [string]$o.file_name
        Direction = [string]$o.direction
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @()
        Source    = [string]$o.source
        CreatedAt = [string]$o.created
        Restored  = $true
    }
    $script:YakuCatProjects[$project.Id] = $project
    return $project
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
    # 進捗は「人が確認した数」で数える。機械が埋めた数だと、翻訳ボタンを
    # 押した瞬間に 100% になり、以後どれだけ確認しても動かない。
    # 数百行を何時間もかけて見る作業では、それは進捗表示として役に立たない。
    $confirmed = @($segs | Where-Object { [bool]$_.Confirmed }).Count
    return [pscustomobject]@{
        Id        = [string]$Project.Id
        FileName  = [string]$Project.FileName
        Direction = [string]$Project.Direction
        Total     = $segs.Count
        Translated = $done
        Remaining = ($segs.Count - $done)
        Joined    = @($segs | Where-Object { [bool]$_.Joined }).Count
        Confirmed = $confirmed
        Unconfirmed = ($segs.Count - $confirmed)
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
            confirmed   = [bool]$segs[$i].Confirmed
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
        kind       = [string]$Project.Kind
        total      = [int]$summary.Total
        translated = [int]$summary.Translated
        remaining  = [int]$summary.Remaining
        joined     = [int]$summary.Joined
        confirmed   = [int]$summary.Confirmed
        unconfirmed = [int]$summary.Unconfirmed
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
        [int]$Max = 8,
        [AllowNull()][string]$PairsDir
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { return @() }
    $text = [string]$segs[$Index].Text
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $toEn = ([string]$Project.Direction -eq 'to_en')
    $sourceKey = ConvertTo-YakuGlossaryMatchKey -Value (ConvertTo-YakuGlossaryField -Value $text)

    $isPublic = Test-YakuCatProjectIsPublic -Project $Project
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

    # 翻訳メモリ。自分が確定した訳なので、どれよりも先に出す。
    # 公表訳は「読ませる訳」で意訳が多いが、これは自分の文体で、
    # 自分が正しいと判断したものだけが入っている。そのまま差し込める。
    try {
        foreach ($tm in @(Find-YakuTranslationMemory -Text $text -Direction ([string]$Project.Direction) -Limit 5)) {
            $key = 'tm' + [string][char]31 + [string]$tm.Source + [string][char]31 + [string]$tm.Target
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$out.Add([pscustomobject]@{
                Kind     = 'memory'
                Source   = [string]$tm.Source
                Target   = [string]$tm.Target
                Exact    = [bool]$tm.Exact
                Database = '翻訳メモリ'
                Verified = $true
                Ratio    = [double]$tm.Ratio
                # 内部資料では前期の自分の訳が主役。毎期同じ資料を作るので、
                # 前期と揃っていることが品質そのものになる。
                # 公表資料では、自分の訳より会社の公式な言い方が優先される。
                Weight   = $(if ($isPublic) { 20000 } else { 30000 }) + [int]([double]$tm.Ratio * 1000)
            })
        }
    } catch {
        # 翻訳メモリが読めなくても候補ペインごと落とさない。
        try { Write-YakuLog ('Translation memory candidates unavailable: ' + $_.Exception.Message) 'WARN' } catch {}
    }

    # 過去の対訳。用語集より上、翻訳メモリより下に出す。
    # 語の対応より文まるごとの前例のほうが強いが、自分が確定した訳には劣る。
    try {
        # 置き場所は呼び出し側から渡せるようにする。要求を捌く runspace は
        # 読み込む一式が違うことがあり、Get-YakuCorpusBuildDir が見えないと
        # 対訳が丸ごと出なくなる。実機のログで気づいた（2026-08-07）。
        $pairsDir = [string]$PairsDir
        if ([string]::IsNullOrWhiteSpace($pairsDir)) { $pairsDir = Get-YakuCorpusBuildDir }
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
                # 公表資料では公表訳が第一候補。会社が公式に出した言い方に従う。
                # 内部資料でも出す。倣う値打ちがあるため（利用者の整理 2026-08-08）。
                # ただし単位と略記は社内表記へ寄せる必要があるので、下に置く。
                Weight   = $(if ($isPublic) { 30000 } else { 20000 }) + [int]([double]$hit.Ratio * 1000) + $(if ($hit.Verified) { 100 } else { 0 })
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
    # 手で直したものは、その時点で人が見たということなので確定にする。
    if ($segs[$Index].PSObject.Properties.Name -contains 'Confirmed') { $segs[$Index].Confirmed = $true }
    else { $segs[$Index] | Add-Member -NotePropertyName 'Confirmed' -NotePropertyValue $true -Force }
    # 確定した訳を翻訳メモリへ貯める。次に同じ文が来たら候補に出る。
    # 市販ツールの Ctrl+Enter と同じ作法で、確定＝記憶にする。
    # 失敗しても訳の確定は妨げない。貯め損ねより、直せないほうが困る。
    try {
        $null = Add-YakuTranslationMemoryEntry -Source ([string]$segs[$Index].Text) -Target ([string]$Text) `
            -Direction ([string]$Project.Direction) -Origin 'cat'
    } catch {
        try { Write-YakuLog ('Translation memory save failed: ' + $_.Exception.Message) 'WARN' } catch {}
    }
    return $segs[$Index]
}

function Set-YakuCatSegmentConfirmed {
    <#
      「この行は見た」を記録する。訳文が変わっていなくても押せる。

      市販の CAT ツールで Ctrl+Enter が担っている役目である。機械訳を読んで
      「これで良い」と判断したことは、直したことと同じくらい記録に値する。
      記録が無いと、翌日再開したときに「どこまで見たか」が分からない。

      訳文が空の行は確定できない。読むものが無いのに見たとは言えない。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [bool]$Confirmed = $true
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw ('セグメントが見つかりません: ' + $Index) }
    if ($Confirmed -and [string]::IsNullOrWhiteSpace([string]$segs[$Index].Translation)) {
        throw '訳文が空の行は確定できません。'
    }
    if ($segs[$Index].PSObject.Properties.Name -contains 'Confirmed') { $segs[$Index].Confirmed = $Confirmed }
    else { $segs[$Index] | Add-Member -NotePropertyName 'Confirmed' -NotePropertyValue $Confirmed -Force }
    # 確定した訳は翻訳メモリへ入れる。直さずに確定したものも、
    # 「この訳で良い」という判断が入っている以上、次に使える。
    if ($Confirmed) {
        try {
            $null = Add-YakuTranslationMemoryEntry -Source ([string]$segs[$Index].Text) -Target ([string]$segs[$Index].Translation) `
                -Direction ([string]$Project.Direction) -Origin 'cat'
        } catch {
            try { Write-YakuLog ('Translation memory save failed: ' + $_.Exception.Message) 'WARN' } catch {}
        }
    }
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
