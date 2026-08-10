function ConvertTo-YakuHtml {
    param([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function UrlEncode {
    param([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::UrlEncode([string]$Value)
}

function ConvertTo-YakuUtf8Base64 {
    param([AllowNull()][object]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
    return [Convert]::ToBase64String($bytes)
}

function New-YakuAlertHtml {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Kind = 'info'
    )
    return "<div class='alert alert-$Kind'>$(ConvertTo-YakuHtml $Message)</div>"
}

function ConvertTo-YakuUserFacingError {
    param([AllowNull()][object]$Message)
    $text = [string]$Message
    if ($text -match '(?:EXTERNAL_SEND_|PROTECTION_RECEIPT_|PROTECTED_PROMPT_|CAT_PROTECTED_|SHORTEN_UNMASKED_CURRENT)') {
        return '安全に送る準備を完了できなかったため、送信を中止しました。原文は送信されていません。再起動後も続く場合は管理者へ連絡してください。（YK-PROTECT-01）'
    }
    return $text
}

function New-YakuSpinnerHtml {
    param([string]$Text = '処理中です...')
    return "<div class='spinner-row'><span class='spinner'></span><span>$(ConvertTo-YakuHtml $Text)</span></div>"
}

function New-YakuCopyButtonHtml {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$Label = 'コピー'
    )
    return '<button type="button" class="secondary-button copy-button" data-yaku-copy-b64="' + (ConvertTo-YakuHtml (ConvertTo-YakuUtf8Base64 $Text)) + '">' + (ConvertTo-YakuHtml $Label) + '</button>'
}
function Convert-YakuStatusOobHtml {
    param(
        [string]$Label = 'Done',
        [string]$Class = 'ok'
    )
    return "<div id='copilot-status' class='status' hx-swap-oob='outerHTML' aria-live='polite'><span class='status-dot $Class'></span><span>$(ConvertTo-YakuHtml $Label)</span></div>"
}

function New-YakuPastTranslationsHtml {
    <#
      過去に自社が公表した英訳を、日英そろえて出す。

      利用者の課題は「過去の翻訳例が**見れない**」であって、「使えない」では
      なかった（利用者 2026-08-08）。プロンプトへ埋めるのは使うことであって
      見せることではない。埋めるだけなら、参考にしたと名乗るだけになる。

      引くのは手元で完結する。日本語の原文から語を取り出して対訳の日本語側へ
      当てるので、Copilot への往復は増えない。検索語を Copilot に作らせて
      いた頃は1往復増えていたが、送りすぎると弾かれる以上それは払えない。

      **何の語で当たったかを添える。** 出典だけでは、なぜこの文が出てきたのか
      分からない。おかしいと思ったときに確かめられる形にしておく。

      引けなければ何も出さない。利用者はコーパスの存在を知らないので、
      「見つかりませんでした」と言われても対処のしようがない。
    #>
    param([AllowNull()][object[]]$Pairs)
    $items = @()
    try { $items = @(@($Pairs) | Where-Object { $null -ne $_ }) } catch { $items = @() }
    if ($items.Count -le 0) { return '' }
    $html = "<details class='past-translations'><summary>過去に公表した英訳を見る（$($items.Count)件）</summary>"
    foreach ($p in $items) {
        $source = [string]$p.Source
        $terms = ''
        try { $terms = (@($p.Terms) -join '、') } catch { $terms = '' }
        $head = $source
        if (-not [string]::IsNullOrWhiteSpace($terms)) { $head += '　当たった語: ' + $terms }
        $ja = [string]$p.Ja
        $en = [string]$p.En
        # 長い一節は畳む。読ませたいのは言い回しであって全文ではない。
        if ($ja.Length -gt 160) { $ja = $ja.Substring(0, 160) + '…' }
        if ($en.Length -gt 260) { $en = $en.Substring(0, 260) + '…' }
        $html += @"
  <article class='past-pair'>
    <p class='past-pair-head'>$(ConvertTo-YakuHtml $head)</p>
    <p class='past-pair-ja'>$(ConvertTo-YakuHtml $ja)</p>
    <p class='past-pair-en'>$(ConvertTo-YakuHtml $en)</p>
  </article>
"@
    }
    $html += '</details>'
    return $html
}

function Convert-YakuTextResultToHtml {
    param(
        [Parameter(Mandatory=$true)]$Result,
        [bool]$IncludeStatusOob = $true
    )

    if ($Result -and ($Result.PSObject.Properties.Name -contains 'Error') -and $Result.Error) {
        $html = ''
        $html += New-YakuAlertHtml -Kind error -Message (ConvertTo-YakuUserFacingError $Result.Error)
        if ($Result.Prompt) {
            $html += "<details class='prompt-details'><summary>Copilotへ手動送信用のプロンプト</summary><textarea readonly rows='12'>$(ConvertTo-YakuHtml $Result.Prompt)</textarea></details>"
        }
        return $html
    }

    $html = ''

    # 入力の字数は、翻訳前から入力欄の下に出ている。ここで二度言わない。

    # V91.60 §9: 何件マスクして送ったかを示す。伏せた件数が見えないと、
    # 利用者は「送信されたのか」を推測するしかない。
    $html += New-YakuMaskingNoticeHtml -Result $Result

    $warnings = @()
    try { $warnings = @($Result.Warnings) } catch { $warnings = @() }
    foreach ($warning in $warnings) {
        $message = try { [string]$warning.Message } catch { [string]$warning }
        if (-not [string]::IsNullOrWhiteSpace($message)) { $html += New-YakuAlertHtml -Kind warning -Message $message }
    }

    # 「適用された用語」の表示は廃止した（利用者の指示 2026-08-06）。
    # 実際に適用された保証が無いのに適用されたように読めていた。
    # use_bundled_glossary を切っても出るうえ、プロンプトへ渡しただけの語も並ぶ。

    # どの指示で直した結果かを出す。出さないと、何度か直した後にどれが
    # どの指示の結果か分からなくなる。
    $revisedFrom = ''
    try { $revisedFrom = [string]$Result.RevisedFrom } catch { $revisedFrom = '' }
    if (-not [string]::IsNullOrWhiteSpace($revisedFrom)) {
        $html += "<div class='batch-note'>修正の指示: $(ConvertTo-YakuHtml $revisedFrom)</div>"
    }

    # 参照した社内資料の一覧は簡易翻訳では出さない。コーパスを引くのをやめたため
    # （利用者の判断 2026-08-06）。New-YakuCorpusReferenceHtml は CAT 側で使う。


    $batchCount = 0
    try { $batchCount = [int]$Result.BatchCount } catch { $batchCount = 0 }
    if ($batchCount -gt 1) {
        # 「バッチ」も「STYLE_REFERENCE」も、こちらの都合の言葉である。
        # 利用者が知りたいのは「分けて訳したが、言い回しは揃えてある」だけ。
        $html += "<div class='batch-note'>長い文章なので $batchCount 回に分けて訳しました。前半の言い回しに合わせています。</div>"
    }

    $html += "<section class='result-stack' data-yaku-state='done'>"

    $options = @($Result.Options)
    if ($options.Count -eq 0) {
        $html += New-YakuAlertHtml -Kind warning -Message 'Copilotの回答は取得できましたが、翻訳結果を解析できませんでした。'
        if ($Result.Raw) {
            $rawPreview = [string]$Result.Raw
            if ($rawPreview.Length -gt 4000) { $rawPreview = $rawPreview.Substring(0, 4000) + ' ...' }
            $html += "<details class='prompt-details' open><summary>Copilot回答</summary><pre class='translation'>$(ConvertTo-YakuHtml $rawPreview)</pre></details>"
        }
    }

    # V91.61（2026-08-06）: 訳文ごとに修正の依頼口を付ける。
    # 利用者の使い方は「一文を訳す → 目で見る → 何度か直す → 確定」であり、
    # 直すには原文を書き換えて訳し直すしかなかった。それでは直していない箇所も
    # 毎回変わるので、確定へ向かって収束しない。
    #
    # 原文はここで各札へ持たせる。画面の入力欄から取り直すと、利用者が
    # 入力欄を書き換えた後に「別の原文と現訳」を突き合わせることになる。
    # 現訳はマスク後のものを持たせる。画面の訳文（実値入り）を送り返させると、
    # 伏せたはずの数値が Copilot へ出る。
    $sourceText = ''
    try { $sourceText = [string]$Result.SourceText } catch { $sourceText = '' }
    $direction = ''
    try { $direction = [string]$Result.Direction } catch { $direction = '' }
    $canRevise = (-not [string]::IsNullOrWhiteSpace($sourceText))

    # 答えを1つに絞り、ほかは下に小さく添える。
    #
    # これまでは同じ重さのカードを縦に2枚並べていた。英語が得意でない人に
    # 「どちらを使うか」を読んで判断させることになり、選べない
    # （独立評価 2026-08-08）。主が1つあれば読む場所が決まる。
    #
    # 2つの違いは長さだけにした。金額の書き方は設定で決まるので、
    # ここで選ばせない（利用者の判断 2026-08-08「そんなに頻繁に切り替える
    # 必要もないので、金額の書き方は設定で」）。
    # 主は「そのまま」。短くするのは枠に入らないときだけである。
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($want in @('full', 'brief')) {
        foreach ($o in $options) {
            $s = ''
            try { $s = [string]$o.Style } catch { $s = '' }
            if ($s -eq $want) { [void]$ordered.Add($o) }
        }
    }
    foreach ($o in $options) { if (-not $ordered.Contains($o)) { [void]$ordered.Add($o) } }
    $options = @($ordered.ToArray())
    $optionIndex = 0
    $altHtml = ''

    foreach ($opt in $options) {
        $title = ConvertTo-YakuHtml $opt.Label
        $translation = ConvertTo-YakuHtml $opt.Translation
        $style = ''
        try { $style = [string]$opt.Style } catch { $style = '' }
        if ($style -ne 'brief') { $style = 'full' }
        if ($style -eq 'full') { $title = '標準訳案（Copilot訳・未確認）' }
        $masked = [string]$opt.Translation
        try { if (-not [string]::IsNullOrEmpty([string]$opt.MaskedTranslation)) { $masked = [string]$opt.MaskedTranslation } } catch {}
        # 修正指示のフォームは置かない。「すぐ訳す」は貼って押してコピーする
        # までの画面で、直すのは「見比べて訳す」の役目にする
        # （利用者の方針 2026-08-08「簡易翻訳は簡易翻訳、CAT は CAT で
        # 利用者にとってベストなものにする」）。
        # 直す機能が両方にあると、どちらでやるべきか毎回考えることになる。
        $reviseHtml = ''
        # 数値が抜けた訳は、短い訳ではなく事実が欠けた訳である。
        # コピーボタンの隣に静かに置くと、そのまま貼られる。
        $dropNotice = ''
        try {
            if ([bool]$opt.NumbersDropped) {
                $dropNotice = "<p class='result-danger'>この訳には数値が入っていません（" + (ConvertTo-YakuHtml ([string]$opt.DroppedNumbers)) + "）。使わずに、もう一方をお使いください。</p>"
            }
        } catch {}
        # 1つ目を主にし、2つ目以降は下に小さく添える。押すと入れ替わる。
        $isMain = ($optionIndex -eq 0)
        $optionIndex++
        $chars = ([string]$opt.Translation).Length
        $b64 = ConvertTo-YakuUtf8Base64 ([string]$opt.Translation)
        if ($isMain) {
            $html += @"
<article class='result-card result-card-translation' data-yaku-main-card>
$dropNotice  <pre class='translation' data-yaku-main-text>$translation</pre>
  <div class='result-actions'>
    <span class='result-kind' data-yaku-main-kind>$title</span>
    $(New-YakuCopyButtonHtml -Text ([string]$opt.Translation) -Label 'コピー')
  </div>
</article>
"@
            $altHtml += ""
        }
        else {
            # 添え物にも中身を出す。押す前にどう違うかが見えないと選べない。
            $preview = [string]$opt.Translation
            if ($preview.Length -gt 90) { $preview = $preview.Substring(0, 90) + '…' }
            $altHtml += @"
  <button type='button' class='result-alt' data-yaku-swap='$b64' data-yaku-swap-kind='$(ConvertTo-YakuHtml $opt.Label)'>
    <span class='result-alt-head'>$title<span class='result-alt-chars'>$chars 字</span></span>
    <span class='result-alt-body'>$(ConvertTo-YakuHtml $preview)</span>
  </button>
"@
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($altHtml)) {
        $html += @"
<div class='result-alts'>
  <p class='result-alts-lead'>枠に入らないときは、こちらを押すと上と入れ替わります。</p>
  <div class='result-alts-list'>
$altHtml  </div>
</div>
"@
    }

    # 旧HTML結果は表示互換だけに限定する。過去例、短縮、CATへの引継ぎは
    # DOM属性へ本文を複製せず、専用Quick/CAT画面とserver artifactで扱う。

    $html += "</section>"
    return $html
}



function New-YakuCorpusReferenceHtml {
    <#
      V91.61 段階3: 何を参照して訳したかを出す。

      出典が見えないと、訳語がどこから来たのか確かめようがない。
      用語集の pill 行と同じ形にして、行を増やさない。

      **引けなかったときは何も出さない。** 利用者はコーパスの存在を知らないため、
      「参照できませんでした」と言われても対処のしようがない。
      理由は記録にだけ残す（Corpus reference skipped. reason=...）。

      本文は伏せ字を掛けた後のものを出す。送ったものと違うものを見せない。
    #>
    param([Parameter(Mandatory=$true)]$Result)
    $examples = @()
    # 項目そのものが無い結果（エラー時・古い履歴）も来る。
    # @($null) は要素1つの配列になるので、null を落としてから数える。
    try { $examples = @(@($Result.CorpusExamples) | Where-Object { $null -ne $_ }) } catch { $examples = @() }
    if ($examples.Count -le 0) { return '' }
    $html = "<section class='glossary-preview' aria-label='参照した社内資料'><span class='glossary-preview-label'>参照した社内資料:</span>"
    foreach ($ex in $examples) {
        $label = [string]$ex.Source
        $page = 0
        try { $page = [int]$ex.Page } catch { $page = 0 }
        if ($page -gt 0) { $label += ' p.' + [string]$page }
        $html += "<span class='term-pill'>$(ConvertTo-YakuHtml $label)</span>"
    }
    $html += "</section>"
    # 中身も確かめられるようにする。既定は閉じておき、普段は視界に入れない。
    $detail = ''
    foreach ($ex in $examples) {
        $head = [string]$ex.Source
        $page = 0
        try { $page = [int]$ex.Page } catch { $page = 0 }
        if ($page -gt 0) { $head += ' p.' + [string]$page }
        $detail += "<div class='eyebrow'>$(ConvertTo-YakuHtml $head)</div><pre class='translation'>$(ConvertTo-YakuHtml ([string]$ex.Text))</pre>"
    }
    $terms = @()
    try { $terms = @(@($Result.CorpusTerms) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) } catch { $terms = @() }
    $termNote = if ($terms.Count -gt 0) { '検索語: ' + ($terms -join ' ') } else { '' }
    $html += "<details class='prompt-details'><summary>参照した箇所を見る</summary>"
    if ($termNote) { $html += "<div class='batch-note'>$(ConvertTo-YakuHtml $termNote)</div>" }
    $html += "<div class='batch-note'>数字は # に伏せて送っています。</div>$detail</details>"
    return $html
}

function New-YakuMaskingNoticeHtml {
    <#
      V91.60 §9: 「数値 12 件をマスクして送信しました」を出す。
      件数のみを扱う。対応表(Map)は画面の警告文以外へ出さない(§8)。
    #>
    param([AllowNull()]$Result)
    $masked = 0
    $kept = 0
    try { $masked = [int]$Result.MaskedCount } catch { $masked = 0 }
    try { $kept = [int]$Result.KeptCount } catch { $kept = 0 }
    if ($masked -le 0) { return '' }
    $suffix = if ($kept -gt 0) { "（年度・用語集の語など $kept 件はそのまま送信）" } else { '' }
    return "<div class='batch-note masking-note'>数値 $masked 件をマスクして送信しました。符号と単位は送信しています。$suffix</div>"
}

function Convert-YakuCopilotDiagnosticsToHtml {
    param([Parameter(Mandatory=$true)]$Diag)
    $kind = if ($Diag.InputReady) { 'success' } elseif ($Diag.LoginDetected -or $Diag.DevToolsReachable) { 'warning' } else { 'info' }
    $lastLogHtml = ''
    if ($Diag.LastLog) {
        $lastLogHtml = "<details class='prompt-details'><summary>直近ログ</summary><pre class='explanation'>$(ConvertTo-YakuHtml $Diag.LastLog)</pre></details>"
    }
    $html = New-YakuAlertHtml -Kind $kind -Message ([string]$Diag.Message)
    $html += @"
<table class='diag-table'>
  <tr><th>CDPポート</th><td>$(ConvertTo-YakuHtml $Diag.Port)</td></tr>
  <tr><th>Edge DevTools</th><td>$(ConvertTo-YakuHtml $Diag.DevToolsReachable)</td></tr>
  <tr><th>Browser</th><td>$(ConvertTo-YakuHtml $Diag.Browser)</td></tr>
  <tr><th>URL</th><td>$(ConvertTo-YakuHtml $Diag.PageUrl)</td></tr>
  <tr><th>Title</th><td>$(ConvertTo-YakuHtml $Diag.Title)</td></tr>
  <tr><th>ログイン画面</th><td>$(ConvertTo-YakuHtml $Diag.LoginDetected)</td></tr>
  <tr><th>入力欄検出</th><td>$(ConvertTo-YakuHtml $Diag.InputReady)</td></tr>
  <tr><th>入力欄Selector</th><td><code>$(ConvertTo-YakuHtml $Diag.InputSelector)</code></td></tr>
  <tr><th>送信ボタン検出</th><td>$(ConvertTo-YakuHtml $Diag.SendButtonReady)</td></tr>
  <tr><th>送信ボタンLabel</th><td><code>$(ConvertTo-YakuHtml $Diag.SendButtonLabel)</code></td></tr>
  <tr><th>Response数</th><td>$(ConvertTo-YakuHtml $Diag.ResponseCount)</td></tr>
  <tr><th>通常ログ</th><td><code>$(ConvertTo-YakuHtml $Diag.LogPath)</code></td></tr>
  <tr><th>入力診断ログ</th><td><code>$(ConvertTo-YakuHtml $Diag.LatestInputDiagnosticLog)</code></td></tr>
  <tr><th>送信診断ログ</th><td><code>$(ConvertTo-YakuHtml $Diag.LatestSendDiagnosticLog)</code></td></tr>
</table>
$lastLogHtml
"@
    return $html
}

function Convert-YakuCopilotInputDiagnosticToHtml {
    param([Parameter(Mandatory=$true)]$Result)
    $kind = if ($Result.Ok) { 'success' } else { 'error' }
    $html = New-YakuAlertHtml -Kind $kind -Message ([string]$Result.Message)
    $tail = ''
    if ($Result.LogPath) {
        try {
            if (Test-Path -LiteralPath ([string]$Result.LogPath) -PathType Leaf) {
                $tail = (Get-Content -LiteralPath ([string]$Result.LogPath) -Encoding UTF8 -Tail 8) -join "`n"
            }
        } catch {}
    }
    $tailHtml = ''
    if ($tail) {
        $tailHtml = "<details class='prompt-details'><summary>ログ末尾</summary><pre class='explanation'>$(ConvertTo-YakuHtml $tail)</pre></details>"
    }
    $html += @"
<table class='diag-table'>
  <tr><th>開始</th><td>$(ConvertTo-YakuHtml $Result.Started)</td></tr>
  <tr><th>終了</th><td>$(ConvertTo-YakuHtml $Result.Finished)</td></tr>
  <tr><th>結果</th><td>$(ConvertTo-YakuHtml $Result.Ok)</td></tr>
  <tr><th>理由</th><td><code>$(ConvertTo-YakuHtml $Result.Reason)</code></td></tr>
  <tr><th>ログファイル</th><td><code>$(ConvertTo-YakuHtml $Result.LogPath)</code></td></tr>
  <tr><th>送信プロンプト</th><td><code>$(ConvertTo-YakuHtml $Result.PromptPath)</code></td></tr>
  <tr><th>実際の入力</th><td><code>$(ConvertTo-YakuHtml $Result.ActualInputPath)</code></td></tr>
</table>
$tailHtml
<details class='prompt-details'>
  <summary>詳細</summary>
  <pre class='explanation'>$(ConvertTo-YakuHtml $Result.Detail)</pre>
</details>
"@
    return $html
}

function Convert-YakuCopilotSelfTestToHtml {
    param([Parameter(Mandatory=$true)]$Result)
    $kind = if ($Result.Ok) { 'success' } else { 'error' }
    $html = New-YakuAlertHtml -Kind $kind -Message ([string]$Result.Message)
    $html += @"
<table class='diag-table'>
  <tr><th>開始</th><td>$(ConvertTo-YakuHtml $Result.Started)</td></tr>
  <tr><th>終了</th><td>$(ConvertTo-YakuHtml $Result.Finished)</td></tr>
  <tr><th>結果</th><td>$(ConvertTo-YakuHtml $Result.Ok)</td></tr>
</table>
<details class='prompt-details' open>
  <summary>Copilot応答</summary>
  <pre class='translation'>$(ConvertTo-YakuHtml $Result.Response)</pre>
</details>
"@
    return $html
}
