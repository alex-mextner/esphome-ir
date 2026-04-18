#Requires -Version 5.0
<#
.SYNOPSIS
    HTTP listener that opens/closes a Chrome/Edge app-window showing guide.html.
    Reads config from C:\guide-listener\secret.txt and listens on http://+:<port>/.
    Runs as a long-running service (Task Scheduler or manual).
.NOTES
    Prerequisites (run once as Administrator):
        netsh http add urlacl url=http://+:8765/ user=Everyone
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Config ──────────────────────────────────────────────────────────────────
$Port        = 8765
$BaseDir     = 'C:\guide-listener'
$HtmlFile    = "$BaseDir\guide.html"
$SecretFile  = "$BaseDir\secret.txt"
$ProfileDir  = "$env:TEMP\guide_profile"
$AppUrl      = "file:///C:/guide-listener/guide.html"

# ── Load secret ─────────────────────────────────────────────────────────────
if (-not (Test-Path $SecretFile)) {
    throw "Secret file not found: $SecretFile"
}
$Secret = (Get-Content $SecretFile -Raw).Trim()
if ($Secret.Length -eq 0) {
    throw "Secret file is empty: $SecretFile"
}

# ── Find browser executable ──────────────────────────────────────────────────
$BrowserCandidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)

$BrowserExe = $null
foreach ($candidate in $BrowserCandidates) {
    if (Test-Path $candidate) {
        $BrowserExe = $candidate
        break
    }
}

if ($null -eq $BrowserExe) {
    throw "No Chrome or Edge installation found. Checked:`n$($BrowserCandidates -join "`n")"
}
Write-Host "[guide-listener] Using browser: $BrowserExe"

# ── Helper: send HTTP response ───────────────────────────────────────────────
function Send-Response {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$Body = ''
    )
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'text/plain; charset=utf-8'
    if ($Body.Length -gt 0) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $Response.ContentLength64 = 0
    }
    $Response.OutputStream.Close()
}

# ── Handler: POST /open ──────────────────────────────────────────────────────
function Invoke-Open {
    param([System.Net.HttpListenerResponse]$Response)

    $args = @(
        "--user-data-dir=$ProfileDir",
        '--new-window',
        "--app=$AppUrl"
    )
    Start-Process -FilePath $BrowserExe -ArgumentList $args
    Write-Host "[guide-listener] /open — launched browser"
    Send-Response -Response $Response -StatusCode 200 -Body 'opened'
}

# ── Handler: POST /close ─────────────────────────────────────────────────────
function Invoke-Close {
    param([System.Net.HttpListenerResponse]$Response)

    # Normalise the profile dir path for comparison (forward-slash variant used in cmdline)
    $ProfileDirFwd = $ProfileDir.Replace('\', '/')

    $browserNames = @('chrome', 'msedge')
    $killed = 0

    foreach ($procName in $browserNames) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($null -eq $procs) { continue }

        foreach ($proc in $procs) {
            try {
                $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
                if ($null -eq $cimProc) { continue }

                $cmdLine = $cimProc.CommandLine
                if ($null -eq $cmdLine) { continue }

                # Match either backslash or forward-slash variant of profile dir
                if ($cmdLine -like "*$ProfileDir*" -or $cmdLine -like "*$ProfileDirFwd*") {
                    Write-Host "[guide-listener] /close — killing PID $($proc.Id) ($procName)"
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    $killed++
                }
            } catch {
                Write-Host "[guide-listener] /close — error inspecting PID $($proc.Id): $_"
            }
        }
    }

    Write-Host "[guide-listener] /close — killed $killed process(es)"
    Send-Response -Response $Response -StatusCode 200 -Body "closed $killed process(es)"
}

# ── Start listener ────────────────────────────────────────────────────────────
$Prefix   = "http://+:$Port/"
$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)

try {
    $Listener.Start()
} catch {
    Write-Error "Failed to start HttpListener on $Prefix. Did you run: netsh http add urlacl url=$Prefix user=Everyone ?`n$_"
    exit 1
}

Write-Host "[guide-listener] Listening on $Prefix"
Write-Host "[guide-listener] Browser : $BrowserExe"
Write-Host "[guide-listener] HTML    : $HtmlFile"
Write-Host "[guide-listener] Profile : $ProfileDir"

# ── Request loop ──────────────────────────────────────────────────────────────
while ($Listener.IsListening) {
    $context = $null
    try {
        $context = $Listener.GetContext()
    } catch {
        if (-not $Listener.IsListening) { break }
        Write-Host "[guide-listener] GetContext error: $_"
        continue
    }

    $req  = $context.Request
    $resp = $context.Response

    try {
        # ── Auth ─────────────────────────────────────────────────────────────
        $token = $req.Headers['X-Guide-Token']
        if ($token -ne $Secret) {
            Write-Host "[guide-listener] 403 from $($req.RemoteEndPoint) — bad/missing token"
            Send-Response -Response $resp -StatusCode 403 -Body 'Forbidden'
            continue
        }

        $method = $req.HttpMethod.ToUpper()
        $path   = $req.Url.AbsolutePath.TrimEnd('/')

        Write-Host "[guide-listener] $method $path from $($req.RemoteEndPoint)"

        # ── Routing ───────────────────────────────────────────────────────────
        if ($method -eq 'POST' -and $path -eq '/ping') {
            Send-Response -Response $resp -StatusCode 200 -Body 'pong'

        } elseif ($method -eq 'POST' -and $path -eq '/open') {
            Invoke-Open -Response $resp

        } elseif ($method -eq 'POST' -and $path -eq '/close') {
            Invoke-Close -Response $resp

        } else {
            Send-Response -Response $resp -StatusCode 404 -Body 'Not found'
        }

    } catch {
        Write-Host "[guide-listener] 500 error handling $($req.Url): $_"
        try {
            Send-Response -Response $resp -StatusCode 500 -Body 'Internal error'
        } catch {
            # Response might already be partially written; ignore.
        }
    }
}

$Listener.Stop()
Write-Host "[guide-listener] Stopped."
