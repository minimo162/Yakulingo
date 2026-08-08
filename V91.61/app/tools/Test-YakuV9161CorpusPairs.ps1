<#
.SYNOPSIS
  V91.61: 対訳の対を貯めて日本語でも引ける層の回帰テスト。

.DESCRIPTION
  元々の要求は「日本語で検索して、対応する英文を出したい」だった。
  これまでは英文資料しか検索対象にできず、英語で検索する必要があった。

  ここで見るのは3つ。
   - 同じ対を二度入れないこと（同じ資料を取り込み直しても増えない）
   - 日本語でも英語でも引けること
   - 壊れた行があっても残りが読めること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CorpusPairs.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'CorpusPairs.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-pairs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    # Invoke-YakuDocumentAlignment の出力に合わせた形。
    $pairs = @(
        [pscustomobject]@{ JaText = '当社グループは、2030年までを「電動化の黎明期」と捉えています。'; EnText = 'The Mazda Group views the period until 2030 as the dawn of electrification.'; NumberChecked = $true; NumberAgree = $true }
        [pscustomobject]@{ JaText = '北米では、生産設備等に122億円を投資しました。'; EnText = 'In North America, 12.2 billion yen was invested in production facilities.'; NumberChecked = $true; NumberAgree = $true }
        [pscustomobject]@{ JaText = '当社は電動化を進めます。'; EnText = 'We will advance electrification.'; NumberChecked = $false; NumberAgree = $true }
        [pscustomobject]@{ JaText = ''; EnText = 'orphan line'; NumberChecked = $false; NumberAgree = $true }
    )

    Write-Host '取り込み' -ForegroundColor Cyan
    $r = Add-YakuCorpusPairs -Dir $tmp -Database '有報' -Source '有報/第160期.pdf' -Pairs $pairs -Public
    Chk ($r.Added -eq 3 -and $r.Skipped -eq 1) '片側が空の対は入れない'
    Chk (Test-Path -LiteralPath $r.Path -PathType Leaf) 'JSONL を書き出す'

    $r2 = Add-YakuCorpusPairs -Dir $tmp -Database '有報' -Source '有報/第160期.pdf' -Pairs $pairs -Public
    Chk ($r2.Added -eq 0 -and $r2.Skipped -eq 4) '同じ資料を取り込み直しても増えない'
    Chk (@(Read-YakuCorpusPairs -Dir $tmp -Database '有報').Count -eq 3) '対の数は3のまま'

    Write-Host '検索' -ForegroundColor Cyan
    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化の黎明期')
    Chk ($hits.Count -eq 1 -and $hits[0].En -match 'dawn of electrification') '日本語で引いて英文が出る'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query 'production facilities')
    Chk ($hits.Count -eq 1 -and $hits[0].Ja -match '生産設備') '英語で引いて和文が出る'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化')
    Chk ($hits.Count -eq 2) '複数当たる問い合わせで両方返す'
    Chk ($hits[0].Ja -eq '当社は電動化を進めます。') '短い文に当たったほうを先に出す'

    Write-Host '日本語の原文から往復なしで引く' -ForegroundColor Cyan
    # 検索語を Copilot に作らせると往復が1回増え、120回の制限を早く食う。
    # 対訳は日本語側でも引けるので、原文から手元で語を取り出す。
    $terms = @(Get-YakuJapaneseTerms -Text '当社グループは電動化の黎明期を迎え、生産設備等への投資を進めています。')
    Chk ($terms -contains '電動化') '漢字の連なりを語として取る'
    Chk ($terms -contains '生産設備') '複合名詞をひとまとまりで取る'
    Chk ((@(Get-YakuJapaneseTerms -Text 'これはとてもよいものです')).Count -eq 0) 'ひらがなだけなら語は取れない'
    Chk ((@(Get-YakuJapaneseTerms -Text '2027年3月期 第1四半期')).Count -eq 0) '期の言い方は落とす（どの資料にも出るので手がかりにならない）'
    Chk ((@(Get-YakuJapaneseTerms -Text 'サプライチェーンの混乱')) -contains 'サプライチェーン') 'カタカナ語も取る'
    $long = @(Get-YakuJapaneseTerms -Text '有形固定資産と資産の話')
    Chk ($long.Count -gt 0 -and $long[0].Length -ge $long[-1].Length) '長い語を先に返す'

    $byTerms = @(Find-YakuCorpusPairsByTerms -Dir $tmp -Text '当社は電動化の黎明期に向けた投資を進めます。' -Limit 3)
    Chk ($byTerms.Count -ge 1) '原文の語で対訳が引ける'
    Chk ((@($byTerms[0].Terms)).Count -ge 1) '何の語で当たったかを返す（根拠を画面に出せる）'
    Chk ($byTerms[0].Ja -match '電動化') '当たった対の日本語側に語が含まれる'
    Chk (@($byTerms | Where-Object { $_.Score -le 0 }).Count -eq 0) '当たらなかった対は返さない'
    $none = @(Find-YakuCorpusPairsByTerms -Dir $tmp -Text 'これはとてもよいものです')
    Chk ($none.Count -eq 0) '語が取れなければ空を返す（落ちない）'
    Chk ((@(Find-YakuCorpusPairsByTerms -Dir (Join-Path $tmp 'no-such-dir') -Text '電動化')).Count -eq 0) 'コーパスが無くても落ちない'

    Write-Host '過去の英訳を画面へ出す' -ForegroundColor Cyan
    # 利用者の課題は「過去の翻訳例が見れない」であって「使えない」ではない。
    # プロンプトへ埋めるのは使うことであって、見せることではない。
    . (Join-Path (Join-Path $root 'src') 'Html.ps1')
    $shown = @(Find-YakuCorpusPairsByTerms -Dir $tmp -Text '当社は電動化の黎明期に向けた投資を進めます。' -Limit 3)
    $pastHtml = New-YakuPastTranslationsHtml -Pairs $shown
    Chk ($pastHtml -match '過去に公表した英訳') '見出しが出る'
    Chk ($pastHtml -match 'past-pair-ja' -and $pastHtml -match 'past-pair-en') '日英そろえて出す（英文だけでは確かめようがない）'
    Chk ($pastHtml -match '当たった語') 'なぜこの文が出たのかを添える'
    Chk ($pastHtml -match '<details') '畳んで置く（要らない人の邪魔をしない）'
    Chk ((New-YakuPastTranslationsHtml -Pairs @()) -eq '') '引けなければ何も出さない'
    Chk ((New-YakuPastTranslationsHtml -Pairs $null) -eq '') 'null でも落ちない'
    # 往復を増やさないことが要点。翻訳側が Copilot を呼ばずに引いているか。
    $trSrc = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Translation.ps1') -Raw -Encoding UTF8
    $lookupAt = $trSrc.IndexOf('Find-YakuCorpusPairsByTerms')
    Chk ($lookupAt -ge 0) '翻訳の結果に過去の英訳を載せている'
    $lookupBlock = $trSrc.Substring([Math]::Max(0, $lookupAt - 900), 1400)
    Chk ($lookupBlock -notmatch 'Invoke-YakuCopilotPrompt') '引くのに Copilot を呼ばない（往復を増やさない）'
    Chk ($trSrc -match 'PastPairs') '結果に PastPairs として載る'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化' -VerifiedOnly)
    Chk ($hits.Count -eq 1 -and $hits[0].Ja -match '黎明期') '裏取りの通った対だけに絞れる'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query 'まったく無い語')
    Chk ($hits.Count -eq 0) '当たらなければ空を返す'

    Write-Host '壊れた行' -ForegroundColor Cyan
    $path = Get-YakuCorpusPairsPath -Dir $tmp -Database '有報'
    [IO.File]::AppendAllLines($path, [string[]]@('{壊れた行', ''), [Text.UTF8Encoding]::new($false))
    Chk (@(Read-YakuCorpusPairs -Dir $tmp -Database '有報').Count -eq 3) '壊れた行を捨てて残りを読む'

    Write-Host '資料をまたぐ' -ForegroundColor Cyan
    $null = Add-YakuCorpusPairs -Dir $tmp -Database '決算短信' -Source '短信/FY2025.pdf' -Pairs @(
        [pscustomobject]@{ JaText = '電動化の推進'; EnText = 'Promotion of electrification'; NumberChecked = $false; NumberAgree = $true }
    ) -Public
    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化')
    Chk (@($hits | Select-Object -ExpandProperty Database -Unique).Count -eq 2) '資料をまたいで探す'
    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化' -Databases @('決算短信'))
    Chk ($hits.Count -eq 1 -and $hits[0].Database -eq '決算短信') '資料を絞れる'

    Write-Host 'セグメント向けの検索（候補ペイン）' -ForegroundColor Cyan
    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text '当社は電動化を進めます。')
    Chk ($h.Count -ge 1 -and [bool]$h[0].Exact -and $h[0].Target -eq 'We will advance electrification.') '同じ文を訳していれば完全一致で出す'
    Chk ([Math]::Abs([double]$h[0].Ratio - 1.0) -lt 0.001) '完全一致は一致率1.0'

    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text '当社は電動化を進めます。なお詳細は後述します。')
    Chk ($h.Count -ge 1 -and -not [bool]$h[0].Exact -and [double]$h[0].Ratio -lt 1.0) '過去の文を含む原文には部分一致で出す'

    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text '短い')
    Chk ($h.Count -eq 0) '短すぎる原文では引かない'

    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text 'まったく関係のない文章をここに置きます。')
    Chk ($h.Count -eq 0) '当たらなければ何も出さない'

    $h = @(Find-YakuCorpusPairsForSegment -Dir (Join-Path $tmp 'no-such-dir') -Text '当社は電動化を進めます。')
    Chk ($h.Count -eq 0) 'コーパスが無くても落ちない'

    Write-Host '資料の取り込み' -ForegroundColor Cyan
    . (Join-Path (Join-Path $root 'src') 'AlignMask.ps1')
    . (Join-Path (Join-Path $root 'src') 'Alignment.ps1')
    # Copilot の代役。実機の応答は別に確かめてある。
    function Invoke-YakuCopilotPrompt {
        param([string]$Prompt, $Settings, [string]$AnswerFormat, [switch]$PreserveEndMarker)
        $n = ([regex]::Matches($Prompt, '(?m)^J\d+ ')).Count
        $m = ([regex]::Matches($Prompt, '(?m)^E\d+ ')).Count
        $k = [Math]::Min($n, $m)
        $lines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $k; $i++) { [void]$lines.Add(('[[ID:{0}]] {0}. J{1:d2} | E{1:d2}' -f ($i + 1), $i)) }
        return ($lines -join "`n")
    }
    $jaDoc = "当社は電動化を進めます。`n`n短`n北米に投資しました。`n業績は堅調に推移しました。"
    $enDoc = "We will advance electrification.`n`nx`nWe invested in North America.`nResults remained solid."
    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '統合報告書' -Source '統合報告書/2025.pdf' -JaText $jaDoc -EnText $enDoc -Settings $null -Public
    Chk ($imp.JaLines -eq 3 -and $imp.EnLines -eq 3) '空行と極端に短い行を落とす'
    Chk ($imp.Added -eq 3) '対を貯める'
    Chk ([Math]::Abs([double]$imp.JaCoverage - 1.0) -lt 0.001) '網羅率を返す'

    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '統合報告書' -Source '統合報告書/2025.pdf' -JaText $jaDoc -EnText $enDoc -Settings $null -Public
    Chk ($imp.Added -eq 0 -and $imp.Skipped -eq 3) '同じ資料を取り込み直しても増えない'

    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '統合報告書' -Source 'x.pdf' -JaText '' -EnText $enDoc -Settings $null
    Chk ($imp.Added -eq 0 -and $imp.Calls -eq 0) '片側が空なら Copilot を呼ばない'

    Write-Host '途中で止まっても捨てない' -ForegroundColor Cyan
    # Copilot が一定量で止まる状況を作る。3回答えたあとは必ず失敗させる。
    $script:stopAfter = 3
    function Invoke-YakuCopilotPrompt {
        param([string]$Prompt, $Settings, [string]$AnswerFormat, [switch]$PreserveEndMarker)
        if ($script:stopAfter -le 0) { throw 'Copilotの生成停止は検出しましたが、解析可能な回答を取得できませんでした。' }
        $script:stopAfter--
        $n = ([regex]::Matches($Prompt, '(?m)^J\d+ ')).Count
        $m = ([regex]::Matches($Prompt, '(?m)^E\d+ ')).Count
        $k = [Math]::Min($n, $m)
        $lines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $k; $i++) { [void]$lines.Add(('[[ID:{0}]] {0}. J{1:d2} | E{1:d2}' -f ($i + 1), $i)) }
        return ($lines -join "`n")
    }
    $many = @(0..399 | ForEach-Object { "これは第{0}文です。" -f $_ }) -join "`n"
    $manyEn = @(0..399 | ForEach-Object { "This is sentence number {0}." -f $_ }) -join "`n"
    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '長文' -Source '長文/a.pdf' -JaText $many -EnText $manyEn -Settings $null -Public
    Chk ($imp.Added -gt 0) '途中で止まっても、そこまでの対は貯まる'
    Chk (-not [bool]$imp.Completed -and [int]$imp.ResumeFrom -gt 0) '止まった位置を返す'
    $prog = Join-Path (Join-Path $tmp '長文') 'progress.json'
    Chk (Test-Path -LiteralPath $prog -PathType Leaf) '続きの位置を書き残す'

    # 次に流すと続きから始まる。頭から流し直すと同じ場所で止まって終わらない。
    $script:stopAfter = 3
    $before = @(Read-YakuCorpusPairs -Dir $tmp -Database '長文').Count
    $imp2 = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '長文' -Source '長文/a.pdf' -JaText $many -EnText $manyEn -Settings $null -Public
    Chk ($imp2.Added -gt 0) '2回目は続きの分が増える'
    Chk (@(Read-YakuCorpusPairs -Dir $tmp -Database '長文').Count -gt $before) '対の総数が増える'
    Chk ([int]$imp2.ResumeFrom -gt [int]$imp.ResumeFrom) '続きの位置が前へ進む'

    # 止める仕掛けを解除する。以降は普通に答える代役に戻す。
    $script:stopAfter = 100000

    Write-Host 'CAT の画面から突き合わせる' -ForegroundColor Cyan
    foreach ($mod in @('PromptBuilder.ps1', 'CellSegments.ps1', 'Corpus.ps1', 'CatProject.ps1')) {
        . (Join-Path (Join-Path $root 'src') $mod)
    }
    $proj = New-YakuCatAlignProject -Root $root -SourceText $jaDoc -TargetText $enDoc -Settings $null -Direction 'to_en'
    Chk (@($proj.Segments).Count -eq 3) '対応した数だけ行ができる'
    Chk ([string]@($proj.Segments)[0].Text -eq '当社は電動化を進めます。') '原文側に日本語が入る'
    Chk ([string]@($proj.Segments)[0].Translation -eq 'We will advance electrification.') '訳文側に英語が入る'
    Chk ([string]@($proj.Segments)[0].Origin -eq 'align') '機械が作った対応であることを残す'
    Chk (@($proj.Warnings).Count -eq 0) '網羅できていれば注意は出ない'

    $ng = New-YakuCatAlignProject -Root $root -SourceText '' -TargetText $enDoc -Settings $null
    Chk (@($ng.Segments).Count -eq 0 -and @($ng.Warnings).Count -eq 1) '片方が空なら注意を出して空で返す'

    # 機械が作った対応を、未確認のまま貯めない。
    $unchecked = Save-YakuCatProjectToCorpus -Project $proj -Database '未確認' -Source '未確認の分' -Dir $tmp -Public
    Chk ($unchecked.Added -eq 0) '未確認の機械アライメントはコーパスへ入れない'

    # グリッドで直すか「これでよい」と確定してから貯める、という順序を確かめる。
    $null = Set-YakuCatSegmentTranslation -Project $proj -Index 0 -Text 'We will promote electrification.'
    for ($i = 1; $i -lt @($proj.Segments).Count; $i++) {
        $null = Set-YakuCatSegmentConfirmed -Project $proj -Index $i
    }
    # 保存先は試験用の場所を指す。本番の取り込み場所を汚さない。
    $saved = Save-YakuCatProjectToCorpus -Project $proj -Database '突合' -Source '手で直した分' -Dir $tmp -Public
    Chk ($saved.Added -eq 3) '確かめた対訳をコーパスへ入れる'
    $h = @(Find-YakuCorpusPairs -Dir $tmp -Query 'promote electrification' -Databases @('突合'))
    Chk ($h.Count -eq 1) '直した内容のほうが入る'

    # 文例を作るのは開発者であって、日々の利用者ではない
    # （利用者の整理 2026-08-08）。訳しながら片手間に文例を作らせると、
    # 公表前の資料や作りかけの訳が混ざる。入口は突き合わせに限る。
    $daily = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text '当社は電動化を進めます。' -Translation 'We will advance electrification.'
    $refused = $false
    try { $null = Save-YakuCatProjectToCorpus -Project $daily -Database '突合' -Dir $tmp -Public } catch { $refused = $true }
    Chk $refused '日々の翻訳からは文例を作れない'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 corpus pairs regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 corpus pairs regression passed.' -ForegroundColor Green
