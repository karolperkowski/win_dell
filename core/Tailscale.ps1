#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Install and register Tailscale

.DESCRIPTION
    1. Installs Tailscale silently via winget.
    2. Starts tailscale up, captures the auth URL from its output in real-time.
    3. Generates a QR code PNG so the monitor can display it.
    4. Writes C:\ProgramData\WinDeploy\tailscale.json with the URL and QR path.
    5. Polls tailscale status until the machine is registered (or timeout).

    If config.Tailscale.AuthKey is set, uses --authkey instead of
    the interactive QR flow entirely.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'InstallTailscale',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'Winget.psm1')  -DisableNameChecking -Force
Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DEPLOY_ROOT   = 'C:\ProgramData\WinDeploy'
$TS_JSON       = Join-Path $DEPLOY_ROOT 'tailscale.json'
$TS_QR_PNG     = Join-Path $DEPLOY_ROOT 'tailscale_qr.png'
$TS_EXE        = 'C:\Program Files\Tailscale\tailscale.exe'
$TS_WINGET_ID  = 'Tailscale.Tailscale'
$TS_SERVICE    = 'Tailscale'

# Config defaults
$tsConfig      = if ($Config['Tailscale']) { $Config['Tailscale'] } else { @{} }
$authKey       = $tsConfig['AuthKey']        # Pre-auth key; skips QR if set
$qrTimeout     = if ($tsConfig['QrTimeoutMinutes']) { [int]$tsConfig['QrTimeoutMinutes'] } else { 30 }
$hostname      = $tsConfig['Hostname']       # Override machine hostname in Tailscale
$acceptRoutes  = if ($tsConfig['AcceptRoutes'] -eq $true) { '--accept-routes' } else { '' }
$acceptDns     = if ($tsConfig['AcceptDNS']    -eq $false) { '--accept-dns=false' } else { '' }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-TailscaleJson {
    param(
        [string]$AuthUrl     = '',
        [string]$QrPath      = '',
        [bool]  $Registered  = $false,
        [string]$MachineName = ''
    )
    $data = [ordered]@{
        AuthUrl     = $AuthUrl
        QrPath      = $QrPath
        Registered  = $Registered
        MachineName = $MachineName
        UpdatedAt   = (Get-Date -Format 'o')
    }
    $data | ConvertTo-Json | Set-Content -Path $TS_JSON -Encoding UTF8
}

function Write-NetworkSnapshot {
    <#
    Logs pre-install adapter/driver state so if the system freezes again we have
    evidence of what was present before WinTun was loaded.
    #>
    param([string]$Label)
    try {
        Write-LogInfo "--- Network snapshot ($Label) ---"
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Sort-Object ifIndex |
            ForEach-Object {
                Write-LogInfo ("  [{0}] {1} | {2} | {3}" -f $_.ifIndex, $_.Name, $_.InterfaceDescription, $_.Status)
            }
        $tun = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'Tailscale|Wintun' }
        if ($tun) {
            foreach ($d in $tun) {
                Write-LogInfo ("  PnP: {0} | Status: {1} | InstanceId: {2}" -f $d.FriendlyName, $d.Status, $d.InstanceId)
            }
        } else {
            Write-LogInfo '  PnP: no Tailscale/Wintun device present.'
        }
    } catch {
        Write-LogWarning "Network snapshot failed: $($_.Exception.Message)"
    }
}

function Wait-TailscaleDriver {
    <#
    After winget reports Tailscale installed, the MSI may still be running its
    child WinTun driver installer. Poll for the WinTun PnP device before
    touching the Tailscale service — this is the missing handshake that caused
    the 13:52 install to deadlock the network stack (Wait-TailscaleService was
    hammering SCM while the driver was still loading in kernel mode).
    #>
    param([int]$TimeoutSeconds = 180)
    Write-LogInfo "Waiting for Tailscale/WinTun driver to register (up to ${TimeoutSeconds}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $dev = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'Tailscale|Wintun' }
        if ($dev -and ($dev | Where-Object Status -eq 'OK')) {
            Write-LogSuccess "Tailscale driver ready: $($dev[0].FriendlyName)"
            return $true
        }
        Start-Sleep -Seconds 5
    }
    Write-LogWarning "WinTun/Tailscale PnP device did not register within ${TimeoutSeconds}s - proceeding anyway."
    return $false
}

function Install-TailscaleViaWinget {
    # --source winget pins to the community repo. The default msstore source
    # fails under SYSTEM with TLS cert pinning errors (exit 0x8A15005E),
    # observed 2026-05-16. Use Invoke-WingetCli so winget's output is captured
    # rather than leaking into the script's return pipeline (which previously
    # caused "Stage returned invalid result (type: Object[])" in the orchestrator).
    $result = Invoke-WingetCli -Description "Install Tailscale ($TS_WINGET_ID)" -ArgList @(
        'install',
        '--id', $TS_WINGET_ID,
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if (-not $result.Success) {
        throw "Tailscale winget install failed (exit $($result.ExitCode) -- $($result.Meaning))."
    }
}

function Wait-TailscaleService {
    <#
    Wait for the Tailscale Windows service to enter the Running state.

    IMPORTANT: this function must NOT call Start-Service in a tight loop. During
    the original post-install window the WinTun driver is still registering in
    kernel mode, and repeated SCM start requests against a half-loaded network
    filter driver will deadlock the network stack and freeze the desktop
    (observed 2026-04-10: system-wide hang requiring force power-off). Let SCM
    start the service once, then only poll Status.
    #>
    Write-LogInfo "Waiting for $TS_SERVICE service..."
    $svc = Get-Service -Name $TS_SERVICE -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "$TS_SERVICE service not registered after install."
    }

    # Single, non-blocking attempt to kick the service if it's idle. We do NOT
    # repeat this in the poll loop.
    if ($svc.Status -ne 'Running') {
        try {
            Start-Service -Name $TS_SERVICE -ErrorAction Stop
        } catch {
            Write-LogWarning "Initial Start-Service failed: $($_.Exception.Message) - will poll Status only."
        }
    }

    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $TS_SERVICE -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-LogSuccess "$TS_SERVICE service is running."
            return
        }
        Start-Sleep -Seconds 3
    }

    # Diagnostic dump before throwing — next time we want evidence, not silence
    Write-LogError "$TS_SERVICE service did not start within 120 seconds."
    try {
        $s = Get-Service -Name $TS_SERVICE -ErrorAction SilentlyContinue
        if ($s) { Write-LogError ("  Service status: {0} / StartType: {1}" -f $s.Status, $s.StartType) }
    } catch { }
    throw "$TS_SERVICE service did not start within 120 seconds."
}

function Test-TailscaleRegistered {
    try {
        $json = & $TS_EXE status --json 2>$null | ConvertFrom-Json
        return ($json.BackendState -eq 'Running')
    } catch { return $false }
}

function Get-TailscaleMachineName {
    try {
        $json = & $TS_EXE status --json 2>$null | ConvertFrom-Json
        return $json.Self.HostName
    } catch { return '' }
}

function New-QRCodePng {
    param([string]$Data, [string]$OutputPath)

    # Attempt 1: PSGallery QRCodeGenerator module
    try {
        if (-not (Get-Module -ListAvailable -Name 'QRCodeGenerator')) {
            Write-LogInfo 'Installing QRCodeGenerator module from PSGallery...'
            Install-Module -Name 'QRCodeGenerator' -Force -Scope AllUsers `
                -SkipPublisherCheck -ErrorAction Stop
        }
        Import-Module QRCodeGenerator -Force -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing

        Write-LogInfo 'Generating QR code via QRCodeGenerator module...'
        $bmp = New-QRCodeURI -URI $Data -Width 10
        $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-LogSuccess "QR PNG saved: $OutputPath"
        return $true
    } catch {
        Write-LogWarning "QRCodeGenerator module attempt failed: $($_.Exception.Message)"
    }

    # Attempt 2: QRCoder NuGet package
    try {
        Write-LogInfo 'Trying QRCoder NuGet package fallback...'
        $nupkg  = Join-Path $env:TEMP 'QRCoder.nupkg'
        $extract = Join-Path $env:TEMP 'QRCoder_pkg'

        Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/QRCoder/1.4.3' `
            -OutFile $nupkg -UseBasicParsing -ErrorAction Stop

        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
        Expand-Archive -Path $nupkg -DestinationPath $extract -Force

        # Pick the highest .NET version DLL available
        $dll = Get-ChildItem "$extract\lib" -Filter 'QRCoder.dll' -Recurse |
               Sort-Object { $_.Directory.Name } | Select-Object -Last 1
        if (-not $dll) { throw 'QRCoder.dll not found in NuGet package.' }

        [System.Reflection.Assembly]::LoadFrom($dll.FullName) | Out-Null

        $gen    = [QRCoder.QRCodeGenerator]::new()
        $qrData = $gen.CreateQrCode($Data, [QRCoder.QRCodeGenerator+ECCLevel]::Q)
        $qrCode = [QRCoder.PngByteQRCode]::new($qrData)
        $bytes  = $qrCode.GetGraphic(10)
        [System.IO.File]::WriteAllBytes($OutputPath, $bytes)
        Write-LogSuccess "QR PNG saved via QRCoder NuGet: $OutputPath"
        return $true
    } catch {
        Write-LogWarning "QRCoder NuGet attempt failed: $($_.Exception.Message)"
    }

    Write-LogWarning 'QR code generation failed on all attempts. Monitor will show URL as text only.'
    # Write auth URL to a plaintext file so the user can easily copy-paste it
    $urlFile = Join-Path (Split-Path $OutputPath -Parent) 'tailscale_auth_url.txt'
    try {
        [System.IO.File]::WriteAllText($urlFile, "Open this URL to register Tailscale:`r`n$Data`r`n", [System.Text.Encoding]::UTF8)
        Write-LogInfo "Auth URL saved to: $urlFile"
    } catch {
        Write-LogWarning "Could not write auth URL file: $($_.Exception.Message)"
    }
    return $false
}

function Start-TailscaleUp {
    <#
    Runs 'tailscale up' as a background Process, captures output in real-time
    via async event handlers, and returns the auth URL as soon as it appears.
    The process is left running (it blocks until authenticated).
    Returns the Process object and the auth URL.
    #>
    param([string]$ExtraArgs = '')

    $psi = [System.Diagnostics.ProcessStartInfo]@{
        FileName               = $TS_EXE
        Arguments              = "up $ExtraArgs".Trim()
        RedirectStandardOutput = $true
        RedirectStandardError  = $true
        UseShellExecute        = $false
        CreateNoWindow         = $true
    }

    $script:capturedAuthUrl = $null
    $outputBuffer = [System.Collections.Generic.List[string]]::new()

    $handler = {
        param($s, $e)
        if ([string]::IsNullOrWhiteSpace($e.Data)) { return }
        $outputBuffer.Add($e.Data)
        $match = [regex]::Match($e.Data, 'https://login\.tailscale\.com/\S+')
        if ($match.Success) {
            $script:capturedAuthUrl = $match.Value.TrimEnd('.')
        }
    }

    $proc = [System.Diagnostics.Process]@{ StartInfo = $psi }
    $proc.add_OutputDataReceived($handler)
    $proc.add_ErrorDataReceived($handler)
    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    return $proc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-LogInfo "Stage '$StageName' starting."

    # ── Check if already registered ──
    if (Test-Path $TS_EXE) {
        if (Test-TailscaleRegistered) {
            $name = Get-TailscaleMachineName
            Write-LogSuccess "Tailscale already registered as '$name'. Skipping."
            Write-TailscaleJson -Registered $true -MachineName $name
            Close-Logger -FinalStatus 'SUCCESS'
            return @{ Status = 'Complete'; Message = "Tailscale already registered: $name" }
        }
        Write-LogInfo 'Tailscale installed but not registered - proceeding to auth.'
    } else {
        # ── Install ──
        Write-NetworkSnapshot -Label 'pre-install'
        Install-TailscaleViaWinget
        # Wait for the WinTun kernel driver before touching the service. Skipping
        # this step is what froze the system on 2026-04-10.
        $null = Wait-TailscaleDriver -TimeoutSeconds 180
        Write-NetworkSnapshot -Label 'post-install'
    }

    Wait-TailscaleService

    # Gate: confirm the LocalAPI actually responds before running `tailscale up`.
    # If tailscaled can't answer a status query, the auth flow will hang with no
    # output and we'd block on the URL-wait loop for 60s for nothing.
    Write-LogInfo 'Verifying Tailscale backend responsiveness...'
    $backendDeadline = (Get-Date).AddSeconds(60)
    $backendReady    = $false
    while ((Get-Date) -lt $backendDeadline) {
        try {
            $null = & $TS_EXE status --json 2>$null
            if ($LASTEXITCODE -eq 0) { $backendReady = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $backendReady) {
        throw 'Tailscale backend did not respond to status query - install may be incomplete.'
    }
    Write-LogSuccess 'Tailscale backend is responsive.'

    # ── Auth: pre-auth key path ──
    if ($authKey) {
        Write-LogInfo 'AuthKey provided - authenticating with pre-auth key (no QR needed)...'
        $extraArgs = "--authkey=$authKey $acceptRoutes $acceptDns".Trim()
        if ($hostname) { $extraArgs += " --hostname=$hostname" }

        $proc = Start-TailscaleUp -ExtraArgs $extraArgs
        $proc.WaitForExit(30000) | Out-Null

        if (-not (Test-TailscaleRegistered)) {
            throw 'Tailscale auth key authentication failed. Check the key is valid and not expired.'
        }

        $name = Get-TailscaleMachineName
        Write-TailscaleJson -Registered $true -MachineName $name
        Write-LogSuccess "Tailscale registered via auth key as '$name'."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "Tailscale registered: $name" }
    }

    # ── Auth: interactive QR flow ──
    Write-LogInfo "Starting 'tailscale up' - waiting for auth URL..."
    $extraArgs = "$acceptRoutes $acceptDns".Trim()
    if ($hostname) { $extraArgs += " --hostname=$hostname" }

    $tsProc = Start-TailscaleUp -ExtraArgs $extraArgs

    # Wait for the auth URL to appear in output (up to 60s)
    $urlDeadline = (Get-Date).AddSeconds(60)
    while (-not $script:capturedAuthUrl -and (Get-Date) -lt $urlDeadline) {
        Start-Sleep -Seconds 1
    }

    if (-not $script:capturedAuthUrl) {
        $tsProc.Kill()
        throw 'Timed out waiting for Tailscale auth URL. Check Tailscale service logs.'
    }

    Write-LogSuccess "Auth URL captured: $($script:capturedAuthUrl)"

    # ── Generate QR ──
    $qrGenerated = New-QRCodePng -Data $script:capturedAuthUrl -OutputPath $TS_QR_PNG

    # ── Write tailscale.json so monitor can display it immediately ──
    $qrPath = if ($qrGenerated) { $TS_QR_PNG } else { '' }
    Write-TailscaleJson `
        -AuthUrl    $script:capturedAuthUrl `
        -QrPath     $qrPath `
        -Registered $false

    Write-LogInfo "Waiting for QR scan... (timeout: $qrTimeout minutes)"

    # ── Poll for registration ──
    $regDeadline = (Get-Date).AddMinutes($qrTimeout)
    $registered  = $false

    while ((Get-Date) -lt $regDeadline) {
        if (Test-TailscaleRegistered) {
            $registered = $true
            break
        }
        Start-Sleep -Seconds 5
    }

    # Clean up tailscale up process if still running
    if (-not $tsProc.HasExited) {
        $tsProc.Kill()
    }

    if (-not $registered) {
        # Update JSON to reflect timeout but don't hard-fail
        # Operator can re-run stage manually
        Write-LogWarning "QR registration timed out after $qrTimeout minutes."
        Close-Logger -FinalStatus 'FAILED'
        return @{
            Status  = 'Failed'
            Message = "Tailscale QR registration timed out after $qrTimeout min. Re-run this stage after scanning."
        }
    }

    $machineName = Get-TailscaleMachineName
    Write-TailscaleJson -AuthUrl $script:capturedAuthUrl -QrPath $TS_QR_PNG -Registered $true -MachineName $machineName
    Write-LogSuccess "Tailscale registered as '$machineName'."

    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = "Tailscale registered: $machineName" }

} catch {
    Write-LogError "Tailscale stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
