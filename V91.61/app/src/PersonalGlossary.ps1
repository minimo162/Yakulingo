<#
  Compatibility adapter for the former two-column personal glossary.

  New CAT terminology is stored as provenance-bound schema-v2 JSONL.  The CSV
  remains readable so an existing user's terms are never lost during upgrade.
#>

if (-not (Get-Command Read-YakuTerminologyEntries -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Terminology.ps1')
}

function Get-YakuPersonalGlossaryPath {
    return (Join-Path (Get-YakuSubDir 'glossary') 'personal.csv')
}

function Read-YakuLegacyPersonalGlossaryRows {
    param([AllowNull()][string]$Path)
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuPersonalGlossaryPath } else { [string]$Path }
    $rows = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return @() }
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($target, [Text.UTF8Encoding]::new($true))) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match($line, '^\s*(?:"(?<a>(?:[^"]|"")*)"|(?<a>[^,]*))\s*,\s*(?:"(?<b>(?:[^"]|"")*)"|(?<b>.*?))\s*$')
        if (-not $m.Success) { continue }
        $source = $m.Groups['a'].Value.Replace('""', '"').Trim().TrimStart([char]0xFEFF)
        $targetText = $m.Groups['b'].Value.Replace('""', '"').Trim()
        # The old writer always emitted this header.  Treat it as metadata, not
        # as the real term `source -> target`.
        if ($lineNumber -eq 1 -and [string]::Equals($source, 'source', [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($targetText, 'target', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($targetText)) { continue }
        $rows.Add([pscustomobject]@{ Source=$source; Target=$targetText; Row=$lineNumber }) | Out-Null
    }
    return @($rows.ToArray())
}

function Invoke-YakuPersonalGlossaryMigration {
    param(
        [AllowNull()][string]$LegacyPath,
        [AllowNull()][string]$TerminologyPath
    )
    $legacy = if ([string]::IsNullOrWhiteSpace($LegacyPath)) { Get-YakuPersonalGlossaryPath } else { [string]$LegacyPath }
    $termPath = if ([string]::IsNullOrWhiteSpace($TerminologyPath)) { Get-YakuPersonalTerminologyPath } else { [string]$TerminologyPath }
    $migrated = 0
    $latestRows = [ordered]@{}
    foreach ($row in @(Read-YakuLegacyPersonalGlossaryRows -Path $legacy)) { $latestRows[[string]$row.Source] = $row }
    $currentById = @{}
    foreach ($current in @(Read-YakuTerminologyEntries -Path $termPath -IncludeInactive)) { $currentById[[string]$current.term_id] = $current }
    foreach ($row in @($latestRows.Values)) {
        $identity = [string]$row.Source
        $termId = (Get-YakuTerminologyHash -Text ('legacy-personal-term|' + $identity)).Substring(0, 32)
        $originProjectId = (Get-YakuTerminologyHash -Text 'legacy-personal-glossary-project').Substring(0, 32)
        $originSegmentId = (Get-YakuTerminologyHash -Text ('legacy-personal-term|' + $identity)).Substring(0, 32)
        $version = 1
        $created = ''
        if ($currentById.ContainsKey($termId)) {
            $old = $currentById[$termId]
            if ([bool]$old.active -and [string]$old.ja.preferred -eq [string]$row.Source -and [string]$old.en.preferred -eq [string]$row.Target) { continue }
            # 利用者が取り消した登録を、CSVが残っているという理由だけで作り直さない。
            # 通常はCSVの行も一緒に消しているが、共有フォルダ上などで消せなかったときの保険。
            if (-not [bool]$old.active -and [string]$old.origin -eq 'personal-glossary-remove' -and
                [string]$old.ja.preferred -eq [string]$row.Source -and [string]$old.en.preferred -eq [string]$row.Target) { continue }
            $version = [int]$old.version + 1
            $created = [string]$old.created
        }
        $entry = New-YakuTerminologyEntry -TermId $termId -Version $version -Scope personal -Kind cell_exact -Enforcement advisory `
            -JapanesePreferred ([string]$row.Source) -EnglishPreferred ([string]$row.Target) `
            -Origin 'legacy-personal-csv' -OriginProjectId $originProjectId -OriginFileName ([IO.Path]::GetFileName($legacy)) `
            -OriginSegmentId $originSegmentId -OriginLocation 'legacy personal glossary' -OriginRevision 0 -CreatedAt $created
        $result = Add-YakuTerminologyRecord -Entry $entry -Path $termPath
        if ([bool]$result.Added) { $migrated++; $currentById[$termId] = $entry }
    }
    return [pscustomobject]@{ Migrated=$migrated; LegacyPath=$legacy; TerminologyPath=$termPath }
}

function Remove-YakuLegacyPersonalGlossaryRow {
    <#
      旧CSVから1行だけ消す。

      これをやらないと、次回読み込みの移行処理（Invoke-YakuPersonalGlossaryMigration）が
      「CSVにあるのに無効になっている」entryを見つけて版を上げ、active=$true で
      作り直してしまう。利用者から見ると「消したのに戻ってくる」になる。
    #>
    param([AllowNull()][string]$Source, [AllowNull()][string]$Path)
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuPersonalGlossaryPath } else { [string]$Path }
    $target = [IO.Path]::GetFullPath($target)
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $false }
    $wanted = ([string]$Source).Trim()
    if ([string]::IsNullOrWhiteSpace($wanted)) { return $false }
    $kept = New-Object Collections.Generic.List[string]
    $removed = $false
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($target, [Text.UTF8Encoding]::new($true))) {
        $lineNumber++
        $m = [regex]::Match($line, '^\s*(?:"(?<a>(?:[^"]|"")*)"|(?<a>[^,]*))\s*,\s*(?:"(?<b>(?:[^"]|"")*)"|(?<b>.*?))\s*$')
        $isRow = $false
        if ($m.Success -and $lineNumber -ne 1) { $isRow = $true }
        elseif ($m.Success -and $lineNumber -eq 1) {
            $head = $m.Groups['a'].Value.Replace('""', '"').Trim().TrimStart([char]0xFEFF)
            $isRow = -not [string]::Equals($head, 'source', [StringComparison]::OrdinalIgnoreCase)
        }
        if ($isRow) {
            $rowSource = $m.Groups['a'].Value.Replace('""', '"').Trim().TrimStart([char]0xFEFF)
            if ([string]::Equals($rowSource, $wanted, [StringComparison]::Ordinal)) { $removed = $true; continue }
        }
        $kept.Add($line) | Out-Null
    }
    if (-not $removed) { return $false }
    [IO.File]::WriteAllLines($target, @($kept.ToArray()), [Text.UTF8Encoding]::new($true))
    return $true
}

function Remove-YakuPersonalGlossaryEntry {
    <#
      今後の資料で使う登録（personal スコープ）を1件取り消す。

      記録は追記式なので、行を消すのではなく active=$false の版を足す。
      いつ誰が消したかが残り、過去に使った行の記録も壊れない。
      由来が旧CSVのものは、CSV側からも消す（でないと復活する）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TermId,
        [AllowNull()][string]$LegacyPath,
        [AllowNull()][string]$TerminologyPath
    )
    $id = ([string]$TermId).Trim().ToLowerInvariant()
    if ($id -notmatch '^[a-f0-9]{32}$') { throw 'PERSONAL_GLOSSARY_TERM_ID_INVALID: 取り消す登録を特定できませんでした。画面を読み込み直してからもう一度お試しください。' }
    $termPath = if ([string]::IsNullOrWhiteSpace($TerminologyPath)) { Get-YakuPersonalTerminologyPath } else { [string]$TerminologyPath }
    $entries = @(Read-YakuPersonalTerminologyEntries -LegacyPath $LegacyPath -TerminologyPath $TerminologyPath -IncludeInactive |
        Where-Object { [string]$_.term_id -eq $id })
    if ($entries.Count -lt 1) { throw 'PERSONAL_GLOSSARY_ENTRY_NOT_FOUND: その登録は見つかりませんでした。すでに取り消されている可能性があります。' }
    $current = $entries[$entries.Count - 1]
    if ([string]$current.scope -ne 'personal') {
        throw 'PERSONAL_GLOSSARY_SCOPE_MISMATCH: これは1つの資料の中だけで使う登録です。その資料を開いて取り消してください。'
    }
    $legacyRemoved = $false
    if ([string]$current.origin -eq 'legacy-personal-csv') {
        try { $legacyRemoved = [bool](Remove-YakuLegacyPersonalGlossaryRow -Source ([string]$current.ja.preferred) -Path $LegacyPath) } catch { $legacyRemoved = $false }
    }
    if (-not [bool]$current.active) {
        return [pscustomobject]@{ Removed=$false; Reason='already-removed'; LegacyRemoved=$legacyRemoved; Entry=$current }
    }
    $entry = New-YakuTerminologyEntry -TermId $id -Version ([int]$current.version + 1) -Active $false `
        -Scope personal -Kind ([string]$current.kind) -Enforcement ([string]$current.enforcement) `
        -JapanesePreferred ([string]$current.ja.preferred) -EnglishPreferred ([string]$current.en.preferred) `
        -JapaneseAllowed @($current.ja.allowed) -JapaneseForbidden @($current.ja.forbidden) `
        -EnglishAllowed @($current.en.allowed) -EnglishForbidden @($current.en.forbidden) `
        -Note ([string]$current.note) -Origin 'personal-glossary-remove' `
        -OriginProjectId ([string]$current.origin_project_id) -OriginFileName ([string]$current.origin_file_name) `
        -OriginSegmentId ([string]$current.origin_segment_id) -OriginLocation ([string]$current.origin_location) `
        -OriginRevision ([int]$current.origin_revision) -CreatedAt ([string]$current.created)
    $result = Add-YakuTerminologyRecord -Entry $entry -Path $termPath
    return [pscustomobject]@{ Removed=[bool]$result.Added; Reason=''; LegacyRemoved=$legacyRemoved; Entry=$entry }
}

function Read-YakuPersonalTerminologyEntries {
    param(
        [AllowNull()][string]$LegacyPath,
        [AllowNull()][string]$TerminologyPath,
        [AllowNull()][string]$ProjectId,
        [switch]$IncludeInactive,
        [switch]$Strict
    )
    $null = Invoke-YakuPersonalGlossaryMigration -LegacyPath $LegacyPath -TerminologyPath $TerminologyPath
    $target = if ([string]::IsNullOrWhiteSpace($TerminologyPath)) { Get-YakuPersonalTerminologyPath } else { [string]$TerminologyPath }
    return @(Read-YakuTerminologyEntries -Path $target -ProjectId $ProjectId -IncludeInactive:$IncludeInactive -Strict:$Strict)
}

function Read-YakuPersonalGlossary {
    <# Return the old source->target map while preferring active v2 records. #>
    param(
        [AllowNull()][string]$LegacyPath,
        [AllowNull()][string]$TerminologyPath
    )
    $map = [ordered]@{}
    foreach ($row in @(Read-YakuLegacyPersonalGlossaryRows -Path $LegacyPath)) { $map[[string]$row.Source] = [string]$row.Target }
    foreach ($entry in @(Read-YakuPersonalTerminologyEntries -LegacyPath $LegacyPath -TerminologyPath $TerminologyPath)) {
        if (-not [bool]$entry.active) { continue }
        # This compatibility API has no project context.  Returning project
        # terms here would make a "this document only" entry part of the old
        # global glossary merge used by every project (and by Quick).  CAT reads
        # project terms through Read-YakuPersonalTerminologyEntries -ProjectId.
        if ([string]$entry.scope -ne 'personal') { continue }
        $map[[string]$entry.ja.preferred] = [string]$entry.en.preferred
    }
    return $map
}

function Add-YakuPersonalGlossaryEntry {
    <#
      Backward-compatible writer.  New callers pass provenance and get a v2
      terminology record.  Old callers continue to append CSV and are migrated
      by the next read.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target,
        [AllowNull()][string]$OriginProjectId,
        [AllowNull()][string]$OriginFileName,
        [AllowNull()][string]$OriginSegmentId,
        [AllowNull()][string]$OriginLocation,
        [int]$OriginRevision = 0,
        [AllowNull()][string]$TerminologyPath
    )
    $sourceText = ([string]$Source).Trim()
    $targetText = ([string]$Target).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceText) -or [string]::IsNullOrWhiteSpace($targetText)) {
        return [pscustomobject]@{ Added=$false; Reason='empty' }
    }
    if ($sourceText.Length -gt 40 -or $sourceText -match '[。．]') {
        return [pscustomobject]@{ Added=$false; Reason='too-long' }
    }
    $hasProvenance = ([string]$OriginProjectId -match '^[a-fA-F0-9]{32}$' -and
        [string]$OriginSegmentId -match '^[a-fA-F0-9]{32}$' -and
        -not [string]::IsNullOrWhiteSpace($OriginFileName) -and -not [string]::IsNullOrWhiteSpace($OriginLocation))
    if ($hasProvenance) {
        return (Add-YakuTerminologyEntry -Scope personal -Kind cell_exact -Enforcement advisory `
            -JapanesePreferred $sourceText -EnglishPreferred $targetText -Origin 'cat-label-editor' `
            -OriginProjectId $OriginProjectId -OriginFileName $OriginFileName -OriginSegmentId $OriginSegmentId `
            -OriginLocation $OriginLocation -OriginRevision $OriginRevision -Path $TerminologyPath)
    }

    $existing = Read-YakuPersonalGlossary
    if ($existing.Contains($sourceText) -and [string]$existing[$sourceText] -eq $targetText) {
        return [pscustomobject]@{ Added=$false; Reason='same' }
    }
    $path = Get-YakuPersonalGlossaryPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $quote = { param([string]$Value) if ($Value -match '[",]') { return '"' + $Value.Replace('"', '""') + '"' } return $Value }
    $line = (& $quote $sourceText) + ',' + (& $quote $targetText)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [IO.File]::WriteAllLines($path, [string[]]@('source,target', $line), [Text.UTF8Encoding]::new($true))
    } else {
        [IO.File]::AppendAllLines($path, [string[]]@($line), [Text.UTF8Encoding]::new($true))
    }
    try { Write-YakuLog "Personal glossary entry added. source=$sourceText" 'INFO' } catch {}
    return [pscustomobject]@{ Added=$true; Reason=$(if ($existing.Contains($sourceText)) { 'updated' } else { 'new' }) }
}
