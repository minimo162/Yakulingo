<#
.SYNOPSIS
  検索と置換（一括置換）の回帰テスト。

.DESCRIPTION
  市販CAT（memoQ Ctrl+H / Phrase Ctrl+H / Trados / XTM）が全社持つ table stakes。
  用語の統一修正を一括で掛けられないと、手で1行ずつ直すことになる。

  見るのは8つ。
   (a) 置換で訳文が変わった行は confirmed が落ち、QcStatus が not_run へ戻る
       （**ここが最重要。** 落とさないと、点検を通っていない訳が確認済みのまま
        残り「数値が抜けた訳は警告ではなく欠陥」に触れる）
   (b) 置換の結果 numeric-value-mismatch になる行は確定できず、書き出しも止まる。
       止まる理由は既存の3つのままで、増えていないこと
   (c) 置換は絞り込み結果（indexes）の中だけに掛かる。押す前に告げた行数と、
       実際に変わった行数が一致する
   (d) cat.js の絞り込みの鍵と cat.html のボタンが1対1である（到達不能な枝が無い）。
       しかも鍵ごとに違う行が選ばれることを、実際に走らせて確かめる
   (e) 原文は1文字も変わらない
   (f) 不正な正規表現・空に一致する式でサーバが落ちない
   (g) サーバの口（Server.ps1 のルート本体を構文木で取り出して走らせる）
   (h) 画面（cat.js）とサーバ（CatProject.ps1）の照合結果が、同じ表で一致する。
       cat.js の該当部分を node で実際に走らせて突き合わせる。字面（-match）で
       名前があることを見るだけの表明は、門ではない

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9174SearchReplace.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# 読み込み順序は SrcModules.ps1 が唯一の出典。ここで一覧を書き写すと、
# 写し間違いが静かに効く（SrcModules.ps1 の冒頭に経緯あり）。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-repl-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

function Get-YakuServerRouteBody {
    <#
      Server.ps1 の switch から、ルート1本ぶんの**本体そのもの**を取り出す。
      写経しないのは、写しだけが古いまま残るのを避けるため（Test-YakuV9172 と同じ）。
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
    param([Parameter(Mandatory=$true)][string]$BodyText)
    $script:YakuRouteResponseText = ''
    . ([scriptblock]::Create($BodyText))
    return [string]$script:YakuRouteResponseText
}

function Get-YakuCatJsBlock {
    <#
      cat.js から関数（または var の塊）を1本、括弧の対応で切り出す。
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

$settings = Read-YakuSettings -Root $root
$script:YakuRoot = $root
$catJsPath = Join-Path (Join-Path $root 'www') 'assets\cat.js'
$catHtmlPath = Join-Path (Join-Path $root 'www') 'cat.html'
$catJs = [IO.File]::ReadAllText($catJsPath)
$catHtml = [IO.File]::ReadAllText($catHtmlPath)

try {
    # ------------------------------------------------------------------ (a)
    Write-Host '(a) 置換で訳文が変わった行は確認済みが落ちる' -ForegroundColor Cyan
    $textA = @(
        '当社は電動化を進めます。',
        '当社の売上高は増加しました。',
        'この行に対象の言葉はありません。'
    ) -join "`n"
    $pa = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    $segsA = @($pa.Segments)
    $null = Set-YakuCatSegmentTranslation -Project $pa -Index 0 -Text 'The Company will advance electrification.'
    $null = Set-YakuCatSegmentTranslation -Project $pa -Index 1 -Text 'The Company posted higher net sales.'
    $null = Set-YakuCatSegmentTranslation -Project $pa -Index 2 -Text 'Nothing to change here.'
    foreach ($i in 0,1,2) { $null = Set-YakuCatSegmentConfirmed -Project $pa -Index $i -Confirmed $true }
    $segsA = @($pa.Segments)
    Chk (@($segsA | Where-Object { [bool]$_.Confirmed }).Count -eq 3) '置換の前は3行とも確認済み（この検査が空振りでないこと）'
    Chk (@($segsA | Where-Object { [string]$_.QcStatus -eq 'passed' }).Count -eq 3) '置換の前は3行とも点検済み'

    $resultA = Invoke-YakuCatSearchReplace -Project $pa -Indexes @(0,1,2) -Find 'The Company' -Replace 'The Group'
    $segsA = @($pa.Segments)
    Chk ([int]$resultA.Replaced -eq 2) ('訳文が変わるのは2行（実際 ' + [int]$resultA.Replaced + ' 行）')
    Chk ([int]$resultA.Occurrences -eq 2) ('置き換えたのは2か所（実際 ' + [int]$resultA.Occurrences + ' か所）')
    Chk ([string]$segsA[0].Translation -eq 'The Group will advance electrification.') '1行目の訳文が置き換わる'
    Chk ([string]$segsA[1].Translation -eq 'The Group posted higher net sales.') '2行目の訳文が置き換わる'
    Chk ([string]$segsA[2].Translation -eq 'Nothing to change here.') '当たらない行の訳文はそのまま'
    Chk (-not [bool]$segsA[0].Confirmed -and -not [bool]$segsA[1].Confirmed) '**変わった行の確認済みが落ちる**'
    Chk ([bool]$segsA[2].Confirmed) '変わらなかった行の確認済みは落とさない'
    Chk ([string]$segsA[0].QcStatus -eq 'not_run' -and [string]$segsA[1].QcStatus -eq 'not_run') '変わった行の点検は not_run へ戻る'
    Chk ([string]$segsA[2].QcStatus -eq 'passed') '変わらなかった行の点検結果は残る'
    Chk ([string]$segsA[0].State -eq 'human_edited') '変わった行は human_edited になる（人が直したのと同じ扱い）'
    Chk ([int]$resultA.Unconfirmed -eq 2) ('確認済みが落ちた行数を返す（実際 ' + [int]$resultA.Unconfirmed + ' 行）')

    # 手で直したときと、同じ1本を通っていること。State / Origin / QcStatus /
    # Confirmed / MaskedTranslation / TmRegistered のどれか1つでも違えば赤。
    $pb = New-YakuCatTextProject -Root $root -Text '当社は電動化を進めます。' -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $pb -Index 0 -Text 'The Company will advance electrification.'
    $null = Set-YakuCatSegmentConfirmed -Project $pb -Index 0 -Confirmed $true
    $null = Set-YakuCatSegmentTranslation -Project $pb -Index 0 -Text 'The Group will advance electrification.'
    $handEdited = @($pb.Segments)[0]
    $sameShape = $true
    foreach ($field in 'Translation','State','Origin','QcStatus','Confirmed','MaskedTranslation','TmRegistered') {
        if ([string]$handEdited.$field -ne [string]$segsA[0].$field) { $sameShape = $false; Write-Host ('       differs: ' + $field) -ForegroundColor DarkYellow }
    }
    Chk $sameShape '置換した行の状態が、手で同じ訳文に直した行と1つも違わない'
    Remove-YakuCatProject -Id ([string]$pb.Id)

    # 置換の記録が追記専用のイベントとして残る（source_hash / target_hash 付き）
    $replaceEvents = @($pa.ReviewEvents | Where-Object { [string]$_.action -eq 'search_replaced' })
    Chk ($replaceEvents.Count -eq 2) ('置換した2行ぶんの記録が残る（実際 ' + $replaceEvents.Count + ' 件）')
    Chk (@($replaceEvents | Where-Object { [string]$_.source_hash -match '^[a-f0-9]{16,64}$' -and [string]$_.target_hash -match '^[a-f0-9]{16,64}$' }).Count -eq 2) '記録に source_hash と target_hash が入る'
    Chk (@($replaceEvents | Where-Object { [string]$_.decision_scope -eq 'translation' }).Count -eq 2) '記録の scope が translation である'
    Remove-YakuCatProject -Id ([string]$pa.Id)

    # ------------------------------------------------------------------ (b)
    Write-Host '(b) 置換で数字が合わなくなった行は確定できず、書き出しも止まる' -ForegroundColor Cyan
    $pc = New-YakuCatTextProject -Root $root -Text '売上高は100百万円でした。' -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $pc -Index 0 -Text 'Revenue was 100 million yen.'
    $null = Set-YakuCatSegmentConfirmed -Project $pc -Index 0 -Confirmed $true
    $beforeEligibility = Get-YakuCatOutputEligibility -Project $pc
    Chk ([bool]$beforeEligibility.TranslationListEligible) '置換の前は書き出せる（この検査が空振りでないこと）'

    $resultC = Invoke-YakuCatSearchReplace -Project $pc -Indexes @(0) -Find '100' -Replace '900'
    Chk ([int]$resultC.Replaced -eq 1) '数字を置き換えられる（止めはしない）'
    $segC = @($pc.Segments)[0]
    Chk ([string]$segC.Translation -eq 'Revenue was 900 million yen.') '訳文の数字が変わっている'
    Chk (-not [bool]$segC.Confirmed) '確認済みが落ちている'
    $confirmBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $pc -Index 0 -Confirmed $true }
    catch { $confirmBlocked = ([string]$_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
    Chk $confirmBlocked '確定しようとすると数字の点検で止まる'
    $afterEligibility = Get-YakuCatOutputEligibility -Project $pc
    Chk (-not [bool]$afterEligibility.TranslationListEligible) '数字が合わないままでは書き出せない'
    Chk (@($afterEligibility.Reasons) -contains 'segment-qc-failed') '止まる理由が segment-qc-failed である'
    # 止める理由を増やしていないこと。DRAFT を止めるのは3つだけ、という決まり。
    $allowedReasons = @('segment-untranslated','segment-qc-failed','segment-qc-not-current','project-empty','source-file-missing','word-unsupported-structure')
    Chk (@(@($afterEligibility.Reasons) | Where-Object { $allowedReasons -notcontains $_ }).Count -eq 0) ('止める理由を増やしていない（実際: ' + ((@($afterEligibility.Reasons)) -join ',') + '）')
    Remove-YakuCatProject -Id ([string]$pc.Id)

    # ------------------------------------------------------------------ (c)
    Write-Host '(c) 置換は絞り込み結果の中だけに掛かる' -ForegroundColor Cyan
    $textD = @('当社は一つ目です。','当社は二つ目です。','当社は三つ目です。','当社は四つ目です。') -join "`n"
    $pd = New-YakuCatTextProject -Root $root -Text $textD -Settings $settings -Direction 'to_en'
    for ($i = 0; $i -lt 4; $i++) { $null = Set-YakuCatSegmentTranslation -Project $pd -Index $i -Text ('The Company is number ' + ($i + 1) + '.') }
    $planD = Get-YakuCatSearchReplacePlan -Project $pd -Indexes @(1,2) -Find 'The Company' -Replace 'The Group'
    Chk ([int]$planD.RowCount -eq 2) ('計画は絞り込みの2行だけを数える（実際 ' + [int]$planD.RowCount + ' 行）')
    Chk ([int]$planD.ScannedRows -eq 2) '読んだ行も2行だけ'
    $resultD = Invoke-YakuCatSearchReplace -Project $pd -Indexes @(1,2) -Find 'The Company' -Replace 'The Group'
    $segsD = @($pd.Segments)
    Chk ([int]$resultD.Replaced -eq [int]$planD.RowCount) ('押す前に数えた行数と、実際に変わった行数が一致する（' + [int]$planD.RowCount + ' / ' + [int]$resultD.Replaced + '）')
    Chk ([string]$segsD[0].Translation -eq 'The Company is number 1.') '絞り込みの外（先頭）は変えない'
    Chk ([string]$segsD[3].Translation -eq 'The Company is number 4.') '絞り込みの外（末尾）は変えない'
    Chk ([string]$segsD[1].Translation -eq 'The Group is number 2.' -and [string]$segsD[2].Translation -eq 'The Group is number 3.') '絞り込みの中は変わる'
    # 対象が無い指定でも落とさない
    $planEmpty = Get-YakuCatSearchReplacePlan -Project $pd -Indexes @() -Find 'The Group' -Replace 'X'
    Chk ([int]$planEmpty.RowCount -eq 0) '対象の行を渡さなければ0行'
    $planOutside = Get-YakuCatSearchReplacePlan -Project $pd -Indexes @(99,-3) -Find 'The Group' -Replace 'X'
    Chk ([int]$planOutside.RowCount -eq 0 -and [int]$planOutside.ScannedRows -eq 0) '範囲外の番号は読まない'

    # ------------------------------------------------------------------ (e)
    Write-Host '(e) 原文は変わらない' -ForegroundColor Cyan
    $sourcesBefore = @($pd.Segments | ForEach-Object { [string]$_.Text })
    $hashesBefore = @($pd.Segments | ForEach-Object { [string]$_.SourceIntegrityHash })
    $revisionsBefore = @($pd.Segments | ForEach-Object { [int]$_.SourceRevision })
    $null = Invoke-YakuCatSearchReplace -Project $pd -Indexes @(0,1,2,3) -Find '当社' -Replace '当グループ'
    $sourcesAfter = @($pd.Segments | ForEach-Object { [string]$_.Text })
    Chk ((($sourcesBefore -join '|') -eq ($sourcesAfter -join '|'))) '原文の文字列が1つも変わらない'
    Chk ((($hashesBefore -join '|') -eq (@($pd.Segments | ForEach-Object { [string]$_.SourceIntegrityHash }) -join '|'))) '原文のハッシュが変わらない'
    Chk ((($revisionsBefore -join '|') -eq (@($pd.Segments | ForEach-Object { [int]$_.SourceRevision }) -join '|'))) '原文の版が上がらない'
    # 原文にしか無い言葉は、訳文の置換では1行も掛からない
    $planSourceOnly = Get-YakuCatSearchReplacePlan -Project $pd -Indexes @(0,1,2,3) -Find '当社' -Replace '当グループ'
    Chk ([int]$planSourceOnly.RowCount -eq 0) '原文にしか無い言葉では0行（置換の対象は訳文だけ）'
    Remove-YakuCatProject -Id ([string]$pd.Id)

    # ------------------------------------------------------------------ (f)
    Write-Host '(f) 読めない式・危ない式で落とさない' -ForegroundColor Cyan
    $pf = New-YakuCatTextProject -Root $root -Text 'テスト行です。' -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $pf -Index 0 -Text 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa test line.'
    $badPattern = ''
    try { $null = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find '(' -Replace 'X' -UseRegex $true }
    catch { $badPattern = [string]$_.Exception.Message }
    Chk ($badPattern -match '^CAT_SEARCH_PATTERN_INVALID') ('読めない正規表現は名前付きで断る（実際 ' + $(if($badPattern){$badPattern.Substring(0,[Math]::Min(40,$badPattern.Length))}else{'例外が出なかった'}) + '）')
    $emptyMatch = ''
    try { $null = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find 'a*' -Replace 'X' -UseRegex $true }
    catch { $emptyMatch = [string]$_.Exception.Message }
    Chk ($emptyMatch -match '^CAT_SEARCH_PATTERN_MATCHES_EMPTY') '空に一致する式は断る（1文字ごとに差し込まない）'
    $emptyFind = ''
    try { $null = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find '' -Replace 'X' }
    catch { $emptyFind = [string]$_.Exception.Message }
    Chk ($emptyFind -match '^CAT_SEARCH_FIND_EMPTY') '探す文字列が空なら断る'
    # 正規表現を使わないときは、記号を字面として扱う
    $null = Set-YakuCatSegmentTranslation -Project $pf -Index 0 -Text 'Cost is a.b and axb.'
    $planLiteral = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find 'a.b' -Replace 'Z'
    Chk ([int]$planLiteral.Occurrences -eq 1 -and [string]@($planLiteral.Rows)[0].After -eq 'Cost is Z and axb.') '正規表現を使わないとき . は字面として扱う'
    # 置換後の $ も字面として入る
    $planDollar = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find 'Cost' -Replace '$1 cost'
    Chk ([string]@($planDollar.Rows)[0].After -eq '$1 cost is a.b and axb.') '正規表現を使わないとき置換後の $1 は字面として入る'
    # 正規表現では置換群が使える
    $planGroup = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find '(a)x(b)' -Replace '$2-$1' -UseRegex $true
    Chk ([string]@($planGroup.Rows)[0].After -eq 'Cost is a.b and b-a.') '正規表現では置換群（$1）が使える'
    # 大文字小文字
    $planCase = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find 'cost' -Replace 'PRICE' -MatchCase $true
    Chk ([int]$planCase.RowCount -eq 0) '大文字小文字を区別すると当たらない'
    $planNoCase = Get-YakuCatSearchReplacePlan -Project $pf -Indexes @(0) -Find 'cost' -Replace 'PRICE'
    Chk ([int]$planNoCase.RowCount -eq 1) '区別しなければ当たる'
    # 置き換えても同じになる行は対象にしない（何も変わらないのに確認済みだけ落とさない）
    $null = Set-YakuCatSegmentConfirmed -Project $pf -Index 0 -Confirmed $true
    $sameResult = Invoke-YakuCatSearchReplace -Project $pf -Indexes @(0) -Find 'Cost' -Replace 'Cost'
    Chk ([int]$sameResult.Replaced -eq 0) '置き換えても同じ文字列になる行は対象にしない'
    Chk ([bool]@($pf.Segments)[0].Confirmed) '同じ文字列なら確認済みも落とさない'
    Remove-YakuCatProject -Id ([string]$pf.Id)

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) cat.js の絞り込みの鍵と cat.html のボタンが1対1' -ForegroundColor Cyan
    $stateFilterBlock = Get-YakuCatJsBlock -Text $catJs -Header '  var stateFilters = {'
    Chk (-not [string]::IsNullOrWhiteSpace($stateFilterBlock)) 'cat.js から絞り込みの表を取り出せた'
    Chk ([string]::IsNullOrWhiteSpace((Get-YakuCatJsBlock -Text $catJs -Header '  var noSuchTableHere = {'))) '無い名前では取り出せない（取り出しが空振りでないこと）'
    $jsFilterKeys = @([regex]::Matches($stateFilterBlock, '(?m)^\s{4}([a-z]+):') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $htmlFilterKeys = @([regex]::Matches($catHtml, 'data-cat-filter="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Chk ($jsFilterKeys.Count -ge 4) ('cat.js の鍵を取り出せた（' + ($jsFilterKeys -join ',') + '）')
    Chk ($htmlFilterKeys.Count -ge 4) ('cat.html のボタンを取り出せた（' + ($htmlFilterKeys -join ',') + '）')
    $onlyInJs = @($jsFilterKeys | Where-Object { $htmlFilterKeys -notcontains $_ })
    $onlyInHtml = @($htmlFilterKeys | Where-Object { $jsFilterKeys -notcontains $_ })
    Chk ($onlyInJs.Count -eq 0) ('押すボタンの無い枝が cat.js に無い（余り: ' + ($onlyInJs -join ',') + '）')
    Chk ($onlyInHtml.Count -eq 0) ('受け手の無いボタンが cat.html に無い（余り: ' + ($onlyInHtml -join ',') + '）')
    $htmlCountKeys = @([regex]::Matches($catHtml, 'data-cat-count="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $countOrphans = @($htmlCountKeys | Where-Object { $jsFilterKeys -notcontains $_ })
    Chk ($countOrphans.Count -eq 0) ('件数の置き場も鍵と1対1（余り: ' + ($countOrphans -join ',') + '）')
    Chk ($catJs -notmatch "currentFilter === 'untranslated'" -and $catJs -notmatch "currentFilter === 'unconfirmed'") '到達できなかった untranslated / unconfirmed の枝が残っていない'
    # Ctrl+H はキー一覧にも書く（一覧と実装をずらさない）
    $keyList = ''
    $km = [regex]::Match($catHtml, '<details class="cat-key-help">.*?</details>', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($km.Success) { $keyList = $km.Value }
    Chk ($keyList -match '<kbd>H</kbd>') 'キー一覧に Ctrl+H が載っている'
    Chk ($catJs -match "key.toLowerCase\(\) === 'h'") 'cat.js が Ctrl+H を受けている'

    # ------------------------------------------------------------------ (h)
    Write-Host '(h) 画面（cat.js）とサーバ（PowerShell）が同じ答を出す' -ForegroundColor Cyan
    # ここは字面では見ない。cat.js の該当部分を node で**実際に走らせて**、
    # 同じ表を PowerShell 側にも通し、選ばれた行と置換後の文字列を突き合わせる。
    $nodeExe = ''
    try { $nodeExe = [string](Get-Command node -ErrorAction Stop).Source } catch { $nodeExe = '' }
    Chk (-not [string]::IsNullOrWhiteSpace($nodeExe)) ('node が使える（' + $(if($nodeExe){$nodeExe}else{'見つからない'}) + '）')

    $jsBlocks = [ordered]@{
        stateFilters = '  var stateFilters = {'
        escapeRegExp = '  function escapeRegExp('
        searchMatcher = '  function searchMatcher('
        searchFields = '  function searchFields('
        segmentMatchesFilter = '  function segmentMatchesFilter('
        visibleSegments = '  function visibleSegments('
        replaceTargets = '  function replaceTargets('
        renderSearchTools = '  function renderSearchTools('
        isAlwaysEnabled = '  function isAlwaysEnabled('
        setBusy = '  function setBusy('
    }
    $harnessParts = New-Object System.Collections.Generic.List[string]
    $missingBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($blockName in $jsBlocks.Keys) {
        $block = Get-YakuCatJsBlock -Text $catJs -Header ([string]$jsBlocks[$blockName])
        if ([string]::IsNullOrWhiteSpace($block)) { [void]$missingBlocks.Add($blockName); continue }
        if ($blockName -eq 'stateFilters') { $block = $block + ';' }
        [void]$harnessParts.Add($block)
    }
    Chk ($missingBlocks.Count -eq 0) ('cat.js の該当部分を全部取り出せた（欠け: ' + (($missingBlocks.ToArray()) -join ',') + '）')

    # 原文は1行1文の日本語にする。切り分けが意図と違う数になったら、下の
    # 「6行を用意できた」で赤になる。
    $segmentsForJs = @(
        [ordered]@{ index=0; source='電動化の行です。'; translation='The Company will advance electrification.'; location='本文'; confirmed=$false; qc_findings=@(); repetition_count=1; change_kind='' }
        [ordered]@{ index=1; source='固定費の行です。'; translation='Net sales rose and costs fell.'; location='本文'; confirmed=$true; qc_findings=@(); repetition_count=1; change_kind='' }
        [ordered]@{ index=2; source='この行の原文には The Company という語があります。'; translation='原文だけに出る語の行です。'; location='本文'; confirmed=$false; qc_findings=@(); repetition_count=1; change_kind='' }
        [ordered]@{ index=3; source='実績の行です。'; translation='Results for FY2025 and FY2024.'; location='本文'; confirmed=$false; qc_findings=@(); repetition_count=1; change_kind='' }
        [ordered]@{ index=4; source='訳文が空の行です。'; translation=''; location='本文'; confirmed=$false; qc_findings=@(); repetition_count=1; change_kind='' }
        [ordered]@{ index=5; source='費用の行です。'; translation='Cost is a.b and axb.'; location='本文'; confirmed=$false; qc_findings=@(); repetition_count=1; change_kind='' }
    )
    $matchCases = @(
        [ordered]@{ name='字面';                 find='The Company'; replace='The Group'; use_regex=$false; match_case=$false; scope='target' }
        [ordered]@{ name='大小を区別しない';     find='net sales';   replace='revenue';   use_regex=$false; match_case=$false; scope='target' }
        [ordered]@{ name='大小を区別する';       find='net sales';   replace='revenue';   use_regex=$false; match_case=$true;  scope='target' }
        [ordered]@{ name='正規表現と置換群';     find='FY(\d{4})';   replace='fiscal $1'; use_regex=$true;  match_case=$false; scope='target' }
        [ordered]@{ name='記号は字面';           find='a.b';         replace='Z';         use_regex=$false; match_case=$false; scope='target' }
        [ordered]@{ name='置換後の$は字面';      find='Cost';        replace='$1 cost';   use_regex=$false; match_case=$false; scope='target' }
        [ordered]@{ name='置き換えても同じ';     find='Cost';        replace='Cost';      use_regex=$false; match_case=$true;  scope='target' }
        [ordered]@{ name='原文と訳文を探す';     find='The Company'; replace='The Group'; use_regex=$false; match_case=$false; scope='both' }
        [ordered]@{ name='読めない式';           find='(';           replace='X';         use_regex=$true;  match_case=$false; scope='target' }
        [ordered]@{ name='空に一致する式';       find='a*';          replace='X';         use_regex=$true;  match_case=$false; scope='target' }
    )
    $filterCases = @(
        [ordered]@{ key='actionable'; rows=@(0,2,3,4,5) }
        [ordered]@{ key='reviewed';   rows=@(1) }
        [ordered]@{ key='all';        rows=@(0,1,2,3,4,5) }
    )
    $harnessPath = Join-Path $tmp 'cat-matcher.js'
    $inputPath = Join-Path $tmp 'cat-matcher-input.json'
    $outputPath = Join-Path $tmp 'cat-matcher-output.json'
    $harness = @"
'use strict';
/* cat.js から切り出した本体を、そのまま走らせる。写経はしない。
   ここで用意するのは、切り出した本体が読む外側の名前だけである。 */
function makeEl(id, attrs) {
  return {
    id: id, disabled: false, checked: false, value: '', textContent: '', hidden: false,
    _attrs: Object.assign({}, attrs || {}),
    classList: {
      _s: {},
      add: function (c) { this._s[c] = 1; },
      remove: function (c) { delete this._s[c]; },
      contains: function (c) { return !!this._s[c]; },
      toggle: function (c, on) { if (on === undefined) { if (this._s[c]) { delete this._s[c]; } else { this._s[c] = 1; } } else if (on) { this._s[c] = 1; } else { delete this._s[c]; } }
    },
    hasAttribute: function (n) { return Object.prototype.hasOwnProperty.call(this._attrs, n); },
    getAttribute: function (n) { return this.hasAttribute(n) ? this._attrs[n] : null; },
    setAttribute: function (n, v) { this._attrs[n] = String(v); },
    closest: function () { return null; }
  };
}
var ELEMENTS = {};
['cat-search','cat-replace-input','cat-replace-run','cat-replace-summary','cat-search-case','cat-search-regex','cat-translate','cat-export','cat-export-reviewed'].forEach(function (id) { ELEMENTS[id] = makeEl(id); });
var SCOPE_BUTTONS = ['both','source','target'].map(function (v) { return makeEl('scope-' + v, { 'data-cat-search-scope': v }); });
function el(id) { return Object.prototype.hasOwnProperty.call(ELEMENTS, id) ? ELEMENTS[id] : null; }
var document = {
  getElementById: function (id) { return el(id); },
  querySelector: function () { return null; },
  querySelectorAll: function (selector) {
    if (selector === '[data-cat-search-scope]') { return SCOPE_BUTTONS; }
    if (selector === 'button') { return [ELEMENTS['cat-replace-run'], ELEMENTS['cat-translate'], ELEMENTS['cat-export'], ELEMENTS['cat-export-reviewed']].concat(SCOPE_BUTTONS); }
    return [];
  }
};
var searchScope = 'both', searchCase = false, searchRegex = false;
var currentFilter = 'all', currentLocation = 'all', currentChange = 'all';
var project = null, busy = false, ready = true, dirty = new Map();
/* 絞り込みの述語が読む3つ。cat.js の本物と同じ式を置く（qc_findings の有無、
   確認済みかどうか、場所と変更の別）。 */
function segmentHasQc(segment) { return (segment.qc_findings || []).length > 0; }
function segmentActionable(segment) { return !segment.confirmed || segmentHasQc(segment); }
function locationGroup(segment) { return String(segment.location || '本文'); }
function changeGroup(segment) { return String(segment.change_kind || ''); }
/* setBusy が呼ぶだけで、置換のボタンには触らないもの。 */
function updateActionLabels() {}
function updateQaButton() {}
function updateAlignEstimate() {}

$($harnessParts.ToArray() -join "`n")

var fs = require('fs');
var input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
project = { segments: input.segments };
var matchOut = input.cases.map(function (one) {
  ELEMENTS['cat-search'].value = one.find; ELEMENTS['cat-replace-input'].value = one.replace;
  searchScope = one.scope; searchCase = !!one.match_case; searchRegex = !!one.use_regex;
  currentFilter = 'all';
  var matcher = searchMatcher();
  var targets = replaceTargets();
  return {
    name: one.name,
    invalid: !!matcher.invalid,
    visible: visibleSegments().map(function (s) { return s.index; }),
    targets: targets.map(function (s) { return s.index; }),
    after: targets.map(function (s) { return matcher.replace(String(s.translation || '')); })
  };
});
ELEMENTS['cat-search'].value = ''; ELEMENTS['cat-replace-input'].value = '';
searchScope = 'both'; searchCase = false; searchRegex = false;
var filterOut = Object.keys(stateFilters).map(function (key) {
  currentFilter = key;
  return { key: key, rows: visibleSegments().map(function (s) { return s.index; }) };
});

/* 待機の切り替えが、置換のボタンの可否を壊さないこと。
   setBusy(false) は全ボタンを押せる状態へ戻すので、そのあとで条件から
   決め直さないと、探す文字列が空でも押せてしまう（実機で実際にそうなった、
   2026-08-15）。ここは「呼んでいるか」ではなく、押せるかどうかの値を見る。 */
currentFilter = 'all'; searchScope = 'target';
ELEMENTS['cat-search'].value = ''; ELEMENTS['cat-replace-input'].value = '';
renderSearchTools();
setBusy(true);
var busyState = { disabled: !!ELEMENTS['cat-replace-run'].disabled };
setBusy(false);
var idleEmpty = { disabled: !!ELEMENTS['cat-replace-run'].disabled, label: String(ELEMENTS['cat-replace-run'].textContent) };
ELEMENTS['cat-search'].value = 'The Company'; ELEMENTS['cat-replace-input'].value = 'The Group';
renderSearchTools();
setBusy(false);
var idleHit = { disabled: !!ELEMENTS['cat-replace-run'].disabled, label: String(ELEMENTS['cat-replace-run'].textContent) };

fs.writeFileSync(process.argv[3], JSON.stringify({
  matches: matchOut, filters: filterOut,
  busyState: busyState, idleEmpty: idleEmpty, idleHit: idleHit
}), 'utf8');
"@
    [IO.File]::WriteAllText($harnessPath, $harness, (New-Object Text.UTF8Encoding($false)))
    $inputJson = ([ordered]@{ segments = @($segmentsForJs); cases = @($matchCases) } | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText($inputPath, $inputJson, (New-Object Text.UTF8Encoding($false)))

    $nodeOut = $null
    if (-not [string]::IsNullOrWhiteSpace($nodeExe)) {
        $nodeErr = ''
        try {
            $nodeStdErr = Join-Path $tmp 'node-stderr.txt'
            $proc = Start-Process -FilePath $nodeExe -ArgumentList @($harnessPath, $inputPath, $outputPath) -NoNewWindow -Wait -PassThru -RedirectStandardError $nodeStdErr
            if ([int]$proc.ExitCode -ne 0) { $nodeErr = [IO.File]::ReadAllText($nodeStdErr) }
        } catch { $nodeErr = [string]$_.Exception.Message }
        Chk ([string]::IsNullOrWhiteSpace($nodeErr)) ('cat.js の該当部分が node で走る' + $(if($nodeErr){' / ' + $nodeErr.Substring(0,[Math]::Min(200,$nodeErr.Length))}else{''}))
        if (Test-Path -LiteralPath $outputPath) {
            $nodeOut = [IO.File]::ReadAllText($outputPath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
        }
    }
    Chk ($null -ne $nodeOut) '画面側の答を受け取れた'

    if ($null -ne $nodeOut) {
        # 同じ表を PowerShell 側にも通す。行の中身は上の segmentsForJs と同じものを
        # 使う（原文はここでは効かない。効くのは訳文である）。
        $textH = @($segmentsForJs | ForEach-Object { [string]$_['source'] }) -join "`n"
        $ph = New-YakuCatTextProject -Root $root -Text $textH -Settings $settings -Direction 'to_en'
        $segsH = @($ph.Segments)
        Chk ($segsH.Count -eq $segmentsForJs.Count) ('突き合わせ用に ' + $segmentsForJs.Count + ' 行を用意できた（実際 ' + $segsH.Count + ' 行）')
        for ($i = 0; $i -lt [Math]::Min($segsH.Count, $segmentsForJs.Count); $i++) {
            $wanted = [string]$segmentsForJs[$i]['translation']
            if ([string]::IsNullOrEmpty($wanted)) { continue }
            $null = Set-YakuCatSegmentTranslation -Project $ph -Index $i -Text $wanted
        }
        $allIndexes = @(0..($segsH.Count - 1))
        $mismatch = New-Object System.Collections.Generic.List[string]
        for ($c = 0; $c -lt $matchCases.Count; $c++) {
            $case = $matchCases[$c]
            $jsRow = @($nodeOut.matches)[$c]
            $caseName = [string]$case['name']
            $psInvalid = $false; $psPlan = $null
            try {
                $psPlan = Get-YakuCatSearchReplacePlan -Project $ph -Indexes $allIndexes -Find ([string]$case['find']) `
                    -Replace ([string]$case['replace']) -UseRegex ([bool]$case['use_regex']) -MatchCase ([bool]$case['match_case'])
            } catch { $psInvalid = $true }
            if ([bool]$jsRow.invalid -ne $psInvalid) { [void]$mismatch.Add($caseName + ': 式の可否が違う（画面 ' + [bool]$jsRow.invalid + ' / サーバ ' + $psInvalid + '）'); continue }
            if ($psInvalid) { continue }
            $psTargets = @(@($psPlan.Rows) | ForEach-Object { [int]$_.Index })
            $jsTargets = @(@($jsRow.targets) | ForEach-Object { [int]$_ })
            if (($psTargets -join ',') -ne ($jsTargets -join ',')) {
                [void]$mismatch.Add($caseName + ': 対象行が違う（画面 [' + ($jsTargets -join ',') + '] / サーバ [' + ($psTargets -join ',') + ']）')
                continue
            }
            $psAfter = @(@($psPlan.Rows) | ForEach-Object { [string]$_.After })
            $jsAfter = @(@($jsRow.after) | ForEach-Object { [string]$_ })
            if (($psAfter -join [char]31) -ne ($jsAfter -join [char]31)) {
                [void]$mismatch.Add($caseName + ': 置換後の文字列が違う（画面 [' + ($jsAfter -join ' | ') + '] / サーバ [' + ($psAfter -join ' | ') + ']）')
            }
        }
        Chk ($mismatch.Count -eq 0) ('画面とサーバが ' + $matchCases.Count + ' 通りすべてで同じ答を出す' + $(if($mismatch.Count){"`n       " + (($mismatch.ToArray()) -join "`n       ")}else{''}))
        # この突き合わせが空振りでないこと（当たる場面が実際にあること）
        $hitCases = @(@($nodeOut.matches) | Where-Object { @($_.targets).Count -gt 0 })
        Chk ($hitCases.Count -ge 4) ('少なくとも4通りは実際に行が当たっている（実際 ' + $hitCases.Count + ' 通り）')
        $invalidCases = @(@($nodeOut.matches) | Where-Object { [bool]$_.invalid })
        Chk ($invalidCases.Count -eq 2) ('読めない式・空に一致する式は、画面でも断っている（実際 ' + $invalidCases.Count + ' 通り）')
        # scope が both でも target でも、置換の対象行は同じになる
        $bothCase = @(@($nodeOut.matches) | Where-Object { [string]$_.name -eq '原文と訳文を探す' })[0]
        $targetCase = @(@($nodeOut.matches) | Where-Object { [string]$_.name -eq '字面' })[0]
        Chk ((@($bothCase.targets) -join ',') -eq (@($targetCase.targets) -join ',')) '探す場所が「原文と訳文」でも、置き換わるのは訳文が当たった行だけ'
        Chk (@($bothCase.visible).Count -gt @($targetCase.visible).Count) '「原文と訳文」のほうが、表に出る行は多い（探す場所が効いている）'
        Remove-YakuCatProject -Id ([string]$ph.Id)

        # 絞り込みの鍵が、実際に別々の行を選ぶこと。鍵があるだけでは意味が無い。
        $filterProblems = New-Object System.Collections.Generic.List[string]
        foreach ($expected in $filterCases) {
            $expectedKey = [string]$expected['key']
            $actual = @(@($nodeOut.filters) | Where-Object { [string]$_.key -eq $expectedKey })
            if ($actual.Count -ne 1) { [void]$filterProblems.Add($expectedKey + ': 鍵が無い'); continue }
            $rows = @(@($actual[0].rows) | ForEach-Object { [int]$_ })
            if (($rows -join ',') -ne (@($expected['rows']) -join ',')) {
                [void]$filterProblems.Add($expectedKey + ': [' + ($rows -join ',') + '] を選んだ（期待 [' + (@($expected['rows']) -join ',') + ']）')
            }
        }
        Chk ($filterProblems.Count -eq 0) ('絞り込みの鍵ごとに、期待した行が選ばれる' + $(if($filterProblems.Count){' / ' + (($filterProblems.ToArray()) -join ' / ')}else{''}))
        $jsFilterRuntimeKeys = @(@($nodeOut.filters) | ForEach-Object { [string]$_.key } | Sort-Object)
        Chk ((($jsFilterRuntimeKeys) -join ',') -eq (($jsFilterKeys | Sort-Object) -join ',')) ('走らせて出た鍵と、cat.html のボタンが一致する（' + ($jsFilterRuntimeKeys -join ',') + '）')

        # 待機の切り替えが、置換ボタンの可否を壊さないこと。ここは「renderSearchTools
        # を呼んでいるか」を字面で見ない。呼ぶ行を if (false) に変えても字面は
        # 残るので、それは門にならない（実測 2026-08-15）。実際に setBusy を
        # 走らせて、押せるかどうかの値を見る。
        Chk ([bool]$nodeOut.busyState.disabled) '処理中は置換のボタンを押せない'
        Chk ([bool]$nodeOut.idleEmpty.disabled) '処理が終わっても、探す文字列が空なら押せないままにする'
        Chk ([string]$nodeOut.idleEmpty.label -eq '訳文を置き換える') '押せないときのボタンは行数を名乗らない'
        Chk (-not [bool]$nodeOut.idleHit.disabled) '探す文字列が当たれば、処理が終わったあとに押せる'
        Chk ([string]$nodeOut.idleHit.label -match '^表示中の\d+行の訳文を置き換える$') ('押せるときのボタンに対象行数が出る（実際 ' + [string]$nodeOut.idleHit.label + '）')
    }

    # ------------------------------------------------------------ サーバの口
    Write-Host '(g) サーバの口（ルート本体を Server.ps1 から取り出して走らせる）' -ForegroundColor Cyan
    $serverFile = Join-Path (Join-Path $root 'src') 'Server.ps1'
    $rtEstimateRoute = Get-YakuServerRouteBody -ServerPath $serverFile -Route 'replace-estimate'
    $rtApplyRoute = Get-YakuServerRouteBody -ServerPath $serverFile -Route 'replace'
    Chk ($null -ne $rtEstimateRoute) ('見積りのルート本体を Server.ps1 から取り出せた' +
        $(if ($null -ne $rtEstimateRoute) { '（' + $rtEstimateRoute.StartLine + '-' + $rtEstimateRoute.EndLine + ' 行）' } else { '' }))
    Chk ($null -ne $rtApplyRoute) ('置換のルート本体を Server.ps1 から取り出せた' +
        $(if ($null -ne $rtApplyRoute) { '（' + $rtApplyRoute.StartLine + '-' + $rtApplyRoute.EndLine + ' 行）' } else { '' }))
    Chk ($null -eq (Get-YakuServerRouteBody -ServerPath $serverFile -Route 'replace-no-such-route')) '無い名前では取り出せない（取り出しが空振りでないこと）'
    # 置換は版の食い違いを見る操作である。一覧へ入れ忘れると、別のタブの更新を
    # 黙って踏み潰す。一覧そのものを構文木から取り出して見る。
    $serverTokens = $null; $serverParseErrors = $null
    $serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverFile, [ref]$serverTokens, [ref]$serverParseErrors)
    $revisionActionList = @()
    foreach ($assign in @($serverAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        if ([string]$assign.Left.Extent.Text -ne '$revisionActions') { continue }
        $revisionActionList = @([regex]::Matches([string]$assign.Right.Extent.Text, "'([a-z\-]+)'") | ForEach-Object { $_.Groups[1].Value })
    }
    Chk ($revisionActionList.Count -gt 10) ('版を見る操作の一覧を取り出せた（' + $revisionActionList.Count + ' 件）')
    Chk ($revisionActionList -contains 'replace') '置換が「版を見る操作」に入っている'
    Chk ($revisionActionList -notcontains 'replace-estimate') '見積りは版を見ない（何も書き換えないため）'

    if ($null -eq $rtEstimateRoute -or $null -eq $rtApplyRoute) {
        Write-Host '  SKIP ルート本体を取り出せなかったので、サーバの口は走らせられない' -ForegroundColor Red
    } else {
        $rtText = @(
            '当社は一つ目です。',
            '当社は二つ目です。',
            '当社は三つ目です。'
        ) -join "`n"
        # 訳文に数字を入れない。原文に無い数字を入れると数字の点検に落ちて、
        # ここで確認済みにできなくなる（それはそれで正しい振る舞いである）。
        $rtTargets = @('The Company is first.','The Company is second.','The Company is third.')
        $rtDraft = New-YakuCatTextProject -Root $root -Text $rtText -Settings $settings -Direction 'to_en'
        $project = Commit-YakuNewCatProject -Project $rtDraft
        for ($i = 0; $i -lt 3; $i++) { $null = Set-YakuCatSegmentTranslation -Project $project -Index $i -Text $rtTargets[$i] }
        $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0 -Confirmed $true
        $null = Set-YakuCatSegmentConfirmed -Project $project -Index 1 -Confirmed $true
        $Context = $null
        $rtRevisionBefore = [int]$project.Revision
        $expectedRevision = $rtRevisionBefore
        # 画面は絞り込み結果の番号を送る。ここでは 0 と 1 だけを送る。
        $payload = @{ indexes = @(0,1); find = 'The Company'; replace = 'The Group'; use_regex = $false; match_case = $false }

        $rtEstimate = $null; $rtEstimateNote = ''
        try { $rtEstimate = (Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text) | ConvertFrom-Json }
        catch { $rtEstimateNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $rtEstimate) ('見積りの口が応答を返す' + $rtEstimateNote)
        Chk ([int]$rtEstimate.rows -eq 2) ('見積りが対象2行を返す（実際 ' + [int]$rtEstimate.rows + ' 行）')
        Chk ([int]$rtEstimate.occurrences -eq 2) ('見積りが2か所を返す（実際 ' + [int]$rtEstimate.occurrences + ' か所）')
        Chk ([int]$rtEstimate.confirmed_rows -eq 2) ('確認済みが外れる行数を先に告げる（実際 ' + [int]$rtEstimate.confirmed_rows + ' 行）')
        Chk ([int]$rtEstimate.scanned_rows -eq 2) '読んだ行は絞り込みの2行だけ'
        Chk ([string]@($project.Segments)[0].Translation -eq 'The Company is first.') '見積りだけでは1行も書き換えない'
        Chk ([bool]@($project.Segments)[0].Confirmed) '見積りだけでは確認済みも落とさない'

        $rtApply = $null; $rtApplyNote = ''
        try { $rtApply = (Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text) | ConvertFrom-Json }
        catch { $rtApplyNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $rtApply) ('置換の口が応答を返す' + $rtApplyNote)
        $rtApplyNames = @(); if ($null -ne $rtApply) { $rtApplyNames = @($rtApply.PSObject.Properties.Name) }
        Chk ($rtApplyNames -contains 'replace_rows') '応答に replace_rows が載る'
        Chk ([int]$rtApply.replace_rows -eq 2) ('2行を置き換えたと応答する（実際 ' + [int]$rtApply.replace_rows + ' 行）')
        Chk ([int]$rtEstimate.rows -eq [int]$rtApply.replace_rows) ('押す前に告げた行数と、実際に変わった行数が一致する（' + [int]$rtEstimate.rows + ' / ' + [int]$rtApply.replace_rows + '）')
        Chk ([int]$rtEstimate.occurrences -eq [int]$rtApply.replace_occurrences) '告げたか所数と、実際のか所数が一致する'
        Chk ([int]$rtEstimate.confirmed_rows -eq [int]$rtApply.replace_unconfirmed) '告げた「確認済みが外れる行数」と実際が一致する'
        $rtSegs = @($rtApply.segments)
        Chk ($rtSegs.Count -eq 3) ('応答に3行が載る（実際 ' + $rtSegs.Count + ' 行）')
        Chk ([string]$rtSegs[0].translation -eq 'The Group is first.') '応答の中でも1行目が置き換わっている'
        Chk ([string]$rtSegs[2].translation -eq 'The Company is third.') '絞り込みの外は応答の中でも変わらない'
        Chk (-not [bool]$rtSegs[0].confirmed -and -not [bool]$rtSegs[1].confirmed) '**応答の中でも、置き換えた行の確認済みが落ちている**'
        Chk ([string]$rtSegs[0].qc_status -eq 'not_run') '応答の中でも点検が not_run へ戻っている'
        Chk ([string]$rtSegs[0].source -eq '当社は一つ目です。') '応答の中でも原文は変わらない'
        Chk ([int]$rtApply.revision -eq ($rtRevisionBefore + 1)) ('置換で revision が1つ進む（' + $rtRevisionBefore + ' → ' + [int]$rtApply.revision + '）')

        # 画面が読む名前と、サーバが返す名前をつなぐ。cat.js の該当箇所から名前を
        # 拾い、実際の応答に全部あるかを見る。どちらかを改名すれば赤になる。
        $rtJs = Get-YakuCatJsBlock -Text $catJs -Header '  function runReplace('
        Chk (-not [string]::IsNullOrWhiteSpace($rtJs)) '画面側の置換の処理を cat.js から取り出せた'
        $rtJsResultKeys = @([regex]::Matches($rtJs, 'result\.(replace_[a-z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $rtJsDataKeys = @([regex]::Matches($rtJs, 'data && data\.([a-z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Chk ($rtJsResultKeys.Count -ge 3) ('画面が読む replace_* の名前を取り出せた（' + ($rtJsResultKeys -join ',') + '）')
        Chk ($rtJsDataKeys.Count -ge 3) ('画面が読む見積りの名前を取り出せた（' + ($rtJsDataKeys -join ',') + '）')
        $rtMissingResult = @($rtJsResultKeys | Where-Object { $rtApplyNames -notcontains $_ })
        Chk ($rtMissingResult.Count -eq 0) ('画面が読む replace_* が、サーバの応答にすべてある（欠け: ' + (($rtMissingResult) -join ',') + '）')
        $rtEstimateNames = @(); if ($null -ne $rtEstimate) { $rtEstimateNames = @($rtEstimate.PSObject.Properties.Name) }
        $rtMissingData = @($rtJsDataKeys | Where-Object { $rtEstimateNames -notcontains $_ })
        Chk ($rtMissingData.Count -eq 0) ('画面が読む見積りの名前が、サーバの応答にすべてある（欠け: ' + (($rtMissingData) -join ',') + '）')
        # 画面が送る名前も、サーバが読む名前と合っていること
        $rtJsSentKeys = @([regex]::Matches($rtJs, "(?:indexes|find|replace|use_regex|match_case|scope):") | ForEach-Object { $_.Value.TrimEnd(':') } | Sort-Object -Unique)
        Chk ($rtJsSentKeys.Count -eq 6) ('画面が送る6つの名前がそろっている（' + ($rtJsSentKeys -join ',') + '）')
        foreach ($sent in $rtJsSentKeys) {
            Chk ($rtApplyRoute.Text -match ("payload\['" + $sent + "'\]")) ('サーバの置換の口が ' + $sent + ' を読んでいる')
        }

        # ------------------------------------------------------------ (i)
        # 「探す場所が原文だけなら訳文を書き換えない」をサーバでも断る。
        # これを守っていたのは cat.js の3行だけで、3つとも外しても回帰は
        # 全件緑だった（2026-08-15 の指摘）。原文は資料そのものなので、
        # 画面の親切ではなく決まりである。口を直接叩いて確かめる。
        Write-Host '(i) 探す場所が原文だけなら、サーバが断る' -ForegroundColor Cyan
        $expectedRevision = [int]$project.Revision
        $rtScopeBefore = @($project.Segments | ForEach-Object { [string]$_.Translation })
        $payload = @{ indexes = @(0,1,2); find = 'The Group'; replace = 'X'; use_regex = $false; match_case = $false; scope = 'source' }
        $rtScopeEstimate = ''
        try { $null = Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text } catch { $rtScopeEstimate = [string]$_.Exception.Message }
        Chk ($rtScopeEstimate -match '^CAT_REPLACE_SCOPE_SOURCE') ('見積りの口が断る（実際 ' +
            $(if ([string]::IsNullOrWhiteSpace($rtScopeEstimate)) { '断らなかった' } else { $rtScopeEstimate.Substring(0, [Math]::Min(30, $rtScopeEstimate.Length)) }) + '）')
        $rtScopeApply = ''
        try { $null = Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text } catch { $rtScopeApply = [string]$_.Exception.Message }
        Chk ($rtScopeApply -match '^CAT_REPLACE_SCOPE_SOURCE') ('置換の口も断る（実際 ' +
            $(if ([string]::IsNullOrWhiteSpace($rtScopeApply)) { '断らなかった' } else { $rtScopeApply.Substring(0, [Math]::Min(30, $rtScopeApply.Length)) }) + '）')
        $rtScopeAfter = @($project.Segments | ForEach-Object { [string]$_.Translation })
        Chk ((($rtScopeAfter) -join '|') -eq (($rtScopeBefore) -join '|')) '断ったとき、訳文は1文字も変わっていない'
        # 空振り防止。同じ要求で scope だけを変えれば、ちゃんと通る。
        $payload = @{ indexes = @(0,1,2); find = 'The Company'; replace = 'X'; use_regex = $false; match_case = $false; scope = 'target' }
        $rtScopeOk = $null; $rtScopeOkNote = ''
        try { $rtScopeOk = (Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text) | ConvertFrom-Json } catch { $rtScopeOkNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $rtScopeOk -and [int]$rtScopeOk.rows -ge 1) ('探す場所が訳文なら、同じ要求が通る（この検査が空振りでないこと）' + $rtScopeOkNote)
        # 古い画面（scope を送らない）は断らない。
        $payload = @{ indexes = @(0,1,2); find = 'The Company'; replace = 'X'; use_regex = $false; match_case = $false }
        $rtScopeMissing = $null; $rtScopeMissingNote = ''
        try { $rtScopeMissing = (Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text) | ConvertFrom-Json } catch { $rtScopeMissingNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $rtScopeMissing) ('探す場所を送らない要求は、これまでどおり通る' + $rtScopeMissingNote)

        # 別のタブが先に更新していたら、黙って上書きしない。
        $rtStale = ''
        $expectedRevision = $rtRevisionBefore
        try { $null = Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text } catch { $rtStale = [string]$_.Exception.Message }
        Chk ($rtStale -match '^CAT_PROJECT_REVISION_CONFLICT') ('古い revision では競合として止まる（実際 ' +
            $(if ([string]::IsNullOrWhiteSpace($rtStale)) { '止まらなかった' } else { $rtStale.Substring(0, [Math]::Min(38, $rtStale.Length)) }) + '）')

        # 対象の行を渡さなければ断る
        $expectedRevision = [int]$project.Revision
        $payload = @{ indexes = @(); find = 'The Group'; replace = 'X'; use_regex = $false; match_case = $false }
        $rtNoTarget = ''
        try { $null = Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text } catch { $rtNoTarget = [string]$_.Exception.Message }
        Chk ($rtNoTarget -match '^CAT_REPLACE_NO_TARGET') '対象の行が無ければ断る'

        # 読めない式でも 500 で落とさず、名前付きで断る
        $payload = @{ indexes = @(0,1,2); find = '('; replace = 'X'; use_regex = $true; match_case = $false }
        $rtBadPattern = ''
        try { $null = Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text } catch { $rtBadPattern = [string]$_.Exception.Message }
        Chk ($rtBadPattern -match '^CAT_SEARCH_PATTERN_INVALID') '見積りの口も、読めない式を名前付きで断る'

        Remove-YakuCatProject -Id ([string]$project.Id)
    }

    # ------------------------------------------------------------------- (j)
    # 一括置換は行数の2乗にならないこと。
    #
    # 実測（2026-08-15、全行が対象の資料。直す前）:
    #   200行 2,492ms → 400行 8,728ms → 800行 35,492ms（倍にすると3.5〜4.1倍）
    #   しかも同じ資料への2回目は 2.4〜2.6倍（記録が消えないので伸び続ける）
    # 原因は Add-YakuCatHumanDecisionEvent が1行ごとに既存イベント全件を走査し、
    # 全件を新しい配列へ写していたこと。Invoke-YakuCatSearchReplace のコメントが
    # 「行ごとに Initialize を呼ぶと2乗になる」と書いてそれを避けた、その同じ
    # ループの中に別の2乗が残っていた。
    #
    # 直したあとに見るのは2つ。どちらも大きさに依らない比なので、機械が速くても
    # 遅くても同じ判定になる。
    Write-Host '(j) 一括置換が行数の2乗にならない' -ForegroundColor Cyan
    function New-YakuReplacePerfProject {
        param([Parameter(Mandatory=$true)][int]$Lines)
        $texts = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $Lines; $i++) { [void]$texts.Add(('第' + ($i + 1) + '節。当社の売上高は' + (100 + $i) + '億円で、前期から増加しました。')) }
        $perfProject = New-YakuCatTextProject -Root $root -Text (($texts.ToArray()) -join "`n") -Settings $settings -Direction 'to_en'
        $perfCount = @($perfProject.Segments).Count
        for ($i = 0; $i -lt $perfCount; $i++) {
            $null = Set-YakuCatSegmentTranslation -Project $perfProject -Index $i -Text ('Section ' + ($i + 1) + '. The Company posted net sales of ' + (100 + $i) + ' billion yen.')
        }
        return $perfProject
    }
    function Measure-YakuReplaceMs {
        param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$From,[Parameter(Mandatory=$true)][string]$Into)
        $indexes = @(0..(@($Project.Segments).Count - 1))
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-YakuCatSearchReplace -Project $Project -Indexes $indexes -Find $From -Replace $Into
        $watch.Stop()
        return [pscustomobject]@{ Ms = [double]$watch.Elapsed.TotalMilliseconds; Replaced = [int]$result.Replaced }
    }
    $perfSmall = New-YakuReplacePerfProject -Lines 100
    $perfLarge = New-YakuReplacePerfProject -Lines 200
    $perfSmallCount = @($perfSmall.Segments).Count
    $perfLargeCount = @($perfLarge.Segments).Count
    Chk ($perfLargeCount -eq ($perfSmallCount * 2)) ('題材は行数がちょうど倍（' + $perfSmallCount + ' → ' + $perfLargeCount + '）')

    $perfSmallFirst = Measure-YakuReplaceMs -Project $perfSmall -From 'The Company' -Into 'The Group'
    $perfLargeFirst = Measure-YakuReplaceMs -Project $perfLarge -From 'The Company' -Into 'The Group'
    Chk ($perfSmallFirst.Replaced -eq $perfSmallCount -and $perfLargeFirst.Replaced -eq $perfLargeCount) '両方とも全行を置き換えている（測っている仕事が同じ形である）'
    $growth = $(if ($perfSmallFirst.Ms -gt 0) { $perfLargeFirst.Ms / $perfSmallFirst.Ms } else { 0 })
    Chk ($growth -le 2.8) ('行数を倍にしたときの所要は倍前後に収まる（' + ('{0:N0}' -f $perfSmallFirst.Ms) + 'ms → ' + ('{0:N0}' -f $perfLargeFirst.Ms) + 'ms、' + ('{0:N2}' -f $growth) + '倍。2乗なら4倍前後になる）')

    # 2回目。記録は消えないので、追記のたびに全件を写す作りだと必ず伸びる。
    $perfLargeSecond = Measure-YakuReplaceMs -Project $perfLarge -From 'The Group' -Into 'The Firm'
    Chk ($perfLargeSecond.Replaced -eq $perfLargeCount) '2回目も全行を置き換えている'
    Chk (@($perfLarge.ReviewEvents).Count -eq ($perfLargeCount * 2)) ('記録は置き換えた行の数だけ増える（' + @($perfLarge.ReviewEvents).Count + ' 件）')

    # 記録の件数に対しても2乗にならないこと。**ここが本丸である。**
    # 壊れていた作りは1行ごとに既存イベント全件を走査し全件を写すので、
    # 資料が育つほど（＝長く使うほど）遅くなった。同じ行数の置換を、
    # 記録が空の資料と、記録が既に3,000件ある資料とで比べる。
    # まとめて index 化するなら差はほぼ出ない。1行ごとに舐めるなら跳ね上がる。
    $perfAged = New-YakuReplacePerfProject -Lines 50
    $perfAgedCount = @($perfAged.Segments).Count
    $perfFresh = Measure-YakuReplaceMs -Project $perfAged -From 'The Company' -Into 'The Group'
    $seeded = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($perfAged.ReviewEvents)) { [void]$seeded.Add($event) }
    for ($i = 0; $i -lt 3000; $i++) {
        [void]$seeded.Add([pscustomobject]@{
            event_id=('seed-' + $i.ToString('D6')); occurred_at=(Get-Date).ToString('o'); project_id=[string]$perfAged.Id
            project_revision=1; decision_scope='translation'; action='reviewed'; segment_id=''
            reason_code=''; source_hash=''; target_hash=''; dependency_fingerprint=''
            finding_id=''; finding_revision=0; finding_fingerprint=''; coverage_item_id=''
        })
    }
    $perfAged.ReviewEvents = $seeded.ToArray()
    $agedBefore = @($perfAged.ReviewEvents).Count
    $perfAgedRun = Measure-YakuReplaceMs -Project $perfAged -From 'The Group' -Into 'The Firm'
    $agedGrowth = $(if ($perfFresh.Ms -gt 0) { $perfAgedRun.Ms / $perfFresh.Ms } else { 0 })
    Chk ($perfFresh.Replaced -eq $perfAgedCount -and $perfAgedRun.Replaced -eq $perfAgedCount) '記録の多い少ないに関わらず、同じ行数を置き換えている'
    Chk ($agedGrowth -le 2.0) ('記録が3,000件ある資料でも、同じ置換の所要が跳ね上がらない（' + ('{0:N0}' -f $perfFresh.Ms) + 'ms → ' + ('{0:N0}' -f $perfAgedRun.Ms) + 'ms、' + ('{0:N2}' -f $agedGrowth) + '倍）')
    Chk (@($perfAged.ReviewEvents).Count -eq ($agedBefore + $perfAgedCount)) ('既にあった記録を1件も落とさずに追記する（' + $agedBefore + ' → ' + @($perfAged.ReviewEvents).Count + ' 件）')
    Chk (@($perfAged.ReviewEvents | Select-Object -First 1).event_id -eq @($seeded.ToArray() | Select-Object -First 1).event_id) '先頭の記録は元のまま（追記専用）'
    Remove-YakuCatProject -Id ([string]$perfAged.Id)

    # 速くしたことで、記録の性質を緩めていないこと。
    $perfEvents = @($perfLarge.ReviewEvents)
    Chk (@($perfEvents | Where-Object { [string]$_.action -eq 'search_replaced' }).Count -eq ($perfLargeCount * 2)) 'すべて search_replaced として残る'
    Chk (@($perfEvents | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.source_hash) -or [string]::IsNullOrWhiteSpace([string]$_.target_hash) }).Count -eq 0) 'source_hash / target_hash を全件が持つ'
    Chk ((@($perfEvents | ForEach-Object { [string]$_.event_id } | Sort-Object -Unique)).Count -eq $perfEvents.Count) '同じ記録が二重に入っていない'
    $perfFirstBatchIds = @($perfEvents | Select-Object -First $perfLargeCount | ForEach-Object { [string]$_.event_id })
    Chk (@($perfFirstBatchIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) '1回目の記録が2回目のあとも先頭に残っている（追記専用）'

    # まとめて追記する口と、1件ずつ追記する口が同じ答えを出すこと。
    $batchProbe = New-YakuCatTextProject -Root $root -Text '当社は増えました。' -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $batchProbe -Index 0 -Text 'The Company increased.'
    $probeSegment = @($batchProbe.Segments)[0]
    $probeBefore = @($batchProbe.ReviewEvents).Count
    $singleId = Add-YakuCatHumanDecisionEvent -Project $batchProbe -Scope 'translation' -Action 'search_replaced' -Segment $probeSegment -ReasonCode 'bulk-replace'
    $singleAdded = @($batchProbe.ReviewEvents).Count - $probeBefore
    Chk ($singleAdded -eq 1) ('1件ずつ追記する口は1件だけ足す（実際 ' + $singleAdded + ' 件）')
    # 同じ資料・同じ行に対して、まとめて追記する口を通す。記録だけ元へ戻して比べる。
    $batchProbe.ReviewEvents = @()
    $batch = New-YakuCatHumanDecisionEventBatch -Project $batchProbe
    $batchId = Add-YakuCatHumanDecisionEvent -Project $batchProbe -Scope 'translation' -Action 'search_replaced' -Segment $probeSegment -ReasonCode 'bulk-replace' -Batch $batch
    $batchIdAgain = Add-YakuCatHumanDecisionEvent -Project $batchProbe -Scope 'translation' -Action 'search_replaced' -Segment $probeSegment -ReasonCode 'bulk-replace' -Batch $batch
    Chk (@($batchProbe.ReviewEvents).Count -eq 0) 'まとめる口は、書き戻すまで資料へ触らない'
    $null = Complete-YakuCatHumanDecisionEventBatch -Project $batchProbe -Batch $batch
    Chk ([string]$batchId -eq [string]$singleId) 'まとめて追記しても、1件ずつ追記したときと同じ event_id になる'
    Chk ([string]$batchIdAgain -eq [string]$batchId) '同じ内容を2度足しても同じ event_id を返す'
    Chk (@($batchProbe.ReviewEvents).Count -eq 1) ('同じ内容を2度足しても記録は増えない（冪等。' + @($batchProbe.ReviewEvents).Count + ' 件）')
    Remove-YakuCatProject -Id ([string]$perfSmall.Id)
    Remove-YakuCatProject -Id ([string]$perfLarge.Id)

    # ---------------------------------------------------------------- 画面と入口
    Write-Host '画面と入口' -ForegroundColor Cyan
    Chk ($catHtml -match 'id="cat-search-menu"') '検索と置換の帯が cat.html にある'
    Chk ($catHtml -match 'id="cat-replace-input"' -and $catHtml -match 'id="cat-replace-run"') '置換後の文字列と、押すボタンがある'
    Chk ($catHtml -match 'id="cat-search-case"' -and $catHtml -match 'id="cat-search-regex"') '大文字小文字と正規表現の切替がある'
    $htmlScopes = @([regex]::Matches($catHtml, 'data-cat-search-scope="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Chk ((($htmlScopes) -join ',') -eq 'both,source,target') ('探す場所の選択肢が3つある（' + ($htmlScopes -join ',') + '）')
    $jsScopes = @([regex]::Matches($catJs, "searchScope === '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $scopeOrphans = @($jsScopes | Where-Object { $htmlScopes -notcontains $_ })
    Chk ($scopeOrphans.Count -eq 0) ('cat.js が見る探す場所に、押せないものが無い（余り: ' + ($scopeOrphans -join ',') + '）')
    # 押す前に対象行数を告げる（一括確定・事前翻訳と同じ作法）
    $renderTools = Get-YakuCatJsBlock -Text $catJs -Header '  function renderSearchTools('
    Chk (-not [string]::IsNullOrWhiteSpace($renderTools)) '置換の帯を描く処理を cat.js から取り出せた'
    Chk ($renderTools -match '行の訳文を置き換える') '押すボタンに対象行数を書く'
    Chk ($renderTools -match '確認済みは外れます') '押す前に、確認済みが外れることを書く'
    $runReplaceBlock = Get-YakuCatJsBlock -Text $catJs -Header '  function runReplace('
    Chk ($runReplaceBlock -match 'window\.confirm\(') '押したあと、進めるかどうかを一度たずねる'
    Chk ($runReplaceBlock -match 'replace-estimate') '押したときにサーバへ数え直させる'
    Chk ($runReplaceBlock -match '原文は変わりません') 'たずねる文に「原文は変わらない」と書く'
    # 実機（1380x860）で開いて分かったこと2件。どちらも「名前があるか」では
    # 見つからず、開いて測って初めて出た。消えないように表明で留める。
    Chk ($catHtml -match 'id="cat-search-menu" class="cat-toolbar-menu is-drop-up"') '検索と置換の帯は上へ開く（下へ開くと押すボタンが画面の外に出た）'
    $catCss = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'assets\cat-workspace.css'))
    Chk ($catCss -match '\.cat-toolbar-menu\.is-drop-up > div') '上へ開く指定が cat-workspace.css にある'
    Chk ($catCss -notmatch '#cat-replace-summary' -and $catCss -notmatch '#cat-replace-run') '置換の見た目に ID セレクタを使っていない（詳細度を上げない）'

    Write-Host ''
    if ($script:fail -gt 0) { Write-Host ('Search/replace tests failed: ' + $script:fail) -ForegroundColor Red }
    else { Write-Host 'Search/replace tests passed.' -ForegroundColor Green }
}
finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:fail -gt 0) { exit 1 }
exit 0
