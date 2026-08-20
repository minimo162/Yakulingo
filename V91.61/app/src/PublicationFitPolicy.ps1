# Fit-first publication policy.
#
# 「収める候補」は、生成された候補を全部見せる場所ではない。
# Publication.ps1 は候補ごとに deterministic_qc_status と
# fit_verification_status を付け、採用時には QC failed / estimated_overflow を
# 拒否している。それにもかかわらず、従来は拒否される候補も候補一覧へ返していた。
# 利用者から見ると「収める候補」に出たのに採用できないため、fit-first の約束と
# 画面の意味がずれる。
#
# ここでは「既知の文字budgetを通り、自動点検も通った候補」だけを返す。
# これは実ピクセル幅の最終保証ではない。採用後のブラウザ側の実幅判定が最終判定で、
# はみ出せば再び fit risk になる。まずサーバ側で既知の失格候補を落とし、
# 次段階の「再測定→再短縮」閉ループへつなぎやすい契約にする。

function Select-YakuCatFitSafePublicationCandidates {
    param([AllowNull()][object[]]$Candidates)

    $accepted = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        if ([string]$candidate.deterministic_qc_status -ne 'passed') { continue }
        if ([string]$candidate.fit_verification_status -eq 'estimated_overflow') { continue }
        [void]$accepted.Add($candidate)
    }

    # fit-first なので、同じ安全条件なら短いものを先にする。
    return @($accepted.ToArray() | Sort-Object @{ Expression = { ([string]$_.text).Length }; Ascending = $true })
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

    # モデルが候補を返していても、既知budget/QCを通るものが0件なら
    # 「候補あり」とは扱わない。元の cannot_fit_reason があれば尊重する。
    if ($after.Count -eq 0 -and [string]::IsNullOrWhiteSpace([string]$result.cannot_fit_reason)) {
        $result.cannot_fit_reason = '文字目標と自動点検を両方満たす候補を作れませんでした。'
    }

    $result | Add-Member -NotePropertyName fit_candidate_count -NotePropertyValue ([int]$after.Count) -Force
    $result | Add-Member -NotePropertyName rejected_candidate_count -NotePropertyValue ([int]($before.Count - $after.Count)) -Force
    return $result
}
