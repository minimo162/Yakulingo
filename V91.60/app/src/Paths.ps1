
function Get-YakuRoot {
    if ($script:YakuRoot) { return $script:YakuRoot }
    $src = Split-Path -Parent $MyInvocation.MyCommand.Path
    return (Split-Path -Parent $src)
}

function Get-YakuDataDir {
    # YAKULINGO_DATA_DIR は回帰テストが実データを汚さずに実行するための退避先指定。
    $override = [string]$env:YAKULINGO_DATA_DIR
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $dir = [System.IO.Path]::GetFullPath($override)
    } else {
        $homeDir = [Environment]::GetFolderPath('UserProfile')
        $dir = Join-Path $homeDir '.yakulingo-ps'
    }
    if (!(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-YakuSubDir {
    param([Parameter(Mandatory=$true)][string]$Name)
    $dir = Join-Path (Get-YakuDataDir) $Name
    if (!(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-YakuUserSettingsPath {
    # 利用者設定はアプリ本体（バージョンフォルダ）ではなくユーザープロファイルへ置く。
    # 共有フォルダのアプリを全利用者が共有しても衝突せず、版を更新しても引き継がれる。
    return (Join-Path (Get-YakuSubDir 'config') 'user_settings.json')
}

function Get-YakuLegacyUserSettingsPath {
    param([Parameter(Mandatory=$true)][string]$Root)
    return (Join-Path $Root 'config\user_settings.json')
}

function New-SafeFileName {
    param([Parameter(Mandatory=$true)][string]$FileName)
    $name = [System.IO.Path]::GetFileName($FileName)
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$ch, '_')
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'file' }
    return $name
}



