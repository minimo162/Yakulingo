<#
.SYNOPSIS
  V91.61: CAT の段取り（取り込む→用語集で置換→残りを訳す→出力）の回帰テスト。

.DESCRIPTION
  ファイル翻訳は廃止し CAT へ統合する（利用者の判断 2026-08-06）。
  やることはファイル翻訳とほぼ同じで、違うのは1つの塊にせず、
  押した分だけ進み、左右に並べて見えるようにする点だけである。

  Copilot への往復は行わない。段取りと、機械が人の直しを踏まないことを
  確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CatProject.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','FileTranslation.ps1','CellSegments.ps1','CatProject.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

if (-not (Test-YakuExcelAvailable)) {
    Write-Host 'Excel が無いため飛ばす' -ForegroundColor Yellow
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-cat-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$srcPath = Join-Path $tmp 'in.xlsx'
$outPath = Join-Path $tmp 'out.xlsx'

# 用語集に載っているラベルと、載っていない文章を混ぜる。
$glossaryFirst = @(Get-YakuGlossaryEntries -Root $root | Select-Object -First 1)
$knownSource = [string]$glossaryFirst[0].Source
$knownTarget = [string]$glossaryFirst[0].Target

$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false; $xl.DisplayAlerts = $false
try {
    $wb = $xl.Workbooks.Add()
    $ws = $wb.Worksheets.Item(1); $ws.Name = '説明'
    # 1〜2行目: 3セルに割られていない文章（用語集には無い）
    $ws.Cells.Item(1,1).Value2 = '当第1四半期は、生産体制の見直しにより'
    $ws.Cells.Item(2,1).Value2 = '固定費を圧縮しました。'
    # 4行目: 用語集に載っているラベル＋数値（表の行）
    $ws.Cells.Item(4,1).Value2 = $knownSource
    $ws.Cells.Item(4,2).Value2 = 1234
    $wb.SaveAs($srcPath, 51); $wb.Close($false)
} finally {
    try { $xl.Quit() } catch {}
    Release-YakuComObject $xl
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

$settings = Read-YakuSettings -Root $root

# ---------------------------------------------------------------- 取り込む
Write-Host '取り込んでセグメントに分ける'
$project = New-YakuCatProject -Root $root -Path $srcPath -Settings $settings -Direction 'to_en'
$segs = @($project.Segments)
Chk ($segs.Count -eq 2) ('2セグメント（文章1＋ラベル1）: ' + $segs.Count)
Chk (@($segs | Where-Object { [bool]$_.Joined }).Count -eq 1) '割られた文章は繋がる'
Chk (@($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count -eq 2) '取り込んだ時点では訳は付いていない'
$summary = Get-YakuCatProjectSummary -Project $project
Chk ([int]$summary.Total -eq 2 -and [int]$summary.Translated -eq 0) '要約が原文だけの状態を表す'
$proseIdx = 0
for ($i = 0; $i -lt $segs.Count; $i++) { if ([bool]$segs[$i].Joined) { $proseIdx = $i } }
Chk ((Get-YakuCatProject -Id ([string]$project.Id)) -ne $null) 'Id で取り出せる'

# ---------------------------------------------------------------- 用語集で置換
Write-Host '用語集で機械的に置換する'
$g = Invoke-YakuCatGlossaryPass -Root $root -Project $project -Settings $settings
Chk ([int]$g.Applied -eq 1) ('用語集で1件埋まる: ' + $g.Applied)
$labelSeg = @($segs | Where-Object { [string]$_.Text -eq $knownSource })
Chk ($labelSeg.Count -eq 1 -and [string]$labelSeg[0].Translation -eq $knownTarget) ('ラベルが置換される: ' + $knownSource + ' -> ' + [string]$labelSeg[0].Translation)
Chk ([string]$labelSeg[0].Origin -eq 'glossary') 'どこから来た訳文か分かる'
# 文中の語は置き換えない。活用と一致が壊れるため（実機検証結果 §3-2）。
$proseSeg = @($segs | Where-Object { [bool]$_.Joined })
Chk ([string]::IsNullOrWhiteSpace([string]$proseSeg[0].Translation)) '完全一致しない文章は空のまま'
Chk ([int]$g.Remaining -eq 1) '残りが1件と分かる'

# ---------------------------------------------------------------- 画面へ渡す形
Write-Host '画面へ渡す形'
$json = ConvertTo-YakuCatProjectJson -Project $project
$view = $json | ConvertFrom-Json
Chk ([string]$view.id -eq [string]$project.Id) 'Id が入る'
Chk ([int]$view.total -eq 2 -and [int]$view.translated -eq 1 -and [int]$view.remaining -eq 1) '件数が入る'
Chk (@($view.segments).Count -eq 2) 'セグメントが並ぶ'
Chk (@($view.segments | Where-Object { [bool]$_.joined }).Count -eq 1) '結合したものが分かる'
Chk (@($view.segments | Where-Object { [int]$_.cells -gt 1 }).Count -eq 1) '何セルを繋いだか分かる'
# 元の塊やセルの座標は画面に用が無いので載せない。
Chk (-not ($view.segments[0].PSObject.Properties.Name -contains 'BlockIds')) '内部の識別子は画面へ出さない'

# ---------------------------------------------------------------- 繋ぎ直し
# 自動で完璧にセグメントを分けるのは無理なので（利用者の指摘 2026-08-06）、
# 外れたときに人が直せることが前提になっている。
Write-Host '手で繋ぎ直す'
$before = @($project.Segments).Count
$null = Split-YakuCatSegment -Project $project -Index $proseIdx
$segs = @($project.Segments)
Chk ($segs.Count -eq ($before + 1)) ('解除すると元のセル1つずつに戻る: ' + $before + ' -> ' + $segs.Count)
Chk (@($segs | Where-Object { [bool]$_.Joined }).Count -eq 0) '繋がったものが無くなる'
Chk ([string]$segs[0].Text -eq '当第1四半期は、生産体制の見直しにより') '1つ目は元のセルの文字'
Chk ([string]$segs[1].Text -eq '固定費を圧縮しました。') '2つ目も元のセルの文字'
# 訳文は消す。繋ぎ方が変われば原文が別の文になるので、前の訳は断片の訳になる。
# 残すと「一見良さげだが中身が合っていない」状態を自分で作ることになる。
Chk ([string]::IsNullOrWhiteSpace([string]$segs[0].Translation)) '解除すると訳文は消える'

$null = Merge-YakuCatSegments -Project $project -Index 0
$segs = @($project.Segments)
Chk ($segs.Count -eq $before) ('隣と結合すると元の数へ戻る: ' + $segs.Count)
Chk ([bool]$segs[0].Joined) '結合した印が付く'
Chk ([string]$segs[0].Text -eq '当第1四半期は、生産体制の見直しにより固定費を圧縮しました。') '本文が繋がる'
Chk (@($segs[0].Cells).Count -eq 2) '元のセルを2つとも覚えている'
Chk ([string]::IsNullOrWhiteSpace([string]$segs[0].Translation)) '結合しても訳文は消える'

# 繋げないものは繋げない。
$labelIdx = -1
for ($i = 0; $i -lt $segs.Count; $i++) { if ([string]$segs[$i].Text -eq $knownSource) { $labelIdx = $i } }
$threw = $false
try { $null = Merge-YakuCatSegments -Project $project -Index ($segs.Count - 1) } catch { $threw = $true }
Chk $threw '最後のセグメントは次が無いので結合できない'
$threw = $false
try { $null = Split-YakuCatSegment -Project $project -Index $labelIdx } catch { $threw = $true }
Chk $threw '繋がっていないセグメントは解除できない'
# 画面へ「繋げるか」を出す。押せない操作をボタンで見せない。
$view2 = (ConvertTo-YakuCatProjectJson -Project $project) | ConvertFrom-Json
Chk ([bool]$view2.segments[0].can_split) '結合済みは解除できると出る'
Chk (-not [bool]$view2.segments[$view2.segments.Count - 1].can_merge) '最後のセグメントは結合できないと出る'

# ---------------------------------------------------------------- 人の直し
Write-Host '人が直したものを機械が踏まない'
$null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'Hand written.'
Chk ([string]$segs[0].Origin -eq 'manual') '手直しの印が付く'
$g2 = Invoke-YakuCatGlossaryPass -Root $root -Project $project -Settings $settings
Chk ([int]$g2.Applied -eq 0) 'もう一度置換しても、埋まっているものは触らない'
Chk ([string]$segs[0].Translation -eq 'Hand written.') '手直しが残る'

# ---------------------------------------------------------------- 出力
Write-Host '元のコピーへ出力する'
# 文章側にも訳を入れてから出す。
$proseIndex = 0
for ($i = 0; $i -lt $segs.Count; $i++) { if ([bool]$segs[$i].Joined) { $proseIndex = $i } }
$null = Set-YakuCatSegmentTranslation -Project $project -Index $proseIndex -Text 'In the first quarter, fixed costs were reduced through a review of production.'
$exported = Export-YakuCatProject -Project $project -OutputPath $outPath -Settings $settings
Chk (Test-Path -LiteralPath $outPath) '出力ファイルができる'
Chk ([string]$exported.OutputName -eq 'out.xlsx') '出力名が返る'

$xl2 = New-Object -ComObject Excel.Application
$xl2.Visible = $false; $xl2.DisplayAlerts = $false
$read = @{}
try {
    $wb2 = $xl2.Workbooks.Open($outPath, 0, $true)
    $ws2 = $wb2.Worksheets.Item(1)
    foreach ($r in @(1,2,4)) { $read["A$r"] = [string]$ws2.Cells.Item($r,1).Value2 }
    $read['B4'] = [string]$ws2.Cells.Item(4,2).Value2
    $wb2.Close($false)
} finally {
    try { $xl2.Quit() } catch {}
    Release-YakuComObject $xl2
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}
$rejoined = ((@($read['A1'], $read['A2']) -join ' ') -replace '\s+', ' ').Trim()
Chk ($rejoined -eq 'In the first quarter, fixed costs were reduced through a review of production.') '繋いだ訳文が元の2セルへ戻る'
Chk ([string]$read['A4'] -eq $knownTarget) '用語集で置換したラベルが出力される'
Chk ([string]$read['B4'] -eq '1234') '数値セルは触らない'

# ---------------------------------------------------------------- 貼り付けから開く
# 簡易翻訳を使っている人にも CAT のほうが便利だが、急に画面が変わると
# 覚え直しの負担を負わせる（利用者の懸念 2026-08-06）。入力の作法を揃える。
Write-Host '貼り付けたテキストから開く'
$pasted = @"
当第1四半期は、生産体制の見直しにより固定費を圧縮しました。為替の影響は限定的でした。
今後も市場環境を注視してまいります。
"@
$tp = New-YakuCatTextProject -Root $root -Text $pasted -Settings $settings -Direction 'to_en'
$tsegs = @($tp.Segments)
Chk ($tsegs.Count -eq 3) ('行と句点で分かれる: ' + $tsegs.Count)
Chk ([string]$tsegs[0].Text -eq '当第1四半期は、生産体制の見直しにより固定費を圧縮しました。') '1文目'
Chk ([string]$tsegs[1].Text -eq '為替の影響は限定的でした。') '同じ行の2文目も分かれる'
Chk ([string]$tsegs[2].Text -eq '今後も市場環境を注視してまいります。') '次の行'
Chk ([string]$tsegs[0].Kind -eq 'text') 'セルではなくテキストとして扱う'
$tview = (ConvertTo-YakuCatProjectJson -Project $tp) | ConvertFrom-Json
Chk ([string]$tview.source -eq 'text') '画面が出口を切り替えられる'

# 繋ぎ直しはテキストでもできる。分け方が外れても直せることが前提。
$null = Merge-YakuCatSegments -Project $tp -Index 0
$tsegs = @($tp.Segments)
Chk ($tsegs.Count -eq 2) ('隣と結合できる: ' + $tsegs.Count)
Chk ([string]$tsegs[0].Text -eq '当第1四半期は、生産体制の見直しにより固定費を圧縮しました。為替の影響は限定的でした。') '本文が繋がる'
$null = Split-YakuCatSegment -Project $tp -Index 0
$tsegs = @($tp.Segments)
Chk ($tsegs.Count -eq 3) '解除すると元の文へ戻る'
Chk ([string]$tsegs[1].Text -eq '為替の影響は限定的でした。') '元の切れ目で戻る'

# 出口はコピー。書き戻す元のファイルが無い。
$null = Set-YakuCatSegmentTranslation -Project $tp -Index 0 -Text 'Fixed costs were reduced.'
$null = Set-YakuCatSegmentTranslation -Project $tp -Index 1 -Text 'FX impact was limited.'
$texported = Export-YakuCatProject -Project $tp -OutputPath '' -Settings $settings
Chk ([string]::IsNullOrEmpty([string]$texported.OutputPath)) 'ファイルは作らない'
Chk ([string]$texported.Text -match 'Fixed costs were reduced\.') '訳文が繋がって返る'
Chk ([string]$texported.Text -match 'FX impact was limited\.') '2文目も入る'
# 未訳のセグメントは原文のまま残す。抜け落ちると文書として使えない。
Chk ([string]$texported.Text -match '今後も市場環境を注視してまいります。') '未訳は原文のまま残す'
Remove-YakuCatProject -Id ([string]$tp.Id)

# 画面に導線があること。押した先に見慣れた文が並ぶようにする。
$textResult = [pscustomobject]@{
    Direction='to_en'; SourceText='当第1四半期の営業利益は増益となりました。'; InputLength=20; Warnings=@()
    Options=@([pscustomobject]@{ Style='full'; Label='FULL'; Translation='Q1 operating profit increased.'; MaskedTranslation='Q1 operating profit increased.' })
}
$handoff = Convert-YakuTextResultToHtml -Result $textResult -IncludeStatusOob:$false
Chk ($handoff -match 'data-yaku-to-cat') '簡易翻訳の結果から CAT へ渡す導線がある'
$appJsText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\app.js'))
Chk ($appJsText.Contains("name=`"cat_source`"")) '取り込み元を切り替えられる'
$indexText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'index.html'))
Chk ($indexText -match 'id="cat-text"') 'CAT に貼り付け欄がある'

# ---------------------------------------------------------------- 一覧の作法
# 市販の CAT エディタが備えていて、こちらに無かったもの（2026-08-06 の比較）。
# 一日中この一覧の中で作業する道具なので、進み具合・現在位置・キーボードは
# 「あると便利」ではなく前提に近い。
Write-Host '一覧の作法（市販ツールに合わせたもの）'
$cssText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\styles.css'))
Chk ($cssText -match 'data-yaku-cat-state="untranslated"') '未訳の行を色で示す'
Chk ($cssText -match 'data-yaku-cat-state="manual"') '手直しの行を色で示す'
Chk ($cssText -match '\.cat-grid tbody tr\.is-active') 'いま見ている行を強調する'
Chk ($cssText -match '\.cat-ops \{[^}]*visibility: hidden') '繋ぎ直しのボタンは常には出さない（全行に並ぶと目が滑る）'
Chk ($appJsText.Contains("addEventListener('focusin'")) '現在行を追う'
Chk ($appJsText.Contains("event.key !== 'Enter'")) 'Ctrl+Enter で次へ進める'
Chk ($appJsText.Contains('yakuCatUpdateProgress')) '進み具合を出す'
Chk ($indexText -match 'id="cat-progress-bar"') '進捗バーがある'
# 触っただけのセグメントを「手直し」にしない。以前は離れるたびに保存して
# いたので、一覧を上から見ていくだけで全部が手直し扱いになっていた。
Chk ($appJsText.Contains("data-yaku-original")) '変更が無ければ保存しない（触っただけで手直しにしない）'

# ---------------------------------------------------------------- 候補ペイン
# CAT エディタの中核にあたる部分（利用者の指摘 2026-08-06）。
# いま出せるのは用語集だけ。翻訳メモリはまだ無く、コーパスの文例は英語でしか
# 引けないため行ごとには出せない。
Write-Host '候補ペイン'
$cp = New-YakuCatTextProject -Root $root -Text '上期営利' -Settings $settings -Direction 'to_en'
$cands = @(Get-YakuCatSegmentCandidates -Root $root -Project $cp -Index 0)
Chk ($cands.Count -gt 0) ('候補が出る: ' + $cands.Count)
Chk ([bool]$cands[0].Exact) '完全一致が先頭に来る'
Chk ([string]$cands[0].Target -eq '1H OP') ('上期営利 -> 1H OP: ' + [string]$cands[0].Target)
Remove-YakuCatProject -Id ([string]$cp.Id)

# 文中の一致も出す。表のラベルは完全一致で機械置換できるが、文中の語は
# 置換しない（活用と一致が壊れるため）。置換しないからこそ目に入れる。
$cp2 = New-YakuCatTextProject -Root $root -Text '固定費を圧縮した一方、為替の影響を受けました。' -Settings $settings -Direction 'to_en'
$c2 = @(Get-YakuCatSegmentCandidates -Root $root -Project $cp2 -Index 0)
Chk (@($c2 | Where-Object { [string]$_.Source -eq '固定費' }).Count -eq 1) '文中の語を拾う'
Chk (@($c2 | Where-Object { [bool]$_.Exact }).Count -eq 0) '文には完全一致が無い'
Remove-YakuCatProject -Id ([string]$cp2.Id)

# 短い漢字語が前の漢字と続いて別の語になっている場合は拾わない。
# 「四半期」の中の「半期」が Half-year として出ると、かえって誤らせる。
$cp3 = New-YakuCatTextProject -Root $root -Text '当第1四半期の実績です。' -Settings $settings -Direction 'to_en'
$c3 = @(Get-YakuCatSegmentCandidates -Root $root -Project $cp3 -Index 0)
Chk (@($c3 | Where-Object { [string]$_.Source -eq '半期' }).Count -eq 0) '四半期 の中の 半期 を拾わない'
Remove-YakuCatProject -Id ([string]$cp3.Id)

Chk ($appJsText.Contains('yakuCatLoadCandidates')) '行を移るたびに候補を出す'
Chk ($appJsText.Contains('data-yaku-cat-insert')) '候補を訳文へ差し込める'
Chk ($indexText -match 'id="cat-candidates"') '候補ペインがある'

# ---------------------------------------------------------------- 片付け
Remove-YakuCatProject -Id ([string]$project.Id)
Chk ((Get-YakuCatProject -Id ([string]$project.Id)) -eq $null) '終わったプロジェクトは捨てられる'

try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}

if ($script:fail -gt 0) {
    Write-Host "V91.61 CAT project regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 CAT project regression passed.' -ForegroundColor Green
