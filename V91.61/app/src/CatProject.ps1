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
        })
    }
    $summary = Get-YakuCatProjectSummary -Project $Project
    return ([ordered]@{
        id         = [string]$Project.Id
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
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [AllowNull()]$Settings,
        [AllowNull()]$Warnings,
        [AllowNull()]$ProgressState
    )
    if ($null -eq $Warnings) { $Warnings = New-Object System.Collections.Generic.List[object] }
    $segs = @($Project.Segments)
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
