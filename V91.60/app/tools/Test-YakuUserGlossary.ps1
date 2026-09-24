<#
.SYNOPSIS
  自分の用語集（%USERPROFILE%\.yakulingo-ps\glossary）の回帰テスト。

.DESCRIPTION
  版フォルダの外に置いた利用者の用語集が、同梱の用語集に重なって読まれること、
  同じ原語は利用者側が優先されること、追加が版フォルダを書き換えないことを確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuUserGlossary.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuUg {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

$dataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-ug-' + [guid]::NewGuid().ToString('N'))
$env:YAKULINGO_DATA_DIR = $dataDir
try {
    foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1')) {
        . (Join-Path (Join-Path $root 'src') $name)
    }
    $bundledPrompt = Get-YakuPromptGlossaryPath -Root $root
    $bundledHash = (Get-FileHash -LiteralPath $bundledPrompt -Algorithm SHA256).Hash
    $bundled = @(Get-YakuGlossaryEntries -Root $root -Path $bundledPrompt)
    $sample = $bundled | Where-Object { [string]$_.Source -eq '売上高' } | Select-Object -First 1
    Assert-YakuUg ($null -ne $sample) '同梱の用語集に「売上高」がある（テストの前提）'

    Write-Host 'CASE 1: 利用者の用語集が無ければ同梱分だけを返す'
    Assert-YakuUg (-not (Test-Path -LiteralPath (Get-YakuUserGlossaryPath -Name 'prompt_glossary.csv'))) 'まだ作られていない'
    Assert-YakuUg (@(Get-YakuGlossaryEntries -Root $root -Path $bundledPrompt).Count -eq $bundled.Count) '件数は同梱分と同じ'

    Write-Host 'CASE 2: 追加した語が読まれ、同じ原語は利用者側が優先される'
    $fp1 = Get-YakuTranslationContractFingerprint -Root $root -Settings $null
    $userPath = Add-YakuUserGlossaryEntry -Name 'prompt_glossary.csv' -Source '台当り新語テスト' -Target 'new test term per unit'
    Start-Sleep -Milliseconds 20
    $null = Add-YakuUserGlossaryEntry -Name 'prompt_glossary.csv' -Source '売上高' -Target 'turnover, net'
    Assert-YakuUg ($userPath.StartsWith($dataDir)) ('保存先は利用者データの下: ' + $userPath)
    $merged = @(Get-YakuGlossaryEntries -Root $root -Path $bundledPrompt)
    Assert-YakuUg (@($merged | Where-Object { [string]$_.Source -eq '台当り新語テスト' }).Count -eq 1) '追加した語が読まれる'
    $sales = @($merged | Where-Object { [string]$_.Source -eq '売上高' })
    Assert-YakuUg ($sales.Count -eq 1 -and [string]$sales[0].Target -eq 'turnover, net') ('同じ原語は利用者側を優先（カンマ入りの訳語も崩れない）: ' + (($sales | ForEach-Object { $_.Target }) -join ' / '))
    Assert-YakuUg ($merged.Count -eq $bundled.Count + 1) '重複は1件にまとまる'
    $matches = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText '台当り新語テストが増えた' -Direction 'to_en' -Limit 10 -Path $bundledPrompt)
    Assert-YakuUg (@($matches | Where-Object { [string]$_.Source -eq '台当り新語テスト' }).Count -ge 1) 'プロンプトへ注入する候補にも入る'
    $fp2 = Get-YakuTranslationContractFingerprint -Root $root -Settings $null
    Assert-YakuUg ($fp1 -ne $fp2) '追加すると翻訳キャッシュの契約が変わる（古い訳を使い回さない）'
    Assert-YakuUg ((Get-FileHash -LiteralPath $bundledPrompt -Algorithm SHA256).Hash -eq $bundledHash) '同梱の用語集は書き換えない'

    Write-Host 'CASE 3: 表ラベル用は glossary.csv 側に効く'
    $null = Add-YakuUserGlossaryEntry -Name 'glossary.csv' -Source '表ラベル新語テスト' -Target 'Label Test'
    $labelEntries = @(Get-YakuGlossaryEntries -Root $root)
    Assert-YakuUg (@($labelEntries | Where-Object { [string]$_.Source -eq '表ラベル新語テスト' }).Count -eq 1) '表ラベル用に入る'
    Assert-YakuUg (@(Get-YakuGlossaryEntries -Root $root -Path $bundledPrompt | Where-Object { [string]$_.Source -eq '表ラベル新語テスト' }).Count -eq 0) '文章用には混ざらない'

    Write-Host 'CASE 4: 入力の検査'
    foreach ($bad in @(@('', 'x'), @('x', ''), @("a`nb", 'x'), @('#c', 'x'))) {
        $threw = $false
        try { $null = Add-YakuUserGlossaryEntry -Name 'prompt_glossary.csv' -Source $bad[0] -Target $bad[1] } catch { $threw = $true }
        Assert-YakuUg $threw ('受け付けない: [' + ($bad[0] -replace "`n", '\n') + '] -> [' + $bad[1] + ']')
    }
    $bytes = [System.IO.File]::ReadAllBytes($userPath)
    Assert-YakuUg ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'UTF-8 BOM付きで作る（Excelで開いても文字化けしない）'

    Write-Host 'CASE 5: 画面'
    $panel = Convert-YakuGlossaryManagerToHtml -Root $root
    Assert-YakuUg ($panel.Contains('自分の用語集 — 文章用') -and $panel.Contains('台当り新語テスト')) '自分の用語集が表示される'
    Assert-YakuUg ($panel.Contains('data-yaku-glossary-add')) '追加フォームがある'
} finally {
    Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -gt 0) {
    Write-Host "User glossary test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'User glossary regression passed.' -ForegroundColor Green
