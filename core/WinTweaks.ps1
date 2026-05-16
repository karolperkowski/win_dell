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
# Pass 1: WinUtil unattended preset
# ---------------------------------------------------------------------------
# The two launch paths (user-session GUI vs. SYSTEM headless) share a single
# child-script body produced by Get-WinUtilChildScriptBody. The child:
#   1. Starts a transcript at $ChildLog so its output reaches windeploy.log.
#   2. Downloads the WinUtil bundle.
#   3. Catalogs the WPF{Install|Tweaks|Feature|Toggle} IDs the bundle declares,
#      compares them with the preset, and records unknown IDs to $ChildMeta.
#   4. In GUI mode: regex-patches Invoke-WinUtilAutoRun to auto-close the
#      form. If the patch matches 0 sites, falls back to -Noui inline.
#      In headless mode: runs -Noui directly.
#   5. Writes a structured outcome to $ChildMeta.
# The parent reads $ChildMeta + $ChildLog after the child exits and surfaces
# outcome into windeploy.log and StageExtras so a silent "did nothing" run is
# no longer invisible.

function Get-WinUtilChildScriptBody {
    param(
        [Parameter(Mandatory)][string]$PresetPath,
        [Parameter(Mandatory)][string]$ChildLog,
        [Parameter(Mandatory)][string]$ChildMeta,
        [Parameter(Mandatory)][ValidateSet('GUI-AutoClose','Headless')][string]$Mode
    )

    $escapedPreset = $PresetPath -replace "'","''"
    $escapedLog    = $ChildLog   -replace "'","''"
    $escapedMeta   = $ChildMeta  -replace "'","''"
    $wantHeadless  = if ($Mode -eq 'Headless') { '$true' } else { '$false' }

    return @"
`$ErrorActionPreference = 'Continue'

# Prefer Tls12+Tls13. The string-flag parse + SChannel assignment can fail on
# older Windows builds where Tls13 is not negotiable - fall back to Tls12.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

`$childLog     = '$escapedLog'
`$childMeta    = '$escapedMeta'
`$presetPath   = '$escapedPreset'
`$wantHeadless = $wantHeadless

try { Start-Transcript -Path `$childLog -Force -IncludeInvocationHeader | Out-Null } catch {}

`$meta = [ordered]@{
    LaunchMode         = if (`$wantHeadless) { 'headless-noui' } else { 'gui-autoclose' }
    BundleBytes        = 0
    BundleIdCount      = 0
    PresetIds          = @()
    KnownIds           = @()
    UnknownIds         = @()
    AutoClosePatchHits = 0
    ExitReason         = 'unknown'
}

try {
    Write-Host '[WinDeploy] Downloading WinUtil bootstrap script...'
    `$winutilSrc = Invoke-RestMethod 'https://christitus.com/win'
    `$meta.BundleBytes = `$winutilSrc.Length
    Write-Host ("[WinDeploy] Bundle size: {0} bytes." -f `$meta.BundleBytes)

    # Catalog every WPF{Install|Tweaks|Feature|Toggle} key the bundle declares.
    # These appear as JSON-style keys inside the bundle's inlined config blobs.
    `$bundleIdRegex = '"(WPF(?:Install|Tweaks|Feature[s]?|Toggle)\w+)"\s*:'
    `$bundleIds = @{}
    foreach (`$m in [regex]::Matches(`$winutilSrc, `$bundleIdRegex)) {
        `$bundleIds[`$m.Groups[1].Value] = `$true
    }
    `$meta.BundleIdCount = `$bundleIds.Count
    Write-Host ("[WinDeploy] Bundle declares {0} IDs." -f `$bundleIds.Count)

    # Parse preset - accept flat-array or nested {WPFTweaks,WPFInstall,WPFFeature}.
    # ReadAllText (no encoding arg) auto-detects BOM, so a fresh WinUtil export
    # saved as UTF-16 LE survives without manual conversion.
    `$presetRaw = [System.IO.File]::ReadAllText(`$presetPath)
    `$presetObj = `$presetRaw | ConvertFrom-Json
    `$presetIds = @()
    if (`$presetObj -is [array]) {
        `$presetIds = @(`$presetObj)
    } else {
        foreach (`$prop in 'WPFTweaks','WPFInstall','WPFFeature') {
            if (`$presetObj.PSObject.Properties.Name -contains `$prop) {
                `$presetIds += @(`$presetObj.`$prop)
            }
        }
    }
    `$meta.PresetIds  = `$presetIds
    `$meta.KnownIds   = @(`$presetIds | Where-Object { `$bundleIds.ContainsKey(`$_) })
    `$meta.UnknownIds = @(`$presetIds | Where-Object { -not `$bundleIds.ContainsKey(`$_) })
    Write-Host ("[WinDeploy] Preset: {0} total, {1} known, {2} unknown." -f `
        `$meta.PresetIds.Count, `$meta.KnownIds.Count, `$meta.UnknownIds.Count)
    if (`$meta.UnknownIds.Count -gt 0) {
        Write-Host ("[WinDeploy] WARNING: unknown IDs (silently dropped by WinUtil): " + (`$meta.UnknownIds -join ', '))
    }

    if (`$wantHeadless) {
        Write-Host '[WinDeploy] Running WinUtil headless (-Noui)...'
        & ([scriptblock]::Create(`$winutilSrc)) -Config `$presetPath -Run -Noui
        `$meta.ExitReason = ("headless-exit-{0}" -f `$LASTEXITCODE)
    } else {
        # After Invoke-WinUtilAutoRun returns, close the form on its dispatcher
        # thread so ShowDialog() returns and powershell.exe exits cleanly.
        # Without this, the WPF window stays open and only the orchestrator's
        # timeout would unblock the stage - which it would mark SUCCESS with
        # nothing actually applied.
        `$replacement = 'Invoke-WinUtilAutoRun; Start-Sleep -Seconds 3; try { `$sync["Form"].Dispatcher.Invoke([action]{ `$sync["Form"].Close() }) } catch {}'
        `$pattern     = '(?<!function )Invoke-WinUtilAutoRun(?!\w)'
        `$patched     = [regex]::Replace(`$winutilSrc, `$pattern, `$replacement)
        `$meta.AutoClosePatchHits = ([regex]::Matches(`$winutilSrc, `$pattern)).Count
        Write-Host ("[WinDeploy] Auto-close patch applied to {0} call site(s)." -f `$meta.AutoClosePatchHits)

        if (`$meta.AutoClosePatchHits -lt 1) {
            Write-Host '[WinDeploy] Patch matched 0 sites - falling back to headless (-Noui) inline.'
            `$meta.LaunchMode = 'gui-patch-miss-headless-fallback'
            & ([scriptblock]::Create(`$winutilSrc)) -Config `$presetPath -Run -Noui
            `$meta.ExitReason = ("headless-inline-exit-{0}" -f `$LASTEXITCODE)
        } else {
            Write-Host '[WinDeploy] Launching WinUtil with patched bundle...'
            & ([scriptblock]::Create(`$patched)) -Config `$presetPath -Run
            `$meta.ExitReason = ("gui-exit-{0}" -f `$LASTEXITCODE)
        }
    }
    Write-Host '[WinDeploy] WinUtil child exiting.'
} catch {
    `$meta.ExitReason = ("exception: {0}" -f `$_.Exception.Message)
    Write-Host ("[WinDeploy] ERROR: {0}" -f `$_.Exception.Message)
} finally {
    try {
        `$meta | ConvertTo-Json -Depth 5 | Set-Content -Path `$childMeta -Encoding UTF8 -Force
    } catch {
        Write-Host ("[WinDeploy] WARN: could not write meta to {0}: {1}" -f `$childMeta, `$_.Exception.Message)
    }
    try { Stop-Transcript | Out-Null } catch {}
}
"@
}

function Invoke-WinUtilHeadlessFallback {
    <#
    Headless fallback: run WinUtil with -Noui in this (SYSTEM) session.
    Used when no interactive user is logged in OR when the GUI launcher
    failed / timed out. Writes to the same ChildLog/ChildMeta as the GUI
    path so the parent reads a single, authoritative outcome record.
    #>
    param(
        [Parameter(Mandatory)][string]$PresetPath,
        [Parameter(Mandatory)][string]$ChildLog,
        [Parameter(Mandatory)][string]$ChildMeta,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    $tempScript = Join-Path $env:TEMP "windeploy_winutil_noui_$([guid]::NewGuid().ToString('N')).ps1"
    try {
        $body = Get-WinUtilChildScriptBody -PresetPath $PresetPath -ChildLog $ChildLog `
                                            -ChildMeta $ChildMeta -Mode 'Headless'
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

function Read-WinUtilChildOutcome {
    <#
    Ingests the child transcript into windeploy.log and the child meta into
    StageExtras. Always runs after both GUI and headless paths so the
    orchestrator never silently swallows a WinUtil failure.
    #>
    param(
        [Parameter(Mandatory)][string]$ChildLog,
        [Parameter(Mandatory)][string]$ChildMeta,
        [Parameter(Mandatory)][string]$StageName
    )

    if (Test-Path $ChildLog) {
        Write-LogInfo '--- WinUtil child transcript begin ---'
        Get-Content -Path $ChildLog -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-LogInfo "  $_" }
        Write-LogInfo '--- WinUtil child transcript end ---'
    } else {
        Write-LogWarning "WinUtil child transcript not found at $ChildLog"
    }

    if (-not (Test-Path $ChildMeta)) {
        Write-LogWarning "WinUtil child meta not found at $ChildMeta - cannot summarize outcome."
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value 'no-meta-file' } catch {}
        return
    }

    $meta = $null
    try {
        $meta = Get-Content -Raw -Path $ChildMeta -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-LogWarning "WinUtil meta parse failed: $($_.Exception.Message)"
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value 'meta-parse-failed' } catch {}
        return
    }

    $presetCount  = @($meta.PresetIds).Count
    $knownCount   = @($meta.KnownIds).Count
    $unknownCount = @($meta.UnknownIds).Count
    $unknownList  = @($meta.UnknownIds)

    Write-LogInfo ("WinUtil outcome: mode={0}, autoClosePatchHits={1}, presetIds={2} ({3} known, {4} unknown), exit={5}" -f `
        $meta.LaunchMode, $meta.AutoClosePatchHits, $presetCount, $knownCount, $unknownCount, $meta.ExitReason)

    if ($unknownCount -gt 0) {
        Write-LogWarning ("Unknown preset IDs (silently dropped by WinUtil): " + ($unknownList -join ', '))
    }

    try {
        Set-StageExtra -StageName $StageName -Key 'WinUtilLaunchMode'         -Value $meta.LaunchMode
        Set-StageExtra -StageName $StageName -Key 'WinUtilAutoClosePatchHits' -Value $meta.AutoClosePatchHits
        Set-StageExtra -StageName $StageName -Key 'WinUtilPresetIdCount'     -Value $presetCount
        Set-StageExtra -StageName $StageName -Key 'WinUtilKnownIdCount'      -Value $knownCount
        Set-StageExtra -StageName $StageName -Key 'WinUtilUnknownPresetIds'  -Value $unknownList
        Set-StageExtra -StageName $StageName -Key 'WinUtilExitReason'        -Value $meta.ExitReason
        Set-StageExtra -StageName $StageName -Key 'WinUtilBundleIdCount'     -Value $meta.BundleIdCount
    } catch {
        Write-LogWarning "Could not write WinUtil StageExtras: $($_.Exception.Message)"
    }
}

function Start-WinUtilPreset {
    $presetPath = Join-Path $repoRoot 'config\winutil-preset.json'

    if (-not (Test-Path $presetPath)) {
        Write-LogWarning "WinUtil preset not found at '$presetPath' -- skipping WinUtil pass."
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value 'skipped: preset missing' } catch {}
        return
    }

    $timeoutMs = $WD.WinUtilTimeoutMs
    $id        = [guid]::NewGuid().ToString('N')

    # LogDir is owned by SYSTEM but inherits ProgramData permissions so the
    # user-session child can write here too.
    if (-not (Test-Path $WD.LogDir)) {
        New-Item -ItemType Directory -Path $WD.LogDir -Force | Out-Null
    }
    $childLog  = Join-Path $WD.LogDir "winutil-child-$id.log"
    $childMeta = Join-Path $WD.LogDir "winutil-child-$id.meta.json"

    $tempScript = Join-Path $env:TEMP "windeploy_winutil_$id.ps1"
    try {
        $body = Get-WinUtilChildScriptBody -PresetPath $presetPath -ChildLog $childLog `
                                            -ChildMeta $childMeta -Mode 'GUI-AutoClose'
        [System.IO.File]::WriteAllText($tempScript, $body, [System.Text.Encoding]::UTF8)
        Write-LogInfo "WinUtil launcher script: $tempScript"
        Write-LogInfo "WinUtil child log:       $childLog"
        Write-LogInfo "WinUtil child meta:      $childMeta"

        $cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""

        Write-LogInfo 'Attempting to launch WinUtil in user desktop session (GUI + console)...'
        $result = Start-ProcessInUserSession -CommandLine $cmdLine -TimeoutMs $timeoutMs

        if ($null -eq $result) {
            Write-LogInfo 'No user session - falling back to headless (-Noui) mode.'
            Invoke-WinUtilHeadlessFallback -PresetPath $presetPath -ChildLog $childLog `
                                            -ChildMeta $childMeta -TimeoutMs $timeoutMs
        } elseif ($result -eq $false) {
            Write-LogWarning 'GUI launcher timed out -- retrying once with headless (-Noui) mode.'
            Invoke-WinUtilHeadlessFallback -PresetPath $presetPath -ChildLog $childLog `
                                            -ChildMeta $childMeta -TimeoutMs $timeoutMs
        }
    } catch {
        Write-LogWarning "WinUtil run failed: $($_.Exception.Message)"
        Write-LogWarning 'Continuing with direct registry tweaks.'
        try { Set-StageExtra -StageName $StageName -Key 'WinUtilOutcome' -Value "exception: $($_.Exception.Message)" } catch {}
    } finally {
        Remove-Item $tempScript -ErrorAction SilentlyContinue
        Read-WinUtilChildOutcome -ChildLog $childLog -ChildMeta $childMeta -StageName $StageName
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
