<#
  CAT terminology store.

  A term is a bilingual concept, not a complete translated segment.  The
  append-only JSONL store keeps every revision so a candidate and a QA result
  can name the exact entry that was used.  Project and personal stores use the
  same schema; callers choose the path and scope.
#>

function Get-YakuTerminologyHash {
    param([AllowNull()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-YakuPersonalTerminologyPath {
    return (Join-Path (Get-YakuSubDir 'terminology') 'personal-v2.jsonl')
}

function ConvertTo-YakuTerminologyTextList {
    param(
        [AllowNull()][object[]]$Values,
        [AllowNull()][string]$Exclude
    )
    $out = New-Object Collections.Generic.List[string]
    $seen = @{}
    foreach ($value in @($Values)) {
        $text = ([string]$value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Exclude) -and
            [string]::Equals($text, $Exclude, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $key = $text.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $out.Add($text) | Out-Null
    }
    return [string[]]@($out.ToArray())
}

function ConvertTo-YakuTerminologyLanguageRecord {
    param(
        [Parameter(Mandatory=$true)][string]$Preferred,
        [AllowNull()][object[]]$Allowed,
        [AllowNull()][object[]]$Forbidden
    )
    $preferredText = $Preferred.Trim()
    if ([string]::IsNullOrWhiteSpace($preferredText)) { throw 'TERMINOLOGY_PREFERRED_REQUIRED' }
    $allowedTerms = @(ConvertTo-YakuTerminologyTextList -Values $Allowed -Exclude $preferredText)
    $forbiddenTerms = @(ConvertTo-YakuTerminologyTextList -Values $Forbidden -Exclude $preferredText)
    $allowedKeys = @{}
    foreach ($term in $allowedTerms) { $allowedKeys[$term.ToLowerInvariant()] = $true }
    foreach ($term in $forbiddenTerms) {
        if ($allowedKeys.ContainsKey($term.ToLowerInvariant())) { throw 'TERMINOLOGY_ALLOWED_FORBIDDEN_CONFLICT' }
    }
    return [ordered]@{
        preferred = $preferredText
        allowed = [string[]]$allowedTerms
        forbidden = [string[]]$forbiddenTerms
    }
}

function Get-YakuTerminologyReferenceId {
    param([Parameter(Mandatory=$true)]$Entry)
    $ja = $Entry.ja
    $en = $Entry.en
    $separator = [string][char]31
    $parts = @(
        'term-v2', [string]$Entry.term_id, [string][int]$Entry.version,
        [string][bool]$Entry.active, [string]$Entry.scope, [string]$Entry.project_id,
        [string]$Entry.kind, [string]$Entry.enforcement,
        [string]$ja.preferred, (@($ja.allowed) -join [char]30), (@($ja.forbidden) -join [char]30),
        [string]$en.preferred, (@($en.allowed) -join [char]30), (@($en.forbidden) -join [char]30),
        [string]$Entry.note, [string]$Entry.origin,
        [string]$Entry.origin_project_id, [string]$Entry.origin_file_name,
        [string]$Entry.origin_segment_id, [string]$Entry.origin_location,
        [string][int]$Entry.origin_revision
    )
    return (Get-YakuTerminologyHash -Text ($parts -join $separator))
}

function Test-YakuTerminologyProvenance {
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return $false }
    try {
        if ([int]$Entry.schema_version -ne 2) { return $false }
        if ([string]$Entry.term_id -notmatch '^[a-f0-9]{32}$') { return $false }
        if ([int]$Entry.version -lt 1) { return $false }
        if ([string]$Entry.scope -notin @('project','personal')) { return $false }
        if ([string]$Entry.scope -eq 'project' -and [string]$Entry.project_id -notmatch '^[a-f0-9]{32}$') { return $false }
        if ([string]$Entry.kind -notin @('occurrence','cell_exact')) { return $false }
        if ([string]$Entry.enforcement -notin @('required','advisory')) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$Entry.ja.preferred) -or
            [string]::IsNullOrWhiteSpace([string]$Entry.en.preferred)) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$Entry.origin) -or
            [string]::IsNullOrWhiteSpace([string]$Entry.origin_file_name) -or
            [string]::IsNullOrWhiteSpace([string]$Entry.origin_location)) { return $false }
        if ([string]$Entry.origin_project_id -notmatch '^[a-f0-9]{32}$') { return $false }
        if ([string]$Entry.origin_segment_id -notmatch '^[a-f0-9]{32}$') { return $false }
        if ([int]$Entry.origin_revision -lt 0) { return $false }
        if ([string]$Entry.reference_id -notmatch '^[a-f0-9]{64}$') { return $false }
        return [string]::Equals([string]$Entry.reference_id, (Get-YakuTerminologyReferenceId -Entry $Entry), [StringComparison]::Ordinal)
    } catch { return $false }
}

function New-YakuTerminologyEntry {
    param(
        [AllowNull()][string]$TermId,
        [int]$Version = 1,
        [bool]$Active = $true,
        [Parameter(Mandatory=$true)][ValidateSet('project','personal')][string]$Scope,
        [AllowNull()][string]$ProjectId,
        [ValidateSet('occurrence','cell_exact')][string]$Kind = 'occurrence',
        [ValidateSet('required','advisory')][string]$Enforcement = 'required',
        [Parameter(Mandatory=$true)][string]$JapanesePreferred,
        [Parameter(Mandatory=$true)][string]$EnglishPreferred,
        [AllowNull()][object[]]$JapaneseAllowed,
        [AllowNull()][object[]]$JapaneseForbidden,
        [AllowNull()][object[]]$EnglishAllowed,
        [AllowNull()][object[]]$EnglishForbidden,
        [AllowNull()][string]$Note,
        [string]$Origin = 'cat-term-editor',
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginFileName,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][string]$OriginLocation,
        [int]$OriginRevision = 0,
        [AllowNull()][string]$CreatedAt
    )
    $id = ([string]$TermId).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [guid]::NewGuid().ToString('N') }
    if ($id -notmatch '^[a-f0-9]{32}$') { throw 'TERMINOLOGY_TERM_ID_INVALID' }
    if ($Version -lt 1) { throw 'TERMINOLOGY_VERSION_INVALID' }
    $project = ([string]$ProjectId).Trim().ToLowerInvariant()
    if ($Scope -eq 'project' -and $project -notmatch '^[a-f0-9]{32}$') { throw 'TERMINOLOGY_PROJECT_ID_REQUIRED' }
    if ($Scope -eq 'personal') { $project = '' }
    $originProject = $OriginProjectId.Trim().ToLowerInvariant()
    $originSegment = $OriginSegmentId.Trim().ToLowerInvariant()
    if ($originProject -notmatch '^[a-f0-9]{32}$' -or $originSegment -notmatch '^[a-f0-9]{32}$' -or
        [string]::IsNullOrWhiteSpace($OriginFileName) -or [string]::IsNullOrWhiteSpace($OriginLocation) -or
        [string]::IsNullOrWhiteSpace($Origin) -or $OriginRevision -lt 0) {
        throw 'TERMINOLOGY_PROVENANCE_REQUIRED'
    }
    $created = ([string]$CreatedAt).Trim()
    if ([string]::IsNullOrWhiteSpace($created)) { $created = (Get-Date).ToString('s') }
    $entry = [ordered]@{
        schema_version = 2
        term_id = $id
        version = [int]$Version
        active = [bool]$Active
        scope = $Scope
        project_id = $project
        kind = $Kind
        enforcement = $Enforcement
        ja = ConvertTo-YakuTerminologyLanguageRecord -Preferred $JapanesePreferred -Allowed $JapaneseAllowed -Forbidden $JapaneseForbidden
        en = ConvertTo-YakuTerminologyLanguageRecord -Preferred $EnglishPreferred -Allowed $EnglishAllowed -Forbidden $EnglishForbidden
        note = ([string]$Note).Trim()
        origin = $Origin
        origin_project_id = $originProject
        origin_file_name = $OriginFileName.Trim()
        origin_segment_id = $originSegment
        origin_location = $OriginLocation.Trim()
        origin_revision = [int]$OriginRevision
        created = $created
        updated = (Get-Date).ToString('s')
        reference_id = ''
    }
    $entry.reference_id = Get-YakuTerminologyReferenceId -Entry $entry
    return [pscustomobject]$entry
}

function Read-YakuTerminologyEntries {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$ProjectId,
        [switch]$IncludeInactive,
        [switch]$IncludeInvalid,
        [switch]$Strict
    )
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuPersonalTerminologyPath } else { [string]$Path }
    $latest = [ordered]@{}
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return @() }
    foreach ($line in [IO.File]::ReadAllLines($target, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { if ($Strict) { throw 'TERMINOLOGY_STORE_INVALID_JSON' }; continue }
        $valid = Test-YakuTerminologyProvenance -Entry $entry
        if (-not $valid -and -not $IncludeInvalid) { if ($Strict) { throw 'TERMINOLOGY_STORE_INVALID_PROVENANCE' }; continue }
        $id = [string]$entry.term_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($ProjectId) -and [string]$entry.scope -eq 'project' -and
            -not [string]::Equals([string]$entry.project_id, $ProjectId, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $latest.Contains($id) -or [int]$entry.version -ge [int]$latest[$id].version) { $latest[$id] = $entry }
    }
    $entries = @($latest.Values | Sort-Object -Property @{Expression={ [string]$_.scope };Descending=$false}, @{Expression={ [string]$_.term_id };Descending=$false})
    if (-not $IncludeInactive) { $entries = @($entries | Where-Object { [bool]$_.active }) }
    return @($entries)
}

function Add-YakuTerminologyRecord {
    param(
        [Parameter(Mandatory=$true)]$Entry,
        [AllowNull()][string]$Path
    )
    if (-not (Test-YakuTerminologyProvenance -Entry $Entry)) { throw 'TERMINOLOGY_RECORD_INVALID' }
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuPersonalTerminologyPath } else { [string]$Path }
    $fullTarget = [IO.Path]::GetFullPath($target)
    $mutexName = 'Local\YakuLingo.Terminology.' + (Get-YakuTerminologyHash -Text $fullTarget).Substring(0, 24)
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'TERMINOLOGY_LOCK_TIMEOUT' }
        $existing = @(Read-YakuTerminologyEntries -Path $target -IncludeInactive)
        $same = @($existing | Where-Object { [string]$_.term_id -eq [string]$Entry.term_id -and [int]$_.version -eq [int]$Entry.version })
        if ($same.Count -gt 0) {
            if ([string]$same[0].reference_id -eq [string]$Entry.reference_id) {
                return [pscustomobject]@{ Added=$false; Reason='same'; Entry=$same[0] }
            }
            throw 'TERMINOLOGY_VERSION_CONFLICT'
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        [IO.File]::AppendAllLines($target, [string[]]@(($Entry | ConvertTo-Json -Compress -Depth 8)), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Added=$true; Reason=$(if ([int]$Entry.version -gt 1) { 'updated' } else { 'new' }); Entry=$Entry }
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Add-YakuTerminologyEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('project','personal')][string]$Scope,
        [AllowNull()][string]$ProjectId,
        [ValidateSet('occurrence','cell_exact')][string]$Kind = 'occurrence',
        [ValidateSet('required','advisory')][string]$Enforcement = 'required',
        [Parameter(Mandatory=$true)][string]$JapanesePreferred,
        [Parameter(Mandatory=$true)][string]$EnglishPreferred,
        [AllowNull()][object[]]$JapaneseAllowed,
        [AllowNull()][object[]]$JapaneseForbidden,
        [AllowNull()][object[]]$EnglishAllowed,
        [AllowNull()][object[]]$EnglishForbidden,
        [AllowNull()][string]$Note,
        [string]$Origin = 'cat-term-editor',
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginFileName,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][string]$OriginLocation,
        [int]$OriginRevision = 0,
        [AllowNull()][string]$TermId,
        [AllowNull()][string]$Path
    )
    $targetPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuPersonalTerminologyPath } else { [string]$Path }
    if ([string]::IsNullOrWhiteSpace($TermId)) {
        $same = @(Read-YakuTerminologyEntries -Path $targetPath -ProjectId $ProjectId | Where-Object {
            [string]$_.scope -eq $Scope -and [string]$_.kind -eq $Kind -and
            [string]::Equals([string]$_.ja.preferred, $JapanesePreferred.Trim(), [StringComparison]::Ordinal) -and
            [string]::Equals([string]$_.en.preferred, $EnglishPreferred.Trim(), [StringComparison]::OrdinalIgnoreCase)
        })
        if ($same.Count -gt 0) { return [pscustomobject]@{ Added=$false; Reason='same'; Entry=$same[0] } }
    }
    $params = @{} + $PSBoundParameters
    $params.Remove('Path')
    $entry = New-YakuTerminologyEntry @params
    return (Add-YakuTerminologyRecord -Entry $entry -Path $targetPath)
}

function Update-YakuTerminologyEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TermId,
        [Parameter(Mandatory=$true)][ValidateSet('project','personal')][string]$Scope,
        [AllowNull()][string]$ProjectId,
        [ValidateSet('occurrence','cell_exact')][string]$Kind = 'occurrence',
        [ValidateSet('required','advisory')][string]$Enforcement = 'required',
        [Parameter(Mandatory=$true)][string]$JapanesePreferred,
        [Parameter(Mandatory=$true)][string]$EnglishPreferred,
        [AllowNull()][object[]]$JapaneseAllowed,
        [AllowNull()][object[]]$JapaneseForbidden,
        [AllowNull()][object[]]$EnglishAllowed,
        [AllowNull()][object[]]$EnglishForbidden,
        [AllowNull()][string]$Note,
        [string]$Origin = 'cat-term-editor',
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginFileName,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][string]$OriginLocation,
        [int]$OriginRevision = 0,
        [AllowNull()][string]$Path
    )
    $current = @(Read-YakuTerminologyEntries -Path $Path -IncludeInactive | Where-Object { [string]$_.term_id -eq $TermId })
    if ($current.Count -ne 1) { throw 'TERMINOLOGY_ENTRY_NOT_FOUND' }
    $params = @{} + $PSBoundParameters
    $params.Remove('Path')
    $params['Version'] = [int]$current[0].version + 1
    $params['CreatedAt'] = [string]$current[0].created
    $entry = New-YakuTerminologyEntry @params
    return (Add-YakuTerminologyRecord -Entry $entry -Path $Path)
}

function Disable-YakuTerminologyEntry {
    param(
        [Parameter(Mandatory=$true)][string]$TermId,
        [AllowNull()][string]$Path,
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginFileName,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][string]$OriginLocation,
        [int]$OriginRevision = 0
    )
    $current = @(Read-YakuTerminologyEntries -Path $Path -IncludeInactive | Where-Object { [string]$_.term_id -eq $TermId })
    if ($current.Count -ne 1) { throw 'TERMINOLOGY_ENTRY_NOT_FOUND' }
    if (-not [bool]$current[0].active) { return [pscustomobject]@{ Added=$false; Reason='already-inactive'; Entry=$current[0] } }
    $entry = New-YakuTerminologyEntry -TermId $TermId -Version ([int]$current[0].version + 1) -Active $false `
        -Scope ([string]$current[0].scope) -ProjectId ([string]$current[0].project_id) -Kind ([string]$current[0].kind) `
        -Enforcement ([string]$current[0].enforcement) -JapanesePreferred ([string]$current[0].ja.preferred) `
        -EnglishPreferred ([string]$current[0].en.preferred) -JapaneseAllowed @($current[0].ja.allowed) `
        -JapaneseForbidden @($current[0].ja.forbidden) -EnglishAllowed @($current[0].en.allowed) `
        -EnglishForbidden @($current[0].en.forbidden) -Note ([string]$current[0].note) -Origin 'cat-term-deactivate' `
        -OriginProjectId $OriginProjectId -OriginFileName $OriginFileName -OriginSegmentId $OriginSegmentId `
        -OriginLocation $OriginLocation -OriginRevision $OriginRevision -CreatedAt ([string]$current[0].created)
    return (Add-YakuTerminologyRecord -Entry $entry -Path $Path)
}

function Deactivate-YakuTerminologyEntry {
    <# Product-facing synonym; retained alongside Disable for existing callers. #>
    param(
        [Parameter(Mandatory=$true)][string]$TermId,
        [AllowNull()][string]$Path,
        [Parameter(Mandatory=$true)][string]$OriginProjectId,
        [Parameter(Mandatory=$true)][string]$OriginFileName,
        [Parameter(Mandatory=$true)][string]$OriginSegmentId,
        [Parameter(Mandatory=$true)][string]$OriginLocation,
        [int]$OriginRevision = 0
    )
    return (Disable-YakuTerminologyEntry @PSBoundParameters)
}

function Find-YakuTerminologyTextPositions {
    param([AllowNull()][string]$Text, [AllowNull()][string]$Term)
    $source = [string]$Text
    $needle = ([string]$Term).Trim()
    if ([string]::IsNullOrWhiteSpace($source) -or $needle.Length -lt 2) { return @() }
    $positions = New-Object Collections.Generic.List[int]
    if ($needle -match '^[\x00-\x7F]+$' -and $needle -match '[A-Za-z0-9]') {
        $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($needle) + '(?![A-Za-z0-9])'
        foreach ($match in @([regex]::Matches($source, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase))) {
            if ($match.Success) { $positions.Add([int]$match.Index) | Out-Null }
        }
        return [int[]]@($positions.ToArray())
    }
    $start = 0
    while ($start -lt $source.Length) {
        $at = $source.IndexOf($needle, $start, [StringComparison]::Ordinal)
        if ($at -lt 0) { break }
        $excluded = ($needle -eq '半期' -and $at -gt 0 -and $source[$at - 1] -eq '四')
        if (-not $excluded) { $positions.Add($at) | Out-Null }
        $start = $at + [Math]::Max(1, $needle.Length)
    }
    return [int[]]@($positions.ToArray())
}

function Find-YakuTerminologyMatches {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()][object[]]$Entries,
        [AllowNull()][string]$ProjectId
    )
    $candidates = New-Object Collections.Generic.List[object]
    foreach ($entry in @($Entries)) {
        if (-not (Test-YakuTerminologyProvenance -Entry $entry) -or -not [bool]$entry.active -or [string]$entry.kind -ne 'occurrence') { continue }
        if ([string]$entry.scope -eq 'project' -and -not [string]::Equals([string]$entry.project_id, $ProjectId, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $sourceLanguage = if ($Direction -eq 'to_en') { $entry.ja } else { $entry.en }
        $targetLanguage = if ($Direction -eq 'to_en') { $entry.en } else { $entry.ja }
        $aliases = @([string]$sourceLanguage.preferred) + @($sourceLanguage.allowed) + @($sourceLanguage.forbidden)
        foreach ($alias in @(ConvertTo-YakuTerminologyTextList -Values $aliases)) {
            foreach ($position in @(Find-YakuTerminologyTextPositions -Text $Text -Term $alias)) {
                $candidates.Add([pscustomobject]@{
                    TermId=[string]$entry.term_id; Version=[int]$entry.version; ReferenceId=[string]$entry.reference_id
                    Scope=[string]$entry.scope; Enforcement=[string]$entry.enforcement
                    SourceTerm=[string]$alias; PreferredTarget=[string]$targetLanguage.preferred
                    AllowedTargets=[string[]]@($targetLanguage.allowed); ForbiddenTargets=[string[]]@($targetLanguage.forbidden)
                    Position=[int]$position; Length=[int]([string]$alias).Length; Entry=$entry
                    ScopeWeight=$(if ([string]$entry.scope -eq 'project') { 2 } else { 1 })
                }) | Out-Null
            }
        }
    }
    $ordered = @($candidates.ToArray() | Sort-Object -Property @{Expression={$_.Position};Ascending=$true}, @{Expression={$_.Length};Descending=$true}, @{Expression={$_.ScopeWeight};Descending=$true})
    $out = New-Object Collections.Generic.List[object]
    $covered = New-Object Collections.Generic.List[object]
    foreach ($candidate in $ordered) {
        $end = [int]$candidate.Position + [int]$candidate.Length
        $overlap = $false
        foreach ($span in @($covered.ToArray())) {
            if ([int]$candidate.Position -lt [int]$span.End -and [int]$span.Start -lt $end) { $overlap = $true; break }
        }
        if ($overlap) { continue }
        $out.Add($candidate) | Out-Null
        $covered.Add([pscustomobject]@{ Start=[int]$candidate.Position; End=$end }) | Out-Null
    }
    return @($out.ToArray())
}

function Get-YakuTerminologySnapshotHash {
    param([AllowNull()][object[]]$Entries)
    $rows = @($Entries | Where-Object { Test-YakuTerminologyProvenance -Entry $_ } |
        Sort-Object -Property term_id,version | ForEach-Object { [string]$_.reference_id })
    return (Get-YakuTerminologyHash -Text ($rows -join [char]31))
}

function Test-YakuTerminologyCompliance {
    param(
        [AllowNull()][string]$SourceText,
        [AllowNull()][string]$TargetText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()][object[]]$Entries,
        [AllowNull()][object[]]$Exceptions,
        [AllowNull()][string]$ProjectId
    )
    $findings = New-Object Collections.Generic.List[object]
    # Detect competing required translations at the same source span before
    # the longest-match resolver chooses one candidate. Project terms may
    # override personal terms, but peers at the same scope must be resolved by
    # the user rather than by insertion order.
    $conflictBuckets = @{}
    foreach ($entry in @($Entries)) {
        if (-not (Test-YakuTerminologyProvenance -Entry $entry) -or -not [bool]$entry.active -or [string]$entry.kind -ne 'occurrence' -or [string]$entry.enforcement -ne 'required') { continue }
        if ([string]$entry.scope -eq 'project' -and -not [string]::Equals([string]$entry.project_id, $ProjectId, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $sourceLanguage = if ($Direction -eq 'to_en') { $entry.ja } else { $entry.en }
        $targetLanguage = if ($Direction -eq 'to_en') { $entry.en } else { $entry.ja }
        $scopeWeight = if ([string]$entry.scope -eq 'project') { 2 } else { 1 }
        foreach ($alias in @(ConvertTo-YakuTerminologyTextList -Values (@([string]$sourceLanguage.preferred) + @($sourceLanguage.allowed) + @($sourceLanguage.forbidden)))) {
            foreach ($position in @(Find-YakuTerminologyTextPositions -Text $SourceText -Term $alias)) {
                $key = ([string]$position + '|' + [string]$alias.Length)
                if (-not $conflictBuckets.ContainsKey($key)) { $conflictBuckets[$key] = New-Object Collections.Generic.List[object] }
                $conflictBuckets[$key].Add([pscustomobject]@{ ScopeWeight=$scopeWeight; Entry=$entry; Source=$alias; Target=[string]$targetLanguage.preferred }) | Out-Null
            }
        }
    }
    foreach ($bucket in @($conflictBuckets.Values)) {
        $topWeight = @($bucket | Measure-Object -Property ScopeWeight -Maximum)[0].Maximum
        $top = @($bucket | Where-Object { [int]$_.ScopeWeight -eq [int]$topWeight })
        $targets = @($top.Target | Sort-Object -Unique)
        if ($targets.Count -gt 1) {
            $findings.Add([pscustomobject]@{
                Code='terminology-conflict'; Severity='error'; Excepted=$false
                TermId=''; TermVersion=0; SourceTerm=[string]$top[0].Source
                PreferredTarget=($targets -join ' / '); Found=[string[]]$targets; ReferenceId=''
            }) | Out-Null
        }
    }
    $matches = @(Find-YakuTerminologyMatches -Text $SourceText -Direction $Direction -Entries $Entries -ProjectId $ProjectId)
    $sourceHash = Get-YakuTerminologyHash -Text ([string]$SourceText)
    $targetHash = Get-YakuTerminologyHash -Text ([string]$TargetText)
    foreach ($match in $matches) {
        $excepted = $false
        foreach ($exception in @($Exceptions)) {
            if ([string]$exception.term_id -ne [string]$match.TermId -or [int]$exception.term_version -ne [int]$match.Version) { continue }
            if ($exception.PSObject.Properties.Name -contains 'active' -and -not [bool]$exception.active) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$exception.source_hash) -and [string]$exception.source_hash -ne $sourceHash) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$exception.target_hash) -and [string]$exception.target_hash -ne $targetHash) { continue }
            $excepted = $true
            break
        }
        $approved = @([string]$match.PreferredTarget) + @($match.AllowedTargets)
        $approvedSpans = New-Object Collections.Generic.List[object]
        $approvedFound = New-Object Collections.Generic.List[string]
        foreach ($approvedTerm in $approved) {
            $positions = @(Find-YakuTerminologyTextPositions -Text $TargetText -Term ([string]$approvedTerm))
            if ($positions.Count -gt 0) { $approvedFound.Add([string]$approvedTerm) | Out-Null }
            foreach ($position in $positions) {
                $approvedSpans.Add([pscustomobject]@{ Start=[int]$position; End=([int]$position + ([string]$approvedTerm).Length) }) | Out-Null
            }
        }
        $forbiddenFound = New-Object Collections.Generic.List[string]
        foreach ($forbiddenTerm in @($match.ForbiddenTargets)) {
            foreach ($position in @(Find-YakuTerminologyTextPositions -Text $TargetText -Term ([string]$forbiddenTerm))) {
                $end = [int]$position + ([string]$forbiddenTerm).Length
                $insideApproved = $false
                foreach ($span in @($approvedSpans.ToArray())) {
                    if ([int]$span.Start -le [int]$position -and $end -le [int]$span.End) { $insideApproved = $true; break }
                }
                if (-not $insideApproved) { $forbiddenFound.Add([string]$forbiddenTerm) | Out-Null; break }
            }
        }
        if ($forbiddenFound.Count -gt 0) {
            $findings.Add([pscustomobject]@{
                Code='terminology-forbidden'; Severity=$(if ($excepted) { 'info' } else { 'error' }); Excepted=$excepted
                TermId=[string]$match.TermId; TermVersion=[int]$match.Version; SourceTerm=[string]$match.SourceTerm
                PreferredTarget=[string]$match.PreferredTarget; Found=[string[]]@($forbiddenFound.ToArray()); ReferenceId=[string]$match.ReferenceId
            }) | Out-Null
        } elseif ($approvedFound.Count -eq 0) {
            $severity = if ([string]$match.Enforcement -eq 'required') { 'error' } else { 'warning' }
            if ($excepted) { $severity = 'info' }
            $findings.Add([pscustomobject]@{
                Code='terminology-missing'; Severity=$severity; Excepted=$excepted
                TermId=[string]$match.TermId; TermVersion=[int]$match.Version; SourceTerm=[string]$match.SourceTerm
                PreferredTarget=[string]$match.PreferredTarget; Found=[string[]]@(); ReferenceId=[string]$match.ReferenceId
            }) | Out-Null
        }
    }
    $blocking = @($findings.ToArray() | Where-Object { [string]$_.Severity -eq 'error' })
    return [pscustomobject]@{
        Passed=($blocking.Count -eq 0); Findings=@($findings.ToArray()); Matches=$matches
        SnapshotHash=Get-YakuTerminologySnapshotHash -Entries $Entries
    }
}
