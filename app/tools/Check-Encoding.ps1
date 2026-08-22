<#
.SYNOPSIS
  Verifies YakuLingo PowerShell, prompt, web UI, and selected edited config/docs files are UTF-8 BOM and parse cleanly.

.DESCRIPTION
  Windows PowerShell 5.1 reads BOM-less .ps1 files as the system ANSI code page.
  This gate checks BOM bytes directly before AST parsing so UTF-8 Japanese literals
  cannot be silently misread on Japanese Windows environments.
#>
[CmdletBinding()]
param(
    # 既定値の式では解決しない。[CmdletBinding()] を付けた .ps1 の param() 既定値の中では、
    # Windows PowerShell 5.1 は $MyInvocation.MyCommand.Path を $null にする（本体では入る）。
    # 既定値で解決すると -File 起動が Split-Path で落ち、この門自体が実機で動かなくなる。
    [string]$Root = '',
    # 改行コードを意図して変えたときだけ渡す。基準値を書き直して終了する。
    [switch]$UpdateEolBaseline
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Get-YakuCheckRelativePath {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path
    )
    try {
        $base = (Resolve-Path -LiteralPath $Root).Path
        $full = (Resolve-Path -LiteralPath $Path).Path
        if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($base.Length).TrimStart([char[]]@('\','/'))
        }
    } catch {}
    return $Path
}

function Get-YakuFileEolStyle {
    # 配布物はファイルごとに CRLF と LF が混在しており、その並びを保つ必要がある。
    # 一括変換は差分を全行に広げ、レビューを不能にする。
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ne 0x0A) { continue }
        if ($i -gt 0 -and $bytes[$i - 1] -eq 0x0D) { $crlf++ } else { $lf++ }
    }
    if ($crlf -gt 0 -and $lf -gt 0) { return 'mixed' }
    if ($crlf -gt 0) { return 'crlf' }
    if ($lf -gt 0) { return 'lf' }
    return 'none'
}

function Test-YakuUtf8BomBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$targets = New-Object System.Collections.Generic.List[object]
$seen = @{}

function Test-YakuVendorPath {
    # V91.61: www/vendor/ は第三者の配布物（LiteParse WASM 等）。
    # BOM も改行も上流のバイト列のまま保つ必要があるため、検査の対象外にする。
    # 書き換えないことが正しさなので、ここで守るべき不変条件が逆になる。
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$Path)
    $vendor = [System.IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Root 'www') 'assets') 'vendor'))
    $vendor = $vendor.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.StartsWith($vendor, [System.StringComparison]::OrdinalIgnoreCase)
}

foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Filter '*.ps1' -ErrorAction Stop | Sort-Object FullName)) {
    if (Test-YakuVendorPath -Root $rootPath -Path $file.FullName) { continue }
    if (-not $seen.ContainsKey($file.FullName)) {
        $seen[$file.FullName] = $true
        $targets.Add($file) | Out-Null
    }
}

$promptDir = Join-Path $rootPath 'prompts'
if (Test-Path -LiteralPath $promptDir -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $promptDir -Filter '*.txt' -ErrorAction Stop | Sort-Object FullName)) {
        if (-not $seen.ContainsKey($file.FullName)) {
            $seen[$file.FullName] = $true
            $targets.Add($file) | Out-Null
        }
    }
}

$wwwDir = Join-Path $rootPath 'www'
if (Test-Path -LiteralPath $wwwDir -PathType Container) {
    foreach ($pattern in @('*.html','*.css','*.js')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $wwwDir -Recurse -Filter $pattern -ErrorAction Stop | Sort-Object FullName)) {
            if (Test-YakuVendorPath -Root $rootPath -Path $file.FullName) { continue }
            if (-not $seen.ContainsKey($file.FullName)) {
                $seen[$file.FullName] = $true
                $targets.Add($file) | Out-Null
            }
        }
    }
}
$extraBomTargets = @(
    'glossary.csv',
    'config\settings.template.json',
    'docs\UI_REDESIGN_V33.md',
    'docs\WRITEBACK_FIX_V34.md',
    'docs\MD_ESCAPE_FIX_V35.md'
)
foreach ($rel in $extraBomTargets) {
    $path = Join-Path $rootPath $rel
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $file = Get-Item -LiteralPath $path
        if (-not $seen.ContainsKey($file.FullName)) {
            $seen[$file.FullName] = $true
            $targets.Add($file) | Out-Null
        }
    }
}


# --- 改行コードの基準値 ---------------------------------------------------
# BOM と構文だけを見ていた時期に、パッチ処理が LF のファイルを丸ごと CRLF へ
# 変換して通過したことがある。基準値と突き合わせて機械的に止める。
$eolBaselinePath = Join-Path (Join-Path $rootPath 'tools') 'eol-baseline.txt'
$eolActual = [ordered]@{}
foreach ($file in @($targets.ToArray())) {
    $rel = (Get-YakuCheckRelativePath -Root $rootPath -Path ([string]$file.FullName)).Replace('\', '/')
    $eolActual[$rel] = Get-YakuFileEolStyle -Path ([string]$file.FullName)
}
if ($UpdateEolBaseline) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($rel in @($eolActual.Keys | Sort-Object)) { $lines.Add($rel + "`t" + [string]$eolActual[$rel]) | Out-Null }
    # **基準値そのものの改行を、書き直すたびに変えない（2026-08-16）。**
    # ここは長らく LF 決め打ちで書いていた。基準値は CRLF なので、1行足すだけの
    # つもりで実行すると**全行が差分になり**、中身の変化が読めなくなる。
    # 「改行の一括変換をレビュー不能な差分で通す」ことこそ、この基準値が
    # 止めるためにある事故である。基準値ファイル自身は検査の対象に入っていない
    # （`tools/*.txt` は対象外）ので、反転しても誰も気づかなかった。
    $newline = "`r`n"
    if (Test-Path -LiteralPath $eolBaselinePath -PathType Leaf) {
        $existingStyle = Get-YakuFileEolStyle -Path $eolBaselinePath
        if ($existingStyle -eq 'lf') { $newline = "`n" }
    }
    $text = (($lines.ToArray()) -join $newline) + $newline
    [System.IO.File]::WriteAllText($eolBaselinePath, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("EOL baseline updated: {0} entry(ies). newline={1}" -f $lines.Count, $(if ($newline -eq "`r`n") { 'crlf' } else { 'lf' })) -ForegroundColor Yellow
    return
}

$violations = New-Object System.Collections.Generic.List[string]

$eolBaseline = @{}
if (Test-Path -LiteralPath $eolBaselinePath -PathType Leaf) {
    foreach ($line in @([System.IO.File]::ReadAllLines($eolBaselinePath))) {
        $clean = ([string]$line).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $parts = $clean -split "`t", 2
        if ($parts.Count -ne 2) { continue }
        $eolBaseline[[string]$parts[0]] = [string]$parts[1]
    }
} else {
    $violations.Add('EOL baseline missing: tools/eol-baseline.txt (regenerate with -UpdateEolBaseline)') | Out-Null
}
if ($eolBaseline.Count -gt 0) {
    foreach ($rel in @($eolActual.Keys)) {
        $actual = [string]$eolActual[$rel]
        if ($actual -eq 'mixed') { $violations.Add("Mixed line endings: $rel") | Out-Null; continue }
        if (-not $eolBaseline.ContainsKey($rel)) {
            $violations.Add("EOL baseline entry missing: $rel (actual=$actual; regenerate with -UpdateEolBaseline)") | Out-Null
            continue
        }
        $expected = [string]$eolBaseline[$rel]
        if ($actual -ne $expected) {
            $violations.Add("EOL changed: $rel expected=$expected actual=$actual (regenerate with -UpdateEolBaseline only if intended)") | Out-Null
        }
    }
    foreach ($rel in @($eolBaseline.Keys)) {
        if (-not $eolActual.Contains($rel)) { $violations.Add("EOL baseline entry stale: $rel (regenerate with -UpdateEolBaseline)") | Out-Null }
    }
}

foreach ($file in @($targets.ToArray())) {
    $full = [string]$file.FullName
    if (-not (Test-YakuUtf8BomBytes -Path $full)) {
        $rel = Get-YakuCheckRelativePath -Root $rootPath -Path $full
        $violations.Add("BOM missing: $rel") | Out-Null
    }
}

$parserType = [type]'System.Management.Automation.Language.Parser'
if ($null -eq $parserType) {
    $violations.Add('AST parser not available: System.Management.Automation.Language.Parser') | Out-Null
} else {
    foreach ($file in @($targets.ToArray() | Where-Object { $_.Name -like '*.ps1' })) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            foreach ($err in @($errors)) {
                $rel = Get-YakuCheckRelativePath -Root $rootPath -Path $file.FullName
                $violations.Add(("Parse error: {0}: Line {1}, Column {2}: {3}" -f $rel, $err.Extent.StartLineNumber, $err.Extent.StartColumnNumber, $err.Message)) | Out-Null
            }
        }
    }
}

# --- 未定義の Yaku コマンド ------------------------------------------------
# 関数をまとめて削除したとき、まだ呼ばれている関数まで巻き込むことがある。
# 構文検査は通ってしまい、実行して初めて分かる。定義と呼び出しを突き合わせる。
if ($null -ne $parserType) {
    $definedCommands = @{}
    $invokedCommands = @{}
    foreach ($file in @($targets.ToArray() | Where-Object { $_.Name -like '*.ps1' })) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { continue }
        foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $definedCommands[([string]$fn.Name).ToLowerInvariant()] = $true
        }
        foreach ($cmd in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $name = ''
            try { $name = [string]$cmd.GetCommandName() } catch { $name = '' }
            # 変数経由の呼び出し(&$fn)は名前が取れない。静的に追えないので対象外。
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch '-Yaku') { continue }
            $key = $name.ToLowerInvariant()
            if (-not $invokedCommands.ContainsKey($key)) { $invokedCommands[$key] = @() }
            $invokedCommands[$key] += (Get-YakuCheckRelativePath -Root $rootPath -Path ([string]$file.FullName))
        }
    }
    # 保護済み送信口はclosureへauthorityを閉じ込め、初期化時にFunction:へ公開する。
    # FunctionDefinitionAstには現れないため、製品が意図的に公開する2コマンドだけを
    # 動的定義として登録する。任意prompt/receiptのfactoryはここへ追加しない。
    foreach ($dynamicCommand in @('New-YakuProtectedPromptPackage','Invoke-YakuProtectedCopilotPrompt')) {
        $definedCommands[$dynamicCommand.ToLowerInvariant()] = $true
    }
    # bootstrap.ps1 は app/ の外にあるが製品の一部である。
    # 回帰テストは共有フォルダ側の作法を検証するため、ここから関数本文を取り出して使う。
    # 定義側を数えないと、実在する関数を「未定義」と誤って咎める。
    # $rootPath は共有ルート直下の app。bootstrap.ps1 はその親にある。
    $bootstrapPath = Join-Path (Split-Path -Parent $rootPath) 'bootstrap.ps1'
    if (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) {
        $tokens = $null; $errors = $null
        $bootAst = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$tokens, [ref]$errors)
        if ($null -ne $bootAst) {
            foreach ($fn in @($bootAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
                $definedCommands[([string]$fn.Name).ToLowerInvariant()] = $true
            }
        }
    }
    foreach ($key in @($invokedCommands.Keys | Sort-Object)) {
        if ($definedCommands.ContainsKey($key)) { continue }
        $where = (@($invokedCommands[$key] | Sort-Object -Unique) -join ', ')
        $violations.Add("Undefined command: $key called from $where") | Out-Null
    }
}

# --- 共有フォルダ側の製品ファイル -----------------------------------------
# $rootPath は共有ルート直下の app。bootstrap.ps1 と起動用 .cmd はその親にある。
# **そこは長らく検査の外だった。**
# 壊れてはいなかったが、壊しても誰も気づかない状態で、守っていたのは
# 仕組みではなく規律だった（2026-08-16 に広げた）。
#
# 在処は bootstrap.ps1 を探して決める。`..\..` の直書きは階層が変われば
# 静かに外れる。**見つからなければ赤にする。** 黙って飛ばすと、検査が
# 通っているのに何も見ていない状態になる。
$shareRoot = ''
$probe = $rootPath
for ($depth = 0; $depth -lt 6; $depth++) {
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
    $probe = $parent
    if (Test-Path -LiteralPath (Join-Path $probe 'bootstrap.ps1') -PathType Leaf) { $shareRoot = $probe; break }
}
if ([string]::IsNullOrWhiteSpace($shareRoot)) {
    $violations.Add('Share-folder root not found: no bootstrap.ps1 above ' + $rootPath) | Out-Null
}
else {
    # 直下の .ps1。BOM 無しだと 5.1 が ANSI として読み、日本語が壊れて構文エラーになる。
    $shareScripts = @(Get-ChildItem -LiteralPath $shareRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($shareScripts.Count -eq 0) {
        $violations.Add('Share-folder root has no .ps1 to check: ' + $shareRoot) | Out-Null
    }
    foreach ($file in $shareScripts) {
        $name = 'share/' + $file.Name
        if (-not (Test-YakuUtf8BomBytes -Path $file.FullName)) { $violations.Add('Missing UTF-8 BOM: ' + $name) | Out-Null }
        $eol = Get-YakuFileEolStyle -Path $file.FullName
        if ($eol -eq 'mixed') { $violations.Add('Mixed line endings: ' + $name) | Out-Null }
        $shareTokens = $null; $shareErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$shareTokens, [ref]$shareErrors)
        if (@($shareErrors).Count -gt 0) { $violations.Add(('Parse error: ' + $name + ' (' + @($shareErrors).Count + ')')) | Out-Null }
    }

    # 起動用の .cmd。**中身は ASCII だけにする。**
    # cmd.exe は OEM コードページで読むので、日本語を入れると環境によって化ける。
    # ファイル名に日本語があるのは構わない（利用者が読むのは名前のほうである）。
    # node_modules は第三者の配布物なので見ない。
    $cmdFiles = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $shareRoot -Recurse -Filter '*.cmd' -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if ($file.FullName -match '(?i)[\\/]node_modules[\\/]') { continue }
        $cmdFiles.Add($file) | Out-Null
    }
    if ($cmdFiles.Count -eq 0) {
        # 1本も見つからないなら、探し方のほうが壊れている。
        $violations.Add('No .cmd found under ' + $shareRoot + ' (the launcher check would be vacuous)') | Out-Null
    }
    foreach ($file in @($cmdFiles.ToArray())) {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $nonAscii = 0
        foreach ($byte in $bytes) { if ($byte -ge 0x80) { $nonAscii++ } }
        if ($nonAscii -gt 0) {
            $rel = $file.FullName.Substring($shareRoot.Length).TrimStart([char[]]@('\','/'))
            $violations.Add(('Non-ASCII bytes in .cmd: ' + $rel.Replace('\', '/') + ' (' + $nonAscii + ' byte(s))')) | Out-Null
        }
    }
    Write-Host ("Share-folder check: {0} script(s), {1} launcher(s) under {2}" -f $shareScripts.Count, $cmdFiles.Count, $shareRoot) -ForegroundColor DarkGray
}

if ($violations.Count -gt 0) {
    Write-Host 'Encoding/syntax check failed:' -ForegroundColor Red
    foreach ($v in @($violations.ToArray())) { Write-Host ('- ' + $v) -ForegroundColor Red }
    throw ("Encoding/syntax check failed: {0} issue(s)." -f $violations.Count)
}

Write-Host ("Encoding/syntax check passed: {0} file(s) verified (BOM, syntax, line endings, command definitions)." -f $targets.Count) -ForegroundColor Green
