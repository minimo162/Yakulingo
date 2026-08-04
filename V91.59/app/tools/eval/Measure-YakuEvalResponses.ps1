<#
.SYNOPSIS
  翻訳エンジンの応答を、アプリ本体の検証関数で採点する。

.DESCRIPTION
  Parse-YakuTextTranslationResponse・Test-YakuNumericIntegrity・
  Test-YakuTextStructureIntegrity をそのまま使うため、アプリと同じ基準で測れる。
  これに評価セット固有の必須語・禁止語と、用語集遵守・BRIEF圧縮率を加える。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\eval\Measure-YakuEvalResponses.ps1
#>
[CmdletBinding()]
param(
    [string]$EvalSet = '',
    [string]$ResponseDir = '',
    [string]$PromptDir = '',
    [string]$ReportPath = '',
    [string]$Label = 'baseline',
    [string]$CompareWith = ''
)

$ErrorActionPreference = 'Stop'
$evalRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsRoot = Split-Path -Parent $evalRoot
$appRoot = Split-Path -Parent $toolsRoot
if ([string]::IsNullOrWhiteSpace($EvalSet)) { $EvalSet = Join-Path $evalRoot 'evalset.json' }

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','Translation.ps1')) {
    . (Join-Path (Join-Path $appRoot 'src') $n)
}

# 既定値の解決は dot-source の後（Build-YakuEvalPrompts.ps1 と同じ理由・同じ場所）。
$labelRoot = Join-Path (Get-YakuSubDir 'eval') $Label
if ([string]::IsNullOrWhiteSpace($ResponseDir)) { $ResponseDir = Join-Path $labelRoot 'responses' }
if ([string]::IsNullOrWhiteSpace($PromptDir))   { $PromptDir   = Join-Path $labelRoot 'prompts' }
if ([string]::IsNullOrWhiteSpace($ReportPath))  { $ReportPath  = Join-Path $labelRoot 'report.json' }

$set = [IO.File]::ReadAllText($EvalSet) | ConvertFrom-Json
$settings = Read-YakuSettings -Root $appRoot
$index = @{}
$indexPath = Join-Path $PromptDir '_index.json'
if (Test-Path -LiteralPath $indexPath) {
    foreach ($e in @((([IO.File]::ReadAllText($indexPath)) | ConvertFrom-Json).cases)) { $index[[string]$e.id] = $e }
}

# 出力してはいけない語。oku 固定の方針に反するもの。
$forbiddenGlobal = @('billion','million','trillion',' bn',' tn')

function Get-YakuEvalList {
    # 未定義プロパティは @($null) になるため、空要素を必ず除く。
    param([AllowNull()]$Value)
    return @(@($Value) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
}

function Test-YakuEvalContains {
    param([string]$Text, [string[]]$Needles)
    foreach ($n in @($Needles)) { if ([string]$Text -like ('*' + $n + '*')) { return $true } }
    return $false
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($case in @($set.cases)) {
    $id = [string]$case.id
    $responsePath = Join-Path $ResponseDir ($id + '.response.txt')
    $row = [ordered]@{ id = $id; group = [string]$case.group; origin = [string]$case.origin; focus = [string]$case.focus }

    if (-not (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
        $row['status'] = 'missing-response'
        $rows.Add([pscustomobject]$row) | Out-Null
        continue
    }
    $raw = [IO.File]::ReadAllText($responsePath)
    $requestId = if ($index.ContainsKey($id)) { [string]$index[$id].request_id } else { '' }

    $full = ''; $brief = ''; $contractOk = $false; $contractError = ''
    try {
        $options = @(Parse-YakuTextTranslationResponse -Raw $raw -Direction ([string]$case.direction) -RequestId $requestId)
        if ($options.Count -ge 2) {
            $full = [string]$options[0].Translation
            $brief = [string]$options[1].Translation
            $contractOk = $true
        } else { $contractError = "options=$($options.Count)" }
    } catch { $contractError = ($_.Exception.Message -replace '[\r\n]+',' ') }

    $row['contract_ok'] = $contractOk
    if (-not $contractOk) {
        $row['status'] = 'contract-failed'
        $row['detail'] = $contractError
        $rows.Add([pscustomobject]$row) | Out-Null
        continue
    }

    # --- アプリ本体と同じ監査 ---
    $numFull  = Test-YakuNumericIntegrity -SourceText ([string]$case.source) -TranslatedText $full  -Location "eval-$id-FULL"
    $numBrief = Test-YakuNumericIntegrity -SourceText ([string]$case.source) -TranslatedText $brief -Location "eval-$id-BRIEF"
    $struct   = Test-YakuTextStructureIntegrity -SourceText ([string]$case.source) -FullText $full -BriefText $brief

    $row['numeric_checked'] = [int]$numFull.Checked
    $row['numeric_ok_full'] = [bool]$numFull.Ok
    $row['numeric_ok_brief'] = [bool]$numBrief.Ok
    $row['structure_ok'] = [bool]$struct.Ok

    # --- 禁止語 ---
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($w in $forbiddenGlobal) { if (($full + ' ' + $brief) -like ('*' + $w + '*')) { $hits.Add($w.Trim()) | Out-Null } }
    foreach ($w in (Get-YakuEvalList $case.must_not_contain))      { if (($full + ' ' + $brief) -like ('*' + $w + '*')) { $hits.Add($w) | Out-Null } }
    foreach ($w in (Get-YakuEvalList $case.full_must_not_contain)) { if ($full -like ('*' + $w + '*')) { $hits.Add('FULL:' + $w) | Out-Null } }
    $row['forbidden_hits'] = @($hits.ToArray() | Sort-Object -Unique)

    # --- 必須語 ---
    $missing = New-Object System.Collections.Generic.List[string]
    $anyList   = Get-YakuEvalList $case.must_contain_any
    $fullList  = Get-YakuEvalList $case.full_must_contain_any
    $briefList = Get-YakuEvalList $case.brief_must_contain_any
    $rawList   = Get-YakuEvalList $case.raw_must_contain_any
    if ($anyList.Count   -gt 0 -and -not (Test-YakuEvalContains -Text ($full + ' ' + $brief) -Needles $anyList))  { $missing.Add('any:' + ($anyList -join '|')) | Out-Null }
    if ($fullList.Count  -gt 0 -and -not (Test-YakuEvalContains -Text $full  -Needles $fullList))                 { $missing.Add('FULL:' + ($fullList -join '|')) | Out-Null }
    if ($briefList.Count -gt 0 -and -not (Test-YakuEvalContains -Text $brief -Needles $briefList))                { $missing.Add('BRIEF:' + ($briefList -join '|')) | Out-Null }
    # 生応答に対する検査。全角山括弧のように、パーサが変換してしまうものを見る。
    if ($rawList.Count   -gt 0 -and -not (Test-YakuEvalContains -Text $raw   -Needles $rawList))                  { $missing.Add('RAW:' + ($rawList -join '|')) | Out-Null }
    $row['missing_required'] = @($missing.ToArray())

    # --- 用語集遵守 ---
    $applied = @(Get-YakuAppliedGlossaryEntries -Root $appRoot -InputText ([string]$case.source) -Direction ([string]$case.direction) -Settings $settings)
    $glossaryTotal = 0; $glossaryHit = 0; $glossaryMiss = New-Object System.Collections.Generic.List[string]
    foreach ($g in $applied) {
        $target = [string]$g.Target
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $glossaryTotal++
        # 訳語が候補を | で並べる場合があるため、いずれか1つが出ていればよい。
        $variants = @($target -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (Test-YakuEvalContains -Text ($full + ' ' + $brief) -Needles $variants) { $glossaryHit++ }
        else { $glossaryMiss.Add([string]$g.Source + '->' + $target) | Out-Null }
    }
    $row['glossary_total'] = $glossaryTotal
    $row['glossary_hit'] = $glossaryHit
    $row['glossary_miss'] = @($glossaryMiss.ToArray())

    # --- BRIEF 圧縮率 ---
    $row['full_chars'] = $full.Length
    $row['brief_chars'] = $brief.Length
    $row['brief_ratio'] = if ($full.Length -gt 0) { [Math]::Round($brief.Length / $full.Length, 2) } else { 0 }

    $pass = ($contractOk -and [bool]$numFull.Ok -and [bool]$struct.Ok -and $hits.Count -eq 0 -and $missing.Count -eq 0)
    $row['status'] = if ($pass) { 'pass' } else { 'fail' }
    $row['full'] = $full
    $row['brief'] = $brief
    $rows.Add([pscustomobject]$row) | Out-Null
}

# --- 集計 ---
$all = @($rows.ToArray())
$scored = @($all | Where-Object { $_.status -ne 'missing-response' })
$passCount = @($all | Where-Object { $_.status -eq 'pass' }).Count
$glossaryTotalAll = (@($scored | ForEach-Object { [int]$_.glossary_total } | Measure-Object -Sum).Sum)
$glossaryHitAll   = (@($scored | ForEach-Object { [int]$_.glossary_hit }   | Measure-Object -Sum).Sum)
if ($null -eq $glossaryTotalAll) { $glossaryTotalAll = 0 }
if ($null -eq $glossaryHitAll) { $glossaryHitAll = 0 }
$briefRatios = @($scored | Where-Object { $_.brief_ratio -gt 0 } | ForEach-Object { [double]$_.brief_ratio })

$summary = [ordered]@{
    cases            = $all.Count
    scored           = $scored.Count
    pass             = $passCount
    contract_ok      = @($scored | Where-Object { $_.contract_ok }).Count
    numeric_ok_full  = @($scored | Where-Object { $_.numeric_ok_full }).Count
    structure_ok     = @($scored | Where-Object { $_.structure_ok }).Count
    forbidden_cases  = @($scored | Where-Object { @($_.forbidden_hits).Count -gt 0 }).Count
    glossary_rate    = if ($glossaryTotalAll -gt 0) { [Math]::Round($glossaryHitAll / $glossaryTotalAll, 3) } else { 0 }
    brief_ratio_avg  = if ($briefRatios.Count -gt 0) { [Math]::Round((($briefRatios | Measure-Object -Average).Average), 2) } else { 0 }
}

Write-Host ''
Write-Host '=== 個別結果 ===' -ForegroundColor Cyan
foreach ($r in $all) {
    $color = switch ([string]$r.status) { 'pass' { 'Green' } 'missing-response' { 'DarkGray' } default { 'Red' } }
    Write-Host ('{0,-26} {1}' -f $r.id, $r.status) -ForegroundColor $color
    if ($r.status -eq 'fail') {
        if (@($r.forbidden_hits).Count -gt 0)   { Write-Host ('    禁止語: ' + (@($r.forbidden_hits) -join ', ')) -ForegroundColor Yellow }
        if (@($r.missing_required).Count -gt 0) { Write-Host ('    必須語なし: ' + (@($r.missing_required) -join ', ')) -ForegroundColor Yellow }
        if (-not $r.numeric_ok_full)            { Write-Host '    数値整合(FULL) NG' -ForegroundColor Yellow }
        if (-not $r.structure_ok)               { Write-Host '    構造整合 NG' -ForegroundColor Yellow }
        if (@($r.glossary_miss).Count -gt 0)    { Write-Host ('    用語未反映: ' + (@($r.glossary_miss) -join ', ')) -ForegroundColor DarkYellow }
    }
}

# グループ別のBRIEF圧縮率。用語集の内側と外側で安定しているかを見る。
$byGroup = @($scored | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.group) } | Group-Object group)
if ($byGroup.Count -gt 0) {
    Write-Host ''
    Write-Host '=== グループ別 BRIEF圧縮率 ===' -ForegroundColor Cyan
    foreach ($g in ($byGroup | Sort-Object Name)) {
        $ratios = @($g.Group | ForEach-Object { [double]$_.brief_ratio })
        $avg = [Math]::Round((($ratios | Measure-Object -Average).Average), 3)
        $min = [Math]::Round((($ratios | Measure-Object -Minimum).Minimum), 3)
        $max = [Math]::Round((($ratios | Measure-Object -Maximum).Maximum), 3)
        Write-Host ('  {0,-14} n={1}  平均={2}  最小={3}  最大={4}  幅={5}' -f $g.Name, $g.Count, $avg, $min, $max, [Math]::Round($max-$min,3))
    }
}

Write-Host ''
Write-Host '=== 集計 ===' -ForegroundColor Cyan
foreach ($k in $summary.Keys) { Write-Host ('  {0,-16} {1}' -f $k, $summary[$k]) }

[IO.File]::WriteAllText($ReportPath, (@{ label = $Label; summary = $summary; rows = $all } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))

# --- ベースラインとの差分 ---
if (-not [string]::IsNullOrWhiteSpace($CompareWith)) {
    $basePath = Join-Path (Join-Path (Get-YakuSubDir 'eval') $CompareWith) 'report.json'
    if (Test-Path -LiteralPath $basePath -PathType Leaf) {
        $base = [IO.File]::ReadAllText($basePath) | ConvertFrom-Json
        $baseRows = @{}
        foreach ($r in @($base.rows)) { $baseRows[[string]$r.id] = $r }
        # 応答の使い回し検出。A/Bで同一バイトの応答があれば、規則変更の効果を測れていない。
        $baseResponseDir = Join-Path (Join-Path (Get-YakuSubDir 'eval') $CompareWith) 'responses'
        $identical = New-Object System.Collections.Generic.List[string]
        foreach ($r in $scored) {
            $a = Join-Path $baseResponseDir ([string]$r.id + '.response.txt')
            $b = Join-Path $ResponseDir ([string]$r.id + '.response.txt')
            if ((Test-Path -LiteralPath $a -PathType Leaf) -and (Test-Path -LiteralPath $b -PathType Leaf)) {
                if ([IO.File]::ReadAllText($a) -eq [IO.File]::ReadAllText($b)) { $identical.Add([string]$r.id) | Out-Null }
            }
        }
        if ($identical.Count -gt 0) {
            Write-Host ''
            Write-Host ("*** 比較無効: 応答が使い回されています ({0}/{1}件が同一) ***" -f $identical.Count, $scored.Count) -ForegroundColor Red
            Write-Host ('    ' + (@($identical.ToArray()) -join ', ')) -ForegroundColor Red
            Write-Host '    A/Bは必ず別々に翻訳し直してください。片方を複製すると効果を測れません。' -ForegroundColor Red
        }

        Write-Host ''
        Write-Host ("=== {0} vs {1} ===" -f $Label, $CompareWith) -ForegroundColor Cyan
        Write-Host ('  {0,-26} {1,8} {2,8} {3,8}' -f 'case', $CompareWith, $Label, '差')
        foreach ($r in $scored) {
            if (-not $baseRows.ContainsKey([string]$r.id)) { continue }
            $b = [double]$baseRows[[string]$r.id].brief_ratio
            $c = [double]$r.brief_ratio
            $d = [Math]::Round($c - $b, 3)
            $mark = if ($d -lt -0.03) { '改善' } elseif ($d -gt 0.03) { '悪化' } else { '' }
            Write-Host ('  {0,-26} {1,8} {2,8} {3,8} {4}' -f $r.id, $b, $c, $d, $mark)
        }
        foreach ($g in ($byGroup | Sort-Object Name)) {
            $ids = @($g.Group | ForEach-Object { [string]$_.id })
            $baseAvg = [Math]::Round((@($ids | Where-Object { $baseRows.ContainsKey($_) } | ForEach-Object { [double]$baseRows[$_].brief_ratio } | Measure-Object -Average).Average), 3)
            $curAvg  = [Math]::Round((@($g.Group | ForEach-Object { [double]$_.brief_ratio } | Measure-Object -Average).Average), 3)
            Write-Host ('  [{0}] 平均 {1} -> {2}  差 {3}' -f $g.Name, $baseAvg, $curAvg, [Math]::Round($curAvg-$baseAvg,3)) -ForegroundColor Yellow
        }
    } else { Write-Host ("比較対象が見つかりません: " + $basePath) -ForegroundColor DarkYellow }
}
Write-Host ''
Write-Host ("レポート: " + $ReportPath) -ForegroundColor Green
