#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Cleanup

.DESCRIPTION
    Final stage. Removes the resume scheduled task, disables auto-logon,
    writes a deployment completion report, and optionally reboots one
    last time for a clean start state.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'Cleanup',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'   # Prevent any cmdlet from prompting during unattended run

$coreDir  = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'State.psm1')   -DisableNameChecking -Force

Initialize-Logger -Stage $StageName

$TASK_NAME = 'WinDeploy-Resume'

function Write-CompletionReport {
    $state    = Get-DeployState
    $logDir   = 'C:\ProgramData\WinDeploy\Logs'
    $report   = Join-Path $logDir 'completion_report.txt'

    $lines = @(
        '=' * 60
        '  WinDeploy - Deployment Completion Report'
        '=' * 60
        ''
        "  Bootstrapped At : $($state['BootstrappedAt'])"
        "  Completed At    : $(Get-Date -Format 'o')"
        "  Reboot Count    : $($state['RebootCount'])"
        ''
        '  Stage Results:'
    )

    Get-StageStatus | ForEach-Object {
        $lines += "    {0,-32} {1}" -f $_.Stage, $_.Status
    }

    if ($state['FailedStages'] -and @($state['FailedStages']).Count -gt 0) {
        $lines += ''
        $lines += '  Stages with errors (check logs):'
        foreach ($s in $state['FailedStages']) {
            $lines += "    - $s"
        }
    }

    $lines += ''
    $lines += "  Log directory: $logDir"
    $lines += '=' * 60

    $lines | Set-Content -Path $report -Encoding UTF8

    Write-LogInfo "Completion report written to: $report"
    $lines | ForEach-Object { Write-LogInfo $_ }
}

try {
    Write-LogInfo "Stage '$StageName' starting."

    # Remove resume task
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Write-LogSuccess "Scheduled task '$TASK_NAME' removed."

    # Remove monitor task - it auto-closes its own window when DeployComplete = true,
    # but we also unregister the task so it doesn't re-launch after the final reboot
    Unregister-ScheduledTask -TaskName 'WinDeploy-Monitor' -Confirm:$false -ErrorAction SilentlyContinue
    Write-LogSuccess "Scheduled task 'WinDeploy-Monitor' removed."

    # Disable auto-logon
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $regPath 'AutoAdminLogon'  '0'    -Type String -ErrorAction SilentlyContinue
    Remove-ItemProperty $regPath 'DefaultPassword'     -ErrorAction SilentlyContinue
    Set-ItemProperty $regPath 'AutoLogonCount'  '0'    -Type String -ErrorAction SilentlyContinue
    Write-LogSuccess 'Auto-logon disabled.'

    # Write completion report
    Write-CompletionReport

    # Final reboot (optional - set FinalReboot = false in config to skip)
    $finalReboot = if ($Config['Cleanup'] -and $Config['Cleanup']['FinalReboot'] -eq $false) {
        $false
    } else { $true }

    Write-LogSuccess 'Cleanup complete. Deployment finished successfully.'
    Close-Logger -FinalStatus 'SUCCESS'

    if ($finalReboot) {
        return @{ Status = 'RebootRequired'; Message = 'Final cleanup reboot.' }
    }
    return @{ Status = 'Complete'; Message = 'Deployment complete.' }

} catch {
    Write-LogError "Cleanup stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
