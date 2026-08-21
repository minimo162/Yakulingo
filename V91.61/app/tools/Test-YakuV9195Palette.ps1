<#
.SYNOPSIS
  お手軽翻訳（/palette）の回帰テスト。

.DESCRIPTION
  見るのは3つ。

  (a) 静的部。www/palette.html・www/assets/palette.js・palette.css が
      存在し、要る合図（貼り付け欄・common.js/palette.js の読み込み・
      セッショントークンのプレースホルダ）を持つこと。「短く」チップの
      配線がどこにも残っていないこと。

  (b) 実装地図の部。Server.ps1 から本物の関数を AST で取り出し、
      その場で呼ぶ（写経しない）。
        - Serve-YakuAppPage の ValidateSet に palette.html が入り、
          実際に www/palette.html を配れること
        - Invoke-YakuRoute が GET /palette を Serve-YakuAppPage(palette.html)
          へ、POST /api/palette/instant・/translate・/chip を正しく配線して
          いること
        - /api/palette/instant が Find-YakuTranslationMemoryExact だけを
          呼ぶこと（あいまい照合 Find-YakuTranslationMemory を一度も
          呼ばないことを、呼んだら例外を投げるスタブで確かめる）。
          曖昧な原文でも 409 にならないこと
        - /api/palette/translate は Resolve-YakuDirectionDecision で
          曖昧と出たら 409/DIRECTION_CONFIRMATION_REQUIRED を返し、
          Start-YakuTranslationJob を一度も呼ばないこと。明示方向・
          高確度の自動判定は通り、-Kind 'text' で呼ぶこと。実行中ジョブの
          throw を 409/JOB_RUNNING へ写すこと
        - /api/palette/chip は 'shorten' を必ず断ること（Start-YakuTranslationJob
          を一度も呼ばない）。'revise' は Kind revise で呼び、current_text に
          渡した値がそのまま ReviseJson へ乗ること（マスクを外さない配線）
        - Convert-YakuTranslationJobResultJson が source_text・
          masked_translation・direction・style を返すこと（CAT結果では
          空のままなこと）。**本物の Convert-YakuTextResultToHtml
          （Html.ps1、書き換えない）が実際に生成した html** に対して、
          palette.js が読む data-yaku-main-card・data-yaku-main-text・
          data-yaku-copy-b64・data-yaku-swap・masking-note が全部
          存在することを見る（字面の合成ではなく実物の出力を見る）

  (c) 実機Chromium部。本物の palette.html/palette.js を配り、貼り付け→
      即答表示→ジョブ完了→1〜9キーでコピー→添え札クリックで入れ替え→
      チップ→Escで消去、方向確認(409)→Enterで確定、480x640/1912x987の
      両方で結果カードが画面内に収まること、を実際に押して確かめる。
      node/Playwright/Chromium が無い環境では UNMEASURED（exit 3）にする。
      「測れなかった」を赤に畳まない。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9195Palette.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$N9195Root = Split-Path -Parent $PSScriptRoot
$N9195Src = Join-Path $N9195Root 'src'
$N9195Www = Join-Path $N9195Root 'www'
$script:N9195Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9195 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9195Failures.Add($Message) }
}

Write-Host 'Test-YakuV9195Palette'

# ============================================================ (a) 静的部
Write-Host '-- static --'

$N9195PaletteHtmlPath = Join-Path $N9195Www 'palette.html'
$N9195PaletteJsPath = Join-Path $N9195Www 'assets\palette.js'
$N9195PaletteCssPath = Join-Path $N9195Www 'assets\palette.css'
$N9195CatHtmlPath = Join-Path $N9195Www 'cat.html'

Assert-N9195 (Test-Path -LiteralPath $N9195PaletteHtmlPath -PathType Leaf) 'www/palette.html が存在する'
Assert-N9195 (Test-Path -LiteralPath $N9195PaletteJsPath -PathType Leaf) 'www/assets/palette.js が存在する'
Assert-N9195 (Test-Path -LiteralPath $N9195PaletteCssPath -PathType Leaf) 'www/assets/palette.css が存在する'

if (Test-Path -LiteralPath $N9195PaletteHtmlPath -PathType Leaf) {
    $N9195Html = Get-Content -LiteralPath $N9195PaletteHtmlPath -Raw -Encoding UTF8
    Assert-N9195 ($N9195Html -match '__YAKU_SESSION_TOKEN__') 'palette.html がセッショントークンのプレースホルダを持つ'
    Assert-N9195 ($N9195Html -match '__YAKU_MAX_BATCH_CHARS__') 'palette.html が文字数上限のプレースホルダを持つ'
    Assert-N9195 ($N9195Html -match 'id="palette-input"') 'palette.html に貼り付け欄(#palette-input)がある'
    Assert-N9195 ($N9195Html -match 'id="palette-instant"') 'palette.html に即答欄(#palette-instant)がある'
    Assert-N9195 ($N9195Html -match 'id="palette-chips"') 'palette.html に注文チップ欄(#palette-chips)がある'
    Assert-N9195 ($N9195Html -match 'id="palette-result"') 'palette.html に結果欄(#palette-result)がある'
    Assert-N9195 ($N9195Html -match 'id="palette-direction-select"') 'palette.html に翻訳先セレクト(#palette-direction-select)がある(MAJOR-2)'
    Assert-N9195 ($N9195Html -match 'class="palette-footer"') 'palette.html にキー案内の固定帯(.palette-footer)がある(MAJOR-4)'
    Assert-N9195 ($N9195Html -match '/assets/common\.js') 'palette.html が common.js を読み込む'
    Assert-N9195 ($N9195Html -match '/assets/palette\.js') 'palette.html が palette.js を読み込む'
    Assert-N9195 ($N9195Html -match '/assets/palette\.css') 'palette.html が palette.css を読み込む'
    # 既存画面(cat.html/quick.js/cat.js)は変更しない。palette.html はそれらを読み込まない。
    Assert-N9195 ($N9195Html -notmatch 'quick\.js|cat\.js|cat-workspace\.css') 'palette.html は既存画面のスクリプト/CSSを読み込まない'
    # BLOCKER-1: 「短く」チップはどこにも残っていない。
    Assert-N9195 ($N9195Html -notmatch 'data-yaku-chip="shorten"') 'palette.html に「短く」チップが残っていない(BLOCKER-1)'
}

if (Test-Path -LiteralPath $N9195PaletteJsPath -PathType Leaf) {
    $N9195Js = Get-Content -LiteralPath $N9195PaletteJsPath -Raw -Encoding UTF8
    Assert-N9195 ($N9195Js -match "inputType === 'insertFromPaste'") 'palette.js が貼り付け(paste)固有のinputTypeで自動翻訳を起こす'
    Assert-N9195 ($N9195Js -match "key === 'Escape'") 'palette.js がEscでクリアする配線を持つ'
    Assert-N9195 ($N9195Js -match "/api/palette/instant") 'palette.js が即答APIを呼ぶ'
    Assert-N9195 ($N9195Js -match "/api/palette/translate") 'palette.js が翻訳APIを呼ぶ'
    Assert-N9195 ($N9195Js -match "/api/palette/chip") 'palette.js がチップAPIを呼ぶ'
    Assert-N9195 ($N9195Js -notmatch "'shorten'") 'palette.js に「短く」の配線が残っていない(BLOCKER-1)'
    Assert-N9195 ($N9195Js -match 'DIRECTION_CONFIRMATION_REQUIRED') 'palette.js が方向確認(409)を扱う(MAJOR-2)'
    Assert-N9195 ($N9195Js -match 'window\.scrollBy\(') 'palette.js が結果を画面内へ寄せる(自前の最小移動計算、MAJOR-4/B)'
    Assert-N9195 ($N9195Js -match 'reducedMotion') 'palette.js がprefers-reduced-motionを見る'
    Assert-N9195 ($N9195Js -match 'setCompactInput') 'palette.js が結果表示中は原文欄を縮める(原文併記を保つ、MAJOR-B)'
    Assert-N9195 ($N9195Js -match 'setCompactInstant') 'palette.js が結果到着後は即答欄も縮める(MAJOR-B)'
    Assert-N9195 ($N9195Js -match 'swapAltIntoMain') 'palette.js が添え札クリックで入れ替える(MINOR-5)'
    Assert-N9195 ($N9195Js -match 'beforeunload') 'palette.js がジョブ中の離脱確認を持つ(MINOR-6、common.jsは変更しない)'
    Assert-N9195 ($N9195Js -match 'data\.html \|\|') 'palette.js のエラー表示は data.html を優先する(MINOR-7)'
    Assert-N9195 ($N9195Js -match 'isInteractiveTarget') 'palette.js はボタン等にフォーカスがあるときEnterを奪わない(NIT-10)'
    Assert-N9195 ($N9195Js -match '\.trim\(\)\.length') 'palette.js の文字数はTrim後の.lengthでサーバと揃える(NIT-11)'
    Assert-N9195 ($N9195Js -match 'directionConfirmContext') 'palette.js が方向確認の対象原文を保持する(input.valueを当てにしない、NIT-D)'
    Assert-N9195 ($N9195Js -match 'updateHintTarget') 'palette.js がEnterでコピーする候補を帯へ名指しする(MINOR-C)'

    # MAJOR-A: isInteractiveTarget の判定はEnter分岐だけに掛かり、数字キー分岐には
    # 掛からないこと。字面で「かかっていない」ことまでは保証しにくいので、ここは
    # 「Enterの直前で判定している」「数字キーのifからEnterのブロックより後ろで
    # isInteractiveTargetを呼ぶ行が無い」の2点を弱く見て、実効性はChromium部の
    # 実測（クリック直後に数字キーで実際にコピーされるか）で確かめる。
    $N9195KeydownBody = ''
    if ($N9195Js -match "(?s)function onDocumentKeydown\(event\) \{(.*?)\n  \}") { $N9195KeydownBody = $Matches[1] }
    Assert-N9195 (-not [string]::IsNullOrWhiteSpace($N9195KeydownBody)) 'onDocumentKeydown の本体を取り出せる(前提条件)'
    if (-not [string]::IsNullOrWhiteSpace($N9195KeydownBody)) {
        # 「key === 'Enter'」は Ctrl+Enter 送信ぶん（typingInInput 分岐、"&&
        # event.key === 'Enter')" という字面）にも現れ、IndexOf が最初の出現を
        # 拾うと Enter コピー分岐そのものより手前に当たってしまい、判定が
        # 空振りで通ってしまう（実際に MAJOR-A の変異でこの穴を踏んだ）。
        # 実コピー分岐は「if (event.key === 'Enter')」という字面でしか
        # 現れないので、こちらで狙い撃ちする。
        $N9195EnterIdx = $N9195KeydownBody.IndexOf("if (event.key === 'Enter')")
        $N9195DigitIdx = $N9195KeydownBody.IndexOf("key >= '1'")
        $N9195GuardIdx = $N9195KeydownBody.IndexOf('isInteractiveTarget(event.target)')
        Assert-N9195 ($N9195EnterIdx -ge 0 -and $N9195DigitIdx -ge 0 -and $N9195GuardIdx -ge 0) 'Enter分岐・数字キー分岐・isInteractiveTarget判定のいずれも見つかる(前提条件)'
        Assert-N9195 ($N9195GuardIdx -gt $N9195EnterIdx -and $N9195GuardIdx -lt $N9195DigitIdx) 'isInteractiveTarget判定はEnter分岐の中にあり、数字キー分岐より前で終わる(MAJOR-A、数字キーには掛からない)'
    }
}

if (Test-Path -LiteralPath $N9195CatHtmlPath -PathType Leaf) {
    $N9195CatHtml = Get-Content -LiteralPath $N9195CatHtmlPath -Raw -Encoding UTF8
    Assert-N9195 ($N9195CatHtml -notmatch 'href="/palette"') '通常の翻訳面から専用パレット画面へ分岐しない'
}

# ==================================================== (b) 実装地図（本物の関数）

Write-Host '-- server routes (real functions, extracted via AST) --'

. (Join-Path $N9195Src 'SrcModules.ps1')
foreach ($N9195File in @($script:YakuSrcModuleFiles)) {
    . (Join-Path $N9195Src $N9195File)
}

# データを汚さない。既存の回帰テストと同じ退避先の作り方（Test-YakuV9172等）。
$N9195Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9195-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $N9195Temp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $N9195Temp 'user-data'
$script:YakuRoot = $N9195Root

function Get-N9195FunctionText {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Language.ScriptBlockAst]$Ast, [Parameter(Mandatory=$true)][string]$Name)
    $found = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return $null }
    return [string]$found[0].Extent.Text
}

$N9195ServerPath = Join-Path $N9195Src 'Server.ps1'
$N9195Tokens = $null; $N9195ParseErrors = $null
$N9195ServerAst = [System.Management.Automation.Language.Parser]::ParseFile($N9195ServerPath, [ref]$N9195Tokens, [ref]$N9195ParseErrors)
Assert-N9195 (@($N9195ParseErrors).Count -eq 0) 'Server.ps1 が構文エラー無く解析できる'

$N9195FunctionNames = @('Serve-YakuAppPage', 'Get-YakuFileUploadBodyLimitBytes', 'Invoke-YakuRoute', 'Convert-YakuTranslationJobResultJson', 'Convert-YakuResultJsonToHtml')
$N9195FunctionTexts = New-Object System.Collections.Generic.List[string]
foreach ($N9195Name in $N9195FunctionNames) {
    $N9195Text = Get-N9195FunctionText -Ast $N9195ServerAst -Name $N9195Name
    Assert-N9195 (-not [string]::IsNullOrWhiteSpace($N9195Text)) ('Server.ps1 から ' + $N9195Name + ' を取り出せる')
    if ($N9195Text) { [void]$N9195FunctionTexts.Add($N9195Text) }
}
if ($N9195FunctionTexts.Count -eq $N9195FunctionNames.Count) {
    . ([scriptblock]::Create(($N9195FunctionTexts.ToArray() -join "`n`n")))
}

# --- Serve-YakuAppPage: palette.html を実際に配れること -----------------
$script:N9195SentText = ''
$script:N9195SentStatus = 200
$script:N9195SentContentType = ''
Set-Item -Path Function:Send-YakuTextResponse -Value {
    param($Context, [string]$Text, [string]$ContentType = '', [int]$StatusCode = 200, [switch]$AllowWasm)
    $script:N9195SentText = $Text
    $script:N9195SentStatus = $StatusCode
    $script:N9195SentContentType = $ContentType
}
$N9195PageError = ''
try { Serve-YakuAppPage -Context ([pscustomobject]@{}) -PageName 'palette.html' }
catch { $N9195PageError = [string]$_.Exception.Message }
Assert-N9195 ([string]::IsNullOrWhiteSpace($N9195PageError)) ('Serve-YakuAppPage が palette.html を ValidateSet で拒まない: ' + $N9195PageError)
Assert-N9195 ($script:N9195SentText -match 'id="palette-input"') 'Serve-YakuAppPage(palette.html) が実際に palette.html の中身を返す'
Assert-N9195 ($script:N9195SentText -notmatch '__YAKU_SESSION_TOKEN__') 'Serve-YakuAppPage がセッショントークンのプレースホルダを置換する'
Assert-N9195 ($script:N9195SentText -notmatch '__YAKU_MAX_BATCH_CHARS__') 'Serve-YakuAppPage が文字数上限のプレースホルダを置換する'

# --- Invoke-YakuRoute: ルーティングの配線 --------------------------------
Set-Item -Path Function:Assert-YakuRequestBoundary -Value { param($Request, $Path, $Method) }
Set-Item -Path Function:Clear-YakuExpiredUploads -Value { param() }
Set-Item -Path Function:Convert-YakuExceptionToUserMessage -Value { param($ErrorRecord) return [string]$ErrorRecord.Exception.Message }
Set-Item -Path Function:Read-YakuRequestJson -Value { param($Request, [int64]$MaxBytes = 0); return $script:N9195Payload }

$script:N9195ServedPageName = ''
Set-Item -Path Function:Serve-YakuAppPage -Value {
    param($Context, [string]$PageName, [string]$InitialView = '', [switch]$AllowWasm)
    $script:N9195ServedPageName = $PageName
}

$script:N9195StartJobCalls = New-Object System.Collections.Generic.List[object]
$script:N9195StartJobThrow = ''
$script:N9195StartJobId = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1'
Set-Item -Path Function:Start-YakuTranslationJob -Value {
    param(
        [AllowNull()][string]$InputText = '',
        $Settings,
        [AllowNull()][string]$TextDirectionOverride = '',
        [ValidateSet('text', 'revise', 'shorten', 'cat')][string]$Kind = 'text',
        [ValidateSet('default', 'none')][string]$CachePolicy = 'default',
        [ValidateSet('display', 'none')][string]$ReferencePolicy = 'display',
        [AllowNull()][string]$ReviseJson = '',
        [AllowNull()][string]$CatJson = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($script:N9195StartJobThrow)) { throw $script:N9195StartJobThrow }
    [void]$script:N9195StartJobCalls.Add([pscustomobject]@{
        InputText = $InputText; Kind = $Kind; TextDirectionOverride = $TextDirectionOverride; ReviseJson = $ReviseJson
    })
    return @{ id = $script:N9195StartJobId }
}

$script:YakuTranslateJobs = @{}
$script:YakuTranslateJobHandles = @{}
$script:YakuLastUploadSweep = Get-Date
$script:ActivePort = 39195
$script:YakuAdminMode = $false

function Invoke-N9195Route {
    param([string]$Method, [string]$Path, [hashtable]$Payload = @{})
    $script:N9195Payload = $Payload
    $script:N9195SentText = ''
    $script:N9195SentStatus = 200
    $req = [pscustomobject]@{ Url = [uri]('http://127.0.0.1' + $Path); HttpMethod = $Method; Headers = @{} }
    $context = [pscustomobject]@{ Request = $req }
    $routeException = ''
    try { Invoke-YakuRoute -Context $context } catch { $routeException = [string]$_.Exception.Message }
    $body = $null
    try { $body = $script:N9195SentText | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Exception = $routeException; Status = $script:N9195SentStatus; Body = $body; Text = $script:N9195SentText }
}

# 通常の翻訳面は1つ。旧 /palette・/cat・/quick も同じ cat.html を返し、
# 画面側で履歴を増やさず / へ正規化する。
$script:N9195ServedPageName = ''
$null = Invoke-N9195Route -Method 'GET' -Path '/palette'
Assert-N9195 ($script:N9195ServedPageName -eq 'cat.html') 'GET /palette が左右の標準翻訳面を返す'

$script:N9195ServedPageName = ''
$null = Invoke-N9195Route -Method 'GET' -Path '/cat'
Assert-N9195 ($script:N9195ServedPageName -eq 'cat.html') 'GET /cat も左右の標準翻訳面を返す'
$script:N9195ServedPageName = ''
$null = Invoke-N9195Route -Method 'GET' -Path '/quick'
Assert-N9195 ($script:N9195ServedPageName -eq 'cat.html') 'GET /quick も左右の標準翻訳面を返す'

# --- /api/palette/instant --------------------------------------------
# TM完全一致の種を仕込む(既定パスへ。Find-YakuTranslationMemoryExact は
# -Path を渡さないので、既定パス=env:YAKULINGO_DATA_DIR配下 に置く)。
$N9195TmSource = '来期の見通しについてご説明いたします。'
$N9195TmTarget = 'We will explain the outlook for next fiscal year.'
$N9195Added = Add-YakuTranslationMemoryEntry -Source $N9195TmSource -Target $N9195TmTarget -Direction 'to_en' `
    -OriginProjectId '11111111111111111111111111111111' -OriginFileName 'palette-test.xlsx' `
    -OriginSegmentId ((Get-YakuTranslationMemoryHash -Text $N9195TmSource).Substring(0, 32)) `
    -OriginLocation 'Sheet1, A1' -OriginPage 1 -ReviewRevision 1
Assert-N9195 ([bool]$N9195Added.Added) 'TM完全一致の種を仕込めた(前提条件)'

# 個人用語集にも occurrence 種の語を仕込む。
$N9195TermAdd = Add-YakuTerminologyEntry -Scope personal -Kind occurrence -Enforcement advisory `
    -JapanesePreferred '御社' -EnglishPreferred 'your company' -Origin 'palette-test' `
    -OriginProjectId '22222222222222222222222222222222' -OriginFileName 'palette-test.xlsx' `
    -OriginSegmentId '33333333333333333333333333333333' -OriginLocation 'Sheet1, A1' -OriginRevision 1
Assert-N9195 ([bool]$N9195TermAdd.Added) '個人用語集の種を仕込めた(前提条件)'

# あいまい照合(Find-YakuTranslationMemory)を一度でも呼んだら例外にする。
# 3,000件規模で~25秒かかる関数をこの経路が呼んではならない(実装地図の制約)。
$script:N9195FuzzyCalled = $false
$N9195OriginalFuzzy = (Get-Command Find-YakuTranslationMemory -CommandType Function).ScriptBlock
Set-Item -Path Function:Find-YakuTranslationMemory -Value {
    param([Parameter(Mandatory=$true)][string]$Text, [ValidateSet('to_en', 'to_jp')][string]$Direction = 'to_en', [AllowNull()][string]$Path)
    $script:N9195FuzzyCalled = $true
    throw 'FUZZY_MUST_NOT_BE_CALLED_FROM_PALETTE_INSTANT'
}

$N9195InstantHit = Invoke-N9195Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9195TmSource; direction_intent = 'auto' }
Assert-N9195 ([string]::IsNullOrWhiteSpace($N9195InstantHit.Exception)) ('/api/palette/instant がTM完全一致の原文で例外を出さない: ' + $N9195InstantHit.Exception)
Assert-N9195 (-not $script:N9195FuzzyCalled) '/api/palette/instant があいまい照合(Find-YakuTranslationMemory)を一度も呼ばない'
Assert-N9195 ($null -ne $N9195InstantHit.Body -and $null -ne $N9195InstantHit.Body.tm -and [string]$N9195InstantHit.Body.tm.target -eq $N9195TmTarget) '/api/palette/instant がTM完全一致をtmとして返す'
Assert-N9195 ([bool]$N9195InstantHit.Body.tm.exact) '/api/palette/instant のtmがexact=trueを持つ'

$N9195TermText = 'いつも御社にはお世話になっております。'
$N9195TermHit = Invoke-N9195Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9195TermText; direction_intent = 'auto' }
$N9195TermRows = @($N9195TermHit.Body.terms)
Assert-N9195 ($N9195TermRows.Count -ge 1 -and (@($N9195TermRows | Where-Object { [string]$_.source -eq '御社' -and [string]$_.target -eq 'your company' })).Count -eq 1) '/api/palette/instant が個人用語集の一致語をtermsとして返す'

# 曖昧な方向でも 409 にしない(即答は参考情報であって関門ではない)。
$N9195Ambiguous = Invoke-N9195Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = 'ABC'; direction_intent = 'auto' }
Assert-N9195 ($N9195Ambiguous.Status -ne 409) '/api/palette/instant は方向が曖昧でも409にしない'
Assert-N9195 ([string]$N9195Ambiguous.Body.direction -eq 'to_en' -or [string]$N9195Ambiguous.Body.direction -eq 'to_jp') '/api/palette/instant は曖昧でも見込みの方向を返す(空にしない)'

$N9195EmptyInstant = Invoke-N9195Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = ''; direction_intent = 'auto' }
Assert-N9195 ($null -eq $N9195EmptyInstant.Body.tm -and @($N9195EmptyInstant.Body.terms).Count -eq 0) '/api/palette/instant は空文字にtm=null・terms=[]を返す'

Set-Item -Path Function:Find-YakuTranslationMemory -Value $N9195OriginalFuzzy

# --- /api/palette/translate --------------------------------------------
# MAJOR-2: 'ABC' は Get-YakuDirectionAnalysis で latin<4 の低確度になり、
# Resolve-YakuDirectionDecision が RequiresConfirmation=true を返す
# (/api/palette/instant の曖昧確認テストと同じ原文で確かめ済み)。
$script:N9195StartJobCalls.Clear()
$N9195AmbiguousTranslate = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = 'ABC'; direction_intent = 'auto' }
Assert-N9195 ($N9195AmbiguousTranslate.Status -eq 409 -and [string]$N9195AmbiguousTranslate.Body.code -eq 'DIRECTION_CONFIRMATION_REQUIRED') '/api/palette/translate は曖昧な方向を409/DIRECTION_CONFIRMATION_REQUIREDで止める(MAJOR-2)'
Assert-N9195 (-not [string]::IsNullOrWhiteSpace([string]$N9195AmbiguousTranslate.Body.suggested_direction)) '409応答が suggested_direction を持つ(確認ボタンの表示に要る)'
Assert-N9195 (-not [string]::IsNullOrWhiteSpace([string]$N9195AmbiguousTranslate.Body.confidence)) '409応答が confidence を持つ'
Assert-N9195 ($script:N9195StartJobCalls.Count -eq 0) '方向が曖昧なときは Start-YakuTranslationJob を一度も呼ばない(Copilotへ送らない)'

# 曖昧でも明示方向(direction_intent)を渡せば通す。
$script:N9195StartJobCalls.Clear()
$N9195ExplicitAmbiguous = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = 'ABC'; direction_intent = 'to_en' }
Assert-N9195 ($N9195ExplicitAmbiguous.Status -ne 409 -and $script:N9195StartJobCalls.Count -eq 1) '明示方向(to_en)を渡せば、曖昧な原文でも409にせず送る'

$script:N9195StartJobCalls.Clear()
$N9195Translate = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = '来期の業績見通しについて説明します。'; direction_intent = 'auto' }
Assert-N9195 ($script:N9195StartJobCalls.Count -eq 1 -and [string]$script:N9195StartJobCalls[0].Kind -eq 'text') '/api/palette/translate が Start-YakuTranslationJob を -Kind text で呼ぶ'
Assert-N9195 ([string]$N9195Translate.Body.job_id -eq $script:N9195StartJobId) '/api/palette/translate が job_id をそのまま返す'

$script:N9195StartJobCalls.Clear()
$null = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = 'Explain the results.'; direction_intent = 'to_jp' }
Assert-N9195 ([string]$script:N9195StartJobCalls[0].TextDirectionOverride -eq 'to_jp') '/api/palette/translate は明示方向を -TextDirectionOverride へ渡す'

$N9195EmptyTranslate = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = '   '; direction_intent = 'auto' }
Assert-N9195 ($N9195EmptyTranslate.Status -eq 400) '/api/palette/translate は空文字を400で断る'

$script:N9195StartJobThrow = '別の翻訳が実行中です。完了してから再実行してください。'
$N9195Busy = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = '実行中に送る文章'; direction_intent = 'auto' }
Assert-N9195 ($N9195Busy.Status -eq 409 -and [string]$N9195Busy.Body.code -eq 'JOB_RUNNING') '/api/palette/translate は実行中ジョブのthrowを409/JOB_RUNNINGへ写す'
$script:N9195StartJobThrow = ''

# 文字数上限。Get-YakuMaxCharsPerFileBatch を小さい値へ差し替えて確かめる。
$N9195OriginalMaxChars = (Get-Command Get-YakuMaxCharsPerFileBatch -CommandType Function).ScriptBlock
Set-Item -Path Function:Get-YakuMaxCharsPerFileBatch -Value { param($Settings) return 5 }
$N9195TooLong = Invoke-N9195Route -Method 'POST' -Path '/api/palette/translate' -Payload @{ text = 'これは6文字以上あります'; direction_intent = 'auto' }
Assert-N9195 ($N9195TooLong.Status -eq 400 -and [string]$N9195TooLong.Body.error -match 'PALETTE_TEXT_TOO_LONG|1回で送れるのは') '/api/palette/translate は上限超過を400で断る(上限超過での再依頼はしない)'
Set-Item -Path Function:Get-YakuMaxCharsPerFileBatch -Value $N9195OriginalMaxChars

# --- /api/palette/chip --------------------------------------------------
# BLOCKER-1: 「短く」は必ず断る。マスクの対応表が翻訳時とずれるため
# (Invoke-YakuTextTranslation は単位換算→マスクの順、Invoke-YakuTextShorten は
# その逆で、同じ原文でも異なる[[N#]]対応になる。実測は Server.ps1 の
# /api/palette/chip 直前のコメントを参照)。
$script:N9195StartJobCalls.Clear()
$N9195ChipShorten = Invoke-N9195Route -Method 'POST' -Path '/api/palette/chip' -Payload @{
    chip = 'shorten'; source_text = 'Revenue increased.'; current_text = 'Revenue increased by [[N1]] percent.'; direction = 'to_en'; style = 'full'
}
Assert-N9195 ($N9195ChipShorten.Status -eq 400 -and $script:N9195StartJobCalls.Count -eq 0) '「短く」は常に断る。Start-YakuTranslationJobを一度も呼ばない(BLOCKER-1)'

$script:N9195StartJobCalls.Clear()
$N9195ChipRevise = Invoke-N9195Route -Method 'POST' -Path '/api/palette/chip' -Payload @{
    chip = 'revise'; source_text = 'Revenue increased.'; current_text = 'Revenue increased by [[N1]] percent.'; direction = 'to_en'; style = 'full'
}
Assert-N9195 ($script:N9195StartJobCalls.Count -eq 1 -and [string]$script:N9195StartJobCalls[0].Kind -eq 'revise') '「丁寧に」チップが Start-YakuTranslationJob を -Kind revise で呼ぶ'
$N9195ReviseReviseJson = $script:N9195StartJobCalls[0].ReviseJson | ConvertFrom-Json
Assert-N9195 (-not [string]::IsNullOrWhiteSpace([string]$N9195ReviseReviseJson.instruction)) '「丁寧に」チップは固定の指示を積む(自由記述欄は無い)'
Assert-N9195 ([string]$N9195ReviseReviseJson.current_text -eq 'Revenue increased by [[N1]] percent.') '「丁寧に」チップの current_text は渡した値のまま(マスクを外さない)'

$N9195ChipMissing = Invoke-N9195Route -Method 'POST' -Path '/api/palette/chip' -Payload @{ chip = 'revise'; source_text = ''; current_text = '' }
Assert-N9195 ($N9195ChipMissing.Status -eq 400) 'チップは原文/現訳が無ければ400で断る'

# Convert-YakuTranslationJobResultJson は冒頭で Update-YakuTranslationJobs を
# 呼ぶ(実行中ジョブの後始末)。ここでは完了済みの結果を読むだけを見たいので、
# 本物の代わりに何もしないスタブを立てる(本物はランスペース/ハンドルの
# 後始末で、この試験の関心事(JSONの配線)とは無関係)。
Set-Item -Path Function:Update-YakuTranslationJobs -Value { param() }

# --- Convert-YakuTranslationJobResultJson: 本物の html を実際に見る(MAJOR-3) ---
# 2件のOptionsを積む。Convert-YakuTextResultToHtml(Html.ps1、書き換えない)は
# 1件目を主札(data-yaku-main-card)、2件目以降を添え札(data-yaku-swap)にする。
# ここで両方を出させないと、palette.jsが実際に読む属性のうち
# data-yaku-swap だけが検証から漏れる(合成した字面ではなく実物を見る)。
$N9195SyntheticResult = [ordered]@{
    Direction = 'to_en'
    SourceText = 'Synthetic source text.'
    Options = @(
        [ordered]@{ Style = 'full'; Label = '標準'; Translation = 'Real value 1234.'; MaskedTranslation = 'Real value [[N1]].'; NumbersDropped = $false },
        [ordered]@{ Style = 'brief'; Label = '電文体'; Translation = 'Short 1234.'; MaskedTranslation = 'Short [[N1]].'; NumbersDropped = $false }
    )
    MaskedCount = 1
    KeptCount = 0
    Warnings = @()
    BatchCount = 1
}
$N9195State = @{
    id = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2'; mode = 'done'; label = 'Done'; class = 'ok'; detail = ''; progress = 100
    kind = 'text'; phase = ''; unique_done = 0; unique_total = 0; updated_at = ''; error_code = ''; completion_status = ''
    result_json = ($N9195SyntheticResult | ConvertTo-Json -Depth 10 -Compress)
}
$N9195ResultJson = Convert-YakuTranslationJobResultJson -State $N9195State | ConvertFrom-Json
Assert-N9195 ([string]$N9195ResultJson.source_text -eq 'Synthetic source text.') 'Convert-YakuTranslationJobResultJson が source_text を返す(チップの元になる)'
Assert-N9195 ([string]$N9195ResultJson.masked_translation -eq 'Real value [[N1]].') 'Convert-YakuTranslationJobResultJson が masked_translation(実値なし・主札=1件目)を返す'
Assert-N9195 ([string]$N9195ResultJson.direction -eq 'to_en') 'Convert-YakuTranslationJobResultJson が direction を返す'
$N9195RealHtml = [string]$N9195ResultJson.html
# MAJOR-3 の本体: palette.js が実際にDOMから読む5つの合図が、本物の
# 生成結果に存在すること。字面の合成ではなく Html.ps1 の実出力を見る。
Assert-N9195 ($N9195RealHtml -match 'data-yaku-main-card') '本物のhtmlに data-yaku-main-card がある(主札)'
Assert-N9195 ($N9195RealHtml -match 'data-yaku-main-text') '本物のhtmlに data-yaku-main-text がある(主訳の本文、palette.jsが候補1のテキストとして読む)'
Assert-N9195 ($N9195RealHtml -match 'data-yaku-copy-b64=[''"][A-Za-z0-9+/=]+[''"]') '本物のhtmlに data-yaku-copy-b64 がある(主札コピー釦)'
Assert-N9195 ($N9195RealHtml -match 'data-yaku-swap=[''"][A-Za-z0-9+/=]+[''"]') '本物のhtmlに data-yaku-swap がある(添え札、候補3・スワップ対象)'
Assert-N9195 ($N9195RealHtml -match 'masking-note') '本物のhtmlに masking-note がある(マスク件数の見える化)'

# CAT結果(Kind='cat')には新フィールドを持ち込まない(既存挙動への副作用なし)。
$N9195CatResult = [ordered]@{ Kind = 'cat'; Mode = 'translate'; Translations = @() }
$N9195CatState = @{
    id = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3'; mode = 'done'; label = 'Done'; class = 'ok'; detail = ''; progress = 100
    kind = 'cat'; phase = ''; unique_done = 0; unique_total = 0; updated_at = ''; error_code = ''; completion_status = ''
    result_json = ($N9195CatResult | ConvertTo-Json -Depth 10 -Compress)
}
$N9195CatResultJson = Convert-YakuTranslationJobResultJson -State $N9195CatState | ConvertFrom-Json
Assert-N9195 ([string]::IsNullOrEmpty([string]$N9195CatResultJson.source_text)) 'CAT結果(Kind=cat)には source_text が乗らない(パレット追加の副作用なし)'

# ============================================================ (c) 実機Chromium部
Write-Host '-- chromium --'

$N9195Unmeasured = 3
$N9195Driver = Join-Path $PSScriptRoot 'palette-screen\palette-gate.js'
$N9195Node = Get-Command node -ErrorAction SilentlyContinue
$N9195ChromiumOk = $false
$N9195ChromiumNote = ''
if ($null -eq $N9195Node -or -not (Test-Path -LiteralPath $N9195Driver -PathType Leaf)) {
    $N9195ChromiumNote = 'node またはドライバが見つからない'
} else {
    $N9195NodeExe = [string]$N9195Node.Source
    $N9195ProbeDir = (Split-Path -Parent $N9195Driver).Replace('\', '/')
    $null = & $N9195NodeExe -e ("try{require.resolve('playwright',{paths:['" + $N9195ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
    if ($LASTEXITCODE -ne 0) {
        $N9195ChromiumNote = 'Playwright が見つからない'
    } else {
        $N9195ChromiumPath = & $N9195NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $N9195ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$N9195ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$N9195ChromiumPath) -PathType Leaf)) {
            $N9195ChromiumNote = 'Playwright Chromium が見つからない'
        } else {
            $N9195ChromiumOk = $true
        }
    }
}

$N9195StaticFailed = ($script:N9195Failures.Count -gt 0)

if (-not $N9195ChromiumOk) {
    Write-Host ('UNMEASURED: ' + $N9195ChromiumNote)
    if ($N9195StaticFailed) {
        Write-Host ''
        Write-Host ('FAIL ' + $script:N9195Failures.Count + ' assertion(s) (static/route part)')
        foreach ($f in $script:N9195Failures) { Write-Host ('  - ' + $f) }
        exit 1
    }
    exit $N9195Unmeasured
}

$N9195Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9195-chromium-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $N9195Work -Force
$N9195OutJson = Join-Path $N9195Work 'out.json'
& $N9195NodeExe $N9195Driver $N9195Www $N9195OutJson
$N9195DriverExit = $LASTEXITCODE
Assert-N9195 ($N9195DriverExit -eq 0 -and (Test-Path -LiteralPath $N9195OutJson -PathType Leaf)) 'Chromiumドライバが完走し、観察結果を書き出した'

if (Test-Path -LiteralPath $N9195OutJson -PathType Leaf) {
    $N9195Observed = Get-Content -LiteralPath $N9195OutJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pageError in @($N9195Observed.errors)) { Write-Host ('  Chromium error: ' + [string]$pageError) }
    foreach ($consoleError in @($N9195Observed.console)) { Write-Host ('  Chromium console: ' + [string]$consoleError) }
    Assert-N9195 (@($N9195Observed.errors).Count -eq 0) '実機ページでJSエラーが出ない'
    Assert-N9195 (@($N9195Observed.console).Count -eq 0) '実機ページでconsole.errorが出ない(意図した409は除外済み)'

    Assert-N9195 ([int]$N9195Observed.shortenChipCount -eq 0) '実機の画面にも「短く」チップが無い(BLOCKER-1)'
    Assert-N9195 ($N9195Observed.activeIsInputAfterPaste -eq $false) '貼り付け後は入力欄からフォーカスが外れる(1〜9/Enterがそのまま効く)'
    Assert-N9195 ($N9195Observed.instantHtml -match 'TM exact translation\.') '貼り付け直後にTM完全一致の即答が描かれる'
    Assert-N9195 ($N9195Observed.resultHtml -match 'data-yaku-main-card') 'ジョブ完了後、Copilotの訳が結果欄へ挿し込まれる'
    Assert-N9195 ($N9195Observed.resultHtml -match 'masking-note') '結果欄にマスク件数の表示(見える化)が入っている'

    # MINOR-6: ジョブ実行中だけ beforeunload を止める。
    Assert-N9195 ($N9195Observed.beforeUnloadWhileRunning -eq $true) 'ジョブ実行中は beforeunload を止める(離脱確認)'
    Assert-N9195 ($N9195Observed.beforeUnloadAfterDone -eq $false) 'ジョブ完了後は beforeunload を止めない'
    Assert-N9195 ($N9195Observed.beforeUnloadAfterEscape -eq $false) 'Escで消した後も beforeunload を止めない'

    $N9195Indexes = @($N9195Observed.candidateIndexes)
    Assert-N9195 (($N9195Indexes -join ',') -eq '1,2,3') '候補番号がTM→主訳→添えの順で1,2,3と振られる'

    Assert-N9195 ($N9195Observed.chipsHidden -eq $false) '翻訳完了後、注文チップが現れる'

    $N9195One = @($N9195Observed.copiedAfterDigitOne)
    Assert-N9195 ($N9195One.Count -eq 1 -and [string]$N9195One[0] -eq 'TM exact translation.') '1キーで先頭候補(TM)がコピーされる'

    $N9195AfterEnter = @($N9195Observed.copiedAfterEnter)
    Assert-N9195 ($N9195AfterEnter.Count -eq 2 -and [string]$N9195AfterEnter[1] -eq 'TM exact translation.') 'Enterで既定候補(先頭)がコピーされる'

    $N9195AfterThree = @($N9195Observed.copiedAfterDigitThree)
    Assert-N9195 ($N9195AfterThree.Count -eq 3 -and [string]$N9195AfterThree[2] -eq 'Sales reached 1,234 million yen.') '3キーでCopilotの添え(alt)候補がコピーされる(まだ入れ替えていない)'

    # MAJOR-A: 主札のコピー釦をマウスでクリックした直後(activeElementがその
    # <button>のまま)でも、数字キーは生きている。壊れていた時は、ここで
    # 一切クリップボードへ書かれなかった(0回増加)。
    Assert-N9195 ([int]$N9195Observed.copiedCountAfterMainCopyClickThenDigit -eq [int]$N9195Observed.copiedCountBeforeMainCopyClick + 2) 'コピー釦クリック(+1)の直後に数字キー(+1)が効く(MAJOR-A)'
    Assert-N9195 ([string]$N9195Observed.copiedLastAfterMainCopyClickThenDigit -eq 'TM exact translation.') 'コピー釦クリック後の1キーは候補1(TM)をコピーする'

    # MINOR-5: 添え札をクリックすると主札と入れ替わる。
    Assert-N9195 ([string]$N9195Observed.mainTextAfterSwap -eq 'Sales reached 1,234 million yen.') '添え札クリックで主札の中身が入れ替わる(MINOR-5)'
    Assert-N9195 ([string]$N9195Observed.altBodyAfterSwap -eq 'Revenue was 1,234 million yen.') '添え札クリックで、元の主訳が添え札側へ入れ替わる(双方向)'

    # MAJOR-A続き: 添え札クリック(スワップ)の直後も、数字キーは生きている
    # (実測: 修正前は2/3キーを押してもクリップボードへ一切書かれなかった)。
    Assert-N9195 ([int]$N9195Observed.copiedCountAfterSwapDigit -eq [int]$N9195Observed.copiedCountBeforeSwapDigit + 1) 'スワップ(クリック)の直後に数字キーが効く(MAJOR-A)'
    Assert-N9195 ([string]$N9195Observed.copiedLastAfterSwapDigit -eq 'Sales reached 1,234 million yen.') 'スワップ後の2キーは、入れ替わった新しい候補2をコピーする'
    Assert-N9195 ([string]$N9195Observed.copyStatusAfterSwapDigit -match '候補2') 'スワップ後の数字キーコピーで状態表示も更新される(固まっていない)'

    $N9195ChipReq = @($N9195Observed.chipRequests)
    Assert-N9195 ($N9195ChipReq.Count -eq 1) '「丁寧に」チップを押すと /api/palette/chip へ1回送られる'
    if ($N9195ChipReq.Count -eq 1) {
        Assert-N9195 ([string]$N9195ChipReq[0].chip -eq 'revise') 'チップ送信の chip=revise'
        Assert-N9195 ([string]$N9195ChipReq[0].current_text -eq 'Revenue was [[N1]] million yen.') 'チップ送信の current_text はマスク後の値のまま(スワップ後の表示文字列ではない)'
        Assert-N9195 ([string]$N9195ChipReq[0].source_text -eq 'Revenue source text') 'チップ送信の source_text は元の原文'
    }

    Assert-N9195 ([string]$N9195Observed.inputValueAfterEscape -eq '') 'Escで入力欄が空になる'
    Assert-N9195 ([string]$N9195Observed.resultHtmlAfterEscape -eq '') 'Escで結果欄が空になる'
    Assert-N9195 ($N9195Observed.chipsHiddenAfterEscape -eq $true) 'Escで注文チップが隠れる'
    Assert-N9195 ([int]$N9195Observed.candidateCountAfterEscape -eq 0) 'Escで候補番号が全て消える'

    # MAJOR-2 + NIT-10: 方向確認と、Enterがそのボタンを押すこと(候補コピーへ奪われない)。
    Assert-N9195 ($N9195Observed.directionConfirmVisible -eq $true) '曖昧な原文で方向確認ボタンが出る(MAJOR-2)'
    Assert-N9195 ($N9195Observed.directionConfirmIsFocused -eq $true) '方向確認ボタンへ自動でフォーカスが移る(Enterで押せるように)'
    $N9195Confirmed = @($N9195Observed.translateRequestsAfterConfirm)
    Assert-N9195 ($N9195Confirmed.Count -eq 2) 'Enterで方向確認ボタンが押され、明示方向で再送される(1回目auto→409、2回目確定、NIT-10)'
    if ($N9195Confirmed.Count -eq 2) {
        Assert-N9195 ([string]$N9195Confirmed[0].direction_intent -eq 'auto') '1回目はauto(409になる側)'
        Assert-N9195 ([string]$N9195Confirmed[1].direction_intent -eq 'to_en') '2回目はEnterで確定した明示方向(to_en)'
    }
    Assert-N9195 ($N9195Observed.afterDirectionConfirmHtml -match 'data-yaku-main-card') '方向確定後、翻訳結果が結果欄へ挿し込まれる'

    # NIT-D: 確認ボタンを押す前に原文を書き換えたら、古い判定(to_en)を新しい
    # 原文へ当てはめず、書き換え後の原文で自動判定(auto)へ戻す。
    $N9195EditedReq = @($N9195Observed.translateRequestsAfterEdit)
    Assert-N9195 ($N9195EditedReq.Count -eq 1) '書き換え後、確認ボタンを押すと書き換えた原文で1回送られる(NIT-D)'
    if ($N9195EditedReq.Count -eq 1) {
        Assert-N9195 ([string]$N9195EditedReq[0].text -match 'EDITEDAFTERCONFIRM') '送られた原文は書き換え後のもの(古い判定対象の原文ではない)'
        Assert-N9195 ([string]$N9195EditedReq[0].direction_intent -eq 'auto') '書き換え後は自動判定(auto)へ戻す。古い確定方向(to_en)を使い回さない'
    }
    Assert-N9195 ($N9195Observed.afterEditConfirmHtml -match 'data-yaku-main-card') '書き換え後の原文でも翻訳結果が結果欄へ挿し込まれる'

    # ============================================== MAJOR-B/MAJOR-4/MINOR-C/NIT-E: 幾何
    # (a) 左右画面では結果欄を一定高のスクロール領域にして、隣のExcel面を押し流さない。
    # (b) 原文欄(#palette-input)は少なくとも一部が見える(原文併記、spec item 3)。
    # (c) キー案内(.palette-hint)は見える。
    function Test-N9195Geometry {
        param([string]$Label, $Geo, [bool]$RequireInput = $true, [bool]$RequireMain = $true)
        if ($RequireMain) {
            Assert-N9195 ($null -ne $Geo.main) ($Label + ': 主札の矩形を測れている(前提条件)')
        }
        if ($null -ne $Geo.main) {
            Assert-N9195 ($null -ne $Geo.result -and [string]$Geo.resultOverflowY -eq 'auto' -and [string]$Geo.resultMaxHeight -eq '280px') ($Label + ': 左右画面では結果欄が280px以内のスクロール領域になる(result.maxHeight=' + [string]$Geo.resultMaxHeight + ' overflowY=' + [string]$Geo.resultOverflowY + ')')
        }
        if ($RequireInput) {
            Assert-N9195 ($null -ne $Geo.input) ($Label + ': 原文欄の矩形を測れている(前提条件)')
            if ($null -ne $Geo.input) {
                $inputBottomLimit = [double]$Geo.innerHeight
                if ($null -ne $Geo.footer) { $inputBottomLimit = [double]$Geo.footer.top }
                Assert-N9195 ([double]$Geo.input.top -lt $inputBottomLimit) ($Label + ': 原文欄の上端が帯より上(top=' + [string]$Geo.input.top + ')')
                Assert-N9195 ([double]$Geo.input.bottom -gt 0) ($Label + ': 原文欄の下端が画面の上端より下——一部でも見えている(bottom=' + [string]$Geo.input.bottom + ')、原文併記(spec item 3)/MAJOR-B')
            }
        }
        Assert-N9195 ($null -ne $Geo.hint) ($Label + ': キー案内(.palette-hint)の矩形を測れている')
    }

    # NIT-E: 即答(TM)だけが出ている段階の幾何も使う。原文欄はこの時点でも
    # 見えているべき(まだ結果が無いので、そもそも押し出す圧力も小さい)。
    Test-N9195Geometry -Label '480x640(即答のみ)' -Geo $N9195Observed.geometryAfterInstant480 -RequireInput $true -RequireMain $false

    Test-N9195Geometry -Label '480x640(ジョブ完了後)' -Geo $N9195Observed.geometryAfterJob480 -RequireInput $true
    Test-N9195Geometry -Label '1912x987(ジョブ完了後)' -Geo $N9195Observed.geometryAfterJob1912 -RequireInput $true

    # MINOR-C: Enterでコピーされる「既定候補」が実際に何かを、帯が名指しする。
    # 汎用の「既定候補」のままなら、見えていないものを誤魔化していることになる。
    Assert-N9195 ([string]$N9195Observed.geometryAfterJob480.hintTargetText -ne '既定候補') '帯の案内文が、Enterで実際にコピーされる候補の種類を名指ししている(MINOR-C)'
    Assert-N9195 ([string]$N9195Observed.geometryAfterJob480.hintTargetText -eq '訳文メモリの候補') 'この題材では候補1がTM完全一致なので、案内文もそう名指しする'
    # 圧縮(MAJOR-B)によって候補1(TM)自体も画面内に収まっているかも実測する
    # (収まらない場合の代替策が案内文の名指し=直前の表明)。
    $N9195Cand1_480 = $N9195Observed.geometryAfterJob480.candidate1
    if ($null -ne $N9195Cand1_480) {
        Assert-N9195 ([double]$N9195Cand1_480.top -ge -2 -and [double]$N9195Cand1_480.bottom -le ([double]$N9195Observed.geometryAfterJob480.innerHeight + 2)) ('480x640: 候補1(TM)も画面内に収まっている(top=' + [string]$N9195Cand1_480.top + ' bottom=' + [string]$N9195Cand1_480.bottom + ')')
    }
}

Write-Host ''
if ($script:N9195Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9195Palette'
    exit 0
}
Write-Host ('FAIL ' + $script:N9195Failures.Count + ' assertion(s)')
foreach ($f in $script:N9195Failures) { Write-Host ('  - ' + $f) }
exit 1
