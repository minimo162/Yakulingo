<#
.SYNOPSIS
  V91.60: 数値マスキングの回帰テスト。

.DESCRIPTION
  全ユーザー入力数値のマスク、往復、符号・単位の保持、非数値語の保持、
  平文の漏洩、異常系を検証する。ケースはデータで持ち、後から足せる形にする
  （_docs/設計方針_翻訳アーキテクチャ見直し.md §4-E の評価基盤の一部）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9160NumericMasking.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:YAKULINGO_TEST_PROTECTED_TRANSPORT = '1'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
$oldDataDir = [string]$env:YAKULINGO_DATA_DIR
$script:YakuNumericTestData = Join-Path ([IO.Path]::GetTempPath()) ('yaku-numeric-' + [guid]::NewGuid().ToString('N'))
$env:YAKULINGO_DATA_DIR = $script:YakuNumericTestData

function Assert-YakuMask {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','BriefStyle.ps1','CatProject.ps1')) {
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
Write-Host 'CASE 1: 年度・日付・電話・コードを含む全入力数値をマスクする'
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
    Assert-YakuMask ([int]$r.Masked.MaskedCount -gt 0 -and
        -not ([string]$r.Masked.Text -match '(?<!\[\[N)\d')) ("全数値をマスク: " + [string]$c.Text)
    Assert-YakuMask ((Restore-YakuNumericMask -Text ([string]$r.Masked.Text) -Map $r.Masked.Map) -eq [string]$r.Pre) ("全数値を復元: " + [string]$c.Text)
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

Write-Host 'CASE 2b: 漢数字・英語の綴り数も保護する'
foreach ($c in @(
    @{ Text='極秘売上高は一億二千万円です。'; Direction='to_en'; Expected='極秘売上高は120,000,000円です。' },
    @{ Text='極秘売上高は百億円です。'; Direction='to_en'; Expected='極秘売上高は10,000,000,000円です。' },
    @{ Text='極秘売上高は三千五百万円です。'; Direction='to_en'; Expected='極秘売上高は35,000,000円です。' },
    @{ Text='極秘売上高は壱億弐千万円です。'; Direction='to_en'; Expected='極秘売上高は120,000,000円です。' },
    @{ Text='Confidential revenue was one hundred million dollars.'; Direction='to_jp'; Expected='Confidential revenue was 100,000,000 dollars.' },
    @{ Text='Confidential revenue was two billion yen.'; Direction='to_jp'; Expected='Confidential revenue was 2,000,000,000 yen.' }
)) {
    $maskedWords = New-YakuNumericMaskMap -Text ([string]$c.Text) -Root $root -Direction ([string]$c.Direction) -Location 'word-number-test'
    $restoredWords = Restore-YakuNumericMask -Text ([string]$maskedWords.Text) -Map $maskedWords.Map
    Assert-YakuMask ([int]$maskedWords.MaskedCount -gt 0 -and [string]$maskedWords.Text -ne [string]$c.Text) ('綴り数を伏せる: ' + [string]$c.Text)
    Assert-YakuMask ([string]$restoredWords -eq [string]$c.Expected) ('綴り数を言語非依存の数字へ復元する: ' + [string]$c.Text)
}

Write-Host 'CASE 2c: 漢数字の金額は財務英語のscaleへ復元する'
foreach($c in @(
    @{Source='売上高は一億二千万円です。';Masked='Net sales were [[N1]] yen.';Expected='Net sales were 120 million yen.'},
    @{Source='売上高は120,000,000円です。';Masked='Net sales were [[N1]] yen.';Expected='Net sales were 120 million yen.'},
    @{Source='売上高は百億円です。';Masked='Net sales were [[N1]] yen.';Expected='Net sales were 10 billion yen.'},
    @{Source='売上高は三千五百万円です。';Masked='Net sales were [[N1]] yen.';Expected='Net sales were 35 million yen.'},
    @{Source='売上高は壱億弐千万円です。';Masked='JPY [[N1]]';Expected='JPY 120 million'},
    @{Source='売上高は一億二千万円です。';Masked='Net sales were [[N1]] million yen.';Expected='Net sales were 120 million yen.'}
)){
    $financialMask=New-YakuNumericMaskMap -Text ([string]$c.Source) -Root $root -Direction to_en -Location 'financial-restore-test'
    $financialRestored=Restore-YakuNumericMask -Text ([string]$c.Masked) -Map $financialMask.Map -Direction to_en -SourceText ([string]$financialMask.Text)
    Assert-YakuMask ([string]$financialRestored -eq [string]$c.Expected) ('財務英語へ復元: '+[string]$c.Source+' => '+$financialRestored)
}
$peopleMask=New-YakuNumericMaskMap -Text '従業員は一億人です。' -Root $root -Direction to_en -Location 'non-financial-restore-test'
$peopleRestored=Restore-YakuNumericMask -Text 'There are [[N1]] employees.' -Map $peopleMask.Map -Direction to_en
Assert-YakuMask ($peopleRestored -eq 'There are 100,000,000 employees.') '通貨でない数量へ財務scaleを追加しない'
$financialOptions=@([pscustomobject]@{Style='full';Label='FULL';Translation='Net sales were [[N1]] yen.';Explanation=''})
$financialOptionResult=@(Restore-YakuMaskedTranslationOptions -Options $financialOptions -MaskedSource ([string]$financialMask.Text) -Map $financialMask.Map -Warnings $null -Location 'financial-option-restore-test' -Direction to_en)
Assert-YakuMask ($financialOptionResult[0].Translation -eq 'Net sales were 120 million yen.') '本文翻訳の復元経路にも財務scaleを適用する'
$okuMask=New-YakuNumericMaskMap -Text '売上高は122 okuです。' -Root $root -Direction to_en -Location 'oku-financial-restore-test'
$okuRestored=Restore-YakuNumericMask -Text 'Net sales were [[N1]] billion yen.' -Map $okuMask.Map -Direction to_en -SourceText ([string]$okuMask.Text)
Assert-YakuMask ($okuRestored -eq 'Net sales were 12.2 billion yen.') 'okuの係数を英語scaleへ事実値のまま換算する'

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

# ---------------------------------------------------------------- 単位の複合
# 日本語の桁は重ねて書かれる（18万6千台）。複合を畳まないと上位の桁だけが
# 日本語のまま英文へ残り、モデルが ten thousand と訳す（2026-08-05 実機）。
# 兆+億 は元から畳んでいたので、万+千 と 億+万 も同じ扱いに揃える。
Write-Host 'CASE 3b: 桁の複合を畳む'
foreach ($u in @(
    @{ In='販売台数は18万6千台。';     Want='186 k units' }
    @{ In='販売台数は1万9千台。';      Want='19 k units' }
    @{ In='販売台数は2万0千台。';      Want='20 k units' }
    @{ In='販売台数は18万6,000台。';   Want='186 k units' }
    @{ In='費用は3万5千円。';          Want='35 k yen' }
    @{ In='売上高は1億2,000万円。';    Want='1.2 oku' }
    @{ In='売上高は3億5千万円。';      Want='3.5 oku' }
    # 単独の桁は従来どおり
    @{ In='販売台数は18万台。';        Want='180 k units' }
    @{ In='販売台数は6千台。';         Want='6 k units' }
    @{ In='費用は500万円。';           Want='5,000 k yen' }
    @{ In='売上高は1兆2,345億円。';    Want='12,345 oku' }
)) {
    $got = [string](Convert-YakuNumericUnits -Text ([string]$u.In) -Location 'test').Text
    Assert-YakuMask ($got -match ([regex]::Escape([string]$u.Want))) ("{0} -> {1}" -f $u.In, $got)
    Assert-YakuMask ($got -notmatch '[万千兆億]') ("日本語の桁が残らない: " + $got)
}

# ---------------------------------------------------------------- 符号・単位
Write-Host 'CASE 4: 符号と単位はプレースホルダーの外に残る'
$signCase = Invoke-YakuMaskPipeline -Text '前年差は▲72億円、計画差は+120億円、比率は△3.1％。'
foreach ($k in @('▲', '+', '△', 'oku', '％')) {
    Assert-YakuMask ([string]$signCase.Masked.Text -like ('*' + $k + '*')) ("外に残る: $k")
}
Assert-YakuMask (-not ([string]$signCase.Masked.Text -match '(?<!N)\d')) '送信テキストに素の数字が残らない'

$parenCase = Invoke-YakuMaskPipeline -Text '前年差は(50)億円。'
Assert-YakuMask ([string]$parenCase.Masked.Text -match ([regex]::Escape('([[N1]])億円'))) "半角括弧の負数を壊さない: $($parenCase.Masked.Text)"

# ---------------------------------------------------------------- 数値以外の本文保護
Write-Host 'CASE 5: 数値以外の本文はマスキングで壊さない'
$glossaryCase = Invoke-YakuMaskPipeline -Text 'FY26/3 1Q の単価改善は120億円。'
Assert-YakuMask ([string]$glossaryCase.Masked.Text -like '*単価改善*') '数値以外の語句が壊れない'
Assert-YakuMask (-not (Test-Path -LiteralPath (Join-Path $root 'glossary.csv'))) '同梱用語集に依存しない'

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
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText -replace ([regex]::Escape('[[N1]]')),'')).Ok) '欠落を検出'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText + '[[N1]]')).Ok) '重複を検出'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText + '[[N9]]')).Ok) '混入を検出'
Assert-YakuMask (-not (Test-YakuNumericMaskIntegrity -MaskedSource $maskedText -Translated ($maskedText -replace ([regex]::Escape('[[N1]]')),'789')).Ok) '数字への置換を検出'

# ---------------------------------------------------------------- 【】の扱い
Write-Host 'CASE 8: 手動マスクの廃止（決定事項#7）'
# 【…非開示】は保護しない。数値は自動でマスクされるので手で伏せる必要がなく、
# 二重の仕組みを残すと保護範囲の判断が分かれる。【】は強調・見出しの括弧として扱う。
$manual = Invoke-YakuMaskPipeline -Text '営業利益は【営業利益額非開示】、売上高は11,577億円。'
Assert-YakuMask ([string]$manual.Masked.Text -like '*【営業利益額非開示】*') '数字を含まない【…】はそのまま（訳す対象になる）'
Assert-YakuMask (-not ([string]$manual.Masked.Text -like '*11,577*')) '同じ文の機密数値はマスクする'

$bracketed = Invoke-YakuMaskPipeline -Text '【営業利益 296億円】は前年並みでした。'
Assert-YakuMask (-not ([string]$bracketed.Masked.Text -like '*296*')) '【】の中の数値もマスクする'
Assert-YakuMask ([string]$bracketed.Masked.Text -match ([regex]::Escape('【営業利益 [[N1]] oku】'))) '【】自体は残す'

# 内部で保護済みと明示した[[N1]]だけは二重マスクしない。
$twice = New-YakuNumericMaskMap -Text ([string]$bracketed.Masked.Text) -Root $root -Direction 'to_en' -Location 'test' -AllowExistingTokens
Assert-YakuMask ([int]$twice.MaskedCount -eq 0) '内部の[[N1]]を二重にマスクしない'
Assert-YakuMask ([string]$twice.Text -eq [string]$bracketed.Masked.Text) '保護済み欄への二度掛けは変わらない'
$literalToken = New-YakuNumericMaskMap -Text '利用者入力 [[N1234]]' -Root $root -Direction 'to_en' -Location 'test'
Assert-YakuMask (-not ([string]$literalToken.Text).Contains('1234') -and [int]$literalToken.MaskedCount -eq 1) '生入力の予約token記法でも数字を迂回できない'

# ---------------------------------------------------------------- 括弧の選び方
# 【】へ戻してはいけない。M365 Copilot は自身の引用参照に【】を使っており、
# 往復するとトークンごと消える（2026-08-05 実機で確認）。
# そのとき単位だけが残り "increased% year on year to  oku." のような英文になる。
# 送信前のマスクは効いたままなので外部への漏れは無いが、訳文が使えなくなる。
#
# ここは往復を伴わないので消える現象そのものは再現できない。
# 「消える括弧を選んでいないこと」だけを見る。
$delimCheck = New-YakuNumericMaskMap -Text '売上高は1,234億円。' -Root $root -Direction 'to_en' -Location 'test'
$delimToken = @([string[]]$delimCheck.Map.Keys)[0]
Assert-YakuMask (-not [string]::IsNullOrWhiteSpace($delimToken)) ('トークンが作られる: ' + $delimToken)
Assert-YakuMask ($delimToken -notmatch '[【】]') 'Copilot が食う【】をトークンに使わない'
Assert-YakuMask ($delimToken -match '^\[\[N\d+\]\]$') ('トークンは [[N1]] 形式: ' + $delimToken)

# 廃止した関数が残っていないこと
foreach ($gone in @('Get-YakuMaskingPlaceholderTokens','Test-YakuMaskingPlaceholderIntegrity','Test-YakuTextResponsePlaceholderIntegrity','Invoke-YakuBackTranslation','New-YakuBackTranslatePrompt','Parse-YakuBackTranslationResponse','Convert-YakuBackTranslationToHtml')) {
    Assert-YakuMask ($null -eq (Get-Command $gone -ErrorAction SilentlyContinue)) ("廃止済み: " + $gone)
}

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
$auditSource = '売上高は[[N1]] oku、比率は[[N2]]％。'
$expectations = @(Get-YakuNumericAuditExpectations -SourceText $auditSource)
Assert-YakuMask (@($expectations | Where-Object { [string]$_.Expected -eq '[[N1]] oku' }).Count -eq 1) '[[N1]] oku を監査対象にする'
Assert-YakuMask (@($expectations | Where-Object { [string]$_.Expected -eq '[[N2]]%' }).Count -eq 1) '[[N2]]% を監査対象にする'
$okAudit = Test-YakuNumericIntegrity -SourceText $auditSource -TranslatedText 'Revenue [[N1]] oku, ratio [[N2]]%.' -Location 'test'
Assert-YakuMask ($okAudit.Ok) 'プレースホルダーが揃えば Ok'
$ngAudit = Test-YakuNumericIntegrity -SourceText $auditSource -TranslatedText 'Revenue oku, ratio %.' -Location 'test'
Assert-YakuMask (-not $ngAudit.Ok) '欠落を検出する'

Write-Host 'CASE 12: 補正指示文に平文の数値を載せない'
$instruction = New-YakuNumericCorrectionInstruction -Audit $ngAudit
Assert-YakuMask ($instruction -match ([regex]::Escape('[[N1]] oku'))) 'プレースホルダーは指示に載る'
Assert-YakuMask (-not ($instruction -match '(?<!N)\d')) ("指示文に素の数字が無い: " + $instruction)

# マスクされなかった数値(年号など)が監査に入っても、指示文へは出さない
$mixedSource = '売上高は[[N1]] oku、前年は72 oku。'
$mixedAudit = Test-YakuNumericIntegrity -SourceText $mixedSource -TranslatedText 'Revenue was oku, prior year oku.' -Location 'test'
Assert-YakuMask ($mixedAudit.Checked -eq 2) '平文の数値も監査自体は拾う'
$mixedInstruction = New-YakuNumericCorrectionInstruction -Audit $mixedAudit
Assert-YakuMask ($mixedInstruction -match ([regex]::Escape('[[N1]]'))) 'プレースホルダーは残る'
Assert-YakuMask (-not ($mixedInstruction -like '*72*')) '平文の数値は指示文から落とす'

$allPlainAudit = Test-YakuNumericIntegrity -SourceText '前年は72 oku。' -TranslatedText 'Prior year oku.' -Location 'test'
Assert-YakuMask ((New-YakuNumericCorrectionInstruction -Audit $allPlainAudit) -eq '') '平文だけなら指示文は空になる'

Write-Host 'CASE 13: to_en プロンプトへプレースホルダー保護規則が入る'
$rulesWith = Get-YakuNumericRulesSection -InputText '売上高は[[N1]] oku。'
Assert-YakuMask ($rulesWith -like '*NUMBER PLACEHOLDERS*') 'プレースホルダーがあれば保護規則を出す'
Assert-YakuMask ($rulesWith -like '*decision table*') '決定表を出す'
Assert-YakuMask ($rulesWith -like '*Positive/additive*') '既存の数値規則も残る'
$rulesWithout = Get-YakuNumericRulesSection -InputText '前年比で増加しました。72 oku。'
Assert-YakuMask (-not ($rulesWithout -like '*NUMBER PLACEHOLDERS*')) 'プレースホルダーが無ければ保護規則は出さない'
Assert-YakuMask ($rulesWithout -like '*Positive/additive*') 'その場合も既存の数値規則は出す'
Assert-YakuMask ((Get-YakuNumericRulesSection -InputText 'これは文章です。') -eq '') '数値関連が無ければ空'

Write-Host 'CASE 14: 復元ヘルパー'
$restoreOptions = @(
    [pscustomobject]@{ Style='full'; Label='FULL'; Translation='Revenue was [[N1]] oku, up [[N2]]%.'; Explanation='' }
    [pscustomobject]@{ Style='brief'; Label='BRIEF'; Translation='Rev. [[N1]] oku (+[[N2]]%)'; Explanation='' }
)
$restoreMap = @{ '[[N1]]' = '11,577'; '[[N2]]' = '3.4' }
$restored = @(Restore-YakuMaskedTranslationOptions -Options $restoreOptions -MaskedSource '売上高は[[N1]] oku、[[N2]]％増。' -Map $restoreMap -Warnings $null -Location 'test')
Assert-YakuMask ($restored[0].Translation -eq 'Revenue was 11,577 oku, up 3.4%.') 'FULL を復元する'
Assert-YakuMask ($restored[1].Translation -eq 'Rev. 11,577 oku (+3.4%)') 'BRIEF を復元する'
Assert-YakuMask (-not ($restored[0].Translation -match '\[\[N\d+\]\]')) '復元後にトークンが残らない'

$lossOptions = @([pscustomobject]@{ Style='full'; Label='FULL'; Translation='Revenue was up.'; Explanation='' })
$lossWarnings = New-Object System.Collections.Generic.List[object]
$null = @(Restore-YakuMaskedTranslationOptions -Options $lossOptions -MaskedSource '売上高は[[N1]] oku。' -Map @{ '[[N1]]' = '72' } -Warnings $lossWarnings -Location 'test')
Assert-YakuMask (@($lossWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-unresolved' }).Count -eq 1) '欠落したら警告を立てる'

Write-Host 'CASE 15: 本文翻訳経路の結線（Copilot 呼び出しを差し替えて確認）'
$script:SentPrompts = New-Object System.Collections.Generic.List[string]
function Invoke-YakuProtectedTransportTestHook {
    # 実機の代わり。プロンプトを記録し、契約に合う応答をそのまま返す。
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $body = [string]([regex]::Match([string]$Prompt, '(?s)SOURCE_BEGIN:[0-9a-fA-F]{32}\s*\n(.*?)\nSOURCE_END:[0-9a-fA-F]{32}').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    if (@($tokens).Count -eq 0) { $tokens = @('115.77', '8.32') }
    if ([string]$Prompt -match 'JAPANESE_TEXT:') {
        $jp = '日本語訳: 売上高はFY' + ([string]$tokens[0]) + '/' + ([string]$tokens[1]) + 'に' + ([string]$tokens[-1]) + '億円でした。'
        return ("JAPANESE_TEXT: $jp" + "`n" + "YAKULINGO_END:$id")
    }
    $safeBody = [regex]::Replace($body, '[ぁ-んァ-ヶ一-龯]+', ' ')
    $line = 'Translated data: ' + $safeBody
    return ("FULL_TEXT: $line" + "`n" + "YAKULINGO_END:$id")
}

$settings = Read-YakuSettings -Root $root
$wiredWarnings = New-Object System.Collections.Generic.List[object]
# 億円は oku へ換算される。百万円はアプリの対象外なので使わない。
$wiredInput = (Convert-YakuNumericUnits -Text '2026年3月期の売上高は115.77億円、営業利益は8.32億円でした。' -Location 'test').Text
Assert-YakuMask ($wiredInput -like '*115.77 oku*') '単位変換が先に効く'
$wired = Invoke-YakuSingleTranslationBatch -Root $root -InputText $wiredInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $wiredWarnings
$sent = [string]$script:SentPrompts[$script:SentPrompts.Count - 1]

Assert-YakuMask ($sent -match ([regex]::Escape('[[N1]]'))) 'プロンプトにプレースホルダーが入る'
Assert-YakuMask (-not ($sent -like '*115.77*')) 'プロンプトに換算後の売上高が出ない'
Assert-YakuMask (-not ($sent -like '*8.32*')) 'プロンプトに換算後の営業利益が出ない'
Assert-YakuMask (-not ($sent -like '*2026年3月期*') -and -not ($sent -like '*FY2026*')) '年度も伏せて送る'
Assert-YakuMask ($sent -like '*NUMBER PLACEHOLDERS*') 'プロンプトに保護規則が入る'
Assert-YakuMask ($wired.Options.Count -eq 1) '通常翻訳は FULL だけ返る'
Assert-YakuMask (([string]$wired.Options[0].Translation) -like '*115.77*') '訳文は実値へ復元されている'
Assert-YakuMask (-not (([string]$wired.Options[0].Translation) -match '\[\[N\d+\]\]')) '訳文にトークンが残らない'

# キャッシュ命中経路でも復元する。ここは別の呼び出し箇所なので個別に見る。
$script:SentPrompts.Clear()
$cached = Invoke-YakuSingleTranslationBatch -Root $root -InputText $wiredInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $wiredWarnings
Assert-YakuMask ([bool]$cached.CacheHit) '2回目はキャッシュに命中する'
Assert-YakuMask ($script:SentPrompts.Count -eq 0) 'キャッシュ命中時は送信しない'
Assert-YakuMask ((@($cached.Options | Where-Object { ([string]$_.Translation) -match '\[\[N\d+\]\]' }).Count) -eq 0) 'キャッシュ命中でもトークンが残らない'
Assert-YakuMask (([string]$cached.Options[0].Translation) -like '*115.77*') 'キャッシュ命中でも実値へ復元する'
Assert-YakuMask (([string]$cached.Raw) -match ([regex]::Escape('[[N1]]'))) 'キャッシュにはマスク後のまま保存する'

# マスク関数の試験用無効化が有効でも、外部送信の直前で必ず止まる。
$env:YAKULINGO_NUMERIC_MASKING = 'off'
try {
    $script:SentPrompts.Clear()
    $disabledSendBlocked = $false
    try { $null = Invoke-YakuSingleTranslationBatch -Root $root -InputText $wiredInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $wiredWarnings }
    catch { $disabledSendBlocked = ($_.Exception.Message -match 'EXTERNAL_SEND_NUMERIC_PROTECTION_DISABLED') }
    Assert-YakuMask $disabledSendBlocked 'マスキング無効時は送信を拒否する'
    Assert-YakuMask ($script:SentPrompts.Count -eq 0) 'マスキング前の本文をCopilotへ渡さない'
} finally { Remove-Item Env:\YAKULINGO_NUMERIC_MASKING -ErrorAction SilentlyContinue }

Write-Host 'CASE 16: to_jp 方向（単位変換の有効化と専用の数値規則）'
$jpRules = Get-YakuNumericRulesSection -InputText 'Net sales were [[N1]] oku.' -Direction 'to_jp'
Assert-YakuMask ($jpRules -like '*NUMBER PLACEHOLDERS*') 'to_jp でも保護規則を出す'
Assert-YakuMask ($jpRules -like '*oku -> 億円*') '単位の日本語表記を指示する'
Assert-YakuMask ($jpRules -like '*never 1億2,340万円*') '桁の繰り上げを禁じる'
Assert-YakuMask ($jpRules -match ([regex]::Escape('▲[[N1]]億円'))) '括弧を▲へ写す指示がある'
Assert-YakuMask (-not ($jpRules -like '*Never million, billion*')) 'to_en 専用の規則は混ぜない'

# to_jp でも単位変換を通す（日英混在資料を想定）
$jpPre = (Convert-YakuNumericUnits -Text 'Sales reached 115.77億円 in the period.' -Location 'test').Text
Assert-YakuMask ($jpPre -like '*115.77 oku*') 'to_jp 入力の日本語単位も正規化される'

$script:SentPrompts.Clear()
$jpWarnings = New-Object System.Collections.Generic.List[object]
$jpInput = (Convert-YakuNumericUnits -Text 'Net sales for FY2026/3 were 115.77億円.' -Location 'test').Text
$jpResult = Invoke-YakuSingleTranslationBatch -Root $root -InputText $jpInput -Settings $settings -Direction 'to_jp' -StyleReference '' -Warnings $jpWarnings
$jpSent = [string]$script:SentPrompts[$script:SentPrompts.Count - 1]
Assert-YakuMask ($jpSent -match ([regex]::Escape('[[N1]]'))) 'to_jp のプロンプトにもプレースホルダーが入る'
Assert-YakuMask (-not ($jpSent -like '*115.77*')) 'to_jp のプロンプトに実値が出ない'
Assert-YakuMask (-not ($jpSent -like '*FY2026/3*')) 'to_jp でも会計期を伏せる'
Assert-YakuMask ($jpSent -like '*oku -> 億円*') 'to_jp のプロンプトに単位表記の指示が入る'
Assert-YakuMask (@($jpResult.Options).Count -eq 1) 'JAPANESE の1件が返る'
Assert-YakuMask (([string]$jpResult.Options[0].Translation) -like '*115.77*') 'to_jp でも実値へ復元する'

Write-Host 'CASE 17: CAT翻訳経路（プロンプトと復元）'
# 実ファイルを使わず、CAT専用経路の構成要素を直接確認する。
$fileItems = @(
    [pscustomobject]@{ Index=1; Text='2026年3月期の売上高は115.77億円' }
    [pscustomobject]@{ Index=2; Text='営業利益率は8.3%' }
)
foreach ($fi in $fileItems) {
    $fi | Add-Member -NotePropertyName BlockIds -NotePropertyValue (New-Object System.Collections.Generic.List[string]) -Force
}
$null = Protect-YakuCatItems -Items $fileItems -Root $root -Direction 'to_en'
$filePrompt = New-YakuCatPrompt -Root $root -Items $fileItems -Settings $settings -Direction 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuMask ($filePrompt -match ([regex]::Escape('[[N1]]'))) 'CAT用プロンプトにプレースホルダーが入る'
Assert-YakuMask (-not ($filePrompt -like '*115.77*')) 'CAT用プロンプトに実値が出ない'
Assert-YakuMask (-not ($filePrompt -like '*8.3%*')) 'CAT用プロンプトに比率の実値が出ない'
Assert-YakuMask (-not ($filePrompt -like '*2026年3月期*')) 'CATでも会計期を伏せる'
Assert-YakuMask ($filePrompt -like '*NUMBER PLACEHOLDERS*') 'CAT用プロンプトに保護規則が入る'
Assert-YakuMask ($filePrompt -match 'complete|省略') 'CAT用プロンプトは正本の完全訳を要求する'
Assert-YakuMask (-not ($filePrompt -like '*{numeric_rules}*')) 'テンプレート変数が残らない'

# to_jp のCAT用テンプレートも同様に展開される
$filePromptJp = New-YakuCatPrompt -Root $root -Items $fileItems -Settings $settings -Direction 'to_jp' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuMask ($filePromptJp -like '*oku -> 億円*') 'to_jp のCAT用プロンプトに単位表記の指示が入る'
Assert-YakuMask (-not ($filePromptJp -like '*{numeric_rules}*')) 'to_jp でもテンプレート変数が残らない'

# 復元
$fileTranslations = @{ 1 = 'Net sales for FY[[N1]]/[[N2]] were [[N3]] oku'; 2 = 'OPM [[N1]]%' }
foreach ($fi in $fileItems) {
    $fi | Add-Member -NotePropertyName Targets -NotePropertyValue @([int]$fi.Index - 1) -Force
}
Restore-YakuCatItemTranslations -Items $fileItems -Map $fileTranslations -Warnings $null
Assert-YakuMask ($fileTranslations[1] -eq 'Net sales for FY2026/3 were 115.77 oku') 'CAT訳文の年度と金額を実値へ復元する'
Assert-YakuMask ($fileTranslations[2] -eq 'OPM 8.3%') '項目ごとに別のマップで復元する'

Write-Host 'CASE 18: 契約フィンガープリントがマスク状態を含む'
$fpOn = Get-YakuTranslationContractFingerprint -Root $root -Settings $settings
$env:YAKULINGO_NUMERIC_MASKING = 'off'
try { $fpOff = Get-YakuTranslationContractFingerprint -Root $root -Settings $settings }
finally { Remove-Item Env:\YAKULINGO_NUMERIC_MASKING -ErrorAction SilentlyContinue }
$fpBack = Get-YakuTranslationContractFingerprint -Root $root -Settings $settings
Assert-YakuMask ($fpOn -ne $fpOff) 'マスクの有無で指紋が変わる'
Assert-YakuMask ($fpOn -eq $fpBack) '戻せば同じ指紋になる（メモ化が状態を無視しない）'

Write-Host 'CASE 19: BRIEF は警告のみ / FULL は再試行対象（決定事項#3・#12）'
$briefMap = @{ '[[N1]]' = '115.77'; '[[N2]]' = '296' }
$briefSource = '売上高は[[N1]] oku、うち海外は[[N2]] oku。'

# BRIEF で数値が落ちた場合: 平文つきの専用警告を出し、訳文へ数値を挿入しない
$briefOptions = @(
    [pscustomobject]@{ Style='full'; Label='FULL'; Translation='Net sales [[N1]] oku, overseas [[N2]] oku.'; Explanation='' }
    [pscustomobject]@{ Style='brief'; Label='BRIEF'; Translation='Net sales [[N1]] oku.'; Explanation='' }
)
$briefWarnings = New-Object System.Collections.Generic.List[object]
$briefRestored = @(Restore-YakuMaskedTranslationOptions -Options $briefOptions -MaskedSource $briefSource -Map $briefMap -Warnings $briefWarnings -Location 'test')
$briefWarn = @($briefWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-dropped-brief' })
Assert-YakuMask ($briefWarn.Count -eq 1) 'BRIEF 専用の警告カテゴリで出す'
Assert-YakuMask (([string]$briefWarn[0].Message) -match ([regex]::Escape('[[N2]]（296）'))) '落ちた数値を平文つきで示す'
Assert-YakuMask (([string]$briefRestored[1].Translation) -eq 'Net sales 115.77 oku.') '落ちた数値を訳文へ挿入しない'
Assert-YakuMask (([string]$briefRestored[0].Translation) -eq 'Net sales 115.77 oku, overseas 296 oku.') 'FULL は通常どおり復元する'
Assert-YakuMask (@($briefWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-unresolved' }).Count -eq 0) 'BRIEF の欠落は unresolved 扱いにしない'

# FULL で落ちた場合は unresolved 警告
$fullOptions = @([pscustomobject]@{ Style='full'; Label='FULL'; Translation='Net sales [[N1]] oku.'; Explanation='' })
$fullWarnings = New-Object System.Collections.Generic.List[object]
$null = @(Restore-YakuMaskedTranslationOptions -Options $fullOptions -MaskedSource $briefSource -Map $briefMap -Warnings $fullWarnings -Location 'test')
Assert-YakuMask (@($fullWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-unresolved' }).Count -eq 1) 'FULL の欠落は unresolved 警告'

# 原文に無い番号を作られた場合は取り除く
$inventedOptions = @([pscustomobject]@{ Style='brief'; Label='BRIEF'; Translation='Net sales [[N1]] oku and [[N9]] oku.'; Explanation='' })
$inventedWarnings = New-Object System.Collections.Generic.List[object]
$inventedRestored = @(Restore-YakuMaskedTranslationOptions -Options $inventedOptions -MaskedSource $briefSource -Map $briefMap -Warnings $inventedWarnings -Location 'test')
Assert-YakuMask (-not (([string]$inventedRestored[0].Translation) -match '\[\[N\d+\]\]')) '原文に無い番号は訳文から取り除く'
Assert-YakuMask (@($inventedWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-unresolved' }).Count -eq 1) '混入は unresolved 警告'

# 経路: BRIEF だけ落ちても再試行せず完走する
$script:SentPrompts.Clear()
function Invoke-YakuProtectedTransportTestHook {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    $brief = 'Net sales ' + ([string]$tokens[0]) + ' oku.'
    return ("BRIEF_TEXT: $brief" + "`n" + "YAKULINGO_END:$id")
}
$briefJobWarnings = New-Object System.Collections.Generic.List[object]
$briefJobInput = (Convert-YakuNumericUnits -Text '売上高は115.77億円、営業利益は8.32億円でした。' -Location 'test').Text
$briefJob = Invoke-YakuSingleTranslationBatch -Root $root -InputText $briefJobInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $briefJobWarnings -Mode 'brief'
Assert-YakuMask ($script:SentPrompts.Count -eq 1) 'BRIEF の欠落では再送しない'
Assert-YakuMask (([string]$briefJob.Options[0].Translation) -eq 'Net sales 115.77 oku.') 'BRIEF はそのまま復元して返す'
Assert-YakuMask (@($briefJobWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-dropped-brief' }).Count -eq 1) 'BRIEF 警告が結果に載る'

# 経路: FULL が落ちたら再送する
$script:SentPrompts.Clear()
$script:FullAttempt = 0
function Invoke-YakuProtectedTransportTestHook {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $script:FullAttempt++
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    $complete = 'Net sales ' + ([string]$tokens[0]) + ' oku, operating profit ' + ([string]$tokens[-1]) + ' oku.'
    # 1回目は FULL から2つ目のプレースホルダーを落とす
    $full = if ($script:FullAttempt -eq 1) { 'Net sales ' + ([string]$tokens[0]) + ' oku.' } else { $complete }
    return ("FULL_TEXT: $full" + "`n" + "YAKULINGO_END:$id")
}
$fullJobWarnings = New-Object System.Collections.Generic.List[object]
# 上の節と同じ構造の文はキャッシュを共有する（下の CASE 20 で確認する）。
# 再送そのものを見たいので、構造ごと違う文を使う。
$fullJobInput = (Convert-YakuNumericUnits -Text '国内販売台数は223.4千台、輸出は9.9千台となりました。' -Location 'test').Text
$fullJob = Invoke-YakuSingleTranslationBatch -Root $root -InputText $fullJobInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $fullJobWarnings
Assert-YakuMask ($script:SentPrompts.Count -ge 2) 'FULL の欠落では再送する'
Assert-YakuMask (([string]$fullJob.Options[0].Translation) -like '*223.4*9.9*') '再送後の FULL は数値が揃う'

Write-Host 'CASE 20: 大きさだけが違う定型文はキャッシュを共有する（§7の副次効果）'
# マスク後は「売上高は[[N1]] oku、営業利益は[[N2]] oku。」で一致するため、
# 数値の異なる同型の文が同じキャッシュ項目に当たる。表項目の多い資料で効く。
$script:SentPrompts.Clear()
$shareA = (Convert-YakuNumericUnits -Text '売上高は500.5億円、営業利益は44.4億円でした。' -Location 'test').Text
$shareB = (Convert-YakuNumericUnits -Text '売上高は777.7億円、営業利益は12.3億円でした。' -Location 'test').Text
$resA = Invoke-YakuSingleTranslationBatch -Root $root -InputText $shareA -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $fullJobWarnings
$sentAfterA = $script:SentPrompts.Count
$resB = Invoke-YakuSingleTranslationBatch -Root $root -InputText $shareB -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $fullJobWarnings
Assert-YakuMask ($script:SentPrompts.Count -eq $sentAfterA) '2文目は送信しない'
Assert-YakuMask ([bool]$resB.CacheHit) '2文目はキャッシュに命中する'
Assert-YakuMask (([string]$resA.Options[0].Translation) -like '*500.5*44.4*') '1文目は自分の数値へ復元する'
Assert-YakuMask (([string]$resB.Options[0].Translation) -like '*777.7*12.3*') '2文目は自分の数値へ復元する'
Assert-YakuMask (-not (([string]$resB.Options[0].Translation) -like '*500.5*')) '他の文の数値が混ざらない'
Assert-YakuMask (@($fullJobWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-unresolved' }).Count -eq 0) '解消すれば警告は残らない'

Write-Host 'CASE 20A: 補助欄も共通envelopeの前でマスクする'
# 原文だけをマスク表へ入れていた時期は、StyleReference / CorpusSection と
# クライアントから戻る CurrentText が最終promptへ平文で混入した。このstubは
# protected adapterのさらに下、実transport相当で受け取った文字列だけを記録する。
$script:SentPrompts.Clear()
function Invoke-YakuProtectedTransportTestHook {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [string]$AnswerFormat, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    if ([string]$Prompt -match 'INSTRUCTION_BEGIN:') {
        return ("FULL_TEXT: Revenue was $([string]$tokens[0]) million yen.`nYAKULINGO_END:$id")
    }
    if ([string]$Prompt -match 'CURRENT_BEGIN:') {
        return ("BRIEF_TEXT: Rev. $([string]$tokens[0]) mn yen; stable.`nYAKULINGO_END:$id")
    }
    return ("FULL_TEXT: Performance is explained.`nYAKULINGO_END:$id")
}

$auxWarnings = New-Object System.Collections.Generic.List[object]
$quickAux = Invoke-YakuSingleTranslationBatch -Root $root -InputText '補助欄保護の業績説明です。' -Settings $settings -Direction 'to_en' `
    -StyleReference 'STYLE: 極秘売上高は1,234百万円です。' -CorpusSection 'CORPUS: 極秘計画は7,777台です。' -Warnings $auxWarnings
$quickAuxPrompt = [string]$script:SentPrompts[0]
Assert-YakuMask ($script:SentPrompts.Count -eq 1 -and @($quickAux.Options).Count -eq 1) 'Quick は保護済みpromptをtransportへ1回送って正常終了する'
Assert-YakuMask (-not ($quickAuxPrompt -like '*1,234*')) 'Quick StyleReference の1,234はtransportへ平文で到達しない'
Assert-YakuMask (-not ($quickAuxPrompt -like '*7,777*')) 'Quick CorpusSection の7,777はtransportへ平文で到達しない'
Assert-YakuMask ($quickAuxPrompt -match ([regex]::Escape('[[N1]]')) -and $quickAuxPrompt -match ([regex]::Escape('[[N2]]'))) 'Quick の補助欄は別々の数値tokenとして送る'

# 既存mapがある状態で補助欄に2値以上を足すと、N1→N2 のあと元N2まで
# N3へ置き換える連鎖が起きていた。数値tokenが一意なまま復元できること。
$collisionNumericMap = @{ '[[N1]]' = '1,111' }
$collisionProtected = Protect-YakuPromptField `
    -Text 'Revenue was 1,111 million yen; profit was 2,222 million yen. あずさ監査法人と毛籠。' `
    -Root $root -Direction 'to_en' -NumericMap $collisionNumericMap -Location 'test-token-renumber'
Assert-YakuMask ($collisionProtected.Contains('[[N2]] million yen; profit was [[N3]]')) ('補助欄の複数数値tokenは連鎖せず出現順を保つ: ' + $collisionProtected)
Assert-YakuMask ($collisionProtected.Contains('あずさ監査法人') -and $collisionProtected.Contains('毛籠')) '補助欄の固有名詞はマスクしない'
$collisionRestored = Restore-YakuNumericMask -Text $collisionProtected -Map $collisionNumericMap
Assert-YakuMask ($collisionRestored -eq 'Revenue was 1,111 million yen; profit was 2,222 million yen. あずさ監査法人と毛籠。') ('補助欄の数値を元の値と位置へ完全復元する: ' + $collisionRestored)

$reviseAux = Invoke-YakuTextRevision -Root $root -InputText '補助欄保護の業績説明です。' `
    -CurrentText 'Revenue was 9,999 million yen.' -Instruction '文体だけを整える' -Settings $settings -Direction 'to_en' -Style 'full' -Warnings $auxWarnings
$reviseAuxPrompt = [string]$script:SentPrompts[1]
Assert-YakuMask ($script:SentPrompts.Count -eq 2 -and @($reviseAux.Options).Count -eq 1) 'revise は保護済みpromptをtransportへ1回送って正常終了する'
Assert-YakuMask (-not ($reviseAuxPrompt -like '*9,999*')) 'revise CurrentText の9,999はtransportへ平文で到達しない'
Assert-YakuMask ($reviseAuxPrompt -match ([regex]::Escape('[[N1]]'))) 'revise CurrentText は数値tokenとして送る'
Assert-YakuMask (([string]$reviseAux.Options[0].Translation) -like '*9,999*') 'revise の応答はCurrentText由来の実値へ復元する'

$shortenAux = Invoke-YakuTextShorten -Root $root -InputText '補助欄保護の販売状況です。' `
    -MaskedCurrentText 'Revenue was 8,888 million yen and remained stable throughout the period.' -Settings $settings -Warnings $auxWarnings
$shortenAuxPrompt = [string]$script:SentPrompts[2]
Assert-YakuMask ($script:SentPrompts.Count -eq 3 -and @($shortenAux.Options).Count -eq 1) 'shorten は保護済みpromptをtransportへ1回送って正常終了する'
Assert-YakuMask (-not ($shortenAuxPrompt -like '*8,888*')) 'shorten CurrentText の8,888はtransportへ平文で到達しない'
Assert-YakuMask ($shortenAuxPrompt -match ([regex]::Escape('[[N1]]'))) 'shorten CurrentText は数値tokenとして送る'
Assert-YakuMask (([string]$shortenAux.Options[0].Translation) -like '*8,888*') 'shorten の応答はCurrentText由来の実値へ復元する'

Write-Host 'CASE 21: UI 表示（仕様書 §9）'
# 件数の告知
$noticeResult = [pscustomobject]@{ MaskedCount = 12; KeptCount = 3 }
$notice = New-YakuMaskingNoticeHtml -Result $noticeResult
Assert-YakuMask ($notice -like '*数値 12 件をマスクして送信しました*') 'マスク件数を表示する'
Assert-YakuMask ($notice -like '*符号と単位は送信しています*') '何が送られるかを明示する'
Assert-YakuMask ($notice -like '*3 件はそのまま送信*') '非マスク件数も示す'
Assert-YakuMask ((New-YakuMaskingNoticeHtml -Result ([pscustomobject]@{ MaskedCount = 0; KeptCount = 0 })) -eq '') 'マスクが無ければ何も出さない'
Assert-YakuMask ((New-YakuMaskingNoticeHtml -Result $null) -eq '') '結果が無くても落ちない'

# 経路の戻り値に件数が載る
$script:SentPrompts.Clear()
$countWarnings = New-Object System.Collections.Generic.List[object]
$countInput = (Convert-YakuNumericUnits -Text '2026年3月期の売上は318.2億円、営業利益は27.4億円、比率は8.6%でした。' -Location 'test').Text
$countResult = Invoke-YakuTextTranslation -Root $root -InputText $countInput -Settings $settings -ProgressState $null -DirectionOverride 'to_en'
Assert-YakuMask ([int]$countResult.MaskedCount -eq 5) ('年度を含むマスク件数が結果に載る: ' + [string]$countResult.MaskedCount)
Assert-YakuMask ([int]$countResult.KeptCount -eq 0) '入力数値の非マスク例外はない'
$resultHtml = Convert-YakuTextResultToHtml -Result $countResult
Assert-YakuMask ($resultHtml -like '*数値 5 件をマスクして送信しました*') '結果画面へ年度を含む件数が出る'

# 警告カテゴリの表示名

# 一般画面の説明
$indexHtml = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'index.html') -Raw -Encoding UTF8
Assert-YakuMask ($indexHtml -like '*金額などの数値は、Copilotへ送る前に自動で伏せます*') '利用者向けの言葉で自動保護を説明する'
Assert-YakuMask (-not ($indexHtml -match 'プレースホルダー|122 oku|amount-notation')) '内部用語や未完成の金額設定を一般画面へ出さない'

Write-Host 'CASE 22: 受容基準の残り（仕様書 §10）'

# §10-3-b 決算期に似ているが別物の形はマスクする
foreach ($c in @(@{ Text='取引先は151件です。'; Gone='151' }, @{ Text='売上3億円の案件。'; Gone='3' })) {
    $r = Invoke-YakuMaskPipeline -Text ([string]$c.Text)
    Assert-YakuMask (-not ([string]$r.Masked.Text -like ('*' + $c.Gone + '*'))) ("決算期に似た形はマスク: " + $c.Text + ' -> ' + $r.Masked.Text)
}

# 数字を含む用語でも数字だけを伏せ、非数値部分は保持する。
$cx = Invoke-YakuMaskPipeline -Text 'MTMUS製(CX-50)の単価改善は120億円。'
Assert-YakuMask (([string]$cx.Masked.Text).Contains('MTMUS製(CX-[[N1]])')) ('用語の数字だけを伏せる: ' + $cx.Masked.Text)
Assert-YakuMask (-not ([string]$cx.Masked.Text -like '*120*')) '同じ文の金額はマスクする'
$fyq = Invoke-YakuMaskPipeline -Text 'FY26/3 1Q の AAT 営業利益(50%)は堅調。'
Assert-YakuMask (-not (([string]$fyq.Masked.Text).Contains('FY26/3 1Q')) -and ([string]$fyq.Masked.Text).Contains('FY[[N1]]/[[N2]] [[N3]]Q')) 'FY・四半期の数字も伏せる'

# §10-19-b 変換後の単位トークンがマスクされ、復元で戻る
foreach ($t22 in @('出荷台数は659千台。', '生産は2万台。')) {
    $r = Invoke-YakuMaskPipeline -Text $t22
    Assert-YakuMask ([string]$r.Masked.Text -like '*k units*') ("k units が残る: " + $r.Masked.Text)
    Assert-YakuMask ((Restore-YakuNumericMask -Text $r.Masked.Text -Map $r.Masked.Map) -eq $r.Pre) ("復元一致: $t22")
}

# §10-20 復元後は原文どおりの字形で戻る（全角のまま）
$widthSource = '上位１０社と取引しています。'
$width = New-YakuNumericMaskMap -Text $widthSource -Root $root -Direction 'to_en' -Location 'test'
Assert-YakuMask ([int]$width.MaskedCount -eq 1) '全角数字もマスクする'
Assert-YakuMask ((Restore-YakuNumericMask -Text ([string]$width.Text) -Map $width.Map) -eq $widthSource) '全角の字形のまま戻る'

# §10-22 バッチ分割がプレースホルダーの内部で切れない
# マスクは分割の後に掛かるので構造的に起こらない。経路の順序ごと確認する。
$longRow = ((1..400 | ForEach-Object { "項目$_" + 'は' + (1000 + $_) + '億円' }) -join '、')
$longPre = (Convert-YakuNumericUnits -Text $longRow -Location 'test').Text
$longBatches = @(Split-YakuTextBatches -Text $longPre -MaxChars 400)
Assert-YakuMask ($longBatches.Count -gt 1) ("複数バッチに分かれる: " + $longBatches.Count)
$rejoined = ''
$cutToken = 0
foreach ($lb in $longBatches) {
    $lm = New-YakuNumericMaskMap -Text ([string]$lb.Text) -Root $root -Direction 'to_en' -Location 'test'
    $mt = [string]$lm.Text
    # 途中で切れたトークンの痕跡（末尾の [[N…、先頭の …]]）が無いこと
    if ($mt -match '\[\[N\d*$' -or $mt -match '^\d*\]\]') { $cutToken++ }
    $rejoined += (Restore-YakuNumericMask -Text $mt -Map $lm.Map)
}
Assert-YakuMask ($cutToken -eq 0) 'バッチ境界でプレースホルダーが切れない'
Assert-YakuMask ($rejoined -eq $longPre) '全バッチを復元して結合すると元に戻る'

# §10-21 Copilot 呼び出しが翻訳経路とその再試行だけになっている
$callSites = @()
foreach ($srcFile in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1')) {
    $lines = @(Get-Content -LiteralPath $srcFile.FullName -Encoding UTF8)
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $line = [string]$lines[$li]
        if ($line -notmatch 'Invoke-YakuProtectedCopilotPrompt') { continue }
        if ($line -match 'function Invoke-YakuProtectedCopilotPrompt' -or $line -match 'Get-Command Invoke-YakuProtectedCopilotPrompt') { continue }
        $callSites += ($srcFile.Name)
    }
}
# V91.61 段階3: CorpusReference.ps1 が加わる。参考資料を引くための検索語を
# Copilot に作らせる経路で、原文を外部へ送る点は翻訳と同じ。
# 送る前にマスクしていることを下で確かめる。
# V91.61: Alignment.ps1 が加わる。日英の対を Copilot に取らせる経路で、
# 原文を外部へ送る点は翻訳と同じ。こちらは値を戻さない非可逆マスクを使う
# （返るのは行番号だけで復元が要らないため、安全側に倒せる）。
$outside = @($callSites | Where-Object { $_ -notin @('CopilotClient.ps1','Translation.ps1','CatBatch.ps1','CorpusReference.ps1','Alignment.ps1') })
Assert-YakuMask ($outside.Count -eq 0) ("翻訳経路の外から呼ばれていない: " + (@($outside | Select-Object -Unique) -join ','))

# 許可しただけでは統制にならない。Alignment.ps1 が実際にマスクを通してから
# 送っていることを確かめる。原文の変数をそのまま渡す形へ書き換えられたら、
# ここで落ちる。
# 「どのファイルが Copilot を呼ぶか」だけでは足りない。CAT は Copilot を
# 直接呼ばず、CatBatch.ps1 の内側の関数を呼ぶので許可一覧では捕まらず、
# その関数はマスクを通っていなかった。実数値のまま送っていたことに、
# 2026-08-08 まで気づけなかった。呼び出し元ごとにマスクを確かめる。
$catSrc = Get-Content -LiteralPath (Join-Path $root 'src\CatProject.ps1') -Raw -Encoding UTF8
Assert-YakuMask ($catSrc -match 'New-YakuNumericMaskMap') 'CAT 経路が送信前にマスクを作る'
Assert-YakuMask ($catSrc -match 'Restore-YakuNumericMask') 'CAT 経路が訳文の数値を戻す'
Assert-YakuMask ($catSrc -match 'Test-YakuNumericMaskIntegrity') 'CAT 経路が数値の個数を確かめる'
# 専用入口は保護済みitemを検査してから共通バッチへ渡す。
$catFacadeSrc = Get-Content -LiteralPath (Join-Path $root 'src\CatTranslation.ps1') -Raw -Encoding UTF8
$catAssertAt = $catFacadeSrc.IndexOf('Assert-YakuCatProtectedItems -Items')
$catSendAt = $catFacadeSrc.IndexOf('Invoke-YakuTranslationBatchItems -Root')
Assert-YakuMask ($catAssertAt -gt 0 -and $catSendAt -gt 0 -and $catAssertAt -lt $catSendAt) 'CAT 経路は保護済みpayloadを検査してから送信する'

# 静的な順序だけでなく、実際の中継関数へ複合単位を通す。以前は
# 18万6千台 が [[N1]]万[[N2]]千台 に割れ、モデルへ日本語の桁が残っていた。
$catUnitItem = [pscustomobject]@{ Index = 1; Text = '販売台数は18万6千台。' }
$null = Protect-YakuCatItems -Items @($catUnitItem) -Root $root -Direction 'to_en'
Assert-YakuMask ([string]$catUnitItem.MaskedText -match '\[\[N1\]\]\s+k units') ('CAT でも複合単位を1つに畳んでから伏せる: ' + [string]$catUnitItem.MaskedText)
Assert-YakuMask ([string]$catUnitItem.MaskedText -notmatch '[万千]') 'CAT の送信本文に日本語の桁を残さない'
$catUnitMap = @{ 1 = 'Sales volume was [[N1]] k units.' }
Restore-YakuCatItemTranslations -Items @($catUnitItem) -Map $catUnitMap -Warnings $null
Assert-YakuMask ([string]$catUnitMap[1] -match '186\s+k units') ('CAT の訳文へ複合数量を復元する: ' + [string]$catUnitMap[1])
Assert-YakuMask ([string]$catUnitItem.MaskedTranslation -match '\[\[N1\]\]') 'CAT の推敲用に実値復元前の訳文を保持する'

$alignSrc = Get-Content -LiteralPath (Join-Path $root 'src\Alignment.ps1') -Raw -Encoding UTF8
Assert-YakuMask ($alignSrc -match 'Protect-YakuAlignmentLines') 'アライメント経路がマスクを呼んでいる'
Assert-YakuMask ($alignSrc -match "New-YakuProtectedPromptPackage\s+-Kind\s+alignment" -and
    $alignSrc -match 'ProtectedText=\[string\]\$jaMasked' -and
    $alignSrc -match 'ProtectedText=\[string\]\$enMasked') 'アライメント経路がマスク済みの行だけを渡している'

# 外部へ送る経路が増えたら、そこもマスクを通っていること。
# 経路を足すたびに手で思い出す話にしない。
$corpusRefText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CorpusReference.ps1'))
$maskAt = $corpusRefText.IndexOf('New-YakuNumericMaskMap')
$sendAt = $corpusRefText.IndexOf('Invoke-YakuProtectedCopilotPrompt')
Assert-YakuMask ($maskAt -ge 0) 'コーパス検索語の経路もマスクを呼ぶ'
Assert-YakuMask ($sendAt -ge 0 -and $maskAt -lt $sendAt) 'マスクしてから送っている'
Assert-YakuMask ($corpusRefText -match "Location 'corpus-query'") '記録に経路名が残る（どこでマスクしたか分かる）'
# V91.61（2026-08-06）: 修正の依頼が2箇所目になる。訳文へ指示を1つ当てて直す
# 経路で、原文と現訳を外部へ送る点は翻訳と同じ。件数で見張るのは、
# 送る経路が黙って増えるのを気づかせるため。増やすときは下の確認も足すこと。
# 3箇所目は「短くする」（Invoke-YakuTextShorten）。現訳をマスク後の姿で
# 受け取る点も修正と同じで、専用の検査は Test-YakuV9161Shorten.ps1 にある。
$translationSends = @($callSites | Where-Object { $_ -eq 'Translation.ps1' }).Count
Assert-YakuMask ($translationSends -eq 3) ('テキスト経路の送信は3箇所（翻訳・修正・短くする）: ' + $translationSends)
# 修正の経路もマスクしてから送っていること。現訳は呼び出し側から
# マスク後の姿で渡ってくるが、原文はここでマスクする。
$translationSrc = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Translation.ps1'))
$reviseFn = [regex]::Match($translationSrc, '(?s)function Invoke-YakuTextRevision \{.*?\n\}\r?\n\r?\nfunction ').Value
Assert-YakuMask ($reviseFn.Length -gt 0) '修正の経路が見つかる'
$rMask = $reviseFn.IndexOf('New-YakuNumericMaskMap')
$rSend = $reviseFn.IndexOf('Invoke-YakuProtectedCopilotPrompt')
Assert-YakuMask ($rMask -ge 0 -and $rSend -ge 0 -and $rMask -lt $rSend) '修正の経路もマスクしてから送っている'
Assert-YakuMask ($reviseFn -match "Location 'text-revise'") '修正の経路にも経路名が残る'

# ---------------------------------------------------------------------------
# 経路ごとの統制を、経路を足したら必ず落ちる形にする。
#
# これまでの確認は経路ごとに手で書いていた。だから経路が増えるたびに
# 書き忘れを防ぐため、表に載っていない送信経路が
# 現れたら落ちる形にして、手で思い出す話をやめる。
Write-Host '送信経路ごとの統制（表に無い経路が現れたら落ちる）' -ForegroundColor Cyan

# 送信経路と、その経路に要るもの。
#   Numeric  数値マスクを通してから送る
# Alignment は AlignMask.ps1 の破壊的マスクを使う（戻さない経路なので別物）。
$sendingPaths = @(
    @{ File = 'Translation.ps1';     Numeric = 'New-YakuNumericMaskMap' }
    @{ File = 'CatProject.ps1';      Numeric = 'New-YakuNumericMaskMap' }
    @{ File = 'CorpusReference.ps1'; Numeric = 'New-YakuNumericMaskMap' }
    @{ File = 'Alignment.ps1';       Numeric = 'Protect-YakuAlignmentLines' }
    # ジョブのランスペースから直接送る経路。CAT の「残りを訳す」はここを通る。
    # 自分では伏せず、切り出した Protect-YakuCatItems へ委ねる。順序は下で別に見る。
    @{ File = 'Server.ps1';          Numeric = 'Protect-YakuCatItems' }
)
# 中継そのもの。CatBatch は専用入口を通ったことを内部でも検査する。
$transportOnly = @('CopilotClient.ps1',  'CatBatch.ps1')

$listed = @(@($sendingPaths | ForEach-Object { [string]$_.File }) + $transportOnly)
$unlisted = @(@($callSites | Select-Object -Unique) | Where-Object { $_ -notin $listed })
Assert-YakuMask ($unlisted.Count -eq 0) ('表に無い送信経路が増えていない: ' + (@($unlisted) -join ','))

# ---------------------------------------------------------------------------
# CATは共通バッチの内側でCopilotを呼ぶため、呼び出し元と専用入口の
# 両方を検査する。ファイル単位の送信箇所一覧だけでは保護を保証できない。
$translationSrcFile = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CatBatch.ps1'))
$catTranslationSrc = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CatTranslation.ps1'))
Assert-YakuMask ($translationSrcFile -match 'CAT_TRANSLATION_FACADE_REQUIRED') '共通バッチはCAT専用入口を通さない呼出しを拒否する'
Assert-YakuMask ($catTranslationSrc -match 'Assert-YakuCatProtectedItems') 'CAT専用入口が保護済みpayloadを検査する'

# 実際に走る経路（ジョブ側）が伏せてから送っていること。
# ここが抜けていた当人なので、名指しで確かめる。
$serverSrc = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
$catSendAt = $serverSrc.IndexOf('Invoke-YakuCatTranslationItems -Root')
Assert-YakuMask ($catSendAt -ge 0) 'ジョブ側の CAT 送信箇所が見つかる'
$catHead = $serverSrc.Substring([Math]::Max(0, $catSendAt - 3000), [Math]::Min(3000, $catSendAt))
Assert-YakuMask ($catHead -match 'Protect-YakuCatItems') 'ジョブ側は送信の直前に伏せている'
$catTail = $serverSrc.Substring($catSendAt, [Math]::Min(900, $serverSrc.Length - $catSendAt))
Assert-YakuMask ($catTail -match 'Restore-YakuCatItemTranslations') 'ジョブ側は訳文を実値へ戻している'

foreach ($p in $sendingPaths) {
    $file = [string]$p.File
    $src = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') $file))
    # ファイル全体での出現位置で順序を見てはいけない。関数の定義そのものや、
    # 別の呼び出し元を拾って、通ったり落ちたりする（2026-08-08 に踏んだ）。
    # ここで見るのは「その経路にマスクがあるか」だけにする。
    Assert-YakuMask ($src -match [regex]::Escape([string]$p.Numeric)) ($file + ': 数値マスクを呼ぶ')
}

Write-Host 'Copilot の呼び出し回数を数える' -ForegroundColor Cyan
# 120回ほどで応答しなくなるのに、回数を1度も数えていなかった。
# 数えていないと、制限に当たったのかこちらの不具合かを切り分けられない。
$clientSrc = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CopilotClient.ps1'))
Assert-YakuMask ($clientSrc -match 'Add-YakuCopilotCall') '送信のたびに回数を記録する'
$countAt = $clientSrc.IndexOf('Add-YakuCopilotCall')
$mockAt = $clientSrc.IndexOf("YAKULINGO_MOCK -eq '1'")
Assert-YakuMask ($mockAt -ge 0 -and $mockAt -lt $countAt) '模擬経路は数えない（回帰テストで数が増えない）'
$budgetSrc = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CopilotBudget.ps1'))
Assert-YakuMask ($budgetSrc -notmatch 'Prompt|Translation') '記録するのは時刻だけ（本文を残さない）'
. (Join-Path (Join-Path $root 'src') 'CopilotBudget.ps1')
$script:YakuBudgetTestLog = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-budget-' + [guid]::NewGuid().ToString('N') + '.log')
function Get-YakuCopilotCallLogPath { return $script:YakuBudgetTestLog }
$fixedNow = [datetime]'2026-08-09T12:00:00'
[IO.File]::WriteAllLines($script:YakuBudgetTestLog, @(
        '2026-08-09T08:59:59', '2026-08-09T09:00:00',
        '2026-08-09T10:30:00', '2026-08-09T11:59:00', 'broken-line'
    ), [Text.UTF8Encoding]::new($false))
Assert-YakuMask ((Get-YakuCopilotCallCount -Now $fixedNow -WindowHours 3) -eq 3) '直近3時間は境界を含め、不正行と境界前を除外する'
$null = Add-YakuCopilotCall -Now $fixedNow
Assert-YakuMask ((Get-YakuCopilotCallCount -Now $fixedNow -WindowHours 3) -eq 4) '1時間集計を挟んでも3時間分の履歴を保持する'
Remove-Item -LiteralPath $script:YakuBudgetTestLog -Force -ErrorAction SilentlyContinue
# 使いすぎに見える失敗をリトライすると、残りをさらに削る。
Assert-YakuMask ($translationSrc -match 'Test-YakuCopilotLimitError') '制限らしい失敗ではリトライを止める'
# 順序はリトライの catch の中だけを見る。ファイル全体で位置を比べると、
# 無関係な場所の同じ語を拾う。
$catchAt = $translationSrc.IndexOf('$attemptErrorCode = Get-YakuTranslationAttemptErrorCode')
Assert-YakuMask ($catchAt -ge 0) 'リトライの判定箇所が見つかる'
$catchWindow = $translationSrc.Substring($catchAt, [Math]::Min(1200, $translationSrc.Length - $catchAt))
$limitAt = $catchWindow.IndexOf('Test-YakuCopilotLimitError')
$silentAt = $catchWindow.IndexOf('COPILOT_SILENT_START_TIMEOUT')
Assert-YakuMask ($limitAt -ge 0 -and $silentAt -ge 0 -and $limitAt -lt $silentAt) '打ち切りの判定は他の再試行より先に見る'

if ([string]::IsNullOrWhiteSpace($oldDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue } else { $env:YAKULINGO_DATA_DIR = $oldDataDir }
Remove-Item -LiteralPath $script:YakuNumericTestData -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "V91.60 numeric masking test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'CASE 23: oku 表記への換算を画面に明示する' -ForegroundColor Cyan
# oku は社内規約であって一般的な英語ではない。「メール・Webを訳す」という看板から
# billion を期待した人が、黙って 13,150 oku を受け取ると混乱する。
# billion は Settings.ps1 で意図的に選べない（換算コードが無く 10 倍の誤りになる）。
# 選べない以上、いま何をしているかは画面に書くほかない。
$quickPageSrc = [IO.File]::ReadAllText((Join-Path $root 'www/cat.html'))
$quickJsSrc = [IO.File]::ReadAllText((Join-Path $root 'www/assets/quick.js'))
$catPageSrc = [IO.File]::ReadAllText((Join-Path $root 'www/cat.html'))
$settingsSrc = [IO.File]::ReadAllText((Join-Path $root 'src/Settings.ps1'))
Assert-YakuMask ($quickPageSrc -match 'oku' -and $quickPageSrc -match 'billion') 'ちょっと翻訳が金額の書き方を明示する'
Assert-YakuMask ($quickJsSrc -match 'quick-notation-hint') '訳文の隣にも書き方を出す'
Assert-YakuMask ($catPageSrc -match 'oku' -and $catPageSrc -match 'billion') '資料翻訳も金額の書き方を明示する'
Assert-YakuMask ($settingsSrc -match "amount_notation.*Values=@\('oku'\)") '換算コードが入るまで billion を選べるようにしない'

Write-Host 'V91.60 numeric masking regression passed.' -ForegroundColor Green
