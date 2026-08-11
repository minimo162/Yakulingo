function Get-YakuSettingBool {
    param(
        [AllowNull()]$Settings,
        [Parameter(Mandatory=$true)][string]$Name,
        [bool]$Default = $false
    )
    try {
        if ($Settings -and ($Settings.PSObject.Properties.Name -contains $Name)) {
            $v = $Settings.$Name
            if ($v -is [bool]) { return [bool]$v }
            return ([string]$v -in @('true','on','1','yes'))
        }
    } catch {}
    return $Default
}

function Get-YakuSettingInt {
    param(
        [AllowNull()]$Settings,
        [Parameter(Mandatory=$true)][string]$Name,
        [int]$Default = 0
    )
    try {
        if ($Settings -and ($Settings.PSObject.Properties.Name -contains $Name)) {
            $v = [int]$Settings.$Name
            return $v
        }
    } catch {}
    return $Default
}

function Get-YakuSettingString {
    param(
        [AllowNull()]$Settings,
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowNull()][string]$Default = ''
    )
    try {
        if ($Settings -and ($Settings.PSObject.Properties.Name -contains $Name)) {
            return [string]$Settings.$Name
        }
    } catch {}
    return [string]$Default
}

function Test-YakuExcelAvailable {
    try { return ($null -ne [type]::GetTypeFromProgID('Excel.Application')) } catch { return $false }
}

function Get-YakuSupportedFileKind {
    param([Parameter(Mandatory=$true)][string]$Path)
    $ext = ([System.IO.Path]::GetExtension($Path)).ToLowerInvariant()
    switch ($ext) {
        '.xlsx' { return 'excel' }
        '.xlsm' { return 'excel' }
        '.csv' { return 'csv' }
        '.xls' { throw '.xls は非対応です。Excelで .xlsx に変換してから実行してください。' }
        default { throw '対応しているファイル形式は .xlsx / .xlsm / .csv です。' }
    }
}

function Test-YakuHasJapaneseChars {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch([string]$Text, '[ぁ-んァ-ヶ一-龯々〆ヵヶｦ-ﾟ]')
}

function Test-YakuHasLatinChars {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch([string]$Text, '[A-Za-z]')
}

function Test-YakuHasHangulChars {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch([string]$Text, '[가-힣]')
}

function Test-YakuShouldTranslateCell {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $s = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }

    # Numeric / symbol-only cells, dates, mail addresses, URLs, and code-like tokens are left untouched.
    if ($s -match '^[\s\d０-９,，.．/／\\\-－ー―:+＋%％()（）\[\]【】<>＜＞▲△▼▽●○■□〇※＊*#＃&＆@＠￥¥$€£~～=＝_＿|｜;；:：''"”“,、。]+$') { return $false }
    if ($s -match '^\d{1,4}[/-]\d{1,2}([/-]\d{1,2})?(\s+\d{1,2}:\d{2}(:\d{2})?)?$') { return $false }
    if ($s -match '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$') { return $false }
    if ($s -match '^(https?://|www\.)\S+$') { return $false }
    if ($s -match '^[A-Z]{2,}[A-Z0-9_./]*[-_][A-Z0-9_.\-/]+$') { return $false }
    if ($s -match '^[¥￥$€£]\s*[\d,]+(\.\d+)?$') { return $false }

    if ($Direction -eq 'to_en') {
        return (Test-YakuHasJapaneseChars -Text $s)
    }

    # For non-Japanese to Japanese, Japanese-only strings do not need translation.
    if ((Test-YakuHasJapaneseChars -Text $s) -and -not (Test-YakuHasLatinChars -Text $s)) { return $false }
    return ((Test-YakuHasLatinChars -Text $s) -or (Test-YakuHasHangulChars -Text $s))
}

function ConvertTo-YakuColumnLetter {
    param([Parameter(Mandatory=$true)][int]$Column)
    if ($Column -lt 1) { throw "Invalid column index: $Column" }
    $letters = ''
    $c = [int]$Column
    while ($c -gt 0) {
        $rem = [int](($c - 1) % 26)
        $letters = ([string][char]([int](65 + $rem))) + $letters
        $c = [int][Math]::Floor((([double]$c - 1.0) / 26.0))
    }
    return $letters
}

function Convert-YakuColumnNumberToName {
    param([Parameter(Mandatory=$true)][int]$Column)
    return (ConvertTo-YakuColumnLetter -Column $Column)
}

function New-YakuColumnLetterCache {
    param(
        [Parameter(Mandatory=$true)][Alias('FirstColumn')][int]$StartColumn,
        [Parameter(Mandatory=$true)][Alias('ColumnCount')][int]$Count
    )
    $cache = @{}
    if ($Count -lt 1) { return $cache }
    $lastColumn = [int]($StartColumn + $Count - 1)
    for ($col = [int]$StartColumn; $col -le $lastColumn; $col++) {
        $cache[$col] = ConvertTo-YakuColumnLetter -Column $col
    }
    return $cache
}

function Convert-YakuColumnNameToNumber {
    param([Parameter(Mandatory=$true)][string]$Name)
    $n = 0
    foreach ($ch in ([string]$Name).ToUpperInvariant().ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 65 -or $code -gt 90) { continue }
        $n = ([int]$n * 26) + ($code - 64)
    }
    return [int]$n
}

function Convert-YakuA1ToCoord {
    param([Parameter(Mandatory=$true)][string]$Address)
    $a = ([string]$Address).Trim().Replace('$','')
    if ($a.Contains('!')) { $a = $a.Substring($a.LastIndexOf('!') + 1).Trim("'") }
    if ($a -notmatch '^([A-Za-z]+)(\d+)$') { return $null }
    return [pscustomobject]@{ Row=[int]$Matches[2]; Col=(Convert-YakuColumnNameToNumber -Name $Matches[1]) }
}

function Get-YakuRangeArrayValue {
    param(
        [AllowNull()]$Values,
        [int]$RowOffset,
        [int]$ColOffset
    )
    if ($null -eq $Values) { return $null }
    if ($Values -is [System.Array] -and $Values.Rank -eq 2) {
        $r = $Values.GetLowerBound(0) + $RowOffset - 1
        $c = $Values.GetLowerBound(1) + $ColOffset - 1
        return $Values.GetValue($r, $c)
    }
    if ($RowOffset -eq 1 -and $ColOffset -eq 1) { return $Values }
    return $null
}

function Release-YakuComObject {
    param([AllowNull()]$Object)
    if ($null -eq $Object) { return }
    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object) } catch {}
}


function Close-YakuExcelObjects {
    param(
        [AllowNull()]$Workbook,
        [AllowNull()]$Application,
        [bool]$Save = $false,
        [AllowNull()]$OldCalculation,
        [AllowNull()]$OldCalculateBeforeSave,
        [AllowNull()]$OldScreenUpdating,
        [AllowNull()]$OldEnableEvents,
        [AllowNull()]$OldDisplayStatusBar,
        [AllowNull()]$OldFormatConditionsCalc,
        [AllowNull()]$OldBackgroundChecking
    )
    try {
        if ($null -ne $Workbook) {
            try { if ($Save) { $Workbook.Save() | Out-Null } } catch {}
            try { $Workbook.Close($false) | Out-Null } catch {}
        }
    } catch {}
    try {
        if ($null -ne $Application) {
            try { if ($null -ne $OldCalculation) { $Application.Calculation = $OldCalculation } } catch {}
            try { if ($null -ne $OldCalculateBeforeSave) { $Application.CalculateBeforeSave = $OldCalculateBeforeSave } } catch {}
            try { if ($null -ne $OldScreenUpdating) { $Application.ScreenUpdating = $OldScreenUpdating } } catch {}
            try { if ($null -ne $OldEnableEvents) { $Application.EnableEvents = $OldEnableEvents } } catch {}
            try { if ($null -ne $OldFormatConditionsCalc) { $Application.EnableFormatConditionsCalculation = $OldFormatConditionsCalc } } catch {}
            try { if ($null -ne $OldBackgroundChecking) { $Application.ErrorCheckingOptions.BackgroundChecking = $OldBackgroundChecking } } catch {}
            try { if ($null -ne $OldDisplayStatusBar) { $Application.DisplayStatusBar = $OldDisplayStatusBar } } catch {}
            try { $Application.Quit() | Out-Null } catch {}
        }
    } catch {}
    Release-YakuComObject $Workbook
    Release-YakuComObject $Application
    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
}

function New-YakuExcelApplication {
    if (-not (Test-YakuExcelAvailable)) { throw 'Excelがインストールされていないため、xlsx/xlsm を処理できません。CSVのみ利用できます。' }
    $excel = New-Object -ComObject Excel.Application
    $oldScreenUpdating = $null
    $oldEnableEvents = $null
    $oldDisplayStatusBar = $null
    $oldFormatConditionsCalc = $null
    $oldBackgroundChecking = $null
    try { $oldScreenUpdating = $excel.ScreenUpdating } catch {}
    try { $oldEnableEvents = $excel.EnableEvents } catch {}
    try { $oldDisplayStatusBar = $excel.DisplayStatusBar } catch {}
    try { $oldFormatConditionsCalc = $excel.EnableFormatConditionsCalculation } catch {}
    try { $oldBackgroundChecking = $excel.ErrorCheckingOptions.BackgroundChecking } catch {}
    try { $excel.Visible = $false } catch {}
    try { $excel.DisplayAlerts = $false } catch {}
    try { $excel.AutomationSecurity = 3 } catch {} # msoAutomationSecurityForceDisable
    try { $excel.ScreenUpdating = $false } catch {}
    try { $excel.EnableEvents = $false } catch {}
    try { $excel.DisplayStatusBar = $false } catch {}
    try { $excel.EnableFormatConditionsCalculation = $false } catch {}
    try { $excel.ErrorCheckingOptions.BackgroundChecking = $false } catch {}
    $excelPid = 0
    try {
        if (-not ('YakuLingoNativeMethods' -as [type])) {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class YakuLingoNativeMethods { [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId); }' -ErrorAction Stop | Out-Null
        }
        $nativePid = [uint32]0
        $null = [YakuLingoNativeMethods]::GetWindowThreadProcessId([IntPtr]([int64]$excel.Hwnd), [ref]$nativePid)
        $excelPid = [int]$nativePid
        if ($script:YakuWorkerProgressState -and $excelPid -gt 0) {
            $script:YakuWorkerProgressState['excel_pid'] = $excelPid
            $script:YakuWorkerProgressState['excel_started_at'] = Get-YakuProcessStartTimeIso -Id $excelPid
            Write-YakuProgressStateFile -ProgressState $script:YakuWorkerProgressState
        }
    } catch {}
    return [pscustomobject]@{
        Application=$excel
        ProcessId=$excelPid
        OldCalculation=$null
        OldCalculateBeforeSave=$null
        OldScreenUpdating=$oldScreenUpdating
        OldEnableEvents=$oldEnableEvents
        OldDisplayStatusBar=$oldDisplayStatusBar
        OldFormatConditionsCalc=$oldFormatConditionsCalc
        OldBackgroundChecking=$oldBackgroundChecking
    }
}

function Set-YakuExcelManualCalculation {
    param([Parameter(Mandatory=$true)]$Application)
    $old = $null
    $oldCalcBeforeSave = $null
    try { $old = $Application.Calculation } catch {}
    try { $oldCalcBeforeSave = $Application.CalculateBeforeSave } catch {}
    try { $Application.Calculation = -4135 } catch {}        # xlCalculationManual
    try { $Application.CalculateBeforeSave = $false } catch {} # B-2
    return [pscustomobject]@{ OldCalculation=$old; OldCalculateBeforeSave=$oldCalcBeforeSave }
}

function Set-YakuExcelAutomaticCalculationForOutput {
    param(
        [AllowNull()]$Application,
        [AllowNull()]$Workbook = $null
    )
    if ($null -eq $Application) { return }
    try {
        $Application.Calculation = -4105        # xlCalculationAutomatic
    } catch {
        try { Write-YakuLog "Output automatic calc restore failed: $($_.Exception.Message)" 'WARN' } catch {}
    }
    try { $Application.CalculateBeforeSave = $true } catch {}
    # 翻訳中は再計算を抑止するが、出力ブックには「自動計算」を保存して利用者側に残す。
    try { if ($null -ne $Workbook) { $Workbook.Saved = $false } } catch {}
    try { Write-YakuLog "Excel calc mode before output save: $($Application.Calculation) calcBeforeSave=$($Application.CalculateBeforeSave)" 'INFO' } catch {}
}

function Clear-YakuOutputReadOnlyAttribute {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace([string]$Path)) { return $false }
    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if (-not $fi.Exists) {
            try { Write-YakuLog "Writeback output attribute clear skipped; file not found. output=$Path" 'WARN' } catch {}
            return $false
        }
        $readOnlyAttr = [System.IO.FileAttributes]::ReadOnly
        if (($fi.Attributes -band $readOnlyAttr) -ne 0) {
            $fi.Attributes = [System.IO.FileAttributes](([int]$fi.Attributes) -band (-bnot [int]$readOnlyAttr))
            try { Write-YakuLog "Writeback output ReadOnly attribute cleared. output=$Path" 'INFO' } catch {}
            return $true
        }
    } catch {
        try { Write-YakuLog "Writeback output attribute clear failed: $($_.Exception.Message)" 'WARN' } catch {}
    }
    return $false
}

function Add-YakuInputReadOnlyNotice {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()]$Warnings = $null
    )
    if ([string]::IsNullOrWhiteSpace([string]$Path)) { return }
    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if (-not $fi.Exists) { return }
        if (($fi.Attributes -band [System.IO.FileAttributes]::ReadOnly) -eq 0) { return }
        $message = '入力は読み取り専用ですが、翻訳結果は別ファイルに書き込み可能な状態で保存されます。'
        $location = [System.IO.Path]::GetFileName($Path)
        try { Write-YakuLog "file-input: $message input=$Path" 'INFO' } catch {}
        try {
            if ($null -ne $Warnings) {
                $alreadyAdded = $false
                try {
                    foreach ($w in @($Warnings.ToArray())) {
                        if ([string]$w.Category -eq 'file-input' -and [string]$w.Location -eq $location -and [string]$w.Message -eq $message) { $alreadyAdded = $true; break }
                    }
                } catch {}
                if (-not $alreadyAdded) {
                    Add-YakuWarning -Warnings $Warnings -Category 'file-input' -Location $location -Message $message
                }
            }
        } catch {}
    } catch {
        try { Write-YakuLog "Input ReadOnly attribute check failed: $($_.Exception.Message)" 'WARN' } catch {}
    }
}

function Assert-YakuExcelWorkbookWritableForOutput {
    param([AllowNull()]$Workbook)
    if ($null -eq $Workbook) { return }
    $wbReadOnly = $false
    try { $wbReadOnly = [bool]$Workbook.ReadOnly } catch { $wbReadOnly = $false }
    if ($wbReadOnly) {
        $reason = '出力ファイルが読み取り専用で開かれたため保存できません。'
        try {
            if ([bool]$Workbook.WriteReserved) {
                $reason = 'ブックに書き込みパスワードが設定されているため保存できません。パスワードを解除したファイルで再実行してください。'
            }
        } catch {}
        throw $reason
    }
}


function Set-YakuExcelContextCalculationState {
    param(
        [AllowNull()]$Context,
        [Parameter(Mandatory=$true)]$Application
    )
    $calcState = Set-YakuExcelManualCalculation -Application $Application
    try {
        if ($null -ne $Context) {
            if ($null -eq $Context.OldCalculation) { $Context.OldCalculation = $calcState.OldCalculation }
            if ($null -eq $Context.OldCalculateBeforeSave) { $Context.OldCalculateBeforeSave = $calcState.OldCalculateBeforeSave }
        }
    } catch {}
    try { Write-YakuLog "Excel calc mode after open: $($Application.Calculation) calcBeforeSave=$($Application.CalculateBeforeSave)" 'DEBUG' } catch {}
    return $calcState
}


function Open-YakuWorkbookWithManualCalc {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$Path,
        [bool]$ReadOnly = $true
    )
    $excel = $Context.Application
    $tempWb = $null
    try {
        try {
            $tempWb = $excel.Workbooks.Add()
            Set-YakuExcelContextCalculationState -Context $Context -Application $excel | Out-Null
        } catch {
            try { Write-YakuLog "Pre-open manual calc failed: $($_.Exception.Message)" 'WARN' } catch {}
        }
        $missing = [Type]::Missing
        if ($ReadOnly) {
            $workbook = $excel.Workbooks.Open($Path, 0, $true)
        } else {
            # Open(FileName, UpdateLinks, ReadOnly, Format, Password, WriteResPassword, IgnoreReadOnlyRecommended, ...)
            $workbook = $excel.Workbooks.Open($Path, 0, $false, $missing, $missing, $missing, $true)
        }
        # Open時にブック側設定で上書きされるケースの保険。
        Set-YakuExcelContextCalculationState -Context $Context -Application $excel | Out-Null
        return $workbook
    } finally {
        try { if ($null -ne $tempWb) { $tempWb.Close($false) | Out-Null } } catch {}
        Release-YakuComObject $tempWb
    }
}

function Get-YakuExcelFormulaAddressSet {
    param([Parameter(Mandatory=$true)]$UsedRange, [AllowNull()]$Warnings = $null)
    # V91.10: FormulaSet is built from Formula/Value2 arrays, not SpecialCells.Address.
    # FormulaSet is only a performance pre-filter. The write-time HasFormula guard remains
    # the final integrity boundary even when this mask is unexpectedly incomplete.
    $set = @{}
    $values = $null
    $formulas = $null
    try {
        $startRow = [int]$UsedRange.Row
        $startCol = [int]$UsedRange.Column
        $rowCount = [int]$UsedRange.Rows.Count
        $colCount = [int]$UsedRange.Columns.Count
        $values = $UsedRange.Value2
        $formulas = $UsedRange.Formula

        if ($rowCount -eq 1 -and $colCount -eq 1) {
            $formulaText = if ($null -eq $formulas) { '' } else { [string]$formulas }
            $valueText = if ($null -eq $values) { '' } else { [string]$values }
            if ($formulaText.StartsWith('=') -and $formulaText -ne $valueText) { $set["$startRow,$startCol"] = $true }
            return $set
        }
        if (-not ($formulas -is [System.Array]) -or $formulas.Rank -ne 2 -or -not ($values -is [System.Array]) -or $values.Rank -ne 2) {
            if ($null -ne $Warnings) { Add-YakuWarning -Warnings $Warnings -Category 'formula-mask-unknown' -Location 'Excel' -Message 'Formula配列の形状を確認できないため安全なターゲット限定書込へ切り替えます。' }
            return $null
        }
        $fr0 = [int]$formulas.GetLowerBound(0); $fc0 = [int]$formulas.GetLowerBound(1)
        $vr0 = [int]$values.GetLowerBound(0); $vc0 = [int]$values.GetLowerBound(1)
        for ($r = 0; $r -lt $rowCount; $r++) {
            for ($c = 0; $c -lt $colCount; $c++) {
                $formulaValue = $formulas.GetValue($fr0 + $r, $fc0 + $c)
                $valueValue = $values.GetValue($vr0 + $r, $vc0 + $c)
                $formulaText = if ($null -eq $formulaValue) { '' } else { [string]$formulaValue }
                $valueText = if ($null -eq $valueValue) { '' } else { [string]$valueValue }
                if ($formulaText.StartsWith('=') -and $formulaText -ne $valueText) {
                    $set["$([int]($startRow + $r)),$([int]($startCol + $c))"] = $true
                }
            }
        }
        try { Write-YakuLog "Excel write formula mask. address=$([string]$UsedRange.Address($false,$false)) formulaCells=$($set.Count)" 'DEBUG' } catch {}
        return $set
    } catch {
        if ($null -ne $Warnings) { Add-YakuWarning -Warnings $Warnings -Category 'formula-mask-unknown' -Location 'Excel' -Message "Formula配列の取得に失敗したため安全なターゲット限定書込へ切り替えます。error=$($_.Exception.Message)" }
        return $null
    }
}


function Get-YakuExcelFormulaCellCount {
    param([Parameter(Mandatory=$true)]$UsedRange)
    $formulaRange = $null
    try {
        $formulaRange = $UsedRange.SpecialCells(-4123) # xlCellTypeFormulas
        try { return [int]$formulaRange.Count } catch { return 0 }
    } catch {
        return 0
    } finally {
        Release-YakuComObject $formulaRange
    }
}


function New-YakuExcelMergeCellInfo {
    param(
        [bool]$IsWritable = $true,
        [bool]$IsMerged = $false,
        [bool]$IsTopLeft = $true,
        [int]$TopRow = 0,
        [int]$LeftCol = 0,
        [int]$Rows = 1,
        [int]$Cols = 1
    )
    return [pscustomobject]@{ IsWritable=$IsWritable; IsMerged=$IsMerged; IsTopLeft=$IsTopLeft; TopRow=$TopRow; LeftCol=$LeftCol; Rows=$Rows; Cols=$Cols }
}

function Get-YakuExcelMergeCellInfo {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [int]$Row,
        [int]$Col,
        [AllowNull()][hashtable]$MergeCache = $null
    )
    $key = "$Row,$Col"
    if ($null -ne $MergeCache -and $MergeCache.ContainsKey($key)) {
        $cached = $MergeCache[$key]
        try {
            if ($cached -and $cached.PSObject -and ($cached.PSObject.Properties.Name -contains 'IsWritable')) { return $cached }
        } catch {}
        return (New-YakuExcelMergeCellInfo -IsWritable ([bool]$cached) -IsMerged $false -IsTopLeft ([bool]$cached) -TopRow $Row -LeftCol $Col)
    }
    $cell = $null
    $mergeArea = $null
    try {
        $cell = $Worksheet.Cells.Item($Row, $Col)
        $isMerged = $false
        try { $isMerged = [bool]$cell.MergeCells } catch { $isMerged = $false }
        if (-not $isMerged) {
            $info = New-YakuExcelMergeCellInfo -IsWritable $true -IsMerged $false -IsTopLeft $true -TopRow $Row -LeftCol $Col -Rows 1 -Cols 1
            if ($null -ne $MergeCache) { $MergeCache[$key] = $info }
            return $info
        }
        $mergeArea = $cell.MergeArea
        $topRow = [int]$mergeArea.Row
        $leftCol = [int]$mergeArea.Column
        $rows = [int]$mergeArea.Rows.Count
        $cols = [int]$mergeArea.Columns.Count
        $isTopLeft = ($topRow -eq $Row -and $leftCol -eq $Col)
        if ($null -ne $MergeCache) {
            for ($rr = $topRow; $rr -lt ($topRow + $rows); $rr++) {
                for ($cc = $leftCol; $cc -lt ($leftCol + $cols); $cc++) {
                    $cellInfo = New-YakuExcelMergeCellInfo -IsWritable ($rr -eq $topRow -and $cc -eq $leftCol) -IsMerged $true -IsTopLeft ($rr -eq $topRow -and $cc -eq $leftCol) -TopRow $topRow -LeftCol $leftCol -Rows $rows -Cols $cols
                    $MergeCache["$rr,$cc"] = $cellInfo
                }
            }
            return $MergeCache[$key]
        }
        return (New-YakuExcelMergeCellInfo -IsWritable $isTopLeft -IsMerged $true -IsTopLeft $isTopLeft -TopRow $topRow -LeftCol $leftCol -Rows $rows -Cols $cols)
    } catch {
        $fallback = New-YakuExcelMergeCellInfo -IsWritable $true -IsMerged $false -IsTopLeft $true -TopRow $Row -LeftCol $Col -Rows 1 -Cols 1
        if ($null -ne $MergeCache) { $MergeCache[$key] = $fallback }
        return $fallback
    } finally {
        Release-YakuComObject $mergeArea
        Release-YakuComObject $cell
    }
}

function Test-YakuIsMergeTopLeftCell {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [int]$Row,
        [int]$Col,
        [AllowNull()][hashtable]$MergeCache = $null
    )
    $info = Get-YakuExcelMergeCellInfo -Worksheet $Worksheet -Row $Row -Col $Col -MergeCache $MergeCache
    try { return [bool]$info.IsWritable } catch { return $true }
}

function New-YakuTextBlock {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Location,
        [Parameter(Mandatory=$true)]$Meta
    )
    return [pscustomobject]@{ Id=$Id; Text=$Text; Location=$Location; Meta=$Meta }
}

function New-YakuStatsObject {
    return @{
        cells = 0
        shapes = 0
        charts = 0
        skipped_formula_cells = 0
        skipped_smartart = 0
        skipped_non_text_shapes = 0
        warnings = 0
    }
}

function Add-YakuWarning {
    param(
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$Warning,
        [AllowNull()][string]$Category = 'general',
        [AllowNull()][string]$Message = '',
        [AllowNull()][string]$Location = '',
        [Alias('Details')][AllowNull()][object]$Detail = $null,
        [int]$Batch = 0
    )
    try {
        if ($null -eq $Warnings) { return }
        if ($null -ne $Warning) {
            if ($Warning -is [string]) {
                if ([string]::IsNullOrWhiteSpace([string]$Message)) { $Message = [string]$Warning }
            } elseif ($Warning.PSObject -and ($Warning.PSObject.Properties.Name -contains 'Message')) {
                $names = @($Warning.PSObject.Properties.Name)
                if ([string]::IsNullOrWhiteSpace([string]$Message)) { $Message = [string]$Warning.Message }
                if ($names -contains 'Category') { $Category = [string]$Warning.Category }
                if ($names -contains 'Location') { $Location = [string]$Warning.Location }
                if ($names -contains 'Details') { $Detail = $Warning.Details }
                elseif ($names -contains 'Detail') { $Detail = $Warning.Detail }
                if ($names -contains 'Batch') { try { $Batch = [int]$Warning.Batch } catch {} }
            } else {
                if ([string]::IsNullOrWhiteSpace([string]$Message)) { $Message = [string]$Warning }
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$Message)) { return }

        # V37: 同一カテゴリの警告上限。上限到達後は加算せずログのみ。
        $categoryKey = if ([string]::IsNullOrWhiteSpace($Category)) { 'general' } else { [string]$Category }
        try { if ($null -eq $script:YakuWarningSuppressionLogged) { $script:YakuWarningSuppressionLogged = @{} } } catch { $script:YakuWarningSuppressionLogged = @{} }
        $totalWarningCount = 0
        try { $totalWarningCount = [int]$Warnings.Count } catch { $totalWarningCount = 0 }
        if ($totalWarningCount -ge 1000) {
            try {
                if (-not $script:YakuWarningSuppressionLogged.ContainsKey('__global__')) {
                    $script:YakuWarningSuppressionLogged['__global__'] = $true
                    Write-YakuLog 'Warning list reached global cap 1000; suppressing further warnings.' 'WARN'
                }
            } catch {}
            return
        }
        $sameCategoryCount = 0
        try {
            foreach ($w in @($Warnings.ToArray())) {
                $cat = ''
                try { $cat = [string]$w.Category } catch { $cat = '' }
                if ([string]::IsNullOrWhiteSpace($cat)) { $cat = 'general' }
                if ($cat -eq $categoryKey) { $sameCategoryCount++ }
            }
        } catch { $sameCategoryCount = 0 }
        if ($sameCategoryCount -ge 200) {
            try {
                $logKey = 'category:' + $categoryKey
                if (-not $script:YakuWarningSuppressionLogged.ContainsKey($logKey)) {
                    $script:YakuWarningSuppressionLogged[$logKey] = $true
                    Write-YakuLog "Warning category cap reached: $categoryKey; suppressing further warnings." 'WARN'
                }
            } catch {}
            return
        }
        if ($sameCategoryCount -eq 199) { $Message = "$Message（このカテゴリの警告は以降省略されます）" }
        if ($sameCategoryCount -ge 50) { $Detail = $null }

        $detailText = ''
        if ($null -ne $Detail) {
            try {
                if ($Detail -is [string]) { $detailText = [string]$Detail }
                else { $detailText = ($Detail | ConvertTo-Json -Depth 8 -Compress) }
            } catch { $detailText = [string]$Detail }
        }
        $Warnings.Add([pscustomobject]@{
            Category = $categoryKey
            Message = [string]$Message
            Location = [string]$Location
            Detail = $detailText
            Details = $Detail
            Batch = [int]$Batch
        }) | Out-Null
    } catch {}
}

function Get-YakuWarningMessage {
    param([AllowNull()]$Warning)
    if ($null -eq $Warning) { return '' }
    try {
        if ($Warning.PSObject.Properties.Name -contains 'Message') { return [string]$Warning.Message }
    } catch {}
    return [string]$Warning
}



function Copy-YakuWarning {
    param(
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$Warning
    )
    if ($null -eq $Warning) { return }
    try {
        if ($Warning -is [string]) {
            Add-YakuWarning -Warnings $Warnings -Message ([string]$Warning) -Category 'general'
            return
        }
        $names = @($Warning.PSObject.Properties.Name)
        if ($names -contains 'Message') {
            $cat = if ($names -contains 'Category') { [string]$Warning.Category } else { 'general' }
            $loc = if ($names -contains 'Location') { [string]$Warning.Location } else { '' }
            $detail = if ($names -contains 'Detail') { [string]$Warning.Detail } else { '' }
            Add-YakuWarning -Warnings $Warnings -Message ([string]$Warning.Message) -Category $cat -Location $loc -Detail $detail
            return
        }
    } catch {}
    Add-YakuWarning -Warnings $Warnings -Message ([string]$Warning) -Category 'general'
}


function Get-YakuShapeTypeSkipReason {
    param([int]$ShapeType)
    switch ($ShapeType) {
        13 { return 'picture' }
        3 { return 'chart-shape' }
        7 { return 'embedded-ole' }
        10 { return 'linked-ole' }
        12 { return 'ole-control' }
        16 { return 'media' }
        24 { return 'smartart' }
        default { return '' }
    }
}

function Get-YakuShapeIndexPathText {
    param([Parameter(Mandatory=$true)][int[]]$IndexPath)
    return (($IndexPath | ForEach-Object { [string]$_ }) -join '/')
}

function Get-YakuShapeTextBlocksRecursive {
    param(
        [Parameter(Mandatory=$true)]$Shape,
        [Parameter(Mandatory=$true)][string]$SheetName,
        [Parameter(Mandatory=$true)][int[]]$IndexPath,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Blocks,
        [Parameter(Mandatory=$true)]$Warnings,
        [Parameter(Mandatory=$true)][hashtable]$Stats,
        [int]$Depth = 0
    )
    if ($Depth -gt 5) {
        Add-YakuWarning -Warnings $Warnings -Category shape-group-depth -Location "$SheetName / $(Get-YakuShapeIndexPathText -IndexPath $IndexPath)" -Message "図形グループが深すぎるためスキップしました: $SheetName / $(Get-YakuShapeIndexPathText -IndexPath $IndexPath)"
        return
    }

    $shapeType = 0
    try { $shapeType = [int]$Shape.Type } catch { $shapeType = 0 }
    $pathText = Get-YakuShapeIndexPathText -IndexPath $IndexPath

    if ($shapeType -eq 6) { # msoGroup
        $groupItems = $null
        try {
            $groupItems = $Shape.GroupItems
            $count = [int]$groupItems.Count
            for ($i = 1; $i -le $count; $i++) {
                $child = $null
                try {
                    $child = $groupItems.Item($i)
                    $childPath = @($IndexPath + $i)
                    Get-YakuShapeTextBlocksRecursive -Shape $child -SheetName $SheetName -IndexPath $childPath -Direction $Direction -Blocks $Blocks -Warnings $Warnings -Stats $Stats -Depth ($Depth + 1)
                } catch {
                    Add-YakuWarning -Warnings $Warnings -Category shape-extract-skip -Location "$SheetName / $pathText / $i" -Detail $_.Exception.Message -Message "グループ図形の読み取りをスキップしました: $SheetName / $pathText / $i - $($_.Exception.Message)"
                } finally {
                    Release-YakuComObject $child
                }
            }
        } catch {
            Add-YakuWarning -Warnings $Warnings -Category shape-extract-skip -Location "$SheetName / $pathText" -Detail $_.Exception.Message -Message "グループ図形を展開できませんでした: $SheetName / $pathText - $($_.Exception.Message)"
        } finally {
            Release-YakuComObject $groupItems
        }
        return
    }

    $skipReason = Get-YakuShapeTypeSkipReason -ShapeType $shapeType
    if ($skipReason -eq 'smartart') {
        $Stats['skipped_smartart'] = [int]$Stats['skipped_smartart'] + 1
        Add-YakuWarning -Warnings $Warnings -Category smartart-skip -Location "$SheetName / $pathText" -Message "SmartArtはPhase 1ではスキップしました: $SheetName / $pathText"
        return
    }
    if ($skipReason -ne '') {
        $Stats['skipped_non_text_shapes'] = [int]$Stats['skipped_non_text_shapes'] + 1
        return
    }

    $text = ''
    $tf = $null
    $textRange = $null
    try {
        $tf = $Shape.TextFrame2
        if ($null -eq $tf) { return }
        $hasText = $false
        try { $hasText = ([int]$tf.HasText -ne 0) } catch { $hasText = $false }
        if (-not $hasText) { return }
        $textRange = $tf.TextRange
        $text = [string]$textRange.Text
    } catch {
        return
    } finally {
        Release-YakuComObject $textRange
        Release-YakuComObject $tf
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $clean = $text.Trim()
    if (-not (Test-YakuShouldTranslateCell -Text $clean -Direction $Direction)) { return }
    $name = ''
    try { $name = [string]$Shape.Name } catch { $name = $pathText }
    $id = "shape|$SheetName|$pathText"
    $Blocks.Add((New-YakuTextBlock -Id $id -Text $clean -Location "$SheetName, Shape '$name'" -Meta ([pscustomobject]@{ Kind='shape'; Sheet=$SheetName; IndexPath=@($IndexPath); ShapeName=$name }))) | Out-Null
    $Stats['shapes'] = [int]$Stats['shapes'] + 1
}


function Get-YakuExcelSheetTextBlocksFallback {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)]$UsedRange,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Blocks,
        [Parameter(Mandatory=$true)]$Warnings,
        [Parameter(Mandatory=$true)][hashtable]$Stats
    )
    $sheetName = [string]$Worksheet.Name
    $localCells = 0
    $localFormulaSkipped = 0
    try {
        $startRow = [int]$UsedRange.Row
        $startCol = [int]$UsedRange.Column
        $rowCount = [int]$UsedRange.Rows.Count
        $colCount = [int]$UsedRange.Columns.Count
        $cellCount = [long]$rowCount * [long]$colCount
        if ($cellCount -gt 500000L) {
            Add-YakuWarning -Warnings $Warnings -Category 'cell-extract-oversize' -Location $sheetName -Message "UsedRange が過大なため抽出をスキップしました。行×列=$rowCount×$colCount"
            return
        }
        $values = $UsedRange.Value2
        # Formula is read only as a mask. Never write this array back: doing so can rewrite
        # shared, array, and dynamic-array formula representation.
        try { $formulas = $UsedRange.Formula } catch {
            Add-YakuWarning -Warnings $Warnings -Category 'formula-mask-read-failed' -Location $sheetName -Message "数式マスクの一括読取に失敗しました。セル単位HasFormula確認へ切り替えます。error=$($_.Exception.Message)"
            $formulas = $null
        }
        $isScalarUsed = ($rowCount -eq 1 -and $colCount -eq 1)
        $columnLetters = New-YakuColumnLetterCache -StartColumn $startCol -ColumnCount $colCount
        $mergeState = $false
        try { $mergeState = $UsedRange.MergeCells } catch { $mergeState = $false }
        $needsMergeCheck = $true
        try { if (($mergeState -is [bool]) -and ([bool]$mergeState -eq $false)) { $needsMergeCheck = $false } } catch { $needsMergeCheck = $true }
        if ($needsMergeCheck -and $cellCount -gt 2000L) {
            $needsMergeCheck = $false
            try { Write-YakuLog "Excel merge check simplified. sheet=$sheetName scope=used-range cells=$cellCount threshold=2000" 'DEBUG' } catch {}
        }
        $mergeCache = @{}

        for ($r = 1; $r -le $rowCount; $r++) {
            for ($c = 1; $c -le $colCount; $c++) {
                $actualRow = [int]($startRow + $r - 1)
                $actualCol = [int]($startCol + $c - 1)
                try {
                    $v = if ($isScalarUsed) { $values } else { $values[$r, $c] }
                    $formulaValue = $null
                    if ($null -ne $formulas) { $formulaValue = if ($isScalarUsed) { $formulas } else { $formulas[$r, $c] } }
                    $isFormulaCell = $false
                    if ($formulaValue -is [string]) {
                        $formulaText = [string]$formulaValue
                        $valueTextForFormulaCheck = if ($null -eq $v) { '' } else { [string]$v }
                        $isFormulaCell = ($formulaText.StartsWith('=') -and $formulaText -ne $valueTextForFormulaCheck)
                    } elseif ($null -eq $formulas) {
                        $probe = $null
                        try {
                            $probe = $Worksheet.Cells.Item($actualRow, $actualCol)
                            $isFormulaCell = -not (Test-YakuExcelComFalse -Value $probe.HasFormula)
                        } finally { Release-YakuComObject $probe }
                    }
                    if ($isFormulaCell) { $localFormulaSkipped++; continue }
                    if ($null -eq $v -or -not ($v -is [string])) { continue }
                    $text = [string]$v
                    if (-not (Test-YakuShouldTranslateCell -Text $text -Direction $Direction)) { continue }
                    $mergeInfo = $null
                    $isMergedAnchor = $false
                    if ($needsMergeCheck) {
                        $mergeInfo = Get-YakuExcelMergeCellInfo -Worksheet $Worksheet -Row $actualRow -Col $actualCol -MergeCache $mergeCache
                        if (-not [bool]$mergeInfo.IsWritable) { continue }
                        try { $isMergedAnchor = [bool]$mergeInfo.IsMerged } catch { $isMergedAnchor = $false }
                    }
                    $colLetter = [string]$columnLetters[$actualCol]
                    if ([string]::IsNullOrWhiteSpace($colLetter)) { $colLetter = ConvertTo-YakuColumnLetter -Column $actualCol }
                    $a1 = $colLetter + [string]$actualRow
                    $id = "cell|$sheetName|$a1"
                    $Blocks.Add((New-YakuTextBlock -Id $id -Text $text.Trim() -Location "$sheetName, $a1" -Meta ([pscustomobject]@{ Kind='cell'; Sheet=$sheetName; Row=$actualRow; Col=$actualCol; A1=$a1; Merged=$isMergedAnchor }))) | Out-Null
                    $localCells++
                } catch {
                    $location = ("{0}!R{1}C{2}" -f $sheetName, $actualRow, $actualCol)
                    Add-YakuWarning -Warnings $Warnings -Category 'cell-extract-skip' -Location $location -Message "セル抽出をスキップしました: $location - $($_.Exception.Message)"
                }
            }
        }
    } finally {
        try { Write-YakuLog "Excel text extraction formula mask. sheet=$sheetName formulaMask=$localFormulaSkipped" 'DEBUG' } catch {}
        $Stats['cells'] = [int]$Stats['cells'] + [int]$localCells
        $Stats['skipped_formula_cells'] = [int]$Stats['skipped_formula_cells'] + [int]$localFormulaSkipped
    }
}


function Get-YakuExcelSheetTextBlocks {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)]$Blocks,
        [Parameter(Mandatory=$true)]$Warnings,
        [Parameter(Mandatory=$true)][hashtable]$Stats
    )
    $sheetName = [string]$Worksheet.Name
    $used = $null
    $textRange = $null
    $areas = $null
    $localCells = 0
    $localFormulaSkipped = 0
    try {
        $used = $Worksheet.UsedRange
        $startCol = [int]$used.Column
        $colCount = [int]$used.Columns.Count
        $columnLetters = New-YakuColumnLetterCache -StartColumn $startCol -ColumnCount $colCount
        $localFormulaSkipped = Get-YakuExcelFormulaCellCount -UsedRange $used

        $specialStarted = Get-Date
        try {
            # xlCellTypeConstants = 2, xlTextValues = 2: COM側で「文字列定数セル」だけに絞る。
            $textRange = $used.SpecialCells(2, 2)
        } catch {
            # 文字列定数セルなしは正常系。UsedRange全走査には戻さない。
            return
        }

        $usedRows = [int]$used.Rows.Count
        $usedCols = [int]$used.Columns.Count
        $usedCellCount = [long]$usedRows * [long]$usedCols
        if ($usedCellCount -le 500000L) {
            try { Write-YakuLog "Excel text SpecialCells done. sheet=$sheetName areaCount=bulk elapsedMs=$([int](((Get-Date)-$specialStarted).TotalMilliseconds)) mode=bulk" 'DEBUG' } catch {}
            # V63: AreaごとのCOM往復を避け、UsedRange.Value2を一括取得してメモリ内走査する。
            Get-YakuExcelSheetTextBlocksFallback -Worksheet $Worksheet -UsedRange $used -Direction $Direction -Blocks $Blocks -Warnings $Warnings -Stats $Stats
            $localCells = 0
            $localFormulaSkipped = 0
            return
        }

        $areaCount = 0
        try {
            $areas = $textRange.Areas
            $areaCount = [int]$areas.Count
            try { Write-YakuLog "Excel text SpecialCells done. sheet=$sheetName areaCount=$areaCount elapsedMs=$([int](((Get-Date)-$specialStarted).TotalMilliseconds)) mode=areas" 'DEBUG' } catch {}
        } catch {
            $fallbackRows = 0; $fallbackCols = 0
            try { $fallbackRows = [int]$used.Rows.Count; $fallbackCols = [int]$used.Columns.Count } catch {}
            try { Write-YakuLog "SpecialCells text Areas failed on sheet '$sheetName'; falling back to used-range scan. rows=$fallbackRows cols=$fallbackCols error=$($_.Exception.Message)" 'WARN' } catch {}
            Get-YakuExcelSheetTextBlocksFallback -Worksheet $Worksheet -UsedRange $used -Direction $Direction -Blocks $Blocks -Warnings $Warnings -Stats $Stats
            $localFormulaSkipped = 0
            return
        }

        $mergeCache = @{}

        for ($a = 1; $a -le $areaCount; $a++) {
            $area = $null
            try {
                $area = $areas.Item($a)
                $aRow = [int]$area.Row
                $aCol = [int]$area.Column
                $aRows = [int]$area.Rows.Count
                $aCols = [int]$area.Columns.Count
                $areaCellCount = [long]$aRows * [long]$aCols
                $areaMergeState = $false
                try { $areaMergeState = $area.MergeCells } catch { $areaMergeState = $null }
                $needsMergeCheck = -not (($areaMergeState -is [bool]) -and ([bool]$areaMergeState -eq $false))
                if ($needsMergeCheck -and $areaCellCount -gt 2000L) {
                    $needsMergeCheck = $false
                    try { Write-YakuLog "Excel merge check simplified. sheet=$sheetName scope=area area=$a cells=$areaCellCount threshold=2000" 'DEBUG' } catch {}
                }
                $values = $area.Value2
                $isScalar = ($aRows -eq 1 -and $aCols -eq 1)
                for ($r = 1; $r -le $aRows; $r++) {
                    for ($c = 1; $c -le $aCols; $c++) {
                        $actualRow = [int]($aRow + $r - 1)
                        $actualCol = [int]($aCol + $c - 1)
                        try {
                            $text = if ($isScalar) { [string]$values } else { [string]$values[$r, $c] }
                            if ([string]::IsNullOrWhiteSpace($text)) { continue }
                            if (-not (Test-YakuShouldTranslateCell -Text $text -Direction $Direction)) { continue }
                            $mergeInfo = $null
                            $isMergedAnchor = $false
                            if ($needsMergeCheck) {
                                $mergeInfo = Get-YakuExcelMergeCellInfo -Worksheet $Worksheet -Row $actualRow -Col $actualCol -MergeCache $mergeCache
                                if (-not [bool]$mergeInfo.IsWritable) { continue }
                                try { $isMergedAnchor = [bool]$mergeInfo.IsMerged } catch { $isMergedAnchor = $false }
                            }
                            $colLetter = [string]$columnLetters[$actualCol]
                            if ([string]::IsNullOrWhiteSpace($colLetter)) { $colLetter = ConvertTo-YakuColumnLetter -Column $actualCol }
                            $a1 = $colLetter + [string]$actualRow
                            $id = "cell|$sheetName|$a1"
                            $Blocks.Add((New-YakuTextBlock -Id $id -Text $text.Trim() -Location "$sheetName, $a1" -Meta ([pscustomobject]@{ Kind='cell'; Sheet=$sheetName; Row=$actualRow; Col=$actualCol; A1=$a1; Merged=$isMergedAnchor }))) | Out-Null
                            $localCells++
                        } catch {
                            $location = ("{0}!R{1}C{2}" -f $sheetName, $actualRow, $actualCol)
                            Add-YakuWarning -Warnings $Warnings -Category 'cell-extract-skip' -Location $location -Message "セル抽出をスキップしました: $location - $($_.Exception.Message)"
                        }
                    }
                }
            } catch {
                $location = ("{0}!Area{1}" -f $sheetName, $a)
                Add-YakuWarning -Warnings $Warnings -Category 'cell-extract-skip' -Location $location -Message "セル抽出をスキップしました: $location - $($_.Exception.Message)"
            } finally {
                Release-YakuComObject $area
            }
        }
    } catch {
        Add-YakuWarning -Warnings $Warnings -Category 'cell-extract-sheet' -Location $sheetName -Message "セル抽出をスキップしました: $sheetName - $($_.Exception.Message)"
    } finally {
        $Stats['cells'] = [int]$Stats['cells'] + [int]$localCells
        $Stats['skipped_formula_cells'] = [int]$Stats['skipped_formula_cells'] + [int]$localFormulaSkipped
        Release-YakuComObject $areas
        Release-YakuComObject $textRange
        Release-YakuComObject $used
    }
}

function Get-YakuExcelShapeTextBlocks {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)]$Blocks,
        [Parameter(Mandatory=$true)]$Warnings,
        [Parameter(Mandatory=$true)][hashtable]$Stats
    )
    if (-not (Get-YakuSettingBool -Settings $Settings -Name 'translate_shapes' -Default $true)) { return }
    $sheetName = [string]$Worksheet.Name
    $shapeWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $shapeBefore = [int]$Stats['shapes']
    $shapes = $null
    try {
        $shapes = $Worksheet.Shapes
        $count = [int]$shapes.Count
        if ($count -le 0) { return }
        for ($i = 1; $i -le $count; $i++) {
            $shape = $null
            try {
                $shape = $shapes.Item($i)
                Get-YakuShapeTextBlocksRecursive -Shape $shape -SheetName $sheetName -IndexPath @($i) -Direction $Direction -Blocks $Blocks -Warnings $Warnings -Stats $Stats -Depth 0
            } catch {
                Add-YakuWarning -Warnings $Warnings -Category shape-extract-skip -Location "$sheetName / $i" -Detail $_.Exception.Message -Message "図形抽出をスキップしました: $sheetName / $i - $($_.Exception.Message)"
            } finally {
                Release-YakuComObject $shape
            }
        }
    } catch {
        Add-YakuWarning -Warnings $Warnings -Category shape-list-skip -Location $sheetName -Detail $_.Exception.Message -Message "図形一覧を取得できませんでした: $sheetName - $($_.Exception.Message)"
    } finally {
        try { Write-YakuLog "Excel shape extract done. sheet=$sheetName count=$([int]$Stats['shapes']-$shapeBefore) elapsedMs=$([int]$shapeWatch.ElapsedMilliseconds)" 'DEBUG' } catch {}
        Release-YakuComObject $shapes
    }
}

function Get-YakuExcelChartTextBlocks {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)]$Blocks,
        [Parameter(Mandatory=$true)]$Warnings,
        [Parameter(Mandatory=$true)][hashtable]$Stats
    )
    if (-not (Get-YakuSettingBool -Settings $Settings -Name 'translate_charts' -Default $true)) { return }
    $sheetName = [string]$Worksheet.Name
    $chartWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $chartBefore = [int]$Stats['charts']
    $chartObjects = $null
    try {
        $chartObjects = $Worksheet.ChartObjects()
        $count = [int]$chartObjects.Count
        for ($i = 1; $i -le $count; $i++) {
            $chartObj = $null
            $chart = $null
            try {
                $chartObj = $chartObjects.Item($i)
                $chart = $chartObj.Chart
                if ($chart.HasTitle) {
                    $titleText = [string]$chart.ChartTitle.Text
                    if (Test-YakuShouldTranslateCell -Text $titleText -Direction $Direction) {
                        $id = "chart|$sheetName|$i|title"
                        $Blocks.Add((New-YakuTextBlock -Id $id -Text $titleText.Trim() -Location "$sheetName, Chart $i Title" -Meta ([pscustomobject]@{ Kind='chart'; Sheet=$sheetName; ChartIndex=$i; Part='title' }))) | Out-Null
                        $Stats['charts'] = [int]$Stats['charts'] + 1
                    }
                }
                foreach ($axisSpec in @(@{Type=1;Part='axis_category';Label='Category Axis'}, @{Type=2;Part='axis_value';Label='Value Axis'})) {
                    $axis = $null
                    try {
                        $axis = $chart.Axes([int]$axisSpec.Type)
                        if ($axis -and $axis.HasTitle) {
                            $axisText = [string]$axis.AxisTitle.Text
                            if (Test-YakuShouldTranslateCell -Text $axisText -Direction $Direction) {
                                $id = "chart|$sheetName|$i|$($axisSpec.Part)"
                                $Blocks.Add((New-YakuTextBlock -Id $id -Text $axisText.Trim() -Location "$sheetName, Chart $i $($axisSpec.Label)" -Meta ([pscustomobject]@{ Kind='chart'; Sheet=$sheetName; ChartIndex=$i; Part=[string]$axisSpec.Part }))) | Out-Null
                                $Stats['charts'] = [int]$Stats['charts'] + 1
                            }
                        }
                    } catch {} finally { Release-YakuComObject $axis }
                }
            } catch {
                Add-YakuWarning -Warnings $Warnings -Category chart-extract-skip -Location "$sheetName / Chart $i" -Detail $_.Exception.Message -Message "グラフ抽出をスキップしました: $sheetName / Chart $i - $($_.Exception.Message)"
            } finally {
                Release-YakuComObject $chart
                Release-YakuComObject $chartObj
            }
        }
    } catch {
        # ChartObjects may throw when the sheet has none; that is normal.
    } finally {
        try { Write-YakuLog "Excel chart extract done. sheet=$sheetName count=$([int]$Stats['charts']-$chartBefore) elapsedMs=$([int]$chartWatch.ElapsedMilliseconds)" 'DEBUG' } catch {}
        Release-YakuComObject $chartObjects
    }
}

function Get-YakuSelectedSheetLookup {
    param([AllowNull()][string[]]$Sheets)
    $lookup = @{}
    foreach ($s in @($Sheets)) {
        if ([string]::IsNullOrWhiteSpace([string]$s)) { continue }
        $lookup[[string]$s] = $true
    }
    return $lookup
}

function Get-YakuExcelTextBlocks {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()][string[]]$Sheets,
        [AllowNull()][scriptblock]$OnProgress = $null,
        [AllowNull()]$ProgressState = $null
    )
    $ctx = $null
    $excel = $null
    $workbook = $null
    $blocks = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[object]
    $actualNames = New-Object System.Collections.Generic.List[string]
    Add-YakuInputReadOnlyNotice -Path $Path -Warnings $warnings
    $stats = New-YakuStatsObject
    $selected = Get-YakuSelectedSheetLookup -Sheets $Sheets
    $selectedDone = 0
    $selectedTotal = 0
    try {
        $ctx = New-YakuExcelApplication
        $excel = $ctx.Application
        $workbook = Open-YakuWorkbookWithManualCalc -Context $ctx -Path $Path -ReadOnly $true
        $sheetCount = [int]$workbook.Worksheets.Count
        $selectedTotal = if ($selected.Count -gt 0) { [int]$selected.Count } else { $sheetCount }
        $extractWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $extractTimeoutSeconds = Get-YakuSettingInt -Settings $Settings -Name 'extract_timeout_seconds' -Default 300
        if ($extractTimeoutSeconds -lt 60) { $extractTimeoutSeconds = 60 }
        for ($i = 1; $i -le $sheetCount; $i++) {
            Assert-YakuJobNotCancelled -ProgressState $ProgressState
            if ($extractWatch.Elapsed.TotalSeconds -ge $extractTimeoutSeconds) {
                Add-YakuWarning -Warnings $warnings -Category 'extract-timeout' -Location ([System.IO.Path]::GetFileName($Path)) -Message "抽出タイムアウト: $($i-1)/$sheetCount シートまで抽出済み。残りはスキップしました。"
                try { Write-YakuLog "Excel extract timeout. completed=$($i-1)/$sheetCount elapsedSeconds=$([int]$extractWatch.Elapsed.TotalSeconds)" 'WARN' } catch {}
                break
            }
            $ws = $null
            try {
                $ws = $workbook.Worksheets.Item($i)
                $sheetName = [string]$ws.Name
                $sheetCodeName = ''
                try { $sheetCodeName = [string]$ws.CodeName } catch { $sheetCodeName = '' }
                $actualNames.Add($sheetName) | Out-Null
                if ($selected.Count -gt 0 -and -not $selected.ContainsKey($sheetName)) { continue }
                $selectedDone++
                $usedForLog = $null; $usedRows = 0; $usedCols = 0
                try { $usedForLog = $ws.UsedRange; $usedRows = [int]$usedForLog.Rows.Count; $usedCols = [int]$usedForLog.Columns.Count } finally { Release-YakuComObject $usedForLog }
                $sheetWatch = [System.Diagnostics.Stopwatch]::StartNew()
                $cellsBefore = [int]$stats['cells']; $shapesBefore = [int]$stats['shapes']; $chartsBefore = [int]$stats['charts']
                $blocksBefore = $blocks.Count
                try { Write-YakuLog "Excel extract sheet start. sheet=$i/$sheetCount name=$sheetName usedRows=$usedRows usedCols=$usedCols" 'INFO' } catch {}
                Get-YakuExcelSheetTextBlocks -Worksheet $ws -Direction $Direction -Settings $Settings -Blocks $blocks -Warnings $warnings -Stats $stats
                Get-YakuExcelShapeTextBlocks -Worksheet $ws -Direction $Direction -Settings $Settings -Blocks $blocks -Warnings $warnings -Stats $stats
                Get-YakuExcelChartTextBlocks -Worksheet $ws -Direction $Direction -Settings $Settings -Blocks $blocks -Warnings $warnings -Stats $stats
                # Worksheet.CodeName は表示名を変えても維持される。取り込み時と
                # 出力時のブロックへ持たせ、別シートを「改名」と推測しない。
                for ($bi = $blocksBefore; $bi -lt $blocks.Count; $bi++) {
                    try { $blocks[$bi].Meta | Add-Member -NotePropertyName 'SheetCodeName' -NotePropertyValue $sheetCodeName -Force } catch {}
                }
                $sheetCells = [int]$stats['cells'] - $cellsBefore; $sheetShapes = [int]$stats['shapes'] - $shapesBefore; $sheetCharts = [int]$stats['charts'] - $chartsBefore
                try { Write-YakuLog "Excel extract sheet done. sheet=$i/$sheetCount name=$sheetName cells=$sheetCells shapes=$sheetShapes charts=$sheetCharts elapsedMs=$([int]$sheetWatch.ElapsedMilliseconds)" 'INFO' } catch {}
                if ($null -ne $OnProgress) { & $OnProgress ([pscustomobject]@{ SheetIndex=$i; SheetTotal=$sheetCount; SelectedIndex=$selectedDone; SelectedTotal=$selectedTotal; SheetName=$sheetName; Cells=$sheetCells }) }
            } finally {
                Release-YakuComObject $ws
            }
        }
    } finally {
        Close-YakuExcelObjects -Workbook $workbook -Application $excel -Save:$false -OldCalculation $ctx.OldCalculation -OldCalculateBeforeSave $ctx.OldCalculateBeforeSave -OldScreenUpdating $ctx.OldScreenUpdating -OldEnableEvents $ctx.OldEnableEvents -OldDisplayStatusBar $ctx.OldDisplayStatusBar -OldFormatConditionsCalc $ctx.OldFormatConditionsCalc -OldBackgroundChecking $ctx.OldBackgroundChecking
    }
    $unmatchedSheets = @()
    if ($selected.Count -gt 0) {
        $actualLookup = @{}
        foreach ($n in @($actualNames.ToArray())) { $actualLookup[[string]$n] = $true }
        $unmatchedSheets = @($selected.Keys | Where-Object { -not $actualLookup.ContainsKey([string]$_) })
        foreach ($miss in $unmatchedSheets) {
            Add-YakuWarning -Warnings $warnings -Category 'sheet-not-found' -Location ([string]$miss) -Message "指定シートが見つかりません: $miss"
        }
    }
    $stats['warnings'] = $warnings.Count
    return [pscustomobject]@{ Kind='excel'; Blocks=@($blocks.ToArray()); Stats=[pscustomobject]$stats; Warnings=@($warnings.ToArray()); UnmatchedSheets=@($unmatchedSheets); ActualSheetNames=@($actualNames.ToArray()); SelectedSheetCount=[int]$selected.Count }
}

function Get-YakuTextEncodingForCsv {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return New-Object System.Text.UTF8Encoding -ArgumentList $true }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
    if ($bytes.Length -ge 4) {
        $evenNul = 0; $oddNul = 0; $sample = [Math]::Min($bytes.Length, 4096)
        for ($i = 0; $i -lt $sample; $i++) { if ($bytes[$i] -eq 0) { if (($i % 2) -eq 0) { $evenNul++ } else { $oddNul++ } } }
        if ($oddNul -gt ($sample / 10)) { return New-Object System.Text.UnicodeEncoding -ArgumentList @($false, $false, $true) }
        if ($evenNul -gt ($sample / 10)) { return New-Object System.Text.UnicodeEncoding -ArgumentList @($true, $false, $true) }
    }
    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        [void]$utf8Strict.GetString($bytes)
        return New-Object System.Text.UTF8Encoding -ArgumentList $false
    } catch {
        return [System.Text.Encoding]::GetEncoding(932)
    }
}

function Read-YakuCsvRows {
    param([Parameter(Mandatory=$true)][string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop | Out-Null
    $encoding = Get-YakuTextEncodingForCsv -Path $Path
    $parser = $null
    $rows = New-Object System.Collections.Generic.List[object]
    $blankPhysicalLines = New-Object System.Collections.Generic.List[int]
    try {
        $rawText = [System.IO.File]::ReadAllText($Path, $encoding)
        $recordIndex = 0
        $inQuotedRecord = $false
        foreach ($physicalLine in @($rawText.Replace("`r`n","`n").Replace("`r","`n") -split "`n")) {
            if (-not $inQuotedRecord -and $physicalLine.Length -eq 0) {
                $blankPhysicalLines.Add($recordIndex) | Out-Null
                $recordIndex++
                continue
            }
            $quoteProbe = $physicalLine.Replace('""','')
            $quoteCount = ([regex]::Matches($quoteProbe, '"')).Count
            if (($quoteCount % 2) -eq 1) { $inQuotedRecord = -not $inQuotedRecord }
            if (-not $inQuotedRecord) { $recordIndex++ }
        }
        if ($rawText.EndsWith("`n") -or $rawText.EndsWith("`r")) { if ($blankPhysicalLines.Count -gt 0) { $blankPhysicalLines.RemoveAt($blankPhysicalLines.Count - 1) } }
    } catch {}
    try {
        $parser = New-Object -TypeName Microsoft.VisualBasic.FileIO.TextFieldParser -ArgumentList @($Path, $encoding)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        while (-not $parser.EndOfData) {
            try { $fields = $parser.ReadFields() }
            catch [Microsoft.VisualBasic.FileIO.MalformedLineException] { throw "CSV_MALFORMED_LINE: 行 $($parser.ErrorLineNumber) を解析できません。$($_.Exception.Message)" }
            if ($null -eq $fields) { $fields = @() }
            $rows.Add([string[]]$fields) | Out-Null
        }
    } finally {
        if ($null -ne $parser) { try { $parser.Close() } catch {}; try { $parser.Dispose() } catch {} }
    }
    foreach ($blankIndex in @($blankPhysicalLines.ToArray())) {
        $insertAt = [Math]::Min([int]$blankIndex, $rows.Count)
        $rows.Insert($insertAt, [string[]]@(''))
    }
    return ,$rows
}

function ConvertTo-YakuFileCsvField {
    param([AllowNull()][string]$Value)
    $s = [string]$Value
    if ($s.Contains(',') -or $s.Contains('"') -or $s.Contains("`r") -or $s.Contains("`n")) {
        return '"' + ($s -replace '"', '""') + '"'
    }
    return $s
}

function Write-YakuCsvRows {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Rows,
        [AllowNull()][string]$SourcePath = ''
    )
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Clear-YakuOutputReadOnlyAttribute -Path $Path | Out-Null }
    $encoding = if (-not [string]::IsNullOrWhiteSpace($SourcePath)) { Get-YakuTextEncodingForCsv -Path $SourcePath } else { New-Object System.Text.UTF8Encoding -ArgumentList $true }
    $writer = New-Object System.IO.StreamWriter -ArgumentList @($Path, $false, $encoding)
    try {
        foreach ($row in $Rows) {
            $fields = @($row | ForEach-Object { ConvertTo-YakuFileCsvField -Value ([string]$_) })
            $writer.WriteLine(($fields -join ','))
        }
    } finally {
        $writer.Close()
        $writer.Dispose()
    }
}

function Get-YakuCsvTextBlocks {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings
    )
    $rows = Read-YakuCsvRows -Path $Path
    $blocks = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[object]
    Add-YakuInputReadOnlyNotice -Path $Path -Warnings $warnings
    $stats = New-YakuStatsObject
    $translateHeader = Get-YakuSettingBool -Settings $Settings -Name 'csv_translate_header' -Default $true
    for ($r = 0; $r -lt $rows.Count; $r++) {
        if ($r -eq 0 -and -not $translateHeader) { continue }
        $row = [string[]]$rows[$r]
        for ($c = 0; $c -lt $row.Count; $c++) {
            $text = [string]$row[$c]
            if (-not (Test-YakuShouldTranslateCell -Text $text -Direction $Direction)) { continue }
            $id = "cell|csv|R$($r + 1)C$($c + 1)"
            $blocks.Add((New-YakuTextBlock -Id $id -Text $text.Trim() -Location "CSV, R$($r + 1)C$($c + 1)" -Meta ([pscustomobject]@{ Kind='csv-cell'; Row=($r + 1); Col=($c + 1) }))) | Out-Null
            $stats['cells'] = [int]$stats['cells'] + 1
        }
    }
    return [pscustomobject]@{ Kind='csv'; Blocks=@($blocks.ToArray()); Stats=[pscustomobject]$stats; Warnings=@($warnings.ToArray()); Rows=$rows }
}

function Get-YakuFileTextBlocks {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ValidateSet('to_en','to_jp')][string]$Direction,
        [Parameter(Mandatory=$true)]$Settings,
        [AllowNull()][string[]]$Sheets,
        [AllowNull()][scriptblock]$OnProgress = $null,
        [AllowNull()]$ProgressState = $null
    )
    $kind = Get-YakuSupportedFileKind -Path $Path
    if ($kind -eq 'excel') { return Get-YakuExcelTextBlocks -Path $Path -Direction $Direction -Settings $Settings -Sheets $Sheets -OnProgress $OnProgress -ProgressState $ProgressState }
    if ($kind -eq 'csv') { return Get-YakuCsvTextBlocks -Path $Path -Direction $Direction -Settings $Settings }
    throw '対応しているファイル形式は .xlsx / .xlsm / .csv です。'
}

function Get-YakuShapeByIndexPath {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][int[]]$IndexPath
    )
    if ($IndexPath.Count -lt 1) { return $null }
    $shape = $Worksheet.Shapes.Item([int]$IndexPath[0])
    for ($i = 1; $i -lt $IndexPath.Count; $i++) {
        $shape = $shape.GroupItems.Item([int]$IndexPath[$i])
    }
    return $shape
}

function Get-YakuOutputFontName {
    param([AllowNull()]$Settings)
    $font = Get-YakuSettingString -Settings $Settings -Name 'output_font_name' -Default 'Arial'
    if ($null -eq $font) { return '' }
    return ([string]$font).Trim()
}

function Set-YakuComTextFontName {
    param(
        [AllowNull()]$TextRange,
        [AllowNull()][string]$FontName
    )
    if ([string]::IsNullOrWhiteSpace([string]$FontName) -or $null -eq $TextRange) { return }
    try { $TextRange.Font.Name = [string]$FontName } catch {}
}

function Set-YakuChartTextFontName {
    param(
        [AllowNull()]$TitleObject,
        [AllowNull()][string]$FontName
    )
    if ([string]::IsNullOrWhiteSpace([string]$FontName) -or $null -eq $TitleObject) { return }
    $tf = $null
    $tr = $null
    try {
        $tf = $TitleObject.Format.TextFrame2
        $tr = $tf.TextRange
        $tr.Font.Name = [string]$FontName
        return
    } catch {
        try { $TitleObject.Font.Name = [string]$FontName } catch {}
    } finally {
        Release-YakuComObject $tr
        Release-YakuComObject $tf
    }
}

function Get-YakuExceptionDetailObject {
    param([AllowNull()]$ErrorRecord)
    $typeName = ''
    $message = ''
    $stackTop = ''
    try { if ($ErrorRecord -and $ErrorRecord.Exception) { $typeName = $ErrorRecord.Exception.GetType().FullName } } catch {}
    try { if ($ErrorRecord -and $ErrorRecord.Exception) { $message = [string]$ErrorRecord.Exception.Message } } catch {}
    try {
        $stackText = [string]$ErrorRecord.ScriptStackTrace
        if (-not [string]::IsNullOrWhiteSpace($stackText)) {
            $stackText = $stackText.Replace("`r`n", "`n").Replace("`r", "`n")
            $stackTop = @($stackText -split "`n")[0]
        }
    } catch {}
    return [pscustomobject]@{ ExceptionType=$typeName; Message=$message; StackTop=$stackTop }
}

function Get-YakuExcelRangeAddress {
    param(
        [Parameter(Mandatory=$true)][int]$StartRow,
        [Parameter(Mandatory=$true)][int]$StartCol,
        [Parameter(Mandatory=$true)][int]$EndRow,
        [Parameter(Mandatory=$true)][int]$EndCol
    )
    $startA1 = (ConvertTo-YakuColumnLetter -Column $StartCol) + [string]$StartRow
    $endA1 = (ConvertTo-YakuColumnLetter -Column $EndCol) + [string]$EndRow
    if ($startA1 -eq $endA1) { return $startA1 }
    return ($startA1 + ':' + $endA1)
}


function Test-YakuExcelWriteRangeHasNoFormula {
    param([Parameter(Mandatory=$true)]$Range)
    $hasFormula = $null
    try { $hasFormula = $Range.HasFormula } catch { return $false }
    return (Test-YakuExcelComFalse -Value $hasFormula)
}

function Add-YakuFormulaWriteBlockedWarning {
    param([Parameter(Mandatory=$true)]$Warnings, [string]$Location, [AllowNull()][string]$Translation)
    $summary = [string]$Translation
    if ($summary.Length -gt 80) { $summary = $summary.Substring(0, 80) + '...' }
    Add-YakuWarning -Warnings $Warnings -Category 'formula-cell-write-blocked' -Location $Location -Message "数式セルへの訳文書込を遮断しました。location=$Location translation=$summary"
    try { Write-YakuLog "Formula cell write blocked. location=$Location translation=$summary" 'WARN' } catch {}
}

# V91.14: PS COM adapter may fail to marshal a two-dimensional Object[,] through
# a direct property PUT. Try direct assignment first, then cache a reflection-based
# SetProperty path for the remainder of the worker process. Formula safety checks are
# performed by callers before this helper is invoked.
$script:YakuExcelArrayWriteMode = ''   # '' | 'direct' | 'reflection'
$script:YakuExcelFormulaArrayWriteMode = '' # '' | 'direct' | 'reflection'

function Set-YakuExcelRangeArrayValue2 {
    param(
        [Parameter(Mandatory=$true)]$Range,
        [Parameter(Mandatory=$true)]$Values2D
    )
    if (-not ($Values2D -is [System.Array]) -or $Values2D.Rank -ne 2) {
        throw 'Value2 array write requires a two-dimensional array.'
    }
    if ($script:YakuExcelArrayWriteMode -ne 'reflection') {
        try {
            $Range.Value2 = $Values2D
            if ($script:YakuExcelArrayWriteMode -eq '') {
                $script:YakuExcelArrayWriteMode = 'direct'
                try { Write-YakuLog "Excel array write mode selected. property=Value2 mode=direct" 'DEBUG' } catch {}
            }
            return
        } catch {
            $isCast = ($_.Exception -is [System.InvalidCastException]) -or
                      ($_.Exception.InnerException -is [System.InvalidCastException])
            if (-not $isCast) { throw }
            try { Write-YakuLog "Excel array write direct set failed; switching to reflection. property=Value2 errorType=$($_.Exception.GetType().Name)" 'DEBUG' } catch {}
        }
    }
    try {
        [void]$Range.GetType().InvokeMember(
            'Value2',
            [System.Reflection.BindingFlags]::SetProperty,
            $null, $Range, @(,$Values2D))
    } catch {
        try { Write-YakuLog "Excel array write reflection set failed. property=Value2 errorType=$($_.Exception.GetType().Name)" 'DEBUG' } catch {}
        throw
    }
    if ($script:YakuExcelArrayWriteMode -ne 'reflection') {
        $script:YakuExcelArrayWriteMode = 'reflection'
        try { Write-YakuLog "Excel array write mode selected. property=Value2 mode=reflection" 'DEBUG' } catch {}
    }
}

function Set-YakuExcelRangeArrayFormula {
    param(
        [Parameter(Mandatory=$true)]$Range,
        [Parameter(Mandatory=$true)]$Values2D
    )
    if (-not ($Values2D -is [System.Array]) -or $Values2D.Rank -ne 2) {
        throw 'Formula array write requires a two-dimensional array.'
    }
    if ($script:YakuExcelFormulaArrayWriteMode -ne 'reflection') {
        try {
            $Range.Formula = $Values2D
            if ($script:YakuExcelFormulaArrayWriteMode -eq '') {
                $script:YakuExcelFormulaArrayWriteMode = 'direct'
                try { Write-YakuLog "Excel array write mode selected. property=Formula mode=direct" 'DEBUG' } catch {}
            }
            return
        } catch {
            $isCast = ($_.Exception -is [System.InvalidCastException]) -or
                      ($_.Exception.InnerException -is [System.InvalidCastException])
            if (-not $isCast) { throw }
            try { Write-YakuLog "Excel array write direct set failed; switching to reflection. property=Formula errorType=$($_.Exception.GetType().Name)" 'DEBUG' } catch {}
        }
    }
    try {
        [void]$Range.GetType().InvokeMember(
            'Formula',
            [System.Reflection.BindingFlags]::SetProperty,
            $null, $Range, @(,$Values2D))
    } catch {
        try { Write-YakuLog "Excel array write reflection set failed. property=Formula errorType=$($_.Exception.GetType().Name)" 'DEBUG' } catch {}
        throw
    }
    if ($script:YakuExcelFormulaArrayWriteMode -ne 'reflection') {
        $script:YakuExcelFormulaArrayWriteMode = 'reflection'
        try { Write-YakuLog "Excel array write mode selected. property=Formula mode=reflection" 'DEBUG' } catch {}
    }
}

function Add-YakuExcelCellSingleValue {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [int]$Row,
        [int]$Col,
        [AllowNull()][string]$Value,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = ''
    )
    $cell = $null
    $address = ''
    $location = ''
    try {
        if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { try { $SheetName = [string]$Worksheet.Name } catch { $SheetName = '' } }
        $address = Get-YakuExcelRangeAddress -StartRow $Row -StartCol $Col -EndRow $Row -EndCol $Col
        $location = if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { $address } else { ([string]$SheetName) + '!' + $address }
        $cell = $Worksheet.Cells.Item($Row, $Col)
        $valueText = [string]$Value
        if (-not (Test-YakuExcelWriteRangeHasNoFormula -Range $cell)) {
            Add-YakuFormulaWriteBlockedWarning -Warnings $Warnings -Location $location -Translation $valueText
            return 0
        }
        if (Test-YakuExcelCoercionRiskString -Value $valueText) {
            $cell.Formula = ("'" + $valueText)
        } else {
            $cell.Value2 = $valueText
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) { try { $cell.Font.Name = [string]$OutputFontName } catch {} }
        return 1
    } catch {
        if ([string]::IsNullOrWhiteSpace($location)) { $location = "R${Row}C${Col}" }
        $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
        $typeName = [string]$diag.ExceptionType
        if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
        Add-YakuWarning -Warnings $Warnings -Category 'writeback-cell' -Location $location -Detail $diag -Message "セル単位書き戻しをスキップしました: $location - ${typeName}: $($_.Exception.Message)"
        return 0
    } finally {
        Release-YakuComObject $cell
    }
}

# V37: row-run fallback aborts after three consecutive cell failures (category: writeback-row-abort).
function Add-YakuExcelCellRowRunFallback {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [int]$Row,
        [int]$StartCol,
        [Parameter(Mandatory=$true)][string[]]$Values,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = ''
    )
    $count = [int]$Values.Count
    if ($count -le 0) { return 0 }
    if ($count -eq 1) {
        return (Add-YakuExcelCellSingleValue -Worksheet $Worksheet -Row $Row -Col $StartCol -Value ([string]$Values[0]) -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName)
    }
    $range = $null
    $address = ''
    $location = ''
    try {
        if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { try { $SheetName = [string]$Worksheet.Name } catch { $SheetName = '' } }
        $endCol = [int]($StartCol + $count - 1)
        $address = Get-YakuExcelRangeAddress -StartRow $Row -StartCol $StartCol -EndRow $Row -EndCol $endCol
        $location = if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { $address } else { ([string]$SheetName) + '!' + $address }
        $range = $Worksheet.Range($address)
        if (-not (Test-YakuExcelWriteRangeHasNoFormula -Range $range)) {
            $guardWritten = 0
            for ($guardIndex = 0; $guardIndex -lt $count; $guardIndex++) {
                $guardWritten += [int](Add-YakuExcelCellSingleValue -Worksheet $Worksheet -Row $Row -Col ([int]($StartCol + $guardIndex)) -Value ([string]$Values[$guardIndex]) -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName)
            }
            return [int]$guardWritten
        }
        $arr = [System.Array]::CreateInstance([object], 1, $count)
        for ($j = 0; $j -lt $count; $j++) { $arr.SetValue([string]$Values[$j], 0, $j) }
        Set-YakuExcelRangeArrayValue2 -Range $range -Values2D $arr
        if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) { try { $range.Font.Name = [string]$OutputFontName } catch {} }
        return $count
    } catch {
        try { Write-YakuLog "Excel row-run write failed; falling back to cells. location=$location count=$count errorType=$($_.Exception.GetType().Name) error=$($_.Exception.Message)" 'DEBUG' } catch {}
        $written = 0
        $consecutiveFailedCells = 0
        for ($j = 0; $j -lt $count; $j++) {
            $cellWritten = [int](Add-YakuExcelCellSingleValue -Worksheet $Worksheet -Row $Row -Col ([int]($StartCol + $j)) -Value ([string]$Values[$j]) -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName)
            $written += $cellWritten
            if ($cellWritten -le 0) { $consecutiveFailedCells++ } else { $consecutiveFailedCells = 0 }
            if ($consecutiveFailedCells -ge 3) {
                $remaining = [int]($count - $j - 1)
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-row-abort' -Location $location -Message "行フォールバックで連続セル失敗が続いたため残り $remaining セルの書き戻しを中断しました（系統的な失敗の可能性）。"
                try { Write-YakuLog "Row-run fallback aborted after consecutive cell failures. location=$location remainingCells=$remaining" 'WARN' } catch {}
                break
            }
        }
        return [int]$written
    } finally {
        Release-YakuComObject $range
    }
}

function Invoke-YakuExcelCellRectangleFallback {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)]$Rectangle,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = ''
    )
    $startRow = [int]$Rectangle.StartRow
    $endRow = [int]$Rectangle.EndRow
    $startCol = [int]$Rectangle.StartCol
    $endCol = [int]$Rectangle.EndCol
    $rowCount = [int]($endRow - $startRow + 1)
    $colCount = [int]($endCol - $startCol + 1)
    if ($rowCount -le 0 -or $colCount -le 0) { return 0 }
    $rectRows = @($Rectangle.Rows.ToArray())
    if ($rectRows.Count -ne $rowCount) { throw "矩形行数が一致しません。Expected=$rowCount Actual=$($rectRows.Count)" }
    $written = 0
    $consecutiveFailedRows = 0
    for ($i = 0; $i -lt $rowCount; $i++) {
        $rowValues = [string[]]@($rectRows[$i])
        if ($rowValues.Count -ne $colCount) { throw "矩形列数が一致しません。RowOffset=$i Expected=$colCount Actual=$($rowValues.Count)" }
        $rowWritten = [int](Add-YakuExcelCellRowRunFallback -Worksheet $Worksheet -Row ([int]($startRow + $i)) -StartCol $startCol -Values $rowValues -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName)
        $written += $rowWritten
        if ($rowWritten -le 0) { $consecutiveFailedRows++ } else { $consecutiveFailedRows = 0 }
        if ($consecutiveFailedRows -ge 5) {
            $remaining = [int]($rowCount - $i - 1)
            Add-YakuWarning -Warnings $Warnings -Category 'writeback-rect-abort' -Location $SheetName -Message "矩形フォールバックで連続失敗が続いたため残り $remaining 行の書き戻しを中断しました（系統的な失敗の可能性）。"
            try { Write-YakuLog "Rectangle fallback aborted after consecutive failures. sheet=$SheetName remainingRows=$remaining" 'WARN' } catch {}
            break
        }
    }
    return [int]$written
}

function Add-YakuExcelCellRun {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][int]$Row,
        [Parameter(Mandatory=$true)][object[]]$Run,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings
    )
    if ($Run.Count -le 0) { return 0 }
    $values = New-Object System.Collections.Generic.List[string]
    $sorted = @($Run | Sort-Object Col)
    foreach ($item in $sorted) { $values.Add([string]$item.Translation) | Out-Null }
    $runObject = [pscustomobject]@{ Row=[int]$Row; StartCol=[int]$sorted[0].Col; EndCol=[int]$sorted[$sorted.Count - 1].Col; Values=[string[]]@($values.ToArray()) }
    $rect = (Merge-YakuCellRunsToRects -Runs @($runObject))[0]
    return (Add-YakuExcelCellRectangle -Worksheet $Worksheet -Rectangle $rect -OutputFontName $OutputFontName -Warnings $Warnings)
}

function Merge-YakuCellRunsToRects {
    # 入力: 横Runの配列。各Run = @{ Row=[int]; StartCol=[int]; EndCol=[int]; Values=[string[]] }
    # 出力: 矩形の配列。各Rect = @{ StartRow; EndRow; StartCol; EndCol; Rows=List[string[]] }
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Runs)
    $rects = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Runs -or $Runs.Count -eq 0) { return @() }
    $sorted = @($Runs | Sort-Object @{Expression='StartCol'}, @{Expression='EndCol'}, @{Expression='Row'})
    $current = $null
    foreach ($run in $sorted) {
        if ($null -eq $run) { continue }
        $values = [string[]]@($run.Values)
        if ($null -ne $current -and
            [int]$run.StartCol -eq [int]$current.StartCol -and
            [int]$run.EndCol  -eq [int]$current.EndCol  -and
            [int]$run.Row     -eq ([int]$current.EndRow + 1)) {
            $current.EndRow = [int]$run.Row
            $current.Rows.Add($values) | Out-Null
        } else {
            if ($null -ne $current) { $rects.Add($current) | Out-Null }
            $rows = New-Object System.Collections.Generic.List[object]
            $rows.Add($values) | Out-Null
            $current = [pscustomobject]@{ StartRow=[int]$run.Row; EndRow=[int]$run.Row; StartCol=[int]$run.StartCol; EndCol=[int]$run.EndCol; Rows=$rows }
        }
    }
    if ($null -ne $current) { $rects.Add($current) | Out-Null }
    return @($rects.ToArray())
}

function Add-YakuExcelMetricElapsed {
    param(
        [AllowNull()][hashtable]$Metrics,
        [Parameter(Mandatory=$true)][string]$Key,
        [AllowNull()]$Stopwatch
    )
    if ($null -eq $Metrics -or $null -eq $Stopwatch) { return }
    try {
        if (-not $Metrics.ContainsKey($Key)) { $Metrics[$Key] = 0.0 }
        $Metrics[$Key] = [double]$Metrics[$Key] + [double]$Stopwatch.Elapsed.TotalMilliseconds
    } catch {}
}


function Test-YakuExcelComFalse {
    param([AllowNull()]$Value)
    try {
        if ($Value -is [bool]) { return ([bool]$Value -eq $false) }
        if ($null -eq $Value) { return $false }
        if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long]) { return ([int64]$Value -eq 0) }
        $s = ([string]$Value).Trim()
        return ($s -eq 'False' -or $s -eq '0')
    } catch { return $false }
}

function Test-YakuExcelFormulaPatchLeadingToken {
    param([AllowNull()][string]$Value)
    try {
        if ($null -eq $Value) { return $false }
        $s = ([string]$Value).TrimStart()
        if ($s.Length -le 0) { return $false }
        $first = $s.Substring(0, 1)
        return ($first -eq '=' -or $first -eq '+' -or $first -eq '-' -or $first -eq '@')
    } catch { return $false }
}

function Test-YakuExcelFormulaPatchNumericString {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $number = 0.0
    $styles = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
    try {
        if ([double]::TryParse([string]$Value, $styles, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$number)) { return $true }
    } catch {}
    try {
        if ([double]::TryParse([string]$Value, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $true }
    } catch {}
    return $false
}

function Test-YakuExcelFormulaPatchRiskyConstantString {
    param([AllowNull()][string]$Value)
    if (-not (Test-YakuExcelFormulaPatchLeadingToken -Value $Value)) { return $false }
    return (-not (Test-YakuExcelFormulaPatchNumericString -Value $Value))
}


function Test-YakuExcelCoercionRiskString {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty([string]$Value)) { return $false }
    $s = ([string]$Value)
    # 先頭トークン(数式化リスク)
    if (Test-YakuExcelFormulaPatchLeadingToken -Value $s) { return $true }
    $t = $s.Trim()
    if ($t.Length -le 0) { return $false }
    # 数値としてパース可能なテキスト(0123 → 123 のリスク)
    if (Test-YakuExcelFormulaPatchNumericString -Value $t) { return $true }
    # 日付/時刻としてパース可能なテキスト(1-2 → 日付 のリスク)
    $dt = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::None
    try { if ([datetime]::TryParse($t, [System.Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$dt)) { return $true } } catch {}
    try { if ([datetime]::TryParse($t, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) { return $true } } catch {}
    # パーセント・通貨風 (末尾% / 先頭通貨記号 + 数値)
    if ($t -match '^[¥$€]?[\d,\.]+%?$') { return $true }
    return $false
}

function Test-YakuExcelFormulaPatchSafeConstantValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [double]) { return $true }
    if ($Value -is [string]) { return $true }
    if ($Value -is [bool]) { return $true }
    return $false
}

function Test-YakuExcelFormulaPatchCvErrValue {
    param([AllowNull()]$Value)
    try {
        if ($null -eq $Value) { return $false }
        # COM interop の Value2 で観測される CVErr は負の System.Int32。
        # 正の整数は通常値の可能性を残し、unknown-cverr ではなく従来ガード扱いにする。
        if ($Value -is [int]) { return ([int]$Value -lt 0) }
        $typeName = ''
        try { $typeName = [string]$Value.GetType().FullName } catch { $typeName = '' }
        if ($typeName -ne 'System.Int32') { return $false }
        return ([int]$Value -lt 0)
    } catch { return $false }
}

function Get-YakuExcelCvErrLiteral {
    param([AllowNull()]$Value)
    if (-not (Test-YakuExcelFormulaPatchCvErrValue -Value $Value)) { return $null }
    $code = 0
    try { $code = [int]$Value } catch { return $null }
    # Excel COM interop の Range.Value2 は、VBA の CVErr 番号(2000..2042)ではなく
    # HRESULT形式の負の Int32 を返す。Formula へエラーリテラルを戻して復元する。
    switch ($code) {
        -2146826288 { return '#NULL!' }
        -2146826281 { return '#DIV/0!' }
        -2146826273 { return '#REF!' }
        -2146826265 { return '#VALUE!' }
        -2146826259 { return '#NAME?' }
        -2146826252 { return '#NUM!' }
        -2146826246 { return '#N/A' }
        default { return $null }
    }
}

function New-YakuExcelErrorValueRestoreRecord {
    param(
        [int]$Row,
        [int]$Col,
        [AllowNull()]$Value
    )
    $literal = Get-YakuExcelCvErrLiteral -Value $Value
    if ([string]::IsNullOrWhiteSpace([string]$literal)) { return $null }
    $code = 0
    try { $code = [int]$Value } catch { $code = 0 }
    return [pscustomobject]@{ Row=[int]$Row; Col=[int]$Col; Code=[int]$code; Formula=[string]$literal }
}

function Get-YakuExcelShortLogText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 80
    )
    try {
        $s = [string]$Text
        $s = $s -replace "`r", ' '
        $s = $s -replace "`n", ' '
        if ($MaxLength -le 0) { $MaxLength = 80 }
        if ($s.Length -gt $MaxLength) { return $s.Substring(0, $MaxLength) }
        return $s
    } catch { return '' }
}


function Normalize-YakuExcelComparisonText {
    param([AllowNull()]$Text)
    try { return ([string]$Text).Replace("`r`n", "`n").Replace("`r", "`n") } catch { return '' }
}

function Get-YakuExcelBulkArrayValue {
    param(
        [AllowNull()]$Source,
        [bool]$IsArray,
        [int]$RowIndex,
        [int]$ColIndex
    )
    if ($IsArray -and $null -ne $Source) { return $Source.GetValue($RowIndex, $ColIndex) }
    return $Source
}

function New-YakuExcelSingleCellRectangle {
    param(
        [Parameter(Mandatory=$true)][int]$Row,
        [Parameter(Mandatory=$true)][int]$Col,
        [Parameter(Mandatory=$true)][string]$Value
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([string[]]@([string]$Value)) | Out-Null
    return [pscustomobject]@{ StartRow=$Row; EndRow=$Row; StartCol=$Col; EndCol=$Col; Rows=$rows }
}

function New-YakuExcelCellItemsBounds {
    param([Parameter(Mandatory=$true)][object[]]$Items)
    if ($null -eq $Items -or $Items.Count -le 0) { return $null }
    $minRow = [int]::MaxValue
    $maxRow = 0
    $minCol = [int]::MaxValue
    $maxCol = 0
    $targetMap = @{}
    foreach ($item in @($Items)) {
        try {
            $row = [int]$item.Row
            $col = [int]$item.Col
            if ($row -lt $minRow) { $minRow = $row }
            if ($row -gt $maxRow) { $maxRow = $row }
            if ($col -lt $minCol) { $minCol = $col }
            if ($col -gt $maxCol) { $maxCol = $col }
            $targetMap[(([string]$row) + ',' + ([string]$col))] = $item
        } catch {}
    }
    if ($minRow -eq [int]::MaxValue -or $minCol -eq [int]::MaxValue) { return $null }
    $rowCount = [int]($maxRow - $minRow + 1)
    $colCount = [int]($maxCol - $minCol + 1)
    if ($rowCount -le 0 -or $colCount -le 0) { return $null }
    $area = ([int64]$rowCount) * ([int64]$colCount)
    return [pscustomobject]@{ MinRow=$minRow; MaxRow=$maxRow; MinCol=$minCol; MaxCol=$maxCol; RowCount=$rowCount; ColCount=$colCount; Area=$area; TargetMap=$targetMap }
}

function New-YakuExcelTargetRowBands {
    param(
        [Parameter(Mandatory=$true)][object[]]$Items,
        [int]$MaxGap = 5
    )
    $rowSet = @{}
    foreach ($item in @($Items)) {
        try { $rowSet[[string]([int]$item.Row)] = $true } catch {}
    }
    $rows = @($rowSet.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $bands = New-Object System.Collections.Generic.List[object]
    if ($rows.Count -le 0) { return @() }
    $start = [int]$rows[0]
    $end = [int]$rows[0]
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $row = [int]$rows[$i]
        $gap = [int]($row - $end - 1)
        if ($gap -le $MaxGap) {
            $end = $row
        } else {
            $bands.Add([pscustomobject]@{ StartRow=$start; EndRow=$end }) | Out-Null
            $start = $row
            $end = $row
        }
    }
    $bands.Add([pscustomobject]@{ StartRow=$start; EndRow=$end }) | Out-Null
    return @($bands.ToArray())
}

function Get-YakuExcelFormulaSetRangeCount {
    param(
        [AllowNull()][hashtable]$FormulaSet,
        [int]$StartRow,
        [int]$EndRow,
        [int]$StartCol,
        [int]$EndCol
    )
    $count = 0
    if ($null -eq $FormulaSet -or $FormulaSet.Count -le 0) { return 0 }
    foreach ($keyObj in @($FormulaSet.Keys)) {
        try {
            $key = [string]$keyObj
            $comma = $key.IndexOf(',')
            if ($comma -lt 1) { continue }
            $row = [int]$key.Substring(0, $comma)
            $col = [int]$key.Substring($comma + 1)
            if ($row -ge $StartRow -and $row -le $EndRow -and $col -ge $StartCol -and $col -le $EndCol) { $count++ }
        } catch {}
    }
    return [int]$count
}

function Get-YakuExcelCellItemsInRowRange {
    param(
        [Parameter(Mandatory=$true)][object[]]$Items,
        [int]$StartRow,
        [int]$EndRow
    )
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        try {
            $row = [int]$item.Row
            if ($row -ge $StartRow -and $row -le $EndRow) { $list.Add($item) | Out-Null }
        } catch {}
    }
    return @($list.ToArray())
}

function Invoke-YakuExcelCellItemsRectangleWrite {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null
    )
    $written = 0
    $fontAddresses = New-Object System.Collections.Generic.List[string]
    $rows = @{}
    foreach ($item in @($Items)) {
        try {
            $row = [int]$item.Row
            if (-not $rows.ContainsKey($row)) { $rows[$row] = New-Object System.Collections.Generic.List[object] }
            $rows[$row].Add($item) | Out-Null
        } catch {}
    }
    $runs = New-Object System.Collections.Generic.List[object]
    foreach ($rowKey in @($rows.Keys | Sort-Object {[int]$_})) {
        $row = [int]$rowKey
        $rowItems = @($rows[$row].ToArray() | Sort-Object Col)
        $run = New-Object System.Collections.Generic.List[object]
        $prevCol = $null
        foreach ($item in $rowItems) {
            $col = [int]$item.Col
            if ($null -ne $prevCol -and $col -ne ([int]$prevCol + 1)) {
                $runItems = @($run.ToArray())
                if ($runItems.Count -gt 0) {
                    $values = New-Object System.Collections.Generic.List[string]
                    foreach ($ri in $runItems) { $values.Add([string]$ri.Translation) | Out-Null }
                    $runs.Add([pscustomobject]@{ Row=$row; StartCol=[int]$runItems[0].Col; EndCol=[int]$runItems[$runItems.Count - 1].Col; Values=[string[]]@($values.ToArray()) }) | Out-Null
                }
                $run = New-Object System.Collections.Generic.List[object]
            }
            $run.Add($item) | Out-Null
            $prevCol = $col
        }
        if ($run.Count -gt 0) {
            $runItems = @($run.ToArray())
            $values = New-Object System.Collections.Generic.List[string]
            foreach ($ri in $runItems) { $values.Add([string]$ri.Translation) | Out-Null }
            $runs.Add([pscustomobject]@{ Row=$row; StartCol=[int]$runItems[0].Col; EndCol=[int]$runItems[$runItems.Count - 1].Col; Values=[string[]]@($values.ToArray()) }) | Out-Null
        }
    }
    $rectangles = @(Merge-YakuCellRunsToRects -Runs @($runs.ToArray()))
    foreach ($rect in $rectangles) {
        $rectWritten = [int](Add-YakuExcelCellRectangle -Worksheet $Worksheet -Rectangle $rect -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -SkipFont)
        $written += $rectWritten
        if ($rectWritten -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
            try { $fontAddresses.Add((Get-YakuExcelRangeAddress -StartRow ([int]$rect.StartRow) -StartCol ([int]$rect.StartCol) -EndRow ([int]$rect.EndRow) -EndCol ([int]$rect.EndCol))) | Out-Null } catch {}
        }
    }
    return [pscustomobject]@{ Written=[int]$written; FontAddresses=[string[]]@($fontAddresses.ToArray()); Rectangles=[int]$rectangles.Count }
}

function New-YakuExcelBulkRangeWritePlan {
    param(
        [Parameter(Mandatory=$true)]$Range,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [AllowNull()][hashtable]$FormulaSet = $null,
        [int]$MinRow,
        [int]$MinCol,
        [int]$RowCount,
        [int]$ColCount,
        [Parameter(Mandatory=$true)][string]$Address,
        [int64]$Area,
        [AllowNull()][string]$OutputFontName,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [switch]$ForceFormulaPatch,
        [int]$MaxRestoreCount = 200
    )
    $sw = $null
    try {
        $targetMap = @{}
        foreach ($item in @($Items)) {
            try { $targetMap[(([string]([int]$item.Row)) + ',' + ([string]([int]$item.Col)))] = $item } catch {}
        }
        if ($null -eq $FormulaSet) {
            try { Write-YakuLog "Excel bulk range avoided because formulaCells=unknown. sheet=$SheetName address=$Address" 'DEBUG' } catch {}
            return $null
        }
        $formulaCellCount = Get-YakuExcelFormulaSetRangeCount -FormulaSet $FormulaSet -StartRow $MinRow -EndRow ([int]($MinRow + $RowCount - 1)) -StartCol $MinCol -EndCol ([int]($MinCol + $ColCount - 1))
        $hasFormulaCells = ([int]$formulaCellCount -gt 0)
        # V91.3: never read and reassign Range.Formula. Excel can rewrite shared/array/dynamic
        # formula representation. Returning null routes the caller to target-only rectangle/single-cell writes.
        if ($hasFormulaCells) {
            try { Write-YakuLog "Excel bulk range avoided to preserve formulas. sheet=$SheetName address=$Address formulaCells=$formulaCellCount force=$([bool]$ForceFormulaPatch)" 'DEBUG' } catch {}
            return $null
        }
        $values = $null
        $formulas = $null
        if ($null -ne $Metrics) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
        $values = $Range.Value2
        if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_read_ms' -Stopwatch $sw; $sw = $null }

        $fontAddresses = New-Object System.Collections.Generic.List[string]
        if (-not $hasFormulaCells) {
            if ($RowCount -eq 1 -and $ColCount -eq 1) {
                $first = @($Items)[0]
                $payload = [string]$first.Translation
                if (Test-YakuExcelCoercionRiskString -Value $payload) {
                    return [pscustomobject]@{ Kind='bulk'; Range=$Range; Property='Value2'; Payload=$values; Written=0; FontAddresses=[string[]]@(); Address=$Address; Area=$Area; Mode='value2'; SingleItems=@($first); RiskyConstantRestores=@(); ErrorValueRestores=@(); RiskyTranslationSingles=1; FormulaCellCount=0; Rectangles=0; Items=[object[]]@($Items); BulkItems=[object[]]@(); StartRow=$MinRow; EndRow=([int]($MinRow + $RowCount - 1)) }
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) { $fontAddresses.Add($Address) | Out-Null }
                return [pscustomobject]@{ Kind='bulk'; Range=$Range; Property='Value2'; Payload=$payload; Written=[int]$Items.Count; FontAddresses=[string[]]@($fontAddresses.ToArray()); Address=$Address; Area=$Area; Mode='value2'; SingleItems=@(); RiskyConstantRestores=@(); ErrorValueRestores=@(); RiskyTranslationSingles=0; FormulaCellCount=0; Rectangles=0; Items=[object[]]@($Items); BulkItems=[object[]]@($Items); StartRow=$MinRow; EndRow=([int]($MinRow + $RowCount - 1)) }
            }
            if (-not ($values -is [System.Array]) -or $values.Rank -ne 2) {
                try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=shape-mismatch target=Value2 targets=$($Items.Count)" 'DEBUG' } catch {}
                return $null
            }
            $rowBase = [int]$values.GetLowerBound(0)
            $colBase = [int]$values.GetLowerBound(1)
            $valueRows = [int]($values.GetUpperBound(0) - $rowBase + 1)
            $valueCols = [int]($values.GetUpperBound(1) - $colBase + 1)
            if ($valueRows -ne $RowCount -or $valueCols -ne $ColCount) {
                try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=shape-mismatch target=Value2 rows=$valueRows cols=$valueCols expectedRows=$RowCount expectedCols=$ColCount" 'DEBUG' } catch {}
                return $null
            }
            $singleItems = New-Object System.Collections.Generic.List[object]
            $bulkItems = New-Object System.Collections.Generic.List[object]
            $riskyRestores = New-Object System.Collections.Generic.List[object]
            $errorRestores = New-Object System.Collections.Generic.List[object]
            $bulkTargetWritten = 0
            for ($vr = 0; $vr -lt $RowCount; $vr++) {
                $absRow = [int]($MinRow + $vr)
                for ($vc = 0; $vc -lt $ColCount; $vc++) {
                    $absCol = [int]($MinCol + $vc)
                    $key = ([string]$absRow) + ',' + ([string]$absCol)
                    if ($targetMap.ContainsKey($key)) { continue }
                    $existingValue = $values.GetValue([int]($rowBase + $vr), [int]($colBase + $vc))
                    if (($existingValue -is [string]) -and (Test-YakuExcelCoercionRiskString -Value ([string]$existingValue))) {
                        $values.SetValue($null, [int]($rowBase + $vr), [int]($colBase + $vc))
                        $riskyRestores.Add([pscustomobject]@{ Row=$absRow; Col=$absCol; Value=$existingValue }) | Out-Null
                        if (($riskyRestores.Count + $errorRestores.Count) -gt $MaxRestoreCount) { try { Write-YakuLog "Excel bulk plan aborted early. sheet=$SheetName address=$Address reason=restore-limit restores=$($riskyRestores.Count + $errorRestores.Count) maxRestores=$MaxRestoreCount" 'DEBUG' } catch {}; return $null }
                        continue
                    }
                    if (-not (Test-YakuExcelFormulaPatchSafeConstantValue -Value $existingValue)) {
                        $restore = New-YakuExcelErrorValueRestoreRecord -Row $absRow -Col $absCol -Value $existingValue
                        if ($null -eq $restore) {
                            $typeName = if ($null -eq $existingValue) { '<null>' } else { try { $existingValue.GetType().FullName } catch { '' } }
                            $codeText = ''
                            try { if (Test-YakuExcelFormulaPatchCvErrValue -Value $existingValue) { $codeText = ' code=' + ([string]([int]$existingValue)) } } catch {}
                            $reasonName = 'error-value'
                            try { if (Test-YakuExcelFormulaPatchCvErrValue -Value $existingValue) { $reasonName = 'unknown-cverr' } } catch {}
                            try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=$reasonName cell=R${absRow}C${absCol} type=$typeName$codeText mode=value2 targets=$($Items.Count)" 'DEBUG' } catch {}
                            return $null
                        }
                        $values.SetValue($null, [int]($rowBase + $vr), [int]($colBase + $vc))
                        $errorRestores.Add($restore) | Out-Null
                        if (($riskyRestores.Count + $errorRestores.Count) -gt $MaxRestoreCount) { try { Write-YakuLog "Excel bulk plan aborted early. sheet=$SheetName address=$Address reason=restore-limit restores=$($riskyRestores.Count + $errorRestores.Count) maxRestores=$MaxRestoreCount" 'DEBUG' } catch {}; return $null }
                    }
                }
            }
            foreach ($item in @($Items)) {
                $row = [int]$item.Row
                $col = [int]$item.Col
                $translation = [string]$item.Translation
                if (Test-YakuExcelCoercionRiskString -Value $translation) {
                    $singleItems.Add($item) | Out-Null
                    continue
                }
                $values.SetValue($translation, [int]($rowBase + $row - $MinRow), [int]($colBase + $col - $MinCol))
                $bulkTargetWritten++
                $bulkItems.Add($item) | Out-Null
                if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
                    try { $fontAddresses.Add((Get-YakuExcelRangeAddress -StartRow $row -StartCol $col -EndRow $row -EndCol $col)) | Out-Null } catch {}
                }
            }
            return [pscustomobject]@{ Kind='bulk'; Range=$Range; Property='Value2'; Payload=$values; Written=[int]$bulkTargetWritten; FontAddresses=[string[]]@($fontAddresses.ToArray()); Address=$Address; Area=$Area; Mode='value2'; SingleItems=@($singleItems.ToArray()); RiskyConstantRestores=@($riskyRestores.ToArray()); ErrorValueRestores=@($errorRestores.ToArray()); RiskyTranslationSingles=[int]$singleItems.Count; FormulaCellCount=0; Rectangles=0; Items=[object[]]@($Items); BulkItems=[object[]]@($bulkItems.ToArray()); StartRow=$MinRow; EndRow=([int]($MinRow + $RowCount - 1)) }
        }

        $valuesIsArray = ($values -is [System.Array] -and $values.Rank -eq 2)
        $formulasIsArray = ($formulas -is [System.Array] -and $formulas.Rank -eq 2)
        if (($RowCount -gt 1 -or $ColCount -gt 1) -and (-not $valuesIsArray -or ($hasFormulaCells -and -not $formulasIsArray))) {
            try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=shape-mismatch target=formula-patch valuesArray=$valuesIsArray formulasArray=$formulasIsArray formulaCells=$formulaCellCount targets=$($Items.Count)" 'DEBUG' } catch {}
            return $null
        }
        $valueRowBase = 0
        $valueColBase = 0
        $formulaRowBase = 0
        $formulaColBase = 0
        if ($valuesIsArray) {
            $valueRowBase = [int]$values.GetLowerBound(0)
            $valueColBase = [int]$values.GetLowerBound(1)
            $valueRows = [int]($values.GetUpperBound(0) - $valueRowBase + 1)
            $valueCols = [int]($values.GetUpperBound(1) - $valueColBase + 1)
            if ($valueRows -ne $RowCount -or $valueCols -ne $ColCount) {
                try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=shape-mismatch target=Value2 rows=$valueRows cols=$valueCols expectedRows=$RowCount expectedCols=$ColCount" 'DEBUG' } catch {}
                return $null
            }
        }
        if ($formulasIsArray) {
            $formulaRowBase = [int]$formulas.GetLowerBound(0)
            $formulaColBase = [int]$formulas.GetLowerBound(1)
            $formulaRows = [int]($formulas.GetUpperBound(0) - $formulaRowBase + 1)
            $formulaCols = [int]($formulas.GetUpperBound(1) - $formulaColBase + 1)
            if ($formulaRows -ne $RowCount -or $formulaCols -ne $ColCount) {
                try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=shape-mismatch target=Formula rows=$formulaRows cols=$formulaCols expectedRows=$RowCount expectedCols=$ColCount" 'DEBUG' } catch {}
                return $null
            }
        }

        $out = [System.Array]::CreateInstance([object], $RowCount, $ColCount)
        $singleItems = New-Object System.Collections.Generic.List[object]
        $bulkItems = New-Object System.Collections.Generic.List[object]
        $riskyRestores = New-Object System.Collections.Generic.List[object]
        $errorRestores = New-Object System.Collections.Generic.List[object]
        $bulkTargetWritten = 0
        for ($ri = 0; $ri -lt $RowCount; $ri++) {
            $absRow = [int]($MinRow + $ri)
            for ($ci = 0; $ci -lt $ColCount; $ci++) {
                $absCol = [int]($MinCol + $ci)
                $key = ([string]$absRow) + ',' + ([string]$absCol)
                $valueIndexRow = [int]($valueRowBase + $ri)
                $valueIndexCol = [int]($valueColBase + $ci)
                $formulaIndexRow = [int]($formulaRowBase + $ri)
                $formulaIndexCol = [int]($formulaColBase + $ci)
                $cellValue = Get-YakuExcelBulkArrayValue -Source $values -IsArray $valuesIsArray -RowIndex $valueIndexRow -ColIndex $valueIndexCol

                if ($null -ne $FormulaSet -and $FormulaSet.ContainsKey($key)) {
                    $formulaValue = Get-YakuExcelBulkArrayValue -Source $formulas -IsArray $formulasIsArray -RowIndex $formulaIndexRow -ColIndex $formulaIndexCol
                    if ($null -eq $formulaValue -or -not ($formulaValue -is [string])) {
                        $typeName = if ($null -eq $formulaValue) { '<null>' } else { try { $formulaValue.GetType().FullName } catch { '' } }
                        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=shape-mismatch cell=$key formulaType=$typeName mode=formula-patch targets=$($Items.Count)" 'DEBUG' } catch {}
                        return $null
                    }
                    $out.SetValue([string]$formulaValue, $ri, $ci)
                    continue
                }

                if ($targetMap.ContainsKey($key)) {
                    $targetItem = $targetMap[$key]
                    $translation = [string]$targetItem.Translation
                    if (Test-YakuExcelCoercionRiskString -Value $translation) {
                        if (($cellValue -is [string]) -and (Test-YakuExcelCoercionRiskString -Value ([string]$cellValue))) {
                            $out.SetValue($null, $ri, $ci)
                        } elseif (-not (Test-YakuExcelFormulaPatchSafeConstantValue -Value $cellValue)) {
                            $out.SetValue($null, $ri, $ci)
                        } else {
                            $out.SetValue($cellValue, $ri, $ci)
                        }
                        $singleItems.Add($targetItem) | Out-Null
                    } else {
                        $out.SetValue($translation, $ri, $ci)
                        $bulkTargetWritten++
                        try { $bulkItems.Add($targetItem) | Out-Null } catch {}
                        if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
                            try { $fontAddresses.Add((Get-YakuExcelRangeAddress -StartRow $absRow -StartCol $absCol -EndRow $absRow -EndCol $absCol)) | Out-Null } catch {}
                        }
                    }
                    continue
                }

                if (($cellValue -is [string]) -and (Test-YakuExcelCoercionRiskString -Value ([string]$cellValue))) {
                    $out.SetValue($null, $ri, $ci)
                    $riskyRestores.Add([pscustomobject]@{ Row=$absRow; Col=$absCol; Value=$cellValue }) | Out-Null
                    if (($riskyRestores.Count + $errorRestores.Count) -gt $MaxRestoreCount) { try { Write-YakuLog "Excel bulk plan aborted early. sheet=$SheetName address=$Address reason=restore-limit restores=$($riskyRestores.Count + $errorRestores.Count) maxRestores=$MaxRestoreCount" 'DEBUG' } catch {}; return $null }
                    continue
                }
                if (-not (Test-YakuExcelFormulaPatchSafeConstantValue -Value $cellValue)) {
                    $restore = New-YakuExcelErrorValueRestoreRecord -Row $absRow -Col $absCol -Value $cellValue
                    if ($null -eq $restore) {
                        $typeName = if ($null -eq $cellValue) { '<null>' } else { try { $cellValue.GetType().FullName } catch { '' } }
                        $codeText = ''
                        try { if (Test-YakuExcelFormulaPatchCvErrValue -Value $cellValue) { $codeText = ' code=' + ([string]([int]$cellValue)) } } catch {}
                        $reasonName = 'error-value'
                        try { if (Test-YakuExcelFormulaPatchCvErrValue -Value $cellValue) { $reasonName = 'unknown-cverr' } } catch {}
                        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=$reasonName cell=$key type=$typeName$codeText mode=formula-patch targets=$($Items.Count)" 'DEBUG' } catch {}
                        return $null
                    }
                    $out.SetValue($null, $ri, $ci)
                    $errorRestores.Add($restore) | Out-Null
                    if (($riskyRestores.Count + $errorRestores.Count) -gt $MaxRestoreCount) { try { Write-YakuLog "Excel bulk plan aborted early. sheet=$SheetName address=$Address reason=restore-limit restores=$($riskyRestores.Count + $errorRestores.Count) maxRestores=$MaxRestoreCount" 'DEBUG' } catch {}; return $null }
                    continue
                }
                $out.SetValue($cellValue, $ri, $ci)
            }
        }
        return [pscustomobject]@{ Kind='bulk'; Range=$Range; Property='Formula'; Payload=$out; Written=[int]$bulkTargetWritten; FontAddresses=[string[]]@($fontAddresses.ToArray()); Address=$Address; Area=$Area; Mode='formula-patch'; SingleItems=@($singleItems.ToArray()); RiskyConstantRestores=@($riskyRestores.ToArray()); ErrorValueRestores=@($errorRestores.ToArray()); RiskyTranslationSingles=[int]$singleItems.Count; FormulaCellCount=[int]$formulaCellCount; Rectangles=0; Items=[object[]]@($Items); BulkItems=[object[]]@($bulkItems.ToArray()); StartRow=$MinRow; EndRow=([int]($MinRow + $RowCount - 1)) }
    } catch {
        if ($null -ne $sw) { try { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_read_ms' -Stopwatch $sw } catch {} }
        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$Address reason=exception-plan error=$($_.Exception.Message)" 'DEBUG' } catch {}
        return $null
    }
}
function Invoke-YakuExcelBulkRangeWritePlan {
    param(
        [Parameter(Mandatory=$true)]$Plan,
        [Parameter(Mandatory=$true)]$Worksheet,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [switch]$ThrowOnWriteError
    )
    $sw = $null
    $fontAddresses = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($addr in @($Plan.FontAddresses)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$addr)) { $fontAddresses.Add([string]$addr) | Out-Null }
        }
        if ($null -ne $Metrics) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
        # V91.10 final defense: FormulaSet is a fast pre-filter; Excel HasFormula is authoritative.
        $hasNoFormula = Test-YakuExcelWriteRangeHasNoFormula -Range $Plan.Range
        if (-not $hasNoFormula) {
            $hasFormulaRaw = $null; try { $hasFormulaRaw = $Plan.Range.HasFormula } catch { $hasFormulaRaw = '<read-failed>' }
            $detail = [pscustomobject]@{ Sheet=[string]$SheetName; Address=[string]$Plan.Address; FormulaSetCount=[int]$Plan.FormulaCellCount; HasFormula=[string]$hasFormulaRaw }
            Add-YakuWarning -Warnings $Warnings -Category 'formula-set-underreport' -Location (([string]$SheetName) + '!' + ([string]$Plan.Address)) -Detail $detail -Message "数式セルを含む可能性がある一括書込を遮断し、安全な矩形書込へ切り替えました。sheet=$SheetName address=$($Plan.Address) formulaSet=$($Plan.FormulaCellCount) hasFormula=$hasFormulaRaw"
            try { Write-YakuLog "FormulaSet underreport blocked bulk write. sheet=$SheetName address=$($Plan.Address) formulaSet=$($Plan.FormulaCellCount) hasFormula=$hasFormulaRaw" 'WARN' } catch {}
            return $null
        }
        if ([string]$Plan.Property -eq 'Value2') {
            $value2ProbeSw = $null
            $runValue2Probe = $false
            try { $runValue2Probe = ($null -ne $Metrics -and $Metrics.ContainsKey('value2_put_probe_pending') -and [bool]$Metrics['value2_put_probe_pending']) } catch { $runValue2Probe = $false }
            if ($runValue2Probe) { $value2ProbeSw = [System.Diagnostics.Stopwatch]::StartNew() }
            if ($Plan.Payload -is [System.Array] -and $Plan.Payload.Rank -eq 2) {
                Set-YakuExcelRangeArrayValue2 -Range $Plan.Range -Values2D $Plan.Payload
            } else {
                $Plan.Range.Value2 = $Plan.Payload
            }
            if ($null -ne $value2ProbeSw) {
                $value2ProbeSw.Stop()
                try { Write-YakuLog "Excel writeback value2 put probe. sheet=$SheetName address=$($Plan.Address) ms=$([Math]::Round($value2ProbeSw.Elapsed.TotalMilliseconds, 2))" 'INFO' } catch {}
                try { $Metrics['value2_put_probe_pending'] = $false; $Metrics['value2_put_probe_done'] = $true; $Metrics['value2_put_probe_ms'] = [double]$value2ProbeSw.Elapsed.TotalMilliseconds } catch {}
            }
        } else {
            if ($Plan.Payload -is [System.Array] -and $Plan.Payload.Rank -eq 2) {
                Set-YakuExcelRangeArrayFormula -Range $Plan.Range -Values2D $Plan.Payload
            } else {
                $Plan.Range.Formula = $Plan.Payload
            }
        }
        if ($null -ne $sw) {
            Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_write_ms' -Stopwatch $sw
            if ([string]$Plan.Property -eq 'Value2') { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'value2_ms' -Stopwatch $sw }
        }

        $restoreWritten = 0
        foreach ($restore in @($Plan.RiskyConstantRestores)) {
            $cell = $null
            $restoreSw = $null
            try {
                if ($null -ne $Metrics) { $restoreSw = [System.Diagnostics.Stopwatch]::StartNew() }
                $row = [int]$restore.Row
                $col = [int]$restore.Col
                $loc = "R${row}C${col}"; if (-not [string]::IsNullOrWhiteSpace([string]$SheetName)) { $loc = ([string]$SheetName) + '!' + $loc }
                $cell = $Worksheet.Cells.Item($row, $col)
                $restoreText = [string]$restore.Value
                if (-not (Test-YakuExcelWriteRangeHasNoFormula -Range $cell)) {
                    Add-YakuFormulaWriteBlockedWarning -Warnings $Warnings -Location $loc -Translation $restoreText
                    continue
                }
                $numberFormat = ''; try { $numberFormat = [string]$cell.NumberFormat } catch {}
                if ($numberFormat -eq '@') { $cell.Value2 = $restoreText }
                else { $cell.Formula = ("'" + $restoreText) }
                $restoreWritten++
                if ($null -ne $restoreSw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_write_ms' -Stopwatch $restoreSw }
            } catch {
                $loc = "R$($restore.Row)C$($restore.Col)"
                if (-not [string]::IsNullOrWhiteSpace([string]$SheetName)) { $loc = ([string]$SheetName) + '!' + $loc }
                $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-risky-constant-restore' -Location $loc -Detail $diag -Message "risky定数セルの復元に失敗しました: $loc - $($_.Exception.Message)"
                throw "OUTPUT_RESTORE_FAILED: 非対象セルを安全に復元できませんでした。location=$loc"
            } finally {
                Release-YakuComObject $cell
            }
        }

        $errorRestoreWritten = 0
        foreach ($restore in @($Plan.ErrorValueRestores)) {
            $cell = $null
            $restoreSw = $null
            try {
                if ($null -ne $Metrics) { $restoreSw = [System.Diagnostics.Stopwatch]::StartNew() }
                $row = [int]$restore.Row
                $col = [int]$restore.Col
                $loc = "R${row}C${col}"; if (-not [string]::IsNullOrWhiteSpace([string]$SheetName)) { $loc = ([string]$SheetName) + '!' + $loc }
                $cell = $Worksheet.Cells.Item($row, $col)
                if (-not (Test-YakuExcelWriteRangeHasNoFormula -Range $cell)) {
                    Add-YakuFormulaWriteBlockedWarning -Warnings $Warnings -Location $loc -Translation ([string]$restore.Formula)
                    continue
                }
                $cell.Formula = [string]$restore.Formula
                $errorRestoreWritten++
                if ($null -ne $restoreSw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_write_ms' -Stopwatch $restoreSw }
            } catch {
                $loc = "R$($restore.Row)C$($restore.Col)"
                if (-not [string]::IsNullOrWhiteSpace([string]$SheetName)) { $loc = ([string]$SheetName) + '!' + $loc }
                $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
                $code = ''
                try { $code = [string]$restore.Code } catch { $code = '' }
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-error-value-restore' -Location $loc -Detail $diag -Message "エラー値セルの復元に失敗しました: $loc code=$code - $($_.Exception.Message)"
            } finally {
                Release-YakuComObject $cell
            }
        }

        $singleWritten = 0
        foreach ($item in @($Plan.SingleItems)) {
            try {
                $row = [int]$item.Row
                $col = [int]$item.Col
                $singleResult = [int](Add-YakuExcelCellSingleValue -Worksheet $Worksheet -Row $row -Col $col -Value ([string]$item.Translation) -OutputFontName '' -Warnings $Warnings -SheetName $SheetName)
                $singleWritten += $singleResult
                if ($singleResult -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
                    try { $fontAddresses.Add((Get-YakuExcelRangeAddress -StartRow $row -StartCol $col -EndRow $row -EndCol $col)) | Out-Null } catch {}
                }
            } catch {}
        }
        return [pscustomobject]@{ Written=([int]$Plan.Written + [int]$singleWritten); SingleCells=[int]$singleWritten; RiskyConstantRestores=[int]$restoreWritten; ErrorValueRestores=[int]$errorRestoreWritten; RiskyTranslationSingles=[int]$Plan.RiskyTranslationSingles; FontAddresses=[string[]]@($fontAddresses.ToArray()); Rectangles=0; Mode=[string]$Plan.Mode }
    } catch {
        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$($Plan.Address) reason=exception-write error=$($_.Exception.Message)" 'DEBUG' } catch {}
        if ($ThrowOnWriteError) { throw }
        return $null
    }
}
function Get-YakuExcelBulkPlanRestoreCount {
    param([AllowNull()]$Plan)
    $count = 0
    try { $count += [int]@($Plan.RiskyConstantRestores).Count } catch {}
    try { $count += [int]@($Plan.ErrorValueRestores).Count } catch {}
    return [int]$count
}

function Test-YakuExcelBulkWriteFirstTarget {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)]$Plan,
        [AllowNull()][string]$SheetName = ''
    )
    try {
        $bulkItems = @()
        try { $bulkItems = @($Plan.BulkItems) } catch { $bulkItems = @() }
        if ($bulkItems.Count -le 0) { return $true }
        foreach ($item in $bulkItems) {
            $cell = $null
            try {
                $row = [int]$item.Row; $col = [int]$item.Col; $expected = [string]$item.Translation
                $cell = $Worksheet.Cells.Item($row, $col); $actual = $cell.Value2
                $actualText = if ($null -eq $actual) { '' } else { [string]$actual }
                if ((Normalize-YakuExcelComparisonText -Text $actualText) -cne (Normalize-YakuExcelComparisonText -Text $expected)) {
                    try { Write-YakuLog "Excel writeback optimistic verify failed. sheet=$SheetName address=$($Plan.Address) cell=R${row}C${col} expectedLen=$($expected.Length) actualLen=$($actualText.Length)" 'DEBUG' } catch {}
                    return $false
                }
            } finally { Release-YakuComObject $cell }
        }
        return $true
    } catch {
        try { Write-YakuLog "Excel writeback optimistic verify failed. sheet=$SheetName address=$($Plan.Address) reason=exception error=$($_.Exception.Message)" 'DEBUG' } catch {}
        return $false
    }
}

function Invoke-YakuExcelOptimisticWritePlan {
    param(
        [Parameter(Mandatory=$true)]$Plan,
        [Parameter(Mandatory=$true)]$Worksheet,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [AllowNull()][hashtable]$VerifyState = $null
    )
    try { $Plan.Mode = 'value2-optimistic' } catch {}
    try {
        $writeResult = Invoke-YakuExcelBulkRangeWritePlan -Plan $Plan -Worksheet $Worksheet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -ThrowOnWriteError
        if ($null -eq $writeResult) { throw "optimistic bulk write returned null" }
        $ok = Test-YakuExcelBulkWriteFirstTarget -Worksheet $Worksheet -Plan $Plan -SheetName $SheetName
        if (-not $ok) { throw "optimistic verify failed" }
        return $writeResult
    } catch {
        $reason = Get-YakuExcelShortLogText -Text ([string]$_.Exception.Message) -MaxLength 80
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'unknown' }
        try { Write-YakuLog "Excel writeback bulk box optimisticFailed=1 sheet=$SheetName address=$($Plan.Address) reason=$reason" 'DEBUG' } catch {}
        if ($null -ne $Metrics) {
            try {
                if (-not $Metrics.ContainsKey('optimistic_failed')) { $Metrics['optimistic_failed'] = 0 }
                $Metrics['optimistic_failed'] = [int]$Metrics['optimistic_failed'] + 1
            } catch {}
            try { $Metrics['optimistic_failed_reason'] = [string]$reason } catch {}
        }
        return $null
    }
}

function Add-YakuExcelBulkWriteAggregate {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Aggregate,
        [Parameter(Mandatory=$true)]$WriteResult,
        [switch]$Optimistic
    )
    try { $Aggregate['Written'] = [int]$Aggregate['Written'] + [int]$WriteResult.Written } catch {}
    try { $Aggregate['SingleCells'] = [int]$Aggregate['SingleCells'] + [int]$WriteResult.SingleCells } catch {}
    try { $Aggregate['RiskyTranslationSingles'] = [int]$Aggregate['RiskyTranslationSingles'] + [int]$WriteResult.RiskyTranslationSingles } catch {}
    try { $Aggregate['RiskyRestoresWritten'] = [int]$Aggregate['RiskyRestoresWritten'] + [int]$WriteResult.RiskyConstantRestores } catch {}
    try { $Aggregate['ErrorRestoresWritten'] = [int]$Aggregate['ErrorRestoresWritten'] + [int]$WriteResult.ErrorValueRestores } catch {}
    try { $Aggregate['BulkBands'] = [int]$Aggregate['BulkBands'] + 1 } catch {}
    try { if ($Optimistic) { $Aggregate['OptimisticBulkBands'] = [int]$Aggregate['OptimisticBulkBands'] + 1 } } catch {}
    $fontList = $null
    try { $fontList = $Aggregate['FontAddresses'] } catch { $fontList = $null }
    if ($null -ne $fontList) {
        foreach ($addr in @($WriteResult.FontAddresses)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$addr)) { try { $fontList.Add([string]$addr) | Out-Null } catch {} }
        }
    }
}

function Add-YakuExcelFormulaFreeColumnBandPlans {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Bounds,
        [Parameter(Mandatory=$true)][hashtable]$FormulaSet,
        [AllowNull()][string]$OutputFontName,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [Parameter(Mandatory=$true)]$Plans,
        [Parameter(Mandatory=$true)][hashtable]$Counters,
        [int]$StartRow,
        [int]$EndRow,
        [int]$Depth = 0
    )
    # V91.17: FormulaSet is already in memory.  Split the row band into contiguous
    # columns that contain no formula in any row, so Range.Formula is never read or restored.
    $blockedCols = @{}
    for ($row = $StartRow; $row -le $EndRow; $row++) {
        for ($col = [int]$Bounds.MinCol; $col -le [int]$Bounds.MaxCol; $col++) {
            $key = ([string]$row) + ',' + ([string]$col)
            if ($FormulaSet.ContainsKey($key)) { $blockedCols[$col] = $true }
        }
    }
    if ($blockedCols.Count -le 0) { return $false }

    $handled = @{}
    $segmentStart = $null
    for ($col = [int]$Bounds.MinCol; $col -le ([int]$Bounds.MaxCol + 1); $col++) {
        $isSafe = ($col -le [int]$Bounds.MaxCol -and -not $blockedCols.ContainsKey($col))
        if ($isSafe -and $null -eq $segmentStart) { $segmentStart = $col; continue }
        if (($isSafe -or $null -eq $segmentStart)) { continue }

        $segmentEnd = [int]($col - 1)
        $segmentItems = @($Items | Where-Object { [int]$_.Col -ge [int]$segmentStart -and [int]$_.Col -le $segmentEnd })
        if ($segmentItems.Count -gt 0) {
            $segmentAddress = Get-YakuExcelRangeAddress -StartRow $StartRow -StartCol ([int]$segmentStart) -EndRow $EndRow -EndCol $segmentEnd
            $segmentRange = $null
            try {
                $rangeSw = $null
                if ($null -ne $Metrics) { $rangeSw = [System.Diagnostics.Stopwatch]::StartNew() }
                $segmentRange = $Worksheet.Range($segmentAddress)
                if ($null -ne $rangeSw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'range_ms' -Stopwatch $rangeSw }
                $segmentRows = [int]($EndRow - $StartRow + 1)
                $segmentCols = [int]($segmentEnd - [int]$segmentStart + 1)
                $segmentPlan = New-YakuExcelBulkRangeWritePlan -Range $segmentRange -Items ([object[]]$segmentItems) -FormulaSet $FormulaSet -MinRow $StartRow -MinCol ([int]$segmentStart) -RowCount $segmentRows -ColCount $segmentCols -Address $segmentAddress -Area (([int64]$segmentRows) * ([int64]$segmentCols)) -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics -ForceFormulaPatch
                if ($null -ne $segmentPlan) {
                    try { $segmentPlan.Mode = 'value2-banded' } catch {}
                    $Plans.Add($segmentPlan) | Out-Null
                    foreach ($item in $segmentItems) { $handled[(([string]([int]$item.Row)) + ',' + ([string]([int]$item.Col)))] = $true }
                    $segmentRange = $null
                    try { Write-YakuLog "Excel writeback formula-free column band. sheet=$SheetName address=$segmentAddress targets=$($segmentItems.Count) depth=$Depth" 'DEBUG' } catch {}
                }
            } catch {
                try { Write-YakuLog "Excel writeback formula-free column band failed. sheet=$SheetName address=$segmentAddress error=$($_.Exception.Message)" 'DEBUG' } catch {}
            } finally {
                Release-YakuComObject $segmentRange
            }
        }
        $segmentStart = $null
    }

    $remaining = @($Items | Where-Object { -not $handled.ContainsKey((([string]([int]$_.Row)) + ',' + ([string]([int]$_.Col)))) })
    if ($remaining.Count -gt 0) {
        $Plans.Add([pscustomobject]@{ Kind='fallback'; Items=[object[]]$remaining; Address='formula-columns' }) | Out-Null
        try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
        try { Write-YakuLog "Excel writeback bulk band partial fallback. sheet=$SheetName reason=formula-columns targets=$($remaining.Count) depth=$Depth" 'DEBUG' } catch {}
    }
    return ($handled.Count -gt 0)
}

function Add-YakuExcelBulkBandPlansRecursive {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Bounds,
        [AllowNull()][hashtable]$FormulaSet = $null,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [Parameter(Mandatory=$true)]$Plans,
        [Parameter(Mandatory=$true)][hashtable]$Counters,
        [int]$StartRow,
        [int]$EndRow,
        [int]$Depth = 0,
        [int]$MaxDepth = 6,
        [int]$MaxProbes = 30
    )
    if ($null -eq $Items -or $Items.Count -le 0) { return }
    if ($StartRow -gt $EndRow) { return }
    try {
        if (-not $Counters.ContainsKey('Probes')) { $Counters['Probes'] = 0 }
        if (-not $Counters.ContainsKey('Fallbacks')) { $Counters['Fallbacks'] = 0 }
        if (-not $Counters.ContainsKey('DepthMax')) { $Counters['DepthMax'] = 0 }
        if ([int]$Depth -gt [int]$Counters['DepthMax']) { $Counters['DepthMax'] = [int]$Depth }
    } catch {}

    $bandRange = $null
    $bandAddress = Get-YakuExcelRangeAddress -StartRow $StartRow -StartCol ([int]$Bounds.MinCol) -EndRow $EndRow -EndCol ([int]$Bounds.MaxCol)
    $bandRows = [int]($EndRow - $StartRow + 1)
    $bandCols = [int]$Bounds.ColCount
    $bandArea = ([int64]$bandRows) * ([int64]$bandCols)
    $probeLimitReached = $false
    try { $probeLimitReached = ([int]$Counters['Probes'] -ge [int]$MaxProbes) } catch { $probeLimitReached = $false }

    try {
        $rangeSw = $null
        if ($null -ne $Metrics) { $rangeSw = [System.Diagnostics.Stopwatch]::StartNew() }
        $bandRange = $Worksheet.Range($bandAddress)
        if ($null -ne $rangeSw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'range_ms' -Stopwatch $rangeSw }

        if ($probeLimitReached) {
            $plan = New-YakuExcelBulkRangeWritePlan -Range $bandRange -Items $Items -FormulaSet $FormulaSet -MinRow $StartRow -MinCol ([int]$Bounds.MinCol) -RowCount $bandRows -ColCount $bandCols -Address $bandAddress -Area $bandArea -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics -ForceFormulaPatch
            if ($null -ne $plan) {
                try { $plan.Mode = 'value2-optimistic' } catch {}
                try { Write-YakuLog "Excel writeback bulk band optimistic. sheet=$SheetName address=$bandAddress reason=band-probe-limit targets=$($Items.Count) depth=$Depth probes=$($Counters['Probes'])" 'DEBUG' } catch {}
                $Plans.Add([pscustomobject]@{ Kind='optimistic'; Plan=$plan; Items=[object[]]@($Items); Address=$bandAddress; StartRow=$StartRow; EndRow=$EndRow; Depth=$Depth; SplitOnFail=$false; Reason='band-probe-limit' }) | Out-Null
                $bandRange = $null
            } else {
                try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName rows=$StartRow-$EndRow reason=band-probe-limit probes=$($Counters['Probes']) maxProbes=$MaxProbes targets=$($Items.Count)" 'DEBUG' } catch {}
                $Plans.Add([pscustomobject]@{ Kind='fallback'; Items=[object[]]@($Items); Address=$bandAddress }) | Out-Null
                try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
            }
            return
        }

        $bandMergeCells = $null
        try {
            $Counters['Probes'] = [int]$Counters['Probes'] + 1
            $bandMergeCells = $bandRange.MergeCells
        } catch {
            $bandMergeCells = $null
        }

        if (Test-YakuExcelComFalse -Value $bandMergeCells) {
            $plan = New-YakuExcelBulkRangeWritePlan -Range $bandRange -Items $Items -FormulaSet $FormulaSet -MinRow $StartRow -MinCol ([int]$Bounds.MinCol) -RowCount $bandRows -ColCount $bandCols -Address $bandAddress -Area $bandArea -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics
            if ($null -eq $plan) {
                $splitUsed = $false
                try { $splitUsed = [bool](Add-YakuExcelFormulaFreeColumnBandPlans -Worksheet $Worksheet -Items $Items -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics -Plans $Plans -Counters $Counters -StartRow $StartRow -EndRow $EndRow -Depth $Depth) } catch { $splitUsed = $false }
                if (-not $splitUsed) {
                    try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$bandAddress reason=guard targets=$($Items.Count) depth=$Depth" 'DEBUG' } catch {}
                    $Plans.Add([pscustomobject]@{ Kind='fallback'; Items=[object[]]@($Items); Address=$bandAddress }) | Out-Null
                    try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
                }
                Release-YakuComObject $bandRange
                $bandRange = $null
            } else {
                $Plans.Add($plan) | Out-Null
                $bandRange = $null
            }
            return
        }

        $isTerminal = ([int]$Depth -ge [int]$MaxDepth -or [int]$bandRows -le 2)
        $optimisticPlan = New-YakuExcelBulkRangeWritePlan -Range $bandRange -Items $Items -FormulaSet $FormulaSet -MinRow $StartRow -MinCol ([int]$Bounds.MinCol) -RowCount $bandRows -ColCount $bandCols -Address $bandAddress -Area $bandArea -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics -ForceFormulaPatch
        if ($null -ne $optimisticPlan) {
            try { $optimisticPlan.Mode = 'value2-optimistic' } catch {}
            $splitOnFail = (-not $isTerminal)
            try { Write-YakuLog "Excel writeback bulk band optimistic. sheet=$SheetName address=$bandAddress mergeCells=$bandMergeCells targets=$($Items.Count) depth=$Depth splitOnFail=$splitOnFail" 'DEBUG' } catch {}
            $Plans.Add([pscustomobject]@{ Kind='optimistic'; Plan=$optimisticPlan; Items=[object[]]@($Items); Address=$bandAddress; StartRow=$StartRow; EndRow=$EndRow; Depth=$Depth; SplitOnFail=$splitOnFail; Reason='merged' }) | Out-Null
            $bandRange = $null
            return
        }

        if ($isTerminal) {
            try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$bandAddress reason=merged-terminal mergeCells=$bandMergeCells targets=$($Items.Count) depth=$Depth rows=$bandRows" 'DEBUG' } catch {}
            $Plans.Add([pscustomobject]@{ Kind='fallback'; Items=[object[]]@($Items); Address=$bandAddress }) | Out-Null
            try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
            return
        }

        try { Write-YakuLog "Excel writeback bulk band split. sheet=$SheetName address=$bandAddress reason=merged-plan mergeCells=$bandMergeCells targets=$($Items.Count) depth=$Depth probes=$($Counters['Probes'])" 'DEBUG' } catch {}
        Release-YakuComObject $bandRange
        $bandRange = $null
        Add-YakuExcelBulkSplitPlans -Worksheet $Worksheet -Items $Items -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Plans $Plans -Counters $Counters -StartRow $StartRow -EndRow $EndRow -Depth $Depth -MaxDepth $MaxDepth -MaxProbes $MaxProbes
    } catch {
        try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$bandAddress reason=exception-plan error=$($_.Exception.Message) targets=$($Items.Count) depth=$Depth" 'DEBUG' } catch {}
        $Plans.Add([pscustomobject]@{ Kind='fallback'; Items=[object[]]@($Items); Address=$bandAddress }) | Out-Null
        try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
    } finally {
        Release-YakuComObject $bandRange
    }
}

function Add-YakuExcelBulkSplitPlans {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Bounds,
        [AllowNull()][hashtable]$FormulaSet = $null,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [Parameter(Mandatory=$true)]$Plans,
        [Parameter(Mandatory=$true)][hashtable]$Counters,
        [int]$StartRow,
        [int]$EndRow,
        [int]$Depth = 0,
        [int]$MaxDepth = 6,
        [int]$MaxProbes = 30
    )
    $rowSet = @{}
    foreach ($item in @($Items)) {
        try {
            $row = [int]$item.Row
            if ($row -ge $StartRow -and $row -le $EndRow) { $rowSet[[string]$row] = $true }
        } catch {}
    }
    $targetRows = @($rowSet.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    if ($targetRows.Count -le 0) { return }
    $splitRow = [int][Math]::Floor(([double]($StartRow + $EndRow)) / 2.0)
    if ($targetRows.Count -gt 1) {
        try {
            $medianIndex = [int][Math]::Floor(([double]($targetRows.Count - 1)) / 2.0)
            $splitRow = [int]$targetRows[$medianIndex]
        } catch {}
    }
    if ($splitRow -le $StartRow -or $splitRow -ge $EndRow) {
        $splitRow = [int][Math]::Floor(([double]($StartRow + $EndRow)) / 2.0)
    }
    if ($splitRow -lt $StartRow) { $splitRow = $StartRow }
    if ($splitRow -ge $EndRow) { $splitRow = [int]($EndRow - 1) }

    $lowerItems = @(Get-YakuExcelCellItemsInRowRange -Items $Items -StartRow $StartRow -EndRow $splitRow)
    $upperItems = @(Get-YakuExcelCellItemsInRowRange -Items $Items -StartRow ([int]($splitRow + 1)) -EndRow $EndRow)
    if ($lowerItems.Count -gt 0) {
        Add-YakuExcelBulkBandPlansRecursive -Worksheet $Worksheet -Items ([object[]]$lowerItems) -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Plans $Plans -Counters $Counters -StartRow $StartRow -EndRow $splitRow -Depth ([int]($Depth + 1)) -MaxDepth $MaxDepth -MaxProbes $MaxProbes
    }
    if ($upperItems.Count -gt 0) {
        Add-YakuExcelBulkBandPlansRecursive -Worksheet $Worksheet -Items ([object[]]$upperItems) -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Plans $Plans -Counters $Counters -StartRow ([int]($splitRow + 1)) -EndRow $EndRow -Depth ([int]($Depth + 1)) -MaxDepth $MaxDepth -MaxProbes $MaxProbes
    }
}

function Invoke-YakuExcelBulkBandPlanObject {
    param(
        [Parameter(Mandatory=$true)]$PlanObject,
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)]$Bounds,
        [AllowNull()][hashtable]$FormulaSet = $null,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [Parameter(Mandatory=$true)][hashtable]$Aggregate,
        [Parameter(Mandatory=$true)][hashtable]$Counters,
        [Parameter(Mandatory=$true)][hashtable]$VerifyState,
        [int]$MaxDepth = 6,
        [int]$MaxProbes = 30
    )
    if ([string]$PlanObject.Kind -eq 'fallback') {
        $fallbackResult = Invoke-YakuExcelCellItemsRectangleWrite -Worksheet $Worksheet -Items ([object[]]@($PlanObject.Items)) -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics
        try { $Aggregate['Written'] = [int]$Aggregate['Written'] + [int]$fallbackResult.Written } catch {}
        try { $Aggregate['Rectangles'] = [int]$Aggregate['Rectangles'] + [int]$fallbackResult.Rectangles } catch {}
        $fontList = $Aggregate['FontAddresses']
        foreach ($addr in @($fallbackResult.FontAddresses)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$addr)) { try { $fontList.Add([string]$addr) | Out-Null } catch {} }
        }
        return
    }

    if ([string]$PlanObject.Kind -eq 'optimistic') {
        $plan = $PlanObject.Plan
        try {
            $restoreCount = Get-YakuExcelBulkPlanRestoreCount -Plan $plan
            if ([int]$restoreCount -gt 200) {
                try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$($PlanObject.Address) reason=restore-limit restores=$restoreCount maxRestores=200 mode=value2-optimistic targets=$(@($PlanObject.Items).Count)" 'DEBUG' } catch {}
                try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
                $fallbackObj = [pscustomobject]@{ Kind='fallback'; Items=[object[]]@($PlanObject.Items); Address=$PlanObject.Address }
                Invoke-YakuExcelBulkBandPlanObject -PlanObject $fallbackObj -Worksheet $Worksheet -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Aggregate $Aggregate -Counters $Counters -VerifyState $VerifyState -MaxDepth $MaxDepth -MaxProbes $MaxProbes
                return
            }
            $writeResult = Invoke-YakuExcelOptimisticWritePlan -Plan $plan -Worksheet $Worksheet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -VerifyState $VerifyState
            if ($null -ne $writeResult) {
                Add-YakuExcelBulkWriteAggregate -Aggregate $Aggregate -WriteResult $writeResult -Optimistic
                return
            }

            $reason = ''
            try { if ($Metrics.ContainsKey('optimistic_failed_reason')) { $reason = [string]$Metrics['optimistic_failed_reason'] } } catch {}
            $splitOnFail = $false
            try { $splitOnFail = [bool]$PlanObject.SplitOnFail } catch { $splitOnFail = $false }
            if ($splitOnFail -and $reason -ne 'optimistic verify failed') {
                $childPlans = New-Object System.Collections.Generic.List[object]
                try { Write-YakuLog "Excel writeback bulk band split. sheet=$SheetName address=$($PlanObject.Address) reason=optimisticFailed targets=$(@($PlanObject.Items).Count) depth=$($PlanObject.Depth)" 'DEBUG' } catch {}
                Add-YakuExcelBulkSplitPlans -Worksheet $Worksheet -Items ([object[]]@($PlanObject.Items)) -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Plans $childPlans -Counters $Counters -StartRow ([int]$PlanObject.StartRow) -EndRow ([int]$PlanObject.EndRow) -Depth ([int]$PlanObject.Depth) -MaxDepth $MaxDepth -MaxProbes $MaxProbes
                foreach ($child in @($childPlans.ToArray())) {
                    Invoke-YakuExcelBulkBandPlanObject -PlanObject $child -Worksheet $Worksheet -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Aggregate $Aggregate -Counters $Counters -VerifyState $VerifyState -MaxDepth $MaxDepth -MaxProbes $MaxProbes
                }
                return
            }

            try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$($PlanObject.Address) reason=optimistic-write-failed targets=$(@($PlanObject.Items).Count)" 'DEBUG' } catch {}
            try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
            $fallbackObj = [pscustomobject]@{ Kind='fallback'; Items=[object[]]@($PlanObject.Items); Address=$PlanObject.Address }
            Invoke-YakuExcelBulkBandPlanObject -PlanObject $fallbackObj -Worksheet $Worksheet -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Aggregate $Aggregate -Counters $Counters -VerifyState $VerifyState -MaxDepth $MaxDepth -MaxProbes $MaxProbes
        } finally {
            try { Release-YakuComObject $plan.Range } catch {}
        }
        return
    }

    try {
        $restoreCount = Get-YakuExcelBulkPlanRestoreCount -Plan $PlanObject
        if ([int]$restoreCount -gt 200) {
            try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$($PlanObject.Address) reason=restore-limit restores=$restoreCount maxRestores=200 mode=$($PlanObject.Mode) targets=$(@($PlanObject.Items).Count)" 'DEBUG' } catch {}
            try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
            $fallbackItems = @()
            try { $fallbackItems = @($PlanObject.Items) } catch { $fallbackItems = @() }
            $fallbackObj = [pscustomobject]@{ Kind='fallback'; Items=[object[]]$fallbackItems; Address=$PlanObject.Address }
            Invoke-YakuExcelBulkBandPlanObject -PlanObject $fallbackObj -Worksheet $Worksheet -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Aggregate $Aggregate -Counters $Counters -VerifyState $VerifyState -MaxDepth $MaxDepth -MaxProbes $MaxProbes
            return
        }
        $writeResult = Invoke-YakuExcelBulkRangeWritePlan -Plan $PlanObject -Worksheet $Worksheet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics
        if ($null -eq $writeResult) {
            $writeFailedTargets = 0
            try { $writeFailedTargets = [int]@($PlanObject.Items).Count } catch { $writeFailedTargets = 0 }
            try { Write-YakuLog "Excel writeback bulk band fallback. sheet=$SheetName address=$($PlanObject.Address) reason=write-failed targets=$writeFailedTargets" 'DEBUG' } catch {}
            try { $Counters['Fallbacks'] = [int]$Counters['Fallbacks'] + 1 } catch {}
            $fallbackItems = @()
            try { $fallbackItems = @($PlanObject.Items) } catch { $fallbackItems = @() }
            $fallbackObj = [pscustomobject]@{ Kind='fallback'; Items=[object[]]$fallbackItems; Address=$PlanObject.Address }
            Invoke-YakuExcelBulkBandPlanObject -PlanObject $fallbackObj -Worksheet $Worksheet -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Aggregate $Aggregate -Counters $Counters -VerifyState $VerifyState -MaxDepth $MaxDepth -MaxProbes $MaxProbes
        } else {
            Add-YakuExcelBulkWriteAggregate -Aggregate $Aggregate -WriteResult $writeResult
        }
    } finally {
        try { Release-YakuComObject $PlanObject.Range } catch {}
    }
}

function Invoke-YakuExcelBulkBandedWrite {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)]$Bounds,
        [AllowNull()][hashtable]$FormulaSet = $null,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [int]$MaxBands = 40,
        [int]$MaxRiskyConstantRestores = 200,
        [int]$MaxBandDepth = 6,
        [int]$MaxBandProbes = 30
    )
    $plans = New-Object System.Collections.Generic.List[object]
    $fontAddresses = New-Object System.Collections.Generic.List[string]
    $bands = @(New-YakuExcelTargetRowBands -Items $Items -MaxGap 5)
    if ($bands.Count -le 0) { return $null }
    if ($bands.Count -gt $MaxBands) {
        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName reason=bands bands=$($bands.Count) maxBands=$MaxBands targets=$($Items.Count)" 'DEBUG' } catch {}
        return $null
    }

    $counters = @{ Probes = 0; Fallbacks = 0; DepthMax = 0 }
    try {
        foreach ($bandInfo in $bands) {
            $bandStart = [int]$bandInfo.StartRow
            $bandEnd = [int]$bandInfo.EndRow
            $bandItems = @(Get-YakuExcelCellItemsInRowRange -Items $Items -StartRow $bandStart -EndRow $bandEnd)
            if ($bandItems.Count -le 0) { continue }
            Add-YakuExcelBulkBandPlansRecursive -Worksheet $Worksheet -Items ([object[]]$bandItems) -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Plans $plans -Counters $counters -StartRow $bandStart -EndRow $bandEnd -Depth 0 -MaxDepth $MaxBandDepth -MaxProbes $MaxBandProbes
        }

        $totalRiskyRestores = 0
        $totalErrorRestores = 0
        foreach ($planObj in @($plans.ToArray())) {
            try {
                if ([string]$planObj.Kind -eq 'bulk') {
                    $totalRiskyRestores += [int]@($planObj.RiskyConstantRestores).Count
                    $totalErrorRestores += [int]@($planObj.ErrorValueRestores).Count
                } elseif ([string]$planObj.Kind -eq 'optimistic') {
                    $totalRiskyRestores += [int]@($planObj.Plan.RiskyConstantRestores).Count
                    $totalErrorRestores += [int]@($planObj.Plan.ErrorValueRestores).Count
                }
            } catch {}
        }
        $totalRestores = [int]($totalRiskyRestores + $totalErrorRestores)
        if ($totalRestores -gt $MaxRiskyConstantRestores) {
            try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName reason=restore-limit riskyConstantRestores=$totalRiskyRestores errorValueRestores=$totalErrorRestores maxRestores=$MaxRiskyConstantRestores mode=value2-banded targets=$($Items.Count)" 'DEBUG' } catch {}
            foreach ($planObj in @($plans.ToArray())) {
                try {
                    if ([string]$planObj.Kind -eq 'bulk') { Release-YakuComObject $planObj.Range }
                    elseif ([string]$planObj.Kind -eq 'optimistic') { Release-YakuComObject $planObj.Plan.Range }
                } catch {}
            }
            return $null
        }

        $preparedBulkBands = 0
        foreach ($planObj in @($plans.ToArray())) {
            try { if ([string]$planObj.Kind -eq 'bulk') { $preparedBulkBands++ } } catch {}
        }

        $aggregate = @{
            Written = 0
            SingleCells = 0
            RiskyTranslationSingles = 0
            RiskyRestoresWritten = 0
            ErrorRestoresWritten = 0
            Rectangles = 0
            BulkBands = 0
            OptimisticBulkBands = 0
            FontAddresses = $fontAddresses
        }
        $verifyState = @{ Done = $false }
        foreach ($planObj in @($plans.ToArray())) {
            Invoke-YakuExcelBulkBandPlanObject -PlanObject $planObj -Worksheet $Worksheet -Bounds $Bounds -FormulaSet $FormulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -Aggregate $aggregate -Counters $counters -VerifyState $verifyState -MaxDepth $MaxBandDepth -MaxProbes $MaxBandProbes
        }
        $written = [int]$aggregate['Written']
        $singleCells = [int]$aggregate['SingleCells']
        $riskyTranslationSingles = [int]$aggregate['RiskyTranslationSingles']
        $riskyRestoresWritten = [int]$aggregate['RiskyRestoresWritten']
        $errorRestoresWritten = [int]$aggregate['ErrorRestoresWritten']
        $rectangles = [int]$aggregate['Rectangles']
        $bulkBands = [int]$aggregate['BulkBands']
        $optimisticBulkBands = [int]$aggregate['OptimisticBulkBands']
        $bandFallbacks = 0
        try { $bandFallbacks = [int]$counters['Fallbacks'] } catch { $bandFallbacks = 0 }
        if ($null -ne $Metrics) {
            try { $Metrics['bulk_box'] = 1 } catch {}
            try {
                if ([int]$optimisticBulkBands -gt 0 -and [int]$bandFallbacks -eq 0 -and [int]$bulkBands -eq [int]$optimisticBulkBands) { $Metrics['bulk_mode'] = 'value2-optimistic' }
                elseif ([int]$optimisticBulkBands -gt 0) { $Metrics['bulk_mode'] = 'value2-optimistic-banded' }
                else { $Metrics['bulk_mode'] = 'value2-banded' }
            } catch {}
            try { $Metrics['bands'] = [int]$bands.Count } catch {}
            try { $Metrics['band_fallbacks'] = [int]$bandFallbacks } catch {}
            try { $Metrics['band_probes'] = [int]$counters['Probes'] } catch {}
            try { $Metrics['band_depth_max'] = [int]$counters['DepthMax'] } catch {}
            try {
                if (-not $Metrics.ContainsKey('single_cells')) { $Metrics['single_cells'] = 0 }
                $Metrics['single_cells'] = [int]$Metrics['single_cells'] + [int]$singleCells
            } catch {}
            try {
                if (-not $Metrics.ContainsKey('risky_constant_restores')) { $Metrics['risky_constant_restores'] = 0 }
                $Metrics['risky_constant_restores'] = [int]$Metrics['risky_constant_restores'] + [int]$riskyRestoresWritten
            } catch {}
            try {
                if (-not $Metrics.ContainsKey('error_value_restores')) { $Metrics['error_value_restores'] = 0 }
                $Metrics['error_value_restores'] = [int]$Metrics['error_value_restores'] + [int]$errorRestoresWritten
            } catch {}
        }
        $modeName = 'value2-banded'
        try {
            if ([int]$optimisticBulkBands -gt 0 -and [int]$bandFallbacks -eq 0 -and [int]$bulkBands -eq [int]$optimisticBulkBands) { $modeName = 'value2-optimistic' }
            elseif ([int]$optimisticBulkBands -gt 0) { $modeName = 'value2-optimistic-banded' }
        } catch {}
        try { Write-YakuLog "Excel writeback bulk box used. sheet=$SheetName targets=$($Items.Count) written=$written area=$($Bounds.Area) mode=$modeName bands=$($bands.Count) bandFallbacks=$bandFallbacks bandProbes=$($counters['Probes']) bandDepthMax=$($counters['DepthMax']) bulkBands=$bulkBands optimisticBulkBands=$optimisticBulkBands preparedBulkBands=$preparedBulkBands riskyConstantRestores=$riskyRestoresWritten errorValueRestores=$errorRestoresWritten riskyTranslationSingles=$riskyTranslationSingles" 'DEBUG' } catch {}
        return [pscustomobject]@{ Used=$true; Written=[int]$written; FontAddresses=[string[]]@($fontAddresses.ToArray()); Address='banded'; Area=[int64]$Bounds.Area; Mode=$modeName; SingleCells=[int]$singleCells; RiskyTranslationSingles=[int]$riskyTranslationSingles; RiskyConstantRestores=[int]$riskyRestoresWritten; ErrorValueRestores=[int]$errorRestoresWritten; Bands=[int]$bands.Count; BandFallbacks=[int]$bandFallbacks; BandProbes=[int]$counters['Probes']; BandDepthMax=[int]$counters['DepthMax']; Rectangles=[int]$rectangles }
    } catch {
        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName reason=exception-banded error=$($_.Exception.Message)" 'DEBUG' } catch {}
        foreach ($planObj in @($plans.ToArray())) {
            try {
                if ([string]$planObj.Kind -eq 'bulk') { Release-YakuComObject $planObj.Range }
                elseif ([string]$planObj.Kind -eq 'optimistic') { Release-YakuComObject $planObj.Plan.Range }
            } catch {}
        }
        return $null
    }
}
function Invoke-YakuExcelBulkBoundingBoxWrite {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Items,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [int]$MaxArea = 50000
    )
    if ($null -eq $Items -or $Items.Count -le 0) { return $null }
    $box = $null
    $address = ''
    $sw = $null
    try {
        if ($null -ne $Metrics) { try { $Metrics['bulk_mode'] = 'fallback' } catch {} }
        if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { try { $SheetName = [string]$Worksheet.Name } catch { $SheetName = '' } }
        $bounds = New-YakuExcelCellItemsBounds -Items $Items
        if ($null -eq $bounds) { return $null }
        if ([int64]$bounds.Area -gt [int64]$MaxArea) {
            try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName reason=size area=$($bounds.Area) maxArea=$MaxArea targets=$($Items.Count)" 'DEBUG' } catch {}
            return $null
        }

        $address = Get-YakuExcelRangeAddress -StartRow ([int]$bounds.MinRow) -StartCol ([int]$bounds.MinCol) -EndRow ([int]$bounds.MaxRow) -EndCol ([int]$bounds.MaxCol)
        if ($null -ne $Metrics) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
        $box = $Worksheet.Range($address)
        if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'range_ms' -Stopwatch $sw }

        $formulaSet = @{}
        if ($null -ne $Metrics) { $sw.Restart() }
        try { $formulaSet = Get-YakuExcelFormulaAddressSet -UsedRange $box -Warnings $Warnings } catch { $formulaSet = $null }
        if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_read_ms' -Stopwatch $sw }
        $formulaStatus = if ($null -eq $formulaSet) { 'unknown' } else { [string]$formulaSet.Count }
        if ($null -eq $formulaSet) {
            try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$address reason=formula-set-unknown formulaCells=unknown targets=$($Items.Count)" 'DEBUG' } catch {}
            return $null
        }

        $mergeCells = $null
        try { $mergeCells = $box.MergeCells } catch { $mergeCells = $null }
        if (-not (Test-YakuExcelComFalse -Value $mergeCells)) {
            try { Write-YakuLog "Excel writeback bulk box optimistic. sheet=$SheetName address=$address reason=merged mergeCells=$mergeCells targets=$($Items.Count)" 'DEBUG' } catch {}
            $optimisticPlan = New-YakuExcelBulkRangeWritePlan -Range $box -Items $Items -FormulaSet $formulaSet -MinRow ([int]$bounds.MinRow) -MinCol ([int]$bounds.MinCol) -RowCount ([int]$bounds.RowCount) -ColCount ([int]$bounds.ColCount) -Address $address -Area ([int64]$bounds.Area) -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics -ForceFormulaPatch
            if ($null -ne $optimisticPlan) {
                $restoreTotal = Get-YakuExcelBulkPlanRestoreCount -Plan $optimisticPlan
                if ([int]$restoreTotal -le 200) {
                    $verifyState = @{ Done = $false }
                    $writeResult = Invoke-YakuExcelOptimisticWritePlan -Plan $optimisticPlan -Worksheet $Worksheet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics -VerifyState $verifyState
                    if ($null -ne $writeResult) {
                        if ($null -ne $Metrics) {
                            try { $Metrics['bulk_box'] = 1 } catch {}
                            try { $Metrics['bulk_mode'] = 'value2-optimistic' } catch {}
                            try {
                                if (-not $Metrics.ContainsKey('single_cells')) { $Metrics['single_cells'] = 0 }
                                $Metrics['single_cells'] = [int]$Metrics['single_cells'] + [int]$writeResult.SingleCells
                            } catch {}
                            try {
                                if (-not $Metrics.ContainsKey('risky_constant_restores')) { $Metrics['risky_constant_restores'] = 0 }
                                $Metrics['risky_constant_restores'] = [int]$Metrics['risky_constant_restores'] + [int]$writeResult.RiskyConstantRestores
                            } catch {}
                            try {
                                if (-not $Metrics.ContainsKey('error_value_restores')) { $Metrics['error_value_restores'] = 0 }
                                $Metrics['error_value_restores'] = [int]$Metrics['error_value_restores'] + [int]$writeResult.ErrorValueRestores
                            } catch {}
                        }
                        $written = [int]$writeResult.Written
                        try { Write-YakuLog "Excel writeback bulk box used. sheet=$SheetName address=$address targets=$($Items.Count) written=$written area=$($bounds.Area) mode=value2-optimistic formulaCells=$($optimisticPlan.FormulaCellCount) riskyConstantRestores=$($writeResult.RiskyConstantRestores) errorValueRestores=$($writeResult.ErrorValueRestores) riskyTranslationSingles=$($writeResult.RiskyTranslationSingles)" 'DEBUG' } catch {}
                        return [pscustomobject]@{ Used=$true; Written=$written; FontAddresses=[string[]]@($writeResult.FontAddresses); Address=$address; Area=[int64]$bounds.Area; Mode='value2-optimistic'; SingleCells=[int]$writeResult.SingleCells; RiskyTranslationSingles=[int]$writeResult.RiskyTranslationSingles; RiskyConstantRestores=[int]$writeResult.RiskyConstantRestores; ErrorValueRestores=[int]$writeResult.ErrorValueRestores; Bands=0; BandFallbacks=0; BandProbes=0; BandDepthMax=0; Rectangles=0 }
                    }
                    $optimisticFailureReason = ''
                    try { if ($Metrics.ContainsKey('optimistic_failed_reason')) { $optimisticFailureReason = [string]$Metrics['optimistic_failed_reason'] } } catch {}
                    if ($optimisticFailureReason -eq 'optimistic verify failed') { return $null }
                } else {
                    try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$address reason=restore-limit riskyConstantRestores=$(@($optimisticPlan.RiskyConstantRestores).Count) errorValueRestores=$(@($optimisticPlan.ErrorValueRestores).Count) maxRestores=200 mode=value2-optimistic targets=$($Items.Count)" 'DEBUG' } catch {}
                }
            }
            try { Write-YakuLog "Excel writeback bulk box banded. sheet=$SheetName address=$address reason=optimisticFailed mergeCells=$mergeCells targets=$($Items.Count)" 'DEBUG' } catch {}
            $bandedResult = Invoke-YakuExcelBulkBandedWrite -Worksheet $Worksheet -Items $Items -Bounds $bounds -FormulaSet $formulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics
            if ($null -ne $bandedResult -and ([bool]$bandedResult.Used)) { return $bandedResult }
            return $null
        }

        $plan = New-YakuExcelBulkRangeWritePlan -Range $box -Items $Items -FormulaSet $formulaSet -MinRow ([int]$bounds.MinRow) -MinCol ([int]$bounds.MinCol) -RowCount ([int]$bounds.RowCount) -ColCount ([int]$bounds.ColCount) -Address $address -Area ([int64]$bounds.Area) -OutputFontName $OutputFontName -SheetName $SheetName -Metrics $Metrics
        if ($null -eq $plan) {
            try { Write-YakuLog "Excel writeback bulk box banded. sheet=$SheetName address=$address reason=plan-null-non-merged targets=$($Items.Count)" 'DEBUG' } catch {}
            $bandedResult = Invoke-YakuExcelBulkBandedWrite -Worksheet $Worksheet -Items $Items -Bounds $bounds -FormulaSet $formulaSet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics
            if ($null -ne $bandedResult -and ([bool]$bandedResult.Used)) { return $bandedResult }
            return $null
        }
        $riskyRestoreCount = 0
        $errorRestoreCount = 0
        try { $riskyRestoreCount = [int]@($plan.RiskyConstantRestores).Count } catch { $riskyRestoreCount = 0 }
        try { $errorRestoreCount = [int]@($plan.ErrorValueRestores).Count } catch { $errorRestoreCount = 0 }
        $totalRestoreCount = [int]($riskyRestoreCount + $errorRestoreCount)
        if ($totalRestoreCount -gt 200) {
            try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$address reason=restore-limit riskyConstantRestores=$riskyRestoreCount errorValueRestores=$errorRestoreCount maxRestores=200 mode=$($plan.Mode) targets=$($Items.Count)" 'DEBUG' } catch {}
            return $null
        }
        $writeResult = Invoke-YakuExcelBulkRangeWritePlan -Plan $plan -Worksheet $Worksheet -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $SheetName -Metrics $Metrics
        if ($null -eq $writeResult) { return $null }
        if ($null -ne $Metrics) {
            try { $Metrics['bulk_box'] = 1 } catch {}
            try { $Metrics['bulk_mode'] = [string]$plan.Mode } catch {}
            try {
                if (-not $Metrics.ContainsKey('single_cells')) { $Metrics['single_cells'] = 0 }
                $Metrics['single_cells'] = [int]$Metrics['single_cells'] + [int]$writeResult.SingleCells
            } catch {}
            try {
                if (-not $Metrics.ContainsKey('risky_constant_restores')) { $Metrics['risky_constant_restores'] = 0 }
                $Metrics['risky_constant_restores'] = [int]$Metrics['risky_constant_restores'] + [int]$writeResult.RiskyConstantRestores
            } catch {}
            try {
                if (-not $Metrics.ContainsKey('error_value_restores')) { $Metrics['error_value_restores'] = 0 }
                $Metrics['error_value_restores'] = [int]$Metrics['error_value_restores'] + [int]$writeResult.ErrorValueRestores
            } catch {}
        }
        $written = [int]$writeResult.Written
        try { Write-YakuLog "Excel writeback bulk box used. sheet=$SheetName address=$address targets=$($Items.Count) written=$written area=$($bounds.Area) mode=$($plan.Mode) formulaCells=$($plan.FormulaCellCount) riskyConstantRestores=$($writeResult.RiskyConstantRestores) errorValueRestores=$($writeResult.ErrorValueRestores) riskyTranslationSingles=$($writeResult.RiskyTranslationSingles)" 'DEBUG' } catch {}
        return [pscustomobject]@{ Used=$true; Written=$written; FontAddresses=[string[]]@($writeResult.FontAddresses); Address=$address; Area=[int64]$bounds.Area; Mode=[string]$plan.Mode; SingleCells=[int]$writeResult.SingleCells; RiskyTranslationSingles=[int]$writeResult.RiskyTranslationSingles; RiskyConstantRestores=[int]$writeResult.RiskyConstantRestores; ErrorValueRestores=[int]$writeResult.ErrorValueRestores; Bands=0; BandFallbacks=0; BandProbes=0; BandDepthMax=0; Rectangles=0 }
    } catch {
        try { Write-YakuLog "Excel writeback bulk box fallback. sheet=$SheetName address=$address reason=exception error=$($_.Exception.Message)" 'DEBUG' } catch {}
        return $null
    } finally {
        Release-YakuComObject $box
    }
}


function Split-YakuExcelRangeAddressChunks {
    # V38: Range union文字列の255文字制限を避けるため、200文字以内に分割する純関数。
    param(
        [AllowNull()][object[]]$Addresses,
        [int]$MaxLength = 200
    )
    $chunks = New-Object System.Collections.Generic.List[object]
    $chunk = New-Object System.Collections.Generic.List[string]
    $chunkLen = 0
    if ($MaxLength -le 0) { $MaxLength = 200 }
    foreach ($addrValue in @($Addresses)) {
        $addr = [string]$addrValue
        if ([string]::IsNullOrWhiteSpace($addr)) { continue }
        if ($chunkLen + $addr.Length + 1 -gt $MaxLength -and $chunk.Count -gt 0) {
            $joined = ($chunk.ToArray() -join ',')
            $chunks.Add([pscustomobject]@{ Addresses=[string[]]@($chunk.ToArray()); Joined=$joined }) | Out-Null
            $chunk = New-Object System.Collections.Generic.List[string]
            $chunkLen = 0
        }
        $chunk.Add($addr) | Out-Null
        $chunkLen += $addr.Length + 1
    }
    if ($chunk.Count -gt 0) {
        $joined = ($chunk.ToArray() -join ',')
        $chunks.Add([pscustomobject]@{ Addresses=[string[]]@($chunk.ToArray()); Joined=$joined }) | Out-Null
    }
    return @($chunks.ToArray())
}

function Invoke-YakuExcelFontUnionApply {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [AllowNull()][object[]]$Addresses,
        [AllowNull()][string]$FontName,
        [AllowNull()][hashtable]$Metrics = $null
    )
    if ([string]::IsNullOrWhiteSpace([string]$FontName)) { return }
    $allAddresses = New-Object System.Collections.Generic.List[string]
    foreach ($addr in @($Addresses)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$addr)) { $allAddresses.Add([string]$addr) | Out-Null }
    }
    if ($allAddresses.Count -le 0) { return }
    $sw = $null
    if ($null -ne $Metrics) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
    try {
        foreach ($chunk in @(Split-YakuExcelRangeAddressChunks -Addresses @($allAddresses.ToArray()) -MaxLength 200)) {
            $joined = ''
            try { $joined = [string]$chunk.Joined } catch { $joined = '' }
            if ([string]::IsNullOrWhiteSpace($joined)) { continue }
            $unionRange = $null
            try {
                $unionRange = $Worksheet.Range($joined)
                $unionRange.Font.Name = [string]$FontName
            } catch {
                foreach ($addr in @($chunk.Addresses)) {
                    $r = $null
                    try {
                        $r = $Worksheet.Range([string]$addr)
                        $r.Font.Name = [string]$FontName
                    } catch {}
                    Release-YakuComObject $r
                }
            } finally {
                Release-YakuComObject $unionRange
            }
        }
    } finally {
        if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'font_ms' -Stopwatch $sw }
    }
}

function Add-YakuExcelCellRectangle {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)]$Rectangle,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][hashtable]$Metrics = $null,
        [switch]$SkipFont
    )
    $range = $null
    $address = ''
    $location = ''
    try {
        $startRow = [int]$Rectangle.StartRow
        $endRow = [int]$Rectangle.EndRow
        $startCol = [int]$Rectangle.StartCol
        $endCol = [int]$Rectangle.EndCol
        $rowCount = [int]($endRow - $startRow + 1)
        $colCount = [int]($endCol - $startCol + 1)
        if ($rowCount -le 0 -or $colCount -le 0) { return 0 }
        if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { try { $SheetName = [string]$Worksheet.Name } catch { $SheetName = '' } }
        $address = Get-YakuExcelRangeAddress -StartRow $startRow -StartCol $startCol -EndRow $endRow -EndCol $endCol
        $location = if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { $address } else { ([string]$SheetName) + '!' + $address }
        $sw = $null
        if ($null -ne $Metrics) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
        $range = $Worksheet.Range($address)
        if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'range_ms' -Stopwatch $sw }
        $rectRows = @($Rectangle.Rows.ToArray())
        if ($rectRows.Count -ne $rowCount) { throw "矩形行数が一致しません。Expected=$rowCount Actual=$($rectRows.Count)" }
        if (-not (Test-YakuExcelWriteRangeHasNoFormula -Range $range)) {
            $guardWritten = 0
            for ($guardRow = 0; $guardRow -lt $rowCount; $guardRow++) {
                $guardValues = [string[]]@($rectRows[$guardRow])
                if ($guardValues.Count -ne $colCount) { throw "矩形列数が一致しません。RowOffset=$guardRow Expected=$colCount Actual=$($guardValues.Count)" }
                for ($guardCol = 0; $guardCol -lt $colCount; $guardCol++) {
                    $guardWritten += [int](Add-YakuExcelCellSingleValue -Worksheet $Worksheet -Row ([int]($startRow + $guardRow)) -Col ([int]($startCol + $guardCol)) -Value ([string]$guardValues[$guardCol]) -OutputFontName $(if ($SkipFont) { '' } else { $OutputFontName }) -Warnings $Warnings -SheetName $SheetName)
                }
            }
            return [int]$guardWritten
        }
        if ($rowCount -eq 1 -and $colCount -eq 1) {
            $first = [string[]]@($rectRows[0])
            if ($first.Count -lt 1) { throw '矩形値が空です。' }
            if ($null -ne $sw) { $sw.Restart() }
            $firstText = [string]$first[0]
            if (Test-YakuExcelCoercionRiskString -Value $firstText) {
                $range.Formula = ("'" + $firstText)
                if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'bulk_write_ms' -Stopwatch $sw }
            } else {
                $range.Value2 = $firstText
                if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'value2_ms' -Stopwatch $sw }
            }
        } else {
            $arr = [System.Array]::CreateInstance([object], $rowCount, $colCount)
            for ($i = 0; $i -lt $rowCount; $i++) {
                $rowValues = [string[]]@($rectRows[$i])
                if ($rowValues.Count -ne $colCount) { throw "矩形列数が一致しません。RowOffset=$i Expected=$colCount Actual=$($rowValues.Count)" }
                for ($j = 0; $j -lt $colCount; $j++) {
                    $arr.SetValue([string]$rowValues[$j], $i, $j)
                }
            }
            if ($null -ne $sw) { $sw.Restart() }
            Set-YakuExcelRangeArrayValue2 -Range $range -Values2D $arr
            if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'value2_ms' -Stopwatch $sw }
        }
        if (-not $SkipFont -and -not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
            if ($null -ne $sw) { $sw.Restart() }
            try { $range.Font.Name = [string]$OutputFontName } catch {}
            if ($null -ne $sw) { Add-YakuExcelMetricElapsed -Metrics $Metrics -Key 'font_ms' -Stopwatch $sw }
        }
        return [int]($rowCount * $colCount)
    } catch {
        $originalError = $_
        if ([string]::IsNullOrWhiteSpace($location)) {
            try {
                $address = Get-YakuExcelRangeAddress -StartRow ([int]$Rectangle.StartRow) -StartCol ([int]$Rectangle.StartCol) -EndRow ([int]$Rectangle.EndRow) -EndCol ([int]$Rectangle.EndCol)
                $location = if ([string]::IsNullOrWhiteSpace([string]$SheetName)) { $address } else { ([string]$SheetName) + '!' + $address }
            } catch { $location = 'unknown-rect' }
        }
        try {
            $fallbackFontName = if ($SkipFont) { '' } else { [string]$OutputFontName }
            $fallbackWritten = [int](Invoke-YakuExcelCellRectangleFallback -Worksheet $Worksheet -Rectangle $Rectangle -OutputFontName $fallbackFontName -Warnings $Warnings -SheetName $SheetName)
            try { Write-YakuLog "Excel rectangle write fallback used. location=$location written=$fallbackWritten errorType=$($originalError.Exception.GetType().Name) error=$($originalError.Exception.Message)" 'DEBUG' } catch {}
            return [int]$fallbackWritten
        } catch {
            $diag = Get-YakuExceptionDetailObject -ErrorRecord $originalError
            $typeName = [string]$diag.ExceptionType
            if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
            Add-YakuWarning -Warnings $Warnings -Category 'writeback-rect' -Location $location -Detail $diag -Message "矩形書き戻しをスキップしました: $location - ${typeName}: $($originalError.Exception.Message)"
            return 0
        }
    } finally {
        Release-YakuComObject $range
    }
}

function New-YakuExcelCellWritePlan {
    param(
        [Parameter(Mandatory=$true)][object[]]$Blocks,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByBlockId
    )
    $rows = @{}
    $cellItems = New-Object System.Collections.Generic.List[object]
    $mergedCellBlocks = New-Object System.Collections.Generic.List[object]
    foreach ($block in @($Blocks)) {
        try {
            if ([string]$block.Meta.Kind -ne 'cell') { continue }
            $id = [string]$block.Id
            if (-not $TranslationByBlockId.ContainsKey($id)) { continue }
            $translation = [string]$TranslationByBlockId[$id]
            if ([string]::IsNullOrWhiteSpace($translation)) { continue }
            $row = [int]$block.Meta.Row
            $col = [int]$block.Meta.Col
            $isMerged = $false
            try { $isMerged = [bool]$block.Meta.Merged } catch { $isMerged = $false }
            if ($isMerged) {
                $mergedCellBlocks.Add($block) | Out-Null
                continue
            }
            $item = [pscustomobject]@{ Row=$row; Col=$col; Translation=$translation; Block=$block }
            if (-not $rows.ContainsKey($row)) { $rows[$row] = New-Object System.Collections.Generic.List[object] }
            $rows[$row].Add($item) | Out-Null
            $cellItems.Add($item) | Out-Null
        } catch {}
    }
    # SingleCellBlocks is kept as an alias for compatibility with older callers/diagnostics.
    return [pscustomobject]@{ Rows=$rows; CellItems=$cellItems; MergedCellBlocks=$mergedCellBlocks; SingleCellBlocks=$mergedCellBlocks }
}

function Write-YakuExcelCellTranslationsForSheet {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][object[]]$Blocks,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByBlockId,
        [AllowNull()][string]$OutputFontName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][hashtable]$Metrics = $null
    )
    if ($null -ne $Metrics) {
        try {
            if (-not $Metrics.ContainsKey('range_ms')) { $Metrics['range_ms'] = 0.0 }
            if (-not $Metrics.ContainsKey('value2_ms')) { $Metrics['value2_ms'] = 0.0 }
            if (-not $Metrics.ContainsKey('font_ms')) { $Metrics['font_ms'] = 0.0 }
            if (-not $Metrics.ContainsKey('bulk_box')) { $Metrics['bulk_box'] = 0 }
            if (-not $Metrics.ContainsKey('bulk_read_ms')) { $Metrics['bulk_read_ms'] = 0.0 }
            if (-not $Metrics.ContainsKey('bulk_write_ms')) { $Metrics['bulk_write_ms'] = 0.0 }
            if (-not $Metrics.ContainsKey('bulk_mode')) { $Metrics['bulk_mode'] = 'fallback' }
            if (-not $Metrics.ContainsKey('single_cells')) { $Metrics['single_cells'] = 0 }
            if (-not $Metrics.ContainsKey('risky_constant_restores')) { $Metrics['risky_constant_restores'] = 0 }
            if (-not $Metrics.ContainsKey('error_value_restores')) { $Metrics['error_value_restores'] = 0 }
            if (-not $Metrics.ContainsKey('bands')) { $Metrics['bands'] = 0 }
            if (-not $Metrics.ContainsKey('band_fallbacks')) { $Metrics['band_fallbacks'] = 0 }
            if (-not $Metrics.ContainsKey('band_probes')) { $Metrics['band_probes'] = 0 }
            if (-not $Metrics.ContainsKey('band_depth_max')) { $Metrics['band_depth_max'] = 0 }
            if (-not $Metrics.ContainsKey('merged_anchor_rectangles')) { $Metrics['merged_anchor_rectangles'] = 0 }
        } catch {}
    }
    $plan = New-YakuExcelCellWritePlan -Blocks $Blocks -TranslationByBlockId $TranslationByBlockId
    $rows = $plan.Rows
    $cellItems = @($plan.CellItems.ToArray())
    $mergedCellBlocks = $plan.MergedCellBlocks
    $mergedCellCount = 0
    try { $mergedCellCount = [int]$mergedCellBlocks.Count } catch { $mergedCellCount = 0 }

    $sheetName = ''
    try { $sheetName = [string]$Worksheet.Name } catch {}
    $written = 0
    $rectangles = @()
    $fontAddresses = New-Object System.Collections.Generic.List[string]
    $usedBulkBox = $false
    $bulkSingleCells = 0
    $bulkRectangles = 0
    $mergedAnchorRectangles = 0

    if ($cellItems.Count -gt 0) {
        $bulkResult = Invoke-YakuExcelBulkBoundingBoxWrite -Worksheet $Worksheet -Items $cellItems -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $sheetName -Metrics $Metrics
        if ($null -ne $bulkResult -and ([bool]$bulkResult.Used)) {
            $usedBulkBox = $true
            $written += [int]$bulkResult.Written
            try { if ($bulkResult.PSObject.Properties.Name -contains 'SingleCells') { $bulkSingleCells = [int]$bulkResult.SingleCells } } catch { $bulkSingleCells = 0 }
            try { if ($bulkResult.PSObject.Properties.Name -contains 'Rectangles') { $bulkRectangles = [int]$bulkResult.Rectangles } } catch { $bulkRectangles = 0 }
            if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
                foreach ($addr in @($bulkResult.FontAddresses)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$addr)) { $fontAddresses.Add([string]$addr) | Out-Null }
                }
            }
        } else {
            $runs = New-Object System.Collections.Generic.List[object]
            foreach ($rowKey in @($rows.Keys | Sort-Object {[int]$_})) {
                $row = [int]$rowKey
                $items = @($rows[$row].ToArray() | Sort-Object Col)
                $run = New-Object System.Collections.Generic.List[object]
                $prevCol = $null
                foreach ($item in $items) {
                    $col = [int]$item.Col
                    if ($null -ne $prevCol -and $col -ne ([int]$prevCol + 1)) {
                        $runItems = @($run.ToArray())
                        if ($runItems.Count -gt 0) {
                            $values = New-Object System.Collections.Generic.List[string]
                            foreach ($ri in $runItems) { $values.Add([string]$ri.Translation) | Out-Null }
                            $runs.Add([pscustomobject]@{ Row=$row; StartCol=[int]$runItems[0].Col; EndCol=[int]$runItems[$runItems.Count - 1].Col; Values=[string[]]@($values.ToArray()) }) | Out-Null
                        }
                        $run = New-Object System.Collections.Generic.List[object]
                    }
                    $run.Add($item) | Out-Null
                    $prevCol = $col
                }
                if ($run.Count -gt 0) {
                    $runItems = @($run.ToArray())
                    $values = New-Object System.Collections.Generic.List[string]
                    foreach ($ri in $runItems) { $values.Add([string]$ri.Translation) | Out-Null }
                    $runs.Add([pscustomobject]@{ Row=$row; StartCol=[int]$runItems[0].Col; EndCol=[int]$runItems[$runItems.Count - 1].Col; Values=[string[]]@($values.ToArray()) }) | Out-Null
                }
            }

            $rectangles = @(Merge-YakuCellRunsToRects -Runs @($runs.ToArray()))
            foreach ($rect in $rectangles) {
                $rectWritten = [int](Add-YakuExcelCellRectangle -Worksheet $Worksheet -Rectangle $rect -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $sheetName -Metrics $Metrics -SkipFont)
                $written += $rectWritten
                if ($rectWritten -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
                    try { $fontAddresses.Add((Get-YakuExcelRangeAddress -StartRow ([int]$rect.StartRow) -StartCol ([int]$rect.StartCol) -EndRow ([int]$rect.EndRow) -EndCol ([int]$rect.EndCol))) | Out-Null } catch {}
                }
            }
        }
    }

    foreach ($block in @($mergedCellBlocks.ToArray())) {
        try {
            $id = [string]$block.Id
            if (-not $TranslationByBlockId.ContainsKey($id)) { continue }
            $translation = [string]$TranslationByBlockId[$id]
            if ([string]::IsNullOrWhiteSpace($translation)) { continue }
            $row = [int]$block.Meta.Row
            $col = [int]$block.Meta.Col
            $rect = New-YakuExcelSingleCellRectangle -Row $row -Col $col -Value $translation
            $rectWritten = [int](Add-YakuExcelCellRectangle -Worksheet $Worksheet -Rectangle $rect -OutputFontName $OutputFontName -Warnings $Warnings -SheetName $sheetName -Metrics $Metrics -SkipFont)
            $written += $rectWritten
            if ($rectWritten -gt 0) {
                $mergedAnchorRectangles++
                if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) {
                    try { $fontAddresses.Add((Get-YakuExcelRangeAddress -StartRow $row -StartCol $col -EndRow $row -EndCol $col)) | Out-Null } catch {}
                }
            }
        } catch {}
    }

    # V38/V39: フォントはアドレス連結（union）でシート単位に近い粒度で一括適用し、矩形ごとの Font.Name COM 呼び出しを削減する。
    if ($fontAddresses.Count -gt 0) {
        Invoke-YakuExcelFontUnionApply -Worksheet $Worksheet -Addresses ([string[]]@($fontAddresses.ToArray())) -FontName $OutputFontName -Metrics $Metrics
    }
    if ($null -ne $Metrics) {
        try {
            $Metrics['rectangles'] = if ($usedBulkBox) { [int]$bulkRectangles } else { [int]$rectangles.Count }
            $Metrics['single_cells'] = if ($usedBulkBox) { [int]$bulkSingleCells } else { 0 }
            if (-not $usedBulkBox) { $Metrics['bulk_mode'] = 'fallback' }
            $Metrics['merged_cells'] = [int]$mergedCellCount
            $Metrics['merged_anchor_rectangles'] = [int]$mergedAnchorRectangles
            $Metrics['written'] = [int]$written
        } catch {}
    }
    return [int]$written
}



function Get-YakuExcelObjectWriteKey {
    param([AllowNull()]$Block)
    try {
        if ($null -eq $Block -or $null -eq $Block.Meta) { return '' }
        $kind = [string]$Block.Meta.Kind
        $sheet = [string]$Block.Meta.Sheet
        if ($kind -eq 'shape') {
            $path = ''
            try { $path = (@($Block.Meta.IndexPath | ForEach-Object { [string]([int]$_) }) -join '.') } catch { $path = '' }
            return ('shape|' + $sheet + '|' + $path)
        }
        if ($kind -eq 'chart') {
            $chartIndex = ''
            $part = ''
            try { $chartIndex = [string]([int]$Block.Meta.ChartIndex) } catch { $chartIndex = [string]$Block.Meta.ChartIndex }
            try { $part = [string]$Block.Meta.Part } catch { $part = '' }
            return ('chart|' + $sheet + '|' + $chartIndex + '|' + $part)
        }
    } catch {}
    return ''
}

function Set-YakuExcelBlockTranslation {
    param(
        [AllowNull()]$Workbook = $null,
        [AllowNull()]$Worksheet = $null,
        [Parameter(Mandatory=$true)]$Block,
        [Parameter(Mandatory=$true)][string]$Translation,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$OutputFontName = ''
    )
    $kind = [string]$Block.Meta.Kind
    try { if (($kind -eq 'shape' -or $kind -eq 'chart') -and [string]$Translation -eq [string]$Block.Text) { return $true } } catch {}
    $sheetName = [string]$Block.Meta.Sheet
    $ws = $null
    $releaseWorksheet = $false
    try {
        if ($null -ne $Worksheet) {
            $ws = $Worksheet
        } else {
            if ($null -eq $Workbook) { throw 'WorkbookまたはWorksheetが指定されていません。' }
            $ws = $Workbook.Worksheets.Item($sheetName)
            $releaseWorksheet = $true
        }
        if ($kind -eq 'cell') {
            $cell = $null
            try {
                $cell = $ws.Cells.Item([int]$Block.Meta.Row, [int]$Block.Meta.Col)
                if (-not (Test-YakuExcelWriteRangeHasNoFormula -Range $cell)) {
                    Add-YakuFormulaWriteBlockedWarning -Warnings $Warnings -Location ([string]$Block.Location) -Translation $Translation
                    return $false
                }
                if (Test-YakuExcelCoercionRiskString -Value $Translation) { $cell.Formula = ("'" + $Translation) }
                else { $cell.Value2 = $Translation }
                if (-not [string]::IsNullOrWhiteSpace([string]$OutputFontName)) { try { $cell.Font.Name = [string]$OutputFontName } catch {} }
            } finally { Release-YakuComObject $cell }
            return $true
        }
        if ($kind -eq 'shape') {
            $path = @($Block.Meta.IndexPath | ForEach-Object { [int]$_ })
            $shape = $null
            $tf = $null
            $textRange = $null
            try {
                $shape = Get-YakuShapeByIndexPath -Worksheet $ws -IndexPath $path
                if ($null -eq $shape) { throw '図形が見つかりません。' }
                $tf = $shape.TextFrame2
                $textRange = $tf.TextRange
                $currentText = $null
                try { $currentText = [string]$textRange.Text } catch { $currentText = $null }
                if ($null -eq $currentText -or [string]$currentText -ne [string]$Translation) {
                    $textRange.Text = $Translation
                } else {
                    try { Write-YakuLog "Excel shape text write skipped because text already matched. location=$($Block.Location)" 'DEBUG' } catch {}
                }
                Set-YakuComTextFontName -TextRange $textRange -FontName $OutputFontName
            } finally {
                Release-YakuComObject $textRange
                Release-YakuComObject $tf
                Release-YakuComObject $shape
            }
            return $true
        }
        if ($kind -eq 'chart') {
            $chartObj = $null
            $chart = $null
            $axis = $null
            $chartTitle = $null
            $axisTitle = $null
            try {
                $chartObj = $ws.ChartObjects().Item([int]$Block.Meta.ChartIndex)
                $chart = $chartObj.Chart
                $part = [string]$Block.Meta.Part
                if ($part -eq 'title') {
                    if (-not $chart.HasTitle) { $chart.HasTitle = $true }
                    $chartTitle = $chart.ChartTitle
                    try { if ([string]$chartTitle.Text -ne [string]$Translation) { $chartTitle.Text = $Translation } } catch { $chartTitle.Text = $Translation }
                    Set-YakuChartTextFontName -TitleObject $chartTitle -FontName $OutputFontName
                } elseif ($part -eq 'axis_category') {
                    $axis = $chart.Axes(1)
                    if (-not $axis.HasTitle) { $axis.HasTitle = $true }
                    $axisTitle = $axis.AxisTitle
                    try { if ([string]$axisTitle.Text -ne [string]$Translation) { $axisTitle.Text = $Translation } } catch { $axisTitle.Text = $Translation }
                    Set-YakuChartTextFontName -TitleObject $axisTitle -FontName $OutputFontName
                } elseif ($part -eq 'axis_value') {
                    $axis = $chart.Axes(2)
                    if (-not $axis.HasTitle) { $axis.HasTitle = $true }
                    $axisTitle = $axis.AxisTitle
                    try { if ([string]$axisTitle.Text -ne [string]$Translation) { $axisTitle.Text = $Translation } } catch { $axisTitle.Text = $Translation }
                    Set-YakuChartTextFontName -TitleObject $axisTitle -FontName $OutputFontName
                }
            } finally {
                Release-YakuComObject $axisTitle
                Release-YakuComObject $chartTitle
                Release-YakuComObject $axis
                Release-YakuComObject $chart
                Release-YakuComObject $chartObj
            }
            return $true
        }
        return $false
    } catch {
        $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
        $typeName = [string]$diag.ExceptionType
        if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
        $category = if ($kind -eq 'shape') { 'writeback-shape' } elseif ($kind -eq 'chart') { 'writeback-chart' } elseif ($kind -eq 'cell') { 'writeback-cell' } else { 'writeback-skip' }
        Add-YakuWarning -Warnings $Warnings -Category $category -Location ([string]$Block.Location) -Detail $diag -Message "書き戻しをスキップしました: $($Block.Location) - ${typeName}: $($_.Exception.Message)"
        return $false
    } finally {
        if ($releaseWorksheet) { Release-YakuComObject $ws }
    }
}


function Test-YakuExcelWorksheetWritebackReady {
    param(
        [Parameter(Mandatory=$true)]$Worksheet,
        [Parameter(Mandatory=$true)][string]$SheetName,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()][string]$Purpose = 'cell'
    )
    $isProtected = $false
    try { $isProtected = [bool]$Worksheet.ProtectContents } catch { $isProtected = $false }
    if (-not $isProtected) { return $true }
    $unprotected = $false
    try { $Worksheet.Unprotect(); $unprotected = -not [bool]$Worksheet.ProtectContents } catch { $unprotected = $false }
    if ($unprotected) {
        try { Write-YakuLog "Writeback sheet '$SheetName' was protected; unprotected temporarily." 'INFO' } catch {}
        return $true
    }
    $message = if ($Purpose -eq 'objects') { "シートが保護されているため図形・グラフ書き戻しをスキップしました: $SheetName（パスワード保護解除不可）" } else { "シートが保護されているため書き戻しをスキップしました: $SheetName（パスワード保護解除不可）" }
    Add-YakuWarning -Warnings $Warnings -Category 'writeback-protected' -Location ([string]$SheetName) -Message $message
    return $false
}

function Set-YakuExcelWritebackProgress {
    param(
        [AllowNull()]$ProgressState,
        [int]$SheetDone,
        [int]$SheetTotal,
        [AllowNull()][string]$SheetName = '',
        [AllowNull()][string]$DetailPrefix = '書き戻し中'
    )
    if ($null -eq $ProgressState) { return }
    Assert-YakuJobNotCancelled -ProgressState $ProgressState
    try {
        $total = [Math]::Max(1, [int]$SheetTotal)
        $done = [Math]::Max(0, [Math]::Min([int]$SheetDone, $total))
        $progress = [int](92 + [Math]::Floor(($done / [double]$total) * 7))
        $label = if ($DetailPrefix -eq '保存中') { '保存中' } else { '書き戻し中' }
        $detail = if ($DetailPrefix -eq '保存中') { '保存中' } else { "訳文を書込中（$done/$total シート目: $SheetName）" }
        if (Get-Command Set-YakuFileTranslationProgress -ErrorAction SilentlyContinue) {
            Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'apply' -Label $label -Progress $progress -Detail $detail -Fields @{ apply_sheet_done=$done; apply_sheet_total=$total; apply_sheet=$SheetName }
        } else {
            $ProgressState['mode'] = 'working'
            $ProgressState['label'] = $label
            $ProgressState['class'] = 'warn'
            $ProgressState['progress'] = $progress
            $ProgressState['detail'] = $detail
            $ProgressState['phase'] = 'apply'
            $ProgressState['apply_sheet_done'] = $done
            $ProgressState['apply_sheet_total'] = $total
            $ProgressState['apply_sheet'] = $SheetName
            $ProgressState['updated_at'] = (Get-Date).ToString('s')
        }
    } catch [System.OperationCanceledException] { throw }
    catch {}
}


function Write-YakuExcelTranslations {
    param(
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][object[]]$Blocks,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByBlockId,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$Settings,
        [AllowNull()][string]$BaselinePath = $null,
        [AllowNull()]$ProgressState = $null,
        [bool]$DraftMarker = $false
    )
    $ctx = $null
    $excel = $null
    $workbook = $null
    $writeTargetCount = 0
    $writtenCount = 0
    try {
        $phaseStarted = Get-Date
        $ctx = New-YakuExcelApplication
        $excel = $ctx.Application
        $openStarted = Get-Date
        $workbook = Open-YakuWorkbookWithManualCalc -Context $ctx -Path $OutputPath -ReadOnly $false
        Assert-YakuExcelWorkbookWritableForOutput -Workbook $workbook
        if (-not [string]::IsNullOrWhiteSpace([string]$BaselinePath)) {
            try {
                $workbook.SaveCopyAs($BaselinePath)
                Write-YakuLog "Validation baseline saved through Excel. path=$BaselinePath" 'INFO'
            } catch {
                try { Write-YakuLog "Validation baseline SaveCopyAs failed; original input will be used. path=$BaselinePath error=$($_.Exception.Message)" 'WARN' } catch {}
            }
        }
        try {
            $openSeconds = [Math]::Round(((Get-Date) - $openStarted).TotalSeconds, 2)
            $phaseSeconds = [Math]::Round(((Get-Date) - $phaseStarted).TotalSeconds, 2)
            Write-YakuLog "Writeback excel open done. seconds=$phaseSeconds openSeconds=$openSeconds" 'INFO'
        } catch {}
        # V64: this is a dedicated Excel instance; do not change the user's COM add-in state.
        $fontName = Get-YakuOutputFontName -Settings $Settings
        $cellBlocksBySheet = @{}
        $otherBlocks = New-Object System.Collections.Generic.List[object]
        foreach ($block in @($Blocks)) {
            $id = [string]$block.Id
            if (-not $TranslationByBlockId.ContainsKey($id)) { continue }
            $translation = [string]$TranslationByBlockId[$id]
            if ([string]::IsNullOrWhiteSpace($translation)) { continue }
            # 原文保持（未翻訳・不足補完失敗など）は値/フォントとも変更しない。
            if ($translation -eq [string]$block.Text) { continue }
            $writeTargetCount++
            $kind = [string]$block.Meta.Kind
            if ($kind -eq 'cell') {
                $sheet = [string]$block.Meta.Sheet
                if (-not $cellBlocksBySheet.ContainsKey($sheet)) { $cellBlocksBySheet[$sheet] = New-Object System.Collections.Generic.List[object] }
                $cellBlocksBySheet[$sheet].Add($block) | Out-Null
            } else {
                $otherBlocks.Add($block) | Out-Null
            }
        }
        $otherBlocksBySheet = @{}
        foreach ($block in @($otherBlocks.ToArray())) {
            try {
                $sheetName = [string]$block.Meta.Sheet
                if ([string]::IsNullOrWhiteSpace($sheetName)) { $sheetName = '' }
                if (-not $otherBlocksBySheet.ContainsKey($sheetName)) { $otherBlocksBySheet[$sheetName] = New-Object System.Collections.Generic.List[object] }
                $otherBlocksBySheet[$sheetName].Add($block) | Out-Null
            } catch {}
        }

        $applySheetTotal = [Math]::Max(1, [int](@($cellBlocksBySheet.Keys).Count + @($otherBlocksBySheet.Keys).Count))
        $applySheetDone = 0
        try {
            Write-YakuLog ("Excel writeback app state. screenUpdating=$($excel.ScreenUpdating) enableEvents=$($excel.EnableEvents) calculation=$($excel.Calculation) formatCondCalc=$($excel.EnableFormatConditionsCalculation) displayStatusBar=$($excel.DisplayStatusBar) visible=$($excel.Visible) interactive=$($excel.Interactive)") 'INFO'
        } catch {}
        try { $excel.ScreenUpdating = $false } catch {}
        try { $excel.EnableEvents = $false } catch {}
        try { $excel.DisplayStatusBar = $false } catch {}
        try { $excel.EnableFormatConditionsCalculation = $false } catch {}
        try { $excel.Calculation = -4135 } catch {} # xlCalculationManual
        try { if ($excel.ActiveWindow) { $excel.ActiveWindow.View = 1 } } catch {} # xlNormalView
        $value2PutProbeDone = $false
        $writeStarted = Get-Date
        foreach ($sheetName in @($cellBlocksBySheet.Keys)) {
            Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
            $ws = $null
            $sheetStarted = Get-Date
            $metrics = @{}
            if (-not $value2PutProbeDone) { $metrics['value2_put_probe_pending'] = $true }
            $sheetWritten = 0
            try {
                $ws = $workbook.Worksheets.Item([string]$sheetName)
            } catch {
                $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
                $typeName = [string]$diag.ExceptionType
                if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-sheet' -Location ([string]$sheetName) -Detail $diag -Message "シート取得に失敗したため書き戻しをスキップしました: $sheetName - ${typeName}: $($_.Exception.Message)"
                $applySheetDone++
                Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
                continue
            }
            if (-not (Test-YakuExcelWorksheetWritebackReady -Worksheet $ws -SheetName ([string]$sheetName) -Warnings $Warnings -Purpose 'cell')) {
                Release-YakuComObject $ws
                $ws = $null
                $applySheetDone++
                Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
                continue
            }
            # V38: 改ページ再計算の抑止。セル書き込みごとの改ページ再計算が1呼び出し数百msの主因になる。
            $oldDisplayPageBreaks = $null
            try { $oldDisplayPageBreaks = [bool]$ws.DisplayPageBreaks } catch { $oldDisplayPageBreaks = $null }
            try { Write-YakuLog "Excel writeback sheet pagebreaks. displayPageBreaks=$oldDisplayPageBreaks" 'DEBUG' } catch {}
            try { $ws.DisplayPageBreaks = $false } catch {}
            try {
                $sheetWritten = [int](Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks @($cellBlocksBySheet[$sheetName].ToArray()) -TranslationByBlockId $TranslationByBlockId -OutputFontName $fontName -Warnings $Warnings -Metrics $metrics)
                $writtenCount += [int]$sheetWritten
            } catch {
                $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
                $typeName = [string]$diag.ExceptionType
                if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-sheet-unexpected' -Location ([string]$sheetName) -Detail $diag -Message "シート書き戻しの予期しない例外です: $sheetName - ${typeName}: $($_.Exception.Message)"
            } finally {
                $seconds = [Math]::Round(((Get-Date) - $sheetStarted).TotalSeconds, 2)
                $rectangles = 0
                $singleCells = 0
                try { if ($metrics.ContainsKey('rectangles')) { $rectangles = [int]$metrics['rectangles'] } } catch {}
                try { if ($metrics.ContainsKey('single_cells')) { $singleCells = [int]$metrics['single_cells'] } } catch {}
                $rangeMs = 0
                $value2Ms = 0
                $fontMs = 0
                $bulkBox = 0
                $bulkReadMs = 0
                $bulkWriteMs = 0
                $bulkMode = 'fallback'
                $riskyConstantRestores = 0
                $errorValueRestores = 0
                $bands = 0
                $bandFallbacks = 0
                $bandProbes = 0
                $bandDepthMax = 0
                $mergedCells = 0
                $mergedAnchors = 0
                $optimisticFailed = 0
                try { if ($metrics.ContainsKey('range_ms')) { $rangeMs = [Math]::Round([double]$metrics['range_ms'], 0) } } catch {}
                try { if ($metrics.ContainsKey('value2_ms')) { $value2Ms = [Math]::Round([double]$metrics['value2_ms'], 0) } } catch {}
                try { if ($metrics.ContainsKey('font_ms')) { $fontMs = [Math]::Round([double]$metrics['font_ms'], 0) } } catch {}
                try { if ($metrics.ContainsKey('bulk_box')) { $bulkBox = [int]$metrics['bulk_box'] } } catch {}
                try { if ($metrics.ContainsKey('bulk_read_ms')) { $bulkReadMs = [Math]::Round([double]$metrics['bulk_read_ms'], 0) } } catch {}
                try { if ($metrics.ContainsKey('bulk_write_ms')) { $bulkWriteMs = [Math]::Round([double]$metrics['bulk_write_ms'], 0) } } catch {}
                try { if ($metrics.ContainsKey('bulk_mode')) { $bulkMode = [string]$metrics['bulk_mode'] } } catch {}
                try { if ($metrics.ContainsKey('risky_constant_restores')) { $riskyConstantRestores = [int]$metrics['risky_constant_restores'] } } catch {}
                try { if ($metrics.ContainsKey('error_value_restores')) { $errorValueRestores = [int]$metrics['error_value_restores'] } } catch {}
                try { if ($metrics.ContainsKey('bands')) { $bands = [int]$metrics['bands'] } } catch {}
                try { if ($metrics.ContainsKey('band_fallbacks')) { $bandFallbacks = [int]$metrics['band_fallbacks'] } } catch {}
                try { if ($metrics.ContainsKey('band_probes')) { $bandProbes = [int]$metrics['band_probes'] } } catch {}
                try { if ($metrics.ContainsKey('band_depth_max')) { $bandDepthMax = [int]$metrics['band_depth_max'] } } catch {}
                try { if ($metrics.ContainsKey('merged_cells')) { $mergedCells = [int]$metrics['merged_cells'] } } catch {}
                try { if ($metrics.ContainsKey('merged_anchor_rectangles')) { $mergedAnchors = [int]$metrics['merged_anchor_rectangles'] } } catch {}
                try { if ($metrics.ContainsKey('optimistic_failed')) { $optimisticFailed = [int]$metrics['optimistic_failed'] } } catch {}
                $msPerCell = if ($sheetWritten -gt 0) { [Math]::Round(($seconds * 1000.0) / [double]$sheetWritten, 2) } else { 0 }
                try { Write-YakuLog "Excel writeback sheet '$sheetName': rectangles=$rectangles singleCells=$singleCells writtenCells=$sheetWritten seconds=$seconds msPerCell=$msPerCell rangeMs=$rangeMs value2Ms=$value2Ms fontMs=$fontMs bulk_box=$bulkBox bulk_mode=$bulkMode bulk_read_ms=$bulkReadMs bulk_write_ms=$bulkWriteMs riskyConstantRestores=$riskyConstantRestores errorValueRestores=$errorValueRestores bands=$bands bandFallbacks=$bandFallbacks bandProbes=$bandProbes bandDepthMax=$bandDepthMax mergedCells=$mergedCells mergedAnchors=$mergedAnchors optimisticFailed=$optimisticFailed" 'INFO' } catch {}
                try { if ($metrics.ContainsKey('value2_put_probe_done') -and [bool]$metrics['value2_put_probe_done']) { $value2PutProbeDone = $true } } catch {}
                try { if ($oldDisplayPageBreaks -eq $true) { $ws.DisplayPageBreaks = $true } } catch {}
                Release-YakuComObject $ws
                $applySheetDone++
                Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
            }
        }
        foreach ($sheetName in @($otherBlocksBySheet.Keys)) {
            Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
            $ws = $null
            $sheetStarted = Get-Date
            $sheetWritten = 0
            try {
                $ws = $workbook.Worksheets.Item([string]$sheetName)
            } catch {
                $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
                $typeName = [string]$diag.ExceptionType
                if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-sheet' -Location ([string]$sheetName) -Detail $diag -Message "シート取得に失敗したため図形・グラフ書き戻しをスキップしました: $sheetName - ${typeName}: $($_.Exception.Message)"
                $applySheetDone++
                Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
                continue
            }
            if (-not (Test-YakuExcelWorksheetWritebackReady -Worksheet $ws -SheetName ([string]$sheetName) -Warnings $Warnings -Purpose 'objects')) {
                Release-YakuComObject $ws
                $ws = $null
                $applySheetDone++
                Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
                continue
            }
            # V38: 改ページ再計算の抑止。図形・グラフ書き戻しでも同じシート変更コストを抑える。
            $oldDisplayPageBreaks = $null
            try { $oldDisplayPageBreaks = [bool]$ws.DisplayPageBreaks } catch { $oldDisplayPageBreaks = $null }
            try { Write-YakuLog "Excel writeback sheet pagebreaks. displayPageBreaks=$oldDisplayPageBreaks" 'DEBUG' } catch {}
            try { $ws.DisplayPageBreaks = $false } catch {}
            try {
                $objectWriteKeys = @{}
                foreach ($block in @($otherBlocksBySheet[$sheetName].ToArray())) {
                    $id = [string]$block.Id
                    if (-not $TranslationByBlockId.ContainsKey($id)) { continue }
                    $objectTranslation = [string]$TranslationByBlockId[$id]
                    $objectKey = Get-YakuExcelObjectWriteKey -Block $block
                    if (-not [string]::IsNullOrWhiteSpace([string]$objectKey) -and $objectWriteKeys.ContainsKey($objectKey)) {
                        if ([string]$objectWriteKeys[$objectKey] -eq $objectTranslation) {
                            try { Write-YakuLog "Excel object write duplicate skipped. sheet=$sheetName key=$objectKey" 'DEBUG' } catch {}
                            $writtenCount++
                            $sheetWritten++
                            continue
                        }
                    }
                    if (Set-YakuExcelBlockTranslation -Worksheet $ws -Block $block -Translation $objectTranslation -Warnings $Warnings -OutputFontName $fontName) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$objectKey)) { $objectWriteKeys[$objectKey] = $objectTranslation }
                        $writtenCount++
                        $sheetWritten++
                    }
                }
            } catch {
                $diag = Get-YakuExceptionDetailObject -ErrorRecord $_
                $typeName = [string]$diag.ExceptionType
                if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'UnknownException' }
                Add-YakuWarning -Warnings $Warnings -Category 'writeback-sheet-unexpected' -Location ([string]$sheetName) -Detail $diag -Message "図形・グラフ書き戻しの予期しない例外です: $sheetName - ${typeName}: $($_.Exception.Message)"
            } finally {
                $seconds = [Math]::Round(((Get-Date) - $sheetStarted).TotalSeconds, 2)
                try { Write-YakuLog "Excel writeback sheet '$sheetName': rectangles=0 singleCells=0 writtenObjects=$sheetWritten seconds=$seconds rangeMs=0 value2Ms=0 fontMs=0 bulk_box=0 bulk_mode=fallback bulk_read_ms=0 bulk_write_ms=0 riskyConstantRestores=0 bands=0 bandFallbacks=0 mergedCells=0 mergedAnchors=0" 'INFO' } catch {}
                try { if ($oldDisplayPageBreaks -eq $true) { $ws.DisplayPageBreaks = $true } } catch {}
                Release-YakuComObject $ws
                $applySheetDone++
                Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetDone -SheetTotal $applySheetTotal -SheetName ([string]$sheetName)
            }
        }
        try { Write-YakuLog "Writeback write phase done. sheets=$applySheetTotal seconds=$([Math]::Round(((Get-Date) - $writeStarted).TotalSeconds, 2))" 'INFO' } catch {}
        if ($DraftMarker) {
            # Mark CAT output inside the workbook without changing cells, print areas,
            # sheet order, or the user's layout. The DRAFT_ filename is the visible marker;
            # this hidden workbook name is the machine-readable in-document marker.
            # CustomDocumentProperties is not exposed reliably by every Office COM build.
            $draftName = $null
            try {
                $existingDraftName = $null
                try {
                    $existingDraftName = $workbook.Names.Item('_YakuLingoArtifactStatus')
                    if ($null -ne $existingDraftName) { $existingDraftName.Delete() | Out-Null }
                } catch {
                    # A source workbook normally has no marker. Absence is expected.
                } finally {
                    if ($null -ne $existingDraftName) { Release-YakuComObject $existingDraftName }
                }
                $draftName = $workbook.Names.Add('_YakuLingoArtifactStatus', '="DRAFT - reviewed translation work; not release approved"', $false)
                if ($null -eq $draftName -or [bool]$draftName.Visible) { throw 'Hidden workbook marker was not created.' }
            } catch {
                throw ('CAT_DRAFT_MARKER_FAILED: Excel内にDRAFT標識を記録できませんでした。' + $_.Exception.Message)
            } finally {
                if ($null -ne $draftName) { Release-YakuComObject $draftName }
            }
        }
        Set-YakuExcelWritebackProgress -ProgressState $ProgressState -SheetDone $applySheetTotal -SheetTotal $applySheetTotal -DetailPrefix '保存中'
        $saveStarted = Get-Date
        Set-YakuExcelAutomaticCalculationForOutput -Application $excel -Workbook $workbook
        $workbook.Save() | Out-Null
        try { Write-YakuLog "Writeback save done. seconds=$([Math]::Round(((Get-Date) - $saveStarted).TotalSeconds, 2))" 'INFO' } catch {}
    } finally {
        $oldCalculation = $null
        $oldCalculateBeforeSave = $null
        $oldScreenUpdating = $null
        $oldEnableEvents = $null
        $oldDisplayStatusBar = $null
        $oldFormatConditionsCalc = $null
        $oldBackgroundChecking = $null
        try { if ($null -ne $ctx) { $oldCalculation = $ctx.OldCalculation } } catch {}
        try { if ($null -ne $ctx) { $oldCalculateBeforeSave = $ctx.OldCalculateBeforeSave } } catch {}
        try { if ($null -ne $ctx) { $oldScreenUpdating = $ctx.OldScreenUpdating } } catch {}
        try { if ($null -ne $ctx) { $oldEnableEvents = $ctx.OldEnableEvents } } catch {}
        try { if ($null -ne $ctx) { $oldDisplayStatusBar = $ctx.OldDisplayStatusBar } } catch {}
        try { if ($null -ne $ctx) { $oldFormatConditionsCalc = $ctx.OldFormatConditionsCalc } } catch {}
        try { if ($null -ne $ctx) { $oldBackgroundChecking = $ctx.OldBackgroundChecking } } catch {}
        $closeStarted = Get-Date
        Close-YakuExcelObjects -Workbook $workbook -Application $excel -Save:$false -OldCalculation $oldCalculation -OldCalculateBeforeSave $oldCalculateBeforeSave -OldScreenUpdating $oldScreenUpdating -OldEnableEvents $oldEnableEvents -OldDisplayStatusBar $oldDisplayStatusBar -OldFormatConditionsCalc $oldFormatConditionsCalc -OldBackgroundChecking $oldBackgroundChecking
        try { Write-YakuLog "Writeback close done. seconds=$([Math]::Round(((Get-Date) - $closeStarted).TotalSeconds, 2))" 'INFO' } catch {}
    }
    try {
        $wbWarnCounts = @{}
        foreach ($w in @($Warnings.ToArray())) {
            $cat = ''
            try { $cat = [string]$w.Category } catch {}
            if ($cat -like 'writeback-*') {
                if (-not $wbWarnCounts.ContainsKey($cat)) { $wbWarnCounts[$cat] = 0 }
                $wbWarnCounts[$cat] = [int]$wbWarnCounts[$cat] + 1
            }
        }
        if ($wbWarnCounts.Keys.Count -gt 0) {
            $parts = @($wbWarnCounts.Keys | Sort-Object | ForEach-Object { "$_=$($wbWarnCounts[$_])" })
            Write-YakuLog "Writeback warning summary: $($parts -join ' ')" 'WARN'
        }
    } catch {}
    $skippedCount = 0
    if ($writtenCount -lt $writeTargetCount -and (Test-YakuIncompleteWarnings -Warnings $Warnings)) { $skippedCount = [int]($writeTargetCount - $writtenCount) }
    return [pscustomobject]@{ WriteTargetCount=[int]$writeTargetCount; WrittenCount=[int]$writtenCount; SkippedCount=[int]$skippedCount }
}

function Write-YakuCsvTranslations {
    param(
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][object[]]$Blocks,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByBlockId,
        [AllowNull()]$Warnings = $null
    )
    $rows = Read-YakuCsvRows -Path $InputPath
    $writeTargetCount = 0
    $writtenCount = 0
    foreach ($block in @($Blocks)) {
        $id = [string]$block.Id
        if (-not $TranslationByBlockId.ContainsKey($id)) { continue }
        $translation = [string]$TranslationByBlockId[$id]
        if ([string]::IsNullOrWhiteSpace($translation)) { continue }
        if ($translation -eq [string]$block.Text) { continue }
        $writeTargetCount++
        $r = [int]$block.Meta.Row - 1
        $c = [int]$block.Meta.Col - 1
        $loc = 'csv!R' + [string]([int]$block.Meta.Row) + 'C' + [string]([int]$block.Meta.Col)
        if ($r -lt 0 -or $r -ge $rows.Count) {
            if ($null -ne $Warnings) { Add-YakuWarning -Warnings $Warnings -Category 'writeback-cell' -Location $loc -Message "CSV書き戻しをスキップしました: $loc - 行インデックスが範囲外です。" }
            continue
        }
        $row = [string[]]$rows[$r]
        if ($c -lt 0 -or $c -ge $row.Length) {
            if ($null -ne $Warnings) { Add-YakuWarning -Warnings $Warnings -Category 'writeback-cell' -Location $loc -Message "CSV書き戻しをスキップしました: $loc - 列インデックスが範囲外です。" }
            continue
        }
        $row[$c] = $translation
        $rows[$r] = $row
        $writtenCount++
    }
    Write-YakuCsvRows -Path $OutputPath -Rows $rows -SourcePath $InputPath
    $skippedCount = 0
    if ($writtenCount -lt $writeTargetCount -and $null -ne $Warnings -and (Test-YakuIncompleteWarnings -Warnings $Warnings)) { $skippedCount = [int]($writeTargetCount - $writtenCount) }
    return [pscustomobject]@{ WriteTargetCount=[int]$writeTargetCount; WrittenCount=[int]$writtenCount; SkippedCount=[int]$skippedCount }
}

function Get-YakuZipEntryBytes {
    param([Parameter(Mandatory=$true)]$Archive, [Parameter(Mandatory=$true)][string]$Name)
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    $memory = New-Object System.IO.MemoryStream
    try { $stream.CopyTo($memory); return ,$memory.ToArray() }
    finally { $memory.Dispose(); $stream.Dispose() }
}

function Get-YakuOpenXmlIntegritySnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()]$ProgressState = $null,
        [AllowNull()][string]$ProgressScope = '出力'
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        # V65: ワークシートXML全体へ跨る正規表現は、数式が少なくセル数が多い
        # シートで巨大なバックトラッキングを起こす。XmlReaderで1回だけ走査し、
        # セル参照・数式属性・数式本文を順次ハッシュする。
        $formulaCount = 0
        $formulaHash = ''
        $normalizedSha = [System.Security.Cryptography.SHA256]::Create()
        $formulaRecords = New-Object System.Collections.Generic.List[object]
        $worksheetEntries = @($archive.Entries | Where-Object { $_.FullName -match '^xl/(?:worksheets|macrosheets)/[^/]+\.xml$' } | Sort-Object FullName)
        $worksheetTotal = [Math]::Max(1, $worksheetEntries.Count)
        $worksheetDone = 0
        $utf8 = New-Object System.Text.UTF8Encoding($false)

        foreach ($entry in $worksheetEntries) {
            Assert-YakuJobNotCancelled -ProgressState $ProgressState
            $worksheetDone++
            if ($null -ne $ProgressState -and (Get-Command Set-YakuFileTranslationProgress -ErrorAction SilentlyContinue)) {
                Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'validating' -Label '検証中' -Progress 99 -Detail ("数式・シート構成を検証中（$ProgressScope $worksheetDone/$worksheetTotal）") -Fields @{}
            }

            $stream = $null
            $reader = $null
            try {
                $readerSettings = New-Object System.Xml.XmlReaderSettings
                $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                $readerSettings.XmlResolver = $null
                $readerSettings.IgnoreComments = $true
                $readerSettings.IgnoreWhitespace = $true
                $stream = $entry.Open()
                $reader = [System.Xml.XmlReader]::Create($stream, $readerSettings)
                $cellReference = ''
                $encodedEntryName = [Convert]::ToBase64String($utf8.GetBytes([string]$entry.FullName))
                $nodeCount = 0

                while ($reader.Read()) {
                    $nodeCount++
                    if (($nodeCount % 50000) -eq 0) {
                        Assert-YakuJobNotCancelled -ProgressState $ProgressState
                        if ($null -ne $ProgressState -and (Get-Command Set-YakuFileTranslationProgress -ErrorAction SilentlyContinue)) {
                            Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'validating' -Label '検証中' -Progress 99 -Detail ("数式・シート構成を検証中（$ProgressScope $worksheetDone/$worksheetTotal）") -Fields @{}
                        }
                    }
                    if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                    if ($reader.LocalName -eq 'c') {
                        $cellReference = [string]$reader.GetAttribute('r')
                        continue
                    }
                    if ($reader.LocalName -ne 'f') { continue }

                    $attributeParts = New-Object System.Collections.Generic.List[string]
                    $formulaType = ''; $formulaSi = ''; $formulaRef = ''
                    if ($reader.HasAttributes) {
                        for ($attributeIndex = 0; $attributeIndex -lt $reader.AttributeCount; $attributeIndex++) {
                            $reader.MoveToAttribute($attributeIndex)
                            $attributeName = [string]$reader.LocalName
                            $attributeValue = [string]$reader.Value
                            if ($attributeName -eq 't') { $formulaType = $attributeValue }
                            elseif ($attributeName -eq 'si') { $formulaSi = $attributeValue }
                            elseif ($attributeName -eq 'ref') { $formulaRef = $attributeValue }
                            $encodedAttributeValue = [Convert]::ToBase64String($utf8.GetBytes($attributeValue))
                            $attributeParts.Add(($attributeName + '=' + $encodedAttributeValue)) | Out-Null
                        }
                        $null = $reader.MoveToElement()
                    }
                    $attributeParts.Sort()
                    $formulaText = ''
                    if (-not $reader.IsEmptyElement) { $formulaText = [string]$reader.ReadElementContentAsString() }
                    $record = $encodedEntryName + '|' + [Convert]::ToBase64String($utf8.GetBytes($cellReference)) + '|' + ($attributeParts.ToArray() -join ';') + '|' + [Convert]::ToBase64String($utf8.GetBytes($formulaText)) + "`n"
                    $recordBytes = $utf8.GetBytes($record)
                    if ($recordBytes.Length -gt 0) { $null = $sha.TransformBlock($recordBytes, 0, $recordBytes.Length, $recordBytes, 0) }
                    $normalizedAttributes = @($attributeParts.ToArray() | Where-Object { $_ -notmatch '^(si|ca|aca|xda|dt2D|dtr)=' })
                    $normalizedFormula = ([string]$formulaText).Trim()
                    $normalizedFormula = $normalizedFormula -replace '(?i)_xlfn\.SINGLE\s*\((.+)\)', '$1'
                    $normalizedFormula = $normalizedFormula -replace '^@', ''
                    $normalizedRecord = $encodedEntryName + '|' + [Convert]::ToBase64String($utf8.GetBytes($cellReference)) + '|' + ($normalizedAttributes -join ';') + '|' + [Convert]::ToBase64String($utf8.GetBytes($normalizedFormula)) + "`n"
                    $normalizedBytes = $utf8.GetBytes($normalizedRecord)
                    if ($normalizedBytes.Length -gt 0) { $null = $normalizedSha.TransformBlock($normalizedBytes, 0, $normalizedBytes.Length, $normalizedBytes, 0) }
                    if ($formulaRecords.Count -lt 200000) { $formulaRecords.Add([pscustomobject]@{ Entry=[string]$entry.FullName; Cell=$cellReference; Formula=$formulaText; Normalized=$normalizedFormula; FormulaType=$formulaType; SharedIndex=$formulaSi; FormulaRef=$formulaRef }) | Out-Null }
                    $formulaCount++
                }
            } finally {
                if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
                if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
            }
        }
        $emptyBytes = New-Object byte[] 0
        $null = $sha.TransformFinalBlock($emptyBytes, 0, 0)
        $formulaHash = (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
        $null = $normalizedSha.TransformFinalBlock($emptyBytes, 0, 0)
        $normalizedFormulaHash = (($normalizedSha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')

        $workbookBytes = Get-YakuZipEntryBytes -Archive $archive -Name 'xl/workbook.xml'
        $sheetNames = New-Object System.Collections.Generic.List[string]
        $definedNames = New-Object System.Collections.Generic.List[string]
        if ($workbookBytes) {
            $memory = [System.IO.MemoryStream]::new([byte[]]$workbookBytes, $false)
            $reader = $null
            try {
                $readerSettings = New-Object System.Xml.XmlReaderSettings
                $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit; $readerSettings.XmlResolver = $null
                $reader = [System.Xml.XmlReader]::Create($memory, $readerSettings)
                while ($reader.Read()) {
                    if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                    if ($reader.LocalName -eq 'sheet') { $sheetNames.Add([string]$reader.GetAttribute('name')) | Out-Null; continue }
                    if ($reader.LocalName -eq 'definedName') {
                        $name = [string]$reader.GetAttribute('name'); $localSheetId = [string]$reader.GetAttribute('localSheetId')
                        $value = if ($reader.IsEmptyElement) { '' } else { [string]$reader.ReadElementContentAsString() }
                        $definedNames.Add($name + '|' + $localSheetId + '|' + $value) | Out-Null
                    }
                }
            } finally { if ($reader) { $reader.Dispose() }; $memory.Dispose() }
        }
        $normalizedDefinedNames = @($definedNames.ToArray() | ForEach-Object { ($_ -replace '\s+', '').Replace('"', "'") } | Sort-Object)
        $macroBytes = Get-YakuZipEntryBytes -Archive $archive -Name 'xl/vbaProject.bin'
        return [pscustomobject]@{
            FormulaCount = $formulaCount
            FormulaSha256 = $formulaHash
            NormalizedFormulaSha256 = $normalizedFormulaHash
            FormulaRecords = @($formulaRecords.ToArray())
            SheetNames = @($sheetNames.ToArray())
            MacroSha256 = if ($macroBytes) { Get-YakuSha256Hex -Bytes $macroBytes } else { '' }
            HasMacro = [bool]($null -ne $macroBytes)
            DefinedNamesSha256 = Get-YakuTextSha256 -Text ($definedNames.ToArray() -join "`n")
            NormalizedDefinedNamesSha256 = Get-YakuTextSha256 -Text ($normalizedDefinedNames -join "`n")
            DefinedNames = @($definedNames.ToArray())
        }
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $normalizedSha) { $normalizedSha.Dispose() }
        $archive.Dispose()
    }
}

function Get-YakuOpenXmlFileInfo {
    param([Parameter(Mandatory=$true)][string]$Path)
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.docx') {
        if (-not (Get-Command Get-YakuWordDocumentInventory -ErrorAction SilentlyContinue)) { throw 'WORD_ADAPTER_NOT_AVAILABLE' }
        $inventory = Get-YakuWordDocumentInventory -Path $Path
        $sample = (@($inventory.Blocks | Select-Object -First 200 | ForEach-Object { [string]$_.Text }) -join "`n")
        $analysis = if (Get-Command Get-YakuDirectionAnalysis -ErrorAction SilentlyContinue) { Get-YakuDirectionAnalysis -Text $sample } else { [pscustomobject]@{ Direction='to_en'; Confidence='low'; Reason='detector-unavailable' } }
        return [pscustomobject]@{
            Kind='word'; Name=[System.IO.Path]::GetFileName($Path); FileName=[System.IO.Path]::GetFileName($Path)
            Extension=$extension; ExcelAvailable=(Test-YakuExcelAvailable)
            Direction=[string]$analysis.Direction; DetectedDirection=[string]$analysis.Direction
            DirectionConfidence=[string]$analysis.Confidence; DirectionReason=[string]$analysis.Reason
            Sheets=@(); SafeMetadataOnly=$true
        }
    }
    $snapshot = Get-YakuOpenXmlIntegritySnapshot -Path $Path
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $sample = ''
        $shared = Get-YakuZipEntryBytes -Archive $archive -Name 'xl/sharedStrings.xml'
        if ($shared) {
            $xml = [System.Text.Encoding]::UTF8.GetString($shared)
            $texts = New-Object System.Collections.Generic.List[string]
            foreach ($m in ([regex]::Matches($xml, '(?is)<t(?:\s[^>]*)?>(.*?)</t>') | Select-Object -First 200)) {
                $texts.Add([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) | Out-Null
            }
            $sample = ($texts.ToArray() -join "`n")
        }
        $analysis = if (Get-Command Get-YakuDirectionAnalysis -ErrorAction SilentlyContinue) { Get-YakuDirectionAnalysis -Text $sample } else { [pscustomobject]@{ Direction='to_en'; Confidence='low'; Reason='detector-unavailable' } }
        $direction = [string]$analysis.Direction
        $sheets = @($snapshot.SheetNames | ForEach-Object { [pscustomobject]@{ Name=[string]$_; UsedRange='-'; ShapeCount=0; ChartCount=0 } })
        return [pscustomobject]@{
            Kind='excel'; Name=[System.IO.Path]::GetFileName($Path); FileName=[System.IO.Path]::GetFileName($Path)
            Extension=[System.IO.Path]::GetExtension($Path).ToLowerInvariant(); ExcelAvailable=(Test-YakuExcelAvailable)
            Direction=$direction; DetectedDirection=$direction
            DirectionConfidence=[string]$analysis.Confidence; DirectionReason=[string]$analysis.Reason
            Sheets=$sheets; SafeMetadataOnly=$true
        }
    } finally { $archive.Dispose() }
}

function Test-YakuOpenXmlCellLooksTranslatedConstant {
    param([Parameter(Mandatory=$true)][string]$Path, [string]$Entry, [string]$Cell)
    if ([string]::IsNullOrWhiteSpace($Entry) -or [string]::IsNullOrWhiteSpace($Cell)) { return $false }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $archive = $null; $stream = $null; $reader = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $zipEntry = $archive.GetEntry($Entry)
        if ($null -eq $zipEntry) { return $false }
        $stream = $zipEntry.Open()
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($stream, $settings)
        $insideTarget = $false
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element -and $reader.LocalName -eq 'c') { $insideTarget = ([string]$reader.GetAttribute('r') -eq $Cell); continue }
            if ($insideTarget -and $reader.NodeType -eq [System.Xml.XmlNodeType]::Element -and ($reader.LocalName -eq 'v' -or $reader.LocalName -eq 't')) {
                $text = [string]$reader.ReadElementContentAsString()
                return [bool]($text -match '[A-Za-z]')
            }
            if ($insideTarget -and $reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement -and $reader.LocalName -eq 'c') { break }
        }
    } catch { return $false } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        if ($null -ne $archive) { try { $archive.Dispose() } catch {} }
    }
    return $false
}

function Test-YakuCandidateOutput {
    param(
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)][string]$CandidatePath,
        [AllowNull()][string]$BaselinePath = $null,
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][object[]]$Blocks,
        [int]$WriteTargetCount,
        [int]$WrittenCount,
        [int]$SkippedCount = 0,
        [bool]$ContentModified = $true,
        [AllowNull()]$ProgressState = $null,
        [switch]$AllowDraftMarker
    )
    $validationStarted = Get-Date
    Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'validating' -Label '検証中' -Progress 99 -Detail '保存したファイルの完全性を検証しています' -Fields @{}
    try { Write-YakuLog "Output validation started. kind=$Kind" 'INFO' } catch {}
    if (!(Test-Path -LiteralPath $CandidatePath -PathType Leaf)) { throw 'OUTPUT_VALIDATION_MISSING: 一時出力がありません。' }
    $size = (Get-Item -LiteralPath $CandidatePath).Length
    if ($size -le 0) { throw 'OUTPUT_VALIDATION_SIZE: 一時出力のファイルサイズが0です。' }
    if (($WriteTargetCount - $SkippedCount) -ne $WrittenCount) { throw "OUTPUT_VALIDATION_WRITE_COUNT: 説明できない書込件数差です。target=$WriteTargetCount skipped=$SkippedCount written=$WrittenCount" }
    if ($Kind -eq 'csv') {
        $inputRows = Read-YakuCsvRows -Path $InputPath
        $outputRows = Read-YakuCsvRows -Path $CandidatePath
        if ($inputRows.Count -ne $outputRows.Count) { throw "OUTPUT_VALIDATION_CSV_ROWS: CSV行数が一致しません。input=$($inputRows.Count) output=$($outputRows.Count)" }
        return [pscustomobject]@{ Reopenable=$true; FormulaCount=0; MacroPreserved=$true; SheetCount=0; FileSize=$size }
    }
    $inputSize = (Get-Item -LiteralPath $InputPath).Length
    if ($inputSize -gt 0 -and $size -lt [int64]($inputSize * 0.25)) { throw 'OUTPUT_VALIDATION_SIZE: 出力サイズが原本に比べて異常に小さいです。' }
    if (-not $ContentModified) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($CandidatePath)
        try { $null = $archive.Entries.Count } finally { $archive.Dispose() }
        try { Write-YakuLog "Output light validation completed. contentModified=false fileSize=$size" 'INFO' } catch {}
        return [pscustomobject]@{ Reopenable=$true; PackageReadable=$true; FormulaCount=0; MacroPreserved=$true; SheetCount=0; FileSize=$size; LightValidation=$true }
    }
    $beforeStarted = Get-Date
    $beforePath = $InputPath
    if (-not [string]::IsNullOrWhiteSpace([string]$BaselinePath) -and (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) { $beforePath = $BaselinePath }
    $before = Get-YakuOpenXmlIntegritySnapshot -Path $beforePath -ProgressState $ProgressState -ProgressScope '原本'
    try { Write-YakuLog "Output validation input snapshot done. formulas=$($before.FormulaCount) sheets=$(@($before.SheetNames).Count) seconds=$([Math]::Round(((Get-Date) - $beforeStarted).TotalSeconds, 2))" 'INFO' } catch {}
    Assert-YakuJobNotCancelled -ProgressState $ProgressState
    $afterStarted = Get-Date
    $after = Get-YakuOpenXmlIntegritySnapshot -Path $CandidatePath -ProgressState $ProgressState -ProgressScope '出力'
    try { Write-YakuLog "Output validation candidate snapshot done. formulas=$($after.FormulaCount) sheets=$(@($after.SheetNames).Count) seconds=$([Math]::Round(((Get-Date) - $afterStarted).TotalSeconds, 2))" 'INFO' } catch {}
    if ($before.FormulaCount -ne $after.FormulaCount -or $before.FormulaSha256 -ne $after.FormulaSha256) {
        $normalizedMatch = ($before.FormulaCount -eq $after.FormulaCount -and [string]$before.NormalizedFormulaSha256 -eq [string]$after.NormalizedFormulaSha256)
        if ($normalizedMatch) {
            Write-YakuLog 'Formula XML representation changed, but normalized formulas are equivalent. category=formula-representation-changed' 'WARN'
        } else {
            $beforeMap = @{}; foreach ($r in @($before.FormulaRecords)) { $beforeMap[([string]$r.Entry + '!' + [string]$r.Cell)] = $r }
            $afterMap = @{}; foreach ($r in @($after.FormulaRecords)) { $afterMap[([string]$r.Entry + '!' + [string]$r.Cell)] = $r }
            $diffCount = 0; $destroyed = 0; $representation = 0; $modified = 0
            foreach ($key in @($beforeMap.Keys + $afterMap.Keys | Sort-Object -Unique)) {
                $b = $beforeMap[$key]; $a = $afterMap[$key]
                $bf = if ($b) { [string]$b.Formula } else { '<missing>' }; $af = if ($a) { [string]$a.Formula } else { '<missing>' }
                if ($bf -ne $af) {
                    $classification = 'modified'
                    if ($b -and -not $a) {
                        $classification = 'destroyed'
                        try {
                            $formulaType = [string]$b.FormulaType
                            $sharedIndex = [string]$b.SharedIndex
                            $formulaRef = [string]$b.FormulaRef
                            if ($formulaType -eq 'shared' -or $formulaType -eq 'array' -or -not [string]::IsNullOrWhiteSpace($sharedIndex) -or -not [string]::IsNullOrWhiteSpace($formulaRef)) { $classification = 'representation' }
                        } catch {}
                    }
                    if ($classification -eq 'destroyed') { $destroyed++ } elseif ($classification -eq 'representation') { $representation++ } else { $modified++ }
                    if ($diffCount -lt 100) { Write-YakuLog "Formula difference. location=$key classification=$classification inputLength=$($bf.Length) outputLength=$($af.Length) translatedConstantHint=$((Test-YakuOpenXmlCellLooksTranslatedConstant -Path $CandidatePath -Entry ([string]$b.Entry) -Cell ([string]$b.Cell)))" 'ERROR' }
                    $diffCount++
                }
            }
            throw "OUTPUT_VALIDATION_FORMULA: 原本と出力の数式が実質的に一致しません。formulaCountInput=$($before.FormulaCount) formulaCountOutput=$($after.FormulaCount) differences=$diffCount destroyed=$destroyed representation=$representation modified=$modified"
        }
    }
    if (($before.SheetNames -join [char]31) -ne ($after.SheetNames -join [char]31)) {
        throw 'OUTPUT_VALIDATION_SHEETS: 原本と出力のシート構成が一致しません。'
    }
    if ([string]$before.DefinedNamesSha256 -ne [string]$after.DefinedNamesSha256) {
        if ([string]$before.NormalizedDefinedNamesSha256 -eq [string]$after.NormalizedDefinedNamesSha256) { Write-YakuLog 'Defined-name representation changed, but normalized values are equivalent.' 'WARN' }
        else {
            $beforeComparable = @($before.DefinedNames | Where-Object { [string]$_ -notmatch '^_YakuLingoArtifactStatus\|' } | ForEach-Object { ($_ -replace '\s+', '').Replace('"', "'") } | Sort-Object)
            $afterComparable = @($after.DefinedNames | Where-Object { [string]$_ -notmatch '^_YakuLingoArtifactStatus\|' } | ForEach-Object { ($_ -replace '\s+', '').Replace('"', "'") } | Sort-Object)
            $draftMarkerPresent = @($after.DefinedNames | Where-Object { [string]$_ -match '^_YakuLingoArtifactStatus\|' }).Count -eq 1
            if ($AllowDraftMarker -and $draftMarkerPresent -and ($beforeComparable -join [char]31) -eq ($afterComparable -join [char]31)) {
                Write-YakuLog 'Defined names differ only by the required CAT DRAFT marker.' 'INFO'
            } else {
            Write-YakuLog "Defined names differ. inputCount=$(@($before.DefinedNames).Count) outputCount=$(@($after.DefinedNames).Count)" 'ERROR'
            throw 'OUTPUT_VALIDATION_DEFINED_NAMES: 定義名の数式が実質的に一致しません。'
            }
        }
    }
    if ($before.HasMacro -and (-not $after.HasMacro -or $before.MacroSha256 -ne $after.MacroSha256)) {
        throw 'OUTPUT_VALIDATION_MACRO: VBAプロジェクトが保持されていません。'
    }
    $expectedSheets = @($Blocks | ForEach-Object { try { [string]$_.Meta.Sheet } catch { '' } } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($sheet in $expectedSheets) { if (@($after.SheetNames) -notcontains $sheet) { throw "OUTPUT_VALIDATION_TARGET_SHEET: 対象シートが出力にありません。" } }
    # この直前に専用ExcelでSave/Close済みであり、ここで別Excelを再起動すると
    # 外部リンクやアドイン待ちで再びハングし得る。再読込はOpen XMLの全シート
    # ストリーム解析で行い、同一ワーカー内で2回目のExcel COM起動はしない。
    try { Write-YakuLog "Output validation completed. formulas=$($after.FormulaCount) sheets=$(@($after.SheetNames).Count) seconds=$([Math]::Round(((Get-Date) - $validationStarted).TotalSeconds, 2))" 'INFO' } catch {}
    return [pscustomobject]@{ Reopenable=$true; PackageReadable=$true; FormulaCount=$after.FormulaCount; MacroPreserved=$true; SheetCount=@($after.SheetNames).Count; FileSize=$size }
}

function Test-YakuIncompleteWarnings {
    param([AllowNull()]$Warnings)
    foreach ($warning in @($Warnings.ToArray())) {
        $category = ''
        try { $category = [string]$warning.Category } catch {}
        if ($category -eq 'extract-timeout' -or $category -eq 'batch-count' -or $category -eq 'untranslated-retained' -or $category -eq 'supplement-pass' -or $category -eq 'sheet-not-found' -or $category -like 'writeback*' -or $category -eq 'formula-cell-write-blocked') { return $true }
    }
    return $false
}

function Get-YakuAvailableOutputPath {
    param([Parameter(Mandatory=$true)][string]$PreferredPath, [switch]$Incomplete)
    $dir = Split-Path -Parent $PreferredPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($PreferredPath)
    $ext = [System.IO.Path]::GetExtension($PreferredPath)
    if ($Incomplete -and -not $base.EndsWith('_INCOMPLETE', [System.StringComparison]::OrdinalIgnoreCase)) { $base += '_INCOMPLETE' }
    $candidate = Join-Path $dir ($base + $ext)
    $i = 2
    while (Test-Path -LiteralPath $candidate) { $candidate = Join-Path $dir ($base + '(' + $i + ')' + $ext); $i++ }
    return $candidate
}

function Write-YakuFileTranslations {
    param(
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][object[]]$Blocks,
        [Parameter(Mandatory=$true)][hashtable]$TranslationByBlockId,
        [Parameter(Mandatory=$true)]$Settings,
        [Parameter(Mandatory=$true)]$Warnings,
        [AllowNull()]$ProgressState = $null,
        [switch]$DraftMarker,
        [switch]$FailOnIncomplete
    )
    $kind = Get-YakuSupportedFileKind -Path $InputPath
    Add-YakuInputReadOnlyNotice -Path $InputPath -Warnings $Warnings
    Assert-YakuJobNotCancelled -ProgressState $ProgressState
    $jobId = [guid]::NewGuid().ToString('N')
    try { if ($ProgressState -and -not [string]::IsNullOrWhiteSpace([string]$ProgressState['id'])) { $jobId = [string]$ProgressState['id'] } } catch {}
    $outputDir = Split-Path -Parent $OutputPath
    $jobDir = Join-Path $outputDir ('.yakulingo-job-' + $jobId)
    $candidatePath = Join-Path $jobDir ([System.IO.Path]::GetFileName($OutputPath))
    $baselinePath = Join-Path $jobDir ('baseline-' + [System.IO.Path]::GetFileName($OutputPath))
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    try {
        $writeResult = $null
        $hasWriteTargets = ($TranslationByBlockId.Count -gt 0)
        if ($kind -eq 'csv') {
            $writeResult = Write-YakuCsvTranslations -InputPath $InputPath -OutputPath $candidatePath -Blocks $Blocks -TranslationByBlockId $TranslationByBlockId -Warnings $Warnings
        } else {
            $copyStarted = Get-Date
            Copy-Item -LiteralPath $InputPath -Destination $candidatePath -Force
            Clear-YakuOutputReadOnlyAttribute -Path $candidatePath | Out-Null
            try { Write-YakuLog "Writeback copy done. seconds=$([Math]::Round(((Get-Date) - $copyStarted).TotalSeconds, 2)) jobId=$jobId" 'INFO' } catch {}
            if ($hasWriteTargets) {
                $writeResult = Write-YakuExcelTranslations -OutputPath $candidatePath -Blocks $Blocks -TranslationByBlockId $TranslationByBlockId -Warnings $Warnings -Settings $Settings -BaselinePath $baselinePath -ProgressState $ProgressState -DraftMarker:$DraftMarker
            } else {
                try { Write-YakuLog "Writeback skipped; no translated blocks. jobId=$jobId" 'INFO' } catch {}
                $writeResult = [pscustomobject]@{ WriteTargetCount=0; WrittenCount=0; SkippedCount=0 }
            }
        }
        Assert-YakuJobNotCancelled -ProgressState $ProgressState
        $skippedCount = 0; try { $skippedCount = [int]$writeResult.SkippedCount } catch {}
        $contentModified = if ($kind -eq 'csv') { $true } else { $hasWriteTargets }
        $validation = Test-YakuCandidateOutput -InputPath $InputPath -CandidatePath $candidatePath -BaselinePath $baselinePath -Kind $kind -Blocks $Blocks -WriteTargetCount ([int]$writeResult.WriteTargetCount) -WrittenCount ([int]$writeResult.WrittenCount) -SkippedCount $skippedCount -ContentModified:$contentModified -ProgressState $ProgressState -AllowDraftMarker:$DraftMarker
        $incomplete = Test-YakuIncompleteWarnings -Warnings $Warnings
        if ($FailOnIncomplete -and $incomplete) { throw 'CAT_EXPORT_WRITE_INCOMPLETE: 一部を書き込めなかったため、DRAFTファイルを公開しませんでした。' }
        Set-YakuFileTranslationProgress -ProgressState $ProgressState -Phase 'publishing' -Label '保存完了処理中' -Progress 99 -Detail '検証済みファイルを出力先へ移動しています' -Fields @{}
        $publishedPath = ''
        for ($publishAttempt = 0; $publishAttempt -lt 100; $publishAttempt++) {
            $nextPath = Get-YakuAvailableOutputPath -PreferredPath $OutputPath -Incomplete:$incomplete
            try { [System.IO.File]::Move($candidatePath, $nextPath); $publishedPath = $nextPath; break }
            catch [System.IO.IOException] { if ($publishAttempt -ge 99) { throw } }
        }
        if ([string]::IsNullOrWhiteSpace($publishedPath)) { throw 'OUTPUT_PUBLISH_COLLISION: 出力ファイル名を確保できませんでした。' }
        try { Write-YakuLog "Output publish completed. status=$(if ($incomplete) { 'completed_with_warnings' } else { 'done' })" 'INFO' } catch {}
        $completionStatus = if ($incomplete) { 'completed_with_warnings' } else { 'done' }
        return [pscustomobject]@{
            WriteTargetCount=[int]$writeResult.WriteTargetCount
            WrittenCount=[int]$writeResult.WrittenCount
            SkippedCount=[int]$skippedCount
            PublishedPath=$publishedPath
            CompletionStatus=$completionStatus
            Validation=$validation
        }
    } catch {
        try { if (Test-Path -LiteralPath $candidatePath -PathType Leaf) { Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue } } catch {}
        throw
    } finally {
        try {
            if (Test-Path -LiteralPath $jobDir -PathType Container) {
                Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction Stop
            }
        } catch { try { Write-YakuLog "Temporary job directory cleanup failed. jobDir=$jobDir error=$($_.Exception.Message)" 'WARN' } catch {} }
    }
}

function Get-YakuFileInfo {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()]$Settings
    )
    # Word はここを通れなかった。取り込みの入口（/api/cat/open と /api/file-info）は
    # 必ずこの関数で訳す向きを見るのに、この関数が Excel と CSV しか知らず
    # 「対応しているファイル形式は .xlsx / .xlsm / .csv です」で止めていた。
    # 画面は .docx を選ばせ、CatProject には Word の分岐（New-YakuCatWordProject）が
    # あるのに、そこへ届いていなかった（2026-08-11、実機で Word を取り込んで発覚）。
    # 本文の取り出しは OpenXML だけで済むので、ここで COM は使わない。
    if (([System.IO.Path]::GetExtension($Path)).ToLowerInvariant() -eq '.docx') {
        $wordName = [System.IO.Path]::GetFileName($Path)
        $inventory = Get-YakuWordDocumentInventory -Path $Path
        $wordSample = New-Object System.Text.StringBuilder
        foreach ($block in @($inventory.Blocks)) {
            if ($wordSample.Length -ge 8000) { break }
            $blockText = [string]$block.Text
            if (-not [string]::IsNullOrWhiteSpace($blockText)) { [void]$wordSample.AppendLine($blockText) }
        }
        $wordAnalysis = if (Get-Command Get-YakuDirectionAnalysis -ErrorAction SilentlyContinue) { Get-YakuDirectionAnalysis -Text ([string]$wordSample.ToString()) } else { [pscustomobject]@{ Direction='to_en'; Confidence='low'; Reason='detector-unavailable' } }
        $wordDirection = [string]$wordAnalysis.Direction
        return [pscustomobject]@{
            Kind='word'; Name=$wordName; FileName=$wordName; Extension='.docx'; ExcelAvailable=(Test-YakuExcelAvailable)
            Direction=$wordDirection; DetectedDirection=$wordDirection
            DirectionConfidence=[string]$wordAnalysis.Confidence; DirectionReason=[string]$wordAnalysis.Reason
            Sheets=@(); Rows=@($inventory.Blocks).Count; Columns=1
        }
    }
    $kind = Get-YakuSupportedFileKind -Path $Path
    Add-YakuInputReadOnlyNotice -Path $Path -Warnings $null
    $name = [System.IO.Path]::GetFileName($Path)
    if ($kind -eq 'csv') {
        $rows = Read-YakuCsvRows -Path $Path
        $maxCols = 0
        $sample = New-Object System.Text.StringBuilder
        foreach ($row in ($rows | Select-Object -First 100)) {
            $arr = @($row)
            if ($arr.Count -gt $maxCols) { $maxCols = $arr.Count }
            foreach ($v in ($arr | Select-Object -First 12)) {
                if ($sample.Length -lt 8000 -and -not [string]::IsNullOrWhiteSpace([string]$v)) { [void]$sample.AppendLine([string]$v) }
            }
        }
        $analysis = if (Get-Command Get-YakuDirectionAnalysis -ErrorAction SilentlyContinue) { Get-YakuDirectionAnalysis -Text ([string]$sample.ToString()) } else { [pscustomobject]@{ Direction='to_en'; Confidence='low'; Reason='detector-unavailable' } }
        $dir = [string]$analysis.Direction
        return [pscustomobject]@{ Kind='csv'; Name=$name; FileName=$name; Extension='.csv'; ExcelAvailable=(Test-YakuExcelAvailable); Direction=$dir; DetectedDirection=$dir; DirectionConfidence=[string]$analysis.Confidence; DirectionReason=[string]$analysis.Reason; Sheets=@(); Rows=$rows.Count; Columns=$maxCols }
    }

    # V64: file-info must never invoke Excel COM on the HTTP server thread.
    return (Get-YakuOpenXmlFileInfo -Path $Path)

    $ctx = $null
    $excel = $null
    $workbook = $null
    $sheets = New-Object System.Collections.Generic.List[object]
    $sampleText = New-Object System.Text.StringBuilder
    try {
        $ctx = New-YakuExcelApplication
        $excel = $ctx.Application
        $workbook = Open-YakuWorkbookWithManualCalc -Context $ctx -Path $Path -ReadOnly $true
        $sheetCount = [int]$workbook.Worksheets.Count
        for ($i = 1; $i -le $sheetCount; $i++) {
            $ws = $null
            $used = $null
            $shapes = $null
            $chartObjects = $null
            try {
                $ws = $workbook.Worksheets.Item($i)
                $used = $ws.UsedRange
                $rows = [int]$used.Rows.Count
                $cols = [int]$used.Columns.Count
                $shapeCount = 0
                try { $shapes = $ws.Shapes; $shapeCount = [int]$shapes.Count } catch {}
                $chartCount = 0
                try { $chartObjects = $ws.ChartObjects(); $chartCount = [int]$chartObjects.Count } catch {}
                $sheets.Add([pscustomobject]@{ Name=[string]$ws.Name; Rows=$rows; Columns=$cols; UsedRange=($rows.ToString() + ' x ' + $cols.ToString()); Shapes=$shapeCount; ShapeCount=$shapeCount; Charts=$chartCount; ChartCount=$chartCount }) | Out-Null
                if ($sampleText.Length -lt 8000) {
                    try {
                        $values = $used.Value2
                        $sampleRows = [Math]::Min(20, $rows)
                        $sampleCols = [Math]::Min(12, $cols)
                        for ($r = 1; $r -le $sampleRows; $r++) {
                            for ($c = 1; $c -le $sampleCols; $c++) {
                                $v = Get-YakuRangeArrayValue -Values $values -RowOffset $r -ColOffset $c
                                if ($v -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$v)) { [void]$sampleText.AppendLine([string]$v) }
                            }
                        }
                    } catch {}
                }
            } finally {
                Release-YakuComObject $chartObjects
                Release-YakuComObject $shapes
                Release-YakuComObject $used
                Release-YakuComObject $ws
            }
        }
    } finally {
        Close-YakuExcelObjects -Workbook $workbook -Application $excel -Save:$false -OldCalculation $ctx.OldCalculation -OldCalculateBeforeSave $ctx.OldCalculateBeforeSave -OldScreenUpdating $ctx.OldScreenUpdating -OldEnableEvents $ctx.OldEnableEvents -OldDisplayStatusBar $ctx.OldDisplayStatusBar -OldFormatConditionsCalc $ctx.OldFormatConditionsCalc -OldBackgroundChecking $ctx.OldBackgroundChecking
    }
    $direction = if (Get-Command Get-YakuDirection -ErrorAction SilentlyContinue) { Get-YakuDirection -Text ([string]$sampleText.ToString()) } else { 'to_en' }
    return [pscustomobject]@{ Kind='excel'; Name=$name; FileName=$name; Extension=([System.IO.Path]::GetExtension($Path)); ExcelAvailable=(Test-YakuExcelAvailable); Direction=$direction; DetectedDirection=$direction; Sheets=@($sheets.ToArray()) }
}
