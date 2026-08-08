<#
  固有名詞のマスク。

  人名・監査法人名・地名は、正確さがすべてで創造性が要らない。にもかかわらず
  読みが自明でないものが多く、Copilot に任せると揺れる。

    毛籠   → Moro    （Kego / Mōro になりうる）
    ガイトン → Guyton  （Gaiton になりうる）
    あずさ  → AZSA    （Azusa になりうる）

  そこで送る前に置き換え、返ってきてから戻す。Copilot の判断を通らないので、
  原理的に間違わない（利用者の判断 2026-08-08）。

  数値マスクと同じ仕組みだが、目的が違う。数値は「見せない」ため、
  固有名詞は「間違わせない」ため。だから記号も分ける（[[N1]] と [[P1]]）。

  順番が大事である。固有名詞を先に置き換える。住所には全角数字が入っており
  （新地３番１号）、数値マスクが先に走ると固有名詞の照合が壊れる。
#>

function Get-YakuProperNounPath {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path $Root 'propernouns.csv')
}

function Get-YakuProperNounEntries {
    <#
      一覧を読む。長いものから順に並べる。
      「毛籠 勝弘」を先に当てないと、「毛籠」だけが置き換わって
      「Moro 勝弘」という半端なものができる。
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Get-YakuProperNounPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $key = ''
    try {
        $fi = Get-Item -LiteralPath $path -ErrorAction Stop
        $key = [string]$fi.LastWriteTimeUtc.Ticks + '|' + [string]$fi.Length
    } catch { $key = [string](Get-Date).Ticks }
    if ($script:YakuProperNounCache -and [string]$script:YakuProperNounCache.Key -eq $key) {
        return @($script:YakuProperNounCache.Entries)
    }
    $list = New-Object System.Collections.Generic.List[object]
    $broken = 0
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.UTF8Encoding]::new($true))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*source\s*,\s*target\s*$') { continue }
        $m = [regex]::Match($line, '^\s*(?:"(?<a>(?:[^"]|"")*)"|(?<a>[^,]*))\s*,\s*(?:"(?<b>(?:[^"]|"")*)"|(?<b>.*?))\s*$')
        if (-not $m.Success) { $broken++; continue }
        $src = $m.Groups['a'].Value.Replace('""', '"').Trim()
        $tgt = $m.Groups['b'].Value.Replace('""', '"').Trim()
        if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) { continue }
        [void]$list.Add([pscustomobject]@{ Source = $src; Target = $tgt })
    }
    if ($broken -gt 0) { try { Write-YakuLog "Proper noun list had unreadable lines. broken=$broken" 'WARN' } catch {} }
    $ordered = @($list.ToArray() | Sort-Object -Property @{ Expression = { ([string]$_.Source).Length }; Descending = $true })
    $script:YakuProperNounCache = [pscustomobject]@{ Key = $key; Entries = $ordered }
    return @($ordered)
}

function New-YakuProperNounMaskMap {
    <#
      固有名詞を [[P1]] へ置き換え、戻すための対応表を返す。
      同じ語が何度出ても同じ記号を使う。訳文でも同じ語になるようにするため。
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $s = [string]$Text
    $map = @{}
    if ([string]::IsNullOrEmpty($s)) { return [pscustomobject]@{ Text = ''; Map = $map; MaskedCount = 0 } }
    $entries = @(Get-YakuProperNounEntries -Root $Root)
    if ($entries.Count -eq 0) { return [pscustomobject]@{ Text = $s; Map = $map; MaskedCount = 0 } }
    $byTarget = @{}
    $n = 0
    foreach ($e in $entries) {
        $src = [string]$e.Source
        if ([string]::IsNullOrEmpty($src)) { continue }
        if ($s.IndexOf($src, [StringComparison]::Ordinal) -lt 0) { continue }
        $tgt = [string]$e.Target
        if ($byTarget.ContainsKey($tgt)) {
            # 同じ英語に落ちる別表記（毛籠 / 毛籠 勝弘 など）は同じ記号にまとめる。
            $token = [string]$byTarget[$tgt]
        }
        else {
            $n++
            $token = '[[P' + [string]$n + ']]'
            $byTarget[$tgt] = $token
            $map[$token] = $tgt
        }
        $s = $s.Replace($src, $token)
    }
    return [pscustomobject]@{ Text = $s; Map = $map; MaskedCount = $map.Count }
}

function Restore-YakuProperNounMask {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][hashtable]$Map
    )
    $result = [string]$Text
    if ([string]::IsNullOrEmpty($result) -or $null -eq $Map -or $Map.Count -eq 0) { return $result }
    # 番号の大きい順に戻す。[[P1]] が [[P10]] の一部を壊さないため。
    foreach ($token in @($Map.Keys | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) } -Descending)) {
        $result = $result.Replace([string]$token, [string]$Map[$token])
    }
    return $result
}

function Test-YakuProperNounMaskIntegrity {
    <#
      戻す前に、記号が消えていないかを見る。消えていれば固有名詞が訳文から
      落ちているので、黙って戻してはいけない。
    #>
    param(
        [AllowNull()][string]$MaskedSource,
        [AllowNull()][string]$Translated,
        [AllowNull()][hashtable]$Map
    )
    $missing = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Map -or $Map.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Missing = @() } }
    foreach ($token in @($Map.Keys)) {
        if (([string]$MaskedSource).IndexOf([string]$token, [StringComparison]::Ordinal) -lt 0) { continue }
        if (([string]$Translated).IndexOf([string]$token, [StringComparison]::Ordinal) -lt 0) { [void]$missing.Add([string]$token) }
    }
    return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Missing = @($missing.ToArray()) }
}
