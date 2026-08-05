<#
.SYNOPSIS
  V91.61: BRIEF の略語をアプリ側で当てる処理の回帰テスト。

.DESCRIPTION
  プロンプトに「使え」と書いても守られるかは確率的だが、アプリで当てれば必ず揃う。
  ただし機械的に当てると壊すものがあるため、対象は文脈に依らないものだけに限る。
  ここではその線引きが守られているかを確かめる。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161BriefStyle.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

foreach ($n in @('Paths.ps1','Runtime.ps1','Html.ps1','Settings.ps1','PromptBuilder.ps1','EdgeLaunch.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','FileTranslation.ps1','Corpus.ps1','CorpusSearch.ps1','CorpusReference.ps1','BriefStyle.ps1')) {
    . (Join-Path (Join-Path $root 'src') $n)
}

function Chk { param([bool]$c,[string]$m) if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }
function Conv { param([string]$t) return (Convert-YakuBriefAbbreviations -Text $t) }

Write-Host '月名'
Chk ((Conv 'Results for January and February.') -eq 'Results for Jan. and Feb.') '月名を略す'
Chk ((Conv 'from April to September') -eq 'from Apr. to Sep.') '月名を略す（2）'
Chk ((Conv 'in May') -eq 'in May') 'May は変えない（略語も May）'

Write-Host '語句の置換'
Chk ((Conv 'approximately 10 oku') -eq 'approx. 10 oku') 'approximately -> approx.'
Chk ((Conv 'including tax') -eq 'incl. tax') 'including -> incl.'
Chk ((Conv 'excluding FX impact') -eq 'excl. FX impact') 'excluding -> excl.'
Chk ((Conv 'compared with PY') -eq 'vs. PY') 'compared with -> vs.'
Chk ((Conv 'compared to PY') -eq 'vs. PY') 'compared to -> vs.'
Chk ((Conv 'with tariffs') -eq 'w/ tariffs') 'with -> w/'
Chk ((Conv 'without tariffs') -eq 'w/o tariffs') 'without -> w/o（with より先に当てる）'

Write-Host '定型の金融用語'
Chk ((Conv 'foreign exchange losses') -eq 'FX losses') 'foreign exchange -> FX'
Chk ((Conv 'operating profit rose') -eq 'OP rose') 'operating profit -> OP'
Chk ((Conv 'accounts receivable and accounts payable') -eq 'A/R and A/P') 'A/R と A/P'
Chk ((Conv 'up 3 percentage points') -eq 'up 3 pts') 'percentage points -> pts'
Chk ((Conv 'year-on-year change') -eq 'YoY change') 'ハイフンを含む語も当たる'

Write-Host '長いものから先に当てる'
# 短いほうを先に当てると "sales promotion costs" が食われて
# "fixed VM" のような、固定側と変動側が混ざった形になる。
Chk ((Conv 'fixed sales promotion costs increased') -eq 'Fixed MKT increased') '長い語句が優先される'
Chk ((Conv 'sales promotion costs increased') -eq 'VM increased') '短いほうも単独では当たる'
# 販促費は 変動側 VM / 固定側 Fixed MKT。取り違えると別項目になる。
Chk ((Conv 'fixed promotion costs increased') -eq 'Fixed MKT increased') '固定側は VM にならない'
Chk ((Conv 'promotion costs rose') -eq 'VM rose') '販促費だけでも VM'
Chk ((Conv "subsidiaries' fixed sales promotion costs") -eq 'Subs. Fixed MKT') '子会社の固定側も対で当たる'
Chk ((Conv 'sales promotion costs and fixed sales promotion costs') -eq 'VM and Fixed MKT') '同じ文に両方あっても取り違えない'
Chk ((Conv 'vehicle variable profit') -eq 'VP (Veh.)') '車両変動利益'
Chk ((Conv 'variable profit') -eq 'VP') '変動利益'
Chk ((Conv 'fixed costs and variable costs') -eq 'FC and VC') 'FC と VC'

Write-Host '大文字・小文字'
Chk ((Conv 'Approximately 10 oku') -eq 'Approx. 10 oku') '文頭の大文字を保つ'
Chk ((Conv 'Including tax') -eq 'Incl. tax') '文頭の大文字を保つ（2）'
Chk ((Conv 'Foreign exchange losses') -eq 'FX losses') '元から大文字の略語は影響を受けない'

Write-Host '壊さないこと'
Chk ((Conv 'incline and excluded') -eq 'incline and excluded') '語の一部には当てない'
Chk ((Conv 'within the segment') -eq 'within the segment') 'within は with を含むが当てない'
Chk ((Conv 'approx. 10 oku') -eq 'approx. 10 oku') '既に略されているものは二重に当てない'
Chk ((Conv 'Sales were approximately.') -eq 'Sales were approx.') '終止符が二重にならない'
Chk ((Conv 'and so on ...') -eq 'and so on ...') '三点リーダーは残す'
Chk ((Conv '') -eq '') '空文字でも落ちない'
Chk ((Conv $null) -eq '') 'null でも落ちない'

Write-Host '引用の中は触らない'
# BRIEF 規則 Q1: 引用符が残るなら FULL と字句が一致すること。
$quoted = 'He said "operating profit including tax" was flat.'
Chk ((Conv $quoted) -eq 'He said "operating profit including tax" was flat.') '二重引用符の中は変えない'
$curly = 'The report said “compared with last year” only.'
Chk ((Conv $curly) -eq 'The report said “compared with last year” only.') '全角の引用符でも変えない'
Chk ((Conv 'operating profit "as reported" including tax') -eq 'OP "as reported" incl. tax') '引用の外側は当てる'
Chk ((Conv "the company's operating profit") -eq "the company's OP") 'アポストロフィは引用とみなさない'

Write-Host '文脈に依るものは移していない'
# 機械的に当てると壊すもの。モデルの判断に任せる。
Chk ((Conv 'technological progress') -eq 'technological progress') 'technological は残す'
Chk ((Conv 'technology division') -eq 'technology division') 'technology は移していない（名詞のときだけの規則）'
Chk ((Conv 'Corporate Planning Department') -eq 'Corporate Planning Department') 'corporate は移していない（社名の中では変えない）'
Chk ((Conv 'subsidiaries in Asia') -eq 'subsidiaries in Asia') 'subsidiaries は移していない（表と見出しだけの規則）'
Chk ((Conv 'the standard contract') -eq 'the standard contract') 'standard は移していない（普通の語と衝突する）'
Chk ((Conv 'actual results') -eq 'actual results') 'actual は移していない（形容詞として普通に使う）'

Write-Host 'BRIEF だけに当てる'
$options = @(
    [pscustomobject]@{ Style='full';  Label='FULL';  Translation='Operating profit increased approximately 10 oku.'; Explanation='' }
    [pscustomobject]@{ Style='brief'; Label='BRIEF'; Translation='Operating profit up approximately 10 oku.'; Explanation='' }
)
$converted = @(Convert-YakuBriefTranslationOptions -Options $options)
Chk ($converted.Count -eq 2) '件数は変わらない'
Chk ((@($converted | Where-Object { $_.Style -eq 'full' })[0].Translation) -eq 'Operating profit increased approximately 10 oku.') 'FULL は触らない（spelled-out が正しい）'
Chk ((@($converted | Where-Object { $_.Style -eq 'brief' })[0].Translation) -eq 'OP up approx. 10 oku.') 'BRIEF だけ当てる'
Chk ($options[1].Translation -eq 'Operating profit up approximately 10 oku.') '元の配列を書き換えない'
$jp = @([pscustomobject]@{ Style='jp'; Label='JAPANESE'; Translation='営業利益は増加した。'; Explanation='' })
Chk ((@(Convert-YakuBriefTranslationOptions -Options $jp)[0].Translation) -eq '営業利益は増加した。') 'EN→JA には対象が無い'
Chk (@(Convert-YakuBriefTranslationOptions -Options $null).Count -eq 0) 'null でも落ちない'

Write-Host '数値プレースホルダーを壊さないこと'
# 復元前に当てるので【N1】が残っている。ここを壊すと V91.60 の保証が崩れる。
Chk ((Conv 'Operating profit up approximately 【N1】 oku vs. 【N2】 oku.') -eq 'OP up approx. 【N1】 oku vs. 【N2】 oku.') 'プレースホルダーはそのまま'

Write-Host '翻訳経路への組み込み'
$translationText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Translation.ps1'))
# 呼び出しだけを数える。存在確認（Get-Command …）は呼び出しではない。
$hookCount = ([regex]::Matches($translationText, 'Convert-YakuBriefTranslationOptions -Options')).Count
Chk ($hookCount -eq 2) ('キャッシュ命中とそれ以外の両方に入っている: ' + $hookCount)
# 復元より前に置く。復元後の数字（12,340 など）を語として拾わせないため。
$convAt = $translationText.IndexOf('Convert-YakuBriefTranslationOptions -Options $options')
$restoreAt = $translationText.IndexOf('Restore-YakuMaskedTranslationOptions -Options $options')
Chk ($convAt -ge 0 -and $restoreAt -gt $convAt) 'マスク復元より前に当てる'

Write-Host '読み込まれていない経路でも止まらない'
# Translation.ps1 を読むが BriefStyle.ps1 を読まない経路（別ランスペース・
# ワーカー・部分的に読み込む回帰テスト）で翻訳を止めない。
# 当たらなければ従来どおりモデルの出力のままになるだけである。
$guards = ([regex]::Matches($translationText, 'Get-Command Convert-YakuBriefTranslationOptions')).Count
Chk ($guards -eq 2) ('両方の呼び出しが守られている: ' + $guards)

Write-Host 'プロンプトから外れていること'
$briefRules = Get-YakuBriefRules -Root $root
Chk ($briefRules -notmatch 'Months: Jan\., Feb\.') '月名の一覧が消えている'
Chk ($briefRules -notmatch 'foreign exchange -> FX') 'FX の対応が消えている'
Chk ($briefRules -notmatch 'operating profit=OP') 'OP の対応が消えている'
Chk ($briefRules -notmatch 'fixed costs / fixed cost -> FC') 'FC の対応が消えている'
# 文脈に依るものは残っている。外すと壊れる。
Chk ($briefRules -match 'corporate -> corp\. only as adjective') '文脈に依るものは残っている'
Chk ($briefRules -match 'subsidiaries -> Subs\. in table items') '文脈に依るものは残っている（2）'
Chk ($briefRules -match 'technology -> tech') '文脈に依るものは残っている（3）'
Chk ($briefRules -match 'applied automatically') 'アプリ側で当てることをモデルへ伝えている'

if ($script:fail -gt 0) {
    Write-Host "V91.61 brief style regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 brief style regression passed.' -ForegroundColor Green
