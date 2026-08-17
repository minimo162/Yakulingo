#Requires -Version 5.1
<#
  背面に落ちた Copilot タブを、要求のたびに前面へ戻すこと。

  2026-08-17 に実機で起きた不具合の回帰。Copilot のタブが Edge の背面に
  数分置かれると、Edge がそのタブの setTimeout と requestAnimationFrame を
  止める。すると「await sleep(...)」を含むスクリプトだけが返らなくなり、
  新しいチャットの準備が 15 秒で時間切れになる。

  実測（利用者の機械、2026-08-17 04:2x）:

      document.visibilityState = "hidden"   document.hidden = true
      setTimeout(300ms)        3秒後も発火せず
      requestAnimationFrame    2秒後も発火せず
      performance.now()        +2009ms 進む   ← 描画側は生きている
      1+1 の評価               97ms で返る    ← 生存確認は通ってしまう

  **見つからなかった理由は監視のほうにある。**
  `Repair-YakuCopilotPageResponsiveness` の生存確認が `1+1` で、これは
  凍ったタブでも即答する。対象が壊れていても緑を返す形になっていた。
  利用者へ出ていた案内は「Edge を再起動してください」で、原因を
  指していなかった。

  この試験は Copilot も Edge も要らない。CDP の評価を差し替えて動かす。

  変数名に接頭辞を付けてある。モジュールを読み込むと `$src` のような
  ありふれた名前は上書きされ、最初に書いた版はそれで落ちた。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9183Root = Split-Path -Parent $PSScriptRoot
$YakuT9183Src = Join-Path $YakuT9183Root 'src'
$YakuT9183ClientPath = Join-Path $YakuT9183Src 'CopilotClient.ps1'
$YakuT9183WarmupPath = Join-Path $YakuT9183Root 'tools\Prepare-Copilot.ps1'
. (Join-Path $YakuT9183Src 'SrcModules.ps1')
foreach ($YakuT9183File in $script:YakuSrcModuleFiles) { . (Join-Path $YakuT9183Src $YakuT9183File) }

$script:T9183Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9183 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9183Failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9183CopilotTabVisibility'

$script:T9183Evals = New-Object System.Collections.Generic.List[string]
$script:T9183Bring = 0
$script:T9183HiddenValues = New-Object System.Collections.Generic.Queue[object]

function Invoke-YakuCdpEval {
    param($Page, [string]$Expression, [int]$TimeoutSeconds = 15)
    $script:T9183Evals.Add($Expression) | Out-Null
    if ($Expression -eq 'document.hidden') {
        if ($script:T9183HiddenValues.Count -gt 0) { return $script:T9183HiddenValues.Dequeue() }
        return $false
    }
    if ($Expression -eq '1+1') { return 2 }
    return $null
}
function Invoke-YakuCdpBringToFront { param($Page) $script:T9183Bring++ }
function Write-YakuLog { param([string]$Message, [string]$Level = 'INFO') }

$YakuT9183Page = [pscustomobject]@{ id = 'T1' }
function Reset-T9183 {
    param([object[]]$HiddenValues)
    $script:T9183Evals.Clear()
    $script:T9183Bring = 0
    $script:T9183HiddenValues.Clear()
    foreach ($v in @($HiddenValues)) { $script:T9183HiddenValues.Enqueue($v) }
}

# --- 1. 見えているタブには触らない -------------------------------------------
Reset-T9183 -HiddenValues @($false)
$null = Restore-YakuCopilotTabVisibility -Page $YakuT9183Page
Assert-T9183 -Condition ($script:T9183Bring -eq 0) -Message 'a visible tab is left alone (no bring-to-front)'

# --- 2. 隠れているタブは1回だけ前面へ戻し、戻ったか確かめ直す -----------------
Reset-T9183 -HiddenValues @($true, $false)
$null = Restore-YakuCopilotTabVisibility -Page $YakuT9183Page
Assert-T9183 -Condition ($script:T9183Bring -eq 1) -Message 'a hidden tab is brought to front exactly once'
Assert-T9183 -Condition (@($script:T9183Evals.ToArray() | Where-Object { $_ -eq 'document.hidden' }).Count -eq 2) `
    -Message 'visibility is re-checked after bringing it to front'

# --- 3. 生存確認が `1+1` だけで終わらないこと --------------------------------
# 凍ったタブでも 1+1 は返る。返ったからといって、そのまま先へ進めてはいけない。
Reset-T9183 -HiddenValues @($true, $false)
$null = Repair-YakuCopilotPageResponsiveness -Page $YakuT9183Page -Port 9433 -Url 'https://m365.cloud.microsoft/chat/'
Assert-T9183 -Condition ($script:T9183Evals -contains '1+1') -Message 'the liveness ping still runs'
Assert-T9183 -Condition ($script:T9183Bring -eq 1) `
    -Message 'a ping that succeeds does NOT end the check: a hidden tab is still brought to front'

Reset-T9183 -HiddenValues @($false)
$null = Repair-YakuCopilotPageResponsiveness -Page $YakuT9183Page -Port 9433 -Url 'https://m365.cloud.microsoft/chat/'
Write-Host ('       [diag] bring=' + $script:T9183Bring + ' evals=' + (($script:T9183Evals.ToArray()) -join ','))
Assert-T9183 -Condition ($script:T9183Bring -eq 0) -Message 'a healthy visible tab is not stolen to the front'

$YakuT9183Text = [IO.File]::ReadAllText($YakuT9183ClientPath, [Text.Encoding]::UTF8)
Write-Host ('       [diag] client chars=' + $YakuT9183Text.Length)
Assert-T9183 -Condition ($YakuT9183Text.Length -gt 1000) -Message 'CopilotClient.ps1 was read'
Assert-T9183 -Condition ($YakuT9183Text.IndexOf("Expression 'document.hidden'") -ge 0) -Message 'the wording is chosen from an observation, not from a guess'
Assert-T9183 -Condition ($YakuT9183Text.IndexOf('Restore-YakuCopilotTabVisibility') -ge 0) -Message 'the restore helper is wired into the client'

# The initial warmup worker used to call Get-YakuCopilotPage and immediately
# inspect the DOM. That left a hidden/frozen first tab waiting forever until a
# user opened another tab. Keep visibility repair on the first poll and the
# fresh-chat retry; the resident readiness monitor must not steal the tab while
# the user is working in it.
$YakuT9183WarmupText = [IO.File]::ReadAllText($YakuT9183WarmupPath, [Text.Encoding]::UTF8)
Assert-T9183 -Condition ($YakuT9183WarmupText -match '(?s)\$page\s*=\s*Get-YakuCopilotPage\s+-Port\s+\$port\s+-Url\s+\$copilotUrl\s*\r?\n\s*\$page\s*=\s*Restore-YakuCopilotTabVisibility') `
    -Message 'initial warmup restores the first Copilot tab before state inspection'
Assert-T9183 -Condition ($YakuT9183WarmupText -match '(?s)\$currentPage\s*=\s*Get-YakuCopilotPage\s+-Port\s+\$Port\s+-Url\s+\$Url\s*\r?\n\s*\$currentPage\s*=\s*Restore-YakuCopilotTabVisibility') `
    -Message 'fresh-chat retry restores a reacquired Copilot tab before evaluation'
$YakuT9183WatchMatch = [regex]::Match($YakuT9183WarmupText, '(?s)function Watch-YakuCopilotReadiness\b.*?(?=\r?\ntry\s*\{)')
Assert-T9183 -Condition ($YakuT9183WatchMatch.Success -and $YakuT9183WatchMatch.Value.IndexOf('Restore-YakuCopilotTabVisibility') -lt 0) `
    -Message 'resident readiness monitoring does not restore or steal the active Copilot tab'

Write-Host ''
if ($script:T9183Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9183CopilotTabVisibility'
    exit 0
}
Write-Host ("FAIL " + $script:T9183Failures.Count + ' assertion(s)')
foreach ($YakuT9183F in $script:T9183Failures) { Write-Host ('  - ' + $YakuT9183F) }
exit 1