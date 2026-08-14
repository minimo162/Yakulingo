<# Manual integration check: opens a real workbook in Excel and exports a PDF. #>
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $root 'src') 'SrcModules.ps1')
foreach($name in $script:YakuSrcModuleFiles){if($name -eq 'DesktopIntegration.ps1'){continue};. (Join-Path (Join-Path $root 'src') $name)}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('yaku-real-render-'+[guid]::NewGuid().ToString('N').Substring(0,8));$null=New-Item -ItemType Directory -Path $temp -Force
$oldData=$env:YAKULINGO_DATA_DIR;$env:YAKULINGO_DATA_DIR=Join-Path $temp 'data'
try{
  $settings=Read-YakuSettings -Root $root
  $fixture=(Resolve-Path (Join-Path $root 'tools/regression/V91.38_file数値前処理ミニブック.xlsx')).Path
  $project=New-YakuCatProject -Root $root -Path $fixture -Settings $settings -Direction to_en -Register:$false
  for($i=0;$i -lt @($project.Segments).Count;$i++){
    $segment=@($project.Segments)[$i];if([string]::IsNullOrWhiteSpace([string]$segment.Text)){continue}
    # この試験の対象はExcel/PDF経路であり翻訳品質ではない。原文の数字・通貨を
    # 変えずに仮の掲載文を置き、QC dependency fieldsだけを現在値へ固定する。
    $segment.Translation=[string]$segment.Text;$segment.Origin='manual';$segment.State='reviewed'
    $null=Invoke-YakuCatSegmentValidation -Project $project -Segment $segment
    $segment.QcStatus='passed';$segment.QcFindings=@();$segment.Confirmed=$true
  }
  $project=Commit-YakuNewCatProject -Project $project;$render=New-YakuCatSourceFaithfulRender -Project $project -Settings $settings
  if(-not (Test-Path -LiteralPath ([string]$render.PdfPath) -PathType Leaf)){throw 'ACTUAL_RENDER_PDF_MISSING'}
  $sourceResolved=Resolve-YakuCatRenderPdf -ProjectId ([string]$project.Id) -RenderId ([string]$render.RenderId) -Artifact source
  if(-not (Test-Path -LiteralPath ([string]$sourceResolved.Path) -PathType Leaf)){throw 'ACTUAL_RENDER_SOURCE_PDF_MISSING'}
  if((Get-FileHash -LiteralPath ([string]$sourceResolved.Path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$render.Manifest.source_pdf_sha256){throw 'ACTUAL_RENDER_SOURCE_PDF_HASH_MISMATCH'}
  [pscustomobject]@{ok=$true;segments=@($project.Segments).Count;render_id=$render.RenderId;pdf=$render.PdfPath;pdf_sha256=$render.Manifest.canonical_pdf_sha256;source_pdf=$sourceResolved.Path;source_pdf_sha256=$render.Manifest.source_pdf_sha256;print=$render.Manifest.print_conformance_status;writeback=$render.Manifest.writeback_completeness.status}|ConvertTo-Json -Compress
}finally{
  if($null -eq $oldData){Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue}else{$env:YAKULINGO_DATA_DIR=$oldData}
}
