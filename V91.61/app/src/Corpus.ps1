<#
  V91.61 参考資料コーパス。

  管理者が原本フォルダの PDF を取り込み、ローカルへ Markdown を貯める。
  取り込みの解析そのものはブラウザ側の WASM（LiteParse）が行い、
  ここはファイルの列挙・読み出し・保存・台帳の管理だけを受け持つ。

  設計上の約束（_docs/V91.61_修正指示書_参考資料コーパスの作成と配布.md）:
   - アプリは共有フォルダへ書き込まない。書き込み先はすべてローカル。
   - 取り込み結果は Get-YakuDataDir 配下へ置く。版更新で消えないため。
   - 原本フォルダの外を読ませない。id は台帳経由で解決し、パスを直接受け取らない。
#>

function Get-YakuCorpusBuildDir {
    # 管理者の取り込み結果。配布前の作業場所。
    return (Get-YakuSubDir 'corpus-build')
}

function Get-YakuCorpusPublishDir {
    # 配布用フォルダの出力先。ここから共有フォルダへは人がコピーする。
    return (Get-YakuSubDir 'corpus-publish')
}

function Get-YakuCorpusDir {
    <#
      利用者側の配布済みコーパス。bootstrap.ps1 が複製し、環境変数で場所を渡す。
      未設定・不在なら空を返す。呼び出し側は「コーパス無し」で動くこと。
    #>
    $dir = [string]$env:YAKULINGO_CORPUS_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    try { $full = [System.IO.Path]::GetFullPath($dir) } catch { return '' }
    if (!(Test-Path -LiteralPath $full -PathType Container)) { return '' }
    return $full
}

function New-YakuCorpusManifest {
    return [ordered]@{
        schema         = 'yaku-corpus-1'
        corpus_version = ''
        updated        = ''
        entries        = @()
    }
}

function Read-YakuCorpusManifest {
    param([Parameter(Mandatory=$true)][string]$Dir)
    $path = Join-Path $Dir 'manifest.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return (New-YakuCorpusManifest) }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
    } catch {
        try { Write-YakuLog "Corpus manifest unreadable. path=$path error=$($_.Exception.Message)" 'WARN' } catch {}
        return (New-YakuCorpusManifest)
    }
    $m = New-YakuCorpusManifest
    foreach ($key in @('schema','corpus_version','updated')) {
        try { if ($obj.PSObject.Properties.Name -contains $key) { $m[$key] = [string]$obj.$key } } catch {}
    }
    # ConvertFrom-Json は1要素の配列を単体へ畳むため、@() で必ず配列に戻す。
    $m['entries'] = @()
    try { if ($obj.PSObject.Properties.Name -contains 'entries') { $m['entries'] = @($obj.entries) } } catch {}
    return $m
}

function Write-YakuCorpusManifest {
    param(
        [Parameter(Mandatory=$true)][string]$Dir,
        [Parameter(Mandatory=$true)]$Manifest
    )
    if (!(Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Manifest['updated'] = (Get-Date).ToString('s')
    $Manifest['entries'] = @($Manifest['entries'] | Sort-Object { [string]$_.source })
    $json = $Manifest | ConvertTo-Json -Depth 6
    Write-YakuTextAtomic -Path (Join-Path $Dir 'manifest.json') -Text $json
}

function Test-YakuPathInside {
    <#
      $Path が $Base の配下にあるかを見る。Serve-YakuStaticFile と同じ方式。
      利用者・管理者の入力がそのままファイルパスにならないようにするための門。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Base,
        [Parameter(Mandatory=$true)][string]$Path
    )
    try {
        $b = [System.IO.Path]::GetFullPath($Base).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
        $p = [System.IO.Path]::GetFullPath($Path)
        return $p.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-YakuCorpusFileId {
    param([Parameter(Mandatory=$true)][string]$Path)
    # 内容で採番する。名前を変えただけの同じ資料を二重に取り込まないため。
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{ Id = $hash.Substring(0, 8); Sha256 = $hash }
}

function Get-YakuCorpusSourceFiles {
    <#
      原本フォルダ直下のサブフォルダを1データベースとして、その配下の PDF を集める。
      直下に置かれた PDF は database='(未分類)' として拾う。捨てない。
    #>
    param([Parameter(Mandatory=$true)][string]$SourceRoot)
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) { return @() }
    if (!(Test-Path -LiteralPath $SourceRoot -PathType Container)) { return @() }
    $rootFull = [System.IO.Path]::GetFullPath($SourceRoot)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter '*.pdf' -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if (-not (Test-YakuPathInside -Base $rootFull -Path $file.FullName)) { continue }
        $rel = $file.FullName.Substring($rootFull.Length).TrimStart([char[]]@('\','/')).Replace('\', '/')
        $db = if ($rel.Contains('/')) { $rel.Substring(0, $rel.IndexOf('/')) } else { '(未分類)' }
        $items.Add([pscustomobject]@{
            FullName = [string]$file.FullName
            Relative = [string]$rel
            Database = [string]$db
            Length   = [int64]$file.Length
        }) | Out-Null
    }
    return @($items.ToArray())
}

function Get-YakuCorpusState {
    <#
      原本フォルダと台帳を突き合わせ、取込済み・未取込を出す。
      ハッシュ計算はファイル数に比例するため、呼び出しは画面操作のときだけにする。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [AllowNull()][string]$BuildDir
    )
    if ([string]::IsNullOrWhiteSpace($BuildDir)) { $BuildDir = Get-YakuCorpusBuildDir }
    $manifest = Read-YakuCorpusManifest -Dir $BuildDir
    $known = @{}
    foreach ($e in @($manifest.entries)) {
        try { $known[[string]$e.id] = $e } catch {}
    }

    $files = @(Get-YakuCorpusSourceFiles -SourceRoot $SourceRoot)
    $pending = New-Object System.Collections.Generic.List[object]
    $byDb = [ordered]@{}
    $seenIds = @{}
    $relocated = 0
    foreach ($f in $files) {
        $ident = Get-YakuCorpusFileId -Path $f.FullName
        $seenIds[$ident.Id] = $true
        $done = $known.ContainsKey($ident.Id)
        # id は内容のハッシュなので、資料を別のフォルダへ移しても同じ id になる。
        # そのままだと「取り込み済み」と判定され、データベース名が古いまま直せない。
        # 置き場所が変わっていたら取り込み直す対象にする。
        $moved = $false
        if ($done -and ([string]$known[$ident.Id].source -ne [string]$f.Relative)) {
            $done = $false; $moved = $true; $relocated++
        }
        if (-not $byDb.Contains($f.Database)) { $byDb[$f.Database] = [pscustomobject]@{ Database=$f.Database; Done=0; Pending=0 } }
        if ($done) { $byDb[$f.Database].Done++ }
        else {
            $byDb[$f.Database].Pending++
            $pending.Add([pscustomobject]@{
                id        = $ident.Id
                sha256    = $ident.Sha256
                database  = $f.Database
                source    = $f.Relative
                path      = $f.FullName
                bytes     = $f.Length
                relocated = $moved
                previous  = $(if ($moved) { [string]$known[$ident.Id].source } else { '' })
            }) | Out-Null
        }
    }
    # 原本が無くなった台帳の項目。消さずに数えるだけにする。判断は人がする。
    $stale = @(@($manifest.entries) | Where-Object { -not $seenIds.ContainsKey([string]$_.id) })
    $databases = @()
    foreach ($k in $byDb.Keys) { $databases += $byDb[$k] }
    return [pscustomobject]@{
        SourceRoot     = [string]$SourceRoot
        BuildDir       = [string]$BuildDir
        Reachable      = (Test-Path -LiteralPath $SourceRoot -PathType Container)
        Databases      = @($databases)
        Pending        = @($pending.ToArray())
        DoneCount      = @($manifest.entries).Count
        RelocatedCount = [int]$relocated
        StaleEntries   = @($stale)
    }
}

function Save-YakuCorpusMarkdown {
    <#
      取り込んだ Markdown を保存し、台帳へ1件加える。
      同じ id が既にあれば置き換える。二重に増やさない（冪等）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$BuildDir,
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Sha256,
        [Parameter(Mandatory=$true)][string]$Database,
        [Parameter(Mandatory=$true)][string]$Source,
        [AllowNull()][string]$Markdown,
        [int]$Pages = 0,
        [string]$Status = 'ok',
        [string]$Note = ''
    )
    $relMd = ([System.IO.Path]::ChangeExtension($Source, '.md')).Replace('\', '/')
    $text = [string]$Markdown
    if ($Status -ne 'failed') {
        $target = Join-Path $BuildDir ($relMd -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        Write-YakuTextAtomic -Path $target -Text $text
    } else {
        $relMd = ''
    }

    $manifest = Read-YakuCorpusManifest -Dir $BuildDir
    # 同じ資料が別のフォルダへ移っていたら、前の .md を消す。
    # 残すと配布物へ古い置き場所のまま入り、データベースが二重になる。
    foreach ($old in @(@($manifest.entries) | Where-Object { [string]$_.id -eq $Id })) {
        $oldRel = [string]$old.markdown
        if ([string]::IsNullOrWhiteSpace($oldRel) -or $oldRel -eq $relMd) { continue }
        $oldPath = Join-Path $BuildDir ($oldRel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        try {
            if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                Remove-Item -LiteralPath $oldPath -Force
                try { Write-YakuLog "Corpus relocated. id=$Id from=$oldRel to=$relMd" 'INFO' } catch {}
            }
            # 空になったフォルダも片付ける。配布物に空の器を作らないため。
            $oldDir = Split-Path -Parent $oldPath
            if ((Test-Path -LiteralPath $oldDir -PathType Container) -and
                (@(Get-ChildItem -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
                Remove-Item -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    $entries = @(@($manifest.entries) | Where-Object { [string]$_.id -ne $Id })
    $entries += [ordered]@{
        id       = $Id
        database = $Database
        source   = $Source
        sha256   = $Sha256
        markdown = $relMd
        pages    = [int]$Pages
        chars    = [int]$text.Length
        status   = $Status
        note     = [string]$Note
    }
    $manifest['entries'] = @($entries)
    Write-YakuCorpusManifest -Dir $BuildDir -Manifest $manifest
    try { Write-YakuLog "Corpus ingest. id=$Id database=$Database pages=$Pages chars=$($text.Length) status=$Status" 'INFO' } catch {}
    return $manifest
}

function Test-YakuCorpusLowText {
    <#
      画像主体の資料を見分ける。エラーにはしない。「取れない」のが正常な資料がある。
      半数以上のページが閾値未満なら low-text とする。
    #>
    param(
        [AllowNull()][object[]]$PageChars,
        [int]$Threshold = 200
    )
    $pages = @($PageChars)
    if ($pages.Count -le 0) { return $true }
    $low = @($pages | Where-Object { [int]$_ -lt $Threshold }).Count
    return ($low * 2 -gt $pages.Count)
}

function New-YakuCorpusPublishFolder {
    <#
      配布用フォルダをローカルへ作る。共有フォルダへは人がコピーする。
      アプリが共有へ書かないのは意図的である（仕様書 §1）。
    #>
    param(
        [AllowNull()][string]$BuildDir,
        [AllowNull()][string]$Version
    )
    if ([string]::IsNullOrWhiteSpace($BuildDir)) { $BuildDir = Get-YakuCorpusBuildDir }
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = (Get-Date).ToString('yyyy-MM-dd') }

    $manifest = Read-YakuCorpusManifest -Dir $BuildDir
    $entries = @(@($manifest.entries) | Where-Object { [string]$_.status -ne 'failed' -and -not [string]::IsNullOrWhiteSpace([string]$_.markdown) })
    if ($entries.Count -le 0) { throw 'CORPUS_PUBLISH_EMPTY: 配布できる取り込み結果がありません。' }

    $target = Join-Path (Get-YakuCorpusPublishDir) $Version
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    foreach ($e in $entries) {
        $rel = ([string]$e.markdown) -replace '/', [System.IO.Path]::DirectorySeparatorChar
        $src = Join-Path $BuildDir $rel
        if (!(Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $target $rel
        $dstDir = Split-Path -Parent $dst
        if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }

    # 配布物には元 PDF を入れない。Markdown と台帳だけを配る。
    $out = New-YakuCorpusManifest
    $out['corpus_version'] = $Version
    $out['entries'] = @($entries)
    Write-YakuCorpusManifest -Dir $target -Manifest $out

    try { Write-YakuLog "Corpus publish. version=$Version entries=$($entries.Count) path=$target" 'INFO' } catch {}
    return [pscustomobject]@{ Version = $Version; Path = $target; Count = $entries.Count }
}
