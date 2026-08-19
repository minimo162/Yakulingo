<#
.SYNOPSIS
  V91.99: パレット(/palette)の昇格ボタン(「CATで開く」)の回帰試験。

.DESCRIPTION
  パレットで手に負えない長さ・重要度のテキストを、1ボタンでCAT(資料翻訳)へ
  引き継ぐ導線を見る。構想図の3接続のうち「昇格」だけを見る(逆方向は作って
  いない)。見るのは2つ。

  (a) 静的部。ボタン・キー名・読み捨て・イベント再利用を、字面(regex)で見る。
      - palette.html に「CATで開く」ボタンがあり、既定で押せないこと
      - palette.js が本文(と方向)を sessionStorage の専用キー
        (yaku.palette.handoff)へ退避してから /cat?handoff=palette へ
        遷移すること。try/catchで包むこと(quick.jsのdraft退避と同じ流儀)
      - cat.js が同じキー文字列を持つこと(palette.jsとの綴りのずれを防ぐ)
      - cat.js の consumePaletteHandoff が、読んでから消すこと(read-once。
        getItemがremoveItemより先に現れること)
      - consumePaletteHandoff が既存の yaku-instant-handoff を
        dispatchEventで呼ぶだけで、el('quick-input')やopenSourceを
        自分で直接呼ばないこと(既存受け口の処理を複製しない)
      - cat.js の start() が ?handoff=palette のときだけ
        consumePaletteHandoff を呼ぶこと
      - 既存の yaku-instant-handoff 受け口(bindInstant)が、パレットから
        運ばれた方向をopenSourceへ渡せる形を保っていること(V9161の
        ピン: window.addEventListener('yaku-instant-handoff'
        [0,1600]el('quick-input').value = text;[0,160]openSource('text'
        を壊さないこと)

  (b) 実機Chromium部。本物のpalette.html/cat.html/palette.js/cat.jsを配り、
      パレットで本文を打つ→「CATで開く」が押せるようになる→押すと
      sessionStorageへ退避してから遷移しようとする(遷移先URL・退避内容を
      実際に見る)→翻訳ジョブ実行中は押せない、を実際に押して確かめる。
      別に、cat.htmlを ?handoff=palette + sessionStorage仕込みで開き、
      quick-inputへ本文が入り、既存経路(/api/cat/open)へ実際に
      text・direction_intentが飛ぶことを見る。キー欠落・JSON破損では
      通常起動に落ちること、1回読んだら2回目は起きない(読み捨て)ことも見る。

      node/Playwright/Chromium が無い環境では緑にしない。終了コード3
      (未測定)で抜ける。「測れなかった」を赤に畳まない。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9199PaletteHandoff.ps1
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

Write-Host 'Test-YakuV9199PaletteHandoff'

$wwwDir = Join-Path $root 'www'
$paletteHtmlPath = Join-Path $wwwDir 'palette.html'
$paletteJsPath = Join-Path (Join-Path $wwwDir 'assets') 'palette.js'
$catJsPath = Join-Path (Join-Path $wwwDir 'assets') 'cat.js'

Chk (Test-Path -LiteralPath $paletteHtmlPath -PathType Leaf) 'www/palette.html が存在する'
Chk (Test-Path -LiteralPath $paletteJsPath -PathType Leaf) 'www/assets/palette.js が存在する'
Chk (Test-Path -LiteralPath $catJsPath -PathType Leaf) 'www/assets/cat.js が存在する'

$paletteHtml = [System.IO.File]::ReadAllText($paletteHtmlPath)
$paletteJs = [System.IO.File]::ReadAllText($paletteJsPath)
$catJs = [System.IO.File]::ReadAllText($catJsPath)

# ============================================================ (a) 静的部
Write-Host '-- (a) static --'

Chk ($paletteHtml -match '<button id="palette-handoff"[^>]*\bdisabled\b[^>]*>CATで開く</button>') 'palette.html に「CATで開く」ボタンがあり、既定で押せない'

Chk ($paletteJs -match "var handoffStorageKey = 'yaku\.palette\.handoff';") 'palette.js が専用キー(yaku.palette.handoff)を持つ'
Chk ($catJs -match "var paletteHandoffStorageKey = 'yaku\.palette\.handoff';") 'cat.js が同じキー文字列を持つ(綴りのずれを防ぐ)'

# quick.jsのdraft退避(preserveDraft)と同じtry/catchの流儀。setItemの前後に
# try{...}catch(...){}を持つこと(壊れても画面を止めない)。
Chk ($paletteJs -match "try\s*\{\s*window\.sessionStorage\.setItem\(handoffStorageKey[\s\S]{0,200}?\}\s*catch") 'palette.js の退避はtry/catchで包む(quick.jsのdraft退避と同じ流儀)'
Chk ($paletteJs -match "window\.location\.assign\('/cat\?handoff=palette'\)") 'palette.js が /cat?handoff=palette へ遷移する(新規タブは開かない)'
Chk ($paletteJs -match "direction_intent:\s*currentDirectionIntent\(\)") 'palette.js が明示方向をdirection_intentとして退避する(currentDirectionIntentを再利用)'

# 押せる/押せないを1か所へ集めている(updateHandoffButton)。本文が無い・
# 翻訳ジョブ実行中(jobRunning)のどちらでも押せないこと。
Chk ($paletteJs -match 'handoffButton\.disabled = !input\.value\.trim\(\) \|\| busy;') 'palette.js は本文なし・busy(ジョブ実行中)のどちらでも押せない(1か所)'
Chk (($paletteJs -split 'updateHandoffButton\(').Count -ge 6) 'updateHandoffButton は複数の状態遷移点(ジョブ開始・完了・失敗・チップ)から呼ばれる'

# 読み捨て(read-once): getItemしてから消す。removeItemより先にgetItemが
# 現れること(順序を変異させると赤くなる)。
function Get-N9199FunctionText {
    param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$Name)
    $marker = 'function ' + $Name + '('
    $start = $Source.IndexOf($marker)
    if ($start -lt 0) { return '' }
    $depth = 0; $bodyStart = -1
    for ($i = $start; $i -lt $Source.Length; $i++) {
        $ch = $Source[$i]
        if ($ch -eq '{') { if ($depth -eq 0) { $bodyStart = $i }; $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0 -and $bodyStart -ge 0) { return $Source.Substring($start, ($i - $start) + 1) }
        }
    }
    return ''
}

$consumeText = Get-N9199FunctionText -Source $catJs -Name 'consumePaletteHandoff'
Chk (-not [string]::IsNullOrEmpty($consumeText)) 'cat.js から consumePaletteHandoff を取り出せる(前提条件)'
if (-not [string]::IsNullOrEmpty($consumeText)) {
    $getIdx = $consumeText.IndexOf('.getItem(paletteHandoffStorageKey)')
    $removeIdx = $consumeText.IndexOf('.removeItem(paletteHandoffStorageKey)')
    Chk ($getIdx -ge 0 -and $removeIdx -ge 0 -and $getIdx -lt $removeIdx) 'consumePaletteHandoff は getItem してから removeItem する(読み捨て、順序も見る)'
    Chk ($consumeText -match "window\.dispatchEvent\(new CustomEvent\('yaku-instant-handoff'") 'consumePaletteHandoff は既存の yaku-instant-handoff を dispatchEvent で呼ぶ(イベント再利用)'
    Chk ($consumeText -notmatch "el\('quick-input'\)" -and $consumeText -notmatch 'openSource\(') 'consumePaletteHandoff は quick-input を自分で書き換えたり openSource を自分で呼んだりしない(既存受け口の処理を複製しない)'
}

$startText = Get-N9199FunctionText -Source $catJs -Name 'start'
Chk (-not [string]::IsNullOrEmpty($startText)) 'cat.js から start() を取り出せる(前提条件)'
if (-not [string]::IsNullOrEmpty($startText)) {
    Chk ($startText -match "params\.get\('handoff'\) === 'palette' && consumePaletteHandoff\(\)") 'start() は ?handoff=palette のときだけ consumePaletteHandoff を呼ぶ'
}

# V9161のピン(window.addEventListener('yaku-instant-handoff'...)の窓)を、
# ここでも壊していないことを見る。字面はTest-YakuV9161CatProject.ps1と同じ。
Chk ($catJs -match "window\.addEventListener\('yaku-instant-handoff'[\s\S]{0,1600}?el\('quick-input'\)\.value = text;[\s\S]{0,160}?openSource\('text'") 'yaku-instant-handoff受け口(V9161のピン)を壊していない'
Chk ($catJs -match "openSource\('text', handoffDirection\)") '既存受け口は、パレットが運んできた方向をopenSourceへ渡せる(auto決め打ちのままではない)'

# ============================================================ (b) 実機Chromium部
Write-Host '-- (b) chromium --'

$driver = Join-Path (Join-Path $toolsRoot 'palette-handoff-screen') 'palette-handoff-gate.js'
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

. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in @($script:YakuSrcModuleFiles)) {
    if ($name -ne 'DesktopIntegration.ps1') { . (Join-Path (Join-Path $root 'src') $name) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9199-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }
$script:YakuRoot = $root
$settings = Read-YakuSettings -Root $root

# /api/cat/open の応答に使う、本物の作りかけプロジェクト。運転席は入力に
# 関わらずこれを返す。中身(project.id等)は見ない——見るのは実際に
# /api/cat/open へ飛んだ要求の中身(text・direction_intent)であって、
# レンダリング結果の題材はrender()が最後まで例外を投げずに走る土台でしかない。
$project = New-YakuCatTextProject -Root $root -Text 'この題材の中身は見ない(運転席の応答に使うだけ)。' -Settings $settings -Direction 'to_en'
$projectJson = ConvertTo-YakuCatProjectJson -Project $project

$utf8 = New-Object System.Text.UTF8Encoding($false)
$projectJsonPath = Join-Path $tmp 'project.json'
[IO.File]::WriteAllText($projectJsonPath, $projectJson, $utf8)
$observedPath = Join-Path $tmp 'observed.json'
$stderrPath = Join-Path $tmp 'node-stderr.txt'

$arguments = @($driver, (Join-Path $root 'www'), $projectJsonPath, $observedPath) | ForEach-Object { '"' + $_ + '"' }
$proc = Start-Process -FilePath $nodeExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardError $stderrPath
$nodeErr = ''
if (Test-Path -LiteralPath $stderrPath) { $nodeErr = [string][IO.File]::ReadAllText($stderrPath) }
Chk ([int]$proc.ExitCode -eq 0) ('運転席が走り切る' + $(if ($nodeErr) { ' / ' + $nodeErr.Substring(0, [Math]::Min(400, $nodeErr.Length)) } else { '' }))

$o = $null
if (Test-Path -LiteralPath $observedPath) { $o = [IO.File]::ReadAllText($observedPath, $utf8) | ConvertFrom-Json }
Chk ($null -ne $o) '画面で観測した事実を受け取れた'
if ($null -eq $o) { throw 'PALETTE_HANDOFF_GATE_NO_OBSERVATION' }
Chk (@($o.errors).Count -eq 0) ('ページ例外が無い(実測: ' + (($o.errors -join ' | ')) + ')')
Chk (@($o.console).Count -eq 0) ('console.error が無い(実測: ' + (($o.console -join ' | ')) + ')')

Write-Host '  -- A) /palette: ボタンの押せる/押せない、退避内容、遷移先 --'
Chk ([bool]$o.handoffDisabledWhenEmpty) '本文が無いあいだは「CATで開く」が押せない'
Chk ([bool]$o.handoffEnabledWithText) '本文を打つと押せるようになる(訳す前でもよい)'
Chk (@($o.assignCallsAfterClick).Count -eq 1 -and [string]$o.assignCallsAfterClick[0] -eq '/cat?handoff=palette') ('押すと /cat?handoff=palette へ遷移しようとする(実際 [' + (($o.assignCallsAfterClick -join ',')) + '])。新規タブは開かない')
Chk ($null -ne $o.storedHandoffPayload) '押すと sessionStorage の専用キーへ内容を退避する'
if ($null -ne $o.storedHandoffPayload) {
    Chk ([string]$o.storedHandoffPayload.text -eq 'エスカレーション対象の長文本文です。') ('退避した本文が実際に打った文章と一致する(実際: ' + [string]$o.storedHandoffPayload.text + ')')
    Chk ([string]$o.storedHandoffPayload.direction_intent -eq 'to_en') ('明示した方向(to_en)がdirection_intentとして退避される(実際: ' + [string]$o.storedHandoffPayload.direction_intent + ')')
}
Chk ([bool]$o.handoffDisabledWhileJobRunning) '翻訳ジョブ実行中は押せない(既存の busy 概念、jobRunningに従う)'
Chk ([bool]$o.handoffEnabledAfterJobDone) 'ジョブが完了すると再び押せるようになる'

Write-Host '  -- B) /cat: キー欠落は通常起動 --'
Chk ([string]$o.quickInputAfterEmptyKey -eq '') 'sessionStorageにキーが無ければ quick-input は空のまま(通常起動)'
Chk ([int]$o.openRequestsAfterEmptyKey -eq 0) 'キー欠落では /api/cat/open が飛ばない'

Write-Host '  -- E) /cat: 壊れたJSONも通常起動 --'
Chk ([string]$o.quickInputAfterBrokenJson -eq '') 'JSONが壊れていても例外にせず、quick-input は空のまま(通常起動)'
Chk ([int]$o.openRequestsAfterBrokenJson -eq 0) '壊れたJSONでは /api/cat/open が飛ばない'

Write-Host '  -- C) /cat: 本文ありは既存受け口へ実際に渡る --'
Chk ([string]$o.quickInputAfterHandoff -eq 'パレットから昇格した長文の本文です。数値は伏せて送ります。') ('quick-inputへ本文がそのまま入る(実際: ' + [string]$o.quickInputAfterHandoff + ')')
Chk (@($o.openRequestsAfterFirstHandoff).Count -eq 1) ('/api/cat/open が1回だけ飛ぶ(実際 ' + (@($o.openRequestsAfterFirstHandoff).Count) + '回)')
if (@($o.openRequestsAfterFirstHandoff).Count -eq 1) {
    $sentOpen = $o.openRequestsAfterFirstHandoff[0]
    Chk ([string]$sentOpen.text -eq 'パレットから昇格した長文の本文です。数値は伏せて送ります。') ('実際に飛んだ要求のtextが一致する(実際: ' + [string]$sentOpen.text + ')')
    Chk ([string]$sentOpen.direction_intent -eq 'to_en') ('実際に飛んだ要求のdirection_intentが、パレットで仕込んだ方向(to_en)と一致する(実際: ' + [string]$sentOpen.direction_intent + ')。auto決め打ちのままなら落ちる')
}
Chk ([string]::IsNullOrEmpty([string]$o.sessionStorageAfterFirstHandoff)) '読んだ直後、sessionStorageのキーは消えている(読み捨て)'
# showPicker()内のsyncLocation('')がまず/cat(クエリ無し)へreplaceStateし、
# 作業が開けた後はopenSource経由のrenderが改めてsyncLocation(project.id)を
# pushStateする。最終的なアドレスが /cat?project=<id> になること自体が、
# ?handoff=palette の付いたURLがreplaceStateで置き換え済みであることの
# 証拠になる(置き換えていなければ ?handoff=palette が残ったまま)。
Chk ([string]$o.urlAfterFirstHandoff -match '^http://127\.0\.0\.1:\d+/cat\?project=[a-f0-9]{32}$') ('/cat?handoff=palette が /cat?project=<id> へ置き換わる。?handoff=paletteが残っていない(実際: ' + [string]$o.urlAfterFirstHandoff + ')')

Write-Host '  -- D) /cat: 読み捨て(2回目は何も起きない) --'
Chk ([string]$o.quickInputAfterSecondHandoff -eq '') ('同じ ?handoff=palette をもう一度開いても quick-input は空のまま(実際: ' + [string]$o.quickInputAfterSecondHandoff + ')')
Chk ([int]$o.openRequestsAfterSecondHandoff -eq 0) '2回目は /api/cat/open が飛ばない(二重投入・再発火が起きない)'

if ($script:fail -eq 0) { Write-Host ('Test-YakuV9199PaletteHandoff: 検査 ' + $script:checks + ' 件、合格。') -ForegroundColor Green; exit 0 }
Write-Host ('Test-YakuV9199PaletteHandoff: 検査 ' + $script:checks + ' 件中 ' + $script:fail + ' 件が不合格。') -ForegroundColor Red
exit 1
