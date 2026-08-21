<#
.SYNOPSIS
  End-to-end CAT terminology and translation-memory integration regression.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$src = Join-Path $root 'src'
$script:failed = 0

function Chk([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-cat-resources-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$oldData = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'data'

foreach ($name in @(
    'Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1',
    'FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1',
    'Terminology.ps1','PersonalGlossary.ps1','TranslationMemory.ps1','CatProject.ps1'
)) { . (Join-Path $src $name) }

function Get-YakuCatProjectStoreDir { return (Join-Path $tmp 'projects') }

try {
    Write-Host 'CAT terminology lifecycle' -ForegroundColor Cyan
    $project = New-YakuCatTextProject -Root $root -Text '一過性の費用を計上しました。' -Settings $null -Direction to_en -Translation 'We recorded a temporary expense.' -Register $false
    $segment = @($project.Segments)[0]
    $added = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$project.Id) -Kind occurrence -Enforcement required `
        -JapanesePreferred '一過性' -EnglishPreferred 'one-time' -EnglishAllowed @('non-recurring') -EnglishForbidden @('temporary') `
        -OriginProjectId ([string]$project.Id) -OriginFileName 'test.docx' -OriginSegmentId ([string]$segment.SegmentId) `
        -OriginLocation '本文 1' -OriginRevision ([int]$project.Revision)
    Chk ([bool]$added.Added) '選択した短い対をproject用語として登録できる'
    $affected = Update-YakuCatProjectForTerminologyChange -Project $project -Entry $added.Entry
    Chk ($affected -eq 1 -and [string]$segment.Translation -eq 'We recorded a temporary expense.') '用語追加は該当行を再検査対象にするが訳文を書き換えない'

    $candidates = @(Get-YakuCatSegmentCandidates -Root $root -Project $project -Index 0 -PairsDir (Join-Path $tmp 'pairs'))
    $termCandidate = @($candidates | Where-Object { [string]$_.Kind -eq 'term' -and [string]$_.Target -eq 'one-time' })
    Chk ($termCandidate.Count -eq 1) '別の文章でも登録用語を全文候補と別に提示する'
    $blocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0 -Confirmed $true } catch { $blocked = ([string]$_.Exception.Message -like 'CAT_REVIEW_QC_FAILED:*terminology-*') }
    Chk $blocked '必須用語の欠落と禁止訳は確認を止める'

    $null = Set-YakuCatSegmentTranslation -Project $project -Index 0 -Text 'We recorded a one-time expense.'
    $null = Set-YakuCatSegmentTerminologyUsage -Project $project -Index 0 -Candidate $termCandidate[0]
    Chk ([string]$segment.Translation -eq 'We recorded a one-time expense.') '用語挿入は文全体を用語だけに置換しない'
    $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0 -Confirmed $true
    Chk ([bool]$segment.Confirmed -and [string]$segment.QcStatus -eq 'passed') '推奨訳を使った行は機械チェック後に確認できる'

    Write-Host 'Per-segment exception and persistence' -ForegroundColor Cyan
    $project2 = New-YakuCatTextProject -Root $root -Text '一過性の費用です。' -Settings $null -Direction to_en -Translation 'This expense is temporary.' -Register $false
    # The project-scoped term must not leak to another project.
    Chk (@(Get-YakuCatSegmentCandidates -Root $root -Project $project2 -Index 0 -PairsDir (Join-Path $tmp 'pairs')).Count -eq 0) 'この資料だけの用語は別projectへ出ない'
    $personal = Add-YakuTerminologyEntry -Scope personal -Kind occurrence -Enforcement required `
        -JapanesePreferred '一過性' -EnglishPreferred 'one-time' -EnglishForbidden @('temporary') `
        -OriginProjectId ([string]$project2.Id) -OriginFileName 'test2.docx' -OriginSegmentId ([string]$project2.Segments[0].SegmentId) `
        -OriginLocation '本文 1' -OriginRevision ([int]$project2.Revision)
    $null = Update-YakuCatProjectForTerminologyChange -Project $project2 -Entry $personal.Entry
    $null = Add-YakuCatTerminologyException -Project $project2 -Index 0 -TermId ([string]$personal.Entry.term_id) -TermVersion ([int]$personal.Entry.version) -ReasonCode approved-alternative -Alternative 'temporary'
    $null = Set-YakuCatSegmentConfirmed -Project $project2 -Index 0 -Confirmed $true
    Chk ([bool]$project2.Segments[0].Confirmed) '明示した行だけは別表現の例外として確認できる'
    $null = Set-YakuCatSegmentTranslation -Project $project2 -Index 0 -Text 'This is still temporary.'
    $staleExceptionBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $project2 -Index 0 -Confirmed $true } catch { $staleExceptionBlocked = $true }
    Chk $staleExceptionBlocked '訳文を変更すると以前の用語例外は失効する'
    $invalidAlternativeBlocked = $false
    try { $null = Add-YakuCatTerminologyException -Project $project2 -Index 0 -TermId ([string]$personal.Entry.term_id) -TermVersion ([int]$personal.Entry.version) -ReasonCode approved-alternative -Alternative 'not in translation' } catch { $invalidAlternativeBlocked = ([string]$_.Exception.Message -eq 'CAT_TERM_ALTERNATIVE_NOT_PRESENT') }
    Chk $invalidAlternativeBlocked '別表現の例外は現在の訳文に実在する表現だけを認める'

    Write-Host 'Affected-row invalidation' -ForegroundColor Cyan
    $project3 = New-YakuCatTextProject -Root $root -Text "一過性の費用です。`n通常の費用です。" -Settings $null -Direction to_en -Translation "This is a temporary expense.`nThis is a normal expense." -Register $false
    foreach ($row in @($project3.Segments)) { $row.State='reviewed'; $row.Confirmed=$true; $row.QcStatus='passed'; $row.QcSourceHash=[string]$row.SourceIntegrityHash; $row.QcTargetHash=Get-YakuCatSourceIntegrityHash -Text ([string]$row.Translation); $row.QcContractVersion=Get-YakuCatQcContractVersion }
    $scoped = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$project3.Id) -Kind occurrence -Enforcement required `
        -JapanesePreferred '一過性' -EnglishPreferred 'one-time' -OriginProjectId ([string]$project3.Id) -OriginFileName 'two-lines.docx' `
        -OriginSegmentId ([string]$project3.Segments[0].SegmentId) -OriginLocation '本文 1' -OriginRevision ([int]$project3.Revision)
    $null = Update-YakuCatProjectForTerminologyChange -Project $project3 -Entry $scoped.Entry
    Chk ([string]$project3.Segments[0].State -eq 'stale' -and [string]$project3.Segments[1].State -eq 'reviewed') '用語変更では該当する確認済み行だけを再確認対象にする'

    Write-Host 'Zero-seed cell-exact pass' -ForegroundColor Cyan
    $resourceSettings = [pscustomobject]@{}
    $fixedProject = New-YakuCatTextProject -Root $root -Text '売上高' -Settings $null -Direction to_en -Register $false
    $emptyPass = Invoke-YakuCatGlossaryPass -Root $root -Project $fixedProject -Settings $resourceSettings
    Chk ([int]$emptyPass.Applied -eq 0 -and [string]::IsNullOrWhiteSpace([string]$fixedProject.Segments[0].Translation)) '登録前は配布データから固定訳を補わない'
    $fixedTerm = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$fixedProject.Id) -Kind cell_exact -Enforcement advisory `
        -JapanesePreferred '売上高' -EnglishPreferred 'Net sales' -OriginProjectId ([string]$fixedProject.Id) `
        -OriginFileName 'labels.xlsx' -OriginSegmentId ([string]$fixedProject.Segments[0].SegmentId) `
        -OriginLocation 'Sheet1!A1' -OriginRevision ([int]$fixedProject.Revision)
    $fixedPass = Invoke-YakuCatGlossaryPass -Root $root -Project $fixedProject -Settings $resourceSettings
    Chk ([int]$fixedPass.Applied -eq 1 -and [string]$fixedProject.Segments[0].Translation -eq 'Net sales' -and [string]$fixedProject.Segments[0].Origin -eq 'glossary') '利用者登録の固定訳だけを明示適用する'
    $fixedUsage = @($fixedProject.Segments[0].TerminologyUsages | Where-Object { [string]$_.reference_id -eq [string]$fixedTerm.Entry.reference_id })
    Chk ($fixedUsage.Count -eq 1 -and [int]$fixedUsage[0].term_version -eq 1) '固定訳のreference idとversionを行へ記録する'
    $otherFixedProject = New-YakuCatTextProject -Root $root -Text '売上高' -Settings $null -Direction to_en -Register $false
    $otherPass = Invoke-YakuCatGlossaryPass -Root $root -Project $otherFixedProject -Settings $resourceSettings
    Chk ([int]$otherPass.Applied -eq 0) 'この資料だけの固定訳を別projectへ漏らさない'

    # 決算の略語は原文に無い数字を持つ（上期→1H、第1四半期→Q1、2026年度→FY26）。
    # 登録した固定訳をアプリが丸ごと写した行は、数値の増減チェックから外す。
    # 外れるのはそこだけで、人が書き換えた訳やCopilotの訳は従来どおり全部検査される。
    Write-Host 'registered abbreviations with digits' -ForegroundColor Cyan
    function Test-YakuAbbrevConfirm {
        param([string]$SourceText, [string]$TermTarget, [string]$OverrideTarget)
        $abbrevProject = New-YakuCatTextProject -Root $root -Text $SourceText -Settings $null -Direction to_en -Register $false
        $abbrevSegment = @($abbrevProject.Segments)[0]
        if ($TermTarget) {
            $null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$abbrevProject.Id) -Kind cell_exact -Enforcement advisory `
                -JapanesePreferred $SourceText -EnglishPreferred $TermTarget -Origin 'cat-abbrev-test' `
                -OriginProjectId ([string]$abbrevProject.Id) -OriginFileName 'abbrev.xlsx' `
                -OriginSegmentId ([string]$abbrevSegment.SegmentId) -OriginLocation '説明!A1' -OriginRevision ([int]$abbrevProject.Revision)
            $null = Invoke-YakuCatGlossaryPass -Root $root -Project $abbrevProject -Settings $resourceSettings
        }
        if ($OverrideTarget) { $null = Set-YakuCatSegmentTranslation -Project $abbrevProject -Index 0 -Text $OverrideTarget }
        try { $null = Set-YakuCatSegmentConfirmed -Project $abbrevProject -Index 0; return $true } catch { return $false }
    }
    Chk (Test-YakuAbbrevConfirm -SourceText '上期営利' -TermTarget '1H OP') '登録した固定訳をアプリが丸ごと当てた行は、数字入りの略語でも確認済みにできる'
    Chk (Test-YakuAbbrevConfirm -SourceText '2026年度' -TermTarget 'FY26') '年度の略語も確認済みにできる'
    Chk (-not (Test-YakuAbbrevConfirm -SourceText '上期営利' -TermTarget '1H OP' -OverrideTarget '2H OP 999')) '登録があっても人が書き換えた訳は数値検査を通す'
    Chk (-not (Test-YakuAbbrevConfirm -SourceText '上期営利' -OverrideTarget '1H OP')) '登録が無い訳文に数字が増えていれば止める'

    # 兆・万千を含む金額。単位変換は原文を訳文側の表記へ書き換える（1兆3,150億円 → 13,150 oku）。
    # 突き合わせがその変換を通っていないと、アプリ自身が正しく換算した訳を
    # アプリ自身が numeric-value-mismatch で拒否する。有報・短信で頻出する。
    Write-Host 'composite magnitude units' -ForegroundColor Cyan
    function Test-YakuUnitConfirm {
        param([string]$SourceText, [string]$TargetText)
        $unitProject = New-YakuCatTextProject -Root $root -Text $SourceText -Settings $null -Direction to_en -Register $false
        $null = Set-YakuCatSegmentTranslation -Project $unitProject -Index 0 -Text $TargetText
        try { $null = Set-YakuCatSegmentConfirmed -Project $unitProject -Index 0; return $true } catch { return $false }
    }
    Chk (Test-YakuUnitConfirm '当連結会計年度の売上高は1兆3,150億円となりました。' 'Net sales for the fiscal year were 13,150 oku.') '兆と億が混ざった金額を確認済みにできる'
    Chk (Test-YakuUnitConfirm '売上高は1兆2,400億円に達しました。' 'Net sales reached 12,400 oku.') '語尾が変わっても単位を取り違えない'
    Chk (Test-YakuUnitConfirm '販売台数は18万6千台でした。' 'Unit sales were 186 k units.') '万と千が混ざった台数を確認済みにできる'
    Chk (-not (Test-YakuUnitConfirm '当連結会計年度の売上高は1兆3,150億円となりました。' 'Net sales for the fiscal year were 1,315 oku.')) '桁を10分の1にした訳は止める'
    Chk (-not (Test-YakuUnitConfirm '販売台数は18万6千台でした。' 'Unit sales were 186 units.')) '千を落とした訳は止める'

    Write-Host 'UI and API separation' -ForegroundColor Cyan
    $server = [IO.File]::ReadAllText((Join-Path $src 'Server.ps1'))
    $client = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www\assets') 'cat.js'))
    Chk ($server -match 'CAT_TERM_CANNOT_REPLACE_SEGMENT' -and $server -match "'term-insert'") 'サーバーも用語挿入と全文置換を別操作にする'
    Chk ($client -match 'data-cat-term-insert' -and $client -match 'nextText = input\.value\.slice' -and $client -match 'segment_matches') '画面は用語をカーソル位置へ挿入し全文候補と分ける'
    Chk ($client -notmatch 'input\.setRangeText\(term') '用語保存に失敗する前に画面上の訳文を変更しない'
    Chk ($client -match 'data-cat-tm-delete' -and $server -match "'tm-delete'") '個人TM候補をtombstoneで非表示にできる'

    # 2026-08-12: 見積りは画面から外した（押す前に読んでも判断が変わらず、
    # ツールバーを1行占めていた）。APIは残す。サーバ側の契約だけ見る。
    # （以前の経緯）押したあとに
    # 上限へ当たると、そのバッチぶんの往復が無駄になる。結線が切れたら落とす。
    Chk ($server -match "'estimate'" -and $server -match 'estimated_calls' -and $server -match 'calls_last_3h') 'サーバーは翻訳前の見積りを返す'
    $catHtml = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'cat.html'))
}
finally {
    $env:YAKULINGO_DATA_DIR = $oldData
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:failed -gt 0) { Write-Host "V91.66 CAT resources regression failed. failures=$script:failed" -ForegroundColor Red; exit 1 }
Write-Host 'V91.66 CAT resources regression passed.' -ForegroundColor Green
