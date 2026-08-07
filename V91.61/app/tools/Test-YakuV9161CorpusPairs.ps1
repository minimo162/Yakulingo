<#
.SYNOPSIS
  V91.61: 対訳の対を貯めて日本語でも引ける層の回帰テスト。

.DESCRIPTION
  元々の要求は「日本語で検索して、対応する英文を出したい」だった。
  これまでは英文資料しか検索対象にできず、英語で検索する必要があった。

  ここで見るのは3つ。
   - 同じ対を二度入れないこと（同じ資料を取り込み直しても増えない）
   - 日本語でも英語でも引けること
   - 壊れた行があっても残りが読めること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CorpusPairs.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'CorpusPairs.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-pairs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    # Invoke-YakuDocumentAlignment の出力に合わせた形。
    $pairs = @(
        [pscustomobject]@{ JaText = '当社グループは、2030年までを「電動化の黎明期」と捉えています。'; EnText = 'The Mazda Group views the period until 2030 as the dawn of electrification.'; NumberChecked = $true; NumberAgree = $true }
        [pscustomobject]@{ JaText = '北米では、生産設備等に122億円を投資しました。'; EnText = 'In North America, 12.2 billion yen was invested in production facilities.'; NumberChecked = $true; NumberAgree = $true }
        [pscustomobject]@{ JaText = '当社は電動化を進めます。'; EnText = 'We will advance electrification.'; NumberChecked = $false; NumberAgree = $true }
        [pscustomobject]@{ JaText = ''; EnText = 'orphan line'; NumberChecked = $false; NumberAgree = $true }
    )

    Write-Host '取り込み' -ForegroundColor Cyan
    $r = Add-YakuCorpusPairs -Dir $tmp -Database '有報' -Source '有報/第160期.pdf' -Pairs $pairs -Public
    Chk ($r.Added -eq 3 -and $r.Skipped -eq 1) '片側が空の対は入れない'
    Chk (Test-Path -LiteralPath $r.Path -PathType Leaf) 'JSONL を書き出す'

    $r2 = Add-YakuCorpusPairs -Dir $tmp -Database '有報' -Source '有報/第160期.pdf' -Pairs $pairs -Public
    Chk ($r2.Added -eq 0 -and $r2.Skipped -eq 4) '同じ資料を取り込み直しても増えない'
    Chk (@(Read-YakuCorpusPairs -Dir $tmp -Database '有報').Count -eq 3) '対の数は3のまま'

    Write-Host '検索' -ForegroundColor Cyan
    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化の黎明期')
    Chk ($hits.Count -eq 1 -and $hits[0].En -match 'dawn of electrification') '日本語で引いて英文が出る'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query 'production facilities')
    Chk ($hits.Count -eq 1 -and $hits[0].Ja -match '生産設備') '英語で引いて和文が出る'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化')
    Chk ($hits.Count -eq 2) '複数当たる問い合わせで両方返す'
    Chk ($hits[0].Ja -eq '当社は電動化を進めます。') '短い文に当たったほうを先に出す'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化' -VerifiedOnly)
    Chk ($hits.Count -eq 1 -and $hits[0].Ja -match '黎明期') '裏取りの通った対だけに絞れる'

    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query 'まったく無い語')
    Chk ($hits.Count -eq 0) '当たらなければ空を返す'

    Write-Host '壊れた行' -ForegroundColor Cyan
    $path = Get-YakuCorpusPairsPath -Dir $tmp -Database '有報'
    [IO.File]::AppendAllLines($path, [string[]]@('{壊れた行', ''), [Text.UTF8Encoding]::new($false))
    Chk (@(Read-YakuCorpusPairs -Dir $tmp -Database '有報').Count -eq 3) '壊れた行を捨てて残りを読む'

    Write-Host '資料をまたぐ' -ForegroundColor Cyan
    $null = Add-YakuCorpusPairs -Dir $tmp -Database '決算短信' -Source '短信/FY2025.pdf' -Pairs @(
        [pscustomobject]@{ JaText = '電動化の推進'; EnText = 'Promotion of electrification'; NumberChecked = $false; NumberAgree = $true }
    ) -Public
    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化')
    Chk (@($hits | Select-Object -ExpandProperty Database -Unique).Count -eq 2) '資料をまたいで探す'
    $hits = @(Find-YakuCorpusPairs -Dir $tmp -Query '電動化' -Databases @('決算短信'))
    Chk ($hits.Count -eq 1 -and $hits[0].Database -eq '決算短信') '資料を絞れる'

    Write-Host 'セグメント向けの検索（候補ペイン）' -ForegroundColor Cyan
    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text '当社は電動化を進めます。')
    Chk ($h.Count -ge 1 -and [bool]$h[0].Exact -and $h[0].Target -eq 'We will advance electrification.') '同じ文を訳していれば完全一致で出す'
    Chk ([Math]::Abs([double]$h[0].Ratio - 1.0) -lt 0.001) '完全一致は一致率1.0'

    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text '当社は電動化を進めます。なお詳細は後述します。')
    Chk ($h.Count -ge 1 -and -not [bool]$h[0].Exact -and [double]$h[0].Ratio -lt 1.0) '過去の文を含む原文には部分一致で出す'

    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text '短い')
    Chk ($h.Count -eq 0) '短すぎる原文では引かない'

    $h = @(Find-YakuCorpusPairsForSegment -Dir $tmp -Text 'まったく関係のない文章をここに置きます。')
    Chk ($h.Count -eq 0) '当たらなければ何も出さない'

    $h = @(Find-YakuCorpusPairsForSegment -Dir (Join-Path $tmp 'no-such-dir') -Text '当社は電動化を進めます。')
    Chk ($h.Count -eq 0) 'コーパスが無くても落ちない'

    Write-Host '資料の取り込み' -ForegroundColor Cyan
    . (Join-Path (Join-Path $root 'src') 'AlignMask.ps1')
    . (Join-Path (Join-Path $root 'src') 'Alignment.ps1')
    # Copilot の代役。実機の応答は別に確かめてある。
    function Invoke-YakuCopilotPrompt {
        param([string]$Prompt, $Settings, [string]$AnswerFormat, [switch]$PreserveEndMarker)
        $n = ([regex]::Matches($Prompt, '(?m)^J\d+ ')).Count
        $m = ([regex]::Matches($Prompt, '(?m)^E\d+ ')).Count
        $k = [Math]::Min($n, $m)
        $lines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $k; $i++) { [void]$lines.Add(('[[ID:{0}]] {0}. J{1:d2} | E{1:d2}' -f ($i + 1), $i)) }
        return ($lines -join "`n")
    }
    $jaDoc = "当社は電動化を進めます。`n`n短`n北米に投資しました。`n業績は堅調に推移しました。"
    $enDoc = "We will advance electrification.`n`nx`nWe invested in North America.`nResults remained solid."
    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '統合報告書' -Source '統合報告書/2025.pdf' -JaText $jaDoc -EnText $enDoc -Settings $null -Public
    Chk ($imp.JaLines -eq 3 -and $imp.EnLines -eq 3) '空行と極端に短い行を落とす'
    Chk ($imp.Added -eq 3) '対を貯める'
    Chk ([Math]::Abs([double]$imp.JaCoverage - 1.0) -lt 0.001) '網羅率を返す'

    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '統合報告書' -Source '統合報告書/2025.pdf' -JaText $jaDoc -EnText $enDoc -Settings $null -Public
    Chk ($imp.Added -eq 0 -and $imp.Skipped -eq 3) '同じ資料を取り込み直しても増えない'

    $imp = Import-YakuCorpusPairsFromTexts -Dir $tmp -Database '統合報告書' -Source 'x.pdf' -JaText '' -EnText $enDoc -Settings $null
    Chk ($imp.Added -eq 0 -and $imp.Calls -eq 0) '片側が空なら Copilot を呼ばない'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 corpus pairs regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 corpus pairs regression passed.' -ForegroundColor Green
