<#
.SYNOPSIS
  Excel との COM 接続が切れたとき（0x800706BA など）の回復処理の回帰テスト。

.DESCRIPTION
  - RPC 切断の例外を、包まれていても見分けること
  - 1回目に切断されたら、BeforeRetry で状態を戻して新しい Excel でやり直すこと
  - やり直しても切断されたら、次にすべきことが分かる文で止めること
  - 切断以外の例外はやり直さずにそのまま投げること
  - 画面に「RPC サーバーを利用できません」を生のまま出さないこと

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuExcelRpcRecovery.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuRpc {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}
$src = Join-Path $root 'src'
. (Join-Path $src 'Paths.ps1')
. (Join-Path $src 'Runtime.ps1')
. (Join-Path $src 'Html.ps1')
. (Join-Path $src 'FileProcessors.ps1')
function Write-YakuLog { param($Message, $Level) }
function Start-Sleep { param($Seconds, $Milliseconds) }

$rpcMessage = 'RPC サーバーを利用できません。 (HRESULT からの例外:0x800706BA)'
function New-YakuTestRpcError {
    $com = [System.Runtime.InteropServices.COMException]::new($rpcMessage, -2147023174)
    return [System.Management.Automation.MethodInvocationException]::new('Exception calling "Save" with "0" argument(s): ' + $rpcMessage, $com)
}

Write-Host 'CASE 1: RPC 切断の例外を見分ける'
Assert-YakuRpc (Test-YakuExcelRpcLostError -ErrorRecord (New-YakuTestRpcError)) '包まれた 0x800706BA を切断と判定する'
Assert-YakuRpc (Test-YakuExcelRpcLostError -ErrorRecord ([System.Runtime.InteropServices.COMException]::new('disconnected', -2147417848))) '0x80010108 を切断と判定する'
Assert-YakuRpc (-not (Test-YakuExcelRpcLostError -ErrorRecord ([System.InvalidOperationException]::new('other')))) '切断以外は判定しない'
Assert-YakuRpc (-not (Test-YakuExcelRpcLostError -ErrorRecord ([System.Runtime.InteropServices.COMException]::new('busy', -2147418111)))) 'Excel 応答待ち (0x80010001) は対象外'

Write-Host 'CASE 2: 1回目に切断されたら、状態を戻して新しい Excel でやり直す'
$script:calls = 0; $script:resets = 0
$result = Invoke-YakuExcelWithRpcRecovery -Stage 'test' -Action {
    $script:calls++
    if ($script:calls -eq 1) { throw (New-YakuTestRpcError) }
    [pscustomobject]@{ WrittenCount = 7 }
} -BeforeRetry { $script:resets++ }
Assert-YakuRpc ($script:calls -eq 2 -and $script:resets -eq 1) "やり直しは1回、戻し処理も1回 (calls=$script:calls resets=$script:resets)"
Assert-YakuRpc ([int]$result.WrittenCount -eq 7) 'やり直した結果を返す'

Write-Host 'CASE 3: やり直しても切断されたら、分かる文で止める'
$script:calls = 0
$message = ''
try { Invoke-YakuExcelWithRpcRecovery -Stage 'test' -Action { $script:calls++; throw (New-YakuTestRpcError) } | Out-Null } catch { $message = [string]$_.Exception.Message }
Assert-YakuRpc ($script:calls -eq 2) "やり直しは既定で1回まで (calls=$script:calls)"
Assert-YakuRpc ($message -like 'EXCEL_RPC_UNAVAILABLE:*') ('エラーコード付きで止める: ' + $message)
$friendly = Get-YakuFriendlyError -Message $message
Assert-YakuRpc ([string]$friendly.Message -like 'Excelとの接続が切れた*' -and -not ([string]$friendly.Message).Contains('EXCEL_RPC_UNAVAILABLE')) ('画面にはコードを外して出す: ' + $friendly.Message)

Write-Host 'CASE 4: 切断以外の例外はやり直さない'
$script:calls = 0
$message = ''
try { Invoke-YakuExcelWithRpcRecovery -Stage 'test' -Action { $script:calls++; throw 'OUTPUT_VALIDATION_FORMULA: x' } | Out-Null } catch { $message = [string]$_.Exception.Message }
Assert-YakuRpc ($script:calls -eq 1 -and $message -eq 'OUTPUT_VALIDATION_FORMULA: x') 'そのまま投げる'

Write-Host 'CASE 5: キャンセルはやり直さない'
$script:calls = 0
$cancelled = $false
try { Invoke-YakuExcelWithRpcRecovery -Stage 'test' -Action { $script:calls++; throw [System.OperationCanceledException]::new('cancel') } | Out-Null } catch [System.OperationCanceledException] { $cancelled = $true }
Assert-YakuRpc ($cancelled -and $script:calls -eq 1) 'キャンセルをそのまま伝える'

Write-Host 'CASE 6: 生の RPC エラー文を画面に出さない'
$friendly = Get-YakuFriendlyError -Message $rpcMessage
Assert-YakuRpc ([string]$friendly.Message -like 'Excelとの接続が切れました*') ('言い換え: ' + $friendly.Message)
Assert-YakuRpc ([string]$friendly.Detail -eq $rpcMessage) '元の本文は詳細に残す'

Write-Host 'CASE 7: 止める Excel が無ければ何もしない'
$script:YakuLastExcelProcess = $null
Stop-YakuLostExcelProcess
$script:YakuLastExcelProcess = [pscustomobject]@{ Id = $PID; StartedAt = '2000-01-01T00:00:00.0000000Z' }
Stop-YakuLostExcelProcess
Assert-YakuRpc ($null -eq $script:YakuLastExcelProcess) '起動時刻が一致しないプロセスは止めない'

if ($script:Failures -gt 0) {
    Write-Host "Excel RPC recovery test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'Excel RPC recovery regression passed.' -ForegroundColor Green
