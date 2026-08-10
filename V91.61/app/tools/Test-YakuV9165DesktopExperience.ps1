[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:YakuRoot = $appRoot
. (Join-Path $appRoot 'src\Paths.ps1')
. (Join-Path $appRoot 'src\Runtime.ps1')
. (Join-Path $appRoot 'src\DesktopIntegration.ps1')
. (Join-Path $appRoot 'src\CatProject.ps1')

$passed = 0
function Assert-YakuDesktopTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Desktop experience test failed: ' + $Message) }
    $script:passed++
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('yakulingo-desktop-test-' + [guid]::NewGuid().ToString('N'))
$oldData = [string]$env:YAKULINGO_DATA_DIR
$oldLinks = [string]$env:YAKULINGO_DESKTOP_LINK_ROOT
$oldExe = [string]$env:YAKULINGO_DESKTOP_EXE
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $fakeExe = Join-Path $testRoot 'YakuLingo.exe'
    [IO.File]::WriteAllBytes($fakeExe, [byte[]]@(77,90))
    $env:YAKULINGO_DATA_DIR = Join-Path $testRoot 'data'
    $env:YAKULINGO_DESKTOP_LINK_ROOT = Join-Path $testRoot 'links'
    $env:YAKULINGO_DESKTOP_EXE = $fakeExe

    $before = Get-YakuDesktopPreferences
    Assert-YakuDesktopTest (-not [bool]$before.tutorial_completed) 'tutorial must be incomplete before final confirmation'
    Assert-YakuDesktopTest (-not (Test-Path -LiteralPath (Join-Path $testRoot 'links') -PathType Container)) 'GET must not create shortcuts'
    Assert-YakuDesktopTest (-not [string]::IsNullOrWhiteSpace((Get-YakuWindowsKnownFolderPath -Name Desktop))) 'desktop known folder must resolve even in a non-interactive process'

    $legacyRoot = Join-Path $testRoot 'legacy'
    New-Item -ItemType Directory -Path $legacyRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'bootstrap.ps1'), '# legacy')
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'current.txt'), 'V91.60')
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'YakuLingo起動.cmd'), '@echo off')
    $legacyDesktop = Join-Path $testRoot 'links\Desktop\YakuLingo.lnk'
    Set-YakuDesktopShortcutFile -Path $legacyDesktop -TargetPath (Join-Path $legacyRoot 'YakuLingo起動.cmd')
    $legacyShell = New-Object -ComObject WScript.Shell
    $legacyShortcut = $legacyShell.CreateShortcut($legacyDesktop)
    $legacyShortcut.Description = 'Start YakuLingo HTMX + PowerShell edition'
    $legacyShortcut.Save()
    try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($legacyShortcut) } catch {}
    try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($legacyShell) } catch {}
    Assert-YakuDesktopTest (Test-YakuOwnedShortcut -Path $legacyDesktop -TargetPath $fakeExe) 'official legacy launcher shortcut should be recognized for migration'

    $enabled = Set-YakuDesktopPreferences -StartupEnabled $true -DesktopShortcut $true
    Assert-YakuDesktopTest ([bool]$enabled.startup_enabled) 'startup shortcut should be enabled'
    Assert-YakuDesktopTest ([bool]$enabled.desktop_shortcut) 'desktop shortcut should be enabled'
    Assert-YakuDesktopTest ([bool]$enabled.start_menu_shortcut) 'start menu shortcut should always exist'
    Assert-YakuDesktopTest ([bool]$enabled.tutorial_completed) 'final confirmation should complete tutorial'
    Assert-YakuDesktopTest ([string]::Equals([IO.Path]::GetFullPath([string](Get-YakuShortcutTarget -Path $legacyDesktop).TargetPath), [IO.Path]::GetFullPath($fakeExe), [StringComparison]::OrdinalIgnoreCase)) 'legacy shortcut should be rebound to the shell'

    $disabled = Set-YakuDesktopPreferences -StartupEnabled $false -DesktopShortcut $false
    Assert-YakuDesktopTest (-not [bool]$disabled.startup_enabled) 'startup shortcut should be removable'
    Assert-YakuDesktopTest (-not [bool]$disabled.desktop_shortcut) 'desktop shortcut should be removable'
    Assert-YakuDesktopTest ([bool]$disabled.start_menu_shortcut) 'start menu shortcut must remain discoverable'

    $foreignExe = Join-Path $testRoot 'foreign.exe'
    [IO.File]::WriteAllBytes($foreignExe, [byte[]]@(77,90))
    Set-YakuDesktopShortcutFile -Path $legacyDesktop -TargetPath $foreignExe
    $conflictRejected = $false
    try { $null = Set-YakuDesktopPreferences -StartupEnabled $false -DesktopShortcut $true } catch { $conflictRejected = ([string]$_.Exception.Message -match 'DESKTOP_SHORTCUT_CONFLICT') }
    Assert-YakuDesktopTest $conflictRejected 'unrelated same-name shortcut must remain protected from replacement'

    $segment = [pscustomobject]@{
        Text='売上高'; Translation='Net sales'; State='reviewed'; Confirmed=$true; SourceRevision=1
        QcStatus='passed'; QcSourceRevision=1; QcSourceHash=(Get-YakuCatSourceIntegrityHash -Text '売上高')
        QcTargetHash=(Get-YakuCatSourceIntegrityHash -Text 'Net sales'); QcContractVersion=(Get-YakuCatQcContractVersion)
        QcFindings=@()
    }
    $project = [pscustomobject]@{ Id='test'; Revision=3; Source='text'; Path=''; DocumentFormat='text'; Segments=@($segment) }
    # QC記録は原文・訳文だけでなく用語集スナップショットにも紐づく。ここを空のままにすると
    # 「訳文を直したあと点検していない」と判定され、出力可否そのものを見られなくなる。
    # 値は本番と同じ関数から取る。ハッシュの作り方が変わってもこの試験は追随する。
    $segment | Add-Member -NotePropertyName QcTerminologyHash -NotePropertyValue (Get-YakuCatTerminologySnapshotHash -Project $project) -Force
    $preflight = Get-YakuCatOutputPreflight -Project $project
    Assert-YakuDesktopTest ([bool]$preflight.Eligible -and [string]$preflight.Mode -eq 'copy_text') 'reviewed text should preflight to copy_text'
    $project.Source = 'file'; $project.Path = Join-Path $testRoot 'missing.docx'; $project.DocumentFormat = 'docx'
    $project | Add-Member -NotePropertyName WordInventory -NotePropertyValue ([pscustomobject]@{ DraftStructureEligible=$false; ContractVersion='word-adapter-v1' }) -Force
    $wordFallback = Get-YakuCatOutputPreflight -Project $project
    Assert-YakuDesktopTest ([bool]$wordFallback.Eligible -and [string]$wordFallback.Mode -eq 'copy_text') 'unsupported Word should safely fall back to reviewed text'
    Assert-YakuDesktopTest (@($wordFallback.Blockers).Count -eq 0 -and @($wordFallback.Warnings).Count -gt 0) 'safe Word fallback reasons must be warnings, not blockers'
    $project.Source = 'text'; $project.Path = ''; $project.DocumentFormat = 'text'
    $segment.State = 'machine_draft'; $segment.Confirmed = $false
    $blocked = Get-YakuCatOutputPreflight -Project $project
    Assert-YakuDesktopTest (-not [bool]$blocked.Eligible -and @($blocked.Blockers).Count -gt 0) 'unreviewed text must be blocked'

    Write-Host ("Desktop experience tests passed: {0}" -f $passed) -ForegroundColor Green
} finally {
    $env:YAKULINGO_DATA_DIR = $oldData
    $env:YAKULINGO_DESKTOP_LINK_ROOT = $oldLinks
    $env:YAKULINGO_DESKTOP_EXE = $oldExe
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
