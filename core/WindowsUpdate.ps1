#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Windows Update.

.DESCRIPTION
    Drives the native Windows Update Agent COM API (Microsoft.Update.Session
    + Microsoft.Update.ServiceManager) to detect, download, and install all
    pending updates with the Microsoft Update service registered so Office,
    .NET, MS-published drivers, and optional updates are in scope - these
    are exactly what the Settings -> Windows Update UI shows but what the old
    PSWindowsUpdate-only path missed.

    After the WUA drain reports zero pending, the stage invokes Dell Command
    | Update (DCU) for OEM BIOS / firmware / driver updates that don't flow
    through Microsoft Update.

    Reboots: the stage never reboots directly. On RebootRequired it returns
    to the orchestrator which handles the reboot. The orchestrator marks
    WindowsUpdate as a DRAIN stage (Config.psm1 $Script:DRAIN_STAGES) - every
    subsequent boot re-runs this script so late-cascading updates (servicing
    stack -> cumulative -> .NET -> drivers) are caught.

    PSWindowsUpdate fallback: if the COM session cannot be created (very
    rare - usually corruption of wuaueng.dll), the script falls back to the
    legacy PSWindowsUpdate-based install path with -MicrosoftUpdate flagged.

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
$Script:NUGET_MIN_VERSION    = [Version]'2.8.5.201'

# Known WU HResult codes -> human-readable strings. Keys are strings (the
# formatted hex) so we don't fight Int32 overflow on values with the high bit set.
# Source: https://learn.microsoft.com/windows/win32/wua_sdk/wua-success-and-error-codes-
$Script:WU_HRESULT_MEANINGS = @{
    '0x00000000' = 'Success'
    '0x00240001' = 'Reboot required (informational)'
    '0x80240020' = 'WU_E_NO_INTERACTIVE_USER - operation requires an interactive user.'
    '0x80240438' = 'WU_E_NO_CONNECTION - WU agent could not reach a source.'
    '0x8024D007' = 'WU_E_SETUP_WUSERVICE_NOT_STOPPED - wuauserv was not stopped before update.'
    '0x8024200B' = 'WU_E_INSTALL_FAILURE - install command failed; see WindowsUpdate.log.'
    '0x80240024' = 'WU_E_NO_UPDATE - no applicable update found.'
    '0x80240017' = 'WU_E_NOT_APPLICABLE - update is not applicable to the system.'
    '0x8024401C' = 'WU_E_PT_HTTP_STATUS_REQ_TIMEOUT - source request timed out.'
    '0x8024A005' = 'WU_E_AU_NO_REGISTERED_SERVICE - no service is registered with AU.'
}

function Format-WUHResult {
    param([Parameter(Mandatory)][int]$HResult)
    $hex = '0x{0:X8}' -f $HResult
    if ($Script:WU_HRESULT_MEANINGS.ContainsKey($hex)) {
        return "$hex ($($Script:WU_HRESULT_MEANINGS[$hex]))"
    }
    return $hex
}

# ---------------------------------------------------------------------------
# Cycle counter - shared between COM path and PSWindowsUpdate fallback
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

function Get-WUSearchCriteria {
    # https://learn.microsoft.com/windows/win32/wua_sdk/search-criteria
    $typeBits = @("Type='Software'")
    if ($Script:INCLUDE_DRIVERS) { $typeBits += "Type='Driver'" }
    $typeExpr = '(' + ($typeBits -join ' or ') + ')'
    return "IsInstalled=0 and IsHidden=0 and $typeExpr"
}

function New-WuaSession {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'WinDeploy'
    return $session
}

function Get-PendingViaCOM {
    <#
    Returns @{ Updates = IUpdateCollection; Count = int; Error = string? }.
    On COM failure: @{ Updates = $null; Count = -1; Error = '...' }.
    #>
    Write-LogInfo 'Scanning for updates via Windows Update Agent COM API...'
    try {
        $session  = New-WuaSession
        $searcher = $session.CreateUpdateSearcher()
        if ($Script:INCLUDE_MS_UPDATE) {
            $searcher.ServerSelection = 3  # ssOthers
            $searcher.ServiceID       = $Script:MS_UPDATE_SERVICE_ID
        }
        $criteria = Get-WUSearchCriteria
        Write-LogInfo "Search criteria: $criteria"

        $result = $searcher.Search($criteria)
        $rawUpdates = $result.Updates

        if (-not $Script:INCLUDE_OPTIONAL) {
            # Optional updates have AutoSelectOnWebSites=$false and are kept
            # behind Settings -> Optional Updates. Filter them out when the
            # operator has disabled IncludeOptional.
            $filtered = New-Object -ComObject Microsoft.Update.UpdateColl
            for ($i = 0; $i -lt $rawUpdates.Count; $i++) {
                $u = $rawUpdates.Item($i)
                if ($u.AutoSelectOnWebSites) { $null = $filtered.Add($u) }
            }
            $dropped = $rawUpdates.Count - $filtered.Count
            if ($dropped -gt 0) {
                Write-LogInfo "Filtered out $dropped optional update(s) (IncludeOptional=false)."
            }
            return @{ Updates = $filtered; Count = $filtered.Count; Error = $null }
        }

        return @{ Updates = $rawUpdates; Count = $rawUpdates.Count; Error = $null }
    } catch {
        return @{ Updates = $null; Count = -1; Error = $_.Exception.Message }
    }
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
# PSWindowsUpdate fallback (only used if COM session cannot be created)
# ---------------------------------------------------------------------------
function Test-PSGalleryReachable {
    $maxAttempts = 4
    $delay = 3
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2' `
                -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { return $true }
        } catch {
            if ($i -lt $maxAttempts) {
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * 2, 20)
            }
        }
    }
    return $false
}

function Invoke-PSWindowsUpdateFallback {
    Write-LogWarning 'Falling back to PSWindowsUpdate path - COM API was unavailable.'
    if (-not (Test-PSGalleryReachable)) {
        return @{ Status = 'Failed'; Message = 'PSGallery unreachable for fallback path.' }
    }
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt $Script:NUGET_MIN_VERSION) {
        Install-PackageProvider -Name NuGet -MinimumVersion $Script:NUGET_MIN_VERSION `
            -Force -Scope AllUsers | Out-Null
    }
    $mod = Get-Module -ListAvailable -Name 'PSWindowsUpdate' |
           Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        Install-Module -Name 'PSWindowsUpdate' -Force -Scope AllUsers `
            -AllowClobber -SkipPublisherCheck | Out-Null
    }
    Import-Module 'PSWindowsUpdate' -Force

    $wuArgs = @{
        AcceptAll    = $true
        AutoReboot   = $false
        IgnoreReboot = $true
        Confirm      = $false
        NotTitle     = 'Preview'
        ErrorAction  = 'Stop'
    }
    if ($Script:INCLUDE_MS_UPDATE) { $wuArgs['MicrosoftUpdate'] = $true }

    try {
        $result = Install-WindowsUpdate @wuArgs
        $rebootReq = $result | Where-Object { $_.RebootRequired -eq $true }
        if ($rebootReq -or (Test-RebootPending)) {
            return @{ Status = 'RebootRequired'; Message = 'PSWindowsUpdate fallback: reboot required.' }
        }
        return @{ Status = 'Complete'; Message = 'PSWindowsUpdate fallback: drain complete.' }
    } catch {
        return @{ Status = 'Failed'; Message = "PSWindowsUpdate fallback failed: $($_.Exception.Message)" }
    }
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
        Set-StageExtra -StageName $StageName -Key 'Engine' -Value 'PSWindowsUpdate-Fallback'
        $fallback = Invoke-PSWindowsUpdateFallback
        $finalStatus = 'SUCCESS'
        if ($fallback.Status -eq 'Failed') { $finalStatus = 'FAILED' }
        Close-Logger -FinalStatus $finalStatus
        return $fallback
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
