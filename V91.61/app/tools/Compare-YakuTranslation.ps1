<#
.SYNOPSIS
  訳文を公表訳と突き合わせる。実機テストの採点用。

.DESCRIPTION
  **公表訳は「正解」ではない。1つの妥当な訳である。**
  言い回しの近さで採点すると、正しい別解を減点することになる。
  ここで見るのは、機械で決まるものだけにする。

    - 数値が合っているか（単位換算を考慮する）
    - 用語が公表訳と揃っているか
    - プレースホルダーが残っていないか

  なぜ単位換算を見るのか。2026-08-07 に「Copilot の対応づけが4割誤り」と
  報告したが、実際は照合器が 億円 と billion を別物として数えていただけで、
  中身は 15/15 正しかった。同じ失敗を繰り返さないための実装である。

  日本語と英語で同じ量を指す書き方:

      1兆2,857億円   =  1,285.7 billion yen  =  12,857 oku
      328億3,600万円 =  32.836 billion yen   =  328.36 oku
      18万6千台      =  186 thousand units   =  186 k units

  すべて「億円」に正規化してから比べる。丸めの差は許容する
  （公表訳は 1,285.7 billion のように丸めることがある）。

.EXAMPLE
  .\tools\Compare-YakuTranslation.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [AllowNull()][string]$PairsPath
)

$ErrorActionPreference = 'Stop'

function ConvertTo-YakuCompareNumber {
    <#
      数値の文字列を [decimal] にする。全角・桁区切り・符号の書き分けを吸収する。
      負数は ▲ △ (…) いずれの書き方でも同じ値にする。
    #>
    param([AllowNull()][string]$Text)
    $s = [string]$Text
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $s = $s.Normalize([Text.NormalizationForm]::FormKC)
    $neg = $false
    if ($s -match '^[\s]*[▲△−-]') { $neg = $true }
    if ($s -match '^\s*\(.*\)\s*$') { $neg = $true }
    $s = $s -replace '[^\d\.]', ''
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $v = [decimal]0
    if (-not [decimal]::TryParse($s, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $null }
    if ($neg) { $v = -1 * $v }
    return $v
}

function Get-YakuAmountsInOku {
    <#
      文の中の金額を、すべて「億円」に直して並べて返す。

      日本語側:  1兆2,857億円 / 328億3,600万円 / 1,234百万円 / 12億円
      英語側:    1,285.7 billion yen / 32,836 million yen / 12.2 billion / 1,234 oku
    #>
    param([AllowNull()][string]$Text)
    $s = ([string]$Text).Normalize([Text.NormalizationForm]::FormKC)
    # PDF 抽出は語の間に空白を連ねる（「144 thousand     units」）。
    # 畳んでから見ないと、単位付きの数を丸ごと取り逃がす（2026-08-08 に発見）。
    # 見えない文字（ソフトハイフン U+00AD）も落とす。
    $s = ($s -replace '\u00AD', '') -replace '\s+', ' '
    $out = New-Object System.Collections.Generic.List[decimal]

    # --- 日本語: 兆・億・万 の組み合わせ ---
    # 「1兆2,857億600万円」のような連なりを1つの量として畳む。
    foreach ($m in [regex]::Matches($s, '(?<sign>[▲△−-])?\s*(?:(?<cho>[\d,]+(?:\.\d+)?)兆)?(?:(?<oku>[\d,]+(?:\.\d+)?)億)?(?:(?<man>[\d,]+(?:\.\d+)?)万)?円')) {
        $cho = ConvertTo-YakuCompareNumber $m.Groups['cho'].Value
        $oku = ConvertTo-YakuCompareNumber $m.Groups['oku'].Value
        $man = ConvertTo-YakuCompareNumber $m.Groups['man'].Value
        if ($null -eq $cho -and $null -eq $oku -and $null -eq $man) { continue }
        # 億円へ寄せる。1兆 = 10,000億、1万円 = 0.0001億円
        $total = [decimal]0
        if ($null -ne $cho) { $total += $cho * 10000 }
        if ($null -ne $oku) { $total += $oku }
        if ($null -ne $man) { $total += $man / 10000 }
        if ($m.Groups['sign'].Success) { $total = -1 * $total }
        [void]$out.Add($total)
    }
    # 「1,234百万円」= 12.34億円
    foreach ($m in [regex]::Matches($s, '(?<sign>[▲△−-])?\s*(?<v>[\d,]+(?:\.\d+)?)\s*百万円')) {
        $v = ConvertTo-YakuCompareNumber $m.Groups['v'].Value
        if ($null -eq $v) { continue }
        $t = $v / 100
        if ($m.Groups['sign'].Success) { $t = -1 * $t }
        [void]$out.Add($t)
    }

    # --- 英語 ---
    # billion yen = 10億円 / million yen = 0.01億円 / oku = 1億円
    # 負数は ▲ でも (…) でも書かれる。社内表記は括弧、公表訳は言葉である。
    # 括弧を見落とすと、減少を増加として一致させてしまう。
    $enUnits = @(
        @{ Unit = 'billion'; Factor = [decimal]10 }
        @{ Unit = 'million'; Factor = [decimal]0.01 }
        @{ Unit = 'oku';     Factor = [decimal]1 }
    )
    foreach ($u in $enUnits) {
        $pattern = '(?<sign>[▲△−-])?\s*(?<open>\()?\s*¥?\s*(?<v>[\d,]+(?:\.\d+)?)\s*(?<close>\))?\s*(?:' + $u.Unit + ')\b'
        foreach ($m in [regex]::Matches($s, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $v = ConvertTo-YakuCompareNumber $m.Groups['v'].Value
            if ($null -eq $v) { continue }
            $t = $v * $u.Factor
            if ($m.Groups['sign'].Success -or $m.Groups['open'].Success -or $m.Groups['close'].Success) { $t = -1 * $t }
            [void]$out.Add($t)
        }
    }
    return @($out.ToArray())
}

function Get-YakuUnitsInThousands {
    <#
      台数を「千台」に直して返す。18万6千台 = 186 thousand units = 186 k units
    #>
    param([AllowNull()][string]$Text)
    $s = ([string]$Text).Normalize([Text.NormalizationForm]::FormKC)
    # PDF 抽出は語の間に空白を連ねる（「144 thousand     units」）。
    # 畳んでから見ないと、単位付きの数を丸ごと取り逃がす（2026-08-08 に発見）。
    # 見えない文字（ソフトハイフン U+00AD）も落とす。
    $s = ($s -replace '\u00AD', '') -replace '\s+', ' '
    $out = New-Object System.Collections.Generic.List[decimal]
    foreach ($m in [regex]::Matches($s, '(?:(?<man>[\d,]+(?:\.\d+)?)万)?(?:(?<sen>[\d,]+(?:\.\d+)?)千)?台')) {
        $man = ConvertTo-YakuCompareNumber $m.Groups['man'].Value
        $sen = ConvertTo-YakuCompareNumber $m.Groups['sen'].Value
        if ($null -eq $man -and $null -eq $sen) { continue }
        $t = [decimal]0
        if ($null -ne $man) { $t += $man * 10 }
        if ($null -ne $sen) { $t += $sen }
        [void]$out.Add($t)
    }
    foreach ($m in [regex]::Matches($s, '(?<v>[\d,]+(?:\.\d+)?)\s*(?:thousand units|k units)\b', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $v = ConvertTo-YakuCompareNumber $m.Groups['v'].Value
        if ($null -ne $v) { [void]$out.Add($v) }
    }
    return @($out.ToArray())
}

function Get-YakuPercents {
    param([AllowNull()][string]$Text)
    $s = ([string]$Text).Normalize([Text.NormalizationForm]::FormKC)
    # PDF 抽出は語の間に空白を連ねる（「144 thousand     units」）。
    # 畳んでから見ないと、単位付きの数を丸ごと取り逃がす（2026-08-08 に発見）。
    # 見えない文字（ソフトハイフン U+00AD）も落とす。
    $s = ($s -replace '\u00AD', '') -replace '\s+', ' '
    $out = New-Object System.Collections.Generic.List[decimal]
    # 金額と同じく、括弧書きの負数を拾う。日本語は △72.3%、公表訳は (72.3)% と書く。
    # 金額側で直したのに％で同じ見落としをしていた（2026-08-08 に実データで発見）。
    foreach ($m in [regex]::Matches($s, '(?<sign>[▲△−-])?\s*(?<open>\()?\s*(?<v>[\d,]+(?:\.\d+)?)\s*(?<close>\))?\s*[%％]')) {
        $v = ConvertTo-YakuCompareNumber $m.Groups['v'].Value
        if ($null -eq $v) { continue }
        if ($m.Groups['sign'].Success -or $m.Groups['open'].Success -or $m.Groups['close'].Success) { $v = -1 * $v }
        [void]$out.Add($v)
    }
    return @($out.ToArray())
}

function Compare-YakuNumberSets {
    <#
      2つの数の並びを突き合わせる。丸めの差は許容する。
      公表訳は 1,285.7 billion のように丸めることがあるので、
      相対誤差 0.5% までを一致とみなす。
    #>
    param(
        [AllowNull()][decimal[]]$Expected,
        [AllowNull()][decimal[]]$Actual,
        [decimal]$Tolerance = 0.005
    )
    $exp = @($Expected)
    $act = New-Object System.Collections.Generic.List[decimal]
    foreach ($a in @($Actual)) { [void]$act.Add($a) }
    $matched = 0
    $missing = New-Object System.Collections.Generic.List[decimal]
    foreach ($e in $exp) {
        $hit = -1
        for ($i = 0; $i -lt $act.Count; $i++) {
            $a = $act[$i]
            $diff = [Math]::Abs($a - $e)
            $scale = [Math]::Max([Math]::Abs($e), [decimal]1)
            if (($diff / $scale) -le $Tolerance) { $hit = $i; break }
        }
        if ($hit -ge 0) { $matched++; $act.RemoveAt($hit) } else { [void]$missing.Add($e) }
    }
    return [pscustomobject]@{
        Expected = $exp.Count
        Matched  = $matched
        Missing  = @($missing.ToArray())
        Extra    = @($act.ToArray())
        Ok       = ($missing.Count -eq 0)
    }
}

function Compare-YakuTranslationPair {
    param(
        [Parameter(Mandatory=$true)][string]$Japanese,
        # 公表訳。所見を書くときの手掛かりで、採点には使わない。
        # 無いこともあるので空を許す。
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Candidate
    )
    $amt = Compare-YakuNumberSets -Expected (Get-YakuAmountsInOku -Text $Japanese) -Actual (Get-YakuAmountsInOku -Text $Candidate)
    $unt = Compare-YakuNumberSets -Expected (Get-YakuUnitsInThousands -Text $Japanese) -Actual (Get-YakuUnitsInThousands -Text $Candidate)
    $pct = Compare-YakuNumberSets -Expected (Get-YakuPercents -Text $Japanese) -Actual (Get-YakuPercents -Text $Candidate)
    $leftover = @([regex]::Matches([string]$Candidate, '\[\[[NP]\d+\]\]') | ForEach-Object { $_.Value })
    return [pscustomobject]@{
        Amounts     = $amt
        Units       = $unt
        Percents    = $pct
        Leftover    = @($leftover)
        NumbersOk   = ($amt.Ok -and $unt.Ok -and $pct.Ok)
        PlaceholderOk = (@($leftover).Count -eq 0)
        RefAmounts  = @(Get-YakuAmountsInOku -Text $Reference)
    }
}

if ($SelfTest) {
    # ------------------------------------------------------------------
    # 自分の測定が正しいことを、先に確かめる。
    # ここが通らないうちは、Copilot の出力について何も言ってはいけない。
    # ------------------------------------------------------------------
    $fail = 0
    function T { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }
    $script:fail = 0

    Write-Host '金額を億円へ正規化する' -ForegroundColor Cyan
    T ((Get-YakuAmountsInOku -Text '売上高は1兆2,857億600万円')[0] -eq [decimal]12857.06) '1兆2,857億600万円 = 12,857.06億円'
    T ((Get-YakuAmountsInOku -Text 'Net sales were 1,285.7 billion yen')[0] -eq [decimal]12857) '1,285.7 billion yen = 12,857億円'
    T ((Get-YakuAmountsInOku -Text '営業利益は328億3,600万円')[0] -eq [decimal]328.36) '328億3,600万円 = 328.36億円'
    T ((Get-YakuAmountsInOku -Text 'operating income of 32,836 million yen')[0] -eq [decimal]328.36) '32,836 million yen = 328.36億円'
    T ((Get-YakuAmountsInOku -Text '122 oku')[0] -eq [decimal]122) '122 oku = 122億円'
    T ((Get-YakuAmountsInOku -Text '¥12.2 billion')[0] -eq [decimal]122) '¥12.2 billion = 122億円'

    Write-Host '負数の書き分けを吸収する' -ForegroundColor Cyan
    T ((Get-YakuAmountsInOku -Text '▲46億円')[0] -eq [decimal](-46)) '▲46億円 = -46'
    T ((Get-YakuAmountsInOku -Text '(46) oku')[0] -eq [decimal](-46)) '(46) oku = -46'

    Write-Host '台数' -ForegroundColor Cyan
    T ((Get-YakuUnitsInThousands -Text '18万6千台')[0] -eq [decimal]186) '18万6千台 = 186千台'
    T ((Get-YakuUnitsInThousands -Text '186 thousand units')[0] -eq [decimal]186) '186 thousand units = 186千台'

    Write-Host '突き合わせ（ここが 2026-08-07 に外したところ）' -ForegroundColor Cyan
    $r = Compare-YakuTranslationPair -Japanese '売上高は1兆2,857億600万円、営業利益は328億3,600万円となりました。' `
        -Reference '' -Candidate 'Net sales were 1,285.7 billion yen and operating income was 32.8 billion yen.'
    T ($r.NumbersOk) '単位が違っても、同じ量なら一致とみなす'
    $r2 = Compare-YakuTranslationPair -Japanese '売上高は1兆2,857億600万円です。' -Reference '' -Candidate 'Net sales were 128.57 billion yen.'
    T (-not $r2.NumbersOk) '桁が1つ違えば不一致にする（10倍の誤りを見逃さない）'
    $r3 = Compare-YakuTranslationPair -Japanese '売上高は122億円です。' -Reference '' -Candidate 'Net sales were [[N1]] oku.'
    T (-not $r3.PlaceholderOk) '記号が残っていたら気づく'

    Write-Host '丸め' -ForegroundColor Cyan
    $r4 = Compare-YakuTranslationPair -Japanese '売上高は1兆2,857億600万円です。' -Reference '' -Candidate 'Net sales were 1,285.7 billion yen.'
    T ($r4.NumbersOk) '公表訳の丸め（12,857.06 対 12,857）は一致とみなす'

    if ($script:fail -gt 0) { Write-Host ('照合器の自己確認が失敗しました。failures=' + $script:fail) -ForegroundColor Red; exit 1 }
    Write-Host '照合器の自己確認が通りました。' -ForegroundColor Green
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($PairsPath)) {
    Write-Host '（採点は実機の結果が出てから行う）'
}
