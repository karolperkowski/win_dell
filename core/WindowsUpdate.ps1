#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Windows Update.

.DESCRIPTION
    Drives the native Windows Update Agent COM API (Microsoft.Update.Session
    + Microsoft.Update.ServiceManager) to detect, download, and install all
    pending updates. Two searches are issued and merged:

      - Software updates via the Microsoft Update service (so Office, .NET,
        and other MS-published software are in scope).
      - Driver updates via the default Windows Update service. The Microsoft
        Update service catalog rejects Type='Driver' criteria with
        WU_E_INVALID_CRITERIA (0x80240032), so drivers must come from the
        default WU service.

    Either search will retry with progressively narrower criteria on
    WU_E_INVALID_CRITERIA and record the criteria that finally worked into
    StageExtras (WindowsUpdate_ComScanCriteriaUsed). Driver-search failure
    is non-fatal - we log a warning and proceed with software-only.

    After the WUA drain reports zero pending, the stage invokes Dell Command
    | Update (DCU) for OEM BIOS / firmware / driver updates that don't flow
    through Microsoft Update.

    Reboots: the stage never reboots directly. On RebootRequired it returns
    to the orchestrator which handles the reboot. The orchestrator marks
    WindowsUpdate as a DRAIN stage (Config.psm1 $Script:DRAIN_STAGES) - every
    subsequent boot re-runs this script so late-cascading updates (servicing
    stack -> cumulative -> .NET -> drivers) are caught.

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
$ConfirmPreference     = 'None'

# ---------------------------------------------------------------------------
# Module imports
# ---------------------------------------------------------------------------
$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'State.psm1')   -DisableNameChecking -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Settings from $Config (= $config['Stages']['WindowsUpdate'] in settings.json)
# ---------------------------------------------------------------------------
$Script:MAX_UPDATE_CYCLES      = 8
$Script:INCLUDE_MS_UPDATE      = $true
$Script:INCLUDE_DRIVERS        = $true
$Script:INCLUDE_OPTIONAL       = $true
$Script:RUN_DCU                = $true
$Script:INSTALL_DCU_IF_MISSING = $true

if ($Config['MaxCycles']) { $Script:MAX_UPDATE_CYCLES = [int]$Config['MaxCycles'] }
if ($Config.ContainsKey('IncludeMicrosoftUpdate')) { $Script:INCLUDE_MS_UPDATE      = [bool]$Config['IncludeMicrosoftUpdate'] }
if ($Config.ContainsKey('IncludeDrivers'))         { $Script:INCLUDE_DRIVERS        = [bool]$Config['IncludeDrivers'] }
if ($Config.ContainsKey('IncludeOptional'))        { $Script:INCLUDE_OPTIONAL       = [bool]$Config['IncludeOptional'] }
if ($Config.ContainsKey('RunDellCommandUpdate'))   { $Script:RUN_DCU                = [bool]$Config['RunDellCommandUpdate'] }
if ($Config.ContainsKey('InstallDellCommandUpdateIfMissing')) {
    $Script:INSTALL_DCU_IF_MISSING = [bool]$Config['InstallDellCommandUpdateIfMissing']
}

# Microsoft Update service GUID. Stable across all supported Windows versions.
$Script:MS_UPDATE_SERVICE_ID = '7971f918-a847-4430-9279-4a52d1efe18d'
$Script:WU_CYCLE_STATE_KEY   = 'WindowsUpdate_CycleCount'
$Script:CHUNK_SIZE           = 50

# ServerSelection enum (IUpdateSearcher.ServerSelection)
$Script:SS_DEFAULT        = 0
$Script:SS_MANAGED_SERVER = 1
$Script:SS_WINDOWS_UPDATE = 2
$Script:SS_OTHERS         = 3

# Known WU HResult codes -> human-readable strings. Keys are strings (the
# formatted hex) so we don't fight Int32 overflow on values with the high bit set.
# Source: https://learn.microsoft.com/windows/win32/wua_sdk/wua-success-and-error-codes-
$Script:WU_HRESULT_MEANINGS = @{
    '0x00000000' = 'Success'
    '0x00240001' = 'Reboot required (informational)'
    '0x80240020' = 'WU_E_NO_INTERACTIVE_USER - operation requires an interactive user.'
    '0x80240032' = "WU_E_INVALID_CRITERIA - search criteria rejected by service (often Type='Driver' against Microsoft Update; query default WU instead)."
    '0x80240438' = 'WU_E_NO_CONNECTION - WU agent could not reach a source.'
    '0x8024D007' = 'WU_E_SETUP_WUSERVICE_NOT_STOPPED - wuauserv was not stopped before update.'
    '0x8024200B' = 'WU_E_INSTALL_FAILURE - install command failed; see WindowsUpdate.log.'
    '0x80240024' = 'WU_E_NO_UPDATE - no applicable update found.'
    '0x80240017' = 'WU_E_NOT_APPLICABLE - update is not applicable to the system.'
    '0x8024401C' = 'WU_E_PT_HTTP_STATUS_REQ_TIMEOUT - source request timed out.'
    '0x8024A005' = 'WU_E_AU_NO_REGISTERED_SERVICE - no service is registered with AU.'
}
$Script:WU_E_INVALID_CRITERIA = '0x80240032'

function Format-WUHResult {
    param([Parameter(Mandatory)][int]$HResult)
    $hex = '0x{0:X8}' -f $HResult
    if ($Script:WU_HRESULT_MEANINGS.ContainsKey($hex)) {
        return "$hex ($($Script:WU_HRESULT_MEANINGS[$hex]))"
    }
    return $hex
}

# ---------------------------------------------------------------------------
# Cycle counter - persisted across reboots so the drain stage knows when to
# give up.
# ---------------------------------------------------------------------------
function Get-UpdateCycleCount {
    $state = Get-DeployState
    $extras = $state['StageExtras']
    if ($extras -and $extras[$Script:WU_CYCLE_STATE_KEY]) {
        return [int]$extras[$Script:WU_CYCLE_STATE_KEY]
    }
    return 0
}

function Add-UpdateCycleCount {
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
# Reboot-pending detection (multi-source registry probe)
# ---------------------------------------------------------------------------
function Test-RebootPending {
    $reasons = @()

    $wuReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (Test-Path $wuReg) { $reasons += 'WindowsUpdate registry key' }

    $pfro = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pfroVal = $null
    try {
        $pfroVal = Get-ItemPropertyValue -Path $pfro -Name 'PendingFileRenameOperations' -ErrorAction Stop
    } catch { $pfroVal = $null }
    if ($pfroVal) { $reasons += 'PendingFileRenameOperations' }

    $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if (Test-Path $cbsKey) { $reasons += 'CBS RebootPending' }

    if (@($reasons).Count -gt 0) {
        Write-LogInfo "Reboot pending: $($reasons -join ', ')"
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Native WUA COM helpers
# ---------------------------------------------------------------------------
function Register-MicrosoftUpdateService {
    <#
    Adds the Microsoft Update service to the local update agent. Idempotent.
    Returns $true if the service is registered after the call, else $false.
    #>
    if (-not $Script:INCLUDE_MS_UPDATE) {
        Write-LogInfo 'IncludeMicrosoftUpdate=false - leaving service registration alone.'
        return $false
    }

    try {
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $already = $false
        foreach ($svc in $sm.Services) {
            if ($svc.ServiceID -eq $Script:MS_UPDATE_SERVICE_ID) {
                $already = $true
                break
            }
        }
        if ($already) {
            Write-LogInfo 'Microsoft Update service already registered.'
            return $true
        }
        # Flag 7 = AsfAllowOnlineRegistration | AsfAllowPendingRegistration |
        # AsfRegisterServiceWithAU. Empty authorizationCabPath uses bundled cab.
        $null = $sm.AddService2($Script:MS_UPDATE_SERVICE_ID, 7, '')
        Write-LogSuccess 'Microsoft Update service registered.'
        return $true
    } catch {
        Write-LogWarning "Microsoft Update service registration failed: $($_.Exception.Message)"
        return $false
    }
}

function New-WuaSession {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'WinDeploy'
    return $session
}

function Get-ComExceptionHexHResult {
    # Pulls the HResult from a caught exception and formats it the same way
    # as Format-WUHResult so it matches WU_HRESULT_MEANINGS keys.
    param([Parameter(Mandatory)]$ErrorRecord)
    $hr = 0
    try { $hr = [int]$ErrorRecord.Exception.HResult } catch { $hr = 0 }
    return ('0x{0:X8}' -f $hr)
}

function Search-Updates {
    <#
    Runs a single WUA search with criteria-narrowing retry on
    WU_E_INVALID_CRITERIA (0x80240032). Tries each entry of $CriteriaLadder
    in order; first non-INVALID_CRITERIA result wins (success or any other
    error). Returns @{ Updates; HResult; CriteriaUsed; Error }.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$ServerSelection,
        [string]$ServiceId,
        [Parameter(Mandatory)][string[]]$CriteriaLadder,
        [Parameter(Mandatory)][string]$Label
    )

    $lastHex      = $Script:WU_E_INVALID_CRITERIA
    $lastCriteria = $CriteriaLadder[-1]
    $lastError    = "All narrowed criteria still returned WU_E_INVALID_CRITERIA"

    foreach ($criteria in $CriteriaLadder) {
        $lastCriteria = $criteria
        try {
            $searcher = $Session.CreateUpdateSearcher()
            $searcher.ServerSelection = $ServerSelection
            if ($ServiceId) {
                $searcher.ServiceID = $ServiceId
            }
            Write-LogInfo "  [$Label] criteria: $criteria"
            $result = $searcher.Search($criteria)
            return @{
                Updates      = $result.Updates
                HResult      = '0x00000000'
                CriteriaUsed = $criteria
                Error        = $null
            }
        } catch {
            $lastHex   = Get-ComExceptionHexHResult -ErrorRecord $_
            $lastError = $_.Exception.Message
            if ($lastHex -eq $Script:WU_E_INVALID_CRITERIA) {
                Write-LogWarning "  [$Label] WU_E_INVALID_CRITERIA on '$criteria' - narrowing"
                continue
            }
            Write-LogError "  [$Label] search failed ($lastHex): $lastError"
            return @{
                Updates      = $null
                HResult      = $lastHex
                CriteriaUsed = $criteria
                Error        = $lastError
            }
        }
    }
    return @{
        Updates      = $null
        HResult      = $lastHex
        CriteriaUsed = $lastCriteria
        Error        = $lastError
    }
}

function Get-PendingViaCOM {
    <#
    Issues up to two searches (Software via MU when enabled, Drivers via
    default WU when INCLUDE_DRIVERS), merges deduped results, and applies
    the IncludeOptional filter. Returns @{ Updates; Count; Error }.

    On hard failure (software search broken): @{ Updates=$null; Count=-1; Error=... }.
    Driver-search failure is non-fatal: warn + proceed with software-only.
    #>
    Write-LogInfo 'Scanning for updates via Windows Update Agent COM API...'

    try {
        $session = New-WuaSession
    } catch {
        $hex = Get-ComExceptionHexHResult -ErrorRecord $_
        return @{ Updates = $null; Count = -1; Error = "Could not create Microsoft.Update.Session ($hex): $($_.Exception.Message)" }
    }

    $merged       = New-Object -ComObject Microsoft.Update.UpdateColl
    $seen         = @{}
    $criteriaUsed = @{}

    # ---- Software search ----------------------------------------------------
    if ($Script:INCLUDE_MS_UPDATE) {
        $softSel   = $Script:SS_OTHERS
        $softSvc   = $Script:MS_UPDATE_SERVICE_ID
        $softLabel = 'Software via Microsoft Update'
    } else {
        $softSel   = $Script:SS_WINDOWS_UPDATE
        $softSvc   = $null
        $softLabel = 'Software via Windows Update'
    }
    $softLadder = @(
        "IsInstalled=0 and IsHidden=0 and Type='Software'",
        "IsInstalled=0 and IsHidden=0",
        "IsInstalled=0"
    )
    $softRes = Search-Updates -Session $session -ServerSelection $softSel `
        -ServiceId $softSvc -CriteriaLadder $softLadder -Label $softLabel

    if (-not $softRes.Updates) {
        Set-StageExtra -StageName $StageName -Key 'WindowsUpdate_ComScanHResult'  -Value $softRes.HResult
        Set-StageExtra -StageName $StageName -Key 'WindowsUpdate_ComScanCriteria' -Value $softRes.CriteriaUsed
        $msg = "$softLabel failed: $(Format-WUHResult ([int][Convert]::ToInt32($softRes.HResult.Substring(2), 16))) - $($softRes.Error)"
        return @{ Updates = $null; Count = -1; Error = $msg }
    }
    $criteriaUsed['Software'] = $softRes.CriteriaUsed
    for ($i = 0; $i -lt $softRes.Updates.Count; $i++) {
        $u  = $softRes.Updates.Item($i)
        $id = $u.Identity.UpdateID
        if (-not $seen.ContainsKey($id)) {
            $null = $merged.Add($u)
            $seen[$id] = $true
        }
    }
    Write-LogInfo "  [$softLabel] returned $($softRes.Updates.Count) update(s)."

    # ---- Driver search ------------------------------------------------------
    # MU service catalog rejects Type='Driver' with WU_E_INVALID_CRITERIA, so
    # drivers always come from the default Windows Update service.
    if ($Script:INCLUDE_DRIVERS) {
        $drvLadder = @(
            "IsInstalled=0 and IsHidden=0 and Type='Driver'",
            "IsInstalled=0 and Type='Driver'"
        )
        $drvRes = Search-Updates -Session $session -ServerSelection $Script:SS_WINDOWS_UPDATE `
            -ServiceId $null -CriteriaLadder $drvLadder -Label 'Drivers via Windows Update'

        if ($drvRes.Updates) {
            $criteriaUsed['Driver'] = $drvRes.CriteriaUsed
            $added = 0
            for ($i = 0; $i -lt $drvRes.Updates.Count; $i++) {
                $u  = $drvRes.Updates.Item($i)
                $id = $u.Identity.UpdateID
                if (-not $seen.ContainsKey($id)) {
                    $null = $merged.Add($u)
                    $seen[$id] = $true
                    $added++
                }
            }
            Write-LogInfo "  [Drivers via Windows Update] returned $($drvRes.Updates.Count) update(s); $added newly merged."
        } else {
            Write-LogWarning "Driver search failed ($($drvRes.HResult)): $($drvRes.Error). Proceeding software-only; DCU runs after drain."
            Set-StageExtra -StageName $StageName -Key 'WindowsUpdate_DriverScanHResult'  -Value $drvRes.HResult
            Set-StageExtra -StageName $StageName -Key 'WindowsUpdate_DriverScanCriteria' -Value $drvRes.CriteriaUsed
        }
    }

    Set-StageExtra -StageName $StageName -Key 'WindowsUpdate_ComScanCriteriaUsed' -Value $criteriaUsed

    # ---- Optional filter ----------------------------------------------------
    if (-not $Script:INCLUDE_OPTIONAL) {
        $filtered = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $merged.Count; $i++) {
            $u = $merged.Item($i)
            if ($u.AutoSelectOnWebSites) { $null = $filtered.Add($u) }
        }
        $dropped = $merged.Count - $filtered.Count
        if ($dropped -gt 0) {
            Write-LogInfo "Filtered out $dropped optional update(s) (IncludeOptional=false)."
        }
        return @{ Updates = $filtered; Count = $filtered.Count; Error = $null }
    }

    return @{ Updates = $merged; Count = $merged.Count; Error = $null }
}

function Install-ViaCOM {
    <#
    Downloads + installs the given IUpdateCollection in chunks. Returns
    @{ Installed = array; RebootRequired = bool; Error = string? }.
    Each Installed record: @{ KB; Title; HResult; RebootRequired }.
    #>
    param([Parameter(Mandatory)]$Updates)

    $records        = @()
    $rebootRequired = $false
    $session        = New-WuaSession

    $total = $Updates.Count
    if ($total -eq 0) {
        return @{ Installed = @(); RebootRequired = $false; Error = $null }
    }

    Write-LogInfo "Preparing $total update(s) in chunks of $Script:CHUNK_SIZE."
    for ($start = 0; $start -lt $total; $start += $Script:CHUNK_SIZE) {
        $end = [Math]::Min($start + $Script:CHUNK_SIZE - 1, $total - 1)

        $chunk = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = $start; $i -le $end; $i++) {
            $u = $Updates.Item($i)
            if (-not $u.EulaAccepted) {
                try { $u.AcceptEula() } catch {
                    Write-LogWarning "EULA accept failed for '$($u.Title)': $($_.Exception.Message)"
                }
            }
            $null = $chunk.Add($u)
            $kb = ''
            try {
                if ($u.KBArticleIDs.Count -gt 0) { $kb = 'KB' + $u.KBArticleIDs.Item(0) }
            } catch { $kb = '' }
            Write-LogInfo "  queued: $kb $($u.Title)"
        }

        # Download chunk
        try {
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $chunk
            Write-LogInfo "Downloading chunk $($start + 1)-$($end + 1) of $total..."
            $dlResult = $downloader.Download()
            Write-LogInfo "  download result: $(Format-WUHResult ([int]$dlResult.HResult))"
        } catch {
            return @{
                Installed      = $records
                RebootRequired = $rebootRequired
                Error          = "Downloader.Download() threw: $($_.Exception.Message)"
            }
        }

        # Pick downloaded items for install
        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $chunk.Count; $i++) {
            if ($chunk.Item($i).IsDownloaded) { $null = $toInstall.Add($chunk.Item($i)) }
        }
        if ($toInstall.Count -eq 0) {
            Write-LogWarning 'No updates from this chunk are downloaded - skipping install for chunk.'
            continue
        }

        # Install chunk
        try {
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $toInstall
            Write-LogInfo "Installing $($toInstall.Count) update(s) from chunk..."
            $instResult = $installer.Install()
            Write-LogInfo "  install result: $(Format-WUHResult ([int]$instResult.HResult))"
            if ($instResult.RebootRequired) { $rebootRequired = $true }
        } catch {
            return @{
                Installed      = $records
                RebootRequired = $rebootRequired
                Error          = "Installer.Install() threw: $($_.Exception.Message)"
            }
        }

        # Per-update records
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            $u = $toInstall.Item($i)
            $uRes = $instResult.GetUpdateResult($i)
            $kb = ''
            try {
                if ($u.KBArticleIDs.Count -gt 0) { $kb = 'KB' + $u.KBArticleIDs.Item(0) }
            } catch { $kb = '' }
            $rec = @{
                KB             = $kb
                Title          = $u.Title
                HResult        = Format-WUHResult ([int]$uRes.HResult)
                RebootRequired = [bool]$uRes.RebootRequired
            }
            $records += $rec
            if ($uRes.HResult -eq 0) {
                Write-LogSuccess "  installed: $kb $($u.Title)"
            } else {
                Write-LogWarning "  failed:    $kb $($u.Title) - $($rec.HResult)"
            }
        }

        if ($rebootRequired) {
            Write-LogInfo 'Reboot required mid-batch - stopping chunk loop to let orchestrator reboot first.'
            break
        }
    }

    return @{ Installed = $records; RebootRequired = $rebootRequired; Error = $null }
}

# ---------------------------------------------------------------------------
# DCU sub-step wrapper - dot-sources DellCommandUpdate.ps1 and records extras
# ---------------------------------------------------------------------------
function Invoke-DcuSubStep {
    if (-not $Script:RUN_DCU) {
        Set-StageExtra -StageName $StageName -Key 'DCUUsed'    -Value $false
        Set-StageExtra -StageName $StageName -Key 'DCUSkipped' -Value 'disabled via config'
        return @{ RebootRequired = $false; Error = $null }
    }

    . (Join-Path $coreDir 'DellCommandUpdate.ps1')
    $dcu = $null
    try {
        $dcu = Invoke-DellCommandUpdate -InstallIfMissing $Script:INSTALL_DCU_IF_MISSING
    } catch {
        Write-LogWarning "DCU sub-step threw: $($_.Exception.Message)"
        Set-StageExtra -StageName $StageName -Key 'DCUUsed'    -Value $false
        Set-StageExtra -StageName $StageName -Key 'DCUSkipped' -Value "exception: $($_.Exception.Message)"
        return @{ RebootRequired = $false; Error = $_.Exception.Message }
    }

    Set-StageExtra -StageName $StageName -Key 'DCUUsed'           -Value $dcu.Used
    if ($dcu.Skipped) {
        Set-StageExtra -StageName $StageName -Key 'DCUSkipped'    -Value $dcu.Skipped
    }
    if ($null -ne $dcu.ScanExitCode) {
        Set-StageExtra -StageName $StageName -Key 'DCUScanExit'   -Value $dcu.ScanExitCode
    }
    if ($null -ne $dcu.ApplyExitCode) {
        Set-StageExtra -StageName $StageName -Key 'DCUApplyExit'  -Value $dcu.ApplyExitCode
    }
    Set-StageExtra -StageName $StageName -Key 'DCUInstalledCount' -Value $dcu.InstalledCount
    return @{ RebootRequired = $dcu.RebootRequired; Error = $dcu.Error; InstalledCount = $dcu.InstalledCount }
}

# ---------------------------------------------------------------------------
# Main stage logic
# ---------------------------------------------------------------------------
try {
    Write-LogInfo "Stage '$StageName' starting."
    Set-StageExtra -StageName $StageName -Key 'Engine' -Value 'WUA-COM'

    # Safety cap on the cycle loop.
    $cycle = Get-UpdateCycleCount
    Write-LogInfo "Update cycle counter: $cycle / $Script:MAX_UPDATE_CYCLES"
    if ($cycle -ge $Script:MAX_UPDATE_CYCLES) {
        Write-LogWarning "Maximum update cycles reached ($cycle). Returning Complete with warning."
        Set-StageExtra -StageName $StageName -Key 'MaxCyclesHit' -Value $true
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "Max update cycles reached ($cycle)." }
    }

    # Register Microsoft Update so Office / .NET / MS drivers are in scope.
    $muRegistered = Register-MicrosoftUpdateService
    Set-StageExtra -StageName $StageName -Key 'MicrosoftUpdateRegistered' -Value $muRegistered

    # Detect via COM.
    $pending = Get-PendingViaCOM
    if ($pending.Count -lt 0) {
        Write-LogError "COM scan failed: $($pending.Error)"
        Close-Logger -FinalStatus 'FAILED'
        return @{ Status = 'Failed'; Message = "WUA COM scan failed: $($pending.Error)" }
    }
    Set-StageExtra -StageName $StageName -Key 'PendingCountStart' -Value $pending.Count
    Write-LogInfo "COM scan found $($pending.Count) applicable update(s)."

    if ($pending.Count -eq 0) {
        # Nothing pending in WU/MU. Honour a pending reboot from a prior cycle
        # before running DCU - wuauserv often needs a clean reboot before DCU
        # can touch BitLocker / drivers.
        if (Test-RebootPending) {
            Write-LogInfo 'Pending=0 but registry says a reboot is still pending from prior cycle.'
            $null = Add-UpdateCycleCount
            Close-Logger -FinalStatus 'SUCCESS'
            return @{ Status = 'RebootRequired'; Message = 'Pending reboot from previous update cycle.' }
        }

        # Dell Command | Update for OEM updates not in MU.
        $dcuResult = Invoke-DcuSubStep
        if ($dcuResult.RebootRequired) {
            Write-LogInfo 'DCU requested reboot.'
            $null = Add-UpdateCycleCount
            Close-Logger -FinalStatus 'SUCCESS'
            return @{ Status = 'RebootRequired'; Message = "DCU installed $($dcuResult.InstalledCount) update(s); reboot required." }
        }

        # Final drain check - must agree with what Settings UI will show.
        $finalScan = Get-PendingViaCOM
        Set-StageExtra -StageName $StageName -Key 'LastDrainScanCount' -Value $finalScan.Count
        if ($finalScan.Count -gt 0) {
            Write-LogInfo "Post-DCU rescan found $($finalScan.Count) update(s) - returning RebootRequired to drain on next boot."
            $null = Add-UpdateCycleCount
            Close-Logger -FinalStatus 'SUCCESS'
            return @{ Status = 'RebootRequired'; Message = "Post-DCU rescan found $($finalScan.Count) update(s); will drain on next cycle." }
        }
        Write-LogSuccess 'All Windows / Microsoft / Dell updates applied. Pending count is zero.'
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = 'All updates applied; pending count is zero.' }
    }

    # Install via COM.
    $install = Install-ViaCOM -Updates $pending.Updates
    Set-StageExtra -StageName $StageName -Key 'InstalledThisCycle' -Value $install.Installed
    $newCycle = Add-UpdateCycleCount
    Write-LogInfo "Installed $(@($install.Installed).Count) update(s) this cycle (#$newCycle). Reboot needed: $($install.RebootRequired)"

    if ($install.Error) {
        Write-LogError "Installer raised: $($install.Error)"
        Close-Logger -FinalStatus 'FAILED'
        return @{ Status = 'Failed'; Message = $install.Error }
    }

    if ($install.RebootRequired -or (Test-RebootPending)) {
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'RebootRequired'; Message = "Installed $(@($install.Installed).Count) update(s); reboot required. Cycle #$newCycle." }
    }

    # No reboot needed - rescan once more so cascaded updates are caught.
    $cascade = Get-PendingViaCOM
    if ($cascade.Count -gt 0) {
        Write-LogInfo "$($cascade.Count) cascaded update(s) appeared post-install - returning RebootRequired to loop."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'RebootRequired'; Message = "Cascaded updates pending ($($cascade.Count))." }
    }

    Write-LogSuccess 'Cycle complete - no reboot, no further updates.'
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = "Installed $(@($install.Installed).Count) update(s); no reboot needed." }
}
catch {
    Write-LogError "WindowsUpdate stage threw: $($_.Exception.Message)"
    Write-LogError "Line: $($_.InvocationInfo.ScriptLineNumber)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
