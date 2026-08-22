<#
.SYNOPSIS
  Cell-exact glossary candidate import gate (V91.77).

.DESCRIPTION
  The extractor produced candidates but nothing could carry them into the
  cell-exact store, so the one guarantee CLAUDE.md calls non-negotiable
  (whole-cell exact replacement, kept for layout) had no way to grow.

  This file is written in ASCII only.  Japanese test data is assembled from
  code points and printed before use, because a throwaway .ps1 without a BOM
  silently mangles Japanese literals on Windows PowerShell 5.1 and the run
  then "measures" broken input.

  Every check carries an id.  The ids are registered up front and the run
  fails if any registered id did not fire, if an unregistered id fired, or if
  an id fired twice.  Without that, an early throw or an accidental `continue`
  would remove assertions from the run while the file still looked green.

  The bar every assertion here has to clear: *if the implementation broke,
  would this value change?*  Several checks did not clear it and were rewritten
  or removed on 2026-08-16.

    - CASE g measured the extractor by looking for function names in its AST.
      Measured, not argued: inserting `$columns = [ordered]@{...}` right after
      the call to Get-YakuCellGlossaryCandidateColumns left the gate at
      exit=0, and disabling the already-registered exclusion with
      `if ($false -and ...)` did the same.  Both are now measured by running
      the extracted functions for real (g2, g3).
    - g6 was a list of forbidden writers plus a spelling check on the -Path
      argument.  Rebinding $OutputPath right after the export call passed it at
      exit=0 while the extractor wrote to A and named B three times in its
      printed guidance, and so did appending to the written file with
      [IO.File]::AppendAllText, which was simply not on the list.  Guidance is
      now built by the shipped code from the file it wrote, g6 measures that by
      reading the named file and importing from it, g9 measures that guidance
      for a file that was never written is refused, and g8 replaces the
      denylist with an allowlist over everything the extractor may invoke.
    - Nothing ran the extractor's printing.  g6 measured the handoff object, and
      the extractor then printed it with a Write-Host loop nobody looked at.
      Measured on that shape: appending one line to the extractor --
      `Write-Host ('...' + (Join-Path $toolsRoot 'MUT-DECOY.csv'))`, with no
      other change at all -- left this gate at exit=0 while the extractor wrote
      one file and named another as the file it had written.  The printing now
      lives in shipped functions: g10 runs the printer and compares what it
      actually emitted, g13 drives the line builders, g11 holds the extractor to
      printing only through them and never with text of its own, g12 stops it
      spelling a .csv name at all, and Write-Host is off g8's allowlist.
    - Three clauses were removed for asserting things that could not be false
      (2026-08-16, one per case).  p1 asked whether a file inside a GUID
      directory this run had just created existed yet; the useful half of it is
      now the "before" of a transition asserted in a2.  a2's own third clause
      compared Get-YakuPersonalTerminologyPath against Get-YakuSubDir
      'terminology' -- the first is built from the second in the same process.
      a8's fourth clause compared the gate's Join-Path with the gate's
      GetDirectoryName; it now asserts the store is byte-identical across the
      three refusals instead.
    - A check that no glossary.csv appears in the release tree was dropped.
      It was true before this change began, no path in this change can create
      that file, and tools\Smoke-Test.ps1 already asserts the same thing for
      the release tree.  It could never have failed for a reason this gate
      is responsible for.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$src = Join-Path $root 'src'
$script:fail = 0
$script:Fired = @{}

. (Join-Path $src 'Paths.ps1')
. (Join-Path $src 'Terminology.ps1')
. (Join-Path $src 'PersonalGlossary.ps1')

# --- reachability registry ------------------------------------------------
$script:Expected = @(
    'p1',
    'a1', 'a2', 'a3', 'a4', 'a5', 'a7', 'a8',
    'b1', 'b2', 'b3', 'b4', 'b5', 'b6',
    'c1', 'c2', 'c3', 'c4',
    'd1', 'd2', 'd3', 'd4', 'd5', 'd6',
    'e1', 'e2', 'e3',
    'x1', 'x2',
    'g1', 'g2', 'g3', 'g4', 'g5', 'g6', 'g7', 'g8', 'g9', 'g10', 'g11', 'g12', 'g13'
)

function Chk {
    param([string]$Id, [bool]$Condition, [string]$Message)
    if ($script:Fired.ContainsKey($Id)) { $script:Fired[$Id] = [int]$script:Fired[$Id] + 1 }
    else { $script:Fired[$Id] = 1 }
    if ($Condition) { Write-Host ('  ok   [' + $Id + '] ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL [' + $Id + '] ' + $Message) -ForegroundColor Red; $script:fail++ }
}

function Show-CodePoints {
    param([string]$Label, [string]$Text)
    $points = @([int[]][char[]]$Text | ForEach-Object { 'U+{0:X4}' -f $_ })
    Write-Host ('  data ' + $Label + ' len=' + $Text.Length + ' [' + ($points -join ' ') + ']')
}

function ConvertTo-CsvField {
    param([AllowNull()][string]$Value)
    return ('"' + ([string]$Value).Replace('"', '""') + '"')
}

function New-CandidateCsv {
    param([string]$FilePath, [AllowNull()][object[]]$Rows)
    $cols = Get-YakuCellGlossaryCandidateColumns
    $keys = @('Adopt', 'Source', 'Target', 'Kind', 'Count', 'Conflict', 'Confidence', 'Location')
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add((@($keys | ForEach-Object { ConvertTo-CsvField -Value ([string]$cols[$_]) }) -join ',')) | Out-Null
    foreach ($row in @($Rows)) {
        $lines.Add((@($keys | ForEach-Object { ConvertTo-CsvField -Value ([string]$row[$_]) }) -join ',')) | Out-Null
    }
    $text = (($lines.ToArray()) -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($FilePath, $text, (New-Object Text.UTF8Encoding($true)))
}

function Get-FileSha {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return 'absent' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($FilePath))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-DirSnapshot {
    param([string]$Dir)
    $out = New-Object Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $out.Add([string]$f.FullName + '|' + (Get-FileSha -FilePath ([string]$f.FullName))) | Out-Null
    }
    return (($out.ToArray()) -join "`n")
}

function Get-AstCommandCalls {
    <#
      Every CommandAst under $Ast whose command name is $Name.  Used instead of
      "does this name appear in the file" so that CASE g can look at *which
      expression* a value came from rather than at the presence of a word.
    #>
    param($Ast, [string]$Name)
    $found = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    return @($found | Where-Object {
        $commandName = ''
        try { $commandName = [string]$_.GetCommandName() } catch { $commandName = '' }
        [string]::Equals($commandName, $Name, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-AstNamedArgumentText {
    # Source text of the argument bound to -<ParameterName> on one command.
    param($Command, [string]$ParameterName)
    $elements = @($Command.CommandElements)
    for ($i = 0; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        if (-not [string]::Equals([string]$element.ParameterName, $ParameterName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($null -ne $element.Argument) { return [string]$element.Argument.Extent.Text }
        if ($i + 1 -lt $elements.Count) { return [string]$elements[$i + 1].Extent.Text }
        return ''
    }
    return ''
}

function Get-AstAssignmentsTo {
    # Every assignment whose left-hand side is the plain variable $<Name>.
    param($Ast, [string]$Name)
    $found = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    return @($found | Where-Object {
        ($_.Left -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        [string]::Equals([string]$_.Left.VariablePath.UserPath, $Name, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Get-CsvPropertyName {
    # Import-Csv may or may not hand back the BOM on the first header, so pick
    # the property by its trimmed name instead of assuming either shape.
    param($Row, [string]$Header)
    foreach ($name in @($Row.PSObject.Properties.Name)) {
        if ([string]::Equals(([string]$name).TrimStart([char]0xFEFF).Trim(), $Header, [StringComparison]::Ordinal)) { return [string]$name }
    }
    return ''
}

function Get-StoreLines {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return @() }
    return @([IO.File]::ReadAllLines($FilePath, [Text.UTF8Encoding]::new($false)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# --- test data ------------------------------------------------------------
# [string]::Concat with four arguments throws ArgumentNullException here on
# Windows PowerShell 5.1 (measured 2026-08-16), so build every literal one code
# point at a time and print the result before using it.
function New-TextFromCodePoints {
    param([AllowNull()][int[]]$Points)
    $sb = New-Object Text.StringBuilder
    foreach ($point in @($Points)) { $null = $sb.Append([char][int]$point) }
    return $sb.ToString()
}

$SALES  = New-TextFromCodePoints -Points @(0x58F2, 0x4E0A, 0x9AD8)          # net sales
$COGS   = New-TextFromCodePoints -Points @(0x58F2, 0x4E0A, 0x539F, 0x4FA1)  # cost of sales
$OPINC  = New-TextFromCodePoints -Points @(0x55B6, 0x696D, 0x5229, 0x76CA)  # operating income
$EQUITY = New-TextFromCodePoints -Points @(0x7D14, 0x8CC7, 0x7523)          # net assets
$TOTAL  = New-TextFromCodePoints -Points @(0x5408, 0x8A08)                  # total
$ORD    = New-TextFromCodePoints -Points @(0x7D4C, 0x5E38, 0x5229, 0x76CA)  # ordinary income
$ASSETS = New-TextFromCodePoints -Points @(0x7DCF, 0x8CC7, 0x7523)          # total assets
$CASH   = New-TextFromCodePoints -Points @(0x73FE, 0x91D1)                  # cash
$LIAB   = New-TextFromCodePoints -Points @(0x8CA0, 0x50B5)                  # liabilities
$CAPITAL= New-TextFromCodePoints -Points @(0x8CC7, 0x672C, 0x91D1)          # capital stock
$DEBT   = New-TextFromCodePoints -Points @(0x793E, 0x50B5)                  # bonds payable
$INVENT = New-TextFromCodePoints -Points @(0x68DA, 0x5378, 0x8CC7, 0x7523)  # inventories
$DEPREC = New-TextFromCodePoints -Points @(0x6E1B, 0x4FA1, 0x511F, 0x5374, 0x8CBB) # depreciation
$MARU   = New-TextFromCodePoints -Points @(0x3007)                          # adoption mark
$ACTUAL = New-TextFromCodePoints -Points @(0x5B9F, 0x6E2C)                  # candidate kind
$SALES_PADDED = (New-TextFromCodePoints -Points @(0x0020, 0x3000)) + $SALES + (New-TextFromCodePoints -Points @(0x3000))
$SALES_NEAR   = $SALES + (New-TextFromCodePoints -Points @(0x7387))

Write-Host 'test data (verify these before trusting any result below)' -ForegroundColor Cyan
Show-CodePoints -Label 'SALES ' -Text $SALES
Show-CodePoints -Label 'COGS  ' -Text $COGS
Show-CodePoints -Label 'OPINC ' -Text $OPINC
Show-CodePoints -Label 'EQUITY' -Text $EQUITY
Show-CodePoints -Label 'TOTAL ' -Text $TOTAL
Show-CodePoints -Label 'ORD   ' -Text $ORD
Show-CodePoints -Label 'ASSETS' -Text $ASSETS
Show-CodePoints -Label 'CASH  ' -Text $CASH
Show-CodePoints -Label 'LIAB  ' -Text $LIAB
Show-CodePoints -Label 'CAPITL' -Text $CAPITAL
Show-CodePoints -Label 'DEBT  ' -Text $DEBT
Show-CodePoints -Label 'INVENT' -Text $INVENT
Show-CodePoints -Label 'DEPREC' -Text $DEPREC
Show-CodePoints -Label 'MARU  ' -Text $MARU
Show-CodePoints -Label 'PADDED' -Text $SALES_PADDED
Show-CodePoints -Label 'NEAR  ' -Text $SALES_NEAR

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-cellglo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$csvDir = Join-Path $tmp 'csv'
$null = New-Item -ItemType Directory -Path $csvDir -Force
$oldData = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'data'

try {
    $storePath = Get-YakuPersonalTerminologyPath
    Write-Host ''
    Write-Host 'CASE 0: arrangement' -ForegroundColor Cyan
    # p1 is not about the importer.  It is the check that this run writes into a
    # store this run created: if YAKULINGO_DATA_DIR stopped being honoured the run
    # would otherwise go green while appending test terms to the user's own
    # glossary.  The location is what matters, so the location is what is
    # asserted, and the run is aborted here rather than after the first write.
    #
    # p1's second clause -- "and the store file does not exist yet" -- was dropped
    # on 2026-08-16.  $tmp is a GUID directory created four statements earlier in
    # this same run, so once the first clause holds the second cannot be false.
    # It is worth something only as the "before" half of a transition, so it is
    # recorded here and asserted against the "after" in a2.
    $tmpPrefix = [IO.Path]::GetFullPath($tmp).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    $storeFull = [IO.Path]::GetFullPath($storePath)
    $storeUnderTmp = $storeFull.StartsWith($tmpPrefix, [StringComparison]::OrdinalIgnoreCase)
    $storeExistedBefore = Test-Path -LiteralPath $storeFull -PathType Leaf
    Write-Host ('  data store before the first import: exists=' + [string]$storeExistedBefore + ' path=' + $storeFull)
    Chk 'p1' $storeUnderTmp `
        ('the store this run will write to is inside this run''s own temp directory (' + $storeFull + ')')
    if (-not $storeUnderTmp) {
        throw ('CELL_GLOSSARY_GATE_STORE_NOT_REDIRECTED: refusing to write to ' + $storeFull)
    }

    $csv1 = Join-Path $csvDir 'candidates.csv'
    New-CandidateCsv -FilePath $csv1 -Rows @(
        @{ Adopt='o';     Source=$SALES;  Target='Net sales';        Kind=$ACTUAL; Count='7'; Confidence='high';   Location='Sheet1!A5 -> Sheet1!A5' },
        @{ Adopt='';      Source=$COGS;   Target='Cost of sales';    Kind=$ACTUAL; Count='6'; Confidence='high';   Location='Sheet1!A6 -> Sheet1!A6' },
        @{ Adopt='x';     Source=$OPINC;  Target='Operating income'; Kind=$ACTUAL; Count='5'; Confidence='high';   Location='Sheet1!A7 -> Sheet1!A7' },
        @{ Adopt='o';     Source=$EQUITY; Target='Net assets';       Kind=$ACTUAL; Count='4'; Confidence='medium'; Location='' },
        @{ Adopt=$MARU;   Source=$TOTAL;  Target='Total';            Kind=$ACTUAL; Count='9'; Confidence='high';   Location='Sheet1!A9 -> Sheet1!B9' }
    )
    $csvDirBefore = Get-DirSnapshot -Dir $csvDir

    Write-Host ''
    Write-Host 'CASE a: the adopted rows reach the local cell_exact store' -ForegroundColor Cyan
    $r1 = Import-YakuCellGlossaryCandidates -Path $csv1
    Chk 'a1' ([int]$r1.Imported -eq 2 -and [int]$r1.Updated -eq 0) ('exactly the two well-formed adopted rows were imported (got ' + [string]$r1.Imported + ')')
    $localDir = [IO.Path]::GetFullPath((Get-YakuSubDir 'terminology'))
    # a2's third clause -- GetFullPath($storePath) starts with $localDir -- was
    # dropped on 2026-08-16.  Get-YakuPersonalTerminologyPath is literally
    # Join-Path (Get-YakuSubDir 'terminology') 'personal-v2.jsonl', so within one
    # process the two sides are built by the same call and the clause cannot be
    # false whatever the importer does.  What is load-bearing is the transition:
    # the store did not exist before this import (recorded at p1) and the path the
    # importer reports is the file that now does.
    #
    # The (-not $storeExistedBefore) conjunct went the same way on 2026-08-16.
    # $storeExistedBefore is a Test-Path under $tmp, and $tmp is a fresh GUID
    # directory created four statements earlier, so it cannot be anything but
    # False.  The one story that would make it True -- YAKULINGO_DATA_DIR no
    # longer redirecting -- is thrown by p1 before a2 is reached.  Measured:
    # replacing the conjunct with $true left the gate at exit=0 and both runs
    # printed exists=False under different GUIDs.  It was the gate checking its
    # own setup.  The two clauses that remain measure the transition itself.
    Chk 'a2' ((Test-Path -LiteralPath $storePath -PathType Leaf) -and
              [string]::Equals([string]$r1.TerminologyPath, [IO.Path]::GetFullPath($storePath), [StringComparison]::OrdinalIgnoreCase)) `
        'the first import created the store file, and the path it reports writing to is that file'
    $lines = @(Get-StoreLines -FilePath $storePath)
    $parsed = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
    Chk 'a3' ($lines.Count -eq 2 -and
              @($parsed | Where-Object { [string]$_.kind -eq 'cell_exact' -and [string]$_.scope -eq 'personal' -and [int]$_.version -eq 1 -and [bool]$_.active }).Count -eq 2) `
        'both appended records are active personal cell_exact revisions at version 1'
    $pairs = @($parsed | ForEach-Object { [string]$_.ja.preferred + '=>' + [string]$_.en.preferred } | Sort-Object)
    $wantPairs = @(($SALES + '=>Net sales'), ($TOTAL + '=>Total')) | Sort-Object
    Chk 'a4' ((($pairs -join '|') -eq ($wantPairs -join '|'))) 'the stored pairs are exactly the adopted source/target pairs from the CSV'
    # The candidate CSV is the user's working copy; the importer reads it and
    # owes it nothing.  The snapshot is by content hash, so a rewrite that
    # happened to keep the byte count would still show up.
    Chk 'a5' ((Get-DirSnapshot -Dir $csvDir) -eq $csvDirBefore) `
        'importing leaves every file in the candidate folder byte-identical'
    $outside = Join-Path $tmp 'outside-store.jsonl'
    $outsideCode = ''
    try { $null = Import-YakuCellGlossaryCandidates -Path $csv1 -TerminologyPath $outside }
    catch { $outsideCode = ([string]$_.Exception.Message -split ':', 2)[0] }
    Chk 'a7' ($outsideCode -eq 'CELL_GLOSSARY_TARGET_OUTSIDE_LOCAL_STORE' -and -not (Test-Path -LiteralPath $outside)) `
        'a store path outside the local terminology directory is refused and nothing is written there'

    # The refusal is a prefix test on a resolved path.  These are the shapes
    # that slip through a prefix test written carelessly: a sibling folder
    # whose name merely starts with the allowed one, a path that walks back out
    # with .., and a UNC path (the share this app must never write to).
    # The refusal is a prefix test on a resolved path, so these are the shapes a
    # careless prefix test lets through.  The UNC one is never probed with
    # Test-Path: touching a share is the very thing being refused.
    $localBase = $localDir.TrimEnd([char[]]@('\', '/'))
    $siblingStore = Join-Path ($localBase + '-evil') 'personal-v2.jsonl'
    $walkedOutStore = [IO.Path]::GetFullPath((Join-Path $localDir '..\escaped-store.jsonl'))
    $escapes = @($siblingStore, $walkedOutStore, '\\yakulingo-no-such-host\share\team\personal-v2.jsonl')
    $escapeCodes = New-Object Collections.Generic.List[string]
    # a8's fourth clause used to re-derive the parent of the walk-out path and
    # compare it with the parent of the local directory.  That is the gate
    # checking its own Join-Path against its own GetDirectoryName -- both sides
    # come from this file and neither can move when the importer breaks.  Dropped
    # 2026-08-16.  In its place: nothing was written anywhere while the three
    # refusals happened.  A refusal that appended first, or that quietly fell back
    # to the default store, moves this hash.
    $shaBeforeEscapes = Get-FileSha -FilePath $storePath
    foreach ($escape in $escapes) {
        $code = ''
        try { $null = Import-YakuCellGlossaryCandidates -Path $csv1 -TerminologyPath $escape }
        catch { $code = ([string]$_.Exception.Message -split ':', 2)[0] }
        $escapeCodes.Add($code) | Out-Null
    }
    Chk 'a8' (@($escapeCodes.ToArray() | Where-Object { $_ -eq 'CELL_GLOSSARY_TARGET_OUTSIDE_LOCAL_STORE' }).Count -eq 3 -and
              -not (Test-Path -LiteralPath ($localBase + '-evil')) -and
              -not (Test-Path -LiteralPath $walkedOutStore) -and
              (Get-FileSha -FilePath $storePath) -eq $shaBeforeEscapes) `
        'a same-prefix sibling folder, a .. walk-out and a UNC share are all refused, none of them is created, and the real store is untouched'

    Write-Host ''
    Write-Host 'CASE b: the appended rows survive re-read and resolve through the cell-exact engine' -ForegroundColor Cyan
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    Chk 'b1' ($entries.Count -eq 2) 'strict re-read accepts both appended rows (reference_id recomputation passes)'
    $hit = Find-YakuCellExactTerminologyMatch -Text $SALES -Direction to_en -Entries $entries -ProjectId ''
    Chk 'b2' ($null -ne $hit -and [string]$hit.Target -eq 'Net sales') 'the imported row resolves through Find-YakuCellExactTerminologyMatch'
    $padded = Find-YakuCellExactTerminologyMatch -Text $SALES_PADDED -Direction to_en -Entries $entries -ProjectId ''
    # Both sides are normalised and trimmed by the matcher, so this says nothing
    # about the shape of the stored text.  What it holds down is the matcher's
    # own normalisation: a label carrying leading/trailing and full-width spaces
    # (the ordinary state of a spreadsheet label) still reaches its row.
    Chk 'b3' ($null -ne $padded -and [string]$padded.Target -eq 'Net sales') `
        'a cell padded with ASCII and full-width spaces still resolves to the imported row'
    $back = Find-YakuCellExactTerminologyMatch -Text 'net sales' -Direction to_jp -Entries $entries -ProjectId ''
    Chk 'b4' ($null -ne $back -and [string]$back.Target -eq $SALES) 'the same row resolves in the reverse direction'
    Chk 'b5' ($null -eq (Find-YakuCellExactTerminologyMatch -Text $SALES_NEAR -Direction to_en -Entries $entries -ProjectId '')) `
        'a longer neighbouring label does not resolve (the match stays whole-cell exact)'
    $storeBytes = [IO.File]::ReadAllBytes($storePath)
    $tampered = ([IO.File]::ReadAllText($storePath, [Text.UTF8Encoding]::new($false))).Replace('Net sales', 'Net revenue')
    [IO.File]::WriteAllText($storePath, $tampered, [Text.UTF8Encoding]::new($false))
    $strictCode = ''
    try { $null = @(Read-YakuTerminologyEntries -Path $storePath -Strict) } catch { $strictCode = [string]$_.Exception.Message }
    $afterTamper = @(Read-YakuTerminologyEntries -Path $storePath)
    [IO.File]::WriteAllBytes($storePath, $storeBytes)
    Chk 'b6' ($strictCode -eq 'TERMINOLOGY_STORE_INVALID_PROVENANCE' -and $afterTamper.Count -eq 1) `
        'editing the appended line breaks its reference_id and drops it from the read (the check is load-bearing on this record)'

    Write-Host ''
    Write-Host 'CASE c: rows without an adoption mark stay out' -ForegroundColor Cyan
    $entries = @(Read-YakuTerminologyEntries -Path $storePath)
    Chk 'c1' ($null -eq (Find-YakuCellExactTerminologyMatch -Text $COGS -Direction to_en -Entries $entries -ProjectId '') -and
              @($entries | Where-Object { [string]$_.ja.preferred -eq $COGS }).Count -eq 0) `
        'the unmarked neighbour of an adopted row is neither stored nor resolvable'
    Chk 'c2' ($null -eq (Find-YakuCellExactTerminologyMatch -Text $OPINC -Direction to_en -Entries $entries -ProjectId '') -and
              @($entries | Where-Object { [string]$_.ja.preferred -eq $OPINC }).Count -eq 0) `
        'a row marked with an unrecognised character is not treated as adopted'
    $marks = @($r1.UnrecognizedMarks)
    Chk 'c3' ($marks.Count -eq 1 -and [string]$marks[0].Source -eq $OPINC -and [string]$marks[0].Mark -eq 'x') `
        'the unrecognised mark is reported to the user rather than dropped in silence'
    # Not just "two terms come back": the refused sources must be absent from
    # the file itself.  A version that wrote every row and then deactivated the
    # bad ones would still return two terms here.
    # The IndexOf checks below are only worth anything if an adopted source is
    # found by the same search, so an adopted one is asserted present first.
    # (Windows PowerShell 5.1 ConvertTo-Json leaves these characters unescaped;
    # measured 2026-08-16 -- U+58F2 is emitted as the character itself, not as
    # a backslash-u escape, so a literal search does reach it.)
    $rawStore = [IO.File]::ReadAllText($storePath, [Text.UTF8Encoding]::new($false))
    Chk 'c4' (@($entries | Where-Object { [string]$_.kind -eq 'cell_exact' }).Count -eq 2 -and
              $rawStore.IndexOf($SALES, [StringComparison]::Ordinal) -ge 0 -and
              $rawStore.IndexOf($COGS, [StringComparison]::Ordinal) -lt 0 -and
              $rawStore.IndexOf($OPINC, [StringComparison]::Ordinal) -lt 0 -and
              $rawStore.IndexOf($EQUITY, [StringComparison]::Ordinal) -lt 0) `
        'the store holds exactly the valid adopted rows, and no refused source was written to the file at all'

    Write-Host ''
    Write-Host 'CASE d: re-importing is idempotent, but a corrected translation still lands' -ForegroundColor Cyan
    $shaBefore = Get-FileSha -FilePath $storePath
    $r2 = Import-YakuCellGlossaryCandidates -Path $csv1
    Chk 'd1' ([int]$r2.Imported -eq 0 -and [int]$r2.Updated -eq 0 -and [int]$r2.Skipped -eq 2) `
        'the second import of the same CSV adds nothing and reports both rows as already registered'
    Chk 'd2' ((Get-FileSha -FilePath $storePath) -eq $shaBefore) 'the store file is byte-identical after the second import'
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    $stillThere = Find-YakuCellExactTerminologyMatch -Text $SALES -Direction to_en -Entries $entries -ProjectId ''
    Chk 'd3' ($null -ne $stillThere -and [string]$stillThere.Target -eq 'Net sales') `
        'idempotency did not come from an empty store: the term still resolves'
    $totalTermId = [string](@($entries | Where-Object { [string]$_.ja.preferred -eq $TOTAL })[0].term_id)
    $csv2 = Join-Path $csvDir 'candidates-corrected.csv'
    New-CandidateCsv -FilePath $csv2 -Rows @(
        @{ Adopt='o';   Source=$SALES; Target='Net sales';    Kind=$ACTUAL; Count='7'; Confidence='high'; Location='Sheet1!A5 -> Sheet1!A5' },
        @{ Adopt=$MARU; Source=$TOTAL; Target='Total amount'; Kind=$ACTUAL; Count='9'; Confidence='high'; Location='Sheet1!A9 -> Sheet1!B9' }
    )
    $r3 = Import-YakuCellGlossaryCandidates -Path $csv2
    $lines = @(Get-StoreLines -FilePath $storePath)
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    $corrected = Find-YakuCellExactTerminologyMatch -Text $TOTAL -Direction to_en -Entries $entries -ProjectId ''
    Chk 'd4' ([int]$r3.Updated -eq 1 -and [int]$r3.Imported -eq 0 -and $lines.Count -eq 3 -and
              $null -ne $corrected -and [string]$corrected.Target -eq 'Total amount' -and
              [int]$corrected.Version -eq 2 -and [string]$corrected.TermId -eq $totalTermId) `
        'a changed translation appends revision 2 under the same term_id and becomes the resolved target'
    Chk 'd5' ($entries.Count -eq 2) 'the superseded revision stays on disk but does not come back as a second term'
    # A term the user cancelled must not come back just because the CSV that
    # produced it is still lying around.  Nothing else measured the Withdrawn
    # counter, so a break here would have been silent.
    $salesTermId = [string](@($entries | Where-Object { [string]$_.ja.preferred -eq $SALES })[0].term_id)
    $removal = Remove-YakuPersonalGlossaryEntry -TermId $salesTermId
    $linesAfterRemove = @(Get-StoreLines -FilePath $storePath).Count
    $r7 = Import-YakuCellGlossaryCandidates -Path $csv2
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    Chk 'd6' ([bool]$removal.Removed -and [int]$r7.Withdrawn -eq 1 -and [int]$r7.Imported -eq 0 -and [int]$r7.Updated -eq 0 -and
              @(Get-StoreLines -FilePath $storePath).Count -eq $linesAfterRemove -and
              $null -eq (Find-YakuCellExactTerminologyMatch -Text $SALES -Direction to_en -Entries $entries -ProjectId '')) `
        'a cancelled term is not resurrected by re-importing the CSV it came from, and the store gains no line'

    Write-Host ''
    Write-Host 'CASE e: a candidate without provenance is refused by the terminology store' -ForegroundColor Cyan
    $bad = @($r1.Rejected)
    Chk 'e1' ($bad.Count -eq 1 -and [string]$bad[0].Code -eq 'TERMINOLOGY_PROVENANCE_REQUIRED' -and [string]$bad[0].Source -eq $EQUITY) `
        'the adopted row with an empty source-cell column is rejected with TERMINOLOGY_PROVENANCE_REQUIRED'
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    Chk 'e2' ($null -eq (Find-YakuCellExactTerminologyMatch -Text $EQUITY -Direction to_en -Entries $entries -ProjectId '') -and
              @($entries | Where-Object { [string]$_.ja.preferred -eq $EQUITY }).Count -eq 0) `
        'nothing from the rejected row leaked into the store'
    $csv3 = Join-Path $csvDir 'candidates-no-provenance.csv'
    New-CandidateCsv -FilePath $csv3 -Rows @(
        @{ Adopt='o'; Source=$EQUITY; Target='Net assets'; Kind=$ACTUAL; Count='4'; Confidence='medium'; Location='' }
    )
    $shaBefore = Get-FileSha -FilePath $storePath
    $r4 = Import-YakuCellGlossaryCandidates -Path $csv3
    Chk 'e3' ([int]$r4.Imported -eq 0 -and @($r4.Rejected).Count -eq 1 -and
              [string](@($r4.Rejected)[0].Code) -eq 'TERMINOLOGY_PROVENANCE_REQUIRED' -and
              (Get-FileSha -FilePath $storePath) -eq $shaBefore) `
        'a CSV whose only adopted row lacks provenance writes nothing at all'

    Write-Host ''
    Write-Host 'CASE x: competing translations are stopped before they are written' -ForegroundColor Cyan
    $csv4 = Join-Path $csvDir 'candidates-conflict.csv'
    New-CandidateCsv -FilePath $csv4 -Rows @(
        @{ Adopt='o'; Source=$ASSETS; Target='Total assets'; Kind=$ACTUAL; Count='3'; Confidence='high'; Location='Sheet2!A2 -> Sheet2!A2' },
        @{ Adopt='o'; Source=$ASSETS; Target='Gross assets'; Kind=$ACTUAL; Count='2'; Confidence='high'; Location='Sheet3!A2 -> Sheet3!A2' }
    )
    $shaBefore = Get-FileSha -FilePath $storePath
    $r5 = Import-YakuCellGlossaryCandidates -Path $csv4
    Chk 'x1' ([int]$r5.Imported -eq 0 -and @($r5.Rejected).Count -eq 2 -and
              @($r5.Rejected | Where-Object { [string]$_.Code -eq 'CELL_GLOSSARY_TARGET_CONFLICT' }).Count -eq 2 -and
              (Get-FileSha -FilePath $storePath) -eq $shaBefore) `
        'two adopted rows with the same source and different targets are both refused and nothing is written'
    $null = Add-YakuPersonalGlossaryEntry -Source $CASH -Target 'Cash' `
        -OriginProjectId '33333333333333333333333333333333' -OriginFileName 'FY2026.xlsx' `
        -OriginSegmentId '44444444444444444444444444444444' -OriginLocation 'Sheet1!B2'
    $shaBefore = Get-FileSha -FilePath $storePath
    $csv5 = Join-Path $csvDir 'candidates-rival.csv'
    New-CandidateCsv -FilePath $csv5 -Rows @(
        @{ Adopt='o'; Source=$CASH; Target='Cash and deposits'; Kind=$ACTUAL; Count='3'; Confidence='high'; Location='Sheet1!B2 -> Sheet1!B2' }
    )
    $r6 = Import-YakuCellGlossaryCandidates -Path $csv5
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    $cashHit = Find-YakuCellExactTerminologyMatch -Text $CASH -Direction to_en -Entries $entries -ProjectId ''
    Chk 'x2' ([int]$r6.Imported -eq 0 -and @($r6.Rejected).Count -eq 1 -and
              [string](@($r6.Rejected)[0].Code) -eq 'CELL_GLOSSARY_TARGET_CONFLICT' -and
              (Get-FileSha -FilePath $storePath) -eq $shaBefore -and
              $null -ne $cashHit -and [string]$cashHit.Target -eq 'Cash') `
        'a source already registered with a different target is refused at import instead of failing later at match time'

    Write-Host ''
    Write-Host 'CASE g: extractor and importer are one supply line' -ForegroundColor Cyan
    $extractPath = Join-Path $toolsRoot 'Extract-YakuCellGlossary.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($extractPath, [ref]$tokens, [ref]$parseErrors)
    $glossaryCsvTokens = @(@($tokens) | Where-Object { ([string]$_.Text).IndexOf('glossary.csv', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    Chk 'g1' (@($parseErrors).Count -eq 0 -and $glossaryCsvTokens.Count -eq 0) `
        'the extractor no longer names glossary.csv anywhere (code, help or printed guidance)'
    # g2: the round trip.  The extractor's row building and CSV writing now live
    # in Export-YakuCellGlossaryCandidateCsv, so the gate can drive the real
    # writer with extractor-shaped candidates, mark a row the way a user would,
    # and push that same file through the shipped importer.  No Excel needed.
    $extractorShaped = @(
        [pscustomobject]@{ Source=$LIAB; Target='Liabilities';   Origin=$ACTUAL; Count=6; Conflict=$false; Confidence='high'; Samples=@('Sheet5!A2 -> Sheet5!B2', 'Sheet6!A2 -> Sheet6!B2') },
        [pscustomobject]@{ Source=$DEBT; Target='Bonds payable'; Origin=$ACTUAL; Count=2; Conflict=$false; Confidence='low';  Samples=@('Sheet5!A3 -> Sheet5!B3') }
    )
    $supplyCsv = Join-Path $csvDir 'candidates-supply.csv'
    $written = Export-YakuCellGlossaryCandidateCsv -Entries $extractorShaped -Path $supplyCsv
    $cols = Get-YakuCellGlossaryCandidateColumns
    $reopened = @(Import-Csv -LiteralPath $supplyCsv -Encoding UTF8)
    $adoptProp = Get-CsvPropertyName -Row $reopened[0] -Header ([string]$cols['Adopt'])
    $sourceProp = Get-CsvPropertyName -Row $reopened[0] -Header ([string]$cols['Source'])
    if (-not [string]::IsNullOrEmpty($adoptProp)) { $reopened[0].$adoptProp = $MARU }
    $reopened | Export-Csv -LiteralPath $supplyCsv -NoTypeInformation -Encoding UTF8
    $r8 = Import-YakuCellGlossaryCandidates -Path $supplyCsv
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    $liabHit = Find-YakuCellExactTerminologyMatch -Text $LIAB -Direction to_en -Entries $entries -ProjectId ''
    $liabEntry = @($entries | Where-Object { [string]$_.ja.preferred -eq $LIAB })
    Chk 'g2' ([int]$written.Rows -eq 2 -and $reopened.Count -eq 2 -and
              -not [string]::IsNullOrEmpty($adoptProp) -and
              [string]$reopened[0].$sourceProp -eq $LIAB -and
              [int]$r8.Imported -eq 1 -and @($r8.Rejected).Count -eq 0 -and
              $null -ne $liabHit -and [string]$liabHit.Target -eq 'Liabilities' -and
              $liabEntry.Count -eq 1 -and
              [string]$liabEntry[0].origin_location -eq 'Sheet5!A2 -> Sheet5!B2 / Sheet6!A2 -> Sheet6!B2' -and
              $null -eq (Find-YakuCellExactTerminologyMatch -Text $DEBT -Direction to_en -Entries $entries -ProjectId '')) `
        'a row written by the extractor-side CSV writer imports as-is, carries its cell reference through as provenance, and only the marked row lands'

    # g3: the exclusion, measured by its effect.  Naming the function is not
    # enough; the count has to move when a term is registered, and the very
    # entry that was registered has to drop out of the candidate list.
    $exclusionCandidates = @(
        [pscustomobject]@{ Source=$CAPITAL; Target='Capital stock'; Origin=$ACTUAL; Count=4; Conflict=$false; Confidence='high'; Samples=@('Sheet7!A2 -> Sheet7!B2') },
        [pscustomobject]@{ Source=$DEBT;    Target='Bonds payable'; Origin=$ACTUAL; Count=2; Conflict=$false; Confidence='low';  Samples=@('Sheet5!A3 -> Sheet5!B3') }
    )
    $knownBefore = Get-YakuCellGlossaryKnownSources -Path $storePath
    $freshBefore = @(Select-YakuCellGlossaryUnregisteredEntries -Entries $exclusionCandidates -Known $knownBefore)
    $capitalCsv = Join-Path $csvDir 'candidates-exclusion.csv'
    New-CandidateCsv -FilePath $capitalCsv -Rows @(
        @{ Adopt=$MARU; Source=$CAPITAL; Target='Capital stock'; Kind=$ACTUAL; Count='4'; Confidence='high'; Location='Sheet7!A2 -> Sheet7!B2' }
    )
    $r9 = Import-YakuCellGlossaryCandidates -Path $capitalCsv
    $knownAfter = Get-YakuCellGlossaryKnownSources -Path $storePath
    $freshAfter = @(Select-YakuCellGlossaryUnregisteredEntries -Entries $exclusionCandidates -Known $knownAfter)
    Chk 'g3' ([int]$r9.Imported -eq 1 -and
              -not $knownBefore.ContainsKey($CAPITAL) -and $knownAfter.ContainsKey($CAPITAL) -and
              ([int]$knownAfter.Count - [int]$knownBefore.Count) -eq 1 -and
              $freshBefore.Count -eq 2 -and $freshAfter.Count -eq 1 -and
              [string]$freshAfter[0].Source -eq $DEBT) `
        'importing one term adds exactly that source to the known set and removes exactly that candidate from the next extraction'

    $csv6 = Join-Path $csvDir 'candidates-cli.csv'
    New-CandidateCsv -FilePath $csv6 -Rows @(
        @{ Adopt='o'; Source=$ORD; Target='Ordinary income'; Kind=$ACTUAL; Count='8'; Confidence='high'; Location='Sheet1!A11 -> Sheet1!B11' }
    )
    $importTool = Join-Path $toolsRoot 'Import-YakuCellGlossary.ps1'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importTool -CandidatePath $csv6
    $cliCode = $LASTEXITCODE
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    $ordHit = Find-YakuCellExactTerminologyMatch -Text $ORD -Direction to_en -Entries $entries -ProjectId ''
    # $null -eq is deliberate on both: an exit code that was never produced must
    # read as "not measured", not fold into either colour.  ($code -ne 0 would
    # have passed g5 on $null, and PS 5.1 makes 0 -eq '' true, so neither
    # comparison is safe written the short way.)
    Chk 'g4' (($null -ne $cliCode) -and ([int]$cliCode -eq 0) -and
              $null -ne $ordHit -and [string]$ordHit.Target -eq 'Ordinary income') `
        'the shipped import command, run as its own process, exits 0 and the term becomes resolvable'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importTool -CandidatePath $csv3
    $cliBadCode = $LASTEXITCODE
    Chk 'g5' (($null -ne $cliBadCode) -and ([int]$cliBadCode -eq 1)) `
        'the import command exits 1 -- not merely non-zero, and not an unmeasured null -- when a row is rejected'

    # g6: the printed guidance and the file on disk, measured on the file.
    #
    # The previous g6 asked the AST whether the -Path argument was spelled
    # $OutputPath and whether any of five named writers appeared.  Both are
    # answerable without the guidance being true.  Measured 2026-08-16 on the
    # old shape: rebinding $OutputPath immediately after the export call left
    # the gate at exit=0 while the extractor wrote to A and named B three times,
    # and appending to the file with [IO.File]::AppendAllText also stayed green
    # because that writer was not on the list.  A list of forbidden writers
    # cannot see "call the right function, then damage the file".
    #
    # So the guidance is now produced by the shipped code, and this check reads
    # the file the guidance names, compares it against what the writer reported,
    # and then walks a user's actual next step: put the mark in the column the
    # guidance names, in the file the guidance names, and import it.
    $handoffCsv = Join-Path $csvDir 'candidates-handoff.csv'
    $handoffShaped = @(
        [pscustomobject]@{ Source=$INVENT; Target='Inventories';  Origin=$ACTUAL; Count=5; Conflict=$false; Confidence='high'; Samples=@('Sheet8!A2 -> Sheet8!B2') },
        [pscustomobject]@{ Source=$DEPREC; Target='Depreciation'; Origin=$ACTUAL; Count=3; Conflict=$false; Confidence='high'; Samples=@('Sheet8!A3 -> Sheet8!B3') }
    )
    $h = New-YakuCellGlossaryCandidateHandoff -Entries $handoffShaped -Path $handoffCsv -ImportToolPath $importTool
    $guideBlob = ((@(@($h.Lines) | ForEach-Object { [string]$_.Text })) -join "`n")
    Write-Host '  data guidance printed by the shipped handoff:'
    foreach ($line in @(@($h.Lines) | ForEach-Object { [string]$_.Text })) { Write-Host ('       | ' + $line) }
    # Every path the guidance names that mentions a .csv, whoever wrote that
    # line.  The trailing [^\s"']* matters: without it a decoy naming
    # "<real>.csv.bak" would be trimmed back to the real path and read as a
    # match (measured 2026-08-16 while probing this check).
    $namedCsv = @([regex]::Matches($guideBlob, '[A-Za-z]:\\[^\s"'']*\.csv[^\s"'']*') | ForEach-Object { [string]$_.Value } | Sort-Object -Unique)
    $guidedPath = if ($namedCsv.Count -eq 1) { [string]$namedCsv[0] } else { '' }
    $kagiOpen = [string][char]0x300C
    $kagiClose = [string][char]0x300D
    $colMatch = [regex]::Match($guideBlob, ($kagiOpen + '([^' + $kagiClose + ']+)' + $kagiClose))
    $guidedColumn = if ($colMatch.Success) { [string]$colMatch.Groups[1].Value } else { '' }
    Show-CodePoints -Label 'GUIDED' -Text $guidedColumn
    $guidedHeaders = @()
    $guidedRows = @()
    $guidedMap = @{}
    if ($guidedPath -ne '' -and (Test-Path -LiteralPath $guidedPath -PathType Leaf)) {
        $guidedHeaders = @(Get-YakuCellGlossaryCandidateCsvHeaders -Path $guidedPath)
        $guidedRows = @(Import-Csv -LiteralPath $guidedPath -Encoding UTF8)
        if ($guidedRows.Count -gt 0) { $guidedMap = Get-YakuCellGlossaryCsvHeaderMap -Row $guidedRows[0] }
    }
    # The file the guidance names has to hold exactly what the writer reported.
    $contentOk = ($guidedRows.Count -eq 2 -and [int]$h.Rows -eq 2 -and $guidedColumn -ne '' -and $guidedMap.ContainsKey($guidedColumn))
    if ($contentOk) {
        for ($i = 0; $i -lt 2; $i++) {
            # Not $expected: at script scope that name is $script:Expected, the
            # reachability registry.  Assigning it here emptied the registry and
            # turned every green check into "unregistered id fired" (measured
            # 2026-08-16).
            $wantRow = $handoffShaped[$i]
            if ([string]$guidedRows[$i].($guidedMap[[string]$cols['Source']]) -ne [string]$wantRow.Source) { $contentOk = $false }
            if ([string]$guidedRows[$i].($guidedMap[[string]$cols['Target']]) -ne [string]$wantRow.Target) { $contentOk = $false }
            if ([string]$guidedRows[$i].($guidedMap[[string]$cols['Count']]) -ne [string]([int]$wantRow.Count)) { $contentOk = $false }
            if ([string]$guidedRows[$i].($guidedMap[[string]$cols['Location']]) -ne ((@($wantRow.Samples)) -join ' / ')) { $contentOk = $false }
            if (-not [string]::IsNullOrEmpty([string]$guidedRows[$i].($guidedMap[$guidedColumn]))) { $contentOk = $false }
        }
    }
    # Now do what the guidance told the user to do, in the file it named.
    # $marked is control flow, not an assertion: it is set only inside the
    # $contentOk branch, so asserting both said nothing the first clause had not
    # already said (removed from the Chk on 2026-08-16).  What is asserted below
    # is $r10 -- the import actually ran and reported one row.
    $marked = $false
    if ($contentOk) {
        $guidedRows[0].($guidedMap[$guidedColumn]) = $MARU
        $guidedRows | Export-Csv -LiteralPath $guidedPath -NoTypeInformation -Encoding UTF8
        $marked = $true
    }
    $r10 = if ($marked) { Import-YakuCellGlossaryCandidates -Path $guidedPath } else { $null }
    $entries = @(Read-YakuTerminologyEntries -Path $storePath -Strict)
    $inventHit = Find-YakuCellExactTerminologyMatch -Text $INVENT -Direction to_en -Entries $entries -ProjectId ''
    Chk 'g6' ($namedCsv.Count -eq 1 -and
              [string]::Equals($guidedPath, [string]$h.Path, [StringComparison]::OrdinalIgnoreCase) -and
              [string]::Equals($guidedColumn, [string]$h.AdoptColumn, [StringComparison]::Ordinal) -and
              ($guidedHeaders -contains $guidedColumn) -and
              $guideBlob.IndexOf([IO.Path]::GetFullPath($importTool), [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
              $contentOk -and
              $null -ne $r10 -and [int]$r10.Imported -eq 1 -and @($r10.Rejected).Count -eq 0 -and
              $null -ne $inventHit -and [string]$inventHit.Target -eq 'Inventories' -and
              $null -eq (Find-YakuCellExactTerminologyMatch -Text $DEPREC -Direction to_en -Entries $entries -ProjectId '')) `
        'the one file the guidance names holds exactly the rows the writer reported, and marking the column the guidance names imports that row'

    # g9: the guidance cannot name a file it did not read.  This is what makes
    # g6 hold for the extractor too: rebinding the path between writing and
    # printing no longer produces wrong guidance, it produces a stop.
    $missingCsv = Join-Path $tmp 'never-written.csv'
    $foreignCsv = Join-Path $tmp 'not-a-candidate.csv'
    [IO.File]::WriteAllText($foreignCsv, "a,b`r`n1,2`r`n", (New-Object Text.UTF8Encoding($true)))
    $guideCodes = New-Object Collections.Generic.List[string]
    foreach ($badPath in @($missingCsv, $foreignCsv)) {
        $code = ''
        try { $null = Get-YakuCellGlossaryHandoffLines -CandidatePath $badPath -ImportToolPath $importTool }
        catch { $code = ([string]$_.Exception.Message -split ':', 2)[0] }
        $guideCodes.Add($code) | Out-Null
    }
    $toolCode = ''
    try { $null = Get-YakuCellGlossaryHandoffLines -CandidatePath ([string]$h.Path) -ImportToolPath (Join-Path $tmp 'no-such-import-tool.ps1') }
    catch { $toolCode = ([string]$_.Exception.Message -split ':', 2)[0] }
    Chk 'g9' ([string]$guideCodes[0] -eq 'CELL_GLOSSARY_CANDIDATES_NOT_FOUND' -and
              [string]$guideCodes[1] -eq 'CELL_GLOSSARY_CANDIDATES_COLUMN_MISSING' -and
              $toolCode -eq 'CELL_GLOSSARY_IMPORT_TOOL_NOT_FOUND') `
        'guidance is refused outright for a path with no candidate CSV, a CSV without the adoption column, and a missing import command'

    # g7: the exclusion hop inside the extractor.  Driving the extractor itself
    # would need Excel, so this reads which expression produced the value each
    # command is given -- not the presence of a name, which is what let a
    # reassignment of $columns right after the call pass as green.
    $freshAssignments = @(Get-AstAssignmentsTo -Ast $ast -Name 'fresh')
    $selectCalls = @(Get-AstCommandCalls -Ast $ast -Name 'Select-YakuCellGlossaryUnregisteredEntries')
    $selectInFresh = if ($freshAssignments.Count -eq 1) { @(Get-AstCommandCalls -Ast $freshAssignments[0].Right -Name 'Select-YakuCellGlossaryUnregisteredEntries') } else { @() }
    $knownAssignments = @(Get-AstAssignmentsTo -Ast $ast -Name 'known')
    $knownFromFunction = @($knownAssignments | Where-Object { @(Get-AstCommandCalls -Ast $_.Right -Name 'Get-YakuCellGlossaryKnownSources').Count -eq 1 })
    $selectKnownArg = if ($selectCalls.Count -eq 1) { Get-AstNamedArgumentText -Command $selectCalls[0] -ParameterName 'Known' } else { '' }
    # $knownNotClobbered added 2026-08-16.  Without it, inserting $known = @{}
    # just before the Select- call leaves both the "one assignment holds the
    # function call" clause and the "-Known is $known" clause true, so the
    # exclusion dies whole and the gate stays at exit=0.  Measured: with that
    # one extra line the extractor reports "already registered: 0" and every
    # imported term returns to the candidate list, with nothing here going red.
    #
    # Counting the assignments does NOT close it, and that was measured too.
    # The extractor legitimately assigns $known twice: an @{} initialiser, then
    # the function call inside the try.  The initialiser is the fallback for a
    # store that cannot be read -- the glossary is an addition, never a
    # precondition -- so requiring exactly one assignment fails on the honest
    # code.  What separates the two is order: nothing may reassign $known after
    # the assignment that holds the call.
    $knownCallOffset = if ($knownFromFunction.Count -eq 1) { $knownFromFunction[0].Extent.StartOffset } else { -1 }
    $knownNotClobbered = ($knownCallOffset -ge 0) -and
        (@($knownAssignments | Where-Object { $_.Extent.StartOffset -gt $knownCallOffset }).Count -eq 0)
    Chk 'g7' ($selectCalls.Count -eq 1 -and $selectInFresh.Count -eq 1 -and
              $selectKnownArg -eq '$known' -and $knownFromFunction.Count -eq 1 -and
              $knownNotClobbered) `
        'the filtered list comes from the exclusion g3 exercised, and nothing reassigns the known-source set after it is read'

    # g8: what the extractor is allowed to do at all, as an allowlist.
    #
    # g6 measures the shipped handoff by result, but the gate cannot run the
    # extractor end to end: New-YakuExcelApplication needs Excel, and a
    # regression gate that only passes on a machine with Excel installed is not
    # a gate.  That is the stated limit, and this is what covers the gap in its
    # place: instead of naming writers that are forbidden, name everything the
    # extractor is permitted to invoke and fail on anything else.  A denylist
    # misses whatever nobody thought of ([IO.File]::AppendAllText did); an
    # allowlist makes a new writer fail here until someone adds it deliberately.
    #
    # Remaining hole, stated rather than papered over: this cannot see damage
    # done through something on the lists (a permitted command given different
    # arguments), and it does not follow the dot-sourced src modules, which are
    # covered by their own gates.  Anything else -- a redirection, an ampersand
    # invocation, a .NET call, a cmdlet not on the list -- fails here.
    #
    # Write-Host came off this list on 2026-08-16.  While it was on it, any
    # printed line at all was permitted, including one naming a file the
    # extractor never wrote (measured: appending a single Write-Host naming
    # MUT-DECOY.csv left this gate at exit=0).  The extractor now prints only
    # through Write-YakuCellGlossaryLines, which is measured for real by g10 and
    # pinned to $handoff.Lines by g11, so a direct Write-Host anywhere in the
    # extractor is a stray command and fails here.
    $allowedCommands = @(
        'Split-Path', 'Join-Path', 'Test-Path', 'Where-Object', 'New-Object',
        'New-YakuExcelApplication', 'Close-YakuExcelObjects', 'Get-YakuWorkbookPairCandidates',
        'Test-YakuCellPairUsableAsGlossary', 'Merge-YakuCellPairOccurrences', 'Add-YakuGlossaryPeriodVariants',
        'Get-YakuPersonalTerminologyPath', 'Get-YakuCellGlossaryKnownSources',
        'Select-YakuCellGlossaryUnregisteredEntries', 'New-YakuCellGlossaryCandidateHandoff',
        'Get-YakuCellGlossaryDefaultCandidatePath', 'Write-YakuCellGlossaryLines',
        'New-YakuCellGlossaryKnownSourceLines', 'New-YakuCellGlossaryKnownSourceFailureLines',
        'New-YakuCellGlossaryWorkbookHeadingLines', 'New-YakuCellGlossarySheetLines',
        'New-YakuCellGlossaryTallyLines'
    )
    $allowedMembers = @('IsNullOrWhiteSpace', 'Trim', 'Add', 'ToArray')
    $usedCommands = New-Object Collections.Generic.List[string]
    $unnamedCommands = 0
    $dotSourceCommands = 0
    $ampersandCommands = 0
    foreach ($command in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = ''
        try { $commandName = [string]$command.GetCommandName() } catch { $commandName = '' }
        $operator = [string]$command.InvocationOperator
        if ($operator -eq 'Ampersand') { $ampersandCommands++ }
        if ([string]::IsNullOrEmpty($commandName)) {
            $unnamedCommands++
            if ($operator -eq 'Dot') { $dotSourceCommands++ }
            continue
        }
        $usedCommands.Add($commandName) | Out-Null
    }
    $strayCommands = @(@($usedCommands.ToArray()) | Where-Object { $allowedCommands -notcontains $_ } | Sort-Object -Unique)
    $strayMembers = @(@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) |
        ForEach-Object { [string]$_.Member.Extent.Text } | Where-Object { $allowedMembers -notcontains $_ } | Sort-Object -Unique)
    $redirections = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.RedirectionAst] }, $true))
    if ($strayCommands.Count -gt 0) { Write-Host ('  data commands outside the allowlist: ' + ($strayCommands -join ', ')) }
    if ($strayMembers.Count -gt 0) { Write-Host ('  data .NET/member calls outside the allowlist: ' + ($strayMembers -join ', ')) }
    $handoffCalls = @(Get-AstCommandCalls -Ast $ast -Name 'New-YakuCellGlossaryCandidateHandoff')
    $handoffEntriesArg = if ($handoffCalls.Count -eq 1) { Get-AstNamedArgumentText -Command $handoffCalls[0] -ParameterName 'Entries' } else { '' }
    $handoffPathArg = if ($handoffCalls.Count -eq 1) { Get-AstNamedArgumentText -Command $handoffCalls[0] -ParameterName 'Path' } else { '' }
    $handoffAssignments = @(Get-AstAssignmentsTo -Ast $ast -Name 'handoff')
    $handoffLinesReads = @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.MemberExpressionAst]) -and
        ($n.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        ([string]$n.Expression.VariablePath.UserPath -eq 'handoff') -and
        ([string]$n.Member.Extent.Text -eq 'Lines') }, $true))
    Chk 'g8' ($strayCommands.Count -eq 0 -and $strayMembers.Count -eq 0 -and
              $redirections.Count -eq 0 -and $ampersandCommands -eq 0 -and
              $unnamedCommands -eq 1 -and $dotSourceCommands -eq 1 -and
              $handoffCalls.Count -eq 1 -and $handoffEntriesArg -eq '$fresh' -and $handoffPathArg -eq '$OutputPath' -and
              $handoffAssignments.Count -eq 1 -and $handoffLinesReads.Count -eq 1 -and
              $freshAssignments.Count -eq 1) `
        'the extractor invokes nothing outside the allowlist, and its whole write-and-guide step is the single handoff call g6 exercised, fed by the filtered list'

    # g10: what the shipped print path actually puts on the screen, captured.
    #
    # Nothing here ran the extractor's printing before today.  g6 measures the
    # handoff object; the extractor then printed it with its own Write-Host loop,
    # and whatever else that loop's neighbours chose to print was never looked at.
    # Write-Host writes to the information stream on Windows PowerShell 5.1, so
    # 6>&1 returns one InformationRecord per emitted line, blank lines included
    # (measured 2026-08-16).  That makes the printed text a value this gate can
    # compare, which is the whole point of moving the printing into shipped code.
    $printedText = @(Write-YakuCellGlossaryLines -Lines $h.Lines 6>&1 | ForEach-Object { [string]$_ })
    $wantText = @(@($h.Lines) | ForEach-Object { [string]$_.Text })
    $printedBlob = ($printedText -join "`n")
    Write-Host ('  data printer emitted ' + [string]$printedText.Count + ' lines')
    $printedCsv = @([regex]::Matches($printedBlob, '[A-Za-z]:\\[^\s"'']*\.csv[^\s"'']*') | ForEach-Object { [string]$_.Value } | Sort-Object -Unique)
    # A line whose colour is unusable must still reach the screen.  The extractor
    # used to hand the stored colour straight to -ForegroundColor, so an empty one
    # threw on the last statement of the whole run: the CSV was on disk and the
    # guidance naming it was the thing that never printed.
    $oddColour = @(Write-YakuCellGlossaryLines -Lines @(
        [pscustomobject]@{ Text='COLOURLESS'; Color='' },
        [pscustomobject]@{ Text='NONSENSE'; Color='not-a-colour' }) 6>&1 | ForEach-Object { [string]$_ })
    Chk 'g10' ($wantText.Count -ge 8 -and $printedText.Count -eq $wantText.Count -and
               $printedBlob -eq ($wantText -join "`n") -and
               $printedCsv.Count -eq 1 -and
               [string]::Equals([string]$printedCsv[0], [string]$h.Path, [StringComparison]::OrdinalIgnoreCase) -and
               (Test-Path -LiteralPath ([string]$printedCsv[0]) -PathType Leaf) -and
               (($oddColour -join '|') -eq 'COLOURLESS|NONSENSE')) `
        'the shipped printer emits the handoff lines verbatim, names exactly one .csv and that file is on disk, and an unusable colour does not swallow a line'

    # g11: the extractor's print discipline, read off its syntax tree.
    #
    # Measured 2026-08-16 on the previous shape, which printed with Write-Host
    # directly: appending the single line
    #     Write-Host ('...: ' + (Join-Path $toolsRoot 'MUT-DECOY.csv'))
    # to the end of the extractor left this gate at exit=0.  The extractor then
    # wrote one file and named a different one as the file it had written, which
    # is the defect this change set exists to remove, and nothing here saw it.
    #
    # g8 no longer permits Write-Host, so a direct print fails there.  This covers
    # the way round that: calling the shipped printer with text of the extractor's
    # own making.  The printer may be handed values only -- no string literal may
    # appear anywhere under a printer call -- and the handoff guidance must be the
    # last thing the file prints.
    #
    # Two kinds of node are literals in name only and are excluded: the command
    # name of every call in the subtree, and the member name of every property or
    # method access.  PowerShell parses both as StringConstantExpressionAst, so
    # without this `$known.Count` and `$_.Exception.Message` read as text handed
    # to the printer (measured 2026-08-16: five false positives on the correct
    # extractor).  Anything else -- a bare string, an expandable string, a
    # hashtable key -- still counts, which is what a decoy needs to build a line.
    $writeHostCalls = @(Get-AstCommandCalls -Ast $ast -Name 'Write-Host')
    $printerCalls = @(Get-AstCommandCalls -Ast $ast -Name 'Write-YakuCellGlossaryLines')
    $printerWithLiteralText = 0
    foreach ($call in $printerCalls) {
        $nameNodes = @{}
        foreach ($inner in @($call.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $elements = @($inner.CommandElements)
            if ($elements.Count -gt 0) { $nameNodes[[string]$elements[0].Extent.StartOffset] = $true }
        }
        foreach ($member in @($call.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true))) {
            if ($null -ne $member.Member) { $nameNodes[[string]$member.Member.Extent.StartOffset] = $true }
        }
        $literals = @($call.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
            ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }, $true) |
            Where-Object { -not $nameNodes.ContainsKey([string]$_.Extent.StartOffset) })
        if ($literals.Count -gt 0) {
            Write-Host ('  data literal text handed to the printer: ' + ((@($literals | ForEach-Object { [string]$_.Extent.Text })) -join ', '))
            $printerWithLiteralText++
        }
    }
    $lastCommandOffset = -1
    foreach ($command in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        if ([int]$command.Extent.StartOffset -gt $lastCommandOffset) { $lastCommandOffset = [int]$command.Extent.StartOffset }
    }
    $guidanceCalls = @($printerCalls | Where-Object { (Get-AstNamedArgumentText -Command $_ -ParameterName 'Lines') -eq '$handoff.Lines' })
    # $guidanceIsLast already requires exactly one printer call fed by
    # $handoff.Lines, so "at least one printer call exists" is not asserted
    # separately -- it cannot be false once this holds.
    $guidanceIsLast = ($guidanceCalls.Count -eq 1 -and [int]$guidanceCalls[0].Extent.StartOffset -eq $lastCommandOffset)
    Chk 'g11' ($writeHostCalls.Count -eq 0 -and
               $printerWithLiteralText -eq 0 -and $guidanceIsLast) `
        'the extractor prints only through the shipped printer, never hands it text of its own, and the handoff guidance is the last thing it prints'

    # g12: the extractor does not author a candidate path.
    #
    # $OutputPath is bound once, before the handoff call, and never again.
    # Rebinding it after the write is what produced guidance for a file that was
    # never written (measured 2026-08-16: exit=0 on the old shape, with and
    # without a matching decoy print).  And no expression anywhere in the
    # extractor spells a .csv name at all: the default location now comes from
    # Get-YakuCellGlossaryDefaultCandidatePath, so a decoy path cannot be
    # assembled here even by a caller who stays inside g8's allowlist.  Comment
    # and help text are untouched by this -- g1 is what reads those.
    $outputAssignments = @(Get-AstAssignmentsTo -Ast $ast -Name 'OutputPath')
    $handoffOffset = if ($handoffCalls.Count -eq 1) { [int]$handoffCalls[0].Extent.StartOffset } else { -1 }
    $outputBoundBeforeHandoff = ($outputAssignments.Count -eq 1 -and $handoffOffset -ge 0 -and
        [int]$outputAssignments[0].Extent.StartOffset -lt $handoffOffset)
    $csvLiterals = @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
        ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }, $true) |
        Where-Object { ([string]$_.Extent.Text).IndexOf('.csv', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($csvLiterals.Count -gt 0) {
        Write-Host ('  data .csv spelled in extractor code: ' + ((@($csvLiterals | ForEach-Object { [string]$_.Extent.Text })) -join ', '))
    }
    Chk 'g12' ($outputBoundBeforeHandoff -and $csvLiterals.Count -eq 0) `
        'the extractor binds its output path exactly once before the handoff and spells no .csv name of its own'

    # g13: the shipped line builders, driven with known values.
    #
    # g11 says the extractor may hand the printer nothing but values, which is
    # only worth having if the values turn into the right text somewhere.  This
    # is that somewhere.  Digit runs are compared in order instead of the Japanese
    # wording, because this file is ASCII only -- and the fourth number is the one
    # that matters: it is a subtraction the builder performs (9 - 4), not a value
    # the caller passed.
    $tallyQuiet = @(New-YakuCellGlossaryTallyLines -Raw 11 -Usable 7 -Merged 4 -WithVariants 9 -Fresh 3 -Conflicts 0)
    $tallyLoud = @(New-YakuCellGlossaryTallyLines -Raw 11 -Usable 7 -Merged 4 -WithVariants 9 -Fresh 3 -Conflicts 2)
    $tallyDigits = @([regex]::Matches((@($tallyQuiet | ForEach-Object { [string]$_.Text }) -join "`n"), '[0-9]+') | ForEach-Object { [string]$_.Value })
    $loudDigits = @([regex]::Matches((@($tallyLoud | ForEach-Object { [string]$_.Text }) -join "`n"), '[0-9]+') | ForEach-Object { [string]$_.Value })
    Write-Host ('  data tally digits quiet=[' + ($tallyDigits -join ',') + '] loud=[' + ($loudDigits -join ',') + ']')
    $headLines = @(New-YakuCellGlossaryWorkbookHeadingLines -SourcePath 'C:\ecm\past\FY2026_JP.xlsx' -TargetPath 'D:\ecm\FY2026_EN.xlsx')
    $sheetLines = @(New-YakuCellGlossarySheetLines -Sheets @(
        [pscustomobject]@{ Sheet='PL'; TargetSheet='PL_EN'; Matched=$true; Basis='anchor'; Anchors=12; Pairs=5 },
        [pscustomobject]@{ Sheet='Memo'; TargetSheet=''; Matched=$false; Basis=''; Anchors=0; Pairs=0 }))
    $knownLines = @(New-YakuCellGlossaryKnownSourceLines -Count 42)
    $headText = if ($headLines.Count -eq 2) { [string]$headLines[1].Text } else { '' }
    Chk 'g13' (($tallyDigits -join ',') -eq '11,7,4,5,3' -and
               ($loudDigits -join ',') -eq '11,7,4,5,3,2' -and
               @($tallyQuiet | Where-Object { [string]$_.Color -eq 'Yellow' }).Count -eq 0 -and
               @($tallyLoud | Where-Object { [string]$_.Color -eq 'Yellow' }).Count -eq 1 -and
               ($tallyLoud.Count - $tallyQuiet.Count) -eq 1 -and
               $headLines.Count -eq 2 -and [string]$headLines[0].Text -eq '' -and
               $headText.IndexOf('FY2026_JP.xlsx', [StringComparison]::Ordinal) -ge 0 -and
               $headText.IndexOf('FY2026_EN.xlsx', [StringComparison]::Ordinal) -ge 0 -and
               $headText.IndexOf('C:\ecm\past', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
               $sheetLines.Count -eq 2 -and
               [string]$sheetLines[0].Color -eq 'Gray' -and [string]$sheetLines[1].Color -eq 'Yellow' -and
               ([string]$sheetLines[0].Text).IndexOf('PL_EN', [StringComparison]::Ordinal) -ge 0 -and
               ([string]$sheetLines[0].Text).IndexOf('anchor', [StringComparison]::Ordinal) -ge 0 -and
               ([string]$sheetLines[1].Text).IndexOf('Memo', [StringComparison]::Ordinal) -ge 0 -and
               $knownLines.Count -eq 1 -and ([string]$knownLines[0].Text).IndexOf('42', [StringComparison]::Ordinal) -ge 0) `
        'the shipped line builders carry the counts, compute the period-variant difference, keep only the leaf file names and colour the unmatched sheet as a warning'
}
catch {
    # Report the failure and still run the reachability report below, so a throw
    # in the middle shows up as "these checks never ran" instead of as a bare
    # stack trace with no account of what was and was not measured.
    Write-Host ('  FAIL unexpected error: ' + [string]$_.Exception.Message) -ForegroundColor Red
    Write-Host ('       at ' + [string]$_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    $script:fail++
}
finally {
    $env:YAKULINGO_DATA_DIR = $oldData
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

Write-Host ''
Write-Host 'reachability of the assertions themselves' -ForegroundColor Cyan
$missing = @($script:Expected | Where-Object { -not $script:Fired.ContainsKey($_) })
$unknown = @($script:Fired.Keys | Where-Object { $script:Expected -notcontains $_ })
$twice = @($script:Fired.Keys | Where-Object { [int]$script:Fired[$_] -gt 1 })
if ($missing.Count -gt 0) {
    Write-Host ('  FAIL registered checks never ran: ' + ($missing -join ', ')) -ForegroundColor Red
    $script:fail++
}
if ($unknown.Count -gt 0) {
    Write-Host ('  FAIL unregistered check ids fired: ' + ($unknown -join ', ')) -ForegroundColor Red
    $script:fail++
}
if ($twice.Count -gt 0) {
    Write-Host ('  FAIL check ids fired more than once: ' + ($twice -join ', ')) -ForegroundColor Red
    $script:fail++
}
if ($missing.Count -eq 0 -and $unknown.Count -eq 0 -and $twice.Count -eq 0) {
    Write-Host ('  ok   all ' + $script:Expected.Count + ' registered checks ran exactly once') -ForegroundColor Green
}

if ($script:fail -gt 0) {
    Write-Host ("V91.77 cell glossary import gate failed. failures={0}" -f $script:fail) -ForegroundColor Red
    exit 1
}
Write-Host 'V91.77 cell glossary import gate passed.' -ForegroundColor Green
exit 0
