<#
.SYNOPSIS
  V91.61: Copilot による日英アライメントの、送信前後の処理の回帰テスト。

.DESCRIPTION
  Copilot の応答そのものは実機でしか確かめられない。ここで固定するのは、
  応答を受けたあとに効く門のほうである。

   - 数値の照合が単位換算を跨げるか
     （122億円 と ¥12.2 billion を一致と見なせるか）
     字面で比べると、単位換算のある対を全部「不一致」と誤判定する。
     実際にそれで「4割誤り」という誤った結論を出した。同じ穴を塞ぐ。
   - 捏造・順序の乱れ・重複使用を落とせるか
   - 50行ずつの切り出しが、重なりを持って全体を覆うか

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161Alignment.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'Alignment.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

Write-Host '数値の取り出し' -ForegroundColor Cyan
$v = @(Get-YakuAlignmentNumbers -Text '生産設備等に122億円を投資しました' -Language 'ja')
Chk ($v -contains [decimal]12200000000) '億円を実数に直す'
$v = @(Get-YakuAlignmentNumbers -Text '売上高は1兆2,345億円' -Language 'ja')
Chk ($v -contains [decimal]1000000000000 -and $v -contains [decimal]1234500000000) '兆と億をそれぞれ実数に直す'
$v = @(Get-YakuAlignmentNumbers -Text '営業利益率は１２．３％' -Language 'ja')
Chk ($v -contains [decimal]12.3) '全角の数字と小数点を読む'
$v = @(Get-YakuAlignmentNumbers -Text '¥12.2 billion was invested' -Language 'en')
Chk ($v -contains [decimal]12200000000) 'billion を実数に直す'
$v = @(Get-YakuAlignmentNumbers -Text 'Net sales were 3,501,499 million yen' -Language 'en')
Chk ($v -contains [decimal]3501499000000) '桁区切りのある million を読む'

Write-Host '数値の照合' -ForegroundColor Cyan
$r = Test-YakuAlignmentNumbersAgree -JaText '北米では、生産設備等に122億円を投資しました' -EnText 'In North America, ¥12.2 billion was invested in production facilities'
Chk ([bool]$r.Checked -and [bool]$r.Agree) '単位換算を跨いで一致と判定する'

$r = Test-YakuAlignmentNumbersAgree -JaText '売上高は3,501,499百万円' -EnText 'Net sales were 3,501,499 million yen'
Chk ([bool]$r.Agree) '同じ単位ならそのまま一致する'

$r = Test-YakuAlignmentNumbersAgree -JaText '投資額は122億円' -EnText 'The figure was ¥45.6 billion'
Chk ([bool]$r.Checked -and -not [bool]$r.Agree) '本当に食い違う対は落とす'

$r = Test-YakuAlignmentNumbersAgree -JaText '2026年3月31日現在' -EnText 'As of March 31, 2026'
Chk (-not [bool]$r.Checked) '日付だけの対は判定しない'

$r = Test-YakuAlignmentNumbersAgree -JaText '当社は電動化を進めます' -EnText 'We will advance electrification'
Chk (-not [bool]$r.Checked) '数値の無い対は判定しない'

Write-Host '応答の検分' -ForegroundColor Cyan
$raw = @'
[[ID:1]] 1. J00+J01 | E00
[[ID:2]] 2. J02 | E01+E02
[[ID:3]] 3. J03 | E03
'@
$res = ConvertFrom-YakuAlignmentResponse -Raw $raw -JaCount 4 -EnCount 4
Chk (@($res.Pairs).Count -eq 3) '正しい応答から対を取り出す'
Chk ([Math]::Abs([double]$res.JaCoverage - 1.0) -lt 0.001) '網羅率を返す'

$raw = "[[ID:1]] 1. J00 | E00`n[[ID:2]] 2. J99 | E01"
$res = ConvertFrom-YakuAlignmentResponse -Raw $raw -JaCount 4 -EnCount 4
Chk (@($res.Pairs).Count -eq 1 -and @($res.Rejects)[0].Reason -eq 'range') '範囲外の番号（捏造）を落とす'

$raw = "[[ID:1]] 1. J02 | E02`n[[ID:2]] 2. J00 | E00"
$res = ConvertFrom-YakuAlignmentResponse -Raw $raw -JaCount 4 -EnCount 4
Chk (@($res.Pairs).Count -eq 1 -and @($res.Rejects)[0].Reason -eq 'order') '順序が戻る対を落とす'

$raw = "[[ID:1]] 1. J00 | E00`n[[ID:2]] 2. J00+J01 | E01"
$res = ConvertFrom-YakuAlignmentResponse -Raw $raw -JaCount 4 -EnCount 4
Chk (@($res.Pairs).Count -eq 1 -and @($res.Rejects)[0].Reason -eq 'duplicate') '同じ番号を二度使う対を落とす'

Write-Host '切り出し' -ForegroundColor Cyan
$c = @(Split-YakuAlignmentChunks -Count 30 -MaxLines 50 -Overlap 5)
Chk ($c.Count -eq 1 -and $c[0].Start -eq 0 -and $c[0].End -eq 29) '50行に満たなければ切らない'

$c = @(Split-YakuAlignmentChunks -Count 120 -MaxLines 50 -Overlap 5)
$covered = @{}
foreach ($x in $c) { for ($i = $x.Start; $i -le $x.End; $i++) { $covered[$i] = $true } }
Chk ($covered.Count -eq 120) '全部の行がどれかの塊に入る'
Chk (@($c | Where-Object { ($_.End - $_.Start + 1) -gt 50 }).Count -eq 0) 'どの塊も50行を超えない'
Chk ($c[1].Start -eq ($c[0].End + 1 - 5)) '隣り合う塊が5行重なる'
Chk ($c[-1].End -eq 119) '最後の行まで届く'

if ($script:fail -gt 0) {
    Write-Host "V91.61 alignment regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 alignment regression passed.' -ForegroundColor Green
