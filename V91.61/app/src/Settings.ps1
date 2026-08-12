function ConvertTo-YakuHashtable {
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $value = $InputObject[$key]
            if ($value -is [System.Management.Automation.PSCustomObject] -or
                $value -is [System.Collections.IDictionary]) {
                $hash[$key] = ConvertTo-YakuHashtable $value
            } else {
                $hash[$key] = $value
            }
        }
        return $hash
    }
    $hash = [ordered]@{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Value -is [System.Management.Automation.PSCustomObject] -or
            $prop.Value -is [System.Collections.IDictionary]) {
            $hash[$prop.Name] = ConvertTo-YakuHashtable $prop.Value
        } else {
            $hash[$prop.Name] = $prop.Value
        }
    }
    return $hash
}

function ConvertTo-YakuSettingsSafeInt {
    param([AllowNull()][object]$Value, [int]$Default)
    try {
        if (Get-Command ConvertTo-YakuSafeInt -ErrorAction SilentlyContinue) {
            return (ConvertTo-YakuSafeInt -Value $Value -Default $Default)
        }
    } catch {}
    try {
        if ($null -eq $Value) { return $Default }
        if ($Value -is [System.Array]) { $Value = @($Value)[0] }
        $s = if ($Value -is [string]) { $Value } else { [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
        if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
        $i = 0
        if ([int]::TryParse($s.Trim(), [ref]$i)) { return $i }
    } catch {}
    return $Default
}

function ConvertTo-YakuBoolSetting {
    param([AllowNull()]$Value, [bool]$Default = $false)
    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $Default }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('true','1','yes','on','enabled')) { return $true }
    if ($s -in @('false','0','no','off','disabled','')) { return $false }
    # Privacy-sensitive and other unknown values fail closed.
    return $Default
}

function Get-YakuDiagnosticsLevel {
    param([AllowNull()]$Settings = $null)
    try {
        if ($null -ne $Settings) {
            $source = ConvertTo-YakuHashtable $Settings
            if ($source.Contains('diagnostics_level')) {
                $candidate = ([string]$source['diagnostics_level']).Trim().ToLowerInvariant()
                if ($candidate -in @('minimal','standard','full')) { return $candidate }
            }
            if ($source.Contains('full_text_diagnostics_enabled') -and
                (ConvertTo-YakuBoolSetting -Value $source['full_text_diagnostics_enabled'] -Default $false)) {
                return 'full'
            }
            return 'standard'
        }
        $cached = ''
        try { $cached = ([string]$script:YakuDiagnosticsLevel).Trim().ToLowerInvariant() } catch { $cached = '' }
        if ($cached -in @('minimal','standard','full')) { return $cached }
        try { if ($script:YakuFullTextDiagnosticsEnabled -eq $true) { return 'full' } } catch {}
    } catch {}
    return 'standard'
}

function Get-YakuApprovedCopilotUrls {
    return @('https://m365.cloud.microsoft/chat/')
}

function Get-YakuSettingsSchema {
    return [ordered]@{
        max_chars_per_batch               = @{ Type='int';  Default=3000; Min=0; Max=20000 }
        max_chars_per_batch_file          = @{ Type='int';  Default=3000; Min=300; Max=20000 }
        file_upload_max_mb                = @{ Type='int';  Default=50; Min=1; Max=200 }
        csv_translate_header              = @{ Type='bool'; Default=$true }
        translate_shapes                  = @{ Type='bool'; Default=$true }
        translate_charts                  = @{ Type='bool'; Default=$true }
        output_font_name                  = @{ Type='string'; Default='Arial'; MaxLength=80 }
        translation_cache_enabled         = @{ Type='bool'; Default=$true }
        request_timeout                   = @{ Type='int';  Default=240; Min=30; Max=1800 }
        extract_timeout_seconds           = @{ Type='int';  Default=300; Min=60; Max=3600 }
        worker_heartbeat_timeout_seconds  = @{ Type='int';  Default=180; Min=30; Max=3600 }
        max_retries                       = @{ Type='int';  Default=3; Min=0; Max=10 }
        # 金額の書き方。訳の種類ではなく書き方なので、毎回選ばせず設定で持つ。
        # 外部公表は billion、社内資料の一部が oku（利用者 2026-08-08）。
        #
        # billion は 2026-08-08 から 2026-08-12 まで塞いでいた。単位名だけ替えると
        # 122億円 が ¥122 billion になり、10倍の誤りになるためである（実行して確認）。
        # 2026-08-12 に Convert-YakuNumericUnits へ 億÷10 の割り算を入れて開けた。
        # 換算はこのパソコンの中で済ませ、Copilot には伏せた数値しか渡さない。
        #
        # 書き方は作業ごとに固定する（CatProject の amount_notation）。数値の点検は
        # 換算後の原文と訳文を突き合わせるので、途中で替えると既存の行が落ちる。
        amount_notation                   = @{ Type='enum'; Default='oku'; Values=@('oku','billion') }
        glossary_prompt_limit             = @{ Type='int';  Default=48; Min=1; Max=200 }
        browser_display_mode              = @{ Type='enum'; Default='foreground'; Values=@('foreground') }
        edge_window_size                  = @{ Type='string'; Default='1280,900'; MaxLength=24 }
        edge_debug_port                   = @{ Type='int';  Default=9433; Min=1024; Max=65535 }
        copilot_url                       = @{ Type='enum'; Default='https://m365.cloud.microsoft/chat/'; Values=(Get-YakuApprovedCopilotUrls) }
        copilot_model                     = @{ Type='string'; Default='GPT 5.6 Think deeper,Opus,Think Deeper'; MaxLength=300 }
        copilot_cdp_socket_cache_enabled  = @{ Type='bool'; Default=$true }
        copilotFirstActivityTimeoutMs     = @{ Type='int';  Default=10000; Min=5000; Max=120000 }
        copilotAnswerRatioText            = @{ Type='double'; Default=4.0; Min=0.1; Max=20.0 }
        copilotAnswerBaseText             = @{ Type='double'; Default=150.0; Min=0.0; Max=10000.0 }
        copilotAnswerRatioFile            = @{ Type='double'; Default=1.7; Min=0.1; Max=10.0 }
        copilotAnswerBaseFile             = @{ Type='double'; Default=0.0; Min=0.0; Max=10000.0 }
        copilotPromptCharLimit            = @{ Type='int'; Default=0; Min=0; Max=200000 }
        diagnostics_level                = @{ Type='enum'; Default='standard'; Values=@('minimal','standard','full') }
        full_text_diagnostics_enabled     = @{ Type='bool'; Default=$false }
        diagnostic_retention_days         = @{ Type='int';  Default=1; Min=1; Max=7 }
        history_retention_days            = @{ Type='int';  Default=30; Min=1; Max=90 }
        log_retention_days                = @{ Type='int';  Default=30; Min=1; Max=90 }
        allow_direct_local_path           = @{ Type='bool'; Default=$true }
        allow_network_paths               = @{ Type='bool'; Default=$false }
    }
}

function ConvertTo-YakuSettingValue {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowNull()]$Value,
        [Parameter(Mandatory=$true)]$Rule,
        [switch]$Strict
    )
    $type = [string]$Rule.Type
    if ($type -eq 'bool') {
        if ($Value -is [bool]) { return [bool]$Value }
        $s = ([string]$Value).Trim().ToLowerInvariant()
        if ($s -in @('true','on','1','yes','enabled')) { return $true }
        if ($s -in @('false','off','0','no','disabled','')) { return $false }
        if ($Strict) { throw "設定値 $Name は true/false で指定してください。" }
        return [bool]$Rule.Default
    }
    if ($type -eq 'int') {
        $parsed = 0
        if (-not [int]::TryParse(([string]$Value).Trim(), [ref]$parsed) -or $parsed -lt [int]$Rule.Min -or $parsed -gt [int]$Rule.Max) {
            if ($Strict) { throw "設定値 $Name は $($Rule.Min)～$($Rule.Max) の整数で指定してください。" }
            return [int]$Rule.Default
        }
        return [int]$parsed
    }
    if ($type -eq 'double') {
        $parsed = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        if (-not [double]::TryParse(([string]$Value).Trim(), $styles, $culture, [ref]$parsed) -or $parsed -lt [double]$Rule.Min -or $parsed -gt [double]$Rule.Max) {
            if ($Strict) { throw "設定値 $Name は $($Rule.Min)～$($Rule.Max) の数値で指定してください。" }
            return [double]$Rule.Default
        }
        return [double]$parsed
    }
    if ($type -eq 'enum') {
        $s = [string]$Value
        if (@($Rule.Values) -notcontains $s) {
            if ($Strict) { throw "設定値 $Name は承認済みの値から選択してください。" }
            return $Rule.Default
        }
        return $s
    }
    $text = [string]$Value
    if ($Rule.ContainsKey('MaxLength') -and $text.Length -gt [int]$Rule.MaxLength) {
        if ($Strict) { throw "設定値 $Name が長すぎます。" }
        return [string]$Rule.Default
    }
    return $text
}

function Test-YakuSettingsData {
    param(
        # PSCustomObject または IDictionary (Hashtable / OrderedDictionary) を受け入れる。
        [AllowNull()]$Data,
        [switch]$Strict
    )
    $schema = Get-YakuSettingsSchema
    $source = ConvertTo-YakuHashtable $Data
    $validated = [ordered]@{}
    foreach ($name in $schema.Keys) {
        $rule = $schema[$name]
        $value = if ($source.Contains($name)) { $source[$name] } else { $rule.Default }
        $validated[$name] = ConvertTo-YakuSettingValue -Name $name -Value $value -Rule $rule -Strict:$Strict
    }
    return [pscustomobject]$validated
}

function Write-YakuSettingsAtomic {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Data)
    if (Get-Command Write-YakuJsonAtomic -ErrorAction SilentlyContinue) {
        Write-YakuJsonAtomic -Path $Path -Value $Data -Depth 10
        return
    }
    $dir = Split-Path -Parent $Path
    $temp = Join-Path $dir ('.user_settings.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Resolve-YakuUserSettingsPath {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Get-YakuUserSettingsPath
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $legacy = Get-YakuLegacyUserSettingsPath -Root $Root
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        # アプリフォルダ内の旧設定を一度だけ引き継ぐ。旧ファイルは削除しない。
        # 共有フォルダが読取専用の場合と、旧版を使い続ける利用者がいる場合の双方を壊さないため。
        try {
            Copy-Item -LiteralPath $legacy -Destination $path -Force
            try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog "Legacy user settings migrated to the user profile. to=$path" 'INFO' } } catch {}
        } catch {
            try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog 'SETTINGS_MIGRATION_FAILED: 旧設定を引き継げませんでした。既定値で継続します。' 'WARN' } } catch {}
        }
    }
    return $path
}

function Read-YakuSettings {
    param([Parameter(Mandatory=$true)][string]$Root)
    $templatePath = Join-Path $Root 'config\settings.template.json'
    $template = $null
    try { $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $template = $null }
    $merged = ConvertTo-YakuHashtable (Test-YakuSettingsData -Data $template)

    $userPath = Resolve-YakuUserSettingsPath -Root $Root
    if (Test-Path -LiteralPath $userPath -PathType Leaf) {
        try {
            $user = ConvertTo-YakuHashtable (Get-Content -LiteralPath $userPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            $schema = Get-YakuSettingsSchema
            $invalidKeys = New-Object System.Collections.Generic.List[string]
            foreach ($key in $user.Keys) {
                if (-not $merged.Contains($key)) { continue }
                try { $merged[$key] = ConvertTo-YakuSettingValue -Name $key -Value $user[$key] -Rule $schema[$key] -Strict }
                catch { $invalidKeys.Add([string]$key) | Out-Null }
            }
            $legacyBatchMigrated = $false
            $legacyCdpPortMigrated = $false
            $legacyDiagnosticsMigrated = $false
            # Backward compatibility: an existing user file with only the old boolean
            # must retain full diagnostics even though the template now has standard.
            if (-not $user.Contains('diagnostics_level') -and $user.Contains('full_text_diagnostics_enabled') -and
                (ConvertTo-YakuBoolSetting -Value $user['full_text_diagnostics_enabled'] -Default $false)) {
                $merged['diagnostics_level'] = 'full'
                $legacyDiagnosticsMigrated = $true
            }
            if ($user.Contains('edge_debug_port') -and [int]$merged['edge_debug_port'] -eq 9333) {
                $merged['edge_debug_port'] = 9433
                $legacyCdpPortMigrated = $true
            }
            if ($user.Contains('max_chars_per_batch') -and [int]$merged['max_chars_per_batch'] -eq 1000) {
                $merged['max_chars_per_batch'] = 3000
                $legacyBatchMigrated = $true
            }
            if ($invalidKeys.Count -gt 0 -or $legacyBatchMigrated -or $legacyCdpPortMigrated -or $legacyDiagnosticsMigrated) {
                if ($invalidKeys.Count -gt 0) {
                    $backup = $userPath + '.invalid-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.bak'
                    Copy-Item -LiteralPath $userPath -Destination $backup -Force
                }
                Write-YakuSettingsAtomic -Path $userPath -Data $merged
                if ($invalidKeys.Count -gt 0) {
                    try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog ("Invalid settings were reset. keys=" + (($invalidKeys.ToArray()) -join ',')) 'WARN' } } catch {}
                }
                if ($legacyBatchMigrated) {
                    try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog 'Legacy text batch default migrated. max_chars_per_batch=1000 -> 3000' 'INFO' } } catch {}
                }
                if ($legacyCdpPortMigrated) {
                    try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog 'edge_debug_port migrated 9333 -> 9433 (conflict with yakulingom365copilot)' 'INFO' } } catch {}
                }
                if ($legacyDiagnosticsMigrated) {
                    try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog 'Legacy full-text diagnostics setting migrated. diagnosticsLevel=full' 'INFO' } } catch {}
                }
            }
        } catch {
            $backup = $userPath + '.invalid-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.bak'
            try { Move-Item -LiteralPath $userPath -Destination $backup -Force } catch {}
            try { if (Get-Command Write-YakuLog -ErrorAction SilentlyContinue) { Write-YakuLog 'Invalid settings file was backed up and defaults were restored. errorCode=SETTINGS_INVALID_JSON' 'WARN' } } catch {}
        }
    }
    return (Test-YakuSettingsData -Data $merged)
}

function Read-YakuUserSettingsStrict {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Get-YakuUserSettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'SETTINGS_SAVE_READBACK_FAILED: 保存後の設定ファイルが見つかりません。'
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw '設定ファイルが空です。' }
        $source = ConvertTo-YakuHashtable ($raw | ConvertFrom-Json -ErrorAction Stop)
        $schema = Get-YakuSettingsSchema
        foreach ($key in $schema.Keys) {
            if (-not $source.Contains($key)) { throw "設定項目 $key がありません。" }
        }
        return (Test-YakuSettingsData -Data $source -Strict)
    } catch {
        $detail = ([string]$_.Exception.Message) -replace '[\r\n\t]+', ' '
        throw "SETTINGS_SAVE_READBACK_FAILED: 保存後の設定ファイルを検証できません。$detail"
    }
}

function Save-YakuUserSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][hashtable]$Form
    )
    $schema = Get-YakuSettingsSchema
    $current = ConvertTo-YakuHashtable (Read-YakuSettings -Root $Root)
    foreach ($key in $schema.Keys) {
        if ($Form.ContainsKey($key)) {
            $current[$key] = ConvertTo-YakuSettingValue -Name $key -Value $Form[$key] -Rule $schema[$key] -Strict
        }
    }
    $data = ConvertTo-YakuHashtable (Test-YakuSettingsData -Data $current -Strict)
    $path = Get-YakuUserSettingsPath
    $null = Write-YakuSettingsAtomic -Path $path -Data $data
    try {
        if (Get-Command Clear-YakuTranslationCache -ErrorAction SilentlyContinue) { $null = Clear-YakuTranslationCache }
    } catch {}

    $verifiedItems = @(Read-YakuUserSettingsStrict -Root $Root)
    if ($verifiedItems.Count -ne 1 -or $null -eq $verifiedItems[0]) {
        throw 'SETTINGS_SAVE_RESULT_INVALID: 保存後の設定を単一の設定オブジェクトとして読み込めませんでした。'
    }
    $verified = $verifiedItems[0]
    $verifiedHash = ConvertTo-YakuHashtable $verified
    $safePreview = {
        param([string]$Key, $Value, $Rule)
        $type = [string]$Rule.Type
        if ($type -in @('bool','int')) { return [string]$Value }
        # URLs, model names, and future free-form settings may contain internal
        # information. Only the explicitly harmless display settings are logged.
        if ($Key -notin @('output_font_name','browser_display_mode','edge_window_size')) { return '<masked>' }
        $text = ([string]$Value).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
        if ($text.Length -gt 40) { $text = $text.Substring(0, 40) + '...' }
        return $text
    }
    foreach ($key in $schema.Keys) {
        if (-not $Form.ContainsKey($key)) { continue }
        if (-not $verifiedHash.Contains($key)) {
            $expected = ConvertTo-YakuSettingValue -Name $key -Value $Form[$key] -Rule $schema[$key] -Strict
            $expectedPreview = & $safePreview $key $expected $schema[$key]
            throw "SETTINGS_SAVE_VERIFY_FAILED: 保存後の設定に $key がありません。expected=$expectedPreview actual=<missing>"
        }
        $rule = $schema[$key]
        $expected = ConvertTo-YakuSettingValue -Name $key -Value $Form[$key] -Rule $rule -Strict
        $actual = ConvertTo-YakuSettingValue -Name $key -Value $verifiedHash[$key] -Rule $rule -Strict
        $isMatch = if ([string]$rule.Type -in @('string','enum')) {
            [string]::Equals([string]$expected, [string]$actual, [System.StringComparison]::Ordinal)
        } else {
            $expected -eq $actual
        }
        if (-not $isMatch) {
            $expectedPreview = & $safePreview $key $expected $rule
            $actualPreview = & $safePreview $key $actual $rule
            throw "SETTINGS_SAVE_VERIFY_FAILED: 設定 $key の保存後の値が送信値と一致しません。expected=$expectedPreview actual=$actualPreview"
        }
    }
    return $verified
}
