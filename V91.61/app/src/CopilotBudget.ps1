<#
  Copilot を何回呼んだかを数える層。

  なぜ要るか。Copilot は連続120回ほどで応答しなくなり、時間を置くまで
  戻らない。この性質は 2026-08-07 のアライメント作業で分かっていたのに、
  **アプリは呼び出し回数を1度も数えていなかった**（独立評価の指摘 2026-08-08）。

  数えていないと2つ困る。

    1. 制限に当たったのか、こちらの不具合かを切り分けられない。実際、
       2026-08-08 に「Copilot が劣化した」と誤った説明を立てている
    2. 制限に当たった失敗をリトライで追い打ちする。1回の失敗が3回の
       消費になり、残りをさらに削る

  記録するのは時刻だけである。プロンプトも訳文も書かない。ここは
  「他人の履歴が見えてはいけない」（利用者の方針）に触れる場所なので、
  中身を持たない形にしておく。ファイルは利用者ごとのデータ領域にある。
#>

# 制限に当たるあたりの実測値。ここを超えたら警告を出す（止めはしない。
# 正確な閾値は Microsoft 側の都合で変わるので、こちらで決め打ちにしない）。
$script:YakuCopilotCallWarnThreshold = 100
# 数える窓。制限は時間を置くと戻るので、古い記録は数に入れない。
$script:YakuCopilotCallWindowHours = 3

function Get-YakuCopilotCallLogPath {
    $dir = Get-YakuSubDir 'logs'
    return (Join-Path $dir 'copilot-calls.log')
}

function Add-YakuCopilotCall {
    <#
      1回分を記録し、窓の中の件数を返す。

      追記だけで済ませる。呼ぶたびに読み書きするので、重い処理は置かない。
      失敗しても投げない。数えられないことを理由に翻訳を止めない。
    #>
    param([AllowNull()][datetime]$Now)
    $now = if ($null -eq $Now -or $Now -eq [datetime]::MinValue) { Get-Date } else { $Now }
    try {
        $path = Get-YakuCopilotCallLogPath
        # 時刻だけ。ASCII の固定長で書く。CP932 と UTF-8 の取り違えが
        # 起きる余地を残さない（2026-08-07 に3時間失った失敗）。
        [IO.File]::AppendAllText($path, $now.ToString('yyyy-MM-ddTHH:mm:ss') + "`n", [Text.UTF8Encoding]::new($false))
        return (Get-YakuCopilotCallCount -Now $now)
    } catch {
        return 0
    }
}

function Get-YakuCopilotCallCount {
    <#
      窓の中で何回呼んだかを返す。ついでに古い行を落とす。
      落としておかないとファイルが伸び続け、毎回の読み込みが重くなる。
    #>
    param(
        [AllowNull()][datetime]$Now,
        [int]$WindowHours = 0
    )
    $now = if ($null -eq $Now -or $Now -eq [datetime]::MinValue) { Get-Date } else { $Now }
    $hours = if ($WindowHours -gt 0) { $WindowHours } else { $script:YakuCopilotCallWindowHours }
    $since = $now.AddHours(-1 * $hours)
    try {
        $path = Get-YakuCopilotCallLogPath
        if (-not [IO.File]::Exists($path)) { return 0 }
        $lines = @([IO.File]::ReadAllLines($path, [Text.UTF8Encoding]::new($false)))
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $t = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $dt = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($t, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
            if ($dt -lt $since) { continue }
            [void]$kept.Add($t)
        }
        # 落とせる行があるときだけ書き直す。毎回書くと追記の意味が無くなる。
        if ($kept.Count -lt $lines.Count) {
            try { [IO.File]::WriteAllLines($path, @($kept.ToArray()), [Text.UTF8Encoding]::new($false)) } catch {}
        }
        return [int]$kept.Count
    } catch {
        return 0
    }
}

function Test-YakuCopilotLimitError {
    <#
      その失敗が「使いすぎ」に見えるかを判定する。

      見えるなら、もう一度頼んでも同じである。リトライは残りを削るだけで
      害しかない。Copilot 自身のエラー（COPILOT_SERVICE_ERROR）は、
      2026-08-07 の実測では制限に当たったときにまさにこの形で出た。

      ここは「止める判断」なので、迷ったら止めない側に倒す。取りこぼして
      1回余分に呼ぶほうが、直せる失敗を止めてしまうより軽い。
    #>
    param([AllowNull()][string]$Message)
    $m = [string]$Message
    if ([string]::IsNullOrWhiteSpace($m)) { return $false }
    if ($m -match 'COPILOT_SERVICE_ERROR') { return $true }
    if ($m -match '(?i)rate limit|too many requests|quota') { return $true }
    return $false
}

function Write-YakuCopilotCallLog {
    <#
      呼び出しごとに1行残す。件数が見えないと、制限に当たったときに
      「アプリの不具合では」と調べ始めることになる。
    #>
    param([int]$Count)
    if ($Count -le 0) { return }
    $level = if ($Count -ge $script:YakuCopilotCallWarnThreshold) { 'WARN' } else { 'INFO' }
    $note = if ($Count -ge $script:YakuCopilotCallWarnThreshold) { ' note=near-usage-limit' } else { '' }
    try { Write-YakuLog ("Copilot call count. windowHours=$($script:YakuCopilotCallWindowHours) count=$Count" + $note) $level } catch {}
}
