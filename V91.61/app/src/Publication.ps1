<#
  Excelへ掲載するための短縮訳を、確認済みの基準訳から分離する。
  Copilotの候補はここでは確定しない。人が原文・基準訳・候補を比較して
  採用したときだけactive variantを作り、TMには登録しない。
#>

function Get-YakuCatAbbreviationRegistryHash {
    param([Parameter(Mandatory=$true)]$Project)
    $rows=@($Project.AbbreviationEntries|Sort-Object entry_id,version|ForEach-Object{
        [string]$_.entry_id+'|'+[string]$_.version+'|'+[string]$_.abbreviation+'|'+[string]$_.full_form+'|'+[string]$_.meaning+'|'+[string]$_.allowed_scope+'|'+[string]$_.scope_id+'|'+[string]$_.first_use_rule+'|'+[string]$_.active
    })
    return Get-YakuCatSourceIntegrityHash -Text ('abbreviation-registry-v1|'+($rows -join "`n"))
}

function Get-YakuCatPublicationVariantHash {
    <# 状態・時刻・監査eventを除いた不変payloadだけをvariant identityにする。 #>
    param([Parameter(Mandatory=$true)]$Variant)
    $payload=[ordered]@{
        variant_id=[string]$Variant.variant_id;segment_id=[string]$Variant.segment_id;revision=[int]$Variant.revision
        canonical_target_hash=[string]$Variant.canonical_target_hash;text_hash=[string]$Variant.text_hash
        change_kind=[string]$Variant.change_kind;abbreviation_use_ids=@($Variant.abbreviation_use_ids|ForEach-Object{[string]$_})
        generation_origin=[string]$Variant.generation_origin;semantic_review_status=[string]$Variant.semantic_review_status
        source_facts_hash=[string]$Variant.source_facts_hash;candidate_context_hash=[string]$(try{$Variant.candidate_context_hash}catch{''})
    }
    return Get-YakuCatSourceIntegrityHash -Text ($payload|ConvertTo-Json -Depth 10 -Compress)
}

function Register-YakuCatAbbreviationEntry {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$FullForm,[Parameter(Mandatory=$true)][string]$Abbreviation,[Parameter(Mandatory=$true)][string]$Meaning,[ValidateSet('document','project')][string]$Scope='document',[ValidateSet('none','define_first','source_defined_only')][string]$FirstUseRule='define_first')
    $full=([string]$FullForm).Trim();$abbr=([string]$Abbreviation).Trim();$meaning=([string]$Meaning).Trim()
    foreach($value in @($full,$abbr,$meaning)){if([string]::IsNullOrWhiteSpace($value)-or $value.Length -gt 300 -or $value -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){throw 'CAT_ABBREVIATION_ENTRY_INVALID'}}
    $conflicts=@($Project.AbbreviationEntries|Where-Object{[bool]$_.active -and ([string]$_.abbreviation -ieq $abbr -or [string]$_.full_form -ieq $full)})
    foreach($conflict in $conflicts){if([string]$conflict.abbreviation -ine $abbr -or [string]$conflict.full_form -ine $full -or [string]$conflict.meaning -ine $meaning){throw 'CAT_ABBREVIATION_CONFLICT'};return $conflict}
    $entry=[pscustomobject]@{entry_id=[guid]::NewGuid().ToString('N');full_form=$full;abbreviation=$abbr;meaning=$meaning;allowed_scope=$Scope;scope_id=$(if($Scope -eq 'project'){[string]$Project.Id}else{[string]$Project.ActiveSourceId});first_use_rule=$FirstUseRule;ambiguity='medium';source='user_registered';approved_by_human=$true;version=1;active=$true;created_at=(Get-Date).ToString('o')}
    $Project.AbbreviationEntries=@($Project.AbbreviationEntries)+@($entry);$dependency=Get-YakuCatSourceIntegrityHash -Text ($entry|ConvertTo-Json -Depth 8 -Compress)
    $event=Add-YakuCatHumanDecisionEvent -Project $Project -Scope abbreviation -Action entry_registered -ReasonCode user_registered -DependencyFingerprint $dependency;$entry|Add-Member -NotePropertyName decision_event_id -NotePropertyValue $event -Force
    return $entry
}

function Get-YakuCatActivePublicationVariant {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$SegmentId)
    $variantId='';try{$variantId=[string]$Project.ActivePublicationVariantBySegment.$SegmentId}catch{}
    if([string]::IsNullOrWhiteSpace($variantId)){return $null}
    $found=@($Project.PublicationVariants|Where-Object{[string]$_.variant_id -eq $variantId -and [string]$_.segment_id -eq $SegmentId -and [string]$_.status -eq 'active'}|Select-Object -First 1)
    if($found.Count -ne 1){throw 'CAT_PUBLICATION_ACTIVE_VARIANT_INVALID'}
    return $found[0]
}

function Resolve-YakuCatPublicationText {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Segment)
    $canonical=[string]$Segment.Translation;$canonicalHash=Get-YakuCatSourceIntegrityHash -Text $canonical
    $variant=Get-YakuCatActivePublicationVariant -Project $Project -SegmentId ([string]$Segment.SegmentId)
    if($null -eq $variant){return [pscustomobject]@{Text=$canonical;TextHash=$canonicalHash;VariantId='';VariantRevision=0;VariantHash='';IsVariant=$false}}
    if([string]$variant.canonical_target_hash -ne $canonicalHash){throw 'CAT_PUBLICATION_VARIANT_STALE'}
    $text=[string]$variant.text;$textHash=Get-YakuCatSourceIntegrityHash -Text $text
    if([string]$variant.text_hash -ne $textHash){throw 'CAT_PUBLICATION_VARIANT_INTEGRITY_INVALID'}
    if([string]$variant.source_facts_hash -ne (Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Text))){throw 'CAT_PUBLICATION_VARIANT_STALE'}
    if([string]$variant.variant_hash -ne (Get-YakuCatPublicationVariantHash -Variant $variant)){throw 'CAT_PUBLICATION_VARIANT_INTEGRITY_INVALID'}
    return [pscustomobject]@{Text=$text;TextHash=$textHash;VariantId=[string]$variant.variant_id;VariantRevision=[int]$variant.revision;VariantHash=[string]$variant.variant_hash;IsVariant=$true}
}

function Get-YakuCatPublicationCandidateDependencyFingerprint {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Segment,[Parameter(Mandatory=$true)][string]$PlacementBudgetHash)
    $context=Get-YakuCatPublicationCandidateContext -Project $Project -Segment $Segment
    return Get-YakuCatSourceIntegrityHash -Text ('publication-candidate-v2|'+[string]$Project.Id+'|'+[string]$Project.ActiveSourceId+'|'+[string]$Segment.SegmentId+'|'+[string]$Segment.SourceRevision+'|'+[string]$Segment.SourceIntegrityHash+'|'+(Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation))+'|'+[string]$Project.TerminologySnapshotHash+'|'+(Get-YakuCatAbbreviationRegistryHash -Project $Project)+'|'+[string]$context.FactsHash+'|'+$PlacementBudgetHash)
}

function Get-YakuCatPublicationCandidateContext {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Segment)
    $required=@($Segment.TerminologyUsages|Where-Object{-not [bool]$(try{$_.edited_after_insert}catch{$false})}|ForEach-Object{[ordered]@{term_id=[string]$_.term_id;version=[int]$_.term_version;source=[string]$_.source;target=[string]$_.preferred_target}})
    $protected=New-Object System.Collections.Generic.List[string]
    foreach($marker in @('ない','ません','禁止','必須','場合','ただし','除く','まで','以上','以下','予定','見込','方針','not','must','shall','unless','except','at least','at most')){if(([string]$Segment.Text).IndexOf($marker,[StringComparison]::OrdinalIgnoreCase)-ge 0){$protected.Add($marker)|Out-Null}}
    $segments=@($Project.Segments);$index=[array]::IndexOf($segments,$Segment);$before=$null;$after=$null
    if($index -gt 0){$before=[ordered]@{source=[string]$segments[$index-1].Text;translation=[string]$segments[$index-1].Translation}}
    if($index -ge 0 -and $index+1 -lt $segments.Count){$after=[ordered]@{source=[string]$segments[$index+1].Text;translation=[string]$segments[$index+1].Translation}}
    $value=[ordered]@{required_terms=$required;protected_facts=@($protected.ToArray());surrounding_context=[ordered]@{previous=$before;next=$after}}
    return [pscustomobject]@{Value=$value;FactsHash=(Get-YakuCatSourceIntegrityHash -Text ($value|ConvertTo-Json -Depth 8 -Compress))}
}

function New-YakuCatProtectedPublicationCandidateRequest {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][int]$Index,[Parameter(Mandatory=$true)]$PlacementBudget)
    $segments=@($Project.Segments);if($Index -lt 0 -or $Index -ge $segments.Count){throw 'CAT_PUBLICATION_SEGMENT_NOT_FOUND'}
    $segment=$segments[$Index];if([string]::IsNullOrWhiteSpace([string]$segment.Translation)){throw 'CAT_PUBLICATION_CANONICAL_REQUIRED'}
    $allowed=@($Project.AbbreviationEntries|Where-Object{[bool]$_.active -and [bool]$_.approved_by_human -and (([string]$_.allowed_scope -eq 'project' -and [string]$_.scope_id -eq [string]$Project.Id) -or ([string]$_.allowed_scope -eq 'document' -and [string]$_.scope_id -eq [string]$Project.ActiveSourceId))}|ForEach-Object{[ordered]@{entry_id=[string]$_.entry_id;version=[string]$_.version;abbreviation=[string]$_.abbreviation;full_form=[string]$_.full_form;meaning=[string]$_.meaning;first_use_rule=[string]$_.first_use_rule}})
    # 数値maskはJSONの文字列値だけに適用できるよう、sidecar内のbudget/versionも
    # 文字列として表す。裸のJSON numberを[[N1]]へ置換するとJSON自体が壊れる。
    $safeBudget=[ordered]@{};foreach($property in @($PlacementBudget.PSObject.Properties)){$safeBudget[[string]$property.Name]=[string]$property.Value}
    $context=Get-YakuCatPublicationCandidateContext -Project $Project -Segment $segment
    $payload=[ordered]@{segment_id=[string]$segment.SegmentId;source=[string]$segment.Text;canonical_translation=[string]$segment.Translation;allowed_abbreviations=$allowed;required_terms=@($context.Value.required_terms);protected_facts=@($context.Value.protected_facts);placement_budget=$safeBudget;surrounding_context=$context.Value.surrounding_context}
    $original=$payload|ConvertTo-Json -Depth 8 -Compress;$mask=New-YakuNumericMaskMap -Text $original -Root $Root -Direction ([string]$Project.Direction) -Location 'publication-candidate'
    $field=[pscustomobject]@{Name='publication_sidecar';OriginalText=$original;ProtectedText=[string]$mask.Text;NumericMaskMaps=@($mask.Map)}
    # max_chars はクライアントが現訳の長さから作る概算目標であり、実際のセル幅ではない。
    # 数字を含むsidecarは必ずマスクしたままにし、固定プロンプト用には安全な2桁だけを
    # 別引数で渡す。無効値は従来どおり目標を指示しない。
    [int]$promptTarget=0
    try{
        [int]$parsedTarget=0
        if([int]::TryParse([string]$PlacementBudget.max_chars,[ref]$parsedTarget) -and $parsedTarget -ge 8 -and $parsedTarget -le 99){$promptTarget=$parsedTarget}
    }catch{}
    $package=New-YakuProtectedPromptPackage -Kind compaction -Root $Root -Direction ([string]$Project.Direction) -Fields @($field) -Arguments ([pscustomobject]@{ContractVersion='compaction-candidate-v1';MaxChars=$promptTarget})
    $null=Assert-YakuNumericPromptProtected -Prompt ([string]$package.Prompt) -MaskMap $mask.Map
    $budgetHash=Get-YakuCatSourceIntegrityHash -Text ($PlacementBudget|ConvertTo-Json -Depth 6 -Compress)
    return [pscustomobject]@{Envelope=$package.Envelope;RequestId=[string]$package.RequestId;ContractVersion='compaction-candidate-v1';ProjectId=[string]$Project.Id;ProjectRevision=[int]$Project.Revision;SegmentId=[string]$segment.SegmentId;SegmentIndex=$Index;SourceHash=[string]$segment.SourceIntegrityHash;CanonicalHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Translation));SourceFactsHash=[string]$context.FactsHash;TerminologyHash=[string]$Project.TerminologySnapshotHash;AbbreviationRegistryHash=(Get-YakuCatAbbreviationRegistryHash -Project $Project);PlacementBudget=$PlacementBudget;PlacementBudgetHash=$budgetHash;DependencyFingerprint=(Get-YakuCatPublicationCandidateDependencyFingerprint -Project $Project -Segment $segment -PlacementBudgetHash $budgetHash);NumericMaskMap=$mask.Map;ProtectedSidecar=[string]$mask.Text;AllowedAbbreviations=$allowed}
}

function ConvertFrom-YakuPublicationCandidateResponse {
    param([Parameter(Mandatory=$true)][string]$Response,[Parameter(Mandatory=$true)]$Request)
    $normalized=$Response.Replace("`r`n","`n").Replace("`r","`n").Trim();$end='YAKULINGO_END:'+[string]$Request.RequestId;$hasEnd=$normalized.EndsWith($end,[StringComparison]::Ordinal)
    $prefix='COMPACTION_JSON:';$start=$normalized.IndexOf($prefix,[StringComparison]::Ordinal)
    if($start -ge 0){$json=$normalized.Substring($start+$prefix.Length,$normalized.Length-($start+$prefix.Length)-$(if($hasEnd){$end.Length}else{0})).Trim()}elseif($normalized.StartsWith('{')){$json=$(if($hasEnd){$normalized.Substring(0,$normalized.Length-$end.Length).Trim()}else{$normalized})}else{throw 'CAT_PUBLICATION_RESPONSE_CONTRACT_MISSING'}
    try{$payload=$json|ConvertFrom-Json}catch{throw 'CAT_PUBLICATION_RESPONSE_JSON_INVALID'}
    if([string]$payload.contract -ne [string]$Request.ContractVersion -or [string]$payload.request_id -ne [string]$Request.RequestId){throw 'CAT_PUBLICATION_RESPONSE_BINDING_MISMATCH'}
    # 申告の照合表は、素の entry_id だけでなく**送った形**でも引けるようにする。
    #
    # 2026-08-17 に実行して再現した。sidecar は丸ごと数値マスクを通るので、
    # entry_id（32桁の16進）は数字の並びごとに置き換わって出ていく。
    #
    #   登録 b5ed71b05d4646aab96ae1e447b1f7ce
    #   送信 b[[N10]]ed[[N11]]b[[N12]]d[[N13]]aab[[N14]]ae[[N15]]e[[N16]]b[[N17]]f[[N18]]ce
    #   version は [[N19]]
    #
    # モデルは見せられた形しか返せない。素の id で作った表と突き合わせると
    # 必ず外れ、CAT_PUBLICATION_RESPONSE_ABBREVIATION_NOT_ALLOWED が
    # **応答全体**に対して投げられる。つまり利用者が略語を登録し、モデルが
    # それを使ったと申告した瞬間に、候補生成が丸ごと落ちていた。
    #
    # 試験（Test-YakuV9170Publication）は素の entry_id で応答を組むので緑のまま
    # だった。試験が本番と違う入力を作っていた。
    #
    # 直し方は、照合表に「送った形」の鍵を足すだけにする。素の鍵は残すので、
    # 既存の呼び出しも試験もそのまま通る。対応づけは位置で取る。sidecar は
    # 同じ JSON の値だけを置換したものなので、allowed_abbreviations[i] は
    # 1対1で対応する。
    $allowed=@{};foreach($entry in @($Request.AllowedAbbreviations)){$allowed[[string]$entry.entry_id+':'+[string]$entry.version]=$entry}
    try{
        $sentAbbreviations=@((([string]$Request.ProtectedSidecar)|ConvertFrom-Json).allowed_abbreviations)
        $rawAbbreviations=@($Request.AllowedAbbreviations)
        if($sentAbbreviations.Count -eq $rawAbbreviations.Count){
            for($abbrIndex=0;$abbrIndex -lt $sentAbbreviations.Count;$abbrIndex++){
                $sentKey=[string]$sentAbbreviations[$abbrIndex].entry_id+':'+[string]$sentAbbreviations[$abbrIndex].version
                if(-not $allowed.ContainsKey($sentKey)){$allowed[$sentKey]=$rawAbbreviations[$abbrIndex]}
            }
        }
    }catch{}
    $candidates=New-Object System.Collections.Generic.List[object];$ordinal=0
    foreach($row in @($payload.candidates|Select-Object -First 5)){
        $protectedText=([string]$row.text).Trim();if([string]::IsNullOrWhiteSpace($protectedText)-or $protectedText.Length -gt 20000){throw 'CAT_PUBLICATION_RESPONSE_CANDIDATE_INVALID'}
        $fitEstimate=[string]$row.fit_estimate;if($fitEstimate -notin @('fits','likely','uncertain')){throw 'CAT_PUBLICATION_RESPONSE_FIT_INVALID'}
        $used=New-Object System.Collections.Generic.List[object]
        foreach($use in @($row.used_abbreviations)){
            $key=[string]$use.entry_id+':'+[string]$use.version
            if(-not $allowed.ContainsKey($key)){throw 'CAT_PUBLICATION_RESPONSE_ABBREVIATION_NOT_ALLOWED'}
            # 記録するのは登録簿の値であって、モデルの復唱ではない。
            # 復唱はマスク済みの形なので、[int] へ落とすと "[[N19]]" で壊れる。
            # 素の値は照合で引き当てた $allowed[$key] が持っている。
            $used.Add([pscustomobject]@{entry_id=[string]$allowed[$key].entry_id;version=[int]$allowed[$key].version;abbreviation=[string]$allowed[$key].abbreviation;full_form=[string]$allowed[$key].full_form;meaning=[string]$allowed[$key].meaning})|Out-Null
        }
        $text=Restore-YakuNumericMask -Text $protectedText -Map $Request.NumericMaskMap -Direction auto -SourceText ([string]$Request.ProtectedSidecar)
        foreach($use in @($used.ToArray())){
            if($text.IndexOf([string]$use.abbreviation,[StringComparison]::Ordinal) -lt 0){throw 'CAT_PUBLICATION_RESPONSE_ABBREVIATION_NOT_USED'}
        }
        $ordinal++;$textHash=Get-YakuCatSourceIntegrityHash -Text $text
        $candidates.Add([pscustomobject]@{candidate_id=(Get-YakuCatSourceIntegrityHash -Text ('publication-candidate-row-v1|'+[string]$Request.RequestId+'|'+$ordinal+'|'+$textHash)).Substring(0,32);text=$text;text_hash=$textHash;used_abbreviations=@($used.ToArray());transformations=@($row.transformations|ForEach-Object{[string]$_});claimed_preserved_facts=@($row.claimed_preserved_facts|ForEach-Object{[string]$_});fit_estimate=$fitEstimate;fit_verification_status='pending';warnings=@($row.warnings|ForEach-Object{[string]$_});deterministic_qc_status='pending';bilingual_review_status='human_review_required'})|Out-Null
    }
    if($candidates.Count -eq 0 -and [string]::IsNullOrWhiteSpace([string]$payload.cannot_fit_reason)){throw 'CAT_PUBLICATION_RESPONSE_EMPTY'}
    return [pscustomobject]@{CandidateSetId=[guid]::NewGuid().ToString('N');Candidates=@($candidates.ToArray());CannotFitReason=[string]$payload.cannot_fit_reason}
}

function Complete-YakuCatPublicationCandidateSet {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Request,[Parameter(Mandatory=$true)]$Parsed)
    $segment=@($Project.Segments|Where-Object{[string]$_.SegmentId -eq [string]$Request.SegmentId}|Select-Object -First 1);if($segment.Count -ne 1){throw 'CAT_PUBLICATION_SEGMENT_NOT_FOUND'}
    if((Get-YakuCatPublicationCandidateDependencyFingerprint -Project $Project -Segment $segment[0] -PlacementBudgetHash ([string]$Request.PlacementBudgetHash)) -ne [string]$Request.DependencyFingerprint){throw 'CAT_PUBLICATION_RESULT_STALE'}
    foreach($candidate in @($Parsed.Candidates)){
        $clone=[Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($segment[0],30));$clone.Translation=[string]$candidate.text
        $qc=Invoke-YakuCatSegmentValidation -Project $Project -Segment $clone
        $candidate.deterministic_qc_status=$(if([bool]$qc.Passed){'passed'}else{'failed'});$candidate|Add-Member -NotePropertyName qc_findings -NotePropertyValue @($qc.Findings) -Force
        $maxChars=[int]$(try{$Request.PlacementBudget.max_chars}catch{0});$candidate.fit_verification_status=$(if($maxChars -gt 0 -and ([string]$candidate.text).Length -gt $maxChars){'estimated_overflow'}else{'within_estimate'})
    }
    return [pscustomobject]@{candidate_set_id=[string]$Parsed.CandidateSetId;project_id=[string]$Project.Id;segment_id=[string]$Request.SegmentId;base_revision=[int]$Request.ProjectRevision;source_hash=[string]$Request.SourceHash;canonical_hash=[string]$Request.CanonicalHash;source_facts_hash=[string]$Request.SourceFactsHash;terminology_hash=[string]$Request.TerminologyHash;abbreviation_registry_hash=[string]$Request.AbbreviationRegistryHash;placement_budget=$Request.PlacementBudget;placement_budget_hash=[string]$Request.PlacementBudgetHash;dependency_fingerprint=[string]$Request.DependencyFingerprint;request_contract_version=[string]$Request.ContractVersion;candidates=@($Parsed.Candidates);cannot_fit_reason=[string]$Parsed.CannotFitReason}
}

function Invoke-YakuCatPublicationCandidateRequest {
    <# Copilotへ送るのはここだけ。数値maskを作るのが同じファイルの
       New-YakuCatProtectedPublicationCandidateRequest なので、送信も同じ
       ファイルに置く。ジョブのランスペースから直接Copilotを叩くと、
       「どこで伏せたか」をファイル単位の統制
       （tools/Test-YakuV9160NumericMasking.ps1 §10-21）で名指しできない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)]$PlacementBudget,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$StartedDependencyFingerprint,
        [Parameter(Mandatory=$true)][AllowNull()]$Settings,
        [AllowNull()]$Warnings,
        [AllowNull()]$ProgressState
    )
    $request=New-YakuCatProtectedPublicationCandidateRequest -Root $Root -Project $Project -Index $Index -PlacementBudget $PlacementBudget
    if([string]$request.DependencyFingerprint -ne $StartedDependencyFingerprint){throw 'CAT_PUBLICATION_DEPENDENCY_STALE'}
    Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label 'Excelに入れる候補を作っています' -Progress 35 -Detail '情報を削らずに短くできる案を確認しています。' -Phase 'publication_candidates'
    $raw=Invoke-YakuProtectedCopilotPrompt -Envelope $request.Envelope -Settings $Settings -AnswerFormat labeled -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
    $parsed=ConvertFrom-YakuPublicationCandidateResponse -Response $raw -Request $request
    $candidateSet=Complete-YakuCatPublicationCandidateSet -Project $Project -Request $request -Parsed $parsed
    return [pscustomobject]@{CandidateSet=$candidateSet;SegmentId=[string]$request.SegmentId;PlacementBudgetHash=[string]$request.PlacementBudgetHash;DependencyFingerprint=[string]$request.DependencyFingerprint}
}

function Apply-YakuCatPublicationCandidate {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$CandidateSet,[Parameter(Mandatory=$true)][string]$CandidateSetId,[Parameter(Mandatory=$true)][string]$CandidateId,[Parameter(Mandatory=$true)][string]$CandidateTextHash,[Parameter(Mandatory=$true)][bool]$MeaningPreservationConfirmed,[Parameter(Mandatory=$true)][string]$Reason)
    if(-not $MeaningPreservationConfirmed){throw 'CAT_PUBLICATION_MEANING_CONFIRMATION_REQUIRED'}
    if([string]$CandidateSet.candidate_set_id -ne $CandidateSetId){throw 'CAT_PUBLICATION_CANDIDATE_SET_MISMATCH'}
    $segment=@($Project.Segments|Where-Object{[string]$_.SegmentId -eq [string]$CandidateSet.segment_id}|Select-Object -First 1);if($segment.Count -ne 1){throw 'CAT_PUBLICATION_SEGMENT_NOT_FOUND'}
    $currentCanonicalHash=Get-YakuCatSourceIntegrityHash -Text ([string]$segment[0].Translation)
    $currentRegistryHash=Get-YakuCatAbbreviationRegistryHash -Project $Project
    $currentSourceFactsHash=[string](Get-YakuCatPublicationCandidateContext -Project $Project -Segment $segment[0]).FactsHash
    $currentDependency=Get-YakuCatPublicationCandidateDependencyFingerprint -Project $Project -Segment $segment[0] -PlacementBudgetHash ([string]$CandidateSet.placement_budget_hash)
    if([string]$CandidateSet.source_hash -ne [string]$segment[0].SourceIntegrityHash -or
       [string]$CandidateSet.source_facts_hash -ne $currentSourceFactsHash -or
       [string]$CandidateSet.canonical_hash -ne $currentCanonicalHash -or
       [string]$CandidateSet.terminology_hash -ne [string]$Project.TerminologySnapshotHash -or
       [string]$CandidateSet.abbreviation_registry_hash -ne $currentRegistryHash -or
       [string]$CandidateSet.dependency_fingerprint -ne $currentDependency){throw 'CAT_PUBLICATION_CANDIDATE_STALE'}
    $candidate=@($CandidateSet.candidates|Where-Object{[string]$_.candidate_id -eq $CandidateId}|Select-Object -First 1);if($candidate.Count -ne 1){throw 'CAT_PUBLICATION_CANDIDATE_NOT_FOUND'}
    if([string]$candidate[0].text_hash -ne $CandidateTextHash -or (Get-YakuCatSourceIntegrityHash -Text ([string]$candidate[0].text)) -ne $CandidateTextHash){throw 'CAT_PUBLICATION_CANDIDATE_HASH_MISMATCH'}
    if([string]$candidate[0].deterministic_qc_status -ne 'passed'){throw 'CAT_PUBLICATION_CANDIDATE_QC_REQUIRED'}
    if([string]$candidate[0].fit_verification_status -eq 'estimated_overflow'){throw 'CAT_PUBLICATION_CANDIDATE_OVERFLOW'}
    $reasonText=([string]$Reason).Trim();if([string]::IsNullOrWhiteSpace($reasonText)){throw 'CAT_PUBLICATION_REVIEW_REASON_REQUIRED'}
    $text=[string]$candidate[0].text;$canonical=[string]$segment[0].Translation
    if($text -ceq $canonical){return Revert-YakuCatPublicationVariant -Project $Project -SegmentId ([string]$segment[0].SegmentId) -Reason $reasonText}
    foreach($old in @($Project.PublicationVariants|Where-Object{[string]$_.segment_id -eq [string]$segment[0].SegmentId -and [string]$_.status -eq 'active'})){$old.status='superseded'}
    $variantId=[guid]::NewGuid().ToString('N');$revision=1;$textHash=Get-YakuCatSourceIntegrityHash -Text $text
    $uses=New-Object System.Collections.Generic.List[object];$useIds=New-Object System.Collections.Generic.List[string]
    foreach($used in @($candidate[0].used_abbreviations)){$useId=[guid]::NewGuid().ToString('N');$useIds.Add($useId)|Out-Null;$uses.Add([pscustomobject]@{use_id=$useId;variant_id=$variantId;surface=[string]$used.abbreviation;expanded_form=[string]$used.full_form;meaning=[string]$used.meaning;entry_id=[string]$used.entry_id;entry_version=[int]$used.version;approval='registered';decision_event_id='';dependency_fingerprint=[string]$CandidateSet.dependency_fingerprint})|Out-Null}
    $variant=[pscustomobject]@{variant_id=$variantId;segment_id=[string]$segment[0].SegmentId;revision=$revision;canonical_target_hash=(Get-YakuCatSourceIntegrityHash -Text $canonical);text=$text;text_hash=$textHash;change_kind=$(if(@($candidate[0].used_abbreviations).Count){'mixed'}else{'concise'});abbreviation_use_ids=@($useIds.ToArray());generation_origin='copilot_candidate';semantic_review_status='human_approved';source_facts_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$segment[0].Text));candidate_context_hash=[string]$CandidateSet.source_facts_hash;status='active';created_at=(Get-Date).ToString('o');variant_hash=''}
    $variant.variant_hash=Get-YakuCatPublicationVariantHash -Variant $variant
    $Project.PublicationVariants=@($Project.PublicationVariants)+@($variant);$Project.ActivePublicationVariantBySegment|Add-Member -NotePropertyName ([string]$segment[0].SegmentId) -NotePropertyValue $variantId -Force
    foreach($plan in @($Project.PlacementPlans|Where-Object{[string]$_.segment_id -eq [string]$segment[0].SegmentId})){$plan.status='stale';$plan.plan_hash=$(if(Get-Command Get-YakuCatPlacementPlanHash -ErrorAction SilentlyContinue){Get-YakuCatPlacementPlanHash -Plan $plan}else{Get-YakuCatSourceIntegrityHash -Text (($plan|Select-Object * -ExcludeProperty plan_hash)|ConvertTo-Json -Depth 12 -Compress)})}
    foreach($finding in @($Project.DocumentFindings|Where-Object{[string]$_.status -ne 'stale'})){$finding.status='stale'}
    $event=Add-YakuCatHumanDecisionEvent -Project $Project -Scope publication -Action candidate_applied -Segment $segment[0] -ReasonCode $reasonText -DependencyFingerprint ([string]$variant.variant_hash)
    $variant|Add-Member -NotePropertyName approval_event_id -NotePropertyValue $event -Force
    foreach($use in @($uses.ToArray())){$use.decision_event_id=$event};$Project.AbbreviationUses=@($Project.AbbreviationUses)+@($uses.ToArray())
    $null=Sync-YakuCatPlacementPlans -Project $Project
    return $variant
}

function Revert-YakuCatPublicationVariant {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$SegmentId,[Parameter(Mandatory=$true)][string]$Reason)
    $segment=@($Project.Segments|Where-Object{[string]$_.SegmentId -eq $SegmentId}|Select-Object -First 1);if($segment.Count -ne 1){throw 'CAT_PUBLICATION_SEGMENT_NOT_FOUND'}
    $variant=Get-YakuCatActivePublicationVariant -Project $Project -SegmentId $SegmentId;if($null -eq $variant){return $null};$variant.status='superseded';$Project.ActivePublicationVariantBySegment.PSObject.Properties.Remove($SegmentId)
    foreach($plan in @($Project.PlacementPlans|Where-Object{[string]$_.segment_id -eq $SegmentId})){$plan.status='stale';$plan.plan_hash=Get-YakuCatSourceIntegrityHash -Text (($plan|Select-Object * -ExcludeProperty plan_hash)|ConvertTo-Json -Depth 12 -Compress)}
    foreach($finding in @($Project.DocumentFindings|Where-Object{[string]$_.status -ne 'stale'})){$finding.status='stale'}
    $null=Add-YakuCatHumanDecisionEvent -Project $Project -Scope publication -Action variant_reverted -Segment $segment[0] -ReasonCode $Reason -DependencyFingerprint ([string]$variant.variant_hash);$null=Sync-YakuCatPlacementPlans -Project $Project
    return $variant
}
