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

  そこで両向きを機械で固定する。判定は4つ。
    (a) src/ が生成しうる finding コードは、すべて cat.js のラベルにある
    (b) cat.js のラベルにあって src/ が一度も生成しないコードは 0 件
    (c) src/ が「道具の不調」と分類した種別の集合と、cat.js が赤ではなく
        道具の色で塗る種別の集合が、**一致する**
    (d) src/ が「止めない警告」と分類した種別の集合と、cat.js が警告の色で
        塗る種別の集合が、**一致する**（2026-08-16 に足した。群が2つに
        増えたので、同じ形の穴が2か所に開くようになった）

  (d) を足した理由。用語集に無い短いラベルの警告（label-not-in-glossary）は、
  道具の不調とも訳の欠陥とも違う。直せるが、直さなくても書き出せる。赤で出せば
  押せるはずの書き出しが押せないように見え、道具の不調の色で出せば自分で
  対処できることが伝わらない。正本は src/CatProject.ps1 の
  Get-YakuCatQcWarningCodes、画面側の写しは cat.js の QC_WARNING_CODES である。
  あわせて qcGroup の本体に出てよい文字列を群の名前だけに縛る（種別名を
  直書きした枝は、一覧を通らないので赤になる）。

  (c) を足した理由（2026-08-16）。src/CatProject.ps1 は4種
  （numeric-validation-error / structure-validation-error /
  terminology-check-unavailable / validation-unavailable）を
  「利用者の訳の欠陥ではなく道具の不調。訳を直しても消えない」と分類していたが、
  cat.js の qcGroup は後ろ2種しか道具の色にしておらず、前2種を赤（訳の欠陥）で
  塗っていた。**直しても消えないものを赤で見せると、利用者は際限なく探す。**
  2026-08-15 に validation-unavailable だけを同じ形で直した直後の再発である。

  分類そのものはコメントの中にしか無かったので、機械は一致を見られなかった。
  いまは src 側に正本（Get-YakuCatQcToolTroubleCodes）があり、cat.js 側の写しは
  QC_TOOL_TROUBLE_CODES である。ここでは両方を読んで集合の一致を見る。
  片方へ足してもう片方へ足し忘れたら赤になる。**註のコメント位置は読まない。**
  コメントを1行動かすだけで門が壊れる読み方は、門ではないからである。

  (c) は**表示の分類だけ**を見る。止める条件（Get-YakuCatOutputEligibility）は
  この一覧を読まない。色が変わっても、その行は止まったままである。

  走査は素の grep ではなく AST で行う。'Code=' を行から探すと ErrorCode /
  ReasonCode / WarningCode を巻き込み、対応表に無い偽のコードを数える。
  ハッシュテーブルのキー名を AST で見れば Code と ErrorCode は別物として分かれる。

  ただし 'Code=' の鍵だけでは足りない（2026-08-15 に実測で分かった穴）。
  種別は finding からだけ来るのではなく、**その場で合成される**ものがある。
  src/CatProject.ps1 の Get-YakuCatOutputEligibility は、点検そのものが例外で
  落ちた行に対して $seenCodes.Add('validation-unavailable') と積む。これは
  ハッシュテーブルの Code= を1つも通らないので、上の走査の網には掛からない。
  掛からないまま画面へ届くと、cat.js に文言が無いので汎用文へ落ち、しかも
  qcGroup が赤（利用者の訳の欠陥）で塗る。**道具の不調が欠陥の顔で出る。**

  そこで走査を2本立てにする。
    1. finding の形（Code と Severity の対）を持つハッシュテーブル … 従来どおり
    2. 名前に code を含む入れ物へ、文字列定数を Add しているところ … 合成の種別
  2 を「名前に code を含む変数への .Add(定数)」に限るのは、素の .Add() を全部
  数えると別の一覧（行、理由、問題点）まで巻き込むからである。実測では
  src 全体でこの形は1か所しか無く、それが上の validation-unavailable だった。

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
    # 合成された種別（finding を通らずに積まれるもの）。どこで積まれたかまで残す。
    # 数だけ持つと、網が空になったときに気づけない。
    $synthesized = New-Object 'System.Collections.Generic.List[psobject]'

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
                # 大小を区別しない。cat.js:330 は finding.code も finding.Code も
                # 受けるので、小文字 code で書かれた finding も画面に出る。
                # -ceq にしていたため小文字を黙って見逃していた（2026-08-14 に批評が
                # 使い捨ての複製へ @{ code='zzz'; Severity='error' } を差し込んで実測）。
                # ErrorCode / WarningCode / ReasonCode を巻き込まないのは、素の grep で
                # なく AST の鍵名を完全一致で見ているからであって、大小の区別ではない。
                if ($name -eq 'Code') { $codePair = $pair }
                elseif ($name -eq 'Severity') { $hasSeverity = $true }
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

        # 2本目の走査。$seenCodes.Add('validation-unavailable') のように、
        # finding を通らずに種別だけを積むところを拾う。
        # 受け手の名前に code が入っているものに限る（$rows / $reasons / $problems
        # のような別の一覧を巻き込まないため）。引数が定数でなければ
        # （$seenCodes.Add($code) のような素通し）合成ではないので数えない。
        foreach ($call in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
            $member = ''
            if ($call.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $member = [string]$call.Member.Value }
            if ($member -ne 'Add') { continue }
            if ($call.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $holder = [string]$call.Expression.VariablePath.UserPath
            if ($holder -notmatch '(?i)code') { continue }
            foreach ($argument in @($call.Arguments)) {
                if ($argument -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                $value = ([string]$argument.Value).Trim()
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
                $synthesized.Add([pscustomobject]@{
                    File     = [string]$file.Name
                    Line     = [int]$call.Extent.StartLineNumber
                    Function = (Get-YakuQcEnclosingFunctionName -Ast $call)
                    Holder   = $holder
                    Code     = $value
                }) | Out-Null
            }
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
    foreach ($record in $synthesized.ToArray()) {
        $null = $codes.Add(([string]$record.Code).ToLowerInvariant().Replace('_', '-'))
    }

    return [pscustomobject]@{ Codes = $codes; Producers = $producers; Records = $records; Synthesized = $synthesized }
}

function Get-YakuQcCanonCodesFromSrc {
    <# src 側の正本（Get-YakuCatQcToolTroubleCodes / Get-YakuCatQcWarningCodes）が
       並べている種別を、構文木から読む。関数を dot-source して呼ばないのは、
       この試験が src を1行も実行せずに成り立っている（読むだけ）性質を崩さないため。

       読み方は「その関数の中の `@( … )` ただ1つ」に固定する。註のコメントを
       数える読み方は採らない（コメントを動かすと壊れる門は門ではない）。
       形が読めなければ黙って空を返さず、Problems へ積んで赤にする。
       空で通る門は門ではないからである。

       **ArrayLiteralAst を数えてはいけない**（2026-08-16 に実測して分かった）。
       要素が2つ以上の `@('a','b')` は ArrayExpressionAst の中に ArrayLiteralAst を
       持つが、要素が1つの `@('a')` は ArrayLiteralAst を**作らない**。
       配列リテラルの個数を1に決め打ちすると、正しい1件だけの正本が
       「配列リテラルが 0 個」で落ちる。数えるのは `@( … )` そのものにする。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$FunctionName,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
    )
    $codes = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Problems.Add(('種別の正本を置いたファイルが無い: ' + $Path)) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $Problems.Add(('AST parse error: {0}: {1}' -f (Split-Path -Leaf $Path), [string]$errors[0].Message)) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    $function = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        [string]$n.Name -eq $FunctionName }, $true))
    if ($function.Count -ne 1) {
        $Problems.Add(('src の正本 ' + $FunctionName + ' が ' + $function.Count + ' 個ある（1個であること）')) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    $arrays = @($function[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true))
    if ($arrays.Count -ne 1) {
        $Problems.Add(($FunctionName + ' の中の @( ) が ' + $arrays.Count + ' 個（1個であること。読み方を変えたなら、この門も直す）')) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    # `@( … )` の中身を、文 → パイプライン → 式 の順に開く。素の FindAll で
    # 文字列定数を掻き集めると、要素以外の場所に書いた文字列まで種別に化ける。
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($statement in @($arrays[0].SubExpression.Statements)) {
        if ($statement -isnot [System.Management.Automation.Language.PipelineAst]) {
            $Problems.Add(($FunctionName + ' の @( ) に、式でない文がある: ' + [string]$statement.Extent.Text)) | Out-Null
            continue
        }
        foreach ($element in @($statement.PipelineElements)) {
            if ($element -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                $Problems.Add(($FunctionName + ' の @( ) に、式でない要素がある: ' + [string]$element.Extent.Text)) | Out-Null
                continue
            }
            $expression = $element.Expression
            if ($expression -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                foreach ($member in @($expression.Elements)) { $items.Add($member) | Out-Null }
            } else {
                $items.Add($expression) | Out-Null
            }
        }
    }
    if ($items.Count -eq 0) {
        $Problems.Add(($FunctionName + ' の @( ) から要素を1つも読めなかった')) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    foreach ($element in $items.ToArray()) {
        if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $Problems.Add(($FunctionName + ' に文字列定数でない要素がある: ' + [string]$element.Extent.Text)) | Out-Null
            continue
        }
        $codes.Add(([string]$element.Value).ToLowerInvariant().Replace('_', '-')) | Out-Null
    }
    return [pscustomobject]@{ Codes = $codes }
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

function Get-YakuQcJsSpans {
    <# JS の断片を1文字ずつ辿り、コメントを落としたうえで
       「地の文」と「文字列リテラルの中身」に分ける。正規表現1本では
       文字列の中と外を区別できない（cat.js の文言には // も /* も入り得る）。 #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $backslash   = [char]92
    $bare = New-Object System.Text.StringBuilder
    $current = New-Object System.Text.StringBuilder
    $strings = New-Object 'System.Collections.Generic.List[string]'
    $mode = 'code'   # code / string / line-comment / block-comment
    $quote = [char]0
    $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        switch ($mode) {
            'string' {
                if ($escaped) { [void]$current.Append($c); $escaped = $false; break }
                if ($c -eq $backslash) { $escaped = $true; [void]$current.Append($c); break }
                if ($c -eq $quote) { $strings.Add($current.ToString()) | Out-Null; [void]$current.Clear(); $mode = 'code'; break }
                [void]$current.Append($c)
            }
            'line-comment' { if ($c -eq "`n") { $mode = 'code'; [void]$bare.Append($c) } }
            'block-comment' { if ($c -eq '*' -and $next -eq '/') { $mode = 'code'; $i++ } }
            default {
                if ($c -eq '/' -and $next -eq '/') { $mode = 'line-comment'; $i++; break }
                if ($c -eq '/' -and $next -eq '*') { $mode = 'block-comment'; $i++; break }
                if ($c -eq $singleQuote -or $c -eq $doubleQuote) { $mode = 'string'; $quote = $c; [void]$current.Clear(); break }
                [void]$bare.Append($c)
            }
        }
    }
    return [pscustomobject]@{ Bare = $bare.ToString(); Strings = $strings; Unterminated = ($mode -ne 'code') }
}

function Get-YakuQcJsBalanced {
    <# Text[$OpenIndex] の括弧に対応する閉じ括弧までの中身を返す。
       文字列とコメントの中の括弧は数えない。閉じなければ Found=$false。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][int]$OpenIndex
    )
    $open = $Text[$OpenIndex]
    $close = if ($open -eq '{') { '}' } elseif ($open -eq '[') { ']' } else { ')' }
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $backslash   = [char]92
    $depth = 0
    $mode = 'code'
    $quote = [char]0
    $escaped = $false
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($mode -eq 'string') {
            if ($escaped) { $escaped = $false; continue }
            if ($c -eq $backslash) { $escaped = $true; continue }
            if ($c -eq $quote) { $mode = 'code' }
            continue
        }
        if ($mode -eq 'line-comment') { if ($c -eq "`n") { $mode = 'code' }; continue }
        if ($mode -eq 'block-comment') { if ($c -eq '*' -and $next -eq '/') { $mode = 'code'; $i++ }; continue }
        if ($c -eq '/' -and $next -eq '/') { $mode = 'line-comment'; $i++; continue }
        if ($c -eq '/' -and $next -eq '*') { $mode = 'block-comment'; $i++; continue }
        if ($c -eq $singleQuote -or $c -eq $doubleQuote) { $mode = 'string'; $quote = $c; continue }
        if ($c -eq $open) { $depth++; continue }
        if ($c -eq $close) {
            $depth--
            if ($depth -eq 0) { return [pscustomobject]@{ Found = $true; Inner = $Text.Substring($OpenIndex + 1, $i - $OpenIndex - 1); EndIndex = $i } }
        }
    }
    return [pscustomobject]@{ Found = $false; Inner = ''; EndIndex = -1 }
}

function Get-YakuQcCatJsCodeList {
    <# cat.js の写しの一覧（QC_TOOL_TROUBLE_CODES / QC_WARNING_CODES）を読む。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$ListName,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
    )
    $codes = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Problems.Add(('cat.js が見つからない: ' + $Path)) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    $declaration = [regex]::Match($text, ('var\s+' + [regex]::Escape($ListName) + '\s*=\s*\['))
    if (-not $declaration.Success) {
        $Problems.Add(('cat.js に ' + $ListName + ' の一覧が無い（画面側の分類の出所が消えている）')) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    $arrayOpen = $text.IndexOf('[', $declaration.Index)
    $array = Get-YakuQcJsBalanced -Text $text -OpenIndex $arrayOpen
    if (-not $array.Found) {
        $Problems.Add(('cat.js の ' + $ListName + ' が閉じていない')) | Out-Null
        return [pscustomobject]@{ Codes = $codes }
    }
    $arraySpans = Get-YakuQcJsSpans -Text $array.Inner
    foreach ($value in $arraySpans.Strings.ToArray()) {
        $code = ([string]$value).Trim().ToLowerInvariant().Replace('_', '-')
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $codes.Add($code) | Out-Null
    }
    return [pscustomobject]@{ Codes = $codes }
}

function Test-YakuQcCatJsGroupBody {
    <# qcGroup が**一覧だけ**を見て群を決めていることを確かめる。

       一覧を残したまま `if (code === 'x') return 'tool';` を手で足せる形だと、
       集合の一致の表明を素通りできてしまう。そこで2つを見る。
         1. 本体が、渡した一覧の名前を**全部**参照していること
         2. 本体に出る文字列は、群の名前（'tool' / 'warn' / 'error'）だけであること
       2 により、種別名を直書きした枝は必ず赤になる。群を1つ増やすときは
       AllowedGroups と RequiredLists の両方を足すことになり、その群にも正本が
       要る形が保たれる。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string[]]$RequiredLists,
        [Parameter(Mandatory=$true)][string[]]$AllowedGroups,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problems
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Problems.Add(('cat.js が見つからない: ' + $Path)) | Out-Null
        return $false
    }
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    $fnIndex = $text.IndexOf('function qcGroup(')
    if ($fnIndex -lt 0) {
        $Problems.Add('cat.js に qcGroup 関数が無い（塗り分けの出所が消えている）') | Out-Null
        return $false
    }
    $bodyOpen = $text.IndexOf('{', $fnIndex)
    $body = Get-YakuQcJsBalanced -Text $text -OpenIndex $bodyOpen
    if (-not $body.Found) {
        $Problems.Add('cat.js の qcGroup の本体が閉じていない') | Out-Null
        return $false
    }
    $bodySpans = Get-YakuQcJsSpans -Text $body.Inner
    $ok = $true
    foreach ($listName in @($RequiredLists)) {
        if (-not ([string]$bodySpans.Bare).Contains([string]$listName)) {
            $Problems.Add(('qcGroup が ' + [string]$listName + ' を見ていない（一覧と実際の塗り分けが別物になっている）')) | Out-Null
            $ok = $false
        }
    }
    foreach ($value in $bodySpans.Strings.ToArray()) {
        $literal = [string]$value
        if (@($AllowedGroups) -contains $literal) { continue }
        $Problems.Add(('qcGroup の本体に、一覧を通らない文字列がある: ' + $literal)) | Out-Null
        $ok = $false
    }
    return $ok
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
$synthesized = @($srcScan.Synthesized.ToArray())
$labelKeys = $catScan.Keys

# 走査の不成立は、あとの CASE でも積まれる。同じものを2度数えないように、
# 出したものを覚えておく（1件を2回赤にすると、赤の内訳が実際より重く見える）。
$reportedProblems = New-Object 'System.Collections.Generic.List[string]'
foreach ($problem in $problems.ToArray()) {
    if ($reportedProblems.Contains([string]$problem)) { continue }
    Write-Host ('  FAIL ' + $problem) -ForegroundColor Red; $script:Failures++
    $reportedProblems.Add([string]$problem) | Out-Null
}

# 生成元が消えると、コード集合は空になり (a) は自動的に通ってしまう。
# 空で通る門は門ではないので、既知の生成元が居ることを先に確かめる。
foreach ($expected in @('Invoke-YakuCatSegmentValidation', 'Test-YakuTerminologyCompliance')) {
    Assert-YakuQcLabel ($producers.Contains($expected)) ('finding の生成元を見つけた: ' + $expected)
}
Assert-YakuQcLabel ($srcCodes.Count -gt 0) ('src が生成する finding コードを数えた: ' + $srcCodes.Count + ' 件')
Assert-YakuQcLabel ($labelKeys.Count -gt 0) ('cat.js のラベルを数えた: ' + $labelKeys.Count + ' 件')
# 2本目の走査が空だと、(a) は合成された種別を1つも見ないまま通ってしまう。
# 空で通る門は門ではないので、実際に拾えていることをここで数える。
# （2026-08-15 の実測では src 全体で1件。validation-unavailable である）
Assert-YakuQcLabel ($synthesized.Count -gt 0) ('finding を通らずに合成される種別を拾えた: ' +
    (($synthesized | ForEach-Object { [string]$_.Code + '（' + [string]$_.File + ':' + [string]$_.Line + '）' }) -join ', '))

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

Write-Host 'CASE 4: 「道具の不調」の顔ぶれが、src と cat.js で一致する'
# 色は表示だけの話である。ここで見ているのは塗り分けであって、書き出しを
# 止める条件ではない。道具の不調で止まった行は、色が変わっても止まったままである。
$catProjectPath = Join-Path $srcDir 'CatProject.ps1'
$srcToolCodes = @((Get-YakuQcCanonCodesFromSrc -Path $catProjectPath -FunctionName 'Get-YakuCatQcToolTroubleCodes' -Problems $problems).Codes.ToArray())
$catToolCodes = @((Get-YakuQcCatJsCodeList -Path $catJsPath -ListName 'QC_TOOL_TROUBLE_CODES' -Problems $problems).Codes.ToArray())
$srcWarnCodes = @((Get-YakuQcCanonCodesFromSrc -Path $catProjectPath -FunctionName 'Get-YakuCatQcWarningCodes' -Problems $problems).Codes.ToArray())
$catWarnCodes = @((Get-YakuQcCatJsCodeList -Path $catJsPath -ListName 'QC_WARNING_CODES' -Problems $problems).Codes.ToArray())
# 群を決める枝が一覧だけを見ていること。ここが素通りできると、下の集合の一致は
# 「一覧に何が書いてあるか」だけの話になり、実際の塗り分けと無関係になる。
$groupBodyOk = Test-YakuQcCatJsGroupBody -Path $catJsPath -RequiredLists @('QC_TOOL_TROUBLE_CODES','QC_WARNING_CODES') `
    -AllowedGroups @('tool','warn','error') -Problems $problems
foreach ($problem in $problems.ToArray()) {
    if ($reportedProblems.Contains([string]$problem)) { continue }
    Write-Host ('  FAIL ' + $problem) -ForegroundColor Red; $script:Failures++
    $reportedProblems.Add([string]$problem) | Out-Null
}
# 両方が空だと、下の一致は自動的に成立してしまう。空で通る門は門ではない。
Assert-YakuQcLabel ($srcToolCodes.Count -gt 0) ('src が道具の不調と分類した種別を読めた: ' + ($srcToolCodes -join ', '))
Assert-YakuQcLabel ($catToolCodes.Count -gt 0) ('cat.js が道具の色で塗る種別を読めた: ' + ($catToolCodes -join ', '))
# 正本に、src が一度も出さない名前を置かない（死んだ名前は分類を嘘にする）
$deadTool = @($srcToolCodes | Where-Object { -not $srcCodes.Contains([string]$_) })
Assert-YakuQcLabel ($deadTool.Count -eq 0) ('道具の不調の正本に、src が生成しない名前は無い' + $(if ($deadTool.Count -gt 0) { '（死語: ' + ($deadTool -join ', ') + '）' } else { '' }))
# 一致は両向きで見る。片方だけだと、足し忘れの向きによって黙る。
$toolOnlyInSrc = @($srcToolCodes | Where-Object { $catToolCodes -notcontains [string]$_ })
$toolOnlyInCat = @($catToolCodes | Where-Object { $srcToolCodes -notcontains [string]$_ })
Assert-YakuQcLabel ($toolOnlyInSrc.Count -eq 0) ('src が道具の不調と言った種別を、画面も道具の色で塗る' + $(if ($toolOnlyInSrc.Count -gt 0) { '（画面が赤で塗っている: ' + ($toolOnlyInSrc -join ', ') + '）' } else { '' }))
Assert-YakuQcLabel ($toolOnlyInCat.Count -eq 0) ('画面が道具の色で塗る種別は、src もそう分類している' + $(if ($toolOnlyInCat.Count -gt 0) { '（src に無い: ' + ($toolOnlyInCat -join ', ') + '）' } else { '' }))
Assert-YakuQcLabel $groupBodyOk 'qcGroup は一覧だけを見て群を決めている（種別名の直書きが無い）'

Write-Host 'CASE 5: 「止めない警告」の顔ぶれが、src と cat.js で一致する'
# 道具の不調と同じ形の穴が、別の群でも開く。あちらは直しようが無いもの、
# こちらは直せるが直さなくても書き出せるもので、どちらも赤（訳の欠陥）ではない。
# ここも表示の分類だけを見る。止める条件は Severity='error' だけで決まる。
Assert-YakuQcLabel ($srcWarnCodes.Count -gt 0) ('src が止めない警告と分類した種別を読めた: ' + ($srcWarnCodes -join ', '))
Assert-YakuQcLabel ($catWarnCodes.Count -gt 0) ('cat.js が警告の色で塗る種別を読めた: ' + ($catWarnCodes -join ', '))
$deadWarn = @($srcWarnCodes | Where-Object { -not $srcCodes.Contains([string]$_) })
Assert-YakuQcLabel ($deadWarn.Count -eq 0) ('止めない警告の正本に、src が生成しない名前は無い' + $(if ($deadWarn.Count -gt 0) { '（死語: ' + ($deadWarn -join ', ') + '）' } else { '' }))
$warnOnlyInSrc = @($srcWarnCodes | Where-Object { $catWarnCodes -notcontains [string]$_ })
$warnOnlyInCat = @($catWarnCodes | Where-Object { $srcWarnCodes -notcontains [string]$_ })
Assert-YakuQcLabel ($warnOnlyInSrc.Count -eq 0) ('src が止めない警告と言った種別を、画面も警告の色で塗る' + $(if ($warnOnlyInSrc.Count -gt 0) { '（画面が赤で塗っている: ' + ($warnOnlyInSrc -join ', ') + '）' } else { '' }))
Assert-YakuQcLabel ($warnOnlyInCat.Count -eq 0) ('画面が警告の色で塗る種別は、src もそう分類している' + $(if ($warnOnlyInCat.Count -gt 0) { '（src に無い: ' + ($warnOnlyInCat -join ', ') + '）' } else { '' }))
# 2つの正本が重なると、qcGroup の返す群が並び順で決まってしまう。
$overlap = @($srcWarnCodes | Where-Object { $srcToolCodes -contains [string]$_ })
Assert-YakuQcLabel ($overlap.Count -eq 0) ('道具の不調と止めない警告は重ならない' + $(if ($overlap.Count -gt 0) { '（両方に居る: ' + ($overlap -join ', ') + '）' } else { '' }))

if ($script:Failures -gt 0) {
    Write-Host ''
    Write-Host ('src tool codes    : ' + ($srcToolCodes -join ', ')) -ForegroundColor Yellow
    Write-Host ('cat.js tool codes : ' + ($catToolCodes -join ', ')) -ForegroundColor Yellow
    Write-Host ('src warn codes    : ' + ($srcWarnCodes -join ', ')) -ForegroundColor Yellow
    Write-Host ('cat.js warn codes : ' + ($catWarnCodes -join ', ')) -ForegroundColor Yellow
    Write-Host ('src codes   : ' + ((@($srcCodes | Sort-Object)) -join ', ')) -ForegroundColor Yellow
    Write-Host ('cat.js keys : ' + ((@($labelKeys.ToArray() | Sort-Object)) -join ', ')) -ForegroundColor Yellow
    Write-Host "V91.61 CAT QC label coverage test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host ('V91.61 CAT QC label coverage regression passed. codes=' + $srcCodes.Count + ' labels=' + $labelKeys.Count) -ForegroundColor Green
