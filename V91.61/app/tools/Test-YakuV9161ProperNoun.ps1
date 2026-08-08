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

if ($script:fail -gt 0) {
    Write-Host "V91.61 proper noun regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 proper noun regression passed.' -ForegroundColor Green
