<#
.SYNOPSIS
  V91.61: 訳文を短くする経路の回帰テスト。

.DESCRIPTION
  短くするのは「訳し直し」ではなく「できた英文からの圧縮」である。
  原文→BRIEF を並べて頼むと圧縮が日本語照合になり、実測で圧縮率が
  用語集のカバー有無で 0.55 と 0.75 に割れていた（要件整理 §5-A）。
  できた英文から縮めれば、この語彙依存は原理的に消える。

  そして押されたときだけ走る。Copilot は120回ほどで応答しなくなるので、
  毎回2本作れば使える文の数が半分になる。

  ここで見るのは3つ。
   - 門が効くこと（プロンプトの指示は保証にならない。守らせるのは検査だけ）
   - マスク後の訳文しか送らないこと
   - 既定では余分な往復を使わないこと

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161Shorten.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'Settings.ps1',  'PromptBuilder.ps1', 'Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $mod)
}
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

$cur = "Net sales amounted to [[N1]] oku, an increase of [[N2]] oku." + [Environment]::NewLine + "Operating income was [[N3]] oku."

Write-Host '門（プロンプトの指示は保証にならないので、アプリ側で見る）' -ForegroundColor Cyan

$ok = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened ("Net sales [[N1]] oku, up [[N2]] oku." + [Environment]::NewLine + "Operating income [[N3]] oku.")
Chk ([string]::IsNullOrEmpty($ok)) '正しく短くしたものは通す'

$merged = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened 'Net sales [[N1]] oku, up [[N2]] oku; operating income [[N3]] oku.'
Chk ($merged -match '行の数') '行を統合したら弾く（見出しや箇条書きが潰れる）'

$dropped = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened ("Net sales [[N1]] oku, up." + [Environment]::NewLine + "Operating income [[N3]] oku.")
Chk ($dropped -match '数値') '数値が落ちたら弾く（短い訳ではなく事実が欠けた訳）'

# 最も危険な壊れ方。個数は合うので、並べ替えて比べると通ってしまう。
# 復元すると営業利益の欄に売上高の数字が入る。
$swapped = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened ("Net sales [[N2]] oku, up [[N1]] oku." + [Environment]::NewLine + "Operating income [[N3]] oku.")
Chk ($swapped -match '数値') '数値が入れ替わったら弾く（個数だけ見ていると通る）'

$longer = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened ("Net sales amounted to [[N1]] oku, representing an increase of [[N2]] oku over the prior period here." + [Environment]::NewLine + "Operating income for the period was [[N3]] oku in total.")
Chk ($longer -match '短くなっていません') '長くなったら弾く（押した意味が無い）'

$same = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened $cur
Chk ([string]::IsNullOrEmpty($same)) '同じまま返すのは正しい答え（これ以上短くできない）'

$empty = Test-YakuShortenResult -MaskedCurrentText $cur -Shortened ''
Chk ($empty -match '空') '空の応答を弾く'

Write-Host 'マスク後の訳文しか送らない' -ForegroundColor Cyan
$trSrc = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Translation.ps1') -Raw -Encoding UTF8
$fn = [regex]::Match($trSrc, '(?s)function Invoke-YakuTextShorten \{.*?\n\}\r?\n').Value
Chk ($fn.Length -gt 0) '短くする経路が見つかる'
Chk ($fn -match 'MaskedCurrentText') '受け取る引数の名前がマスク後であることを示している'
Chk ($fn -match 'SHORTEN_UNMASKED_CURRENT') '実値入りの訳文を渡されたら例外を投げる'
$nAt = $fn.IndexOf('New-YakuNumericMaskMap')
$sAt = $fn.IndexOf('Invoke-YakuProtectedCopilotPrompt')
Chk ($nAt -ge 0 -and $sAt -ge 0 -and $nAt -lt $sAt) '数値マスク→送信の順'
Chk ($fn -notmatch 'ProperNounMask|ProperMap|\[\[P') '短くする経路は固有名詞をマスクしない'
$gateAt = $fn.IndexOf('Test-YakuShortenResult')
$restoreAt = $fn.IndexOf('Restore-YakuMaskedTranslationOptions')
Chk ($gateAt -ge 0 -and $restoreAt -ge 0 -and $gateAt -lt $restoreAt) '門を通してから実値へ戻す'
Chk ($fn -match 'Convert-YakuBriefTranslationOptions') '略語はアプリが後から当てる'
$abbrAt = $fn.IndexOf('Convert-YakuBriefTranslationOptions')
Chk ($abbrAt -gt $sAt) '略語を当てるのは送信より後（先に渡すとモデルが展開する）'

# 実値入りの訳文を渡したら本当に止まるか。条件が発火するかを一度確かめる。
$threw = $false
try {
    $null = Invoke-YakuTextShorten -Root $root -InputText '売上高は11,577億円でした。' -MaskedCurrentText 'Net sales were 11,577 oku.' -Settings ([pscustomobject]@{}) -ProgressState $null -Warnings $null
} catch {
    $threw = ([string]$_.Exception.Message -match 'SHORTEN_UNMASKED_CURRENT')
}
Chk $threw '実値入りの訳文を渡すと、送信する前に止まる'

Write-Host '既定では余分な往復を使わない' -ForegroundColor Cyan
Chk ($trSrc -match "Invoke-YakuSingleTranslationBatch[\s\S]*-Mode 'full'") '既定の依頼は1本だけ（短くするのは押されたときだけ）'
Chk ($trSrc -notmatch 'Invoke-YakuTextRequestsInParallel|YAKULINGO_PARALLEL') '休眠中の並列経路が残っていない'
$htmlSrc = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Html.ps1') -Raw -Encoding UTF8
Chk ($htmlSrc -notmatch 'data-yaku-shorten') '旧HTML結果にも短縮導線を残さない'
$quickJs = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'quick.js') -Raw -Encoding UTF8
Chk ($quickJs -notmatch 'shorten|/api/shorten-text') 'ちょっと翻訳は1本の訳案に絞り、短縮操作を出さない'
$srvSrc = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
# 誰も呼ばない入口の存在を固定していた（/api/shorten-text は www から参照0件だった）。
# 守りたいのは入口の有無ではなく「短縮は資料翻訳にだけあり、ちょっと翻訳には無い」。
$catJs = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www/assets') 'cat.js') -Raw -Encoding UTF8
Chk ($srvSrc -notmatch "'/api/shorten-text'") '誰も呼ばない旧入口を残さない'
Chk ($catJs -notmatch 'data-cat-shorten' -and $catJs -match 'publication-candidates' -and $catJs -match 'publication-apply') '単一指示の短縮UIを廃止し、非変更の掲載候補と人の採用へ分離する'
Chk ($srvSrc -match "SHORTEN_REJECTED") '門で弾いた理由を利用者へ伝える'

Write-Host 'プロンプト' -ForegroundColor Cyan
$built = New-YakuShortenPrompt -Root $root -InputText '売上高は[[N1]] okuでした。' -CurrentText 'Net sales were [[N1]] oku.'
Chk ($built.Prompt -match 'BRIEF_TEXT') '求めるラベルが入る'
Chk ($built.Prompt -match 'CURRENT is a finished English translation') '訳し直しではなく編集だと伝えている'
Chk ($built.Prompt -match 'Returning CURRENT unchanged is a correct answer') '無変更が正解だと伝えている（何か変えたくなるのを抑える）'
Chk ($built.Prompt -match 'DO NOT ABBREVIATE') '略語を使わないよう伝えている'
Chk ($built.Prompt -match '\[\[N1\]\]') 'プレースホルダーはそのまま渡す'
# 日本語そのものは送ってよい（社内ルールで伏せるのは数値だけ）。
# 見るのは「実値が混ざっていないか」である。渡したものをそのまま
# 差し込んでいることを確かめる。
$withValue = New-YakuShortenPrompt -Root $root -InputText '売上高は[[N1]] okuでした。' -CurrentText 'Net sales were [[N1]] oku.'
Chk ($withValue.Prompt -match '売上高は\[\[N1\]\] oku') '渡したマスク後の原文をそのまま差し込む'
Chk ($withValue.Prompt -notmatch '11,577') '実値は入らない'
# 圧縮の手口は渡すが、電文体の規則集を丸ごと再掲しているわけではないこと。
# 既に良い訳が入力なのに規則を全部見せると、一から作り直しを誘発する。
Chk ($built.Prompt -match 'HOW TO COMPRESS') '圧縮の手口は渡す'
Chk ($built.Prompt -notmatch 'FULL_TEXT') '完全訳の契約は持ち込まない（求めるのは1本だけ）'

if ($script:fail -gt 0) {
    Write-Host "V91.61 shorten regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 shorten regression passed.' -ForegroundColor Green
