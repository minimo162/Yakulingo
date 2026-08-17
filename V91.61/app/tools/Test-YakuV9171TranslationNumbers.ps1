<#
.SYNOPSIS
  V91.71: 訳文の数値が原文どおり残っているかを、採点駆動部ごと確かめる。

.DESCRIPTION
  「数値が抜けた訳は警告ではなく欠陥」を、資料まるごとの単位で見張る門である。
  Compare-YakuTranslation.ps1 -PairsPath の駆動部そのものを回すので、
  照合器（-SelfTest が見ている部分）だけでなく、読み込み・組み立て・
  終了コードまでが対象になる。

  **公表訳は正解ではない。** 採点は「日本語原文 対 候補」で行い、reference は
  所見のための手掛かりにしか使わない。言い回しの近さで採点すると、正しい別解を
  減点することになる。実測でも、マツダの公表英訳をこの指標で採点すると
  金額 39/43・比率 21/28 になる（公表訳は逐語訳ではないため）。
  公表訳に寄せる方向へ直してはいけない。oku 固定の単位規約を壊す。

  この試験は2段になっている。
    1. いつでも走る合成の組。駆動部と門が働くことを確かめる
    2. 手元に日英対訳があるときだけ走る実資料の組。tmp/ と output/ は
       配布対象外（.gitignore）なので、無い環境では飛ばす

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9171TranslationNumbers.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$compare = Join-Path $toolsRoot 'Compare-YakuTranslation.ps1'
$script:fail = 0

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-v9171-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$utf8 = New-Object System.Text.UTF8Encoding $false

function Invoke-YakuComparePairs {
    param([string[]]$Rows, [string]$Name)
    $p = Join-Path $tmp ($Name + '.jsonl')
    [IO.File]::WriteAllLines($p, $Rows, $utf8)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compare -PairsPath $p
    $code = $LASTEXITCODE
    $json = $null
    try { $json = ($out -join "`n") | ConvertFrom-Json } catch { $json = $null }
    return [pscustomobject]@{ Code = $code; Report = $json; Raw = ($out -join "`n") }
}

try {
    # ---------------------------------------------------------------- 合成の組
    Write-Host '駆動部と門（合成の組）'

    $good = ([ordered]@{ name='good'
        japanese='売上高は1兆2,857億600万円、営業利益は328億3,600万円です。'
        reference=''
        candidate='Net sales were 1,285.7 billion yen and operating income was 32.8 billion yen.' } | ConvertTo-Json -Compress)
    $dropped = ([ordered]@{ name='dropped'
        japanese='売上高は1兆2,857億600万円、営業利益は328億3,600万円です。'
        reference=''
        candidate='Net sales were 1,285.7 billion yen.' } | ConvertTo-Json -Compress)
    $residue = ([ordered]@{ name='residue'
        japanese='売上高は122億円です。'
        reference=''
        candidate='Net sales were [[N1]] oku.' } | ConvertTo-Json -Compress)

    $r1 = Invoke-YakuComparePairs -Rows @($good) -Name 'good'
    Chk ($r1.Code -eq 0) '規約どおりの訳は通る（終了コード0）'
    Chk ([bool]$r1.Report.all_ok) '規約どおりの訳は all_ok'
    Chk ([int]$r1.Report.results[0].amounts.matched -eq 2) '単位が違っても同じ量なら一致（2件）'

    # 門は「発火すること」を確かめて初めて門になる。
    $r2 = Invoke-YakuComparePairs -Rows @($good, $dropped, $residue) -Name 'mixed'
    Chk ($r2.Code -eq 1) '1組でも落ちれば終了コードが1になる'
    Chk (-not [bool]$r2.Report.all_ok) '落ちた組があれば all_ok は false'
    $failed = @($r2.Report.failed)
    Chk ($failed -contains 'dropped') '数字が1つ落ちた訳を捕まえる'
    Chk ($failed -contains 'residue') '記号が残った訳を捕まえる'
    Chk (-not ($failed -contains 'good')) '通る組を巻き込まない'

    $residueRow = @($r2.Report.results | Where-Object { [string]$_.name -eq 'residue' })[0]
    Chk (-not [bool]$residueRow.placeholder_ok) '記号の残留は placeholder_ok で分かる'

    # 原文が空の組は、静かに0件で通してはいけない。
    $empty = ([ordered]@{ name='empty'; japanese=''; reference=''; candidate='x' } | ConvertTo-Json -Compress)
    $r3 = Invoke-YakuComparePairs -Rows @($empty) -Name 'empty'
    Chk ($r3.Code -ne 0) '原文が空の組は通さない'

    # -------------------------------------------------------- 実資料の組（規模）
    #
    # 合成の組は仕組みを確かめるが、規模を確かめない。集合の突き合わせは
    # 件数が増えて初めて壊れることがあるので、実資料1本ぶんを固定資料として
    # 同梱している。出典は下記のとおり公開情報である。
    #
    #   原文 : マツダ株式会社 2027年3月期 第1四半期 決算短信（日本語）からの抽出全文
    #   訳文 : その原文を YakuLingo が訳した結果（2026-08-14 時点）
    #
    # 置き場を tools/regression にしているのは、New-YakuPackage.ps1 が
    # glossary.csv / propernouns.csv / corpus/ / _docs/ を配布物から弾く一方で、
    # 回帰用の固定資料はここに置く作法が既にあるため（V91.35 / V91.38 と同じ）。
    #
    # tmp/ には置かない。あそこは消える場所で、そこにだけ依存すると、
    # 資料が消えた日にこの門が黙って合成だけへ縮退する。
    $jaPath = Join-Path $toolsRoot 'regression\V91.71_数値回帰_原文ja.txt'
    $candPath = Join-Path $toolsRoot 'regression\V91.71_数値回帰_訳文en.txt'

    # 同梱資料が無いのは環境差ではなく異常なので、飛ばさずに赤にする。
    Chk (Test-Path -LiteralPath $jaPath -PathType Leaf) ('同梱の原文がある: ' + $jaPath)
    Chk (Test-Path -LiteralPath $candPath -PathType Leaf) ('同梱の訳文がある: ' + $candPath)

    if ((Test-Path -LiteralPath $jaPath -PathType Leaf) -and (Test-Path -LiteralPath $candPath -PathType Leaf)) {
        Write-Host '実資料の組（規模で見る）'
        $real = ([ordered]@{ name='mazda2027q1'
            japanese_path=$jaPath; reference_path=''; candidate_path=$candPath } | ConvertTo-Json -Compress)
        $r4 = Invoke-YakuComparePairs -Rows @($real) -Name 'scale'
        $m = @($r4.Report.results)[0]
        # 2026-08-14 の実測値。ここを下回ったら退行である。
        # 参考: 同じ指標で公表英訳を採点すると金額 39/43・比率 21/28 になる。
        # 公表訳は逐語訳ではないので、そちらへ寄せる方向へ直してはいけない。
        Chk ([int]$m.amounts.matched -ge 43) ('金額が43件以上そろう（実測 ' + [int]$m.amounts.matched + '/' + [int]$m.amounts.expected + '）')
        Chk ([int]$m.percents.matched -ge 28) ('比率が28件以上そろう（実測 ' + [int]$m.percents.matched + '/' + [int]$m.percents.expected + '）')
        Chk ([int]$m.units.matched -ge 1) '台数がそろう'
        Chk (@($m.leftover).Count -eq 0) '記号が残っていない'
        Chk ($r4.Code -eq 0) '実資料の組が通る'
    }
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.71 translation numbers regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.71 translation numbers regression passed.' -ForegroundColor Green
