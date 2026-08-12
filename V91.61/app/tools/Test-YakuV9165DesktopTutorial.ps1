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
Check-YakuTutorial ($tourJs.Contains("events: ['input']") -and $tourJs.Contains("events: ['click']") -and -not ($tourJs -match "textContent = '次へ'")) 'the tour advances on real actions, not on a Next button'
Check-YakuTutorial ($tourJs.Contains('案内を閉じる') -and $tourJs.Contains('/api/desktop/tour-complete')) 'the tour can be closed and records only that it finished'
# 案内を終えても、ショートカットは作らない（起動設定は別の画面で明示的に押す）。
$desktopIntegration = Read-YakuTutorialFile 'src\DesktopIntegration.ps1'
$tutorialCompletedBody = ''
if ($desktopIntegration -match '(?s)function Set-YakuTutorialCompleted \{(?<body>.*?)\r?\nfunction ') { $tutorialCompletedBody = $Matches['body'] }
Check-YakuTutorial ($tutorialCompletedBody -ne '' -and $tutorialCompletedBody.Contains('Write-YakuTextAtomic') -and -not $tutorialCompletedBody.Contains('Set-YakuDesktopShortcutFile')) 'finishing the tour must not create shortcuts'
# 2026-08-12: Ctrl+Alt+J が Word・Excel・PowerPoint の選択範囲を読み込むようになったので、
# 「文章は自動では読み取りません」は事実と違う。境界は2つに分かれた。
#   読み込む境界: このキーを押したときだけ。見張らない
#   送る境界:     「訳案を作る」を押すまで送らない
# 送信ボタンの名前も「翻訳」から変わっている。実物の名前で書く。
Check-YakuTutorial ($html.Contains('読み込むのは押した時だけ')) 'tutorial states when text is read from the foreground app'
Check-YakuTutorial ($html.Contains('「訳案を作る」を押した文章だけ')) 'the about page states the explicit-send boundary with the real button name'
Check-YakuTutorial (-not ($html -match '文章は自動では読み取りません|貼り付けて「翻訳」を押す')) 'the retired no-reading claim must not come back'
# 2026-08-12（同日追記）: 「Outlook などからは読み込めない」と書いたが、実装は
# Office 以外でも疑似 Ctrl+C を送ってクリップボードから読む（Program.cs の
# CopySelectionFromForeground）。読めないのではなく、読み方が違ってクリップボードが
# 変わる。市販側でいちばん良い説明（PowerToys は「選んだ範囲の画素だけを見る」と
# 具体的に書く）に倣い、2通りの読み方をそのまま書く。
Check-YakuTutorial (-not ($html -match 'ほかのアプリ（Outlookなど）からは読み込めない')) 'the false claim that other apps cannot be read must not come back'
Check-YakuTutorial ($html.Contains('選択範囲をそのまま読みます') -and $html.Contains('コピー（<kbd>Ctrl</kbd>＋<kbd>C</kbd>）を代わりに押すので、クリップボードが置き換わります')) 'tutorial states both reading paths and the clipboard side effect'
$shellSourceForTutorial = Read-YakuTutorialFile 'desktop\Program.cs'
Check-YakuTutorial ($shellSourceForTutorial.Contains('CopySelectionFromForeground') -and $shellSourceForTutorial.Contains('GetClipboardSequenceNumber')) 'the described clipboard path still exists in the shell'
$quickClientForTutorial = Read-YakuTutorialFile 'www\assets\quick.js'
Check-YakuTutorial ($quickClientForTutorial.Contains("'訳案を作る'") -and $quickClientForTutorial.Contains('/api/quick/selection')) 'the tutorial button name and the reading path still exist in the app'
# 2026-08-12: 自動起動を既定オフ（オプトイン）にした。実測で、これが節約するのは
# Copilot の準備 4.3〜15秒。代わりに常駐して 850ms ごとの死活確認を回し続ける
# （Program.cs の backendTimer）。同じ形の道具でも QTranslate は利用者が入れる
# チェックにしている。デスクトップのショートカットは常駐しないので既定オンのまま。
Check-YakuTutorial ($html -match 'id="startup-enabled"[^>]*type="checkbox"(?![^>]*checked)') 'startup must be opt-in (unchecked by default)'
Check-YakuTutorial ($html -match 'id="desktop-shortcut"[^>]*type="checkbox"[^>]*checked') 'desktop shortcut is visibly ON by default'
Check-YakuTutorial ($html.Contains('押すまで、パソコンの設定は変わりません') -and $html.Contains('この設定で始める')) 'final confirmation explains the side-effect boundary'
# 2026-08-12: 押してよいか迷う人がいる、という指摘。迷いの中身は「何が起きるか」
# 「取り消せるか」「チェックを外しても押していいのか」の3つ。押す直前に3つとも書く。
# とくにスタートメニューは、チェックに関係なく必ず作る（DesktopIntegration.ps1 の
# start_menu = $true）。書かないと「外したのに作られた」と見える。
Check-YakuTutorial ($html.Contains('チェックに関係なく必ず作ります') -and $html.Contains('ユーザーフォルダの中')) 'final step states exactly what the button creates, including the always-created start menu entry'
Check-YakuTutorial ($html.Contains('レジストリへの書き込みも、管理者権限も使いません') -and $html.Contains('あとから開始画面の「起動とショートカット」で変えられます')) 'final step states the limits of the change and that it is reversible'
Check-YakuTutorial ($html.Contains('両方のチェックを外したまま押しても')) 'final step says both boxes may be cleared before pressing'
$desktopSrc = Read-YakuTutorialFile 'src\DesktopIntegration.ps1'
# レジストリは「置き場所を読む」だけで、書き込みはしない。書き込む道が入ったら、
# チュートリアルの説明が嘘になるのでここで止める。
Check-YakuTutorial ($desktopSrc -match 'start_menu\s*=\s*\$true') 'the tutorial claim matches the implementation: the start menu shortcut is always created'
Check-YakuTutorial (-not ($desktopSrc -match '(Set|New|Remove)-ItemProperty|reg\.exe|RegistryKey.*SetValue')) 'the tutorial claim matches the implementation: nothing is written to the registry'

Check-YakuTutorial ([regex]::Matches($js, [regex]::Escape("YakuCommon.post('/api/desktop/preferences'")).Count -eq 1) 'desktop preferences have one POST call site'
Check-YakuTutorial ($js.Contains('startup_enabled: !!startupInput.checked') -and $js.Contains('desktop_shortcut: !!desktopInput.checked')) 'POST carries both explicit checkbox values'
Check-YakuTutorial ($js.Contains("YakuCommon.json('/api/desktop/preferences')")) 'existing preferences are read without changing them'
Check-YakuTutorial (-not ($js -match 'clipboard|execCommand|localStorage|sessionStorage')) 'tutorial neither reads clipboard nor persists text in browser storage'
Check-YakuTutorial ($js.Contains('data.message') -and $js.Contains('data.warnings') -and $js.Contains('data.available')) 'server response, warnings, and availability are surfaced'
Check-YakuTutorial ($js.Contains("YakuCommon.notifyDesktopShell('desktop-preferences-changed')") -and
    -not ($js -match 'chrome\.webview\.postMessage')) 'successful tutorial save uses the shared metadata-only shell notifier'

Check-YakuTutorial ($html.Contains('tabindex="-1"') -and $html.Contains('aria-live="polite"')) 'focus and live-region semantics are present'
Check-YakuTutorial ($css.Contains('min-height: 48px') -and $css.Contains('width: 26px') -and $css.Contains('height: 26px')) 'interactive controls remain large enough to target'
Check-YakuTutorial ($css.Contains('@media (max-width: 640px)') -and $css.Contains('@media (prefers-reduced-motion: reduce)')) 'narrow and reduced-motion layouts are defined'
Check-YakuTutorial ($css.Contains('font-size: clamp(2rem') -and $css.Contains('font-size: 1.25rem')) 'headings and instructional text remain readable at high zoom'

Check-YakuTutorial ($homeHtml.Contains('起動とショートカット') -and $homeHtml.Contains('使い方を見る') -and $homeHtml.Contains('/tutorial#settings')) 'home exposes help and direct preference routes'
# 既定オフにしたので、「オフです」と知らせる帯は催促にしかならない。外した。
Check-YakuTutorial (-not $homeHtml.Contains('id="background-disabled-banner"')) 'the startup-off nag banner must stay removed'
# 開始画面は状態を変えない。読み取り専用の一覧取得（/api/cat/recent）だけを許し、
# それ以外の POST（とくに起動設定の書き換え）は今までどおり禁止する。
# 開始画面を兼ねる翻訳画面も、起動設定を書き換えない。
$catJs = Read-YakuTutorialFile 'www\assets\cat.js'
Check-YakuTutorial (-not ($catJs -match "post\('/api/desktop/preferences'")) 'the landing translation screen must not touch the startup preference at all'

Check-YakuTutorial ($commonJs.Contains("data.type !== 'set-startup-enabled'") -and
    $commonJs.Contains("typeof data.enabled !== 'boolean'") -and $commonJs.Contains("keys !== 'enabled,type'")) 'shell handler accepts only the exact startup-toggle message contract'
Check-YakuTutorial ($commonJs.Contains("json('/api/desktop/preferences')") -and
    $commonJs.Contains('desktop_shortcut: current.desktop_shortcut') -and
    $commonJs.Contains('startup_enabled: enabled')) 'shell toggle preserves the current desktop shortcut value'
Check-YakuTutorial ($commonJs.Contains("notifyDesktopShell('desktop-preferences-changed')") -and
    $commonJs.Contains("notifyDesktopShell('desktop-preferences-error')")) 'shell receives metadata-only success or failure events'
Check-YakuTutorial ($commonJs.Contains("type !== 'desktop-preferences-changed' && type !== 'desktop-preferences-error'") -and
    $commonJs.Contains('postMessage({ type: type })')) 'outbound WebMessage is restricted to an allowlisted type with no settings or token'
Check-YakuTutorial ($commonJs.Contains('desktopPreferenceMessageQueue.then')) 'rapid tray changes are serialized in arrival order'

# 取り込みは必ず記録に残す（本文は書かない）。RegisterHotKey はセキュリティの確認で
# キーロガーと同じ入口に見えるため、「押したときだけ読む」をログで示せるようにする。
$serverSourceForCapture = Read-YakuTutorialFile 'src\Server.ps1'
$quickClientForCapture = Read-YakuTutorialFile 'www\assets\quick.js'
$shellForCapture = Read-YakuTutorialFile 'desktop\Program.cs'
Check-YakuTutorial ($serverSourceForCapture.Contains('Selection capture. trigger=hotkey') -and $serverSourceForCapture.Contains('via=office')) 'office captures are logged'
Check-YakuTutorial ($serverSourceForCapture.Contains('/api/quick/selection-capture') -and $serverSourceForCapture.Contains('via=clipboard')) 'clipboard captures are logged too'
Check-YakuTutorial ($quickClientForCapture.Contains('reportClipboardCapture') -and $shellForCapture.Contains('yaku-clipboard-selection')) 'the clipboard path reports its capture'
# 本文はログにも、報告の経路にも載せない。
Check-YakuTutorial ($serverSourceForCapture -match "notin @\('chars'\)") 'the capture report accepts a character count only'

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
