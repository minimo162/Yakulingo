<#
.SYNOPSIS
  V91.70: 貼り付け翻訳をCATへ一本化した契約の回帰テスト。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','TranslationMemory.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1')) {
    . (Join-Path (Join-Path $root 'src') $name)
}

function Chk {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:fail++ }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-unified-cat-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$previousDataDir = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tempRoot 'user-data'
$script:YakuUnifiedCatStore = Join-Path $tempRoot 'cat-store'
function Get-YakuCatProjectStoreDir { return $script:YakuUnifiedCatStore }

try {
    $settings = Read-YakuSettings -Root $root
    $raw = "見出し`r`n`r`n・項目A`r`n・項目B`r`n"
    $project = New-YakuCatTextProject -Root $root -Text $raw -Settings $settings -Direction 'to_en' -Register:$false

    Chk ([string]$project.Lifecycle -eq 'saved') '貼り付けは作成時点から保存済みCAT作業として始まる'
    Chk ([string]::IsNullOrWhiteSpace([string]$project.RetentionUntil)) '新規貼り付け作業に保持期限を持たせない'
    Chk ([string]$project.TextSourceStructure.ContractVersion -eq 'cat-text-source-v1') '貼り付け本文のlossless構造契約を持つ'
    Chk ([string]$project.TextSourceStructure.RawText -eq $raw.Replace("`r`n", "`n")) '正規化した原文本文をhashだけでなく保存する'

    $translations = @('Heading', 'Item alpha', 'Item beta')
    $counter = 0
    foreach ($segment in @($project.Segments)) {
        $segment.Translation = $translations[$counter]
        $counter++
        $segment.Origin = 'manual'
        $segment.State = 'human_edited'
    }
    $output = Get-YakuCatTextOutput -Project $project
    Chk ($output.EndsWith("`n", [StringComparison]::Ordinal)) '末尾改行を復元する'
    Chk ($output.Contains("`n`n")) '空行を復元する'
    Chk ($output.Contains('・')) '箇条書きの区切りを復元する'

    $projectId = [string]$project.Id
    $null = Commit-YakuNewCatProject -Project $project
    $committed = Get-YakuCatProject -Id $projectId
    $recent = @(Get-YakuCatSavedProjects)
    Chk (@($recent | Where-Object { [string]$_.id -eq [string]$committed.Id }).Count -eq 1) '貼り付け作業を最近の作業から再開できる'

    $projectDir = Join-Path (Get-YakuCatProjectStoreDir) $projectId
    $manifest = Get-Content -LiteralPath (Join-Path $projectDir 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $generation = Join-Path (Join-Path $projectDir 'generations') ([string]$manifest.generation_id)
    Chk (Test-Path -LiteralPath (Join-Path $generation 'text-source.json')) '本文構造をgenerationへ保存する'
    Chk (Test-Path -LiteralPath (Join-Path $generation 'human-decisions.jsonl')) '人の判断eventをgenerationへ保存する'

    $restored = Restore-YakuCatProject -Id ([string]$committed.Id)
    Chk ([string]$restored.TextSourceStructure.RawTextHash -eq [string]$committed.TextSourceStructure.RawTextHash) '再起動後も本文構造を復元する'

    $mutation = {
        param($candidate)
        $null = Set-YakuCatSegmentConfirmed -Project $candidate -Index 0 -Confirmed $true
    }
    $confirmedCommit = Invoke-YakuCatProjectMutation -ProjectId ([string]$committed.Id) -ExpectedRevision ([int]$committed.Revision) -Mutation $mutation
    $confirmed = $confirmedCommit.Project
    Chk ([string]$confirmed.Lifecycle -eq 'saved' -and [string]::IsNullOrWhiteSpace([string]$confirmed.RetentionUntil)) '明示確認後も期限なしの保存作業として続く'
    Chk (@($confirmed.TmOutbox).Count -eq 0) '確認だけでは翻訳メモリoutboxを作らず、登録操作を待つ'
    Chk (@($confirmed.ReviewEvents | Where-Object { [string]$_.decision_scope -eq 'translation' }).Count -eq 1) '翻訳確認を監査eventとして残す'

    $registerMutation = {
        param($candidate)
        return Register-YakuCatSegmentTranslationMemory -Project $candidate -Index 0
    }
    $registeredCommit = Invoke-YakuCatProjectMutation -ProjectId ([string]$confirmed.Id) -ExpectedRevision ([int]$confirmed.Revision) -Mutation $registerMutation
    $registered = $registeredCommit.Project
    Chk (@($registered.TmOutbox).Count -eq 1 -and [bool]@($registered.Segments)[0].TmRegistered) '明示登録時だけTM outboxと登録状態を作る'
    Chk (@($registered.ReviewEvents | Where-Object { [string]$_.decision_scope -eq 'translation_memory' }).Count -eq 1) 'TM登録判断を翻訳確認とは別eventで残す'
    $registeredRevision=[int]@($registered.ReviewEvents|Where-Object{[string]$_.decision_scope -eq 'translation_memory' -and [string]$_.action -eq 'registered'}|Select-Object -Last 1).project_revision
    $registeredSegmentId=[string]@($registered.Segments)[0].SegmentId
    $null=Set-YakuCatSegmentTranslation -Project $registered -Index 0 -Text 'Edited after TM registration'
    Chk (-not [bool]@($registered.Segments)[0].TmRegistered) 'TM登録後の訳文編集は現在訳を未登録状態へ戻す'
    $revokeRegistrations=@(Get-YakuCatTranslationMemoryRegistrationsForRevocation -Project $registered)
    Chk ($revokeRegistrations.Count -eq 1 -and [string]$revokeRegistrations[0].origin_segment_id -eq $registeredSegmentId -and [int]$revokeRegistrations[0].review_revision -eq $registeredRevision) '訳文編集後も登録event履歴からrevoke対象を復元する'
    $pendingAfterSync=Sync-YakuCatTranslationMemoryOutbox -Project $registered
    $null=Revoke-YakuCatTranslationMemoryRegistrations -Project $registered -Reason 'test-project-delete'
    $tmUnitId=Get-YakuTranslationMemoryUnitId -OriginProjectId ([string]$registered.Id) -OriginSegmentId $registeredSegmentId -Direction ([string]$registered.Direction)
    $tmAfterRevoke=Read-YakuTranslationMemory -Direction ([string]$registered.Direction)
    Chk ($pendingAfterSync -eq 0 -and $tmAfterRevoke.Contains($tmUnitId) -and (Test-YakuTranslationMemoryTombstone -Entry $tmAfterRevoke[$tmUnitId])) '登録後に訳文を編集してもrevoke削除で同期済みTMをtombstone化する'

    $serverText = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
    $entryText = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'quick.js') -Raw -Encoding UTF8
    $htmlText = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
    Chk (-not $serverText.Contains('/api/quick/jobs') -and -not $entryText.Contains('/api/quick/jobs')) '保存しないQuick APIと呼出を廃止する'
    Chk ($entryText.Contains("post('/api/cat/open'") -and $entryText.Contains('&translate=1')) '貼り付けはCAT作成後に翻訳を開始する'
    Chk (-not $htmlText.Contains('id="quick-save-submit"') -and -not $htmlText.Contains('id="quick-save-work"')) '保存有無を選ぶ二重入口を廃止する'
    Chk ($htmlText.Contains('id="quick-submit-reason" class="quick-submit-reason" role="status"') -and -not $htmlText.Contains('quick-submit-note') -and -not $htmlText.Contains('確認画面へ進みます')) '貼り付けの状態説明を主操作の直下へ動的に出す'
    $catClientText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
    $retiredActions = @('project-close-delete','project-retain','project-save')
    Chk ($serverText.Contains('YakuProjectLeases') -and $serverText.Contains("'project-presence'") -and
        -not $serverText.Contains('Invoke-YakuExpiredTransientProjectCleanup') -and
        -not $serverText.Contains('YakuTransientCleanupNotBeforeUtc') -and
        @($retiredActions | Where-Object { $serverText.Contains("'$_'") -or $catClientText.Contains("'$_'") }).Count -eq 0) `
        'project-presence leases remain while timed cleanup and its three UI actions are absent'
    Chk ($serverText.Contains("ValidateSet('retain_tm','revoke_tm')") -and $htmlText.Contains('翻訳メモリの訳は残す') -and $htmlText.Contains('翻訳メモリ登録も取り消す')) '作業削除時に翻訳メモリを残すか取り消すか選べる'
    Chk ($catClientText.Contains("post('delete'") -and $catClientText.Contains('cat-delete-memory') -and
        -not $catClientText.Contains("post('project-close-delete'") -and -not $catClientText.Contains("post('project-retain'") -and
        -not $catClientText.Contains("post('project-save'")) 'explicit deletion keeps the retain_tm/revoke_tm choice without timed actions'

    # 意図的な負の試験: 期限切れの旧 transient manifest を作っても、一覧・復元から
    # 消えず、通常の保存作業として期限を持たないことを確認する。
    $legacyProject=New-YakuCatTextProject -Root $root -Text '期限切れ旧作業' -Translation 'Expired legacy work' -Settings $settings -Direction 'to_en' -Register:$false
    $legacyProject=Commit-YakuNewCatProject -Project $legacyProject
    $legacyManifestPath = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) ([string]$legacyProject.Id)) 'project.json'
    $legacyManifest = Get-Content -LiteralPath $legacyManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $legacyManifest.lifecycle = 'transient'
    $legacyManifest.retention_until = [datetime]::UtcNow.AddDays(-1).ToString('o')
    $legacyUtf8 = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($legacyManifestPath, ($legacyManifest | ConvertTo-Json -Depth 20), $legacyUtf8)
    Remove-YakuCatProject -Id ([string]$legacyProject.Id)
    $legacyListed = @(Get-YakuCatSavedProjects | Where-Object { [string]$_.Id -eq [string]$legacyProject.Id })
    Chk ($legacyListed.Count -eq 1) '期限切れの旧 transient 作業も最近の作業に残る'
    $legacyRestored = Restore-YakuCatProject -Id ([string]$legacyProject.Id)
    Chk ($null -ne $legacyRestored -and [string]$legacyRestored.Lifecycle -eq 'saved' -and
        [string]::IsNullOrWhiteSpace([string]$legacyRestored.RetentionUntil) -and
        (Test-Path -LiteralPath $legacyManifestPath)) '期限切れの旧 transient 作業を期限なしの保存作業として復元する'
    $legacyDiskManifest = Get-Content -LiteralPath $legacyManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Chk ([string]$legacyDiskManifest.lifecycle -eq 'saved' -and
        [string]::IsNullOrWhiteSpace([string]$legacyDiskManifest.retention_until)) '期限切れ旧 transient のmanifest自体もsaved・期限なしへ移行する'

    # recent route と同じ production helper を実行し、旧 revision の行を返さないこと、
    # その行の revision で最初の明示削除CASが通ることを確認する。
    $serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
    $serverTokens = $null; $serverParseErrors = $null
    $serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$serverTokens, [ref]$serverParseErrors)
    $recentHelperAst = @($serverAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq 'Get-YakuCatRecentProjectRows'
    }, $true))
    Chk ($recentHelperAst.Count -eq 1) 'recent一覧の旧transient移行helperをproduction Serverから取り出せる'
    if ($recentHelperAst.Count -eq 1) {
        . ([scriptblock]::Create([string]$recentHelperAst[0].Extent.Text))
        $legacyDeleteProject = New-YakuCatTextProject -Root $root -Text 'recent delete migration' -Translation 'Recent delete migration' -Settings $settings -Direction 'to_en' -Register:$false
        $legacyDeleteProject = Commit-YakuNewCatProject -Project $legacyDeleteProject
        $legacyDeleteId = [string]$legacyDeleteProject.Id
        $legacyDeleteManifestPath = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) $legacyDeleteId) 'project.json'
        $legacyDeleteManifest = Get-Content -LiteralPath $legacyDeleteManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $legacyDeleteManifest.lifecycle = 'transient'
        $legacyDeleteManifest.retention_until = [datetime]::UtcNow.AddDays(-1).ToString('o')
        [IO.File]::WriteAllText($legacyDeleteManifestPath, ($legacyDeleteManifest | ConvertTo-Json -Depth 20), $legacyUtf8)
        Remove-YakuCatProject -Id $legacyDeleteId
        $legacyRecentRow = @(Get-YakuCatRecentProjectRows -Limit 10 | Where-Object { [string]$_.id -eq $legacyDeleteId })[0]
        $legacyDeleteCurrent = Get-YakuCatProject -Id $legacyDeleteId
        Chk ($null -ne $legacyRecentRow -and $null -ne $legacyDeleteCurrent -and
            [int]$legacyRecentRow.revision -eq [int]$legacyDeleteCurrent.Revision -and
            [string]$legacyDeleteCurrent.Lifecycle -eq 'saved') 'recent一覧は移行後のrevisionを返し、メモリ状態もsavedになる'
        $deleteFromRecent = $null; $deleteFromRecentError = ''
        try {
            $deleteFromRecent = Start-YakuCatProjectDeletion -ProjectId $legacyDeleteId -ExpectedRevision ([int]$legacyRecentRow.revision) `
                -ExpectedGenerationId ([string]$legacyDeleteCurrent.ActiveGenerationId) -ExpectedLifecycle saved -MemoryPolicy retain_tm
        } catch { $deleteFromRecentError = [string]$_.Exception.Message }
        Chk ($null -ne $deleteFromRecent -and [string]$deleteFromRecent.Project.Lifecycle -eq 'deleting' -and
            [string]::IsNullOrWhiteSpace($deleteFromRecentError)) 'recent一覧のrevisionで最初の明示delete CASが成功する'
        Remove-YakuCatProject -Id $legacyDeleteId -DeleteStored
    }

    # 意図的なCAS競合負試験: stable CAT code は migration wrapper で隠さない。
    $legacyConflictProject = New-YakuCatTextProject -Root $root -Text 'legacy migration conflict' -Translation 'Legacy migration conflict' -Settings $settings -Direction 'to_en' -Register:$false
    $legacyConflictProject = Commit-YakuNewCatProject -Project $legacyConflictProject
    $legacyConflictId = [string]$legacyConflictProject.Id
    $legacyConflictManifestPath = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) $legacyConflictId) 'project.json'
    $legacyConflictManifest = Get-Content -LiteralPath $legacyConflictManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $legacyConflictManifest.lifecycle = 'transient'
    $legacyConflictManifest.retention_until = [datetime]::UtcNow.AddDays(-1).ToString('o')
    [IO.File]::WriteAllText($legacyConflictManifestPath, ($legacyConflictManifest | ConvertTo-Json -Depth 20), $legacyUtf8)
    Remove-YakuCatProject -Id $legacyConflictId
    $originalProjectSaver = (Get-Command Save-YakuCatProject).ScriptBlock
    Set-Item -Path Function:Save-YakuCatProject -Value {
        param($Project, [switch]$ThrowOnError)
        throw 'CAT_COMMIT_MANIFEST_CONFLICT: simulated concurrent manifest update'
    }
    $legacyConflictMessage = ''
    try { $null = Restore-YakuCatProject -Id $legacyConflictId }
    catch { $legacyConflictMessage = [string]$_.Exception.Message }
    finally { Set-Item -Path Function:Save-YakuCatProject -Value $originalProjectSaver }
    Chk ($legacyConflictMessage -match '^CAT_COMMIT_MANIFEST_CONFLICT: simulated concurrent manifest update') 'legacy migration preserves stable CAT_COMMIT_MANIFEST_CONFLICT code and detail'

    # route-level negative tests: Restore の失敗を recent/resume/mutation の各入口で
    # 409 + current_revision として返し、通常の saved 一覧はRestoreしないことを確認する。
    $routeAst = @($serverAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -eq 'Invoke-YakuRoute'
    }, $true))
    Chk ($routeAst.Count -eq 1) 'production ServerのInvoke-YakuRouteをテストへ取り出せる'
    if ($routeAst.Count -eq 1) {
        . ([scriptblock]::Create([string]$routeAst[0].Extent.Text))
        $routeFunctionNames = @('Assert-YakuRequestBoundary','Clear-YakuExpiredUploads','Read-YakuRequestJson','Convert-YakuExceptionToUserMessage','Send-YakuTextResponse')
        $routeOriginalFunctions = @{}
        foreach ($routeFunctionName in $routeFunctionNames) {
            $routeCommand = Get-Command $routeFunctionName -CommandType Function -ErrorAction SilentlyContinue
            if ($null -ne $routeCommand) { $routeOriginalFunctions[$routeFunctionName] = $routeCommand.ScriptBlock }
        }
        Set-Item -Path Function:Assert-YakuRequestBoundary -Value { param($Request,$Path,$Method) }
        Set-Item -Path Function:Clear-YakuExpiredUploads -Value { param() }
        Set-Item -Path Function:Read-YakuRequestJson -Value { param($Request,[int]$MaxBytes=0); return $script:YakuRoutePayload }
        Set-Item -Path Function:Convert-YakuExceptionToUserMessage -Value { param($ErrorRecord); return [string]$ErrorRecord.Exception.Message }
        Set-Item -Path Function:Send-YakuTextResponse -Value {
            param($Context,[string]$Text,[string]$ContentType='',[int]$StatusCode=200,[switch]$AllowWasm)
            $script:YakuRouteResponseText = [string]$Text
            $script:YakuRouteResponseStatus = [int]$StatusCode
        }
        $script:YakuRoot = $root
        $routeOriginalProjectSaver = (Get-Command Save-YakuCatProject).ScriptBlock
        Set-Item -Path Function:Save-YakuCatProject -Value {
            param($Project,[switch]$ThrowOnError)
            throw 'CAT_COMMIT_MANIFEST_CONFLICT: simulated concurrent manifest update'
        }
        $routeProjectRevision = [int]$legacyConflictManifest.revision
        $routeRequest = [pscustomobject]@{ Url = [uri]'http://127.0.0.1/api/cat/recent'; HttpMethod = 'POST' }
        $routeContext = [pscustomobject]@{ Request = $routeRequest }
        $routeCases = @(
            [pscustomobject]@{ Name='recent'; Path='/api/cat/recent'; Payload=@{} },
            [pscustomobject]@{ Name='resume'; Path='/api/cat/resume'; Payload=@{ project_id=$legacyConflictId } },
            [pscustomobject]@{ Name='mutation'; Path='/api/cat/segment'; Payload=@{ id=$legacyConflictId; index=0; text='route conflict'; expected_revision=$routeProjectRevision } }
        )
        foreach ($routeCase in $routeCases) {
            $routeRequest.Url = [uri]('http://127.0.0.1' + [string]$routeCase.Path)
            $script:YakuRoutePayload = $routeCase.Payload
            $script:YakuRouteResponseText = ''
            $script:YakuRouteResponseStatus = 0
            $routeException = ''
            try { Invoke-YakuRoute -Context $routeContext } catch { $routeException = [string]$_.Exception.Message }
            $routeBody = $null
            try { $routeBody = $script:YakuRouteResponseText | ConvertFrom-Json } catch {}
            Chk ([string]::IsNullOrWhiteSpace($routeException) -and [int]$script:YakuRouteResponseStatus -eq 409 -and
                $null -ne $routeBody -and [string]$routeBody.code -eq 'CAT_COMMIT_MANIFEST_CONFLICT' -and
                [int]$routeBody.current_revision -eq $routeProjectRevision) `
                ($routeCase.Name + ' restoration conflict keeps HTTP 409/current_revision')
        }
        Set-Item -Path Function:Save-YakuCatProject -Value $routeOriginalProjectSaver
        Remove-YakuCatProject -Id $legacyConflictId -DeleteStored

        $normalRecentProject = New-YakuCatTextProject -Root $root -Text 'normal saved recent row' -Translation 'Normal saved recent row' -Settings $settings -Direction 'to_en' -Register:$false
        $normalRecentProject = Commit-YakuNewCatProject -Project $normalRecentProject
        Remove-YakuCatProject -Id ([string]$normalRecentProject.Id)
        $routeOriginalRestorer = (Get-Command Restore-YakuCatProject).ScriptBlock
        $script:YakuNormalRestoreCalls = 0
        Set-Item -Path Function:Restore-YakuCatProject -Value {
            param([string]$Id)
            $script:YakuNormalRestoreCalls++
            throw 'TEST_NORMAL_SAVED_MUST_NOT_RESTORE'
        }
        $normalRecentRows = @()
        $normalRecentError = ''
        try { $normalRecentRows = @(Get-YakuCatRecentProjectRows -Limit 10) } catch { $normalRecentError = [string]$_.Exception.Message }
        Set-Item -Path Function:Restore-YakuCatProject -Value $routeOriginalRestorer
        Chk ([string]::IsNullOrWhiteSpace($normalRecentError) -and $script:YakuNormalRestoreCalls -eq 0 -and
            @($normalRecentRows | Where-Object { [string]$_.id -eq [string]$normalRecentProject.Id }).Count -eq 1) `
            'normal saved recent rows never invoke restoration'

        foreach ($routeFunctionName in $routeFunctionNames) {
            if ($routeOriginalFunctions.ContainsKey($routeFunctionName)) {
                Set-Item -Path ("Function:" + $routeFunctionName) -Value $routeOriginalFunctions[$routeFunctionName]
            } else {
                Remove-Item -Path ("Function:" + $routeFunctionName) -ErrorAction SilentlyContinue
            }
        }
        Remove-YakuCatProject -Id ([string]$normalRecentProject.Id) -DeleteStored
    }

    $deleteProject=New-YakuCatTextProject -Root $root -Text '削除競合テスト' -Translation 'Deletion race test' -Settings $settings -Direction 'to_en' -Register:$false
    $deleteProject=Commit-YakuNewCatProject -Project $deleteProject
    $badDeleteBlocked=$false;try{$null=Start-YakuCatProjectDeletion -ProjectId ([string]$deleteProject.Id) -ExpectedRevision ([int]$deleteProject.Revision) -ExpectedGenerationId ('0'*32) -ExpectedLifecycle saved}catch{$badDeleteBlocked=$_.Exception.Message -match 'CAT_PROJECT_DELETE_CAS_MISMATCH'}
    Chk ($badDeleteBlocked -and [string](Get-YakuCatProject -Id ([string]$deleteProject.Id)).Lifecycle -eq 'saved') 'explicit deletion rejects a stale generation without changing the saved work'
    $deleteCommit=Start-YakuCatProjectDeletion -ProjectId ([string]$deleteProject.Id) -ExpectedRevision ([int]$deleteProject.Revision) -ExpectedGenerationId ([string]$deleteProject.ActiveGenerationId) -ExpectedLifecycle saved
    $mutationAfterDeleteBlocked=$false;try{$null=Invoke-YakuCatProjectMutation -ProjectId ([string]$deleteProject.Id) -ExpectedRevision ([int]$deleteCommit.Project.Revision) -Mutation {param($candidate);$candidate.RetentionUntil=[datetime]::UtcNow.AddDays(7).ToString('o')}}catch{$mutationAfterDeleteBlocked=$_.Exception.Message -match 'CAT_PROJECT_DELETING'}
    Chk ([string]$deleteCommit.Project.Lifecycle -eq 'deleting' -and $mutationAfterDeleteBlocked) '削除開始をmanifestへ先にcommitし、以後の保存・延長mutationを拒否する'

    $incoming = Join-Path $tempRoot 'source.xlsx'
    [IO.File]::WriteAllBytes($incoming, [byte[]](1,2,3,4,5,6,7,8))
    $fileProject = New-YakuCatTextProject -Root $root -Text '原本snapshot' -Translation 'Source snapshot' -Settings $settings -Direction 'to_en' -Register:$false
    $fileProject.Source = 'file'; $fileProject.Path = $incoming; $fileProject.FileName = 'source.xlsx'; $fileProject.Lifecycle = 'saved'
    $fileProject.Blocks = @(
        [pscustomobject]@{ Id='block-a'; Text='原本'; Location='Sheet1, A1'; Meta=[pscustomobject]@{ Sheet='Sheet1'; Address='A1' } },
        [pscustomobject]@{ Id='block-b'; Text='snapshot'; Location='Sheet1, A2'; Meta=[pscustomobject]@{ Sheet='Sheet1'; Address='A2' } }
    )
    $fileSegment = @($fileProject.Segments)[0]
    $fileSegment.Text = '原本snapshot'; $fileSegment.SourceIntegrityHash = Get-YakuCatSourceIntegrityHash -Text $fileSegment.Text
    $fileSegment.Kind = 'cell'; $fileSegment.Sheet = 'Sheet1'; $fileSegment.BlockIds = @('block-a','block-b')
    $fileSegment.Cells = @(
        [pscustomobject]@{ BlockId='block-a'; Text='原本'; Address='A1'; Row=1; Column=1 },
        [pscustomobject]@{ BlockId='block-b'; Text='snapshot'; Address='A2'; Row=2; Column=1 }
    )
    $fileProjectId = [string]$fileProject.Id
    $null = Commit-YakuNewCatProject -Project $fileProject
    $fileManifestPath = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) $fileProjectId) 'project.json'
    $fileManifest = Get-Content -LiteralPath $fileManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Chk ([string]$fileManifest.active_source_id -match '^[a-f0-9]{32}$' -and @($fileManifest.source_snapshots).Count -eq 1) '原本を不変SourceSnapshotとしてmanifestへ束縛する'
    $sourceSnapshot=@($fileManifest.source_snapshots)[0]
    Chk ([string]$sourceSnapshot.inventory_hash -match '^[a-f0-9]{64}$' -and [string]$sourceSnapshot.layout_hash -match '^[a-f0-9]{64}$' -and [string]$sourceSnapshot.print_hash -match '^[a-f0-9]{64}$') 'SourceSnapshotの構造・体裁・印刷依存を空欄でなく不変hashへ束縛する'
    Chk ([string]$fileManifest.source_artifact_relative_path -match '^source/revisions/[a-f0-9]{32}/original\.xlsx$') '原本をsource revision配下へ保存する'
    Chk ([string]$fileManifest.active_generation_id -eq [string]$fileManifest.generation_id -and [int]$fileManifest.project_revision -eq [int]$fileManifest.revision) 'sourceとgenerationとrevisionを一つのcommit manifestへ束縛する'
    Remove-YakuCatProject -Id $fileProjectId
    $fileRestored = Restore-YakuCatProject -Id $fileProjectId
    Chk ([string]$fileRestored.ActiveSourceId -eq [string]$fileManifest.active_source_id -and (Test-Path -LiteralPath ([string]$fileRestored.Path))) 'SourceSnapshotを再起動後に検証して復元する'
    $placement = @($fileRestored.PlacementPlans)[0]
    Chk ($null -ne $placement -and [string]$placement.source_snapshot_id -eq [string]$fileRestored.ActiveSourceId) 'PlacementPlanをSourceSnapshotへ束縛して保存・復元する'
    Chk ((@($placement.destinations | ForEach-Object { [string]$_.text }) -join '') -eq [string]@($fileRestored.Segments)[0].Translation) '掲載sliceを読順に連結すると掲載訳を空白も含めて復元できる'
    $manualPlacement = Set-YakuCatPlacementSlices -Project $fileRestored -Index 0 -Slices @('Source ','snapshot')
    Chk ([string]$manualPlacement.placement_kind -eq 'human_confirmed' -and (@($manualPlacement.destinations | ForEach-Object { [string]$_.text }) -join '') -eq 'Source snapshot') '人は訳文を削らずセル境界だけを明示確定できる'
    Chk (@($fileRestored.ReviewEvents | Where-Object { [string]$_.decision_scope -eq 'placement' }).Count -eq 1) '配置確認を訳文確認と別の監査eventにする'
    $firstPlacementHash = [string]$fileRestored.PlacementSetHash
    @($fileRestored.Segments)[0].Translation = 'Updated source snapshot'
    $null = Sync-YakuCatPlacementPlans -Project $fileRestored
    Chk ([string]$fileRestored.PlacementSetHash -ne $firstPlacementHash -and [string]@($fileRestored.PlacementPlans)[0].status -eq 'stale') '人が確定した配置は掲載訳変更時に黙って作り直さずstaleにする'
    $staleBlocked = $false
    try { $null = Get-YakuCatPlacementTranslationByBlockId -Project $fileRestored -TranslationBySegmentIndex @{ 0 = 'Updated source snapshot' } }
    catch { $staleBlocked = ([string]$_.Exception.Message -like 'CAT_PLACEMENT_STALE*') }
    Chk $staleBlocked 'staleな配置計画ではDRAFT書き戻しを停止する'
} finally {
    $env:YAKULINGO_DATA_DIR = $previousDataDir
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { throw ($script:fail.ToString() + ' checks failed') }
Write-Host 'Unified CAT entry tests passed.' -ForegroundColor Green
