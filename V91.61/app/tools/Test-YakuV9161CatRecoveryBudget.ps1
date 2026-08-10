<#
.SYNOPSIS
  V91.61: CATのバッチ途中保存・キャッシュ・使用回数概算をExcelなしで検査する。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT = '1'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$oldDataDir = [string]$env:YAKULINGO_DATA_DIR
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-cat-recovery-' + [guid]::NewGuid().ToString('N'))
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'data'
$null = New-Item -ItemType Directory -Path $tmp -Force

function Chk { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   ' + $Message) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $Message) -ForegroundColor Red;$script:fail++} }

try {
    foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotBudget.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1')) {
        . (Join-Path (Join-Path $root 'src') $name)
    }
    $script:YakuCatRecoveryStore = Join-Path $tmp 'cat'
    function Get-YakuCatProjectStoreDir { return $script:YakuCatRecoveryStore }
    $script:YakuBudgetRecoveryLog = Join-Path $tmp 'copilot-calls.log'
    function Get-YakuCopilotCallLogPath { return $script:YakuBudgetRecoveryLog }
    $settings = Read-YakuSettings -Root $root
    $settings.max_chars_per_batch_file = 300
    Clear-YakuTranslationCache

    Write-Host '成功バッチの直後に後続バッチが失敗しても復元できる'
    $source1 = 'あ' * 276
    $source2 = 'い' * 276
    $segments = @(
        [pscustomobject]@{ Text=$source1; Translation=''; MaskedTranslation=''; Origin=''; Confirmed=$false; Joined=$false; Kind='text'; Sheet=''; Location='本文'; BlockIds=@(); Cells=@() },
        [pscustomobject]@{ Text=$source2; Translation=''; MaskedTranslation=''; Origin=''; Confirmed=$false; Joined=$false; Kind='text'; Sheet=''; Location='本文'; BlockIds=@(); Cells=@() }
    )
    $project = [pscustomobject]@{ Id='recovery'; Path=''; FileName='貼り付け'; Direction='to_en'; Source='text'; CreatedAt=(Get-Date).ToString('s'); CorpusSection=''; Blocks=@(); Segments=$segments }
    $script:YakuCatProjects[$project.Id] = $project
    Chk (Save-YakuCatProject -Project $project) '空のProjectを先に永続化する'

    $items = New-Object System.Collections.Generic.List[object]
    $items.Add([pscustomobject]@{ Index=1; Text=$source1; Targets=@(0); BlockIds=(New-Object System.Collections.Generic.List[string]) }) | Out-Null
    $items.Add([pscustomobject]@{ Index=2; Text=$source2; Targets=@(1); BlockIds=(New-Object System.Collections.Generic.List[string]) }) | Out-Null
    $null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $root -Direction 'to_en'
    $style = Get-YakuCatCacheStyle
    $warnings = New-Object System.Collections.Generic.List[object]
    $script:YakuRecoverySends = 0
    function Invoke-YakuProtectedTransportTestHook {
        param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat, [switch]$PreserveEndMarker, $Warnings, $ProgressState)
        $script:YakuRecoverySends++
        if ($script:YakuRecoverySends -ge 2) { throw 'COPILOT_SERVICE_ERROR: forced after first batch' }
        $requestId = [regex]::Match($Prompt, 'YAKULINGO_END:([0-9a-f]{32})').Groups[1].Value
        $translation = ('Translated recovery result. ' * 12).Trim()
        return ("[[ID:1]] 1. $translation`nYAKULINGO_END:$requestId")
    }
    $callback = {
        param($completedItems, $completedMap)
        $rows = @(ConvertTo-YakuCatCheckpointRows -Items @($completedItems) -Translations $completedMap -Warnings $warnings)
        if ($rows.Count -gt 0) { $null = Save-YakuCatBatchCheckpoint -ProjectId $project.Id -ProjectRevision ([int]$project.Revision) -Translations $rows }
    }.GetNewClosure()
    $context = @{
        BatchOrdinal=0; TotalBatches=2; MaxRetryDepth=0
        CacheHits=0; TranslatedSoFar=0; UniqueTotal=2; CopilotCalls=0
        CompletedMap=@{}; CachePerBatch=$true; CacheKind='cat'; CacheStyle=$style; CacheRoot=$root
        OnBatchCompleted=$callback
    }
    $threw = $false
    $caughtMessage = ''
    $caughtStack = ''
    try {
        $null = Invoke-YakuCatTranslationItems -Root $root -Items @($items.ToArray()) -Settings $settings -Direction 'to_en' -MaxChars 300 -Warnings $warnings -Context $context
    } catch { $threw = $true; $caughtMessage = [string]$_.Exception.Message; $caughtStack = [string]$_.ScriptStackTrace }
    Chk ($threw -and $script:YakuRecoverySends -eq 2) '1バッチ成功後の強制失敗を再現する'
    if ($context['CompletedMap'].Count -eq 0) {
        Write-Host ('  diagnostic completed=0 error=' + $caughtMessage + ' stack=' + $caughtStack + ' warnings=' + (@($warnings | ForEach-Object { [string]$_.Message }) -join ' | ')) -ForegroundColor Yellow
    }
    Remove-YakuCatProject -Id $project.Id
    $restored = Restore-YakuCatProject -Id $project.Id
    Chk (-not [string]::IsNullOrWhiteSpace([string]$restored.Segments[0].Translation) -and [string]::IsNullOrWhiteSpace([string]$restored.Segments[1].Translation)) 'applyなしで成功済み1件だけ復元する'
    Chk ([string]$restored.Segments[0].MaskedTranslation -eq [string]$restored.Segments[0].Translation -and [string]$restored.Segments[0].Origin -eq 'copilot') 'マスク後訳文と出所も保存する'

    $fresh = [pscustomobject]@{ Id='fresh'; Direction='to_en'; CorpusSection=''; Segments=@([pscustomobject]@{ Text=$source1; Translation='' }) }
    $beforeUsageSends = $script:YakuRecoverySends
    $usage = Get-YakuCatCopilotUsage -Root $root -Project $fresh -Settings $settings
    Chk ([int]$usage.CacheHits -eq 0 -and [int]$usage.EstimatedCalls -eq 1) ('成功バッチは別projectの意味的cacheへ流用しない (hits=' + [int]$usage.CacheHits + ' calls=' + [int]$usage.EstimatedCalls + ')')
    Chk ($script:YakuRecoverySends -eq $beforeUsageSends) '利用回数の概算自体ではCopilot送信を増やさない'

    Write-Host '3時間集計は1時間集計で履歴を失わない'
    $now = [datetime]'2026-08-09T12:00:00'
    [IO.File]::WriteAllLines($script:YakuBudgetRecoveryLog, @('2026-08-09T08:59:59','2026-08-09T09:00:00','2026-08-09T10:30:00','2026-08-09T11:59:00','broken'), [Text.UTF8Encoding]::new($false))
    Chk ((Get-YakuCopilotCallCount -Now $now -WindowHours 3) -eq 3) '3時間境界と不正行を正しく扱う'
    $null = Add-YakuCopilotCall -Now $now
    Chk ((Get-YakuCopilotCallCount -Now $now -WindowHours 3) -eq 4) '送信時の1時間集計後も3時間履歴を保持する'

    Write-Host '実分割と概算の境界を共有する'
    Clear-YakuTranslationCache
    $settings.max_chars_per_batch_file = 3000
    $boundary = [pscustomobject]@{ Id='boundary'; Direction='to_en'; CorpusSection=''; Segments=@([pscustomobject]@{Text=('う'*1477);Translation=''},[pscustomobject]@{Text=('え'*1477);Translation=''}) }
    $boundaryUsage = Get-YakuCatCopilotUsage -Root $root -Project $boundary -Settings $settings
    Chk ([int]$boundaryUsage.EstimatedCalls -eq 2) '1477字×2件を実分割どおり2回と見積もる'
} finally {
    if ([string]::IsNullOrWhiteSpace($oldDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $oldDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:fail -gt 0) { Write-Host "V91.61 CAT recovery/budget failed. failures=$script:fail" -ForegroundColor Red; exit 1 }
Write-Host 'V91.61 CAT recovery/budget regression passed.' -ForegroundColor Green
