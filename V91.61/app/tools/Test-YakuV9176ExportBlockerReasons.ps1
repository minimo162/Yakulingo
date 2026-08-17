<#
.SYNOPSIS
  書き出しが止まった理由を、種別ごとの文言で言えているかの回帰テスト。

.DESCRIPTION
  CLAUDE.md が唯一「宿題」と明記していた項目。止まる理由コードは
  segment-qc-failed の1本しか無いのに、その裏では 9 種の QC error が動いている（数値意味系は warning として別に表示される）。
  1本に丸めたままだと、用語集で止まった利用者が「数字の点検に通らない行が
  あります」と言われ、数字を見に行く。何を直せば押せるのかが画面から分からない。

  **止める条件は1つも減らしていない。** ここで測るのは説明だけである。
  (f) がそれを表明する（理由の顔ぶれと、止まるかどうかが従来のままであること）。

  見るのは9つ。
   (a) 数える。Reasons が何種類あり、行単位で止めるのがどれで、
       segment-qc-failed へ丸められる QC の error コードが何種類あるかを、
       構文木で src から取り出して数える。文書の引き写しはしない
   (b) その種別だけで落ちる行を実際に作り、その種別の文言が出ることを測る。
       字面照合ではなく、作った行を Get-YakuCatOutputPreflight に通して見る
   (c) 用語で止まった行の文言に「数字」「数値」が入っていないこと（宿題の本体）。
       併せて、種別ごとの文言が互いに違うこと
   (d) 道具の不調（点検そのものが落ちた）でも、訳を見比べろとは言わないこと。
       実際に点検関数を差し替えて落とし、出た文言で測る
   (e) 複数種別が同時に立つときは、全部を決めた順で並べること
   (f) 止める条件を減らしていないこと。理由の顔ぶれは従来の6種のまま、
       落ちる行は落ちたまま、通る行は通ったまま。
       **ただし守り方が3つで揃っていない。** segment-untranslated と
       segment-qc-failed は実物のプロジェクトを通して振る舞いで測っているが、
       segment-qc-not-current だけは構文木から $reasons.Add(...) の字面を
       拾っているだけである。2026-08-15 に実測: Add 行を消す改変は捕まえるが、
       CatProject.ps1 の `if (-not (Test-YakuCatSegmentQcCurrent ...))` を
       到達不能にする改変は素通しする（exit=0 のまま）。リポジトリ全体でも
       この理由を end-to-end で立てている試験は無い（CAT 試験9本で確認）。
       **測っていないものを測ったように読まないこと。**
   (g) 実装の註が「3つ」になっていること（2026-08-14 に CLAUDE.md だけが
       訂正され、註は「2つだけ」のまま残っていた）
   (h) 止めた理由が名指しした種別と行数が、画面へ渡す JSON の qc_preview にも
       そのまま載っていること（案内先が実在すること）
   (i) その qc_preview が、**保存したファイルへは1文字も漏れていない**こと。
       2026-08-15 の実測では、Save-YakuCatProject が qc_preview を
       generations/<id>/segments.jsonl へ書いても tools/ の55本が全部緑だった。
       ディスク側の門はここが最初の1本である。qc_findings（確定処理が書いた
       本物）は残ってよいので、同じ保存物で対にして見る

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9176ExportBlockerReasons.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# 読み込み順序は SrcModules.ps1 が唯一の出典。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-blk-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

function Get-YakuFunctionText {
    <# src から関数1本ぶんの本文を構文木で取り出す。写経すると写しだけが古くなる。 #>
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Name)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { return '' }
    foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        if ([string]$fn.Name -eq $Name) { return [string]$fn.Extent.Text }
    }
    return ''
}

function Get-YakuAstStringLiterals {
    <# 構文木の枝1本に含まれる文字列リテラルを全部返す。 #>
    param([AllowNull()]$Node)
    if ($null -eq $Node) { return @() }
    return @(@($Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) | ForEach-Object { [string]$_.Value })
}

function Get-YakuQcFindingCodes {
    <#
      点検が積む finding を構文木で拾い、Code と Severity を対で見て仕分ける。

      なぜ Severity まで見るか（2026-08-15）: ここが `Code=` の字面を数えるだけだと、
      **警告専用の finding を1つ足しただけで、止める種別の数え上げへ混ざる。**
      次の担当者はその赤を消すために、絶対に止まらないコードへ文言を足して緑へ戻す。
      門が数えているものが「止める種別」から「finding の種類」へ静かに入れ替わり、
      本来この門が守っていた「止める種別には必ず専用の文言がある」が空になる。

      Severity は 'error' の直書きだけではない。
        Severity=$(if ($excepted) { 'info' } else { 'error' })  … 分岐の中に居る
        Severity=$severity                                       … 変数で渡る
      前者は枝の中の文字列リテラルを見れば足り、後者は同じ関数の中の代入を追う。
      どちらでも決められなかったものは 'unknown' として返し、呼び出し側で
      名指しの FAIL にする。**黙って error 側にも other 側にも寄せない。**
      寄せると、道具が分類できなかっただけの話が、対象の欠陥（または合格）に化ける。

      戻り値は Code と Kind（error / other / unknown）の対。
    #>
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Name)
    $found = New-Object System.Collections.Generic.List[object]
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { return $found.ToArray() }
    $target = $null
    foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        if ([string]$fn.Name -eq $Name) { $target = $fn; break }
    }
    if ($null -eq $target) { return $found.ToArray() }

    # 変数で渡る Severity を追うため、同じ関数の中の代入を先に集める。
    $assigned = @{}
    foreach ($assign in @($target.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        if ($assign.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $key = [string]$assign.Left.VariablePath.UserPath
        if (-not $assigned.ContainsKey($key)) { $assigned[$key] = New-Object System.Collections.Generic.List[string] }
        foreach ($literal in @(Get-YakuAstStringLiterals -Node $assign.Right)) { $assigned[$key].Add([string]$literal) | Out-Null }
    }

    foreach ($table in @($target.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
        $codeNode = $null; $severityNode = $null
        foreach ($pair in @($table.KeyValuePairs)) {
            $keyName = ''
            if ($pair.Item1 -is [System.Management.Automation.Language.ConstantExpressionAst]) { $keyName = [string]$pair.Item1.Value }
            if ($keyName -eq 'Code') { $codeNode = $pair.Item2 }
            elseif ($keyName -eq 'Severity') { $severityNode = $pair.Item2 }
        }
        if ($null -eq $codeNode -or $null -eq $severityNode) { continue }
        $codeLiterals = @(Get-YakuAstStringLiterals -Node $codeNode)
        $code = if ($codeLiterals.Count -eq 1) { [string]$codeLiterals[0] } else { '' }

        $severityLiterals = @(Get-YakuAstStringLiterals -Node $severityNode)
        $kind = ''
        if ($severityLiterals -contains 'error') { $kind = 'error' }
        elseif ($severityLiterals.Count -gt 0) { $kind = 'other' }
        else {
            $vars = @($severityNode.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
            if ($vars.Count -eq 1) {
                $varName = [string]$vars[0].VariablePath.UserPath
                if ($assigned.ContainsKey($varName)) {
                    $kind = if (@($assigned[$varName].ToArray()) -contains 'error') { 'error' } else { 'other' }
                } else { $kind = 'unknown' }
            } else { $kind = 'unknown' }
        }
        if ([string]::IsNullOrWhiteSpace($code)) { $code = ('(コード不明) ' + [string]$codeNode.Extent.Text); $kind = 'unknown' }
        $found.Add([pscustomobject]@{ Code=$code; Kind=$kind }) | Out-Null
    }
    return $found.ToArray()
}

function Get-YakuFirstString {
    <# 空集合を [0] で引くと $null になり、その先の .Contains() が
       $ErrorActionPreference='Stop' の下で試験そのものを落とす。落ちると
       残りの節が走らないまま終了コード1だけが返り、赤の内訳が消える。
       ここで '' へ落として、外れは Chk の失敗として流す。 #>
    param([AllowNull()][object[]]$Items)
    $list = @($Items)
    if ($list.Count -eq 0) { return '' }
    return [string]$list[0]
}

function Get-YakuQcMessageFor {
    <# 種別1つぶんの文言。取れなければ '' を返し、例外では落ちない。 #>
    param([Parameter(Mandatory=$true)][string]$Code, [int]$Rows = 1)
    $items = @(Get-YakuCatQcBlockerMessages -Failures @([pscustomobject]@{ Code=$Code; Rows=$Rows }))
    if ($items.Count -eq 0) { return '' }
    return [string]$items[0].Message
}

try {
    $settings = Read-YakuSettings -Root $root
    $catPath = Join-Path (Join-Path $root 'src') 'CatProject.ps1'
    $termPath = Join-Path (Join-Path $root 'src') 'Terminology.ps1'

    # ------------------------------------------------------------------ (a)
    Write-Host '(a) 数える（引き写さない）' -ForegroundColor Cyan
    $eligibilityText = Get-YakuFunctionText -Path $catPath -Name 'Get-YakuCatOutputEligibility'
    Chk (-not [string]::IsNullOrWhiteSpace($eligibilityText)) 'Get-YakuCatOutputEligibility を構文木から取り出せた'
    $reasonKinds = @([regex]::Matches($eligibilityText, "\`$reasons\.Add\('([a-z-]+)'\)") | ForEach-Object { [string]$_.Groups[1].Value } | Sort-Object -Unique)
    Write-Host ('     Reasons の種類 = ' + $reasonKinds.Count + ' : ' + ($reasonKinds -join ','))
    $expectedReasons = @('project-empty','segment-qc-failed','segment-qc-not-current','segment-untranslated','source-file-missing','word-unsupported-structure')
    Chk ($reasonKinds.Count -eq 6) ('Reasons は6種（実際 ' + $reasonKinds.Count + '）')
    Chk (@(Compare-Object $reasonKinds $expectedReasons).Count -eq 0) '理由の顔ぶれが従来どおり（増やしても減らしてもいない）'
    # 行ごとに立つのは3つ。これが「DRAFT を止める理由は3つ」の実体である。
    $rowLevel = @('segment-untranslated','segment-qc-failed','segment-qc-not-current')
    Chk (@($rowLevel | Where-Object { $reasonKinds -notcontains $_ }).Count -eq 0) ('行単位で止めるのは3つ : ' + ($rowLevel -join ','))

    $validationText = Get-YakuFunctionText -Path $catPath -Name 'Invoke-YakuCatSegmentValidation'
    $complianceText = Get-YakuFunctionText -Path $termPath -Name 'Test-YakuTerminologyCompliance'
    Chk (-not [string]::IsNullOrWhiteSpace($validationText) -and -not [string]::IsNullOrWhiteSpace($complianceText)) '点検2本を構文木から取り出せた'

    # 数え上げは Severity まで見る。`Code=` の字面だけを数えると、warning 専用の
    # finding を1つ足しただけで門の種別数が増え、次の担当者が
    # **絶対に止まらないコードへ文言を足して緑へ戻す**。門が守るものが入れ替わる。
    $qcFindingDefs = @(@(Get-YakuQcFindingCodes -Path $catPath -Name 'Invoke-YakuCatSegmentValidation') + `
                       @(Get-YakuQcFindingCodes -Path $termPath -Name 'Test-YakuTerminologyCompliance'))
    Chk ($qcFindingDefs.Count -gt 0) ('点検2本の finding を構文木で拾えた（実際 ' + $qcFindingDefs.Count + ' 件）')
    # 分類できなかったものは、error 側にも other 側にも寄せずに名指しで落とす。
    $unresolvedSeverity = @(@($qcFindingDefs | Where-Object { [string]$_.Kind -eq 'unknown' } | ForEach-Object { [string]$_.Code }) | Sort-Object -Unique)
    Chk ($unresolvedSeverity.Count -eq 0) ('Severity を判定できない finding が無い（実際: ' + ($unresolvedSeverity -join ',') + '）')
    $qcCodes = @(@($qcFindingDefs | Where-Object { [string]$_.Kind -eq 'error' } | ForEach-Object { [string]$_.Code }) | Sort-Object -Unique)
    $nonErrorCodes = @(@($qcFindingDefs | Where-Object { [string]$_.Kind -eq 'other' } | ForEach-Object { [string]$_.Code }) | Sort-Object -Unique)
    Write-Host ('     segment-qc-failed へ丸められる error コード = ' + $qcCodes.Count + ' : ' + ($qcCodes -join ','))
    Write-Host ('     error にならない finding = ' + $nonErrorCodes.Count + ' : ' + ($nonErrorCodes -join ','))
    Chk ($qcCodes.Count -eq 9) ('QC の error コードは 9 種（実際 ' + $qcCodes.Count + '）')
    # error になり得ない種別を「止める種別」として数えていないこと。
    Chk (@($nonErrorCodes | Where-Object { $qcCodes -contains $_ }).Count -eq 0) 'error にならない finding を、止める種別として数えていない'

    # 種別ごとの文言が、9種すべてに用意されていること。ここが空くと、点検を
    # 増やしたのに説明を足し忘れた分だけ「自動点検に通らない」へ落ちる。
    $generic = '自動点検に通らない行が'
    $covered = 0
    foreach ($code in $qcCodes) {
        $message = Get-YakuQcMessageFor -Code $code -Rows 1
        if (-not [string]::IsNullOrWhiteSpace($message) -and -not $message.StartsWith($generic)) { $covered++ }
        else { Write-Host ('     未整備: ' + $code) -ForegroundColor Yellow }
    }
    Chk ($covered -eq $qcCodes.Count) ('9種すべてに専用の文言がある（実際 ' + $covered + '/' + $qcCodes.Count + '）')
    # 知らないコードが来ても黙らせない（落とすと押せない理由が消える）
    $unknown = @(Get-YakuCatQcBlockerMessages -Failures @([pscustomobject]@{ Code='brand-new-check'; Rows=3 }))
    $unknownMessage = Get-YakuFirstString -Items @($unknown | ForEach-Object { [string]$_.Message })
    Chk ($unknown.Count -eq 1 -and $unknownMessage.StartsWith($generic)) '知らない種別でも、押せない理由を1件は出す'
    # 訳文が空の行は segment-untranslated が先に立つので、end-to-end では empty は
    # 出ない。文言だけは持っておく（点検を単体で呼ぶ経路があるため）。
    $emptyMessage = Get-YakuQcMessageFor -Code 'empty' -Rows 2
    Chk ($emptyMessage.Contains('2 行')) '行数が文言に入る'

    # ---- 文言の中身を、事例の名指しではなく規則で守る --------------------
    # ここが「terminology-missing / structure-integrity / invalid-or-source-fallback
    # の3種だけを名指しで見る」形だったため、**terminology-conflict の文言を旧
    # 「数字の点検に通らない行が #ROWS# 行あります」へ書き戻す変異が緑のまま通った**
    # （2026-08-15 実測 exit=0 / ok=89 / FAIL=0）。直したはずの欠陥をそのまま
    # 復活させられる門は、門ではない。
    #
    # そこで (a) が src から導いたコード一覧の側で回し、種別の接頭辞で規則を立てる。
    # 規則を決めていない接頭辞が来たら、素通しではなく FAIL にする。点検を増やした
    # 人が、文言の言い分けまで含めて決めるまで緑にならない。
    $messageCodes = @(@($qcCodes) + @('validation-unavailable') | Sort-Object -Unique)
    $ruleChecked = 0
    $ruleViolations = New-Object System.Collections.Generic.List[string]
    $ruleUnclassified = New-Object System.Collections.Generic.List[string]
    $rowsMissing = New-Object System.Collections.Generic.List[string]
    foreach ($code in $messageCodes) {
        # 行数は必ず文言へ出す。#ROWS# を落とした文言は、何行あるか言わずに止める。
        $probeMessage = Get-YakuQcMessageFor -Code $code -Rows 7
        if (-not $probeMessage.Contains('7 行')) { $rowsMissing.Add([string]$code) | Out-Null }

        $message = Get-YakuQcMessageFor -Code $code -Rows 1
        $forbid = @(); $require = @(); $classified = $true
        if ($code.StartsWith('terminology-')) {
            # 宿題の本体。用語で止まったのに数字を見に行かされない。
            # 求めるほうは「語」までにする。terminology-conflict は
            # 「同じ語に、必ず使う訳が2つ以上登録されています」と言っており、
            # 「用語」「訳語」を直書きしていない。実装の言い回しに規則を合わせる
            # （実装のほうを規則へ寄せて書き換えるのは、この門の仕事ではない）。
            $forbid = @('数字','数値'); $require = @('語')
        } elseif ($code.StartsWith('numeric-') -or $code.StartsWith('currency-') -or $code.StartsWith('accounting-')) {
            # 逆向き。数字・通貨で止まったのに用語集を開かされない。
            $forbid = @('用語','訳語')
        } elseif ($code.StartsWith('structure-')) {
            $forbid = @('数字','数値','用語','訳語')
        } elseif ($code -eq 'placeholder-residue') {
            # 差し込み記号は数字そのものの替え玉なので「数字」は言ってよい。用語は言わない。
            $forbid = @('用語','訳語')
        } elseif (@('empty','invalid-or-source-fallback','validation-unavailable') -contains $code) {
            $forbid = @('数字','数値','用語','訳語')
        } else {
            $classified = $false
            $ruleUnclassified.Add([string]$code) | Out-Null
        }
        if (-not $classified) { continue }
        $ruleChecked++
        if ([string]::IsNullOrWhiteSpace($message)) { $ruleViolations.Add([string]$code + ' の文言が空') | Out-Null; continue }
        $said = @($forbid | Where-Object { $message.Contains([string]$_) })
        if ($said.Count -gt 0) { $ruleViolations.Add([string]$code + ' が「' + ($said -join '」「') + '」と言っている') | Out-Null }
        if ($require.Count -gt 0 -and @($require | Where-Object { $message.Contains([string]$_) }).Count -eq 0) {
            $ruleViolations.Add([string]$code + ' が「' + ($require -join '」「') + '」のどれも言っていない') | Out-Null
        }
    }
    Chk ($ruleUnclassified.Count -eq 0) ('文言の規則を決めていない種別が無い（実際: ' + (@($ruleUnclassified.ToArray()) -join ',') + '）')
    Chk ($ruleViolations.Count -eq 0) ('種別ごとの文言が、無関係な言葉を持ち出さない（違反: ' + (@($ruleViolations.ToArray()) -join ' / ') + '）')
    Chk ($ruleChecked -eq $messageCodes.Count) ('文言を規則で見た種別が ' + $messageCodes.Count + ' 種（実際 ' + $ruleChecked + '）')
    Chk ($rowsMissing.Count -eq 0) ('どの種別の文言にも行数が入る（欠け: ' + (@($rowsMissing.ToArray()) -join ',') + '）')
    # 種別ごとに違う文言であること（9種と validation-unavailable で見る。end-to-end で
    # 足りない。写経して差し替え忘れた文言は、ここでしか捕まらない）。
    $allMessages = @($messageCodes | ForEach-Object { Get-YakuQcMessageFor -Code $_ -Rows 1 })
    Chk (@($allMessages | Sort-Object -Unique).Count -eq $messageCodes.Count) ('種別ごとの文言が互いに違う（実際 ' + @($allMessages | Sort-Object -Unique).Count + '/' + $messageCodes.Count + '）')

    # ------------------------------------------------------------------ 共通
    function New-BlockedProject {
        param([string[]]$Sources, [string[]]$Targets, [string]$Direction = 'to_en', [scriptblock]$Setup)
        $p = New-YakuCatTextProject -Root $root -Text ($Sources -join "`n") -Settings $settings -Direction $Direction
        if ($Setup) { & $Setup $p }
        for ($i = 0; $i -lt $Targets.Count; $i++) { $null = Set-YakuCatSegmentTranslation -Project $p -Index $i -Text $Targets[$i] }
        return $p
    }
    function Get-BlockerMessages {
        param($Project)
        $preflight = Get-YakuCatOutputPreflight -Project $Project
        return @(@($preflight.Blockers) | ForEach-Object { [string]$_.message })
    }
    function Get-QcCodesOf {
        param($Project)
        return @(@((Get-YakuCatOutputEligibility -Project $Project).QcFailures) | ForEach-Object { [string]$_.Code })
    }

    $srcFixed  = '固定費を圧縮しました。'
    $srcDollar = '売上はドルで計上しました。'
    $srcSign   = '▲152億円でした。'
    $srcOrder  = '売上は100、利益は200でした。'
    $srcProfit = '利益が増加しました。'
    $srcHead   = '【概要】'
    $srcAmount = '売上高は100億円でした。'
    $addFixedTerm = {
        param($p)
        $segs = @($p.Segments)
        # 空集合を [0] で引かない。外れたら例外死ではなく Chk の失敗として流す。
        if ($segs.Count -eq 0) { Chk $false '用語の登録に使う行が作られている'; return }
        $seg = $segs[0]
        $null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$p.Id) -Kind occurrence -Enforcement required `
            -JapanesePreferred '固定費' -EnglishPreferred 'fixed costs' -Origin 'export-blocker-test' `
            -OriginProjectId ([string]$p.Id) -OriginFileName ([string]$p.FileName) -OriginSegmentId ([string]$seg.SegmentId) `
            -OriginLocation ([string]$seg.Location) -OriginRevision ([int]$p.Revision)
    }

    # ------------------------------------------------------------------ (b)(c)
    Write-Host '(b)(c) その種別だけで落ちる行を作り、出た文言で測る' -ForegroundColor Cyan
    # 期待は「その種別の文言が出ること」。落ちる種別が1つに絞れるものは絞る。
    #   numeric-scale-mismatch だけは単独に落とせない。桁が違えば値も食い違うので、
    #   numeric-value-* が必ず同時に立つ。ここでは同時に立つことを認めたうえで、
    #   桁の文言が確かに出ることを見る。
    $cases = @(
        [pscustomobject]@{ Name='terminology-missing'; Sources=@($srcFixed); Targets=@('We cut overhead.'); Setup=$addFixedTerm; Sole=$true; Expect='登録した訳語が使われていない' }
        [pscustomobject]@{ Name='structure-integrity'; Sources=@($srcHead); Targets=@('Overview'); Setup=$null; Sole=$true; Expect='見出しや箇条書きの形が原文と違う' }
        [pscustomobject]@{ Name='invalid-or-source-fallback'; Sources=@($srcFixed); Targets=@($srcFixed); Setup=$null; Sole=$true; Expect='訳文が原文のままか' }
        [pscustomobject]@{ Name='placeholder-residue'; Sources=@($srcFixed); Targets=@('We cut [[N1]] costs.'); Setup=$null; Sole=$false; Expect='のような差し込み記号が残っている' }
    )
    $seenMessages = @{}
    foreach ($case in $cases) {
        $direction = if ([string]::IsNullOrWhiteSpace([string]$case.Direction)) { 'to_en' } else { [string]$case.Direction }
        $project = New-BlockedProject -Sources @($case.Sources) -Targets @($case.Targets) -Direction $direction -Setup $case.Setup
        $codes = Get-QcCodesOf -Project $project
        $messages = Get-BlockerMessages -Project $project
        $hit = @($messages | Where-Object { $_.Contains([string]$case.Expect) })
        Chk ($codes -contains [string]$case.Name) ([string]$case.Name + ' で実際に落ちる（実際: ' + ($codes -join ',') + '）')
        if ([bool]$case.Sole) { Chk ($codes.Count -eq 1) ([string]$case.Name + ' だけで落ちている（実際 ' + $codes.Count + ' 種）') }
        Chk ($hit.Count -eq 1) ([string]$case.Name + ' の文言が出る')
        if ($hit.Count -eq 1) { $seenMessages[[string]$case.Name] = Get-YakuFirstString -Items $hit }
        # 宿題の本体。数字以外で止まったのに「数字」の話をされない。
        if ([string]$case.Name -in @('terminology-missing','structure-integrity','invalid-or-source-fallback')) {
            $wrong = @($hit | Where-Object { $_.Contains('数字') -or $_.Contains('数値') })
            Chk ($wrong.Count -eq 0) ([string]$case.Name + ' の文言に「数字」「数値」が出てこない')
        }
        Chk (-not [bool](Get-YakuCatOutputEligibility -Project $project).TranslationListEligible) ([string]$case.Name + ' は書き出しを止めたまま')
        Remove-YakuCatProject -Id ([string]$project.Id)
    }
    Chk (@($seenMessages.Values | Sort-Object -Unique).Count -eq $seenMessages.Count) ('種別ごとに違う文言になっている（' + $seenMessages.Count + ' 種）')
    # 用語で止まったのに数字を見に行かされる、が本当に直っているか。
    $termOnly = $seenMessages['terminology-missing']
    Chk (-not [string]::IsNullOrWhiteSpace($termOnly) -and $termOnly.Contains('用語')) '用語で止まった文言が用語を指している'

    # 数値意味系は画面へ warning として載るが、確認・書き出しは止めない。
    $warningCases = @(
        [pscustomobject]@{ Name='currency-mismatch'; Sources=@($srcDollar); Targets=@('Sales were recorded.') }
        [pscustomobject]@{ Name='numeric-sign-missing'; Sources=@($srcSign); Targets=@('152 oku yen.') }
        [pscustomobject]@{ Name='numeric-value-order-mismatch'; Sources=@($srcOrder); Targets=@('Profit was 200 and revenue was 100.') }
        [pscustomobject]@{ Name='numeric-value-extra'; Sources=@($srcAmount); Targets=@('Revenue was 100 oku yen in 2026.') }
        [pscustomobject]@{ Name='accounting-polarity-mismatch'; Sources=@($srcProfit); Targets=@('The result declined.') }
        [pscustomobject]@{ Name='numeric-value-mismatch'; Sources=@($srcAmount); Targets=@('Revenue was strong in yen.') }
        [pscustomobject]@{ Name='numeric-scale-mismatch'; Sources=@('Revenue was 5 billion yen.'); Targets=@('売上高は5百万円でした。'); Direction='to_jp' }
    )
    foreach ($case in $warningCases) {
        $direction = if ([string]::IsNullOrWhiteSpace([string]$case.Direction)) { 'to_en' } else { [string]$case.Direction }
        $project = New-BlockedProject -Sources @($case.Sources) -Targets @($case.Targets) -Direction $direction
        $eligibility = Get-YakuCatOutputEligibility -Project $project
        $warningRows = @(@($eligibility.QcRows) | Where-Object {
            (@($_.Findings) | Where-Object { [string]$_.code -eq [string]$case.Name }).Count -gt 0 -or
            @($_.Codes) -contains [string]$case.Name
        })
        Chk ($warningRows.Count -ge 1) ([string]$case.Name + ' は warning として行に残る')
        Chk (@($eligibility.QcFailures | Where-Object { [string]$_.Code -eq [string]$case.Name }).Count -eq 0) ([string]$case.Name + ' は blocker に昇格しない')
        Chk ([bool]$eligibility.TranslationListEligible) ([string]$case.Name + ' は書き出しを止めない')
        Remove-YakuCatProject -Id ([string]$project.Id)
    }

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) 道具の不調は、訳を見比べろとは言わない' -ForegroundColor Cyan
    # 点検そのものを落として測る。字面ではなく、実際にその枝を通す。
    $faults = @(
        [pscustomobject]@{ Function='Get-YakuCanonicalNumericFacts'; Code='numeric-validation-error'; Warning=$true }
        [pscustomobject]@{ Function='Test-YakuTextStructureIntegrity'; Code='structure-validation-error'; Warning=$false }
        [pscustomobject]@{ Function='Test-YakuTerminologyCompliance'; Code='terminology-check-unavailable' }
        [pscustomobject]@{ Function='Invoke-YakuCatSegmentValidation'; Code='validation-unavailable' }
    )
    foreach ($fault in $faults) {
        $saved = (Get-Item ('function:' + [string]$fault.Function)).ScriptBlock
        Set-Item ('function:' + [string]$fault.Function) -Value { param() throw 'INJECTED_FOR_TEST' }
        try {
            $faultSource = if ([bool]$fault.Warning) { $srcAmount } else { $srcFixed }
            $faultTarget = if ([bool]$fault.Warning) { 'Revenue was 100 oku yen.' } else { 'We cut fixed costs.' }
            $project = New-BlockedProject -Sources @($faultSource) -Targets @($faultTarget)
            $codes = Get-QcCodesOf -Project $project
            $messages = Get-BlockerMessages -Project $project
            if ([bool]$fault.Warning) {
                Chk (-not ($codes -contains [string]$fault.Code)) ([string]$fault.Code + ' は点検不能でも blocker にしない（実際: ' + ($codes -join ',') + '）')
                Chk ([bool](Get-YakuCatOutputEligibility -Project $project).TranslationListEligible) ([string]$fault.Code + ' は書き出しを止めない')
            } else {
                Chk ($codes -contains [string]$fault.Code) ([string]$fault.Code + ' として立つ（実際: ' + ($codes -join ',') + '）')
                $told = @($messages | Where-Object { $_.Contains('管理者へご連絡ください') })
                Chk ($told.Count -eq 1) ([string]$fault.Code + ' は、直しようが無いことを認めて連絡先を出す')
                Chk (@($messages | Where-Object { $_.Contains('見比べて') }).Count -eq 0) ([string]$fault.Code + ' で「原文と見比べて」とは言わない')
            }
            Remove-YakuCatProject -Id ([string]$project.Id)
        } finally { Set-Item ('function:' + [string]$fault.Function) -Value $saved }
    }
    # 差し替えを戻せていること（戻せていないと、以降の測定が全部嘘になる）
    $sane = New-BlockedProject -Sources @($srcFixed) -Targets @('We cut fixed costs.')
    Chk ((Get-QcCodesOf -Project $sane).Count -eq 0) '差し替えを戻したあとは、素通しの行が通る'
    Remove-YakuCatProject -Id ([string]$sane.Id)

    # ------------------------------------------------------------------ (e)
    Write-Host '(e) 複数種別が同時に立つときは、全部を決めた順で並べる' -ForegroundColor Cyan
    $multi = New-BlockedProject -Sources @($srcFixed, $srcDollar, $srcSign, $srcFixed) `
                                -Targets @('We cut overhead.', 'Sales were recorded.', '152 oku yen.', 'We reduced overhead.') `
                                -Setup $addFixedTerm
    $multiCodes = Get-QcCodesOf -Project $multi
    $multiMessages = Get-BlockerMessages -Project $multi
    Chk ($multiCodes.Count -eq 1 -and $multiCodes -contains 'terminology-missing') ('非数値 error だけが blocker に残る（実際: ' + ($multiCodes -join ',') + '）')
    $indexOf = { param([string]$needle) return [array]::FindIndex([string[]]$multiMessages, [Predicate[string]]{ param($m) $m.Contains($needle) }) }
    $iTerm = & $indexOf '登録した訳語が使われていない'
    Chk ($iTerm -ge 0) '非数値 error の文言が出る（warning を blocker に丸めない）'
    $termRows = @(@((Get-YakuCatOutputEligibility -Project $multi).QcFailures) | Where-Object { [string]$_.Code -eq 'terminology-missing' })
    $termRowCount = if ($termRows.Count -ge 1) { [int]$termRows[0].Rows } else { -1 }
    Chk ($termRows.Count -eq 1 -and $termRowCount -eq 2) ('同じ種別で落ちた行数を数えている（用語 2 行、実際 ' + $termRowCount + '）')
    # 空集合を [0] で引くと $null になり、.Contains() が $ErrorActionPreference='Stop' の
    # 下で試験そのものを落とす。落ちると (f)(g) が走らないまま終了コード1だけが返り、
    # 赤の内訳が消える。外れは Chk の失敗として流し、後続は必ず走らせる。
    $termHits = @($multiMessages | Where-Object { $_.Contains('登録した訳語が使われていない') })
    Chk ($termHits.Count -eq 1) ('用語の文言が1件だけ出る（実際 ' + $termHits.Count + ' 件）')
    $termMessage = Get-YakuFirstString -Items $termHits
    Chk ($termMessage.Contains('2 行')) '行数が文言に出る'
    # 押せない理由が blockers に入っていること（warnings へ逃がしていないこと）
    $multiPreflight = Get-YakuCatOutputPreflight -Project $multi
    Chk (-not [bool]$multiPreflight.Eligible -and @($multiPreflight.Blockers).Count -ge 1) '非数値 error が残る以上、blockers に出る'
    Chk (@(@($multiPreflight.Blockers) | Where-Object { [string]$_.code -eq 'segment-qc-failed' }).Count -ge 1) '機械が読む code は segment-qc-failed のまま（鍵は変えない）'
    Chk (@(@($multiPreflight.Blockers) | Where-Object { [string]$_.qc_code -eq 'terminology-missing' }).Count -eq 1) '種別は qc_code に足してある'
    # rows は誰も表明していなかった。rows=0 へ固定する変異が緑で通る（2026-08-15 実測）。
    Chk (@(@($multiPreflight.Blockers) | Where-Object { [string]$_.qc_code -eq 'terminology-missing' -and [int]$_.rows -eq 2 }).Count -eq 1) 'blocker の rows に、その種別で落ちた行数が入る（用語 2 行）'
    Chk (@(@($multiPreflight.Blockers) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.qc_code) -and [int]$_.rows -lt 1 }).Count -eq 0) '種別つきの blocker は rows が 1 以上'
    Remove-YakuCatProject -Id ([string]$multi.Id)

    # ------------------------------------------------------------------ (f)
    Write-Host '(f) 止める条件を減らしていない' -ForegroundColor Cyan
    $allowedReasons = @('segment-untranslated','segment-qc-failed','segment-qc-not-current','project-empty','source-file-missing','word-unsupported-structure')
    $blockedOne = New-BlockedProject -Sources @($srcFixed) -Targets @('We cut overhead.') -Setup $addFixedTerm
    $blockedEligibility = Get-YakuCatOutputEligibility -Project $blockedOne
    Chk (@(@($blockedEligibility.Reasons) | Where-Object { $allowedReasons -notcontains $_ }).Count -eq 0) ('止める理由を増やしていない（実際: ' + ((@($blockedEligibility.Reasons)) -join ',') + '）')
    Chk (@($blockedEligibility.Reasons) -contains 'segment-qc-failed') '用語で落ちた行も、従来どおり segment-qc-failed で止まる'
    Chk (-not [bool]$blockedEligibility.TranslationListEligible) '止まっている'
    Remove-YakuCatProject -Id ([string]$blockedOne.Id)
    # 通る行は通ったまま（この検査が空振りでないこと）
    $clean = New-BlockedProject -Sources @($srcAmount) -Targets @('Revenue was 100 oku yen.')
    $cleanEligibility = Get-YakuCatOutputEligibility -Project $clean
    Chk ([bool]$cleanEligibility.TranslationListEligible) '素通しの行は従来どおり書き出せる'
    Chk (@($cleanEligibility.QcFailures).Count -eq 0) '通る行は内訳も空'
    $cleanPreflight = Get-YakuCatOutputPreflight -Project $clean
    Chk (@($cleanPreflight.Blockers).Count -eq 0) '通るときは blockers を出さない'
    Remove-YakuCatProject -Id ([string]$clean.Id)
    # 未確認は止めない（緩めてもいないし、締めてもいない）
    $unconfirmed = New-BlockedProject -Sources @($srcAmount) -Targets @('Revenue was 100 oku yen.')
    Chk ([int](Get-YakuCatOutputEligibility -Project $unconfirmed).UnconfirmedCount -eq 1) '未確認は数えるが止めない'
    Remove-YakuCatProject -Id ([string]$unconfirmed.Id)
    # 訳文が空の行は従来どおり止まる
    $untranslated = New-BlockedProject -Sources @($srcAmount, $srcFixed) -Targets @('Revenue was 100 oku yen.')
    $untranslatedPreflight = Get-YakuCatOutputPreflight -Project $untranslated
    Chk (@(@($untranslatedPreflight.Blockers) | Where-Object { [string]$_.code -eq 'segment-untranslated' }).Count -eq 1) '訳文が空の行は従来どおり止まり、その文言が出る'
    Remove-YakuCatProject -Id ([string]$untranslated.Id)

    # ------------------------------------------------------------------ (h)
    # 宿題の残り半分（2026-08-15）。上の (b)(c)(e) は「文言が種別を名指しするか」
    # までしか見ていなかった。文言15本が案内する「点検の指摘」は
    # www/assets/cat.js が segment.qc_findings の件数で出し入れしており、
    # その findings を実セグメントへ書くのは Set-YakuCatSegmentConfirmed だけである。
    # 書き出し前の点検は写しに走らせるので、**未確定の行では案内先が1件も無い**。
    # ここでは「preflight が数えた行と種別が、画面へ渡す JSON にも載っているか」を
    # 見る。画面で実際に開けるかは Test-YakuV9176CatScreenWiring.ps1 (j) が
    # Chromium で押して測る。
    Write-Host '(h) 止めた理由が名指しした指摘が、画面へ渡す JSON にも載っている' -ForegroundColor Cyan
    $previewProject = New-BlockedProject -Sources @($srcFixed, $srcAmount, $srcDollar) `
                                         -Targets @('We cut overhead.', 'Revenue was 100 oku yen.', 'Sales were recorded.') `
                                         -Setup $addFixedTerm
    $previewEligibility = Get-YakuCatOutputEligibility -Project $previewProject
    $previewBlockers = @((Get-YakuCatOutputPreflight -Project $previewProject).Blockers)
    $previewView = (ConvertTo-YakuCatProjectJson -Project $previewProject) | ConvertFrom-Json
    $previewRows = @($previewView.segments)
    Chk ($previewRows.Count -eq 3) ('画面へ渡す行は3行（実際 ' + $previewRows.Count + '）')
    # まず、この題材が空振りでないこと。実セグメントには findings が1件も無い。
    Chk (@(@($previewProject.Segments) | Where-Object { @($_.QcFindings).Count -gt 0 }).Count -eq 0) '実セグメントには点検結果が1件も無い（未確定だから。この題材が空振りでない）'
    Chk (@(@($previewRows) | Where-Object { @($_.qc_findings).Count -gt 0 }).Count -eq 0) 'JSON の qc_findings も空のまま（写しの結果を実セグメントへ書いていない）'
    Chk (@(@($previewProject.Segments) | Where-Object { [string]$_.QcStatus -ne 'not_run' }).Count -eq 0) '点検の状態も not_run のまま（写しに走らせても行は書き換えない）'
    # ここが本体。preflight が名指しした種別と行数が、そのまま行にも載る。
    $previewByCode = @{}
    foreach ($row in $previewRows) {
        foreach ($item in @($row.qc_preview)) {
            $c = [string]$item.code
            if ($previewByCode.ContainsKey($c)) { $previewByCode[$c] = [int]$previewByCode[$c] + 1 } else { $previewByCode[$c] = 1 }
        }
    }
    $failureCodes = @(@($previewEligibility.QcFailures) | ForEach-Object { [string]$_.Code })
    Chk ($failureCodes.Count -eq 1 -and $failureCodes -contains 'terminology-missing') ('非数値 error だけが書き出しを止める（実際: ' + ($failureCodes -join ',') + '）')
    $previewMismatch = New-Object System.Collections.Generic.List[string]
    foreach ($failure in @($previewEligibility.QcFailures)) {
        $c = [string]$failure.Code
        $have = if ($previewByCode.ContainsKey($c)) { [int]$previewByCode[$c] } else { 0 }
        if ($have -ne [int]$failure.Rows) { $previewMismatch.Add($c + ' 数えた=' + [string][int]$failure.Rows + ' 載った=' + [string]$have) | Out-Null }
    }
    Chk ($previewMismatch.Count -eq 0) ('数えた行数と、行に載った件数が種別ごとに一致する（ずれ: ' + (@($previewMismatch.ToArray()) -join ' / ') + '）')
    Chk (@($failureCodes | Where-Object { -not $previewByCode.ContainsKey([string]$_) }).Count -eq 0) ('止めた種別は行の写しから引ける（実際: ' + ((@($previewByCode.Keys)) -join ',') + '）')
    Chk (@($previewRows | ForEach-Object { @($_.qc_preview) } | Where-Object { [string]$_.code -eq 'currency-mismatch' -and [string]$_.severity -eq 'warning' }).Count -ge 1) 'numeric warning は preview に残るが blocker ではない'
    # 文言が名指しした種別も、行から引ける（案内先が実在する）
    foreach ($blocker in @($previewBlockers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.qc_code) })) {
        Chk ($previewByCode.ContainsKey([string]$blocker.qc_code)) ('文言が名指しした ' + [string]$blocker.qc_code + ' を、行からも引ける')
    }
    # 通った行には何も載らない（全部の行に付けて誤魔化していない）
    $cleanRows = @($previewRows | Where-Object { @($_.qc_preview).Count -eq 0 })
    Chk ($cleanRows.Count -eq 1 -and [string]$cleanRows[0].source -eq $srcAmount) ('点検に通った行には1件も載らない（実際 ' + $cleanRows.Count + ' 行）')
    # 用語の免除に要る鍵は載せない。載せると未確定の行にも免除ボタンが出せてしまう。
    $leaked = New-Object System.Collections.Generic.List[string]
    foreach ($row in $previewRows) {
        foreach ($item in @($row.qc_preview)) {
            foreach ($name in @($item.PSObject.Properties.Name)) { if ($name -notin @('code','severity')) { $leaked.Add($name) | Out-Null } }
        }
    }
    Chk ($leaked.Count -eq 0) ('写しの指摘は種別と severity だけを持つ（余分な鍵: ' + (@($leaked.ToArray() | Sort-Object -Unique) -join ',') + '）')
    Remove-YakuCatProject -Id ([string]$previewProject.Id)
    # 確定して落ちた行は、従来どおり qc_findings を持つ（そちらを壊していない）
    $confirmedProject = New-BlockedProject -Sources @($srcFixed) -Targets @('We cut overhead.') -Setup $addFixedTerm
    $confirmBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $confirmedProject -Index 0 } catch { $confirmBlocked = $true }
    Chk $confirmBlocked '用語で落ちる行は、従来どおり確定を断られる（止める条件は変えていない）'
    $confirmedRows = @(((ConvertTo-YakuCatProjectJson -Project $confirmedProject) | ConvertFrom-Json).segments)
    Chk (@($confirmedRows[0].qc_findings).Count -ge 1) ('断られた行には従来どおり qc_findings が残る（実際 ' + @($confirmedRows[0].qc_findings).Count + ' 件）')
    Remove-YakuCatProject -Id ([string]$confirmedProject.Id)

    # ------------------------------------------------------------------ (i)
    # ディスクの一線。src/CatProject.ps1 の註（Get-YakuCatOutputEligibility と
    # ConvertTo-YakuCatProjectJson の2か所）が「写しの点検結果は実セグメントへは
    # 書かない」と言っている。メモリ上の Segment.QcFindings を守る門は3本あるが、
    # **2026-08-15 の実測では、ディスク側の門は0本だった**。
    # Save-YakuCatProject が qc_preview を generations/<id>/segments.jsonl へ
    # 書き足しても（実際に書いて DISK-HAS-QC-PREVIEW=True を確認したうえで）
    # tools/ の55本が全部緑のまま通った。segments.jsonl に触れる試験は
    # Test-YakuV9162Horizon1.ps1 と Test-YakuV9170SourceRebase.ps1 の2本しか無く、
    # どちらも qc_findings も qc_preview も見ていない。註だけが一線を守っていた。
    #
    # ここでは実際に保存して、書かれたファイルを読む。
    # **qc_findings（確定処理が走ったときの本物）は残ってよい。** 取り違えないよう、
    # 同じ保存物の中で「本物の findings は残っている／写しの qc_preview は無い」を
    # 対で見る。findings 側を見ないと、この門は「何も読めていない」でも緑になる。
    Write-Host '(i) 写しの点検結果が、保存したファイルへ漏れていない' -ForegroundColor Cyan
    $diskProject = New-BlockedProject -Sources @($srcFixed, $srcAmount) `
                                      -Targets @('We cut overhead.', 'Revenue was 100 oku yen.') `
                                      -Setup $addFixedTerm
    # 1行目は確定を断られる。断られても点検そのものは走っているので、実セグメントへ
    # 本物の qc_findings が残る。これが「残ってよい側」の題材になる。
    $diskConfirmBlocked = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $diskProject -Index 0 } catch { $diskConfirmBlocked = $true }
    Chk $diskConfirmBlocked '題材の1行目は従来どおり確定を断られる（止める条件は変えていない）'
    $diskRows = @(((ConvertTo-YakuCatProjectJson -Project $diskProject) | ConvertFrom-Json).segments)
    Chk ($diskRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $diskRows.Count + '）')
    if ($diskRows.Count -eq 2) {
        Chk (@($diskRows[0].qc_findings).Count -ge 1) ('その行は本物の qc_findings を持っている（実際 ' + @($diskRows[0].qc_findings).Count + ' 件）')
        # ここが空だと、この節は「そもそも漏れようがない」題材を見ていることになる。
        Chk (@($diskRows[0].qc_preview).Count -ge 1) ('同じ行は写しの qc_preview も持っている（この題材が空振りでない。実際 ' + @($diskRows[0].qc_preview).Count + ' 件）')
    }
    $diskSaved = Save-YakuCatProject -Project $diskProject
    Chk ([bool]$diskSaved) '保存できた（保存が落ちていたら、以下は「読めなかった」であって「漏れていない」ではない）'
    $diskDir = Join-Path $script:YakuCatTestStore ([string]$diskProject.Id)
    Chk (Test-Path -LiteralPath $diskDir -PathType Container) ('保存先のディレクトリができている: ' + $diskDir)
    $diskFiles = @(Get-ChildItem -LiteralPath $diskDir -Recurse -File -ErrorAction SilentlyContinue)
    Chk ($diskFiles.Count -ge 1) ('保存されたファイルがある（実際 ' + $diskFiles.Count + ' 個）')
    $segmentFiles = @($diskFiles | Where-Object { [string]$_.Name -eq 'segments.jsonl' })
    Chk ($segmentFiles.Count -ge 1) ('segments.jsonl がある（実際 ' + $segmentFiles.Count + ' 個）')
    # 1) 字面。保存物のどのファイルにも `qc_preview` という語が無いこと。
    #    Write-YakuTextAtomic は UTF-8 BOM 付きで書く。ReadAllText は BOM を落とす。
    $diskUtf8 = New-Object Text.UTF8Encoding($false)
    $diskLeaks = New-Object System.Collections.Generic.List[string]
    foreach ($file in $diskFiles) {
        $text = ''
        try { $text = [string][IO.File]::ReadAllText($file.FullName, $diskUtf8) } catch { $diskLeaks.Add('読めなかった: ' + $file.FullName) | Out-Null; continue }
        if ($text.Contains('qc_preview')) { $diskLeaks.Add('字面 qc_preview: ' + $file.FullName) | Out-Null }
    }
    Chk ($diskLeaks.Count -eq 0) ('保存物のどのファイルにも qc_preview の語が無い（漏れ: ' + (@($diskLeaks.ToArray()) -join ' / ') + '）')
    # 2) 鍵。segments.jsonl の各行を JSON として解いて、鍵の名前で見る。
    #    字面照合だけだと、鍵名を変えて書く改変（qcPreview など）を素通しする。
    $diskLines = 0
    $diskFindingsOnDisk = 0
    $diskPreviewKeys = New-Object System.Collections.Generic.List[string]
    $diskFindingsKeyRows = 0
    foreach ($file in $segmentFiles) {
        $text = [string][IO.File]::ReadAllText($file.FullName, $diskUtf8)
        foreach ($line in @($text -split "`n")) {
            $trimmed = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $diskLines++
            $record = $trimmed | ConvertFrom-Json
            foreach ($name in @($record.PSObject.Properties.Name)) {
                $flat = ([string]$name).ToLowerInvariant().Replace('_', '')
                if ($flat -eq 'qcpreview') { $diskPreviewKeys.Add([string]$name + ' @ ' + $file.Name) | Out-Null }
                if ([string]$name -eq 'qc_findings') { $diskFindingsKeyRows++ }
            }
            $diskFindingsOnDisk += @($record.qc_findings).Count
        }
    }
    Chk ($diskLines -eq 2) ('保存された行は2行（実際 ' + $diskLines + '）')
    Chk ($diskPreviewKeys.Count -eq 0) ('保存された行に写しの点検の鍵が1つも無い（漏れ: ' + (@($diskPreviewKeys.ToArray()) -join ' / ') + '）')
    # 3) 取り違え防止。本物の qc_findings は消していない。ここが 0 になったら、
    #    この節は「ディスクに何も無い」を見ているだけで、一線を守っていない。
    Chk ($diskFindingsKeyRows -eq $diskLines) ('保存されたどの行にも qc_findings の鍵がある（実際 ' + $diskFindingsKeyRows + ' / ' + $diskLines + '）')
    Chk ($diskFindingsOnDisk -ge 1) ('本物の点検結果はディスクにも残っている（実際 ' + $diskFindingsOnDisk + ' 件。0 ならこの節は何も読めていない）')
    Remove-YakuCatProject -Id ([string]$diskProject.Id)

    # ------------------------------------------------------------------ (g)
    Write-Host '(g) 実装の註が3つになっている' -ForegroundColor Cyan
    $catText = [IO.File]::ReadAllText($catPath, [Text.UTF8Encoding]::new($false))
    Chk (-not $catText.Contains('残す歯止めは2つだけにする')) '「2つだけ」という註が残っていない'
    Chk ($catText.Contains('残す歯止めは3つ')) '註が3つと書いている'
    foreach ($code in $rowLevel) { Chk ($catText -match ('残す歯止めは3つ(?s).{0,900}' + [regex]::Escape($code))) ('註が ' + $code + ' を挙げている') }

    Write-Host ''
    if ($script:fail -gt 0) { Write-Host ('Export blocker reason tests failed: ' + $script:fail) -ForegroundColor Red }
    else { Write-Host 'Export blocker reason tests passed.' -ForegroundColor Green }
}
finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:fail -gt 0) { exit 1 }
exit 0
