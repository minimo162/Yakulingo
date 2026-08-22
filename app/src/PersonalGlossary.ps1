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

function Get-YakuCellGlossaryCandidateColumns {
    <#
      候補CSVの列名を1か所で決める。

      抽出（tools\Extract-YakuCellGlossary.ps1）と取り込み
      （tools\Import-YakuCellGlossary.ps1）が別々に列名を書いていると、
      片方だけ直したときに供給が黙って切れる。実際 V91.61 では抽出の案内だけが
      glossary.csv を指し続け、そのファイルは配布木に置けないため
      （tools\Smoke-Test.ps1 が在ること自体を失敗にする）、候補は出るのに
      登録へ渡す経路が無かった。
    #>
    return [ordered]@{
        Adopt      = '採用'
        Source     = 'Source'
        Target     = 'Target'
        Kind       = '種別'
        Count      = '出現数'
        Conflict   = '競合'
        Confidence = '確度'
        Location   = '参照セル'
    }
}

function New-YakuCellGlossaryCandidateRow {
    <#
      候補1件を、候補CSVの1行へ直す。

      抽出（tools\Extract-YakuCellGlossary.ps1）が自前で行を組み立てていると、
      門は「列名の定義を呼んでいるか」しか見られない。呼んだあとで別の列名へ
      差し替えても、名前は残るので門は緑のままになる（2026-08-16 に実測。
      呼び出しの直後に $columns を上書きする変異で終了コードは 0 のままだった）。
      行の形をここに集めておけば、門はこの関数が返す行をそのままCSVへ書き、
      それを取り込み口へ通して登録できるところまでを1本で測れる。

      「採用」列は必ず空で出す。印は人が付ける。既定で印が付いていると、
      誤りが1件混ざったまま完全一致で当たり続ける。
    #>
    param([Parameter(Mandatory=$true)][AllowNull()]$Entry)
    $columns = Get-YakuCellGlossaryCandidateColumns
    $row = [ordered]@{}
    $row[[string]$columns['Adopt']]      = ''
    $row[[string]$columns['Source']]     = [string]$Entry.Source
    $row[[string]$columns['Target']]     = [string]$Entry.Target
    $row[[string]$columns['Kind']]       = [string]$Entry.Origin
    $row[[string]$columns['Count']]      = [int]$Entry.Count
    $row[[string]$columns['Conflict']]   = $(if ([bool]$Entry.Conflict) { 'あり' } else { '' })
    $row[[string]$columns['Confidence']] = [string]$Entry.Confidence
    $row[[string]$columns['Location']]   = (@($Entry.Samples) -join ' / ')
    return [pscustomobject]$row
}

function Get-YakuCellGlossaryCsvHeaderMap {
    <#
      候補CSVの見出しを「BOMと前後の空白を落とした名前 → 実際の属性名」で返す。

      Import-Csv は最初の見出しに BOM を残すことがある。書き出し側の検算と
      取り込み側の読み取りが別々に手当てしていると、片方だけ直したときに
      列が見つからなくなる。
    #>
    param([AllowNull()]$Row)
    $map = @{}
    if ($null -eq $Row) { return $map }
    foreach ($name in @($Row.PSObject.Properties.Name)) {
        $clean = ([string]$name).TrimStart([char]0xFEFF).Trim()
        if (-not $map.ContainsKey($clean)) { $map[$clean] = [string]$name }
    }
    return $map
}

function Get-YakuCellGlossaryCandidateCsvHeaders {
    <#
      候補CSVの見出しを、ファイルそのものから読み直して並び順どおりに返す。

      Import-Csv は行が0件のとき何も返さず、見出しが取れない。見出し行だけを
      2度 ConvertFrom-Csv へ通し、行の無いCSVでも「そのファイルに実際に
      載っている見出し」を取る。案内文はこの読み取りだけを根拠にする。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw ('CELL_GLOSSARY_CANDIDATES_NOT_FOUND: 候補CSVが見つかりませんでした: ' + $full)
    }
    $lines = @([IO.File]::ReadAllLines($full, [Text.UTF8Encoding]::new($true)))
    $head = if ($lines.Count -ge 1) { ([string]$lines[0]).TrimStart([char]0xFEFF) } else { '' }
    if ([string]::IsNullOrWhiteSpace($head)) {
        throw ('CELL_GLOSSARY_CANDIDATES_HEADER_MISSING: 候補CSVに見出し行がありません: ' + $full)
    }
    $probe = @(@($head, $head) | ConvertFrom-Csv)
    if ($probe.Count -lt 1) {
        throw ('CELL_GLOSSARY_CANDIDATES_HEADER_MISSING: 候補CSVの見出し行を読めませんでした: ' + $full)
    }
    return @(@($probe[0].PSObject.Properties.Name) | ForEach-Object { ([string]$_).TrimStart([char]0xFEFF).Trim() })
}

function Export-YakuCellGlossaryCandidateCsv {
    <#
      候補の一覧を候補CSVへ書き出す。抽出が書き出しに使う唯一の口。

      符号化と列の並びも含めて、取り込み口が読める形はここだけが決める。

      書いたあとで、そのファイルを開き直して確かめる。返す Path も Columns も
      読み直した結果から作る。案内文（Get-YakuCellGlossaryHandoffLines）は
      この戻り値しか見ないので、案内が指す先と実際に置いたファイルは同じ
      1つの読み取りから出る。読み直しが合わなければ、案内を作らせずに落ちる。
    #>
    param(
        [AllowNull()][object[]]$Entries,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $columns = Get-YakuCellGlossaryCandidateColumns
    $wanted = @(@($columns.Keys) | ForEach-Object { [string]$columns[$_] })
    $rows = New-Object Collections.Generic.List[object]
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $rows.Add((New-YakuCellGlossaryCandidateRow -Entry $entry)) | Out-Null
    }
    $full = [IO.Path]::GetFullPath($Path)
    $dir = [IO.Path]::GetDirectoryName($full)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    if ($rows.Count -eq 0) {
        # 候補が0件でも見出しだけは置く。Export-Csv は0件だと中身の無い
        # ファイルを作るので、案内が名指しする列がファイルの中に無くなる。
        $headerLine = (@($wanted | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ',')
        [IO.File]::WriteAllText($full, ($headerLine + "`r`n"), (New-Object Text.UTF8Encoding($true)))
    } else {
        $rows.ToArray() | Export-Csv -LiteralPath $full -NoTypeInformation -Encoding UTF8
    }

    $headers = @(Get-YakuCellGlossaryCandidateCsvHeaders -Path $full)
    $sep = [string][char]0x1F
    if (($headers -join $sep) -ne ($wanted -join $sep)) {
        throw ('CELL_GLOSSARY_CANDIDATE_CSV_HEADER_MISMATCH: 書き出した候補CSVの見出しが想定と違います: ' + $full)
    }
    $reread = @(Import-Csv -LiteralPath $full -Encoding UTF8)
    if ($reread.Count -ne $rows.Count) {
        throw ('CELL_GLOSSARY_CANDIDATE_CSV_WRITEBACK_MISMATCH: 書き出した候補CSVの行数が合いません: ' + $full)
    }
    if ($reread.Count -gt 0) {
        $map = Get-YakuCellGlossaryCsvHeaderMap -Row $reread[0]
        for ($i = 0; $i -lt $rows.Count; $i++) {
            foreach ($header in $wanted) {
                if (-not $map.ContainsKey($header)) {
                    throw ('CELL_GLOSSARY_CANDIDATE_CSV_HEADER_MISMATCH: 書き出した候補CSVに列がありません: ' + $header)
                }
                if ([string]$reread[$i].($map[$header]) -ne [string]$rows[$i].$header) {
                    throw ('CELL_GLOSSARY_CANDIDATE_CSV_WRITEBACK_MISMATCH: 書き出した候補CSVの中身が合いません: ' + $full)
                }
            }
        }
    }
    $adoptIndex = -1
    $position = 0
    foreach ($key in @($columns.Keys)) {
        if ([string]$key -eq 'Adopt') { $adoptIndex = $position; break }
        $position++
    }
    if ($adoptIndex -lt 0 -or $adoptIndex -ge $headers.Count) {
        throw ('CELL_GLOSSARY_CANDIDATE_CSV_HEADER_MISMATCH: 書き出した候補CSVに採用列がありません: ' + $full)
    }
    return [pscustomobject]@{
        Path        = [string]$full
        Rows        = [int]$rows.Count
        Columns     = @($headers)
        AdoptColumn = [string]$headers[$adoptIndex]
    }
}

function Get-YakuCellGlossaryHandoffLines {
    <#
      抽出が最後に画面へ出す案内を、置いたファイルそのものから組み立てる。

      案内文と現物が別々の変数から出ていると、片方を差し替えても文言だけは
      残る。2026-08-16 に実測: Export-YakuCellGlossaryCandidateCsv の呼び出し
      直後に $OutputPath を別のパスへ束ね直すと、抽出は A へ書き、画面は B を
      3回名指しし、門は終了コード0のままだった。案内が置いていないファイルを
      指すのは、この改修が直そうとした欠陥そのものである。

      ここは渡されたパスを開いて見出しを読み、その読み取りから案内を組む。
      開けないパスや、採用列を持たないファイルを渡されたら、案内を作らずに
      落ちる。取り込みツールも実在を確かめてから名指しする。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CandidatePath,
        [Parameter(Mandatory=$true)][string]$ImportToolPath,
        [AllowNull()][string]$TerminologyPath
    )
    $csvFull = [IO.Path]::GetFullPath($CandidatePath)
    $headers = @(Get-YakuCellGlossaryCandidateCsvHeaders -Path $csvFull)
    $columns = Get-YakuCellGlossaryCandidateColumns
    $adoptMatches = @($headers | Where-Object { [string]::Equals([string]$_, [string]$columns['Adopt'], [StringComparison]::Ordinal) })
    if ($adoptMatches.Count -ne 1) {
        throw ('CELL_GLOSSARY_CANDIDATES_COLUMN_MISSING: 候補CSVに列がありません: ' + [string]$columns['Adopt'])
    }
    $adopt = [string]$adoptMatches[0]
    $toolFull = [IO.Path]::GetFullPath($ImportToolPath)
    if (-not (Test-Path -LiteralPath $toolFull -PathType Leaf)) {
        throw ('CELL_GLOSSARY_IMPORT_TOOL_NOT_FOUND: 取り込みツールが見つかりませんでした: ' + $toolFull)
    }
    $store = if ([string]::IsNullOrWhiteSpace($TerminologyPath)) { Get-YakuPersonalTerminologyPath } else { [IO.Path]::GetFullPath($TerminologyPath) }
    $lines = New-Object Collections.Generic.List[object]
    $lines.Add([pscustomobject]@{ Text=('書き出しました: ' + $csvFull); Color='Green' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text=''; Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text='次の手順:'; Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text=('  1. ' + $csvFull + ' を開き、採る行の「' + $adopt + '」列に o を入れる'); Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text='  2. 次を実行して、印を付けた行だけを置換表へ登録する'; Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text=('     powershell -ExecutionPolicy Bypass -File ' + $toolFull + ' -CandidatePath "' + $csvFull + '"'); Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text=''; Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text='このツール自身は置換表を書き換えません。誤りが1件混ざると完全一致で当たり続けるためです。'; Color='Gray' }) | Out-Null
    $lines.Add([pscustomobject]@{ Text=('登録先は ' + $store + ' です（共有フォルダへは書きません）。'); Color='Gray' }) | Out-Null
    return @($lines.ToArray())
}

function New-YakuCellGlossaryCandidateHandoff {
    <#
      候補CSVを書き、置いたそのファイルから案内を組み、両方を1つの戻り値で返す。

      抽出はこれを1度呼ぶだけにする。書き出しと案内を別々に呼ぶと、その間で
      パスや列名を束ね直せてしまう（上の実測）。1本にしておけば、案内が指す先は
      書いた先の読み直しからしか出てこない。
    #>
    param(
        [AllowNull()][object[]]$Entries,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$ImportToolPath,
        [AllowNull()][string]$TerminologyPath
    )
    $written = Export-YakuCellGlossaryCandidateCsv -Entries $Entries -Path $Path
    $lines = @(Get-YakuCellGlossaryHandoffLines -CandidatePath ([string]$written.Path) `
        -ImportToolPath $ImportToolPath -TerminologyPath $TerminologyPath)
    return [pscustomobject]@{
        Path        = [string]$written.Path
        Rows        = [int]$written.Rows
        Columns     = @($written.Columns)
        AdoptColumn = [string]$written.AdoptColumn
        Lines       = @($lines)
    }
}

function Get-YakuCellGlossaryDefaultCandidatePath {
    <#
      候補CSVの既定の置き場を決める唯一の口。

      抽出（tools\Extract-YakuCellGlossary.ps1）が自前で綴っていると、
      門は抽出の中の文字列を見比べるしかなくなる。ここに集めておけば、
      抽出の側には .csv を綴った文字列が1つも残らないので、
      「案内が別のファイルを名指しした」変異を構文木で落とせる。
    #>
    param([Parameter(Mandatory=$true)][string]$Directory)
    return (Join-Path $Directory 'cell-glossary-candidates.csv')
}

function New-YakuCellGlossaryLine {
    <#
      画面へ出す1行。文言と色を持つ。

      色は Write-Host が受け取れる値だけに正規化する。読めない色をそのまま
      渡すと、最後の案内を出す直前で例外になり、候補CSVは置いたのに
      案内だけが出ない状態になる。
    #>
    param([AllowNull()][string]$Text, [AllowNull()][string]$Color)
    $name = ([string]$Color).Trim()
    $known = @([Enum]::GetNames([ConsoleColor]))
    $chosen = 'Gray'
    foreach ($candidate in $known) {
        if ([string]::Equals($candidate, $name, [StringComparison]::OrdinalIgnoreCase)) { $chosen = [string]$candidate; break }
    }
    return [pscustomobject]@{ Text=[string]$Text; Color=$chosen }
}

function New-YakuCellGlossaryKnownSourceLines {
    <# 既に登録済みで候補から外した件数。 #>
    param([int]$Count)
    return @((New-YakuCellGlossaryLine -Text ('登録済み: ' + [string]$Count + ' 件') -Color 'Gray'))
}

function New-YakuCellGlossaryKnownSourceFailureLines {
    <# 登録済みの一覧を読めなかったとき。候補は出るが絞り込みが効かない。 #>
    param([AllowNull()][string]$Message)
    return @((New-YakuCellGlossaryLine `
        -Text ('用語記録を読めませんでした（候補の絞り込みのみ影響します）: ' + [string]$Message) -Color 'Yellow'))
}

function New-YakuCellGlossaryWorkbookHeadingLines {
    <# 突き合わせている2冊の見出し。 #>
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$TargetPath
    )
    return @(
        (New-YakuCellGlossaryLine -Text '' -Color 'Gray'),
        (New-YakuCellGlossaryLine -Text ('■ ' + [IO.Path]::GetFileName($SourcePath) + '  ↔  ' + [IO.Path]::GetFileName($TargetPath)) -Color 'Gray')
    )
}

function New-YakuCellGlossarySheetLines {
    <# シートごとの対応の取れ方。対応が付かなかったシートは黄で出す。 #>
    param([AllowNull()][object[]]$Sheets)
    $lines = New-Object Collections.Generic.List[object]
    foreach ($sheet in @($Sheets)) {
        if ($null -eq $sheet) { continue }
        if (-not [bool]$sheet.Matched) {
            $lines.Add((New-YakuCellGlossaryLine `
                -Text ('    ' + [string]$sheet.Sheet + ' … 英語版に対応するシートが無い（対象外）') -Color 'Yellow')) | Out-Null
            continue
        }
        $via = ''
        if ([string]$sheet.TargetSheet -ne [string]$sheet.Sheet) { $via = ' → ' + [string]$sheet.TargetSheet }
        $lines.Add((New-YakuCellGlossaryLine `
            -Text ('    ' + [string]$sheet.Sheet + $via + ' … 対応: ' + [string]$sheet.Basis +
                   ' / 錨 ' + [string]$sheet.Anchors + ' / 候補 ' + [string]$sheet.Pairs) -Color 'Gray')) | Out-Null
    }
    return @($lines.ToArray())
}

function New-YakuCellGlossaryTallyLines {
    <#
      何件が何で落ちたかの内訳。

      抽出の側に数字の文言を残さないための切り出しでもある。抽出が渡すのは
      数値だけで、文言はここだけが持つ。
    #>
    param(
        [int]$Raw,
        [int]$Usable,
        [int]$Merged,
        [int]$WithVariants,
        [int]$Fresh,
        [int]$Conflicts
    )
    $lines = New-Object Collections.Generic.List[object]
    $lines.Add((New-YakuCellGlossaryLine -Text '' -Color 'Gray')) | Out-Null
    $lines.Add((New-YakuCellGlossaryLine -Text ('候補（生）        : ' + [string]$Raw + ' 件') -Color 'Gray')) | Out-Null
    $lines.Add((New-YakuCellGlossaryLine -Text ('置換表に使える形  : ' + [string]$Usable + ' 件') -Color 'Gray')) | Out-Null
    $lines.Add((New-YakuCellGlossaryLine -Text ('まとめた後        : ' + [string]$Merged + ' 件') -Color 'Gray')) | Out-Null
    $lines.Add((New-YakuCellGlossaryLine -Text ('期をずらした版を追加: ' + [string]([int]$WithVariants - [int]$Merged) + ' 件') -Color 'Gray')) | Out-Null
    $lines.Add((New-YakuCellGlossaryLine -Text ('登録済みを除く    : ' + [string]$Fresh + ' 件') -Color 'Gray')) | Out-Null
    if ([int]$Conflicts -gt 0) {
        $lines.Add((New-YakuCellGlossaryLine `
            -Text ('うち訳が割れているもの: ' + [string]$Conflicts + ' 件（どちらを採るか人が決めること）') -Color 'Yellow')) | Out-Null
    }
    $lines.Add((New-YakuCellGlossaryLine -Text '' -Color 'Gray')) | Out-Null
    return @($lines.ToArray())
}

function Write-YakuCellGlossaryLines {
    <#
      抽出が画面へ出す唯一の口。

      2026-08-16 の実測: 抽出の末尾へ Write-Host を1行足して、置いていない
      パスを「書き出しました」として出す変異は、門を終了コード0で通り抜けた。
      案内が現物と違うファイルを指すのは、この改修が直そうとした欠陥そのもので、
      それを門が見ていなかった。

      印字をここへ寄せると、抽出の中には Write-Host が1つも残らない。門は
      「抽出が呼んでよい命令」の一覧から Write-Host を外すだけで、どこへ
      どんな引数で足された印字も落とせる。文言を持つのはこちら側だけなので、
      抽出は数値と対象しか渡せない。
    #>
    param([AllowNull()][object[]]$Lines)
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $normalized = New-YakuCellGlossaryLine -Text ([string]$line.Text) -Color ([string]$line.Color)
        Write-Host ([string]$normalized.Text) -ForegroundColor ([string]$normalized.Color)
    }
}

function Get-YakuCellGlossaryKnownSources {
    <#
      既に置換表へ入っている原文の集合を返す。候補から外す先。

      見る先は取り込み口が書く先と同じ用語記録にする。CSV を間に挟むと、
      tools\Smoke-Test.ps1 が同梱の置換表CSVを配布木に置くこと自体を
      失敗にしているため、抽出から登録への線がそこで切れる。

      切り出した理由は門にある。抽出の中に置いたままだと、門は
      「Read-YakuTerminologyEntries を呼んでいるか」しか見られず、
      除外そのものを殺す変異（`if ($false -and ...)`）を通してしまう
      （2026-08-16 に実測。終了コードは 0 のままだった）。
      関数にしておけば、取り込みを1件通す前後で戻り件数が動くかを直に測れる。

      潰し方は用語記録側に合わせて Trim だけにする。ここで大文字小文字や
      全半角まで潰すと、実際には別語として登録できるものを候補から
      落としてしまう。
    #>
    param([AllowNull()][string]$Path)
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuPersonalTerminologyPath } else { [string]$Path }
    $known = @{}
    foreach ($entry in @(Read-YakuTerminologyEntries -Path $target)) {
        if ([string]$entry.kind -ne 'cell_exact') { continue }
        $source = [string]$entry.ja.preferred
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        $known[$source.Trim()] = $true
    }
    return $known
}

function Select-YakuCellGlossaryUnregisteredEntries {
    <#
      候補のうち、まだ置換表に無いものだけを残す。

      同じ語を何度も人に見せないための絞り込みである。ここが死ぬと、
      取り込み済みの語が候補に出続け、この改修が直そうとした欠陥へ戻る。
    #>
    param(
        [AllowNull()][object[]]$Entries,
        [AllowNull()][hashtable]$Known,
        [AllowNull()][string]$TerminologyPath
    )
    $set = if ($null -ne $Known) { $Known } else { Get-YakuCellGlossaryKnownSources -Path $TerminologyPath }
    $kept = New-Object Collections.Generic.List[object]
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        if ($set.ContainsKey(([string]$entry.Source).Trim())) { continue }
        $kept.Add($entry) | Out-Null
    }
    return @($kept.ToArray())
}

function ConvertTo-YakuCellGlossaryMatchKey {
    <#
      完全一致の突き合わせに使う鍵。

      Find-YakuCellExactTerminologyMatch が引くときと同じ潰し方をする。
      ここが違うと、取り込みでは別物と見なした2件が、実際に引くときには
      同じセルへ当たって TERMINOLOGY_CELL_EXACT_CONFLICT で止まる。
    #>
    param([AllowNull()][string]$Value)
    $text = ([string]$Value).Normalize([Text.NormalizationForm]::FormKC).Trim()
    return (($text -replace '\s+', ' ').ToLowerInvariant())
}

function Test-YakuCellGlossaryAdoptionMark {
    <#
      「採用」列の値が採用の印か。

      印は肯定の並びだけを採る。cell_exact は一度誤ると完全一致で当たり続けるので、
      「空でなければ採用」にはしない。判別できない印は捨てずに呼び出し元へ返し、
      利用者へ件数を見せること（黙って落とすと、印を付けたつもりの行が消える）。
    #>
    param([AllowNull()][string]$Value)
    $text = ([string]$Value).Normalize([Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $marks = @(
        'o', 'y', 'yes', '1', 'true', '採用', '要',
        [string][char]0x3007, [string][char]0x25CB, [string][char]0x25EF,
        [string][char]0x2713, [string][char]0x2714
    )
    return ($marks -contains $text)
}

function Import-YakuCellGlossaryCandidates {
    <#
      候補CSVのうち「採用」列に印の付いた行だけを、個人の用語記録
      （personal-v2.jsonl）へ kind='cell_exact' として登録する。

      守る点が3つある。
        1. 書き込み先は Get-YakuSubDir 'terminology' 配下のローカルだけ。
           それ以外を渡されたら書かずに止める（アプリは共有フォルダへ書かない）。
        2. 出典は候補CSV自身から採る。参照セルが空の候補は
           New-YakuTerminologyEntry の出典必須検査に当たって
           TERMINOLOGY_PROVENANCE_REQUIRED で落ちる。ここで代わりの値を
           作らないこと。作った瞬間、出典必須は空回りする。
        3. 同じ原文に別の訳を当てる登録は、書く前に止める。書いてしまうと
           引くときに TERMINOLOGY_CELL_EXACT_CONFLICT になり、原因が
           翻訳の途中まで分からない。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][string]$TerminologyPath
    )
    $csvPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        throw 'CELL_GLOSSARY_CANDIDATES_NOT_FOUND: 候補CSVが見つかりませんでした。'
    }
    $termPath = if ([string]::IsNullOrWhiteSpace($TerminologyPath)) { Get-YakuPersonalTerminologyPath } else { [string]$TerminologyPath }
    $termFull = [IO.Path]::GetFullPath($termPath)
    $localDir = [IO.Path]::GetFullPath((Get-YakuSubDir 'terminology')).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $termFull.StartsWith($localDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CELL_GLOSSARY_TARGET_OUTSIDE_LOCAL_STORE: 用語の登録先はローカルの terminology フォルダだけです。'
    }

    $columns = Get-YakuCellGlossaryCandidateColumns
    $rows = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
    $propByHeader = @{}
    if ($rows.Count -gt 0) {
        $propByHeader = Get-YakuCellGlossaryCsvHeaderMap -Row $rows[0]
        foreach ($key in @('Adopt', 'Source', 'Target', 'Location')) {
            if (-not $propByHeader.ContainsKey([string]$columns[$key])) {
                throw ('CELL_GLOSSARY_CANDIDATES_COLUMN_MISSING: 候補CSVに列がありません: ' + [string]$columns[$key])
            }
        }
    }
    $cellOf = {
        param($Row, [string]$Key)
        $header = [string]$columns[$Key]
        if (-not $propByHeader.ContainsKey($header)) { return '' }
        return ([string]$Row.($propByHeader[$header]))
    }

    $adopted = New-Object Collections.Generic.List[object]
    $rejected = New-Object Collections.Generic.List[object]
    $unrecognized = New-Object Collections.Generic.List[object]
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        $mark = [string](& $cellOf $row 'Adopt')
        if ([string]::IsNullOrWhiteSpace($mark)) { continue }
        $source = ([string](& $cellOf $row 'Source')).Trim()
        if (-not (Test-YakuCellGlossaryAdoptionMark -Value $mark)) {
            $unrecognized.Add([pscustomobject]@{ Row=$rowNumber; Source=$source; Mark=$mark.Trim() }) | Out-Null
            continue
        }
        $adopted.Add([pscustomobject]@{
            Row=$rowNumber; Source=$source
            Target=([string](& $cellOf $row 'Target')).Trim()
            Location=([string](& $cellOf $row 'Location')).Trim()
            Kind=([string](& $cellOf $row 'Kind')).Trim()
            Key=(ConvertTo-YakuCellGlossaryMatchKey -Value $source)
        }) | Out-Null
    }

    # 同じ原文へ別の訳を当てている採用行は、まとめて拒否する。どちらが正しいかは
    # 機械に決められない。片方を黙って採ると、誤ったほうが残りうる。
    $byKey = @{}
    foreach ($item in @($adopted.ToArray())) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Key)) { continue }
        if (-not $byKey.ContainsKey([string]$item.Key)) { $byKey[[string]$item.Key] = New-Object Collections.Generic.List[object] }
        $byKey[[string]$item.Key].Add($item) | Out-Null
    }
    $conflicted = @{}
    foreach ($key in @($byKey.Keys)) {
        $group = @($byKey[$key].ToArray())
        $targets = @($group | ForEach-Object { ConvertTo-YakuCellGlossaryMatchKey -Value ([string]$_.Target) } | Sort-Object -Unique)
        if ($targets.Count -le 1) { continue }
        $conflicted[$key] = $true
        foreach ($item in $group) {
            $rejected.Add([pscustomobject]@{
                Row=[int]$item.Row; Source=[string]$item.Source; Target=[string]$item.Target
                Code='CELL_GLOSSARY_TARGET_CONFLICT'
                Message='同じ原文に別の訳が採用されています。どちらか一方だけに印を付けてください。'
            }) | Out-Null
        }
    }

    $existingById = @{}
    $activeByKey = @{}
    foreach ($entry in @(Read-YakuTerminologyEntries -Path $termPath -IncludeInactive)) {
        $existingById[[string]$entry.term_id] = $entry
        if (-not [bool]$entry.active -or [string]$entry.kind -ne 'cell_exact' -or [string]$entry.scope -ne 'personal') { continue }
        $activeByKey[(ConvertTo-YakuCellGlossaryMatchKey -Value ([string]$entry.ja.preferred))] = $entry
    }

    $originProjectId = (Get-YakuTerminologyHash -Text 'cell-glossary-import-project').Substring(0, 32)
    $csvName = [IO.Path]::GetFileName($csvPath)
    $written = New-Object Collections.Generic.List[object]
    $imported = 0; $updated = 0; $skipped = 0; $withdrawn = 0
    $seenKeys = @{}
    foreach ($item in @($adopted.ToArray())) {
        $key = [string]$item.Key
        if ($conflicted.ContainsKey($key)) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$item.Source) -or [string]::IsNullOrWhiteSpace([string]$item.Target)) {
            $rejected.Add([pscustomobject]@{
                Row=[int]$item.Row; Source=[string]$item.Source; Target=[string]$item.Target
                Code='CELL_GLOSSARY_ROW_INCOMPLETE'; Message='原文か訳文が空です。'
            }) | Out-Null
            continue
        }
        # 同じCSVの中で完全に同じ対が2度出てきたら、1度だけ扱う。
        if ($seenKeys.ContainsKey($key)) { $skipped++; continue }
        $seenKeys[$key] = $true

        $termId = (Get-YakuTerminologyHash -Text ('cell-glossary-term|' + $key)).Substring(0, 32)
        $segmentId = (Get-YakuTerminologyHash -Text ('cell-glossary-candidate|' + $key)).Substring(0, 32)
        $targetKey = ConvertTo-YakuCellGlossaryMatchKey -Value ([string]$item.Target)

        # 別IDで同じ原文が既に登録されていて、訳が違う場合は書かない。
        # 書けば引くときに落ちる。落ちる場所を翻訳から取り込みへ前へ出す。
        if ($activeByKey.ContainsKey($key)) {
            $rival = $activeByKey[$key]
            if ([string]$rival.term_id -ne $termId -and
                (ConvertTo-YakuCellGlossaryMatchKey -Value ([string]$rival.en.preferred)) -ne $targetKey) {
                $rejected.Add([pscustomobject]@{
                    Row=[int]$item.Row; Source=[string]$item.Source; Target=[string]$item.Target
                    Code='CELL_GLOSSARY_TARGET_CONFLICT'
                    Message=('同じ原文が別の訳「' + [string]$rival.en.preferred + '」で既に登録されています。')
                }) | Out-Null
                continue
            }
        }

        $version = 1
        $created = ''
        if ($existingById.ContainsKey($termId)) {
            $old = $existingById[$termId]
            if ([bool]$old.active -and
                [string]::Equals([string]$old.ja.preferred, [string]$item.Source, [StringComparison]::Ordinal) -and
                [string]::Equals([string]$old.en.preferred, [string]$item.Target, [StringComparison]::Ordinal)) {
                $skipped++
                continue
            }
            # 利用者が取り消した登録を、CSVが残っているという理由だけで作り直さない。
            if (-not [bool]$old.active -and [string]$old.origin -eq 'personal-glossary-remove' -and
                [string]::Equals([string]$old.ja.preferred, [string]$item.Source, [StringComparison]::Ordinal) -and
                [string]::Equals([string]$old.en.preferred, [string]$item.Target, [StringComparison]::Ordinal)) {
                $withdrawn++
                continue
            }
            $version = [int]$old.version + 1
            $created = [string]$old.created
        }

        $kindToken = [string]$item.Kind
        $paren = $kindToken.IndexOf('(')
        if ($paren -gt 0) { $kindToken = $kindToken.Substring(0, $paren) }
        $note = if ([string]::IsNullOrWhiteSpace($kindToken)) { 'cell-glossary' } else { 'cell-glossary:' + $kindToken.Trim() }

        $entry = $null
        try {
            $entry = New-YakuTerminologyEntry -TermId $termId -Version $version -Scope personal -Kind cell_exact `
                -Enforcement advisory -JapanesePreferred ([string]$item.Source) -EnglishPreferred ([string]$item.Target) `
                -Note $note -Origin 'cell-glossary-import' -OriginProjectId $originProjectId `
                -OriginFileName $csvName -OriginSegmentId $segmentId `
                -OriginLocation ([string]$item.Location) -OriginRevision 0 -CreatedAt $created
        } catch {
            $message = [string]$_.Exception.Message
            $code = if ($message -match '^[A-Z_]+') { [string]$Matches[0] } else { 'CELL_GLOSSARY_ENTRY_REJECTED' }
            $rejected.Add([pscustomobject]@{
                Row=[int]$item.Row; Source=[string]$item.Source; Target=[string]$item.Target
                Code=$code; Message=$message
            }) | Out-Null
            continue
        }
        $result = Add-YakuTerminologyRecord -Entry $entry -Path $termPath
        if ([bool]$result.Added) {
            if ($version -gt 1) { $updated++ } else { $imported++ }
            $existingById[$termId] = $entry
            $activeByKey[$key] = $entry
            $written.Add($entry) | Out-Null
        } else {
            $skipped++
        }
    }
    try { Write-YakuLog ("Cell glossary candidates imported. new=$imported updated=$updated skipped=$skipped rejected=" + $rejected.Count) 'INFO' } catch {}
    return [pscustomobject]@{
        CandidatePath = $csvPath
        TerminologyPath = $termFull
        Rows = [int]$rows.Count
        Adopted = [int]$adopted.Count
        Imported = [int]$imported
        Updated = [int]$updated
        Skipped = [int]$skipped
        Withdrawn = [int]$withdrawn
        UnrecognizedMarks = @($unrecognized.ToArray())
        Rejected = @($rejected.ToArray())
        Entries = @($written.ToArray())
    }
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
