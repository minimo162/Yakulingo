<#
.SYNOPSIS
  V91.61 段階2: 参考資料コーパスの語彙検索の回帰テスト。

.DESCRIPTION
  一節への切り分け・検索語の取り出し・出現数の数え方・BM25 の順位づけを検証する。
  コーパスは英語のみで、日本語との対応づけは持たない
  （_docs/要件整理_汎用翻訳アプリとRAG翻訳.md §13-4）。
  転置索引は作らない。理由と実測は _docs/V91.61_段階2_コーパス検索.md を参照。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161CorpusSearch.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('yaku-cs-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$prevData = [string]$env:YAKULINGO_DATA_DIR
$prevCorpus = [string]$env:YAKULINGO_CORPUS_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $work 'data'

try {
foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','Corpus.ps1','CorpusSearch.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# ---------------------------------------------------------------- 索引語
Write-Host '検索語の取り出し'
$tk = @(Get-YakuCorpusTokens -Text 'Operating income increased by 12.3% to 45,600 million yen.')
Chk ($tk -contains 'operating') '英単語を拾う'
Chk ($tk -contains 'income') '英単語を拾う（2語目）'
Chk (-not ($tk -contains 'by')) '機能語は落とす'
Chk (-not ($tk -contains 'to')) '機能語は落とす（2語目）'
Chk (@($tk | Where-Object { $_ -match '^[0-9]+$' }).Count -eq 0) '数字だけの語は落とす（年度や金額は言い回しの手がかりにならない）'
Chk (@(Get-YakuCorpusTokens -Text '').Count -eq 0) '空文字は0語'
Chk (@(Get-YakuCorpusTokens -Text $null).Count -eq 0) 'null でも落ちない'

# ---------------------------------------------------------------- 一節への切り分け
Write-Host '一節への切り分け'
$md = @"
<!--yaku-page:1-->
$('Consolidated operating results improved on higher shipment volumes. ' * 12)

$('The equity ratio rose as retained earnings accumulated over the period. ' * 12)

<!--yaku-page:2-->
$('Cash flows from operating activities remained positive throughout the year. ' * 12)
"@
$ps = @(Split-YakuCorpusPassages -Markdown $md)
Chk ($ps.Count -ge 3) ('一節に切れる: ' + $ps.Count)
Chk (@($ps | Where-Object { $_.Page -eq 1 }).Count -ge 2) 'ページ1から2件以上'
Chk (@($ps | Where-Object { $_.Page -eq 2 }).Count -ge 1) 'ページ2から1件以上'
Chk (@($ps | Where-Object { $_.Text -match 'yaku-page' }).Count -eq 0) 'ページ境界の印は本文に混ぜない'
foreach ($p in $ps) {
    if ($p.Page -eq 1 -and $p.Text -match 'Cash flows') { Chk $false 'ページ境界を越えて連結してしまった'; break }
}
Chk ($true) 'ページ境界を越えない'
Chk (@(Split-YakuCorpusPassages -Markdown "<!--yaku-page:1-->`n短すぎ").Count -eq 0) '短すぎる一節は捨てる'

# ---------------------------------------------------------------- 空行が無い本文
# PDF から取り出したテキストには空行がほとんど無い。空行だけを切れ目にしていた
# ため、本物の英文短信で 1ページ＝1一節（平均1,633字・最大2,716字）になっていた。
# 文例は先頭600字で切り詰めて送るので、届くのは見出しと表のキャプションだけで、
# 手本になる文が切り捨てられていた（2026-08-06 実データで確認）。
Write-Host '空行が無くても切れる'
$noBlank = "<!--yaku-page:1-->`n" + (('Net sales decreased by a modest margin as shipment volumes fell in the period. ' * 30) -replace ' $', '')
$nb = @(Split-YakuCorpusPassages -Markdown $noBlank)
Chk ($nb.Count -ge 2) ('空行が無くても複数の一節へ切れる: ' + $nb.Count)
Chk ((@($nb | ForEach-Object { $_.Text.Length }) | Measure-Object -Maximum).Maximum -le 1000) ('一節が目安を大きく超えない: ' + (@($nb | ForEach-Object { $_.Text.Length }) | Measure-Object -Maximum).Maximum)

# 表は文末が無い。行で切れないと1一節へ潰れる。
$tableMd = "<!--yaku-page:1-->`n" + ((1..60 | ForEach-Object { "Operating profit by segment $_ 1,234 5,678 9,012" }) -join "`n")
$tb = @(Split-YakuCorpusPassages -Markdown $tableMd)
Chk ($tb.Count -ge 2) ('文末が無い表も複数の一節へ切れる: ' + $tb.Count)
Chk ((@($tb | ForEach-Object { $_.Text.Length }) | Measure-Object -Maximum).Maximum -le 1000) '表の一節も目安を大きく超えない'
# 略語のピリオドで切ってはいけない。
$abbrev = @(Split-YakuCorpusOversizedBlock -Text ('Sales rose approx. 5% vs. plan in the U.S. market. ' * 40) -TargetChars 900)
Chk (@($abbrev | Where-Object { $_ -match '^\s*5% vs' }).Count -eq 0) '略語の途中では切らない'

# ---------------------------------------------------------------- 出現数の数え方
Write-Host '出現数の数え方'
$h = Measure-YakuCorpusTermHits -LowerText 'the equity ratio rose. the equity ratio is disclosed.' -Terms @('equity','ratio','cash')
Chk ($h[0] -eq 2) 'equity を2回数える'
Chk ($h[1] -eq 2) 'ratio を2回数える'
Chk ($h[2] -eq 0) '無い語は0回'
Chk ($h.Count -eq 3) '検索語と同じ並びで返る'
$h2 = Measure-YakuCorpusTermHits -LowerText 'ratios and ratio' -Terms @('ratio')
Chk ($h2[0] -eq 2) '部分一致で数える（ratios も当たる。英語では簡易な語幹処理として働く）'
$h3 = Measure-YakuCorpusTermHits -LowerText '' -Terms @('ratio')
Chk ($h3[0] -eq 0) '空文字でも落ちない'

Write-Host 'BM25 の順位づけ'
# どの資料にも出る語は効かなくなること（IDF が効いていること）
$rare = Get-YakuCorpusBm25Score -Counts @(1) -DocFreq @(1) -DocumentCount 100 -Length 900
$common = Get-YakuCorpusBm25Score -Counts @(1) -DocFreq @(95) -DocumentCount 100 -Length 900
Chk ($rare -gt $common) '珍しい語ほど重い'
$many = Get-YakuCorpusBm25Score -Counts @(5) -DocFreq @(10) -DocumentCount 100 -Length 900
$few = Get-YakuCorpusBm25Score -Counts @(1) -DocFreq @(10) -DocumentCount 100 -Length 900
Chk ($many -gt $few) '出現数が多いほど重い'
$short = Get-YakuCorpusBm25Score -Counts @(3) -DocFreq @(10) -DocumentCount 100 -Length 300
$long = Get-YakuCorpusBm25Score -Counts @(3) -DocFreq @(10) -DocumentCount 100 -Length 3000
Chk ($short -gt $long) '同じ出現数なら短い一節を優先する'
Chk ((Get-YakuCorpusBm25Score -Counts @(0) -DocFreq @(10) -DocumentCount 100 -Length 900) -eq 0) '出現0なら0点'
Chk ((Get-YakuCorpusBm25Score -Counts @(1) -DocFreq @(1) -DocumentCount 0 -Length 900) -eq 0) '資料0件なら0点（落ちない）'

# ---------------------------------------------------------------- コーパスを用意する
Write-Host 'コーパスを用意する'
$corpus = Join-Path $work 'corpus'
$dbA = Join-Path $corpus '英文短信'
$dbB = Join-Path $corpus '英文ｱﾆｭｱﾙ [2026]'
New-Item -ItemType Directory -Path $dbA -Force | Out-Null
New-Item -ItemType Directory -Path $dbB -Force | Out-Null

$docA = "<!--yaku-page:1-->`n" + ('The equity ratio improved to a comfortable level as retained earnings accumulated. ' * 8) +
        "`n`n<!--yaku-page:2-->`n" + ('Operating income rose on higher shipment volumes and a favourable product mix. ' * 8)
$docB = "<!--yaku-page:1-->`n" + ('Cash flows from operating activities remained solidly positive during the period. ' * 8) +
        "`n`n<!--yaku-page:2-->`n" + ('The equity ratio is disclosed in the consolidated balance sheet section. ' * 8)
[System.IO.File]::WriteAllText((Join-Path $dbA 'tanshin.md'), $docA)
[System.IO.File]::WriteAllText((Join-Path $dbB 'annual.md'), $docB)

$manifest = New-YakuCorpusManifest
$manifest['corpus_version'] = '2026-08-05'
$manifest['entries'] = @(
    [pscustomobject]@{ id='aaaaaaaa'; database='英文短信'; source='英文短信/tanshin.pdf'; markdown='英文短信/tanshin.md'; status='ok' }
    [pscustomobject]@{ id='bbbbbbbb'; database='英文ｱﾆｭｱﾙ [2026]'; source='英文ｱﾆｭｱﾙ [2026]/annual.pdf'; markdown='英文ｱﾆｭｱﾙ [2026]/annual.md'; status='ok' }
)
Write-YakuCorpusManifest -Dir $corpus -Manifest $manifest

$phase1 = Get-YakuCorpusDocumentMatches -CorpusDir $corpus -Terms @('equity','ratio') -Databases $null
Chk ($phase1.ScannedCount -eq 2) '2件の資料を読む'
Chk (@($phase1.Documents).Count -eq 2) '2件とも検索語を含む'
Chk ($phase1.DocFreq[0] -eq 2) '文書頻度が数えられる（equity は2資料に出る）'
$phase1b = Get-YakuCorpusDocumentMatches -CorpusDir $corpus -Terms @('semiconductor') -Databases $null
Chk (@($phase1b.Documents).Count -eq 0) '当たらない語では候補が0件'
Chk ($phase1b.ScannedCount -eq 2) '当たらなくても走査件数は数える'
$phase1c = Get-YakuCorpusDocumentMatches -CorpusDir $corpus -Terms @('equity') -Databases @('英文短信')
Chk ($phase1c.ScannedCount -eq 1) 'データベースで絞ると読む資料も減る（無駄に読まない）'

# ---------------------------------------------------------------- 検索
Write-Host '語彙検索（2段構え）'
$hits = @(Search-YakuCorpus -Query 'equity ratio' -CorpusDir $corpus -Top 5)
Chk ($hits.Count -gt 0) ('引ける: ' + $hits.Count)
Chk (([string]$hits[0].Text) -match 'equity ratio') '最上位に検索語が含まれる'
Chk ($hits[0].Score -gt 0) '得点が付く'
Chk (-not [string]::IsNullOrWhiteSpace([string]$hits[0].Source)) '出典が分かる'
Chk ($hits[0].Page -ge 1) 'ページが分かる（どの資料の何ページから引いたか）'
$scores = @($hits | ForEach-Object { [double]$_.Score })
$descending = $true
for ($i = 1; $i -lt $scores.Count; $i++) { if ($scores[$i] -gt $scores[$i-1]) { $descending = $false } }
Chk $descending '得点の高い順に並ぶ'

Write-Host '件数の上限と絞り込み'
Chk (@(Search-YakuCorpus -Query 'equity ratio' -CorpusDir $corpus -Top 1).Count -eq 1) 'Top で件数を絞れる'
$onlyA = @(Search-YakuCorpus -Query 'equity ratio' -CorpusDir $corpus -Databases @('英文短信') -Top 5)
Chk ($onlyA.Count -gt 0) '指定したデータベースから引ける'
Chk (@($onlyA | Where-Object { $_.Database -ne '英文短信' }).Count -eq 0) '指定外のデータベースは混ざらない'
$oddDb = @(Search-YakuCorpus -Query 'consolidated balance sheet' -CorpusDir $corpus -Databases @('英文ｱﾆｭｱﾙ [2026]') -Top 5)
Chk ($oddDb.Count -gt 0) '括弧・半角カナを含む名前でも絞り込める'

Write-Host '当たらないとき'
Chk (@(Search-YakuCorpus -Query 'zzzznotpresent' -CorpusDir $corpus).Count -eq 0) '当たらなければ0件（作り話をしない）'
Chk (@(Search-YakuCorpus -Query '' -CorpusDir $corpus).Count -eq 0) '空の検索語は0件'
Chk (@(Search-YakuCorpus -Query '売上高' -CorpusDir $corpus).Count -eq 0) '日本語だけの検索語は0件（英語側コーパスなので当然）'
Chk (@(Search-YakuCorpus -Query 'equity' -CorpusDir (Join-Path $work 'no-such')).Count -eq 0) 'コーパスが無ければ0件（落ちない）'
Chk (@(Search-YakuCorpus -Query 'equity ratio' -CorpusDir $corpus -Databases @('存在しないDB')).Count -eq 0) '空振りするデータベース指定でも0件'
Chk (@(Search-YakuCorpus -Query 'equity ratio' -CorpusDir $corpus -Top 5 -DocumentCandidates 1).Count -gt 0) '候補の資料数を絞っても引ける'

Write-Host '機能語だけでは引かない'
# 定型表現の多い資料で機能語を残すと、どの一節も同じくらい当たってしまう。
Chk (@(Search-YakuCorpus -Query 'the of and to' -CorpusDir $corpus).Count -eq 0) '機能語だけの検索語は0件'

# ---------------------------------------------------------------- 索引を持たないこと
Write-Host '索引を作らない'
# 索引をやめたので、鮮度の判定も作り直しも要らない。
# コーパスを変えたら次の検索へ即座に反映される。
$dataDir = Get-YakuDataDir
Chk (-not (Test-Path -LiteralPath (Join-Path $dataDir 'corpus-index'))) '索引フォルダを作らない'
Chk (@(Get-ChildItem -LiteralPath $corpus -Recurse -Filter '*.tsv' -ErrorAction SilentlyContinue).Count -eq 0) 'コーパスの中へも書かない'

$manifest2 = Read-YakuCorpusManifest -Dir $corpus
# 台帳は source で並べ替えて保存されるため、添字ではなく id で選ぶ。
$manifest2['entries'] = @(@($manifest2.entries) | Where-Object { [string]$_.id -eq 'aaaaaaaa' })
Write-YakuCorpusManifest -Dir $corpus -Manifest $manifest2
Chk (@($manifest2.entries).Count -eq 1) '台帳から1件だけにする'
Chk (@(Search-YakuCorpus -Query 'consolidated balance sheet' -CorpusDir $corpus).Count -eq 0) '取り除いた資料は即座に引けなくなる（作り直し不要）'
Chk (@(Search-YakuCorpus -Query 'equity ratio' -CorpusDir $corpus).Count -gt 0) '残した資料は引ける'

Write-Host '前の版が作った索引フォルダの片付け'
$legacy = Join-Path $dataDir 'corpus-index'
New-Item -ItemType Directory -Path (Join-Path $legacy '2026-08-05') -Force | Out-Null
foreach ($n in @('meta.tsv','passages.tsv','postings.tsv')) {
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $legacy '2026-08-05') $n), 'stale')
}
Chk (Remove-YakuCorpusLegacyIndex) '見覚えのある中身なら消す'
Chk (-not (Test-Path -LiteralPath $legacy)) '消えている'
New-Item -ItemType Directory -Path (Join-Path $legacy '2026-08-05') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path (Join-Path $legacy '2026-08-05') 'メモ.txt'), '利用者が置いた何か')
Chk (-not (Remove-YakuCorpusLegacyIndex)) '見覚えのないものが混じっていたら触らない'
Chk (Test-Path -LiteralPath $legacy) '残っている'
Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
Chk (-not (Remove-YakuCorpusLegacyIndex)) '無ければ何もしない'

Write-Host '環境変数からの解決'
$env:YAKULINGO_CORPUS_DIR = $corpus
Chk (@(Search-YakuCorpus -Query 'equity ratio').Count -gt 0) 'CorpusDir 省略時は配布済みコーパスを使う'
Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue
Chk (@(Search-YakuCorpus -Query 'equity ratio').Count -eq 0) 'コーパス未配布なら0件（コーパス無しで動く）'

# ---------------------------------------------------------------- 管理画面からの確認経路
Write-Host '管理画面の検索経路'
$serverText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
# 二重引用符だと $script:YakuAdminMode と $path が展開されてしまう。単一引用符で書く。
$guard = $serverText.IndexOf('if ($script:YakuAdminMode -and $path.StartsWith(''/api/admin/corpus''))')
$searchAt = $serverText.IndexOf("'/api/admin/corpus/search'")
Chk ($searchAt -ge 0) '検索の経路がある'
Chk ($guard -ge 0 -and $searchAt -gt $guard) '-Admin のときだけ登録される（塊の中にある）'
Chk ($serverText -match "Get-YakuQueryValue -Request \`$req -Name 'q'") 'クエリは UTF-8 で取り出す（文字化けの回帰）'
Chk ($serverText -notmatch "QueryString\['q'\]") 'QueryString を使っていない'
$adminHtml = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'admin.html'))
Chk ($adminHtml -match 'search-query') '管理画面に検索欄がある'
$indexHtml = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'index.html'))
Chk ($indexHtml -notmatch 'search-query') '一般利用者の画面には出さない（段階4 まで出さない）'
# V91.61（2026-08-06）: CAT に「文例を検索」を置いた。参照する側は一般利用者の
# 画面にも現れる。管理画面だけに置くのは**作る側**（取り込み・索引作り）である。
Chk ($indexHtml -notmatch '(?i)corpus[-_]?(build|rebuild|index|import|ingest|admin|manage)') 'コーパスを作る操作は一般利用者の画面に出さない'

# ---------------------------------------------------------------- 翻訳経路を触っていないこと
Write-Host '翻訳経路への影響'
$translation = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Translation.ps1'))
Chk ($translation -notmatch 'Search-YakuCorpus') '段階2 では翻訳経路へ差し込まない（差し込みは段階3）'
$fileTranslation = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CatBatch.ps1'))
Chk ($fileTranslation -notmatch 'Search-YakuCorpus') 'ファイル翻訳経路にも差し込まない'

} finally {
    if (-not [string]::IsNullOrWhiteSpace($prevData)) { $env:YAKULINGO_DATA_DIR = $prevData } else { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    if (-not [string]::IsNullOrWhiteSpace($prevCorpus)) { $env:YAKULINGO_CORPUS_DIR = $prevCorpus } else { Remove-Item Env:\YAKULINGO_CORPUS_DIR -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 corpus search regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 corpus search regression passed.' -ForegroundColor Green
