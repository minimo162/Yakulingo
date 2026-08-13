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

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}
function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

if (-not (Test-YakuExcelAvailable)) {
    Write-Host 'Excel が無いため飛ばす' -ForegroundColor Yellow
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-cat-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }
$srcPath = Join-Path $tmp 'in.xlsx'
$outPath = Join-Path $tmp 'out.xlsx'

# 配布版に用語は入っていない。利用者が登録する固定訳と文章を混ぜる。
$knownSource = '上期営利'
$knownTarget = '1H OP'

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
Write-Host '利用者が登録した固定訳を明示適用する'
$labelBefore = @($segs | Where-Object { [string]$_.Text -eq $knownSource } | Select-Object -First 1)
$null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$project.Id) -Kind cell_exact -Enforcement advisory `
    -JapanesePreferred $knownSource -EnglishPreferred $knownTarget -Origin 'cat-project-test' `
    -OriginProjectId ([string]$project.Id) -OriginFileName ([string]$project.FileName) `
    -OriginSegmentId ([string]$labelBefore[0].SegmentId) -OriginLocation ([string]$labelBefore[0].Location) `
    -OriginRevision ([int]$project.Revision)
$g = Invoke-YakuCatGlossaryPass -Root $root -Project $project -Settings $settings
Chk ([int]$g.Applied -eq 1) ('登録した固定訳で1件埋まる: ' + $g.Applied)
$labelSeg = @($segs | Where-Object { [string]$_.Text -eq $knownSource })
Chk ($labelSeg.Count -eq 1 -and [string]$labelSeg[0].Translation -eq $knownTarget) ('ラベルが置換される: ' + $knownSource + ' -> ' + [string]$labelSeg[0].Translation)
Chk ([string]$labelSeg[0].Origin -eq 'glossary') '用語集の固定訳から来たと分かる'
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
# 原文「当第1四半期」の 1 を訳文にも残す。first と綴ると数字が消え、
# numeric-value-mismatch が正しく発火して出力が止まる（§8 数値が抜けた訳は欠陥）。
$null = Set-YakuCatSegmentTranslation -Project $project -Index $proseIndex -Text 'In Q1, fixed costs were reduced through a review of the production system.'
# Horizon 1: 手編集や用語置換だけでは出力できない。各訳文を明示確認し、
# 現在の原文 revision に対する機械 QC を通してから出力する。
for ($i = 0; $i -lt @($project.Segments).Count; $i++) {
    $null = Set-YakuCatSegmentConfirmed -Project $project -Index $i
}
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
Chk ($rejoined -eq 'In Q1, fixed costs were reduced through a review of the production system.') '繋いだ訳文が元の2セルへ戻る'
Chk ([string]$read['A4'] -eq $knownTarget) '用語集で置換したラベルが出力される'
Chk ([string]$read['B4'] -eq '1234') '数値セルは触らない'

# ---------------------------------------------------------------- 保存→再開→外部原本が変わってもproject専用原本から出力
Write-Host '保存後に再開し、project専用原本から安全に書き戻す'
Chk (Save-YakuCatProject -Project $project) '原文スナップショットを含めて保存できる'
$ownedSourcePath = [string]$project.Path
$ownedSourceHash = (Get-FileHash -LiteralPath $ownedSourcePath -Algorithm SHA256).Hash
Chk ($ownedSourcePath -ne $srcPath -and $ownedSourcePath -match 'source\\original\.xlsx$') '取込原本をproject専用領域へ固定する'
Chk ([string]$project.FileName -eq 'in.xlsx') 'project専用原本でも利用者の元ファイル名を保持する'
$savedId = [string]$project.Id
Remove-YakuCatProject -Id $savedId
$restored = Restore-YakuCatProject -Id $savedId
Chk ($null -ne $restored -and @($restored.Blocks).Count -eq @($project.Blocks).Count) '再開時に原文スナップショットが戻る'

# 取込前の外部ファイルを後から変更しても、保存済み作業の原本と出力は変えない。
$xlMove = New-Object -ComObject Excel.Application
$xlMove.Visible = $false; $xlMove.DisplayAlerts = $false
try {
    $wbMove = $xlMove.Workbooks.Open($srcPath)
    $wsMove = $wbMove.Worksheets.Item(1)
    $wsMove.Rows.Item(1).Insert() | Out-Null
    $wsMove.Name = 'Overview'
    $wbMove.Save(); $wbMove.Close($false)
} finally {
    try { $xlMove.Quit() } catch {}
    Release-YakuComObject $xlMove
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

Chk ((Get-FileHash -LiteralPath ([string]$restored.Path) -Algorithm SHA256).Hash -eq $ownedSourceHash) '外部ファイルを変更してもproject専用原本は不変'

$restoredView = (ConvertTo-YakuCatProjectJson -Project $restored) | ConvertFrom-Json
Chk (-not [bool]$restoredView.export_blocked) 'project専用原本が残っていれば再開後も出力できる'
$resumedPath = Join-Path $tmp 'resumed.xlsx'
$resumedExport = Export-YakuCatProject -Project $restored -OutputPath $resumedPath -Settings $settings
Chk ([int]$resumedExport.Written -gt 0 -and (Test-Path -LiteralPath $resumedPath)) '保存済みのproject専用原本から出力できる'

$xlRead = New-Object -ComObject Excel.Application
$xlRead.Visible = $false; $xlRead.DisplayAlerts = $false
$movedRead = @{}
try {
    $wbRead = $xlRead.Workbooks.Open($resumedPath, 0, $true)
    $wsRead = $wbRead.Worksheets.Item('説明')
    foreach ($r in @(1,2,4)) { $movedRead["A$r"] = [string]$wsRead.Cells.Item($r,1).Value2 }
    $movedRead['B4'] = [string]$wsRead.Cells.Item(4,2).Value2
    $wbRead.Close($false)
} finally {
    try { $xlRead.Quit() } catch {}
    Release-YakuComObject $xlRead
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}
$movedJoined = ((@($movedRead['A1'], $movedRead['A2']) -join ' ') -replace '\s+', ' ').Trim()
Chk ($movedJoined -eq 'In Q1, fixed costs were reduced through a review of the production system.') '外部ファイルの行挿入を取り込まず、保存時の配置へ訳文を書き戻す'
Chk ([string]$movedRead['A4'] -eq $knownTarget) '外部ファイルのシート改名を取り込まず、保存時のラベル位置へ書く'
Chk ([string]$movedRead['B4'] -eq '1234') 'project専用原本の数値セルは触らない'

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

# 出口は確認済み訳文一覧のコピー。書き戻す元のファイルが無い。
# 原文「当第1四半期」の 1 を残す。落とすと numeric-value-mismatch で確認できない。
$null = Set-YakuCatSegmentTranslation -Project $tp -Index 0 -Text 'In Q1, fixed costs were reduced.'
$null = Set-YakuCatSegmentTranslation -Project $tp -Index 1 -Text 'FX impact was limited.'
$null = Set-YakuCatSegmentTranslation -Project $tp -Index 2 -Text 'We will continue to monitor market conditions.'
for ($i = 0; $i -lt @($tp.Segments).Count; $i++) {
    $null = Set-YakuCatSegmentConfirmed -Project $tp -Index $i
}
$texported = Export-YakuCatProject -Project $tp -OutputPath '' -Settings $settings
Chk ([string]::IsNullOrEmpty([string]$texported.OutputPath)) 'ファイルは作らない'
Chk ([string]$texported.Text -match 'Fixed costs were reduced\.') '訳文が繋がって返る'
Chk ([string]$texported.Text -match 'FX impact was limited\.') '2文目も入る'
Chk ([string]$texported.Text -match 'We will continue to monitor market conditions\.') '確認済みの3文目も入る'
Chk ([string]$texported.Text -notmatch '今後も市場環境を注視してまいります。') '未訳原文を訳文一覧へ混ぜない'
Remove-YakuCatProject -Id ([string]$tp.Id)

# 2026-08-13: 昇格（一時artifact -> 作業）は要らなくなった。貼り付けた文章は
# 最初から作業として作られるので、移る段が無い。守るものは変わっていない
# ＝「訳文をブラウザーから送り返さない」。原文だけを送る経路は、もともと
# 「長い文章を貼り付ける」が通っていたものと同じ。
$appJsText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\cat.js'))
$quickJsText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\quick.js'))
Chk ($quickJsText.Contains('/api/cat/open') -and -not $quickJsText.Contains('/api/cat/promote')) '貼り付けた文章は最初から作業として作る'
Chk (-not $quickJsText.Contains('translation:') -and -not $quickJsText.Contains('target_text')) '訳文を送り返す経路は作らない'
$indexText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'cat.html'))
# 貼り付けの入口は1つで、まずその場で訳す状態へ入る（2026-08-11）。長すぎて1回で
# 送れないときだけ、貼り付けた本文をそのまま確認作業へ渡す。
# 貼り付けは「入口」ではなく、始める画面にそのまま置いてある（2026-08-12）。
# 押して別の画面へ入れ替わる作りをやめたので、開く導線ではなく同居を見る。
Chk ($indexText.Contains('data-cat-source-show="file"') -and $indexText -notmatch 'id="cat-open-instant"') 'ファイルの入口はあり、貼り付けを開く導線は要らなくなった'
# 2026-08-13 に帯（タブ）を足し、同じ日に外した。外した理由は、貼り付けた文章も
# 資料と同じ確認作業になったので、切り替える相手そのものが無くなったこと
# （利用者判断「保存しない約束は要らない」）。帯を押しても同じ入口に着くだけの
# 飾りになっていた。守るべきもの（起動したら貼り付け欄に着地する）は変わらない。
Chk ($indexText -match 'id="cat-instant"' -and $indexText -match 'id="quick-input"') '貼り付け欄は起動して最初の画面にある'
Chk ($indexText -notmatch 'data-cat-tab-to=') '切り替える相手が無いのに帯だけ残す、をしていない'
Chk ($quickJsText.Contains('yaku-instant-handoff') -and $appJsText.Contains('yaku-instant-handoff') -and $appJsText -match "showPicker\(\);\s*\r?\n\s*el\('cat-text'\)\.value = text;") '長すぎる文章は確認作業へ渡せる'
Chk ($indexText -match 'id="cat-text"') 'CAT に貼り付け欄がある'

# ---------------------------------------------------------------- 一覧の作法
# 市販の CAT エディタが備えていて、こちらに無かったもの（2026-08-06 の比較）。
# 一日中この一覧の中で作業する道具なので、進み具合・現在位置・キーボードは
# 「あると便利」ではなく前提に近い。
Write-Host '一覧の作法（市販ツールに合わせたもの）'
$cssText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\styles.css'))
Chk ($cssText -match 'data-yaku-cat-state="untranslated"') '未訳の行を色で示す'
Chk ($cssText -match 'data-yaku-cat-state="human_edited"') '手直しの行を色で示す'
Chk ($cssText -match '\.cat-grid tbody tr\.is-active') 'いま見ている行を強調する'
# 繋ぎ直しのボタンは、開いている行にだけ描く。以前はCSSのvisibilityで隠していたが、
# 全行に要素が残り、116pxの場所列で日本語が1文字ずつ縦に折り返されていた。
# いまは cat.js が isActive の行の訳文セルにだけ入れる。
Chk ($appJsText -match 'isActive \?[\s\S]{0,2000}?<div class="cat-ops">') '繋ぎ直しのボタンは開いている行にだけ出す（全行に並ぶと目が滑る）'
Chk ($appJsText -notmatch 'cat-col-loc[^\r\n]{0,400}?cat-ops') '繋ぎ直しのボタンを狭い場所列へ入れない'
Chk ($appJsText.Contains("addEventListener('focusin'")) '現在行を追う'
Chk ($appJsText.Contains("event.key === 'Enter'") -and $appJsText.Contains('confirmRow(')) 'Ctrl+Enter で保存・確認して次へ進める'
Chk ($appJsText.Contains("status('処理中は確認できません")) '処理中のCtrl+Enterを止める'
Chk ($appJsText.Contains("el('cat-progress-bar').style.width")) '進み具合を出す'
Chk ($indexText -match 'id="cat-progress-bar"') '進捗バーがある'
# 触っただけのセグメントを「手直し」にしない。以前は離れるたびに保存して
# いたので、一覧を上から見ていくだけで全部が手直し扱いになっていた。
Chk ($appJsText.Contains("data-original")) '変更が無ければ保存しない（触っただけで手直しにしない）'
Chk ($appJsText.Contains("bindFileDrop(el('cat-drop'), el('cat-file-input'))") -and $appJsText.Contains("event.key === 'Enter' || event.key === ' '")) 'CAT のファイル欄へドロップとキーボード操作を結線する'
Chk ($appJsText.Contains("'行目の訳文`"")) '動的な訳文欄に行ごとの読み上げ名がある'
Chk ($appJsText.Contains("data-cat-loss")) '結合・解除ボタンが訳文消失の有無を持つ'
Chk ($appJsText -match "data-cat-merge[\s\S]{0,200}?window\.confirm\('[^']*訳文は消えます[^']*元に戻せません") '訳文がある行の結合前に、消えることを告げて確認する'
Chk ($appJsText -match "data-cat-split[\s\S]{0,200}?window\.confirm\('[^']*訳文は消えます[^']*元に戻せません") '訳文がある行の解除前に、消えることを告げて確認する'
Chk ($cssText -match '--focus:\s*#[0-9A-Fa-f]{6}\s*;') 'フォーカスリングは白地で見える不透明色を使う'
Chk ($appJsText.Contains('data-cat-revise')) 'CAT の訳文行に自由入力の修正欄を出す'
Chk ($appJsText.Contains("mode: 'revise'")) '修正指示を CAT ジョブとして送る'
$serverText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
Chk ($serverText.Contains("Mode = 'revise'")) '修正結果を同じ CAT 行へ戻す経路がある'
Chk ($serverText.Contains('previous_masked')) '待機中に人が直した行を古い修正結果で踏まない'
$revSeg = [pscustomobject]@{ Text='売上高は1,234百万円'; Translation='Net sales were JPY 1,234 million.'; MaskedTranslation='Net sales were JPY [[N1]] million.'; BlockIds=@(); Cells=@(); Joined=$false; Origin='copilot'; Confirmed=$false; Kind='text'; Location='本文' }
$revProject = [pscustomobject]@{ Id='rev1'; Path=''; FileName='貼り付け'; Direction='to_en'; Blocks=@(); Segments=@($revSeg); Source='text' }
$revView = (ConvertTo-YakuCatProjectJson -Project $revProject) | ConvertFrom-Json
Chk ([bool]$revView.segments[0].can_revise) 'マスク後訳文を持つ行だけ修正を依頼できる'
Chk ($appJsText.Contains('scopeIsCurrent(packet.scope, true)') -and $appJsText.Contains('data-cat-project-id')) '遅延保存応答を開始時の作業とrevisionへ束縛する'
Chk ($appJsText.Contains('deleteTarget = currentScope()') -and $appJsText.Contains('表示中の作業が変わったため、削除を中止しました')) '削除dialogは開いた時の作業を固定する'
Chk ($appJsText.Contains("type: 'translate', scope: jobScope") -and $appJsText.Contains("post('apply', { job_id: jobId }, true, context.scope)")) '翻訳jobの結果を開始時の作業へだけ適用する'
Chk ($appJsText.Contains('data.review_blocked') -and $appJsText.Contains('var same = document.querySelector')) 'QCで確認できない時は同じ行へ戻す'
Chk ($appJsText -match 'function redrawAfterFlush\(\)[\s\S]{0,200}?flush\(\)' -and $appJsText -match "data-cat-filter'\)[^
]*redrawAfterFlush\(\)") '絞り込み再描画の前に未保存編集を保存する'
Chk ($serverText.Contains('Get-YakuCopilotCallCount -WindowHours 3')) '画面へ直近3時間の実測回数を返す'
$fileTranslationText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CatBatch.ps1'))
Chk ($fileTranslationText.Contains("Context.ContainsKey('CompletedMap')")) '各バッチ完了時にCATへ途中結果を公開する'
Chk (-not $fileTranslationText.Contains("Context.ContainsKey('CachePerBatch')")) '機械下訳を別project向けcacheへ保存しない'
Chk ($fileTranslationText.Contains("Context.ContainsKey('OnBatchCompleted')")) '各成功バッチの耐障害保存コールバックを呼ぶ'
Chk (-not $serverText.Contains('Get-YakuTranslationCacheValue -Key $cacheKey')) 'CAT が別projectの機械下訳cacheを読まない'
Chk ($serverText.Contains("Category 'cat-partial'")) '途中停止でも完了済みの訳文をグリッドへ戻す'

Write-Host '成功バッチをapplyなしで復元する'
$checkpointSeg = [pscustomobject]@{ Text='境界テスト原文'; Translation=''; MaskedTranslation=''; BlockIds=@(); Cells=@(); Joined=$false; Origin=''; Confirmed=$false; Kind='text'; Sheet=''; Location='本文' }
$checkpointProject = [pscustomobject]@{ Id='checkpoint1'; Path=''; FileName='貼り付け'; Direction='to_en'; Blocks=@(); Segments=@($checkpointSeg); Source='text'; CreatedAt=(Get-Date).ToString('s') }
$script:YakuCatProjects[$checkpointProject.Id] = $checkpointProject
Chk (Save-YakuCatProject -Project $checkpointProject) 'チェックポイント前の空プロジェクトを保存する'
$null = Save-YakuCatBatchCheckpoint -ProjectId $checkpointProject.Id -ProjectRevision ([int]$checkpointProject.Revision) -Translations @([ordered]@{ index=0; source='境界テスト原文'; text='Recovered translation'; masked='Recovered [[N1]]' })
Remove-YakuCatProject -Id $checkpointProject.Id
$checkpointRestored = Restore-YakuCatProject -Id $checkpointProject.Id
Chk ([string]$checkpointRestored.Segments[0].Translation -eq 'Recovered translation') 'apply を呼ばず成功バッチの訳文が戻る'
Chk ([string]$checkpointRestored.Segments[0].MaskedTranslation -eq 'Recovered [[N1]]') '修正用のマスク後訳文も戻る'
Chk ([string]$checkpointRestored.Segments[0].Origin -eq 'copilot' -and -not [bool]$checkpointRestored.Segments[0].Confirmed) '復元した機械訳は未確認にする'

$retrySeg = [pscustomobject]@{ Text='保存再試行原文'; Translation=''; MaskedTranslation=''; BlockIds=@(); Cells=@(); Joined=$false; Origin=''; Confirmed=$false; Kind='text'; Sheet=''; Location='本文' }
$retryProject = [pscustomobject]@{ Id='checkpoint-retry'; Path=''; FileName='貼り付け'; Direction='to_en'; Blocks=@(); Segments=@($retrySeg); Source='text'; CreatedAt=(Get-Date).ToString('s') }
$null = Save-YakuCatBatchCheckpoint -ProjectId $retryProject.Id -ProjectRevision ([int]$retryProject.Revision) -Translations @([ordered]@{ index=0; source='保存再試行原文'; text='Retry saved'; masked='Retry saved' })
$originalSaveFunction = (Get-Command Save-YakuCatProject).ScriptBlock
Set-Item -LiteralPath Function:\Save-YakuCatProject -Value { param($Project) return $false }
$firstApply = Apply-YakuCatBatchCheckpoint -Project $retryProject
$retryCheckpointPath = Get-YakuCatCheckpointPath -ProjectId $retryProject.Id
Chk ($firstApply -eq 0 -and (Test-Path -LiteralPath $retryCheckpointPath -PathType Leaf)) 'Project保存に失敗したらチェックポイントを残す'
Set-Item -LiteralPath Function:\Save-YakuCatProject -Value $originalSaveFunction
$secondApply = Apply-YakuCatBatchCheckpoint -Project $retryProject
Remove-YakuCatProject -Id $retryProject.Id
$retryRestored = Restore-YakuCatProject -Id $retryProject.Id
Chk ($secondApply -eq 0 -and [string]$retryRestored.Segments[0].Translation -eq 'Retry saved') 'メモリ適用済みでも再保存し、成功後だけチェックポイントを消す'

Write-Host '概算は実際のバッチ境界を使う'
Clear-YakuTranslationCache
$usageSettings = $settings | Select-Object *
$usageSettings.max_chars_per_batch_file = 3000
$longA = 'あ' * 1477; $longB = 'い' * 1477
$usageProject = [pscustomobject]@{
    Id='usage1'; Direction='to_en'; CorpusSection=''; Source='text'; Blocks=@()
    Segments=@(
        [pscustomobject]@{ Text=$longA; Translation='' },
        [pscustomobject]@{ Text=$longB; Translation='' }
    )
}
$usage = Get-YakuCatCopilotUsage -Root $root -Project $usageProject -Settings $usageSettings
Chk ([int]$usage.EstimatedCalls -eq 2) '1477字×2件は実分割（各+24字）どおり2回と見積もる'
Chk ([int]$usage.MaxChars -eq 3000) 'max_chars_per_batch_file を単一の上限として使う'
Chk ((Get-YakuCatCacheStyle) -match 'reference:none') '候補文例は参考表示だけで、キャッシュ契約に混ぜない'
$cacheSource = 'この行はCATキャッシュの検査です。'
$cacheSeed = [pscustomobject]@{ Index=1; Text=$cacheSource; BlockIds=(New-Object System.Collections.Generic.List[string]) }
$null = Protect-YakuCatItems -Items @($cacheSeed) -Root $root -Direction 'to_en'
$cacheStyleA = Get-YakuCatCacheStyle
$cacheKeyA = Get-YakuTranslationCacheKey -Kind 'cat' -Direction 'to_en' -Text ([string]$cacheSeed.Text) -Style $cacheStyleA -Root $root -Settings $usageSettings
Set-YakuTranslationCacheValue -Key $cacheKeyA -Value 'Cached CAT translation.' -Settings $usageSettings
$cacheUsageProject = [pscustomobject]@{ Id='cache1'; Direction='to_en'; CorpusSection='文例A'; Segments=@([pscustomobject]@{ Text=$cacheSource; Translation='' }) }
$cacheHitUsage = Get-YakuCatCopilotUsage -Root $root -Project $cacheUsageProject -Settings $usageSettings
Chk ([int]$cacheHitUsage.CacheHits -eq 0 -and [int]$cacheHitUsage.EstimatedCalls -eq 1) '別projectの機械下訳cacheを読まず送信1回と見積もる'
$cacheUsageProject.CorpusSection = '文例B'
$cacheSamePromptUsage = Get-YakuCatCopilotUsage -Root $root -Project $cacheUsageProject -Settings $usageSettings
Chk ([int]$cacheSamePromptUsage.CacheHits -eq 0 -and [int]$cacheSamePromptUsage.EstimatedCalls -eq 1) '候補表示と無関係に別projectの機械下訳cacheを再利用しない'

# ---------------------------------------------------------------- 候補ペイン
# CAT エディタの中核にあたる部分（利用者の指摘 2026-08-06）。
# いま出せるのは用語集だけ。翻訳メモリはまだ無く、コーパスの文例は英語でしか
# 引けないため行ごとには出せない。
Write-Host '再開したものも元ファイルを再確認して Excel へ出力できる'
$restoredProj = Copy-YakuCatProjectForMutation -Project $restored
$flag = { param($p) return ((ConvertTo-YakuCatProjectJson -Project $p) | ConvertFrom-Json).export_blocked }
Chk (-not [bool](& $flag $restoredProj)) '専用原本と最新QCが残る再開プロジェクトは出力できる'
$missingFileProj = Copy-YakuCatProjectForMutation -Project $restored
$missingFileProj.Path = (Join-Path $tmp 'missing.xlsx')
Chk ([bool](& $flag $missingFileProj)) '専用原本が無ければ押す前に止める'
$textProj = Copy-YakuCatProjectForMutation -Project $restored
$textProj.Source = 'text'; $textProj.Path = ''; $textProj.Blocks = @(); $textProj.FileName = '貼り付けたテキスト'
Chk (-not [bool](& $flag $textProj)) '貼り付けたテキストは最新QCがあれば再開後も出せる（Blocks を使わない）'
$jsSrcX = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
Chk ($jsSrcX -match 'export_blocked') '画面が受け取っている'
Chk ($jsSrcX -match "el\('cat-export'\)\.disabled") '出力ボタンを押せなくする'
Chk ($jsSrcX -match 'outputGuidance' -and $jsSrcX -match 'eligibility_reasons') '出力できない理由を具体的な次操作として表示する'

Write-Host '候補ペイン'
$cp = New-YakuCatTextProject -Root $root -Text '上期営利' -Settings $settings -Direction 'to_en'
$cpSeg = @($cp.Segments)[0]
$null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$cp.Id) -Kind occurrence -Enforcement required `
    -JapanesePreferred '上期営利' -EnglishPreferred '1H OP' -Origin 'cat-project-test' `
    -OriginProjectId ([string]$cp.Id) -OriginFileName ([string]$cp.FileName) -OriginSegmentId ([string]$cpSeg.SegmentId) `
    -OriginLocation ([string]$cpSeg.Location) -OriginRevision ([int]$cp.Revision)
$cands = @(Get-YakuCatSegmentCandidates -Root $root -Project $cp -Index 0)
Chk ($cands.Count -gt 0) ('候補が出る: ' + $cands.Count)
Chk ([string]$cands[0].Kind -eq 'term') '利用者が登録した用語として出る'
Chk ([string]$cands[0].Target -eq '1H OP') ('上期営利 -> 1H OP: ' + [string]$cands[0].Target)
Remove-YakuCatProject -Id ([string]$cp.Id)

# 文中の一致も出す。表のラベルは完全一致で機械置換できるが、文中の語は
# 置換しない（活用と一致が壊れるため）。置換しないからこそ目に入れる。
$cp2 = New-YakuCatTextProject -Root $root -Text '固定費を圧縮した一方、為替の影響を受けました。' -Settings $settings -Direction 'to_en'
$cp2Seg = @($cp2.Segments)[0]
$null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$cp2.Id) -Kind occurrence -Enforcement required `
    -JapanesePreferred '固定費' -EnglishPreferred 'fixed costs' -Origin 'cat-project-test' `
    -OriginProjectId ([string]$cp2.Id) -OriginFileName ([string]$cp2.FileName) -OriginSegmentId ([string]$cp2Seg.SegmentId) `
    -OriginLocation ([string]$cp2Seg.Location) -OriginRevision ([int]$cp2.Revision)
$c2 = @(Get-YakuCatSegmentCandidates -Root $root -Project $cp2 -Index 0)
Chk (@($c2 | Where-Object { [string]$_.Source -eq '固定費' }).Count -eq 1) '文中の語を拾う'
Chk (@($c2 | Where-Object { [string]$_.Kind -ne 'term' }).Count -eq 0) '未登録の翻訳例を混ぜない'
Remove-YakuCatProject -Id ([string]$cp2.Id)

# 短い漢字語が前の漢字と続いて別の語になっている場合は拾わない。
# 「四半期」の中の「半期」が Half-year として出ると、かえって誤らせる。
$cp3 = New-YakuCatTextProject -Root $root -Text '当第1四半期の実績です。' -Settings $settings -Direction 'to_en'
$cp3Seg = @($cp3.Segments)[0]
$null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$cp3.Id) -Kind occurrence -Enforcement required `
    -JapanesePreferred '半期' -EnglishPreferred 'half-year' -Origin 'cat-project-test' `
    -OriginProjectId ([string]$cp3.Id) -OriginFileName ([string]$cp3.FileName) -OriginSegmentId ([string]$cp3Seg.SegmentId) `
    -OriginLocation ([string]$cp3Seg.Location) -OriginRevision ([int]$cp3.Revision)
$c3 = @(Get-YakuCatSegmentCandidates -Root $root -Project $cp3 -Index 0)
Chk (@($c3 | Where-Object { [string]$_.Source -eq '半期' }).Count -eq 0) '四半期 の中の 半期 を拾わない'
Remove-YakuCatProject -Id ([string]$cp3.Id)

Chk ($appJsText.Contains('function candidates(index)')) '行を移るたびに候補を出す'
Chk ($appJsText.Contains('data-cat-insert')) '候補を訳文へ差し込める'
Chk ($indexText -match 'id="cat-candidates"') '候補ペインがある'

# ---------------------------------------------- 負の金額は、括弧も印として数える
# このアプリは Copilot へ「▲やマイナスは数値を括弧でくくれ」と指示し、画面にも
# 「▲152億円 → (152) oku」と書いている。その形を点検が弾くと、負の金額を含む
# 資料は規約どおりに訳すかぎり必ず出力できなくなる（2026-08-11、実機で発生）。
$signProject = [pscustomobject]@{ Direction='to_en' }
function Test-YakuSignFinding { param([string]$Source,[string]$Target)
    $seg = [pscustomobject]@{ Text=$Source; Translation=$Target; Origin='human'; TermIds=@()
        SourceRevision=1; QcStatus=''; QcSourceRevision=0; QcFindings=@(); TerminologyExceptions=@() }
    $result = Invoke-YakuCatSegmentValidation -Project $signProject -Segment $seg
    return @(@($result.Findings) | Where-Object { [string]$_.Code -eq 'numeric-sign-missing' }).Count
}
Chk ((Test-YakuSignFinding -Source '▲152億円' -Target '(152) oku') -eq 0) '括弧でくくった負の金額は、この規約どおりとして通る'
Chk ((Test-YakuSignFinding -Source '▲152億円' -Target '-152 oku') -eq 0) 'マイナス記号でも通る'
Chk ((Test-YakuSignFinding -Source '▲152億円' -Target '152 oku') -eq 1) '負である印が無ければ、いままでどおり弾く'

# -------------------------------- 金額だけのセルは「原文と同じ」でも正しい訳
# 単位換算がこのアプリ自身の表記へ直すので（1兆3,150億円 → 13,150 oku）、
# Copilot へ渡る原文は既に 13,150 oku であり、正しい訳もまったく同じ文字列になる。
# それを捨てると、金額だけのセルが1つあるだけで全行確認できず、社内確認用の
# ファイルが永久に作れない（2026-08-11、実機のExcelで発生）。
# 検査に届くのは外部送信前にマスクした形（[[N1]] oku）である。実機のログに出た
# sourceLength=10 はこれで、素の 13,150 oku ではない。素のほうだけで試すと
# 直ったつもりで直っていない（2026-08-11、一度そうなった）。
Chk ((Get-YakuFileTranslationInvalidReason -Source '[[N1]] oku' -Translation '[[N1]] oku' -Direction 'to_en') -eq '') 'マスク済みの金額セルは、同じ文字列でも訳として通る'
Chk ((Get-YakuFileTranslationInvalidReason -Source '[[N1]]' -Translation '[[N1]]' -Direction 'to_en') -eq '') 'マスク済みの数値だけのセルも通る'
Chk ((Get-YakuFileTranslationInvalidReason -Source '13,150 oku' -Translation '13,150 oku' -Direction 'to_en') -eq '') '金額だけのセルは、同じ文字列でも訳として通る'
Chk ((Get-YakuFileTranslationInvalidReason -Source '(152) oku' -Translation '(152) oku' -Direction 'to_en') -eq '') '括弧付きの負の金額も通る'
Chk ((Get-YakuFileTranslationInvalidReason -Source '13,150' -Translation '13,150' -Direction 'to_en') -eq '') '数値だけのセルは、いままでどおり通る'
Chk ((Get-YakuFileTranslationInvalidReason -Source '1兆3,150億円' -Translation '1兆3,150億円' -Direction 'to_en') -eq 'same-as-source') '日本語のまま返ってきたものは、いままでどおり捨てる'
Chk ((Get-YakuFileTranslationInvalidReason -Source '売上高' -Translation '売上高' -Direction 'to_en') -eq 'same-as-source') '訳されていない語も、いままでどおり捨てる'

Write-Host 'CASE: 同じ原文の行へ配る（反復）' -ForegroundColor Cyan
# 市販のCATツールでは標準の機能（memoQ の auto-propagation、Phrase の repetitions）。
# 確定のときに配るのも各ツールと同じ。ただし配り方は狭くする。
#   空の行にだけ入れる／確認済みにはしない／出どころを propagated にする
$repText = @(
    '売上高',
    '当第1四半期の売上高は122億円でした。',
    '売上高',
    '営業利益',
    '売上高'
) -join "`n"
$rp = New-YakuCatTextProject -Root $root -Text $repText -Settings $settings -Direction 'to_en'
$repSegs = @($rp.Segments)
Chk ($repSegs.Count -eq 5) '5行に分かれる'
$repJson = ConvertTo-YakuCatProjectJson -Project $rp | ConvertFrom-Json
$repRows = @($repJson.segments)
Chk ([int]$repRows[0].repetition_count -eq 3 -and [bool]$repRows[0].repetition_first) '同じ原文の行数を数え、最初の行が分かる'
Chk ([int]$repRows[2].repetition_count -eq 3 -and -not [bool]$repRows[2].repetition_first) '2つ目以降は最初ではない'
Chk ([int]$repRows[1].repetition_count -eq 1) '1行しか無い原文は反復ではない'

# 3行目に先に別の訳を入れておく。上書きしないことを見る。
$null = Set-YakuCatSegmentTranslation -Project $rp -Index 4 -Text 'Revenue (kept)'
$null = Set-YakuCatSegmentTranslation -Project $rp -Index 0 -Text 'Net sales'
$filled = Copy-YakuCatTranslationToRepetitions -Project $rp -Index 0
$after = @($rp.Segments)
Chk ($filled -eq 1) ('空いている同じ原文の行にだけ入れる（実際 ' + $filled + ' 行）')
Chk ([string]$after[2].Translation -eq 'Net sales') '空だった行には入る'
Chk ([string]$after[4].Translation -eq 'Revenue (kept)') '既にある訳は上書きしない'
Chk ([string]$after[3].Translation -eq '') '原文が違う行には入らない'
Chk ([string]$after[2].Origin -eq 'propagated') '出どころが分かる'
Chk (-not [bool]$after[2].Confirmed) '配った行は確認済みにしない'
Chk ([string]$after[2].MaskedTranslation -eq '') 'マスク後の訳文は引き継がない'
Remove-YakuCatProject -Id ([string]$rp.Id)

# ---------------------------------------------------------------- 片付け
Remove-YakuCatProject -Id ([string]$project.Id)
Chk ((Get-YakuCatProject -Id ([string]$project.Id)) -eq $null) '終わったプロジェクトは捨てられる'

try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
if ([string]::IsNullOrWhiteSpace($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue } else { $env:YAKULINGO_DATA_DIR = $previousDataDir }

if ($script:fail -gt 0) {
    Write-Host "V91.61 CAT project regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 CAT project regression passed.' -ForegroundColor Green
