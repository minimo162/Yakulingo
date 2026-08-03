<#
.SYNOPSIS
  Ask the local YakuLingo server to stop.
#>
[CmdletBinding()]
param([int]$Port = 0)

$ErrorActionPreference = 'Continue'
$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $toolsRoot
. (Join-Path $appRoot 'src\Paths.ps1')
. (Join-Path $appRoot 'src\Runtime.ps1')

# Prefer an identity-checked local process stop. This does not expose a shutdown
# credential on disk and cannot terminate a PID that has been reused.
try {
    $runtimePath = Join-Path (Get-YakuSubDir 'runtime') 'server.json'
    if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $serverPid = [int]$runtime.pid
        $started = [string]$runtime.process_started_at
        if (Test-YakuProcessIdentity -Id $serverPid -StartTimeUtc $started) {
            Stop-Process -Id $serverPid -ErrorAction Stop
            Write-Host "YakuLingo server stopped. PID=$serverPid" -ForegroundColor Green
            exit 0
        }
    }
} catch { Write-Warning "YakuLingo server could not be stopped safely: $($_.Exception.Message)" }

$urls = New-Object System.Collections.Generic.List[string]
try {
    $runtimePath = Join-Path (Get-YakuSubDir 'runtime') 'server.json'
    if (Test-Path -LiteralPath $runtimePath) {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runtime.url) { $urls.Add(([string]$runtime.url).TrimEnd('/') + '/shutdown') | Out-Null }
    }
} catch {}

if ($Port -gt 0) {
    $urls.Add("http://127.0.0.1:$Port/shutdown") | Out-Null
} else {
    for ($p = 8765; $p -le 8795; $p++) { $urls.Add("http://127.0.0.1:$p/shutdown") | Out-Null }
}

$tried = @{}
foreach ($url in $urls) {
    if ($tried.ContainsKey($url)) { continue }
    $tried[$url] = $true
    try {
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri $url -ContentType 'application/json' -Body '{}' -TimeoutSec 2 | Out-Null
        Write-Host "Shutdown request sent: $url" -ForegroundColor Green
        exit 0
    } catch {}
}

Write-Warning '起動中のYakuLingoサーバーを見つけられませんでした。'
