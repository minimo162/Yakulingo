<#
.SYNOPSIS
  「その場で訳す」と「資料を訳す」を、上の帯で行き来できる状態を固定する。

.DESCRIPTION
  2026-08-13 まで、2つの仕事の繋がりが画面から読めなかった。実測:

    画面      1枚（cat.html）を data-cat-view で start / workspace に切替
    start     その場で訳す と 資料を選ぶ が縦積みで同居
    workspace その場で訳す が消える（quickVisible=false）
    履歴      URL は /cat -> /cat?project=… と変わるのに historyLength は 3 のまま
              （replaceState）。ブラウザの戻るでアプリの外へ出ていた
    出口      ロゴ（全体を読み直す）と、折りたたみの中の「ほかの資料に切り替える」

  上部に常設の帯を置き、資料を開いていても1回で行き来できるようにした。
  資料の作業は開いたまま保持する（読み直さない）ので、戻れば同じ行・同じ位置から続く。

  #cat-instant は #cat-picker の外に出してある。中にあると、資料を開いたときに
  picker ごと隠れて、帯で戻れなくなる。ここが崩れると繋がりが元に戻るので固定する。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuTab {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

$html = Get-Content -LiteralPath (Join-Path $root 'www\cat.html') -Raw -Encoding UTF8
$js   = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat.js') -Raw -Encoding UTF8
$css  = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat-workspace.css') -Raw -Encoding UTF8

Write-Host 'Quick and document work stay one switch apart' -ForegroundColor Cyan

# 帯があること
Check-YakuTab ($html -match 'class="cat-tabs" role="tablist"') '上に帯がある'
Check-YakuTab ($html -match 'data-cat-tab-to="quick"' -and $html -match 'data-cat-tab-to="docs"') '行き先は2つ'
Check-YakuTab ($html -match 'id="cat-tab-docs-count"') '資料側に件数を出す場所がある'

# いちばん大事な構造: その場で訳す は picker の外に居る
$instantPos = $html.IndexOf('id="cat-instant"')
$pickerPos  = $html.IndexOf('id="cat-picker"')
Check-YakuTab ($instantPos -gt 0 -and $pickerPos -gt 0 -and $instantPos -lt $pickerPos) 'その場で訳す は資料側より前にあり、入れ子になっていない'
# picker の開始タグから終了までの間に cat-instant が現れないこと
$pickerFragment = $html.Substring($pickerPos)
$pickerEnd = $pickerFragment.IndexOf('id="cat-workspace"')
if ($pickerEnd -lt 0) { $pickerEnd = $pickerFragment.Length }
Check-YakuTab (-not $pickerFragment.Substring(0, $pickerEnd).Contains('id="cat-instant"')) '資料側の中にその場で訳すを入れていない'

# 帯で出し分ける（picker/workspace の hidden とは別の軸）
Check-YakuTab ($css -match 'body\[data-cat-tab="quick"\] #cat-picker') 'その場で訳す のときは資料側を出さない'
Check-YakuTab ($css -match 'body\[data-cat-tab="quick"\] #cat-workspace') 'その場で訳す のときは作業画面も出さない'
Check-YakuTab ($css -match 'body\[data-cat-tab="docs"\] #cat-instant') '資料のときはその場で訳すを出さない'

# 箱を増やさない（2026-08-12 の決定）
Check-YakuTab ($html -notmatch 'id="cat-instant" class="cat-instant translate-form"') 'その場で訳すにカードの器を付けない'
Check-YakuTab ($css -match '(?s)\.cat-picker,\s*\r?\n?\s*\.cat-instant \{') '器の作法は1か所で決める'

# 戻るが効く
Check-YakuTab ($js -match 'history\.pushState') 'タブの移動を履歴に積む'
Check-YakuTab ($js -match "addEventListener\('popstate'") '戻るを受けてタブを戻す'

# 資料の作業を読み直さない（開いたまま保持）
Check-YakuTab ($js -match 'function setTab') '帯の切替に専用の関数がある'
Check-YakuTab ($js -notmatch '(?s)function setTab[\s\S]{0,900}?(loadProject|resume\(|location\.reload)') 'タブを移るだけでは資料を読み直さない'

# 押しやすさと縦の消費
Check-YakuTab ($css -match 'min-height: 2\.75rem') '帯は押しやすい高さを保つ'
Check-YakuTab ($css -match 'body\[data-cat-view="workspace"\] \.cat-tabs \{ margin-bottom') '作業中は帯の下の余白を詰める'

# 読み上げの作法
Check-YakuTab ($js -match "setAttribute\('aria-selected'") 'どちらが選ばれているかを伝える'
Check-YakuTab ($js -match "event\.key !== 'ArrowLeft'") '矢印でも移れる'
Check-YakuTab ($html -match 'role="tabpanel"') '中身は tabpanel として結び付ける'

# 資料の切り替えは、作業画面に居たまま行う（市販ツールを調べた結果に合わせる）。
#   Crowdin  エディタは全画面。左上のナビゲーションパスと、畳めるファイル一覧（Ctrl+[）
#   memoQ    資料ごとに編集タブ。Project home もタブとして残る
#   Phrase   資料はブラウザの新しいタブで開く（一覧は元のタブに残る）
#   Trados   1つの版面の左側にファイルとフォルダ
# どれも「作業画面を畳んで一覧へ戻ってから選び直す」をさせない。
Check-YakuTab ($html -match 'id="cat-doc-switch"') '左上の資料名が切替口になっている'
Check-YakuTab ($html -match 'id="cat-doc-dialog"') '資料を選ぶ口がある'
Check-YakuTab ($js -match 'function openDocDialog') '作業画面から開く'
Check-YakuTab ($js -match "event\.key === 'F7'") 'キーでも開ける'
Check-YakuTab ($html -match '<kbd>F7</kbd>') 'キーの一覧にも出ている'
# 選んだら、その場で入れ替える（showPicker を経由しない）
Check-YakuTab ($js -match '(?s)data-cat-doc-open[\s\S]{0,400}?resume\(id\)') '選んだ資料へ直接入れ替える'
# 「選んだとき」だけを見る。すぐ隣にある「取り込む」は初期画面へ行くのが正しいので、
# 窓を広く取ると、そちらを拾って誤って赤くなる（実際にそうなった）。
Check-YakuTab ($js -notmatch '(?s)data-cat-doc-open[\s\S]{0,150}?showPicker') '選んだときは一覧画面を経由しない'
# 打ちかけの訳文を失わない
Check-YakuTab ($js -match '(?s)data-cat-doc-open[\s\S]{0,400}?flush\(\)') '切り替える前に保存する'
# 「ほかの資料に切り替える」も同じ口へ寄せる（畳んで戻さない）
Check-YakuTab ($js -match "el\('cat-switch-project'\)[\s\S]{0,200}?openDocDialog") 'そのほかの項目も同じ口を開く'

# 資料の一覧を、作業画面の中に畳める欄として持つ（2026-08-13）。
# 市販ツールで常設の左欄を持つブラウザ型は無く、Crowdin（Ctrl+[）と Trados（最小化/展開）は
# どちらも「畳める」。よって常設にしない。
# 2026-08-12 に左の列を廃止した根拠「1列 321px」は 1380px での測定なので、
# 幅で条件を分ける。実測 2026-08-13:
#   1380px 既定は閉じる（1列 412.6px）。開いても 323.8px で 321px を下回らない
#   1920px 既定で開く（1列 501.7px。1380px で閉じているときの 421px より広い）
# 初回（保存した作業ゼロ）の画面。実機で確認した2点。
# タブが「資料を訳す」と言っているので、同じ語の見出しは置かない。
Check-YakuTab ($html -notmatch 'id="cat-docs-title"') 'タブと同じ語の見出しを重ねない'
Check-YakuTab ($html -match 'id="cat-picker"[^>]*aria-labelledby="cat-tab-docs"') '読み上げにはタブを見出しとして結び付ける'
Check-YakuTab ($css -match '\.cat-picker > \.entry-secondary:first-child') '区切る相手がいない罫線を出さない'

Check-YakuTab ($html -match 'id="cat-docs-pane"') '資料の一覧が作業画面の中にある'
Check-YakuTab ($html -match 'id="cat-docs-toggle"') '畳む・出すの操作がある'
Check-YakuTab ($css -match '\.cat-docs-pane \{ display: none; \}') '既定では出さない'
Check-YakuTab ($css -match '\.cat-editor-layout\.is-docs-open \{ grid-template-columns: var\(--pane-docs\)') '開いたときだけ左の列を作る'
Check-YakuTab ($css -match '\.cat-editor-layout\.is-docs-open\.is-inspector-hidden') '左右の開閉4通りを列の指定で表す'
Check-YakuTab ($js -match "event\.key === '\['") 'Crowdin と同じ Ctrl\+\[ で開閉する'
Check-YakuTab ($js -match "localStorage\.setItem\('yaku-cat-docs-open'") '開閉の選択を覚える'
Check-YakuTab ($js -match 'DOCS_PANE_MIN_WIDTH') '既定で開くのは広い窓だけ'
# 窓の大きさは起動後に変わる。外枠が資料翻訳で 1240px -> 1760px へ広げるので、
# 起動時の1回だけで決めると、広い窓なのに閉じたままになる（実機で発生）。
Check-YakuTab ($js -match "addEventListener\('resize'") '窓の大きさが変わったら決め直す'
Check-YakuTab ($js -match 'function applyDocsPaneDefault') '既定の決め方を1か所に持つ'
# 自動の開閉まで覚えると、一度狭い窓で見ただけで以後ずっと閉じたままになる。
Check-YakuTab ($js -match 'if \(fromUser\) \{ try \{ window\.localStorage\.setItem') '覚えるのは自分で開閉したときだけ'
# 左欄でも同名の資料を見分けられること（時刻）。
Check-YakuTab ($js -match '(?s)cat-docs-pane-meta[\s\S]{0,200}?savedLabel\(item\.saved\)') '左欄にも保存時刻を出す'
Check-YakuTab ($css -match '--pane-docs: clamp\(9rem, 12vw, 15rem\)') '狭い窓で開いても 321px を下回らない幅にする'
# 画面の上限。1920px で 1600px 頭打ちだと 320px が使われないまま余っていた。
Check-YakuTab ($css -match '(?s)@media \(min-width: 1700px\)[^}]*\[data-cat-view="workspace"\] \.shell') '広い画面では確認作業の幅の上限を上げる'
Check-YakuTab ($css -match '(?s)@media \(min-width: 1700px\)[^}]*max-width: 2200px') '上げ幅にも上限は置く'

# 高さを窓に固定してよいのは、確認作業の一覧を実際に見ているときだけ。
# 資料を開いたまま「その場で訳す」タブへ移ると view は workspace のままなので、
# タブを条件に入れないと貼り付け側が断ち切られる。
# 実測 2026-08-13（窓の高さ 700px）: 直す前は body が height:700px/overflow:hidden で
# 中身 733px が切れ、「英訳の金額」の下端 705px に手が届かなかった。
Check-YakuTab ($css -match 'body\.app-cat\[data-cat-view="workspace"\]\[data-cat-tab="docs"\] \{ height: 100dvh') '高さの固定はタブも条件に入れる'
Check-YakuTab ($css -notmatch 'body\.app-cat\[data-cat-view="workspace"\] \{ height: 100dvh') 'view だけで固定する書き方に戻さない'
# overflow を解くだけでは足りない。html と body の高さが窓に固定されたままだと伸びない。
Check-YakuTab ($css -match 'body\.app-cat\[data-cat-tab="quick"\] \{ height: auto; \}') '貼り付け側では高さも解く'

if ($script:failed -gt 0) { Write-Host ('Tab structure tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Tab structure tests passed.' -ForegroundColor Green
