#Requires -Version 5.1
<#
  英訳へ全角数字を出さないこと。値は変えないこと。

  2026-08-17 の実測で見つけた欠陥の回帰。数値マスクは原文の字形をそのまま
  写像へ入れ、復元でそれを書き戻す。全角の数字はそこを素通りしていた。

      第１５９期 (至 2025年３月31日)
        -> Fiscal Year １５９ (ending 2025 Year ３ Month 31 Day)
      当第３四半期連結累計期間…
        -> ... consolidated first ３ quarters ...

  同じ題材で DeepL・Nani翻訳・素のLLM・マツダの公表英文はいずれも 0 行。
  YakuLingo だけが、表のラベル20行のうち7行、散文20行のうち6行で出していた。

  `ConvertTo-YakuNumericRestoreValue` の註は「値を変えず、言語に依存しない
  アラビア数字へ正規化してから復元する」と書いてある。半角化は関数の中で
  していたが、解析用の局所変数に留まっていて、返り値は元の字形だった。
  **註と実装の食い違いで、註のほうが正しかった。**

  日本語へ訳す向きでは字形を変えない。全角は日本語の表記だからである。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9184Root = Split-Path -Parent $PSScriptRoot
$YakuT9184Src = Join-Path $YakuT9184Root 'src'
. (Join-Path $YakuT9184Src 'SrcModules.ps1')
foreach ($YakuT9184File in $script:YakuSrcModuleFiles) { . (Join-Path $YakuT9184Src $YakuT9184File) }

$script:T9184Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9184 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9184Failures.Add($Message) | Out-Null }
}
function Test-T9184HasFullWidthDigit {
    param([string]$Text)
    foreach ($ch in ([string]$Text).ToCharArray()) { if ([int]$ch -ge 0xFF10 -and [int]$ch -le 0xFF19) { return $true } }
    return $false
}

Write-Host 'Test-YakuV9184FullWidthRestore'

# 全角の数字（符号位置から組む。この .ps1 は ASCII だけで書く）
$YakuT9184FW159 = [string]::Concat([char]0xFF11, [char]0xFF15, [char]0xFF19)   # 159
$YakuT9184FW3 = [string]([char]0xFF13)                                          # 3

# --- 英訳へは半角で戻る -------------------------------------------------------
$r1 = ConvertTo-YakuNumericRestoreValue -Text $YakuT9184FW159 -Direction 'to_en'
Assert-T9184 -Condition ($r1 -eq '159') -Message ('a full-width 159 restores as 159 for to_en (got "' + $r1 + '")')
Assert-T9184 -Condition (-not (Test-T9184HasFullWidthDigit $r1)) -Message 'no full-width digit survives into English'

$r2 = ConvertTo-YakuNumericRestoreValue -Text $YakuT9184FW3 -Direction 'to_en'
Assert-T9184 -Condition ($r2 -eq '3') -Message ('a full-width 3 restores as 3 for to_en (got "' + $r2 + '")')

# --- 値は変えない -------------------------------------------------------------
$r3 = ConvertTo-YakuNumericRestoreValue -Text '1,609' -Direction 'to_en'
Assert-T9184 -Condition ($r3 -eq '1,609') -Message 'a half-width number is returned untouched, separators included'
$r4 = ConvertTo-YakuNumericRestoreValue -Text '43.8' -Direction 'to_en'
Assert-T9184 -Condition ($r4 -eq '43.8') -Message 'a decimal is returned untouched'

# --- 日本語へ訳す向きでは字形を変えない ---------------------------------------
$r5 = ConvertTo-YakuNumericRestoreValue -Text $YakuT9184FW159 -Direction 'to_jp'
Assert-T9184 -Condition ($r5 -eq $YakuT9184FW159) -Message 'to_jp keeps the Japanese glyph form'
$r6 = ConvertTo-YakuNumericRestoreValue -Text $YakuT9184FW159 -Direction 'auto'
Assert-T9184 -Condition ($r6 -eq $YakuT9184FW159) -Message 'auto keeps the Japanese glyph form'

# --- 経路の端から端まで -------------------------------------------------------
# 「第１５９期」を伏せて、英文へ戻す。
$YakuT9184Ja = [string]::Concat([char]0x7B2C, $YakuT9184FW159, [char]0x671F)   # dai-159-ki
$mask = New-YakuNumericMaskMap -Text $YakuT9184Ja -Root $YakuT9184Root -Direction 'to_en' -Location 'test-9184'
Assert-T9184 -Condition ([int]$mask.MaskedCount -ge 1) -Message 'the full-width figure is masked before sending'
$tokens = @(Get-YakuNumericMaskTokens -Text ([string]$mask.Text))
Assert-T9184 -Condition ($tokens.Count -ge 1) -Message 'a placeholder token is present in the masked text'
$englishWithToken = 'Fiscal Year ' + $tokens[0]
$restored = Restore-YakuNumericMask -Text $englishWithToken -Map $mask.Map -Direction 'to_en' -SourceText $YakuT9184Ja
Assert-T9184 -Condition ($restored -eq 'Fiscal Year 159') -Message ('end to end: "' + $restored + '" carries no full-width digit')
Assert-T9184 -Condition (-not (Test-T9184HasFullWidthDigit $restored)) -Message 'end to end: the English output is free of full-width digits'

Write-Host ''
if ($script:T9184Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9184FullWidthRestore'
    exit 0
}
Write-Host ("FAIL " + $script:T9184Failures.Count + ' assertion(s)')
foreach ($YakuT9184F in $script:T9184Failures) { Write-Host ('  - ' + $YakuT9184F) }
exit 1
