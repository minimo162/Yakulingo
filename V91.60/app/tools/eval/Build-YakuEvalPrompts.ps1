<#
.SYNOPSIS
  評価セットから、アプリが実際に送るのと同じプロンプトを生成する。

.DESCRIPTION
  New-YakuTextPrompt をそのまま使うため、用語集の注入・数値規則・BRIEF規則を
  含めた実物のプロンプトが得られる。生成したプロンプトを翻訳エンジン（Copilot、
  または評価用の代替モデル）へ渡し、応答を responses/ へ保存する。

  Copilot は呼び出さない。プロンプトを書き出すだけである。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\eval\Build-YakuEvalPrompts.ps1
#>
[CmdletBinding()]
param(
    [string]$EvalSet = '',
    [string]$OutDir = '',
    [string]$AppRoot = '',
    [string]$Label = 'baseline'
)

$ErrorActionPreference = 'Stop'
$evalRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsRoot = Split-Path -Parent $evalRoot
# -AppRoot でプロンプト・用語集の出所を差し替えられる。A/B比較のため。
$appRoot = if ([string]::IsNullOrWhiteSpace($AppRoot)) { Split-Path -Parent $toolsRoot } else { (Resolve-Path -LiteralPath $AppRoot).Path }
if ([string]::IsNullOrWhiteSpace($EvalSet)) { $EvalSet = Join-Path $evalRoot 'evalset.json' }

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','Translation.ps1')) {
    . (Join-Path (Join-Path $appRoot 'src') $n)
}

# 既定値の解決は dot-source の後で行う。パラメータ既定値は関数の読込より先に
# 評価されるため、param ブロックで Get-YakuSubDir を呼ぶことはできない。
# 生成物はアプリツリーへ置かない。配布物に混ざり manifest と食い違うため。
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path (Join-Path (Get-YakuSubDir 'eval') $Label) 'prompts' }

$set = [IO.File]::ReadAllText($EvalSet) | ConvertFrom-Json
$settings = Read-YakuSettings -Root $appRoot
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$index = New-Object System.Collections.Generic.List[object]
$seq = 0
foreach ($case in @($set.cases)) {
    $id = [string]$case.id
    $seq++
    # request_id はケースIDから決定的に作る。応答の取り違えを防ぐため、
    # 先頭12文字が衝突しても通し番号で必ず一意になるようにする。
    $stem = ($id -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
    if ($stem.Length -gt 8) { $stem = $stem.Substring(0, 8) }
    $requestId = ('EVAL' + $stem.PadRight(8, 'X') + ('{0:00}' -f $seq))
    $built = New-YakuTextPrompt -Root $appRoot -InputText ([string]$case.source) -Settings $settings `
        -DirectionOverride ([string]$case.direction) -RequestId $requestId
    $path = Join-Path $OutDir ($id + '.prompt.txt')
    [IO.File]::WriteAllText($path, [string]$built.Prompt, (New-Object Text.UTF8Encoding($false)))
    $index.Add([ordered]@{ id = $id; request_id = $requestId; direction = [string]$built.Direction; prompt_chars = ([string]$built.Prompt).Length; prompt_file = ($id + '.prompt.txt') }) | Out-Null
    Write-Host ('{0,-26} {1}  {2} chars' -f $id, $requestId, ([string]$built.Prompt).Length)
}

$indexPath = Join-Path $OutDir '_index.json'
[IO.File]::WriteAllText($indexPath, (@{ generated_for = 'eval'; cases = @($index.ToArray()) } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("プロンプト {0} 件を生成しました (label={1}, appRoot={2})" -f $index.Count, $Label, $appRoot) -ForegroundColor Green
Write-Host ("  " + $OutDir)
Write-Host '応答は同じIDで <id>.response.txt として responses/ へ保存してください。'
