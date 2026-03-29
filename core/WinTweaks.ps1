#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Windows Tweaks

.DESCRIPTION
    Two-pass approach:
      Pass 1 — Run Chris Titus Tech WinUtil in unattended preset mode using
               config/winutil-preset.json. Wrapped in try/catch so a WinUtil
               failure doesn't abort the deployment.
      Pass 2 — Apply specific tweaks directly via registry regardless of whether
               WinUtil succeeded. These are always applied:
                 - Dark theme (system + apps)
                 - Remove Bing from taskbar search
                 - NumLock on at startup (default user + current user)
                 - Verbose status messages during login/startup
                 - Additional telemetry and noise reduction tweaks
#>

[CmdletBinding()]
param(
    [string]$StageName = 'WinTweaks',
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$coreDir  = $PSScriptRoot
$repoRoot = Split-Path $coreDir -Parent

Import-Module (Join-Path $coreDir 'Logging.psm1') -DisableNameChecking -Force
Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Registry helper
# ---------------------------------------------------------------------------
function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        Write-LogInfo "  SET $Path\$Name = $Value"
    } catch {
        Write-LogWarning "  SKIP $Path\$Name  — $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Pass 1: WinUtil unattended preset
# ---------------------------------------------------------------------------
function Invoke-WinUtil {
    $presetPath = Join-Path $repoRoot 'config\winutil-preset.json'

    if (-not (Test-Path $presetPath)) {
        Write-LogWarning "WinUtil preset not found at '$presetPath' — skipping WinUtil pass."
        return
    }

    Write-LogInfo 'Downloading WinUtil script...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        # Download the script to a temp file so we can call it with -Config/-Run
        $winUtilScript = Join-Path $env:TEMP 'winutil.ps1'
        Invoke-WebRequest -Uri 'https://christitus.com/win' `
            -OutFile $winUtilScript -UseBasicParsing -ErrorAction Stop

        Write-LogInfo "Running WinUtil with preset: $presetPath"
        $argList = "-NonInteractive -ExecutionPolicy Bypass -File `"$winUtilScript`" " +
                   "-Config `"$presetPath`" -Run"

        $proc = Start-Process powershell.exe -ArgumentList $argList -Wait -PassThru
        Write-LogInfo "WinUtil exited with code: $($proc.ExitCode)"
    } catch {
        Write-LogWarning "WinUtil run failed: $($_.Exception.Message)"
        Write-LogWarning 'Continuing with direct registry tweaks.'
    }
}

# ---------------------------------------------------------------------------
# Pass 2: Direct registry tweaks (always applied)
# ---------------------------------------------------------------------------

function Set-DarkTheme {
    Write-LogSection 'Dark Theme'
    # System-wide default (affects new users and login screen)
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'   0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    # Current user (Administrator during deployment; auto-logon user)
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'   0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    # Default user hive (applies to every NEW user profile created later)
    $defaultHive = 'C:\Users\Default\NTUSER.DAT'
    if (Test-Path $defaultHive) {
        try {
            reg.exe load 'HKU\WinDeploy_Default' $defaultHive 2>$null
            Set-Reg 'Registry::HKU\WinDeploy_Default\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'   0
            Set-Reg 'Registry::HKU\WinDeploy_Default\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
        } finally {
            [gc]::Collect()
            reg.exe unload 'HKU\WinDeploy_Default' 2>$null
        }
    }
}

function Remove-BingSearch {
    Write-LogSection 'Remove Bing Search'
    # Disable web/Bing results in taskbar search
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'             'BingSearchEnabled'       0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'             'CortanaConsent'          0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'             'SearchboxTaskbarMode'    1  # 0=hidden,1=icon,2=box
    # Policy: disable connected/web search (applies machine-wide)
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'           'DisableWebSearch'        1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'           'ConnectedSearchUseWeb'   0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'           'AllowCortana'            0
    # Disable "Show search highlights" (the Bing-sourced daily content in search)
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings'     'IsDynamicSearchBoxEnabled' 0
}

function Set-NumLockOn {
    Write-LogSection 'NumLock on at startup'
    # HKU\.DEFAULT = affects the login screen and any user who hasn't changed it
    Set-Reg 'Registry::HKU\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' String
    # Current user
    Set-Reg 'HKCU:\Control Panel\Keyboard'                  'InitialKeyboardIndicators' '2' String
    # Default user hive
    $defaultHive = 'C:\Users\Default\NTUSER.DAT'
    if (Test-Path $defaultHive) {
        try {
            reg.exe load 'HKU\WinDeploy_Default' $defaultHive 2>$null
            Set-Reg 'Registry::HKU\WinDeploy_Default\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' String
        } finally {
            [gc]::Collect()
            reg.exe unload 'HKU\WinDeploy_Default' 2>$null
        }
    }
}

function Set-VerboseLogin {
    Write-LogSection 'Verbose login messages'
    # Shows "Applying computer settings...", "Applying user settings..." etc. during login
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1
    # Also increase the startup/shutdown verbosity in boot options (optional — comment out if not needed)
    # bcdedit /set quietboot No  — handled separately via bcdedit below
    try {
        & bcdedit.exe /set '{current}' bootstatuspolicy DisplayAllFailures 2>$null | Out-Null
        Write-LogInfo '  bcdedit: boot status policy set to DisplayAllFailures'
    } catch {
        Write-LogWarning "  bcdedit failed (non-fatal): $($_.Exception.Message)"
    }
}

function Install-WingetApps {
    Write-LogSection 'Winget app installs'

    # Ensure winget is available
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-LogWarning 'winget not found - skipping app installs.'
        Write-LogWarning 'winget ships with App Installer from the Microsoft Store.'
        return
    }

    $apps = @(
        @{ Id = 'Google.Chrome'; Name = 'Google Chrome' }
    )

    foreach ($app in $apps) {
        Write-LogInfo "Installing $($app.Name) via winget..."
        try {
            $result = & winget.exe install `
                --id $app.Id `
                --silent `
                --accept-package-agreements `
                --accept-source-agreements `
                --disable-interactivity `
                2>&1

            if ($LASTEXITCODE -in @(0, -1978335189)) {
                # 0 = success, -1978335189 (0x8A150011) = already installed
                Write-LogSuccess "$($app.Name) installed (or already present)."
            } else {
                Write-LogWarning "$($app.Name) winget exit code: $LASTEXITCODE"
            }
        } catch {
            Write-LogWarning "$($app.Name) install failed: $($_.Exception.Message)"
        }
    }
}
    Write-LogSection 'Additional tweaks'

    # Disable telemetry
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'           0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                'AllowTelemetry'           0

    # Disable activity history
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed'          0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities'       0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities'        0

    # Disable location tracking
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' String

    # Show file extensions in Explorer
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt'        0
    # Show hidden files
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden'             1
    # Disable "Recently used files" in Quick Access
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'          'ShowRecent'         0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'          'ShowFrequent'       0

    # Disable Xbox Game DVR / Game Bar
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar'                   'AutoGameModeEnabled' 0

    # Disable fast startup (can cause issues with dual-boot and some hardware)
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0

    # Set timezone to Eastern Time (New York)
    try {
        & tzutil.exe /s "Eastern Standard Time"
        Write-LogInfo '  Timezone set to Eastern Standard Time (New York)'
    } catch {
        Write-LogWarning "  tzutil failed: $($_.Exception.Message)"
    }

    # Set UTC time (important for dual-boot / VMs)
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1

    # Taskbar: show seconds in clock
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 1

    # Disable Widgets (Windows 11)
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0

    # End task from taskbar right-click (Windows 11 22H2+)
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-LogInfo "Stage '$StageName' starting."

    # Pass 1: WinUtil (best-effort)
    $runWinUtil = if ($Config['WinTweaks'] -and $Config['WinTweaks']['RunWinUtil'] -eq $false) {
        $false
    } else { $true }

    if ($runWinUtil) {
        Write-LogSection 'Pass 1: WinUtil preset'
        try { Invoke-WinUtil } catch { Write-LogWarning "WinUtil pass threw: $($_.Exception.Message)" }
    } else {
        Write-LogInfo 'WinUtil pass skipped (RunWinUtil = false in config).'
    }

    # Pass 2: Direct tweaks
    Write-LogSection 'Pass 2: Direct registry tweaks'
    Set-DarkTheme
    Remove-BingSearch
    Set-NumLockOn
    Set-VerboseLogin
    Set-AdditionalTweaks

    # Winget app installs
    Install-WingetApps

    Write-LogSuccess 'WinTweaks stage complete.'
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = 'Windows tweaks applied.' }

} catch {
    Write-LogError "WinTweaks stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
