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
    [string]$ReportPath = ''
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
if ([string]::IsNullOrWhiteSpace($ResponseDir)) { $ResponseDir = Join-Path (Get-YakuSubDir 'eval') 'responses' }
if ([string]::IsNullOrWhiteSpace($PromptDir))   { $PromptDir   = Join-Path (Get-YakuSubDir 'eval') 'prompts' }
if ([string]::IsNullOrWhiteSpace($ReportPath))  { $ReportPath  = Join-Path (Get-YakuSubDir 'eval') 'report.json' }

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
    $row = [ordered]@{ id = $id; origin = [string]$case.origin; focus = [string]$case.focus }

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

Write-Host ''
Write-Host '=== 集計 ===' -ForegroundColor Cyan
foreach ($k in $summary.Keys) { Write-Host ('  {0,-16} {1}' -f $k, $summary[$k]) }

[IO.File]::WriteAllText($ReportPath, (@{ summary = $summary; rows = $all } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("レポート: " + $ReportPath) -ForegroundColor Green
