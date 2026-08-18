<#
.SYNOPSIS
  Copilot target, CAT Word/Excel import, and null-cleanup regression checks.

.DESCRIPTION
  Exercises the same Get-YakuFileInfo gate used by /api/file-info and
  /api/cat/open with a real OOXML DOCX fixture and the checked-in XLSX fixture.
  The old null-method expression is also kept as a focused diagnostic so a
  future failure identifies the exact unguarded cleanup expression.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $toolsRoot
$script:Failures = 0

function Assert-YakuRegression {
  param([bool]$Condition, [string]$Message)
  if ($Condition) { Write-Host ('  ok   ' + $Message) -ForegroundColor Green }
  else { Write-Host ('  FAIL ' + $Message) -ForegroundColor Red; $script:Failures++ }
}

foreach ($name in @('Paths.ps1','Runtime.ps1','Settings.ps1','PromptBuilder.ps1','CopilotClient.ps1','Translation.ps1','FileProcessors.ps1','CatBatch.ps1','CatTranslation.ps1','CellSegments.ps1','CellAlign.ps1','WordAdapter.ps1','CatProject.ps1')) {
  . (Join-Path (Join-Path $root 'src') $name)
}

$settings = [pscustomobject]@{}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yaku-import-regression-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force

function New-YakuImportRegressionDocx {
  param([Parameter(Mandatory=$true)][string]$Path)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    $parts = [ordered]@{
      '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
      '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
      'word/document.xml' = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>売上について説明します。</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'
    }
    foreach ($name in $parts.Keys) {
      $entry = $zip.CreateEntry([string]$name, [IO.Compression.CompressionLevel]::Optimal)
      $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
      try { $writer.Write([string]$parts[$name]) } finally { $writer.Dispose() }
    }
  } finally { $zip.Dispose(); $stream.Dispose() }
}

try {
  Write-Host 'CASE 1: the real Word import gate reads a valid DOCX' -ForegroundColor Cyan
  $wordPath = Join-Path $tempRoot 'import.docx'
  New-YakuImportRegressionDocx -Path $wordPath
  $wordInventory = Get-YakuWordDocumentInventory -Path $wordPath
  $wordInfo = Get-YakuFileInfo -Path $wordPath -Settings $settings
  Assert-YakuRegression ($null -ne $wordInventory -and @($wordInventory.Blocks).Count -eq 1) 'DOCX inventory contains the fixture paragraph'
  Assert-YakuRegression ($null -ne $wordInfo -and [string]$wordInfo.Kind -eq 'word' -and [string]$wordInfo.Extension -eq '.docx') 'Get-YakuFileInfo accepts DOCX through the import gate'
  Assert-YakuRegression (@($wordInfo.Sheets).Count -eq 0 -and [int]$wordInfo.Rows -eq 1) 'DOCX metadata is non-null and reports its blocks'

  Write-Host 'CASE 2: the checked-in XLSX regression fixture reaches the same import gate' -ForegroundColor Cyan
  $xlsxPath = Join-Path $root 'tools/regression/V91.38_file数値前処理ミニブック.xlsx'
  Assert-YakuRegression (Test-Path -LiteralPath $xlsxPath -PathType Leaf) 'checked-in XLSX fixture exists'
  if (Test-Path -LiteralPath $xlsxPath -PathType Leaf) {
    $excelInfo = Get-YakuFileInfo -Path $xlsxPath -Settings $settings
    Assert-YakuRegression ($null -ne $excelInfo -and [string]$excelInfo.Kind -eq 'excel' -and [string]$excelInfo.Extension -eq '.xlsx') 'Get-YakuFileInfo accepts XLSX through the import gate'
    Assert-YakuRegression ($null -ne $excelInfo.Sheets -and @($excelInfo.Sheets).Count -gt 0) 'XLSX metadata contains non-null sheet information'
  }

  Write-Host 'CASE 3: diagnose the old null-method expression and keep real failures explicit' -ForegroundColor Cyan
  $nullDisposeError = $null
  $nullDisposeRecord = $null
  try {
    $archive = $null
    try { } finally { $archive.Dispose() }
  } catch {
    $nullDisposeRecord = $_
    $nullDisposeError = [string]$_.Exception.Message
  }
  $nullMethodId = if ($null -ne $nullDisposeRecord) { [string]$nullDisposeRecord.FullyQualifiedErrorId } else { '' }
  $nullMethodCategory = if ($null -ne $nullDisposeRecord) { [string]$nullDisposeRecord.CategoryInfo.Category } else { '' }
  $nullMethodType = if ($null -ne $nullDisposeRecord -and $null -ne $nullDisposeRecord.Exception) { [string]$nullDisposeRecord.Exception.GetType().FullName } else { '' }
  $nullMethodDetected = ($nullMethodId -match '(?i)InvokeMethodOnNull|MethodInvocation') -or
    ($nullMethodCategory -eq 'InvalidOperation' -and $nullMethodType -match '(?i)RuntimeException') -or
    ($nullDisposeError -match '(?i)null-valued|メソッドを呼び出せません')
  Assert-YakuRegression $nullMethodDetected ('old unguarded archive.Dispose expression reproduces the locale-independent null-method diagnostic (FQID=' + $nullMethodId + ', Category=' + $nullMethodCategory + ', Type=' + $nullMethodType + ')')
  $clientSource = [IO.File]::ReadAllText((Join-Path $root 'src/CopilotClient.ps1'))
  Assert-YakuRegression ($clientSource -match 'COPILOT_TARGET_LOCK_UNAVAILABLE' -and $clientSource -match 'Copilot target mutex unavailable') 'mutex creation failures are logged and rethrown'
  Assert-YakuRegression ($clientSource -notmatch '(?s)Get-YakuCopilotTargetMutex\s*\{.*catch\s*\{\s*return\s+\$null') 'Copilot target creation cannot fail open without a mutex'
  $processorsSource = [IO.File]::ReadAllText((Join-Path $root 'src/FileProcessors.ps1'))
  $tokens = $null; $parseErrors = $null
  $processorsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/FileProcessors.ps1'), [ref]$tokens, [ref]$parseErrors)
  $archiveDisposeCalls = @($processorsAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    [string]$node.Member.Value -eq 'Dispose' -and [string]$node.Expression.Extent.Text -eq '$archive'
  }, $true))
  $archiveDisposeTextCount = ([regex]::Matches($processorsSource, '\$archive\.Dispose\(\)')).Count
  Assert-YakuRegression ($null -eq $parseErrors -or @($parseErrors).Count -eq 0) 'FileProcessors parses before cleanup inspection'

  function Test-YakuArchiveDisposeHasNullGuard {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Language.InvokeMemberExpressionAst]$Call)

    $parent = $Call.Parent
    while ($null -ne $parent) {
      if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
        foreach ($clause in @($parent.Clauses)) {
          $condition = $clause.Item1
          $conditionText = ''
          if ($null -ne $condition) { $conditionText = [string]$condition.Extent.Text }
          if ($conditionText -match '(?i)\$null\s*-ne\s*\$archive' -or
              $conditionText -match '(?i)\$archive\s*-ne\s*\$null' -or
              $conditionText -match '(?i)^\s*\$archive\s*(?:-and|$)') {
            return $true
          }
        }
      }
      $parent = $parent.Parent
    }
    return $false
  }

  $archiveDisposeGuardResults = @($archiveDisposeCalls | ForEach-Object {
    $call = $_
    [pscustomobject]@{
      Extent = [string]$call.Extent.Text
      Guarded = [bool](Test-YakuArchiveDisposeHasNullGuard -Call $call)
    }
  })
  $unguardedArchiveDisposeCalls = @($archiveDisposeGuardResults | Where-Object { -not $_.Guarded })
  $unguardedArchiveDisposeText = (($unguardedArchiveDisposeCalls | ForEach-Object { $_.Extent }) -join ', ')
  Assert-YakuRegression (
    $archiveDisposeCalls.Count -eq $archiveDisposeTextCount -and
    $archiveDisposeCalls.Count -gt 0 -and
    $unguardedArchiveDisposeCalls.Count -eq 0
  ) ('each FileProcessors archive Dispose call is individually inside a null guard (calls=' + $archiveDisposeCalls.Count + ', unguarded=' + $unguardedArchiveDisposeText + ')')
  Assert-YakuRegression ($processorsSource -match 'FILE_PACKAGE_OPEN_FAILED') 'OpenXML open failures retain a specific error code'

  $badPath = Join-Path $tempRoot 'invalid.xlsx'
  [IO.File]::WriteAllBytes($badPath, [Text.Encoding]::ASCII.GetBytes('not an OpenXML package'))
  $badError = $null
  try { $null = Get-YakuFileInfo -Path $badPath -Settings $settings } catch { $badError = [string]$_.Exception.Message }
  Assert-YakuRegression ($badError -match 'FILE_PACKAGE_OPEN_FAILED' -and $badError -notmatch 'null-valued') 'malformed XLSX reports the package failure rather than a null method'
} finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failures -gt 0) { throw ('Copilot/import regression test failed. failures=' + $script:Failures) }
Write-Host 'Copilot/import regression test passed.' -ForegroundColor Green
