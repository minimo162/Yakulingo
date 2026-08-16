#Requires -Version 5.1
<#
  略語の往復。モデルが「見せられた形」で答えても通ること。

  2026-08-17 に実行して再現した欠陥の回帰。

    登録 entry_id : b5ed71b05d4646aab96ae1e447b1f7ce
    送られた形    : b[[N10]]ed[[N11]]b[[N12]]d[[N13]]aab[[N14]]ae[[N15]]e[[N16]]b[[N17]]f[[N18]]ce
    version       : [[N19]]

  sidecar は JSON 化してから丸ごと数値マスクを通る（`New-YakuCatProtectedPublicationCandidateRequest`）。
  entry_id は32桁の16進なので、数字の並びごとに置き換わって出ていく。
  モデルは見せられた形しか返せないのに、応答は**素の** entry_id で作った表と
  突き合わされ、外れると `CAT_PUBLICATION_RESPONSE_ABBREVIATION_NOT_ALLOWED` が
  **応答全体**に対して投げられていた。
  つまり利用者が略語を登録し、モデルがそれを使ったと申告した瞬間に、
  候補生成が丸ごと落ちていた。

  **既存の `Test-YakuV9170Publication` は、この欠陥を見つけられない。**
  応答を素の `$entry.entry_id` で組むからである（同ファイル 24行目あたり）。
  試験が本番と違う入力を作っていた。だからこの試験は、**送った sidecar から
  値を読んで**応答を組む。モデルにできることと同じことしかしない。

  Copilot も Excel も要らない。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$YakuT9186Root = Split-Path -Parent $PSScriptRoot
$YakuT9186Src = Join-Path $YakuT9186Root 'src'
$script:T9186Failures = New-Object System.Collections.Generic.List[string]
function Assert-T9186 {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ("  ok   " + $Message) }
    else { Write-Host ("  NG   " + $Message); $script:T9186Failures.Add($Message) | Out-Null }
}

Write-Host 'Test-YakuV9186AbbreviationRoundTrip'

$YakuT9186Temp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9186-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $YakuT9186Temp -Force
$YakuT9186OldData = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $YakuT9186Temp 'data'
$script:YakuT9186Store = Join-Path $YakuT9186Temp 'store'

. (Join-Path $YakuT9186Src 'SrcModules.ps1')
foreach ($YakuT9186File in $script:YakuSrcModuleFiles) {
    if ($YakuT9186File -eq 'DesktopIntegration.ps1') { continue }
    . (Join-Path $YakuT9186Src $YakuT9186File)
}
function Get-YakuCatProjectStoreDir { return $script:YakuT9186Store }

try {
    $settings = Read-YakuSettings -Root $YakuT9186Root
    # 売上高は123百万円でした。（この .ps1 は ASCII だけで書く）
    $YakuT9186Ja = [string]::Concat([char]0x58F2, [char]0x4E0A, [char]0x9AD8, [char]0x306F, '123',
        [char]0x767E, [char]0x4E07, [char]0x5186, [char]0x3067, [char]0x3057, [char]0x305F, [char]0x3002)
    $project = New-YakuCatTextProject -Root $YakuT9186Root -Text $YakuT9186Ja -Settings $settings -Direction to_en -Register:$false
    $segment = $project.Segments[0]
    $segment.Translation = 'Net sales were 123 million yen.'
    $segment.Kind = 'cell'; $segment.Sheet = 'Sheet1'; $segment.BlockIds = @('block-a')
    $segment.Cells = @([pscustomobject]@{ Text = [string]$segment.Text; Address = 'A1' })
    $project.Blocks = @([pscustomobject]@{ Id = 'block-a'; Text = [string]$segment.Text; Location = 'Sheet1!A1'; Meta = $null })
    $segment.Confirmed = $true; $segment.State = 'reviewed'; $segment.TmRegistered = $true; $segment.TmRegistrationEventId = 'existing-tm'
    $null = Initialize-YakuCatProjectState -Project $project
    $null = Sync-YakuCatPlacementPlans -Project $project
    $project.PlacementPlans[0].placement_kind = 'human_confirmed'; $project.PlacementPlans[0].status = 'current'

    $entry = Register-YakuCatAbbreviationEntry -Project $project -FullForm 'Net sales' -Abbreviation 'NS' -Meaning $YakuT9186Ja -Scope document -FirstUseRule define_first
    $request = New-YakuCatProtectedPublicationCandidateRequest -Root $YakuT9186Root -Project $project -Index 0 -PlacementBudget ([pscustomobject]@{ max_chars = 40; destination_count = 1 })

    # --- 1. 前提: 送信前に伏せられていること --------------------------------
    $sent = ([string]$request.ProtectedSidecar) | ConvertFrom-Json
    $sentAbbreviations = @($sent.allowed_abbreviations)
    Assert-T9186 -Condition ($sentAbbreviations.Count -eq 1) -Message 'the registered abbreviation is carried in the sidecar'
    $sentId = [string]$sentAbbreviations[0].entry_id
    $sentVersion = [string]$sentAbbreviations[0].version
    Assert-T9186 -Condition ($sentId -ne [string]$entry.entry_id) `
        -Message 'the entry_id really is masked on the way out (otherwise this test proves nothing)'
    Assert-T9186 -Condition ($sentId -match '\[\[N\d+\]\]') -Message 'the masked entry_id carries placeholder tokens'

    # --- 2. モデルにできることと同じことをする -------------------------------
    # 見せられた形で申告する。素の entry_id はモデルに見えていない。
    $payload = [ordered]@{
        contract = 'compaction-candidate-v1'
        request_id = [string]$request.RequestId
        candidates = @([ordered]@{
            text = 'NS: 123 million yen.'
            used_abbreviations = @([ordered]@{ entry_id = $sentId; version = $sentVersion })
            transformations = @('abbreviated')
            claimed_preserved_facts = @('sales amount')
            fit_estimate = 'likely'
            warnings = @()
        })
        cannot_fit_reason = ''
    }
    $response = 'COMPACTION_JSON:' + ($payload | ConvertTo-Json -Depth 8 -Compress)
    $thrown = ''
    $parsed = $null
    try { $parsed = ConvertFrom-YakuPublicationCandidateResponse -Response $response -Request $request }
    catch { $thrown = [string]$_.Exception.Message }

    Assert-T9186 -Condition ($thrown -notmatch 'ABBREVIATION_NOT_ALLOWED') `
        -Message ('answering with the masked form is accepted (thrown="' + $thrown + '")')
    Assert-T9186 -Condition ($null -ne $parsed -and @($parsed.Candidates).Count -eq 1) -Message 'the candidate survives'

    if ($null -ne $parsed -and @($parsed.Candidates).Count -eq 1) {
        $used = @(@($parsed.Candidates)[0].used_abbreviations)
        Assert-T9186 -Condition ($used.Count -eq 1) -Message 'the declared abbreviation is recorded'
        if ($used.Count -eq 1) {
            # 記録するのは登録簿の値であって、モデルの復唱ではない。
            # 復唱を [int] へ落とすと "[[N19]]" で壊れる。
            Assert-T9186 -Condition ([string]$used[0].entry_id -eq [string]$entry.entry_id) `
                -Message 'the recorded entry_id is the registry value, not the model echo'
            Assert-T9186 -Condition ([int]$used[0].version -eq [int]$entry.version) `
                -Message 'the recorded version is a number from the registry'
            Assert-T9186 -Condition ([string]$used[0].abbreviation -eq 'NS') -Message 'the abbreviation resolves from the registry'
        }
    }

    # --- 3. 本当に許していない略語は、これまでどおり拒む ---------------------
    $bogus = [ordered]@{
        contract = 'compaction-candidate-v1'
        request_id = [string]$request.RequestId
        candidates = @([ordered]@{
            text = 'XX: 123 million yen.'
            used_abbreviations = @([ordered]@{ entry_id = 'not-a-registered-id'; version = '9' })
            transformations = @(); claimed_preserved_facts = @(); fit_estimate = 'likely'; warnings = @()
        })
        cannot_fit_reason = ''
    }
    $bogusThrown = ''
    try { $null = ConvertFrom-YakuPublicationCandidateResponse -Response ('COMPACTION_JSON:' + ($bogus | ConvertTo-Json -Depth 8 -Compress)) -Request $request }
    catch { $bogusThrown = [string]$_.Exception.Message }
    Assert-T9186 -Condition ($bogusThrown -match 'ABBREVIATION_NOT_ALLOWED') `
        -Message 'an abbreviation that was never registered is still rejected'
} finally {
    if ([string]::IsNullOrEmpty($YakuT9186OldData)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $YakuT9186OldData }
    try { Remove-Item -LiteralPath $YakuT9186Temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($script:T9186Failures.Count -eq 0) {
    Write-Host 'PASS Test-YakuV9186AbbreviationRoundTrip'
    exit 0
}
Write-Host ("FAIL " + $script:T9186Failures.Count + ' assertion(s)')
foreach ($YakuT9186F in $script:T9186Failures) { Write-Host ('  - ' + $YakuT9186F) }
exit 1
