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
        Blocks    = $blocks
        Segments  = $segments
        Warnings  = @($extract.Warnings)
        Source    = 'file'
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
        # 機械が作った対応を、人が見ないまま公開対訳へ入れない。
        # 手直しした行は Set-YakuCatSegmentTranslation が確定済みにし、
        # 直さない行も「これでよい」を押したものだけがここを通る。
        $confirmed = $false
        try { $confirmed = [bool]$seg.Confirmed } catch { $confirmed = $false }
        if (-not $confirmed) { continue }
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

function Get-YakuCatCheckpointPath {
    param([Parameter(Mandatory=$true)][string]$ProjectId)
    $safeId = [regex]::Replace($ProjectId, '[^A-Za-z0-9_.-]', '_')
    $dir = Join-Path (Get-YakuCatProjectStoreDir) 'checkpoints'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    return (Join-Path $dir ($safeId + '.json'))
}

function Invoke-YakuCatCheckpointLock {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][scriptblock]$Operation
    )
    $safeId = [regex]::Replace($ProjectId, '[^A-Za-z0-9_.-]', '_')
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.CatCheckpoint.' + $safeId))
    $entered = $false
    try {
        try { $entered = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $entered = $true }
        if (-not $entered) { throw 'CAT_CHECKPOINT_LOCK_TIMEOUT: 途中保存の排他待ちがタイムアウトしました。' }
        return (& $Operation)
    } finally {
        if ($entered) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

function Save-YakuCatBatchCheckpoint {
    <# 成功したバッチだけを小さな別ファイルへ原子的に積む。別ランスペースから
       Project全体を書かないので、待機中の手修正を古いスナップショットで踏まない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Translations
    )
    if (@($Translations).Count -eq 0) { return 0 }
    $operation = {
        $path = Get-YakuCatCheckpointPath -ProjectId $ProjectId
        $byKey = [ordered]@{}
        try {
            $old = Read-YakuJsonFile -Path $path
            foreach ($row in @($old.translations)) {
                $key = [string]([int]$row.index) + '|' + [string]$row.source
                $byKey[$key] = $row
            }
        } catch {}
        foreach ($row in @($Translations)) {
            if ($null -eq $row) { continue }
            $source = [string]$row.source
            $text = [string]$row.text
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($text)) { continue }
            $index = [int]$row.index
            $key = [string]$index + '|' + $source
            $byKey[$key] = [ordered]@{
                index = $index; source = $source; text = $text
                masked = [string]$row.masked; saved = (Get-Date).ToString('s')
            }
        }
        Write-YakuJsonAtomic -Path $path -Value ([ordered]@{
                project_id = $ProjectId; translations = @($byKey.Values)
            }) -Depth 8
        return @($byKey.Values).Count
    }.GetNewClosure()
    return (Invoke-YakuCatCheckpointLock -ProjectId $ProjectId -Operation $operation)
}

function Apply-YakuCatBatchCheckpoint {
    <# mainランスペースでだけProjectへ取り込む。行番号に加えて原文一致と空欄を
       必須にし、結合・分割・手修正が待ち時間中に行われても上書きしない。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $projectId = [string]$Project.Id
    $operation = {
        $path = Get-YakuCatCheckpointPath -ProjectId $projectId
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
        $checkpoint = Read-YakuJsonFile -Path $path
        if ($null -eq $checkpoint) { return 0 }
        $segments = @($Project.Segments)
        $applied = 0
        $requiresSave = $false
        foreach ($row in @($checkpoint.translations)) {
            $index = [int]$row.index
            if ($index -lt 0 -or $index -ge $segments.Count) { continue }
            $segment = $segments[$index]
            if ([string]$segment.Text -ne [string]$row.source) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$segment.Translation)) {
                # 前回はメモリへ適用できたが、Project JSON の保存だけ失敗した可能性が
                # ある。同じcheckpoint由来の値なら再保存し、成功するまで消さない。
                if ([string]$segment.Translation -eq [string]$row.text -and
                    [string]$segment.MaskedTranslation -eq [string]$row.masked -and
                    [string]$segment.Origin -eq 'copilot') { $requiresSave = $true }
                continue
            }
            $segment.Translation = [string]$row.text
            $segment | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue ([string]$row.masked) -Force
            $segment.Origin = 'copilot'
            $segment.Confirmed = $false
            $applied++
            $requiresSave = $true
        }
        if ($requiresSave -and -not (Save-YakuCatProject -Project $Project)) { return 0 }
        # 適用できなかった行も古い編集状態に属する。保持すると毎回再評価され、
        # 将来たまたま同じ行番号になったときに誤適用されるため、ここで破棄する。
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $applied
    }.GetNewClosure()
    return (Invoke-YakuCatCheckpointLock -ProjectId $projectId -Operation $operation)
}

function Save-YakuCatProject {
    <#
      作業中のプロジェクトをディスクへ書く。

      これまではメモリだけに置いていた。「作業中しか使わないので保存の形を
      先に決めなくてよい」という判断だったが、確定の状態を持つようになって
      前提が変わった。どこまで見たかを記録しても、再読み込みで消えるなら
      記録の意味が無い。数百行を何時間もかけて見る作業で、F5 ひとつで
      全部消えるのは受け入れられない。

      訳文に加え、取り込み時の原文ブロックを軽量なスナップショットとして持つ。
      出力時はこの番地をそのまま使わず、元ファイルを読み直して原文どうしを
      対応付ける。スナップショットは「何が同じ原文か」を判断するためのもの。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    try {
        $dir = Get-YakuCatProjectStoreDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $segs = @($Project.Segments | ForEach-Object {
                [ordered]@{
                    text = [string]$_.Text
                    translation = [string]$_.Translation
                    masked_translation = [string]$_.MaskedTranslation
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
        $blocks = @($Project.Blocks | ForEach-Object {
                [ordered]@{
                    id = [string]$_.Id
                    text = [string]$_.Text
                    location = [string]$_.Location
                    meta = $_.Meta
                }
            })
        $record = [ordered]@{
            id = [string]$Project.Id
            path = [string]$Project.Path
            file_name = [string]$Project.FileName
            direction = [string]$Project.Direction
            source = [string]$Project.Source
            created = [string]$Project.CreatedAt
            corpus_section = [string]$Project.CorpusSection
            corpus_examples = @($Project.CorpusExamples)
            saved = (Get-Date).ToString('s')
            segments = $segs
            blocks = $blocks
        }
        $file = Join-Path $dir ([string]$Project.Id + '.json')
        Write-YakuJsonAtomic -Path $file -Value $record -Depth 10
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
                    Source = [string]$o.source
                    # ファイル型は元ファイルが残っていれば、出力時に読み直して
                    # 原文を再対応付けできる。無い場合だけ押す前に止める。
                    ExportBlocked = ([string]$o.source -ne 'text' -and -not (Test-Path -LiteralPath ([string]$o.path) -PathType Leaf))
                })
        } catch {
            try { Write-YakuLog ('CAT project unreadable, skipped. file=' + $f.Name) 'WARN' } catch {}
        }
    }
    return @($out.ToArray())
}

function ConvertFrom-YakuCatSavedSegmentsToBlocks {
    <#
      blocks を保存していなかった旧形式から、対応付けに必要な原文だけを戻す。
      番地は書き戻し先として使わない。新しく抽出したブロックを探す手掛かり。
    #>
    param([AllowNull()][object[]]$Segments)
    $blocks = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($s in @($Segments)) {
        $kind = [string]$s.Kind
        if ($kind -eq 'cell') {
            foreach ($cell in @($s.Cells)) {
                $id = [string]$cell.BlockId
                if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                [void]$blocks.Add([pscustomobject]@{
                    Id = $id
                    Text = [string]$cell.Text
                    Location = [string]$s.Location
                    Meta = [pscustomobject]@{
                        Kind = 'cell'; Sheet = [string]$s.Sheet
                        Row = [int]$cell.Row; Col = [int]$cell.Column
                        A1 = [string]$cell.Address
                    }
                })
            }
            continue
        }
        $ids = @($s.BlockIds)
        if ($ids.Count -ne 1) { continue }
        $id = [string]$ids[0]
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        [void]$blocks.Add([pscustomobject]@{
            Id = $id; Text = [string]$s.Text; Location = [string]$s.Location
            Meta = [pscustomobject]@{ Kind = $kind; Sheet = [string]$s.Sheet }
        })
    }
    return @($blocks.ToArray())
}

function Restore-YakuCatProject {
    <#
      保存したものをメモリへ戻す。保存時の原文ブロックは、出力時に
      現在の元ファイルから再抽出したブロックと対応付けるために使う。
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
                MaskedTranslation = [string]$s.masked_translation
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
    $savedBlocks = New-Object System.Collections.Generic.List[object]
    foreach ($b in @($o.blocks)) {
        if ($null -eq $b -or [string]::IsNullOrWhiteSpace([string]$b.id)) { continue }
        [void]$savedBlocks.Add([pscustomobject]@{
            Id = [string]$b.id; Text = [string]$b.text
            Location = [string]$b.location; Meta = $b.meta
        })
    }
    if ($savedBlocks.Count -eq 0) {
        foreach ($b in @(ConvertFrom-YakuCatSavedSegmentsToBlocks -Segments @($segments.ToArray()))) {
            [void]$savedBlocks.Add($b)
        }
    }
    $project = [pscustomobject]@{
        Id        = [string]$o.id
        Path      = [string]$o.path
        FileName  = [string]$o.file_name
        Direction = [string]$o.direction
        Blocks    = @($savedBlocks.ToArray())
        Segments  = @($segments.ToArray())
        Warnings  = @()
        Source    = [string]$o.source
        CreatedAt = [string]$o.created
        Restored  = $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$o.corpus_section)) {
        $project | Add-Member -NotePropertyName 'CorpusSection' -NotePropertyValue ([string]$o.corpus_section) -Force
        $project | Add-Member -NotePropertyName 'CorpusExamples' -NotePropertyValue @($o.corpus_examples) -Force
    }
    $script:YakuCatProjects[$project.Id] = $project
    $null = Apply-YakuCatBatchCheckpoint -Project $project
    return $project
}

function Get-YakuCatProject {
    param([Parameter(Mandatory=$true)][string]$Id)
    if (-not $script:YakuCatProjects.ContainsKey($Id)) { return $null }
    $project = $script:YakuCatProjects[$Id]
    $null = Apply-YakuCatBatchCheckpoint -Project $project
    return $project
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
    # 元ファイルが無ければ再抽出できない。存在する場合は、出力時に原文を
    # 再対応付けし、曖昧・欠落があればコピーを作る前に安全停止する。
    $exportBlocked = ([string]$Project.Source -ne 'text' -and -not (Test-Path -LiteralPath ([string]$Project.Path) -PathType Leaf))
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
            can_revise  = (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation) -and -not [string]::IsNullOrWhiteSpace([string]$segs[$i].MaskedTranslation))
            status      = Get-YakuCatSegmentStatus -Segment $segs[$i]
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
        # 出力できない状態かどうか。押す前に画面へ出す。
        export_blocked = [bool]$exportBlocked
        corpus_ready = $(try { -not [string]::IsNullOrWhiteSpace([string]$Project.CorpusSection) } catch { $false })
        corpus     = @($corpusRows.ToArray())
        file_name  = [string]$Project.FileName
        direction  = [string]$Project.Direction
        total      = [int]$summary.Total
        translated = [int]$summary.Translated
        remaining  = [int]$summary.Remaining
        joined     = [int]$summary.Joined
        confirmed   = [int]$summary.Confirmed
        unconfirmed = [int]$summary.Unconfirmed
        untranslated = @($segs | Where-Object { (Get-YakuCatSegmentStatus -Segment $_) -eq 'untranslated' }).Count
        glossary_candidates = $(try { [int]$Project.GlossaryCandidates } catch { 0 })
        draft        = @($segs | Where-Object { (Get-YakuCatSegmentStatus -Segment $_) -eq 'draft' }).Count
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

function Measure-YakuCatGlossaryCandidates {
    <#
      用語集で埋められる行が何行あるかを、置き換えずに数える。

      取り込んだ直後に勝手に置き換えるのは気味が悪い（利用者の指摘 2026-08-08）。
      市販ツールでも事前翻訳は名前の付いた作業で、設定が見えていて、
      押さなければ起きない。押す前に「何行が対象か」を見せる。
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
    if ($items.Count -eq 0) { return 0 }
    $map = @{}
    try { $null = Resolve-YakuFileExactGlossaryTranslations -Root $Root -Items @($items.ToArray()) -Direction ([string]$Project.Direction) -Settings $Settings -TranslationByIndex $map } catch { return 0 }
    return @($map.Keys).Count
}

function Get-YakuCatSegmentStatus {
    <#
      行の状態。市販ツールに倣って3つにする。

        未翻訳  訳が入っていない
        下訳    機械が入れた。人はまだ見ていない
        確定    人が見て、これでよいと決めた

      「訳が入っているか」と「人が見たか」は別物である。
      用語集で埋めた行も、目を通すまでは終わっていない。
    #>
    param([Parameter(Mandatory=$true)]$Segment)
    if ([bool]$Segment.Confirmed) { return 'confirmed' }
    if ([string]::IsNullOrWhiteSpace([string]$Segment.Translation)) { return 'untranslated' }
    return 'draft'
}

function Get-YakuCatCacheStyle {
    param([AllowNull()][string]$CorpusSection)
    $hash = 'none'
    if (-not [string]::IsNullOrWhiteSpace($CorpusSection)) {
        $hash = Get-YakuTextSha256 -Text $CorpusSection
    }
    return ('concise|corpus:' + $hash)
}

function ConvertTo-YakuCatCheckpointRows {
    <# マスク済みのバッチ結果をコピー上で実値へ戻し、Projectへ安全に
       突き合わせられる行へする。元itemsは後続バッチのため変更しない。 #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory=$true)]$Translations,
        [AllowNull()]$Warnings
    )
    $copies = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        $idx = [int]$item.Index
        if (-not $Translations.ContainsKey($idx)) { continue }
        $copies.Add([pscustomobject]@{
                Index = $idx; Text = [string]$item.Text
                OriginalText = [string]$item.OriginalText
                MaskedText = [string]$item.MaskedText
                NumericMaskMap = $item.NumericMaskMap; ProperMaskMap = $item.ProperMaskMap
                Targets = @($item.Targets); SegmentIndexes = @($item.SegmentIndexes)
            }) | Out-Null
    }
    $copyMap = @{}
    foreach ($copy in @($copies.ToArray())) { $copyMap[[int]$copy.Index] = [string]$Translations[[int]$copy.Index] }
    Restore-YakuCatItemTranslations -Items @($copies.ToArray()) -Map $copyMap -Warnings $Warnings
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($copy in @($copies.ToArray())) {
        $targets = @($copy.Targets)
        if ($targets.Count -eq 0) { $targets = @($copy.SegmentIndexes) }
        foreach ($target in $targets) {
            $rows.Add([ordered]@{
                    index = [int]$target; source = [string]$copy.OriginalText
                    text = [string]$copyMap[[int]$copy.Index]
                    masked = [string]$copy.MaskedTranslation
                }) | Out-Null
        }
    }
    return @($rows.ToArray())
}

function Get-YakuCatCopilotUsage {
    <# 画面の概算と実処理が同じ重複排除・マスク・キャッシュ・分割を使う。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Settings
    )
    $byText = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($segment in @($Project.Segments)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segment.Translation)) { continue }
        $text = [string]$segment.Text
        if ([string]::IsNullOrWhiteSpace($text) -or $byText.ContainsKey($text)) { continue }
        $item = [pscustomobject]@{ Index=($items.Count + 1); Text=$text; BlockIds=(New-Object System.Collections.Generic.List[string]) }
        $byText[$text] = $item; $items.Add($item) | Out-Null
    }
    $null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $Root -Direction ([string]$Project.Direction)
    $style = Get-YakuCatCacheStyle -CorpusSection ([string]$Project.CorpusSection)
    $pending = New-Object System.Collections.Generic.List[object]
    $hits = 0
    foreach ($item in @($items.ToArray())) {
        $key = Get-YakuTranslationCacheKey -Kind 'cat' -Direction ([string]$Project.Direction) -Text ([string]$item.Text) -Style $style -Root $Root -Settings $Settings
        $cached = Get-YakuTranslationCacheValue -Key $key -Settings $Settings
        if ($null -ne $cached -and -not (Test-YakuFileTranslationInvalid -Source ([string]$item.Text) -Translation ([string]$cached) -Direction ([string]$Project.Direction))) { $hits++ }
        else { $pending.Add($item) | Out-Null }
    }
    $maxChars = Get-YakuMaxCharsPerFileBatch -Settings $Settings
    $batches = @(Split-YakuFileTranslationItems -Items @($pending.ToArray()) -MaxChars $maxChars)
    $calls3h = 0; try { $calls3h = Get-YakuCopilotCallCount -WindowHours 3 } catch {}
    return [pscustomobject]@{
        UniqueRemaining = $items.Count; CacheHits = $hits; Pending = $pending.Count
        EstimatedCalls = $batches.Count; CallsLast3h = $calls3h; MaxChars = $maxChars
    }
}

function Protect-YakuCatItems {
    <#
      CAT が送る項目を、送信前に伏せる。

      **なぜ Project ではなく items を受け取るのか。**

      翻訳のジョブは別のランスペースで走るので、メモリ上のプロジェクトを
      触れない（Server.ps1 のコメント参照）。そのため Project を受け取る形の
      関数はジョブから呼べず、同じ処理が Server.ps1 の中に書き直されていた。
      そして**マスクは書き直された側に入っていなかった。**

      結果、2026-08-08 の時点で CAT の「残りを訳す」は実数値と人名を素のまま
      Copilot へ送っていた。「CAT 経路が数値をマスクせずに送っていたのを直した」
      という記録は誤りで、直した先は呼び出し元が0件の関数だった。
      統制テストも CatProject.ps1 の本文を grep していたので通っていた。

      同じ失敗を繰り返さないため、マスクは**items だけを受け取る形**にする。
      これならジョブからも、プロジェクトを持つ経路からも同じものを呼べる。

      順序は翻訳経路と同じ。単位変換 → 固有名詞 → 数値（住所の全角数字を
      数値マスクに取られないため）。表は項目へ持たせ、復元で使う。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Direction
    )
    $maskedItems = 0
    $properItems = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $text = [string]$item.Text
        $item | Add-Member -NotePropertyName OriginalText -NotePropertyValue $text -Force
        # CAT は一括翻訳の外側を通らず Invoke-YakuFileTranslationItems を直接
        # 呼ぶため、ここで単位変換を済ませる。先に数値を伏せると
        # 18万6千台 が [[N1]]万[[N2]]千台 に割れ、1つの数量へ戻せない。
        $numericPre = Convert-YakuNumericUnits -Text $text -Location ("cat-ID-" + [string]$item.Index)
        $text = [string]$numericPre.Text
        $properMap = $null
        if (Get-Command New-YakuProperNounMaskMap -ErrorAction SilentlyContinue) {
            $properResult = New-YakuProperNounMaskMap -Text $text -Root $Root
            $properMap = $properResult.Map
            $text = [string]$properResult.Text
            if ($null -ne $properMap -and $properMap.Count -gt 0) { $properItems++ }
        }
        $maskResult = New-YakuNumericMaskMap -Text $text -Root $Root -Direction $Direction -Location ("cat-ID-" + [string]$item.Index)
        $item | Add-Member -NotePropertyName ProperMaskMap -NotePropertyValue $properMap -Force
        $item | Add-Member -NotePropertyName NumericMaskMap -NotePropertyValue $maskResult.Map -Force
        $item | Add-Member -NotePropertyName MaskedText -NotePropertyValue ([string]$maskResult.Text) -Force
        $item.Text = [string]$maskResult.Text
        if ([int]$maskResult.MaskedCount -gt 0) { $maskedItems++ }
    }
    try { Write-YakuLog "CAT masking. items=$(@($Items).Count) maskedItems=$maskedItems properItems=$properItems" 'INFO' } catch {}
    return [pscustomobject]@{ MaskedItems = [int]$maskedItems; ProperItems = [int]$properItems }
}

function Restore-YakuCatItemTranslations {
    <#
      訳文の伏せ字を実値へ戻す。個数が合わなければ警告する。
      無言で数値や人名が消えるのを避ける。

      数値と固有名詞は別々に有無を見る。まとめて「マスクが無ければ次へ」と
      すると、数字を含まない行（「毛籠社長」）で固有名詞が戻らず、
      画面へ [[P1]] が出る。簡易翻訳側で実際に起きていた形である。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory=$true)]$Map,
        [AllowNull()]$Warnings
    )
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $idx = [int]$item.Index
        if (-not $Map.ContainsKey($idx)) { continue }
        $maskMap = $null
        try { $maskMap = $item.NumericMaskMap } catch { $maskMap = $null }
        $properMap = $null
        try { $properMap = $item.ProperMaskMap } catch { $properMap = $null }
        $hasNumeric = ($null -ne $maskMap -and $maskMap.Count -gt 0)
        $hasProper = ($null -ne $properMap -and $properMap.Count -gt 0)
        $translated = [string]$Map[$idx]
        # 修正の往復では、実値へ戻す前の訳文だけを Copilot へ送り返す。
        # 画面に出す実値入り訳文とは分けて、セグメントへ引き継げるよう残す。
        $item | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue $translated -Force
        if (-not $hasNumeric -and -not $hasProper) { continue }
        if ($hasNumeric) {
            try {
                $integrity = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$item.MaskedText) -Translated $translated -Location ("cat-ID-" + [string]$idx)
                if (-not [bool]$integrity.Ok -and $null -ne $Warnings) {
                    Add-YakuWarning -Warnings $Warnings -Location ("ID $idx") -Category 'numeric-mask-integrity' `
                        -Details @{ Detail = [string]$integrity.Detail } `
                        -Message "数値の個数が原文と一致しません。該当箇所の数値を必ずご確認ください。($([string]$integrity.Detail))"
                }
            } catch {}
            $translated = Restore-YakuNumericMask -Text $translated -Map $maskMap
            try { $item.Text = Restore-YakuNumericMask -Text ([string]$item.Text) -Map $maskMap } catch {}
        }
        if ($hasProper) {
            try {
                $pInt = Test-YakuProperNounMaskIntegrity -MaskedSource ([string]$item.MaskedText) -Translated $translated -Map $properMap
                if (-not [bool]$pInt.Ok -and $null -ne $Warnings) {
                    $lost = @(@($pInt.Missing) | ForEach-Object { [string]$properMap[[string]$_] })
                    Add-YakuWarning -Warnings $Warnings -Location ("ID $idx") -Category 'proper-noun-dropped' `
                        -Details @{ Missing = @($pInt.Missing) } `
                        -Message ("固有名詞が訳文から抜けています: " + (@($lost) -join '、') + "。必ずご確認ください。")
                }
            } catch {}
            $translated = Restore-YakuProperNounMask -Text $translated -Map $properMap
            try { $item.Text = Restore-YakuProperNounMask -Text ([string]$item.Text) -Map $properMap } catch {}
        }
        $Map[$idx] = $translated
    }
}

function Invoke-YakuCatCopilotPass {
    <#
      用語集で埋まらなかったセグメントを Copilot で訳す。

      同じ原文が何度出ても1回しか送らない。ファイル翻訳と同じ扱いである。
      既に訳が入っているものは送らない。

      **この関数はいま呼ばれていない。** 実際に走るのは Server.ps1 の
      ジョブ側（Kind='cat'）である。プロジェクトを受け取る形なので、
      別ランスペースのジョブから呼べないためである。
      残してあるのは、プロジェクトを直接持つ経路（回帰テスト）で使うため。
      マスクは Protect-YakuCatItems / Restore-YakuCatItemTranslations に
      切り出し、両方の経路が同じものを呼ぶようにした。
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

    $maxChars = Get-YakuMaxCharsPerFileBatch -Settings $Settings
    $cacheStyle = Get-YakuCatCacheStyle -CorpusSection ([string]$Project.CorpusSection)
    $context = @{ BatchOrdinal = 0; TotalBatches = 0; MaxRetryDepth = 0; CachePerBatch=$true; CacheKind='cat'; CacheStyle=$cacheStyle; CacheRoot=$Root }
    $batches = @(Split-YakuFileTranslationItems -Items @($items.ToArray()) -MaxChars $maxChars)
    $context['TotalBatches'] = [int]$batches.Count
    # 送る前に数値を伏せる。
    #
    # これは一括翻訳の経路（Invoke-YakuFileTranslation）にしか無く、CAT は
    # その内側の Invoke-YakuFileTranslationItems を直接呼んでいたため、
    # 実数値のまま Copilot へ送っていた（2026-08-08 に判明）。
    #
    # マスクと復元は Protect-YakuCatItems / Restore-YakuCatItemTranslations へ
    # 切り出した。ここに直接書いていたため、ジョブ側（Server.ps1）が同じ処理を
    # 書き直したときにマスクが落ち、それに気づけなかった。
    # 完全一致置換のあとにマスクする。先にマスクすると見出し語と一致しない。
    $null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $Root -Direction ([string]$Project.Direction)

    $map = Invoke-YakuFileTranslationItems -Root $Root -Items @($items.ToArray()) -Settings $Settings `
        -Direction ([string]$Project.Direction) -MaxChars $maxChars -Warnings $Warnings `
        -ProgressState $ProgressState -Context $context

    Restore-YakuCatItemTranslations -Items @($items.ToArray()) -Map $map -Warnings $Warnings
    $filled = 0
    foreach ($item in @($items.ToArray())) {
        $idx = [int]$item.Index
        if (-not $map.ContainsKey($idx)) { continue }
        $translation = [string]$map[$idx]
        if ([string]::IsNullOrWhiteSpace($translation)) { continue }
        foreach ($si in @($item.SegmentIndexes)) {
            $segs[[int]$si].Translation = $translation
            $segs[[int]$si] | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue ([string]$item.MaskedTranslation) -Force
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
                # 自分が確定した訳。そのまま差し込めるので先頭に置く。
                Weight   = 30000 + [int]([double]$tm.Ratio * 1000)
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
        # 読み込む一式が違うことがあり、Get-YakuCorpusSearchDir が見えないと
        # 対訳が丸ごと出なくなる。実機のログで気づいた（2026-08-07）。
        $pairsDir = [string]$PairsDir
        if ([string]::IsNullOrWhiteSpace($pairsDir)) { $pairsDir = Get-YakuCorpusSearchDir }
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
                # 会社が公表した言い方。倣う値打ちがあるが、自分の確定訳には劣る。
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
    $translation = [string]$Text
    $hasTranslation = -not [string]::IsNullOrWhiteSpace($translation)
    $segs[$Index].Translation = $translation
    # 人が書き換えた訳文は、以前のマスク後訳文ともう対応しない。
    $segs[$Index] | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue '' -Force
    $segs[$Index].Origin = $(if ($hasTranslation) { 'manual' } else { '' })
    # 手で直したものは、その時点で人が見たということなので確定にする。
    # ただし空に戻した行は未翻訳であり、確認済みにはできない。
    if ($segs[$Index].PSObject.Properties.Name -contains 'Confirmed') { $segs[$Index].Confirmed = $hasTranslation }
    else { $segs[$Index] | Add-Member -NotePropertyName 'Confirmed' -NotePropertyValue $hasTranslation -Force }
    # 確定した訳を翻訳メモリへ貯める。次に同じ文が来たら候補に出る。
    # 市販ツールの Ctrl+Enter と同じ作法で、確定＝記憶にする。
    # 失敗しても訳の確定は妨げない。貯め損ねより、直せないほうが困る。
    if ($hasTranslation) {
        try {
            $null = Add-YakuTranslationMemoryEntry -Source ([string]$segs[$Index].Text) -Target $translation `
                -Direction ([string]$Project.Direction) -Origin 'cat'
        } catch {
            try { Write-YakuLog ('Translation memory save failed: ' + $_.Exception.Message) 'WARN' } catch {}
        }
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

function ConvertTo-YakuCatBlockMatchKey {
    <# 同じ原文ブロックかを比べる鍵。番地は意図的に含めない。 #>
    param([AllowNull()]$Block)
    if ($null -eq $Block) { return '' }
    $kind = ''; $text = ''
    try { $kind = [string]$Block.Meta.Kind } catch { $kind = '' }
    try { $text = [string]$Block.Text } catch { $text = '' }
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    try { $text = $text.Normalize([Text.NormalizationForm]::FormKC) } catch {}
    $text = [regex]::Replace($text.Trim(), '\s+', ' ').ToLowerInvariant()
    return ($kind.ToLowerInvariant() + [char]31 + $text)
}

function Get-YakuCatBlockSheet {
    param([AllowNull()]$Block)
    try { return [string]$Block.Meta.Sheet } catch { return '' }
}

function Get-YakuCatSheetCodeName {
    param([AllowNull()][object[]]$Blocks, [AllowNull()][string]$Sheet)
    foreach ($block in @($Blocks)) {
        if ((Get-YakuCatBlockSheet $block) -ne [string]$Sheet) { continue }
        try {
            $code = [string]$block.Meta.SheetCodeName
            if (-not [string]::IsNullOrWhiteSpace($code)) { return $code }
        } catch {}
    }
    return ''
}

function Test-YakuCatSourceTextExact {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    # Excelの改行表現だけを揃える。大小文字・全半角・空白は意味を変え得るので
    # NFKCやTrimをせず、保存時と現在値のOrdinal一致を最終門にする。
    $a = ([string]$Left).Replace("`r`n", "`n").Replace("`r", "`n")
    $b = ([string]$Right).Replace("`r`n", "`n").Replace("`r", "`n")
    return [string]::Equals($a, $b, [StringComparison]::Ordinal)
}

function Get-YakuCatUniqueBlockPairs {
    <# 両側で一度だけ現れる原文を錨候補にする。 #>
    param([AllowNull()][object[]]$Left, [AllowNull()][object[]]$Right)
    $l = @($Left); $r = @($Right)
    $lc = @{}; $rc = @{}; $li = @{}; $ri = @{}
    for ($i = 0; $i -lt $l.Count; $i++) {
        $k = ConvertTo-YakuCatBlockMatchKey -Block $l[$i]
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $lc.ContainsKey($k)) { $lc[$k] = 0 }
        $lc[$k]++; $li[$k] = $i
    }
    for ($i = 0; $i -lt $r.Count; $i++) {
        $k = ConvertTo-YakuCatBlockMatchKey -Block $r[$i]
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $rc.ContainsKey($k)) { $rc[$k] = 0 }
        $rc[$k]++; $ri[$k] = $i
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($k in $lc.Keys) {
        if ([int]$lc[$k] -ne 1 -or -not $rc.ContainsKey($k) -or [int]$rc[$k] -ne 1) { continue }
        [void]$pairs.Add([pscustomobject]@{ Key = $k; L = [int]$li[$k]; R = [int]$ri[$k] })
    }
    return @(@($pairs.ToArray()) | Sort-Object -Property L)
}

function Resolve-YakuCatExportBlocks {
    <#
      取り込み時と現在の原文ブロックを対応付ける純粋関数。

      一意な原文を錨にし、CellAlign.ps1 と同じ最長増加部分列で順序が
      保たれる錨だけを採る。重複原文は錨に挟まれた区間内で一意な場合だけ
      対応付ける。決められないものを旧番地で推測することはしない。
    #>
    param(
        [AllowNull()][object[]]$OriginalBlocks,
        [AllowNull()][object[]]$CurrentBlocks,
        [AllowNull()][string[]]$RequiredBlockIds
    )
    if (-not (Get-Command Get-YakuLongestIncreasingPairs -ErrorAction SilentlyContinue)) {
        throw 'CAT_EXPORT_ALIGN_UNAVAILABLE: 原文再対応付けの部品を読み込めませんでした。'
    }
    $old = @($OriginalBlocks); $cur = @($CurrentBlocks)
    $required = @{}
    foreach ($id in @($RequiredBlockIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { $required[[string]$id] = $true }
    }
    $errors = New-Object System.Collections.Generic.List[string]
    $map = @{}; $usedCurrent = @{}; $sheetMatches = @{}
    $oldSheets = New-Object System.Collections.Generic.List[string]
    $curSheets = New-Object System.Collections.Generic.List[string]
    foreach ($b in $old) { $s = Get-YakuCatBlockSheet $b; if (-not $oldSheets.Contains($s)) { [void]$oldSheets.Add($s) } }
    foreach ($b in $cur) { $s = Get-YakuCatBlockSheet $b; if (-not $curSheets.Contains($s)) { [void]$curSheets.Add($s) } }
    $usedSheets = @{}

    # 同名シートを先に確定する。
    foreach ($s in @($oldSheets.ToArray())) {
        if (-not $curSheets.Contains($s)) { continue }
        $oldCode = Get-YakuCatSheetCodeName -Blocks $old -Sheet $s
        $newCode = Get-YakuCatSheetCodeName -Blocks $cur -Sheet $s
        if (-not [string]::IsNullOrWhiteSpace($oldCode) -and -not [string]::IsNullOrWhiteSpace($newCode) -and $oldCode -ne $newCode) { continue }
        $sheetMatches[$s] = $s; $usedSheets[$s] = $true
    }
    # 改名されたシートはまず Worksheet.CodeName で追う。Excel環境によって
    # CodeNameが空の場合だけ、両側のほぼ全原文が同じ順序にある候補へ限定する。
    foreach ($s in @($oldSheets.ToArray())) {
        if ($sheetMatches.ContainsKey($s)) { continue }
        $oldCode = Get-YakuCatSheetCodeName -Blocks $old -Sheet $s
        if (-not [string]::IsNullOrWhiteSpace($oldCode)) {
            $matches = New-Object System.Collections.Generic.List[string]
            foreach ($t in @($curSheets.ToArray())) {
                if ($usedSheets.ContainsKey($t)) { continue }
                if ((Get-YakuCatSheetCodeName -Blocks $cur -Sheet $t) -eq $oldCode) { [void]$matches.Add($t) }
            }
            if ($matches.Count -eq 1) {
                $sheetMatches[$s] = [string]$matches[0]; $usedSheets[[string]$matches[0]] = $true
            }
            continue
        }
        $left = @($old | Where-Object { (Get-YakuCatBlockSheet $_) -eq $s })
        $fallback = New-Object System.Collections.Generic.List[object]
        foreach ($t in @($curSheets.ToArray())) {
            if ($usedSheets.ContainsKey($t)) { continue }
            $right = @($cur | Where-Object { (Get-YakuCatBlockSheet $_) -eq $t })
            $ordered = @(Get-YakuLongestIncreasingPairs -Pairs @(Get-YakuCatUniqueBlockPairs -Left $left -Right $right))
            $leftCoverage = $ordered.Count / [double][Math]::Max(1, $left.Count)
            $rightCoverage = $ordered.Count / [double][Math]::Max(1, $right.Count)
            if ($ordered.Count -ge 3 -and $leftCoverage -ge 0.8 -and $rightCoverage -ge 0.8) {
                [void]$fallback.Add([pscustomobject]@{ Sheet=$t; Score=$ordered.Count })
            }
        }
        $ranked = @($fallback.ToArray() | Sort-Object -Property Score -Descending)
        if ($ranked.Count -eq 1 -or ($ranked.Count -gt 1 -and [int]$ranked[0].Score -gt [int]$ranked[1].Score)) {
            $picked = [string]$ranked[0].Sheet
            $sheetMatches[$s] = $picked; $usedSheets[$picked] = $true
        }
    }

    foreach ($s in @($oldSheets.ToArray())) {
        $leftAll = @($old | Where-Object { (Get-YakuCatBlockSheet $_) -eq $s })
        $neededHere = @($leftAll | Where-Object { $required.ContainsKey([string]$_.Id) })
        if ($neededHere.Count -eq 0) { continue }
        if (-not $sheetMatches.ContainsKey($s)) {
            foreach ($b in $neededHere) { [void]$errors.Add(('sheet-missing-or-ambiguous: ' + [string]$b.Id + ' / ' + $s)) }
            continue
        }
        $targetSheet = [string]$sheetMatches[$s]
        $rightAll = @($cur | Where-Object { (Get-YakuCatBlockSheet $_) -eq $targetSheet })
        $candidates = @(Get-YakuCatUniqueBlockPairs -Left $leftAll -Right $rightAll)
        $anchors = @(Get-YakuLongestIncreasingPairs -Pairs $candidates)
        $anchorByLeft = @{}
        foreach ($a in $anchors) { $anchorByLeft[[int]$a.L] = $a }

        foreach ($b in $neededHere) {
            $oldIndex = [array]::IndexOf($leftAll, $b)
            if ($oldIndex -lt 0) { [void]$errors.Add(('source-missing: ' + [string]$b.Id)); continue }
            $newIndex = -1
            if ($anchorByLeft.ContainsKey($oldIndex)) {
                $newIndex = [int]$anchorByLeft[$oldIndex].R
            } else {
                $prevL = -1; $prevR = -1; $nextL = $leftAll.Count; $nextR = $rightAll.Count
                foreach ($a in $anchors) {
                    if ([int]$a.L -lt $oldIndex) { $prevL = [int]$a.L; $prevR = [int]$a.R; continue }
                    if ([int]$a.L -gt $oldIndex) { $nextL = [int]$a.L; $nextR = [int]$a.R; break }
                }
                $key = ConvertTo-YakuCatBlockMatchKey -Block $b
                $oldHits = @(); $newHits = @()
                for ($i = $prevL + 1; $i -lt $nextL; $i++) {
                    if ((ConvertTo-YakuCatBlockMatchKey -Block $leftAll[$i]) -eq $key) { $oldHits += $i }
                }
                for ($i = $prevR + 1; $i -lt $nextR; $i++) {
                    if ((ConvertTo-YakuCatBlockMatchKey -Block $rightAll[$i]) -eq $key) { $newHits += $i }
                }
                if ($oldHits.Count -eq 1 -and $newHits.Count -eq 1) { $newIndex = [int]$newHits[0] }
            }
            if ($newIndex -lt 0 -or $newIndex -ge $rightAll.Count) {
                [void]$errors.Add(('source-missing-or-ambiguous: ' + [string]$b.Id + ' / ' + [string]$b.Location + ' / ' + [string]$b.Text))
                continue
            }
            $currentBlock = $rightAll[$newIndex]
            $currentId = [string]$currentBlock.Id
            if ($usedCurrent.ContainsKey($currentId)) {
                [void]$errors.Add(('current-block-reused: ' + [string]$b.Id + ' -> ' + $currentId))
                continue
            }
            # 書込直前の最後の門。対応付け結果でも原文が一致しなければ使わない。
            if (-not (Test-YakuCatSourceTextExact -Left ([string]$b.Text) -Right ([string]$currentBlock.Text))) {
                [void]$errors.Add(('source-changed: ' + [string]$b.Id + ' / ' + [string]$b.Text))
                continue
            }
            $usedCurrent[$currentId] = $true
            $map[[string]$b.Id] = $currentBlock
        }
    }
    foreach ($id in $required.Keys) {
        if (-not $map.ContainsKey($id) -and @($errors | Where-Object { $_ -match ('(^|: )' + [regex]::Escape($id) + '( /| ->|$)') }).Count -eq 0) {
            [void]$errors.Add(('snapshot-missing: ' + $id))
        }
    }
    return [pscustomobject]@{
        Success = ($errors.Count -eq 0)
        Map = $map
        Errors = @($errors.ToArray())
        SheetMatches = $sheetMatches
    }
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
    if (-not (Test-Path -LiteralPath ([string]$Project.Path) -PathType Leaf)) {
        throw 'CAT_EXPORT_SOURCE_MISSING: 元の Excel が見つかりません。移動または削除されていないか確認してください。'
    }
    $originalBlocks = @($Project.Blocks)
    if ($originalBlocks.Count -eq 0) {
        $originalBlocks = @(ConvertFrom-YakuCatSavedSegmentsToBlocks -Segments $segs)
    }
    $hashBefore = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    $currentExtract = Get-YakuExcelTextBlocks -Path ([string]$Project.Path) -Direction ([string]$Project.Direction) `
        -Settings $Settings -ProgressState $ProgressState
    $hashAfter = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    if ($hashBefore -ne $hashAfter) {
        throw 'CAT_EXPORT_SOURCE_CHANGED_DURING_READ: 原文を確認している間に元の Excel が変更されました。もう一度出力してください。'
    }
    foreach ($w in @($currentExtract.Warnings)) { try { [void]$Warnings.Add($w) } catch {} }
    $resolved = Resolve-YakuCatExportBlocks -OriginalBlocks $originalBlocks -CurrentBlocks @($currentExtract.Blocks) `
        -RequiredBlockIds @($byBlock.Keys)
    if (-not [bool]$resolved.Success) {
        throw ('CAT_EXPORT_SOURCE_MISMATCH: 元の Excel で行・シートの対応を一意に確認できませんでした。誤ったセルへの書き込みを防ぐため出力を中止しました。' + `
            ' 詳細: ' + (@($resolved.Errors) -join '; '))
    }
    $currentByBlock = @{}
    foreach ($oldId in @($byBlock.Keys)) {
        $newBlock = $resolved.Map[[string]$oldId]
        $currentByBlock[[string]$newBlock.Id] = [string]$byBlock[$oldId]
    }
    Copy-Item -LiteralPath ([string]$Project.Path) -Destination $OutputPath -Force
    Clear-YakuOutputReadOnlyAttribute -Path $OutputPath
    $copiedHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
    if ($copiedHash -ne $hashAfter) {
        throw 'CAT_EXPORT_SOURCE_CHANGED_BEFORE_COPY: 元の Excel が出力直前に変更されました。訳文はまだ書き込んでいません。もう一度出力してください。'
    }
    $null = Write-YakuExcelTranslations -OutputPath $OutputPath -Blocks @($currentExtract.Blocks) `
        -TranslationByBlockId $currentByBlock -Warnings $Warnings -Settings $Settings -ProgressState $ProgressState
    return [pscustomobject]@{
        OutputPath = $OutputPath
        OutputName = [System.IO.Path]::GetFileName($OutputPath)
        Written    = $currentByBlock.Count
        Skipped    = (@($segs).Count - $bySegment.Count)
    }
}
