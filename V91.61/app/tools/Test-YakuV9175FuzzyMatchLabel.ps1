<#
.SYNOPSIS
  あいまい一致を「%」と3段の帯で見せることの回帰テスト。

.DESCRIPTION
  画面は翻訳メモリの候補に一致の度合いを出す。

  2026-08-15 に「%」を消し、**2026-08-16 に戻した。** 消した理由は
  「中身が 3-gram の Dice 係数で、翻訳者が読む 100 / 95-99 / 85-94 / 75-84 の
  帯は編集距離を前提にしているから、別の尺度の数字をその帯へ当てはめさせるのは
  誤読させるのと同じ」だった。**その前提が両側で消えた。**

  - 実装が編集距離になった（src/TranslationMemory.ps1 の
    Get-YakuTranslationMemoryEditRatio。拾うのは MinScore=0.70 以上）
  - **Smartcat を実機で測ったら「%」を出していた。** 閾値の選択肢も
    75 / 85 / 95 / 99 / 100 / 101 で、その帯そのものだった
    （出典 `_docs/測定_一致率_2026-08-16.md`）

  帯は3段。境目の 85 は実測に合わせてある（Smartcat: 100=緑 / 86-92=黄 /
  75-77=赤。境目は 78〜85 の間で、設定が刻む 85 を採った）。

      100%      is-exact  塗りつぶし
      85〜99%   is-high   実線の枠
      70〜84%   is-low    破線の枠

  見るのは4つ。
   (a) サーバは従来どおり候補を返す（件数・並び順・ratio の値）
   (b) 画面が「%」を出す。cat.js の該当部分を node で**実際に走らせて**、
       描かれた札の中身を読む（字面の -match ではない）。数字はサーバの
       一致率そのものであること、**100% は完全一致だけ**であること
   (c) 3段が、文字でも塗りでも見分けられる。**色を消しても形が違う**こと
   (d) 前回版の候補（kind='prior'）には数字を出さない。そこの ratio は
       一致率ではなく 0 が入るため（かつては 1% と描いていた）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9175FuzzyMatchLabel.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# 読み込み順序は SrcModules.ps1 が唯一の出典。ここで一覧を書き写すと、
# 写し間違いが静かに効く。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-fuzzylabel-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

function Get-YakuServerRouteBody {
    <#
      Server.ps1 の switch から、ルート1本ぶんの**本体そのもの**を取り出す。
      写経しない（写せば Server.ps1 を直したときに写しだけが古くなる）。
      取り出せなければ $null を返し、呼び出し側は**赤にする**。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ServerPath,
        [Parameter(Mandatory=$true)][string]$Route
    )
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ServerPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { return $null }
    foreach ($switchAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true))) {
        foreach ($clause in $switchAst.Clauses) {
            if ([string]$clause.Item1.Extent.Text -ne ("'" + $Route + "'")) { continue }
            $bodyText = [string]$clause.Item2.Extent.Text
            if ($bodyText.Length -lt 3) { return $null }
            if ($bodyText[0] -ne '{' -or $bodyText[$bodyText.Length - 1] -ne '}') { return $null }
            return [pscustomobject]@{
                Text      = $bodyText.Substring(1, $bodyText.Length - 2)
                StartLine = [int]$clause.Item2.Extent.StartLineNumber
                EndLine   = [int]$clause.Item2.Extent.EndLineNumber
            }
        }
    }
    return $null
}

# ルートは Send-YakuTextResponse で応答を出す。Server.ps1 は読み込まないので、
# ここで受け皿を用意して、実際に出た本文をそのまま検査する。
$script:YakuRouteResponseText = ''
function Send-YakuTextResponse {
    param($Context,[string]$Text,[string]$ContentType='',[int]$StatusCode=200,[switch]$AllowWasm)
    $script:YakuRouteResponseText = [string]$Text
}
function Invoke-YakuServerRouteBody {
    <# 取り出した本体を、現在のスコープでそのまま走らせて応答本文を返す。
       $project / $payload / $Context は呼び出し側が置く。 #>
    param([Parameter(Mandatory=$true)][string]$BodyText)
    $script:YakuRouteResponseText = ''
    . ([scriptblock]::Create($BodyText))
    return [string]$script:YakuRouteResponseText
}

function Get-YakuCatJsBlock {
    <#
      cat.js から関数（または関数式）を1本、括弧の対応で切り出す。
      切り出せなければ '' を返す。呼び出し側は**赤にする**。
      切り出したものは node へ渡して実際に走らせるので、対応が崩れていれば
      node の構文解析が落ちて分かる（黙って通らない）。
    #>
    param([Parameter(Mandatory=$true)][string]$Text,[Parameter(Mandatory=$true)][string]$Header)
    $start = $Text.IndexOf($Header, [StringComparison]::Ordinal)
    if ($start -lt 0) { return '' }
    $depth = 0; $seen = $false
    for ($i = $start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '{') { $depth++; $seen = $true }
        elseif ($ch -eq '}') {
            $depth--
            if ($seen -and $depth -eq 0) { return $Text.Substring($start, $i - $start + 1) }
        }
    }
    return ''
}

function Remove-YakuJsBlockComment {
    <#
      /* ... */ を落とす。否定形の検査（「%」の式が無いこと）は**コードだけ**へ
      当てる。なぜやめたかを書いたコメントには当然「%」が出てくるので、
      落とさずに当てると、説明を書くほど赤くなるという逆立ちになる。
      コメントが在ることは別に検査する。
    #>
    param([Parameter(Mandatory=$true)][string]$Text)
    return ([regex]::Replace($Text, '/\*[\s\S]*?\*/', ' '))
}

function Get-YakuEditDistanceRatio {
    <#
      編集距離ベースの一致率（1 - Levenshtein/長い方）。市販CATの「%」が
      前提にしている尺度のほうである。~~アプリ本体はこれを使わない。~~

      **2026-08-16 に本体がこの尺度になった。** この関数は消さずに残す。
      本体（src/TranslationMemory.ps1、C# へ落として計算する）とは別に書かれた
      実装なので、両方が同じ値を出すことが独立した裏づけになる。
      片方を直したときに、もう片方が黙って付いてくることは無い。
    #>
    param([Parameter(Mandatory=$true)][string]$Left,[Parameter(Mandatory=$true)][string]$Right)
    $a = [string]$Left; $b = [string]$Right
    if ($a.Length -eq 0 -and $b.Length -eq 0) { return [double]1 }
    $prev = New-Object 'int[]' ($b.Length + 1)
    $cur  = New-Object 'int[]' ($b.Length + 1)
    for ($j = 0; $j -le $b.Length; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $b.Length; $j++) {
            # -eq は大文字小文字を畳む。本体（C#の ==）は畳まないので -ceq で揃える。
            # 畳んだままだと 'ABCD' と 'abcd' で本体と食い違い、突き合わせが崩れる。
            $cost = if ($a[$i-1] -ceq $b[$j-1]) { 0 } else { 1 }
            $del = $prev[$j] + 1
            $ins = $cur[$j-1] + 1
            $sub = $prev[$j-1] + $cost
            $min = $del
            if ($ins -lt $min) { $min = $ins }
            if ($sub -lt $min) { $min = $sub }
            $cur[$j] = $min
        }
        $swap = $prev; $prev = $cur; $cur = $swap
    }
    $distance = [double]$prev[$b.Length]
    $longest = [double]([Math]::Max($a.Length, $b.Length))
    if ($longest -le 0) { return [double]1 }
    return (1.0 - ($distance / $longest))
}

$settings = Read-YakuSettings -Root $root
$script:YakuRoot = $root
$serverFile = Join-Path (Join-Path $root 'src') 'Server.ps1'
$catJsPath = Join-Path (Join-Path $root 'www') 'assets\cat.js'
$commonJsPath = Join-Path (Join-Path $root 'www') 'assets\common.js'
$stylesPath = Join-Path (Join-Path $root 'www') 'assets\styles.css'
$catJs = [IO.File]::ReadAllText($catJsPath)
$commonJs = [IO.File]::ReadAllText($commonJsPath)
$styles = [IO.File]::ReadAllText($stylesPath)

# 現在の行の原文と、翻訳メモリに入れておく過去訳。
# 4件目はわざと「%」を含む原文にしてある。「あいまい側に % が出ない」を
# 見るとき、そもそも % が一度も通らない題材で測っていたら、その検査は
# 何も見張っていない（(b) の最後で使う）。
$activeSource = '当社の売上高は前年同期比で増加しました。'
$tmRows = @(
    [pscustomobject]@{ Source='当社の売上高は前年同期比で増加しました。';    Target='Net sales increased year on year.';       Note='完全一致' }
    [pscustomobject]@{ Source='当社の売上高は前年同期比で10%増加しました。'; Target='Net sales increased 10% year on year.';   Note='あいまい・原文に%' }
    [pscustomobject]@{ Source='当社の売上高は前年同期比で減少しました。';    Target='Net sales decreased year on year.';       Note='あいまい・1文字違い' }
    [pscustomobject]@{ Source='当社の経常利益は前年同期比で増加しました。';  Target='Ordinary profit increased year on year.'; Note='あいまい・語が違う' }
    [pscustomobject]@{ Source='本日は晴天なり。';                            Target='It is fine today.';                       Note='閾値未満・出ない' }
)

try {
    # ------------------------------------------------------------------ (a)
    Write-Host '(a) サーバの候補は従来どおり（表記だけを変えたことを示す）' -ForegroundColor Cyan
    foreach ($row in $tmRows) {
        $segmentId = (Get-YakuTranslationMemoryHash -Text ([string]$row.Source)).Substring(0,32)
        $null = Add-YakuTranslationMemoryEntry -Source ([string]$row.Source) -Target ([string]$row.Target) -Direction 'to_en' `
            -OriginProjectId '11111111111111111111111111111111' -OriginFileName 'FY2025-results.xlsx' `
            -OriginSegmentId $segmentId -OriginLocation 'Sheet1, A1' -OriginPage 3 -ReviewRevision 7
    }
    Clear-YakuTranslationMemoryCache

    $project = New-YakuCatTextProject -Root $root -Text $activeSource -Settings $settings -Direction 'to_en'
    $Context = $null
    $payload = @{ index = 0 }

    $route = Get-YakuServerRouteBody -ServerPath $serverFile -Route 'candidates'
    Chk ($null -ne $route) 'Server.ps1 から candidates ルートの本体を取り出せた'
    Chk ($null -eq (Get-YakuServerRouteBody -ServerPath $serverFile -Route 'no-such-candidates-route')) '無い名前では取り出せない（取り出しが空振りでないこと）'

    $response = $null
    if ($null -ne $route) {
        $response = (Invoke-YakuServerRouteBody -BodyText $route.Text) | ConvertFrom-Json
    }
    Chk ($null -ne $response) 'candidates ルートが応答本文を返した'

    $serverHits = @()
    if ($null -ne $response) { $serverHits = @($response.segment_matches) }
    Chk ($serverHits.Count -eq 4) ('候補は4件（閾値未満の1件は出ない）。実際 ' + $serverHits.Count + ' 件')

    # 並び順。Exact を先頭に、あとは ratio の降順。ここが変わっていないことが
    # 「表記だけの変更」の中身である。
    # 2026-08-16 に順が変わった。Dice では「10%増加」（3字足す）が「減少」（2字違う）
    # より上だったが、編集距離では手の入る量の順に並ぶので入れ替わる。
    # どちらも使い回せる候補だが、上に来るべきなのは直す手数が少ないほうである。
    $expectedOrder = @(
        '当社の売上高は前年同期比で増加しました。'
        '当社の売上高は前年同期比で減少しました。'
        '当社の売上高は前年同期比で10%増加しました。'
        '当社の経常利益は前年同期比で増加しました。'
    )
    $actualOrder = @($serverHits | ForEach-Object { [string]$_.source })
    Chk ((($actualOrder) -join '|') -eq (($expectedOrder) -join '|')) ('並び順は手数の少ない順: ' + ($actualOrder -join ' / '))
    Chk (@($actualOrder | Where-Object { $_ -eq '本日は晴天なり。' }).Count -eq 0) '閾値未満の過去訳は候補に出ない（絞り込みが効いている）'

    # サーバが返す数値が、画面と同じ一致率であること。
    $selfMismatch = 0
    foreach ($m in $serverHits) {
        $expectedRatio = [double](Get-YakuTranslationMemorySimilarity -Left $activeSource -Right ([string]$m.source))
        if ([Math]::Abs([double]$m.source_match_ratio - $expectedRatio) -ge 0.000001) { $selfMismatch++ }
    }
    Chk ($selfMismatch -eq 0) 'サーバの source_match_ratio は画面と同じ一致率'
    Chk (@($serverHits | Where-Object { [bool]$_.exact }).Count -eq 1) '完全一致はちょうど1件'

    # 本体とは別に書かれた実装（この試験の中の Get-YakuEditDistanceRatio）と
    # 突き合わせる。本体は C# へ落として計算するので、両方が同じ値を出すことが
    # 独立した裏づけになる。突き合わせるのは正規化したあとの鍵どうしである。
    $independentMismatch = 0
    foreach ($m in $serverHits) {
        $keyLeft = ConvertTo-YakuTranslationMemoryKey -Text $activeSource
        $keyRight = ConvertTo-YakuTranslationMemoryKey -Text ([string]$m.source)
        $independent = [double](Get-YakuEditDistanceRatio -Left $keyLeft -Right $keyRight)
        if ([Math]::Abs([double]$m.source_match_ratio - $independent) -ge 0.000001) { $independentMismatch++ }
    }
    Chk ($independentMismatch -eq 0) '別に書いた編集距離の実装と、1件残らず同じ値になる'

    # 「増加→減少」だけが違う20字の文。かつて Dice では 0.78（75-84 の帯＝
    # 手直しが要る）で、翻訳者が「%」から受け取る印象と食い違っていた。
    # これが「%」をやめた理由だったが、いまは帯のとおりの値を返す。
    $near = @($serverHits | Where-Object { [string]$_.source -eq '当社の売上高は前年同期比で減少しました。' })[0]
    $nearRatio = [double]$near.source_match_ratio
    Chk ($nearRatio -ge 0.85 -and $nearRatio -lt 0.95) ('20字中2字違いは ' + ('{0:N2}' -f $nearRatio) + '（85-94 の帯＝ほぼそのまま使える）')

    # 長さで答えが変わらないこと。同じ「2字違い」を短い文でも出す。Dice なら
    # ここが 0.60 まで落ちて閾値を割り、候補ごと消えていた。
    $shortLeft = '営業利益は増加しました。'
    $shortRight = '営業利益は減少しました。'
    $shortRatio = [double](Get-YakuTranslationMemorySimilarity -Left $shortLeft -Right $shortRight)
    Chk ($shortRatio -ge 0.70) ('12字でも同じ2字違いが閾値を越える: ' + ('{0:N2}' -f $shortRatio))
    Chk ([Math]::Abs($shortRatio - $nearRatio) -lt 0.10) ('長い文と短い文で一致率がほぼ同じ: ' + ('{0:N2}' -f $shortRatio) + ' / ' + ('{0:N2}' -f $nearRatio))

    # ------------------------------------------------------------------ (b)
    Write-Host '(b) 画面は「%」を出さない（cat.js を node で実際に走らせる）' -ForegroundColor Cyan
    $nodeExe = ''
    try { $nodeExe = [string](Get-Command node -ErrorAction Stop).Source } catch { $nodeExe = '' }
    Chk (-not [string]::IsNullOrWhiteSpace($nodeExe)) ('node が使える（' + $(if($nodeExe){$nodeExe}else{'見つからない'}) + '）')

    $jsBlocks = [ordered]@{
        escapeHtml   = '  function escapeHtml(value) {'
        esc          = '  function esc(value) {'
        diffTokens   = '  function diffTokens(text) {'
        diffMarkup   = '  function diffMarkup(candidateSource, currentSource) {'
    }
    $harnessParts = New-Object System.Collections.Generic.List[string]
    $missingBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($blockName in $jsBlocks.Keys) {
        $source = if ($blockName -eq 'escapeHtml') { $commonJs } else { $catJs }
        $block = Get-YakuCatJsBlock -Text $source -Header ([string]$jsBlocks[$blockName])
        if ([string]::IsNullOrWhiteSpace($block)) { [void]$missingBlocks.Add($blockName); continue }
        [void]$harnessParts.Add($block)
        if ($blockName -eq 'escapeHtml') { [void]$harnessParts.Add('var YakuCommon = { escape: escapeHtml };') }
    }
    Chk ($missingBlocks.Count -eq 0) ('cat.js / common.js の下ごしらえを全部取り出せた（欠け: ' + (($missingBlocks.ToArray()) -join ',') + '）')

    # 候補カードを組む本体そのもの。写さずに切り出す。
    $cardBlock = Get-YakuCatJsBlock -Text $catJs -Header 'function (item, itemIndex) {'
    Chk (-not [string]::IsNullOrWhiteSpace($cardBlock)) '候補カードを組む本体を cat.js から取り出せた'
    Chk ($cardBlock -match 'cat-cand-score') '取り出したのは一致の度合いの札を作る場所である（取り違えでないこと）'

    # kind='prior' の枝も通す。前回版の「原文が変わった」候補は ratio=0 で来るので、
    # かつては 1% と描かれていた。数字にすると、この枝はとくに読めない。
    $priorItem = [ordered]@{
        kind='prior'; reference_id=('a' * 32); source_name='前回のFY2024資料'; location='Sheet1, A1'; page=0
        source='当社の売上高は前年同期比で増加しました'; translation='Net sales increased from a year earlier.'
        target='Net sales increased from a year earlier.'; exact=$false; ratio=0.0; source_match_ratio=0.0
        score=0.0; match_type='fuzzy'; saved=''; database='前回版'; verified=$false
    }
    # 100 の直前で止まることを、**画面に実際に描かせて**確かめるための1件。
    # 0.997 は四捨五入すると 100 になる。ここを PowerShell 側で計算して比べると、
    # cat.js に一度も当たらない検査になる（自己同語反復）。
    $cappedItem = [ordered]@{
        kind='tm'; reference_id=('b' * 32); source_name='丸め確認用'; location=''; page=0
        source='丸め確認用の原文'; translation='rounding probe'; target='rounding probe'
        exact=$false; ratio=0.997; source_match_ratio=0.997; score=0.997
        match_type='fuzzy'; saved='2026-08-16T00:00:00Z'; database='probe'; verified=$true
    }
    $itemsForJs = New-Object System.Collections.Generic.List[object]
    foreach ($m in $serverHits) { [void]$itemsForJs.Add($m) }
    [void]$itemsForJs.Add([pscustomobject]$cappedItem)
    [void]$itemsForJs.Add([pscustomobject]$priorItem)

    $harnessPath = Join-Path $tmp 'cat-candidate-card.js'
    $inputPath = Join-Path $tmp 'cat-candidate-card-input.json'
    $outputPath = Join-Path $tmp 'cat-candidate-card-output.json'
    $harness = @"
'use strict';
/* cat.js から切り出した本体を、そのまま走らせる。写経はしない。
   ここで用意するのは、切り出した本体が読む外側の名前だけである。 */
$($harnessParts.ToArray() -join "`n")

var terms = [];
var index = 0;
var requestScope = { id: '' };
var activeSource = '';
var diffHintShown = false;
var candidateCard = $cardBlock;

var fs = require('fs');
var input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
terms = input.terms || [];
index = input.index;
requestScope = { id: input.project_id };
activeSource = input.active_source;
diffHintShown = false;
var cards = (input.items || []).map(function (item, i) { return candidateCard(item, i); });
fs.writeFileSync(process.argv[3], JSON.stringify({ cards: cards }), 'utf8');
"@
    [IO.File]::WriteAllText($harnessPath, $harness, (New-Object Text.UTF8Encoding($false)))
    $inputJson = ([ordered]@{
        terms = @(); index = 0; project_id = [string]$project.Id
        active_source = $activeSource; items = @($itemsForJs.ToArray())
    } | ConvertTo-Json -Depth 8)
    [IO.File]::WriteAllText($inputPath, $inputJson, (New-Object Text.UTF8Encoding($false)))

    $nodeOut = $null
    if (-not [string]::IsNullOrWhiteSpace($nodeExe)) {
        $nodeErr = ''
        try {
            $nodeStdErr = Join-Path $tmp 'node-stderr.txt'
            $proc = Start-Process -FilePath $nodeExe -ArgumentList @($harnessPath, $inputPath, $outputPath) -NoNewWindow -Wait -PassThru -RedirectStandardError $nodeStdErr
            if ([int]$proc.ExitCode -ne 0) { $nodeErr = [IO.File]::ReadAllText($nodeStdErr) }
        } catch { $nodeErr = [string]$_.Exception.Message }
        Chk ([string]::IsNullOrWhiteSpace($nodeErr)) ('cat.js の該当部分が node で走る' + $(if($nodeErr){' / ' + $nodeErr.Substring(0,[Math]::Min(300,$nodeErr.Length))}else{''}))
        if (Test-Path -LiteralPath $outputPath) {
            $nodeOut = [IO.File]::ReadAllText($outputPath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
        }
    }
    Chk ($null -ne $nodeOut) '画面側が描いた札を受け取れた'

    if ($null -ne $nodeOut) {
        $cards = @($nodeOut.cards)
        # サーバの候補4件＋丸め確認用1件＋前回版1件。
        Chk ($cards.Count -eq $itemsForJs.Count) ('渡した候補と同じ数だけカードが出る（' + $cards.Count + ' 枚 / 渡したのは ' + $itemsForJs.Count + ' 件）')

        $badgeRe = [regex]'<span class="cat-cand-score ([^"]*)" title="([^"]*)">([^<]*)</span>'
        $badges = New-Object System.Collections.Generic.List[object]
        $noBadge = 0
        foreach ($card in $cards) {
            $m = $badgeRe.Match([string]$card)
            if (-not $m.Success) { $noBadge++; continue }
            [void]$badges.Add([pscustomobject]@{
                Class = [string]$m.Groups[1].Value
                Title = [string]$m.Groups[2].Value
                Text  = [string]$m.Groups[3].Value
                Card  = [string]$card
            })
        }
        Chk ($noBadge -eq 0) 'どのカードにも一致の度合いの札がある'

        $badgeList = @($badges.ToArray())
        # 前回版の候補（kind='prior'）には数字を出さない。そこの ratio は
        # 一致率ではなく 0 が入るため（かつては 1% と描いていた）。
        $priorBadges  = @($badgeList | Where-Object { [string]$_.Card -match '前回のFY2024資料' })
        $cappedBadges = @($badgeList | Where-Object { [string]$_.Card -match '丸め確認用' })
        $tmBadges     = @($badgeList | Where-Object { [string]$_.Card -notmatch '前回のFY2024資料' -and [string]$_.Card -notmatch '丸め確認用' })
        Chk ($priorBadges.Count -eq 1) '前回版の札は1枚'
        Chk ($cappedBadges.Count -eq 1) '丸め確認用の札は1枚'
        Chk ($tmBadges.Count -eq 4) '翻訳メモリの札は4枚'

        # 受入条件そのもの。翻訳メモリ側の札は全部「n%」である。
        $percentRe = [regex]'^\d{1,3}%$'
        $nonPercent = @($tmBadges | Where-Object { -not $percentRe.IsMatch([string]$_.Text) })
        Chk ($nonPercent.Count -eq 0) ('翻訳メモリの札はすべて「n%」: ' + (($tmBadges | ForEach-Object { [string]$_.Text }) -join ' / '))
        Chk (@($priorBadges | Where-Object { [string]$_.Text -match '[%％\d]' }).Count -eq 0) ('前回版の札には数字を出さない: ' + [string]@($priorBadges)[0].Text)

        # 画面の数字が、サーバの一致率そのものであること。**完全一致だけが 100%。**
        $expectedPercents = New-Object System.Collections.Generic.List[string]
        foreach ($m in $serverHits) {
            $r = [double]$m.source_match_ratio
            $p = if ([bool]$m.exact -or $r -ge 0.999) { 100 } else { [Math]::Min(99, [Math]::Max(0, [int][Math]::Round($r * 100, [MidpointRounding]::AwayFromZero))) }
            [void]$expectedPercents.Add(([string]$p + '%'))
        }
        $expectedList = @($expectedPercents.ToArray())
        $shownList = @($tmBadges | ForEach-Object { [string]$_.Text })
        Chk ((($shownList | Sort-Object) -join ',') -eq (($expectedList | Sort-Object) -join ',')) ('札の数字はサーバの一致率そのもの: 画面 ' + ($shownList -join '/') + ' / 期待 ' + ($expectedList -join '/'))

        # 空振り防止。題材が3段とも通っていなければ、帯の検査は何も見ていない。
        $hundred = @($shownList | Where-Object { $_ -eq '100%' })
        $high    = @($tmBadges | Where-Object { [string]$_.Class -eq 'is-high' })
        $low     = @($tmBadges | Where-Object { [string]$_.Class -eq 'is-low' })
        Chk ($hundred.Count -eq 1) '題材に 100% がちょうど1枚ある'
        Chk ($high.Count -ge 1) ('題材に 85%以上の札がある（' + $high.Count + '枚）')
        Chk ($low.Count -ge 1) ('題材に 85%未満の札がある（' + $low.Count + '枚）')

        # **100% は完全一致だけ。** 0.999 以上を丸めて 100% と描くと、
        # 1文字だけ違う長文が「同じ」と読まれる。
        $falseHundred = @($badgeList | Where-Object { [string]$_.Text -eq '100%' -and [string]$_.Class -ne 'is-exact' })
        Chk ($falseHundred.Count -eq 0) '完全一致でないものに 100% は出ない'
        # 画面に実際に描かせて確かめる。ratio=0.997 は四捨五入すれば 100 になる。
        $cappedText = if ($cappedBadges.Count -eq 1) { [string]@($cappedBadges)[0].Text } else { '' }
        $cappedClass = if ($cappedBadges.Count -eq 1) { [string]@($cappedBadges)[0].Class } else { '' }
        Chk ($cappedText -eq '99%') ('一致率 0.997 の候補は 99% と描かれる（100 へ丸めない）。実際 ' + $cappedText)
        Chk ($cappedClass -eq 'is-high') ('その札は完全一致の見た目にならない。実際 ' + $cappedClass)

        # 帯の境目は 85。実測（Smartcat: 100=緑 / 86-92=黄 / 75-77=赤）に合わせてある。
        $bandWrong = @($tmBadges | Where-Object {
            $p = [int]([string]$_.Text -replace '%', '')
            $c = [string]$_.Class
            (($p -eq 100) -and ($c -ne 'is-exact')) -or
            (($p -lt 100 -and $p -ge 85) -and ($c -ne 'is-high')) -or
            (($p -lt 85) -and ($c -ne 'is-low'))
        })
        Chk ($bandWrong.Count -eq 0) ('帯の境目は 85: ' + (($tmBadges | ForEach-Object { [string]$_.Text + '=' + [string]$_.Class }) -join ' '))

        # 原文に % を含む候補では、% は本文としてもそのまま出る（札と本文の取り違え防止）。
        $percentCard = @($cards | Where-Object { [string]$_ -match '10%' })
        Chk ($percentCard.Count -eq 1) '原文に % を含む候補では、% は本文としてカードに出る'

        # --------------------------------------------------------------- (c)
        Write-Host '(c) 3段が、文字でも塗りでも見分けられる' -ForegroundColor Cyan
        $haveExact = (@($badgeList | Where-Object { [string]$_.Class -eq 'is-exact' }).Count -ge 1)
        $titles = @(@($badgeList | ForEach-Object { [string]$_.Title }) | Sort-Object -Unique)
        Chk ($titles.Count -ge 3) ('説明（title）が段ごとに分かれる: ' + $titles.Count + '種類')

        # 画面が出す class に、実際に見た目の規則があること。
        # かつての is-low は styles.css に規則が無く、札は既定のまま出ていた。
        # 「名前があるか」ではなく「つながっているか」を見る。
        $classesUsed = @(@($badgeList | ForEach-Object { [string]$_.Class }) | Sort-Object -Unique)
        $classesWithoutRule = @($classesUsed | Where-Object { $styles -notmatch ('\.cat-cand-score\.' + [regex]::Escape($_) + '\s*\{') })
        Chk ($classesWithoutRule.Count -eq 0) ('画面が出す class には styles.css の規則がある（規則なし: ' + ($classesWithoutRule -join ',') + '）')
        Chk ($classesUsed.Count -eq 3) ('札の class は3種類: ' + ($classesUsed -join ','))

        $ruleRe = [regex]'\.cat-cand-score\.(is-[a-z-]+)\s*\{([^}]*)\}'
        $rules = @{}
        foreach ($rm in $ruleRe.Matches($styles)) { $rules[[string]$rm.Groups[1].Value] = ([string]$rm.Groups[2].Value).Trim() }
        $missingRule = @($classesUsed | Where-Object { -not $rules.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$rules[$_]) })
        Chk ($missingRule.Count -eq 0) ('3段とも規則の中身がある（空: ' + ($missingRule -join ',') + '）')
        $ruleTexts = @(@($classesUsed | ForEach-Object { [string]$rules[$_] }) | Sort-Object -Unique)
        Chk ($ruleTexts.Count -eq 3) '3段の塗りの規則が、それぞれ違う'

        # **色だけに頼らない。** 3段の見分けが色以外にも付いていること。
        # 色の指定（color / border-color / background の値）を落としてから比べる。
        $stripColour = {
            param([string]$Rule)
            $t = [regex]::Replace([string]$Rule, '(?i)(background|color|border-color)\s*:[^;]*;?', '')
            return ($t -replace '\s+', ' ').Trim()
        }
        $exactShape = & $stripColour ([string]$rules['is-exact'])
        $highShape  = & $stripColour ([string]$rules['is-high'])
        $lowShape   = & $stripColour ([string]$rules['is-low'])
        Chk ($haveExact -and ([string]$rules['is-exact'] -match 'background')) '完全一致は塗りつぶし'
        Chk ($highShape -ne $lowShape) ('85%以上と85%未満は、色を消しても形が違う: [' + $highShape + '] / [' + $lowShape + ']')
        Chk ($lowShape -match 'dashed') '85%未満は破線の枠（色が見えなくても分かる）'

        # 並び順は、サーバの順のままカードになる。表記だけを変えたことの裏づけ。
        $cardSourceOrder = New-Object System.Collections.Generic.List[string]
        foreach ($card in @($cards)) {
            $sm = [regex]::Match([string]$card, '<p class="cat-cand-src">(.*?)</p>')
            $plain = [regex]::Replace([string]$sm.Groups[1].Value, '<[^>]+>', '')
            [void]$cardSourceOrder.Add($plain)
        }
        $renderedOrder = @(@($cardSourceOrder.ToArray()) | Select-Object -First $serverHits.Count)
        Chk ((($renderedOrder) -join '|') -eq (($expectedOrder) -join '|')) 'カードの並びはサーバの並びのまま'
        $numbers = @($cards | ForEach-Object { [int][regex]::Match([string]$_, '<span class="cat-candidate-number">(\d+)</span>').Groups[1].Value })
        $expectedNumbers = @(1..$itemsForJs.Count) -join ','
        Chk ((($numbers) -join ',') -eq $expectedNumbers) ('Ctrl+数字の割り当ても従来どおり: ' + ($numbers -join ','))
    }

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) 前回版の候補には数字を出さない／札を作る場所は1つ' -ForegroundColor Cyan
    $codeOnly = Remove-YakuJsBlockComment -Text $cardBlock
    Chk ($codeOnly.Length -gt 500 -and $codeOnly -match 'cat-cand-score') 'コメントを落としても、札を作るコードは残っている（検査の当て先があること）'
    Chk ($cardBlock.Length -gt $codeOnly.Length) 'コメントは実際に落ちている（コードだけへ当てられていること）'
    # 数字を出すのはコード側であって、コメントの中の例ではない。
    Chk ($codeOnly -match 'is-high' -and $codeOnly -match 'is-low') 'コードに3段の分岐がある'
    Chk ($codeOnly -match "'%'" -or $codeOnly -match '"%"') 'コードが「%」を組み立てている'
    Chk ($codeOnly -match 'isPrior') 'コードが前回版の候補を分けている'
    # 前回版の分岐が本当に数字を止めていること。ここを外すと 0% と描かれる。
    Chk ($codeOnly -match "isPrior\s*\?") '前回版のときは数字ではなく言葉を選ぶ枝がある'
    # 札を作る場所は1つだけ。別の場所で表記を足し直していないこと。
    Chk (([regex]::Matches($catJs, 'cat-cand-score')).Count -eq 1) 'cat.js が一致の度合いの札を作る場所は1か所だけ'

    # なぜ戻したかがコメントに残っていること。
    Chk ($cardBlock -match 'Smartcat') 'コメントに、市販ツールを実機で測ったことが書いてある'
    Chk ($cardBlock -match '85') 'コメントに帯の境目（85）が書いてある'
    Chk ($cardBlock -match 'TranslationMemory\.ps1') 'コメントに算出元の出典が書いてある'
    Chk ($cardBlock -match '測定_一致率') 'コメントに測定記録の出典が書いてある'

    # サーバは ratio を返し続ける（画面が使わないだけで、口は変えていない）。
    Chk ($null -ne $response -and (@($response.segment_matches)[0].PSObject.Properties.Name -contains 'source_match_ratio')) 'サーバの口は従来どおり source_match_ratio を返す'

    Remove-YakuCatProject -Id ([string]$project.Id)
}
finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'V9175 fuzzy match label: PASS' -ForegroundColor Green; exit 0 }
Write-Host ('V9175 fuzzy match label: FAIL (' + $script:fail + ')') -ForegroundColor Red
exit 1
