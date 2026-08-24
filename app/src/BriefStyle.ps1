<#
  V91.61: BRIEF の略語をアプリ側で当てる。

  なぜプロンプトから外すのか:

    BRIEF 規則 7,772 字のうち、約 2,100 字が略語表である
    （standard abbreviations / months / phrase substitutions）。
    これは**規則ではなく辞書**であり、モデルにしか判断できないことではない。

    プロンプトに書いても「使え」と言っているだけで、守られるかは確率的である。
    アプリで当てれば**必ず**揃う。用語集が「レイアウトの保証」だったのと同じで、
    **プロンプトの指示は保証にならない。**

    さらに、プロンプト全体が原文 99 字に対して 13,826 字ある。
    長さそのものが指示の効きを落とすため、辞書を外す価値はそこにもある。

  何を移して、何を残すか:

    移すのは**文脈に依らないものだけ**。同じ英単語がこの分野で1つの意味しか
    持たず、略語が一意に決まるものに限る。

    残すのは、規則自身が文脈を条件にしているもの:
      technology -> tech   （名詞のときだけ。technological は残す）
      corporate  -> corp.  （形容詞のときだけ。社名の中では変えない）
      subsidiaries -> Subs.（表の項目と見出しのときだけ）
      standard -> std. / financial -> fin. / actual -> act. など
        （普通の語と衝突する。固有名詞の中に現れる）
    これらは判断が要るのでモデルに任せる。**機械的に当てると壊す。**

  適用範囲:
   - **BRIEF だけ。** FULL は spelled-out が正しいので触らない。
   - **引用の中は触らない。** BRIEF 規則 Q1 が「引用符が残るなら FULL と
     字句が一致すること」を求めているため、中を書き換えると規則違反になる。
#>

# 置換表。左が原形、右が BRIEF での形。
#
# ここに載せてよいのは「文脈に依らないもの」だけである。迷ったら載せない。
# 載せ忘れはモデルが従来どおり処理するだけだが、誤って載せると必ず壊す。
$script:YakuBriefAbbreviationPairs = @(
    # --- 月名はここに置かない（利用者の指示 2026-08-05。プロンプトで示す）。
    #
    # 月名は文脈に依らないつもりで載せていたが、実機で人名を潰すことが分かった。
    #   April Smith -> Apr. Smith / June Tanaka -> Jun. Tanaka
    #   March / August も姓名として現れうる。
    # 機械的に当てると必ず壊すので、判断が要るものとしてモデルへ返す。
    # 指示は prompts/style_brief_rules.txt の Months にある。

    # --- 決算の言い回し。文脈に依らないのでここで当てる（2026-08-06）。
    # アブレーションで、これらをプロンプトの一覧から外すとモデルが
    # 綴りのまま書く場合があった（Rev. increased -> Sales up）。
    # 一覧で「使え」と言うのは確率的なので、当てて確定させる。
    # forecast と actual は入れない。動詞・形容詞の用法があり、
    # 「we forecast」「the actual figure」まで略すと読みにくくなる。迷ったら載せない。
    # revenue -> rev. は外した（2026-08-08）。rev. は「revised（改訂）」の略
    # としても広く使われ、多義的である。節約も1〜2文字しかない。
    # 略語は「綴ると入らない」かつ「一般的である」の両方を満たすものに絞る。
    @{ From = 'volumes';      To = 'vol.' }
    @{ From = 'volume';       To = 'vol.' }
    @{ From = 'consolidated'; To = 'consol.' }
    # reduction -> redn. は外した（2026-08-08）。一般的な略記ではなく、
    # 読み手が復元できない。節約も4文字しかない。

    # --- 語句の置換。規則の Phrase substitutions より。
    @{ From = 'approximately'; To = 'approx.' }
    @{ From = 'including';     To = 'incl.' }
    @{ From = 'excluding';     To = 'excl.' }
    @{ From = 'compared with'; To = 'vs.' }
    @{ From = 'compared to';   To = 'vs.' }
    @{ From = 'versus';        To = 'vs.' }

    # --- 定型の金融用語。綴りが決まっており、他の意味を持たない。
    @{ From = 'foreign exchange';     To = 'FX' }
    @{ From = 'accounts receivable';  To = 'A/R' }
    @{ From = 'accounts payable';     To = 'A/P' }
    @{ From = 'net working capital';  To = 'NWC' }
    @{ From = 'board of directors';   To = 'BOD' }
    @{ From = 'per annum';            To = 'p.a.' }
    @{ From = 'commercial paper';     To = 'CP' }
    # financial institutions -> FIs は外した（2026-08-08）。節約は19文字と
    # 大きいが、複数形の s を付ける略記は一般的ではない。
    # Suppl. は論文の補足資料で見かける形なので残す。
    # この会社は operating income に統一している（英文開示12冊に
    # operating profit は1件も無い）。用語は統一されるものなので、
    # 見るべきは使うか使わないかであって、出現回数ではない。
    # 両方置いておく。どちらで書かれても拾える。
    @{ From = 'operating income';     To = 'OP' }
    @{ From = 'operating profit';     To = 'OP' }
    #
    # net profit -> NP と gross profit -> GP は外した（2026-08-08）。
    # 略語は「綴ると入らないもの」に絞る、という線で揃えるため。
    # net income も gross profit も12文字で、綴っても入る。
    # 略しても理解の助けにならないうえ、NI は英国の社会保険料、
    # GP は General Practitioner とも読める。
    @{ From = 'return on sales';      To = 'ROS' }
    @{ From = 'break-even point';     To = 'BEP' }
    @{ From = 'percentage points';    To = 'pts' }
    # 期の表記（2026-08-08 追加）。決算資料で頻出し、節約が大きく、
    # 曖昧さが無い。月名と違って人名や地名と衝突しない。
    #
    # 冠詞つきを先に当てる。「the first quarter」を「the Q1」にすると
    # 英語として崩れるので、冠詞ごと置き換える。長い順に当てる仕組みが
    # あるので、並べる順ではなく字数で先後が決まる。
    @{ From = 'the first quarter';    To = 'Q1' }
    @{ From = 'the second quarter';   To = 'Q2' }
    @{ From = 'the third quarter';    To = 'Q3' }
    @{ From = 'the fourth quarter';   To = 'Q4' }
    @{ From = 'first quarter';        To = 'Q1' }
    @{ From = 'second quarter';       To = 'Q2' }
    @{ From = 'third quarter';        To = 'Q3' }
    @{ From = 'fourth quarter';       To = 'Q4' }
    @{ From = 'the first half';       To = 'H1' }
    @{ From = 'the second half';      To = 'H2' }
    @{ From = 'first half';           To = 'H1' }
    @{ From = 'second half';          To = 'H2' }
    @{ From = 'year-on-year';         To = 'YoY' }
    @{ From = 'month-on-month';       To = 'MoM' }
    @{ From = 'quarter-on-quarter';   To = 'QoQ' }
    @{ From = 'year-end';             To = 'YE' }
    @{ From = 'wholesale';            To = 'W/S' }
    # semis は外した（2026-08-08）。出番が少ないうえ、準決勝やセミトレーラー
    # とも読める。綴りのままで支障が無い、という利用者の判断による。
    @{ From = 'supplementary materials'; To = 'Suppl.' }

    # --- 社内で決めた形。規則が「必ずこの形を使う」と定めているもの。
    # 長いものから先に当てる必要がある（下の並べ替えで担保する）。
    # 販促費は 変動側 VM / 固定側 Fixed MKT の対で扱う（利用者の指示 2026-08-05）。
    # 固定側を先に当てないと "fixed VM" になる。並べ替えで長い語句が先に来ることに依る。
    @{ From = "subsidiaries' fixed sales promotion costs"; To = 'Subs. Fixed MKT' }
    @{ From = 'fixed sales promotion costs'; To = 'Fixed MKT' }
    @{ From = 'fixed promotion costs';       To = 'Fixed MKT' }
    @{ From = 'sales promotion costs';       To = 'VM' }
    @{ From = 'promotion costs';             To = 'VM' }
    @{ From = 'vehicle variable profit';     To = 'VP (Veh.)' }
    @{ From = 'variable profit';             To = 'VP' }
    @{ From = 'variable costs';              To = 'VC' }
    @{ From = 'variable cost';               To = 'VC' }
    @{ From = 'fixed costs';                 To = 'FC' }
    @{ From = 'fixed cost';                  To = 'FC' }

    # --- 前置詞の短縮。BRIEF の電文体では常に短縮する。
    # ここは最も踏み込んだ置換なので、順番の都合上いちばん最後に当てる
    # （"compared with" などを先に処理させるため）。
    # with は外した（2026-08-08）。英文で最も頻出する語の1つで、機械で当てると
    # 「in line with」「in accordance with」まで壊す。節約も2文字しかない。
    # without は単独で現れる語なので残す。節約は4文字あり、誤読の余地も無い。
    @{ From = 'without'; To = 'w/o' }
)

# 長い語句から先に当てる。"fixed sales promotion costs" を
# "sales promotion costs" より先に処理しないと、途中で食われる。
$script:YakuBriefAbbreviationRules = @(
    @($script:YakuBriefAbbreviationPairs) |
        Sort-Object -Property @{ Expression = { ([string]$_.From).Length }; Descending = $true }, @{ Expression = { [string]$_.From } }
)


function Get-YakuBriefAbbreviationPreferencePath {
    return (Join-Path (Get-YakuDataDir) 'brief-abbreviations.json')
}

function Get-YakuBriefAbbreviationPreferences {
    $defaults = @($script:YakuBriefAbbreviationRules | ForEach-Object { [pscustomobject]@{ from=[string]$_.From; to=[string]$_.To } })
    $result = [pscustomobject]@{ enabled=$false; entries=$defaults }
    try {
        $path = Get-YakuBriefAbbreviationPreferencePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($saved.entries)) {
            $from = ([string]$entry.from).Trim(); $to = ([string]$entry.to).Trim()
            if ($from -and $to) { [void]$entries.Add([pscustomobject]@{ from=$from; to=$to }) }
        }
        return [pscustomobject]@{ enabled=[bool]$saved.enabled; entries=@($entries.ToArray()) }
    } catch {
        try { Write-YakuLog "Brief abbreviation preferences could not be read; disabled. error=$($_.Exception.Message)" 'WARN' } catch {}
        return $result
    }
}

function Save-YakuBriefAbbreviationPreferences {
    param([bool]$Enabled, [AllowEmptyCollection()][object[]]$Entries)
    $validated = New-Object System.Collections.Generic.List[object]
    if (@($Entries).Count -gt 200) { throw 'BRIEF_ABBREVIATION_TOO_MANY: 略語は200件まで登録できます。' }
    foreach ($entry in @($Entries)) {
        $from = ([string]$entry.from).Trim(); $to = ([string]$entry.to).Trim()
        if (-not $from -or -not $to -or $from.Length -gt 80 -or $to.Length -gt 80 -or $from -match "[\r\n]" -or $to -match "[\r\n]") {
            throw 'BRIEF_ABBREVIATION_INVALID: 略語は改行を含まない80文字以内で指定してください。'
        }
        [void]$validated.Add([pscustomobject]@{ from=$from; to=$to })
    }
    $payload = [pscustomobject]@{ enabled=[bool]$Enabled; entries=@($validated.ToArray()) }
    $path = Get-YakuBriefAbbreviationPreferencePath
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    return $payload
}

function Get-YakuEnabledBriefAbbreviationRules {
    $preferences = Get-YakuBriefAbbreviationPreferences
    if (-not [bool]$preferences.enabled) { return @() }
    return @(@($preferences.entries) | ForEach-Object { @{ From=[string]$_.from; To=[string]$_.to } } |
        Sort-Object -Property @{ Expression = { ([string]$_.From).Length }; Descending = $true }, @{ Expression = { [string]$_.From } })
}

function Get-YakuBriefAbbreviationRules {
    # 一覧を見せるためだけの入口。何を機械的に当てているかを確かめられるようにする。
    return @($script:YakuBriefAbbreviationRules)
}

function ConvertTo-YakuBriefCasedReplacement {
    <#
      元の語が大文字で始まっていたら、置換後も大文字で始める。
      「January」→「Jan.」、「january」→「jan.」。
      FX や A/R のように元から大文字のものは、この処理で変化しない。
    #>
    param([string]$Matched, [string]$Replacement)
    if ([string]::IsNullOrEmpty($Matched) -or [string]::IsNullOrEmpty($Replacement)) { return $Replacement }
    $first = $Matched[0]
    if (-not [char]::IsUpper($first)) { return $Replacement }
    return ([string]$Replacement[0]).ToUpperInvariant() + $Replacement.Substring(1)
}

function Convert-YakuBriefAbbreviationSegment {
    # 引用の外側だけを処理する。呼び出し側で切り分けてから渡すこと。
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $result = [string]$Text
    $activeRules = @(Get-YakuEnabledBriefAbbreviationRules)
    if ($activeRules.Count -eq 0) { return $result }
    foreach ($rule in $activeRules) {
        $from = [string]$rule.From
        $to = [string]$rule.To
        # 語境界で囲む。"including" が "excluding" の一部を食わないようにするため。
        # ハイフンを含む語（year-on-year）は \b が末尾で効くので問題ない。
        $pattern = '\b' + [regex]::Escape($from) + '\b'
        $result = [regex]::Replace($result, $pattern, {
            param($m)
            ConvertTo-YakuBriefCasedReplacement -Matched ([string]$m.Value) -Replacement $to
        }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    # 「approximately.」→「approx..」のような二重の終止符を畳む。
    # 三点リーダー（...）は残す。
    $result = [regex]::Replace($result, '(?<=[A-Za-z])\.\.(?!\.)', '.')
    return $result
}

function Convert-YakuBriefAbbreviations {
    <#
      BRIEF の本文へ略語を当てる。

      引用の中は触らない。BRIEF 規則 Q1 は「引用符が残るなら FULL と字句が
      一致すること」を求めており、中を書き換えると規則違反になる。
      対象は二重引用符だけにする。アポストロフィ（company's）まで引用と
      みなすと、本文の大半が触れなくなる。
    #>
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # 括弧で囲んだ部分は Regex.Split の結果にも含まれる。
    # したがって [本文, 引用, 本文, 引用, …] の並びで返る。
    $parts = @([regex]::Split([string]$Text, '("[^"]*"|“[^”]*”)'))
    $sb = New-Object System.Text.StringBuilder
    foreach ($part in $parts) {
        $seg = [string]$part
        if ([string]::IsNullOrEmpty($seg)) { continue }
        $c = $seg[0]
        if ($c -eq [char]'"' -or $c -eq [char]0x201C) {
            [void]$sb.Append($seg)   # 引用はそのまま
            continue
        }
        [void]$sb.Append((Convert-YakuBriefAbbreviationSegment -Text $seg))
    }
    return $sb.ToString()
}

function Convert-YakuBriefTranslationOptions {
    <#
      翻訳結果のうち BRIEF だけへ略語を当てる。

      FULL は spelled-out が正しいので触らない（テンプレートの FULL_TEXT 節）。
      EN→JA には BRIEF が無いので、そもそも対象が現れない。
    #>
    param([AllowNull()][object[]]$Options)
    if ($null -eq $Options) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($opt in @($Options)) {
        if ($null -eq $opt) { continue }
        $style = ''
        try { $style = [string]$opt.Style } catch { $style = '' }
        if ($style -ne 'brief') { [void]$out.Add($opt); continue }
        $before = ''
        try { $before = [string]$opt.Translation } catch { $before = '' }
        $after = Convert-YakuBriefAbbreviations -Text $before
        if ($after -eq $before) { [void]$out.Add($opt); continue }
        $copy = $opt.PSObject.Copy()
        $copy.Translation = $after
        [void]$out.Add($copy)
    }
    return @($out.ToArray())
}
