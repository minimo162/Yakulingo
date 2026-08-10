<#
  翻訳メモリ。利用者自身が確認したセグメント訳を、出典付きで再利用する。

  用語集は語・短い表現、翻訳メモリはセグメント全体を扱う。翻訳メモリの
  候補を挿入しても確認済み状態は継承せず、現在のセグメントで再確認する。

  保存形式は追記専用 JSONL。schema v3 は原文ではなく、確認元projectと
  segmentから作る unit_id を同一翻訳単位の識別子にする。同じ原文に複数の
  確認訳があっても別unitとして残り、訂正は同unitの新しいupsert、撤回は
  tombstoneで表す。schema v2は読み取り互換を保つ。
#>

function Get-YakuTranslationMemoryPath {
    param([ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en')
    $dir = Get-YakuSubDir 'memory'
    return (Join-Path $dir ('tm-' + $Direction + '.jsonl'))
}

function ConvertTo-YakuTranslationMemoryKey {
    <# 空白、英数字の全角半角、英字大小を検索用に正規化する。 #>
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

function Get-YakuTranslationMemoryUnitId {
    param(
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    $separator = [string][char]31
    return (Get-YakuTranslationMemoryHash -Text ('tm-unit-v3' + $separator +
            $OriginProjectId.ToLowerInvariant() + $separator + $OriginSegmentId.ToLowerInvariant() + $separator + $Direction))
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

function Get-YakuTranslationMemoryEventId {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('upsert','tombstone')][string]$EventType,
        [Parameter(Mandatory=$true)][string]$UnitId,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)][int]$ReviewRevision,
        [string]$ReferenceId = '',
        [string]$Reason = ''
    )
    $separator = [string][char]31
    return (Get-YakuTranslationMemoryHash -Text ('tm-event-v3' + $separator + $EventType + $separator +
            $UnitId + $separator + $Direction + $separator + [string]$ReviewRevision + $separator +
            $ReferenceId + $separator + $Reason))
}

function Resolve-YakuTranslationMemoryRecordUnitId {
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return '' }
    $projectId = [string]$Entry.origin_project_id
    $segmentId = [string]$Entry.origin_segment_id
    $direction = [string]$Entry.direction
    if ($projectId -notmatch '^[a-f0-9]{32}$' -or $segmentId -notmatch '^[a-f0-9]{32}$' -or
        $direction -notin @('to_en','to_jp')) { return '' }
    return (Get-YakuTranslationMemoryUnitId -OriginProjectId $projectId -OriginSegmentId $segmentId -Direction $direction)
}

function Test-YakuTranslationMemoryProvenance {
    <# v2/v3 upsertの本文、出典、識別子が一体であることを検査する。 #>
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return $false }
    $schema = 0
    try { $schema = [int]$Entry.schema_version } catch { return $false }
    if ($schema -notin @(2,3)) { return $false }
    if ($schema -eq 3 -and [string]$Entry.event_type -ne 'upsert') { return $false }
    $projectId = [string]$Entry.origin_project_id
    $segmentId = [string]$Entry.origin_segment_id
    $fileName = [string]$Entry.origin_file_name
    $location = [string]$Entry.origin_location
    $source = [string]$Entry.source
    $target = [string]$Entry.target
    $sourceHash = [string]$Entry.source_hash
    $targetHash = [string]$Entry.target_hash
    $direction = [string]$Entry.direction
    try { $revision = [int]$Entry.review_revision } catch { return $false }
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
    if ([string]$Entry.reference_id -ne $expectedReferenceId) { return $false }
    if ($schema -eq 3) {
        $unitId = Resolve-YakuTranslationMemoryRecordUnitId -Entry $Entry
        if ([string]$Entry.unit_id -ne $unitId) { return $false }
        $expectedEventId = Get-YakuTranslationMemoryEventId -EventType 'upsert' -UnitId $unitId `
            -Direction $direction -ReviewRevision $revision -ReferenceId $expectedReferenceId
        if ([string]$Entry.event_id -ne $expectedEventId) { return $false }
    }
    return $true
}

function Test-YakuTranslationMemoryTombstone {
    param([AllowNull()]$Entry)
    if ($null -eq $Entry -or [int]$Entry.schema_version -ne 3 -or [string]$Entry.event_type -ne 'tombstone') { return $false }
    $unitId = Resolve-YakuTranslationMemoryRecordUnitId -Entry $Entry
    if ([string]::IsNullOrWhiteSpace($unitId) -or [string]$Entry.unit_id -ne $unitId) { return $false }
    try { $revision = [int]$Entry.review_revision } catch { return $false }
    if ($revision -lt 1) { return $false }
    $reason = [string]$Entry.reason
    if ([string]::IsNullOrWhiteSpace($reason)) { return $false }
    $expected = Get-YakuTranslationMemoryEventId -EventType 'tombstone' -UnitId $unitId `
        -Direction ([string]$Entry.direction) -ReviewRevision $revision -Reason $reason
    return ([string]$Entry.event_id -eq $expected)
}

function Read-YakuTranslationMemory {
    <#
      active eventをunit_idごとに返す。後のupsert/tombstoneが同unitの前行を
      上書きする。壊れた行は捨て、改ざんされたv3行はそのunitを候補から閉じる。
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
            $schema = 0
            try { $schema = [int]$o.schema_version } catch { $schema = 0 }
            $unitId = Resolve-YakuTranslationMemoryRecordUnitId -Entry $o
            if ($schema -eq 3) {
                # unit_id自体だけを書き換えても、出典から導いたunitへfail-closedにする。
                if ([string]::IsNullOrWhiteSpace($unitId)) { $unitId = 'invalid:' + (Get-YakuTranslationMemoryHash -Text $line) }
                $map[$unitId] = $o
                continue
            }
            if ($schema -eq 2 -and -not [string]::IsNullOrWhiteSpace($unitId)) {
                $map[$unitId] = $o
                continue
            }
            # 出典の無い旧形式は移行調査のため読めるが、Findでは候補にしない。
            $key = [string]$o.key
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $map['legacy:' + (Get-YakuTranslationMemoryHash -Text ($key + [string][char]31 + [string]$o.target))] = $o
        } catch { $broken++ }
    }
    if ($broken -gt 0) { try { Write-YakuLog "Translation memory had unreadable lines. broken=$broken" 'WARN' } catch {} }
    return $map
}

function Test-YakuTranslationMemoryEventExists {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$EventId
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (-not (Get-Variable -Name YakuTranslationMemoryEventCache -Scope Script -ErrorAction SilentlyContinue)) {
        $script:YakuTranslationMemoryEventCache = @{}
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $info = Get-Item -LiteralPath $fullPath
    $fingerprint = ([string]$info.Length + '|' + [string]$info.LastWriteTimeUtc.Ticks)
    $cached = $null
    if ($script:YakuTranslationMemoryEventCache.ContainsKey($fullPath)) {
        $candidate = $script:YakuTranslationMemoryEventCache[$fullPath]
        if ([string]$candidate.Fingerprint -eq $fingerprint) { $cached = $candidate }
    }
    if ($null -ne $cached) { return [bool]$cached.EventIds.Contains($EventId) }

    # outboxは確認済み行の数だけ増える。同期間隔ごとにeventごと全JSONLを
    # 読むと二乗になるため、同じファイル世代のevent IDを1回だけ索引化する。
    # lengthとmtimeはTM mutexの内側で取得しており、他processの追記も次回に
    # fingerprint不一致として再読込する。
    $eventIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($fullPath, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $record = $line | ConvertFrom-Json
            if ([int]$record.schema_version -eq 3 -and [string]$record.event_id -match '^[a-f0-9]{64}$') {
                [void]$eventIds.Add([string]$record.event_id)
            }
        } catch {}
    }
    $script:YakuTranslationMemoryEventCache[$fullPath] = [pscustomobject]@{
        Fingerprint = $fingerprint
        EventIds = $eventIds
    }
    return [bool]$eventIds.Contains($EventId)
}

function Add-YakuTranslationMemoryEntry {
    <# 確認したセグメントをupsertする。同unit・同内容の再確認は追記しない。 #>
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
    $targetPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $key = ConvertTo-YakuTranslationMemoryKey -Text $src
    $sourceHash = Get-YakuTranslationMemoryHash -Text $src
    $targetHash = Get-YakuTranslationMemoryHash -Text $tgt
    $unitId = Get-YakuTranslationMemoryUnitId -OriginProjectId $projectId -OriginSegmentId $segmentId -Direction $Direction
    $referenceId = Get-YakuTranslationMemoryReferenceId -OriginProjectId $projectId -OriginFileName $fileName `
        -OriginSegmentId $segmentId -OriginLocation $location -OriginPage $OriginPage -ReviewRevision $ReviewRevision `
        -Direction $Direction -SourceHash $sourceHash -TargetHash $targetHash
    $eventId = Get-YakuTranslationMemoryEventId -EventType 'upsert' -UnitId $unitId -Direction $Direction `
        -ReviewRevision $ReviewRevision -ReferenceId $referenceId
    $fullTarget = [IO.Path]::GetFullPath($targetPath)
    $lockKey = (Get-YakuTranslationMemoryHash -Text $fullTarget).Substring(0, 24)
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.TranslationMemory.' + $lockKey))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'TRANSLATION_MEMORY_LOCK_TIMEOUT' }
        # The project outbox is intentionally replayed after restart. An older
        # successful event must remain idempotent even if a newer event for the
        # same translation unit is now active; otherwise replay would roll the
        # unit back to an earlier translation.
        if (Test-YakuTranslationMemoryEventExists -Path $targetPath -EventId $eventId) {
            return [pscustomobject]@{ Added = $false; Reason = 'same'; Key = $key; UnitId = $unitId; ReferenceId = $referenceId }
        }
        $existing = Read-YakuTranslationMemory -Direction $Direction -Path $targetPath
        $current = if ($existing.Contains($unitId)) { $existing[$unitId] } else { $null }
        if ($null -ne $current -and (Test-YakuTranslationMemoryProvenance -Entry $current) -and
            [string]$current.source -eq $src -and [string]$current.target -eq $tgt -and
            [string]$current.reference_id -eq $referenceId) {
            return [pscustomobject]@{ Added = $false; Reason = 'same'; Key = $key; UnitId = $unitId; ReferenceId = $referenceId }
        }
        $parent = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $record = [ordered]@{
            schema_version    = 3
            event_type       = 'upsert'
            event_id         = $eventId
            unit_id          = $unitId
            key              = $key
            source           = $src
            target           = $tgt
            direction        = $Direction
            origin           = $Origin
            reference_id     = $referenceId
            origin_project_id = $projectId
            origin_file_name = $fileName
            origin_segment_id = $segmentId
            origin_location  = $location
            origin_page      = [int]$OriginPage
            source_hash      = $sourceHash
            target_hash      = $targetHash
            review_revision  = [int]$ReviewRevision
            saved            = (Get-Date).ToString('s')
        }
        [IO.File]::AppendAllLines($targetPath, [string[]]@(($record | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
        $reason = if ($null -eq $current) { 'new' } elseif (Test-YakuTranslationMemoryTombstone -Entry $current) { 'revived' } else { 'updated' }
        return [pscustomobject]@{ Added = $true; Reason = $reason; Key = $key; UnitId = $unitId; ReferenceId = $referenceId }
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Add-YakuTranslationMemoryTombstone {
    <# unitを物理削除せず候補から撤回する。重複撤回は追記しない。 #>
    param(
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [int]$ReviewRevision = 0,
        [string]$Reason = 'withdrawn',
        [AllowNull()][string]$Path
    )
    $projectId = ([string]$OriginProjectId).Trim().ToLowerInvariant()
    $segmentId = ([string]$OriginSegmentId).Trim().ToLowerInvariant()
    $why = ([string]$Reason).Trim()
    if ($projectId -notmatch '^[a-f0-9]{32}$' -or $segmentId -notmatch '^[a-f0-9]{32}$' -or
        $ReviewRevision -lt 1 -or [string]::IsNullOrWhiteSpace($why)) {
        return [pscustomobject]@{ Added = $false; Reason = 'provenance-required' }
    }
    $targetPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $unitId = Get-YakuTranslationMemoryUnitId -OriginProjectId $projectId -OriginSegmentId $segmentId -Direction $Direction
    $eventId = Get-YakuTranslationMemoryEventId -EventType 'tombstone' -UnitId $unitId -Direction $Direction `
        -ReviewRevision $ReviewRevision -Reason $why
    $fullTarget = [IO.Path]::GetFullPath($targetPath)
    $lockKey = (Get-YakuTranslationMemoryHash -Text $fullTarget).Substring(0, 24)
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.TranslationMemory.' + $lockKey))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'TRANSLATION_MEMORY_LOCK_TIMEOUT' }
        if (Test-YakuTranslationMemoryEventExists -Path $targetPath -EventId $eventId) {
            return [pscustomobject]@{ Added = $false; Reason = 'same'; UnitId = $unitId }
        }
        $existing = Read-YakuTranslationMemory -Direction $Direction -Path $targetPath
        if (-not $existing.Contains($unitId)) {
            return [pscustomobject]@{ Added = $false; Reason = 'missing'; UnitId = $unitId }
        }
        $current = $existing[$unitId]
        if (Test-YakuTranslationMemoryTombstone -Entry $current) {
            return [pscustomobject]@{ Added = $false; Reason = 'same'; UnitId = $unitId }
        }
        # 改ざんされたactive eventをtombstoneで正当化しない。
        if (-not (Test-YakuTranslationMemoryProvenance -Entry $current)) {
            return [pscustomobject]@{ Added = $false; Reason = 'invalid-active'; UnitId = $unitId }
        }
        $record = [ordered]@{
            schema_version = 3
            event_type = 'tombstone'
            event_id = $eventId
            unit_id = $unitId
            direction = $Direction
            origin_project_id = $projectId
            origin_segment_id = $segmentId
            review_revision = [int]$ReviewRevision
            reason = $why
            saved = (Get-Date).ToString('s')
        }
        [IO.File]::AppendAllLines($targetPath, [string[]]@(($record | ConvertTo-Json -Compress -Depth 3)), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Added = $true; Reason = 'tombstoned'; UnitId = $unitId; EventId = $eventId }
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Get-YakuTranslationMemoryNgrams {
    param([Parameter(Mandatory=$true)][string]$Text, [int]$Size = 3)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($Text.Length -le $Size) { [void]$set.Add($Text); return $set }
    for ($i = 0; $i -le ($Text.Length - $Size); $i++) { [void]$set.Add($Text.Substring($i, $Size)) }
    return $set
}

function Get-YakuTranslationMemorySimilarity {
    <# 正規化文字trigramのDice係数。日本語でも形態素辞書なしで差分を拾える。 #>
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    $a = ConvertTo-YakuTranslationMemoryKey -Text $Left
    $b = ConvertTo-YakuTranslationMemoryKey -Text $Right
    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return [double]0 }
    if ([string]::Equals($a, $b, [StringComparison]::Ordinal)) { return [double]1 }
    $gramsA = Get-YakuTranslationMemoryNgrams -Text $a -Size 3
    $gramsB = Get-YakuTranslationMemoryNgrams -Text $b -Size 3
    $intersection = 0
    foreach ($gram in $gramsA) { if ($gramsB.Contains($gram)) { $intersection++ } }
    if (($gramsA.Count + $gramsB.Count) -eq 0) { return [double]0 }
    return [double](2.0 * $intersection / ($gramsA.Count + $gramsB.Count))
}

function Find-YakuTranslationMemory {
    <# 完全一致と70%以上のfuzzyを、複数unitのまま出典付きで返す。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [int]$Limit = 5,
        [int]$MinLength = 4,
        [ValidateRange(0.0,1.0)][double]$MinScore = 0.70,
        [AllowNull()][string]$Path
    )
    $t = ([string]$Text).Trim()
    if ($t.Length -lt $MinLength) { return @() }
    $entries = Read-YakuTranslationMemory -Direction $Direction -Path $Path
    if ($entries.Count -eq 0) { return @() }
    $tn = ConvertTo-YakuTranslationMemoryKey -Text $t
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($unitId in $entries.Keys) {
        $e = $entries[$unitId]
        if (-not (Test-YakuTranslationMemoryProvenance -Entry $e)) { continue }
        if ([string]$e.direction -ne $Direction) { continue }
        $sn = [string]$e.key
        if ($sn.Length -lt $MinLength) { continue }
        $exact = [string]::Equals($sn, $tn, [StringComparison]::Ordinal)
        $ratio = if ($exact) { [double]1 } else { Get-YakuTranslationMemorySimilarity -Left $t -Right ([string]$e.source) }
        if (-not $exact -and $ratio -lt $MinScore) { continue }
        [void]$hits.Add([pscustomobject]@{
                Source = [string]$e.source
                Target = [string]$e.target
                Exact  = $exact
                Ratio  = [double]$ratio
                Score  = [double]$ratio
                MatchType = $(if ($exact) { 'exact' } else { 'fuzzy' })
                Saved  = [string]$e.saved
                UnitId = $(if ([int]$e.schema_version -eq 3) { [string]$e.unit_id } else { Resolve-YakuTranslationMemoryRecordUnitId -Entry $e })
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
    return @(@($hits.ToArray()) | Sort-Object -Property `
        @{ Expression = { if ([bool]$_.Exact) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { [double]$_.Score }; Descending = $true }, `
        @{ Expression = { [string]$_.Saved }; Descending = $true } | Select-Object -First $Limit)
}
