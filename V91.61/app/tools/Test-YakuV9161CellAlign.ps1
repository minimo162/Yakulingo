<#
.SYNOPSIS
  V91.61: 過去の対訳 Excel からセルの対応を取る仕組みの回帰テスト。

.DESCRIPTION
  「セル番地は基本対応する。ただし体裁のために行や列を足したり削ったり
  するので保証はしない」（利用者の説明 2026-08-06）。

  番地で突き合わせると、行が1本入った時点で以降が全部ずれる。ずれたまま
  置換表を作れば、誤った対訳が完全一致で機械置換され続ける。
  そこで diff と同じ patience 方式を採った。両側で1回ずつしか出ない値を
  錨にし、錨と錨に挟まれたテキストだけを対応付ける。

  ECM の実物は手元に無い（社内にしかない）。ここでは行・列の出し入れを
  故意に起こした合成の並びで、ずれても対応が取れることを確かめる。
  実物へ当てる前に、道具側の正しさだけは決めておくため。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CellAlign.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'CellAlign.ps1')
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# 並びを組み立てる小道具。@('見出し','1,234',...) を渡すと、
# 数字だけのものを数値セル扱いにして並びを作る。
function Seq {
    param([string]$Sheet, [string[]]$Cells)
    $out = New-Object System.Collections.Generic.List[object]
    $row = 1
    foreach ($c in $Cells) {
        $isText = ($c -match '[^\s0-9,\.\(\)▲△%\-]')
        [void]$out.Add((New-YakuCellEntry -Address ($Sheet + '!B' + $row) -Text $c -IsText $isText))
        $row++
    }
    return @($out.ToArray())
}
function TargetOf {
    param($Result, [string]$Source)
    $m = @($Result.Pairs | Where-Object { [string]$_.Source -eq $Source })
    if ($m.Count -eq 0) { return '' }
    return [string]$m[0].Target
}
function ConfOf {
    param($Result, [string]$Source)
    $m = @($Result.Pairs | Where-Object { [string]$_.Source -eq $Source })
    if ($m.Count -eq 0) { return '' }
    return [string]$m[0].Confidence
}
function ConfOfTarget {
    param($Result, [string]$Target)
    $m = @($Result.Pairs | Where-Object { [string]$_.Target -eq $Target })
    if ($m.Count -eq 0) { return '' }
    return [string]$m[0].Confidence
}

# ------------------------------------------------------------------ 錨の選び方
Write-Host '錨に使ってよい値'
Chk (Test-YakuAnchorCandidate -Key (ConvertTo-YakuAnchorKey -Text '11,577')) '桁区切りの数値は錨になる'
Chk (Test-YakuAnchorCandidate -Key (ConvertTo-YakuAnchorKey -Text 'FY26/3')) '年度記号は錨になる（日英で同じ姿）'
Chk (-not (Test-YakuAnchorCandidate -Key (ConvertTo-YakuAnchorKey -Text '営業利益'))) '日本語は錨にしない（英語版では別の姿）'
Chk (-not (Test-YakuAnchorCandidate -Key (ConvertTo-YakuAnchorKey -Text 'Operating profit'))) '英語だけの語も錨にしない（数字が無い）'
Chk (-not (Test-YakuAnchorCandidate -Key (ConvertTo-YakuAnchorKey -Text '12'))) '2桁の数は錨にしない（表の中で何度も出る）'
# 書式の違いを吸収する。同じ値が日英で違う姿で書かれていても錨になるように。
Chk ((ConvertTo-YakuAnchorKey -Text '11,577') -eq (ConvertTo-YakuAnchorKey -Text '11577')) '桁区切りの有無を吸収する'
Chk ((ConvertTo-YakuAnchorKey -Text '▲123') -eq (ConvertTo-YakuAnchorKey -Text '(123)')) '負の書き分け（▲と括弧）を揃える'
Chk ((ConvertTo-YakuAnchorKey -Text '１２３４') -eq (ConvertTo-YakuAnchorKey -Text '1234')) '全角数字を半角へ寄せる'

# ------------------------------------------------------------------ ずれが無い場合
Write-Host 'ずれが無い場合'
$ja = Seq -Sheet 'Sheet1' -Cells @('売上高','11,577','営業利益','1,234','経常利益','2,345')
$en = Seq -Sheet 'Sheet1' -Cells @('Revenue','11,577','Operating profit','1,234','Ordinary profit','2,345')
$r = Get-YakuBilingualCellPairs -Left $ja -Right $en
Chk ([int]$r.AnchorCount -eq 3) ('錨が3つ取れる: ' + $r.AnchorCount)
Chk ((TargetOf $r '売上高') -eq 'Revenue') '売上高 -> Revenue'
Chk ((TargetOf $r '営業利益') -eq 'Operating profit') '営業利益 -> Operating profit'
Chk ((TargetOf $r '経常利益') -eq 'Ordinary profit') '経常利益 -> Ordinary profit'
# 先頭でも、自分の数値の直前に居れば直付けで決まるので high になる。
# 「錨で閉じているか」より「数値に直付けか」のほうが強い根拠である。
Chk ((ConfOf $r '営業利益') -eq 'high') '数値に直付けなら high'
Chk ((ConfOf $r '売上高') -eq 'high') '先頭でも数値に直付けなら high'

# ------------------------------------------------------------------ 行の挿入（本題）
Write-Host '英語版だけ行が増えている場合'
# 体裁のために「小計」の行が英語版にだけ入っている。番地で突き合わせると
# ここから先が全部1つずれ、営業利益 -> Subtotal のような誤りが出る。
$ja2 = Seq -Sheet 'Sheet1' -Cells @('売上高','11,577','営業利益','1,234','経常利益','2,345')
$en2 = Seq -Sheet 'Sheet1' -Cells @('Revenue','11,577','Subtotal','9,999','Operating profit','1,234','Ordinary profit','2,345')
$r2 = Get-YakuBilingualCellPairs -Left $ja2 -Right $en2
Chk ((TargetOf $r2 '営業利益') -eq 'Operating profit') '行が増えても 営業利益 -> Operating profit（番地なら Subtotal になる）'
Chk ((TargetOf $r2 '経常利益') -eq 'Ordinary profit') '以降も同期が戻っている'
Chk ((TargetOf $r2 '売上高') -eq 'Revenue') '挿入より前は影響を受けない'
# 増えた側だけに居る項目は、個数が合わないので確度が落ちる。
Chk ((ConfOfTarget $r2 'Subtotal') -ne 'high') '増えた項目は high にしない（対応する原文が無い）'

Write-Host '日本語版だけ行が増えている場合'
$ja3 = Seq -Sheet 'Sheet1' -Cells @('売上高','11,577','内部売上','500','営業利益','1,234','経常利益','2,345')
$en3 = Seq -Sheet 'Sheet1' -Cells @('Revenue','11,577','Operating profit','1,234','Ordinary profit','2,345')
$r3 = Get-YakuBilingualCellPairs -Left $ja3 -Right $en3
Chk ((TargetOf $r3 '営業利益') -eq 'Operating profit') '削られていても 営業利益 -> Operating profit'
Chk ((TargetOf $r3 '経常利益') -eq 'Ordinary profit') '以降も同期が戻っている'
Chk ((ConfOf $r3 '内部売上') -ne 'high') '訳の無い項目は high にしない'

# ------------------------------------------------------------------ 複数箇所のずれ
Write-Host '複数箇所で出し入れがある場合'
$ja4 = Seq -Sheet 'S' -Cells @(
    '売上高','11,577','売上原価','8,001','販売費','1,002',
    '営業利益','1,234','営業外収益','321','経常利益','2,345','当期純利益','1,111')
$en4 = Seq -Sheet 'S' -Cells @(
    'Revenue','11,577','Note','0','Cost of sales','8,001','SG&A','1,002',
    'Operating profit','1,234','Non-operating income','321','Memo','0','Ordinary profit','2,345','Net income','1,111')
$r4 = Get-YakuBilingualCellPairs -Left $ja4 -Right $en4
Chk ((TargetOf $r4 '売上原価') -eq 'Cost of sales') '1つ目の挿入をまたいで正しい'
Chk ((TargetOf $r4 '販売費') -eq 'SG&A') '続きも正しい'
Chk ((TargetOf $r4 '経常利益') -eq 'Ordinary profit') '2つ目の挿入をまたいで正しい'
Chk ((TargetOf $r4 '当期純利益') -eq 'Net income') '最後まで同期している'

# ------------------------------------------------------------------ 順序の入れ替え
Write-Host '順序が入れ替わっている場合'
# 錨の順序が逆転していたら、その錨は使わない。使うと区間の切り方が壊れ、
# 間に挟まれたセルの対応が総崩れになる。
$pairs = @(
    [pscustomobject]@{ L=0; R=0 }
    [pscustomobject]@{ L=1; R=5 }
    [pscustomobject]@{ L=2; R=2 }
    [pscustomobject]@{ L=3; R=3 }
    [pscustomobject]@{ L=4; R=4 }
)
$lis = @(Get-YakuLongestIncreasingPairs -Pairs $pairs)
Chk ($lis.Count -eq 4) ('逆転した錨を落として最大の並びを採る: ' + $lis.Count)
Chk (-not (@($lis | Where-Object { [int]$_.R -eq 5 }).Count -gt 0)) '逆転していた錨が落ちている'

# ------------------------------------------------------------------ 何度も出る値
Write-Host '同じ値が何度も出る場合'
# 0 や 100 は表の中に何度も出る。どれとどれが対応するか決められないので
# 錨にしない。曖昧な錨を使うと、区間の切り方が誤る。
$ja5 = Seq -Sheet 'S' -Cells @('項目A','1,000','項目B','1,000','項目C','7,777')
$en5 = Seq -Sheet 'S' -Cells @('Item A','1,000','Item B','1,000','Item C','7,777')
$r5 = Get-YakuBilingualCellPairs -Left $ja5 -Right $en5
Chk ([int]$r5.AnchorCount -eq 1) ('重複する値は錨にしない（7,777 だけ）: ' + $r5.AnchorCount)
Chk ((TargetOf $r5 '項目A') -eq 'Item A') '錨が少なくても区間内の順序で対応が取れる'
Chk ((TargetOf $r5 '項目C') -eq 'Item C') '同じ区間の続きも対応する'
Chk ((ConfOf $r5 '項目C') -eq 'high') '唯一の錨に直付けの項目名は high'
Chk ((ConfOf $r5 '項目A') -eq 'low') '錨で閉じていない区間は low にする'

# ------------------------------------------------------------------ 数値への直付け
Write-Host '項目名は自分の数値の直前にある、という表の性質を使う'
# 区間の内側に行が増えていると、順番に対応させる方式は総崩れになる。
# 一致した数値から1つ戻れば項目名どうしが対応するので、行の増減に左右されない。
$ja6 = Seq -Sheet 'S' -Cells @('項目','前年','当年','営業利益','1,000','1,234')
$en6 = Seq -Sheet 'S' -Cells @('Item','PY','CY','Operating profit','1,000','1,234')
$r6 = Get-YakuBilingualCellPairs -Left $ja6 -Right $en6
Chk ([int]$r6.AdjacentCount -gt 0) ('数値に直付けの対が取れる: ' + $r6.AdjacentCount)
Chk ((ConfOf $r6 '営業利益') -eq 'high') '数値の1つ前は high（直付け）'
# 見出しが連なる行は、1つ前が正しかった前提に乗るので確度を落とす。
Chk ((TargetOf $r6 '当年') -eq 'CY') '2つ前も対応は取れる'
Chk ((ConfOf $r6 '当年') -eq 'medium') '2つ以上前は medium（前提に乗っている）'

# ------------------------------------------------------------------ 置換表へ入れてよいもの
Write-Host '置換表へ入れてよい対だけを通す'
function P { param($s,$t,$c='high') [pscustomobject]@{ Source=$s; Target=$t; Confidence=$c; SourceAddress='a'; TargetAddress='b' } }
Chk (Test-YakuCellPairUsableAsGlossary -Pair (P '営業利益' 'Operating profit')) '普通の対は通る'
Chk (-not (Test-YakuCellPairUsableAsGlossary -Pair (P '営業利益' 'Operating profit' 'medium'))) 'high 以外は通さない'
Chk (-not (Test-YakuCellPairUsableAsGlossary -Pair (P '営業利益' 'medium 以外' 'high'))) '訳文に日本語が残っていたら通さない（訳し漏れ）'
Chk (-not (Test-YakuCellPairUsableAsGlossary -Pair (P '1,234' '1,234'))) '数値は置換表の仕事ではない'
Chk (-not (Test-YakuCellPairUsableAsGlossary -Pair (P 'FY26/3' 'FY26/3'))) '原文と訳文が同じなら置換する意味が無い'
$long = ('あ' * 80)
Chk (-not (Test-YakuCellPairUsableAsGlossary -Pair (P $long 'x'))) '長い文は置換表ではなく翻訳メモリの仕事'

# ------------------------------------------------------------------ まとめ方
Write-Host '複数ファイルの候補をまとめる'
$merged = @(Merge-YakuCellPairOccurrences -Pairs @(
    (P '営業利益' 'Operating profit'), (P '営業利益' 'Operating profit'), (P '営業利益' 'Operating profit')
    (P '売上高' 'Revenue'), (P '売上高' 'Revenue')
    (P '販売費' 'SG&A')
    (P '経常利益' 'Ordinary profit'), (P '経常利益' 'Ordinary income')
))
Chk ([string]$merged[0].Source -eq '営業利益' -and [int]$merged[0].Count -eq 3) '出現数の多い順に並ぶ'
Chk ([int](@($merged | Where-Object { [string]$_.Source -eq '売上高' })[0].Count) -eq 2) '同じ対を数える'
$conf = @($merged | Where-Object { [string]$_.Source -eq '経常利益' })
Chk ($conf.Count -eq 2) '同じ原文に別の訳があれば両方残す（機械に選ばせない）'
Chk (@($conf | Where-Object { [bool]$_.Conflict }).Count -eq 2) '競合として印を付ける'
Chk (-not [bool](@($merged | Where-Object { [string]$_.Source -eq '売上高' })[0].Conflict)) '競合していないものには印を付けない'
Chk (@($merged[0].Samples).Count -gt 0) 'どのセルから来たかを残す（人が確かめられるように）'

# ------------------------------------------------------------------ シートの対応
# シート名は四半期で変わり、名前そのものが訳されていることもある
# （損益 と PL）。名前で結べないなら中身で結ぶ。
Write-Host 'シートの対応を決める'
. (Join-Path (Join-Path $root 'src') 'GlossaryVariants.ps1')
function Book { param([hashtable]$Sheets)
    $order = @($Sheets.Keys)
    $map = @{}
    foreach ($k in $order) { $map[$k] = Seq -Sheet $k -Cells $Sheets[$k] }
    return [pscustomobject]@{ Sheets = $map; Order = $order }
}
$bJa = Book @{ '損益' = @('売上高','11,577','営業利益','1,234','経常利益','2,345') }
$bEn = Book @{ '損益' = @('Revenue','11,577','Operating profit','1,234','Ordinary profit','2,345') }
$m = Get-YakuSheetMatches -Source $bJa -Target $bEn
Chk ([string]$m['損益'].Basis -eq '名前') '同名なら名前で結ぶ'

$bJa2 = Book @{ '損益_Q1' = @('売上高','11,577','営業利益','1,234','経常利益','2,345') }
$bEn2 = Book @{ '損益_1Q' = @('Revenue','11,577','Operating profit','1,234','Ordinary profit','2,345') }
$m2 = Get-YakuSheetMatches -Source $bJa2 -Target $bEn2
Chk ([string]$m2['損益_Q1'].Target -eq '損益_1Q') '期の書き方が違っても結ぶ（Q1 と 1Q）'
Chk ([string]$m2['損益_Q1'].Basis -eq '期を伏せた名前') '期を伏せた名前で結んだと分かる'

# シート名そのものが訳されている場合。名前では手掛かりが無いので中身で結ぶ。
$bJa3 = Book @{ '損益' = @('売上高','11,577','営業利益','1,234','経常利益','2,345') }
$bEn3 = Book @{ 'PL' = @('Revenue','11,577','Operating profit','1,234','Ordinary profit','2,345') }
$m3 = Get-YakuSheetMatches -Source $bJa3 -Target $bEn3
Chk ([string]$m3['損益'].Target -eq 'PL') '名前が訳されていても中身で結ぶ'
Chk ([string]$m3['損益'].Basis -like '中身*') '中身で結んだと分かる'

# 決められないなら結ばない。まるごと別の表を結ぶと誤訳が大量に出る。
$bJa4 = Book @{ '損益' = @('売上高','11,577','営業利益','1,234','経常利益','2,345') }
$bEn4 = Book @{ '無関係' = @('Something','9,001','Other','9,002','More','9,003') }
$m4 = Get-YakuSheetMatches -Source $bJa4 -Target $bEn4
Chk (-not $m4.ContainsKey('損益')) '共通の錨が無ければ結ばない'
# 2番手と差が付かない場合も結ばない。
$common = @('項目','11,577','項目2','1,234','項目3','2,345')
$bJa5 = Book @{ 'A' = $common }
$bEn5 = Book @{ 'X' = $common; 'Y' = $common }
$m5 = Get-YakuSheetMatches -Source $bJa5 -Target $bEn5
Chk (-not $m5.ContainsKey('A')) '同点の相手が居れば結ばない'
# 相手は1度しか使わない。2つのシートが同じ相手を取り合わないこと。
$bJa6 = Book @{ '損益' = @('売上高','11,577','営業利益','1,234','経常利益','2,345'); '注記' = @('会計方針','4,001','偶発債務','4,002','後発事象','4,003') }
$bEn6 = Book @{ '損益' = @('Revenue','11,577','Operating profit','1,234','Ordinary profit','2,345'); 'Notes' = @('Accounting policies','4,001','Contingent liabilities','4,002','Subsequent events','4,003') }
$m6 = Get-YakuSheetMatches -Source $bJa6 -Target $bEn6
Chk ([string]$m6['損益'].Target -eq '損益' -and [string]$m6['注記'].Target -eq 'Notes') '名前で決まった相手は中身の候補から外れる'

# ------------------------------------------------------------------ Excel との繋ぎ目
# 算法だけを試していると、Excel から並びを作る側の取り違えを見逃す
# （実際に列名の取り出しで引数名を間違え、ここで初めて分かった）。
# 実物のブックを作って通す。Excel が無い環境では飛ばす。
. (Join-Path (Join-Path $root 'src') 'Paths.ps1')
. (Join-Path (Join-Path $root 'src') 'Runtime.ps1')
. (Join-Path (Join-Path $root 'src') 'Html.ps1')
. (Join-Path (Join-Path $root 'src') 'Settings.ps1')
. (Join-Path (Join-Path $root 'src') 'FileProcessors.ps1')
Write-Host 'Excel から並びを作る'
if (-not (Test-YakuExcelAvailable)) {
    Write-Host '  skip Excel が無いため飛ばす' -ForegroundColor Yellow
} else {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-align-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $null = New-Item -ItemType Directory -Path $tmp -Force
    $jaPath = Join-Path $tmp 'jp.xlsx'
    $enPath = Join-Path $tmp 'en.xlsx'
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        # 英語版には体裁のための行を1本、左に番号列を1本足す。
        # 利用者の説明どおりの崩れ方（行や列をその場その場で出し入れする）。
        $wb = $xl.Workbooks.Add()
        $ws = $wb.Worksheets.Item(1); $ws.Name = '損益'
        $rowsJa = @(@('売上高','11,577'), @('売上原価','8,001'), @('営業利益','1,234'), @('経常利益','2,345'))
        for ($i = 0; $i -lt $rowsJa.Count; $i++) { $ws.Cells.Item($i+1,1).Value2 = $rowsJa[$i][0]; $ws.Cells.Item($i+1,2).Value2 = $rowsJa[$i][1] }
        $wb.SaveAs($jaPath, 51); $wb.Close($false)

        $wb2 = $xl.Workbooks.Add()
        $ws2 = $wb2.Worksheets.Item(1); $ws2.Name = '損益'
        $rowsEn = @(@('1','Revenue','11,577'), @('2','Cost of sales','8,001'), @('','Subtotal','9,003'), @('3','Operating profit','1,234'), @('4','Ordinary profit','2,345'))
        for ($i = 0; $i -lt $rowsEn.Count; $i++) { for ($c = 0; $c -lt 3; $c++) { $ws2.Cells.Item($i+1,$c+1).Value2 = $rowsEn[$i][$c] } }
        $wb2.SaveAs($enPath, 51); $wb2.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    $res = Get-YakuWorkbookPairCandidates -SourcePath $jaPath -TargetPath $enPath
    function XTargetOf { param($R,[string]$S) $m = @($R.Pairs | Where-Object { [string]$_.Source -eq $S }); if ($m.Count -eq 0) { return '' }; return [string]$m[0].Target }
    Chk ((XTargetOf $res '売上高') -eq 'Revenue') 'ブックから 売上高 -> Revenue'
    Chk ((XTargetOf $res '営業利益') -eq 'Operating profit') '行と列が増えていても 営業利益 -> Operating profit'
    Chk ((XTargetOf $res '経常利益') -eq 'Ordinary profit') '最後まで同期している'
    Chk ((XTargetOf $res '売上原価') -eq 'Cost of sales') '挿入より前も正しい'
    # 番地が実際にずれていることを確かめる。ずれていないと試験にならない。
    $one = @($res.Pairs | Where-Object { [string]$_.Source -eq '営業利益' })[0]
    Chk ([string]$one.SourceAddress -eq '損益!A3' -and [string]$one.TargetAddress -eq '損益!B4') ('番地は実際にずれている: ' + [string]$one.SourceAddress + ' -> ' + [string]$one.TargetAddress)
    Chk (@($res.Sheets | Where-Object { [string]$_.Sheet -eq '損益' -and [bool]$_.Matched }).Count -eq 1) '同名のシートを突き合わせる'
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 cell align regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 cell align regression passed.' -ForegroundColor Green
