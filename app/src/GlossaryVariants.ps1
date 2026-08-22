<#
  置換表の項目から、期をずらした版を作る。

  何のためか:

    ECM の項目名には期が入る（「Q1 営業利益」「FY26 販売台数」）。
    シート名も四半期で変わる（利用者の説明 2026-08-06）。
    最新の四半期から置換表を採ると、次の四半期には当たらなくなる。
    期の部分だけが違う同じ項目なのに、毎回採り直すことになる。

    「Q1 を含むものは Q2 版も、FY26 を含むものは FY27 版も用意しておく」
    （利用者の指示 2026-08-06）。予測できるものは先に作っておく。

  なぜ「両側に同じ期がある場合だけ」なのか:

    片側だけを書き換えると、対応していない対ができる。
    「Q1 営業利益」→「Q1 OP」から「Q2 営業利益」→「Q1 OP」を作れば、
    それが完全一致で当たり続ける。誤りを増やす道具になってしまう。

    したがって、原文と訳文の**両方に同じ期があり、両方を同じだけ
    ずらせる**場合に限る。日本語が「第1四半期」で英語が「Q1」でも、
    どちらも「第1四半期」を意味しているので同族として扱う。

  作ったものは実測ではなく予測である:

    実物で確かめたわけではないので、区別できるようにして返す。
    採否は人が決める。実測の対と衝突したら、実測を優先する。
#>

# 期の族。同じ族の中なら、日本語と英語で書き方が違っても同じものとして扱う。
# Literals は並び順が番号になる（上期=1、下期=2）。
$script:YakuPeriodFamilies = @(
    @{
        Family = 'quarter'
        Label  = '四半期'
        Patterns = @(
            @{ Pattern = '(?<![0-9A-Za-z])Q([1-4])(?![0-9])';      Format = 'Q{0}' }
            @{ Pattern = '(?<![0-9A-Za-z])([1-4])Q(?![0-9A-Za-z])'; Format = '{0}Q' }
            @{ Pattern = '第([1-4])四半期';                          Format = '第{0}四半期' }
        )
        Values = @(1, 2, 3, 4)
    }
    @{
        Family = 'half'
        Label  = '半期'
        Patterns = @(
            @{ Pattern = '(?<![0-9A-Za-z])([12])H(?![0-9])'; Format = '{0}H' }
        )
        Literals = @('上期', '下期')
        Values = @(1, 2)
    }
    @{
        Family = 'fy'
        Label  = '年度'
        Patterns = @(
            @{ Pattern = '(?<![0-9A-Za-z])FY\s?([0-9]{2,4})'; Format = 'FY{0}' }
            @{ Pattern = '([0-9]{4})年度';                     Format = '{0}年度' }
            @{ Pattern = '([0-9]{4})年([0-9]{1,2})月期';        Format = '{0}年{1}月期'; Extra = 2 }
        )
        # 年度は次の1つだけ作る。何年先まで作っても当たらないうえ、候補が膨らむ。
        NextOnly = $true
    }
)

function Get-YakuPeriodFamilies {
    return @($script:YakuPeriodFamilies)
}

function Get-YakuPeriodIndexes {
    <#
      文字列の中から、その族の期番号を集める。
      同じ族の別の書き方（Q1 と 第1四半期）はどちらも 1 として返る。
    #>
    param([AllowNull()][string]$Text, [Parameter(Mandatory=$true)]$Family)
    $t = [string]$Text
    $found = New-Object System.Collections.Generic.List[int]
    if ([string]::IsNullOrEmpty($t)) { return @() }
    foreach ($p in @($Family.Patterns)) {
        foreach ($m in [regex]::Matches($t, [string]$p.Pattern)) {
            $v = 0
            if ([int]::TryParse([string]$m.Groups[1].Value, [ref]$v)) { [void]$found.Add($v) }
        }
    }
    foreach ($lit in @($Family.Literals)) {
        if ([string]::IsNullOrEmpty([string]$lit)) { continue }
        if ($t.Contains([string]$lit)) { [void]$found.Add(([array]::IndexOf(@($Family.Literals), [string]$lit)) + 1) }
    }
    return @(@($found.ToArray()) | Sort-Object -Unique)
}

function Set-YakuPeriodIndex {
    <#
      その族の期を、指定の番号へ書き換える。書き方は元のまま保つ。
      FY26 は FY27 に、FY2026 は FY2027 に（桁の幅を変えない）。
    #>
    param([AllowNull()][string]$Text, [Parameter(Mandatory=$true)]$Family, [Parameter(Mandatory=$true)][int]$NewIndex)
    $t = [string]$Text
    if ([string]::IsNullOrEmpty($t)) { return $t }
    foreach ($p in @($Family.Patterns)) {
        $format = [string]$p.Format
        $extra = 0
        if ($p.ContainsKey('Extra')) { $extra = [int]$p.Extra }
        $t = [regex]::Replace($t, [string]$p.Pattern, {
            param($m)
            $orig = [string]$m.Groups[1].Value
            # 桁の幅を保つ。FY26 -> FY27、FY2026 -> FY2027。
            $num = ([string]$NewIndex).PadLeft($orig.Length, '0')
            if ($extra -ge 2) { return ($format -f $num, [string]$m.Groups[2].Value) }
            return ($format -f $num)
        })
    }
    $lits = @($Family.Literals)
    if ($lits.Count -gt 0 -and $NewIndex -ge 1 -and $NewIndex -le $lits.Count) {
        for ($i = 0; $i -lt $lits.Count; $i++) {
            if ($i -eq ($NewIndex - 1)) { continue }
            $t = $t.Replace([string]$lits[$i], [string]$lits[$NewIndex - 1])
        }
    }
    return $t
}

function Get-YakuGlossaryPeriodVariants {
    <#
      1つの対から、期をずらした版を作る。

      条件は3つ。どれか1つでも欠けたら作らない。
       - 原文と訳文の両方に、同じ族の期がある
       - どちらも期が1種類だけ（複数あると、どれをずらすか決められない）
       - 両者の期番号が一致している（食い違っていれば元の対を疑うべき）
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Target
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($family in $script:YakuPeriodFamilies) {
        $sIdx = @(Get-YakuPeriodIndexes -Text $Source -Family $family)
        $tIdx = @(Get-YakuPeriodIndexes -Text $Target -Family $family)
        if ($sIdx.Count -ne 1 -or $tIdx.Count -ne 1) { continue }
        if ([int]$sIdx[0] -ne [int]$tIdx[0]) { continue }
        $current = [int]$sIdx[0]
        $candidates = @()
        if ([bool]$family.NextOnly) {
            $candidates = @($current + 1)
        } else {
            $candidates = @(@($family.Values) | Where-Object { [int]$_ -ne $current })
        }
        foreach ($n in $candidates) {
            $ns = Set-YakuPeriodIndex -Text $Source -Family $family -NewIndex ([int]$n)
            $nt = Set-YakuPeriodIndex -Text $Target -Family $family -NewIndex ([int]$n)
            # 片側しか変わらなかったら作らない。対応していない対になる。
            if ($ns -eq $Source -or $nt -eq $Target) { continue }
            [void]$out.Add([pscustomobject]@{
                Source = $ns
                Target = $nt
                Family = [string]$family.Family
                Origin = ('予測(' + [string]$family.Label + [string]$n + ')')
            })
        }
    }
    return @($out.ToArray())
}

function Add-YakuGlossaryPeriodVariants {
    <#
      候補の一覧へ、期をずらした版を足す。

      実測の対と衝突したら実測を採る。予測は実物で確かめていないので、
      観測された対を上書きしてはならない。
      作った版どうしが衝突した場合も、先に来たほうを残して数えない。
    #>
    param([AllowNull()][object[]]$Entries)
    $list = @($Entries)
    $seen = @{}
    foreach ($e in $list) {
        $k = ([string]$e.Source).Trim()
        if (-not [string]::IsNullOrEmpty($k)) { $seen[$k] = $true }
    }
    $added = New-Object System.Collections.Generic.List[object]
    foreach ($e in $list) {
        foreach ($v in @(Get-YakuGlossaryPeriodVariants -Source ([string]$e.Source) -Target ([string]$e.Target))) {
            $k = ([string]$v.Source).Trim()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $copy = [pscustomobject]@{
                Source     = [string]$v.Source
                Target     = [string]$v.Target
                Count      = 0
                Confidence = [string]$e.Confidence
                Conflict   = $false
                Origin     = [string]$v.Origin
                Samples    = @('（' + [string]$e.Source + ' から）')
            }
            [void]$added.Add($copy)
        }
    }
    # 実測には実測の印を付ける。予測と並ぶので、区別が要る。
    foreach ($e in $list) {
        try { $e | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '実測' -Force } catch {}
    }
    return @(@($list) + @($added.ToArray()))
}

function ConvertTo-YakuPeriodNeutralName {
    <#
      期の部分を伏せた名前にする。シートの突き合わせに使う。

      シート名は四半期で変わる（利用者の説明 2026-08-06）。
      日英で表記が揃わないことがあるので（Q1 と 1Q など）、
      名前が完全一致しないときの二段目としてこれで比べる。
      期以外が違うシートは、これでも一致しないので結ばれない。
    #>
    param([AllowNull()][string]$Name)
    $t = [string]$Name
    if ([string]::IsNullOrEmpty($t)) { return '' }
    foreach ($family in $script:YakuPeriodFamilies) {
        foreach ($p in @($family.Patterns)) { $t = [regex]::Replace($t, [string]$p.Pattern, '#') }
        foreach ($lit in @($family.Literals)) { if (-not [string]::IsNullOrEmpty([string]$lit)) { $t = $t.Replace([string]$lit, '#') } }
    }
    $t = [regex]::Replace($t, '[0-9]{4,8}', '#')
    $t = [regex]::Replace($t, '[\s_\-]+', '')
    return $t.Trim()
}
