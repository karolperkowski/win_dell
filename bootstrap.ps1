#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Bootstrap - Initial entry point for post-install automation.

.DESCRIPTION
    Manually triggered once after a fresh Windows install. Elevates to admin,
    sets up the resume-after-reboot scheduled task, initialises state and
    logging, then hands off to the orchestrator. Every subsequent run (after
    reboot) is driven by that scheduled task - this file is NOT re-executed.

.NOTES
    Repo  : https://github.com/karolperkowski/win_dell
    Run as: powershell.exe -ExecutionPolicy Bypass -File .\bootstrap.ps1
    Or via: irm "https://raw.githubusercontent.com/karolperkowski/win_dell/main/install.ps1" | iex
    Tested on Windows 10 21H2+ and Windows 11 22H2+
#>

[CmdletBinding()]
param(
    # Override the source root (useful for local dev / testing)
    [string]$RepoRoot = $PSScriptRoot,

    # Skip the self-elevation check (already elevated externally)
    [switch]$NoElevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'

# ---------------------------------------------------------------------------
# Resilience module loaded first — before any other import.
# Creates log directory, validates state file, re-registers missing tasks.
# Self-contained: no dependency on other WinDeploy modules.
# ---------------------------------------------------------------------------
$Script:_resPath = Join-Path $PSScriptRoot 'core\Resilience.psm1'
if (Test-Path $Script:_resPath) {
    Import-Module $Script:_resPath -DisableNameChecking -Force
} else {
    # Absolute fallback if even Resilience.psm1 is missing
    $earlyLog = 'C:\ProgramData\WinDeploy\Logs\early.log'
    $earlyDir = Split-Path $earlyLog
    if (-not (Test-Path $earlyDir)) { New-Item -ItemType Directory $earlyDir -Force | Out-Null }
    [System.IO.File]::AppendAllText($earlyLog, "WARNING: Resilience.psm1 not found at $Script:_resPath`r`n", [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# Region: Constants
# ---------------------------------------------------------------------------
$Script:DEPLOY_ROOT   = 'C:\ProgramData\WinDeploy'
$Script:LOG_DIR       = Join-Path $Script:DEPLOY_ROOT 'Logs'
$Script:STATE_FILE    = Join-Path $Script:DEPLOY_ROOT 'state.json'
$Script:CONFIG_FILE   = Join-Path $RepoRoot 'config\settings.json'
$Script:TASK_NAME     = 'WinDeploy-Resume'
$Script:ORCHESTRATOR  = Join-Path $RepoRoot 'core\Orchestrator.ps1'
# ---------------------------------------------------------------------------

function Test-AdminPrivilege {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$id
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    <#
    Re-launches the bootstrap as Administrator, preserving RepoRoot so paths
    resolve correctly after elevation.
    #>
    Write-Host '[Bootstrap] Not running as Administrator - re-launching elevated...' -ForegroundColor Yellow
    $argList = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -RepoRoot `"$RepoRoot`" -NoElevation"
    Start-Process -FilePath 'powershell.exe' `
                  -ArgumentList $argList `
                  -Verb RunAs
    exit 0
}

function Initialize-DeployDirectories {
    foreach ($dir in @($Script:DEPLOY_ROOT, $Script:LOG_DIR)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "[Bootstrap] Created directory: $dir"
        }
    }
}

function Copy-RepoToDeployRoot {
    <#
    Copies the entire repo to C:\ProgramData\WinDeploy\repo so the scheduled
    task can reference a stable, local path even if the original media
    (USB/network share) is later disconnected.
    #>
    $dest = Join-Path $Script:DEPLOY_ROOT 'repo'
    if (Test-Path $dest) {
        Write-Host '[Bootstrap] Repo already copied to deploy root - skipping copy.'
        return $dest
    }
    Write-Host "[Bootstrap] Copying repo from $RepoRoot to $dest ..."
    Copy-Item -Path $RepoRoot -Destination $dest -Recurse -Force
    Write-Host '[Bootstrap] Repo copy complete.'
    return $dest
}

function Set-AutoLogon {
    <#
    Configures the built-in Administrator account for automatic logon so
    reboots during SYSTEM-level stages (Windows Update) re-enter a session
    without operator intervention.

    Also temporarily disables UAC (EnableLUA=0) for the deployment window.
    Without this, auto-logon creates a split-token session even for the
    Administrator account, causing child processes that attempt elevation
    to show a UAC prompt with no one to click it.
    UAC is restored by the Cleanup stage after deployment completes.

    SECURITY NOTE: Auto-logon credentials are stored in plaintext in the
    registry (HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon).
    This is intentional for unattended deployment; the orchestrator MUST
    disable auto-logon and re-enable UAC in its final cleanup stage.
    A reboot is required for EnableLUA changes to take effect.
    #>
    param(
        [string]$Username = 'Administrator',
        [string]$Password = ''   # Blank password on fresh installs
    )

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $polSystem = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # Auto-logon
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon'  -Value '1'      -Type String
    Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value $Username -Type String
    Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' -Value $Password -Type String
    Set-ItemProperty -Path $winlogon -Name 'AutoLogonCount'  -Value '99'      -Type String

    # Save current UAC state so Cleanup can restore it exactly
    $currentUAC = (Get-ItemProperty -Path $polSystem -Name 'EnableLUA' -ErrorAction SilentlyContinue).EnableLUA
    if ($null -eq $currentUAC) { $currentUAC = 1 }   # default is enabled
    Set-ItemProperty -Path $polSystem -Name 'WinDeployPrevUAC' -Value $currentUAC -Type DWord

    # Disable UAC for the deployment window
    Set-ItemProperty -Path $polSystem -Name 'EnableLUA' -Value 0 -Type DWord

    Write-Host "[Bootstrap] Auto-logon configured for '$Username'."
    Write-Host '[Bootstrap] UAC temporarily disabled for deployment (will be restored by Cleanup).'
    Write-Host '[Bootstrap] NOTE: A reboot is required before UAC change takes effect.'
}

function Write-BootstrapLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $logFile = Join-Path $Script:LOG_DIR 'bootstrap.log'
    [System.IO.File]::AppendAllText($logFile, "$line`r`n", [System.Text.Encoding]::UTF8)
    Write-Host $line
}

# ---------------------------------------------------------------------------
# Region: Main
# ---------------------------------------------------------------------------
try {
    # Step 1 - Elevation guard
    if (-not $NoElevation -and -not (Test-AdminPrivilege)) {
        Invoke-SelfElevation
    }

    # Step 2 - Directories (raw, before resilience module may be available)
    foreach ($dir in @($Script:DEPLOY_ROOT, $Script:LOG_DIR)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    Write-BootstrapLog 'Bootstrap started.'
    Write-BootstrapLog "Source repo: $RepoRoot"
    Write-BootstrapLog "OS: $($(Get-CimInstance Win32_OperatingSystem).Caption)"

    # Step 3 - Copy repo to stable local path FIRST so all script paths are valid
    $localRepo = Copy-RepoToDeployRoot

    # Step 4 - State file
    if (-not (Test-Path $Script:STATE_FILE)) {
        $initialState = [ordered]@{
            SchemaVersion          = 1
            BootstrappedAt         = (Get-Date -Format 'o')
            LastUpdatedAt          = (Get-Date -Format 'o')
            RepoRoot               = $localRepo
            ConfigFile             = Join-Path $localRepo 'config\settings.json'
            CurrentStage           = 'PowerSettings'
            CompletedStages        = @()
            FailedStages           = @()
            StageTimestamps        = @{}
            LastError              = $null
            LastErrorStage         = $null
            LastErrorTimestamp     = $null
            RebootCount            = 0
            DeployComplete         = $false
            DeployCompletedAt      = $null
        }
        $initialState | ConvertTo-Json -Depth 5 |
            Set-Content -Path $Script:STATE_FILE -Encoding UTF8
        Write-BootstrapLog "State file created: $($Script:STATE_FILE)"
    } else {
        Write-BootstrapLog 'State file already exists - resuming existing deployment.'
    }

    # Step 5 - Auto-logon
    Set-AutoLogon -Username 'Administrator' -Password ''

    # Step 6 - Resilience checks: validates dirs, state, registers ALL tasks.
    # Must run AFTER Copy-RepoToDeployRoot so script paths resolve correctly.
    if (Get-Command Invoke-ResilienceChecks -ErrorAction SilentlyContinue) {
        Invoke-ResilienceChecks -CalledFrom 'bootstrap' -RepoRoot $localRepo
    } else {
        Write-BootstrapLog 'WARNING: Resilience module not available - tasks may not be registered.' WARN
    }

    # Step 7 - Launch monitor immediately so progress is visible from the first run.
    # Start-Process returns instantly (no -Wait) so the monitor runs alongside
    # the orchestrator rather than blocking it.
    $monitorPath = Join-Path $localRepo 'core\Monitor.ps1'
    if (Test-Path $monitorPath) {
        Write-BootstrapLog 'Launching monitor window...'
        Start-Process powershell.exe `
            -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$monitorPath`"" `
            -ErrorAction SilentlyContinue
    }

    # Step 8 - Trigger orchestrator via the scheduled task (runs as SYSTEM).
    # Running via the task avoids ACL issues - state.json and deploy root
    # are locked to SYSTEM/Administrators, and the task runs with the
    # correct privileges. The monitor updates independently via its timer.
    Write-BootstrapLog 'Starting orchestrator via WinDeploy-Resume task...'
    Start-ScheduledTask -TaskName 'WinDeploy-Resume' -ErrorAction Stop
    Write-BootstrapLog 'Orchestrator task started. Monitor window will show progress.'

} catch {
    $errMsg = "Bootstrap FATAL: $($_.Exception.Message) | Line $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host $errMsg -ForegroundColor Red
    try {
        $logFile = Join-Path $Script:LOG_DIR 'bootstrap.log'
        [System.IO.File]::AppendAllText($logFile, "$errMsg`r`n", [System.Text.Encoding]::UTF8)
    } catch { Write-Host "[Bootstrap] Log write failed: $($_.Exception.Message)" }
    exit 1
}
