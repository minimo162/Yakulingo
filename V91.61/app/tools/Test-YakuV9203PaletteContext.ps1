<#
.SYNOPSIS
  パレットの文脈ポインタ（V91.61 #71）の回帰テスト。

.DESCRIPTION
  構想図の3接続の最後の1つ。パレット(/palette)に「この資料の文脈で訳す」
  選択を持たせ、期中修正のセルをコピーして貼ると、初回にCATで確定した
  言い回しがそのまま即答(instant)の候補1に返るようにする。

  設計判断（仕様書 palette-context-spec.md、審査基準）:
    1. 効かせる先は即答(instant)のみ。Copilotプロンプトへは注入しない。
    2. 選択肢は既存の /api/cat/ の recent アクションから取る。
    3. 保存はlocalStorageへid・表示名のみ（機密本文は保存しない）。
    4. サーバは /api/palette/instant に任意の context_project_id を追加。
       確定済みセグメントの完全一致(原文Ordinal、trim後)を、既存のTM欄
       より優先する候補(project_hit)として返す。プロジェクトの用語集
       (project+personal)もFind-YakuTerminologyMatchesへ混ぜる。
    5. 表示は既存の候補機構に乗せるだけ(#palette-tm-candidate を奪い合う。
       新しいカード・新しい行を増やさない)。
    6. translate/chipのPOSTにはcontextを渡さない(エンジン変更はスコープ外)。

  見るのは3つ。

  (a) 静的部。palette.html/js/css が、文脈選択の合図
      (#palette-context-select・localStorageキー・/api/cat/recentの呼び出し・
      project_hitの取り扱い)を持ち、既存のDOM契約(data-yaku-main-card等、
      V9195/V9199/V9200/V9202がピン)を壊していないこと。#palette-context-select
      が width:auto を明示すること(styles.cssのselect{width:100%}のままだと
      flex-wrapの行でこのselectだけが1行分を占めて強制改行し、480x640の
      幾何ゲートを崩す——#67 B1の教訓、実測で確認済み)。

  (b) サーバ単体。実際のInvoke-YakuRoute(Server.ps1からAST抽出、V9195と
      同じ手法——Server.ps1を丸ごとdot-sourceすると入口の待ち受けが動く
      ため)へ、実際のCatProject.ps1が作った資料(確定セグメント入り)を
      使って/api/palette/instantを直接叩く。

      実装前の確認(報告のみ、停止不要)の実測もここで行う:
        - recentアクションの応答形は investigation 済み(id/file_name/
          direction等、Get-YakuCatRecentProjectRows)。POST /api/cat/recent
          は既存の境界チェック(path.StartsWith('/api/cat/'))をそのまま通る。
        - プロジェクト読込(Restore-YakuCatProject)のコストを、600行規模の
          資料で実測し、Write-Hostへ出す(仕様書 実装前の確認 item 2)。
        - 方向の食い違いガード(item 3)を、実際に方向の違う資料で確かめる。

  (c) 実機Chromium部。本物のpalette.html/js/cssを配り、起動時に選べる
      資料が並ぶ→選ぶとlocalStorageへid・表示名だけが残る→貼ると
      project_hitが候補1になる(同時にTM完全一致が来てもproject_hitが
      勝つ)→Enter/1キーでコピー→「なし」へ戻すと従来どおり→資料が
      一覧から消えていれば無言でフォールバック→まだ一覧にあれば
      再読み込みだけで操作ゼロのまま選択が戻る、を実際に押して確かめる。
      node/Playwright/Chromium が無い環境では UNMEASURED(exit 3)にする。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9203PaletteContext.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$N9203Root = Split-Path -Parent $PSScriptRoot
$N9203Src = Join-Path $N9203Root 'src'
$N9203Www = Join-Path $N9203Root 'www'
$script:N9203Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9203 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9203Failures.Add($Message) }
}

Write-Host 'Test-YakuV9203PaletteContext'

# ============================================================ (a) 静的部
Write-Host '-- static --'

$N9203PaletteHtmlPath = Join-Path $N9203Www 'palette.html'
$N9203PaletteJsPath = Join-Path $N9203Www 'assets\palette.js'
$N9203PaletteCssPath = Join-Path $N9203Www 'assets\palette.css'

Assert-N9203 (Test-Path -LiteralPath $N9203PaletteHtmlPath -PathType Leaf) 'www/palette.html が存在する'
Assert-N9203 (Test-Path -LiteralPath $N9203PaletteJsPath -PathType Leaf) 'www/assets/palette.js が存在する'
Assert-N9203 (Test-Path -LiteralPath $N9203PaletteCssPath -PathType Leaf) 'www/assets/palette.css が存在する'

if (Test-Path -LiteralPath $N9203PaletteHtmlPath -PathType Leaf) {
    $N9203Html = [IO.File]::ReadAllText($N9203PaletteHtmlPath, [Text.UTF8Encoding]::new($false))
    Assert-N9203 ($N9203Html -match 'id="palette-context-select"') 'palette.html に文脈選択(#palette-context-select)がある'
    Assert-N9203 ($N9203Html -match '文脈: なし') 'palette.html の既定選択肢が「文脈: なし」'
    # 新しい行を増やさない(#67 B1の教訓)。direction-row(既存)の内側に
    # 収まっていること——別の.palette-*-rowを新設していないことを見る。
    if ($N9203Html -match '(?s)<div class="palette-direction-row">(.*?)</div>\s*</form>') {
        Assert-N9203 ($Matches[1] -match 'id="palette-context-select"') '文脈選択は既存のdirection-rowの内側に同居する(新しい行を増やさない)'
    } else {
        Assert-N9203 $false 'direction-rowの中身を取り出せる(前提条件)'
    }
    # 既存のDOM契約を壊していない。
    Assert-N9203 ($N9203Html -match 'id="palette-direction-select"') 'palette.html の翻訳先セレクトが残っている(V9195のピン)'
    Assert-N9203 ($N9203Html -match 'id="palette-handoff"') 'palette.html のCATで開くボタンが残っている(V9199のピン)'
}

if (Test-Path -LiteralPath $N9203PaletteJsPath -PathType Leaf) {
    $N9203Js = [IO.File]::ReadAllText($N9203PaletteJsPath, [Text.UTF8Encoding]::new($false))
    Assert-N9203 ($N9203Js -match "var paletteContextStorageKey = 'yaku\.palette\.context';") 'palette.js が文脈の専用localStorageキーを持つ'
    Assert-N9203 ($N9203Js -match "function initContextPicker") 'palette.js が起動時の一覧取得・復元関数を持つ'
    Assert-N9203 ($N9203Js -match "YakuCommon\.post\('/api/cat/recent'") 'palette.js が既存の /api/cat/recent を呼ぶ(新しい一覧APIを作らない)'
    Assert-N9203 ($N9203Js -match "function loadContextSelection") 'palette.js が保存済み選択の読み出し関数を持つ'
    Assert-N9203 ($N9203Js -match "function saveContextSelection") 'palette.js が選択の保存関数を持つ'
    # 保存はid・表示名のみ(本文を含まない、設計判断3)。
    $N9203SaveBody = ''
    if ($N9203Js -match "(?s)function saveContextSelection\(id, name\) \{(.*?)\n  \}") { $N9203SaveBody = $Matches[1] }
    Assert-N9203 (-not [string]::IsNullOrWhiteSpace($N9203SaveBody)) 'saveContextSelection の本体を取り出せる(前提条件)'
    if (-not [string]::IsNullOrWhiteSpace($N9203SaveBody)) {
        Assert-N9203 ($N9203SaveBody -match 'JSON\.stringify\(\{ id: id, name: name \}\)') 'saveContextSelection が保存するのはid・nameだけ(本文を保存しない、設計判断3)'
    }
    Assert-N9203 ($N9203Js -match "context_project_id: currentContextProjectId\(\)") 'palette.js が /api/palette/instant へ context_project_id を渡す'
    # translate/chipには文脈を渡さない(設計判断6、スコープ外)。
    $N9203TranslateCallLine = (@($N9203Js -split "`n") | Where-Object { $_ -match "post\('/api/palette/translate'" })
    Assert-N9203 (@($N9203TranslateCallLine).Count -ge 1 -and -not (@($N9203TranslateCallLine) -match 'context_project_id')) '/api/palette/translate の呼び出しに context_project_id を渡さない(設計判断6)'
    $N9203ChipCallLine = (@($N9203Js -split "`n") | Where-Object { $_ -match "post\('/api/palette/chip'" })
    Assert-N9203 (@($N9203ChipCallLine).Count -ge 1 -and -not (@($N9203ChipCallLine) -match 'context_project_id')) '/api/palette/chip の呼び出しに context_project_id を渡さない(設計判断6)'
    Assert-N9203 ($N9203Js -match "data-yaku-context-hit") 'palette.js が文脈ヒットの合図(data-yaku-context-hit)を持つ'
    Assert-N9203 ($N9203Js -match "この資料の確定訳") 'palette.js が文脈ヒットのラベル文言を持つ(設計判断5)'
    # 既存の候補機構に乗せるだけ(新しいコピー配線を作らない、設計判断5)。
    # #palette-tm-candidate を奪い合う形になっている(新しいid/カードを作らない)。
    Assert-N9203 (@([regex]::Matches($N9203Js, "card\.id = 'palette-tm-candidate';")).Count -eq 1) 'project_hit/tmは同じ器(#palette-tm-candidate)を奪い合う(新しいカードを作らない)'
    Assert-N9203 ($N9203Js -match 'hasProjectHit \? String\(projectHit\.target\) : String\(data\.tm\.target\)') 'renderInstant はproject_hitがあればそちらを優先する(既存のTM欄より優先、設計判断4)'
    # 既存のDOM契約(V9195/V9199/V9200/V9202がピン)が残っている。
    Assert-N9203 ($N9203Js -match 'function refreshCandidates') 'palette.js の refreshCandidates が残っている'
    Assert-N9203 ($N9203Js -match 'function ensureLearnButtonFor') 'palette.js の学習釦配線(ensureLearnButtonFor)が残っている'
    Assert-N9203 ($N9203Js -match 'function applyBilingualView') 'palette.js の対訳並置ビュー(V9202)が残っている'
    Assert-N9203 ($N9203Js -match "handoffStorageKey = 'yaku\.palette\.handoff';") 'palette.js の昇格キー(V9199のピン)が残っている'
}

if (Test-Path -LiteralPath $N9203PaletteCssPath -PathType Leaf) {
    $N9203Css = [IO.File]::ReadAllText($N9203PaletteCssPath, [Text.UTF8Encoding]::new($false))
    Assert-N9203 ($N9203Css -match '#palette-context-select\s*\{[^}]*width:\s*auto') '#67 B1の教訓: #palette-context-selectがwidth:autoを明示する(styles.cssのselect{width:100%}のままだと強制改行して幾何ゲートを崩す)'
    Assert-N9203 ($N9203Css -match '#palette-context-select\s*\{[^}]*max-width:\s*92px') '#palette-context-select が幅の上限を持つ(資料名の長さで伸びない)'
}

# ==================================================== (b) サーバ単体（本物の関数）
Write-Host '-- server (real functions) --'

. (Join-Path $N9203Src 'SrcModules.ps1')
foreach ($N9203File in @($script:YakuSrcModuleFiles)) {
    if ($N9203File -ne 'DesktopIntegration.ps1') { . (Join-Path $N9203Src $N9203File) }
}

$N9203Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9203-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $N9203Temp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $N9203Temp 'user-data'
$script:YakuRoot = $N9203Root
$settings = Read-YakuSettings -Root $N9203Root

function Get-N9203FunctionText {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Language.ScriptBlockAst]$Ast, [Parameter(Mandatory=$true)][string]$Name)
    $found = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return $null }
    return [string]$found[0].Extent.Text
}

$N9203ServerPath = Join-Path $N9203Src 'Server.ps1'
$N9203Tokens = $null; $N9203ParseErrors = $null
$N9203ServerAst = [System.Management.Automation.Language.Parser]::ParseFile($N9203ServerPath, [ref]$N9203Tokens, [ref]$N9203ParseErrors)
Assert-N9203 (@($N9203ParseErrors).Count -eq 0) 'Server.ps1 が構文エラー無く解析できる'

# Invoke-YakuRouteの/api/cat/recentはGet-YakuCatRecentProjectRows(同じく
# Server.ps1内、CatProject.ps1側ではない)を呼ぶので、一緒に取り出す。
$N9203ExtractNames = @('Invoke-YakuRoute', 'Get-YakuCatRecentProjectRows')
$N9203ExtractTexts = New-Object System.Collections.Generic.List[string]
foreach ($N9203Name in $N9203ExtractNames) {
    $N9203Text = Get-N9203FunctionText -Ast $N9203ServerAst -Name $N9203Name
    Assert-N9203 (-not [string]::IsNullOrWhiteSpace($N9203Text)) ('Server.ps1 から ' + $N9203Name + ' を取り出せる')
    if ($N9203Text) { [void]$N9203ExtractTexts.Add($N9203Text) }
}
if ($N9203ExtractTexts.Count -eq $N9203ExtractNames.Count) {
    . ([scriptblock]::Create(($N9203ExtractTexts.ToArray() -join "`n`n")))
}

Set-Item -Path Function:Assert-YakuRequestBoundary -Value { param($Request, $Path, $Method) }
Set-Item -Path Function:Clear-YakuExpiredUploads -Value { param() }
Set-Item -Path Function:Convert-YakuExceptionToUserMessage -Value { param($ErrorRecord) return [string]$ErrorRecord.Exception.Message }
Set-Item -Path Function:Read-YakuRequestJson -Value { param($Request, [int64]$MaxBytes = 0); return $script:N9203Payload }

$script:N9203SentText = ''
$script:N9203SentStatus = 200
Set-Item -Path Function:Send-YakuTextResponse -Value {
    param($Context, [string]$Text, [string]$ContentType = '', [int]$StatusCode = 200, [switch]$AllowWasm)
    $script:N9203SentText = $Text
    $script:N9203SentStatus = $StatusCode
}

$script:YakuTranslateJobs = @{}
$script:YakuTranslateJobHandles = @{}
$script:YakuLastUploadSweep = Get-Date
$script:ActivePort = 39203
$script:YakuAdminMode = $false
if (-not (Test-Path Variable:script:YakuCatProjects)) { $script:YakuCatProjects = @{} }

function Invoke-N9203Route {
    param([string]$Method, [string]$Path, [hashtable]$Payload = @{})
    $script:N9203Payload = $Payload
    $script:N9203SentText = ''
    $script:N9203SentStatus = 200
    $req = [pscustomobject]@{ Url = [uri]('http://127.0.0.1' + $Path); HttpMethod = $Method; Headers = @{} }
    $context = [pscustomobject]@{ Request = $req }
    $routeException = ''
    try { Invoke-YakuRoute -Context $context } catch { $routeException = [string]$_.Exception.Message }
    $body = $null
    try { $body = $script:N9203SentText | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Exception = $routeException; Status = $script:N9203SentStatus; Body = $body; Text = $script:N9203SentText }
}

# --- 実装前の確認: /api/cat/recent の応答形と境界チェック ------------------
# (報告用に検証済みの前提を、ここでも実際に叩いて確かめる)
$N9203RecentCheck = Invoke-N9203Route -Method 'POST' -Path '/api/cat/recent' -Payload @{}
Assert-N9203 ([string]::IsNullOrWhiteSpace($N9203RecentCheck.Exception)) ('POST /api/cat/recent が例外を出さない(既存の境界チェックpath.StartsWith(/api/cat/)を通る): ' + $N9203RecentCheck.Exception)
Assert-N9203 ($null -ne $N9203RecentCheck.Body -and ($N9203RecentCheck.Body.PSObject.Properties.Name -contains 'projects')) 'POST /api/cat/recent が projects 配列を返す(実装前の確認item1、応答形はid/file_name/direction等)'

# --- 資料(文脈プロジェクト)を用意する -------------------------------------
# ProjectA: to_en、3セグメント。0番は確定済み(完全一致の的)、1番は
# 未確定(確定していないと出さないことを見る)、2番は確定だが別文。
$N9203MatchSource = '御社の今期決算の言い回しは確定済みの表現でご案内します。'
$N9203MatchTarget = 'We will describe this fiscal year''s results using the finalized wording for this document.'
$N9203OtherSource = 'これは別の一致しない原文です。'
$N9203OtherTarget = 'This is a different, non-matching source sentence.'
$N9203UnconfirmedSource = 'これは未確定のままの原文です。'

$N9203ProjA = New-YakuCatTextProject -Root $N9203Root -Text ($N9203MatchSource + "`n" + $N9203UnconfirmedSource + "`n" + $N9203OtherSource) -Settings $settings -Direction 'to_en' -Register:$false
Assert-N9203 (@($N9203ProjA.Segments).Count -eq 3) '題材ProjectAが3セグメントに分かれる(前提条件)'
# Confirmedはstate派生プロパティ(Initialize-YakuCatProjectStateがSegment.State
# =='reviewed'から毎回計算し直す、CatProject.ps1:574)。.Confirmedだけを直接
# 立てても、Copy-YakuCatProjectForMutation(Commit内で必ず通る)の
# Initialize-YakuCatProjectStateで無条件に上書きされて消える(実測、デバッグで
# 確認済み)。試験の種はSet-YakuCatSegmentConfirmedと同じ組(State='reviewed'+
# Confirmed=$true)で立てる。
$N9203ProjA.Segments[0].Translation = $N9203MatchTarget
$N9203ProjA.Segments[0].State = 'reviewed'
$N9203ProjA.Segments[0].Confirmed = $true
$N9203ProjA.Segments[1].Translation = 'Draft, not confirmed yet.'
$N9203ProjA.Segments[1].State = 'machine_draft'
$N9203ProjA.Segments[1].Confirmed = $false
$N9203ProjA.Segments[2].Translation = $N9203OtherTarget
$N9203ProjA.Segments[2].State = 'reviewed'
$N9203ProjA.Segments[2].Confirmed = $true
$N9203ProjA.FileName = 'A社_決算資料.xlsx'
$N9203ProjA = Commit-YakuNewCatProject -Project $N9203ProjA
Assert-N9203 ($N9203ProjA.Id -match '^[a-f0-9]{32}$') 'ProjectAが32桁16進のIDでコミットされる(前提条件)'
Assert-N9203 ([bool]$N9203ProjA.Segments[0].Confirmed -and [bool]$N9203ProjA.Segments[2].Confirmed -and -not [bool]$N9203ProjA.Segments[1].Confirmed) 'ProjectAの確定状態がコミット後も種のとおり(0/2確定・1未確定、前提条件)'

# ProjectC: to_en(向きが逆)。英文は自動判定で to_jp になる
# (Test-YakuJapaneseText の定義どおり、日本語だけがto_enと判定される)ので、
# to_enの資料へ英文を貼れば必ず向きが食い違う——方向の食い違いガード
# (item 3)を見るための題材。
$N9203MismatchSource = 'Revenue increased significantly this quarter.'
$N9203ProjC = New-YakuCatTextProject -Root $N9203Root -Text $N9203MismatchSource -Settings $settings -Direction 'to_en' -Register:$false
$N9203ProjC.Segments[0].Translation = [string][char]0x53CE + [char]0x76CA + [char]0x306F + [char]0x5927 + [char]0x5E45 + [char]0x306B + [char]0x5897 + [char]0x52A0 + [char]0x3057 + [char]0x305F + [char]0x3002
$N9203ProjC.Segments[0].State = 'reviewed'
$N9203ProjC.Segments[0].Confirmed = $true
$N9203ProjC.FileName = 'C社_逆方向資料.xlsx'
$N9203ProjC = Commit-YakuNewCatProject -Project $N9203ProjC
Assert-N9203 ([bool]$N9203ProjC.Segments[0].Confirmed) 'ProjectCの確定状態がコミット後も種のとおり(前提条件)'

Write-Host '-- /api/palette/instant: context_project_id の有無・実在性・方向 --'

# 1) 文脈なし: 従来どおり。TMだけを引く(project_hitはnull)。
$N9203TmAdd = Add-YakuTranslationMemoryEntry -Source $N9203MatchSource -Target 'TM decoy (must lose to project_hit when context selected).' -Direction 'to_en' `
    -OriginProjectId '99999999999999999999999999999999' -OriginFileName 'unrelated.xlsx' `
    -OriginSegmentId ((Get-YakuTranslationMemoryHash -Text $N9203MatchSource).Substring(0, 32)) `
    -OriginLocation 'Sheet1, A1' -OriginPage 1 -ReviewRevision 1
Assert-N9203 ([bool]$N9203TmAdd.Added) 'TM完全一致の種を仕込めた(前提条件)'

$N9203NoContext = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203MatchSource; direction_intent = 'auto' }
Assert-N9203 ([string]::IsNullOrWhiteSpace($N9203NoContext.Exception)) ('文脈なしで例外を出さない: ' + $N9203NoContext.Exception)
Assert-N9203 ($null -eq $N9203NoContext.Body.project_hit) '文脈なしなら project_hit は null(従来どおり)'
Assert-N9203 ($null -ne $N9203NoContext.Body.tm -and [string]$N9203NoContext.Body.tm.target -eq 'TM decoy (must lose to project_hit when context selected).') '文脈なしなら従来どおりTM完全一致がそのまま出る(UX検収基準: 文脈なし時の挙動は従来と同一)'

# 2) 文脈あり(ProjectA、稼働中=メモリ): 完全一致・方向一致 → project_hitが
#    TMより優先して返る(両方とも応答には独立に乗る。優先の判定はクライアント側)。
$N9203WithContext = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203MatchSource; direction_intent = 'auto'; context_project_id = $N9203ProjA.Id }
Assert-N9203 ([string]::IsNullOrWhiteSpace($N9203WithContext.Exception)) ('文脈ありで例外を出さない: ' + $N9203WithContext.Exception)
Assert-N9203 ($null -ne $N9203WithContext.Body.project_hit) '文脈あり・完全一致・方向一致なら project_hit が返る'
if ($null -ne $N9203WithContext.Body.project_hit) {
    Assert-N9203 ([string]$N9203WithContext.Body.project_hit.source -eq $N9203MatchSource) 'project_hit.source が確定済みセグメントの原文と一致する'
    Assert-N9203 ([string]$N9203WithContext.Body.project_hit.target -eq $N9203MatchTarget) 'project_hit.target が確定済みセグメントの訳文と一致する'
    Assert-N9203 ([string]$N9203WithContext.Body.project_hit.project_name -eq 'A社_決算資料.xlsx') 'project_hit.project_name が資料名(FileName)と一致する'
}
Assert-N9203 ($null -ne $N9203WithContext.Body.tm) 'tmは文脈の有無に関わらず独立に計算される(project_hitと同時に返ってよい、優先の決着はクライアント側)'

# 3) 実在しない32桁16進ID: 黙って無視(従来動作)。
$N9203MissingId = 'deadbeefdeadbeefdeadbeefdeadbeef'
$N9203Missing = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203MatchSource; direction_intent = 'auto'; context_project_id = $N9203MissingId }
Assert-N9203 ([string]::IsNullOrWhiteSpace($N9203Missing.Exception)) ('実在しないIDでも例外を出さない: ' + $N9203Missing.Exception)
Assert-N9203 ($null -eq $N9203Missing.Body.project_hit) '実在しない資料IDなら project_hit は null(黙って無視)'

# 4) 壊れた/不正な形式のcontext_project_id(32桁16進でない): 同じく無視。
# CLAUDE.md PowerShell 5.1の落とし穴: 「@($a - $b, $a + $b) はカンマが先に
# 結合する」。ここでも同じ罠を踏んだ(実測): 括弧を省くと
# @('a','b','','x' * 5000) が (配列4件) * 5000 = 20000件の配列になり、
# ループが20000回×2アサーションで実質無限ループのように固まった。
# 掛け算の対象は必ず括弧で明示する。
$N9203LongBadId = ('x' * 5000)
foreach ($N9203BadId in @('not-a-hex-id', '../../etc/passwd', '', $N9203LongBadId)) {
    $N9203Bad = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203MatchSource; direction_intent = 'auto'; context_project_id = $N9203BadId }
    Assert-N9203 ([string]::IsNullOrWhiteSpace($N9203Bad.Exception) -and $N9203Bad.Status -ne 500 -and $N9203Bad.Status -ne 409) ('壊れたcontext_project_id(' + $N9203BadId.Substring(0, [Math]::Min(20, $N9203BadId.Length)) + '...)でも409/500にしない(実測status=' + $N9203Bad.Status + ')')
    Assert-N9203 ($null -eq $N9203Bad.Body.project_hit) ('壊れたcontext_project_idなら project_hit は null')
}

# 5) 文脈はあるが一致しない原文: project_hitはnull。
$N9203NoMatch = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = 'これはどのセグメントとも一致しない文です。'; direction_intent = 'auto'; context_project_id = $N9203ProjA.Id }
Assert-N9203 ($null -eq $N9203NoMatch.Body.project_hit) '一致しない原文なら project_hit は null'

# 6) 未確定セグメントとは完全一致しても出さない。
$N9203Unconfirmed = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203UnconfirmedSource; direction_intent = 'auto'; context_project_id = $N9203ProjA.Id }
Assert-N9203 ($null -eq $N9203Unconfirmed.Body.project_hit) '未確定セグメントとの完全一致は project_hit にならない(確定済みだけを見る)'

# 7) 方向の食い違い(ProjectCはto_en、原文は英語=to_jpと判定される): 出さない。
$N9203Mismatch = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203MismatchSource; direction_intent = 'auto'; context_project_id = $N9203ProjC.Id }
Assert-N9203 ([string]$N9203Mismatch.Body.direction -eq 'to_jp') '方向食い違い題材: この英文は to_jp と判定される(前提条件、Test-YakuJapaneseTextの定義どおり)'
Assert-N9203 ($null -eq $N9203Mismatch.Body.project_hit) '文脈プロジェクトの方向(to_en)と判定方向(to_jp)が食い違えば project_hit を出さない(設計判断・実装前の確認item3)'

Write-Host '-- 実装前の確認: プロジェクト読込のコスト(ディスク復元経路) --'

# 8) メモリから追い出し、Restore-YakuCatProjectの経路を実際に踏ませる。
#    /api/cat/resumeと同じ二段構え(Get-YakuCatProject→無ければRestore)。
#    このブロックは下のterms(用語集)試験より先に置く——terms試験が
#    ProjectAへ新しいproject scopeの用語(御社)を足すと、
#    Initialize-YakuCatProjectStateの用語スナップショット差分検知
#    (CatProject.ps1:576-590)が確定済みセグメントを'stale'へ落とす
#    (実測で確認: 順序を入れ替える前は本試験がここでNGになった。
#    これはアプリの意図した動作——用語が変わったら確定済みの点検は
#    古くなる、CLAUDE.mdのsegment-qc-not-currentと同じ理屈——であって
#    実装の欠陥ではないが、この試験の関心はRestore経路そのものなので、
#    影響を受けない順序に置く)。
$null = $script:YakuCatProjects.Remove([string]$N9203ProjA.Id)
$N9203Restored = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203MatchSource; direction_intent = 'auto'; context_project_id = $N9203ProjA.Id }
Assert-N9203 ($null -ne $N9203Restored.Body.project_hit -and [string]$N9203Restored.Body.project_hit.target -eq $N9203MatchTarget) 'メモリに無い場合はRestore-YakuCatProjectへ落ちて、それでも project_hit が返る(/api/cat/resumeと同じ二段構え)'

# 600セグメント規模の資料でコスト実測(仕様書「実装前の確認」item2)。
$N9203LargeLines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt 600; $i++) { [void]$N9203LargeLines.Add('これは実測用の第' + $i + '文です。数値' + $i + 'を含みます。') }
$N9203LargeText = [string]::Join("`n", $N9203LargeLines.ToArray())
$N9203ProjLarge = New-YakuCatTextProject -Root $N9203Root -Text $N9203LargeText -Settings $settings -Direction 'to_en' -Register:$false
Assert-N9203 (@($N9203ProjLarge.Segments).Count -ge 500) ('大規模題材が実際に500行以上に分かれる(実測 ' + (@($N9203ProjLarge.Segments).Count) + '行、前提条件)')
$N9203LargeMatchIndex = [Math]::Floor(@($N9203ProjLarge.Segments).Count / 2)
$N9203LargeMatchSource = [string]$N9203ProjLarge.Segments[$N9203LargeMatchIndex].Text
$N9203LargeMatchTarget = 'Large-project confirmed translation at the middle row.'
for ($i = 0; $i -lt @($N9203ProjLarge.Segments).Count; $i++) {
    if ($i -eq $N9203LargeMatchIndex) { $N9203ProjLarge.Segments[$i].Translation = $N9203LargeMatchTarget }
    else { $N9203ProjLarge.Segments[$i].Translation = ('draft ' + $i) }
    # Confirmedはstate派生(上のProjectAと同じ理由でState='reviewed'も要る)。
    $N9203ProjLarge.Segments[$i].State = 'reviewed'
    $N9203ProjLarge.Segments[$i].Confirmed = $true
}
$N9203ProjLarge.FileName = '大規模資料_600行.xlsx'
$N9203ProjLarge = Commit-YakuNewCatProject -Project $N9203ProjLarge
Assert-N9203 ([bool]$N9203ProjLarge.Segments[$N9203LargeMatchIndex].Confirmed) '大規模題材の確定状態がコミット後も種のとおり(前提条件)'
$null = $script:YakuCatProjects.Remove([string]$N9203ProjLarge.Id)

$N9203Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$N9203LargeResult = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203LargeMatchSource; direction_intent = 'auto'; context_project_id = $N9203ProjLarge.Id }
$N9203Stopwatch.Stop()
Write-Host ('  info 実装前の確認(item2): 600行規模の資料をディスクから復元してinstantを1回処理する所要時間 = ' + $N9203Stopwatch.ElapsedMilliseconds + 'ms(貼り付けごとに1回なので許容想定、仕様書どおり)')
Assert-N9203 ($null -ne $N9203LargeResult.Body.project_hit -and [string]$N9203LargeResult.Body.project_hit.target -eq $N9203LargeMatchTarget) '600行規模でもRestore経由で正しい project_hit が返る'
Assert-N9203 ($N9203Stopwatch.ElapsedMilliseconds -lt 5000) ('600行規模の実測が5秒未満(実測 ' + $N9203Stopwatch.ElapsedMilliseconds + 'ms、貼り付けごとに1回の許容想定)')

Write-Host '-- terms: project+personal 統合、project優先 --'

# 8) 用語集の統合。同じ日本語エイリアスに personal と project(ProjectA)の
#    両方を仕込み、文脈ありでは project が勝ち、文脈なしでは personal のみ。
# 御社
$N9203Alias = [string]([char]0x5FA1) + [string]([char]0x793E)
$N9203PersonalTarget = 'your firm (personal)'
$N9203ProjectTarget = 'your company (project A)'
$N9203PersonalAdd = Add-YakuTerminologyEntry -Scope personal -Kind occurrence -Enforcement advisory `
    -JapanesePreferred $N9203Alias -EnglishPreferred $N9203PersonalTarget -Origin 'palette-9203-test' `
    -OriginProjectId '11111111111111111111111111111111' -OriginFileName 'x.xlsx' `
    -OriginSegmentId '22222222222222222222222222222222' -OriginLocation 'Sheet1, A1' -OriginRevision 1
Assert-N9203 ([bool]$N9203PersonalAdd.Added) '個人スコープの用語を仕込めた(前提条件)'
$N9203ProjectAdd = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$N9203ProjA.Id) -Kind occurrence -Enforcement advisory `
    -JapanesePreferred $N9203Alias -EnglishPreferred $N9203ProjectTarget -Origin 'palette-9203-test' `
    -OriginProjectId ([string]$N9203ProjA.Id) -OriginFileName 'A社_決算資料.xlsx' `
    -OriginSegmentId '33333333333333333333333333333333' -OriginLocation 'Sheet1, A1' -OriginRevision 1
Assert-N9203 ([bool]$N9203ProjectAdd.Added) 'プロジェクトスコープの用語を仕込めた(前提条件)'

$N9203TermText = $N9203Alias + [string][char]0x306B + [char]0x3054 + [char]0x6848 + [char]0x5185 + [char]0x3057 + [char]0x307E + [char]0x3059 + [char]0x3002

$N9203TermsNoContext = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203TermText; direction_intent = 'auto' }
$N9203RowsNoContext = @($N9203TermsNoContext.Body.terms | Where-Object { [string]$_.source -eq $N9203Alias })
Assert-N9203 ($N9203RowsNoContext.Count -eq 1 -and [string]$N9203RowsNoContext[0].target -eq $N9203PersonalTarget) '文脈なしでは個人スコープの用語だけが出る(従来どおり、project語は混ざらない)'

$N9203TermsWithContext = Invoke-N9203Route -Method 'POST' -Path '/api/palette/instant' -Payload @{ text = $N9203TermText; direction_intent = 'auto'; context_project_id = $N9203ProjA.Id }
$N9203RowsWithContext = @($N9203TermsWithContext.Body.terms | Where-Object { [string]$_.source -eq $N9203Alias })
Assert-N9203 ($N9203RowsWithContext.Count -eq 1 -and [string]$N9203RowsWithContext[0].target -eq $N9203ProjectTarget) '文脈ありでは同じ位置の重複でproject語が勝つ(Find-YakuTerminologyMatchesの既存ScopeWeight規則そのまま、統合ロジックを新設しない)'

# ============================================================ (c) 実機Chromium部
Write-Host '-- chromium --'

$N9203Unmeasured = 3
$N9203Driver = Join-Path $PSScriptRoot 'palette-context-screen\palette-context-gate.js'
$N9203Node = Get-Command node -ErrorAction SilentlyContinue
$N9203ChromiumOk = $false
$N9203ChromiumNote = ''
if ($null -eq $N9203Node -or -not (Test-Path -LiteralPath $N9203Driver -PathType Leaf)) {
    $N9203ChromiumNote = 'node またはドライバが見つからない'
} else {
    $N9203NodeExe = [string]$N9203Node.Source
    $N9203ProbeDir = (Split-Path -Parent $N9203Driver).Replace('\', '/')
    $null = & $N9203NodeExe -e ("try{require.resolve('playwright',{paths:['" + $N9203ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
    if ($LASTEXITCODE -ne 0) {
        $N9203ChromiumNote = 'Playwright が見つからない'
    } else {
        $N9203ChromiumPath = & $N9203NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $N9203ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$N9203ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$N9203ChromiumPath) -PathType Leaf)) {
            $N9203ChromiumNote = 'Playwright Chromium が見つからない'
        } else {
            $N9203ChromiumOk = $true
        }
    }
}

$N9203StaticFailed = ($script:N9203Failures.Count -gt 0)

if (-not $N9203ChromiumOk) {
    Write-Host ('UNMEASURED: ' + $N9203ChromiumNote)
    if ($N9203StaticFailed) {
        Write-Host ''
        Write-Host ('FAIL ' + $script:N9203Failures.Count + ' assertion(s) (static/server part)')
        foreach ($f in $script:N9203Failures) { Write-Host ('  - ' + $f) }
        exit 1
    }
    exit $N9203Unmeasured
}

$N9203Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9203-chromium-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $N9203Work -Force
$N9203OutJson = Join-Path $N9203Work 'out.json'
& $N9203NodeExe $N9203Driver $N9203Www $N9203OutJson
$N9203DriverExit = $LASTEXITCODE
Assert-N9203 ($N9203DriverExit -eq 0 -and (Test-Path -LiteralPath $N9203OutJson -PathType Leaf)) 'Chromiumドライバが完走し、観察結果を書き出した'

if (Test-Path -LiteralPath $N9203OutJson -PathType Leaf) {
    $N9203Observed = Get-Content -LiteralPath $N9203OutJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pageError in @($N9203Observed.errors)) { Write-Host ('  Chromium error: ' + [string]$pageError) }
    foreach ($consoleError in @($N9203Observed.console)) { Write-Host ('  Chromium console: ' + [string]$consoleError) }
    Assert-N9203 (@($N9203Observed.errors).Count -eq 0) '実機ページでJSエラーが出ない'
    Assert-N9203 (@($N9203Observed.console).Count -eq 0) '実機ページでconsole.errorが出ない'

    Write-Host '-- A) 起動時: 選べる資料が並ぶ --'
    $N9203InitialOptions = @($N9203Observed.initialOptionValues)
    Assert-N9203 ($N9203InitialOptions.Count -eq 3) ('起動時のoption数が3(なし+資料2件、実際 ' + $N9203InitialOptions.Count + ')')
    Assert-N9203 ([string]$N9203InitialOptions[0].value -eq '') '先頭は「文脈: なし」(value空)のまま'
    Assert-N9203 (@($N9203InitialOptions | Where-Object { $_.text -match 'A社_決算資料\.xlsx' }).Count -eq 1) '/api/cat/recent で取得した資料名がoptionに反映される'

    Write-Host '-- B) 選ぶとlocalStorageへid・表示名だけ --'
    $N9203Saved = $N9203Observed.localStorageAfterSelect
    Assert-N9203 ($null -ne $N9203Saved) '選ぶとlocalStorageに何か保存される'
    if ($null -ne $N9203Saved) {
        $N9203SavedProps = @($N9203Saved.PSObject.Properties.Name | Sort-Object)
        Assert-N9203 (($N9203SavedProps -join ',') -eq 'id,name') ('localStorageに保存されるキーが id・name だけ(実際: ' + ($N9203SavedProps -join ',') + ')、設計判断3(本文を保存しない)')
        Assert-N9203 ([string]$N9203Saved.name -eq 'A社_決算資料.xlsx') 'localStorageのnameが選んだ資料名と一致する'
    }

    Write-Host '-- C) 貼るとproject_hitが候補1(TMが同時に来ても勝つ) --'
    $N9203Reqs = @($N9203Observed.instantRequestsWithContext)
    Assert-N9203 ($N9203Reqs.Count -ge 1 -and [string]$N9203Reqs[0].context_project_id -eq 'aaaa1111aaaa1111aaaa1111aaaa1111') '/api/palette/instant へ選んだ資料のidがcontext_project_idとして飛ぶ'
    $N9203Card = $N9203Observed.cardAfterContextHit
    Assert-N9203 ($null -ne $N9203Card) '文脈ヒット時のカードを観測できた(前提条件)'
    if ($null -ne $N9203Card) {
        Assert-N9203 ([bool]$N9203Card.hasContextHit) 'カードに data-yaku-context-hit が付く'
        Assert-N9203 ([string]$N9203Card.kindText -eq 'この資料の確定訳') 'ラベルが「この資料の確定訳」(設計判断5)'
        Assert-N9203 ([string]$N9203Card.candidateIndex -eq '1') '文脈ヒットが候補1の番号バッジを持つ(既存の候補機構、新しい配線を作らない)'
        Assert-N9203 ([string]$N9203Card.candidateText -match "^We will describe this fiscal year") 'カードの中身がproject_hit.targetで、TMのおとりではない(既存TM欄より優先、設計判断4)'
        Assert-N9203 ([string]$N9203Card.preText -eq [string]$N9203Card.candidateText) 'カードの表示文もproject_hit.targetのまま(TMのおとりが混ざらない)'
    }
    Assert-N9203 ([string]$N9203Observed.hintTargetAfterContextHit -eq 'この資料の確定訳') '帯の案内文(Enterで何がコピーされるか)も「この資料の確定訳」と名指しする(MINOR-C相当)'

    Write-Host '-- 既存の候補機構(Enter/1キー)がそのまま効く --'
    Assert-N9203 ([string]$N9203Observed.copiedAfterDigitOneContext -match "^We will describe this fiscal year") '1キーでproject_hitの訳文全体がコピーされる'
    Assert-N9203 ([string]$N9203Observed.copiedAfterEnterContext -match "^We will describe this fiscal year") 'Enterでも既定候補(project_hit)がコピーされる'

    Write-Host '-- D) 「なし」へ戻すと従来どおり --'
    Assert-N9203 ([string]::IsNullOrEmpty([string]$N9203Observed.localStorageAfterNone)) '「なし」を選ぶとlocalStorageの記録が消える'
    $N9203ReqsNone = @($N9203Observed.instantRequestsWithoutContext)
    Assert-N9203 ($N9203ReqsNone.Count -ge 1 -and [string]$N9203ReqsNone[0].context_project_id -eq '') '「なし」へ戻すと以後 context_project_id は空で送られる'
    $N9203CardNone = $N9203Observed.cardAfterNoContext
    Assert-N9203 ($null -ne $N9203CardNone) '「なし」時のカードを観測できた(前提条件)'
    if ($null -ne $N9203CardNone) {
        Assert-N9203 (-not [bool]$N9203CardNone.hasContextHit) '「なし」に戻すと data-yaku-context-hit が付かない'
        Assert-N9203 ([string]$N9203CardNone.kindText -eq '訳文メモリの完全一致（未確認）') '「なし」に戻すと従来どおりTMのラベルへ戻る(UX検収基準: 文脈なし時の挙動は従来と同一)'
        Assert-N9203 ([string]$N9203CardNone.candidateText -eq 'TM decoy translation (must not be shown once project_hit wins).') '「なし」に戻すと従来どおりTMの中身が出る'
    }

    Write-Host '-- E) 資料が一覧から消えていれば無言でフォールバック --'
    Assert-N9203 ([string]$N9203Observed.selectValueAfterStale -eq '') '一覧に無い資料が保存されていても、選択は「なし」のまま(無言のフォールバック)'
    Assert-N9203 ([string]::IsNullOrEmpty([string]$N9203Observed.localStorageAfterStale)) '消えた資料の古い記録はlocalStorageから消える(次回また同じ検出をしない)'

    Write-Host '-- F) 資料がまだ一覧にあれば、再読み込みだけで操作ゼロのまま復元 --'
    Assert-N9203 ([string]$N9203Observed.selectValueAfterRestore -eq 'aaaa1111aaaa1111aaaa1111aaaa1111') '再読み込み後、選択が自動で元の資料へ戻る(操作ゼロ、UX検収基準)'
    $N9203ReqsRestore = @($N9203Observed.instantRequestsAfterRestore)
    Assert-N9203 ($N9203ReqsRestore.Count -ge 1 -and [string]$N9203ReqsRestore[0].context_project_id -eq 'aaaa1111aaaa1111aaaa1111aaaa1111') '復元後の貼り付けは、選び直さなくても context_project_id が自動で乗る'
}

Write-Host ''
if ($script:N9203Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9203PaletteContext'
    exit 0
}
Write-Host ('FAIL ' + $script:N9203Failures.Count + ' assertion(s)')
foreach ($f in $script:N9203Failures) { Write-Host ('  - ' + $f) }
exit 1
