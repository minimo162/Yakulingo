<#
.SYNOPSIS
  V91.61: 参考資料コーパスの回帰テスト。

.DESCRIPTION
  取り込みの列挙・冪等性・低抽出の判定・パスの門・配布用フォルダの生成を検証する。
  PDF の解析そのものはブラウザ側の WASM が行うため、ここでは Markdown をダミーで与える。
  解析の実測は _docs/要件整理_汎用翻訳アプリとRAG翻訳.md §13-6 を参照。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161Corpus.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

# 実データを汚さないよう、データディレクトリと原本フォルダを一時領域へ退避する。
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-corpus-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$srcRoot = Join-Path $work 'src'
$dbDir = Join-Path $srcRoot '英文短信'
New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
$prevData = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $work 'data'

# 中身の違う PDF もどきを2つ置く。解析はしないので実PDFである必要はない。
[System.IO.File]::WriteAllBytes((Join-Path $dbDir 'a_en.pdf'), [System.Text.Encoding]::ASCII.GetBytes('%PDF-1.4 sample A'))
[System.IO.File]::WriteAllBytes((Join-Path $dbDir 'b_en.pdf'), [System.Text.Encoding]::ASCII.GetBytes('%PDF-1.4 sample B different'))

try {
foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','FileTranslation.ps1','Corpus.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

Write-Host '取り込み前'
$st = Get-YakuCorpusState -SourceRoot $srcRoot
Chk ($st.Reachable) '原本フォルダに到達する'
Chk (@($st.Pending).Count -eq 2) ("未取込 2 件: " + @($st.Pending).Count)
Chk (@($st.Databases)[0].Database -eq '英文短信') 'データベース名は直下のフォルダ名'
$ids = @($st.Pending | ForEach-Object { $_.id })
Chk (($ids | Select-Object -Unique).Count -eq 2) '内容が違えば別の id'

Write-Host '取り込み（Markdown はダミー）'
$build = Get-YakuCorpusBuildDir
foreach ($p in $st.Pending) {
  $null = Save-YakuCorpusMarkdown -BuildDir $build -Id $p.id -Sha256 $p.sha256 -Database $p.database -Source $p.source -Markdown "<!--yaku-page:1-->`nEquity ratio increased by 0.7 percentage points." -Pages 1 -Status 'ok'
}
$st2 = Get-YakuCorpusState -SourceRoot $srcRoot
Chk (@($st2.Pending).Count -eq 0) '未取込が 0 になる'
Chk ($st2.DoneCount -eq 2) '取込済 2 件'

Write-Host '冪等性'
$p0 = $st.Pending[0]
$null = Save-YakuCorpusMarkdown -BuildDir $build -Id $p0.id -Sha256 $p0.sha256 -Database $p0.database -Source $p0.source -Markdown 'x' -Pages 1 -Status 'ok'
$m = Read-YakuCorpusManifest -Dir $build
Chk (@($m.entries).Count -eq 2) ('2回取り込んでも件数が増えない: ' + @($m.entries).Count)

Write-Host '別名の同一ファイル'
Copy-Item (Join-Path $dbDir 'a_en.pdf') (Join-Path $dbDir 'copy.pdf')
$st3 = Get-YakuCorpusState -SourceRoot $srcRoot
Chk (@($st3.Pending).Count -eq 0) '別名でも同じ id なので未取込にならない'
Remove-Item (Join-Path $dbDir 'copy.pdf')

Write-Host '低抽出の判定'
Chk (Test-YakuCorpusLowText -PageChars @(10,20,30)) '全ページ低ければ low-text'
Chk (-not (Test-YakuCorpusLowText -PageChars @(3000,2000,10))) '大半が十分なら low-text ではない'
Chk (Test-YakuCorpusLowText -PageChars @()) 'ページ0件は low-text'

Write-Host 'パスの門'
Chk (-not (Test-YakuPathInside -Base $srcRoot -Path (Join-Path $srcRoot '../data/x'))) '外へ出るパスを弾く'
Chk (Test-YakuPathInside -Base $srcRoot -Path (Join-Path $dbDir 'a_en.pdf')) '配下は通す'

Write-Host '配布用フォルダ'
$pub = New-YakuCorpusPublishFolder -Version '2026-08-04'
Chk (Test-Path (Join-Path $pub.Path 'manifest.json')) '台帳が出力される'
Chk ($pub.Count -eq 2) '2件が配布対象'
$pm = Read-YakuCorpusManifest -Dir $pub.Path
Chk ($pm.corpus_version -eq '2026-08-04') 'コーパスの版が入る'
Chk (@(Get-ChildItem -LiteralPath $pub.Path -Recurse -Filter '*.pdf').Count -eq 0) '配布物に元PDFを入れない'
Chk (@(Get-ChildItem -LiteralPath $pub.Path -Recurse -Filter '*.md').Count -eq 2) 'Markdown が2件'

Write-Host 'クエリ文字列の日本語（文字化けの回帰）'
# HttpListener.QueryString は日本語 Windows で CP932 を使うため
# 「原本フォルダ」が「蜴滓悽繝輔か繝ｫ繝」になる。RawUrl から UTF-8 で読む。
$serverText = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
Chk (-not ($serverText -match '\$req\.QueryString')) 'QueryString を使っていない'

# Get-YakuQueryValue を Server.ps1 から取り出して単体で確かめる
$fnStart = $serverText.IndexOf('function Get-YakuQueryValue {')
$fnEnd = $serverText.IndexOf('function Read-YakuRequestBodyText {')
Chk ($fnStart -ge 0 -and $fnEnd -gt $fnStart) 'Get-YakuQueryValue が定義されている'
Invoke-Expression $serverText.Substring($fnStart, $fnEnd - $fnStart)

$jp = 'C:\Users\m242054\Downloads\原本フォルダ'
$encoded = [System.Uri]::EscapeDataString($jp)
$fake = [pscustomobject]@{ RawUrl = '/api/admin/corpus/status?root=' + $encoded }
Chk ((Get-YakuQueryValue -Request $fake -Name 'root') -eq $jp) '日本語を含むパスがそのまま取れる'

$fake2 = [pscustomobject]@{ RawUrl = '/api/admin/corpus/pdf?root=' + $encoded + '&id=a1b2c3d4' }
Chk ((Get-YakuQueryValue -Request $fake2 -Name 'id') -eq 'a1b2c3d4') '2つ目の値も取れる'
Chk ((Get-YakuQueryValue -Request $fake2 -Name 'root') -eq $jp) '1つ目の値も壊れない'
Chk ((Get-YakuQueryValue -Request $fake2 -Name 'none') -eq '') '無い名前は空'
Chk ((Get-YakuQueryValue -Request ([pscustomobject]@{ RawUrl='/api/x' }) -Name 'root') -eq '') 'クエリ無しでも落ちない'
# 前方一致の別名を取り違えない
$fake3 = [pscustomobject]@{ RawUrl = '/x?rootdir=zzz&root=' + $encoded }
Chk ((Get-YakuQueryValue -Request $fake3 -Name 'root') -eq $jp) '名前の前方一致で取り違えない'

Write-Host '配布済みコーパスの解決'
Chk ((Get-YakuCorpusDir) -eq '') '環境変数が無ければ空'
$env:YAKULINGO_CORPUS_DIR = $pub.Path
Chk ((Get-YakuCorpusDir) -ne '') '環境変数があれば解決する'
$env:YAKULINGO_CORPUS_DIR = '/nonexistent/xyz'
Chk ((Get-YakuCorpusDir) -eq '') '不在なら空を返す（コーパス無しで動く）'
Remove-Item Env:\YAKULINGO_CORPUS_DIR
} finally {
    if ([string]::IsNullOrWhiteSpace($prevData)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $prevData }
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:fail -gt 0) {
    Write-Host ("V91.61 corpus test failed. failures={0}" -f $script:fail) -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 corpus regression passed.' -ForegroundColor Green
