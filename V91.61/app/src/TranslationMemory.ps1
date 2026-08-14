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

function Clear-YakuTranslationMemoryCache {
    <#
      記憶化を捨てる。記憶化は足しであって前提ではないので、いつ捨てても
      結果は変わらず、次の呼び出しがJSONLから作り直すだけである。
    #>
    $script:YakuTranslationMemorySnapshotCache = @{}
}

function Get-YakuTranslationMemorySnapshotCache {
    if (-not (Get-Variable -Name YakuTranslationMemorySnapshotCache -Scope Script -ErrorAction SilentlyContinue)) {
        $script:YakuTranslationMemorySnapshotCache = @{}
    }
    return $script:YakuTranslationMemorySnapshotCache
}

function Get-YakuTranslationMemoryContentDigest {
    <#
      byte列の一部または全部のSHA-256。指紋にも、前半の照合にも同じ物差しを使う。

      $Bytes に [Parameter(Mandatory=$true)] を付けてはならない。PowerShell 5.1 は
      必須パラメータが「空か」を判定するために配列を全要素たどる。5MBのbyte[]で
      1回あたり **185ms**（実測 5.1.26100.9168）。中身のSHA-256そのものは1.3msである。
      つまり計算ではなく引数の受け渡しが費用の99%を占める。同じ理由で
      [AllowEmptyCollection()] 単独は無害（1.3ms）。必須にするのが高い。
    #>
    param(
        [byte[]]$Bytes,
        [int]$Offset = 0,
        [int]$Count = -1
    )
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    if ($Count -lt 0) { $Count = $Bytes.Length - $Offset }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes, $Offset, $Count)).Replace('-', '') } finally { $sha.Dispose() }
}

function New-YakuTranslationMemorySnapshotState {
    return [pscustomobject]@{
        Fingerprint  = ''
        Length       = [long]0
        Digest       = ''
        EndsAtLine   = $true
        Map          = [ordered]@{}
        EventIds     = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
        CandidateMap = $null
        Candidates   = $null
        Broken       = 0
        LastUsed     = [DateTime]::UtcNow.Ticks
    }
}

function Get-YakuTranslationMemoryDecodedLineCount {
    <#
      このプロセスが起動してからJSONLの行をのべ何本解いたか。

      速さの門をここへ置く。時計は機械の混み具合で揺れるが、この数は揺れない。
      追記のたびに全件を解き直す作りへ戻すと、追記1回につき種の件数ぶん増える。
      snapshotごとではなくプロセス全体で数える。作り直すたびに新しいsnapshotを
      作る実装だと、snapshotの中に持たせた数は毎回0へ戻り、増えたことが見えない。
    #>
    if (-not (Get-Variable -Name YakuTranslationMemoryDecodedLines -Scope Script -ErrorAction SilentlyContinue)) {
        $script:YakuTranslationMemoryDecodedLines = [long]0
    }
    return [long]$script:YakuTranslationMemoryDecodedLines
}

function Add-YakuTranslationMemorySnapshotLines {
    <#
      JSONLの行をsnapshotへ取り込む。全件を作り直すときも、末尾へ追記された
      分だけを取り込むときも、この1本を通す。触れたunit_idを返す。
    #>
    param(
        [Parameter(Mandatory=$true)]$State,
        [AllowEmptyCollection()][string[]]$Lines = @()
    )
    $touched = New-Object 'System.Collections.Generic.List[string]'
    $decoded = Get-YakuTranslationMemoryDecodedLineCount
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $decoded = $decoded + 1
        try {
            $o = $line | ConvertFrom-Json
            $schema = 0
            try { $schema = [int]$o.schema_version } catch { $schema = 0 }
            # 上書きされた行のevent IDも残す。outbox再送の冪等はunitの現在値では
            # なく「その追記を一度受けたか」で決まる。
            if ($schema -eq 3 -and [string]$o.event_id -match '^[a-f0-9]{64}$') { [void]$State.EventIds.Add([string]$o.event_id) }
            $unitId = Resolve-YakuTranslationMemoryRecordUnitId -Entry $o
            if ($schema -eq 3) {
                # unit_id自体だけを書き換えても、出典から導いたunitへfail-closedにする。
                if ([string]::IsNullOrWhiteSpace($unitId)) { $unitId = 'invalid:' + (Get-YakuTranslationMemoryHash -Text $line) }
            } elseif ($schema -eq 2 -and -not [string]::IsNullOrWhiteSpace($unitId)) {
                # 出典検証できるv2はunit_idをそのまま使う。
            } else {
                # 出典の無い旧形式は移行調査のため読めるが、Findでは候補にしない。
                $key = [string]$o.key
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                $unitId = 'legacy:' + (Get-YakuTranslationMemoryHash -Text ($key + [string][char]31 + [string]$o.target))
            }
            $State.Map[$unitId] = $o
            [void]$touched.Add($unitId)
        } catch { $State.Broken = [int]$State.Broken + 1 }
    }
    $script:YakuTranslationMemoryDecodedLines = [long]$decoded
    return ,$touched
}

function ConvertTo-YakuTranslationMemoryCandidate {
    <#
      出典検証を通ったentryだけを、照合に使う軽い姿へ写す。通らなければ$null。
      憶えるのは「検証を通った」という結論ではなく、通ったentryそのものである。
    #>
    param([AllowNull()]$Entry)
    if (-not (Test-YakuTranslationMemoryProvenance -Entry $Entry)) { return $null }
    $source = [string]$Entry.source
    $target = [string]$Entry.target
    $storedKey = [string]$Entry.key
    return [pscustomobject]@{
        Key         = $storedKey
        KeyLength   = $storedKey.Length
        Grams       = $null
        Direction   = [string]$Entry.direction
        Source      = $source
        Target      = $target
        SourceLower = $source.ToLowerInvariant()
        TargetLower = $target.ToLowerInvariant()
        Saved       = [string]$Entry.saved
        UnitId      = $(if ([int]$Entry.schema_version -eq 3) { [string]$Entry.unit_id } else { Resolve-YakuTranslationMemoryRecordUnitId -Entry $Entry })
        ReferenceId = [string]$Entry.reference_id
        SourceName  = [string]$Entry.origin_file_name
        Location    = [string]$Entry.origin_location
        Page        = [int]$Entry.origin_page
        OriginProjectId = [string]$Entry.origin_project_id
        OriginSegmentId = [string]$Entry.origin_segment_id
        ReviewRevision  = [int]$Entry.review_revision
        SourceHash  = [string]$Entry.source_hash
        TargetHash  = [string]$Entry.target_hash
    }
}

function Get-YakuTranslationMemorySnapshot {
    <#
      同じ世代のJSONLを1回だけ読み、解いた姿をプロセス内に憶える。

      なぜ要るか。Find-YakuTranslationMemoryはCATで行を移るたびに呼ばれる。
      素で書くと、変わっていない同じファイルに対して毎回
      ConvertFrom-Json（行ごと）と Test-...Provenance（entryごとにSHA-256を5個）を
      やり直す。実データ123件で約104ms、合成5,000件で約6秒かかっていた。

      世代の見分けには中身のSHA-256を使う。長さとmtimeだけだと、Windowsの
      ファイル時刻の更新間隔（約15.6ms）の内側で同じ長さに書き換えられた場合に
      古い姿を返してしまう。改ざんされた行を候補から外すのはこの層より上
      （Test-...Provenance）の仕事だが、その判定を憶えておく以上、憶えた鍵が
      中身と一対一でなければ意味がない。5MBのJSONLでも読取と要約で約6msである。

      指紋が合わなくても、まだ全部作り直すとは限らない。JSONLは追記専用なので、
      いま読んだbyte列の**前半が、前に憶えたときのbyte列とSHA-256で一致する**なら、
      増えた分だけを取り込んで憶えている姿を前へ進める。「伸びた」ことだけを
      根拠にはしない。前半が1byteでも違えば全部作り直す。ここを緩めると、
      追記に見せかけた差し替えが素通りする。

      これが要るのは、確認済みにするたびにTMへ1行追記するからである。追記の
      たびに全件を作り直すと、読みで得た分を書きで失い、さらに次の読みが
      毎回coldになる（実測: 実データ123件で追記直後のFindが88.8ms）。

      記憶化はプロセス内だけに置く。ディスクにも共有フォルダにも書かない。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (New-YakuTranslationMemorySnapshotState) }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    $digest = Get-YakuTranslationMemoryContentDigest -Bytes $bytes
    $fingerprint = ([string]$bytes.Length + '|' + $digest)

    $cache = Get-YakuTranslationMemorySnapshotCache
    $state = $null
    $tailOffset = 0
    if ($cache.ContainsKey($fullPath)) {
        $hit = $cache[$fullPath]
        if ([string]$hit.Fingerprint -eq $fingerprint) {
            $hit.LastUsed = [DateTime]::UtcNow.Ticks
            return $hit
        }
        # 憶えた分が行の途中で終わっていたら前へ進めない。次の追記はその行の
        # 続きとして連結され、憶えている「1行」と食い違う。
        if ([bool]$hit.EndsAtLine -and [long]$hit.Length -gt 0 -and [long]$bytes.Length -gt [long]$hit.Length) {
            $prefix = Get-YakuTranslationMemoryContentDigest -Bytes $bytes -Offset 0 -Count ([int]$hit.Length)
            if ($prefix -eq [string]$hit.Digest) {
                $state = $hit
                $tailOffset = [int]$hit.Length
            }
        }
    }
    if ($null -eq $state) { $state = New-YakuTranslationMemorySnapshotState }

    # 読んだそのbyte列から復号する。指紋用と本文用で二度読むと、その隙間の
    # 書き込みで指紋と中身が食い違う。
    $text = [Text.Encoding]::UTF8.GetString($bytes, $tailOffset, ($bytes.Length - $tailOffset))
    if ($tailOffset -eq 0 -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $brokenBefore = [int]$state.Broken
    $touched = Add-YakuTranslationMemorySnapshotLines -State $state -Lines ($text -split "`r`n|`n|`r")
    $brokenNow = [int]$state.Broken - $brokenBefore
    if ($brokenNow -gt 0) { try { Write-YakuLog "Translation memory had unreadable lines. broken=$brokenNow" 'WARN' } catch {} }

    # 候補の姿は Find / Concordance が最初に呼ぶまで作らない。書き込み経路は
    # 候補一覧を使わないので、その費用（entryごとにSHA-256を5個）を払わない。
    # すでに作ってあるなら、触れたunitだけ作り直す。
    if ($null -ne $state.CandidateMap) {
        foreach ($unitKey in $touched) {
            $candidate = ConvertTo-YakuTranslationMemoryCandidate -Entry $state.Map[$unitKey]
            if ($null -eq $candidate) {
                if ($state.CandidateMap.Contains($unitKey)) { $state.CandidateMap.Remove($unitKey) }
            } else {
                $state.CandidateMap[$unitKey] = $candidate
            }
        }
        $state.Candidates = $null
    }

    $state.Fingerprint = $fingerprint
    $state.Length = [long]$bytes.Length
    $state.Digest = $digest
    $state.EndsAtLine = ($bytes.Length -eq 0 -or $bytes[$bytes.Length - 1] -eq 10 -or $bytes[$bytes.Length - 1] -eq 13)
    $state.LastUsed = [DateTime]::UtcNow.Ticks
    # 常駐プロセスなので置きっぱなしにしない。実運用の宛先は方向ごとの2本だが、
    # 試験は使い捨ての一時ファイルを次々に作る。
    if (-not $cache.ContainsKey($fullPath) -and $cache.Count -ge 8) {
        $oldest = $null
        foreach ($k in @($cache.Keys)) {
            if ($null -eq $oldest -or [long]$cache[$k].LastUsed -lt [long]$cache[$oldest].LastUsed) { $oldest = $k }
        }
        if ($null -ne $oldest) { $cache.Remove($oldest) }
    }
    $cache[$fullPath] = $state
    return $state
}

function Get-YakuTranslationMemoryCandidates {
    <#
      照合に使う姿。出典検証を通ったentryだけが入る。
      最初に引かれたときに作り、以後は追記で触れたunitだけを作り直す。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $state = Get-YakuTranslationMemorySnapshot -Path $Path
    if ($null -eq $state.CandidateMap) {
        $built = [ordered]@{}
        foreach ($unitKey in $state.Map.Keys) {
            $candidate = ConvertTo-YakuTranslationMemoryCandidate -Entry $state.Map[$unitKey]
            if ($null -ne $candidate) { $built[$unitKey] = $candidate }
        }
        $state.CandidateMap = $built
        $state.Candidates = $null
    }
    if ($null -eq $state.Candidates) {
        # 並びはMapの順、つまりJSONLで最初に現れた順にそろえる。差分で
        # 進めても全件で作り直しても同じ順にするための一手間である。
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($unitKey in $state.Map.Keys) {
            if ($state.CandidateMap.Contains($unitKey)) { [void]$list.Add($state.CandidateMap[$unitKey]) }
        }
        $state.Candidates = $list
    }
    return ,$state.Candidates
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
    $snapshot = Get-YakuTranslationMemorySnapshot -Path $target
    # 憶えている辞書そのものは渡さない。呼び出し側が足したり消したりすると
    # 次の読みが濁る。中のentryは共有のままなので、書き換えずに読むこと。
    $map = [ordered]@{}
    foreach ($k in $snapshot.Map.Keys) { $map[$k] = $snapshot.Map[$k] }
    return $map
}

function Get-YakuTranslationMemoryActiveEntry {
    <#
      1つのunitのいま有効なeventだけを返す。書き込み経路はここしか見ないので、
      写しを作る Read-YakuTranslationMemory を通さない。写しは全件ぶんの
      詰め替えになり、追記1件のたびに払う筋合いがない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$UnitId
    )
    $state = Get-YakuTranslationMemorySnapshot -Path $Path
    if ($state.Map.Contains($UnitId)) { return $state.Map[$UnitId] }
    return $null
}

function Test-YakuTranslationMemoryEventExists {
    <#
      outboxは確認済み行の数だけ増える。同期間隔ごとにeventごと全JSONLを読むと
      二乗になるため、同じファイル世代のevent IDを1回だけ索引化する。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$EventId
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return [bool](Get-YakuTranslationMemorySnapshot -Path $Path).EventIds.Contains($EventId)
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
        $current = Get-YakuTranslationMemoryActiveEntry -Path $targetPath -UnitId $unitId
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
        $current = Get-YakuTranslationMemoryActiveEntry -Path $targetPath -UnitId $unitId
        if ($null -eq $current) {
            return [pscustomobject]@{ Added = $false; Reason = 'missing'; UnitId = $unitId }
        }
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
    <#
      文字n-gramの集合を返す。

      `return $set` と書くとPowerShellがHashSetを列挙して展開する。要素1個なら
      ただの文字列、2個以上ならObject[]になり、いずれもHashSetではなくなる。
      すると呼び出し側の `.Contains()` が集合の所属ではなくなる。文字列なら
      String.Contains（部分一致）、Object[]ならIList.Contains（線形探索）である。
      前者は Dice を非対称にし（発行/発行元 が片方向だけ1.0になる）、後者は
      照合を O(nA*nB) にする。`return ,$set` で展開を止める。
    #>
    param([Parameter(Mandatory=$true)][string]$Text, [int]$Size = 3)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($Text.Length -le $Size) { [void]$set.Add($Text); return ,$set }
    for ($i = 0; $i -le ($Text.Length - $Size); $i++) { [void]$set.Add($Text.Substring($i, $Size)) }
    return ,$set
}

function Get-YakuTranslationMemoryDice {
    <# 用意済みのn-gram集合どうしのDice係数。集合の構築を呼び出し側へ預ける。 #>
    param([Parameter(Mandatory=$true)]$Left, [Parameter(Mandatory=$true)]$Right)
    $total = $Left.Count + $Right.Count
    if ($total -eq 0) { return [double]0 }
    # 小さい方を回すと、HashSet.Containsの呼び出し回数が最小になる。
    if ($Left.Count -le $Right.Count) { $small = $Left; $large = $Right } else { $small = $Right; $large = $Left }
    $intersection = 0
    foreach ($gram in $small) { if ($large.Contains($gram)) { $intersection++ } }
    return [double](2.0 * $intersection / $total)
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
    return (Get-YakuTranslationMemoryDice -Left $gramsA -Right $gramsB)
}

function Search-YakuTranslationMemoryConcordance {
    <#
      過去に確認した訳を、言葉で探す。市販のCATツールでいうコンコーダンス。
      「あの言い回し、前はどう訳したか」を引くための道で、いまの行に対して
      自動で出る候補（Find-YakuTranslationMemory）とは別物である。

      原文・訳文のどちらに含まれていても拾う。日本語には語の区切りが無いので
      部分一致で探す。大文字小文字は畳む（英語側を探すときに必要）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [int]$Limit = 20,
        [AllowNull()][string]$Path
    )
    $needle = ([string]$Query).Trim()
    if ($needle.Length -lt 2) { return @() }
    $lowered = $needle.ToLowerInvariant()
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $entries = Get-YakuTranslationMemoryCandidates -Path $target
    if ($entries.Count -eq 0) { return @() }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        if ($e.Direction -ne $Direction) { continue }
        $inSource = $e.SourceLower.Contains($lowered)
        $inTarget = $e.TargetLower.Contains($lowered)
        if (-not $inSource -and -not $inTarget) { continue }
        [void]$hits.Add([pscustomobject]@{
                Source = $e.Source
                Target = $e.Target
                MatchedIn = $(if ($inSource -and $inTarget) { 'both' } elseif ($inSource) { 'source' } else { 'target' })
                Saved = $e.Saved
                SourceName = $e.SourceName
                Location = $e.Location
            })
    }
    # 新しく確認したものから見せる。古い言い回しを先に出しても役に立たない。
    return @(@($hits.ToArray()) | Sort-Object -Property @{ Expression = 'Saved'; Descending = $true } | Select-Object -First $Limit)
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
    $targetPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $entries = Get-YakuTranslationMemoryCandidates -Path $targetPath
    if ($entries.Count -eq 0) { return @() }
    $tn = ConvertTo-YakuTranslationMemoryKey -Text $t
    # 出典検証で key = ConvertTo-Key(source) を確かめてあるので、entry側の
    # 正規化はやり直さない。問い合わせ側のn-gramも1回だけ作る。
    $blank = [string]::IsNullOrWhiteSpace($tn)
    $queryGrams = $null
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        if ($e.Direction -ne $Direction) { continue }
        if ($e.KeyLength -lt $MinLength) { continue }
        $exact = [string]::Equals($e.Key, $tn, [StringComparison]::Ordinal)
        if ($exact) {
            $ratio = [double]1
        } else {
            # Get-YakuTranslationMemorySimilarity は正規化後が空なら0を返す。
            # MinLength=0 で呼ばれた場合にだけ効く枝で、そこも同じにしておく。
            if ($blank -or $e.KeyLength -eq 0) {
                $ratio = [double]0
            } else {
                if ($null -eq $queryGrams) { $queryGrams = Get-YakuTranslationMemoryNgrams -Text $tn -Size 3 }
                if ($null -eq $e.Grams) { $e.Grams = Get-YakuTranslationMemoryNgrams -Text $e.Key -Size 3 }
                $ratio = Get-YakuTranslationMemoryDice -Left $queryGrams -Right $e.Grams
            }
            if ($ratio -lt $MinScore) { continue }
        }
        # 並べ替えるまでは軽い姿で持つ。最悪ケース（5,000件が全部閾値を超える）
        # では、ここで17項目のオブジェクトを5,000個作る費用が最大になる。
        # 出典付きの姿に組み立てるのは、Limit件へ絞ったあとでよい。
        [void]$hits.Add([pscustomobject]@{
                Candidate = $e
                Exact     = $exact
                Score     = [double]$ratio
                Saved     = $e.Saved
            })
    }
    # Expressionへ式ではなく項目名を渡す。式にすると要素ごとにscriptblockを
    # 呼ぶので、5,000件で82ms対34msの差になる。比較の意味は変わらない。
    $ranked = @(@($hits.ToArray()) | Sort-Object -Property `
        @{ Expression = 'Exact'; Descending = $true }, `
        @{ Expression = 'Score'; Descending = $true }, `
        @{ Expression = 'Saved'; Descending = $true } | Select-Object -First $Limit)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($hit in $ranked) {
        $e = $hit.Candidate
        [void]$out.Add([pscustomobject]@{
                Source = $e.Source
                Target = $e.Target
                Exact  = [bool]$hit.Exact
                Ratio  = [double]$hit.Score
                Score  = [double]$hit.Score
                MatchType = $(if ([bool]$hit.Exact) { 'exact' } else { 'fuzzy' })
                Saved  = $e.Saved
                UnitId = $e.UnitId
                ReferenceId = $e.ReferenceId
                SourceName = $e.SourceName
                Location = $e.Location
                Page = $e.Page
                OriginProjectId = $e.OriginProjectId
                OriginSegmentId = $e.OriginSegmentId
                ReviewRevision = $e.ReviewRevision
                SourceHash = $e.SourceHash
                TargetHash = $e.TargetHash
            })
    }
    return @($out.ToArray())
}
