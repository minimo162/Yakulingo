<#
  翻訳メモリ。利用者自身が確定した訳を貯める。

  候補ペインの3本柱のうち、これが最後の1本になる。

    用語集      語の対応。人が育てる
    過去の対訳  公表訳から機械で取った対応。意訳が多く、そのままは使いにくい
    翻訳メモリ  自分が確定した訳。そのまま差し込める

  一番効くのはこれである。公表訳は「読ませる訳」なので直訳では当たらないが、
  翻訳メモリは自分の文体で、自分が正しいと判断したものだけが入る。

  置き場所は個人ごと。利用者の説明（2026-08-06）に従う。
  「tm の置き場所は基本的には個人で持つのが運用的にもセキュリティ的にも良い。
   ただし開発者や部署の代表者が作成して配布ということもありうる」
  配布はあとから足せるよう、読み取り先を複数持てる形にしておく。

  形式は対訳コーパスと同じ JSONL。1行1対で追記だけで済み、
  壊れた行があってもその行だけ捨てれば残りは読める。
#>

function Get-YakuTranslationMemoryPath {
    param([ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en')
    $dir = Get-YakuSubDir 'memory'
    return (Join-Path $dir ('tm-' + $Direction + '.jsonl'))
}

function ConvertTo-YakuTranslationMemoryKey {
    <#
      同じ原文とみなす鍵。空白の違いと全角半角の揺れを吸収する。
      表記が少し違うだけで別物として貯まると、候補が重複して読みにくい。
    #>
    param([AllowNull()][string]$Text)
    $s = ([string]$Text) -replace '\s+', ''
    $full = '０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ．，％（）'
    $half = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.,%()"
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $i = $full.IndexOf($ch)
        if ($i -ge 0) { $null = $sb.Append($half[$i]) } else { $null = $sb.Append($ch) }
    }
    return $sb.ToString().ToLowerInvariant()
}

function Read-YakuTranslationMemory {
    <#
      壊れた行は黙って捨てる。1行の破損で全部読めなくなるほうが困る。
      同じ原文が何度も確定された場合は、あとの行が前の行を上書きする。
      追記だけで「直した」を表せるようにするため。
    #>
    param(
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [AllowNull()][string]$Path
    )
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $map }
    $broken = 0
    foreach ($line in [IO.File]::ReadAllLines($target, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json
            $k = [string]$o.key
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            $map[$k] = $o
        } catch { $broken++ }
    }
    if ($broken -gt 0) { try { Write-YakuLog "Translation memory had unreadable lines. broken=$broken" 'WARN' } catch {} }
    return $map
}

function Add-YakuTranslationMemoryEntry {
    <#
      確定した訳を1件貯める。原文か訳文が空なら何もしない。
      同じ内容が既にあるなら書かない。押すたびに同じ行が増えないように。
    #>
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target,
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [string]$Origin = 'manual',
        [AllowNull()][string]$Path
    )
    $src = ([string]$Source).Trim()
    $tgt = ([string]$Target).Trim()
    if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) {
        return [pscustomobject]@{ Added = $false; Reason = 'empty' }
    }
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuTranslationMemoryPath -Direction $Direction } else { $Path }
    $key = ConvertTo-YakuTranslationMemoryKey -Text $src
    $existing = Read-YakuTranslationMemory -Direction $Direction -Path $target
    if ($existing.Contains($key) -and [string]$existing[$key].target -eq $tgt) {
        return [pscustomobject]@{ Added = $false; Reason = 'same' }
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $record = [ordered]@{
        key       = $key
        source    = $src
        target    = $tgt
        direction = $Direction
        origin    = $Origin
        saved     = (Get-Date).ToString('s')
    }
    [IO.File]::AppendAllLines($target, [string[]]@(($record | ConvertTo-Json -Compress -Depth 3)), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Added = $true; Reason = $(if ($existing.Contains($key)) { 'updated' } else { 'new' }); Key = $key }
}

function Find-YakuTranslationMemory {
    <#
      原文セグメント1本に対して、過去に自分が確定した訳を探す。

      完全一致を最優先にする。市販ツールが 100% 一致を別格に扱うのと同じで、
      同じ文を二度違う訳にしないことが一貫性の中身だからである。
      部分一致は文字数の比で一致率を出す。編集距離のほうが精確だが、
      行を移るたびに全件へ掛けると重い。まず動く形を置く。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en',
        [int]$Limit = 5,
        [int]$MinLength = 4,
        [AllowNull()][string]$Path
    )
    $t = ([string]$Text).Trim()
    if ($t.Length -lt $MinLength) { return @() }
    $entries = Read-YakuTranslationMemory -Direction $Direction -Path $Path
    if ($entries.Count -eq 0) { return @() }
    $tn = ConvertTo-YakuTranslationMemoryKey -Text $t
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($k in $entries.Keys) {
        $e = $entries[$k]
        $sn = [string]$k
        if ($sn.Length -lt $MinLength) { continue }
        $exact = [string]::Equals($sn, $tn, [StringComparison]::Ordinal)
        if ($exact) { $ratio = 1.0 }
        elseif ($sn.IndexOf($tn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$tn.Length / $sn.Length }
        elseif ($tn.IndexOf($sn, [StringComparison]::Ordinal) -ge 0) { $ratio = [double]$sn.Length / $tn.Length }
        else { continue }
        if ($ratio -lt 0.3) { continue }
        [void]$hits.Add([pscustomobject]@{
                Source = [string]$e.source
                Target = [string]$e.target
                Exact  = $exact
                Ratio  = $ratio
                Saved  = [string]$e.saved
            })
    }
    return @(@($hits.ToArray()) | Sort-Object -Property Ratio -Descending | Select-Object -First $Limit)
}
