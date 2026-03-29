#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Resilience Module

.DESCRIPTION
    Self-healing functions that every entry point calls before doing any work.
    Designed to run even when other modules are broken, missing, or not yet loaded.
    No dependencies on any other WinDeploy module.

    Rules enforced here:
      R1  Log directory always exists before anything else runs
      R2  All three scheduled tasks are validated and re-registered if missing
      R3  Auto-logon has an independent safety task that doesn't depend on Cleanup
      R4  State file corruption is detected and quarantined, never causes a hard crash
      R5  Each recovery action is logged to early.log regardless of other module state
      R6  Every function is idempotent - safe to call multiple times
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

# ---------------------------------------------------------------------------
# Constants (no dependency on Config.psm1 - this module must be self-contained)
# ---------------------------------------------------------------------------
$Script:DEPLOY_ROOT  = 'C:\ProgramData\WinDeploy'
$Script:LOG_DIR      = 'C:\ProgramData\WinDeploy\Logs'
$Script:EARLY_LOG    = 'C:\ProgramData\WinDeploy\Logs\early.log'
$Script:STATE_FILE   = 'C:\ProgramData\WinDeploy\state.json'
$Script:REPO_DIR     = 'C:\ProgramData\WinDeploy\repo'
$Script:TASK_RESUME  = 'WinDeploy-Resume'
$Script:TASK_MONITOR = 'WinDeploy-Monitor'
$Script:TASK_NOTIFY  = 'WinDeploy-Notify'
$Script:TASK_SAFETY  = 'WinDeploy-AutoLogonSafety'
$Script:TASK_WATCHDOG= 'WinDeploy-Watchdog'

# ---------------------------------------------------------------------------
# R1: Raw logger — writes before any other module is loaded
# ---------------------------------------------------------------------------
function Write-ResilienceLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [RESILIENCE/$Level] $Message"

    # Always try to write to disk first
    try {
        if (-not (Test-Path $Script:LOG_DIR)) {
            New-Item -ItemType Directory -Path $Script:LOG_DIR -Force | Out-Null
        }
        try { [System.IO.File]::AppendAllText($Script:EARLY_LOG, "$line`r`n", [System.Text.Encoding]::UTF8) } catch {}
    } catch { Write-Host "[Resilience] Log write failed: $($_.Exception.Message)" }

    # Then console
    $colour = switch ($Level) {
        'WARN'  { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# R1: Ensure all required directories exist with correct ACLs
# ---------------------------------------------------------------------------
function Assert-DeployDirectories {
    foreach ($dir in @($Script:DEPLOY_ROOT, $Script:LOG_DIR)) {
        if (-not (Test-Path $dir)) {
            try {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-ResilienceLog "Created directory: $dir" OK
            } catch {
                Write-ResilienceLog "Could not create $dir : $($_.Exception.Message)" WARN
                continue
            }
        }

        # Set ACL on every run (not just on creation) so permissions are
        # correct even if the directory already existed with wrong ACLs.
        try {
            $acl = Get-Acl $dir
            $acl.SetAccessRuleProtection($true, $false)

            # SYSTEM + Administrators: full control
            foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
                $acl.AddAccessRule(
                    [System.Security.AccessControl.FileSystemAccessRule]::new(
                        $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }

            # BUILTIN\Users: Modify on Logs dir so Monitor/Notify tasks (which
            # run as the interactive user) can write early.log and task logs.
            # Restricted to LOG_DIR only - DEPLOY_ROOT stays Admins-only.
            if ($dir -eq $Script:LOG_DIR) {
                $acl.AddAccessRule(
                    [System.Security.AccessControl.FileSystemAccessRule]::new(
                        'BUILTIN\Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }

            Set-Acl -Path $dir -AclObject $acl
        } catch {
            Write-ResilienceLog "Could not set ACL on $dir : $($_.Exception.Message)" WARN
        }
    }
}

# ---------------------------------------------------------------------------
# R4: State file validation and quarantine
# ---------------------------------------------------------------------------
function Assert-StateFileIntegrity {
    if (-not (Test-Path $Script:STATE_FILE)) {
        Write-ResilienceLog 'State file not found - will be created by bootstrap.' INFO
        return
    }

    try {
        $raw = Get-Content $Script:STATE_FILE -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'File is empty.' }
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
        Write-ResilienceLog 'State file OK.' OK
    } catch {
        # Quarantine the corrupt file — never delete it, we may need it for diagnosis
        $quarantine = "$($Script:STATE_FILE).corrupt_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        try {
            Move-Item $Script:STATE_FILE $quarantine -Force
            Write-ResilienceLog "State file corrupt - quarantined to: $quarantine" WARN
            Write-ResilienceLog "Reason: $($_.Exception.Message)" WARN
            Write-ResilienceLog 'Deployment will restart from the beginning.' WARN
        } catch {
            Write-ResilienceLog "Could not quarantine corrupt state file: $($_.Exception.Message)" ERROR
        }
    }
}

# ---------------------------------------------------------------------------
# R2: Scheduled task self-healing
# Re-registers any missing WinDeploy tasks using paths from the local repo.
# Called by bootstrap AND by the orchestrator on every run.
# ---------------------------------------------------------------------------
function Assert-ScheduledTasks {
    param([string]$RepoRoot = $Script:REPO_DIR)

    if (-not (Test-Path $RepoRoot)) {
        Write-ResilienceLog "Repo not found at '$RepoRoot' - cannot register tasks." ERROR
        return
    }

    $LOG_DIR = 'C:\ProgramData\WinDeploy\Logs'

    $taskDefs = @(
        @{
            Name        = $Script:TASK_RESUME
            Script      = Join-Path $RepoRoot 'core\Orchestrator.ps1'
            LogFile     = "$LOG_DIR\task_resume.log"
            UseLauncher = $true     # hidden SYSTEM task - redirect all output to log
            Principal   = 'SYSTEM'
            Triggers    = @('Boot', 'Logon')
            TimeLimit   = 4
            Description = 'WinDeploy orchestrator - runs deployment stages'
        },
        @{
            Name        = $Script:TASK_MONITOR
            Script      = Join-Path $RepoRoot 'core\Monitor.ps1'
            LogFile     = $null
            UseLauncher = $false    # interactive UI task - must run directly in user session
            Principal   = 'Users'
            Triggers    = @('Logon')
            TimeLimit   = 4
            Description = 'WinDeploy monitor - shows deployment progress'
        },
        @{
            Name        = $Script:TASK_NOTIFY
            Script      = Join-Path $RepoRoot 'core\Notify.ps1'
            LogFile     = "$LOG_DIR\task_notify.log"
            UseLauncher = $true     # hidden background task - redirect output to log
            Principal   = 'Users'
            Triggers    = @('Logon')
            TimeLimit   = 0.033
            Description = 'WinDeploy notify - tray notification on completion'
        }
    )

    foreach ($def in $taskDefs) {
        # Verify the script file exists - hard error, not a silent skip
        if (-not (Test-Path $def.Script)) {
            Write-ResilienceLog "CANNOT register '$($def.Name)' - script not found: $($def.Script)" ERROR
            continue
        }

        # Check if already registered correctly
        $existing = Get-ScheduledTask -TaskName $def.Name -ErrorAction SilentlyContinue
        if ($existing) {
            $currentArgs = $existing.Actions[0].Arguments
            $expectedFragment = if ($def.UseLauncher) {
                "launch_$($def.Name.Replace('WinDeploy-','').ToLower()).ps1"
            } else {
                $def.Script
            }
            if ($currentArgs -like "*$expectedFragment*") {
                Write-ResilienceLog "Task '$($def.Name)' OK." OK
                continue
            }
            Write-ResilienceLog "Task '$($def.Name)' has stale path - replacing." WARN
            Unregister-ScheduledTask -TaskName $def.Name -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-ResilienceLog "Task '$($def.Name)' missing - registering." WARN
        }

        try {
            if ($def.UseLauncher) {
                # Hidden tasks: wrap in a launcher that redirects all output to a log file.
                # This ensures every execution leaves a trace even if the script crashes
                # before its own logging starts.
                $launcherPath = Join-Path $LOG_DIR "launch_$($def.Name.Replace('WinDeploy-','').ToLower()).ps1"
                $logFile      = $def.LogFile
                $scriptPath   = $def.Script

                $launcherContent = @"
`$log = '$logFile'
`$ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
[System.IO.File]::AppendAllText(`$log, "[`$ts] Task '$($def.Name)' started. PID:`$PID User:`$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`r`n", [System.Text.Encoding]::UTF8)
try {
    # Force UTF-8 output encoding to prevent UTF-16LE wide-character log files
    `$OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    & powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '$scriptPath' *>&1 | Out-File -FilePath `$log -Append -Encoding UTF8
    [System.IO.File]::AppendAllText(`$log, "[`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] Exited: `$LASTEXITCODE`r`n", [System.Text.Encoding]::UTF8)
} catch {
    [System.IO.File]::AppendAllText(`$log, "[`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] LAUNCHER ERROR: `$(`$_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8)
}
"@
                $launcherContent | Set-Content -Path $launcherPath -Encoding UTF8
                $argString = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
            } else {
                # Interactive UI tasks (Monitor): run directly in the user session.
                # A child process cannot show windows on the desktop - must be the direct task process.
                $argString = "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$($def.Script)`""
            }

            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argString

            $triggers = @()
            foreach ($t in $def.Triggers) {
                $triggers += switch ($t) {
                    'Boot'  { New-ScheduledTaskTrigger -AtStartup }
                    'Logon' { New-ScheduledTaskTrigger -AtLogOn }
                }
            }

            $principal = if ($def.Principal -eq 'SYSTEM') {
                New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            } else {
                # -GroupId runs the task for any logged-on user in that group.
                # Do NOT specify -LogonType with -GroupId - they are incompatible
                # parameter sets and cause "parameter set cannot be resolved" error.
                New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
            }

            $limitMins  = [int](($def.TimeLimit - [Math]::Floor($def.TimeLimit)) * 60)
            $timeLimit  = New-TimeSpan -Hours ([Math]::Floor($def.TimeLimit)) -Minutes $limitMins

            $settings = New-ScheduledTaskSettingsSet `
                -ExecutionTimeLimit    $timeLimit `
                -MultipleInstances     IgnoreNew `
                -StartWhenAvailable `
                -RunOnlyIfNetworkAvailable:$false

            Register-ScheduledTask `
                -TaskName    $def.Name `
                -TaskPath    '\' `
                -Action      $action `
                -Trigger     $triggers `
                -Principal   $principal `
                -Settings    $settings `
                -Description $def.Description `
                -Force | Out-Null

            # Post-registration verification - don't trust the exit code
            $check = Get-ScheduledTask -TaskName $def.Name -ErrorAction SilentlyContinue
            if ($check) {
                Write-ResilienceLog "Task '$($def.Name)' registered and verified." OK
            } else {
                Write-ResilienceLog "Task '$($def.Name)' was NOT created - silent failure after task registration." ERROR
            }

        } catch {
            Write-ResilienceLog "Task '$($def.Name)' registration threw: $($_.Exception.Message)" ERROR
        }
    }
}

# ---------------------------------------------------------------------------
# R3: Auto-logon independent safety task
# Registered at bootstrap. Fires 6 hours after bootstrap time regardless
# of whether Cleanup ever runs. Disables auto-logon unconditionally.
# ---------------------------------------------------------------------------
function Assert-AutoLogonSafetyTask {
    $existing = Get-ScheduledTask -TaskName $Script:TASK_SAFETY -ErrorAction SilentlyContinue
    if ($existing) {
        Write-ResilienceLog "AutoLogon safety task already registered." OK
        return
    }

    Write-ResilienceLog 'Registering auto-logon safety task...' INFO

    try {
        $action = New-ScheduledTaskAction `
            -Execute 'reg.exe' `
            -Argument 'add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f'

        # Fire once, 6 hours from now.
        # EndBoundary must be set on the trigger when using DeleteExpiredTaskAfter,
        # otherwise the XML schema fails with "missing required element or attribute".
        # New-ScheduledTaskTrigger does not expose EndBoundary, so we set it directly.
        $triggerAt  = (Get-Date).AddHours(6)
        $trigger    = New-ScheduledTaskTrigger -Once -At $triggerAt
        $trigger.EndBoundary = $triggerAt.AddHours(1).ToString('s')   # ISO 8601 local

        $principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
            -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 10) `
            -StartWhenAvailable

        Register-ScheduledTask `
            -TaskName   $Script:TASK_SAFETY `
            -Action     $action `
            -Trigger    $trigger `
            -Principal  $principal `
            -Settings   $settings `
            -Description 'WinDeploy safety: disables auto-logon after 6h regardless of deployment state' `
            -Force | Out-Null

        Write-ResilienceLog 'Auto-logon safety task registered (fires in 6h).' OK
    } catch {
        Write-ResilienceLog "Failed to register safety task: $($_.Exception.Message)" ERROR
    }
}

# ---------------------------------------------------------------------------
# R6: Watchdog task — kills any WinDeploy process that has been running
# for more than 4 hours. Prevents a hung stage from locking the machine.
# ---------------------------------------------------------------------------
function Assert-WatchdogTask {
    $existing = Get-ScheduledTask -TaskName $Script:TASK_WATCHDOG -ErrorAction SilentlyContinue
    if ($existing) { return }   # Only register once

    $watchdogScript = @'
# WinDeploy Watchdog - kills hung orchestrator processes
$maxAgeHours = 4
$procs = Get-WmiObject Win32_Process |
    Where-Object { $_.CommandLine -like '*Orchestrator.ps1*' }
foreach ($p in $procs) {
    $start = [System.Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate)
    $age   = (Get-Date) - $start
    if ($age.TotalHours -gt $maxAgeHours) {
        $log = 'C:\ProgramData\WinDeploy\Logs\early.log'
        [System.IO.File]::AppendAllText($log, "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [WATCHDOG] Killing hung process PID $($p.ProcessId) (age: $([int]$age.TotalHours)h)`r`n", [System.Text.Encoding]::UTF8)
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
'@

    $watchdogPath = Join-Path $Script:DEPLOY_ROOT 'watchdog.ps1'
    try {
        $watchdogScript | Set-Content $watchdogPath -Encoding UTF8

        $action  = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogPath`""

        # -RepetitionInterval alone on a -Once trigger generates XML missing EndBoundary,
        # which fails validation on Windows 10/11. -RepetitionDuration must be set explicitly.
        # 9999 days = effectively indefinite without hitting the XML schema boundary issue.
        $trigger = New-ScheduledTaskTrigger `
            -Once `
            -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 30) `
            -RepetitionDuration (New-TimeSpan -Days 9999)

        $principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
            -StartWhenAvailable

        Register-ScheduledTask `
            -TaskName   $Script:TASK_WATCHDOG `
            -Action     $action `
            -Trigger    $trigger `
            -Principal  $principal `
            -Settings   $settings `
            -Description 'WinDeploy watchdog - kills hung stage processes' `
            -Force | Out-Null

        Write-ResilienceLog 'Watchdog task registered (runs every 30 min).' OK
    } catch {
        Write-ResilienceLog "Failed to register watchdog: $($_.Exception.Message)" WARN
    }
}

# ---------------------------------------------------------------------------
# Master entry point — call this at the top of every bootstrap and orchestrator run
# ---------------------------------------------------------------------------
function Invoke-ResilienceChecks {
    param([string]$CalledFrom = 'Unknown', [string]$RepoRoot = $Script:REPO_DIR)

    Write-ResilienceLog "=== Resilience checks starting (called from: $CalledFrom) ==="

    Assert-DeployDirectories
    Assert-StateFileIntegrity
    Assert-ScheduledTasks      -RepoRoot $RepoRoot
    Assert-AutoLogonSafetyTask
    Assert-WatchdogTask

    Write-ResilienceLog '=== Resilience checks complete ==='
}

Export-ModuleMember -Function @(
    'Write-ResilienceLog'
    'Assert-DeployDirectories'
    'Assert-StateFileIntegrity'
    'Assert-ScheduledTasks'
    'Assert-AutoLogonSafetyTask'
    'Assert-WatchdogTask'
    'Invoke-ResilienceChecks'
)
