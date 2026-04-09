#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Orchestrator - Master controller script.

.DESCRIPTION
    Executed on every boot/logon by the WinDeploy-Resume scheduled task until
    deployment is complete.  It:
      1. Loads the current state.
      2. Skips any stage already marked complete (idempotency).
      3. Runs each pending stage in order.
      4. Handles stage-requested reboots cleanly.
      5. Removes itself (the task) and disables auto-logon when all stages done.

    This script must be robust enough to survive partial runs, crashes, and
    reboots at any point during any stage.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'

# ---------------------------------------------------------------------------
# Early logger - writes to disk before any Import-Module so startup
# failures are always captured even if the logging module cannot load.
# ---------------------------------------------------------------------------
$Script:_rawLog = 'C:\ProgramData\WinDeploy\Logs\early.log'
function Write-Early {
    param([string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    Write-Host $line
    try {
        $dir = Split-Path $Script:_rawLog
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($Script:_rawLog, $line + "`r`n", [System.Text.Encoding]::UTF8)
    } catch { Write-Host "[Orchestrator] Log write failed: $($_.Exception.Message)" }
}
Write-Early "=== $(Split-Path -Leaf $MyInvocation.MyCommand.Path) started (PID $PID) ==="
Write-Early "PSScriptRoot : $PSScriptRoot"
Write-Early "Running as   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Early "ExecutionPolicy: $(Get-ExecutionPolicy)"
   # Prevent any cmdlet from prompting during unattended run

# ---------------------------------------------------------------------------
# Resolve module paths relative to this script's location
# ---------------------------------------------------------------------------
$Script:RepoRoot  = Split-Path $PSScriptRoot -Parent
$Script:CoreDir   = $PSScriptRoot

Write-Early "RepoRoot : $Script:RepoRoot"
Write-Early "CoreDir  : $Script:CoreDir"

try {

# Resilience module first — validates dirs, state, and tasks before anything else
try {
    Import-Module (Join-Path $Script:CoreDir 'Resilience.psm1') -DisableNameChecking -Force
    Write-Early 'Resilience.psm1 loaded OK'
    Invoke-ResilienceChecks -CalledFrom 'Orchestrator' -RepoRoot $Script:RepoRoot
} catch { Write-Early "Resilience.psm1 failed (non-fatal): $($_.Exception.Message)" }

try {
    Import-Module (Join-Path $Script:CoreDir 'Config.psm1') -DisableNameChecking -Force
    $Script:WD = Get-WDConfig
    if (-not $Script:WD) { Write-Early "FATAL: Get-WDConfig returned null"; exit 1 }
    Write-Early 'Config.psm1 loaded OK'
} catch { Write-Early "FATAL: Config.psm1 failed - $($_.Exception.Message)"; exit 1 }

try {
    Import-Module (Join-Path $Script:CoreDir 'State.psm1')   -DisableNameChecking -Force
    Write-Early 'State.psm1 loaded OK'
} catch { Write-Early "FATAL: State.psm1 failed - $($_.Exception.Message)"; exit 1 }

try {
    Import-Module (Join-Path $Script:CoreDir 'Logging.psm1') -DisableNameChecking -Force
    Write-Early 'Logging.psm1 loaded OK'
} catch { Write-Early "FATAL: Logging.psm1 failed - $($_.Exception.Message)"; exit 1 }

# Load webhook notification helper (non-fatal if missing)
$webhookScript = Join-Path $Script:CoreDir 'Notify-Webhook.ps1'
if (Test-Path $webhookScript) { . $webhookScript }

$Script:TASK_NAME = $Script:WD.TaskResume

# Stage map: name → script. Execution order is driven by $WD.StageOrder in State.psm1.
$Script:STAGE_SCRIPTS = [ordered]@{
    PowerSettings            = Join-Path $Script:CoreDir 'PowerSettings.ps1'
    Debloat                  = Join-Path $Script:CoreDir 'Debloat.ps1'
    WinTweaks                = Join-Path $Script:CoreDir 'WinTweaks.ps1'
    InstallDellSupportAssist = Join-Path $Script:CoreDir 'AppInstall.ps1'
    InstallDellPowerManager  = Join-Path $Script:CoreDir 'AppInstall.ps1'
    InstallRustDesk          = Join-Path $Script:CoreDir 'AppInstall.ps1'
    InstallTailscale         = Join-Path $Script:CoreDir 'Tailscale.ps1'
    WindowsUpdate            = Join-Path $Script:CoreDir 'WindowsUpdate.ps1'
    Cleanup                  = Join-Path $Script:CoreDir 'Cleanup.ps1'
}

$Script:REBOOT_ALLOWED_STAGES    = $Script:WD.RebootAllowedStages
$Script:MAX_CONSECUTIVE_FAILURES = 3

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Test-StagePrerequisites {
    <#
    .SYNOPSIS
        Checks prerequisites before running a stage.
    .DESCRIPTION
        Returns $true if the stage may proceed, or a descriptive string
        explaining why it must be skipped.
    #>
    param(
        [string]$StageName,
        [hashtable]$Config
    )

    switch ($StageName) {
        'WindowsUpdate' {
            $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
            if ($freeGB -lt 10) {
                return "Insufficient disk space: ${freeGB}GB free (need 10GB+)"
            }
            try {
                $null = [System.Net.Dns]::GetHostAddresses('www.powershellgallery.com')
            } catch {
                return 'Cannot resolve www.powershellgallery.com - PSGallery unreachable'
            }
        }
        'InstallTailscale' {
            try {
                $null = [System.Net.Dns]::GetHostAddresses('tailscale.com')
            } catch {
                return 'Cannot resolve tailscale.com - no internet connection'
            }
        }
        'InstallDellSupportAssist' {
            $hasInternet = $true
            try {
                $null = [System.Net.Dns]::GetHostAddresses('dl.dell.com')
            } catch {
                $hasInternet = $false
            }
            $hasLocal = $false
            if ($Config -and $Config['Apps'] -and $Config['Apps']['InstallDellSupportAssist']) {
                $localPath = $Config['Apps']['InstallDellSupportAssist']['LocalPath']
                if ($localPath) {
                    $appsDir = Join-Path $Script:RepoRoot 'apps'
                    $fullPath = Join-Path $appsDir $localPath
                    if (Test-Path $fullPath) { $hasLocal = $true }
                    # Also check if it is an absolute path
                    if ((-not $hasLocal) -and (Test-Path $localPath)) { $hasLocal = $true }
                }
            }
            if ((-not $hasInternet) -and (-not $hasLocal)) {
                return 'No internet (dl.dell.com) and no local installer found for Dell SupportAssist'
            }
        }
        'InstallDellPowerManager' {
            $hasInternet = $true
            try {
                $null = [System.Net.Dns]::GetHostAddresses('dl.dell.com')
            } catch {
                $hasInternet = $false
            }
            $hasLocal = $false
            if ($Config -and $Config['Apps'] -and $Config['Apps']['InstallDellPowerManager']) {
                $localPath = $Config['Apps']['InstallDellPowerManager']['LocalPath']
                if ($localPath) {
                    $appsDir = Join-Path $Script:RepoRoot 'apps'
                    $fullPath = Join-Path $appsDir $localPath
                    if (Test-Path $fullPath) { $hasLocal = $true }
                    if ((-not $hasLocal) -and (Test-Path $localPath)) { $hasLocal = $true }
                }
            }
            if ((-not $hasInternet) -and (-not $hasLocal)) {
                return 'No internet (dl.dell.com) and no local installer found for Dell Power Manager'
            }
        }
        'InstallRustDesk' {
            try {
                $null = [System.Net.Dns]::GetHostAddresses('github.com')
            } catch {
                return 'Cannot resolve github.com - RustDesk winget source unreachable'
            }
        }
    }

    return $true
}

function Invoke-Stage {
    <#
    Runs a single stage script, passing -StageName and -Config.
    Returns an exit-code-style hashtable:
        Status  : 'Complete' | 'RebootRequired' | 'Failed'
        Message : string
    #>
    param(
        [string]$StageName,
        [string]$ScriptPath,
        [hashtable]$Config
    )

    Write-LogSection "Running stage: $StageName"

    if (-not (Test-Path $ScriptPath)) {
        return @{ Status = 'Failed'; Message = "Script not found: $ScriptPath" }
    }

    # Resolve per-stage timeout from config (default 60 minutes)
    $timeoutMinutes = 60
    if ($Config -and $Config['Stages']) {
        $stgCfg = $Config['Stages'][$StageName]
        if ($stgCfg -and $stgCfg['TimeoutMinutes']) {
            $timeoutMinutes = [int]$stgCfg['TimeoutMinutes']
        }
    }
    Write-LogInfo "Stage timeout: $timeoutMinutes minutes"

    $stageTimer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Each stage script is a dot-sourced function container.
        # It must expose an Invoke-Stage function and return a hashtable.
        $result = & $ScriptPath -StageName $StageName -Config $Config
        if ($null -eq $result) {
            # Treat missing return as success (backwards compat)
            $result = @{ Status = 'Complete'; Message = 'No return value - assumed complete.' }
        }
    } catch {
        $result = @{
            Status  = 'Failed'
            Message = "Unhandled exception in stage '$StageName': $($_.Exception.Message)"
        }
    }

    $stageTimer.Stop()
    $elapsedMin = [math]::Round($stageTimer.Elapsed.TotalMinutes, 1)
    Write-LogInfo "Stage '$StageName' elapsed time: $elapsedMin minutes"

    if ($elapsedMin -gt $timeoutMinutes) {
        Write-LogWarning "Stage '$StageName' exceeded timeout ($elapsedMin min > $timeoutMinutes min configured)"
    }

    return $result
}

function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $Script:TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Write-LogInfo "Scheduled task '$($Script:TASK_NAME)' removed."
}

function Disable-AutoLogon {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon' -Value '0' -Type String -ErrorAction SilentlyContinue
    # Remove the plaintext password entry entirely
    Remove-ItemProperty -Path $regPath -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPath -Name 'AutoLogonCount' -Value '0' -Type String -ErrorAction SilentlyContinue
    Write-LogInfo 'Auto-logon disabled.'
}

function Invoke-RebootWithReason {
    param([string]$Reason, [int]$DelaySeconds = 15)

    Add-RebootCount
    $state = Get-DeployState
    Write-LogInfo "Rebooting (reboot #$($state.RebootCount)). Reason: $Reason"
    Write-LogInfo "System will restart in $DelaySeconds seconds..."

    Start-Sleep -Seconds $DelaySeconds
    Restart-Computer -Force -Confirm:$false
    # Script ends here - orchestrator will be re-launched by the scheduled task
    exit 0
}

function Load-Config {
    <#
    Reads settings.json from the repo. Falls back to empty hashtable if
    the file doesn't exist so the deployment can still limp forward.
    #>
    $state = Get-DeployState
    $configPath = $state['ConfigFile']

    if (-not (Test-Path $configPath)) {
        Write-LogWarning "Config file not found at '$configPath' - using defaults."
        return @{}
    }

    try {
        $raw = Get-Content -Path $configPath -Raw -Encoding UTF8
        # ConvertFrom-Json returns PSCustomObject; coerce to hashtable
        $obj = $raw | ConvertFrom-Json
        return ConvertTo-Hashtable -InputObject $obj
    } catch {
        Write-LogWarning "Failed to parse config file: $($_.Exception.Message)"
        return @{}
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

Initialize-Logger -Stage 'Orchestrator'

    Write-LogSection 'WinDeploy Orchestrator Started'
    Write-LogInfo "Repo root : $Script:RepoRoot"
    Write-LogInfo "Start time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    # Guard: deployment already finished
    if (Test-DeployComplete) {
        Write-LogSuccess 'Deployment is already complete. Removing scheduled task and exiting.'
        Remove-ResumeTask
        Disable-AutoLogon
        Close-Logger -FinalStatus 'SUCCESS'
        exit 0
    }

    # Load config once
    $config = Load-Config

    # Load webhook config
    $webhookUrl = ''
    $notifyConfig = @{}
    if ($config['Notifications']) {
        $notifyConfig = $config['Notifications']
        $webhookUrl = $notifyConfig['Webhook']
    }

    # Send start notification
    if ($webhookUrl -and $notifyConfig['OnStart'] -ne $false) {
        Send-DeployNotification -WebhookUrl $webhookUrl -Event 'Start' `
            -MachineName $env:COMPUTERNAME -Message "Starting deployment pipeline."
    }

    # Print current stage summary
    Write-LogSection 'Stage Status Summary'
    Get-StageStatus | ForEach-Object {
        Write-LogInfo ("  {0,-30} {1}" -f $_.Stage, $_.Status)
    }

    # ---------------------------------------------------------------------------
    # Main stage loop
    # ---------------------------------------------------------------------------
    $consecutiveFailures = 0

    foreach ($stageName in $Script:STAGE_SCRIPTS.Keys) {
        $scriptPath = $Script:STAGE_SCRIPTS[$stageName]

        # Skip completed stages
        if (Test-StageComplete -StageName $stageName) {
            Write-LogInfo "Stage '$stageName' already complete - skipping."
            continue
        }

        # Pre-stage health checks
        $prereqResult = Test-StagePrerequisites -StageName $stageName -Config $config
        if ($prereqResult -ne $true) {
            Write-LogWarning "Skipping '$stageName': $prereqResult"
            Set-StageComplete -StageName $stageName -Message "Skipped: $prereqResult"
            continue
        }

        # Run the stage
        Write-LogInfo "--- Starting stage: $stageName ---"
        $result = Invoke-Stage -StageName $stageName -ScriptPath $scriptPath -Config $config

        # Validate result — stage must return @{ Status = '...'; Message = '...' }
        if ($null -eq $result -or $result -isnot [hashtable] -or -not $result.ContainsKey('Status')) {
            $resultType = if ($null -eq $result) { 'null' } else { $result.GetType().Name }
            Write-LogError "Stage '$stageName' returned invalid result (type: $resultType). Expected hashtable with 'Status' key."
            $result = @{ Status = 'Failed'; Message = "Invalid stage return value (type: $resultType)" }
        }

        switch ($result.Status) {

            'Complete' {
                Set-StageComplete -StageName $stageName
                Write-LogSuccess "Stage '$stageName' completed successfully."
                $consecutiveFailures = 0
            }

            'RebootRequired' {
                Set-StageComplete -StageName $stageName
                Write-LogInfo "Stage '$stageName' complete - reboot requested."
                if ($stageName -in $Script:REBOOT_ALLOWED_STAGES) {
                    Invoke-RebootWithReason -Reason $result.Message
                    # ^ does not return
                } else {
                    Write-LogWarning "Stage '$stageName' requested reboot but is not in REBOOT_ALLOWED_STAGES. Continuing."
                }
            }

            'Failed' {
                $consecutiveFailures++
                Write-StateError -StageName $stageName -ErrorMessage $result.Message
                Write-LogError "Stage '$stageName' FAILED: $($result.Message)"
                Write-LogError "Consecutive failures: $consecutiveFailures / $Script:MAX_CONSECUTIVE_FAILURES"

                # Webhook: stage failure notification
                if ($webhookUrl -and $notifyConfig['OnStageFailure'] -ne $false) {
                    Send-DeployNotification -WebhookUrl $webhookUrl -Event 'StageFailure' `
                        -MachineName $env:COMPUTERNAME -StageName $stageName `
                        -Message $result.Message -ErrorDetail $result.Message
                }

                if ($consecutiveFailures -ge $Script:MAX_CONSECUTIVE_FAILURES) {
                    Write-LogError 'Maximum consecutive failures reached. Aborting deployment.'
                    Write-LogError 'Review logs at C:\ProgramData\WinDeploy\Logs and fix the issue.'
                    Write-LogError 'Re-run Orchestrator.ps1 manually once the issue is resolved.'
                    Close-Logger -FinalStatus 'FAILED'
                    exit 1
                }

                # Check if the stage allows retry-on-failure (config-driven)
                $stageConfig = if ($config['Stages'] -and $config['Stages'][$stageName]) {
                    $config['Stages'][$stageName]
                } else { @{} }

                if ($stageConfig['ContinueOnError'] -eq $true) {
                    Write-LogWarning "ContinueOnError=true for '$stageName' - proceeding to next stage."
                    # Mark complete anyway so we don't loop forever
                    Set-StageComplete -StageName $stageName
                } else {
                    Write-LogError "Halting until the failure is resolved. Reboot will retry this stage."
                    Close-Logger -FinalStatus 'FAILED'
                    exit 1
                }
            }

            default {
                Write-LogWarning "Stage '$stageName' returned unexpected status: '$($result.Status)'. Treating as complete."
                Set-StageComplete -StageName $stageName
            }
        }
    }

    # ---------------------------------------------------------------------------
    # All stages complete
    # ---------------------------------------------------------------------------
    Set-DeployComplete
    Write-LogSection 'ALL STAGES COMPLETE'

    # Webhook: completion notification
    if ($webhookUrl -and $notifyConfig['OnComplete'] -ne $false) {
        Send-DeployNotification -WebhookUrl $webhookUrl -Event 'Complete' `
            -MachineName $env:COMPUTERNAME -Message "All stages finished."
    }

    $elapsed = (Get-Date) - [datetime](Get-DeployState)['BootstrappedAt']
    Write-LogSuccess "Total deployment time: $([Math]::Round($elapsed.TotalMinutes, 1)) minutes"

    # Final cleanup
    Remove-ResumeTask
    Disable-AutoLogon

    Close-Logger -FinalStatus 'SUCCESS'
    exit 0

} catch {
    Write-Early "ORCHESTRATOR FATAL: $($_.Exception.Message)"
    Write-Early "Line: $($_.InvocationInfo.ScriptLineNumber)"
    exit 1
}
