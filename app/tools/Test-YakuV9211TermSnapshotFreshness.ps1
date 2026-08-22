<#
.SYNOPSIS
  V92.11: 無関係な用語登録が確認済み行のQCを古く扱い、書き出しを誤って止める欠陥の回帰試験(GitHub issue #102)。

.DESCRIPTION
  _docs/欠陥記録_用語スナップショットの粒度_2026-08-19.md の「測定した再現」をそのまま
  試験へ落としたもの。機構の要点。
    - 個人用語集への書き込み1件で Get-YakuTerminologySnapshotHash(src/Terminology.ps1)が
      変わる(scope・kind・enforcementで絞っていないため、advisoryでもrequiredでも変わる)。
    - Initialize-YakuCatProjectState(src/CatProject.ps1)は、保存済みハッシュと現行ハッシュが
      違うとき、実際に語を含む行だけを古い扱いへ戻す狭め込みを持つ。しかし末尾で
      $Project.TerminologySnapshotHash を無条件に現行値へ書き換える。その結果、語を含まない
      確認済みpassed行まで Test-YakuCatSegmentQcCurrent が偽を返し、
      Get-YakuCatOutputEligibility が segment-qc-not-current を積んで書き出しを止める。
      実際には訳文は1文字も触られていないので、案内文言も誤解を招く。
    - 同じ無条件更新が Update-YakuCatProjectForTerminologyChange(term-add等が開いている
      作業へ呼ぶ)にもある。

  見るのは3つ。
    (a) 原文に含まれない語をadvisoryで個人用語へ1件登録しても、確認済み行のある作業は
        書き出せること(修正前に赤になる主断言)。行自体はreviewed/passedのまま
        (stale化もnot_run化もしていない)であること。
    (b) 正の制御。原文に含まれる語では狭め込みresetが従来どおり働き、stale/not_runに
        なること。「無関係な語で止める」欠陥を直すとき、関係する語で作業を古くするという
        正しい動きまで消してしまわないことを見る。
    (c) 開いている作業への用語変更反映。無関係な語では戻り値0・行無傷・書き出し可
        (修正前に赤になる第2断言)。関係する語では戻り値1以上でstale/not_runになること。

  用語登録はすべて Enforcement advisory(Server.ps1 のpalette学習と同じ)。requiredだと
  terminology-missing=error が別経路で立ち、本欠陥と混ざる。HTTPサーバは立てず、すべて
  in-processで実物の関数を叩く。個人用語集とCAT作業の保存先は $env:YAKULINGO_DATA_DIR の
  一時ディレクトリへ隔離し、finallyで元の値へ必ず戻す(一時フォルダも残置しない)。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-YakuV9211TermSnapshotFreshness.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0

function Chk { param([bool]$c, [string]$m) $script:checks++; if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

Write-Host 'Test-YakuV9211TermSnapshotFreshness'

. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in @($script:YakuSrcModuleFiles)) {
    . (Join-Path (Join-Path $root 'src') $name)
}

# $env:YAKULINGO_DATA_DIR はプロセス全体に効く。退避せずに書き換えると、同じ
# プロセスで動く他の試験・後続処理を汚したまま終わりうる。ここで元の値を控え、
# finallyブロックで必ず戻す。一時フォルダも使い終わったら消す(残置しない)。
$originalDataDirEnv = $env:YAKULINGO_DATA_DIR
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku9211-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuRoot = $root

try {

# CAT作業の保存先も一時領域へ隔離する。この試験は保存しないが、経路が万一
# 触れても利用者の実データへ届かないようにする。
function Get-YakuCatProjectStoreDir { return $tmp }

function New-N9211ConfirmedTextProject {
    param([string]$Source, [string]$Target)
    $project = New-YakuCatTextProject -Root $root -Text $Source -Settings $null -Direction 'to_en' -Translation $Target
    $null = Set-YakuCatSegmentConfirmed -Project $project -Index 0
    return $project
}

function Add-N9211PersonalTerm {
    param($Project, $Segment, [string]$Japanese, [string]$English)
    # 出典(origin_project_id/origin_segment_id)は32桁16進が必須である
    # (New-YakuTerminologyEntryの出典必須規約)。この作業自身のId/SegmentIdを使う。
    # CATのterm-addが実作業から登録するときと同じ形である。
    return Add-YakuTerminologyEntry -Scope personal -Kind occurrence -Enforcement advisory `
        -JapanesePreferred $Japanese -EnglishPreferred $English `
        -OriginProjectId ([string]$Project.Id) -OriginFileName 'test.xlsx' `
        -OriginSegmentId ([string]$Segment.SegmentId) -OriginLocation 'A1'
}

$n9211Source = '売上高は100百万円でした。'
$n9211Target = 'Revenue was 100 million yen.'

# ============================================================ (a) Initialize 経路
Write-Host '-- (a) Initialize-YakuCatProjectState 経路(欠陥記録の再現そのもの) --'

$p1 = New-N9211ConfirmedTextProject -Source $n9211Source -Target $n9211Target
$seg1 = @($p1.Segments)[0]
Chk ([string]$seg1.State -eq 'reviewed' -and [string]$seg1.QcStatus -eq 'passed') 'fixture: 1行を確定するとreviewed/passedになる'
$hashAtConfirm = [string]$seg1.QcTerminologyHash
Chk (-not [string]::IsNullOrWhiteSpace($hashAtConfirm)) 'fixture: 確定時点で行へ用語スナップショット刻印が付いている'

$before = Get-YakuCatOutputEligibility -Project $p1
Chk ([bool]$before.TranslationListEligible) 'BEFORE: 確定済み1行の作業は書き出せる'
Chk (@($before.Reasons).Count -eq 0) 'BEFORE: 書き出しを止める理由は1件も無い'
Chk ([int]$before.UnconfirmedCount -eq 0) 'BEFORE: 未確認行は0'

# 行の原文に含まれない語を1件登録する。
$unrelated = Add-N9211PersonalTerm -Project $p1 -Segment $seg1 -Japanese '梱包発泡材' -English 'Packaging Foam'
Chk ([bool]$unrelated.Added -and $null -ne $unrelated.Entry) 'fixture: 無関係な語(梱包発泡材)をadvisoryで個人用語集へ1件登録できた'
$storeHashAfterAdd = Get-YakuTerminologySnapshotHash -Entries @(Read-YakuPersonalTerminologyEntries)
Chk ($storeHashAfterAdd -ne $hashAtConfirm) 'fixture: 用語集のスナップショットハッシュは点検時と食い違っている(空振りの緑を防ぐ)'

$after = Get-YakuCatOutputEligibility -Project $p1
Chk ([bool]$after.TranslationListEligible) 'AFTER: 原文に含まれない語の登録では書き出しを止めない(issue #102 主断言)'
Chk (@($after.Reasons) -notcontains 'segment-qc-not-current') 'AFTER: 無関係な語で segment-qc-not-current を積まない(issue #102 主断言)'
Chk ([string]$seg1.State -eq 'reviewed' -and [string]$seg1.QcStatus -eq 'passed') 'AFTER: 行はreviewed/passedのまま(stale化もnot_run化もしていない)'
Chk ([string]::Equals([string]$seg1.Translation, $n9211Target, [StringComparison]::Ordinal)) 'AFTER: 訳文は1文字も変わっていない'

# ============================================================ (b) 正の制御
Write-Host '-- (b) 正の制御: 関係する語は従来どおり古くなる --'

$related = Add-N9211PersonalTerm -Project $p1 -Segment $seg1 -Japanese '売上高' -English 'Net sales'
Chk ($null -ne $related.Entry) 'fixture: 関係する語(売上高)の登録結果からEntryが取れている'
# eligibility呼び出しがInitializeを通すので、断言の直前にもう一度通してから見る。
$null = Get-YakuCatOutputEligibility -Project $p1
Chk ([string]$seg1.State -eq 'stale') '関係する語(売上高)では狭め込みresetが生きていて、行はstaleになる'
Chk ([string]$seg1.QcStatus -eq 'not_run') '関係する語(売上高)では点検もnot_runへ戻る'
# ここでもう一度確定してから eligibility を通す。ハッシュの追跡をただ止めるだけの
# 疑似修正では、保存済みの目印が進まないため、開くたびにこの行が stale へ戻る。
# 再確定後も reviewed/passed が維持されることをここで見る(疑似修正を赤に落とす)。
$null = Set-YakuCatSegmentConfirmed -Project $p1 -Index 0
Chk ([string]$seg1.State -eq 'reviewed' -and [string]$seg1.QcStatus -eq 'passed') '関係する語の反映後に再確定するとreviewed/passedへ戻る'
$null = Get-YakuCatOutputEligibility -Project $p1
Chk ([string]$seg1.State -eq 'reviewed' -and [string]$seg1.QcStatus -eq 'passed') '再確定後のeligibilityでも行はstaleへ戻らない'

# ============================================================ (c) Update 経路
Write-Host '-- (c) Update-YakuCatProjectForTerminologyChange 経路 --'

$p2 = New-N9211ConfirmedTextProject -Source $n9211Source -Target $n9211Target
$seg2 = @($p2.Segments)[0]
Chk ([string]$seg2.State -eq 'reviewed' -and [string]$seg2.QcStatus -eq 'passed') 'fixture: 2本目の作業も1行を確定してreviewed/passed'

# (a)(b)とは別の、やはり原文に含まれない語。
$cUnrelated = Add-N9211PersonalTerm -Project $p2 -Segment $seg2 -Japanese '木製パレット' -English 'Wooden Pallet'
$cUnrelatedEntry = $cUnrelated.Entry
if ($null -eq $cUnrelatedEntry) { throw 'N9211_UNRELATED_TERM_UNAVAILABLE' }

$affected = Update-YakuCatProjectForTerminologyChange -Project $p2 -Entry $cUnrelatedEntry
Chk ([int]$affected -eq 0) '開いている作業への無関係な語(木製パレット)の反映では、触った行は0件'
Chk ([string]$seg2.State -eq 'reviewed' -and [string]$seg2.QcStatus -eq 'passed') '無関係な語の反映後も行はreviewed/passedのまま無傷'
$cAfter = Get-YakuCatOutputEligibility -Project $p2
Chk ([bool]$cAfter.TranslationListEligible) '無関係な語の反映後に書き出しを止めない(issue #102 第2断言)'
Chk (@($cAfter.Reasons) -notcontains 'segment-qc-not-current') '無関係な語の反映後に segment-qc-not-current を積まない(issue #102 第2断言)'

# 正の制御。売上高は(b)で既に個人用語集にあるので、同じ内容の再登録はunchangedで
# 戻り、Entryとして既存の1件を返す(重複契約)。それをそのまま使う。
$cRelated = Add-N9211PersonalTerm -Project $p2 -Segment $seg2 -Japanese '売上高' -English 'Net sales'
Chk ($null -ne $cRelated.Entry) 'fixture: 関係する語(売上高)の再登録結果からEntryが取れている'
$affectedRelated = Update-YakuCatProjectForTerminologyChange -Project $p2 -Entry $cRelated.Entry
Chk ([int]$affectedRelated -ge 1) '関係する語(売上高)の反映では戻り値が1以上'
Chk ([string]$seg2.State -eq 'stale' -and [string]$seg2.QcStatus -eq 'not_run') '関係する語(売上高)では行がstale/not_runになる'

} finally {
    # プロセス全体の環境変数を必ず元へ戻し、使った一時フォルダを残置しない。
    $env:YAKULINGO_DATA_DIR = $originalDataDirEnv
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host ('Test-YakuV9211TermSnapshotFreshness: 検査 ' + $script:checks + ' 件、合格。') -ForegroundColor Green; exit 0 }
Write-Host ('Test-YakuV9211TermSnapshotFreshness: 検査 ' + $script:checks + ' 件、' + $script:fail + ' 件不合格。') -ForegroundColor Red
exit 1
