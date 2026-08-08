<#
  日英アライメントで Copilot へ渡す文の数値マスク。

  社内ルール: Copilot は機密情報を扱ってよい。ただし未公開の財務情報は
  機密性が高いため、数字だけはマスクして渡す。

  翻訳経路のマスク（Translation.ps1）は数値を訳文へ戻す必要があるので
  可逆にしてある。アライメント経路は違う。Copilot から返るのは行番号だけで、
  文そのものは返らない。だから値を捨てる非可逆マスクが使える。
  復元経路が無いぶん、こちらのほうが安全側に倒せる。

  精度への影響は実測した（有報 R&D 節、日50行/英60行）。
  数値あり 21組 / 数値マスク 21組、対応は 21/21 が完全一致。
  Copilot は文意で対応を取っているので、数字を消しても落ちない。

  正規表現は必ず取りこぼす。そのため送信直前に
  Test-YakuAlignmentTextSafe で数字の残りを検査し、残っていれば送らない。
#>

# 半角・全角の数字1文字。
$script:YakuAlignDigit = '[0-9０-９]'
# 桁区切りと小数点を含む数値のかたまり。前後は必ず数字で終える。
$script:YakuAlignNumberCore = '[0-9０-９][0-9０-９,，\.．]*[0-9０-９]|[0-9０-９]'
# 漢数字。〇と零を含める（二〇二六年 のような表記があるため）。
$script:YakuAlignKanjiDigit = '[〇零一二三四五六七八九十百千万億兆]'
# 漢数字に続いたら数量とみなす単位。
# 「分」は十分（じゅうぶん）、「部」は一部、「方」は一方、「期」は四半期に
# 当たってしまうので入れない。取りこぼすより、文を壊さないほうを採る。
$script:YakuAlignKanjiUnit = '(?:円|ドル|株|名|人|件|台|年|月|日|回|倍|割|％|%|ポイント)'
# 英語の綴りによる数。桁語（hundred 以上）を含むものだけを数とみなす。
# そうしないと one of the ... まで潰れる。
$script:YakuAlignEnWord = '(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion|point)'
$script:YakuAlignEnScale = '(?:hundred|thousand|million|billion|trillion)'

function Get-YakuAlignmentMaskToken {
    param([ValidateSet('ja', 'en')][string]$Language = 'ja')
    if ($Language -eq 'en') { return '[NUM]' }
    return '〔数〕'
}

function ConvertTo-YakuAlignmentMaskedText {
    <#
      1行分の文から数を消す。置き換えるトークンに数字は含めない。
      桁を表す語（億・兆・billion）もトークンへ吸収する。桁だけ残すと
      未公開の金額の桁数が読めてしまうため。
    #>
    param(
        [AllowNull()][string]$Text,
        [ValidateSet('ja', 'en')][string]$Language = 'ja'
    )
    $s = [string]$Text
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $token = Get-YakuAlignmentMaskToken -Language $Language
    $num = $script:YakuAlignNumberCore

    if ($Language -eq 'en') {
        # 12.2 billion / 1,234 thousand → [NUM]
        $s = [regex]::Replace($s, "(?:$num)(?:\s*$script:YakuAlignEnScale\b)?", $token, 'IgnoreCase')
        # 綴りの数。桁語を含む並びだけを潰す。
        $s = [regex]::Replace($s, "\b$script:YakuAlignEnWord(?:[\s\-]+(?:and[\s\-]+)?$script:YakuAlignEnWord)*\b", {
                param($m)
                if ($m.Value -match $script:YakuAlignEnScale) { return $token }
                return $m.Value
            }, 'IgnoreCase')
    }
    else {
        # 1兆2,345億 のように桁の漢字を挟む並びは、まとめて1つに潰す。
        $s = [regex]::Replace($s, "(?:$num)(?:\s*[兆億万千百](?:\s*(?:$num))?)*", $token)
        # 漢数字＋単位。単位そのものは残す（円 は秘密ではなく、対応の手がかりになる）。
        $s = [regex]::Replace($s, "$script:YakuAlignKanjiDigit+(?=$script:YakuAlignKanjiUnit)", $token)
    }
    # 同じトークンが連続したらまとめる。1〜2 のような並びが 〔数〕〜〔数〕 で
    # 残るのは構わないが、隣接した重複は読みにくいだけなので畳む。
    $s = [regex]::Replace($s, '(?:' + [regex]::Escape($token) + '){2,}', $token)
    return $s
}

function Test-YakuAlignmentTextSafe {
    <#
      送信直前の検査。数が残っていれば Safe=$false を返す。
      正規表現の取りこぼしが将来見つかっても、ここで止まれば情報は出ない。
    #>
    param(
        [AllowNull()][string[]]$Lines,
        [ValidateSet('ja', 'en')][string]$Language = 'ja'
    )
    $findings = New-Object System.Collections.Generic.List[object]
    $index = -1
    foreach ($line in @($Lines)) {
        $index++
        $s = [string]$line
        if ([string]::IsNullOrEmpty($s)) { continue }
        $hits = New-Object System.Collections.Generic.List[string]
        $m = [regex]::Match($s, $script:YakuAlignDigit)
        if ($m.Success) { [void]$hits.Add('数字が残っている: ' + $m.Value) }
        if ($Language -eq 'ja') {
            $m = [regex]::Match($s, "$script:YakuAlignKanjiDigit+$script:YakuAlignKanjiUnit")
            if ($m.Success) { [void]$hits.Add('漢数字が残っている: ' + $m.Value) }
        }
        else {
            $m = [regex]::Match($s, "\b$script:YakuAlignEnWord(?:[\s\-]+(?:and[\s\-]+)?$script:YakuAlignEnWord)*\b", 'IgnoreCase')
            while ($m.Success) {
                if ($m.Value -match $script:YakuAlignEnScale) { [void]$hits.Add('綴りの数が残っている: ' + $m.Value); break }
                $m = $m.NextMatch()
            }
        }
        if ($hits.Count -gt 0) {
            [void]$findings.Add([pscustomobject]@{
                    Index  = $index
                    Reason = ($hits -join ' / ')
                    Sample = $(if ($s.Length -gt 60) { $s.Substring(0, 60) } else { $s })
                })
        }
    }
    return [pscustomobject]@{
        Safe     = ($findings.Count -eq 0)
        Findings = @($findings.ToArray())
    }
}

function Protect-YakuAlignmentLines {
    <#
      行の並びをマスクし、検査に通ったものだけを返す。
      通らなければ例外を投げる。呼び出し側が握り潰さない限り送信されない。
    #>
    param(
        [AllowNull()][string[]]$Lines,
        [ValidateSet('ja', 'en')][string]$Language = 'ja'
    )
    $masked = @(@($Lines) | ForEach-Object { ConvertTo-YakuAlignmentMaskedText -Text ([string]$_) -Language $Language })
    $check = Test-YakuAlignmentTextSafe -Lines $masked -Language $Language
    if (-not $check.Safe) {
        $first = @($check.Findings)[0]
        $message = 'Alignment masking left a number in the text. Sending was stopped. language=' + $Language +
        ' line=' + [string]$first.Index + ' reason=' + [string]$first.Reason
        try { Write-YakuLog $message 'ERROR' } catch {}
        throw $message
    }
    return , $masked
}
