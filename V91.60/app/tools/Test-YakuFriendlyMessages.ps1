<#
.SYNOPSIS
  画面に出す状態表示・エラー文の回帰テスト。

.DESCRIPTION
  技術的な例外の本文（CDP、Reason=… など）をそのまま画面に出さず、
  次にすべきことを日本語で示すこと、元の本文は「詳細」にだけ残すことを確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuFriendlyMessages.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuFm {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}
. (Join-Path (Join-Path $root 'src') 'Html.ps1')

Write-Host 'CASE 1: 技術的な本文は言い換え、元の本文は詳細に残す'
foreach ($c in @(
    @{ Raw = 'Copilot入力欄が見つかりません。Reason=login-required URL=https://login.microsoftonline.com/ Title= Context=x'; Expect = '*ログイン*' },
    @{ Raw = 'Copilot入力欄が見つかりません。Reason=timeout URL=https://m365.cloud.microsoft/chat/'; Expect = '*Edgeの画面*' },
    @{ Raw = 'CDP method timed out: Runtime.evaluate'; Expect = '*応答がありませんでした*' },
    @{ Raw = 'JavaScript evaluation failed: TypeError'; Expect = '*応答がありませんでした*' },
    @{ Raw = 'RESPONSE_STRUCTURE_MISMATCH: headings=3/2'; Expect = '*回答を読み取れません*' },
    @{ Raw = 'Unexpected token at position 42'; Expect = '*管理者に連絡*' }
)) {
    $e = Get-YakuFriendlyError -Message ([string]$c.Raw)
    Assert-YakuFm ([string]$e.Message -like [string]$c.Expect) ("言い換え: " + $c.Raw + ' -> ' + $e.Message)
    Assert-YakuFm (-not ([string]$e.Message -match 'Reason=|URL=|CDP|JavaScript')) '言い換えに技術用語を残さない'
    Assert-YakuFm ([string]$e.Detail -eq [string]$c.Raw) '元の本文は詳細に残す'
}

Write-Host 'CASE 2: 日本語の案内はコードだけ外してそのまま出す'
$e = Get-YakuFriendlyError -Message 'SHEET_NOT_FOUND: 指定シートが見つかりません: 集計。このファイルのシート: Sheet1、Sheet2'
Assert-YakuFm ([string]$e.Message -eq '指定シートが見つかりません: 集計。このファイルのシート: Sheet1、Sheet2') ('コードを外す: ' + $e.Message)
$e = Get-YakuFriendlyError -Message '翻訳対象ファイルが見つかりません。'
Assert-YakuFm ([string]$e.Message -eq '翻訳対象ファイルが見つかりません。' -and [string]::IsNullOrEmpty([string]$e.Detail)) 'もともと分かりやすい文は詳細を付けない'

Write-Host 'CASE 3: 画面の部品'
$html = New-YakuErrorAlertHtml -Raw 'CDP method timed out: <script>'
Assert-YakuFm ($html.Contains("<details class='error-details'>") -and $html.Contains('&lt;script&gt;') -and -not $html.Contains('<script>')) '詳細は折りたたみ、エスケープする'

Write-Host 'CASE 4: 状態表示に英語を残さない'
$targets = @('src\Server.ps1','src\FileWorker.ps1','tools\Prepare-Copilot.ps1','www\index.html','www\assets\app.js')
foreach ($t in $targets) {
    $text = Get-Content -LiteralPath (Join-Path $root $t) -Raw -Encoding UTF8
    foreach ($word in @("'Preparing Copilot'","'Translation error'","'Completed with warnings'","'Login required'","'Not ready'","'Cancelling'","'Opening file'","<span>Preparing</span>","<span>Ready</span>")) {
        Assert-YakuFm (-not $text.Contains($word)) ("$t に $word が無い")
    }
}

if ($script:Failures -gt 0) {
    Write-Host "Friendly message test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'Friendly message regression passed.' -ForegroundColor Green
