<#
.SYNOPSIS
  V91.60: 数値マスキングの回帰テスト。

.DESCRIPTION
  分類（マスクされる／されない）、往復、符号・単位の保持、用語集保護、
  平文の漏洩、異常系を検証する。ケースはデータで持ち、後から足せる形にする
  （_docs/設計方針_翻訳アーキテクチャ見直し.md §4-E の評価基盤の一部）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9160NumericMasking.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0

function Assert-YakuMask {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','Translation.ps1')) {
    . (Join-Path (Join-Path $root 'src') $name)
}

function Invoke-YakuMaskPipeline {
    # アプリと同じ順序: 単位変換 -> マスク
    param([string]$Text, [string]$Direction = 'to_en')
    $pre = if ($Direction -eq 'to_en') { (Convert-YakuNumericUnits -Text $Text -Location 'test').Text } else { [string]$Text }
    $masked = New-YakuNumericMaskMap -Text $pre -Root $root -Direction $Direction -Location 'test'
    return [pscustomobject]@{ Pre = $pre; Masked = $masked }
}

# ---------------------------------------------------------------- 分類
Write-Host 'CASE 1: 非マスクにする形'
$keepCases = @(
    @{ Text = '2027年３月期第１四半期の営業利益は296億円でした。'; Keep = @('2027年３月期', '第１四半期') },
    @{ Text = 'FY26/3 1Q の固定費改善は248億円。';                  Keep = @('FY26/3', '1Q') },
    @{ Text = '2026年８月４日に公表しました。';                      Keep = @('2026年８月４日') },
    @{ Text = 'TEL 082-282-1111 へご連絡ください。';                 Keep = @('082-282-1111') },
    @{ Text = 'コード番号 7261 です。';                              Keep = @('コード番号 7261') },
    @{ Text = '1株当たり配当金は120円です。';                        Keep = @('1株当たり') },
    @{ Text = '２０２６年度の計画です。';                            Keep = @('２０２６年度') },
    @{ Text = '第151期の報告です。';                                 Keep = @('第151期') }
)
foreach ($c in $keepCases) {
    $r = Invoke-YakuMaskPipeline -Text ([string]$c.Text)
    foreach ($k in @($c.Keep)) {
        Assert-YakuMask ([string]$r.Masked.Text -like ('*' + $k + '*')) ("非マスク: $k")
    }
}

Write-Host 'CASE 2: マスクする形'
$maskCases = @(
    @{ Text = '売上高は11,577億円。';        Gone = @('11,577') },
    @{ Text = '自己資本比率は43.3％。';       Gone = @('43.3') },
    @{ Text = '出荷台数は659千台。';          Gone = @('659') },
    @{ Text = '上位10社と取引しています。';   Gone = @('10') },
    @{ Text = '0.7ポイント増加しました。';    Gone = @('0.7') }
)
foreach ($c in $maskCases) {
    $r = Invoke-YakuMaskPipeline -Text ([string]$c.Text)
    foreach ($g in @($c.Gone)) {
        Assert-YakuMask (-not ([string]$r.Masked.Text -like ('*' + $g + '*'))) ("マスク: $g -> " + $r.Masked.Text)
    }
}

# ---------------------------------------------------------------- 往復
Write-Host 'CASE 3: 往復（復元でマスク前と一致する）'
$roundTrip = @(
    '売上高は前年同期比789億円増の11,577億円となりました。',
    '前年差は(50)億円、計画差は(400)億円、改善額は60億円。',
    '売上高５，６０２億円となった。固定費改善は対前年4Q比248億円。',
    '前連結会計年度末より579億円減少の2兆4,967億円となりました。',
    '自己資本比率は0.7ポイント増加の43.3％となりました。',
    '１．セグメント利益は△46,115百万円。',
    '10〜20億円の範囲です。72億円→85億円へ増加しました。'
)
foreach ($t in $roundTrip) {
    $r = Invoke-YakuMaskPipeline -Text $t
    $back = Restore-YakuNumericMask -Text $r.Masked.Text -Map $r.Masked.Map
    Assert-YakuMask ($back -eq $r.Pre) ("往復一致: $t")
}

# ---------------------------------------------------------------- 符号・単位
Write-Host 'CASE 4: 符号と単位はプレースホルダーの外に残る'
$signCase = Invoke-YakuMaskPipeline -Text '前年差は▲72億円、計画差は+120億円、比率は△3.1％。'
foreach ($k in @('▲', '+', '△', 'oku', '％')) {
    Assert-YakuMask ([string]$signCase.Masked.Text -like ('*' + $k + '*')) ("外に残る: $k")
}
Assert-YakuMask (-not ([string]$signCase.Masked.Text -match '(?<!N)\d')) '送信テキストに素の数字が残らない'

$parenCase = Invoke-YakuMaskPipeline -Text '前年差は(50)億円。'
Assert-YakuMask ([string]$parenCase.Masked.Text -like '*(【N1】)億円*') "半角括弧の負数を壊さない: $($parenCase.Masked.Text)"

# ---------------------------------------------------------------- 用語集保護
Write-Host 'CASE 5: 用語集に一致した範囲は保護される'
$glossaryCase = Invoke-YakuMaskPipeline -Text 'FY26/3 1Q の単価改善は120億円。'
Assert-YakuMask ([string]$glossaryCase.Masked.Text -like '*単価改善*') '用語集の語が壊れない'
$glossaryMatches = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText ([string]$glossaryCase.Masked.Text) -Direction 'to_en' -Limit 48)
Assert-YakuMask (@($glossaryMatches | Where-Object { [string]$_.Source -eq '単価改善' }).Count -gt 0) 'マスク後も用語集が一致する'

# ---------------------------------------------------------------- 漏洩
Write-Host 'CASE 6: 送信テキストに平文の機密数値が残らない'
$leakSource = '営業利益は296億円、税金費用99億円、前年同期は421億円の損失。出荷台数659千台。'
$leak = Invoke-YakuMaskPipeline -Text $leakSource
foreach ($n in @('296', '99', '421', '659')) {
    Assert-YakuMask (-not ([string]$leak.Masked.Text -like ('*' + $n + '*'))) ("平文なし: $n")
}
Assert-YakuMask ($leak.Masked.MaskedCount -ge 4) ("マスク件数 " + $leak.Masked.MaskedCount)

# ---------------------------------------------------------------- 整合検証
Write-Host 'CASE 7: プレースホルダー整合の検証'
$base = Invoke-YakuMaskPipeline -Text '売上高は789億円増の11,577億円。'
$maskedText = [string]$base.Masked.Text
Assert-YakuMask ((Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated $maskedText).Ok) '同一なら Ok'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText -replace '【N1】','')).Ok) '欠落を検出'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText + '【N1】')).Ok) '重複を検出'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText + '【N9】')).Ok) '混入を検出'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText -replace '【N1】','789')).Ok) '数字への置換を検出'

# ---------------------------------------------------------------- 手動マスクとの共存
Write-Host 'CASE 8: 利用者の手動マスクを壊さない'
$manual = Invoke-YakuMaskPipeline -Text '営業利益は【営業利益額非開示】、売上高は11,577億円。'
Assert-YakuMask ([string]$manual.Masked.Text -like '*【営業利益額非開示】*') '【…非開示】をそのまま残す'
Assert-YakuMask (-not ([string]$manual.Masked.Text -like '*11,577*')) '同じ文の機密数値はマスクする'

# ---------------------------------------------------------------- to_jp
Write-Host 'CASE 9: to_jp 方向でもマスクする'
$toJp = New-YakuNumericMaskMap -Text 'Revenue was 7.2 billion yen, up 12.3% year on year.' -Root $root -Direction 'to_jp' -Location 'test'
Assert-YakuMask (-not ([string]$toJp.Text -like '*7.2*')) '英語入力の金額をマスクする'
Assert-YakuMask ([string]$toJp.Text -like '*billion yen*') '単位は残る'
Assert-YakuMask ((Restore-YakuNumericMask -Text $toJp.Text -Map $toJp.Map) -eq 'Revenue was 7.2 billion yen, up 12.3% year on year.') 'to_jp でも往復する'

# ---------------------------------------------------------------- 無効化
Write-Host 'CASE 10: 環境変数での無効化（検証用の抜け道）'
$previous = $env:YAKULINGO_NUMERIC_MASKING
$env:YAKULINGO_NUMERIC_MASKING = 'off'
try {
    $offCase = New-YakuNumericMaskMap -Text '売上高は11,577 oku。' -Root $root -Direction 'to_en' -Location 'test'
    Assert-YakuMask ([string]$offCase.Text -like '*11,577*') 'off で素通しする'
    Assert-YakuMask ($offCase.MaskedCount -eq 0) 'off ではマスクしない'
} finally {
    if ([string]::IsNullOrEmpty($previous)) { Remove-Item Env:YAKULINGO_NUMERIC_MASKING -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_NUMERIC_MASKING = $previous }
}
$onAgain = New-YakuNumericMaskMap -Text '売上高は11,577 oku。' -Root $root -Direction 'to_en' -Location 'test'
Assert-YakuMask ($onAgain.MaskedCount -gt 0) '既定では有効に戻る'

# ---------------------------------------------------------------- 監査と補正指示
Write-Host 'CASE 11: 数値整合監査がプレースホルダーを対象にする'
$auditSource = '売上高は【N1】 oku、比率は【N2】％。'
$expectations = @(Get-YakuNumericAuditExpectations -SourceText $auditSource)
Assert-YakuMask (@($expectations | Where-Object { [string]$_.Expected -eq '【N1】 oku' }).Count -eq 1) '【N1】 oku を監査対象にする'
Assert-YakuMask (@($expectations | Where-Object { [string]$_.Expected -eq '【N2】%' }).Count -eq 1) '【N2】% を監査対象にする'
$okAudit = Test-YakuNumericIntegrity -SourceText $auditSource -TranslatedText 'Revenue 【N1】 oku, ratio 【N2】%.' -Location 'test'
Assert-YakuMask ($okAudit.Ok) 'プレースホルダーが揃えば Ok'
$ngAudit = Test-YakuNumericIntegrity -SourceText $auditSource -TranslatedText 'Revenue oku, ratio %.' -Location 'test'
Assert-YakuMask (-not $ngAudit.Ok) '欠落を検出する'

Write-Host 'CASE 12: 補正指示文に平文の数値を載せない'
$instruction = New-YakuNumericCorrectionInstruction -Audit $ngAudit
Assert-YakuMask ($instruction -like '*【N1】 oku*') 'プレースホルダーは指示に載る'
Assert-YakuMask (-not ($instruction -match '(?<!N)\d')) ("指示文に素の数字が無い: " + $instruction)

# マスクされなかった数値(年号など)が監査に入っても、指示文へは出さない
$mixedSource = '売上高は【N1】 oku、前年は72 oku。'
$mixedAudit = Test-YakuNumericIntegrity -SourceText $mixedSource -TranslatedText 'Revenue was oku, prior year oku.' -Location 'test'
Assert-YakuMask ($mixedAudit.Checked -eq 2) '平文の数値も監査自体は拾う'
$mixedInstruction = New-YakuNumericCorrectionInstruction -Audit $mixedAudit
Assert-YakuMask ($mixedInstruction -like '*【N1】*') 'プレースホルダーは残る'
Assert-YakuMask (-not ($mixedInstruction -like '*72*')) '平文の数値は指示文から落とす'

$allPlainAudit = Test-YakuNumericIntegrity -SourceText '前年は72 oku。' -TranslatedText 'Prior year oku.' -Location 'test'
Assert-YakuMask ((New-YakuNumericCorrectionInstruction -Audit $allPlainAudit) -eq '') '平文だけなら指示文は空になる'

if ($script:Failures -gt 0) {
    Write-Host "V91.60 numeric masking test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.60 numeric masking regression passed.' -ForegroundColor Green
