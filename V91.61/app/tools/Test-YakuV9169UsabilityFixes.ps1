<#
.SYNOPSIS
  実機で使って見つけた4件を固定する。

.DESCRIPTION
  2026-08-13、実機（1380x900）で一通り使って測った結果を直したもの。

  1. 金額の注記が、金額の無い訳にも出ていた
     実測: 数字ゼロの文を訳しても「金額は ¥1,315 billion のように書いています」。
     すぐ下の伏せ字の要約は maskCount で隠しているので、同じ作法に揃える。
  2. 保存した作業が同名で並び、見分けられなかった
     実測:「spec.docx・英語に訳す作業・あと258行」が2件、時刻表示なし。
     時刻は saved でサーバから既に届いていた（06:11:45 と 06:10:00）。出すだけ。
  3. 押せない理由が tooltip にしか無かった
     実測: 画面上の理由テキスト0件、無効ボタンはフォーカス不可、
     「確認済みの行だけコピー」は title すら空。
     理由の帯は 2026-08-12 に意図して畳んだので、戻さない。読み上げ用の
     sr-only の行へ書いて、場所を取らずに理由を残す。
  4. Ctrl+Enter が使う場所から遠かった
     実測: 一覧は実在するが「そのほか」→「キーボード操作」の2段の折りたたみの中
     （clicksToReveal=2）。書き足すのではなく、いちばん押すボタンのそばへ置く。

  取り下げたもの: 「表示中の0行をまとめて確認済みにする」が押せる、と最初に報告したが
  誤りだった。hidden=true で画面に出ていない（私の測定が可視性を見ていなかった）。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuUse {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

$quickJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\quick.js') -Raw -Encoding UTF8
$catJs   = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat.js') -Raw -Encoding UTF8
$catCss  = Get-Content -LiteralPath (Join-Path $root 'www\assets\cat-workspace.css') -Raw -Encoding UTF8
$catHtml = Get-Content -LiteralPath (Join-Path $root 'www\cat.html') -Raw -Encoding UTF8

Write-Host 'Findings from using the app on the real screen stay fixed' -ForegroundColor Cyan

# 1. 金額の注記は、金額があったときだけ
Check-YakuUse ($quickJs -match 'function hasAmount') '金額があったかを見る関数がある'
Check-YakuUse ($quickJs -match 'showNotation\s*=\s*toEnglish\s*&&\s*hasAmount\(') '注記は英訳かつ金額ありのときだけ'
Check-YakuUse ($quickJs -notmatch "hidden\s*=\s*!toEnglish;") '英訳だけを条件にしていない'
Check-YakuUse ($quickJs -match 'billion\|million\|trillion\|oku') '訳文の金額の書き方を見る'
# 原文はこの画面が持ち回らない（Quick の試験が固定している不変条件）。
# 最初 source_text を見に行って、その試験に止められた。判定は訳文だけで足りる。
Check-YakuUse ($quickJs -notmatch 'source_text') '原文には触らない'

# 2. 保存した作業に、いつのものかを出す
Check-YakuUse ($catJs -match 'function savedLabel') '保存時刻を読む関数がある'
Check-YakuUse ($catJs -match 'savedLabel\(item\.saved\)') 'サーバから来る saved を使う'
Check-YakuUse ($catJs -match 'cat-resume-time') '時刻を行に出す'
Check-YakuUse ($catCss -match '\.cat-resume-time') '時刻の見た目は弱い字で添える'
Check-YakuUse ($catJs -match '今日 ' -and $catJs -match '昨日 ') '今日・昨日は日付ではなく言葉で出す'

# 3. 押せない理由を、tooltip の外にも残す
Check-YakuUse ($catJs -match 'function reviewedGuidance') '「確認済みの行だけコピー」に理由がある'
Check-YakuUse ($catJs -match "el\('cat-export-reviewed'\)\.title = reviewedGuidance\(\)") '理由をボタンにも付ける'
Check-YakuUse ($catHtml -match 'id="cat-output-reason"[^>]*class="sr-only"') '読み上げ用の行があり、場所を取らない'
Check-YakuUse ($catJs -match "el\('cat-output-reason'\)\.textContent") '押せない理由をその行へ書く'
# 畳んだ帯は戻さない（2026-08-12 の決定）
Check-YakuUse ($catJs -match "el\('cat-export-blocked'\)\.textContent = '';") '理由の帯は畳んだまま'

# 4. Ctrl+Enter を、いちばん押すボタンのそばに置く
Check-YakuUse ($catJs -match 'data-cat-confirm="' + "' \+ index \+ '" + '" title="確認して次の行へ（Ctrl\+Enter）"') '確認ボタンがキーの名前を持つ'
Check-YakuUse ($catJs -match 'aria-keyshortcuts="Control\+Enter"') '読み上げにもキーを伝える'
Check-YakuUse ($catJs -match 'cat-op-key') '画面にもキーを出す'
Check-YakuUse ($catCss -match '\.cat-op-key') 'キーは操作名より弱く見せる'
# 一覧そのものは既にあるので、消していないこと
Check-YakuUse ($catHtml -match 'cat-key-help') 'キーボード操作の一覧は残っている'

# 初回利用者の目で見て見つかった3件（2026-08-13、実機と3体の点検）。
$styles = Get-Content -LiteralPath (Join-Path $root 'www\assets\styles.css') -Raw -Encoding UTF8
$tourJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\tour.js') -Raw -Encoding UTF8

# 1. 「使い方を見る」（/cat?tour=1）で案内が始まる。syncLocation がアドレスを
#    書き換えるより先に、tour=1 を meta へ写しておく必要がある。
#    実測: 直す前は アドレス /cat?tab=quick・meta 空・案内の要素0個。
Check-YakuUse ($catJs -match "get\('tour'\) === '1'") 'アドレスの案内指定を読む'
Check-YakuUse ($catJs -match "querySelector\('meta\[name=\x22yaku-tour\x22\]'\)") '書き換わる前に印へ写す'
Check-YakuUse ($tourJs -match 'meta\[name="yaku-tour"\]') '案内は印を先に見る'
# 写す処理は syncLocation の定義より前に無いと意味がない
Check-YakuUse ($catJs.IndexOf("get('tour') === '1'") -lt $catJs.IndexOf('function syncLocation')) '写すのはアドレスを書き換える処理より前'

# 2. 画面から消した見出しでも、文書の見出しは残す（h1 が読み上げから落ちていた）。
Check-YakuUse ($styles -notmatch 'body\[data-cat-view="local-start"\] \.workspace-heading \{ display: none; \}') '開始画面の見出しを display:none で消さない'
Check-YakuUse ($styles -match '(?s)body\[data-cat-view="start"\] \.workspace-heading \{[^}]*clip: rect\(0, 0, 0, 0\)') '開始画面では場所だけ取らせない'
Check-YakuUse ($catCss -match '(?s)\.app-cat \.workspace-heading \{[^}]*clip: rect\(0, 0, 0, 0\)') '確認作業でも見出しは文書に残す'

# 3. 使い方への出口は、どちらのタブからも届く（着地タブに1本も無かった）。
Check-YakuUse ($catHtml -match 'id="cat-help-links"') '使い方への出口に名前を付ける'
# 守りたいのは「資料側のパネルの中に無いこと」。パネルの最後の要素
# （cat-direction-choice）と出口のあいだに </section> があれば、外に出ている。
Check-YakuUse ($catHtml -match '(?s)id="cat-direction-choice"[\s\S]*?</section>[\s\S]*?id="cat-help-links"') '出口は資料側のパネルの外にある'
Check-YakuUse ($catCss -match 'body\[data-cat-view="workspace"\] #cat-help-links \{ display: none; \}') '確認作業中は出さない'

# 資料の側にも、外へ送ることと伏せることを書く（2026-08-13）。
# 貼り付けの側にだけ書いてあり、資料を選んだ人は読まずに送れてしまっていた。
Check-YakuUse ($catHtml -match '(?s)data-cat-source-show="file"[\s\S]{0,400}?Copilotへ送ります') '資料の側にも送信の説明がある'
Check-YakuUse ($catHtml -match 'ファイルそのものは送りません') '送るのは文だけだと書く'

# DRAFT の約束を3か所で揃える。実装は名前だけでなく中にも印を入れている。
#   Word  … WordAdapter.ps1 が本文の先頭へ「DRAFT — YakuLingo（確認用）」を挿入
#   Excel … FileProcessors.ps1 が定義名 _YakuLingoArtifactStatus を追加
$catProject = Get-Content -LiteralPath (Join-Path $root 'src\CatProject.ps1') -Raw -Encoding UTF8
$tutorial = Get-Content -LiteralPath (Join-Path $root 'www\tutorial.html') -Raw -Encoding UTF8
Check-YakuUse ($catProject -match "mode -eq 'word_draft'" -and $catProject -match "mode -eq 'excel_draft'") '出す前の確認は形式ごとに書き分ける'
Check-YakuUse ($catProject -match 'DRAFT — YakuLingo（確認用）') 'Wordは本文に入る印まで書く'
Check-YakuUse ($tutorial -match 'コピーの中にも下書きの印が入ります') '説明ページも中の印に触れる'
Check-YakuUse ($catJs -match "document_format === 'docx'[\s\S]{0,200}?本文の1行目") '作業画面も形式ごとに書き分ける'
Check-YakuUse ($catJs -notmatch '名前と文書内に DRAFT が付きます') '曖昧な言い方は残さない'

# 押す前に、どちらへ訳すのかが出る（自動判定のときは決め方を書く）。
Check-YakuUse ($quickJs -match "hidden = !text\.trim\(\);") '文章を入れたら方向の欄を出す'
Check-YakuUse ($quickJs -match '文章を見て、英語か日本語かを決めます') '自動のときは決め方を書く'
Check-YakuUse ($quickJs -notmatch "hidden = !text\.trim\(\) \|\| !explicitDirection") '自分で選んだときだけ出す作りに戻さない'

if ($script:failed -gt 0) { Write-Host ('Usability tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Usability tests passed.' -ForegroundColor Green
