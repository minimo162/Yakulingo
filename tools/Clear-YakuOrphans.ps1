<#
.SYNOPSIS
  回帰テストが残した孤児プロセスと使い捨て Edge プロファイルを刈る。

.DESCRIPTION
  テストを回したあとに残るもののうち、次の周回を止めるものだけを落とす。

  1. 親が消滅した YakuLingo サーバー（powershell.exe）
     Server.ps1 は利用者ごとの Mutex（Local\YakuLingo-<hash>）を握るので、
     待ち受けが死んでいても残っていると次の起動が
     「別のYakuLingoプロセスが起動中ですが、既存画面を安全に確認できませんでした」
     で落ちる。V64-HTTP-Boundary-Test.ps1 が実際にこれで赤になった。
  2. 使い捨てプロファイル（Temp 配下）の msedge.exe
     画面調査用に立てた Edge が CDP ポート（既定 9433）を占拠すると、
     アプリが未ログインのプロファイルに当たる。
  3. 上の使い捨てプロファイルのディレクトリ残骸（Temp 配下に限る）

  落とす判定は「印」で決める。印が無いものは落とさない（-IncludeAppServer で明示可）。

.NOTES
  待ち受けポートの有無は生死の証拠にならない。この製品の HTTP は HttpListener
  （http.sys）なので、実測すると Get-NetTCPConnection -OwningProcess <サーバーPID>
  は空を返す。生きていても 0 件になるため、判定には使っていない。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # 列挙だけして落とさない。-WhatIf と同じ結果を、明示的な名前で得るためのもの。
    [switch]$ListOnly,

    # 対象をこの PID に限る。自己検証と、外科的に1つだけ落としたいときに使う。
    [int[]]$OnlyProcessId = @(),

    # 扱う種類を絞る。'edge' だけ掃除してサーバーには触らない、という使い方ができる。
    # 自己検証は、自分が作ったもの以外に手を出さないためにこれを使う。
    [ValidateSet('all', 'servers', 'edge', 'dirs')][string[]]$Scope = @('all'),

    # 使い捨て Edge プロファイルとみなすフォルダ名。Temp 配下であることは別途必須。
    [string[]]$DisposableProfilePattern = @('yakulingo-ui-audit-*', 'yakulingo-reaper-selftest-*'),

    # この範囲の -Port は「利用者が実際に使っている可能性がある」とみなし、印にしない。
    [int]$AppPortMin = 8765,
    [int]$AppPortMax = 9999,

    # 印の無いサーバー孤児も落とす。既定は落とさない（利用者の実アプリかもしれない）。
    [switch]$IncludeAppServer,

    # ディレクトリ残骸は、この分数より古いものだけ消す。起動直後のものを巻き込まない。
    [int]$ProfileIdleMinutes = 5
)

$ErrorActionPreference = 'Stop'

# -WhatIf の下でモジュールが自動読み込みされると、別名の登録まで
# 「What if: Performing the operation "Set Alias"」として12行出る。
# 掃除の計画が読めなくなるので、先に読み込んでおく。
# -WhatIf:$false を Import-Module へ渡すだけでは消えない。モジュール側の Set-Alias が
# 呼び出し元の $WhatiIfPreference を見るため、環境変数のように一時的に戻す必要がある。
$script:YakuReaperWhatIfSaved = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module CimCmdlets -ErrorAction SilentlyContinue | Out-Null
} catch {} finally { $WhatIfPreference = $script:YakuReaperWhatIfSaved }

# 一般的な .ps1 として dot-source されたときは、定義だけして本体を走らせない。
# 自己検証がここの判定関数を単体で呼べるようにするため。
$script:YakuReaperDotSourced = ($MyInvocation.InvocationName -eq '.')

# ---------------------------------------------------------------------------
# コマンドラインの分解
# ---------------------------------------------------------------------------

function Split-YakuCommandLine {
    <#
      Win32_Process.CommandLine を引数へ分解する。実測した3つの形をすべて通す。
        -File "C:\path with spaces\x.ps1"
        --user-data-dir="C:\path with spaces\edge-profile"
        "--user-data-dir=C:\Users\...\Edge\User Data"
      バックスラッシュによる引用符のエスケープは扱わない（この用途では現れない）。
    #>
    param([AllowNull()][string]$CommandLine)

    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return ,$tokens.ToArray() }

    $sb = New-Object System.Text.StringBuilder
    $inQuote = $false
    $hasContent = $false
    foreach ($ch in $CommandLine.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; $hasContent = $true; continue }
        if ((-not $inQuote) -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($hasContent) { $tokens.Add($sb.ToString()) | Out-Null }
            $sb.Length = 0
            $hasContent = $false
            continue
        }
        $sb.Append($ch) | Out-Null
        $hasContent = $true
    }
    if ($hasContent) { $tokens.Add($sb.ToString()) | Out-Null }
    return ,$tokens.ToArray()
}

function Get-YakuFileArgument {
    <#
      powershell.exe の -File が指す .ps1 を返す。
      「コマンドラインに Server.ps1 という文字列が含まれる」だけでは返さない。
      実際、Win32_Process をフィルタする自分の調査コマンド自身が -like '*Server.ps1*'
      に一致した。文字列一致で殺しにいくと、自分の測定用プロセスを殺す。
    #>
    param([string[]]$Tokens)

    if ($null -eq $Tokens) { return '' }
    for ($i = 0; $i -lt $Tokens.Length; $i++) {
        $token = [string]$Tokens[$i]
        if ($token -match '^-(?i:f|fi|fil|file)$') {
            if ($i + 1 -lt $Tokens.Length) { return [string]$Tokens[$i + 1] }
            return ''
        }
        $m = [regex]::Match($token, '^-(?i:file):(.+)$')
        if ($m.Success) { return [string]$m.Groups[1].Value }
    }
    return ''
}

function Test-YakuSwitchToken {
    param([string[]]$Tokens, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Tokens) { return $false }
    foreach ($token in $Tokens) {
        $text = [string]$token
        if ($text.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($text.StartsWith($Name + ':', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-YakuPortArgument {
    param([string[]]$Tokens)
    if ($null -eq $Tokens) { return 0 }
    for ($i = 0; $i -lt $Tokens.Length; $i++) {
        $token = [string]$Tokens[$i]
        $value = ''
        if ($token -match '^-(?i:port)$') {
            if ($i + 1 -lt $Tokens.Length) { $value = [string]$Tokens[$i + 1] }
        } else {
            $m = [regex]::Match($token, '^-(?i:port)[:=](.+)$')
            if ($m.Success) { $value = [string]$m.Groups[1].Value }
        }
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed)) { return $parsed }
    }
    return 0
}

function Get-YakuUserDataDirArgument {
    param([string[]]$Tokens)
    if ($null -eq $Tokens) { return '' }
    foreach ($token in $Tokens) {
        $text = [string]$token
        if ($text.StartsWith('--user-data-dir=', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $text.Substring('--user-data-dir='.Length)
        }
    }
    return ''
}

# ---------------------------------------------------------------------------
# パスの判定
# ---------------------------------------------------------------------------

function Test-YakuPathUnder {
    # $Child が $Parent の下（または同一）かを、正規化したうえで判定する。
    param([AllowNull()][string]$Child, [AllowNull()][string]$Parent)
    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    try {
        $c = [System.IO.Path]::GetFullPath($Child).TrimEnd([char[]]@('\', '/'))
        $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('\', '/'))
    } catch { return $false }
    if ($c.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-YakuTempRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $candidates = @(
        [string]$env:TEMP,
        [string]$env:TMP,
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Temp' } else { '' }),
        $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'Temp' } else { '' })
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try { $full = [System.IO.Path]::GetFullPath($candidate).TrimEnd([char[]]@('\', '/')) } catch { continue }
        $known = $false
        foreach ($existing in $roots.ToArray()) {
            if ([string]$existing -eq $full) { $known = $true; break }
        }
        if (-not $known) { $roots.Add($full) | Out-Null }
    }
    return $roots.ToArray()
}

function Get-YakuRealEdgeProfilePath {
    # 本物（ログイン済み）の Copilot 用プロファイル。src/EdgeLaunch.ps1 と同じ場所。
    # $home という名前は使わない（PowerShell の自動変数 $HOME と衝突する）。
    $dataHome = [string]$env:YAKULINGO_DATA_DIR
    if ([string]::IsNullOrWhiteSpace($dataHome)) {
        $profileRoot = [string]$env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = [Environment]::GetFolderPath('UserProfile') }
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { return '' }
        $dataHome = Join-Path $profileRoot '.yakulingo-ps'
    }
    return (Join-Path $dataHome 'edge-profile')
}

function Test-YakuProtectedEdgeProfile {
    <#
      落としてはならないプロファイル。
      - ~/.yakulingo-ps/edge-profile（ログイン済みの本物）とその配下
      - ~/.yakulingo-ps 全体（アプリのデータ）
      - 通常の Edge（%LOCALAPPDATA%\Microsoft\Edge\User Data）とその配下
      Temp 封じ込めだけでも届かないが、二重にする。誤爆の代償が大きい。
    #>
    param([AllowNull()][string]$UserDataDir)
    if ([string]::IsNullOrWhiteSpace($UserDataDir)) { return $true }

    $real = Get-YakuRealEdgeProfilePath
    if ((-not [string]::IsNullOrWhiteSpace($real)) -and (Test-YakuPathUnder -Child $UserDataDir -Parent $real)) { return $true }
    if ((-not [string]::IsNullOrWhiteSpace($real)) -and (Test-YakuPathUnder -Child $UserDataDir -Parent (Split-Path -Parent $real))) { return $true }
    if ($env:LOCALAPPDATA) {
        $default = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge'
        if (Test-YakuPathUnder -Child $UserDataDir -Parent $default) { return $true }
    }
    if ($env:PROGRAMFILES) {
        if (Test-YakuPathUnder -Child $UserDataDir -Parent $env:PROGRAMFILES) { return $true }
    }
    return $false
}

function Test-YakuDisposableEdgeProfile {
    <#
      使い捨てプロファイルの条件（すべて満たすときだけ真）。
        1. Temp 配下であること
        2. パスのどこかの区切りが $Pattern に一致すること
        3. 保護対象でないこと
    #>
    param(
        [AllowNull()][string]$UserDataDir,
        [string[]]$Pattern = @('yakulingo-ui-audit-*')
    )
    if ([string]::IsNullOrWhiteSpace($UserDataDir)) { return $false }
    if (Test-YakuProtectedEdgeProfile -UserDataDir $UserDataDir) { return $false }

    try { $full = [System.IO.Path]::GetFullPath($UserDataDir) } catch { return $false }

    $underTemp = $false
    foreach ($root in @(Get-YakuTempRoots)) {
        if (Test-YakuPathUnder -Child $full -Parent $root) { $underTemp = $true; break }
    }
    if (-not $underTemp) { return $false }

    foreach ($segment in $full.Split([char[]]@('\', '/'))) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        foreach ($glob in $Pattern) {
            if ([string]::IsNullOrWhiteSpace($glob)) { continue }
            if ($segment -like $glob) { return $true }
        }
    }
    return $false
}

function Get-YakuServerScriptKind {
    <#
      -File が指す .ps1 が YakuLingo のサーバーかどうか、実体を見て決める。
        server-script  … src\Server.ps1 を直接 -File で起動した形。
                          出荷されるランチャーはこの形を使わない（Start-YakuLingo.ps1 が
                          & で同一プロセス内から呼ぶ）。テスト・手作業だけがこの形になる。
        launcher-script… Start-YakuLingo.ps1。利用者の実アプリもこの形なので、
                          これ単体では落とす理由にしない。
      隣にあるはずのファイルまで確認する。名前一致だけでは足りない。
    #>
    param([AllowNull()][string]$ScriptPath)

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return '' }
    # パスとして不正な文字列は、例外にせず「対象外」に落とす。
    # IsPathRooted も GetFullPath も ArgumentException を投げる。掃除の道具が
    # 途中で止まると、掃除できたのかどうかが分からなくなる。
    $full = ''
    $leaf = ''
    $dir = ''
    try {
        if (-not [System.IO.Path]::IsPathRooted($ScriptPath)) { return '' }
        $full = [System.IO.Path]::GetFullPath($ScriptPath)
        $leaf = [System.IO.Path]::GetFileName($full)
        $dir = [System.IO.Path]::GetDirectoryName($full)
    } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }

    if ($leaf.Equals('Server.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not ([System.IO.Path]::GetFileName($dir)).Equals('src', [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'SrcModules.ps1') -PathType Leaf)) { return '' }
        $appRoot = [System.IO.Path]::GetDirectoryName($dir)
        if ([string]::IsNullOrWhiteSpace($appRoot)) { return '' }
        if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'Start-YakuLingo.ps1') -PathType Leaf)) { return '' }
        return 'server-script'
    }
    if ($leaf.Equals('Start-YakuLingo.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'src\Server.ps1') -PathType Leaf)) { return '' }
        return 'launcher-script'
    }
    return ''
}

# ---------------------------------------------------------------------------
# プロセスの親子
# ---------------------------------------------------------------------------

function Get-YakuProcessTable {
    $table = @{}
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $table[[int]$proc.ProcessId] = $proc
    }
    return $table
}

function Test-YakuOrphanProcess {
    <#
      孤児の条件。
        - 親 PID が今の一覧に無い
        - もしくは、その PID の作成時刻が自分より後（＝PID が再利用されている）
      親が生きているものは落とさない。実行中のテストのサーバーを殺さないため。
    #>
    param([Parameter(Mandatory = $true)]$Process, [Parameter(Mandatory = $true)][hashtable]$Table)

    $parentId = [int]$Process.ParentProcessId
    if ($parentId -le 0) { return $true }
    if (-not $Table.ContainsKey($parentId)) { return $true }
    $parent = $Table[$parentId]
    try {
        $parentCreated = [datetime]$parent.CreationDate
        $selfCreated = [datetime]$Process.CreationDate
        if ($parentCreated -gt $selfCreated) { return $true }
    } catch {}
    return $false
}

function Get-YakuAncestorProcessIds {
    param([Parameter(Mandatory = $true)][int]$ProcessId, [Parameter(Mandatory = $true)][hashtable]$Table)
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    $null = $set.Add($ProcessId)
    $current = $ProcessId
    for ($depth = 0; $depth -lt 32; $depth++) {
        if (-not $Table.ContainsKey($current)) { break }
        $parentId = [int]$Table[$current].ParentProcessId
        if ($parentId -le 0 -or $parentId -eq $current) { break }
        if (-not $set.Add($parentId)) { break }
        $current = $parentId
    }
    # HashSet はそのまま return すると展開されて要素になる。カンマで止める。
    return ,$set
}

function Get-YakuRegisteredServer {
    # 実行中として登録されているサーバー。応答まで確かめたときだけ返す。
    $dataHome = [string]$env:YAKULINGO_DATA_DIR
    if ([string]::IsNullOrWhiteSpace($dataHome)) {
        $profileRoot = [string]$env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { return $null }
        $dataHome = Join-Path $profileRoot '.yakulingo-ps'
    }
    $path = Join-Path $dataHome 'runtime\server.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $url = [string]$state.url
        if ([string]::IsNullOrWhiteSpace($url)) { return $null }
        $probe = Invoke-RestMethod -UseBasicParsing -Uri ($url.TrimEnd('/') + '/api/instance') -TimeoutSec 2
        if ([string]$probe.instance_id -ne [string]$state.instance_id) { return $null }
        return [pscustomobject]@{ ProcessId = [int]$state.pid; Url = $url }
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# 計画
# ---------------------------------------------------------------------------

function New-YakuReaperItem {
    param(
        [string]$Category, [int]$ProcessId, [string]$Name, [string]$Action,
        [string]$Reason, [string]$Detail
    )
    return [pscustomobject]@{
        Category  = $Category
        ProcessId = $ProcessId
        Name      = $Name
        Action    = $Action
        Reason    = $Reason
        Detail    = $Detail
    }
}

function Get-YakuOrphanServerPlan {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Table,
        [int[]]$OnlyProcessId = @(),
        [int]$AppPortMin = 8765,
        [int]$AppPortMax = 9999,
        [switch]$IncludeAppServer
    )

    $items = New-Object System.Collections.Generic.List[psobject]
    $selfChain = Get-YakuAncestorProcessIds -ProcessId $PID -Table $Table
    $registered = $null

    foreach ($key in @($Table.Keys)) {
        $proc = $Table[[int]$key]
        $name = [string]$proc.Name
        if (-not ($name -match '^(?i:powershell|pwsh)\.exe$')) { continue }

        $tokens = Split-YakuCommandLine -CommandLine ([string]$proc.CommandLine)
        $file = Get-YakuFileArgument -Tokens $tokens
        $kind = Get-YakuServerScriptKind -ScriptPath $file
        if ([string]::IsNullOrWhiteSpace($kind)) { continue }

        $processId = [int]$proc.ProcessId
        if ($OnlyProcessId.Count -gt 0 -and ($OnlyProcessId -notcontains $processId)) { continue }

        $detail = '{0} port={1}' -f (Split-Path -Leaf $file), (Get-YakuPortArgument -Tokens $tokens)

        if ($selfChain.Contains($processId)) {
            $items.Add((New-YakuReaperItem -Category 'server' -ProcessId $processId -Name $name -Action 'skip' -Reason 'self-or-ancestor' -Detail $detail)) | Out-Null
            continue
        }
        if (-not (Test-YakuOrphanProcess -Process $proc -Table $Table)) {
            $items.Add((New-YakuReaperItem -Category 'server' -ProcessId $processId -Name $name -Action 'skip' -Reason 'parent-alive' -Detail $detail)) | Out-Null
            continue
        }

        # 「テストが立てたもの」の印。1つでもあれば落とす。
        $marks = New-Object System.Collections.Generic.List[string]
        if ($kind -eq 'server-script') { $marks.Add('server-script-direct') | Out-Null }
        if (Test-YakuSwitchToken -Tokens $tokens -Name '-UseMockTranslator') { $marks.Add('mock-translator') | Out-Null }
        $port = Get-YakuPortArgument -Tokens $tokens
        if ($port -gt 0 -and ($port -lt $AppPortMin -or $port -gt $AppPortMax)) { $marks.Add('test-port') | Out-Null }

        if ($marks.Count -eq 0) {
            if ($null -eq $registered) { $registered = Get-YakuRegisteredServer }
            if ($null -ne $registered -and [int]$registered.ProcessId -eq $processId) {
                $items.Add((New-YakuReaperItem -Category 'server' -ProcessId $processId -Name $name -Action 'skip' -Reason 'live-registered-app' -Detail $detail)) | Out-Null
                continue
            }
            if (-not $IncludeAppServer) {
                $items.Add((New-YakuReaperItem -Category 'server' -ProcessId $processId -Name $name -Action 'skip' -Reason 'no-test-marker' -Detail $detail)) | Out-Null
                continue
            }
            $marks.Add('include-app-server') | Out-Null
        }

        $items.Add((New-YakuReaperItem -Category 'server' -ProcessId $processId -Name $name -Action 'kill' -Reason (($marks.ToArray()) -join '+') -Detail $detail)) | Out-Null
    }
    return $items.ToArray()
}

function Get-YakuDisposableEdgePlan {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Table,
        [int[]]$OnlyProcessId = @(),
        [string[]]$Pattern = @('yakulingo-ui-audit-*')
    )

    $items = New-Object System.Collections.Generic.List[psobject]
    foreach ($key in @($Table.Keys)) {
        $proc = $Table[[int]$key]
        if (-not ([string]$proc.Name).Equals('msedge.exe', [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $tokens = Split-YakuCommandLine -CommandLine ([string]$proc.CommandLine)
        $userData = Get-YakuUserDataDirArgument -Tokens $tokens
        $processId = [int]$proc.ProcessId

        if ([string]::IsNullOrWhiteSpace($userData)) {
            $items.Add((New-YakuReaperItem -Category 'edge' -ProcessId $processId -Name 'msedge.exe' -Action 'skip' -Reason 'no-user-data-dir' -Detail '')) | Out-Null
            continue
        }
        if (Test-YakuProtectedEdgeProfile -UserDataDir $userData) {
            $items.Add((New-YakuReaperItem -Category 'edge' -ProcessId $processId -Name 'msedge.exe' -Action 'skip' -Reason 'protected-profile' -Detail $userData)) | Out-Null
            continue
        }
        if (-not (Test-YakuDisposableEdgeProfile -UserDataDir $userData -Pattern $Pattern)) {
            $items.Add((New-YakuReaperItem -Category 'edge' -ProcessId $processId -Name 'msedge.exe' -Action 'skip' -Reason 'not-disposable' -Detail $userData)) | Out-Null
            continue
        }
        if ($OnlyProcessId.Count -gt 0 -and ($OnlyProcessId -notcontains $processId)) {
            $items.Add((New-YakuReaperItem -Category 'edge' -ProcessId $processId -Name 'msedge.exe' -Action 'skip' -Reason 'out-of-scope' -Detail $userData)) | Out-Null
            continue
        }
        $items.Add((New-YakuReaperItem -Category 'edge' -ProcessId $processId -Name 'msedge.exe' -Action 'kill' -Reason 'disposable-profile' -Detail $userData)) | Out-Null
    }
    return $items.ToArray()
}

function Get-YakuStaleProfileDirPlan {
    <#
      残骸ディレクトリ。消す条件（すべて満たすときだけ）。
        1. Temp 直下で、名前が $Pattern に一致
        2. edge-profile を含む（＝ブラウザのプロファイルである証拠）
        3. $IdleMinutes より古い
        4. そのパスを使っている msedge が1つも生きていない
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Table,
        [string[]]$Pattern = @('yakulingo-ui-audit-*'),
        [int]$IdleMinutes = 5
    )

    $inUse = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Table.Keys)) {
        $proc = $Table[[int]$key]
        if (-not ([string]$proc.Name).Equals('msedge.exe', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $userData = Get-YakuUserDataDirArgument -Tokens (Split-YakuCommandLine -CommandLine ([string]$proc.CommandLine))
        if (-not [string]::IsNullOrWhiteSpace($userData)) { $inUse.Add($userData) | Out-Null }
    }

    $items = New-Object System.Collections.Generic.List[psobject]
    $cutoff = (Get-Date).AddMinutes(-[Math]::Abs($IdleMinutes))
    foreach ($root in @(Get-YakuTempRoots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($glob in $Pattern) {
            if ([string]::IsNullOrWhiteSpace($glob)) { continue }
            foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter $glob -ErrorAction SilentlyContinue)) {
                $full = [string]$dir.FullName
                # 4重の封じ込め。Temp 配下でないものは何があっても消さない。
                if (-not (Test-YakuPathUnder -Child $full -Parent $root)) { continue }
                if (Test-YakuPathUnder -Child $root -Parent $full) { continue }
                if (Test-YakuProtectedEdgeProfile -UserDataDir $full) { continue }
                $hasProfile = (Test-Path -LiteralPath (Join-Path $full 'edge-profile') -PathType Container)
                if (-not $hasProfile) {
                    $items.Add((New-YakuReaperItem -Category 'dir' -ProcessId 0 -Name $dir.Name -Action 'skip' -Reason 'no-edge-profile' -Detail $full)) | Out-Null
                    continue
                }
                $busy = $false
                foreach ($used in $inUse.ToArray()) {
                    if (Test-YakuPathUnder -Child $used -Parent $full) { $busy = $true; break }
                }
                if ($busy) {
                    $items.Add((New-YakuReaperItem -Category 'dir' -ProcessId 0 -Name $dir.Name -Action 'skip' -Reason 'in-use' -Detail $full)) | Out-Null
                    continue
                }
                if ($dir.LastWriteTime -gt $cutoff) {
                    $items.Add((New-YakuReaperItem -Category 'dir' -ProcessId 0 -Name $dir.Name -Action 'skip' -Reason 'too-fresh' -Detail $full)) | Out-Null
                    continue
                }
                $items.Add((New-YakuReaperItem -Category 'dir' -ProcessId 0 -Name $dir.Name -Action 'remove' -Reason 'disposable-profile' -Detail $full)) | Out-Null
            }
        }
    }
    return $items.ToArray()
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

function Invoke-YakuReaperAction {
    # 1件を実行する。戻り値は 'done'（実行した） / 'listed'（列挙だけ） / 'failed'。
    param(
        [Parameter(Mandatory = $true)]$Item,
        [switch]$ListOnly,
        [AllowNull()]$Cmdlet,
        [Parameter(Mandatory = $true)]$Failures
    )

    $label = if ($Item.Category -eq 'dir') { [string]$Item.Detail } else { ('PID={0} {1} [{2}]' -f $Item.ProcessId, $Item.Name, $Item.Detail) }
    Write-Host ('  {0} {1} <- {2}' -f ([string]$Item.Action).PadRight(6), $label, $Item.Reason)

    if ($ListOnly) { return 'listed' }
    if (($null -ne $Cmdlet) -and (-not ($Cmdlet.ShouldProcess($label, [string]$Item.Action)))) { return 'listed' }

    try {
        if ($Item.Category -eq 'dir') {
            Remove-Item -LiteralPath $Item.Detail -Recurse -Force -ErrorAction Stop
        } else {
            Stop-Process -Id ([int]$Item.ProcessId) -Force -ErrorAction Stop
        }
        return 'done'
    } catch {
        # 既に消えている（子プロセスが親と一緒に落ちた等）のは失敗ではない。
        $gone = $false
        if ($Item.Category -eq 'dir') { $gone = -not (Test-Path -LiteralPath $Item.Detail) }
        else { $gone = -not (Get-Process -Id ([int]$Item.ProcessId) -ErrorAction SilentlyContinue) }
        if ($gone) { return 'listed' }
        $Failures.Add(('{0} {1}: {2}' -f $Item.Category, $label, $_.Exception.Message)) | Out-Null
        return 'failed'
    }
}

function Invoke-YakuOrphanCleanup {
    param(
        [switch]$ListOnly,
        [int[]]$OnlyProcessId = @(),
        [string[]]$DisposableProfilePattern = @('yakulingo-ui-audit-*'),
        [int]$AppPortMin = 8765,
        [int]$AppPortMax = 9999,
        [switch]$IncludeAppServer,
        [int]$ProfileIdleMinutes = 5,
        [string[]]$Scope = @('all'),
        [AllowNull()]$Cmdlet
    )

    $doServers = ($Scope -contains 'all') -or ($Scope -contains 'servers')
    $doEdge = ($Scope -contains 'all') -or ($Scope -contains 'edge')
    $doDirs = ($Scope -contains 'all') -or ($Scope -contains 'dirs')

    $table = Get-YakuProcessTable
    $plan = New-Object System.Collections.Generic.List[psobject]
    if ($doServers) {
        foreach ($item in @(Get-YakuOrphanServerPlan -Table $table -OnlyProcessId $OnlyProcessId -AppPortMin $AppPortMin -AppPortMax $AppPortMax -IncludeAppServer:$IncludeAppServer)) { $plan.Add($item) | Out-Null }
    }
    if ($doEdge) {
        foreach ($item in @(Get-YakuDisposableEdgePlan -Table $table -OnlyProcessId $OnlyProcessId -Pattern $DisposableProfilePattern)) { $plan.Add($item) | Out-Null }
    }
    $edgeRounds = 1

    $killedServers = 0
    $killedEdge = 0
    $removedDirs = 0
    $failures = New-Object System.Collections.Generic.List[string]
    $planned = New-Object System.Collections.Generic.List[psobject]

    foreach ($item in $plan.ToArray()) {
        if ($item.Action -eq 'skip') { continue }
        $planned.Add($item) | Out-Null
        $outcome = Invoke-YakuReaperAction -Item $item -ListOnly:$ListOnly -Cmdlet $Cmdlet -Failures $failures
        if ($outcome -eq 'done') {
            if ($item.Category -eq 'server') { $killedServers++ } else { $killedEdge++ }
        }
    }

    # ブラウザは起動中も子プロセスを増やし続ける。1回の一覧で決め打ちすると、
    # 一覧を取ったあとに生まれた子が残る（実測: 落としたつもりで4つ残っていた）。
    # 残りが無くなるまで数えて繰り返す。上限を置いて、無限には回さない。
    if ((-not $ListOnly) -and $doEdge -and $killedEdge -gt 0) {
        for ($round = 2; $round -le 4; $round++) {
            Start-Sleep -Milliseconds 500
            $again = @(Get-YakuDisposableEdgePlan -Table (Get-YakuProcessTable) -OnlyProcessId $OnlyProcessId -Pattern $DisposableProfilePattern | Where-Object { $_.Action -eq 'kill' })
            if ($again.Count -eq 0) { break }
            $edgeRounds = $round
            foreach ($item in $again) {
                $plan.Add($item) | Out-Null
                $planned.Add($item) | Out-Null
                $outcome = Invoke-YakuReaperAction -Item $item -ListOnly:$ListOnly -Cmdlet $Cmdlet -Failures $failures
                if ($outcome -eq 'done') { $killedEdge++ }
            }
        }
    }

    # ディレクトリの計画は、プロセスを落としたあとに立て直す。
    # 先に立てると、いま殺したばかりの Edge が使っている扱いのままになり、
    # 残骸が1つも消えない（実測: 14プロセスを落としたのに dirs=0 だった）。
    if ((-not $ListOnly) -and $killedEdge -gt 0) { Start-Sleep -Milliseconds 700 }
    $dirTable = if ($ListOnly) { $table } else { Get-YakuProcessTable }
    # -OnlyProcessId は「この PID だけ」という外科的な指定。PID を持たない
    # ディレクトリ掃除まで道連れにしない。
    $dirPlan = if (($OnlyProcessId.Count -gt 0) -or (-not $doDirs)) { @() } else { @(Get-YakuStaleProfileDirPlan -Table $dirTable -Pattern $DisposableProfilePattern -IdleMinutes $ProfileIdleMinutes) }
    foreach ($item in $dirPlan) {
        $plan.Add($item) | Out-Null
        if ($item.Action -eq 'skip') { continue }
        $planned.Add($item) | Out-Null
        $outcome = Invoke-YakuReaperAction -Item $item -ListOnly:$ListOnly -Cmdlet $Cmdlet -Failures $failures
        if ($outcome -eq 'done') { $removedDirs++ }
    }

    return [pscustomobject]@{
        Plan          = $plan.ToArray()
        Planned       = $planned.ToArray()
        KilledServers = $killedServers
        KilledEdge    = $killedEdge
        EdgeRounds    = $edgeRounds
        RemovedDirs   = $removedDirs
        Failures      = $failures.ToArray()
    }
}

if ($script:YakuReaperDotSourced) { return }

$listOnly = $ListOnly.IsPresent -or ($WhatIfPreference -eq $true)
Write-Host ('YakuLingo orphan cleanup ({0})' -f $(if ($listOnly) { 'list only' } else { 'apply' })) -ForegroundColor Cyan

$result = Invoke-YakuOrphanCleanup `
    -ListOnly:$listOnly `
    -OnlyProcessId $OnlyProcessId `
    -DisposableProfilePattern $DisposableProfilePattern `
    -AppPortMin $AppPortMin `
    -AppPortMax $AppPortMax `
    -IncludeAppServer:$IncludeAppServer `
    -ProfileIdleMinutes $ProfileIdleMinutes `
    -Scope $Scope `
    -Cmdlet $(if ($listOnly) { $null } else { $PSCmdlet })

$skipped = @($result.Plan | Where-Object { $_.Action -eq 'skip' })
foreach ($item in $skipped) {
    # 守ったものは黙って通さない。誤爆を疑うときに読む行はここ。
    Write-Verbose ('  keep   {0} PID={1} {2} <- {3}' -f $item.Category, $item.ProcessId, $item.Detail, $item.Reason)
}
$protectedEdge = @($skipped | Where-Object { $_.Category -eq 'edge' -and ($_.Reason -eq 'protected-profile' -or $_.Reason -eq 'not-disposable' -or $_.Reason -eq 'no-user-data-dir') })
$keptServers = @($skipped | Where-Object { $_.Category -eq 'server' })
foreach ($item in $keptServers) {
    Write-Host ('  keep   PID={0} {1} <- {2}' -f $item.ProcessId, $item.Detail, $item.Reason) -ForegroundColor DarkGray
    if ($item.Reason -eq 'no-test-marker' -or $item.Reason -eq 'live-registered-app') {
        Write-Host '         （利用者の実アプリの可能性。止めるなら app\tools\Stop-YakuLingo.ps1）' -ForegroundColor DarkGray
    }
}

foreach ($failure in $result.Failures) { Write-Warning $failure }

# 監視用の目印は ASCII で出す。CP932 のログを UTF-8 で探して待ち続けた失敗があるため。
$verb = if ($listOnly) { 'PLAN' } else { 'DONE' }
Write-Host ('ORPHAN-CLEANUP-{0} servers={1} edge={2} dirs={3} planned={4} kept-servers={5} kept-edge={6} failures={7}' -f `
    $verb, $result.KilledServers, $result.KilledEdge, $result.RemovedDirs, @($result.Planned).Count, `
    $keptServers.Count, $protectedEdge.Count, @($result.Failures).Count) -ForegroundColor Green

if (@($result.Failures).Count -gt 0) { exit 1 }
exit 0
