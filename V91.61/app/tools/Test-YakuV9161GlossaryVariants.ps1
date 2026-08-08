<#
.SYNOPSIS
  V91.61: 置換表の項目から期をずらした版を作る仕組みの回帰テスト。

.DESCRIPTION
  ECM の項目名には期が入り、シート名も四半期で変わる
  （利用者の説明 2026-08-06）。最新の四半期から置換表を採ると、
  次の四半期には当たらなくなる。期の部分だけが違う同じ項目なのに、
  毎回採り直すことになる。

  「Q1 を含むものは Q2 版も、FY26 を含むものは FY27 版も用意しておく」
  （利用者の指示 2026-08-06）。

  いちばん確かめたいのは**作らない条件**である。片側だけを書き換えると、
  対応していない対が完全一致で当たり続ける。誤りを増やす道具になる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161GlossaryVariants.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'GlossaryVariants.ps1')
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }
function V { param([string]$s,[string]$t) @(Get-YakuGlossaryPeriodVariants -Source $s -Target $t) }
function Has { param($Vs,[string]$s,[string]$t) return (@($Vs | Where-Object { [string]$_.Source -eq $s -and [string]$_.Target -eq $t }).Count -eq 1) }

# ---------------------------------------------------------------- 四半期
Write-Host '四半期をずらす'
$q = V 'Q1 営業利益' 'Q1 OP'
Chk ($q.Count -eq 3) ('Q1 から Q2/Q3/Q4 の3件: ' + $q.Count)
Chk (Has $q 'Q2 営業利益' 'Q2 OP') 'Q2 版ができる'
Chk (Has $q 'Q4 営業利益' 'Q4 OP') 'Q4 版ができる'
Chk (-not (Has $q 'Q1 営業利益' 'Q1 OP')) '元と同じものは作らない'
# 日本語と英語で書き方が違っても、同じ期を指していれば同族として扱う。
$q2 = V '第1四半期の営業利益' 'Q1 OP'
Chk ($q2.Count -eq 3) ('第1四半期 と Q1 を同族として扱う: ' + $q2.Count)
Chk (Has $q2 '第3四半期の営業利益' 'Q3 OP') '両側の書き方をそのまま保って番号だけ変える'
# 1Q / 3Q 表記
$q3 = V '1Q 販売台数' '1Q volume'
Chk (Has $q3 '2Q 販売台数' '2Q volume') '1Q 表記も扱う'

# ---------------------------------------------------------------- 半期
Write-Host '半期をずらす'
$h = @(V '上期 仕向地別営業利益' '1H OP by Market')
Chk ($h.Count -eq 1) ('上期 から下期の1件: ' + $h.Count)
Chk (Has $h '下期 仕向地別営業利益' '2H OP by Market') '上期/下期 と 1H/2H を対で扱う'
$h2 = V '下期 販売実績' '2H sales'
Chk (Has $h2 '上期 販売実績' '1H sales') '逆向きも作る'

# ---------------------------------------------------------------- 年度
Write-Host '年度をずらす'
$f = @(V 'FY26 営業利益' 'FY26 OP')
Chk ($f.Count -eq 1) ('年度は次の1つだけ: ' + $f.Count)
Chk (Has $f 'FY27 営業利益' 'FY27 OP') 'FY26 -> FY27'
Chk (Has (V 'FY2026 計画' 'FY2026 plan') 'FY2027 計画' 'FY2027 plan') '4桁でも桁の幅を保つ'
Chk (Has (V 'FY26/3 実績' 'FY26/3 act.') 'FY27/3 実績' 'FY27/3 act.') 'FY26/3 のような形も扱う'
Chk (Has (V '2026年度 販売計画' 'FY2026 sales plan') '2027年度 販売計画' 'FY2027 sales plan') '和暦表記と FY を同族として扱う'
Chk (Has (V '2026年3月期 連結' 'FY2026 consolidated') '2027年3月期 連結' 'FY2027 consolidated') '2026年3月期 の月を保つ'

# ---------------------------------------------------------------- 作らない条件（本題）
Write-Host '作ってはいけない場合'
# 片側だけを書き換えると、対応していない対が完全一致で当たり続ける。
Chk ((V 'Q1 営業利益' '営業利益').Count -eq 0) '訳文に期が無ければ作らない'
Chk ((V '営業利益' 'Q1 OP').Count -eq 0) '原文に期が無ければ作らない'
Chk ((V '営業利益' 'OP').Count -eq 0) '両方に期が無ければ何も作らない'
# 期が食い違っていれば、元の対そのものを疑うべきである。増やしてはならない。
Chk ((V 'Q1 営業利益' 'Q2 OP').Count -eq 0) '原文と訳文で期が食い違えば作らない'
# 期が複数あると、どれをずらすか決められない。
Chk ((V 'Q1からQ2への変化' 'Change from Q1 to Q2').Count -eq 0) '期が複数あれば作らない'
# 語の一部を期と読み違えないこと。
Chk ((V 'QA 体制' 'QA structure').Count -eq 0) 'QA の Q を四半期と読まない'
Chk ((V 'HQ 費用' 'HQ costs').Count -eq 0) 'HQ の H を半期と読まない'

# ---------------------------------------------------------------- 一覧への追加
Write-Host '候補の一覧へ足す'
$entries = @(
    [pscustomobject]@{ Source='Q1 営業利益'; Target='Q1 OP'; Count=3; Confidence='high'; Conflict=$false; Samples=@('a') }
    [pscustomobject]@{ Source='Q2 営業利益'; Target='Q2 OP（実測）'; Count=1; Confidence='high'; Conflict=$false; Samples=@('b') }
    [pscustomobject]@{ Source='売上高';      Target='Revenue'; Count=9; Confidence='high'; Conflict=$false; Samples=@('c') }
)
$merged = @(Add-YakuGlossaryPeriodVariants -Entries $entries)
$q2row = @($merged | Where-Object { [string]$_.Source -eq 'Q2 営業利益' })
Chk ($q2row.Count -eq 1) ('実測がある期は予測で増やさない: ' + $q2row.Count)
Chk ([string]$q2row[0].Target -eq 'Q2 OP（実測）') '実測を予測で上書きしない'
Chk ((@($merged | Where-Object { [string]$_.Source -eq 'Q3 営業利益' }).Count) -eq 1) '実測の無い期は予測で足す'
Chk ([string](@($merged | Where-Object { [string]$_.Source -eq 'Q3 営業利益' })[0].Origin) -like '予測*') '予測には予測の印が付く'
Chk ([string](@($merged | Where-Object { [string]$_.Source -eq '売上高' })[0].Origin) -eq '実測') '実測には実測の印が付く'
Chk ((@($merged | Where-Object { [string]$_.Source -eq '売上高' }).Count) -eq 1) '期の無い項目は増えない'
# 同じ原文が二度出ないこと。置換表は完全一致で引くので、重複は無意味かつ有害。
$dupes = @($merged | Group-Object -Property Source | Where-Object { $_.Count -gt 1 })
Chk ($dupes.Count -eq 0) ('同じ原文が二度出ない: ' + $dupes.Count)

# ---------------------------------------------------------------- シート名の突き合わせ
Write-Host 'シート名から期を伏せる'
Chk ((ConvertTo-YakuPeriodNeutralName -Name '損益_Q1') -eq (ConvertTo-YakuPeriodNeutralName -Name '損益_1Q')) 'Q1 と 1Q は同じ名前とみなす'
Chk ((ConvertTo-YakuPeriodNeutralName -Name 'PL FY26') -eq (ConvertTo-YakuPeriodNeutralName -Name 'PL FY27')) '年度違いは同じ名前とみなす'
Chk ((ConvertTo-YakuPeriodNeutralName -Name '損益') -ne (ConvertTo-YakuPeriodNeutralName -Name '注記')) '期以外が違えば別の名前のまま'
Chk ((ConvertTo-YakuPeriodNeutralName -Name '損益 Q1') -eq (ConvertTo-YakuPeriodNeutralName -Name '損益Q1')) '空白と下線は無視する'

if ($script:fail -gt 0) {
    Write-Host "V91.61 glossary variant regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 glossary variant regression passed.' -ForegroundColor Green
