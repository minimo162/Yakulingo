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
Chk (@($st3.Pending).Count -eq 0) '別名でも同じ id なので未取込にならない（原本が在るので移動ではなく重複）'
Chk ([int]$st3.RelocatedCount -eq 0) '原本が在るうちは移動として数えない'
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

Write-Host '資料を別のデータベースへ移したとき（実機で発生）'
# id は内容のハッシュなので、フォルダを移しても同じ id になる。
# そのままだと「取り込み済み」と判定され、データベース名が古いまま直せない。
$moveRoot = Join-Path $work 'move'
$dbA = Join-Path $moveRoot '(未分類)'
$dbB = Join-Path $moveRoot '英文短信'
New-Item -ItemType Directory -Path $dbA -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $dbA 'tanshin.pdf'), [Text.Encoding]::ASCII.GetBytes('%PDF-1.4 moved sample'))
$mvBuild = Join-Path $work 'move-build'

$s1 = Get-YakuCorpusState -SourceRoot $moveRoot -BuildDir $mvBuild
$p1 = @($s1.Pending)[0]
Chk (@($s1.Pending).Count -eq 1) '最初は未取込 1 件'
$null = Save-YakuCorpusMarkdown -BuildDir $mvBuild -Id $p1.id -Sha256 $p1.sha256 -Database $p1.database -Source $p1.source -Markdown 'body' -Pages 1 -Status 'ok'
Chk (Test-Path -LiteralPath (Join-Path $mvBuild '(未分類)/tanshin.pdf'.Replace('.pdf','.md'))) '(未分類) の下に md ができる'

# 別のフォルダへ移す（利用者がやった操作）
New-Item -ItemType Directory -Path $dbB -Force | Out-Null
Move-Item -LiteralPath (Join-Path $dbA 'tanshin.pdf') -Destination (Join-Path $dbB 'tanshin.pdf')
Remove-Item -LiteralPath $dbA -Force -ErrorAction SilentlyContinue

$s2 = Get-YakuCorpusState -SourceRoot $moveRoot -BuildDir $mvBuild
Chk (@($s2.Pending).Count -eq 1) '移動を未取込として拾う（これが無いと取り込めない）'
Chk ([int]$s2.RelocatedCount -eq 1) '移動として数える'
$p2 = @($s2.Pending)[0]
Chk ([bool]$p2.relocated) '移動の印が付く'
Chk ([string]$p2.previous -eq '(未分類)/tanshin.pdf') '移動前の場所が分かる'
Chk ([string]$p2.database -eq '英文短信') '新しいデータベース名になる'
Chk ([string]$p2.id -eq [string]$p1.id) 'id は内容由来なので変わらない'

$null = Save-YakuCorpusMarkdown -BuildDir $mvBuild -Id $p2.id -Sha256 $p2.sha256 -Database $p2.database -Source $p2.source -Markdown 'body' -Pages 1 -Status 'ok'
$m2 = Read-YakuCorpusManifest -Dir $mvBuild
Chk (@($m2.entries).Count -eq 1) '台帳の件数は増えない'
Chk ([string]@($m2.entries)[0].database -eq '英文短信') '台帳のデータベース名が更新される'
Chk (Test-Path -LiteralPath (Join-Path $mvBuild '英文短信/tanshin.md')) '新しい場所に md がある'
Chk (-not (Test-Path -LiteralPath (Join-Path $mvBuild '(未分類)/tanshin.md'))) '古い md は消える'
Chk (-not (Test-Path -LiteralPath (Join-Path $mvBuild '(未分類)'))) '空になったフォルダも消える'

$s3 = Get-YakuCorpusState -SourceRoot $moveRoot -BuildDir $mvBuild
Chk (@($s3.Pending).Count -eq 0) '取り込み直した後は未取込 0 件'
Chk ([int]$s3.RelocatedCount -eq 0) '移動は解消している'

Write-Host '原本が無くなった項目'
Remove-Item -LiteralPath (Join-Path $dbB 'tanshin.pdf') -Force
$s4 = Get-YakuCorpusState -SourceRoot $moveRoot -BuildDir $mvBuild
Chk (@($s4.StaleEntries).Count -eq 1) '原本消失を数える'
$m4 = Read-YakuCorpusManifest -Dir $mvBuild
Chk (@($m4.entries).Count -eq 1) '勝手に消さない（判断は人がする）'

Write-Host 'CSP（WASM が実行できるかの回帰）'
# ブラウザは CSP に script-src があると、WebAssembly のコンパイルに
# 'wasm-unsafe-eval' を要求する。無いと管理画面が「WASM を読み込んでいます…」で
# 止まる（実機で発生）。Linux 上の検証では既定CSPのサーバーを使っておらず見逃した。
$serverSrc = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
$cspStart = $serverSrc.IndexOf('function Get-YakuContentSecurityPolicy {')
$cspEnd = $serverSrc.IndexOf('function Send-YakuResponse {')
Chk ($cspStart -ge 0 -and $cspEnd -gt $cspStart) 'Get-YakuContentSecurityPolicy が定義されている'
Invoke-Expression $serverSrc.Substring($cspStart, $cspEnd - $cspStart)

$cspDefault = Get-YakuContentSecurityPolicy
$cspWasm = Get-YakuContentSecurityPolicy -AllowWasm
Chk ($cspWasm -like "*script-src 'self' 'wasm-unsafe-eval'*") '管理画面の CSP は WebAssembly を許す'
Chk (-not ($cspDefault -like '*wasm-unsafe-eval*')) '一般利用者の CSP は既定のまま'
Chk (-not ($cspWasm -like "*'unsafe-eval'*" -and -not ($cspWasm -like "*'wasm-unsafe-eval'*"))) "eval() は許さない（wasm-unsafe-eval のみ）"
foreach ($d in @("default-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "connect-src 'self'")) {
    Chk ($cspWasm -like ('*' + $d + '*')) ('管理画面でも他の制限は維持: ' + $d)
}
# 管理画面の応答が -AllowWasm を渡していること
Chk ($serverSrc -match 'Send-YakuTextResponse -Context \$Context -Text \$html -ContentType ''text/html; charset=utf-8'' -AllowWasm') '管理画面の応答が -AllowWasm を渡す'
# .wasm の MIME
Chk ($serverSrc -match "'\.wasm'\s*\{\s*'application/wasm'\s*\}") '.wasm は application/wasm で配信する'

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
