<#
.SYNOPSIS
  任意位置での分割（1行を原文の途中で2つに割る）の回帰テスト。

.DESCRIPTION
  なぜ要るか。これまでの繋ぎ直しは「次の行とつなげる」と「つなげた行を元に
  戻す」の2つだけで、割れるのはセルの境目までだった。1つのセルの中に2文が
  入っていると、そこから先は Excel を開いて直すことになり、書き戻しの往復が
  壊れる。memoQ(Ctrl+T) / Phrase(Ctrl+E) / Smartcat / Trados / XTM のどれもが
  任意位置の分割を持っているのは、日本語の自動分割が「。」や箇条書きで外れる
  のが日常だからである。

  見るのは9つ。
   (a) 指定位置で原文が2分され、両方の SegmentId が新規に振られる
   (b) 書き戻しで、割った2行が元の1セルへ結合されて入る
   (c) 訳文は両方とも消える（決めたとおりに動く）
   (d) 割った直後は Confirmed=$false で、確定時に必ず点検を通る
   (e) 割った行を結合すると元の原文に戻る（可逆）
   (f) 位置の境界（0・末尾・範囲外・空白だけ）を弾く
   (g) 画面（cat.js / cat.html）と口（Server.ps1）が実物どうしでつながっている
   (h) 保存して読み直しても、割った印が残る
   (i) トークン（単語・数字）の内側では割らせない・繋ぐときに空白を入れない

  (b) は Excel がある環境では実ファイルの往復まで見る。無い環境では
  配置計画（PlacementPlan）の段まで見る。

  (i) は 2026-08-15 の欠陥。原文 `型式はAB-1234を採用します。` を位置6で割ると
  書き戻しが `The model is AB- 1234 will be adopted.` になり、トークンの内側へ
  空白が入る。数字は1桁も欠けないので数値QCに掛からず、割った後は片側ずつしか
  点検しないので原理的に見えない。2層で塞ぐ（割らせない／繋ぎ方を直す）ので、
  両方をここで見る。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9173SegmentSplitAt.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0
$script:checks = 0

function Chk { param([bool]$c,[string]$m) $script:checks++; if($c){Write-Host ('  ok   ' + $m) -ForegroundColor Green}else{Write-Host ('  FAIL ' + $m) -ForegroundColor Red;$script:fail++} }

# 読み込み順序は SrcModules.ps1 が唯一の出典。写すと写し間違いが静かに効く。
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach ($name in $script:YakuSrcModuleFiles) { . (Join-Path (Join-Path $root 'src') $name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-splitat-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'user-data'
$script:YakuCatTestStore = Join-Path $tmp 'cat-store'
$null = New-Item -ItemType Directory -Path $script:YakuCatTestStore -Force
function Get-YakuCatProjectStoreDir { return $script:YakuCatTestStore }

$settings = Read-YakuSettings -Root $root
$script:YakuRoot = $root

# ---------------------------------------------------------------- 素材（Excel不要）
$safeStructure = [pscustomobject]@{contract_version='excel-cell-structure-v2';read_status='verified';merge_kind='none';merge_area='';has_formula=$false;has_array_formula=$false;has_spill=$false;worksheet_protect_contents=$false;cell_locked=$false;validation_type='none';wrap_text='False'}
$safeStructureHash = Get-YakuCatSourceIntegrityHash -Text ($safeStructure | ConvertTo-Json -Depth 6 -Compress)

function New-TestCellProject {
    <# セル1つぶんの最小 project。Excel が無くても配置計画まで通せる形にする。 #>
    param([Parameter(Mandatory=$true)][string[]]$Texts)
    $segments = New-Object System.Collections.Generic.List[object]
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Texts.Count; $i++) {
        $address = 'A' + [string]($i + 1)
        $blockId = 'b' + [string]($i + 1)
        $cell = [pscustomobject]@{Text=[string]$Texts[$i];Address=$address;Row=($i+1);Column=1;IsText=$true;IsMerged=$false;BlockId=$blockId;SheetCodeName='Sheet1';StructureContract=$safeStructure;StructureFingerprint=$safeStructureHash}
        [void]$segments.Add([pscustomobject]@{
            SegmentId=''; Text=[string]$Texts[$i]; Translation=''; Origin=''; Kind='cell'
            BlockIds=@($blockId); Cells=@($cell); Sheet='Sheet1'; Location=('Sheet1, ' + $address); Joined=$false
        })
        [void]$blocks.Add([pscustomobject]@{Id=$blockId;Text=[string]$Texts[$i];Location=('Sheet1, ' + $address);Meta=[pscustomobject]@{Kind='cell';Sheet='Sheet1';Row=($i+1);Col=1;A1=$address;Merged=$false;SheetCodeName='Sheet1';StructureContract=$safeStructure;StructureFingerprint=$safeStructureHash}})
    }
    $project = [pscustomobject]@{
        Id=([guid]::NewGuid().ToString('N')); Path=(Join-Path $tmp 'nonexistent.xlsx'); FileName='in.xlsx'
        ActiveSourceId=('1'*32); SourceArtifactSha256=('5'*64); Revision=1; Source='file'; DocumentFormat='xlsx'
        Direction='to_en'; TerminologySnapshotHash=''; Segments=@($segments.ToArray()); Blocks=@($blocks.ToArray())
        PlacementPlans=@(); PlacementSetHash=''; DocumentFindings=@(); ReviewRuns=@(); ReviewEvents=@(); FinalReviewDecisions=@()
        CreatedAt=(Get-Date).ToString('s')
    }
    $null = Initialize-YakuCatProjectState -Project $project
    return $project
}

function New-TestSplitDocx {
    <#
      段落だけの docx を作る。実 Word は要らない（zip と XML だけ）。
      Excel 側と同じ往復を Word でも通すために使う。
    #>
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Paragraphs)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bodyXml = ''
    foreach ($text in $Paragraphs) { $bodyXml += '<w:p><w:r><w:t>' + [Security.SecurityElement]::Escape([string]$text) + '</w:t></w:r></w:p>' }
    $parts = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
        'word/document.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + $bodyXml + '<w:sectPr/></w:body></w:document>'
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($name in $parts.Keys) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write([string]$parts[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}

try {
    # ================================================================ (a)
    Write-Host '(a) 指定位置で原文が2分され、SegmentId が新規に振られる' -ForegroundColor Cyan
    $head = '当社は生産体制を見直しました。'
    $tail = '調達費も削減しました。'
    $whole = $head + $tail
    $pa = New-TestCellProject -Texts @($whole)
    $beforeId = [string]@($pa.Segments)[0].SegmentId
    Chk ($beforeId -match '^[a-f0-9]{32}$') '割る前の行に SegmentId がある'
    $null = Split-YakuCatSegmentAt -Project $pa -Index 0 -Position ($head.Length)
    $sa = @($pa.Segments)
    Chk ($sa.Count -eq 2) ('1行が2行になる（実際 ' + $sa.Count + ' 行）')
    Chk ([string]$sa[0].Text -eq $head) '前半は指定位置までの原文そのもの'
    Chk ([string]$sa[1].Text -eq $tail) '後半は指定位置からの原文そのもの'
    Chk ((([string]$sa[0].Text) + ([string]$sa[1].Text)) -ceq $whole) '2つを繋ぐと元の原文へ一致する（1文字も落ちない）'
    Chk ([string]$sa[0].SegmentId -ne $beforeId -and [string]$sa[1].SegmentId -ne $beforeId) '両方の SegmentId が新規'
    Chk ([string]$sa[0].SegmentId -ne [string]$sa[1].SegmentId) '2つの SegmentId は互いに違う'
    Chk (([string]$sa[0].SegmentId -match '^[a-f0-9]{32}$') -and ([string]$sa[1].SegmentId -match '^[a-f0-9]{32}$')) 'SegmentId の形が既存と同じ'
    $groupA = Get-YakuCatSegmentSplitGroupId -Segment $sa[0]
    Chk (-not [string]::IsNullOrWhiteSpace($groupA) -and $groupA -eq (Get-YakuCatSegmentSplitGroupId -Segment $sa[1])) '同じ組（SplitGroupId）に入る'
    Chk ([int]$sa[0].SplitOrdinal -eq 0 -and [int]$sa[1].SplitOrdinal -eq 1) '組の中の並び番号が 0,1'
    Chk ((@($sa[0].BlockIds) -join '|') -eq 'b1' -and (@($sa[1].BlockIds) -join '|') -eq 'b1') '両方が元の同じセルを指す'
    Chk ([string]$sa[0].SourceIntegrityHash -eq (Get-YakuCatSourceIntegrityHash -Text $head)) '前半の原文ハッシュが張り替わる'
    Chk ([string]$sa[1].SourceIntegrityHash -eq (Get-YakuCatSourceIntegrityHash -Text $tail)) '後半の原文ハッシュが張り替わる'

    # ================================================================ (c)(d)
    Write-Host '(c)(d) 訳文は両方消え、未確認から始まる' -ForegroundColor Cyan
    $pc = New-TestCellProject -Texts @($whole)
    $null = Set-YakuCatSegmentTranslation -Project $pc -Index 0 -Text 'We reviewed our production system and also reduced procurement costs.'
    $null = Set-YakuCatSegmentConfirmed -Project $pc -Index 0
    Chk ([bool]@($pc.Segments)[0].Confirmed) '割る前は確認済みにできている（この検査が空振りでないこと）'
    $null = Split-YakuCatSegmentAt -Project $pc -Index 0 -Position ($head.Length)
    $sc = @($pc.Segments)
    Chk ([string]::IsNullOrWhiteSpace([string]$sc[0].Translation) -and [string]::IsNullOrWhiteSpace([string]$sc[1].Translation)) '訳文は両方とも消える'
    Chk (-not [bool]$sc[0].Confirmed -and -not [bool]$sc[1].Confirmed) '割った直後は両方とも未確認'
    Chk ([string]$sc[0].State -eq 'untranslated' -and [string]$sc[1].State -eq 'untranslated') '状態も未翻訳へ戻る'
    Chk ([string]$sc[0].QcStatus -eq 'not_run' -and [string]$sc[1].QcStatus -eq 'not_run') '点検は走っていない扱い'
    Chk ([string]$sc[0].Origin -eq '' -and [string]$sc[1].Origin -eq '') '出どころも引き継がない'

    # 確定時に必ず点検を通る。数値が抜けた訳は確定できない（§8）。
    $pd = New-TestCellProject -Texts @('売上高は120億円でした。費用は30億円でした。')
    $null = Split-YakuCatSegmentAt -Project $pd -Index 0 -Position ('売上高は120億円でした。'.Length)
    $null = Set-YakuCatSegmentTranslation -Project $pd -Index 0 -Text 'Revenue rose.'
    $qcBlocked = $false; $qcCode = ''
    try { $null = Set-YakuCatSegmentConfirmed -Project $pd -Index 0 } catch { $qcBlocked = $true; $qcCode = [string]$_.Exception.Message }
    Chk ($qcBlocked -and $qcCode -match 'CAT_REVIEW_QC_FAILED') ('割った行でも数値の点検が確定を止める（' + $qcCode + '）')
    Chk (-not [bool]@($pd.Segments)[0].Confirmed) '落ちた行は確認済みにならない'
    $null = Set-YakuCatSegmentTranslation -Project $pd -Index 0 -Text 'Revenue was 120 oku yen.'
    $qcPassed = $true
    try { $null = Set-YakuCatSegmentConfirmed -Project $pd -Index 0 } catch { $qcPassed = $false }
    Chk ($qcPassed -and [bool]@($pd.Segments)[0].Confirmed) '数値が揃えば割った行も確定できる'

    # 決めた内容がコメントとして実装に残っているか（受入条件 c）。
    $catProjectSource = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CatProject.ps1'), [Text.UTF8Encoding]::new($false))
    $splitAtAst = [System.Management.Automation.Language.Parser]::ParseInput($catProjectSource, [ref]$null, [ref]$null)
    $splitAtFunc = @($splitAtAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Split-YakuCatSegmentAt' }, $true))
    Chk ($splitAtFunc.Count -eq 1) 'Split-YakuCatSegmentAt が1つだけ定義されている'
    $splitAtText = if ($splitAtFunc.Count -eq 1) { [string]$splitAtFunc[0].Extent.Text } else { '' }
    Chk ($splitAtText -match '訳文' -and $splitAtText -match '消す') '訳文をどう扱うと決めたかが実装のコメントに書いてある'

    # ================================================================ (e)
    Write-Host '(e) 割った行を結合すると元の原文に戻る' -ForegroundColor Cyan
    $pe = New-TestCellProject -Texts @($whole)
    $null = Split-YakuCatSegmentAt -Project $pe -Index 0 -Position ($head.Length)
    $null = Set-YakuCatSegmentTranslation -Project $pe -Index 0 -Text 'We reviewed our production system.'
    $null = Merge-YakuCatSegments -Project $pe -Index 0
    $se = @($pe.Segments)
    Chk ($se.Count -eq 1) ('2行が1行へ戻る（実際 ' + $se.Count + ' 行）')
    Chk ([string]$se[0].Text -ceq $whole) '原文が割る前と一字一句同じへ戻る'
    Chk ([string]::IsNullOrWhiteSpace([string]$se[0].Translation)) '結合でも訳文は消える（Merge と同じ決まり）'
    Chk ((Get-YakuCatSegmentSplitGroupId -Segment $se[0]) -eq '') '組の印が外れて、ふつうの行へ戻る'
    Chk ((@($se[0].BlockIds) -join '|') -eq 'b1') '元のセルを1つだけ指したまま'
    Chk (-not [bool]$se[0].Confirmed) '戻した行も未確認から始まる'

    # 3つに割って、2回結合しても戻る。
    $pe3 = New-TestCellProject -Texts @($whole)
    $null = Split-YakuCatSegmentAt -Project $pe3 -Index 0 -Position ($head.Length)
    $null = Split-YakuCatSegmentAt -Project $pe3 -Index 0 -Position 5
    Chk (@($pe3.Segments).Count -eq 3) '割った行をさらに割れる'
    $groups3 = @(@($pe3.Segments) | ForEach-Object { Get-YakuCatSegmentSplitGroupId -Segment $_ } | Select-Object -Unique)
    Chk ($groups3.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$groups3[0])) '3つとも同じ組に入る'
    Chk ((@(@($pe3.Segments) | ForEach-Object { [int]$_.SplitOrdinal }) -join ',') -eq '0,1,2') '並び番号が振り直される'
    $null = Merge-YakuCatSegments -Project $pe3 -Index 0
    $null = Merge-YakuCatSegments -Project $pe3 -Index 0
    Chk (@($pe3.Segments).Count -eq 1 -and [string]@($pe3.Segments)[0].Text -ceq $whole) '2回結合すると元の原文へ戻る'

    # ================================================================ (f)
    Write-Host '(f) 位置の境界を弾く' -ForegroundColor Cyan
    foreach ($bad in @(0, -1, $whole.Length, ($whole.Length + 1), 9999)) {
        $pf = New-TestCellProject -Texts @($whole)
        $threw = $false
        try { $null = Split-YakuCatSegmentAt -Project $pf -Index 0 -Position $bad } catch { $threw = $true }
        Chk $threw ('位置 ' + $bad + ' は弾く')
        Chk (@($pf.Segments).Count -eq 1) ('位置 ' + $bad + ' では行が増えない')
    }
    # 片方が空白だけになる位置も弾く。空の行は書き出しを永久に止める。
    $pfw = New-TestCellProject -Texts @('  あいうえお')
    $threwWs = $false
    try { $null = Split-YakuCatSegmentAt -Project $pfw -Index 0 -Position 1 } catch { $threwWs = $true }
    Chk $threwWs '割ると片方が空白だけになる位置は弾く'
    # 繋いだ行はそのままでは割らせない（先に「元に戻す」で境目へ戻す）。
    $pfj = New-TestCellProject -Texts @('当第1四半期は、生産体制の見直しにより','固定費を圧縮しました。')
    $null = Merge-YakuCatSegments -Project $pfj -Index 0
    Chk (@($pfj.Segments).Count -eq 1 -and @(@($pfj.Segments)[0].Cells).Count -eq 2) '2セルを繋いだ行を用意できた（この検査が空振りでないこと）'
    Chk (-not (Test-YakuCatSegmentSplittable -Segment @($pfj.Segments)[0])) '繋いだ行は「途中で割れる」とは言わない'
    $threwJoined = $false
    try { $null = Split-YakuCatSegmentAt -Project $pfj -Index 0 -Position 5 } catch { $threwJoined = $true }
    Chk $threwJoined '繋いだ行を途中で割ろうとすると止まる'
    # 存在しない行番号
    $threwIndex = $false
    try { $null = Split-YakuCatSegmentAt -Project $pfj -Index 9 -Position 3 } catch { $threwIndex = $true }
    Chk $threwIndex '存在しない行番号は弾く'

    # 割った行は、割った相手以外とは繋げない（組が離れると書き戻しが壊れる）。
    $pfm = New-TestCellProject -Texts @($whole, '営業利益')
    $null = Split-YakuCatSegmentAt -Project $pfm -Index 0 -Position ($head.Length)
    Chk (@($pfm.Segments).Count -eq 3) '割ったので3行になる（この検査が空振りでないこと）'
    Chk (Test-YakuCatSegmentsMergeable -First @($pfm.Segments)[0] -Second @($pfm.Segments)[1]) '割った相手とは繋げる'
    Chk (-not (Test-YakuCatSegmentsMergeable -First @($pfm.Segments)[1] -Second @($pfm.Segments)[2])) '割った行と別の行は繋げない'
    $threwCross = $false
    try { $null = Merge-YakuCatSegments -Project $pfm -Index 1 } catch { $threwCross = $true }
    Chk $threwCross '割った行と別の行を繋ごうとすると止まる'
    Chk (@($pfm.Segments).Count -eq 3) '止まったので行数は変わらない'

    # ================================================================ (b)
    Write-Host '(b) 書き戻しで、割った2行が元の1セルへ結合されて入る' -ForegroundColor Cyan
    $pb = New-TestCellProject -Texts @($whole, '営業利益')
    $null = Split-YakuCatSegmentAt -Project $pb -Index 0 -Position ($head.Length)
    $null = Set-YakuCatSegmentTranslation -Project $pb -Index 0 -Text 'We reviewed our production system.'
    $null = Set-YakuCatSegmentTranslation -Project $pb -Index 1 -Text 'We also reduced procurement costs.'
    $null = Set-YakuCatSegmentTranslation -Project $pb -Index 2 -Text 'Operating profit'
    $expectedJoined = 'We reviewed our production system. We also reduced procurement costs.'

    $bySegment = @{0='We reviewed our production system.';1='We also reduced procurement costs.';2='Operating profit'}
    $byBlock = Get-YakuCatPlacementTranslationByBlockId -Project $pb -TranslationBySegmentIndex $bySegment
    Chk ($byBlock.Count -eq 2) ('塊は2つ（割っても増えない）: ' + $byBlock.Count)
    Chk ([string]$byBlock['b1'] -eq $expectedJoined) ('割った2行が元の1セルへ順に入る: ' + [string]$byBlock['b1'])
    Chk ([string]$byBlock['b1'] -match 'reviewed' -and [string]$byBlock['b1'] -match 'procurement') '前半の訳が後半に上書きされていない'
    Chk ([string]$byBlock['b2'] -eq 'Operating profit') '割っていない行はそのまま'

    # 配置計画も1つに畳まれる（同じセルを2つの計画が指すと出力が止まる）。
    $plans = @($pb.PlacementPlans)
    Chk ($plans.Count -eq 2) ('配置計画は2件（割った2行で1件）: ' + $plans.Count)
    $splitPlan = @($plans | Where-Object { @($_.destinations | Where-Object { [string]$_.block_id -eq 'b1' }).Count -gt 0 })
    Chk ($splitPlan.Count -eq 1) '同じセルを指す配置計画は1つだけ'
    Chk ([string]$splitPlan[0].destinations[0].text -eq $expectedJoined) '配置計画にも繋いだ訳文が入る'
    Chk ([string]$splitPlan[0].segment_id -eq (Get-YakuCatSegmentSplitGroupId -Segment @($pb.Segments)[0])) '配置計画は組の番号で持つ'

    # 画面（体裁で見る）でも、割った2行は同じ1セルを指す。別々に置くと同じ番地へ
    # 二重に描き、後の行だけが見える。
    $viewB = (ConvertTo-YakuCatProjectJson -Project $pb) | ConvertFrom-Json
    $rowsB = @($viewB.segments)
    Chk ($null -ne $rowsB[0].placement -and $null -ne $rowsB[1].placement) '割った2行のどちらにも配置が出る'
    Chk ([string]$rowsB[0].placement.placement_id -eq [string]$rowsB[1].placement.placement_id) '2行が同じ配置計画を指す'
    Chk ([string]$rowsB[0].placement.destinations[0].text -eq $expectedJoined) '画面に出す配置先の文字も、繋いだ訳文'
    # 「体裁で見る」は split_group / split_part で1つへまとめる。名前が無いと
    # 同じ番地へ2回描き、あとの行だけが見える。
    Chk ([string]$rowsB[0].split_group -ne '' -and [string]$rowsB[0].split_group -eq [string]$rowsB[1].split_group) '画面が同じ組と分かる名前を応答が持つ'
    Chk ([int]$rowsB[0].split_part -eq 1 -and [int]$rowsB[1].split_part -eq 2) '何番目かが 1,2 で出る'
    Chk ([string]$rowsB[2].split_group -eq '' -and [int]$rowsB[2].split_parts -eq 0) '割っていない行には組の名前を出さない'
    $previewJs = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www\assets') 'cat.js'), [Text.UTF8Encoding]::new($false))
    Chk ($previewJs -match 'segment\.split_group && Number\(segment\.split_part\) !== 1') '体裁で見るは、割った行を先頭1つにまとめて置く'
    Chk ($previewJs -match 'splitSources\[segment\.split_group\]') '体裁で見るの原文側は、割った行の原文を繋いで出す'
    # 割った行からでもセルの区切りを確定できる（行き止まりを作らない）。
    $sliceResult = $null; $sliceNote = ''
    try { $sliceResult = Set-YakuCatPlacementSlices -Project $pb -Index 1 -Slices @($expectedJoined) } catch { $sliceNote = ' / ' + [string]$_.Exception.Message }
    Chk ($null -ne $sliceResult -and [string]$sliceResult.placement_kind -eq 'human_confirmed') ('割った行からでもセルの区切りを確定できる' + $sliceNote)

    # セル層の割り戻し（Excel往復テストが通る経路）も同じ答えを出す。
    $byBlockCell = Get-YakuSegmentTranslationByBlockId -Segments @($pb.Segments) -TranslationBySegmentIndex $bySegment
    Chk ($byBlockCell.Count -eq 2) ('セル層でも塊は2つ: ' + $byBlockCell.Count)
    Chk ([string]$byBlockCell['b1'] -eq $expectedJoined) 'セル層でも割った2行が1セルへ結合される'

    # 貼り付け本文でも、割った行は元の1つとして繋がって出る。
    # 貼り付け本文は「。」で自動的に切れるので、1行のままになる文を使う。
    # （そもそも自動の切り分けが1文にまとめてしまう場面が、この機能の出番である）
    $textHead = '当社は生産体制を見直し、'
    $textTail = '調達費も削減しました。'
    $textWhole = $textHead + $textTail
    $pt = New-YakuCatTextProject -Root $root -Text ($textWhole + "`n" + '営業利益は増えました。') -Settings $settings -Direction 'to_en'
    $ptSegs = @($pt.Segments)
    $ptIndex = -1
    for ($i = 0; $i -lt $ptSegs.Count; $i++) { if ([string]$ptSegs[$i].Text -eq $textWhole) { $ptIndex = $i } }
    Chk ($ptIndex -ge 0) '貼り付け本文で、割る対象の行が取れる'
    if ($ptIndex -ge 0) {
        $null = Split-YakuCatSegmentAt -Project $pt -Index $ptIndex -Position ($textHead.Length)
        $null = Set-YakuCatSegmentTranslation -Project $pt -Index $ptIndex -Text 'We reviewed our production system.'
        $null = Set-YakuCatSegmentTranslation -Project $pt -Index ($ptIndex + 1) -Text 'We also reduced procurement costs.'
        for ($i = 0; $i -lt @($pt.Segments).Count; $i++) {
            if ([string]::IsNullOrWhiteSpace([string]@($pt.Segments)[$i].Translation)) { $null = Set-YakuCatSegmentTranslation -Project $pt -Index $i -Text 'Operating profit rose.' }
        }
        $textOut = Get-YakuCatTextOutput -Project $pt
        Chk ($textOut -match 'We reviewed our production system\. We also reduced procurement costs\.') ('割った行が1行として繋がって出る: ' + ($textOut -replace "`n", '\n'))
        Chk (($textOut -split "`n").Count -eq 2) ('行数は割る前と同じ2行（実際 ' + ($textOut -split "`n").Count + ' 行）')
    }
    Remove-YakuCatProject -Id ([string]$pt.Id)

    # ============================================================= (b3) Word
    # Word の出口には門が1件も無かった。Export-YakuWordDraft から
    # Group-YakuCatSplitSegments（畳み）を外しても、この試験も
    # Test-YakuV9163WordAdapter も緑のままだった（2026-08-15 の指摘、実測）。
    # 畳まないと、同じ段落IDへ後半の訳が上書きし、**前半の訳が黙って消えた
    # 資料が出る**。Excel 側でやっているのと同じ往復をここでも通す。
    # 実 Word は要らない。docx は zip と XML なので、書き出した中身を読み返す。
    Write-Host '(b3) Word の書き戻しでも、割った2行が元の1段落へ結合されて入る' -ForegroundColor Cyan
    $docxPath = Join-Path $tmp 'split-word.docx'
    New-TestSplitDocx -Path $docxPath -Paragraphs @($textWhole, '営業利益は増えました。')
    $pw = New-YakuCatProject -Root $root -Path $docxPath -Settings $settings -Direction 'to_en'
    $wsegs = @($pw.Segments)
    $wIndex = -1
    for ($i = 0; $i -lt $wsegs.Count; $i++) { if ([string]$wsegs[$i].Text -eq $textWhole) { $wIndex = $i } }
    Chk ($wIndex -ge 0) 'Word の段落から、割る対象の行が取れる'
    if ($wIndex -ge 0) {
        Chk ([string]$wsegs[$wIndex].Kind -like 'word_*') ('対象は Word の段落である: ' + [string]$wsegs[$wIndex].Kind)
        Chk (Test-YakuCatSegmentSplittable -Segment $wsegs[$wIndex]) 'Word の段落も原文の途中で割れる'
        $wBlockId = [string]@($wsegs[$wIndex].BlockIds)[0]
        $null = Split-YakuCatSegmentAt -Project $pw -Index $wIndex -Position ($textHead.Length)
        Chk (@($pw.Segments).Count -eq ($wsegs.Count + 1)) '割ると行が1つ増える'
        $null = Set-YakuCatSegmentTranslation -Project $pw -Index $wIndex -Text 'We reviewed our production system.'
        $null = Set-YakuCatSegmentTranslation -Project $pw -Index ($wIndex + 1) -Text 'We also reduced procurement costs.'
        for ($i = 0; $i -lt @($pw.Segments).Count; $i++) {
            if ([string]::IsNullOrWhiteSpace([string]@($pw.Segments)[$i].Translation)) { $null = Set-YakuCatSegmentTranslation -Project $pw -Index $i -Text 'Operating profit rose.' }
        }
        for ($i = 0; $i -lt @($pw.Segments).Count; $i++) { $null = Set-YakuCatSegmentConfirmed -Project $pw -Index $i }

        # 割った2行が同じ段落IDを指していること。ここが前提で、畳まないと壊れる。
        $wParts = @(@($pw.Segments) | Where-Object { @($_.BlockIds) -contains $wBlockId })
        Chk ($wParts.Count -eq 2) ('割った2行が同じ段落IDを指す（実際 ' + $wParts.Count + ' 行）')

        # 段落IDごとの訳文。書き出し本体（WordAdapter.ps1）が作るのと同じ表を、
        # 同じ関数から作って中身を見る。畳みが外れると、ここが後半だけになる。
        $wordMap = @{}
        foreach ($unit in @(Group-YakuCatSplitSegments -Segments @($pw.Segments))) {
            foreach ($id in @($unit.Segment.BlockIds)) { $wordMap[[string]$id] = [string]$unit.Segment.Translation }
        }
        Chk ([string]$wordMap[$wBlockId] -eq $expectedJoined) ('段落IDごとの訳文が前半＋後半になる: ' + [string]$wordMap[$wBlockId])

        $wordOut = Join-Path $tmp 'DRAFT_split-word.docx'
        $wordNote = ''; $wordResult = $null
        try { $wordResult = Export-YakuCatProject -Project $pw -OutputPath $wordOut -Settings $settings } catch { $wordNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $wordResult -and (Test-Path -LiteralPath $wordOut)) ('割った行があっても Word の DRAFT を書き出せる' + $wordNote)
        if (Test-Path -LiteralPath $wordOut) {
            # 書き出した docx を読み返す。名前の在否ではなく、段落の本文そのもの。
            $afterInv = Get-YakuWordDocumentInventory -Path $wordOut
            $afterBlocks = @($afterInv.Blocks)
            $writtenText = [string]@($afterBlocks | Where-Object { [string]$_.Id -eq $wBlockId })[0].Text
            Chk ($afterBlocks.Count -eq $wsegs.Count) ('段落の数は割る前と同じ（実際 ' + $afterBlocks.Count + '）')
            Chk ($writtenText -eq $expectedJoined) ('Word の段落に前半＋後半が入る: ' + $writtenText)
            Chk ($writtenText -match 'reviewed' -and $writtenText -match 'procurement') 'Word でも前半の訳が後半に上書きされていない'
            # 空振り防止。畳まない素の走査だと後半だけになる、という比較をここで作る。
            $naive = @{}
            foreach ($seg in @($pw.Segments)) { foreach ($id in @($seg.BlockIds)) { $naive[[string]$id] = [string]$seg.Translation } }
            Chk ([string]$naive[$wBlockId] -eq 'We also reduced procurement costs.') '畳まなければ後半だけになる題材である（この検査が空振りでないこと）'
            Chk ($writtenText -ne [string]$naive[$wBlockId]) '書き出した本文は、畳まなかった場合の本文と違う'
        }
    }
    Remove-YakuCatProject -Id ([string]$pw.Id)

    # ================================================================ (h)
    Write-Host '(h) 保存して読み直しても割った印が残る' -ForegroundColor Cyan
    $ph = New-YakuCatTextProject -Root $root -Text ($textWhole) -Settings $settings -Direction 'to_en'
    $ph = Commit-YakuNewCatProject -Project $ph
    $null = Split-YakuCatSegmentAt -Project $ph -Index 0 -Position ($textHead.Length)
    $null = Save-YakuCatProject -Project $ph
    $savedId = [string]$ph.Id
    $groupBefore = Get-YakuCatSegmentSplitGroupId -Segment @($ph.Segments)[0]
    Remove-YakuCatProject -Id $savedId
    $restored = Restore-YakuCatProject -Id $savedId
    $rs = @($restored.Segments)
    Chk ($rs.Count -eq 2) ('読み直しても2行のまま（実際 ' + $rs.Count + ' 行）')
    Chk ((Get-YakuCatSegmentSplitGroupId -Segment $rs[0]) -eq $groupBefore) '組の番号が保存・復元で保たれる'
    Chk ((Get-YakuCatSegmentSplitGroupId -Segment $rs[1]) -eq $groupBefore) '後半も同じ組のまま'
    Chk ([int]$rs[0].SplitOrdinal -eq 0 -and [int]$rs[1].SplitOrdinal -eq 1) '並び番号も保たれる'
    $null = Merge-YakuCatSegments -Project $restored -Index 0
    Chk (@($restored.Segments).Count -eq 1 -and [string]@($restored.Segments)[0].Text -ceq $textWhole) '読み直したあとでも結合で元へ戻る'
    Remove-YakuCatProject -Id $savedId

    # ================================================================ (g)
    Write-Host '(g) 画面と口が実物どうしでつながっている' -ForegroundColor Cyan
    $serverPath = Join-Path (Join-Path $root 'src') 'Server.ps1'
    $serverText = [IO.File]::ReadAllText($serverPath, [Text.UTF8Encoding]::new($false))
    $clientText = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www\assets') 'cat.js'), [Text.UTF8Encoding]::new($false))
    $pageText = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'cat.html'), [Text.UTF8Encoding]::new($false))

    # 画面が押したときに呼ぶ名前を cat.js から取り出し、サーバの口と突き合わせる。
    $clientAction = ''
    $clientActionMatch = [regex]::Match($clientText, "hasAttribute\('data-cat-split-at'\)[\s\S]{0,1200}?mutate\('(?<action>[a-z-]+)'")
    if ($clientActionMatch.Success) { $clientAction = [string]$clientActionMatch.Groups['action'].Value }
    Chk (-not [string]::IsNullOrWhiteSpace($clientAction)) ('cat.js の分割ボタンが呼ぶ口の名前を取り出せる: ' + $clientAction)

    # サーバ側の switch 節を構文木で取り出す。取り出せなければ黙って飛ばさず赤にする。
    $serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$null, [ref]$null)
    $routeBody = $null
    foreach ($switchAst in @($serverAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true))) {
        foreach ($clause in $switchAst.Clauses) {
            if ([string]$clause.Item1.Extent.Text -ne ("'" + $clientAction + "'")) { continue }
            $bodyText = [string]$clause.Item2.Extent.Text
            if ($bodyText.Length -gt 2 -and $bodyText[0] -eq '{' -and $bodyText[$bodyText.Length - 1] -eq '}') { $routeBody = $bodyText.Substring(1, $bodyText.Length - 2) }
        }
    }
    Chk ($null -ne $routeBody) ('サーバに ' + $clientAction + ' の口が実在する')
    # revision を進める操作の一覧に入っていないと、同時編集の衝突検知を通らない。
    $revisionActionsMatch = [regex]::Match($serverText, '\$revisionActions\s*=\s*@\((?<body>[^\)]*)\)')
    Chk ($revisionActionsMatch.Success -and $revisionActionsMatch.Groups['body'].Value -match ("'" + $clientAction + "'")) ($clientAction + ' が revision を進める操作として登録されている')

    if ($null -ne $routeBody) {
        # 口の本体をそのまま走らせる。写経しない（Server.ps1 を直すと写しが古くなる）。
        $script:YakuRouteResponseText = ''
        function Send-YakuTextResponse { param($Context,[string]$Text,[string]$ContentType='',[int]$StatusCode=200,[switch]$AllowWasm) $script:YakuRouteResponseText = [string]$Text }
        $rp = New-YakuCatTextProject -Root $root -Text $textWhole -Settings $settings -Direction 'to_en'
        $project = Commit-YakuNewCatProject -Project $rp
        $Context = $null
        $expectedRevision = [int]$project.Revision
        $payload = @{ id = [string]$project.Id; index = '0'; position = [string]$textHead.Length; expected_revision = [string]$project.Revision }
        $routeJson = $null; $routeNote = ''
        try { . ([scriptblock]::Create($routeBody)); $routeJson = $script:YakuRouteResponseText | ConvertFrom-Json }
        catch { $routeNote = ' / ' + [string]$_.Exception.Message }
        Chk ($null -ne $routeJson) ('口が応答を返す' + $routeNote)
        if ($null -ne $routeJson) {
            $routeRows = @($routeJson.segments)
            Chk ($routeRows.Count -eq 2) ('口を通しても2行に割れる（実際 ' + $routeRows.Count + ' 行）')
            Chk ([string]$routeRows[0].source -eq $textHead -and [string]$routeRows[1].source -eq $textTail) '口の応答の原文が指定位置で割れている'
            Chk (-not [bool]$routeRows[0].confirmed -and -not [bool]$routeRows[1].confirmed) '口の応答でも未確認'
            # 画面が読む名前が、応答に実在するか（名前があるかではなく値が合うか）
            Chk ($routeRows[0].PSObject.Properties.Name -contains 'can_split_at') '応答に can_split_at がある'
            $expectSplittable = Test-YakuCatSegmentSplittable -Segment @((Get-YakuCatProject -Id ([string]$project.Id)).Segments)[0]
            Chk ([bool]$routeRows[0].can_split_at -eq [bool]$expectSplittable) 'can_split_at が実装の判定と一致する'
            Chk ([bool]$routeRows[0].can_merge) '割った行は、割った相手と繋げると画面へ出す'
            Chk ([int]$routeRows[0].split_parts -eq 2 -and [int]$routeRows[0].split_part -eq 1) '何分割の何番目かを画面へ出す'
        }
        Remove-YakuCatProject -Id ([string]$project.Id)
    }

    # 画面の作法：Alt+M / Alt+K と同じ並びに Alt+S を置き、キー一覧と実装をそろえる。
    Chk ($clientText -match 'data-cat-split-at') 'cat.js に分割ボタンがある'
    Chk ($clientText -match "event\.key\.toLowerCase\(\) === 's'") 'cat.js が Alt+S を受ける'
    Chk ($clientText -match "\[data-cat-split-at=") 'Alt+S が分割ボタンを押す'
    Chk ($pageText -match '<kbd>Alt</kbd>\+<kbd>S</kbd>') 'キー一覧（cat.html）に Alt+S がある'
    Chk ($pageText -match '<kbd>Alt</kbd>\+<kbd>M</kbd>') 'キー一覧に Alt+M が残っている'
    # キー一覧に載っている Alt のキーが、すべて cat.js で受けられていること。
    $listedAltKeys = @([regex]::Matches($pageText, '<kbd>Alt</kbd>\+<kbd>(?<k>[A-Z])</kbd>') | ForEach-Object { [string]$_.Groups['k'].Value.ToLowerInvariant() } | Select-Object -Unique)
    Chk ($listedAltKeys.Count -ge 3) ('キー一覧に Alt の割り当てが ' + $listedAltKeys.Count + ' 件ある')
    $missingAltKeys = @($listedAltKeys | Where-Object { $clientText -notmatch ("event\.key\.toLowerCase\(\) === '" + $_ + "'") })
    Chk ($missingAltKeys.Count -eq 0) ('キー一覧の Alt キーはすべて cat.js が受ける（受けていない: ' + (@($missingAltKeys) -join ',') + '）')

    # ================================================================ (i)
    # 2026-08-15 の欠陥。原文をトークンの内側で割ると、to_en の書き戻しで
    # 訳文へ空白が1つ混じる。数字は1桁も欠けないので数値QCに掛からない。
    Write-Host '(i) トークンの内側では割らせない・繋ぐときに空白を入れない' -ForegroundColor Cyan

    # --- (i-1) 判定そのもの。境目の両隣の字種だけで決まる。
    # 「原文の境目に空白があったか」で判定してはいけない。日本語の原文には
    # どこにも空白が無いので、それだと節で割った普通の文まで詰まる。
    $tokenText = '型式はAB-1234を採用します。'
    $emoji = [char]::ConvertFromUtf32(0x1F600)
    $latinPair = 'We reviewed our production system. We also reduced procurement costs.'
    $cjkPair = $head + $tail
    $tokenCases = @(
        @{ T=$tokenText; P=6;  E=$true;  M='ハイフンと数字の間（この欠陥の再現位置 AB-|1234）' },
        @{ T=$tokenText; P=4;  E=$true;  M='英字どうしの間（A|B）' },
        @{ T=$tokenText; P=5;  E=$true;  M='英字とハイフンの間（B|-）' },
        @{ T=$tokenText; P=3;  E=$false; M='CJKと英数の境目（は|A）' },
        @{ T=$tokenText; P=10; E=$false; M='英数とCJKの境目（4|を）' },
        @{ T=$tokenText; P=1;  E=$false; M='CJKどうしの間（型|式）' },
        @{ T='ＡＢ－１２３４を採用'; P=2; E=$true;  M='全角英数のハイフン手前（Ｂ|－）' },
        @{ T='ＡＢ－１２３４を採用'; P=3; E=$true;  M='全角英数のハイフン直後（－|１）' },
        @{ T='ＡＢ－１２３４を採用'; P=7; E=$false; M='全角英数とCJKの境目（４|を）' },
        @{ T='https://example.com/spec'; P=12; E=$true; M='URLの語の内側（m|p）' },
        @{ T='https://example.com/spec'; P=16; E=$true; M='URLのドット直後（.|c）' },
        @{ T='https://example.com/spec'; P=19; E=$true; M='URLのスラッシュ手前（m|/）' },
        @{ T='https://example.com/spec'; P=20; E=$true; M='URLのスラッシュ直後（/|s）' },
        @{ T='円周率は3.14です。'; P=5; E=$true;  M='小数点の手前（3|.）' },
        @{ T='円周率は3.14です。'; P=6; E=$true;  M='小数点の直後（.|1）' },
        @{ T='円周率は3.14です。'; P=4; E=$false; M='CJKと数字の境目（は|3）' },
        @{ T='2026-08-15'; P=4; E=$true; M='日付の数字とハイフン（6|-）' },
        @{ T='2026-08-15'; P=5; E=$true; M='日付のハイフンと数字（-|0）' },
        @{ T='2026-08-15'; P=7; E=$true; M='日付の2つ目のハイフン手前（8|-）' },
        @{ T='売上は1,234でした'; P=4; E=$true;  M='桁区切りの手前（1|,）' },
        @{ T='売上は1,234でした'; P=5; E=$true;  M='桁区切りの直後（,|2）' },
        @{ T='距離は100kmです'; P=6; E=$true;  M='数値と単位の境目（0|k）' },
        @{ T='AB--1234'; P=3; E=$false; M='記号どうしの境目は内側と見なさない（-|-。空白1つ側へ倒す）' },
        @{ T=$latinPair; P=($latinPair.IndexOf('. ') + 1); E=$false; M='空白の手前は内側でない（.| ）' },
        @{ T=$latinPair; P=($latinPair.IndexOf('. ') + 2); E=$false; M='空白の直後は内側でない（ |W）' },
        @{ T=$latinPair; P=$latinPair.IndexOf('. '); E=$true; M='語と句点の間は内側（m|.）' },
        @{ T=$cjkPair; P=$head.Length; E=$false; M='日本語の文の切れ目は内側でない（。|調）' },
        @{ T=('AB' + $emoji + 'CD'); P=3; E=$true; M='サロゲートペアの真ん中は必ず内側（絵文字を半分に割らない）' },
        @{ T=''; P=0; E=$false; M='空文字は内側でない' },
        @{ T=''; P=1; E=$false; M='空文字に位置1を聞かれても内側でない' },
        @{ T='A'; P=1; E=$false; M='1文字の原文は内側でない' },
        @{ T='あ'; P=0; E=$false; M='1文字のCJKも内側でない' },
        @{ T=$tokenText; P=0; E=$false; M='位置0は内側でない（別の門が弾く）' },
        @{ T=$tokenText; P=$tokenText.Length; E=$false; M='末尾は内側でない（別の門が弾く）' },
        @{ T=$tokenText; P=9999; E=$false; M='範囲外は内側でない（別の門が弾く）' },
        @{ T=$tokenText; P=-1; E=$false; M='負の位置は内側でない（別の門が弾く）' }
    )
    foreach ($case in $tokenCases) {
        $got = [bool](Test-YakuCatSplitPositionInsideToken -Text ([string]$case.T) -Position ([int]$case.P))
        $want = [bool]$case.E
        Chk ($got -eq $want) ('判定: ' + [string]$case.M + ' → ' + $(if ($want) { '内側' } else { '内側でない' }) + '（実際 ' + $(if ($got) { '内側' } else { '内側でない' }) + '）')
    }
    Chk ([bool](Test-YakuCatSplitPositionInsideToken -Text $null -Position 1) -eq $false) '原文が $null でも落ちずに「内側でない」を返す'

    # 判定は1か所だけが持つ。CatProject 側へ写すと、片方だけ直り忘れる。
    $cellSegmentsSource = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'CellSegments.ps1'), [Text.UTF8Encoding]::new($false))
    $cellAst = [System.Management.Automation.Language.Parser]::ParseInput($cellSegmentsSource, [ref]$null, [ref]$null)
    $predInCell = @($cellAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-YakuCatSplitPositionInsideToken' }, $true))
    $predInCat = @($splitAtAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-YakuCatSplitPositionInsideToken' }, $true))
    Chk ($predInCell.Count -eq 1) '判定は CellSegments.ps1 に1つだけ定義されている'
    Chk ($predInCat.Count -eq 0) 'CatProject.ps1 には写しが無い'
    Chk ($splitAtText -match 'Test-YakuCatSplitPositionInsideToken') 'Split-YakuCatSegmentAt は共有の判定を呼ぶ'
    # 前方呼び出しにしない（後ろのモジュールの関数を呼ぶと CommandNotFoundException が
    # セル単位の catch で警告へ落ちる。2026-08-14 の実績）。
    $moduleOrder = @($script:YakuSrcModuleFiles)
    $idxCell = [array]::IndexOf($moduleOrder, 'CellSegments.ps1')
    $idxCat = [array]::IndexOf($moduleOrder, 'CatProject.ps1')
    Chk ($idxCell -ge 0 -and $idxCat -gt $idxCell) ('CellSegments.ps1 が CatProject.ps1 より先に読まれる（' + $idxCell + ' < ' + $idxCat + '）')

    # --- (i-2) 門。新しい破損はここで止める。
    $pi = New-TestCellProject -Texts @($tokenText)
    $threwToken = $false; $tokenMessage = ''
    try { $null = Split-YakuCatSegmentAt -Project $pi -Index 0 -Position 6 } catch { $threwToken = $true; $tokenMessage = [string]$_.Exception.Message }
    Chk $threwToken 'トークンの内側（AB-|1234）で割ろうとすると止まる'
    Chk (@($pi.Segments).Count -eq 1) '止まったので行は増えない'
    Chk ($tokenMessage -match '単語' -and $tokenMessage -match '数字') '止めた理由が「単語や数字の途中」と書いてある'
    Chk ($tokenMessage -match 'AB-1234') '何がトークンかの例が文面にある'
    Chk ($tokenMessage -match 'もう一度お試しください') '次に何をすればよいかまで書いてある（既存4つと同じ語り口）'
    # 門は「割れるはずの位置」まで塞いでいないこと。ここが空振りだと意味が無い。
    $pi2 = New-TestCellProject -Texts @($tokenText)
    $null = Split-YakuCatSegmentAt -Project $pi2 -Index 0 -Position 3
    Chk (@($pi2.Segments).Count -eq 2) 'CJKと英数の境目（は|AB）では今までどおり割れる'
    Chk ([string]@($pi2.Segments)[0].Text -eq '型式は' -and [string]@($pi2.Segments)[1].Text -eq 'AB-1234を採用します。') '割れた位置は指定どおり'
    $pi3 = New-TestCellProject -Texts @($tokenText)
    $null = Split-YakuCatSegmentAt -Project $pi3 -Index 0 -Position 10
    Chk (@($pi3.Segments).Count -eq 2) '英数とCJKの境目（1234|を）でも今までどおり割れる'
    # 絵文字を半分に割らせない。
    $piE = New-TestCellProject -Texts @('注記' + $emoji + '追記')
    $threwEmoji = $false
    try { $null = Split-YakuCatSegmentAt -Project $piE -Index 0 -Position 3 } catch { $threwEmoji = $true }
    Chk $threwEmoji 'サロゲートペアの真ん中では割れない'
    Chk (@($piE.Segments).Count -eq 1) '絵文字の半分割りでも行は増えない'

    # --- (i-3) 繋ぎ方。既に割ってある資料は、繋ぎ方だけで直す。
    $brokenParts = @('The model is AB-', '1234 will be adopted.')
    $brokenSources = @('型式はAB-', '1234を採用します。')
    Chk ((Join-YakuCatSplitTranslations -Parts $brokenParts) -eq 'The model is AB- 1234 will be adopted.') '原文を渡さない既存の呼び出しは今までどおり（空白が入る）'
    Chk ((Join-YakuCatSplitTranslations -Parts $brokenParts -Sources $brokenSources) -eq 'The model is AB-1234 will be adopted.') '原文を渡すと、トークンの内側には空白を入れない'
    Chk ((Join-YakuCatSplitTranslations -Parts @('We reviewed our production system.', 'We also reduced procurement costs.') -Sources @($head, $tail)) -eq $expectedJoined) '日本語の文の切れ目では、今までどおり空白1つで繋ぐ'
    Chk ((Join-YakuCatSplitTranslations -Parts $brokenParts -Sources @('型式はAB-')) -eq 'The model is AB- 1234 will be adopted.') '原文の本数が合わないときは今までどおり（対応づけを推測しない）'
    # 原文が「多すぎる」側も要る。少なすぎる側だけでは、本数一致ガードを緩めても
    # 出力が1文字も変わらない（位置が範囲外→0になり、述語がどのみち $false を返す）。
    # つまり上の1行だけでは、ガードを外したことを検知できない。多すぎる側は
    # ずれた原文で判定が走るので、緩めた瞬間に詰めて繋いでしまう。
    Chk ((Join-YakuCatSplitTranslations -Parts $brokenParts -Sources @('型式はAB-', '1234', '余分')) -eq 'The model is AB- 1234 will be adopted.') '原文が多すぎるときも今までどおり（本数が一致したときだけ信じる）'
    Chk ((Join-YakuCatSplitTranslations -Parts @('型式はAB-', '1234を採用します。') -Sources @('The model is AB-', '1234 will be adopted.')) -eq '型式はAB-1234を採用します。') 'to_jp は繋ぎ文字がそもそも無いので、どちらでも詰めて繋ぐ'

    # --- (i-4) 既に割ってある資料の書き戻し。門を通さずに割った状態を組み立てる。
    #     利用者の作業を巻き戻さない（既存の分割行は弾かない）ので、ここが本番になる。
    $pl = New-TestCellProject -Texts @($tokenText)
    $legacyTarget = @($pl.Segments)[0]
    $legacyGroup = [guid]::NewGuid().ToString('N')
    $legacyOut = New-Object System.Collections.Generic.List[object]
    foreach ($piece in @($tokenText.Substring(0, 6), $tokenText.Substring(6))) {
        [void]$legacyOut.Add((New-YakuCatSplitPart -Source $legacyTarget -Text $piece -GroupId $legacyGroup -OriginSegmentId ([string]$legacyTarget.SegmentId)))
    }
    $null = Set-YakuCatSegments -Project $pl -Segments @($legacyOut.ToArray())
    $null = Update-YakuCatSplitOrdinals -Project $pl
    Chk (@($pl.Segments).Count -eq 2 -and [string]@($pl.Segments)[0].Text -eq '型式はAB-') '門を通さずに割った資料を用意できた（この検査が空振りでないこと）'
    $null = Set-YakuCatSegmentTranslation -Project $pl -Index 0 -Text 'The model is AB-'
    $null = Set-YakuCatSegmentTranslation -Project $pl -Index 1 -Text '1234 will be adopted.'
    $expectedTight = 'The model is AB-1234 will be adopted.'
    $legacyUnits = @(Group-YakuCatSplitSegments -Segments @($pl.Segments))
    Chk ($legacyUnits.Count -eq 1 -and [bool]$legacyUnits[0].IsSplitGroup) '畳むと1単位になる'
    Chk ([string]$legacyUnits[0].Segment.Translation -eq $expectedTight) ('畳んだ訳文に空白が混じらない: ' + [string]$legacyUnits[0].Segment.Translation)
    Chk ([string]$legacyUnits[0].Segment.Text -eq $tokenText) '原文は連結すると元へ戻る（割り方は可逆）'
    $legacyBySegment = @{0='The model is AB-';1='1234 will be adopted.'}
    $legacyByBlock = Get-YakuCatPlacementTranslationByBlockId -Project $pl -TranslationBySegmentIndex $legacyBySegment
    Chk ([string]$legacyByBlock['b1'] -eq $expectedTight) ('配置計画の経路でも空白が混じらない: ' + [string]$legacyByBlock['b1'])
    $legacyByBlockCell = Get-YakuSegmentTranslationByBlockId -Segments @($pl.Segments) -TranslationBySegmentIndex $legacyBySegment
    Chk ([string]$legacyByBlockCell['b1'] -eq $expectedTight) ('セル層の経路でも空白が混じらない: ' + [string]$legacyByBlockCell['b1'])
    Chk ([string]$legacyByBlock['b1'] -notmatch 'AB- 1234') '欠陥そのもの（AB- 1234）が出ない'
    # 数値QCは、この欠陥を見つけられない。数字は1桁も欠けず、割った後は
    # 片側ずつしか点検が走らないからである。だから止める側ではなく繋ぎ方で直した。
    $pq = New-TestCellProject -Texts @('1234を採用します。')
    $null = Set-YakuCatSegmentTranslation -Project $pq -Index 0 -Text '1234 will be adopted.'
    $qcBroken = Invoke-YakuCatSegmentValidation -Project $pq -Segment @($pq.Segments)[0]
    Chk ([bool]$qcBroken.Passed) '割った片側だけでは点検が何も言わない（この欠陥が見えない理由）'

    # ================================================================ (b) 実Excel
    if (Test-YakuExcelAvailable) {
        Write-Host '(b2) 実Excelでの往復' -ForegroundColor Cyan
        $srcPath = Join-Path $tmp 'in.xlsx'
        $outPath = Join-Path $tmp 'out.xlsx'
        $xl = New-Object -ComObject Excel.Application
        $xl.Visible = $false; $xl.DisplayAlerts = $false
        try {
            $wb = $xl.Workbooks.Add()
            $ws = $wb.Worksheets.Item(1); $ws.Name = '説明'
            $ws.Cells.Item(1,1).Value2 = $whole
            $ws.Cells.Item(3,1).Value2 = '営業利益'
            $ws.Cells.Item(3,2).Value2 = 1234
            $wb.SaveAs($srcPath, 51); $wb.Close($false)
        } finally {
            try { $xl.Quit() } catch {}
            Release-YakuComObject $xl
            try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
        }
        $xp = New-YakuCatProject -Root $root -Path $srcPath -Settings $settings -Direction 'to_en'
        $xsegs = @($xp.Segments)
        $xIndex = -1
        for ($i = 0; $i -lt $xsegs.Count; $i++) { if ([string]$xsegs[$i].Text -eq $whole) { $xIndex = $i } }
        Chk ($xIndex -ge 0) '取り込んだ Excel から、割る対象のセルが取れる'
        if ($xIndex -ge 0) {
            $null = Split-YakuCatSegmentAt -Project $xp -Index $xIndex -Position ($head.Length)
            Chk (@($xp.Segments).Count -eq ($xsegs.Count + 1)) '割ると行が1つ増える'
            $null = Set-YakuCatSegmentTranslation -Project $xp -Index $xIndex -Text 'We reviewed our production system.'
            $null = Set-YakuCatSegmentTranslation -Project $xp -Index ($xIndex + 1) -Text 'We also reduced procurement costs.'
            for ($i = 0; $i -lt @($xp.Segments).Count; $i++) {
                if ([string]::IsNullOrWhiteSpace([string]@($xp.Segments)[$i].Translation)) { $null = Set-YakuCatSegmentTranslation -Project $xp -Index $i -Text 'Operating profit' }
            }
            for ($i = 0; $i -lt @($xp.Segments).Count; $i++) { $null = Set-YakuCatSegmentConfirmed -Project $xp -Index $i }
            $null = Save-YakuCatProject -Project $xp
            $exportNote = ''
            $exported = $null
            try { $exported = Export-YakuCatProject -Project $xp -OutputPath $outPath -Settings $settings } catch { $exportNote = [string]$_.Exception.Message }
            Chk ($null -ne $exported) ('割った行があっても DRAFT を書き出せる' + $(if ($exportNote) { ' / ' + $exportNote } else { '' }))
            if ($null -ne $exported) {
                $xl2 = New-Object -ComObject Excel.Application
                $xl2.Visible = $false; $xl2.DisplayAlerts = $false
                $read = @{}
                try {
                    $wb2 = $xl2.Workbooks.Open([string]$exported.OutputPath, 0, $true)
                    $ws2 = $wb2.Worksheets.Item(1)
                    $read['A1'] = [string]$ws2.Cells.Item(1,1).Value2
                    $read['A2'] = [string]$ws2.Cells.Item(2,1).Value2
                    $read['A3'] = [string]$ws2.Cells.Item(3,1).Value2
                    $read['B3'] = [string]$ws2.Cells.Item(3,2).Value2
                    $wb2.Close($false)
                } finally {
                    try { $xl2.Quit() } catch {}
                    Release-YakuComObject $xl2
                    try { [GC]::Collect(); [GC]::WaitForPendingFinalizers() } catch {}
                }
                Chk ([string]$read['A1'] -eq $expectedJoined) ('割った2行が元の1セルへ結合されて入る: ' + [string]$read['A1'])
                Chk ([string]::IsNullOrWhiteSpace([string]$read['A2'])) '割ったからといって下のセルへこぼさない'
                Chk ([string]$read['A3'] -eq 'Operating profit') '割っていないセルはそのまま訳される'
                Chk ([string]$read['B3'] -eq '1234') '数値セルは触らない'
            }
        }
        Remove-YakuCatProject -Id ([string]$xp.Id)
    } else {
        Write-Host '(b2) Excel が無いため実ファイルの往復は飛ばす' -ForegroundColor Yellow
    }

    if ($script:fail -eq 0) { Write-Host ('V91.73 任意位置での分割の回帰テストに合格しました。検査 ' + $script:checks + ' 件。') -ForegroundColor Green }
    else { Write-Host ('FAILED: ' + $script:fail + ' / ' + $script:checks) -ForegroundColor Red }
} finally {
    if ([string]::IsNullOrEmpty($previousDataDir)) { Remove-Item Env:\YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
exit ([int]($script:fail -gt 0))
