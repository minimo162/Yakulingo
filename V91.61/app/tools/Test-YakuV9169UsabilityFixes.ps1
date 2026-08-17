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
$styles  = Get-Content -LiteralPath (Join-Path $root 'www\assets\styles.css') -Raw -Encoding UTF8
$catHtml = Get-Content -LiteralPath (Join-Path $root 'www\cat.html') -Raw -Encoding UTF8

Write-Host 'Findings from using the app on the real screen stay fixed' -ForegroundColor Cyan

# 1. 金額の書き方は、選ぶところで言う（2026-08-13 に置き換えた）
# もとは訳案のそばに「金額は ¥1,315 billion のように書いています」を出し、
# 金額が1つも無い文にも出ていたのを、金額があるときだけに直したものだった。
# 訳案カードを外したので、注記の置き場そのものが無くなった。選ぶところの
# <option> が両方の例を並べて言っており、実際の書き方は確認画面の訳文に出る。
# 守るのは「説明を2か所に持たない」と「選ぶ前に例が読める」こと。
Check-YakuUse ($catHtml -match 'oku（1兆3,150億円' -and $catHtml -match 'billion（1兆3,150億円') '選ぶところに両方の例が出ている'
Check-YakuUse ($quickJs -notmatch 'notationExample' -and $quickJs -notmatch 'hasAmount') '置き場の無い注記を作りに行かない'
Check-YakuUse ($quickJs -match 'function notation\(') '既定は設定から読む（画面側で決めない）'
# 原文はこの画面が持ち回らない（Quick の試験が固定している不変条件）。
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
Check-YakuUse ($catJs -match 'data-cat-confirm="' + "' \+ index \+ '" + '" title="この行を確認済みにする（Ctrl\+Enter）"' -and
    $catJs.Contains('aria-label="確認済みにする（Ctrl+Enter）"')) '確認ボタンがキーの名前を持つ'
Check-YakuUse ($catJs -match 'aria-keyshortcuts="Control\+Enter"') '読み上げにもキーを伝える'
Check-YakuUse ($catJs -match 'cat-op-key') '画面にもキーを出す'
Check-YakuUse ($catCss -match '\.cat-op-key') 'キーは操作名より弱く見せる'
# 一覧そのものは既にあるので、消していないこと
Check-YakuUse ($catHtml -match 'cat-key-help') 'キーボード操作の一覧は残っている'

# 初回利用者の目で見て見つかった3件（2026-08-13、実機と3体の点検）。
$styles = Get-Content -LiteralPath (Join-Path $root 'www\assets\styles.css') -Raw -Encoding UTF8
$tourJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\tour.js') -Raw -Encoding UTF8
$serverForView = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8

# 1. 使い方・設定・初回ツアーの入口は開始画面から退役した。
#    互換アセットは残すが、CAT の URL/meta/script からは到達できない。
Check-YakuUse ($catJs -notmatch "location\.(?:assign|href).*?/tutorial(?:#settings)?") 'CAT client に tutorial/settings への遷移を残さない'
Check-YakuUse ($catHtml -notmatch 'name="yaku-tour"' -and $catHtml -notmatch '/assets/tour.js') 'CAT テンプレートにツアーの meta/script を残さない'
Check-YakuUse ($catHtml -notmatch '__YAKU_TOUR__' -and $catHtml -notmatch 'tour=1') 'CAT テンプレートに退役したツアー placeholder/URL hook を残さない'
Check-YakuUse ($serverForView -notmatch 'StartTour') 'サーバ本文に StartTour hook を残さない'

# 2. 画面から消した見出しでも、文書の見出しは残す（h1 が読み上げから落ちていた）。
Check-YakuUse ($styles -notmatch 'body\[data-cat-view="local-start"\] \.workspace-heading \{ display: none; \}') '開始画面の見出しを display:none で消さない'
Check-YakuUse ($styles -match '(?s)body\[data-cat-view="start"\] \.workspace-heading \{[^}]*clip: rect\(0, 0, 0, 0\)') '開始画面では場所だけ取らせない'
Check-YakuUse ($catCss -match '(?s)\.app-cat \.workspace-heading \{[^}]*clip: rect\(0, 0, 0, 0\)') '確認作業でも見出しは文書に残す'

# 3. 退役した使い方・設定の入口は、開始画面にも確認作業にも出さない。
Check-YakuUse ($catHtml -notmatch 'id="cat-help-links"' -and $catHtml -notmatch 'href="/tutorial(?:#settings)?"') '開始画面に退役した help/settings link を残さない'
# 主役の入力面を DOM の先頭に置き、右の最近の作業/TM rail を補助にする。
$mainPos = $catHtml.IndexOf('class="entry-main"')
$railPos = $catHtml.IndexOf('class="entry-rail"')
Check-YakuUse ($mainPos -ge 0 -and $railPos -gt $mainPos) '主役の入力面を最近の作業 rail より先に置く'
Check-YakuUse ($serverForView.Contains("if (`$method -eq 'GET' -and `$path -eq '/tutorial')") -and $serverForView.Contains("Send-YakuRedirectResponse -Context `$Context -Location '/cat'")) '退役した /tutorial は CAT へ redirect する'

# 外へ送るものは、統合した入力枠の直下で短く1回だけ説明する。
Check-YakuUse ($catHtml -match '数値は伏せて送ります。社名・人名と文章はそのまま送ります。ファイルは送りません。') '送るものと送らないものを同じ1行で書く'
Check-YakuUse (([regex]::Matches($catHtml, '社名・人名と文章はそのまま送ります')).Count -eq 1) '送信の説明を1画面に重ねない'
Check-YakuUse ($catHtml -match 'ファイルは送りません') '送るのは文だけだと書く'

# ファイルの中の印は 2026-08-13 に利用者判断で外した（「そもそもその機能自体
# いらない」）。形式ごとに書き分ける相手も無くなったので、言うのは
# 「原本は触らない」「名前の先頭に DRAFT_ が付く」の2つだけ。
$catProject = Get-Content -LiteralPath (Join-Path $root 'src\CatProject.ps1') -Raw -Encoding UTF8
$tutorial = Get-Content -LiteralPath (Join-Path $root 'www\tutorial.html') -Raw -Encoding UTF8
Check-YakuUse ($catProject -match '名前の先頭に「DRAFT_」が付きます。' -and $catProject -notmatch '本文の1行目') '出す前の確認は、名前のことだけを言う'
Check-YakuUse ($tutorial -notmatch '下書きの印' -and $tutorial -match 'DRAFT_</code> が付いた別のコピー') '説明ページも名前のことだけを言う'
Check-YakuUse ($catJs -notmatch '本文の1行目' -and $catJs -notmatch '見えない DRAFT の印') '作業画面にも中の印の話を残さない'
Check-YakuUse ($catJs -notmatch '名前と文書内に DRAFT が付きます') '曖昧な言い方は残さない'

# 押す前に、どちらへ訳すのかが出る。
# 2026-08-13 の午前は「決め方を書く」で満足していたが、それでは結局どちらに
# なるのか分からない、という指摘を同じ日に受けた。いまは決まった向きを出す。
# この検査は私の注釈に引っかかって通っていた（字面ではなく出す値を見る）。
Check-YakuUse ($quickJs -match "hidden = !text\.trim\(\);") '文章を入れたら方向の欄を出す'
Check-YakuUse ($quickJs -match "directionSelect\.value = direction === 'to_en' \|\| direction === 'to_jp' \? direction : ''") '自動のときも、決まった向きを選択欄へ出す'
Check-YakuUse ($quickJs -notmatch "hidden = !text\.trim\(\) \|\| !explicitDirection") '自分で選んだときだけ出す作りに戻さない'

# 2026-08-13、初回利用者として実機を通して見つけたもの。

# 作った直後に「点検 2」を赤く出さない。中身は「訳文が空 2」で、まだ訳していない
# だけだった。何もしていない利用者に、いきなり欠陥の言い方をしていた。
# 同じ画面の「訳文を取り出す」は最初から「残り2行の訳案を作ってください。」と
# 正しく言っていたので、言い方はそちらへ揃える。1行でも訳ができれば指摘に戻る。
Check-YakuUse ($catJs -match 'function nothingTranslatedYet') 'まだ一度も訳していない状態を見分ける'
# 群の説明や種類が増えても、関数内のガードそのものを見失わない。文字数で距離を
# 600字に固定すると、挙動が同じまま説明を足しただけで物差しが赤になる。
Check-YakuUse ($catJs -match '(?s)function qaFindings\(\)\s*\{[\s\S]*?if \(nothingTranslatedYet\(\)\) return groups;') '訳す前は指摘を数えない'
Check-YakuUse ($catJs -match 'まだ訳していません。「Copilotで未訳を翻訳」を押すと') '点検一覧は次にやることを書く'

# 帯と行で、同じことを違う名前で呼んでいた（帯は「訳案」、行は「訳文」）。
# 範囲も帯の側だけ名乗っていなかった（2026-08-13、利用者の指摘
# 「パッと見て分かりにくいかも」）。並べて読めるように、範囲を名前へ入れる。
#   訳す   この行だけ訳す        / 訳していない行を訳す
#   コピー この行の訳文をコピー  / すべての訳文をコピー / 確認済みの行だけコピー
Check-YakuUse ($catHtml -match '<button id="cat-translate"[^>]*>Copilotで未訳を翻訳</button>') 'まとめて訳すボタンが範囲を名乗る'
Check-YakuUse ($catHtml -match '<button id="cat-export"[^>]*>訳文をコピー</button>') 'まとめてコピーが範囲を名乗る'
Check-YakuUse ($catJs -notmatch '残りの訳案を作る' -and $catHtml -notmatch '残りの訳案を作る') '古い呼び名を画面に残さない'

# 出す先はファイルとは限らない。訳文のコピーはクリップボードへ写すだけで、
# ファイルは作らない。作られていないものを作ったと言わない。
Check-YakuUse ($catJs -match "isCopy = mode === 'copy_text'" -and $catJs -match "isCopy \? 'コピーできます。' : 'ファイルにできます。'") 'コピーのときはコピーと言う'
Check-YakuUse ($catProject -match "mode -eq 'copy_text'.*そのままコピーに入れます") '未確認の断りも出す先に合わせる'

# 初回の案内。1つ目に本文の無い「訳したい文章を貼り付けます」を出していたが、
# 画面の見出しが同じことを言っており、しかもすぐ下の1行を覆っていた
# （実測 1240x860: 吹き出し y320-419 が「1行ずつ確認する画面に移ります。…」y376-400 を覆う）。
$tourJsUse = Get-Content -LiteralPath (Join-Path $root 'www\assets\tour.js') -Raw -Encoding UTF8
Check-YakuUse ($tourJsUse -notmatch "target: '#quick-input'") '当たり前の操作を説明する段は置かない'
# 前の段の操作で画面が動くと、次の段のボタンが画面の外へ出て、吹き出しだけが端で切れる。
Check-YakuUse ($tourJsUse -match 'box\.top < 12 \|\| box\.bottom > window\.innerHeight - 12') '指す先が画面の外なら、先に見える所へ戻す'
Check-YakuUse ($tourJsUse -match "target: '#cat-open-file-entry'[\s\S]{0,500}?preservePosition: true" -and $tourJsUse.Contains('if (step.preservePosition) { next(); return; }')) '狭い初回画面では入力欄の位置を守る'
Check-YakuUse ($tourJsUse -match "target: '#cat-open-file-entry'[\s\S]{0,700}?nextAtTop: true" -and $tourJsUse.Contains('target.blur();') -and $tourJsUse.Contains('window.scrollTo(0, 0);')) '資料選択の次は入力欄へ戻す'
Check-YakuUse ($tourJsUse.Contains("document.getElementById('quick-form')") -and $tourJsUse.Contains('new MutationObserver') -and $tourJsUse.Contains('mutationObserver.disconnect()')) '入力で動いた送信ボタンを案内が追いかける'
# 中央へ寄せると押しただけで大きく飛ぶ。開いた欄はいちばん少ない移動で見せる。
Check-YakuUse ($catJs -match "(?s)function showStart\(mode\)[\s\S]{0,1200}?block: 'nearest'") '開いた欄は最小の移動で見せる'
Check-YakuUse ($catJs -notmatch "(?s)function showStart\(mode\) \{ closeStartPanels\(\); var panel[\s\S]{0,120}?YakuCommon\.focus\(") '中央へ寄せる作りに戻さない'

# 押せるボタンに「してください」と書かない。未確認が残っていても取り出せる決まりに
# した（2026-08-12）のに、押せる状態のまま「あと2行を確認済みにしてください。」と
# 出しており、命令に読めた。押せるボタンには起きることを書く。
Check-YakuUse ($catJs -match 'まだ確認していない.{0,20}行も、そのまま入ります。') '押せるときは、起きることを書く'

# 過去訳の対応候補は、作成直後はまだ未確認。ここで守るのは
# **「調べていないものを問題なしと言い切らない」** ことである。
#
# 2026-08-15 に、その言い方を変えた。以前は「数字の点検は、確認済みにするときに
# 行います」と書いて未点検であることを伝えていたが、**それは既に事実でなかった**。
# Get-YakuCatOutputEligibility は未確定の行を写しに掛けて点検しており、その関数は
# 画面へ返す JSON を作るたびに通る。指摘が出ないのは「まだ調べていないから」では
# なく「調べて通ったから」である。写しの結果を画面へ渡すようにした（qc_preview）
# ので、いまは一覧にも出る。CLAUDE.md の「制約文と実装が食い違ったら実装を採る」
# に従い、文言のほうを実装へ合わせた。
#
# 守る中身は変えない。増やしたのは「もう事実でない古い言い方へ戻さない」1本である。
Check-YakuUse ($catJs -match '未確認は .{0,30} 行です。自動点検では、直すところは見つかりませんでした。') '未確認の段階でも、点検した結果として伝える'
Check-YakuUse ($catJs -notmatch '止まる指摘はありません。未確認は') '未点検を問題なしと言い切らない'
Check-YakuUse ($catJs -notmatch '数字の点検は、確認済みにするときに行います') '「点検は確認済みにするときに行う」という、もう事実でない言い方へ戻さない'
# 一覧の群の名前も「数字」だけを名乗らない。ここへ来る指摘は18種あり、
# 通貨・見出しの形・用語もその中に居る（用語で止まった人が数字を見に行かされる）。
Check-YakuUse ($catJs -match "title: '自動点検の指摘'") '点検一覧の群は、数字以外も入る名前になっている'
Check-YakuUse ($catJs -notmatch "title: '数字の点検'") '群の名前を「数字の点検」へ戻さない'
# 注釈にも同じ字面を書いていて、自分の説明に引っかかっていた。
# 見るのは出している文言（title に入る戻り値）のほう。
Check-YakuUse ($catJs -notmatch "return 'あと' \+ left \+ '行を確認済みにしてください。'") '押せるボタンに命令を書かない'
# 押せない理由は、押せるかどうかが決まったあとで作る。先に作ると、待っているあいだの
# 「全部押せない」状態を読んで、押せるボタンにも「押せません」と書いてしまう。
Check-YakuUse ($catJs -match "(?s)saveStatus\('保存済み', false\); setBusy\(false\);[\s\S]{0,400}?var outputReasons = \[\];") '押せない理由は、状態が決まってから作る'

# Excel の場所は、どのセルかがいちばん要る情報。列が狭く、長いシート名だと番地まで
# 届かない（実測 1760px: 366px 必要なところに 89px）。全文を指せば読めるようにする。
Check-YakuUse ($catJs -match 'class="cat-location-main" title="') '場所は全文を指せば読める'
# 「訳して確認する」を押したのに、原文が並ぶだけで訳が始まらなかった
# （2026-08-13、利用者の指摘）。ボタン名も案内も「送る」と言っているので、
# 送るところまでがこの操作。資料の取り込みは「取り込んで確認を始める」と
# 名乗っているので、そちらは取り込むだけのままにする。
Check-YakuUse ($quickJs -match "encodeURIComponent\(data\.id\) \+ '&translate=1'") '貼り付けから来たことを行き先に渡す'
Check-YakuUse ($catJs -match 'function translateWhenReady') '着いたらそのまま訳しにいく'
Check-YakuUse ($catJs -match "params\.get\('translate'\) === '1'") '貼り付けから来たときだけ自動で送る'
Check-YakuUse ($catJs -match 'autoTranslateDone') '自動で送るのは1回だけ'
Check-YakuUse ($catJs -match 'Copilotの準備ができ次第、送ります') '準備前に押しても、待って送ると書く'

# 資料を開いた形で読み込むとき、貼り付け欄が一瞬出てから入れ替わり、点滅して見えた。
# サーバが ?project= を見て body へ状態を入れ、1回目の描画から確認作業として出す。
$serverForView = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8
Check-YakuUse ($catHtml -match '<body class="app-cat" data-cat-view="__YAKU_VIEW__">' -and $catHtml -notmatch '__YAKU_TOUR__') '開いた瞬間の view 属性だけを差し込む口がある'
Check-YakuUse ($serverForView -match "InitialView -eq 'workspace'") 'サーバが確認作業として開く'
Check-YakuUse ($serverForView -match 'wantedProject -match') '住所の project を見て決める'
Check-YakuUse ($catCss -match 'body\[data-cat-view="workspace"\] #cat-picker \{ display: none; \}') '始める画面の器も最初から出さない'
# 読み込んだ時点で ?project= が付いていたら履歴を積まない。積むと戻るが1回増え、
# 戻った先の住所は translate=1 付きで、読み直すとまた訳しにいく。
Check-YakuUse ($catJs -match 'var locationSynced = false;' -and $catJs -match 'if \(projectId && !first\)') '最初の1回は履歴を積まない'

# 選んだ行の左に、状態の帯（4px）と選択の枠（3px）が色違いで2本並んでいた。
# 選んでいる行では帯を消す。その行の状態は丸章と文字で同じ行に出ている。
Check-YakuUse ($catCss -match '(?s)\.cat-grid tbody tr\.is-active \{[^}]*border-left-color: transparent;') '選んだ行では状態の帯を出さない'

# どちらへ訳すのかを、押す前に出す。「文章を見て、英語か日本語かを決めます」では
# 結局どちらになるのか分からなかった（2026-08-13、利用者の指摘）。判定は
# Resolve-YakuDirectionDecision 1か所しか持たない決まりなので、同じ判定へ聞く。
Check-YakuUse ($serverForView -match "path -eq '/api/direction-preview'") '向きを聞くだけの口がある'
Check-YakuUse ($serverForView -match "(?s)/api/direction-preview[\s\S]{0,900}?Resolve-YakuDirectionDecision") '判定は同じ関数へ聞く'
Check-YakuUse ($quickJs -match 'function refreshDirection' -and $quickJs -match "'/api/direction-preview'") '打ち終わったら聞きにいく'
# 注釈にも同じ字面を書いているので、字面ではなく「画面へ出す値」を見る。
Check-YakuUse ($quickJs -notmatch ": '文章を見て、英語か日本語かを決めます';") '決め方だけを書く一文は残さない'
Check-YakuUse ($quickJs -match "\(resolved \? direction : 'to_en'\) === 'to_en' \? '英語に訳す' : '日本語に訳す'") '実行ボタンは空のときも行為の名前を保ち、決まった向きを出す'

# 他の始め方を見ただけで、打ちかけのメールを消さない。PDF取り込みは WebAssembly
# を許可するため ?import=1 へ読み直す必要があるので、移動前にこのタブ内だけへ退避する。
Check-YakuUse ($quickJs -match "draftStorageKey = 'yaku\.quick\.draft\.before-navigation'") '打ちかけはこのタブ内だけへ退避する'
Check-YakuUse ($quickJs -match 'function preserveDraft' -and $quickJs -match 'function restoreDraft') '移動前の退避と移動後の復元がある'
Check-YakuUse ($catJs -match 'YakuInstant\.preserveDraft') 'PDF取り込み画面へ移る前に退避する'
Check-YakuUse ($quickJs -match 'sessionStorage\.removeItem\(draftStorageKey\)') '復元した退避データを残し続けない'

# 英訳の金額表記は英訳するときだけ必要。短い英文メールの和訳で、関係のない設定を
# 最初から判断させない。
Check-YakuUse ($catHtml -match 'id="quick-amount-setting"[^>]*hidden') '金額表記は最初は隠れている'
Check-YakuUse ($quickJs -match "amountSetting\.hidden = direction !== 'to_en'") '英訳するときだけ金額表記を出す'

# 貼り付けはCATへ一本化し、保存有無を開始前に選ばせない。
Check-YakuUse ($catHtml -match 'id="quick-submit-reason"[^>]*class="quick-submit-reason"[^>]*role="status"' -and $catHtml -notmatch 'quick-submit-note|確認画面へ進みます') '貼り付けの状態説明を主操作の直下へ動的に出す'
Check-YakuUse ($catHtml -match 'Word・Excelを訳す' -and $catHtml -match 'ファイルを選ぶと、文章を行ごとに確認できます。元のファイルは変更せず、訳したファイルを新しいコピーとして保存します。') 'Word・Excel の入口と原本を触らないことを簡潔に示す'
Check-YakuUse ($catHtml -notmatch 'あとで続けるため、確認作業として保存する') '内部的な作業名だけの説明へ戻さない'
Check-YakuUse ($catHtml -notmatch 'class="quick-save-choice"' -and $catHtml -notmatch 'id="quick-save-submit"') '主操作の意味をチェックボックスや二つ目のボタンで切り替えない'
Check-YakuUse ($quickJs -notmatch 'quick-save-submit|saveAsWork' -and $quickJs -match "/api/cat/open") '貼り付けは単一のCAT操作へ進む'
# 言語の選択は送信ではない。選択後に主操作へ戻し、利用者が明示的に押すまで
# Copilotへの送信を始めない。
$directionChoiceHandler = [regex]::Match($quickJs, "(?s)el\('quick-direction-select'\)\.addEventListener\('change'.*?^    \}\);", [System.Text.RegularExpressions.RegexOptions]::Multiline).Value
Check-YakuUse ($directionChoiceHandler -match "YakuCommon\.focus\(el\('quick-submit'\)\)" -and $directionChoiceHandler -notmatch 'requestSubmit') '訳す言語の選択だけでは送信しない'

# 文章とファイルをタブで分けず、同じ枠で受ける。
Check-YakuUse ($catHtml -match '(?s)id="quick-area"[\s\S]*?id="quick-input"[\s\S]*?id="cat-file-area"[\s\S]*?id="cat-open-file-entry"') '文章とファイルを1つの入力枠で受ける'
Check-YakuUse ($catHtml -match 'Word・Excelを訳す' -and
    $catHtml -match 'ファイルを選ぶと、文章を行ごとに確認できます。元のファイルは変更せず、訳したファイルを新しいコピーとして保存します。' -and
    $catHtml -match 'id="cat-open-file-entry"[^>]*>ファイルを選ぶ' -and
    $catHtml -match 'id="cat-file-input"[^>]*type="file"' -and
    $catJs.Contains("bindFileDrop(el('quick-area'), el('cat-file-input'))") -and
    $catJs.Contains("drop.addEventListener('keydown'") -and
    $catJs.Contains("event.key === 'Enter' || event.key === ' '") -and
    $catJs.Contains("drop.addEventListener('drop'")) 'ドラッグと単一ポインタの両方で取り込める'
Check-YakuUse ($catHtml -notmatch 'id="quick-save-submit"' -and $catHtml -match 'id="cat-open-file-entry"') '保存有無の二重入口を残さない'
Check-YakuUse ($catHtml -match 'id="cat-resume-title"[^>]*>最近の作業<' -and $mainPos -ge 0 -and $railPos -gt $mainPos) '最近の作業を主入力の後段にある utility rail として示す'
Check-YakuUse ($catCss -match '(?s)\.quick-area\s*\{[^}]*border:\s*1px solid var\(--line\)[^}]*border-radius:\s*var\(--yk-r-card\)') '文章とファイルの主入口を1枚の枠にする'
Check-YakuUse ($catCss -match '(?s)\.file-lane\s*\{[^}]*border:\s*1px dashed var\(--line-strong\)') 'ファイルを落とせる領域を見た目でも示す'
Check-YakuUse ($catCss -match '(?s)#quick-submit\[disabled\][^{]*\{[^}]*background:\s*#cdd6e4') '空の主ボタンを有効に見せない'
Check-YakuUse ($catCss -match '(?s)\.entry-rail\s*\{[^}]*flex:\s*0 0 var\(--yk-rail\)') '続きの作業を主入力と競合しない左レールにまとめる'

# 「Word・Excelを取り込む」を押しても、下に欄が開くだけで何も起きないように見えた。
# その欄の中にもう一度「選ぶ」があり、さらに確認のボタンがあった（押す回数3回）。
Check-YakuUse ($catJs -match "el\('cat-open-file-entry'\)\.addEventListener\('click'[\s\S]{0,160}?cat-file-input'\)\.click\(\)") '取り込みボタンはファイル選択をそのまま開く'
Check-YakuUse ($catJs -match "(?s)cat-file-input'\)\.addEventListener\('change'[\s\S]{0,220}?openSource\('file', 'auto'\)") '選んだ時点で取り込みが始まる'
Check-YakuUse ($catHtml -notmatch 'Word・Excelを選ぶ' -and $catHtml -notmatch 'ここにファイルをドロップ') '同じことを言う欄を下に置かない'
Check-YakuUse ($catJs -match "(?s)function showStart\(mode\)[\s\S]{0,260}?if \(mode !== 'align'\) return" -and
    $catJs -notmatch "showStart\('file'\)|showStart\('text'\)|showStart\('prior'\)|data-cat-source-show|cat-prior-open|data-cat-open") '開始画面の廃止した手動・旧版パネルを開く処理を残さない'
Check-YakuUse ($catJs -match "bindFileDrop\(el\('quick-area'\), el\('cat-file-input'\)\)" -and ([regex]::Matches($catJs, 'bindFileDrop\(')).Count -eq 2) 'ドロップ処理は関数定義と外枠への結線1回だけにする'

# 1文ずつ依頼する道と、1文だけコピーする道が無かった（2026-08-13、利用者の指摘）。
# まとめて行う道は道具の帯にあり、名前もそう言っている。
Check-YakuUse ($catJs -match 'data-cat-translate-row') 'この行だけ訳すがある'
Check-YakuUse ($catJs -match 'data-cat-copy-target') 'この行の訳文をコピーがある'
Check-YakuUse ($catJs -match "(?s)function translateRow[\s\S]{0,700}?mode: 'translate', index: index") '1行だけの依頼も、まとめて訳すのと同じ口を使う'
Check-YakuUse ($serverForView -match '\$onlyIndex') 'サーバは index を受けたらその行だけ訳す'


# 過去の日英資料を PDF から取り込む（2026-08-13）。利用者の実情として、正式版は
# PDF で、元の Word・Excel は章ごとに細切れだったり印刷範囲外にゴミがあったりする。
# memoQ・Trados も PDF での突き合わせを公式に認めている（memoQ「you can align a
# PDF with a Word document」／Trados は Word原文↔PDF訳文の設定手順まで書いている）。
$serverPdf = Get-Content -LiteralPath (Join-Path $root 'src\Server.ps1') -Raw -Encoding UTF8
$pdfJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\pdf-extract.js') -Raw -Encoding UTF8
$adminJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\admin.js') -Raw -Encoding UTF8
# 利用者の画面は普段 script-src 'self' のまま。取り込みで開いたときだけ緩める。
Check-YakuUse ($serverPdf -match "AllowWasm:\`$wantsImport") '取り込みで開いたときだけ WebAssembly を許す'
Check-YakuUse ($serverPdf -match "Get-YakuQueryValue -Request \`$req -Name 'import'") '住所の import を見て決める'
Check-YakuUse ($catHtml -match 'name="yaku-import"') '画面側にも、取り込みで来たことを渡す'
# 段組みの判定は測って決めた実装。写すと必ず食い違うので、共通部品に1つだけ置く。
Check-YakuUse ($pdfJs -match 'export function yakuPageTextByColumns') '段組みの判定は共通部品にある'
Check-YakuUse ($adminJs -match "from '/assets/pdf-extract.js'" -and $adminJs -notmatch 'function yakuPageTextByColumns') '管理画面も同じ部品を使う（写しを持たない）'
# 画像PDFは受けない。市販ツールも memoQ・Trados が外部OCRへ回している。
Check-YakuUse ($pdfJs -match 'lowText') '文字が取れないPDFを見分ける'
Check-YakuUse ($catJs -match 'OCRでテキスト付きのPDFにしてから') '画像PDFは、OCRしてからと案内する'
# 押す前に、往復回数と見込み時間を出す（実測 2026-08-13: 144ページで128回）。
Check-YakuUse ($catJs -match 'function updateAlignEstimate') '送る前に見込みを出す関数がある'
Check-YakuUse ($catJs -match 'Copilotへ約') '往復回数を押す前に出す'
Check-YakuUse ($catHtml -match '(?s)<section id="cat-align-entry"[\s\S]{0,500}?<h2 id="cat-align-entry-title">過去の訳を登録</h2>[\s\S]{0,500}?日本語版と英語版のPDF' -and
    $catHtml -match 'id="cat-open-align-entry"') '過去訳の入口が開始画面で何をする場所か分かる'
Check-YakuUse ($catHtml -match 'id="cat-source-align"[\s\S]{0,1800}?accept="\.pdf"') '過去訳の対訳フォームでPDF形式を示す'
Check-YakuUse ($catHtml -match '確認済みにしただけでは候補にならず' -and $catHtml -match '翻訳メモリへ登録した(?:訳|行)だけ') '確認だけでは候補にせず、翻訳メモリへ登録した訳だけを次資料へ出すと明示する'
Check-YakuUse ($catJs -match 'function confirmRow' -and $catJs -match "mutate\('confirm'" -and
    $catJs -match 'function registerTranslationMemory' -and $catJs -match "mutate\('tm-register'") '対訳の確認と翻訳メモリ登録は別操作として実装されている'
Check-YakuUse ($catHtml -match '取り出した日本語と英語の文をCopilotへ送って') 'PDF突き合わせで送る内容を押す前に明示する'
Check-YakuUse ($catHtml -match 'id="cat-align-open" disabled') '日英の片方だけでは対応づけを始められない'
Check-YakuUse ($catJs -match "var en = String\(el\('cat-align-target'\)" -and $catJs -match 'var ready = ja > 0 && en > 0') '日英双方の読取結果で開始可否を決める'
Check-YakuUse ($catJs -match "日本語 ' \+ ja\.toLocaleString\('ja-JP'\) \+ '行、英語 '") '選んだ範囲の日英行数を両方表示する'
Check-YakuUse ($catJs -match "if \(mode === 'align'\) updateAlignEstimate\(\)") '画面を開き直しても片方だけで開始できない'
Check-YakuUse ($catJs -match "if \(el\('cat-align-open'\)\) updateAlignEstimate\(\)") '待機解除で対訳開始ボタンを誤って有効にしない'

# ページ範囲。資料まるごとは往復が3桁になるので、章だけを選べるようにする。
# 実測 2026-08-13: 144ページ全部で約128回（21〜43分）、50〜60ページに絞ると
# 約13回（2〜4分）。対応づけの宣言は人がする（市販ツールも全社そう）が、
# 対応するページを調べる手間はこちらで引き受ける（ページの冒頭を並べる）。
Check-YakuUse ($catHtml -match 'id="cat-align-source-from"' -and $catHtml -match 'id="cat-align-target-to"') '日英それぞれに範囲の欄がある'
Check-YakuUse ($catJs -match 'function applyAlignRange') '選んだ範囲だけを送る文へ組み直す'
Check-YakuUse ($catJs -match "\['input', 'change'\]\.forEach") 'ページ範囲の入力中から見込みを更新する'

# memoQ・Tradosの alignment editor と同様に、過去訳の対応確認を通常の翻訳と
# 区別する。実機では保存一覧まで「英語に訳す作業」と表示され、目的が逆に見えた。
Check-YakuUse ($serverForView -match 'source = \[string\]\$_.Source') '保存一覧にも作業の種類を返す'
Check-YakuUse ($catJs -match "source === 'align' \? '過去訳の対応確認'") '対訳作業を新規翻訳と呼ばない'
Check-YakuUse ($catHtml -match 'id="cat-align-review-guide"' -and $catHtml -match '自動で作った対応は推測です') '自動対応は人が確認すると表の前で伝える'
Check-YakuUse ($catHtml -match 'id="cat-align-next-document"' -and $catHtml -match '今回のWord・Excelを取り込む' -and $catJs -match "cat-align-next-document'.*showPicker\(\); YakuCommon\.focus\(el\('cat-open-file-entry'\)\)") '過去訳の確認後に今回の資料へ進む導線がある'
Check-YakuUse ($catJs.Contains("var headingLabels = isAlignment") -and
    $catJs.Contains("{ source: '日本語', target: '英語' }") -and
    $catJs.Contains("el('cat-source-heading').textContent = headingLabels.source") -and
    $catJs.Contains("el('cat-target-heading').textContent = headingLabels.target")) '対訳画面の columnHeadings は 日本語 / 英語 を示す'
Check-YakuUse ($catJs -match "el\('cat-translate'\)\.hidden = isAlignment") '対訳確認では新規翻訳の操作を隠す'
Check-YakuUse ($catJs -match "el\('cat-page-title'\)\.textContent = isAlignment \? '過去訳の対応確認' : '翻訳'") 'ページ全体も対訳確認として名乗る'
Check-YakuUse ($catJs -match 'function renderAlignPages') 'ページの冒頭を並べる'
Check-YakuUse ($catHtml -match 'ページの冒頭を見る') '別のアプリで開かずに対応を探せる'
# 解析し直さずに範囲を変えられること（読み込みは1回だけで済ませる）。
Check-YakuUse ($catJs -match 'var alignPages = \{ source: \[\], target: \[\] \}') '読み込んだページを持っておく'
Check-YakuUse ($catCss -match '\.align-page-list') 'ページ一覧はその中だけで動かす'

# ---- 画面のキー一覧と、実装が扱うキーが一致していること ---------------------
# 差分表 #12。cat.js の keydown ハンドラが扱うキーの集合と、cat.html の <dl> に
# 並ぶキーの集合が一致すること（片方にしか無いキーが0件）。
#
# なぜ字面照合では駄目か（2026-08-16 に実測）: この時点で実装には Ctrl+K
# （過去訳を言葉で探す）と Ctrl+[（資料一覧の開閉）があったのに、一覧には
# どちらも載っていなかった。`-match 'Ctrl\+K'` の形の表明をいくら足しても、
# **書き忘れたキーは名前が出てこない**ので永久に見つからない。行番号でもなく
# キー名でもなく、**両方から集合を取り出して突き合わせる**ほかない。
#
# 取り出しは条件式そのものから行う（`event.key === '['` の '[' を読む）。
# 註のコメントに書いた名前は読まない。註は実装が変わっても書き換わらないので、
# 名前照合をコメントに対して行うのと同じになる。
function Remove-YakuJsComments {
    <# コメントの中の `if (` を条件式と取り違えないよう、先に空白へ潰す。
       文字列リテラルの中の `/*` は潰さない（位置がずれると括弧の対応が狂う）。 #>
    param([Parameter(Mandatory=$true)][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $quote = ''
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($quote -ne '') {
            [void]$sb.Append($ch)
            if ($ch -eq '\') { if (($i + 1) -lt $Text.Length) { [void]$sb.Append($Text[$i+1]) }; $i += 2; continue }
            if ([string]$ch -eq $quote) { $quote = '' }
            $i++; continue
        }
        if ($ch -eq "'" -or $ch -eq '"' -or $ch -eq [char]0x60) { $quote = [string]$ch; [void]$sb.Append($ch); $i++; continue }
        if ($ch -eq '/' -and ($i + 1) -lt $Text.Length -and $Text[$i+1] -eq '*') {
            $i += 2
            while ($i -lt $Text.Length -and -not ($Text[$i] -eq '*' -and ($i+1) -lt $Text.Length -and $Text[$i+1] -eq '/')) {
                if ($Text[$i] -eq [char]10) { [void]$sb.Append([char]10) } else { [void]$sb.Append(' ') }
                $i++
            }
            [void]$sb.Append('  '); $i += 2; continue
        }
        if ($ch -eq '/' -and ($i + 1) -lt $Text.Length -and $Text[$i+1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne [char]10) { [void]$sb.Append(' '); $i++ }
            continue
        }
        [void]$sb.Append($ch); $i++
    }
    return $sb.ToString()
}
function Get-YakuJsBalancedSpan {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][int]$Start,
        [Parameter(Mandatory=$true)][char]$Open,
        [Parameter(Mandatory=$true)][char]$Close
    )
    $depth = 0; $i = $Start; $quote = ''
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($quote -ne '') {
            if ($ch -eq '\') { $i += 2; continue }
            if ([string]$ch -eq $quote) { $quote = '' }
            $i++; continue
        }
        if ($ch -eq "'" -or $ch -eq '"' -or $ch -eq [char]0x60) { $quote = [string]$ch; $i++; continue }
        if ($ch -eq $Open) { $depth++ }
        elseif ($ch -eq $Close) { $depth--; if ($depth -eq 0) { return $Text.Substring($Start, $i - $Start + 1) } }
        $i++
    }
    return ''
}
function Get-YakuJsKeydownBody {
    <# 画面全体のキー操作を持つのは document 直付けの keydown 1つだけ。
       取り込み欄の Enter/Space（cat.js の drop 要素）は、押しどころの
       起動キーであって作業画面のキー操作ではないので、ここには入れない。 #>
    param([Parameter(Mandatory=$true)][string]$Js)
    $at = $Js.IndexOf("document.addEventListener('keydown'", [StringComparison]::Ordinal)
    if ($at -lt 0) { return '' }
    $open = $Js.IndexOf('{', $at)
    if ($open -lt 0) { return '' }
    return (Get-YakuJsBalancedSpan -Text $Js -Start $open -Open ([char]'{') -Close ([char]'}'))
}
function ConvertTo-YakuKeyDisplayName {
    <# 両側を同じ名前へ寄せる。画面は「↑」「1～9」、実装は 'ArrowUp'、'1'〜'9' と
       書くので、どちらかに寄せないと突き合わせられない。 #>
    param([Parameter(Mandatory=$true)][string]$Raw)
    $v = [string]$Raw
    if ($v -eq 'Escape' -or $v -eq 'Esc') { return 'Esc' }
    if ($v -eq [string][char]0x2191) { return 'ArrowUp' }
    if ($v -eq [string][char]0x2193) { return 'ArrowDown' }
    if ($v -eq ('1' + [string][char]0xFF5E + '9')) { return '1-9' }
    if ($v.Length -eq 1) { return $v.ToUpperInvariant() }
    return $v
}
function Format-YakuShortcutName {
    param([AllowNull()][object]$Modifiers, [Parameter(Mandatory=$true)][string]$Key)
    $mods = @($Modifiers)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($mods -contains 'Ctrl') { $parts.Add('Ctrl') | Out-Null }
    if ($mods -contains 'Alt') { $parts.Add('Alt') | Out-Null }
    if ($mods -contains 'Shift') { $parts.Add('Shift') | Out-Null }
    $parts.Add($Key) | Out-Null
    return (($parts.ToArray()) -join '+')
}
function Get-YakuJsShortcutSet {
    <# keydown の中の if の条件式から、押されたときに通るキーを拾う。
       `if (!(event.ctrlKey || event.metaKey)) return;` より後ろの条件は
       Ctrl を継いでいる（Ctrl+Enter と Ctrl+1〜9 がそれ）。 #>
    param([Parameter(Mandatory=$true)][string]$Body)
    $set = New-Object System.Collections.Generic.List[string]
    $guardPattern = '!\(\s*event\.ctrlKey\s*\|\|\s*event\.metaKey\s*\)'
    $guardMatch = [regex]::Match($Body, $guardPattern)
    $guardAt = $(if ($guardMatch.Success) { [int]$guardMatch.Index } else { -1 })
    foreach ($m in [regex]::Matches($Body, '(?<![A-Za-z0-9_$])if\s*\(')) {
        $parenAt = $Body.IndexOf('(', $m.Index)
        $cond = Get-YakuJsBalancedSpan -Text $Body -Start $parenAt -Open ([char]'(') -Close ([char]')')
        if ([string]::IsNullOrEmpty($cond)) { continue }
        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($k in [regex]::Matches($cond, "event\.key(?:\.toLowerCase\(\))?\s*===\s*'([^']+)'")) {
            $keys.Add((ConvertTo-YakuKeyDisplayName -Raw ([string]$k.Groups[1].Value))) | Out-Null
        }
        # 番号キーは範囲で書いてある（'1' 以上 '9' 以下）。両端がそろって初めて範囲。
        $bounds = @([regex]::Matches($cond, "event\.key\s*(?:<=|>=|<|>)\s*'([19])'") | ForEach-Object { [string]$_.Groups[1].Value })
        if (($bounds -contains '1') -and ($bounds -contains '9')) { $keys.Add('1-9') | Out-Null }
        if ($keys.Count -eq 0) { continue }
        $stripped = $cond -replace $guardPattern, '' -replace '!\s*event\.(?:ctrlKey|metaKey|altKey|shiftKey)', ''
        $mods = New-Object System.Collections.Generic.List[string]
        if (($stripped -match 'event\.(?:ctrlKey|metaKey)') -or ($guardAt -ge 0 -and $m.Index -gt $guardAt)) { $mods.Add('Ctrl') | Out-Null }
        if ($stripped -match 'event\.altKey') { $mods.Add('Alt') | Out-Null }
        if ($stripped -match 'event\.shiftKey') { $mods.Add('Shift') | Out-Null }
        foreach ($key in $keys) {
            $name = Format-YakuShortcutName -Modifiers $mods.ToArray() -Key $key
            if (-not $set.Contains($name)) { $set.Add($name) | Out-Null }
        }
    }
    return @($set.ToArray() | Sort-Object)
}
function Get-YakuHtmlShortcutSet {
    param([Parameter(Mandatory=$true)][string]$Html)
    $blockMatch = [regex]::Match($Html, '(?s)class="cat-key-help".*?<dl>(?<body>.*?)</dl>')
    if (-not $blockMatch.Success) { return @() }
    $set = New-Object System.Collections.Generic.List[string]
    foreach ($dt in [regex]::Matches([string]$blockMatch.Groups['body'].Value, '(?s)<dt>(?<inner>.*?)</dt>')) {
        $inner = [string]$dt.Groups['inner'].Value
        # 「/」で2つ並べた行がある（Alt+↑/↓、Alt+M / Alt+K）。閉じタグの中の
        # 「/」と紛れるので、要素の境目だけを割る。
        $marked = [regex]::Replace($inner, '</kbd>\s*/\s*<kbd>', ('</kbd>' + [char]0x1F + '<kbd>'))
        $carried = New-Object System.Collections.Generic.List[string]
        foreach ($part in ($marked -split [string][char]0x1F)) {
            $tokens = @([regex]::Matches($part, '(?s)<kbd>(?<k>.*?)</kbd>') | ForEach-Object { ([string]$_.Groups['k'].Value).Trim() })
            if ($tokens.Count -eq 0) { continue }
            $mods = New-Object System.Collections.Generic.List[string]
            $keys = New-Object System.Collections.Generic.List[string]
            foreach ($token in $tokens) {
                if (@('Ctrl','Alt','Shift') -contains $token) { $mods.Add($token) | Out-Null }
                else { $keys.Add((ConvertTo-YakuKeyDisplayName -Raw $token)) | Out-Null }
            }
            # 「Alt+↑/↓」の後ろ半分は修飾キーを書かない。同じ dt の前半から継ぐ。
            if ($mods.Count -eq 0 -and $carried.Count -gt 0) { foreach ($mod in $carried) { $mods.Add($mod) | Out-Null } }
            else { $carried.Clear(); foreach ($mod in $mods) { $carried.Add($mod) | Out-Null } }
            foreach ($key in $keys) {
                $name = Format-YakuShortcutName -Modifiers $mods.ToArray() -Key $key
                if (-not $set.Contains($name)) { $set.Add($name) | Out-Null }
            }
        }
    }
    return @($set.ToArray() | Sort-Object)
}

$yakuKeydownBody = Get-YakuJsKeydownBody -Js (Remove-YakuJsComments -Text $catJs)
Check-YakuUse ($yakuKeydownBody.Length -gt 500) ('画面全体の keydown ハンドラが取れる（実際 ' + $yakuKeydownBody.Length + ' 文字）')
$nativeActivationKeys = @('Enter', ' ')
$yakuJsKeys = @(Get-YakuJsShortcutSet -Body $yakuKeydownBody | Where-Object { $nativeActivationKeys -notcontains $_ })
$yakuHtmlKeys = @(Get-YakuHtmlShortcutSet -Html $catHtml)
Check-YakuUse ($catJs.Contains("bindFileDrop(el('quick-area'), el('cat-file-input'))") -and
    $catJs.Contains("event.key === 'Enter' || event.key === ' '") -and
    $catJs.Contains("drop.addEventListener('drop'")) '開始画面のファイル枠の Enter / Space は CAT ショートカット一覧へ混ぜない'
Write-Host ('  実装 (' + $yakuJsKeys.Count + '): ' + ($yakuJsKeys -join ', '))
Write-Host ('  一覧 (' + $yakuHtmlKeys.Count + '): ' + ($yakuHtmlKeys -join ', '))
# 取り出しが両方とも空なら「一致」は恒真になる。空でないことを先に押さえる。
Check-YakuUse ($yakuJsKeys.Count -ge 16) ('実装から16件以上のキーを取り出せている（実際 ' + $yakuJsKeys.Count + '）')
Check-YakuUse ($yakuHtmlKeys.Count -ge 16) ('一覧から16件以上のキーを取り出せている（実際 ' + $yakuHtmlKeys.Count + '）')
# 取り出しそのものが効いている証拠。修飾キー・記号・範囲・関数キーを1件ずつ。
foreach ($yakuKeyProbe in @('Ctrl+D','1-9','Ctrl+K','Ctrl+[','Alt+ArrowUp','Ctrl+Shift+S','F8','Esc')) {
    Check-YakuUse ($yakuJsKeys -contains $yakuKeyProbe) ('実装から ' + $yakuKeyProbe + ' を拾えている')
    Check-YakuUse ($yakuHtmlKeys -contains $yakuKeyProbe) ('一覧から ' + $yakuKeyProbe + ' を拾えている')
}
$yakuKeysOnlyInJs = @($yakuJsKeys | Where-Object { $yakuHtmlKeys -notcontains $_ })
$yakuKeysOnlyInHtml = @($yakuHtmlKeys | Where-Object { $yakuJsKeys -notcontains $_ })
Check-YakuUse ($yakuKeysOnlyInJs.Count -eq 0) ('一覧に載っていないキーが実装に無い（実際 ' + $yakuKeysOnlyInJs.Count + '件: ' + ($yakuKeysOnlyInJs -join ', ') + '）')
Check-YakuUse ($yakuKeysOnlyInHtml.Count -eq 0) ('実装に無いキーが一覧に載っていない（実際 ' + $yakuKeysOnlyInHtml.Count + '件: ' + ($yakuKeysOnlyInHtml -join ', ') + '）')

# 2026-08-13: この行を自分で消してしまい、赤が出ても緑と報告される状態を
# 1コミットぶん作った。判定を消したまま「41本緑」と言っていた。
if ($script:failed -gt 0) { Write-Host ('Usability tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Usability tests passed.' -ForegroundColor Green
