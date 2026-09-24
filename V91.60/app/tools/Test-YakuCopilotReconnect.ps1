<#
.SYNOPSIS
  Copilot の再接続（準備のやり直し）の回帰テスト。

.DESCRIPTION
  翻訳がログイン切れ・入力欄の消失で失敗したときに準備をやり直すこと、
  同じジョブで何度もやり直さないこと、訳文の形式エラーでは触らないこと、
  準備中に重ねて起動しないことを確かめる。Server.ps1 は読み込むと起動するため、
  必要な関数だけを構文木から取り出して読む。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuCopilotReconnect.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuRc {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

$serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$errors)
$wanted = @('Test-YakuCopilotWarmupRunning','Restart-YakuCopilotWarmup','Test-YakuCopilotConnectionLostMessage','Invoke-YakuCopilotRecoveryForFailedJob')
foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))) {
    if ($wanted -contains $fn.Name) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
foreach ($name in $wanted) { Assert-YakuRc ([bool](Get-Command $name -ErrorAction SilentlyContinue)) ("関数がある: $name") }

function Write-YakuLog { param($Message, $Level) }
$script:WarmupStarts = 0
function Start-YakuCopilotWarmup { $script:WarmupStarts++ }

Write-Host 'CASE 1: どの失敗で準備をやり直すか'
Assert-YakuRc (Test-YakuCopilotConnectionLostMessage -Message 'Copilot入力欄が見つかりません。Reason=login-required URL=https://login.microsoftonline.com/') 'ログイン切れ'
Assert-YakuRc (Test-YakuCopilotConnectionLostMessage -Message 'Copilot入力欄が見つかりません。Reason=timeout URL=https://m365.cloud.microsoft/chat/') '入力欄が無い'
Assert-YakuRc (Test-YakuCopilotConnectionLostMessage -Message 'COPILOT_REFUSAL_OR_LOGIN: 翻訳ではない拒否・ログイン要求を検出しました。') '拒否・ログイン要求の応答'
Assert-YakuRc (-not (Test-YakuCopilotConnectionLostMessage -Message 'RESPONSE_STRUCTURE_MISMATCH: headings')) '訳文の形式エラーでは触らない'
Assert-YakuRc (-not (Test-YakuCopilotConnectionLostMessage -Message '')) '空なら触らない'

Write-Host 'CASE 2: 失敗したジョブ1件につき1回だけやり直す'
$script:YakuWarmupProcess = $null
Invoke-YakuCopilotRecoveryForFailedJob -JobId 'job-a' -Detail 'Copilot入力欄が見つかりません。Reason=login-required'
Invoke-YakuCopilotRecoveryForFailedJob -JobId 'job-a' -Detail 'Copilot入力欄が見つかりません。Reason=login-required'
Assert-YakuRc ($script:WarmupStarts -eq 1) ("同じジョブでは1回だけ: starts=$script:WarmupStarts")
Invoke-YakuCopilotRecoveryForFailedJob -JobId 'job-b' -Detail 'RESPONSE_PLACEHOLDER_MISMATCH: numeric placeholders'
Assert-YakuRc ($script:WarmupStarts -eq 1) '形式エラーのジョブではやり直さない'

Write-Host 'CASE 3: 準備中は重ねて起動しない'
$script:YakuWarmupProcess = [pscustomobject]@{ HasExited = $false }
Assert-YakuRc (-not (Restart-YakuCopilotWarmup -Reason 'test')) '準備の途中なら起動しない'
$script:YakuWarmupProcess = [pscustomobject]@{ HasExited = $true }
Assert-YakuRc (Restart-YakuCopilotWarmup -Reason 'test') '準備が終わっていれば起動する'
Assert-YakuRc ($script:WarmupStarts -eq 2) ("起動回数: $script:WarmupStarts")

Write-Host 'CASE 4: 画面と経路'
$server = Get-Content -LiteralPath $serverPath -Raw -Encoding UTF8
$appJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\app.js') -Raw -Encoding UTF8
$index = Get-Content -LiteralPath (Join-Path $root 'www\index.html') -Raw -Encoding UTF8
Assert-YakuRc ($server.Contains("`$path -eq '/api/copilot/reconnect'")) '再接続の経路がある'
Assert-YakuRc ($appJs.Contains('data-yaku-reconnect') -and $appJs.Contains('/api/copilot/reconnect')) '画面に再接続ボタンがある'
Assert-YakuRc ($index.IndexOf('id="startup-gate"') -lt $index.IndexOf('id="panel-text"')) '準備状況の表示はテキスト/ファイルどちらのタブでも見える'

if ($script:Failures -gt 0) {
    Write-Host "Copilot reconnect test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'Copilot reconnect regression passed.' -ForegroundColor Green
