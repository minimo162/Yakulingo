<#
.SYNOPSIS
  V91.61: 用語集に無い短いラベルの警告が、実際に立ち・実際に止めず・実際に画面へ届くこと。

.DESCRIPTION
  決定 _docs/決定_用語集は用語の一貫性ではなくレイアウトの保証.md §1 は、
  cell_exact の完全一致置換が「用語の一貫性」ではなく「列からはみ出さないこと」の
  保証として使われていると述べ、その穴は**新しいラベル**であり
  「しかもそれが見えない」と書いている。§4 はこの回帰の場所を
  app/tools/Test-YakuV9161LabelCoverage.ps1 と指している。

  判定そのもの（Test-YakuFileLabelLike、src/CatBatch.ps1）は 2026-08-05 から
  在ったが、**呼び出し元が1件も無かった**。定義があるだけで動いていない検出は、
  無いのと同じである。ここでは字面ではなく振る舞いで測る。

  見るのは5つ。

   (a) ラベル状の原文（営業利益 / 研究開発費）が cell_exact 用語ベースに
       登録されておらず、Kind='cell' の行であるとき、Severity='warning' の
       finding（label-not-in-glossary）が**実際に立つ**
   (b) 立たない場面で立たない。述語で終わる文・25文字以上・Kind='text'・
       EN→JA・**登録済みのラベル**。境目（24文字/25文字）は両向きで見る
   (c) この警告が Get-YakuCatOutputEligibility の Reasons に入らず、
       書き出しを止めない。**同じ作業で警告が立っていること**も同時に見る。
       立っていない作業で「止まらない」を見ても、それは着手前から真である
   (d) 画面へ渡す JSON に届く。未確定の行では qc_preview、確定した行では
       qc_findings。行へ結果を書くのは確定時だけなので、道は2つある
   (e) 確定できる。警告が確定を止めるなら、それは警告ではなく blocker である

  **画面の見た目**（警告の色、点検一覧の群と件数）は、ここでは測らない。
  それは実機の Chromium で押して測るもので、
  tools/Test-YakuV9176CatScreenWiring.ps1 の (n) が受け持つ。
  src と cat.js の分類の一致は tools/Test-YakuV9171CatQcLabelCoverage.ps1 の
  CASE 5 が見る。ここで字面を照合すると、3つの門が同じ弱い測り方を重ねるだけになる。

  題材の日本語は、使う前に**長さと符号位置を印字して確かめる**。符号化が壊れた
  ファイルで関数を呼ぶと、返ってきた値を根拠に結論を出してしまう（2026-08-15）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161LabelCoverage.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0

function Assert-YakuLabelGate {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:fail++ }
}

function Get-YakuLabelCodePoints {
    <# 題材が壊れていないことを、目でなく数で確かめるための印字用。 #>
    param([AllowNull()][string]$Text)
    return (@(([string]$Text).ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
}

# 読み込み順序は SrcModules.ps1 が唯一の出典。写すと写し間違いが静かに効く。
# **Get-Command で守らない。** CatBatch.ps1（Test-YakuFileLabelLike の在処）が
# 読まれていなければ、この試験は例外で赤くなるべきである。守ると、実行時に
# 検出が丸ごと消えていても緑になる。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-label-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

try {
    $settings = Read-YakuSettings -Root $root

    # ---------------------------------------------------------------- 題材
    Write-Host '(0) 題材の日本語が壊れていないことを、長さと符号位置で確かめる' -ForegroundColor Cyan
    $labelA   = '営業利益'
    $labelB   = '研究開発費'
    $sentence = '当社は電動化を進めます。'
    # 24文字ちょうど（拾う）と 25文字（拾わない）。境目を両向きで見るための対。
    $label24  = '営業利益研究開発費販売費及び一般管理費売上総利益'
    $label25  = $label24 + '率'
    $english  = 'Operating profit'

    Write-Host ('     labelA   = ' + $labelA + ' / ' + $labelA.Length + '字 / ' + (Get-YakuLabelCodePoints -Text $labelA))
    Write-Host ('     labelB   = ' + $labelB + ' / ' + $labelB.Length + '字')
    Write-Host ('     sentence = ' + $sentence + ' / ' + $sentence.Length + '字')
    Write-Host ('     label24  = ' + $label24 + ' / ' + $label24.Length + '字')
    Write-Host ('     label25  = ' + $label25 + ' / ' + $label25.Length + '字')

    Assert-YakuLabelGate ($labelA.Length -eq 4 -and [int][char]$labelA[0] -eq 0x55B6 -and [int][char]$labelA[3] -eq 0x76CA) `
        ('題材 labelA が壊れていない（4字・U+55B6…U+76CA）: ' + (Get-YakuLabelCodePoints -Text $labelA))
    Assert-YakuLabelGate ($labelB.Length -eq 5 -and [int][char]$labelB[0] -eq 0x7814) `
        ('題材 labelB が壊れていない（5字・U+7814 で始まる）')
    # 「を」（U+3092）が生きていることが要点。ここが壊れると、格助詞の枝を
    # 通らないまま「文では立たない」を見たことになる。
    Assert-YakuLabelGate ($sentence.Length -eq 12 -and $sentence.Contains([string][char]0x3092) -and [int][char]$sentence[11] -eq 0x3002) `
        ('題材 sentence が壊れていない（12字・「を」U+3092 と句点 U+3002 を持つ）')
    Assert-YakuLabelGate ($label24.Length -eq 24) ('題材 label24 はちょうど24字（実際 ' + $label24.Length + '）')
    Assert-YakuLabelGate ($label25.Length -eq 25) ('題材 label25 はちょうど25字（実際 ' + $label25.Length + '）')

    # ------------------------------------------------------- 補助（作業を作る）
    function New-YakuLabelProject {
        <# 貼り付け本文から作り、指定の行だけ Kind='cell' にする。
           Kind は実装が読む唯一の鍵なので、ここを実際に切り替えて枝へ入れる。 #>
        param([string[]]$Sources, [string[]]$Targets, [int[]]$CellIndexes, [string]$Direction = 'to_en')
        $p = New-YakuCatTextProject -Root $root -Text ($Sources -join "`n") -Settings $settings -Direction $Direction
        for ($i = 0; $i -lt $Targets.Count; $i++) { $null = Set-YakuCatSegmentTranslation -Project $p -Index $i -Text $Targets[$i] }
        $segs = @($p.Segments)
        foreach ($index in @($CellIndexes)) { if ($index -ge 0 -and $index -lt $segs.Count) { $segs[$index].Kind = 'cell' } }
        return $p
    }
    function Get-YakuLabelVerdict {
        param($Project, [int]$Index)
        $segs = @($Project.Segments)
        return (Invoke-YakuCatSegmentValidation -Project $Project -Segment $segs[$Index])
    }
    function Get-YakuLabelCodes {
        param($Verdict)
        return @(@($Verdict.Findings) | ForEach-Object { [string]$_.Code })
    }
    $labelCode = 'label-not-in-glossary'

    # ------------------------------------------------------------------ (a)
    Write-Host '(a) ラベル状の原文で、警告が実際に立つ' -ForegroundColor Cyan
    $projectA = New-YakuLabelProject -Sources @($labelA, $labelB) -Targets @('Operating profit', 'R&D expenses') -CellIndexes @(0, 1)
    $segsA = @($projectA.Segments)
    Assert-YakuLabelGate ($segsA.Count -eq 2) ('題材は2行に切り分けられる（実際 ' + $segsA.Count + '）')
    Assert-YakuLabelGate ([string]$segsA[0].Text -eq $labelA -and [string]$segsA[1].Text -eq $labelB) '行の原文が題材どおり（切り分けが混ざっていない）'
    Assert-YakuLabelGate ([string]$segsA[0].Kind -eq 'cell') 'Kind を cell にできた（この枝へ入る題材である）'

    $verdictA0 = Get-YakuLabelVerdict -Project $projectA -Index 0
    $codesA0 = Get-YakuLabelCodes -Verdict $verdictA0
    Assert-YakuLabelGate ($codesA0 -contains $labelCode) ('labelA で ' + $labelCode + ' が立つ（実際: ' + ($codesA0 -join ',') + '）')
    $verdictA1 = Get-YakuLabelVerdict -Project $projectA -Index 1
    Assert-YakuLabelGate ((Get-YakuLabelCodes -Verdict $verdictA1) -contains $labelCode) 'labelB でも立つ（1件だけの偶然ではない）'

    $warningFindings = @(@($verdictA0.Findings) | Where-Object { [string]$_.Code -eq $labelCode })
    Assert-YakuLabelGate ($warningFindings.Count -eq 1) ('同じ行で1件だけ積む（実際 ' + $warningFindings.Count + ' 件）')
    Assert-YakuLabelGate ((@($warningFindings | ForEach-Object { [string]$_.Severity }) -join ',') -eq 'warning') `
        ('Severity は warning（実際 ' + (@($warningFindings | ForEach-Object { [string]$_.Severity }) -join ',') + '）')
    # 種別を上げて error にした改変は、ここで落ちる。Passed は Severity でしか決まらない。
    Assert-YakuLabelGate ([bool]$verdictA0.Passed -and [string]$verdictA0.Status -eq 'passed') `
        ('警告だけの行は点検に通る（Status=' + [string]$verdictA0.Status + '）')
    Assert-YakuLabelGate (@(@($segsA[0].QcFindings) | ForEach-Object { [string]$_.Code }) -contains $labelCode) `
        '行の QcFindings にも残る（確定した行が画面へ持って行ける形になっている）'

    # ------------------------------------------------------------------ (b)
    Write-Host '(b) 立たない場面で立たない' -ForegroundColor Cyan
    # 述語で終わる文。同じ作業の中にラベルの行も置き、**その行では立つ**ことを
    # 同時に見る。立たないことだけを見ると、検出を丸ごと殺した改変でも緑になる。
    $projectB = New-YakuLabelProject -Sources @($sentence, $labelA) -Targets @('We will advance electrification.', 'Operating profit') -CellIndexes @(0, 1)
    $segsB = @($projectB.Segments)
    Assert-YakuLabelGate ($segsB.Count -eq 2 -and [string]$segsB[0].Text -eq $sentence) '文とラベルが1行ずつ並んでいる'
    $codesB0 = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectB -Index 0)
    $codesB1 = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectB -Index 1)
    Assert-YakuLabelGate (-not ($codesB0 -contains $labelCode)) ('述語で終わる文では立たない（実際: ' + ($codesB0 -join ',') + '）')
    Assert-YakuLabelGate ($codesB1 -contains $labelCode) '同じ作業のラベルの行では立つ（検出そのものは生きている）'

    # 25文字は拾わない・24文字は拾う。片側だけだと、上限を 0 にした改変でも緑になる。
    $projectL = New-YakuLabelProject -Sources @($label24, $label25) -Targets @('Ordinary items', 'Ordinary ratio') -CellIndexes @(0, 1)
    $segsL = @($projectL.Segments)
    Assert-YakuLabelGate ($segsL.Count -eq 2 -and [string]$segsL[0].Text -eq $label24 -and [string]$segsL[1].Text -eq $label25) '長さの題材が2行に並んでいる'
    $codesL24 = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectL -Index 0)
    $codesL25 = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectL -Index 1)
    Assert-YakuLabelGate ($codesL24 -contains $labelCode) ('24文字では立つ（実際: ' + ($codesL24 -join ',') + '）')
    Assert-YakuLabelGate (-not ($codesL25 -contains $labelCode)) ('25文字では立たない（実際: ' + ($codesL25 -join ',') + '）')

    # Kind='text' では立たない。はみ出しが問題になるのは列に収める場所だけである。
    $projectT = New-YakuLabelProject -Sources @($labelA) -Targets @('Operating profit') -CellIndexes @()
    Assert-YakuLabelGate ([string]@($projectT.Segments)[0].Kind -eq 'text') '題材の Kind は text のまま'
    $codesT = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectT -Index 0)
    Assert-YakuLabelGate (-not ($codesT -contains $labelCode)) ('Kind=text では立たない（実際: ' + ($codesT -join ',') + '）')

    # EN→JA では立たない（決定 §4-4）。英語だけの原文は Test-YakuFileLabelLike が落とす。
    $projectE = New-YakuLabelProject -Sources @($english) -Targets @('営業利益') -CellIndexes @(0) -Direction 'to_jp'
    $codesE = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectE -Index 0)
    Assert-YakuLabelGate (-not ($codesE -contains $labelCode)) ('EN→JA では立たない（実際: ' + ($codesE -join ',') + '）')

    # 登録済みのラベルでは立たない。**同じ作業・同じ行で、登録の前後を見る。**
    # 別の作業で見ると「登録の有無」ではなく「作業の違い」を見たことになる。
    $projectG = New-YakuLabelProject -Sources @($labelA) -Targets @('Operating profit') -CellIndexes @(0)
    $segsG = @($projectG.Segments)
    $codesGBefore = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectG -Index 0)
    Assert-YakuLabelGate ($codesGBefore -contains $labelCode) '登録する前は立つ'
    $null = Add-YakuTerminologyEntry -Scope project -ProjectId ([string]$projectG.Id) -Kind cell_exact -Enforcement required `
        -JapanesePreferred $labelA -EnglishPreferred 'Operating profit' -Origin 'label-coverage-test' `
        -OriginProjectId ([string]$projectG.Id) -OriginFileName ([string]$projectG.FileName) `
        -OriginSegmentId ([string]$segsG[0].SegmentId) -OriginLocation ([string]$segsG[0].Location) -OriginRevision ([int]$projectG.Revision)
    $cellExactHit = Find-YakuCellExactTerminologyMatch -Text $labelA -Direction 'to_en' `
        -Entries @(Get-YakuCatTerminologyEntries -Project $projectG) -ProjectId ([string]$projectG.Id)
    Assert-YakuLabelGate ($null -ne $cellExactHit) '用語ベースへ cell_exact として実際に載った（載っていなければ、次の表明は空回りする）'
    $codesGAfter = Get-YakuLabelCodes -Verdict (Get-YakuLabelVerdict -Project $projectG -Index 0)
    Assert-YakuLabelGate (-not ($codesGAfter -contains $labelCode)) ('登録した後は立たない（実際: ' + ($codesGAfter -join ',') + '）')

    # ------------------------------------------------------------------ (c)(d)(e)
    Write-Host '(c)(d)(e) 止めない・画面へ届く・確定できる' -ForegroundColor Cyan
    $projectC = New-YakuLabelProject -Sources @($labelA, $labelB) -Targets @('Operating profit', 'R&D expenses') -CellIndexes @(0, 1)
    $segsC = @($projectC.Segments)
    $eligibility = Get-YakuCatOutputEligibility -Project $projectC
    $reasons = @($eligibility.Reasons)
    $failureCodes = @(@($eligibility.QcFailures) | ForEach-Object { [string]$_.Code })
    # 先に「この作業で警告が立っている」ことを確かめる。立っていない作業で
    # 「止まらない」を見ても、それは着手前から真である。
    $previewCodes = @(@($eligibility.QcRows) | ForEach-Object { @($_.Codes) } | ForEach-Object { [string]$_ })
    Assert-YakuLabelGate ($previewCodes -contains $labelCode) ('未確定の行の写しに警告が載る（実際: ' + ($previewCodes -join ',') + '）')
    Assert-YakuLabelGate ($reasons.Count -eq 0) ('止める理由は1つも増えない（実際: ' + ($reasons -join ',') + '）')
    Assert-YakuLabelGate (-not ($failureCodes -contains $labelCode)) ('QcFailures（押せない理由の内訳）に入らない（実際: ' + ($failureCodes -join ',') + '）')
    Assert-YakuLabelGate ([bool]$eligibility.TranslationListEligible) '訳文一覧は出せる（書き出しを止めていない）'
    $preflight = Get-YakuCatOutputPreflight -Project $projectC
    Assert-YakuLabelGate (@($preflight.Blockers).Count -eq 0) ('出力前の確認に blocker が1件も無い（実際 ' + @($preflight.Blockers).Count + ' 件）')

    # 画面へ渡す JSON。未確定の行は qc_preview から届く。
    $view = (ConvertTo-YakuCatProjectJson -Project $projectC) | ConvertFrom-Json
    $viewRows = @($view.segments)
    Assert-YakuLabelGate ($viewRows.Count -eq 2) ('画面へ渡す行は2行（実際 ' + $viewRows.Count + '）')
    $previewOnScreen = @(@($viewRows[0].qc_preview) | ForEach-Object { [string]$_.code })
    Assert-YakuLabelGate ($previewOnScreen -contains $labelCode) ('未確定の行の qc_preview に届く（実際: ' + ($previewOnScreen -join ',') + '）')
    Assert-YakuLabelGate (-not [bool]$view.export_blocked) '画面の取り出しボタンは押せる状態のまま'

    # 確定できること。警告が確定を止めるなら、それは警告ではない。
    $confirmFailed = ''
    try { $null = Set-YakuCatSegmentConfirmed -Project $projectC -Index 0 -Confirmed $true } catch { $confirmFailed = [string]$_.Exception.Message }
    Assert-YakuLabelGate ([string]::IsNullOrEmpty($confirmFailed)) ('警告のある行を確定できる（例外: ' + $confirmFailed + '）')
    $segsC = @($projectC.Segments)
    Assert-YakuLabelGate ([bool]$segsC[0].Confirmed -and [string]$segsC[0].State -eq 'reviewed') ('確定後の状態は reviewed（実際 ' + [string]$segsC[0].State + '）')
    $confirmedCodes = @(@($segsC[0].QcFindings) | ForEach-Object { [string]$_.Code })
    Assert-YakuLabelGate ($confirmedCodes -contains $labelCode) ('確定した行にも警告が残る（実際: ' + ($confirmedCodes -join ',') + '）')

    $viewAfter = (ConvertTo-YakuCatProjectJson -Project $projectC) | ConvertFrom-Json
    $rowsAfter = @($viewAfter.segments)
    $findingsOnScreen = @(@($rowsAfter[0].qc_findings) | ForEach-Object { [string]$_.Code })
    Assert-YakuLabelGate ($findingsOnScreen -contains $labelCode) ('確定した行は qc_findings で画面へ届く（実際: ' + ($findingsOnScreen -join ',') + '）')
    $eligibilityAfter = Get-YakuCatOutputEligibility -Project $projectC
    Assert-YakuLabelGate (@($eligibilityAfter.Reasons).Count -eq 0) ('確定した後も止める理由は無い（実際: ' + (@($eligibilityAfter.Reasons) -join ',') + '）')

    foreach ($done in @($projectA, $projectB, $projectL, $projectT, $projectE, $projectG, $projectC)) {
        try { Remove-YakuCatProject -Id ([string]$done.Id) } catch {}
    }
} finally {
    if ([string]::IsNullOrWhiteSpace($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host ("V91.61 label coverage test failed. checks=$script:checks failures=$script:fail") -ForegroundColor Red
    exit 1
}
Write-Host ("V91.61 label coverage regression passed. checks=$script:checks") -ForegroundColor Green
exit 0
