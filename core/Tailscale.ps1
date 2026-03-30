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

function Install-TailscaleViaWinget {
    # Resolve winget path - not on PATH when running as SYSTEM
    $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        # Search WindowsApps for the winget executable
        $wingetPath = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue |
                      Sort-Object { $_.Directory.Name } -Descending | Select-Object -First 1
        if ($wingetPath) {
            Write-LogInfo "winget found at: $($wingetPath.FullName)"
            $wingetExe = $wingetPath.FullName
        } else {
            throw 'winget not found. winget ships with App Installer from the Microsoft Store.'
        }
    } else {
        $wingetExe = 'winget.exe'
    }

    Write-LogInfo "Installing Tailscale via winget ($TS_WINGET_ID)..."
    & $wingetExe install `
        --id $TS_WINGET_ID `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity `
        2>&1

    if ($LASTEXITCODE -in @(0, -1978335189)) {
        # 0 = success, -1978335189 (0x8A150011) = already installed
        Write-LogSuccess "Tailscale installed via winget (exit $LASTEXITCODE)."
    } else {
        throw "Tailscale winget install failed (exit $LASTEXITCODE)."
    }
}

function Wait-TailscaleService {
    Write-LogInfo "Waiting for $TS_SERVICE service..."
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $TS_SERVICE -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-LogSuccess "$TS_SERVICE service is running."
            return
        }
        if ($svc -and $svc.Status -ne 'Running') {
            Start-Service -Name $TS_SERVICE -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }
    throw "$TS_SERVICE service did not start within 60 seconds."
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
        Install-TailscaleViaWinget
    }

    Wait-TailscaleService

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
