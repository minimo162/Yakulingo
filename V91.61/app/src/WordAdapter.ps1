function Open-YakuWordPackage {
    param([Parameter(Mandatory=$true)][string]$Path, [ValidateSet('Read','Update')][string]$Mode = 'Read')
    $fileMode = if ($Mode -eq 'Update') { [IO.FileMode]::Open } else { [IO.FileMode]::Open }
    $access = if ($Mode -eq 'Update') { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }
    $share = if ($Mode -eq 'Update') { [IO.FileShare]::None } else { [IO.FileShare]::Read }
    $stream = [IO.File]::Open($Path, $fileMode, $access, $share)
    try {
        $zipMode = if ($Mode -eq 'Update') { [IO.Compression.ZipArchiveMode]::Update } else { [IO.Compression.ZipArchiveMode]::Read }
        $archive = New-Object IO.Compression.ZipArchive($stream, $zipMode, $false)
        return [pscustomobject]@{ Stream=$stream; Archive=$archive }
    } catch { $stream.Dispose(); throw }
}

# Windows PowerShell 5.1 resolves enum types before entering a function body.
# Load the package assemblies while this adapter is dot-sourced.
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function Close-YakuWordPackage {
    param([AllowNull()]$Package)
    if ($null -eq $Package) { return }
    try { $Package.Archive.Dispose() } finally { $Package.Stream.Dispose() }
}

function Read-YakuWordXmlEntry {
    param([Parameter(Mandatory=$true)]$Archive, [Parameter(Mandatory=$true)][string]$Name)
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { throw ('WORD_PACKAGE_PART_MISSING: ' + $Name) }
    $reader = $null
    try {
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
    } finally { if ($reader) { $reader.Dispose() } }
    $doc = New-Object Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.XmlResolver = $null
    $doc.LoadXml($text)
    return ,$doc
}

function New-YakuWordNamespaceManager {
    param([Parameter(Mandatory=$true)][Xml.XmlDocument]$Document)
    $ns = New-Object Xml.XmlNamespaceManager($Document.NameTable)
    $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $ns.AddNamespace('m','http://schemas.openxmlformats.org/officeDocument/2006/math')
    return ,$ns
}

function Get-YakuWordParagraphText {
    param([Parameter(Mandatory=$true)][Xml.XmlNode]$Paragraph, [Parameter(Mandatory=$true)]$Namespaces)
    return (@($Paragraph.SelectNodes('.//w:t', $Namespaces) | ForEach-Object { [string]$_.InnerText }) -join '')
}

function Get-YakuWordRunStyleKey {
    <#
      文字書式が同じかどうかを見るための鍵。rPr をそのまま比べると、
      w:rFonts の w:hint だけが違う run を「別の書式」と数えてしまう。

      hint は書式ではない。どの文字にどのフォント表（ascii / eastAsia）を
      当てるかの指定で、太さも大きさも色も変えない。日本語を打つと Word が
      自動で付けるため、日本語の文書ではほぼ必ず現れる。

      実測（2026-08-11、Word が作った1段落の文書）:
        run1 「当第」 rPr=<w:rFonts w:hint="eastAsia"/>
        run2 「1四半期の売上高は…」 rPr=なし
      この2つを別書式と数えたせいで DRAFT 出力が止まっていた。書き戻しは
      段落の先頭 run へ本文をまとめて入れる作りなので、hint の違いは結果に
      影響しない。ここだけを無視し、太字などほんとうの書式差は今までどおり止める。
    #>
    param([AllowNull()][Xml.XmlNode]$RunProperties)
    if ($null -eq $RunProperties) { return '' }
    $clone = $RunProperties.CloneNode($true)
    foreach ($fonts in @($clone.SelectNodes('.//*[local-name()="rFonts"]'))) {
        $null = $fonts.RemoveAttribute('hint','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        if ($fonts.Attributes.Count -eq 0 -and $fonts.ChildNodes.Count -eq 0) { $null = $fonts.ParentNode.RemoveChild($fonts) }
    }
    if ($clone.ChildNodes.Count -eq 0 -and $clone.Attributes.Count -eq 0) { return '' }
    return [string]$clone.OuterXml
}

function Get-YakuWordStructureHash {
    param([Parameter(Mandatory=$true)][Xml.XmlDocument]$Document)
    $copy = New-Object Xml.XmlDocument
    $copy.PreserveWhitespace = $false
    $copy.LoadXml($Document.OuterXml)
    if ($copy.FirstChild -is [Xml.XmlDeclaration]) { $null = $copy.RemoveChild($copy.FirstChild) }
    $ns = New-YakuWordNamespaceManager -Document $copy
    foreach ($p in @($copy.SelectNodes('//w:p', $ns))) {
        if ((Get-YakuWordParagraphText -Paragraph $p -Namespaces $ns).StartsWith('DRAFT — YakuLingo')) {
            $null = $p.ParentNode.RemoveChild($p)
        }
    }
    foreach ($node in @($copy.SelectNodes('//w:t|//w:delText', $ns))) {
        $node.InnerText = ''
        $node.RemoveAttribute('space','http://www.w3.org/XML/1998/namespace')
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($copy.OuterXml)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-YakuWordDocumentInventory {
    <#
      Wordを丸ごと「対応」とは扱わない。本文xmlを調べ、現在安全に書き戻せる
      単純な段落だけをblocksにする。未対応の本文や別storyに文字があれば、
      翻訳一覧には進めてもWord DRAFTはfail-closedで止める。
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.docx') { throw 'WORD_FILE_TYPE_UNSUPPORTED' }
    $package = $null
    try {
        $package = Open-YakuWordPackage -Path $Path
        $doc = Read-YakuWordXmlEntry -Archive $package.Archive -Name 'word/document.xml'
        $ns = New-YakuWordNamespaceManager -Document $doc
        $unsupported = New-Object Collections.Generic.List[string]
        $blocks = New-Object Collections.Generic.List[object]
        $forbiddenXPath = './/w:txbxContent|.//w:ins|.//w:del|.//w:moveFrom|.//w:moveTo|.//w:fldSimple|.//w:fldChar|.//w:instrText|.//w:hyperlink|.//w:drawing|.//w:pict|.//w:object|.//w:altChunk|.//w:sdt|.//w:tab|.//w:br|.//w:cr|.//w:sym|.//m:oMath|.//m:oMathPara'
        $paragraphs = @($doc.SelectNodes('/w:document/w:body//w:p', $ns))
        $ordinal = 0; $bodyNo = 0; $tableNo = 0; $writeSupportedCount=0
        foreach ($p in $paragraphs) {
            $ordinal++
            # テキストボックス等の外側段落は内側の段落テキストまで返す。
            # 内側を別blockにするため、親コンテナ側は重複取込しない。
            if ($p.SelectNodes('.//w:p', $ns).Count -gt 0) { continue }
            $text = Get-YakuWordParagraphText -Paragraph $p -Namespaces $ns
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $writeSupported=$true
            if ($p.SelectNodes($forbiddenXPath, $ns).Count -gt 0 -or $null -ne $p.SelectSingleNode('ancestor::w:txbxContent', $ns)) {
                $unsupported.Add(('本文の複雑な要素（段落 ' + $ordinal + '）')) | Out-Null
                $writeSupported=$false
            }
            # 複数の文字書式を一つの段落で使っている場合、訳文をどの範囲へ
            # 割り当てるかは意味判断になる。最初の書式へ寄せず、DRAFTを止める。
            $runStyles = New-Object Collections.Generic.List[string]
            foreach ($textNode in @($p.SelectNodes('.//w:t', $ns))) {
                $run = $textNode.SelectSingleNode('ancestor::w:r[1]', $ns)
                $rPr = if ($run) { $run.SelectSingleNode('./w:rPr', $ns) } else { $null }
                $runStyles.Add((Get-YakuWordRunStyleKey -RunProperties $rPr)) | Out-Null
            }
            if (@($runStyles.ToArray() | Select-Object -Unique).Count -gt 1) {
                $unsupported.Add(('段落内に複数の文字書式（段落 ' + $ordinal + '）')) | Out-Null
                $writeSupported=$false
            }
            $inTable = $null -ne $p.SelectSingleNode('ancestor::w:tc', $ns)
            if ($inTable) { $tableNo++; $kind='word_table'; $location='表内 ' + $tableNo }
            else {
                $bodyNo++; $kind='word_paragraph'
                $styleNode = $p.SelectSingleNode('./w:pPr/w:pStyle', $ns)
                $style = if ($styleNode) { [string]$styleNode.GetAttribute('val','http://schemas.openxmlformats.org/wordprocessingml/2006/main') } else { '' }
                $location = if ($style -match '^(?i:Heading|見出し)') { '見出し ' + $bodyNo } else { '本文 ' + $bodyNo }
            }
            $id = 'word:document.xml:p:' + $ordinal
            $blocks.Add([pscustomobject]@{
                Id=$id; Text=$text; Location=$location
                Meta=[pscustomobject]@{ Kind=$kind; Part='word/document.xml'; ParagraphOrdinal=$ordinal; WriteSupported=$writeSupported }
            }) | Out-Null
            if($writeSupported){$writeSupportedCount++}
        }
        foreach ($entry in @($package.Archive.Entries)) {
            if ($entry.FullName -notmatch '^word/(?:header\d+|footer\d+|footnotes|endnotes|comments)\.xml$') { continue }
            $story = Read-YakuWordXmlEntry -Archive $package.Archive -Name $entry.FullName
            $storyNs = New-YakuWordNamespaceManager -Document $story
            $storyText = @($story.SelectNodes('//w:t', $storyNs) | ForEach-Object { [string]$_.InnerText }) -join ''
            if (-not [string]::IsNullOrWhiteSpace($storyText)) {
                $unsupported.Add(('元のファイルへ書き戻せない箇所があります: ' + $entry.FullName)) | Out-Null
                $storyOrdinal=0
                foreach($storyParagraph in @($story.SelectNodes('//w:p',$storyNs))){
                    $storyOrdinal++; $paragraphText=Get-YakuWordParagraphText -Paragraph $storyParagraph -Namespaces $storyNs
                    if([string]::IsNullOrWhiteSpace($paragraphText)){continue}
                    $storyKind=if($entry.FullName -match 'header'){'word_header'}elseif($entry.FullName -match 'footer'){'word_footer'}else{'word_story'}
                    # 画面の「場所」列にそのまま出る。word/footnotes.xml のような内部の名前だと、
                    # 利用者は自分がどこを訳しているのか分からなくなる。Wordの用語へ直す。
                    $storyLabel = switch -Regex ($entry.FullName) {
                        'footnotes' { '脚注'; break }
                        'endnotes'  { '文末脚注'; break }
                        'header'    { 'ヘッダー'; break }
                        'footer'    { 'フッター'; break }
                        'comments'  { 'コメント'; break }
                        default     { '本文以外'; break }
                    }
                    $blocks.Add([pscustomobject]@{
                        Id=('word:'+$entry.FullName+':p:'+$storyOrdinal);Text=$paragraphText;Location=($storyLabel+' '+$storyOrdinal)
                        Meta=[pscustomobject]@{Kind=$storyKind;Part=$entry.FullName;ParagraphOrdinal=$storyOrdinal;WriteSupported=$false}
                    })|Out-Null
                }
            }
        }
        return [pscustomobject]@{
            ContractVersion='word-adapter-v1'
            Blocks=@($blocks.ToArray())
            SupportedBlockCount=$writeSupportedCount
            TotalBlockCount=$blocks.Count
            UnsupportedCount=@($unsupported.ToArray() | Select-Object -Unique).Count
            UnsupportedReasons=@($unsupported.ToArray() | Select-Object -Unique)
            DraftStructureEligible=($unsupported.Count -eq 0)
            StructureHash=(Get-YakuWordStructureHash -Document $doc)
            EntryNames=@($package.Archive.Entries | ForEach-Object { [string]$_.FullName } | Sort-Object)
        }
    } finally { Close-YakuWordPackage -Package $package }
}

function Set-YakuWordParagraphTranslation {
    param([Parameter(Mandatory=$true)][Xml.XmlNode]$Paragraph, [Parameter(Mandatory=$true)]$Namespaces, [Parameter(Mandatory=$true)][string]$Text)
    $nodes = @($Paragraph.SelectNodes('.//w:t', $Namespaces))
    if ($nodes.Count -eq 0) { throw 'WORD_WRITE_TEXT_NODE_MISSING' }
    $nodes[0].InnerText = $Text
    if ($Text -match '^\s|\s$') { $nodes[0].SetAttribute('space','http://www.w3.org/XML/1998/namespace','preserve') }
    else { $nodes[0].RemoveAttribute('space','http://www.w3.org/XML/1998/namespace') }
    for ($i=1; $i -lt $nodes.Count; $i++) { $nodes[$i].InnerText = '' }
}

function Export-YakuWordDraft {
    param(
        [Parameter(Mandatory=$true)]$Project,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )
    $source = [string]$Project.Path
    $inventory = Get-YakuWordDocumentInventory -Path $source
    if (-not [bool]$inventory.DraftStructureEligible) { throw ('CAT_WORD_DRAFT_UNSUPPORTED_STRUCTURE: ' + (@($inventory.UnsupportedReasons) -join '; ')) }
    if ([string]$inventory.ContractVersion -ne 'word-adapter-v1') { throw 'CAT_WORD_ADAPTER_CONTRACT_UNSUPPORTED' }
    if ([string]$Project.WordInventory.StructureHash -ne [string]$inventory.StructureHash) { throw 'CAT_WORD_SOURCE_STRUCTURE_CHANGED' }
    $sourceBlocks = @($Project.Blocks); $currentBlocks=@($inventory.Blocks)
    if ($sourceBlocks.Count -ne $currentBlocks.Count) { throw 'CAT_WORD_SOURCE_BLOCK_COUNT_CHANGED' }
    $translations = @{}
    foreach ($s in @($Project.Segments)) {
        foreach ($id in @($s.BlockIds)) { $translations[[string]$id] = [string]$s.Translation }
    }
    for ($i=0; $i -lt $sourceBlocks.Count; $i++) {
        if ([string]$sourceBlocks[$i].Id -ne [string]$currentBlocks[$i].Id -or [string]$sourceBlocks[$i].Text -ne [string]$currentBlocks[$i].Text) {
            throw 'CAT_WORD_SOURCE_TEXT_CHANGED'
        }
    }
    $outDir = [IO.Path]::GetDirectoryName($OutputPath)
    if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { $null=New-Item -ItemType Directory -Path $outDir -Force }
    $temp = Join-Path $outDir ('.word-draft-' + [guid]::NewGuid().ToString('N') + '.docx')
    try {
        [IO.File]::Copy($source, $temp, $false)
        $package=$null
        try {
            $package=Open-YakuWordPackage -Path $temp -Mode Update
            $doc=Read-YakuWordXmlEntry -Archive $package.Archive -Name 'word/document.xml'
            $ns=New-YakuWordNamespaceManager -Document $doc
            $paragraphs=@($doc.SelectNodes('/w:document/w:body//w:p', $ns)); $ordinal=0; $written=0
            foreach ($p in $paragraphs) {
                $ordinal++; $id='word:document.xml:p:'+$ordinal
                if (-not $translations.ContainsKey($id)) { continue }
                Set-YakuWordParagraphTranslation -Paragraph $p -Namespaces $ns -Text ([string]$translations[$id]); $written++
            }
            $body=$doc.SelectSingleNode('/w:document/w:body',$ns)
            $marker=$doc.CreateElement('w','p','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
            $run=$doc.CreateElement('w','r','http://schemas.openxmlformats.org/wordprocessingml/2006/main'); $null=$marker.AppendChild($run)
            # 未確認のまま出せるようにしたので、何行が未確認かをファイル自身に書く。
            # 画面で見た人と、ファイルだけを受け取った人が同じことを知れるようにする。
            $unconfirmed = @($Project.Segments | Where-Object { [string]$_.State -ne 'reviewed' }).Count
            $markerText = 'DRAFT — YakuLingo（確認用）'
            if ($unconfirmed -gt 0) { $markerText = $markerText + ' 未確認 ' + $unconfirmed + ' 行を含む' }
            $textNode=$doc.CreateElement('w','t','http://schemas.openxmlformats.org/wordprocessingml/2006/main'); $textNode.InnerText=$markerText; $null=$run.AppendChild($textNode)
            $null=$body.InsertBefore($marker,$body.FirstChild)
            $entry=$package.Archive.GetEntry('word/document.xml'); $entry.Delete()
            $newEntry=$package.Archive.CreateEntry('word/document.xml',[IO.Compression.CompressionLevel]::Optimal)
            $writer=New-Object IO.StreamWriter($newEntry.Open(),(New-Object Text.UTF8Encoding($false)))
            try { $doc.Save($writer) } finally { $writer.Dispose() }
        } finally { Close-YakuWordPackage -Package $package }
        $verify=Get-YakuWordDocumentInventory -Path $temp
        if ([string]$verify.StructureHash -ne [string]$inventory.StructureHash) { throw 'CAT_WORD_DRAFT_ROUNDTRIP_STRUCTURE_FAILED' }
        if ((Compare-Object @($inventory.EntryNames) @($verify.EntryNames)).Count -ne 0) { throw 'CAT_WORD_DRAFT_PACKAGE_GRAPH_CHANGED' }
        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { throw 'CAT_WORD_DRAFT_OUTPUT_EXISTS' }
        [IO.File]::Move($temp,$OutputPath)
        return [pscustomobject]@{ PublishedPath=$OutputPath; WrittenCount=$written; SkippedCount=0 }
    } finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function New-YakuCatWordProject {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Settings,
        [ValidateSet('to_en','to_jp')][string]$Direction='to_en'
    )
    $inventory=Get-YakuWordDocumentInventory -Path $Path
    $segments=New-Object Collections.Generic.List[object]
    foreach ($b in @($inventory.Blocks)) {
        $segments.Add([pscustomobject]@{
            Text=[string]$b.Text; BlockIds=@([string]$b.Id); Cells=@(); Joined=$false
            Kind=[string]$b.Meta.Kind; Sheet=''; Location=[string]$b.Location
            Translation=''; Origin=''; Confirmed=$false
        }) | Out-Null
    }
    $warnings=@($inventory.UnsupportedReasons | ForEach-Object { 'WordのDRAFT出力対象外: ' + $_ })
    $project=[pscustomobject]@{
        Id=[guid]::NewGuid().ToString('N'); Path=$Path; FileName=[IO.Path]::GetFileName($Path)
        Direction=$Direction; Blocks=@($inventory.Blocks); Segments=@($segments.ToArray())
        Warnings=$warnings; Source='file'; DocumentFormat='docx'; WordInventory=$inventory
        CreatedAt=(Get-Date).ToString('s')
    }
    $null=Initialize-YakuCatProjectState -Project $project
    return $project
}
