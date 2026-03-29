#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy uninstaller.

.DESCRIPTION
    Removes all WinDeploy scheduled tasks, launcher scripts, auto-logon
    settings, and optionally the deployment directory itself.

    Run via:
        irm "https://raw.githubusercontent.com/karolperkowski/win_dell/main/uninstall.ps1" | iex

    Or locally:
        powershell -ExecutionPolicy Bypass -File uninstall.ps1

    Flags:
        -KeepLogs    Preserve C:\ProgramData\WinDeploy\Logs (default: remove)
        -KeepState   Preserve state.json (default: remove)
        -Silent      No confirmation prompts

.NOTES
    Safe to run at any point - even mid-deployment.
    Idempotent - running twice has the same effect as running once.
#>

[CmdletBinding()]
param(
    [switch]$KeepLogs,
    [switch]$KeepState,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DEPLOY_ROOT = 'C:\ProgramData\WinDeploy'
$LOG_DIR     = Join-Path $DEPLOY_ROOT 'Logs'
$STATE_FILE  = Join-Path $DEPLOY_ROOT 'state.json'
$UNINSTALL_LOG = Join-Path $DEPLOY_ROOT 'uninstall.log'

$ALL_TASKS = @(
    'WinDeploy-Resume'
    'WinDeploy-Monitor'
    'WinDeploy-Notify'
    'WinDeploy-AutoLogonSafety'
    'WinDeploy-Watchdog'
)

$AUTOLOGON_REG = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Test-AdminPrivilege {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    Write-Host '[Uninstall] Not running as Administrator - re-launching elevated...' -ForegroundColor Yellow
    $argList = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($KeepLogs)  { $argList += ' -KeepLogs' }
    if ($KeepState) { $argList += ' -KeepState' }
    if ($Silent)    { $argList += ' -Silent' }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Normal
    exit 0
}

function Write-UninstallLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line   = "[$ts] [$Level] $Message"
    $colour = switch ($Level) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        'SKIP'  { 'DarkGray' }
        default { 'Cyan'   }
    }
    Write-Host $line -ForegroundColor $colour
    try {
        if (-not (Test-Path $DEPLOY_ROOT)) {
            New-Item -ItemType Directory $DEPLOY_ROOT -Force | Out-Null
        }
        Add-Content -Path $UNINSTALL_LOG -Value $line -Encoding UTF8
    } catch { <# non-fatal #> }
}

function Confirm-Action {
    param([string]$Message)
    if ($Silent) { return $true }
    $resp = Read-Host "$Message [Y/n]"
    return ($resp.Trim() -eq '' -or $resp.Trim().ToUpper() -eq 'Y')
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
if (-not (Test-AdminPrivilege)) {
    # irm|iex context has no $PSCommandPath - save to temp and relaunch
    if (-not $PSCommandPath) {
        Write-Host '[Uninstall] Saving to temp and re-launching elevated...' -ForegroundColor Yellow
        $tempScript = Join-Path $env:TEMP 'windeploy_uninstall.ps1'
        $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content $tempScript -Encoding UTF8
        $argList = "-ExecutionPolicy Bypass -File `"$tempScript`""
        if ($KeepLogs)  { $argList += ' -KeepLogs' }
        if ($KeepState) { $argList += ' -KeepState' }
        if ($Silent)    { $argList += ' -Silent' }
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Normal
        exit 0
    }
    Invoke-SelfElevation
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  WinDeploy Uninstaller' -ForegroundColor Cyan
Write-Host '  =====================' -ForegroundColor Cyan
Write-Host ''

if (-not $Silent) {
    Write-Host '  This will remove:' -ForegroundColor Yellow
    Write-Host '    - All WinDeploy scheduled tasks'
    Write-Host '    - Auto-logon registry settings'
    Write-Host '    - Launcher scripts in Logs\'
    Write-Host '    - C:\ProgramData\WinDeploy\repo\'
    if (-not $KeepState) { Write-Host '    - state.json' }
    if (-not $KeepLogs)  { Write-Host '    - All log files' }
    Write-Host ''

    if (-not (Confirm-Action 'Continue with uninstall?')) {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        exit 0
    }
    Write-Host ''
}

Write-UninstallLog 'Uninstall started.'

# ---------------------------------------------------------------------------
# Step 1: Stop and kill task processes BEFORE unregistering
# ---------------------------------------------------------------------------
Write-UninstallLog '--- Stopping task processes ---'

foreach ($taskName in $ALL_TASKS) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { continue }

    if ($task.State -eq 'Running') {
        Write-UninstallLog "  Task '$taskName' is running - force stopping..." WARN

        # Try Stop-ScheduledTask first
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        # Get the PID of the running task instance and kill it directly
        $taskProc = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
            Where-Object {
                $_.CommandLine -like "*$taskName*" -or
                $_.CommandLine -like "*Orchestrator*" -or
                $_.CommandLine -like "*Monitor*" -or
                $_.CommandLine -like "*Notify*" -or
                $_.CommandLine -like "*launch_*"
            }
        foreach ($proc in $taskProc) {
            Write-UninstallLog "  Force killing PID $($proc.ProcessId) for task '$taskName'" WARN
            # taskkill /F terminates the process tree, Stop-Process only kills the process
            & taskkill.exe /F /PID $proc.ProcessId /T 2>$null | Out-Null
        }

        Start-Sleep -Milliseconds 500
    }
}

# ---------------------------------------------------------------------------
# Step 2: Unregister scheduled tasks
# ---------------------------------------------------------------------------
Write-UninstallLog '--- Unregistering scheduled tasks ---'

foreach ($taskName in $ALL_TASKS) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-UninstallLog "  Removed: $taskName" OK
        } catch {
            Write-UninstallLog "  Failed to remove '$taskName': $($_.Exception.Message)" ERROR
        }
    } else {
        Write-UninstallLog "  Not found (already removed): $taskName" SKIP
    }
}

# ---------------------------------------------------------------------------
# Step 3: Kill ANY remaining WinDeploy-related processes
# ---------------------------------------------------------------------------
Write-UninstallLog '--- Killing remaining processes ---'

$patterns   = @('Orchestrator.ps1','Monitor.ps1','Notify.ps1','Watchdog',
                 'launch_resume','launch_monitor','launch_notify','WinDeploy')
$killed     = $false

# Check both powershell.exe and pwsh.exe
foreach ($exeName in @('powershell.exe', 'pwsh.exe')) {
    Get-CimInstance Win32_Process -Filter "Name = '$exeName'" | ForEach-Object {
        $proc = $_
        $cmd  = $proc.CommandLine
        if (-not $cmd) { return }
        foreach ($p in $patterns) {
            if ($cmd -like "*$p*") {
                Write-UninstallLog "  Killing PID $($proc.ProcessId) ($exeName): $($cmd.Substring(0,[Math]::Min(80,$cmd.Length)))..." WARN
                # /T kills the entire process tree (child processes too)
                & taskkill.exe /F /PID $proc.ProcessId /T 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    # fallback
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                }
                $killed = $true
                break
            }
        }
    }
}

if (-not $killed) {
    Write-UninstallLog '  No remaining WinDeploy processes found.' SKIP
}

# Brief wait to ensure all file handles are released before we try to delete files
if ($killed) { Start-Sleep -Seconds 2 }

# ---------------------------------------------------------------------------
# Step 3: Disable auto-logon
# ---------------------------------------------------------------------------
Write-UninstallLog '--- Auto-logon ---'

try {
    Set-ItemProperty $AUTOLOGON_REG 'AutoAdminLogon'  '0'  -Type String -ErrorAction SilentlyContinue
    Remove-ItemProperty $AUTOLOGON_REG 'DefaultPassword' -ErrorAction SilentlyContinue
    Set-ItemProperty $AUTOLOGON_REG 'AutoLogonCount'  '0'  -Type String -ErrorAction SilentlyContinue
    Write-UninstallLog '  Auto-logon disabled and password removed.' OK
} catch {
    Write-UninstallLog "  Auto-logon cleanup failed: $($_.Exception.Message)" WARN
}

# ---------------------------------------------------------------------------
# Step 4: Remove launcher scripts
# ---------------------------------------------------------------------------
Write-UninstallLog '--- Launcher scripts ---'

foreach ($launcher in @('launch_resume.ps1', 'launch_monitor.ps1', 'launch_notify.ps1')) {
    $path = Join-Path $LOG_DIR $launcher
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        Write-UninstallLog "  Removed: $launcher" OK
    }
}

# Also remove watchdog script
$watchdog = Join-Path $DEPLOY_ROOT 'watchdog.ps1'
if (Test-Path $watchdog) {
    Remove-Item $watchdog -Force -ErrorAction SilentlyContinue
    Write-UninstallLog '  Removed: watchdog.ps1' OK
}

# ---------------------------------------------------------------------------
# Step 5: Remove state file
# ---------------------------------------------------------------------------
if (-not $KeepState) {
    Write-UninstallLog '--- State file ---'
    if (Test-Path $STATE_FILE) {
        Remove-Item $STATE_FILE -Force -ErrorAction SilentlyContinue
        Write-UninstallLog '  Removed: state.json' OK
    }
    # Also remove any quarantined state files
    Get-ChildItem $DEPLOY_ROOT -Filter 'state.json.corrupt_*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-UninstallLog "  Removed: $($_.Name)" OK
        }
    # Remove tailscale state files
    foreach ($f in @('tailscale.json', 'tailscale_qr.png')) {
        $p = Join-Path $DEPLOY_ROOT $f
        if (Test-Path $p) {
            Remove-Item $p -Force -ErrorAction SilentlyContinue
            Write-UninstallLog "  Removed: $f" OK
        }
    }
}

# ---------------------------------------------------------------------------
# Step 6: Remove repo
# ---------------------------------------------------------------------------
Write-UninstallLog '--- Repo ---'

$repoDir = Join-Path $DEPLOY_ROOT 'repo'
if (Test-Path $repoDir) {
    try {
        Remove-Item $repoDir -Recurse -Force -ErrorAction Stop
        Write-UninstallLog '  Removed: repo\' OK
    } catch {
        Write-UninstallLog "  Failed to remove repo\: $($_.Exception.Message)" ERROR
        Write-UninstallLog '  Try rebooting and running uninstall again.' WARN
    }
} else {
    Write-UninstallLog '  repo\ not found.' SKIP
}

# ---------------------------------------------------------------------------
# Step 7: Remove logs (unless -KeepLogs)
# ---------------------------------------------------------------------------
if (-not $KeepLogs) {
    Write-UninstallLog '--- Logs ---'

    # Write final line before removing the directory
    Write-UninstallLog 'Removing log directory...' WARN

    # Small delay to flush the log
    Start-Sleep -Milliseconds 200

    if (Test-Path $LOG_DIR) {
        try {
            Remove-Item $LOG_DIR -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "[Uninstall] Could not remove Logs\: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Remove root deploy dir if now empty
    if ((Test-Path $DEPLOY_ROOT) -and -not (Get-ChildItem $DEPLOY_ROOT -ErrorAction SilentlyContinue)) {
        Remove-Item $DEPLOY_ROOT -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-UninstallLog 'Log directory preserved (-KeepLogs).' SKIP
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  Uninstall complete.' -ForegroundColor Green
Write-Host ''
if ($KeepLogs) {
    Write-Host "  Logs preserved at: $LOG_DIR" -ForegroundColor Cyan
}
if ($KeepState) {
    Write-Host "  State file preserved at: $STATE_FILE" -ForegroundColor Cyan
}
Write-Host ''
