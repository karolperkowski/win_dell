#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Stage: Windows Tweaks

.DESCRIPTION
    Two-pass approach:
      Pass 1 -- Run Chris Titus Tech WinUtil in unattended preset mode using
               config/winutil-preset.json. Wrapped in try/catch so a WinUtil
               failure doesn't abort the deployment.
      Pass 2 -- Apply specific tweaks directly via registry regardless of whether
               WinUtil succeeded. These are always applied:
                 - Dark theme (system + apps)
                 - Remove Bing from taskbar search
                 - NumLock on at startup (default user + current user)
                 - Verbose status messages during login/startup
                 - Additional telemetry and noise reduction tweaks

    Because the orchestrator runs as SYSTEM, HKCU points to the SYSTEM hive --
    not the real user. Pass 2 therefore enumerates every real user profile and
    loads their NTUSER.DAT so per-user tweaks actually reach the right accounts.
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
Import-Module (Join-Path $coreDir 'Config.psm1')  -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'State.psm1')   -DisableNameChecking -Force
Import-Module (Join-Path $coreDir 'Winget.psm1')  -DisableNameChecking -Force
Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# WinUtil applier strategy
# ---------------------------------------------------------------------------
# WinUtil's `-Noui` + `-Run` mode is fundamentally broken for unattended use:
#   - Invoke-WinUtilAutoRun does work inside a background runspace and uses
#     BusyWait() to poll $sync.ProcessRunning; that flag is set true at the
#     top of the runspace but only set false at the end. If anything in the
#     middle fails (e.g. the runspace references $sync["Form"].Dispatcher,
#     which is null in -Noui mode), the flag stays true and the parent
#     loops forever -- a 12-minute timeout, then the headless fallback also
#     hangs for the same reason. This was observed on 2026-04-10 on this
#     repo's first real-machine run.
#
# Instead of running WinUtil's own runner, we parse the WinUtil bundle's
# embedded JSON ($sync.configs.tweaks and $sync.configs.feature heredocs)
# and apply each preset ID directly: registry entries, services,
# Windows-optional-features, and InvokeScript blocks. Runs synchronously
# in our SYSTEM context -- no GUI, no runspace, no dispatcher.

# ---------------------------------------------------------------------------
# Script-level state for user hive management
# ---------------------------------------------------------------------------
$Script:UserHiveRoots   = @()   # Registry::HKU\<key> for each real user
$Script:DefaultHiveRoot = $null # Registry::HKU\WinDeploy_Default
$Script:LoadedHiveKeys  = @()   # Keys we loaded (must unload at end)

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
        Write-LogWarning "  SKIP $Path\$Name  -- $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# User-hive mount / dismount
# ---------------------------------------------------------------------------
function Mount-AllUserHives {
    <#
    Enumerates real user profiles and loads their NTUSER.DAT into HKU so
    per-user (HKCU) tweaks reach the correct accounts. Also loads the
    default-user hive (template for future new profiles).
    #>
    Write-LogSection 'Mounting user hives'

    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    Get-ChildItem $profileList -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        # Skip short SIDs -- these are system accounts (SYSTEM, LOCAL SERVICE, etc.)
        if ($sid.Length -lt 20) { return }

        $profilePath = $null
        try { $profilePath = Get-ItemPropertyValue -Path $_.PSPath -Name 'ProfileImagePath' -ErrorAction Stop } catch { }
        if (-not $profilePath -or -not (Test-Path $profilePath)) { return }

        # If the user is logged in their hive is already in HKU under their SID
        if (Test-Path "Registry::HKU\$sid") {
            $Script:UserHiveRoots += "Registry::HKU\$sid"
            Write-LogInfo "  User hive already loaded (logged-in): $profilePath"
            return
        }

        # Offline user -- load their hive manually
        $hivePath = Join-Path $profilePath 'NTUSER.DAT'
        if (-not (Test-Path $hivePath)) { return }

        $short   = $sid.Substring($sid.Length - 8)
        $hiveKey = "WinDeploy_U_$short"
        reg.exe load "HKU\$hiveKey" $hivePath 2>$null
        if ($LASTEXITCODE -eq 0) {
            $Script:UserHiveRoots  += "Registry::HKU\$hiveKey"
            $Script:LoadedHiveKeys += $hiveKey
            Write-LogInfo "  Loaded offline hive: $hiveKey ($profilePath)"
        } else {
            Write-LogWarning "  Could not load hive for $profilePath (exit $LASTEXITCODE)"
        }
    }

    # Default-user hive (template for any profile created after deployment)
    $defaultHive = 'C:\Users\Default\NTUSER.DAT'
    if (Test-Path $defaultHive) {
        reg.exe load 'HKU\WinDeploy_Default' $defaultHive 2>$null
        if ($LASTEXITCODE -eq 0) {
            $Script:DefaultHiveRoot = 'Registry::HKU\WinDeploy_Default'
            $Script:LoadedHiveKeys += 'WinDeploy_Default'
            Write-LogInfo '  Loaded default-user hive.'
        } else {
            Write-LogWarning "  Could not load default-user hive (exit $LASTEXITCODE)."
        }
    }

    $total = $Script:UserHiveRoots.Count
    if ($Script:DefaultHiveRoot) { $total++ }
    Write-LogInfo "  Total hives to apply per-user tweaks: $total"
}

function Dismount-AllUserHives {
    [gc]::Collect()
    Start-Sleep -Milliseconds 200
    foreach ($hiveKey in $Script:LoadedHiveKeys) {
        [gc]::Collect()
        reg.exe unload "HKU\$hiveKey" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "  Unloaded hive: $hiveKey"
        } else {
            Write-LogWarning "  Could not unload hive: $hiveKey (exit $LASTEXITCODE)"
        }
    }
}

function Get-AllUserRoots {
    <# Returns every hive root that needs per-user tweaks: real users + default. #>
    $roots = @() + $Script:UserHiveRoots
    if ($Script:DefaultHiveRoot) { $roots += $Script:DefaultHiveRoot }
    return $roots
}

# ---------------------------------------------------------------------------
# Pass 1: WinUtil preset (direct apply)
# ---------------------------------------------------------------------------
# We download the WinUtil bundle, extract the embedded $sync.configs.tweaks
# and $sync.configs.feature JSON heredocs, and apply each preset ID's
# registry / service / feature / InvokeScript entries ourselves.
#
# Bundle URL: christitus.com/win redirects to GitHub's latest release. We
# fetch the GitHub URL directly to avoid the redirect (faster, no Cloudflare
# in the path) but fall back to the short URL if the GitHub URL is down.

$Script:WinUtilBundleUrls = @(
    'https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1'
    'https://christitus.com/win'
)

function Get-WinUtilBundle {
    <#
    Downloads the WinUtil bundle, returns its source text. Tries each URL
    in order until one succeeds; throws if all fail.
    #>
    param([int]$TimeoutSec = 60)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    $lastErr = $null
    foreach ($url in $Script:WinUtilBundleUrls) {
        try {
            Write-LogInfo "  Downloading WinUtil bundle from $url"
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            # GitHub serves .ps1 with application/octet-stream so Content
            # arrives as byte[]; christitus.com returns text/plain so it
            # arrives as string. Normalize to UTF-8 string.
            $text = if ($resp.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($resp.Content)
            } else {
                [string]$resp.Content
            }
            if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 100000) {
                throw "Bundle suspiciously small ($($text.Length) bytes)"
            }
            Write-LogInfo "  Bundle: $($text.Length) bytes."
            return $text
        } catch {
            $lastErr = $_.Exception.Message
            Write-LogWarning "  $url failed: $lastErr"
        }
    }
    throw "All WinUtil bundle URLs failed. Last error: $lastErr"
}

function Get-WinUtilConfigsFromBundle {
    <#
    Extracts the embedded $sync.configs.<name> = @'<json>'@ heredocs and
    returns a hashtable of { tweaks = <PSObject>; feature = <PSObject> }.
    #>
    param([Parameter(Mandatory)][string]$BundleSrc)

    $result = @{}
    foreach ($name in 'tweaks','feature') {
        # Match $sync.configs.<name> = @'<newline>...<newline>'@ across lines.
        # The bundle uses CRLF; ConvertFrom-Json handles either.
        $pattern = ('\$sync\.configs\.' + [regex]::Escape($name) + "\s*=\s*@'\r?\n([\s\S]*?)\r?\n'@")
        $m = [regex]::Match($BundleSrc, $pattern)
        if (-not $m.Success) {
            throw "Could not locate `$sync.configs.$name in WinUtil bundle (regex mismatch)."
        }
        try {
            $obj = $m.Groups[1].Value | ConvertFrom-Json
        } catch {
            throw "Failed to parse `$sync.configs.$name JSON from bundle: $($_.Exception.Message)"
        }
        $result[$name] = $obj
        $count = @($obj.PSObject.Properties).Count
        Write-LogInfo "  Bundle.${name}: $count entries."
    }
    return $result
}

function Set-WinUtilRegistryEntry {
    <#
    Applies one WinUtil-style registry entry. Rewrites HKCU: to every
    mounted user hive root so SYSTEM context still reaches the real user(s).
    HKLM:, HKU:, and absolute Registry:: paths are written as-is.
    #>
    param(
        [Parameter(Mandatory)][PSObject]$Entry,
        [string]$TweakId = ''
    )

    $path  = [string]$Entry.Path
    $rName = [string]$Entry.Name
    $rVal  = $Entry.Value
    $rType = if ($Entry.PSObject.Properties.Name -contains 'Type' -and $Entry.Type) { [string]$Entry.Type } else { 'DWord' }

    # WinUtil presets sometimes use '<RemoveEntry>' as Value to indicate the
    # entry should be deleted. We treat that as "no-op" in apply mode since
    # the entry already not existing == the desired state.
    if ($rVal -is [string] -and $rVal -eq '<RemoveEntry>') {
        Write-LogInfo "  [$TweakId] skip $path\$rName (Value = <RemoveEntry>)"
        return
    }

    # Coerce DWord/QWord values: bundle stores them as strings.
    if ($rType -eq 'DWord' -or $rType -eq 'QWord') {
        try { $rVal = [int64]$rVal } catch { }
    }

    if ($path -match '^HKCU:(?<rest>.*)$') {
        $rest = $Matches['rest']
        foreach ($root in (Get-AllUserRoots)) {
            Set-Reg ($root + $rest) $rName $rVal $rType
        }
    } else {
        # HKU: paths require a PSDrive (Set-ItemProperty's provider lookup
        # for HKU is not registered by default on PS 5.1).
        if ($path -match '^HKU:' -and -not (Get-PSDrive -Name 'HKU' -ErrorAction SilentlyContinue)) {
            try { New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null } catch {}
        }
        Set-Reg $path $rName $rVal $rType
    }
}

function Set-WinUtilServiceEntry {
    <#
    Sets a Windows service startup type. Handles two quirks in WinUtil's
    own data: (1) some entries use 'Disable' (typo) instead of 'Disabled',
    and (2) 'AutomaticDelayedStart' is not a valid -StartupType for
    Set-Service on PS 5.1 -- has to go through sc.exe. Skips silently if
    the service doesn't exist on this SKU.
    #>
    param(
        [Parameter(Mandatory)][PSObject]$Entry,
        [string]$TweakId = ''
    )
    $sName = [string]$Entry.Name
    $sType = [string]$Entry.StartupType
    if (-not $sType) { return }

    # Normalize WinUtil's quirks
    if ($sType -eq 'Disable') { $sType = 'Disabled' }

    try {
        $svc = Get-Service -Name $sName -ErrorAction Stop
        if ($sType -eq 'AutomaticDelayedStart') {
            & sc.exe config $sName start= delayed-auto | Out-Null
            Write-LogInfo "  [$TweakId] service $sName -> delayed-auto (sc.exe)"
            return
        }
        if ($svc.StartType.ToString() -eq $sType) {
            Write-LogInfo "  [$TweakId] service $sName already $sType"
            return
        }
        Set-Service -Name $sName -StartupType $sType -ErrorAction Stop
        Write-LogInfo "  [$TweakId] service $sName -> $sType"
    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        Write-LogInfo "  [$TweakId] service $sName not present on this SKU; skipping."
    } catch {
        Write-LogWarning "  [$TweakId] service ${sName}: $($_.Exception.Message)"
    }
}

function Enable-WinUtilWindowsFeature {
    <#
    Enables a Windows optional feature. -NoRestart prevents the cmdlet from
    rebooting -- WindowsUpdate runs after WinTweaks and the orchestrator
    triggers reboots itself.
    #>
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [string]$TweakId = ''
    )
    try {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        if ($state.State -eq 'Enabled') {
            Write-LogInfo "  [$TweakId] feature $FeatureName already enabled."
            return
        }
        Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -All -ErrorAction Stop | Out-Null
        Write-LogInfo "  [$TweakId] feature $FeatureName enabled."
    } catch {
        Write-LogWarning "  [$TweakId] feature ${FeatureName}: $($_.Exception.Message)"
    }
}

function Invoke-WinUtilScriptEntry {
    <#
    Executes a WinUtil InvokeScript string. Captures all output streams into
    the log; never re-throws so one bad script can't sink the whole pass.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [string]$TweakId = ''
    )
    if ([string]::IsNullOrWhiteSpace($ScriptText)) { return }
    Write-LogInfo "  [$TweakId] InvokeScript ($($ScriptText.Length) chars):"
    try {
        $sb = [scriptblock]::Create($ScriptText)
        $output = & $sb 2>&1
        foreach ($line in $output) {
            $s = if ($null -eq $line) { '' } else { $line.ToString() }
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            Write-LogInfo "    > $s"
        }
    } catch {
        Write-LogWarning "  [$TweakId] InvokeScript threw: $($_.Exception.Message)"
    }
}

function Invoke-WinUtilPresetEntry {
    <#
    Applies a single preset ID. Looks it up in tweaks first, then features.
    WPFInstall* IDs are deliberately skipped -- this repo owns app installs
    via data/profiles.json so we don't want WinUtil's installer fighting it.
    Returns a status string for the per-ID report.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][PSObject]$TweaksConfig,
        [Parameter(Mandatory)][PSObject]$FeatureConfig
    )

    if ($Id -like 'WPFInstall*') {
        Write-LogInfo "  $Id -> skipped (installs are owned by profiles.json)"
        return 'skipped-install'
    }

    $entry = $null
    $bucket = $null
    if ($TweaksConfig.PSObject.Properties.Name -contains $Id) {
        $entry = $TweaksConfig.$Id; $bucket = 'tweak'
    } elseif ($FeatureConfig.PSObject.Properties.Name -contains $Id) {
        $entry = $FeatureConfig.$Id; $bucket = 'feature'
    } else {
        Write-LogWarning "  $Id -> not found in WinUtil bundle (renamed upstream?)"
        return 'unknown'
    }

    Write-LogInfo "  $Id ($bucket): applying"

    $propNames = @($entry.PSObject.Properties.Name)

    if ($propNames -contains 'registry' -and $entry.registry) {
        foreach ($r in @($entry.registry)) {
            Set-WinUtilRegistryEntry -Entry $r -TweakId $Id
        }
    }
    if ($propNames -contains 'service' -and $entry.service) {
        foreach ($s in @($entry.service)) {
            Set-WinUtilServiceEntry -Entry $s -TweakId $Id
        }
    }
    if ($propNames -contains 'feature' -and $entry.feature) {
        foreach ($f in @($entry.feature)) {
            Enable-WinUtilWindowsFeature -FeatureName $f -TweakId $Id
        }
    }
    if ($propNames -contains 'InvokeScript' -and $entry.InvokeScript) {
        foreach ($scr in @($entry.InvokeScript)) {
            Invoke-WinUtilScriptEntry -ScriptText $scr -TweakId $Id
        }
    }
    return 'applied'
}

function Get-WinUtilPresetIds {
    <#
    Parses config/winutil-preset.json. Supports two shapes:
      1. Flat array of IDs (WinDeploy's preferred format)
      2. Nested object { WPFTweaks: [...], WPFInstall: [...], WPFFeature: [...] }
         (WinUtil's GUI exporter writes this)
    ReadAllText (no encoding arg) auto-detects BOM so a fresh export saved
    as UTF-16 LE survives.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path)
    $obj = $raw | ConvertFrom-Json

    if ($obj -is [array]) { return @($obj) }

    $ids = @()
    foreach ($prop in 'WPFTweaks','WPFToggle','WPFInstall','WPFFeature') {
        if ($obj.PSObject.Properties.Name -contains $prop) {
            $ids += @($obj.$prop)
        }
    }
    return $ids
}

function Start-WinUtilPreset {
    $presetPath = Join-Path $repoRoot 'config\winutil-preset.json'

    if (-not (Test-Path $presetPath)) {
        Write-LogWarning "WinUtil preset not found at '$presetPath' -- skipping WinUtil pass."
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value 'skipped: preset missing' } catch {}
        return
    }

    $presetIds = @()
    try {
        $presetIds = @(Get-WinUtilPresetIds -Path $presetPath)
    } catch {
        Write-LogWarning "WinUtil preset parse failed: $($_.Exception.Message)"
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value "preset-parse-failed: $($_.Exception.Message)" } catch {}
        return
    }
    Write-LogInfo "WinUtil preset: $($presetIds.Count) IDs"

    $bundleSrc = $null
    try {
        $bundleSrc = Get-WinUtilBundle
    } catch {
        Write-LogWarning "WinUtil bundle download failed: $($_.Exception.Message)"
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value "bundle-download-failed: $($_.Exception.Message)" } catch {}
        return
    }

    $configs = $null
    try {
        $configs = Get-WinUtilConfigsFromBundle -BundleSrc $bundleSrc
    } catch {
        Write-LogWarning "WinUtil bundle parse failed: $($_.Exception.Message)"
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value "bundle-parse-failed: $($_.Exception.Message)" } catch {}
        return
    }

    $applied = 0; $skipped = 0; $unknown = @()
    foreach ($id in $presetIds) {
        $status = $null
        try {
            $status = Invoke-WinUtilPresetEntry -Id $id -TweaksConfig $configs['tweaks'] -FeatureConfig $configs['feature']
        } catch {
            Write-LogWarning "  $id threw: $($_.Exception.Message)"
            $status = 'error'
        }
        switch ($status) {
            'applied'           { $applied++ }
            'skipped-install'   { $skipped++ }
            'unknown'           { $unknown += $id }
            default             { }
        }
    }

    Write-LogSuccess "WinUtil direct apply: $applied applied, $skipped skipped, $($unknown.Count) unknown."
    try {
        Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome'         -Value 'direct-apply'
        Set-StageExtra -StageName $StageName -Key 'WinUtilPresetIdCount'   -Value $presetIds.Count
        Set-StageExtra -StageName $StageName -Key 'WinUtilAppliedCount'    -Value $applied
        Set-StageExtra -StageName $StageName -Key 'WinUtilSkippedCount'    -Value $skipped
        Set-StageExtra -StageName $StageName -Key 'WinUtilUnknownPresetIds' -Value $unknown
    } catch {
        Write-LogWarning "Could not write WinUtil StageExtras: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Pass 2: Direct registry tweaks (always applied)
# ---------------------------------------------------------------------------

function Set-DarkTheme {
    Write-LogSection 'Dark Theme'
    # Machine-wide (affects login screen)
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'   0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    # Every real user + default-user hive
    foreach ($root in (Get-AllUserRoots)) {
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'AppsUseLightTheme'   0
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'SystemUsesLightTheme' 0
    }
}

function Remove-BingSearch {
    Write-LogSection 'Remove Bing Search'
    # Policy: machine-wide
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'           'DisableWebSearch'        1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'           'ConnectedSearchUseWeb'   0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'           'AllowCortana'            0
    # Per-user
    foreach ($root in (Get-AllUserRoots)) {
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"             'BingSearchEnabled'       0
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"             'CortanaConsent'          0
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"             'SearchboxTaskbarMode'    1
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings"     'IsDynamicSearchBoxEnabled' 0
    }
}

function Set-NumLockOn {
    $numLockEnabled = $true
    if ($Config['WinTweaks'] -and $Config['WinTweaks']['NumLockOnStartup'] -eq $false) {
        $numLockEnabled = $false
    }

    if (-not $numLockEnabled) {
        Write-LogInfo 'NumLock on startup disabled via config. Skipping.'
        return
    }

    Write-LogSection 'NumLock on at startup'
    # .DEFAULT hive = login screen
    Set-Reg 'Registry::HKU\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' String
    # Every real user + default-user hive
    foreach ($root in (Get-AllUserRoots)) {
        Set-Reg "$root\Control Panel\Keyboard" 'InitialKeyboardIndicators' '2' String
    }
}

function Set-VerboseLogin {
    Write-LogSection 'Verbose login messages'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1
    try {
        & bcdedit.exe /set '{current}' bootstatuspolicy DisplayAllFailures 2>$null | Out-Null
        Write-LogInfo '  bcdedit: boot status policy set to DisplayAllFailures'
    } catch {
        Write-LogWarning "  bcdedit failed (non-fatal): $($_.Exception.Message)"
    }
}

function Set-DisplayScale {
    $displayScale = 100
    if ($Config['WinTweaks'] -and $Config['WinTweaks']['DisplayScale']) {
        $displayScale = $Config['WinTweaks']['DisplayScale']
    }
    $dpi = [int](96 * $displayScale / 100)

    Write-LogSection "Display scaling -> $displayScale% [$dpi DPI]"

    # Every real user + default-user hive
    foreach ($root in (Get-AllUserRoots)) {
        Set-Reg "$root\Control Panel\Desktop" 'LogPixels'      $dpi DWord
        Set-Reg "$root\Control Panel\Desktop" 'Win8DpiScaling'  1 DWord

        # Clear per-monitor DPI overrides (Windows 11)
        $perMonitorKey = "$root\Control Panel\Desktop\PerMonitorSettings"
        if (Test-Path $perMonitorKey) {
            Get-ChildItem $perMonitorKey -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-ItemProperty -Path $_.PSPath -Name 'DpiValue' -ErrorAction SilentlyContinue
            }
            Write-LogInfo "  Cleared per-monitor DPI overrides under $root."
        }
    }

    Write-LogInfo "  Display scale set to $displayScale% [$dpi DPI]. Takes effect after reboot."
}

function Install-WingetApps {
    Write-LogSection 'Winget app installs'

    # Load app list from config profile
    $profileName = 'Default'
    if ($Config['WinTweaks'] -and $Config['WinTweaks']['AppProfile']) {
        $profileName = $Config['WinTweaks']['AppProfile']
    }

    $profilesFile = Join-Path (Split-Path $coreDir -Parent) 'data\profiles.json'
    $apps = @()
    if (Test-Path $profilesFile) {
        try {
            $profiles = Get-Content $profilesFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $profileApps = $profiles.$profileName
            if ($profileApps) {
                $apps = @($profileApps)
            } else {
                Write-LogWarning "Profile '$profileName' not found in profiles.json. Using empty list."
            }
        } catch {
            Write-LogWarning "Failed to load profiles.json: $($_.Exception.Message)"
        }
    } else {
        Write-LogWarning "profiles.json not found at '$profilesFile'. Skipping app installs."
    }

    foreach ($app in $apps) {
        try {
            # --source winget required: msstore TLS cert pinning fails under SYSTEM
            # (exit 0x8A15005E). See core/Winget.psm1.
            $result = Invoke-WingetCli -Description "Install $($app.Name)" -ArgList @(
                'install',
                '--id', $app.Id,
                '--source', 'winget',
                '--silent',
                '--accept-package-agreements',
                '--accept-source-agreements',
                '--disable-interactivity'
            )
            if (-not $result.Success) {
                Write-LogWarning "$($app.Name) install did not succeed: $($result.Meaning)"
            }
        } catch {
            Write-LogWarning "$($app.Name) install threw: $($_.Exception.Message)"
        }
    }
}

function Set-AdditionalTweaks {
    Write-LogSection 'Additional tweaks'

    # Machine-wide tweaks (HKLM)
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'           0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                'AllowTelemetry'           0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed'          0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities'       0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities'        0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' String
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0

    # Per-user tweaks
    foreach ($root in (Get-AllUserRoots)) {
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt'        0
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Hidden'             1
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"          'ShowRecent'         0
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"          'ShowFrequent'       0
        Set-Reg "$root\SOFTWARE\Microsoft\GameBar"                                   'AutoGameModeEnabled' 0
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowSecondsInSystemClock' 1
        Set-Reg "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" 'TaskbarEndTask' 1
    }

    # Timezone is owned by the TimeSync stage (runs before this one).
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-LogInfo "Stage '$StageName' starting."

    $runWinUtil = if ($Config['WinTweaks'] -and $Config['WinTweaks']['RunWinUtil'] -eq $false) {
        $false
    } else { $true }

    # Mount user hives once for both passes. Pass 1 (WinUtil direct apply)
    # needs them so HKCU: paths can be rewritten to each user. Pass 2
    # touches the same hives directly.
    Mount-AllUserHives
    try {
        if ($runWinUtil) {
            Write-LogSection 'Pass 1: WinUtil preset (direct apply)'
            try { Start-WinUtilPreset } catch { Write-LogWarning "WinUtil pass threw: $($_.Exception.Message)" }
        } else {
            Write-LogInfo 'WinUtil pass skipped (RunWinUtil = false in config).'
        }

        Write-LogSection 'Pass 2: Direct registry tweaks'
        Set-DarkTheme
        Remove-BingSearch
        Set-NumLockOn
        Set-VerboseLogin
        Set-DisplayScale
        Set-AdditionalTweaks
    } finally {
        Dismount-AllUserHives
    }

    # Winget app installs (no hive dependency)
    Install-WingetApps

    Write-LogSuccess 'WinTweaks stage complete.'
    Close-Logger -FinalStatus 'SUCCESS'
    return @{ Status = 'Complete'; Message = 'Windows tweaks applied.' }

} catch {
    Write-LogError "WinTweaks stage failed: $($_.Exception.Message)"
    Close-Logger -FinalStatus 'FAILED'
    return @{ Status = 'Failed'; Message = $_.Exception.Message }
}
