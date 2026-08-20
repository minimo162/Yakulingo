# Fit-first policy overrides.
#
# 同じ原文が複数セルに現れる場合も「同じ原文には同じ訳」を保つため、
# 1つの訳へ畳む。そのとき幅を測れたセルが1つでもあれば、測定済みbudgetの
# 最小値を採る。幅不明セルは制約が無いので、測定済みセルの制約を無効化しない。
# これにより、狭い既知セルを守りつつ、同じ訳を幅不明セルにも安全に再利用する。
function Resolve-YakuCatFitTargetForDuplicates {
    param([AllowNull()][object[]]$MaxCharsValues)
    $resolved = $null
    foreach ($value in @($MaxCharsValues)) {
        if ($null -eq $value) { continue }
        $intValue = -1
        try { $intValue = [int]$value } catch { continue }
        if ($intValue -lt 8 -or $intValue -gt 99) { continue }
        if ($null -eq $resolved -or $intValue -lt $resolved) { $resolved = $intValue }
    }
    return $resolved
}
