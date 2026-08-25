<#
  行ローカルQCとは別に、複数行・文書全体の確認事項を扱う。
  Copilotを使わない決定論的runも、後続のAI runも同じFinding/Coverage契約へ投影する。
#>

function Get-YakuCatDocumentReviewDependencyFingerprint {
    param([Parameter(Mandatory=$true)]$Project)
    $segmentParts = @($Project.Segments | ForEach-Object {
        $publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $_}else{[pscustomobject]@{Text=[string]$_.Translation}})
        [string]$_.SegmentId + ':' + [string]$_.SourceIntegrityHash + ':' + (Get-YakuCatSourceIntegrityHash -Text ([string]$publication.Text))
    })
    return Get-YakuCatSourceIntegrityHash -Text ('document-review-v1|' + [string]$Project.ActiveSourceId + '|' + [string]$Project.SourceArtifactSha256 + '|' + [string]$Project.TerminologySnapshotHash + '|' + ($segmentParts -join '|'))
}

function Get-YakuCatDocumentIndexSnapshotHash {
    param([Parameter(Mandatory=$true)]$Snapshot)
    $payload=[ordered]@{
        contract_version=[string]$Snapshot.contract_version
        dependency_fingerprint=[string]$Snapshot.dependency_fingerprint
        occurrences=@($Snapshot.occurrences)
        groups=@($Snapshot.groups)
    }
    return Get-YakuCatSourceIntegrityHash -Text ($payload|ConvertTo-Json -Depth 8 -Compress)
}

function Assert-YakuCatDocumentIndexSnapshot {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Snapshot)
    if([string]$Snapshot.contract_version -ne 'document-index-v1' -or [string]$Snapshot.dependency_fingerprint -ne (Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project)){throw 'CAT_REVIEW_DOCUMENT_INDEX_STALE'}
    if([string]$Snapshot.snapshot_hash -ne (Get-YakuCatDocumentIndexSnapshotHash -Snapshot $Snapshot)){throw 'CAT_REVIEW_DOCUMENT_INDEX_INTEGRITY_FAILED'}
    $segmentIds=@($Project.Segments|ForEach-Object{[string]$_.SegmentId})
    $occurrenceIds=@($Snapshot.occurrences|ForEach-Object{[string]$_.segment_id})
    if(($occurrenceIds -join '|') -cne ($segmentIds -join '|')){throw 'CAT_REVIEW_DOCUMENT_INDEX_TARGET_MISMATCH'}
    foreach($group in @($Snapshot.groups)){if([string]::IsNullOrWhiteSpace([string]$group.group_id) -or [string]$group.lens -notin @('translation_consistency','target_document_consistency') -or @($group.segment_ids|Where-Object{$segmentIds -notcontains [string]$_}).Count -gt 0){throw 'CAT_REVIEW_DOCUMENT_INDEX_TARGET_MISMATCH'}}
    return $true
}

function New-YakuCatDocumentIndexSnapshot {
    <# 全文を一度の外部送信へ載せず、文書横断で比較すべき組をローカルで列挙する。
       同一原文は1 group、訳文単独整合性は先頭anchorを共有する最大20件のgroupにする。
       groupに入らなかったsegmentをcoverage済みとは扱わない。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    $segments=@($Project.Segments);$occurrences=New-Object System.Collections.Generic.List[object]
    $bySource=@{};$bySourceTerm=@{}
    for($i=0;$i -lt $segments.Count;$i++){
        $segment=$segments[$i];$publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $segment}else{[pscustomobject]@{Text=[string]$segment.Translation}})
        $sourceKey=ConvertTo-YakuRebaseComparableText -Text ([string]$segment.Text)
        $occurrences.Add([pscustomobject]@{occurrence_id=(Get-YakuCatSourceIntegrityHash -Text ('doc-occurrence-v1|'+[string]$segment.SegmentId+'|'+$dependency));segment_id=[string]$segment.SegmentId;segment_index=$i;source_hash=[string]$segment.SourceIntegrityHash;target_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$publication.Text))})|Out-Null
        if(-not [string]::IsNullOrWhiteSpace($sourceKey)){if(-not $bySource.ContainsKey($sourceKey)){$bySource[$sourceKey]=New-Object System.Collections.Generic.List[int]};$bySource[$sourceKey].Add($i)|Out-Null}
        $terms=@([regex]::Matches(([string]$segment.Text).Normalize([Text.NormalizationForm]::FormKC),'[一-龠々〆ヵヶ]{2,12}|[ァ-ヴー]{2,}|[A-Za-z][A-Za-z0-9&./-]{1,}')|ForEach-Object{$_.Value.ToLowerInvariant()}|Where-Object{$_ -notin @('これら','それぞれ','について','および','または','the','and','for','with','from')}|Select-Object -Unique)
        foreach($term in $terms){if(-not $bySourceTerm.ContainsKey($term)){$bySourceTerm[$term]=New-Object System.Collections.Generic.List[int]};$bySourceTerm[$term].Add($i)|Out-Null}
    }
    $groups=New-Object System.Collections.Generic.List[object]
    foreach($entry in @($bySource.GetEnumerator()|Sort-Object Name)){
        $indices=@($entry.Value.ToArray());if($indices.Count -lt 2){continue}
        $groups.Add([pscustomobject]@{group_id=(Get-YakuCatSourceIntegrityHash -Text ('doc-group-v1|translation_consistency|'+($indices -join ',')+'|'+$dependency));lens='translation_consistency';kind='repeated_source';segment_indices=$indices;segment_ids=@($indices|ForEach-Object{[string]$segments[$_].SegmentId})})|Out-Null
    }
    foreach($entry in @($bySourceTerm.GetEnumerator()|Sort-Object Name)){
        $all=@($entry.Value.ToArray()|Select-Object -Unique);if($all.Count -lt 2){continue}
        $cursor=0;while($cursor -lt $all.Count){$last=[Math]::Min($all.Count-1,$cursor+19);$indices=@($all[$cursor..$last]);if($cursor -gt 0 -and $indices[0] -ne $all[0]){$indices=@($all[0])+@($indices|Select-Object -First 19)};$groups.Add([pscustomobject]@{group_id=(Get-YakuCatSourceIntegrityHash -Text ('doc-group-v1|translation_consistency|source_term|'+[string]$entry.Name+'|'+($indices -join ',')+'|'+$dependency));lens='translation_consistency';kind='source_term_occurrences';term_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$entry.Name));segment_indices=@($indices);segment_ids=@($indices|ForEach-Object{[string]$segments[$_].SegmentId});automated=$true})|Out-Null;$cursor=$last+1}
    }
    # 英語文書単独の整合性は全segmentを索引母集団に含める。20件を超える場合は
    # 先頭anchorを各groupへ入れ、request間で文体・定義の基準を共有する。
    if($segments.Count -gt 0){
        if($segments.Count -le 20){$windows=@((0..($segments.Count-1)))}else{$windows=@();$cursor=1;while($cursor -lt $segments.Count){$last=[Math]::Min($segments.Count-1,$cursor+18);$window=@(0)+@($cursor..$last);$windows+=,@($window);$cursor=$last+1}}
        foreach($indices in $windows){$groups.Add([pscustomobject]@{group_id=(Get-YakuCatSourceIntegrityHash -Text ('doc-group-v1|target_document_consistency|'+($indices -join ',')+'|'+$dependency));lens='target_document_consistency';kind='anchored_document_window';segment_indices=@($indices);segment_ids=@($indices|ForEach-Object{[string]$segments[$_].SegmentId});automated=$true})|Out-Null}
        if($segments.Count -gt 20){$allIndices=@(0..($segments.Count-1));$groups.Add([pscustomobject]@{group_id=(Get-YakuCatSourceIntegrityHash -Text ('doc-group-v1|target_document_consistency|cross-group-human|'+$dependency));lens='target_document_consistency';kind='whole_document_cross_group';segment_indices=$allIndices;segment_ids=@($segments|ForEach-Object{[string]$_.SegmentId});automated=$false})|Out-Null}
    }
    $snapshot=[pscustomobject]@{snapshot_id='';contract_version='document-index-v1';dependency_fingerprint=$dependency;created_at=(Get-Date).ToString('o');occurrences=@($occurrences.ToArray());groups=@($groups.ToArray());snapshot_hash=''}
    $hash=Get-YakuCatDocumentIndexSnapshotHash -Snapshot $snapshot;$snapshot.snapshot_id=$hash;$snapshot.snapshot_hash=$hash
    return $snapshot
}

function ConvertTo-YakuReviewAlias {
    param([Parameter(Mandatory=$true)][int]$Index)
    $value=$Index+1;$letters=''
    while($value -gt 0){$value--; $letters=[char](65+($value%26))+$letters; $value=[Math]::Floor($value/26)}
    return ('SEG-'+$letters)
}

function New-YakuCatProtectedDocumentReviewRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [int]$StartIndex=0,
        [int]$Count=40,
        [int[]]$SegmentIndices=@(),
        [ValidateSet('local','document_index')][string]$ReviewPurpose='local',
        [string]$IndexLens='',
        [string]$IndexGroupId=''
    )
    if($StartIndex -lt 0 -or $Count -lt 1){throw 'CAT_REVIEW_RANGE_INVALID'}
    $segments=@($Project.Segments);$end=[Math]::Min($segments.Count,$StartIndex+$Count)
    $records=New-Object System.Collections.Generic.List[object];$aliases=@{}
    $selected=$(if(@($SegmentIndices).Count){@($SegmentIndices|Select-Object -Unique)}else{@($StartIndex..([Math]::Max($StartIndex,$end-1)))})
    foreach($i in $selected){
        if($i -lt 0 -or $i -ge $segments.Count){throw 'CAT_REVIEW_RANGE_INVALID'}
        $alias=ConvertTo-YakuReviewAlias -Index $i;$segment=$segments[$i];$aliases[$alias]=[string]$segment.SegmentId
        $publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $segment}else{[pscustomobject]@{Text=[string]$segment.Translation}})
        $records.Add([ordered]@{segment_alias=$alias;source=[string]$segment.Text;target=[string]$publication.Text})|Out-Null
    }
    $original=@($records.ToArray())|ConvertTo-Json -Depth 4 -Compress
    # Windows PowerShell 5.1 escapes these characters as \uXXXX. Decode them
    # before numeric masking so the hexadecimal digits cannot become tokens.
    $original=$original.Replace('\u0027',"'").Replace('\u0026','&').Replace('\u003c','<').Replace('\u003C','<').Replace('\u003e','>').Replace('\u003E','>')
    if([string]::IsNullOrWhiteSpace($original)){throw 'CAT_REVIEW_TEXT_EMPTY'}
    $mask=New-YakuNumericMaskMap -Text $original -Root $Root -Direction ([string]$Project.Direction) -Location 'document-review'
    $field=[pscustomobject]@{Name='review_sidecar';OriginalText=$original;ProtectedText=[string]$mask.Text;NumericMaskMaps=@($mask.Map)}
    $package=New-YakuProtectedPromptPackage -Kind review -Root $Root -Direction ([string]$Project.Direction) -Fields @($field) -Arguments ([pscustomobject]@{ReviewContractVersion='document-review-copilot-v2'})
    $null=Assert-YakuNumericPromptProtected -Prompt ([string]$package.Prompt) -MaskMap $mask.Map
    [object[]]$protectedRecords=([string]$mask.Text|ConvertFrom-Json)
    return [pscustomobject]@{
        Envelope=$package.Envelope;RequestId=[string]$package.RequestId;PromptSha256=[string]$package.Envelope.PromptSha256
        AliasToSegmentId=$aliases;ProtectedSidecar=[string]$mask.Text;ProtectedRecords=$protectedRecords;NumericMaskMap=$mask.Map;ContractVersion='document-review-copilot-v2'
        DependencyFingerprint=(Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project);ProjectRevision=[int]$Project.Revision
        ReviewPurpose=$ReviewPurpose;IndexLens=$IndexLens;IndexGroupId=$IndexGroupId
    }
}

function ConvertFrom-YakuDocumentReviewResponse {
    param(
        [Parameter(Mandatory=$true)][string]$Response,
        [Parameter(Mandatory=$true)]$Request
    )
    $normalized=$Response.Replace("`r`n","`n").Replace("`r","`n").Trim()
    $end='YAKULINGO_END:'+ [string]$Request.RequestId
    $hasEndMarker=$normalized.EndsWith($end,[StringComparison]::Ordinal)
    $prefix='REVIEW_JSON:';$start=$normalized.IndexOf($prefix,[StringComparison]::Ordinal)
    if($start -ge 0){
        $jsonLength=$normalized.Length-($start+$prefix.Length)-$(if($hasEndMarker){$end.Length}else{0})
        $json=$normalized.Substring($start+$prefix.Length,$jsonLength).Trim()
    }elseif($normalized.StartsWith('{',[StringComparison]::Ordinal)){
        # The response watcher extracts a request-bound review JSON object from
        # REVIEW_JSON before returning it.  Accept that canonical projection as
        # well as the raw labeled response; request_id is validated below.
        $json=$(if($hasEndMarker){$normalized.Substring(0,$normalized.Length-$end.Length).Trim()}else{$normalized})
    }else{throw 'CAT_REVIEW_RESPONSE_CONTRACT_MISSING'}
    if($json.StartsWith('```')){$json=[regex]::Replace($json,'^```(?:json)?\s*|\s*```$','',[Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()}
    try{$payload=$json|ConvertFrom-Json}catch{throw 'CAT_REVIEW_RESPONSE_JSON_INVALID'}
    if([string]$payload.contract -ne [string]$Request.ContractVersion){throw 'CAT_REVIEW_RESPONSE_CONTRACT_MISMATCH'}
    if([string]$payload.request_id -ne [string]$Request.RequestId){throw 'CAT_REVIEW_RESPONSE_REQUEST_ID_MISMATCH'}
    $allowedCategories=@('bilingual_block','names_terms_abbreviations','translation_consistency','target_document_consistency','structure_notes','gap')
    $allowedSeverities=@('info','warning','error')
    $protectedByAlias=@{};foreach($record in @($Request.ProtectedRecords)){$protectedByAlias[[string]$record.segment_alias]=$record}
    $normalizedFindings=New-Object System.Collections.Generic.List[object]
    foreach($finding in @($payload.findings)){
        if($allowedCategories -notcontains [string]$finding.category -or $allowedSeverities -notcontains [string]$finding.severity -or [string]$finding.evidence_quality -ne 'clear' -or [double]$finding.evidence_confidence -lt 0.75 -or [double]$finding.evidence_confidence -gt 1.0){throw 'CAT_REVIEW_RESPONSE_FINDING_INVALID'}
        $evidenceRows=New-Object System.Collections.Generic.List[object]
        foreach($evidence in @($finding.evidence)){
            $alias=[string]$evidence.segment_alias;if(-not $protectedByAlias.ContainsKey($alias)){throw 'CAT_REVIEW_RESPONSE_EVIDENCE_ALIAS_INVALID'}
            $record=$protectedByAlias[$alias];$sourceQuote=[string]$evidence.source_quote;$targetQuote=[string]$evidence.target_quote
            if([string]::IsNullOrWhiteSpace($sourceQuote) -or [string]::IsNullOrWhiteSpace($targetQuote) -or ([string]$record.source).IndexOf($sourceQuote,[StringComparison]::Ordinal) -lt 0 -or ([string]$record.target).IndexOf($targetQuote,[StringComparison]::Ordinal) -lt 0){throw 'CAT_REVIEW_RESPONSE_EVIDENCE_QUOTE_INVALID'}
            $evidenceRows.Add([pscustomobject]@{segment_alias=$alias;source_quote=$sourceQuote;target_quote=$targetQuote})|Out-Null
        }
        if($evidenceRows.Count -eq 0 -or ([string]$finding.category -in @('translation_consistency','target_document_consistency') -and $evidenceRows.Count -lt 2)){throw 'CAT_REVIEW_RESPONSE_EVIDENCE_INSUFFICIENT'}
        $normalizedFindings.Add([pscustomobject]@{category=[string]$finding.category;severity=[string]$finding.severity;title=[string]$finding.title;message=[string]$finding.message;evidence_quality='clear';evidence_confidence=[double]$finding.evidence_confidence;evidence=@($evidenceRows.ToArray());suggestions=@($finding.suggestions|ForEach-Object{[string]$_})})|Out-Null
    }
    $lensCoverage=New-Object System.Collections.Generic.List[object]
    foreach($lens in $allowedCategories){
        $rows=@($payload.lens_coverage|Where-Object{[string]$_.lens -eq $lens})
        if($rows.Count -ne 1){throw 'CAT_REVIEW_RESPONSE_LENS_COVERAGE_INVALID'}
        $checked=@($rows[0].checked_segment_aliases|ForEach-Object{[string]$_}|Select-Object -Unique)
        foreach($alias in $checked){if(-not $protectedByAlias.ContainsKey($alias)){throw 'CAT_REVIEW_RESPONSE_COVERAGE_ALIAS_INVALID'}}
        $lensCoverage.Add([pscustomobject]@{lens=$lens;checked_aliases=$checked})|Out-Null
    }
    if(@($payload.lens_coverage).Count -ne $allowedCategories.Count){throw 'CAT_REVIEW_RESPONSE_LENS_COVERAGE_INVALID'}
    return [pscustomobject]@{ContractVersion=[string]$payload.contract;Findings=@($normalizedFindings.ToArray());LensCoverage=@($lensCoverage.ToArray())}
}

function ConvertFrom-YakuReviewMaskedText {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)]$Request
    )
    if([bool]$(try{$Request.Sanitized}catch{$false})){return [string]$Text}
    return Restore-YakuNumericMask -Text ([string]$Text) -Map $Request.NumericMaskMap -Direction auto -SourceText ([string]$Request.ProtectedSidecar)
}

function ConvertTo-YakuSanitizedDocumentReviewPacket {
    <# job完了後にplaceholder辞書・masked sidecar・raw応答を残さない。
       復号済みの構造化結果だけへ投影し、apply時に現projectへ再検証する。 #>
    param([Parameter(Mandatory=$true)]$Request,[Parameter(Mandatory=$true)]$ParsedResult)
    $findings=@($ParsedResult.Findings|ForEach-Object{
        $row=$_
        [pscustomobject]@{category=[string]$row.category;severity=[string]$row.severity;title=(ConvertFrom-YakuReviewMaskedText -Text ([string]$row.title) -Request $Request);message=(ConvertFrom-YakuReviewMaskedText -Text ([string]$row.message) -Request $Request);evidence_quality=[string]$row.evidence_quality;evidence_confidence=[double]$row.evidence_confidence;evidence=@($row.evidence|ForEach-Object{[pscustomobject]@{segment_alias=[string]$_.segment_alias;source_quote=(ConvertFrom-YakuReviewMaskedText -Text ([string]$_.source_quote) -Request $Request);target_quote=(ConvertFrom-YakuReviewMaskedText -Text ([string]$_.target_quote) -Request $Request)}});suggestions=@($row.suggestions|ForEach-Object{ConvertFrom-YakuReviewMaskedText -Text ([string]$_) -Request $Request})}
    })
    return [pscustomobject]@{request_id=[string]$Request.RequestId;alias_to_segment_id=$Request.AliasToSegmentId;contract_version=[string]$Request.ContractVersion;dependency_fingerprint=[string]$Request.DependencyFingerprint;project_revision=[int]$Request.ProjectRevision;review_purpose=[string]$Request.ReviewPurpose;index_lens=[string]$Request.IndexLens;index_group_id=[string]$Request.IndexGroupId;sanitized=$true;parsed_result=[pscustomobject]@{ContractVersion=[string]$ParsedResult.ContractVersion;Findings=$findings;LensCoverage=@($ParsedResult.LensCoverage)}}
}

function Invoke-YakuCatDocumentReviewRequests {
    <# Copilotへ送るのはここだけ。数値maskを作るのが同じファイルの
       New-YakuCatProtectedDocumentReviewRequest なので、送信も同じファイルに
       置く。ジョブのランスペースから直接Copilotを叩くと、「どこで伏せたか」を
       ファイル単位の統制（tools/Test-YakuV9160NumericMasking.ps1 §10-21）で
       名指しできない。返すのはsanitized packetだけで、placeholder辞書と
       masked sidecarはこの関数の外へ出さない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$DocumentIndex,
        [Parameter(Mandatory=$true)][AllowNull()]$Settings,
        [AllowNull()]$Warnings,
        [AllowNull()]$ProgressState
    )
    $packets=New-Object System.Collections.Generic.List[object];$skipped=New-Object System.Collections.Generic.List[string]
    $batchSize=20;$segmentCount=@($Project.Segments).Count;$requestNumber=0;$start=0;$promptLimit=0
    try{$promptLimit=[int]$Settings.copilotPromptCharLimit}catch{}
    while($start -lt $segmentCount){
        $count=[Math]::Min($batchSize,$segmentCount-$start);$request=$null
        while($count -ge 1){
            try{$candidateRequest=New-YakuCatProtectedDocumentReviewRequest -Root $Root -Project $Project -StartIndex $start -Count $count}
            catch{if([string]$_.Exception.Message -eq 'CAT_REVIEW_TEXT_EMPTY'){$skipped.Add([string]@($Project.Segments)[$start].SegmentId)|Out-Null;$start++;$count=0;break};throw}
            if($promptLimit -le 0 -or ([string]$candidateRequest.Envelope.Prompt).Length -le $promptLimit){$request=$candidateRequest;break}
            if($count -eq 1){$skipped.Add([string]@($Project.Segments)[$start].SegmentId)|Out-Null;$start++;$count=0;break}
            $count=[Math]::Max(1,[Math]::Floor($count/2))
        }
        if($null -eq $request){continue}
        $requestNumber++
        $progress=[Math]::Min(90,10+[int](80*$start/[Math]::Max(1,$segmentCount)))
        Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '文書全体を確認しています' -Progress $progress -Detail ("確認範囲 {0}～{1} / {2}" -f ($start+1),($start+$count),$segmentCount) -Phase 'document_review'
        $raw=Invoke-YakuProtectedCopilotPrompt -Envelope $request.Envelope -Settings $Settings -SkipFreshChatWait:($requestNumber -gt 1) -AnswerFormat labeled -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
        $parsed=ConvertFrom-YakuDocumentReviewResponse -Response $raw -Request $request
        $packets.Add((ConvertTo-YakuSanitizedDocumentReviewPacket -Request $request -ParsedResult $parsed))|Out-Null
        $start+=$count
    }
    foreach($group in @($DocumentIndex.groups)){
        if($group.PSObject.Properties.Name -contains 'automated' -and -not [bool]$group.automated){continue}
        $request=$null
        try{$request=New-YakuCatProtectedDocumentReviewRequest -Root $Root -Project $Project -SegmentIndices @($group.segment_indices) -ReviewPurpose document_index -IndexLens ([string]$group.lens) -IndexGroupId ([string]$group.group_id)}catch{continue}
        if($promptLimit -gt 0 -and ([string]$request.Envelope.Prompt).Length -gt $promptLimit){continue}
        $requestNumber++;Set-YakuTranslationProgress -ProgressState $ProgressState -Mode 'working' -Label '文書全体を確認しています' -Progress 92 -Detail '文書内の一貫性を索引単位で比較しています' -Phase 'document_review_index'
        $raw=Invoke-YakuProtectedCopilotPrompt -Envelope $request.Envelope -Settings $Settings -SkipFreshChatWait:($requestNumber -gt 1) -AnswerFormat labeled -PreserveEndMarker -Warnings $Warnings -ProgressState $ProgressState
        $parsed=ConvertFrom-YakuDocumentReviewResponse -Response $raw -Request $request
        $packets.Add((ConvertTo-YakuSanitizedDocumentReviewPacket -Request $request -ParsedResult $parsed))|Out-Null
    }
    return [pscustomobject]@{Packets=@($packets.ToArray());SkippedSegmentIds=@($skipped.ToArray())}
}

function Apply-YakuCatCopilotDocumentReviewResult {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Request,
        [Parameter(Mandatory=$true)]$ParsedResult
    )
    $null=Initialize-YakuCatProjectState -Project $Project
    $null=Sync-YakuCatPlacementPlans -Project $Project
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    if([string]$Request.DependencyFingerprint -ne $dependency){throw 'CAT_REVIEW_RESULT_STALE'}
    $segmentsById=@{};foreach($segment in @($Project.Segments)){$segmentsById[[string]$segment.SegmentId]=$segment}
    $runId=[guid]::NewGuid().ToString('N')
    $findings=New-Object System.Collections.Generic.List[object]
    $findingIdsByAlias=@{}
    foreach($candidate in @($ParsedResult.Findings)){
        $locations=New-Object System.Collections.Generic.List[object]
        foreach($evidence in @($candidate.evidence)){
            $alias=[string]$evidence.segment_alias
            if(-not $Request.AliasToSegmentId.ContainsKey($alias)){throw 'CAT_REVIEW_RESULT_ALIAS_INVALID'}
            $segmentId=[string]$Request.AliasToSegmentId[$alias]
            if(-not $segmentsById.ContainsKey($segmentId)){throw 'CAT_REVIEW_RESULT_SEGMENT_MISSING'}
            $segment=$segmentsById[$segmentId]
            $sourceQuote=ConvertFrom-YakuReviewMaskedText -Text ([string]$evidence.source_quote) -Request $Request
            $targetQuote=ConvertFrom-YakuReviewMaskedText -Text ([string]$evidence.target_quote) -Request $Request
            $publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $segment}else{[pscustomobject]@{Text=[string]$segment.Translation}})
            if(([string]$segment.Text).IndexOf($sourceQuote,[StringComparison]::Ordinal) -lt 0 -or ([string]$publication.Text).IndexOf($targetQuote,[StringComparison]::Ordinal) -lt 0){throw 'CAT_REVIEW_RESULT_QUOTE_STALE'}
            $sourceLocation=New-YakuCatReviewEvidenceLocation -Project $Project -Segment $segment -Side source
            $sourceLocation.quote=$sourceQuote;$locations.Add($sourceLocation)|Out-Null
            $targetLocation=New-YakuCatReviewEvidenceLocation -Project $Project -Segment $segment -Side target
            $targetLocation.quote=$targetQuote;$locations.Add($targetLocation)|Out-Null
        }
        $scope=$(if(@($candidate.evidence).Count -gt 1 -or [string]$candidate.category -in @('translation_consistency','target_document_consistency')){'document'}else{'local'})
        $finding=New-YakuCatDocumentFinding -Scope $scope -Category ([string]$candidate.category) -Detector copilot -DetectorContractVersion ([string]$Request.ContractVersion) -Severity ([string]$candidate.severity) -Title (ConvertFrom-YakuReviewMaskedText -Text ([string]$candidate.title) -Request $Request) -Message (ConvertFrom-YakuReviewMaskedText -Text ([string]$candidate.message) -Request $Request) -Suggestions @($candidate.suggestions|ForEach-Object{ConvertFrom-YakuReviewMaskedText -Text ([string]$_) -Request $Request}) -EvidenceLocations @($locations.ToArray()) -DependencyFingerprint $dependency -ReviewRunId $runId -EvidenceQuality ([string]$candidate.evidence_quality) -EvidenceConfidence ([double]$candidate.evidence_confidence)
        $findings.Add($finding)|Out-Null
        foreach($alias in @($candidate.evidence|ForEach-Object{[string]$_.segment_alias}|Select-Object -Unique)){
            if(-not $findingIdsByAlias.ContainsKey($alias)){$findingIdsByAlias[$alias]=New-Object System.Collections.Generic.List[string]}
            $findingIdsByAlias[$alias].Add([string]$finding.finding_id)|Out-Null
        }
    }
    $coverage=New-Object System.Collections.Generic.List[object]
    $documentLenses=@('translation_consistency','target_document_consistency')
    foreach($lensRow in @($ParsedResult.LensCoverage)){
        $lens=[string]$lensRow.lens;$checked=@{};foreach($alias in @($lensRow.checked_aliases)){$checked[[string]$alias]=$true}
        if($documentLenses -contains $lens){
            $targetIds=@($Request.AliasToSegmentId.Keys|Sort-Object|ForEach-Object{[string]$Request.AliasToSegmentId[$_]})
            $lensFindingIds=@($findings.ToArray()|Where-Object{[string]$_.category -eq $lens}|ForEach-Object{[string]$_.finding_id}|Select-Object -Unique)
            $allChecked=(@($Request.AliasToSegmentId.Keys|Where-Object{-not $checked.ContainsKey([string]$_)}).Count -eq 0)
            $coverage.Add([pscustomobject]@{
                coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v2|copilot|'+$lens+'|'+($targetIds -join '|')+'|'+$dependency))
                scope='document';lens=$lens;target_kind='document_batch';target_ids=$targetIds;state=$(if(-not $allChecked){'skipped'}elseif($lensFindingIds.Count){'finding'}else{'checked'});finding_ids=$lensFindingIds
                reason=$(if($allChecked){''}else{'model_not_covered'});index_group_id=[string]$(try{$Request.IndexGroupId}catch{''});target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false
            })|Out-Null
            continue
        }
        foreach($alias in @($Request.AliasToSegmentId.Keys|Sort-Object)){
            $segmentId=[string]$Request.AliasToSegmentId[$alias]
            $ids=@($findings.ToArray()|Where-Object{[string]$_.category -eq $lens -and @($_.evidence_locations|Where-Object{[string]$_.segment_id -eq $segmentId}).Count -gt 0}|ForEach-Object{[string]$_.finding_id}|Select-Object -Unique)
            $state=$(if($ids.Count -gt 0){'finding'}elseif($checked.ContainsKey($alias)){'checked'}else{'skipped'})
            $coverage.Add([pscustomobject]@{
                coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v2|copilot|'+$lens+'|'+$segmentId+'|'+$dependency))
                scope='local';lens=$lens;target_kind='semantic_segment';target_ids=@($segmentId);state=$state;finding_ids=$ids
                reason=$(if($state -eq 'skipped'){'model_not_covered'}else{''});target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false
            })|Out-Null
        }
    }
    $universeHash=Get-YakuCatSourceIntegrityHash -Text (@($coverage|ForEach-Object{[string]$_.coverage_item_id}|Sort-Object)-join '|')
    foreach($item in @($coverage.ToArray())){$item.target_universe_hash=$universeHash}
    $run=[pscustomobject]@{
        review_run_id=$runId;contract_version=[string]$Request.ContractVersion;detector='copilot';dependency_fingerprint=$dependency
        started_at=(Get-Date).ToString('o');completed_at=(Get-Date).ToString('o');status='completed';target_universe_hash=$universeHash
        coverage_items=@($coverage.ToArray());coverage_summary=(Get-YakuCatReviewCoverageSummary -Items @($coverage.ToArray()));finding_ids=@($findings.ToArray()|ForEach-Object{[string]$_.finding_id})
    }
    foreach($fresh in @($findings.ToArray())){
        $prior=@($Project.DocumentFindings|Where-Object{[string]$_.finding_id -eq [string]$fresh.finding_id -and [string]$_.finding_fingerprint -eq [string]$fresh.finding_fingerprint}|Select-Object -First 1)
        if($prior.Count -eq 1 -and [string]$prior[0].status -notin @('open','stale')){
            $fresh.status=[string]$prior[0].status
            foreach($name in @('disposition_event_id','disposition_note')){if($prior[0].PSObject.Properties.Name -contains $name){$fresh|Add-Member -NotePropertyName $name -NotePropertyValue $prior[0].$name -Force}}
        }
    }
    foreach($old in @($Project.DocumentFindings|Where-Object{[string]$_.detector -eq 'copilot' -and [string]$_.dependency_fingerprint -ne $dependency -and [string]$_.status -ne 'stale'})){$old.status='stale'}
    $other=@($Project.DocumentFindings|Where-Object{[string]$_.detector -ne 'copilot' -or [string]$_.dependency_fingerprint -ne $dependency})
    $Project.DocumentFindings=@($other+@($findings.ToArray()))
    $allRuns=@($Project.ReviewRuns)+@($run);$Project.ReviewRuns=@($allRuns|Select-Object -Last 20)
    return $run
}

function ConvertTo-YakuCatDocumentReviewRequestFromJobPacket {
    param([Parameter(Mandatory=$true)]$Packet)
    $aliases=@{};foreach($property in @($Packet.alias_to_segment_id.PSObject.Properties)){$aliases[[string]$property.Name]=[string]$property.Value}
    if(-not [bool]$Packet.sanitized){throw 'CAT_REVIEW_JOB_PACKET_NOT_SANITIZED'}
    return [pscustomobject]@{RequestId=[string]$Packet.request_id;AliasToSegmentId=$aliases;ContractVersion=[string]$Packet.contract_version;DependencyFingerprint=[string]$Packet.dependency_fingerprint;ProjectRevision=[int]$Packet.project_revision;ReviewPurpose=$(if([string]$Packet.review_purpose -eq 'document_index'){'document_index'}else{'local'});IndexLens=[string]$Packet.index_lens;IndexGroupId=[string]$Packet.index_group_id;Sanitized=$true}
}

function Apply-YakuCatCopilotDocumentReviewPackets {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Packets,[AllowEmptyCollection()][string[]]$SkippedSegmentIds=@(),[string]$SourceJobId='')
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    $originalFindings=@($Project.DocumentFindings);$originalRuns=@($Project.ReviewRuns)
    $collectedFindings=New-Object System.Collections.Generic.List[object];$collectedCoverage=New-Object System.Collections.Generic.List[object]
    $localLenses=@('bilingual_block','names_terms_abbreviations','structure_notes','gap')
    $documentLenses=@('translation_consistency','target_document_consistency')
    foreach($packet in @($Packets)){
        $request=ConvertTo-YakuCatDocumentReviewRequestFromJobPacket -Packet $packet
        if([string]$request.DependencyFingerprint -ne $dependency){throw 'CAT_REVIEW_RESULT_STALE'}
        $parsed=$packet.parsed_result
        if([string]$request.ReviewPurpose -eq 'document_index'){
            $parsed=[pscustomobject]@{ContractVersion=[string]$parsed.ContractVersion;Findings=@($parsed.Findings|Where-Object{[string]$_.category -eq [string]$request.IndexLens});LensCoverage=@($parsed.LensCoverage|Where-Object{[string]$_.lens -eq [string]$request.IndexLens})}
        }else{
            $parsed=[pscustomobject]@{ContractVersion=[string]$parsed.ContractVersion;Findings=@($parsed.Findings|Where-Object{[string]$_.category -notin $documentLenses});LensCoverage=@($parsed.LensCoverage|Where-Object{[string]$_.lens -notin $documentLenses})}
        }
        $run=Apply-YakuCatCopilotDocumentReviewResult -Project $Project -Request $request -ParsedResult $parsed
        foreach($finding in @($Project.DocumentFindings|Where-Object{[string]$_.review_run_id -eq [string]$run.review_run_id})){$collectedFindings.Add($finding)|Out-Null}
        foreach($item in @($run.coverage_items)){$collectedCoverage.Add($item)|Out-Null}
    }
    foreach($segmentId in @($SkippedSegmentIds|Select-Object -Unique)){
        foreach($lens in $localLenses){
            $collectedCoverage.Add([pscustomobject]@{coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v2|copilot|'+$lens+'|'+$segmentId+'|'+$dependency));scope='local';lens=$lens;target_kind='semantic_segment';target_ids=@($segmentId);state='skipped';finding_ids=@();reason='input_limit';target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false})|Out-Null
        }
    }
    # 文書横断レンズはローカルDocumentIndexが列挙したgroup単位で判定する。
    # 通常の連続batchを通しただけのdocument lensは母集団へ含めない。
    $batchDocumentItems=@($collectedCoverage.ToArray()|Where-Object{$documentLenses -contains [string]$_.lens})
    $keptCoverage=@($collectedCoverage.ToArray()|Where-Object{$documentLenses -notcontains [string]$_.lens})
    $collectedCoverage=New-Object System.Collections.Generic.List[object];foreach($item in $keptCoverage){$collectedCoverage.Add($item)|Out-Null}
    foreach($lens in $documentLenses){
        $expectedGroups=@($(try{$Project.DocumentIndexSnapshot.groups}catch{@()})|Where-Object{[string]$_.lens -eq $lens})
        if($expectedGroups.Count -eq 0){
            $collectedCoverage.Add([pscustomobject]@{coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v3|copilot-index-empty|'+$lens+'|'+$dependency));scope='document';lens=$lens;target_kind='document_index';target_ids=@();state='checked';finding_ids=@();reason='no_index_candidates';target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false})|Out-Null
            continue
        }
        foreach($group in $expectedGroups){
            $expectedIds=@($group.segment_ids|ForEach-Object{[string]$_}|Sort-Object)
            $lensItems=@($batchDocumentItems|Where-Object{
                if([string]$_.lens -ne $lens){return $false}
                if([string]$_.index_group_id -eq [string]$group.group_id){return $true}
                $actualIds=@($_.target_ids|ForEach-Object{[string]$_}|Sort-Object)
                return (($actualIds -join '|') -ceq ($expectedIds -join '|'))
            })
            $findingIds=@($lensItems|ForEach-Object{@($_.finding_ids)}|ForEach-Object{[string]$_}|Sort-Object -Unique)
            $valid=($lensItems.Count -eq 1 -and [string]$lensItems[0].state -in @('checked','finding'))
            $collectedCoverage.Add([pscustomobject]@{coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v3|copilot-index|'+[string]$group.group_id+'|'+$dependency));scope='document';lens=$lens;target_kind=[string]$group.kind;target_ids=@($group.segment_ids);index_group_id=[string]$group.group_id;state=$(if(-not $valid){'skipped'}elseif($findingIds.Count){'finding'}else{'checked'});finding_ids=$findingIds;reason=$(if($valid){''}else{'index_group_not_checked'});target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false})|Out-Null
        }
    }
    if($collectedCoverage.Count -eq 0){throw 'CAT_REVIEW_RESULT_EMPTY'}
    $combinedRunId=[guid]::NewGuid().ToString('N')
    $dedupedFindings=@($collectedFindings.ToArray()|Group-Object finding_id|ForEach-Object{$_.Group[0]})
    foreach($finding in $dedupedFindings){$finding.review_run_id=$combinedRunId}
    $universeHash=Get-YakuCatSourceIntegrityHash -Text (@($collectedCoverage|ForEach-Object{[string]$_.coverage_item_id}|Sort-Object -Unique)-join '|');foreach($item in @($collectedCoverage.ToArray())){$item.target_universe_hash=$universeHash}
    $run=[pscustomobject]@{review_run_id=$combinedRunId;contract_version='document-review-copilot-v2';detector='copilot';source_job_id=$SourceJobId;dependency_fingerprint=$dependency;started_at=(Get-Date).ToString('o');completed_at=(Get-Date).ToString('o');status='completed';target_universe_hash=$universeHash;coverage_items=@($collectedCoverage.ToArray());coverage_summary=(Get-YakuCatReviewCoverageSummary -Items @($collectedCoverage.ToArray()));finding_ids=@($dedupedFindings|ForEach-Object{[string]$_.finding_id})}
    foreach($fresh in $dedupedFindings){
        $prior=@($originalFindings|Where-Object{[string]$_.finding_id -eq [string]$fresh.finding_id -and [string]$_.finding_fingerprint -eq [string]$fresh.finding_fingerprint}|Select-Object -First 1)
        if($prior.Count -eq 1 -and [string]$prior[0].status -notin @('open','stale')){$fresh.status=[string]$prior[0].status;foreach($name in @('disposition_event_id','disposition_note')){if($prior[0].PSObject.Properties.Name -contains $name){$fresh|Add-Member -NotePropertyName $name -NotePropertyValue $prior[0].$name -Force}}}
    }
    foreach($old in @($originalFindings|Where-Object{[string]$_.detector -eq 'copilot' -and [string]$_.dependency_fingerprint -ne $dependency -and [string]$_.status -ne 'stale'})){$old.status='stale'}
    $Project.DocumentFindings=@($originalFindings|Where-Object{[string]$_.detector -ne 'copilot' -or [string]$_.dependency_fingerprint -ne $dependency})+@($dedupedFindings)
    $allRuns=@($originalRuns)+@($run);$Project.ReviewRuns=@($allRuns|Select-Object -Last 20)
    return $run
}

function New-YakuCatReviewEvidenceLocation {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Segment,
        [ValidateSet('source','target')][string]$Side
    )
    $kind = $(if ([string]$Project.Source -eq 'text') { 'copied_text' } elseif ([string]$Project.DocumentFormat -eq 'docx') { 'docx' } elseif ([string]$Project.DocumentFormat -eq 'csv') { 'csv' } else { 'xlsx' })
    return [pscustomobject]@{
        artifact_kind=$kind; segment_id=[string]$Segment.SegmentId; side=$Side
        sheet=$(try{[string]$Segment.Sheet}catch{''}); cells=@($(try{$Segment.Cells}catch{@()}))
        text_block_ids=@($(try{$Segment.BlockIds}catch{@()})); quote=$(if($Side -eq 'source'){[string]$Segment.Text}else{[string]$Segment.Translation})
    }
}

function New-YakuCatDocumentFinding {
    param(
        [Parameter(Mandatory=$true)][string]$Scope,
        [Parameter(Mandatory=$true)][string]$Category,
        [ValidateSet('deterministic','copilot','human')][string]$Detector,
        [Parameter(Mandatory=$true)][string]$DetectorContractVersion,
        [ValidateSet('info','warning','error')][string]$Severity,
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$EvidenceLocations,
        [Parameter(Mandatory=$true)][string]$DependencyFingerprint,
        [string[]]$Suggestions=@(),
        [string]$ReviewRunId='',
        [ValidateSet('clear','unclear')][string]$EvidenceQuality='clear',
        [ValidateRange(0.0,1.0)][double]$EvidenceConfidence=1.0
    )
    if ($Category -eq 'rendered_output_completeness' -and $Detector -eq 'copilot') { throw 'CAT_REVIEW_RENDER_FINDING_DETECTOR_INVALID' }
    $evidenceKeys = @($EvidenceLocations | ForEach-Object {
        [string]$_.artifact_kind + ':' + [string]$_.segment_id + ':' + [string]$_.side + ':' + (Get-YakuCatSourceIntegrityHash -Text ([string]$_.quote))
    } | Sort-Object)
    $id = Get-YakuCatSourceIntegrityHash -Text ('document-finding-id-v1|' + $Scope + '|' + $Category + '|' + ($evidenceKeys -join '|') + '|' + $DetectorContractVersion)
    $fingerprint = Get-YakuCatSourceIntegrityHash -Text ('document-finding-v1|' + $id + '|' + $Severity + '|' + $Message + '|' + $DependencyFingerprint)
    return [pscustomobject]@{
        finding_id=$id; finding_revision=1; finding_fingerprint=$fingerprint; review_run_id=$ReviewRunId
        scope=$Scope; category=$Category; detector=$Detector; detector_contract_version=$DetectorContractVersion
        severity=$Severity; status='open'; title=$Title; message=$Message; suggestions=@($Suggestions)
        evidence_locations=@($EvidenceLocations); evidence_quality=$EvidenceQuality; evidence_confidence=$EvidenceConfidence
        dependency_fingerprint=$DependencyFingerprint; created_at=(Get-Date).ToString('o'); updated_at=(Get-Date).ToString('o')
    }
}

function Get-YakuCatReviewCoverageSummary {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Items)
    $all=@($Items)
    $allowed=@('checked','finding','unreadable','unmapped','skipped')
    $enumerationComplete=($all.Count -gt 0 -and @($all|Where-Object{$allowed -notcontains [string]$_.state}).Count -eq 0)
    $evidenceComplete=($enumerationComplete -and @($all|Where-Object{[string]$_.state -in @('unreadable','unmapped','skipped')}).Count -eq 0)
    $decisionComplete=($enumerationComplete -and @($all|Where-Object{[string]$_.state -in @('unreadable','unmapped','skipped') -and -not [bool]$_.human_decision_current}).Count -eq 0)
    return [pscustomobject]@{
        target_count=$all.Count; checked_count=@($all|Where-Object{$_.state -eq 'checked'}).Count
        finding_count=@($all|Where-Object{$_.state -eq 'finding'}).Count
        unreadable_count=@($all|Where-Object{$_.state -eq 'unreadable'}).Count
        unmapped_count=@($all|Where-Object{$_.state -eq 'unmapped'}).Count
        skipped_count=@($all|Where-Object{$_.state -eq 'skipped'}).Count
        enumeration_complete=$enumerationComplete; evidence_complete=$evidenceComplete; decision_complete=$decisionComplete
    }
}

function Invoke-YakuCatDeterministicDocumentReview {
    param([Parameter(Mandatory=$true)]$Project)
    $null=Initialize-YakuCatProjectState -Project $Project
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    $Project.DocumentIndexSnapshot=New-YakuCatDocumentIndexSnapshot -Project $Project
    $runId=[guid]::NewGuid().ToString('N')
    $findings=New-Object System.Collections.Generic.List[object]
    $coverage=New-Object System.Collections.Generic.List[object]
    $groups=@{}
    foreach($segment in @($Project.Segments)){
        $sourceKey=ConvertTo-YakuRebaseComparableText -Text ([string]$segment.Text)
        if([string]::IsNullOrWhiteSpace($sourceKey)){continue}
        if(-not $groups.ContainsKey($sourceKey)){$groups[$sourceKey]=New-Object System.Collections.Generic.List[object]}
        $groups[$sourceKey].Add($segment)
    }
    $groupIndex=0
    foreach($entry in @($groups.GetEnumerator()|Sort-Object Name)){
        $segments=@($entry.Value.ToArray())
        if($segments.Count -lt 2){continue}
        $groupIndex++
        $targets=@($segments|ForEach-Object{ConvertTo-YakuRebaseComparableText -Text ([string]$_.Translation)}|Sort-Object -Unique)
        $itemId=Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v1|translation_consistency|'+($segments.SegmentId -join '|')+'|'+$dependency)
        $findingIds=@()
        if($targets.Count -gt 1){
            $evidence=@();foreach($segment in $segments){$evidence+=New-YakuCatReviewEvidenceLocation -Project $Project -Segment $segment -Side 'source';$evidence+=New-YakuCatReviewEvidenceLocation -Project $Project -Segment $segment -Side 'target'}
            $finding=New-YakuCatDocumentFinding -Scope 'document' -Category 'translation_consistency' -Detector 'deterministic' -DetectorContractVersion 'translation-consistency-exact-v1' -Severity 'warning' -Title '同じ原文に異なる訳があります' -Message '同じ原文が文書内で異なる英訳になっています。文脈上の訳し分けか、統一が必要かを確認してください。' -EvidenceLocations $evidence -DependencyFingerprint $dependency -ReviewRunId $runId
            $findings.Add($finding)|Out-Null;$findingIds=@([string]$finding.finding_id)
        }
        $coverage.Add([pscustomobject]@{
            coverage_item_id=$itemId; scope='document'; lens='translation_consistency'; target_kind='repeated_source_group'
            target_ids=@($segments.SegmentId); state=$(if($findingIds.Count){'finding'}else{'checked'}); finding_ids=$findingIds
            reason=''; target_universe_hash=''; dependency_fingerprint=$dependency; human_decision_current=$false
        })|Out-Null
    }
    if($groupIndex -eq 0){
        $coverage.Add([pscustomobject]@{
            coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v1|translation_consistency|document|'+$dependency))
            scope='document';lens='translation_consistency';target_kind='document_index';target_ids=@();state='checked';finding_ids=@();reason='no_repeated_source_groups'
            target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false
        })|Out-Null
    }
    $universeHash=Get-YakuCatSourceIntegrityHash -Text (@($coverage|ForEach-Object{[string]$_.coverage_item_id}|Sort-Object)-join '|')
    foreach($item in @($coverage.ToArray())){$item.target_universe_hash=$universeHash}
    $summary=Get-YakuCatReviewCoverageSummary -Items @($coverage.ToArray())
    $run=[pscustomobject]@{
        review_run_id=$runId; contract_version='document-review-run-v1'; detector='deterministic'; dependency_fingerprint=$dependency
        started_at=(Get-Date).ToString('o');completed_at=(Get-Date).ToString('o');status='completed';target_universe_hash=$universeHash
        coverage_items=@($coverage.ToArray());coverage_summary=$summary;finding_ids=@($findings.ToArray()|ForEach-Object{[string]$_.finding_id})
    }
    foreach($fresh in @($findings.ToArray())){
        $prior=@($Project.DocumentFindings|Where-Object{[string]$_.finding_id -eq [string]$fresh.finding_id -and [string]$_.finding_fingerprint -eq [string]$fresh.finding_fingerprint}|Select-Object -First 1)
        if($prior.Count -eq 1 -and [string]$prior[0].status -notin @('open','stale')){
            $fresh.status=[string]$prior[0].status
            foreach($name in @('disposition_event_id','disposition_note')){if($prior[0].PSObject.Properties.Name -contains $name){$fresh|Add-Member -NotePropertyName $name -NotePropertyValue $prior[0].$name -Force}}
        }
    }
    $oldFindings=@($Project.DocumentFindings|Where-Object{[string]$_.dependency_fingerprint -ne $dependency -or [string]$_.detector_contract_version -ne 'translation-consistency-exact-v1'})
    foreach($old in @($Project.DocumentFindings|Where-Object{[string]$_.detector_contract_version -eq 'translation-consistency-exact-v1' -and [string]$_.dependency_fingerprint -ne $dependency -and [string]$_.status -ne 'stale'})){$old.status='stale'}
    $Project.DocumentFindings=@($oldFindings+@($findings.ToArray()))
    $Project.ReviewRuns=@(@($Project.ReviewRuns)+@($run)|Select-Object -Last 20)
    return $run
}

function Set-YakuCatDocumentFindingDecision {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$FindingId,
        [Parameter(Mandatory=$true)][int]$FindingRevision,
        [ValidateSet('fixed_pending_verify','resolved','false_positive','accepted_risk','deferred','reopen')][string]$Action,
        [string]$ReasonCode='',
        [string]$Note=''
    )
    $finding=@($Project.DocumentFindings|Where-Object{[string]$_.finding_id -eq $FindingId}|Select-Object -First 1)
    if($finding.Count -ne 1 -or [int]$finding[0].finding_revision -ne $FindingRevision){throw 'CAT_FINDING_NOT_CURRENT'}
    $item=$finding[0]
    $allowed=@{
        open=@('fixed_pending_verify','false_positive','accepted_risk','deferred');fixed_pending_verify=@('resolved','reopen')
        resolved=@('reopen');false_positive=@('reopen');accepted_risk=@('reopen');deferred=@('reopen')
    }
    $current=[string]$item.status;if(-not $allowed.ContainsKey($current) -or @($allowed[$current]) -notcontains $Action){throw 'CAT_FINDING_TRANSITION_INVALID'}
    if($Action -in @('false_positive','accepted_risk','deferred') -and [string]::IsNullOrWhiteSpace($ReasonCode)){throw 'CAT_FINDING_REASON_REQUIRED'}
    if($Action -in @('false_positive','accepted_risk','deferred') -and [string]::IsNullOrWhiteSpace(([string]$Note).Trim())){throw 'CAT_FINDING_EXPLANATION_REQUIRED'}
    if($Action -eq 'false_positive' -and $ReasonCode -eq 'context_specific' -and [string]$item.category -notin @('translation_consistency','target_document_consistency')){throw 'CAT_FINDING_REASON_NOT_APPLICABLE'}
    $newStatus=$(if($Action -eq 'reopen'){'open'}else{$Action})
    $eventId=Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'document' -Action $Action -ReasonCode $ReasonCode -DependencyFingerprint ([string]$item.dependency_fingerprint) -FindingId $FindingId -FindingRevision $FindingRevision -FindingFingerprint ([string]$item.finding_fingerprint)
    $item.status=$newStatus;$item.updated_at=(Get-Date).ToString('o')
    $item|Add-Member -NotePropertyName disposition_event_id -NotePropertyValue $eventId -Force
    $item|Add-Member -NotePropertyName disposition_note -NotePropertyValue ([string]$Note).Trim() -Force
    return $item
}

function Get-YakuCatCanonicalTranslationSetHash {
    param([Parameter(Mandatory=$true)]$Project)
    $parts=@($Project.Segments|ForEach-Object{[string]$_.SegmentId+':'+[string]$_.SourceIntegrityHash+':'+(Get-YakuCatSourceIntegrityHash -Text ([string]$_.Translation))})
    return Get-YakuCatSourceIntegrityHash -Text ('canonical-set-v1|'+($parts -join '|'))
}

function Get-YakuCatPublicationTranslationSetHash {
    param([Parameter(Mandatory=$true)]$Project)
    $parts=@($Project.Segments|ForEach-Object{
        $resolved=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $_}else{[pscustomobject]@{TextHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$_.Translation));VariantId='';VariantRevision=0;VariantHash=''}})
        [string]$_.SegmentId+':'+[string]$resolved.TextHash+':'+[string]$resolved.VariantId+':'+[string]$resolved.VariantRevision+':'+[string]$resolved.VariantHash
    })
    return Get-YakuCatSourceIntegrityHash -Text ('publication-set-v1|'+($parts -join '|'))
}

function Get-YakuCatCurrentReviewRunsForFinalDecision {
    param([Parameter(Mandatory=$true)]$Project)
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    $current=@($Project.ReviewRuns|Where-Object{([string]$_.dependency_fingerprint -eq $dependency -or [string]$(try{$_.document_dependency_fingerprint}catch{''}) -eq $dependency) -and [string]$_.status -eq 'completed'})
    $latest=New-Object System.Collections.Generic.List[object]
    foreach($group in @($current|Group-Object { [string]$_.detector+'|'+[string]$_.contract_version+'|'+[string]$(try{$_.render_id}catch{''}) })){$latest.Add(@($group.Group)[-1])|Out-Null}
    return @($latest.ToArray())
}

function Get-YakuCatRequiredReviewProfileStatus {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Runs,[string]$RenderId='')
    $missing=New-Object System.Collections.Generic.List[string]
    if($null -ne $Project.DocumentIndexSnapshot){try{$null=Assert-YakuCatDocumentIndexSnapshot -Project $Project -Snapshot $Project.DocumentIndexSnapshot}catch{if($_.Exception.Message -eq 'CAT_REVIEW_DOCUMENT_INDEX_STALE'){$missing.Add('document_index.stale')|Out-Null}else{throw}}}
    $requiredProfileKeys=@(
        'deterministic.document-review-run-v1.translation_consistency',
        'copilot.document-review-copilot-v2.bilingual_block.all_segments',
        'copilot.document-review-copilot-v2.names_terms_abbreviations.all_segments',
        'copilot.document-review-copilot-v2.structure_notes.all_segments',
        'copilot.document-review-copilot-v2.gap.all_segments',
        'copilot.document-review-copilot-v2.translation_consistency.document_index',
        'copilot.document-review-copilot-v2.target_document_consistency.document_index'
    )
    if(-not [string]::IsNullOrWhiteSpace($RenderId)){$requiredProfileKeys+=@('pdf.rendered_output_completeness')}
    $allSegmentIds=@($Project.Segments|ForEach-Object{[string]$_.SegmentId}|Sort-Object)
    $usable={param($item)return ([string]$item.state -in @('checked','finding') -or ([string]$item.state -in @('unreadable','unmapped','skipped') -and [bool]$item.human_decision_current))}
    $deterministic=@($Runs|Where-Object{[string]$_.detector -eq 'deterministic' -and [string]$_.contract_version -eq 'document-review-run-v1'}|Select-Object -Last 1)
    if($deterministic.Count -ne 1 -or @($deterministic[0].coverage_items|Where-Object{[string]$_.scope -eq 'document' -and [string]$_.lens -eq 'translation_consistency' -and (& $usable $_)}).Count -eq 0){$missing.Add('deterministic.translation_consistency')|Out-Null}
    $copilot=@($Runs|Where-Object{[string]$_.detector -eq 'copilot' -and [string]$_.contract_version -eq 'document-review-copilot-v2'}|Select-Object -Last 1)
    if($copilot.Count -ne 1){$missing.Add('copilot.run.v2')|Out-Null}else{
        foreach($lens in @('bilingual_block','names_terms_abbreviations','structure_notes','gap')){
            $items=@($copilot[0].coverage_items|Where-Object{[string]$_.scope -eq 'local' -and [string]$_.lens -eq $lens -and (& $usable $_)})
            $covered=@($items|ForEach-Object{@($_.target_ids)}|ForEach-Object{[string]$_}|Sort-Object -Unique)
            if(($covered -join '|') -cne ($allSegmentIds -join '|')){$missing.Add('copilot.'+$lens+'.all_segments')|Out-Null}
        }
        foreach($lens in @('translation_consistency','target_document_consistency')){
            $items=@($copilot[0].coverage_items|Where-Object{[string]$_.scope -eq 'document' -and [string]$_.lens -eq $lens -and (& $usable $_)})
            $expectedGroups=@($(try{$Project.DocumentIndexSnapshot.groups}catch{@()})|Where-Object{[string]$_.lens -eq $lens})
            $legacyFull=@($items|Where-Object{[string]$_.target_kind -eq 'document_index'});$legacyFullIds=@($legacyFull|ForEach-Object{@($_.target_ids)}|ForEach-Object{[string]$_}|Sort-Object -Unique)
            # 現行DocumentIndexがあるprojectでは、旧runの全文一括itemでgroup別coverageを
            # 代用しない。requestをまたぐ比較対象が抜けてもcompleteになってしまうため。
            $hasCurrentIndex=($null -ne $Project.DocumentIndexSnapshot -and -not [string]::IsNullOrWhiteSpace([string]$Project.DocumentIndexSnapshot.snapshot_hash))
            if(-not $hasCurrentIndex -and $legacyFull.Count -eq 1 -and ($legacyFullIds -join '|') -ceq ($allSegmentIds -join '|')){continue}
            if($expectedGroups.Count -eq 0){
                $legacy=@($items|Where-Object{[string]$_.target_kind -eq 'document_index'});$legacyCovered=@($legacy|ForEach-Object{@($_.target_ids)}|ForEach-Object{[string]$_}|Sort-Object -Unique)
                if(@($items|Where-Object{[string]$_.reason -eq 'no_index_candidates'}).Count -ne 1 -and ($legacy.Count -ne 1 -or ($legacyCovered -join '|') -cne ($allSegmentIds -join '|'))){$missing.Add('copilot.'+$lens+'.document_index')|Out-Null}
                continue
            }
            foreach($group in $expectedGroups){
                $expectedIds=@($group.segment_ids|ForEach-Object{[string]$_}|Sort-Object)
                $matched=@($items|Where-Object{[string]$_.index_group_id -eq [string]$group.group_id -or ([string]::IsNullOrWhiteSpace([string]$_.index_group_id) -and ((@($_.target_ids|ForEach-Object{[string]$_}|Sort-Object)-join '|') -ceq ($expectedIds -join '|')))})
                if($matched.Count -ne 1){$missing.Add('copilot.'+$lens+'.document_index.'+[string]$group.group_id)|Out-Null}
            }
        }
    }
    if(-not [string]::IsNullOrWhiteSpace($RenderId)){
        $pdf=@($Runs|Where-Object{[string]$(try{$_.render_id}catch{''}) -eq $RenderId -and @($_.coverage_items|Where-Object{[string]$_.lens -eq 'rendered_output_completeness' -and (& $usable $_)}).Count -gt 0}|Select-Object -Last 1)
        if($pdf.Count -ne 1){$missing.Add('rendered_output_completeness')|Out-Null}
    }
    # 必須観点が将来増減した場合、すべて完了してmissingが空のままでも旧判断を
    # currentへ戻さない。profile定義そのものをhashへ含める。
    $hash=Get-YakuCatSourceIntegrityHash -Text ('required-review-profile-v2|requirements='+($requiredProfileKeys -join ',')+'|missing='+($missing.ToArray() -join ',')+'|targets='+($allSegmentIds -join ',')+'|render='+$RenderId)
    return [pscustomobject]@{complete=($missing.Count -eq 0);missing=@($missing.ToArray());profile_hash=$hash}
}

function Get-YakuCatReviewDecisionSetHash {
    param([Parameter(Mandatory=$true)]$Project,[AllowNull()][object[]]$Runs)
    $selected=$(if($PSBoundParameters.ContainsKey('Runs')){@($Runs)}else{@(Get-YakuCatCurrentReviewRunsForFinalDecision -Project $Project)})
    $runRows=@($selected|Sort-Object review_run_id|ForEach-Object{
        $run=$_;$coverage=@($run.coverage_items|Sort-Object coverage_item_id|ForEach-Object{
            [string]$_.coverage_item_id+':'+[string]$_.state+':'+[string]$_.human_decision_current+':'+[string]$(try{$_.human_decision_event_id}catch{''})+':'+(@($_.finding_ids|ForEach-Object{[string]$_}|Sort-Object)-join ',')
        })
        [string]$run.review_run_id+':'+[string]$run.target_universe_hash+':'+($coverage -join ';')
    })
    $findingRows=@($Project.DocumentFindings|Sort-Object finding_id|ForEach-Object{
        [string]$_.finding_id+':'+[string]$_.finding_revision+':'+[string]$_.finding_fingerprint+':'+[string]$_.status+':'+[string]$(try{$_.disposition_event_id}catch{''})
    })
    # final event自身は除外する。掲載訳をA→B→Aへ戻す、findingを再openする等の
    # 人の操作eventは内容hashが元へ戻ってもepochとして残る。
    $eventRows=@($Project.ReviewEvents|Where-Object{[string]$_.decision_scope -ne 'final'}|Sort-Object event_id|ForEach-Object{[string]$_.event_id+':'+[string]$_.decision_scope+':'+[string]$_.action+':'+[string]$_.dependency_fingerprint})
    return Get-YakuCatSourceIntegrityHash -Text ('review-decision-set-v1|'+($runRows -join '|')+'|'+($findingRows -join '|')+'|'+($eventRows -join '|'))
}

function ConvertTo-YakuPdfComparableText {
    param([AllowNull()][string]$Text)
    return [regex]::Replace(([string]$Text).Normalize([Text.NormalizationForm]::FormKC),'[\s\u200B\u200C\u200D\uFEFF]+','').ToLowerInvariant()
}

function Invoke-YakuCatPdfTextCompletenessReview {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$RenderId,
        [Parameter(Mandatory=$true)][string]$PdfSha256,
        [Parameter(Mandatory=$true)][string]$ExtractorContract,
        [Parameter(Mandatory=$true)][int]$PageCount,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Pages
    )
    $null=Initialize-YakuCatProjectState -Project $Project
    if($ExtractorContract -cne 'pdfjs-text-v2@5.7.284'){throw 'CAT_PDF_REVIEW_EXTRACTOR_INVALID'}
    $resolved=Resolve-YakuCatRenderPdf -ProjectId ([string]$Project.Id) -RenderId $RenderId;$manifest=$resolved.Manifest
    if([string]$manifest.canonical_pdf_sha256 -ne $PdfSha256){throw 'CAT_PDF_REVIEW_HASH_MISMATCH'}
    if([string]$manifest.source_snapshot_id -ne [string]$Project.ActiveSourceId -or [string]$manifest.input_fingerprint -ne (Get-YakuCatRenderInputFingerprint -Project $Project)){throw 'CAT_PDF_REVIEW_RENDER_STALE'}
    $pageRows=@($Pages);if($PageCount -lt 1 -or $PageCount -gt 1000 -or $pageRows.Count -ne $PageCount){throw 'CAT_PDF_REVIEW_PAGE_COUNT_INVALID'}
    $totalChars=0;$totalItems=0;$normalizedPages=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt $pageRows.Count;$i++){
        if([int]$pageRows[$i].page -ne $i+1){throw 'CAT_PDF_REVIEW_PAGE_ORDER_INVALID'}
        $text=[string]$pageRows[$i].text;$totalChars+=$text.Length;if($totalChars -gt 10000000){throw 'CAT_PDF_REVIEW_TEXT_LIMIT'}
        $pageBox=$pageRows[$i].page_box;$width=[double]$pageBox.width;$height=[double]$pageBox.height;$rotation=[int]$pageBox.rotation
        if($width -le 0 -or $height -le 0 -or $width -gt 100000 -or $height -gt 100000 -or $rotation -notin @(0,90,180,270)){throw 'CAT_PDF_REVIEW_PAGE_BOX_INVALID'}
        $offset=0;$indexedItems=New-Object System.Collections.Generic.List[object]
        foreach($item in @($pageRows[$i].items)){
            $totalItems++;if($totalItems -gt 500000){throw 'CAT_PDF_REVIEW_ITEM_LIMIT'}
            $part=ConvertTo-YakuPdfComparableText -Text ([string]$item.text)
            if([string]::IsNullOrWhiteSpace($part)){continue}
            $bbox=$item.bbox;$x=[double]$bbox.x;$y=[double]$bbox.y;$w=[double]$bbox.w;$h=[double]$bbox.h
            if([string]$bbox.space -ne 'viewport_points' -or [double]::IsNaN($x) -or [double]::IsNaN($y) -or [double]::IsNaN($w) -or [double]::IsNaN($h) -or $w -lt 0 -or $h -lt 0 -or $x -lt -1 -or $y -lt -1 -or $x+$w -gt $width+1 -or $y+$h -gt $height+1){throw 'CAT_PDF_REVIEW_BBOX_INVALID'}
            $indexedItems.Add([pscustomobject]@{start=$offset;end=$offset+$part.Length;bbox=[pscustomobject]@{space='viewport_points';x=$x;y=$y;w=$w;h=$h;page_width=$width;page_height=$height;rotation=$rotation;crop_box=@($bbox.crop_box)}})|Out-Null;$offset+=$part.Length
        }
        $comparable=ConvertTo-YakuPdfComparableText -Text $text
        if($offset -gt 0 -and $offset -ne $comparable.Length){throw 'CAT_PDF_REVIEW_TEXT_ITEM_MISMATCH'}
        $normalizedPages.Add([pscustomobject]@{page=$i+1;text=$text;comparable=$comparable;items=@($indexedItems.ToArray());page_box=[pscustomobject]@{width=$width;height=$height;rotation=$rotation;crop_box=@($pageBox.crop_box)}})|Out-Null
    }
    $documentDependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    $dependency=Get-YakuCatSourceIntegrityHash -Text ('pdf-text-review-v1|'+$documentDependency+'|'+$RenderId+'|'+$PdfSha256+'|'+$ExtractorContract)
    $runId=[guid]::NewGuid().ToString('N');$coverage=New-Object System.Collections.Generic.List[object];$findings=New-Object System.Collections.Generic.List[object]
    $null=Sync-YakuCatPlacementPlans -Project $Project
    $segmentsById=@{};foreach($segment in @($Project.Segments)){$segmentsById[[string]$segment.SegmentId]=$segment}
    foreach($plan in @($Project.PlacementPlans)){
        $segmentId=[string]$plan.segment_id;$expected=@($plan.destinations|ForEach-Object{[string]$_.text}) -join '';$needle=ConvertTo-YakuPdfComparableText -Text $expected
        $matches=New-Object System.Collections.Generic.List[object]
        if(-not [string]::IsNullOrWhiteSpace($needle)){foreach($page in @($normalizedPages.ToArray())){$position=0;while($position -le ([string]$page.comparable).Length-$needle.Length){$found=([string]$page.comparable).IndexOf($needle,$position,[StringComparison]::Ordinal);if($found -lt 0){break};$matches.Add([pscustomobject]@{page=$page;start=$found;end=$found+$needle.Length})|Out-Null;$position=$found+[Math]::Max(1,$needle.Length)}}}
        $matchedPage=0;$matchBbox=$null
        if($matches.Count -eq 1){
            $match=$matches[0];$boxes=@($match.page.items|Where-Object{[int]$_.start -lt [int]$match.end -and [int]$_.end -gt [int]$match.start}|ForEach-Object{$_.bbox})
            if($boxes.Count -gt 0){$minX=($boxes|Measure-Object x -Minimum).Minimum;$minY=($boxes|Measure-Object y -Minimum).Minimum;$maxX=($boxes|ForEach-Object{[double]$_.x+[double]$_.w}|Measure-Object -Maximum).Maximum;$maxY=($boxes|ForEach-Object{[double]$_.y+[double]$_.h}|Measure-Object -Maximum).Maximum;$first=$boxes[0];$matchBbox=[pscustomobject]@{space='viewport_points';x=[double]$minX;y=[double]$minY;w=[double]$maxX-[double]$minX;h=[double]$maxY-[double]$minY;page_width=[double]$first.page_width;page_height=[double]$first.page_height;rotation=[int]$first.rotation;crop_box=@($first.crop_box)};$matchedPage=[int]$match.page.page}
        }
        # 文字がPDF内に一度だけ存在しても、期待したsheet/cellの掲載結果とはまだ
        # 対応付けられない。自動照合は候補位置の提示までに留め、目視判断を要求する。
        $findingIds=@();$state='unmapped';$reason=$(if($matches.Count -eq 0){'text_not_found_or_extraction_order_unknown'}elseif($matches.Count -gt 1){'duplicate_text_not_uniquely_mapped'}elseif($matchedPage -gt 0){'text_present_but_position_unassociated'}else{'text_coordinates_unavailable'})
        if($state -eq 'unmapped'){
            $segment=$segmentsById[$segmentId]
            $sourceEvidence=New-YakuCatReviewEvidenceLocation -Project $Project -Segment $segment -Side source
            $renderEvidence=[pscustomobject]@{artifact_kind='pdf';segment_id=$segmentId;side='render';sheet=[string]$plan.destinations[0].sheet;cells=@($plan.destinations|ForEach-Object{[string]$_.address});text_block_ids=@();quote=$expected;pdf_sha256=$PdfSha256;page=$matchedPage;association_status='unverified';match_count=$matches.Count;bbox=$matchBbox;extractor_contract=$ExtractorContract}
            # 「本文に無い」と「本文にあるが位置が結び付かない」を、同じ文言にしない。
            #
            # 2026-08-17 まで、掲載箇所すべてに同じ警告が1件ずつ立っていた。
            # match_count は coverage_items に記録されるのに、指摘の文面が同じなので
            # 「PDFの本文にその文字列が無い」行を利用者が拾えなかった。
            # 利用者の判定基準は「セルに収まっているかより、pdfで見て文字が
            # 切れていないか」であり、切れの証拠はまさに match_count = 0 である。
            #
            # 状態は unmapped のまま変えない。unmapped / unreadable / skipped だけが
            # 人の目視判断を要求するので、ここを finding へ動かすと、いちばん見て
            # ほしい行が確認義務から外れる。分けるのは文面のほうである。
            if($matches.Count -eq 0){
                $title='PDFの本文に掲載文が見つかりません'
                $message='PDFから抽出した本文に、この掲載文が1件も現れませんでした。文字が切れている（列や印刷範囲からはみ出した）可能性があります。ただし抽出器が文を分けて拾った場合も同じ結果になるため、欠落が確定したわけではありません。PDF画面でそのセルを確認してください。'
                $suggestions=@('PDF画面で該当セルを見て、文字が切れていないか確かめる','切れている場合は、そのセルの「縮小して全体を表示」か文字サイズで収める','右の空白セルへはみ出させている場合は、列幅を広げずにそのままでよい')
                $confidence=0.8
            } else {
                $title='PDFで掲載文の位置を自動確認できません'
                $message='PDFの文字抽出結果に掲載文はありますが、期待したセルの位置とは結び付けられませんでした。欠落が確定したという意味ではありません。PDF画面で切れ・重なり・印刷範囲を確認してください。'
                $suggestions=@('PDF画面で該当セルを見て、意図した場所に出ているか確かめる')
                $confidence=0.5
            }
            $finding=New-YakuCatDocumentFinding -Scope render -Category rendered_output_completeness -Detector deterministic -DetectorContractVersion 'pdfjs-text-presence-v2' -Severity warning -Title $title -Message $message -Suggestions $suggestions -EvidenceLocations @($sourceEvidence,$renderEvidence) -DependencyFingerprint $dependency -ReviewRunId $runId -EvidenceQuality unclear -EvidenceConfidence $confidence
            $findings.Add($finding)|Out-Null;$findingIds=@([string]$finding.finding_id)
        }
        $coverage.Add([pscustomobject]@{coverage_item_id=(Get-YakuCatSourceIntegrityHash -Text ('coverage-item-v2|pdf-text|'+$RenderId+'|'+[string]$plan.placement_id));scope='render';lens='rendered_output_completeness';target_kind='placement_plan';target_ids=@([string]$plan.placement_id,$segmentId);state=$state;finding_ids=$findingIds;reason=$reason;target_universe_hash='';dependency_fingerprint=$dependency;human_decision_current=$false;matched_page=$matchedPage;match_count=$matches.Count;match_bbox=$matchBbox})|Out-Null
    }
    if($coverage.Count -eq 0){throw 'CAT_PDF_REVIEW_NO_PLACEMENT_TARGETS'}
    $universeHash=Get-YakuCatSourceIntegrityHash -Text (@($coverage|ForEach-Object{[string]$_.coverage_item_id}|Sort-Object)-join '|');foreach($item in @($coverage.ToArray())){$item.target_universe_hash=$universeHash}
    $run=[pscustomobject]@{review_run_id=$runId;contract_version='pdf-text-presence-v2';detector='pdfjs-deterministic';dependency_fingerprint=$dependency;document_dependency_fingerprint=$documentDependency;render_id=$RenderId;pdf_sha256=$PdfSha256;extractor_contract=$ExtractorContract;started_at=(Get-Date).ToString('o');completed_at=(Get-Date).ToString('o');status='completed';target_universe_hash=$universeHash;coverage_items=@($coverage.ToArray());coverage_summary=(Get-YakuCatReviewCoverageSummary -Items @($coverage.ToArray()));finding_ids=@($findings.ToArray()|ForEach-Object{[string]$_.finding_id})}
    $other=@($Project.DocumentFindings|Where-Object{[string]$_.detector_contract_version -ne 'pdfjs-text-presence-v2' -or [string]$_.dependency_fingerprint -ne $dependency})
    foreach($old in @($Project.DocumentFindings|Where-Object{[string]$_.detector_contract_version -eq 'pdfjs-text-presence-v2' -and [string]$_.dependency_fingerprint -ne $dependency -and [string]$_.status -ne 'stale'})){$old.status='stale'}
    $Project.DocumentFindings=@($other+@($findings.ToArray()));$allRuns=@($Project.ReviewRuns)+@($run);$Project.ReviewRuns=@($allRuns|Select-Object -Last 20)
    return $run
}

function Set-YakuCatReviewCoverageDecision {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][string]$ReviewRunId,[Parameter(Mandatory=$true)][string[]]$CoverageItemIds,[Parameter(Mandatory=$true)][string]$Note)
    $noteText=([string]$Note).Trim();if([string]::IsNullOrWhiteSpace($noteText)){throw 'CAT_COVERAGE_DECISION_NOTE_REQUIRED'}
    $run=@($Project.ReviewRuns|Where-Object{[string]$_.review_run_id -eq $ReviewRunId}|Select-Object -First 1);if($run.Count -ne 1){throw 'CAT_COVERAGE_RUN_NOT_FOUND'}
    $ids=@($CoverageItemIds|Select-Object -Unique);if($ids.Count -eq 0){throw 'CAT_COVERAGE_DECISION_TARGET_REQUIRED'}
    $events=New-Object System.Collections.Generic.List[string]
    foreach($id in $ids){
        $item=@($run[0].coverage_items|Where-Object{[string]$_.coverage_item_id -eq $id}|Select-Object -First 1);if($item.Count -ne 1 -or [string]$item[0].state -notin @('unreadable','unmapped','skipped')){throw 'CAT_COVERAGE_DECISION_TARGET_INVALID'}
        $decisionScope=$(if([string]$item[0].scope -eq 'render'){'render'}else{'document'})
        $event=Add-YakuCatHumanDecisionEvent -Project $Project -Scope $decisionScope -Action $(if($decisionScope -eq 'render'){'human_visual_reviewed'}else{'human_coverage_reviewed'}) -ReasonCode $(if($decisionScope -eq 'render'){'user_checked_pdf'}else{'user_checked_uncovered_scope'}) -DependencyFingerprint ([string]$item[0].dependency_fingerprint) -CoverageItemId $id
        $item[0].human_decision_current=$true;$item[0]|Add-Member -NotePropertyName human_decision_event_id -NotePropertyValue $event -Force;$item[0]|Add-Member -NotePropertyName human_decision_note -NotePropertyValue $noteText -Force;$events.Add($event)|Out-Null
    }
    $run[0].coverage_summary=Get-YakuCatReviewCoverageSummary -Items @($run[0].coverage_items)
    return [pscustomobject]@{review_run_id=$ReviewRunId;event_ids=@($events.ToArray());coverage_summary=$run[0].coverage_summary}
}

function New-YakuCatFinalReviewDecision {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [ValidateSet('copied_text','draft_docx','draft_xlsx','draft_xlsm','draft_csv')][string]$ArtifactKind,
        [string]$ArtifactPath='',
        [AllowNull()][string]$ArtifactText,
        [string]$RenderId='',
        [Parameter(Mandatory=$true)][string]$Reason,
        [switch]$AcknowledgeUnresolved
    )
    $null=Initialize-YakuCatProjectState -Project $Project
    $null=Sync-YakuCatPlacementPlans -Project $Project
    $reasonText=([string]$Reason).Trim();if([string]::IsNullOrWhiteSpace($reasonText)){throw 'CAT_FINAL_REVIEW_REASON_REQUIRED'}
    $canonicalHash=Get-YakuCatCanonicalTranslationSetHash -Project $Project
    $publicationHash=Get-YakuCatPublicationTranslationSetHash -Project $Project
    $dependency=Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project
    $runs=@(Get-YakuCatCurrentReviewRunsForFinalDecision -Project $Project)
    if($runs.Count -eq 0){throw 'CAT_FINAL_REVIEW_RUN_REQUIRED'}
    $requiredProfile=Get-YakuCatRequiredReviewProfileStatus -Project $Project -Runs $runs -RenderId $RenderId
    if(-not [bool]$requiredProfile.complete){throw ('CAT_FINAL_REVIEW_PROFILE_INCOMPLETE: '+(@($requiredProfile.missing)-join ','))}
    $enumerationComplete=(@($runs|Where-Object{-not [bool]$_.coverage_summary.enumeration_complete}).Count -eq 0)
    $evidenceComplete=(@($runs|Where-Object{-not [bool]$_.coverage_summary.evidence_complete}).Count -eq 0)
    $decisionComplete=(@($runs|Where-Object{-not [bool]$_.coverage_summary.decision_complete}).Count -eq 0)
    if(-not $enumerationComplete -or -not $decisionComplete){throw 'CAT_FINAL_REVIEW_COVERAGE_INCOMPLETE'}
    $currentFindings=@($Project.DocumentFindings|Where-Object{[string]$_.dependency_fingerprint -eq $dependency -and [string]$_.status -ne 'stale'})
    $unresolved=@($currentFindings|Where-Object{[string]$_.status -in @('open','fixed_pending_verify','deferred')})
    if($unresolved.Count -gt 0 -and -not $AcknowledgeUnresolved){throw 'CAT_FINAL_REVIEW_UNRESOLVED_ACK_REQUIRED'}
    $waivers=@($currentFindings|Where-Object{[string]$_.status -in @('false_positive','accepted_risk') -and -not [string]::IsNullOrWhiteSpace([string]$_.disposition_event_id)}|ForEach-Object{[string]$_.disposition_event_id}|Select-Object -Unique)
    $artifacts=New-Object System.Collections.Generic.List[object]
    if($ArtifactKind -eq 'copied_text'){
        $text=$(if($PSBoundParameters.ContainsKey('ArtifactText')){[string]$ArtifactText}else{Get-YakuCatTextOutput -Project $Project})
        $expected=Get-YakuCatTextOutput -Project $Project;if($text -cne $expected){throw 'CAT_FINAL_REVIEW_ARTIFACT_STALE'}
        $artifacts.Add([pscustomobject]@{artifact_kind='copied_text';sha256=(Get-YakuCatSourceIntegrityHash -Text $text);source_generation_id='';role='deliverable';path='';render_id=''})|Out-Null
    }else{
        if([string]::IsNullOrWhiteSpace($ArtifactPath) -or -not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)){throw 'CAT_FINAL_REVIEW_ARTIFACT_MISSING'}
        $expectedExtension=@{draft_docx='.docx';draft_xlsx='.xlsx';draft_xlsm='.xlsm';draft_csv='.csv'}[$ArtifactKind]
        if([IO.Path]::GetExtension($ArtifactPath) -ine $expectedExtension){throw 'CAT_FINAL_REVIEW_ARTIFACT_KIND_MISMATCH'}
        $artifacts.Add([pscustomobject]@{artifact_kind=$expectedExtension.TrimStart('.');sha256=(Get-YakuFileSha256Hex -Path $ArtifactPath);source_generation_id='';role='deliverable';path=[IO.Path]::GetFullPath($ArtifactPath);render_id=''})|Out-Null
    }
    $finalPdfHash='';$renderProfileHash='';$renderReviewed=$false
    if(-not [string]::IsNullOrWhiteSpace($RenderId)){
        $resolved=Resolve-YakuCatRenderPdf -ProjectId ([string]$Project.Id) -RenderId $RenderId;$manifest=$resolved.Manifest
        if([string]$manifest.source_snapshot_id -ne [string]$Project.ActiveSourceId -or [string]$manifest.input_fingerprint -ne (Get-YakuCatRenderInputFingerprint -Project $Project)){throw 'CAT_FINAL_REVIEW_RENDER_STALE'}
        $finalPdfHash=[string]$manifest.canonical_pdf_sha256;$renderProfileHash=[string]$manifest.expected_print_fingerprint
        $deliverable=@($artifacts|Where-Object{[string]$_.role -eq 'deliverable'}|Select-Object -First 1)
        if($ArtifactKind -in @('draft_xlsx','draft_xlsm') -and ($deliverable.Count -ne 1 -or [string]$deliverable[0].sha256 -ne [string]$manifest.output_xlsx_sha256)){throw 'CAT_FINAL_REVIEW_RENDER_ARTIFACT_MISMATCH'}
        $artifacts.Add([pscustomobject]@{artifact_kind='pdf';sha256=$finalPdfHash;source_generation_id='';role='review_evidence';path=[string]$resolved.Path;render_id=$RenderId})|Out-Null
        $pdfRuns=@($runs|Where-Object{[string]$(try{$_.render_id}catch{''}) -eq $RenderId}|Select-Object -Last 1)
        $visualItems=@();if($pdfRuns.Count -eq 1){$visualItems=@($pdfRuns[0].coverage_items|Where-Object{[string]$_.scope -eq 'render'})}
        $visualReviewed=($visualItems.Count -gt 0)
        foreach($visualItem in $visualItems){if(-not [bool]$visualItem.human_decision_current -or [string]::IsNullOrWhiteSpace([string]$visualItem.human_decision_event_id)){$visualReviewed=$false;break}}
        $renderReviewed=([string]$manifest.print_conformance_status -in @('verified','unverified') -and $pdfRuns.Count -eq 1 -and [bool]$pdfRuns[0].coverage_summary.decision_complete -and $visualReviewed)
    }
    $artifactDigest=Get-YakuCatSourceIntegrityHash -Text (@($artifacts|ForEach-Object{[string]$_.artifact_kind+':'+[string]$_.sha256+':'+[string]$_.role}|Sort-Object)-join '|')
    $reviewDecisionSetHash=Get-YakuCatReviewDecisionSetHash -Project $Project -Runs $runs
    $finalDependency=Get-YakuCatSourceIntegrityHash -Text ('final-review-v2|'+$dependency+'|'+$canonicalHash+'|'+$publicationHash+'|'+[string]$Project.PlacementSetHash+'|'+$artifactDigest+'|'+$reviewDecisionSetHash+'|'+$reasonText)
    $eventId=Add-YakuCatHumanDecisionEvent -Project $Project -Scope final -Action final_review_acknowledged -ReasonCode user_reviewed_output -DependencyFingerprint $finalDependency
    $decision=[pscustomobject]@{
        event_id=$eventId;artifact_kind=$ArtifactKind;project_revision=[int]$Project.Revision+1;source_snapshot_id=[string]$Project.ActiveSourceId;source_generation_id=''
        canonical_set_hash=$canonicalHash;publication_set_hash=$publicationHash;placement_set_hash=[string]$Project.PlacementSetHash;document_review_dependency_fingerprint=$dependency
        final_artifacts=@($artifacts.ToArray());final_pdf_sha256=$finalPdfHash;render_profile_hash=$renderProfileHash;final_render_owner=$(if($RenderId){'local_excel'}else{''});render_reviewed=$renderReviewed
        review_run_ids=@($runs|ForEach-Object{[string]$_.review_run_id});unresolved_finding_ids=@($unresolved|ForEach-Object{[string]$_.finding_id});waiver_event_ids=$waivers
        required_review_profile_hash=[string]$requiredProfile.profile_hash
        review_decision_set_hash=$reviewDecisionSetHash
        coverage_enumeration_complete=$enumerationComplete;coverage_evidence_complete=$evidenceComplete;coverage_decision_complete=$decisionComplete
        unreadable_decision_ids=@();skipped_decision_ids=@();actor_label='local-user';reason=$reasonText;occurred_at=(Get-Date).ToString('o');dependency_fingerprint=$finalDependency
    }
    $all=@($Project.FinalReviewDecisions)+@($decision);$Project.FinalReviewDecisions=@($all|Select-Object -Last 20)
    return $decision
}

function Get-YakuCatFinalReviewDecisionStatus {
    param([Parameter(Mandatory=$true)]$Project,[AllowNull()]$Decision)
    if($null -eq $Decision){return [pscustomobject]@{status='none';reasons=@('not_recorded')}}
    $reasons=New-Object System.Collections.Generic.List[string]
    if([string]$Decision.source_snapshot_id -ne [string]$Project.ActiveSourceId){$reasons.Add('source_changed')|Out-Null}
    if([string]$Decision.canonical_set_hash -ne (Get-YakuCatCanonicalTranslationSetHash -Project $Project)){$reasons.Add('translation_changed')|Out-Null}
    if([string]$Decision.publication_set_hash -ne (Get-YakuCatPublicationTranslationSetHash -Project $Project)){$reasons.Add('publication_changed')|Out-Null}
    if([string]$Decision.placement_set_hash -ne [string]$Project.PlacementSetHash){$reasons.Add('placement_changed')|Out-Null}
    if([string]$Decision.document_review_dependency_fingerprint -ne (Get-YakuCatDocumentReviewDependencyFingerprint -Project $Project)){$reasons.Add('review_dependency_changed')|Out-Null}
    if([string]$Decision.review_decision_set_hash -ne (Get-YakuCatReviewDecisionSetHash -Project $Project)){$reasons.Add('review_decisions_changed')|Out-Null}
    $currentRuns=@(Get-YakuCatCurrentReviewRunsForFinalDecision -Project $Project)
    $decisionRenderId=''
    try{$decisionRenderId=[string]@($Decision.final_artifacts|Where-Object{[string]$_.artifact_kind -eq 'pdf'}|Select-Object -Last 1).render_id}catch{}
    $currentRequiredProfile=Get-YakuCatRequiredReviewProfileStatus -Project $Project -Runs $currentRuns -RenderId $decisionRenderId
    if([string]$Decision.required_review_profile_hash -ne [string]$currentRequiredProfile.profile_hash){$reasons.Add('required_review_profile_changed')|Out-Null}
    foreach($artifact in @($Decision.final_artifacts|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_.path)})){
        if(-not (Test-Path -LiteralPath ([string]$artifact.path) -PathType Leaf)){$reasons.Add('artifact_missing')|Out-Null;continue}
        if((Get-YakuFileSha256Hex -Path ([string]$artifact.path)) -ne [string]$artifact.sha256){$reasons.Add('artifact_changed')|Out-Null}
    }
    return [pscustomobject]@{status=$(if($reasons.Count -eq 0){'current'}else{'stale'});reasons=@($reasons.ToArray());decision=$Decision}
}
