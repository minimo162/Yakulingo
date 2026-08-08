<#
.SYNOPSIS
  V91.61: 固有名詞マスクの回帰テスト。

.DESCRIPTION
  人名・法人名・地名は正確さがすべてで、創造性が要らない。にもかかわらず
  読みが自明でないものが多く、Copilot に任せると揺れる（毛籠 → Kego、
  あずさ → Azusa など）。送る前に置き換え、返ってから戻すことで、
  Copilot の判断を通らないようにする（利用者の判断 2026-08-08）。

  見るのは4つ。
   - 長いものから当てること（「毛籠 勝弘」を「毛籠」より先に）
   - 同じ英語になる別表記を1つの記号にまとめること
   - 住所の全角数字が数値マスクより先に処理されること
   - 訳文から記号が消えたら気づけること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161ProperNoun.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'ProperNoun.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

Write-Host '一覧の読み込み' -ForegroundColor Cyan
$entries = @(Get-YakuProperNounEntries -Root $root)
Chk ($entries.Count -gt 0) '固有名詞の一覧を読める'
Chk (@($entries | Where-Object { $_.Source -eq '毛籠' -and $_.Target -eq 'Moro' }).Count -eq 1) '読みが自明でない姓が入っている'
# 長い順に並んでいないと、短いものが先に当たって半端な置換になる。
$lens = @($entries | ForEach-Object { ([string]$_.Source).Length })
$sorted = $true
for ($i = 1; $i -lt $lens.Count; $i++) { if ($lens[$i] -gt $lens[$i - 1]) { $sorted = $false; break } }
Chk $sorted '長いものから順に並んでいる'

Write-Host '置き換え' -ForegroundColor Cyan
$r = New-YakuProperNounMaskMap -Text '毛籠社長は、あずさ監査法人と協議しました。' -Root $root
Chk ($r.Text -notmatch '毛籠|あずさ') '固有名詞が残らない'
Chk ($r.Text -match '\[\[P\d+\]\]') '記号に置き換わる'
$back = Restore-YakuProperNounMask -Text $r.Text -Map $r.Map
Chk ($back -match 'Moro' -and $back -match 'KPMG AZSA LLC') '英語表記に戻る'

# 「毛籠 勝弘」が先に当たらないと「Moro 勝弘」になる。
$r2 = New-YakuProperNounMaskMap -Text '代表取締役社長 毛籠 勝弘' -Root $root
$back2 = Restore-YakuProperNounMask -Text $r2.Text -Map $r2.Map
Chk ($back2 -match 'Masahiro Moro') 'フルネームを先に当てる'
Chk ($back2 -notmatch '勝弘') '姓だけ置き換えて名が残ることがない'

# 同じ英語に落ちる別表記は1つの記号にまとめる。訳文で表記が割れないため。
$r3 = New-YakuProperNounMaskMap -Text 'あずさ監査法人と有限責任 あずさ監査法人' -Root $root
Chk (@($r3.Map.Keys).Count -eq 1) '同じ英語になる別表記は1つの記号にまとめる'

Write-Host '住所の全角数字' -ForegroundColor Cyan
# 数値マスクが先に走ると、住所の３や１が伏せられて照合が壊れる。
# だから固有名詞を先に処理する、という順序をここで固定する。
$r4 = New-YakuProperNounMaskMap -Text '本店は広島県安芸郡府中町新地３番１号にあります。' -Root $root
$back4 = Restore-YakuProperNounMask -Text $r4.Text -Map $r4.Map
Chk ($back4 -match 'Shinchi') '全角数字を含む住所も置き換わる'

Write-Host '触らない' -ForegroundColor Cyan
$r5 = New-YakuProperNounMaskMap -Text '当社は電動化を進めます。' -Root $root
Chk ($r5.Text -eq '当社は電動化を進めます。' -and $r5.MaskedCount -eq 0) '該当が無ければ変えない'
$r6 = New-YakuProperNounMaskMap -Text '' -Root $root
Chk ($r6.Text -eq '') '空文字でも落ちない'
Chk ((Restore-YakuProperNounMask -Text 'x' -Map $null) -eq 'x') '対応表が無くても落ちない'

Write-Host '抜けの検知' -ForegroundColor Cyan
$masked = '[[P1]] said so.'
$ok = Test-YakuProperNounMaskIntegrity -MaskedSource $masked -Translated '[[P1]] said so.' -Map @{ '[[P1]]' = 'Moro' }
Chk ([bool]$ok.Ok) '記号が残っていれば通す'
$ng = Test-YakuProperNounMaskIntegrity -MaskedSource $masked -Translated 'He said so.' -Map @{ '[[P1]]' = 'Moro' }
Chk (-not [bool]$ng.Ok -and @($ng.Missing).Count -eq 1) '記号が消えていれば気づく'

Write-Host '経路' -ForegroundColor Cyan
$tr = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Translation.ps1') -Raw -Encoding UTF8
Chk ($tr -match 'New-YakuProperNounMaskMap') 'テキスト経路が固有名詞を伏せる'
# 数値より先に伏せる。住所の全角数字を数値マスクに取られないため。
$pAt = $tr.IndexOf('New-YakuProperNounMaskMap')
$nAt = $tr.IndexOf("New-YakuNumericMaskMap -Text ([string]`$properResult.Text)")
Chk ($pAt -gt 0 -and $nAt -gt 0 -and $pAt -lt $nAt) '固有名詞を数値より先に伏せる'
$pb = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'PromptBuilder.ps1') -Raw -Encoding UTF8
Chk ($pb -match 'PROPER NOUN PLACEHOLDERS') '記号の扱いをプロンプトで説明する'

Write-Host '固有名詞の記号を数値マスクが壊さない' -ForegroundColor Cyan
# 固有名詞は数値より先に伏せるので、数値マスクへ来るときには [[P1]] が本文に居る。
# 保護しないと中の 1 が数字として伏せられ、[[P[[N2]]]] という壊れた形で送られる。
# 復元が数値→固有名詞の順なので偶然もとに戻り、今日まで気づかなかった
# （2026-08-08 に実際に確認）。偶然に頼ってよい話ではない。
foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'Settings.ps1', 'PromptBuilder.ps1', 'Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $mod)
}
$pnSrc = '営業利益は115.77億円、毛籠社長と青山専務が発表しました。'
$pnMasked = New-YakuProperNounMaskMap -Text $pnSrc -Root $root
$pnUnits = Convert-YakuNumericUnits -Text ([string]$pnMasked.Text) -Location 'test'
$pnNum = New-YakuNumericMaskMap -Text ([string]$pnUnits.Text) -Root $root -Direction 'to_en' -Location 'test'
Chk ([string]$pnNum.Text -match '\[\[P1\]\]') '[[P1]] がそのまま残る'
Chk ([string]$pnNum.Text -notmatch '\[\[P\[\[N') '[[P[[N2]]]] のような壊れた形にならない'
Chk ([int]$pnNum.MaskedCount -eq 1) '名前の中の数字を数えない（伏せた件数が水増しされない）'
$pnBack = Restore-YakuProperNounMask -Text (Restore-YakuNumericMask -Text ([string]$pnNum.Text) -Map $pnNum.Map) -Map $pnMasked.Map
Chk ($pnBack -match 'Moro' -and $pnBack -match 'Aoyama') '2人とも戻る'
Chk ($pnBack -match '115\.77') '数値も戻る'

Write-Host '数値が無い文でも固有名詞を戻す' -ForegroundColor Cyan
# 「毛籠社長が就任しました。」には数字が1つも無い。数値マスクが空になるが、
# それを理由に復元ごと打ち切っていたため、画面へ [[P1]] が出ていた
# （2026-08-08 に再現）。片方だけあるほうが普通である。
foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'Settings.ps1', 'PromptBuilder.ps1', 'Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $mod)
}
function NewOpt { param([string]$Text) return [pscustomobject]@{ Style = 'full'; Label = 'そのまま'; Translation = $Text } }

$onlyProper = @(Restore-YakuMaskedTranslationOptions -Options @(NewOpt '[[P1]] was appointed president.') -MaskedSource '[[P1]]が社長に就任しました。' -Map @{} -ProperMap @{ '[[P1]]' = 'Moro' } -Warnings $null -Location 'test')
Chk ($onlyProper[0].Translation -eq 'Moro was appointed president.') '数値マスクが空でも固有名詞を戻す'
Chk ($onlyProper[0].Translation -notmatch '\[\[P\d+\]\]') '記号が画面へ出ない'
Chk ($onlyProper[0].MaskedTranslation -match '\[\[P1\]\]') 'マスク後の姿は控えておく（修正の依頼で使う）'

$both = @(Restore-YakuMaskedTranslationOptions -Options @(NewOpt '[[P1]] reported [[N1]] oku.') -MaskedSource '[[P1]]は[[N1]] okuと発表した。' -Map @{ '[[N1]]' = '11,577' } -ProperMap @{ '[[P1]]' = 'Moro' } -Warnings $null -Location 'test')
Chk ($both[0].Translation -eq 'Moro reported 11,577 oku.') '両方あるときは両方戻す'

$onlyNum = @(Restore-YakuMaskedTranslationOptions -Options @(NewOpt 'Sales were [[N1]] oku.') -MaskedSource '売上高は[[N1]] okuでした。' -Map @{ '[[N1]]' = '11,577' } -ProperMap $null -Warnings $null -Location 'test')
Chk ($onlyNum[0].Translation -eq 'Sales were 11,577 oku.') '固有名詞が無いときも数値は戻る'

Write-Host '直す経路も固有名詞を通す' -ForegroundColor Cyan
# 直すたびに人名が素のまま外へ出ていた。翻訳経路と同じ順序で掛ける。
$rev = $tr.IndexOf('text-revise')
$revBlock = $tr.Substring([Math]::Max(0, $rev - 1200), 1600)
Chk ($revBlock -match 'New-YakuProperNounMaskMap') '直す経路も原文を固有名詞マスクしてから送る'
Chk ($tr -match "Map \`$maskMap -ProperMap \`$properMap -Warnings \`$Warnings -Location 'text-revise'") '直した訳文の復元にも固有名詞の表を渡す'

if ($script:fail -gt 0) {
    Write-Host "V91.61 proper noun regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 proper noun regression passed.' -ForegroundColor Green
