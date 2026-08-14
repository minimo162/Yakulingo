<# .SYNOPSIS Horizon 3 Word adapter and DRAFT round-trip regression. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root=Split-Path -Parent $toolsRoot
$script:failed=0
function Check-YakuWord { param([bool]$Condition,[string]$Message) if($Condition){Write-Host ('  ok   '+$Message) -ForegroundColor Green}else{Write-Host ('  FAIL '+$Message) -ForegroundColor Red;$script:failed++} }
foreach($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','PromptBuilder.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','WordAdapter.ps1','CatProject.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('yaku-word-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tempRoot -Force
function Get-YakuCatProjectStoreDir { return (Join-Path $tempRoot 'cat') }
function Add-YakuTranslationMemoryEntry { return [pscustomobject]@{Added=$true;Reason='test'} }

function New-TestDocxParagraph {
    # 段落ひとつだけの docx。run の書式だけを変えて試すために使う。
    param([string]$Path,[string]$RunsXml)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        $parts=[ordered]@{
            '[Content_Types].xml'='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
            '_rels/.rels'='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            'word/document.xml'='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p>'+$RunsXml+'</w:p><w:sectPr/></w:body></w:document>'
        }
        foreach($name in $parts.Keys){
            $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
            $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
            try{$writer.Write([string]$parts[$name])}finally{$writer.Dispose()}
        }
    } finally {$zip.Dispose();$stream.Dispose()}
}

function New-TestDocx {
    param([string]$Path,[switch]$Complex)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        $parts=[ordered]@{
            '[Content_Types].xml'='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
            '_rels/.rels'='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
        }
        $complexXml=if($Complex){'<w:hyperlink><w:r><w:t>リンク付き本文</w:t></w:r></w:hyperlink>'}else{'<w:r><w:t>売上について説明します。</w:t></w:r>'}
        $parts['word/document.xml']='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'+$complexXml+'</w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>今後の見通しです。</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:sectPr/></w:body></w:document>'
        foreach($name in $parts.Keys){
            $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
            $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
            try{$writer.Write([string]$parts[$name])}finally{$writer.Dispose()}
        }
    } finally {$zip.Dispose();$stream.Dispose()}
}

function Add-TestDocxStory {
    param([string]$Path,[string]$Name,[string]$Text,[string]$RunsXml='')
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Update,$false)
    try {
        $entry=$zip.CreateEntry(('word/'+$Name+'.xml'),[IO.Compression.CompressionLevel]::Optimal)
        $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
        $storyRuns=if([string]::IsNullOrWhiteSpace($RunsXml)){'<w:r><w:t>'+[Security.SecurityElement]::Escape($Text)+'</w:t></w:r>'}else{$RunsXml}
        try{$writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:'+$(if($Name -like 'header*'){'hdr'}else{'ftr'})+' xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p>'+$storyRuns+'</w:p></w:'+$(if($Name -like 'header*'){'hdr'}else{'ftr'})+'>')}finally{$writer.Dispose()}
    } finally {$zip.Dispose();$stream.Dispose()}
}

try {
    $source=Join-Path $tempRoot 'quarter.docx'; New-TestDocx -Path $source
    $settings=[pscustomobject]@{}
    $inventory=Get-YakuWordDocumentInventory -Path $source
    Check-YakuWord ($inventory.SupportedBlockCount -eq 2 -and $inventory.DraftStructureEligible) 'simple heading and table paragraph are inventoried'
    Check-YakuWord ([string]$inventory.Blocks[0].Location -like '見出し*' -and [string]$inventory.Blocks[1].Meta.Kind -eq 'word_table') 'heading and table locations stay distinct'

    # 取り込みの入口（/api/cat/open と /api/file-info）は、プロジェクトを作る前に
    # 必ず Get-YakuFileInfo で訳す向きを見る。ここが Excel と CSV しか知らず、
    # Word は「対応しているファイル形式は .xlsx / .xlsm / .csv です」で止まっていた。
    # この試験は New-YakuCatProject を直接叩いていたので、下の層だけ緑で、
    # 実際の経路は通らないままだった（2026-08-11、実機の Word 取り込みで発覚）。
    $wordInfo = Get-YakuFileInfo -Path $source -Settings $settings
    Check-YakuWord ([string]$wordInfo.Kind -eq 'word' -and [string]$wordInfo.FileName -eq 'quarter.docx') 'the import gate accepts DOCX instead of rejecting it as an unsupported type'
    Check-YakuWord (@('to_en','to_jp') -contains [string]$wordInfo.DetectedDirection -and -not [string]::IsNullOrWhiteSpace([string]$wordInfo.DirectionConfidence)) 'the import gate decides a direction for DOCX like it does for Excel'

    $mixedLanguage=Join-Path $tempRoot 'mixed-language.docx'
    New-TestDocxParagraph -Path $mixedLanguage -RunsXml '<w:r><w:t>お客様へのお知らせです。</w:t></w:r></w:p><w:p><w:r><w:t>Customer Communication</w:t></w:r>'
    $mixedProject=New-YakuCatProject -Root $root -Path $mixedLanguage -Settings $settings -Direction to_en
    Check-YakuWord (@($mixedProject.Blocks).Count -eq 2 -and @($mixedProject.Segments).Count -eq 1) 'already-English Word headers remain in the file without becoming untranslated blockers'
    Check-YakuWord ([string]$mixedProject.Segments[0].Text -eq 'お客様へのお知らせです。') 'only text needing the selected direction appears in the review grid'

    $storyDoc=Join-Path $tempRoot 'header-footer.docx'; New-TestDocx -Path $storyDoc
    Add-TestDocxStory -Path $storyDoc -Name 'header1' -RunsXml '<w:r><w:rPr><w:b/></w:rPr><w:t>Customer Notice</w:t></w:r><w:r><w:t xml:space="preserve"> 2026年度 お客様向け資料</w:t></w:r>'
    Add-TestDocxStory -Path $storyDoc -Name 'footer1' -Text 'Customer Communication'
    $storyProject=New-YakuCatProject -Root $root -Path $storyDoc -Settings $settings -Direction to_en
    Check-YakuWord ([bool]$storyProject.WordInventory.DraftStructureEligible -and @($storyProject.Blocks).Count -eq 5) 'mixed-format headers and simple footers remain eligible for a Word DRAFT'
    Check-YakuWord (@($storyProject.Segments).Count -eq 3) 'an English footer stays unchanged while a Japanese header is translated'
    for($storyIndex=0;$storyIndex -lt @($storyProject.Segments).Count;$storyIndex++){
        $storyProject.Segments[$storyIndex].Translation=$(if([string]$storyProject.Segments[$storyIndex].Text -match '2026'){'Translated 2026'}else{'Translated text'}); $storyProject.Segments[$storyIndex].Origin='human'
        $null=Set-YakuCatSegmentConfirmed -Project $storyProject -Index $storyIndex
    }
    $storyOutput=Join-Path $tempRoot 'DRAFT_header-footer.docx'
    $storyResult=Export-YakuCatProject -Project $storyProject -OutputPath $storyOutput -Settings $settings
    $storyAfter=Get-YakuWordDocumentInventory -Path $storyOutput
    $storyAfterText=@($storyAfter.Blocks|ForEach-Object{[string]$_.Text}) -join '|'
    Check-YakuWord ($storyResult.Written -eq 3 -and $storyAfterText -match 'Customer Notice' -and $storyAfterText -match 'Translated 2026' -and $storyAfterText -match 'Customer Communication') 'translated header run is written while its English prefix and footer are preserved'

    $project=New-YakuCatProject -Root $root -Path $source -Settings $settings -Direction to_en
    Check-YakuWord ([string]$project.DocumentFormat -eq 'docx' -and @($project.Segments).Count -eq 2) 'generic CAT open dispatches DOCX to Word adapter'
    Check-YakuWord (Save-YakuCatProject -Project $project) 'Word project and owned source persist'
    # 原本の置き場は cat-source-v2（source\revisions\<原本hashの先頭32桁>\original.ext）。
    # Save-YakuCatProject 側の CatProject.ps1:1813,1841 が決め、
    # Resolve-YakuCatSavedSourceArtifact（CatProject.ps1:1873）が契約として検査する。
    # source\original.docx は v1 の旧形。#52 で v2 へ移ったとき、この1行だけ取り残された。
    # 表明の中身は緩めない。利用者の元ファイルではなく作業領域の複製を指していること
    # （-ne $source）と、契約そのもの（cat-source-v2）を足して、次に配置が変わったら
    # 黙って通らないようにする。
    Check-YakuWord ([string]$project.Path -ne [string]$source -and [string]$project.Path -match '\\source\\revisions\\[a-f0-9]{32}\\original\.docx$' -and [string]$project.SourceArtifactContractVersion -eq 'cat-source-v2' -and (Test-Path -LiteralPath $project.Path)) 'Word source is copied into the project'
    Check-YakuWord ([string]$project.FileName -eq 'quarter.docx') 'owned source keeps the user-facing original file name'
    $suggestedOutput=Get-YakuCatDraftOutputPath -Project $project -OutputDirectory $tempRoot
    Check-YakuWord ([IO.Path]::GetFileName($suggestedOutput) -eq 'DRAFT_quarter_translated.docx') 'DRAFT output name uses the imported file name instead of original.docx'
    $null=New-Item -ItemType File -Path $suggestedOutput
    $nextSuggestedOutput=Get-YakuCatDraftOutputPath -Project $project -OutputDirectory $tempRoot
    Check-YakuWord ([IO.Path]::GetFileName($nextSuggestedOutput) -eq 'DRAFT_quarter_translated(2).docx') 'an existing DRAFT is not overwritten'
    $project.Segments[0].Translation='About net sales.'; $project.Segments[0].Origin='human'
    $project.Segments[1].Translation='This is the outlook.'; $project.Segments[1].Origin='human'
    $null=Set-YakuCatSegmentConfirmed -Project $project -Index 0
    $null=Set-YakuCatSegmentConfirmed -Project $project -Index 1
    Check-YakuWord (Save-YakuCatProject -Project $project) 'review and QC state persist before restart'
    $eligible=Get-YakuCatOutputEligibility -Project $project
    Check-YakuWord ($eligible.WordDraftEligible -and -not $eligible.ExcelDraftEligible) 'reviewed Word uses a separate Word DRAFT release gate'
    $output=$nextSuggestedOutput
    $result=Export-YakuCatProject -Project $project -OutputPath $output -Settings $settings
    Check-YakuWord ((Test-Path -LiteralPath $output) -and $result.Written -eq 2) 'DRAFT DOCX is written only after review'
    $after=Get-YakuWordDocumentInventory -Path $output
    $afterText=@($after.Blocks | ForEach-Object {[string]$_.Text}) -join '|'
    # 本文の1行目へ入れていた「DRAFT — YakuLingo（確認用）」は 2026-08-13 に
    # 利用者判断で外した（「そもそもその機能自体いらない」）。下書きであることは
    # ファイル名の DRAFT_ が示す。原本に無い行を足さないことのほうを固定する。
    Check-YakuWord ($afterText -notmatch 'DRAFT — YakuLingo' -and $afterText -match 'About net sales' -and $afterText -match 'This is the outlook') '確認済みの訳文だけが入り、原本に無い行を足さない'
    Check-YakuWord (@($after.Blocks).Count -eq @($inventory.Blocks).Count) '段落の数が原本と変わらない'
    Check-YakuWord ([string]$after.StructureHash -eq [string]$inventory.StructureHash -and (Compare-Object @($after.EntryNames) @($inventory.EntryNames)).Count -eq 0) 'OOXML structure and package graph survive round trip'
    $id=[string]$project.Id; Remove-YakuCatProject -Id $id
    $restored=Restore-YakuCatProject -Id $id
    Check-YakuWord ([string]$restored.DocumentFormat -eq 'docx' -and [string]$restored.WordInventory.ContractVersion -eq 'word-adapter-v1') 'Word capability inventory survives restart'
    $restartOutput=Join-Path $tempRoot 'DRAFT_quarter_restart.docx'
    $restartResult=Export-YakuCatProject -Project $restored -OutputPath $restartOutput -Settings $settings
    Check-YakuWord ((Test-Path -LiteralPath $restartOutput) -and $restartResult.Written -eq 2) 'restored Word project can still produce a verified DRAFT'

    # 日本語を打つと Word は自動で w:rFonts の w:hint を付ける。hint は書式ではなく
    # どのフォント表を当てるかの指定で、太さも大きさも色も変えない。これを別書式と
    # 数えていたため、Word が作った普通の1段落の文書ですら DRAFT を出せなかった
    # （2026-08-11、実機で判明）。ほんとうの書式差（太字）は今までどおり止める。
    $hintDoc=Join-Path $tempRoot 'hint.docx'
    New-TestDocxParagraph -Path $hintDoc -RunsXml '<w:r><w:rPr><w:rFonts w:hint="eastAsia"/></w:rPr><w:t>当第</w:t></w:r><w:r><w:t>1四半期の売上高です。</w:t></w:r>'
    $hintInv=Get-YakuWordDocumentInventory -Path $hintDoc
    Check-YakuWord ([bool]$hintInv.DraftStructureEligible -and $hintInv.SupportedBlockCount -eq 1) 'a font hint alone is not treated as a different character format'

    $boldDoc=Join-Path $tempRoot 'bold.docx'
    New-TestDocxParagraph -Path $boldDoc -RunsXml '<w:r><w:rPr><w:b/></w:rPr><w:t>当第</w:t></w:r><w:r><w:t>1四半期の売上高です。</w:t></w:r>'
    $boldInv=Get-YakuWordDocumentInventory -Path $boldDoc
    Check-YakuWord (-not [bool]$boldInv.DraftStructureEligible -and @($boldInv.UnsupportedReasons).Count -gt 0) 'a real character format difference still fails closed'

    $complex=Join-Path $tempRoot 'complex.docx'; New-TestDocx -Path $complex -Complex
    $complexProject=New-YakuCatProject -Root $root -Path $complex -Settings $settings -Direction to_en
    Check-YakuWord (-not [bool]$complexProject.WordInventory.DraftStructureEligible -and @($complexProject.WordInventory.UnsupportedReasons).Count -gt 0) 'hyperlinked text is inventoried as unsupported'
    Check-YakuWord (-not [bool](Get-YakuCatOutputEligibility -Project $complexProject).WordDraftEligible) 'unsupported Word structure fails closed for file output'
    $complexProject.Segments[0].Translation='Linked body text.'; $complexProject.Segments[0].Origin='human'
    $complexProject.Segments[1].Translation='This is the outlook.'; $complexProject.Segments[1].Origin='human'
    $null=Set-YakuCatSegmentConfirmed -Project $complexProject -Index 0
    $null=Set-YakuCatSegmentConfirmed -Project $complexProject -Index 1
    $fallback=Export-YakuCatProject -Project $complexProject -OutputPath (Join-Path $tempRoot 'must-not-exist.docx') -Settings $settings
    Check-YakuWord ([string]$fallback.OutputPath -eq '' -and [string]$fallback.Text -eq "Linked body text.`nThis is the outlook." -and -not (Test-Path -LiteralPath (Join-Path $tempRoot 'must-not-exist.docx'))) 'unsupported Word keeps complex text in the reviewed translation list without creating a partial file'
    $serverSource=[IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') 'Server.ps1'))
    $uiSource=[IO.File]::ReadAllText((Join-Path (Join-Path $root 'www') 'cat.html'))
    Check-YakuWord ($serverSource -match "'\.docx','\.xlsx','\.xlsm','\.csv'" -and $uiSource -match 'accept="\.docx,\.xlsx,\.xlsm"') 'upload and direct-path entry both accept DOCX'
} finally { try{Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}catch{} }
if($script:failed -gt 0){throw("Word adapter tests failed: $script:failed")}
Write-Host 'V91.63 Word adapter regression passed.' -ForegroundColor Green
