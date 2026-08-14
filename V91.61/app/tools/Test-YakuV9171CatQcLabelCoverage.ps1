<#
.SYNOPSIS
  V91.61: CAT点検の finding コードと、cat.js の説明文の対応表がずれていないことを検証する。

.DESCRIPTION
  2026-08-14 の利用者判断（_docs/決定_実装優先と固有名詞マスク_2026-08-14.md §2）で、
  cat.js に残っていた死語ラベル proper-noun-missing を削除した。src/ に生成箇所が
  1件も無いラベルが残っていると、画面を読んだ人には「固有名詞の点検がある」と読める。

  逆向きの穴も同じ重さである。サーバが出すのに画面が名前で呼べないコードは、
  利用者には汎用文（自動点検で気になる点が見つかりました）としてしか見えない。
  何が起きたのか分からないまま、出力が止まる。

  そこで両向きを機械で固定する。判定は2つ。
    (a) src/ が生成しうる finding コードは、すべて cat.js のラベルにある
    (b) cat.js のラベルにあって src/ が一度も生成しないコードは 0 件

  走査は素の grep ではなく AST で行う。'Code=' を行から探すと ErrorCode /
  ReasonCode / WarningCode を巻き込み、対応表に無い偽のコードを数える。
  ハッシュテーブルのキー名を AST で見れば Code と ErrorCode は別物として分かれる。

.PARAMETER Root
  検査対象の app フォルダ。既定はこのスクリプトの親（配布物の app）。
  門そのものが発火するかを確かめるとき、複製へ向けて使う。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9171CatQcLabelCoverage.ps1
#>
[CmdletBinding()]
param(
    # 既定値の式では解決しない。[CmdletBinding()] 付き .ps1 の param() 内では
    # $MyInvocation.MyCommand.Path が $null になる（Check-Encoding.ps1 と同じ罠）。
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$rootPath = (Resolve-Path -LiteralPath $Root).Path

$script:Failures = 0
function Assert-YakuQcLabel {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

# --- AST 補助 --------------------------------------------------------------

function Get-YakuQcAstKeyName {
    # ハッシュテーブルのキー名。定数キー以外（式キー）は名前が取れないので空で返す。
    param($KeyAst)
    if ($KeyAst -is [System.Management.Automation.Language.ConstantExpressionAst]) { return [string]$KeyAst.Value }
    return ''
}

function Get-YakuQcAstConstantString {
    # ハッシュテーブルの値が文字列定数なら中身を返す。式なら IsConstant=$false。
    param($ValueAst)
    $expr = $null
    if ($ValueAst -is [System.Management.Automation.Language.PipelineAst] -and $ValueAst.PipelineElements.Count -eq 1) {
        $element = $ValueAst.PipelineElements[0]
        if ($element -is [System.Management.Automation.Language.CommandExpressionAst]) { $expr = $element.Expression }
    } elseif ($ValueAst -is [System.Management.Automation.Language.ExpressionAst]) {
        $expr = $ValueAst
    }
    if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{ IsConstant = $true; Value = [string]$expr.Value }
    }
    return [pscustomobject]@{ IsConstant = $false; Value = '' }
}

function Get-YakuQcEnclosingFunctionName {
    param($Ast)
    $node = $Ast
    while ($null -ne $node) {
        if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return [string]$node.Name }
        $node = $node.Parent
    }
    return ''
}

function Get-YakuQcFindingCodesFromSrc {
    <# finding は { Code=...; Severity=... } という形をした唯一の記録である。
       Invoke-YakuCatSegmentValidation が blocker を選ぶとき見ているのも Severity。
       この2つのキーを持つハッシュテーブルだけを finding と見なし、
       それを含む関数を「生成元」として自分で見つける。関数名を手で並べると、
       新しい生成元が増えたとき無音で漏れる。 #>
    param(
        [Parameter(Mandatory=$true)][string]$SrcDir,
        # Mandatory だけだと空のリストを渡せない（PS 5.1 は空コレクションを未指定と見なす）。
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
    )
    $codes = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $producers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $records = New-Object 'System.Collections.Generic.List[psobject]'

    foreach ($file in @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1' -File | Sort-Object Name)) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $Problems.Add(('AST parse error: {0}: {1}' -f $file.Name, [string]$errors[0].Message)) | Out-Null
            continue
        }
        if ($null -eq $ast) { $Problems.Add(('AST unavailable: ' + $file.Name)) | Out-Null; continue }
        foreach ($hashtable in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
            $codePair = $null
            $hasSeverity = $false
            foreach ($pair in $hashtable.KeyValuePairs) {
                $name = Get-YakuQcAstKeyName -KeyAst $pair.Item1
                if ($name -ceq 'Code') { $codePair = $pair }
                elseif ($name -ceq 'Severity') { $hasSeverity = $true }
            }
            if ($null -eq $codePair) { continue }
            $constant = Get-YakuQcAstConstantString -ValueAst $codePair.Item2
            $records.Add([pscustomobject]@{
                File        = [string]$file.Name
                Line        = [int]$hashtable.Extent.StartLineNumber
                Function    = (Get-YakuQcEnclosingFunctionName -Ast $hashtable)
                HasSeverity = [bool]$hasSeverity
                IsConstant  = [bool]$constant.IsConstant
                Code        = [string]$constant.Value
            }) | Out-Null
            if ($hasSeverity) { $null = $producers.Add((Get-YakuQcEnclosingFunctionName -Ast $hashtable)) }
        }
    }

    foreach ($record in $records.ToArray()) {
        if (-not $producers.Contains([string]$record.Function)) { continue }
        # 生成元の中では finding の形（Code と Severity の対）が崩れていないことまで見る。
        # Severity の無い finding が現れたら、この門の見分け方そのものが効かなくなる。
        # 静かに数え落とすより、ここで止めて作り直させる。
        if (-not $record.HasSeverity) {
            $Problems.Add(('Severity の無い Code が生成元にある: {0}:{1} ({2})' -f $record.File, $record.Line, $record.Function)) | Out-Null
            continue
        }
        if (-not $record.IsConstant) {
            $Problems.Add(('Code が文字列定数ではないため照合できない: {0}:{1} ({2})' -f $record.File, $record.Line, $record.Function)) | Out-Null
            continue
        }
        $null = $codes.Add(([string]$record.Code).ToLowerInvariant().Replace('_', '-'))
    }

    return [pscustomobject]@{ Codes = $codes; Producers = $producers; Records = $records }
}

# --- cat.js のラベル -------------------------------------------------------

function Get-YakuQcCatJsLabelKeys {
    <# qcMessages の labels オブジェクトからキーだけを取り出す。
       値には「[[N1]]」のような括弧や句読点が入るので、文字列の中と外を
       数えながら深さ0のカンマで区切る。正規表現1本では中と外を区別できない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
    )
    $keys = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Problems.Add(('cat.js が見つからない: ' + $Path)) | Out-Null
        return [pscustomobject]@{ Keys = $keys }
    }
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    $fnIndex = $text.IndexOf('function qcMessages(')
    if ($fnIndex -lt 0) {
        $Problems.Add('cat.js に qcMessages 関数が無い（画面側の点検文の出所が消えている）') | Out-Null
        return [pscustomobject]@{ Keys = $keys }
    }
    $varIndex = $text.IndexOf('var labels', $fnIndex)
    if ($varIndex -lt 0) {
        $Problems.Add('cat.js の qcMessages に labels 対応表が無い') | Out-Null
        return [pscustomobject]@{ Keys = $keys }
    }
    $open = $text.IndexOf('{', $varIndex)
    if ($open -lt 0) {
        $Problems.Add('cat.js の labels に開き括弧が無い') | Out-Null
        return [pscustomobject]@{ Keys = $keys }
    }

    $singleQuote = [char]39
    $doubleQuote = [char]34
    $backslash   = [char]92
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $buffer = New-Object System.Text.StringBuilder
    $depth = 0
    $inString = $false
    $quote = [char]0
    $escaped = $false
    $closed = $false
    for ($i = $open + 1; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($escaped) { [void]$buffer.Append($c); $escaped = $false; continue }
        if ($inString) {
            if ($c -eq $backslash) { $escaped = $true; [void]$buffer.Append($c); continue }
            if ($c -eq $quote) { $inString = $false }
            [void]$buffer.Append($c); continue
        }
        if ($c -eq $singleQuote -or $c -eq $doubleQuote) { $inString = $true; $quote = $c; [void]$buffer.Append($c); continue }
        if ($c -eq '{' -or $c -eq '[' -or $c -eq '(') { $depth++; [void]$buffer.Append($c); continue }
        if ($c -eq '}' -and $depth -eq 0) { $entries.Add($buffer.ToString()) | Out-Null; $closed = $true; break }
        if ($c -eq '}' -or $c -eq ']' -or $c -eq ')') { $depth--; [void]$buffer.Append($c); continue }
        if ($c -eq ',' -and $depth -eq 0) { $entries.Add($buffer.ToString()) | Out-Null; [void]$buffer.Clear(); continue }
        [void]$buffer.Append($c)
    }
    if (-not $closed) {
        $Problems.Add('cat.js の labels が閉じていない（走査が最後まで届かなかった）') | Out-Null
        return [pscustomobject]@{ Keys = $keys }
    }

    $keyPattern = '^\s*(?:''([^'']*)''|"([^"]*)"|([A-Za-z_$][A-Za-z0-9_$]*))\s*:'
    foreach ($entry in $entries.ToArray()) {
        $clean = [string]$entry
        for ($pass = 0; $pass -lt 4; $pass++) {
            $before = $clean
            $clean = [regex]::Replace($clean, '^\s*/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $clean = [regex]::Replace($clean, '^[ \t]*//[^\r\n]*', '')
            if ($clean -eq $before) { break }
        }
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $match = [regex]::Match($clean, $keyPattern)
        if (-not $match.Success) {
            $snippet = $clean.Trim()
            if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 60) + '...' }
            $Problems.Add(('cat.js の labels に読み取れない項目がある: ' + $snippet)) | Out-Null
            continue
        }
        $key = if ($match.Groups[1].Success) { $match.Groups[1].Value }
               elseif ($match.Groups[2].Success) { $match.Groups[2].Value }
               else { $match.Groups[3].Value }
        # cat.js 側は code.toLowerCase().replace(/_/g,'-') で引く。同じ形に揃えて比べる。
        $keys.Add(([string]$key).ToLowerInvariant().Replace('_', '-')) | Out-Null
    }
    return [pscustomobject]@{ Keys = $keys }
}

# --- 実行 ------------------------------------------------------------------

$problems = New-Object 'System.Collections.Generic.List[string]'
$srcDir = Join-Path $rootPath 'src'
$catJsPath = Join-Path (Join-Path (Join-Path $rootPath 'www') 'assets') 'cat.js'

Write-Host 'CASE 1: 走査そのものが成立しているか'
Assert-YakuQcLabel (Test-Path -LiteralPath $srcDir -PathType Container) ('src フォルダがある: ' + $srcDir)
Assert-YakuQcLabel (Test-Path -LiteralPath $catJsPath -PathType Leaf) ('cat.js がある: ' + $catJsPath)

$srcScan = Get-YakuQcFindingCodesFromSrc -SrcDir $srcDir -Problems $problems
$catScan = Get-YakuQcCatJsLabelKeys -Path $catJsPath -Problems $problems

$srcCodes = $srcScan.Codes
$producers = $srcScan.Producers
$labelKeys = $catScan.Keys

foreach ($problem in $problems.ToArray()) { Write-Host ('  FAIL ' + $problem) -ForegroundColor Red; $script:Failures++ }

# 生成元が消えると、コード集合は空になり (a) は自動的に通ってしまう。
# 空で通る門は門ではないので、既知の生成元が居ることを先に確かめる。
foreach ($expected in @('Invoke-YakuCatSegmentValidation', 'Test-YakuTerminologyCompliance')) {
    Assert-YakuQcLabel ($producers.Contains($expected)) ('finding の生成元を見つけた: ' + $expected)
}
Assert-YakuQcLabel ($srcCodes.Count -gt 0) ('src が生成する finding コードを数えた: ' + $srcCodes.Count + ' 件')
Assert-YakuQcLabel ($labelKeys.Count -gt 0) ('cat.js のラベルを数えた: ' + $labelKeys.Count + ' 件')

Write-Host 'CASE 2: src が出すコードは、すべて cat.js が名前で説明できる'
$uncovered = New-Object 'System.Collections.Generic.List[string]'
foreach ($code in @($srcCodes | Sort-Object)) {
    if (-not $labelKeys.Contains($code)) { $uncovered.Add([string]$code) | Out-Null }
}
Assert-YakuQcLabel ($uncovered.Count -eq 0) ('cat.js に説明文の無いコードは無い' + $(if ($uncovered.Count -gt 0) { '（不足: ' + (($uncovered.ToArray()) -join ', ') + '）' } else { '' }))

Write-Host 'CASE 3: cat.js のラベルに、src が一度も出さない死語が無い'
$dead = New-Object 'System.Collections.Generic.List[string]'
foreach ($key in $labelKeys.ToArray()) {
    if (-not $srcCodes.Contains([string]$key)) { $dead.Add([string]$key) | Out-Null }
}
Assert-YakuQcLabel ($dead.Count -eq 0) ('src が生成しないラベルは無い' + $(if ($dead.Count -gt 0) { '（死語: ' + (($dead.ToArray() | Sort-Object -Unique) -join ', ') + '）' } else { '' }))

if ($script:Failures -gt 0) {
    Write-Host ''
    Write-Host ('src codes   : ' + ((@($srcCodes | Sort-Object)) -join ', ')) -ForegroundColor Yellow
    Write-Host ('cat.js keys : ' + ((@($labelKeys.ToArray() | Sort-Object)) -join ', ')) -ForegroundColor Yellow
    Write-Host "V91.61 CAT QC label coverage test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host ('V91.61 CAT QC label coverage regression passed. codes=' + $srcCodes.Count + ' labels=' + $labelKeys.Count) -ForegroundColor Green
