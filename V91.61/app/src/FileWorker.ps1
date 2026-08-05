[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$JobSpecPath,
    [Parameter(Mandatory=$true)][string]$StatePath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
# Ordering contract: write result.json before publishing a terminal mode in state.json.
# Server.ps1 lazy-loads terminal results based on this guarantee.
$script:YakuRoot = $Root
. (Join-Path $Root 'src\Paths.ps1')
. (Join-Path $Root 'src\Runtime.ps1')
. (Join-Path $Root 'src\Html.ps1')
. (Join-Path $Root 'src\Settings.ps1')
. (Join-Path $Root 'src\PromptBuilder.ps1')
. (Join-Path $Root 'src\CopilotClient.ps1')
. (Join-Path $Root 'src\Translation.ps1')
. (Join-Path $Root 'src\FileProcessors.ps1')
. (Join-Path $Root 'src\FileTranslation.ps1')
. (Join-Path $Root 'src\Corpus.ps1')
. (Join-Path $Root 'src\CorpusSearch.ps1')
. (Join-Path $Root 'src\CorpusReference.ps1')

$spec = Read-YakuJsonFile -Path $JobSpecPath
if ($null -eq $spec) { throw 'ファイル翻訳ワーカーのジョブ仕様を読み込めませんでした。' }

$state = [hashtable]::Synchronized(@{})
foreach ($prop in @($spec.state.PSObject.Properties)) { $state[[string]$prop.Name] = $prop.Value }
$state['state_path'] = $StatePath
$state['result_path'] = $ResultPath
$state['cancel_path'] = [string]$spec.cancel_path
$state['worker_pid'] = $PID
$state['worker_started_at'] = Get-YakuProcessStartTimeIso -Id $PID
$state['mode'] = 'opening'
$state['phase'] = 'opening'
$state['label'] = 'Opening file'
$state['started_at'] = (Get-Date).ToString('s')
$state['updated_at'] = (Get-Date).ToString('s')
$script:YakuWorkerProgressState = $state
Write-YakuProgressStateFile -ProgressState $state

try {
    Assert-YakuJobNotCancelled -ProgressState $state
    if ([string]::IsNullOrWhiteSpace([string]$spec.build_id)) { throw 'BUILD_ID_SPEC_MISSING: 古いサーバーから起動されたワーカーです。YakuLingoを完全終了して再起動してください。' }
    $workerBuildId = Assert-YakuBuildIdentity -Root $Root -ExpectedBuildId ([string]$spec.build_id)
    $state['build_id'] = $workerBuildId
    $settings = $spec.settings
    try { $script:YakuDiagnosticsLevel = Get-YakuDiagnosticsLevel -Settings $settings } catch { $script:YakuDiagnosticsLevel = 'standard' }
    $script:YakuFullTextDiagnosticsEnabled = ($script:YakuDiagnosticsLevel -eq 'full')
    Write-YakuLog "File worker settings snapshot. jobId=$($state['id']) buildId=$workerBuildId diagnosticsLevel=$script:YakuDiagnosticsLevel source=job-spec" 'INFO'
    $sheets = @($spec.sheets)
    $result = Invoke-YakuFileTranslation -Root $Root -InputPath ([string]$spec.file_path) -Settings $settings -ProgressState $state -Direction ([string]$spec.direction) -Sheets $sheets -JobId ([string]$state['id'])
    Assert-YakuJobNotCancelled -ProgressState $state
    Write-YakuJsonAtomic -Path $ResultPath -Value $result -Depth 80
    $completion = 'done'
    try { if ($result.PSObject.Properties.Name -contains 'CompletionStatus') { $completion = [string]$result.CompletionStatus } } catch {}
    if ([string]::IsNullOrWhiteSpace($completion)) { $completion = 'done' }
    $state['completion_status'] = $completion
    $state['mode'] = $completion
    $state['label'] = if ($completion -eq 'completed_with_warnings') { 'Completed with warnings' } else { 'Done' }
    $state['class'] = if ($completion -eq 'completed_with_warnings') { 'warn' } else { 'ok' }
    $state['detail'] = if ($completion -eq 'completed_with_warnings') { '不完全な項目があります。警告を確認してください。' } else { 'File translation completed.' }
    $state['progress'] = 100
    $state['output_path'] = [string]$result.OutputPath
    $state['output_name'] = [string]$result.OutputName
    $state['blocks_total'] = [int]$result.BlocksTotal
    $state['blocks_translated'] = [int]$result.BlocksTranslated
    $state['blocks_retained'] = [int]$result.BlocksRetainedOriginal
    $state['unique_total'] = [int]$result.UniqueTextCount
    $state['unique_done'] = [int]$result.UniqueTextCount
} catch [System.OperationCanceledException] {
    try {
        $cancelledOutput = [string]$result.OutputPath
        $outputsRoot = [System.IO.Path]::GetFullPath((Get-YakuSubDir 'outputs')).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
        if (-not [string]::IsNullOrWhiteSpace($cancelledOutput)) {
            $cancelledFull = [System.IO.Path]::GetFullPath($cancelledOutput)
            if ($cancelledFull.StartsWith($outputsRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $cancelledFull -PathType Leaf)) {
                Remove-Item -LiteralPath $cancelledFull -Force -ErrorAction Stop
            }
        }
    } catch { try { Write-YakuLog "Cancelled output cleanup failed. error=$($_.Exception.Message)" 'WARN' } catch {} }
    $state['mode'] = 'cancelled'
    $state['label'] = 'Cancelled'
    $state['class'] = 'idle'
    $state['detail'] = '翻訳をキャンセルしました。'
    $state['progress'] = 100
    $state['error_code'] = 'JOB_CANCELLED'
    $state['output_path'] = ''
    $state['output_name'] = ''
} catch {
    $safeMessage = [string]$_.Exception.Message
    try { Write-YakuLog "File worker failed. jobId=$($state['id']) errorCode=FILE_WORKER_FAILED error=$safeMessage" 'ERROR' } catch {}
    $errorResult = [pscustomobject]@{ Error=$safeMessage; ErrorCode='FILE_WORKER_FAILED'; Kind='file'; JobId=[string]$state['id'] }
    Write-YakuJsonAtomic -Path $ResultPath -Value $errorResult -Depth 12
    $state['mode'] = 'failed'
    $state['label'] = 'Translation error'
    $state['class'] = 'warn'
    $state['detail'] = $safeMessage
    $state['progress'] = 100
    $state['error_code'] = 'FILE_WORKER_FAILED'
    $state['output_path'] = ''
    $state['output_name'] = ''
} finally {
    $state['completed_at'] = (Get-Date).ToString('s')
    $state['updated_at'] = (Get-Date).ToString('s')
    Write-YakuProgressStateFile -ProgressState $state
    try {
        if ([bool]$spec.uploaded_input -and -not [string]::IsNullOrWhiteSpace([string]$spec.upload_dir) -and (Test-Path -LiteralPath ([string]$spec.upload_dir))) {
            Remove-Item -LiteralPath ([string]$spec.upload_dir) -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try { Remove-Item -LiteralPath $JobSpecPath -Force -ErrorAction SilentlyContinue } catch {}
}
