<#
.SYNOPSIS
  V91.61: 出力書体まわりの4件（向き・住所のまとめ・無音・実在確認）を確かめる。

.DESCRIPTION
  2026-08-16 に Excel COM で実測したこと（再検証しない前提の事実）。

    Q1 Font.Name を当てても run は潰れない
    Q3 存在しない書体名でも Excel は例外を投げず、その名前を保存する
       （threw=False storedName=NoSuchFontZZZ）
    Q4 union 文字列の壁は 230〜350文字の間。MaxLength 200 は妥当
    Q5 連続範囲は1回で当たる

  ここで見るのは4つ。

    1. 向き   … to_jp は和書体、to_en は設定値。**両方向**を実機の Font.Name で測る
    2. まとめ … 連続するセルが1つの範囲住所になる。**離れているものは繋がない**
    3. 無音   … 退避した塊・失敗した範囲が数えられ、全滅したときだけ警告が出る
    4. 実在   … 綴りの違う書体名で警告が出て、正しい名前では出ない

  **Excel が要る表明と、要らない表明を分ける。** Excel が無ければ実機の表明は
  未測定（exit 3）にする。赤へ畳むと、道具の不在が対象の欠陥に化ける。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9179OutputFont.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:excelMeasured = $false

# 読み込み順序は SrcModules.ps1 が唯一の出典。写すと写し間違いが静かに効く。
# 全部読むのは、向きが**本番の入口から書込まで**届いているかを押すのに
# CAT の書き出し（CatProject.ps1）まで要るためである。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($moduleName in @($script:YakuSrcModuleFiles)) { . (Join-Path (Join-Path $root 'src') $moduleName) }

function Chk {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:fail++ }
}

function Get-YakuFontCodePoints {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ((([string]$Text).ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ')
}

function Get-YakuWarningCategories {
    # @($list) は List[object] に限って ArgumentException で落ちる（CLAUDE.md）。
    # 警告入れは List[object] なので、ここで @() を使ってはならない。
    param([AllowNull()]$Warnings)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Warnings) { return [string[]]@() }
    foreach ($w in $Warnings) {
        if ($null -eq $w) { continue }
        try { $names.Add([string]$w.Category) | Out-Null } catch {}
    }
    return [string[]]@($names.ToArray())
}

# 実機の測り方。セルの Font.Name は、run が混在していると DBNull を返す。
function Get-YakuCellFontName {
    param([Parameter(Mandatory=$true)]$Worksheet,[int]$Row,[int]$Col)
    $cell = $null
    try {
        $cell = $Worksheet.Cells.Item($Row,$Col)
        $value = $cell.Font.Name
        if ($null -eq $value) { return '<null>' }
        if ($value -is [System.DBNull]) { return '<mixed>' }
        return [string]$value
    } catch { return '<error>' } finally { Release-YakuComObject $cell }
}

function Get-YakuXlsxAppliedFontName {
    <#
      .SYNOPSIS
        出来上がった xlsx に**実際に書かれた**書体名を、そのセルの style から読む。

      .DESCRIPTION
        **実機の Font.Name では「Arial を当ててしまった」を名指しできない。**
        実測（2026-08-16 / Excel COM）: 日本語のセル（四半期報告）へ
        `Font.Name = Arial` を当てると、Excel は Latin 側を Arial、東アジア側を
        游ゴシック の run に割る。そのため

          - セルの `Font.Name`          … DBNull（この試験の `<mixed>`）
          - 1文字ずつの `Font.Name`     … 游ゴシック（Arial ではない）

        となり、`-ne 'Arial'` は**名指しした欠陥では決して赤にならない**。
        当てた名前そのものは styles.xml に残る。同じ実測で、Arial を当てた側は
        `rFont=Arial`（0041 0072 0069 0061 006C）、和書体を当てた側は
        `rFont=MS Pゴシック`（004D 0053 0020 0050 30B4 30B7 30C3 30AF）だった。
        だからここは Excel を通さず、書かれた XML を読む。

        読めない場合は `<...>` で囲んだ理由を返す。**空文字を返さない。**
        空を返すと「和書体ではない」も「読めなかった」も同じ見た目になる。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$SheetName,
        [Parameter(Mandatory=$true)][string]$Address
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<no-file>' }
    $zip = Open-YakuXlsxArchiveForRead -Path $Path
    if ($null -eq $zip) { return '<unreadable>' }
    try {
        $partName = ''
        foreach ($spec in @(Get-YakuXlsxSheetParts -Archive $zip)) {
            if ([string]$spec.Name -eq [string]$SheetName) { $partName = [string]$spec.PartName }
        }
        if ([string]::IsNullOrEmpty($partName)) { return '<no-sheet>' }
        $sheetXml = Get-YakuXlsxPartText -Archive $zip -Name $partName
        if ([string]::IsNullOrEmpty($sheetXml)) { return '<no-sheet-xml>' }
        # 自己終端の形を**先に**置く（`<c r="A1" s="1"/>` を後回しにすると
        # `.*?</c>` が次のセルの中身を飲む）。
        $escaped = [regex]::Escape([string]$Address)
        $cell = [regex]::Match($sheetXml, '(?s)<c\b[^>]*\br="' + $escaped + '"[^>]*/>|<c\b[^>]*\br="' + $escaped + '"[^>]*>.*?</c>')
        if (-not $cell.Success) { return '<no-cell>' }
        $styleId = 0
        $styleMatch = [regex]::Match([string]$cell.Value, '\bs="(\d+)"')
        if ($styleMatch.Success) { $styleId = [int]$styleMatch.Groups[1].Value }
        $map = Get-YakuXlsxStyleFontMap -Archive $zip
        $fontId = 0
        if ($map.FontIdByStyle.ContainsKey($styleId)) { $fontId = [int]$map.FontIdByStyle[$styleId] }
        if ($fontId -lt 0 -or $fontId -ge $map.Fonts.Length) { return '<no-font>' }
        $properties = $map.Fonts[$fontId]
        if ($null -eq $properties -or -not $properties.ContainsKey('rFont')) { return '<no-name>' }
        return [string]$properties['rFont']
    } catch { return '<error>' } finally { if ($null -ne $zip) { try { $zip.Dispose() } catch {} } }
}

# ===========================================================================
# 0. 符号化の確認。**使う前に印字して確かめる**
# ===========================================================================
# 和書体の既定は利用者が決めた「MS Pゴシック」（半角 MS・半角 P・カタカナ）。
# 符号位置から組み立てたものと設定表の既定が一致しなければ、以降の比較は
# 全部あてにならない。ここで先に落とす。
$expectedJpFont = 'MS P' + ([char]0x30B4).ToString() + ([char]0x30B7).ToString() + ([char]0x30C3).ToString() + ([char]0x30AF).ToString()
Write-Host ('和書体の符号位置: ' + (Get-YakuFontCodePoints $expectedJpFont)) -ForegroundColor DarkGray

$schema = Get-YakuSettingsSchema
Chk ($schema.Contains('output_font_name_jp')) '和書体用の設定キーがある'
$schemaJpDefault = ''
if ($schema.Contains('output_font_name_jp')) { $schemaJpDefault = [string]$schema['output_font_name_jp'].Default }
Chk ($schemaJpDefault -ceq $expectedJpFont) ('和書体の既定は MS Pゴシック: ' + (Get-YakuFontCodePoints $schemaJpDefault))
Chk ([string]$schema['output_font_name'].Default -eq 'Arial') '和→英用の既定は Arial のまま（既存設定の意味を変えない）'

# ===========================================================================
# 1. 向き（設定の引き方）。Excel は要らない
# ===========================================================================
Write-Host '出力書体を、訳す向きで引き分ける' -ForegroundColor Cyan

$bothSettings = [pscustomobject]@{ output_font_name = 'Arial'; output_font_name_jp = $expectedJpFont }
Chk ((Get-YakuOutputFontName -Settings $bothSettings -Direction 'to_jp') -ceq $expectedJpFont) '英→和は和書体を引く'
Chk ((Get-YakuOutputFontName -Settings $bothSettings -Direction 'to_en') -eq 'Arial') '和→英は output_font_name を引く'

# **別のキーであることを、値を入れ替えて確かめる。** 同じキーを見ている実装は
# ここで必ず落ちる（片方向だけの表明は空回りする）。
$swapped = [pscustomobject]@{ output_font_name = 'Meiryo'; output_font_name_jp = 'Consolas' }
Chk ((Get-YakuOutputFontName -Settings $swapped -Direction 'to_en') -eq 'Meiryo') '和→英は和書体の設定に引きずられない'
Chk ((Get-YakuOutputFontName -Settings $swapped -Direction 'to_jp') -eq 'Consolas') '英→和は和→英の設定に引きずられない'

# 古い設定ファイル（和書体キーが無い）でも、英→和で Arial にはしない。
$legacy = [pscustomobject]@{ output_font_name = 'Arial' }
Chk ((Get-YakuOutputFontName -Settings $legacy -Direction 'to_jp') -ceq $expectedJpFont) '和書体キーが無い設定でも、英→和は Arial にならない'
Chk ((Get-YakuOutputFontName -Settings $legacy) -eq 'Arial') '向きを渡さなければ従来どおり（to_en）'
# 空欄は「変更しない」。向きを分けても、その意味は変えない。
Chk ([string]::IsNullOrEmpty((Get-YakuOutputFontName -Settings ([pscustomobject]@{ output_font_name_jp = '' }) -Direction 'to_jp'))) '和書体が空欄なら書体を変更しない'

# 向きを引き回す配線。**既定値を置いていない**ことを、束縛の規約そのもので見る。
# 既定を置くと、渡し忘れが「英→和なのに Arial」という無音の欠陥へ戻る。
# 実際に渡っているかは、CAT の書き出しを通す Test-YakuV9161CatProject が押す
# （あそこが Export-YakuCatProject を実際に走らせている）。
$directionParam = (Get-Command Write-YakuFileTranslations).Parameters['Direction']
Chk ($null -ne $directionParam) 'ファイル書き出しの入口が向きを受け取る'
$directionMandatory = $false
if ($null -ne $directionParam) {
    foreach ($attr in @($directionParam.Attributes)) {
        if ($attr -is [System.Management.Automation.ParameterAttribute] -and [bool]$attr.Mandatory) { $directionMandatory = $true }
    }
}
Chk $directionMandatory '向きは必須。渡し忘れが既定値で黙って埋まらない'

# ===========================================================================
# 2. 住所のまとめ（純関数）。Excel は要らない
# ===========================================================================
Write-Host '連続する住所だけを1つの範囲へ畳む' -ForegroundColor Cyan

# **中身で見る。件数だけを見ると、別の範囲へ化けても気づけない。**
$thousand = New-Object System.Collections.Generic.List[string]
for ($r = 5; $r -le 1004; $r++) { $thousand.Add('B' + [string]$r) | Out-Null }
$thousandMerged = @(Merge-YakuExcelFontAddressRanges -Addresses ([string[]]@($thousand.ToArray())))
Chk (($thousandMerged -join ',') -eq 'B5:B1004') ('1列1000セルは1つの範囲になる: ' + ($thousandMerged -join ','))

# **対の表明。隙間があれば繋がない。** 間の B7 は対象ではないので、繋いだら
# 書体を当ててはならないセルを塗ることになる。
$gapMerged = @(Merge-YakuExcelFontAddressRanges -Addresses @('B5','B6','B8'))
Chk (($gapMerged -join ',') -eq 'B5:B6,B8') ('間が空いていれば別の範囲のまま: ' + ($gapMerged -join ','))
Chk (-not (($gapMerged -join ',') -match 'B5:B8')) '離れたセルを1つの範囲へ繋がない'
$colGap = @(Merge-YakuExcelFontAddressRanges -Addresses @('B5','D5'))
Chk (($colGap -join ',') -eq 'B5,D5') ('列が飛んでいれば繋がない: ' + ($colGap -join ','))

Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('B5','C5','D5'))) -join ',') -eq 'B5:D5') '横に並んだセルは1本の範囲になる'
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('B5','C5','B6','C6'))) -join ',') -eq 'B5:C6') '縦横に並んだセルは1つの矩形になる'
# **列が2本ある題材。** 縦積みの並べ替えを「行→開始列」のままにすると、
# ここが B5,D5,B6,D6 の4本のまま残る（実装中に一度そうなった）。
$twoColumns = @(Merge-YakuExcelFontAddressRanges -Addresses @('B5','D5','B6','D6'))
Chk (($twoColumns -join ',') -eq 'B5:B6,D5:D6') ('離れた列が2本あっても、列ごとに縦へ積む: ' + ($twoColumns -join ','))
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('AA5','AB5','AD5'))) -join ',') -eq 'AA5:AB5,AD5') '2文字の列名でも隣接だけを畳む'
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('B5','B5','B6'))) -join ',') -eq 'B5:B6') '同じ住所が重なって届いても増えない'
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('B5:C6','B7','C7'))) -join ',') -eq 'B5:C7') '矩形の住所と単セルの住所が混ざっても畳める'
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('C5','B5'))) -join ',') -eq 'B5:C5') '順番が入れ替わっていても畳める'
# 読めない住所は落とさない。欠かすと、そのセルの書体だけが当たらなくなる。
$garbage = @(Merge-YakuExcelFontAddressRanges -Addresses @('not-an-address','B5'))
Chk (($garbage -join ',') -eq 'not-an-address,B5') ('読めない住所は畳まずそのまま残す: ' + ($garbage -join ','))
Chk ((@(Merge-YakuExcelFontAddressRanges -Addresses @())).Count -eq 0) '空を渡せば空が返る'
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('A1:A300000'))) -join ',') -eq 'A1:A300000') '巨大な矩形は行ごとにばらさず、そのまま返す'

# 住所の読み方は、出荷する関数の振る舞いとして押す（読み手だけを別に試さない）。
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('$B$5','$B$6'))) -join ',') -eq 'B5:B6') '$ 付きの住所も読んで畳める'
Chk (((@(Merge-YakuExcelFontAddressRanges -Addresses @('$B$5:$D$7'))) -join ',') -eq 'B5:D7') '$ 付きの矩形住所も読める'
$sheetQualified = @(Merge-YakuExcelFontAddressRanges -Addresses @('Sheet1!A1','B5'))
Chk (($sheetQualified -join ',') -eq 'Sheet1!A1,B5') ('シート名付きの住所は畳まずそのまま渡す: ' + ($sheetQualified -join ','))

# ===========================================================================
# 3. 実在確認（純関数）。Excel を1回も起動しない
# ===========================================================================
Write-Host '存在しない書体名を、書き出しを止めずに知らせる' -ForegroundColor Cyan

$installedKeys = Get-YakuInstalledFontNameKeys
if ($null -eq $installedKeys) {
    Write-Host '  書体一覧が取れないため、実在確認は未測定にする（赤へ畳まない）' -ForegroundColor Yellow
} else {
    Chk ((Test-YakuInstalledFontName -Name 'Arial') -eq 'installed') 'Arial は実在する'
    # **ここが罠。** GDI+ の家族名は英語（MS PGothic）で、日本語名は全角の
    # ＭＳ Ｐゴシック。利用者が書いた半角の MS Pゴシック はどちらとも
    # 文字列一致しない。NFKC で畳まない実装は、既定値そのものを「無い」と言う。
    Chk ((Test-YakuInstalledFontName -Name $expectedJpFont) -eq 'installed') 'アプリ自身の既定（MS Pゴシック）を「無い」と言わない'
    Chk ((Test-YakuInstalledFontName -Name 'Ariel') -eq 'missing') '綴り違いの Ariel は無いと分かる'
    Chk ((Test-YakuInstalledFontName -Name 'NoSuchFontZZZ') -eq 'missing') '存在しない名前は無いと分かる'
    Chk ((Test-YakuInstalledFontName -Name '') -eq 'unknown') '空欄は判定しない（変更しないの意味なので）'

    $missWarnings = New-Object System.Collections.Generic.List[object]
    $missState = Add-YakuOutputFontMissingWarning -Warnings $missWarnings -FontName 'Ariel' -Direction 'to_en'
    Chk ([string]$missState -eq 'missing') '綴り違いは missing として返る'
    Chk ($missWarnings.Count -eq 1) ('警告が1件出る: ' + $missWarnings.Count)
    Chk ((Get-YakuWarningCategories -Warnings $missWarnings) -contains 'output-font-missing') '種別が分かる'
    # **書き出しブロッカーを増やしていない。** ここが真でないと、綴り違いだけで
    # DRAFT が _INCOMPLETE になり、-FailOnIncomplete では例外になる。
    Chk (-not (Test-YakuIncompleteWarnings -Warnings $missWarnings)) '書体が無いだけでは書き出しを止めない'

    # 対の表明。実在する名前では出さない（無条件に警告する実装をここで落とす）。
    $okWarnings = New-Object System.Collections.Generic.List[object]
    $okState = Add-YakuOutputFontMissingWarning -Warnings $okWarnings -FontName 'Arial' -Direction 'to_en'
    Chk ([string]$okState -eq 'installed' -and $okWarnings.Count -eq 0) '実在する名前では警告を出さない'
    $jpWarnings = New-Object System.Collections.Generic.List[object]
    $null = Add-YakuOutputFontMissingWarning -Warnings $jpWarnings -FontName $expectedJpFont -Direction 'to_jp'
    Chk ($jpWarnings.Count -eq 0) '和書体の既定でも警告を出さない'
    $blankWarnings = New-Object System.Collections.Generic.List[object]
    $null = Add-YakuOutputFontMissingWarning -Warnings $blankWarnings -FontName '' -Direction 'to_en'
    Chk ($blankWarnings.Count -eq 0) '空欄（変更しない）では警告を出さない'
}

# ===========================================================================
# 4. 実機（Excel が要る）
# ===========================================================================
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('yaku-font-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $workDir -Force
# CAT の書き出しまで通すので、利用者の保存先へ1つも置かない。
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $workDir 'user-data'
$script:YakuFontTestStore = Join-Path $workDir 'cat-store'
function Get-YakuCatProjectStoreDir { return $script:YakuFontTestStore }
try {

if (-not (Test-YakuExcelAvailable)) {
    Write-Host 'Excel が無いため、実機の表明は未測定にする（赤へ畳まない）' -ForegroundColor Yellow
} else {
    $script:excelMeasured = $true

    $probeFont = 'Times New Roman'
    $keepFont = 'Consolas'
    if ($null -ne $installedKeys) {
        Chk ((Test-YakuInstalledFontName -Name $probeFont) -eq 'installed') '実機で使う測定用の書体が入っている'
        Chk ((Test-YakuInstalledFontName -Name $keepFont) -eq 'installed') '触らない側の書体も入っている'
    }

    # --- 題材 ---------------------------------------------------------------
    # B5〜B8 に文字を置き、B7 だけ別の書体にしておく。B7 は書体を当てる対象では
    # ないので、まとめ方を誤って B5:B8 に広げれば、ここが変わって赤になる。
    $livePath = Join-Path $workDir 'live.xlsx'
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        $wb = $xl.Workbooks.Add()
        $ws = $wb.Worksheets.Item(1); $ws.Name = 'S1'
        foreach ($r in @(5,6,7,8)) { $ws.Cells.Item($r,2).Value2 = ('row' + [string]$r) }
        $ws.Cells.Item(7,2).Font.Name = $keepFont
        $ws.Cells.Item(1,1).Value2 = 'Quarterly report'
        $ws.Cells.Item(1,6).Value2 = 'f5'
        $wb.SaveAs($livePath, 51)
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }

    # --- 住所のまとめ・無音の解消を、1つの Excel で全部測る -----------------
    $probe = $null
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        $wb = $xl.Workbooks.Open((Join-Path $workDir 'live.xlsx'))
        $ws = $wb.Worksheets.Item('S1')

        # (A) 隙間を跨がない
        $beforeB5 = Get-YakuCellFontName -Worksheet $ws -Row 5 -Col 2
        $beforeB7 = Get-YakuCellFontName -Worksheet $ws -Row 7 -Col 2
        $aMetrics = @{}
        $aWarnings = New-Object System.Collections.Generic.List[object]
        Invoke-YakuExcelFontUnionApply -Worksheet $ws -Addresses ([string[]]@('B5','B6','B8')) -FontName $probeFont -Metrics $aMetrics -Warnings $aWarnings -SheetName 'S1'

        # (B) 1列1000セルが union 1回で当たる
        $bAddresses = New-Object System.Collections.Generic.List[string]
        for ($r = 5; $r -le 1004; $r++) { $bAddresses.Add('D' + [string]$r) | Out-Null }
        $bMetrics = @{}
        $bWarnings = New-Object System.Collections.Generic.List[object]
        Invoke-YakuExcelFontUnionApply -Worksheet $ws -Addresses ([string[]]@($bAddresses.ToArray())) -FontName $probeFont -Metrics $bMetrics -Warnings $bWarnings -SheetName 'S1'

        # (C) union が落ちる塊。1住所ずつの退避へ降りる。
        # F1048577 は Excel の行の上限を1つ越えているので Range が例外を投げる。
        $cMetrics = @{}
        $cWarnings = New-Object System.Collections.Generic.List[object]
        Invoke-YakuExcelFontUnionApply -Worksheet $ws -Addresses ([string[]]@('F1','F1048577')) -FontName $probeFont -Metrics $cMetrics -Warnings $cWarnings -SheetName 'S1'

        # (D) 全滅。1か所も当たらない。
        $dMetrics = @{}
        $dWarnings = New-Object System.Collections.Generic.List[object]
        Invoke-YakuExcelFontUnionApply -Worksheet $ws -Addresses ([string[]]@('F1048577')) -FontName $probeFont -Metrics $dMetrics -Warnings $dWarnings -SheetName 'S1'

        # (E) 塊の文字数上限（MaxLength 200）が効いていることを、**効かなくなる
        # 題材**で押す。上限が無ければ union 文字列が壁を越えて全部が退避する。
        # 実測（2026-08-16 / このスクリプトと同じ組み方の使い捨て probe）:
        #   住所28件（joined 251文字）… 通る
        #   住所30件（joined 269文字）… 0x800A03EC
        # 8文字の住所を1行おきに 120 件並べると、
        #   MaxLength 200 → 6塊・退避0・applied 120
        #   MaxLength 400 → 3塊・**3塊とも 0x800A03EC**（＝退避3）
        # 住所を1つしか作らない題材では 400 でも落ちないので、必ず塊を跨がせる。
        $eAddresses = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt 120; $i++) { $eAddresses.Add('BZ' + [string](100001 + ($i * 2))) | Out-Null }
        $eMetrics = @{}
        $eWarnings = New-Object System.Collections.Generic.List[object]
        Invoke-YakuExcelFontUnionApply -Worksheet $ws -Addresses ([string[]]@($eAddresses.ToArray())) -FontName $probeFont -Metrics $eMetrics -Warnings $eWarnings -SheetName 'S1'

        $probe = [pscustomobject]@{
            EFirst = [string](Get-YakuCellFontName -Worksheet $ws -Row 100001 -Col 78)
            EMid   = [string](Get-YakuCellFontName -Worksheet $ws -Row 100121 -Col 78)
            ELast  = [string](Get-YakuCellFontName -Worksheet $ws -Row 100239 -Col 78)
            E = $eMetrics; EWarn = (Get-YakuWarningCategories -Warnings $eWarnings)
            BeforeB5 = [string]$beforeB5
            BeforeB7 = [string]$beforeB7
            AfterB5  = [string](Get-YakuCellFontName -Worksheet $ws -Row 5 -Col 2)
            AfterB6  = [string](Get-YakuCellFontName -Worksheet $ws -Row 6 -Col 2)
            AfterB7  = [string](Get-YakuCellFontName -Worksheet $ws -Row 7 -Col 2)
            AfterB8  = [string](Get-YakuCellFontName -Worksheet $ws -Row 8 -Col 2)
            AfterD5  = [string](Get-YakuCellFontName -Worksheet $ws -Row 5 -Col 4)
            AfterD500 = [string](Get-YakuCellFontName -Worksheet $ws -Row 500 -Col 4)
            AfterD1004 = [string](Get-YakuCellFontName -Worksheet $ws -Row 1004 -Col 4)
            AfterF1  = [string](Get-YakuCellFontName -Worksheet $ws -Row 1 -Col 6)
            A = $aMetrics; AWarn = (Get-YakuWarningCategories -Warnings $aWarnings)
            B = $bMetrics; BWarn = (Get-YakuWarningCategories -Warnings $bWarnings)
            C = $cMetrics; CWarn = (Get-YakuWarningCategories -Warnings $cWarnings)
            D = $dMetrics; DWarn = (Get-YakuWarningCategories -Warnings $dWarnings)
            DWarnings = $dWarnings
        }
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }

    Write-Host '実機のセルで、当たった範囲と当たらなかった範囲を測る' -ForegroundColor Cyan
    # 題材がその枝へ届いているか。当たる前と後で本当に変わっているか先に見る。
    Chk ([string]$probe.BeforeB5 -ne $probeFont) ('測る前の B5 は測定用の書体ではない: ' + [string]$probe.BeforeB5)
    Chk ([string]$probe.BeforeB7 -eq $keepFont) ('B7 は別の書体にしてある: ' + [string]$probe.BeforeB7)
    Chk ([string]$probe.AfterB5 -eq $probeFont -and [string]$probe.AfterB6 -eq $probeFont -and [string]$probe.AfterB8 -eq $probeFont) '対象の B5・B6・B8 に書体が当たる'
    Chk ([string]$probe.AfterB7 -eq $keepFont) ('間の B7 は触られない: ' + [string]$probe.AfterB7)
    Chk ([int]$probe.A['font_input_addresses'] -eq 3 -and [int]$probe.A['font_ranges'] -eq 2) ('3つの住所が2つの範囲になる: ranges=' + [string]$probe.A['font_ranges'])
    Chk ([int]$probe.A['font_union_chunks'] -eq 1 -and [int]$probe.A['font_union_fallback_chunks'] -eq 0) '塊は1つで、退避していない'
    # **当てた「範囲の数」を数える。** 塊ごとに1しか足さない実装はここで落ちる
    # （B5:B6 と B8 の2範囲を1つの塊で当てているので、2 でなければならない）。
    Chk ([int]$probe.A['font_ranges_applied'] -eq 2) ('1つの塊で当てた範囲を、塊の数ではなく範囲の数で数える: applied=' + [string]$probe.A['font_ranges_applied'])

    Chk ([string]$probe.AfterD5 -eq $probeFont -and [string]$probe.AfterD500 -eq $probeFont -and [string]$probe.AfterD1004 -eq $probeFont) '1000セルの端と真ん中に書体が当たっている'
    Chk ([int]$probe.B['font_input_addresses'] -eq 1000 -and [int]$probe.B['font_ranges'] -eq 1) ('1000セルは1つの範囲へ畳まれる: ranges=' + [string]$probe.B['font_ranges'])
    Chk ([int]$probe.B['font_union_chunks'] -eq 1) ('union は1回で済む（畳まなければ十数回になる）: chunks=' + [string]$probe.B['font_union_chunks'])
    Chk (@($probe.BWarn).Count -eq 0) '当たったときは警告を出さない'

    Write-Host '退避したときに、何回退避したかが分かる' -ForegroundColor Cyan
    Chk ([int]$probe.C['font_union_fallback_chunks'] -eq 1) ('union が落ちた塊を数えている: ' + [string]$probe.C['font_union_fallback_chunks'])
    Chk ([int]$probe.C['font_union_fallback_ranges'] -eq 2) ('1住所ずつ当て直した回数も数えている: ' + [string]$probe.C['font_union_fallback_ranges'])
    Chk ([int]$probe.C['font_ranges_applied'] -eq 1 -and [int]$probe.C['font_ranges_failed'] -eq 1) ('当たった数と落ちた数を分けている: applied=' + [string]$probe.C['font_ranges_applied'] + ' failed=' + [string]$probe.C['font_ranges_failed'])
    Chk ([string]$probe.AfterF1 -eq $probeFont) '退避しても、当てられる範囲には当たっている'
    Chk (@($probe.CWarn).Count -eq 0) '一部でも当たったなら警告は出さない'

    Chk ([int]$probe.D['font_ranges_applied'] -eq 0) '全滅したときは、当たった数が0'
    Chk (@($probe.DWarn) -contains 'output-font-apply-failed') '全滅したときだけ警告が出る'
    Chk (-not (Test-YakuIncompleteWarnings -Warnings $probe.DWarnings)) '書体を当てられなくても書き出しは止めない'

    Write-Host '住所を繋げすぎない（union 文字列の壁を越えさせない）' -ForegroundColor Cyan
    # 上限を 400 へ緩めると 3塊になり、3塊とも 0x800A03EC で落ちる（実測）。
    # だからこの2行は、上限を緩めた瞬間に両方赤になる。
    Chk ([int]$probe.E['font_ranges'] -eq 120) ('離れた120件は畳まれず120範囲のまま: ranges=' + [string]$probe.E['font_ranges'])
    Chk ([int]$probe.E['font_union_chunks'] -eq 6) ('120範囲は6つの塊に割れる（上限200文字ぶん）: chunks=' + [string]$probe.E['font_union_chunks'])
    Chk ([int]$probe.E['font_union_fallback_chunks'] -eq 0 -and [int]$probe.E['font_union_fallback_ranges'] -eq 0) ('塊はどれも壁を越えないので、1つも退避しない: fallbackChunks=' + [string]$probe.E['font_union_fallback_chunks'] + ' fallbackRanges=' + [string]$probe.E['font_union_fallback_ranges'])
    Chk ([int]$probe.E['font_ranges_applied'] -eq 120) ('6つの塊で120範囲ぶん当てたと数える: applied=' + [string]$probe.E['font_ranges_applied'])
    # 数だけでは足りない。**端と真ん中の実物**を見る。
    Chk ([string]$probe.EFirst -eq $probeFont -and [string]$probe.EMid -eq $probeFont -and [string]$probe.ELast -eq $probeFont) ('先頭・真ん中・末尾のセルに実際に当たっている: ' + [string]$probe.EFirst + ' / ' + [string]$probe.EMid + ' / ' + [string]$probe.ELast)
    Chk (@($probe.EWarn).Count -eq 0) '全部当たったのだから警告は出ない'

    # --- 向き。本番の入口を通して、実機の Font.Name を読む -------------------
    Write-Host '英→和と和→英の両方を、本番の入口で測る' -ForegroundColor Cyan
    $settings = Read-YakuSettings -Root $root
    $settings | Add-Member -NotePropertyName 'output_font_name' -NotePropertyValue 'Arial' -Force
    $settings | Add-Member -NotePropertyName 'output_font_name_jp' -NotePropertyValue $expectedJpFont -Force

    $blocks = @(
        [pscustomobject]@{ Id='a1'; Text='Quarterly report'; Location='S1, A1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=1; Col=1; A1='A1'; Merged=$false } }
    )
    $jpPath = Join-Path $workDir 'to-jp.xlsx'
    $enPath = Join-Path $workDir 'to-en.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $jpPath -Force
    Copy-Item -LiteralPath $livePath -Destination $enPath -Force

    $jpWriteWarnings = New-Object System.Collections.Generic.List[object]
    $null = Write-YakuExcelTranslations -OutputPath $jpPath -Blocks $blocks -TranslationByBlockId @{ 'a1' = '四半期報告' } `
        -Warnings $jpWriteWarnings -Settings $settings -SourcePath $livePath -Direction 'to_jp'
    $enWriteWarnings = New-Object System.Collections.Generic.List[object]
    $null = Write-YakuExcelTranslations -OutputPath $enPath -Blocks $blocks -TranslationByBlockId @{ 'a1' = 'Shihanki hokoku' } `
        -Warnings $enWriteWarnings -Settings $settings -SourcePath $livePath -Direction 'to_en'

    # 綴り違いでも書き出しは止まらないことを、同じ入口で測る。
    $badPath = Join-Path $workDir 'bad-font.xlsx'
    Copy-Item -LiteralPath $livePath -Destination $badPath -Force
    $badSettings = Read-YakuSettings -Root $root
    $badSettings | Add-Member -NotePropertyName 'output_font_name' -NotePropertyValue 'Ariel' -Force
    $badWarnings = New-Object System.Collections.Generic.List[object]
    $null = Write-YakuExcelTranslations -OutputPath $badPath -Blocks $blocks -TranslationByBlockId @{ 'a1' = 'Typo font' } `
        -Warnings $badWarnings -Settings $badSettings -SourcePath $livePath -Direction 'to_en'

    $read = $null
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        $jpBook = $xl.Workbooks.Open($jpPath, 0, $true)
        $jpSheet = $jpBook.Worksheets.Item('S1')
        $jpFont = Get-YakuCellFontName -Worksheet $jpSheet -Row 1 -Col 1
        $jpValue = [string]$jpSheet.Cells.Item(1,1).Value2
        $jpBook.Close($false)
        $enBook = $xl.Workbooks.Open($enPath, 0, $true)
        $enSheet = $enBook.Worksheets.Item('S1')
        $enFont = Get-YakuCellFontName -Worksheet $enSheet -Row 1 -Col 1
        $enValue = [string]$enSheet.Cells.Item(1,1).Value2
        $enBook.Close($false)
        $badBook = $xl.Workbooks.Open($badPath, 0, $true)
        $badSheet = $badBook.Worksheets.Item('S1')
        $badFont = Get-YakuCellFontName -Worksheet $badSheet -Row 1 -Col 1
        $badValue = [string]$badSheet.Cells.Item(1,1).Value2
        $badBook.Close($false)
        $read = [pscustomobject]@{ JpFont=[string]$jpFont; JpValue=[string]$jpValue; EnFont=[string]$enFont; EnValue=[string]$enValue; BadFont=[string]$badFont; BadValue=[string]$badValue }
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }

    Chk ([string]$read.JpValue -eq '四半期報告') '英→和で訳文が書けている'
    Chk ([string]$read.JpFont -ceq $expectedJpFont) ('英→和の訳文セルは和書体になる: ' + (Get-YakuFontCodePoints ([string]$read.JpFont)))
    # **`$read.JpFont -ne 'Arial'` は空回りする。** 日本語のセルへ Arial を当てると
    # Excel は Font.Name に DBNull を返す（この試験の `<mixed>`）ので、名指しした
    # 欠陥では決して 'Arial' にならない。当てた名前は出来上がりの styles.xml に
    # 残るので、そちらで測る（Get-YakuXlsxAppliedFontName に実測を書いた）。
    $jpApplied = Get-YakuXlsxAppliedFontName -Path $jpPath -SheetName 'S1' -Address 'A1'
    $enApplied = Get-YakuXlsxAppliedFontName -Path $enPath -SheetName 'S1' -Address 'A1'
    Chk ($jpApplied -ceq $expectedJpFont) ('英→和で書かれた書体名は和書体: ' + (Get-YakuFontCodePoints $jpApplied))
    Chk ($jpApplied -ne 'Arial') '英→和で Arial を当てない（これが直した欠陥そのもの）'
    # **対の表明。片方向だけなら空回りする。**
    Chk ([string]$read.EnValue -eq 'Shihanki hokoku') '和→英でも訳文が書けている'
    Chk ([string]$read.EnFont -eq 'Arial') ('和→英の訳文セルは設定どおり Arial のまま: ' + [string]$read.EnFont)
    Chk ($enApplied -eq 'Arial') ('和→英で書かれた書体名も Arial（測り方そのものが片側だけ当たっていないか見る）: ' + $enApplied)

    Chk ((Get-YakuWarningCategories -Warnings $badWarnings) -contains 'output-font-missing') '綴り違いの書体名で警告が出る'
    Chk ([string]$read.BadValue -eq 'Typo font') '綴り違いでも訳文は書けている（書き出しを止めない）'
    Chk (-not (Test-YakuIncompleteWarnings -Warnings $badWarnings)) '綴り違いは書き出しの中断条件にならない'
    Chk ((Get-YakuWarningCategories -Warnings $jpWriteWarnings) -notcontains 'output-font-missing') '正しい和書体では警告が出ない'

    # --- 「1か所も当てられなかった」が利用者まで届く線 -----------------------
    # `Invoke-YakuExcelFontUnionApply` を直に呼ぶ表明（上の D）は、シート書込の
    # 入口が `-Warnings` を渡しているかを1つも見ていない。渡すのをやめても
    # 全部緑のままだった。だからここは**シート書込の入口を通して**測る。
    #
    # 値は書けるのに書体だけ当てられない状態を作る（実測 2026-08-16）:
    # セルの Locked を外し、シートを AllowFormattingCells=false で保護すると
    # `Value2` は通り、`Font.Name` は「Font クラスの Name プロパティを
    # 設定できません。」で落ちる。保護されたシートは実在するので、題材としても
    # 作り物ではない。
    Write-Host '1か所も当てられなかったことが、シート書込の入口から外へ出る' -ForegroundColor Cyan
    $lockedWarnings = New-Object System.Collections.Generic.List[object]
    $lockedMetrics = @{}
    $lockedValue = ''
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        $wb = $xl.Workbooks.Add()
        $ws = $wb.Worksheets.Item(1); $ws.Name = 'S1'
        $ws.Cells.Item(1,1).Value2 = 'seed'
        $ws.Range('A1:D10').Locked = $false
        $ws.Protect($null, $true, $true, $true, $false, $false, $false, $false, $false, $false, $false, $false, $false, $false, $false, $false)
        $lockedBlocks = @(
            [pscustomobject]@{ Id='p1'; Text='seed'; Location='S1, A3'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=3; Col=1; A1='A3'; Merged=$false } }
        )
        $null = Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks ([object[]]$lockedBlocks) `
            -TranslationByBlockId @{ 'p1' = 'written anyway' } -OutputFontName $probeFont `
            -Warnings $lockedWarnings -Metrics $lockedMetrics
        $lockedValue = [string]$ws.Cells.Item(3,1).Value2
        $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }
    # 題材がその枝へ届いているか先に見る。届いていなければ、下の表明は空回りする。
    Chk ($lockedValue -eq 'written anyway') ('保護されていても、値そのものは書けている: ' + $lockedValue)
    Chk ([int]$lockedMetrics['font_input_addresses'] -ge 1) ('書体を当てる住所は積まれている: ' + [string]$lockedMetrics['font_input_addresses'])
    Chk ([int]$lockedMetrics['font_ranges_applied'] -eq 0 -and [int]$lockedMetrics['font_ranges_failed'] -ge 1) ('1か所も当たらず、落ちた数が残る: applied=' + [string]$lockedMetrics['font_ranges_applied'] + ' failed=' + [string]$lockedMetrics['font_ranges_failed'])
    Chk ((Get-YakuWarningCategories -Warnings $lockedWarnings) -contains 'output-font-apply-failed') 'その警告がシート書込の入口の警告入れへ届く'
    Chk (-not (Test-YakuIncompleteWarnings -Warnings $lockedWarnings)) '当てられなくても書き出しの中断条件にはしない'

    # =======================================================================
    # 5. 向きが**外側の入口から書込まで**届いているか（実機）
    # =======================================================================
    # ここまでの向きの表明は Write-YakuExcelTranslations（内側）を直に呼んで
    # いるので、**外側が向きを渡し忘れても全部緑のまま**だった。実測で確かめた
    # 抜け道は2つあり、どちらも内側の既定（to_en）が黙って埋める。
    #   - FileProcessors.ps1 の Write-YakuFileTranslations が
    #     Write-YakuExcelTranslations へ -Direction を渡すのをやめる
    #   - CatProject.ps1 の Export-YakuCatProject が -Direction を to_en に固定する
    # どちらも英→和の日本語セルへ Arial が戻る。**それぞれの入口を to_jp で
    # 1回ずつ通し**、出来上がりの xlsx に書かれた書体名を読む。
    Write-Host '向きが外側の入口から書込まで届く' -ForegroundColor Cyan

    $entrySrc = Join-Path $workDir 'entry-src.xlsx'
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
        $wb = $xl.Workbooks.Add()
        $ws = $wb.Worksheets.Item(1); $ws.Name = 'S1'
        $ws.Cells.Item(1,1).Value2 = 'Quarterly report'
        $wb.SaveAs($entrySrc, 51); $wb.Close($false)
    } finally {
        try { $xl.Quit() } catch {}
        Release-YakuComObject $xl
        try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
    }

    # (5-1) ファイル書き出しの入口
    $entryBlocks = @(
        [pscustomobject]@{ Id='e1'; Text='Quarterly report'; Location='S1, A1'; Meta=[pscustomobject]@{ Kind='cell'; Sheet='S1'; Row=1; Col=1; A1='A1'; Merged=$false } }
    )
    $entryWarnings = New-Object System.Collections.Generic.List[object]
    $entryResult = Write-YakuFileTranslations -InputPath $entrySrc -OutputPath (Join-Path $workDir 'entry-out.xlsx') `
        -Blocks $entryBlocks -TranslationByBlockId @{ 'e1' = '四半期報告' } `
        -Settings $settings -Warnings $entryWarnings -Direction 'to_jp'
    $entryPublished = [string]$entryResult.PublishedPath
    Chk (Test-Path -LiteralPath $entryPublished) ('ファイル書き出しの入口が出力を作る: ' + $entryPublished)
    $entryFont = Get-YakuXlsxAppliedFontName -Path $entryPublished -SheetName 'S1' -Address 'A1'
    Chk ($entryFont -ceq $expectedJpFont) ('ファイル書き出しの入口へ to_jp を渡すと、和書体が書かれる: ' + (Get-YakuFontCodePoints $entryFont))

    # (5-2) CAT の書き出し。**to_jp で1本通す門はここまで1つも無かった。**
    $catSrc = Join-Path $workDir 'cat-src.xlsx'
    Copy-Item -LiteralPath $entrySrc -Destination $catSrc -Force
    $catProject = New-YakuCatProject -Root $root -Path $catSrc -Settings $settings -Direction 'to_jp'
    try {
        Chk ([string]$catProject.Direction -eq 'to_jp') ('英→和の作業として取り込める: ' + [string]$catProject.Direction)
        for ($i = 0; $i -lt @($catProject.Segments).Count; $i++) {
            $null = Set-YakuCatSegmentTranslation -Project $catProject -Index $i -Text '四半期報告'
            $null = Set-YakuCatSegmentConfirmed -Project $catProject -Index $i
        }
        $null = Save-YakuCatProject -Project $catProject
        $catOut = Join-Path $workDir 'cat-out.xlsx'
        $catExported = Export-YakuCatProject -Project $catProject -OutputPath $catOut -Settings $settings
        $catPublished = [string]$catExported.OutputPath
        Chk (Test-Path -LiteralPath $catPublished) ('CAT の書き出しが出力を作る: ' + $catPublished)
        $catFont = Get-YakuXlsxAppliedFontName -Path $catPublished -SheetName 'S1' -Address 'A1'
        Chk ($catFont -ceq $expectedJpFont) ('英→和の作業を書き出すと、和書体が書かれる: ' + (Get-YakuFontCodePoints $catFont))
    } finally {
        try { Remove-YakuCatProject -Id ([string]$catProject.Id) } catch {}
    }
}

}
finally {
    $env:YAKULINGO_DATA_DIR = $previousDataDir
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) {
    Write-Host ('V91.61 output font regression failed. failures=' + $script:fail) -ForegroundColor Red
    exit 1
}
if (-not $script:excelMeasured) {
    Write-Host 'V91.61 output font: Excel の要る表明は未測定（exit 3）。それ以外は緑。' -ForegroundColor Yellow
    exit 3
}
Write-Host 'V91.61 output font regression passed.' -ForegroundColor Green
exit 0
