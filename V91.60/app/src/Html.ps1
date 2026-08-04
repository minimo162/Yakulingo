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

function Convert-YakuTextResultToHtml {
    param(
        [Parameter(Mandatory=$true)]$Result,
        [bool]$IncludeStatusOob = $true
    )

    if ($Result -and ($Result.PSObject.Properties.Name -contains 'Error') -and $Result.Error) {
        $html = ''
        $html += New-YakuAlertHtml -Kind error -Message $Result.Error
        if ($Result.Prompt) {
            $html += "<details class='prompt-details'><summary>Copilotへ手動送信用のプロンプト</summary><textarea readonly rows='12'>$(ConvertTo-YakuHtml $Result.Prompt)</textarea></details>"
        }
        return $html
    }

    $html = ''

    $inputLength = 0
    try { $inputLength = [int]$Result.InputLength } catch { $inputLength = 0 }
    if ($inputLength -gt 0) { $html += "<div class='batch-note'>ユーザー入力: $(ConvertTo-YakuHtml $inputLength)字</div>" }

    # V91.60 §9: 何件マスクして送ったかを示す。伏せた件数が見えないと、
    # 利用者は「送信されたのか」を推測するしかない。
    $html += New-YakuMaskingNoticeHtml -Result $Result

    $warnings = @()
    try { $warnings = @($Result.Warnings) } catch { $warnings = @() }
    foreach ($warning in $warnings) {
        $message = try { [string]$warning.Message } catch { [string]$warning }
        if (-not [string]::IsNullOrWhiteSpace($message)) { $html += New-YakuAlertHtml -Kind warning -Message $message }
    }

    $glossary = @()
    try { $glossary = @($Result.AppliedGlossary) } catch { $glossary = @() }
    if ($glossary.Count -gt 0) {
        $html += "<section class='glossary-preview' aria-label='適用された用語'><span class='glossary-preview-label'>適用された用語:</span>"
        foreach ($term in ($glossary | Select-Object -First 12)) {
            $from = if ($term.From) { [string]$term.From } else { [string]$term.Source }
            $to = if ($term.To) { [string]$term.To } else { [string]$term.Target }
            $html += "<span class='term-pill'>$(ConvertTo-YakuHtml ($from + ' → ' + $to))</span>"
        }
        if ($glossary.Count -gt 12) { $html += "<span class='term-pill muted-pill'>+$(ConvertTo-YakuHtml ($glossary.Count - 12))</span>" }
        $html += "</section>"
    }

    $batchCount = 0
    try { $batchCount = [int]$Result.BatchCount } catch { $batchCount = 0 }
    if ($batchCount -gt 1) {
        $html += "<div class='batch-note'>長文を $batchCount バッチに分割し、前バッチの訳をSTYLE_REFERENCEとして引き継ぎました。</div>"
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

    foreach ($opt in $options) {
        $title = ConvertTo-YakuHtml $opt.Label
        $translation = ConvertTo-YakuHtml $opt.Translation
        $html += @"
<article class='result-card result-card-translation'>
  <header>
    <div class='eyebrow'>$title</div>
    $(New-YakuCopyButtonHtml -Text ([string]$opt.Translation) -Label 'コピー')
  </header>
  <pre class='translation'>$translation</pre>
</article>
"@
    }

    $html += "</section>"
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

function Get-YakuWarningCategoryLabel {
    param([AllowNull()][string]$Category)
    $cat = [string]$Category
    if ([string]::IsNullOrWhiteSpace($cat)) { return 'その他' }
    switch -Wildcard ($cat) {
        'cell-extract*' { return 'セル抽出スキップ' }
        'shape-extract*' { return '図形抽出スキップ' }
        'shape-list*' { return '図形一覧取得スキップ' }
        'shape-group*' { return '図形グループスキップ' }
        'shape-skip*' { return '図形スキップ' }
        'chart-extract*' { return 'グラフ抽出スキップ' }
        'smartart-skip' { return 'SmartArtスキップ' }
        'batch-count' { return '応答件数不足・過剰' }
        'batch-diagnostic' { return 'バッチ応答診断' }
        'truncated-retry' { return '途中切れリトライ' }
        'split-retry' { return '分割要求リトライ' }
        'supplement-pass' { return '不足ID補完パス' }
        'completion-pass' { return '不足ID補完パス' }
        'needs-supplement' { return '未翻訳検出' }
        'untranslated' { return '原文保持' }
        'untranslated-retained' { return '原文保持' }
        'hangul-retry' { return 'Hangul再翻訳' }
        'glossary-compliance' { return '訳語の確認推奨' }
        'numeric-placeholder-dropped-brief' { return 'BRIEFで省略された数値' }
        'numeric-placeholder-unresolved' { return '数値プレースホルダー不一致' }
        'numeric-mask-integrity' { return '数値プレースホルダー不一致' }
        'writeback-count' { return '書き込み件数不一致' }
        'writeback-rect' { return '矩形書き戻しスキップ' }
        'writeback-sheet' { return 'シート書き戻しスキップ' }
        'writeback*' { return '書き戻しスキップ' }
        'write-back*' { return '書き戻しスキップ' }
        default { return $cat }
    }
}


function Convert-YakuFileWarningsToGroupedHtml {
    param([AllowNull()][object[]]$Warnings)
    $warnings = @($Warnings)
    if ($warnings.Count -le 0) { return '' }
    $groups = [ordered]@{}
    foreach ($w in $warnings) {
        $category = 'general'
        $message = [string]$w
        $location = ''
        try {
            if ($w -and ($w.PSObject.Properties.Name -contains 'Category')) { $category = [string]$w.Category }
            if ($w -and ($w.PSObject.Properties.Name -contains 'Message')) { $message = [string]$w.Message }
            if ($w -and ($w.PSObject.Properties.Name -contains 'Location')) { $location = [string]$w.Location }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($category)) { $category = 'general' }
        if (-not $groups.Contains($category)) { $groups[$category] = New-Object System.Collections.Generic.List[object] }
        $groups[$category].Add([pscustomobject]@{ Message=$message; Location=$location }) | Out-Null
    }
    $kindCount = [int]$groups.Count
    $totalCount = [int]$warnings.Count
    $html = "<details class='file-warning-groups'><summary>警告 $kindCount種 · $totalCount件</summary><div class='warning-group-stack'>"
    foreach ($category in $groups.Keys) {
        $items = @($groups[$category].ToArray())
        $label = Get-YakuWarningCategoryLabel -Category $category
        $html += "<section class='file-warning-group'><h3>$(ConvertTo-YakuHtml $label) <span>$(ConvertTo-YakuHtml $items.Count)件</span></h3><ul>"
        foreach ($item in ($items | Select-Object -First 80)) {
            $line = [string]$item.Message
            if (-not [string]::IsNullOrWhiteSpace([string]$item.Location) -and $line -notmatch [regex]::Escape([string]$item.Location)) {
                $line = ([string]$item.Location) + ' - ' + $line
            }
            $html += '<li>' + (ConvertTo-YakuHtml $line) + '</li>'
        }
        if ($items.Count -gt 80) { $html += '<li>ほか ' + (ConvertTo-YakuHtml ($items.Count - 80)) + ' 件</li>' }
        $html += '</ul></section>'
    }
    $html += '</div></details>'
    return $html
}


function Convert-YakuFileResultToHtml {
    param(
        [Parameter(Mandatory=$true)]$Result,
        [bool]$IncludeStatusOob = $true
    )
    if ($Result -and ($Result.PSObject.Properties.Name -contains 'Error') -and $Result.Error) {
        $html = ''
        $html += New-YakuAlertHtml -Kind error -Message $Result.Error
        return $html
    }

    $html = ''
    $jobId = [string]$Result.JobId
    $stats = $Result.Stats
    $cells = 0; $shapes = 0; $charts = 0; $formula = 0; $smartart = 0
    try { $cells = [int]$stats.cells } catch {}
    try { $shapes = [int]$stats.shapes } catch {}
    try { $charts = [int]$stats.charts } catch {}
    try { $formula = [int]$stats.skipped_formula_cells } catch {}
    try { $smartart = [int]$stats.skipped_smartart } catch {}
    $warnings = @()
    try { $warnings = @($Result.Warnings) } catch { $warnings = @() }
    $glossary = @()
    try { $glossary = @($Result.AppliedGlossary) } catch { $glossary = @() }
    $glossaryExactHits = 0
    try { if ($Result.PSObject.Properties.Name -contains 'GlossaryExactHits') { $glossaryExactHits = [int]$Result.GlossaryExactHits } } catch {}
    $glossaryHtml = ''
    if ($glossary.Count -gt 0) {
        $glossaryHtml += "<section class='glossary-preview' aria-label='適用された用語'><span class='glossary-preview-label'>適用された用語:</span>"
        foreach ($term in ($glossary | Select-Object -First 12)) {
            $from = if ($term.From) { [string]$term.From } else { [string]$term.Source }
            $to = if ($term.To) { [string]$term.To } else { [string]$term.Target }
            $glossaryHtml += "<span class='term-pill'>$(ConvertTo-YakuHtml ($from + ' → ' + $to))</span>"
        }
        if ($glossary.Count -gt 12) { $glossaryHtml += "<span class='term-pill muted-pill'>+$(ConvertTo-YakuHtml ($glossary.Count - 12))</span>" }
        $glossaryHtml += "</section>"
    }

    $maskingHtml = New-YakuMaskingNoticeHtml -Result $Result
    $warningHtml = Convert-YakuFileWarningsToGroupedHtml -Warnings $warnings
    $completionStatus = 'done'
    try { if ($Result.PSObject.Properties.Name -contains 'CompletionStatus') { $completionStatus = [string]$Result.CompletionStatus } } catch {}
    $incomplete = ($completionStatus -eq 'completed_with_warnings')
    $stateAttr = if ($incomplete) { 'completed_with_warnings' } else { 'done' }
    $downloadLabel = if ($incomplete) { '警告付きファイルをダウンロード' } else { 'ダウンロード' }
    $downloadClass = if ($incomplete) { 'button download-button download-warning' } else { 'button download-button' }
    $completionBanner = if ($incomplete) {
        "<div class='alert alert-warning persistent-warning' role='alert'><strong>未翻訳またはスキップされた項目があります。</strong><br>出力名には <code>_INCOMPLETE</code> が付きます。警告一覧を確認してから利用してください。</div>"
    } else { '' }
    $validation = $Result.Validation
    $validationText = ''
    try {
        if ($validation) {
            $validationText = "<span>再オープン $(ConvertTo-YakuHtml $validation.Reopenable)</span><span>数式 $(ConvertTo-YakuHtml $validation.FormulaCount)件</span><span>マクロ保持 $(ConvertTo-YakuHtml $validation.MacroPreserved)</span>"
        }
    } catch { $validationText = '' }
    $retained = 0
    try {
        if ($Result.PSObject.Properties.Name -contains 'BlocksRetainedOriginal') { $retained = [int]$Result.BlocksRetainedOriginal }
        elseif ($Result.PSObject.Properties.Name -contains 'BlocksRetained') { $retained = [int]$Result.BlocksRetained }
        elseif ($Result.PSObject.Properties.Name -contains 'OriginalKept') { $retained = [int]$Result.OriginalKept }
    } catch { $retained = 0 }
    $translated = 0
    try { $translated = [int]$Result.BlocksTranslated } catch { $translated = [int]$Result.BlocksTotal }
    $writeTarget = $translated
    $written = $translated
    try { if ($Result.PSObject.Properties.Name -contains 'BlocksWriteTarget') { $writeTarget = [int]$Result.BlocksWriteTarget } } catch {}
    try { if ($Result.PSObject.Properties.Name -contains 'BlocksWritten') { $written = [int]$Result.BlocksWritten } } catch {}
    $truncated = 0
    $batchTotal = 0
    $truncatedRateText = '0%'
    try { if ($Result.PSObject.Properties.Name -contains 'TruncatedBatches') { $truncated = [int]$Result.TruncatedBatches } } catch {}
    try { if ($Result.PSObject.Properties.Name -contains 'BatchTotal') { $batchTotal = [int]$Result.BatchTotal } elseif ($Result.PSObject.Properties.Name -contains 'BatchCount') { $batchTotal = [int]$Result.BatchCount } } catch {}
    try { if ($batchTotal -gt 0) { $truncatedRateText = ([Math]::Round(($truncated / [double]$batchTotal) * 100, 1)).ToString() + '%' } } catch {}
    $maxRetryDepth = 0
    try { if ($Result.PSObject.Properties.Name -contains 'MaxRetryDepthReached') { $maxRetryDepth = [int]$Result.MaxRetryDepthReached } } catch {}
    $extractSeconds = ''
    try { if ($Result.PSObject.Properties.Name -contains 'ExtractSeconds') { $extractSeconds = [string]$Result.ExtractSeconds } } catch {}
    $applySeconds = ''
    try { if ($Result.PSObject.Properties.Name -contains 'ApplySeconds') { $applySeconds = [string]$Result.ApplySeconds } } catch {}
    $durationDetail = [string]$Result.DurationSeconds + '秒'
    if (-not [string]::IsNullOrWhiteSpace($extractSeconds) -or -not [string]::IsNullOrWhiteSpace($applySeconds)) {
        $durationDetail += ' · 抽出 ' + $(if ([string]::IsNullOrWhiteSpace($extractSeconds)) { '-' } else { $extractSeconds }) + '秒 / 書き戻し ' + $(if ([string]::IsNullOrWhiteSpace($applySeconds)) { '-' } else { $applySeconds }) + '秒'
    }

    $html += @"
<section class='result-stack file-result-stack' data-yaku-state='$(ConvertTo-YakuHtml $stateAttr)'>
  $completionBanner
  <article class='result-card file-result-card'>
    <header class='result-card-header'>
      <div class='result-title-block'>
        <div class='eyebrow'>FILE TRANSLATION</div>
        <h2>$(ConvertTo-YakuHtml $Result.OutputName)</h2>
        <p class='result-subtitle'>$(ConvertTo-YakuHtml $Result.InputName) · $(ConvertTo-YakuHtml $Result.DirectionLabel)</p>
      </div>
      <div class='result-actions'>
        <button type='button' class='$(ConvertTo-YakuHtml $downloadClass)' data-yaku-download-job='$(ConvertTo-YakuHtml $jobId)'>$(ConvertTo-YakuHtml $downloadLabel)</button>
        <button type='button' class='secondary-button open-output-button' data-yaku-job-id='$(ConvertTo-YakuHtml $jobId)'>フォルダを開く</button>
      </div>
    </header>
    <div class='stat-pills' aria-label='翻訳統計'>
      <span class='stat-pill'>対象 <strong>$(ConvertTo-YakuHtml $Result.BlocksTotal)</strong></span>
      <span class='stat-pill'>翻訳 <strong>$translated</strong></span>
      <span class='stat-pill'>書込 <strong>$written/$writeTarget</strong></span>
      <span class='stat-pill'>保持 <strong>$retained</strong></span>
      <span class='stat-pill'>セル <strong>$cells</strong></span>
      <span class='stat-pill'>図形 <strong>$shapes</strong></span>
      <span class='stat-pill'>グラフ <strong>$charts</strong></span>
      <span class='stat-pill'>時間 <strong>$(ConvertTo-YakuHtml $durationDetail)</strong></span>
    </div>
    <div class='file-result-meta'>
      <span>ユニーク $(ConvertTo-YakuHtml $Result.UniqueTextCount)件</span>
      <span>キャッシュ $(ConvertTo-YakuHtml $Result.CacheHits)件</span>
      <span>用語完全一致 $(ConvertTo-YakuHtml $glossaryExactHits)件</span>
      <span>Batch $(ConvertTo-YakuHtml $Result.BatchCount)</span>
      <span>途中切れ $truncated/$batchTotal ($truncatedRateText)</span>
      <span>最大リトライ深さ $maxRetryDepth</span>
      <span>数式セル $formula件</span>
      <span>SmartArt $smartart件</span>
      $validationText
    </div>
    <p class='hint'>元ファイルは変更していません。翻訳を書き込んだセル・図形・グラフタイトルだけに設定フォントを適用します（既定 Arial、CSVは対象外）。原文保持セルには触れません。Excel図形内の部分書式は、Excel COM の制約により先頭ランの書式に均される場合があります。文字溢れの自動調整は行いません。</p>
    <details class='output-path-details'><summary>出力先</summary><code>$(ConvertTo-YakuHtml $Result.OutputPath)</code></details>
    $glossaryHtml
    $maskingHtml
    $warningHtml
  </article>
</section>
"@
    return $html
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
