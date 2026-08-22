<#
.SYNOPSIS
  V92.00: パレットの学習ボタン(用語登録先行)の回帰試験。

.DESCRIPTION
  パレットで得た訳を1クリックで個人用語集へ登録する導線(構想図「学習」の
  前半、TM登録は後続に分離)を見る。見るのは3つ。

  (a) 静的部。palette.js/palette.css が、候補ごとの「覚える」釦・
      文っぽい原文の確認・二重送信ガード・button-in-buttonを避ける
      添え候補の包み方を持つことを字面(regex)で見る。「文っぽい」の
      半角ピリオド判定が単語境界からの小文字2文字以上＋空白/終端限定に
      絞られていること('U.S.'等の略語で誤爆しないこと、CoD審査
      REWORK-1 MINOR-D)も見る。

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
          増えないこと。同一source・別targetは status=conflict-added
          で共存すること(Add-YakuTerminologyEntryの契約どおり、
          上書きではなく別エントリになる。この場合の即答の勝者は登録順
          では決まらないので、その旨の文言を返すこと。CoD審査 REWORK-1
          MAJOR-2)
        - directionを省略した場合はResolve-YakuDirectionDecisionで
          自動判定されること。クライアントが送ったdirectionが
          優先されること
        - 個人用語集の書き込み先が$env:YAKULINGO_DATA_DIR配下(ローカル)
          であること(共有フォルダへ書かない制約の実測)
        - advisoryの効能表示の正確さ: advisoryが避けるのは
          terminology-missing=errorだけで、personal用語集への書き込みは
          advisory/requiredを問わずGet-YakuTerminologySnapshotHash経由で
          無関係な別資料のsegment-qc-not-currentを引き起こす(既存の欠陥、
          _docs/欠陥記録_用語スナップショットの粒度_2026-08-19.md参照)。
          この試験はコードの文言がその欠陥を「無いこと」にしていないかを
          字面で見る(CoD審査 REWORK-1 MAJOR-1)

  (c) 実機Chromium部。本物のpalette.html/js/cssを配り、TM候補・主訳・
      添え候補それぞれの「覚える」を実際に押す。POST本文・二重送信
      ガード・文っぽい原文での確認ダイアログ('U.S.'では出ないこと、
      MINOR-D)・即答欄が開いていれば再取得されること(閉じていれば
      再取得しないこと)・button-in-buttonを避けている(添え札の
      クリックで入れ替えが起きない)ことを実測する。480x640で主札が
      画面内に収まる(V9195の幾何ゲートを崩さない)ことも自前で測る。
      釦自体は短い状態語だけを示し、詳細な文言(登録成功/重複/衝突/
      失敗)は帯の共有行(#palette-copy-status)へ全文が出ること
      (MINOR-A/B)、成功/失敗どちらの表示もしばらくすると既定の
      「覚える」へ戻ること(MINOR-C、主訳・添え候補は次の翻訳まで
      DOMが作り直されないため)も実測する。ジョブ完了直後(何も押して
      いない時点)の主札が、premium画面の長さ設定によって黙って添え札と
      入れ替わっていないこと(無言スワップのピン、issue #104)も見る。

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
Chk ($paletteJs -match "TERM_LEARN_REFRESH_DELAY_MS") '学習成功後のinstant取り直しに遅延を持つ(取り直しで結果表示を消す前に読めるように)'
Chk ($paletteJs -match "direction:\s*lastDirection") '学習リクエストが検出済みの方向(lastDirection)を送る(逆方向登録を避ける)'
Chk ($paletteJs -notmatch "TERM_LEARN_REFRESH_DELAY_MS = 0;") '取り直しの遅延が0固定(実質即時)ではない'
# CoD審査 REWORK-1 MINOR-A/B: 釦自体の文言は短い状態語だけにし、サーバの
# 詳細な文言(重複の案内・エラー本文)は帯の共有行(#palette-copy-status、
# コピー結果と同じ場所)へ出す。釦の中に長い文言を直接書き込まないこと。
Chk ($paletteJs -match "function setCopyStatusLine") 'palette.js が学習の詳細文言(と色)を専用の関数経由で帯へ出す(REWORK-2で setTermLearnStatusLine から改名・一般化)'
Chk ($paletteJs -match "setCopyStatusLine[\s\S]{0,40}?el\('palette-copy-status'\)") '学習の詳細文言は#palette-copy-status(帯の共有行)へ出す(MINOR-B)'
Chk ($paletteJs -notmatch "message\.substring\(0,\s*12\)") '釦へエラー文言を12字で切り詰める古い実装が残っていない(MINOR-B、帯が全文を見せる)'
Chk ($paletteJs -match "data\.message[\s\S]{0,10}?\|\|") '学習成功時はサーバが返したmessageをそのまま帯へ出す(status別の文言をJS側で決め打ちしない、MAJOR-2)'
Chk ($paletteJs -match "TERM_LEARN_RESTORE_DELAY_MS") '学習結果の表示から既定文言(「覚える」)へ戻す遅延を持つ(MINOR-C)'
Chk ($paletteJs -match "'済み'[\s\S]{0,200}?TERM_LEARN_RESTORE_DELAY_MS") '成功表示も失敗と同じ復帰の仕組みで「覚える」へ戻る(MINOR-C: 主訳・添え候補は次の翻訳までDOMが作り直されないため、放置すると押せる状態のまま残る)'
Chk ($paletteJs -match "'エラー'[\s\S]{0,200}?TERM_LEARN_RESTORE_DELAY_MS") '失敗表示も同じ仕組みで「覚える」へ戻る'
# CoD審査 REWORK-1 MINOR-D: 'U.S.'・'Ltd.'・'No.1'のような略語で
# 確認ダイアログを誤爆しない絞り込み(単語境界からの小文字2文字以上＋
# 空白/終端限定)を持つこと。
Chk ($paletteJs -match '\\b\[a-z\]\{2,\}\\\.') 'palette.js の英語終止符判定が単語境界からの小文字2文字以上に絞られている(MINOR-D)'
# CoD審査 REWORK-2 NEW-3: 色はkind('error'/'warning'/既定=success)で決め、
# 呼ぶたびにis-error/is-warningを付け直す(前回の色が残らない)。
Chk ($paletteJs -match "classList\.remove\('is-error', 'is-warning'\)") 'setCopyStatusLineが呼ぶたびに前回の色クラスを外す(色が残留しない、NEW-3)'
Chk ($paletteJs -match "kind === 'error'[\s\S]{0,40}?is-error") "kind='error'でis-errorクラスを付ける(NEW-3)"
Chk ($paletteJs -match "kind === 'warning'[\s\S]{0,40}?is-warning") "kind='warning'でis-warningクラスを付ける(NEW-3)"
Chk ($paletteJs -match "'conflict-added'[\s\S]{0,40}?'unchanged-conflict'[\s\S]{0,60}?'warning'") 'conflict-added/unchanged-conflictはkind=warningになる(NEW-3/NEW-4)'
Chk ($paletteJs -match "function copyCandidate[\s\S]{0,300}?setCopyStatusLine\([\s\S]{0,200}?ok \? 'success' : 'error'") 'copyCandidateの失敗(コピーできませんでした)もkind=errorで帯へ出す(NEW-3、既存の穴を塞ぐ)'
# CoD審査 REWORK-2 NEW-2: 帯が伸びて主札/TM候補の下端を隠す実測(空文字
# 0.25px・単純な成功文言5.73px・衝突文言29.66px)への対処として、文言確定の
# 直後にrevealMainResult()をもう一度呼ぶこと(伸びた後の帯の高さで寄せ直す)。
Chk ($paletteJs -match "setCopyStatusLine\([\s\S]{0,300}?revealMainResult\(\);[\s\S]{0,400}?TERM_LEARN_RESTORE_DELAY_MS") 'sendTermLearnの成功パスがsetCopyStatusLineの直後にrevealMainResult()を呼び直す(NEW-2)'
Chk (@([regex]::Matches($paletteJs, 'revealMainResult\(\);')).Count -ge 3) 'revealMainResult()の呼び出しが増えている(既存2箇所+学習の成功/失敗2箇所、NEW-2)'

Chk ($paletteCss -match "\.term-learn-button\s*\{") 'palette.css が .term-learn-button を持つ'
Chk ($paletteCss -match "\.term-learn-corner") 'palette.css が絶対配置の釦位置を持つ'
Chk ($paletteCss -match "\.result-alt-shell") 'palette.css が添え札の器を持つ'
Chk ($paletteCss -match "#palette-tm-candidate\s*\{[^}]*position:\s*relative") 'palette.css がTM候補へposition:relativeを与える(絶対配置の基準)'
Chk ($paletteCss -match "\[data-yaku-main-card\]\s*\{[^}]*position:\s*relative") 'palette.css が主札へposition:relativeを与える'
# CoD審査 REWORK-1 MINOR-A: 圧縮時カード(実測43.3px高)へ既定の
# min-height:44px(styles.css、タッチ目標)をそのまま使うと、絶対配置の
# 釦がカードの下端を実測7.7pxはみ出していた。この釦だけ明示的に
# min-heightを44pxより下げていることを見る(理由はCSSコメントに明記済み)。
Chk ($paletteCss -match "term-learn-corner[\s\S]{0,600}?min-height:\s*3[0-9]px") 'palette.css がTM候補の絶対配置釦のmin-heightを44pxより下げている(MINOR-A、圧縮時カードの高さに収めるため)'
# CoD審査 REWORK-2 NEW-2: .palette-copy-statusのmin-heightを1行の実測分まで
# 広げている(1.2em→1.7em、空文字→1行の遷移で帯が伸びない)。
Chk ($paletteCss -match "\.palette-copy-status\s*\{[^}]*min-height:\s*1\.[5-9]em") 'palette.css の.palette-copy-statusが1行ぶんのmin-height(1.5em以上)を確保している(NEW-2)'
Chk ($paletteCss -notmatch "\.palette-copy-status\s*\{[^}]*min-height:\s*1\.2em") '.palette-copy-statusのmin-heightが1.2em(空文字相当)のまま据え置かれていない(NEW-2)'
# CoD審査 REWORK-2 NEW-3: styles.css:241 .cat-save-status.is-errorと同じ
# 流儀(is-error/is-warning修飾クラス)を持つこと。
Chk ($paletteCss -match "\.palette-copy-status\.is-error\s*\{[^}]*color:\s*var\(--error\)") 'palette.css が.palette-copy-status.is-errorでvar(--error)を使う(NEW-3)'
Chk ($paletteCss -match "\.palette-copy-status\.is-warning\s*\{[^}]*color:\s*var\(--warning\)") 'palette.css が.palette-copy-status.is-warningでvar(--warning)を使う(NEW-3)'

# ============================================================ (b) サーバ単体部
Write-Host '-- (b) server --'

. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in @($script:YakuSrcModuleFiles)) {
    . (Join-Path (Join-Path $root 'src') $name)
}

# CoD審査 REWORK-1 NIT-B: $env:YAKULINGO_DATA_DIR はプロセス全体に効く。
# 退避せずに書き換えると、同じプロセスで動く他の試験・後続処理を汚したまま
# 終わりうる。ここで元の値を控え、(b)を抜けるとき(finallyブロック)に
# 必ず戻す。一時フォルダも同様に、使い終わったら消す(残置しない)。
$originalDataDirEnv = $env:YAKULINGO_DATA_DIR
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9200-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuRoot = $root

try {

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

# 検証値そのものが、CATのterm-add操作(/api/cat/のアクションswitchにある
# 'term-add')と揃っていることを、抽出した実物の関数テキストの中で見る
# (写経した数字ではなく、実際に効いている数字)。行番号では引かない
# ——term-add側の行はこの塊への追記だけで簡単にずれる(CoD審査 REWORK-1
# NIT-A)。
Chk ($routeFunctionText -match "term-learn") '抽出した実物のInvoke-YakuRouteに/api/palette/term-learnの分岐が入っている'
Chk ($routeFunctionText -match "-gt 80[\s\S]{0,80}?-gt 80") '実物のterm-learn分岐が80文字を検証値に使っている(term-addと同じ値)'
Chk ($routeFunctionText -match "Kind='occurrence'") '実物のterm-learn分岐がKind=occurrenceで登録する(即答のFind-YakuTerminologyMatchesが拾える種)'
# 'advisory'という文字列だけを探すと、他の呼び出し(glossary-add等)にも
# 同じ文字列があり、そちらを誤って拾って緑になりかねない。term-learn分岐に
# 固有の Origin='palette-term-learn' の直前にあることまで見て、この分岐
# 自身の値であることを確かめる。
#
# CoD審査 REWORK-1 MAJOR-1: advisoryが実際に避けるのは
# terminology-missing=errorだけである。「無関係な別資料のCAT exportは
# 影響を受けない」という趣旨の断定はここでは確かめない——それは事実に
# 反する(personal用語集への書き込みはadvisory/requiredを問わず
# segment-qc-not-currentを無関係な別資料へ引き起こす、実測。
# _docs/欠陥記録_用語スナップショットの粒度_2026-08-19.md参照)。
Chk ($routeFunctionText -match "Enforcement='advisory'[\s\S]{0,120}?Origin='palette-term-learn'") '実物のterm-learn分岐がEnforcement=advisoryで登録する(設計判断: 避けるのはterminology-missing=errorだけ)'
Chk ($routeFunctionText -match "segment-qc-not-current") 'advisoryの註が、segment-qc-not-currentへは効かないことを名指ししている(MAJOR-1、効能を誇張しない)'
Chk ($routeFunctionText -match "Get-YakuTerminologySnapshotHash") 'advisoryの註が、欠陥の出どころ(Get-YakuTerminologySnapshotHash)を名指ししている(MAJOR-1)'
Chk ($routeFunctionText -notmatch [regex]::Escape('Test-YakuV9195Palette.ps1:278')) '自分自身の試験(Test-YakuV9195Palette.ps1)を「実績」として引用していない(CLAUDE.md「自分が書いた文を要件として引用しない」、MAJOR-1(d))'
# CoD審査 REWORK-2 NEW-1: 「CATのterm-add/glossary-addアクションはEnforcement=
# required固定」は半分だけ嘘だった——term-add(Kind=occurrence)はrequired固定
# だが、glossary-add(Kind=cell_exact)は既にpersonal scope+advisoryである。
# しかもglossary-addのpersonal+advisoryこそ、この経路の選択が倣うべき
# 製品内の先例だった(捨てた自分の試験の代わりに引くべきだったもの)。
Chk ($routeFunctionText -notmatch [regex]::Escape('term-add/glossary-addアクションはEnforcement=required固定')) '「term-add/glossary-addは両方required固定」という誤った一括りの文言が残っていない(NEW-1)'
Chk ($routeFunctionText -match "term-addアクション[\s\S]{0,40}?Enforcement=[\s\S]{0,20}?required固定") 'term-addアクションはEnforcement=required固定だと正しく書かれている(NEW-1)'
Chk ($routeFunctionText -match "glossary-add[\s\S]{0,140}?personal scope\+advisory") 'glossary-addアクションが既にpersonal scope+advisoryであると書かれている(NEW-1)'
Chk ($routeFunctionText -match "先例") 'glossary-addの先例に倣ったことが書かれている(発明ではないことを示す、NEW-1)'
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
# CoD審査 REWORK-1 MAJOR-2: 同じsourceに別のtargetが既にある場合、上書きは
# しない(データを失わない)が、「次から同じ訳が出ます」は嘘になりうる——
# 即答(Find-YakuTerminologyMatches)がどちらを返すかは登録順で決まらない
# (全候補が同点のときの並べ替えがterm_id(GUID)の大小勝負になるため、
# 実測12組でfirstWins=4/secondWins=8)。ここではstatus=conflict-addedを
# 返し、正直な文言(「次から同じ訳が出ます」ではない)を返すことを見る。
Chk ($rSecond.Status -eq 200 -and [string]$rSecond.Body.status -eq 'conflict-added') '同じsource・別targetはstatus=conflict-added(上書きではない、Add-YakuTerminologyEntryの契約どおり共存する)'
Chk ([string]$rSecond.Body.message -notmatch '次から同じ訳が出ます') '重複時の文言は「次から同じ訳が出ます」という単純な成功文言ではない(嘘をつかない)'
Chk ([string]$rSecond.Body.message -match '登録の順番では決まりません|順番では決まりません') '重複時の文言が、どちらが出るかは登録順で決まらないことを案内する'
Chk ([string]$rSecond.Body.message -match '用語一覧') '重複時の文言が、古い方を取り消す先(用語一覧)を案内する'
$entriesAfterSecond = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq $sourceJa })
Chk ($entriesAfterSecond.Count -eq 2) '同じsourceで2件が共存する(既存関数の契約を正直に反映、UIへの独自の統合はしない、データを失わない)'

# 三重目(既存2件のうちどちらとも異なるtarget)も同じくconflict-addedになる
# こと(1件だけの特別扱いではないことを見る)。
$targetEn3 = 'your sample term (v3)'
$rThird = Invoke-N9200TermLearn -Payload @{ source = $sourceJa; target = $targetEn3 }
Chk ($rThird.Status -eq 200 -and [string]$rThird.Body.status -eq 'conflict-added') '3件目の別targetも同じくstatus=conflict-added'
$entriesAfterThird = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq $sourceJa })
Chk ($entriesAfterThird.Count -eq 3) '3件とも共存する'

# CoD審査 REWORK-2 NEW-4: 最初のtarget($targetEn)をもう一度そのまま送ると
# Add-YakuTerminologyEntryは完全一致(Added=false)を返す(unchanged)。しかし
# targetEn2・targetEn3が今もactiveで残っているので、「すでに同じ内容で
# 登録されています」だけでは、即答の勝者が登録順で決まらない事実を隠す。
$rUnchangedWithRival = Invoke-N9200TermLearn -Payload @{ source = $sourceJa; target = $targetEn }
Chk ($rUnchangedWithRival.Status -eq 200 -and [string]$rUnchangedWithRival.Body.status -eq 'unchanged-conflict') '別targetの既存語がactiveなまま残っているときの再登録はstatus=unchanged-conflict(NEW-4)'
Chk ([string]$rUnchangedWithRival.Body.message -match '登録の順番では決まりません|順番では決まりません') 'unchanged-conflictの文言も、勝者は登録順で決まらないことを案内する'
Chk ([string]$rUnchangedWithRival.Body.message -match '用語一覧') 'unchanged-conflictの文言も、古い方を消す先(用語一覧)を案内する'
$entriesAfterUnchangedConflict = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq $sourceJa })
Chk ($entriesAfterUnchangedConflict.Count -eq 3) 'unchanged-conflictでは件数が増えない(既存の完全一致のまま)'

# active=falseの既存語(取り消し済み)とは衝突しない――過去に消した訳と
# 同じ語を今度は別の訳で覚え直すのは、衝突ではなく通常の追加であるべき。
$sourceForInactive = '取り消し済み語のテスト'
$rInactiveSeed = Invoke-N9200TermLearn -Payload @{ source = $sourceForInactive; target = 'inactive seed target' }
$seedEntry = @(Read-YakuPersonalTerminologyEntries | Where-Object { [string]$_.ja.preferred -eq $sourceForInactive })[0]
$null = Disable-YakuTerminologyEntry -TermId ([string]$seedEntry.term_id) -OriginProjectId ([string]$seedEntry.origin_project_id) `
    -OriginFileName ([string]$seedEntry.origin_file_name) -OriginSegmentId ([string]$seedEntry.origin_segment_id) `
    -OriginLocation ([string]$seedEntry.origin_location) -OriginRevision 0
$rAfterInactive = Invoke-N9200TermLearn -Payload @{ source = $sourceForInactive; target = 'a different target after disable' }
Chk ([string]$rAfterInactive.Body.status -eq 'added') '取り消し済み(active=false)の既存語とは衝突しない(status=added、activeのみを見る)'

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

} finally {
    # CoD審査 REWORK-1 NIT-B: プロセス全体の環境変数を必ず元へ戻し、
    # 使った一時フォルダを残置しない。
    $env:YAKULINGO_DATA_DIR = $originalDataDirEnv
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

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

# 無言スワップのピン(ジョブ完了直後・未選択の状態)の判定基準は、ドライバが
# 既定で持つ題材の定数そのものを使う(試験側で文言を写経しない)。
$gateText = [IO.File]::ReadAllText($driver, [Text.UTF8Encoding]::new($false))
$n9200MainText = [regex]::Match($gateText, "const MAIN_TEXT = '([^']*)';").Groups[1].Value
$n9200AltText = [regex]::Match($gateText, "const ALT_TEXT = '([^']*)';").Groups[1].Value
$n9200DoneKind = [regex]::Match($gateText, "data-yaku-main-kind>([^<]+)<").Groups[1].Value

# CoD審査 REWORK-1 NIT-B: ここも一時フォルダを残置しない(try/finally)。
$work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9200-chromium-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
try {
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
# CoD審査 REWORK-1 MINOR-A/B: 釦自体は短い状態語だけ、詳細な文言は
# 帯の共有行(#palette-copy-status)へ出る。
Chk ([string]$o.tmLearnButtonTextAfterSuccess -eq '済み') '登録成功の表示(釦は短い「済み」)を、取り直しで消える前に読める'
Chk ([string]$o.tmLearnStatusLineAfterSuccess -eq '覚えました。次から同じ訳が出ます。') '登録成功の詳細な文言(サーバのmessage)が帯へ出る'
Chk ([string]$o.tmLearnStatusClassAfterSuccess -notmatch 'is-error') '成功時の帯にis-errorクラスが付かない(NEW-3)'
Chk ([string]$o.tmLearnStatusClassAfterSuccess -notmatch 'is-warning') '成功時の帯にis-warningクラスも付かない(NEW-3、既定の成功色のまま)'
Chk ([int]$o.instantRequestCountAfterTmLearnDelay -eq 2) '遅延が明けると即答欄をもう一度取り直す(即効性の見える化)'
# CoD審査 REWORK-2 NEW-2: 帯(footer)が空文字→1行の文言で伸びても、
# TM候補の下端が帯の裏へ沈んでいないこと(実測: 直す前は0.25px隠れていた)。
Chk ($null -ne $o.footerFitEmptyStatus -and [double]$o.footerFitEmptyStatus.clearance -ge -2) '即答のみの段階(帯は空文字)でもTM候補は帯に隠れていない(NEW-2の比較の基準)'
Chk ($null -ne $o.footerFitAfterTmSuccess -and [double]$o.footerFitAfterTmSuccess.clearance -ge -2) '登録成功で帯に1行の文言が入っても、TM候補は帯に隠れていない(NEW-2)'

Write-Host '  -- ジョブ完了直後の主札(無言スワップのピン、issue #104) --'
Chk (($n9200MainText -ne '') -and ($n9200AltText -ne '') -and ($n9200DoneKind -ne '')) 'ドライバの既定定数(MAIN_TEXT/ALT_TEXT/種別)を取り出せた(前提条件)'
Chk ([string]$o.mainPreTextAfterDone -eq $n9200MainText) 'ジョブ完了直後、主札の本文はCopilot訳そのもの(未選択での無言入れ替えが起きていない)'
Chk ([string]$o.mainKindAfterDone -eq $n9200DoneKind) 'ジョブ完了直後、主札の種別ラベルはdoneHtmlどおり(添え札の種別に化けていない)'
Chk ([string]$o.altSwapDecodedAfterDone -eq $n9200AltText) '添え札の入れ替えデータ(data-yaku-swap)を復号すると添え候補のテキスト'

Write-Host '  -- シナリオ2/3: 主訳・添え候補の「覚える」 --'
Chk ([bool]$o.mainLearnButtonExists) '主訳にも「覚える」釦がある'
Chk ([bool]$o.altLearnButtonExists) '添え候補にも「覚える」釦がある'
Chk ([bool]$o.altLearnButtonIsSiblingNotChild) '添え候補の学習釦は添え札(button)の子孫ではない(button-in-button回避の実測)'
Chk ([int]$o.copiedAfterMainLearnClick -eq 0) '主訳の「覚える」を押してもコピーへは伝播しない'
Chk ($null -ne $o.mainLearnRequestBody -and [string]$o.mainLearnRequestBody.target -match 'Revenue was') '主訳の送信本文targetが主訳のテキスト'
Chk ([string]$o.mainLearnButtonTextAfterSuccess -eq '済み') '主訳の登録成功表示も短い「済み」'
Chk ([string]$o.mainLearnStatusLineAfterSuccess -eq '覚えました。次から同じ訳が出ます。') '主訳の登録成功の詳細な文言も帯へ出る'
Chk ([string]$o.mainLearnStatusClassAfterSuccess -notmatch 'is-error|is-warning') '主訳の登録成功も帯の色は既定(成功色)のまま(NEW-3)'
# CoD審査 REWORK-2 NEW-2: 帯に文言が入っても、主訳(このシナリオでの主役)が
# 帯に隠れていないこと(実測: 直す前は5.73px隠れていた、既存のコピー結果
# 文言でも起きていた継承の欠陥)。
Chk ($null -ne $o.footerFitAfterMainSuccess -and [bool]$o.footerFitAfterMainSuccess.usedMain -and [double]$o.footerFitAfterMainSuccess.clearance -ge -2) '主訳の登録成功で帯に文言が入っても、主訳は帯に隠れていない(NEW-2)'
Chk ([int]$o.instantRequestCountAfterMainLearnDelay -eq [int]$o.instantRequestCountRightAfterMainLearn + 1) '主訳の学習成功後も、即答欄が開いていれば取り直す(TM候補限定の配線ではない)'
# CoD審査 REWORK-1 MINOR-C: 主訳・添え候補は次の翻訳が始まるまでDOMが
# 作り直されないため、復帰の仕組みが無いと「済み」のまま残り続けていた。
Chk ([string]$o.mainLearnButtonTextAfterRestore -eq '覚える') '主訳の学習釦は、しばらくすると既定の「覚える」へ戻る(MINOR-C、押しっぱなしの表示のまま残らない)'
Chk ([int]$o.copiedAfterAltLearnClick -eq 0) '添え候補の「覚える」を押してもコピーへは伝播しない'
Chk ([bool]$o.mainTextUnchangedAfterAltLearn) '添え候補の「覚える」を押しても入れ替え(swap)は起きない'
Chk ($null -ne $o.altLearnRequestBody -and [string]$o.altLearnRequestBody.target -match 'Sales reached') '添え候補の送信本文targetが添え候補のテキスト'

Chk ($null -ne $o.geometryAfterAllLearnClicks.main -and [double]$o.geometryAfterAllLearnClicks.main.bottom -le ([double]$o.geometryAfterAllLearnClicks.footer.top + 2)) '3つとも押した後も、主札は帯(footer)に隠れていない(480x640、幾何ゲートを崩していない)'

Write-Host '  -- シナリオ4/4.5/4.6/4.65/4.7/5: 文っぽい判定・確認の可否・重複/衝突表示 --'
Chk (@($o.confirmCallsForShortSource).Count -eq 0) '短い語句(句点なし・40字以下)では確認ダイアログを出さない'
# CoD審査 REWORK-2 NOTE-6: MINOR-A(丸1)を今後の文言変更でも機械的に検知
# できるよう、4つの状態(覚える/登録中/済み/エラー)ぶんの釦とTM候補カードの
# 重なり/はみ出しを実測でピンする。overhang>0なら釦がカードの下端をはみ出す、
# overlap>0なら候補本文と釦が重なる——どちらも0以下でなければならない。
function Test-N9200ButtonFit {
    param([string]$Label, $Geo)
    Chk ($null -ne $Geo) ($Label + ': 釦とカードの矩形を測れている(前提条件)')
    if ($null -eq $Geo) { return }
    Chk ([double]$Geo.overhang -le 0.5) ($Label + ': 釦がカードの下端をはみ出していない(overhang=' + [string]$Geo.overhang + ')')
    Chk ([double]$Geo.overlap -le 0.5) ($Label + ': 釦が候補本文と重なっていない(overlap=' + [string]$Geo.overlap + ')')
}
Test-N9200ButtonFit -Label '覚える(idle)' -Geo $o.buttonFitIdle
Test-N9200ButtonFit -Label '登録中(pending)' -Geo $o.buttonFitPending
Test-N9200ButtonFit -Label '済み(success)' -Geo $o.buttonFitSuccess
Chk ([string]$o.tmLearnButtonTextAfterUnchanged -eq '済み') '既に同じ内容がある応答(unchanged)も釦は短い「済み」'
Chk ([string]$o.tmLearnStatusLineAfterUnchanged -eq 'すでに同じ内容で登録されています。') 'unchangedの詳細な文言(addedとは異なる)が帯へ出る'
Chk ([string]$o.tmLearnStatusClassAfterUnchanged -notmatch 'is-error|is-warning') 'unchangedの帯の色も既定(成功色)のまま(NEW-3、衝突していない通常のunchanged)'
# CoD審査 REWORK-1 MAJOR-2: 同じ語に別の訳が既にある場合(conflict-added)。
# 単純な成功文言を出さない(即答の勝者は登録順で決まらないため嘘になる)。
Chk ([string]$o.tmLearnButtonTextAfterConflict -eq '済み') '衝突登録(conflict-added)も釦は短い「済み」'
Chk ([string]$o.tmLearnStatusLineAfterConflict -notmatch '^覚えました。次から同じ訳が出ます。$') '衝突登録の帯の文言は、単純な成功文言そのものではない(MAJOR-2)'
Chk ([string]$o.tmLearnStatusLineAfterConflict -match '登録の順番では決まりません') '衝突登録の帯の文言が、即答の勝者は登録順で決まらないことを案内する'
Chk ([string]$o.tmLearnStatusLineAfterConflict -match '用語一覧') '衝突登録の帯の文言が、古い方を消す先(用語一覧)を案内する'
# CoD審査 REWORK-2 NEW-3: 衝突の案内は警告色(is-warning)。
Chk ([string]$o.tmLearnStatusClassAfterConflict -match 'is-warning') '衝突登録の帯はis-warning(警告色)になる(NEW-3)'
Chk ([string]$o.tmLearnStatusClassAfterConflict -notmatch 'is-error') '衝突登録はエラーではないので、is-errorは付かない(NEW-3)'
# CoD審査 REWORK-2 NEW-2: 3行に折り返す衝突文言でも、主役(主訳がある場合は
# 主訳、無ければTM候補)は帯に隠れていない(実測: 直す前は29.66px隠れていた)。
# 幾何ゲート(V9195)を保つため常設の確保は3行ぶん行っていない
# ——setCopyStatusLineの直後に呼び直すrevealMainResult()で寄せ直す。
Chk ($null -ne $o.footerFitAfterConflict -and [double]$o.footerFitAfterConflict.clearance -ge -2) '3行になる衝突文言でも、主役の候補は帯に隠れていない(NEW-2、最重要)'

# CoD審査 REWORK-2 NEW-4: 別targetの既存語がactiveなまま残っているときの
# 再登録(status=unchanged-conflict)は、単純なunchanged文言ではなく、
# 衝突の案内(is-warning)を出す。
Chk ([string]$o.tmLearnButtonTextAfterUnchangedConflict -eq '済み') 'unchanged-conflictも釦は短い「済み」'
Chk ([string]$o.tmLearnStatusLineAfterUnchangedConflict -notmatch '^すでに同じ内容で登録されています。$') 'unchanged-conflictの帯の文言は、単純なunchanged文言そのものではない(NEW-4)'
Chk ([string]$o.tmLearnStatusLineAfterUnchangedConflict -match '登録の順番では決まりません') 'unchanged-conflictの帯の文言が、勝者は登録順で決まらないことを案内する(NEW-4)'
Chk ([string]$o.tmLearnStatusClassAfterUnchangedConflict -match 'is-warning') 'unchanged-conflictの帯もis-warning(警告色)になる(NEW-3/NEW-4)'

# CoD審査 REWORK-1 MINOR-D: 'U.S.'のような略語では確認ダイアログを
# 誤爆しない(実機Chromiumで、実際にwindow.confirmを差し替えて見る)。
Chk (@($o.confirmCallsForAbbreviation).Count -eq 0) "'U.S.'を含む短い原文では確認ダイアログを出さない(MINOR-D)"
Chk ([int]$o.learnRequestCountAfterAbbreviationClick -eq 1) "'U.S.'は確認なしでそのまま送信される"
Chk (@($o.confirmCallsForDeclinedSentence).Count -eq 1) '文っぽい原文では確認ダイアログが出る(いいえのケース)'
Chk ([int]$o.learnRequestCountAfterDecline -eq 0) '確認で「いいえ」を選ぶと送信しない'

Write-Host '  -- シナリオ6: 即答欄が閉じていれば取り直さない --'
Chk ([bool]$o.instantHiddenWhenNoTmNoTerms) 'TMも用語も無ければ即答欄は閉じたまま(hidden=true)'
Chk ([int]$o.instantRequestDeltaWhenClosedAfterLearn -eq 0) '即答欄が閉じているときは、学習成功後もinstantを再送しない'

Write-Host '  -- シナリオ7: 二重送信ガード --'
Chk ([bool]$o.learnButtonDisabledRightAfterFirstClick) '1回目のクリック直後、その候補の「覚える」はdisabledになる'
Chk ([int]$o.learnRequestCountAfterDoubleClick -eq 1) '連続でクリックしても送信は1回だけ'

Write-Host '  -- シナリオ8: 失敗応答 --'
Chk ([string]$o.tmLearnButtonTextAfterFailure -eq 'エラー') '失敗時の釦は短い状態語(「エラー」)だけを示す(MINOR-A)'
Chk ([string]$o.tmLearnStatusLineAfterFailure -eq 'テスト用の失敗です。') '失敗時のサーバの文言は12字へ切り詰めず、全文を帯へ表示する(MINOR-B)'
Chk ([string]$o.tmLearnStatusClassAfterFailure -match 'is-error') '失敗時の帯はis-error(エラー色)になる(NEW-3)'
Chk ([string]$o.tmLearnStatusClassAfterFailure -notmatch 'is-warning') '失敗は警告ではないので、is-warningは付かない(NEW-3)'
Test-N9200ButtonFit -Label 'エラー(failure)' -Geo $o.buttonFitError
Chk (-not [bool]$o.tmLearnButtonDisabledAfterFailure) '失敗後は押し直せる(disabledのままにしない)'
Chk ([string]$o.tmLearnButtonTextAfterFailureRestore -eq '覚える') '失敗表示も、しばらくすると既定の「覚える」へ戻る(MINOR-C)'

} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host ('Test-YakuV9200PaletteLearn: 検査 ' + $script:checks + ' 件、合格。') -ForegroundColor Green; exit 0 }
Write-Host ('Test-YakuV9200PaletteLearn: 検査 ' + $script:checks + ' 件、' + $script:fail + ' 件不合格。') -ForegroundColor Red
exit 1
