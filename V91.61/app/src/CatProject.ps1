<#
  CAT: Excel を取り込み、セグメントで並べ、置換・翻訳・出力を段階に分ける。

  なぜ段階に分けるのか:

    ファイル翻訳の精度が低いもう半分の理由は、**途中が見えない**ことにある。
    出来上がった Excel が一見良さげに見えるので崩壊に気づけず、
    あとの修正作業が増える（利用者の診断 2026-08-06）。

    やることはファイル翻訳とほぼ同じである。違うのは、
      取り込む → 用語集で置換する → 残りを訳す → 出力する
    を1つの塊にせず、押した分だけ進み、左右に並べて見えるようにする点だけ。

  ここに無いもの:

    翻訳メモリ、確定の状態、事前翻訳の仕組みは入れない。
    まずは「ファイル翻訳と同じことが、確認しやすくなっただけ」を作る
    （利用者の判断 2026-08-06）。段階を分けておけば、あとから
    段階を足すのは easy になる。

  保持の仕方:

    プロジェクトはメモリに置く。作業中しか使わないので、保存の形を
    先に決めなくてよい。決めていない設計をファイルへ書き出すと、
    あとで移行が要る。
#>

# CatProject.ps1 is also loaded directly by focused regression tests and by
# maintenance scripts. Keep terminology QA available outside Server.ps1 too;
# merely having no registered terms must never turn into a blocking
# "terminology checker unavailable" result.
if (-not (Get-Command Test-YakuTerminologyCompliance -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Terminology.ps1')
}

$script:YakuCatProjects = [hashtable]::Synchronized(@{})

function Get-YakuCatSourceIntegrityHash {
    param([AllowNull()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-YakuCatQcContractVersion {
    return 'cat-qc-v3-terminology'
}

function Get-YakuCatTerminologyEntries {
    param([Parameter(Mandatory=$true)]$Project)
    if (-not (Get-Command Read-YakuTerminologyEntries -ErrorAction SilentlyContinue)) { return @() }
    # Reading a project that has never used terminology is side-effect free.
    # In particular, focused tests and read-only recovery must not create the
    # per-user data directory merely to discover that there are no terms.
    $dataRoot = [string]$env:YAKULINGO_DATA_DIR
    if ([string]::IsNullOrWhiteSpace($dataRoot)) {
        $profile = [Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($profile)) { $profile = [string]$env:USERPROFILE }
        if (-not [string]::IsNullOrWhiteSpace($profile)) { $dataRoot = Join-Path $profile '.yakulingo-ps' }
    }
    if (-not [string]::IsNullOrWhiteSpace($dataRoot)) {
        $termStore = Join-Path $dataRoot 'terminology\personal-v2.jsonl'
        $legacyStore = Join-Path $dataRoot 'glossary\personal.csv'
        if (-not (Test-Path -LiteralPath $termStore -PathType Leaf) -and -not (Test-Path -LiteralPath $legacyStore -PathType Leaf)) {
            $emptyTerminologyHash = Get-YakuTerminologySnapshotHash -Entries @()
            if (-not [string]::IsNullOrWhiteSpace([string]$Project.TerminologySnapshotHash) -and [string]$Project.TerminologySnapshotHash -ne [string]$emptyTerminologyHash) { throw 'CAT_TERMINOLOGY_STORE_MISSING' }
            return @()
        }
    }
    try {
        if (Get-Command Read-YakuPersonalTerminologyEntries -ErrorAction SilentlyContinue) {
            return @(Read-YakuPersonalTerminologyEntries -ProjectId ([string]$Project.Id) -Strict)
        }
        return @(Read-YakuTerminologyEntries -ProjectId ([string]$Project.Id) -Strict)
    } catch { throw ('CAT_TERMINOLOGY_STORE_UNAVAILABLE:' + [string]$_.Exception.Message) }
}

function Get-YakuCatTerminologySnapshotHash {
    param([Parameter(Mandatory=$true)]$Project)
    if (-not (Get-Command Get-YakuTerminologySnapshotHash -ErrorAction SilentlyContinue)) { return '' }
    return [string](Get-YakuTerminologySnapshotHash -Entries @(Get-YakuCatTerminologyEntries -Project $Project))
}

function ConvertTo-YakuCanonicalNumericScalar {
    param([AllowNull()][string]$Text)
    $s = (ConvertTo-YakuMaskNormalizedText -Text ([string]$Text)).Trim()
    [decimal]$number = 0
    if ([decimal]::TryParse($s.Replace(',',''), [Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return [pscustomobject]@{ Ok=$true; Value=$number; IncludesScale=$false }
    }
    $jp = ConvertFrom-YakuJapaneseNumberText -Text $s
    if ([bool]$jp.Ok) { return [pscustomobject]@{ Ok=$true; Value=[decimal]$jp.Value; IncludesScale=$true } }
    $en = ConvertFrom-YakuEnglishNumberText -Text $s
    if ([bool]$en.Ok) {
        $hasScale = ($s -match '(?i)\b(?:hundred|thousand|million|billion|trillion)\b')
        return [pscustomobject]@{ Ok=$true; Value=[decimal]$en.Value; IncludesScale=$hasScale }
    }
    return [pscustomobject]@{ Ok=$false; Value=[decimal]0; IncludesScale=$false }
}

function Get-YakuCanonicalNumericFacts {
    <#
      数値マスキングと同じ分類器で対象を拾い、値・単位・通貨・符号を比較可能な
      形へする。漢数字、大字、英語の綴り数も同じ入口を通る。
    #>
    param(
        [AllowNull()][string]$Text,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$Location = 'cat-qc'
    )
    $source = [string]$Text
    $mask = New-YakuNumericMaskMap -Text $source -Direction $Direction -Location $Location
    $masked = [string]$mask.Text
    $facts = New-Object System.Collections.Generic.List[object]
    foreach ($token in @($mask.Map.Keys | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })) {
        $raw = [string]$mask.Map[$token]
        $scalar = ConvertTo-YakuCanonicalNumericScalar -Text $raw
        if (-not [bool]$scalar.Ok) { throw ('CAT_NUMERIC_FACT_UNPARSEABLE:' + $raw) }
        $at = $masked.IndexOf([string]$token, [StringComparison]::Ordinal)
        if ($at -lt 0) { throw ('CAT_NUMERIC_FACT_TOKEN_MISSING:' + [string]$token) }
        $before = $masked.Substring([Math]::Max(0,$at-24), [Math]::Min(24,$at))
        $afterStart = $at + ([string]$token).Length
        $after = $masked.Substring($afterStart, [Math]::Min(40,$masked.Length-$afterStart))
        $context = ($before + '|' + $after)
        $descriptor=Get-YakuNumericContextDescriptor -Text $masked -Token ([string]$token) -Start $at
        [decimal]$scale = $(if([bool]$scalar.IncludesScale){[decimal]1}else{[decimal]$descriptor.Scale})
        [decimal]$value = [decimal]$scalar.Value * $scale
        $category = 'number'
        if ([string]$descriptor.Currency -eq 'yen') { $category='currency:yen' }
        elseif ([string]$descriptor.Currency -eq 'dollar') { $category='currency:dollar' }
        elseif ([string]$descriptor.Currency -eq 'euro') { $category='currency:euro' }
        elseif ([string]$descriptor.Currency -eq 'pound') { $category='currency:pound' }
        elseif ($after -match '^\s*\)?\s*(?:%|％|percent\b|percentage\b)') { $category='ratio:percent' }
        # units? も同じ理由で \b が使えない。「186 k unitsでした」のように
        # 日本語が続くと境界ができないため、英数字が続かないことで判定する。
        elseif ($after -match '(?i)^\s*\)?\s*(?:k\s+)?units?(?![A-Za-z0-9])|^\s*\)?\s*(?:台|件|人|名|株|個|本|回|ポイント)') { $category='count' }
        $negative = ($before -match '(?:[-−△▲]\s*|\(\s*)$')
        if ($negative -and $value -gt 0) { $value = -$value }
        $canonical = $value.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture)
        $magnitude=[Math]::Abs($value).ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture)
        # 金額の絶対量と、△・括弧・minus/decrease等で表す方向は別に検査する。
        # Keyへ符号を混ぜると「△100」→"decreased by 100"を誤って拒否する。
        $facts.Add([pscustomobject]@{ Token=[string]$token; Raw=$raw; Category=$category; Value=$canonical; Magnitude=$magnitude; ExplicitNegative=[bool]$negative; Key=($category + '|' + $magnitude) }) | Out-Null
    }
    return @($facts.ToArray())
}

function Reset-YakuCatSegmentQc {
    param([Parameter(Mandatory=$true)]$Segment, [switch]$KeepState)
    $Segment | Add-Member -NotePropertyName QcStatus -NotePropertyValue 'not_run' -Force
    $Segment | Add-Member -NotePropertyName QcSourceRevision -NotePropertyValue 0 -Force
    $Segment | Add-Member -NotePropertyName QcSourceHash -NotePropertyValue '' -Force
    $Segment | Add-Member -NotePropertyName QcTargetHash -NotePropertyValue '' -Force
    $Segment | Add-Member -NotePropertyName QcContractVersion -NotePropertyValue '' -Force
    $Segment | Add-Member -NotePropertyName QcTerminologyHash -NotePropertyValue '' -Force
    $Segment | Add-Member -NotePropertyName QcFindings -NotePropertyValue @() -Force
    $Segment | Add-Member -NotePropertyName Confirmed -NotePropertyValue $false -Force
    if (-not $KeepState -and [string]$Segment.State -eq 'reviewed') {
        $Segment.State = if ([string]::IsNullOrWhiteSpace([string]$Segment.Translation)) { 'untranslated' } elseif ([string]$Segment.Origin -eq 'manual') { 'human_edited' } else { 'machine_draft' }
    }
}

function Test-YakuCatSegmentQcCurrent {
    param([Parameter(Mandatory=$true)]$Segment, [AllowNull()][string]$TerminologySnapshotHash)
    if ([string]$Segment.QcStatus -ne 'passed') { return $false }
    if ([int]$Segment.QcSourceRevision -ne [int]$Segment.SourceRevision) { return $false }
    if ([string]$Segment.QcContractVersion -ne (Get-YakuCatQcContractVersion)) { return $false }
    if ([string]$Segment.QcSourceHash -ne (Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Text))) { return $false }
    if ([string]$Segment.QcTargetHash -ne (Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation))) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($TerminologySnapshotHash) -and [string]$Segment.QcTerminologyHash -ne $TerminologySnapshotHash) { return $false }
    return $true
}

function Test-YakuCatTranslationInvalid {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [AllowNull()][string]$Translation,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    if ([string]::IsNullOrWhiteSpace($Translation)) { return $true }
    $target = ([string]$Translation).Trim()
    if ($target -eq ([string]$Source).Trim()) { return $true }
    if ($target -match '(?i)\b(i\s+cannot|i\s+can''t|unable\s+to|as\s+an\s+ai|sign\s+in|log\s*in|required\s+login|content\s+policy|against\s+(?:the\s+)?policy|due\s+to\s+(?:the\s+)?policy|policy\s+(?:prevents|does\s+not\s+allow))\b|申し訳|ログインしてください|対応できません') { return $true }
    if ($Direction -eq 'to_en') {
        $jp = [regex]::Matches($target, '[ぁ-んァ-ヶ一-龯]').Count
        $latin = [regex]::Matches($target, '[A-Za-z]').Count
        if ($jp -gt 0 -and ($latin -le 0 -or ($jp / [double][Math]::Max(1, $jp + $latin)) -gt 0.20)) { return $true }
        if ($target -match '[가-힣]') { return $true }
    }
    if ($Direction -eq 'to_jp' -and $Source -match '[A-Za-z]' -and $target -notmatch '[ぁ-んァ-ヶ一-龯]' -and [regex]::Matches($target, '[A-Za-z]').Count -ge 4) { return $true }
    return $false
}

function Get-YakuCatAuditableNumericValueCount {
    param(
        [AllowNull()][string]$Text,
        [ValidateSet('source','target')][string]$Side = 'target'
    )
    $normalized = ConvertTo-YakuMaskNormalizedText -Text ([string]$Text)
    $protected = @()
    if ($Side -eq 'source') {
        # 決算期・年度・四半期・条番号などは翻訳後に別表記となり得る。
        # 数値機密の監査対象とは分け、金額・比率・数量の欠落だけを数える。
        $protected = @(Get-YakuNumericMaskProtectedSpans -Text ([string]$Text) -Direction 'to_en')
    }
    $count = 0
    foreach ($match in [regex]::Matches($normalized, '(?<![A-Za-z0-9])\d[\d,]*(?:\.\d+)?')) {
        if ($Side -eq 'source' -and (Test-YakuMaskSpanCovered -Spans $protected -Start $match.Index -End ($match.Index + $match.Length))) { continue }
        $count++
    }
    return $count
}

function Get-YakuCatAuditableNumericValues {
    param(
        [AllowNull()][string]$Text,
        [ValidateSet('source','target')][string]$Side,
        [ValidateSet('to_en','to_jp')][string]$Direction
    )
    $value = ConvertTo-YakuMaskNormalizedText -Text ([string]$Text)
    if ($Side -eq 'source' -or $Side -eq 'target') {
        try {
            $chars = $value.ToCharArray()
            foreach ($span in @(Get-YakuNumericMaskProtectedSpans -Text $value -Direction $Direction)) {
                for ($i = [int]$span.Start; $i -lt [int]$span.End -and $i -lt $chars.Length; $i++) { $chars[$i] = ' ' }
            }
            $value = -join $chars
        } catch {}
        if ($Side -eq 'source' -and $Direction -eq 'to_en') {
            try { $value = [string](Convert-YakuNumericUnits -Text $value -Location 'cat-review-values').Text } catch {}
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($value, '(?<![A-Za-z0-9])[-+]?(?:\d[\d,]*)(?:\.\d+)?')) {
        $canonical = ([string]$match.Value).Replace(',','')
        $number = [decimal]0
        if ([decimal]::TryParse($canonical, [Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            $out.Add($number.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture)) | Out-Null
        }
    }
    return @($out.ToArray())
}

function Initialize-YakuCatProjectState {
    param([Parameter(Mandatory=$true)]$Project)
    if (-not ($Project.PSObject.Properties.Name -contains 'Revision')) { $Project | Add-Member -NotePropertyName Revision -NotePropertyValue 0 -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'SchemaVersion')) { $Project | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue 2 -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DirectionBasis')) { $Project | Add-Member -NotePropertyName DirectionBasis -NotePropertyValue 'fixed' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DirectionConfidence')) { $Project | Add-Member -NotePropertyName DirectionConfidence -NotePropertyValue 'not_applicable' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DirectionSourceFingerprint')) { $Project | Add-Member -NotePropertyName DirectionSourceFingerprint -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'QuickArtifactId')) { $Project | Add-Member -NotePropertyName QuickArtifactId -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'TerminologySnapshotHash')) { $Project | Add-Member -NotePropertyName TerminologySnapshotHash -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'TmOutbox')) { $Project | Add-Member -NotePropertyName TmOutbox -NotePropertyValue @() -Force }
    foreach ($segment in @($Project.Segments)) {
        if (-not ($segment.PSObject.Properties.Name -contains 'SegmentId') -or [string]::IsNullOrWhiteSpace([string]$segment.SegmentId)) {
            $segment | Add-Member -NotePropertyName SegmentId -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
        }
        if (-not ($segment.PSObject.Properties.Name -contains 'SourceRevision')) { $segment | Add-Member -NotePropertyName SourceRevision -NotePropertyValue 1 -Force }
        $hash = Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Text)
        if (-not ($segment.PSObject.Properties.Name -contains 'SourceIntegrityHash') -or [string]::IsNullOrWhiteSpace([string]$segment.SourceIntegrityHash)) { $segment | Add-Member -NotePropertyName SourceIntegrityHash -NotePropertyValue $hash -Force }
        elseif ([string]$segment.SourceIntegrityHash -ne $hash) {
            $segment.SourceRevision = [int]$segment.SourceRevision + 1
            $segment.SourceIntegrityHash = $hash
            $segment | Add-Member -NotePropertyName State -NotePropertyValue 'stale' -Force
            $segment | Add-Member -NotePropertyName QcStatus -NotePropertyValue 'not_run' -Force
        }
        if (-not ($segment.PSObject.Properties.Name -contains 'State') -or [string]::IsNullOrWhiteSpace([string]$segment.State)) {
            $state = if ([string]::IsNullOrWhiteSpace([string]$segment.Translation)) { 'untranslated' } elseif ([bool]$segment.Confirmed) { 'reviewed' } elseif ([string]$segment.Origin -eq 'manual') { 'human_edited' } else { 'machine_draft' }
            $segment | Add-Member -NotePropertyName State -NotePropertyValue $state -Force
        }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcStatus') -or [string]::IsNullOrWhiteSpace([string]$segment.QcStatus)) { $segment | Add-Member -NotePropertyName QcStatus -NotePropertyValue 'not_run' -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcSourceRevision')) { $segment | Add-Member -NotePropertyName QcSourceRevision -NotePropertyValue 0 -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcSourceHash')) { $segment | Add-Member -NotePropertyName QcSourceHash -NotePropertyValue '' -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcTargetHash')) { $segment | Add-Member -NotePropertyName QcTargetHash -NotePropertyValue '' -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcContractVersion')) { $segment | Add-Member -NotePropertyName QcContractVersion -NotePropertyValue '' -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcTerminologyHash')) { $segment | Add-Member -NotePropertyName QcTerminologyHash -NotePropertyValue '' -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'QcFindings')) { $segment | Add-Member -NotePropertyName QcFindings -NotePropertyValue @() -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'ReferenceUsage')) { $segment | Add-Member -NotePropertyName ReferenceUsage -NotePropertyValue $null -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'ReferenceEvents')) { $segment | Add-Member -NotePropertyName ReferenceEvents -NotePropertyValue @() -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'TerminologyUsages')) { $segment | Add-Member -NotePropertyName TerminologyUsages -NotePropertyValue @() -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'TerminologyExceptions')) { $segment | Add-Member -NotePropertyName TerminologyExceptions -NotePropertyValue @() -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'TerminologyGeneration')) { $segment | Add-Member -NotePropertyName TerminologyGeneration -NotePropertyValue @() -Force }
        if ([string]$segment.QcStatus -eq 'passed' -and -not (Test-YakuCatSegmentQcCurrent -Segment $segment)) {
            Reset-YakuCatSegmentQc -Segment $segment
        }
        $segment | Add-Member -NotePropertyName Confirmed -NotePropertyValue ([string]$segment.State -eq 'reviewed') -Force
    }
    $currentTerminologyHash = Get-YakuCatTerminologySnapshotHash -Project $Project
    if (-not [string]::IsNullOrWhiteSpace($currentTerminologyHash)) {
        $storedTerminologyHash = [string]$Project.TerminologySnapshotHash
        if (-not [string]::IsNullOrWhiteSpace($storedTerminologyHash) -and $storedTerminologyHash -ne $currentTerminologyHash) {
            $currentEntries = @(Get-YakuCatTerminologyEntries -Project $Project)
            foreach ($segment in @($Project.Segments)) {
                if ([string]$segment.QcStatus -ne 'passed' -and -not [bool]$segment.Confirmed) { continue }
                $matches = @(Find-YakuTerminologyMatches -Text ([string]$segment.Text) -Direction ([string]$Project.Direction) -Entries $currentEntries -ProjectId ([string]$Project.Id))
                if ($matches.Count -eq 0) { continue }
                Reset-YakuCatSegmentQc -Segment $segment
                $segment.State = 'stale'
            }
        }
        $Project.TerminologySnapshotHash = $currentTerminologyHash
    }
    return $Project
}

function Copy-YakuCatProjectForMutation {
    <# Project は入れ子の可変 PSObject であるため、浅い Select-Object では
       Segments/Blocks を共有してしまう。PowerShell 自身の serializer で完全に
       独立した candidate を作り、保存成功前の共有状態を触らない。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $serialized = [System.Management.Automation.PSSerializer]::Serialize($Project, 50)
    $candidate = [System.Management.Automation.PSSerializer]::Deserialize($serialized)
    return (Initialize-YakuCatProjectState -Project $candidate)
}

function Invoke-YakuCatProjectLock {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][scriptblock]$Operation,
        [object[]]$Arguments = @()
    )
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'CAT_PROJECT_ID_REQUIRED' }
    $safeId = [regex]::Replace($ProjectId, '[^A-Za-z0-9_.-]', '_')
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.CatProject.' + $safeId))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'CAT_PROJECT_LOCK_TIMEOUT: 作業の更新待ちがタイムアウトしました。' }
        return (& $Operation @Arguments)
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Invoke-YakuCatProjectMutation {
    <# ExpectedRevision の確認、candidate への変更、世代/manifest 保存、registry
       差替えを同じ project lock 内で行う。Mutation は共有 Project を受け取らない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][int]$ExpectedRevision,
        [Parameter(Mandatory=$true)][scriptblock]$Mutation,
        [object[]]$Arguments = @()
    )
    $state = [pscustomobject]@{
        ProjectId = $ProjectId
        ExpectedRevision = $ExpectedRevision
        Mutation = $Mutation
        Arguments = @($Arguments)
    }
    $operation = {
        param($innerState)
        $id = [string]$innerState.ProjectId
        if (-not $script:YakuCatProjects.ContainsKey($id)) {
            throw 'CAT_PROJECT_NOT_FOUND: 作業が見つかりません。'
        }
        $committed = $script:YakuCatProjects[$id]
        if ([int]$committed.Revision -ne [int]$innerState.ExpectedRevision) {
            throw 'CAT_PROJECT_REVISION_CONFLICT: 別の操作で作業内容が更新されました。最新状態を読み込んでからやり直してください。'
        }
        $candidate = Copy-YakuCatProjectForMutation -Project $committed
        $mutationArguments = @($innerState.Arguments)
        $mutationResult = & $innerState.Mutation $candidate @mutationArguments
        if (-not (Save-YakuCatProject -Project $candidate)) {
            throw 'CAT_PROJECT_SAVE_FAILED: 作業内容を保存できませんでした。'
        }
        $script:YakuCatProjects[$id] = $candidate
        return [pscustomobject]@{ Project=$candidate; Result=$mutationResult }
    }
    return (Invoke-YakuCatProjectLock -ProjectId $ProjectId -Operation $operation -Arguments @($state))
}

function Commit-YakuNewCatProject {
    <# 旧factoryは互換性のため生成時登録を続けるが、Serverからの新規作成は
       この境界を使い、永続化できなかったProjectをregistryへ残さない。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $projectId = [string]$Project.Id
    $state = [pscustomobject]@{ Project=$Project; ProjectId=$projectId }
    $operation = {
        param($innerState)
        $id = [string]$innerState.ProjectId
        $newProject = $innerState.Project
        if ($script:YakuCatProjects.ContainsKey($id)) {
            $registered = $script:YakuCatProjects[$id]
            if (-not [object]::ReferenceEquals($registered, $newProject)) {
                throw 'CAT_PROJECT_ID_CONFLICT: 同じIDの作業がすでにあります。'
            }
            $script:YakuCatProjects.Remove($id)
        }
        $candidate = Copy-YakuCatProjectForMutation -Project $newProject
        if (-not (Save-YakuCatProject -Project $candidate)) {
            # newProject は未コミットなので戻さない。呼出側へIDを返す前に破棄する。
            throw 'CAT_PROJECT_SAVE_FAILED: 作業内容を保存できませんでした。'
        }
        $script:YakuCatProjects[$id] = $candidate
        return $candidate
    }
    return (Invoke-YakuCatProjectLock -ProjectId $projectId -Operation $operation -Arguments @($state))
}

function Invoke-YakuCatSegmentValidation {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Segment
    )
    $findings = New-Object System.Collections.Generic.List[object]
    $source = [string]$Segment.Text
    $target = [string]$Segment.Translation
    if ([string]::IsNullOrWhiteSpace($target)) { $findings.Add([pscustomobject]@{ Code='empty'; Severity='error' }) | Out-Null }
    elseif (Test-YakuCatTranslationInvalid -Source $source -Translation $target -Direction ([string]$Project.Direction)) {
        $findings.Add([pscustomobject]@{ Code='invalid-or-source-fallback'; Severity='error' }) | Out-Null
    }
    if ($target -match '\[\[(?:N|P)\d+\]\]') { $findings.Add([pscustomobject]@{ Code='placeholder-residue'; Severity='error' }) | Out-Null }

    # 利用者が登録した固定訳（cell_exact）を、アプリがセル丸ごと一字一句そのまま入れた場合だけ、
    # 数値の増減チェックを外す。
    #
    # 決算の略語は原文に無い数字を持つ（上期→1H、第1四半期→Q1、2026年度→FY26）。
    # これを numeric-value-extra で弾くと、§8「略語は一覧にあるものだけをアプリが当てる」で
    # 登録した訳が、そのまま確認済みにできなくなる。
    #
    # 外すのは「利用者が登録し、アプリが機械的に写した訳」に限る。Copilotの訳文や、
    # 人が編集した訳文は1文字でも違えば一致しないので、従来どおり全部検査される。
    $isVerbatimRegisteredTerm = $false
    if (-not [string]::IsNullOrWhiteSpace($target)) {
        try {
            $cellExact = Find-YakuCellExactTerminologyMatch -Text $source -Direction ([string]$Project.Direction) `
                -Entries @(Get-YakuCatTerminologyEntries -Project $Project) -ProjectId ([string]$Project.Id)
            if ($null -ne $cellExact) {
                $normalizeForCompare = {
                    param([AllowNull()][string]$Value)
                    $text = ([string]$Value).Normalize([Text.NormalizationForm]::FormKC).Trim()
                    return (($text -replace '\s+', ' ').ToLowerInvariant())
                }
                $isVerbatimRegisteredTerm = ((& $normalizeForCompare $target) -eq (& $normalizeForCompare ([string]$cellExact.Target)))
            }
        } catch { $isVerbatimRegisteredTerm = $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($target) -and -not $isVerbatimRegisteredTerm) {
        try {
            $normalizedSource = if ([string]$Project.Direction -eq 'to_en') { [string](Convert-YakuNumericUnits -Text $source -Location ('cat-review-' + [string]$Segment.SegmentId)).Text } else { $source }
            $audit = Test-YakuNumericIntegrity -SourceText $normalizedSource -TranslatedText $target -Location ('cat-review-' + [string]$Segment.SegmentId)
            if (-not [bool]$audit.Ok) { $findings.Add([pscustomobject]@{ Code='numeric-integrity'; Severity='error'; Detail=[string]$audit.Detail }) | Out-Null }
            # 突き合わせにも単位変換後の原文を使う。443行の $audit だけが変換を通っていて、
            # ここが生の原文のままだった。そのため「1兆3,150億円」が 1 と 3,150 に割れ、
            # アプリ自身が正しく換算した「13,150 oku」を、アプリ自身が
            # numeric-value-mismatch と numeric-value-extra で拒否していた。
            # 兆を含む金額は有報・短信で頻出し、その行は確認済みにできなかった。
            $targetDirection = if ([string]$Project.Direction -eq 'to_en') { 'to_jp' } else { 'to_en' }
            # 単位変換は原文を訳文側の表記（13,150 oku）へ書き換える。だから分類も
            # 訳文と同じ側で行う。原文側だけ日本語向けの分類にすると、同じ
            # 「13,150 oku」が原文では number|13150、訳文では currency:yen|1315000000000 になり、
            # 一致しなくなる。
            $sourceFactsDirection = if ([string]$Project.Direction -eq 'to_en') { $targetDirection } else { [string]$Project.Direction }
            $sourceFacts = @(Get-YakuCanonicalNumericFacts -Text $normalizedSource -Direction $sourceFactsDirection -Location ('cat-review-source-' + [string]$Segment.SegmentId))
            $sourceValues = @($sourceFacts | ForEach-Object { [string]$_.Key })
            $targetFacts = @(Get-YakuCanonicalNumericFacts -Text $target -Direction $targetDirection -Location ('cat-review-target-' + [string]$Segment.SegmentId))
            $targetValues = @($targetFacts | ForEach-Object { [string]$_.Key })
            $remaining = New-Object System.Collections.Generic.List[string]
            foreach ($v in $targetValues) { $remaining.Add([string]$v) | Out-Null }
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($v in $sourceValues) {
                $pos = $remaining.IndexOf([string]$v)
                if ($pos -ge 0) { $remaining.RemoveAt($pos) } else { $missing.Add([string]$v) | Out-Null }
            }
            if ($missing.Count -gt 0) { $findings.Add([pscustomobject]@{ Code='numeric-value-mismatch'; Severity='error'; Detail=('missing=' + ($missing.ToArray() -join ',')) }) | Out-Null }
            if ($remaining.Count -gt 0) { $findings.Add([pscustomobject]@{ Code='numeric-value-extra'; Severity='error'; Detail=('extra=' + ($remaining.ToArray() -join ',')) }) | Out-Null }
            # 英語では「2027年度第1四半期」を FY2027 Q1 / Q1 of FY2027 の
            # どちらにも自然に並べられる。期間値は存在・個数を上で厳密に検査し、
            # 順序検査からだけ除外する。金額など残りの数値順序は維持する。
            $orderSource = New-Object System.Collections.Generic.List[string]
            $orderTarget = New-Object System.Collections.Generic.List[string]
            foreach($v in $sourceValues){$orderSource.Add([string]$v)|Out-Null}
            foreach($v in $targetValues){$orderTarget.Add([string]$v)|Out-Null}
            if([string]$Project.Direction -eq 'to_en'){
                # 会計期は英語で語順が変わる。「2027年度第1四半期」だけでなく
                # 「2027年3月期 第1四半期」も同じ形なので、両方を順序比較から外す。
                # マスク側（Get-YakuFiscalPeriodMaskTokens）と対になる規則。
                $periodPatterns=@(
                    '(?<year>\d{4})\s*年度\s*第\s*(?<quarter>[1-4])\s*四半期',
                    '(?<year>\d{4})\s*年\s*(?:\d{1,2})\s*月期\s*第\s*(?<quarter>[1-4])\s*四半期'
                )
                foreach($periodMatch in @($periodPatterns | ForEach-Object { [regex]::Matches($source,$_) } | ForEach-Object { $_ })){
                    $year=[string]$periodMatch.Groups['year'].Value;$quarter=[string]$periodMatch.Groups['quarter'].Value
                    if([string]::IsNullOrWhiteSpace($year) -or [string]::IsNullOrWhiteSpace($quarter)){continue}
                    $hasYear=($target -match ('(?i)(?:\bFY\s*'+[regex]::Escape($year)+'\b|\b'+[regex]::Escape($year)+'\s+(?:fiscal\s+year|fiscal-year)\b)'))
                    $hasQuarter=($target -match ('(?i)(?:\bQ\s*'+[regex]::Escape($quarter)+'\b|\b'+[regex]::Escape($quarter)+'(?:st|nd|rd|th)?\s+quarter\b)'))
                    if($hasYear -and $hasQuarter){
                        foreach($key in @((('number|'+$year)),(('number|'+$quarter)))){
                            $p=$orderSource.IndexOf($key);if($p -ge 0){$orderSource.RemoveAt($p)}
                            $p=$orderTarget.IndexOf($key);if($p -ge 0){$orderTarget.RemoveAt($p)}
                        }
                    }
                }
            }
            if($missing.Count -eq 0 -and $remaining.Count -eq 0 -and $orderSource.Count -gt 1 -and $orderSource.Count -eq $orderTarget.Count){
                $sameOrder=$true
                for($i=0;$i -lt $orderSource.Count;$i++){
                    if([string]$orderSource[$i] -ne [string]$orderTarget[$i]){$sameOrder=$false;break}
                }
                if(-not $sameOrder){$findings.Add([pscustomobject]@{Code='numeric-value-order-mismatch';Severity='error';Detail='数値の順序が原文と一致しません。'})|Out-Null}
            }
        } catch { $findings.Add([pscustomobject]@{ Code='numeric-validation-error'; Severity='error' }) | Out-Null }
    }
    if (-not $isVerbatimRegisteredTerm -and ($source -match '[△▲]' -or $source -match '\(\s*[-+]?\d[\d,.]*\s*\)') -and $target -notmatch '(?i)(?:^|[\s(])[-−]|loss|decrease|decline|deficit|negative|損失|減少|赤字|マイナス|△|▲') {
        $findings.Add([pscustomobject]@{ Code='numeric-sign-missing'; Severity='error' }) | Out-Null
    }
    if (-not $isVerbatimRegisteredTerm -and [string]$Project.Direction -eq 'to_jp') {
        foreach ($match in [regex]::Matches($source, '(?i)(?<num>\d[\d,]*(?:\.\d+)?)\s+(?<unit>million|billion)\b')) {
            $n = [decimal]0
            if (-not [decimal]::TryParse(([string]$match.Groups['num'].Value).Replace(',',''), [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { continue }
            $expectedMillion = if ([string]$match.Groups['unit'].Value -ieq 'billion') { $n * 1000 } else { $n }
            $magnitudeMatches = @([regex]::Matches($target, '(?<num>\d[\d,]*(?:\.\d+)?)\s*(?<unit>億|百万)'))
            $hasExpected = $false
            foreach ($magnitude in $magnitudeMatches) {
                $actual = [decimal]0
                if (-not [decimal]::TryParse(([string]$magnitude.Groups['num'].Value).Replace(',',''), [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$actual)) { continue }
                $actualMillion = if ([string]$magnitude.Groups['unit'].Value -eq '億') { $actual * 100 } else { $actual }
                if ($actualMillion -eq $expectedMillion) { $hasExpected = $true; break }
            }
            if (-not $hasExpected) { $findings.Add([pscustomobject]@{ Code='numeric-scale-mismatch'; Severity='error'; Detail=('expected_million=' + $expectedMillion) }) | Out-Null }
        }
    }
    $sourceNegative = $source -match '(?i)\b(?:loss|deficit|decrease|decline|decreased|declined|fell)\b|損失|赤字|減少|減益|下落'
    $sourcePositive = $source -match '(?i)\b(?:profit|surplus|increase|increased|gain|gained|rose)\b|利益|黒字|増加|増益|上昇'
    $targetNegative = $target -match '(?i)\b(?:loss|deficit|decrease|decline|decreased|declined|fell)\b|損失|赤字|減少|減益|下落'
    $targetPositive = $target -match '(?i)\b(?:profit|surplus|increase|increased|gain|gained|rose)\b|利益|黒字|増加|増益|上昇'
    if (($sourceNegative -and $targetPositive -and -not $targetNegative) -or ($sourcePositive -and $targetNegative -and -not $targetPositive)) {
        $findings.Add([pscustomobject]@{ Code='accounting-polarity-mismatch'; Severity='error' }) | Out-Null
    }
    # `oku` は本アプリの英訳で 1億円を表す単位であり、数値fact抽出でも
    # yen として扱う。ここだけ単純な文字列検査で落とすと、正しい
    # `1,234 oku` を確認済みにできない。
    if (-not $isVerbatimRegisteredTerm -and $source -match '(?i)(?:円|\byen\b|\boku\b)' -and $target -notmatch '(?i)(?:円|\byen\b|\boku\b)') { $findings.Add([pscustomobject]@{ Code='currency-mismatch'; Severity='error'; Detail='yen' }) | Out-Null }
    if (-not $isVerbatimRegisteredTerm -and $source -match '(?i)(?:ドル|\bdollars?\b|\$)' -and $target -notmatch '(?i)(?:ドル|\bdollars?\b|\$)') { $findings.Add([pscustomobject]@{ Code='currency-mismatch'; Severity='error'; Detail='dollar' }) | Out-Null }
    try {
        $structure = Test-YakuTextStructureIntegrity -SourceText $source -FullText $target -BriefText $target
        if (-not [bool]$structure.Ok) { $findings.Add([pscustomobject]@{ Code='structure-integrity'; Severity='error'; Detail=[string]$structure.Detail }) | Out-Null }
    } catch { $findings.Add([pscustomobject]@{ Code='structure-validation-error'; Severity='error' }) | Out-Null }
    $terminologyHash = ''
    try {
        $entries = @(Get-YakuCatTerminologyEntries -Project $Project)
        $terminology = Test-YakuTerminologyCompliance -SourceText $source -TargetText $target -Direction ([string]$Project.Direction) `
            -Entries $entries -Exceptions @($Segment.TerminologyExceptions) -ProjectId ([string]$Project.Id)
        $terminologyHash = [string]$terminology.SnapshotHash
        foreach ($finding in @($terminology.Findings)) {
            # 有効な明示例外は監査情報としてsegmentに残すが、QC blockerにはしない。
            if ([string]$finding.Severity -eq 'info') { continue }
            $findings.Add($finding) | Out-Null
        }
    } catch {
        $findings.Add([pscustomobject]@{ Code='terminology-check-unavailable'; Severity='error'; Detail=[string]$_.Exception.Message }) | Out-Null
    }
    $blocking = @($findings.ToArray() | Where-Object { [string]$_.Severity -eq 'error' })
    $status = if ($blocking.Count -eq 0) { 'passed' } else { 'failed' }
    $Segment.QcStatus = $status
    $Segment.QcSourceRevision = [int]$Segment.SourceRevision
    $Segment | Add-Member -NotePropertyName QcSourceHash -NotePropertyValue (Get-YakuCatSourceIntegrityHash -Text $source) -Force
    $Segment | Add-Member -NotePropertyName QcTargetHash -NotePropertyValue (Get-YakuCatSourceIntegrityHash -Text $target) -Force
    $Segment | Add-Member -NotePropertyName QcContractVersion -NotePropertyValue (Get-YakuCatQcContractVersion) -Force
    $Segment | Add-Member -NotePropertyName QcTerminologyHash -NotePropertyValue $terminologyHash -Force
    $Segment.QcFindings = @($findings.ToArray())
    return [pscustomobject]@{ Passed=($status -eq 'passed'); Status=$status; Findings=@($findings.ToArray()) }
}

function Get-YakuCatOutputEligibility {
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $reasons = New-Object System.Collections.Generic.List[string]
    if (@($Project.Segments).Count -eq 0) { $reasons.Add('project-empty') | Out-Null }
    foreach ($segment in @($Project.Segments)) {
        if ([string]$segment.State -ne 'reviewed') { $reasons.Add('segment-not-reviewed') | Out-Null; break }
        if (-not (Test-YakuCatSegmentQcCurrent -Segment $segment -TerminologySnapshotHash ([string]$Project.TerminologySnapshotHash))) { $reasons.Add('segment-qc-not-current') | Out-Null; break }
        if ([string]::IsNullOrWhiteSpace([string]$segment.Translation)) { $reasons.Add('segment-untranslated') | Out-Null; break }
    }
    $translationList = ($reasons.Count -eq 0)
    $sourceReady = [string]$Project.Source -eq 'file' -and (Test-Path -LiteralPath ([string]$Project.Path) -PathType Leaf)
    $documentFormat = $(try { [string]$Project.DocumentFormat } catch { '' })
    if ([string]::IsNullOrWhiteSpace($documentFormat) -and [string]$Project.Source -eq 'file') { $documentFormat = [IO.Path]::GetExtension([string]$Project.Path).TrimStart('.').ToLowerInvariant() }
    $excelDraft = $translationList -and $sourceReady -and $documentFormat -in @('xlsx','xlsm','csv')
    $wordStructureReady = $false
    if ($documentFormat -eq 'docx') {
        try { $wordStructureReady = [bool]$Project.WordInventory.DraftStructureEligible -and [string]$Project.WordInventory.ContractVersion -eq 'word-adapter-v1' } catch {}
    }
    $wordDraft = $translationList -and $sourceReady -and $documentFormat -eq 'docx' -and $wordStructureReady
    if ($translationList -and [string]$Project.Source -eq 'file' -and -not $sourceReady) { $reasons.Add('source-file-missing') | Out-Null }
    if ($translationList -and $documentFormat -eq 'docx' -and -not $wordStructureReady) { $reasons.Add('word-unsupported-structure') | Out-Null }
    return [pscustomobject]@{
        TranslationListEligible = $translationList
        ExcelDraftEligible = $excelDraft
        WordDraftEligible = $wordDraft
        Reasons = @($reasons.ToArray() | Select-Object -Unique)
    }
}

function Get-YakuCatOutputPreflight {
    <#
      出力直前に画面へ示す情報の正本。

      UI がファイル形式や確認件数から出力可否を推測すると、実際の export
      と表示が食い違う。ここでは Export-YakuCatProject と同じ eligibility を
      使い、まだファイルを作らずに出力方法と阻害理由だけを返す。
    #>
    param([Parameter(Mandatory=$true)]$Project)

    $eligibility = Get-YakuCatOutputEligibility -Project $Project
    $format = $(try { [string]$Project.DocumentFormat } catch { '' })
    if ([string]::IsNullOrWhiteSpace($format) -and [string]$Project.Source -eq 'file') {
        $format = [IO.Path]::GetExtension([string]$Project.Path).TrimStart('.').ToLowerInvariant()
    }

    $mode = 'blocked'
    $warnings = New-Object System.Collections.Generic.List[string]
    if ([bool]$eligibility.TranslationListEligible) {
        if ([string]$Project.Source -in @('text','align','prior_version')) {
            $mode = 'copy_text'
        } elseif ($format -eq 'docx') {
            if ([bool]$eligibility.WordDraftEligible) {
                $mode = 'word_draft'
            } else {
                # Word の体裁を安全に維持できないときは、現行 export と同じく
                # 確認済み訳文一覧へ縮退する。
                $mode = 'copy_text'
                $warnings.Add('このWordは体裁を保ったファイル出力に対応していないため、確認済み訳文をコピーします。') | Out-Null
            }
        } elseif ([bool]$eligibility.ExcelDraftEligible) {
            $mode = 'excel_draft'
        }
    }

    $reasonText = [ordered]@{
        'project-empty' = '翻訳する行がありません。'
        'segment-not-reviewed' = 'まだ確認していない行があります。左の「要対応」を押すと、その行だけ表示できます。'
        'segment-qc-not-current' = '訳文を直したあと、まだ自動点検をしていない行があります。その行を「確認済みにする」と点検します。'
        'segment-untranslated' = '訳文が空の行があります。'
        'source-file-missing' = '元のファイルが見つかりません。'
        'word-unsupported-structure' = '体裁を安全に保てないWord要素があります。'
    }
    $blockers = @(
        foreach ($reason in @($eligibility.Reasons)) {
            $message = if ($reasonText.Contains([string]$reason)) { [string]$reasonText[[string]$reason] } else { '出力条件を満たしていません。' }
            if ($mode -eq 'blocked') {
                [ordered]@{ code = [string]$reason; message = $message }
            } else {
                # Word体裁出力から訳文コピーへ安全に縮退できた理由は、
                # 実行を妨げるblockerではなく利用者へ伝えるwarningである。
                $warnings.Add($message) | Out-Null
            }
        }
    )

    $outputName = ''
    if ($mode -in @('word_draft','excel_draft')) {
        $sourceName = $(try { [IO.Path]::GetFileNameWithoutExtension([string]$Project.Path) } catch { 'translated' })
        if ([string]::IsNullOrWhiteSpace($sourceName)) { $sourceName = 'translated' }
        $safeName = ($sourceName -replace '[\\/:*?"<>|]', '_').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'translated' }
        $extension = if ([string]::IsNullOrWhiteSpace($format)) { '' } else { '.' + $format }
        $outputName = 'DRAFT_' + $safeName + '_translated' + $extension
    } elseif ($mode -eq 'copy_text') {
        $outputName = '確認済み訳文'
    }

    return [pscustomobject]@{
        ProjectId = [string]$Project.Id
        Revision = [int]$Project.Revision
        Eligible = ($mode -ne 'blocked')
        Mode = $mode
        OutputName = $outputName
        Blockers = @($blockers)
        Warnings = @($warnings.ToArray())
        DraftNotice = if ($mode -in @('word_draft','excel_draft')) { 'できあがるファイルは、社内で確認するためのものです。ファイル名の先頭に「DRAFT_」が付きます。完成版ではありませんので、お客様や社外へはそのままお送りにならないでください。' } else { '確認済みの訳文をまとめてコピーします。' }
    }
}

function New-YakuCatSegmentView {
    <#
      画面へ渡すセグメント1件分。中身は保持しているものの写しである。
    #>
    param([Parameter(Mandatory=$true)]$Segment, [Parameter(Mandatory=$true)][int]$Index)
    return [pscustomobject]@{
        Index       = $Index
        Source      = [string]$Segment.Text
        Translation = [string]$Segment.Translation
        Origin      = [string]$Segment.Origin
        Joined      = [bool]$Segment.Joined
        CellCount   = @($Segment.BlockIds).Count
        Kind        = [string]$Segment.Kind
        Location    = [string]$Segment.Location
        # 人が「これで良い」と判断したか。訳文が入っているかとは別物である。
        Confirmed   = [bool]$Segment.Confirmed
    }
}

function New-YakuCatProject {
    <#
      Excel を取り込み、セグメントに分ける。訳はまだ付けない。
      まず原文だけを並べて見せる、という段取りに合わせている。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [AllowNull()][string[]]$Sheets,
        [AllowNull()]$ProgressState,
        [bool]$Register = $true
    )
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.docx') {
        $wordProject = New-YakuCatWordProject -Root $Root -Path $Path -Settings $Settings -Direction $Direction
        if ($Register) { $script:YakuCatProjects[$wordProject.Id] = $wordProject }
        return $wordProject
    }
    $extract = Get-YakuExcelTextBlocks -Path $Path -Direction $Direction -Settings $Settings -Sheets $Sheets -ProgressState $ProgressState
    $blocks = @($extract.Blocks)

    # 行の埋まり具合は実際のシートから数える。翻訳対象だけを数えると
    # 「営業利益 | 1,234」の行が単独に見え、表の行を文章として繋いでしまう。
    $occ = @{}
    $ctx = New-YakuExcelApplication
    try {
        $wb = Open-YakuWorkbookWithManualCalc -Context $ctx -Path $Path -ReadOnly $true
        try { $occ = Get-YakuExcelRowOccupancy -Workbook $wb } finally {
            try { $wb.Close($false) | Out-Null } catch {}
            Release-YakuComObject $wb
        }
    } finally {
        Close-YakuExcelObjects -Workbook $null -Application $ctx.Application `
            -OldScreenUpdating $ctx.OldScreenUpdating -OldEnableEvents $ctx.OldEnableEvents `
            -OldDisplayStatusBar $ctx.OldDisplayStatusBar -OldFormatConditionsCalc $ctx.OldFormatConditionsCalc `
            -OldBackgroundChecking $ctx.OldBackgroundChecking
    }

    $segments = @(Group-YakuTextBlocksIntoSegments -Blocks $blocks -RowOccupancy $occ)
    foreach ($s in $segments) {
        $s | Add-Member -NotePropertyName 'Translation' -NotePropertyValue '' -Force
        # どこから来た訳文か。用語集／Copilot／手直し を区別して画面に出す。
        $s | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '' -Force
        # 人が「これで良い」と見た行かどうか。訳が入っているかとは別に持つ。
        $s | Add-Member -NotePropertyName 'Confirmed' -NotePropertyValue $false -Force
    }

    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = [string]$Path
        FileName  = [System.IO.Path]::GetFileName($Path)
        Direction = [string]$Direction
        Blocks    = $blocks
        Segments  = $segments
        Warnings  = @($extract.Warnings)
        Source    = 'file'
        CreatedAt = (Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    if ($Register) { $script:YakuCatProjects[$project.Id] = $project }
    return $project
}

function New-YakuCatTextProject {
    <#
      貼り付けたテキストから CAT のプロジェクトを作る。

      簡易翻訳と入力の作法を揃えるための経路である（利用者の懸念 2026-08-06）。
      貼って押す、までは同じで、変わるのは出口だけになる。
      Excel を知らなくても CAT を使えるようにする。

      出口も違う。書き戻す元のファイルが無いので、出力は訳文を繋いだもの
      （画面でコピーする）。簡易翻訳と同じ終わり方になる。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][AllowNull()]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        # 簡易翻訳から持ってきた訳文。原文と同じ規則で分けて並べる。
        # 空のまま渡すと、渡した先で「さっきの訳が消えた」ことになる。
        [AllowNull()][string]$Translation,
        [bool]$Register = $true
    )
    $sources = @(Split-YakuTextIntoSegments -Text $Text)
    $targets = @()
    if (-not [string]::IsNullOrWhiteSpace($Translation)) {
        $targets = @(Split-YakuTextIntoSegments -Text $Translation)
    }
    # 行数が合わないときは割り当てない。ずれたまま並べると、対応していない
    # 訳が原文の隣に出る。空欄のほうがまだ分かる。
    $useTargets = ($targets.Count -gt 0 -and $targets.Count -eq $sources.Count)
    $segments = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $seg = [pscustomobject]@{
            Text = [string]$sources[$i]
            BlockIds = @()
            Cells = @()
            Joined = $false
            Kind = 'text'
            Sheet = ''
            Location = '本文'
            Translation = [string]$(if ($useTargets) { $targets[$i] } else { '' })
            Origin = [string]$(if ($useTargets) { 'copilot' } else { '' })
            Confirmed = $false
        }
        [void]$segments.Add($seg)
    }
    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = ''
        FileName  = '貼り付けたテキスト'
        Direction = [string]$Direction
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @()
        Source    = 'text'
        PromotionReferenceTranslation = [string]$(if (-not $useTargets) { $Translation } else { '' })
        CreatedAt = (Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    if ($Register) { $script:YakuCatProjects[$project.Id] = $project }
    return $project
}

function New-YakuCatProjectFromQuickArtifact {
    <# Quick の本文をブラウザーから再送させず、server memory の artifact を
       そのまま未確認 CAT project として commit する。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Artifact,
        [Parameter(Mandatory=$true)][AllowNull()]$Settings
    )
    if ([string]$Artifact.Id -notmatch '^[a-f0-9]{32}$') { throw 'QUICK_ARTIFACT_ID_INVALID' }
    if ([string]$Artifact.Status -ne 'ready') { throw 'QUICK_ARTIFACT_NOT_READY' }
    if ([string]$Artifact.Direction -notin @('to_en','to_jp')) { throw 'QUICK_ARTIFACT_DIRECTION_INVALID' }
    if ([string]::IsNullOrWhiteSpace([string]$Artifact.SourceText) -or
        [string]::IsNullOrWhiteSpace([string]$Artifact.Translation)) { throw 'QUICK_ARTIFACT_CONTENT_MISSING' }

    $project = New-YakuCatTextProject -Root $Root -Text ([string]$Artifact.SourceText) -Settings $Settings `
        -Direction ([string]$Artifact.Direction) -Translation ([string]$Artifact.Translation) -Register $false
    $project.FileName = 'ちょっと翻訳から引き継ぎ'
    $project | Add-Member -NotePropertyName QuickArtifactId -NotePropertyValue ([string]$Artifact.Id) -Force
    $project | Add-Member -NotePropertyName DirectionBasis -NotePropertyValue 'inherited' -Force
    $project | Add-Member -NotePropertyName DirectionConfidence -NotePropertyValue ([string]$Artifact.DirectionConfidence) -Force
    $project | Add-Member -NotePropertyName DirectionSourceFingerprint -NotePropertyValue ([string]$Artifact.SourceFingerprint) -Force
    foreach ($segment in @($project.Segments)) {
        $segment.Confirmed = $false
        $segment | Add-Member -NotePropertyName State -NotePropertyValue $(if ([string]::IsNullOrWhiteSpace([string]$segment.Translation)) { 'untranslated' } else { 'machine_draft' }) -Force
        Reset-YakuCatSegmentQc -Segment $segment -KeepState
    }
    return (Commit-YakuNewCatProject -Project $project)
}

function New-YakuCatAlignProject {
    <#
      日本語と英語のひと組から CAT のプロジェクトを作る。訳す代わりに、
      既にある訳と突き合わせる。市販ツールの「文書のアライメント」に当たる。

      管理画面に取り込み専用の画面を作るのではなく、CAT の画面をそのまま
      使う（利用者の指摘 2026-08-07「今の管理画面は使いづらい」）。
      利点は作りの節約ではなく、確認の質のほうにある。

        - 対応は原文と訳文が左右に並ぶ、いつものグリッドで見える
        - ずれていれば、いつもの結合・分割で直せる
        - 直してからコーパスへ入れられる

      機械が作った対応をそのまま貯めるのではなく、人が一度見てから貯める。
      誤った対訳は完全一致で機械置換され続けるので、入口で見るのが安い。

      どのファイルとどのファイルが組かは、利用者が2つ選ぶことで決まる。
      名前から機械的に推測はしない。間違った組で突き合わせると、もっともらしい
      誤った対訳ができてしまう。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceText,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetText,
        [Parameter(Mandatory=$true)][AllowNull()]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$FileName = '対訳の突き合わせ',
        [int]$MinLineLength = 4
    )
    $clean = {
        param([string]$Text)
        return @(($Text -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim().Length -ge $MinLineLength })
    }
    $toEn = ([string]$Direction -eq 'to_en')
    $srcLines = @(& $clean $SourceText)
    $tgtLines = @(& $clean $TargetText)
    # アライメントは日本語を軸に切る。実測した壁（50行）が日本語基準のため。
    $jaLines = if ($toEn) { $srcLines } else { $tgtLines }
    $enLines = if ($toEn) { $tgtLines } else { $srcLines }

    if ($jaLines.Count -eq 0 -or $enLines.Count -eq 0) {
        return (New-YakuCatProjectFromPairs -Pairs @() -Direction $Direction -FileName $FileName `
                -Warnings @('日本語と英語の両方が必要です。片方が空でした。'))
    }
    $aligned = Invoke-YakuDocumentAlignment -JaLines $jaLines -EnLines $enLines -Settings $Settings
    return (New-YakuCatProjectFromPairs -Pairs @($aligned.Pairs) -Direction $Direction -FileName $FileName `
            -JaCoverage ([double]$aligned.JaCoverage) -Dropped ([int]$aligned.Dropped))
}

function New-YakuCatProjectFromPairs {
    <#
      取れた対から CAT のプロジェクトを組み立てる。

      突き合わせ自体は時間がかかるのでジョブ側（別のランスペース）で走らせる。
      プロジェクトはサーバーの手元に持つので、組み立ては分けてある。
      New-YakuCatAlignProject も、試験や単独実行のためにこれを呼ぶ。
    #>
    param(
        [AllowNull()][object[]]$Pairs,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        [string]$FileName = '対訳の突き合わせ',
        [AllowNull()][string[]]$Warnings,
        [double]$JaCoverage = 1.0,
        [int]$Dropped = 0,
        [bool]$Register = $true
    )
    $toEn = ([string]$Direction -eq 'to_en')
    $warn = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($Warnings)) { if (-not [string]::IsNullOrWhiteSpace([string]$w)) { [void]$warn.Add([string]$w) } }
    $segments = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Pairs)) {
        $ja = [string]$p.JaText; $en = [string]$p.EnText
        if ([string]::IsNullOrWhiteSpace($ja) -and [string]::IsNullOrWhiteSpace($en)) { continue }
        [void]$segments.Add([pscustomobject]@{
            Text        = [string]$(if ($toEn) { $ja } else { $en })
            BlockIds    = @()
            Cells       = @()
            Joined      = $false
            Kind        = 'align'
            Sheet       = ''
            Location    = '対訳'
            Translation = [string]$(if ($toEn) { $en } else { $ja })
            # 機械が作った対応であることを残す。人が直せば manual になる。
            Origin      = 'align'
            Confirmed   = $false
        })
    }
    # 黙って少ない結果を返すと、取れているように見えてしまう。
    if ($segments.Count -gt 0 -and $JaCoverage -lt 0.9) {
        [void]$warn.Add(('対応を取れなかった行があります（網羅率 ' + [string]([int]([Math]::Round($JaCoverage * 100))) + '%）。抽出が崩れていないか確かめてください。'))
    }
    if ($Dropped -gt 0) {
        [void]$warn.Add(('数値が食い違う対を ' + [string]$Dropped + ' 組はずしました。'))
    }
    $project = [pscustomobject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Path      = ''
        FileName  = [string]$FileName
        Direction = [string]$Direction
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @($warn.ToArray())
        Source    = 'align'
        CreatedAt = (Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    if ($Register) { $script:YakuCatProjects[$project.Id] = $project }
    return $project
}

function Save-YakuCatProjectToCorpus {
    <#
      グリッドで確かめた対訳をコーパスへ入れる。人が直した対も、直していない
      対も、この時点の中身をそのまま貯める。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$Database,
        [string]$Source = '',
        # 保存先。既定は管理者の取り込み場所。試験は別の場所を指す。
        [AllowNull()][string]$Dir,
        [switch]$Public,
        [switch]$PublicAttested
    )
    if ([string]::IsNullOrWhiteSpace($Dir)) { $Dir = Get-YakuCorpusBuildDir }
    # 文例を作るのは開発者であって、日々の利用者ではない
    # （利用者の整理 2026-08-08「公表資料は数も限られているので、開発者が
    # 最終形を配布用として保存する前提のほうが良い」）。
    # だから入口は突き合わせ（Source='align'）に限る。訳しながら片手間に
    # 文例を作らせると、公表前の資料や作りかけの訳が混ざる。
    if ([string]$Project.Source -ne 'align') {
        throw '文例は、公表済みの資料を突き合わせたときだけ保存できます。'
    }
    if (-not $Public -or -not $PublicAttested) {
        throw 'CAT_CORPUS_PUBLIC_ATTESTATION_REQUIRED: 公表実績を別途確認した資料だけを文例へ登録できます。'
    }
    $toEn = ([string]$Project.Direction -eq 'to_en')
    $null = Initialize-YakuCatProjectState -Project $Project
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($seg in @($Project.Segments)) {
        if ([string]$seg.State -ne 'reviewed' -or -not (Test-YakuCatSegmentQcCurrent -Segment $seg)) { continue }
        $a = [string]$seg.Text; $b = [string]$seg.Translation
        if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { continue }
        [void]$pairs.Add([pscustomobject]@{
            JaText        = [string]$(if ($toEn) { $a } else { $b })
            EnText        = [string]$(if ($toEn) { $b } else { $a })
            NumberChecked = $true
            NumberAgree   = $true
        })
    }
    $src = [string]$Source
    if ([string]::IsNullOrWhiteSpace($src)) { $src = [string]$Project.FileName }
    return (Add-YakuCorpusPairs -Dir $Dir -Database $Database -Source $src -Pairs @($pairs.ToArray()) -Public:$Public)
}

function Get-YakuCatProjectStoreDir {
    return (Get-YakuSubDir 'cat')
}

function Get-YakuCatOwnedSourceArtifactPath {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$Extension
    )
    if ($ProjectId -notmatch '^[a-fA-F0-9]{32}$') { throw 'CAT_PROJECT_ID_INVALID' }
    $ext = ([string]$Extension).ToLowerInvariant()
    if (@('.xlsx','.xlsm','.csv','.docx') -notcontains $ext) { throw 'CAT_SOURCE_ARTIFACT_TYPE_UNSUPPORTED' }
    $store = [System.IO.Path]::GetFullPath((Get-YakuCatProjectStoreDir)).TrimEnd('\')
    $projectDir = [System.IO.Path]::GetFullPath((Join-Path $store $ProjectId))
    if (-not $projectDir.StartsWith($store + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_SOURCE_ARTIFACT_PATH_INVALID' }
    return (Join-Path (Join-Path $projectDir 'source') ('original' + $ext))
}

function Initialize-YakuCatProjectSourceArtifact {
    <#
      ファイル型CATが参照する原本を、一時アップロード領域や利用者の元ファイル
      から切り離してproject配下へ固定する。以後の再開・出力はこの不変コピーだけ
      を読む。利用者の元ファイルを移動・削除することはない。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    if ([string]$Project.Source -ne 'file') { return $Project }
    $sourcePath = [string]$Project.Path
    if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw 'CAT_SOURCE_ARTIFACT_SOURCE_MISSING'
    }
    $sourceFull = [System.IO.Path]::GetFullPath($sourcePath)
    $ext = [System.IO.Path]::GetExtension($sourceFull).ToLowerInvariant()
    $destination = [System.IO.Path]::GetFullPath((Get-YakuCatOwnedSourceArtifactPath -ProjectId ([string]$Project.Id) -Extension $ext))
    $sourceDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $sourceDir -Force }

    $sourceHash = (Get-FileHash -LiteralPath $sourceFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $sourceFull.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $existingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($existingHash -ne $sourceHash) { throw 'CAT_SOURCE_ARTIFACT_CONFLICT' }
        } else {
            $tempPath = Join-Path $sourceDir ('.source-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [System.IO.File]::Copy($sourceFull, $tempPath, $false)
                $copiedHash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($copiedHash -ne $sourceHash) { throw 'CAT_SOURCE_ARTIFACT_COPY_MISMATCH' }
                [System.IO.File]::Move($tempPath, $destination)
            } finally {
                if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    $artifactHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifactSize = [int64](Get-Item -LiteralPath $destination).Length
    if ($Project.PSObject.Properties.Name -contains 'SourceArtifactSha256' -and
        -not [string]::IsNullOrWhiteSpace([string]$Project.SourceArtifactSha256) -and
        [string]$Project.SourceArtifactSha256 -ne $artifactHash) { throw 'CAT_SOURCE_ARTIFACT_INTEGRITY_FAILED' }
    if ([string]::IsNullOrWhiteSpace([string]$Project.FileName)) { $Project.FileName = [System.IO.Path]::GetFileName($sourceFull) }
    $Project.Path = $destination
    $Project | Add-Member -NotePropertyName SourceArtifactRelativePath -NotePropertyValue ('source/original' + $ext) -Force
    $Project | Add-Member -NotePropertyName SourceArtifactSha256 -NotePropertyValue $artifactHash -Force
    $Project | Add-Member -NotePropertyName SourceArtifactSize -NotePropertyValue $artifactSize -Force
    $Project | Add-Member -NotePropertyName SourceArtifactContractVersion -NotePropertyValue 'cat-source-v1' -Force
    return $Project
}

function Resolve-YakuCatSavedSourceArtifact {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectDir,
        [Parameter(Mandatory=$true)]$Record
    )
    $relative = [string]$Record.source_artifact_relative_path
    if ([string]::IsNullOrWhiteSpace($relative)) { return [string]$Record.path }
    if ([string]$Record.source_artifact_contract_version -ne 'cat-source-v1') { throw 'CAT_SOURCE_ARTIFACT_CONTRACT_UNSUPPORTED' }
    if ($relative -notmatch '^source/original\.(?:xlsx|xlsm|csv|docx)$') { throw 'CAT_SOURCE_ARTIFACT_PATH_INVALID' }
    $projectFull = [System.IO.Path]::GetFullPath($ProjectDir).TrimEnd('\')
    $artifactPath = [System.IO.Path]::GetFullPath((Join-Path $projectFull ($relative.Replace('/','\'))))
    if (-not $artifactPath.StartsWith($projectFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_SOURCE_ARTIFACT_PATH_INVALID' }
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw 'CAT_SOURCE_ARTIFACT_MISSING' }
    $expectedHash = ([string]$Record.source_artifact_sha256).ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($expectedHash) -or $actualHash -ne $expectedHash) { throw 'CAT_SOURCE_ARTIFACT_INTEGRITY_FAILED' }
    if ([int64]$Record.source_artifact_size -ne [int64](Get-Item -LiteralPath $artifactPath).Length) { throw 'CAT_SOURCE_ARTIFACT_INTEGRITY_FAILED' }
    return $artifactPath
}

function Get-YakuCatCheckpointPath {
    param([Parameter(Mandatory=$true)][string]$ProjectId)
    $safeId = [regex]::Replace($ProjectId, '[^A-Za-z0-9_.-]', '_')
    $dir = Join-Path (Get-YakuCatProjectStoreDir) 'checkpoints'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    return (Join-Path $dir ($safeId + '.json'))
}

function Get-YakuCatTombstonePath {
    param([Parameter(Mandatory=$true)][string]$ProjectId)
    $safeId = [regex]::Replace($ProjectId, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeId)) { throw 'CAT_PROJECT_ID_INVALID' }
    $dir = Join-Path (Get-YakuCatProjectStoreDir) 'deleted'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    return (Join-Path $dir ($safeId + '.tombstone'))
}

function Invoke-YakuCatCheckpointLock {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][scriptblock]$Operation,
        [AllowEmptyCollection()][object[]]$Arguments = @()
    )
    $safeId = [regex]::Replace($ProjectId, '[^A-Za-z0-9_.-]', '_')
    $mutex = New-Object Threading.Mutex($false, ('Local\YakuLingo.CatCheckpoint.' + $safeId))
    $entered = $false
    try {
        try { $entered = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $entered = $true }
        if (-not $entered) { throw 'CAT_CHECKPOINT_LOCK_TIMEOUT: 途中保存の排他待ちがタイムアウトしました。' }
        return (& $Operation @Arguments)
    } finally {
        if ($entered) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

function Save-YakuCatBatchCheckpoint {
    <# 成功したバッチだけを小さな別ファイルへ原子的に積む。別ランスペースから
       Project全体を書かないので、待機中の手修正を古いスナップショットで踏まない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][int]$ProjectRevision,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Translations
    )
    if (@($Translations).Count -eq 0) { return 0 }
    $operationState = [pscustomobject]@{ ProjectId=$ProjectId; ProjectRevision=$ProjectRevision; Translations=@($Translations) }
    $operation = {
        param($state)
        $tombstone = Get-YakuCatTombstonePath -ProjectId ([string]$state.ProjectId)
        if (Test-Path -LiteralPath $tombstone -PathType Leaf) {
            throw 'CAT_PROJECT_DELETED: 削除済みの作業には途中結果を保存できません。'
        }
        $path = Get-YakuCatCheckpointPath -ProjectId ([string]$state.ProjectId)
        $byKey = [ordered]@{}
        try {
            $old = Read-YakuJsonFile -Path $path
            if ([int]$old.project_revision -eq [int]$state.ProjectRevision) {
                foreach ($row in @($old.translations)) {
                    $key = [string]([int]$row.index) + '|' + [string]$row.source
                    $byKey[$key] = $row
                }
            }
        } catch {}
        foreach ($row in @($state.Translations)) {
            if ($null -eq $row) { continue }
            $source = [string]$row.source
            $text = [string]$row.text
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($text)) { continue }
            $index = [int]$row.index
            $key = [string]$index + '|' + $source
            $byKey[$key] = [ordered]@{
                index = $index; source = $source; text = $text
                masked = [string]$row.masked; saved = (Get-Date).ToString('s')
            }
        }
        Write-YakuJsonAtomic -Path $path -Value ([ordered]@{
                project_id = [string]$state.ProjectId; project_revision = [int]$state.ProjectRevision
                translations = @($byKey.Values)
            }) -Depth 8
        return @($byKey.Values).Count
    }
    return (Invoke-YakuCatCheckpointLock -ProjectId $ProjectId -Operation $operation -Arguments @($operationState))
}

function Apply-YakuCatBatchCheckpoint {
    <# mainランスペースでだけProjectへ取り込む。行番号に加えて原文一致と空欄を
       必須にし、結合・分割・手修正が待ち時間中に行われても上書きしない。
       Project本体と同じcopy-on-write境界を使い、保存失敗時は共有メモリも
       checkpointも変更しない。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $projectId = [string]$Project.Id
    $operationState = [pscustomobject]@{ Project=$Project; ProjectId=$projectId }
    $operation = {
        param($state)
        $innerProject = $state.Project
        $path = Get-YakuCatCheckpointPath -ProjectId ([string]$state.ProjectId)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
        $checkpoint = Read-YakuJsonFile -Path $path
        if ($null -eq $checkpoint) { return 0 }
        $wasRegistered = $script:YakuCatProjects.ContainsKey([string]$state.ProjectId)
        if (-not $wasRegistered) { $script:YakuCatProjects[[string]$state.ProjectId] = $innerProject }
        $committed = $script:YakuCatProjects[[string]$state.ProjectId]
        if ([int]$checkpoint.project_revision -ne [int]$committed.Revision) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if (-not $wasRegistered) { $script:YakuCatProjects.Remove([string]$state.ProjectId) }
            return 0
        }
        $mutation = {
            param($candidate,$rows)
            $segments = @($candidate.Segments)
            $applied = 0
            foreach ($row in @($rows)) {
                $index = [int]$row.index
                if ($index -lt 0 -or $index -ge $segments.Count) { continue }
                $segment = $segments[$index]
                if ([string]$segment.Text -ne [string]$row.source) { continue }
                if (-not [string]::IsNullOrWhiteSpace([string]$segment.Translation)) { continue }
                $segment.Translation = [string]$row.text
                $segment | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue ([string]$row.masked) -Force
                $segment.Origin = 'copilot'
                $segment.Confirmed = $false
                $segment | Add-Member -NotePropertyName State -NotePropertyValue 'machine_draft' -Force
                Reset-YakuCatSegmentQc -Segment $segment -KeepState
                $applied++
            }
            if ($applied -eq 0) { throw 'CAT_PROJECT_MUTATION_NO_CHANGES' }
            return $applied
        }
        try {
            $commit = Invoke-YakuCatProjectMutation -ProjectId ([string]$state.ProjectId) -ExpectedRevision ([int]$checkpoint.project_revision) -Mutation $mutation -Arguments @(,@($checkpoint.translations))
        } catch {
            if ([string]$_.Exception.Message -eq 'CAT_PROJECT_MUTATION_NO_CHANGES') {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
            if (-not $wasRegistered) { $script:YakuCatProjects.Remove([string]$state.ProjectId) }
            return 0
        }
        # 適用できなかった行も古い編集状態に属する。保持すると毎回再評価され、
        # 将来たまたま同じ行番号になったときに誤適用されるため、ここで破棄する。
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $(if ($wasRegistered) { [int]$commit.Result } else { 0 })
    }
    return (Invoke-YakuCatCheckpointLock -ProjectId $projectId -Operation $operation -Arguments @($operationState))
}

function Save-YakuCatProject {
    <#
      作業中のプロジェクトをディスクへ書く。

      これまではメモリだけに置いていた。「作業中しか使わないので保存の形を
      先に決めなくてよい」という判断だったが、確定の状態を持つようになって
      前提が変わった。どこまで見たかを記録しても、再読み込みで消えるなら
      記録の意味が無い。数百行を何時間もかけて見る作業で、F5 ひとつで
      全部消えるのは受け入れられない。

      訳文に加え、取り込み時の原文ブロックを軽量なスナップショットとして持つ。
      出力時はこの番地をそのまま使わず、元ファイルを読み直して原文どうしを
      対応付ける。スナップショットは「何が同じ原文か」を判断するためのもの。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $oldRevision = [int]$Project.Revision
    $generationDir = ''
    try {
        if ([string]$Project.Source -eq 'file') { $null = Initialize-YakuCatProjectSourceArtifact -Project $Project }
        $dir = Get-YakuCatProjectStoreDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $nextRevision = $oldRevision + 1
        $segs = @($Project.Segments | ForEach-Object {
                [ordered]@{
                    segment_id = [string]$_.SegmentId
                    text = [string]$_.Text
                    source_revision = [int]$_.SourceRevision
                    source_integrity_hash = [string]$_.SourceIntegrityHash
                    translation = [string]$_.Translation
                    masked_translation = [string]$_.MaskedTranslation
                    origin = [string]$_.Origin
                    state = [string]$_.State
                    qc_status = [string]$_.QcStatus
                    qc_source_revision = [int]$_.QcSourceRevision
                    qc_source_hash = [string]$_.QcSourceHash
                    qc_target_hash = [string]$_.QcTargetHash
                    qc_contract_version = [string]$_.QcContractVersion
                    qc_terminology_hash = [string]$_.QcTerminologyHash
                    qc_findings = @($_.QcFindings)
                    confirmed = [bool]$_.Confirmed
                    joined = [bool]$_.Joined
                    kind = [string]$_.Kind
                    sheet = [string]$_.Sheet
                    location = [string]$_.Location
                    block_ids = @($_.BlockIds)
                    cells = @($_.Cells)
                    change_kind = $(try { [string]$_.ChangeKind } catch { '' })
                    prior_source_text = $(try { [string]$_.PriorSourceText } catch { '' })
                    prior_translation = $(try { [string]$_.PriorTranslation } catch { '' })
                    reuse_evidence = $(try { [string]$_.ReuseEvidence } catch { '' })
                    prior_index = $(try { [int]$_.PriorIndex } catch { -1 })
                    reference_usage = $(try { $_.ReferenceUsage } catch { $null })
                    reference_events = @($(try { $_.ReferenceEvents } catch { @() }))
                    terminology_usages = @($(try { $_.TerminologyUsages } catch { @() }))
                    terminology_exceptions = @($(try { $_.TerminologyExceptions } catch { @() }))
                    terminology_generation = @($(try { $_.TerminologyGeneration } catch { @() }))
                }
            })
        $blocks = @($Project.Blocks | ForEach-Object {
                [ordered]@{
                    id = [string]$_.Id
                    text = [string]$_.Text
                    location = [string]$_.Location
                    meta = $_.Meta
                }
            })
        $record = [ordered]@{
            schema_version = 2
            revision = $nextRevision
            id = [string]$Project.Id
            path = [string]$Project.Path
            file_name = [string]$Project.FileName
            direction = [string]$Project.Direction
            direction_basis = [string]$Project.DirectionBasis
            direction_confidence = [string]$Project.DirectionConfidence
            direction_source_fingerprint = [string]$Project.DirectionSourceFingerprint
            quick_artifact_id = [string]$Project.QuickArtifactId
            terminology_snapshot_hash = [string]$Project.TerminologySnapshotHash
            tm_outbox = @($Project.TmOutbox)
            source = [string]$Project.Source
            document_format = $(try { [string]$Project.DocumentFormat } catch { '' })
            word_inventory = $(try { $Project.WordInventory } catch { $null })
            created = [string]$Project.CreatedAt
            corpus_section = [string]$Project.CorpusSection
            corpus_examples = @($Project.CorpusExamples)
            promotion_reference_translation = $(try { [string]$Project.PromotionReferenceTranslation } catch { '' })
            source_artifact_relative_path = $(try { [string]$Project.SourceArtifactRelativePath } catch { '' })
            source_artifact_sha256 = $(try { [string]$Project.SourceArtifactSha256 } catch { '' })
            source_artifact_size = $(try { [int64]$Project.SourceArtifactSize } catch { [int64]0 })
            source_artifact_contract_version = $(try { [string]$Project.SourceArtifactContractVersion } catch { '' })
            prior_version = $(try { $Project.PriorVersion } catch { $null })
            version_update_summary = $(try { $Project.VersionUpdateSummary } catch { $null })
            saved = (Get-Date).ToString('s')
        }
        $projectDir = Join-Path $dir ([string]$Project.Id)
        $generationId = [guid]::NewGuid().ToString('N')
        $generationRoot = Join-Path $projectDir 'generations'
        $generationDir = Join-Path $generationRoot $generationId
        foreach ($needed in @($projectDir,$generationRoot,$generationDir)) { if (-not (Test-Path -LiteralPath $needed -PathType Container)) { $null = New-Item -ItemType Directory -Path $needed -Force } }
        $segmentLines = @($segs | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join "`n"
        $blockLines = @($blocks | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join "`n"
        $qcLines = @($segs | ForEach-Object { [ordered]@{
                    segment_id=$_.segment_id; source_revision=$_.source_revision; status=$_.qc_status
                    source_hash=$_.qc_source_hash; target_hash=$_.qc_target_hash; contract_version=$_.qc_contract_version
                    findings=@($_.qc_findings)
                } | ConvertTo-Json -Depth 8 -Compress }) -join "`n"
        # 1 revision を構成する全ファイルを新しい世代へ先に書く。project.json は
        # コミットmanifestであり、全書込みが成功した最後にだけ差し替える。
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'segments.jsonl') -Text $segmentLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'blocks.jsonl') -Text $blockLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'qc.jsonl') -Text $qcLines
        $record['generation_id'] = $generationId
        $record['segment_count'] = @($segs).Count
        $record['block_count'] = @($blocks).Count
        $record['segments_sha256'] = Get-YakuCatSourceIntegrityHash -Text $segmentLines
        $record['blocks_sha256'] = Get-YakuCatSourceIntegrityHash -Text $blockLines
        $record['qc_sha256'] = Get-YakuCatSourceIntegrityHash -Text $qcLines
        Write-YakuJsonAtomic -Path (Join-Path $projectDir 'project.json') -Value $record -Depth 10
        $Project.Revision = $nextRevision
        # manifest 差し替え後は旧世代を残さない。行ごとの保存で全量スナップ
        # が無制限に増えると、長い資料ほど開く・保存する操作が劣化する。
        try {
            foreach ($oldGeneration in @(Get-ChildItem -LiteralPath $generationRoot -Directory -ErrorAction SilentlyContinue)) {
                if ([string]$oldGeneration.Name -eq $generationId) { continue }
                Remove-Item -LiteralPath $oldGeneration.FullName -Recurse -Force -ErrorAction Stop
            }
        } catch { try { Write-YakuLog ('CAT generation cleanup failed: ' + $_.Exception.Message) 'WARN' } catch {} }
        return $true
    } catch {
        $Project.Revision = $oldRevision
        # manifest が指していない未コミット世代は復元に使わない。
        # 失敗するたびに残すと障害時ほど容量が増えるため、ここで回収する。
        if (-not [string]::IsNullOrWhiteSpace($generationDir) -and (Test-Path -LiteralPath $generationDir -PathType Container)) {
            try { Remove-Item -LiteralPath $generationDir -Recurse -Force -ErrorAction Stop } catch {}
        }
        try { Write-YakuLog ('CAT project save failed: ' + $_.Exception.Message) 'WARN' } catch {}
        return $false
    }
}

function Get-YakuCatSavedProjects {
    <#
      保存してあるものの一覧。新しい順。
      画面に「前回の続きから」を出すために使う。
    #>
    param([int]$Limit = 10)
    $dir = Get-YakuCatProjectStoreDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'project.json' -File -Recurse -ErrorAction SilentlyContinue)) { $files.Add($f) | Out-Null }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $files.Add($f) | Out-Null }
    foreach ($f in @($files.ToArray() | Sort-Object LastWriteTime -Descending | Select-Object -First $Limit)) {
        try {
            $o = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $segs = @($o.segments)
            if ([int]$o.schema_version -ge 2) {
                $generationId = [string]$o.generation_id
                $segPath = if ($generationId -match '^[a-f0-9]{32}$') { Join-Path (Join-Path (Join-Path $f.DirectoryName 'generations') $generationId) 'segments.jsonl' } else { Join-Path $f.DirectoryName 'segments.jsonl' }
                if (Test-Path -LiteralPath $segPath -PathType Leaf) { $segs = @(Get-Content -LiteralPath $segPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }) }
            }
            $savedSourcePath = [string]$o.path
            if ([string]$o.source -eq 'file' -and -not [string]::IsNullOrWhiteSpace([string]$o.source_artifact_relative_path)) {
                try { $savedSourcePath = Resolve-YakuCatSavedSourceArtifact -ProjectDir $f.DirectoryName -Record $o }
                catch { $savedSourcePath = '' }
            }
            [void]$out.Add([pscustomobject]@{
                    Id = [string]$o.id
                    FileName = [string]$o.file_name
                    Direction = [string]$o.direction
                    Total = $segs.Count
                    Confirmed = @($segs | Where-Object { [bool]$_.confirmed }).Count
                    Saved = [string]$o.saved
                    Source = [string]$o.source
                    # ファイル型は元ファイルが残っていれば、出力時に読み直して
                    # 原文を再対応付けできる。無い場合だけ押す前に止める。
                    ExportBlocked = ([string]$o.source -eq 'file' -and -not (Test-Path -LiteralPath $savedSourcePath -PathType Leaf))
                })
        } catch {
            try { Write-YakuLog ('CAT project unreadable, skipped. file=' + $f.Name) 'WARN' } catch {}
        }
    }
    return @($out.ToArray())
}

function ConvertFrom-YakuCatSavedSegmentsToBlocks {
    <#
      blocks を保存していなかった旧形式から、対応付けに必要な原文だけを戻す。
      番地は書き戻し先として使わない。新しく抽出したブロックを探す手掛かり。
    #>
    param([AllowNull()][object[]]$Segments)
    $blocks = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($s in @($Segments)) {
        $kind = [string]$s.Kind
        if ($kind -eq 'cell') {
            foreach ($cell in @($s.Cells)) {
                $id = [string]$cell.BlockId
                if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                [void]$blocks.Add([pscustomobject]@{
                    Id = $id
                    Text = [string]$cell.Text
                    Location = [string]$s.Location
                    Meta = [pscustomobject]@{
                        Kind = 'cell'; Sheet = [string]$s.Sheet
                        Row = [int]$cell.Row; Col = [int]$cell.Column
                        A1 = [string]$cell.Address
                    }
                })
            }
            continue
        }
        $ids = @($s.BlockIds)
        if ($ids.Count -ne 1) { continue }
        $id = [string]$ids[0]
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        [void]$blocks.Add([pscustomobject]@{
            Id = $id; Text = [string]$s.Text; Location = [string]$s.Location
            Meta = [pscustomobject]@{ Kind = $kind; Sheet = [string]$s.Sheet }
        })
    }
    return @($blocks.ToArray())
}

function Restore-YakuCatProject {
    <#
      保存したものをメモリへ戻す。保存時の原文ブロックは、出力時に
      現在の元ファイルから再抽出したブロックと対応付けるために使う。
    #>
    param([Parameter(Mandatory=$true)][string]$Id)
    $store = Get-YakuCatProjectStoreDir
    $projectDir = Join-Path $store $Id
    $file = Join-Path $projectDir 'project.json'
    $isV2 = Test-Path -LiteralPath $file -PathType Leaf
    if (-not $isV2) { $file = Join-Path $store ($Id + '.json') }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $o = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $savedSourcePath = [string]$o.path
    if ([string]$o.source -eq 'file' -and -not [string]::IsNullOrWhiteSpace([string]$o.source_artifact_relative_path)) {
        $savedSourcePath = Resolve-YakuCatSavedSourceArtifact -ProjectDir $projectDir -Record $o
    }
    $savedSegmentRows = @($o.segments)
    $savedBlockRows = @($o.blocks)
    if ($isV2) {
        $generationId = [string]$o.generation_id
        if (-not [string]::IsNullOrWhiteSpace($generationId)) {
            if ($generationId -notmatch '^[a-f0-9]{32}$') { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代IDが不正です。' }
            $generationDir = Join-Path (Join-Path $projectDir 'generations') $generationId
            $segPath = Join-Path $generationDir 'segments.jsonl'
            $blockPath = Join-Path $generationDir 'blocks.jsonl'
            $qcPath = Join-Path $generationDir 'qc.jsonl'
            foreach ($requiredPath in @($segPath,$blockPath,$qcPath)) {
                if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代を構成するファイルが不足しています。' }
            }
            $segmentRaw = Get-Content -LiteralPath $segPath -Raw -Encoding UTF8
            $blockRaw = Get-Content -LiteralPath $blockPath -Raw -Encoding UTF8
            $qcRaw = Get-Content -LiteralPath $qcPath -Raw -Encoding UTF8
            if ((Get-YakuCatSourceIntegrityHash -Text $segmentRaw) -ne [string]$o.segments_sha256 -or
                (Get-YakuCatSourceIntegrityHash -Text $blockRaw) -ne [string]$o.blocks_sha256 -or
                (Get-YakuCatSourceIntegrityHash -Text $qcRaw) -ne [string]$o.qc_sha256) {
                throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代の整合性検査に失敗しました。'
            }
            $savedSegmentRows = @($segmentRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedBlockRows = @($blockRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            if ($savedSegmentRows.Count -ne [int]$o.segment_count -or $savedBlockRows.Count -ne [int]$o.block_count) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代の件数がmanifestと一致しません。' }
        } else {
            # schema v2初期版との後方互換。新しい保存は必ず generation_id を持つ。
            $segPath = Join-Path $projectDir 'segments.jsonl'
            $blockPath = Join-Path (Join-Path $projectDir 'snapshots') 'blocks.jsonl'
            if (-not (Test-Path -LiteralPath $segPath -PathType Leaf)) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: セグメント保存ファイルがありません。' }
            $savedSegmentRows = @(Get-Content -LiteralPath $segPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            if (Test-Path -LiteralPath $blockPath -PathType Leaf) { $savedBlockRows = @(Get-Content -LiteralPath $blockPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }) }
        }
    }
    $segments = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($savedSegmentRows)) {
        [void]$segments.Add([pscustomobject]@{
                SegmentId = [string]$s.segment_id
                Text = [string]$s.text
                SourceRevision = $(if ([int]$s.source_revision -gt 0) { [int]$s.source_revision } else { 1 })
                SourceIntegrityHash = [string]$s.source_integrity_hash
                Translation = [string]$s.translation
                MaskedTranslation = [string]$s.masked_translation
                Origin = [string]$s.origin
                State = [string]$s.state
                QcStatus = [string]$s.qc_status
                QcSourceRevision = [int]$s.qc_source_revision
                QcSourceHash = [string]$s.qc_source_hash
                QcTargetHash = [string]$s.qc_target_hash
                QcContractVersion = [string]$s.qc_contract_version
                QcTerminologyHash = [string]$s.qc_terminology_hash
                QcFindings = @($s.qc_findings)
                Confirmed = [bool]$s.confirmed
                Joined = [bool]$s.joined
                Kind = [string]$s.kind
                Sheet = [string]$s.sheet
                Location = [string]$s.location
                BlockIds = @($s.block_ids)
                Cells = @($s.cells)
                ChangeKind = [string]$s.change_kind
                PriorSourceText = [string]$s.prior_source_text
                PriorTranslation = [string]$s.prior_translation
                ReuseEvidence = [string]$s.reuse_evidence
                PriorIndex = $(if ($null -ne $s.prior_index) { [int]$s.prior_index } else { -1 })
                ReferenceUsage = $s.reference_usage
                ReferenceEvents = @($s.reference_events)
                TerminologyUsages = @($s.terminology_usages)
                TerminologyExceptions = @($s.terminology_exceptions)
                TerminologyGeneration = @($s.terminology_generation)
            })
    }
    $savedBlocks = New-Object System.Collections.Generic.List[object]
    foreach ($b in @($savedBlockRows)) {
        if ($null -eq $b -or [string]::IsNullOrWhiteSpace([string]$b.id)) { continue }
        [void]$savedBlocks.Add([pscustomobject]@{
            Id = [string]$b.id; Text = [string]$b.text
            Location = [string]$b.location; Meta = $b.meta
        })
    }
    if ($savedBlocks.Count -eq 0) {
        foreach ($b in @(ConvertFrom-YakuCatSavedSegmentsToBlocks -Segments @($segments.ToArray()))) {
            [void]$savedBlocks.Add($b)
        }
    }
    $project = [pscustomobject]@{
        Id        = [string]$o.id
        Path      = $savedSourcePath
        FileName  = [string]$o.file_name
        Direction = [string]$o.direction
        DirectionBasis = $(if (-not [string]::IsNullOrWhiteSpace([string]$o.direction_basis)) { [string]$o.direction_basis } else { 'fixed' })
        DirectionConfidence = $(if (-not [string]::IsNullOrWhiteSpace([string]$o.direction_confidence)) { [string]$o.direction_confidence } else { 'not_applicable' })
        DirectionSourceFingerprint = [string]$o.direction_source_fingerprint
        QuickArtifactId = [string]$o.quick_artifact_id
        TerminologySnapshotHash = [string]$o.terminology_snapshot_hash
        TmOutbox = @($o.tm_outbox)
        Blocks    = @($savedBlocks.ToArray())
        Segments  = @($segments.ToArray())
        Warnings  = @()
        Source    = [string]$o.source
        DocumentFormat = [string]$o.document_format
        WordInventory = $o.word_inventory
        CreatedAt = [string]$o.created
        Revision  = [int]$o.revision
        SchemaVersion = $(if ([int]$o.schema_version -gt 0) { [int]$o.schema_version } else { 1 })
        Restored  = $true
        PromotionReferenceTranslation = [string]$o.promotion_reference_translation
        SourceArtifactRelativePath = [string]$o.source_artifact_relative_path
        SourceArtifactSha256 = [string]$o.source_artifact_sha256
        SourceArtifactSize = [int64]$o.source_artifact_size
        SourceArtifactContractVersion = [string]$o.source_artifact_contract_version
        PriorVersion = $o.prior_version
        VersionUpdateSummary = $o.version_update_summary
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$o.corpus_section)) {
        $project | Add-Member -NotePropertyName 'CorpusSection' -NotePropertyValue ([string]$o.corpus_section) -Force
        $project | Add-Member -NotePropertyName 'CorpusExamples' -NotePropertyValue @($o.corpus_examples) -Force
    }
    $null = Initialize-YakuCatProjectState -Project $project
    if ([string]$project.Source -eq 'file' -and [string]::IsNullOrWhiteSpace([string]$project.SourceArtifactRelativePath) -and
        (Test-Path -LiteralPath ([string]$project.Path) -PathType Leaf)) {
        if (-not (Save-YakuCatProject -Project $project)) { throw 'CAT_SOURCE_ARTIFACT_MIGRATION_FAILED' }
    }
    $script:YakuCatProjects[$project.Id] = $project
    $null = Sync-YakuCatTranslationMemoryOutbox -Project $project
    $null = Apply-YakuCatBatchCheckpoint -Project $project
    return $script:YakuCatProjects[[string]$project.Id]
}

function Get-YakuCatProject {
    param([Parameter(Mandatory=$true)][string]$Id)
    if (-not $script:YakuCatProjects.ContainsKey($Id)) { return $null }
    return $script:YakuCatProjects[$Id]
}

function Remove-YakuCatProject {
    param([Parameter(Mandatory=$true)][string]$Id, [switch]$DeleteStored)
    try { $script:YakuCatProjects.Remove($Id) } catch {}
    if (-not $DeleteStored) { return }
    if ($Id -notmatch '^[a-fA-F0-9]{32}$') { throw 'CAT_PROJECT_ID_INVALID' }
    $store = [System.IO.Path]::GetFullPath((Get-YakuCatProjectStoreDir))
    $projectDir = [System.IO.Path]::GetFullPath((Join-Path $store $Id))
    if (-not $projectDir.StartsWith($store.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_PROJECT_DELETE_PATH_INVALID' }
    # 実行中workerと同じlock内でtombstoneを先にコミットする。
    # 削除後に遅れて終了したbatchがcheckpointを復活させる競合を防ぐ。
    $deleteOperation = {
        param($innerId)
        $tombstone = Get-YakuCatTombstonePath -ProjectId $innerId
        Write-YakuTextAtomic -Path $tombstone -Text ((Get-Date).ToString('o'))
        $checkpoint = Get-YakuCatCheckpointPath -ProjectId $innerId
        if (Test-Path -LiteralPath $checkpoint -PathType Leaf) { Remove-Item -LiteralPath $checkpoint -Force }
    }
    $null = Invoke-YakuCatCheckpointLock -ProjectId $Id -Operation $deleteOperation -Arguments @($Id)
    if (Test-Path -LiteralPath $projectDir -PathType Container) { Remove-Item -LiteralPath $projectDir -Recurse -Force }
    $legacyPath = [System.IO.Path]::GetFullPath((Join-Path $store ($Id + '.json')))
    if (-not $legacyPath.StartsWith($store.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_PROJECT_DELETE_PATH_INVALID' }
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) { Remove-Item -LiteralPath $legacyPath -Force }
    # キャッシュはproject IDを鍵に含まないため、対象projectの行だけを
    # 安全に特定できない。削除契約を優先し、process-wide cacheを全削除する。
    if (Get-Command Clear-YakuTranslationCache -ErrorAction SilentlyContinue) { $null = Clear-YakuTranslationCache }
}

function Get-YakuCatProjectSummary {
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    $done = @($segs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
    # 進捗は「人が確認した数」で数える。機械が埋めた数だと、翻訳ボタンを
    # 押した瞬間に 100% になり、以後どれだけ確認しても動かない。
    # 数百行を何時間もかけて見る作業では、それは進捗表示として役に立たない。
    $confirmed = @($segs | Where-Object { [string]$_.State -eq 'reviewed' }).Count
    $eligibility = Get-YakuCatOutputEligibility -Project $Project
    return [pscustomobject]@{
        Id        = [string]$Project.Id
        FileName  = [string]$Project.FileName
        Direction = [string]$Project.Direction
        DirectionBasis = [string]$Project.DirectionBasis
        DirectionConfidence = [string]$Project.DirectionConfidence
        Total     = $segs.Count
        Translated = $done
        Remaining = ($segs.Count - $done)
        Joined    = @($segs | Where-Object { [bool]$_.Joined }).Count
        Confirmed = $confirmed
        Unconfirmed = ($segs.Count - $confirmed)
        Revision = [int]$Project.Revision
        TranslationListEligible = [bool]$eligibility.TranslationListEligible
        ExcelDraftEligible = [bool]$eligibility.ExcelDraftEligible
        WordDraftEligible = [bool]$eligibility.WordDraftEligible
        EligibilityReasons = @($eligibility.Reasons)
    }
}

function ConvertTo-YakuCatProjectJson {
    <#
      画面へ渡す形。原文・訳文・出どころ・場所だけを出す。
      元の塊やセルの座標は画面に用が無いので載せない。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $segs = @($Project.Segments)
    # 元ファイルが無ければ再抽出できない。存在する場合は、出力時に原文を
    # 再対応付けし、曖昧・欠落があればコピーを作る前に安全停止する。
    $eligibility = Get-YakuCatOutputEligibility -Project $Project
    $documentFormat = $(try { [string]$Project.DocumentFormat } catch { '' })
    $exportBlocked = if ([string]$Project.Source -ne 'file') { -not [bool]$eligibility.TranslationListEligible } elseif ($documentFormat -eq 'docx') { -not [bool]$eligibility.TranslationListEligible } else { -not [bool]$eligibility.ExcelDraftEligible }
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        [void]$rows.Add([ordered]@{
            index       = $i
            segment_id  = [string]$segs[$i].SegmentId
            source      = [string]$segs[$i].Text
            translation = [string]$segs[$i].Translation
            origin      = [string]$segs[$i].Origin
            joined      = [bool]$segs[$i].Joined
            cells       = @($segs[$i].BlockIds).Count
            kind        = [string]$segs[$i].Kind
            location    = [string]$segs[$i].Location
            confirmed   = [bool]$segs[$i].Confirmed
            state       = [string]$segs[$i].State
            qc_status   = [string]$segs[$i].QcStatus
            qc_findings = @($segs[$i].QcFindings)
            qc_terminology_hash = [string]$segs[$i].QcTerminologyHash
            change_kind = $(try { [string]$segs[$i].ChangeKind } catch { '' })
            prior_source = $(try { [string]$segs[$i].PriorSourceText } catch { '' })
            prior_translation = $(try { [string]$segs[$i].PriorTranslation } catch { '' })
            reuse_evidence = $(try { [string]$segs[$i].ReuseEvidence } catch { '' })
            reference_usage = $(try { $segs[$i].ReferenceUsage } catch { $null })
            reference_events = @($(try { $segs[$i].ReferenceEvents } catch { @() }))
            terminology_usages = @($(try { $segs[$i].TerminologyUsages } catch { @() }))
            terminology_exceptions = @($(try { $segs[$i].TerminologyExceptions } catch { @() }))
            terminology_generation = @($(try { $segs[$i].TerminologyGeneration } catch { @() }))
            can_revise  = (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation) -and -not [string]::IsNullOrWhiteSpace([string]$segs[$i].MaskedTranslation))
            status      = Get-YakuCatSegmentStatus -Segment $segs[$i]
            # 次と繋げるか。シートが違う・図形が挟まる場合は繋げない。
            can_merge   = ($i -lt ($segs.Count - 1)) -and ([string]$segs[$i].Kind -eq [string]$segs[$i + 1].Kind) -and (
                           ([string]$segs[$i].Kind -eq 'text') -or
                           ([string]$segs[$i].Kind -eq 'cell' -and [string]$segs[$i].Sheet -eq [string]$segs[$i + 1].Sheet))
            can_split   = (([string]$segs[$i].Kind -eq 'cell' -and @($segs[$i].Cells).Count -gt 1) -or
                           ([string]$segs[$i].Kind -eq 'text' -and @(Get-YakuCatTextPieces -Segment $segs[$i]).Count -gt 1))
        })
    }
    $summary = Get-YakuCatProjectSummary -Project $Project
    # 引いた文例。検索したときだけ入る。何が引けたかを見てから
    # 使うかどうか決められるようにするため（利用者の判断 2026-08-06）。
    $corpusExamples = @()
    try { $corpusExamples = @($Project.CorpusExamples) } catch { $corpusExamples = @() }
    $corpusRows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $corpusExamples) {
        if ($null -eq $e) { continue }
        # 出どころは Database / Source / Page。どの資料の何ページかが分からないと、
        # 文例を採るかどうか判断できない。
        $text = ''; $db = ''; $doc = ''; $page = ''
        try { $text = [string]$e.Text } catch {}
        try { $db = [string]$e.Database } catch {}
        try { $doc = [string]$e.Source } catch {}
        try { $page = [string]$e.Page } catch {}
        # Source が既にデータベース名で始まっていることがある。二重に付けない。
        if ((-not [string]::IsNullOrWhiteSpace($db)) -and $doc.StartsWith($db)) { $db = '' }
        $where = (@($db, $doc) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '/'
        if (-not [string]::IsNullOrWhiteSpace($page)) { $where = ($where + ' p.' + $page).Trim() }
        [void]$corpusRows.Add([ordered]@{ text = $text; where = $where })
    }
    return ([ordered]@{
        id         = [string]$Project.Id
        revision   = [int]$Project.Revision
        source     = $(try { [string]$Project.Source } catch { 'file' })
        # 出力できない状態かどうか。押す前に画面へ出す。
        export_blocked = [bool]$exportBlocked
        translation_list_eligibility = [bool]$eligibility.TranslationListEligible
        excel_draft_eligibility = [bool]$eligibility.ExcelDraftEligible
        word_draft_eligibility = [bool]$eligibility.WordDraftEligible
        word_file_output_supported = $(try { [bool]$Project.WordInventory.DraftStructureEligible } catch { $false })
        eligibility_reasons = @($eligibility.Reasons)
        corpus_ready = $(try { -not [string]::IsNullOrWhiteSpace([string]$Project.CorpusSection) } catch { $false })
        corpus     = @($corpusRows.ToArray())
        promotion_reference_translation = $(try { [string]$Project.PromotionReferenceTranslation } catch { '' })
        version_update = $(try { $Project.VersionUpdateSummary } catch { $null })
        word_inventory = $(try {
            [ordered]@{
                draft_structure_eligible = [bool]$Project.WordInventory.DraftStructureEligible
                unsupported_reasons = @($Project.WordInventory.UnsupportedReasons)
                supported_blocks = [int]$Project.WordInventory.SupportedBlockCount
                total_blocks = [int]$Project.WordInventory.TotalBlockCount
            }
        } catch { $null })
        file_name  = [string]$Project.FileName
        document_format = $documentFormat
        direction  = [string]$Project.Direction
        terminology_snapshot_hash = [string]$Project.TerminologySnapshotHash
        tm_pending = $(try { [int]$Project.TmPendingCount } catch { 0 })
        total      = [int]$summary.Total
        translated = [int]$summary.Translated
        remaining  = [int]$summary.Remaining
        joined     = [int]$summary.Joined
        confirmed   = [int]$summary.Confirmed
        unconfirmed = [int]$summary.Unconfirmed
        untranslated = @($segs | Where-Object { (Get-YakuCatSegmentStatus -Segment $_) -eq 'untranslated' }).Count
        glossary_candidates = $(try { [int]$Project.GlossaryCandidates } catch { 0 })
        draft        = @($segs | Where-Object { @('machine_draft','human_edited') -contains (Get-YakuCatSegmentStatus -Segment $_) }).Count
        segments   = @($rows.ToArray())
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Invoke-YakuCatGlossaryPass {
    <#
      登録された用語集で、機械的に置換する。

      当たるのは**完全一致だけ**である。表のラベルはそのために登録して
      あるので、ここで大半の項目が片付く。文中の語を置き換えることは
      しない（活用と一致が壊れるため。実機検証結果 §3-2 に記録）。

      既に訳が入っているセグメントは触らない。人が直したものを
      機械が上書きしてはならない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Settings
    )
    $segs = @($Project.Segments)
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
        [void]$items.Add([pscustomobject]@{ Index = $i; Text = [string]$segs[$i].Text; BlockIds = (New-Object System.Collections.Generic.List[string]) })
    }
    $map = @{}
    $resolved = [pscustomobject]@{ Count=0; AppliedGlossary=@() }
    if ($items.Count -gt 0) {
        $terminologyEntries = @(Get-YakuCatTerminologyEntries -Project $Project)
        $resolved = Resolve-YakuFileExactGlossaryTranslations -Root $Root -Items @($items.ToArray()) -Direction ([string]$Project.Direction) `
            -Settings $Settings -TranslationByIndex $map -TerminologyEntries $terminologyEntries -ProjectId ([string]$Project.Id)
    }
    $appliedByIndex = @{}
    foreach ($appliedTerm in @($resolved.AppliedGlossary)) { $appliedByIndex[[int]$appliedTerm.ItemIndex] = $appliedTerm }
    $hits = 0
    foreach ($k in @($map.Keys)) {
        $i = [int]$k
        if ($i -lt 0 -or $i -ge $segs.Count) { continue }
        $segs[$i].Translation = [string]$map[$k]
        $segs[$i].Origin = 'glossary'
        if ($appliedByIndex.ContainsKey($i)) {
            $appliedTerm = $appliedByIndex[$i]
            $usages = New-Object System.Collections.Generic.List[object]
            foreach ($oldUsage in @($(try { $segs[$i].TerminologyUsages } catch { @() }))) { $usages.Add($oldUsage) | Out-Null }
            $scope = [string]$appliedTerm.Scope
            $usages.Add([pscustomobject]@{
                reference_id=[string]$appliedTerm.ReferenceId; term_id=[string]$appliedTerm.TermId
                term_version=[int]$appliedTerm.TermVersion; source=[string]$appliedTerm.Source
                preferred_target=[string]$appliedTerm.To
                source_name=$(if($scope -eq 'project'){'この資料の用語集'}else{'個人用語集'})
                scope=$scope; action='cell-exact-applied'
                target_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$map[$k])
                edited_after_insert=$false; created=(Get-Date).ToString('s')
            }) | Out-Null
            $segs[$i] | Add-Member -NotePropertyName TerminologyUsages -NotePropertyValue @($usages.ToArray()) -Force
        }
        $segs[$i] | Add-Member -NotePropertyName State -NotePropertyValue 'machine_draft' -Force
        Reset-YakuCatSegmentQc -Segment $segs[$i] -KeepState
        $hits++
    }
    return [pscustomobject]@{ Applied = $hits; Remaining = @($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count }
}

function Measure-YakuCatGlossaryCandidates {
    <#
      用語集で埋められる行が何行あるかを、置き換えずに数える。

      取り込んだ直後に勝手に置き換えるのは気味が悪い（利用者の指摘 2026-08-08）。
      市販ツールでも事前翻訳は名前の付いた作業で、設定が見えていて、
      押さなければ起きない。押す前に「何行が対象か」を見せる。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Settings
    )
    $segs = @($Project.Segments)
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
        [void]$items.Add([pscustomobject]@{ Index = $i; Text = [string]$segs[$i].Text; BlockIds = (New-Object System.Collections.Generic.List[string]) })
    }
    if ($items.Count -eq 0) { return 0 }
    $map = @{}
    try {
        $terminologyEntries = @(Get-YakuCatTerminologyEntries -Project $Project)
        $null = Resolve-YakuFileExactGlossaryTranslations -Root $Root -Items @($items.ToArray()) -Direction ([string]$Project.Direction) `
            -Settings $Settings -TranslationByIndex $map -TerminologyEntries $terminologyEntries -ProjectId ([string]$Project.Id)
    } catch { return 0 }
    return @($map.Keys).Count
}

function Get-YakuCatSegmentStatus {
    <#
      行の状態。市販ツールに倣って3つにする。

        未翻訳  訳が入っていない
        下訳    機械が入れた。人はまだ見ていない
        確定    人が見て、これでよいと決めた

      「訳が入っているか」と「人が見たか」は別物である。
      用語集で埋めた行も、目を通すまでは終わっていない。
    #>
    param([Parameter(Mandatory=$true)]$Segment)
    if ($Segment.PSObject.Properties.Name -contains 'State' -and -not [string]::IsNullOrWhiteSpace([string]$Segment.State)) { return [string]$Segment.State }
    if ([bool]$Segment.Confirmed) { return 'reviewed' }
    if ([string]::IsNullOrWhiteSpace([string]$Segment.Translation)) { return 'untranslated' }
    return 'machine_draft'
}

function Get-YakuCatCacheStyle {
    return 'canonical-v1|reference:none|mask:numeric-v1|validation:cat-v1'
}

function ConvertTo-YakuCatCheckpointRows {
    <# マスク済みのバッチ結果をコピー上で実値へ戻し、Projectへ安全に
       突き合わせられる行へする。元itemsは後続バッチのため変更しない。 #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory=$true)]$Translations,
        [AllowNull()]$Warnings,
        [ValidateSet('auto','to_en','to_jp')][string]$Direction='auto'
    )
    $copies = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        $idx = [int]$item.Index
        if (-not $Translations.ContainsKey($idx)) { continue }
        $copies.Add([pscustomobject]@{
                Index = $idx; Text = [string]$item.Text
                OriginalText = [string]$item.OriginalText
                MaskedText = [string]$item.MaskedText
                NumericMaskMap = $item.NumericMaskMap
                Targets = @($item.Targets); SegmentIndexes = @($item.SegmentIndexes)
            }) | Out-Null
    }
    $copyMap = @{}
    foreach ($copy in @($copies.ToArray())) { $copyMap[[int]$copy.Index] = [string]$Translations[[int]$copy.Index] }
    Restore-YakuCatItemTranslations -Items @($copies.ToArray()) -Map $copyMap -Warnings $Warnings -Direction $Direction
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($copy in @($copies.ToArray())) {
        $targets = @($copy.Targets)
        if ($targets.Count -eq 0) { $targets = @($copy.SegmentIndexes) }
        foreach ($target in $targets) {
            $rows.Add([ordered]@{
                    index = [int]$target; source = [string]$copy.OriginalText
                    text = [string]$copyMap[[int]$copy.Index]
                    masked = [string]$copy.MaskedTranslation
                }) | Out-Null
        }
    }
    return @($rows.ToArray())
}

function Get-YakuCatCopilotUsage {
    <# 画面の概算と実処理が同じ重複排除・マスク・分割を使う。
       machine draft のcross-project cacheは使わない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Settings
    )
    $byText = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($segment in @($Project.Segments)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segment.Translation)) { continue }
        $text = [string]$segment.Text
        if ([string]::IsNullOrWhiteSpace($text) -or $byText.ContainsKey($text)) { continue }
        $item = [pscustomobject]@{ Index=($items.Count + 1); Text=$text; BlockIds=(New-Object System.Collections.Generic.List[string]) }
        $byText[$text] = $item; $items.Add($item) | Out-Null
    }
    $null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $Root -Direction ([string]$Project.Direction)
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($items.ToArray())) {
        $pending.Add($item) | Out-Null
    }
    $maxChars = Get-YakuMaxCharsPerFileBatch -Settings $Settings
    $batches = @(Split-YakuFileTranslationItems -Items @($pending.ToArray()) -MaxChars $maxChars)
    $calls3h = 0; try { $calls3h = Get-YakuCopilotCallCount -WindowHours 3 } catch {}
    return [pscustomobject]@{
        UniqueRemaining = $items.Count; CacheHits = 0; Pending = $pending.Count
        EstimatedCalls = $batches.Count; CallsLast3h = $calls3h; MaxChars = $maxChars
    }
}

function Protect-YakuCatItems {
    <#
      CAT が送る項目を、送信前に伏せる。

      **なぜ Project ではなく items を受け取るのか。**

      翻訳のジョブは別のランスペースで走るので、メモリ上のプロジェクトを
      触れない（Server.ps1 のコメント参照）。そのため Project を受け取る形の
      関数はジョブから呼べず、同じ処理が Server.ps1 の中に書き直されていた。
      そして**マスクは書き直された側に入っていなかった。**

      結果、2026-08-08 の時点で CAT の「残りを訳す」は実数値と人名を素のまま
      Copilot へ送っていた。「CAT 経路が数値をマスクせずに送っていたのを直した」
      という記録は誤りで、直した先は呼び出し元が0件の関数だった。
      統制テストも CatProject.ps1 の本文を grep していたので通っていた。

      同じ失敗を繰り返さないため、マスクは**items だけを受け取る形**にする。
      これならジョブからも、プロジェクトを持つ経路からも同じものを呼べる。

      順序は翻訳経路と同じ。単位変換 → 数値。表は項目へ持たせ、復元で使う。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Direction
    )
    $maskedItems = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $text = [string]$item.Text
        $item | Add-Member -NotePropertyName OriginalText -NotePropertyValue $text -Force
        # CAT translation uses the dedicated canonical contract and protects every unit here.
        # 呼ぶため、ここで単位変換を済ませる。先に数値を伏せると
        # 18万6千台 が [[N1]]万[[N2]]千台 に割れ、1つの数量へ戻せない。
        $numericPre = Convert-YakuNumericUnits -Text $text -Location ("cat-ID-" + [string]$item.Index)
        $text = [string]$numericPre.Text
        $maskResult = New-YakuNumericMaskMap -Text $text -Root $Root -Direction $Direction -Location ("cat-ID-" + [string]$item.Index)
        $item | Add-Member -NotePropertyName NumericMaskMap -NotePropertyValue $maskResult.Map -Force
        $item | Add-Member -NotePropertyName MaskedText -NotePropertyValue ([string]$maskResult.Text) -Force
        $item | Add-Member -NotePropertyName ProtectionContractVersion -NotePropertyValue 'cat-protection-v1' -Force
        $item.Text = [string]$maskResult.Text
        if ([int]$maskResult.MaskedCount -gt 0) { $maskedItems++ }
    }
    try { Write-YakuLog "CAT numeric masking. items=$(@($Items).Count) maskedItems=$maskedItems" 'INFO' } catch {}
    return [pscustomobject]@{ MaskedItems = [int]$maskedItems }
}

function Restore-YakuCatItemTranslations {
    <#
      訳文の伏せ字を実値へ戻す。個数が合わなければ警告する。
      無言で数値が消えるのを避ける。
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory=$true)]$Map,
        [AllowNull()]$Warnings,
        [ValidateSet('auto','to_en','to_jp')][string]$Direction='auto'
    )
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $idx = [int]$item.Index
        if (-not $Map.ContainsKey($idx)) { continue }
        $maskMap = $null
        try { $maskMap = $item.NumericMaskMap } catch { $maskMap = $null }
        $hasNumeric = ($null -ne $maskMap -and $maskMap.Count -gt 0)
        $translated = [string]$Map[$idx]
        # 修正の往復では、実値へ戻す前の訳文だけを Copilot へ送り返す。
        # 画面に出す実値入り訳文とは分けて、セグメントへ引き継げるよう残す。
        $item | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue $translated -Force
        if (-not $hasNumeric) { continue }
        if ($hasNumeric) {
            try {
                $integrity = Test-YakuNumericMaskIntegrity -MaskedSource ([string]$item.MaskedText) -Translated $translated -Location ("cat-ID-" + [string]$idx)
                if (-not [bool]$integrity.Ok -and $null -ne $Warnings) {
                    Add-YakuWarning -Warnings $Warnings -Location ("ID $idx") -Category 'numeric-mask-integrity' `
                        -Details @{ Detail = [string]$integrity.Detail } `
                        -Message "数値の個数が原文と一致しないため、この行の訳文は取り込みませんでした。もう一度「残りの訳案を作る」を押してください。($([string]$integrity.Detail))"
                }
                if (-not [bool]$integrity.Ok) {
                    # 数値が欠けた・重複した・原文に無い数値が増えた。§8「数値が抜けた訳は
                    # 警告ではなく欠陥」に従い、この訳文は取り込まない。
                    $Map.Remove($idx)
                    continue
                }
                if ([bool]$integrity.OutOfOrder -and $null -ne $Warnings) {
                    # 順序だけの違いでは捨てない。日英では語順が変わるのが自然で、
                    # 捨てると再実行しても同じ判定になり、その行は永久に埋まらなくなる。
                    # 実値の取り違えが疑わしい行は、確認時のQCが確定を止める。
                    Add-YakuWarning -Warnings $Warnings -Location ("ID $idx") -Category 'numeric-order-review' `
                        -Details @{ Detail = [string]$integrity.Detail } `
                        -Message "数値の並び順が原文と違います。訳文は取り込みましたので、どの数値がどこに掛かるかをご確認ください。"
                }
            } catch {}
            $translated = Restore-YakuNumericMask -Text $translated -Map $maskMap -Direction $Direction -SourceText ([string]$item.MaskedText)
            try { $item.Text = Restore-YakuNumericMask -Text ([string]$item.Text) -Map $maskMap -Direction 'auto' -SourceText ([string]$item.MaskedText) } catch {}
        }
        if($Direction -eq 'to_en'){
            try{$translated=ConvertTo-YakuNaturalEnglishNotation -SourceText ([string]$item.OriginalText) -Translation $translated}catch{}
        }
        $Map[$idx] = $translated
    }
}

function Get-YakuCatTextPieces {
    <#
      テキストのセグメントが抱えている元の文を返す。

      繋いだものは Pieces を持ち、繋いでいないものは持たない。
      @($null) は「空」ではなく「null が1つ入った配列」になるので、
      件数で判断する前に必ず空要素を落とす。
    #>
    param([Parameter(Mandatory=$true)]$Segment)
    $pieces = @()
    try { $pieces = @(@($Segment.Pieces) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) } catch { $pieces = @() }
    if ($pieces.Count -eq 0) { $pieces = @([string]$Segment.Text) }
    return @($pieces)
}

function Set-YakuCatSegments {
    # 並べ替えたセグメントを差し戻す。訳文と出どころは各セグメントが持つ。
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Segments)
    $Project.Segments = @($Segments)
}

function Merge-YakuCatSegments {
    <#
      隣り合うセグメントを1つに繋ぐ。

      なぜ手で繋げるようにするのか:

        繋ぐ判定は「同じ列で行が連続し、他に埋まったセルが無く、句点で
        終わっていない」という目に見える事実だけで決めている。それでも
        自動で完璧に分けるのは無理である（利用者の指摘 2026-08-06）。
        外れたときに人が直せることが、この作りの前提になっている。

      訳文は消す:

        繋いだ後の原文は、繋ぐ前とは別の文である。前の訳文は断片の訳
        なので、残すと「一見良さげだが中身が合っていない」状態を自分で
        作ることになる。それはこの作り直しがいちばん避けたかったものである。

      繋げるのはセルどうし、同じシートのものだけ。図形はレイアウト上の
      位置で並ぶので、セルの並びへ混ぜられない。
    #>
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][int]$Index)
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge ($segs.Count - 1)) { throw '次のセグメントがありません。' }
    $a = $segs[$Index]
    $b = $segs[$Index + 1]
    if ([string]$a.Kind -ne [string]$b.Kind) { throw '種類が違うため結合できません。' }
    if ([string]$a.Kind -eq 'text') {
        # 貼り付けたテキスト。戻すセルが無いので、本文を繋ぐだけでよい。
        # 元の文は覚えておく。解除して1文ずつへ戻せるようにするため。
        $pieces = @(@(Get-YakuCatTextPieces -Segment $a) + @(Get-YakuCatTextPieces -Segment $b))
        $joiner = if ((@($pieces) -join '') -match '[぀-ヿ一-鿿]') { '' } else { ' ' }
        $merged = [pscustomobject]@{
            Text = (@($pieces) -join $joiner); BlockIds = @(); Cells = @(); Joined = $true
            Kind = 'text'; Sheet = ''; Location = '本文'; Pieces = @($pieces)
            Translation = ''; Origin = ''
        }
        $out = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($i -eq $Index) { [void]$out.Add($merged); continue }
            if ($i -eq ($Index + 1)) { continue }
            [void]$out.Add($segs[$i])
        }
        Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
        return $Project
    }
    if ([string]$a.Kind -ne 'cell') { throw 'セル以外は結合できません。' }
    if ([string]$a.Sheet -ne [string]$b.Sheet) { throw 'シートが違うため結合できません。' }
    $merged = New-YakuCellSegment -Sheet ([string]$a.Sheet) -Cells (@($a.Cells) + @($b.Cells)) -Joined $true
    $merged | Add-Member -NotePropertyName 'Translation' -NotePropertyValue '' -Force
    $merged | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '' -Force
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($i -eq $Index) { [void]$out.Add($merged); continue }
        if ($i -eq ($Index + 1)) { continue }
        [void]$out.Add($segs[$i])
    }
    Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
    return $Project
}

function Split-YakuCatSegment {
    <#
      繋がっているセグメントを、元のセル1つずつへ戻す。

      「隣と繋ぐ」と「元へ戻す」の2つがあれば、どんなまとめ方にも
      到達できる。途中で切る操作は入れない。操作が増えるだけで、
      できることは変わらない。

      訳文は消す。理由は Merge-YakuCatSegments と同じ。
    #>
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][int]$Index)
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'セグメントが見つかりません。' }
    $target = $segs[$Index]
    if ([string]$target.Kind -eq 'text') {
        $pieces = @(Get-YakuCatTextPieces -Segment $target)
        if ($pieces.Count -le 1) { throw 'このセグメントは繋がっていません。' }
        $out = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($i -ne $Index) { [void]$out.Add($segs[$i]); continue }
            foreach ($p in $pieces) {
                [void]$out.Add([pscustomobject]@{
                    Text = [string]$p; BlockIds = @(); Cells = @(); Joined = $false
                    Kind = 'text'; Sheet = ''; Location = '本文'
                    Translation = ''; Origin = ''
                })
            }
        }
        Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
        return $Project
    }
    if ([string]$target.Kind -ne 'cell') { throw 'セル以外は解除できません。' }
    $cells = @($target.Cells)
    if ($cells.Count -le 1) { throw 'このセグメントは繋がっていません。' }
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($i -ne $Index) { [void]$out.Add($segs[$i]); continue }
        foreach ($c in $cells) {
            $one = New-YakuCellSegment -Sheet ([string]$target.Sheet) -Cells @($c) -Joined $false
            $one | Add-Member -NotePropertyName 'Translation' -NotePropertyValue '' -Force
            $one | Add-Member -NotePropertyName 'Origin' -NotePropertyValue '' -Force
            [void]$out.Add($one)
        }
    }
    Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
    return $Project
}

function Get-YakuCatSegmentOriginPage {
    <# OOXMLだけではWordの描画後ページ番号を確定できない。adapterがページを
       取得できた形式だけ正数を返し、取れない場合は0（不明）を明示する。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Segment
    )
    foreach ($propertyName in @('Page', 'PageNumber')) {
        try {
            $value = [int]$Segment.$propertyName
            if ($value -gt 0) { return $value }
        } catch {}
    }
    $blockIds = @($Segment.BlockIds | ForEach-Object { [string]$_ })
    foreach ($block in @($Project.Blocks)) {
        if ($blockIds.Count -gt 0 -and $blockIds -notcontains [string]$block.Id) { continue }
        foreach ($owner in @($block, $block.Meta)) {
            if ($null -eq $owner) { continue }
            foreach ($propertyName in @('Page', 'PageNumber')) {
                try {
                    $value = [int]$owner.$propertyName
                    if ($value -gt 0) { return $value }
                } catch {}
            }
        }
    }
    return 0
}

function Get-YakuCatSegmentCandidates {
    <#
      1つのセグメントに対する候補を返す。CAT エディタの中核にあたる部分。

      市販ツールはここに 翻訳メモリ・用語集・機械翻訳 を一致率つきで並べ、
      Ctrl+数字 で差し込めるようにしている。訳す前に「過去はどう訳したか」が
      目に入ることが、一貫性を保つ仕組みそのものになっている。

      出せるのは用語集と、過去の対訳（コーパスの対）である。

      対訳のほうは長く出せなかった。コーパスが英文しか持たず、日本語の
      原文から英語の検索語を作るのに Copilot への往復が要ったためで、
      行を移るたびには引けなかった（利用者の指摘 2026-08-06）。
      Copilot によるアライメントで日英の対が取れるようになり、日本語の
      まま引けるようになったので、ここへ出す。

      翻訳メモリ（この利用者自身が確定した訳）はまだ無い。

      完全一致だけでなく部分一致も出す。表のラベルは完全一致で機械置換
      できるが、文の中に現れた語は置換しない（活用と一致が壊れるため。
      実機検証結果 §3-2）。置換しないからこそ、目に入る場所へ出す値打ちがある。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [int]$Max = 8,
        # Read compatibility only. Corpus candidates are retired and this
        # value is intentionally ignored.
        [AllowNull()][string]$PairsDir
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { return @() }
    $text = [string]$segs[$Index].Text
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $sourceKey = ConvertTo-YakuGlossaryMatchKey -Value (ConvertTo-YakuGlossaryField -Value $text)

    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    # 翻訳用語集。全文候補とは別種であり、UIでは訳文のカーソル位置へ
    # 語だけを挿入する。Candidate.Targetで訳文全体を上書きしてはならない。
    try {
        $termEntries = @(Get-YakuCatTerminologyEntries -Project $Project)
        foreach ($term in @(Find-YakuTerminologyMatches -Text $text -Direction ([string]$Project.Direction) -Entries $termEntries -ProjectId ([string]$Project.Id))) {
            $termKey = 'term' + [char]31 + [string]$term.ReferenceId
            if ($seen.ContainsKey($termKey)) { continue }
            $seen[$termKey] = $true
            $sourceName = if ([string]$term.Scope -eq 'project') { 'この資料の用語集' } else { '個人用語集' }
            [void]$out.Add([pscustomobject]@{
                Kind='term'; Source=[string]$term.SourceTerm; Target=[string]$term.PreferredTarget; Exact=$false
                ReferenceId=[string]$term.ReferenceId; SourceName=$sourceName; Location=[string]$term.Entry.origin_location
                Page=0; MatchedTerms=@([string]$term.SourceTerm); Database=$sourceName; Verified=$false
                Ratio=0.0; Weight=40000 + [int]$term.Length; TermId=[string]$term.TermId; TermVersion=[int]$term.Version
                Scope=[string]$term.Scope; Enforcement=[string]$term.Enforcement
                AllowedTargets=@($term.AllowedTargets); ForbiddenTargets=@($term.ForbiddenTargets)
            })
        }
    } catch {
        try { Write-YakuLog ('Terminology candidates unavailable: ' + $_.Exception.Message) 'WARN' } catch {}
    }

    # このprojectに結び付いた前回版の対応行。貼り付けた日英は承認済みと
    # 自己申告させず、自動適用もしないが、出典付き候補として明示的に
    # 挿入できるようにする。これが3-way更新で前回英語を下敷きにする入口。
    $priorSource = $(try { [string]$segs[$Index].PriorSourceText } catch { '' })
    $priorTarget = $(try { [string]$segs[$Index].PriorTranslation } catch { '' })
    if (-not [string]::IsNullOrWhiteSpace($priorTarget)) {
        $priorExact = (-not [string]::IsNullOrWhiteSpace($priorSource) -and
            [string]::Equals((ConvertTo-YakuGlossaryMatchKey -Value $priorSource), $sourceKey, [StringComparison]::Ordinal))
        $priorIndex = $(try { [int]$segs[$Index].PriorIndex } catch { $Index })
        $priorName = $(if ([string]::IsNullOrWhiteSpace([string]$Project.FileName)) { '前回版' } else { [string]$Project.FileName + '（前回版）' })
        $priorLocation = '前回版 段落 ' + [string]($priorIndex + 1)
        $priorReferenceId = Get-YakuCatSourceIntegrityHash -Text ('prior|' + [string]$Project.Id + '|' + [string]$segs[$Index].SegmentId + '|' + $priorSource + '|' + $priorTarget)
        $seen['prior' + [string][char]31 + $priorSource + [string][char]31 + $priorTarget] = $true
        [void]$out.Add([pscustomobject]@{
            Kind='prior'; Source=$priorSource; Target=$priorTarget; Exact=$priorExact
            ReferenceId=$priorReferenceId; SourceName=$priorName; Location=$priorLocation; Page=0
            MatchedTerms=@(); Database='前回版'; Verified=$false
            Ratio=$(if($priorExact){1.0}else{0.0}); Weight=29000
        })
    }
    # 翻訳メモリ。自分が確定した訳なので、どれよりも先に出す。
    # 公表訳は「読ませる訳」で意訳が多いが、これは自分の文体で、
    # 自分が正しいと判断したものだけが入っている。そのまま差し込める。
    try {
        foreach ($tm in @(Find-YakuTranslationMemory -Text $text -Direction ([string]$Project.Direction) -Limit 5)) {
            $key = 'tm' + [string][char]31 + [string]$tm.Source + [string][char]31 + [string]$tm.Target
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$out.Add([pscustomobject]@{
                Kind     = 'memory'
                Source   = [string]$tm.Source
                Target   = [string]$tm.Target
                Exact    = [bool]$tm.Exact
                ReferenceId = [string]$tm.ReferenceId
                SourceName = [string]$tm.SourceName
                Location = [string]$tm.Location
                Page = [int]$tm.Page
                MatchedTerms = @()
                Database = '翻訳メモリ'
                Verified = $true
                Ratio    = [double]$tm.Ratio
                MatchType = [string]$tm.MatchType
                Score = [double]$tm.Score
                Saved = [string]$tm.Saved
                OriginProjectId = [string]$tm.OriginProjectId
                OriginSegmentId = [string]$tm.OriginSegmentId
                ReviewRevision = [int]$tm.ReviewRevision
                # この端末で確認した訳。候補挿入後にも再QC・再確認が必要。
                Weight   = 30000 + [int]([double]$tm.Ratio * 1000)
            })
        }
    } catch {
        # 翻訳メモリが読めなくても候補ペインごと落とさない。
        try { Write-YakuLog ('Translation memory candidates unavailable: ' + $_.Exception.Message) 'WARN' } catch {}
    }

    $ordered = @($out.ToArray() | Sort-Object -Property @{ Expression = { [int]$_.Weight }; Descending = $true })
    # 用語と全文候補は別の作業なので、同じ上限を奪い合わせない。多数の
    # 用語がある行でも、TMや前回版の全文候補を最低限同じ件数まで探せる。
    $terms = @($ordered | Where-Object { [string]$_.Kind -eq 'term' } | Select-Object -First $Max)
    $segments = @($ordered | Where-Object { [string]$_.Kind -ne 'term' } | Select-Object -First $Max)
    return @($terms + $segments)
}

function Update-YakuCatSegmentReferenceEditState {
    param(
        [Parameter(Mandatory=$true)]$Segment,
        [AllowNull()][string]$Text
    )
    if ($null -eq $Segment.ReferenceUsage) { return $Segment }
    $newHash = Get-YakuCatSourceIntegrityHash -Text ([string]$Text)
    if ([string]$Segment.ReferenceUsage.target_hash -ne $newHash) {
        $Segment.ReferenceUsage.edited_after_insert = $true
    }
    foreach ($event in @($Segment.ReferenceEvents)) {
        if ([string]$event.action -eq 'inserted' -and [string]$event.target_hash -ne $newHash) {
            $event.edited_after_insert = $true
        }
    }
    foreach ($usage in @($Segment.TerminologyUsages)) {
        if ([string]$usage.target_hash -ne $newHash) { $usage.edited_after_insert = $true }
    }
    return $Segment
}

function Set-YakuCatSegmentTranslation {
    <#
      人が直した訳文を入れる。以後、機械の処理はここを触らない。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [AllowNull()][string]$Text
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw ('セグメントが見つかりません: ' + $Index) }
    $translation = [string]$Text
    $hasTranslation = -not [string]::IsNullOrWhiteSpace($translation)
    $segs[$Index].Translation = $translation
    $null = Update-YakuCatSegmentReferenceEditState -Segment $segs[$Index] -Text $translation
    # 人が書き換えた訳文は、以前のマスク後訳文ともう対応しない。
    $segs[$Index] | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue '' -Force
    $segs[$Index].Origin = $(if ($hasTranslation) { 'manual' } else { '' })
    $segs[$Index] | Add-Member -NotePropertyName State -NotePropertyValue $(if ($hasTranslation) { 'human_edited' } else { 'untranslated' }) -Force
    Reset-YakuCatSegmentQc -Segment $segs[$Index] -KeepState
    return $segs[$Index]
}

function Set-YakuCatSegmentReferenceUsage {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)]$Candidate
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'CAT_REFERENCE_SEGMENT_NOT_FOUND' }
    if ([string]$Candidate.ReferenceId -notmatch '^[a-f0-9]{16,64}$') { throw 'CAT_REFERENCE_ID_INVALID' }
    if (-not [string]::Equals([string]$segs[$Index].Translation, [string]$Candidate.Target, [StringComparison]::Ordinal)) {
        throw 'CAT_REFERENCE_TARGET_MISMATCH'
    }
    $segs[$Index].ReferenceUsage = [pscustomobject]@{
        id = [string]$Candidate.ReferenceId
        kind = [string]$Candidate.Kind
        action = 'inserted'
        target_hash = Get-YakuCatSourceIntegrityHash -Text ([string]$segs[$Index].Translation)
        edited_after_insert = $false
        source_name = [string]$Candidate.SourceName
        location = [string]$Candidate.Location
        page = [int]$Candidate.Page
        source = [string]$Candidate.Source
        translation = [string]$Candidate.Target
    }
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($existing in @($segs[$Index].ReferenceEvents)) { $events.Add($existing) | Out-Null }
    $events.Add([pscustomobject]@{
        event_id=[guid]::NewGuid().ToString('N'); reference_id=[string]$Candidate.ReferenceId
        kind=[string]$Candidate.Kind; action='inserted'; source_name=[string]$Candidate.SourceName
        location=[string]$Candidate.Location; page=[int]$Candidate.Page
        source=[string]$Candidate.Source; translation=[string]$Candidate.Target
        match_score=$(try { [double]$Candidate.Score } catch { [double]$Candidate.Ratio })
        target_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$segs[$Index].Translation)
        project_revision=[int]$Project.Revision; created=(Get-Date).ToString('s'); edited_after_insert=$false
    }) | Out-Null
    $segs[$Index].ReferenceEvents = @($events.ToArray())
    return $segs[$Index]
}

function Set-YakuCatSegmentTerminologyUsage {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)]$Candidate
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'CAT_TERM_SEGMENT_NOT_FOUND' }
    if ([string]$Candidate.Kind -notin @('term','glossary')) { throw 'CAT_TERM_REFERENCE_KIND_INVALID' }
    $target = [string]$Candidate.Target
    if ([string]::IsNullOrWhiteSpace($target) -or ([string]$segs[$Index].Translation).IndexOf($target, [StringComparison]::Ordinal) -lt 0) {
        throw 'CAT_TERM_TARGET_NOT_PRESENT'
    }
    $usages = New-Object System.Collections.Generic.List[object]
    foreach ($usage in @($segs[$Index].TerminologyUsages)) { $usages.Add($usage) | Out-Null }
    $usages.Add([pscustomobject]@{
        reference_id=[string]$Candidate.ReferenceId; term_id=$(try { [string]$Candidate.TermId } catch { '' })
        term_version=$(try { [int]$Candidate.TermVersion } catch { 0 }); source=[string]$Candidate.Source
        preferred_target=$target; source_name=[string]$Candidate.SourceName; action='inserted'
        target_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$segs[$Index].Translation)
        edited_after_insert=$false; created=(Get-Date).ToString('s')
    }) | Out-Null
    $segs[$Index].TerminologyUsages = @($usages.ToArray())
    return $segs[$Index]
}

function Add-YakuCatTerminologyException {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][string]$TermId,
        [Parameter(Mandatory=$true)][int]$TermVersion,
        [ValidateSet('not-applicable','approved-alternative')][string]$ReasonCode='not-applicable',
        [AllowNull()][string]$Alternative,
        [AllowNull()][string]$Note
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'CAT_TERM_SEGMENT_NOT_FOUND' }
    $entries = @(Get-YakuCatTerminologyEntries -Project $Project | Where-Object { [string]$_.term_id -eq $TermId -and [int]$_.version -eq $TermVersion })
    if ($entries.Count -ne 1) { throw 'CAT_TERM_REFERENCE_NOT_AVAILABLE' }
    $alternativeText = ([string]$Alternative).Trim()
    if ($ReasonCode -eq 'approved-alternative') {
        if ([string]::IsNullOrWhiteSpace($alternativeText)) { throw 'CAT_TERM_ALTERNATIVE_REQUIRED' }
        if (([string]$segs[$Index].Translation).IndexOf($alternativeText, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'CAT_TERM_ALTERNATIVE_NOT_PRESENT' }
    }
    $exceptions = New-Object System.Collections.Generic.List[object]
    foreach ($exception in @($segs[$Index].TerminologyExceptions)) { $exceptions.Add($exception) | Out-Null }
    $exceptions.Add([pscustomobject]@{
        term_id=$TermId; term_version=$TermVersion; reference_id=[string]$entries[0].reference_id
        source_hash=Get-YakuTerminologyHash -Text ([string]$segs[$Index].Text)
        target_hash=Get-YakuTerminologyHash -Text ([string]$segs[$Index].Translation)
        reason_code=$ReasonCode; alternative=$alternativeText; note=([string]$Note).Trim()
        active=$true; created=(Get-Date).ToString('s')
    }) | Out-Null
    $segs[$Index].TerminologyExceptions = @($exceptions.ToArray())
    Reset-YakuCatSegmentQc -Segment $segs[$Index] -KeepState
    return $segs[$Index]
}

function Add-YakuCatTranslationMemoryOutboxEvent {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)]$Segment)
    $eventId = Get-YakuCatSourceIntegrityHash -Text ('tm-outbox-v1|' + [string]$Project.Id + '|' + [string]$Segment.SegmentId + '|' + [string]$Project.Revision + '|' + [string]$Segment.SourceIntegrityHash + '|' + (Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation)))
    if (@($Project.TmOutbox | Where-Object { [string]$_.event_id -eq $eventId }).Count -gt 0) { return $eventId }
    $outbox = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($Project.TmOutbox)) { $outbox.Add($event) | Out-Null }
    $outbox.Add([pscustomobject]@{
        event_id=$eventId; source=[string]$Segment.Text; target=[string]$Segment.Translation
        direction=[string]$Project.Direction; origin_project_id=[string]$Project.Id
        origin_file_name=[string]$Project.FileName; origin_segment_id=[string]$Segment.SegmentId
        origin_location=[string]$Segment.Location; origin_page=Get-YakuCatSegmentOriginPage -Project $Project -Segment $Segment
        review_revision=[int]$Project.Revision + 1; created=(Get-Date).ToString('s')
    }) | Out-Null
    $Project.TmOutbox = @($outbox.ToArray())
    return $eventId
}

function Sync-YakuCatTranslationMemoryOutbox {
    param([Parameter(Mandatory=$true)]$Project)
    $pending = 0
    foreach ($event in @($Project.TmOutbox)) {
        try {
            $result = Add-YakuTranslationMemoryEntry -Source ([string]$event.source) -Target ([string]$event.target) `
                -Direction ([string]$event.direction) -Origin 'cat-reviewed-qc-v1' `
                -OriginProjectId ([string]$event.origin_project_id) -OriginFileName ([string]$event.origin_file_name) `
                -OriginSegmentId ([string]$event.origin_segment_id) -OriginLocation ([string]$event.origin_location) `
                -OriginPage ([int]$event.origin_page) -ReviewRevision ([int]$event.review_revision)
            if ($null -eq $result) { $pending++ }
        } catch {
            $pending++
            try { Write-YakuLog ('Translation memory outbox pending. event=' + [string]$event.event_id + ' error=' + $_.Exception.Message) 'WARN' } catch {}
        }
    }
    $Project | Add-Member -NotePropertyName TmPendingCount -NotePropertyValue ([int]$pending) -Force
    return [int]$pending
}

function Update-YakuCatProjectForTerminologyChange {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)]$Entry)
    $affected = 0
    foreach ($segment in @($Project.Segments)) {
        $matches = @(Find-YakuTerminologyMatches -Text ([string]$segment.Text) -Direction ([string]$Project.Direction) -Entries @($Entry) -ProjectId ([string]$Project.Id))
        if ($matches.Count -eq 0) { continue }
        $affected++
        if ([bool]$segment.Confirmed -or [string]$segment.QcStatus -eq 'passed') {
            Reset-YakuCatSegmentQc -Segment $segment
            $segment.State = 'stale'
        }
    }
    $Project.TerminologySnapshotHash = Get-YakuCatTerminologySnapshotHash -Project $Project
    return $affected
}

function Set-YakuCatSegmentConfirmed {
    <#
      「この行は見た」を記録する。訳文が変わっていなくても押せる。

      市販の CAT ツールで Ctrl+Enter が担っている役目である。機械訳を読んで
      「これで良い」と判断したことは、直したことと同じくらい記録に値する。
      記録が無いと、翌日再開したときに「どこまで見たか」が分からない。

      訳文が空の行は確定できない。読むものが無いのに見たとは言えない。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [bool]$Confirmed = $true
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw ('セグメントが見つかりません: ' + $Index) }
    if ($Confirmed -and [string]::IsNullOrWhiteSpace([string]$segs[$Index].Translation)) {
        throw '訳文が空の行は確定できません。'
    }
    if (-not $Confirmed) {
        $fallback = if ([string]$segs[$Index].Origin -eq 'manual') { 'human_edited' } elseif ([string]::IsNullOrWhiteSpace([string]$segs[$Index].Translation)) { 'untranslated' } else { 'machine_draft' }
        $segs[$Index].State = $fallback
        $segs[$Index].Confirmed = $false
        return $segs[$Index]
    }
    $validation = Invoke-YakuCatSegmentValidation -Project $Project -Segment $segs[$Index]
    if (-not [bool]$validation.Passed) {
        $segs[$Index].Confirmed = $false
        throw ('CAT_REVIEW_QC_FAILED: ' + (@($validation.Findings | ForEach-Object { [string]$_.Code }) -join ','))
    }
    $segs[$Index].State = 'reviewed'
    $segs[$Index].Confirmed = $true
    return $segs[$Index]
}

function ConvertTo-YakuCatBlockMatchKey {
    <# 同じ原文ブロックかを比べる鍵。番地は意図的に含めない。 #>
    param([AllowNull()]$Block)
    if ($null -eq $Block) { return '' }
    $kind = ''; $text = ''
    try { $kind = [string]$Block.Meta.Kind } catch { $kind = '' }
    try { $text = [string]$Block.Text } catch { $text = '' }
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    try { $text = $text.Normalize([Text.NormalizationForm]::FormKC) } catch {}
    $text = [regex]::Replace($text.Trim(), '\s+', ' ').ToLowerInvariant()
    return ($kind.ToLowerInvariant() + [char]31 + $text)
}

function Get-YakuCatBlockSheet {
    param([AllowNull()]$Block)
    try { return [string]$Block.Meta.Sheet } catch { return '' }
}

function Get-YakuCatSheetCodeName {
    param([AllowNull()][object[]]$Blocks, [AllowNull()][string]$Sheet)
    foreach ($block in @($Blocks)) {
        if ((Get-YakuCatBlockSheet $block) -ne [string]$Sheet) { continue }
        try {
            $code = [string]$block.Meta.SheetCodeName
            if (-not [string]::IsNullOrWhiteSpace($code)) { return $code }
        } catch {}
    }
    return ''
}

function Test-YakuCatSourceTextExact {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    # Excelの改行表現だけを揃える。大小文字・全半角・空白は意味を変え得るので
    # NFKCやTrimをせず、保存時と現在値のOrdinal一致を最終門にする。
    $a = ([string]$Left).Replace("`r`n", "`n").Replace("`r", "`n")
    $b = ([string]$Right).Replace("`r`n", "`n").Replace("`r", "`n")
    return [string]::Equals($a, $b, [StringComparison]::Ordinal)
}

function Get-YakuCatUniqueBlockPairs {
    <# 両側で一度だけ現れる原文を錨候補にする。 #>
    param([AllowNull()][object[]]$Left, [AllowNull()][object[]]$Right)
    $l = @($Left); $r = @($Right)
    $lc = @{}; $rc = @{}; $li = @{}; $ri = @{}
    for ($i = 0; $i -lt $l.Count; $i++) {
        $k = ConvertTo-YakuCatBlockMatchKey -Block $l[$i]
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $lc.ContainsKey($k)) { $lc[$k] = 0 }
        $lc[$k]++; $li[$k] = $i
    }
    for ($i = 0; $i -lt $r.Count; $i++) {
        $k = ConvertTo-YakuCatBlockMatchKey -Block $r[$i]
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $rc.ContainsKey($k)) { $rc[$k] = 0 }
        $rc[$k]++; $ri[$k] = $i
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($k in $lc.Keys) {
        if ([int]$lc[$k] -ne 1 -or -not $rc.ContainsKey($k) -or [int]$rc[$k] -ne 1) { continue }
        [void]$pairs.Add([pscustomobject]@{ Key = $k; L = [int]$li[$k]; R = [int]$ri[$k] })
    }
    return @(@($pairs.ToArray()) | Sort-Object -Property L)
}

function Resolve-YakuCatExportBlocks {
    <#
      取り込み時と現在の原文ブロックを対応付ける純粋関数。

      一意な原文を錨にし、CellAlign.ps1 と同じ最長増加部分列で順序が
      保たれる錨だけを採る。重複原文は錨に挟まれた区間内で一意な場合だけ
      対応付ける。決められないものを旧番地で推測することはしない。
    #>
    param(
        [AllowNull()][object[]]$OriginalBlocks,
        [AllowNull()][object[]]$CurrentBlocks,
        [AllowNull()][string[]]$RequiredBlockIds
    )
    if (-not (Get-Command Get-YakuLongestIncreasingPairs -ErrorAction SilentlyContinue)) {
        throw 'CAT_EXPORT_ALIGN_UNAVAILABLE: 原文再対応付けの部品を読み込めませんでした。'
    }
    $old = @($OriginalBlocks); $cur = @($CurrentBlocks)
    $required = @{}
    foreach ($id in @($RequiredBlockIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { $required[[string]$id] = $true }
    }
    $errors = New-Object System.Collections.Generic.List[string]
    $map = @{}; $usedCurrent = @{}; $sheetMatches = @{}
    $oldSheets = New-Object System.Collections.Generic.List[string]
    $curSheets = New-Object System.Collections.Generic.List[string]
    foreach ($b in $old) { $s = Get-YakuCatBlockSheet $b; if (-not $oldSheets.Contains($s)) { [void]$oldSheets.Add($s) } }
    foreach ($b in $cur) { $s = Get-YakuCatBlockSheet $b; if (-not $curSheets.Contains($s)) { [void]$curSheets.Add($s) } }
    $usedSheets = @{}

    # 同名シートを先に確定する。
    foreach ($s in @($oldSheets.ToArray())) {
        if (-not $curSheets.Contains($s)) { continue }
        $oldCode = Get-YakuCatSheetCodeName -Blocks $old -Sheet $s
        $newCode = Get-YakuCatSheetCodeName -Blocks $cur -Sheet $s
        if (-not [string]::IsNullOrWhiteSpace($oldCode) -and -not [string]::IsNullOrWhiteSpace($newCode) -and $oldCode -ne $newCode) { continue }
        $sheetMatches[$s] = $s; $usedSheets[$s] = $true
    }
    # 改名されたシートはまず Worksheet.CodeName で追う。Excel環境によって
    # CodeNameが空の場合だけ、両側のほぼ全原文が同じ順序にある候補へ限定する。
    foreach ($s in @($oldSheets.ToArray())) {
        if ($sheetMatches.ContainsKey($s)) { continue }
        $oldCode = Get-YakuCatSheetCodeName -Blocks $old -Sheet $s
        if (-not [string]::IsNullOrWhiteSpace($oldCode)) {
            $matches = New-Object System.Collections.Generic.List[string]
            foreach ($t in @($curSheets.ToArray())) {
                if ($usedSheets.ContainsKey($t)) { continue }
                if ((Get-YakuCatSheetCodeName -Blocks $cur -Sheet $t) -eq $oldCode) { [void]$matches.Add($t) }
            }
            if ($matches.Count -eq 1) {
                $sheetMatches[$s] = [string]$matches[0]; $usedSheets[[string]$matches[0]] = $true
            }
            continue
        }
        $left = @($old | Where-Object { (Get-YakuCatBlockSheet $_) -eq $s })
        $fallback = New-Object System.Collections.Generic.List[object]
        foreach ($t in @($curSheets.ToArray())) {
            if ($usedSheets.ContainsKey($t)) { continue }
            $right = @($cur | Where-Object { (Get-YakuCatBlockSheet $_) -eq $t })
            $ordered = @(Get-YakuLongestIncreasingPairs -Pairs @(Get-YakuCatUniqueBlockPairs -Left $left -Right $right))
            $leftCoverage = $ordered.Count / [double][Math]::Max(1, $left.Count)
            $rightCoverage = $ordered.Count / [double][Math]::Max(1, $right.Count)
            if ($ordered.Count -ge 3 -and $leftCoverage -ge 0.8 -and $rightCoverage -ge 0.8) {
                [void]$fallback.Add([pscustomobject]@{ Sheet=$t; Score=$ordered.Count })
            }
        }
        $ranked = @($fallback.ToArray() | Sort-Object -Property Score -Descending)
        if ($ranked.Count -eq 1 -or ($ranked.Count -gt 1 -and [int]$ranked[0].Score -gt [int]$ranked[1].Score)) {
            $picked = [string]$ranked[0].Sheet
            $sheetMatches[$s] = $picked; $usedSheets[$picked] = $true
        }
    }

    foreach ($s in @($oldSheets.ToArray())) {
        $leftAll = @($old | Where-Object { (Get-YakuCatBlockSheet $_) -eq $s })
        $neededHere = @($leftAll | Where-Object { $required.ContainsKey([string]$_.Id) })
        if ($neededHere.Count -eq 0) { continue }
        if (-not $sheetMatches.ContainsKey($s)) {
            foreach ($b in $neededHere) { [void]$errors.Add(('sheet-missing-or-ambiguous: ' + [string]$b.Id + ' / ' + $s)) }
            continue
        }
        $targetSheet = [string]$sheetMatches[$s]
        $rightAll = @($cur | Where-Object { (Get-YakuCatBlockSheet $_) -eq $targetSheet })
        $candidates = @(Get-YakuCatUniqueBlockPairs -Left $leftAll -Right $rightAll)
        $anchors = @(Get-YakuLongestIncreasingPairs -Pairs $candidates)
        $anchorByLeft = @{}
        foreach ($a in $anchors) { $anchorByLeft[[int]$a.L] = $a }

        foreach ($b in $neededHere) {
            $oldIndex = [array]::IndexOf($leftAll, $b)
            if ($oldIndex -lt 0) { [void]$errors.Add(('source-missing: ' + [string]$b.Id)); continue }
            $newIndex = -1
            if ($anchorByLeft.ContainsKey($oldIndex)) {
                $newIndex = [int]$anchorByLeft[$oldIndex].R
            } else {
                $prevL = -1; $prevR = -1; $nextL = $leftAll.Count; $nextR = $rightAll.Count
                foreach ($a in $anchors) {
                    if ([int]$a.L -lt $oldIndex) { $prevL = [int]$a.L; $prevR = [int]$a.R; continue }
                    if ([int]$a.L -gt $oldIndex) { $nextL = [int]$a.L; $nextR = [int]$a.R; break }
                }
                $key = ConvertTo-YakuCatBlockMatchKey -Block $b
                $oldHits = @(); $newHits = @()
                for ($i = $prevL + 1; $i -lt $nextL; $i++) {
                    if ((ConvertTo-YakuCatBlockMatchKey -Block $leftAll[$i]) -eq $key) { $oldHits += $i }
                }
                for ($i = $prevR + 1; $i -lt $nextR; $i++) {
                    if ((ConvertTo-YakuCatBlockMatchKey -Block $rightAll[$i]) -eq $key) { $newHits += $i }
                }
                if ($oldHits.Count -eq 1 -and $newHits.Count -eq 1) { $newIndex = [int]$newHits[0] }
            }
            if ($newIndex -lt 0 -or $newIndex -ge $rightAll.Count) {
                [void]$errors.Add(('source-missing-or-ambiguous: ' + [string]$b.Id + ' / ' + [string]$b.Location))
                continue
            }
            $currentBlock = $rightAll[$newIndex]
            $currentId = [string]$currentBlock.Id
            if ($usedCurrent.ContainsKey($currentId)) {
                [void]$errors.Add(('current-block-reused: ' + [string]$b.Id + ' -> ' + $currentId))
                continue
            }
            # 書込直前の最後の門。対応付け結果でも原文が一致しなければ使わない。
            if (-not (Test-YakuCatSourceTextExact -Left ([string]$b.Text) -Right ([string]$currentBlock.Text))) {
                [void]$errors.Add(('source-changed: ' + [string]$b.Id))
                continue
            }
            $usedCurrent[$currentId] = $true
            $map[[string]$b.Id] = $currentBlock
        }
    }
    foreach ($id in $required.Keys) {
        if (-not $map.ContainsKey($id) -and @($errors | Where-Object { $_ -match ('(^|: )' + [regex]::Escape($id) + '( /| ->|$)') }).Count -eq 0) {
            [void]$errors.Add(('snapshot-missing: ' + $id))
        }
    }
    return [pscustomobject]@{
        Success = ($errors.Count -eq 0)
        Map = $map
        Errors = @($errors.ToArray())
        SheetMatches = $sheetMatches
    }
}

function Export-YakuCatReviewedSegments {
    <#
      確認済みの行だけを取り出す。

      全行を確認し終えるまで何も取り出せないと、10分の細切れで使う利用者は
      成果ゼロで終わる。ここは「途中の成果を持ち帰る」ための経路であり、
      元ファイルへの書き戻し（Export-YakuCatProject）とは別物である。

      渡すのは reviewed の行だけ。未確認・未翻訳・自動点検が古い行は含めない。
      含めなかった行数を必ず返し、画面で「一部である」と言えるようにする。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $segments = @($Project.Segments)
    if ($segments.Count -eq 0) { throw 'CAT_REVIEWED_EXPORT_EMPTY: 翻訳する行がありません。' }

    $snapshotHash = [string]$Project.TerminologySnapshotHash
    $included = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    foreach ($segment in $segments) {
        $ok = ([string]$segment.State -eq 'reviewed') -and
              (-not [string]::IsNullOrWhiteSpace([string]$segment.Translation)) -and
              (Test-YakuCatSegmentQcCurrent -Segment $segment -TerminologySnapshotHash $snapshotHash)
        if ($ok) { $included.Add($segment) | Out-Null } else { $skipped++ }
    }
    if ($included.Count -eq 0) {
        throw 'CAT_REVIEWED_EXPORT_NONE: まだ確認済みの行がありません。行を「確認済みにする」と、その行だけ取り出せます。'
    }

    $lines = @($included | ForEach-Object { [string]$_.Translation })
    $locations = @($included | ForEach-Object { [string]$_.Location })
    return [pscustomobject]@{
        Text      = (@($lines) -join "`n")
        Written   = [int]$included.Count
        Skipped   = [int]$skipped
        Total     = [int]$segments.Count
        Locations = @($locations)
        Partial   = ([int]$skipped -gt 0)
    }
}

function Export-YakuCatProject {
    <#
      元の Excel をコピーし、そこへ訳文を書き戻す。

      繋いだセグメントは元のセルの長さを重みにして割り振る。
      訳の無いセグメントは書かない。既存の書き戻しは
      「訳文が原文と同じなら触らない」を守るので、原文のまま残る。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        # 貼り付けたテキストのときは空。書き戻す元のファイルが無い。
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$OutputPath,
        [AllowNull()]$Settings,
        [AllowNull()]$Warnings,
        [AllowNull()]$ProgressState
    )
    if ($null -eq $Warnings) { $Warnings = New-Object System.Collections.Generic.List[object] }
    $eligibility = Get-YakuCatOutputEligibility -Project $Project
    if (-not [bool]$eligibility.TranslationListEligible) {
        throw ('CAT_TRANSLATION_LIST_BLOCKED: 確認済み訳文一覧を出力できません。' + (@($eligibility.Reasons) -join ','))
    }
    $segs = @($Project.Segments)
    # 貼り付けたテキストは書き戻す元のファイルが無い。訳文を繋いで返すだけ。
    # 簡易翻訳と同じ終わり方（画面でコピーする）にして、覚えることを増やさない。
    if ([string]$Project.Source -in @('text','align','prior_version')) {
        $lines = @($segs | ForEach-Object { [string]$_.Translation })
        return [pscustomobject]@{
            OutputPath = ''
            OutputName = ''
            Text       = (@($lines) -join "`n")
            Written    = @($segs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
            Skipped    = @($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
        }
    }
    $documentFormat = $(try { [string]$Project.DocumentFormat } catch { '' })
    if ($documentFormat -eq 'docx') {
        if (-not [bool]$eligibility.WordDraftEligible) {
            # 体裁を保証できないWordは、ファイルを作らず確認済み訳文だけを返す。
            # 「一部だけ書けたWord」を完成物らしく見せないための縮退経路。
            $lines = @($segs | ForEach-Object { [string]$_.Translation })
            return [pscustomobject]@{
                OutputPath=''; OutputName=''; Text=(@($lines) -join "`n")
                Written=@($segs).Count; Skipped=0
            }
        }
        $writeResult = Export-YakuWordDraft -Project $Project -OutputPath $OutputPath
        return [pscustomobject]@{
            OutputPath = [string]$writeResult.PublishedPath
            OutputName = [IO.Path]::GetFileName([string]$writeResult.PublishedPath)
            Written = [int]$writeResult.WrittenCount
            Skipped = [int]$writeResult.SkippedCount
        }
    }
    if (-not [bool]$eligibility.ExcelDraftEligible) {
        throw ('CAT_EXCEL_DRAFT_BLOCKED: DRAFT Excelを安全に出力できません。' + (@($eligibility.Reasons) -join ','))
    }
    $bySegment = @{}
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $t = [string]$segs[$i].Translation
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $bySegment[$i] = $t
    }
    $byBlock = Get-YakuSegmentTranslationByBlockId -Segments $segs -TranslationBySegmentIndex $bySegment
    if (-not (Test-Path -LiteralPath ([string]$Project.Path) -PathType Leaf)) {
        throw 'CAT_EXPORT_SOURCE_MISSING: 元の Excel が見つかりません。移動または削除されていないか確認してください。'
    }
    $originalBlocks = @($Project.Blocks)
    if ($originalBlocks.Count -eq 0) {
        $originalBlocks = @(ConvertFrom-YakuCatSavedSegmentsToBlocks -Segments $segs)
    }
    $hashBefore = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    $currentExtract = Get-YakuExcelTextBlocks -Path ([string]$Project.Path) -Direction ([string]$Project.Direction) `
        -Settings $Settings -ProgressState $ProgressState
    $hashAfter = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    if ($hashBefore -ne $hashAfter) {
        throw 'CAT_EXPORT_SOURCE_CHANGED_DURING_READ: 原文を確認している間に元の Excel が変更されました。もう一度出力してください。'
    }
    foreach ($w in @($currentExtract.Warnings)) { try { [void]$Warnings.Add($w) } catch {} }
    $resolved = Resolve-YakuCatExportBlocks -OriginalBlocks $originalBlocks -CurrentBlocks @($currentExtract.Blocks) `
        -RequiredBlockIds @($byBlock.Keys)
    if (-not [bool]$resolved.Success) {
        throw ('CAT_EXPORT_SOURCE_MISMATCH: 元の Excel で行・シートの対応を一意に確認できませんでした。誤ったセルへの書き込みを防ぐため出力を中止しました。' + `
            ' 詳細: ' + (@($resolved.Errors) -join '; '))
    }
    $currentByBlock = @{}
    foreach ($oldId in @($byBlock.Keys)) {
        $newBlock = $resolved.Map[[string]$oldId]
        $currentByBlock[[string]$newBlock.Id] = [string]$byBlock[$oldId]
    }
    $sourceHashBeforeWrite = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    if ($sourceHashBeforeWrite -ne $hashAfter) {
        throw 'CAT_EXPORT_SOURCE_CHANGED_BEFORE_COPY: 元の Excel が出力直前に変更されました。訳文はまだ書き込んでいません。もう一度出力してください。'
    }
    $writeResult = Write-YakuFileTranslations -InputPath ([string]$Project.Path) -OutputPath $OutputPath -Blocks @($currentExtract.Blocks) `
        -TranslationByBlockId $currentByBlock -Warnings $Warnings -Settings $Settings -ProgressState $ProgressState -DraftMarker -FailOnIncomplete
    return [pscustomobject]@{
        OutputPath = [string]$writeResult.PublishedPath
        OutputName = [System.IO.Path]::GetFileName([string]$writeResult.PublishedPath)
        Written    = [int]$writeResult.WrittenCount
        Skipped    = [int]$writeResult.SkippedCount
    }
}
