#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Debloat

.DESCRIPTION
    Removes unwanted built-in Windows apps. The removal list is driven by
    data/bloatware.json so you can customise what gets removed without
    touching this script.

    Two removal passes are made:
      1. Remove provisioned packages  (stops the app being installed for new users)
      2. Remove installed packages    (removes from the current user profile)

    A DO-NOT-REMOVE list is checked before every removal attempt. Any app
    on that list is skipped regardless of what the config says.
#>

[CmdletBinding()]
param(
    [string]$StageName = 'Debloat',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreDir = $PSScriptRoot
$repoRoot = Split-Path $coreDir -Parent

Import-Module (Join-Path $coreDir 'Logging.psm1') -Force

Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Hard-coded DO-NOT-REMOVE list - these are required for Windows to function.
# Never remove these regardless of configuration.
# ---------------------------------------------------------------------------
$Script:DO_NOT_REMOVE = @(
    'Microsoft.WindowsStore'              # Store - needed to update apps
    'Microsoft.StorePurchaseApp'          # Store payment framework
    'Microsoft.DesktopAppInstaller'       # winget - needed for future installs
    'Microsoft.UI.Xaml*'                  # WinUI framework (many apps depend on this)
    'Microsoft.VCLibs*'                   # VC runtime - breaks many apps if removed
    'Microsoft.NET*'                      # .NET packages
    'Microsoft.WindowsCalculator'         # Basic utility - low risk to keep
    'Microsoft.Windows.Photos'            # Used by file associations
    'Microsoft.WindowsSoundRecorder'      # Audio drivers depend on this
    'Microsoft.MicrosoftEdge*'            # Edge - OS-integrated, removal causes issues
    'Microsoft.Win32WebViewHost'          # WebView host - required by many apps
    'Microsoft.Xbox.TCUI'                 # Xbox identity layer - some apps need it
    'Windows.CBSPreview'                  # Component Based Servicing - system
    'Microsoft.ScreenSketch'              # Snipping Tool - keep for usability
)

# ---------------------------------------------------------------------------
# Load removal lists from bloatware.json
# ---------------------------------------------------------------------------

function Load-BloatwareConfig {
    $dataFile = Join-Path $repoRoot 'data\bloatware.json'

    if (-not (Test-Path $dataFile)) {
        Write-LogWarning "bloatware.json not found at '$dataFile'. Using empty list."
        return @{ Safe = @(); Optional = @() }
    }

    try {
        $raw = Get-Content $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{
            Safe     = @($raw.SafeToRemove)
            Optional = @($raw.OptionalRemoval)
        }
    } catch {
        Write-LogWarning "Failed to parse bloatware.json: $($_.Exception.Message)"
        return @{ Safe = @(); Optional = @() }
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-IsProtected {
    param([string]$PackageName)

    foreach ($pattern in $Script:DO_NOT_REMOVE) {
        if ($PackageName -like $pattern) {
            return $true
        }
    }
    return $false
}

function Remove-ProvisionedApp {
    param([string]$PackageName)

    $provisioned = Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -like "*$PackageName*" }

    if (-not $provisioned) {
        Write-LogDebug "  Provisioned: '$PackageName' not found - skipping."
        return
    }

    foreach ($pkg in $provisioned) {
        if (Test-IsProtected -PackageName $pkg.DisplayName) {
            Write-LogWarning "  PROTECTED - skipping provisioned: $($pkg.DisplayName)"
            continue
        }
        try {
            Write-LogInfo "  Removing provisioned: $($pkg.DisplayName)"
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            Write-LogSuccess "  Removed provisioned: $($pkg.DisplayName)"
        } catch {
            Write-LogWarning "  Failed to remove provisioned '$($pkg.DisplayName)': $($_.Exception.Message)"
        }
    }
}

function Remove-InstalledApp {
    param([string]$PackageName)

    # All-users removal
    $allUsers = Get-AppxPackage -AllUsers -Name "*$PackageName*" -ErrorAction SilentlyContinue
    if (-not $allUsers) {
        Write-LogDebug "  Installed (AllUsers): '$PackageName' not found - skipping."
        return
    }

    foreach ($pkg in $allUsers) {
        if (Test-IsProtected -PackageName $pkg.Name) {
            Write-LogWarning "  PROTECTED - skipping installed: $($pkg.Name)"
            continue
        }
        try {
            Write-LogInfo "  Removing installed (AllUsers): $($pkg.Name)"
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Write-LogSuccess "  Removed: $($pkg.Name)"
        } catch {
            Write-LogWarning "  Failed to remove '$($pkg.Name)': $($_.Exception.Message)"
        }
    }
}

function Remove-AppEntry {
    param([string]$PackageName, [string]$Category)

    Write-LogInfo "Processing [$Category]: $PackageName"
    Remove-ProvisionedApp  -PackageName $PackageName
    Remove-InstalledApp    -PackageName $PackageName
}

# ---------------------------------------------------------------------------
# Optional: disable Cortana, Consumer Experience, etc. via registry
# ---------------------------------------------------------------------------
function Invoke-RegistryTweaks {
    Write-LogInfo 'Applying registry tweaks...'

    $tweaks = @(
        # Disable Cortana suggestions in Start
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
            Name  = 'AllowCortana'
            Value = 0
            Type  = 'DWord'
        },
        # Disable Consumer Features (auto-installing sponsored apps)
        @{
            Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
            Name  = 'DisableWindowsConsumerFeatures'
            Value = 1
            Type  = 'DWord'
        },
        # Disable Bing in Start Search
        @{
            Path  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'
            Name  = 'BingSearchEnabled'
            Value = 0
            Type  = 'DWord'
        },
        # Disable Start Menu suggestions/ads
        @{
            Path  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Name  = 'SystemPaneSuggestionsEnabled'
            Value = 0
            Type  = 'DWord'
        },
        @{
            Path  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Name  = 'SubscribedContent-338388Enabled'
            Value = 0
            Type  = 'DWord'
        }
    )

    foreach ($tweak in $tweaks) {
        try {
            if (-not (Test-Path $tweak.Path)) {
                New-Item -Path $tweak.Path -Force | Out-Null
            }
            Set-ItemProperty -Path $tweak.Path -Name $tweak.Name `
                -Value $tweak.Value -Type $tweak.Type -ErrorAction Stop
            Write-LogInfo "  Set: $($tweak.Path)\$($tweak.Name) = $($tweak.Value)"
        } catch {
            Write-LogWarning "  Registry tweak failed ($($tweak.Name)): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-LogInfo "Stage '$StageName' starting."

    $lists = Load-BloatwareConfig

    # Determine which optional apps to remove based on config
    $removeOptional = if ($Config['Debloat'] -and $Config['Debloat']['RemoveOptional'] -eq $true) {
        $true
    } else { $false }

    Write-LogInfo "Safe-to-remove apps:    $(@($lists.Safe).Count)"
    Write-LogInfo "Optional-removal apps:  $(@($lists.Optional).Count)"
    Write-LogInfo "Remove optional:        $removeOptional"

    # Pass 1: Safe removals
    Write-LogSection 'Pass 1: Safe Removals'
    foreach ($app in $lists.Safe) {
        Remove-AppEntry -PackageName $app -Category 'SAFE'
    }

    # Pass 2: Optional removals (config-gated)
    if ($removeOptional) {
        Write-LogSection 'Pass 2: Optional Removals'
        foreach ($app in $lists.Optional) {
            Remove-AppEntry -PackageName $app -Category 'OPTIONAL'
        }
    } else {
        Write-LogInfo 'Optional removals skipped (RemoveOptional = false in config).'
    }

    # Registry tweaks
    Write-LogSection 'Registry Tweaks'
    Invoke-RegistryTweaks

    Write-LogSuccess 'Debloat stage complete.'
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = 'Debloat complete.' }

} catch {
    Write-LogError "Debloat stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
