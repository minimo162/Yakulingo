function Get-YakuDesktopPreferencesPath {
    return (Join-Path (Get-YakuSubDir 'config') 'desktop_preferences.json')
}

function Get-YakuDesktopShellPath {
    # Packaged builds place the signed shell here. The environment override is
    # used only by isolated regression tests and local packaging verification.
    $override = [string]$env:YAKULINGO_DESKTOP_EXE
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        try { return [IO.Path]::GetFullPath($override) } catch { return '' }
    }
    foreach ($relative in @('desktop\YakuLingo.exe','desktop\bin\YakuLingo.exe')) {
        $candidate = Join-Path (Get-YakuRoot) $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    return ''
}

function Get-YakuWindowsKnownFolderPath {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Startup','Desktop','Programs')][string]$Name
    )
    $specialName = if ($Name -eq 'Desktop') { 'Desktop' } else { $Name }
    $path = ''
    try { $path = [string][Environment]::GetFolderPath($specialName) } catch {}
    if (-not [string]::IsNullOrWhiteSpace($path)) { return [Environment]::ExpandEnvironmentVariables($path) }

    $valueName = if ($Name -eq 'Desktop') { 'Desktop' } elseif ($Name -eq 'Startup') { 'Startup' } else { 'Programs' }
    try {
        $raw = [string](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name $valueName -ErrorAction Stop)
        if (-not [string]::IsNullOrWhiteSpace($raw)) { return [Environment]::ExpandEnvironmentVariables($raw) }
    } catch {}

    $profile = [string]$env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profile)) { throw ('DESKTOP_KNOWN_FOLDER_MISSING: ' + $Name) }
    if ($Name -eq 'Desktop') { return (Join-Path $profile 'Desktop') }
    $startMenu = Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu'
    if ($Name -eq 'Startup') { return (Join-Path $startMenu 'Programs\Startup') }
    return (Join-Path $startMenu 'Programs')
}

function Get-YakuDesktopShortcutLocations {
    $testRoot = [string]$env:YAKULINGO_DESKTOP_LINK_ROOT
    if (-not [string]::IsNullOrWhiteSpace($testRoot)) {
        $base = [IO.Path]::GetFullPath($testRoot)
        return [ordered]@{
            startup = Join-Path (Join-Path $base 'Startup') 'YakuLingo.lnk'
            desktop = Join-Path (Join-Path $base 'Desktop') 'YakuLingo.lnk'
            start_menu = Join-Path (Join-Path $base 'Programs') 'YakuLingo.lnk'
        }
    }
    return [ordered]@{
        startup = Join-Path (Get-YakuWindowsKnownFolderPath -Name Startup) 'YakuLingo.lnk'
        desktop = Join-Path (Get-YakuWindowsKnownFolderPath -Name Desktop) 'YakuLingo.lnk'
        start_menu = Join-Path (Get-YakuWindowsKnownFolderPath -Name Programs) 'YakuLingo.lnk'
    }
}

function Get-YakuShortcutTarget {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return [pscustomobject]@{ TargetPath=[string]$shortcut.TargetPath; Arguments=[string]$shortcut.Arguments; Description=[string]$shortcut.Description }
    } catch { return $null }
    finally { if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch {} } }
}

function Test-YakuOwnedShortcut {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$TargetPath
    )
    $link = Get-YakuShortcutTarget -Path $Path
    if ($null -eq $link) { return $false }
    try {
        $actual = [IO.Path]::GetFullPath([string]$link.TargetPath)
        if ([string]::Equals($actual, [IO.Path]::GetFullPath($TargetPath), [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if (-not [string]::Equals([IO.Path]::GetFileName($actual), 'YakuLingo起動.cmd', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $description = [string]$link.Description
        if (-not ([string]::Equals($description, 'YakuLingo', [StringComparison]::Ordinal) -or
            [string]::Equals($description, 'Start YakuLingo HTMX + PowerShell edition', [StringComparison]::Ordinal))) { return $false }
        $legacyRoot = Split-Path -Parent $actual
        return ((Test-Path -LiteralPath (Join-Path $legacyRoot 'bootstrap.ps1') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $legacyRoot 'current.txt') -PathType Leaf))
    } catch { return $false }
}

function Set-YakuDesktopShortcutFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [AllowEmptyString()][string]$Arguments = ''
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $temp = Join-Path $dir ('.YakuLingo-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($temp)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
        $shortcut.Description = 'YakuLingo'
        $shortcut.Save()
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch {} }
    }
}

function Get-YakuDesktopPreferences {
    $shellPath = Get-YakuDesktopShellPath
    $locations = Get-YakuDesktopShortcutLocations
    $available = -not [string]::IsNullOrWhiteSpace($shellPath)
    $saved = $null
    try { $saved = Read-YakuJsonFile -Path (Get-YakuDesktopPreferencesPath) } catch {}
    $tutorialCompleted = $false
    try { $tutorialCompleted = [bool]$saved.tutorial_completed } catch {}
    $desktopEnabled = ($available -and (Test-YakuOwnedShortcut -Path ([string]$locations.desktop) -TargetPath $shellPath))
    return [pscustomobject]@{
        available = $available
        startup_enabled = ($available -and (Test-YakuOwnedShortcut -Path ([string]$locations.startup) -TargetPath $shellPath))
        desktop_shortcut = $desktopEnabled
        desktop_shortcut_enabled = $desktopEnabled
        start_menu_shortcut = ($available -and (Test-YakuOwnedShortcut -Path ([string]$locations.start_menu) -TargetPath $shellPath))
        tutorial_completed = $tutorialCompleted
        message = if ($available) { '設定を読み込みました。' } else { 'デスクトップ版を準備できていません。アプリを一式更新してください。' }
        warnings = @()
    }
}

function Set-YakuDesktopPreferences {
    param(
        [Parameter(Mandatory=$true)][bool]$StartupEnabled,
        [Parameter(Mandatory=$true)][bool]$DesktopShortcut
    )
    $shellPath = Get-YakuDesktopShellPath
    if ([string]::IsNullOrWhiteSpace($shellPath) -or -not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
        throw 'DESKTOP_SHELL_MISSING: デスクトップ版を準備できていません。アプリを一式更新してください。'
    }
    $locations = Get-YakuDesktopShortcutLocations
    $desired = [ordered]@{
        startup = [bool]$StartupEnabled
        desktop = [bool]$DesktopShortcut
        start_menu = $true
    }
    $arguments = @{ startup='--background'; desktop=''; start_menu='' }
    $snapshots = @{}
    foreach ($name in $locations.Keys) {
        $path = [string]$locations[$name]
        $snapshots[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::ReadAllBytes($path) } else { $null }
    }
    try {
        foreach ($name in $locations.Keys) {
            $path = [string]$locations[$name]
            if ([bool]$desired[$name]) {
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-YakuOwnedShortcut -Path $path -TargetPath $shellPath)) {
                    throw ('DESKTOP_SHORTCUT_CONFLICT: 同名の別ショートカットがあるため変更できません: ' + $path)
                }
                Set-YakuDesktopShortcutFile -Path $path -TargetPath $shellPath -Arguments ([string]$arguments[$name])
            } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                if (-not (Test-YakuOwnedShortcut -Path $path -TargetPath $shellPath)) {
                    throw ('DESKTOP_SHORTCUT_CONFLICT: 同名の別ショートカットがあるため削除できません: ' + $path)
                }
                Remove-Item -LiteralPath $path -Force
            }
        }
        $state = [ordered]@{
            tutorial_completed = $true
            startup_enabled = [bool]$StartupEnabled
            desktop_shortcut = [bool]$DesktopShortcut
            updated_at = (Get-Date).ToString('o')
        }
        Write-YakuTextAtomic -Path (Get-YakuDesktopPreferencesPath) -Text ($state | ConvertTo-Json -Compress)
    } catch {
        foreach ($path in $snapshots.Keys) {
            try {
                if ($null -eq $snapshots[$path]) {
                    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
                } else {
                    $dir = Split-Path -Parent $path
                    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    [IO.File]::WriteAllBytes($path, [byte[]]$snapshots[$path])
                }
            } catch {}
        }
        throw
    }
    $result = Get-YakuDesktopPreferences
    $result.message = '設定を保存しました。'
    return $result
}
