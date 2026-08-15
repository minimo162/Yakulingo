<#
.SYNOPSIS
  書き出しが止まった理由を、種別ごとの文言で言えているかの回帰テスト。

.DESCRIPTION
  CLAUDE.md が唯一「宿題」と明記していた項目。止まる理由コードは
  segment-qc-failed の1本しか無いのに、その裏では 18 種の QC error が動いている。
  1本に丸めたままだと、用語集で止まった利用者が「数字の点検に通らない行が
  あります」と言われ、数字を見に行く。何を直せば押せるのかが画面から分からない。

  **止める条件は1つも減らしていない。** ここで測るのは説明だけである。
  (f) がそれを表明する（理由の顔ぶれと、止まるかどうかが従来のままであること）。

  見るのは7つ。
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
      **警告専用の finding を1つ足しただけで「18種」の数え上げが赤くなる。**
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
    # finding を1つ足しただけで門が「19種」で赤くなり、次の担当者が
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
    Chk ($qcCodes.Count -eq 18) ('QC の error コードは 18 種（実際 ' + $qcCodes.Count + '）')
    # error になり得ない種別を「止める種別」として数えていないこと。
    Chk (@($nonErrorCodes | Where-Object { $qcCodes -contains $_ }).Count -eq 0) 'error にならない finding を、止める種別として数えていない'

    # 種別ごとの文言が、18種すべてに用意されていること。ここが空くと、点検を
    # 増やしたのに説明を足し忘れた分だけ「自動点検に通らない」へ落ちる。
    $generic = '自動点検に通らない行が'
    $covered = 0
    foreach ($code in $qcCodes) {
        $message = Get-YakuQcMessageFor -Code $code -Rows 1
        if (-not [string]::IsNullOrWhiteSpace($message) -and -not $message.StartsWith($generic)) { $covered++ }
        else { Write-Host ('     未整備: ' + $code) -ForegroundColor Yellow }
    }
    Chk ($covered -eq $qcCodes.Count) ('18種すべてに専用の文言がある（実際 ' + $covered + '/' + $qcCodes.Count + '）')
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
    # 種別ごとに違う文言であること（19本すべてで見る。end-to-end で作れる12種だけでは
    # 足りない。写経して差し替え忘れた文言は、ここでしか捕まらない）。
    $allMessages = @($messageCodes | ForEach-Object { Get-YakuQcMessageFor -Code $_ -Rows 1 })
    Chk (@($allMessages | Sort-Object -Unique).Count -eq $messageCodes.Count) ('19本の文言が互いに違う（実際 ' + @($allMessages | Sort-Object -Unique).Count + '/' + $messageCodes.Count + '）')

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
        [pscustomobject]@{ Name='currency-mismatch'; Sources=@($srcDollar); Targets=@('Sales were recorded.'); Setup=$null; Sole=$true; Expect='通貨（円・ドルなど）が原文と合っていない' }
        [pscustomobject]@{ Name='numeric-sign-missing'; Sources=@($srcSign); Targets=@('152 oku yen.'); Setup=$null; Sole=$true; Expect='損失や減少を示すマイナスが訳文に入っていない' }
        [pscustomobject]@{ Name='numeric-value-order-mismatch'; Sources=@($srcOrder); Targets=@('Profit was 200 and revenue was 100.'); Setup=$null; Sole=$true; Expect='数字の並ぶ順番が原文と違う' }
        [pscustomobject]@{ Name='numeric-value-extra'; Sources=@($srcAmount); Targets=@('Revenue was 100 oku yen in 2026.'); Setup=$null; Sole=$true; Expect='原文に無い数字が訳文に入っている' }
        [pscustomobject]@{ Name='accounting-polarity-mismatch'; Sources=@($srcProfit); Targets=@('The result declined.'); Setup=$null; Sole=$true; Expect='利益と損失、または増加と減少が原文と逆になっている' }
        [pscustomobject]@{ Name='structure-integrity'; Sources=@($srcHead); Targets=@('Overview'); Setup=$null; Sole=$true; Expect='見出しや箇条書きの形が原文と違う' }
        [pscustomobject]@{ Name='invalid-or-source-fallback'; Sources=@($srcFixed); Targets=@($srcFixed); Setup=$null; Sole=$true; Expect='訳文が原文のままか' }
        [pscustomobject]@{ Name='placeholder-residue'; Sources=@($srcFixed); Targets=@('We cut [[N1]] costs.'); Setup=$null; Sole=$false; Expect='のような差し込み記号が残っている' }
        [pscustomobject]@{ Name='numeric-value-mismatch'; Sources=@($srcAmount); Targets=@('Revenue was strong in yen.'); Setup=$null; Sole=$false; Expect='訳文で違う値になっているか抜けている' }
        [pscustomobject]@{ Name='numeric-scale-mismatch'; Sources=@('Revenue was 5 billion yen.'); Targets=@('売上高は5百万円でした。'); Setup=$null; Sole=$false; Expect='数字の桁（億・百万など）が原文と合っていない'; Direction='to_jp' }
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

    # ------------------------------------------------------------------ (d)
    Write-Host '(d) 道具の不調は、訳を見比べろとは言わない' -ForegroundColor Cyan
    # 点検そのものを落として測る。字面ではなく、実際にその枝を通す。
    $faults = @(
        [pscustomobject]@{ Function='Test-YakuNumericIntegrity'; Code='numeric-validation-error' }
        [pscustomobject]@{ Function='Test-YakuTextStructureIntegrity'; Code='structure-validation-error' }
        [pscustomobject]@{ Function='Test-YakuTerminologyCompliance'; Code='terminology-check-unavailable' }
        [pscustomobject]@{ Function='Invoke-YakuCatSegmentValidation'; Code='validation-unavailable' }
    )
    foreach ($fault in $faults) {
        $saved = (Get-Item ('function:' + [string]$fault.Function)).ScriptBlock
        Set-Item ('function:' + [string]$fault.Function) -Value { param() throw 'INJECTED_FOR_TEST' }
        try {
            $project = New-BlockedProject -Sources @($srcFixed) -Targets @('We cut fixed costs.')
            $codes = Get-QcCodesOf -Project $project
            $messages = Get-BlockerMessages -Project $project
            Chk ($codes -contains [string]$fault.Code) ([string]$fault.Code + ' として立つ（実際: ' + ($codes -join ',') + '）')
            $told = @($messages | Where-Object { $_.Contains('管理者へご連絡ください') })
            Chk ($told.Count -eq 1) ([string]$fault.Code + ' は、直しようが無いことを認めて連絡先を出す')
            Chk (@($messages | Where-Object { $_.Contains('見比べて') }).Count -eq 0) ([string]$fault.Code + ' で「原文と見比べて」とは言わない')
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
    Chk ($multiCodes -contains 'terminology-missing' -and $multiCodes -contains 'currency-mismatch' -and $multiCodes -contains 'numeric-sign-missing') ('3種が同時に立つ（実際: ' + ($multiCodes -join ',') + '）')
    $indexOf = { param([string]$needle) return [array]::FindIndex([string[]]$multiMessages, [Predicate[string]]{ param($m) $m.Contains($needle) }) }
    $iSign = & $indexOf '損失や減少を示すマイナス'
    $iCurrency = & $indexOf '通貨（円・ドルなど）'
    $iTerm = & $indexOf '登録した訳語が使われていない'
    Chk ($iSign -ge 0 -and $iCurrency -ge 0 -and $iTerm -ge 0) '3種の文言がすべて出る（1つに丸めない）'
    Chk ($iSign -lt $iCurrency -and $iCurrency -lt $iTerm) ('並びは 数字 → 通貨 → 用語 で固定（実際 ' + $iSign + ',' + $iCurrency + ',' + $iTerm + '）')
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
    Chk (-not [bool]$multiPreflight.Eligible -and @($multiPreflight.Blockers).Count -ge 3) '止まっている以上、blockers に出る'
    Chk (@(@($multiPreflight.Blockers) | Where-Object { [string]$_.code -eq 'segment-qc-failed' }).Count -ge 3) '機械が読む code は segment-qc-failed のまま（鍵は変えない）'
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
