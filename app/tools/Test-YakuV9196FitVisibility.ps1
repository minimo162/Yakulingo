<#
.SYNOPSIS
  収まりの見える化（自動spill幅・絞り込み・1クリック導線・実幅由来のmax_chars）の回帰テスト。

.DESCRIPTION
  見るのは3つ。

  (a) 静的部。cat.js に共有判定関数（segmentFitRisk・autoSpillColumns・
      segmentFitRiskInfo・segmentFitCapacity）が実在し、previewCellHtml と
      絞り込み・行の印の両方が同じ segmentFitRisk を使っていること。
      絞り込みボタン（cat.html の data-cat-filter）と stateFilters の鍵が
      1対1であること（:774 の決まり）。既存の aria-label 文言（V9185が
      固定する「収まり要確認」）が変わっていないこと。1クリック導線が
      既存の openPlacementEditor・openPublicationCandidates だけを呼び、
      新しい /api/cat/* を呼んでいないこと。

  (b) 実機Chromium部。本物の cat.html/cat.js を配り、14行の作業（main）と
      301行の作業（perf）を開いて実際に押す。
        - 自動spill幅: 右が空2列→加算される（open）／右が占有→加算されない
          （occupied）／右が数式セル→加算されない（formula）／非表示列で
          停止（hidden）／未知幅列で停止（unknown）／右寄せは自動適用しない
          （right-align）／宣言済みspillは自動が0列のときのフォールバックで
          従来どおり効く（declared-fallback）／結合セルで停止（merge-stop）
        - 絞り込み: 収まらない見込みの行数でボタンが出て、押すと該当行だけに
          絞られる（1912x987・1380x900の両方の窓で。MINOR-6d）
        - 1クリック導線: 行のボタンを押すと配置ダイアログと公開候補ダイアログの
          両方が開く。訳が空の行には出ない
        - max_chars: 実幅が引ける行は実測由来の値（20字下限なし・8..99へ
          クランプ済み、同じ式で独立に求めた期待値と一致）、層が引けない行は
          従来の0.8倍（20字下限つき・厳密に一致）
        - 訳が空の行は「収まらない見込み」に数えない・印も付けない・行の
          ボタンも出ない（原文だけなら明らかにはみ出す長さにしてある）
        - シートの最終内容列より右は使える幅の根拠にしない: 300行「右に
          何も無い」行の初回描画が3秒を大きく下回ること（CoD審査
          2026-08-18 REWORK-1 が実測した25倍の描画退行が戻っていないかの
          歯止め）。最終内容列そのもののセル（narrowな列・長い訳）は
          正しくはみ出しと判定されること
      node/Playwright/Chromium が無い環境では UNMEASURED（exit 3）にする。
      「測れなかった」を赤に畳まない。

  (c) 突然変異の実証。cat.js を一時的に壊し、この試験が実際に赤へ落ちる
      ことを別プロセスで確かめる（このファイルの実行だけでは行わない。
      呼び出し側の手順で実施し、結果をログへ残す）。最終内容列の上限を
      外す変異は必須（CoD審査 2026-08-18 REWORK-1 の指示）。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9196FitVisibility.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$N9196Root = Split-Path -Parent $PSScriptRoot
$N9196Www = Join-Path $N9196Root 'www'
$script:N9196Failures = New-Object System.Collections.Generic.List[string]

function Assert-N9196 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) }
    else { Write-Host ('  NG   ' + $Message); [void]$script:N9196Failures.Add($Message) }
}

Write-Host 'Test-YakuV9196FitVisibility'

# ============================================================ (a) 静的部
Write-Host '-- static --'

$N9196CatJsPath = Join-Path $N9196Www 'assets\cat.js'
$N9196CatHtmlPath = Join-Path $N9196Www 'cat.html'
$N9196CatJs = [IO.File]::ReadAllText($N9196CatJsPath, [Text.Encoding]::UTF8)
$N9196CatHtml = [IO.File]::ReadAllText($N9196CatHtmlPath, [Text.Encoding]::UTF8)

Assert-N9196 ($N9196CatJs -match 'function autoSpillColumns\(layout, row, column, span(?:, previewLimit)?\)') 'autoSpillColumns が実在する（プレビューだけ任意の上限を渡せる）'
Assert-N9196 ($N9196CatJs -match 'function segmentFitRisk\(segment, layout, row, column, span, text, bold(?:, previewLimit)?\)') 'segmentFitRisk（共有判定）が実在する（プレビューだけ任意の上限を渡せる）'
Assert-N9196 ($N9196CatJs.Contains('function segmentFitRiskInfo(segment)')) 'segmentFitRiskInfo（絞り込み・行の印の入口）が実在する'
Assert-N9196 ($N9196CatJs.Contains('function segmentFitCapacity(segment)')) 'segmentFitCapacity（max_charsの実幅由来）が実在する'

# 自動spillの停止条件が5つとも書かれていること（占有・数式は同じ occupied 集合、
# 非表示・結合・未知幅は別々）。
Assert-N9196 ($N9196CatJs.Contains('if (!previewColumnsHaveKnownWidth(layout, next, 1)) break;')) '自動spillが未知幅列で止まる'
Assert-N9196 ($N9196CatJs.Contains('if (layout.hidden[next]) break;')) '自動spillが非表示列で止まる'
Assert-N9196 ($N9196CatJs.Contains('if (layout.covered[key] || layout.spans[key] || layout.occupied[key]) break;')) '自動spillが結合・占有・数式で止まる'
Assert-N9196 ($N9196CatJs.Contains("(found.occupied_cells || []).concat(found.formula_cells || [])")) '占有セルと数式セルの両方を止める根拠に使う（サーバの宣言spill検証と同じ条件）'

# REWORK-1 (MAJOR-1/2): 最終内容列より右は使える幅の根拠にしない。
# previewLayout がシートごとに1回だけ求め、autoSpillColumns はその値で歩きを
# 打ち切る（行ごとに求めない・16384への無制限の歩きをしない）。
Assert-N9196 ($N9196CatJs.Contains('lastContentColumn: lastContentColumn,')) 'previewLayout がシートごとに最終内容列を1回だけ求めて __prepared に持たせる'
Assert-N9196 ($N9196CatJs.Contains('var bound = Math.min(YAKU_PREVIEW_MAX_COLUMN, Number(layout.lastContentColumn) || 0);')) '自動spillの歩きは最終内容列（と物理上限16384の小さいほう）で打ち切る'
Assert-N9196 ($N9196CatJs.Contains('while (next <= bound) {')) '歩きの継続条件が最終内容列の bound を使っている（16384固定ではない）'

# previewCellHtml とプレビュー以外（絞り込み・行の印・max_chars）が、同じ
# segmentFitRisk を呼んでいること（判定の分岐が2つに増えていないか）。
$N9196FitRiskCallers = [regex]::Matches($N9196CatJs, 'segmentFitRisk\(').Count
Assert-N9196 ($N9196FitRiskCallers -ge 3) ('segmentFitRisk は複数箇所（プレビュー・絞り込み系・文字目標）から呼ばれる（実測 ' + $N9196FitRiskCallers + ' 箇所）')
Assert-N9196 ($N9196CatJs.Contains('var fit = segmentFitRisk(segment, layout, row, column, span, value.text,')) 'previewCellHtml が segmentFitRisk を使う（独自の再計算をしない）'

# V9185 が固定する aria-label 文言（純粋な抽出であることの静的な裏付け）。
Assert-N9196 ($N9196CatJs.Contains('aria-label="収まり要確認: PDFで切れを確認してください"')) 'aria-label の文言はプレビューでは変えていない（V9185 互換）'

# 絞り込みボタンと鍵の1対1（cat.js :774 の決まり）。
$N9196StateFiltersBlock = [regex]::Match($N9196CatJs, '(?s)var stateFilters = \{(.*?)\};')
Assert-N9196 $N9196StateFiltersBlock.Success 'stateFilters の定義ブロックが見つかる'
$N9196FilterKeys = @()
if ($N9196StateFiltersBlock.Success) {
    $N9196FilterKeys = @([regex]::Matches($N9196StateFiltersBlock.Groups[1].Value, '(?m)^\s*(\w+):\s*function') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
$N9196HtmlFilterKeys = @([regex]::Matches($N9196CatHtml, 'data-cat-filter="(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-N9196 (($N9196FilterKeys.Count -gt 0) -and (-not (Compare-Object $N9196FilterKeys $N9196HtmlFilterKeys))) `
    ('stateFilters の鍵と cat.html の data-cat-filter が1対1（js=' + ($N9196FilterKeys -join ',') + ' / html=' + ($N9196HtmlFilterKeys -join ',') + '）')
Assert-N9196 ($N9196FilterKeys -contains 'fit') 'fit が stateFilters に入っている'
Assert-N9196 (($N9196HtmlFilterKeys | Where-Object { $_ -eq 'fit' } | Measure-Object).Count -eq 1) 'data-cat-filter="fit" は1個だけ（重複していない）'

# 0件なら隠す（qc/repetition/review_notesと同じ optionalFilterCounts の仲間）。
Assert-N9196 ($N9196CatJs -match "\['qc','repetition','review_notes','fit'\]\.forEach\(function \(name\) \{\s*var button") 'syncOptionalStateFilters が fit を qc/repetition/review_notes と同じ扱いにする'
Assert-N9196 ($N9196CatJs -match "\['qc','repetition','review_notes','fit'\]\.forEach\(function \(name\) \{ optionalFilterCounts") 'renderRows の optionalFilterCounts が fit を数える'

# 1クリック導線は新しいAPIを作らない（既存の openPlacementEditor・
# openPublicationCandidates だけを呼ぶ）。
$N9196FlowBody = [regex]::Match($N9196CatJs, '(?s)function openFitPublicationFlow\(index\) \{(.*?)\n  \}')
Assert-N9196 $N9196FlowBody.Success 'openFitPublicationFlow が実在する'
if ($N9196FlowBody.Success) {
    $N9196FlowText = $N9196FlowBody.Groups[1].Value
    Assert-N9196 ($N9196FlowText.Contains('openPlacementEditor(index)')) '既存の openPlacementEditor を呼ぶ（配置ダイアログはここで開く）'
    Assert-N9196 ($N9196FlowText.Contains('openPublicationCandidates()')) '既存の openPublicationCandidates を自動で発火する'
    Assert-N9196 (-not $N9196FlowText.Contains("post(")) '新しい /api/cat/* は呼んでいない（既存の2関数を呼ぶだけ）'
}
Assert-N9196 ($N9196CatJs.Contains("if (button.hasAttribute('data-cat-fit-candidates')) { return openFitPublicationFlow(button.getAttribute('data-cat-fit-candidates')); }")) '行のボタンの配線が既存のクリック委譲に乗っている'
Assert-N9196 ($N9196CatJs -match "busy && \(button\.id === 'cat-confirm-bulk'.*data-cat-fit-candidates") '翻訳中はこのボタンも止める（他の行操作と同じ歯止め）'

# max_chars: 実幅が取れれば実測、取れなければ従来の0.8倍（20字下限つき）へ
# フォールバック（REWORK-1 MAJOR-3/4: 実測側の20字下限は外し、8..99へ
# クランプしてから送る。生の値とクランプの理由（basis）を状態行が正直に言う）。
Assert-N9196 ($N9196CatJs.Contains('var measuredCapacity = segmentFitCapacity(segment);')) 'generatePublicationCandidates が segmentFitCapacity を先に試す'
# 2026-08-22（#106 flatten, 28600d1）に算出部は generatePublicationCandidates から
# computeFitBudget へ純粋抽出された。フォールバック式の字面はそちらへ移っただけで、
# 意味論は変わっていない（currentText = segmentFitText(segment)。訳文が無ければ
# 原文で代行する点だけが旧ピンの String(segment.translation||'') との違いで、
# 層が引けない行で訳文が入っているというこの試験の題材では同じ値になる）。
# 「従来の0.8倍・20字下限」の振る舞いそのものは、実機部の fallback 断言が見る。
Assert-N9196 ($N9196CatJs.Contains('var maxChars = measuredCapacity ? measuredCapacity.maxChars : Math.max(20, Math.floor(currentText.length * 0.8));')) '実測できないときだけ従来の0.8倍（20字下限つき）へ落ちる（computeFitBudget のフォールバック）'
Assert-N9196 ($N9196CatJs.Contains('var raw = Math.floor(text.length * Math.max(0, fit.displayWidthPx - 8) / fit.textWidthPx);')) 'segmentFitCapacity は生の容量（20字下限を掛けない）をまず出す'
Assert-N9196 (-not ($N9196CatJs -match 'Math\.max\(20,\s*Math\.floor\(text\.length')) '実測側には20字下限を掛けていない（実容量8〜11字の行に「20字」と出ていた誤りの再発防止）'
Assert-N9196 ($N9196CatJs.Contains('return { raw: raw, maxChars: Math.min(99, Math.max(8, raw)), basis: basis };')) 'segmentFitCapacity がサーバの使える窓[8,99]へクランプしてから返す'
Assert-N9196 ($N9196CatJs.Contains("var basis = raw < 8 ? 'below-min' : (raw > 99 ? 'above-max' : 'measured');")) 'クランプが効いたかどうかを basis に持つ'
Assert-N9196 ($N9196CatJs -match "below-min[\s\S]{0,40}文字目標 8字（下限") '状態行が下限クランプ（8字）を正直に言う'
Assert-N9196 ($N9196CatJs -match "above-max[\s\S]{0,40}文字目標 99字（上限") '状態行が上限クランプ（99字）を正直に言う'

# REWORK-1 (MAJOR-5): 訳がまだ空の行は「収まらない見込み」に数えない・印も
# 付けない・行のボタンも出さない（配置計画は掲載訳が空でないことが前提。
# src/CatProject.ps1:1877）。ゲートは segmentFitRiskInfo の入口にあるので、
# 絞り込み・行の印・1クリック導線の全部へ一度に効く。
Assert-N9196 ($N9196CatJs.Contains("if (!String(segment.translation || '').trim()) return { risk: false };")) 'segmentFitRiskInfo が訳の空を先に弾く'

# ============================================================ (b) 実機Chromium部
Write-Host '-- chromium --'

$YAKU_FIT_UNMEASURED = 3
$N9196Driver = Join-Path $PSScriptRoot 'fit-screen\fit-screen-gate.js'
$N9196Node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $N9196Node -or -not (Test-Path -LiteralPath $N9196Driver -PathType Leaf)) {
    Write-Host 'UNMEASURED: node または Chromium 運転席が無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9196Failures.Count -gt 0) {
        Write-Host ("FAIL " + $script:N9196Failures.Count + ' assertion(s) in static part')
        exit 1
    }
    exit $YAKU_FIT_UNMEASURED
}
$N9196NodeExe = [string]$N9196Node.Source
$N9196ProbeDir = (Split-Path -Parent $N9196Driver).Replace('\', '/')
$null = & $N9196NodeExe -e ("try{require.resolve('playwright',{paths:['" + $N9196ProbeDir + "']});process.exit(0)}catch(e){process.exit(9)}") 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UNMEASURED: playwright が無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9196Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9196Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_FIT_UNMEASURED
}
$N9196ChromiumPath = & $N9196NodeExe -e ("try{const fs=require('fs');const api=require(require.resolve('playwright',{paths:['" + $N9196ProbeDir + "']}));const executable=api.chromium.executablePath();if(!executable||!fs.existsSync(executable)){process.exit(9)}process.stdout.write(executable);process.exit(0)}catch(e){process.exit(9)}") 2>$null
$N9196ChromiumExit = $LASTEXITCODE
if ($N9196ChromiumExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$N9196ChromiumPath) -or -not (Test-Path -LiteralPath ([string]$N9196ChromiumPath) -PathType Leaf)) {
    Write-Host 'UNMEASURED: Playwright Chromium 実行ファイルが無いため実機を測れません。' -ForegroundColor Red
    if ($script:N9196Failures.Count -gt 0) { Write-Host ("FAIL " + $script:N9196Failures.Count + ' assertion(s) in static part'); exit 1 }
    exit $YAKU_FIT_UNMEASURED
}

# --- 題材を組む -----------------------------------------------------------
# 列の並び（シート Fit1、行はすべて1）。anchor は幅1（12px）で単独では必ず
# はみ出す。wide は幅50（355px）で、加算されると必ず収まる。この落差を
# 大きく取ることで、実際のフォント計測系（Arial のフォールバック含む）に
# 依存せず判定が揺れないようにする。
#   A(1)     anchor0 open            B,C(2-3) 空・幅50    D(4) 占有（停止）
#   E(5)     anchor1 occupied        F(6) 占有（即停止）
#   H(8)     anchor2 formula         I(9) 数式のみ（即停止）
#   K(11)    anchor3 hidden          L(12) 非表示（即停止）
#   N(14)    anchor4 unknown         O(15) 幅属性なし＝未知幅（即停止）
#   Q(17)    anchor5 right-align     R(18) 空・幅50（右寄せなので使わない）
#   S(19)    anchor6 declared        T(20) 空・幅50（宣言spillの対象）
#   U(21)    anchor7 row-action      V(22) 占有（即停止）
#   W(23)    anchor8 max-chars       X,Y(24-25) 空・幅50  Z(26) 占有（停止）
#   AA(27)   anchor10 merge-stop     AB:AC(28-29) 結合（即停止）
#   AD(30)   anchor11 untranslated（訳が空。原文だけなら明らかにはみ出す長さ）
#   AE(31)   anchor12 max-normal     AF(32) 空・幅50   AG(33) 占有（停止）
#   AH(34)   anchor13 max-below      AI(35) 占有（即停止）
# REWORK-1 (MAJOR-3/4): max_chars は3つの領域を別々の行で見る。
#   above-max … index8（従来のindex8。spillが広く、生の容量が99を超える）
#   measured  … index12（8..99の範囲に収まる、クランプなしの素の実測）
#   below-min … index13（spillが無く、生の容量が8を下回る）
$N9196MeasuredText = 'Moderately long translated sentence used to check the measured capacity formula end to end.'
$N9196FallbackText = 'Another translated sentence used only to check the zero point eight fallback path.'
$N9196UntranslatedSource = 'This original source text is deliberately very long, so that if the translation-empty gate were ever removed it would obviously overflow the narrow column and get flagged by mistake.'
# 生の容量（raw）は「この幅・この書体に平均的な英文が何字入るか」で決まり、
# 文字列そのものの長さにはほぼ左右されない（raw ≈ 予算px ÷ 平均字幅）。
# 収まらない見込み（overflowRisk）に入れるには、実際の訳文の長さが raw を
# 上回っている必要がある。最初 53字の文で試したところ raw=61 で「収まる」
# 側に落ちた（実測 2026-08-18 REWORK-1 検証時）ので、121字まで伸ばした。
$N9196NormalText = 'Shorten this particular cell so that its translated text actually fits inside the available printable width area, please.'
$N9196BelowText = 'This cell needs a much shorter version because the column is extremely narrow and nothing empty follows it on the right.'

$N9196Columns = @(
    [ordered]@{ min = 1; max = 1; width = 1; hidden = $false }
    [ordered]@{ min = 2; max = 3; width = 50; hidden = $false }
    [ordered]@{ min = 4; max = 4; width = 50; hidden = $false }
    [ordered]@{ min = 5; max = 5; width = 1; hidden = $false }
    [ordered]@{ min = 6; max = 6; width = 50; hidden = $false }
    [ordered]@{ min = 8; max = 8; width = 1; hidden = $false }
    [ordered]@{ min = 9; max = 9; width = 50; hidden = $false }
    [ordered]@{ min = 11; max = 11; width = 1; hidden = $false }
    [ordered]@{ min = 12; max = 12; width = 50; hidden = $true }
    [ordered]@{ min = 14; max = 14; width = 1; hidden = $false }
    [ordered]@{ min = 17; max = 17; width = 1; hidden = $false }
    [ordered]@{ min = 18; max = 18; width = 50; hidden = $false }
    [ordered]@{ min = 19; max = 19; width = 1; hidden = $false }
    [ordered]@{ min = 20; max = 20; width = 50; hidden = $false }
    [ordered]@{ min = 21; max = 21; width = 1; hidden = $false }
    [ordered]@{ min = 22; max = 22; width = 50; hidden = $false }
    [ordered]@{ min = 23; max = 23; width = 1; hidden = $false }
    [ordered]@{ min = 24; max = 25; width = 50; hidden = $false }
    [ordered]@{ min = 26; max = 26; width = 50; hidden = $false }
    [ordered]@{ min = 27; max = 27; width = 1; hidden = $false }
    [ordered]@{ min = 28; max = 29; width = 50; hidden = $false }
    [ordered]@{ min = 30; max = 30; width = 1; hidden = $false }
    [ordered]@{ min = 31; max = 31; width = 1; hidden = $false }
    [ordered]@{ min = 32; max = 32; width = 50; hidden = $false }
    [ordered]@{ min = 33; max = 33; width = 50; hidden = $false }
    [ordered]@{ min = 34; max = 34; width = 1; hidden = $false }
    [ordered]@{ min = 35; max = 35; width = 50; hidden = $false }
)
$N9196SheetLayout = [ordered]@{
    name = 'Fit1'; default_width = 8.43; default_height = 18.75
    columns = $N9196Columns
    unknown_width_columns = @([ordered]@{ min = 15; max = 15; hidden = $false })
    merges = @('AB1:AC1')
    occupied_cells = @('D1', 'F1', 'V1', 'Z1', 'AG1', 'AI1')
    formula_cells = @('I1')
    rows = @()
    cells = @([ordered]@{ address = 'Q1'; align = 'right' }, [ordered]@{ address = 'S1'; align = 'center' })
}

function New-N9196Segment {
    param([int]$Index, [string]$Id, [string]$Source, [string]$Translation, [string]$Location, $Placement = $null)
    $seg = [ordered]@{
        index = $Index; segment_id = $Id; source = $Source; translation = $Translation
        kind = 'cell'; location = $Location; confirmed = $false
    }
    if ($null -ne $Placement) { $seg.placement = $Placement }
    return $seg
}

$N9196Segments = @(
    (New-N9196Segment -Index 0 -Id 'fit-open' -Source 'src open' -Translation 'AB' -Location 'Fit1, A1')
    (New-N9196Segment -Index 1 -Id 'fit-occupied' -Source 'src occupied' -Translation 'AB' -Location 'Fit1, E1')
    (New-N9196Segment -Index 2 -Id 'fit-formula' -Source 'src formula' -Translation 'AB' -Location 'Fit1, H1')
    (New-N9196Segment -Index 3 -Id 'fit-hidden' -Source 'src hidden' -Translation 'AB' -Location 'Fit1, K1')
    (New-N9196Segment -Index 4 -Id 'fit-unknown' -Source 'src unknown' -Translation 'AB' -Location 'Fit1, N1')
    (New-N9196Segment -Index 5 -Id 'fit-right' -Source 'src right align' -Translation 'AB' -Location 'Fit1, Q1')
    (New-N9196Segment -Index 6 -Id 'fit-declared' -Source 'src declared' -Translation 'AB' -Location 'Fit1, S1' -Placement ([ordered]@{
        destinations = @([ordered]@{ sheet = 'Fit1'; address = 'S1'; text = 'AB'; mode = 'replace_source_block' })
        display_regions = @([ordered]@{ mode = 'spill_right_display_only'; anchor_address = 'S1'; cells = @('T1'); verification = 'requires_pdf_visual_review' })
    }))
    (New-N9196Segment -Index 7 -Id 'fit-rowaction' -Source 'src row action' -Translation 'AB' -Location 'Fit1, U1' -Placement ([ordered]@{
        destinations = @([ordered]@{ sheet = 'Fit1'; address = 'U1'; text = 'AB'; mode = 'replace_source_block' })
    }))
    (New-N9196Segment -Index 8 -Id 'fit-measured' -Source 'src measured' -Translation $N9196MeasuredText -Location 'Fit1, W1' -Placement ([ordered]@{
        destinations = @([ordered]@{ sheet = 'Fit1'; address = 'W1'; text = $N9196MeasuredText; mode = 'replace_source_block' })
    }))
    (New-N9196Segment -Index 9 -Id 'fit-fallback' -Source 'src fallback' -Translation $N9196FallbackText -Location 'NoLayout, A1' -Placement ([ordered]@{
        destinations = @([ordered]@{ sheet = 'NoLayout'; address = 'A1'; text = $N9196FallbackText; mode = 'replace_source_block' })
    }))
    (New-N9196Segment -Index 10 -Id 'fit-merge' -Source 'src merge' -Translation 'AB' -Location 'Fit1, AA1')
    # REWORK-1 (MAJOR-5): 訳が空。原文だけで判定してしまう実装なら、この
    # 長い原文が明らかにはみ出すので、絞り込み・印・行のボタンに出てしまう。
    (New-N9196Segment -Index 11 -Id 'fit-untranslated' -Source $N9196UntranslatedSource -Translation '' -Location 'Fit1, AD1')
    # REWORK-1 (MAJOR-3/4): 生の容量が8..99の範囲に収まる行（クランプなしの
    # 素の実測値になるはず）。
    (New-N9196Segment -Index 12 -Id 'fit-max-normal' -Source 'src max normal' -Translation $N9196NormalText -Location 'Fit1, AE1' -Placement ([ordered]@{
        destinations = @([ordered]@{ sheet = 'Fit1'; address = 'AE1'; text = $N9196NormalText; mode = 'replace_source_block' })
    }))
    # REWORK-1 (MAJOR-3/4): spillが無く、生の容量が8を下回る行（8へクランプ
    # されるはず。20字下限はここでは絶対に掛からない）。
    (New-N9196Segment -Index 13 -Id 'fit-max-below' -Source 'src max below' -Translation $N9196BelowText -Location 'Fit1, AH1' -Placement ([ordered]@{
        destinations = @([ordered]@{ sheet = 'Fit1'; address = 'AH1'; text = $N9196BelowText; mode = 'replace_source_block' })
    }))
)

$N9196Project = [ordered]@{
    id = 'fit-visibility-9196'; revision = 1; file_name = 'fit.xlsx'; document_format = 'xlsx'; direction = 'to_en'
    segments = $N9196Segments
    sheet_layout = @($N9196SheetLayout)
}

# --- perf題材: 「右に何も無い」300行＋「シートの最終内容列そのもの」1行 ----
# REWORK-1 (MAJOR-1/2 の実証)。列は A(1・幅1)と J(10・幅1)の2つだけ定義する。
# 300行は全部A列（行1〜300）で、シート全体で唯一の「中身」は J301（占有・
# 幅1・訳が長い）。J301 が無ければ最終内容列は0になり自動spillは一切効かない
# （それも正しい振る舞いだが、この題材の主眼である「最終内容列そのものの
# セルが正しくはみ出し判定される」ことを見られないので、あえて1つだけ置く）。
# 300行（列A）はどれも J301 と同じ列（10）までは歩けるが、それ以遠には
# 決して伸びない。歩きが「最終内容列」で打ち切られていなければ（＝上限を
# 外す変異を入れれば）、300行とも16384列まで歩き、初回描画が大きく遅くなる。
$N9196PerfSegments = New-Object System.Collections.Generic.List[object]
for ($n9196i = 0; $n9196i -lt 300; $n9196i++) {
    [void]$N9196PerfSegments.Add((New-N9196Segment -Index $n9196i -Id ('perf-' + $n9196i) -Source ('perf src ' + $n9196i) -Translation 'AB' -Location ('Perf1, A' + ($n9196i + 1))))
}
$N9196PerfRightmostText = 'This translation is intentionally long, so that even the rightmost content column, with nothing at all beyond it anywhere on the sheet, still gets correctly flagged as an overflow risk once the automatic right spill walk is bounded by the real used range of the sheet.'
[void]$N9196PerfSegments.Add((New-N9196Segment -Index 300 -Id 'perf-rightmost' -Source 'perf rightmost source' -Translation $N9196PerfRightmostText -Location 'Perf1, J301'))
$N9196PerfSheetLayout = [ordered]@{
    name = 'Perf1'; default_width = 8.43; default_height = 18.75
    columns = @(
        [ordered]@{ min = 1; max = 1; width = 1; hidden = $false }
        [ordered]@{ min = 10; max = 10; width = 1; hidden = $false }
    )
    unknown_width_columns = @()
    merges = @()
    occupied_cells = @('J301')
    formula_cells = @()
    rows = @()
    cells = @()
}
$N9196PerfProject = [ordered]@{
    id = 'fit-perf-9196'; revision = 1; file_name = 'fit-perf.xlsx'; document_format = 'xlsx'; direction = 'to_en'
    segments = $N9196PerfSegments.ToArray()
    sheet_layout = @($N9196PerfSheetLayout)
}

$N9196Payload = [ordered]@{ main = $N9196Project; perf = $N9196PerfProject }

$N9196Work = Join-Path ([IO.Path]::GetTempPath()) ('yaku9196-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $N9196Work -Force
$N9196ProjectJson = Join-Path $N9196Work 'project.json'
$N9196OutJson = Join-Path $N9196Work 'out.json'
$N9196OutJson1380 = Join-Path $N9196Work 'out-1380.json'
[IO.File]::WriteAllText($N9196ProjectJson, ($N9196Payload | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))

& $N9196NodeExe $N9196Driver $N9196Www $N9196ProjectJson $N9196OutJson '1912x987' 'full'
$N9196DriverExit = $LASTEXITCODE
Assert-N9196 ($N9196DriverExit -eq 0 -and (Test-Path -LiteralPath $N9196OutJson -PathType Leaf)) 'headless Chromium が実際の CAT 画面を開いた（1912x987・full）'

# MINOR-6d: 狭い窓（1380x900）でも絞り込み・行の印だけ同じ手順で再確認する。
& $N9196NodeExe $N9196Driver $N9196Www $N9196ProjectJson $N9196OutJson1380 '1380x900' 'filter'
$N9196DriverExit1380 = $LASTEXITCODE
Assert-N9196 ($N9196DriverExit1380 -eq 0 -and (Test-Path -LiteralPath $N9196OutJson1380 -PathType Leaf)) 'headless Chromium が実際の CAT 画面を開いた（1380x900・filter）'

$N9196Result = $null
if (Test-Path -LiteralPath $N9196OutJson -PathType Leaf) { $N9196Result = [IO.File]::ReadAllText($N9196OutJson, [Text.Encoding]::UTF8) | ConvertFrom-Json }
if ($null -ne $N9196Result) {
    foreach ($e in @($N9196Result.errors)) { Write-Host ('  Chromium error: ' + [string]$e) -ForegroundColor Red }
    foreach ($c in @($N9196Result.console)) { Write-Host ('  Chromium console: ' + [string]$c) -ForegroundColor Red }
    if ($N9196Result.fatal) { Write-Host ('  Chromium fatal: ' + [string]$N9196Result.fatal) -ForegroundColor Red }
}
Assert-N9196 ($null -ne $N9196Result -and @($N9196Result.errors).Count -eq 0 -and @($N9196Result.console).Count -eq 0 -and -not $N9196Result.fatal) '画面にエラーが出ていない'

if ($null -ne $N9196Result) {
    $N9196Cells = @($N9196Result.previewCells)
    function Get-N9196Cell {
        param([int]$Index)
        # 戻り値は ,@(...) で包む。包まないと一致が1個のとき関数の外へ解かれて
        # スカラーになり、PS 5.1 の PSCustomObject には .Count が無いため
        # 「印が1個ある」の比較が黙って偽になる（V9212 の同名の手当てと同じ。
        # 実測: $cell.Count は空、@($cell).Count なら 1。2026-08-23）。
        return ,@($N9196Cells | Where-Object { [int]$_.index -eq $Index })
    }

    # --- 自動spill幅 --------------------------------------------------------
    # 註: 整数キーの [ordered]@{} は使わない。System.Collections.Specialized.
    # OrderedDictionary は整数の添字を「位置」として解釈する別のインデクサを
    # 持ち、キーとしての整数一致とは別物になる（実測: Contains(10)=True なのに
    # [10] は空を返す）。ここでは (index, expected, label) の組を配列で持つ。
    $N9196SpillCases = @(
        [pscustomobject]@{ Index = 0; Expected = $false; Label = 'open: 右2列が空 → 加算されて収まる' }
        [pscustomobject]@{ Index = 1; Expected = $true; Label = 'occupied: 右が占有 → 加算されない' }
        [pscustomobject]@{ Index = 2; Expected = $true; Label = 'formula: 右が数式のみ → 加算されない' }
        [pscustomobject]@{ Index = 3; Expected = $true; Label = 'hidden: 右が非表示列 → 加算されない' }
        [pscustomobject]@{ Index = 4; Expected = $true; Label = 'unknown: 右が未知幅列 → 加算されない' }
        [pscustomobject]@{ Index = 5; Expected = $true; Label = 'right-align: 右寄せは自動spillの対象外' }
        [pscustomobject]@{ Index = 6; Expected = $false; Label = 'declared-fallback: 宣言spillが従来どおり効く' }
        [pscustomobject]@{ Index = 7; Expected = $true; Label = 'row-action: 右が占有（1クリック導線の題材）' }
        [pscustomobject]@{ Index = 10; Expected = $true; Label = 'merge-stop: 右が結合セル → 加算されない' }
    )
    foreach ($case in $N9196SpillCases) {
        $cell = Get-N9196Cell -Index $case.Index
        Assert-N9196 ($cell.Count -eq 1) ('index=' + $case.Index + ' のプレビュー印が1個ある（' + $case.Label + '）')
        if ($cell.Count -eq 1) {
            Assert-N9196 ([bool]$cell[0].overflowRisk -eq [bool]$case.Expected) `
                ('index=' + $case.Index + ' の overflowRisk は ' + $case.Expected + '（' + $case.Label + '／実測 ' + [bool]$cell[0].overflowRisk + '）')
        }
    }
    # 収まらない行は title に使える幅の根拠が出る（行側に必ず出す、利用者判断）。
    $N9196OccupiedCell = Get-N9196Cell -Index 1
    if ($N9196OccupiedCell.Count -eq 1) {
        Assert-N9196 ([string]$N9196OccupiedCell[0].title -match '使える幅') 'title に使える幅の根拠が出る'
        Assert-N9196 ([string]$N9196OccupiedCell[0].ariaLabel -match '収まり要確認') 'aria-label は従来どおり'
    }

    # --- 絞り込み・行の印 ------------------------------------------------------
    # index=12・13（max_charsのクランプ題材）も、narrowな列に実際の訳文が
    # 収まっていないので、この集合に入って正しい（訳が空のindex=11だけが
    # 除外される）。
    $N9196ExpectedRows = @(1, 2, 3, 4, 5, 7, 10, 12, 13)
    Assert-N9196 ([bool]$N9196Result.fitFilterBefore.hidden -eq $false) '収まらない見込みが1件以上あるのでボタンが自動で現れる（探す操作ゼロ）'
    Assert-N9196 ([string]$N9196Result.fitFilterBefore.count -eq '9') ('件数は9（実測 ' + [string]$N9196Result.fitFilterBefore.count + '）。訳が空のindex=11は数えない')
    Assert-N9196 ([string]$N9196Result.fitFilterAfter.pressed -eq 'True') '押すと選択状態になる'
    $N9196FilteredRows = @($N9196Result.fitFilterAfter.rows | Sort-Object)
    Assert-N9196 (-not (Compare-Object $N9196FilteredRows $N9196ExpectedRows)) ('絞り込むと該当行だけになる（実測 ' + ($N9196FilteredRows -join ',') + '）')
    $N9196BadgeRows = @(@($N9196Result.fitBadges) | ForEach-Object { [int]$_.row } | Sort-Object)
    Assert-N9196 (-not (Compare-Object $N9196BadgeRows $N9196ExpectedRows)) ('行の印（バッジ）が付く行も同じ集合になる（実測 ' + ($N9196BadgeRows -join ',') + '）')
    $N9196Badge1 = @(@($N9196Result.fitBadges) | Where-Object { [int]$_.row -eq 1 })
    if ($N9196Badge1.Count -eq 1) { Assert-N9196 ([string]$N9196Badge1[0].title -match '使える幅') '行のバッジも使える幅の根拠を title に持つ' }

    # --- 1クリック導線 --------------------------------------------------------
    Assert-N9196 ([bool]$N9196Result.rowActionButton.exists -and [bool]$N9196Result.rowActionButton.visible) '収まらない行の選択行リボンにボタンが出る'
    Assert-N9196 (-not [bool]$N9196Result.untranslatedRowActionButton) '訳が空の行（index=11）には選択行リボンのボタンが出ない'
    Assert-N9196 ([bool]$N9196Result.rowActionOpened.placementOpen) '押すと配置ダイアログが開く'
    Assert-N9196 ([bool]$N9196Result.rowActionOpened.publicationOpen) '配置ダイアログを経由せず「収める候補」まで自動で開く（cat-publication-open の自動発火）'
    Assert-N9196 ([string]$N9196Result.rowActionOpened.placementIndex -eq '7') '開いたのは押した行（index=7）'

    # --- perf: 最終内容列の上限（REWORK-1 MAJOR-1/2/MINOR-6a） -----------------
    $N9196PerfCeilingMs = 3000
    Assert-N9196 ($null -ne $N9196Result.perfFirstRenderMs) 'perf題材（301行）の初回描画の所要時間を測れた'
    if ($null -ne $N9196Result.perfFirstRenderMs) {
        Assert-N9196 ([int]$N9196Result.perfFirstRenderMs -lt $N9196PerfCeilingMs) `
            ('300行「右に何も無い」資料の初回描画は' + $N9196PerfCeilingMs + 'ms未満（実測 ' + [int]$N9196Result.perfFirstRenderMs + 'ms。上限を外す変異を入れると数秒〜十数秒に跳ね上がる）')
    }
    $N9196PerfCells = @($N9196Result.perfPreviewCells)
    $N9196PerfRightmost = @($N9196PerfCells | Where-Object { [int]$_.index -eq 300 })
    Assert-N9196 ($N9196PerfRightmost.Count -eq 1) '最終内容列そのもののセル（index=300）のプレビュー印が1個ある'
    if ($N9196PerfRightmost.Count -eq 1) {
        Assert-N9196 ([bool]$N9196PerfRightmost[0].overflowRisk -eq $true) `
            '最終内容列そのもののセルは「右へ無限の余白」を得ない（正しくはみ出しと判定される）'
    }

    # --- max_chars（REWORK-1 MAJOR-3/4: below-min／measured／above-maxの3通り） ---
    function Assert-N9196MaxChars {
        param([string]$Label, $ResultEntry, $Oracle, [string]$ExpectedBasis, [string]$NoteMatch)
        $body = $ResultEntry.requestBody
        Assert-N9196 ($null -ne $body) ($Label + ': publication-candidates が呼ばれた')
        if ($null -eq $body) { return }
        Assert-N9196 ([string]$Oracle.basis -eq $ExpectedBasis) ($Label + ': 独立に求めた基準（basis）が期待どおり（' + $ExpectedBasis + '／実測 ' + [string]$Oracle.basis + '）')
        Assert-N9196 ([int]$body.max_chars -eq [int]$Oracle.expectedMaxChars) `
            ($Label + ': max_chars がクランプ後の期待値と一致する（実測 ' + [int]$body.max_chars + ' / 期待 ' + [int]$Oracle.expectedMaxChars + '、生の容量 ' + [int]$Oracle.raw + '）')
        Assert-N9196 ([string]$ResultEntry.note -match $NoteMatch) ($Label + ': 状態行の文言が基準を正直に言う（' + $NoteMatch + '）')
    }
    Assert-N9196MaxChars -Label 'above-max(index8)' -ResultEntry $N9196Result.measuredAbove -Oracle $N9196Result.oracleAbove -ExpectedBasis 'above-max' -NoteMatch '文字目標 99字（上限'
    Assert-N9196MaxChars -Label 'measured(index12)' -ResultEntry $N9196Result.measuredNormal -Oracle $N9196Result.oracleNormal -ExpectedBasis 'measured' -NoteMatch '実測した使える幅から算出'
    Assert-N9196MaxChars -Label 'below-min(index13)' -ResultEntry $N9196Result.measuredBelow -Oracle $N9196Result.oracleBelow -ExpectedBasis 'below-min' -NoteMatch '文字目標 8字（下限'
    if ($null -ne $N9196Result.measuredAbove.requestBody) {
        Assert-N9196 ([int]$N9196Result.measuredAbove.requestBody.max_chars -le 99) 'above-max: 99を超える値を送っていない（クランプせずに送ると CopilotClient.ps1 が文字数の指示を出さない）'
    }
    if ($null -ne $N9196Result.measuredNormal.requestBody) {
        $N9196NormalOldHeuristic = [Math]::Max(20, [Math]::Floor($N9196NormalText.Length * 0.8))
        Assert-N9196 ([int]$N9196Result.measuredNormal.requestBody.max_chars -ne [int]$N9196NormalOldHeuristic) `
            ('measured(index12): 従来の「現訳の長さ×0.8」（' + $N9196NormalOldHeuristic + '）とは異なる値になる（実測由来であることの裏付け）')
    }
    if ($null -ne $N9196Result.measuredBelow.requestBody) {
        Assert-N9196 ([int]$N9196Result.measuredBelow.requestBody.max_chars -eq 8) 'below-min: 20字ではなく8字へクランプされる（20字下限は実測側に掛けない）'
    }

    $N9196FallbackBody = $N9196Result.fallback.requestBody
    Assert-N9196 ($null -ne $N9196FallbackBody) '層が引けない行でも publication-candidates が呼ばれた'
    if ($null -ne $N9196FallbackBody) {
        Assert-N9196 ([int]$N9196FallbackBody.max_chars -eq [int]$N9196Result.fallbackExpected) `
            ('層が引けない行は従来の0.8倍（20字下限つき）に一致する（実測 ' + [int]$N9196FallbackBody.max_chars + ' / 期待 ' + [int]$N9196Result.fallbackExpected + '）')
        Assert-N9196 ([string]$N9196Result.fallback.note -match '実幅を測れない') '状態行に「実幅を測れない」と出す（出所を言う）'
    }
}

# --- 1380x900: 絞り込み・行の印だけの再確認（MINOR-6d） -----------------------
$N9196Result1380 = $null
if (Test-Path -LiteralPath $N9196OutJson1380 -PathType Leaf) { $N9196Result1380 = [IO.File]::ReadAllText($N9196OutJson1380, [Text.Encoding]::UTF8) | ConvertFrom-Json }
if ($null -ne $N9196Result1380) {
    foreach ($e in @($N9196Result1380.errors)) { Write-Host ('  Chromium error (1380x900): ' + [string]$e) -ForegroundColor Red }
    foreach ($c in @($N9196Result1380.console)) { Write-Host ('  Chromium console (1380x900): ' + [string]$c) -ForegroundColor Red }
    if ($N9196Result1380.fatal) { Write-Host ('  Chromium fatal (1380x900): ' + [string]$N9196Result1380.fatal) -ForegroundColor Red }
}
Assert-N9196 ($null -ne $N9196Result1380 -and @($N9196Result1380.errors).Count -eq 0 -and @($N9196Result1380.console).Count -eq 0 -and -not $N9196Result1380.fatal) '1380x900でも画面にエラーが出ていない'
if ($null -ne $N9196Result1380) {
    $N9196ExpectedRows1380 = @(1, 2, 3, 4, 5, 7, 10, 12, 13)
    Assert-N9196 ([bool]$N9196Result1380.fitFilterBefore.hidden -eq $false) '1380x900でも絞り込みボタンが自動で現れる'
    Assert-N9196 ([string]$N9196Result1380.fitFilterBefore.count -eq '9') ('1380x900でも件数は9（実測 ' + [string]$N9196Result1380.fitFilterBefore.count + '）')
    $N9196FilteredRows1380 = @($N9196Result1380.fitFilterAfter.rows | Sort-Object)
    Assert-N9196 (-not (Compare-Object $N9196FilteredRows1380 $N9196ExpectedRows1380)) ('1380x900でも絞り込むと該当行だけになる（実測 ' + ($N9196FilteredRows1380 -join ',') + '）')
    $N9196BadgeRows1380 = @(@($N9196Result1380.fitBadges) | ForEach-Object { [int]$_.row } | Sort-Object)
    Assert-N9196 (-not (Compare-Object $N9196BadgeRows1380 $N9196ExpectedRows1380)) ('1380x900でも行の印（バッジ）が付く行は同じ集合になる（実測 ' + ($N9196BadgeRows1380 -join ',') + '）')
}

try { Remove-Item -LiteralPath $N9196Work -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ''
if ($script:N9196Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9196FitVisibility'
    exit 0
}
Write-Host ("FAIL " + $script:N9196Failures.Count + ' assertion(s)')
foreach ($f in @($script:N9196Failures)) { Write-Host ('  - ' + $f) }
exit 1
