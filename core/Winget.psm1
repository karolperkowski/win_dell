#Requires -Version 5.1
<#
.SYNOPSIS
    Winget interaction helpers - single canonical place to own:
      - Locating winget.exe (not on PATH under SYSTEM)
      - Patching $env:PATH with VCLibs / UI.Xaml dirs (winget under SYSTEM
        otherwise fails with STATUS_DLL_NOT_FOUND 0xC0000135)
      - Capturing winget output WITHOUT polluting the script return pipeline
        (the silent "Object[] returned instead of hashtable" bug)
      - Translating cryptic winget exit codes into human-readable causes
      - Pre-flight source health check before any install stage runs

.NOTES
    Microsoft documents that the winget CLI is not officially supported in
    the system context. We use it from the SYSTEM-context orchestrator
    anyway because it is the right tool for the job and the failures we
    have hit so far (msstore TLS cert pinning) are dodged by passing
    --source winget. If we ever hit a failure that --source winget cannot
    work around, the next step is to launch winget in the logged-in user's
    session via the same Start-ProcessInUserSession helper WinTweaks uses
    for WinUtil.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking -Force

# Known winget exit codes -> human-readable meanings.
# Source: src/AppInstallerSharedLib/Public/AppInstallerErrors.h in
# microsoft/winget-cli. Add codes here as we encounter them; unknown
# codes fall through to a generic message.
$Script:WINGET_EXIT_MEANINGS = @{
    0           = 'Success'
    -1978335189 = 'Already installed (0x8A15002B)'
    -1978335215 = 'No applicable installer for current system (0x8A150011)'
    -1978335212 = 'Multiple packages match the input criteria (0x8A150014)'
    -1978335211 = 'Cannot agree to package agreements (0x8A150015)'
    -1978335209 = 'Cannot agree to source agreements (0x8A150017)'
    -1978335200 = 'No package found matching input criteria (0x8A150020)'
    -1978335138 = 'TLS certificate pinning mismatch (0x8A15005E) - source server cert did not match expected. Common cause: msstore source under SYSTEM context, TLS interception by EDR/proxy, or stale machine root cert store.'
    -1978335129 = 'Update not applicable - package is up to date or no upgrade available (0x8A150067)'
    -1978335135 = 'Source data integrity failure (0x8A150061)'
    -1978335180 = 'Failed when searching the source (0x8A150034)'
}

function Get-WingetExitMeaning {
    <#
    .SYNOPSIS Translates a winget exit code to a human-readable cause string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$ExitCode)

    if ($Script:WINGET_EXIT_MEANINGS.ContainsKey($ExitCode)) {
        return $Script:WINGET_EXIT_MEANINGS[$ExitCode]
    }
    return "Unknown winget exit code: $ExitCode"
}

function Find-WingetExe {
    <#
    .SYNOPSIS
        Returns the full path to winget.exe and patches $env:PATH with the
        UWP dependency directories. Safe to call multiple times - dependency
        path injection is idempotent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        $wingetExe = $wingetCmd.Path
    } else {
        $wingetPath = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' `
                        -ErrorAction SilentlyContinue |
                      Sort-Object { $_.Directory.Name } -Descending |
                      Select-Object -First 1
        if (-not $wingetPath) {
            throw 'winget not found. winget ships with App Installer from the Microsoft Store.'
        }
        $wingetExe = $wingetPath.FullName
        Write-LogInfo "winget found at: $wingetExe"
    }

    # When running as SYSTEM, winget's UWP dependencies (VCLibs, UI.Xaml) are
    # not on PATH, causing STATUS_DLL_NOT_FOUND (0xC0000135). Inject them.
    $depDirs = @(
        Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.VCLibs.140.00.UWPDesktop_*_x64__8wekyb3d8bbwe' `
            -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.UI.Xaml.2.8_*_x64__8wekyb3d8bbwe' `
            -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    ) | Where-Object { $_ }

    if ($depDirs) {
        $extraPaths = ($depDirs | ForEach-Object { $_.FullName }) -join ';'
        if ($env:PATH -notlike "*$extraPaths*") {
            $env:PATH = "$extraPaths;$env:PATH"
            Write-LogInfo "Added winget dependency paths: $extraPaths"
        }
    }

    return $wingetExe
}

function Invoke-WingetCli {
    <#
    .SYNOPSIS
        Invokes winget with arbitrary args. Captures stdout+stderr without
        polluting the script's return pipeline, logs each line, returns a
        structured result.

    .DESCRIPTION
        Replaces the previous inline pattern:
            & $wingetExe install --id X --silent ... 2>&1
        which let winget's output flow into the script's return pipeline,
        producing Object[] when the script later returned a hashtable
        (observed 2026-05-16 in InstallTailscale - the orchestrator rejected
        the stage result with "Expected hashtable with 'Status' key").

    .OUTPUTS
        Hashtable: @{ ExitCode = int; Success = bool; Meaning = string; Output = string[] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$ArgList,
        [int[]]$SuccessExitCodes = @(0, -1978335189),
        [string]$Description = 'winget'
    )

    $exe = Find-WingetExe
    Write-LogInfo "$Description : winget $($ArgList -join ' ')"

    # Variable assignment + 2>&1 captures both streams into $captured so
    # nothing leaks into the caller's return pipeline.
    $captured = @(& $exe @ArgList 2>&1)
    $exitCode = $LASTEXITCODE

    foreach ($line in $captured) {
        if ($null -ne $line -and "$line".Trim().Length -gt 0) {
            Write-LogInfo "  winget: $line"
        }
    }

    $meaning = Get-WingetExitMeaning -ExitCode $exitCode
    $success = $SuccessExitCodes -contains $exitCode

    if ($success) {
        Write-LogSuccess "$Description succeeded (exit $exitCode -- $meaning)."
    } else {
        Write-LogWarning "$Description failed (exit $exitCode -- $meaning)."
    }

    return @{
        ExitCode = [int]$exitCode
        Success  = [bool]$success
        Meaning  = $meaning
        Output   = $captured
    }
}

function Test-WingetSourceHealth {
    <#
    .SYNOPSIS
        Pre-flight: confirms winget can list the named source. If this fails
        every install will fail too, so the orchestrator can flag a clear
        cause instead of letting the consecutive-failure budget burn down.

    .OUTPUTS
        Hashtable: @{ Healthy = bool; ExitCode = int; Meaning = string; SourceListed = bool }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$SourceName = 'winget')

    try {
        $result = Invoke-WingetCli `
                    -ArgList @('source','list','--name',$SourceName) `
                    -SuccessExitCodes @(0) `
                    -Description "winget source health (source=$SourceName)"
        $sourceListed = $false
        foreach ($line in $result.Output) {
            if ("$line" -match [regex]::Escape($SourceName)) {
                $sourceListed = $true
                break
            }
        }
        return @{
            Healthy      = ($result.Success -and $sourceListed)
            ExitCode     = $result.ExitCode
            Meaning      = $result.Meaning
            SourceListed = $sourceListed
        }
    } catch {
        return @{
            Healthy      = $false
            ExitCode     = -1
            Meaning      = "Exception: $($_.Exception.Message)"
            SourceListed = $false
        }
    }
}

Export-ModuleMember -Function @(
    'Get-WingetExitMeaning'
    'Find-WingetExe'
    'Invoke-WingetCli'
    'Test-WingetSourceHealth'
)
