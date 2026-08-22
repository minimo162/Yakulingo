<# V91.70: 文書全体finding、coverage、人の処理、世代保存の回帰テスト。 #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$script:fail=0
foreach($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','BriefStyle.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','CatProject.ps1','VersionUpdate.ps1','SourceRebase.ps1','Review.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
function Chk{param([bool]$Condition,[string]$Message)if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:fail++}}

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('yaku-review-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-Item -ItemType Directory -Path $tempRoot -Force
$previousDataDir=$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR=Join-Path $tempRoot 'data'
$script:YakuReviewStore=Join-Path $tempRoot 'cat-store'
function Get-YakuCatProjectStoreDir{return $script:YakuReviewStore}
try{
    $settings=Read-YakuSettings -Root $root
    $project=New-YakuCatTextProject -Root $root -Text "売上高は123,456,789百万円`n注記`n売上高は123,456,789百万円" -Settings $settings -Direction 'to_en' -Register:$false
    $project.Segments[0].Translation='Net sales were 123,456,789 million yen.'
    $project.Segments[1].Translation='Note'
    $project.Segments[2].Translation='Revenue was 123,456,789 million yen.'
    $protectedRequest=New-YakuCatProtectedDocumentReviewRequest -Root $root -Project $project
    Chk ([string]$protectedRequest.Envelope.ContractVersion -eq 'protected-prompt-v2' -and [string]$protectedRequest.Envelope.Prompt -match 'document-review-copilot-v2') '文書校正を専用review kindと固定builderからだけ構築する'
    Chk (-not ([string]$protectedRequest.Envelope.Prompt).Contains('123,456,789') -and [string]$protectedRequest.Envelope.Prompt -match '\[\[N\d+\]\]') 'sourceとtargetを含む校正sidecarを送信前に数値マスクする'
    Chk ([string]$protectedRequest.Envelope.Prompt -match 'no PDF was provided' -and [string]$protectedRequest.Envelope.Prompt -notmatch 'pdf_base64|pdf_path') '原本PDFを添付せず、PDF体裁をAI根拠にしない'
    $firstProtected=$protectedRequest.ProtectedRecords[0];$thirdProtected=$protectedRequest.ProtectedRecords[2]
    $allAliases=@($protectedRequest.ProtectedRecords|ForEach-Object{[string]$_.segment_alias})
    $responsePayload=[ordered]@{contract='document-review-copilot-v2';request_id=[string]$protectedRequest.RequestId;findings=@([ordered]@{
        category='translation_consistency';severity='warning';title='訳語の揺れ';message='同じ語の訳が異なります。';evidence_quality='clear';evidence_confidence=0.9;suggestions=@('統一を確認する')
        evidence=@(
            [ordered]@{segment_alias=[string]$firstProtected.segment_alias;source_quote=[string]$firstProtected.source;target_quote=[string]$firstProtected.target},
            [ordered]@{segment_alias=[string]$thirdProtected.segment_alias;source_quote=[string]$thirdProtected.source;target_quote=[string]$thirdProtected.target}
        )
    });lens_coverage=@('bilingual_block','names_terms_abbreviations','translation_consistency','target_document_consistency','structure_notes','gap'|ForEach-Object{[ordered]@{lens=$_;checked_segment_aliases=$allAliases}})}
    $response="REVIEW_JSON:`n"+($responsePayload|ConvertTo-Json -Depth 8 -Compress)+"`nYAKULINGO_END:"+[string]$protectedRequest.RequestId
    $parsed=ConvertFrom-YakuDocumentReviewResponse -Response $response -Request $protectedRequest
    Chk (@($parsed.Findings).Count -eq 1 -and @($parsed.Findings[0].evidence).Count -eq 2 -and @($parsed.LensCoverage).Count -eq 6) 'AI応答はschema・実在引用・観点別coverageを検証してから採用する'
    $markerlessParsed=ConvertFrom-YakuDocumentReviewResponse -Response ("REVIEW_JSON:`n"+($responsePayload|ConvertTo-Json -Depth 8 -Compress)) -Request $protectedRequest
    Chk (@($markerlessParsed.Findings).Count -eq 1) '末尾markerがなくてもJSON内request_idが一致する校正応答を採用できる'
    $projectedParsed=ConvertFrom-YakuDocumentReviewResponse -Response ($responsePayload|ConvertTo-Json -Depth 8 -Compress) -Request $protectedRequest
    Chk (@($projectedParsed.Findings).Count -eq 1) '回答監視が抽出した純JSONを同じrequest_id契約で解析する'
    $wrongRequest=$responsePayload|ConvertTo-Json -Depth 8|ConvertFrom-Json;$wrongRequest.request_id=('f'*32)
    $wrongRequestBlocked=$false;try{$null=ConvertFrom-YakuDocumentReviewResponse -Response ("REVIEW_JSON:`n"+($wrongRequest|ConvertTo-Json -Depth 8 -Compress)) -Request $protectedRequest}catch{$wrongRequestBlocked=$_.Exception.Message -match 'CAT_REVIEW_RESPONSE_REQUEST_ID_MISMATCH'}
    Chk $wrongRequestBlocked '別requestの校正JSONを採用しない'
    $copilotRun=Apply-YakuCatCopilotDocumentReviewResult -Project $project -Request $protectedRequest -ParsedResult $parsed
    Chk (@($copilotRun.coverage_items).Count -eq 14 -and @($copilotRun.coverage_items|Where-Object{$_.state -eq 'finding'}).Count -eq 1 -and @($copilotRun.coverage_items|Where-Object{$_.state -eq 'checked'}).Count -eq 13) 'AI校正をscope・lens・対象segmentごとのcoverageへ投影する'
    Chk (@($project.DocumentFindings).Count -eq 1 -and [string]$project.DocumentFindings[0].detector -eq 'copilot' -and [string]$project.DocumentFindings[0].evidence_locations[0].quote -match '123,456,789') '引用のマスクを復元し現在の原文・訳文へ再照合してからfindingを保存する'
    $project.DocumentFindings=@();$project.ReviewRuns=@()
    $packet=(ConvertTo-YakuSanitizedDocumentReviewPacket -Request $protectedRequest -ParsedResult $parsed)|ConvertTo-Json -Depth 12|ConvertFrom-Json
    $batchRun=Apply-YakuCatCopilotDocumentReviewPackets -Project $project -Packets @($packet) -SourceJobId ('9'*32)
    Chk ([string]$batchRun.detector -eq 'copilot' -and [string]$batchRun.source_job_id -eq ('9'*32) -and @($batchRun.coverage_items).Count -eq 14) 'AI結果をscope・lens母集団付きの1つのReviewRunへ統合する'
    $packetJson=$packet|ConvertTo-Json -Depth 12 -Compress
    Chk ($packetJson -notmatch 'protected_sidecar|numeric_mask_map|protected_records' -and $packetJson -match '"sanitized":true') 'job完了結果へplaceholder辞書・masked sidecarを残さない'
    $longText=@(0..20|ForEach-Object{if($_ -in @(0,20)){'共通見出し'}elseif($_ -in @(5,19)){"製品Alphaの本文 $_"}else{"本文 $_"}})-join "`n"
    $longProject=New-YakuCatTextProject -Root $root -Text $longText -Settings $settings -Direction 'to_en' -Register:$false
    foreach($segment in @($longProject.Segments)){$segment.Translation='Target '+[string]$segment.Text}
    $longProject.DocumentIndexSnapshot=New-YakuCatDocumentIndexSnapshot -Project $longProject
    $longPackets=New-Object System.Collections.Generic.List[object]
    foreach($indices in @(@(0..19),@(20))){
        $request=New-YakuCatProtectedDocumentReviewRequest -Root $root -Project $longProject -SegmentIndices $indices -ReviewPurpose local
        $aliases=@($request.AliasToSegmentId.Keys);$localParsed=[pscustomobject]@{ContractVersion='document-review-copilot-v2';Findings=@();LensCoverage=@('bilingual_block','names_terms_abbreviations','structure_notes','gap'|ForEach-Object{[pscustomobject]@{lens=$_;checked_aliases=$aliases}})}
        $longPackets.Add(((ConvertTo-YakuSanitizedDocumentReviewPacket -Request $request -ParsedResult $localParsed)|ConvertTo-Json -Depth 12|ConvertFrom-Json))|Out-Null
    }
    foreach($group in @($longProject.DocumentIndexSnapshot.groups)){
        if($group.PSObject.Properties.Name -contains 'automated' -and -not [bool]$group.automated){continue}
        $request=New-YakuCatProtectedDocumentReviewRequest -Root $root -Project $longProject -SegmentIndices @($group.segment_indices) -ReviewPurpose document_index -IndexLens ([string]$group.lens) -IndexGroupId ([string]$group.group_id)
        $indexParsed=[pscustomobject]@{ContractVersion='document-review-copilot-v2';Findings=@();LensCoverage=@([pscustomobject]@{lens=[string]$group.lens;checked_aliases=@($request.AliasToSegmentId.Keys)})}
        $longPackets.Add(((ConvertTo-YakuSanitizedDocumentReviewPacket -Request $request -ParsedResult $indexParsed)|ConvertTo-Json -Depth 12|ConvertFrom-Json))|Out-Null
    }
    $longRun=Apply-YakuCatCopilotDocumentReviewPackets -Project $longProject -Packets @($longPackets.ToArray())
    $indexedCoverage=@($longRun.coverage_items|Where-Object{[string]$_.scope -eq 'document'})
    Chk (@($longProject.DocumentIndexSnapshot.occurrences).Count -eq 21 -and @($longProject.DocumentIndexSnapshot.groups).Count -eq $indexedCoverage.Count -and [bool]$longRun.coverage_summary.enumeration_complete -and -not [bool]$longRun.coverage_summary.evidence_complete -and @($indexedCoverage|Where-Object{[string]$_.target_kind -eq 'whole_document_cross_group' -and [string]$_.state -eq 'skipped'}).Count -eq 1) '21行を超える文書は索引groupを列挙し、request間の未比較範囲を自動完了にしない'
    Chk (@($longProject.DocumentIndexSnapshot.groups|Where-Object{[string]$_.lens -eq 'translation_consistency' -and [string]$_.kind -eq 'repeated_source' -and @($_.segment_ids).Count -eq 2}).Count -eq 1) '別requestに離れた同一原文を一つの比較groupへ列挙する'
    Chk (@($longProject.DocumentIndexSnapshot.groups|Where-Object{[string]$_.kind -eq 'source_term_occurrences' -and @($_.segment_ids).Count -ge 2}).Count -ge 1) '異なる文中で繰り返す固有名詞・用語候補もrequest横断groupへ列挙する'
    $tamperedIndex=$longProject.DocumentIndexSnapshot|ConvertTo-Json -Depth 10|ConvertFrom-Json;$tamperedIndex.groups=@($tamperedIndex.groups|Select-Object -Skip 1);$tamperedBlocked=$false
    try{$null=Assert-YakuCatDocumentIndexSnapshot -Project $longProject -Snapshot $tamperedIndex}catch{$tamperedBlocked=$_.Exception.Message -eq 'CAT_REVIEW_DOCUMENT_INDEX_INTEGRITY_FAILED'}
    Chk $tamperedBlocked 'DocumentIndexのgroupを欠落させたjob・保存結果をhash再検証で拒否する'
    $project.DocumentFindings=@();$project.ReviewRuns=@()
    $badPayload=$responsePayload|ConvertTo-Json -Depth 8|ConvertFrom-Json;$badPayload.findings[0].category='rendered_output_completeness'
    $badResponse="REVIEW_JSON:`n"+($badPayload|ConvertTo-Json -Depth 8 -Compress)+"`nYAKULINGO_END:"+[string]$protectedRequest.RequestId
    $visualClaimBlocked=$false;try{$null=ConvertFrom-YakuDocumentReviewResponse -Response $badResponse -Request $protectedRequest}catch{$visualClaimBlocked=$_.Exception.Message -match 'CAT_REVIEW_RESPONSE_FINDING_INVALID'}
    Chk $visualClaimBlocked 'AI応答schemaでもPDF掲載完全性の視覚主張を拒否する'
    $lowConfidence=$responsePayload|ConvertTo-Json -Depth 8|ConvertFrom-Json;$lowConfidence.findings[0].evidence_confidence=0.5
    $lowResponse="REVIEW_JSON:`n"+($lowConfidence|ConvertTo-Json -Depth 8 -Compress)+"`nYAKULINGO_END:"+[string]$protectedRequest.RequestId
    $lowBlocked=$false;try{$null=ConvertFrom-YakuDocumentReviewResponse -Response $lowResponse -Request $protectedRequest}catch{$lowBlocked=$_.Exception.Message -match 'CAT_REVIEW_RESPONSE_FINDING_INVALID'}
    Chk $lowBlocked '根拠が明瞭でconfidence 0.75未満のAI findingを採用しない'
    $run=Invoke-YakuCatDeterministicDocumentReview -Project $project
    Chk ([string]$run.status -eq 'completed' -and [bool]$run.coverage_summary.enumeration_complete) '対象母集団を列挙しcoverage完了とfinding 0件を分離する'
    Chk (@($project.DocumentFindings).Count -eq 1 -and [string]$project.DocumentFindings[0].category -eq 'translation_consistency') '同じ原文の異なる訳を文書全体findingにする'
    Chk (@($project.DocumentFindings[0].evidence_locations).Count -eq 4) '文書横断findingは原文・訳文の複数根拠位置を持つ'
    Chk (@($run.coverage_items|Where-Object{$_.state -eq 'finding' -and $_.finding_ids.Count -eq 1}).Count -eq 1) 'coverage itemをfindingへ安定IDで対応付ける'
    $blocked=$false;try{$null=New-YakuCatDocumentFinding -Scope 'render' -Category 'rendered_output_completeness' -Detector 'copilot' -DetectorContractVersion 'bad-v1' -Severity 'warning' -Title x -Message x -EvidenceLocations @() -DependencyFingerprint x}catch{$blocked=$_.Exception.Message -match 'CAT_REVIEW_RENDER_FINDING_DETECTOR_INVALID'}
    Chk $blocked 'Copilotが見ていないPDF体裁findingを作る契約を拒否する'
    $reasonBlocked=$false;try{$null=Set-YakuCatDocumentFindingDecision -Project $project -FindingId ([string]$project.DocumentFindings[0].finding_id) -FindingRevision 1 -Action accepted_risk}catch{$reasonBlocked=$_.Exception.Message -match 'CAT_FINDING_REASON_REQUIRED'}
    Chk $reasonBlocked 'リスク許容は理由なしで通さない'
    $decision=Set-YakuCatDocumentFindingDecision -Project $project -FindingId ([string]$project.DocumentFindings[0].finding_id) -FindingRevision 1 -Action false_positive -ReasonCode context_specific -Note '表見出しが異なるため訳し分ける'
    Chk ([string]$decision.status -eq 'false_positive' -and @($project.ReviewEvents|Where-Object{[string]$_.finding_id -eq [string]$decision.finding_id}).Count -eq 1) 'finding処理をrevision・fingerprint付きHumanDecisionへ束縛する'
    $null=Invoke-YakuCatDeterministicDocumentReview -Project $project
    Chk ([string]$project.DocumentFindings[0].status -eq 'false_positive') '依存とfinding fingerprintが同じ再検査では人の判断を維持する'
    $null=Commit-YakuNewCatProject -Project $project
    $manifest=Get-Content -LiteralPath (Join-Path (Join-Path $script:YakuReviewStore ([string]$project.Id)) 'project.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $generation=Join-Path (Join-Path (Join-Path $script:YakuReviewStore ([string]$project.Id)) 'generations') ([string]$manifest.generation_id)
    Chk ((Test-Path -LiteralPath (Join-Path $generation 'document-findings.jsonl')) -and (Test-Path -LiteralPath (Join-Path $generation 'review-runs.jsonl'))) 'findingとReviewRunを同じcommit generationへ保存する'
    $restored=Restore-YakuCatProject -Id ([string]$project.Id)
    Chk (@($restored.DocumentFindings).Count -eq 1 -and @($restored.ReviewRuns).Count -eq 2 -and [string]$restored.DocumentFindings[0].status -eq 'false_positive' -and [string]$restored.DocumentIndexSnapshot.snapshot_hash -match '^[a-f0-9]{64}$') '再起動後も索引・finding・coverage・人の判断を整合して復元する'
    $serverText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
    $clientText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www\assets') 'cat.js') -Raw -Encoding UTF8
    $pageText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'cat.html') -Raw -Encoding UTF8
    Chk ($serverText -match "'review-start'" -and $serverText -match "'copilot-review-preview'" -and $serverText -match "'copilot-review-start'" -and $serverText -match "'copilot-review-apply'" -and $serverText -match "'finding-decision'") '決定論review・保護済み送信preview・Copilot job・人の判断APIを公開する'
    # V91.61（2026-08-14）: 送信ループを Review.ps1 側へ戻した。伏せる関数と送る
    # 関数が別ファイルだと、数値マスクの統制（Test-YakuV9160NumericMasking.ps1
    # §10-21）が経路を名指しできない。見張る条件は同じまま、見る場所だけを
    # 実装のある側へ移し、ジョブ側が委譲していることを1つ足す。
    $reviewText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Review.ps1') -Raw -Encoding UTF8
    Chk ($serverText -match "catMode -eq 'document_review'" -and $serverText -match 'Invoke-YakuCatDocumentReviewRequests' -and $reviewText -match 'SkipFreshChatWait:\(\$requestNumber -gt 1\)' -and $reviewText -match 'copilotPromptCharLimit') '複数校正batchでチャット準備と入力上限を制御する'
    $copilotText=Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CopilotClient.ps1') -Raw -Encoding UTF8
    Chk ($copilotText -match 'fresh chat retry discarded an unresponsive CDP socket' -and $copilotText -match 'Remove-YakuCdpCachedSocket') '新しいチャット操作のCDP timeoutは同じ故障ソケットを再利用しない'
    Chk ($copilotText -match "obj\.contract === 'document-review-copilot-v2'" -and $copilotText -match 'obj\.request_id === requestId' -and $copilotText -match 'REVIEW_JSON') '回答監視が校正JSONをrequest固有IDへ束縛する'
    Chk ($clientText -match 'runDocumentReview' -and $clientText -match 'runCopilotDocumentReview' -and $clientText -match 'decideDocumentFinding' -and $pageText -match 'Copilotで意味と一貫性を確認') 'CATの点検一覧から文書全体findingを確認・処理できる'
    Chk ($clientText -match 'previewCopilotDocumentReview' -and $pageText -match 'Copilotへ送る内容を確認' -and $serverText -match "PDFや原本ファイルは送信しません") '数値を伏せた実送信promptと残る本文の境界を送信前に表示する'
    Chk ($clientText -match 'この指摘は当てはまらない' -and $clientText -match "reason_code: action === 'false_positive' \? 'not_applicable'") 'false positiveを全カテゴリで意図した訳し分けと誤表示しない'
    Chk ($serverText -match "'qa-report'" -and $clientText -match 'downloadQaReport' -and $pageText -match 'QAレポートを保存' -and $pageText -match 'cat-document-finding-search') '確認範囲・指摘・人の判断を検索しQAレポートとして持ち出せる'
    Chk ($clientText -match '文書全体.*targetCount.*行' -and $clientText -match "project\.direction === 'to_jp'.*日本語訳文としての整合性") '長文書の人確認範囲と現在の翻訳方向を描画時に正しく表示する'
    Chk ($clientText -match '訳文セルを押すと、セル配置の調整' -and $clientText -match '情報を保って短くする候補') 'Excelの配置と収容候補への入口をhoverなしで説明する'
}finally{
    $env:YAKULINGO_DATA_DIR=$previousDataDir
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if($script:fail){throw ($script:fail.ToString()+' review checks failed')}
Write-Host 'Document review checks passed.' -ForegroundColor Green
