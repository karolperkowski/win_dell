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
      2. Clear HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation
         RealTimeIsUniversal so Windows treats the BIOS clock as local
         time (Dell ships BIOS=local; the old WinTweaks tweak shifted
         the clock by the timezone offset on first boot).
      3. Set W32Time service to Automatic (Delayed Start) and start it.
      4. Configure NTP peers via w32tm /config and force a resync.
      5. Verify Source / LastSyncTime via w32tm /query /status.

    Idempotent — re-running on an already-synced machine is a no-op
    apart from one extra resync.
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

$NtpServers = @('time.windows.com','time.google.com','time.cloudflare.com','pool.ntp.org')
if ($cfg['NtpServers'] -and @($cfg['NtpServers']).Count -gt 0) {
    $NtpServers = @($cfg['NtpServers'])
}

$ClearRTU = $true
if ($cfg.ContainsKey('ClearRealTimeIsUniversal') -and $cfg['ClearRealTimeIsUniversal'] -eq $false) {
    $ClearRTU = $false
}

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
    # Dell ships BIOS = local time; the old WinTweaks tweak set this to 1
    # which made Windows interpret the BIOS clock as UTC. On a single-boot
    # Windows machine the safe default is to clear it.
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
    # Set-Service on PS 5.1 cannot express "Automatic (Delayed Start)" — use sc.exe.
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

function Set-NtpPeers {
    param([string[]]$Peers)
    # 0x9 = SpecialInterval (0x1) | Client (0x8). Marks each peer as a poll-
    # interval-controlled time source, which is what we want from a SYSTEM
    # context without an AD domain.
    $peerList = ($Peers | ForEach-Object { "$_,0x9" }) -join ' '
    Write-LogInfo "Configuring NTP peers: $peerList"

    $out = & w32tm.exe /config /manualpeerlist:"$peerList" /syncfromflags:manual /reliable:no /update 2>&1
    Write-LogInfo "  $($out -join ' ')"
    if ($LASTEXITCODE -ne 0) {
        throw "w32tm /config failed (exit $LASTEXITCODE)"
    }
}

function Invoke-TimeResync {
    param([int]$MaxAttempts = 3)

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Write-LogInfo "Resync attempt $i/$MaxAttempts..."
        $out = & w32tm.exe /resync /rediscover 2>&1
        $msg = ($out -join ' ').Trim()
        Write-LogInfo "  $msg"
        if ($LASTEXITCODE -eq 0) {
            Write-LogSuccess "  Resync succeeded on attempt $i."
            return $true
        }
        # 0x80070426 = service not started; happens if the very first
        # resync races w32time startup. Pause and retry.
        Start-Sleep -Seconds 10
    }
    return $false
}

function Test-TimeSync {
    Write-LogInfo 'Querying w32tm status...'
    $statusOut = & w32tm.exe /query /status 2>&1
    $statusText = ($statusOut -join "`n")
    Write-LogInfo $statusText

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
        Write-LogInfo 'ClearRealTimeIsUniversal=false in config — leaving registry untouched.'
        try { Set-StageExtra -StageName $StageName -Key 'RealTimeIsUniversalCleared' -Value $false } catch {}
    }

    # 3. w32time service
    Write-LogSection 'W32Time service'
    Enable-W32TimeService

    # 4. NTP peers
    Write-LogSection 'NTP peer configuration'
    Set-NtpPeers -Peers $NtpServers
    try { Set-StageExtra -StageName $StageName -Key 'NtpPeers' -Value ($NtpServers -join ',') } catch {}

    # 5. Force resync
    Write-LogSection 'Force resync'
    $resyncOk = Invoke-TimeResync -MaxAttempts 3
    try { Set-StageExtra -StageName $StageName -Key 'ResyncSucceeded' -Value $resyncOk } catch {}

    # 6. Verify
    Write-LogSection 'Verification'
    $verify = Test-TimeSync
    try {
        Set-StageExtra -StageName $StageName -Key 'Source'      -Value $verify.Source
        Set-StageExtra -StageName $StageName -Key 'LastSyncRaw' -Value $verify.LastSyncRaw
    } catch {}

    $sourceOk = ($verify.Source -and $verify.Source -ne 'Local CMOS Clock' -and $verify.Source -ne 'Free-running System Clock')
    $recent   = $false
    if ($verify.LastSync) {
        $age = (Get-Date) - $verify.LastSync
        $recent = ($age.TotalHours -lt 24)
        Write-LogInfo ("  LastSync age: {0:N1} h" -f $age.TotalHours)
    }

    if ($sourceOk -and $recent) {
        Write-LogSuccess "Time sync OK (source=$($verify.Source), last sync $($verify.LastSyncRaw))."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "Time synced from $($verify.Source)." }
    }

    $reason = if (-not $sourceOk) {
        "no external NTP source bound (Source='$($verify.Source)')"
    } else {
        "last sync stale or missing ('$($verify.LastSyncRaw)')"
    }
    Write-LogError "Time sync verification failed: $reason"
    try { Set-StageExtra -StageName $StageName -Key 'QueryStatus' -Value $verify.StatusText } catch {}
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = "Time sync verification failed: $reason" }

} catch {
    Write-LogError "TimeSync stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
