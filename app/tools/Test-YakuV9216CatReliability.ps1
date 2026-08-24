[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
function Check { param([bool]$Condition,[string]$Message) if ($Condition) { Write-Host ('  ok   ' + $Message) } else { Write-Host ('  FAIL ' + $Message); $script:fail++ } }

foreach ($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','Html.ps1','EdgeLaunch.ps1','CopilotBudget.ps1','CopilotClient.ps1','PromptBuilder.ps1','BriefStyle.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1')) {
    . (Join-Path (Join-Path $root 'src') $name)
}

Write-Host 'Test-YakuV9216CatReliability'
$settings = Read-YakuSettings -Root $root
$requestId = '92169216921692169216921692169216'
$items = @(
    [pscustomobject]@{ Index=1; Text='売上高'; BlockIds=@() },
    [pscustomobject]@{ Index=2; Text='営業利益'; BlockIds=@() }
)
$null = Protect-YakuCatItems -Items $items -Root $root -Direction 'to_en'
$prompt = New-YakuCatPrompt -Root $root -Items $items -Settings $settings -Direction 'to_en' -RequestId $requestId
$mock = Invoke-YakuMockCopilotPrompt -Prompt $prompt
$parsed = Parse-YakuNumberedBatchResponse -Raw $mock -ExpectedIds @(1,2) -RequestId $requestId
Check ($parsed.ReceivedCount -eq 2 -and $parsed.DuplicateIds.Count -eq 0) 'request-scoped CAT prompt is parsed once by the mock translator'
Check ([string]$parsed.Items[1] -match 'Mock translation 1$' -and [string]$parsed.Items[2] -match 'Mock translation 2$') ('mock returns the current numbered file response contract: [' + [string]$parsed.Items[1] + '] [' + [string]$parsed.Items[2] + ']')
$warnings = New-Object System.Collections.Generic.List[object]
$context = @{ BatchOrdinal=0; TotalBatches=1; MaxRetryDepth=0; CacheHits=0; TranslatedSoFar=0; UniqueTotal=2; CopilotCalls=0; CompletedMap=@{} }
$env:YAKULINGO_MOCK = '1'
try {
    $translated = Invoke-YakuCatTranslationItems -Root $root -Items $items -Settings $settings -Direction 'to_en' -MaxChars 3000 -Warnings $warnings -Context $context
} finally {
    Remove-Item Env:YAKULINGO_MOCK -ErrorAction SilentlyContinue
}
Check ($translated.Count -eq 2 -and [string]$translated[1] -match 'Mock translation 1$' -and [string]$translated[2] -match 'Mock translation 2$') 'UseMockTranslator completes the actual CAT batch translation path'

function Get-TestFunctionText {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast,[string]$Name)
    $found = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { return '' }
    return [string]$found[0].Extent.Text
}
$serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
$tokens = $null; $errors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$errors)
Check (@($errors).Count -eq 0) 'Server.ps1 parses cleanly'
foreach ($functionName in @('Get-YakuTranslationJobStateValue','Convert-YakuTranslationJobResultJson')) {
    $functionText = Get-TestFunctionText -Ast $serverAst -Name $functionName
    Check (-not [string]::IsNullOrWhiteSpace($functionText)) ($functionName + ' can be extracted')
    if ($functionText) { Invoke-Expression $functionText }
}
Set-Item -Path Function:Update-YakuTranslationJobs -Value { param() }
$state = @{ id='job-9216'; mode='working'; label='翻訳中'; class='warn'; detail=''; progress=20; kind='cat'; phase='translate'; unique_done=0; unique_total=1; updated_at=''; error_code=''; completion_status=''; result_json='' }
$jobPayload = Convert-YakuTranslationJobResultJson -State $state | ConvertFrom-Json
Check (@($jobPayload.worker_progress).Count -eq 0) 'missing worker_progress serializes as an empty array, not [null]'
$state['worker_progress'] = @($null, [pscustomobject]@{ worker=0; state='running'; items=@(1) })
$jobPayloadWithNull = Convert-YakuTranslationJobResultJson -State $state | ConvertFrom-Json
Check (@($jobPayloadWithNull.worker_progress).Count -eq 1 -and $null -ne $jobPayloadWithNull.worker_progress[0]) 'null worker rows are removed from the job response'

$catProjectSource = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CatProject.ps1'))
Check ($catProjectSource.Contains('UnsupportedReasons | Where-Object { $null -ne $_ }')) 'Word unsupported reasons also exclude null rows'

$runtimeNode = 'C:\Users\yuuki\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$runtimeModules = 'C:\Users\yuuki\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules'
$node = if (Test-Path -LiteralPath $runtimeNode) { $runtimeNode } else { (Get-Command node -ErrorAction Stop).Source }
$oldNodePath = $env:NODE_PATH
$outPath = Join-Path ([IO.Path]::GetTempPath()) ('yaku9216-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    if (Test-Path -LiteralPath $runtimeModules) { $env:NODE_PATH = $runtimeModules }
    & $node (Join-Path $toolsRoot 'cat-reliability-gate.js') (Join-Path $root 'www') $outPath
    $nodeExit = $LASTEXITCODE
    $screen = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    Check ($nodeExit -eq 0 -and $null -ne $screen) 'real Chromium reliability gate completed'
    if ($screen) {
        Check ([string]$screen.disabledGuidance -match '保存できていない編集') 'disabled summary export explains the failed-save state before other blockers'
        Check ([string]$screen.saveStatus -eq '保存済み' -and [string]$screen.currentOriginal -eq 'Recovered target' -and -not [bool]$screen.saveFailed) 'successful retry clears the replaced-input ghost dirty state'
        Check ([string]$screen.terminalStatus -eq 'モック翻訳が停止しました。' -and -not [bool]$screen.connectionRecovery -and [int]$screen.jobPolls -eq 1) 'terminal job error is shown once instead of entering connection recovery'
        Check ([string]$screen.terminalPartial -eq 'Recovered partial target') 'partial rows delivered only with a terminal response remain visible'
        $unexpectedConsole = @($screen.console | Where-Object { [string]$_ -notmatch 'status of 500 \(Internal Server Error\)' })
        Check (@($screen.errors).Count -eq 0 -and $unexpectedConsole.Count -eq 0) 'browser has no unexpected page or console errors'
    }
} finally {
    $env:NODE_PATH = $oldNodePath
    if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }
}

if ($script:fail -gt 0) { Write-Host ('V92.16 CAT reliability failed: ' + $script:fail); exit 1 }
Write-Host 'V92.16 CAT reliability passed.'
