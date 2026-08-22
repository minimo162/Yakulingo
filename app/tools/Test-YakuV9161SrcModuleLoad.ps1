<#
.SYNOPSIS
  読み込み順序が1か所にまとまっていること、そこから漏れたファイルが無いことを見る。

.DESCRIPTION
  2026-08-12: Server.ps1 の中に同じ意味の一覧が4つ手で書き写されていた。
  本体30件と、別ランスペースで動くプリロード3か所の22件。写し間違いは静かに効く。
  実際 GlossaryVariants.ps1 はどの一覧にも入っておらず、CellAlign.ps1 が
  ConvertTo-YakuPeriodNeutralName を Get-Command で守って呼んでいたため、その機能は
  動くアプリの中で一度も走っていなかった。試験は自分で dot-source して通していたので
  緑のままだった。

  ここでは、アプリを起動せずに次を見る。
    1. src\*.ps1 のうち、読み込み一覧に無いものが無い（除外は3つだけ）
    2. Server.ps1 に手書きの一覧が復活していない
    3. 一覧に載っているファイルから呼ばれる関数が、その一覧の中で定義されている
       （Get-Command で守っている呼び出しは、任意の依存として除く）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161SrcModuleLoad.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$srcDir = Join-Path $root 'src'
$script:Failures = 0

function Assert-YakuLoad {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

# 一覧そのものを読む。配列を1つ置くだけのファイルなので副作用は無い。
. (Join-Path $srcDir 'SrcModules.ps1')
$listed = @($script:YakuSrcModuleFiles)

Write-Host 'CASE 1: src の全ファイルが読み込み一覧に載っている' -ForegroundColor Cyan
# 入口・プロセス単位の初期化・一覧そのもの、の3つだけが例外。
$excluded = @('Server.ps1','JobObject.ps1','SrcModules.ps1')
$onDisk = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' -File | ForEach-Object { $_.Name })
$shouldBeListed = @($onDisk | Where-Object { $excluded -notcontains $_ })
foreach ($name in $shouldBeListed) {
    Assert-YakuLoad ($listed -contains $name) ($name + ' が読み込み一覧に入っている')
}
foreach ($name in $listed) {
    Assert-YakuLoad (Test-Path -LiteralPath (Join-Path $srcDir $name) -PathType Leaf) ('一覧の ' + $name + ' が実在する')
}
$dupes = @($listed | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Assert-YakuLoad ($dupes.Count -eq 0) ('一覧に重複が無い' + $(if ($dupes.Count) { '（重複: ' + ($dupes -join ',') + '）' } else { '' }))

Write-Host 'CASE 2: Server.ps1 に手書きの一覧が復活していない' -ForegroundColor Cyan
$serverPath = Join-Path $srcDir 'Server.ps1'
$tokens = $null; $parseErrors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrors)
Assert-YakuLoad (@($parseErrors).Count -eq 0) 'Server.ps1 が構文として読める'
$dotSourced = New-Object System.Collections.Generic.List[string]
foreach ($call in @($serverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    if ([string]$call.InvocationOperator -ne 'Dot') { continue }
    foreach ($element in @($call.CommandElements)) {
        foreach ($literal in @($element.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
            $value = [string]$literal.Value
            if ($value -match '\.ps1$') { $dotSourced.Add((Split-Path -Leaf $value)) | Out-Null }
        }
    }
}
$srcModuleHits = @($dotSourced.ToArray() | Where-Object { $_ -eq 'SrcModules.ps1' })
$otherHits = @($dotSourced.ToArray() | Where-Object { $_ -ne 'SrcModules.ps1' })
Assert-YakuLoad ($srcModuleHits.Count -eq 4) ('読み込み口は4か所とも一覧を読む（実際 ' + $srcModuleHits.Count + ' か所）')
Assert-YakuLoad ($otherHits.Count -eq 0) ('Server.ps1 が個別のファイルを直接読み込んでいない' + $(if ($otherHits.Count) { '（' + (($otherHits | Sort-Object -Unique) -join ',') + '）' } else { '' }))

Write-Host 'CASE 3: 一覧の中から呼ばれる関数が、一覧の中で定義されている' -ForegroundColor Cyan
$definedIn = @{}
$asts = @{}
foreach ($name in $listed) {
    $path = Join-Path $srcDir $name
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
    $asts[$name] = $ast
    foreach ($fn in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        $definedIn[[string]$fn.Name] = $name
    }
    # function 構文以外の定義も拾う。CopilotClient.ps1 は保護付きの入口を
    # Set-Item Function:script:... で作っており（外から差し替えられないようにするため）、
    # 構文木の関数定義としては現れない。
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText((Join-Path $srcDir $name)), 'Function:(?:script:|global:)?(?<name>[A-Za-z]+-Yaku[A-Za-z0-9]*)')) {
        $definedIn[[string]$m.Groups['name'].Value] = $name
    }
}
# Server.ps1 の中だけで定義されている関数。ワーカーのランスペースには居ない。
$serverOnly = @{}
foreach ($fn in @($serverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    if (-not $definedIn.ContainsKey([string]$fn.Name)) { $serverOnly[[string]$fn.Name] = $true }
}
$unresolved = New-Object System.Collections.Generic.List[string]
foreach ($name in $listed) {
    $text = [IO.File]::ReadAllText((Join-Path $srcDir $name))
    foreach ($call in @($asts[$name].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = [string]$call.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) { continue }
        if ($commandName -notmatch '^[A-Za-z]+-Yaku') { continue }
        if ($definedIn.ContainsKey($commandName)) { continue }
        # Get-Command で存在を確かめてから呼ぶものは「あれば使う」依存として認める。
        if ($text -match ('Get-Command\s+' + [regex]::Escape($commandName))) { continue }
        $where = $name + ':' + [string]$call.Extent.StartLineNumber
        $reason = if ($serverOnly.ContainsKey($commandName)) { 'Server.ps1 でしか定義されていない' } else { 'どこにも定義が無い' }
        $unresolved.Add(($commandName + ' (' + $where + ') ' + $reason)) | Out-Null
    }
}
$unresolvedUnique = @($unresolved.ToArray() | Sort-Object -Unique)
Assert-YakuLoad ($unresolvedUnique.Count -eq 0) '一覧の中から呼ばれる関数が、すべて一覧の中で定義されている'
foreach ($item in $unresolvedUnique) { Write-Host ('       ' + $item) -ForegroundColor Yellow }

if ($script:Failures -gt 0) {
    Write-Host "src module load test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'src module load regression passed.' -ForegroundColor Green
