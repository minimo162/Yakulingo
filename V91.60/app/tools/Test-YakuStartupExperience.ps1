<#
.SYNOPSIS
  起動・設定・終了まわりの回帰テスト。

.DESCRIPTION
  起動時の文字コード・構文検査を、中身が変わっていないときは省くこと、
  設定画面で開発者向けの項目を「詳細設定」にしまうこと、画面から終了できることを確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuStartupExperience.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuSx {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

Write-Host 'CASE 1: 起動時の検査は中身が変わったときだけ'
$startPath = Join-Path $root 'Start-YakuLingo.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($startPath, [ref]$tokens, [ref]$errors)
foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))) {
    if ($fn.Name -in @('Get-YakuStartupCheckStampPath','Get-YakuRelativePathForStartup')) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-sx-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $work 'prompts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'src\A.ps1') -Value 'function A { 1 }' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $work 'prompts\p.txt') -Value 'prompt' -Encoding UTF8
    $s1 = Get-YakuStartupCheckStampPath -Root $work
    $s2 = Get-YakuStartupCheckStampPath -Root $work
    Assert-YakuSx (-not [string]::IsNullOrWhiteSpace($s1) -and $s1 -eq $s2) '同じ中身なら同じ印'
    Assert-YakuSx (-not $s1.StartsWith($work)) '印はアプリのフォルダ（共有フォルダの場合がある）へ書かない'
    Start-Sleep -Milliseconds 20
    Set-Content -LiteralPath (Join-Path $work 'src\A.ps1') -Value 'function A { 22 }' -Encoding UTF8
    Assert-YakuSx ((Get-YakuStartupCheckStampPath -Root $work) -ne $s1) '.ps1 が変われば印も変わる（検査をやり直す）'
    $s3 = Get-YakuStartupCheckStampPath -Root $work
    Set-Content -LiteralPath (Join-Path $work 'prompts\p.txt') -Value 'prompt changed' -Encoding UTF8
    Assert-YakuSx ((Get-YakuStartupCheckStampPath -Root $work) -ne $s3) 'プロンプトが変われば印も変わる'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
$startText = Get-Content -LiteralPath $startPath -Raw -Encoding UTF8
Assert-YakuSx ($startText.Contains('Test-YakuUtf8BomForStartup -Root $root') -and $startText.Contains('Test-YakuPowerShellSyntax -Root $root')) '印が無いときは従来どおり検査する'

Write-Host 'CASE 2: 設定画面'
foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1')) { . (Join-Path (Join-Path $root 'src') $name) }
$env:YAKULINGO_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-sx-data-' + [guid]::NewGuid().ToString('N'))
try {
    $form = Convert-YakuSettingsFormToHtml -Settings (Read-YakuSettings -Root $root)
} finally {
    if (Test-Path -LiteralPath $env:YAKULINGO_DATA_DIR) { Remove-Item -LiteralPath $env:YAKULINGO_DATA_DIR -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue
}
$advancedAt = $form.IndexOf("<details class='settings-advanced'>")
Assert-YakuSx ($advancedAt -gt 0) '詳細設定の折りたたみがある'
foreach ($dev in @("name='edge_debug_port'","name='max_chars_per_batch'","name='copilot_model'","name='request_timeout'")) {
    Assert-YakuSx ($form.IndexOf($dev) -gt $advancedAt) ("開発者向けの項目は詳細設定の中: $dev")
}
foreach ($basic in @("name='diagnostics_level'","name='translate_shapes' value='true'")) {
    Assert-YakuSx ($form.IndexOf($basic) -ge 0 -and $form.IndexOf($basic) -lt $advancedAt) ("よく使う項目は外に出す: $basic")
}
foreach ($flag in @('use_bundled_glossary','csv_translate_header','translate_shapes','translate_charts','translation_cache_enabled')) {
    $hidden = $form.IndexOf("<input type='hidden' name='$flag' value='false'>")
    $box = $form.IndexOf("<input type='checkbox' name='$flag'")
    Assert-YakuSx ($hidden -ge 0 -and $box -gt $hidden) ("チェックを外した値も送る（hidden が先）: $flag")
}

Write-Host 'CASE 3: 画面から終了できる'
$index = Get-Content -LiteralPath (Join-Path $root 'www\index.html') -Raw -Encoding UTF8
$appJs = Get-Content -LiteralPath (Join-Path $root 'www\assets\app.js') -Raw -Encoding UTF8
Assert-YakuSx ($index.Contains('data-yaku-quit')) '終了ボタンがある'
Assert-YakuSx ($appJs.Contains("yakuJsonPost('/shutdown'")) '終了ボタンはセッション付きで /shutdown を呼ぶ'
$launcher = Join-Path (Split-Path -Parent (Split-Path -Parent $root)) 'YakuLingo起動.cmd'
if (Test-Path -LiteralPath $launcher) {
    $cmd = [System.IO.File]::ReadAllText($launcher)
    Assert-YakuSx ($cmd.Contains('if "%CODE%"=="0" exit /b 0')) '正常終了ならコンソールを閉じる'
    Assert-YakuSx (-not ($cmd -match '[^\x00-\x7F]')) '起動用 .cmd は ASCII のまま'
}

if ($script:Failures -gt 0) {
    Write-Host "Startup experience test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'Startup experience regression passed.' -ForegroundColor Green
