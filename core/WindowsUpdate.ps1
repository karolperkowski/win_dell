#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Windows Update

.DESCRIPTION
    Installs all available Windows Updates using the PSWindowsUpdate module.
    Handles multiple reboot cycles automatically - the stage returns
    'RebootRequired' to the orchestrator whenever a reboot is needed, and
    re-evaluates pending updates when it runs again after that reboot.

    The stage is idempotent: if called again after completion it returns
    'Complete' immediately via the orchestrator's Test-StageComplete check.

.PARAMETER StageName
    Passed by the Orchestrator. Must be 'WindowsUpdate'.

.PARAMETER Config
    Hashtable loaded from settings.json.

.RETURNS
    Hashtable: @{ Status = 'Complete'|'RebootRequired'|'Failed'; Message = string }
#>

[CmdletBinding()]
param(
    [string]$StageName = 'WindowsUpdate',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'   # Prevent any cmdlet from prompting during unattended run

# ---------------------------------------------------------------------------
# Import shared modules
# ---------------------------------------------------------------------------
$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'State.psm1')   -DisableNameChecking -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Constants and defaults
# ---------------------------------------------------------------------------
$Script:MAX_UPDATE_CYCLES   = 5    # Safety cap on update+reboot loops
$Script:NUGET_MIN_VERSION   = [Version]'2.8.5.201'
$Script:WU_MODULE_NAME      = 'PSWindowsUpdate'
$Script:WU_CYCLE_STATE_KEY  = 'WindowsUpdate_CycleCount'   # stored in state extras

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Test-PSGalleryReachable {
    Write-LogInfo 'Pre-flight: checking PSGallery connectivity...'
    try {
        $resp = Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2' `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            Write-LogSuccess 'PSGallery is reachable.'
            return $true
        }
    } catch {
        Write-LogWarning "PSGallery connectivity check failed: $($_.Exception.Message)"
    }
    return $false
}

function Install-NuGetProvider {
    Write-LogInfo 'Checking NuGet package provider...'
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt $Script:NUGET_MIN_VERSION) {
        Write-LogInfo 'Installing NuGet provider...'
        Install-PackageProvider -Name NuGet -MinimumVersion $Script:NUGET_MIN_VERSION `
            -Force -Scope AllUsers | Out-Null
        Write-LogSuccess 'NuGet provider installed.'
    } else {
        Write-LogInfo "NuGet provider OK ($($nuget.Version))."
    }
}

function Install-WUModule {
    Write-LogInfo "Checking $Script:WU_MODULE_NAME module..."
    $mod = Get-Module -ListAvailable -Name $Script:WU_MODULE_NAME |
           Sort-Object Version -Descending | Select-Object -First 1

    if (-not $mod) {
        Write-LogInfo "Installing $Script:WU_MODULE_NAME from PSGallery..."
        Install-Module -Name $Script:WU_MODULE_NAME -Force -Scope AllUsers `
            -AllowClobber -SkipPublisherCheck | Out-Null
        Write-LogSuccess "$Script:WU_MODULE_NAME installed."
    } else {
        Write-LogInfo "$Script:WU_MODULE_NAME already present (v$($mod.Version))."
    }

    Import-Module $Script:WU_MODULE_NAME -Force
}

function Get-PendingUpdateList {
    <#
    Returns an array of pending Windows Update objects.
    Does NOT install them - this is a query-only operation.
    #>
    Write-LogInfo 'Querying pending Windows Updates (this may take a few minutes)...'
    try {
        $updates = Get-WindowsUpdate -ErrorAction Stop
        return $updates
    } catch {
        Write-LogWarning "Get-WindowsUpdate query failed: $($_.Exception.Message)"
        return @()
    }
}

function Install-PendingUpdates {
    <#
    Installs all pending updates silently. Returns $true if a reboot is needed.
    #>
    param([array]$UpdateList)

    if (@($UpdateList).Count -eq 0) {
        Write-LogInfo 'No updates to install.'
        return $false
    }

    Write-LogInfo "Installing $(@($UpdateList).Count) update(s)..."
    foreach ($u in $UpdateList) {
        Write-LogInfo "  -> $($u.KB) : $($u.Title)"
    }

    try {
        $result = Install-WindowsUpdate `
            -AcceptAll `
            -AutoReboot:$false `
            -IgnoreReboot `
            -Confirm:$false `
            -NotTitle 'Preview' `
            -ErrorAction Stop

        $rebootRequired = $result | Where-Object { $_.RebootRequired -eq $true }
        if ($rebootRequired) {
            Write-LogInfo "$((@($rebootRequired) | Measure-Object).Count) update(s) require a reboot."
            return $true
        }
        return $false
    } catch {
        Write-LogError "Install-WindowsUpdate failed: $($_.Exception.Message)"
        throw
    }
}

function Test-RebootPending {
    <#
    Multi-source reboot-pending check. Returns $true if any source indicates
    a reboot is waiting.
    #>
    $reasons = @()

    # Source 1: Windows Update service flag
    $wuReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (Test-Path $wuReg) { $reasons += 'WindowsUpdate registry key' }

    # Source 2: Pending file rename operations
    $pfro = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pfroVal = (Get-ItemProperty -Path $pfro -Name 'PendingFileRenameOperations' `
                    -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfroVal) { $reasons += 'PendingFileRenameOperations' }

    # Source 3: Component-Based Servicing
    $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if (Test-Path $cbsKey) { $reasons += 'CBS RebootPending' }

    if (@($reasons).Count -gt 0) {
        Write-LogInfo "Reboot pending detected via: $($reasons -join ', ')"
        return $true
    }
    return $false
}

function Get-UpdateCycleCount {
    $state = Get-DeployState
    $extras = $state['StageExtras']
    if ($extras -and $extras[$Script:WU_CYCLE_STATE_KEY]) {
        return [int]$extras[$Script:WU_CYCLE_STATE_KEY]
    }
    return 0
}

function Increment-UpdateCycleCount {
    $state = Get-DeployState
    if (-not $state['StageExtras']) { $state['StageExtras'] = @{} }
    $count = 1
    if ($state['StageExtras'][$Script:WU_CYCLE_STATE_KEY]) {
        $count = [int]$state['StageExtras'][$Script:WU_CYCLE_STATE_KEY] + 1
    }
    $state['StageExtras'][$Script:WU_CYCLE_STATE_KEY] = $count
    Save-DeployState -State $state
    return $count
}

# ---------------------------------------------------------------------------
# Main stage logic
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    # Pre-flight: verify PSGallery is reachable before attempting module installs
    if (-not (Test-PSGalleryReachable)) {
        Write-LogError 'PSGallery is unreachable. Cannot install NuGet provider or PSWindowsUpdate module.'
        Write-LogError 'Check internet connectivity and DNS resolution, then re-run.'
        Close-Logger -FinalStatus 'FAILED'
        return @{ Status = 'Failed'; Message = 'PSGallery unreachable - check internet connectivity.' }
    }

    # Step 1 - Set up NuGet + WU module
    Install-NuGetProvider
    Install-WUModule

    # Step 2 - Check the cycle counter (guards against infinite reboot loop)
    $cycleCount = Get-UpdateCycleCount
    Write-LogInfo "Update cycle count: $cycleCount / $Script:MAX_UPDATE_CYCLES"

    if ($cycleCount -ge $Script:MAX_UPDATE_CYCLES) {
        Write-LogWarning "Maximum update cycles ($Script:MAX_UPDATE_CYCLES) reached."
        Write-LogWarning 'Some updates may still be pending, but continuing deployment.'
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "Max update cycles reached ($cycleCount)." }
    }

    # Step 3 - Query pending updates
    $pending = Get-PendingUpdateList
    Write-LogInfo "Pending updates found: $(@($pending).Count)"

    if (@($pending).Count -eq 0) {
        # Verify with the registry as well
        if (Test-RebootPending) {
            Write-LogInfo 'No new updates but system reboot is still pending from a previous cycle.'
            $null = Increment-UpdateCycleCount
            Close-Logger -FinalStatus 'SUCCESS'
            return @{ Status = 'RebootRequired'; Message = 'Pending reboot from previous update cycle.' }
        }

        Write-LogSuccess 'No pending updates found. Windows Update stage complete.'
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = 'All Windows Updates applied.' }
    }

    # Step 4 - Install
    $rebootNeeded = Install-PendingUpdates -UpdateList $pending
    $newCycle     = Increment-UpdateCycleCount

    Write-LogInfo "Installed $(@($pending).Count) update(s). Reboot needed: $rebootNeeded"

    if ($rebootNeeded -or (Test-RebootPending)) {
        Write-LogInfo "Reboot required after update cycle $newCycle."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'RebootRequired'; Message = "Reboot required after installing $(@($pending).Count) update(s). Cycle: $newCycle." }
    }

    # No reboot needed - check if more updates appeared (chained updates)
    $nextPending = Get-PendingUpdateList
    if (@($nextPending).Count -gt 0) {
        Write-LogInfo "$(@($nextPending).Count) additional update(s) found after first pass - will handle on next orchestrator run."
        Close-Logger -FinalStatus 'SUCCESS'
        # Don't mark stage complete - orchestrator will re-run it
        return @{ Status = 'RebootRequired'; Message = "More updates found: $(@($nextPending).Count) - re-running." }
    }

    Write-LogSuccess 'Windows Update complete - no reboot required, no further updates pending.'
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = 'All Windows Updates applied. No reboot required.' }

} catch {
    Write-LogError "Windows Update stage failed: $($_.Exception.Message)"
    Write-LogError "Line: $($_.InvocationInfo.ScriptLineNumber)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
