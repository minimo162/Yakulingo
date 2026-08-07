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
Chk ((MaskEn 'one of the three pillars of our strategy') -eq 'one of the three pillars of our strategy') '桁語を含まない綴りは数として扱わない'
Chk ((MaskEn 'The point is that quality matters') -eq 'The point is that quality matters') 'point 単独は数として扱わない'

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
