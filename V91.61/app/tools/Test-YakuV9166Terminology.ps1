<#
.SYNOPSIS
  Schema-v2 terminology, QA, and legacy personal-glossary migration regression.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$src = Join-Path $root 'src'
$script:fail = 0

. (Join-Path $src 'Paths.ps1')
. (Join-Path $src 'Terminology.ps1')
. (Join-Path $src 'PersonalGlossary.ps1')

function Chk {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-term-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$oldData = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'data'
$projectPath = Join-Path $tmp 'project-terms.jsonl'
$projectId = '11111111111111111111111111111111'
$segmentId = '22222222222222222222222222222222'

function Add-TestTerm {
    param(
        [string]$Ja = '一過性',
        [string]$En = 'one-time',
        [string[]]$EnAllowed = @('non-recurring'),
        [string[]]$EnForbidden = @('one time'),
        [ValidateSet('required','advisory')][string]$Enforcement = 'required',
        [string]$Path = $projectPath,
        [string]$Scope = 'project',
        [string]$TermId = ''
    )
    $args = @{
        Scope=$Scope; ProjectId=$(if ($Scope -eq 'project') { $projectId } else { '' })
        JapanesePreferred=$Ja; EnglishPreferred=$En; EnglishAllowed=$EnAllowed; EnglishForbidden=$EnForbidden
        Enforcement=$Enforcement; OriginProjectId=$projectId; OriginFileName='FY2026.xlsx'
        OriginSegmentId=$segmentId; OriginLocation='Sheet1!A1'; OriginRevision=3; Path=$Path
    }
    if (-not [string]::IsNullOrWhiteSpace($TermId)) { $args['TermId'] = $TermId }
    return (Add-YakuTerminologyEntry @args)
}

try {
    Write-Host 'schema v2 / provenance' -ForegroundColor Cyan
    $added = Add-TestTerm
    Chk ([bool]$added.Added -and [string]$added.Reason -eq 'new') 'project termを追加できる'
    $entry = $added.Entry
    Chk ([int]$entry.schema_version -eq 2 -and [int]$entry.version -eq 1 -and [bool]$entry.active) 'schema/version/activeを持つ'
    Chk ([string]$entry.scope -eq 'project' -and [string]$entry.project_id -eq $projectId) 'project scopeを束縛する'
    Chk ([string]$entry.en.preferred -eq 'one-time' -and @($entry.en.allowed) -contains 'non-recurring' -and @($entry.en.forbidden) -contains 'one time') 'preferred/allowed/forbiddenを分ける'
    Chk ((Test-YakuTerminologyProvenance -Entry $entry) -and [string]$entry.reference_id -match '^[a-f0-9]{64}$') '内容と出典に束縛したreference idを持つ'
    $same = Add-YakuTerminologyRecord -Entry $entry -Path $projectPath
    Chk (-not [bool]$same.Added -and [string]$same.Reason -eq 'same') '同じrevisionを二重追記しない'
    $sameConcept = Add-TestTerm
    Chk (-not [bool]$sameConcept.Added -and [string]$sameConcept.Entry.term_id -eq [string]$entry.term_id) '同じ用語対を別IDで二重登録しない'

    $tampered = ($entry | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $tampered.en.preferred = 'tampered'
    Chk (-not (Test-YakuTerminologyProvenance -Entry $tampered)) '用語内容の改ざんを拒否する'
    $tamperedPath = Join-Path $tmp 'tampered.jsonl'
    [IO.File]::WriteAllLines($tamperedPath, [string[]]@(($tampered | ConvertTo-Json -Compress -Depth 8)), [Text.UTF8Encoding]::new($false))
    Chk (@(Read-YakuTerminologyEntries -Path $tamperedPath).Count -eq 0) '改ざん行を候補に読まない'
    $strictRejected = $false
    try { $null = @(Read-YakuTerminologyEntries -Path $tamperedPath -Strict) } catch { $strictRejected = ([string]$_.Exception.Message -like '*TERMINOLOGY_STORE_INVALID_PROVENANCE*') }
    Chk $strictRejected 'CAT用の厳格読込では改ざんstoreを空扱いせず停止する'

    Write-Host 'matching / project scope' -ForegroundColor Cyan
    $entries = @(Read-YakuTerminologyEntries -Path $projectPath -ProjectId $projectId)
    $hits = @(Find-YakuTerminologyMatches -Text '一過性の費用が発生しました。' -Direction to_en -Entries $entries -ProjectId $projectId)
    Chk ($hits.Count -eq 1 -and [string]$hits[0].PreferredTarget -eq 'one-time') '文中の用語を候補として見つける'
    Chk (@(Find-YakuTerminologyMatches -Text '一過性の費用' -Direction to_en -Entries $entries -ProjectId '99999999999999999999999999999999').Count -eq 0) '別projectの用語を出さない'
    $long = Add-TestTerm -Ja '一過性費用' -En 'one-time expense' -EnAllowed @() -EnForbidden @() -TermId '33333333333333333333333333333333'
    $entries = @(Read-YakuTerminologyEntries -Path $projectPath -ProjectId $projectId)
    $hits = @(Find-YakuTerminologyMatches -Text '一過性費用が発生しました。' -Direction to_en -Entries $entries -ProjectId $projectId)
    Chk ($hits.Count -eq 1 -and [string]$hits[0].SourceTerm -eq '一過性費用') '重なる語は長い用語を優先する'

    Write-Host 'terminology QA / exception' -ForegroundColor Cyan
    $baseEntries = @($entries | Where-Object { [string]$_.term_id -eq [string]$entry.term_id })
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a one-time expense.' -Direction to_en -Entries $baseEntries -ProjectId $projectId
    Chk ([bool]$qa.Passed -and @($qa.Findings).Count -eq 0) 'preferred targetはQA合格'
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a non-recurring expense.' -Direction to_en -Entries $baseEntries -ProjectId $projectId
    Chk ([bool]$qa.Passed) 'allowed targetもQA合格'
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a temporary expense.' -Direction to_en -Entries $baseEntries -ProjectId $projectId
    Chk (-not [bool]$qa.Passed -and [string]$qa.Findings[0].Code -eq 'terminology-missing' -and [string]$qa.Findings[0].Severity -eq 'error') 'required用語の欠落をerrorにする'
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a one time expense.' -Direction to_en -Entries $baseEntries -ProjectId $projectId
    Chk (-not [bool]$qa.Passed -and [string]$qa.Findings[0].Code -eq 'terminology-forbidden') 'forbidden targetをerrorにする'
    $conflictPath = Join-Path $tmp 'conflict.jsonl'
    $conflictA = Add-TestTerm -Path $conflictPath -TermId '66666666666666666666666666666666' -En 'one-time' -EnAllowed @() -EnForbidden @()
    $conflictB = Add-TestTerm -Path $conflictPath -TermId '77777777777777777777777777777777' -En 'temporary' -EnAllowed @() -EnForbidden @()
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a one-time expense.' -Direction to_en -Entries @($conflictA.Entry,$conflictB.Entry) -ProjectId $projectId
    Chk (-not [bool]$qa.Passed -and @($qa.Findings | Where-Object { [string]$_.Code -eq 'terminology-conflict' }).Count -eq 1) '同じ範囲の同格必須用語が競合したら黙って一方を選ばない'
    $substringPath = Join-Path $tmp 'substring.jsonl'
    $substring = Add-TestTerm -Path $substringPath -TermId '55555555555555555555555555555555' -EnAllowed @() -EnForbidden @('time')
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a one-time expense.' -Direction to_en -Entries @($substring.Entry) -ProjectId $projectId
    Chk ([bool]$qa.Passed) 'preferred内の部分文字列をforbiddenの別使用と誤認しない'
    $exception = [pscustomobject]@{
        term_id=[string]$entry.term_id; term_version=[int]$entry.version; active=$true
        source_hash=Get-YakuTerminologyHash -Text '一過性の費用です。'
        target_hash=Get-YakuTerminologyHash -Text 'This is a temporary expense.'
    }
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'This is a temporary expense.' -Direction to_en -Entries $baseEntries -Exceptions @($exception) -ProjectId $projectId
    Chk ([bool]$qa.Passed -and [bool]$qa.Findings[0].Excepted -and [string]$qa.Findings[0].Severity -eq 'info') '同じterm version/source/targetの行例外だけを認める'
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性の費用です。' -TargetText 'Temporary cost.' -Direction to_en -Entries $baseEntries -Exceptions @($exception) -ProjectId $projectId
    Chk (-not [bool]$qa.Passed) '訳文変更後は古い例外を使わない'

    $advisoryPath = Join-Path $tmp 'advisory.jsonl'
    $advisory = Add-TestTerm -Enforcement advisory -Path $advisoryPath -TermId '44444444444444444444444444444444'
    $qa = Test-YakuTerminologyCompliance -SourceText '一過性です。' -TargetText 'It is temporary.' -Direction to_en -Entries @($advisory.Entry) -ProjectId $projectId
    Chk ([bool]$qa.Passed -and [string]$qa.Findings[0].Severity -eq 'warning') 'advisory不一致は警告だが確認を止めない'

    Write-Host 'update / deactivate / snapshot' -ForegroundColor Cyan
    $snapshot1 = Get-YakuTerminologySnapshotHash -Entries $baseEntries
    $updated = Update-YakuTerminologyEntry -TermId ([string]$entry.term_id) -Scope project -ProjectId $projectId `
        -JapanesePreferred '一過性' -EnglishPreferred 'non-recurring' -EnglishAllowed @('one-time') `
        -OriginProjectId $projectId -OriginFileName 'FY2026.xlsx' -OriginSegmentId $segmentId `
        -OriginLocation 'Sheet1!A1' -OriginRevision 4 -Path $projectPath
    Chk ([bool]$updated.Added -and [int]$updated.Entry.version -eq 2 -and [string]$updated.Entry.reference_id -ne [string]$entry.reference_id) '更新はversionとreference idを進める'
    $latest = @(Read-YakuTerminologyEntries -Path $projectPath -ProjectId $projectId | Where-Object { [string]$_.term_id -eq [string]$entry.term_id })
    Chk ($latest.Count -eq 1 -and [string]$latest[0].en.preferred -eq 'non-recurring') '読込は最新versionだけを返す'
    Chk ((Get-YakuTerminologySnapshotHash -Entries $latest) -ne $snapshot1) '用語更新でsnapshot hashが変わる'
    $disabled = Disable-YakuTerminologyEntry -TermId ([string]$entry.term_id) -Path $projectPath `
        -OriginProjectId $projectId -OriginFileName 'FY2026.xlsx' -OriginSegmentId $segmentId `
        -OriginLocation 'Sheet1!A1' -OriginRevision 5
    Chk ([bool]$disabled.Added -and -not [bool]$disabled.Entry.active -and [int]$disabled.Entry.version -eq 3) '削除せずinactive revisionを追記する'
    Chk (@(Read-YakuTerminologyEntries -Path $projectPath | Where-Object { [string]$_.term_id -eq [string]$entry.term_id }).Count -eq 0) 'inactive termを通常候補に出さない'
    Chk (@(Read-YakuTerminologyEntries -Path $projectPath -IncludeInactive | Where-Object { [string]$_.term_id -eq [string]$entry.term_id }).Count -eq 1) '監査用にはinactive latest revisionを読める'

    Write-Host 'legacy personal.csv migration' -ForegroundColor Cyan
    $legacyDir = Join-Path $tmp 'legacy'
    $null = New-Item -ItemType Directory -Path $legacyDir -Force
    $legacy = Join-Path $legacyDir 'personal.csv'
    $personalTerms = Join-Path $legacyDir 'personal-v2.jsonl'
    [IO.File]::WriteAllLines($legacy, [string[]]@('source,target','一過性,one-time','一過性,non-recurring','"売上,合計","Net sales, total"'), [Text.UTF8Encoding]::new($true))
    $legacyRows = @(Read-YakuLegacyPersonalGlossaryRows -Path $legacy)
    Chk ($legacyRows.Count -eq 3 -and @($legacyRows | Where-Object { $_.Source -eq 'source' }).Count -eq 0) 'CSV headerを用語として読まない'
    $migration = Invoke-YakuPersonalGlossaryMigration -LegacyPath $legacy -TerminologyPath $personalTerms
    Chk ([int]$migration.Migrated -eq 2) '同じ原語は旧CSVの最終行を採ってv2へ移行する'
    $personal = @(Read-YakuPersonalTerminologyEntries -LegacyPath $legacy -TerminologyPath $personalTerms)
    Chk ($personal.Count -eq 2 -and @($personal | Where-Object { $_.ja.preferred -eq '一過性' -and $_.en.preferred -eq 'non-recurring' }).Count -eq 1) '移行後も最新の個人用語を読める'
    $migration = Invoke-YakuPersonalGlossaryMigration -LegacyPath $legacy -TerminologyPath $personalTerms
    Chk ([int]$migration.Migrated -eq 0 -and ([IO.File]::ReadAllLines($personalTerms)).Count -eq 2) '移行を再実行しても重複しない'
    $map = Read-YakuPersonalGlossary -LegacyPath $legacy -TerminologyPath $personalTerms
    Chk (-not $map.Contains('source') -and [string]$map['一過性'] -eq 'non-recurring' -and [string]$map['売上,合計'] -eq 'Net sales, total') '旧map APIもheader除外・CSV引用符・v2優先を保つ'

    Write-Host 'legacy writer compatibility' -ForegroundColor Cyan
    $legacyData = Join-Path $tmp 'legacy-writer-data'
    $env:YAKULINGO_DATA_DIR = $legacyData
    $oldAdd = Add-YakuPersonalGlossaryEntry -Source '営業利益' -Target 'Operating profit'
    Chk ([bool]$oldAdd.Added) '出典を渡さない旧呼出しもCSVへ保存できる'
    $oldMap = Read-YakuPersonalGlossary
    Chk (-not $oldMap.Contains('source') -and [string]$oldMap['営業利益'] -eq 'Operating profit') '旧writerのheaderが擬似用語にならない'
    $projectOnly = Add-YakuTerminologyEntry -Scope project -ProjectId $projectId -JapanesePreferred 'この資料限定語' `
        -EnglishPreferred 'project-only term' -OriginProjectId $projectId -OriginFileName 'private.docx' `
        -OriginSegmentId $segmentId -OriginLocation '本文 2' -OriginRevision 1
    Chk ([bool]$projectOnly.Added) '同じJSONL storeへproject用語を保存できる'
    $oldMap = Read-YakuPersonalGlossary
    Chk (-not $oldMap.Contains('この資料限定語')) 'project用語を旧global glossary APIへ漏らさない'
    $scoped = @(Read-YakuPersonalTerminologyEntries -ProjectId $projectId | Where-Object { [string]$_.term_id -eq [string]$projectOnly.Entry.term_id })
    Chk ($scoped.Count -eq 1) 'project contextを持つCAT APIからだけproject用語を読める'
}
finally {
    $env:YAKULINGO_DATA_DIR = $oldData
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.66 terminology regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.66 terminology regression passed.' -ForegroundColor Green
