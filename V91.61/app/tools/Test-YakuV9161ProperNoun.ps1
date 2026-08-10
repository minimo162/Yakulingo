<#
.SYNOPSIS
  V91.61: 固有名詞を送信前マスクの対象にしない回帰テスト。

.DESCRIPTION
  外部送信前にマスクするのは数値だけ。固有名詞一覧は翻訳後の品質確認用に
  読み込める状態を保つが、人名・法人名・地名を記号へ置き換えない。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'ProperNoun.ps1')
foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'Settings.ps1', 'PromptBuilder.ps1', 'Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $mod)
}

function Chk {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:fail++ }
}

Write-Host '固有名詞一覧は品質確認用に残す' -ForegroundColor Cyan
$entries = @(Get-YakuProperNounEntries -Root $root)
Chk ($entries.Count -gt 0) '固有名詞の一覧を読める'
Chk (@($entries | Where-Object { $_.Source -eq '毛籠' -and $_.Target -eq 'Moro' }).Count -eq 1) '品質確認用の正式表記を読める'

Write-Host '送信前マスクは数値だけ' -ForegroundColor Cyan
Chk ($null -eq (Get-Command New-YakuProperNounMaskMap -ErrorAction SilentlyContinue)) '固有名詞マスクを公開しない'
Chk ($null -eq (Get-Command Restore-YakuProperNounMask -ErrorAction SilentlyContinue)) '固有名詞マスクの復元経路を持たない'

$source = 'マツダ株式会社の毛籠社長は、売上高1,234百万円を説明しました。'
$masked = New-YakuNumericMaskMap -Text $source -Root $root -Direction to_en -Location 'proper-noun-policy-test'
Chk ([string]$masked.Text -match 'マツダ株式会社' -and [string]$masked.Text -match '毛籠') '固有名詞は平文のまま保持する'
Chk ([string]$masked.Text -notmatch '1,234' -and [string]$masked.Text -match '\[\[N1\]\]') '数値だけをマスクする'
Chk ((Restore-YakuNumericMask -Text ([string]$masked.Text) -Map $masked.Map) -eq $source) '数値を復元して原文と一致する'

$productionNames = @('Translation.ps1','CatProject.ps1','CatTranslation.ps1','CatBatch.ps1','CopilotClient.ps1','CorpusReference.ps1','AlignMask.ps1','Alignment.ps1','PromptBuilder.ps1')
$productionText = ($productionNames | ForEach-Object { [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') $_)) }) -join "`n"
Chk ($productionText -notmatch 'New-YakuProperNounMaskMap|Restore-YakuProperNounMask|Test-YakuProperNounMaskIntegrity') '全送信経路が固有名詞マスクを呼ばない'
Chk ($productionText -notmatch 'ProperMaskMap|PROPER NOUN PLACEHOLDERS|\[\[P\d+') '固有名詞placeholder契約を残さない'
Chk ($productionText -match 'New-YakuNumericMaskMap|Protect-YakuAlignmentLines') '数値保護は維持する'

if ($script:fail -gt 0) {
    Write-Host "V91.61 numeric-only masking policy failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 numeric-only masking policy passed.' -ForegroundColor Green
