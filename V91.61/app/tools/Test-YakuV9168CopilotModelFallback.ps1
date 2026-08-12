<#
.SYNOPSIS
  モデルの切替で、1つ目が外れても残りの候補を試すことを固定する。

.DESCRIPTION
  2026-08-13、設定は「GPT 5.6 Think deeper, Opus, Think Deeper」なのに『自動』のまま
  訳していた。実機で当てた結果（Copilot の実画面・子メニューを塞いだ状態）:

    直す前  reason=model_not_in_menu  9205ms  試した候補 1/3  → 自動のまま
    直した後 reason=selected           3930ms  試した候補 3/3  → Think Deeper

  外れていたのは「探し方」ではない。GPT の子メニューが開かなかったとき、
  (1) 押してもいない親（GPT）の名前で 5 秒待ち、(2) メニューを開き直す待ちが
  300ms 決め打ちだったため空振りし、(3) そこで break して残りの候補を
  一度も試さなかった。「Think Deeper」は上の階層にあり、試していれば選べていた。

  記録では 08-06 以降 model_not_in_menu が 26 回、menu_not_found が 9 回あり、
  今回だけの不具合ではない（成功 1667 回に対して 0〜5%/日）。

  ここは字面で固定する。JS の DOM 操作そのものを試すには偽の DOM が要るが、
  それは「Copilot ではなく自分で書いた偽物を試す」ことになるので採らない。
  実機で当てた結果が根拠であり、ここで止めたいのは決定の取り消しである。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuModel {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

$source = Get-Content -LiteralPath (Join-Path $root 'src\CopilotClient.ps1') -Raw -Encoding UTF8

# 見るのは Set-YakuCopilotModel の中だけ。ほかの場所の同名の語に釣られない。
# 終わりは「次の function が行頭に来るところ」。中身の JS にも行頭の } があるので、
# 最初の } で切ると本文を取りこぼす（最初にそう書いて、実際に取りこぼした）。
$fn = [regex]::Match($source, '(?sm)^function Set-YakuCopilotModel\b.*?(?=^function |\z)')
if (-not $fn.Success) { Write-Host 'Set-YakuCopilotModel が見つかりません' -ForegroundColor Red; exit 1 }
$js = $fn.Value
if ($js.Length -lt 4000) { Write-Host ('取り出せた本文が短すぎます: ' + $js.Length + '文字') -ForegroundColor Red; exit 1 }

Write-Host 'Copilot model switch keeps trying the remaining candidates' -ForegroundColor Cyan

# 1. 子メニューが開かなかったら、その候補は即座に切り上げる。
#    親の名前で確認を待つと 5 秒を捨てることになる。
Check-YakuModel ($js -match "reason:'submenu_not_opened'") '子メニューが開かないことを結果として返す'
Check-YakuModel ($js -match "(?s)\}\s*else\s*\{[^}]*submenu_not_opened") '開かなかったときは確認へ進まず抜ける'

# 2. 開き直しは「開くまで待つ」。300ms 決め打ちに戻さない。
Check-YakuModel ($js -notmatch 'fireClick\(switcher\);\s*await sleep\(300\);') '開き直しが300ms決め打ちではない'
Check-YakuModel ($js -match '(?s)fireClick\(switcher\);\s*items = \[\];\s*for \(let i = 0; i < \d+; i\+\+\) \{\s*items = collectItems\(\);') '開き直しはメニューが出るまで繰り返す'

# 3. 持ち時間切れで例外を投げない。投げると menuItems と skipped が消え、
#    あとから原因を追えなくなる（今回それらが残っていたから原因が分かった）。
Check-YakuModel ($js -notmatch 'MODEL_SELECTION_DEADLINE') '持ち時間切れを例外にしない'
Check-YakuModel ($js -match 'outOfBudget') '持ち時間は真偽値で見る'
Check-YakuModel ($js -match "reason:'deadline'") '時間切れも結果として返す'

# 4. 候補の取りこぼしを防ぐ土台。上の階層の項目と子メニューの親を、
#    どちらも引き当てられること（GPT 系は子メニューの親へ寄せる）。
Check-YakuModel ($js -match 'const findHit' -and $js -match 'isGptTrigger') '上の階層と子メニューの両方から探す'
Check-YakuModel ($js -match 'gptSubMenuModelTrigger') 'GPT の親項目を testId で見分ける'

# 5. 診断が残ること。これが無いと、次に外れたときまた憶測になる。
Check-YakuModel ($js -match 'menuItems' -and $js -match 'skipped') 'メニューの中身と外れた理由を返す'
Check-YakuModel ($js -match 'confirmSamples') '切替ボタンの字の移り変わりを残す'

if ($script:failed -gt 0) { Write-Host ('Copilot model fallback tests failed: ' + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Copilot model fallback tests passed.' -ForegroundColor Green
