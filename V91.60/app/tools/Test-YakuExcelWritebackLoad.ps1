<#
.SYNOPSIS
  Excel 書き戻しの COM 負荷を下げる変更の回帰テスト（Excel 不要）。

.DESCRIPTION
  セルを辞書で持つ偽のワークシートで、書き戻しが呼ぶ COM 相当の操作を数える。
  - 単一セルのアドレス列を、同じセル集合を覆う矩形にまとめること（フォント一括適用の前処理）
  - 外接矩形が上限を超えるシートを、上限内の行区画に分けること
  - 楽観書込の検証を、セルごとの Cells.Item ではなく範囲の1回読み戻しで行うこと
  - 大きなシートでも訳文・非対象セル・数式セル・フォントが正しく、COM 呼び出し数が小さいこと
  - 区画ごとに進捗（心拍）を更新すること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuExcelWritebackLoad.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuWb {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}
$src = Join-Path $root 'src'
. (Join-Path $src 'Paths.ps1')
. (Join-Path $src 'Runtime.ps1')
. (Join-Path $src 'Html.ps1')
. (Join-Path $src 'FileProcessors.ps1')
function Write-YakuLog { param($Message, $Level) }

# ---- 偽ワークシート -------------------------------------------------------
function ConvertFrom-YakuTestA1 {
    param([string]$Address)
    $rects = New-Object System.Collections.Generic.List[object]
    foreach ($part in ($Address -split ',')) {
        $m = [regex]::Match($part.Trim(), '^([A-Z]+)([0-9]+)(?::([A-Z]+)([0-9]+))?$')
        if (-not $m.Success) { throw "bad address: $part" }
        $toCol = { param($s) $n = 0; foreach ($ch in $s.ToCharArray()) { $n = ($n * 26) + ([int]$ch - 64) }; $n }
        $r1 = [int]$m.Groups[2].Value; $c1 = [int](& $toCol $m.Groups[1].Value)
        $r2 = $r1; $c2 = $c1
        if ($m.Groups[3].Success) { $r2 = [int]$m.Groups[4].Value; $c2 = [int](& $toCol $m.Groups[3].Value) }
        $rects.Add([pscustomobject]@{ R1=[Math]::Min($r1,$r2); R2=[Math]::Max($r1,$r2); C1=[Math]::Min($c1,$c2); C2=[Math]::Max($c1,$c2) }) | Out-Null
    }
    return ,$rects.ToArray()
}

function New-YakuTestSheet {
    param([string]$Name = 'S')
    $state = [pscustomobject]@{
        Values = @{}; Formulas = @{}; Fonts = @{}
        Calls = @{ Range = 0; CellsItem = 0; Value2Get = 0; Value2Set = 0; FormulaGet = 0; FontSet = 0; HasFormula = 0; MergeCells = 0 }
    }
    $sheet = [pscustomobject]@{ Name = $Name; State = $state }
    $sheet | Add-Member -MemberType ScriptMethod -Name Range -Value {
        param($address)
        $this.State.Calls.Range++
        return (New-YakuTestRange -State $this.State -Rects (ConvertFrom-YakuTestA1 -Address ([string]$address)))
    }
    $cells = [pscustomobject]@{ State = $state }
    $cells | Add-Member -MemberType ScriptMethod -Name Item -Value {
        param($row, $col)
        $this.State.Calls.CellsItem++
        return (New-YakuTestRange -State $this.State -Rects @([pscustomobject]@{ R1=[int]$row; R2=[int]$row; C1=[int]$col; C2=[int]$col }))
    }
    $sheet | Add-Member -MemberType NoteProperty -Name Cells -Value $cells
    return $sheet
}

function New-YakuTestRange {
    param($State, [object[]]$Rects)
    $first = $Rects[0]
    $range = [pscustomobject]@{
        State = $State; Rects = $Rects
        Row = [int]$first.R1; Column = [int]$first.C1
        Rows = [pscustomobject]@{ Count = [int]($first.R2 - $first.R1 + 1) }
        Columns = [pscustomobject]@{ Count = [int]($first.C2 - $first.C1 + 1) }
        MergeCells = $false
    }
    $range | Add-Member -MemberType ScriptMethod -Name Address -Value { param($a, $b) return 'R' + $this.Row + 'C' + $this.Column }
    $range | Add-Member -MemberType ScriptProperty -Name HasFormula -Value {
        $this.State.Calls.HasFormula++
        $any = $false; $all = $true
        foreach ($r in $this.Rects) { for ($i = $r.R1; $i -le $r.R2; $i++) { for ($j = $r.C1; $j -le $r.C2; $j++) { if ($this.State.Formulas.ContainsKey("$i,$j")) { $any = $true } else { $all = $false } } } }
        if (-not $any) { return $false }
        if ($all) { return $true }
        return $null
    }
    $getGrid = {
        param($range, [bool]$formula)
        $r = $range.Rects[0]
        $rows = [int]($r.R2 - $r.R1 + 1); $cols = [int]($r.C2 - $r.C1 + 1)
        $read = {
            param($i, $j)
            $key = "$i,$j"
            if ($formula -and $range.State.Formulas.ContainsKey($key)) { return $range.State.Formulas[$key] }
            if ($range.State.Values.ContainsKey($key)) { return $range.State.Values[$key] }
            if ($formula) { return '' }
            return $null
        }
        if ($rows -eq 1 -and $cols -eq 1) { return (& $read $r.R1 $r.C1) }
        $arr = [System.Array]::CreateInstance([object], [int[]]@($rows, $cols), [int[]]@(1, 1))
        for ($i = 0; $i -lt $rows; $i++) { for ($j = 0; $j -lt $cols; $j++) { $arr.SetValue((& $read ($r.R1 + $i) ($r.C1 + $j)), ($i + 1), ($j + 1)) } }
        return ,$arr
    }
    $range | Add-Member -MemberType NoteProperty -Name GetGrid -Value $getGrid
    $range | Add-Member -MemberType ScriptProperty -Name Value2 -Value {
        $this.State.Calls.Value2Get++
        # 2次元配列を1要素のまま返す（返り値の展開で1次元に潰れないように）。
        return ,(& $this.GetGrid $this $false)
    } -SecondValue {
        param($value)
        $this.State.Calls.Value2Set++
        $r = $this.Rects[0]
        if ($value -is [System.Array]) {
            $rb = $value.GetLowerBound(0); $cb = $value.GetLowerBound(1)
            for ($i = $r.R1; $i -le $r.R2; $i++) { for ($j = $r.C1; $j -le $r.C2; $j++) {
                if ($this.State.Formulas.ContainsKey("$i,$j")) { throw "formula overwritten at R${i}C${j}" }
                $v = $value.GetValue(($rb + $i - $r.R1), ($cb + $j - $r.C1))
                if ($null -eq $v) { $this.State.Values.Remove("$i,$j") } else { $this.State.Values["$i,$j"] = $v }
            } }
        } else {
            for ($i = $r.R1; $i -le $r.R2; $i++) { for ($j = $r.C1; $j -le $r.C2; $j++) {
                if ($this.State.Formulas.ContainsKey("$i,$j")) { throw "formula overwritten at R${i}C${j}" }
                $this.State.Values["$i,$j"] = $value
            } }
        }
    }
    $range | Add-Member -MemberType ScriptProperty -Name Formula -Value {
        $this.State.Calls.FormulaGet++
        return ,(& $this.GetGrid $this $true)
    } -SecondValue {
        param($value)
        $r = $this.Rects[0]
        $text = [string]$value
        if ($text.StartsWith("'")) { $this.State.Values["$($r.R1),$($r.C1)"] = $text.Substring(1) } else { $this.State.Values["$($r.R1),$($r.C1)"] = $text }
    }
    $font = [pscustomobject]@{ Range = $range }
    $font | Add-Member -MemberType ScriptProperty -Name Name -Value { return '' } -SecondValue {
        param($value)
        $owner = $this.Range
        $owner.State.Calls.FontSet++
        foreach ($r in $owner.Rects) { for ($i = $r.R1; $i -le $r.R2; $i++) { for ($j = $r.C1; $j -le $r.C2; $j++) { $owner.State.Fonts["$i,$j"] = [string]$value } } }
    }
    $range | Add-Member -MemberType NoteProperty -Name Font -Value $font
    return $range
}

function Expand-YakuTestAddresses {
    param([object[]]$Addresses)
    $set = @{}
    foreach ($a in @($Addresses)) { foreach ($r in (ConvertFrom-YakuTestA1 -Address ([string]$a))) { for ($i = $r.R1; $i -le $r.R2; $i++) { for ($j = $r.C1; $j -le $r.C2; $j++) { $set["$i,$j"] = $true } } } }
    return $set
}
function Test-YakuTestSameSet {
    param([hashtable]$A, [hashtable]$B)
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k)) { return $false } }
    return $true
}

# ---- CASE 1 --------------------------------------------------------------
Write-Host 'CASE 1: 単一セルのアドレス列を矩形にまとめる（覆うセルは同じ）'
$singles = New-Object System.Collections.Generic.List[string]
for ($r = 2; $r -le 101; $r++) { foreach ($c in @(2, 3, 4, 7)) { $singles.Add((Get-YakuExcelRangeAddress -StartRow $r -StartCol $c -EndRow $r -EndCol $c)) } }
$compressed = @(Compress-YakuExcelCellAddresses -Addresses $singles.ToArray())
Assert-YakuWb ($compressed.Count -eq 2) "400 セル → 2 矩形 (got $($compressed.Count): $($compressed -join ','))"
Assert-YakuWb (($compressed -contains 'B2:D101') -and ($compressed -contains 'G2:G101')) '矩形は B2:D101 と G2:G101'
$rng = New-Object System.Random 42
$randomSet = New-Object System.Collections.Generic.List[string]
for ($k = 0; $k -lt 600; $k++) { $rr = $rng.Next(1, 60); $cc = $rng.Next(1, 30); $randomSet.Add((Get-YakuExcelRangeAddress -StartRow $rr -StartCol $cc -EndRow $rr -EndCol $cc)) }
$randomSet.Add('AA5:AC9'); $randomSet.Add('B3')
$randomCompressed = @(Compress-YakuExcelCellAddresses -Addresses $randomSet.ToArray())
Assert-YakuWb (Test-YakuTestSameSet (Expand-YakuTestAddresses $randomSet.ToArray()) (Expand-YakuTestAddresses $randomCompressed)) "ランダムなセル集合でも覆うセルが一致する ($($randomSet.Count) → $($randomCompressed.Count))"
Assert-YakuWb ($randomCompressed -contains 'AA5:AC9') '矩形アドレスはそのまま残す'
Assert-YakuWb (@(Compress-YakuExcelCellAddresses -Addresses @()).Count -eq 0) '空なら空を返す'

# ---- CASE 2 --------------------------------------------------------------
Write-Host 'CASE 2: 外接矩形が上限を超える項目を、上限内の行区画に分ける'
$items = New-Object System.Collections.Generic.List[object]
for ($r = 1; $r -le 3000; $r++) { foreach ($c in @(1, 5, 20)) { $items.Add([pscustomobject]@{ Row=$r; Col=$c; Translation="t$r-$c" }) } }
$chunks = @(Split-YakuExcelCellItemsByArea -Items $items.ToArray() -MaxArea 50000)
Assert-YakuWb ($chunks.Count -ge 2) "3000x20 (60,000) は複数区画になる (chunks=$($chunks.Count))"
$total = 0; $areaOk = $true; $prevMax = 0; $orderOk = $true
foreach ($ch in $chunks) {
    $ch = @($ch); $total += $ch.Count
    $b = New-YakuExcelCellItemsBounds -Items $ch
    if ([int64]$b.Area -gt 50000) { $areaOk = $false }
    if ([int]$b.MinRow -le $prevMax) { $orderOk = $false }
    $prevMax = [int]$b.MaxRow
}
Assert-YakuWb ($total -eq $items.Count) "全項目がちょうど1回ずつ区画に入る ($total/$($items.Count))"
Assert-YakuWb $areaOk '各区画の外接矩形は上限以下'
Assert-YakuWb $orderOk '区画は行で重ならない'
$small = @(Split-YakuExcelCellItemsByArea -Items @($items.ToArray() | Select-Object -First 30) -MaxArea 50000)
Assert-YakuWb ($small.Count -eq 1 -and @($small[0]).Count -eq 30) '上限内なら1区画のまま（従来と同じ動き）'

# ---- CASE 3 --------------------------------------------------------------
Write-Host 'CASE 3: 楽観書込の検証は範囲の1回読み戻しで行う'
$ws = New-YakuTestSheet
$bulkItems = New-Object System.Collections.Generic.List[object]
for ($r = 1; $r -le 50; $r++) { for ($c = 1; $c -le 4; $c++) { $ws.State.Values["$r,$c"] = "en$r-$c"; $bulkItems.Add([pscustomobject]@{ Row=$r; Col=$c; Translation="en$r-$c" }) } }
$plan = [pscustomobject]@{ Range=$ws.Range('A1:D50'); Address='A1:D50'; BulkItems=[object[]]$bulkItems.ToArray(); StartRow=1; MinCol=1; RowCount=50; ColCount=4 }
$ws.State.Calls.CellsItem = 0; $ws.State.Calls.Value2Get = 0
Assert-YakuWb (Test-YakuExcelBulkWriteFirstTarget -Worksheet $ws -Plan $plan -SheetName 'S') '一致すれば true'
Assert-YakuWb ($ws.State.Calls.CellsItem -eq 0 -and $ws.State.Calls.Value2Get -eq 1) "Cells.Item=0, Value2 読み=1 (got Cells.Item=$($ws.State.Calls.CellsItem) Value2=$($ws.State.Calls.Value2Get))"
$ws.State.Values['37,3'] = 'different'
Assert-YakuWb (-not (Test-YakuExcelBulkWriteFirstTarget -Worksheet $ws -Plan $plan -SheetName 'S')) '1セルでも違えば false'
$ws.State.Values['37,3'] = "en37-3`r`nx"; $bulkItems[146].Translation = "en37-3`nx"
Assert-YakuWb (Test-YakuExcelBulkWriteFirstTarget -Worksheet $ws -Plan $plan -SheetName 'S') '改行コードの違いは従来どおり同一とみなす'
$single = [pscustomobject]@{ Range=$ws.Range('B2'); Address='B2'; BulkItems=@([pscustomobject]@{ Row=2; Col=2; Translation='en2-2' }); StartRow=2; MinCol=2; RowCount=1; ColCount=1 }
Assert-YakuWb (Test-YakuExcelBulkWriteFirstTarget -Worksheet $ws -Plan $single -SheetName 'S') '1x1 の範囲（スカラー読み戻し）も照合できる'
$legacy = [pscustomobject]@{ Range=$ws.Range('A1:D50'); Address='A1:D50'; BulkItems=@([pscustomobject]@{ Row=3; Col=1; Translation='en3-1' }) }
$ws.State.Calls.CellsItem = 0
Assert-YakuWb ((Test-YakuExcelBulkWriteFirstTarget -Worksheet $ws -Plan $legacy -SheetName 'S') -and $ws.State.Calls.CellsItem -eq 1) '形状情報が無い計画はセル単位の照合に戻る'

# ---- CASE 4 --------------------------------------------------------------
Write-Host 'CASE 4: 大きなシートの書き戻し（訳文・非対象セル・数式・フォント・COM 呼び出し数）'
$ws = New-YakuTestSheet -Name 'Big'
$blocks = New-Object System.Collections.Generic.List[object]
$translations = @{}
$rowsTotal = 3000; $colsTotal = 20
for ($r = 1; $r -le $rowsTotal; $r++) {
    for ($c = 1; $c -le $colsTotal; $c++) {
        $key = "$r,$c"
        if (($c % 4) -eq 1) {
            $ws.State.Values[$key] = "原文$r-$c"
            $id = "b$r-$c"
            $blocks.Add([pscustomobject]@{ Id=$id; Text="原文$r-$c"; Meta=[pscustomobject]@{ Kind='cell'; Sheet='Big'; Row=$r; Col=$c } })
            $translations[$id] = "Source $r-$c"
        } elseif ($c -eq 2) {
            $ws.State.Values[$key] = [double]($r * 10)
        } elseif ($c -eq 3) {
            $ws.State.Values[$key] = "keep$r"
        }
    }
}
# 数式セル（列 16 の一部。対象の外接矩形の内側）は値も数式も変わってはいけない。
foreach ($r in @(10, 1500, 2999)) { $ws.State.Formulas["$r,16"] = "=B$r*2"; $ws.State.Values["$r,16"] = [double]($r * 20) }
$warnings = New-Object System.Collections.Generic.List[object]
$metrics = @{}
$script:chunkCalls = New-Object System.Collections.Generic.List[string]
$onChunk = { param($done, $total) $script:chunkCalls.Add("$done/$total") }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$written = Write-YakuExcelCellTranslationsForSheet -Worksheet $ws -Blocks $blocks.ToArray() -TranslationByBlockId $translations -OutputFontName 'Arial' -Warnings $warnings -Metrics $metrics -OnChunkDone $onChunk
$sw.Stop()
Assert-YakuWb ([int]$written -eq $blocks.Count) "書込件数 = 対象数 ($written/$($blocks.Count))"
$textOk = $true; $fontOk = $true; $otherOk = $true
foreach ($b in $blocks) { $k = "$($b.Meta.Row),$($b.Meta.Col)"; if ([string]$ws.State.Values[$k] -cne [string]$translations[$b.Id]) { $textOk = $false }; if ($ws.State.Fonts[$k] -ne 'Arial') { $fontOk = $false } }
for ($r = 1; $r -le $rowsTotal; $r++) {
    if ([double]$ws.State.Values["$r,2"] -ne [double]($r * 10)) { $otherOk = $false }
    if ([string]$ws.State.Values["$r,3"] -cne "keep$r") { $otherOk = $false }
    if ($ws.State.Fonts.ContainsKey("$r,2") -or $ws.State.Fonts.ContainsKey("$r,3")) { $otherOk = $false }
}
foreach ($r in @(10, 1500, 2999)) { if ($ws.State.Formulas["$r,16"] -ne "=B$r*2" -or [double]$ws.State.Values["$r,16"] -ne [double]($r * 20)) { $otherOk = $false } }
Assert-YakuWb $textOk '全ターゲットに訳文が入る'
Assert-YakuWb $fontOk '全ターゲットに出力フォントが付く'
Assert-YakuWb $otherOk '非対象セル・数式セルは値もフォントも変わらない'
Assert-YakuWb ([int]$metrics['chunks'] -ge 2) "区画に分けて一括書込する (chunks=$($metrics['chunks']) chunkFallbacks=$($metrics['chunk_fallbacks']) mode=$($metrics['bulk_mode']))"
$calls = $ws.State.Calls
Write-Host ("       calls: Range=$($calls.Range) Cells.Item=$($calls.CellsItem) Value2Get=$($calls.Value2Get) Value2Set=$($calls.Value2Set) FontSet=$($calls.FontSet) HasFormula=$($calls.HasFormula) seconds=$([Math]::Round($sw.Elapsed.TotalSeconds, 1))")
Assert-YakuWb ($calls.CellsItem -eq 0) "セル単位の Cells.Item 呼び出しが無い (got $($calls.CellsItem))"
Assert-YakuWb ($calls.Value2Set -le 20) "Value2 書込は区画・帯の数程度 (got $($calls.Value2Set), 対象 $($blocks.Count) セル)"
Assert-YakuWb ($calls.FontSet -le 10) "Font.Name 設定は矩形にまとめた union の数程度 (got $($calls.FontSet))"
Assert-YakuWb ($script:chunkCalls.Count -eq [int]$metrics['chunks'] -and $script:chunkCalls[$script:chunkCalls.Count - 1] -eq "$($metrics['chunks'])/$($metrics['chunks'])") "区画ごとに進捗コールバックが呼ばれる ($($script:chunkCalls -join ' '))"

# ---- CASE 5 --------------------------------------------------------------
Write-Host 'CASE 5: 区画の進捗は心拍（updated_at）と詳細を更新する'
$progress = @{ id = 'job'; mode = 'working' }
Set-YakuExcelWritebackProgress -ProgressState $progress -SheetDone 0 -SheetTotal 2 -SheetName 'Big' -ChunkDone 3 -ChunkTotal 5
Assert-YakuWb ([string]$progress['detail'] -like '*区画 3/5*') "詳細に区画が出る ($($progress['detail']))"
Assert-YakuWb (-not [string]::IsNullOrWhiteSpace([string]$progress['updated_at'])) 'updated_at が更新される'
Set-YakuExcelWritebackProgress -ProgressState $progress -SheetDone 1 -SheetTotal 2 -SheetName 'Big'
Assert-YakuWb ([string]$progress['detail'] -notlike '*区画*') '区画なしの呼び出しは従来の表示'

# ---- CASE 6 --------------------------------------------------------------
Write-Host 'CASE 6: Write-YakuExcelTranslations 全体（Excel は偽物）で、区画の心拍とキャンセルが届く'
function New-YakuTestBigBlocks {
    param($Sheet, [int]$Rows)
    $list = New-Object System.Collections.Generic.List[object]; $map = @{}
    for ($r = 1; $r -le $Rows; $r++) { foreach ($c in @(1, 30)) {
        $Sheet.State.Values["$r,$c"] = "原文$r-$c"; $id = "$($Sheet.Name)-$r-$c"
        $list.Add([pscustomobject]@{ Id=$id; Text="原文$r-$c"; Meta=[pscustomobject]@{ Kind='cell'; Sheet=$Sheet.Name; Row=$r; Col=$c } }); $map[$id] = "Source $r-$c"
    } }
    return [pscustomobject]@{ Blocks=$list.ToArray(); Map=$map }
}
$script:fakeSheet = New-YakuTestSheet -Name 'Big'
$script:fakeSheet | Add-Member -MemberType NoteProperty -Name ProtectContents -Value $false
$script:fakeSheet | Add-Member -MemberType NoteProperty -Name DisplayPageBreaks -Value $false
$fakeWorksheets = [pscustomobject]@{}
$fakeWorksheets | Add-Member -MemberType ScriptMethod -Name Item -Value { param($name) return $script:fakeSheet }
$script:fakeWorkbook = [pscustomobject]@{ Worksheets = $fakeWorksheets }
$script:fakeWorkbook | Add-Member -MemberType ScriptMethod -Name Save -Value { }
$script:fakeWorkbook | Add-Member -MemberType ScriptMethod -Name SaveCopyAs -Value { param($p) }
function New-YakuExcelApplication { return [pscustomobject]@{ Application = [pscustomobject]@{ ScreenUpdating=$true; EnableEvents=$true; DisplayStatusBar=$true; EnableFormatConditionsCalculation=$true; Calculation=-4105; ActiveWindow=$null; Visible=$false; Interactive=$false } } }
function Open-YakuWorkbookWithManualCalc { param($Context, $Path, $ReadOnly) return $script:fakeWorkbook }
function Assert-YakuExcelWorkbookWritableForOutput { param($Workbook) }
function Set-YakuExcelAutomaticCalculationForOutput { param($Application, $Workbook) }
function Close-YakuExcelObjects { param($Workbook, $Application, [switch]$Save, $OldCalculation, $OldCalculateBeforeSave, $OldScreenUpdating, $OldEnableEvents, $OldDisplayStatusBar, $OldFormatConditionsCalc, $OldBackgroundChecking) }
function Get-YakuOutputFontName { param($Settings) return 'Arial' }

# 30 列 x 2000 行 = 60,000 > 50,000 なので 2 区画になる。
$data = New-YakuTestBigBlocks -Sheet $script:fakeSheet -Rows 2000
$progressState = @{ id = 'job6'; mode = 'working' }
$script:details = New-Object System.Collections.Generic.List[string]
$origSetProgress = ${function:Set-YakuExcelWritebackProgress}
function Set-YakuExcelWritebackProgress {
    param($ProgressState, [int]$SheetDone, [int]$SheetTotal, [AllowNull()][string]$SheetName = '', [AllowNull()][string]$DetailPrefix = '書き戻し中', [int]$ChunkDone = 0, [int]$ChunkTotal = 0)
    & $origSetProgress -ProgressState $ProgressState -SheetDone $SheetDone -SheetTotal $SheetTotal -SheetName $SheetName -DetailPrefix $DetailPrefix -ChunkDone $ChunkDone -ChunkTotal $ChunkTotal
    if ($null -ne $ProgressState) { $script:details.Add([string]$ProgressState['detail']) }
}
$warnings = New-Object System.Collections.Generic.List[object]
$result = Write-YakuExcelTranslations -OutputPath 'fake.xlsx' -Blocks $data.Blocks -TranslationByBlockId $data.Map -Warnings $warnings -Settings $null -ProgressState $progressState
Assert-YakuWb ([int]$result.WrittenCount -eq $data.Blocks.Count -and [int]$result.WriteTargetCount -eq $data.Blocks.Count) "書込件数が一致する ($($result.WrittenCount)/$($result.WriteTargetCount))"
Assert-YakuWb (@($script:details | Where-Object { $_ -like '*区画 1/2*' }).Count -ge 1 -and @($script:details | Where-Object { $_ -like '*区画 2/2*' }).Count -ge 1) "区画ごとの進捗が ProgressState に届く ($((@($script:details | Where-Object { $_ -like '*区画*' })) -join ' | '))"
Assert-YakuWb ($warnings.Count -eq 0) "警告なし (got $($warnings.Count))"

$script:fakeSheet = New-YakuTestSheet -Name 'Big'
$script:fakeSheet | Add-Member -MemberType NoteProperty -Name ProtectContents -Value $false
$script:fakeSheet | Add-Member -MemberType NoteProperty -Name DisplayPageBreaks -Value $false
$data = New-YakuTestBigBlocks -Sheet $script:fakeSheet -Rows 2000
$cancelPath = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-cancel-' + [guid]::NewGuid().ToString('N'))
$progressState = @{ id = 'job6b'; mode = 'working'; cancel_path = $cancelPath }
function Set-YakuExcelWritebackProgress {
    param($ProgressState, [int]$SheetDone, [int]$SheetTotal, [AllowNull()][string]$SheetName = '', [AllowNull()][string]$DetailPrefix = '書き戻し中', [int]$ChunkDone = 0, [int]$ChunkTotal = 0)
    # 1区画目を書き終えた時点でキャンセルを要求する。
    if ($ChunkDone -eq 1) { Set-Content -LiteralPath $cancelPath -Value 'x' }
    & $origSetProgress -ProgressState $ProgressState -SheetDone $SheetDone -SheetTotal $SheetTotal -SheetName $SheetName -DetailPrefix $DetailPrefix -ChunkDone $ChunkDone -ChunkTotal $ChunkTotal
}
$warnings = New-Object System.Collections.Generic.List[object]
$cancelled = $false
try { Write-YakuExcelTranslations -OutputPath 'fake.xlsx' -Blocks $data.Blocks -TranslationByBlockId $data.Map -Warnings $warnings -Settings $null -ProgressState $progressState | Out-Null }
catch [System.OperationCanceledException] { $cancelled = $true }
finally { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
Assert-YakuWb $cancelled 'シート途中のキャンセルは警告に化けず、そのまま止まる'
Assert-YakuWb (@($warnings | Where-Object { [string]$_.Category -eq 'writeback-sheet-unexpected' }).Count -eq 0) 'writeback-sheet-unexpected 警告を出さない'
Set-Item -Path function:Set-YakuExcelWritebackProgress -Value $origSetProgress

if ($script:Failures -gt 0) { Write-Host "Excel writeback load regression FAILED ($script:Failures)" -ForegroundColor Red; exit 1 }
Write-Host 'Excel writeback load regression passed.'
