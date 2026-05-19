#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Configure Dell Updates (unattended)

.DESCRIPTION
    Runs after InstallDellSupportAssist + InstallDellPowerManager. Two jobs:

      1) Best-effort SupportAssist auto-consent. The consumer SupportAssist
         app does not expose a documented CLI for unattended scans; instead
         we set the registry keys it reads on startup (AutoUpdate, scheduled
         scan frequency, telemetry/analytics consent) and enable its own
         scheduled tasks if they were left disabled by the installer. Every
         write is wrapped in try/catch -- Dell renames these keys between
         agent versions and a missing key is logged, not fatal.

      2) Recurring DCU sweep. Registers a SYSTEM-context scheduled task that
         runs Invoke-DellCommandUpdate from core/DellCommandUpdate.ps1 once a
         week. dcu-cli is the actual unattended Dell update mechanism --
         BIOS, firmware, drivers, Dell-published software updates -- and is
         already integrated into the WindowsUpdate stage. Adding the weekly
         task keeps updates flowing after the one-shot deploy is done.

    Skips cleanly on non-Dell hardware using the same Manufacturer match as
    core/DellCommandUpdate.ps1.

    Per the orchestrator contract (CLAUDE.md), this stage returns exactly
    one @{ Status; Message } hashtable.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'ConfigureDellUpdates',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'Config.psm1')  -DisableNameChecking -Force
try {
    Import-Module (Join-Path $coreDir 'State.psm1') -DisableNameChecking -Force
} catch {
    $Script:StateLoadErr = $_.Exception.Message
}

Initialize-Logger -Stage $StageName

if ($Script:StateLoadErr) {
    Write-LogWarning "State.psm1 unavailable: $($Script:StateLoadErr) -- StageExtras writes will be skipped."
}

$WD = Get-WDConfig

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Set-StageExtraSafe {
    param([string]$Key, $Value)
    try {
        if (Get-Command Set-StageExtra -ErrorAction SilentlyContinue) {
            Set-StageExtra -StageName $StageName -Key $Key -Value $Value
        }
    } catch {
        Write-LogWarning "  StageExtras[$Key] write failed: $($_.Exception.Message)"
    }
}

function Test-IsDellHardware {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $cs -or -not $cs.Manufacturer) { return $false }
    return ($cs.Manufacturer -match 'Dell')
}

function Set-RegistrySafe {
    <#
    Wraps Set-ItemProperty + auto-create-key in try/catch so a single bad
    write does not abort the SupportAssist configuration pass.
    Returns $true on success.
    #>
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')

    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        Write-LogInfo "  SET $Path\$Name = $Value"
        return $true
    } catch {
        Write-LogWarning "  SKIP $Path\$Name -- $($_.Exception.Message)"
        return $false
    }
}

function Configure-SupportAssist {
    <#
    Best-effort registry tweaks to make SupportAssist for Home PCs run its
    scheduled scan unattended (auto-consent, weekly cadence). The path layout
    Dell uses has moved more than once -- write to all known locations and
    log misses rather than failing.
    Returns a hashtable @{ KeysWritten = int; TasksEnabled = string[] }.
    #>
    Write-LogSection 'SupportAssist auto-consent + scheduled scan'

    $writes = 0

    # 64-bit + 32-bit (WOW6432Node) views of the same agent settings.
    $agentRoots = @(
        'HKLM:\SOFTWARE\Dell\SupportAssistAgent'
        'HKLM:\SOFTWARE\WOW6432Node\Dell\SupportAssistAgent'
    )
    foreach ($root in $agentRoots) {
        if (Set-RegistrySafe -Path $root -Name 'AutoUpdate'             -Value 1) { $writes++ }
        if (Set-RegistrySafe -Path $root -Name 'ScheduledScanFrequency' -Value 7) { $writes++ }
    }

    $svcRoots = @(
        'HKLM:\SOFTWARE\Dell\SupportAssistAgent\PME\Service'
        'HKLM:\SOFTWARE\WOW6432Node\Dell\SupportAssistAgent\PME\Service'
    )
    foreach ($root in $svcRoots) {
        if (Set-RegistrySafe -Path $root -Name 'DataConsent'      -Value 1) { $writes++ }
        if (Set-RegistrySafe -Path $root -Name 'AnalyticsConsent' -Value 1) { $writes++ }
    }

    $enabled = @()
    $candidateTasks = @(
        'SupportAssistAgent ScheduledTaskMaintenance'
        'SupportAssistAgent WSC'
        'Dell SupportAssistAgent AutoUpdate'
    )
    foreach ($t in $candidateTasks) {
        try {
            $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            if ($task) {
                $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null
                Write-LogInfo "  Enabled scheduled task: $t"
                $enabled += $t
            }
        } catch {
            Write-LogWarning "  Could not enable scheduled task '$t': $($_.Exception.Message)"
        }
    }

    return @{ KeysWritten = $writes; TasksEnabled = $enabled }
}

function Register-WeeklyDcuTask {
    <#
    Registers a weekly SYSTEM-context scheduled task that dot-sources
    core/DellCommandUpdate.ps1 and calls Invoke-DellCommandUpdate. Reuses
    the existing wrapper rather than re-implementing dcu-cli orchestration.
    -Force makes the registration idempotent.
    #>
    param(
        [string]$DayOfWeek = 'Sunday',
        [string]$AtTime    = '03:00'
    )

    $taskName = 'WinDeploy DCU Weekly Sweep'

    # The action invokes powershell.exe with a one-line command. Build it as
    # a single string to keep the argument list simple and predictable in
    # Task Scheduler.
    $dcuPath = Join-Path $WD.RepoDir 'core\DellCommandUpdate.ps1'
    $cmd     = ". '$dcuPath'; Invoke-DellCommandUpdate -InstallIfMissing:`$true | Out-Null"
    $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $AtTime
    $settings  = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable `
                    -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description 'WinDeploy: weekly Dell Command | Update sweep for BIOS, firmware, drivers, and Dell software.' `
        -Force | Out-Null

    Write-LogSuccess "Registered scheduled task '$taskName' -- weekly $DayOfWeek at $AtTime."
    return $taskName
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    if (-not (Test-IsDellHardware)) {
        $mfg = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
        Write-LogInfo "Skipping: system manufacturer is '$mfg', not Dell."
        Set-StageExtraSafe -Key 'Skipped' -Value "non-Dell ($mfg)"
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "Skipped on non-Dell hardware ($mfg)." }
    }

    $stageCfg = @{}
    if ($Config -and $Config['Stages'] -and $Config['Stages'][$StageName]) {
        $stageCfg = $Config['Stages'][$StageName]
    }

    $doSupportAssist = $true
    if ($stageCfg.ContainsKey('ConfigureSupportAssist')) {
        $doSupportAssist = [bool]$stageCfg['ConfigureSupportAssist']
    }

    $doWeeklyTask = $true
    if ($stageCfg.ContainsKey('RegisterWeeklyDcuTask')) {
        $doWeeklyTask = [bool]$stageCfg['RegisterWeeklyDcuTask']
    }

    $weeklyDay = 'Sunday'
    if ($stageCfg['WeeklyDayOfWeek']) { $weeklyDay = [string]$stageCfg['WeeklyDayOfWeek'] }

    $weeklyTime = '03:00'
    if ($stageCfg['WeeklyTime']) { $weeklyTime = [string]$stageCfg['WeeklyTime'] }

    # --- 1) SupportAssist auto-consent (best-effort) ----------------------
    if ($doSupportAssist) {
        try {
            $sa = Configure-SupportAssist
            Set-StageExtraSafe -Key 'SupportAssistKeysWritten' -Value $sa.KeysWritten
            Set-StageExtraSafe -Key 'SupportAssistTasksEnabled' -Value $sa.TasksEnabled
        } catch {
            Write-LogWarning "SupportAssist configuration pass threw: $($_.Exception.Message)"
            Set-StageExtraSafe -Key 'SupportAssistError' -Value $_.Exception.Message
        }
    } else {
        Write-LogInfo 'ConfigureSupportAssist=false -- skipping SupportAssist registry pass.'
    }

    # --- 2) Weekly DCU scheduled task -------------------------------------
    if ($doWeeklyTask) {
        try {
            $taskName = Register-WeeklyDcuTask -DayOfWeek $weeklyDay -AtTime $weeklyTime
            Set-StageExtraSafe -Key 'WeeklyTaskRegistered' -Value $true
            Set-StageExtraSafe -Key 'WeeklyTaskName'       -Value $taskName
            Set-StageExtraSafe -Key 'WeeklyTaskSchedule'   -Value "$weeklyDay $weeklyTime"
        } catch {
            Write-LogError "Weekly DCU task registration failed: $($_.Exception.Message)"
            Set-StageExtraSafe -Key 'WeeklyTaskRegistered' -Value $false
            Set-StageExtraSafe -Key 'WeeklyTaskError'      -Value $_.Exception.Message
            throw
        }
    } else {
        Write-LogInfo 'RegisterWeeklyDcuTask=false -- skipping weekly task registration.'
    }

    Write-LogSuccess "$StageName stage complete."
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = 'Dell update automation configured.' }

} catch {
    Write-LogError "$StageName stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
