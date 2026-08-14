<#
.SYNOPSIS
  事前翻訳（pre-translate）の回帰テスト。

.DESCRIPTION
  翻訳メモリに完全一致がある行を、Copilot へ送る前に訳文欄へ流し込む。

  市販CAT（memoQ / Trados / Phrase / XTM）はどれも持っている機能だが、
  ここで作る理由はそれではない。翻訳の相手は API ではなく Copilot で使用
  上限があり、CLAUDE.md は「上限超過での再依頼はしない」と定めている。
  **翻訳メモリが1件当たるたびに Copilot 呼び出しが1回減り、その分だけ
  訳せる分量が増える。**

  見るのは5つ。
   (a) 完全一致の行が埋まり、出どころ・状態・未確認が決まった値になること
   (b) Get-YakuCatCopilotUsage の UniqueRemaining が、いくつ減るか
   (c) 翻訳メモリが壊れていても例外を投げず、対象行が空のまま残ること
   (d) 埋めた行が数字の点検に落ちるなら、書き出しが segment-qc-failed で止まること
   (e) 人が直した行を踏まないこと・あいまい一致は使わないこと

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9172TmPretranslate.ps1
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

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-tmpre-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

function Add-TestTm {
    param(
        [string]$Source,
        [string]$Target,
        [string]$Path,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$FileName = 'FY2025-results.xlsx',
        [string]$Location = 'Sheet1, A1'
    )
    $segmentId = (Get-YakuTranslationMemoryHash -Text ([string]$Source)).Substring(0,32)
    return (Add-YakuTranslationMemoryEntry -Source $Source -Target $Target -Path $Path -Direction $Direction `
        -OriginProjectId '11111111111111111111111111111111' -OriginFileName $FileName `
        -OriginSegmentId $segmentId -OriginLocation $Location -OriginPage 3 -ReviewRevision 7)
}

function Get-YakuServerRouteBody {
    <#
      Server.ps1 の switch から、ルート1本ぶんの**本体そのもの**を取り出す。

      なぜ写経しないか。ここを試験側へ写すと、Server.ps1 を直したときに
      写しだけが古いまま残る。そうなると「サーバを走らせた」と言いながら
      実際には試験の中の別物を走らせることになり、字面の門へ逆戻りする
      （2026-08-15 の批評: サーバの rows を 0 に固定しても 69 本すべて緑だった）。

      構文木で取り出す。取り出せなければ $null を返し、呼び出し側は**赤にする**。
      黙って飛ばすと「測っていないのに緑」に戻る。
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
       $project / $settings / $expectedRevision / $Context は呼び出し側が置く。 #>
    param([Parameter(Mandatory=$true)][string]$BodyText)
    $script:YakuRouteResponseText = ''
    . ([scriptblock]::Create($BodyText))
    return [string]$script:YakuRouteResponseText
}

$settings = Read-YakuSettings -Root $root
# ルート本体は $script:YakuRoot を読む。Server.ps1 は読み込まないので、
# 起動時に入る値をここで入れておく。
$script:YakuRoot = $root

try {
    # ------------------------------------------------------------------ (a)
    Write-Host '(a) 完全一致の行が埋まる' -ForegroundColor Cyan
    $tmA = Join-Path $tmp 'tm-a.jsonl'
    $null = Add-TestTm -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tmA
    $textA = @('当社は電動化を進めます。','この文は翻訳メモリに載っていません。') -join "`n"
    $pa = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    $segsA = @($pa.Segments)
    Chk ($segsA.Count -eq 2) '2行に分かれる'
    Chk ([string]$segsA[0].Translation -eq '' -and [string]$segsA[1].Translation -eq '') '事前翻訳の前はどちらも空'

    $ra = Invoke-YakuCatTranslationMemoryPass -Project $pa -Path $tmA
    $segsA = @($pa.Segments)
    Chk ([int]$ra.Applied -eq 1) ('完全一致の1行だけを埋める（実際 ' + [int]$ra.Applied + ' 行）')
    Chk ([string]$segsA[0].Translation -eq 'We will advance electrification.') '翻訳メモリの訳がそのまま入る'
    Chk ([string]$segsA[0].Origin -eq 'translation-memory') 'Origin が translation-memory'
    Chk ([string]$segsA[0].State -eq 'machine_draft') 'State が machine_draft'
    Chk (-not [bool]$segsA[0].Confirmed) '埋めた行を確認済みにしない'
    Chk ([string]$segsA[0].QcStatus -eq 'not_run') '点検はまだ走っていない扱いにする'
    Chk ([string]$segsA[0].MaskedTranslation -eq '') 'マスク後の訳文は持ち込まない'
    Chk ([string]$segsA[1].Translation -eq '') '一致しない行は空のまま残す'
    Chk ([string]$segsA[0].ReferenceUsage.kind -eq 'memory' -and [string]$segsA[0].ReferenceUsage.action -eq 'inserted') 'どのTMから来たかを行に残す'
    Chk ([string]$segsA[0].ReferenceUsage.source_name -eq 'FY2025-results.xlsx') '出典の資料名を残す'

    # 画面へ渡す形にも出る。ここが崩れると利用者からは「何も起きない」に見える。
    $jsonA = (ConvertTo-YakuCatProjectJson -Project $pa) | ConvertFrom-Json
    $rowsA = @($jsonA.segments)
    Chk ([string]$rowsA[0].origin -eq 'translation-memory' -and [string]$rowsA[0].state -eq 'machine_draft' -and -not [bool]$rowsA[0].confirmed) '画面へ渡す形にも同じ状態で出る'

    Write-Host '(a2) もう一度押しても二重に入れない' -ForegroundColor Cyan
    $raAgain = Invoke-YakuCatTranslationMemoryPass -Project $pa -Path $tmA
    Chk ([int]$raAgain.Applied -eq 0) '埋め終わった行は対象にしない'
    Chk ([string]@($pa.Segments)[0].Translation -eq 'We will advance electrification.') '2回目でも訳文は変わらない'
    Remove-YakuCatProject -Id ([string]$pa.Id)

    Write-Host '(a3) 出典を書けなくても訳文は入る' -ForegroundColor Cyan
    # 出典（reference_usage）は付け足しであって、訳を入れる条件ではない。
    # 古い形式のTM行など ReferenceId が無いものでも埋まらないと困る。
    # 画面の札はそのとき originLabel('translation-memory') に落ちる。
    # 差し替えて戻すときは ScriptBlock を「値として」先に取り出す。
    # Get-Item Function:\X は生きた handle を返すので、差し替えたあとに
    # そのまま Set-Item へ渡しても**戻らない**（実測 2026-08-15。戻せて
    # いないことは、素の経路では緑のままなので気づけない）。
    $originalUsageRecordBlock = (Get-Item Function:\Set-YakuCatSegmentReferenceUsageRecord).ScriptBlock
    $pa3 = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    try {
        function Set-YakuCatSegmentReferenceUsageRecord { throw 'PRETRANSLATE_TEST_PROVENANCE_STUB' }
        $ra3 = Invoke-YakuCatTranslationMemoryPass -Project $pa3 -Path $tmA
    } finally { Set-Item -LiteralPath Function:\Set-YakuCatSegmentReferenceUsageRecord -Value $originalUsageRecordBlock }
    $segsA3 = @($pa3.Segments)
    Chk ([int]$ra3.Applied -eq 1) '出典が書けなくても訳文は入る'
    Chk ([string]$segsA3[0].Translation -eq 'We will advance electrification.') '訳文の中身は同じ'
    Chk ([string]$segsA3[0].Origin -eq 'translation-memory' -and -not [bool]$segsA3[0].Confirmed) '出どころと未確認は変わらない'
    Remove-YakuCatProject -Id ([string]$pa3.Id)

    # ここから先の検査が空振りしていないこと（この試験自身の点検）
    Chk ((Get-Item Function:\Set-YakuCatSegmentReferenceUsageRecord).ScriptBlock.ToString() -notmatch 'PRETRANSLATE_TEST_PROVENANCE_STUB') '差し替えた関数を元へ戻せている'
    $pa4 = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    $null = Invoke-YakuCatTranslationMemoryPass -Project $pa4 -Path $tmA
    Chk ([string]@($pa4.Segments)[0].ReferenceUsage.kind -eq 'memory') '元へ戻したあとは出典がまた残る'
    Remove-YakuCatProject -Id ([string]$pa4.Id)

    # ------------------------------------------------------------------ (b)
    Write-Host '(b) UniqueRemaining がいくつ減るか' -ForegroundColor Cyan
    $tmB = Join-Path $tmp 'tm-b.jsonl'
    $null = Add-TestTm -Source '当第1四半期の売上高は122億円でした。' -Target 'First-quarter revenue was 12.2 billion yen.' -Path $tmB
    $null = Add-TestTm -Source '固定費を圧縮しました。' -Target 'We reduced fixed costs.' -Path $tmB

    # まず全部ちがう原文で見る。ここでは「埋めた行数」と「原文の種類数」が同じ。
    $textB = @(
        '当第1四半期の売上高は122億円でした。',
        '固定費を圧縮しました。',
        'この文は翻訳メモリに載っていません。'
    ) -join "`n"
    $pb = New-YakuCatTextProject -Root $root -Text $textB -Settings $settings -Direction 'to_en'
    $beforeB = Get-YakuCatCopilotUsage -Root $root -Project $pb -Settings $settings
    Chk ([int]$beforeB.UniqueRemaining -eq 3) ('事前翻訳の前は3件（実際 ' + [int]$beforeB.UniqueRemaining + '）')
    $rb = Invoke-YakuCatTranslationMemoryPass -Project $pb -Path $tmB
    $afterB = Get-YakuCatCopilotUsage -Root $root -Project $pb -Settings $settings
    Chk ([int]$rb.Applied -eq 2 -and [int]$rb.UniqueApplied -eq 2) '完全一致の2行を埋める'
    Chk ([int]$afterB.UniqueRemaining -eq 1) ('事前翻訳の後は1件（実際 ' + [int]$afterB.UniqueRemaining + '）')
    Chk (([int]$beforeB.UniqueRemaining - [int]$afterB.UniqueRemaining) -eq 2) 'UniqueRemaining はちょうど2件減る'
    Chk (([int]$beforeB.UniqueRemaining - [int]$afterB.UniqueRemaining) -eq [int]$rb.UniqueApplied) '減った件数と、埋めた原文の種類数が一致する'
    Chk ([int]$afterB.EstimatedCalls -le [int]$beforeB.EstimatedCalls) 'Copilot 送信回数の見積りが増えない'
    Remove-YakuCatProject -Id ([string]$pb.Id)

    # 同じ原文が複数行あるとき。Copilot は重複を除いた原文の数で送るので、
    # 減る件数は「埋めた行数」ではなく「原文の種類数」に一致する。
    $textBr = @(
        '当第1四半期の売上高は122億円でした。',
        'この文は翻訳メモリに載っていません。',
        '当第1四半期の売上高は122億円でした。',
        '固定費を圧縮しました。',
        'この文は翻訳メモリに載っていません。'
    ) -join "`n"
    $pbr = New-YakuCatTextProject -Root $root -Text $textBr -Settings $settings -Direction 'to_en'
    $beforeBr = Get-YakuCatCopilotUsage -Root $root -Project $pbr -Settings $settings
    Chk ([int]$beforeBr.UniqueRemaining -eq 3) ('重複を除いて3件と数える（実際 ' + [int]$beforeBr.UniqueRemaining + '）')
    $rbr = Invoke-YakuCatTranslationMemoryPass -Project $pbr -Path $tmB
    $afterBr = Get-YakuCatCopilotUsage -Root $root -Project $pbr -Settings $settings
    Chk ([int]$rbr.Applied -eq 3) ('反復も含めて3行を埋める（実際 ' + [int]$rbr.Applied + ' 行）')
    Chk ([int]$rbr.UniqueApplied -eq 2) '埋めた原文の種類は2件'
    Chk (([int]$beforeBr.UniqueRemaining - [int]$afterBr.UniqueRemaining) -eq 2) 'UniqueRemaining は行数の3ではなく種類数の2だけ減る'
    Chk ([int]$afterBr.UniqueRemaining -eq 1) '残るのは翻訳メモリに無い1種類だけ'
    Remove-YakuCatProject -Id ([string]$pbr.Id)

    # 数える側（押す前の表示）も同じ対象を見ている。
    # 突くのは Get-YakuCatTranslationMemoryPretranslatePlan そのもの。サーバの
    # tm-pretranslate-estimate がこれを直に呼ぶからである。かつてここは
    # Measure-YakuCatTranslationMemoryCandidates という包みを突いていたが、
    # 本番の呼び出し元が0件だったため、サーバ側で行数を0に固定しても緑のままだった。
    # 押す前と実際がずれないことは、下の「サーバの口」でも応答どうしで突き合わせる。
    $pbc = New-YakuCatTextProject -Root $root -Text $textBr -Settings $settings -Direction 'to_en'
    $planBc = Get-YakuCatTranslationMemoryPretranslatePlan -Project $pbc -Path $tmB
    Chk (@($planBc.Rows).Count -eq 3) ('押す前に告げる行数が、実際に埋まる行数と一致する（実際 ' + @($planBc.Rows).Count + ' 行）')
    Chk ([int]$planBc.UniqueTexts -eq 2) '押す前に告げる原文の種類数も、埋めた種類数と一致する'
    Chk ([string]@($pbc.Segments)[0].Translation -eq '') '数えるだけでは埋めない'
    Remove-YakuCatProject -Id ([string]$pbc.Id)

    # ------------------------------------------------------------------ (c)
    Write-Host '(c) 翻訳メモリが壊れていても止めない' -ForegroundColor Cyan
    # c1: 中身が壊れている（JSON として読めない行だけ）
    $tmBroken = Join-Path $tmp 'tm-broken.jsonl'
    [IO.File]::WriteAllText($tmBroken, "{壊れています" + "`n" + "not json at all" + "`n", (New-Object Text.UTF8Encoding($false)))
    $pc1 = New-YakuCatTextProject -Root $root -Text $textB -Settings $settings -Direction 'to_en'
    $beforeC1 = Get-YakuCatCopilotUsage -Root $root -Project $pc1 -Settings $settings
    $threwC1 = $false
    $rc1 = $null
    try { $rc1 = Invoke-YakuCatTranslationMemoryPass -Project $pc1 -Path $tmBroken } catch { $threwC1 = $true }
    $afterC1 = Get-YakuCatCopilotUsage -Root $root -Project $pc1 -Settings $settings
    Chk (-not $threwC1) '壊れた翻訳メモリでも例外を投げない'
    Chk ($null -ne $rc1 -and [int]$rc1.Applied -eq 0) '壊れた翻訳メモリからは1行も埋めない'
    Chk (@($pc1.Segments | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count -eq 3) '対象行は空のまま残る'
    Chk ([int]$afterC1.UniqueRemaining -eq [int]$beforeC1.UniqueRemaining -and [int]$afterC1.UniqueRemaining -eq 3) '3件とも Copilot 送信対象に残る'
    Remove-YakuCatProject -Id ([string]$pc1.Id)

    # c2: ファイルそのものが読めない（他のプロセスが掴んでいる）
    $tmLocked = Join-Path $tmp 'tm-locked.jsonl'
    $null = Add-TestTm -Source '当第1四半期の売上高は122億円でした。' -Target 'First-quarter revenue was 12.2 billion yen.' -Path $tmLocked
    Clear-YakuTranslationMemoryCache
    $pc2 = New-YakuCatTextProject -Root $root -Text $textB -Settings $settings -Direction 'to_en'
    $threwC2 = $false
    $rc2 = $null
    $lock = [IO.File]::Open($tmLocked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        # まず「本当に読めない」ことを確かめる。読めてしまうなら、この検査は
        # 何も見張っていない（門は発火することを確かめて初めて門になる）。
        $reallyLocked = $false
        try { $null = [IO.File]::ReadAllBytes($tmLocked) } catch { $reallyLocked = $true }
        Chk $reallyLocked '掴んだファイルは実際に読めない（この検査が空振りでないこと）'
        try { $rc2 = Invoke-YakuCatTranslationMemoryPass -Project $pc2 -Path $tmLocked } catch { $threwC2 = $true }
    } finally { $lock.Dispose() }
    $afterC2 = Get-YakuCatCopilotUsage -Root $root -Project $pc2 -Settings $settings
    Chk (-not $threwC2) '読めない翻訳メモリでも例外を投げない'
    Chk ($null -ne $rc2 -and [int]$rc2.Applied -eq 0) '読めないときは1行も埋めない'
    Chk ($null -ne $rc2 -and [bool]$rc2.MemoryUnavailable) '読めなかったことを黙って成功にしない'
    Chk ([int]$afterC2.UniqueRemaining -eq 3) '対象行は従来どおり Copilot 送信対象に残る'
    # 掴むのをやめれば、同じ作業がそのまま埋まる（一時的な失敗で壊れない）
    Clear-YakuTranslationMemoryCache
    $rc2b = Invoke-YakuCatTranslationMemoryPass -Project $pc2 -Path $tmLocked
    Chk ([int]$rc2b.Applied -eq 1) '読めるようになれば、同じ作業がそのまま埋まる'
    Remove-YakuCatProject -Id ([string]$pc2.Id)

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) 数字の点検に落ちる訳は書き出しを止める' -ForegroundColor Cyan
    $tmD = Join-Path $tmp 'tm-d.jsonl'
    $null = Add-TestTm -Source '売上高は100百万円でした。' -Target 'Revenue was 999 million yen.' -Path $tmD
    $pd = New-YakuCatTextProject -Root $root -Text '売上高は100百万円でした。' -Settings $settings -Direction 'to_en'
    $rd = Invoke-YakuCatTranslationMemoryPass -Project $pd -Path $tmD
    $segD = @($pd.Segments)[0]
    Chk ([int]$rd.Applied -eq 1) '数字が合わない訳でも、埋めること自体は行う'
    Chk (-not [bool]$segD.Confirmed -and [string]$segD.State -eq 'machine_draft') '埋めた時点では確認済みにしない'
    $eligibility = Get-YakuCatOutputEligibility -Project $pd
    Chk (-not [bool]$eligibility.TranslationListEligible) '数字が抜けた訳のままでは書き出せない'
    Chk (@($eligibility.Reasons) -contains 'segment-qc-failed') '止まる理由が segment-qc-failed である'
    Chk ([int]$eligibility.UnconfirmedCount -eq 1) '未確認として数える'
    # 確定しようとしても点検で止まる（埋めたことが確認の代わりにならない）
    $confirmBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $pd -Index 0 } catch { $confirmBlocked = ($_.Exception.Message -match 'CAT_REVIEW_QC_FAILED') }
    Chk $confirmBlocked '確定しようとしても数字の点検で止まる'
    Remove-YakuCatProject -Id ([string]$pd.Id)

    # 数字が合っている訳なら、これまでどおり書き出せる
    $tmD2 = Join-Path $tmp 'tm-d2.jsonl'
    $null = Add-TestTm -Source '売上高は100百万円でした。' -Target 'Revenue was 100 million yen.' -Path $tmD2
    $pd2 = New-YakuCatTextProject -Root $root -Text '売上高は100百万円でした。' -Settings $settings -Direction 'to_en'
    $null = Invoke-YakuCatTranslationMemoryPass -Project $pd2 -Path $tmD2
    $eligibility2 = Get-YakuCatOutputEligibility -Project $pd2
    Chk ([bool]$eligibility2.TranslationListEligible) '数字の合う訳なら未確認でも書き出せる（従来どおり）'
    Remove-YakuCatProject -Id ([string]$pd2.Id)

    # ------------------------------------------------------------------ (e)
    Write-Host '(e) 人の直しを踏まない・あいまい一致は使わない' -ForegroundColor Cyan
    $pe = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    $null = Set-YakuCatSegmentTranslation -Project $pe -Index 0 -Text 'My own wording.'
    $re = Invoke-YakuCatTranslationMemoryPass -Project $pe -Path $tmA
    $segsE = @($pe.Segments)
    Chk ([int]$re.Applied -eq 0) '人が直した行は対象にしない'
    Chk ([string]$segsE[0].Translation -eq 'My own wording.') '人が書いた訳文を上書きしない'
    Chk ([string]$segsE[0].Origin -eq 'manual' -and [string]$segsE[0].State -eq 'human_edited') '人が直した状態のまま残す'
    Remove-YakuCatProject -Id ([string]$pe.Id)

    # 上の (e) は、Get-YakuCatTranslationMemoryPretranslatePlan の2つの門
    #   (1) 訳文が空でない行は対象にしない
    #   (2) Origin=manual / State=human_edited の行は対象にしない
    # のどちらか片方だけでも拾える形になっている。片方を外しても赤にならない
    # なら、その門は見張られていない（2026-08-15 の批評が実測した）。
    # ここから2本は、門を1つずつしか通れない場合を作る。

    # (e2) 訳文が入っている Copilot の下書き。Origin は manual ではないので、
    #      これを止めているのは「訳文が空でない」の門ひとつだけである。
    $pe2 = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    $segsE2 = @($pe2.Segments)
    $segsE2[0].Translation = 'Draft that Copilot wrote.'
    $segsE2[0].Origin = 'copilot'
    $segsE2[0] | Add-Member -NotePropertyName State -NotePropertyValue 'machine_draft' -Force
    $planE2 = Get-YakuCatTranslationMemoryPretranslatePlan -Project $pe2 -Path $tmA
    Chk (@($planE2.Rows).Count -eq 0) ('訳文が入っている下書きは対象にしない（実際 ' + @($planE2.Rows).Count + ' 行）')
    $re2 = Invoke-YakuCatTranslationMemoryPass -Project $pe2 -Path $tmA
    Chk ([int]$re2.Applied -eq 0) '訳文が入っている下書きを翻訳メモリで上書きしない'
    Chk ([string]@($pe2.Segments)[0].Translation -eq 'Draft that Copilot wrote.') '下書きの中身はそのまま残る'
    Remove-YakuCatProject -Id ([string]$pe2.Id)

    # (e3) 訳文が空で、人が直した印だけが残っている行。訳文が空なので
    #      「訳文が空でない」の門は通ってしまう。止めているのは
    #      Origin/State を見る門ひとつだけである。
    #      突く先は計画そのもの。サーバの押す前の口（tm-pretranslate-estimate）は
    #      Initialize を通さずにこの計画を直に呼ぶので、ここが実経路である。
    $pe3 = New-YakuCatTextProject -Root $root -Text $textA -Settings $settings -Direction 'to_en'
    $segsE3 = @($pe3.Segments)
    $segsE3[0].Origin = 'manual'
    $segsE3[0] | Add-Member -NotePropertyName State -NotePropertyValue 'human_edited' -Force
    Chk ([string]::IsNullOrWhiteSpace([string]$segsE3[0].Translation)) '（前提）この行の訳文は空である'
    $planE3 = Get-YakuCatTranslationMemoryPretranslatePlan -Project $pe3 -Path $tmA
    Chk (@($planE3.Rows).Count -eq 0) ('人が直した印のある行は、訳文が空でも対象にしない（実際 ' + @($planE3.Rows).Count + ' 行）')
    Remove-YakuCatProject -Id ([string]$pe3.Id)

    # (e4) 過去訳の対応確認（Source='align'）では1行も埋めない。
    #      あの資料の行は「この日本語に、この英語が対応していた」という記録で、
    #      訳す対象ではない。対応が取れなかった行は片側が空のまま作られるので、
    #      そこへ翻訳メモリの訳を入れると、実在しなかった対応を人が確認したことに
    #      なってしまう。画面はボタンを隠しているが、隠すのは目に見える入口だけである。
    $pe4 = New-YakuCatProjectFromPairs -Pairs @([pscustomobject]@{ JaText = '当社は電動化を進めます。'; EnText = '' }) `
        -Direction 'to_en' -Settings $settings
    Chk ([string]$pe4.Source -eq 'align') '（前提）対応確認の資料として作られている'
    Chk ([string]::IsNullOrWhiteSpace([string]@($pe4.Segments)[0].Translation)) '（前提）対応の取れなかった行は片側が空である'
    $planE4 = Get-YakuCatTranslationMemoryPretranslatePlan -Project $pe4 -Path $tmA
    Chk (@($planE4.Rows).Count -eq 0) ('対応確認の資料では1行も対象にしない（実際 ' + @($planE4.Rows).Count + ' 行）')
    $re4 = Invoke-YakuCatTranslationMemoryPass -Project $pe4 -Path $tmA
    Chk ([int]$re4.Applied -eq 0) '対応確認の資料へは翻訳メモリを流し込まない'
    Chk ([string]::IsNullOrWhiteSpace([string]@($pe4.Segments)[0].Translation)) '対応の取れなかった行は空のまま残る'
    Remove-YakuCatProject -Id ([string]$pe4.Id)

    # あいまい一致（今回の対象外）。似ているだけの原文には入れない。
    $pf = New-YakuCatTextProject -Root $root -Text '当社は電動化を進めています。' -Settings $settings -Direction 'to_en'
    $fuzzyHits = @(Find-YakuTranslationMemory -Text '当社は電動化を進めています。' -Path $tmA)
    Chk ($fuzzyHits.Count -ge 1 -and -not [bool]$fuzzyHits[0].Exact) 'あいまい一致としては引ける（前提の確認）'
    $rf = Invoke-YakuCatTranslationMemoryPass -Project $pf -Path $tmA
    Chk ([int]$rf.Applied -eq 0) 'あいまい一致は流し込まない'
    Chk ([string]@($pf.Segments)[0].Translation -eq '') '似ているだけの行は空のまま残す'
    Remove-YakuCatProject -Id ([string]$pf.Id)

    # 「完全一致」は原文そのままの一致ではない。ConvertTo-YakuTranslationMemoryKey で
    # 空白を落とし、英数字を半角へ畳み、小文字化したあとの一致である。候補ペインは
    # 人が選ぶので差が出なかったが、事前翻訳は人が見ないまま流し込むので、
    # この定義を意図として固定しておく（緩めるとあいまい一致が混ざる）。
    $tmN = Join-Path $tmp 'tm-normalized.jsonl'
    $null = Add-TestTm -Source 'Net Sales increased by 10%.' -Target '純売上高は10%増加しました。' -Path $tmN -Direction 'to_jp'
    $pn = New-YakuCatTextProject -Root $root -Text 'NET   SALES increased by 10%.' -Settings $settings -Direction 'to_jp'
    $rn = Invoke-YakuCatTranslationMemoryPass -Project $pn -Path $tmN
    Chk ([int]$rn.Applied -eq 1) '空白と大小だけが違う原文は完全一致として埋まる（正規化後の一致）'
    Chk ([string]@($pn.Segments)[0].Translation -eq '純売上高は10%増加しました。') 'そのときも訳文はTMのまま入る'
    Remove-YakuCatProject -Id ([string]$pn.Id)

    # 数字は正規化で落とさない。落とすと数値の取り違えが自動で流れ込む。
    $tmN2 = Join-Path $tmp 'tm-normalized2.jsonl'
    $null = Add-TestTm -Source '売上高は200億円でした。' -Target 'Revenue was 20.0 billion yen.' -Path $tmN2
    $pn2 = New-YakuCatTextProject -Root $root -Text '売上高は100億円でした。' -Settings $settings -Direction 'to_en'
    $rn2 = Invoke-YakuCatTranslationMemoryPass -Project $pn2 -Path $tmN2
    Chk ([int]$rn2.Applied -eq 0) '数字だけが違う原文は完全一致にしない'
    Remove-YakuCatProject -Id ([string]$pn2.Id)

    # 方向が違う翻訳メモリは引かない
    $pg = New-YakuCatTextProject -Root $root -Text '当社は電動化を進めます。' -Settings $settings -Direction 'to_jp'
    $rg = Invoke-YakuCatTranslationMemoryPass -Project $pg -Path $tmA
    Chk ([int]$rg.Applied -eq 0) '方向が違う翻訳メモリからは入れない'
    Remove-YakuCatProject -Id ([string]$pg.Id)

    # ------------------------------------------------------- 速さ（見積りでなく実測）
    Write-Host '速さ' -ForegroundColor Cyan
    $tmBig = Join-Path $tmp 'tm-big.jsonl'
    # 1行＝1文にする。句点で分かれると原文が変わり、完全一致しない。
    for ($i = 0; $i -lt 123; $i++) {
        $null = Add-TestTm -Source ('過去に確認した第' + $i + '文の売上高は' + $i + '億円でした。') `
            -Target ('Stored sentence ' + $i + ' revenue was ' + $i + ' hundred million yen.') -Path $tmBig
    }
    $bigLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 200; $i++) {
        if ($i % 2 -eq 0) { [void]$bigLines.Add('過去に確認した第' + [int]($i / 2) + '文の売上高は' + [int]($i / 2) + '億円でした。') }
        else { [void]$bigLines.Add('まだ訳していない第' + $i + '文の内容はここには残っていません。') }
    }
    $pbig = New-YakuCatTextProject -Root $root -Text (($bigLines.ToArray()) -join "`n") -Settings $settings -Direction 'to_en'
    Clear-YakuTranslationMemoryCache
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rbig = Invoke-YakuCatTranslationMemoryPass -Project $pbig -Path $tmBig
    $sw.Stop()
    $elapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    Write-Host ('  measured: TM 123件 / 行 ' + @($pbig.Segments).Count + ' 行 → ' + $elapsedMs + 'ms、埋めた行 ' + [int]$rbig.Applied) -ForegroundColor DarkGray
    Chk ([int]$rbig.Applied -eq 100) ('200行のうち完全一致の100行を埋める（実際 ' + [int]$rbig.Applied + ' 行）')
    # 上限は実測（開発機で約1.3秒。うち翻訳メモリを引く費用が約1.0秒）の約4倍。
    # 行ごとに Project 全体を初期化し直す書き方だと 11.0 秒かかり、ここで赤になる
    # （2026-08-14 に実際に踏んだ。Set-YakuCatSegmentReferenceUsageRecord の由来）。
    Chk ($elapsedMs -lt 5000) ('全行に翻訳メモリを引いても5秒未満（実測 ' + $elapsedMs + 'ms）')
    Remove-YakuCatProject -Id ([string]$pbig.Id)

    # 上の門は「資料の行数」しか動かしていない。実際に育つのは**翻訳メモリの
    # 件数**のほうで、そこに上限は無い。件数の軸を見ていなかったため、完全一致
    # しか要らないのに全件へ3-gram Dice を回す作りが素通りしていた（実測:
    # TM 3,000件・400行で 見積り25.7秒＋反映24.4秒。Server.ps1:3702 の待ち受けは
    # GetContext → Invoke-YakuRoute の直列1本なので、その間**アプリ全体が止まる**）。
    # ここでは行数を固定して、翻訳メモリの件数だけを 123 → 1,000 へ増やす。
    Write-Host '速さ（翻訳メモリの件数を増やす）' -ForegroundColor Cyan
    $tmMany = Join-Path $tmp 'tm-many.jsonl'
    for ($i = 0; $i -lt 1000; $i++) {
        $null = Add-TestTm -Source ('前期に確認した第' + $i + '文の売上高は' + $i + '億円でした。') `
            -Target ('Prior sentence ' + $i + ' revenue was ' + $i + ' hundred million yen.') -Path $tmMany
    }
    $manyLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 400; $i++) {
        if ($i % 2 -eq 0) { [void]$manyLines.Add('前期に確認した第' + [int]($i / 2) + '文の売上高は' + [int]($i / 2) + '億円でした。') }
        else { [void]$manyLines.Add('まだ訳していない第' + $i + '文の内容はここには残っていません。') }
    }
    $pmany = New-YakuCatTextProject -Root $root -Text (($manyLines.ToArray()) -join "`n") -Settings $settings -Direction 'to_en'
    Clear-YakuTranslationMemoryCache
    $swPlan = [Diagnostics.Stopwatch]::StartNew()
    $planMany = Get-YakuCatTranslationMemoryPretranslatePlan -Project $pmany -Path $tmMany
    $swPlan.Stop()
    $swPass = [Diagnostics.Stopwatch]::StartNew()
    $rmany = Invoke-YakuCatTranslationMemoryPass -Project $pmany -Path $tmMany
    $swPass.Stop()
    $manyMs = [int]($swPlan.Elapsed.TotalMilliseconds + $swPass.Elapsed.TotalMilliseconds)
    Write-Host ('  measured: TM 1,000件 / 400行 → 見積り ' + [int]$swPlan.Elapsed.TotalMilliseconds +
        'ms ＋ 反映 ' + [int]$swPass.Elapsed.TotalMilliseconds + 'ms = ' + $manyMs + 'ms') -ForegroundColor DarkGray
    Chk (@($planMany.Rows).Count -eq 200 -and [int]$rmany.Applied -eq 200) ('400行のうち完全一致の200行を埋める（計画 ' +
        @($planMany.Rows).Count + ' 行 / 実際 ' + [int]$rmany.Applied + ' 行）')
    # 上限は索引を使った実測（開発機で 見積り1,612ms＋反映1,590ms＝3,202ms）の約2.5倍。
    # 索引を外して全件のあいまい照合へ戻すと 18,038ms かかり、ここで赤になる
    # （2026-08-15 に実際に外して確かめた）。
    Chk ($manyMs -lt 8000) ('翻訳メモリが1,000件でも、押下1回ぶんが8秒未満（実測 ' + $manyMs + 'ms）')
    Remove-YakuCatProject -Id ([string]$pmany.Id)

    # ------------------------------------------------------------ 画面と入口
    Write-Host '画面と入口' -ForegroundColor Cyan
    $serverSrc = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
    $catJs = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'cat.js'))
    $catHtml = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'cat.html'))
    Chk ($serverSrc -match "'tm-pretranslate'") 'サーバに事前翻訳の入口がある'
    Chk ($serverSrc -match "'tm-pretranslate-estimate'") '押す前に行数を数える入口がある'
    Chk ($serverSrc -match "Invoke-YakuCatTranslationMemoryPass") 'サーバが事前翻訳の本体を呼ぶ'
    Chk ($serverSrc -match "'tm-pretranslate'[^\r\n]*\)" -or $serverSrc -match "'confirm-bulk','tm-pretranslate'" -or $serverSrc -match "revisionActions = @\([^\r\n]*'tm-pretranslate'") '事前翻訳を revision 検査の対象にする'
    Chk ($catJs -match 'tm-pretranslate-estimate') '画面が押す前に対象行数を問い合わせる'
    Chk ($catJs -match 'window\.confirm' -and $catJs -match 'tmPretranslate') '押す前に確認を出す'
    Chk ($catJs -match "origin === 'translation-memory'") '出どころの札に翻訳メモリがある'
    Chk ($catHtml -match 'id="cat-tm-pretranslate"') '画面に押せるボタンがある'

    # 押せるボタンがあることと、押して機能が動くことは別である。上の2本は
    # 「cat.html に id がある」「cat.js に tmPretranslate という名前がある」しか
    # 見ておらず、**その2つがつながっているか**を誰も見ていなかった。配線の1行
    #   if (button.id === 'cat-tm-pretranslate') return tmPretranslate();
    # を if (false) へ変えるとボタンから機能へ到達できなくなるが、それでも
    # 116本すべてが緑・exit=0 のままだった（2026-08-15 の批評が実測）。
    # 文字列 'cat-tm-pretranslate' の出現数を数えるだけでは足りない。同じ文字列は
    # cat.html の id 宣言にも、押下中の握り潰し（cat.js の busy 判定）にも出るので、
    # 配線が消えても数は減らない。**押されたときにその関数へ分岐する行**を見る。
    $catJsLines = @($catJs -split "`r`n|`n|`r")
    $tmCallLines = @($catJsLines | Where-Object { $_ -cmatch 'tmPretranslate\s*\(' -and $_ -cnotmatch 'function\s+tmPretranslate' })
    Chk ($tmCallLines.Count -ge 1) ('cat.js に tmPretranslate を呼ぶ行がある（' + $tmCallLines.Count + ' 行）')
    $tmWiredId = ''
    $tmWireMatch = [regex]::Match((($tmCallLines) -join "`n"), "button\.id\s*===\s*'([^']+)'\s*\)\s*\{?\s*return\s+tmPretranslate\s*\(")
    if ($tmWireMatch.Success) { $tmWiredId = [string]$tmWireMatch.Groups[1].Value }
    Chk (-not [string]::IsNullOrWhiteSpace($tmWiredId)) '押されたボタンの id を見て tmPretranslate へ分岐する行がある（画面から機能へ到達できる）'
    # 分岐が見ている id を、cat.html のボタンに突き合わせる。どちらか一方を
    # 改名すれば、ここで食い違いとして出る。
    Chk (($tmWiredId -ne '') -and ($catHtml -match ('id="' + [regex]::Escape($tmWiredId) + '"'))) ('画面のボタンと cat.js の分岐が同じ id でつながっている（' +
        $(if ([string]::IsNullOrWhiteSpace($tmWiredId)) { '分岐が見つからない' } else { $tmWiredId }) + '）')

    # キー一覧（cat.html）と実装をずらさない。事前翻訳にキーは割り当てない。
    $buttonHtml = ''
    $m = [regex]::Match($catHtml, '<button[^>]*id="cat-tm-pretranslate"[^>]*>')
    if ($m.Success) { $buttonHtml = $m.Value }
    Chk ($buttonHtml -notmatch 'aria-keyshortcuts') '事前翻訳にキーを割り当てない（キー一覧と食い違わせない）'
    $keyList = ''
    $km = [regex]::Match($catHtml, '<details class="cat-key-help">.*?</details>', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($km.Success) { $keyList = $km.Value }
    Chk ($keyList -match 'F7' -and $keyList -match 'F8' -and $keyList -match 'Enter') 'キー一覧は従来どおり残っている'

    # ------------------------------------------------------------ サーバの口
    Write-Host 'サーバの口（ルート本体を Server.ps1 から取り出して走らせる）' -ForegroundColor Cyan
    # ここより上の検査は、どれもサーバの口を通らない。「画面と入口」も本文を
    # 字面で見るだけである。そのため 2026-08-15 の批評は、Server.ps1 の
    #   rows = [int]$planRows  →  rows = [int]0
    # に変えて機能を完全に殺しても、69本すべてが緑・exit=0 のままであることを
    # 実測した。tm_pretranslate_filled / tm_pretranslate_requests_saved の改名も、
    # unique_texts の0固定も同じだった。字面を見る門は、門ではない。
    #
    # そこで Server.ps1 から**ルート本体そのもの**を構文木で取り出し、同じ順序で
    # 走らせて、出た応答の値を計算して比べる。写経はしない（写しだけが古くなる）。
    $serverFile = Join-Path (Join-Path $root 'src') 'Server.ps1'
    $rtEstimateRoute = Get-YakuServerRouteBody -ServerPath $serverFile -Route 'tm-pretranslate-estimate'
    $rtApplyRoute = Get-YakuServerRouteBody -ServerPath $serverFile -Route 'tm-pretranslate'
    Chk ($null -ne $rtEstimateRoute) ('見積りのルート本体を Server.ps1 から取り出せた' +
        $(if ($null -ne $rtEstimateRoute) { '（' + $rtEstimateRoute.StartLine + '-' + $rtEstimateRoute.EndLine + ' 行）' } else { '' }))
    Chk ($null -ne $rtApplyRoute) ('事前翻訳のルート本体を Server.ps1 から取り出せた' +
        $(if ($null -ne $rtApplyRoute) { '（' + $rtApplyRoute.StartLine + '-' + $rtApplyRoute.EndLine + ' 行）' } else { '' }))
    # 取り出しそのものが空振りでないこと。何を渡しても何か返るなら、上の2本に
    # 意味は無い。無い名前では $null が返ることを確かめておく。
    Chk ($null -eq (Get-YakuServerRouteBody -ServerPath $serverFile -Route 'tm-pretranslate-no-such-route')) '無い名前では取り出せない（取り出しが空振りでないこと）'

    if ($null -eq $rtEstimateRoute -or $null -eq $rtApplyRoute) {
        # 黙って飛ばすと「測っていないのに緑」に戻る。上の Chk で既に赤である。
        Write-Host '  SKIP ルート本体を取り出せなかったので、サーバの口は走らせられない' -ForegroundColor Red
    } else {
        # サーバのルートは -Path を渡さない。既定の置き場（YAKULINGO_DATA_DIR 配下）
        # へ入れる。この環境変数は冒頭で一時フォルダへ向けてある。
        $null = Add-TestTm -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path ''
        $null = Add-TestTm -Source '固定費を圧縮しました。' -Target 'We reduced fixed costs.' -Path ''
        Clear-YakuTranslationMemoryCache
        Chk (Test-Path -LiteralPath (Get-YakuTranslationMemoryPath -Direction 'to_en')) '既定の置き場に翻訳メモリが用意できた（この検査が空振りでないこと）'

        $rtText = @(
            '当社は電動化を進めます。',
            '固定費を圧縮しました。',
            '当社は電動化を進めます。',
            'この文は翻訳メモリに載っていません。'
        ) -join "`n"
        $rtDraft = New-YakuCatTextProject -Root $root -Text $rtText -Settings $settings -Direction 'to_en'
        # ルート本体は $project / $settings / $expectedRevision / $Context を読む。
        # 名前ごと、サーバと同じ形で置く。
        $project = Commit-YakuNewCatProject -Project $rtDraft
        $Context = $null
        $rtRevisionBefore = [int]$project.Revision
        $expectedRevision = $rtRevisionBefore

        $rtEstimate = $null; $rtEstimateNote = ''
        try { $rtEstimate = (Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text) | ConvertFrom-Json }
        catch { $rtEstimateNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $rtEstimate) ('見積りの口が応答を返す' + $rtEstimateNote)
        Chk ([int]$rtEstimate.rows -eq 3) ('見積りが対象3行を返す（実際 ' + [int]$rtEstimate.rows + ' 行）')
        Chk ([int]$rtEstimate.unique_texts -eq 2) ('見積りが原文の種類2件を返す（実際 ' + [int]$rtEstimate.unique_texts + ' 件）')
        Chk ([int]$rtEstimate.unique_remaining -eq 3) ('見積りは Copilot へ送る文を3件と数える（実際 ' + [int]$rtEstimate.unique_remaining + ' 件）')
        Chk (-not [bool]$rtEstimate.memory_unavailable) '見積りは翻訳メモリを読めている'
        Chk ([string]@($project.Segments)[0].Translation -eq '') '見積りだけでは1行も埋めない'

        $rtApply = $null; $rtApplyNote = ''
        try { $rtApply = (Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text) | ConvertFrom-Json }
        catch { $rtApplyNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $rtApply) ('事前翻訳の口が応答を返す' + $rtApplyNote)
        $rtApplyNames = @(); if ($null -ne $rtApply) { $rtApplyNames = @($rtApply.PSObject.Properties.Name) }
        Chk ($rtApplyNames -contains 'tm_pretranslate_filled') '応答に tm_pretranslate_filled が載る'
        Chk ([int]$rtApply.tm_pretranslate_filled -eq 3) ('事前翻訳が3行を埋めたと応答する（実際 ' + [int]$rtApply.tm_pretranslate_filled + ' 行）')
        Chk ([int]$rtEstimate.rows -eq [int]$rtApply.tm_pretranslate_filled) ('押す前に告げた行数と、実際に埋まった行数が一致する（' +
            [int]$rtEstimate.rows + ' / ' + [int]$rtApply.tm_pretranslate_filled + '）')
        Chk ($rtApplyNames -contains 'tm_pretranslate_requests_saved') '応答に tm_pretranslate_requests_saved が載る'
        Chk ([int]$rtApply.tm_pretranslate_requests_saved -eq 2) ('Copilot へ送る文が2件減ったと応答する（実際 ' + [int]$rtApply.tm_pretranslate_requests_saved + ' 件）')
        Chk ([int]$rtApply.tm_pretranslate_requests_saved -eq [int]$rtApply.tm_pretranslate_unique) '減った件数と、埋めた原文の種類数が一致する'
        Chk ([int]$rtEstimate.unique_texts -eq [int]$rtApply.tm_pretranslate_unique) '押す前に告げた種類数と、実際に埋めた種類数が一致する'
        Chk (-not [bool]$rtApply.tm_pretranslate_memory_unavailable) '翻訳メモリを最後まで読めたと応答する'

        $rtSegs = @($rtApply.segments)
        Chk ($rtSegs.Count -eq 4) ('応答に4行が載る（実際 ' + $rtSegs.Count + ' 行）')
        Chk ([string]$rtSegs[0].translation -eq 'We will advance electrification.') '1行目に翻訳メモリの訳が入って返る'
        Chk ([string]$rtSegs[0].origin -eq 'translation-memory' -and [string]$rtSegs[0].state -eq 'machine_draft' -and -not [bool]$rtSegs[0].confirmed) '埋めた行の出どころ・状態・未確認が、応答の中でも決まった値になる'
        Chk ([string]$rtSegs[2].translation -eq 'We will advance electrification.') '同じ原文の反復行にも入って返る'
        Chk ([string]::IsNullOrWhiteSpace([string]$rtSegs[3].translation)) '翻訳メモリに無い行は空のまま返る'
        Chk ([int]$rtApply.revision -eq ($rtRevisionBefore + 1)) ('事前翻訳で revision が1つ進む（' + $rtRevisionBefore + ' → ' + [int]$rtApply.revision + '）')

        # 画面が読む名前と、サーバが返す名前をつなぐ。cat.js の該当箇所を取り出して
        # 名前を拾い、実際の応答に全部あるかを見る。どちらかを改名すれば赤になる。
        $rtJsStart = $catJs.IndexOf('function tmPretranslate()')
        $rtJsEnd = $catJs.IndexOf('function registerTranslationMemory(')
        $rtJs = ''
        if ($rtJsStart -ge 0 -and $rtJsEnd -gt $rtJsStart) { $rtJs = $catJs.Substring($rtJsStart, $rtJsEnd - $rtJsStart) }
        Chk (-not [string]::IsNullOrWhiteSpace($rtJs)) '画面側の事前翻訳の処理を cat.js から取り出せた'
        $rtJsResultKeys = @([regex]::Matches($rtJs, 'result\.(tm_pretranslate_[a-z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $rtJsDataKeys = @([regex]::Matches($rtJs, 'data\.([a-z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Chk ($rtJsResultKeys.Count -ge 4) ('画面が読む tm_pretranslate_* の名前を取り出せた（' + $rtJsResultKeys.Count + ' 個）')
        Chk ($rtJsDataKeys.Count -ge 3) ('画面が読む見積りの名前を取り出せた（' + $rtJsDataKeys.Count + ' 個）')
        $rtMissingResult = @($rtJsResultKeys | Where-Object { $rtApplyNames -notcontains $_ })
        Chk ($rtMissingResult.Count -eq 0) ('画面が読む tm_pretranslate_* が、サーバの応答にすべてある（欠け: ' + (($rtMissingResult) -join ',') + '）')
        $rtEstimateNames = @(); if ($null -ne $rtEstimate) { $rtEstimateNames = @($rtEstimate.PSObject.Properties.Name) }
        $rtMissingData = @($rtJsDataKeys | Where-Object { $rtEstimateNames -notcontains $_ })
        Chk ($rtMissingData.Count -eq 0) ('画面が読む見積りの名前が、サーバの応答にすべてある（欠け: ' + (($rtMissingData) -join ',') + '）')

        # 別のタブが先に更新していたら、黙って上書きしない。
        $rtStale = ''
        $expectedRevision = $rtRevisionBefore
        try { $null = Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text } catch { $rtStale = [string]$_.Exception.Message }
        Chk ($rtStale -match '^CAT_PROJECT_REVISION_CONFLICT') ('古い revision では競合として止まる（実際 ' +
            $(if ([string]::IsNullOrWhiteSpace($rtStale)) { '止まらなかった' } else { $rtStale.Substring(0, [Math]::Min(38, $rtStale.Length)) }) + '）')

        Remove-YakuCatProject -Id ([string]$project.Id)

        # ---- 読めない翻訳メモリで、同じ2つの口をもう一度通す ----------------
        # ここまでの memory_unavailable の検査（見積り・反映とも）は「読めている」
        # 側しか見ていない。そのため応答を [bool]$false に固定しても116本すべてが
        # 緑・exit=0 のままだった（2026-08-15 の批評が実測）。
        #
        # これは表示の綾ではない。画面は rows=0 のとき、この値で文面を
        # 「翻訳メモリを読めませんでした」と「完全一致する行はありませんでした。
        # 訳文はそのままです。」に振り分ける（cat.js:1067-1074）。常に偽を返す
        # 実装は、読めなかったことを利用者から隠し、「当たりが無かった」と
        # 誤解させる。反映側の値も同じで、cat.js:1103 の「最後まで読めなかったので
        # 残りは見ていません」は、この値が真になる経路が無ければ死に文である。
        #
        # 読めなくする手は (c2) と同じ（FileShare.None で掴む）。掴んだのに
        # 読めてしまえば検査は空振りなので、先に読めないことを確かめる。
        $rtUnavailDraft = New-YakuCatTextProject -Root $root -Text $rtText -Settings $settings -Direction 'to_en'
        $project = Commit-YakuNewCatProject -Project $rtUnavailDraft
        $expectedRevision = [int]$project.Revision
        $rtDefaultTmPath = Get-YakuTranslationMemoryPath -Direction 'to_en'
        $rtUnavailEstimate = $null; $rtUnavailEstimateNote = ''
        $rtUnavailApply = $null; $rtUnavailApplyNote = ''
        $rtLock = [IO.File]::Open($rtDefaultTmPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            # 記憶化を捨てないと、直前に読んだ中身がそのまま使われて「読めた」に
            # なる。掴む前ではなく掴んだ後に捨てる。
            Clear-YakuTranslationMemoryCache
            $rtReallyLocked = $false
            try { $null = [IO.File]::ReadAllBytes($rtDefaultTmPath) } catch { $rtReallyLocked = $true }
            Chk $rtReallyLocked '既定の置き場の翻訳メモリを実際に読めなくできた（この検査が空振りでないこと）'
            try { $rtUnavailEstimate = (Invoke-YakuServerRouteBody -BodyText $rtEstimateRoute.Text) | ConvertFrom-Json }
            catch { $rtUnavailEstimateNote = ' / ' + [string]$_.Exception.Message }
            try { $rtUnavailApply = (Invoke-YakuServerRouteBody -BodyText $rtApplyRoute.Text) | ConvertFrom-Json }
            catch { $rtUnavailApplyNote = ' / ' + [string]$_.Exception.Message }
        } finally { $rtLock.Dispose(); Clear-YakuTranslationMemoryCache }
        Chk ($null -ne $rtUnavailEstimate) ('読めないときも見積りの口は応答を返す' + $rtUnavailEstimateNote)
        Chk ([int]$rtUnavailEstimate.rows -eq 0) ('読めないときの見積りは0行（実際 ' + [int]$rtUnavailEstimate.rows + ' 行）')
        Chk ([bool]$rtUnavailEstimate.memory_unavailable) '見積りは「翻訳メモリを読めなかった」ことを応答で伝える（当たりが0件だったことと取り違えさせない）'
        Chk ($null -ne $rtUnavailApply) ('読めないときも事前翻訳の口は応答を返す' + $rtUnavailApplyNote)
        Chk ([int]$rtUnavailApply.tm_pretranslate_filled -eq 0) ('読めないときは1行も埋めない（実際 ' + [int]$rtUnavailApply.tm_pretranslate_filled + ' 行）')
        Chk ([bool]$rtUnavailApply.tm_pretranslate_memory_unavailable) '反映も「翻訳メモリを最後まで読めなかった」ことを応答で伝える'
        $rtUnavailSegs = @($rtUnavailApply.segments)
        Chk (@($rtUnavailSegs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.translation) }).Count -eq 0) '読めないときは訳文欄をどれも書き換えずに返す'
        Remove-YakuCatProject -Id ([string]$project.Id)
    }

    if ($script:fail -eq 0) { Write-Host 'V91.72 事前翻訳の回帰テストに合格しました。' -ForegroundColor Green }
    else { Write-Host ('FAILED: ' + $script:fail) -ForegroundColor Red }
} finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
exit ([int]($script:fail -gt 0))
