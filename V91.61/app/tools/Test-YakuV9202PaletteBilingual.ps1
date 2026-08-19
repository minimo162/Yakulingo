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

      REWORK-1で追加: トグル釦がsecondary-button/compactを持つこと
      （styles.css:158/159の基色ルールの対象からそもそも外れる、MAJOR-1の
      直し方）。訳文段落がstyles.cssの.translationを流用すること
      （font-size/line-height/max-width/pre-wrapを複製しない、MINOR-2の
      直し方）。palette.cssにpre-lineが残っていないこと。

  (b) 実機Chromium部。本物のpalette.html/palette.js/palette.cssを配り、
      4つの題材（原文3段落・訳3段落=一致／3vs2=不一致／1段落のみ／
      対訳表示中のチップ）を実際に貼り付け・押して確かめる。

        - 一致(3段落): 対訳（原文段落/訳段落の交互リスト）が並ぶこと。
          原文段落の内容が実際の原文と一致すること（空行区切り・空白だけの
          段落・末尾の空行を正しく落とし、署名のような「改行を含むが空行の
          無い1段落」を分割しないこと=正規化の確認）。コピー(1キー・
          コピー釦)は対訳表示中も常に訳文全体のまま。トグルで訳のみ/対訳を
          往復でき、訳のみ表示中もコピーは全文のまま。覚える釦の送信対象も
          全文のまま(段落の1つではない)。添え札スワップで対訳ビューが
          新しい中身へ作り直され、既定(対訳)へ戻る。スワップ後のコピーも
          全文のまま。トグル釦のcomputed style(選択中/未選択×既定/hover、
          計4状態)を実測し、いずれもコントラスト比4.5:1以上であること
          (MAJOR-1)。同じ添え札を計4回クリックしても、対訳ビュー・
          トグル行・preが1つずつのまま重複しないこと(COVERAGE(c)、
          レビューで確認済みの内容を退行として固定する)。
        - 不一致(3vs2): 対訳ビューを作らず、現行の単一ブロックのまま。
        - 1段落のみ: 同じく単一ブロックのまま。
        - 対訳表示中のチップ(丁寧に): チップの完了後、対訳ビューが新しい
          訳文で作り直され(重複せず1つのまま)、原文段落は変わらないこと
          (COVERAGE(b))。

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

# ---- CoD審査 REWORK-1 MAJOR-1: コントラスト比の計算(WCAG 2.x式) ----------
# 判定(4.5:1以上か)はここPowerShell側で行う。観測(Chromiumドライバ)は
# computed styleの文字列を書き出すだけ(既存の流儀「判定はしない」)。
function Get-N9202RgbFromCss {
    param([string]$Css)
    if ([string]::IsNullOrWhiteSpace($Css)) { return $null }
    if ($Css -match 'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(,\s*([0-9.]+)\s*)?\)') {
        $alpha = 1.0
        if ($Matches[5]) { $alpha = [double]$Matches[5] }
        return [pscustomobject]@{ R = [double]$Matches[1]; G = [double]$Matches[2]; B = [double]$Matches[3]; A = $alpha }
    }
    return $null
}
# 透明(alpha=0、.secondary-buttonの既定=quiet)は、実際に画面へ塗られる
# 色ではない。祖先(主札カード)の背景で置き換える——コントラストは
# 「実際に目に映る組み合わせ」で測る。
function Resolve-N9202EffectiveBg {
    param([string]$OwnCss, [string]$FallbackCss)
    $own = Get-N9202RgbFromCss -Css $OwnCss
    if ($null -eq $own -or $own.A -eq 0) { return $FallbackCss }
    return $OwnCss
}
function Get-N9202RelativeLuminance {
    param($Rgb)
    $lin = @()
    foreach ($component in @($Rgb.R, $Rgb.G, $Rgb.B)) {
        $v = $component / 255.0
        if ($v -le 0.03928) { $lin += ($v / 12.92) } else { $lin += ([Math]::Pow((($v + 0.055) / 1.055), 2.4)) }
    }
    return (0.2126 * $lin[0]) + (0.7152 * $lin[1]) + (0.0722 * $lin[2])
}
function Get-N9202ContrastRatio {
    param([string]$FgCss, [string]$BgCss)
    $fg = Get-N9202RgbFromCss -Css $FgCss
    $bg = Get-N9202RgbFromCss -Css $BgCss
    if ($null -eq $fg -or $null -eq $bg) { return 0.0 }
    $l1 = Get-N9202RelativeLuminance -Rgb $fg
    $l2 = Get-N9202RelativeLuminance -Rgb $bg
    $lighter = [Math]::Max($l1, $l2)
    $darker = [Math]::Min($l1, $l2)
    return ($lighter + 0.05) / ($darker + 0.05)
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

    # CoD審査 REWORK-1 MAJOR-1: トグル釦はsecondary-button/compactを持つ
    # (styles.css:158/159の基色ルールの対象からそもそも外れる)。
    Assert-N9202 ($N9202Js -match "'bilingual-toggle-option secondary-button compact'") 'palette.js のトグル釦がsecondary-button/compactを持つ(MAJOR-1、基色ルールの対象から外れる)'
    # CoD審査 REWORK-1 MINOR-2: 訳文段落はstyles.cssの.translationを流用する
    # (font-size/line-height/max-width/pre-wrapを個別に複製しない)。
    Assert-N9202 ($N9202Js -match "'bilingual-target translation'") 'palette.js の訳文段落が.translationクラスを流用する(MINOR-2、preと見た目を複製せず揃える)'

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
    Assert-N9202 ($N9202Css -match '\.bilingual-source') 'palette.css が原文段落の見た目(控えめな色)を定義する'

    # CoD審査 REWORK-1 MAJOR-1: 選択中(aria-pressed=true)の塗りは、祖先クラス
    # (.bilingual-toggle-row)を足したセレクタで詳細度(0,3,0)まで上げてある
    # こと。.secondary-button(0,1,0)・.secondary-button.compact(0,2,0)・
    # .secondary-button:hover(styles.css、0,2,0)のいずれより高く、
    # 読み込み順に頼らず確実に勝つ(CLAUDE.md「CSSの詳細度も自分の道具」)。
    Assert-N9202 ($N9202Css -match '\.bilingual-toggle-row \.bilingual-toggle-option\[aria-pressed="true"\]\s*\{') 'palette.css が選択中トグルの塗りを祖先クラス込みの詳細度(0,3,0)で定義する(MAJOR-1)'
    Assert-N9202 ($N9202Css -match '\.bilingual-toggle-row \.bilingual-toggle-option\[aria-pressed="true"\]:hover') 'palette.css が選択中トグルのhoverも明示する(.secondary-button:hoverへ運任せにしない、MAJOR-1)'

    # CoD審査 REWORK-1 MINOR-2: white-space:pre-line(空白の連続を潰す)の
    # 宣言がpalette.css内に残っていない。原文・訳文どちらもpre-wrapへ
    # 統一した。字面での"pre-line"検索だと、直した理由を書いた説明コメント
    # 自身に当たって誤検出するので、宣言の形(white-space: pre-line)だけを
    # 狙い撃ちする。
    Assert-N9202 ($N9202Css -notmatch 'white-space\s*:\s*pre-line') 'palette.css に white-space:pre-line の宣言が残っていない(MINOR-2、空白の連続を潰さない)'
    Assert-N9202 ($N9202Css -match '\.bilingual-source[^\}]*pre-wrap') 'palette.css が原文段落をpre-wrapにする(MINOR-2)'
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

    # COVERAGE(b)の期待値(チップ、丁寧に)。原文はASCIIなのでそのまま書ける。
    $chipSrcPara1 = 'Please review the proposal.'
    $chipSrcPara2 = 'We look forward to your reply.'
    $chipSrcPara3 = "Regards,`nBob"
    $chipInitPara1 = [string][char]0x3054 + [char]0x63D0 + [char]0x6848 + [char]0x3092 + [char]0x3054 + [char]0x78BA + [char]0x8A8D + [char]0x304F + [char]0x3060 + [char]0x3055 + [char]0x3044 + [char]0x3002
    $chipInitPara2 = [string][char]0x304A + [char]0x8FD4 + [char]0x4E8B + [char]0x3092 + [char]0x304A + [char]0x5F85 + [char]0x3061 + [char]0x3057 + [char]0x3066 + [char]0x3044 + [char]0x307E + [char]0x3059 + [char]0x3002
    $chipInitPara3 = [string][char]0x3088 + [char]0x308D + [char]0x3057 + [char]0x304F + "`n" + [char]0x30DC + [char]0x30D6
    $chipRevPara1 = [string][char]0x3054 + [char]0x63D0 + [char]0x6848 + [char]0x3092 + [char]0x3054 + [char]0x78BA + [char]0x8A8D + [char]0x3044 + [char]0x305F + [char]0x3060 + [char]0x3051 + [char]0x307E + [char]0x3059 + [char]0x3068 + [char]0x5E78 + [char]0x3044 + [char]0x3067 + [char]0x3059 + [char]0x3002
    $chipRevPara2 = [string][char]0x3054 + [char]0x8FD4 + [char]0x4FE1 + [char]0x3092 + [char]0x5FC3 + [char]0x3088 + [char]0x308A + [char]0x304A + [char]0x5F85 + [char]0x3061 + [char]0x7533 + [char]0x3057 + [char]0x4E0A + [char]0x3052 + [char]0x3066 + [char]0x304A + [char]0x308A + [char]0x307E + [char]0x3059 + [char]0x3002
    $chipRevPara3 = [string][char]0x656C + [char]0x5177 + "`n" + [char]0x30DC + [char]0x30D6

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

    Write-Host '-- toggle contrast (MAJOR-1) --'
    # 実際に画面へ塗られる色(未選択の既定=透明の場合は主札カードの背景で
    # 置き換える)で、4状態(選択中/未選択 × 既定/hover)すべてのコントラスト
    # 比を計算する。判定はここでだけ行う(ドライバは観測のみ)。
    $cardBg = [string]$N9202Observed.mainCardBackground
    $selDefault = $N9202Observed.toggleSelectedDefault
    $unselDefault = $N9202Observed.toggleUnselectedDefault
    $selHover = $N9202Observed.toggleSelectedHover
    $unselHover = $N9202Observed.toggleUnselectedHover
    Assert-N9202 ($null -ne $selDefault -and $null -ne $unselDefault -and $null -ne $selHover -and $null -ne $unselHover -and -not [string]::IsNullOrWhiteSpace($cardBg)) 'トグルのcomputed styleを4状態とも読めている(前提条件)'
    if ($null -ne $selDefault -and $null -ne $unselDefault -and $null -ne $selHover -and $null -ne $unselHover) {
        # 「読み違い(選択/未選択が逆)」を具体的な色の一致で直接検出する。
        # 未選択の既定はsecondary-buttonの素のtransparentのまま(quiet)で
        # あるべきで、accentで塗られていてはならない。
        Assert-N9202 ([string]$selDefault.backgroundColor -eq 'rgb(31, 58, 95)') '選択中(既定)の背景がaccent(rgb(31, 58, 95))で塗られている(逆転していない)'
        Assert-N9202 ([string]$selDefault.color -eq 'rgb(255, 255, 255)') '選択中(既定)の文字が白'
        Assert-N9202 ([string]$unselDefault.backgroundColor -eq 'rgba(0, 0, 0, 0)') '未選択(既定)の背景は透明のまま(secondary-buttonの素のquiet、基色ルールに塗られていない)'
        Assert-N9202 ([string]$selHover.backgroundColor -eq 'rgb(22, 44, 72)') '選択中hoverの背景がaccent-hover(rgb(22, 44, 72))'
        Assert-N9202 ([string]$selHover.color -eq 'rgb(255, 255, 255)') '選択中hoverの文字が白のまま(.secondary-button:hoverへ運任せにしていない)'

        $selDefaultBg = Resolve-N9202EffectiveBg -OwnCss $selDefault.backgroundColor -FallbackCss $cardBg
        $unselDefaultBg = Resolve-N9202EffectiveBg -OwnCss $unselDefault.backgroundColor -FallbackCss $cardBg
        $selHoverBg = Resolve-N9202EffectiveBg -OwnCss $selHover.backgroundColor -FallbackCss $cardBg
        $unselHoverBg = Resolve-N9202EffectiveBg -OwnCss $unselHover.backgroundColor -FallbackCss $cardBg

        $ratioSelDefault = Get-N9202ContrastRatio -FgCss $selDefault.color -BgCss $selDefaultBg
        $ratioUnselDefault = Get-N9202ContrastRatio -FgCss $unselDefault.color -BgCss $unselDefaultBg
        $ratioSelHover = Get-N9202ContrastRatio -FgCss $selHover.color -BgCss $selHoverBg
        $ratioUnselHover = Get-N9202ContrastRatio -FgCss $unselHover.color -BgCss $unselHoverBg

        Write-Host ('  info 選択中(既定)   fg=' + $selDefault.color + ' bg=' + $selDefaultBg + ' contrast=' + [Math]::Round($ratioSelDefault, 2) + ':1')
        Write-Host ('  info 未選択(既定)   fg=' + $unselDefault.color + ' bg=' + $unselDefaultBg + '(実効、素は透明) contrast=' + [Math]::Round($ratioUnselDefault, 2) + ':1')
        Write-Host ('  info 選択中(hover)  fg=' + $selHover.color + ' bg=' + $selHoverBg + ' contrast=' + [Math]::Round($ratioSelHover, 2) + ':1')
        Write-Host ('  info 未選択(hover)  fg=' + $unselHover.color + ' bg=' + $unselHoverBg + ' contrast=' + [Math]::Round($ratioUnselHover, 2) + ':1')

        Assert-N9202 ($ratioSelDefault -ge 4.5) ('選択中(既定)のコントラストが4.5:1以上(実測 ' + [Math]::Round($ratioSelDefault, 2) + ':1)')
        Assert-N9202 ($ratioUnselDefault -ge 4.5) ('未選択(既定)のコントラストが4.5:1以上(実測 ' + [Math]::Round($ratioUnselDefault, 2) + ':1)')
        Assert-N9202 ($ratioSelHover -ge 4.5) ('選択中(hover)のコントラストが4.5:1以上(実測 ' + [Math]::Round($ratioSelHover, 2) + ':1、MAJOR-1が実際に踏んだ値=1.25:1)')
        Assert-N9202 ($ratioUnselHover -ge 4.5) ('未選択(hover)のコントラストが4.5:1以上(実測 ' + [Math]::Round($ratioUnselHover, 2) + ':1)')
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

    # CoD審査 REWORK-1 COVERAGE(c): 繰り返しスワップで対訳ビュー・トグル行・
    # preが重複生成されないこと(レビューで確認済みの内容を退行として固定する)。
    # ここまでで既に1回スワップ済み、ドライバがさらに3回押して合計4回にする
    # ——偶数回なので、中身は元(displayMatch)へ戻っているはず。
    $repeatCounts = $N9202Observed.countsAfterRepeatSwap
    Assert-N9202 ($null -ne $repeatCounts) '繰り返しスワップ後の要素数を読めている(前提条件)'
    if ($null -ne $repeatCounts) {
        Assert-N9202 ([int]$repeatCounts.views -eq 1) '繰り返しスワップ(合計4回)後も対訳ビュー(data-yaku-bilingual-view)は1つだけ(重複しない)'
        Assert-N9202 ([int]$repeatCounts.controls -eq 1) '繰り返しスワップ後もトグル行(data-yaku-bilingual-controls)は1つだけ'
        Assert-N9202 ([int]$repeatCounts.pres -eq 1) '繰り返しスワップ後もpre(data-yaku-main-text)は1つだけ'
    }
    Assert-N9202 ([string]$N9202Observed.mainTextAfterRepeatSwap -eq $displayMatch) '繰り返しスワップ(偶数回)後、主訳は元の訳文全体へ戻る'

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

    Write-Host '-- chip while bilingual (COVERAGE(b)) --'
    # チップは finishJob と同じ完了経路(pollJob)を通るので applyBilingualView
    # も走るはず——それを実際に押して確かめる(字面の配線確認ではない)。
    $cb = $N9202Observed.chipBeforeSnapshot
    Assert-N9202 ($null -ne $cb -and [bool]$cb.hasView) 'チップ前: 対訳ビューが出ている(前提条件)'
    if ($null -ne $cb) {
        $cbTgt = @($cb.targetTexts)
        Assert-N9202 ($cbTgt.Count -eq 3 -and [string]$cbTgt[0] -eq $chipInitPara1) 'チップ前: 初回訳の対訳が並んでいる(前提条件)'
    }

    $chipReq = @($N9202Observed.chipRequests)
    Assert-N9202 ($chipReq.Count -eq 1 -and [string]$chipReq[0].chip -eq 'revise') '「丁寧に」チップが1回送られる(chip=revise)'
    if ($chipReq.Count -eq 1) {
        Assert-N9202 ([string]$chipReq[0].source_text -eq ($chipSrcPara1 + "`n`n" + $chipSrcPara2 + "`n`n" + $chipSrcPara3)) 'チップ送信のsource_textは原文のまま'
    }

    $ca = $N9202Observed.chipAfterSnapshot
    Assert-N9202 ($null -ne $ca -and [bool]$ca.hasView -and $ca.viewHidden -eq $false) 'チップ後: 対訳ビューが新しい訳文で作り直され、表示される(既定=対訳)'
    if ($null -ne $ca) {
        $caTgt = @($ca.targetTexts)
        $caSrc = @($ca.sourceTexts)
        Assert-N9202 ($caTgt.Count -eq 3 -and [string]$caTgt[0] -eq $chipRevPara1 -and [string]$caTgt[1] -eq $chipRevPara2 -and [string]$caTgt[2] -eq $chipRevPara3) 'チップ後: 訳段落がチップ後の新しい訳文を反映する'
        Assert-N9202 ($caSrc.Count -eq 3 -and [string]$caSrc[0] -eq $chipSrcPara1 -and [string]$caSrc[2] -eq $chipSrcPara3) 'チップ後: 原文段落は変わらない(チップは原文を変えない)'
    }
    Assert-N9202 ([int]$N9202Observed.viewCountAfterChip -eq 1) 'チップ後も対訳ビューは1つだけ(重複再生成されない、COVERAGE(b))'

    Write-Host '-- geometry --'
    # UX検収基準(仕様): 480x640でもキー案内(帯)は必ず見える(position:sticky、
    # CSSの仕組みそのものが保証するので、対訳表示の有無に関わらず崩れない)。
    #
    # 主札そのものの全体収まりと、原文欄(#palette-input)の可視性は、対訳表示
    # では要求しない。これはV9195の幾何ゲートが緑であることとは無関係
    # ——V9195の題材(palette-gate.js)はどれも1段落の短文で、対訳の判定
    # (両方2段落以上・数が一致)を一度も満たさない。つまりV9195はこの経路を
    # 一度も踏んでおらず、V9195が緑であることはこの設計判断の根拠にならない。
    #
    # 根拠は本題材(一致・3段落)でのこのテスト自身の実測(geometryMatch480、
    # 下のWrite-Hostで毎回の実行時の値をそのまま出す)である: 480x640で
    # 主札はtop=93.1/bottom=552.1(画面内に収まる)なのに、原文欄は
    # top=-330.1/bottom=-242.6(完全に画面外、一部も見えない)。
    # 対訳表示は単一ブロックより縦に伸び、revealMainResult()が主札の下端を
    # 帯(footer)の上へ寄せるぶん、原文欄がそのまま押し出される。
    #
    # これを許容する設計判断(レビューで承認、根拠): 対訳表示は原文を
    # カード内に段落ごと直接並べるため、原文欄を画面内に保つ意義
    # (原文併記、単一ブロック表示のときの唯一の原文確認手段)は、その時点で
    # 対訳ビュー自身に肩代わりされる。キー案内(帯)だけは対訳表示でも
    # 必ず見える必要があるので、そこだけは引き続き要求する(下のAssertで
    # 実測して確かめる)。
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
