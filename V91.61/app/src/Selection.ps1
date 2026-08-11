# 選択範囲の読み取り。Ctrl+Alt+J を押した瞬間に、利用者が選んでいるものを取る。
#
# 2026-08-11 に実測した結果、対象ごとに手段が違う。
#   Word / Excel : Office COM で取れる（Word は UI Automation では TextPattern を
#                  1つも公開しない。深さ9まで探索して0個だった）
#   PowerPoint   : COM で取れる。しかも疑似 Ctrl+C では足りない（2026-08-12 実測）
#                    図形を選んだとき: クリップボードに文字が入らない（何も読めない）
#                    文字を選んだとき: 読める
#                  スライドは枠を1回クリックして選ぶのが普通なので、Ctrl+C だけでは
#                  いちばんよくある選び方でまったく読めなかった
#   Outlook      : COM を使わない。理由は Selection.ps1 の Get-YakuForegroundSelection に書く
#   それ以外     : COM が無い。C# 側が疑似 Ctrl+C を送り、クリップボードから読む
#
# ここは Office の COM 経路だけを持つ。クリップボードには触れない。
#
# 守ること（決定_ちょっと翻訳と資料翻訳の分離_2026-08-10.md の 2026-08-11 追記）
#   - 利用者の Office を閉じない。設定も変えない。読むだけ
#   - 前面の窓と同じインスタンスであることを Application.Hwnd で照合する。
#     GetActiveObject は実行中オブジェクトテーブルの先頭を返すので、Excel を
#     複数起動していると別ブックを掴む。掴んだまま訳すと利用者は気づけない
#   - 読んだ本文はディスクへ書かない（QuickArtifact.ps1 と同じ守り方）

# Set-StrictMode はここに書かない。Server.ps1 がドットソースで読み込むため、
# このファイルの設定がサーバ全体に及び、未定義変数の参照が例外になって
# バックエンドが起動しなくなる（2026-08-11 に実際に起こした）。

# 一度に扱う上限。超えたら切り詰めずに、資料翻訳のファイル取り込みへ案内する。
$script:YakuSelectionMaxChars = 2000
$script:YakuSelectionMaxCells = 200

function Get-YakuOfficeApplication {
    <# 起動中の Office を掴む。無ければ $null。新しく起動しない。 #>
    param([Parameter(Mandatory=$true)][ValidateSet('Word.Application','Excel.Application','PowerPoint.Application')][string]$ProgId)
    try { return [Runtime.InteropServices.Marshal]::GetActiveObject($ProgId) } catch { return $null }
}

if (-not ('YakuWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class YakuWin32 {
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    public static int ProcessIdOf(IntPtr hWnd) { int pid = 0; GetWindowThreadProcessId(hWnd, out pid); return pid; }
}
'@
}

function Get-YakuOfficeWindowHandle {
    <# 窓のハンドルの取り方が Office 製品ごとに違う。Excel は Application.Hwnd を
       持つが、Word は持たず ActiveWindow.Hwnd になる。しかも Word の ActiveWindow は
       本文の窓で、前面にいる OpusApp（枠の窓）とは別のハンドルになる。 #>
    param([Parameter(Mandatory=$true)]$Application)
    try { $h = [int]$Application.Hwnd; if ($h -gt 0) { return $h } } catch {}
    try { $h = [int]$Application.ActiveWindow.Hwnd; if ($h -gt 0) { return $h } } catch {}
    return 0
}

function Test-YakuOfficeInstanceMatchesWindow {
    <# 掴んだインスタンスが、前面の窓と同じ「プロセス」かを確かめる。違えば読まない。
       別インスタンスを探しに行くこともしない（間違えたときの被害＝別ブックを訳して
       気づけない、が大きく、正しさを示しにくいため）。

       ハンドルの一致ではなくプロセスIDの一致で見る。Word は枠の窓と本文の窓で
       ハンドルが違うため、ハンドル比較では常に不一致になる（2026-08-11 実測）。 #>
    param([Parameter(Mandatory=$true)]$Application, [int]$ForegroundHwnd = 0)
    if ($ForegroundHwnd -le 0) { return $false }
    $appHwnd = Get-YakuOfficeWindowHandle -Application $Application
    if ($appHwnd -le 0) { return $false }
    try {
        $appPid = [YakuWin32]::ProcessIdOf([IntPtr]$appHwnd)
        $fgPid  = [YakuWin32]::ProcessIdOf([IntPtr]$ForegroundHwnd)
        return ($appPid -gt 0 -and $appPid -eq $fgPid)
    } catch { return $false }
}

function Get-YakuWordSelection {
    param([int]$ForegroundHwnd = 0)
    $app = Get-YakuOfficeApplication -ProgId 'Word.Application'
    if ($null -eq $app) { return [pscustomobject]@{ Kind='none'; Reason='word_not_running' } }
    try {
        if (-not (Test-YakuOfficeInstanceMatchesWindow -Application $app -ForegroundHwnd $ForegroundHwnd)) {
            return [pscustomobject]@{ Kind='none'; Reason='instance_mismatch' }
        }
        $text = ''
        try { $text = [string]$app.Selection.Text } catch { return [pscustomobject]@{ Kind='none'; Reason='not_a_selection' } }
        # Word は選択が無くてもキャレット位置の1文字（改行など）を返すことがある。
        $text = $text -replace "", "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ Kind='none'; Reason='no_text' } }
        if ($text.Length -gt $script:YakuSelectionMaxChars) {
            return [pscustomobject]@{ Kind='too_large'; Reason='too_large'; CharCount=$text.Length; DocumentName=[string]$app.ActiveDocument.Name }
        }
        # 保存先と保存状態も返す。あとで「この文書を丸ごと取り込む」を出すため。
        # ディスクの中身を読むので、未保存のまま取り込むと画面の文と違うものから
        # DRAFT を作ってしまう。黙って古い内容を訳さないよう、状態を持って帰る。
        return [pscustomobject]@{
            Kind='word_text'; Text=$text; CharCount=$text.Length
            DocumentName=$(try { [string]$app.ActiveDocument.Name } catch { '' })
            DocumentPath=$(try { [string]$app.ActiveDocument.FullName } catch { '' })
            Saved=$(try { [bool]$app.ActiveDocument.Saved } catch { $false })
        }
    } finally { Release-YakuComObject $app }
}

function Get-YakuExcelSelection {
    param([int]$ForegroundHwnd = 0)
    $app = Get-YakuOfficeApplication -ProgId 'Excel.Application'
    if ($null -eq $app) { return [pscustomobject]@{ Kind='none'; Reason='excel_not_running' } }
    $sel = $null; $wb = $null
    try {
        if (-not (Test-YakuOfficeInstanceMatchesWindow -Application $app -ForegroundHwnd $ForegroundHwnd)) {
            return [pscustomobject]@{ Kind='none'; Reason='instance_mismatch' }
        }
        try { $sel = $app.Selection } catch { return [pscustomobject]@{ Kind='none'; Reason='not_a_range' } }
        $areas = 0
        try { $areas = [int]$sel.Areas.Count } catch { return [pscustomobject]@{ Kind='none'; Reason='not_a_range' } }
        if ($areas -ne 1) { return [pscustomobject]@{ Kind='none'; Reason='multi_area' } }
        $count = 0
        try { $count = [int]$sel.Count } catch { return [pscustomobject]@{ Kind='none'; Reason='not_a_range' } }
        if ($count -gt $script:YakuSelectionMaxCells) {
            return [pscustomobject]@{ Kind='too_large'; Reason='too_large'; CellCount=$count
                WorkbookPath=$(try { [string]$app.ActiveWorkbook.FullName } catch { '' }) }
        }
        $wb = $app.ActiveWorkbook
        $cells = New-Object System.Collections.ArrayList
        $chars = 0; $formulaSkipped = 0
        foreach ($c in $sel) {
            $formula = ''
            try { $formula = [string]$c.Formula } catch { $formula = '' }
            # 数式セルは訳さない。Value2 は計算結果なので、訳して戻すと数式が壊れる。
            if ($formula.StartsWith('=')) { $formulaSkipped++; Release-YakuComObject $c; continue }
            $t = ''
            try { $t = [string]$c.Text } catch { $t = '' }
            $addr = ''
            try { $addr = [string]$c.Address($false, $false) } catch { $addr = '' }
            Release-YakuComObject $c
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $chars += $t.Length
            $null = $cells.Add([pscustomobject]@{ Address=$addr; Text=$t })
        }
        if ($cells.Count -eq 0) { return [pscustomobject]@{ Kind='none'; Reason='no_text'; FormulaSkipped=$formulaSkipped } }
        if ($chars -gt $script:YakuSelectionMaxChars) {
            return [pscustomobject]@{ Kind='too_large'; Reason='too_large'; CharCount=$chars
                WorkbookPath=$(try { [string]$wb.FullName } catch { '' }) }
        }
        return [pscustomobject]@{
            Kind='excel_cells'; Cells=@($cells.ToArray()); CellCount=$cells.Count; CharCount=$chars
            FormulaSkipped=$formulaSkipped
            WorkbookName=$(try { [string]$wb.Name } catch { '' })
            WorkbookPath=$(try { [string]$wb.FullName } catch { '' })
            Saved=$(try { [bool]$wb.Saved } catch { $false })
            SheetName=$(try { [string]$app.ActiveSheet.Name } catch { '' })
            Address=$(try { [string]$sel.Address($false, $false) } catch { '' })
        }
    } finally {
        Release-YakuComObject $sel
        Release-YakuComObject $wb
        Release-YakuComObject $app
    }
}

function Test-YakuPowerPointInstanceMatchesWindow {
    <# PowerPoint だけ、窓のハンドルでは照合できない。実測（2026-08-12）で、
       同じ PowerPoint でも取り方によって Application.HWND の値が変わった。

         Marshal::GetActiveObject('PowerPoint.Application') → HWND = 0
         VisualBasic::GetObject(...)                        → HWND = 7931482

       どちらも Name=Microsoft PowerPoint / Version=16.0 の正しい Application である。
       ハンドルが 0 で返る以上、Word・Excel と同じ照合はできない。

       PowerPoint は1プロセスで全ての窓を持つ（Excel のように複数プロセスへ
       分かれない）ので、「前面の窓が POWERPNT のプロセスか」で同一性が言える。
       ただし万一2つ以上動いていたら、どれを掴んだか言えないので読まない。 #>
    param([int]$ForegroundHwnd = 0)
    if ($ForegroundHwnd -le 0) { return $false }
    $fgPid = 0
    try { $fgPid = [YakuWin32]::ProcessIdOf([IntPtr]$ForegroundHwnd) } catch { return $false }
    if ($fgPid -le 0) { return $false }
    $procs = @(Get-Process -Name 'POWERPNT' -ErrorAction SilentlyContinue)
    if ($procs.Count -ne 1) { return $false }
    return ([int]$procs[0].Id -eq [int]$fgPid)
}

function Get-YakuPowerPointSelection {
    <# スライドの選択を読む。図形を選んだ状態（枠を1回クリック）と、枠の中で文字を
       選んだ状態の両方を扱う。前者は疑似 Ctrl+C では文字が取れない（2026-08-12 実測）。 #>
    param([int]$ForegroundHwnd = 0)
    $app = Get-YakuOfficeApplication -ProgId 'PowerPoint.Application'
    if ($null -eq $app) { return [pscustomobject]@{ Kind='none'; Reason='powerpoint_not_running' } }
    $win = $null; $sel = $null
    try {
        if (-not (Test-YakuPowerPointInstanceMatchesWindow -ForegroundHwnd $ForegroundHwnd)) {
            return [pscustomobject]@{ Kind='none'; Reason='instance_mismatch' }
        }
        try { $win = $app.ActiveWindow } catch { return [pscustomobject]@{ Kind='none'; Reason='no_active_window' } }
        try { $sel = $win.Selection } catch { return [pscustomobject]@{ Kind='none'; Reason='not_a_selection' } }
        $type = 0
        try { $type = [int]$sel.Type } catch { $type = 0 }
        $parts = New-Object System.Collections.Generic.List[string]
        $shapeCount = 0
        if ($type -eq 3) {
            # 文字を選んでいる
            try { $t = [string]$sel.TextRange.Text; if (-not [string]::IsNullOrWhiteSpace($t)) { $parts.Add($t) | Out-Null } } catch {}
        } elseif ($type -eq 2) {
            # 図形を選んでいる。文字を持つ図形だけを、選んだ順に読む
            try {
                foreach ($shape in @($sel.ShapeRange)) {
                    $shapeCount++
                    $text = ''
                    try { if ([bool]$shape.TextFrame.HasText) { $text = [string]$shape.TextFrame.TextRange.Text } } catch { $text = '' }
                    if (-not [string]::IsNullOrWhiteSpace($text)) { $parts.Add($text) | Out-Null }
                    Release-YakuComObject $shape
                }
            } catch {}
        } else {
            return [pscustomobject]@{ Kind='none'; Reason='not_a_selection' }
        }
        if ($parts.Count -lt 1) { return [pscustomobject]@{ Kind='none'; Reason='no_text' } }
        $joined = ($parts.ToArray() -join "`n")
        # PowerPoint の改行は CR。そのままでは1行に見えるので、ほかと同じ改行へ揃える。
        $joined = $joined -replace "`r`n", "`n" -replace "`r", "`n"
        if ($joined.Length -gt $script:YakuSelectionMaxChars) {
            return [pscustomobject]@{ Kind='too_large'; Reason='too_large'; CharCount=$joined.Length }
        }
        return [pscustomobject]@{
            Kind='powerpoint_text'; Text=$joined; CharCount=$joined.Length
            ShapeCount=$(if ($type -eq 2) { $shapeCount } else { 0 })
            PresentationName=$(try { [string]$win.Presentation.Name } catch { '' })
            SlideIndex=$(try { [int]$win.View.Slide.SlideIndex } catch { 0 })
        }
    } finally {
        Release-YakuComObject $sel
        Release-YakuComObject $win
        Release-YakuComObject $app
    }
}

function Get-YakuForegroundSelection {
    <# 前面の窓のクラス名で読み方を決める。
         OpusApp      = Word
         XLMAIN       = Excel
         PPTFrameClass= PowerPoint
       それ以外はここでは扱わない（C# 側が疑似 Ctrl+C で取る）。

       Outlook をここに入れないのは、実測（2026-08-12）で次が分かったため。
         - 読んでいるメール（閲覧ウィンドウ）の文字選択を返す COM は無い。
           Explorer が返すのは「選んだメール（item）」で、選択した文字ではない
         - 新しい Outlook（Microsoft.OutlookForWindows）は COM を持たない。
           この PC には従来版と新版の両方が入っている
         - COM の MAPI へ触ると固まることがある。実際に GetNamespace('MAPI') 経由で
           受信箱を取ろうとして応答が返らず、2分で打ち切った。選択の読み取りは
           HTTP 要求の中で同期に走るので、ここで固まるとアプリ全体が止まる
       疑似 Ctrl+C は Outlook でそのまま効く。危ない道を増やす理由がない。 #>
    param(
        [Parameter(Mandatory=$true)][string]$WindowClass,
        [int]$ForegroundHwnd = 0
    )
    switch ($WindowClass) {
        'OpusApp'       { return Get-YakuWordSelection -ForegroundHwnd $ForegroundHwnd }
        'XLMAIN'        { return Get-YakuExcelSelection -ForegroundHwnd $ForegroundHwnd }
        'PPTFrameClass' { return Get-YakuPowerPointSelection -ForegroundHwnd $ForegroundHwnd }
        default         { return [pscustomobject]@{ Kind='none'; Reason='not_office' } }
    }
}
