<#
  対訳の対を貯める層。

  これまでのコーパスは文書ごとの本文しか持っていなかった。英文資料しか
  検索対象にできず、英語で検索しないと当たらない。日本語で「電動化の
  黎明期」と引いて、対応する英文を出したい——それが元々の要求だった。

  Copilot によるアライメントで日英の対が取れるようになったので、その結果を
  ここへ貯める。検索は日本語側にも英語側にも当てられる。

  貯めるのは JSONL。1行1対。追記だけで済み、壊れた行があってもその行だけ
  捨てれば残りは読める。対訳は増え続けるので、書き直しの要らない形を選ぶ。

  同じ対を二度入れないよう、日英を連結した SHA256 で重複を落とす。
  同じ資料を取り込み直しても増殖しない。
#>

function Get-YakuCorpusPairsPath {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database
    )
    return (Join-Path (Join-Path $Dir $Database) 'pairs.jsonl')
}

function Get-YakuCorpusPairKey {
    param([AllowNull()][string]$Ja, [AllowNull()][string]$En)
    # 空白の違いだけで別物にならないよう、比較用に正規化してから鍵にする。
    $norm = (([string]$Ja) -replace '\s+', '') + "`u{241F}" + (([string]$En) -replace '\s+', '').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').Substring(0, 16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-YakuCorpusPairs {
    <#
      壊れた行は黙って捨てる。1行の破損で資料全体が読めなくなるほうが困る。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database
    )
    $path = Get-YakuCorpusPairsPath -Dir $Dir -Database $Database
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @($out.ToArray()) }
    $broken = 0
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { $broken++ }
    }
    if ($broken -gt 0) { try { Write-YakuLog "Corpus pairs had unreadable lines. database=$Database broken=$broken" 'WARN' } catch {} }
    return @($out.ToArray())
}

function Add-YakuCorpusPairs {
    <#
      アライメントの結果を貯める。既にある対は数えるだけで書かない。
      Pairs は JaText / EnText を持つもの（Invoke-YakuDocumentAlignment の出力）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Source,
        [AllowNull()][object[]]$Pairs,
        [switch]$Public
    )
    $path = Get-YakuCorpusPairsPath -Dir $Dir -Database $Database
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }

    $known = @{}
    foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $Database)) {
        try { $known[[string]$p.key] = $true } catch {}
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $added = 0; $skipped = 0
    foreach ($pair in @($Pairs)) {
        $ja = [string]$pair.JaText; $en = [string]$pair.EnText
        if ([string]::IsNullOrWhiteSpace($ja) -or [string]::IsNullOrWhiteSpace($en)) { $skipped++; continue }
        $key = Get-YakuCorpusPairKey -Ja $ja -En $en
        if ($known.ContainsKey($key)) { $skipped++; continue }
        $known[$key] = $true
        $record = [ordered]@{
            key      = $key
            database = $Database
            source   = $Source
            ja       = $ja
            en       = $en
            # 数値の裏取りが通ったかを残す。通っていない対は参考として弱く扱える。
            verified = [bool]$pair.NumberAgree -and [bool]$pair.NumberChecked
            public   = [bool]$Public
        }
        [void]$lines.Add(($record | ConvertTo-Json -Compress -Depth 3))
        $added++
    }
    if ($lines.Count -gt 0) {
        [IO.File]::AppendAllLines($path, [string[]]$lines.ToArray(), [Text.UTF8Encoding]::new($false))
    }
    try { Write-YakuLog "Corpus pairs stored. database=$Database source=$Source added=$added skipped=$skipped" 'INFO' } catch {}
    return [pscustomobject]@{ Added = $added; Skipped = $skipped; Path = $path }
}

function Find-YakuCorpusPairs {
    <#
      日本語でも英語でも引ける。まず素直な部分一致で拾い、長く一致した順に
      並べる。凝った順位付けは後から足せるが、当たらないものは足せない。

      Language を省くと、問い合わせに日本語の文字が含まれるかで判断する。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Query,
        [AllowNull()][string[]]$Databases,
        [ValidateSet('auto', 'ja', 'en')][string]$Language = 'auto',
        [int]$Limit = 20,
        [switch]$VerifiedOnly
    )
    $q = ([string]$Query).Trim()
    if ([string]::IsNullOrWhiteSpace($q)) { return @() }
    $lang = $Language
    if ($lang -eq 'auto') {
        $lang = $(if ($q -match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]') { 'ja' } else { 'en' })
    }
    $dbs = @($Databases)
    if ($dbs.Count -eq 0) {
        $dbs = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($db in $dbs) {
        foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $db)) {
            if ($VerifiedOnly -and -not [bool]$p.verified) { continue }
            $side = [string]$(if ($lang -eq 'ja') { $p.ja } else { $p.en })
            if ([string]::IsNullOrEmpty($side)) { continue }
            $found = $side.IndexOf($q, [StringComparison]::OrdinalIgnoreCase)
            if ($found -lt 0) { continue }
            [void]$hits.Add([pscustomobject]@{
                    Database = [string]$p.database
                    Source   = [string]$p.source
                    Ja       = [string]$p.ja
                    En       = [string]$p.en
                    Verified = [bool]$p.verified
                    # 短い文に当たったほうが、探している言い回しである可能性が高い。
                    Score    = [double]$q.Length / [Math]::Max(1, $side.Length)
                })
        }
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Score -Descending | Select-Object -First $Limit)
}

function Find-YakuCorpusPairsForSegment {
    <#
      CAT の候補ペイン向け。原文セグメント1本に対して、過去の対訳を探す。

      利用者が語を選んで検索するのではなく、行を移るたびに自動で引くので、
      問い合わせは「原文そのもの」になる。市販ツールの翻訳メモリと同じ形。

      3段階で見る。
        完全一致  過去に同じ文を訳している。そのまま差し込める
        包含      過去の文がこの原文を含む／含まれる。参考になる
      一致率は文字数の比で出す。編集距離のほうが精確だが、行を移るたびに
      全件へ掛けると重い。まず動く形を置き、必要になったら精度を上げる。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('ja', 'en')][string]$SourceLanguage = 'ja',
        [AllowNull()][string[]]$Databases,
        [int]$Limit = 5,
        [int]$MinLength = 6
    )
    $t = ([string]$Text).Trim()
    if ($t.Length -lt $MinLength) { return @() }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $norm = { param($s) return (([string]$s) -replace '\s+', '') }
    $tn = & $norm $t
    $dbs = @($Databases)
    if ($dbs.Count -eq 0) {
        $dbs = @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($db in $dbs) {
        foreach ($p in @(Read-YakuCorpusPairs -Dir $Dir -Database $db)) {
            $src = [string]$(if ($SourceLanguage -eq 'ja') { $p.ja } else { $p.en })
            $tgt = [string]$(if ($SourceLanguage -eq 'ja') { $p.en } else { $p.ja })
            if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) { continue }
            $sn = & $norm $src
            if ($sn.Length -lt $MinLength) { continue }
            $exact = [string]::Equals($sn, $tn, [StringComparison]::Ordinal)
            if ($exact) { $ratio = 1.0 }
            elseif ($sn.IndexOf($tn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$tn.Length / $sn.Length }
            elseif ($tn.IndexOf($sn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$sn.Length / $tn.Length }
            else { continue }
            if ($ratio -lt 0.3) { continue }
            [void]$hits.Add([pscustomobject]@{
                    Database = [string]$p.database
                    Source   = $src
                    Target   = $tgt
                    Verified = [bool]$p.verified
                    Exact    = $exact
                    Ratio    = $ratio
                })
        }
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Ratio -Descending | Select-Object -First $Limit)
}
