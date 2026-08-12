# Direction decisions are authoritative on the server; browser clients do not duplicate these sets.
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
    if ($meaningful -eq 0) { $result.Reason='no-language-text'; return $result }
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
        # 漢字だけの見出しは日本語・中国語のどちらにも見える。新字体が含まれて
        # いても、利用者に確認せず英訳へ送らない。英字との混在も同様に止める。
        if ($kana -eq 0) {
            $result.Direction = $(if ($hasJa -or $hanRatio -ge 0.30) { 'to_en' } else { 'to_jp' })
            $result.Confidence='low'
            $result.Reason=$(if ($latin -gt 0) { 'mixed-han-latin' } else { 'han-only-ambiguous' })
            return $result
        }
    }
    $result.Direction='to_jp'
    if ($latin -lt 4) { $result.Confidence='low'; $result.Reason='short-latin-ambiguous' }
    else { $result.Confidence='high'; $result.Reason='latin-dominant' }
    return $result
}

function Get-YakuDirectionSourceFingerprint {
    param([AllowNull()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Resolve-YakuDirectionDecision {
    <#
      方向は入力ごとに一度だけ解決する。auto の低確度は resolved を返さず、
      Copilot送信やCAT project作成より前に利用者の選択を要求する。
    #>
    param(
        [AllowNull()][string]$Text,
        [ValidateSet('auto','to_en','to_jp')][string]$Intent = 'auto',
        [ValidateSet('detected','explicit','inherited','fixed')][string]$Basis = 'detected'
    )
    $fingerprint = Get-YakuDirectionSourceFingerprint -Text ([string]$Text)
    if (@('to_en','to_jp') -contains $Intent) {
        return [pscustomobject]@{
            Intent=$Intent; Resolved=$Intent; Basis=$Basis; Confidence='not_applicable'
            RequiresConfirmation=$false; SourceFingerprint=$fingerprint; Reason='explicit'
        }
    }
    $analysis = Get-YakuDirectionAnalysis -Text ([string]$Text)
    $requires = ([string]$analysis.Confidence -ne 'high')
    return [pscustomobject]@{
        Intent='auto'; Resolved=$(if($requires){''}else{[string]$analysis.Direction})
        SuggestedDirection=[string]$analysis.Direction; Basis='detected'
        Confidence=[string]$analysis.Confidence; RequiresConfirmation=$requires
        SourceFingerprint=$fingerprint; Reason=[string]$analysis.Reason
    }
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
    # 個人用の用語集を上に重ねる。市販ツールでも、共通のものと作業用のものを
    # 2段重ねにして作業用を優先する。配布分はいま開発者が代わりに作っている
    # 下敷きで、本来は各自が貯めるもの（利用者の整理 2026-08-08）。
    # 将来「各自が作る」へ移るときは、配布分を外すだけで済む。
    try {
        if (Get-Command Read-YakuPersonalGlossary -ErrorAction SilentlyContinue) {
            $personal = Read-YakuPersonalGlossary
            if ($personal.Count -gt 0) {
                $merged = New-Object System.Collections.Generic.List[object]
                $ownKeys = @{}
                foreach ($k in @($personal.Keys)) {
                    $ownKeys[[string]$k] = $true
                    [void]$merged.Add([pscustomobject]@{ Source = [string]$k; Target = [string]$personal[$k]; Row = 0; Origin = 'personal' })
                }
                foreach ($e in @($ordered)) {
                    if ($ownKeys.ContainsKey([string]$e.Source)) { continue }
                    [void]$merged.Add($e)
                }
                return @($merged.ToArray())
            }
        }
    } catch {
        try { Write-YakuLog ('Personal glossary merge failed: ' + $_.Exception.Message) 'WARN' } catch {}
    }
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

# GLOSSARY 節は廃止した（利用者の判断 2026-08-06）。
#
# 用語集の目的はレイアウトの保証であって、文中の言い回しの統一ではない
# （_docs/決定_用語集は用語の一貫性ではなくレイアウトの保証.md）。
# はみ出すのはラベルであり、文はセルの中で折り返せば行高が吸収する。
#
# 実機で、GLOSSARY 節があるとコーパスの言い回しが通らず、切ると通ることを
# 確認した（_docs/実機検証結果_2026-08-05.md §3-2）。文中では用語集が
# コーパスの邪魔をしていた。
#
# 既存の翻訳製品も、文中の用語を機械的に置換していない。CAT/TMS は印を付けて
# 人が直し、MT の用語集（DeepL / Google）はモデルの内側で寄せる仕組みで、
# DeepL は「search-and-replace 方式ではない」と明記し、Google は用語集適用前と
# 適用後の両方を返す（＝保証ではない）。活用と一致が壊れるためである。
#
# ラベルの保証は Resolve-YakuFileExactGlossaryTranslations のセル完全一致が担う。

function Get-YakuAmountNotation {
    <#
      金額の書き方を設定から取り出す。設定が読めない経路（回帰テスト、
      ワーカー、部分読み込み）でも止めず、既定の oku へ落ちる。
      翻訳が止まる理由にはしない。
    #>
    param([AllowNull()]$Settings)
    $v = ''
    try { $v = [string]$Settings.amount_notation } catch { $v = '' }
    # 2026-08-12: 桁の換算を Convert-YakuNumericUnits へ入れたので billion を開けた。
    # 換算はアプリ側で済ませ、Copilot には伏せた数値しか渡さない（計算させない）。
    #   1兆3,150億円 -> 1,315 billion（億 ÷ 10）
    # 塞いでいた理由（単位名だけ替えると 122億円 が ¥122 billion になる 10倍の誤り）は、
    # 割り算が入ったことで消えた。実測は tools/Test-YakuV9160NumericMasking.ps1 にある。
    if ($v -eq 'billion') { return 'billion' }
    return 'oku'
}

function Get-YakuNumericRulesSection {
    param(
        [AllowNull()][string]$InputText,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        # 金額の書き方。設定 amount_notation から来る。
        #
        #   billion  ¥12.2 billion。負数は括弧を使わず "a decrease of ¥12.2 billion"
        #            と言葉で書く。マツダの英文開示12冊で ¥ を括弧で囲む形は
        #            1件も無かった。外部公表はこちら
        #   oku      122 oku。負数は (12.2) oku。社内資料の一部で使う書き方
        #
        # かつては plain / house / published の3つだったが、plain と published は
        # 規則がほぼ同一だった（2026-08-08 に確認）。訳の種類ではなく金額の
        # 書き方なので、2つに畳んで設定へ移した。
        [ValidateSet('oku','billion')][string]$Notation = 'oku'
    )
    if ([string]$InputText -notmatch '\[\[N\d+\]\]|[0-9０-９▲△＋+%％〜~↑↓<>＜＞→]|oku|k units|k yen|YoY|QoQ|CAGR|前年|四半期') { return '' }
    $nl = [Environment]::NewLine
    # V91.60 段階4: to_jp は単位が訳されるため、逐語保持を前提にした to_en の
    # 規則をそのまま流用できない。方向ごとに別の規則を返す。
    # 指示の地の文は英語で揃える。テンプレート本体が英語であり、
    # 途中で指示言語が切り替わるのは避ける。日本語の単位名だけを字義どおり置く。
    if ($Direction -eq 'to_jp') {
        $jpRules = @()
        if ([string]$InputText -match '\[\[N\d+\]\]') {
            $jpRules += '- NUMBER PLACEHOLDERS (highest priority). [[N1]], [[N2]] ... stand for redacted numbers. Copy each token character-for-character into the Japanese output. Never translate, renumber, reorder, merge, split, or drop one; never invent one; never replace one with a digit or with a word such as 一定額, 約, 数, or いくつか. Every token in SOURCE appears the same number of times in the output. A number written WITHOUT a placeholder is not redacted: copy it verbatim as a number.'
        }
        $jpRules += '- Render units in Japanese one for one, without regrouping digits: oku -> 億円 / k yen -> 千円 / k units -> 千台. Keep % as %. Never recompute the magnitude: 12,340 k yen is 12,340千円, never 1億2,340万円.'
        $jpRules += '- Signs follow SOURCE. A value written in parentheses becomes ▲ in front of the value: ([[N1]]) oku -> ▲[[N1]]億円. Keep + as +.'
        return (@($jpRules) -join $nl)
    }
    # V91.60: 数値は外部送信前に[[N1]]へ置き換えている。指示は禁止事項の列挙ではなく
    # 「左に一致したら右を出す」形の決定表で書く。想定外の形が来たときでも
    # 行き先を類推できるようにするため。
    if ($Notation -eq 'billion') {
        # 外部公表の書き方。マツダの英文開示12冊を読んで決めた。
        # oku 表記（括弧の負数）は持ち込まない。
        $billionRules = @()
        if ([string]$InputText -match '\[\[N\d+\]\]') {
            $billionRules += '- NUMBER PLACEHOLDERS (highest priority). [[N1]], [[N2]] ... stand for redacted numbers. Copy each token character for character, exactly once, and never invent, merge, drop, or reorder them.'
        }
        return (@($billionRules + @(
            # k yen / k units は billion へ畳まない。数値の点検が単位の字面ごと
            # 突き合わせるため、「¥1,234 thousand」と書き替えると原文の
            # 「1,234 k yen」と一致せず numeric-integrity で落ちる（2026-08-12 実測）。
            # 元々 Convert-YakuNumericUnits も千単位は換算していない。
            '- Amount units: write yen amounts as published disclosure does: a yen sign, the figure, then billion. SOURCE already carries the rescaled unit. Decision table: [[N1]] billion yen -> ¥[[N1]] billion / [[N1]] k yen -> [[N1]] k yen / [[N1]] k units -> [[N1]] k units. Never write oku.'
            '- The caller rescales the figure itself; you only choose the unit word and the yen sign. Keep the placeholder unchanged.'
            '- Negative amounts: do NOT use parentheses in running text, and never keep the source marks (▲, △). Express the direction in words: "a decrease of ¥[[N1]] billion", "down ¥[[N1]] billion". Parentheses around figures belong to tables, not sentences.'
            '- Percentages keep %. A negative percentage is written in words too: "a decrease of [[N1]]%".'
            '- Arrow (→) between two numbers: reproduce ONLY when SOURCE writes A→B; never create one.'
        )) -join $nl)
    }
    $placeholderRules = @()
    if ([string]$InputText -match '\[\[N\d+\]\]') {
        $placeholderRules = @(
            '- NUMBER PLACEHOLDERS (highest priority). [[N1]], [[N2]] ... stand for redacted numbers. Copy each token character-for-character. Never translate, renumber, reorder, merge, split, or drop one; never invent one; never replace one with a digit or a word (one, several, approximately, a few). Every token in SOURCE appears the same number of times in each output section. Signs, units, and % stay OUTSIDE the token. A number written WITHOUT a placeholder is not redacted: copy it verbatim as a number.'
            '- Placeholder decision table, SOURCE -> OUTPUT: [[N1]] oku -> [[N1]] oku / +[[N1]] oku -> +[[N1]] oku / ▲[[N1]] oku -> ([[N1]]) oku / △[[N1]]% -> ([[N1]])% / [[N1]] k units -> [[N1]] k units / [[N1]] k yen -> [[N1]] k yen / [[N1]]→[[N2]] -> [[N1]]→[[N2]].'
        )
    }
    return (@($placeholderRules + @(
        '- Positive/additive amounts marked +, ＋, or プラス keep +N.'
        '- ▲, negative minus signs, or マイナス: put parentheses around the numeric token only; keep units and % outside. Valid: (72) k units, (xxx) oku, (3) %.'
        '- Numeric tokens already in English (oku, k units, k yen): keep the number and unit verbatim; never rescale, re-convert, add yen after oku, or restore Japanese units. Signs and % follow the existing rules. Never million, billion, trillion, bn, or tn.'
        '- Arrow (→) between two numbers: reproduce ONLY when SOURCE writes A→B; never create one. No tilde or greater-than/less-than signs; use words. Keep YoY, QoQ, CAGR, 3Q, Jan. to Dec.'
    )) -join $nl)
}

function Get-YakuBriefConditionalSections {
    <#
      電文体の雛形のうち、原文に手掛かりが無ければ出さない節を返す。

      なぜ「消す」ではなく「条件で出す」なのか:

        規則を1節ずつ外して同じ原文を実機へ投げ、出力が変わるかを測った
        （scratchpad/Ablate-Brief.ps1、5事例）。結果は次のとおり:

          EXAMPLES                946字  5/5 で出力が変わる
          WORDING                 738字  2/5
          ABBREVIATIONS         1,684字  1/5
          B1-B7                 1,765字  0/5
          WHAT YOU ARE WRITING    802字  0/5

        いちばん小さい節が全部を担い、大きい2節は測れる効果が無かった。
        しかし 5事例で 0/5 なのは「効かない」証拠ではなく、
        「その5事例では引き金を引かなかった」だけである。
        引用の規則は引用の原文でしか効かず、月名は月が出る原文でしか効かない。

        したがって規則そのものは残し、**引き金が原文に無いときだけ出さない**。
        Get-YakuNumericRulesSection が数値の規則で先に採っている形と同じ。
        素の一文なら 1,500字強が落ちるが、失われる規則は1つも無い。

      差し込み口は、直前の行の末尾に置いてある。
      値は自分の改行を先頭に持つ。空のときに空行が残らないようにするため。
    #>
    param([AllowNull()][string]$InputText)
    $t = [string]$InputText
    $nl = [Environment]::NewLine
    $v = @{
        brief_angle_rule     = ''
        brief_quotation_rule = ''
        brief_months_rule    = ''
        brief_signed_rule    = ''
        brief_extra_examples = ''
    }
    $examples = @()

    # 全角山括弧。原文に山括弧の見出しが無ければ、往復の作法を説く必要が無い。
    if ($t -match '[<>＜＞]') {
        $v.brief_angle_rule = $nl + '- Never output half-width < or >. Use FULL-WIDTH ＜ and ＞ for angle-bracket headings; the caller restores them.'
    }

    # 引用。話法の規則は、引用符か発言の動詞がある原文でしか出番が無い。
    # 実測では、引用の事例を外すと電文体そのものが崩れた（文に戻った）ので、
    # 引き金を引いたときは規則と事例の両方を出す。
    if ($t -match '[「」『』"“”]|述べ|語っ|表明|コメント|発言|と説明|と話|インタビュー') {
        $v.brief_quotation_rule = $nl + (@(
            'B6. Quotations. For speech, attributed quotes and quote-like headlines you must pick one of exactly two forms:'
            '    (a) Keep the quotation marks. Then the quoted words are translated faithfully and are NOT compressed: no dropped articles, no abbreviations, no noun-stacking inside the marks.'
            '    (b) Remove the quotation marks and use indirect speech, keeping who said it and the reporting verb. Then compress freely.'
            '    Quotation marks around compressed wording are wrong, because they claim the person said those words. Prefer (b) in this register.'
            '    Short quoted terms, product names, programmes and places with no speech reading are not speech: keep their marks and follow B1-B5.'
        ) -join $nl)
        $examples += (@(
            '社長は生産現場の連携が不可欠であり、フィジカルAIを推進していくと述べた。'
            '-> Mfg.-site collaboration essential; he intends to advance physical AI.'
            '   NOT "...; intends to advance." (the subject must stay recoverable)'
        ) -join $nl)
    }

    # 月名。数値は差し替え済みなので「1月」は「[[N1]]月」になる。月の字だけを見る。
    if ($t -match '月') {
        $v.brief_months_rule = $nl + '- Months: Jan. Feb. Mar. Apr. Jun. Jul. Aug. Sep. Oct. Nov. Dec.; May stays May. Abbreviate only a calendar month. A person, company, product or place name keeps the full word (April Smith, June Tanaka, March & Co.). If unsure, leave it spelled out.'
    }

    # 符号付きの内訳。増減要因の表記が無ければ出さない。
    if ($t -match '内訳|増減要因|要因は|[▲△]|[＋+]\s*[0-9０-９\[]|[(（][0-9０-９]') {
        $v.brief_signed_rule = $nl + '- Signed breakdowns: term + one space + source sign and figure + unit. No "impact", no "of", no colon, no up/down. Only a sentence-level period change may read "subject up/down X YoY". If unsure, keep +X / (X).'
        $examples += (@(
            '第4四半期の変動利益は前年同期比xxx億円の減益。内訳は数量(xxx)、関税(xxx)、構成+xxx。'
            '-> Q4 VP down xxx oku YoY. Breakdown: vol. (xxx); tariffs (xxx); mix +xxx.'
        ) -join $nl)
    }

    if ($examples.Count -gt 0) { $v.brief_extra_examples = $nl + $nl + (@($examples) -join ($nl + $nl)) }
    return $v
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
        [AllowNull()][string]$RequestId,
        # V91.61 段階3: 参考資料コーパスから引いた文例。
        # 作るのは CorpusReference.ps1 で、ここは受け取って差し込むだけ。
        [AllowNull()][string]$CorpusSection,
        # 通常翻訳は full。「短く」は専用処理から brief を指定する。
        [ValidateSet('full','brief')][string]$Mode = 'full'
    )
    if ([string]::IsNullOrWhiteSpace($RequestId)) { $RequestId = [guid]::NewGuid().ToString('N') }
    $direction = if ([string]::IsNullOrWhiteSpace($DirectionOverride)) { Get-YakuDirection -Text $InputText } else { $DirectionOverride }
    $templateName =
        if ($direction -ne 'to_en') { 'text_translate_to_jp.txt' }
        elseif ($Mode -eq 'brief') { 'text_translate_brief_to_en.txt' }
        else { 'text_translate_full_to_en.txt' }
    $template = Get-YakuPromptTemplate -Root $Root -Name $templateName
    $vars = @{
        input_text = $InputText.Trim()
        style_reference_section = Get-YakuStyleReferenceSection -StyleReference $StyleReference
        # to_jp のテンプレートには枠が無い。渡ってきても差し込まれないが、
        # 呼び出し側でも方向を見て空にしている（Test-YakuCorpusReferenceApplicable）。
        corpus_section = [string]$CorpusSection
        # 金額の書き方は依頼の種類（そのまま／短く）では変わらない。設定で決まる。
        # 訳の種類と書き方を混ぜていたので、名前が何を指すのか分からなくなっていた
        # （利用者の指摘 2026-08-08「社内の書き方もおかしい」）。
        numeric_rules = Get-YakuNumericRulesSection -InputText $InputText -Direction $direction -Notation (Get-YakuAmountNotation -Settings $Settings)
        request_id = $RequestId
    }
    # 電文体の雛形だけが持つ差し込み口。原文に引き金が無い節は出さない。
    # 他の雛形には枠が無いので、渡しても差し込まれない。
    if ([string]$Mode -eq 'brief') {
        foreach ($kv in (Get-YakuBriefConditionalSections -InputText $InputText).GetEnumerator()) {
            $vars[$kv.Key] = [string]$kv.Value
        }
    }
    return [pscustomobject]@{
        Direction = $direction
        Prompt = Expand-YakuTemplate -Template $template -Variables $vars
    }
}

function New-YakuRevisePrompt {
    <#
      修正の依頼を組み立てる。

      なぜ規則集を送らないのか:

        利用者の使い方は「一文を訳す → 目で見る → 何度か直す → 確定」である
        （利用者の説明 2026-08-06）。この「直す」を、規則集ごと投げ直す形で
        作ってはいけない。理由は2つある。

        1つ目。現訳はすでに規則を通って出てきたものである。同じ規則を
        もう一度送れば、モデルは指示ではなく規則へ引っ張られ、
        利用者が触っていない箇所まで書き換わる。直したいのは1点だけである。

        2つ目。電文体の規則は圧縮後でも 5,500字あり、利用者の指示は
        たいてい20字である。長さの比が 250:1 では指示が埋もれる。

        したがって送るのは 原文・現訳・指示 の3つと、動かせない機構だけ
        （ラベルの契約と、伏せた数値の扱い）。文体は一行の注記で示す。

      原文を送るのは、指示が事実を落とす形になっていないかを確かめさせるため。
      現訳だけでは、モデルは指示が原文に反しているかを知りようがない。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        [Parameter(Mandatory=$true)][string]$CurrentText,
        [Parameter(Mandatory=$true)][string]$Instruction,
        [ValidateSet('to_en','to_jp')][string]$Direction = 'to_en',
        # 現訳がどちらの成果物か。求めるラベルと文体の注記が決まる。
        [ValidateSet('full','brief')][string]$Style = 'full',
        [AllowNull()][string]$RequestId
    )
    if ([string]::IsNullOrWhiteSpace($RequestId)) { $RequestId = [guid]::NewGuid().ToString('N') }
    $label =
        if ($Direction -ne 'to_en') { 'JAPANESE_TEXT' }
        elseif ($Style -eq 'brief') { 'BRIEF_TEXT' }
        else { 'FULL_TEXT' }
    # 文体は一行で示す。ここに規則を書き足すと、規則集を送らない意味が無くなる。
    $styleNote =
        if ($Direction -ne 'to_en') { 'CURRENT is a Japanese translation. Keep its register, terminology and level of detail.' }
        elseif ($Style -eq 'brief') { 'CURRENT is an English telegraphic line, in the register used inside a Japanese company''s own disclosure and management materials. Keep that register: grammar words go, facts stay. Do not expand it into prose.' }
        else { 'CURRENT is a complete English translation. Keep it complete: no compression and no abbreviations that SOURCE does not itself use.' }
    # 伏せた数値の規則だけは残す。トークンが原文と現訳の両方に居るため、
    # 扱いを示さないと書き換えられて実値へ戻せなくなる。
    $numeric = Get-YakuNumericRulesSection -InputText ([string]$InputText + "`n" + [string]$CurrentText) -Direction $Direction
    $template = Get-YakuPromptTemplate -Root $Root -Name 'text_revise.txt'
    $vars = @{
        request_id       = $RequestId
        output_label     = $label
        style_note       = $styleNote
        numeric_rules    = $numeric
        input_text       = $InputText.Trim()
        current_text     = $CurrentText.Trim()
        instruction_text = $Instruction.Trim()
    }
    return [pscustomobject]@{
        Direction = $Direction
        Label     = $label
        Prompt    = Expand-YakuTemplate -Template $template -Variables $vars
    }
}

function New-YakuShortenPrompt {
    <#
      できあがった訳文を、短くするためだけに依頼する。

      なぜ訳し直しではなく派生なのか（要件整理 §5-A、実測付き）:

        原文→FULL と 原文→BRIEF を並べて頼むと、圧縮が「日本語を読みながら
        縮める」作業になる。実測で圧縮率が 0.55（用語集がカバーする語彙）と
        0.75（しない語彙）に割れた。同じ文長・同じ文体でこれだけ差が出るのは、
        圧縮を日本語照合でやっているからである。

        できた英文から縮めれば、圧縮は英語→英語の操作になり、語彙依存が
        原理的に消える。用語も原文の解釈も現訳から引き継ぐので、
        「さっき訳した文と今の文が食い違う」も起きない。

      何を許すか:

        長さだけである。単位表記も負数の書き方も渡さない。単位換算は桁の
        換算を伴うのでマスクの前にアプリが済ませており、送信後の英文には
        [[N1]] しか無い。Copilot に換算はできない。負数の書き方は設定
        amount_notation が決める規則で、最初の翻訳で既に当たっている。
        機械で決まることをモデルへ渡すのは、往復が高くつく以上は悪い取引である
        （独立評価 2026-08-08）。

        許す軸を1本に絞ると、指示は守られやすくなる。「A も B も C も
        変えてよい」は「A だけ」よりはっきり守られない。

      略語は当てない。返ってきた英文へアプリが後から当てる。先に略語入りの
      英文を渡すと、モデルはそれを知らない語として扱い、書き換えの許可を
      与えている場でこそ綴りへ戻したり別の語に読み替えたりする。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$InputText,
        # マスク後の現訳。実値の入った訳文を渡してはならない。
        [Parameter(Mandatory=$true)][string]$CurrentText,
        # 金額の書き方。渡さないと既定（oku）の規則を送ることになり、
        # 別の表記で作った現訳に対して「その表記を使うな」と言う形になる
        # （2026-08-08 の指摘。設定を無視していた）。
        [AllowNull()]$Settings,
        [AllowNull()][string]$RequestId
    )
    if ([string]::IsNullOrWhiteSpace($RequestId)) { $RequestId = [guid]::NewGuid().ToString('N') }
    # 伏せた数値の扱いだけは残す。トークンが原文と現訳の両方に居るので、
    # 扱いを示さないと書き換えられて実値へ戻せなくなる。
    $numeric = Get-YakuNumericRulesSection -InputText ([string]$InputText + "`n" + [string]$CurrentText) -Direction 'to_en' -Notation (Get-YakuAmountNotation -Settings $Settings)
    # 圧縮の手口だけを渡す。文体の規則集を丸ごと再掲しない。
    # 既に良い訳が入力なのに、それを産んだ規則を全部見せると
    # 「一から作り直す」を誘発する（独立評価 2026-08-08）。
    $briefRules = ''
    try { $briefRules = Get-YakuPromptTemplate -Root $Root -Name 'style_brief_rules.txt' } catch { $briefRules = '' }
    $template = Get-YakuPromptTemplate -Root $Root -Name 'text_shorten_to_en.txt'
    $vars = @{
        request_id    = $RequestId
        numeric_rules = $numeric
        brief_rules   = [string]$briefRules
        input_text    = $InputText.Trim()
        current_text  = $CurrentText.Trim()
    }
    return [pscustomobject]@{
        Direction = 'to_en'
        Label     = 'BRIEF_TEXT'
        RequestId = $RequestId
        Prompt    = Expand-YakuTemplate -Template $template -Variables $vars
    }
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
