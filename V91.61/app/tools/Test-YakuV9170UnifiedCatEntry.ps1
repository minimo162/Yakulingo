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

    Chk ([string]$project.Lifecycle -eq 'transient') '貼り付けは一時CAT作業として始まる'
    Chk ([datetime]$project.RetentionUntil -gt (Get-Date).AddDays(6)) '一時作業に保持期限を持つ'
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
    Chk (@($recent | Where-Object { [string]$_.id -eq [string]$committed.Id }).Count -eq 0) '一時作業は最近の作業を埋めない'

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
    Chk ([string]$confirmed.Lifecycle -eq 'transient') '明示確認後も一時作業のままにし、保存操作と分離する'
    Chk (@($confirmed.TmOutbox).Count -eq 0) '確認だけでは翻訳メモリoutboxを作らない'
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
    Chk ($htmlText.Contains('id="quick-submit-note" class="command-bar-note">確認画面へ進みます')) '貼り付けの行き先を送信前に説明する'
    $catClientText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
    Chk ($serverText.Contains('Invoke-YakuExpiredTransientProjectCleanup') -and $serverText.Contains('YakuProjectLeases') -and $serverText.Contains('YakuTransientCleanupNotBeforeUtc') -and $serverText.Contains("'project-presence'") -and $serverText.Contains("'project-retain'")) '再起動直後の再接続猶予を含め、一時作業cleanupを編集中leaseと延長操作で保護する'
    Chk ($serverText.Contains("ValidateSet('retain_tm','revoke_tm')") -and $htmlText.Contains('翻訳メモリの訳は残す') -and $htmlText.Contains('翻訳メモリ登録も取り消す')) '作業削除時に翻訳メモリを残すか取り消すか選べる'
    Chk ($catClientText.Contains("target=currentScope();if(!target)") -and $catClientText.Contains("post('project-close-delete'")) 'コピー直前の編集を保存し、最新revisionでコピー成功後だけ一時作業を削除する'
    $deleteProject=New-YakuCatTextProject -Root $root -Text '削除競合テスト' -Translation 'Deletion race test' -Settings $settings -Direction 'to_en' -Register:$false
    $deleteProject.Lifecycle='transient';$deleteProject.RetentionUntil=[datetime]::UtcNow.AddDays(-1).ToString('o');$deleteProject=Commit-YakuNewCatProject -Project $deleteProject
    $badDeleteBlocked=$false;try{$null=Start-YakuCatProjectDeletion -ProjectId ([string]$deleteProject.Id) -ExpectedRevision ([int]$deleteProject.Revision) -ExpectedGenerationId ('0'*32) -ExpectedLifecycle transient -RequireExpired}catch{$badDeleteBlocked=$_.Exception.Message -match 'CAT_PROJECT_DELETE_CAS_MISMATCH'}
    Chk ($badDeleteBlocked -and [string](Get-YakuCatProject -Id ([string]$deleteProject.Id)).Lifecycle -eq 'transient') '期限cleanupは読取後にgenerationが変われば削除開始をCAS拒否する'
    $deleteCommit=Start-YakuCatProjectDeletion -ProjectId ([string]$deleteProject.Id) -ExpectedRevision ([int]$deleteProject.Revision) -ExpectedGenerationId ([string]$deleteProject.ActiveGenerationId) -ExpectedLifecycle transient -RequireExpired
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
