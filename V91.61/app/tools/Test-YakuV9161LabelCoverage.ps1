<#
.SYNOPSIS
  V91.61: 用語集に無い短いラベルの検出と、コーパス文例の適用範囲の回帰テスト。

.DESCRIPTION
  ファイル翻訳の完全一致置換（cell-exact）は、実運用では
  **「はみ出さないことの保証」**として使われている。過去のラベルはその列に
  収まっていたから採用されたので、同じ訳語を使えば必ず収まる。
  したがって保証が効くのは「ラベルが変わらない限り」であり、
  新しいラベルが出た瞬間に保証が消える。それを見えるようにする。

  あわせて、コーパス文例が FULL の手本であって BRIEF の手本ではないことを
  プロンプトで名指ししているかを確かめる（IWSLT 2025 の実測より）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161LabelCoverage.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

try {
foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','FileTranslation.ps1','Corpus.ps1','CorpusSearch.ps1','CorpusReference.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# ---------------------------------------------------------------- ラベルらしさ
Write-Host 'ラベルらしさの判定 — 拾いたいもの'
Chk (Test-YakuFileLabelLike -Text '販売促進費') '短い日本語はラベル'
Chk (Test-YakuFileLabelLike -Text '子会社 固定販促費') '空白を含んでもラベル'
Chk (Test-YakuFileLabelLike -Text 'のれん償却') 'ひらがなを含む名詞もラベル'
Chk (Test-YakuFileLabelLike -Text '販売費及び一般管理費') '長めの勘定科目もラベル'
# 途中の活用（帰属する）で弾いてはいけない。正当なラベルの一部である。
Chk (Test-YakuFileLabelLike -Text '親会社株主に帰属する当期純利益') '途中に活用があってもラベル'
Chk (Test-YakuFileLabelLike -Text 'その他の包括利益累計額') '長めでも名詞の連なりならラベル'
Chk (Test-YakuFileLabelLike -Text '前年同期比') '比較語もラベル'
# 「による」は連体修飾で、後ろに名詞が来る＝ラベルの一部。
# 途中一致で弾いていたため、実機のファイル翻訳でこの5件を全て取りこぼした（2026-08-05）。
# 英語にすると長くなる行なので、取りこぼすと はみ出しに気づけない。
Chk (Test-YakuFileLabelLike -Text '営業活動によるキャッシュ・フロー') '「による」を含む勘定科目もラベル'
Chk (Test-YakuFileLabelLike -Text '投資活動によるキャッシュ・フロー') '投資活動のキャッシュ・フローもラベル'
Chk (Test-YakuFileLabelLike -Text '財務活動によるキャッシュ・フロー') '財務活動のキャッシュ・フローもラベル'
Chk (Test-YakuFileLabelLike -Text '持分法による投資利益') '持分法による投資利益もラベル'
Chk (Test-YakuFileLabelLike -Text '事業譲渡による損失') '事業譲渡による損失もラベル'
Chk (Test-YakuFileLabelLike -Text '原価改善による増益') '増減要因表の体言止めもラベル'

Write-Host 'ラベルらしさの判定 — 拾いたくないもの'
# 句点の無い短文が本題。文字数の上限だけでは拾ってしまう。
Chk (-not (Test-YakuFileLabelLike -Text '為替影響により営業利益が減少')) '句点が無くても接続表現があれば文'
Chk (-not (Test-YakuFileLabelLike -Text 'コストを削減')) '格助詞「を」があれば文'
Chk (-not (Test-YakuFileLabelLike -Text '営業利益が増加')) '格助詞「が」があれば文'
Chk (-not (Test-YakuFileLabelLike -Text '出荷台数が増加した')) '述語で終われば文'
Chk (-not (Test-YakuFileLabelLike -Text '価格改定を実施しました')) '丁寧形で終わっても文'
Chk (-not (Test-YakuFileLabelLike -Text '原材料価格の上昇、為替の影響')) '読点があれば文'
Chk (-not (Test-YakuFileLabelLike -Text '為替影響により営業利益は減少した。')) '文末記号があれば文'
Chk (-not (Test-YakuFileLabelLike -Text '半導体セグメントの出荷台数の増加が寄与')) '長さの上限も効く'
Chk (-not (Test-YakuFileLabelLike -Text ('あ' * 40))) '長すぎるものはラベルではない'
Chk (-not (Test-YakuFileLabelLike -Text "販促費`n固定費")) '複数行はラベルではない'
Chk (-not (Test-YakuFileLabelLike -Text '1,234')) '数字だけは訳す対象が無い'
Chk (-not (Test-YakuFileLabelLike -Text 'Operating income')) '英語だけは対象外（JA→EN で訳されない）'
Chk (-not (Test-YakuFileLabelLike -Text '')) '空文字はラベルではない'
Chk (-not (Test-YakuFileLabelLike -Text '   ')) '空白だけもラベルではない'
Chk (-not (Test-YakuFileLabelLike -Text $null)) 'null でも落ちない'

# ---------------------------------------------------------------- 未一致ラベルの抽出
Write-Host '用語集に無いラベルの抽出'
$items = @(
    [pscustomobject]@{ Index=1; Text='販売促進費';   OriginalText='販売促進費' }
    [pscustomobject]@{ Index=2; Text='新規項目A';     OriginalText='新規項目A' }
    [pscustomobject]@{ Index=3; Text='為替影響により営業利益は減少した。'; OriginalText='為替影響により営業利益は減少した。' }
    [pscustomobject]@{ Index=4; Text='新規項目B';     OriginalText='新規項目B' }
    [pscustomobject]@{ Index=5; Text='1,234';         OriginalText='1,234' }
)
# 1 だけが完全一致で置換できた、という状況
$applied = @([pscustomobject]@{ Source='販売促進費'; Target='VM'; ItemIndex=1; Via='exact' })

$labels = @(Get-YakuFileUnmatchedLabels -Items $items -ExactApplied $applied -Direction 'to_en')
$texts = @($labels | ForEach-Object { [string]$_.Text })
Chk ($labels.Count -eq 2) ('未一致のラベルは2件: ' + ($texts -join '、'))
Chk ($texts -contains '新規項目A') '置換できなかったラベルを拾う'
Chk ($texts -contains '新規項目B') '置換できなかったラベルを拾う（2件目）'
Chk (-not ($texts -contains '販売促進費')) '置換できたものは出さない'
Chk (-not ($texts -contains '為替影響により営業利益は減少した。')) '文は出さない（レイアウトは行高で吸収する領域）'
Chk (-not ($texts -contains '1,234')) '数字だけは出さない'
Chk (@($labels | ForEach-Object { [int]$_.Index }) -contains 2) '項目の番号が分かる（どのセルか辿れる）'

Write-Host '並び'
# 判定が完全でない以上、誤って拾ったもの（長めの短文）が上位を占めないようにする。
$order = @(Get-YakuFileUnmatchedLabels -Direction 'to_en' -ExactApplied @() -Items @(
    [pscustomobject]@{ Index=1; Text='その他の包括利益累計額'; OriginalText='その他の包括利益累計額' }
    [pscustomobject]@{ Index=2; Text='販促費'; OriginalText='販促費' }
    [pscustomobject]@{ Index=3; Text='固定販促費'; OriginalText='固定販促費' }
))
Chk (@($order)[0].Text -eq '販促費') '短い順に並ぶ'
Chk (@($order)[-1].Text -eq 'その他の包括利益累計額') '長いものは下へ沈む'

Write-Host '重複と方向'
$dupItems = @(
    [pscustomobject]@{ Index=1; Text='新規項目A'; OriginalText='新規項目A' }
    [pscustomobject]@{ Index=2; Text='新規項目A'; OriginalText='新規項目A' }
    [pscustomobject]@{ Index=3; Text='新規項目 A'; OriginalText='新規項目 A' }
)
$dup = @(Get-YakuFileUnmatchedLabels -Items $dupItems -ExactApplied @() -Direction 'to_en')
Chk ($dup.Count -eq 2) '同じ字面は1件にまとめる'
# 空白違いは別項目として出す。cell-exact は正規化した字面で突き合わせるため、
# 用語集にも別々の行が要る。ここでまとめると、足りない行に気づけない。
Chk (@($dup | ForEach-Object { [string]$_.Text }) -contains '新規項目 A') '空白違いは別のラベルとして出す'
Chk (@(Get-YakuFileUnmatchedLabels -Items $items -ExactApplied $applied -Direction 'to_jp').Count -eq 0) 'EN→JA では出さない（英語のほうが長くなる向きではない）'
Chk (@(Get-YakuFileUnmatchedLabels -Items @() -ExactApplied @() -Direction 'to_en').Count -eq 0) '項目が無ければ0件'
Chk (@(Get-YakuFileUnmatchedLabels -Items $items -ExactApplied $null -Direction 'to_en').Count -eq 3) '用語集が一切効かなければ全ラベルが出る'

Write-Host 'マスク後の本文に引きずられないこと'
# 実際の経路では $item.Text は数値マスク後になる。原文で見ていることを確かめる。
$maskedItems = @([pscustomobject]@{ Index=1; Text='[[N1]]期実績'; OriginalText='2026期実績' })
$maskedLabels = @(Get-YakuFileUnmatchedLabels -Items $maskedItems -ExactApplied @() -Direction 'to_en')
Chk ($maskedLabels.Count -eq 1) 'マスク後でも拾える'
Chk (@($maskedLabels)[0].Text -eq '2026期実績') '原文の字面で出す（用語集へ写せる形）'

# ---------------------------------------------------------------- 警告としての出し方
Write-Host '警告としての出し方'
Chk ((Get-YakuWarningCategoryLabel -Category 'label-not-in-glossary') -eq '用語集に無いラベル') '警告の見出しがある'
$fileText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'FileTranslation.ps1'))
Chk ($fileText -match "Category 'label-not-in-glossary'") '翻訳経路から警告を出している'
Chk ($fileText -match 'Get-YakuFileUnmatchedLabels -Items \$items') '実際の項目から求めている'
# 再依頼はしない。時間がかかるうえ、無茶な翻訳になりやすい。
Chk ($fileText -notmatch 'label-not-in-glossary[\s\S]{0,400}?Invoke-YakuCopilotPrompt') '検出しても再依頼はしない'

# ---------------------------------------------------------------- コーパス文例の適用範囲
Write-Host 'コーパス文例は FULL の手本'
$hits = @([pscustomobject]@{ Score=1.0; Database='英文短信'; Source='英文短信/a.pdf'; Page=1; Text='The equity ratio improved to 45.6%.' })
$section = Get-YakuCorpusExampleSection -Hits $hits
Chk ($section -match 'FULL_TEXT') 'FULL の手本だと名指ししている'
Chk ($section -match 'NOT a model for BRIEF_TEXT') 'BRIEF の手本ではないと明示している'
Chk ($section -match 'BRIEF rules') 'BRIEF は規則に従うと書いている'
# 等長の例文を見せると長さの指示が無視される（IWSLT 2025）。それを打ち消すための一文。
Chk ($section -match 'length and sentence style say nothing') '長さの手本ではないと明示している'

} finally { }

if ($script:fail -gt 0) {
    Write-Host "V91.61 label coverage regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 label coverage regression passed.' -ForegroundColor Green
