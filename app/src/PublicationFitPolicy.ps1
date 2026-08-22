# Fit-first publication policy.
#
# 「収める候補」に並ぶものは、その場で実際に採用判断まで進めるものだけにする。
# Publication.ps1 は候補ごとに fit_verification_status と deterministic_qc_status を
# 付け、採用時には estimated_overflow と QC failed の両方を拒否する。
# そのため、どちらかで失格だと既に分かっている候補を候補一覧へ残すと、
# 「収める候補」に出たのに採用できないという fit-first の約束とのずれが生じる。
#
# 失格候補は捨てず rejected_candidate_diagnostics に残す。画面の主候補一覧は
# 採用可能なものだけにし、診断・テスト・将来の改善分析では失敗理由を追えるようにする。
# これは実ピクセル幅の最終保証ではない。採用後のブラウザ側の実幅判定が最終判定で、
# はみ出せば再び fit risk になる。まずサーバ側で既知の失格候補を確実に分離する。

function Split-YakuCatFitPublicationCandidates {
    param([AllowNull()][object[]]$Candidates)

    $accepted = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[object]
    $overflowCount = 0
    $qcRejectedCount = 0

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        if ([string]$candidate.fit_verification_status -eq 'estimated_overflow') {
            $overflowCount++
            [void]$rejected.Add($candidate)
            continue
        }
        if ([string]$candidate.deterministic_qc_status -ne 'passed') {
            $qcRejectedCount++
            [void]$rejected.Add($candidate)
            continue
        }
        [void]$accepted.Add($candidate)
    }

    $ordered = @($accepted.ToArray() | Sort-Object @{ Expression = { ([string]$_.text).Length }; Ascending = $true })
    return [pscustomobject]@{
        Accepted = $ordered
        Rejected = @($rejected.ToArray())
        OverflowCount = [int]$overflowCount
        QcRejectedCount = [int]$qcRejectedCount
    }
}

function Select-YakuCatFitSafePublicationCandidates {
    param([AllowNull()][object[]]$Candidates)
    return @((Split-YakuCatFitPublicationCandidates -Candidates $Candidates).Accepted)
}

$script:YakuPublicationCompleteBeforeFitPolicy = ${function:Complete-YakuCatPublicationCandidateSet}
if ($null -eq $script:YakuPublicationCompleteBeforeFitPolicy) {
    throw 'CAT_PUBLICATION_FIT_POLICY_LOAD_ORDER_INVALID'
}

function Complete-YakuCatPublicationCandidateSet {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Request,
        [Parameter(Mandatory=$true)]$Parsed
    )

    $result = & $script:YakuPublicationCompleteBeforeFitPolicy -Project $Project -Request $Request -Parsed $Parsed
    $before = @($result.candidates)
    $split = Split-YakuCatFitPublicationCandidates -Candidates $before
    $after = @($split.Accepted)
    $result.candidates = $after

    # 「候補あり」は、文字budgetと決定論QCの両方を通った候補があるときだけ。
    # 失格候補の中身は診断用に別フィールドへ残す。
    if ($after.Count -eq 0 -and [string]::IsNullOrWhiteSpace([string]$result.cannot_fit_reason)) {
        if ([int]$split.QcRejectedCount -gt 0) {
            $result.cannot_fit_reason = '文字目標内の候補は作れましたが、自動点検を通る候補を作れませんでした。'
        } else {
            $result.cannot_fit_reason = '文字目標内に収まる候補を作れませんでした。'
        }
    }

    $result | Add-Member -NotePropertyName fit_candidate_count -NotePropertyValue ([int]$after.Count) -Force
    $result | Add-Member -NotePropertyName overflow_candidate_count -NotePropertyValue ([int]$split.OverflowCount) -Force
    $result | Add-Member -NotePropertyName qc_rejected_candidate_count -NotePropertyValue ([int]$split.QcRejectedCount) -Force
    $result | Add-Member -NotePropertyName rejected_candidate_diagnostics -NotePropertyValue @($split.Rejected) -Force
    return $result
}
