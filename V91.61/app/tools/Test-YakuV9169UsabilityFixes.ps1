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

# 資料の側にも、外へ送ることと伏せることを書いた（2026-08-13 午前）。
# 同じ日の夕方に、それが原因で同じ文が1画面に2回出ていると分かった
# （実測 y438 と y680）。1つに寄せ、資料の話もその1行に含める。
# 開始画面は1枚なので、貼り付け欄の下にあれば取り込みボタンより前に必ず通る。
Check-YakuUse ($catHtml -match '資料は訳す文だけを送り、ファイルそのものは送りません') '資料のことも同じ1行で書く'
Check-YakuUse (([regex]::Matches($catHtml, '社名・人名・文章はそのまま送信されます')).Count -eq 1) '同じ文を1画面に2回出さない'
Check-YakuUse ($catHtml -match 'ファイルそのものは送りません') '送るのは文だけだと書く'

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
Check-YakuUse ($quickJs -match "detectedDirection === 'to_jp' \? '日本語に訳します'") '自動のときも、決まった向きを出す'
Check-YakuUse ($quickJs -notmatch "hidden = !text\.trim\(\) \|\| !explicitDirection") '自分で選んだときだけ出す作りに戻さない'

# 2026-08-13、初回利用者として実機を通して見つけたもの。

# 作った直後に「点検 2」を赤く出さない。中身は「訳文が空 2」で、まだ訳していない
# だけだった。何もしていない利用者に、いきなり欠陥の言い方をしていた。
# 同じ画面の「訳文を取り出す」は最初から「残り2行の訳案を作ってください。」と
# 正しく言っていたので、言い方はそちらへ揃える。1行でも訳ができれば指摘に戻る。
Check-YakuUse ($catJs -match 'function nothingTranslatedYet') 'まだ一度も訳していない状態を見分ける'
Check-YakuUse ($catJs -match '(?s)function qaFindings\(\)[\s\S]{0,600}?if \(nothingTranslatedYet\(\)\) return groups;') '訳す前は指摘を数えない'
Check-YakuUse ($catJs -match 'まだ訳していません。「訳していない行を訳す」を押すと') '点検一覧は次にやることを書く'

# 帯と行で、同じことを違う名前で呼んでいた（帯は「訳案」、行は「訳文」）。
# 範囲も帯の側だけ名乗っていなかった（2026-08-13、利用者の指摘
# 「パッと見て分かりにくいかも」）。並べて読めるように、範囲を名前へ入れる。
#   訳す   この行だけ訳す        / 訳していない行を訳す
#   コピー この行の訳文をコピー  / すべての訳文をコピー / 確認済みの行だけコピー
Check-YakuUse ($catHtml -match '>訳していない行を訳す</button>') 'まとめて訳すボタンが範囲を名乗る'
Check-YakuUse ($catJs -match "'すべての訳文をコピー'") 'まとめてコピーが範囲を名乗る'
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
# 中央へ寄せると押しただけで大きく飛ぶ。開いた欄はいちばん少ない移動で見せる。
Check-YakuUse ($catJs -match "(?s)function showStart\(mode\)[\s\S]{0,1200}?block: 'nearest'") '開いた欄は最小の移動で見せる'
Check-YakuUse ($catJs -notmatch "(?s)function showStart\(mode\) \{ closeStartPanels\(\); var panel[\s\S]{0,120}?YakuCommon\.focus\(") '中央へ寄せる作りに戻さない'

# 押せるボタンに「してください」と書かない。未確認が残っていても取り出せる決まりに
# した（2026-08-12）のに、押せる状態のまま「あと2行を確認済みにしてください。」と
# 出しており、命令に読めた。押せるボタンには起きることを書く。
Check-YakuUse ($catJs -match 'まだ確認していない.{0,20}行も、そのまま入ります。') '押せるときは、起きることを書く'
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
Check-YakuUse ($catHtml -match '<body class="app-cat"__YAKU_VIEW__>') '開いた瞬間の状態を差し込む口がある'
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
Check-YakuUse ($quickJs -match "detectedDirection === 'to_en' \? '英語に訳します'") '決まった向きそのものを出す'

# 「Word・Excelを取り込む」を押しても、下に欄が開くだけで何も起きないように見えた。
# その欄の中にもう一度「選ぶ」があり、さらに確認のボタンがあった（押す回数3回）。
Check-YakuUse ($catJs -match "el\('cat-open-file-entry'\)\.addEventListener\('click'[\s\S]{0,160}?cat-file-input'\)\.click\(\)") '取り込みボタンはファイル選択をそのまま開く'
Check-YakuUse ($catJs -match "(?s)cat-file-input'\)\.addEventListener\('change'[\s\S]{0,220}?openSource\('file', 'auto'\)") '選んだ時点で取り込みが始まる'
Check-YakuUse ($catHtml -notmatch 'Word・Excelを選ぶ' -and $catHtml -notmatch 'ここにファイルをドロップ') '同じことを言う欄を下に置かない'
Check-YakuUse ($catJs -match "(?s)function showStart\(mode\)[\s\S]{0,600}?if \(mode === 'file'\) \{ el\('cat-file-input'\)\.value = ''") '保存場所から取り込むときは、選び済みのファイルを忘れる'

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

# 2026-08-13: この行を自分で消してしまい、赤が出ても緑と報告される状態を
# 1コミットぶん作った。判定を消したまま「41本緑」と言っていた。
if ($script:failed -gt 0) { Write-Host ('Usability tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Usability tests passed.' -ForegroundColor Green
