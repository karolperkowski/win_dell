#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Time Sync

.DESCRIPTION
    Runs first in the pipeline so every downstream stage (TLS handshakes
    for winget, Windows Update token validation, code-signing checks,
    Tailscale auth) sees a correct clock.

    Steps:
      1. Set the configured timezone via tzutil.exe.
      2. Clear RealTimeIsUniversal so Windows treats the BIOS clock as
         local time. Dell ships BIOS=local; the old WinTweaks tweak set
         this to 1 which shifted the clock by the timezone offset.
      3. Set W32Time service to Automatic (Delayed Start) and start it.
      4. Raise MaxPosPhaseCorrection / MaxNegPhaseCorrection so w32time
         will step the clock even when the CMOS is hours/years off
         (dead CMOS battery, fresh-from-factory Dells).
      5. Configure NTP peers and Type=NTP via w32tm /config.
      6. Wait for network (DNS resolve one peer) before any resync.
      7. Loop: w32tm /resync /rediscover + poll /query /status until
         Source flips off the local clock.
      8. On success: return Complete.
         On failure: if reboot retry count < MaxRebootRetries (default 2)
         return RebootRequired; otherwise return Failed.

    TimeSync is in REBOOT_ALLOWED_STAGES so a fresh boot with a fresh
    network stack gets a second chance instead of halting the deploy.

    Idempotent -- re-running on an already-synced machine is one extra
    resync.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'TimeSync',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'State.psm1')   -DisableNameChecking -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Config lookup with defaults
# ---------------------------------------------------------------------------
$cfg = @{}
if ($Config['TimeSync']) { $cfg = $Config['TimeSync'] }

$Timezone = if ($cfg['Timezone']) { $cfg['Timezone'] } else { 'Eastern Standard Time' }

$NtpServers = @('time.google.com','time.cloudflare.com','time.windows.com','pool.ntp.org')
if ($cfg['NtpServers'] -and @($cfg['NtpServers']).Count -gt 0) {
    $NtpServers = @($cfg['NtpServers'])
}

$ClearRTU = $true
if ($cfg.ContainsKey('ClearRealTimeIsUniversal') -and $cfg['ClearRealTimeIsUniversal'] -eq $false) {
    $ClearRTU = $false
}

$MaxRebootRetries     = if ($cfg['MaxRebootRetries'])     { [int]$cfg['MaxRebootRetries']     } else { 2  }
$NetworkWaitSeconds   = if ($cfg['NetworkWaitSeconds'])   { [int]$cfg['NetworkWaitSeconds']   } else { 120 }
$VerifyTimeoutSeconds = if ($cfg['VerifyTimeoutSeconds']) { [int]$cfg['VerifyTimeoutSeconds'] } else { 120 }
$ResyncAttempts       = if ($cfg['ResyncAttempts'])       { [int]$cfg['ResyncAttempts']       } else { 5  }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Set-WDTimezone {
    param([string]$Tz)
    Write-LogInfo "Setting timezone: $Tz"
    & tzutil.exe /s $Tz
    if ($LASTEXITCODE -ne 0) {
        throw "tzutil /s '$Tz' returned exit code $LASTEXITCODE"
    }
    $current = (& tzutil.exe /g).Trim()
    Write-LogSuccess "  Timezone is now: $current"
    return $current
}

function Clear-RealTimeIsUniversal {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
    try {
        $val = Get-ItemProperty -Path $path -Name 'RealTimeIsUniversal' -ErrorAction Stop
        if ($val.RealTimeIsUniversal -ne 0) {
            Remove-ItemProperty -Path $path -Name 'RealTimeIsUniversal' -Force -ErrorAction Stop
            Write-LogSuccess '  RealTimeIsUniversal cleared (BIOS clock = local time).'
            return $true
        }
        Write-LogInfo '  RealTimeIsUniversal already 0.'
    } catch {
        Write-LogInfo '  RealTimeIsUniversal not set (default).'
    }
    return $false
}

function Enable-W32TimeService {
    Write-LogInfo 'Configuring w32time service: Automatic (Delayed Start)...'
    $out = & sc.exe config w32time start= delayed-auto 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe config w32time failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    Write-LogInfo "  $($out -join ' ')"

    $svc = Get-Service w32time -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Write-LogInfo '  Starting w32time...'
        Start-Service w32time -ErrorAction Stop
        $svc.WaitForStatus('Running','00:00:30')
    }
    Write-LogSuccess "  w32time is $((Get-Service w32time).Status)."
}

function Set-W32TimeMaxPhaseCorrection {
    # By default w32time refuses to step the clock if the offset exceeds
    # MaxPosPhaseCorrection / MaxNegPhaseCorrection (15 hours on workstations).
    # On a Dell with a dead CMOS battery the offset can be years; 0xFFFFFFFF
    # = "any size correction permitted". Without this the resync succeeds
    # but the clock never moves.
    $cfg = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
    Set-ItemProperty -Path $cfg -Name 'MaxPosPhaseCorrection' -Value 0xFFFFFFFF -Type DWord
    Set-ItemProperty -Path $cfg -Name 'MaxNegPhaseCorrection' -Value 0xFFFFFFFF -Type DWord
    Set-ItemProperty -Path $cfg -Name 'AnnounceFlags'         -Value 5          -Type DWord
    Write-LogInfo '  MaxPos/Neg PhaseCorrection set to unlimited, AnnounceFlags=5.'

    # Force Type=NTP (rather than NT5DS which expects a domain).
    $params = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    Set-ItemProperty -Path $params -Name 'Type' -Value 'NTP' -Type String
    Write-LogInfo '  Parameters\Type=NTP.'
}

function Set-NtpPeers {
    param([string[]]$Peers)
    # 0x9 = SpecialInterval (0x1) | Client (0x8).
    $peerList = ($Peers | ForEach-Object { "$_,0x9" }) -join ' '
    Write-LogInfo "Configuring NTP peers: $peerList"

    $out = & w32tm.exe /config /manualpeerlist:"$peerList" /syncfromflags:manual /reliable:no /update 2>&1
    Write-LogInfo "  $($out -join ' ')"
    if ($LASTEXITCODE -ne 0) {
        throw "w32tm /config failed (exit $LASTEXITCODE)"
    }
}

function Restart-W32Time {
    Write-LogInfo 'Restarting w32time to pick up new config...'
    try {
        Stop-Service w32time -Force -ErrorAction Stop
        Start-Service w32time -ErrorAction Stop
        (Get-Service w32time).WaitForStatus('Running','00:00:30')
        Write-LogSuccess "  w32time restarted ($((Get-Service w32time).Status))."
    } catch {
        Write-LogWarning "  Restart partial: $($_.Exception.Message)"
    }
}

function Wait-ForNetwork {
    param(
        [string[]]$Peers,
        [int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        foreach ($peer in $Peers) {
            try {
                $null = Resolve-DnsName -Name $peer -Type A -DnsOnly -ErrorAction Stop
                Write-LogSuccess "  Network up: resolved $peer (attempt $attempt)."
                return $true
            } catch { }
        }
        Write-LogInfo "  No NTP peer resolves yet (attempt $attempt). Sleeping 5 s..."
        Start-Sleep -Seconds 5
    }
    Write-LogWarning "  Network probe timed out after ${TimeoutSeconds}s."
    return $false
}

function Get-W32TimeStatus {
    $statusOut = & w32tm.exe /query /status 2>&1
    $statusText = ($statusOut -join "`n")

    $source = $null
    if ($statusText -match '(?im)^\s*Source\s*:\s*(.+)$') {
        $source = $Matches[1].Trim()
    }

    $lastSyncRaw = $null
    if ($statusText -match '(?im)^\s*Last Successful Sync Time\s*:\s*(.+)$') {
        $lastSyncRaw = $Matches[1].Trim()
    }

    $lastSync = $null
    if ($lastSyncRaw -and $lastSyncRaw -ne 'unspecified') {
        try { $lastSync = [datetime]::Parse($lastSyncRaw) } catch { }
    }

    [PSCustomObject]@{
        Source       = $source
        LastSyncRaw  = $lastSyncRaw
        LastSync     = $lastSync
        StatusText   = $statusText
    }
}

function Test-W32TimeSynced {
    param([PSCustomObject]$Status)
    if (-not $Status.Source) { return $false }
    if ($Status.Source -eq 'Local CMOS Clock')        { return $false }
    if ($Status.Source -eq 'Free-running System Clock') { return $false }
    if (-not $Status.LastSync) { return $false }
    return $true
}

function Invoke-TimeResyncWithWait {
    param(
        [int]$Attempts,
        [int]$WaitSecondsPerAttempt
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        Write-LogInfo "Resync attempt $i/$Attempts..."
        $out = & w32tm.exe /resync /rediscover 2>&1
        Write-LogInfo "  $(($out -join ' ').Trim())"

        # /resync returns when the request is dispatched, not when the sync
        # completes. Poll /query /status until Source flips off the local
        # clock or we exhaust this attempt's budget.
        $deadline = (Get-Date).AddSeconds($WaitSecondsPerAttempt)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $st = Get-W32TimeStatus
            if (Test-W32TimeSynced -Status $st) {
                Write-LogSuccess ("  Source flipped to '$($st.Source)' after attempt $i.")
                return $st
            }
        }
        Write-LogInfo "  Attempt $i did not complete a sync within ${WaitSecondsPerAttempt}s."
    }
    # Final read.
    return (Get-W32TimeStatus)
}

function Get-RebootRetryCount {
    try {
        $state = Get-DeployState
        if ($state['StageExtras']) {
            $v = $state['StageExtras']['TimeSync_RebootRetryCount']
            if ($v) { return [int]$v }
        }
    } catch { }
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-LogInfo "Stage '$StageName' starting."

    # 1. Timezone
    Write-LogSection 'Timezone'
    $appliedTz = Set-WDTimezone -Tz $Timezone
    try { Set-StageExtra -StageName $StageName -Key 'Timezone' -Value $appliedTz } catch {}

    # 2. Hardware clock interpretation
    Write-LogSection 'Hardware clock interpretation'
    if ($ClearRTU) {
        $cleared = Clear-RealTimeIsUniversal
        try { Set-StageExtra -StageName $StageName -Key 'RealTimeIsUniversalCleared' -Value $cleared } catch {}
    } else {
        Write-LogInfo 'ClearRealTimeIsUniversal=false in config -- leaving registry untouched.'
        try { Set-StageExtra -StageName $StageName -Key 'RealTimeIsUniversalCleared' -Value $false } catch {}
    }

    # 3. w32time service
    Write-LogSection 'W32Time service'
    Enable-W32TimeService

    # 4. Allow unlimited phase correction (handle dead CMOS / large skew)
    Write-LogSection 'W32Time phase-correction limits'
    Set-W32TimeMaxPhaseCorrection

    # 5. NTP peers
    Write-LogSection 'NTP peer configuration'
    Set-NtpPeers -Peers $NtpServers
    try { Set-StageExtra -StageName $StageName -Key 'NtpPeers' -Value ($NtpServers -join ',') } catch {}

    # 6. Restart w32time so the new MaxPhaseCorrection registry values take
    #    effect (service reads these at start).
    Write-LogSection 'Restart w32time'
    Restart-W32Time

    # 7. Wait for network -- Resolve-DnsName one of the peers. Fresh boots on
    #    Wi-Fi can take 30-60s before DNS works.
    Write-LogSection 'Network readiness'
    $netUp = Wait-ForNetwork -Peers $NtpServers -TimeoutSeconds $NetworkWaitSeconds
    try { Set-StageExtra -StageName $StageName -Key 'NetworkReady' -Value $netUp } catch {}
    if (-not $netUp) {
        Write-LogWarning "Continuing without confirmed network -- resync may fail."
    }

    # 8. Resync + poll
    Write-LogSection 'Force resync (with poll)'
    $perAttemptWait = [Math]::Max(15, [int]($VerifyTimeoutSeconds / $ResyncAttempts))
    $final = Invoke-TimeResyncWithWait -Attempts $ResyncAttempts -WaitSecondsPerAttempt $perAttemptWait

    try {
        Set-StageExtra -StageName $StageName -Key 'Source'      -Value $final.Source
        Set-StageExtra -StageName $StageName -Key 'LastSyncRaw' -Value $final.LastSyncRaw
    } catch {}

    # 9. Verify
    Write-LogSection 'Verification'
    Write-LogInfo $final.StatusText
    $synced = Test-W32TimeSynced -Status $final

    if ($synced) {
        Write-LogSuccess "Time sync OK (source=$($final.Source), last sync $($final.LastSyncRaw))."
        # Reset reboot retry count on success so subsequent re-runs start fresh.
        try { Set-StageExtra -StageName $StageName -Key 'RebootRetryCount' -Value 0 } catch {}
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "Time synced from $($final.Source)." }
    }

    $reason = if (-not $final.Source -or $final.Source -eq 'Local CMOS Clock' -or $final.Source -eq 'Free-running System Clock') {
        "no external NTP source bound (Source='$($final.Source)')"
    } else {
        "last sync missing ('$($final.LastSyncRaw)')"
    }

    try { Set-StageExtra -StageName $StageName -Key 'QueryStatus' -Value $final.StatusText } catch {}

    # 10. Reboot fallback
    $retryCount = Get-RebootRetryCount
    if ($retryCount -lt $MaxRebootRetries) {
        $next = $retryCount + 1
        try { Set-StageExtra -StageName $StageName -Key 'RebootRetryCount' -Value $next } catch {}
        Write-LogWarning "Time sync verification failed: $reason"
        Write-LogWarning "Reboot retry $next/$MaxRebootRetries -- orchestrator will reboot and re-run TimeSync."
        Close-Logger -FinalStatus 'REBOOT'
        return @{ Status = 'RebootRequired'; Message = "TimeSync retry $next/${MaxRebootRetries}: $reason" }
    }

    Write-LogError "Time sync verification failed after $MaxRebootRetries reboot retries: $reason"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = "Time sync verification failed after $MaxRebootRetries reboot retries: $reason" }

} catch {
    Write-LogError "TimeSync stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
