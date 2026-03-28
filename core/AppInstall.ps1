#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Application Installation

.DESCRIPTION
    Handles silent installation of Dell SupportAssist and Dell Power Manager
    (and any other apps listed in config). Called twice by the orchestrator
    with different -StageName values:

        - InstallDellSupportAssist
        - InstallDellPowerManager

    Each invocation processes the matching app definition from settings.json.

    App definitions support three installer types:
        EXE  - run with silent args, check exit code
        MSI  - run via msiexec.exe, standard return codes
        MSIX - use Add-AppxPackage

    Detection methods supported:
        Registry - check HKLM/HKCU Uninstall keys
        Process  - check for a running process name
        File     - check for a specific file on disk
        Service  - check for a Windows service

.PARAMETER StageName
    Must match a key in config.Apps (e.g. 'InstallDellSupportAssist').

.PARAMETER Config
    Full settings.json hashtable.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StageName,
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference   = 'None'   # Prevent any cmdlet from prompting during unattended run

$coreDir = $PSScriptRoot
$repoRoot = Split-Path $coreDir -Parent

Import-Module (Join-Path $coreDir 'Logging.psm1') -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

function Test-AppInstalledByRegistry {
    param([string]$DisplayName, [string]$MinVersion = '')

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$DisplayName*" }

        foreach ($entry in $entries) {
            if ($MinVersion -and $entry.DisplayVersion) {
                try {
                    $installed = [Version]$entry.DisplayVersion
                    $required  = [Version]$MinVersion
                    if ($installed -ge $required) { return $true }
                } catch {
                    # Non-standard version string - treat as found
                    return $true
                }
            } else {
                return $true
            }
        }
    }
    return $false
}

function Test-AppInstalledByFile {
    param([string]$FilePath)
    return (Test-Path $FilePath)
}

function Test-AppInstalledByService {
    param([string]$ServiceName)
    return ($null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue))
}

function Test-AppInstalled {
    <#
    Dispatches to the appropriate detection method based on the app definition.
    Returns $true if the app appears to be installed.
    #>
    param([hashtable]$AppDef)

    $detect = $AppDef['Detection']
    if (-not $detect) {
        Write-LogWarning "No detection config for '$($AppDef['DisplayName'])' - assuming not installed."
        return $false
    }

    switch ($detect['Method']) {
        'Registry' {
            return Test-AppInstalledByRegistry `
                -DisplayName $detect['DisplayName'] `
                -MinVersion  (if ($detect['MinVersion']) { $detect['MinVersion'] } else { '' })
        }
        'File' {
            return Test-AppInstalledByFile -FilePath $detect['FilePath']
        }
        'Service' {
            return Test-AppInstalledByService -ServiceName $detect['ServiceName']
        }
        default {
            Write-LogWarning "Unknown detection method: '$($detect['Method'])'"
            return $false
        }
    }
}

# ---------------------------------------------------------------------------
# Installer helpers
# ---------------------------------------------------------------------------

function Resolve-InstallerPath {
    <#
    Finds the installer. Priority:
      1. LocalPath (absolute or relative to apps/ folder)
      2. Download URL
    Returns the resolved local path.
    #>
    param([hashtable]$AppDef)

    $appsDir = Join-Path $repoRoot 'apps'

    # Try local path first
    if ($AppDef['LocalPath']) {
        $local = $AppDef['LocalPath']
        if (-not [System.IO.Path]::IsPathRooted($local)) {
            $local = Join-Path $appsDir $local
        }
        if (Test-Path $local) {
            Write-LogInfo "Using local installer: $local"
            return $local
        }
        Write-LogWarning "Local installer not found at '$local' - trying download."
    }

    # Try download
    if ($AppDef['DownloadUrl']) {
        $url      = $AppDef['DownloadUrl']
        $fileName = Split-Path $url -Leaf
        $dest     = Join-Path $env:TEMP $fileName

        Write-LogInfo "Downloading installer from: $url"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
            Write-LogSuccess "Downloaded to: $dest"
            return $dest
        } catch {
            throw "Failed to download '$url': $($_.Exception.Message)"
        }
    }

    throw "No installer source available for '$($AppDef['DisplayName'])'. " +
          "Set 'LocalPath' or 'DownloadUrl' in settings.json."
}

function Invoke-EXEInstall {
    param([string]$InstallerPath, [string]$SilentArgs, [array]$SuccessExitCodes)

    Write-LogInfo "Running EXE installer: $InstallerPath $SilentArgs"
    $proc = Start-Process -FilePath $InstallerPath `
                          -ArgumentList $SilentArgs `
                          -Wait -PassThru -ErrorAction Stop

    $exitCode = $proc.ExitCode
    Write-LogInfo "Installer exited with code: $exitCode"

    if ($exitCode -in $SuccessExitCodes) {
        return $exitCode
    }
    throw "EXE installer exited with unexpected code $exitCode " +
          "(expected one of: $($SuccessExitCodes -join ', '))"
}

function Invoke-MSIInstall {
    param([string]$InstallerPath, [string]$ExtraArgs)

    $msiLog  = Join-Path $env:TEMP "msi_$(Split-Path $InstallerPath -Leaf).log"
    $allArgs = "/i `"$InstallerPath`" /qn /norestart /l*v `"$msiLog`" $ExtraArgs"

    Write-LogInfo "Running MSI installer via msiexec: $allArgs"
    $proc = Start-Process -FilePath 'msiexec.exe' `
                          -ArgumentList $allArgs `
                          -Wait -PassThru -ErrorAction Stop

    $exitCode = $proc.ExitCode
    Write-LogInfo "msiexec exited with code: $exitCode (log: $msiLog)"

    # Standard MSI codes: 0=success, 3010=success+reboot required
    if ($exitCode -in @(0, 3010)) { return $exitCode }
    throw "MSI installer exited with unexpected code $exitCode. See log: $msiLog"
}

function Invoke-MSIXInstall {
    param([string]$InstallerPath)

    Write-LogInfo "Adding MSIX package: $InstallerPath"
    Add-AppxPackage -Path $InstallerPath -ErrorAction Stop
    Write-LogSuccess 'MSIX package added.'
}

function Install-App {
    param([hashtable]$AppDef)

    $displayName = $AppDef['DisplayName']
    $type        = $AppDef['InstallerType']   # EXE | MSI | MSIX
    $silentArgs  = if ($AppDef['SilentArgs']) { $AppDef['SilentArgs'] } else { '' }
    $successCodes = if ($AppDef['SuccessExitCodes']) {
        @($AppDef['SuccessExitCodes'])
    } else { @(0) }

    $installerPath = Resolve-InstallerPath -AppDef $AppDef

    switch ($type.ToUpper()) {
        'EXE'  {
            $code = Invoke-EXEInstall -InstallerPath $installerPath `
                                      -SilentArgs $silentArgs `
                                      -SuccessExitCodes $successCodes
            # Exit code 3010 means success + reboot required
            return ($code -eq 3010)
        }
        'MSI'  {
            $code = Invoke-MSIInstall -InstallerPath $installerPath -ExtraArgs $silentArgs
            return ($code -eq 3010)
        }
        'MSIX' {
            Invoke-MSIXInstall -InstallerPath $installerPath
            return $false
        }
        default {
            throw "Unknown InstallerType '$type' for app '$displayName'."
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    # Find the app definition in config
    $apps = $Config['Apps']
    if (-not $apps) {
        Write-LogWarning "No 'Apps' section found in config. Nothing to install."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = 'No apps defined in config.' }
    }

    $appDef = $apps[$StageName]
    if (-not $appDef) {
        Write-LogWarning "No app definition for stage '$StageName' in config.Apps. Skipping."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "No app definition for $StageName." }
    }

    $displayName = if ($appDef['DisplayName']) { $appDef['DisplayName'] } else { $StageName }
    Write-LogInfo "Target application: $displayName"

    # Detection: skip if already installed
    if (Test-AppInstalled -AppDef $appDef) {
        Write-LogSuccess "$displayName is already installed. Skipping."
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'Complete'; Message = "$displayName already installed." }
    }

    Write-LogInfo "$displayName not detected - proceeding with installation."

    # Install
    $rebootRequired = Install-App -AppDef $appDef

    # Post-install verification
    Write-LogInfo 'Verifying installation...'
    $verified = Test-AppInstalled -AppDef $appDef
    if (-not $verified) {
        throw "Post-install detection failed for '$displayName'. " +
              "The installer may have failed silently. Check logs in $env:TEMP."
    }

    Write-LogSuccess "$displayName installed and verified successfully."

    if ($rebootRequired) {
        Close-Logger -FinalStatus 'SUCCESS'
        return @{ Status = 'RebootRequired'; Message = "$displayName installed - reboot required." }
    }

    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = "$displayName installed." }

} catch {
    Write-LogError "App install stage '$StageName' failed: $($_.Exception.Message)"
    Write-LogError "Line: $($_.InvocationInfo.ScriptLineNumber)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
