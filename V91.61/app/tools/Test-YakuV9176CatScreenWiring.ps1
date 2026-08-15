<#
.SYNOPSIS
  画面の描画と配線を、実機と同じ Chromium で**実際に押して**確かめる回帰テスト。

.DESCRIPTION
  なぜ要るか。ここまで画面側の表明は `-match 'data-cat-split-at'` のような
  字面の在否だけだった。2026-08-15 に19通り壊して測ったところ、次の6通りが
  **全部緑のまま**通った。

   - 分割ボタンを描かない（`if (segment.can_split_at)` を `if (false && …)`）
   - Alt+S を殺す（キー分岐の `!event.ctrlKey` を `event.ctrlKey` へ）
   - Ctrl+H を殺す（キー分岐条件を `false && …` へ）
   - 「訳文を置き換える」ボタンを runReplace から外す
   - 「探す場所が原文だけなら訳文を書き換えない」歯止めを3か所とも外す
   - 用語の印が入った行で、押した位置が拾えない（前の位置で黙って割れる）

  字面は「描かれているか」も「つながっているか」も見ていない。ここでは
  本物の cat.html / cat.js を Chromium へ読ませ、実際に押し、出た DOM と
  飛んだ要求の中身を見る。判定はこのファイルが行い、ブラウザ側
  （tools/cat-screen/cat-screen-gate.js）は観測した事実を JSON で返すだけである。

  見るのは7つ。
   (a) can_split_at の行にだけ分割ボタンが**実際に出る**
   (b) Alt+S がその分割ボタンを押す。割れない行では断る
   (c) 用語の印が入った原文でも、押した位置で割れる（位置が一致する）
   (d) Ctrl+H が検索と置換を開き、入力欄へ入る
   (e) 「訳文を置き換える」ボタンが置換の口へつながっている
   (f) 探す場所が原文だけのとき、押しても要求が飛ばない
   (g) 画面が JavaScript の例外を出していない

  (c) は「押した位置」をアプリとは別に測る。ブラウザが決めたキャレット位置を
  capture 段の覗き窓で採り、アプリが送った位置と突き合わせる。どちらか一方の
  実装で両方を作ると、同じように壊せば何も落ちない。

  node と playwright が無い環境では**緑にしない**。走らせられない門を緑に
  すると、字面の表明と同じものになる。終了コード 3（未測定）で抜ける。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9176CatScreenWiring.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0
$YAKU_SCREEN_UNMEASURED = 3

function Chk { param([bool]$c,[string]$m) $script:checks++; if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

$driver = Join-Path (Join-Path $toolsRoot 'cat-screen') 'cat-screen-gate.js'
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) { Write-Host ('UNMEASURED: 運転席がありません: ' + $driver) -ForegroundColor Red; exit $YAKU_SCREEN_UNMEASURED }

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Write-Host 'UNMEASURED: node が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    Write-Host '  この結果を「画面はつながっている」根拠に使わないこと。' -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeExe = [string]$nodeCmd.Source
# playwright は配布物には入らない開発用の依存（リポジトリ直下の package.json）。
# 解決の起点は運転席のあるディレクトリにする（node の探索と同じ順で上へ辿る）。
$probeDir = (Split-Path -Parent $driver).Replace('\', '/')
$null = & $nodeExe -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    Write-Host '  リポジトリ直下で npm install / npx playwright install chromium を通してから、もう一度。' -ForegroundColor Red
    exit $YAKU_SCREEN_UNMEASURED
}

# 読み込み順序は SrcModules.ps1 が唯一の出典。写すと写し間違いが静かに効く。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-screen-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

$settings = Read-YakuSettings -Root $root
$script:YakuRoot = $root

# 題材。1行目は割れる行で、登録用語が**先頭ではなく途中**に入る。
# 押す位置（12文字目）は、その印より後ろに落ちる。ここが要点で、印より前だけを
# 見ていた実装は、この位置を拾えないまま「前に拾えた位置」で割っていた。
$source = '当社は生産体制を見直し、調達費も削減しました。'
$term = '生産体制'
$termEnd = $source.IndexOf($term) + $term.Length
$clickChar = 12

try {
    Write-Host '(0) 題材を、実装が作る応答そのものから用意する' -ForegroundColor Cyan
    $project = New-YakuCatTextProject -Root $root -Text ($source + "`n" + '営業利益は増えました。' + "`n" + '設備投資も進めました。') -Settings $settings -Direction 'to_en'
    Chk (@($project.Segments).Count -eq 3) ('貼り付け本文は3行に切り分けられる（実際 ' + @($project.Segments).Count + '）')
    # 2行目と3行目を繋いで「割れない行」を作る。can_split_at=false を人が書かない。
    $null = Merge-YakuCatSegments -Project $project -Index 1
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'The Company reviewed its production system and cut procurement costs.'
    $null = Set-YakuCatSegmentTranslation -Project $project -Index 1 -Text 'The Company posted higher operating profit and more capital spending.'
    $projectJson = ConvertTo-YakuCatProjectJson -Project $project
    $view = $projectJson | ConvertFrom-Json
    $viewRows = @($view.segments)
    Chk ($viewRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $viewRows.Count + '）')
    Chk ([bool]$viewRows[0].can_split_at -and -not [bool]$viewRows[1].can_split_at) '1行目は割れる・2行目は割れない（描き分けを見る題材である）'
    Chk ([string]$viewRows[0].source -eq $source) '1行目の原文は題材どおり'

    $candidates = [ordered]@{
        terms = @(
            [ordered]@{
                kind='term'; source=$term; translation='production system'; target='production system'
                source_name='用語集'; scope='project'; term_id=('t'*32); term_version=1; reference_id=('a'*32)
                allowed_targets=@(); forbidden_targets=@()
            }
        )
        segment_matches = @()
    }
    $projectPath = Join-Path $tmp 'project.json'
    $candidatePath = Join-Path $tmp 'candidates.json'
    $observedPath = Join-Path $tmp 'observed.json'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($projectPath, $projectJson, $utf8)
    [IO.File]::WriteAllText($candidatePath, ($candidates | ConvertTo-Json -Depth 8), $utf8)

    Write-Host '(1) 本物の画面を Chromium で開いて、実際に押す' -ForegroundColor Cyan
    $stderrPath = Join-Path $tmp 'node-stderr.txt'
    $arguments = @($driver, (Join-Path $root 'www'), $projectPath, $candidatePath, $observedPath) | ForEach-Object { '"' + $_ + '"' }
    $proc = Start-Process -FilePath $nodeExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
    $nodeErr = ''
    if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
    Chk ([int]$proc.ExitCode -eq 0) ('運転席が走り切る' + $(if($nodeErr){' / ' + $nodeErr.Substring(0,[Math]::Min(400,$nodeErr.Length))}else{''}))
    $o = $null
    if (Test-Path -LiteralPath $observedPath) { $o = [IO.File]::ReadAllText($observedPath, $utf8) | ConvertFrom-Json }
    Chk ($null -ne $o) '画面で観測した事実を受け取れた'
    if ($null -eq $o) { throw 'CAT_SCREEN_GATE_NO_OBSERVATION' }
    Chk ([string]::IsNullOrEmpty([string]$o.fatal)) ('画面の操作が途中で止まっていない' + $(if($o.fatal){' / ' + ([string]$o.fatal).Substring(0,[Math]::Min(400,([string]$o.fatal).Length))}else{''}))

    # ------------------------------------------------------------------ (g)
    Write-Host '(g) 画面が JavaScript の例外を出していない' -ForegroundColor Cyan
    Chk (@($o.errors).Count -eq 0) ('例外0件（実際: ' + (@($o.errors) -join ' / ') + '）')
    Chk (@($o.console).Count -eq 0) ('コンソールのエラー0件（実際: ' + (@($o.console) -join ' / ') + '）')

    # ------------------------------------------------------------------ (a)
    Write-Host '(a) can_split_at の行にだけ分割ボタンが実際に出る' -ForegroundColor Cyan
    $drawn = @($o.rows)
    Chk ($drawn.Count -eq 2) ('表に2行が描かれる（実際 ' + $drawn.Count + '）')
    Chk ([string]$drawn[0].source -eq $source) '描かれた原文が題材どおり（描画の当て先を取り違えていない）'
    $onSplittable = @($o.splitButtonsOnSplittableRow)
    $onUnsplittable = @($o.splitButtonsOnUnsplittableRow)
    Chk ($onSplittable.Count -eq 1) ('割れる行では分割ボタンが1つ描かれる（実際 ' + $onSplittable.Count + '）')
    Chk ($onSplittable.Count -eq 1 -and [string]$onSplittable[0].index -eq '0') '描かれたボタンは、その行を指している'
    Chk ($onSplittable.Count -eq 1 -and [string]$onSplittable[0].keys -eq 'Alt+S') 'ボタンに Alt+S が書いてある（キー一覧と実物が一致する）'
    Chk ($onUnsplittable.Count -eq 0) ('割れない行では1つも描かれない（実際 ' + $onUnsplittable.Count + '）')
    Chk (@($o.splitButtonsBackOnSplittableRow).Count -eq 1) '行を移って戻ると、また描かれる'

    # ------------------------------------------------------------------ (b)
    Write-Host '(b) Alt+S が分割ボタンを押す' -ForegroundColor Cyan
    Chk ([string]$o.altSOnUnsplittableRow.status -match '原文の途中では分けられません') ('割れない行の Alt+S は断る: ' + [string]$o.altSOnUnsplittableRow.status)
    Chk ([int]$o.altSOnUnsplittableRow.splitCalls -eq 0) '断ったときは口を叩かない'
    Chk ([int]$o.altSSplit.calls -eq 1) ('割れる行の Alt+S で split-at の口へ1回だけ飛ぶ（実際 ' + [int]$o.altSSplit.calls + ' 回）')
    Chk ($null -ne $o.altSSplit.body -and [int]$o.altSSplit.body.index -eq 0) '送った行番号が正しい'

    # ------------------------------------------------------------------ (c)
    Write-Host '(c) 用語の印が入った原文でも、押した位置で割れる' -ForegroundColor Cyan
    Chk ([int]$o.marks.count -eq 1) ('原文に用語の印が1つ入っている（実際 ' + [int]$o.marks.count + '）')
    Chk ([string]$o.marks.plain -eq $source) '印を入れても生原文（data-plain）は元のまま'
    Chk ([string]$o.marks.rendered -eq $source) '印を入れても見える文字は増減しない'
    Chk ([int]$o.marks.childNodes -ge 3) ('印で原文が複数の子ノードに割れている（実際 ' + [int]$o.marks.childNodes + ' 個。これが無いと、この検査は空振りする）')
    Chk ([string]$o.marks.firstChildText -eq $source.Substring(0, $source.IndexOf($term))) '最初の子ノードは印より前の部分だけ'
    $offsets = @($o.probe.offsets)
    Chk ($offsets.Count -eq 2) ('原文の上で2回押せている（実際 ' + $offsets.Count + ' 回）')
    Chk ($offsets.Count -eq 2 -and [int]$offsets[0] -eq [int]$o.firstClickChar) ('1回目に押した位置は ' + [int]$o.firstClickChar + '（印より前）')
    Chk ($offsets.Count -eq 2 -and [int]$offsets[1] -eq $clickChar) ('2回目に押した位置は ' + $clickChar)
    Chk ($clickChar -gt $termEnd) ('2回目は印の終わり（' + $termEnd + '）より後ろである。前だけを見ている実装が通らない題材になっている')
    # ここが本体。ブラウザが決めた位置と、アプリが送った位置が一致すること。
    # かつては1回目の位置が残り、押した場所とは違う位置で黙って割れていた。
    Chk ($null -ne $o.altSSplit.body -and [int]$o.altSSplit.body.position -eq $clickChar) ('アプリが送った位置が、最後に押した位置と一致する（送った値 ' + [string]$o.altSSplit.body.position + '）')
    Chk ($null -ne $o.altSSplit.body -and [int]$o.altSSplit.body.position -ne [int]$o.firstClickChar) '1回目に押した位置が残っていない'
    # 押す前に見せる文面も、その位置で割ったものであること。
    Chk ([string]$o.altSSplit.dialog -match [regex]::Escape($source.Substring(0, $clickChar))) '確認の窓に出る前半が、その位置で割ったもの'
    Chk ([string]$o.altSSplit.dialog -match [regex]::Escape($source.Substring($clickChar))) '確認の窓に出る後半が、その位置で割ったもの'

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) Ctrl+H が検索と置換を開く' -ForegroundColor Cyan
    Chk ([bool]$o.ctrlH.menuOpen) 'Ctrl+H で検索と置換の折りたたみが開く'
    Chk ([string]$o.ctrlH.focused -eq 'cat-search') ('そのまま検索欄へ入る（実際の焦点: ' + [string]$o.ctrlH.focused + '）')

    # ------------------------------------------------------------------ (e)
    Write-Host '(e) 「訳文を置き換える」が置換の口へつながっている' -ForegroundColor Cyan
    Chk (-not [bool]$o.replaceReady.disabled) '対象がある状態でボタンが押せる'
    Chk ([string]$o.replaceReady.label -match '表示中の2行の訳文を置き換える') ('押す前に対象行数を札に出す: ' + [string]$o.replaceReady.label)
    Chk ([int]$o.replaceRun.estimateCalls -eq 1) ('押すと、まず数える口を1回叩く（実際 ' + [int]$o.replaceRun.estimateCalls + ' 回）')
    Chk ([int]$o.replaceRun.replaceCalls -eq 1) ('確認のあと、置換の口を1回叩く（実際 ' + [int]$o.replaceRun.replaceCalls + ' 回）')
    Chk ($null -ne $o.replaceRun.replaceBody -and [string]$o.replaceRun.replaceBody.find -eq 'The Company') '送った検索語が画面のとおり'
    Chk ($null -ne $o.replaceRun.replaceBody -and @($o.replaceRun.replaceBody.indexes).Count -eq 2) '送った対象行が絞り込み結果のとおり'
    Chk ($null -ne $o.replaceRun.replaceBody -and [string]$o.replaceRun.replaceBody.scope -eq 'both') '探す場所をサーバへも渡している'
    Chk ([string]$o.replaceRun.dialog -match '原文は変わりません') '押す前に、原文は変わらないと告げる'

    # ------------------------------------------------------------------ (f)
    Write-Host '(f) 探す場所が原文だけのときは、押しても訳文を書き換えない' -ForegroundColor Cyan
    Chk ([bool]$o.scopeSource.disabled) 'ボタンが押せない状態になる'
    Chk ([string]$o.scopeSource.label -eq '訳文を置き換える') ('札に対象行数を出さない（実際: ' + [string]$o.scopeSource.label + '）')
    Chk ([string]$o.scopeSource.summary -match '原文は書き換えません') ('理由を書く: ' + [string]$o.scopeSource.summary)
    Chk ([int]$o.scopeSourceForcedClick.estimateCalls -eq 0) '無理やり押しても、数える口を叩かない'
    Chk ([int]$o.scopeSourceForcedClick.replaceCalls -eq 0) '無理やり押しても、置換の口を叩かない'
    Chk ([string]$o.scopeSourceForcedClick.status -match '原文は書き換えません') '押した人に理由を返す'

    if ($script:fail -eq 0) { Write-Host ('V91.76 画面の描画と配線の回帰テストに合格しました。検査 ' + $script:checks + ' 件。') -ForegroundColor Green }
    else { Write-Host ('FAILED: ' + $script:fail + ' / ' + $script:checks) -ForegroundColor Red }
} finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
exit ([int]($script:fail -gt 0))
