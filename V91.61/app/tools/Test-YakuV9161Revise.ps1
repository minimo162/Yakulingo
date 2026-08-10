<#
.SYNOPSIS
  V91.61: 修正の依頼（原文＋現訳＋指示）の回帰テスト。

.DESCRIPTION
  利用者の使い方は「一文を訳す → 目で見る → 何度か直す → 確定」である
  （利用者の説明 2026-08-06）。従来のアプリにはこの「直す」が無く、
  直したければ原文を書き換えて訳し直すしかなかった。それでは直していない
  箇所まで毎回変わるので、確定へ向かって収束しない。

  ここで確かめるのは3つ。
   - 規則集を送っていないこと（送ると指示が埋もれ、触っていない箇所が変わる）
   - 原文と現訳と指示が、取り違えようのない形で入っていること
   - 画面へ出す訳文（実値入り）ではなく、マスク後の訳文を送る作りであること

  Copilot への往復は行わない。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161Revise.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$rid = 'deadbeefdeadbeefdeadbeefdeadbeef'
$src = '当第1四半期の営業利益は前年同期比20億円の増益となりました。'
$cur = 'Q1 OP up 20 oku YoY.'
$ins = '営業利益は Operating profit と綴ってください。'

# ---------------------------------------------------------------- 規則集を送らない
# 現訳はすでに規則を通って出てきたものである。同じ規則をもう一度送れば、
# モデルは20字の指示ではなく5,500字の規則へ引っ張られ、触っていない箇所まで変わる。
Write-Host '修正の依頼に規則集を入れない'
$b = New-YakuRevisePrompt -Root $root -InputText $src -CurrentText $cur -Instruction $ins -Direction 'to_en' -Style 'brief' -RequestId $rid
$p = [string]$b.Prompt
$brief = (New-YakuTextPrompt -Root $root -InputText $src -Settings (Read-YakuSettings -Root $root) -DirectionOverride 'to_en' -RequestId $rid -Mode 'brief').Prompt
Chk ($p -notmatch 'B1\. Drop articles') '電文体の規則 B1-B7 を送らない'
Chk ($p -notmatch 'ABBREVIATIONS') '略語の一覧を送らない'
Chk ($p -notmatch 'EXAMPLES \(SOURCE') '文例を送らない'
Chk ($p.Length -lt ($brief.Length / 2)) ('翻訳の依頼の半分より短い: 修正 ' + $p.Length + ' 字 / 翻訳 ' + $brief.Length + ' 字')
# 文体だけは一行で示す。無いと電文体が散文へ戻る。
Chk ($p -match 'telegraphic line') '文体は一行の注記で示す'
Chk ($p -notmatch '\{\w+\}') '差し込み口が残らない'

# ---------------------------------------------------------------- 3つの入力
Write-Host '原文・現訳・指示が取り違えようのない形で入る'
Chk ($p -match ('SOURCE_BEGIN:' + $rid)) '原文の囲みがある'
Chk ($p -match ('CURRENT_BEGIN:' + $rid)) '現訳の囲みがある'
Chk ($p -match ('INSTRUCTION_BEGIN:' + $rid)) '指示の囲みがある'
Chk ($p -match [regex]::Escape($src)) '原文が入る'
Chk ($p -match [regex]::Escape($cur)) '現訳が入る'
Chk ($p -match [regex]::Escape($ins)) '指示が入る'
# 事実を落とす指示は断らせる。原文を送るのはこのためである。
Chk ($p -match 'SOURCE is the authority on facts') '事実は原文が優先されると伝える'
Chk ($p -match 'return CURRENT unchanged') '当てられない指示なら現訳のまま返させる'

# ---------------------------------------------------------------- 求めるラベル
Write-Host '求めるラベルは現訳の種類で決まる'
Chk ((New-YakuRevisePrompt -Root $root -InputText $src -CurrentText $cur -Instruction $ins -Direction 'to_en' -Style 'full' -RequestId $rid).Label -eq 'FULL_TEXT') '完全訳の修正は FULL_TEXT'
Chk ((New-YakuRevisePrompt -Root $root -InputText $src -CurrentText $cur -Instruction $ins -Direction 'to_en' -Style 'brief' -RequestId $rid).Label -eq 'BRIEF_TEXT') '電文体の修正は BRIEF_TEXT'
Chk ((New-YakuRevisePrompt -Root $root -InputText 'Operating profit rose.' -CurrentText '営業利益は増加した。' -Instruction 'です・ます調にしてください。' -Direction 'to_jp' -RequestId $rid).Label -eq 'JAPANESE_TEXT') 'EN→JA は JAPANESE_TEXT'
$pFull = (New-YakuRevisePrompt -Root $root -InputText $src -CurrentText $cur -Instruction $ins -Direction 'to_en' -Style 'full' -RequestId $rid).Prompt
Chk ($pFull -match 'no compression') '完全訳の修正では圧縮させない'
Chk ($pFull -notmatch 'telegraphic line') '完全訳の修正に電文体の注記を出さない'

# ---------------------------------------------------------------- 伏せた数値
# トークンは原文と現訳の両方に居る。扱いを示さないと書き換えられ、実値へ戻せなくなる。
Write-Host '伏せた数値の規則だけは残す'
$pMask = (New-YakuRevisePrompt -Root $root -InputText '営業利益は[[N1]]億円でした。' -CurrentText 'OP [[N1]] oku.' -Instruction '短くしてください。' -Direction 'to_en' -Style 'brief' -RequestId $rid).Prompt
Chk ($pMask -match 'NUMBER PLACEHOLDERS') 'トークンがあれば扱いを示す'
Chk ($p -notmatch 'NUMBER PLACEHOLDERS') 'トークンが無ければ出さない'

# ---------------------------------------------------------------- マスク後の訳文を運ぶ
# 画面の訳文は実値へ戻した後のもの。そのまま送り返させると、伏せた数値が外へ出る。
Write-Host 'マスク後の訳文を札に載せる'
$masked = @([pscustomobject]@{ Style='brief'; Label='電文体'; Translation='OP [[N1]] oku.' })
$restored = @(Restore-YakuMaskedTranslationOptions -Options $masked -MaskedSource '営業利益は[[N1]]億円。' -Map @{ '[[N1]]' = '20' } -Warnings $null -Location 'test')
Chk ([string]$restored[0].Translation -eq 'OP 20 oku.') '画面へは実値へ戻した訳文を出す'
Chk ([string]$restored[0].MaskedTranslation -eq 'OP [[N1]] oku.') '送り返す用にマスク後の訳文を控える'
# マスクを切っていても同じ形にする。呼び出し側が分岐しなくて済む。
$noMask = @([pscustomobject]@{ Style='full'; Label='完全訳'; Translation='OP up 20 oku.' })
$noMask = @(Restore-YakuMaskedTranslationOptions -Options $noMask -MaskedSource '' -Map @{} -Warnings $null -Location 'test')
Chk ([string]$noMask[0].MaskedTranslation -eq 'OP up 20 oku.') 'マスクが無いときは訳文と同じ'

# ---------------------------------------------------------------- 画面
Write-Host '画面の作り'
$result = [pscustomobject]@{
    Direction='to_en'; SourceText=$src; InputLength=$src.Length; Warnings=@()
    Options=@([pscustomobject]@{ Style='brief'; Label='電文体'; Translation='OP 20 oku.'; MaskedTranslation='OP [[N1]] oku.' })
}
$html = Convert-YakuTextResultToHtml -Result $result -IncludeStatusOob:$false
# 修正の依頼口は「すぐ訳す」から外した。直すのは「見比べて訳す」の役目にする
# （利用者の方針 2026-08-08「簡易翻訳は簡易翻訳、CAT は CAT でベストにする」）。
# 直す機能が両方にあると、どちらでやるべきか毎回考えることになる。
Chk (-not ($html -match 'data-yaku-revise')) 'すぐ訳すには修正の依頼口を置かない'
$quickClientText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\quick.js'))
Chk ($quickClientText.Contains('/api/cat/promote')) '直したいときはserver artifactから資料翻訳へ移れる'
# 内部の英字ラベルを画面に出さない。利用者が読む言葉にする。
Chk (-not ($html -match '>FULL<|>BRIEF<')) '内部の英字ラベルを画面に出さない'
Chk (-not ($html -match 'STYLE_REFERENCE')) 'プロンプト内部の語を画面に出さない'
Chk (-not ($html -match 'ユーザー入力:')) '入力字数を二度出さない'
# 修正の依頼口を外したので、マスク後の現訳を持ち回る札も無くなった。
# 代わりに確かめるのは「実値の訳文を Copilot へ送り返す札が無いこと」。
# CAT へ渡す札は実値を持つが、これは画面に並べるためで外へは出ない。
# CAT が Copilot へ送るのは訳文が空の行だけである。
$realB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('OP 20 oku.'))
Chk (-not ($html -match "data-yaku-current='$([regex]::Escape($realB64))'")) '実値の現訳を送信用の札に載せない'
# 実値の入った訳文は data-yaku-current に載らないこと。
# （コピーボタンには載る。あれは画面に出ている訳文を写すためのもので、
#   Copilot へは送らない。ここで見たいのは送る側だけである。）
$realB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('OP 20 oku.'))
Chk ($html -notmatch ("data-yaku-current='" + [regex]::Escape($realB64))) '送る現訳に実値の訳文を載せない'
# 原文が無ければ依頼口を出さない。突き合わせる相手がいない。
$noSource = [pscustomobject]@{ Direction='to_en'; InputLength=0; Warnings=@(); Options=@([pscustomobject]@{ Style='full'; Label='完全訳'; Translation='x' }) }
Chk ((Convert-YakuTextResultToHtml -Result $noSource -IncludeStatusOob:$false) -notmatch 'data-yaku-revise') '原文が無ければ依頼口を出さない'
# 訳した時の原文を結果に固定する。入力欄から取り直すと、書き換えられた後に
# 「別の原文と現訳」を突き合わせることになる。
$translationText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Translation.ps1'))
Chk ($translationText.Contains('SourceText = [string]$InputText')) '翻訳結果が原文を持つ'
$appJs = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\cat.js'))
Chk ($appJs.Contains("mode: 'revise'") -and $appJs.Contains('data-cat-revise')) '資料翻訳の現在行から修正を依頼できる'
Chk (-not $appJs.Contains('data-yaku-current')) 'ブラウザー属性へ現訳を複製せず、保存済みproject revisionを使う'

if ($script:fail -gt 0) {
    Write-Host "V91.61 revise regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 revise regression passed.' -ForegroundColor Green
