<#
  V91.61 段階2: 参考資料コーパスの索引と語彙検索。

  段階1（Corpus.ps1）が作った英語 Markdown を、引ける形にする。

  設計の前提（_docs/要件整理_汎用翻訳アプリとRAG翻訳.md §13-4, §6-1）:
   - コーパスは**英語側だけ**。日本語との対応づけ（文アライメント）は持たない。
   - 日本語の原文から英語コーパスを引く橋渡しは、段階3 で Copilot に
     英語の検索語を作らせて行う（Agentic RAG）。ここはその検索器を用意する。
   - 埋め込みは使わない。利用者端末にモデルもランタイムも置かない。
     財務文書は固有名詞・勘定科目・定型表現が多く字面が一致しやすいため、
     語彙検索で足りるという実測（§13-5 FinanceBench で語彙検索が +6pt）がある。

  差し替え可能にしておくこと（§6-1-4）:
   - 索引の作り方（New-YakuCorpusIndex）と、順位づけ（Get-YakuCorpusBm25Score）を分ける。
   - 呼び出し側は Search-YakuCorpus の戻り値だけを見る。
     後から埋め込み検索を差し込むときに、翻訳経路を触らずに済む。

  置き場所（修正指示書 §12）:
   - 索引はローカルの corpus\<版>\ の隣ではなく、データディレクトリ配下へ置く。
     corpus\ の中は bootstrap.ps1 が版ごと入れ替える領域であり、
     派生物を混ぜると「古い版」として掃除されてしまうため。
   - 索引は派生物なので、失われても作り直せばよい。
#>

# この module では、繰り返しの中の Add / Append を「| Out-Null」ではなく [void] で捨てる。
# 実測（資料100件・一節6000件）で、List.Add へ | Out-Null を付けると 100 秒、
# [void] なら 1.7 秒だった。パイプラインを1回組み立てる費用が呼び出しごとにかかるため。
# 繰り返しの外では、既存コードに合わせて | Out-Null のままでよい。

# 索引の書式。読み書きの両方で使う。合わなければ作り直す。
$script:YakuCorpusIndexSchema = 'yaku-corpus-index-1'

# 語彙検索の重みづけ。BM25 の一般的な既定値。
$script:YakuCorpusBm25K1 = 1.2
$script:YakuCorpusBm25B  = 0.75

# 英語の機能語。索引語から外す。
# 財務資料は定型表現が多く、これらを残すとどの一節も同じくらい当たってしまう。
$script:YakuCorpusStopWords = @{}
foreach ($w in @(
    'a','about','above','after','again','against','all','am','an','and','any','are','as','at',
    'be','because','been','before','being','below','between','both','but','by',
    'can','cannot','could','did','do','does','doing','down','during',
    'each','few','for','from','further','had','has','have','having','he','her','here','hers',
    'herself','him','himself','his','how','i','if','in','into','is','it','its','itself',
    'me','more','most','my','myself','no','nor','not','of','off','on','once','only','or',
    'other','ought','our','ours','ourselves','out','over','own',
    'same','she','should','so','some','such','than','that','the','their','theirs','them',
    'themselves','then','there','these','they','this','those','through','to','too',
    'under','until','up','very','was','we','were','what','when','where','which','while',
    'who','whom','why','will','with','would','you','your','yours','yourself','yourselves'
)) { $script:YakuCorpusStopWords[$w] = $true }

function Get-YakuCorpusIndexRootDir {
    return (Get-YakuSubDir 'corpus-index')
}

function Get-YakuCorpusSearchDir {
    <#
      引く先のコーパスを決める。

      利用者は配布済みコーパス（YAKULINGO_CORPUS_DIR）を引く。
      管理者は発行前に手元の取り込み結果を試せたほうがよいので、
      配布済みが無ければ corpus-build へ落ちる。
      どちらも無ければ空。呼び出し側は「コーパス無し」で動くこと。
    #>
    $dir = Get-YakuCorpusDir
    if (-not [string]::IsNullOrWhiteSpace($dir)) { return $dir }
    $build = Get-YakuCorpusBuildDir
    if (Test-Path -LiteralPath (Join-Path $build 'manifest.json') -PathType Leaf) { return $build }
    return ''
}

function Get-YakuCorpusTokens {
    <#
      英語の一節を索引語へ分ける。

      コーパスは英語だけなので、日本語の形態素解析も文字 N-gram も要らない。
      小文字化し、英数字以外で切るだけでよい。

      数字だけの語は落とす。金額・年度は資料ごとに違い、
      「2026」で引いても言い回しは見つからない。むしろ雑音になる。
      （翻訳経路では数値は V91.60 でマスクされるため、検索語にも現れない）
    #>
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $lower = $Text.ToLowerInvariant()
    $tokens = New-Object System.Collections.Generic.List[string]
    # 切り分けは正規表現1回で済ませ、1語ごとには正規表現を使わない。
    # 資料100件（約120万語）で語ごとに -match を回すと、それだけで数十秒かかった。
    foreach ($t in @($lower -split '[^a-z0-9]+')) {
        if ($t.Length -lt 2) { continue }
        $c0 = $t[0]
        if ($c0 -ge [char]'0' -and $c0 -le [char]'9') {
            # 先頭が数字のときだけ「全部数字か」を確かめる。大半の語はここへ来ない。
            $allDigits = $true
            for ($i = 1; $i -lt $t.Length; $i++) {
                $c = $t[$i]
                if ($c -lt [char]'0' -or $c -gt [char]'9') { $allDigits = $false; break }
            }
            if ($allDigits) { continue }
        }
        if ($script:YakuCorpusStopWords.ContainsKey($t)) { continue }
        [void]$tokens.Add($t)
    }
    return @($tokens.ToArray())
}

function Split-YakuCorpusPassages {
    <#
      1つの Markdown を、引ける単位（一節）へ切る。

      切り方の方針:
       - ページ境界（<!--yaku-page:N-->）を越えない。出典としてページを示せるようにするため。
       - 空行で段落へ切り、短い段落は隣とつないで $TargetChars 程度にまとめる。
         1行だけの見出しや表の1行は、単独では文例にならない。
       - 極端に短い一節は捨てる。文例として役に立たないため。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Markdown,
        [int]$TargetChars = 900,
        [int]$MinChars = 60
    )
    $result = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Markdown)) { return @($result.ToArray()) }

    $normalized = $Markdown.Replace("`r`n", "`n").Replace("`r", "`n")
    # ページ番号を保ったまま切る。境界の行そのものは本文ではないので捨てる。
    $page = 0
    $pageTexts = New-Object System.Collections.Generic.List[object]
    $buffer = New-Object System.Text.StringBuilder
    foreach ($line in @($normalized -split "`n")) {
        $m = [regex]::Match([string]$line, '^\s*<!--\s*yaku-page:(\d+)\s*-->\s*$')
        if ($m.Success) {
            if ($buffer.Length -gt 0) {
                [void]$pageTexts.Add([pscustomobject]@{ Page = $page; Text = $buffer.ToString() })
                $buffer = New-Object System.Text.StringBuilder
            }
            $page = [int]$m.Groups[1].Value
            continue
        }
        [void]$buffer.AppendLine([string]$line)
    }
    if ($buffer.Length -gt 0) {
        [void]$pageTexts.Add([pscustomobject]@{ Page = $page; Text = $buffer.ToString() })
    }

    foreach ($pt in $pageTexts) {
        $chunk = New-Object System.Text.StringBuilder
        foreach ($para in @([regex]::Split([string]$pt.Text, "`n\s*`n"))) {
            $clean = ([string]$para).Trim()
            if ([string]::IsNullOrWhiteSpace($clean)) { continue }
            # 先に足してから測ると、目安の倍近い一節ができてしまう。
            # 入れると超えるなら、いま溜まっている分を先に確定させる。
            if ($chunk.Length -ge $MinChars -and ($chunk.Length + $clean.Length) -gt $TargetChars) {
                [void]$result.Add([pscustomobject]@{ Page = [int]$pt.Page; Text = $chunk.ToString() })
                $chunk = New-Object System.Text.StringBuilder
            }
            if ($chunk.Length -gt 0) { [void]$chunk.Append("`n`n") }
            [void]$chunk.Append($clean)
            # 1つの段落だけで目安を超えるときは、そこで切る。次と混ぜない。
            if ($chunk.Length -ge $TargetChars) {
                [void]$result.Add([pscustomobject]@{ Page = [int]$pt.Page; Text = $chunk.ToString() })
                $chunk = New-Object System.Text.StringBuilder
            }
        }
        if ($chunk.Length -ge $MinChars) {
            [void]$result.Add([pscustomobject]@{ Page = [int]$pt.Page; Text = $chunk.ToString() })
        }
    }
    return @($result.ToArray())
}

function ConvertTo-YakuCorpusIndexField {
    # TSV の1項目へ入れられる形にする。復元できることが条件。
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('\', '\\').Replace("`r`n", '\n').Replace("`r", '\n').Replace("`n", '\n').Replace("`t", '\t')
}

function ConvertFrom-YakuCorpusIndexField {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # 逃がした文字が無ければ1文字ずつ見る必要はない。
    # データベース名や出典はほぼここで返る。
    if ($Text.IndexOf('\') -lt 0) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -ne '\' -or $i -eq $Text.Length - 1) { [void]$sb.Append($c); continue }
        $i++
        switch ([string]$Text[$i]) {
            'n'     { [void]$sb.Append("`n") }
            't'     { [void]$sb.Append("`t") }
            '\'     { [void]$sb.Append('\') }
            default { [void]$sb.Append('\'); [void]$sb.Append($Text[$i]) }
        }
    }
    return $sb.ToString()
}

function Get-YakuCorpusIndexSignature {
    <#
      コーパスが変わったかどうかを表す短い文字列。
      これが索引側と一致していれば、作り直さない。
      内容そのものではなく台帳（版・更新時刻・件数）で見る。
      台帳は取り込みのたびに書き換わるため、これで十分に検出できる。
    #>
    param([Parameter(Mandatory=$true)]$Manifest)
    $version = [string]$Manifest.corpus_version
    $updated = [string]$Manifest.updated
    $count = @($Manifest.entries).Count
    return ($version + '|' + $updated + '|' + $count)
}

function Get-YakuCorpusIndexDir {
    <#
      索引の置き場所。コーパスの版ごとに分ける。
      版が無い（管理者の作業中のコーパス）ときは 'build' に落とす。
    #>
    param([Parameter(Mandatory=$true)][string]$CorpusDir)
    $manifest = Read-YakuCorpusManifest -Dir $CorpusDir
    $name = [string]$manifest.corpus_version
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'build' }
    if ($name -match '[\\/:*?"<>|]') { $name = 'build' }
    return (Join-Path (Get-YakuCorpusIndexRootDir) $name)
}

function New-YakuCorpusIndex {
    <#
      コーパスの Markdown から索引を作る。

      出力（すべて TSV。JSON にしないのは、PowerShell 5.1 の ConvertFrom-Json が
      数MB で目に見えて遅く、検索のたびに読むには重いため）:

        meta.tsv       schema / signature / passages / avgdl など
        passages.tsv   id, database, source, page, length, text
        postings.tsv   term, df, "id:tf id:tf ..."
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CorpusDir,
        [AllowNull()][string]$IndexDir
    )
    if (!(Test-Path -LiteralPath $CorpusDir -PathType Container)) {
        throw "CORPUS_INDEX_NO_SOURCE: コーパスが見つかりません: $CorpusDir"
    }
    $manifest = Read-YakuCorpusManifest -Dir $CorpusDir
    if ([string]::IsNullOrWhiteSpace($IndexDir)) { $IndexDir = Get-YakuCorpusIndexDir -CorpusDir $CorpusDir }
    if (!(Test-Path -LiteralPath $IndexDir)) { New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null }

    $passageLines = New-Object System.Collections.Generic.List[string]
    # term -> 転置の行を組み立てる StringBuilder。
    # 語ごとに List<string> へ入れて後で連結すると、60万回の文字列連結になり遅い。
    $postings = @{}
    $postingCounts = @{}
    $totalLength = 0
    $id = 0
    $docCount = 0

    foreach ($entry in @($manifest.entries)) {
        if ([string]$entry.status -eq 'failed') { continue }
        $rel = [string]$entry.markdown
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $path = Join-Path $CorpusDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $text = [System.IO.File]::ReadAllText($path) } catch { continue }
        $docCount++
        $database = [string]$entry.database
        $source = [string]$entry.source
        foreach ($passage in @(Split-YakuCorpusPassages -Markdown $text)) {
            $tokens = @(Get-YakuCorpusTokens -Text ([string]$passage.Text))
            if ($tokens.Count -le 0) { continue }
            $tf = @{}
            foreach ($tok in $tokens) {
                if ($tf.ContainsKey($tok)) { $tf[$tok] = [int]$tf[$tok] + 1 } else { $tf[$tok] = 1 }
            }
            foreach ($tok in $tf.Keys) {
                if ($postings.ContainsKey($tok)) {
                    [void]$postings[$tok].Append(' ')
                    $postingCounts[$tok] = [int]$postingCounts[$tok] + 1
                } else {
                    $postings[$tok] = New-Object System.Text.StringBuilder
                    $postingCounts[$tok] = 1
                }
                [void]$postings[$tok].Append($id).Append(':').Append($tf[$tok])
            }
            [void]$passageLines.Add((@(
                [string]$id
                (ConvertTo-YakuCorpusIndexField $database)
                (ConvertTo-YakuCorpusIndexField $source)
                [string]$passage.Page
                [string]$tokens.Count
                (ConvertTo-YakuCorpusIndexField ([string]$passage.Text))
            ) -join "`t"))
            $totalLength += $tokens.Count
            $id++
        }
    }

    $avgdl = 0.0
    if ($id -gt 0) { $avgdl = [double]$totalLength / [double]$id }

    $postingLines = New-Object System.Collections.Generic.List[string]
    foreach ($term in @($postings.Keys | Sort-Object)) {
        [void]$postingLines.Add(($term + "`t" + [string]$postingCounts[$term] + "`t" + $postings[$term].ToString()))
    }

    $meta = @(
        ('schema' + "`t" + $script:YakuCorpusIndexSchema)
        ('signature' + "`t" + (Get-YakuCorpusIndexSignature -Manifest $manifest))
        ('corpus_version' + "`t" + [string]$manifest.corpus_version)
        ('corpus_dir' + "`t" + (ConvertTo-YakuCorpusIndexField $CorpusDir))
        ('documents' + "`t" + [string]$docCount)
        ('passages' + "`t" + [string]$id)
        ('terms' + "`t" + [string]$postingLines.Count)
        ('avgdl' + "`t" + $avgdl.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        ('built' + "`t" + (Get-Date).ToString('s'))
    )

    Write-YakuTextAtomic -Path (Join-Path $IndexDir 'passages.tsv') -Text (($passageLines.ToArray()) -join "`n")
    Write-YakuTextAtomic -Path (Join-Path $IndexDir 'postings.tsv') -Text (($postingLines.ToArray()) -join "`n")
    # meta は最後に書く。途中で落ちたときに「出来上がっている」と誤解させないため。
    Write-YakuTextAtomic -Path (Join-Path $IndexDir 'meta.tsv') -Text (($meta) -join "`n")

    try { Write-YakuLog "Corpus index built. dir=$IndexDir documents=$docCount passages=$id terms=$($postingLines.Count)" 'INFO' } catch {}
    return [pscustomobject]@{
        IndexDir  = [string]$IndexDir
        CorpusDir = [string]$CorpusDir
        Documents = [int]$docCount
        Passages  = [int]$id
        Terms     = [int]$postingLines.Count
        AvgLength = [double]$avgdl
    }
}

function Read-YakuCorpusIndexMeta {
    param([Parameter(Mandatory=$true)][string]$IndexDir)
    $path = Join-Path $IndexDir 'meta.tsv'
    $meta = @{}
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $meta }
    try { $lines = @([System.IO.File]::ReadAllLines($path)) } catch { return $meta }
    foreach ($line in $lines) {
        $clean = ([string]$line).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $parts = $clean -split "`t", 2
        if ($parts.Count -ne 2) { continue }
        $meta[[string]$parts[0]] = [string]$parts[1]
    }
    return $meta
}

function Test-YakuCorpusIndexCurrent {
    <#
      索引がいまのコーパスに追いついているか。
      書式が変わったとき（schema 不一致）も作り直す対象にする。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CorpusDir,
        [AllowNull()][string]$IndexDir
    )
    if ([string]::IsNullOrWhiteSpace($IndexDir)) { $IndexDir = Get-YakuCorpusIndexDir -CorpusDir $CorpusDir }
    foreach ($name in @('meta.tsv','passages.tsv','postings.tsv')) {
        if (!(Test-Path -LiteralPath (Join-Path $IndexDir $name) -PathType Leaf)) { return $false }
    }
    $meta = Read-YakuCorpusIndexMeta -IndexDir $IndexDir
    if ([string]$meta['schema'] -ne $script:YakuCorpusIndexSchema) { return $false }
    $manifest = Read-YakuCorpusManifest -Dir $CorpusDir
    return ([string]$meta['signature'] -eq (Get-YakuCorpusIndexSignature -Manifest $manifest))
}

function Initialize-YakuCorpusIndex {
    <#
      索引が無い・古いときだけ作る。あれば何もしない。

      一般利用者の起動経路からは呼ばない（修正指示書 §7-3）。
      検索が要るときに初めて呼ぶこと。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CorpusDir,
        [AllowNull()][string]$IndexDir,
        [switch]$Force
    )
    if ([string]::IsNullOrWhiteSpace($IndexDir)) { $IndexDir = Get-YakuCorpusIndexDir -CorpusDir $CorpusDir }
    if (-not $Force -and (Test-YakuCorpusIndexCurrent -CorpusDir $CorpusDir -IndexDir $IndexDir)) {
        return [pscustomobject]@{ IndexDir = [string]$IndexDir; Rebuilt = $false }
    }
    $built = New-YakuCorpusIndex -CorpusDir $CorpusDir -IndexDir $IndexDir
    return [pscustomobject]@{ IndexDir = [string]$built.IndexDir; Rebuilt = $true }
}

function Get-YakuCorpusBm25Score {
    <#
      BM25。順位づけをここに閉じ込める。
      埋め込み検索を後から差し込むときは、この関数の対になるものを足せばよい
      （要件整理 §6-1-4「検索層を差し替え可能にする」）。

      $Postings は term -> @{ 'id' = tf } の形。
    #>
    param(
        [Parameter(Mandatory=$true)][string[]]$QueryTerms,
        [Parameter(Mandatory=$true)]$Postings,
        [Parameter(Mandatory=$true)]$Lengths,
        [Parameter(Mandatory=$true)][int]$TotalPassages,
        [Parameter(Mandatory=$true)][double]$AvgLength
    )
    $scores = @{}
    if ($TotalPassages -le 0) { return $scores }
    $avg = $AvgLength
    if ($avg -le 0) { $avg = 1.0 }
    $k1 = $script:YakuCorpusBm25K1
    $b = $script:YakuCorpusBm25B
    # 同じ語を2回書かれても重みが倍にならないようにする。
    $seen = @{}
    foreach ($term in $QueryTerms) {
        if ($seen.ContainsKey($term)) { continue }
        $seen[$term] = $true
        if (-not $Postings.ContainsKey($term)) { continue }
        $list = $Postings[$term]
        $df = @($list.Keys).Count
        if ($df -le 0) { continue }
        # 逆文書頻度。どの一節にも出る語は効かなくなる。
        $idf = [Math]::Log(1.0 + (([double]$TotalPassages - [double]$df + 0.5) / ([double]$df + 0.5)))
        foreach ($idKey in @($list.Keys)) {
            $tf = [double]$list[$idKey]
            $len = 1.0
            if ($Lengths.ContainsKey($idKey)) { $len = [double]$Lengths[$idKey] }
            if ($len -le 0) { $len = 1.0 }
            $denom = $tf + $k1 * (1.0 - $b + $b * ($len / $avg))
            if ($denom -le 0) { continue }
            $add = $idf * (($tf * ($k1 + 1.0)) / $denom)
            if ($scores.ContainsKey($idKey)) { $scores[$idKey] = [double]$scores[$idKey] + $add }
            else { $scores[$idKey] = $add }
        }
    }
    return $scores
}

function Search-YakuCorpus {
    <#
      英語の検索語でコーパスを引く。

      戻り値は順位順の一節。呼び出し側はこの形だけを見ること。
      検索方式を差し替えても、ここの形が変わらなければ翻訳経路は無傷で済む。

      $Databases を渡すと、そのデータベース（原本フォルダ直下のフォルダ名）だけに絞る。
      段階4 の「どのデータベースを参照に含めるか」の受け口である。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Query,
        [AllowNull()][string]$CorpusDir,
        [AllowNull()][string[]]$Databases,
        [int]$Top = 5
    )
    $empty = @()
    if ([string]::IsNullOrWhiteSpace($CorpusDir)) { $CorpusDir = Get-YakuCorpusDir }
    if ([string]::IsNullOrWhiteSpace($CorpusDir)) { return $empty }
    $terms = @(Get-YakuCorpusTokens -Text $Query)
    if ($terms.Count -le 0) { return $empty }

    $ready = $null
    try { $ready = Initialize-YakuCorpusIndex -CorpusDir $CorpusDir } catch {
        # 索引が作れなくても翻訳は続けられる。コーパス無しと同じ扱いにする。
        try { Write-YakuLog "Corpus index unavailable. dir=$CorpusDir error=$($_.Exception.Message)" 'WARN' } catch {}
        return $empty
    }
    $indexDir = [string]$ready.IndexDir
    $meta = Read-YakuCorpusIndexMeta -IndexDir $indexDir
    $total = 0
    try { $total = [int]$meta['passages'] } catch { $total = 0 }
    if ($total -le 0) { return $empty }
    $avgdl = 1.0
    try { $avgdl = [double]::Parse([string]$meta['avgdl'], [System.Globalization.CultureInfo]::InvariantCulture) } catch { $avgdl = 1.0 }

    # 検索語に当たる行だけを取り出す。全語の転置を組み立てると無駄が大きい。
    $wanted = @{}
    foreach ($t in $terms) { $wanted[$t] = $true }
    $postings = @{}
    try { $postingLines = @([System.IO.File]::ReadAllLines((Join-Path $indexDir 'postings.tsv'))) } catch { return $empty }
    foreach ($line in $postingLines) {
        $clean = ([string]$line).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $tab = $clean.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $term = $clean.Substring(0, $tab)
        if (-not $wanted.ContainsKey($term)) { continue }
        $parts = $clean -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $map = @{}
        foreach ($pair in @(([string]$parts[2]) -split ' ')) {
            if ([string]::IsNullOrWhiteSpace($pair)) { continue }
            $colon = $pair.IndexOf(':')
            if ($colon -lt 0) { continue }
            $map[$pair.Substring(0, $colon)] = [int]$pair.Substring($colon + 1)
        }
        if ($map.Count -gt 0) { $postings[$term] = $map }
    }
    if ($postings.Count -le 0) { return $empty }

    # 一節の一覧。長さ（BM25 の正規化）と絞り込み（データベース）に要る。
    #
    # ここでは行を切り分けるだけで、本文の復元はしない。
    # 当たった一節すべてを復元すると、一節6000件の実測で 7秒かかった。
    # 復元するのは最後に残す数件だけでよい。
    try { $passageLines = @([System.IO.File]::ReadAllLines((Join-Path $indexDir 'passages.tsv'))) } catch { return $empty }
    $dbFilter = $null
    if ($null -ne $Databases -and @($Databases).Count -gt 0) {
        $dbFilter = @{}
        # 比較は逃がしたままの値で行う。行ごとに復元しないため。
        foreach ($d in @($Databases)) {
            if ([string]::IsNullOrWhiteSpace([string]$d)) { continue }
            $dbFilter[(ConvertTo-YakuCorpusIndexField ([string]$d))] = $true
        }
        if ($dbFilter.Count -le 0) { $dbFilter = $null }
    }
    # 検索語のどれかに当たった一節だけを候補にする。
    # 全行を切り分けると、一節6000件で毎回その費用がかかる。
    # 先頭の id だけを見て、候補でなければ切り分けない。
    $candidates = @{}
    foreach ($term in @($postings.Keys)) {
        foreach ($k in @($postings[$term].Keys)) { $candidates[$k] = $true }
    }
    $rows = @{}
    $lengths = @{}
    foreach ($line in $passageLines) {
        $clean = [string]$line
        if ($clean.Length -le 0) { continue }
        if ($clean[0] -eq [char]0xFEFF) { $clean = $clean.Substring(1) }
        $tab = $clean.IndexOf("`t")
        if ($tab -le 0) { continue }
        $rowId = $clean.Substring(0, $tab)
        if (-not $candidates.ContainsKey($rowId)) { continue }
        $parts = $clean -split "`t", 6
        if ($parts.Count -lt 6) { continue }
        # データベースで絞るなら、得点を付ける前に落とす。無駄な計算をしない。
        if ($null -ne $dbFilter -and -not $dbFilter.ContainsKey([string]$parts[1])) { continue }
        $rows[$rowId] = $parts
        $lengths[$rowId] = [int]$parts[4]
    }
    if ($lengths.Count -le 0) { return $empty }

    $scores = Get-YakuCorpusBm25Score -QueryTerms $terms -Postings $postings -Lengths $lengths -TotalPassages $total -AvgLength $avgdl
    if ($scores.Count -le 0) { return $empty }

    if ($Top -le 0) { $Top = 5 }
    # 同点のときは id で並びを決める。同じ問いで結果が入れ替わらないようにするため。
    $order = @(@($scores.Keys) |
        Where-Object { $rows.ContainsKey($_) } |
        Sort-Object -Property @{Expression={[double]$scores[$_]};Descending=$true}, @{Expression={[int]$_};Descending=$false} |
        Select-Object -First $Top)
    if ($order.Count -le 0) { return $empty }

    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($rowId in $order) {
        $parts = $rows[$rowId]
        [void]$ranked.Add([pscustomobject]@{
            Id       = $rowId
            Score    = [double]$scores[$rowId]
            Database = (ConvertFrom-YakuCorpusIndexField ([string]$parts[1]))
            Source   = (ConvertFrom-YakuCorpusIndexField ([string]$parts[2]))
            Page     = [int]$parts[3]
            Text     = (ConvertFrom-YakuCorpusIndexField ([string]$parts[5]))
        })
    }
    return @($ranked.ToArray())
}
