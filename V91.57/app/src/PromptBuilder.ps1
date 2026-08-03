# Keep these character sets identical to YAKU_ZH_ONLY/YAKU_JA_ONLY in www/assets/app.js.
$script:YakuZhSimplifiedChars = '们说这电买卖气汉车马鸟龙国际经济发东乐业专应见观议贝页风飞习书记语读谈请谁边达迟运过还进邮针钱银错门问间闻阳阴际陈难预领题风飘饭馆驶验鱼给绩线组织续维总编罗聚台么为兴举义乌产亿仅从优会伤估体余你侧价俭修倾储儿元党军写农凉减务动劳势区医华单卖南历厂压厅参双变叙叠只号叹后吓吕吗听启呜咏员响哑'
$script:YakuJaSpecificChars = '経済険応図売変対発拡広働込峠畑辻榊塩駅円団囲桜権沢浜渋瀬焼県窓縁労効単継絵転軽験鉄銭関顔悪帰実読満児仏圧巻歩黒麺涙戦絶縦緑総聴脳臓芸薬蔵訳証誉譲豊軸辺逓遅郷酔釈鋭録雑霊価併侮倹偽厳寿嘱囑噴壊壌壱奨姉娯嬢学宝実寛専岳峡巌帯帰廃弐弾従徳恵悩悪惨愉慎憎懐戸戻抜択拝拠挙掲揺摂撃斉断旧昼晩暁暑暦朗楽横欧歓歳残殴毎氷汚決渉済渇温湿滝滞漢潜瀬灯炉点為犬状独猟獣産畳癒発盗県真研砕碁秘称稲穀穂穏突窃絹継続総緒縄縦繊缶聖粛脇脱脹与'

function Get-YakuDirectionAnalysis {
    param([AllowNull()][string]$Text)
    $result = [pscustomobject]@{ Direction='to_jp'; Confidence='low'; Reason='empty' }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result }
    $kana = [regex]::Matches($Text, '[ぁ-んァ-ヶｦ-ﾟ]').Count
    $han = [regex]::Matches($Text, '[一-龯㐀-䶵々〆]').Count
    $latin = [regex]::Matches($Text, '[A-Za-z]').Count
    $meaningful = $kana + $han + $latin
    if ($meaningful -eq 0) { return $result }
    if ($kana -gt 0) {
        $jpRatio = ($kana + $han) / [double]$meaningful
        if ($jpRatio -ge 0.30) { $result.Direction='to_en'; $result.Confidence='high'; $result.Reason='kana-dominant' }
        elseif ($jpRatio -le 0.10) { $result.Direction='to_jp'; $result.Confidence='high'; $result.Reason='latin-dominant-few-kana' }
        else { $result.Direction='to_jp'; $result.Confidence='low'; $result.Reason='mixed-ja-en' }
        return $result
    }
    if ($han -gt 0) {
        $hasZh = $false; $hasJa = $false
        foreach ($ch in $Text.ToCharArray()) {
            if ($script:YakuZhSimplifiedChars.IndexOf($ch) -ge 0) { $hasZh = $true }
            elseif ($script:YakuJaSpecificChars.IndexOf($ch) -ge 0) { $hasJa = $true }
            if ($hasZh -and $hasJa) { break }
        }
        if ($hasZh -and -not $hasJa) { $result.Direction='to_jp'; $result.Confidence='high'; $result.Reason='zh-simplified'; return $result }
        $hanRatio = $han / [double]$meaningful
        if ($hasJa -and $hanRatio -ge 0.30) { $result.Direction='to_en'; $result.Confidence='high'; $result.Reason='ja-shinjitai'; return $result }
        if ($hanRatio -ge 0.30) { $result.Direction='to_en'; $result.Confidence='low'; $result.Reason='han-only-ambiguous'; return $result }
    }
    $result.Direction='to_jp'; $result.Confidence='high'; $result.Reason='latin-dominant'
    return $result
}

function Test-YakuJapaneseText {
    param([AllowNull()][string]$Text)
    return ((Get-YakuDirectionAnalysis -Text $Text).Direction -eq 'to_en')
}

function Get-YakuDirection {
    param([Parameter(Mandatory=$true)][string]$Text)
    return [string](Get-YakuDirectionAnalysis -Text $Text).Direction
}

function Get-YakuPromptFileText {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Prompt file not found: $Path" }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $fullPath = [System.IO.Path]::GetFullPath($item.FullName)
    $key = $fullPath + '|' + [string]$item.LastWriteTimeUtc.Ticks + '|' + [string]$item.Length
    if ($null -eq $script:YakuPromptFileCache) { $script:YakuPromptFileCache = @{} }
    if ($script:YakuPromptFileCache.ContainsKey($key)) { return [string]$script:YakuPromptFileCache[$key] }
    $text = (Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
    # Keep only the current signature for this path so template edits are picked
    # up automatically without allowing stale cache entries to accumulate.
    foreach ($oldKey in @($script:YakuPromptFileCache.Keys)) {
        if ([string]$oldKey -ne $key -and ([string]$oldKey).StartsWith(($fullPath + '|'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:YakuPromptFileCache.Remove($oldKey)
        }
    }
    $script:YakuPromptFileCache[$key] = $text
    return $text
}

function Get-YakuBriefRules {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'prompts\style_brief_rules.txt'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Prompt fragment not found: style_brief_rules.txt' }
    return (Get-YakuPromptFileText -Path $path).Trim()
}

function Get-YakuPromptTemplate {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $path = Join-Path $Root ("prompts\$Name")
    if (!(Test-Path -LiteralPath $path)) { throw "Prompt template not found: $Name" }
    $template = Get-YakuPromptFileText -Path $path
    if ($template.Contains('{brief_rules}')) {
        $template = $template.Replace('{brief_rules}', (Get-YakuBriefRules -Root $Root))
    }
    return $template
}

function ConvertTo-YakuGlossaryField {
    param([AllowNull()][object]$Value)
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $s = $s.TrimStart([char]0xFEFF)
    $s = $s -replace "`r`n|`r|`n", ' '
    $s = [regex]::Replace($s, '\s+', ' ')
    return $s.Trim()
}


function ConvertTo-YakuGlossaryMatchKey {
    param([AllowNull()][object]$Value)
    $s = ConvertTo-YakuGlossaryField -Value $Value
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    try { $s = $s.Normalize([System.Text.NormalizationForm]::FormKC) } catch {}
    $s = [regex]::Replace($s, '[\s　]+', ' ')
    return $s.Trim().ToLowerInvariant()
}

function Get-YakuGlossaryPromptLimit {
    param([AllowNull()]$Settings)
    $limit = 48
    try {
        if ($null -ne $Settings -and ($Settings.PSObject.Properties.Name -contains 'glossary_prompt_limit')) {
            $limit = [int]$Settings.glossary_prompt_limit
        }
    } catch { $limit = 48 }
    if ($limit -lt 1) { $limit = 48 }
    if ($limit -gt 200) { $limit = 200 }
    return [int]$limit
}

function Write-YakuGlossaryWarning {
    param([Parameter(Mandatory=$true)][string]$Message)
    try {
        if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog $Message 'WARN' }
        else { Write-Warning $Message }
    } catch {
        try { Write-Warning $Message } catch {}
    }
}

function Get-YakuGlossaryPath {
    param([Parameter(Mandatory=$true)][string]$Root)
    return (Join-Path $Root 'glossary.csv')
}

function Get-YakuPromptGlossaryPath {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'prompt_glossary.csv'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return (Get-YakuGlossaryPath -Root $Root)
}

function Get-YakuGlossaryEntries {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$Path,
        [switch]$IncludeDuplicates
    )
    $glossary = if ([string]::IsNullOrWhiteSpace($Path)) { Get-YakuGlossaryPath -Root $Root } else { [string]$Path }
    if (!(Test-Path -LiteralPath $glossary -PathType Leaf)) { return @() }

    $fileInfo = $null
    $cacheKey = ''
    $cachePathKey = ''
    try {
        $fileInfo = Get-Item -LiteralPath $glossary -ErrorAction Stop
        $cachePathKey = ([System.IO.Path]::GetFullPath($fileInfo.FullName)).ToLowerInvariant()
        $cacheKey = ([string]$fileInfo.LastWriteTimeUtc.Ticks) + '|' + ([string]$fileInfo.Length)
    } catch {
        try { $cachePathKey = ([System.IO.Path]::GetFullPath($glossary)).ToLowerInvariant() } catch { $cachePathKey = [string]$glossary }
        $cacheKey = [string](Get-Date).Ticks
    }

    try {
        if ($script:YakuGlossaryEntriesCache -is [hashtable] -and $script:YakuGlossaryEntriesCache.ContainsKey($cachePathKey)) {
            $cached = $script:YakuGlossaryEntriesCache[$cachePathKey]
            if ($null -ne $cached -and ([string]$cached.Key) -eq $cacheKey) {
                if ($IncludeDuplicates) { return @($cached.AllEntries) }
                return @($cached.DedupedEntries)
            }
        }
    } catch {}

    $entries = New-Object System.Collections.Generic.List[object]
    $parser = $null
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop | Out-Null
        $parser = New-Object -TypeName Microsoft.VisualBasic.FileIO.TextFieldParser -ArgumentList @($glossary)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false

        $row = 0
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            $row++
            if ($null -eq $fields) { continue }
            if ($fields.Length -lt 2) { continue }

            $source = ConvertTo-YakuGlossaryField -Value $fields[0]
            $targetRaw = ConvertTo-YakuGlossaryField -Value $fields[1]
            $scope = if ($fields.Length -ge 3) { (ConvertTo-YakuGlossaryField -Value $fields[2]).ToLowerInvariant() } else { 'occurrence' }
            if ($scope -ne 'cell-exact') { $scope = 'occurrence' }
            $variants = @($targetRaw -split '\|' | ForEach-Object { ConvertTo-YakuGlossaryField -Value $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            $target = if ($variants.Count -gt 0) { [string]$variants[0] } else { '' }
            if ([string]::IsNullOrWhiteSpace($source)) { continue }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            if ($source.StartsWith('#')) { continue }

            $entries.Add([pscustomobject]@{
                Source = [string]$source
                Target = [string]$target
                Variants = [string[]]@($variants)
                Scope = [string]$scope
                Row = [int]$row
                SourceLength = [int]$source.Length
                TargetLength = [int]$target.Length
                MaxLength = [int]([Math]::Max($source.Length, $target.Length))
                SourceKey = ConvertTo-YakuGlossaryMatchKey -Value $source
                TargetKey = ConvertTo-YakuGlossaryMatchKey -Value $target
            }) | Out-Null
        }
    } catch {
        $entries = New-Object System.Collections.Generic.List[object]
        $row = 0
        $lines = @(Get-Content -LiteralPath $glossary -Encoding UTF8 -ErrorAction Stop)
        foreach ($line in $lines) {
            $row++
            $raw = [string]$line
            $trimmed = $raw.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed.StartsWith('#')) { continue }
            $parts = $raw -split ',', 4
            if ($parts.Count -lt 2) { continue }
            $source = ConvertTo-YakuGlossaryField -Value $parts[0]
            $targetRaw = ConvertTo-YakuGlossaryField -Value $parts[1]
            $scope = if ($parts.Count -ge 3) { (ConvertTo-YakuGlossaryField -Value $parts[2]).ToLowerInvariant() } else { 'occurrence' }
            if ($scope -ne 'cell-exact') { $scope = 'occurrence' }
            $variants = @($targetRaw -split '\|' | ForEach-Object { ConvertTo-YakuGlossaryField -Value $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            $target = if ($variants.Count -gt 0) { [string]$variants[0] } else { '' }
            if ([string]::IsNullOrWhiteSpace($source)) { continue }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            $entries.Add([pscustomobject]@{
                Source = [string]$source
                Target = [string]$target
                Variants = [string[]]@($variants)
                Scope = [string]$scope
                Row = [int]$row
                SourceLength = [int]$source.Length
                TargetLength = [int]$target.Length
                MaxLength = [int]([Math]::Max($source.Length, $target.Length))
                SourceKey = ConvertTo-YakuGlossaryMatchKey -Value $source
                TargetKey = ConvertTo-YakuGlossaryMatchKey -Value $target
            }) | Out-Null
        }
    } finally {
        if ($null -ne $parser) {
            try { $parser.Close() } catch {}
            try { $parser.Dispose() } catch {}
        }
    }

    $allEntries = @($entries.ToArray())
    $deduped = New-Object System.Collections.Generic.List[object]
    $groups = @{}
    foreach ($entry in $allEntries) {
        $sourceKey = [string]$entry.SourceKey
        if ([string]::IsNullOrWhiteSpace($sourceKey)) { continue }
        if (-not $groups.ContainsKey($sourceKey)) { $groups[$sourceKey] = New-Object System.Collections.Generic.List[object] }
        $groups[$sourceKey].Add($entry) | Out-Null
    }

    foreach ($sourceKey in @($groups.Keys)) {
        $group = @($groups[$sourceKey].ToArray() | Sort-Object Row)
        if ($group.Count -le 0) { continue }

        $pairFirstRows = @{}
        foreach ($entry in $group) {
            $pairKey = ([string]$entry.SourceKey) + ([string][char]31) + ([string]$entry.TargetKey)
            if ($pairFirstRows.ContainsKey($pairKey)) {
                $first = $pairFirstRows[$pairKey]
                Write-YakuGlossaryWarning "$([System.IO.Path]::GetFileName($glossary)) duplicate ignored: '$($entry.Source)' -> '$($entry.Target)' row=$($entry.Row), firstRow=$first"
            } else {
                $pairFirstRows[$pairKey] = [int]$entry.Row
            }
        }

        $targetKeys = @{}
        foreach ($entry in $group) {
            $targetKey = [string]$entry.TargetKey
            if (-not $targetKeys.ContainsKey($targetKey)) { $targetKeys[$targetKey] = $true }
        }

        if ($targetKeys.Count -gt 1) {
            $chosen = @($group | Sort-Object Row | Select-Object -Last 1)[0]
            foreach ($entry in $group) {
                if ([int]$entry.Row -eq [int]$chosen.Row) { continue }
                if ([string]$entry.TargetKey -ne [string]$chosen.TargetKey) {
                    Write-YakuGlossaryWarning "$([System.IO.Path]::GetFileName($glossary)) conflicting target for '$($entry.Source)': '$($entry.Target)' row=$($entry.Row), using row=$($chosen.Row) '$($chosen.Target)'"
                }
            }
            $deduped.Add($chosen) | Out-Null
        } else {
            $firstUnique = @($group | Sort-Object Row | Select-Object -First 1)[0]
            $deduped.Add($firstUnique) | Out-Null
        }
    }

    $ordered = @($deduped.ToArray() | Sort-Object -Property @{ Expression = { '{0:D10}|{1:D10}|{2:D10}' -f (999999 - [int]$_.MaxLength), (999999 - [int]$_.SourceLength), [int]$_.Row } })
    try {
        if (-not ($script:YakuGlossaryEntriesCache -is [hashtable])) { $script:YakuGlossaryEntriesCache = @{} }
        $script:YakuGlossaryEntriesCache[$cachePathKey] = [pscustomobject]@{
            Key = [string]$cacheKey
            AllEntries = @($allEntries)
            DedupedEntries = @($ordered)
        }
    } catch {}

    if ($IncludeDuplicates) { return @($allEntries) }
    return @($ordered)
}

function Find-YakuExactTermIndexes {
    param(
        [AllowNull()][string]$InputText,
        [AllowNull()][string]$Term
    )
    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
    if ([string]::IsNullOrWhiteSpace($Term)) { return @() }

    $text = ConvertTo-YakuGlossaryMatchKey -Value $InputText
    $termText = ConvertTo-YakuGlossaryMatchKey -Value $Term
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    if ([string]::IsNullOrWhiteSpace($termText)) { return @() }
    if ($termText.Length -lt 2) { return @() }

    $positions = New-Object System.Collections.Generic.List[int]
    if ($termText -match '^[\x00-\x7F]+$' -and $termText -match '[a-z0-9]') {
        $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($termText) + '(?![A-Za-z0-9])'
        $matches = [regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in @($matches)) { if ($m.Success) { $positions.Add([int]$m.Index) | Out-Null } }
        return @($positions.ToArray())
    }

    if ($termText -match '^[ァ-ヶーｦ-ﾟ・]+$') {
        $pattern = '(?<![ァ-ヶーｦ-ﾟ])' + [regex]::Escape($termText) + '(?![ァ-ヶーｦ-ﾟ])'
        $matches = [regex]::Matches($text, $pattern)
        foreach ($m in @($matches)) { if ($m.Success) { $positions.Add([int]$m.Index) | Out-Null } }
        return @($positions.ToArray())
    }

    $start = 0
    while ($start -lt $text.Length) {
        $pos = $text.IndexOf($termText, $start, [System.StringComparison]::Ordinal)
        if ($pos -lt 0) { break }
        # 「半期」は「四半期」の一部としても現れるが、両者は別の会計期間。
        # 四半期を Half-year と誤認してプロンプト／監査へ載せない。
        $excludedComposite = ($termText -eq '半期' -and $pos -gt 0 -and $text[$pos - 1] -eq '四')
        if (-not $excludedComposite) { $positions.Add([int]$pos) | Out-Null }
        $next = $pos + [Math]::Max(1, $termText.Length)
        if ($next -le $start) { break }
        $start = $next
    }
    return @($positions.ToArray())
}

function Find-YakuExactTermIndex {
    param(
        [AllowNull()][string]$InputText,
        [AllowNull()][string]$Term
    )
    $positions = @(Find-YakuExactTermIndexes -InputText $InputText -Term $Term)
    if ($positions.Count -le 0) { return -1 }
    return [int]$positions[0]
}

function Get-YakuRelevantGlossaryMatches {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$InputText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [int]$Limit = 48,
        [AllowNull()][string]$Path
    )
    if ($Limit -lt 1) { return @() }
    $entries = @(Get-YakuGlossaryEntries -Root $Root -Path $Path)
    if ($entries.Count -le 0) { return @() }

    $matched = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($entry in $entries) {
        $source = ConvertTo-YakuGlossaryField -Value $entry.Source
        $target = ConvertTo-YakuGlossaryField -Value $entry.Target
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        $termToFind = ''
        $replacement = ''
        if ($Direction -eq 'to_jp') {
            $termToFind = [string]$target
            $replacement = [string]$source
        } else {
            $termToFind = [string]$source
            $replacement = [string]$target
        }

        $entryScope = if ($entry.PSObject.Properties.Name -contains 'Scope') { [string]$entry.Scope } else { 'occurrence' }
        if ($entryScope -eq 'cell-exact') {
            $inputKey = ConvertTo-YakuGlossaryMatchKey -Value $InputText
            $termExactKey = ConvertTo-YakuGlossaryMatchKey -Value $termToFind
            if (-not [string]::Equals($inputKey, $termExactKey, [System.StringComparison]::Ordinal)) { continue }
            $positions = @(0)
        } else {
            $positions = @(Find-YakuExactTermIndexes -InputText $InputText -Term $termToFind)
            if ($positions.Count -le 0) { continue }
        }

        $termKey = ConvertTo-YakuGlossaryMatchKey -Value $termToFind
        if ([string]::IsNullOrWhiteSpace($termKey) -or $termKey.Length -lt 2) { continue }

        $key = (ConvertTo-YakuGlossaryMatchKey -Value $source) + '=>' + (ConvertTo-YakuGlossaryMatchKey -Value $target)
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $intervals = New-Object System.Collections.Generic.List[object]
        foreach ($pos in $positions) {
            $intervals.Add([pscustomobject]@{ Start=[int]$pos; End=[int]([int]$pos + [int]$termKey.Length) }) | Out-Null
        }
        $rowNum = 0
        try { $rowNum = [int]$entry.Row } catch { $rowNum = 0 }
        $matched.Add([pscustomobject]@{
            Source = [string]$source
            Target = [string]$target
            From = [string]$termToFind
            To = [string]$replacement
            Position = [int]$positions[0]
            Positions = [int[]]@($positions)
            MatchLength = [int]([string]$termToFind).Length
            NormLength = [int]$termKey.Length
            OccurrenceCount = [int]$positions.Count
            Intervals = @($intervals.ToArray())
            Row = [int]$rowNum
            Variants = if ($entry.PSObject.Properties.Name -contains 'Variants') { [string[]]@($entry.Variants) } else { [string[]]@($target) }
            Scope = [string]$entryScope
            SortKey = ('{0:D10}|{1:D10}|{2:D10}' -f [int](999999 - [int]$positions.Count), [int](999999 - [int]$termKey.Length), [int]$rowNum)
        }) | Out-Null
    }

    if ($matched.Count -le 0) { return @() }

    $coveredIntervals = New-Object System.Collections.Generic.List[object]
    $survivors = New-Object System.Collections.Generic.List[object]
    $lengths = @($matched.ToArray() | ForEach-Object { [int]$_.NormLength } | Sort-Object -Descending -Unique)

    foreach ($length in $lengths) {
        $groupSurvivors = New-Object System.Collections.Generic.List[object]
        $group = @($matched.ToArray() | Where-Object { [int]$_.NormLength -eq [int]$length } | Sort-Object Row)
        foreach ($item in $group) {
            $survivalIntervals = New-Object System.Collections.Generic.List[object]
            $survivalPositions = New-Object System.Collections.Generic.List[int]
            foreach ($interval in @($item.Intervals)) {
                $contained = $false
                foreach ($covered in @($coveredIntervals.ToArray())) {
                    if ([int]$covered.Start -le [int]$interval.Start -and [int]$interval.End -le [int]$covered.End) {
                        $contained = $true
                        break
                    }
                }
                if (-not $contained) {
                    $survivalIntervals.Add($interval) | Out-Null
                    $survivalPositions.Add([int]$interval.Start) | Out-Null
                }
            }

            if ($survivalIntervals.Count -le 0) {
                try {
                    $termForLog = ([string]$item.From).Replace("'", "''")
                    if (-not (Get-Variable -Name YakuGlossaryContainmentLogged -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:YakuGlossaryContainmentLogged) { $script:YakuGlossaryContainmentLogged = @{} }
                    if (-not $script:YakuGlossaryContainmentLogged.ContainsKey($termForLog)) {
                        $script:YakuGlossaryContainmentLogged[$termForLog] = $true
                        Write-YakuLog "Glossary containment excluded: term='$termForLog' coveredBy=longer terms" 'DEBUG'
                    }
                } catch {}
                continue
            }

            $occurrenceCount = [int]$survivalIntervals.Count
            $position = [int]($survivalPositions.ToArray()[0])
            $rowNum = [int]$item.Row
            $survivor = [pscustomobject]@{
                Source = [string]$item.Source
                Target = [string]$item.Target
                From = [string]$item.From
                To = [string]$item.To
                Variants = if ($item.PSObject.Properties.Name -contains 'Variants') { [string[]]@($item.Variants) } else { [string[]]@([string]$item.To) }
                Scope = if ($item.PSObject.Properties.Name -contains 'Scope') { [string]$item.Scope } else { 'occurrence' }
                Position = [int]$position
                Positions = [int[]]@($survivalPositions.ToArray())
                MatchLength = [int]$item.MatchLength
                NormLength = [int]$item.NormLength
                OccurrenceCount = [int]$occurrenceCount
                Intervals = @($survivalIntervals.ToArray())
                Row = [int]$rowNum
                SortKey = ('{0:D10}|{1:D10}|{2:D10}' -f [int](999999 - [int]$occurrenceCount), [int](999999 - [int]$item.NormLength), [int]$rowNum)
            }
            $groupSurvivors.Add($survivor) | Out-Null
            $survivors.Add($survivor) | Out-Null
        }

        foreach ($survivor in @($groupSurvivors.ToArray())) {
            foreach ($interval in @($survivor.Intervals)) {
                $coveredIntervals.Add($interval) | Out-Null
            }
        }
    }

    $orderedSurvivors = @($survivors.ToArray() | Sort-Object -Property SortKey | Select-Object -First $Limit)
    return @($orderedSurvivors)
}

function Get-YakuRelevantGlossaryLines {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$InputText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [int]$Limit = 48,
        [AllowNull()][string]$Path
    )
    $matches = @(Get-YakuRelevantGlossaryMatches -Root $Root -InputText $InputText -Direction $Direction -Limit $Limit -Path $Path)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $matches) {
        $lines.Add('- ' + [string]$item.From + ' = ' + [string]$item.To) | Out-Null
    }
    return @($lines.ToArray())
}

function Get-YakuAppliedGlossaryEntries {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [AllowNull()][string]$InputText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [AllowNull()]$Settings,
        [int]$Limit = 0
    )
    if ($Limit -le 0) { $Limit = Get-YakuGlossaryPromptLimit -Settings $Settings }
    $path = Get-YakuPromptGlossaryPath -Root $Root
    return @(Get-YakuRelevantGlossaryMatches -Root $Root -InputText $InputText -Direction $Direction -Limit $Limit -Path $path)
}

function Get-YakuReferenceSection {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()][string]$InputText,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    $useGlossary = $true
    try { $useGlossary = [bool]$Settings.use_bundled_glossary } catch { $useGlossary = $true }
    if (-not $useGlossary) { return '' }

    $limit = Get-YakuGlossaryPromptLimit -Settings $Settings
    $path = Get-YakuPromptGlossaryPath -Root $Root
    $lines = @(Get-YakuRelevantGlossaryLines -Root $Root -InputText $InputText -Direction $Direction -Limit $limit -Path $path)
    if ($lines.Count -le 0) { return '' }
    $nl = [Environment]::NewLine
    return ('GLOSSARY (mandatory). When a source term below appears, use the mapped target term exactly; never a synonym; never apply to items where the term does not occur. FULL uses the spelled-out mapped term; BRIEF may replace it with its standard abbreviation from the BRIEF rules (spelled-out form and its abbreviation count as the same rendering). Casing: keep all-caps acronyms and proper nouns (e.g. FX, OP, B/E) exactly as listed; abbreviations of ordinary words (e.g. Vol., Act.) and ordinary words follow the context - capitalized as listed only when the term stands alone as a heading or label line; inside a sentence, including signed breakdown lists, it is running text (lowercase):' + $nl + ($lines -join $nl))
}

function Get-YakuNumericRulesSection {
    param([AllowNull()][string]$InputText)
    if ([string]$InputText -notmatch '[0-9０-９▲△＋+%％〜~↑↓<>＜＞→]|oku|k units|k yen|YoY|QoQ|CAGR|前年|四半期') { return '' }
    $nl = [Environment]::NewLine
    return (@(
        '- Positive/additive amounts marked +, ＋, or プラス keep +N.'
        '- ▲, negative minus signs, or マイナス: put parentheses around the numeric token only; keep units and % outside. Valid: (72) k units, (xxx) oku, (3) %.'
        '- Numeric tokens already in English (oku, k units, k yen): keep the number and unit verbatim; never rescale, re-convert, add yen after oku, or restore Japanese units. Signs and % follow the existing rules. Never million, billion, trillion, bn, or tn.'
        '- Arrow (→) between two numbers: reproduce ONLY when SOURCE writes A→B; never create one. No tilde or greater-than/less-than signs; use words. Keep YoY, QoQ, CAGR, Jan. to Dec.'
    ) -join $nl)
}

function Get-YakuStyleReferenceSection {
    param([AllowNull()][string]$StyleReference)
    if ([string]::IsNullOrWhiteSpace($StyleReference)) { return '' }
    $nl = [Environment]::NewLine
    return ('STYLE_REFERENCE from the previous batch. Use it only to keep terminology, tone, and sentence style consistent. Do not translate or repeat this text:' + $nl + ([string]$StyleReference).Trim())
}

function Expand-YakuTemplate {
    param(
        [Parameter(Mandatory=$true)][string]$Template,
        [Parameter(Mandatory=$true)][hashtable]$Variables
    )
    return [regex]::Replace($Template, '\{(\w+)\}', {
        param($match)
        $key = [string]$match.Groups[1].Value
        if ($Variables.ContainsKey($key)) { return [string]$Variables[$key] }
        return [string]$match.Value
    })
}

function New-YakuTextPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$DirectionOverride,
        [AllowNull()][string]$StyleReference,
        [AllowNull()][string]$RequestId
    )
    if ([string]::IsNullOrWhiteSpace($RequestId)) { $RequestId = [guid]::NewGuid().ToString('N') }
    $direction = if ([string]::IsNullOrWhiteSpace($DirectionOverride)) { Get-YakuDirection -Text $InputText } else { $DirectionOverride }
    $templateName = if ($direction -eq 'to_en') { 'text_translate_to_en.txt' } else { 'text_translate_to_jp.txt' }
    $template = Get-YakuPromptTemplate -Root $Root -Name $templateName
    $vars = @{
        input_text = $InputText.Trim()
        reference_section = Get-YakuReferenceSection -Root $Root -Settings $Settings -InputText $InputText -Direction $direction
        style_reference_section = Get-YakuStyleReferenceSection -StyleReference $StyleReference
        numeric_rules = if ($direction -eq 'to_en') { Get-YakuNumericRulesSection -InputText $InputText } else { '' }
        request_id = $RequestId
    }
    return [pscustomobject]@{
        Direction = $direction
        Prompt = Expand-YakuTemplate -Template $template -Variables $vars
    }
}

function New-YakuBackTranslatePrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()][string]$RequestId
    )
    $built = New-YakuTextPrompt -Root $Root -InputText $InputText -Settings $Settings -DirectionOverride 'to_jp' -RequestId $RequestId
    return $built.Prompt
}

function Get-YakuGlossaryDuplicateSummaryHtml {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Entries)
    $pairs = @{}
    $sources = @{}
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Entries | Sort-Object Row)) {
        $sourceKey = ConvertTo-YakuGlossaryMatchKey -Value $entry.Source
        $targetKey = ConvertTo-YakuGlossaryMatchKey -Value $entry.Target
        $key = $sourceKey + ([string][char]31) + $targetKey
        if ($pairs.ContainsKey($key)) {
            $warnings.Add("重複: $($entry.Source) → $($entry.Target) / row $($pairs[$key]), $($entry.Row)") | Out-Null
        } else {
            $pairs[$key] = [int]$entry.Row
        }
        if (-not $sources.ContainsKey($sourceKey)) {
            $sources[$sourceKey] = [pscustomobject]@{ TargetKey=$targetKey; Target=[string]$entry.Target; Row=[int]$entry.Row }
        } elseif ([string]$sources[$sourceKey].TargetKey -ne $targetKey) {
            $warnings.Add("競合: $($entry.Source) → $([string]$sources[$sourceKey].Target) / $($entry.Target) (row $([int]$sources[$sourceKey].Row), $($entry.Row))") | Out-Null
        }
    }
    if ($warnings.Count -le 0) { return "<div class='muted'>重複・競合は検出されていません。長い語を優先して参照します。</div>" }
    $html = "<div class='alert alert-warning'><strong>重複・競合候補</strong><ul>"
    foreach ($w in @($warnings.ToArray() | Select-Object -First 12)) {
        $html += "<li>$(ConvertTo-YakuHtml $w)</li>"
    }
    $html += "</ul></div>"
    return $html
}

function Convert-YakuGlossarySectionToHtml {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][string]$DisplayPath,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$AllEntries,
        [AllowNull()][string]$Status = ''
    )
    $ordered = @($Entries | Sort-Object Row)
    $statusHtml = if ([string]::IsNullOrWhiteSpace($Status)) { '' } else { "<div class='alert alert-warning'>$(ConvertTo-YakuHtml $Status)</div>" }
    $warningHtml = Get-YakuGlossaryDuplicateSummaryHtml -Entries $AllEntries
    $html = @"
<section class='glossary-section'>
  <h3>$(ConvertTo-YakuHtml $Title)</h3>
  <p>$(ConvertTo-YakuHtml $Description)</p>
  <div class='muted glossary-path'>$(ConvertTo-YakuHtml $DisplayPath)</div>
  <div class='glossary-count'>エントリ件数: $($ordered.Count)</div>
  $statusHtml
  $warningHtml
  <div class='glossary-table-wrap'>
    <table class='glossary-table'>
      <thead><tr><th>行</th><th>用語</th><th>訳語</th></tr></thead>
      <tbody>
"@
    foreach ($entry in $ordered) {
        $html += @"
        <tr>
          <td>$(ConvertTo-YakuHtml $entry.Row)</td>
          <td>$(ConvertTo-YakuHtml $entry.Source)</td>
          <td>$(ConvertTo-YakuHtml $entry.Target)</td>
        </tr>
"@
    }
    $html += @"
      </tbody>
    </table>
  </div>
</section>
"@
    return $html
}

function Convert-YakuGlossaryManagerToHtml {
    param([Parameter(Mandatory=$true)][string]$Root)
    $machinePath = Get-YakuGlossaryPath -Root $Root
    $machineEntries = @(Get-YakuGlossaryEntries -Root $Root -Path $machinePath)
    $machineAllEntries = @(Get-YakuGlossaryEntries -Root $Root -Path $machinePath -IncludeDuplicates)
    $machineStatus = if (Test-Path -LiteralPath $machinePath -PathType Leaf) { '' } else { '未作成' }

    $promptDisplayPath = Join-Path $Root 'prompt_glossary.csv'
    $promptExists = Test-Path -LiteralPath $promptDisplayPath -PathType Leaf
    $promptReadPath = Get-YakuPromptGlossaryPath -Root $Root
    $promptEntries = @(Get-YakuGlossaryEntries -Root $Root -Path $promptReadPath)
    $promptAllEntries = @(Get-YakuGlossaryEntries -Root $Root -Path $promptReadPath -IncludeDuplicates)
    $promptStatus = if ($promptExists) { '' } else { "未作成(glossary.csv にフォールバック中): $promptReadPath" }

    $machineHtml = Convert-YakuGlossarySectionToHtml -Title '表ラベル置換用 — glossary.csv' -Description 'Excel/CSVのセルが完全一致したときCopilotを使わず直接置換。表の正式表記で登録。' -DisplayPath $machinePath -Entries $machineEntries -AllEntries $machineAllEntries -Status $machineStatus
    $promptHtml = Convert-YakuGlossarySectionToHtml -Title 'Copilot翻訳用 — prompt_glossary.csv' -Description '翻訳プロンプトに参考訳語として注入。文中の形(一般語は小文字)で登録。' -DisplayPath $promptDisplayPath -Entries $promptEntries -AllEntries $promptAllEntries -Status $promptStatus
    $html = @"
<div class='glossary-manager'>
  <div class='alert alert-info glossary-readonly-note'>編集は各CSVファイルを直接編集してください(UTF-8 BOM付き・カンマ区切り)。保存後は次回の翻訳から自動反映されます。</div>
  $machineHtml
  $promptHtml
</div>
"@
    return $html
}
