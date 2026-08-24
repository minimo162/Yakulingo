<#
  Copilot を何回呼んだかを数える層。

  なぜ要るか。Copilot は短時間に集中して送ると弾かれることがある。
  それなのに**アプリは呼び出し回数を1度も数えていなかった**
  （独立評価の指摘 2026-08-08）。

  数えていないと2つ困る。

    1. 弾かれたのか、こちらの不具合かを切り分けられない。実際、
       2026-08-08 に「Copilot が劣化した」と誤った説明を立てている
    2. 弾かれた失敗をリトライで追い打ちする。1回の失敗が3回の送信になる

  ログから数えた事実（2026-08-07 19時〜2026-08-08 19時、送信545回）:

    | 時刻帯   | 送信 | 成功 | 「問題が発生」 |
    | 08-08 05 |  140 |  122 |   0 |
    | 08-08 06 |   21 |    0 |  18 |  ← 全滅
    | 08-08 09 |    7 |    7 |   0 |  ← 回復している
    | 08-08 10 |  111 |   96 |   0 |
    | 08-08 11 |   26 |    0 |  38 |  ← 全滅
    | 08-08 12 |   35 |   30 |   0 |  ← 回復している
    以降 19時まで、毎時20〜35回で7時間連続して全滅なし。

  **最初の失敗は184回目であって、121回目ではない。** 以前「連続120回ほどで
  応答しなくなる」と書いていたが、これは推測で、実データと合っていなかった
  （利用者の指摘 2026-08-08）。

  読めるのは「短時間に集中して送ると弾かれ、間を置けば戻る」までである。
  窓の長さも境目の回数も確かめていない。当たった2点が毎時140回と111回、
  当たらなかった点が毎時20〜35回、というだけである。

  なお利用者の見立てでは、同じ M365 アカウントで別のアプリが同時に画像を
  Copilot へ送っていたことが効いていた可能性がある（画像の送信をやめてからは
  弾かれていない）。**これも確かめていない仮説である。** ただしどちらの筋でも
  「短時間に集中させない」という当面の方針は変わらない。

  記録するのは時刻だけである。プロンプトも訳文も書かない。ここは
  「他人の履歴が見えてはいけない」（利用者の方針）に触れる場所なので、
  中身を持たない形にしておく。ファイルは利用者ごとのデータ領域にある。
#>

# 警告を出す目安。止めはしない。境目は確かめていないので決め打ちにしない。
#
# 実データで全滅した2回は、直前1時間が 140回 と 111回 だった。
# 当たらなかったのは毎時20〜35回である。その間のどこが境目かは分からない。
# 当たった側の下（111）より低く、当たらなかった側の上（35）より高い値として
# 80 を置く。ここを超えたら「送りすぎかもしれない」と記録に残す、それだけ。
$script:YakuCopilotCallWarnThreshold = 80
# 数える窓。上の観測が1時間ごとの集計なので、それに合わせる。
# 窓の長さそのものは確かめていない。
$script:YakuCopilotCallWindowHours = 1
# 画面では直近3時間も示す。送信のたびに1時間より前を捨てると、その値を
# 後から復元できない。警告の集計窓とは分け、軽い時刻行を24時間だけ保持する。
$script:YakuCopilotCallRetentionHours = 24
$script:YakuCopilotBudgetLockTimeoutMilliseconds = 30000

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
    $mutex = $null;$locked = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false,'Local\YakuLingo-CopilotBudget')
        $lockTimeout=[Math]::Max(1,[int]$script:YakuCopilotBudgetLockTimeoutMilliseconds)
        try{$locked=$mutex.WaitOne($lockTimeout)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){
            try{Write-YakuLog "Copilot call count skipped: budget lock timeout. waitedMs=$lockTimeout" 'WARN'}catch{}
            return 0
        }
        $path = Get-YakuCopilotCallLogPath
        # 時刻だけ。ASCII の固定長で書く。CP932 と UTF-8 の取り違えが
        # 起きる余地を残さない（2026-08-07 に3時間失った失敗）。
        [IO.File]::AppendAllText($path, $now.ToString('yyyy-MM-ddTHH:mm:ss') + "`n", [Text.UTF8Encoding]::new($false))
        return (Get-YakuCopilotCallCount -Now $now)
    } catch {
        try{Write-YakuLog ("Copilot call count skipped: budget record failed. reason="+$_.Exception.Message) 'WARN'}catch{}
        return 0
    } finally {
        if($locked){try{$mutex.ReleaseMutex()}catch{}}
        if($mutex){try{$mutex.Dispose()}catch{}}
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
    $retentionHours = [Math]::Max($hours, [int]$script:YakuCopilotCallRetentionHours)
    $keepSince = $now.AddHours(-1 * $retentionHours)
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
            if ($dt -lt $keepSince) { continue }
            [void]$kept.Add($t)
        }
        # 落とせる行があるときだけ書き直す。毎回書くと追記の意味が無くなる。
        if ($kept.Count -lt $lines.Count) {
            try { [IO.File]::WriteAllLines($path, @($kept.ToArray()), [Text.UTF8Encoding]::new($false)) } catch {}
        }
        return [int]@($kept | Where-Object {
                $dt2 = [datetime]::MinValue
                [datetime]::TryParseExact([string]$_, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt2) -and $dt2 -ge $since
            }).Count
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
