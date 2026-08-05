<#
  V91.61 段階2: 参考資料コーパスの検索。

  段階1（Corpus.ps1）が作った英語 Markdown を、引ける形にする。

  設計の前提（_docs/要件整理_汎用翻訳アプリとRAG翻訳.md §13-4, §6-1）:
   - コーパスは**英語側だけ**。日本語との対応づけ（文アライメント）は持たない。
   - 日本語の原文から英語コーパスを引く橋渡しは、段階3 で Copilot に
     英語の検索語を作らせて行う（Agentic RAG）。ここはその検索器を用意する。
   - 埋め込みは使わない。利用者端末にモデルもランタイムも置かない。
     財務文書は固有名詞・勘定科目・定型表現が多く字面が一致しやすいため、
     語彙検索で足りるという実測（§13-5 FinanceBench で語彙検索が +6pt）がある。

  なぜ転置索引を作らないのか（実測 2026-08-05。詳細は _docs/V91.61_段階2_コーパス検索.md）:

    はじめは転置索引（TSV）を作って引いていた。しかし実測すると、
    索引を使わず .md を直接読むほうが速かった。

      資料100件: 索引あり 415ms / 直引き 456ms（ほぼ互角）
      資料300件: 索引あり 1,175ms / 直引き 593ms
      資料600件: 索引あり 2,357ms / 直引き 875ms

    遅かったのは読み込みではない（索引の読み込みは全体の 1〜8% だった）。
    6,000〜36,000 行の転置を **PowerShell で解釈しながら回す**部分である。
    直引きは String.IndexOf に丸投げするため、繰り返しが .NET の中で完結する。

    **この環境では「賢いデータ構造を自前で回す」より
    「素朴な処理を .NET へ投げる」ほうが速い。**
    C# へ降ろしても速くならなかった（89ms 対 90ms）。残りの時間は
    ファイル読み込みと小文字化そのものであり、そこが下限である。

    互角の規模でも直引きを採る。索引をやめたことで、利用者側の索引作成（最大2分）・
    索引ファイル（10〜65MB）・鮮度判定・書式の版管理が、まとめて消えたため。
    コーパスを変えたら次の検索へ即座に反映される。

  差し替え可能にしておくこと（§6-1-4）:
   - 順位づけ（Get-YakuCorpusBm25Score）を独立させてある。
   - 呼び出し側は Search-YakuCorpus の戻り値だけを見る。
     後から別の検索方式を差し込むときに、翻訳経路を触らずに済む。
#>

# この module では、繰り返しの中の Add / Append を「| Out-Null」ではなく [void] で捨てる。
# 実測で、List.Add へ | Out-Null を付けると 72万回で 100 秒、[void] なら 1.7 秒だった。
# パイプラインを1回組み立てる費用が呼び出しごとにかかるため。
# 繰り返しの外では、既存コードに合わせて | Out-Null のままでよい。

# 語彙検索の重みづけ。BM25 の一般的な既定値。
$script:YakuCorpusBm25K1 = 1.2
$script:YakuCorpusBm25B  = 0.75

# 一節の長さの基準。Split-YakuCorpusPassages の目安と合わせる。
# 標本から平均を出すと、絞り込んだ数件に引きずられて基準が動く。定数のほうが安定する。
$script:YakuCorpusRefLength = 900.0

# 一節へ切り分ける対象にする文書の数。
# ここを増やしても、増えるのは切り分けの費用だけ（読み込みは全件で済んでいる）。
$script:YakuCorpusDocCandidates = 8

# 英語の機能語。検索語から外す。
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
      英語の文を検索語へ分ける。

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
    #
    # 行ごとに正規表現を当てると、資料8件（480一節）で 202ms かかっていた。
    # 文書ごとに1回だけ分割する。Regex.Split は括弧で囲んだ部分（ページ番号）も
    # 結果に含めるため、[本文, 番号, 本文, 番号, 本文, …] の並びで返る。
    # \s ではなく [ \t]* にするのは、\s が改行を飲んで隣の行とつながらないようにするため。
    $pageTexts = New-Object System.Collections.Generic.List[object]
    $parts = @([regex]::Split($normalized, '(?m)^[ \t]*<!--[ \t]*yaku-page:(\d+)[ \t]*-->[ \t]*$'))
    if ($parts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$parts[0])) {
        # 最初の境界より前にある本文。ページ番号は分からないので 0 にする。
        [void]$pageTexts.Add([pscustomobject]@{ Page = 0; Text = [string]$parts[0] })
    }
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $pageNo = 0
        try { $pageNo = [int]$parts[$i] } catch { $pageNo = 0 }
        $body = ''
        if (($i + 1) -lt $parts.Count) { $body = [string]$parts[$i + 1] }
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        [void]$pageTexts.Add([pscustomobject]@{ Page = $pageNo; Text = $body })
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

function Measure-YakuCorpusTermHits {
    <#
      小文字化済みの文字列に、各検索語が何回出るかを数える。

      数えるのは String.IndexOf だけにする。ここが全体の費用のほとんどを占めるため、
      PowerShell 側の処理を増やさない（正規表現にすると目に見えて遅くなる）。

      戻り値は $Terms と同じ並びの int[]。

      部分一致で数えるので ratio は ratios にも当たる。
      英語の資料ではこれは概ね利点になる（簡易な語幹処理として働く）。
    #>
    # 引数に [Parameter()] を付けない。一節ごとに呼ばれるため、
    # 属性つきの引数束縛の費用が効く（480回で 66ms 対 39ms）。
    #
    # 戻り値は int[] だけにする。当たった語の数は呼び出し側で数えればよく、
    # 一節ごとに PSCustomObject を作ると、それだけで無視できない時間になる。
    param([string]$LowerText, [string[]]$Terms)
    $counts = [int[]]::new($Terms.Count)
    if ([string]::IsNullOrEmpty($LowerText)) { return $counts }
    for ($t = 0; $t -lt $Terms.Count; $t++) {
        $term = $Terms[$t]
        $idx = 0
        $c = 0
        while (($idx = $LowerText.IndexOf($term, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
            $c++
            $idx += $term.Length
        }
        $counts[$t] = $c
    }
    return $counts
}

function Get-YakuCorpusBm25Score {
    <#
      一節1件の得点。順位づけをここに閉じ込める。
      別の方式へ差し替えるときは、この関数の対になるものを足せばよい
      （要件整理 §6-1-4「検索層を差し替え可能にする」）。

      $DocFreq は「その語を含む**資料**の数」である。一節ではない。
      一節ごとの文書頻度を数えるには全一節を走査する必要があり、それは索引を
      作るのと同じ費用になる。資料単位の粗い値でも、
      「どの資料にも出る語を軽くする」という IDF の役目は果たせる。
    #>
    # 引数に [Parameter()] を付けない理由は Measure-YakuCorpusTermHits と同じ。
    param([int[]]$Counts, [int[]]$DocFreq, [int]$DocumentCount, [int]$Length)
    $score = 0.0
    if ($DocumentCount -le 0) { return $score }
    $k1 = $script:YakuCorpusBm25K1
    $b = $script:YakuCorpusBm25B
    $lenRatio = ([double]$Length) / $script:YakuCorpusRefLength
    if ($lenRatio -le 0) { $lenRatio = 1.0 }
    for ($t = 0; $t -lt $Counts.Count; $t++) {
        $c = [double]$Counts[$t]
        if ($c -le 0) { continue }
        $df = [double]$DocFreq[$t]
        if ($df -le 0) { continue }
        # 逆文書頻度。どの資料にも出る語は効かなくなる。
        $idf = [Math]::Log(1.0 + (([double]$DocumentCount - $df + 0.5) / ($df + 0.5)))
        $denom = $c + $k1 * (1.0 - $b + $b * $lenRatio)
        if ($denom -le 0) { continue }
        $score += $idf * (($c * ($k1 + 1.0)) / $denom)
    }
    return $score
}

function Get-YakuCorpusDocumentMatches {
    <#
      段階1: コーパスの .md を読み、検索語の出現数と文書頻度を出す。

      読み込みは全件だが、繰り返しは資料の数ぶんで済む（一節の数ではない）。
      実測では、ここと小文字化がほぼ全体の費用である。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CorpusDir,
        [Parameter(Mandatory=$true)][string[]]$Terms,
        [AllowNull()][string[]]$Databases
    )
    $manifest = Read-YakuCorpusManifest -Dir $CorpusDir
    $dbFilter = $null
    if ($null -ne $Databases -and @($Databases).Count -gt 0) {
        $dbFilter = @{}
        foreach ($d in @($Databases)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$d)) { $dbFilter[[string]$d] = $true }
        }
        if ($dbFilter.Count -le 0) { $dbFilter = $null }
    }
    $docs = New-Object System.Collections.Generic.List[object]
    $docFreq = New-Object 'int[]' $Terms.Count
    $scanned = 0
    foreach ($entry in @($manifest.entries)) {
        if ([string]$entry.status -eq 'failed') { continue }
        $rel = [string]$entry.markdown
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $database = [string]$entry.database
        if ($null -ne $dbFilter -and -not $dbFilter.ContainsKey($database)) { continue }
        $path = Join-Path $CorpusDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $text = [System.IO.File]::ReadAllText($path) } catch { continue }
        $scanned++
        $counts = Measure-YakuCorpusTermHits -LowerText $text.ToLowerInvariant() -Terms $Terms
        # 絞り込みの並び。検索語をより多く含む資料を優先し、次に出現数で見る。
        # ここは順位そのものではなく「一節へ切る候補」を選ぶだけなので粗くてよい。
        $rank = 0.0
        $matched = 0
        for ($t = 0; $t -lt $Terms.Count; $t++) {
            $c = $counts[$t]
            if ($c -le 0) { continue }
            $matched++
            $docFreq[$t] = $docFreq[$t] + 1
            $rank += 1.0 + [Math]::Log(1.0 + [double]$c) * 0.1
        }
        if ($matched -le 0) { continue }
        [void]$docs.Add([pscustomobject]@{
            Path     = [string]$path
            Database = $database
            Source   = [string]$entry.source
            Rank     = $rank
        })
    }
    return [pscustomobject]@{
        Documents     = @($docs.ToArray())
        DocFreq       = $docFreq
        ScannedCount  = [int]$scanned
    }
}

function Search-YakuCorpus {
    <#
      英語の検索語でコーパスを引く。

      2段構え:
        ① .md を読み、検索語の出現数を数えて資料を絞る（文書頻度もここで手に入る）
        ② 残った資料だけを一節へ切り、BM25 で順位づけする

      戻り値は順位順の一節。呼び出し側はこの形だけを見ること。
      検索方式を差し替えても、ここの形が変わらなければ翻訳経路は無傷で済む。

      $Databases を渡すと、そのデータベース（原本フォルダ直下のフォルダ名）だけに絞る。
      段階4 の「どのデータベースを参照に含めるか」の受け口である。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Query,
        [AllowNull()][string]$CorpusDir,
        [AllowNull()][string[]]$Databases,
        [int]$Top = 5,
        [int]$DocumentCandidates = 0
    )
    $empty = @()
    if ([string]::IsNullOrWhiteSpace($CorpusDir)) { $CorpusDir = Get-YakuCorpusDir }
    if ([string]::IsNullOrWhiteSpace($CorpusDir)) { return $empty }
    if (!(Test-Path -LiteralPath $CorpusDir -PathType Container)) { return $empty }
    $terms = @(Get-YakuCorpusTokens -Text $Query)
    if ($terms.Count -le 0) { return $empty }
    if ($Top -le 0) { $Top = 5 }
    if ($DocumentCandidates -le 0) { $DocumentCandidates = $script:YakuCorpusDocCandidates }

    $phase1 = $null
    try {
        $phase1 = Get-YakuCorpusDocumentMatches -CorpusDir $CorpusDir -Terms $terms -Databases $Databases
    } catch {
        # 引けなくても翻訳は続けられる。コーパス無しと同じ扱いにする。
        try { Write-YakuLog "Corpus search failed. dir=$CorpusDir error=$($_.Exception.Message)" 'WARN' } catch {}
        return $empty
    }
    $candidates = @($phase1.Documents)
    if ($candidates.Count -le 0) { return $empty }
    $shortlist = @(@($candidates) |
        Sort-Object -Property @{Expression='Rank';Descending=$true}, @{Expression='Source';Descending=$false} |
        Select-Object -First $DocumentCandidates)

    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($doc in $shortlist) {
        # 一節の本文は元の大文字小文字のまま返す。文例として見せるため。
        try { $text = [System.IO.File]::ReadAllText([string]$doc.Path) } catch { continue }
        foreach ($passage in @(Split-YakuCorpusPassages -Markdown $text)) {
            $body = [string]$passage.Text
            $counts = Measure-YakuCorpusTermHits -LowerText $body.ToLowerInvariant() -Terms $terms
            $score = Get-YakuCorpusBm25Score -Counts $counts -DocFreq $phase1.DocFreq `
                -DocumentCount ([int]$phase1.ScannedCount) -Length $body.Length
            if ($score -le 0) { continue }
            [void]$ranked.Add([pscustomobject]@{
                Score    = [double]$score
                Database = [string]$doc.Database
                Source   = [string]$doc.Source
                Page     = [int]$passage.Page
                Text     = $body
            })
        }
    }
    if ($ranked.Count -le 0) { return $empty }
    # 同点のときは出典とページで並びを決める。同じ問いで結果が入れ替わらないようにするため。
    return @(@($ranked.ToArray()) |
        Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Source';Descending=$false}, @{Expression='Page';Descending=$false} |
        Select-Object -First $Top)
}

function Remove-YakuCorpusLegacyIndex {
    <#
      転置索引をやめる前の版が作った corpus-index フォルダを片付ける。

      作ったのはこのアプリ自身で、ファイル名も決めてある。
      見覚えのあるものだけを消し、それ以外が混じっていたら触らない。
      放っておくと 10〜65MB がデータディレクトリに残り続けるため。
    #>
    $dir = Join-Path (Get-YakuDataDir) 'corpus-index'
    if (!(Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    $known = @{ 'meta.tsv' = $true; 'passages.tsv' = $true; 'postings.tsv' = $true }
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction Stop)) {
            if (-not $known.ContainsKey([string]$file.Name)) { return $false }
        }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
        try { Write-YakuLog "Legacy corpus index removed. dir=$dir" 'INFO' } catch {}
        return $true
    } catch {
        return $false
    }
}
