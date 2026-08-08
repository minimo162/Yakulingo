<#
  対訳の対を貯める層。

  これまでのコーパスは文書ごとの本文しか持っていなかった。英文資料しか
  検索対象にできず、英語で検索しないと当たらない。日本語で「電動化の
  黎明期」と引いて、対応する英文を出したい——それが元々の要求だった。

  Copilot によるアライメントで日英の対が取れるようになったので、その結果を
  ここへ貯める。検索は日本語側にも英語側にも当てられる。

  貯めるのは JSONL。1行1対。追記だけで済み、壊れた行があってもその行だけ
  捨てれば残りは読める。対訳は増え続けるので、書き直しの要らない形を選ぶ。

  同じ対を二度入れないよう、日英を連結した SHA256 で重複を落とす。
  同じ資料を取り込み直しても増殖しない。
#>

function Get-YakuCorpusPairsPath {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database
    )
    return (Join-Path (Join-Path $Dir $Database) 'pairs.jsonl')
}

function Get-YakuCorpusPairKey {
    param([AllowNull()][string]$Ja, [AllowNull()][string]$En)
    # 空白の違いだけで別物にならないよう、比較用に正規化してから鍵にする。
    $norm = (([string]$Ja) -replace '\s+', '') + "`u{241F}" + (([string]$En) -replace '\s+', '').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').Substring(0, 16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-YakuCorpusPairs {
    <#
      壊れた行は黙って捨てる。1行の破損で資料全体が読めなくなるほうが困る。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database
    )
    $path = Get-YakuCorpusPairsPath -Dir $Dir -Database $Database
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @($out.ToArray()) }
    $broken = 0
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { $broken++ }
    }
    if ($broken -gt 0) { try { Write-YakuLog "Corpus pairs had unreadable lines. database=$Database broken=$broken" 'WARN' } catch {} }
    return @($out.ToArray())
}

function Add-YakuCorpusPairs {
    <#
      アライメントの結果を貯める。既にある対は数えるだけで書かない。
      Pairs は JaText / EnText を持つもの（Invoke-YakuDocumentAlignment の出力）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Source,
        [AllowNull()][object[]]$Pairs,
        [switch]$Public
    )
    $path = Get-YakuCorpusPairsPath -Dir $Dir -Database $Database
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }

    $known = @{}
    foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $Database)) {
        try { $known[[string]$p.key] = $true } catch {}
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $added = 0; $skipped = 0
    foreach ($pair in @($Pairs)) {
        $ja = [string]$pair.JaText; $en = [string]$pair.EnText
        if ([string]::IsNullOrWhiteSpace($ja) -or [string]::IsNullOrWhiteSpace($en)) { $skipped++; continue }
        $key = Get-YakuCorpusPairKey -Ja $ja -En $en
        if ($known.ContainsKey($key)) { $skipped++; continue }
        $known[$key] = $true
        $record = [ordered]@{
            key      = $key
            database = $Database
            source   = $Source
            ja       = $ja
            en       = $en
            # 数値の裏取りが通ったかを残す。通っていない対は参考として弱く扱える。
            verified = [bool]$pair.NumberAgree -and [bool]$pair.NumberChecked
            public   = [bool]$Public
        }
        [void]$lines.Add(($record | ConvertTo-Json -Compress -Depth 3))
        $added++
    }
    if ($lines.Count -gt 0) {
        [IO.File]::AppendAllLines($path, [string[]]$lines.ToArray(), [Text.UTF8Encoding]::new($false))
    }
    try { Write-YakuLog "Corpus pairs stored. database=$Database source=$Source added=$added skipped=$skipped" 'INFO' } catch {}
    return [pscustomobject]@{ Added = $added; Skipped = $skipped; Path = $path }
}

function Find-YakuCorpusPairs {
    <#
      日本語でも英語でも引ける。まず素直な部分一致で拾い、長く一致した順に
      並べる。凝った順位付けは後から足せるが、当たらないものは足せない。

      Language を省くと、問い合わせに日本語の文字が含まれるかで判断する。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Query,
        [AllowNull()][string[]]$Databases,
        [ValidateSet('auto', 'ja', 'en')][string]$Language = 'auto',
        [int]$Limit = 20,
        [switch]$VerifiedOnly
    )
    $q = ([string]$Query).Trim()
    if ([string]::IsNullOrWhiteSpace($q)) { return @() }
    $lang = $Language
    if ($lang -eq 'auto') {
        $lang = $(if ($q -match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]') { 'ja' } else { 'en' })
    }
    $dbs = @($Databases)
    if ($dbs.Count -eq 0) {
        $dbs = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($db in $dbs) {
        foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $db)) {
            if ($VerifiedOnly -and -not [bool]$p.verified) { continue }
            $side = [string]$(if ($lang -eq 'ja') { $p.ja } else { $p.en })
            if ([string]::IsNullOrEmpty($side)) { continue }
            $found = $side.IndexOf($q, [StringComparison]::OrdinalIgnoreCase)
            if ($found -lt 0) { continue }
            [void]$hits.Add([pscustomobject]@{
                    Database = [string]$p.database
                    Source   = [string]$p.source
                    Ja       = [string]$p.ja
                    En       = [string]$p.en
                    Verified = [bool]$p.verified
                    # 短い文に当たったほうが、探している言い回しである可能性が高い。
                    Score    = [double]$q.Length / [Math]::Max(1, $side.Length)
                })
        }
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Score -Descending | Select-Object -First $Limit)
}

function Get-YakuJapaneseTerms {
    <#
      日本語の文から、検索に使える語を手元で取り出す。

      形態素解析は入れない。財務・開示の文で拾いたいのは「売上高」「為替影響」
      「有形固定資産」「サプライチェーン」のような複合名詞であり、これらは
      漢字の連なりとカタカナの連なりとして素直に取れる。助詞・活用語尾は
      ひらがななので、そこで自然に切れる。

      なぜ手元で作るか。これまで検索語は Copilot に作らせていた。往復が1回
      増えるうえ、Copilot は短時間に集中して送ると弾かれる。対訳は日本語側でも
      引けるので、日本語の原文から直接引けば往復は増えない
      （利用者の指摘 2026-08-08）。

      長い語を先に返す。「有形固定資産」が当たるなら「資産」は要らない。
    #>
    param(
        [AllowNull()][string]$Text,
        [int]$Limit = 12,
        [int]$MinKanji = 2,
        [int]$MinKatakana = 3
    )
    $s = [string]$Text
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $terms = New-Object System.Collections.Generic.List[string]
    # 漢字の連なり。数字（漢数字を含む）だけの語は落とす。年度や期は
    # どの資料にも出るので、当たっても言い回しの手がかりにならない。
    foreach ($m in [regex]::Matches($s, '[\p{IsCJKUnifiedIdeographs}]{' + [string]$MinKanji + ',}')) {
        $t = [string]$m.Value
        # 「四半期」「第151期」「2026年度」のような期の言い方は、どの資料にも
        # 出るので当たっても手がかりにならない。半 を入れて四半期を落とす。
        if ($t -match '^[一二三四五六七八九十百千万億兆半第期年月日度前後同]+$') { continue }
        # 末尾の「等」「他」は落とす。原文が「生産設備等」でコーパスが
        # 「生産設備」だと、部分一致では当たらない。3文字以上のときだけ削る。
        # 「均等」「其他」のような2文字語まで削ると、語が消えてしまう。
        if ($t.Length -ge 3 -and ($t.EndsWith('等') -or $t.EndsWith('他'))) {
            $t = $t.Substring(0, $t.Length - 1)
        }
        if ($seen.Add($t)) { [void]$terms.Add($t) }
    }
    # カタカナの連なり。長音記号も語の一部として含める。
    foreach ($m in [regex]::Matches($s, '[\p{IsKatakana}ー]{' + [string]$MinKatakana + ',}')) {
        $t = ([string]$m.Value).Trim('ー')
        if ($t.Length -lt $MinKatakana) { continue }
        if ($seen.Add($t)) { [void]$terms.Add($t) }
    }
    return @(@($terms.ToArray()) | Sort-Object -Property Length -Descending | Select-Object -First $Limit)
}

function Find-YakuCorpusPairsByTerms {
    <#
      日本語の原文に近い対訳を、往復なしで引く。

      Get-YakuJapaneseTerms で語を取り出し、日本語側にその語を含む対を集めて、
      当たった語の文字数の合計で並べる。語数ではなく文字数で数えるのは、
      「有形固定資産」1語のほうが「利益」「増加」2語より手がかりが強いため。

      当たった語を Terms として返す。何を根拠に引いてきた文例なのかを
      画面に出せないと、参考にしたと名乗るだけになる。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowNull()][string[]]$Databases,
        [int]$Limit = 3,
        [int]$TermLimit = 12
    )
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $terms = @(Get-YakuJapaneseTerms -Text $Text -Limit $TermLimit)
    if ($terms.Count -le 0) { return @() }
    $dbs = @($Databases)
    if ($dbs.Count -eq 0) {
        $dbs = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($db in $dbs) {
        foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $db)) {
            $ja = [string]$p.ja
            $en = [string]$p.en
            if ([string]::IsNullOrWhiteSpace($ja) -or [string]::IsNullOrWhiteSpace($en)) { continue }
            $matched = New-Object System.Collections.Generic.List[string]
            $score = 0
            foreach ($t in $terms) {
                if ($ja.IndexOf($t, [StringComparison]::Ordinal) -ge 0) {
                    [void]$matched.Add($t)
                    $score += $t.Length
                }
            }
            if ($score -le 0) { continue }
            [void]$hits.Add([pscustomobject]@{
                    Database = [string]$p.database
                    Source   = [string]$p.source
                    Ja       = $ja
                    En       = $en
                    Verified = [bool]$p.verified
                    Terms    = @($matched.ToArray())
                    Score    = [int]$score
                })
        }
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Score -Descending | Select-Object -First $Limit)
}

function Import-YakuCorpusPairsFromTexts {
    <#
      日英ひと組の本文から対訳を作って貯める。資料を取り込む口の本体。

      渡すのは liteparse の plain text をそのまま。行はレイアウト行であって
      文ではないが、繋ぐ判断は Copilot に任せる（実測で 8/8 一致した）。
      空行と極端に短い行だけ落とす。装飾記号やページ番号を字面で判別しようと
      すると本文を巻き込むので、判定は増やさない。

      重いので進捗を返せるようにしておく。有報1章で 5回・52秒だった。
      文書まるごとなら数十分かかる。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Source,
        # 空も受ける。抽出に失敗した資料は珍しくないので、呼び出し側で
        # 弾かせるより、ここで「0件」を返して記録するほうが追いやすい。
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$JaText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EnText,
        [AllowNull()]$Settings,
        [int]$MinLineLength = 4,
        [switch]$Public
    )
    $clean = {
        param([string]$Text)
        return @(($Text -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim().Length -ge $MinLineLength })
    }
    $ja = @(& $clean $JaText)
    $en = @(& $clean $EnText)
    if ($ja.Count -eq 0 -or $en.Count -eq 0) {
        try { Write-YakuLog "Corpus pair import skipped; empty side. source=$Source ja=$($ja.Count) en=$($en.Count)" 'WARN' } catch {}
        return [pscustomobject]@{ Added = 0; Skipped = 0; JaLines = $ja.Count; EnLines = $en.Count; JaCoverage = 0.0; Calls = 0; Dropped = 0 }
    }
    # 前回どこまで進んだかを覚えてある場合は、その続きから流す。
    # Copilot は一定量を使うと止まるので、長い資料は何度かに分けて通す。
    # 頭から流し直すと、同じところで制限に当たって永久に終わらない。
    $progressPath = Join-Path (Join-Path $Dir $Database) 'progress.json'
    $progress = @{}
    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
        try { (Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $progress[$_.Name] = [int]$_.Value } } catch {}
    }
    $from = 0
    if ($progress.ContainsKey($Source)) { $from = [int]$progress[$Source] }
    if ($from -ge $ja.Count) { $from = 0 }
    $jaRun = if ($from -gt 0) { @($ja[$from..($ja.Count - 1)]) } else { $ja }

    try { Write-YakuLog "Corpus pair import started. source=$Source ja=$($ja.Count) en=$($en.Count) from=$from" 'INFO' } catch {}
    $aligned = Invoke-YakuDocumentAlignment -JaLines $jaRun -EnLines $en -Settings $Settings
    $stored = Add-YakuCorpusPairs -Dir $Dir -Database $Database -Source $Source -Pairs @($aligned.Pairs) -Public:$Public

    # 止まった位置を覚える。最後まで通ったら消す（次回は頭から検証できる）。
    if (-not $aligned.Completed -and [int]$aligned.StoppedAt -ge 0) {
        $progress[$Source] = $from + [int]$aligned.StoppedAt
    } else {
        $progress.Remove($Source) | Out-Null
    }
    try {
        $parent = Split-Path -Parent $progressPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        ($progress | ConvertTo-Json -Compress) | Set-Content -LiteralPath $progressPath -Encoding UTF8
    } catch {}

    try { Write-YakuLog ("Corpus pair import finished. source=$Source added=$($stored.Added) coverage=" + [Math]::Round($aligned.JaCoverage, 3) + " calls=$($aligned.Calls) dropped=$($aligned.Dropped) completed=$($aligned.Completed)") 'INFO' } catch {}
    return [pscustomobject]@{
        Added      = [int]$stored.Added
        Skipped    = [int]$stored.Skipped
        JaLines    = $ja.Count
        EnLines    = $en.Count
        JaCoverage = [double]$aligned.JaCoverage
        Calls      = [int]$aligned.Calls
        Dropped    = [int]$aligned.Dropped
        Completed  = [bool]$aligned.Completed
        ResumeFrom = $(if ($aligned.Completed) { 0 } else { $from + [int]$aligned.StoppedAt })
        StopReason = [string]$aligned.StopReason
    }
}

function Find-YakuCorpusPairsForSegment {
    <#
      CAT の候補ペイン向け。原文セグメント1本に対して、過去の対訳を探す。

      利用者が語を選んで検索するのではなく、行を移るたびに自動で引くので、
      問い合わせは「原文そのもの」になる。市販ツールの翻訳メモリと同じ形。

      3段階で見る。
        完全一致  過去に同じ文を訳している。そのまま差し込める
        包含      過去の文がこの原文を含む／含まれる。参考になる
      一致率は文字数の比で出す。編集距離のほうが精確だが、行を移るたびに
      全件へ掛けると重い。まず動く形を置き、必要になったら精度を上げる。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('ja', 'en')][string]$SourceLanguage = 'ja',
        [AllowNull()][string[]]$Databases,
        [int]$Limit = 5,
        [int]$MinLength = 6
    )
    $t = ([string]$Text).Trim()
    if ($t.Length -lt $MinLength) { return @() }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $norm = { param($s) return (([string]$s) -replace '\s+', '') }
    $tn = & $norm $t
    $dbs = @($Databases)
    if ($dbs.Count -eq 0) {
        $dbs = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($db in $dbs) {
        foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $db)) {
            $src = [string]$(if ($SourceLanguage -eq 'ja') { $p.ja } else { $p.en })
            $tgt = [string]$(if ($SourceLanguage -eq 'ja') { $p.en } else { $p.ja })
            if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) { continue }
            $sn = & $norm $src
            if ($sn.Length -lt $MinLength) { continue }
            $exact = [string]::Equals($sn, $tn, [StringComparison]::Ordinal)
            if ($exact) { $ratio = 1.0 }
            elseif ($sn.IndexOf($tn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$tn.Length / $sn.Length }
            elseif ($tn.IndexOf($sn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$sn.Length / $tn.Length }
            else { continue }
            if ($ratio -lt 0.3) { continue }
            [void]$hits.Add([pscustomobject]@{
                    Database = [string]$p.database
                    Source   = $src
                    Target   = $tgt
                    Verified = [bool]$p.verified
                    Exact    = $exact
                    Ratio    = $ratio
                })
        }
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Ratio -Descending | Select-Object -First $Limit)
}
