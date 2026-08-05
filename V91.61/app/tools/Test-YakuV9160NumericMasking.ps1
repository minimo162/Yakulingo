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

foreach ($name in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','FileTranslation.ps1','BriefStyle.ps1')) {
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

# 自分が入れた[[N1]]は二重マスクしない
$twice = New-YakuNumericMaskMap -Text ([string]$bracketed.Masked.Text) -Root $root -Direction 'to_en' -Location 'test'
Assert-YakuMask ([int]$twice.MaskedCount -eq 0) '[[N1]]を二重にマスクしない'
Assert-YakuMask ([string]$twice.Text -eq [string]$bracketed.Masked.Text) '二度掛けても変わらない'

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
function Invoke-YakuCopilotPrompt {
    # 実機の代わり。プロンプトを記録し、契約に合う応答をそのまま返す。
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $body = [string]([regex]::Match([string]$Prompt, '(?s)SOURCE_TEXT:\s*\n(.*?)\n\s*(?:GLOSSARY|OUTPUT|FORMAT|RULES)').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    if (@($tokens).Count -eq 0) { $tokens = @('115.77', '8.32') }
    if ([string]$Prompt -match 'JAPANESE_TEXT:') {
        $jp = 'FY2026/3の売上高は' + ([string]$tokens[0]) + '億円でした。'
        return ("JAPANESE_TEXT: $jp" + "`n" + "YAKULINGO_END:$id")
    }
    $line = 'FY2026/3 net sales ' + ([string]$tokens[0]) + ' oku, operating profit ' + ([string]$tokens[-1]) + ' oku.'
    return ("FULL_TEXT: $line" + "`n" + "BRIEF_TEXT: $line" + "`n" + "YAKULINGO_END:$id")
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
Assert-YakuMask ($sent -like '*2026年3月期*') '年度は伏せずに送る'
Assert-YakuMask ($sent -like '*NUMBER PLACEHOLDERS*') 'プロンプトに保護規則が入る'
Assert-YakuMask ($wired.Options.Count -eq 2) 'FULL/BRIEF が返る'
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

# 無効化した場合は素通し。回帰テスト用の抜け道が効くことも確かめる。
$env:YAKULINGO_NUMERIC_MASKING = 'off'
try {
    $script:SentPrompts.Clear()
    $null = Invoke-YakuSingleTranslationBatch -Root $root -InputText $wiredInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $wiredWarnings
    $sentOff = [string]$script:SentPrompts[$script:SentPrompts.Count - 1]
    Assert-YakuMask (-not ($sentOff -match ([regex]::Escape('[[N1]]')))) '無効化するとマスクしない'
    Assert-YakuMask ($sentOff -like '*115.77*') '無効化すると実値が入る'
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
Assert-YakuMask ($jpSent -like '*FY2026/3*') 'to_jp でも会計期は伏せない'
Assert-YakuMask ($jpSent -like '*oku -> 億円*') 'to_jp のプロンプトに単位表記の指示が入る'
Assert-YakuMask (@($jpResult.Options).Count -eq 1) 'JAPANESE の1件が返る'
Assert-YakuMask (([string]$jpResult.Options[0].Translation) -like '*115.77*') 'to_jp でも実値へ復元する'

Write-Host 'CASE 17: ファイル翻訳経路（プロンプトと復元）'
# 実ファイルを使わず、経路の構成要素を直接確認する。
$fileItems = @(
    [pscustomobject]@{ Index=1; Text='2026年3月期の売上高は115.77億円' }
    [pscustomobject]@{ Index=2; Text='営業利益率は8.3%' }
)
foreach ($fi in $fileItems) {
    $fi | Add-Member -NotePropertyName OriginalText -NotePropertyValue ([string]$fi.Text) -Force
    $fi.Text = [string](Convert-YakuNumericUnits -Text ([string]$fi.Text) -Location 'test').Text
    $fm = New-YakuNumericMaskMap -Text ([string]$fi.Text) -Root $root -Direction 'to_en' -Location 'test'
    $fi | Add-Member -NotePropertyName NumericMaskMap -NotePropertyValue $fm.Map -Force
    $fi | Add-Member -NotePropertyName MaskedText -NotePropertyValue ([string]$fm.Text) -Force
    $fi.Text = [string]$fm.Text
}
$filePrompt = New-YakuFilePrompt -Root $root -Items $fileItems -Settings $settings -Direction 'to_en' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuMask ($filePrompt -match ([regex]::Escape('[[N1]]'))) 'ファイル用プロンプトにプレースホルダーが入る'
Assert-YakuMask (-not ($filePrompt -like '*115.77*')) 'ファイル用プロンプトに実値が出ない'
Assert-YakuMask (-not ($filePrompt -like '*8.3%*')) 'ファイル用プロンプトに比率の実値が出ない'
Assert-YakuMask ($filePrompt -like '*2026年3月期*') 'ファイルでも会計期は伏せない'
Assert-YakuMask ($filePrompt -like '*NUMBER PLACEHOLDERS*') 'ファイル用プロンプトに保護規則が入る'
Assert-YakuMask ($filePrompt -like '*3Q*') '旧テンプレートにあった 3Q の保持指示が残る'
Assert-YakuMask (-not ($filePrompt -like '*{numeric_rules}*')) 'テンプレート変数が残らない'

# to_jp のファイル用テンプレートも同様に展開される
$filePromptJp = New-YakuFilePrompt -Root $root -Items $fileItems -Settings $settings -Direction 'to_jp' -RequestId ([guid]::NewGuid().ToString('N'))
Assert-YakuMask ($filePromptJp -like '*oku -> 億円*') 'to_jp のファイル用プロンプトに単位表記の指示が入る'
Assert-YakuMask (-not ($filePromptJp -like '*{numeric_rules}*')) 'to_jp でもテンプレート変数が残らない'

# 復元
$fileTranslations = @{ 1 = 'Net sales for FY2026/3 were [[N1]] oku'; 2 = 'OPM [[N1]]%' }
foreach ($fi in $fileItems) {
    $fileTranslations[[int]$fi.Index] = Restore-YakuNumericMask -Text ([string]$fileTranslations[[int]$fi.Index]) -Map $fi.NumericMaskMap
}
Assert-YakuMask ($fileTranslations[1] -eq 'Net sales for FY2026/3 were 115.77 oku') 'ファイル訳文を実値へ復元する'
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
function Invoke-YakuCopilotPrompt {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    $full = 'Net sales ' + ([string]$tokens[0]) + ' oku, operating profit ' + ([string]$tokens[-1]) + ' oku.'
    $brief = 'Net sales ' + ([string]$tokens[0]) + ' oku.'
    return ("FULL_TEXT: $full" + "`n" + "BRIEF_TEXT: $brief" + "`n" + "YAKULINGO_END:$id")
}
$briefJobWarnings = New-Object System.Collections.Generic.List[object]
$briefJobInput = (Convert-YakuNumericUnits -Text '売上高は115.77億円、営業利益は8.32億円でした。' -Location 'test').Text
$briefJob = Invoke-YakuSingleTranslationBatch -Root $root -InputText $briefJobInput -Settings $settings -Direction 'to_en' -StyleReference '' -Warnings $briefJobWarnings
Assert-YakuMask ($script:SentPrompts.Count -eq 1) 'BRIEF の欠落では再送しない'
Assert-YakuMask (([string]$briefJob.Options[1].Translation) -eq 'Net sales 115.77 oku.') 'BRIEF はそのまま復元して返す'
Assert-YakuMask (@($briefJobWarnings.ToArray() | Where-Object { [string]$_.Category -eq 'numeric-placeholder-dropped-brief' }).Count -eq 1) 'BRIEF 警告が結果に載る'

# 経路: FULL が落ちたら再送する
$script:SentPrompts.Clear()
$script:FullAttempt = 0
function Invoke-YakuCopilotPrompt {
    param([string]$Prompt, $Settings, [switch]$SkipFreshChatWait, [switch]$PreserveEndMarker, $ProgressState, $Warnings)
    $script:SentPrompts.Add([string]$Prompt) | Out-Null
    $script:FullAttempt++
    $id = [string]([regex]::Match([string]$Prompt, 'YAKULINGO_END:([0-9a-fA-F]{32})').Groups[1].Value)
    $tokens = @(Get-YakuNumericMaskTokens -Text ([string]$Prompt) | Select-Object -Unique | Sort-Object { [int]([regex]::Match([string]$_, '\d+').Value) })
    $complete = 'Net sales ' + ([string]$tokens[0]) + ' oku, operating profit ' + ([string]$tokens[-1]) + ' oku.'
    # 1回目は FULL から2つ目のプレースホルダーを落とす
    $full = if ($script:FullAttempt -eq 1) { 'Net sales ' + ([string]$tokens[0]) + ' oku.' } else { $complete }
    return ("FULL_TEXT: $full" + "`n" + "BRIEF_TEXT: $complete" + "`n" + "YAKULINGO_END:$id")
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
Assert-YakuMask ([int]$countResult.MaskedCount -eq 3) ('マスク件数が結果に載る: ' + [string]$countResult.MaskedCount)
Assert-YakuMask ([int]$countResult.KeptCount -ge 1) '非マスク件数も結果に載る（年度）'
$resultHtml = Convert-YakuTextResultToHtml -Result $countResult
Assert-YakuMask ($resultHtml -like '*数値 3 件をマスクして送信しました*') '結果画面へ告知が出る'

# 警告カテゴリの表示名
Assert-YakuMask ((Get-YakuWarningCategoryLabel -Category 'numeric-placeholder-dropped-brief') -eq 'BRIEFで省略された数値') 'BRIEF警告の表示名'
Assert-YakuMask ((Get-YakuWarningCategoryLabel -Category 'numeric-placeholder-unresolved') -eq '数値プレースホルダー不一致') '不一致警告の表示名'

# 用語集パネルの注意（§3-3）
$glossaryHtml = Convert-YakuGlossaryManagerToHtml -Root $root
Assert-YakuMask ($glossaryHtml -like '*機密の数値を用語集に登録しないでください*') '用語集パネルに注意を出す'

# 設定パネルの説明（§9）
$indexHtml = Get-Content -LiteralPath (Join-Path (Join-Path $root 'www') 'index.html') -Raw -Encoding UTF8
Assert-YakuMask ($indexHtml -like '*数値の大きさは自動でプレースホルダーへ置き換えます*') '設定パネルにマスキングの説明がある'
Assert-YakuMask ($indexHtml -like '*手で書く必要はありません*') '手動マスク廃止の案内がある'

Write-Host 'CASE 22: 受容基準の残り（仕様書 §10）'

# §10-3-b 決算期に似ているが別物の形はマスクする
foreach ($c in @(@{ Text='取引先は151件です。'; Gone='151' }, @{ Text='売上3億円の案件。'; Gone='3' })) {
    $r = Invoke-YakuMaskPipeline -Text ([string]$c.Text)
    Assert-YakuMask (-not ([string]$r.Masked.Text -like ('*' + $c.Gone + '*'))) ("決算期に似た形はマスク: " + $c.Text + ' -> ' + $r.Masked.Text)
}

# §10-4 / §10-19-c 用語集に一致した範囲は数字ごと無傷
# 仕様書は CX-90 を例示しているが、同梱用語集の実エントリは MTMUS製(CX-50)。
$cx = Invoke-YakuMaskPipeline -Text 'MTMUS製(CX-50)の単価改善は120億円。'
Assert-YakuMask ([string]$cx.Masked.Text -like '*MTMUS製(CX-50)*') ('用語の中の数字を壊さない: ' + $cx.Masked.Text)
Assert-YakuMask (-not ([string]$cx.Masked.Text -like '*120*')) '同じ文の金額はマスクする'
$cxMatches = @(Get-YakuRelevantGlossaryMatches -Root $root -InputText ([string]$cx.Masked.Text) -Direction 'to_en' -Limit 200 -Path (Get-YakuGlossaryPath -Root $root))
Assert-YakuMask (@($cxMatches | Where-Object { [string]$_.Source -eq 'MTMUS製(CX-50)' }).Count -gt 0) 'マスク後も用語集が一致する'
$fyq = Invoke-YakuMaskPipeline -Text 'FY26/3 1Q の AAT 営業利益(50%)は堅調。'
Assert-YakuMask ([string]$fyq.Masked.Text -like '*FY26/3 1Q*') 'FY26/3 1Q が無傷'

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
        if ($line -notmatch 'Invoke-YakuCopilotPrompt') { continue }
        if ($line -match 'function Invoke-YakuCopilotPrompt' -or $line -match 'Get-Command Invoke-YakuCopilotPrompt') { continue }
        $callSites += ($srcFile.Name)
    }
}
# V91.61 段階3: CorpusReference.ps1 が加わる。参考資料を引くための検索語を
# Copilot に作らせる経路で、原文を外部へ送る点は翻訳と同じ。
# 送る前にマスクしていることを下で確かめる。
$outside = @($callSites | Where-Object { $_ -notin @('CopilotClient.ps1','Translation.ps1','FileTranslation.ps1','CorpusReference.ps1') })
Assert-YakuMask ($outside.Count -eq 0) ("翻訳経路の外から呼ばれていない: " + (@($outside | Select-Object -Unique) -join ','))

# 外部へ送る経路が増えたら、そこもマスクを通っていること。
# 経路を足すたびに手で思い出す話にしない。
$corpusRefText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CorpusReference.ps1'))
$maskAt = $corpusRefText.IndexOf('New-YakuNumericMaskMap')
$sendAt = $corpusRefText.IndexOf('Invoke-YakuCopilotPrompt')
Assert-YakuMask ($maskAt -ge 0) 'コーパス検索語の経路もマスクを呼ぶ'
Assert-YakuMask ($sendAt -ge 0 -and $maskAt -lt $sendAt) 'マスクしてから送っている'
Assert-YakuMask ($corpusRefText -match "Location 'corpus-query'") '記録に経路名が残る（どこでマスクしたか分かる）'
Assert-YakuMask ((@($callSites | Where-Object { $_ -eq 'Translation.ps1' }).Count) -eq 1) 'テキスト経路の呼び出しは1箇所（逆翻訳の分が消えている）'

if ($script:Failures -gt 0) {
    Write-Host "V91.60 numeric masking test failed. failures=$script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.60 numeric masking regression passed.' -ForegroundColor Green
