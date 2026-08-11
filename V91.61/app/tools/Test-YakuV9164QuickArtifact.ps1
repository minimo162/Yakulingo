<#
.SYNOPSIS
  Quick memory artifact and CAT promotion regression tests.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0

function Check-YakuQuick {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

foreach ($name in @(
    'Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1',
    'FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CorpusReference.ps1',
    'CellSegments.ps1','CellAlign.ps1','CatProject.ps1','QuickArtifact.ps1'
)) { . (Join-Path (Join-Path $root 'src') $name) }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-quick-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
function Get-YakuCatProjectStoreDir { return $tempRoot }
function Add-YakuTranslationMemoryEntry { return [pscustomobject]@{ Added=$true; Reason='test' } }

try {
Write-Host 'Quick artifact memory contract' -ForegroundColor Cyan
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '第1四半期の資料を15時までに送ります。' -Translation 'I will send the document for the 1 quarter by 15 tomorrow.') -eq 'I will send the document for Q1 by 3:00 p.m. tomorrow.') 'Quick locally formats a masked quarter and clock hour naturally'
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '15時までに送ります。' -Translation 'I will send it by 15:00 tomorrow.') -eq 'I will send it by 3:00 p.m. tomorrow.') 'Quick consumes a model-rendered zero-padded minute without duplicating :00'
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '午後3時までに返信してください。' -Translation 'Please reply by 3 p.m.') -eq 'Please reply by 3:00 p.m.') 'Quick preserves the explicit Japanese p.m. meaning'
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '午後3時までに返信してください。' -Translation 'Please reply by 3:00 a.m. p.m.') -eq 'Please reply by 3:00 p.m.') 'Quick removes conflicting duplicate model meridiems'
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '15時までに前年差が15ポイント改善した理由を送ります。' -Translation 'The difference improved by 15 points; I will send the reason by 3 p.m.') -eq 'The difference improved by 15 points; I will send the reason by 3:00 p.m.') 'Quick never converts an equal-valued point amount into a clock time'
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '午後3時までに3拠点の状況を送ります。' -Translation 'I will send the status at 3 locations by 3 p.m.') -eq 'I will send the status at 3 locations by 3:00 p.m.') 'Quick never converts an equal-valued location count into a clock time'
    Check-YakuQuick ((ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '15時までに、利益は15億円増加する見込みです。' -Translation 'Operating profit is expected to increase by 15 oku by 3:00 p.m.') -eq 'Operating profit is expected to increase by 15 oku by 3:00 p.m.') 'Quick never converts an equal-valued financial amount into a clock time'
    $quickFiscal = ConvertTo-YakuQuickNaturalEnglishNotation -SourceText '2027年度第1四半期です。' -Translation 'It is the 1 quarter of the 2027 fiscal year.'
    Check-YakuQuick ($quickFiscal -eq 'It is Q1 of FY2027.') 'Quick formats a masked fiscal year and quarter naturally'
    $script:YakuQuickArtifacts = [hashtable]::Synchronized(@{})
    $script:YakuQuickArtifactByJob = [hashtable]::Synchronized(@{})
    $jobId = [guid]::NewGuid().ToString('N')
    $artifact = New-YakuQuickArtifact -JobId $jobId -SourceText '売上高は100百万円でした。' -Direction to_en `
        -DirectionBasis detected -DirectionConfidence high -SourceFingerprint ('a' * 64)
    Check-YakuQuick ([string]$artifact.Status -eq 'pending') 'new artifact is pending'
    Check-YakuQuick (([datetime]$artifact.ExpiresAtUtc - [datetime]$artifact.CreatedAtUtc).TotalMinutes -ge 29.9) 'artifact TTL is 30 minutes'
    Check-YakuQuick ([string](Get-YakuQuickArtifactByJobId -JobId $jobId).Id -eq [string]$artifact.Id) 'job maps to memory artifact'

    $jobState = [hashtable]::Synchronized(@{
        id=$jobId; mode='done'; label='Done'; class='ok'; detail=''; progress=100; error_code=''
        result_json=([pscustomobject]@{
            Direction='to_en'
            MaskedCount=1
            Options=@([pscustomobject]@{ Style='full'; Translation='Revenue was 100 million yen.'; MaskedTranslation='Revenue was [[N1]] million yen.' })
        } | ConvertTo-Json -Depth 6 -Compress)
    })
    $artifact = Complete-YakuQuickArtifactFromJobState -JobState $jobState
    Check-YakuQuick ([string]$artifact.Status -eq 'ready') 'terminal job completes artifact'
    Check-YakuQuick ([string]$artifact.Translation -eq 'Revenue was 100 million yen.') 'structured result selects full translation'
    Check-YakuQuick ([int]$artifact.Version -eq 1 -and [string]$artifact.MaskedTranslation -eq 'Revenue was [[N1]] million yen.') 'ready artifact keeps a server-only protected translation and version'
    Check-YakuQuick ([int]$artifact.MaskedCount -eq 1) 'artifact exposes only the number of protected numeric values'
    $view = ConvertTo-YakuQuickArtifactView -Artifact $artifact -IncludeContent
    Check-YakuQuick ([string]$view.PSObject.Properties.Name -notcontains 'Prompt') 'artifact view never exposes prompt'
    Check-YakuQuick ([string]$view.PSObject.Properties.Name -notcontains 'MaskedTranslation') 'artifact view never exposes the protected current translation'
    # 伏せた数値の一覧。-Root を渡したときだけ、原文から作り直して添える。
    # 対応表そのものは結果オブジェクトへ載せない契約（Translation.ps1 §8）を保つため。
    Check-YakuQuick (@($view.masked_values).Count -eq 0) 'view without a root reports the count only'
    $viewWithValues = ConvertTo-YakuQuickArtifactView -Artifact $artifact -IncludeContent -Root $root
    Check-YakuQuick (@($viewWithValues.masked_values).Count -eq [int]$artifact.MaskedCount) '伏せた数値の件数と一覧の件数が一致する'
    Check-YakuQuick (@($viewWithValues.masked_values) -contains '100') '伏せた実値そのものを画面へ返す'
    Check-YakuQuick ([string]$viewWithValues.PSObject.Properties.Name -notcontains 'Map') 'view never exposes the placeholder map itself'

    Write-Host 'In-memory Quick revision' -ForegroundColor Cyan
    $revisionJobId = [guid]::NewGuid().ToString('N')
    $revisionRequestId = [guid]::NewGuid().ToString('N')
    $registration = Register-YakuQuickArtifactRevisionJob -ArtifactId ([string]$artifact.Id) -ExpectedVersion 1 `
        -RequestId $revisionRequestId -Instruction 'Use net sales.' -JobId $revisionJobId
    Check-YakuQuick (-not [bool]$registration.Reused -and [string]$registration.Artifact.RevisionStatus -eq 'pending') 'revision starts against the same ready artifact'
    $duplicate = Register-YakuQuickArtifactRevisionJob -ArtifactId ([string]$artifact.Id) -ExpectedVersion 1 `
        -RequestId $revisionRequestId -Instruction 'Use net sales.' -JobId ([guid]::NewGuid().ToString('N'))
    Check-YakuQuick ([bool]$duplicate.Reused -and [string]$duplicate.JobId -eq $revisionJobId) 'same revision request is idempotent'
    $revisionState = [hashtable]::Synchronized(@{
        id=$revisionJobId; mode='done'; label='Done'; class='ok'; detail=''; progress=100; error_code=''
        result_json=([pscustomobject]@{
            Direction='to_en'
            Options=@([pscustomobject]@{ Style='full'; Translation='Net sales were 100 million yen.'; MaskedTranslation='Net sales were [[N1]] million yen.' })
        } | ConvertTo-Json -Depth 6 -Compress)
    })
    $revised = Complete-YakuQuickArtifactFromJobState -JobState $revisionState
    Check-YakuQuick ([string]$revised.Id -eq [string]$artifact.Id -and [int]$revised.Version -eq 2) 'successful revision atomically advances the same artifact version'
    Check-YakuQuick ([string]$revised.Translation -eq 'Net sales were 100 million yen.' -and [string]$revised.RevisionStatus -eq 'idle') 'successful revision replaces the current draft only after completion'

    $unsafeRevisionJobId = [guid]::NewGuid().ToString('N')
    $null = Register-YakuQuickArtifactRevisionJob -ArtifactId ([string]$artifact.Id) -ExpectedVersion 2 `
        -RequestId ([guid]::NewGuid().ToString('N')) -Instruction 'Change the number.' -JobId $unsafeRevisionJobId
    $beforeUnsafeTranslation = [string]$artifact.Translation
    $beforeUnsafeMasked = [string]$artifact.MaskedTranslation
    $unsafeRevisionState = [hashtable]::Synchronized(@{
        id=$unsafeRevisionJobId; mode='done'; label='Done'; class='ok'; detail=''; progress=100; error_code=''
        result_json=([pscustomobject]@{
            Direction='to_en'
            Warnings=@([pscustomobject]@{ Category='numeric-placeholder-unresolved'; Message='test blocker' })
            Options=@([pscustomobject]@{ Style='full'; Translation='Net sales were 999 million yen.'; MaskedTranslation='Net sales were [[N9]] million yen.' })
        } | ConvertTo-Json -Depth 6 -Compress)
    })
    $unsafeRejected = Complete-YakuQuickArtifactFromJobState -JobState $unsafeRevisionState
    Check-YakuQuick ([int]$unsafeRejected.Version -eq 2 -and [string]$unsafeRejected.RevisionStatus -eq 'error') 'unsafe revision warning fails closed without advancing the artifact version'
    Check-YakuQuick ([string]$unsafeRejected.Translation -eq $beforeUnsafeTranslation -and [string]$unsafeRejected.MaskedTranslation -eq $beforeUnsafeMasked) 'unsafe revision preserves the previous visible and protected translations'

    Write-Host 'Atomic idempotent CAT promotion' -ForegroundColor Cyan
    $beforeCount = $script:YakuCatProjects.Count
    $operation = { param($innerArtifact,$innerRoot) New-YakuCatProjectFromQuickArtifact -Root $innerRoot -Artifact $innerArtifact -Settings $null }
    $first = Invoke-YakuQuickArtifactPromotion -ArtifactId ([string]$artifact.Id) -Operation $operation -Arguments @($root)
    $project = Get-YakuCatProject -Id ([string]$first.ProjectId)
    Check-YakuQuick (-not [bool]$first.Reused) 'first promotion commits a project'
    Check-YakuQuick ($script:YakuCatProjects.Count -eq ($beforeCount + 1)) 'project is registered only once'
    Check-YakuQuick ([string]$project.QuickArtifactId -eq [string]$artifact.Id) 'project records artifact provenance'
    Check-YakuQuick ([string]$project.DirectionBasis -eq 'inherited') 'project inherits resolved direction'
    Check-YakuQuick (@($project.Segments | Where-Object { [bool]$_.Confirmed }).Count -eq 0) 'promoted segments are unreviewed'
    Check-YakuQuick ((Test-Path -LiteralPath (Join-Path (Join-Path $tempRoot ([string]$project.Id)) 'project.json'))) 'promotion is persisted before success'
    $second = Invoke-YakuQuickArtifactPromotion -ArtifactId ([string]$artifact.Id) -Operation $operation -Arguments @($root)
    Check-YakuQuick ([bool]$second.Reused -and [string]$second.ProjectId -eq [string]$first.ProjectId) 'retry returns the same project id'
    Check-YakuQuick ($script:YakuCatProjects.Count -eq ($beforeCount + 1)) 'retry does not create a duplicate project'

    $failureJob = [guid]::NewGuid().ToString('N')
    $failureArtifact = New-YakuQuickArtifact -JobId $failureJob -SourceText '保存失敗の原文' -Direction to_en
    $failureArtifact.Translation = 'Translation that must not commit.'
    $failureArtifact.Status = 'ready'
    $savedSaveFunction = (Get-Item Function:Save-YakuCatProject).ScriptBlock
    Set-Item Function:Save-YakuCatProject -Value { param($Project) return $false }
    $promotionFailed = $false
    try { $null = Invoke-YakuQuickArtifactPromotion -ArtifactId ([string]$failureArtifact.Id) -Operation $operation -Arguments @($root) }
    catch { $promotionFailed = $true }
    finally { Set-Item Function:Save-YakuCatProject -Value $savedSaveFunction }
    Check-YakuQuick $promotionFailed 'save failure rejects promotion'
    Check-YakuQuick ([string]::IsNullOrWhiteSpace([string]$failureArtifact.PromotedProjectId)) 'save failure leaves artifact unpromoted'
    Check-YakuQuick ([string]$failureArtifact.Status -eq 'ready') 'save failure keeps artifact retryable'
    Check-YakuQuick ($script:YakuCatProjects.Count -eq ($beforeCount + 1)) 'save failure does not leak project into registry'

    $expiredJob = [guid]::NewGuid().ToString('N')
    $expired = New-YakuQuickArtifact -JobId $expiredJob -SourceText '期限切れ' -Direction to_en
    $expired.ExpiresAtUtc = [datetime]::UtcNow.AddSeconds(-1)
    Check-YakuQuick ($null -eq (Get-YakuQuickArtifact -Id ([string]$expired.Id))) 'expired artifact is unavailable'
    Check-YakuQuick (-not $script:YakuQuickArtifactByJob.ContainsKey($expiredJob)) 'expiry removes job lookup'

    Write-Host 'Server boundary' -ForegroundColor Cyan
    $serverText = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
    $artifactText = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'QuickArtifact.ps1'))
    $quickJsText = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www\assets') 'quick.js'))
    Check-YakuQuick ($serverText -match "path -eq '/api/quick/jobs'") 'Quick JSON job route exists'
    Check-YakuQuick ($serverText -match "\^/api/quick/jobs/\(\[a-f0-9\]\{32\}\)\$") 'Quick JSON result route exists'
    Check-YakuQuick ($serverText -match "path -eq '/api/cat/promote'") 'artifact promotion route exists'
    Check-YakuQuick ($serverText -match '/api/quick/artifacts/.+?/revisions') 'Quick revision uses an artifact-bound API'
    Check-YakuQuick ($quickJsText -notmatch 'source_text|current_text|masked_translation') 'Quick revision client never reposts source or current translation'
    Check-YakuQuick ($quickJsText -match 'activeSourceSnapshot' -and $quickJsText -match 'readOnly = busy') 'Quick binds terminal results to the submitted source snapshot and locks editing while busy'
    Check-YakuQuick ($quickJsText -match '接続の回復を待っています' -and $quickJsText -notmatch "catch\(function \(error\) \{ busy = false") 'Quick keeps the job locked while transient polling failures recover'
    Check-YakuQuick ($serverText.Contains("if ([string]`$key -ne 'artifact_id')")) 'promotion rejects fields other than artifact_id'
    Check-YakuQuick ($serverText -match "path -eq '/quick'" -and $serverText -match "path -eq '/cat'") 'Quick and CAT page routes exist behind one server'
    Check-YakuQuick ($artifactText -notmatch 'Write-Yaku|Set-Content|Out-File|WriteAll(?:Text|Bytes)') 'Quick artifact store has no persistence write path'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'Quick から CAT への橋' -ForegroundColor Cyan
$quickClient = [IO.File]::ReadAllText((Join-Path $root 'www/assets/quick.js'))
$quickPage = [IO.File]::ReadAllText((Join-Path $root 'www/cat.html'))
$catClient2 = [IO.File]::ReadAllText((Join-Path $root 'www/assets/cat.js'))
$catPage2 = [IO.File]::ReadAllText((Join-Path $root 'www/cat.html'))
# 和訳でも資料翻訳へ移せる。サーバは to_en/to_jp の両方を受ける（Convert-YakuQuickArtifactToCatProject）。
# 画面だけが片側を塞いでいた期間があった。
Check-YakuQuick ($quickClient -notmatch "quick-promote'\)\.hidden = !toEnglish") '和訳でも資料翻訳へ移せる'
# 昇格ボタンの文言は1つだけ。失敗して戻したときに別の名前へ化けない。
Check-YakuQuick ($quickClient -match 'PROMOTE_LABEL' -and ($quickClient -split '資料翻訳で1文ずつ確認する').Count -eq 1) '昇格ボタンの文言が1つに揃っている'
# 「保存しません」が昇格で反転することを、押す前に書く。
Check-YakuQuick ($quickPage -match '1文ずつ確認して保存する') '移した先では保存されると押す前に書く'
# 用語集が Quick に効かないことを、登録した人が読む場所に書く。
Check-YakuQuick ($quickPage -match '登録した訳語も使いません') '用語集が効かない境界を画面に書く'
# 文数不一致のとき、サーバは訳案全文を保持する。画面がそれを読まないと「移したら訳が消えた」になる。
Check-YakuQuick ($catClient2 -match 'promotion_reference_translation' -and $catPage2 -match 'id="cat-promotion-reference"') '行に割り当てできなかった訳案を画面に残す'

if ($script:failed -gt 0) { throw "Quick artifact tests failed: $script:failed" }
Write-Host 'Quick artifact tests passed.' -ForegroundColor Green
