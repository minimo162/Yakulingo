<#
.SYNOPSIS
  対訳並置ビュー（パレット、V9202）の回帰テスト。

.DESCRIPTION
  見るのは2つ。

  (a) 静的部。palette.js/palette.css が、対訳並置ビューの合図
      （data-yaku-bilingual-view・data-yaku-bilingual-mode・段落分割の
      関数・pre[data-yaku-main-text]を消さずCSSで隠すだけの仕組み）を
      持つこと。既存のDOM契約（data-yaku-main-text・data-yaku-copy-b64・
      data-yaku-swap・data-yaku-term-learn、V9195/V9199/V9200がピン）の
      文字列がそのまま残っていること。

  (b) 実機Chromium部。本物のpalette.html/palette.js/palette.cssを配り、
      3つの題材（原文原文3段落・訳3段落=一致／3vs2=不一致／1段落のみ）を
      実際に貼り付けて確かめる。

        - 一致(3段落): 対訳（原文段落/訳段落の交互リスト）が並ぶこと。
          原文段落の内容が実際の原文と一致すること（空行区切り・空白だけの
          段落・末尾の空行を正しく落とし、署名のような「改行を含むが空行の
          無い1段落」を分割しないこと=正規化の確認）。コピー(1キー・
          コピー釦)は対訳表示中も常に訳文全体のまま。トグルで訳のみ/対訳を
          往復でき、訳のみ表示中もコピーは全文のまま。覚える釦の送信対象も
          全文のまま(段落の1つではない)。添え札スワップで対訳ビューが
          新しい中身へ作り直され、既定(対訳)へ戻る。スワップ後のコピーも
          全文のまま。
        - 不一致(3vs2): 対訳ビューを作らず、現行の単一ブロックのまま。
        - 1段落のみ: 同じく単一ブロックのまま。

      node/Playwright/Chromium が無い環境では UNMEASURED(exit 3)にする
      （「測れなかった」を赤に畳まない、CLAUDE.md）。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9202PaletteBilingual.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$N9202Root = Split-Path -Parent $PSScriptRoot
$N9202Www = Join-Path $N9202Root 'www'
$script:N9202Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9202 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9202Failures.Add($Message) }
}

Write-Host 'Test-YakuV9202PaletteBilingual'

# ============================================================ (a) 静的部
Write-Host '-- static --'

$N9202PaletteJsPath = Join-Path $N9202Www 'assets\palette.js'
$N9202PaletteCssPath = Join-Path $N9202Www 'assets\palette.css'

Assert-N9202 (Test-Path -LiteralPath $N9202PaletteJsPath -PathType Leaf) 'www/assets/palette.js が存在する'
Assert-N9202 (Test-Path -LiteralPath $N9202PaletteCssPath -PathType Leaf) 'www/assets/palette.css が存在する'

if (Test-Path -LiteralPath $N9202PaletteJsPath -PathType Leaf) {
    $N9202Js = [IO.File]::ReadAllText($N9202PaletteJsPath, [Text.UTF8Encoding]::new($false))

    # 対訳並置ビュー本体。
    Assert-N9202 ($N9202Js -match 'function splitBilingualParagraphs') 'palette.js が段落分割の関数を持つ'
    Assert-N9202 ($N9202Js -match "raw\.split\(/\\n\\s\*\\n/\)") 'palette.js の段落分割が仕様どおりの正規表現(空行 \n\s*\n)を使う'
    Assert-N9202 ($N9202Js -match 'function bilingualParagraphsEligible') 'palette.js が段落数の判定(両方2段落以上・数が一致)を持つ'
    Assert-N9202 ($N9202Js -match 'BILINGUAL_MIN_PARAGRAPHS') 'palette.js が最小段落数の定数を持つ'
    Assert-N9202 ($N9202Js -match 'function applyBilingualView') 'palette.js が対訳ビューの適用関数を持つ'
    Assert-N9202 ($N9202Js -match 'function buildBilingualView') 'palette.js が対訳ビューの構築関数を持つ'
    Assert-N9202 ($N9202Js -match 'function setBilingualMode') 'palette.js がモード切替の関数を持つ'
    Assert-N9202 ($N9202Js -match 'function removeBilingualUi') 'palette.js が対訳ビューの後始末(作り直し前の除去)を持つ'
    Assert-N9202 ($N9202Js -match "data-yaku-bilingual-view") 'palette.js が対訳ビューの合図(data-yaku-bilingual-view)を持つ'
    Assert-N9202 ($N9202Js -match "data-yaku-bilingual-mode") 'palette.js がトグル釦の合図(data-yaku-bilingual-mode)を持つ'
    Assert-N9202 ($N9202Js -match "data-yaku-bilingual-controls") 'palette.js がトグル行の合図(data-yaku-bilingual-controls)を持つ'
    Assert-N9202 ($N9202Js -match "is-bilingual-hidden") 'palette.js が主訳pre(data-yaku-main-text)を消さずCSSクラスで隠す仕組みを持つ'
    Assert-N9202 ($N9202Js -match "bilingual-source") 'palette.js が原文段落のクラス(bilingual-source)を持つ'
    Assert-N9202 ($N9202Js -match "bilingual-target") 'palette.js が訳段落のクラス(bilingual-target)を持つ'

    # BLOCKER級: 対訳ビュー本体(applyBilingualView)が pre.textContent を
    # 書き換えていないこと(コピー契約を壊す変更の早期検出、字面での弱い
    # ガード——実効性はChromium部で実測する)。swapAltIntoMainの
    # mainPre.textContent=incoming(既存の入れ替え動作、V9195がピン)は
    # 対象外にする——それ自体は対訳ビューの新規コードではない。
    $N9202ApplyBody = ''
    if ($N9202Js -match "(?s)function applyBilingualView\(mainCard, sourceText\) \{(.*?)\n  \}") { $N9202ApplyBody = $Matches[1] }
    Assert-N9202 (-not [string]::IsNullOrWhiteSpace($N9202ApplyBody)) 'applyBilingualView の本体を取り出せる(前提条件)'
    if (-not [string]::IsNullOrWhiteSpace($N9202ApplyBody)) {
        # トグル釦(bilingualButton/monoButton)自身の文言設定(.textContent=)は
        # 対象外——見るのは変数名 pre の textContent への代入だけ
        # (主訳の中身そのものを書き換えていないか)。
        Assert-N9202 ($N9202ApplyBody -notmatch '\bpre\.textContent\s*=') 'applyBilingualView が主訳pre変数のtextContentへ直接代入しない(見た目だけを差し替える)'
    }

    # 既存のDOM契約(V9195/V9199/V9200がピン)の文字列がそのまま残っていること。
    Assert-N9202 ($N9202Js -match "querySelector\('\[data-yaku-main-text\]'\)") 'palette.js が data-yaku-main-text を引き続き読む(mainCardText)'
    Assert-N9202 ($N9202Js -match "mainCopyBtn\.setAttribute\('data-yaku-copy-b64'") 'palette.js のスワップが引き続き data-yaku-copy-b64 を更新する'
    Assert-N9202 ($N9202Js -match 'swapAltIntoMain') 'palette.js のスワップ配線(swapAltIntoMain)が残っている'
    Assert-N9202 ($N9202Js -match 'data-yaku-term-learn') 'palette.js の学習釦の配線(data-yaku-term-learn)が残っている'
    Assert-N9202 ($N9202Js -match 'function finishJob') 'palette.js の finishJob が残っている'
    Assert-N9202 (@([regex]::Matches($N9202Js, 'revealMainResult\(\);')).Count -ge 3) 'revealMainResult() の呼び出しが既存本数以上残っている(V9200 NEW-2の前提を壊さない)'
}

if (Test-Path -LiteralPath $N9202PaletteCssPath -PathType Leaf) {
    $N9202Css = [IO.File]::ReadAllText($N9202PaletteCssPath, [Text.UTF8Encoding]::new($false))
    Assert-N9202 ($N9202Css -match 'is-bilingual-hidden') 'palette.css が is-bilingual-hidden の見た目(display:none)を定義する'
    Assert-N9202 ($N9202Css -match '\.bilingual-view') 'palette.css が .bilingual-view の見た目を定義する'
    Assert-N9202 ($N9202Css -match '\.bilingual-toggle-option') 'palette.css がトグル釦の見た目を定義する'
    Assert-N9202 ($N9202Css -match '\.bilingual-source') 'palette.css が原文段落の見た目(控えめな色)を定義する'
}

# ============================================================ (b) 実機Chromium部
Write-Host '-- chromium --'

$N9202Unmeasured = 3
$N9202Driver = Join-Path $PSScriptRoot 'palette-screen\palette-bilingual-gate.js'
$N9202Node = Get-Command node -ErrorAction SilentlyContinue
$N9202ChromiumOk = $false
$N9202ChromiumNote = ''
if ($null -eq $N9202Node -or -not (Test-Path -LiteralPath $N9202Driver -PathType Leaf)) {
    $N9202ChromiumNote = 'node またはドライバが見つからない'
} else {
    $N9202NodeExe = [string]$N9202Node.Source
    $N9202ProbeDir = (Split-Path -Parent $N9202Driver).Replace('\', '/')
    $null = & $N9202NodeExe -e ("try{require.resolve('playwright',{paths:['" + $N9202ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
    if ($LASTEXITCODE -ne 0) {
        $N9202ChromiumNote = 'Playwright が見つからない'
    } else {
        $N9202ChromiumPath = & $N9202NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $N9202ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$N9202ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$N9202ChromiumPath) -PathType Leaf)) {
            $N9202ChromiumNote = 'Playwright Chromium が見つからない'
        } else {
            $N9202ChromiumOk = $true
        }
    }
}

$N9202StaticFailed = ($script:N9202Failures.Count -gt 0)

if (-not $N9202ChromiumOk) {
    Write-Host ('UNMEASURED: ' + $N9202ChromiumNote)
    if ($N9202StaticFailed) {
        Write-Host ''
        Write-Host ('FAIL ' + $script:N9202Failures.Count + ' assertion(s) (static part)')
        foreach ($f in $script:N9202Failures) { Write-Host ('  - ' + $f) }
        exit 1
    }
    exit $N9202Unmeasured
}

$N9202Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9202-chromium-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $N9202Work -Force
$N9202OutJson = Join-Path $N9202Work 'out.json'
& $N9202NodeExe $N9202Driver $N9202Www $N9202OutJson
$N9202DriverExit = $LASTEXITCODE
Assert-N9202 ($N9202DriverExit -eq 0 -and (Test-Path -LiteralPath $N9202OutJson -PathType Leaf)) 'Chromiumドライバが完走し、観察結果を書き出した'

if (Test-Path -LiteralPath $N9202OutJson -PathType Leaf) {
    $N9202Observed = Get-Content -LiteralPath $N9202OutJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pageError in @($N9202Observed.errors)) { Write-Host ('  Chromium error: ' + [string]$pageError) }
    foreach ($consoleError in @($N9202Observed.console)) { Write-Host ('  Chromium console: ' + [string]$consoleError) }
    Assert-N9202 (@($N9202Observed.errors).Count -eq 0) '実機ページでJSエラーが出ない'
    Assert-N9202 (@($N9202Observed.console).Count -eq 0) '実機ページでconsole.errorが出ない'

    # 期待値(Node側の定数と同じ値をここでも組み立てる、字面の合成ではなく
    # ドライバが実際に送った/受けた値と突き合わせる)。
    $srcPara1 = 'Thank you for your inquiry.'
    $srcPara2 = 'We will confirm the shipping schedule.'
    $srcPara3 = "Best regards,`nAlice"
    $tgtPara1 = [string][char]0x304A + [char]0x554F + [char]0x3044 + [char]0x5408 + [char]0x308F + [char]0x305B + [char]0x3042 + [char]0x308A + [char]0x304C + [char]0x3068 + [char]0x3046 + [char]0x3054 + [char]0x3056 + [char]0x3044 + [char]0x307E + [char]0x3059 + [char]0x3002
    $tgtPara2 = [string][char]0x51FA + [char]0x8377 + [char]0x4E88 + [char]0x5B9A + [char]0x306F + [char]0x78BA + [char]0x8A8D + [char]0x3044 + [char]0x305F + [char]0x3057 + [char]0x307E + [char]0x3059 + [char]0x3002
    $tgtPara3 = [string][char]0x656C + [char]0x5177 + "`n" + [char]0x30A2 + [char]0x30EA + [char]0x30B9
    $displayMatch = $tgtPara1 + "`n`n" + $tgtPara2 + "`n`n" + $tgtPara3 + "`n`n"
    $altPara1 = [string][char]0x3054 + [char]0x9023 + [char]0x7D61 + [char]0x3044 + [char]0x305F + [char]0x3060 + [char]0x304D + [char]0x3042 + [char]0x308A + [char]0x304C + [char]0x3068 + [char]0x3046 + [char]0x3054 + [char]0x3056 + [char]0x3044 + [char]0x307E + [char]0x3059 + [char]0x3002
    $altPara2 = [string][char]0x767A + [char]0x9001 + [char]0x65E5 + [char]0x7A0B + [char]0x3092 + [char]0x78BA + [char]0x8A8D + [char]0x3057 + [char]0x307E + [char]0x3059 + [char]0x3002
    $altPara3 = [string][char]0x656C + [char]0x5177 + "`n" + 'A'
    $altMatch = $altPara1 + "`n`n" + $altPara2 + "`n`n" + $altPara3
    $mismatchTranslation = ([string][char]0x30A2 + [char]0x30EB + [char]0x30D5 + [char]0x30A1) + ' 1' + ([string][char]0x884C + [char]0x76EE) + [char]0x3002 + "`n`n" + ([string][char]0x30A2 + [char]0x30EB + [char]0x30D5 + [char]0x30A1) + ' 2' + ([string][char]0x884C + [char]0x76EE) + [char]0x3002
    $singleTranslation = [string][char]0x4E00 + [char]0x6BB5 + [char]0x843D + [char]0x3060 + [char]0x3051 + [char]0x3067 + [char]0x3059 + [char]0x3002

    Write-Host '-- match (3 paragraphs) --'
    $m = $N9202Observed.matchSnapshot
    Assert-N9202 ($null -ne $m -and [bool]$m.hasCard) '一致題材: 主札が出る(前提条件)'
    if ($null -ne $m) {
        Assert-N9202 ([bool]$m.hasView) '一致題材: 対訳ビュー(data-yaku-bilingual-view)が作られる'
        Assert-N9202 ($m.viewHidden -eq $false) '一致題材: 対訳ビューは既定で表示される(既定=対訳)'
        Assert-N9202 ([bool]$m.preExists) '一致題材: pre(data-yaku-main-text)は消さずに残る'
        Assert-N9202 ($m.preHidden -eq $true) '一致題材: preは既定でCSSにより隠されている(is-bilingual-hidden)'
        Assert-N9202 ([string]$m.preText -eq $displayMatch) '一致題材: preのtextContentは訳文全体のまま(末尾の空行も含め一切変えない)'
        Assert-N9202 ([int]$m.pairCount -eq 3) '一致題材: 対訳の組が3組(空白だけの段落・末尾の空行を段落として数えない)'
        $srcTexts = @($m.sourceTexts)
        $tgtTexts = @($m.targetTexts)
        Assert-N9202 ($srcTexts.Count -eq 3 -and [string]$srcTexts[0] -eq $srcPara1 -and [string]$srcTexts[1] -eq $srcPara2 -and [string]$srcTexts[2] -eq $srcPara3) '一致題材: 原文段落の中身が実際の原文と一致する(署名の改行も保つ)'
        Assert-N9202 ($tgtTexts.Count -eq 3 -and [string]$tgtTexts[0] -eq $tgtPara1 -and [string]$tgtTexts[1] -eq $tgtPara2 -and [string]$tgtTexts[2] -eq $tgtPara3) '一致題材: 訳段落の中身が実際の訳文と一致する'
        Assert-N9202 ([bool]$m.hasToggle) '一致題材: トグル釦(対訳/訳のみ)が出る'
        Assert-N9202 ([string]$m.bilingualPressed -eq 'true' -and [string]$m.monoPressed -eq 'false') '一致題材: 既定で「対訳」側が押下済み表示'
    }

    $matchOne = @($N9202Observed.copiedAfterDigitOneBilingual)
    Assert-N9202 ($matchOne.Count -ge 1 -and [string]$matchOne[$matchOne.Count - 1] -eq $displayMatch) '一致題材: 対訳表示中の1キーコピーは訳文全体のまま(段落の連結ではない)'

    $matchClick = @($N9202Observed.copiedAfterMainCopyClickBilingual)
    Assert-N9202 ($matchClick.Count -eq 1 -and [string]$matchClick[0] -eq $displayMatch) '一致題材: 対訳表示中のコピー釦クリックも訳文全体のまま'

    $toggleMono = $N9202Observed.snapshotAfterToggleMono
    Assert-N9202 ($null -ne $toggleMono -and $toggleMono.preHidden -eq $false -and $toggleMono.viewHidden -eq $true) 'トグル: 「訳のみ」を押すとpreが見え、対訳ビューが隠れる'
    if ($null -ne $toggleMono) {
        Assert-N9202 ([string]$toggleMono.bilingualPressed -eq 'false' -and [string]$toggleMono.monoPressed -eq 'true') 'トグル: 「訳のみ」側が押下済み表示になる'
    }

    $monoDigit = @($N9202Observed.copiedAfterDigitOneMono)
    Assert-N9202 ($monoDigit.Count -eq 1 -and [string]$monoDigit[0] -eq $displayMatch) '「訳のみ」表示中の1キーコピーも訳文全体のまま'

    $toggleBack = $N9202Observed.snapshotAfterToggleBackToBilingual
    Assert-N9202 ($null -ne $toggleBack -and $toggleBack.preHidden -eq $true -and $toggleBack.viewHidden -eq $false) 'トグル: 「対訳」へ戻すとpreが隠れ、対訳ビューが再び見える'

    # wireLearnButton は送信前に .trim() を掛ける(既存動作、V9200・
    # palette.js変更なし)。対訳表示に関わる差分ではないので、期待値も
    # 同じくtrimして突き合わせる——見るのは「段落の1つに切り詰まって
    # いないか」であって、末尾の空行の扱いではない。
    $learnBody = $N9202Observed.mainLearnRequestBodyBilingual
    Assert-N9202 ($null -ne $learnBody -and [string]$learnBody.target -eq $displayMatch.Trim()) '覚える: 対訳表示中でも送信対象(target)は訳文全体のまま(段落の1つではない)'

    $afterSwap = $N9202Observed.snapshotAfterSwap
    Assert-N9202 ($null -ne $afterSwap -and [bool]$afterSwap.hasView -and $afterSwap.viewHidden -eq $false) 'スワップ後: 対訳ビューが新しい中身で作り直され、既定(対訳)へ戻る'
    if ($null -ne $afterSwap) {
        Assert-N9202 ([string]$afterSwap.preText -eq $altMatch) 'スワップ後: preの中身が添え札の訳文全体に入れ替わる'
        $altTgtTexts = @($afterSwap.targetTexts)
        Assert-N9202 ($altTgtTexts.Count -eq 3 -and [string]$altTgtTexts[0] -eq $altPara1 -and [string]$altTgtTexts[2] -eq $altPara3) 'スワップ後: 対訳ビューの訳段落が入れ替わった訳文を反映する'
        $altSrcTexts = @($afterSwap.sourceTexts)
        Assert-N9202 ($altSrcTexts.Count -eq 3 -and [string]$altSrcTexts[0] -eq $srcPara1) 'スワップ後も原文段落は変わらない(原文は同じジョブ由来のまま)'
    }

    $swapDigit = @($N9202Observed.copiedAfterSwapDigit)
    Assert-N9202 ($swapDigit.Count -eq 1 -and [string]$swapDigit[0] -eq $altMatch) 'スワップ後の1キーコピーも、入れ替わった訳文の全体のまま'

    Write-Host '-- mismatch (3 vs 2) --'
    $mm = $N9202Observed.mismatchSnapshot
    Assert-N9202 ($null -ne $mm -and [bool]$mm.hasCard) '不一致題材: 主札が出る(前提条件)'
    if ($null -ne $mm) {
        Assert-N9202 ($mm.hasView -eq $false) '不一致題材: 対訳ビューを作らない(段落数が揃わない)'
        Assert-N9202 ($mm.preHidden -eq $false) '不一致題材: preは隠されない(現行の単一ブロックのまま)'
        Assert-N9202 ([string]$mm.preText -eq $mismatchTranslation) '不一致題材: preの中身は訳文のまま'
    }
    $mismatchDigit = @($N9202Observed.copiedAfterMismatchDigit)
    Assert-N9202 ($mismatchDigit.Count -eq 1 -and [string]$mismatchDigit[0] -eq $mismatchTranslation) '不一致題材: 1キーコピーは従来どおり訳文全体'

    Write-Host '-- single paragraph --'
    $sg = $N9202Observed.singleSnapshot
    Assert-N9202 ($null -ne $sg -and [bool]$sg.hasCard) '1段落題材: 主札が出る(前提条件)'
    if ($null -ne $sg) {
        Assert-N9202 ($sg.hasView -eq $false) '1段落題材: 対訳ビューを作らない(2段落未満)'
        Assert-N9202 ($sg.preHidden -eq $false) '1段落題材: preは隠されない'
        Assert-N9202 ([string]$sg.preText -eq $singleTranslation) '1段落題材: preの中身は訳文のまま'
    }

    Write-Host '-- geometry --'
    # UX検収基準(仕様): 480x640でもキー案内(帯)は必ず見える(position:sticky)。
    # 主札そのものの全体収まりは、対訳表示では要求しない——対訳表示は原文を
    # カード内へ直接並べるため、別建ての原文欄(#palette-input)を画面内に
    # 保つ意義(原文併記)がその時点で対訳ビュー自身に肩代わりされる
    # (設計判断、成果物の説明に記載)。
    $g480 = $N9202Observed.geometryMatch480
    Assert-N9202 ($null -ne $g480 -and $null -ne $g480.hint) '480x640: キー案内の矩形を測れている(前提条件)'
    if ($null -ne $g480 -and $null -ne $g480.hint) {
        Assert-N9202 ([double]$g480.hint.top -ge 0 -and [double]$g480.hint.bottom -le ([double]$g480.innerHeight + 2)) '480x640: 対訳表示中でもキー案内(.palette-hint)は画面内に見える(帯はposition:sticky)'
    }
    Write-Host ('  info 480x640 main=' + ($g480.main | ConvertTo-Json -Compress) + ' input=' + ($g480.input | ConvertTo-Json -Compress))

    $g1912 = $N9202Observed.geometryMatch1912
    Assert-N9202 ($null -ne $g1912 -and $null -ne $g1912.main) '1912x987: 主札の矩形を測れている(前提条件)'
    if ($null -ne $g1912 -and $null -ne $g1912.main) {
        Assert-N9202 ([double]$g1912.main.top -ge -2) '1912x987: 主札の上端が画面内'
        Assert-N9202 ([double]$g1912.main.bottom -le ([double]$g1912.innerHeight + 2)) '1912x987: 主札の下端が画面内(縦に余裕のある窓では対訳表示でも完全に収まる)'
    }
    $m1912 = $N9202Observed.matchSnapshot1912
    Assert-N9202 ($null -ne $m1912 -and [bool]$m1912.hasView -and $m1912.viewHidden -eq $false) '1912x987: 対訳ビューが表示される'
}

Write-Host ''
if ($script:N9202Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9202PaletteBilingual'
    exit 0
}
Write-Host ('FAIL ' + $script:N9202Failures.Count + ' assertion(s)')
foreach ($f in $script:N9202Failures) { Write-Host ('  - ' + $f) }
exit 1
