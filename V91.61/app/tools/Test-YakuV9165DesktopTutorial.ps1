#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$checks = 0
$failures = New-Object System.Collections.Generic.List[string]

function Read-YakuTutorialContractFile {
    param([string]$RelativePath)
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($path)
}

function Check-YakuTutorialContract {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if ($Condition) { Write-Host ('PASS: ' + $Message) }
    else { Write-Host ('FAIL: ' + $Message) -ForegroundColor Red; $script:failures.Add($Message) | Out-Null }
}

$catHtml = Read-YakuTutorialContractFile 'www\cat.html'
$tutorialHtml = Read-YakuTutorialContractFile 'www\tutorial.html'
$tutorialJs = Read-YakuTutorialContractFile 'www\assets\tutorial.js'
$tutorialCss = Read-YakuTutorialContractFile 'www\assets\tutorial.css'
$server = Read-YakuTutorialContractFile 'src\Server.ps1'
$desktop = Read-YakuTutorialContractFile 'src\DesktopIntegration.ps1'

Check-YakuTutorialContract (-not [string]::IsNullOrWhiteSpace($catHtml)) 'www\cat.html exists'
Check-YakuTutorialContract (-not [string]::IsNullOrWhiteSpace($tutorialHtml) -and -not [string]::IsNullOrWhiteSpace($tutorialJs) -and -not [string]::IsNullOrWhiteSpace($tutorialCss)) 'legacy tutorial assets remain available as compatibility files'
Check-YakuTutorialContract (-not $catHtml.Contains('name="yaku-tour"') -and -not $catHtml.Contains('/assets/tour.js')) 'CAT no longer exposes the tour meta or tour script'
Check-YakuTutorialContract (-not ($catHtml -match 'href="/tutorial(?:#settings)?"') -and -not $catHtml.Contains('id="cat-help-links"')) 'start screen has no help/settings user-path links'
Check-YakuTutorialContract ($catHtml -match 'data-cat-view="__YAKU_VIEW__"') 'CAT keeps one initial-view template attribute'

Check-YakuTutorialContract ($server.Contains("if (`$method -eq 'GET' -and `$path -eq '/')") -and $server.Contains("Serve-YakuAppPage -Context `$Context -PageName 'cat.html'") -and -not $server.Contains('-StartTour')) 'root always serves CAT without the retired tour decision'
Check-YakuTutorialContract ($server.Contains('function Send-YakuRedirectResponse') -and $server.Contains("Send-YakuRedirectResponse -Context `$Context -Location '/cat'")) 'legacy /tutorial route redirects safely to CAT'
Check-YakuTutorialContract ($server.Contains("if (`$method -eq 'GET' -and `$path -eq '/tutorial')")) 'legacy /tutorial route remains explicitly handled'
Check-YakuTutorialContract (-not $server.Contains('Serve-YakuAppPage -Context $Context -PageName ''cat.html'' -StartTour')) 'server has no remaining root StartTour call'
Check-YakuTutorialContract ($server.Contains("'/api/desktop/preferences'") -and $desktop.Contains('function Set-YakuDesktopPreferences')) 'desktop preferences API implementation remains present'

function Invoke-YakuTutorialHttpRequest {
    param([Parameter(Mandatory=$true)][string]$Url)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    $response = $null
    try { $response = [System.Net.HttpWebResponse]$request.GetResponse() }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { $response = [System.Net.HttpWebResponse]$_.Exception.Response }
        else { throw }
    }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            Location = [string]$response.Headers['Location']
            Body = [string]$body
        }
    } finally { $response.Dispose() }
}

function Invoke-YakuRedirectFunctionFixture {
    $serverPath = Join-Path $root 'src\Server.ps1'
    $tokens = $null
    $parseErrors = $null
    $serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw 'Server.ps1 could not be parsed for the redirect fixture' }
    foreach ($name in @('Get-YakuContentSecurityPolicy', 'Send-YakuResponse', 'Send-YakuTextResponse', 'Send-YakuRedirectResponse', 'Invoke-YakuRoute')) {
        $definition = @($serverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
        if ($definition.Count -ne 1) { throw ('redirect fixture could not load production function: ' + $name) }
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }
    function Assert-YakuRequestBoundary { param($Request, [string]$Path, [string]$Method) }
    function Clear-YakuExpiredUploads {}
    $stream = New-Object System.IO.MemoryStream
    $response = [pscustomobject]@{
        RedirectLocation = ''
        StatusCode = 0
        ContentType = ''
        ContentLength64 = 0L
        Headers = @{}
        OutputStream = $stream
    }
    $request = [pscustomobject]@{ Url = [uri]'http://127.0.0.1:8765/tutorial'; HttpMethod = 'GET' }
    $context = [pscustomobject]@{ Request = $request; Response = $response }
    Invoke-YakuRoute -Context $context
    return [pscustomobject]@{
        Status = [int]$response.StatusCode
        Location = [string]$response.RedirectLocation
        Body = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
}

$redirectServer = $null
$redirectDataDir = Join-Path ([IO.Path]::GetTempPath()) ('yakulingo-v9165-redirect-' + [guid]::NewGuid().ToString('N'))
$redirectRuntimePath = Join-Path $redirectDataDir 'runtime\server.json'
$previousDataDir = [string]$env:YAKULINGO_DATA_DIR
$previousMock = [string]$env:YAKULINGO_MOCK
try {
    New-Item -ItemType Directory -Path $redirectDataDir -Force | Out-Null
    $env:YAKULINGO_DATA_DIR = $redirectDataDir
    $env:YAKULINGO_MOCK = '1'
    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = 'powershell.exe' }
    $port = Get-Random -Minimum 19000 -Maximum 40000
    $serverArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -NoBrowser -UseMockTranslator' -f (Join-Path $root 'Start-YakuLingo.ps1'), $port
    $stdoutPath = Join-Path $redirectDataDir 'server.stdout.log'
    $stderrPath = Join-Path $redirectDataDir 'server.stderr.log'
    $redirectServer = Start-Process -FilePath $powershell -ArgumentList $serverArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $deadline = (Get-Date).AddSeconds(25)
    $runtime = $null
    while ((Get-Date) -lt $deadline) {
        if ($redirectServer.HasExited) {
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { [IO.File]::ReadAllText($stdoutPath) } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { '' }
            throw ('real PowerShell server exited before redirect check: ' + $redirectServer.ExitCode + '; stdout=' + $stdout.Trim() + '; stderr=' + $stderr.Trim())
        }
        if (Test-Path -LiteralPath $redirectRuntimePath -PathType Leaf) {
            try { $runtime = Get-Content -LiteralPath $redirectRuntimePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $runtime = $null }
            if ($runtime -and [int]$runtime.pid -eq [int]$redirectServer.Id) { break }
        }
        Start-Sleep -Milliseconds 200
    }
    if ($null -eq $runtime) { throw 'real PowerShell server runtime information was not published' }
    $redirect = Invoke-YakuTutorialHttpRequest -Url (([string]$runtime.url).TrimEnd('/') + '/tutorial')
    Check-YakuTutorialContract ([int]$redirect.Status -eq 302 -and [string]$redirect.Location -eq '/cat' -and [string]$redirect.Body -eq 'Redirecting to /cat') 'real PowerShell GET /tutorial returns a 302 /cat redirect with a valid body'
} catch {
    $failure = [string]$_.Exception.Message
    if ($failure -match 'PlatformNotSupported|Operation is not supported on this platform') {
        Write-Host ('SKIP: HttpListener is unavailable in this PowerShell host; production-function fixture follows. ' + $failure) -ForegroundColor Yellow
    } else {
        Check-YakuTutorialContract $false ('real PowerShell GET /tutorial redirect path could not be exercised: ' + $failure)
    }
} finally {
    if ($redirectServer) {
        try { if (-not $redirectServer.HasExited) { $redirectServer.Kill() } } catch {}
        try { $redirectServer.WaitForExit(5000) | Out-Null } catch {}
        try { $redirectServer.Dispose() } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($previousDataDir)) { Remove-Item Env:YAKULINGO_DATA_DIR -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_DATA_DIR = $previousDataDir }
    if ([string]::IsNullOrWhiteSpace($previousMock)) { Remove-Item Env:YAKULINGO_MOCK -ErrorAction SilentlyContinue }
    else { $env:YAKULINGO_MOCK = $previousMock }
    if (Test-Path -LiteralPath $redirectDataDir -PathType Container) { Remove-Item -LiteralPath $redirectDataDir -Recurse -Force -ErrorAction SilentlyContinue }
}

try {
    $functionRedirect = Invoke-YakuRedirectFunctionFixture
    Check-YakuTutorialContract ([int]$functionRedirect.Status -eq 302 -and [string]$functionRedirect.Location -eq '/cat' -and [string]$functionRedirect.Body -eq 'Redirecting to /cat') 'production PowerShell /tutorial route emits 302, Location=/cat, and a valid body without an empty byte-array binding'
} catch {
    Check-YakuTutorialContract $false ('production PowerShell /tutorial route fixture failed: ' + $_.Exception.Message)
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source --check (Join-Path $root 'www\assets\cat.js')
    Check-YakuTutorialContract ($LASTEXITCODE -eq 0) 'CAT JavaScript parses with node --check'
} else {
    Check-YakuTutorialContract $false 'node is available for CAT JavaScript syntax verification'
}

if ($failures.Count -gt 0) {
    Write-Host ('Tutorial route regression failed: ' + $failures.Count + ' of ' + $checks + ' checks') -ForegroundColor Red
    exit 1
}
Write-Host ('Tutorial route regression passed: ' + $checks + ' checks') -ForegroundColor Green
