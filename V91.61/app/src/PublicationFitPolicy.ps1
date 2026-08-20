# Fit-first publication policy.
#
# 「収める候補」に、文字budget超過だと既に判定できた候補を混ぜない。
# Publication.ps1 は候補ごとに fit_verification_status を付け、採用時にも
# estimated_overflow を拒否している。それにもかかわらず、従来は超過候補も
# 候補一覧へ返していたため、「収める候補」に出たのに採用できないという
# fit-first の約束と画面の意味のずれがあった。
#
# deterministic QC の failed 候補は、既存の診断用途を壊さないため残す。
# ただし並び順は QC passed を先、同じ状態なら短い候補を先にする。
# これは実ピクセル幅の最終保証ではない。採用後のブラウザ側の実幅判定が最終判定で、
# はみ出せば再び fit risk になる。まずサーバ側で「収まらないと既に分かる候補」を
# 落とし、次段階の「再測定→再短縮」閉ループへつなぎやすい契約にする。

function Select-YakuCatFitSafePublicationCandidates {
    param([AllowNull()][object[]]$Candidates)

    $accepted = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        if ([string]$candidate.fit_verification_status -eq 'estimated_overflow') { continue }
        [void]$accepted.Add($candidate)
    }

    return @($accepted.ToArray() | Sort-Object `
        @{ Expression = { if ([string]$_.deterministic_qc_status -eq 'passed') { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = { ([string]$_.text).Length }; Ascending = $true })
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
    $after = @(Select-YakuCatFitSafePublicationCandidates -Candidates $before)
    $result.candidates = $after

    # モデルが候補を返していても、既知の文字budgetを通るものが0件なら
    # 「候補あり」とは扱わない。元の cannot_fit_reason があれば尊重する。
    if ($after.Count -eq 0 -and [string]::IsNullOrWhiteSpace([string]$result.cannot_fit_reason)) {
        $result.cannot_fit_reason = '文字目標内に収まる候補を作れませんでした。'
    }

    $passedCount = @($after | Where-Object { [string]$_.deterministic_qc_status -eq 'passed' }).Count
    $result | Add-Member -NotePropertyName fit_candidate_count -NotePropertyValue ([int]$passedCount) -Force
    $result | Add-Member -NotePropertyName overflow_candidate_count -NotePropertyValue ([int]($before.Count - $after.Count)) -Force
    return $result
}
