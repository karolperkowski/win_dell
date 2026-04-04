#Requires -Version 5.1
# Compatible: Windows PowerShell 5.1+ and PowerShell 7+
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
    # Branch or tag to download.
    [string]$Branch = 'main',

    # Override destination. Defaults to the stable deploy root.
    [string]$InstallRoot = 'C:\ProgramData\WinDeploy',

    # Update mode: pull fresh scripts from GitHub without re-running bootstrap.
    # State file and logs are preserved. Tasks are NOT re-registered.
    # Usage: irm "https://.../install.ps1" | iex  then choose update, OR
    #        pass -Update when re-launching the elevated temp file.
    [switch]$Update,

    # Internal flag set when the script re-launches itself elevated.
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'   # Prevent any cmdlet from prompting during unattended run

# Maximise the console window immediately so progress is easy to read.
# Works on the current window (irm|iex run) and on the elevated relaunch
# because we also pass -WindowStyle Maximized to Start-Process.
function Expand-ConsoleWindow {
    try {
        $sig = '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);' +
               '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
        Add-Type -MemberDefinition $sig -Name 'WinHelper' -Namespace 'WinDeploy' -ErrorAction Stop
        $hwnd = [WinDeploy.WinHelper]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [WinDeploy.WinHelper]::ShowWindow($hwnd, 3) | Out-Null  # SW_MAXIMIZE = 3
        }
    } catch { Write-Host "[Install] Window maximize failed (non-fatal): $($_.Exception.Message)" }
}

Expand-ConsoleWindow

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$REPO_OWNER    = 'karolperkowski'
$REPO_NAME     = 'win_dell'
$MANIFEST_URL  = "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/manifest.json"
$SIG_URL       = "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/manifest.sig"

# Public key fingerprint - paste your public key here after running docs/gpg-setup.md
# This is the ONLY value that must be updated when you rotate your GPG key.
# The private key never leaves your machine or GitHub Secrets.
$GPG_PUBLIC_KEY = @'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGnJsS8BEACnajQ2vpt/GQ4/f+o30/eUqCzXnVkBvV6a2pYz8zULonreYSEh
Fq6RRiOJPBnn81B7yX1rTtKeL13oN7u7FdZxWiQC8r1mOUuLjd5J6ozz8CNRKk4k
E9luLLaENGHbI8iXmMkSfsps7rKATT7IiBPd14F2oS6pn/1GN7meMI4HE1y56JfX
FFjEo5HUE8ZjU+0dqhNW0UJt4b5Us9AMu0D1VyTYICKFZm/M4XiBnQfWwc9wknfq
k2KIVCNkDEbOzQ1FQlBUDx6R98ptpF6d2pf80KDtpagelE5dp9QpfQOknD+51zEd
k7orOJAWTW+Fa8xElZ6g8AJonRgi+qcamNQ8UD8vRGafRrIzlAIOO+Sa/FN07m/I
0eZyzbokFW9dkXmNwSbcefDgBJ9nB6R786dwxiNWmyH62mWnDB6F3rTCzgX7fK9I
Kgvl7Mzj+gogr8yDejIh8GgkF5nGHIxINYwv+IVgk7XAa5p/OzfdqsRUlrw19jkB
9WHAjm81wHfa9tYL1IjaHctFvptBVYLb4np4FJ7i9iHZS5fbjpv74iTLXtAMlZG/
OEKDB6Fc2wb+MoTo2lw5f+4Ed242ncwvsDSpDO0Hsvc4y0+u5iz2Zw9iO3CPV5gu
G29xQnjtzapX7DRGMdhKkENGkblXnbooveKrfxg/JtWwVnQ9/fAIbYpkfQARAQAB
tCpXaW5EZXBsb3kgU2lnbmluZyA8ZGVwbG95QHdpbmRlcGxveS5sb2NhbD6JAlQE
EwEKAD4WIQS1GuHDhLVQDJSce38aoHRIQN1WXQUCacmxLwIbAwUJA8JnAAULCQgH
AgYVCgkICwIEFgIDAQIeAQIXgAAKCRAaoHRIQN1WXbX1EACc4W/GB4PvHSMxNqn+
Nqo0ZPajuZa6BbPDiO2DoZESyw+NmlXEU9q30ygqyHi+yrybe/HzY2q/Ku50YbpN
cNqWbkCQCLTXlbVvnMVo4YJlIwnxX6QgJFrZZ1HFBHiFkqC6Tn0WNe/GZt6FSk7F
Iz/09pMyYX9YU2OIlZMYqWvkZu+CoOSqYYOgkGpXwiWd7kAypVdsDV/eN2STMPo9
SzMlYIYu6gk5fxBA2r2lrjBfn4sg/iMqTV4TysMKWPELoXenSJ1/uuoewq7tVn3b
MR4trrMUcbLQjcKx/yqLOA7+pH6ZMPU5MLCmKxgvFqc/6vLuPxkEZfafXZr0+rJV
S3S3O4Tp2+LVGEfXLHAJlRZgCm6mC/nJciHKLBrBM75NIw/yxLKPsOhRgniv6qBV
bOGP2p/yWHo5ylLt6/lvGYnl8XjFrpyGgcEHhM4VulZxM1GURRDV4JvQHs6KIr+d
sex2ajdUel/Ska4g2E7nzdMt2i+1GtNRKFJHjVeqJZ7S+wuB2epuPYRE1BD5VTO0
UqZ1UpEhWib4CExHlrlWgXTp34zYnSCXXeJvDnfithyFBubh/7d0yR0tf32Qea2q
KnU6DMrDtqM0OlFKalbEEjpmGSrcJIKNepua3MFj6ItL68zZ+7UXTTCAr6xaZk+i
NFa/jZbBtV9pifm3t6i/zCdVYA==
=Ygdm
-----END PGP PUBLIC KEY BLOCK-----
'@
$REPO_DIR     = Join-Path $InstallRoot 'repo'
$TEMP_SCRIPT  = Join-Path $env:TEMP 'windeploy_install.ps1'

# ---------------------------------------------------------------------------
# Helper: simple console logger (Logging.psm1 not loaded yet at this stage)
# ---------------------------------------------------------------------------
function Write-InstallLog {
    param([string]$Message, [string]$Level = 'INFO')
    $colours = @{ INFO='Cyan'; OK='Green'; WARN='Yellow'; ERROR='Red' }
    $ts = Get-Date -Format 'HH:mm:ss'
    $colour = if ($colours.ContainsKey($Level)) { $colours[$Level] } else { 'White' }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Manifest verification
# ---------------------------------------------------------------------------
function Get-VerifiedManifest {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-InstallLog 'Fetching manifest...' INFO
    try {
        $manifestJson = (Invoke-WebRequest -Uri $MANIFEST_URL -UseBasicParsing -ErrorAction Stop).Content
        $remoteSig    = (Invoke-WebRequest -Uri $SIG_URL      -UseBasicParsing -ErrorAction Stop).Content.Trim()
    } catch {
        throw "Failed to fetch manifest from GitHub: $($_.Exception.Message)"
    }

    $obj = $manifestJson | ConvertFrom-Json

    # Placeholder manifest: GitHub Action hasn't run yet (needs GPG_PRIVATE_KEY secret)
    if ($obj.zip_sha256 -eq 'pending' -or $obj.commit_sha -eq 'pending' -or $remoteSig -eq 'pending') {
        Write-InstallLog 'Manifest is placeholder - signature check skipped until GPG key is configured.' WARN
        Write-InstallLog 'See docs/gpg-setup.md to generate your signing key.' WARN
        return @{
            CommitSha   = 'main'
            ZipUrl      = "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/main.zip"
            ZipSha256   = ''
            GeneratedAt = 'pending'
        }
    }

    # GPG not configured yet - skip verification
    if ($GPG_PUBLIC_KEY -like '*REPLACE_WITH*') {
        Write-InstallLog 'GPG public key not configured - skipping signature verification.' WARN
        Write-InstallLog 'Run docs/gpg-setup.md then paste your public key into install.ps1.' WARN
    } else {
        # Import public key and verify signature
        $gpgAvailable = Get-Command gpg -ErrorAction SilentlyContinue
        if ($gpgAvailable) {
            $pubKeyFile  = Join-Path $env:TEMP 'windeploy_pub.asc'
            $manifestFile= Join-Path $env:TEMP 'windeploy_manifest.json'
            $sigFile     = Join-Path $env:TEMP 'windeploy_manifest.sig'

            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($pubKeyFile,   $GPG_PUBLIC_KEY, $utf8NoBom)
            [System.IO.File]::WriteAllText($manifestFile, $manifestJson,   $utf8NoBom)
            [System.IO.File]::WriteAllText($sigFile,      $remoteSig,      $utf8NoBom)

            & gpg --batch --import $pubKeyFile 2>$null | Out-Null
            $verifyResult = & gpg --batch --verify $sigFile $manifestFile 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Manifest GPG signature INVALID.`n$verifyResult`nThe manifest may have been tampered with."
            }
            Write-InstallLog 'Manifest GPG signature verified.' OK

            Remove-Item $pubKeyFile, $manifestFile, $sigFile -Force -ErrorAction SilentlyContinue
        } else {
            Write-InstallLog 'gpg not found on PATH - skipping signature verification.' WARN
        }
    }

    return @{
        CommitSha   = $obj.commit_sha
        ZipUrl      = $obj.zip_url
        ZipSha256   = $obj.zip_sha256
        GeneratedAt = $obj.generated_at
    }
}

function Test-ZipHash {
    param([string]$ZipPath, [string]$ExpectedHash)
    $actual = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $ExpectedHash.ToLower()) {
        throw "ZIP hash mismatch!`n  Expected : $ExpectedHash`n  Actual   : $actual`n" +
              "The download may be corrupt or tampered with. Aborting."
    }
    Write-InstallLog "ZIP hash verified: $actual" OK
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

    $argList = "-ExecutionPolicy Bypass -WindowStyle Maximized -File `"$TEMP_SCRIPT`" -Branch `"$Branch`" -InstallRoot `"$InstallRoot`" -Elevated"
    if ($Update) { $argList += ' -Update' }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Maximized
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
# Step 2: Fetch and verify manifest
# ---------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$manifest = Get-VerifiedManifest
Write-InstallLog "Manifest commit : $($manifest.CommitSha)" INFO
Write-InstallLog "Manifest ZIP SHA: $($manifest.ZipSha256)" INFO
Write-InstallLog "Manifest built  : $($manifest.GeneratedAt)" INFO

# Use the ZIP URL and hash from the verified manifest
$REPO_ZIP_URL      = $manifest.ZipUrl
$EXPECTED_ZIP_HASH = $manifest.ZipSha256

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
    param(
        [string]$ZipUrl,
        [string]$DestDir,
        [string]$ExpectedHash = ''   # empty = skip hash check (should only happen in dev)
    )

    $zipPath = Join-Path $env:TEMP "${REPO_NAME}_${Branch}.zip"

    Write-InstallLog "Downloading repo ZIP: $ZipUrl"
    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        Write-InstallLog "Download complete: $zipPath" OK
    } catch {
        throw "GitHub download failed: $($_.Exception.Message). " +
              "Check network connectivity and that the branch '$Branch' exists."
    }

    # Verify integrity before extracting
    if ($ExpectedHash) {
        Test-ZipHash -ZipPath $zipPath -ExpectedHash $ExpectedHash
    } else {
        Write-InstallLog 'WARNING: No expected hash provided - skipping ZIP integrity check.' WARN
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

# ---------------------------------------------------------------------------
# Step 4: Detect mode and act accordingly
# ---------------------------------------------------------------------------
$bootstrapPath = Join-Path $REPO_DIR 'bootstrap.ps1'
$repoExists    = Test-Path $bootstrapPath

# Always update if repo exists, fresh install if not - no prompt.
if ($repoExists) { $Update = $true }

if ($Update) {
    # ── Update mode: replace scripts only, leave state + logs untouched ──
    Write-InstallLog 'Update mode: pulling latest scripts from GitHub...' INFO

    # Back up current settings.json so custom values survive the overwrite
    $settingsSrc  = Join-Path $REPO_DIR 'config\settings.json'
    $settingsBak  = Join-Path $InstallRoot 'settings.json.bak'
    if (Test-Path $settingsSrc) {
        Copy-Item $settingsSrc $settingsBak -Force
        Write-InstallLog "Settings backed up to: $settingsBak" INFO
    }

    # Download fresh repo ZIP into a temp location, then swap only the
    # script files — preserve state.json, logs, and installer binaries.
    $tempRepo = Join-Path $env:TEMP 'windeploy_update'
    Install-RepoFromGitHub -ZipUrl $REPO_ZIP_URL -DestDir $tempRepo -ExpectedHash $EXPECTED_ZIP_HASH

    # Overwrite scripts — explicit list so we never accidentally clobber
    # state, logs, or user-dropped installers in /apps
    $scriptDirs = @('core', 'config', 'data')
    foreach ($dir in $scriptDirs) {
        $src  = Join-Path $tempRepo $dir
        $dest = Join-Path $REPO_DIR  $dir
        if (Test-Path $src) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory $dest -Force | Out-Null }
            Copy-Item "$src\*" $dest -Recurse -Force
            Write-InstallLog "Updated: $dir\" OK
        }
    }
    # Root-level scripts
    foreach ($f in @('bootstrap.ps1', 'install.ps1')) {
        $src = Join-Path $tempRepo $f
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $REPO_DIR $f) -Force
            Write-InstallLog "Updated: $f" OK
        }
    }

    # Restore user's settings.json over the freshly downloaded default
    if (Test-Path $settingsBak) {
        Copy-Item $settingsBak $settingsSrc -Force
        Write-InstallLog 'User settings.json restored from backup.' OK
    }

    Remove-Item $tempRepo -Recurse -Force -ErrorAction SilentlyContinue

    Write-InstallLog 'Scripts updated - re-running bootstrap to restore any missing tasks...' INFO
    # Fall through to bootstrap call below (no exit here)
}

# ── Fresh install mode ──
if (-not $Update) {
    if ($repoExists) {
        Write-InstallLog 'Removing existing repo for fresh install...' WARN
        Remove-Item $REPO_DIR -Recurse -Force
    }
    Install-RepoFromGitHub -ZipUrl $REPO_ZIP_URL -DestDir $REPO_DIR -ExpectedHash $EXPECTED_ZIP_HASH
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

if (@($missing).Count -gt 0) {
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
