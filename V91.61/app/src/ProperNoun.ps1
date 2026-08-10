<#
  固有名詞の参照一覧。

  この一覧は翻訳後の品質確認に使う。外部送信前のマスキング対象は数値だけで、
  人名・法人名・地名は置き換えない。
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
