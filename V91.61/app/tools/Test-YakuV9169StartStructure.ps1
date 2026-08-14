<#
.SYNOPSIS
  始める画面（貼り付け欄と資料の入口）と、資料を開いたあとの行き来を固定する。

.DESCRIPTION
  2026-08-13 まで、2つの仕事の繋がりが画面から読めなかった。実測:

    画面      1枚（cat.html）を data-cat-view で start / workspace に切替
    start     その場で訳す と 資料を選ぶ が縦積みで同居
    workspace その場で訳す が消える（quickVisible=false）
    履歴      URL は /cat -> /cat?project=… と変わるのに historyLength は 3 のまま
              （replaceState）。ブラウザの戻るでアプリの外へ出ていた
    出口      ロゴ（全体を読み直す）と、折りたたみの中の「ほかの資料に切り替える」

  同じ日に上部の帯（タブ）を足し、同じ日に外した。外したのは、貼り付けた文章も
  資料と同じ確認作業になり（利用者判断「保存しない約束は要らない」）、
  切り替える相手そのものが無くなったため。帯を押しても同じ入口に着くだけだった。

  いま繋がりを担うのは次の2つ。ここが崩れると 08-13 以前へ戻るので固定する。
    始める画面  貼り付け欄と資料の入口が縦に同居する（どちらも最初から見える）
    作業画面    左上の資料名（F7）から、ほかの資料も新しい貼り付けも始められる
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

Write-Host 'Quick and document work start from one screen' -ForegroundColor Cyan

# 帯は残していない。切り替える相手が無いのに帯だけ残すと、押しても同じ所に着く。
Check-YakuTab ($html -notmatch 'cat-tabs') 'もう帯は無い'
Check-YakuTab ($css -notmatch 'data-cat-tab=' -and $js -notmatch 'function setTab') '帯の名残（CSS・関数）も残っていない'

# いちばん大事な構造: その場で訳す は picker の外に居る
$instantPos = $html.IndexOf('id="cat-instant"')
$pickerPos  = $html.IndexOf('id="cat-picker"')
Check-YakuTab ($instantPos -gt 0 -and $pickerPos -gt 0 -and $instantPos -lt $pickerPos) 'その場で訳す は資料側より前にあり、入れ子になっていない'
# picker の開始タグから終了までの間に cat-instant が現れないこと
$pickerFragment = $html.Substring($pickerPos)
$pickerEnd = $pickerFragment.IndexOf('id="cat-workspace"')
if ($pickerEnd -lt 0) { $pickerEnd = $pickerFragment.Length }
Check-YakuTab (-not $pickerFragment.Substring(0, $pickerEnd).Contains('id="cat-instant"')) '資料側の中にその場で訳すを入れていない'

# 確認作業に入ったら、始めるための入口は出さない。#cat-instant は #cat-picker の
# 外に居るので、picker の hidden では消えない。view で消す。
Check-YakuTab ($css -match 'body\[data-cat-view="workspace"\] #cat-instant \{ display: none; \}') '確認作業のあいだは貼り付け欄を出さない'

# 保存しない訳案は quick-job に出し、保存するときだけ確認作業へ移る。
$serverText = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8
$quickJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\quick.js') -Raw -Encoding UTF8
Check-YakuTab ($html -match '作業や翻訳メモリには残しません' -and $html -match '確認作業として保存する') '保存するかを押す前に書く'
Check-YakuTab ($serverText -match "path -eq '/quick'" -and $serverText -match "path -eq '/cat'") '/quick と /cat は同じサーバの後ろにある'
Check-YakuTab ($quickJs -match '/api/quick/jobs' -and $html -notmatch 'id="quick-result"') '保存しない訳案は専用カード状態を増やさず quick-job に出す'

# 箱を増やさない（2026-08-12 の決定）
Check-YakuTab ($html -notmatch 'id="cat-instant" class="cat-instant translate-form"') 'その場で訳すにカードの器を付けない'
Check-YakuTab ($css -match '(?s)\.cat-picker,\s*\r?\n?\s*\.cat-instant \{') '器の作法は1か所で決める'

# 戻るが効く（資料を開くと履歴が1つ積まれ、戻ると始める画面へ戻る）
Check-YakuTab ($js -match 'history\.pushState') '資料を開いたら履歴に積む'
Check-YakuTab ($js -match "addEventListener\('popstate'") '戻るを受けて始める画面へ戻す'
Check-YakuTab ($js -match '(?s)popstate[\s\S]{0,300}?showPicker\(\)') '戻るでアプリの外へ出さない'

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
# 短文はこの画面、文書は作業画面へ進む。二つを押す前に区別できる見出しを出す。
Check-YakuTab ($html -match 'id="cat-start-title">メールやチャットをすぐ訳す') '短文はこの画面で訳す入口だと分かる'
Check-YakuTab ($html -match 'id="cat-docs-entry-title">1文ずつ確認する作業画面') '保存する文章と文書が同じ確認画面へ進むと分かる'
Check-YakuTab ($html -match '文章またはWord・Excelを開き') '確認画面へ進める二つの材料を押す前に示す'
Check-YakuTab ($html -match '文章を貼り付けると、通常はこの画面に訳文を表示します') '短文は通常なら同じ画面で完結すると示す'
Check-YakuTab ($html -match 'id="cat-picker"[^>]*aria-labelledby="cat-docs-entry-title"') '資料側をその見出しに結び付ける'
Check-YakuTab ($html -match 'id="cat-instant"[^>]*aria-labelledby="cat-start-title"') '貼り付け側も見出しに結び付ける'

Check-YakuTab ($html -match 'id="cat-docs-pane"') '資料の一覧が作業画面の中にある'
Check-YakuTab ($html -match 'id="cat-docs-toggle"') '畳む・出すの操作がある'
Check-YakuTab ($css -match '\.cat-docs-pane \{ display: none; \}') '既定では出さない'
Check-YakuTab ($css -match '\.cat-editor-layout\.is-docs-open \{ grid-template-columns: var\(--pane-docs\)') '開いたときだけ左の列を作る'
Check-YakuTab ($css -match '\.cat-editor-layout\.is-docs-open\.is-inspector-hidden') '左右の開閉4通りを列の指定で表す'
Check-YakuTab ($js -match "event\.key === '\['") 'Crowdin と同じ Ctrl\+\[ で開閉する'
Check-YakuTab ($js -match "localStorage\.setItem\('yaku-cat-docs-open'") '開閉の選択を覚える'
Check-YakuTab ($js -match 'DOCS_PANE_MIN_WIDTH') '既定で開くのは広い窓だけ'
# 窓の大きさは起動後に変わる。外枠が資料翻訳で最大 1760px へ広げられるので、
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

# 高さを窓に固定してよいのは、確認作業の一覧を見ているときだけ。始める画面には
# 貼り付け欄と保存した作業が縦に並ぶので、固定すると下が切れて手が届かなくなる。
# 実測 2026-08-13（窓の高さ 700px）: 帯があった頃、資料を開いたまま貼り付け側へ
# 移ると view は workspace のままで、中身 733px が切れ、下端 705px に届かなかった。
# 帯を外し、確認作業では #cat-instant を出さないので、view だけで判定してよい。
Check-YakuTab ($css -match 'body\.app-cat\[data-cat-view="workspace"\] \{ height: 100dvh') '確認作業のときだけ高さを窓に固定する'
Check-YakuTab ($css -notmatch 'body\.app-cat\[data-cat-view="start"\] \{ height: 100dvh') '始める画面は固定しない'

if ($script:failed -gt 0) { Write-Host ('Start structure tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Start structure tests passed.' -ForegroundColor Green
