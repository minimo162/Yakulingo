[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:failed = 0
function Chk {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:failed++ }
}

Write-Host '選択範囲の読み取り（Office COM）' -ForegroundColor Cyan
$sel = [IO.File]::ReadAllText((Join-Path $root 'src/Selection.ps1'))

# 利用者の Office を壊さない。読むだけ。
Chk ($sel -notmatch '\.Quit\(|Close-YakuExcelObjects|FinalReleaseComObject') '利用者のOfficeを閉じない'
Chk ($sel -notmatch 'ScreenUpdating\s*=|DisplayAlerts\s*=|EnableEvents\s*=|Calculation\s*=|\.Visible\s*=') '利用者のOfficeの設定を変えない'
Chk ($sel -notmatch 'Application\.Run|Workbooks\.Open|Workbooks\.Add|Documents\.Open|Documents\.Add') '読み取り以外のことをしない'
Chk ($sel -match 'Release-YakuComObject') 'COM参照を解放する'

# 別インスタンスを掴まない。ここを外すと、別ブックを訳しても利用者は気づけない。
Chk ($sel -match 'Test-YakuOfficeInstanceMatchesWindow') '前面の窓とインスタンスを照合する'
Chk ($sel -match 'ProcessIdOf') 'ハンドルではなくプロセスIDで照合する'
Chk ($sel -notmatch 'IRunningObjectTable|GetRunningObjectTable') '他インスタンスを探しに行かない'
Chk ($sel -match 'instance_mismatch') '一致しなければ読まずに理由を返す'

# 読む範囲の制限
Chk ($sel -match 'Areas\.Count') '複数エリア選択を弾く'
Chk ($sel -match "StartsWith\('='\)") '数式セルを除外する'
Chk ($sel -match 'YakuSelectionMaxChars' -and $sel -match 'YakuSelectionMaxCells') 'セル数と文字数の上限が定数である'
Chk ($sel -match 'too_large') '上限超過は切り詰めずに知らせる'

# 本文をディスクへ書かない（QuickArtifact.ps1 と同じ守り方）
Chk ($sel -notmatch 'Set-Content|Add-Content|Out-File|WriteAll(?:Text|Bytes|Lines)|Write-YakuJsonAtomic') '選択の本文をディスクへ書かない'

# クリップボードには触れない（触るのは C# 側の Office 以外の経路だけ）
Chk ($sel -notmatch 'Clipboard') 'この経路はクリップボードに触れない'

# PowerPoint（2026-08-12 追加）。実測では、図形を選んだ状態で疑似 Ctrl+C を送っても
# クリップボードに文字が入らない（ContainsText=False）。スライドは枠を1回クリックして
# 選ぶのが普通なので、COM で読まないといちばんよくある選び方で何も取れない。
$shell = [IO.File]::ReadAllText((Join-Path $root 'desktop\Program.cs'))
$server = [IO.File]::ReadAllText((Join-Path $root 'src\Server.ps1'))
Chk ($sel -match 'PPTFrameClass' -and $sel -match 'Get-YakuPowerPointSelection') 'PowerPoint を窓のクラスで見分けて COM で読む'
Chk ($shell -match 'name == "PPTFrameClass"') '外枠は PowerPoint へ疑似 Ctrl+C を送らない'
Chk ($server -match "'OpusApp','XLMAIN','PPTFrameClass'") 'サーバは PowerPoint の窓クラスだけを追加で受ける'
Chk ($sel -match '\$type -eq 2' -and $sel -match 'TextFrame\.HasText') '図形を選んだ状態でも、文字を持つ枠から読む'
Chk ($sel -match '\$type -eq 3' -and $sel -match 'TextRange\.Text') '文字を選んだ状態でも読む'
# スライドは資料翻訳が扱えない（.pptx は取り込み対象外）。丸ごと取り込む導線を出さない。
$pptBranch = ''
if ($server -match "(?s)Kind -eq 'powerpoint_text'\)\s*\{(?<body>.*?)\}\s*elseif") { $pptBranch = $Matches['body'] }
Chk ($pptBranch -ne '' -and $pptBranch -notmatch "\`$body\['source_path'\]") 'PowerPoint では丸ごと取り込む導線を出さない'

# Outlook は COM を使わない。実測（2026-08-12）に基づく判断で、理由を残しておく。
#   - 閲覧ウィンドウの文字選択を返す COM が無い
#   - 新しい Outlook は COM を持たない（この PC には従来版と新版の両方がある）
#   - MAPI へ触ると固まることがあり、選択の読み取りは HTTP 要求の中で同期に走る
Chk ($sel -notmatch 'Outlook\.Application' -and $shell -notmatch 'rctrl_renwnd32') 'Outlook へ COM で触りに行かない'
Chk ($sel -match 'Outlook') 'Outlook を COM で扱わない理由が書かれている'

if ($script:failed -gt 0) { Write-Host ("Selection regression failed. failures=" + $script:failed) -ForegroundColor Red; exit 1 }
Write-Host 'Selection regression passed.' -ForegroundColor Green
