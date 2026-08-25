param(
    [string[]]$WorkerCounts = @('1','2','4'),
    [int]$ConcurrencyRequests = 4,
    [int]$TimeoutMinutes = 20,
    [switch]$SkipConcurrency,
    [ValidateSet('blind','translation')][string]$JudgeEvidence = 'translation',
    [ValidateSet('binary','clause_map')][string]$JudgeOutput = 'clause_map',
    [ValidateRange(1,12)][int]$JudgeBatchSize = 1
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:YakuRoot = $Root
. (Join-Path $Root 'src\SrcModules.ps1')
foreach ($yakuSrcModule in $script:YakuSrcModuleFiles) { . (Join-Path $Root (Join-Path 'src' $yakuSrcModule)) }

$settings = Read-YakuSettings -Root $Root
$cases = @(
    [pscustomobject]@{Id='ok-1';ExpectedError=$false;Source='取締役会は計画を承認した。';Translation='The board approved the plan.'},
    [pscustomobject]@{Id='ok-2';ExpectedError=$false;Source='需要が続けば、生産を増やす。';Translation='We will increase production if demand continues.'},
    [pscustomobject]@{Id='ok-3';ExpectedError=$false;Source='国内売上のみが増加した。';Translation='Only domestic sales increased.'},
    [pscustomobject]@{Id='ok-4';ExpectedError=$false;Source='品質を保ちながら納期を短縮する。';Translation='Shorten lead times while maintaining quality.'},
    [pscustomobject]@{Id='omit';ExpectedError=$true;Source='売上と利益が増加した。';Translation='Sales increased.'},
    [pscustomobject]@{Id='negation';ExpectedError=$true;Source='この変更は利益に影響しない。';Translation='This change affects profit.'},
    [pscustomobject]@{Id='scope';ExpectedError=$true;Source='国内売上のみが増加した。';Translation='Sales increased.'},
    [pscustomobject]@{Id='condition';ExpectedError=$true;Source='需要が続けば、生産を増やす。';Translation='We will increase production.'},
    [pscustomobject]@{Id='relationship';ExpectedError=$true;Source='価格上昇により数量が減少した。';Translation='Volume increased because prices fell.'},
    [pscustomobject]@{Id='qualifier';ExpectedError=$true;Source='利益はわずかに改善した。';Translation='Profit improved significantly.'},
    [pscustomobject]@{Id='numeric-missing';ExpectedError=$true;Source='売上高は100億円だった。';Translation='Sales were oku.'},
    [pscustomobject]@{Id='numeric-token';ExpectedError=$true;Source='売上高は100億円だった。';Translation='Sales were [[N2]] oku.'}
)

$items = New-Object System.Collections.Generic.List[object]
$final = @{}
foreach ($case in $cases) {
    $index = $items.Count + 1
    $sourceItem = New-YakuAgenticReviewItem -Root $Root -SourceText ([string]$case.Source) -MaskedTranslation ([string]$case.Translation) -Direction to_en -Notation oku -Index $index
    $items.Add($sourceItem) | Out-Null
    $final[$index] = [string]$case.Translation
}
$warnings = New-Object System.Collections.Generic.List[object]
$context = @{Workflow='measure-agentic-catch';AmountNotation='oku';BatchOrdinal=0;TotalBatches=2;TranslatedSoFar=0;UniqueTotal=($items.Count*2);CopilotCalls=0;CompletedMap=@{};JobId=('measure-'+[guid]::NewGuid().ToString('N'));FitBackJudgeEvidence=$JudgeEvidence;FitBackJudgeOutput=$JudgeOutput;FitBackJudgeBatchSize=$JudgeBatchSize}
$retry = @{}
$allItems = @($items.ToArray())
for ($offset=0; $offset -lt $allItems.Count; $offset+=3) {
    $last = [Math]::Min($allItems.Count-1,$offset+2)
    $batchItems = @($allItems[$offset..$last])
    $batchFinal = @{}
    foreach ($batchItem in $batchItems) { $batchFinal[[int]$batchItem.Index] = [string]$final[[int]$batchItem.Index] }
    # 捕捉率は判定性能だけを測る。並列ページの入力失敗を見逃しへ混ぜない。
    # 並列度は下の専用コンカレンシー測定で独立して測る。
    $batchRetry = Invoke-YakuCatFitBackCheck -Root $Root -Items $batchItems -Final $batchFinal -Settings $settings -MaxChars 3500 -Warnings $warnings -ProgressState $null -Context $context
    foreach ($key in @($batchRetry.Keys)) { $retry[[int]$key] = $true }
}

$rows = New-Object System.Collections.Generic.List[object]
for ($i=0; $i -lt $cases.Count; $i++) {
    $item = $items[$i]
    $numeric = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$item.Text) -Translated ([string]$cases[$i].Translation) -Location ('measure-'+[string]$cases[$i].Id)
    $detected = (-not [bool]$numeric.Ok) -or $retry.ContainsKey($i+1)
    $rows.Add([pscustomobject]@{id=$cases[$i].Id;expected_error=[bool]$cases[$i].ExpectedError;detected=[bool]$detected;numeric_ok=[bool]$numeric.Ok;agent_retry=[bool]$retry.ContainsKey($i+1)}) | Out-Null
}
$errorRows = @($rows.ToArray() | Where-Object expected_error)
$correctRows = @($rows.ToArray() | Where-Object {-not $_.expected_error})
$caught = @($errorRows | Where-Object detected).Count
$falsePositive = @($correctRows | Where-Object detected).Count
$catchRate = if ($errorRows.Count) { [Math]::Round($caught/[double]$errorRows.Count,4) } else { 0 }
$falsePositiveRate = if ($correctRows.Count) { [Math]::Round($falsePositive/[double]$correctRows.Count,4) } else { 0 }

$concurrency = $null
$parallelFloor = $(if ($SkipConcurrency) { $null } else { 1 })
if (-not $SkipConcurrency) {
    $rawConcurrency = @(& (Join-Path $Root 'tools\Measure-YakuCopilotConcurrency.ps1') -WorkerCounts $WorkerCounts -Requests $ConcurrencyRequests -TimeoutMinutes $TimeoutMinutes)
    $jsonText = ($rawConcurrency | Where-Object { $_ -is [string] }) -join [Environment]::NewLine
    $jsonStart = $jsonText.IndexOf('{')
    if ($jsonStart -ge 0) { $concurrency = $jsonText.Substring($jsonStart) | ConvertFrom-Json }
    foreach ($record in @($concurrency.results | Sort-Object workers)) {
        if ([int]$record.successes -eq [int]$record.requests -and [int]$record.rate_limits -eq 0 -and [double]$record.overlap -ge ([Math]::Max(1,[int]$record.workers) * 0.6)) { $parallelFloor = [Math]::Max($parallelFloor,[int]$record.workers) }
    }
}

$result = [pscustomobject]@{
    measured_at=(Get-Date).ToUniversalTime().ToString('o')
    catch_rate=$catchRate; caught=$caught; injected_errors=$errorRows.Count
    misses=@($errorRows | Where-Object {-not $_.detected} | ForEach-Object id)
    false_positive_rate=$falsePositiveRate; false_positives=@($correctRows | Where-Object detected | ForEach-Object id)
    badge=$(if($catchRate -ge 0.9 -and $falsePositiveRate -le 0.1){'意味・数字・読みやすさを点検'}else{'機械とAIの点検を通過'})
    judge_condition=[ordered]@{evidence=$JudgeEvidence;output=$JudgeOutput;batch_size=$JudgeBatchSize}
    parallel_floor=$parallelFloor
    cases=@($rows.ToArray())
    concurrency=$concurrency
}
$outputPath = Join-Path (Get-YakuSubDir 'runtime') ('agentic-prerequisites-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
Write-YakuJsonAtomic -Path $outputPath -Value $result -Depth 12
Write-Host ('RESULT_PATH=' + $outputPath)
$result | ConvertTo-Json -Depth 12
