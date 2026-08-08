<#
.SYNOPSIS
  V91.61: 翻訳メモリの回帰テスト。

.DESCRIPTION
  候補ペインの3本柱の最後の1本。利用者が確定した訳を貯め、次に同じ文が
  来たら差し込めるようにする。市販ツールの Ctrl+Enter と同じ作法で、
  確定＝記憶にする。

  一番効くのはこれである。公表訳から取った対訳は「読ませる訳」で意訳が
  多く、そのままは使いにくい。翻訳メモリは自分の文体で、自分が正しいと
  判断したものだけが入る。

  ここで見るのは4つ。
   - 確定したものが貯まること
   - 同じ原文を訳し直したら、あとの訳が優先されること
   - 完全一致が最優先で出ること
   - 壊れた行があっても残りが読めること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161TranslationMemory.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'TranslationMemory.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-tm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$tm = Join-Path $tmp 'tm-to_en.jsonl'
try {
    Write-Host '貯める' -ForegroundColor Cyan
    $r = Add-YakuTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm
    Chk ([bool]$r.Added -and $r.Reason -eq 'new') '確定した訳を貯める'
    $r = Add-YakuTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'same') '同じ内容は二度貯めない'
    $r = Add-YakuTranslationMemoryEntry -Source '' -Target 'x' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'empty') '原文が空なら貯めない'
    $r = Add-YakuTranslationMemoryEntry -Source 'x' -Target '  ' -Path $tm
    Chk (-not [bool]$r.Added) '訳文が空白だけなら貯めない'

    Write-Host '訳し直し' -ForegroundColor Cyan
    $r = Add-YakuTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will promote electrification.' -Path $tm
    Chk ([bool]$r.Added -and $r.Reason -eq 'updated') '訳し直しは上書きとして貯まる'
    $h = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk ($h.Count -eq 1) '同じ原文の候補は1件にまとまる'
    Chk ($h[0].Target -eq 'We will promote electrification.') 'あとから確定した訳が出る'

    Write-Host '引く' -ForegroundColor Cyan
    Chk ([bool]$h[0].Exact -and [Math]::Abs([double]$h[0].Ratio - 1.0) -lt 0.001) '完全一致は一致率1.0'
    $h = @(Find-YakuTranslationMemory -Text '当社は 電動化を進めます 。' -Path $tm)
    Chk ($h.Count -eq 1 -and [bool]$h[0].Exact) '空白の違いは同じ文とみなす'
    $h = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。なお詳細は後述します。' -Path $tm)
    Chk ($h.Count -eq 1 -and -not [bool]$h[0].Exact -and [double]$h[0].Ratio -lt 1.0) '含む原文には部分一致で出る'
    Chk (@(Find-YakuTranslationMemory -Text '短い' -Path $tm).Count -eq 0) '短すぎる原文では引かない'
    Chk (@(Find-YakuTranslationMemory -Text 'まったく関係のない文章です。' -Path $tm).Count -eq 0) '当たらなければ空'
    Chk (@(Find-YakuTranslationMemory -Text 'x' -Path (Join-Path $tmp 'no-such.jsonl')).Count -eq 0) 'メモリが無くても落ちない'

    Write-Host '完全一致を先に出す' -ForegroundColor Cyan
    # 3文字以下は最小長に届かず引かない（語は用語集の役目）。
    # ここは文として成り立つ長さで試す。
    $null = Add-YakuTranslationMemoryEntry -Source '電動化を進めます。' -Target 'We advance electrification.' -Path $tm
    $h = @(Find-YakuTranslationMemory -Text '電動化を進めます。' -Path $tm)
    Chk ($h.Count -ge 1 -and [bool]$h[0].Exact -and $h[0].Target -eq 'We advance electrification.') '完全一致が先頭に来る'
    Chk (@(Find-YakuTranslationMemory -Text '電動化' -Path $tm).Count -eq 0) '語は翻訳メモリでは引かない（用語集の役目）'

    Write-Host '壊れた行' -ForegroundColor Cyan
    [IO.File]::AppendAllLines($tm, [string[]]@('{壊れた行', ''), [Text.UTF8Encoding]::new($false))
    Chk ((Read-YakuTranslationMemory -Path $tm).Count -eq 2) '壊れた行を捨てて残りを読む'

    Write-Host '確定と結びついているか' -ForegroundColor Cyan
    $cat = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CatProject.ps1') -Raw -Encoding UTF8
    Chk ($cat -match 'Add-YakuTranslationMemoryEntry') '訳を確定すると翻訳メモリへ貯まる'
    Chk ($cat -match 'Find-YakuTranslationMemory') '候補ペインが翻訳メモリを引く'
    Chk ($cat -match "Kind\s*=\s*'memory'") '翻訳メモリの候補に印を付ける'
    Chk ($cat -match 'Weight\s*=\s*30000') '翻訳メモリを他の候補より先に出す'

    Write-Host '確定の状態' -ForegroundColor Cyan
    foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'PromptBuilder.ps1', 'CellSegments.ps1', 'Corpus.ps1', 'CorpusPairs.ps1', 'CatProject.ps1')) {
        . (Join-Path (Join-Path $root 'src') $mod)
    }
    $proj = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "当社は電動化を進めます。" -Translation "We will advance electrification."
    $sum = Get-YakuCatProjectSummary -Project $proj
    Chk ([int]$sum.Translated -eq 1 -and [int]$sum.Confirmed -eq 0) '訳が入っていても、見るまでは確定にしない'
    Chk ([string]@($proj.Segments)[0].Origin -eq 'copilot') '簡易翻訳から来た訳は機械の訳として印を付ける'

    $null = Set-YakuCatSegmentConfirmed -Project $proj -Index 0
    $sum = Get-YakuCatProjectSummary -Project $proj
    Chk ([int]$sum.Confirmed -eq 1 -and [int]$sum.Unconfirmed -eq 0) '直さずに確定できる'

    $empty = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' -Text "訳の無い文です。"
    $threw = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $empty -Index 0 } catch { $threw = $true }
    Chk $threw '訳が空の行は確定できない'

    # 行数が合わない訳文は割り当てない。ずれた対応を見せるより空欄がよい。
    $mismatch = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "一つ目の文です。二つ目の文です。" -Translation "Only one sentence."
    Chk ([string]@($mismatch.Segments)[0].Translation -eq '') '行数が合わない訳文は割り当てない'

    Write-Host '作業内容の保存と復元' -ForegroundColor Cyan
    Chk (Save-YakuCatProject -Project $proj) 'ディスクへ保存できる'
    $file = Join-Path (Get-YakuCatProjectStoreDir) ([string]$proj.Id + '.json')
    Chk (Test-Path -LiteralPath $file -PathType Leaf) '保存先にファイルができる'

    # メモリから消したうえで復元する。再起動を模している。
    Remove-YakuCatProject -Id ([string]$proj.Id)
    Chk ($null -eq (Get-YakuCatProject -Id ([string]$proj.Id))) 'メモリからは消えている'
    $back = Restore-YakuCatProject -Id ([string]$proj.Id)
    Chk ($null -ne $back) '保存したものを戻せる'
    Chk (@($back.Segments).Count -eq @($proj.Segments).Count) '行数が保たれる'
    Chk ([bool]@($back.Segments)[0].Confirmed) '確定の状態が残る'
    Chk ([string]@($back.Segments)[0].Translation -eq 'We will advance electrification.') '訳文が残る'
    Chk ([string]$back.Direction -eq 'to_en') '翻訳方向が残る'

    $recent = @(Get-YakuCatSavedProjects -Limit 10)
    Chk (@($recent | Where-Object { [string]$_.Id -eq [string]$proj.Id }).Count -eq 1) '前回の続きの一覧に出る'
    $entry = @($recent | Where-Object { [string]$_.Id -eq [string]$proj.Id })[0]
    Chk ([int]$entry.Confirmed -eq 1 -and [int]$entry.Total -eq 1) '一覧に確認済みの数が出る'

    Chk ($null -eq (Restore-YakuCatProject -Id 'no-such-project')) '無いものを戻そうとしても落ちない'
    try { Remove-Item -LiteralPath $file -Force } catch {}
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 translation memory regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 translation memory regression passed.' -ForegroundColor Green
