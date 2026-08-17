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

function ConvertTo-YakuCatQcEquivalentTimeText {
    <#
      日本語の「午後3時」は、英語では "3 p.m." と "3:00 p.m." のどちらも
      同じ時刻である。後者の 00 を独立した数値として扱うと、アプリ自身が作った
      自然な訳を numeric-value-extra で拒否してしまう。

      省くのは、原文が分を明示していない時刻と同じ時を指し、直後に a.m./p.m.
      がある :00 だけ。原文が「3時00分」「3時30分」と分を持つ場合や、単なる
      "3:00"、数量の 3 と 00 には適用しない。
    #>
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en'
    )
    $result = [string]$Target
    if ($Direction -ne 'to_en' -or [string]::IsNullOrWhiteSpace($result)) { return $result }
    $sourceText = (ConvertTo-YakuMaskNormalizedText -Text ([string]$Source))
    foreach ($match in [regex]::Matches($sourceText, '(?<period>午前|午後)?\s*(?<hour>\d{1,2})\s*時(?!\s*\d{1,2}\s*分)')) {
        $hour = [int]$match.Groups['hour'].Value
        if ($hour -lt 0 -or $hour -gt 23) { continue }
        $period = [string]$match.Groups['period'].Value
        $targetHour = if ($hour -eq 0) { 12 } elseif ($hour -gt 12) { $hour - 12 } else { $hour }
        $ampm = if ($period -eq '午前' -or ($period -eq '' -and $hour -lt 12)) { 'a\.?\s*m\.?' }
            elseif ($period -eq '午後' -or ($period -eq '' -and $hour -gt 12)) { 'p\.?\s*m\.?' }
            else { '(?:a\.?\s*m\.?|p\.?\s*m\.?)' }
        $pattern = '(?i)(?<!\d)' + [regex]::Escape([string]$targetHour) + ':00(?=\s*' + $ampm + '(?![A-Za-z]))'
        $result = [regex]::Replace($result, $pattern, [string]$targetHour)
    }
    return $result
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

function Find-YakuCatPairedDelimiterMismatch {
    <#
      訳文だけを一度走査して、対応する開き・閉じ記号が壊れていないかを調べる。

      これは誤字・組版の見落としを拾うための **warning** であり、原文と同じ
      記号を要求する検査ではない。日英では句読点も引用符の置き方も変わり得る。
      ASCII の quote / apostrophe と curly single quote は英語の短縮形や単位の
      prime と区別できないため、意図的に対象にしない。< > も比較演算子・HTML
      断片との区別が付かないので対象外にする。

      FormKC を掛けず、( と ）のような混在も見た目どおり不一致として扱う。
      対象の記号はすべて BMP 内なので、PowerShell 5.1 の UTF-16 code unit を
      一つずつ読むだけで足りる。正規表現・ファイルI/O・用語集照会は行わず、
      時間 O(n)、追加メモリ O(入れ子の深さ) である。
    #>
    param([AllowNull()][string]$Text)

    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) { return $null }
    $pairs = @{
        '(' = ')'; '[' = ']'; '{' = '}'
        '（' = '）'; '［' = '］'; '｛' = '｝'
        '「' = '」'; '『' = '』'; '【' = '】'; '〔' = '〕'; '〈' = '〉'; '《' = '》'
        '“' = '”'
    }
    $closing = @{}
    foreach ($opening in @($pairs.Keys)) { $closing[[string]$pairs[[string]$opening]] = [string]$opening }
    $stack = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $value.Length; $i++) {
        $mark = [string]$value[$i]
        # 数値マスク [[N1]] / [[P1]] は既存の placeholder-residue が専用に
        # 扱う。通常の [] として二重に数えない。完全な保護トークンだけを飛ばし、
        # 壊れた token は記号自体の不整合としてここで見えるままにする。
        if ($mark -eq '[' -and ($i + 5) -lt $value.Length -and [string]$value[$i + 1] -eq '[' -and ([string]$value[$i + 2] -eq 'N' -or [string]$value[$i + 2] -eq 'P')) {
            $tokenEnd = $i + 3
            while ($tokenEnd -lt $value.Length -and [char]::IsDigit($value[$tokenEnd])) { $tokenEnd++ }
            if ($tokenEnd -gt ($i + 3) -and ($tokenEnd + 1) -lt $value.Length -and [string]$value[$tokenEnd] -eq ']' -and [string]$value[$tokenEnd + 1] -eq ']') {
                $i = $tokenEnd + 1
                continue
            }
        }
        if ($pairs.ContainsKey($mark)) {
            $stack.Add($mark) | Out-Null
            continue
        }
        if (-not $closing.ContainsKey($mark)) { continue }
        if ($stack.Count -eq 0) {
            return [pscustomobject]@{ Reason='unexpected-closing'; Position=[int]$i; Mark=$mark; Expected='' }
        }
        $opening = [string]$stack[$stack.Count - 1]
        $expected = [string]$pairs[$opening]
        if ($expected -ne $mark) {
            return [pscustomobject]@{ Reason='mismatched-closing'; Position=[int]$i; Mark=$mark; Expected=$expected }
        }
        $stack.RemoveAt($stack.Count - 1)
    }
    if ($stack.Count -gt 0) {
        $opening = [string]$stack[$stack.Count - 1]
        return [pscustomobject]@{ Reason='missing-closing'; Position=[int]$value.Length; Mark=$opening; Expected=[string]$pairs[$opening] }
    }
    return $null
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

function Initialize-YakuCatProjectState {
    param([Parameter(Mandatory=$true)]$Project)
    if (-not ($Project.PSObject.Properties.Name -contains 'Revision')) { $Project | Add-Member -NotePropertyName Revision -NotePropertyValue 0 -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'SchemaVersion')) { $Project | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue 8 -Force }
    elseif ([int]$Project.SchemaVersion -lt 8) { $Project.SchemaVersion = 8 }
    if (-not ($Project.PSObject.Properties.Name -contains 'Lifecycle') -or @('transient','saved','deleting','deleted') -notcontains [string]$Project.Lifecycle) {
        $Project | Add-Member -NotePropertyName Lifecycle -NotePropertyValue 'saved' -Force
    }
    if (-not ($Project.PSObject.Properties.Name -contains 'RetentionUntil')) { $Project | Add-Member -NotePropertyName RetentionUntil -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'PromotedAt')) { $Project | Add-Member -NotePropertyName PromotedAt -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DeletionMemoryPolicy')) { $Project | Add-Member -NotePropertyName DeletionMemoryPolicy -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'TextSourceStructure')) { $Project | Add-Member -NotePropertyName TextSourceStructure -NotePropertyValue $null -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'ReviewEvents')) { $Project | Add-Member -NotePropertyName ReviewEvents -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'ActiveSourceId')) { $Project | Add-Member -NotePropertyName ActiveSourceId -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'SourceSnapshots')) { $Project | Add-Member -NotePropertyName SourceSnapshots -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'AppliedRebaseId')) { $Project | Add-Member -NotePropertyName AppliedRebaseId -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'ActiveGenerationId')) { $Project | Add-Member -NotePropertyName ActiveGenerationId -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'RebaseRecords')) { $Project | Add-Member -NotePropertyName RebaseRecords -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'PlacementPlans')) { $Project | Add-Member -NotePropertyName PlacementPlans -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'PlacementSetHash')) { $Project | Add-Member -NotePropertyName PlacementSetHash -NotePropertyValue '' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DocumentFindings')) { $Project | Add-Member -NotePropertyName DocumentFindings -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'ReviewRuns')) { $Project | Add-Member -NotePropertyName ReviewRuns -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DocumentIndexSnapshot')) { $Project | Add-Member -NotePropertyName DocumentIndexSnapshot -NotePropertyValue $null -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'FinalReviewDecisions')) { $Project | Add-Member -NotePropertyName FinalReviewDecisions -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'PublicationVariants')) { $Project | Add-Member -NotePropertyName PublicationVariants -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'ActivePublicationVariantBySegment') -or $null -eq $Project.ActivePublicationVariantBySegment) { $Project | Add-Member -NotePropertyName ActivePublicationVariantBySegment -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'AbbreviationEntries')) { $Project | Add-Member -NotePropertyName AbbreviationEntries -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'AbbreviationUses')) { $Project | Add-Member -NotePropertyName AbbreviationUses -NotePropertyValue @() -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'MutationReceipts')) { $Project | Add-Member -NotePropertyName MutationReceipts -NotePropertyValue @() -Force }
    # Ctrl+H の直近1回だけを戻す、世代と一緒に保存する小さな復元券。一般の
    # 履歴ではない。通常の mutation は Invoke-YakuCatProjectMutation が候補内で
    # これを空にするので、保存に失敗したときにだけ古い券が残ることもない。
    if (-not ($Project.PSObject.Properties.Name -contains 'PendingBulkReplaceUndo')) { $Project | Add-Member -NotePropertyName PendingBulkReplaceUndo -NotePropertyValue $null -Force }
    # 構造編集（結合/分割/任意位置分割）は行IDそのものを作り替える。これは一般的な
    # 履歴ではなく、保存世代と同時に残す「直前1回だけ」の復元券である。
    if (-not ($Project.PSObject.Properties.Name -contains 'PendingStructuralUndo')) { $Project | Add-Member -NotePropertyName PendingStructuralUndo -NotePropertyValue $null -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'LastOutputRecord')) { $Project | Add-Member -NotePropertyName LastOutputRecord -NotePropertyValue $null -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DirectionBasis')) { $Project | Add-Member -NotePropertyName DirectionBasis -NotePropertyValue 'fixed' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DirectionConfidence')) { $Project | Add-Member -NotePropertyName DirectionConfidence -NotePropertyValue 'not_applicable' -Force }
    if (-not ($Project.PSObject.Properties.Name -contains 'DirectionSourceFingerprint')) { $Project | Add-Member -NotePropertyName DirectionSourceFingerprint -NotePropertyValue '' -Force }
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
        if (-not ($segment.PSObject.Properties.Name -contains 'TmRegistered')) { $segment | Add-Member -NotePropertyName TmRegistered -NotePropertyValue $false -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'TmRegistrationEventId')) { $segment | Add-Member -NotePropertyName TmRegistrationEventId -NotePropertyValue '' -Force }
        # 任意位置で割った行の目印。古い作業には項目そのものが無いので空で足す。
        if (-not ($segment.PSObject.Properties.Name -contains 'SplitGroupId')) { $segment | Add-Member -NotePropertyName SplitGroupId -NotePropertyValue '' -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'SplitOrdinal')) { $segment | Add-Member -NotePropertyName SplitOrdinal -NotePropertyValue 0 -Force }
        if (-not ($segment.PSObject.Properties.Name -contains 'SplitOriginSegmentId')) { $segment | Add-Member -NotePropertyName SplitOriginSegmentId -NotePropertyValue '' -Force }
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

function Assert-YakuCatMutationReceiptContract {
    param(
        [Parameter(Mandatory=$true)][string]$IdempotencyKey,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$RequestHash
    )
    if ($IdempotencyKey -notmatch '^[A-Za-z0-9_.:-]{16,128}$' -or
        [string]::IsNullOrWhiteSpace($Action) -or $RequestHash -notmatch '^[a-f0-9]{64}$') {
        throw 'CAT_IDEMPOTENCY_CONTRACT_INVALID: 更新要求の識別情報が不正です。'
    }
}

function ConvertFrom-YakuCatMutationReceiptResult {
    param([Parameter(Mandatory=$true)]$Receipt)
    $resultJson = [string]$Receipt.result_json
    if ([string]::IsNullOrWhiteSpace($resultJson) -or
        [string]$Receipt.result_hash -cne (Get-YakuCatSourceIntegrityHash -Text $resultJson)) {
        throw 'CAT_IDEMPOTENCY_RECEIPT_INVALID: 更新結果の整合性を確認できません。'
    }
    try { return ($resultJson | ConvertFrom-Json) }
    catch { throw 'CAT_IDEMPOTENCY_RECEIPT_INVALID: 更新結果を復元できません。' }
}

function Get-YakuCatProjectMutationReplay {
    <# 長時間jobの一時状態を読む前に、永続generationへ保存済みの結果を返す。
       同じkeyの別payloadは、通常mutationと同じく競合として拒否する。 #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$IdempotencyKey,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$RequestHash
    )
    Assert-YakuCatMutationReceiptContract -IdempotencyKey $IdempotencyKey -Action $Action -RequestHash $RequestHash
    $state=[pscustomobject]@{ProjectId=$ProjectId;IdempotencyKey=$IdempotencyKey;Action=$Action;RequestHash=$RequestHash}
    $operation={
        param($innerState)
        $id=[string]$innerState.ProjectId
        if(-not $script:YakuCatProjects.ContainsKey($id)){throw 'CAT_PROJECT_NOT_FOUND: 作業が見つかりません。'}
        $committed=$script:YakuCatProjects[$id]
        $matches=@($committed.MutationReceipts|Where-Object{[string]$_.idempotency_key -ceq [string]$innerState.IdempotencyKey})
        if($matches.Count -gt 1){throw 'CAT_IDEMPOTENCY_RECEIPT_INVALID: 更新履歴が重複しています。'}
        if($matches.Count -eq 0){return $null}
        $receipt=$matches[0]
        if([string]$receipt.action -cne [string]$innerState.Action -or [string]$receipt.request_hash -cne [string]$innerState.RequestHash){throw 'CAT_IDEMPOTENCY_KEY_REUSED: 同じ識別子が別の更新に使われています。'}
        $result=ConvertFrom-YakuCatMutationReceiptResult -Receipt $receipt
        return [pscustomobject]@{Project=$committed;Result=$result;Replayed=$true;Receipt=$receipt}
    }
    return (Invoke-YakuCatProjectLock -ProjectId $ProjectId -Operation $operation -Arguments @($state))
}

function Assert-YakuCatProjectPersisted {
    <# 永続化できなかった Project を registry へ公開しないための1点。
       Save-YakuCatProject は失敗を2通りで伝える（catch 末尾の return $false と、
       同じ catch の -ThrowOnError 再送出）。片方だけを見ると、もう片方の失敗が
       素通りして未保存の candidate が registry へ載る。両方をここで受けて、
       同じ CAT_PROJECT_SAVE_FAILED に揃える。下位の原因はメッセージへ残す。
       registry を差し替える行は、必ずこの呼び出しより後に置くこと。

       ただし下位が既に CAT_ の安定コードを持つときは、包まずにそのまま通す。
       Server.ps1 は応答コードを '^(CAT_[A-Z0-9_]+)' と行頭固定で抜き、その値で
       409 か 400 かを決める。包むと CAT_COMMIT_MANIFEST_CONFLICT が先頭から消え、
       別プロセスが先に保存した競合が 409 から 400 へ落ちて current_revision も
       返らなくなる。2026-08-14 に実際にそう壊し、47本すべて緑のまま素通りした
       （見張っている表明が Server.ps1 の本文を字面で見るだけで、挙動を計算して
       いなかったため）。緑は、壊れていないことの証拠にならない。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $saved = $false
    try {
        $saved = [bool](Save-YakuCatProject -Project $Project -ThrowOnError)
    } catch {
        $inner = [string]$_.Exception.Message
        if ($inner -match '^CAT_[A-Z0-9_]+') { throw $_ }
        throw ('CAT_PROJECT_SAVE_FAILED: 作業内容を保存できませんでした。 ' + $inner)
    }
    if (-not $saved) { throw 'CAT_PROJECT_SAVE_FAILED: 作業内容を保存できませんでした。' }
}

function Invoke-YakuCatProjectMutation {
    <# ExpectedRevision の確認、candidate への変更、世代/manifest 保存、registry
       差替えを同じ project lock 内で行う。Mutation は共有 Project を受け取らない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][int]$ExpectedRevision,
        [Parameter(Mandatory=$true)][scriptblock]$Mutation,
        [object[]]$Arguments = @(),
        [string]$IdempotencyKey = '',
        [string]$Action = '',
        [string]$RequestHash = '',
        [switch]$NoCommitWhenNoMutation
    )
    if (-not [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        Assert-YakuCatMutationReceiptContract -IdempotencyKey $IdempotencyKey -Action $Action -RequestHash $RequestHash
    }
    $state = [pscustomobject]@{
        ProjectId = $ProjectId
        ExpectedRevision = $ExpectedRevision
        Mutation = $Mutation
        Arguments = @($Arguments)
        IdempotencyKey = $IdempotencyKey
        Action = $Action
        RequestHash = $RequestHash
        NoCommitWhenNoMutation = [bool]$NoCommitWhenNoMutation
    }
    $operation = {
        param($innerState)
        $id = [string]$innerState.ProjectId
        if (-not $script:YakuCatProjects.ContainsKey($id)) {
            throw 'CAT_PROJECT_NOT_FOUND: 作業が見つかりません。'
        }
        $committed = $script:YakuCatProjects[$id]
        $key = [string]$innerState.IdempotencyKey
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $matches = @($committed.MutationReceipts | Where-Object { [string]$_.idempotency_key -ceq $key })
            if ($matches.Count -gt 1) { throw 'CAT_IDEMPOTENCY_RECEIPT_INVALID: 更新履歴が重複しています。' }
            if ($matches.Count -eq 1) {
                $receipt = $matches[0]
                if ([string]$receipt.action -cne [string]$innerState.Action -or [string]$receipt.request_hash -cne [string]$innerState.RequestHash) {
                    throw 'CAT_IDEMPOTENCY_KEY_REUSED: 同じ識別子が別の更新に使われています。'
                }
                $replayedResult = ConvertFrom-YakuCatMutationReceiptResult -Receipt $receipt
                return [pscustomobject]@{ Project=$committed; Result=$replayedResult; Replayed=$true; Receipt=$receipt }
            }
        }
        if([string]$committed.Lifecycle -in @('deleting','deleted') -and [string]$innerState.Action -ne 'project-delete-start'){
            throw 'CAT_PROJECT_DELETING: この作業は削除処理中です。'
        }
        if ([int]$committed.Revision -ne [int]$innerState.ExpectedRevision) {
            throw 'CAT_PROJECT_REVISION_CONFLICT: 別の操作で作業内容が更新されました。最新状態を読み込んでからやり直してください。'
        }
        $candidate = Copy-YakuCatProjectForMutation -Project $committed
        # undo はどちらも直前1回だけ。候補内で先に失効させるので、下流が throw /
        # 保存失敗なら committed の券は残る。構造編集はbulk券を、Ctrl+H は構造券を
        # 互いに失効させる。一般の更新は両方を失効させる。
        $mutationAction = [string]$innerState.Action
        if ($mutationAction -in @('merge','split','split-at','structure-undo')) {
            $candidate.PendingBulkReplaceUndo = $null
        } elseif ($mutationAction -in @('replace','replace-undo')) {
            $candidate.PendingStructuralUndo = $null
        } else {
            $candidate.PendingBulkReplaceUndo = $null
            $candidate.PendingStructuralUndo = $null
        }
        $mutationArguments = @($innerState.Arguments)
        $mutationResult = & $innerState.Mutation $candidate @mutationArguments
        if ([bool]$innerState.NoCommitWhenNoMutation -and $null -ne $mutationResult -and [bool]$(try { $mutationResult.NoMutation } catch { $false })) {
            return [pscustomobject]@{ Project=$committed; Result=$mutationResult; Replayed=$false; Receipt=$null }
        }
        $receipt = $null
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $resultJson = if ($null -eq $mutationResult) { 'null' } else { $mutationResult | ConvertTo-Json -Depth 20 -Compress }
            if ([Text.Encoding]::UTF8.GetByteCount($resultJson) -gt 65536) { throw 'CAT_IDEMPOTENCY_RESULT_TOO_LARGE: 更新結果を安全に記録できません。' }
            $receipt = [pscustomobject]@{
                receipt_id = [guid]::NewGuid().ToString('N')
                idempotency_key = $key
                action = [string]$innerState.Action
                request_hash = [string]$innerState.RequestHash
                committed_revision = [int]$committed.Revision + 1
                result_hash = Get-YakuCatSourceIntegrityHash -Text $resultJson
                result_json = $resultJson
                created_at = (Get-Date).ToString('o')
            }
            # receiptもproject stateと同じgenerationへ入れ、manifestの差替えより
            # 前に単独で見える状態を作らない。古いreceiptは再送期間を十分超える
            # 件数だけ残し、projectの肥大化を防ぐ。
            $candidate.MutationReceipts = @(@($candidate.MutationReceipts) + @($receipt) | Select-Object -Last 256)
        }
        Assert-YakuCatProjectPersisted -Project $candidate
        $script:YakuCatProjects[$id] = $candidate
        return [pscustomobject]@{ Project=$candidate; Result=$mutationResult; Replayed=$false; Receipt=$receipt }
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
        # newProject は未コミットなので、保存失敗時はIDを返す前に破棄する。
        Assert-YakuCatProjectPersisted -Project $candidate
        $script:YakuCatProjects[$id] = $candidate
        return $candidate
    }
    return (Invoke-YakuCatProjectLock -ProjectId $projectId -Operation $operation -Arguments @($state))
}

function Get-YakuCatSegmentNormalizedSource {
    <#
      点検が原文として使う文字列。to_en では単位換算（1兆3,150億円 → 13,150 oku）を
      通したものになる。ここを通さない生の原文と突き合わせると、アプリ自身が
      換算した訳文をアプリ自身が numeric-value-mismatch で拒否する。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Segment
    )
    $source = [string]$Segment.Text
    if ([string]$Project.Direction -ne 'to_en') { return $source }
    return [string](Convert-YakuNumericUnits -Text $source -Notation (Get-YakuCatProjectAmountNotation -Project $Project) -Location ('cat-review-' + [string]$Segment.SegmentId)).Text
}

function Get-YakuCatSegmentSourceNumericFacts {
    <#
      原文側の数値を取り出す唯一の経路。

      なぜ関数にしたか（2026-08-16）: 訳文欄へ数字を入れるキー操作（画面の
      placeables）を足すにあたって、取り出しをもう1つ書くと「入れたのに
      numeric-value-mismatch が立つ」食い違いが必ず生まれる。点検と挿入は
      同じ一覧を見る。

      単位変換は原文を訳文側の表記（13,150 oku）へ書き換える。だから分類も
      訳文と同じ側で行う。原文側だけ日本語向けの分類にすると、同じ
      「13,150 oku」が原文では number|13150、訳文では currency:yen|1315000000000
      になり、一致しなくなる。

      -NormalizedSource は Get-YakuCatSegmentNormalizedSource の結果を持っている
      呼び出し側のためにある。渡さなければここで引き直す（換算を2度走らせない）。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Segment,
        [AllowNull()][object]$NormalizedSource = $null
    )
    $normalized = if ($null -eq $NormalizedSource) { Get-YakuCatSegmentNormalizedSource -Project $Project -Segment $Segment } else { [string]$NormalizedSource }
    $factsDirection = if ([string]$Project.Direction -eq 'to_en') { 'to_jp' } else { [string]$Project.Direction }
    return @(Get-YakuCanonicalNumericFacts -Text $normalized -Direction $factsDirection -Location ('cat-review-source-' + [string]$Segment.SegmentId))
}

function Get-YakuCatSegmentPlaceables {
    <#
      訳文欄へキー操作で入れられる、原文の数字の一覧。出現順。

      text は**原文どおりの表記**である（桁区切り・小数点をそのまま返す）。
      Get-YakuCanonicalNumericFacts の Raw は数値マスクが切り出した文字列そのもので、
      「1,234」を「1234」へ均したりはしない。

      なぜ画面の JSON に毎回載せないか（2026-08-16 に実測）: この取り出しは
      1行あたり約 12ms（うち Convert-YakuNumericUnits が 8.6ms）かかる。
      200行の資料では画面用 JSON が 1.6 秒から 4.1 秒へ延びた。保存のたびに
      作り直す JSON なので、押したときだけ数える。

      取り出せない原文（CAT_NUMERIC_FACT_UNPARSEABLE）は、黙って空を返さずに
      Ok=$false で言う。空と取り違えると「この行に数字は無い」と嘘をつく。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'CAT_SEGMENT_INDEX_OUT_OF_RANGE: 行が見つかりません。' }
    $segment = $segs[$Index]
    $items = New-Object System.Collections.Generic.List[object]
    $ok = $true
    try {
        foreach ($fact in @(Get-YakuCatSegmentSourceNumericFacts -Project $Project -Segment $segment)) {
            $items.Add([ordered]@{ text = [string]$fact.Raw; kind = [string]$fact.Category }) | Out-Null
        }
    } catch { $ok = $false }
    return [pscustomobject]@{
        Ok = $ok
        Index = $Index
        SegmentId = [string]$segment.SegmentId
        Items = @($items.ToArray())
    }
}

function ConvertTo-YakuCatSegmentPlaceablesJson {
    <#
      画面が読む形。Server.ps1 の口も、画面の回帰テストが Chromium へ返す
      決め打ちの応答も、**この関数1つ**から作る。応答の形を2か所に書くと、
      試験の中の形だけが正しいまま実物が腐る。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index
    )
    $placeables = Get-YakuCatSegmentPlaceables -Project $Project -Index $Index
    return ([ordered]@{
        index = [int]$placeables.Index
        segment_id = [string]$placeables.SegmentId
        # 取り出せなかったことを、数字が無いことと取り違えさせない。
        available = [bool]$placeables.Ok
        placeables = @($placeables.Items)
    } | ConvertTo-Json -Depth 4 -Compress)
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
    $pairedDelimiter = Find-YakuCatPairedDelimiterMismatch -Text $target
    if ($null -ne $pairedDelimiter) {
        $findings.Add([pscustomobject]@{ Code='paired-delimiter-mismatch'; Severity='warning'; Detail=([string]$pairedDelimiter.Reason) }) | Out-Null
    }

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
            $normalizedSource = Get-YakuCatSegmentNormalizedSource -Project $Project -Segment $Segment
            $targetForNumericQc = ConvertTo-YakuCatQcEquivalentTimeText -Source $source -Target $target -Direction ([string]$Project.Direction)
            $audit = Test-YakuNumericIntegrity -SourceText $normalizedSource -TranslatedText $targetForNumericQc -Location ('cat-review-' + [string]$Segment.SegmentId)
            if (-not [bool]$audit.Ok) { $findings.Add([pscustomobject]@{ Code='numeric-integrity'; Severity='error'; Detail=[string]$audit.Detail }) | Out-Null }
            # 突き合わせにも単位変換後の原文を使う。443行の $audit だけが変換を通っていて、
            # ここが生の原文のままだった。そのため「1兆3,150億円」が 1 と 3,150 に割れ、
            # アプリ自身が正しく換算した「13,150 oku」を、アプリ自身が
            # numeric-value-mismatch と numeric-value-extra で拒否していた。
            # 兆を含む金額は有報・短信で頻出し、その行は確認済みにできなかった。
            $targetDirection = if ([string]$Project.Direction -eq 'to_en') { 'to_jp' } else { 'to_en' }
            # 原文側の数値は Get-YakuCatSegmentSourceNumericFacts が唯一の出どころ。
            # 訳文欄への挿入（placeables）も同じ関数を通す。分類の理由はその関数の註を見る。
            $sourceFacts = @(Get-YakuCatSegmentSourceNumericFacts -Project $Project -Segment $Segment -NormalizedSource $normalizedSource)
            $sourceValues = @($sourceFacts | ForEach-Object { [string]$_.Key })
            $targetFacts = @(Get-YakuCanonicalNumericFacts -Text $targetForNumericQc -Direction $targetDirection -Location ('cat-review-target-' + [string]$Segment.SegmentId))
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
    # 負であることの印は、マイナス記号・損失を表す語のほかに「括弧」がある。
    # このアプリ自身が Copilot へ「▲やマイナスは数値を括弧でくくれ」と指示しており
    # （PromptBuilder.ps1 の amount 規約）、画面にも「▲152億円 → (152) oku」と
    # 書いている。にもかかわらず括弧を印として数えていなかったため、自分で作った
    # (152) oku を自分の点検が「マイナスが無い」と弾き、確認済みにできなかった
    # （2026-08-11、実機のExcel取り込みで判明）。負の金額を含む資料は、この規約の
    # とおりに訳すかぎり必ず出力できなくなる。
    $targetHasNegativeMark = $target -match '(?i)(?:^|[\s(])[-−]|loss|decrease|decline|deficit|negative|損失|減少|赤字|マイナス|△|▲' -or $target -match '\(\s*\d[\d,.]*\s*\)'
    if (-not $isVerbatimRegisteredTerm -and ($source -match '[△▲]' -or $source -match '\(\s*[-+]?\d[\d,.]*\s*\)') -and -not $targetHasNegativeMark) {
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
    # billion 表記では、このアプリ自身が Copilot へ「¥1,315 billion と書け」と
    # 指示している（PromptBuilder.ps1 の amount 規約）。¥ を通貨として数えないと、
    # 規約どおりの訳文を自分の点検が currency-mismatch で拒否する。
    $yenMark = '(?i)(?:円|\byen\b|\boku\b|¥|\bJPY\b)'
    if (-not $isVerbatimRegisteredTerm -and $source -match $yenMark -and $target -notmatch $yenMark) { $findings.Add([pscustomobject]@{ Code='currency-mismatch'; Severity='error'; Detail='yen' }) | Out-Null }
    if (-not $isVerbatimRegisteredTerm -and $source -match '(?i)(?:ドル|\bdollars?\b|\$)' -and $target -notmatch '(?i)(?:ドル|\bdollars?\b|\$)') { $findings.Add([pscustomobject]@{ Code='currency-mismatch'; Severity='error'; Detail='dollar' }) | Out-Null }
    try {
        $structure = Test-YakuTextStructureIntegrity -SourceText $source -FullText $target -BriefText $target
        if (-not [bool]$structure.Ok) { $findings.Add([pscustomobject]@{ Code='structure-integrity'; Severity='error'; Detail=[string]$structure.Detail }) | Out-Null }
    } catch { $findings.Add([pscustomobject]@{ Code='structure-validation-error'; Severity='error' }) | Out-Null }
    $terminologyHash = ''
    # 用語一覧は下のラベル検査でも使う。読み直すと1行あたりの読み込みが1回増える
    # ので、取れたものを持ち回す。取れなかった（例外）ときは $null のままにして、
    # 下で「引けなかった」として扱う。**空配列と取り違えない。**
    $terminologyEntries = $null
    try {
        $entries = @(Get-YakuCatTerminologyEntries -Project $Project)
        $terminologyEntries = $entries
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
    # 用語集に無い短いラベル。**警告であって、止める理由ではない。**
    #
    # なぜ要るか（決定 _docs/決定_用語集は用語の一貫性ではなくレイアウトの保証.md §1）:
    # cell_exact の完全一致置換は、用語の一貫性ではなく「列からはみ出さないこと」の
    # 保証として使われている。過去のラベルはその列に収まっていたから採用された訳語で、
    # 同じ訳語を使うかぎり必ず収まる。したがって穴は**新しいラベル**であり、
    # 「しかもそれが見えない」ことがこの決定の言う欠陥そのものである。
    #
    # 判定は Test-YakuFileLabelLike（src/CatBatch.ps1）ただ1つを使う。ここへ
    # 条件を写すと、片方だけ直したときに黙ってずれる。**Get-Command で守らない。**
    # 守ると、読み込み順序が崩れたときに検出が丸ごと消えたまま緑になる
    # （SrcModules.ps1 の註にある GlossaryVariants と同じ壊れ方）。
    # SrcModules.ps1 は CatBatch.ps1 を CatProject.ps1 より先に読む。
    #
    # 対象を Kind='cell' に限るのは、はみ出しが問題になるのが列に収める場所だから
    # である。貼り付け本文や Word の段落は行の高さで吸収できる（決定 §2）。
    # EN→JA で立たないことは Test-YakuFileLabelLike の「日本語を含む」条件が担う。
    #
    # 止めない理由: 用語集は網羅を求めない（決定 §1）。登録するかどうかは利用者が
    # 決めることで、登録していないこと自体は欠陥ではない。だから Severity は
    # 'warning' であり、下の $blocking にも Get-YakuCatOutputEligibility の
    # Reasons にも入らない。**止める理由は3つのままである。**
    if ([string]$Segment.Kind -eq 'cell' -and (Test-YakuFileLabelLike -Text $source)) {
        $labelLookupFailed = $false
        $labelRegistered = $false
        try {
            $labelEntries = $terminologyEntries
            if ($null -eq $labelEntries) { $labelEntries = @(Get-YakuCatTerminologyEntries -Project $Project) }
            $labelMatch = Find-YakuCellExactTerminologyMatch -Text $source -Direction ([string]$Project.Direction) `
                -Entries @($labelEntries) -ProjectId ([string]$Project.Id)
            $labelRegistered = ($null -ne $labelMatch)
        } catch {
            # 引けなかったときは黙る。用語集が読めない事実は
            # terminology-check-unavailable が既に error として言っており、
            # ここで重ねて「登録が無い」と言うと、無い理由を取り違えさせる。
            $labelLookupFailed = $true
        }
        if (-not $labelLookupFailed -and -not $labelRegistered) {
            $findings.Add([pscustomobject]@{ Code='label-not-in-glossary'; Severity='warning'; Detail=('label=' + $source) }) | Out-Null
        }
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

function Get-YakuCatProjectAmountNotation {
    <# その作業を作ったときの金額表記。あとから設定を変えても、この作業の送信と
       点検は同じ表記のままにする。表記が食い違うと、アプリ自身が換算した数値を
       アプリ自身が numeric-value-mismatch として弾く（点検は換算後の原文と
       突き合わせるため）。古い作業には項目が無いので oku とみなす。 #>
    param([AllowNull()]$Project)
    $v = ''
    try { $v = [string]$Project.AmountNotation } catch { $v = '' }
    if ($v -eq 'billion') { return 'billion' }
    return 'oku'
}

function Get-YakuCatOutputEligibility {
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $reasons = New-Object System.Collections.Generic.List[string]
    if (@($Project.Segments).Count -eq 0) { $reasons.Add('project-empty') | Out-Null }

    # 2026-08-12: 全行を確認済みにしないとファイルを作れない決まりをやめた。
    # 市販ツールを調べたところ、どれも「書き出す」と「完了にする」を分けている。
    #   memoQ  : 未確認・未訳があっても書き出せる（警告を出す）。納品は全行確認が必要
    #   Phrase : ターゲットは随時ダウンロードできる。Complete は全確認が必要
    #   Trados : Draft のままでも目的ファイルを生成できる。Finalize は別のバッチ
    # このアプリは書き出しに全行確認を要求しており、3つのどれよりも厳しかった。
    #
    # 残す歯止めは3つ。どれも「直さないと欠陥になる」ものである。
    # （2026-08-14 に CLAUDE.md が「2つだけ」を3つへ訂正した。この註だけが
    #  2つのまま残っていて、次に実装を読んだ者がまた「2つ」と書いた。実装は
    #  最初から3つ積んでいる。註のほうを実装へ合わせる。）
    #   1. 訳文が空の行がある                     → 出せない（segment-untranslated）
    #   2. 自動点検に落ちる行がある               → 出せない（segment-qc-failed）
    #   3. 確定済みだが点検が古い行がある         → 出せない（segment-qc-not-current）
    #
    # 2 は「数字」だけではない。Invoke-YakuCatSegmentValidation が error として
    # 積むコードは 18 種あり、通貨・体裁・用語もその中に居る。理由コードを
    # segment-qc-failed の1本に丸めたままにすると、用語で止まった利用者が
    # 「数字の点検に通らない行があります」と言われ、数字を見に行かされる。
    # そこで、どの種別で落ちたかを QcFailures に行数つきで積み、
    # Get-YakuCatOutputPreflight が種別ごとの文言へ直す。
    # **止める条件は増やしも減らしもしない。** Reasons の顔ぶれは従来どおりで、
    # 分けるのは説明だけである。
    #
    # 未確認は止めない。代わりに何行あるかを数え、押す前の画面と文書内の帯に出す。
    #
    # 未確認の行はここで写しに対して点検を走らせて調べる。写しに対して行うので、
    # 作業の状態は変えない。
    #
    # 註の訂正（2026-08-15）: ここには長らく「点検は確定したときにしか走らない」と
    # 書いてあったが、**それは既に事実でなかった**。この関数は
    # Get-YakuCatProjectSummary（画面へ返す JSON を作るたびに通る）からも呼ばれる
    # ので、未確認の行の点検は毎回走っている。走っていないのは
    # 「実セグメントへ結果を書くこと」だけである（それは確定時に限る。写しの結果を
    # Segment.QcFindings へ書くと Test-YakuCatSegmentQcCurrent と監査の意味が壊れる）。
    #
    # そのうえで、写しが出した種別を **行ごとに** も持ち帰る（QcRows）。
    # 2026-08-15 の欠陥: Get-YakuCatOutputPreflight の文言 15 本が
    # 「左の『点検の指摘』を押すと、その行だけ表示できます」と案内するのに、
    # その絞り込みは www/assets/cat.js が segment.qc_findings の件数で出し入れして
    # いた。未確認の行では実セグメントに findings が1件も無いので、**案内先の
    # ボタンがそもそも描かれない**。同じ書き出しの窓にある「点検一覧を開く」も
    # 同じ出どころなので、「用語で N 行止まっています」と言った直後に
    # 「直すところは見つかりませんでした」と出ていた。
    # ここで捨てていた内訳を渡せば、案内先が実際に開く。**点検を走らせる時機は
    # 1ミリも変えない。既に走っている結果を捨てるのをやめるだけ**である。
    $unconfirmed = 0
    $qcFailureRows = [ordered]@{}
    $qcRows = New-Object System.Collections.Generic.List[object]
    foreach ($segment in @($Project.Segments)) {
        if ([string]::IsNullOrWhiteSpace([string]$segment.Translation)) { $reasons.Add('segment-untranslated') | Out-Null; continue }
        if ([string]$segment.State -eq 'reviewed') {
            # warning の追加で QC 契約を上げると、保存済みの確認行が一斉に
            # segment-qc-not-current になり、書き出しまで止まる。これは advisory
            # な検査なので契約は据え置く。その代わりこの純粋な検査だけを写しで
            # 走らせ、古い確認行にも preview として見せる。行・revision・監査は
            # 一切書き換えない。新しく確認した行は Invoke 側で通常どおり永続化する。
            $legacyDelimiter = Find-YakuCatPairedDelimiterMismatch -Text ([string]$segment.Translation)
            $persistedDelimiter = @($segment.QcFindings | Where-Object { [string]$_.Code -eq 'paired-delimiter-mismatch' }).Count -gt 0
            if ($null -ne $legacyDelimiter -and -not $persistedDelimiter) {
                $qcRows.Add([pscustomobject]@{ SegmentId=[string]$segment.SegmentId; Codes=@('paired-delimiter-mismatch') }) | Out-Null
            }
            if (-not (Test-YakuCatSegmentQcCurrent -Segment $segment -TerminologySnapshotHash ([string]$Project.TerminologySnapshotHash))) {
                $reasons.Add('segment-qc-not-current') | Out-Null
            }
            continue
        }
        $unconfirmed++
        $probe = Copy-YakuCatProjectSegmentForProbe -Segment $segment
        $verdict = $null
        try { $verdict = Invoke-YakuCatSegmentValidation -Project $Project -Segment $probe } catch { $verdict = $null }
        # 同じ行が同じ種別で2件落ちても、行数は1と数える。利用者が開く行の数だから。
        $seenCodes = New-Object System.Collections.Generic.List[string]
        # 止めない種別（Severity='warning'）。**別の入れ物に分ける。**
        # 混ぜると、下の $qcFailureRows へ流れて「押せない理由」に化ける。
        $warnCodes = New-Object System.Collections.Generic.List[string]
        if ($null -ne $verdict) {
            foreach ($finding in @($verdict.Findings)) {
                $code = ([string]$finding.Code).Trim()
                if ([string]::IsNullOrWhiteSpace($code)) { continue }
                $severity = [string]$finding.Severity
                if ($severity -eq 'error') {
                    if ($seenCodes.Contains($code)) { continue }
                    $seenCodes.Add($code) | Out-Null
                } elseif ($severity -eq 'warning') {
                    if ($warnCodes.Contains($code)) { continue }
                    $warnCodes.Add($code) | Out-Null
                }
            }
        }
        if ($null -eq $verdict -or -not [bool]$verdict.Passed) {
            $reasons.Add('segment-qc-failed') | Out-Null
            # 点検そのものが落ちた（例外）ときは種別が無い。ここで空のままにすると
            # segment-qc-failed が Reasons に居るのに説明が1件も出ず、
            # 「押せないのに理由が無い」画面になる。必ず1件は積む。
            if ($seenCodes.Count -eq 0) { $seenCodes.Add('validation-unavailable') | Out-Null }
            foreach ($code in $seenCodes.ToArray()) {
                if ($qcFailureRows.Contains($code)) { $qcFailureRows[$code] = [int]$qcFailureRows[$code] + 1 }
                else { $qcFailureRows[$code] = 1 }
            }
        }
        # 行ごとの内訳。**種別だけを持つ**。用語の finding が持つ TermId や
        # SourceTerm はここへ載せない。載せると画面の点検欄が
        # 「この行では別の表現を使う」（用語の免除。訳文を書き換える操作）を
        # 未確認の行にも出せてしまい、免除の場面が黙って広がる。
        # 見ることと決めることを混ぜない。
        #
        # 警告もここへ載せる（2026-08-16）。載せないと、確定を1度も通していない
        # 行では画面に1件も出ない。行へ結果を書くのは確定時だけ（QcFindings）で、
        # 未確定の行が画面へ持つ道はこの写しだけだからである。**止める条件は
        # 1ミリも変えない。** 上の $reasons と $qcFailureRows は error だけを見る。
        $rowCodes = New-Object System.Collections.Generic.List[string]
        foreach ($code in $seenCodes.ToArray()) { $rowCodes.Add([string]$code) | Out-Null }
        foreach ($code in $warnCodes.ToArray()) { if (-not $rowCodes.Contains([string]$code)) { $rowCodes.Add([string]$code) | Out-Null } }
        if ($rowCodes.Count -gt 0) {
            $qcRows.Add([pscustomobject]@{ SegmentId=[string]$segment.SegmentId; Codes=@($rowCodes.ToArray()) }) | Out-Null
        }
    }
    $qcFailures = New-Object System.Collections.Generic.List[object]
    foreach ($code in @($qcFailureRows.Keys)) {
        $qcFailures.Add([pscustomobject]@{ Code=[string]$code; Rows=[int]$qcFailureRows[$code] }) | Out-Null
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
        UnconfirmedCount = $unconfirmed
        Reasons = @($reasons.ToArray() | Select-Object -Unique)
        # segment-qc-failed の内訳。止める条件ではなく、止まった理由の説明のための材料。
        QcFailures = @($qcFailures.ToArray())
        # 同じ内訳を行ごとに。案内文が指す「点検の指摘」を実際に開けるようにするため
        # だけのもので、これも止める条件ではない。**実セグメントへは書かない。**
        QcRows = @($qcRows.ToArray())
    }
}

function Copy-YakuCatProjectSegmentForProbe {
    <# 点検を試すためだけの写し。作業中の行には触れない（点検は状態を書き換える）。 #>
    param([Parameter(Mandatory=$true)]$Segment)
    $copy = [pscustomobject]@{}
    foreach ($property in @($Segment.PSObject.Properties)) {
        $copy | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }
    return $copy
}

function Get-YakuCatQcToolTroubleCodes {
    <#
      「利用者の訳の欠陥ではなく、道具の不調である」種別の正本。

      なぜ関数にするか（2026-08-16）。この分類はもともと下の $qcText の中に
      コメントで書いてあるだけだった。コメントは機械が読めないので、画面
      （www/assets/cat.js の qcGroup）は同じ4種のうち2種しか道具の不調として
      扱っておらず、numeric-validation-error と structure-validation-error は
      赤（訳の欠陥）で塗られていた。**直しても消えないものを赤で見せると、
      利用者は際限なく探す。**

      名前を2か所へ書き写すと、同じずれが必ず再発する。そこで顔ぶれをここ1つに
      置き、下の文言の並びも、画面との一致を見る門
      （tools/Test-YakuV9171CatQcLabelCoverage.ps1 の CASE 4）も、ここを読む。
      画面側は www/assets/cat.js の QC_TOOL_TROUBLE_CODES がこの写しにあたり、
      門は両者が**集合として一致すること**を見る。片方へ足してもう片方へ
      足し忘れたら赤になる。

      ここは**表示の分類だけ**を決める。止める条件（Get-YakuCatOutputEligibility）
      には一切効かない。道具の不調で止まった行は、色が変わっても止まったままである。
    #>
    return @(
        'numeric-validation-error',
        'structure-validation-error',
        'terminology-check-unavailable',
        'validation-unavailable'
    )
}

function Get-YakuCatQcWarningCodes {
    <#
      「書き出しを止めないが、利用者が対処できる」種別の正本。

      道具の不調（Get-YakuCatQcToolTroubleCodes）とは別である。あちらは
      直しようが無いもの、こちらは**直せるが直さなくても出せる**ものである。
      色を error と同じにすると、押せるのに押せないように見える。逆に
      道具の不調と同じにすると、自分で対処できることが伝わらない。

      顔ぶれをここ1つに置く理由は Get-YakuCatQcToolTroubleCodes と同じ。
      画面側の写しは www/assets/cat.js の QC_WARNING_CODES で、両者が集合として
      一致することを tools/Test-YakuV9171CatQcLabelCoverage.ps1 の CASE 5 が見る。

      ここは**表示の分類だけ**を決める。Get-YakuCatOutputEligibility は
      この一覧を読まない。止める条件は Severity='error' だけで決まる。
    #>
    return @(
        'label-not-in-glossary',
        'paired-delimiter-mismatch'
    )
}

function Get-YakuCatQcBlockerMessages {
    <#
      止まった行の点検結果を、種別ごとの文言へ直す。

      なぜ分けるか（2026-08-15）: Get-YakuCatOutputEligibility が返す理由は
      segment-qc-failed の1本だが、その裏では 18 種の error コードが動いている。
      1本に丸めたまま「数字の点検に通らない行があります」とだけ言うと、
      用語集で止まった利用者が数字を見に行く。何を直せば押せるようになるのかが、
      画面から永久に分からない。

      **止める条件は増やしていない。** ここは説明だけを作る。

      並びは固定にする（訳文そのもの → 数字 → 通貨 → 体裁 → 用語 → 道具の不調）。
      複数種別が同時に立つときは、立った種別を全部この順で並べる。1件に丸めると
      「数字も用語も直したのにまだ押せない」が起きる。件数を隠さないほうが、
      利用者は先に何行あるかを知って段取りできる。

      行数は #ROWS# を置き換えて入れる。`-f` を使わないのは、文言に
      「[[N1]]」のような角括弧や、将来 { } を含む例示が入っても壊れないようにするため。
    #>
    param([AllowNull()][object[]]$Failures)

    # 語り口は www/assets/cat.js の qcMessages（行ごとの指摘）と揃える。
    # 向こうは「その行を開いている人」へ、こちらは「押す前の人」へ言うので、
    # 何行あるか と どこを押せばその行に行けるか を必ず添える。
    $qcText = [ordered]@{
        'empty' = '訳文が空の行が #ROWS# 行あります。訳文を入れてから、もう一度お試しください。'
        'invalid-or-source-fallback' = '訳文が原文のままか、訳文として成立していない行が #ROWS# 行あります。左の「点検の指摘」を押すと、その行だけ表示できます。'
        'placeholder-residue' = '「[[N1]]」のような差し込み記号が残っている行が #ROWS# 行あります。左の「点検の指摘」を押して、原文の同じ位置にある数字へ手で置き換えてください。'
        'numeric-integrity' = '原文と数字または単位が合っていない行が #ROWS# 行あります。左の「点検の指摘」を押すと、その行だけ表示できます。'
        'numeric-value-mismatch' = '原文にある数字が、訳文で違う値になっているか抜けている行が #ROWS# 行あります。左の「点検の指摘」を押すと、その行だけ表示できます。'
        'numeric-value-extra' = '原文に無い数字が訳文に入っている行が #ROWS# 行あります。左の「点検の指摘」を押して、余分な数字を消してください。'
        'numeric-value-order-mismatch' = '数字の並ぶ順番が原文と違う行が #ROWS# 行あります。左の「点検の指摘」を押して、原文と同じ順番に直してください。'
        'numeric-scale-mismatch' = '数字の桁（億・百万など）が原文と合っていない行が #ROWS# 行あります。左の「点検の指摘」を押して、原文の単位をご確認ください。'
        'numeric-sign-missing' = '損失や減少を示すマイナスが訳文に入っていない行が #ROWS# 行あります。左の「点検の指摘」を押すと、その行だけ表示できます。'
        'accounting-polarity-mismatch' = '利益と損失、または増加と減少が原文と逆になっている行が #ROWS# 行あります。左の「点検の指摘」を押して、原文と見比べてください。'
        'currency-mismatch' = '通貨（円・ドルなど）が原文と合っていない行が #ROWS# 行あります。左の「点検の指摘」を押して、原文の通貨をご確認ください。'
        'structure-integrity' = '見出しや箇条書きの形が原文と違う行が #ROWS# 行あります。左の「点検の指摘」を押して、原文と見比べてください。'
        'terminology-missing' = '登録した訳語が使われていない行が #ROWS# 行あります。左の「点検の指摘」を押して、右の「用語・参考訳」に出ている訳語へ直してください。その行だけ別の言い方にしたい場合は、行の設定から外せます。'
        'terminology-forbidden' = '「使わない」と登録した表現が訳文に入っている行が #ROWS# 行あります。左の「点検の指摘」を押して、右の「用語・参考訳」に出ている訳語へ置き換えてください。'
        'terminology-conflict' = '同じ語に、必ず使う訳が2つ以上登録されています。当てはまる行が #ROWS# 行あります。「作業の管理」を開いて、どちらか一方を取り消してください。'
    }
    # 以下は利用者の訳の欠陥ではなく、道具の不調である。訳を直しても消えない。
    # 直しようのないものを「訳を見比べてください」と言うと、際限なく探させることになる。
    #
    # **顔ぶれをここへ並べない。** Get-YakuCatQcToolTroubleCodes が正本で、
    # 並び（訳文 → 数字 → 通貨 → 体裁 → 用語 → 道具の不調）はそこを読んで作る。
    # ここに置くのは種別ごとの文言だけである。ここへ文言を足しただけで正本へ
    # 登録し忘れた種別は、下の「知らない種別」の枝へ落ちて汎用文になり、
    # tools/Test-YakuV9176ExportBlockerReasons.ps1 の文言の網が赤になる。
    $toolTroubleText = @{
        'numeric-validation-error' = '数字の点検が最後まで終わらなかった行が #ROWS# 行あります。その行を開いて「確認済みにする」をもう一度押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
        'structure-validation-error' = '見出しや箇条書きの形の点検が最後まで終わらなかった行が #ROWS# 行あります。その行を開いて「確認済みにする」をもう一度押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
        'terminology-check-unavailable' = '登録した用語を読み込めなかった行が #ROWS# 行あります。いったんアプリを閉じて開き直してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
        'validation-unavailable' = '自動点検が最後まで終わらなかった行が #ROWS# 行あります。その行を開いて「確認済みにする」をもう一度押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
    }
    foreach ($toolCode in @(Get-YakuCatQcToolTroubleCodes)) {
        $toolKey = ([string]$toolCode).Trim()
        if ([string]::IsNullOrWhiteSpace($toolKey)) { continue }
        if ($qcText.Contains($toolKey)) { continue }
        if (-not $toolTroubleText.ContainsKey($toolKey)) { continue }
        $qcText[$toolKey] = [string]$toolTroubleText[$toolKey]
    }

    $rowsByCode = @{}
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($failure in @($Failures)) {
        if ($null -eq $failure) { continue }
        $code = ([string]$failure.Code).Trim()
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'validation-unavailable' }
        $rows = 0
        try { $rows = [int]$failure.Rows } catch { $rows = 0 }
        if ($rows -lt 1) { $rows = 1 }
        if ($rowsByCode.ContainsKey($code)) { $rowsByCode[$code] = [int]$rowsByCode[$code] + $rows }
        else { $rowsByCode[$code] = $rows; $order.Add($code) | Out-Null }
    }

    $result = New-Object System.Collections.Generic.List[object]
    # まず既知の種別を決めた順で。知らない種別（点検が増えたのに、ここへ書き足す
    # のを忘れたとき）は落とさずに最後へ回す。落とすと、押せない理由が消える。
    $emitted = New-Object System.Collections.Generic.List[string]
    foreach ($code in @($qcText.Keys)) {
        $key = [string]$code
        if (-not $rowsByCode.ContainsKey($key)) { continue }
        $message = ([string]$qcText[$key]).Replace('#ROWS#', [string][int]$rowsByCode[$key])
        $result.Add([pscustomobject]@{ Code=$key; Rows=[int]$rowsByCode[$key]; Message=$message }) | Out-Null
        $emitted.Add($key) | Out-Null
    }
    foreach ($code in $order.ToArray()) {
        if ($emitted.Contains([string]$code)) { continue }
        $message = '自動点検に通らない行が ' + [string][int]$rowsByCode[[string]$code] + ' 行あります。左の「点検の指摘」を押すと、その行だけ表示できます。'
        $result.Add([pscustomobject]@{ Code=[string]$code; Rows=[int]$rowsByCode[[string]$code]; Message=$message }) | Out-Null
    }
    return $result.ToArray()
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
        'segment-not-reviewed' = 'まだ確認していない行があります。左の「残り」を押すと、その行だけ表示できます。'
        # segment-qc-failed はここでは作らない。18種を1文に丸めると
        # 「用語で止まったのに数字を見に行かされる」ため、
        # Get-YakuCatQcBlockerMessages が種別ごとの文へ分ける。
        'segment-qc-not-current' = '訳文を直したあと、まだ自動点検をしていない行があります。その行を「確認済みにする」と点検します。'
        'segment-untranslated' = '訳文が空の行があります。'
        'source-file-missing' = '元のファイルが見つかりません。'
        'word-unsupported-structure' = '体裁を安全に保てないWord要素があります。'
    }
    # 種別ごとの文言。理由が segment-qc-failed のときだけ、ここへ差し替える。
    $qcMessages = @(Get-YakuCatQcBlockerMessages -Failures @($eligibility.QcFailures))
    $blockers = @(
        foreach ($reason in @($eligibility.Reasons)) {
            # 1つの理由から複数の項目が出る（点検の種別ぶん）。
            # 種別が1件も取れなかったときでも、押せない理由を黙らせない。
            $items = @(
                if ([string]$reason -eq 'segment-qc-failed') {
                    if ($qcMessages.Count -gt 0) { $qcMessages }
                    else { [pscustomobject]@{ Code='validation-unavailable'; Rows=0; Message='自動点検に通らない行があります。左の「点検の指摘」を押すと、その行だけ表示できます。' } }
                } else {
                    $text = if ($reasonText.Contains([string]$reason)) { [string]$reasonText[[string]$reason] } else { '出力条件を満たしていません。' }
                    [pscustomobject]@{ Code=''; Rows=0; Message=$text }
                }
            )
            foreach ($item in $items) {
                if ($mode -eq 'blocked') {
                    # code は従来どおり理由コードのまま。何で止まったかを機械が読む鍵は
                    # 変えない。種別は qc_code に足す（増やすだけ、置き換えない）。
                    [ordered]@{ code = [string]$reason; qc_code = [string]$item.Code; rows = [int]$item.Rows; message = [string]$item.Message }
                } else {
                    # Word体裁出力から訳文コピーへ安全に縮退できた理由は、
                    # 実行を妨げるblockerではなく利用者へ伝えるwarningである。
                    $warnings.Add([string]$item.Message) | Out-Null
                }
            }
        }
    )

    $outputName = ''
    if ($mode -in @('word_draft','excel_draft')) {
        # project 配下の原本は安全のため original.ext という固定名で置いている。
        # 押す前に見せる名前をそこから作ると、実際にできるファイル
        # （Get-YakuCatDraftOutputPath が FileName から作る）と食い違い、
        # 画面には DRAFT_original_translated.xlsx と出て
        # DRAFT_yaku-seltest_translated.xlsx ができていた（2026-08-11、実機）。
        $sourceName = $(try { [IO.Path]::GetFileNameWithoutExtension([string]$Project.FileName) } catch { '' })
        if ([string]::IsNullOrWhiteSpace($sourceName)) { $sourceName = $(try { [IO.Path]::GetFileNameWithoutExtension([string]$Project.Path) } catch { 'translated' }) }
        if ([string]::IsNullOrWhiteSpace($sourceName)) { $sourceName = 'translated' }
        $safeName = ($sourceName -replace '[\\/:*?"<>|]', '_').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'translated' }
        $extension = if ([string]::IsNullOrWhiteSpace($format)) { '' } else { '.' + $format }
        $outputName = 'DRAFT_' + $safeName + '_translated' + $extension
    } elseif ($mode -eq 'copy_text') {
        $outputName = '訳文'
    }

    # 未確認のまま出せるようにした以上、何行が未確認かは押す前に必ず言う。
    # 数を言わずに出すと、確認し終えたものと見分けがつかなくなる。
    $unconfirmedCount = [int]$eligibility.UnconfirmedCount
    # 出す先はファイルとは限らない。copy_text はクリップボードへ写すだけなので、
    # 「ファイルに入れます」と言うと、作られていないものを作ったと伝えることになる
    # （2026-08-13、初回利用者として実機で確認。出力名も「訳文」だった）。
    if ($mode -ne 'blocked' -and $unconfirmedCount -gt 0) {
        $destination = if ($mode -eq 'copy_text') { 'そのままコピーに入れます。' } else { 'そのままファイルに入れます。' }
        $warnings.Add(('まだ確認していない行が ' + $unconfirmedCount + ' 行あります。' + $destination)) | Out-Null
    }

    return [pscustomobject]@{
        ProjectId = [string]$Project.Id
        Revision = [int]$Project.Revision
        Eligible = ($mode -ne 'blocked')
        Mode = $mode
        OutputName = $outputName
        UnconfirmedCount = $unconfirmedCount
        Blockers = @($blockers)
        Warnings = @($warnings.ToArray())
        # ファイルの中の印を外したので（2026-08-13）、形式ごとに書き分けるものが
        # 無くなった。言うのは「原本は触らない」「別名のコピーができる」の2つだけ。
        DraftNotice = if ($mode -eq 'word_draft' -or $mode -eq 'excel_draft') { '原本はそのままで、訳文を入れたコピーを作ります。名前の先頭に「DRAFT_」が付きます。' }
                      else { '' }
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

function New-YakuCatTextSourceStructure {
    <# 貼り付け本文を、翻訳単位へ分けても改行・空行・箇条書きを失わない形で保持する。 #>
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][object[]]$Segments
    )
    $normalized = ([string]$Text).Replace("`r`n", "`n").Replace("`r", "`n")
    $positions = New-Object System.Collections.Generic.List[object]
    $cursor = 0
    foreach ($segment in @($Segments)) {
        $source = [string]$segment.Text
        $start = $normalized.IndexOf($source, $cursor, [StringComparison]::Ordinal)
        if ($start -lt 0) { throw 'CAT_TEXT_STRUCTURE_UNMAPPED: 貼り付け本文と翻訳単位を対応付けられません。' }
        [void]$positions.Add([pscustomobject]@{
            SegmentId = [string]$segment.SegmentId
            Start = [int]$start
            Length = [int]$source.Length
        })
        $cursor = $start + $source.Length
    }
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $positions.Count; $i++) {
        $position = $positions[$i]
        $end = [int]$position.Start + [int]$position.Length
        $nextStart = if ($i + 1 -lt $positions.Count) { [int]$positions[$i + 1].Start } else { $normalized.Length }
        $separator = if ($nextStart -gt $end) { $normalized.Substring($end, $nextStart - $end) } else { '' }
        $prefix = if ($i -eq 0 -and [int]$position.Start -gt 0) { $normalized.Substring(0, [int]$position.Start) } else { '' }
        $sourceSlice = $normalized.Substring([int]$position.Start, [int]$position.Length)
        $listMarker = ''
        $markerMatch = [regex]::Match($sourceSlice, '^(?<marker>\s*(?:[・●○■□◆◇▶▷※]|[-*+]\s+|\d+[.)]\s+))')
        if ($markerMatch.Success) { $listMarker = [string]$markerMatch.Groups['marker'].Value }
        [void]$blocks.Add([pscustomobject]@{
            BlockId = [string]$position.SegmentId
            SegmentId = [string]$position.SegmentId
            RawStart = [int]$position.Start
            RawLength = [int]$position.Length
            TextHash = Get-YakuCatSourceIntegrityHash -Text $normalized.Substring([int]$position.Start, [int]$position.Length)
            Prefix = $prefix
            ListMarker = $listMarker
            Suffix = ''
            SeparatorAfter = $separator
        })
    }
    return [pscustomobject]@{
        RawText = $normalized
        RawTextHash = Get-YakuCatSourceIntegrityHash -Text $normalized
        IndexKind = 'utf16-code-unit'
        Newline = 'lf'
        EndsWithNewline = $normalized.EndsWith("`n", [StringComparison]::Ordinal)
        Blocks = @($blocks.ToArray())
        ContractVersion = 'cat-text-source-v1'
    }
}

function Get-YakuCatTextOutput {
    param([Parameter(Mandatory=$true)]$Project)
    $segments = @($Project.Segments)
    $structure = $(try { $Project.TextSourceStructure } catch { $null })
    if ($null -eq $structure -or [string]$structure.ContractVersion -ne 'cat-text-source-v1') {
        return (@($segments | ForEach-Object { [string]$_.Translation }) -join "`n")
    }
    $byId = @{}
    # 貼り付け本文の構造は、取り込んだときの行の識別子で書いてある。
    # 途中で分けた行・分けてから戻した行は、その構造の中では元の1つとして扱う
    # （繋いで1つの訳文にしてから、元の位置へ置く）。
    foreach ($unit in @(Group-YakuCatSplitSegments -Segments $segments)) {
        $unitSegment = $unit.Segment
        $byId[[string]$unitSegment.SegmentId] = [string]$unitSegment.Translation
        $originId = [string]$(try { $unitSegment.SplitOriginSegmentId } catch { '' })
        if (-not [string]::IsNullOrWhiteSpace($originId)) { $byId[$originId] = [string]$unitSegment.Translation }
    }
    $builder = New-Object Text.StringBuilder
    foreach ($block in @($structure.Blocks)) {
        $segmentId = [string]$block.SegmentId
        if (-not $byId.ContainsKey($segmentId)) {
            return (@($segments | ForEach-Object { [string]$_.Translation }) -join "`n")
        }
        [void]$builder.Append([string]$block.Prefix)
        $translated = [string]$byId[$segmentId]
        $listMarker = [string]$(try { $block.ListMarker } catch { '' })
        if (-not [string]::IsNullOrEmpty($listMarker) -and $translated -notmatch '^\s*(?:[・●○■□◆◇▶▷※]|[-*+]\s+|\d+[.)]\s+)') {
            [void]$builder.Append($listMarker)
        }
        [void]$builder.Append($translated)
        [void]$builder.Append([string]$block.Suffix)
        [void]$builder.Append([string]$block.SeparatorAfter)
    }
    return $builder.ToString()
}

function Split-YakuPublicationTextAcrossCells {
    <# 掲載sliceを連結すると、空白も含めて必ず元の掲載訳へ戻る。 #>
    param([AllowNull()][string]$Text, [Parameter(Mandatory=$true)][AllowEmptyCollection()][int[]]$Weights)
    $value = [string]$Text
    $weightsList = @($Weights)
    if ($weightsList.Count -eq 0) { return @() }
    if ($weightsList.Count -eq 1) { return @($value) }
    if ([string]::IsNullOrEmpty($value)) { return @($weightsList | ForEach-Object { '' }) }
    $total = 0
    foreach ($weight in $weightsList) { $total += [Math]::Max(1, [int]$weight) }
    $parts = New-Object System.Collections.Generic.List[string]
    $position = 0
    $cumulative = 0
    for ($i = 0; $i -lt ($weightsList.Count - 1); $i++) {
        $cumulative += [Math]::Max(1, [int]$weightsList[$i])
        $near = [int][Math]::Round(($value.Length * $cumulative) / $total)
        if ($near -le $position) { $near = $position }
        $cut = Find-YakuBreakPosition -Text $value -Near $near -Min ($position + 1)
        if ($cut -lt $position) { $cut = $position }
        if ($cut -gt $value.Length) { $cut = $value.Length }
        $parts.Add($value.Substring($position, $cut - $position)) | Out-Null
        $position = $cut
    }
    $parts.Add($value.Substring($position)) | Out-Null
    return @($parts.ToArray())
}

function Update-YakuCatPlacementSetHash {
    param([Parameter(Mandatory=$true)]$Project)
    $json = (@($Project.PlacementPlans) | ConvertTo-Json -Depth 14 -Compress)
    $Project.PlacementSetHash = Get-YakuCatSourceIntegrityHash -Text $json
    return $Project.PlacementSetHash
}

function Get-YakuCatPlacementPlanHash {
    param([Parameter(Mandatory=$true)]$Plan)
    return Get-YakuCatSourceIntegrityHash -Text (($Plan|Select-Object * -ExcludeProperty plan_hash)|ConvertTo-Json -Depth 12 -Compress)
}

function Test-YakuCatPlacementPlanBinding {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Segment,
        [Parameter(Mandatory=$true)]$Plan,
        [switch]$AllowPublicationMismatch
    )
    $reasons=New-Object System.Collections.Generic.List[string]
    if([string]$Plan.plan_hash -ne (Get-YakuCatPlacementPlanHash -Plan $Plan)){$reasons.Add('plan_hash')|Out-Null}
    if([string]$Plan.source_snapshot_id -ne [string]$Project.ActiveSourceId){$reasons.Add('source_snapshot')|Out-Null}
    $sourceHash=Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Text)
    if([string]$Plan.source_contract.source_hash -ne $sourceHash -or [int]$Plan.source_contract.source_revision -ne [int]$Segment.SourceRevision){$reasons.Add('source_contract')|Out-Null}
    $ids=@($Segment.BlockIds|ForEach-Object{[string]$_});$contractIds=@($Plan.source_contract.block_ids|ForEach-Object{[string]$_});$destinations=@($Plan.destinations)
    $sourceDestinations=@($destinations|Where-Object{[string]$(try{$_.mode}catch{'replace_source_block'}) -ne 'use_confirmed_empty'})
    $emptyDestinations=@($destinations|Where-Object{[string]$(try{$_.mode}catch{''}) -eq 'use_confirmed_empty'})
    if(($ids -join '|') -cne ($contractIds -join '|') -or $sourceDestinations.Count -ne $ids.Count){$reasons.Add('block_ids')|Out-Null}
    if(@($destinations|ForEach-Object{[string]$_.sheet+'!'+[string]$_.address}|Select-Object -Unique).Count -ne $destinations.Count){$reasons.Add('duplicate_destination')|Out-Null}
    $cells=@($Segment.Cells)
    for($i=0;$i -lt $sourceDestinations.Count;$i++){
        $destination=$sourceDestinations[$i];$cell=$(if($i -lt $cells.Count){$cells[$i]}else{$null});$cellText=$(if($null -ne $cell){[string]$cell.Text}else{''});$address=$(if($null -ne $cell){[string]$cell.Address}else{''})
        if($i -ge $ids.Count -or [string]$destination.block_id -cne [string]$ids[$i] -or [string]$destination.sheet -cne [string]$Segment.Sheet -or [string]$destination.address -cne $address){$reasons.Add('destination_identity')|Out-Null;continue}
        if([string]$destination.expected_source_hash -ne (Get-YakuCatSourceIntegrityHash -Text $cellText) -or [string]$destination.expected_cell_fingerprint -ne (Get-YakuCatSourceIntegrityHash -Text ($ids[$i]+'|'+$cellText))){$reasons.Add('cell_fingerprint')|Out-Null}
        $cellStructure=$(try{[string]$cell.StructureFingerprint}catch{''});$expectedStructure=$(try{[string]$destination.expected_structure_fingerprint}catch{''})
        $requiresExcelStructure=([string]$Project.Source -eq 'file' -and [string]$Project.DocumentFormat -in @('xlsx','xlsm'))
        if($requiresExcelStructure -and ([string]::IsNullOrWhiteSpace($expectedStructure) -or [string]::IsNullOrWhiteSpace($cellStructure))){$reasons.Add('structure_fingerprint_missing')|Out-Null}
        elseif(-not [string]::IsNullOrWhiteSpace($expectedStructure) -and $expectedStructure -ne $cellStructure){$reasons.Add('structure_fingerprint')|Out-Null}
    }
    foreach($destination in $emptyDestinations){
        if([string]::IsNullOrWhiteSpace([string]$destination.block_id) -or [string]::IsNullOrWhiteSpace([string]$destination.sheet) -or [string]::IsNullOrWhiteSpace([string]$destination.address)){$reasons.Add('empty_destination_identity')|Out-Null}
        if([string]$destination.expected_source_hash -ne (Get-YakuCatSourceIntegrityHash -Text '')){$reasons.Add('empty_destination_source')|Out-Null}
        if([string]::IsNullOrWhiteSpace([string]$(try{$destination.expected_structure_fingerprint}catch{''})) -or $null -eq $(try{$destination.structure_contract}catch{$null})){$reasons.Add('empty_destination_structure')|Out-Null}
    }
    if(-not $AllowPublicationMismatch){
        $publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $Segment}else{[pscustomobject]@{Text=[string]$Segment.Translation;TextHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation));VariantId='';VariantRevision=0;VariantHash=''}})
        $canonicalHash=Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation)
        if([string]$Plan.publication_text_hash -ne [string]$publication.TextHash -or [string]$Plan.source_contract.canonical_target_hash -ne $canonicalHash -or [string]$Plan.source_contract.publication_variant_id -cne [string]$publication.VariantId -or [int]$Plan.source_contract.publication_variant_revision -ne [int]$publication.VariantRevision -or [string]$Plan.source_contract.publication_variant_hash -cne [string]$publication.VariantHash){$reasons.Add('publication_binding')|Out-Null}
        if((@($destinations|ForEach-Object{[string]$_.text}) -join '') -cne [string]$publication.Text){$reasons.Add('slice_reconstruction')|Out-Null}
    }
    return [pscustomobject]@{Passed=($reasons.Count -eq 0);Reasons=@($reasons.ToArray())}
}

function Assert-YakuCatPlacementPlanBinding {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Segment,[Parameter(Mandatory=$true)]$Plan,[switch]$AllowPublicationMismatch)
    $result=Test-YakuCatPlacementPlanBinding -Project $Project -Segment $Segment -Plan $Plan -AllowPublicationMismatch:$AllowPublicationMismatch
    if(-not [bool]$result.Passed){throw ('CAT_PLACEMENT_PRECONDITION_FAILED: '+(@($result.Reasons)-join ','))}
    return $true
}

function Get-YakuCatPlacementUnits {
    <#
      配置計画の単位を返す。ふつうは行そのもの。

      任意位置で割った行は、元の1つのセルを指すので、ここで1つへ畳む。
      畳まないと、同じセルを2つの配置先が名指しすることになり、
      Export-YakuCatProject が CAT_PLACEMENT_PRECONDITION_FAILED で止まる。

      畳む前に、行ごとの掲載訳（Publication）まで解決してから繋ぐ。
      掲載訳は行ごとに作れるので、繋いでからでは拾えない。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $segments = @($Project.Segments)
    $units = New-Object System.Collections.Generic.List[object]
    foreach ($unit in @(Group-YakuCatSplitSegments -Segments $segments)) {
        if (-not [bool]$unit.IsSplitGroup) { [void]$units.Add($unit); continue }
        $texts = @(@($unit.Indices) | ForEach-Object {
            $part = $segments[$_]
            if (Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue) { [string](Resolve-YakuCatPublicationText -Project $Project -Segment $part).Text }
            else { [string]$part.Translation }
        })
        # 原文も渡す。境目がトークンの内側（`AB-` ＋ `1234`）だった箇所へ
        # 空白を入れると、数値QCに掛からないまま配置計画・書き出しへ流れる。
        $unit.Segment.Translation = (Join-YakuCatSplitTranslations -Parts $texts -Sources @(@($unit.Indices) | ForEach-Object { [string]$segments[$_].Text }))
        [void]$units.Add($unit)
    }
    # Group-YakuCatSplitSegments と同じ理由で `,` を付けない。呼ぶ側が @() で受ける。
    return @($units.ToArray())
}

function Sync-YakuCatPlacementPlans {
    <# 意味単位の訳文と、各掲載セルへ置くsliceを分離して永続化する。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $existingBySegment = @{}
    foreach ($plan in @($Project.PlacementPlans)) {
        $segmentKey=[string]$plan.segment_id
        if($existingBySegment.ContainsKey($segmentKey)){throw 'CAT_PLACEMENT_PLAN_DUPLICATE: 同じ翻訳単位に複数の配置計画があります。安全のため処理を停止しました。'}
        $existingBySegment[$segmentKey] = $plan
    }
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($segment in @(@(Get-YakuCatPlacementUnits -Project $Project) | ForEach-Object { $_.Segment })) {
        $ids = @($segment.BlockIds | ForEach-Object { [string]$_ })
        $publication = $(if (Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue) { Resolve-YakuCatPublicationText -Project $Project -Segment $segment } else { [pscustomobject]@{Text=[string]$segment.Translation;TextHash=(Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Translation));VariantId='';VariantRevision=0;VariantHash=''} })
        $target = [string]$publication.Text
        if ([string]$segment.Kind -ne 'cell' -or $ids.Count -eq 0 -or [string]::IsNullOrWhiteSpace($target)) { continue }
        $targetHash = Get-YakuCatSourceIntegrityHash -Text $target
        $sourceHash = Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Text)
        $old = $existingBySegment[[string]$segment.SegmentId]
        $same = $false
        if($null -ne $old){$same=[bool](Test-YakuCatPlacementPlanBinding -Project $Project -Segment $segment -Plan $old).Passed}
        if ($same) { $plans.Add($old) | Out-Null; continue }
        if ($null -ne $old -and [string]$old.placement_kind -eq 'human_confirmed') {
            $old.status = 'stale';$old.plan_hash=Get-YakuCatPlacementPlanHash -Plan $old;$plans.Add($old) | Out-Null; continue
        }
        $cells = @($segment.Cells)
        $weights = @($cells | ForEach-Object { [Math]::Max(1, ([string]$_.Text).Trim().Length) })
        if ($weights.Count -ne $ids.Count) { $weights = @($ids | ForEach-Object { 1 }) }
        [string[]]$parts = if ($ids.Count -eq 1) { @($target) } else { @(Split-YakuPublicationTextAcrossCells -Text $target -Weights $weights) }
        $destinations = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $cell = $(if($i -lt $cells.Count){$cells[$i]}else{$null})
            $sourceCellText = $(if($null -ne $cell){[string]$cell.Text}else{''})
            $structureFingerprint=$(try{[string]$cell.StructureFingerprint}catch{''})
            $structureContract=$(try{$cell.StructureContract}catch{$null})
            $sheetCodeName=$(try{[string]$cell.SheetCodeName}catch{''})
            $destinations.Add([pscustomobject]@{
                block_id=$ids[$i]; sheet=[string]$segment.Sheet; address=$(if($null -ne $cell){[string]$cell.Address}else{''})
                text=$(if($i -lt $parts.Count){[string]$parts[$i]}else{''}); expected_source_hash=(Get-YakuCatSourceIntegrityHash -Text $sourceCellText)
                expected_cell_fingerprint=(Get-YakuCatSourceIntegrityHash -Text ($ids[$i] + '|' + $sourceCellText)); expected_sheet_code_name=$sheetCodeName
                expected_structure_fingerprint=$structureFingerprint; structure_contract=$structureContract
                merge_contract=[pscustomobject]@{expected_kind=$(try{[string]$structureContract.merge_kind}catch{'unknown'});expected_area=$(try{[string]$structureContract.merge_area}catch{''});write_anchor_address=$(if($null -ne $cell){[string]$cell.Address}else{''})}
                mode='replace_source_block'
            }) | Out-Null
        }
        $revision = $(if($null -ne $old){[int]$old.placement_revision + 1}else{1})
        $newPlan = [pscustomobject]@{
            placement_id=(Get-YakuCatSourceIntegrityHash -Text ('placement-v1|' + [string]$Project.Id + '|' + [string]$segment.SegmentId)).Substring(0,32)
            segment_id=[string]$segment.SegmentId; source_snapshot_id=[string]$Project.ActiveSourceId; placement_revision=$revision
            placement_kind='auto_weighted'; status='draft'; publication_text_hash=$targetHash
            source_contract=[pscustomobject]@{ source_hash=$sourceHash; source_revision=[int]$segment.SourceRevision; canonical_target_hash=(Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Translation)); publication_variant_id=[string]$publication.VariantId; publication_variant_revision=[int]$publication.VariantRevision; publication_variant_hash=[string]$publication.VariantHash; block_ids=$ids }
            destinations=@($destinations.ToArray()); display_regions=@(); layout_adjustments=@(); created_at=(Get-Date).ToString('o')
            plan_hash=''
        }
        $newPlan.plan_hash = Get-YakuCatSourceIntegrityHash -Text (($newPlan | Select-Object * -ExcludeProperty plan_hash) | ConvertTo-Json -Depth 12 -Compress)
        $plans.Add($newPlan) | Out-Null
    }
    $Project.PlacementPlans = @($plans.ToArray())
    return (Update-YakuCatPlacementSetHash -Project $Project)
}

function Get-YakuCatPlacementTranslationByBlockId {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)][hashtable]$TranslationBySegmentIndex)
    $null = Sync-YakuCatPlacementPlans -Project $Project
    $map = @{}
    $plansBySegment = @{}; foreach($plan in @($Project.PlacementPlans)){$plansBySegment[[string]$plan.segment_id]=$plan}
    foreach($unit in @(Get-YakuCatPlacementUnits -Project $Project)){
        $indices=@($unit.Indices)
        $present=@($indices|Where-Object{$TranslationBySegmentIndex.ContainsKey($_)})
        if($present.Count -eq 0){continue}
        # 割った行は元の1セルへ戻すので、片方だけ訳が入っている状態では書けない。
        # 黙って半分だけ書くと、原文の半分が消えた資料ができる。
        if($present.Count -ne $indices.Count){throw 'CAT_PLACEMENT_SPLIT_INCOMPLETE: 途中で分けた行のどれかに訳文がありません。'}
        $segment=$unit.Segment; $plan=$plansBySegment[[string]$segment.SegmentId]
        if($null -eq $plan){continue}
        if([string]$plan.source_snapshot_id -ne [string]$Project.ActiveSourceId){throw 'CAT_PLACEMENT_SOURCE_SNAPSHOT_MISMATCH'}
        if([string]$plan.status -eq 'stale'){throw 'CAT_PLACEMENT_STALE: 掲載訳が変わったため、セルへの配置を確認してください。'}
        $null=Assert-YakuCatPlacementPlanBinding -Project $Project -Segment $segment -Plan $plan
        $publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $segment}else{[pscustomobject]@{Text=[string]$segment.Translation}})
        if([string]$plan.publication_text_hash -ne (Get-YakuCatSourceIntegrityHash -Text ([string]$publication.Text))){throw 'CAT_PLACEMENT_TARGET_MISMATCH'}
        foreach($destination in @($plan.destinations)){
            if([string]$(try{$destination.mode}catch{'replace_source_block'}) -eq 'use_confirmed_empty'){continue}
            $map[[string]$destination.block_id]=[string]$destination.text
        }
    }
    return $map
}

function Get-YakuCatRightSpillDisplayRegion {
    <#
      Excelの「右セルが空なら文字が見た目上はみ出す」挙動を、セル結合や書込みと
      混同せず表示領域として記録する。静的検査は候補の安全条件までで、収容の最終
      判断は実PDFを人が確認する。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Plan,
        [ValidateRange(0,3)][int]$CellCount = 0
    )
    if ($CellCount -eq 0) { return @() }
    if ([string]$Project.Source -ne 'file' -or [string]$Project.DocumentFormat -notin @('xlsx','xlsm')) { throw 'CAT_PLACEMENT_SPILL_EXCEL_REQUIRED' }
    $destinations=@($Plan.destinations|Where-Object{[string]$(try{$_.mode}catch{'replace_source_block'}) -ne 'use_confirmed_empty'})
    if($destinations.Count -ne 1){throw 'CAT_PLACEMENT_SPILL_SINGLE_CELL_REQUIRED: 右の空白を使えるのは、現在は1セルの行だけです。'}
    $anchor=$destinations[0];$coord=Convert-YakuA1ToCoord -Address ([string]$anchor.address)
    if($null -eq $coord){throw 'CAT_PLACEMENT_SPILL_ADDRESS_INVALID'}
    $structure=$(try{$anchor.structure_contract}catch{$null})
    if($null -eq $structure -or [string]$structure.wrap_text -notin @('False','false','0')){throw 'CAT_PLACEMENT_SPILL_WRAP_UNVERIFIED: 折り返しなしを確認できるセルだけ、右の空白を表示領域にできます。'}
    $layouts=@(Get-YakuSheetLayoutFromXlsx -Path ([string]$Project.Path));$layout=@($layouts|Where-Object{[string]$_.name -ceq [string]$anchor.sheet}|Select-Object -First 1)
    if($layout.Count -ne 1){throw 'CAT_PLACEMENT_SPILL_LAYOUT_UNAVAILABLE'}
    $occupied=@{};foreach($address in @($layout[0].occupied_cells)){$occupied[[string]$address]=$true}
    $formula=@{};foreach($address in @($layout[0].formula_cells)){$formula[[string]$address]=$true}
    $addresses=New-Object System.Collections.Generic.List[string]
    for($offset=1;$offset -le $CellCount;$offset++){
        $column=[int]$coord.Col+$offset;$address=(Convert-YakuColumnNumberToName -Column $column)+[string]$coord.Row
        if($occupied.ContainsKey($address) -or $formula.ContainsKey($address)){throw ('CAT_PLACEMENT_SPILL_CELL_OCCUPIED: '+$address+' に値または数式があります。')}
        foreach($columnSpec in @($layout[0].columns)){if($column -ge [int]$columnSpec.min -and $column -le [int]$columnSpec.max -and [bool]$columnSpec.hidden){throw ('CAT_PLACEMENT_SPILL_CELL_HIDDEN: '+$address+' は非表示列です。')}}
        foreach($mergeRef in @($layout[0].merges)){
            $range=@([string]$mergeRef -split ':');$start=Convert-YakuA1ToCoord -Address $range[0];$end=$(if($range.Count -gt 1){Convert-YakuA1ToCoord -Address $range[1]}else{$start})
            if($null -ne $start -and $null -ne $end -and [int]$coord.Row -ge [int]$start.Row -and [int]$coord.Row -le [int]$end.Row -and $column -ge [int]$start.Col -and $column -le [int]$end.Col){throw ('CAT_PLACEMENT_SPILL_CELL_MERGED: '+$address+' は結合範囲です。')}
        }
        $addresses.Add($address)|Out-Null
    }
    $snapshot=@($Project.SourceSnapshots|Where-Object{[string]$_.source_snapshot_id -eq [string]$Project.ActiveSourceId}|Select-Object -First 1)
    $layoutHash=$(if($snapshot.Count -eq 1){[string]$snapshot[0].layout_hash}else{''})
    $corridorHash=Get-YakuCatSourceIntegrityHash -Text ('spill-right-v1|'+[string]$Project.ActiveSourceId+'|'+$layoutHash+'|'+[string]$anchor.sheet+'|'+[string]$anchor.address+'|'+(@($addresses.ToArray()) -join ','))
    return @([pscustomobject]@{
        mode='spill_right_display_only';sheet=[string]$anchor.sheet;anchor_address=[string]$anchor.address
        cells=@($addresses.ToArray());corridor_fingerprint=$corridorHash;verification='requires_pdf_visual_review'
    })
}

function Test-YakuCatExcelCellShapeOverlap {
    param([Parameter(Mandatory=$true)]$Worksheet,[Parameter(Mandatory=$true)][int]$Row,[Parameter(Mandatory=$true)][int]$Col)
    $shapes=$null
    try{
        $shapes=$Worksheet.Shapes;$count=[int]$shapes.Count
        for($i=1;$i -le $count;$i++){
            $shape=$null;$topLeft=$null;$bottomRight=$null
            try{
                $shape=$shapes.Item($i);$topLeft=$shape.TopLeftCell;$bottomRight=$shape.BottomRightCell
                if($null -eq $topLeft -or $null -eq $bottomRight){throw 'shape_bounds_unavailable'}
                if($Row -ge [int]$topLeft.Row -and $Row -le [int]$bottomRight.Row -and $Col -ge [int]$topLeft.Column -and $Col -le [int]$bottomRight.Column){return $true}
            }catch{if($_.Exception.Message -eq 'shape_bounds_unavailable'){throw};throw 'CAT_PLACEMENT_EMPTY_SHAPE_BOUNDS_UNAVAILABLE'}
            finally{Release-YakuComObject $bottomRight;Release-YakuComObject $topLeft;Release-YakuComObject $shape}
        }
        return $false
    }catch{if($_.Exception.Message -like 'CAT_PLACEMENT_EMPTY_*'){throw};throw 'CAT_PLACEMENT_EMPTY_SHAPE_ENUM_UNAVAILABLE'}
    finally{Release-YakuComObject $shapes}
}

function Get-YakuCatExcelConfirmedEmptyCellSnapshot {
    <# 空白の推測はしない。値・構造・非表示・図形を実Workbook COMから読む。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][string]$Sheet,
        [Parameter(Mandatory=$true)][string]$Address,
        [Parameter(Mandatory=$true)][int]$Ordinal
    )
    $coord=Convert-YakuA1ToCoord -Address $Address;if($null -eq $coord){throw 'CAT_PLACEMENT_EMPTY_ADDRESS_INVALID'}
    $cell=$null
    try{
        $cell=$Worksheet.Range($Address);$value=''
        try{$value=[string]$cell.Value2}catch{throw 'CAT_PLACEMENT_EMPTY_VALUE_UNAVAILABLE'}
        if(-not [string]::IsNullOrEmpty($value)){throw ('CAT_PLACEMENT_EMPTY_CELL_OCCUPIED: '+$Sheet+'!'+$Address)}
        $structureResult=Get-YakuExcelCellStructureContract -Worksheet $Worksheet -Row ([int]$coord.Row) -Col ([int]$coord.Col)
        $structure=$structureResult.Contract;$null=Assert-YakuCatExcelPlacementStructureSafe -Structure $structure -BlockId ($Sheet+'!'+$Address)
        if([string]$structure.merge_kind -ne 'none'){throw ('CAT_PLACEMENT_EMPTY_CELL_MERGED: '+$Sheet+'!'+$Address)}
        if([string]$structure.row_hidden -ne 'False' -or [string]$structure.column_hidden -ne 'False'){throw ('CAT_PLACEMENT_EMPTY_CELL_HIDDEN: '+$Sheet+'!'+$Address)}
        if(Test-YakuCatExcelCellShapeOverlap -Worksheet $Worksheet -Row ([int]$coord.Row) -Col ([int]$coord.Col)){throw ('CAT_PLACEMENT_EMPTY_CELL_SHAPE_OVERLAP: '+$Sheet+'!'+$Address)}
        $sheetCodeName='';try{$sheetCodeName=[string]$Worksheet.CodeName}catch{$sheetCodeName=''}
        $blockId='confirmed-empty|'+(Get-YakuCatSourceIntegrityHash -Text ('confirmed-empty-v1|'+[string]$Project.ActiveSourceId+'|'+$Sheet+'|'+$Address)).Substring(0,32)
        return [pscustomobject]@{
            block_id=$blockId;sheet=$Sheet;address=$Address;text='';expected_source_hash=(Get-YakuCatSourceIntegrityHash -Text '')
            expected_cell_fingerprint=(Get-YakuCatSourceIntegrityHash -Text ($blockId+'|'));expected_sheet_code_name=$sheetCodeName
            expected_structure_fingerprint=[string]$structureResult.Fingerprint;structure_contract=$structure
            merge_contract=[pscustomobject]@{expected_kind='none';expected_area='';write_anchor_address=$Address}
            mode='use_confirmed_empty';empty_selection_ordinal=$Ordinal
        }
    }finally{Release-YakuComObject $cell}
}

function Get-YakuCatConfirmedEmptyDownDestinations {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Plan,[ValidateRange(0,3)][int]$CellCount=0)
    if($CellCount -eq 0){return @()}
    if([string]$Project.Source -ne 'file' -or [string]$Project.DocumentFormat -notin @('xlsx','xlsm')){throw 'CAT_PLACEMENT_EMPTY_EXCEL_REQUIRED'}
    $anchors=@($Plan.destinations|Where-Object{[string]$(try{$_.mode}catch{'replace_source_block'}) -ne 'use_confirmed_empty'})
    if($anchors.Count -eq 0){throw 'CAT_PLACEMENT_EMPTY_ANCHOR_REQUIRED'}
    $anchor=$anchors[-1];$coord=Convert-YakuA1ToCoord -Address ([string]$anchor.address);if($null -eq $coord){throw 'CAT_PLACEMENT_EMPTY_ADDRESS_INVALID'}
    $context=New-YakuExcelApplication;$workbook=$null;$worksheet=$null;$results=New-Object System.Collections.Generic.List[object]
    try{
        $workbook=Open-YakuWorkbookWithManualCalc -Context $context -Path ([string]$Project.Path) -ReadOnly $true
        $worksheet=$workbook.Worksheets.Item([string]$anchor.sheet)
        for($offset=1;$offset -le $CellCount;$offset++){
            $address=(Convert-YakuColumnNumberToName -Column ([int]$coord.Col))+[string]([int]$coord.Row+$offset)
            $results.Add((Get-YakuCatExcelConfirmedEmptyCellSnapshot -Project $Project -Worksheet $worksheet -Sheet ([string]$anchor.sheet) -Address $address -Ordinal $offset))|Out-Null
        }
        return @($results.ToArray())
    }finally{
        Release-YakuComObject $worksheet
        if($null -ne $context){Close-YakuExcelObjects -Workbook $workbook -Application $context.Application -Save:$false -OldCalculation $context.OldCalculation -OldCalculateBeforeSave $context.OldCalculateBeforeSave -OldScreenUpdating $context.OldScreenUpdating -OldEnableEvents $context.OldEnableEvents -OldDisplayStatusBar $context.OldDisplayStatusBar -OldFormatConditionsCalc $context.OldFormatConditionsCalc -OldBackgroundChecking $context.OldBackgroundChecking}
    }
}

function Get-YakuCatConfirmedEmptyWriteTargets {
    <# 全追加先を検査し終えてからsynthetic blockを返す。呼出側はその後にだけ書込む。 #>
    param([Parameter(Mandatory=$true)]$Project)
    $planned=@($Project.PlacementPlans|ForEach-Object{$plan=$_;@($plan.destinations|Where-Object{[string]$(try{$_.mode}catch{''}) -eq 'use_confirmed_empty'}|ForEach-Object{[pscustomobject]@{Plan=$plan;Destination=$_}})})
    if($planned.Count -eq 0){return @()}
    $context=New-YakuExcelApplication;$workbook=$null;$sheets=@{};$blocks=New-Object System.Collections.Generic.List[object]
    try{
        $workbook=Open-YakuWorkbookWithManualCalc -Context $context -Path ([string]$Project.Path) -ReadOnly $true
        foreach($entry in $planned){
            $destination=$entry.Destination;$sheetName=[string]$destination.sheet
            if(-not $sheets.ContainsKey($sheetName)){$sheets[$sheetName]=$workbook.Worksheets.Item($sheetName)}
            $actual=Get-YakuCatExcelConfirmedEmptyCellSnapshot -Project $Project -Worksheet $sheets[$sheetName] -Sheet $sheetName -Address ([string]$destination.address) -Ordinal ([int]$destination.empty_selection_ordinal)
            if([string]$actual.block_id -cne [string]$destination.block_id -or [string]$actual.expected_structure_fingerprint -cne [string]$destination.expected_structure_fingerprint -or [string]$actual.expected_sheet_code_name -cne [string]$destination.expected_sheet_code_name){throw ('CAT_PLACEMENT_EMPTY_PRECONDITION_CHANGED: '+$sheetName+'!'+[string]$destination.address)}
            $coord=Convert-YakuA1ToCoord -Address ([string]$destination.address)
            $blocks.Add([pscustomobject]@{Id=[string]$destination.block_id;Text='';Location=($sheetName+', '+[string]$destination.address);Meta=[pscustomobject]@{Kind='cell';Sheet=$sheetName;Row=[int]$coord.Row;Col=[int]$coord.Col;A1=[string]$destination.address;Merged=$false;StructureContract=$actual.structure_contract;StructureFingerprint=[string]$actual.expected_structure_fingerprint}})|Out-Null
        }
        return @($blocks.ToArray())
    }finally{
        foreach($sheet in @($sheets.Values)){Release-YakuComObject $sheet}
        if($null -ne $context){Close-YakuExcelObjects -Workbook $workbook -Application $context.Application -Save:$false -OldCalculation $context.OldCalculation -OldCalculateBeforeSave $context.OldCalculateBeforeSave -OldScreenUpdating $context.OldScreenUpdating -OldEnableEvents $context.OldEnableEvents -OldDisplayStatusBar $context.OldDisplayStatusBar -OldFormatConditionsCalc $context.OldFormatConditionsCalc -OldBackgroundChecking $context.OldBackgroundChecking}
    }
}

function Set-YakuCatPlacementSlices {
    <# 人が決めるのは掲載訳のセル境界だけ。基準訳そのものはこの操作で変えない。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Slices,
        [ValidateRange(0,3)][int]$SpillRightCells = 0,
        [ValidateRange(0,3)][int]$DownEmptyCells = 0
    )
    $null = Sync-YakuCatPlacementPlans -Project $Project
    $segments = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segments.Count) { throw 'CAT_PLACEMENT_SEGMENT_NOT_FOUND' }
    # 途中で分けた行は、元の1セルへ戻したもの（配置の単位）に対して調整する。
    # 行そのもので引くと計画が見つからず、画面が行き止まりになる。
    $placementUnit = @(@(Get-YakuCatPlacementUnits -Project $Project) | Where-Object { @($_.Indices) -contains $Index })
    if ($placementUnit.Count -ne 1) { throw 'CAT_PLACEMENT_SEGMENT_NOT_FOUND' }
    $segment = $placementUnit[0].Segment
    $plans = @($Project.PlacementPlans)
    $plan = @($plans | Where-Object { [string]$_.segment_id -eq [string]$segment.SegmentId })
    if ($plan.Count -gt 1) { throw 'CAT_PLACEMENT_PLAN_DUPLICATE' }
    if ($plan.Count -ne 1) { throw 'CAT_PLACEMENT_PLAN_NOT_FOUND' }
    $current = $plan[0]
    $null=Assert-YakuCatPlacementPlanBinding -Project $Project -Segment $segment -Plan $current -AllowPublicationMismatch
    $sourceDestinations=@($current.destinations|Where-Object{[string]$(try{$_.mode}catch{'replace_source_block'}) -ne 'use_confirmed_empty'})
    $emptyDestinations=@(Get-YakuCatConfirmedEmptyDownDestinations -Project $Project -Plan $current -CellCount $DownEmptyCells)
    $destinations=@($sourceDestinations)+@($emptyDestinations)
    $sliceList = @($Slices | ForEach-Object { [string]$_ })
    if ($sliceList.Count -ne $destinations.Count) { throw 'CAT_PLACEMENT_SLICE_COUNT_MISMATCH' }
    foreach ($slice in $sliceList) {
        if ($slice.Length -gt 20000 -or $slice -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') { throw 'CAT_PLACEMENT_SLICE_INVALID' }
    }
    $publication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $segment}else{[pscustomobject]@{Text=[string]$segment.Translation}})
    if (($sliceList -join '') -cne [string]$publication.Text) {
        throw 'CAT_PLACEMENT_PUBLICATION_TEXT_MISMATCH: セル別文字列をつなぐと現在の訳文へ戻る必要があります。'
    }
    for ($i = 0; $i -lt $destinations.Count; $i++) { $destinations[$i].text = $sliceList[$i] }
    $current.destinations = $destinations
    $current.publication_text_hash=[string]$publication.TextHash
    $current.source_contract.canonical_target_hash=Get-YakuCatSourceIntegrityHash -Text ([string]$segment.Translation)
    $current.source_contract.publication_variant_id=[string]$publication.VariantId
    $current.source_contract.publication_variant_revision=[int]$publication.VariantRevision
    $current.source_contract.publication_variant_hash=[string]$publication.VariantHash
    $current.display_regions=@(Get-YakuCatRightSpillDisplayRegion -Project $Project -Plan $current -CellCount $SpillRightCells)
    $current.placement_revision = [int]$current.placement_revision + 1
    $current.placement_kind = 'human_confirmed'
    $current.status = 'current'
    $current | Add-Member -NotePropertyName confirmed_at -NotePropertyValue (Get-Date).ToString('o') -Force
    $current.plan_hash = Get-YakuCatPlacementPlanHash -Plan $current
    $Project.PlacementPlans = $plans
    $null = Update-YakuCatPlacementSetHash -Project $Project
    $null = Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'placement' -Action 'placement_confirmed' -Segment $segment -DependencyFingerprint ([string]$current.plan_hash)
    return $current
}

function New-YakuCatProject {
    <#
      Excel / CSV を取り込み、セグメントに分ける。訳はまだ付けない。
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
    $kind = Get-YakuSupportedFileKind -Path $Path
    $extract = Get-YakuFileTextBlocks -Path $Path -Direction $Direction -Settings $Settings -Sheets $Sheets -ProgressState $ProgressState
    $blocks = @($extract.Blocks)

    # 行の埋まり具合は実際のシートから数える。翻訳対象だけを数えると
    # 「営業利益 | 1,234」の行が単独に見え、表の行を文章として繋いでしまう。
    $occ = @{}
    if ($kind -eq 'excel') {
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
        # 金額の書き方を作業へ焼き付ける。あとで設定を変えても、この作業の送信と点検は同じ表記で行う。
        AmountNotation = (Get-YakuAmountNotation -Settings $Settings)
        Blocks    = $blocks
        Segments  = $segments
        Warnings  = @($extract.Warnings)
        Source    = 'file'
        # 画面の出力名と再開後の出力方式を、元ファイルの種類から決められるようにする。
        # Eligibility 側だけ拡張子へfallbackしても、JSONの document_format が空だと
        # Excelなのに「すべての訳文をコピー」と表示される。
        DocumentFormat = [IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
        CreatedAt = (Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    if($null -ne $project.DocumentIndexSnapshot -and (Get-Command Assert-YakuCatDocumentIndexSnapshot -ErrorAction SilentlyContinue)){$null=Assert-YakuCatDocumentIndexSnapshot -Project $project -Snapshot $project.DocumentIndexSnapshot}
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
        # 金額の書き方を作業へ焼き付ける。あとで設定を変えても、この作業の送信と点検は同じ表記で行う。
        AmountNotation = (Get-YakuAmountNotation -Settings $Settings)
        Blocks    = @()
        Segments  = @($segments.ToArray())
        Warnings  = @()
        Source    = 'text'
        Lifecycle = 'transient'
        RetentionUntil = (Get-Date).AddDays(7).ToString('o')
        PromotionReferenceTranslation = [string]$(if (-not $useTargets) { $Translation } else { '' })
        CreatedAt = (Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    $project.TextSourceStructure = New-YakuCatTextSourceStructure -Text $Text -Segments @($project.Segments)
    if ($Register) { $script:YakuCatProjects[$project.Id] = $project }
    return $project
}

# New-YakuCatProjectFromQuickArtifact は 2026-08-13 に外した。
# 訳案を1枚返す状態（その場で訳す）を廃止し、貼り付けた文章も最初から
# New-YakuCatTextProject で作業になったため、昇格するもとが無くなった。
# QuickArtifactId / quick_artifact_id も同時に外している。保存済みの作業に
# 残っている分は、読むときに無視される（既定は空文字だった）。

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
                -Settings $Settings -Warnings @('日本語と英語の両方が必要です。片方が空でした。'))
    }
    $aligned = Invoke-YakuDocumentAlignment -JaLines $jaLines -EnLines $enLines -Settings $Settings
    return (New-YakuCatProjectFromPairs -Pairs @($aligned.Pairs) -Direction $Direction -FileName $FileName `
            -Settings $Settings -JaCoverage ([double]$aligned.JaCoverage) -Dropped ([int]$aligned.Dropped) `
            -Completed ([bool]$aligned.Completed) -StoppedAt ([int]$aligned.StoppedAt) -JaLineCount ([int]@($jaLines).Count))
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
        [bool]$Register = $true,
        # $Settings を引数に持たないまま Get-YakuAmountNotation へ渡していた。
        # PowerShell の動的スコープで呼び出し元の $settings を拾って偶然動いており、
        # 呼び出し元が変数名を変えた瞬間に既定（oku）へ落ちる状態だった
        # （2026-08-13、実測で確認: 呼び出し元に無いと oku、billion があると billion）。
        [AllowNull()]$Settings = $null,
        # 途中で打ち切られたときの位置。呼び出し側が「どこまで進んだか」を出せるように。
        [bool]$Completed = $true,
        [int]$StoppedAt = -1,
        [int]$JaLineCount = 0
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
    # 途中で打ち切られたことは、網羅率とは別に言う。「網羅率が低い」だけでは
    # 「対応が取れなかった」のか「最後まで行っていない」のか区別がつかない。
    if (-not $Completed -and $StoppedAt -ge 0) {
        $totalText = if ($JaLineCount -gt 0) { $JaLineCount.ToString('N0') + '行のうち' } else { '' }
        [void]$warn.Add(($totalText + ($StoppedAt + 1).ToString('N0') + '行目で止まりました。ここまでの対応は残っています。続きは、同じ資料をもう一度取り込んでください。'))
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
        # 金額の書き方を作業へ焼き付ける。あとで設定を変えても、この作業の送信と点検は同じ表記で行う。
        AmountNotation = (Get-YakuAmountNotation -Settings $Settings)
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
        [Parameter(Mandatory=$true)][string]$Extension,
        [string]$SourceSnapshotId = ''
    )
    if ($ProjectId -notmatch '^[a-fA-F0-9]{32}$') { throw 'CAT_PROJECT_ID_INVALID' }
    $ext = ([string]$Extension).ToLowerInvariant()
    if (@('.xlsx','.xlsm','.csv','.docx') -notcontains $ext) { throw 'CAT_SOURCE_ARTIFACT_TYPE_UNSUPPORTED' }
    $store = [System.IO.Path]::GetFullPath((Get-YakuCatProjectStoreDir)).TrimEnd('\')
    $projectDir = [System.IO.Path]::GetFullPath((Join-Path $store $ProjectId))
    if (-not $projectDir.StartsWith($store + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'CAT_SOURCE_ARTIFACT_PATH_INVALID' }
    if ([string]::IsNullOrWhiteSpace($SourceSnapshotId)) {
        return (Join-Path (Join-Path $projectDir 'source') ('original' + $ext))
    }
    if ($SourceSnapshotId -notmatch '^[a-f0-9]{32}$') { throw 'CAT_SOURCE_SNAPSHOT_ID_INVALID' }
    return (Join-Path (Join-Path (Join-Path (Join-Path $projectDir 'source') 'revisions') $SourceSnapshotId) ('original' + $ext))
}

function Get-YakuCatSourceSnapshotFingerprints {
    <#
      SourceSnapshot の比較に使う3つのfingerprintを、原本ファイルの生byte hashとは
      分けて作る。取得不能を空文字にすると「同じ」なのか「未確認」なのか区別できず、
      原本差し替え時に古い配置や確認を継承し得るため、unknownも契約へ含めてhashする。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$ArtifactPath
    )
    $extension = [IO.Path]::GetExtension($ArtifactPath).ToLowerInvariant()
    $inventoryRows = New-Object System.Collections.Generic.List[object]
    foreach ($block in @($Project.Blocks | Sort-Object @{ Expression={ [string]$_.Id }; Ascending=$true })) {
        $meta = $(try { $block.Meta } catch { $null })
        $inventoryRows.Add([ordered]@{
            id = [string]$block.Id
            text_hash = Get-YakuCatSourceIntegrityHash -Text ([string]$block.Text)
            location = [string]$block.Location
            kind = $(try { [string]$meta.Kind } catch { '' })
            sheet = $(try { [string]$meta.Sheet } catch { '' })
            sheet_code_name = $(try { [string]$meta.SheetCodeName } catch { '' })
            address = $(try { [string]$meta.A1 } catch { '' })
            structure_fingerprint = $(try { [string]$meta.StructureFingerprint } catch { '' })
        }) | Out-Null
    }
    $inventoryContract = [ordered]@{
        contract_version = 'cat-source-inventory-v2'
        extension = $extension
        blocks = @($inventoryRows.ToArray())
    }

    $layoutState = 'not_applicable'
    $layoutRows = @()
    if ($extension -in @('.xlsx','.xlsm')) {
        $layoutState = 'unknown'
        if (Get-Command Get-YakuSheetLayoutFromXlsx -ErrorAction SilentlyContinue) {
            try {
                $layoutRows = @(Get-YakuSheetLayoutFromXlsx -Path $ArtifactPath)
                if ($layoutRows.Count -gt 0) { $layoutState = 'known' }
            } catch { $layoutRows = @(); $layoutState = 'unknown' }
        }
    }
    $layoutContract = [ordered]@{
        contract_version = 'cat-source-layout-v2'
        extension = $extension
        state = $layoutState
        sheets = @($layoutRows)
    }

    $printState = 'not_applicable'
    $printFields = [pscustomobject]@{}
    $printUnknown = @()
    if ($extension -in @('.xlsx','.xlsm')) {
        $printState = 'unknown'
        if (Get-Command Get-YakuOoxmlPrintDependencySnapshot -ErrorAction SilentlyContinue) {
            try {
                $printSnapshot = Get-YakuOoxmlPrintDependencySnapshot -Path $ArtifactPath
                $printFields = $printSnapshot.Fields
                $printUnknown = @($printSnapshot.UnknownFields | Sort-Object -Unique)
                $printState = $(if ($printUnknown.Count -gt 0) { 'unknown' } else { 'known' })
            } catch { $printFields = [pscustomobject]@{}; $printUnknown = @('ooxml:print-dependencies'); $printState = 'unknown' }
        } else { $printUnknown = @('ooxml:print-reader-unavailable') }
    }
    $printContract = [ordered]@{
        contract_version = 'cat-source-print-dependencies-v2'
        extension = $extension
        state = $printState
        fields = $printFields
        unknown_fields = @($printUnknown)
    }

    return [pscustomobject]@{
        InventoryHash = Get-YakuCatSourceIntegrityHash -Text ($inventoryContract | ConvertTo-Json -Depth 12 -Compress)
        LayoutHash = Get-YakuCatSourceIntegrityHash -Text ($layoutContract | ConvertTo-Json -Depth 12 -Compress)
        PrintHash = Get-YakuCatSourceIntegrityHash -Text ($printContract | ConvertTo-Json -Depth 12 -Compress)
        InventoryState = 'known'
        LayoutState = $layoutState
        PrintState = $printState
    }
}

function Assert-YakuCatActiveSourceSnapshotFingerprints {
    param([Parameter(Mandatory=$true)]$Project)
    if([string]$Project.Source -ne 'file'){return $true}
    $snapshot=@($Project.SourceSnapshots|Where-Object{[string]$_.source_snapshot_id -eq [string]$Project.ActiveSourceId}|Select-Object -First 1)
    if($snapshot.Count -ne 1){throw 'CAT_SOURCE_SNAPSHOT_ACTIVE_MISSING'}
    if([string]$snapshot[0].contract_version -ne 'cat-source-snapshot-v2'){return $true}
    $actual=Get-YakuCatSourceSnapshotFingerprints -Project $Project -ArtifactPath ([string]$Project.Path)
    if([string]$snapshot[0].inventory_hash -ne [string]$actual.InventoryHash){throw 'CAT_SOURCE_SNAPSHOT_INVENTORY_MISMATCH'}
    if([string]$snapshot[0].layout_hash -ne [string]$actual.LayoutHash){throw 'CAT_SOURCE_SNAPSHOT_LAYOUT_MISMATCH'}
    if([string]$snapshot[0].print_hash -ne [string]$actual.PrintHash){throw 'CAT_SOURCE_SNAPSHOT_PRINT_MISMATCH'}
    return $true
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
    $sourceHash = (Get-FileHash -LiteralPath $sourceFull -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceSnapshotId = $sourceHash.Substring(0, 32)
    $destination = [System.IO.Path]::GetFullPath((Get-YakuCatOwnedSourceArtifactPath -ProjectId ([string]$Project.Id) -Extension $ext -SourceSnapshotId $sourceSnapshotId))
    $sourceDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $sourceDir -Force }

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
    $relativePath = 'source/revisions/' + $sourceSnapshotId + '/original' + $ext
    $snapshots = New-Object System.Collections.Generic.List[object]
    foreach ($snapshot in @($Project.SourceSnapshots)) { $snapshots.Add($snapshot) | Out-Null }
    if (@($snapshots | Where-Object { [string]$_.source_snapshot_id -eq $sourceSnapshotId }).Count -eq 0) {
        $fingerprints = Get-YakuCatSourceSnapshotFingerprints -Project $Project -ArtifactPath $destination
        $snapshots.Add([pscustomobject]@{
            source_snapshot_id=$sourceSnapshotId; parent_id=''; sha256=$artifactHash; size=$artifactSize
            extension=$ext; artifact_path=$relativePath
            inventory_hash=[string]$fingerprints.InventoryHash; layout_hash=[string]$fingerprints.LayoutHash; print_hash=[string]$fingerprints.PrintHash
            inventory_state=[string]$fingerprints.InventoryState; layout_state=[string]$fingerprints.LayoutState; print_state=[string]$fingerprints.PrintState
            created_at=(Get-Date).ToString('o'); contract_version='cat-source-snapshot-v2'
        }) | Out-Null
    }
    $Project.ActiveSourceId = $sourceSnapshotId
    $Project.SourceSnapshots = @($snapshots.ToArray())
    $Project | Add-Member -NotePropertyName SourceArtifactRelativePath -NotePropertyValue $relativePath -Force
    $Project | Add-Member -NotePropertyName SourceArtifactSha256 -NotePropertyValue $artifactHash -Force
    $Project | Add-Member -NotePropertyName SourceArtifactSize -NotePropertyValue $artifactSize -Force
    $Project | Add-Member -NotePropertyName SourceArtifactContractVersion -NotePropertyValue 'cat-source-v2' -Force
    return $Project
}

function Resolve-YakuCatSavedSourceArtifact {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectDir,
        [Parameter(Mandatory=$true)]$Record
    )
    $relative = [string]$Record.source_artifact_relative_path
    if ([string]::IsNullOrWhiteSpace($relative)) { return [string]$Record.path }
    $contract = [string]$Record.source_artifact_contract_version
    if (@('cat-source-v1','cat-source-v2') -notcontains $contract) { throw 'CAT_SOURCE_ARTIFACT_CONTRACT_UNSUPPORTED' }
    if ($contract -eq 'cat-source-v1' -and $relative -notmatch '^source/original\.(?:xlsx|xlsm|csv|docx)$') { throw 'CAT_SOURCE_ARTIFACT_PATH_INVALID' }
    if ($contract -eq 'cat-source-v2' -and $relative -notmatch '^source/revisions/[a-f0-9]{32}/original\.(?:xlsx|xlsm|csv|docx)$') { throw 'CAT_SOURCE_ARTIFACT_PATH_INVALID' }
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

function Write-YakuCatCommitManifestCas {
    <# generationを全て検証した最後にだけmanifestを差し替える。別processも
       同じlock fileをFileShare.Noneで開くため、read-check-replaceを跨いだ
       lost updateを防ぐ。commit manifestでは非atomicなmove fallbackを使わない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Value,
        [Parameter(Mandatory=$true)][int]$ExpectedRevision,
        [string]$ExpectedGenerationId = ''
    )
    $dir=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $dir -PathType Container)){$null=New-Item -ItemType Directory -Path $dir -Force}
    $lockPath=Join-Path $dir '.commit.lock';$lockStream=$null
    for($attempt=0;$attempt -lt 100 -and $null -eq $lockStream;$attempt++){
        try{$lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{if($attempt -ge 99){throw 'CAT_COMMIT_MANIFEST_LOCK_TIMEOUT: 保存処理の競合を解消できません。'};Start-Sleep -Milliseconds 30}
    }
    $temp=Join-Path $dir ('.project.json.'+[guid]::NewGuid().ToString('N')+'.tmp');$backup=$temp+'.bak'
    try{
        $exists=Test-Path -LiteralPath $Path -PathType Leaf
        if($exists){
            try{$current=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{throw 'CAT_COMMIT_MANIFEST_INVALID: 現在の保存情報を検証できません。'}
            if([int]$current.revision -ne $ExpectedRevision -or (-not [string]::IsNullOrWhiteSpace($ExpectedGenerationId) -and [string]$current.active_generation_id -cne $ExpectedGenerationId)){throw 'CAT_COMMIT_MANIFEST_CONFLICT: 別のプロセスが先に作業を保存しました。最新状態を読み込んでください。'}
        } elseif($ExpectedRevision -ne 0 -or -not [string]::IsNullOrWhiteSpace($ExpectedGenerationId)){throw 'CAT_COMMIT_MANIFEST_CONFLICT: 更新元の保存情報が見つかりません。'}
        $utf8Bom=New-Object Text.UTF8Encoding($true);[IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 12),$utf8Bom)
        if($exists){
            try{[IO.File]::Replace($temp,$Path,$backup,$true)}catch{throw 'CAT_COMMIT_MANIFEST_ATOMIC_REPLACE_FAILED: 保存情報を安全に差し替えられませんでした。'}
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }else{[IO.File]::Move($temp,$Path)}
    }finally{
        if($null -ne $lockStream){$lockStream.Dispose()}
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Start-YakuCatProjectDeletion {
    <# lifecycleを先にcommit manifestへCASし、後続mutationを止めてから実体を消す。
       cleanupが期限を読んだ後に保存・延長された場合はcandidate内の再検査で停止する。 #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][int]$ExpectedRevision,
        [Parameter(Mandatory=$true)][string]$ExpectedGenerationId,
        [string]$ExpectedLifecycle='',
        [ValidateSet('retain_tm','revoke_tm')][string]$MemoryPolicy='retain_tm',
        [switch]$RequireExpired
    )
    $mutation={param($candidate,$innerGeneration,$innerLifecycle,$innerMemoryPolicy,$innerRequireExpired)
        if((Get-Command Test-YakuProjectLeaseActive -ErrorAction SilentlyContinue) -and (Test-YakuProjectLeaseActive -ProjectId ([string]$candidate.Id))){throw 'CAT_PROJECT_ACTIVE_LEASE'}
        if((Get-Command Test-YakuProjectJobActive -ErrorAction SilentlyContinue) -and (Test-YakuProjectJobActive -ProjectId ([string]$candidate.Id))){throw 'CAT_PROJECT_ACTIVE_JOB'}
        if([string]$candidate.ActiveGenerationId -cne $innerGeneration){throw 'CAT_PROJECT_DELETE_CAS_MISMATCH'}
        if(-not [string]::IsNullOrWhiteSpace($innerLifecycle) -and [string]$candidate.Lifecycle -cne $innerLifecycle){throw 'CAT_PROJECT_DELETE_CAS_MISMATCH'}
        if([bool]$innerRequireExpired){$expiry=try{[datetime]$candidate.RetentionUntil}catch{[datetime]::MaxValue};if([string]$candidate.Lifecycle -ne 'transient' -or $expiry.ToUniversalTime() -gt [datetime]::UtcNow){throw 'CAT_PROJECT_DELETE_NOT_EXPIRED'}}
        $candidate.Lifecycle='deleting';$candidate.DeletionMemoryPolicy=$innerMemoryPolicy;return [pscustomobject]@{lifecycle='deleting';memory_policy=$innerMemoryPolicy;previous_generation_id=$innerGeneration}
    }
    return (Invoke-YakuCatProjectMutation -ProjectId $ProjectId -ExpectedRevision $ExpectedRevision -Mutation $mutation -Arguments @($ExpectedGenerationId,$ExpectedLifecycle,$MemoryPolicy,[bool]$RequireExpired) -Action project-delete-start)
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
    param([Parameter(Mandatory=$true)]$Project,[switch]$ThrowOnError)
    $null = Initialize-YakuCatProjectState -Project $Project
    $oldRevision = [int]$Project.Revision
    $generationDir = ''
    try {
        if ([string]$Project.Source -eq 'file') { $null = Initialize-YakuCatProjectSourceArtifact -Project $Project }
        $null = Sync-YakuCatPlacementPlans -Project $Project
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
                    tm_registered = [bool]$(try { $_.TmRegistered } catch { $false })
                    tm_registration_event_id = [string]$(try { $_.TmRegistrationEventId } catch { '' })
                    # 任意位置で割った行の組。保存しないと、読み直したときに同じセルを
                    # 指す2行が別々の配置先として扱われ、前半の訳が消える。
                    split_group_id = [string]$(try { $_.SplitGroupId } catch { '' })
                    split_ordinal = [int]$(try { $_.SplitOrdinal } catch { 0 })
                    split_origin_segment_id = [string]$(try { $_.SplitOriginSegmentId } catch { '' })
                    pieces = @($(try { $_.Pieces } catch { @() }))
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
            schema_version = 8
            revision = $nextRevision
            id = [string]$Project.Id
            path = [string]$Project.Path
            file_name = [string]$Project.FileName
            direction = [string]$Project.Direction
            amount_notation = (Get-YakuCatProjectAmountNotation -Project $Project)
            direction_basis = [string]$Project.DirectionBasis
            direction_confidence = [string]$Project.DirectionConfidence
            direction_source_fingerprint = [string]$Project.DirectionSourceFingerprint
            terminology_snapshot_hash = [string]$Project.TerminologySnapshotHash
            tm_outbox = @($Project.TmOutbox)
            lifecycle = [string]$Project.Lifecycle
            retention_until = [string]$Project.RetentionUntil
            promoted_at = [string]$Project.PromotedAt
            deletion_memory_policy = [string]$Project.DeletionMemoryPolicy
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
            active_source_id = $(try { [string]$Project.ActiveSourceId } catch { '' })
            source_snapshots = @($(try { $Project.SourceSnapshots } catch { @() }))
            applied_rebase_id = $(try { [string]$Project.AppliedRebaseId } catch { '' })
            rebase_records = @($(try { $Project.RebaseRecords } catch { @() }))
            placement_set_hash = [string]$Project.PlacementSetHash
            active_publication_variants = $Project.ActivePublicationVariantBySegment
            document_index_snapshot = $Project.DocumentIndexSnapshot
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
        $reviewEventLines = @($Project.ReviewEvents | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }) -join "`n"
        $textSourceJson = if ($null -ne $Project.TextSourceStructure) { $Project.TextSourceStructure | ConvertTo-Json -Depth 12 -Compress } else { 'null' }
        $placementLines = @($Project.PlacementPlans | ForEach-Object { $_ | ConvertTo-Json -Depth 14 -Compress }) -join "`n"
        $documentFindingLines = @($Project.DocumentFindings | ForEach-Object { $_ | ConvertTo-Json -Depth 16 -Compress }) -join "`n"
        $reviewRunLines = @($Project.ReviewRuns | ForEach-Object { $_ | ConvertTo-Json -Depth 16 -Compress }) -join "`n"
        foreach($decision in @($Project.FinalReviewDecisions)){
            if([string]::IsNullOrWhiteSpace([string]$(try{$decision.source_generation_id}catch{''}))){$decision|Add-Member -NotePropertyName source_generation_id -NotePropertyValue $generationId -Force}
            foreach($artifact in @($(try{$decision.final_artifacts}catch{@()}))){if([string]::IsNullOrWhiteSpace([string]$(try{$artifact.source_generation_id}catch{''}))){$artifact|Add-Member -NotePropertyName source_generation_id -NotePropertyValue $generationId -Force}}
        }
        $finalReviewDecisionLines = @($Project.FinalReviewDecisions | ForEach-Object { $_ | ConvertTo-Json -Depth 16 -Compress }) -join "`n"
        $publicationVariantLines = @($Project.PublicationVariants | ForEach-Object { $_ | ConvertTo-Json -Depth 16 -Compress }) -join "`n"
        $abbreviationEntryLines = @($Project.AbbreviationEntries | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }) -join "`n"
        $abbreviationUseLines = @($Project.AbbreviationUses | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }) -join "`n"
        $mutationReceiptLines = @($Project.MutationReceipts | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join "`n"
        $bulkReplaceUndoJson = if ($null -ne $Project.PendingBulkReplaceUndo) {
            $null = Assert-YakuCatBulkReplaceUndoSnapshot -Project $Project -Snapshot $Project.PendingBulkReplaceUndo -RequireCurrent
            $Project.PendingBulkReplaceUndo | ConvertTo-Json -Depth 28 -Compress
        } else { 'null' }
        $structuralUndoJson = if ($null -ne $Project.PendingStructuralUndo) {
            $null = Assert-YakuCatStructuralUndoSnapshot -Project $Project -Snapshot $Project.PendingStructuralUndo -RequireCurrent
            $Project.PendingStructuralUndo | ConvertTo-Json -Depth 40 -Compress
        } else { 'null' }
        if ([Text.Encoding]::UTF8.GetByteCount($bulkReplaceUndoJson) -gt 1048576) { throw 'CAT_REPLACE_UNDO_SNAPSHOT_TOO_LARGE: 元に戻すための記録が1 MiBを超えています。' }
        if ([Text.Encoding]::UTF8.GetByteCount($structuralUndoJson) -gt 1048576) { throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_TOO_LARGE: 元に戻すための記録が1 MiBを超えています。' }
        # 1 revision を構成する全ファイルを新しい世代へ先に書く。project.json は
        # コミットmanifestであり、全書込みが成功した最後にだけ差し替える。
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'segments.jsonl') -Text $segmentLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'blocks.jsonl') -Text $blockLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'qc.jsonl') -Text $qcLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'human-decisions.jsonl') -Text $reviewEventLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'text-source.json') -Text $textSourceJson
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'placements.jsonl') -Text $placementLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'document-findings.jsonl') -Text $documentFindingLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'review-runs.jsonl') -Text $reviewRunLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'final-review-decisions.jsonl') -Text $finalReviewDecisionLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'publication-variants.jsonl') -Text $publicationVariantLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'abbreviation-entries.jsonl') -Text $abbreviationEntryLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'abbreviation-uses.jsonl') -Text $abbreviationUseLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'mutation-receipts.jsonl') -Text $mutationReceiptLines
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'bulk-replace-undo.json') -Text $bulkReplaceUndoJson
        Write-YakuTextAtomic -Path (Join-Path $generationDir 'structural-undo.json') -Text $structuralUndoJson
        $record['generation_id'] = $generationId
        # project.json 自体がcommit manifest。source・project generation・rebase・
        # revisionの組をこの一度のatomic replaceで可視化する。
        $record['active_generation_id'] = $generationId
        $record['project_revision'] = $nextRevision
        $record['segment_count'] = @($segs).Count
        $record['block_count'] = @($blocks).Count
        $record['segments_sha256'] = Get-YakuCatSourceIntegrityHash -Text $segmentLines
        $record['blocks_sha256'] = Get-YakuCatSourceIntegrityHash -Text $blockLines
        $record['qc_sha256'] = Get-YakuCatSourceIntegrityHash -Text $qcLines
        $record['review_events_sha256'] = Get-YakuCatSourceIntegrityHash -Text $reviewEventLines
        $record['text_source_sha256'] = Get-YakuCatSourceIntegrityHash -Text $textSourceJson
        $record['placements_sha256'] = Get-YakuCatSourceIntegrityHash -Text $placementLines
        $record['placement_count'] = @($Project.PlacementPlans).Count
        $record['document_findings_sha256'] = Get-YakuCatSourceIntegrityHash -Text $documentFindingLines
        $record['document_finding_count'] = @($Project.DocumentFindings).Count
        $record['review_runs_sha256'] = Get-YakuCatSourceIntegrityHash -Text $reviewRunLines
        $record['review_run_count'] = @($Project.ReviewRuns).Count
        $record['final_review_decisions_sha256'] = Get-YakuCatSourceIntegrityHash -Text $finalReviewDecisionLines
        $record['final_review_decision_count'] = @($Project.FinalReviewDecisions).Count
        $record['publication_variants_sha256'] = Get-YakuCatSourceIntegrityHash -Text $publicationVariantLines
        $record['publication_variant_count'] = @($Project.PublicationVariants).Count
        $record['abbreviation_entries_sha256'] = Get-YakuCatSourceIntegrityHash -Text $abbreviationEntryLines
        $record['abbreviation_entry_count'] = @($Project.AbbreviationEntries).Count
        $record['abbreviation_uses_sha256'] = Get-YakuCatSourceIntegrityHash -Text $abbreviationUseLines
        $record['abbreviation_use_count'] = @($Project.AbbreviationUses).Count
        $record['mutation_receipts_sha256'] = Get-YakuCatSourceIntegrityHash -Text $mutationReceiptLines
        $record['mutation_receipt_count'] = @($Project.MutationReceipts).Count
        $record['bulk_replace_undo_sha256'] = Get-YakuCatSourceIntegrityHash -Text $bulkReplaceUndoJson
        $record['bulk_replace_undo_count'] = $(if ($null -ne $Project.PendingBulkReplaceUndo) { [int]$Project.PendingBulkReplaceUndo.affected_count } else { 0 })
        $record['structural_undo_sha256'] = Get-YakuCatSourceIntegrityHash -Text $structuralUndoJson
        $record['structural_undo_count'] = $(if ($null -ne $Project.PendingStructuralUndo) { [int]$Project.PendingStructuralUndo.affected_count } else { 0 })
        Write-YakuCatCommitManifestCas -Path (Join-Path $projectDir 'project.json') -Value $record -ExpectedRevision $oldRevision -ExpectedGenerationId ([string]$Project.ActiveGenerationId)
        $Project.Revision = $nextRevision
        $Project.ActiveGenerationId = $generationId
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
        $saveError=$_
        $Project.Revision = $oldRevision
        # manifest が指していない未コミット世代は復元に使わない。
        # 失敗するたびに残すと障害時ほど容量が増えるため、ここで回収する。
        if (-not [string]::IsNullOrWhiteSpace($generationDir) -and (Test-Path -LiteralPath $generationDir -PathType Container)) {
            try { Remove-Item -LiteralPath $generationDir -Recurse -Force -ErrorAction Stop } catch {}
        }
        try { Write-YakuLog ('CAT project save failed: ' + $_.Exception.Message) 'WARN' } catch {}
        if($ThrowOnError){throw $saveError}
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
            if ([string]$o.lifecycle -eq 'transient') { continue }
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
                    # 一覧からそのまま消せるようにする。削除は expected_revision が要る。
                    Revision = $(try { [int]$o.revision } catch { 0 })
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
    $savedReviewEvents = @()
    $savedTextSourceStructure = $null
    $savedPlacementPlans = @()
    $savedDocumentFindings = @()
    $savedReviewRuns = @()
    $savedFinalReviewDecisions = @()
    $savedPublicationVariants = @()
    $savedAbbreviationEntries = @()
    $savedAbbreviationUses = @()
    $savedMutationReceipts = @()
    $savedBulkReplaceUndo = $null
    $savedStructuralUndo = $null
    if ($isV2) {
        $hasBulkReplaceUndoContract = ($o.PSObject.Properties.Name -contains 'bulk_replace_undo_sha256') -or ($o.PSObject.Properties.Name -contains 'bulk_replace_undo_count')
        $hasStructuralUndoContract = ($o.PSObject.Properties.Name -contains 'structural_undo_sha256') -or ($o.PSObject.Properties.Name -contains 'structural_undo_count')
        if (-not [string]::IsNullOrWhiteSpace([string]$o.active_generation_id) -and [string]$o.active_generation_id -ne [string]$o.generation_id) {
            throw 'CAT_PROJECT_COMMIT_MANIFEST_INCONSISTENT: active generationが一致しません。'
        }
        if ([int]$o.project_revision -gt 0 -and [int]$o.project_revision -ne [int]$o.revision) {
            throw 'CAT_PROJECT_COMMIT_MANIFEST_INCONSISTENT: project revisionが一致しません。'
        }
        $generationId = [string]$(if (-not [string]::IsNullOrWhiteSpace([string]$o.active_generation_id)) { $o.active_generation_id } else { $o.generation_id })
        if (-not [string]::IsNullOrWhiteSpace($generationId)) {
            if ($generationId -notmatch '^[a-f0-9]{32}$') { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代IDが不正です。' }
            $generationDir = Join-Path (Join-Path $projectDir 'generations') $generationId
            $segPath = Join-Path $generationDir 'segments.jsonl'
            $blockPath = Join-Path $generationDir 'blocks.jsonl'
            $qcPath = Join-Path $generationDir 'qc.jsonl'
            $decisionPath = Join-Path $generationDir 'human-decisions.jsonl'
            $textSourcePath = Join-Path $generationDir 'text-source.json'
            $placementPath = Join-Path $generationDir 'placements.jsonl'
            $documentFindingPath = Join-Path $generationDir 'document-findings.jsonl'
            $reviewRunPath = Join-Path $generationDir 'review-runs.jsonl'
            $finalReviewDecisionPath = Join-Path $generationDir 'final-review-decisions.jsonl'
            $publicationVariantPath = Join-Path $generationDir 'publication-variants.jsonl'
            $abbreviationEntryPath = Join-Path $generationDir 'abbreviation-entries.jsonl'
            $abbreviationUsePath = Join-Path $generationDir 'abbreviation-uses.jsonl'
            $mutationReceiptPath = Join-Path $generationDir 'mutation-receipts.jsonl'
            $bulkReplaceUndoPath = Join-Path $generationDir 'bulk-replace-undo.json'
            $structuralUndoPath = Join-Path $generationDir 'structural-undo.json'
            $requiredPaths = @($segPath,$blockPath,$qcPath)
            if ([int]$o.schema_version -ge 3) { $requiredPaths += @($decisionPath,$textSourcePath) }
            if ([int]$o.schema_version -ge 4) { $requiredPaths += @($placementPath) }
            if ([int]$o.schema_version -ge 5) { $requiredPaths += @($documentFindingPath,$reviewRunPath) }
            if ([int]$o.schema_version -ge 6) { $requiredPaths += @($finalReviewDecisionPath) }
            if ([int]$o.schema_version -ge 7) { $requiredPaths += @($publicationVariantPath,$abbreviationEntryPath,$abbreviationUsePath) }
            if ([int]$o.schema_version -ge 8) { $requiredPaths += @($mutationReceiptPath) }
            if ($hasBulkReplaceUndoContract) { $requiredPaths += @($bulkReplaceUndoPath) }
            if ($hasStructuralUndoContract) { $requiredPaths += @($structuralUndoPath) }
            foreach ($requiredPath in $requiredPaths) {
                if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代を構成するファイルが不足しています。' }
            }
            $segmentRaw = Get-Content -LiteralPath $segPath -Raw -Encoding UTF8
            $blockRaw = Get-Content -LiteralPath $blockPath -Raw -Encoding UTF8
            $qcRaw = Get-Content -LiteralPath $qcPath -Raw -Encoding UTF8
            $decisionRaw = if (Test-Path -LiteralPath $decisionPath -PathType Leaf) { Get-Content -LiteralPath $decisionPath -Raw -Encoding UTF8 } else { '' }
            $textSourceRaw = if (Test-Path -LiteralPath $textSourcePath -PathType Leaf) { Get-Content -LiteralPath $textSourcePath -Raw -Encoding UTF8 } else { 'null' }
            $placementRaw = if (Test-Path -LiteralPath $placementPath -PathType Leaf) { Get-Content -LiteralPath $placementPath -Raw -Encoding UTF8 } else { '' }
            $documentFindingRaw = if (Test-Path -LiteralPath $documentFindingPath -PathType Leaf) { Get-Content -LiteralPath $documentFindingPath -Raw -Encoding UTF8 } else { '' }
            $reviewRunRaw = if (Test-Path -LiteralPath $reviewRunPath -PathType Leaf) { Get-Content -LiteralPath $reviewRunPath -Raw -Encoding UTF8 } else { '' }
            $finalReviewDecisionRaw = if (Test-Path -LiteralPath $finalReviewDecisionPath -PathType Leaf) { Get-Content -LiteralPath $finalReviewDecisionPath -Raw -Encoding UTF8 } else { '' }
            $publicationVariantRaw = if (Test-Path -LiteralPath $publicationVariantPath -PathType Leaf) { Get-Content -LiteralPath $publicationVariantPath -Raw -Encoding UTF8 } else { '' }
            $abbreviationEntryRaw = if (Test-Path -LiteralPath $abbreviationEntryPath -PathType Leaf) { Get-Content -LiteralPath $abbreviationEntryPath -Raw -Encoding UTF8 } else { '' }
            $abbreviationUseRaw = if (Test-Path -LiteralPath $abbreviationUsePath -PathType Leaf) { Get-Content -LiteralPath $abbreviationUsePath -Raw -Encoding UTF8 } else { '' }
            $mutationReceiptRaw = if (Test-Path -LiteralPath $mutationReceiptPath -PathType Leaf) { Get-Content -LiteralPath $mutationReceiptPath -Raw -Encoding UTF8 } else { '' }
            $bulkReplaceUndoRaw = if (Test-Path -LiteralPath $bulkReplaceUndoPath -PathType Leaf) { Get-Content -LiteralPath $bulkReplaceUndoPath -Raw -Encoding UTF8 } else { 'null' }
            $structuralUndoRaw = if (Test-Path -LiteralPath $structuralUndoPath -PathType Leaf) { Get-Content -LiteralPath $structuralUndoPath -Raw -Encoding UTF8 } else { 'null' }
            if ((Get-YakuCatSourceIntegrityHash -Text $segmentRaw) -ne [string]$o.segments_sha256 -or
                (Get-YakuCatSourceIntegrityHash -Text $blockRaw) -ne [string]$o.blocks_sha256 -or
                (Get-YakuCatSourceIntegrityHash -Text $qcRaw) -ne [string]$o.qc_sha256 -or
                ([int]$o.schema_version -ge 3 -and (Get-YakuCatSourceIntegrityHash -Text $decisionRaw) -ne [string]$o.review_events_sha256) -or
                ([int]$o.schema_version -ge 3 -and (Get-YakuCatSourceIntegrityHash -Text $textSourceRaw) -ne [string]$o.text_source_sha256) -or
                ([int]$o.schema_version -ge 4 -and (Get-YakuCatSourceIntegrityHash -Text $placementRaw) -ne [string]$o.placements_sha256) -or
                ([int]$o.schema_version -ge 5 -and (Get-YakuCatSourceIntegrityHash -Text $documentFindingRaw) -ne [string]$o.document_findings_sha256) -or
                ([int]$o.schema_version -ge 5 -and (Get-YakuCatSourceIntegrityHash -Text $reviewRunRaw) -ne [string]$o.review_runs_sha256) -or
                ([int]$o.schema_version -ge 6 -and (Get-YakuCatSourceIntegrityHash -Text $finalReviewDecisionRaw) -ne [string]$o.final_review_decisions_sha256) -or
                ([int]$o.schema_version -ge 7 -and (Get-YakuCatSourceIntegrityHash -Text $publicationVariantRaw) -ne [string]$o.publication_variants_sha256) -or
                ([int]$o.schema_version -ge 7 -and (Get-YakuCatSourceIntegrityHash -Text $abbreviationEntryRaw) -ne [string]$o.abbreviation_entries_sha256) -or
                ([int]$o.schema_version -ge 7 -and (Get-YakuCatSourceIntegrityHash -Text $abbreviationUseRaw) -ne [string]$o.abbreviation_uses_sha256) -or
                ([int]$o.schema_version -ge 8 -and (Get-YakuCatSourceIntegrityHash -Text $mutationReceiptRaw) -ne [string]$o.mutation_receipts_sha256) -or
                ($hasBulkReplaceUndoContract -and ((Get-YakuCatSourceIntegrityHash -Text $bulkReplaceUndoRaw) -ne [string]$o.bulk_replace_undo_sha256)) -or
                ($hasStructuralUndoContract -and ((Get-YakuCatSourceIntegrityHash -Text $structuralUndoRaw) -ne [string]$o.structural_undo_sha256))) {
                throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代の整合性検査に失敗しました。'
            }
            $savedSegmentRows = @($segmentRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedBlockRows = @($blockRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedReviewEvents = @($decisionRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            if (-not [string]::IsNullOrWhiteSpace($textSourceRaw) -and $textSourceRaw -ne 'null') { $savedTextSourceStructure = $textSourceRaw | ConvertFrom-Json }
            $savedPlacementPlans = @($placementRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedDocumentFindings = @($documentFindingRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedReviewRuns = @($reviewRunRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedFinalReviewDecisions = @($finalReviewDecisionRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedPublicationVariants = @($publicationVariantRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedAbbreviationEntries = @($abbreviationEntryRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedAbbreviationUses = @($abbreviationUseRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            $savedMutationReceipts = @($mutationReceiptRaw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            if ($hasBulkReplaceUndoContract -and $bulkReplaceUndoRaw -ne 'null') {
                try { $savedBulkReplaceUndo = $bulkReplaceUndoRaw | ConvertFrom-Json } catch { throw 'CAT_REPLACE_UNDO_SNAPSHOT_INVALID: 直前の一括置換の復元記録を読めません。' }
            }
            if ($hasStructuralUndoContract -and $structuralUndoRaw -ne 'null') {
                try { $savedStructuralUndo = $structuralUndoRaw | ConvertFrom-Json } catch { throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 直前の構造編集の復元記録を読めません。' }
            }
            if ($savedSegmentRows.Count -ne [int]$o.segment_count -or $savedBlockRows.Count -ne [int]$o.block_count) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 保存世代の件数がmanifestと一致しません。' }
            if ([int]$o.schema_version -ge 4 -and $savedPlacementPlans.Count -ne [int]$o.placement_count) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 配置計画の件数がmanifestと一致しません。' }
            if ([int]$o.schema_version -ge 5 -and ($savedDocumentFindings.Count -ne [int]$o.document_finding_count -or $savedReviewRuns.Count -ne [int]$o.review_run_count)) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 文書校正の件数がmanifestと一致しません。' }
            if ([int]$o.schema_version -ge 6 -and $savedFinalReviewDecisions.Count -ne [int]$o.final_review_decision_count) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 最終確認判断の件数がmanifestと一致しません。' }
            if ([int]$o.schema_version -ge 7 -and ($savedPublicationVariants.Count -ne [int]$o.publication_variant_count -or $savedAbbreviationEntries.Count -ne [int]$o.abbreviation_entry_count -or $savedAbbreviationUses.Count -ne [int]$o.abbreviation_use_count)) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 掲載訳・略語の件数がmanifestと一致しません。' }
            if ([int]$o.schema_version -ge 8 -and $savedMutationReceipts.Count -ne [int]$o.mutation_receipt_count) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 更新receiptの件数がmanifestと一致しません。' }
            if ($hasBulkReplaceUndoContract -and [int]$o.bulk_replace_undo_count -ne $(if ($null -ne $savedBulkReplaceUndo) { [int]$savedBulkReplaceUndo.affected_count } else { 0 })) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 一括置換の復元記録件数がmanifestと一致しません。' }
            if ($hasStructuralUndoContract -and [int]$o.structural_undo_count -ne $(if ($null -ne $savedStructuralUndo) { [int]$savedStructuralUndo.affected_count } else { 0 })) { throw 'CAT_PROJECT_SNAPSHOT_INCOMPLETE: 構造編集の復元記録件数がmanifestと一致しません。' }
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
                TmRegistered = [bool]$s.tm_registered
                TmRegistrationEventId = [string]$s.tm_registration_event_id
                SplitGroupId = [string]$s.split_group_id
                SplitOrdinal = [int]$(if ($null -ne $s.split_ordinal) { $s.split_ordinal } else { 0 })
                SplitOriginSegmentId = [string]$s.split_origin_segment_id
                Pieces = @($(try { $s.pieces } catch { @() }))
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
        AmountNotation = $(if ([string]$o.amount_notation -eq 'billion') { 'billion' } else { 'oku' })
        DirectionBasis = $(if (-not [string]::IsNullOrWhiteSpace([string]$o.direction_basis)) { [string]$o.direction_basis } else { 'fixed' })
        DirectionConfidence = $(if (-not [string]::IsNullOrWhiteSpace([string]$o.direction_confidence)) { [string]$o.direction_confidence } else { 'not_applicable' })
        DirectionSourceFingerprint = [string]$o.direction_source_fingerprint
        TerminologySnapshotHash = [string]$o.terminology_snapshot_hash
        TmOutbox = @($o.tm_outbox)
        Lifecycle = $(if (@('transient','saved','deleting','deleted') -contains [string]$o.lifecycle) { [string]$o.lifecycle } else { 'saved' })
        RetentionUntil = [string]$o.retention_until
        PromotedAt = [string]$o.promoted_at
        DeletionMemoryPolicy = [string]$o.deletion_memory_policy
        ReviewEvents = @($savedReviewEvents)
        TextSourceStructure = $savedTextSourceStructure
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
        ActiveSourceId = [string]$o.active_source_id
        SourceSnapshots = @($o.source_snapshots)
        AppliedRebaseId = [string]$o.applied_rebase_id
        ActiveGenerationId = [string]$(if(-not [string]::IsNullOrWhiteSpace([string]$o.active_generation_id)){$o.active_generation_id}else{$o.generation_id})
        RebaseRecords = @($o.rebase_records)
        PlacementPlans = @($savedPlacementPlans)
        PlacementSetHash = [string]$o.placement_set_hash
        DocumentFindings = @($savedDocumentFindings)
        ReviewRuns = @($savedReviewRuns)
        DocumentIndexSnapshot = $(try{$o.document_index_snapshot}catch{$null})
        FinalReviewDecisions = @($savedFinalReviewDecisions)
        PublicationVariants = @($savedPublicationVariants)
        ActivePublicationVariantBySegment = $(if($null -ne $o.active_publication_variants){$o.active_publication_variants}else{[pscustomobject]@{}})
        AbbreviationEntries = @($savedAbbreviationEntries)
        AbbreviationUses = @($savedAbbreviationUses)
        MutationReceipts = @($savedMutationReceipts)
        PendingBulkReplaceUndo = $savedBulkReplaceUndo
        PendingStructuralUndo = $savedStructuralUndo
        PriorVersion = $o.prior_version
        VersionUpdateSummary = $o.version_update_summary
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$o.corpus_section)) {
        $project | Add-Member -NotePropertyName 'CorpusSection' -NotePropertyValue ([string]$o.corpus_section) -Force
        $project | Add-Member -NotePropertyName 'CorpusExamples' -NotePropertyValue @($o.corpus_examples) -Force
    }
    $null = Initialize-YakuCatProjectState -Project $project
    if ($null -ne $project.PendingBulkReplaceUndo) {
        $null = Assert-YakuCatBulkReplaceUndoSnapshot -Project $project -Snapshot $project.PendingBulkReplaceUndo -RequireCurrent
    }
    if ($null -ne $project.PendingStructuralUndo) {
        $null = Assert-YakuCatStructuralUndoSnapshot -Project $project -Snapshot $project.PendingStructuralUndo -RequireCurrent
    }
    $null = Assert-YakuCatActiveSourceSnapshotFingerprints -Project $project
    if ([string]$project.Source -eq 'file' -and
        ([string]::IsNullOrWhiteSpace([string]$project.SourceArtifactRelativePath) -or [string]$project.SourceArtifactContractVersion -ne 'cat-source-v2') -and
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
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowNull()]$Eligibility = $null
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segs = @($Project.Segments)
    $done = @($segs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
    # 進捗は「人が確認した数」で数える。機械が埋めた数だと、翻訳ボタンを
    # 押した瞬間に 100% になり、以後どれだけ確認しても動かない。
    # 数百行を何時間もかけて見る作業では、それは進捗表示として役に立たない。
    $confirmed = @($segs | Where-Object { [string]$_.State -eq 'reviewed' }).Count
    # 残りの量は行数だけでは分からない。1行が3文字の見出しと、200文字の注記が
    # 同じ1行として数えられるため。市販のCATが語数で見積もるのと同じ理由で、
    # 原文の文字数も出す（日本語に語の区切りが無いので、語数ではなく文字数）。
    $sourceChars = 0
    $confirmedChars = 0
    foreach ($seg in $segs) {
        $length = ([string]$seg.Text).Length
        $sourceChars += $length
        if ([string]$seg.State -eq 'reviewed') { $confirmedChars += $length }
    }
    if ($null -eq $Eligibility) { $Eligibility = Get-YakuCatOutputEligibility -Project $Project }
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
        SourceChars = [int]$sourceChars
        ConfirmedChars = [int]$confirmedChars
        RemainingChars = [int]($sourceChars - $confirmedChars)
        Revision = [int]$Project.Revision
        TranslationListEligible = [bool]$Eligibility.TranslationListEligible
        ExcelDraftEligible = [bool]$Eligibility.ExcelDraftEligible
        WordDraftEligible = [bool]$Eligibility.WordDraftEligible
        EligibilityReasons = @($Eligibility.Reasons)
    }
}

function Get-YakuCatRepetitionKey {
    <#
      同じ原文かどうかの鍵。前後の空白と、途中の空白の数だけを揃える。
      大文字小文字は畳まない。市販のCATツール（memoQ / Phrase）も反復は
      「同一の原文」で数えており、揺らぎを吸収するのは別の機能（あいまい一致）
      の役目だからである。ここを緩めると、違う訳が要る行へ勝手に配ってしまう。
    #>
    param([AllowNull()][string]$Text)
    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    return ([regex]::Replace($value.Trim(), '\s+', ' '))
}

function Copy-YakuCatTranslationToRepetitions {
    <#
      同じ原文の行へ訳文を配る。市販のCATツールでは標準の機能で、
      memoQ は auto-propagation、Phrase は repetitions と呼ぶ。確定のときに
      配るのも各ツールと同じ。

      ただし配り方はこのアプリの決まりに合わせて狭くする。
        - 訳文が空の行にだけ入れる。既にある訳は上書きしない
          （memoQ は既定で上書きするが、人が直した訳を消す危険は採らない）
        - 確認済みにはしない。数字の点検は確定のときにしか走らないので、
          点検を通っていない行を確認済みにはできない
        - 出どころは propagated。人がその行に書いた訳ではない
      返すのは、実際に入れた行数。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { return 0 }
    $translation = [string]$segs[$Index].Translation
    if ([string]::IsNullOrWhiteSpace($translation)) { return 0 }
    $key = Get-YakuCatRepetitionKey -Text ([string]$segs[$Index].Text)
    if ([string]::IsNullOrWhiteSpace($key)) { return 0 }
    $filled = 0
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($i -eq $Index) { continue }
        if ((Get-YakuCatRepetitionKey -Text ([string]$segs[$i].Text)) -ne $key) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
        $segs[$i].Translation = $translation
        $null = Update-YakuCatSegmentReferenceEditState -Segment $segs[$i] -Text $translation
        # マスク後の訳文は元の行のもの。引き継ぐと、この行の原文と対応しない
        # マスクのまま「直す」を実行してしまう。
        $segs[$i] | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue '' -Force
        $segs[$i].Origin = 'propagated'
        $segs[$i] | Add-Member -NotePropertyName State -NotePropertyValue 'machine_draft' -Force
        Reset-YakuCatSegmentQc -Segment $segs[$i] -KeepState
        $filled++
    }
    return $filled
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
    # 未確認の行を写しに掛けた点検と、契約を上げずに表示する advisory warning の
    # 結果（種別だけ）。書き出しを止めた理由の案内が
    # 「左の『点検の指摘』を押してください」と言う、その案内先を実際に開けるようにする。
    # **Segment.QcFindings とは別の鍵にする。** 混ぜると「この行の点検はいつ・どの
    # 用語一覧で行われたか」（Test-YakuCatSegmentQcCurrent と監査）が壊れる。
    $qcPreviewBySegment = @{}
    foreach ($qcRow in @($eligibility.QcRows)) {
        if ($null -eq $qcRow) { continue }
        $qcPreviewBySegment[[string]$qcRow.SegmentId] = @(@($qcRow.Codes) | ForEach-Object { [ordered]@{ code = [string]$_ } })
    }
    $placementBySegment = @{}
    foreach ($placement in @($Project.PlacementPlans)) { $placementBySegment[[string]$placement.segment_id] = $placement }
    # 途中で分けた行が、その組の何番目のいくつ中かを画面へ出すために先に数える。
    # 併せて、その組の訳文を繋いだものもここで作る（split_translation）。
    #
    # なぜサーバで作るか（2026-08-15 の欠陥）: 「体裁で見る」は割った行を先頭1つへ
    # まとめて描くが、配置先の無い行（貼り付け本文・Word）は part 1 の訳文のまま
    # 描いていた。後半の訳が画面から消え、画面で確認して出したのにファイルの中身が
    # 違う、という裏切りになる。かといって繋ぎ方を cat.js へ写すのは駄目である。
    # 繋ぎ方の規則（トークンの内側には空白を入れない・CJK なら詰める）は
    # Join-YakuCatSplitTranslations だけが持ち、2026-08-15 に変わったばかりで、
    # 写せば必ず片方が腐る（src/TranslationMemory.ps1:519 と同じ戒め）。
    # 配置先のある行が placement.destinations[].text をそのまま使っているのと
    # 同じ形にして、画面は計算済みの文字列を受け取るだけにする。
    $splitPartCounts = @{}
    $splitPartTranslations = @{}
    $splitPartSources = @{}
    foreach ($segment in $segs) {
        $splitGroup = Get-YakuCatSegmentSplitGroupId -Segment $segment
        if ($splitGroup -eq '') { continue }
        $splitPartCounts[$splitGroup] = [int]$(if ($splitPartCounts.ContainsKey($splitGroup)) { $splitPartCounts[$splitGroup] } else { 0 }) + 1
        if (-not $splitPartTranslations.ContainsKey($splitGroup)) {
            $splitPartTranslations[$splitGroup] = New-Object System.Collections.Generic.List[string]
            $splitPartSources[$splitGroup] = New-Object System.Collections.Generic.List[string]
        }
        [void]$splitPartTranslations[$splitGroup].Add([string]$segment.Translation)
        [void]$splitPartSources[$splitGroup].Add([string]$segment.Text)
    }
    $splitJoinedTranslations = @{}
    foreach ($splitGroup in @($splitPartCounts.Keys)) {
        # -Sources を必ず付ける。付けないとトークン境界の規則が効かず、
        # 画面だけが `AB- 1234` に戻る（書き戻しは正しいまま）。
        $splitJoinedTranslations[$splitGroup] = [string](Join-YakuCatSplitTranslations `
            -Parts $splitPartTranslations[$splitGroup].ToArray() `
            -Sources $splitPartSources[$splitGroup].ToArray())
    }
    # 反復（同じ原文の行）を先に数える。行ごとに数え直すと O(n^2) になる。
    $repetitionKeys = @{}
    $repetitionCounts = @{}
    $repetitionFirst = @{}
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $repetitionKey = Get-YakuCatRepetitionKey -Text ([string]$segs[$i].Text)
        $repetitionKeys[$i] = $repetitionKey
        if ([string]::IsNullOrWhiteSpace($repetitionKey)) { continue }
        if (-not $repetitionCounts.ContainsKey($repetitionKey)) { $repetitionCounts[$repetitionKey] = 0; $repetitionFirst[$repetitionKey] = $i }
        $repetitionCounts[$repetitionKey] = [int]$repetitionCounts[$repetitionKey] + 1
    }
    # Word の見出しの段と表の位置は、原本のブロックが持っている。行から引けるよう
    # ブロック番号で引ける形にしておく（行ごとに探すと資料の大きさの2乗になる）。
    # 古い作業には無い項目なので、無ければ「見出しでない・表でない」に落とす。
    $blockStructure = @{}
    foreach ($block in @($Project.Blocks)) {
        $blockId = [string]$block.Id
        if ([string]::IsNullOrWhiteSpace($blockId)) { continue }
        $meta = $block.Meta
        if ($null -eq $meta) { continue }
        $blockStructure[$blockId] = [ordered]@{
            heading_level = [int]$(try { if ($null -ne $meta.HeadingLevel) { $meta.HeadingLevel } else { 0 } } catch { 0 })
            table_index   = [int]$(try { if ($null -ne $meta.TableIndex) { $meta.TableIndex } else { -1 } } catch { -1 })
            table_row     = [int]$(try { if ($null -ne $meta.RowIndex) { $meta.RowIndex } else { -1 } } catch { -1 })
            table_column  = [int]$(try { if ($null -ne $meta.ColumnIndex) { $meta.ColumnIndex } else { -1 } } catch { -1 })
            table_span    = [int]$(try { if ($null -ne $meta.ColumnSpan) { $meta.ColumnSpan } else { 1 } } catch { 1 })
        }
    }
    for ($i = 0; $i -lt $segs.Count; $i++) {
        # 繋げた行は先頭のブロックの位置で出す。繋げた時点で見出しと本文は混ざらない。
        $structure = $null
        foreach ($blockId in @($segs[$i].BlockIds)) {
            if ($blockStructure.ContainsKey([string]$blockId)) { $structure = $blockStructure[[string]$blockId]; break }
        }
        # 途中で分けた行の配置計画は、組の番号で持っている（元の1セルに1つ）。
        $placementKey = Get-YakuCatSegmentSplitGroupId -Segment $segs[$i]
        if ($placementKey -eq '') { $placementKey = [string]$segs[$i].SegmentId }
        $rowPlacement = $placementBySegment[$placementKey]
        $rowPublication=$(if(Get-Command Resolve-YakuCatPublicationText -ErrorAction SilentlyContinue){Resolve-YakuCatPublicationText -Project $Project -Segment $segs[$i]}else{[pscustomobject]@{Text=[string]$segs[$i].Translation;VariantId='';VariantRevision=0;VariantHash='';IsVariant=$false}})
        [void]$rows.Add([ordered]@{
            index       = $i
            segment_id  = [string]$segs[$i].SegmentId
            source      = [string]$segs[$i].Text
            heading_level = [int]$(if ($structure) { $structure.heading_level } else { 0 })
            table_index   = [int]$(if ($structure) { $structure.table_index } else { -1 })
            table_row     = [int]$(if ($structure) { $structure.table_row } else { -1 })
            table_column  = [int]$(if ($structure) { $structure.table_column } else { -1 })
            table_span    = [int]$(if ($structure) { $structure.table_span } else { 1 })
            translation = [string]$segs[$i].Translation
            publication_translation = [string]$rowPublication.Text
            publication_variant_id = [string]$rowPublication.VariantId
            publication_variant_revision = [int]$rowPublication.VariantRevision
            publication_variant_hash = [string]$rowPublication.VariantHash
            has_publication_variant = [bool]$rowPublication.IsVariant
            placement = $(if ($null -ne $rowPlacement) { [ordered]@{
                placement_id=[string]$rowPlacement.placement_id; revision=[int]$rowPlacement.placement_revision
                kind=[string]$rowPlacement.placement_kind; status=[string]$rowPlacement.status; plan_hash=[string]$rowPlacement.plan_hash
                destinations=@($rowPlacement.destinations | ForEach-Object { [ordered]@{
                    block_id=[string]$_.block_id; sheet=[string]$_.sheet; address=[string]$_.address; text=[string]$_.text
                    mode=[string]$(try{$_.mode}catch{'replace_source_block'});empty_selection_ordinal=[int]$(try{$_.empty_selection_ordinal}catch{0})
                } })
                display_regions=@($rowPlacement.display_regions | ForEach-Object { [ordered]@{
                    mode=[string]$_.mode; sheet=[string]$_.sheet; anchor_address=[string]$_.anchor_address
                    cells=@($_.cells); verification=[string]$_.verification
                } })
            } } else { $null })
            origin      = [string]$segs[$i].Origin
            joined      = [bool]$segs[$i].Joined
            cells       = @($segs[$i].BlockIds).Count
            kind        = [string]$segs[$i].Kind
            location    = [string]$segs[$i].Location
            confirmed   = [bool]$segs[$i].Confirmed
            tm_registered = [bool]$(try { $segs[$i].TmRegistered } catch { $false })
            state       = [string]$segs[$i].State
            qc_status   = [string]$segs[$i].QcStatus
            qc_findings = @($segs[$i].QcFindings)
            # 未確定行を写しに掛けた結果、または保存済みの確認行へ advisory として
            # 足した種別。実セグメントには残らない（残すと点検の履歴が嘘になる）ので、
            # 画面へはこちらで渡す。
            # 種別だけを持ち、用語の免除に使う TermId は載せない。
            qc_preview = @($(if ($qcPreviewBySegment.ContainsKey([string]$segs[$i].SegmentId)) { $qcPreviewBySegment[[string]$segs[$i].SegmentId] } else { @() }))
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
            # 判定は Merge-YakuCatSegments と同じ関数から取る。押せると書いた
            # ボタンが通らない（またはその逆）が起きないようにするため。
            can_merge   = ($i -lt ($segs.Count - 1)) -and (Test-YakuCatSegmentsMergeable -First $segs[$i] -Second $segs[$i + 1])
            can_split   = (([string]$segs[$i].Kind -eq 'cell' -and @($segs[$i].Cells).Count -gt 1) -or
                           ([string]$segs[$i].Kind -eq 'text' -and @(Get-YakuCatTextPieces -Segment $segs[$i]).Count -gt 1))
            # 原文の途中で2つに割れるか。判定は Split-YakuCatSegmentAt と同じ関数。
            can_split_at = (Test-YakuCatSegmentSplittable -Segment $segs[$i])
            split_group = [string]$(if ($splitPartCounts.ContainsKey([string]$segs[$i].SplitGroupId)) { [string]$segs[$i].SplitGroupId } else { '' })
            split_part  = [int]$(if ($splitPartCounts.ContainsKey([string]$segs[$i].SplitGroupId)) { [int]$segs[$i].SplitOrdinal + 1 } else { 0 })
            split_parts = [int]$(if ($splitPartCounts.ContainsKey([string]$segs[$i].SplitGroupId)) { $splitPartCounts[[string]$segs[$i].SplitGroupId] } else { 0 })
            # その組の訳文を繋いだもの。「体裁で見る」が、配置先の無い行（貼り付け
            # 本文・Word）でも後半の訳を出せるようにするため。繋ぎ方の規則は
            # Join-YakuCatSplitTranslations だけが持つ（上の計算を参照）。
            split_translation = [string]$(if ($splitJoinedTranslations.ContainsKey([string]$segs[$i].SplitGroupId)) { $splitJoinedTranslations[[string]$segs[$i].SplitGroupId] } else { '' })
            # 同じ原文が何行あるか。1 なら反復ではない。
            repetition_count = [int]$(if ($repetitionCounts.ContainsKey([string]$repetitionKeys[$i])) { $repetitionCounts[[string]$repetitionKeys[$i]] } else { 1 })
            repetition_first = [bool]($repetitionFirst.ContainsKey([string]$repetitionKeys[$i]) -and [int]$repetitionFirst[[string]$repetitionKeys[$i]] -eq $i)
        })
    }
    $summary = Get-YakuCatProjectSummary -Project $Project -Eligibility $eligibility
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
    # 体裁（列幅・折り返し・結合）。原本の写しから Office 抜きで読む。
    # 同じ資料で何度も読まないよう、作業ごとに1回だけ覚える。読めなくても翻訳は続く。
    $sheetLayout = @()
    try {
        $layoutPath = [string]$Project.Path
        if ((-not [string]::IsNullOrWhiteSpace($layoutPath)) -and ($layoutPath.ToLowerInvariant().EndsWith('.xlsx') -or $layoutPath.ToLowerInvariant().EndsWith('.xlsm'))) {
            if ($null -eq $script:YakuSheetLayoutCache) { $script:YakuSheetLayoutCache = @{} }
            $layoutKey = [string]$Project.Id + '|' + [string]$Project.Revision
            if (-not $script:YakuSheetLayoutCache.ContainsKey($layoutKey)) {
                $script:YakuSheetLayoutCache[$layoutKey] = @(Get-YakuSheetLayoutFromXlsx -Path $layoutPath)
            }
            $sheetLayout = @($script:YakuSheetLayoutCache[$layoutKey])
        }
    } catch { $sheetLayout = @() }
    return ([ordered]@{
        id         = [string]$Project.Id
        revision   = [int]$Project.Revision
        source     = $(try { [string]$Project.Source } catch { 'file' })
        lifecycle  = $(try { [string]$Project.Lifecycle } catch { 'saved' })
        retention_until = $(try { [string]$Project.RetentionUntil } catch { '' })
        placement_set_hash = $(try { [string]$Project.PlacementSetHash } catch { '' })
        sheet_layout = @($sheetLayout)
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
        active_source_id = $(try { [string]$Project.ActiveSourceId } catch { '' })
        source_artifact_sha256 = $(try { [string]$Project.SourceArtifactSha256 } catch { '' })
        direction  = [string]$Project.Direction
        terminology_snapshot_hash = [string]$Project.TerminologySnapshotHash
        abbreviation_registry_hash = $(if(Get-Command Get-YakuCatAbbreviationRegistryHash -ErrorAction SilentlyContinue){Get-YakuCatAbbreviationRegistryHash -Project $Project}else{''})
        tm_pending = $(try { [int]$Project.TmPendingCount } catch { 0 })
        bulk_replace_undo = $(if ($null -ne $Project.PendingBulkReplaceUndo) {
            [ordered]@{ available=$true; affected_count=[int]$Project.PendingBulkReplaceUndo.affected_count }
        } else { [ordered]@{ available=$false; affected_count=0 } })
        structural_undo = $(if ($null -ne $Project.PendingStructuralUndo) {
            [ordered]@{ available=$true; operation=[string]$Project.PendingStructuralUndo.operation; affected_count=[int]$Project.PendingStructuralUndo.affected_count }
        } else { [ordered]@{ available=$false; operation=''; affected_count=0 } })
        total      = [int]$summary.Total
        translated = [int]$summary.Translated
        remaining  = [int]$summary.Remaining
        joined     = [int]$summary.Joined
        confirmed   = [int]$summary.Confirmed
        unconfirmed = [int]$summary.Unconfirmed
        source_chars = [int]$summary.SourceChars
        remaining_chars = [int]$summary.RemainingChars
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

function Get-YakuCatTranslationMemoryExactMatch {
    <#
      1行ぶんの完全一致を翻訳メモリから引く。あいまい一致は使わない。

      閾値の話をここへ持ち込まない（あいまい一致を自動で流し込むと、直す手間の
      ほうが増える）。

      **ここでいう完全一致は、原文そのままの一致ではない。**
      ConvertTo-YakuTranslationMemoryKey による正規化後の一致であり、
      空白の有無・英数字の全半角・英字の大小は同じものとして扱う
      （TranslationMemory.ps1:19）。数字は落とさないので、数値の取り違えは
      起きない（'100億円' の原文に '200億円' のTMは当たらない。実測済み）。
      候補ペインは人が選ぶので差が出なかったが、事前翻訳は人が見ないまま
      流し込むため、この定義は意図として明記しておく。

      引き方は Find-YakuTranslationMemoryExact（鍵の索引）。かつては
      Find-YakuTranslationMemory を Limit 1 で呼んでいたが、それは全件に
      3-gram Dice を回してから Exact 以外を捨てる作りで、翻訳メモリの件数に
      比例して遅くなった（TM 3,000件・400行で見積り25.7秒＋反映24.4秒。
      サーバの待ち受けは直列1本なので、その間アプリ全体が止まる）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Direction,
        [AllowNull()][string]$Path
    )
    $hits = @()
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $hits = @(Find-YakuTranslationMemoryExact -Text $Text -Direction $Direction)
    } else {
        $hits = @(Find-YakuTranslationMemoryExact -Text $Text -Direction $Direction -Path $Path)
    }
    foreach ($hit in $hits) {
        if (-not [bool]$hit.Exact) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$hit.Target)) { continue }
        return $hit
    }
    return $null
}

function Get-YakuCatTranslationMemoryPretranslatePlan {
    <#
      事前翻訳（pre-translate）の対象を作る。埋めはしない。数えるためにも使う。

      **なぜこのアプリで効くのか。**

      ~~翻訳の相手は API ではなく Copilot で、使用上限がある。翻訳メモリが1件
      当たるたびに Copilot への送信が1件減り、その分だけ訳せる分量が増える~~
      **2026-08-16 に取り消した。** 利用者の判断で「呼び出し回数の設計上の上限は
      無い」となり、**「上限があるから」を理由に呼び出し回数を惜しむ設計はしない**
      と決まった（CLAUDE.md）。実装にも上限は無く、`src/CopilotBudget.ps1` は
      数えて記録へ註を書くだけで、止める関数を持たない。

      いま効く理由は2つあり、どちらも上限とは関係がない。

        1. **同じ原文へ同じ訳を返す。** 何ページも訳すあいだ、去年と同じ注記に
           去年と同じ英文が入る。Copilot は同じ原文でも呼ぶたびに言い回しが
           揺れるので、確定済みの訳を先に置くことでしか揃えられない。
           利用者が挙げた要件のうち、いちばん重いのがこれである
        2. **速い。** 1件当たるごとに往復が1回減る。Copilot の応答は速くなったが
           それでも往復は往復で、行数ぶん積み上がる

      市販CAT（memoQ / Trados / Phrase / XTM）はどれも持っている機能だが、
      ここでの理由は「他所にあるから」ではなく、この2つである。

      対象にするのは訳文が空の行だけ。人が直した行（Origin=manual /
      State=human_edited）は、訳文が空でも踏まない。

      同じ原文は1回だけ引いて、結果を行へ配る。Get-YakuCatCopilotUsage が
      重複を除いた原文の数を数えているので、引く回数もそれに揃う。

      翻訳メモリが読めないときは、そこで打ち切って空の計画を返す。
      コーパスや翻訳メモリは足しであって前提ではない。読めなければ、
      対象行は空のまま Copilot への送信対象として残る。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowNull()][string]$Path
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $uniqueTexts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $direction = [string]$Project.Direction
    if ($direction -ne 'to_en' -and $direction -ne 'to_jp') {
        return [pscustomobject]@{ Rows = @(); UniqueTexts = 0; MemoryUnavailable = $false }
    }
    # 過去訳の対応確認（Source='align'）では1行も埋めない。
    # あの資料の行は「この日本語に、この英語が対応していた」という**記録**であって、
    # 訳す対象ではない。対応の無い行も片側が空のまま作られる（CatProject.ps1:1599 は
    # ja と en の両方が空のときだけ飛ばす）ので、そこへ翻訳メモリの訳を入れると、
    # 実際には存在しなかった対応を人が確認したことにしてしまう。
    # 画面はボタンを隠しているが（cat.js:673）、隠すのは目に見える入口だけである。
    if ([string]$Project.Source -eq 'align') {
        return [pscustomobject]@{ Rows = @(); UniqueTexts = 0; MemoryUnavailable = $false }
    }
    $lookup = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $unavailable = $false
    $segs = @($Project.Segments)
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
        if ([string]$segs[$i].Origin -eq 'manual' -or [string]$segs[$i].State -eq 'human_edited') { continue }
        $text = [string]$segs[$i].Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if (-not $lookup.ContainsKey($text)) {
            $found = $null
            try { $found = Get-YakuCatTranslationMemoryExactMatch -Text $text -Direction $direction -Path $Path }
            catch {
                # 1件で落ちるなら残りも落ちる。読めない相手を全行ぶん叩き直さない。
                $unavailable = $true
                try { Write-YakuLog ('Translation memory pre-translate unavailable: ' + $_.Exception.Message) 'WARN' } catch {}
                break
            }
            $lookup[$text] = $found
        }
        $hit = $lookup[$text]
        if ($null -eq $hit) { continue }
        [void]$rows.Add([pscustomobject]@{ Index = $i; Text = $text; Hit = $hit })
        [void]$uniqueTexts.Add($text)
    }
    return [pscustomobject]@{
        Rows = @($rows.ToArray())
        UniqueTexts = [int]$uniqueTexts.Count
        MemoryUnavailable = [bool]$unavailable
    }
}

# 2026-08-15: Measure-YakuCatTranslationMemoryCandidates をここから削除した。
# 「押す前に何行埋まるか」を数えるだけの薄い包みだったが、本番の呼び出し元は
# 0件で、Server.ps1 の tm-pretranslate-estimate は Get-...PretranslatePlan を
# 直に呼んでいた。それでも回帰はこの包みへ向けて「押す前に告げる行数が、
# 実際に埋まる行数と一致する」を表明していたので、**サーバの rows を 0 に
# 固定して機能を殺しても緑のまま**だった（批評の実測）。製品が通らない道に
# 門を置くと、門があるという事実そのものが嘘になる。数えるのは計画の
# Rows.Count で足り、包みは要らない。

function Invoke-YakuCatTranslationMemoryPass {
    <#
      翻訳メモリの完全一致を訳文欄へ流し込む。市販CATの Pre-translate。

      入れ方は、同一原文への自動伝播（Copy-YakuCatTranslationToRepetitions）と
      同じ扱いにそろえる。
        - 訳文が空の行にだけ入れる。人が直した訳は上書きしない
        - **確認済みにはしない。** 数字の点検は確定のときにしか走らないので、
          点検を通っていない訳を確認済みにはできない。State は machine_draft
        - 出どころは translation-memory。人がその行に書いた訳ではない
        - マスク後の訳文は引き継がない。この行の原文と対応しない

      返すのは、入れた行数（Applied）と、そのもとになった原文の種類数
      （UniqueApplied）。Copilot への送信は重複を除いた原文の数で決まるので、
      減る送信数は UniqueApplied のほうである。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowNull()][string]$Path
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $plan = $null
    try { $plan = Get-YakuCatTranslationMemoryPretranslatePlan -Project $Project -Path $Path }
    catch {
        # 翻訳メモリを引く所は計画側で受け止めてあるので、通常ここへは来ない。
        # 引く以外（行の走査そのもの）が落ちたときの受け皿である。翻訳メモリは
        # 足しであって前提ではないので、ここでも作業は止めない。
        # 2026-08-14: 計画側の受け止めを外して壊したとき、実際にここが受けた。
        try { Write-YakuLog ('Translation memory pre-translate skipped: ' + $_.Exception.Message) 'WARN' } catch {}
        $plan = $null
    }
    $segs = @($Project.Segments)
    $applied = 0
    $uniqueApplied = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($null -ne $plan) {
        foreach ($row in @($plan.Rows)) {
            $i = [int]$row.Index
            if ($i -lt 0 -or $i -ge $segs.Count) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$segs[$i].Translation)) { continue }
            $target = [string]$row.Hit.Target
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            $segs[$i].Translation = $target
            $null = Update-YakuCatSegmentReferenceEditState -Segment $segs[$i] -Text $target
            $segs[$i] | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue '' -Force
            $segs[$i].Origin = 'translation-memory'
            $segs[$i] | Add-Member -NotePropertyName State -NotePropertyValue 'machine_draft' -Force
            $segs[$i].TmRegistered = $false
            $segs[$i].TmRegistrationEventId = ''
            Reset-YakuCatSegmentQc -Segment $segs[$i] -KeepState
            # どのTM単位から来たかを行へ残す。候補を手で挿したときと同じ形にする。
            # Project ごと初期化し直す口（Set-YakuCatSegmentReferenceUsage）は
            # 使わない。行ごとに全行を舐め直すので、資料の大きさの2乗になる。
            try {
                $null = Set-YakuCatSegmentReferenceUsageRecord -Segment $segs[$i] -ProjectRevision ([int]$Project.Revision) -Candidate ([pscustomobject]@{
                    Kind = 'memory'; ReferenceId = [string]$row.Hit.ReferenceId
                    SourceName = [string]$row.Hit.SourceName; Location = [string]$row.Hit.Location
                    Page = [int]$(try { $row.Hit.Page } catch { 0 })
                    Source = [string]$row.Hit.Source; Target = $target
                    Score = [double]$(try { $row.Hit.Score } catch { 1.0 })
                    Ratio = [double]$(try { $row.Hit.Ratio } catch { 1.0 })
                })
            } catch {
                try { Write-YakuLog ('Translation memory pre-translate provenance skipped: ' + $_.Exception.Message) 'WARN' } catch {}
            }
            $applied++
            [void]$uniqueApplied.Add([string]$row.Text)
        }
    }
    return [pscustomobject]@{
        Applied = [int]$applied
        UniqueApplied = [int]$uniqueApplied.Count
        Remaining = [int]@($segs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Translation) }).Count
        MemoryUnavailable = [bool]$(if ($null -eq $plan) { $true } else { [bool]$plan.MemoryUnavailable })
    }
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
    return 'canonical-v1|reference:none|mask:numeric-v1|validation:cat-v2'
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
    $null = Protect-YakuCatItems -Items @($items.ToArray()) -Root $Root -Direction ([string]$Project.Direction) -Notation (Get-YakuCatProjectAmountNotation -Project $Project)
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
        [Parameter(Mandatory=$true)][string]$Direction,
        # 金額の書き方は作業ごとに固定する。点検も同じ表記で突き合わせるため、
        # ここと点検側がずれると、正しい訳をアプリ自身が弾く。
        [ValidateSet('oku','billion')][string]$Notation='oku'
    )
    $maskedItems = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $text = [string]$item.Text
        $item | Add-Member -NotePropertyName OriginalText -NotePropertyValue $text -Force
        # CAT translation uses the dedicated canonical contract and protects every unit here.
        # 呼ぶため、ここで単位変換を済ませる。先に数値を伏せると
        # 18万6千台 が [[N1]]万[[N2]]千台 に割れ、1つの数量へ戻せない。
        $numericPre = Convert-YakuNumericUnits -Text $text -Notation $Notation -Location ("cat-ID-" + [string]$item.Index)
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

function Test-YakuCatSegmentsMergeable {
    <#
      隣り合う2行を繋げるか。

      画面のボタン（can_merge）と Merge-YakuCatSegments が同じ答えを出すよう、
      判定はここ1か所に置く。押せないボタンを見せないためだけではない。
      「押せる」と書いてあるボタンが必ず通ることのほうが大事である。

      途中で分けた行は、分けた相手とだけ繋げる。別の行と繋ぐと、同じセルを
      指す行が離れ、書き戻しで前半の訳が消える。
    #>
    param([Parameter(Mandatory=$true)]$First,[Parameter(Mandatory=$true)]$Second)
    $groupA = Get-YakuCatSegmentSplitGroupId -Segment $First
    $groupB = Get-YakuCatSegmentSplitGroupId -Segment $Second
    if ($groupA -ne '' -or $groupB -ne '') { return ($groupA -ne '' -and $groupA -eq $groupB) }
    if ([string]$First.Kind -ne [string]$Second.Kind) { return $false }
    if ([string]$First.Kind -eq 'text') { return $true }
    if ([string]$First.Kind -ne 'cell') { return $false }
    return ([string]$First.Sheet -eq [string]$Second.Sheet)
}

function Test-YakuCatSegmentSplittable {
    <#
      原文の途中で2つに割れる行か。

      繋いだ行（複数セル・複数断片）はここでは割らせない。先に「つなげた行を
      元に戻す」で境目へ戻してから割る。こうしておくと、割った行はどれも元の
      セル（段落）1つだけを指すので、書き戻しは常に「その1つへ繋いで戻す」で
      済み、重み配分と入れ子にならない。
    #>
    param([Parameter(Mandatory=$true)]$Segment)
    $text = [string]$Segment.Text
    if ($text.Length -lt 2) { return $false }
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $kind = [string]$Segment.Kind
    if ($kind -eq 'cell') { return (@($Segment.Cells).Count -eq 1) }
    if ($kind -eq 'text') { return (@(Get-YakuCatTextPieces -Segment $Segment).Count -le 1) }
    # Word の段落・ヘッダー・脚注。塊1つに対して行1つなので、セルと同じ扱いでよい。
    if ($kind -like 'word_*') { return (@($Segment.BlockIds).Count -eq 1) }
    return $false
}

function New-YakuCatSplitPart {
    <#
      割った片方の行を作る。「どのセル（段落）から来たか」はそのまま引き継ぎ、
      訳文・出どころ・点検の結果だけを落とす。
    #>
    param(
        [Parameter(Mandatory=$true)]$Source,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$GroupId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$OriginSegmentId
    )
    $part = [pscustomobject]@{
        SegmentId = [guid]::NewGuid().ToString('N')
        Text = [string]$Text
        SourceRevision = 1
        SourceIntegrityHash = (Get-YakuCatSourceIntegrityHash -Text ([string]$Text))
        Translation = ''
        MaskedTranslation = ''
        Origin = ''
        State = 'untranslated'
        QcStatus = 'not_run'
        QcSourceRevision = 0
        QcSourceHash = ''
        QcTargetHash = ''
        QcContractVersion = ''
        QcTerminologyHash = ''
        QcFindings = @()
        Confirmed = $false
        Joined = [bool]$Source.Joined
        Kind = [string]$Source.Kind
        Sheet = [string]$Source.Sheet
        Location = [string]$Source.Location
        BlockIds = @($Source.BlockIds)
        Cells = @($Source.Cells)
        TmRegistered = $false
        TmRegistrationEventId = ''
        SplitGroupId = [string]$GroupId
        SplitOrdinal = 0
        SplitOriginSegmentId = [string]$OriginSegmentId
    }
    if (@($Source.PSObject.Properties.Name) -contains 'Pieces') { $part | Add-Member -NotePropertyName Pieces -NotePropertyValue @() -Force }
    return $part
}

function Update-YakuCatSplitOrdinals {
    <#
      組の中の並び番号を振り直す。組が1つになったら、割った印そのものを外す。
      元の原文へ戻ったということなので、以後はふつうの行として扱う。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $segs = @($Project.Segments)
    $counts = @{}
    foreach ($s in $segs) {
        $g = Get-YakuCatSegmentSplitGroupId -Segment $s
        if ($g -eq '') { continue }
        $counts[$g] = [int]$(if ($counts.ContainsKey($g)) { $counts[$g] } else { 0 }) + 1
    }
    $seen = @{}
    foreach ($s in $segs) {
        $g = Get-YakuCatSegmentSplitGroupId -Segment $s
        if ($g -eq '') { continue }
        if ([int]$counts[$g] -le 1) {
            $s | Add-Member -NotePropertyName SplitGroupId -NotePropertyValue '' -Force
            $s | Add-Member -NotePropertyName SplitOrdinal -NotePropertyValue 0 -Force
            continue
        }
        $n = [int]$(if ($seen.ContainsKey($g)) { $seen[$g] } else { 0 })
        $s | Add-Member -NotePropertyName SplitOrdinal -NotePropertyValue $n -Force
        $seen[$g] = $n + 1
    }
    return $Project
}

function Split-YakuCatSegmentAt {
    <#
      1つの行を、原文の指定した位置で2つに割る。

      なぜ要るか（2026-08-15）:
        自動の切り分けが1つの原文をまとめすぎた場合、「つなげた行を元に戻す」
        ではセルの境目までしか戻せない。1つのセルの中に2文が入っていると、
        そこから先は Excel を開いて直すことになり、書き戻しの往復が壊れる。
        memoQ(Ctrl+T) / Phrase(Ctrl+E) / Smartcat / Trados / XTM のどれもが
        任意位置の分割を持つのは、日本語の自動分割が「。」や箇条書きで
        外れるのが日常だからである。

      訳文は両方とも消す。理由は Merge-YakuCatSegments と同じで、割った後の
      原文は割る前とは別の文だからである。前の訳文を片方へ残すと、原文の
      半分しか述べていない訳が「訳済み」の見た目で残る。しかも数値は原文
      全体ぶんが訳文に残っているので、§8「数値が抜けた訳は警告ではなく欠陥」
      の点検にも掛からないまま通ってしまう。消したうえで、割った行は未確認
      （Confirmed=$false）から始め、確定のときに必ず点検を通す。

      位置は原文の文字位置（先頭からの文字数）。0・末尾・範囲外は弾く。
      片方が空白だけになる位置も弾く。空の行は書き出しを永久に止めるためである。
      単語や数字の内側（`AB-` と `1234` の間）も弾く。そこで割ると書き戻しの
      ときに訳文へ空白が1つ入るが、数字は1桁も欠けないので数値QCに掛からず、
      割った後は片側ずつしか点検しないので原理的に見えない（2026-08-15）。
      判定は Test-YakuCatSplitPositionInsideToken が唯一持つ。ここへ写さない。
      既に割ってある資料は弾かない。そちらは繋ぎ方（Join-YakuCatSplitTranslations）
      で直す。利用者の作業を巻き戻さないためである。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index,
        [Parameter(Mandatory=$true)][int]$Position
    )
    $segs = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segs.Count) { throw 'セグメントが見つかりません。' }
    $target = $segs[$Index]
    if (-not (Test-YakuCatSegmentSplittable -Segment $target)) {
        throw 'この行は途中で分けられません。つなげた行は、先に「つなげた行を元に戻す」で戻してください。'
    }
    $text = [string]$target.Text
    if ($Position -le 0 -or $Position -ge $text.Length) { throw '分ける位置が原文の範囲の外です。原文の途中をクリックしてから、もう一度お試しください。' }
    $left = $text.Substring(0, $Position)
    $right = $text.Substring($Position)
    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) {
        throw 'その位置で分けると、片方が空になります。別の位置を選んでください。'
    }
    if (Test-YakuCatSplitPositionInsideToken -Text $text -Position $Position) {
        throw 'その位置は単語や数字の途中です（例: 型式や品番の「AB-1234」）。そこで分けると、書き戻すときに訳文へ空白が入り、点検では見つかりません。語の切れ目まで位置をずらしてから、もう一度お試しください。'
    }
    $groupId = Get-YakuCatSegmentSplitGroupId -Segment $target
    if ($groupId -eq '') { $groupId = [guid]::NewGuid().ToString('N') }
    $originId = [string]$(try { $target.SplitOriginSegmentId } catch { '' })
    if ([string]::IsNullOrWhiteSpace($originId)) { $originId = [string]$target.SegmentId }
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($i -ne $Index) { [void]$out.Add($segs[$i]); continue }
        foreach ($piece in @($left, $right)) {
            [void]$out.Add((New-YakuCatSplitPart -Source $target -Text $piece -GroupId $groupId -OriginSegmentId $originId))
        }
    }
    Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
    $null = Update-YakuCatSplitOrdinals -Project $Project
    return $Project
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
    if (-not (Test-YakuCatSegmentsMergeable -First $a -Second $b)) {
        # 断る理由は、画面の言葉のまま返す。判定そのものは
        # Test-YakuCatSegmentsMergeable が1か所で持つ（can_merge と同じ答えにする）。
        if ((Get-YakuCatSegmentSplitGroupId -Segment $a) -ne '' -or (Get-YakuCatSegmentSplitGroupId -Segment $b) -ne '') {
            throw '途中で分けた行は、分けた相手とだけ繋げられます。'
        }
        if ([string]$a.Kind -ne [string]$b.Kind) { throw '種類が違うため結合できません。' }
        if ([string]$a.Kind -ne 'cell') { throw 'セル以外は結合できません。' }
        throw 'シートが違うため結合できません。'
    }
    $splitGroupId = Get-YakuCatSegmentSplitGroupId -Segment $a
    if ($splitGroupId -ne '') {
        # 途中で分けた行を元へ戻す。原文はそのままの部分文字列なので、
        # 何も挟まずに繋ぐと、割る前の原文へ一字一句そのまま戻る。
        $restored = New-YakuCatSplitPart -Source $a -Text ((([string]$a.Text)) + ([string]$b.Text)) `
            -GroupId $splitGroupId -OriginSegmentId ([string]$(try { $a.SplitOriginSegmentId } catch { '' }))
        $out = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($i -eq $Index) { [void]$out.Add($restored); continue }
            if ($i -eq ($Index + 1)) { continue }
            [void]$out.Add($segs[$i])
        }
        Set-YakuCatSegments -Project $Project -Segments @($out.ToArray())
        $null = Update-YakuCatSplitOrdinals -Project $Project
        return $Project
    }
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

function Copy-YakuCatStructuralUndoValue {
    # serializer ではなく JSON を境界にする。generation artifact と同じ表現にして、
    # candidate の可変な入れ子（QC/出典/用語）を snapshot と共有しない。
    param([Parameter(Mandatory=$true)]$Value)
    return (($Value | ConvertTo-Json -Depth 40 -Compress) | ConvertFrom-Json)
}

function Get-YakuCatStructuralUndoSegmentState {
    param([Parameter(Mandatory=$true)]$Segment)
    # 順序も訳文付随状態も含める。PlacementPlans は Save 直前に Segments から再生成
    # される派生物なので、この hash には含めない（保存だけで変わる値を stale と誤認
    # しないため）。
    return [ordered]@{
        segment_id=[string]$Segment.SegmentId;text=[string]$Segment.Text;source_revision=[int]$Segment.SourceRevision;source_integrity_hash=[string]$Segment.SourceIntegrityHash
        translation=[string]$Segment.Translation;masked_translation=[string]$Segment.MaskedTranslation;origin=[string]$Segment.Origin;state=[string]$Segment.State
        qc_status=[string]$Segment.QcStatus;qc_source_revision=[int]$Segment.QcSourceRevision;qc_source_hash=[string]$Segment.QcSourceHash;qc_target_hash=[string]$Segment.QcTargetHash
        qc_contract_version=[string]$Segment.QcContractVersion;qc_terminology_hash=[string]$Segment.QcTerminologyHash;qc_findings=@($Segment.QcFindings);confirmed=[bool]$Segment.Confirmed
        joined=[bool]$Segment.Joined;kind=[string]$Segment.Kind;sheet=[string]$Segment.Sheet;location=[string]$Segment.Location;block_ids=@($Segment.BlockIds);cells=@($Segment.Cells)
        change_kind=$(try{[string]$Segment.ChangeKind}catch{''});prior_source_text=$(try{[string]$Segment.PriorSourceText}catch{''});prior_translation=$(try{[string]$Segment.PriorTranslation}catch{''});reuse_evidence=$(try{[string]$Segment.ReuseEvidence}catch{''});prior_index=$(try{[int]$Segment.PriorIndex}catch{-1})
        reference_usage=$(try{$Segment.ReferenceUsage}catch{$null});reference_events=@($(try{$Segment.ReferenceEvents}catch{@()}));terminology_usages=@($(try{$Segment.TerminologyUsages}catch{@()}));terminology_exceptions=@($(try{$Segment.TerminologyExceptions}catch{@()}));terminology_generation=@($(try{$Segment.TerminologyGeneration}catch{@()}))
        tm_registered=[bool]$(try{$Segment.TmRegistered}catch{$false});tm_registration_event_id=[string]$(try{$Segment.TmRegistrationEventId}catch{''});split_group_id=[string]$(try{$Segment.SplitGroupId}catch{''});split_ordinal=[int]$(try{$Segment.SplitOrdinal}catch{0});split_origin_segment_id=[string]$(try{$Segment.SplitOriginSegmentId}catch{''});pieces=@($(try{$Segment.Pieces}catch{@()}))
    }
}

function Get-YakuCatStructuralUndoSegmentsHash {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Segments)
    $canonical=@($Segments | ForEach-Object { Get-YakuCatStructuralUndoSegmentState -Segment $_ })
    return (Get-YakuCatSourceIntegrityHash -Text ($canonical | ConvertTo-Json -Depth 40 -Compress))
}

function Get-YakuCatStructuralUndoPlacementPlanIds {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)][int]$Index,[Parameter(Mandatory=$true)][int]$Count)
    $wanted=New-Object 'System.Collections.Generic.HashSet[int]'
    for($i=$Index;$i -lt ($Index+$Count);$i++){[void]$wanted.Add($i)}
    $ids=New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($unit in @(Get-YakuCatPlacementUnits -Project $Project)){
        $hit=$false;foreach($unitIndex in @($unit.Indices)){if($wanted.Contains([int]$unitIndex)){$hit=$true;break}}
        if($hit){[void]$ids.Add([string]$unit.Segment.SegmentId)}
    }
    # HashSet[T] に LINQ の ToArray は生えていない。PowerShell 5.1 では文字列が
    # 1件のときにそのまま $ids へ落ちるので、配列キャストで返す。
    return [string[]]$ids
}

function Get-YakuCatStructuralUndoPlacementPlansHash {
    param([AllowEmptyCollection()][object[]]$Plans)
    return (Get-YakuCatSourceIntegrityHash -Text ((@($Plans)|ConvertTo-Json -Depth 24 -Compress)))
}

function New-YakuCatStructuralUndoSnapshot {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [ValidateSet('merge','split','split-at')][string]$Operation,
        [ValidateRange(1,2)][int]$AffectedCount,
        [Parameter(Mandatory=$true)][int]$Index
    )
    $segs=@($Project.Segments)
    if($Index -lt 0 -or ($Index+$AffectedCount) -gt $segs.Count){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 構造編集の対象行を確認できません。'}
    # 資料全体を複写すると513行目から結合すらできなくなる。保存するのは破棄される
    # 1～2行だけ、資料全体は正規化hashで照合する。これなら大きなCAT案件にも効く。
    $beforeRows=@($segs[$Index..($Index+$AffectedCount-1)])
    $beforePlacementIds=@(Get-YakuCatStructuralUndoPlacementPlanIds -Project $Project -Index $Index -Count $AffectedCount)
    $beforePlacementPlans=@($Project.PlacementPlans|Where-Object{$beforePlacementIds -contains ([string]$_.segment_id)}|ForEach-Object{Copy-YakuCatStructuralUndoValue -Value $_})
    # PlacementSetHash は JSON の順序も含む。対象外の human_confirmed を触らず、
    # 対象だけ差し戻しても末尾へ append すると元の hash には戻らないので、ID の
    # 順序だけも記録する（計画本文は対象行分だけ）。
    $beforePlacementOrder=@($Project.PlacementPlans|ForEach-Object{[string]$_.segment_id})
    $snapshot=[ordered]@{
        version=1;project_id=[string]$Project.Id;operation=$Operation;affected_count=$AffectedCount;created_at=(Get-Date).ToString('o')
        before_segment_count=$segs.Count;before_state_hash=(Get-YakuCatStructuralUndoSegmentsHash -Segments $segs);before_index=$Index
        before_rows_hash=(Get-YakuCatStructuralUndoSegmentsHash -Segments $beforeRows)
        before_segments=@($beforeRows|ForEach-Object{Copy-YakuCatStructuralUndoValue -Value $_})
        # auto計画と違い human_confirmed は人が調整した境界そのもの。復元では
        # 同じ SegmentId にだけ差し戻し、別の新行へ横流ししない。
        before_placement_plan_ids=@($beforePlacementIds);before_placement_plans=@($beforePlacementPlans);before_placement_plan_order=@($beforePlacementOrder)
        before_placement_plans_hash=(Get-YakuCatStructuralUndoPlacementPlansHash -Plans $beforePlacementPlans);before_placement_set_hash=[string]$Project.PlacementSetHash
        before_publication_variants=@();before_active_publication_variants=[pscustomobject]@{}
        post_segment_count=0;post_state_hash='';post_replace_count=0;post_window_hash='';post_segment_ids=@();removed_segment_ids=@()
    }
    $json=$snapshot|ConvertTo-Json -Depth 40 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json)-gt 1048576){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_TOO_LARGE: 元に戻すための記録が1 MiBを超えるため、構造編集は実行しません。'}
    return $snapshot
}

function Complete-YakuCatStructuralUndoSnapshot {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Snapshot)
    $beforeIds=@($Snapshot.before_segments|ForEach-Object{[string]$_.SegmentId})
    $afterIds=@($Project.Segments|ForEach-Object{[string]$_.SegmentId})
    $removed=@($beforeIds|Where-Object{$afterIds -notcontains $_})
    if($removed.Count -lt 1){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 構造編集後の行IDを確認できません。'}
    $Snapshot.removed_segment_ids=@($removed)
    $publicationCopies=New-Object System.Collections.Generic.List[object]
    foreach($variant in @($Project.PublicationVariants)){
        if($removed -contains ([string]$variant.segment_id)){[void]$publicationCopies.Add((Copy-YakuCatStructuralUndoValue -Value $variant))}
    }
    $Snapshot.before_publication_variants=@($publicationCopies.ToArray())
    $Snapshot.before_publication_variants_hash=Get-YakuCatStructuralUndoPlacementPlansHash -Plans @($Snapshot.before_publication_variants)
    $Snapshot.before_publication_variant_ids=@($Snapshot.before_publication_variants|ForEach-Object{[string]$_.variant_id})
    $active=[ordered]@{}
    foreach($id in $removed){try{$value=$Project.ActivePublicationVariantBySegment.$id;if($null -ne $value){$active[$id]=[string]$value}}catch{}}
    $Snapshot.before_active_publication_variants=[pscustomobject]$active
    # 消えた行へ結び付いた掲載訳を、新しい行へ流用しない。undo が戻す時だけ復帰する。
    foreach($variant in @($Project.PublicationVariants)){if($removed -contains ([string]$variant.segment_id)){if([string]$variant.status -eq 'active'){$variant.status='stale'}}}
    foreach($id in $removed){try{$Project.ActivePublicationVariantBySegment.PSObject.Properties.Remove($id)}catch{}}
    $Snapshot.post_segment_count=@($Project.Segments).Count
    $Snapshot.post_state_hash=Get-YakuCatStructuralUndoSegmentsHash -Segments @($Project.Segments)
    $Snapshot.post_replace_count=[int]$Snapshot.post_segment_count - ([int]$Snapshot.before_segment_count - [int]$Snapshot.affected_count)
    if([int]$Snapshot.post_replace_count -lt 1 -or ([int]$Snapshot.before_index + [int]$Snapshot.post_replace_count) -gt @($Project.Segments).Count){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 構造編集後の行範囲を確認できません。'}
    $postRows=@($Project.Segments)[[int]$Snapshot.before_index..([int]$Snapshot.before_index+[int]$Snapshot.post_replace_count-1)]
    $Snapshot.post_window_hash=Get-YakuCatStructuralUndoSegmentsHash -Segments $postRows
    $Snapshot.post_segment_ids=@($postRows|ForEach-Object{[string]$_.SegmentId})
    $json=$Snapshot|ConvertTo-Json -Depth 40 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json)-gt 1048576){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_TOO_LARGE: 元に戻すための記録が1 MiBを超えるため、構造編集は実行しません。'}
    $Project.PendingStructuralUndo=$Snapshot
    return $Snapshot
}

function Assert-YakuCatStructuralUndoSnapshot {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Snapshot,[switch]$RequireCurrent)
    if([int]$Snapshot.version -ne 1 -or [string]$Snapshot.project_id -cne [string]$Project.Id -or [string]$Snapshot.operation -notin @('merge','split','split-at') -or [int]$Snapshot.affected_count -lt 1 -or [int]$Snapshot.affected_count -gt 2){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 直前の構造編集の復元記録が不正です。'}
    $before=@($Snapshot.before_segments);$removed=@($Snapshot.removed_segment_ids)
    if($before.Count -ne [int]$Snapshot.affected_count -or [int]$Snapshot.before_index -lt 0 -or $removed.Count -lt 1 -or [int]$Snapshot.post_segment_count -ne @($Project.Segments).Count -or [int]$Snapshot.post_replace_count -lt 1 -or ([int]$Snapshot.before_index+[int]$Snapshot.post_replace_count) -gt @($Project.Segments).Count -or [string]::IsNullOrWhiteSpace([string]$Snapshot.before_rows_hash) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.before_placement_plans_hash) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.before_publication_variants_hash) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.post_state_hash)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 直前の構造編集の復元記録を確認できません。'}
    $ids=New-Object 'System.Collections.Generic.HashSet[string]';foreach($s in $before){if(-not $ids.Add([string]$s.SegmentId)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元記録の行IDが重複しています。'}}
    if([string]$Snapshot.before_rows_hash -cne (Get-YakuCatStructuralUndoSegmentsHash -Segments $before)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元前の行記録が改変されています。'}
    if([string]$Snapshot.before_placement_plans_hash -cne (Get-YakuCatStructuralUndoPlacementPlansHash -Plans @($Snapshot.before_placement_plans))){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元前の配置計画記録が改変されています。'}
    $planIds=New-Object 'System.Collections.Generic.HashSet[string]';foreach($plan in @($Snapshot.before_placement_plans)){if(-not $planIds.Add([string]$plan.segment_id) -or (@($Snapshot.before_placement_plan_ids) -notcontains [string]$plan.segment_id)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元前の配置計画IDが不正です。'}}
    $orderIds=New-Object 'System.Collections.Generic.HashSet[string]';foreach($planId in @($Snapshot.before_placement_plan_order)){if(-not $orderIds.Add([string]$planId)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元前の配置計画順序が不正です。'}}
    if([string]$Snapshot.before_publication_variants_hash -cne (Get-YakuCatStructuralUndoPlacementPlansHash -Plans @($Snapshot.before_publication_variants)) -or ((@($Snapshot.before_publication_variant_ids) -join '|') -cne (@($Snapshot.before_publication_variants|ForEach-Object{[string]$_.variant_id}) -join '|'))){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元前の掲載訳記録が改変されています。'}
    $currentWindow=@($Project.Segments)[[int]$Snapshot.before_index..([int]$Snapshot.before_index+[int]$Snapshot.post_replace_count-1)]
    $currentWindowIds=@($currentWindow|ForEach-Object{[string]$_.SegmentId})
    if($RequireCurrent -and ([string]$Snapshot.post_state_hash -cne (Get-YakuCatStructuralUndoSegmentsHash -Segments @($Project.Segments)) -or [string]$Snapshot.post_window_hash -cne (Get-YakuCatStructuralUndoSegmentsHash -Segments $currentWindow) -or (($currentWindowIds -join '|') -cne (@($Snapshot.post_segment_ids) -join '|')))){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_STALE: 構造編集後の行が変わったため、安全に元へ戻せません。'}
    return $true
}

function Invoke-YakuCatStructuralEdit {
    param([Parameter(Mandatory=$true)]$Project,[ValidateSet('merge','split','split-at')][string]$Operation,[Parameter(Mandatory=$true)][int]$Index,[int]$Position=-1)
    $affected=$(if($Operation -eq 'merge'){2}else{1})
    # validation が先。失敗した操作で既存券を消さず、snapshot を作る費用も払わない。
    $segs=@($Project.Segments);if($Index -lt 0 -or $Index -ge $segs.Count){throw 'セグメントが見つかりません。'}
    if($Operation -eq 'merge' -and $Index -ge ($segs.Count-1)){throw '次のセグメントがありません。'}
    $snapshot=New-YakuCatStructuralUndoSnapshot -Project $Project -Operation $Operation -AffectedCount $affected -Index $Index
    if($Operation -eq 'merge'){$null=Merge-YakuCatSegments -Project $Project -Index $Index}elseif($Operation -eq 'split'){$null=Split-YakuCatSegment -Project $Project -Index $Index}else{$null=Split-YakuCatSegmentAt -Project $Project -Index $Index -Position $Position}
    # Merge の text行などは legacy helper が最低限のプロパティだけで作る。ここで
    # 正規化してから post hash を打たないと、保存時の正規化で別物になってしまう。
    $null=Initialize-YakuCatProjectState -Project $Project
    $null=Complete-YakuCatStructuralUndoSnapshot -Project $Project -Snapshot $snapshot
    $anchor=@($Project.Segments)[[int]$Index]
    $null=Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation' -Action ('structure_'+$Operation) -Segment $anchor -ReasonCode 'structural-edit'
    return [pscustomobject]@{Operation=$Operation;Affected=[int]$affected}
}

function Undo-YakuCatStructuralEdit {
    param([Parameter(Mandatory=$true)]$Project)
    $snapshot=$Project.PendingStructuralUndo;if($null -eq $snapshot){throw 'CAT_STRUCTURAL_UNDO_NOT_AVAILABLE: 元に戻せる構造編集はありません。'}
    $null=Assert-YakuCatStructuralUndoSnapshot -Project $Project -Snapshot $snapshot -RequireCurrent
    # post操作の新しい行へ属する計画だけを外す。資料の別行で人が調整した計画は
    # そのまま残す。SplitGroup も PlacementUnits で1単位として照合する。
    $postPlacementIds=@(Get-YakuCatStructuralUndoPlacementPlanIds -Project $Project -Index ([int]$snapshot.before_index) -Count ([int]$snapshot.post_replace_count))
    $restored=@($snapshot.before_segments|ForEach-Object{Copy-YakuCatStructuralUndoValue -Value $_})
    $current=@($Project.Segments);$out=New-Object System.Collections.Generic.List[object]
    for($i=0;$i -lt $current.Count;$i++){
        if($i -eq [int]$snapshot.before_index){foreach($row in $restored){[void]$out.Add($row)}}
        if($i -ge [int]$snapshot.before_index -and $i -lt ([int]$snapshot.before_index+[int]$snapshot.post_replace_count)){continue}
        [void]$out.Add($current[$i])
    }
    $Project.Segments=@($out.ToArray())
    if([string]$snapshot.before_state_hash -cne (Get-YakuCatStructuralUndoSegmentsHash -Segments @($Project.Segments))){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元後の行構成が編集前の記録と一致しません。'}
    $plansById=@{}
    foreach($plan in @($Project.PlacementPlans)){if($postPlacementIds -contains ([string]$plan.segment_id)){continue};$key=[string]$plan.segment_id;if($plansById.ContainsKey($key)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元中の配置計画IDが重複しています。'};$plansById[$key]=$plan}
    foreach($plan in @($snapshot.before_placement_plans|ForEach-Object{Copy-YakuCatStructuralUndoValue -Value $_})){ $key=[string]$plan.segment_id;if($plansById.ContainsKey($key)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元対象の配置計画が重複しています。'};$plansById[$key]=$plan }
    $placementPlans=New-Object System.Collections.Generic.List[object]
    foreach($planId in @($snapshot.before_placement_plan_order)){if($plansById.ContainsKey([string]$planId)){[void]$placementPlans.Add($plansById[[string]$planId]);$plansById.Remove([string]$planId)}}
    foreach($plan in @($plansById.Values|Sort-Object {[string]$_.segment_id})){[void]$placementPlans.Add($plan)}
    $Project.PlacementPlans=@($placementPlans.ToArray())
    $restoredPlacementPlans=@($Project.PlacementPlans|Where-Object{$snapshot.before_placement_plan_ids -contains ([string]$_.segment_id)})
    if([string]$snapshot.before_placement_plans_hash -cne (Get-YakuCatStructuralUndoPlacementPlansHash -Plans $restoredPlacementPlans)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元後の配置計画が編集前の記録と一致しません。'}
    $null=Update-YakuCatPlacementSetHash -Project $Project
    if([string]$Project.PlacementSetHash -cne [string]$snapshot.before_placement_set_hash){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元後の配置計画集合が編集前の記録と一致しません。'}
    $removed=@($snapshot.removed_segment_ids)
    # 歴史は表示・監査の順序を持つ。対象を除外して末尾へ戻すと、他行と交互の
    # variant history が並び替わる。post 操作で stale にした同じ variant_id を同じ
    # 添字で置換する。欠落/重複は安全側で止める。
    $variantsById=@{};foreach($variant in @($snapshot.before_publication_variants)){ $key=[string]$variant.variant_id;if([string]::IsNullOrWhiteSpace($key) -or $variantsById.ContainsKey($key)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元前の掲載訳IDが不正です。'};$variantsById[$key]=$variant }
    $variants=New-Object System.Collections.Generic.List[object];$seenVariantIds=New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($variant in @($Project.PublicationVariants)){
        $key=[string]$variant.variant_id
        if($removed -contains ([string]$variant.segment_id)){
            if(-not $variantsById.ContainsKey($key) -or -not $seenVariantIds.Add($key)){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元対象の掲載訳履歴が一致しません。'}
            [void]$variants.Add((Copy-YakuCatStructuralUndoValue -Value $variantsById[$key]))
        }else{[void]$variants.Add($variant)}
    }
    if($seenVariantIds.Count -ne $variantsById.Count){throw 'CAT_STRUCTURAL_UNDO_SNAPSHOT_INVALID: 復元対象の掲載訳履歴が不足しています。'}
    $Project.PublicationVariants=@($variants.ToArray())
    # active map は既存のIDを保持し、失われていたIDだけを snapshot の値へ戻す。
    foreach($id in $removed){try{$Project.ActivePublicationVariantBySegment.PSObject.Properties.Remove($id)}catch{}}
    foreach($property in @($snapshot.before_active_publication_variants.PSObject.Properties)){ $Project.ActivePublicationVariantBySegment | Add-Member -NotePropertyName $property.Name -NotePropertyValue ([string]$property.Value) -Force }
    $anchor=@($Project.Segments)[[int]$snapshot.before_index]
    $null=Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation' -Action 'structure_undone' -Segment $anchor -ReasonCode ('structural-undo-'+[string]$snapshot.operation)
    $Project.PendingStructuralUndo=$null
    return [pscustomobject]@{Restored=[int]$snapshot.affected_count;Operation=[string]$snapshot.operation}
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

function Set-YakuCatSegmentTranslationRecord {
    <#
      人が直した訳文を1行へ入れる。**Project 全体の初期化はしない。**

      Initialize-YakuCatProjectState は全行を舐めて SHA-256 を取り直すので、
      行の数だけ呼ぶと資料の大きさの2乗になる（Set-YakuCatSegmentReferenceUsageRecord
      の注記と同じ理由。実測は 2026-08-14）。まとめて何行も書き換える口
      （一括置換）は、初期化を先に1回だけ済ませてからここを呼ぶ。

      **Reset-YakuCatSegmentQc がここにあることが要点である。** 訳文が変われば
      Confirmed は落ち、QcStatus は not_run へ戻る。次に確認済みにするとき、
      必ず数字の点検を通る。一括置換もこの1本を通す。
    #>
    param(
        [Parameter(Mandatory=$true)]$Segment,
        [AllowNull()][string]$Text
    )
    $translation = [string]$Text
    $hasTranslation = -not [string]::IsNullOrWhiteSpace($translation)
    $Segment.Translation = $translation
    $null = Update-YakuCatSegmentReferenceEditState -Segment $Segment -Text $translation
    # 人が書き換えた訳文は、以前のマスク後訳文ともう対応しない。
    $Segment | Add-Member -NotePropertyName 'MaskedTranslation' -NotePropertyValue '' -Force
    $Segment.Origin = $(if ($hasTranslation) { 'manual' } else { '' })
    $Segment | Add-Member -NotePropertyName State -NotePropertyValue $(if ($hasTranslation) { 'human_edited' } else { 'untranslated' }) -Force
    $Segment.TmRegistered = $false
    $Segment.TmRegistrationEventId = ''
    Reset-YakuCatSegmentQc -Segment $Segment -KeepState
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
    return (Set-YakuCatSegmentTranslationRecord -Segment $segs[$Index] -Text $Text)
}

function New-YakuCatSearchMatcher {
    <#
      検索語から照合器（.NET Regex）を1つ作る。画面の検索欄と一括置換は、
      同じ規則で当たらないと「N行に掛かる」と告げた数と実際が食い違う。

      落とし穴を先に潰しておく。
        - 不正な正規表現でサーバを 500 で落とさない。読めない式は名前付きの
          例外にして、画面がそのまま利用者へ見せられるようにする
        - 暴走する式（(a+)+$ など）で固まらせない。2秒で打ち切る
        - 空に一致する式（a* / ^ など）は受け付けない。1文字ごとに置換後の
          文字列を差し込むことになり、押した人の意図とほぼ確実に違う
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Find,
        [bool]$UseRegex = $false,
        [bool]$MatchCase = $false
    )
    if ([string]::IsNullOrEmpty($Find)) { throw 'CAT_SEARCH_FIND_EMPTY: 探す文字列を入れてください。' }
    $pattern = $(if ($UseRegex) { [string]$Find } else { [regex]::Escape([string]$Find) })
    $options = [System.Text.RegularExpressions.RegexOptions]::None
    if (-not $MatchCase) { $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $rx = $null
    try { $rx = New-Object System.Text.RegularExpressions.Regex($pattern, $options, ([TimeSpan]::FromSeconds(2))) }
    catch { throw ('CAT_SEARCH_PATTERN_INVALID: 正規表現として読めません。' + [string]$_.Exception.Message) }
    $matchesEmpty = $false
    try { $matchesEmpty = [bool]$rx.Match('').Success } catch { $matchesEmpty = $false }
    if ($matchesEmpty) { throw 'CAT_SEARCH_PATTERN_MATCHES_EMPTY: 何も無いところにも一致する式です。別の書き方にしてください。' }
    return $rx
}

function Assert-YakuCatSearchReplaceScope {
    <#
      「探す場所」が原文だけのときは、置換を断る。

      置換が変えるのは訳文だけである。原文は資料そのもので、SourceIntegrityHash
      から書き戻しまでが原文に乗っている。原文だけを探しているのに訳文を
      書き換えたら、押した人が見ていない行が変わる。

      同じ判定は画面（cat.js の replaceTargets / renderSearchTools / runReplace）にも
      あるが、**画面だけが守っている決まりは、画面を壊せば消える。** 実際、その
      3か所を同時に外しても回帰は全件緑だった（2026-08-15 の指摘）。ここが二重目
      である。

      空文字・未指定は「指定なし」として通す。古い画面からの要求を断らない。
    #>
    param([AllowNull()][AllowEmptyString()][string]$Scope)
    if ([string]$Scope -eq 'source') {
        throw 'CAT_REPLACE_SCOPE_SOURCE: 原文は書き換えません。探す場所を「訳文だけ」か「原文と訳文」にしてください。'
    }
}

function ConvertTo-YakuCatSearchReplacement {
    <#
      置換後の文字列を、.NET Regex.Replace が読む形にする。
      正規表現を使わないときは $ を字面として扱う（$1 が置換群にならないように）。
    #>
    param([AllowNull()][string]$Replace, [bool]$UseRegex = $false)
    $text = [string]$Replace
    if ($UseRegex) { return $text }
    return $text.Replace('$', '$$')
}

function Get-YakuCatBulkReplaceUndoSegmentState {
    <# source 側は照合だけに使い、undo で書き戻さない。訳文に付随する状態を
       まとめて持つので、文字列だけを逆置換して QC や出典を嘘にしない。 #>
    param([Parameter(Mandatory=$true)]$Segment)
    return [ordered]@{
        segment_id = [string]$Segment.SegmentId
        source_revision = [int]$Segment.SourceRevision
        source_integrity_hash = [string]$Segment.SourceIntegrityHash
        translation = [string]$Segment.Translation
        masked_translation = [string]$Segment.MaskedTranslation
        origin = [string]$Segment.Origin
        state = [string]$Segment.State
        qc_status = [string]$Segment.QcStatus
        qc_source_revision = [int]$Segment.QcSourceRevision
        qc_source_hash = [string]$Segment.QcSourceHash
        qc_target_hash = [string]$Segment.QcTargetHash
        qc_contract_version = [string]$Segment.QcContractVersion
        qc_terminology_hash = [string]$Segment.QcTerminologyHash
        qc_findings = @($Segment.QcFindings)
        confirmed = [bool]$Segment.Confirmed
        tm_registered = [bool]$Segment.TmRegistered
        tm_registration_event_id = [string]$Segment.TmRegistrationEventId
        reference_usage = $(try { $Segment.ReferenceUsage } catch { $null })
        reference_events = @($(try { $Segment.ReferenceEvents } catch { @() }))
        terminology_usages = @($(try { $Segment.TerminologyUsages } catch { @() }))
        terminology_exceptions = @($(try { $Segment.TerminologyExceptions } catch { @() }))
        terminology_generation = @($(try { $Segment.TerminologyGeneration } catch { @() }))
    }
}

function Get-YakuCatBulkReplaceUndoStateHash {
    param([Parameter(Mandatory=$true)]$State)
    # PSSerializer/ConvertFrom-Json はプロパティ順を契約にしない。永続化前後でも
    # 同じ状態なら同じ hash になるよう、ここで列の順を固定する。
    $canonical = [ordered]@{
        segment_id=[string]$State.segment_id;source_revision=[int]$State.source_revision;source_integrity_hash=[string]$State.source_integrity_hash
        translation=[string]$State.translation;masked_translation=[string]$State.masked_translation;origin=[string]$State.origin;state=[string]$State.state
        qc_status=[string]$State.qc_status;qc_source_revision=[int]$State.qc_source_revision;qc_source_hash=[string]$State.qc_source_hash;qc_target_hash=[string]$State.qc_target_hash
        qc_contract_version=[string]$State.qc_contract_version;qc_terminology_hash=[string]$State.qc_terminology_hash;qc_findings=@($State.qc_findings);confirmed=[bool]$State.confirmed
        tm_registered=[bool]$State.tm_registered;tm_registration_event_id=[string]$State.tm_registration_event_id;reference_usage=$State.reference_usage;reference_events=@($State.reference_events)
        terminology_usages=@($State.terminology_usages);terminology_exceptions=@($State.terminology_exceptions);terminology_generation=@($State.terminology_generation)
    }
    return (Get-YakuCatSourceIntegrityHash -Text ($canonical | ConvertTo-Json -Depth 24 -Compress))
}

function Get-YakuCatBulkReplaceUndoProjectIdentityHash {
    param([Parameter(Mandatory=$true)]$Project)
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($segment in @($Project.Segments)) {
        [void]$rows.Add(([string]$segment.SegmentId + '|' + [int]$segment.SourceRevision + '|' + [string]$segment.SourceIntegrityHash))
    }
    return (Get-YakuCatSourceIntegrityHash -Text (($rows.ToArray() | Sort-Object) -join "`n"))
}

function New-YakuCatBulkReplaceUndoSnapshot {
    <# HTTP 更新本文の上限 2 MiB の半分（1 MiB）かつ 512 行までにする。generation
       は直近1世代しか残さないが、巨大な全行複製で保存・復元を増幅させない。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Plan
    )
    $rows = @($Plan.Rows)
    if ($rows.Count -lt 1) { throw 'CAT_REPLACE_NO_TARGET: 対象の行がありません。絞り込みを見直してください。' }
    if ($rows.Count -gt 512) { throw 'CAT_REPLACE_UNDO_SNAPSHOT_TOO_LARGE: 512行を超える一括置換は安全に元へ戻せないため実行しません。絞り込みを分けてください。' }
    $segs = @($Project.Segments)
    $copies = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        $index = [int]$row.Index
        if ($index -lt 0 -or $index -ge $segs.Count -or [string]$segs[$index].SegmentId -cne [string]$row.SegmentId) {
            throw 'CAT_REPLACE_UNDO_TARGET_CONFLICT: 置換対象の行を安全に確認できません。'
        }
        # ReferenceUsage/QcFindings などは入れ子で可変。浅い property コピーでは
        # Set-YakuCatSegmentTranslationRecord が snapshot の中まで edited にしてしまう。
        $beforeState = [pscustomobject](Get-YakuCatBulkReplaceUndoSegmentState -Segment $segs[$index])
        $before = [System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($beforeState, 30))
        [void]$copies.Add([ordered]@{
            segment_id = [string]$before.segment_id
            before = $before
            before_state_hash = Get-YakuCatBulkReplaceUndoStateHash -State $before
            after_state_hash = ''
        })
    }
    $snapshot = [ordered]@{
        version = 1
        project_id = [string]$Project.Id
        created_at = (Get-Date).ToString('o')
        replace_revision = [int]$Project.Revision + 1
        affected_count = [int]$copies.Count
        project_segment_count = [int]$segs.Count
        project_segment_identity_hash = Get-YakuCatBulkReplaceUndoProjectIdentityHash -Project $Project
        rows = @($copies.ToArray())
    }
    $json = $snapshot | ConvertTo-Json -Depth 28 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1048576) { throw 'CAT_REPLACE_UNDO_SNAPSHOT_TOO_LARGE: 元に戻すための記録が1 MiBを超えるため、一括置換は実行しません。絞り込みを分けてください。' }
    return $snapshot
}

function Assert-YakuCatBulkReplaceUndoSnapshot {
    param([Parameter(Mandatory=$true)]$Project,[Parameter(Mandatory=$true)]$Snapshot,[switch]$RequireCurrent)
    if ([int]$Snapshot.version -ne 1 -or [string]$Snapshot.project_id -cne [string]$Project.Id -or [int]$Snapshot.affected_count -lt 1 -or [int]$Snapshot.affected_count -gt 512) {
        throw 'CAT_REPLACE_UNDO_SNAPSHOT_INVALID: 直前の一括置換の復元記録が不正です。'
    }
    $rows = @($Snapshot.rows)
    if ($rows.Count -ne [int]$Snapshot.affected_count -or [int]$Snapshot.project_segment_count -ne @($Project.Segments).Count -or [string]$Snapshot.project_segment_identity_hash -cne (Get-YakuCatBulkReplaceUndoProjectIdentityHash -Project $Project)) {
        throw 'CAT_REPLACE_UNDO_SNAPSHOT_STALE: 作業の行構成が変わったため、直前の一括置換を安全に元へ戻せません。'
    }
    $byId = @{}
    foreach ($segment in @($Project.Segments)) { $byId[[string]$segment.SegmentId] = $segment }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $rows) {
        $id = [string]$row.segment_id
        if (-not $seen.Add($id) -or -not $byId.ContainsKey($id) -or $null -eq $row.before -or
            [string]$row.before.segment_id -cne $id -or [string]$row.before.source_integrity_hash -cne [string]$byId[$id].SourceIntegrityHash -or
            [int]$row.before.source_revision -ne [int]$byId[$id].SourceRevision) {
            throw 'CAT_REPLACE_UNDO_SNAPSHOT_INVALID: 直前の一括置換の復元記録を確認できません。'
        }
        if ($RequireCurrent -and [string]$row.after_state_hash -cne (Get-YakuCatBulkReplaceUndoStateHash -State (Get-YakuCatBulkReplaceUndoSegmentState -Segment $byId[$id]))) {
            throw 'CAT_REPLACE_UNDO_SNAPSHOT_STALE: 置換後の行が変わったため、直前の一括置換を安全に元へ戻せません。'
        }
    }
    return $true
}

function Restore-YakuCatBulkReplaceUndoSegmentState {
    param([Parameter(Mandatory=$true)]$Segment,[Parameter(Mandatory=$true)]$Before)
    # source/revision/hash は Assert が同一性を確認するだけで、この関数では触らない。
    $map = @{
        Translation='translation'; MaskedTranslation='masked_translation'; Origin='origin'; State='state'
        QcStatus='qc_status'; QcSourceRevision='qc_source_revision'; QcSourceHash='qc_source_hash'; QcTargetHash='qc_target_hash'
        QcContractVersion='qc_contract_version'; QcTerminologyHash='qc_terminology_hash'; QcFindings='qc_findings'; Confirmed='confirmed'
        TmRegistered='tm_registered'; TmRegistrationEventId='tm_registration_event_id'; ReferenceUsage='reference_usage'; ReferenceEvents='reference_events'
        TerminologyUsages='terminology_usages'; TerminologyExceptions='terminology_exceptions'; TerminologyGeneration='terminology_generation'
    }
    foreach ($property in @($map.Keys)) {
        $value = $Before.($map[$property])
        if ($property -in @('QcFindings','ReferenceEvents','TerminologyUsages','TerminologyExceptions','TerminologyGeneration')) { $value = @($value) }
        $Segment | Add-Member -NotePropertyName $property -NotePropertyValue $value -Force
    }
    return $Segment
}

function Undo-YakuCatSearchReplace {
    param([Parameter(Mandatory=$true)]$Project)
    $snapshot = $Project.PendingBulkReplaceUndo
    if ($null -eq $snapshot) { throw 'CAT_REPLACE_UNDO_NOT_AVAILABLE: 元に戻せる一括置換はありません。' }
    $null = Assert-YakuCatBulkReplaceUndoSnapshot -Project $Project -Snapshot $snapshot -RequireCurrent
    $byId = @{}; foreach ($segment in @($Project.Segments)) { $byId[[string]$segment.SegmentId] = $segment }
    $batch = New-YakuCatHumanDecisionEventBatch -Project $Project
    foreach ($row in @($snapshot.rows)) {
        $segment = $byId[[string]$row.segment_id]
        $null = Restore-YakuCatBulkReplaceUndoSegmentState -Segment $segment -Before $row.before
        $null = Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation' -Action 'search_replace_undone' -Segment $segment -ReasonCode 'bulk-replace-undo' -Batch $batch
    }
    $null = Complete-YakuCatHumanDecisionEventBatch -Project $Project -Batch $batch
    $Project.PendingBulkReplaceUndo = $null
    return [pscustomobject]@{ Restored = [int]$snapshot.affected_count }
}

function Get-YakuCatSearchReplacePlan {
    <#
      一括置換の計画。**何も書き換えない。** 押す前に対象行数を告げるためと、
      実際に置換するときの対象を決めるために、同じ1本をどちらからも呼ぶ。
      （告げた数と実際が食い違わないのは、数える経路と書き換える経路が
        同じだからである。別々に書くと必ずずれる。）

      $Indexes は画面の絞り込み結果である。置換は**その中だけ**に掛かる。
      渡されなかった行は読みもしない。

      対象になるのは、訳文が実際に変わる行だけである。訳文が空の行、一致しない行、
      置換しても同じ文字列になる行（例: 「A」を「A」へ）は数に入れない。
      入れてしまうと、何も変わらないのに確認済みだけが落ちる。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowNull()][object[]]$Indexes,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Find,
        [AllowNull()][string]$Replace,
        [bool]$UseRegex = $false,
        [bool]$MatchCase = $false
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $rx = New-YakuCatSearchMatcher -Find $Find -UseRegex $UseRegex -MatchCase $MatchCase
    $replacement = ConvertTo-YakuCatSearchReplacement -Replace $Replace -UseRegex $UseRegex
    $segs = @($Project.Segments)
    $wanted = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($one in @($Indexes)) {
        $parsed = -1
        try { $parsed = [int]$one } catch { $parsed = -1 }
        if ($parsed -ge 0 -and $parsed -lt $segs.Count) { $null = $wanted.Add($parsed) }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $occurrences = 0
    $confirmedRows = 0
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if (-not $wanted.Contains($i)) { continue }
        $before = [string]$segs[$i].Translation
        if ([string]::IsNullOrEmpty($before)) { continue }
        $hits = 0; $after = ''
        try {
            $hits = [int]$rx.Matches($before).Count
            if ($hits -lt 1) { continue }
            $after = [string]$rx.Replace($before, $replacement)
        } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
            throw 'CAT_SEARCH_PATTERN_TIMEOUT: この式は照合に時間がかかりすぎます。別の書き方にしてください。'
        }
        if ([string]::Equals($after, $before, [StringComparison]::Ordinal)) { continue }
        $occurrences += $hits
        if ([bool]$segs[$i].Confirmed) { $confirmedRows++ }
        [void]$rows.Add([pscustomobject]@{
            Index = [int]$i
            SegmentId = [string]$segs[$i].SegmentId
            Before = $before
            After = $after
            Occurrences = [int]$hits
            WasConfirmed = [bool]$segs[$i].Confirmed
        })
    }
    return [pscustomobject]@{
        Rows = @($rows.ToArray())
        RowCount = [int]$rows.Count
        Occurrences = [int]$occurrences
        ConfirmedRows = [int]$confirmedRows
        ScannedRows = [int]$wanted.Count
    }
}

function Invoke-YakuCatSearchReplace {
    <#
      一括置換。市販CAT（memoQ / Phrase / Trados / XTM）はどれも Ctrl+H を持つ。
      用語をあとから統一するとき、手で1行ずつ直す以外の道が要る。

      決まりごとは3つ。
        1. **原文は触らない。** 変えるのは訳文だけである。原文は資料そのもので、
           SourceIntegrityHash から書き戻しまでが原文に乗っている
        2. **絞り込み結果の中だけに掛ける。** 対象は $Indexes で受ける
        3. **訳文が変わった行の確認済みは落ちる。** 書き込みは手で直したときと
           同じ Set-YakuCatSegmentTranslationRecord を通すので、Confirmed は
           $false・QcStatus は not_run へ戻る。次に確認済みにするとき必ず
           数字の点検を通り、落ちれば確定できず書き出しも止まる
           （「数値が抜けた訳は警告ではなく欠陥」）

      置換の記録は1行ごとに追記専用の人手判断イベントとして残す。source_hash /
      target_hash 付きで、既にある reviewed / review_cancelled と同じ形である。
    #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [AllowNull()][object[]]$Indexes,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Find,
        [AllowNull()][string]$Replace,
        [bool]$UseRegex = $false,
        [bool]$MatchCase = $false
    )
    # 計画側が Initialize-YakuCatProjectState を1回だけ呼ぶ。ここから先は
    # 行ごとに Project 全体を初期化し直さない（資料の大きさの2乗になる）。
    $plan = Get-YakuCatSearchReplacePlan -Project $Project -Indexes $Indexes -Find $Find `
        -Replace $Replace -UseRegex $UseRegex -MatchCase $MatchCase
    # 一致が無い replace は以前から成功扱いの no-op である。ここで復元券を
    # 作ると「戻すものが無い」要求が既存の券を上書きしてしまうため、snapshot・
    # event・segment のいずれにも触れず、従来の集計だけを返す。
    if ([int]$plan.RowCount -eq 0) {
        return [pscustomobject]@{
            Replaced = 0
            Occurrences = 0
            Unconfirmed = 0
            ScannedRows = [int]$plan.ScannedRows
            NoMutation = $true
        }
    }
    $segs = @($Project.Segments)
    # 成功した置換だけに復元券を発行する。計画・全行の復元前状態・上限を、訳文を
    # 1文字も変える前に確認するので、復元できない大きな置換を成功扱いにしない。
    $undoSnapshot = New-YakuCatBulkReplaceUndoSnapshot -Project $Project -Plan $plan
    $replaced = 0
    # 記録の追記も行ごとに全走査させない。Initialize を外へ出したのと同じ理由で、
    # ここに残っていたもう1つの2乗である（実測は New-YakuCatHumanDecisionEventBatch の注記）。
    $batch = New-YakuCatHumanDecisionEventBatch -Project $Project
    foreach ($row in @($plan.Rows)) {
        $i = [int]$row.Index
        if ($i -lt 0 -or $i -ge $segs.Count) { continue }
        $null = Set-YakuCatSegmentTranslationRecord -Segment $segs[$i] -Text ([string]$row.After)
        $null = Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation' -Action 'search_replaced' -Segment $segs[$i] -ReasonCode 'bulk-replace' -Batch $batch
        $replaced++
    }
    $null = Complete-YakuCatHumanDecisionEventBatch -Project $Project -Batch $batch
    foreach ($row in @($undoSnapshot.rows)) {
        $segment = $segs | Where-Object { [string]$_.SegmentId -ceq [string]$row.segment_id } | Select-Object -First 1
        if ($null -eq $segment) { throw 'CAT_REPLACE_UNDO_TARGET_CONFLICT: 置換対象の行を安全に確認できません。' }
        $row.after_state_hash = Get-YakuCatBulkReplaceUndoStateHash -State (Get-YakuCatBulkReplaceUndoSegmentState -Segment $segment)
    }
    $undoJson = $undoSnapshot | ConvertTo-Json -Depth 28 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($undoJson) -gt 1048576) { throw 'CAT_REPLACE_UNDO_SNAPSHOT_TOO_LARGE: 元に戻すための記録が1 MiBを超えるため、一括置換は実行しません。絞り込みを分けてください。' }
    $Project.PendingBulkReplaceUndo = $undoSnapshot
    return [pscustomobject]@{
        Replaced = [int]$replaced
        Occurrences = [int]$plan.Occurrences
        Unconfirmed = [int]$plan.ConfirmedRows
        ScannedRows = [int]$plan.ScannedRows
    }
}

function Set-YakuCatSegmentReferenceUsageRecord {
    <#
      「どの候補から挿したか」を1行へ書く。**Project 全体の初期化はしない。**

      Initialize-YakuCatProjectState は全行を舐めて SHA-256 を取り直すので、
      行の数だけ呼ぶと資料の大きさの2乗になる。事前翻訳は当たった行の数だけ
      出典を書くため、そこで実際に踏んだ（実測 2026-08-14、200行・TM 123件:
      引く費用は 961ms なのに全体は 10,991ms。Initialize を100回呼ぶ費用が
      9,935ms を占めていた）。初期化は呼び出し側で1回だけ行う。
    #>
    param(
        [Parameter(Mandatory=$true)]$Segment,
        [Parameter(Mandatory=$true)]$Candidate,
        [int]$ProjectRevision = 0
    )
    if ([string]$Candidate.ReferenceId -notmatch '^[a-f0-9]{16,64}$') { throw 'CAT_REFERENCE_ID_INVALID' }
    if (-not [string]::Equals([string]$Segment.Translation, [string]$Candidate.Target, [StringComparison]::Ordinal)) {
        throw 'CAT_REFERENCE_TARGET_MISMATCH'
    }
    $targetHash = Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation)
    $Segment | Add-Member -NotePropertyName ReferenceUsage -NotePropertyValue ([pscustomobject]@{
        id = [string]$Candidate.ReferenceId
        kind = [string]$Candidate.Kind
        action = 'inserted'
        target_hash = $targetHash
        edited_after_insert = $false
        source_name = [string]$Candidate.SourceName
        location = [string]$Candidate.Location
        page = [int]$Candidate.Page
        source = [string]$Candidate.Source
        translation = [string]$Candidate.Target
    }) -Force
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($existing in @($Segment.ReferenceEvents)) { $events.Add($existing) | Out-Null }
    $events.Add([pscustomobject]@{
        event_id=[guid]::NewGuid().ToString('N'); reference_id=[string]$Candidate.ReferenceId
        kind=[string]$Candidate.Kind; action='inserted'; source_name=[string]$Candidate.SourceName
        location=[string]$Candidate.Location; page=[int]$Candidate.Page
        source=[string]$Candidate.Source; translation=[string]$Candidate.Target
        match_score=$(try { [double]$Candidate.Score } catch { [double]$Candidate.Ratio })
        target_hash=$targetHash
        project_revision=[int]$ProjectRevision; created=(Get-Date).ToString('s'); edited_after_insert=$false
    }) | Out-Null
    $Segment | Add-Member -NotePropertyName ReferenceEvents -NotePropertyValue @($events.ToArray()) -Force
    return $Segment
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
    return (Set-YakuCatSegmentReferenceUsageRecord -Segment $segs[$Index] -Candidate $Candidate -ProjectRevision ([int]$Project.Revision))
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

function New-YakuCatHumanDecisionEventBatch {
    <#
      一括操作（置換など）のための追記口。**追記そのものの性質は変えない。**

      Add-YakuCatHumanDecisionEvent は1件ごとに、既にある event_id 全件を
      Where-Object で走査し、続けて全件を新しい List へ写して配列へ戻していた。
      1行ずつ呼ぶかぎり正しいが、行の数だけ呼ぶと行数の2乗になる。
      実測（2026-08-15、全行が対象の資料。1回目の置換）:
        100行 2,096ms / 200行 4,017ms / 400行 13,368ms / 800行 44,570ms
      800行の 44.6秒 のうち 37秒（83%）がこの1行だった。同じ関数のコメントが
      「行ごとに Initialize を呼ぶと2乗になる」と書いてそれを避けた、その中で
      別の2乗を作っていたことになる。

      ここで既存の event_id を1度だけ Hashtable（HashSet）へ入れ、追記は List へ
      足すだけにする。書き戻しは Complete-… で1回。追記専用であること・
      同じ内容なら足さない（冪等）こと・source_hash / target_hash を持つことは
      いずれもそのままである。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($Project.ReviewEvents)) {
        [void]$events.Add($event)
        [void]$ids.Add([string]$event.event_id)
    }
    return [pscustomobject]@{ Ids = $ids; Events = $events }
}

function Complete-YakuCatHumanDecisionEventBatch {
    <# 溜めた追記を1回だけ書き戻す。呼ばなければ何も残らない。 #>
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)]$Batch
    )
    $Project.ReviewEvents = $Batch.Events.ToArray()
    return [int]$Batch.Events.Count
}

function Add-YakuCatHumanDecisionEvent {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [ValidateSet('translation','translation_memory','project_lifecycle','placement','publication','abbreviation','rebase','render','document','final')][string]$Scope,
        [Parameter(Mandatory=$true)][string]$Action,
        [AllowNull()]$Segment,
        [string]$ReasonCode = '',
        [string]$DependencyFingerprint = '',
        [string]$FindingId = '',
        [int]$FindingRevision = 0,
        [string]$FindingFingerprint = '',
        [string]$CoverageItemId = '',
        # New-YakuCatHumanDecisionEventBatch が返したもの。渡されたときは
        # Project へ直接書かず、そこへ溜める。渡さなければ従来どおり。
        [AllowNull()]$Batch = $null
    )
    $segmentId = $(if ($null -ne $Segment) { [string]$Segment.SegmentId } else { '' })
    $sourceHash = $(if ($null -ne $Segment) { [string]$Segment.SourceIntegrityHash } else { '' })
    $targetHash = $(if ($null -ne $Segment) { Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation) } else { '' })
    if ([string]::IsNullOrWhiteSpace($DependencyFingerprint)) {
        $DependencyFingerprint = Get-YakuCatSourceIntegrityHash -Text ($sourceHash + '|' + $targetHash + '|' + [string]$Project.TerminologySnapshotHash)
    }
    $eventId = Get-YakuCatSourceIntegrityHash -Text ('human-decision-v2|' + [string]$Project.Id + '|' + ([int]$Project.Revision + 1) + '|' + $Scope + '|' + $Action + '|' + $segmentId + '|' + $sourceHash + '|' + $targetHash + '|' + $DependencyFingerprint + '|' + $FindingId + '|' + $FindingRevision + '|' + $FindingFingerprint + '|' + $CoverageItemId)
    $record = [pscustomobject]@{
        event_id=$eventId; occurred_at=(Get-Date).ToString('o'); project_id=[string]$Project.Id
        project_revision=[int]$Project.Revision + 1; decision_scope=$Scope; action=$Action
        segment_id=$segmentId; reason_code=$ReasonCode; source_hash=$sourceHash; target_hash=$targetHash
        dependency_fingerprint=$DependencyFingerprint
        finding_id=$FindingId; finding_revision=$FindingRevision; finding_fingerprint=$FindingFingerprint; coverage_item_id=$CoverageItemId
    }
    if ($null -ne $Batch) {
        # 一括の追記。重複判定は index 済みの HashSet で、配列の作り直しはしない。
        # 足すか足さないかの結果は、下の1件ずつの経路と同じである。
        if ($Batch.Ids.Contains($eventId)) { return $eventId }
        [void]$Batch.Ids.Add($eventId)
        [void]$Batch.Events.Add($record)
        return $eventId
    }
    if (@($Project.ReviewEvents | Where-Object { [string]$_.event_id -eq $eventId }).Count -gt 0) { return $eventId }
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($Project.ReviewEvents)) { $events.Add($event) | Out-Null }
    $events.Add($record) | Out-Null
    $Project.ReviewEvents = @($events.ToArray())
    return $eventId
}

function Set-YakuCatProjectSaved {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [string]$Reason = 'user-requested'
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    if ([string]$Project.Lifecycle -in @('deleting','deleted')) { throw 'CAT_PROJECT_LIFECYCLE_INVALID' }
    if ([string]$Project.Lifecycle -eq 'saved') { return '' }
    $Project.Lifecycle = 'saved'
    $Project.RetentionUntil = ''
    $Project.PromotedAt = (Get-Date).ToString('o')
    return (Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'project_lifecycle' -Action 'saved' -ReasonCode $Reason)
}

function Add-YakuCatTranslationMemoryOutboxEvent {
    param([Parameter(Mandatory=$true)]$Project, [Parameter(Mandatory=$true)]$Segment)
    # PDFの表は、列を再現するための連続空白を文中に持つ。対訳確認の画面では
    # HTMLが畳むため気づきにくいが、そのままTMへ入れると候補を挿入したtextareaに
    # 桁合わせの空白まで戻る。公表対訳の突き合わせだけは、文として再利用できる形へ
    # 空白を1つにする。通常の翻訳は、利用者が入力した空白を変えない。
    $memorySource = [string]$Segment.Text
    $memoryTarget = [string]$Segment.Translation
    if ([string]$Project.Source -eq 'align') {
        $memorySource = ($memorySource -replace '\s+', ' ').Trim()
        $memoryTarget = ($memoryTarget -replace '\s+', ' ').Trim()
    }
    $eventId = Get-YakuCatSourceIntegrityHash -Text ('tm-outbox-v1|' + [string]$Project.Id + '|' + [string]$Segment.SegmentId + '|' + [string]$Project.Revision + '|' + [string]$Segment.SourceIntegrityHash + '|' + (Get-YakuCatSourceIntegrityHash -Text ([string]$Segment.Translation)))
    if (@($Project.TmOutbox | Where-Object { [string]$_.event_id -eq $eventId }).Count -gt 0) { return $eventId }
    $outbox = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($Project.TmOutbox)) { $outbox.Add($event) | Out-Null }
    $outbox.Add([pscustomobject]@{
        event_id=$eventId; source=$memorySource; target=$memoryTarget
        direction=[string]$Project.Direction; origin_project_id=[string]$Project.Id
        origin_file_name=[string]$Project.FileName; origin_segment_id=[string]$Segment.SegmentId
        origin_location=[string]$Segment.Location; origin_page=Get-YakuCatSegmentOriginPage -Project $Project -Segment $Segment
        review_revision=[int]$Project.Revision + 1; created=(Get-Date).ToString('s')
    }) | Out-Null
    $Project.TmOutbox = @($outbox.ToArray())
    return $eventId
}

function Register-YakuCatSegmentTranslationMemory {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][int]$Index
    )
    $null = Initialize-YakuCatProjectState -Project $Project
    $segments = @($Project.Segments)
    if ($Index -lt 0 -or $Index -ge $segments.Count) { throw 'CAT_TM_SEGMENT_NOT_FOUND' }
    $segment = $segments[$Index]
    if (-not [bool]$segment.Confirmed -or -not (Test-YakuCatSegmentQcCurrent -Segment $segment -TerminologySnapshotHash ([string]$Project.TerminologySnapshotHash))) {
        throw 'CAT_TM_REQUIRES_CURRENT_REVIEW: 原文と訳文を確認してから翻訳メモリへ追加してください。'
    }
    $outboxEventId = Add-YakuCatTranslationMemoryOutboxEvent -Project $Project -Segment $segment
    $segment.TmRegistered = $true
    $segment.TmRegistrationEventId = [string]$outboxEventId
    $null = Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation_memory' -Action 'registered' -Segment $segment
    return [string]$outboxEventId
}

function Get-YakuCatTranslationMemoryRegistrationsForRevocation {
    <#
      TM登録後に訳文を編集すると、現在のsegmentはTmRegistered=falseへ戻る。
      過去に同期したTM unitの取消対象は、現在フラグではなくdurableな
      registered decision eventを正本として列挙する。
      eventを持たない旧projectだけTmRegisteredをfallbackにする。
    #>
    param([Parameter(Mandatory=$true)]$Project)
    $null = Initialize-YakuCatProjectState -Project $Project
    $latestBySegment = @{}
    foreach ($event in @($Project.ReviewEvents | Where-Object {
        [string]$_.decision_scope -eq 'translation_memory' -and
        [string]$_.action -eq 'registered' -and
        [string]$_.segment_id -match '^[a-fA-F0-9]{32}$' -and
        [int]$_.project_revision -gt 0
    } | Sort-Object project_revision)) {
        $latestBySegment[[string]$event.segment_id] = [int]$event.project_revision
    }
    foreach ($segment in @($Project.Segments | Where-Object { [bool]$_.TmRegistered })) {
        $segmentId = [string]$segment.SegmentId
        if (-not $latestBySegment.ContainsKey($segmentId)) {
            $latestBySegment[$segmentId] = [Math]::Max(1, [int]$Project.Revision)
        }
    }
    return @($latestBySegment.GetEnumerator() | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            origin_project_id = [string]$Project.Id
            origin_segment_id = [string]$_.Key
            review_revision = [int]$_.Value
        }
    })
}

function Revoke-YakuCatTranslationMemoryRegistrations {
    param([Parameter(Mandatory=$true)]$Project,[string]$Reason='project-deleted-by-user')
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($registration in @(Get-YakuCatTranslationMemoryRegistrationsForRevocation -Project $Project)) {
        $result = Add-YakuTranslationMemoryTombstone -Direction ([string]$Project.Direction) `
            -OriginProjectId ([string]$registration.origin_project_id) `
            -OriginSegmentId ([string]$registration.origin_segment_id) `
            -ReviewRevision ([int]$registration.review_revision) -Reason $Reason
        if (-not [bool]$result.Added -and [string]$result.Reason -notin @('same','missing')) {
            throw ('CAT_PROJECT_TM_REVOCATION_FAILED: ' + [string]$result.Reason)
        }
        $results.Add($result) | Out-Null
    }
    return @($results.ToArray())
}

function Sync-YakuCatTranslationMemoryOutbox {
    param([Parameter(Mandatory=$true)]$Project)
    $pendingEvents=New-Object System.Collections.Generic.List[object]
    foreach ($event in @($Project.TmOutbox)) {
        try {
            $result = Add-YakuTranslationMemoryEntry -Source ([string]$event.source) -Target ([string]$event.target) `
                -Direction ([string]$event.direction) -Origin 'cat-reviewed-qc-v1' `
                -OriginProjectId ([string]$event.origin_project_id) -OriginFileName ([string]$event.origin_file_name) `
                -OriginSegmentId ([string]$event.origin_segment_id) -OriginLocation ([string]$event.origin_location) `
                -OriginPage ([int]$event.origin_page) -ReviewRevision ([int]$event.review_revision)
            if ($null -eq $result) { $pendingEvents.Add($event)|Out-Null }
        } catch {
            $pendingEvents.Add($event)|Out-Null
            try { Write-YakuLog ('Translation memory outbox pending. event=' + [string]$event.event_id + ' error=' + $_.Exception.Message) 'WARN' } catch {}
        }
    }
    # 成功済みeventは外部TM側がevent identityで冪等に保持する。outboxには
    # 未同期だけを残し、transient削除を永久に妨げない。
    $Project.TmOutbox=@($pendingEvents.ToArray())
    $pending=@($Project.TmOutbox).Count
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
        $null = Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation' -Action 'review_cancelled' -Segment $segs[$Index]
        return $segs[$Index]
    }
    $validation = Invoke-YakuCatSegmentValidation -Project $Project -Segment $segs[$Index]
    if (-not [bool]$validation.Passed) {
        $segs[$Index].Confirmed = $false
        throw ('CAT_REVIEW_QC_FAILED: ' + (@($validation.Findings | ForEach-Object { [string]$_.Code }) -join ','))
    }
    $segs[$Index].State = 'reviewed'
    $segs[$Index].Confirmed = $true
    $null = Add-YakuCatHumanDecisionEvent -Project $Project -Scope 'translation' -Action 'reviewed' -Segment $segs[$Index]
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

function Assert-YakuCatExcelPlacementStructureSafe {
    <# 書込み可否へ影響するCOM値は、推測せず全項目を明示確認する。 #>
    param(
        [Parameter(Mandatory=$true)]$Structure,
        [string]$BlockId = ''
    )
    $target=$(if([string]::IsNullOrWhiteSpace($BlockId)){''}else{' 対象: '+$BlockId})
    if([string]$Structure.contract_version -ne 'excel-cell-structure-v2'){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先セルの構造契約を確認できません。'+$target)
    }
    $mergeKind=[string]$Structure.merge_kind
    if($mergeKind -notin @('none','anchor','non_anchor')){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先セルの結合状態を確認できません。'+$target)
    }
    if($mergeKind -eq 'non_anchor'){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 結合セルの左上以外には書き込めません。'+$target)
    }
    if($mergeKind -eq 'anchor' -and ([string]::IsNullOrWhiteSpace([string]$Structure.merge_area) -or [string]$Structure.merge_area -eq 'unknown')){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 結合セル範囲を確認できません。'+$target)
    }
    foreach($field in @('has_formula','has_array','has_spill')){
        $value=[string]$Structure.$field
        if($value -notin @('True','False')){
            throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 数式・配列・スピル状態を確認できません。'+$target)
        }
        if($value -eq 'True'){
            throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 数式・配列・スピルを含むセルには書き込めません。'+$target)
        }
    }
    $protected=[string]$Structure.worksheet_protect_contents;$locked=[string]$Structure.cell_locked
    if($protected -notin @('True','False') -or $locked -notin @('True','False')){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先セルの保護状態を確認できません。'+$target)
    }
    if($protected -eq 'True' -and $locked -eq 'True'){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 保護されたロックセルには書き込めません。'+$target)
    }
    $validationType=[string]$Structure.validation_type
    if([string]::IsNullOrWhiteSpace($validationType) -or $validationType -eq 'unknown'){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先セルの入力規則を確認できません。'+$target)
    }
    if($validationType -ne 'none'){
        throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 入力規則のあるセルには自動で書き込めません。'+$target)
    }
    return $true
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
        $outputText = Get-YakuCatTextOutput -Project $Project
        return [pscustomobject]@{
            OutputPath = ''
            OutputName = ''
            Text       = $outputText
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
    $byBlock = Get-YakuCatPlacementTranslationByBlockId -Project $Project -TranslationBySegmentIndex $bySegment
    if (-not (Test-Path -LiteralPath ([string]$Project.Path) -PathType Leaf)) {
        throw 'CAT_EXPORT_SOURCE_MISSING: 元の Excel が見つかりません。移動または削除されていないか確認してください。'
    }
    $expectedSourceHash=[string]$Project.SourceArtifactSha256
    if($expectedSourceHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'CAT_EXPORT_SOURCE_HASH_REQUIRED: 原本の識別情報を確認できません。'}
    $originalBlocks = @($Project.Blocks)
    if ($originalBlocks.Count -eq 0) {
        $originalBlocks = @(ConvertFrom-YakuCatSavedSegmentsToBlocks -Segments $segs)
    }
    $hashBefore = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    if($hashBefore -cne $expectedSourceHash.ToUpperInvariant()){
        throw 'CAT_EXPORT_SOURCE_ARTIFACT_CONFLICT: 原本が作業開始後に変更されています。「原文ファイルを差し替える」から新版として取り込んでください。'
    }
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
    # 配置計画が確認した原文セルと、今回実際に読み取ったセルが同一であることを
    # 全件先に検査する。1件でも違えば一切書き込まずに停止する。
    $placementDestinationByBlock = @{}
    foreach ($plan in @($Project.PlacementPlans)) {
        foreach ($destination in @($plan.destinations)) {
            if([string]$(try{$destination.mode}catch{'replace_source_block'}) -eq 'use_confirmed_empty'){continue}
            if($placementDestinationByBlock.ContainsKey([string]$destination.block_id)){throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 同じ原文blockが複数の配置先に指定されています。対象: '+[string]$destination.block_id)}
            $placementDestinationByBlock[[string]$destination.block_id] = $destination
        }
    }
    foreach ($oldId in @($byBlock.Keys)) {
        $destination = $placementDestinationByBlock[[string]$oldId]
        $newBlock = $resolved.Map[[string]$oldId]
        if ($null -eq $destination -or $null -eq $newBlock) {
            throw 'CAT_PLACEMENT_PRECONDITION_FAILED: 配置先の対応情報がありません。'
        }
        $actualSourceHash = Get-YakuCatSourceIntegrityHash -Text ([string]$newBlock.Text)
        if ($actualSourceHash -ne [string]$destination.expected_source_hash) {
            throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 原文セルが配置計画の確認後に変わりました。対象: ' + [string]$oldId)
        }
        $actualSheet=$(try{[string]$newBlock.Meta.Sheet}catch{''});$actualAddress=$(try{[string]$newBlock.Meta.A1}catch{''});$actualCodeName=$(try{[string]$newBlock.Meta.SheetCodeName}catch{''})
        if($actualSheet -cne [string]$destination.sheet -or $actualAddress -cne [string]$destination.address){throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先のシートまたはセル番地が一致しません。対象: '+[string]$oldId)}
        $expectedCodeName=$(try{[string]$destination.expected_sheet_code_name}catch{''});if(-not [string]::IsNullOrWhiteSpace($expectedCodeName) -and $expectedCodeName -cne $actualCodeName){throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先シートの識別子が一致しません。対象: '+[string]$oldId)}
        $actualStructure=$(try{$newBlock.Meta.StructureContract}catch{$null});$actualStructureHash=$(try{[string]$newBlock.Meta.StructureFingerprint}catch{''});$expectedStructureHash=$(try{[string]$destination.expected_structure_fingerprint}catch{''})
        if($null -eq $actualStructure -or [string]::IsNullOrWhiteSpace($actualStructureHash)){throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先セルの構造を確認できません。対象: '+[string]$oldId)}
        if(-not [string]::IsNullOrWhiteSpace($expectedStructureHash) -and $expectedStructureHash -ne $actualStructureHash){throw ('CAT_PLACEMENT_PRECONDITION_FAILED: 配置先セルの結合・保護・書式等が計画作成後に変わりました。対象: '+[string]$oldId)}
        $null=Assert-YakuCatExcelPlacementStructureSafe -Structure $actualStructure -BlockId ([string]$oldId)
    }
    # 追加する空白下セルも、値・数式・結合・配列・スピル・保護・入力規則・
    # 非表示・図形重なりを実Workbookで全件確認し終えるまで、一文字も書かない。
    $confirmedEmptyBlocks=@(Get-YakuCatConfirmedEmptyWriteTargets -Project $Project)
    $currentByBlock = @{}
    foreach ($oldId in @($byBlock.Keys)) {
        $newBlock = $resolved.Map[[string]$oldId]
        $currentByBlock[[string]$newBlock.Id] = [string]$byBlock[$oldId]
    }
    foreach($plan in @($Project.PlacementPlans)){
        foreach($destination in @($plan.destinations|Where-Object{[string]$(try{$_.mode}catch{''}) -eq 'use_confirmed_empty'})){
            $currentByBlock[[string]$destination.block_id]=[string]$destination.text
        }
    }
    $writeBlocks=@($currentExtract.Blocks)+@($confirmedEmptyBlocks)
    $sourceHashBeforeWrite = (Get-FileHash -LiteralPath ([string]$Project.Path) -Algorithm SHA256).Hash
    if ($sourceHashBeforeWrite -ne $hashAfter) {
        throw 'CAT_EXPORT_SOURCE_CHANGED_BEFORE_COPY: 元の Excel が出力直前に変更されました。訳文はまだ書き込んでいません。もう一度出力してください。'
    }
    # 訳す向きは出力書体を決める（英→和は和書体）。作業の向きをそのまま渡す。
    $writeResult = Write-YakuFileTranslations -InputPath ([string]$Project.Path) -OutputPath $OutputPath -Blocks @($writeBlocks) `
        -TranslationByBlockId $currentByBlock -Warnings $Warnings -Settings $Settings -Direction ([string]$Project.Direction) `
        -ProgressState $ProgressState -FailOnIncomplete
    return [pscustomobject]@{
        OutputPath = [string]$writeResult.PublishedPath
        OutputName = [System.IO.Path]::GetFileName([string]$writeResult.PublishedPath)
        Written    = [int]$writeResult.WrittenCount
        Skipped    = [int]$writeResult.SkippedCount
    }
}
