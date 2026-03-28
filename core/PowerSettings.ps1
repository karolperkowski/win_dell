#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Power Settings

.DESCRIPTION
    Configures power settings for always-on operation (display never off,
    system never sleeps) when plugged in. Works on both Windows 10 and 11,
    on laptops and desktops. Uses powercfg.exe for reliability.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'PowerSettings',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreDir = $PSScriptRoot
Import-Module (Join-Path $coreDir 'Logging.psm1') -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# GUIDs: these are Windows-standard and stable across Win10/11
# ---------------------------------------------------------------------------
$SCHEME_BALANCED    = 'SCHEME_BALANCED'    # Balanced (default)
$SCHEME_CURRENT     = 'SCHEME_CURRENT'     # Active scheme

# Sub-group and setting GUIDs
$SUB_SLEEP          = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # Sleep sub-group
$SUB_DISPLAY        = '7516b95f-f776-4464-8c53-06167f40cc99'   # Display sub-group
$SETTING_STANDBY_AC = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'  # Sleep after (AC)
$SETTING_DISPLAY_AC = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'  # Display off after (AC)
$SETTING_HIBERNATE  = '9d7815a6-7ee4-497e-8888-515a05f02364'  # Hibernate after (AC)

# Value 0 = Never
$NEVER = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-ActivePowerSchemeGuid {
    $output = & powercfg.exe /getactivescheme
    # Output: "Power Scheme GUID: xxxxxxxx-xxxx-... (Name)"
    if ($output -match 'GUID:\s+([0-9a-f-]{36})') {
        return $Matches[1]
    }
    throw "Could not parse active power scheme GUID from: $output"
}

function Set-PowerValue {
    param(
        [string]$SchemeGuid,
        [string]$SubGroupGuid,
        [string]$SettingGuid,
        [int]$Value,
        [string]$Description
    )
    Write-LogInfo "  Setting: $Description => $Value"
    $rc = & powercfg.exe /setacvalueindex $SchemeGuid $SubGroupGuid $SettingGuid $Value
    if ($LASTEXITCODE -ne 0) {
        Write-LogWarning "  powercfg returned exit code $LASTEXITCODE for: $Description"
    }
}

function Apply-ActiveScheme {
    param([string]$SchemeGuid)
    & powercfg.exe /setactive $SchemeGuid | Out-Null
}

function Verify-PowerSettings {
    param([string]$SchemeGuid)

    Write-LogInfo 'Verifying power settings...'
    $output = & powercfg.exe /query $SchemeGuid $SUB_SLEEP $SETTING_STANDBY_AC
    $output += & powercfg.exe /query $SchemeGuid $SUB_DISPLAY $SETTING_DISPLAY_AC

    # Look for "Current AC Power Setting Index: 0x00000000" lines
    $lines  = $output -join "`n"
    $acVals = [regex]::Matches($lines, 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)')
    foreach ($m in $acVals) {
        $val = [Convert]::ToInt32($m.Groups[1].Value, 16)
        if ($val -ne 0) {
            Write-LogWarning "  A setting is not 0 (Never) - value: $val"
        }
    }
    Write-LogInfo 'Verification complete.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    $schemeGuid = Get-ActivePowerSchemeGuid
    Write-LogInfo "Active power scheme GUID: $schemeGuid"

    Write-LogInfo 'Applying AC (plugged-in) power settings...'

    # Display: never turn off
    Set-PowerValue -SchemeGuid $schemeGuid `
                   -SubGroupGuid $SUB_DISPLAY `
                   -SettingGuid $SETTING_DISPLAY_AC `
                   -Value $NEVER `
                   -Description 'Turn off display after (AC)'

    # Standby/sleep: never
    Set-PowerValue -SchemeGuid $schemeGuid `
                   -SubGroupGuid $SUB_SLEEP `
                   -SettingGuid $SETTING_STANDBY_AC `
                   -Value $NEVER `
                   -Description 'Sleep after (AC)'

    # Hibernate: never
    Set-PowerValue -SchemeGuid $schemeGuid `
                   -SubGroupGuid $SUB_SLEEP `
                   -SettingGuid $SETTING_HIBERNATE `
                   -Value $NEVER `
                   -Description 'Hibernate after (AC)'

    # Apply the scheme to make changes active
    Apply-ActiveScheme -SchemeGuid $schemeGuid
    Write-LogSuccess 'Power scheme applied.'

    # Also disable hibernate file to reclaim disk space (optional - comment out if you want hibernate)
    Write-LogInfo 'Disabling hibernation (hiberfil.sys)...'
    & powercfg.exe /hibernate off | Out-Null

    # Verify
    Verify-PowerSettings -SchemeGuid $schemeGuid

    Write-LogSuccess 'Power settings stage complete.'
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = 'Power settings configured.' }

} catch {
    Write-LogError "Power settings stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
