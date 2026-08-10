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
