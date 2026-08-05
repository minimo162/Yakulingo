<#
  V91.61 段階3: 参考資料コーパスを翻訳へ渡す。

  なぜこれを作るのか（_docs/要件整理_汎用翻訳アプリとRAG翻訳.md §3-1）:

    **現状の翻訳は用語集に依存しているが、その用語集が網羅的でない。**
    表の項目のように固定化された語は完全一致で拾えるが、それ以外は
    その時々で表現が変わるため、用語集を書ききることができない。
    載っていない語は、依頼のたびに違う訳語になる。

    用語集を増やして解こうとすると、語を足すたびに別の抜けが出る。
    そこで**社内の過去の英文資料そのものを見せる**方式へ移す。
    「この語はこう訳す」ではなく「社内ではこう書いている」を示す。

    コーパスは足しであって前提ではない。**引けなければ従来どおり訳す。**

  経路（要件整理 §13-4）:

    原文（日本語）
      ↓ ① Copilot に英語の検索語を作らせる（ジョブごとに1回）
    検索語（英語）
      ↓ ② Search-YakuCorpus（段階2）
    関連する英語の一節 数件（出典つき）
      ↓ ③ 翻訳プロンプトへ文例として添える
    訳文

  適用範囲（2026-08-05 に確定）:

   - **テキスト翻訳の JA→EN のみ。** ファイル翻訳には入れない。
     ファイル翻訳のバッチは文字数で切られた無関係なセル片の寄せ集めで、
     1つの検索語では代表できない。出力も短いラベルなので、
     数百字の一節を文例として見せても噛み合わない。
     ファイル翻訳は完全一致の用語集（cell-exact）が効く領域であり、そのままにする。
   - EN→JA には入れない。コーパスは英語側だけなので、
     英語が入力側にある方向では「社内の言い回し」を示す意味がない。
   - **設定項目は増やさない。** コーパスがあれば使い、無ければ使わない。
#>

# 文例として見せる件数と長さ。多すぎると原文より文例が長くなり、依頼の焦点がぼやける。
$script:YakuCorpusExampleCount = 3
$script:YakuCorpusExampleChars = 600

# 検索語の上限。多すぎると当たりが散り、どの一節も同じくらいの得点になる。
$script:YakuCorpusQueryTermLimit = 12

function Test-YakuCorpusReferenceApplicable {
    # 参照文例を使う条件。ここを1か所にまとめ、呼び出し側で条件を散らさない。
    param([AllowNull()][string]$Direction)
    return ([string]$Direction -eq 'to_en')
}

function ConvertTo-YakuCorpusExampleText {
    <#
      文例に含まれる数字を伏せる。

      V91.60 の【N1】は使わない。原文側のプレースホルダーと名前空間が衝突し、
      「SOURCE にある token と同じ数だけ出力に現れること」という規則が
      文例のぶんだけ狂うため（要件整理 §6-4 で未解決としていた問題）。
      文例に必要なのは言い回しであって数字ではないので、伏せ字で足りる。

      いまのコーパスは開示済み資料だけなので数字を送っても差し支えないが、
      過去 ECM 資料を入れる段階5 では伏せることが前提になる。
      先に伏せておけば、そのときの判断はデータの入れ替えだけで済む。
    #>
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '\d[\d,\.]*', '#')
}

function Get-YakuCorpusExampleSection {
    <#
      引いた一節を、プロンプトへ入れる形にする。
      出典を必ず添える。どの資料の何ページから来たか分からない文例は、
      おかしいと気づいたときに確かめようがない。
    #>
    param([AllowNull()][object[]]$Hits)
    if ($null -eq $Hits -or @($Hits).Count -le 0) { return '' }
    $nl = [Environment]::NewLine
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('CORPUS_EXAMPLES: excerpts from the company''s own past English disclosure documents. Use them ONLY to match terminology, wording, and tone. Do not translate them, do not repeat them, and do not take any fact from them. Figures are redacted as # and must never be copied.')
    $n = 0
    foreach ($hit in @($Hits)) {
        $n++
        $body = ConvertTo-YakuCorpusExampleText -Text ([string]$hit.Text)
        if ($body.Length -gt $script:YakuCorpusExampleChars) {
            # 語の途中で切らない。切れた語が新しい語に見えると、それを真似られる。
            $cut = $body.Substring(0, $script:YakuCorpusExampleChars)
            $space = $cut.LastIndexOf(' ')
            if ($space -gt ($script:YakuCorpusExampleChars / 2)) { $cut = $cut.Substring(0, $space) }
            $body = $cut.TrimEnd() + ' ...'
        }
        $body = ($body -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($body)) { $n--; continue }
        [void]$lines.Add('[' + [string]$n + '] ' + [string]$hit.Source + ' p.' + [string]$hit.Page)
        [void]$lines.Add($body)
    }
    if ($lines.Count -le 1) { return '' }
    return (($lines.ToArray()) -join $nl)
}

function New-YakuCorpusQueryPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)][string]$RequestId
    )
    $template = Get-YakuPromptTemplate -Root $Root -Name 'corpus_query_to_en.txt'
    return Expand-YakuTemplate -Template $template -Variables @{
        input_text = $InputText.Trim()
        request_id = $RequestId
    }
}

function Get-YakuCorpusQueryTerms {
    <#
      Copilot の答えから英語の検索語を取り出す。

      SEARCH_TERMS: の行を探し、無ければ答え全体から英語の語を拾う。
      いずれにせよ Get-YakuCorpusTokens を通すので、日本語や記号は落ちる。
      作文で返されても、検索語として使えるものだけが残る。

      ラベルが在って中身が空のときは、素直に0語とする。
      ここで答え全体へ落ちると、ラベルそのもの（search, terms）を
      検索語として拾ってしまい、「語が作れなかった」ことが分からなくなる。
    #>
    param([AllowNull()][string]$Answer)
    if ([string]::IsNullOrWhiteSpace($Answer)) { return @() }
    $text = [string]$Answer
    $m = [regex]::Match($text, '(?im)^[ \t]*SEARCH_TERMS[ \t]*[:：](.*)$')
    if ($m.Success) { $text = [string]$m.Groups[1].Value }
    $terms = @(Get-YakuCorpusTokens -Text $text)
    if ($terms.Count -le 0) { return @() }
    # 同じ語を繰り返されても重みは増えない。並びは保つ（Copilot が重要な順に出す前提）。
    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($t in $terms) {
        if ($seen.ContainsKey($t)) { continue }
        $seen[$t] = $true
        [void]$unique.Add($t)
        if ($unique.Count -ge $script:YakuCorpusQueryTermLimit) { break }
    }
    return @($unique.ToArray())
}

function Get-YakuCorpusReference {
    <#
      ジョブごとに1回だけ呼ぶ。バッチごとには呼ばない。

      戻り値:
        Section  プロンプトへ入れる文字列（使えないときは空）
        Terms    実際に使った検索語
        Count    文例の件数
        Reason   使わなかった理由。診断のためだけに持つ
        Used     Copilot への往復が実際に発生したか（新規チャット待ちの判断に使う）

      **失敗しても投げない。** コーパスは足しであって前提ではないので、
      引けなければ従来どおりの翻訳へ落ちる。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)][string]$Direction,
        [AllowNull()]$Warnings,
        [AllowNull()]$ProgressState
    )
    $none = [pscustomobject]@{ Section = ''; Terms = @(); Count = 0; Reason = ''; Used = $false }
    if (-not (Test-YakuCorpusReferenceApplicable -Direction $Direction)) {
        return [pscustomobject]@{ Section = ''; Terms = @(); Count = 0; Reason = 'direction'; Used = $false; Examples = @() }
    }
    $corpusDir = ''
    try { $corpusDir = Get-YakuCorpusSearchDir } catch { $corpusDir = '' }
    if ([string]::IsNullOrWhiteSpace($corpusDir)) {
        try { Write-YakuLog 'Corpus reference skipped. reason=no-corpus' 'INFO' } catch {}
        return [pscustomobject]@{ Section = ''; Terms = @(); Count = 0; Reason = 'no-corpus'; Used = $false; Examples = @() }
    }

    $used = $false
    try {
        # 検索語を作らせる依頼にも本文を送る。翻訳と同じくマスクしてから送る。
        # ここを素通しにすると、V91.60 の「数値を外部へ出さない」保証が
        # この経路だけ抜ける。マスク表は使わないので捨てる。
        $masked = [string](New-YakuNumericMaskMap -Text $InputText -Root $Root -Direction 'to_en' -Location 'corpus-query').Text
        $requestId = [guid]::NewGuid().ToString('N')
        $prompt = New-YakuCorpusQueryPrompt -Root $Root -InputText $masked -RequestId $requestId
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $used = $true
        $answer = Invoke-YakuCopilotPrompt -Prompt $prompt -Settings $Settings -AnswerFormat labeled -Warnings $Warnings -ProgressState $ProgressState
        $sw.Stop()
        $terms = @(Get-YakuCorpusQueryTerms -Answer $answer)
        if ($terms.Count -le 0) {
            try { Write-YakuLog "Corpus reference skipped. reason=no-terms elapsedMs=$($sw.ElapsedMilliseconds)" 'INFO' } catch {}
            return [pscustomobject]@{ Section = ''; Terms = @(); Count = 0; Reason = 'no-terms'; Used = $used; Examples = @() }
        }
        $searchSw = [System.Diagnostics.Stopwatch]::StartNew()
        $hits = @(Search-YakuCorpus -Query ($terms -join ' ') -CorpusDir $corpusDir -Top $script:YakuCorpusExampleCount)
        $searchSw.Stop()
        if ($hits.Count -le 0) {
            try { Write-YakuLog "Corpus reference skipped. reason=no-hits terms=$($terms -join ',') searchMs=$($searchSw.ElapsedMilliseconds)" 'INFO' } catch {}
            return [pscustomobject]@{ Section = ''; Terms = @($terms); Count = 0; Reason = 'no-hits'; Used = $used; Examples = @() }
        }
        $section = Get-YakuCorpusExampleSection -Hits $hits
        if ([string]::IsNullOrWhiteSpace($section)) {
            return [pscustomobject]@{ Section = ''; Terms = @($terms); Count = 0; Reason = 'empty-section'; Used = $used; Examples = @() }
        }
        # 何を参照したかを画面へ出せるようにする。本文は伏せ字を掛けた後のもの。
        # 送ったものと違うものを見せない（送信内容を確かめられなくなる）。
        $examples = @(@($hits) | ForEach-Object {
            [pscustomobject]@{
                Database = [string]$_.Database
                Source   = [string]$_.Source
                Page     = [int]$_.Page
                Text     = (ConvertTo-YakuCorpusExampleText -Text ([string]$_.Text))
            }
        })
        try {
            $sources = (@($hits) | ForEach-Object { [string]$_.Source + '#' + [string]$_.Page }) -join ', '
            Write-YakuLog "Corpus reference applied. terms=$($terms -join ',') hits=$($hits.Count) queryMs=$($sw.ElapsedMilliseconds) searchMs=$($searchSw.ElapsedMilliseconds) sources=$sources" 'INFO'
        } catch {}
        return [pscustomobject]@{ Section = $section; Terms = @($terms); Count = $hits.Count; Reason = 'ok'; Used = $used; Examples = $examples }
    } catch {
        # 検索語生成の往復が失敗しても翻訳は続ける。警告も出さない。
        # 利用者はコーパスの存在を知らないため、知らない仕組みの失敗を見せない。
        try { Write-YakuLog "Corpus reference failed. error=$($_.Exception.Message)" 'WARN' } catch {}
        return [pscustomobject]@{ Section = ''; Terms = @(); Count = 0; Reason = 'error'; Used = $used; Examples = @() }
    }
}
