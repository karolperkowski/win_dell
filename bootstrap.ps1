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
$ConfirmPreference   = 'None'   # Prevent any cmdlet from prompting during unattended run

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

function Register-ResumeTask {
    <#
    Creates a scheduled task that runs the orchestrator at every logon/startup
    until the deployment marks itself complete. The task is removed by the
    orchestrator once all stages finish.
    #>
    param([string]$LocalRepoRoot)

    # Remove any stale task from a previous run
    Unregister-ScheduledTask -TaskName $Script:TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue

    $orchestratorPath = Join-Path $LocalRepoRoot 'core\Orchestrator.ps1'
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$orchestratorPath`""

    # Trigger 1: at system startup (catches machine-level reboots)
    $triggerBoot = New-ScheduledTaskTrigger -AtStartup

    # Trigger 2: at any user logon (catches interactive sessions)
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    # Run as SYSTEM so no credential prompt is ever shown
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable:$false

    Register-ScheduledTask `
        -TaskName  $Script:TASK_NAME `
        -Action    $action `
        -Trigger   @($triggerBoot, $triggerLogon) `
        -Principal $principal `
        -Settings  $settings `
        -Description 'WinDeploy post-install automation resume task' `
        -Force | Out-Null

    Write-Host "[Bootstrap] Scheduled task '$($Script:TASK_NAME)' registered."
}

function Register-MonitorTask {
    <#
    Creates a scheduled task that shows the WPF monitor window at every logon.
    Unlike the orchestrator task (which runs as SYSTEM, hidden), this task runs
    as the interactive user so the window is visible on the desktop.
    #>
    param([string]$LocalRepoRoot)

    $monitorTaskName = 'WinDeploy-Monitor'
    Unregister-ScheduledTask -TaskName $monitorTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $monitorPath = Join-Path $LocalRepoRoot 'core\Monitor.ps1'
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$monitorPath`""

    # Logon trigger only - the window should appear when a user logs in,
    # not at bare startup when there is no desktop to display it on
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    # Run as interactive user (whoever logs on), not SYSTEM
    # This is what makes the window appear on the desktop
    $principal = New-ScheduledTaskPrincipal `
        -GroupId 'BUILTIN\Users' `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName   $monitorTaskName `
        -Action     $action `
        -Trigger    $trigger `
        -Principal  $principal `
        -Settings   $settings `
        -Description 'WinDeploy deployment progress monitor (visible window)' `
        -Force | Out-Null

    Write-Host "[Bootstrap] Monitor task '$monitorTaskName' registered."
}
    <#
    Configures the built-in Administrator account for automatic logon so
    reboots during SYSTEM-level stages (Windows Update) re-enter a session
    without operator intervention.

    SECURITY NOTE: Auto-logon credentials are stored in plaintext in the
    registry (HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon).
    This is intentional for unattended deployment; the orchestrator MUST
    disable auto-logon in its final cleanup stage.
    #>
    param(
        [string]$Username = 'Administrator',
        [string]$Password = ''   # Blank password on fresh installs
    )

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon'  -Value '1'    -Type String
    Set-ItemProperty -Path $regPath -Name 'DefaultUserName' -Value $Username -Type String
    Set-ItemProperty -Path $regPath -Name 'DefaultPassword' -Value $Password -Type String
    Set-ItemProperty -Path $regPath -Name 'AutoLogonCount'  -Value '99'   -Type String

    Write-Host "[Bootstrap] Auto-logon configured for '$Username'. Will be disabled on deployment completion."
}

function Write-BootstrapLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $logFile = Join-Path $Script:LOG_DIR 'bootstrap.log'
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# ---------------------------------------------------------------------------
# Region: Main
# ---------------------------------------------------------------------------
try {
    # Step 1 - Elevation guard
    if (-not $NoElevation -and -not (Test-AdminPrivilege)) {
        Invoke-SelfElevation   # does not return
    }

    # Step 2 - Stable local directories
    Initialize-DeployDirectories

    Write-BootstrapLog 'Bootstrap started.'
    Write-BootstrapLog "Source repo: $RepoRoot"
    Write-BootstrapLog "OS: $($(Get-CimInstance Win32_OperatingSystem).Caption)"

    # Step 3 - Copy repo to a stable local path
    $localRepo = Copy-RepoToDeployRoot

    # Step 4 - State file: write initial marker so orchestrator knows it was bootstrapped
    if (-not (Test-Path $Script:STATE_FILE)) {
        $initialState = [ordered]@{
            SchemaVersion    = 1
            BootstrappedAt   = (Get-Date -Format 'o')
            RepoRoot         = $localRepo
            ConfigFile       = Join-Path $localRepo 'config\settings.json'
            CurrentStage     = 'WindowsUpdate'
            CompletedStages  = @()
            LastError        = $null
            DeployComplete   = $false
        }
        $initialState | ConvertTo-Json -Depth 5 |
            Set-Content -Path $Script:STATE_FILE -Encoding UTF8
        Write-BootstrapLog "State file created: $($Script:STATE_FILE)"
    } else {
        Write-BootstrapLog "State file already exists - resuming existing deployment."
    }

    # Step 5 - Auto-logon (disable it ONLY if you need interactive sign-in;
    # comment out the call if your imaging process already handles this)
    Set-AutoLogon -Username 'Administrator' -Password ''

    # Step 6 - Register resume task (hidden, SYSTEM)
    Register-ResumeTask -LocalRepoRoot $localRepo

    # Step 6b - Register monitor task (visible window, interactive user)
    Register-MonitorTask -LocalRepoRoot $localRepo

    # Step 7 - Kick off orchestrator immediately without waiting for a reboot
    Write-BootstrapLog 'Launching orchestrator for first run...'
    $orchestratorPath = Join-Path $localRepo 'core\Orchestrator.ps1'
    & powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $orchestratorPath

} catch {
    $errMsg = "Bootstrap FATAL: $($_.Exception.Message) | Line $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host $errMsg -ForegroundColor Red
    try {
        $logFile = Join-Path $Script:LOG_DIR 'bootstrap.log'
        Add-Content -Path $logFile -Value $errMsg -Encoding UTF8
    } catch { <# best-effort #> }
    exit 1
}
