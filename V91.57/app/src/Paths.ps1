
function Get-YakuRoot {
    if ($script:YakuRoot) { return $script:YakuRoot }
    $src = Split-Path -Parent $MyInvocation.MyCommand.Path
    return (Split-Path -Parent $src)
}

function Get-YakuDataDir {
    $homeDir = [Environment]::GetFolderPath('UserProfile')
    $dir = Join-Path $homeDir '.yakulingo-ps'
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

function New-SafeFileName {
    param([Parameter(Mandatory=$true)][string]$FileName)
    $name = [System.IO.Path]::GetFileName($FileName)
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$ch, '_')
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'file' }
    return $name
}



