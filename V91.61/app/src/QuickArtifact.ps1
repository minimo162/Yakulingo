<#
  Quick translation artifact boundary.

  Quick の原文と訳文は、この PowerShell process のメモリにだけ保持する。
  CAT へ引き継ぐときもブラウザーから本文を送り直さず、artifact ID だけで
  server 内の正本を参照する。
#>

function Initialize-YakuQuickArtifactStore {
    if ($null -eq $script:YakuQuickArtifacts) {
        $script:YakuQuickArtifacts = [hashtable]::Synchronized(@{})
    }
    if ($null -eq $script:YakuQuickArtifactByJob) {
        $script:YakuQuickArtifactByJob = [hashtable]::Synchronized(@{})
    }
}

function Clear-YakuExpiredQuickArtifacts {
    Initialize-YakuQuickArtifactStore
    $now = [datetime]::UtcNow
    foreach ($id in @($script:YakuQuickArtifacts.Keys)) {
        $artifact = $script:YakuQuickArtifacts[[string]$id]
        $expired = $false
        try { $expired = ([datetime]$artifact.ExpiresAtUtc -le $now) } catch { $expired = $true }
        if (-not $expired) { continue }
        $script:YakuQuickArtifacts.Remove([string]$id)
        foreach ($jobId in @($script:YakuQuickArtifactByJob.Keys)) {
            if ([string]$script:YakuQuickArtifactByJob[[string]$jobId] -eq [string]$id) {
                $script:YakuQuickArtifactByJob.Remove([string]$jobId)
            }
        }
    }
}

function New-YakuQuickArtifact {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [ValidateSet('detected','explicit','inherited')][string]$DirectionBasis = 'detected',
        [AllowNull()][string]$DirectionConfidence = '',
        [AllowNull()][string]$SourceFingerprint = '',
        [ValidateRange(1,1440)][int]$TtlMinutes = 30
    )
    Initialize-YakuQuickArtifactStore
    Clear-YakuExpiredQuickArtifacts
    if ($JobId -notmatch '^[a-f0-9]{32}$') { throw 'QUICK_JOB_ID_INVALID' }
    if ($script:YakuQuickArtifactByJob.ContainsKey($JobId)) { throw 'QUICK_JOB_ARTIFACT_ALREADY_EXISTS' }
    $now = [datetime]::UtcNow
    $artifact = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N')
        JobId = $JobId
        Status = 'pending'
        SourceText = [string]$SourceText
        Translation = ''
        # Copilotへ再依頼するときだけ使うserver内の保護済み訳文。viewへ出さない。
        MaskedTranslation = ''
        MaskedCount = 0
        Version = 0
        RevisionStatus = 'idle'
        ActiveRevisionJobId = ''
        ActiveRevisionBaseVersion = 0
        ActiveRevisionTranslationHash = ''
        RevisionError = ''
        RevisionRequests = [hashtable]::Synchronized(@{})
        Direction = [string]$Direction
        DirectionBasis = [string]$DirectionBasis
        DirectionConfidence = [string]$DirectionConfidence
        SourceFingerprint = [string]$SourceFingerprint
        Error = ''
        CreatedAtUtc = $now
        UpdatedAtUtc = $now
        ExpiresAtUtc = $now.AddMinutes($TtlMinutes)
        TtlMinutes = $TtlMinutes
        PromotedProjectId = ''
    }
    $script:YakuQuickArtifacts[$artifact.Id] = $artifact
    $script:YakuQuickArtifactByJob[$JobId] = $artifact.Id
    return $artifact
}

function Update-YakuQuickArtifactExpiry {
    param([Parameter(Mandatory=$true)]$Artifact)
    $now = [datetime]::UtcNow
    $minutes = 30
    try { $minutes = [Math]::Max(1, [int]$Artifact.TtlMinutes) } catch { $minutes = 30 }
    $Artifact.UpdatedAtUtc = $now
    $Artifact.ExpiresAtUtc = $now.AddMinutes($minutes)
    return $Artifact
}

function Get-YakuQuickArtifact {
    param([Parameter(Mandatory=$true)][string]$Id, [switch]$Touch)
    Initialize-YakuQuickArtifactStore
    Clear-YakuExpiredQuickArtifacts
    if ($Id -notmatch '^[a-f0-9]{32}$' -or -not $script:YakuQuickArtifacts.ContainsKey($Id)) { return $null }
    $artifact = $script:YakuQuickArtifacts[$Id]
    if ($Touch) { $null = Update-YakuQuickArtifactExpiry -Artifact $artifact }
    return $artifact
}

function Get-YakuQuickArtifactByJobId {
    param([Parameter(Mandatory=$true)][string]$JobId, [switch]$Touch)
    Initialize-YakuQuickArtifactStore
    Clear-YakuExpiredQuickArtifacts
    if (-not $script:YakuQuickArtifactByJob.ContainsKey($JobId)) { return $null }
    return (Get-YakuQuickArtifact -Id ([string]$script:YakuQuickArtifactByJob[$JobId]) -Touch:$Touch)
}

function ConvertTo-YakuQuickNaturalEnglishNotation {
    <#
      Quickの数値は送信前にすべてtoken化するため、Copilotは「第1四半期」の
      1が序数であることや、15時が時刻であることを知らない。外部送信後、
      復元済みの訳文だけをローカルで整える。金額・数量には触れない。
    #>
    param(
        [AllowNull()][string]$SourceText,
        [AllowNull()][string]$Translation
    )
    return (ConvertTo-YakuNaturalEnglishNotation -SourceText $SourceText -Translation $Translation)
}

function Complete-YakuQuickArtifactFromJobState {
    param([Parameter(Mandatory=$true)]$JobState)
    $jobId = [string]$JobState['id']
    $artifact = Get-YakuQuickArtifactByJobId -JobId $jobId -Touch
    if ($null -eq $artifact) { return $artifact }
    $isRevision = (-not [string]::IsNullOrWhiteSpace([string]$artifact.ActiveRevisionJobId) -and [string]$artifact.ActiveRevisionJobId -eq $jobId)
    if (-not $isRevision -and [string]$artifact.Status -ne 'pending') { return $artifact }
    if ($isRevision -and [string]$artifact.RevisionStatus -ne 'pending') { return $artifact }
    $mode = [string]$JobState['mode']
    if ($mode -notin @('done','completed_with_warnings','error','failed','cancelled','interrupted')) { return $artifact }
    if ($mode -eq 'cancelled') {
        if ($isRevision) {
            $artifact.RevisionStatus = 'error'
            $artifact.RevisionError = '修正をキャンセルしました。現在の訳案は変わっていません。'
            $artifact.ActiveRevisionJobId = ''
        } else {
            $artifact.Status = 'cancelled'
            $artifact.Error = '翻訳をキャンセルしました。'
        }
        return (Update-YakuQuickArtifactExpiry -Artifact $artifact)
    }
    $resultJson = [string]$JobState['result_json']
    if ([string]::IsNullOrWhiteSpace($resultJson)) {
        if ($isRevision) {
            $artifact.RevisionStatus = 'error'; $artifact.RevisionError = '修正結果を取得できませんでした。現在の訳案は変わっていません。'; $artifact.ActiveRevisionJobId = ''
        } else {
            $artifact.Status = 'error'; $artifact.Error = '翻訳結果を取得できませんでした。'
        }
        return (Update-YakuQuickArtifactExpiry -Artifact $artifact)
    }
    try {
        $result = $resultJson | ConvertFrom-Json
        if ($result.PSObject.Properties.Name -contains 'Error' -and -not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
            if ($isRevision) {
                $artifact.RevisionStatus = 'error'; $artifact.RevisionError = ([string]$result.Error + ' 現在の訳案は変わっていません。'); $artifact.ActiveRevisionJobId = ''
            } else {
                $artifact.Status = 'error'; $artifact.Error = [string]$result.Error
            }
            return (Update-YakuQuickArtifactExpiry -Artifact $artifact)
        }
        if ($isRevision) {
            if ([int]$artifact.Version -ne [int]$artifact.ActiveRevisionBaseVersion) { throw 'QUICK_REVISION_STALE_VERSION' }
            $currentHash = Get-YakuSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes([string]$artifact.Translation))
            if ($currentHash -ne [string]$artifact.ActiveRevisionTranslationHash) { throw 'QUICK_REVISION_STALE_TRANSLATION' }
            if (-not [string]::IsNullOrWhiteSpace([string]$artifact.PromotedProjectId)) { throw 'QUICK_REVISION_ALREADY_PROMOTED' }
        }
        if ([string]$result.Direction -ne [string]$artifact.Direction) { throw 'QUICK_RESULT_DIRECTION_MISMATCH' }
        $options = @($result.Options)
        $selected = @($options | Where-Object { [string]$_.Style -eq 'full' } | Select-Object -First 1)
        if ($selected.Count -eq 0) { $selected = @($options | Select-Object -First 1) }
        if ($selected.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$selected[0].Translation)) { throw 'QUICK_RESULT_TRANSLATION_MISSING' }
        if ($isRevision) {
            $unsafeWarningCategories = @('numeric-integrity','numeric-placeholder-unresolved','numeric-placeholder-dropped-brief')
            $unsafeWarnings = @($result.Warnings | Where-Object { $unsafeWarningCategories -contains [string]$_.Category })
            if ($unsafeWarnings.Count -gt 0) { throw 'QUICK_REVISION_NUMERIC_QC_FAILED' }
            if ([string]$selected[0].Translation -match '\[\[N\d+\]\]') { throw 'QUICK_REVISION_PLACEHOLDER_REMAINS' }
        }
        $translation = [string]$selected[0].Translation
        if ([string]$artifact.Direction -eq 'to_en') {
            $translation = ConvertTo-YakuQuickNaturalEnglishNotation -SourceText ([string]$artifact.SourceText) -Translation $translation
        }
        $maskedTranslation = [string]$selected[0].MaskedTranslation
        if ([string]::IsNullOrWhiteSpace($maskedTranslation)) { throw 'QUICK_RESULT_MASKED_TRANSLATION_MISSING' }
        $artifact.Translation = $translation
        $artifact.MaskedTranslation = $maskedTranslation
        if ($isRevision) {
            $artifact.Version = [int]$artifact.Version + 1
            $artifact.RevisionStatus = 'idle'
            $artifact.RevisionError = ''
            $artifact.ActiveRevisionJobId = ''
        } else {
            try { $artifact.MaskedCount = [int]$result.MaskedCount } catch { $artifact.MaskedCount = 0 }
            $artifact.Version = 1
            $artifact.Status = 'ready'
            $artifact.Error = ''
        }
    } catch {
        if ($isRevision) {
            $artifact.RevisionStatus = 'error'
            $artifact.RevisionError = ([string]$_.Exception.Message + ' 現在の訳案は変わっていません。')
            $artifact.ActiveRevisionJobId = ''
        } else {
            $artifact.Status = 'error'
            $artifact.Error = [string]$_.Exception.Message
        }
    }
    return (Update-YakuQuickArtifactExpiry -Artifact $artifact)
}

function ConvertTo-YakuQuickArtifactView {
    param([AllowNull()]$Artifact, [switch]$IncludeContent)
    if ($null -eq $Artifact) { return $null }
    $view = [ordered]@{
        artifact_id = [string]$Artifact.Id
        status = [string]$Artifact.Status
        version = [int]$Artifact.Version
        revision_status = [string]$Artifact.RevisionStatus
        revision_error = [string]$Artifact.RevisionError
        masked_count = [int]$Artifact.MaskedCount
        direction = [string]$Artifact.Direction
        direction_basis = [string]$Artifact.DirectionBasis
        direction_confidence = [string]$Artifact.DirectionConfidence
        source_fingerprint = [string]$Artifact.SourceFingerprint
        expires_at = ([datetime]$Artifact.ExpiresAtUtc).ToString('o')
        error = [string]$Artifact.Error
        promoted_project_id = [string]$Artifact.PromotedProjectId
    }
    if ($IncludeContent) {
        $view['source_text'] = [string]$Artifact.SourceText
        $view['translation'] = [string]$Artifact.Translation
    }
    return [pscustomobject]$view
}

function Register-YakuQuickArtifactRevisionJob {
    param(
        [Parameter(Mandatory=$true)][string]$ArtifactId,
        [Parameter(Mandatory=$true)][int]$ExpectedVersion,
        [Parameter(Mandatory=$true)][string]$RequestId,
        [Parameter(Mandatory=$true)][string]$Instruction,
        [Parameter(Mandatory=$true)][string]$JobId
    )
    if ($RequestId -notmatch '^[a-f0-9]{32}$' -or $JobId -notmatch '^[a-f0-9]{32}$') { throw 'QUICK_REVISION_ID_INVALID' }
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.QuickArtifact.' + $ArtifactId))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'QUICK_ARTIFACT_LOCK_TIMEOUT' }
        $artifact = Get-YakuQuickArtifact -Id $ArtifactId -Touch
        if ($null -eq $artifact) { throw 'QUICK_ARTIFACT_NOT_FOUND_OR_EXPIRED' }
        $instructionHash = Get-YakuSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($Instruction))
        if ($artifact.RevisionRequests.ContainsKey($RequestId)) {
            $prior = $artifact.RevisionRequests[$RequestId]
            if ([string]$prior.InstructionHash -ne $instructionHash -or [int]$prior.ExpectedVersion -ne $ExpectedVersion) { throw 'QUICK_REVISION_REQUEST_ID_REUSED' }
            return [pscustomobject]@{ Artifact=$artifact; JobId=[string]$prior.JobId; Reused=$true }
        }
        if ([string]$artifact.Status -ne 'ready') { throw 'QUICK_ARTIFACT_NOT_READY' }
        if (-not [string]::IsNullOrWhiteSpace([string]$artifact.PromotedProjectId)) { throw 'QUICK_ARTIFACT_ALREADY_PROMOTED' }
        if ([string]$artifact.RevisionStatus -eq 'pending') { throw 'QUICK_ARTIFACT_REVISION_PENDING' }
        if ([int]$artifact.Version -ne $ExpectedVersion) { throw 'QUICK_REVISION_STALE_VERSION' }
        $artifact.RevisionRequests[$RequestId] = [pscustomobject]@{ InstructionHash=$instructionHash; ExpectedVersion=$ExpectedVersion; JobId=$JobId }
        $artifact.ActiveRevisionJobId = $JobId
        $artifact.ActiveRevisionBaseVersion = $ExpectedVersion
        $artifact.ActiveRevisionTranslationHash = Get-YakuSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes([string]$artifact.Translation))
        $artifact.RevisionStatus = 'pending'
        $artifact.RevisionError = ''
        $script:YakuQuickArtifactByJob[$JobId] = $ArtifactId
        $null = Update-YakuQuickArtifactExpiry -Artifact $artifact
        return [pscustomobject]@{ Artifact=$artifact; JobId=$JobId; Reused=$false }
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Invoke-YakuQuickArtifactPromotion {
    param(
        [Parameter(Mandatory=$true)][string]$ArtifactId,
        [Parameter(Mandatory=$true)][scriptblock]$Operation,
        [object[]]$Arguments = @()
    )
    if ($ArtifactId -notmatch '^[a-f0-9]{32}$') { throw 'QUICK_ARTIFACT_ID_INVALID' }
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.QuickArtifact.' + $ArtifactId))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'QUICK_ARTIFACT_LOCK_TIMEOUT' }
        $artifact = Get-YakuQuickArtifact -Id $ArtifactId -Touch
        if ($null -eq $artifact) { throw 'QUICK_ARTIFACT_NOT_FOUND_OR_EXPIRED' }
        if ([string]$artifact.RevisionStatus -eq 'pending') { throw 'QUICK_ARTIFACT_REVISION_PENDING' }
        if (-not [string]::IsNullOrWhiteSpace([string]$artifact.PromotedProjectId)) {
            return [pscustomobject]@{ Artifact=$artifact; ProjectId=[string]$artifact.PromotedProjectId; Reused=$true }
        }
        if ([string]$artifact.Status -ne 'ready') { throw 'QUICK_ARTIFACT_NOT_READY' }
        $project = & $Operation $artifact @Arguments
        if ($null -eq $project -or [string]$project.Id -notmatch '^[a-f0-9]{32}$') { throw 'QUICK_PROMOTION_COMMIT_INVALID' }
        # CAT の manifest commit と registry 差替えが完了して初めて記録する。
        $artifact.PromotedProjectId = [string]$project.Id
        $artifact.Status = 'promoted'
        $null = Update-YakuQuickArtifactExpiry -Artifact $artifact
        return [pscustomobject]@{ Artifact=$artifact; ProjectId=[string]$project.Id; Project=$project; Reused=$false }
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}
