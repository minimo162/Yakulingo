<#
.SYNOPSIS
  Verifies the first-run tutorial and desktop preference UX contract.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]
$checks = 0

function Check-YakuTutorial {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures.Add($Message) | Out-Null }
}

function Read-YakuTutorialFile {
    param([string]$RelativePath)
    $path = Join-Path $root $RelativePath
    Check-YakuTutorial (Test-Path -LiteralPath $path -PathType Leaf) "$RelativePath exists"
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($path)
}

$html = Read-YakuTutorialFile 'www\tutorial.html'
$js = Read-YakuTutorialFile 'www\assets\tutorial.js'
$css = Read-YakuTutorialFile 'www\assets\tutorial.css'
# 2026-08-12: 選ばせる開始画面（index.html と home.js）を削除した。使い方と起動設定
# への出口は、着地する翻訳画面に移してある。
$homeHtml = Read-YakuTutorialFile 'www\cat.html'
$commonJs = Read-YakuTutorialFile 'www\assets\common.js'

# 2026-08-12: 4画面の説明をやめ、本物の画面の上で3か所だけ吹き出しを出す形にした
# （Nielsen Norman Group「Onboarding Tutorials vs. Contextual Help」。前置きの説明は
# 読み飛ばされ、作業の成績も上がらない）。ここで見るのは、案内の形が戻っていないこと。
$tourJs = Read-YakuTutorialFile 'www\assets\tour.js'
$catPageForTour = Read-YakuTutorialFile 'www\cat.html'
Check-YakuTutorial (-not ($html -match 'class="tutorial-step"')) 'the page-by-page tutorial must stay removed'
Check-YakuTutorial ($catPageForTour.Contains('name="yaku-tour"') -and $catPageForTour.Contains('/assets/tour.js')) 'the tour runs on the real translate screen'
# 「次へ」で読み進めさせない。実際の操作（入力する・押す）で進む。
# 「次へ」の文字は説明のコメントにも出るので、押せる「次へ」が作られていないかで見る。
# 2026-08-13: 貼り付け欄の段（events: ['input']）を外したので、いまは押す操作だけで進む。
# 守っているのは「読み進めるためのボタンを作らない」ことなので、そちらを見る。
Check-YakuTutorial ($tourJs.Contains("events: ['click']") -and -not ($tourJs -match "textContent = '次へ'") -and -not ($tourJs -match "events: \['(?!click)")) 'the tour advances on real actions, not on a Next button'
Check-YakuTutorial ($tourJs.Contains('案内を閉じる') -and $tourJs.Contains('/api/desktop/tour-complete')) 'the tour can be closed and records only that it finished'
# 2026-08-13: 送ると確認画面へ移るようになったので、案内の続きを出す場所が無くなる。
# 送る段を最後に置き、押した時点で終わりを記録する。記録しないと次の起動でまた出る
# （実機で確認: 2つ目を押した時点でページごと入れ替わり、tour-complete は飛ばなかった）。
$tourStepOrder = @([regex]::Matches($tourJs, "target: '(#[a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value })
Check-YakuTutorial ($tourStepOrder.Count -ge 2 -and $tourStepOrder[$tourStepOrder.Count - 1] -eq '#quick-submit') '送る段は最後に置く（押すと画面が移るため）'
Check-YakuTutorial ($tourStepOrder -contains '#cat-open-file-entry') '資料の入口を指す段がある'
Check-YakuTutorial ($tourJs -match "target: '#cat-open-file-entry'[\s\S]{0,500}?preservePosition: true" -and
    $tourJs.Contains('if (step.preservePosition) { next(); return; }')) '狭い初回画面を資料入口まで勝手にスクロールしない'
Check-YakuTutorial ($tourJs -match "target: '#cat-open-file-entry'[\s\S]{0,700}?nextAtTop: true" -and
    $tourJs.Contains('target.blur();') -and $tourJs.Contains('window.scrollTo(0, 0);')) '資料選択後は入力欄へ戻して次の案内を見せる'
Check-YakuTutorial ($tourJs.Contains("document.getElementById('quick-form')") -and
    $tourJs.Contains('new MutationObserver') -and $tourJs.Contains('mutationObserver.disconnect()')) '入力後に送信ボタンが動いても案内枠が追従する'
Check-YakuTutorial ($tourJs -match "getElementById\('quick-form'\)[\s\S]{0,200}?finish\('done'\)") '送ったら、どの段に居ても終わりを記録する'
# 案内を終えても、ショートカットは作らない（起動設定は別の画面で明示的に押す）。
$desktopIntegration = Read-YakuTutorialFile 'src\DesktopIntegration.ps1'
$tutorialCompletedBody = ''
if ($desktopIntegration -match '(?s)function Set-YakuTutorialCompleted \{(?<body>.*?)\r?\nfunction ') { $tutorialCompletedBody = $Matches['body'] }
Check-YakuTutorial ($tutorialCompletedBody -ne '' -and $tutorialCompletedBody.Contains('Write-YakuTextAtomic') -and -not $tutorialCompletedBody.Contains('Set-YakuDesktopShortcutFile')) 'finishing the tour must not create shortcuts'
# 廃止したデスクトップ版のグローバルホットキーを案内へ戻さない。
Check-YakuTutorial (-not $html.Contains('Ctrl</kbd>＋<kbd>Alt') -and -not $html.Contains('読み込むのは押した時だけ')) 'retired global hotkey must not remain in the tutorial'
# 2026-08-13: ボタン名が「訳して確認する」へ変わり、資料の文も同じ経路で送るように
# なったので、送るものの範囲も書き足した。守るのは「実物の名前で、押すまで送らないと書く」。
Check-YakuTutorial ($html.Contains('「日本語に訳す」「英語に訳す」') -and $html.Contains('「この文章を保存して確認画面へ」')) 'the about page states the explicit-send boundary with the real button names'
Check-YakuTutorial ($html.Contains('ファイルそのものは送りません')) 'the about page says the file itself is not sent'
Check-YakuTutorial (-not ($html -match '文章は自動では読み取りません|貼り付けて「翻訳」を押す')) 'the retired no-reading claim must not come back'
Check-YakuTutorial ($html.Contains('YakuLingoのタブを閉じると終了します') -and $html.Contains('翻訳中だけ、閉じてよいか確認します')) 'tutorial explains the browser-tab exit contract'
$quickClientForTutorial = Read-YakuTutorialFile 'www\assets\quick.js'
# 2026-08-13: ボタンの文言を「訳して確認する」へ変えた（押した先が確認画面に
# なったため）。説明ページが指すボタン名は、実物と一致していなければならない。
Check-YakuTutorial ($quickClientForTutorial.Contains("'日本語に訳す'") -and $quickClientForTutorial.Contains("'英語に訳す'")) 'the tutorial button names still exist in the app'
# ブラウザ版は常駐せず、起動用ショートカットだけを任意で作る。
Check-YakuTutorial (-not $html.Contains('id="startup-enabled"') -and $html.Contains('自動起動しません')) 'background startup must be removed from the UI'
Check-YakuTutorial ($html -match 'id="desktop-shortcut"[^>]*type="checkbox"[^>]*checked') 'desktop shortcut is visibly ON by default'
Check-YakuTutorial ($html.Contains('押すまで、パソコンの設定は変わりません') -and $html.Contains('この設定で始める')) 'final confirmation explains the side-effect boundary'
# 2026-08-12: 押してよいか迷う人がいる、という指摘。迷いの中身は「何が起きるか」
# 「取り消せるか」「チェックを外しても押していいのか」の3つ。押す直前に3つとも書く。
# とくにスタートメニューは、チェックに関係なく必ず作る（DesktopIntegration.ps1 の
# start_menu = $true）。書かないと「外したのに作られた」と見える。
Check-YakuTutorial ($html.Contains('チェックに関係なく作ります') -and $html.Contains('ユーザーフォルダの中')) 'final step states exactly what the button creates, including the always-created start menu entry'
# 「レジストリ」「管理者権限」は、押す人が使う言葉ではない（2026-08-13、利用者の指摘）。
# 言いたいのは「ほかは変えない」ことなので、そのまま日本語で書く。
Check-YakuTutorial ($html.Contains('Windowsへのサインイン時には自動起動しません') -and $html.Contains('あとから開始画面の「使い方と設定」で変えられます')) 'final step states the limits of the change and that it is reversible'
Check-YakuTutorial ($html.Contains('チェックを外したまま押しても')) 'final step says the optional shortcut may stay cleared'
$desktopSrc = Read-YakuTutorialFile 'src\DesktopIntegration.ps1'
# レジストリは「置き場所を読む」だけで、書き込みはしない。書き込む道が入ったら、
# チュートリアルの説明が嘘になるのでここで止める。
Check-YakuTutorial ($desktopSrc -match 'start_menu\s*=\s*\$true') 'the tutorial claim matches the implementation: the start menu shortcut is always created'
Check-YakuTutorial (-not ($desktopSrc -match '(Set|New|Remove)-ItemProperty|reg\.exe|RegistryKey.*SetValue')) 'the tutorial claim matches the implementation: nothing is written to the registry'

Check-YakuTutorial ([regex]::Matches($js, [regex]::Escape("YakuCommon.post('/api/desktop/preferences'")).Count -eq 1) 'desktop preferences have one POST call site'
Check-YakuTutorial ($js.Contains('startup_enabled: false') -and $js.Contains('desktop_shortcut: !!desktopInput.checked')) 'POST permanently disables startup and carries the shortcut choice'
Check-YakuTutorial ($js.Contains("YakuCommon.json('/api/desktop/preferences')")) 'existing preferences are read without changing them'
Check-YakuTutorial ($html.Contains('id="tutorial-replay" class="button secondary-button" href="/cat?tour=1" hidden') -and
    $html.Contains('id="tutorial-home" class="button secondary-button" href="/" hidden') -and
    $js.Contains('replayLink.hidden = firstRun') -and $js.Contains('homeLink.hidden = firstRun')) 'first run exposes one clear action instead of unusable replay and home links'
Check-YakuTutorial ($js.Contains("data.tutorial_completed === false") -and
    $js.Contains("window.location.assign('/cat?tour=1')")) 'first confirmation opens the real translation screen and starts its contextual tour'
Check-YakuTutorial (-not ($js -match 'clipboard|execCommand|localStorage|sessionStorage')) 'tutorial neither reads clipboard nor persists text in browser storage'
Check-YakuTutorial ($js.Contains('data.message') -and $js.Contains('data.warnings') -and $js.Contains('data.available')) 'server response, warnings, and availability are surfaced'

Check-YakuTutorial ($html.Contains('tabindex="-1"') -and $html.Contains('aria-live="polite"')) 'focus and live-region semantics are present'
Check-YakuTutorial ($css.Contains('min-height: 48px') -and $css.Contains('width: 26px') -and $css.Contains('height: 26px')) 'interactive controls remain large enough to target'
Check-YakuTutorial ($css.Contains('@media (max-width: 640px)') -and $css.Contains('@media (prefers-reduced-motion: reduce)')) 'narrow and reduced-motion layouts are defined'
Check-YakuTutorial ($css.Contains('font-size: clamp(2rem') -and $css.Contains('font-size: 1.25rem')) 'headings and instructional text remain readable at high zoom'

# 2026-08-13、利用者の指摘「3つもリンクがあってどれを選べばよいかわからない。
# 一つでよくない？」。行き先の /tutorial が、使い方・送るもの・起動とショートカットを
# 1枚で持っており、案内の再生もその画面から始められる。出口は1つにする。
Check-YakuTutorial ($homeHtml.Contains('>使い方と設定</a>') -and (([regex]::Matches($homeHtml, '<a href="/tutorial')).Count -eq 1) -and -not $homeHtml.Contains('/cat?tour=1')) 'home exposes exactly one way into help and settings'
Check-YakuTutorial ($html.Contains('href="/cat?tour=1"')) 'the tour can still be replayed from that page'
# 既定オフにしたので、「オフです」と知らせる帯は催促にしかならない。外した。
Check-YakuTutorial (-not $homeHtml.Contains('id="background-disabled-banner"')) 'the startup-off nag banner must stay removed'
# 開始画面は状態を変えない。読み取り専用の一覧取得（/api/cat/recent）だけを許し、
# それ以外の POST（とくに起動設定の書き換え）は今までどおり禁止する。
# 開始画面を兼ねる翻訳画面も、起動設定を書き換えない。
$catJs = Read-YakuTutorialFile 'www\assets\cat.js'
Check-YakuTutorial (-not ($catJs -match "post\('/api/desktop/preferences'")) 'the landing translation screen must not touch the startup preference at all'

Check-YakuTutorial (-not ($commonJs -match 'chrome\.webview|notifyDesktopShell|onOfficeSelection')) 'browser client contains no retired WebView2 shell hooks'
$serverSource = Read-YakuTutorialFile 'src\Server.ps1'
$quickClient = Read-YakuTutorialFile 'www\assets\quick.js'
Check-YakuTutorial (-not ($serverSource -match '/api/quick/selection|Selection capture\. trigger=hotkey')) 'server exposes no retired desktop selection API'
Check-YakuTutorial (-not ($quickClient -match 'yaku-clipboard-selection|applyOfficeSelection|reportClipboardCapture')) 'browser client contains no retired global-hotkey path'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source '--check' (Join-Path $root 'www\assets\tutorial.js')
    Check-YakuTutorial ($LASTEXITCODE -eq 0) 'tutorial JavaScript parses with node --check'
} else {
    Write-Host 'SKIP: node is unavailable; JavaScript syntax check not run.' -ForegroundColor Yellow
}

if ($failures.Count -gt 0) {
    Write-Host "Tutorial regression failed: $($failures.Count) / $checks" -ForegroundColor Red
    exit 1
}
Write-Host "Tutorial regression passed: $checks checks" -ForegroundColor Cyan
