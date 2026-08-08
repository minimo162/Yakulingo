<#
  個人用の用語集。

  配布されている用語集は、いまは開発者が代わりに作っているもので、
  本来は各自が自分に必要な語を貯めるべきものである
  （利用者の整理 2026-08-08）。市販ツールでも、共通のものと作業用のものを
  2段重ねにするのが普通の運用で、作業用が優先される。

  運用はこうなる。

    取り込む → 用語集を当てる → 埋まらなかった行が残る
    → 表の項目なら自分で訳を入れ、この個人用へ足す
    → 次からは機械的に埋まる

  この輪が閉じていないと、「用語集を直す」という方針そのものが回らない。
  これまでは CSV を手で開いて追記するしかなかった。

  形式は配布用と同じ2列の CSV。同じ道具で開けるほうが、
  中身を見たいときに困らない。
#>

function Get-YakuPersonalGlossaryPath {
    return (Join-Path (Get-YakuSubDir 'glossary') 'personal.csv')
}

function Read-YakuPersonalGlossary {
    <#
      個人用の用語集を読む。壊れた行はその行だけ捨てる。
      同じ見出し語が二度出たら、あとの行を採る。追記だけで直せるように。
    #>
    $path = Get-YakuPersonalGlossaryPath
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $broken = 0
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.UTF8Encoding]::new($true))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # 素朴な2列 CSV。引用符つきにも耐える。
        $m = [regex]::Match($line, '^\s*(?:"(?<a>(?:[^"]|"")*)"|(?<a>[^,]*))\s*,\s*(?:"(?<b>(?:[^"]|"")*)"|(?<b>.*?))\s*$')
        if (-not $m.Success) { $broken++; continue }
        $src = $m.Groups['a'].Value.Replace('""', '"').Trim()
        $tgt = $m.Groups['b'].Value.Replace('""', '"').Trim()
        if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) { continue }
        $map[$src] = $tgt
    }
    if ($broken -gt 0) { try { Write-YakuLog "Personal glossary had unreadable lines. broken=$broken" 'WARN' } catch {} }
    return $map
}

function Add-YakuPersonalGlossaryEntry {
    <#
      1件足す。同じ見出し語で同じ訳が既にあるなら書かない。
      押すたびに同じ行が増えると、あとで中身を見たときに読みにくい。
    #>
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target
    )
    $src = ([string]$Source).Trim()
    $tgt = ([string]$Target).Trim()
    if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) {
        return [pscustomobject]@{ Added = $false; Reason = 'empty' }
    }
    # 文章は入れない。用語集は表のラベルのための道具で、文を入れると
    # 完全一致が当たらないうえ、一覧が読めなくなる。
    if ($src.Length -gt 40 -or $src -match '[。．]') {
        return [pscustomobject]@{ Added = $false; Reason = 'too-long' }
    }
    $existing = Read-YakuPersonalGlossary
    if ($existing.Contains($src) -and [string]$existing[$src] -eq $tgt) {
        return [pscustomobject]@{ Added = $false; Reason = 'same' }
    }
    $path = Get-YakuPersonalGlossaryPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $quote = { param([string]$V) if ($V -match '[",]') { return '"' + $V.Replace('"', '""') + '"' } return $V }
    $line = (& $quote $src) + ',' + (& $quote $tgt)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [IO.File]::WriteAllLines($path, [string[]]@('source,target', $line), [Text.UTF8Encoding]::new($true))
    }
    else {
        [IO.File]::AppendAllLines($path, [string[]]@($line), [Text.UTF8Encoding]::new($true))
    }
    try { Write-YakuLog "Personal glossary entry added. source=$src" 'INFO' } catch {}
    return [pscustomobject]@{ Added = $true; Reason = $(if ($existing.Contains($src)) { 'updated' } else { 'new' }) }
}
