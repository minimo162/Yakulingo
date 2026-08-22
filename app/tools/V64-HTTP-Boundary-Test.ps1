[CmdletBinding()]
param([int]$Port = 18765)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataDir = Join-Path $env:USERPROFILE '.yakulingo-ps'
$runtimePath = Join-Path $dataDir 'runtime\server.json'
$server = $null

function Invoke-YakuBoundaryRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$ContentType = '',
        [string]$Body = '',
        [string]$HostOverride = ''
    )
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    if (-not [string]::IsNullOrWhiteSpace($HostOverride)) { $request.Host = $HostOverride }
    foreach ($name in $Headers.Keys) { $request.Headers[[string]$name] = [string]$Headers[$name] }
    if (-not [string]::IsNullOrWhiteSpace($ContentType)) { $request.ContentType = $ContentType }
    if ($Method -eq 'POST') {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    try { $response = [System.Net.HttpWebResponse]$request.GetResponse() }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { $response = [System.Net.HttpWebResponse]$_.Exception.Response }
        else { throw }
    }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ Status=[int]$response.StatusCode; Text=$text }
    } finally { $response.Dispose() }
}

function Assert-Status { param($Response, [int]$Expected, [string]$Name); if ([int]$Response.Status -ne $Expected) { throw "$Name expected $Expected, got $($Response.Status): $($Response.Text)" } }

try {
    $exe = Join-Path $PSHOME 'powershell.exe'
    if (!(Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $scriptPath = Join-Path $root 'Start-YakuLingo.ps1'
    $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -NoBrowser -UseMockTranslator' -f $scriptPath, $Port
    $server = Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(20)
    $info = $null
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) { throw "テストサーバーが終了しました。ExitCode=$($server.ExitCode)" }
        if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
            try { $info = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $info = $null }
            if ($info -and [int]$info.pid -eq [int]$server.Id) { break }
        }
        Start-Sleep -Milliseconds 200
    }
    if ($null -eq $info) { throw 'テストサーバーのruntime情報を取得できませんでした。' }
    $base = [string]$info.url

    $index = Invoke-YakuBoundaryRequest -Url $base
    Assert-Status $index 200 'index'
    $match = [regex]::Match($index.Text, '<meta name="yaku-session" content="([^"]+)"')
    if (-not $match.Success) { throw 'セッショントークンを取得できませんでした。' }
    $token = $match.Groups[1].Value
    $goodHeaders = @{ 'X-Yaku-Session'=$token; Origin=$base.TrimEnd('/'); 'Sec-Fetch-Site'='same-origin' }

    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/ready-state')) 403 'missing token'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/ready-state') -Headers @{ 'X-Yaku-Session'='wrong' }) 403 'wrong token'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/ready-state') -Headers @{ 'X-Yaku-Session'=$token } -HostOverride 'evil.example') 403 'wrong Host'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/ready-state') -Headers @{ 'X-Yaku-Session'=$token; Origin='https://evil.example' }) 403 'wrong Origin'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/ready-state') -Headers @{ 'X-Yaku-Session'=$token; 'Sec-Fetch-Site'='cross-site' }) 403 'cross-site fetch'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/ready-state') -Headers $goodHeaders) 200 'valid token'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'api/cancel-translation') -Method POST -Headers $goodHeaders -ContentType 'application/x-www-form-urlencoded' -Body 'job_id=x') 403 'simple form POST'
    Assert-Status (Invoke-YakuBoundaryRequest -Url ($base + 'shutdown') -Method POST -Headers $goodHeaders -ContentType 'application/json; charset=UTF-8' -Body '{}') 200 'valid shutdown'

    Write-Host 'V64 HTTP boundary tests passed: 8 cases.' -ForegroundColor Green
} finally {
    if ($server) {
        try { $server.WaitForExit(5000) | Out-Null } catch {}
        try { if (-not $server.HasExited) { $server.Kill() } } catch {}
        try { $server.Dispose() } catch {}
    }
}
