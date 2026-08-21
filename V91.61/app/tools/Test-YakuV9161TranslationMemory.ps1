<#
.SYNOPSIS
  V91.61: 翻訳メモリの回帰テスト。

.DESCRIPTION
  候補ペインの3本柱の最後の1本。利用者が確定した訳を貯め、次に同じ文が
  来たら差し込めるようにする。市販ツールの Ctrl+Enter と同じ作法で、
  確定＝記憶にする。

  一番効くのはこれである。公表訳から取った対訳は「読ませる訳」で意訳が
  多く、そのままは使いにくい。翻訳メモリは自分の文体で、自分が正しいと
  判断したものだけが入る。

  ここで見るのは4つ。
   - 確定したものが貯まること
   - 同じ原文を訳し直したら、あとの訳が優先されること
   - 完全一致が最優先で出ること
   - 壊れた行があっても残りが読めること

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\Test-YakuV9161TranslationMemory.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:fail = 0

. (Join-Path (Join-Path $root 'src') 'TranslationMemory.ps1')
function Chk { param([bool]$c, [string]$m) if ($c) { Write-Host ('  ok   ' + $m) -ForegroundColor Green } else { Write-Host ('  FAIL ' + $m) -ForegroundColor Red; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('yaku-tm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
$tm = Join-Path $tmp 'tm-to_en.jsonl'
$oldDataDir = $env:YAKULINGO_DATA_DIR
$env:YAKULINGO_DATA_DIR = Join-Path $tmp 'data'
function Add-TestTranslationMemoryEntry {
    param(
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Target,
        [string]$Path,
        [int]$ReviewRevision = 7,
        [string]$Location = 'Sheet1, A1',
        [int]$Page = 3,
        [string]$ProjectId = '11111111111111111111111111111111',
        [string]$SegmentId = '',
        [string]$FileName = 'FY2025-results.xlsx'
    )
    if ([string]::IsNullOrWhiteSpace($SegmentId)) { $SegmentId = (Get-YakuTranslationMemoryHash -Text ([string]$Source)).Substring(0, 32) }
    return (Add-YakuTranslationMemoryEntry -Source $Source -Target $Target -Path $Path `
        -OriginProjectId $ProjectId -OriginFileName $FileName -OriginSegmentId $SegmentId `
        -OriginLocation $Location -OriginPage $Page -ReviewRevision $ReviewRevision)
}
try {
    Write-Host '貯める' -ForegroundColor Cyan
    $r = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm
    Chk ([bool]$r.Added -and $r.Reason -eq 'new') '確定した訳を貯める'
    $r = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'same') '同じ内容は二度貯めない'
    $r = Add-TestTranslationMemoryEntry -Source '' -Target 'x' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'empty') '原文が空なら貯めない'
    $r = Add-TestTranslationMemoryEntry -Source 'x' -Target '  ' -Path $tm
    Chk (-not [bool]$r.Added) '訳文が空白だけなら貯めない'
    $r = Add-YakuTranslationMemoryEntry -Source '出典の無い文です。' -Target 'No provenance.' -Path $tm
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'provenance-required') '出典の無い新規TM行を作らない'

    $stored = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -Last 1) | ConvertFrom-Json
    Chk ([int]$stored.schema_version -eq 3 -and [string]$stored.event_type -eq 'upsert' -and [string]$stored.origin_project_id -eq '11111111111111111111111111111111') 'schema v3 upsertとorigin project idを永続化する'
    Chk ([string]$stored.unit_id -match '^[a-f0-9]{64}$' -and [string]$stored.event_id -match '^[a-f0-9]{64}$') '翻訳単位と追記eventを安定IDへ束縛する'
    Chk ([string]$stored.origin_file_name -eq 'FY2025-results.xlsx' -and [string]$stored.origin_location -eq 'Sheet1, A1' -and [int]$stored.origin_page -eq 3) '資料名・箇所・ページを永続化する'
    Chk ([string]$stored.origin_segment_id -match '^[a-f0-9]{32}$' -and [int]$stored.review_revision -eq 7) 'stable segment id・確認revisionを永続化する'
    Chk ([string]$stored.source_hash -eq (Get-YakuTranslationMemoryHash -Text ([string]$stored.source)) -and [string]$stored.target_hash -eq (Get-YakuTranslationMemoryHash -Text ([string]$stored.target))) '原文・訳文ハッシュを永続化する'

    Write-Host '訳し直し' -ForegroundColor Cyan
    $r = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will promote electrification.' -Path $tm -ReviewRevision 8
    Chk ([bool]$r.Added -and $r.Reason -eq 'updated') '訳し直しは上書きとして貯まる'
    $h = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk ($h.Count -eq 1) '同じ原文の候補は1件にまとまる'
    Chk ($h[0].Target -eq 'We will promote electrification.') 'あとから確定した訳が出る'
    Chk ($h[0].SourceName -eq 'FY2025-results.xlsx' -and $h[0].Location -eq 'Sheet1, A1' -and [int]$h[0].Page -eq 3) '候補へ資料名・箇所・ページを返す'
    Chk ([int]$h[0].ReviewRevision -eq 8 -and [string]$h[0].ReferenceId -match '^[a-f0-9]{64}$') '候補を確認revisionと安定reference idへ束縛する'
    $beforeReplay = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    $replayed = Add-TestTranslationMemoryEntry -Source '当社は電動化を進めます。' -Target 'We will advance electrification.' -Path $tm -ReviewRevision 7
    $afterReplay = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    $afterReplayHit = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk (-not [bool]$replayed.Added -and $replayed.Reason -eq 'same' -and $afterReplay -eq $beforeReplay -and $afterReplayHit[0].Target -eq 'We will promote electrification.') '古いoutbox eventの再送は最新訳を巻き戻さない'

    Write-Host '同じ原文の複数確認訳' -ForegroundColor Cyan
    $variantProject = '22222222222222222222222222222222'
    $variantSegment = '33333333333333333333333333333333'
    $r = Add-TestTranslationMemoryEntry -Source '当社は 電動化を進めます 。' -Target 'We will pursue electrification.' `
        -Path $tm -ProjectId $variantProject -SegmentId $variantSegment -FileName 'FY2026-plan.docx' `
        -Location '本文 段落 4' -Page 2 -ReviewRevision 3
    Chk ([bool]$r.Added -and $r.Reason -eq 'new') '別project・segmentの確認訳を別unitとして貯める'
    $variants = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk ($variants.Count -eq 2) '同じ正規化原文の複数候補を失わない'
    Chk (@($variants.Target) -contains 'We will promote electrification.' -and @($variants.Target) -contains 'We will pursue electrification.') '異なる確認訳を双方表示する'
    Chk (@($variants | Where-Object { $_.SourceName -eq 'FY2026-plan.docx' -and $_.Location -eq '本文 段落 4' }).Count -eq 1) '複数候補ごとに出典を維持する'

    Write-Host '引く' -ForegroundColor Cyan
    Chk ([bool]$h[0].Exact -and [Math]::Abs([double]$h[0].Ratio - 1.0) -lt 0.001) '完全一致は一致率1.0'
    $h = @(Find-YakuTranslationMemory -Text '当社は 電動化を進めます 。' -Path $tm)
    Chk (@($h | Where-Object { [bool]$_.Exact }).Count -eq 2) '空白の違いは同じ文とみなす'
    $fuzzySource = '当社は中期経営計画に基づき電動化への投資を着実に進めています。'
    $fuzzyQuery = '当社は中期経営計画に基づき電動化への投資を着実に推進しています。'
    $null = Add-TestTranslationMemoryEntry -Source $fuzzySource -Target 'We are steadily investing in electrification under our mid-term plan.' `
        -Path $tm -ProjectId '44444444444444444444444444444444' -SegmentId '55555555555555555555555555555555' `
        -FileName 'mid-term-plan.docx' -Location '本文 段落 9' -Page 5
    $h = @(Find-YakuTranslationMemory -Text $fuzzyQuery -Path $tm)
    Chk ($h.Count -ge 1 -and -not [bool]$h[0].Exact -and $h[0].MatchType -eq 'fuzzy') '包含関係にない類似文をfuzzy候補に出す'
    Chk ([double]$h[0].Score -ge 0.70 -and [Math]::Abs([double]$h[0].Score - [double]$h[0].Ratio) -lt 0.0001) 'fuzzy候補へ70%以上のscoreを返す'
    Chk (@(Find-YakuTranslationMemory -Text '短い' -Path $tm).Count -eq 0) '短すぎる原文では引かない'
    Chk (@(Find-YakuTranslationMemory -Text 'まったく関係のない文章です。' -Path $tm).Count -eq 0) '当たらなければ空'
    Chk (@(Find-YakuTranslationMemory -Text 'x' -Path (Join-Path $tmp 'no-such.jsonl')).Count -eq 0) 'メモリが無くても落ちない'

    Write-Host '完全一致を先に出す' -ForegroundColor Cyan
    # 3文字以下は最小長に届かず引かない（語は用語集の役目）。
    # ここは文として成り立つ長さで試す。
    $null = Add-TestTranslationMemoryEntry -Source '電動化を進めます。' -Target 'We advance electrification.' -Path $tm -Location 'Sheet1, A2'
    $h = @(Find-YakuTranslationMemory -Text '電動化を進めます。' -Path $tm)
    Chk ($h.Count -ge 1 -and [bool]$h[0].Exact -and $h[0].Target -eq 'We advance electrification.') '完全一致が先頭に来る'
    Chk (@(Find-YakuTranslationMemory -Text '電動化' -Path $tm).Count -eq 0) '語は翻訳メモリでは引かない（用語集の役目）'

    Write-Host '追記型tombstone' -ForegroundColor Cyan
    $beforeTombstone = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    $r = Add-YakuTranslationMemoryTombstone -Path $tm -OriginProjectId $variantProject `
        -OriginSegmentId $variantSegment -ReviewRevision 4 -Reason 'translation-corrected'
    Chk ([bool]$r.Added -and $r.Reason -eq 'tombstoned') '確認訳を物理削除せずtombstoneで撤回する'
    $afterTombstone = @(Get-Content -LiteralPath $tm -Encoding UTF8).Count
    Chk ($afterTombstone -eq ($beforeTombstone + 1)) 'tombstoneをJSONL末尾へ1行追記する'
    $variants = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    $exactVariants = @($variants | Where-Object { [bool]$_.Exact })
    Chk ($exactVariants.Count -eq 1 -and $exactVariants[0].Target -eq 'We will promote electrification.') 'tombstone対象だけを候補から隠す'
    $r = Add-YakuTranslationMemoryTombstone -Path $tm -OriginProjectId $variantProject `
        -OriginSegmentId $variantSegment -ReviewRevision 4 -Reason 'translation-corrected'
    Chk (-not [bool]$r.Added -and $r.Reason -eq 'same' -and @(Get-Content -LiteralPath $tm -Encoding UTF8).Count -eq $afterTombstone) '同じtombstone要求は冪等にする'

    Write-Host '壊れた行' -ForegroundColor Cyan
    [IO.File]::AppendAllLines($tm, [string[]]@('{壊れた行', ''), [Text.UTF8Encoding]::new($false))
    Chk ((Read-YakuTranslationMemory -Path $tm).Count -eq 4) '壊れた行を捨ててactive eventをunitごとに読む'

    Write-Host '出典不明を閉じる' -ForegroundColor Cyan
    $legacy = Join-Path $tmp 'legacy.jsonl'
    [IO.File]::WriteAllLines($legacy, [string[]]@('{"key":"旧形式の文です。","source":"旧形式の文です。","target":"Legacy entry","direction":"to_en"}'), [Text.UTF8Encoding]::new($false))
    Chk ((Read-YakuTranslationMemory -Path $legacy).Count -eq 1) '旧形式は移行調査のため読み取れる'
    Chk (@(Find-YakuTranslationMemory -Text '旧形式の文です。' -Path $legacy).Count -eq 0) '出典不明の旧形式は候補に表示しない'
    $v2 = Join-Path $tmp 'schema-v2.jsonl'
    $v2Record = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $v2Record.schema_version = 2
    foreach ($field in @('event_type','event_id','unit_id')) { $v2Record.PSObject.Properties.Remove($field) }
    [IO.File]::WriteAllLines($v2, [string[]]@(($v2Record | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$v2Record.source) -Path $v2).Count -eq 1) '出典検証できるschema v2は読み取り互換を保つ'
    $tampered = Join-Path $tmp 'tampered.jsonl'
    $tamperedRecord = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $tamperedRecord.target = 'Tampered target'
    [IO.File]::WriteAllLines($tampered, [string[]]@(($tamperedRecord | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$tamperedRecord.source) -Path $tampered).Count -eq 0) '内容とハッシュが違うTM行は候補に表示しない'
    $tamperedOrigin = Join-Path $tmp 'tampered-origin.jsonl'
    $tamperedOriginRecord = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $tamperedOriginRecord.origin_location = '偽の出典箇所'
    [IO.File]::WriteAllLines($tamperedOrigin, [string[]]@(($tamperedOriginRecord | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$tamperedOriginRecord.source) -Path $tamperedOrigin).Count -eq 0) '出典表示だけを書き換えたTM行も候補に表示しない'

    Write-Host '記憶化は足しであって前提ではない' -ForegroundColor Cyan
    # 行を移るたびに同じJSONLを読み直さないよう、検証済みの姿をプロセス内に
    # 憶えている。憶えたものを捨てても答えが変わらないことを固定する。
    function Get-TranslationMemoryShape { param($Hits)
        return ((@($Hits) | ForEach-Object { [string]$_.UnitId + '|' + [string]$_.MatchType + '|' + ('{0:F9}' -f [double]$_.Score) + '|' + [string]$_.Target }) -join "`n")
    }
    $warmHits = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Clear-YakuTranslationMemoryCache
    $coldHits = @(Find-YakuTranslationMemory -Text '当社は電動化を進めます。' -Path $tm)
    Chk ($warmHits.Count -eq $coldHits.Count -and (Get-TranslationMemoryShape -Hits $warmHits) -eq (Get-TranslationMemoryShape -Hits $coldHits)) '記憶化を捨てても同じ候補が同じ順で出る'
    Clear-YakuTranslationMemoryCache
    Chk (@(Find-YakuTranslationMemory -Text 'x' -Path (Join-Path $tmp 'no-such.jsonl')).Count -eq 0) '記憶化を捨てた直後にメモリが無くても落ちない'
    Clear-YakuTranslationMemoryCache
    $coldConcordance = @(Search-YakuTranslationMemoryConcordance -Query '固定費' -Direction 'to_en' -Path $tm)
    $warmConcordance = @(Search-YakuTranslationMemoryConcordance -Query '固定費' -Direction 'to_en' -Path $tm)
    Chk ($coldConcordance.Count -eq $warmConcordance.Count) 'コンコーダンスも記憶化の有無で変わらない'

    Write-Host '改ざんは記憶化を素通りしない' -ForegroundColor Cyan
    # 長さもmtimeも同じまま中身だけ差し替える。Windowsのファイル時刻は約15.6ms
    # ごとにしか進まないので、長さとmtimeだけを鍵にすると古い姿を返してしまう。
    # ここを外して速くするのは改善ではない。
    $sneak = Join-Path $tmp 'sneak.jsonl'
    $sneakRecord = (Get-Content -LiteralPath $tm -Encoding UTF8 | Select-Object -First 1) | ConvertFrom-Json
    $sneakGood = ($sneakRecord | ConvertTo-Json -Compress -Depth 4)
    [IO.File]::WriteAllLines($sneak, [string[]]@($sneakGood), [Text.UTF8Encoding]::new($false))
    $sneakStamp = [IO.File]::GetLastWriteTimeUtc($sneak)
    Chk (@(Find-YakuTranslationMemory -Text ([string]$sneakRecord.source) -Path $sneak).Count -eq 1) '差し替える前は候補に出る（記憶化に載せる）'
    $sneakRecord.target = ([string]$sneakRecord.target).ToUpperInvariant()
    $sneakBad = ($sneakRecord | ConvertTo-Json -Compress -Depth 4)
    [IO.File]::WriteAllLines($sneak, [string[]]@($sneakBad), [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($sneak, $sneakStamp)
    # -ne は既定で大小を畳む。大文字化しただけの差し替えを「同じ」と見て、
    # この確認そのものが空振りする。中身の比較は -cne で行う。
    Chk ($sneakGood.Length -eq $sneakBad.Length -and $sneakGood -cne $sneakBad) '長さの変わらない差し替えで試している'
    Chk ([IO.File]::GetLastWriteTimeUtc($sneak) -eq $sneakStamp) 'mtimeも同じに戻してある'
    Chk (@(Find-YakuTranslationMemory -Text ([string]$sneakRecord.source) -Path $sneak).Count -eq 0) '長さもmtimeも同じ改ざんを記憶化が素通りさせない'

    Write-Host '追記のたびに全件を読み直さない' -ForegroundColor Cyan
    # 「確認済みにする」はCAT作業でいちばん回数の多い操作で、そのたびにTMへ
    # 1行追記する。追記で記憶化を捨てて作り直す作りにすると、読みで得た分を
    # 書きで失い、さらに追記直後の照合が毎回coldになる。
    # 実測（実データ123件、追記5回の中央値）:
    #   HEAD          追記 33.2ms / 追記直後の照合 105.7ms
    #   捨てて作り直す 追記  4.3ms / 追記直後の照合  88.8ms
    #   前へ進める     追記  3.4ms / 追記直後の照合   5.1ms
    # 合成5,000件の追記では 1,261.5ms → 11.0ms。
    #
    # 門は時計ではなく「やった仕事の量」で置く。CPUの混み具合で揺れないためで、
    # 遅くなった原因そのもの（全行のJSON解析と全件の出典検証）を数える。
    function New-TestTranslationMemorySeedFile {
        param([string]$Path, [int]$Count, [string]$Prefix = 'seed')
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $sources = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0; $i -lt $Count; $i++) {
            # 原文どうしを似せない。似ているとfuzzyで全部当たり、門が測りたい
            # ものではなく並べ替えの費用を測ってしまう。
            $token = (Get-YakuTranslationMemoryHash -Text ($Prefix + '-' + $i)).Substring(0, 24)
            $src = ('第' + $i + '節。' + $token + 'の件について当社は説明します。')
            $tgt = ('Section ' + $i + '. We explain ' + $token + ' in this material.')
            $projectId = (Get-YakuTranslationMemoryHash -Text ($Prefix + '-project-' + $i)).Substring(0, 32)
            $segmentId = (Get-YakuTranslationMemoryHash -Text ($Prefix + '-segment-' + $i)).Substring(0, 32)
            $sourceHash = Get-YakuTranslationMemoryHash -Text $src
            $targetHash = Get-YakuTranslationMemoryHash -Text $tgt
            $unitId = Get-YakuTranslationMemoryUnitId -OriginProjectId $projectId -OriginSegmentId $segmentId -Direction 'to_en'
            $referenceId = Get-YakuTranslationMemoryReferenceId -OriginProjectId $projectId -OriginFileName 'seed.xlsx' `
                -OriginSegmentId $segmentId -OriginLocation ('Sheet1, A' + ($i + 1)) -OriginPage 1 -ReviewRevision 1 `
                -Direction 'to_en' -SourceHash $sourceHash -TargetHash $targetHash
            $eventId = Get-YakuTranslationMemoryEventId -EventType 'upsert' -UnitId $unitId -Direction 'to_en' `
                -ReviewRevision 1 -ReferenceId $referenceId
            $record = [ordered]@{
                schema_version    = 3
                event_type        = 'upsert'
                event_id          = $eventId
                unit_id           = $unitId
                key               = (ConvertTo-YakuTranslationMemoryKey -Text $src)
                source            = $src
                target            = $tgt
                direction         = 'to_en'
                origin            = 'seed'
                reference_id      = $referenceId
                origin_project_id = $projectId
                origin_file_name  = 'seed.xlsx'
                origin_segment_id = $segmentId
                origin_location   = ('Sheet1, A' + ($i + 1))
                origin_page       = 1
                source_hash       = $sourceHash
                target_hash       = $targetHash
                review_revision   = 1
                saved             = (Get-Date).ToString('s')
            }
            $null = $lines.Add(($record | ConvertTo-Json -Compress -Depth 4))
            $null = $sources.Add($src)
        }
        [IO.File]::WriteAllLines($Path, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
        # `return ,$array` にしてはならない。呼び出し側が @() で包むので入れ子になり、
        # 要素1個の配列（中身は配列全体）になる。実際これで3本を赤にした。
        return $sources.ToArray()
    }
    function Add-TestGateEntry {
        param([string]$Path, [int]$Index)
        return (Add-YakuTranslationMemoryEntry -Path $Path `
            -Source ('追記' + $Index + '件目。' + (Get-YakuTranslationMemoryHash -Text ('gate-add-' + $Index)).Substring(0, 24) + 'について述べます。') `
            -Target ('Appended ' + $Index + '. We describe it here.') `
            -OriginProjectId (Get-YakuTranslationMemoryHash -Text ('gate-add-project-' + $Index)).Substring(0, 32) `
            -OriginFileName 'gate.xlsx' `
            -OriginSegmentId (Get-YakuTranslationMemoryHash -Text ('gate-add-segment-' + $Index)).Substring(0, 32) `
            -OriginLocation ('Sheet9, A' + ($Index + 1)) -OriginPage 1 -ReviewRevision 1)
    }
    function Get-TestMedian { param([double[]]$Values)
        $s = @($Values | Sort-Object)
        return [double]$s[[Math]::Floor($s.Count / 2)]
    }

    $gate = Join-Path $tmp 'writepath.jsonl'
    $gateSeed = 400
    $gateSources = @(New-TestTranslationMemorySeedFile -Path $gate -Count $gateSeed -Prefix 'gate')
    $gateQuery = [string]$gateSources[0]
    Clear-YakuTranslationMemoryCache

    # 出典検証の回数を数える。速さのためにここを飛ばす実装は、この数が減る
    # のではなく、追記のたびに全件へ走ることで増える。
    $script:tmProvenanceCalls = 0
    $script:tmProvenanceInner = ${function:Test-YakuTranslationMemoryProvenance}
    function Test-YakuTranslationMemoryProvenance {
        param([AllowNull()]$Entry)
        $script:tmProvenanceCalls = [int]$script:tmProvenanceCalls + 1
        return (& $script:tmProvenanceInner -Entry $Entry)
    }
    try {
        # 対照。冷えた状態では全行を解き、全件の出典検証を通す。
        $script:tmProvenanceCalls = 0
        $coldLinesBefore = Get-YakuTranslationMemoryDecodedLineCount
        $coldFindSw = [Diagnostics.Stopwatch]::StartNew()
        $gateCold = @(Find-YakuTranslationMemory -Text $gateQuery -Path $gate)
        $coldFindSw.Stop()
        $coldProvenance = [int]$script:tmProvenanceCalls
        $coldLines = [long](Get-YakuTranslationMemoryDecodedLineCount) - $coldLinesBefore
        Chk ($gateCold.Count -eq 1 -and [bool]$gateCold[0].Exact) '種を積んだ翻訳メモリから完全一致を引ける'
        Chk ($coldProvenance -ge $gateSeed) ('冷えた照合では全件の出典検証が走る（' + $coldProvenance + '件 / 種' + $gateSeed + '件）')
        Chk ($coldLines -ge $gateSeed) ('冷えた照合では全行を解く（' + $coldLines + '行）')

        # 本番その1。確認済みを続けて2件。1件目でファイルが変わるので、2件目が
        # 「前の追記で失効した記憶化を、追記のたびに作り直していないか」を見る。
        # 退行はここに出ていた（合成5,000件で 1,261.5ms → 3,374.1ms）。
        $gateAdded = Add-TestGateEntry -Path $gate -Index 0
        $script:tmProvenanceCalls = 0
        $addLinesBefore = Get-YakuTranslationMemoryDecodedLineCount
        $gateAdded2 = Add-TestGateEntry -Path $gate -Index 1
        $addProvenance = [int]$script:tmProvenanceCalls
        $addLines = [long](Get-YakuTranslationMemoryDecodedLineCount) - $addLinesBefore
        Chk ([bool]$gateAdded.Added -and [bool]$gateAdded2.Added) '種を積んだ翻訳メモリへ続けて追記できる'
        Chk ($addProvenance -le 2) ('追記の次の追記で出典検証が全件へ走らない（' + $addProvenance + '件）')
        Chk ($addLines -le 2) ('追記の次の追記で解き直すのは増えた行だけ（' + $addLines + '行）')

        # 本番その2。追記して、そのまま次の行を引く。CATで確認済みにした直後の動き。
        $script:tmProvenanceCalls = 0
        $findLinesBefore = Get-YakuTranslationMemoryDecodedLineCount
        $null = Add-TestGateEntry -Path $gate -Index 2
        $addOnlyProvenance = [int]$script:tmProvenanceCalls
        $findSw = [Diagnostics.Stopwatch]::StartNew()
        $gateWarm = @(Find-YakuTranslationMemory -Text $gateQuery -Path $gate)
        $findSw.Stop()
        $findProvenance = [int]$script:tmProvenanceCalls - $addOnlyProvenance
        $findLines = [long](Get-YakuTranslationMemoryDecodedLineCount) - $findLinesBefore
        Chk ($findProvenance -le 2) ('追記の直後の照合で全件の出典検証をやり直さない（' + $findProvenance + '件）')
        Chk ($findLines -le 3) ('追記の直後に解き直すのは追記した行だけ（' + $findLines + '行）')
        Chk ($gateWarm.Count -eq 1 -and [bool]$gateWarm[0].Exact -and
             [string]$gateWarm[0].Target -eq [string]$gateCold[0].Target) '追記しても既存の候補は同じものが出る'

        # 時計でも見ておく。1件目は作り直しになるので、2件目以降と比べる。
        Clear-YakuTranslationMemoryCache
        $coldAddSw = [Diagnostics.Stopwatch]::StartNew()
        $null = Add-TestGateEntry -Path $gate -Index 10
        $coldAddSw.Stop()
        $coldAddMs = [double]$coldAddSw.Elapsed.TotalMilliseconds
        $warmAdds = New-Object 'System.Collections.Generic.List[double]'
        foreach ($n in 11..15) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $null = Add-TestGateEntry -Path $gate -Index $n
            $sw.Stop()
            $null = $warmAdds.Add([double]$sw.Elapsed.TotalMilliseconds)
        }
        $warmAddMs = Get-TestMedian -Values $warmAdds.ToArray()
        Write-Host ('       種' + $gateSeed + '件: 冷えた照合 ' + ('{0:N1}' -f $coldFindSw.Elapsed.TotalMilliseconds) +
            'ms / 冷えた追記 ' + ('{0:N1}' -f $coldAddMs) + 'ms / 温まった追記 ' + ('{0:N1}' -f $warmAddMs) +
            'ms / 追記直後の照合 ' + ('{0:N1}' -f $findSw.Elapsed.TotalMilliseconds) + 'ms') -ForegroundColor DarkGray
        Chk (($warmAddMs * 3) -lt $coldAddMs) ('2件目以降の追記が作り直しより速い（' +
            ('{0:N1}' -f $warmAddMs) + 'ms 対 ' + ('{0:N1}' -f $coldAddMs) + 'ms）')
    }
    finally { ${function:Test-YakuTranslationMemoryProvenance} = $script:tmProvenanceInner }

    Write-Host '追記に見せかけた差し替えを前へ進めない' -ForegroundColor Cyan
    # 記憶化を前へ進めてよいのは、いま読んだbyte列の前半が、前に憶えたときの
    # byte列とSHA-256で一致したときだけである。「伸びた」ことは根拠にしない。
    $grow = Join-Path $tmp 'grow.jsonl'
    $growSources = @(New-TestTranslationMemorySeedFile -Path $grow -Count 3 -Prefix 'grow')
    Clear-YakuTranslationMemoryCache
    $growQuery = [string]$growSources[0]
    Chk (@(Find-YakuTranslationMemory -Text $growQuery -Path $grow | Where-Object { [bool]$_.Exact }).Count -eq 1) '差し替える前は候補に出る（記憶化に載せる）'
    $growLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in [IO.File]::ReadAllLines($grow)) { if (-not [string]::IsNullOrWhiteSpace($l)) { $null = $growLines.Add($l) } }
    $growFirst = $growLines[0] | ConvertFrom-Json
    $growFirst.target = 'Tampered after caching'
    $growLines[0] = ($growFirst | ConvertTo-Json -Compress -Depth 4)
    $null = $growLines.Add('{"schema_version":3,"event_type":"upsert","event_id":"' + ('9' * 64) + '"}')
    [IO.File]::WriteAllLines($grow, $growLines.ToArray(), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text $growQuery -Path $grow | Where-Object { [bool]$_.Exact }).Count -eq 0) '長くなっても前半が違えば作り直して改ざんを弾く'

    # 追記そのものは正しく前へ進むこと。上と対にしておかないと、何も進めない
    # 実装でも上の1本は通ってしまう。
    $growSources2 = @(New-TestTranslationMemorySeedFile -Path $grow -Count 3 -Prefix 'grow2')
    Clear-YakuTranslationMemoryCache
    $null = @(Find-YakuTranslationMemory -Text ([string]$growSources2[0]) -Path $grow)
    $appendSources = @(New-TestTranslationMemorySeedFile -Path (Join-Path $tmp 'append-src.jsonl') -Count 1 -Prefix 'grow3')
    $appendLine = @([IO.File]::ReadAllLines((Join-Path $tmp 'append-src.jsonl')))[0]
    [IO.File]::AppendAllLines($grow, [string[]]@($appendLine), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$appendSources[0]) -Path $grow | Where-Object { [bool]$_.Exact }).Count -eq 1) '正しく追記された行は候補に加わる'

    # 差分で取り込む行にも出典検証を通す。ここを飛ばすと、正しい前半のうしろへ
    # 1行足すだけで何でも候補に出せてしまう。
    $tamperSources = @(New-TestTranslationMemorySeedFile -Path (Join-Path $tmp 'tamper-src.jsonl') -Count 1 -Prefix 'grow4')
    $tamperRecord = @([IO.File]::ReadAllLines((Join-Path $tmp 'tamper-src.jsonl')))[0] | ConvertFrom-Json
    $tamperRecord.target = 'Tampered on append'
    [IO.File]::AppendAllLines($grow, [string[]]@(($tamperRecord | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text ([string]$tamperSources[0]) -Path $grow | Where-Object { [bool]$_.Exact }).Count -eq 0) '追記された改ざん行は差分で取り込んでも候補に出ない'

    # すでに候補に出ているunitへ改ざんしたupsertを追記する。差分で進めるときに
    # 前の候補を残したままにすると、撤回できない偽の候補ができる。
    $shadowSource = [string]$growSources2[0]
    Chk (@(Find-YakuTranslationMemory -Text $shadowSource -Path $grow | Where-Object { [bool]$_.Exact }).Count -eq 1) '上書きする前の行は候補に出ている'
    $shadowRecord = @([IO.File]::ReadAllLines($grow))[0] | ConvertFrom-Json
    $shadowRecord.review_revision = 2
    $shadowRecord.target = 'Shadowed by a forged upsert'
    [IO.File]::AppendAllLines($grow, [string[]]@(($shadowRecord | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    Chk (@(Find-YakuTranslationMemory -Text $shadowSource -Path $grow | Where-Object { [bool]$_.Exact }).Count -eq 0) '同じunitへ改ざんを追記されたら前の候補も残さない'

    Write-Host '行の途中で終わっているファイルは前へ進めない' -ForegroundColor Cyan
    # 追記は既存の最終行の続きとして連結される。憶えた分が改行で終わって
    # いなければ、憶えている「1行」と食い違うので作り直すしかない。
    $partial = Join-Path $tmp 'partial.jsonl'
    $partialSources = @(New-TestTranslationMemorySeedFile -Path (Join-Path $tmp 'partial-src.jsonl') -Count 1 -Prefix 'partial')
    $partialLine = @([IO.File]::ReadAllLines((Join-Path $tmp 'partial-src.jsonl')))[0]
    [IO.File]::WriteAllText($partial, $partialLine, [Text.UTF8Encoding]::new($false))
    Clear-YakuTranslationMemoryCache
    Chk ((Read-YakuTranslationMemory -Path $partial).Count -eq 1) '改行で終わらないファイルも読める'
    [IO.File]::AppendAllText($partial, "のつづき`r`n", [Text.UTF8Encoding]::new($false))
    Chk ((Read-YakuTranslationMemory -Path $partial).Count -eq 0) '行の途中に足された分は前の行の続きとして読み直す'

    Write-Host '撤回してから確認し直す' -ForegroundColor Cyan
    # tombstoneで候補から外したunitを、あとで確認し直すと戻る。差分で前へ
    # 進めた姿と、全部作り直した姿が、同じ候補を同じ順で出すことを固定する。
    $revive = Join-Path $tmp 'revive.jsonl'
    $reviveSources = @(New-TestTranslationMemorySeedFile -Path $revive -Count 3 -Prefix 'revive')
    Clear-YakuTranslationMemoryCache
    $reviveTargetSource = [string]$reviveSources[1]
    $reviveProject = (Get-YakuTranslationMemoryHash -Text 'revive-project-1').Substring(0, 32)
    $reviveSegment = (Get-YakuTranslationMemoryHash -Text 'revive-segment-1').Substring(0, 32)
    Chk (@(Find-YakuTranslationMemory -Text $reviveTargetSource -Path $revive | Where-Object { [bool]$_.Exact }).Count -eq 1) '撤回する前は候補に出る'
    $r = Add-YakuTranslationMemoryTombstone -Path $revive -OriginProjectId $reviveProject -OriginSegmentId $reviveSegment `
        -ReviewRevision 2 -Reason 'gate-withdrawn'
    Chk ([bool]$r.Added) '記憶化に載せたあとでも撤回できる'
    Chk (@(Find-YakuTranslationMemory -Text $reviveTargetSource -Path $revive | Where-Object { [bool]$_.Exact }).Count -eq 0) '撤回した行は候補から消える'
    $r = Add-YakuTranslationMemoryEntry -Path $revive -Source $reviveTargetSource -Target 'Revived translation.' `
        -OriginProjectId $reviveProject -OriginFileName 'seed.xlsx' -OriginSegmentId $reviveSegment `
        -OriginLocation 'Sheet1, A2' -OriginPage 1 -ReviewRevision 3
    Chk ([bool]$r.Added -and $r.Reason -eq 'revived') '撤回したunitを確認し直すと戻る'
    $reviveWarm = @(Find-YakuTranslationMemory -Text $reviveTargetSource -Path $revive)
    Clear-YakuTranslationMemoryCache
    $reviveCold = @(Find-YakuTranslationMemory -Text $reviveTargetSource -Path $revive)
    Chk ((Get-TranslationMemoryShape -Hits $reviveWarm) -eq (Get-TranslationMemoryShape -Hits $reviveCold) -and
         $reviveWarm.Count -eq 1 -and [string]$reviveWarm[0].Target -eq 'Revived translation.') '差分で進めた姿と作り直した姿が一致する'

    Write-Host '一致率の対称性と、文の長さから独立していること' -ForegroundColor Cyan
    # 2026-08-16 に文字trigramのDice係数から編集距離へ替えた。Diceは文の長さで
    # 答えが変わる。n文字の文で隣り合う2字を書き換えると trigram は n-2 個のうち
    # 4個が壊れるので 1 - 4/(n-2) になり、**16字未満の文は1語違うだけで必ず
    # 0.70 を割って隠れていた**（実測 n=12 で 0.600、n=45 で 0.905）。
    # 勘定科目名・表の見出し・短い注記はほぼ全部この長さである。
    # 出典 `_docs/測定_一致率_2026-08-16.md`
    $makeDistinct = {
        param([int]$Length)
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $Length; $i++) { [void]$sb.Append([char](0x4E00 + ($i * 7))) }
        return $sb.ToString()
    }
    foreach ($len in @(6, 12, 25, 45)) {
        $base = & $makeDistinct $len
        $edited = $base.Substring(0, [int][Math]::Floor($len / 2)) + [char]0x9F98 + $base.Substring([int][Math]::Floor($len / 2) + 1)
        $ratio = [double](Get-YakuTranslationMemorySimilarity -Left $base -Right $edited)
        Chk ($base.Length -eq $edited.Length -and $base -ne $edited) ('治具が1字だけ違う: ' + $len + '字')
        Chk ([Math]::Abs($ratio - (1.0 - (1.0 / $len))) -lt 0.000000001) ('1字違いが 1-1/n になる: ' + $len + '字 → ' + $ratio.ToString('N3'))
        Chk ($ratio -ge 0.70) ('1字違いは長さによらず表に出る: ' + $len + '字')
    }
    foreach ($pair in @(@('発行', '発行元'), @('AB', 'ABC'), @('abc', 'abcdef'), @('ABCD', 'ABCDE'))) {
        $fwd = [double](Get-YakuTranslationMemorySimilarity -Left $pair[0] -Right $pair[1])
        $rev = [double](Get-YakuTranslationMemorySimilarity -Left $pair[1] -Right $pair[0])
        Chk ([Math]::Abs($fwd - $rev) -lt 0.000000001) ('一致率が左右で同じ: ' + $pair[0] + ' / ' + $pair[1])
    }
    Chk ([double](Get-YakuTranslationMemorySimilarity -Left '発行' -Right '発行元') -lt 1.0) '短い語の包含を完全一致として扱わない'
    Chk ([Math]::Abs([double](Get-YakuTranslationMemorySimilarity -Left 'ABCD' -Right 'ABCDE') - 0.8) -lt 0.000000001) '1字足しただけなら 1-1/5 を返す'
    # 控え（Add-Type が使えない環境）が同じ値を返すこと。片方だけ直す事故を止める。
    $scorerType = Get-YakuTranslationMemoryScorer
    Chk ($null -ne $scorerType) 'Add-Type で一致率の型を用意できる'
    foreach ($pair in @(@('ABCD', 'ABCDE'), @('発行', '発行元'), @((& $makeDistinct 25), (& $makeDistinct 20)))) {
        $viaNet = [double]$scorerType::Score($pair[0], $pair[1])
        $viaPs = [double](Get-YakuTranslationMemoryEditRatioManaged -Left $pair[0] -Right $pair[1])
        Chk ([Math]::Abs($viaNet - $viaPs) -lt 0.000000001) ('控えと本体が同じ値: ' + $pair[0].Length + '字/' + $pair[1].Length + '字')
    }

    Write-Host '確定と結びついているか' -ForegroundColor Cyan
    $cat = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'CatProject.ps1') -Raw -Encoding UTF8
    $server = Get-Content -LiteralPath (Join-Path (Join-Path $root 'src') 'Server.ps1') -Raw -Encoding UTF8
    Chk ($server -match "'tm-register'" -and $server -match 'Register-YakuCatSegmentTranslationMemory' -and $server -match 'Sync-YakuCatTranslationMemoryOutbox') '明示したときだけ確認訳を翻訳メモリへ貯める'
    Chk ($server -match 'OriginProjectId' -and $server -match 'OriginFileName' -and $server -match 'OriginSegmentId' -and $server -match 'OriginLocation' -and $server -match 'ReviewRevision') '確定時に出典契約をTMへ渡す'
    Chk ($server -match 'location\s*=\s*\[string\]\$_\.Location') '候補APIがlocationを返す'
    Chk ($cat -match 'Find-YakuTranslationMemory') '候補ペインが翻訳メモリを引く'
    Chk ($cat -match "Kind\s*=\s*'memory'") '翻訳メモリの候補に印を付ける'
    # 自分が確定した訳を先頭に置く。公表訳より自分の文体に合うため。
    Chk ($cat -match 'Weight   = 30000') '自分の訳を先に出す'
    Chk ($cat -notmatch 'Find-YakuCorpusPairsForSegment' -and $cat -notmatch "Kind\s*=\s*'corpus'") '候補に退役した参照資料を混ぜない'
    # 過去訳の一括登録は、確認済みの対訳対応だけを対象にする。
    Chk ($cat -match 'Register-YakuCatAlignmentTranslationMemoryBulk' -and $cat -match "Project\.Source -cne 'align'") '一括登録は突き合わせた資料からだけ保存できる'

    Write-Host '確定の状態' -ForegroundColor Cyan
    foreach ($mod in @('Paths.ps1', 'Runtime.ps1', 'Settings.ps1', 'PromptBuilder.ps1', 'Translation.ps1',  'CatTranslation.ps1', 'CellSegments.ps1', 'CatProject.ps1')) {
        . (Join-Path (Join-Path $root 'src') $mod)
    }
    $proj = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "当社は電動化を進めます。" -Translation "We will advance electrification."
    $sum = Get-YakuCatProjectSummary -Project $proj
    Chk ([int]$sum.Translated -eq 1 -and [int]$sum.Confirmed -eq 0) '訳が入っていても、見るまでは確定にしない'
    Chk ([string]@($proj.Segments)[0].Origin -eq 'copilot') '簡易翻訳から来た訳は機械の訳として印を付ける'

    $null = Set-YakuCatSegmentConfirmed -Project $proj -Index 0
    $null = Set-YakuCatProjectSaved -Project $proj -Reason 'first-translation-review'
    $sum = Get-YakuCatProjectSummary -Project $proj
    Chk ([int]$sum.Confirmed -eq 1 -and [int]$sum.Unconfirmed -eq 0) '直さずに確定できる'

    Write-Host 'PDF対訳をメモリへ登録する空白' -ForegroundColor Cyan
    $alignMemory = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text '  決算補足説明資料作成の有無                    ： 有  ' `
        -Translation '  Supplementary Material                         :      Yes  '
    $alignMemory.Source = 'align'
    $alignMemory.TmOutbox = @()
    $null = Add-YakuCatTranslationMemoryOutboxEvent -Project $alignMemory -Segment @($alignMemory.Segments)[0]
    Chk ([string]$alignMemory.TmOutbox[0].source -eq '決算補足説明資料作成の有無 ： 有') 'PDF表の原文から桁合わせ用の空白を除く'
    Chk ([string]$alignMemory.TmOutbox[0].target -eq 'Supplementary Material : Yes') 'PDF表の訳文から桁合わせ用の空白を除く'

    $ordinaryMemory = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text 'A  B' -Translation 'C  D'
    $ordinaryMemory.TmOutbox = @()
    $null = Add-YakuCatTranslationMemoryOutboxEvent -Project $ordinaryMemory -Segment @($ordinaryMemory.Segments)[0]
    Chk ([string]$ordinaryMemory.TmOutbox[0].source -eq 'A  B' -and [string]$ordinaryMemory.TmOutbox[0].target -eq 'C  D') '通常翻訳で利用者が入力した空白は変えない'

    $empty = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' -Text "訳の無い文です。"
    $threw = $false
    try { $null = Set-YakuCatSegmentConfirmed -Project $empty -Index 0 } catch { $threw = $true }
    Chk $threw '訳が空の行は確定できない'

    $cleared = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "一度訳した文です。" -Translation "This sentence was translated once."
    $null = Set-YakuCatSegmentTranslation -Project $cleared -Index 0 -Text ''
    Chk ([string]@($cleared.Segments)[0].Translation -eq '') '訳文を空へ戻せる'
    Chk (-not [bool]@($cleared.Segments)[0].Confirmed) '空へ戻した行は確認済みにしない'
    Chk ([string]@($cleared.Segments)[0].Origin -eq '') '空へ戻した行に手直し済みの印を残さない'

    # 行数が合わない訳文は割り当てない。ずれた対応を見せるより空欄がよい。
    $mismatch = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' `
        -Text "一つ目の文です。二つ目の文です。" -Translation "Only one sentence."
    Chk ([string]@($mismatch.Segments)[0].Translation -eq '') '行数が合わない訳文は割り当てない'

    Write-Host '作業内容の保存と復元' -ForegroundColor Cyan
    Chk (Save-YakuCatProject -Project $proj) 'ディスクへ保存できる'
    $file = Join-Path (Join-Path (Get-YakuCatProjectStoreDir) ([string]$proj.Id)) 'project.json'
    Chk (Test-Path -LiteralPath $file -PathType Leaf) '保存先にファイルができる'

    Write-Host 'CAT候補の出典' -ForegroundColor Cyan
    $reviewedSegment = @($proj.Segments)[0]
    $tmSaved = Add-YakuTranslationMemoryEntry -Source ([string]$reviewedSegment.Text) -Target ([string]$reviewedSegment.Translation) `
        -Direction ([string]$proj.Direction) -Origin 'cat-reviewed-qc-v1' `
        -OriginProjectId ([string]$proj.Id) -OriginFileName 'FY2025-results.docx' `
        -OriginSegmentId ([string]$reviewedSegment.SegmentId) -OriginLocation '本文 段落 12' `
        -OriginPage 4 -ReviewRevision ([int]$proj.Revision)
    Chk ([bool]$tmSaved.Added) '保存済みCAT revisionから出典付きTMを作る'
    $candidateProject = New-YakuCatTextProject -Root $root -Settings $null -Direction 'to_en' -Text ([string]$reviewedSegment.Text)
    $memoryCandidates = @(Get-YakuCatSegmentCandidates -Root $root -Project $candidateProject -Index 0 | Where-Object { [string]$_.Kind -eq 'memory' })
    Chk ($memoryCandidates.Count -eq 1) '出典付きTMだけがCAT候補へ出る'
    Chk ([string]$memoryCandidates[0].SourceName -eq 'FY2025-results.docx' -and [string]$memoryCandidates[0].Location -eq '本文 段落 12' -and [int]$memoryCandidates[0].Page -eq 4) 'CAT候補がどの資料のどの箇所かを返す'
    $null = Set-YakuCatSegmentTranslation -Project $candidateProject -Index 0 -Text ([string]$memoryCandidates[0].Target)
    $null = Set-YakuCatSegmentReferenceUsage -Project $candidateProject -Index 0 -Candidate $memoryCandidates[0]
    Chk ([string]@($candidateProject.Segments)[0].ReferenceUsage.location -eq '本文 段落 12') '明示挿入の記録にも出典箇所を残す'

    # メモリから消したうえで復元する。再起動を模している。
    Remove-YakuCatProject -Id ([string]$proj.Id)
    Chk ($null -eq (Get-YakuCatProject -Id ([string]$proj.Id))) 'メモリからは消えている'
    $back = Restore-YakuCatProject -Id ([string]$proj.Id)
    Chk ($null -ne $back) '保存したものを戻せる'
    Chk (@($back.Segments).Count -eq @($proj.Segments).Count) '行数が保たれる'
    Chk ([bool]@($back.Segments)[0].Confirmed) '確定の状態が残る'
    Chk ([string]@($back.Segments)[0].Translation -eq 'We will advance electrification.') '訳文が残る'
    Chk ([string]$back.Direction -eq 'to_en') '翻訳方向が残る'

    $recent = @(Get-YakuCatSavedProjects -Limit 10)
    Chk (@($recent | Where-Object { [string]$_.Id -eq [string]$proj.Id }).Count -eq 1) '前回の続きの一覧に出る'
    $entry = @($recent | Where-Object { [string]$_.Id -eq [string]$proj.Id })[0]
    Chk ([int]$entry.Confirmed -eq 1 -and [int]$entry.Total -eq 1) '一覧に確認済みの数が出る'

    Chk ($null -eq (Restore-YakuCatProject -Id 'no-such-project')) '無いものを戻そうとしても落ちない'
    try { Remove-Item -LiteralPath $file -Force } catch {}

    Write-Host '言葉で探す（コンコーダンス）' -ForegroundColor Cyan
    # 市販のCATツールでいうコンコーダンス。いまの行に対して自動で出る候補
    # （Find-YakuTranslationMemory）とは別で、利用者が言葉を入れて過去訳を引く。
    $null = Add-TestTranslationMemoryEntry -Source '固定費を圧縮しました。' -Target 'We reduced fixed costs.' -Path $tm
    $concordance = @(Search-YakuTranslationMemoryConcordance -Query '固定費' -Direction 'to_en' -Path $tm)
    Chk ($concordance.Count -ge 1) '原文に含む言葉で引ける'
    Chk ([string]$concordance[0].Target -eq 'We reduced fixed costs.') '訳文が一緒に返る'
    Chk ([string]$concordance[0].MatchedIn -eq 'source') 'どちら側に当たったかが分かる'
    $byTarget = @(Search-YakuTranslationMemoryConcordance -Query 'fixed costs' -Direction 'to_en' -Path $tm)
    Chk ($byTarget.Count -ge 1 -and [string]$byTarget[0].MatchedIn -eq 'target') '訳文に含む言葉でも引ける'
    $byCase = @(Search-YakuTranslationMemoryConcordance -Query 'FIXED COSTS' -Direction 'to_en' -Path $tm)
    Chk ($byCase.Count -ge 1) '英語は大文字小文字を畳む'
    Chk (@(Search-YakuTranslationMemoryConcordance -Query '固' -Direction 'to_en' -Path $tm).Count -eq 0) '1文字では引かない（何にでも当たる）'
    Chk (@(Search-YakuTranslationMemoryConcordance -Query '存在しない言葉' -Direction 'to_en' -Path $tm).Count -eq 0) '無いものは無いと返す'
}
finally {
    $env:YAKULINGO_DATA_DIR = $oldDataDir
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
}

if ($script:fail -gt 0) {
    Write-Host "V91.61 translation memory regression failed. failures=$script:fail" -ForegroundColor Red
    exit 1
}
Write-Host 'V91.61 translation memory regression passed.' -ForegroundColor Green
