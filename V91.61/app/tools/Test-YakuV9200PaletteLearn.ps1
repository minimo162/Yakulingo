<#
.SYNOPSIS
  V92.00: パレットの学習ボタン(用語登録先行)の回帰試験。

.DESCRIPTION
  パレットで得た訳を1クリックで個人用語集へ登録する導線(構想図「学習」の
  前半、TM登録は後続に分離)を見る。見るのは3つ。

  (a) 静的部。palette.js/palette.css が、候補ごとの「覚える」釦・
      文っぽい原文の確認・二重送信ガード・button-in-buttonを避ける
      添え候補の包み方を持つことを字面(regex)で見る。

  (b) サーバ単体部。Server.ps1からInvoke-YakuRouteとConvert-YakuExceptionTo
      UserMessageを実物のままAST抽出し(写経しない)、実ストア(一時
      $env:YAKULINGO_DATA_DIR)へ対して/api/palette/term-learnを実際に
      叩く。
        - 検証: source/target 空・80字超・改行を含む で400、既存の
          term-add(Server.ps1)と同じ80文字/改行不可を境界値で見る
        - 正常系: Add-YakuTerminologyEntry(Terminology.ps1)へ実際に
          届き、personal scope・occurrence種・advisory(段落末尾の
          設計判断を参照)で保存されること。出典(origin_*)が32桁16進の
          project/segment idと'貼り付け資料'を持つこと
        - 直後にFind-YakuTerminologyMatches(即答が使う関数そのもの)で
          引けること(「登録した瞬間から即答に効く」の実体)
        - 同一source+target の再登録は status=unchanged で件数が
          増えないこと。同一source・別targetは status=added で
          共存すること(Add-YakuTerminologyEntryの契約どおり、
          上書きではなく別エントリになる)
        - directionを省略した場合はResolve-YakuDirectionDecisionで
          自動判定されること。クライアントが送ったdirectionが
          優先されること
        - 個人用語集の書き込み先が$env:YAKULINGO_DATA_DIR配下(ローカル)
          であること(共有フォルダへ書かない制約の実測)

  (c) 実機Chromium部。本物のpalette.html/js/cssを配り、TM候補・主訳・
      添え候補それぞれの「覚える」を実際に押す。POST本文・二重送信
      ガード・文っぽい原文での確認ダイアログ・即答欄が開いていれば
      再取得されること(閉じていれば再取得しないこと)・
      button-in-buttonを避けている(添え札のクリックで入れ替えが
      起きない)ことを実測する。480x640で主札が画面内に収まる
      (V9195の幾何ゲートを崩さない)ことも自前で測る。

      node/Playwright/Chromium が無い環境では緑にしない。終了コード3
      (未測定)で抜ける。「測れなかった」を赤に畳まない。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9200PaletteLearn.ps1
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

Write-Host 'Test-YakuV9200PaletteLearn'

$wwwDir = Join-Path $root 'www'
$paletteJsPath = Join-Path (Join-Path $wwwDir 'assets') 'palette.js'
$paletteCssPath = Join-Path (Join-Path $wwwDir 'assets') 'palette.css'

Chk (Test-Path -LiteralPath $paletteJsPath -PathType Leaf) 'www/assets/palette.js が存在する'
Chk (Test-Path -LiteralPath $paletteCssPath -PathType Leaf) 'www/assets/palette.css が存在する'

# ============================================================ (a) 静的部
Write-Host '-- (a) static --'

$paletteJs = [IO.File]::ReadAllText($paletteJsPath, [Text.UTF8Encoding]::new($false))
$paletteCss = [IO.File]::ReadAllText($paletteCssPath, [Text.UTF8Encoding]::new($false))

Chk ($paletteJs -match "/api/palette/term-learn") 'palette.js が学習APIを呼ぶ'
Chk ($paletteJs -match "data-yaku-term-learn") 'palette.js が学習釦の合図(data-yaku-term-learn)を持つ'
Chk ($paletteJs -match "term-learn-corner") 'palette.js がTM候補用の絶対配置釦(term-learn-corner)を持つ(高さを増やさない)'
Chk ($paletteJs -match "result-alt-shell") 'palette.js が添え札を器(result-alt-shell)で包む(button-in-button回避)'
Chk ($paletteJs -match "function looksLikeSentence") 'palette.js が「文っぽい」判定を持つ'
Chk ($paletteJs -match [regex]::Escape('文章そのものを用語として覚えます')) 'palette.js が文章確認の文言を持つ'
Chk ($paletteJs -match "window\.confirm\(") 'palette.js がwindow.confirmで確認する'
Chk ($paletteJs -match "shell\.appendChild\(altNode\)") 'palette.js は添え札(altNode)を器へ移すだけで、覚える釦を添え札の中には作らない(button-in-button回避の実体)'
Chk ($paletteJs -match "wireLearnButton[\s\S]{0,400}?event\.stopPropagation\(\)") '学習釦のクリックはevent.stopPropagationで、コピー/入れ替えへの伝播を止める'
Chk ($paletteJs -match "button\.disabled = true;[\s\S]{0,400}?YakuCommon\.post\('/api/palette/term-learn'") '学習釦は送信前にdisabledへする(連打・二重送信ガード)'
Chk ($paletteJs -match "TERM_LEARN_REFRESH_DELAY_MS") '学習成功後のinstant取り直しに遅延を持つ(「覚えました」を消す前に読めるように)'
Chk ($paletteJs -match "direction:\s*lastDirection") '学習リクエストが検出済みの方向(lastDirection)を送る(逆方向登録を避ける)'
Chk ($paletteJs -notmatch "TERM_LEARN_REFRESH_DELAY_MS = 0;") '取り直しの遅延が0固定(実質即時)ではない'

Chk ($paletteCss -match "\.term-learn-button\s*\{") 'palette.css が .term-learn-button を持つ'
Chk ($paletteCss -match "\.term-learn-corner") 'palette.css が絶対配置の釦位置を持つ'
Chk ($paletteCss -match "\.result-alt-shell") 'palette.css が添え札の器を持つ'
Chk ($paletteCss -match "#palette-tm-candidate\s*\{[^}]*position:\s*relative") 'palette.css がTM候補へposition:relativeを与える(絶対配置の基準)'
Chk ($paletteCss -match "\[data-yaku-main-card\]\s*\{[^}]*position:\s*relative") 'palette.css が主札へposition:relativeを与える'

# ============================================================ (b) サーバ単体部
Write-Host '-- (b) server --'

. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in @($script:YakuSrcModuleFiles)) {
    if ($name -ne 'DesktopIntegration.ps1') { . (Join-Path (Join-Path $root 'src') $name) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9200-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuRoot = $root

function Get-N9200FunctionText {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Language.ScriptBlockAst]$Ast, [Parameter(Mandatory=$true)][string]$Name)
    $found = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return $null }
    return [string]$found[0].Extent.Text
}

$serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
$tokens = $null; $parseErrors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrors)
Chk (@($parseErrors).Count -eq 0) 'Server.ps1 が構文エラー無く解析できる'

$routeFunctionText = Get-N9200FunctionText -Ast $serverAst -Name 'Invoke-YakuRoute'
Chk (-not [string]::IsNullOrWhiteSpace($routeFunctionText)) 'Server.ps1 から Invoke-YakuRoute を取り出せる'
$errorFunctionText = Get-N9200FunctionText -Ast $serverAst -Name 'Convert-YakuExceptionToUserMessage'
Chk (-not [string]::IsNullOrWhiteSpace($errorFunctionText)) 'Server.ps1 から Convert-YakuExceptionToUserMessage を取り出せる(実物の文言変換を使う)'

# 検証値そのものが term-add(3425行)と揃っていることを、抽出した実物の
# 関数テキストの中で見る(写経した数字ではなく、実際に効いている数字)。
Chk ($routeFunctionText -match "term-learn") '抽出した実物のInvoke-YakuRouteに/api/palette/term-learnの分岐が入っている'
Chk ($routeFunctionText -match "-gt 80[\s\S]{0,80}?-gt 80") '実物のterm-learn分岐が80文字を検証値に使っている(term-addと同じ値)'
Chk ($routeFunctionText -match "Kind='occurrence'") '実物のterm-learn分岐がKind=occurrenceで登録する(即答のFind-YakuTerminologyMatchesが拾える種)'
# 'advisory'という文字列だけを探すと、他の呼び出し(glossary-add等)にも
# 同じ文字列があり、そちらを誤って拾って緑になりかねない。term-learn分岐に
# 固有の Origin='palette-term-learn' の直前にあることまで見て、この分岐
# 自身の値であることを確かめる。
Chk ($routeFunctionText -match "Enforcement='advisory'[\s\S]{0,120}?Origin='palette-term-learn'") '実物のterm-learn分岐がEnforcement=advisoryで登録する(設計判断: requiredにすると無関係な別資料のCAT export が terminology-missing=error で止まるため)'
Chk ($routeFunctionText -match "MaxBytes 8192") '実物のterm-learn分岐のMaxBytesが8192(source/targetは80字以内なので十分な余裕)'

if ($routeFunctionText -and $errorFunctionText) {
    . ([scriptblock]::Create($routeFunctionText + "`n`n" + $errorFunctionText))
}

Set-Item -Path Function:Assert-YakuRequestBoundary -Value { param($Request, $Path, $Method) }
Set-Item -Path Function:Clear-YakuExpiredUploads -Value { param() }

$script:n9200SentText = ''
$script:n9200SentStatus = 200
Set-Item -Path Function:Send-YakuTextResponse -Value {
    param($Context, [string]$Text, [string]$ContentType = '', [int]$StatusCode = 200, [switch]$AllowWasm)
    $script:n9200SentText = $Text
    $script:n9200SentStatus = $StatusCode
}
$script:n9200Payload = @{}
Set-Item -Path Function:Read-YakuRequestJson -Value { param($Request, [int64]$MaxBytes = 0); return $script:n9200Payload }

$script:YakuLastUploadSweep = Get-Date

function Invoke-N9200TermLearn {
    param([hashtable]$Payload)
    $script:n9200Payload = $Payload
    $script:n9200SentText = ''
    $script:n9200SentStatus = 200
    $req = [pscustomobject]@{ Url = [uri]'http://127.0.0.1/api/palette/term-learn'; HttpMethod = 'POST'; Headers = @{} }
    $context = [pscustomobject]@{ Request = $req }
    Invoke-YakuRoute -Context $context
    $body = $null
    try { $body = $script:n9200SentText | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Status = $script:n9200SentStatus; Body = $body; Text = $script:n9200SentText }
}

# --- 検証: 空・長さ・改行 -------------------------------------------------
$rEmpty = Invoke-N9200TermLearn -Payload @{ source = '  '; target = '御社' }
Chk ($rEmpty.Status -eq 400) '原文が空なら400'
Chk ($null -ne $rEmpty.Body -and [string]$rEmpty.Body.error -match '原文と訳文') '空エラーの文言に「原文と訳文」が入る'
Chk ([string]$rEmpty.Body.error -notmatch '^PALETTE_TERM_EMPTY:') '利用者向け文言は生のエラーコードで始まらない(Convert-YakuExceptionToUserMessageが変換した実物)'
Chk ([string]$rEmpty.Body.error -match 'PALETTE_TERM_EMPTY') '問い合わせ番号としてコードは残る(末尾に付く実物の変換規則)'

$rTargetEmpty = Invoke-N9200TermLearn -Payload @{ source = '御社'; target = '   ' }
Chk ($rTargetEmpty.Status -eq 400) '訳文が空なら400(target検証)'

$longOk = 'A' * 80
$longNg = 'A' * 81
$rTooLong = Invoke-N9200TermLearn -Payload @{ source = $longNg; target = '訳' }
Chk ($rTooLong.Status -eq 400 -and [string]$rTooLong.Body.error -match '80文字') '81字は80文字以内エラー(term-addと同じ境界値)'

$rBoundaryOk = Invoke-N9200TermLearn -Payload @{ source = $longOk; target = $longOk; direction = 'to_en' }
Chk ($rBoundaryOk.Status -eq 200 -and [bool]$rBoundaryOk.Body.ok) 'ちょうど80字は通る(境界値、term-addと同じ)'

$rNewline = Invoke-N9200TermLearn -Payload @{ source = "御社`nの"; target = '訳' }
Chk ($rNewline.Status -eq 400 -and [string]$rNewline.Body.error -match '改行') '原文に改行を含むと400'

# --- 正常系: 実ストアへ届く・出典・Kind/Enforcement ------------------------
$sourceJa = '御社サンプル用語'
$targetEn = 'your sample term'
$rAdd = Invoke-N9200TermLearn -Payload @{ source = $sourceJa; target = $targetEn }
Chk ($rAdd.Status -eq 200 -and [bool]$rAdd.Body.ok -and [string]$rAdd.Body.status -eq 'added') '方向省略でも登録できる(status=added)'
Chk ([string]$rAdd.Body.term_id -match '^[a-f0-9]{32}$') '応答のterm_idが32桁16進'

$entries = @(Read-YakuPersonalTerminologyEntries)
$stored = @($entries | Where-Object { [string]$_.ja.preferred -eq $sourceJa -and [string]$_.en.preferred -eq $targetEn })
Chk ($stored.Count -eq 1) '個人用語集(実ストア)へ1件だけ届いている'
if ($stored.Count -eq 1) {
    $e = $stored[0]
    Chk ([string]$e.scope -eq 'personal') 'scope=personal'
    Chk ([string]$e.kind -eq 'occurrence') 'kind=occurrence(即答のFind-YakuTerminologyMatchesが拾う種)'
    Chk ([string]$e.enforcement -eq 'advisory') 'enforcement=advisory(設計判断、CATのterm-add既定requiredとは意図して変えた)'
    Chk ([string]$e.origin -eq 'palette-term-learn') "origin='palette-term-learn'"
    Chk ([string]$e.origin_file_name -eq '貼り付け資料') "origin_file_name='貼り付け資料'(CATのglossary-add同様、実ファイルが無い題材の既存語をそのまま使う)"
    Chk ([string]$e.origin_project_id -match '^[a-f0-9]{32}$') 'origin_project_idが32桁16進(New-YakuTerminologyEntryの必須形式を満たす固定値)'
    Chk ([string]$e.origin_segment_id -match '^[a-f0-9]{32}$') 'origin_segment_idが32桁16進(原文ハッシュから作る、TM試験と同じ手口)'
    Chk ($e.active -eq $true) 'active=true'
}

# 「登録した瞬間から即答に効く」の実体: 即答が使う関数そのもので引ける。
$matches1 = @(Find-YakuTerminologyMatches -Text $sourceJa -Direction 'to_en' -Entries (Read-YakuPersonalTerminologyEntries) -ProjectId '')
$hit = @($matches1 | Where-Object { [string]$_.PreferredTarget -eq $targetEn })
Chk ($hit.Count -ge 1) '登録した用語が Find-YakuTerminologyMatches (即答と同じ関数)で実際に引ける'

# --- 重複: 同一source+target は unchanged、同一source・別targetは共存 -----
$rDup = Invoke-N9200TermLearn -Payload @{ source = $sourceJa; target = $targetEn }
Chk ($rDup.Status -eq 200 -and [string]$rDup.Body.status -eq 'unchanged') '同じsource+targetの再登録はstatus=unchanged'
$entriesAfterDup = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq $sourceJa })
Chk ($entriesAfterDup.Count -eq 1) '同じ内容の再登録では件数が増えない'

$targetEn2 = 'your sample term (v2)'
$rSecond = Invoke-N9200TermLearn -Payload @{ source = $sourceJa; target = $targetEn2 }
Chk ($rSecond.Status -eq 200 -and [string]$rSecond.Body.status -eq 'added') '同じsource・別targetはstatus=added(上書きではない、Add-YakuTerminologyEntryの契約どおり)'
$entriesAfterSecond = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq $sourceJa })
Chk ($entriesAfterSecond.Count -eq 2) '同じsourceで2件が共存する(既存関数の契約を正直に反映、UIへの独自の統合はしない)'

# --- direction: 省略時は自動判定、明示時はそれを優先 ------------------------
$rAutoJa = Invoke-N9200TermLearn -Payload @{ source = '為替レート変動'; target = 'foreign exchange rate fluctuation' }
$entryAuto = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq '為替レート変動' })
Chk ($entryAuto.Count -eq 1 -and [string]$entryAuto[0].en.preferred -eq 'foreign exchange rate fluctuation') 'directionを省略すると自動判定で日本語→英語に格納される(Resolve-YakuDirectionDecision実物を通す)'

$rExplicitJp = Invoke-N9200TermLearn -Payload @{ source = 'Report'; target = '報告書'; direction = 'to_jp' }
$entryExplicit = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.en.preferred -eq 'Report' -and [string]$_.ja.preferred -eq '報告書' })
Chk ($entryExplicit.Count -eq 1) '明示したdirection(to_jp)が優先され、英語→日本語として格納される'

# --- 保存先はローカル(共有フォルダへ書かない) ------------------------------
$storePath = Get-YakuPersonalTerminologyPath
Chk ($storePath.StartsWith($env:YAKULINGO_DATA_DIR, [StringComparison]::OrdinalIgnoreCase)) '個人用語集の書き込み先が $env:YAKULINGO_DATA_DIR 配下(この試験ではローカル一時領域、本番はユーザープロファイル)'
Chk (Test-Path -LiteralPath $storePath -PathType Leaf) '実際にファイルが作られている'
Chk (-not ($storePath -match '^\\\\')) '書き込み先がUNC(共有フォルダ)ではない'

# ============================================================ (c) 実機Chromium部
Write-Host '-- (c) chromium --'

$driver = Join-Path (Join-Path $toolsRoot 'palette-screen') 'palette-learn-gate.js'
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) {
    Write-Host ('UNMEASURED: 運転席がありません: ' + $driver) -ForegroundColor Red
    if ($script:fail -gt 0) { exit 1 }
    exit $YAKU_SCREEN_UNMEASURED
}

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

$work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9200-chromium-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$outJson = Join-Path $work 'out.json'
$stderrPath = Join-Path $work 'node-stderr.txt'
$proc = Start-Process -FilePath $nodeExe -ArgumentList @($driver, $wwwDir, $outJson) -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
$nodeErr = ''
if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
Chk ([int]$proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $outJson -PathType Leaf)) ('Chromiumドライバが完走し、観察結果を書き出した' + $(if ($nodeErr) { ' / ' + $nodeErr.Substring(0, [Math]::Min(400, $nodeErr.Length)) } else { '' }))

$o = $null
if (Test-Path -LiteralPath $outJson -PathType Leaf) { $o = Get-Content -LiteralPath $outJson -Raw -Encoding UTF8 | ConvertFrom-Json }
Chk ($null -ne $o) '画面で観測した事実を受け取れた'
if ($null -eq $o) { throw 'PALETTE_LEARN_GATE_NO_OBSERVATION' }

Chk (@($o.errors).Count -eq 0) ('実機ページでJSエラーが出ない(実測: ' + (($o.errors -join ' | ')) + ')')
$unexpectedConsole = @($o.console | Where-Object { $_ -notmatch 'Failed to load resource:.*400' })
Chk ($unexpectedConsole.Count -eq 0) ('実機ページでconsole.errorが出ない(意図した400は除外済み。実測: ' + (($unexpectedConsole -join ' | ')) + ')')

Write-Host '  -- シナリオ1: TM候補の「覚える」 --'
Chk ([bool]$o.tmLearnButtonExists) 'TM候補に「覚える」釦が現れる'
Chk ([bool]$o.tmLearnButtonIsCorner) 'TM候補の釦は絶対配置(term-learn-corner、高さを増やさない)'
Chk (@($o.confirmCallsForSentenceSource).Count -eq 1) '句点を含む原文では確認ダイアログが1回出る'
Chk ([int]$o.copiedAfterTmLearnClick -eq 0) '「覚える」を押してもクリップボードは変わらない(コピーへ伝播していない)'
Chk ([int]$o.tmLearnRequestCountAfterClick -eq 1) 'term-learnへの送信は1回'
Chk ($null -ne $o.tmLearnRequestBody -and [string]$o.tmLearnRequestBody.target -match 'TM memory phrase') '送信本文のtargetがTM候補のテキスト'
Chk ([string]$o.tmLearnRequestBody.direction -eq 'to_en') '送信本文のdirectionが検出済みの方向(to_en)'
Chk ([int]$o.instantRequestCountRightAfterTmLearn -eq 1) '登録直後(取り直しの遅延が明けるまで)はinstantを再送していない'
Chk ([string]$o.tmLearnButtonTextAfterSuccess -eq '覚えました') '登録成功の表示(「覚えました」)を、取り直しで消える前に読める'
Chk ([int]$o.instantRequestCountAfterTmLearnDelay -eq 2) '遅延が明けると即答欄をもう一度取り直す(即効性の見える化)'

Write-Host '  -- シナリオ2/3: 主訳・添え候補の「覚える」 --'
Chk ([bool]$o.mainLearnButtonExists) '主訳にも「覚える」釦がある'
Chk ([bool]$o.altLearnButtonExists) '添え候補にも「覚える」釦がある'
Chk ([bool]$o.altLearnButtonIsSiblingNotChild) '添え候補の学習釦は添え札(button)の子孫ではない(button-in-button回避の実測)'
Chk ([int]$o.copiedAfterMainLearnClick -eq 0) '主訳の「覚える」を押してもコピーへは伝播しない'
Chk ($null -ne $o.mainLearnRequestBody -and [string]$o.mainLearnRequestBody.target -match 'Revenue was') '主訳の送信本文targetが主訳のテキスト'
Chk ([int]$o.instantRequestCountAfterMainLearnDelay -eq [int]$o.instantRequestCountRightAfterMainLearn + 1) '主訳の学習成功後も、即答欄が開いていれば取り直す(TM候補限定の配線ではない)'
Chk ([int]$o.copiedAfterAltLearnClick -eq 0) '添え候補の「覚える」を押してもコピーへは伝播しない'
Chk ([bool]$o.mainTextUnchangedAfterAltLearn) '添え候補の「覚える」を押しても入れ替え(swap)は起きない'
Chk ($null -ne $o.altLearnRequestBody -and [string]$o.altLearnRequestBody.target -match 'Sales reached') '添え候補の送信本文targetが添え候補のテキスト'

Chk ($null -ne $o.geometryAfterAllLearnClicks.main -and [double]$o.geometryAfterAllLearnClicks.main.bottom -le ([double]$o.geometryAfterAllLearnClicks.footer.top + 2)) '3つとも押した後も、主札は帯(footer)に隠れていない(480x640、幾何ゲートを崩していない)'

Write-Host '  -- シナリオ4/4.5/5: 文っぽい判定・確認の可否・重複表示 --'
Chk (@($o.confirmCallsForShortSource).Count -eq 0) '短い語句(句点なし・40字以下)では確認ダイアログを出さない'
Chk ([string]$o.tmLearnButtonTextAfterUnchanged -eq '登録済みです') '既に同じ内容がある応答(unchanged)は、addedとは違う文言で表示する'
Chk (@($o.confirmCallsForDeclinedSentence).Count -eq 1) '文っぽい原文では確認ダイアログが出る(いいえのケース)'
Chk ([int]$o.learnRequestCountAfterDecline -eq 0) '確認で「いいえ」を選ぶと送信しない'

Write-Host '  -- シナリオ6: 即答欄が閉じていれば取り直さない --'
Chk ([bool]$o.instantHiddenWhenNoTmNoTerms) 'TMも用語も無ければ即答欄は閉じたまま(hidden=true)'
Chk ([int]$o.instantRequestDeltaWhenClosedAfterLearn -eq 0) '即答欄が閉じているときは、学習成功後もinstantを再送しない'

Write-Host '  -- シナリオ7: 二重送信ガード --'
Chk ([bool]$o.learnButtonDisabledRightAfterFirstClick) '1回目のクリック直後、その候補の「覚える」はdisabledになる'
Chk ([int]$o.learnRequestCountAfterDoubleClick -eq 1) '連続でクリックしても送信は1回だけ'

Write-Host '  -- シナリオ8: 失敗応答 --'
Chk ([string]$o.tmLearnButtonTextAfterFailure -eq 'テスト用の失敗です。') '失敗時はサーバの文言を釦に短く表示する'
Chk (-not [bool]$o.tmLearnButtonDisabledAfterFailure) '失敗後は押し直せる(disabledのままにしない)'

Write-Host ''
if ($script:fail -eq 0) { Write-Host ('Test-YakuV9200PaletteLearn: 検査 ' + $script:checks + ' 件、合格。') -ForegroundColor Green; exit 0 }
Write-Host ('Test-YakuV9200PaletteLearn: 検査 ' + $script:checks + ' 件、' + $script:fail + ' 件不合格。') -ForegroundColor Red
exit 1
