#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy one-liner installer.

.DESCRIPTION
    Designed to be run via:

        irm "https://raw.githubusercontent.com/karolperkowski/win_dell/main/install.ps1" | iex

    Because irm|iex provides no file context ($PSScriptRoot is empty and the
    script has no path on disk), this script:

        1. Saves itself to a temp file so re-elevation can reference a real path.
        2. Re-launches that temp file as Administrator if not already elevated.
        3. Downloads the full repo from GitHub as a ZIP (no git required).
        4. Extracts to C:\ProgramData\WinDeploy\repo\.
        5. Calls bootstrap.ps1 -NoElevation (already admin at this point).

    After bootstrap.ps1 finishes its first run, the scheduled task takes over
    and this script is never needed again.

.NOTES
    Requires: PowerShell 5.1+, internet access, Windows 10/11
    Repo    : https://github.com/karolperkowski/win_dell
#>

[CmdletBinding()]
param(
    # Branch or tag to download. Change to a release tag for production.
    [string]$Branch = 'main',

    # Override destination. Defaults to the stable deploy root.
    [string]$InstallRoot = 'C:\ProgramData\WinDeploy',

    # Internal flag set when the script re-launches itself elevated.
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$REPO_OWNER   = 'karolperkowski'
$REPO_NAME    = 'win_dell'
$REPO_ZIP_URL = "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$Branch.zip"
$REPO_DIR     = Join-Path $InstallRoot 'repo'
$TEMP_SCRIPT  = Join-Path $env:TEMP 'windeploy_install.ps1'

# ---------------------------------------------------------------------------
# Helper: simple console logger (Logging.psm1 not loaded yet at this stage)
# ---------------------------------------------------------------------------
function Write-InstallLog {
    param([string]$Message, [string]$Level = 'INFO')
    $colours = @{ INFO='Cyan'; OK='Green'; WARN='Yellow'; ERROR='Red' }
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts][$Level] $Message" -ForegroundColor ($colours[$Level] ?? 'White')
}

# ---------------------------------------------------------------------------
# Step 1: Elevation guard
#
# irm|iex gives us no $PSCommandPath, so we can't just re-launch $PSCommandPath.
# Strategy: write this script to a known temp path, then relaunch that file.
# ---------------------------------------------------------------------------
function Test-AdminPrivilege {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedRelaunch {
    Write-InstallLog 'Not running as Administrator.' WARN
    Write-InstallLog 'Saving installer to temp path and re-launching elevated...' INFO

    # Download the script content again so the elevated process has the full
    # source - $MyInvocation.ScriptName is empty in irm|iex context.
    $scriptContent = (Invoke-RestMethod `
        -Uri "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$Branch/install.ps1" `
        -UseBasicParsing)

    $scriptContent | Set-Content -Path $TEMP_SCRIPT -Encoding UTF8

    $argList = "-ExecutionPolicy Bypass -File `"$TEMP_SCRIPT`" -Branch `"$Branch`" -InstallRoot `"$InstallRoot`" -Elevated"
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    Write-InstallLog 'Elevated process launched. This window can be closed.' OK
    exit 0
}

if (-not (Test-AdminPrivilege)) {
    if (-not $Elevated) {
        Invoke-ElevatedRelaunch   # does not return
    } else {
        # Already re-launched but still not admin - hard failure
        Write-InstallLog 'Re-launched elevated but still not Administrator. Aborting.' ERROR
        exit 1
    }
}

Write-InstallLog 'Running as Administrator.' OK

# ---------------------------------------------------------------------------
# Step 2: Enforce TLS 1.2 for all web requests (required for GitHub)
# ---------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Step 3: Create install root
# ---------------------------------------------------------------------------
foreach ($dir in @($InstallRoot, $REPO_DIR)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-InstallLog "Created: $dir"
    }
}

# ---------------------------------------------------------------------------
# Step 4: Download and extract the repo ZIP
# ---------------------------------------------------------------------------
function Install-RepoFromGitHub {
    param([string]$ZipUrl, [string]$DestDir)

    $zipPath = Join-Path $env:TEMP "${REPO_NAME}_${Branch}.zip"

    Write-InstallLog "Downloading repo ZIP: $ZipUrl"
    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        Write-InstallLog "Download complete: $zipPath" OK
    } catch {
        throw "GitHub download failed: $($_.Exception.Message). " +
              "Check network connectivity and that the branch '$Branch' exists."
    }

    Write-InstallLog "Extracting to: $DestDir"

    # Clean out any previous extraction to keep the copy fresh
    if (Test-Path $DestDir) {
        Remove-Item $DestDir -Recurse -Force
    }

    # Expand-Archive available in PS 5.0+
    $extractTemp = Join-Path $env:TEMP "${REPO_NAME}_extract"
    if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force }

    Expand-Archive -Path $zipPath -DestinationPath $extractTemp -Force

    # GitHub ZIPs contain a single top-level folder named <repo>-<branch>
    $innerFolder = Get-ChildItem -Path $extractTemp -Directory | Select-Object -First 1
    if (-not $innerFolder) {
        throw "ZIP extraction produced no top-level folder. Archive may be corrupt."
    }

    # Move the inner folder to the final destination
    Move-Item -Path $innerFolder.FullName -Destination $DestDir -Force

    # Clean up temp files
    Remove-Item $zipPath      -Force -ErrorAction SilentlyContinue
    Remove-Item $extractTemp  -Force -Recurse -ErrorAction SilentlyContinue

    Write-InstallLog "Repo extracted to: $DestDir" OK
}

# Only re-download if the repo isn't already present (supports re-runs)
$bootstrapPath = Join-Path $REPO_DIR 'bootstrap.ps1'
if (Test-Path $bootstrapPath) {
    Write-InstallLog 'Repo already present at destination - skipping download.' WARN
    Write-InstallLog "Delete '$REPO_DIR' and re-run to force a fresh download." INFO
} else {
    Install-RepoFromGitHub -ZipUrl $REPO_ZIP_URL -DestDir $REPO_DIR
}

# ---------------------------------------------------------------------------
# Step 5: Verify the repo looks sane before handing off
# ---------------------------------------------------------------------------
$requiredFiles = @(
    'bootstrap.ps1'
    'core\Orchestrator.ps1'
    'core\State.psm1'
    'core\Logging.psm1'
    'config\settings.json'
)

$missing = $requiredFiles | Where-Object {
    -not (Test-Path (Join-Path $REPO_DIR $_))
}

if ($missing.Count -gt 0) {
    Write-InstallLog 'Repo integrity check FAILED. Missing files:' ERROR
    $missing | ForEach-Object { Write-InstallLog "  - $_" ERROR }
    throw "Repo download appears incomplete. Re-run install.ps1 after deleting '$REPO_DIR'."
}
Write-InstallLog 'Repo integrity check passed.' OK

# ---------------------------------------------------------------------------
# Step 6: Hand off to bootstrap.ps1
#
# Pass -RepoRoot so bootstrap uses the freshly downloaded copy.
# Pass -NoElevation because we are already Administrator.
# ---------------------------------------------------------------------------
Write-InstallLog ''
Write-InstallLog '=================================================' OK
Write-InstallLog '  Handing off to WinDeploy bootstrap.ps1 ...' OK
Write-InstallLog '=================================================' OK
Write-InstallLog ''

& powershell.exe -NonInteractive -ExecutionPolicy Bypass `
    -File "$bootstrapPath" `
    -RepoRoot "$REPO_DIR" `
    -NoElevation

$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-InstallLog "bootstrap.ps1 exited with code $exitCode - check logs at $InstallRoot\Logs\" ERROR
    exit $exitCode
}

Write-InstallLog 'install.ps1 complete. Deployment is running.' OK
