#Requires -Version 5.1
<#
.SYNOPSIS
    Dell Command | Update (DCU) sweep - installs OEM BIOS / firmware / driver
    updates that don't flow through Microsoft Update.

.DESCRIPTION
    Invoked by WindowsUpdate.ps1 after the native Windows Update Agent COM
    drain reports zero pending items. Dell's own catalog publishes BIOS,
    firmware, dock, and driver updates that Microsoft Update never sees, so
    a fully patched system per Settings UI can still have OEM updates
    waiting.

    Returns a hashtable rather than the stage-script contract because this
    file is dot-sourced by the parent WindowsUpdate stage, not invoked
    directly by the orchestrator.

.PARAMETER LogDir
    Directory for dcu-cli scan/apply log files. Defaults to $WD.LogDir.

.PARAMETER InstallIfMissing
    If $true and dcu-cli.exe is not found, attempt to install Dell Command |
    Update via winget. Best-effort - failure is non-fatal.

.RETURNS
    Hashtable: @{
        Used             = bool        # whether DCU actually ran a scan/apply
        Skipped          = string      # reason, if Used=$false
        ScanExitCode     = int
        ApplyExitCode    = int
        InstalledCount   = int         # parsed from /applyUpdates log
        RebootRequired   = bool
        Error            = string      # set on hard failure
    }
#>

[CmdletBinding()]
param(
    [string]$LogDir,
    [bool]$InstallIfMissing = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module imports - Logging is assumed already initialised by the parent stage.
# Winget.psm1 is optional; we degrade gracefully when missing.
# ---------------------------------------------------------------------------
$Script:_coreDir = $PSScriptRoot
if (-not (Get-Command Write-LogInfo -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $Script:_coreDir 'Logging.psm1') -DisableNameChecking -Force
}
$Script:_haveWinget = $false
if (Get-Command Invoke-WingetCli -ErrorAction SilentlyContinue) {
    $Script:_haveWinget = $true
} else {
    $wingetMod = Join-Path $Script:_coreDir 'Winget.psm1'
    if (Test-Path $wingetMod) {
        try {
            Import-Module $wingetMod -DisableNameChecking -Force -ErrorAction Stop
            $Script:_haveWinget = $true
        } catch {
            Write-LogWarning "Winget.psm1 import failed: $($_.Exception.Message)"
        }
    }
}

if (-not $LogDir) {
    # Pull the canonical log dir from Config.psm1 so we don't duplicate the
    # path literal that lint enforces lives in exactly one place. Config.psm1
    # is import-idempotent and cheap.
    try {
        Import-Module (Join-Path $Script:_coreDir 'Config.psm1') -DisableNameChecking -Force
        $LogDir = (Get-WDConfig).LogDir
    } catch {
        Write-LogWarning "Config.psm1 unavailable; using fallback log dir under DeployRoot."
        $LogDir = Join-Path $env:ProgramData 'WinDeploy\Logs'
    }
}
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$Script:DCU_PATHS = @(
    'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'
    'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
)

# DCU exit codes documented at:
# https://www.dell.com/support/manuals/en-us/command-update/dellcommandupdate_rg/dell-command-%7C-update-cli-commands
# Add codes here as they show up in the wild.
$Script:DCU_EXIT_MEANINGS = @{
    0    = 'Success - command completed.'
    1    = 'Reboot required - apply will need a reboot to finalise.'
    5    = 'Reboot pending from a previous operation - cannot apply more updates until reboot.'
    100  = 'No updates available (alternate code on some DCU versions).'
    101  = 'No updates applicable to system configuration.'
    500  = 'Updates available (scan exit only) - found applicable updates that have not yet been applied.'
    501  = 'Error retrieving inventory from catalog.'
    502  = 'Catalog not accessible.'
    503  = 'Catalog cache empty.'
    1000 = 'Generic error - see /outputLog for details.'
    1001 = 'Error parsing command-line.'
    1002 = 'Invalid command-line argument.'
}

function Get-DcuExitMeaning {
    param([Parameter(Mandatory)][int]$ExitCode)
    if ($Script:DCU_EXIT_MEANINGS.ContainsKey($ExitCode)) {
        return $Script:DCU_EXIT_MEANINGS[$ExitCode]
    }
    return "Unknown dcu-cli exit code: $ExitCode"
}

function Find-DcuCli {
    foreach ($p in $Script:DCU_PATHS) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-DellCommandUpdate {
    <#
    Attempts to install Dell Command | Update via winget. Returns the dcu-cli
    path on success, $null on failure. Failure is logged but not thrown - DCU
    is best-effort.
    #>
    if (-not $Script:_haveWinget) {
        Write-LogWarning 'Cannot install Dell Command | Update: winget helper not available.'
        return $null
    }

    Write-LogInfo 'Dell Command | Update not found - attempting winget install...'
    # Dell publishes two package IDs: the standard build and the "University"
    # build. The Universal/Universal-Update build is what ships with stock
    # Win10/11 Dell images and supports both Win10 and Win11.
    $candidates = @('Dell.CommandUpdate.Universal', 'Dell.CommandUpdate')
    foreach ($pkgId in $candidates) {
        try {
            $result = Invoke-WingetCli `
                -ArgList @('install','--id',$pkgId,'--silent','--accept-package-agreements',
                           '--accept-source-agreements','--source','winget',
                           '--disable-interactivity') `
                -SuccessExitCodes @(0, -1978335189, -1978335129) `
                -Description "Install Dell Command | Update ($pkgId)"
            if ($result.Success) {
                # winget may report success before the installer has finished
                # writing files; poll briefly for dcu-cli.exe to appear.
                for ($i = 0; $i -lt 20; $i++) {
                    $found = Find-DcuCli
                    if ($found) {
                        Write-LogSuccess "Dell Command | Update installed at $found"
                        return $found
                    }
                    Start-Sleep -Seconds 3
                }
                Write-LogWarning 'winget reported success but dcu-cli.exe did not appear within 60s.'
            }
        } catch {
            Write-LogWarning "winget install of $pkgId failed: $($_.Exception.Message)"
        }
    }
    Write-LogWarning 'Dell Command | Update install failed via every candidate package id.'
    return $null
}

function Invoke-DcuConfigure {
    <#
    One-shot DCU configuration for unattended use. Idempotent - safe to call
    on every run. We disable user prompts and BitLocker prompts, and tell DCU
    to download+install but not reboot (the parent stage owns reboots).
    #>
    param([Parameter(Mandatory)][string]$DcuExe)

    $cfgLog = Join-Path $LogDir ("dcu-configure-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $cfgArgs = @(
        '/configure'
        '-silent'
        '-autoSuspendBitLocker=enable'
        '-userConsent=disable'
        '-scheduleAction=DownloadInstallAndNotify'
        "-outputLog=$cfgLog"
    )
    Write-LogInfo "DCU configure : $DcuExe $($cfgArgs -join ' ')"
    $captured = @(& $DcuExe @cfgArgs 2>&1)
    $exit = $LASTEXITCODE
    foreach ($line in $captured) {
        if ($null -ne $line -and "$line".Trim().Length -gt 0) {
            Write-LogInfo "  dcu-configure: $line"
        }
    }
    if ($exit -ne 0) {
        Write-LogWarning "DCU /configure exited $exit ($(Get-DcuExitMeaning -ExitCode $exit))"
    }
    return $exit
}

function Invoke-DcuScan {
    param([Parameter(Mandatory)][string]$DcuExe)
    $scanLog = Join-Path $LogDir ("dcu-scan-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $scanArgs = @('/scan', "-outputLog=$scanLog")
    Write-LogInfo "DCU scan : $DcuExe $($scanArgs -join ' ')"
    $captured = @(& $DcuExe @scanArgs 2>&1)
    $exit = $LASTEXITCODE
    foreach ($line in $captured) {
        if ($null -ne $line -and "$line".Trim().Length -gt 0) {
            Write-LogInfo "  dcu-scan: $line"
        }
    }
    Write-LogInfo "DCU scan exit $exit ($(Get-DcuExitMeaning -ExitCode $exit)) - log: $scanLog"
    return @{ ExitCode = $exit; Log = $scanLog }
}

function Get-DcuInstalledCount {
    <#
    Parses a dcu-cli /applyUpdates -outputLog file for a "Number of updates
    successful" or "successfully applied" line. Different DCU versions phrase
    this differently - we accept either. Returns 0 when nothing matches.
    #>
    param([Parameter(Mandatory)][string]$ApplyLog)
    if (-not (Test-Path $ApplyLog)) { return 0 }
    try {
        $content = Get-Content $ApplyLog -Raw -ErrorAction Stop
    } catch {
        return 0
    }
    $patterns = @(
        'Number of (?:updates )?successful(?:ly applied)?\s*[:=]\s*(\d+)'
        'Successfully applied\s+(\d+)\s+update'
        '(\d+)\s+update\(s\)\s+(?:were\s+)?successfully\s+applied'
    )
    foreach ($pat in $patterns) {
        $m = [regex]::Match($content, $pat, 'IgnoreCase')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    }
    return 0
}

function Invoke-DcuApply {
    param([Parameter(Mandatory)][string]$DcuExe)
    $applyLog = Join-Path $LogDir ("dcu-apply-{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    # -reboot=disable: DCU never reboots; the parent stage handles reboot via
    # the RebootRequired return value once it sees exit code 1 or 5.
    $applyArgs = @('/applyUpdates', '-reboot=disable', "-outputLog=$applyLog")
    Write-LogInfo "DCU apply : $DcuExe $($applyArgs -join ' ')"
    $captured = @(& $DcuExe @applyArgs 2>&1)
    $exit = $LASTEXITCODE
    foreach ($line in $captured) {
        if ($null -ne $line -and "$line".Trim().Length -gt 0) {
            Write-LogInfo "  dcu-apply: $line"
        }
    }
    Write-LogInfo "DCU apply exit $exit ($(Get-DcuExitMeaning -ExitCode $exit)) - log: $applyLog"
    return @{ ExitCode = $exit; Log = $applyLog }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
function Invoke-DellCommandUpdate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([bool]$InstallIfMissing = $true)

    Write-LogSection 'Dell Command | Update sweep'

    # Skip cleanly on non-Dell hardware. SystemFamily / Manufacturer is the
    # canonical signal - Dell-Inc/. Dell sometimes ships odd casing.
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $isDell = $false
    if ($cs -and $cs.Manufacturer) {
        $isDell = ($cs.Manufacturer -match 'Dell')
    }
    if (-not $isDell) {
        Write-LogInfo "Skipping DCU: system manufacturer is '$($cs.Manufacturer)', not Dell."
        return @{
            Used = $false; Skipped = "non-Dell hardware ($($cs.Manufacturer))"
            ScanExitCode = $null; ApplyExitCode = $null
            InstalledCount = 0; RebootRequired = $false; Error = $null
        }
    }

    $dcu = Find-DcuCli
    if (-not $dcu -and $InstallIfMissing) {
        $dcu = Install-DellCommandUpdate
    }
    if (-not $dcu) {
        return @{
            Used = $false; Skipped = 'dcu-cli.exe not found and install skipped/failed'
            ScanExitCode = $null; ApplyExitCode = $null
            InstalledCount = 0; RebootRequired = $false; Error = $null
        }
    }

    try {
        $null = Invoke-DcuConfigure -DcuExe $dcu
    } catch {
        Write-LogWarning "DCU /configure threw: $($_.Exception.Message) - continuing."
    }

    $scan = $null
    try {
        $scan = Invoke-DcuScan -DcuExe $dcu
    } catch {
        return @{
            Used = $true; Skipped = $null
            ScanExitCode = -1; ApplyExitCode = $null
            InstalledCount = 0; RebootRequired = $false
            Error = "DCU /scan threw: $($_.Exception.Message)"
        }
    }

    # If scan says nothing applicable, stop here.
    if ($scan.ExitCode -in @(0, 100, 101)) {
        Write-LogSuccess 'DCU scan: no updates applicable.'
        return @{
            Used = $true; Skipped = $null
            ScanExitCode = $scan.ExitCode; ApplyExitCode = $null
            InstalledCount = 0; RebootRequired = $false; Error = $null
        }
    }

    $apply = $null
    try {
        $apply = Invoke-DcuApply -DcuExe $dcu
    } catch {
        return @{
            Used = $true; Skipped = $null
            ScanExitCode = $scan.ExitCode; ApplyExitCode = -1
            InstalledCount = 0; RebootRequired = $false
            Error = "DCU /applyUpdates threw: $($_.Exception.Message)"
        }
    }

    $installed = Get-DcuInstalledCount -ApplyLog $apply.Log
    $rebootRequired = ($apply.ExitCode -in @(1, 5))

    if ($rebootRequired) {
        Write-LogInfo "DCU applied $installed update(s) and requested a reboot."
    } elseif ($apply.ExitCode -eq 0) {
        Write-LogSuccess "DCU applied $installed update(s) cleanly."
    } else {
        Write-LogWarning "DCU apply returned $($apply.ExitCode) ($(Get-DcuExitMeaning -ExitCode $apply.ExitCode))."
    }

    return @{
        Used = $true; Skipped = $null
        ScanExitCode = $scan.ExitCode; ApplyExitCode = $apply.ExitCode
        InstalledCount = $installed
        RebootRequired = $rebootRequired
        Error = $null
    }
}

# Run when dot-sourced AND requested directly via -InstallIfMissing param at
# script load time. The parent WindowsUpdate.ps1 calls Invoke-DellCommandUpdate
# itself; this fallback is for ad-hoc invocation:
#   . core/DellCommandUpdate.ps1 ; Invoke-DellCommandUpdate
# (No automatic invocation - leaves the function callable without side effects.)
