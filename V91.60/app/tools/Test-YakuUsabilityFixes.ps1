<#
.SYNOPSIS
  使いやすさの修正（エラー表示・テストモード・結果の見出し・ファイル確認）の回帰テスト。

.DESCRIPTION
  - サーバーが返すエラーの HTML を、画面にタグのまま出さないこと
  - テストモード（-UseMockTranslator）のテキスト翻訳が、今のプロンプトで契約検証を通ること
  - 結果カードの見出しに FULL / BRIEF の違いを添えること（内部名 Label は変えない）
  - ファイルを選んだら自動で確認すること
  - パス指定の誤りを、次にすべきことが分かる文で返すこと

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuUsabilityFixes.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0
function Assert-YakuUx {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
    else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}
$src = Join-Path $root 'src'
. (Join-Path $src 'Paths.ps1')
. (Join-Path $src 'Html.ps1')
. (Join-Path $src 'Settings.ps1')
. (Join-Path $src 'PromptBuilder.ps1')
. (Join-Path $src 'Translation.ps1')
. (Join-Path $src 'CopilotClient.ps1')

$appJs = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $root 'www') 'assets') 'app.js') -Raw -Encoding UTF8
$serverPs = Get-Content -LiteralPath (Join-Path $src 'Server.ps1') -Raw -Encoding UTF8

Write-Host 'CASE 1: サーバーのエラー HTML を本文と種類に分けて表示する'
Assert-YakuUx ($appJs -match 'function yakuAlertFromHtml') 'エラー HTML を解釈する関数がある'
$responseText = [regex]::Match($appJs, '(?s)function yakuResponseText\(response\) \{.*?\n  \}').Value
Assert-YakuUx ($responseText -match 'yakuAlertFromHtml\(text\)') 'yakuResponseText がエラー HTML を解釈する'
Assert-YakuUx ($responseText -match 'error\.kind') 'エラーの種類（警告/エラー）を呼び出し側へ渡す'
$startError = [regex]::Match($appJs, '(?s)function yakuShowStartError\(error, fallback\) \{.*?\n  \}').Value
Assert-YakuUx ($startError -match "error\.kind === 'warning'") '「別の翻訳が実行中」などの警告は警告の色で出す'

Write-Host 'CASE 2: テストモードのテキスト翻訳が契約検証を通る'
$settings = Read-YakuSettings -Root $root
foreach ($case in @(
    @{ Direction = 'to_en'; Input = '売上高は ⟦#AAA⟧ 億円でした。'; Labels = @('FULL_TEXT:', 'BRIEF_TEXT:') },
    @{ Direction = 'to_jp'; Input = 'Net sales were ⟦#AAA⟧ billion yen.'; Labels = @('JAPANESE_TEXT:') }
)) {
    $requestId = [guid]::NewGuid().ToString('N')
    $prompt = New-YakuTextPrompt -Root $root -InputText ([string]$case.Input) -Settings $settings -DirectionOverride ([string]$case.Direction) -RequestId $requestId
    $mock = Invoke-YakuMockCopilotPrompt -Prompt ([string]$prompt.Prompt)
    foreach ($label in $case.Labels) { Assert-YakuUx ($mock.Contains([string]$label)) ("$($case.Direction): $label を返す") }
    Assert-YakuUx ($mock.Contains('⟦#AAA⟧')) "$($case.Direction): 伏せ字をそのまま戻す"
    $contract = Test-YakuTextResponseContract -Text $mock -Direction ([string]$case.Direction) -RequestId $requestId
    Assert-YakuUx ([bool]$contract.Valid) ("$($case.Direction): 契約検証を通る " + [string]$contract.ErrorCode)
}

Write-Host 'CASE 3: 結果カードの見出し'
$result = [pscustomobject]@{
    InputLength = 12
    Options = @(
        [pscustomobject]@{ Style='full'; Label='FULL'; Translation='Revenue was 1 oku.'; Explanation='' },
        [pscustomobject]@{ Style='brief'; Label='BRIEF'; Translation='Rev. 1 oku'; Explanation='' }
    )
}
$html = Convert-YakuTextResultToHtml -Result $result
Assert-YakuUx ($html -like '*全文訳*') 'FULL に「全文訳」を添える'
Assert-YakuUx ($html -like '*短縮訳*') 'BRIEF に「短縮訳」を添える'
Assert-YakuUx (-not ($html -like '*ユーザー入力*')) '「ユーザー入力」ではなく「入力」と書く'
$jp = Convert-YakuTextResultToHtml -Result ([pscustomobject]@{ Options = @([pscustomobject]@{ Style='jp'; Label='JAPANESE'; Translation='売上高'; Explanation='' }) })
Assert-YakuUx (($jp -like '*日本語訳*') -and -not ($jp -like '*>JAPANESE<*')) '和訳の見出しは「日本語訳」'
Assert-YakuUx ((Get-YakuResultOptionDisplay -Style 'other' -Label 'X').Title -eq 'X') '知らない種類は Label をそのまま出す'

Write-Host 'CASE 4: ファイルを選んだら自動で確認する'
$changeHandler = [regex]::Match($appJs, "(?s)fileInput\.addEventListener\('change', function \(\) \{.*?\n    \}\);").Value
Assert-YakuUx ($changeHandler -match 'yakuSubmitFileInfo\(\)') 'ファイル選択時に確認を始める'
Assert-YakuUx ($appJs -match "filePath\.addEventListener\('change'") 'パスを入力し終えたときも確認する'
$fileInfo = [regex]::Match($appJs, '(?s)function yakuSubmitFileInfo\(\) \{.*?\n  \}').Value
Assert-YakuUx ($fileInfo -match 'seq !== yakuFileInfoSeq') '選び直した後に古い確認結果で上書きしない'
Assert-YakuUx ($appJs -match 'yakuUploadedFile\.pending') '確認中に翻訳を押しても二重にアップロードしない'
Assert-YakuUx ($fileInfo -match 'sheetNames\.length \? sheetNames : null') 'シートの無い CSV を「全シート未選択」と扱わず、翻訳ボタンを押せるままにする'

Write-Host 'CASE 5: 空のまま翻訳を押したときに知らせる'
$submitText = [regex]::Match($appJs, '(?s)function yakuSubmitText\(event\) \{.*?\n  \}').Value
Assert-YakuUx ($submitText -match '翻訳するテキストを入力してください') '入力を促す文を出す'
Assert-YakuUx ($submitText -match 'input\.focus\(\)') '入力欄へ移動する'

Write-Host 'CASE 6: パス指定の誤りは次にすべきことを示す'
Assert-YakuUx (-not ($serverPs -match "throw '相対パスは使用できません。'")) '「相対パスは使用できません」だけで終わらない'
Assert-YakuUx ($serverPs -match 'パスとしてコピー') 'パスのコピー方法を案内する'
foreach ($message in @(
    'ファイルの場所は、C:\ などのドライブ名から始まるパスで入力してください（エクスプローラーでファイルを Shift+右クリックし、「パスとしてコピー」を選ぶとコピーできます）。',
    'そのパスにファイルが見つかりません。パスが正しいか、ファイルが移動・削除されていないか確認してください。'
)) {
    $friendly = Get-YakuFriendlyError -Message $message
    Assert-YakuUx ([string]$friendly.Message -eq $message) ('言い換えずにそのまま出す: ' + $message.Substring(0, 12))
}

if ($script:Failures -gt 0) { throw "Usability regression failed: $($script:Failures) failure(s)." }
Write-Host 'Usability regression passed.' -ForegroundColor Green
