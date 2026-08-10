<#
  翻訳メモリ。利用者自身が確定した訳を貯める。

  候補ペインの3本柱のうち、これが最後の1本になる。

    用語集      語の対応。人が育てる
    過去の対訳  公表訳から機械で取った対応。意訳が多く、そのままは使いにくい
    翻訳メモリ  自分が確定した訳。そのまま差し込める

  一番効くのはこれである。公表訳は「読ませる訳」なので直訳では当たらないが、
  翻訳メモリは自分の文体で、自分が正しいと判断したものだけが入る。

  置き場所は個人ごと。利用者の説明（2026-08-06）に従う。
  「tm の置き場所は基本的には個人で持つのが運用的にもセキュリティ的にも良い。
   ただし開発者や部署の代表者が作成して配布ということもありうる」
  配布はあとから足せるよう、読み取り先を複数持てる形にしておく。

  形式は対訳コーパスと同じ JSONL。1行1対で追記だけで済み、
  壊れた行があってもその行だけ捨てれば残りは読める。
#>

function Get-YakuTranslationMemoryPath {
    param([ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en')
    $dir = Get-YakuSubDir 'memory'
    return (Join-Path $dir ('tm-' + $Direction + '.jsonl'))
}

function ConvertTo-YakuTranslationMemoryKey {
    <#
      同じ原文とみなす鍵。空白の違いと全角半角の揺れを吸収する。
      表記が少し違うだけで別物として貯まると、候補が重複して読みにくい。
    #>
    param([AllowNull()][string]$Text)
    $s = ([string]$Text) -replace '\s+', ''
    $full = '０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ．，％（）'
    $half = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.,%()"
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $i = $full.IndexOf($ch)
        if ($i -ge 0) { $null = $sb.Append($half[$i]) } else { $null = $sb.Append($ch) }
    }
    return $sb.ToString().ToLowerInvariant()
}

function Get-YakuTranslationMemoryHash {
    param([AllowNull()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-YakuTranslationMemoryReferenceId {
    param(
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginFileName,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][string]$OriginLocation,
        [Parameter(Mandatory=$true)][int]$OriginPage,
        [Parameter(Mandatory=$true)][int]$ReviewRevision,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][string]$SourceHash,
        [Parameter(Mandatory=$true)][string]$TargetHash
    )
    $separator = [string][char]31
    return (Get-YakuTranslationMemoryHash -Text ('tm-v2' + $separator + $OriginProjectId + $separator +
            $OriginFileName + $separator + $OriginSegmentId + $separator + $OriginLocation + $separator +
            [string]$OriginPage + $separator + [string]$ReviewRevision + $separator + $Direction + $separator +
            $SourceHash + $separator + $TargetHash))
}

function Test-YakuTranslationMemoryProvenance {
    <#
      候補として挿入できるTM行かを検査する。旧形式や出典の欠けた行は読み込み
      自体は妨げないが、候補には出さない。内容を書き換えたJSONL行もハッシュと
      reference_idの再計算で拒否する。
    #>
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return $false }
    if ([int]$Entry.schema_version -ne 2) { return $false }
    $projectId = [string]$Entry.origin_project_id
    $segmentId = [string]$Entry.origin_segment_id
    $fileName = [string]$Entry.origin_file_name
    $location = [string]$Entry.origin_location
    $source = [string]$Entry.source
    $target = [string]$Entry.target
    $sourceHash = [string]$Entry.source_hash
    $targetHash = [string]$Entry.target_hash
    $direction = [string]$Entry.direction
    $revision = 0
    try { $revision = [int]$Entry.review_revision } catch { return $false }
    $page = 0
    try { $page = [int]$Entry.origin_page } catch { return $false }
    if ($projectId -notmatch '^[a-f0-9]{32}$' -or $segmentId -notmatch '^[a-f0-9]{32}$') { return $false }
    if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($location)) { return $false }
    if ($revision -lt 1 -or $page -lt 0) { return $false }
    if ($sourceHash -notmatch '^[a-f0-9]{64}$' -or $targetHash -notmatch '^[a-f0-9]{64}$') { return $false }
    if ($direction -notin @('to_en', 'to_jp')) { return $false }
    if ([string]$Entry.key -ne (ConvertTo-YakuTranslationMemoryKey -Text $source)) { return $false }
    if ($sourceHash -ne (Get-YakuTranslationMemoryHash -Text $source)) { return $false }
    if ($targetHash -ne (Get-YakuTranslationMemoryHash -Text $target)) { return $false }
    $expectedReferenceId = Get-YakuTranslationMemoryReferenceId -OriginProjectId $projectId -OriginFileName $fileName `
        -OriginSegmentId $segmentId -OriginLocation $location -OriginPage $page -ReviewRevision $revision `
        -Direction $direction -SourceHash $sourceHash -TargetHash $targetHash
    return ([string]$Entry.reference_id -eq $expectedReferenceId)
}

function Read-YakuTranslationMemory {
    <#
      壊れた行は黙って捨てる。1行の破損で全部読めなくなるほうが困る。
      同じ原文が何度も確定された場合は、あとの行が前の行を上書きする。
      追記だけで「直した」を表せるようにするため。
    #>
    param(
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [AllowNull()][string]$Path
    )
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $map }
    $broken = 0
    foreach ($line in [IO.File]::ReadAllLines($target, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json
            $k = [string]$o.key
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            $map[$k] = $o
        } catch { $broken++ }
    }
    if ($broken -gt 0) { try { Write-YakuLog "Translation memory had unreadable lines. broken=$broken" 'WARN' } catch {} }
    return $map
}

function Add-YakuTranslationMemoryEntry {
    <#
      確定した訳を1件貯める。原文か訳文が空なら何もしない。
      同じ内容が既にあるなら書かない。押すたびに同じ行が増えないように。
    #>
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target,
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [string]$Origin = 'manual',
        [AllowNull()][string]$OriginProjectId,
        [AllowNull()][string]$OriginFileName,
        [AllowNull()][string]$OriginSegmentId,
        [AllowNull()][string]$OriginLocation,
        [int]$OriginPage = 0,
        [int]$ReviewRevision = 0,
        [AllowNull()][string]$Path
    )
    $src = ([string]$Source).Trim()
    $tgt = ([string]$Target).Trim()
    if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) {
        return [pscustomobject]@{ Added = $false; Reason = 'empty' }
    }
    $projectId = ([string]$OriginProjectId).Trim().ToLowerInvariant()
    $fileName = ([string]$OriginFileName).Trim()
    $segmentId = ([string]$OriginSegmentId).Trim().ToLowerInvariant()
    $location = ([string]$OriginLocation).Trim()
    if ($projectId -notmatch '^[a-f0-9]{32}$' -or $segmentId -notmatch '^[a-f0-9]{32}$' -or
        [string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($location) -or
        $OriginPage -lt 0 -or $ReviewRevision -lt 1) {
        return [pscustomobject]@{ Added = $false; Reason = 'provenance-required' }
    }
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $key = ConvertTo-YakuTranslationMemoryKey -Text $src
    $sourceHash = Get-YakuTranslationMemoryHash -Text $src
    $targetHash = Get-YakuTranslationMemoryHash -Text $tgt
    $referenceId = Get-YakuTranslationMemoryReferenceId -OriginProjectId $projectId -OriginFileName $fileName `
        -OriginSegmentId $segmentId -OriginLocation $location -OriginPage $OriginPage -ReviewRevision $ReviewRevision `
        -Direction $Direction -SourceHash $sourceHash -TargetHash $targetHash
    $fullTarget = [IO.Path]::GetFullPath($target)
    $lockKey = (Get-YakuTranslationMemoryHash -Text $fullTarget).Substring(0, 24)
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.TranslationMemory.' + $lockKey))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'TRANSLATION_MEMORY_LOCK_TIMEOUT' }
        $existing = Read-YakuTranslationMemory -Direction $Direction -Path $target
        if ($existing.Contains($key) -and [string]$existing[$key].target -eq $tgt -and
            (Test-YakuTranslationMemoryProvenance -Entry $existing[$key]) -and
            [string]$existing[$key].reference_id -eq $referenceId) {
            return [pscustomobject]@{ Added = $false; Reason = 'same'; Key = $key; ReferenceId = $referenceId }
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $record = [ordered]@{
            schema_version    = 2
            key               = $key
            source            = $src
            target            = $tgt
            direction         = $Direction
            origin            = $Origin
            reference_id      = $referenceId
            origin_project_id = $projectId
            origin_file_name  = $fileName
            origin_segment_id = $segmentId
            origin_location   = $location
            origin_page       = [int]$OriginPage
            source_hash       = $sourceHash
            target_hash       = $targetHash
            review_revision   = [int]$ReviewRevision
            saved             = (Get-Date).ToString('s')
        }
        [IO.File]::AppendAllLines($target, [string[]]@(($record | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Added = $true; Reason = $(if ($existing.Contains($key)) { 'updated' } else { 'new' }); Key = $key; ReferenceId = $referenceId }
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Find-YakuTranslationMemory {
    <#
      原文セグメント1本に対して、過去に自分が確定した訳を探す。

      完全一致を最優先にする。市販ツールが 100% 一致を別格に扱うのと同じで、
      同じ文を二度違う訳にしないことが一貫性の中身だからである。
      部分一致は文字数の比で一致率を出す。編集距離のほうが精確だが、
      行を移るたびに全件へ掛けると重い。まず動く形を置く。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [int]$Limit = 5,
        [int]$MinLength = 4,
        [AllowNull()][string]$Path
    )
    $t = ([string]$Text).Trim()
    if ($t.Length -lt $MinLength) { return @() }
    $entries = Read-YakuTranslationMemory -Direction $Direction -Path $Path
    if ($entries.Count -eq 0) { return @() }
    $tn = ConvertTo-YakuTranslationMemoryKey -Text $t
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($k in $entries.Keys) {
        $e = $entries[$k]
        # 出典が追跡できない旧形式、または内容と証明が一致しない行は表示も
        # 挿入もさせない。移行時に「翻訳メモリ」とだけ見せるのは誤誘導になる。
        if (-not (Test-YakuTranslationMemoryProvenance -Entry $e)) { continue }
        $sn = [string]$k
        if ($sn.Length -lt $MinLength) { continue }
        $exact = [string]::Equals($sn, $tn, [StringComparison]::Ordinal)
        if ($exact) { $ratio = 1.0 }
        elseif ($sn.IndexOf($tn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$tn.Length / $sn.Length }
        elseif ($tn.IndexOf($sn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$sn.Length / $tn.Length }
        else { continue }
        if ($ratio -lt 0.3) { continue }
        [void]$hits.Add([pscustomobject]@{
                Source = [string]$e.source
                Target = [string]$e.target
                Exact  = $exact
                Ratio  = $ratio
                Saved  = [string]$e.saved
                ReferenceId = [string]$e.reference_id
                SourceName = [string]$e.origin_file_name
                Location = [string]$e.origin_location
                Page = [int]$e.origin_page
                OriginProjectId = [string]$e.origin_project_id
                OriginSegmentId = [string]$e.origin_segment_id
                ReviewRevision = [int]$e.review_revision
                SourceHash = [string]$e.source_hash
                TargetHash = [string]$e.target_hash
            })
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Ratio -Descending | Select-Object -First $Limit)
}
