<#
.SYNOPSIS
  あいまい一致を「%」で見せないことの回帰テスト。

.DESCRIPTION
  画面は翻訳メモリの候補に一致の度合いを出す。かつてそれは「%」だった。

  **中身は 3-gram の Dice 係数である**（src/TranslationMemory.ps1 の
  Get-YakuTranslationMemoryDice。拾うのは MinScore=0.70 以上）。ところが
  翻訳者が CAT の「%」を読むときに思い浮かべるのは
  100 / 95-99 / 85-94 / 75-84 / 50-74 という帯で、「85%以上ならほぼ
  そのまま使える」という体感で判断する。この帯は編集距離ベースの
  一致率を前提にした事実上の共通語であり、Dice 係数とは別の尺度である。

  どれくらい別物か。ここで使う「増加→減少」だけが違う20字の文は、
  編集距離では 0.90（85-94 の帯＝ほぼそのまま使える）だが、Dice では 0.78
  （75-84 の帯＝手直しが要る）になる。**85 の境目をまたぐ。**
  この差を「%」として見せていたのだから、誤読させていたのと同じである。

  指標そのものを作り直すのは別の作業。ここで固定するのは表記だけである。

  見るのは4つ。
   (a) サーバは従来どおり候補を返す（件数・並び順・ratio の値）。表記だけを
       変えたことを、ここで示す
   (b) 画面が「%」を出さない。cat.js の該当部分を node で**実際に走らせて**、
       描かれた札の中身を読む（字面の -match ではない）
   (c) 完全一致と近い訳が、文字でも塗りでも見分けられる
   (d) Ratio を100倍して % にする式が、該当箇所に無い（否定形の検査）

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
      前提にしている尺度のほうである。ここでは Dice との差を示すためだけに使う。
      アプリ本体はこれを使わない。
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
            $cost = if ($a[$i-1] -eq $b[$j-1]) { 0 } else { 1 }
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
    $expectedOrder = @(
        '当社の売上高は前年同期比で増加しました。'
        '当社の売上高は前年同期比で10%増加しました。'
        '当社の売上高は前年同期比で減少しました。'
        '当社の経常利益は前年同期比で増加しました。'
    )
    $actualOrder = @($serverHits | ForEach-Object { [string]$_.source })
    Chk ((($actualOrder) -join '|') -eq (($expectedOrder) -join '|')) ('並び順が従来どおり: ' + ($actualOrder -join ' / '))
    Chk (@($actualOrder | Where-Object { $_ -eq '本日は晴天なり。' }).Count -eq 0) '閾値未満の過去訳は候補に出ない（絞り込みが効いている）'

    # サーバが返す数値が Dice 係数そのものであること。ここが崩れたら、
    # 「%をやめた理由」の前提が崩れる。
    $diceMismatch = 0
    foreach ($m in $serverHits) {
        $expectedRatio = [double](Get-YakuTranslationMemorySimilarity -Left $activeSource -Right ([string]$m.source))
        if ([Math]::Abs([double]$m.source_match_ratio - $expectedRatio) -ge 0.000001) { $diceMismatch++ }
    }
    Chk ($diceMismatch -eq 0) 'サーバの source_match_ratio は 3-gram Dice 係数そのもの'
    Chk (@($serverHits | Where-Object { [bool]$_.exact }).Count -eq 1) '完全一致はちょうど1件'

    # なぜ「%」として読ませてはいけないか。「増加→減少」だけが違う過去訳で、
    # 編集距離ベースの一致率と Dice が 85 の境目をまたいで食い違う。
    $near = @($serverHits | Where-Object { [string]$_.source -eq '当社の売上高は前年同期比で減少しました。' })[0]
    $nearDice = [double]$near.source_match_ratio
    $nearEdit = [double](Get-YakuEditDistanceRatio -Left $activeSource -Right ([string]$near.source))
    Chk ($nearEdit -ge 0.85) ('20字中2字違いは編集距離では ' + ('{0:N2}' -f $nearEdit) + '（85-94 の帯＝ほぼそのまま使える）')
    Chk ($nearDice -lt 0.85) ('同じ組が Dice では ' + ('{0:N2}' -f $nearDice) + '（75-84 の帯＝手直しが要る）')
    Chk (($nearEdit - $nearDice) -ge 0.10) '2つの尺度は帯をまたいで食い違う（「%」で読ませてはいけない理由）'

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
    $itemsForJs = New-Object System.Collections.Generic.List[object]
    foreach ($m in $serverHits) { [void]$itemsForJs.Add($m) }
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
        Chk ($cards.Count -eq ($serverHits.Count + 1)) ('サーバの候補と同じ数だけカードが出る（' + $cards.Count + ' 枚）')

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
        $exactBadges = @($badgeList | Where-Object { [string]$_.Text -eq '完全一致' })
        $nearBadges  = @($badgeList | Where-Object { [string]$_.Text -ne '完全一致' })
        Chk ($exactBadges.Count -eq 1) '完全一致の札は1枚だけ'
        Chk ($nearBadges.Count -eq 4) 'あいまい一致の札は4枚（翻訳メモリ3件＋前回版1件）'
        Chk (@($nearBadges | Where-Object { [string]$_.Text -eq '近い訳' }).Count -eq $nearBadges.Count) 'あいまい側の札はすべて「近い訳」'

        # 受入条件そのもの。あいまい側の札に「%」も数字も出ない。
        $percentInBadge = @($nearBadges | Where-Object { [string]$_.Text -match '[%％]' }).Count
        $digitInBadge   = @($nearBadges | Where-Object { [string]$_.Text -match '\d' }).Count
        Chk ($percentInBadge -eq 0) 'あいまい側の札に「%」が出ない'
        Chk ($digitInBadge -eq 0) 'あいまい側の札に数字が出ない（帯として読まれる余地を残さない）'
        # 以降は「完全一致の札が1枚ある」ことを前提にする。無いまま比較すると
        # $null 同士の比較が静かに通り、壊れているのに緑になる（実際に踏んだ）。
        $haveExact = ($exactBadges.Count -eq 1)
        $haveNear = ($nearBadges.Count -gt 0)
        $exactText = if ($haveExact) { [string]@($exactBadges)[0].Text } else { '' }
        Chk ($haveExact -and ($exactText -notmatch '[%％\d]')) '完全一致の札も数字で言わない（「100%」ではない）'

        # 空振り防止。かつての式なら、この題材でいくつの「%」が出ていたかを
        # ここで作って、それがカードに無いことを見る。
        $oldPercents = New-Object System.Collections.Generic.List[string]
        foreach ($m in $serverHits) {
            $r = [double]$m.source_match_ratio
            $p = if ([bool]$m.exact -or $r -ge 0.999) { 100 } else { [Math]::Max(1, [Math]::Min(99, [int][Math]::Round($r * 100, [MidpointRounding]::AwayFromZero))) }
            [void]$oldPercents.Add(([string]$p + '%'))
        }
        [void]$oldPercents.Add('1%')  # kind='prior' の ratio=0 は 1% に丸められていた
        $oldList = @($oldPercents.ToArray())
        Chk ($oldList.Count -eq 5 -and (@($oldList | Where-Object { $_ -match '^\d+%$' }).Count -eq 5)) ('かつての表記は ' + ($oldList -join ' / ') + '（この検査が空振りでないこと）')
        $joinedCards = ($cards -join "`n")
        $leaked = @($oldList | Where-Object { $joinedCards.Contains($_) })
        Chk ($leaked.Count -eq 0) ('かつての「%」表記はどのカードにも出ない（漏れ: ' + ($leaked -join ',') + '）')

        # 「%」が出ないのは、そもそも題材に % が無いからではない。
        # 原文に % を含む候補では、% は本文としてそのまま出る。
        $percentCard = @($cards | Where-Object { [string]$_ -match '10%' })
        Chk ($percentCard.Count -eq 1) '原文に % を含む候補では、% は本文としてカードに出る（検査の当て先が札に絞れている）'
        $percentBadge = @($badgeList | Where-Object { [string]$_.Card -match '10%' })
        Chk ($percentBadge.Count -eq 1 -and ([string]@($percentBadge)[0].Text -eq '近い訳')) 'その候補の札も「近い訳」であって % ではない'

        # 本文に % を持たないカードには、カード全体を通しても % が1つも無い。
        $cleanCards = @($cards | Where-Object { [string]$_ -notmatch '10%' })
        Chk ($cleanCards.Count -eq 4) '本文に % を持たないカードが4枚ある'
        Chk (@($cleanCards | Where-Object { [string]$_ -match '[%％]' }).Count -eq 0) '本文に % が無いカードには、カード全体でも % が出ない'

        # --------------------------------------------------------------- (c)
        Write-Host '(c) 完全一致と近い訳が、文字でも塗りでも見分けられる' -ForegroundColor Cyan
        $exactClass = if ($haveExact) { [string]@($exactBadges)[0].Class } else { '' }
        $nearClasses = @($nearBadges | ForEach-Object { [string]$_.Class } | Sort-Object -Unique)
        Chk ($haveExact -and $haveNear -and ($exactClass -ne ($nearClasses -join ','))) ('札の class が分かれる: 完全一致=' + $exactClass + ' / あいまい=' + ($nearClasses -join ','))
        Chk ($nearClasses.Count -eq 1) 'あいまい側の class は1種類（かつての is-high / is-low の分岐は残っていない）'
        Chk ($haveExact -and $haveNear -and (([string]@($exactBadges)[0].Title) -ne ([string]@($nearBadges)[0].Title))) '説明（title）も分かれる'

        # 画面が出す class に、実際に見た目の規則があること。
        # かつての is-low は styles.css に規則が無く、札は既定のまま出ていた。
        # 「名前があるか」ではなく「つながっているか」を見る。
        $classesUsed = @(@($badgeList | ForEach-Object { [string]$_.Class }) | Sort-Object -Unique)
        $classesWithoutRule = @($classesUsed | Where-Object { $styles -notmatch ('\.cat-cand-score\.' + [regex]::Escape($_) + '\s*\{') })
        Chk ($classesWithoutRule.Count -eq 0) ('画面が出す class には styles.css の規則がある（規則なし: ' + ($classesWithoutRule -join ',') + '）')
        Chk ($classesUsed.Count -eq 2) ('札の class は2種類だけ: ' + ($classesUsed -join ','))

        $ruleRe = [regex]'\.cat-cand-score\.(is-[a-z-]+)\s*\{([^}]*)\}'
        $rules = @{}
        foreach ($rm in $ruleRe.Matches($styles)) { $rules[[string]$rm.Groups[1].Value] = ([string]$rm.Groups[2].Value).Trim() }
        $exactRule = if ($haveExact -and $rules.ContainsKey($exactClass)) { [string]$rules[$exactClass] } else { '' }
        $nearRule = if ($haveNear -and $rules.ContainsKey([string]$nearClasses[0])) { [string]$rules[[string]$nearClasses[0]] } else { '' }
        Chk ((-not [string]::IsNullOrWhiteSpace($exactRule)) -and (-not [string]::IsNullOrWhiteSpace($nearRule)) -and ($exactRule -ne $nearRule)) '完全一致と近い訳で、塗りの規則そのものが違う'
        Chk ($exactRule -match 'background') '完全一致は塗りつぶし（色だけに頼らない見分けが残っている）'

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
        Chk ((($numbers) -join ',') -eq '1,2,3,4,5') ('Ctrl+数字の割り当ても従来どおり: ' + ($numbers -join ','))
    }

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) Ratio を100倍して % にする式が、該当箇所に無い（否定形）' -ForegroundColor Cyan
    $codeOnly = Remove-YakuJsBlockComment -Text $cardBlock
    Chk ($codeOnly.Length -gt 500 -and $codeOnly -match 'cat-cand-score') 'コメントを落としても、札を作るコードは残っている（検査の当て先があること）'
    Chk ($cardBlock.Length -gt $codeOnly.Length) 'コメントは実際に落ちている（この否定形が空振りでないこと）'
    Chk ($codeOnly -notmatch '\*\s*100') '該当箇所に「* 100」が無い'
    Chk ($codeOnly -notmatch 'Math\.round') '該当箇所に Math.round が無い'
    Chk ($codeOnly -notmatch "[%％]") '該当箇所のコードに「%」の文字が無い'
    Chk ($codeOnly -notmatch 'is-high' -and $codeOnly -notmatch 'is-low') 'かつての帯（is-high / is-low）の分岐が残っていない'
    # 札を作る場所は1つだけ。別の場所で % を足し直していないこと。
    Chk (([regex]::Matches($catJs, 'cat-cand-score')).Count -eq 1) 'cat.js が一致の度合いの札を作る場所は1か所だけ'

    # なぜやめたかがコメントに残っていること。
    Chk ($cardBlock -match 'Dice') 'コメントに Dice 係数であることが書いてある'
    Chk ($cardBlock -match '85') 'コメントに帯（85 以上ならほぼそのまま使える）との食い違いが書いてある'
    Chk ($cardBlock -match 'TranslationMemory\.ps1') 'コメントに算出元の出典が書いてある'

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
