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
$WD = Get-WDConfig
Initialize-Logger -Stage $StageName

# ---------------------------------------------------------------------------
# Win32 helper: launch a process in the logged-in user's desktop session
# ---------------------------------------------------------------------------
# When running as SYSTEM we have no desktop. To show WinUtil's GUI on the
# real user's screen we must: get the console session → query the user token
# → obtain the linked elevated token (UAC) → CreateProcessAsUser targeting
# winsta0\Default.  Falls back gracefully if no user is logged in.

if (-not ('WinDeploy.SessionLauncher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WinDeploy
{
    public class SessionLauncher
    {
        // --- kernel32 ---
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr h, uint ms);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(IntPtr h, out uint code);

        // --- wtsapi32 ---
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

        // --- advapi32 ---
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DuplicateTokenEx(
            IntPtr hToken, uint access, IntPtr sa,
            int impersonation, int tokenType, out IntPtr newToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(
            IntPtr token, int infoClass, out IntPtr info, int len, out int retLen);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUserW(
            IntPtr hToken, string app, string cmdLine,
            IntPtr procAttr, IntPtr threadAttr, bool inherit,
            uint flags, IntPtr env, string cwd,
            ref STARTUPINFO si, out PROCESS_INFORMATION pi);

        // --- userenv ---
        [DllImport("userenv.dll", SetLastError = true)]
        public static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);

        [DllImport("userenv.dll")]
        public static extern bool DestroyEnvironmentBlock(IntPtr env);

        // --- structs ---
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public int    cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX, dwY, dwXSize, dwYSize;
            public int dwXCountChars, dwYCountChars, dwFillAttribute;
            public int    dwFlags;
            public short  wShowWindow;
            public short  cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint   dwProcessId;
            public uint   dwThreadId;
        }

        // --- constants ---
        public const uint TOKEN_ALL  = 0x000F01FF;
        public const int  SecurityImpersonation = 2;
        public const int  TokenPrimary = 1;
        public const int  TokenLinkedToken = 19;
        public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        public const uint WAIT_TIMEOUT  = 0x00000102;
        public const uint WAIT_OBJECT_0 = 0x00000000;

        /// <summary>
        /// Launch a command line on the active console user's desktop.
        /// Returns process handle + PID, or IntPtr.Zero if no user session.
        /// </summary>
        public static IntPtr Launch(string cmdLine, out uint pid)
        {
            pid = 0;
            uint sid = WTSGetActiveConsoleSessionId();
            if (sid == 0xFFFFFFFF) return IntPtr.Zero;   // no session

            IntPtr userToken;
            if (!WTSQueryUserToken(sid, out userToken))
                return IntPtr.Zero;

            // Try to get the linked elevated token (UAC).
            IntPtr elevated = IntPtr.Zero;
            IntPtr linkedRaw;
            int    retLen;
            if (GetTokenInformation(userToken, TokenLinkedToken,
                    out linkedRaw, IntPtr.Size, out retLen))
            {
                // linkedRaw IS the elevated token handle
                elevated = linkedRaw;
            }

            // If we got an elevated token, duplicate it as a primary token.
            // Otherwise fall back to the original user token.
            IntPtr launchToken;
            if (elevated != IntPtr.Zero)
            {
                if (!DuplicateTokenEx(elevated, TOKEN_ALL, IntPtr.Zero,
                        SecurityImpersonation, TokenPrimary, out launchToken))
                {
                    launchToken = userToken;  // fallback
                }
                CloseHandle(elevated);
            }
            else
            {
                DuplicateTokenEx(userToken, TOKEN_ALL, IntPtr.Zero,
                    SecurityImpersonation, TokenPrimary, out launchToken);
            }

            // Build environment block for the user
            IntPtr env;
            CreateEnvironmentBlock(out env, launchToken, false);

            var si = new STARTUPINFO();
            si.cb        = Marshal.SizeOf(si);
            si.lpDesktop = "winsta0\\default";

            PROCESS_INFORMATION pi;
            bool ok = CreateProcessAsUserW(
                launchToken, null, cmdLine,
                IntPtr.Zero, IntPtr.Zero, false,
                CREATE_UNICODE_ENVIRONMENT, env, null,
                ref si, out pi);

            // Cleanup
            if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
            CloseHandle(launchToken);
            CloseHandle(userToken);

            if (!ok) return IntPtr.Zero;

            pid = pi.dwProcessId;
            CloseHandle(pi.hThread);
            return pi.hProcess;   // caller must close after waiting
        }
    }
}
'@
}

function Start-ProcessInUserSession {
    <#
    Launches a command in the logged-in user's desktop session (visible GUI).
    Returns $true if the process ran and exited within the timeout.
    When no interactive user is logged in, returns $null (caller should fall back).
    #>
    param(
        [string]$CommandLine,
        [int]$TimeoutMs = 1200000   # 20 minutes
    )

    $pid2 = [uint32]0
    $hProc = [WinDeploy.SessionLauncher]::Launch($CommandLine, [ref]$pid2)

    if ($hProc -eq [IntPtr]::Zero) {
        Write-LogWarning 'No interactive user session found - cannot launch GUI process.'
        return $null
    }

    Write-LogInfo "Launched PID $pid2 in user session."

    $waitResult = [WinDeploy.SessionLauncher]::WaitForSingleObject($hProc, [uint32]$TimeoutMs)
    if ($waitResult -eq [WinDeploy.SessionLauncher]::WAIT_TIMEOUT) {
        Write-LogWarning "Process $pid2 exceeded timeout - killing."
        try { Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue } catch {}
        [WinDeploy.SessionLauncher]::CloseHandle($hProc) | Out-Null
        return $false
    }

    $exitCode = [uint32]0
    [WinDeploy.SessionLauncher]::GetExitCodeProcess($hProc, [ref]$exitCode) | Out-Null
    [WinDeploy.SessionLauncher]::CloseHandle($hProc) | Out-Null
    Write-LogInfo "Process exited with code $exitCode."
    return $true
}

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

        $profilePath = (Get-ItemProperty $_.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
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
# Pass 1: WinUtil unattended preset
# ---------------------------------------------------------------------------
function Invoke-WinUtilHeadlessFallback {
    <#
    Headless fallback: run WinUtil with -Noui in this (SYSTEM) session.
    Used when no interactive user is logged in OR when the GUI launcher
    failed / timed out.
    #>
    param(
        [string]$PresetPath,
        [int]$TimeoutMs
    )

    $tempScript = Join-Path $env:TEMP "windeploy_winutil_noui_$([guid]::NewGuid().ToString('N')).ps1"
    try {
        $body = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([ScriptBlock]::Create((Invoke-RestMethod 'https://christitus.com/win'))) ``
    -Config '$($PresetPath -replace "'","''")' -Run -Noui
"@
        [System.IO.File]::WriteAllText($tempScript, $body, [System.Text.Encoding]::UTF8)

        $proc = Start-Process powershell.exe `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tempScript`"" `
            -WindowStyle Hidden `
            -PassThru `
            -ErrorAction Stop

        $finished = $proc.WaitForExit($TimeoutMs)
        if (-not $finished) {
            Write-LogWarning "WinUtil (headless) exceeded $([int]($TimeoutMs/60000))-minute timeout - killing PID $($proc.Id)."
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        } else {
            Write-LogInfo "WinUtil (headless) exited with code: $($proc.ExitCode)"
        }
    } finally {
        Remove-Item $tempScript -ErrorAction SilentlyContinue
    }
}

function Start-WinUtilPreset {
    $presetPath = Join-Path $repoRoot 'config\winutil-preset.json'

    if (-not (Test-Path $presetPath)) {
        Write-LogWarning "WinUtil preset not found at '$presetPath' -- skipping WinUtil pass."
        return
    }

    $timeoutMs = $WD.WinUtilTimeoutMs

    # Write a temp launcher script. Passing complex iex commands through
    # CreateProcessAsUser's lpCommandLine mangles quote escaping; a file
    # avoids that entirely and also lets us set TLS in the child process.
    #
    # The launcher downloads WinUtil's bootstrap script as TEXT, monkey-
    # patches the Invoke-WinUtilAutoRun call site to close the WPF form on
    # the dispatcher thread immediately after auto-run completes, then
    # executes the patched scriptblock with -Config and -Run. Without the
    # patch, $sync.Form.ShowDialog() would block until the user manually
    # closes the window -- which is exactly the "system frozen" symptom we
    # are fixing.
    $tempScript = Join-Path $env:TEMP "windeploy_winutil_$([guid]::NewGuid().ToString('N')).ps1"
    try {
        $escapedPreset = $presetPath -replace "'","''"
        $scriptBody = @"
`$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host '[WinDeploy] Downloading WinUtil bootstrap script...'
`$winutilSrc = Invoke-RestMethod 'https://christitus.com/win'

# Auto-close hook: after Invoke-WinUtilAutoRun returns, give the UI a few
# seconds to settle, then close the form on its dispatcher thread so
# ShowDialog() returns and powershell.exe exits cleanly.
`$replacement = 'Invoke-WinUtilAutoRun; Start-Sleep -Seconds 3; try { `$sync["Form"].Dispatcher.Invoke([action]{ `$sync["Form"].Close() }) } catch {}'
`$pattern     = '(?<!function )Invoke-WinUtilAutoRun(?!\w)'

`$patched = [regex]::Replace(`$winutilSrc, `$pattern, `$replacement)
`$hits    = ([regex]::Matches(`$winutilSrc, `$pattern)).Count
Write-Host "[WinDeploy] Auto-close patch applied to `$hits call site(s)."

if (`$hits -lt 1) {
    Write-Host '[WinDeploy] WARNING: patch matched 0 sites -- running headless (-Noui) inline so the GUI cannot hang.'
    & ([scriptblock]::Create(`$winutilSrc)) -Config '$escapedPreset' -Run -Noui
    Write-Host '[WinDeploy] WinUtil (headless inline) exited.'
    exit 0
}

Write-Host '[WinDeploy] Launching WinUtil with Standard preset...'
& ([scriptblock]::Create(`$patched)) -Config '$escapedPreset' -Run
Write-Host '[WinDeploy] WinUtil exited.'
"@
        [System.IO.File]::WriteAllText($tempScript, $scriptBody,
            [System.Text.Encoding]::UTF8)
        Write-LogInfo "WinUtil launcher script: $tempScript"

        $cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""

        # Try launching in the logged-in user's session so WinUtil GUI
        # AND its console output are visible on the desktop.
        Write-LogInfo 'Attempting to launch WinUtil in user desktop session (GUI + console)...'
        $result = Start-ProcessInUserSession -CommandLine $cmdLine -TimeoutMs $timeoutMs

        if ($null -eq $result) {
            Write-LogInfo 'No user session - falling back to headless (-Noui) mode.'
            Invoke-WinUtilHeadlessFallback -PresetPath $presetPath -TimeoutMs $timeoutMs
        } elseif ($result -eq $false) {
            Write-LogWarning 'GUI launcher timed out -- retrying once with headless (-Noui) mode.'
            Invoke-WinUtilHeadlessFallback -PresetPath $presetPath -TimeoutMs $timeoutMs
        }
    } catch {
        Write-LogWarning "WinUtil run failed: $($_.Exception.Message)"
        Write-LogWarning 'Continuing with direct registry tweaks.'
    } finally {
        Remove-Item $tempScript -ErrorAction SilentlyContinue
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

    # Resolve winget path - not on PATH when running as SYSTEM
    $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        $wingetPath = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue |
                      Sort-Object { $_.Directory.Name } -Descending | Select-Object -First 1
        if ($wingetPath) {
            Write-LogInfo "winget found at: $($wingetPath.FullName)"
            $wingetExe = $wingetPath.FullName
        } else {
            Write-LogWarning 'winget not found - skipping app installs.'
            Write-LogWarning 'winget ships with App Installer from the Microsoft Store.'
            return
        }
    } else {
        $wingetExe = 'winget.exe'
    }

    # When running as SYSTEM, winget's UWP dependencies are not on PATH
    $depDirs = @(
        Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.VCLibs.140.00.UWPDesktop_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.UI.Xaml.2.8_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    ) | Where-Object { $_ }

    if ($depDirs) {
        $extraPaths = ($depDirs | ForEach-Object { $_.FullName }) -join ';'
        $env:PATH = "$extraPaths;$env:PATH"
        Write-LogInfo "Added winget dependency paths: $extraPaths"
    }

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
        Write-LogInfo "Installing $($app.Name) via winget..."
        try {
            & $wingetExe install `
                --id $app.Id `
                --silent `
                --accept-package-agreements `
                --accept-source-agreements `
                --disable-interactivity `
                2>&1

            if ($LASTEXITCODE -in @(0, -1978335189)) {
                Write-LogSuccess "$($app.Name) installed (or already present)."
            } else {
                Write-LogWarning "$($app.Name) winget exit code: $LASTEXITCODE"
            }
        } catch {
            Write-LogWarning "$($app.Name) install failed: $($_.Exception.Message)"
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
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1
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

    # Timezone
    $timezone = 'Eastern Standard Time'
    if ($Config['WinTweaks'] -and $Config['WinTweaks']['Timezone']) {
        $timezone = $Config['WinTweaks']['Timezone']
    }
    try {
        & tzutil.exe /s $timezone
        Write-LogInfo "  Timezone set to $timezone"
    } catch {
        Write-LogWarning "  tzutil failed: $($_.Exception.Message)"
    }
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
        try { Start-WinUtilPreset } catch { Write-LogWarning "WinUtil pass threw: $($_.Exception.Message)" }
    } else {
        Write-LogInfo 'WinUtil pass skipped (RunWinUtil = false in config).'
    }

    # Pass 2: Direct tweaks -- mount all user hives first
    Write-LogSection 'Pass 2: Direct registry tweaks'
    Mount-AllUserHives
    try {
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
