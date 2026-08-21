<#
.SYNOPSIS
  V91.61: 日英アライメントで Copilot へ渡す文の数値マスクの回帰テスト。

.DESCRIPTION
  社内ルールは「Copilot に機密情報を入れてよい。ただし未公開の財務情報は
  数字だけマスクする」。つまりマスクは便宜ではなく統制である。
  取りこぼしがそのまま情報漏れになるので、道具側の正しさを固定しておく。

  見るのは3つ。
   - 数を消せているか（半角・全角・漢数字・英語の綴り）
   - 消しすぎていないか（一部・一方・四半期・one of ... を壊さない）
   - 取りこぼしたときに送信が止まるか（fail closed）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161AlignMask.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'AlignMask.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

function MaskJa { param([string]$t) return (ConvertTo-YakuAlignmentMaskedText -Text $t -Language 'ja') }
function MaskEn { param([string]$t) return (ConvertTo-YakuAlignmentMaskedText -Text $t -Language 'en') }

Write-Host '日本語: 数を消す' -ForegroundColor Cyan
Chk ((MaskJa '生産設備等に122億円を投資しました') -eq '生産設備等に〔数〕円を投資しました') '億円の金額を消す（桁の漢字ごと）'
Chk ((MaskJa '売上高は1兆2,345億円') -eq '売上高は〔数〕円') '兆と億をまたぐ金額をひとつに潰す'
Chk ((MaskJa '営業利益率は１２．３％') -eq '営業利益率は〔数〕％') '全角の数字と小数点を消す'
Chk ((MaskJa '百二十二億円を投資') -eq '〔数〕円を投資') '漢数字の金額を消す'
Chk ((MaskJa '二〇二六年三月期') -eq '〔数〕年〔数〕月期') '漢数字の年月を消す'
Chk ((MaskJa '発行済株式総数は3,000,000株') -eq '発行済株式総数は〔数〕株') '桁区切りのある株数を消す'
Chk (-not ((MaskJa '前期比▲12.4%の減益となりました') -match '[0-9０-９]')) '符号つきの増減率を消す'

Write-Host '日本語: 消しすぎない' -ForegroundColor Cyan
Chk ((MaskJa '事業の一部を譲渡する一方で') -eq '事業の一部を譲渡する一方で') '一部・一方は数として扱わない'
Chk ((MaskJa '第3四半期の実績') -eq '第〔数〕四半期の実績') '四半期の四を消さない'
Chk ((MaskJa '十分な流動性を確保しています') -eq '十分な流動性を確保しています') '十分は数として扱わない'
Chk ((MaskJa '三菱商事との取引') -eq '三菱商事との取引') '固有名詞の漢数字を壊さない'

Write-Host '英語: 数を消す' -ForegroundColor Cyan
Chk ((MaskEn 'In North America, ¥12.2 billion was invested') -eq 'In North America, ¥[NUM] was invested') '桁語を金額へ吸収する'
Chk ((MaskEn 'Net sales were 3,501,499 million yen') -eq 'Net sales were [NUM] yen') '桁区切りの数を消す（桁語ごと）'
Chk ((MaskEn 'a loss of twelve point two billion yen') -eq 'a loss of [NUM] yen') '綴りの数を消す'
Chk ((MaskEn 'approximately one hundred thousand units') -eq 'approximately [NUM] units') '綴りの数（桁語つき）を消す'

Write-Host '英語: 消しすぎない' -ForegroundColor Cyan
Chk ((MaskEn 'one of the three pillars of our strategy') -eq '[NUM] of the [NUM] pillars of our strategy') '桁語のない cardinal も数として扱う'
Chk ((MaskEn 'The point is that quality matters') -eq 'The point is that quality matters') 'point 単独は数として扱わない'
Chk ((MaskEn 'one point to consider') -eq '[NUM] point to consider') '通常語の point は小数点として吸収しない'
Chk ([bool](Test-YakuAlignmentTextSafe -Lines @((MaskEn 'one point to consider')) -Language 'en').Safe) '通常語の point を残したマスクも検査を通る'

Write-Host '英語: 年度と ordinal' -ForegroundColor Cyan
$periodText = 'Period: FY2026 First Quarter'
$periodMasked = [string](@(Protect-YakuAlignmentLines -Lines @($periodText) -Language 'en')[0])
Chk ($periodMasked -eq 'Period: FY[NUM] [NUM] Quarter') 'FY年度と ordinal の数を同じtokenへ消す'

# CopilotClient の最終 receipt と同じ canonical scanner を通す。ここで
# MaskedCount が残れば PROTECTION_RECEIPT_PROTECTED_TEXT_NOT_MASKED になる。
. (Join-Path (Join-Path $root 'src') 'Translation.ps1')
$periodReceipt = New-YakuNumericMaskMap -Text $periodMasked -Root $root -Direction 'to_en' -Location 'test-alignment-protected-receipt' -AllowExistingTokens
Chk ([int]$periodReceipt.MaskedCount -eq 0) 'FY年度と ordinal の protected text は canonical rescan を通る'
$ordinaryPointMasked = [string](MaskEn 'one point to consider')
$ordinaryPointReceipt = New-YakuNumericMaskMap -Text $ordinaryPointMasked -Root $root -Direction 'to_en' -Location 'test-alignment-ordinary-point' -AllowExistingTokens
Chk ([int]$ordinaryPointReceipt.MaskedCount -eq 0) '通常語の point の protected text は canonical rescan を通る'
$decimalMasked = [string](MaskEn 'a loss of twelve point two billion yen')
$decimalReceipt = New-YakuNumericMaskMap -Text $decimalMasked -Root $root -Direction 'to_en' -Location 'test-alignment-decimal' -AllowExistingTokens
Chk ([int]$decimalReceipt.MaskedCount -eq 0) '数字語の小数の protected text は canonical rescan を通る'

Write-Host '検査: 残っていれば送らせない' -ForegroundColor Cyan
$ok = Test-YakuAlignmentTextSafe -Lines @('生産設備等に〔数〕円', '売上は〔数〕円') -Language 'ja'
Chk ([bool]$ok.Safe) 'マスク済みの並びは検査を通る'

$ng = Test-YakuAlignmentTextSafe -Lines @('売上は〔数〕円', '利益は45億円') -Language 'ja'
Chk (-not [bool]$ng.Safe) '数字が残っていれば検査に落ちる'
Chk (@($ng.Findings).Count -eq 1 -and [int](@($ng.Findings)[0].Index) -eq 1) '落ちた行の位置を返す'

$ngEn = Test-YakuAlignmentTextSafe -Lines @('sales of [NUM] yen', 'a gain of five million yen') -Language 'en'
Chk (-not [bool]$ngEn.Safe) '英語の綴りの数も検査で捕まえる'

Write-Host '経路: 例外で止まる' -ForegroundColor Cyan
$lines = @('生産設備等に122億円を投資しました', '売上高は1兆2,345億円')
# Protect- は , 付きで返すので @() で包まない。包むと配列が1要素に入れ子になる。
$masked = Protect-YakuAlignmentLines -Lines $lines -Language 'ja'
Chk ($masked.Count -eq 2 -and -not (($masked -join '') -match '[0-9０-９]')) '正常な並びはマスクして返す'
$properMaskedJa = Protect-YakuAlignmentLines -Lines @('マツダ株式会社は新工場を建設します') -Language 'ja' -Root $root
Chk (($properMaskedJa -join '') -match 'マツダ株式会社' -and ($properMaskedJa -join '') -notmatch '〔名〕') '日本語の固有名詞は送信可なので変更しない'
$properMaskedEn = Protect-YakuAlignmentLines -Lines @('Mazda Motor Corporation will build a new plant') -Language 'en' -Root $root
Chk (($properMaskedEn -join '') -match 'Mazda Motor Corporation' -and ($properMaskedEn -join '') -notmatch '\[NAME\]') '英語の固有名詞は送信可なので変更しない'

# マスクを故意に無力化して、検査が働くことを確かめる。
# 統制が「効いている」ことは、破ってみないと確かめられない。
function ConvertTo-YakuAlignmentMaskedText { param([AllowNull()][string]$Text, [string]$Language = 'ja') return [string]$Text }
$threw = $false
try { $null = Protect-YakuAlignmentLines -Lines $lines -Language 'ja' } catch { $threw = $true }
Chk $threw 'マスクが働かなければ例外で送信を止める'

if ($script:fail -gt 0) {
    Write-Host "V91.61 align mask regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 align mask regression passed.' -ForegroundColor Green
