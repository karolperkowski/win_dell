#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Remote Access

.DESCRIPTION
    Configures the standard Windows remote management stack so the machine
    can be administered over Tailscale (or LAN, if explicitly opted in):

      - Remote Desktop (RDP) with Network Level Authentication
      - Windows Remote Management (WinRM / PSRemoting)
      - OpenSSH Server (default shell = Windows PowerShell 5.1)

    Firewall rules are scoped to the Tailscale CGNAT range (100.64.0.0/10)
    by default. Set Stages.RemoteAccess.AllowLan = true in settings.json to
    additionally permit private LAN profiles.

    Idempotent: each step checks current state and skips work that is
    already done. Failures in one sub-step do not abort the others —
    partial remote access is more useful than none.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'RemoteAccess',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
$AllowLan        = $false
$TrustedHostMask = '100.*'   # Tailscale CGNAT (100.64.0.0/10)

if ($Config.ContainsKey('AllowLan'))        { $AllowLan        = [bool]$Config['AllowLan'] }
if ($Config.ContainsKey('TrustedHostMask')) { $TrustedHostMask = [string]$Config['TrustedHostMask'] }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Enable-RDP {
    Write-LogInfo 'Enabling Remote Desktop...'
    try {
        $tsKey  = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
        $rdpKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

        $current = (Get-ItemProperty -Path $tsKey -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
        if ($current -eq 0) {
            Write-LogInfo '  RDP already enabled.'
        } else {
            Set-ItemProperty -Path $tsKey -Name 'fDenyTSConnections' -Value 0 -Type DWord
            Write-LogSuccess '  RDP enabled.'
        }

        # Require Network Level Authentication
        Set-ItemProperty -Path $rdpKey -Name 'UserAuthentication' -Value 1 -Type DWord
        Write-LogInfo '  NLA required.'

        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
        Write-LogInfo '  Firewall rules enabled for Remote Desktop.'
        return $true
    } catch {
        Write-LogWarning "  RDP setup failed: $($_.Exception.Message)"
        return $false
    }
}

function Enable-WinRMService {
    Write-LogInfo 'Enabling WinRM / PSRemoting...'
    try {
        # Enable-PSRemoting is idempotent.
        Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

        # Scope client trusted hosts to the Tailscale CGNAT range.
        $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
        if ($current -ne $TrustedHostMask) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TrustedHostMask -Force
            Write-LogInfo "  TrustedHosts set to: $TrustedHostMask"
        } else {
            Write-LogInfo "  TrustedHosts already: $TrustedHostMask"
        }

        Write-LogSuccess '  WinRM enabled.'
        return $true
    } catch {
        Write-LogWarning "  WinRM setup failed: $($_.Exception.Message)"
        return $false
    }
}

function Enable-OpenSshServer {
    Write-LogInfo 'Configuring OpenSSH Server...'
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
        if ($cap -and $cap.State -ne 'Installed') {
            Write-LogInfo '  Installing OpenSSH.Server capability...'
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        } else {
            Write-LogInfo '  OpenSSH.Server already installed.'
        }

        Set-Service -Name sshd -StartupType Automatic
        if ((Get-Service sshd).Status -ne 'Running') {
            Start-Service sshd
        }

        # Default shell = Windows PowerShell 5.1
        $sshKey = 'HKLM:\SOFTWARE\OpenSSH'
        if (-not (Test-Path $sshKey)) { New-Item -Path $sshKey -Force | Out-Null }
        New-ItemProperty -Path $sshKey -Name 'DefaultShell' `
                         -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                         -PropertyType String -Force | Out-Null

        # Firewall rule (Add-WindowsCapability usually creates this, but verify)
        if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
                                -DisplayName 'OpenSSH Server (sshd)' `
                                -Enabled True -Direction Inbound `
                                -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            Write-LogInfo '  Firewall rule created for sshd.'
        }

        Write-LogSuccess '  OpenSSH Server enabled.'
        return $true
    } catch {
        Write-LogWarning "  OpenSSH setup failed: $($_.Exception.Message)"
        return $false
    }
}

function Set-FirewallProfileScope {
    <#
    .DESCRIPTION
        By default, restrict the remote-access firewall rules to Private +
        Domain profiles (Tailscale registers as Public on most installs, but
        the Windows firewall already permits Tailscale traffic via its own
        per-interface rules). When AllowLan is true, leave rules at Any.
    #>
    if ($AllowLan) {
        Write-LogInfo 'AllowLan = true; firewall rules left at Any profile.'
        return
    }

    Write-LogInfo 'Scoping remote-access firewall rules (LAN-only opt-out)...'
    $rules = @()
    $rules += Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    $rules += Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
    $rules += Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue

    foreach ($r in $rules) {
        if ($r) {
            try {
                Set-NetFirewallRule -InputObject $r -Profile Private,Domain -ErrorAction Stop
            } catch {
                Write-LogWarning "  Could not scope rule '$($r.DisplayName)': $($_.Exception.Message)"
            }
        }
    }
}

function Write-Summary {
    Write-LogInfo '--- Remote Access Summary ---'
    $rdpOn = ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
              -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections -eq 0)
    $sshOn = ((Get-Service sshd  -ErrorAction SilentlyContinue).Status -eq 'Running')
    $wrmOn = ((Get-Service WinRM -ErrorAction SilentlyContinue).Status -eq 'Running')

    if ($rdpOn) { $rdpStr = 'ON  (3389)' } else { $rdpStr = 'OFF' }
    if ($sshOn) { $sshStr = 'ON  (22)'   } else { $sshStr = 'OFF' }
    if ($wrmOn) { $wrmStr = 'ON  (5985)' } else { $wrmStr = 'OFF' }
    Write-LogInfo ("  RDP   : {0}" -f $rdpStr)
    Write-LogInfo ("  SSH   : {0}" -f $sshStr)
    Write-LogInfo ("  WinRM : {0}" -f $wrmStr)

    try {
        if (Get-Command tailscale.exe -ErrorAction SilentlyContinue) {
            $tsIp = (& tailscale.exe ip -4 2>$null) | Select-Object -First 1
            if ($tsIp) { Write-LogInfo "  Tailscale IP: $tsIp" }
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    $rdp = Enable-RDP
    $wrm = Enable-WinRMService
    $ssh = Enable-OpenSshServer

    Set-FirewallProfileScope
    Write-Summary

    $okCount = @($rdp, $wrm, $ssh) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count

    if ($okCount -eq 0) {
        Write-LogError 'All remote-access sub-steps failed.'
        Close-Logger -FinalStatus 'FAILED'
        return @{ Status = 'Failed'; Message = 'RDP, WinRM, and SSH all failed to configure.' }
    }

    if ($okCount -lt 3) {
        Write-LogWarning "Remote access partially configured ($okCount/3 services up)."
    } else {
        Write-LogSuccess 'Remote access fully configured (RDP + WinRM + SSH).'
    }

    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = "Remote access configured ($okCount/3 services)." }

} catch {
    Write-LogError "Remote access stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
