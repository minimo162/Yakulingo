<#
.SYNOPSIS
  V91.98: CATの翻訳完了時にもマスク件数を見せる（マスク件数見える化）の回帰試験。

.DESCRIPTION
  テキスト/パレット経路には既にある安全の見える化(New-YakuMaskingNoticeHtml、
  Html.ps1:321-334)を、件数がいちばん多いCAT経路へ横展開した。見るのは4つ。

  (a) Protect-YakuCatItems が、dedupe後の item ごとに MaskedCount/KeptCount を
      積むこと。複製された原文（同じ文が複数行にある）は1回だけ数えること。
      対応表(NumericMaskMap)は運ばず件数だけを持つこと。

  (b) Get-YakuCatSentMaskTotals（Server.ps1のジョブscriptblockから直接は
      試験が届かないため切り出した集計関数、ConvertTo-YakuCatDedupedItems と
      同じ理由）が、「送った分（訳文が実際に届いた行）」だけを合算すること。
      未送達・空訳文は数えないこと。

  (c) Convert-YakuTranslationJobResultJson が、Kind='cat' の結果に載った
      MaskedCount を masked_count として返すこと。MaskedCount を持たない
      cat結果（align等）や、cat以外のKindでは 0 のままなこと（既存挙動への
      副作用なし。Test-YakuV9195Palette.ps1 と同じ確認軸）。

  (d) 実機Chromiumで、まとめて翻訳が終わると #cat-mask-notice に
      「数値 N 件をマスクして送信しました。」が出ること。N=0 のときは
      「この翻訳で外部へ送った数値はありません。」と明示すること
      （何も出さないのではない）。出した通知は、別の render() を経由する
      操作（行の確認）でも消えないこと（自動では消えない）。

  node/Playwright/Chromium が無い環境では **緑にしない**。終了コード3
  （未測定）で抜ける。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9198CatMaskNotice.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0
$YAKU_SCREEN_UNMEASURED = 3

function Chk { param([bool]$c, [string]$m) $script:checks++; if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

Write-Host 'Test-YakuV9198CatMaskNotice'

. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in @($script:YakuSrcModuleFiles)) {
    if ($name -ne 'DesktopIntegration.ps1') { . (Join-Path (Join-Path $root 'src') $name) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9198-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }
$script:YakuRoot = $root
$settings = Read-YakuSettings -Root $root

# ============================================================ (a) Protect-YakuCatItems
Write-Host '-- (a) Protect-YakuCatItems: item ごとの件数、複製は1回だけ --'

$rawItems = @(
    [pscustomobject]@{ index = 1; text = '出荷台数は659千台。'; terminology = @() }
    [pscustomobject]@{ index = 2; text = '当社の方針は変わりません。'; terminology = @() }
    [pscustomobject]@{ index = 3; text = '営業利益は296億円、税金費用99億円の見込みです。'; terminology = @() }
    # index=1と同じ原文。dedupeで1つの item に畳まれ、MaskedCountは二重に
    # 積まれてはならない（重複行を訳すたびに件数が水増しされる欠陥を防ぐ）。
    [pscustomobject]@{ index = 4; text = '出荷台数は659千台。'; terminology = @() }
)
$items = @(ConvertTo-YakuCatDedupedItems -RawItems $rawItems)
Chk ($items.Count -eq 3) ('dedupeで3件になる（実際 ' + $items.Count + '）')
$null = Protect-YakuCatItems -Items $items -Root $root -Direction 'to_en'

$itemByIndex = @{}
foreach ($it in @($items)) { $itemByIndex[[int]$it.Index] = $it }
Chk ([int]$itemByIndex[1].MaskedCount -eq 1) ('659千台の item は MaskedCount=1（実際 ' + [int]$itemByIndex[1].MaskedCount + '）')
Chk (@($itemByIndex[1].Targets) -contains 1 -and @($itemByIndex[1].Targets) -contains 4) '複製された行(index=1,4)は同じ item の Targets へ両方入る（二重計上の芽を断つ）'
Chk ([int]$itemByIndex[2].MaskedCount -eq 0) ('数字を含まない item は MaskedCount=0（実際 ' + [int]$itemByIndex[2].MaskedCount + '）')
Chk ([int]$itemByIndex[3].MaskedCount -eq 2) ('296億円・99億円の item は MaskedCount=2（実際 ' + [int]$itemByIndex[3].MaskedCount + '）')
foreach ($it in @($items)) {
    Chk ($it.PSObject.Properties.Name -contains 'NumericMaskMap') 'item は対応表(NumericMaskMap)自体は従来どおり持つ（実値への割り戻しに要る）'
}
# 対応表そのもの・マスク済み本文は、この試験でも結果オブジェクトへは載せない
# （§8「件数のみ」。ここでは item が Map を「件数」以外の形で外へ運ぶ経路が
# 無いことを、次の(b)で確認する）。

# ============================================================ (b) Get-YakuCatSentMaskTotals
Write-Host '-- (b) Get-YakuCatSentMaskTotals: 送った分だけを合算 --'

$fullMap = @{ 1 = 'A'; 2 = 'B'; 3 = 'C' }
$fullTotals = Get-YakuCatSentMaskTotals -Items @($items) -Map $fullMap
Chk ([int]$fullTotals.MaskedCount -eq 3) ('全部送った(1+0+2): 合計3（実際 ' + [int]$fullTotals.MaskedCount + '）')

# 部分失敗を模す。index=3(MaskedCount=2)の訳文が届いていない
# （CompletedMapに無い＝送っていない分）。
$partialMap = @{ 1 = 'A'; 2 = 'B' }
$partialTotals = Get-YakuCatSentMaskTotals -Items @($items) -Map $partialMap
Chk ([int]$partialTotals.MaskedCount -eq 1) ('index=3が未送達なら合計1（実際 ' + [int]$partialTotals.MaskedCount + '。送っていない分を数えない）')

# キーはあるが訳文が空（サーバの $pairs 構築と同じ扱い）。
$blankMap = @{ 1 = ''; 2 = 'B'; 3 = 'C' }
$blankTotals = Get-YakuCatSentMaskTotals -Items @($items) -Map $blankMap
Chk ([int]$blankTotals.MaskedCount -eq 2) ('index=1の訳文が空なら合計2（実際 ' + [int]$blankTotals.MaskedCount + '。空訳文は数えない）')

$emptyMap = @{}
$emptyTotals = Get-YakuCatSentMaskTotals -Items @($items) -Map $emptyMap
Chk ([int]$emptyTotals.MaskedCount -eq 0 -and [int]$emptyTotals.KeptCount -eq 0) '何も届いていなければ合計0（0件も明示する設計の材料）'

# ============================================================ (c) Convert-YakuTranslationJobResultJson
Write-Host '-- (c) Convert-YakuTranslationJobResultJson: masked_count の配線 --'

function Get-N9198FunctionText {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Language.ScriptBlockAst]$Ast, [Parameter(Mandatory=$true)][string]$Name)
    $found = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return $null }
    return [string]$found[0].Extent.Text
}
$serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
$serverTokens = $null; $serverParseErrors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$serverTokens, [ref]$serverParseErrors)
Chk (@($serverParseErrors).Count -eq 0) 'Server.ps1 が構文エラー無く解析できる'
$convertText = Get-N9198FunctionText -Ast $serverAst -Name 'Convert-YakuTranslationJobResultJson'
Chk (-not [string]::IsNullOrWhiteSpace($convertText)) 'Server.ps1 から Convert-YakuTranslationJobResultJson を取り出せる'
if (-not [string]::IsNullOrWhiteSpace($convertText)) { Invoke-Expression $convertText }

# 冒頭の Update-YakuTranslationJobs は本物のジョブ基盤を要求する副作用な
# ので、Test-YakuV9195Palette.ps1 と同じくスタブに差し替える。
Set-Item -Path Function:Update-YakuTranslationJobs -Value { param() }

function New-N9198JobState {
    param([Parameter(Mandatory=$true)][string]$ResultJson)
    return @{
        id = 'job-n9198'; mode = 'done'; label = 'Done'; class = 'ok'; detail = ''; progress = 100
        kind = 'cat'; phase = ''; unique_done = 0; unique_total = 0; updated_at = ''; error_code = ''; completion_status = ''
        result_json = $ResultJson
    }
}

$catResultWithCount = [ordered]@{ Kind = 'cat'; Mode = 'translate'; Translations = @(); MaskedCount = 5; KeptCount = 1 } | ConvertTo-Json -Depth 6 -Compress
$catStateWithCount = New-N9198JobState -ResultJson $catResultWithCount
$catJsonWithCount = Convert-YakuTranslationJobResultJson -State $catStateWithCount | ConvertFrom-Json
Chk ([int]$catJsonWithCount.masked_count -eq 5) ('Kind=cat, MaskedCount=5 の結果は masked_count=5 を返す（実際 ' + [int]$catJsonWithCount.masked_count + '）')

$catResultNoCount = [ordered]@{ Kind = 'cat'; Mode = 'align'; Pairs = @() } | ConvertTo-Json -Depth 6 -Compress
$catStateNoCount = New-N9198JobState -ResultJson $catResultNoCount
$catJsonNoCount = Convert-YakuTranslationJobResultJson -State $catStateNoCount | ConvertFrom-Json
Chk ([int]$catJsonNoCount.masked_count -eq 0) ('MaskedCountを持たないcat結果(align)は masked_count=0（実際 ' + [int]$catJsonNoCount.masked_count + '。既定値へ安全に落ちる）')

$textResultWithCount = [ordered]@{ Kind = 'text'; Direction = 'to_en'; SourceText = 'src'; Options = @(); MaskedCount = 7; KeptCount = 0 } | ConvertTo-Json -Depth 6 -Compress
$textStateWithCount = New-N9198JobState -ResultJson $textResultWithCount
$textJsonWithCount = Convert-YakuTranslationJobResultJson -State $textStateWithCount | ConvertFrom-Json
Chk ([int]$textJsonWithCount.masked_count -eq 0) ('Kind=text（パレット/簡易翻訳）は masked_count に載せない（実際 ' + [int]$textJsonWithCount.masked_count + '。CAT専用の配線、副作用なし）')

# ============================================================ (d) 実機Chromium部
Write-Host '-- (d) chromium --'

$driver = Join-Path (Join-Path $toolsRoot 'cat-mask-screen') 'cat-mask-gate.js'
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) { Write-Host ('UNMEASURED: 運転席がありません: ' + $driver) -ForegroundColor Red; exit $YAKU_SCREEN_UNMEASURED }

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Write-Host 'UNMEASURED: node が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    if ($script:fail -gt 0) { exit 1 }
    exit $YAKU_SCREEN_UNMEASURED
}
$nodeExe = [string]$nodeCmd.Source
$probeDir = (Split-Path -Parent $driver).Replace('\', '/')
$null = & $nodeExe -e ("try{require.resolve('playwright',{paths:['" + $probeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が見つかりません。画面の門は測っていません。' -ForegroundColor Red
    if ($script:fail -gt 0) { exit 1 }
    exit $YAKU_SCREEN_UNMEASURED
}

# 実際に翻訳し終える2つの資料を、本物の関数で作る（写経しない）。
$projectWithMask = New-YakuCatTextProject -Root $root -Text 'Copilotへ送る本文（この試験では中身は見ない）。' -Settings $settings -Direction 'to_en'
$projectZeroMask = New-YakuCatTextProject -Root $root -Text 'Copilotへ送る本文（同上）。' -Settings $settings -Direction 'to_en'
$projectWithMaskJson = ConvertTo-YakuCatProjectJson -Project $projectWithMask
$projectZeroMaskJson = ConvertTo-YakuCatProjectJson -Project $projectZeroMask

$utf8 = New-Object System.Text.UTF8Encoding($false)
$projectWithMaskPath = Join-Path $tmp 'project-with-mask.json'
$projectZeroMaskPath = Join-Path $tmp 'project-zero-mask.json'
[IO.File]::WriteAllText($projectWithMaskPath, $projectWithMaskJson, $utf8)
[IO.File]::WriteAllText($projectZeroMaskPath, $projectZeroMaskJson, $utf8)
$observedPath = Join-Path $tmp 'observed.json'
$stderrPath = Join-Path $tmp 'node-stderr.txt'

$arguments = @($driver, (Join-Path $root 'www'), $projectWithMaskPath, $projectZeroMaskPath, $observedPath) | ForEach-Object { '"' + $_ + '"' }
$proc = Start-Process -FilePath $nodeExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
$nodeErr = ''
if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
Chk ([int]$proc.ExitCode -eq 0) ('運転席が走り切る' + $(if ($nodeErr) { ' / ' + $nodeErr.Substring(0, [Math]::Min(400, $nodeErr.Length)) } else { '' }))

$o = $null
if (Test-Path -LiteralPath $observedPath) { $o = [IO.File]::ReadAllText($observedPath, $utf8) | ConvertFrom-Json }
Chk ($null -ne $o) '画面で観測した事実を受け取れた'
if ($null -eq $o) { throw 'CAT_MASK_GATE_NO_OBSERVATION' }
Chk ([string]::IsNullOrEmpty([string]$o.fatal)) ('画面の操作が途中で止まっていない' + $(if ($o.fatal) { ' / ' + ([string]$o.fatal).Substring(0, [Math]::Min(400, ([string]$o.fatal).Length)) } else { '' }))
Chk (@($o.errors).Count -eq 0) ('ページ例外が無い（実測: ' + (($o.errors -join ' | ')) + '）')
Chk (@($o.console).Count -eq 0) ('console.error が無い（実測: ' + (($o.console -join ' | ')) + '）')

Chk ([string]::IsNullOrEmpty([string]$o.noticeBeforeTranslate)) '翻訳前は #cat-mask-notice が空（見た目にも場所を取らない）'
$expectedNonZero = '数値 3 件をマスクして送信しました。数値以外の文はマスクせずに送っています。'
Chk ([string]$o.noticeAfterTranslate -eq $expectedNonZero) ('翻訳が終わると件数が出る（実際: ' + [string]$o.noticeAfterTranslate + '）')
Chk ([bool]$o.confirmButtonFound) '確認ボタンが見つかる（前提条件）'
Chk ([string]$o.noticeAfterConfirm -eq $expectedNonZero) ('別の操作(行の確認)を挟んでも通知は消えない（実際: ' + [string]$o.noticeAfterConfirm + '）')
$expectedZero = 'この翻訳で外部へ送った数値はありません。数値以外の文はマスクせずに送っています。'
Chk ([string]$o.noticeZeroCase -eq $expectedZero) ('0件のときは明示の文言が出る（実際: ' + [string]$o.noticeZeroCase + '）')

if ($script:fail -eq 0) { Write-Host ('Test-YakuV9198CatMaskNotice: 検査 ' + $script:checks + ' 件、合格。') -ForegroundColor Green; exit 0 }
Write-Host ('Test-YakuV9198CatMaskNotice: 検査 ' + $script:checks + ' 件中 ' + $script:fail + ' 件が不合格。') -ForegroundColor Red
exit 1
