#Requires -Version 5.1
<#
.SYNOPSIS
    Unified troubleshooting entry point for WinDeploy. Three actions:
        Status    - read-only snapshot of state, logs, and Tailscale daemon
        Diagnose  - stage-specific deep diagnostic (extensible)
        Repair    - stage-specific recovery (destructive)

.DESCRIPTION
    Consolidates the ad-hoc diagnose-tailscale.ps1 / unstick-tailscale.ps1 /
    snapshot-status.ps1 scripts into one repo tool. Called manually by an
    operator OR automatically by:
        - core/Orchestrator.ps1 outer catch (on FATAL throw)
        - core/Orchestrator.ps1 consecutive-failure abort path
        - core/Resilience.psm1 watchdog (before killing a hung orchestrator)

    Snapshots are written to <LogDir>\auto-snapshot-<timestamp>[-<reason>].txt
    (or wherever -OutDir points) so the Monitor and a later operator can
    pick up the forensic state without re-deriving it.

.PARAMETER Action
    Status   : write a status snapshot. Always safe.
    Diagnose : stage-specific read-only diagnostic. Requires -Stage.
    Repair   : stage-specific destructive recovery. Requires -Stage.

.PARAMETER Stage
    Stage name (matches state.json CompletedStages entries) for Diagnose/Repair.
    Supported today: InstallTailscale.
    Adding a new stage = add a plugin block to $Script:StagePlugins below.

.PARAMETER OutDir
    Where to write snapshot files. Defaults to $WD.LogDir.

.PARAMETER Reason
    Optional free-text reason for an auto-triggered snapshot. Appears in the
    file name and the header so the operator immediately knows why this fired.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Troubleshoot.ps1 -Action Status

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Troubleshoot.ps1 `
        -Action Diagnose -Stage InstallTailscale

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Troubleshoot.ps1 `
        -Action Repair -Stage InstallTailscale
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Status','Diagnose','Repair')]
    [string]$Action,

    [string]$Stage,

    [string]$OutDir,

    [string]$Reason = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Resolve paths (Config.psm1 is optional - this tool must work even when the
# WinDeploy modules are unavailable, e.g. when called from a fresh shell or
# when the deploy is in an inconsistent state).
# ---------------------------------------------------------------------------
$Script:DeployRoot = 'C:\ProgramData\WinDeploy'
$Script:RepoDir    = Join-Path $Script:DeployRoot 'repo'
$Script:LogDir     = Join-Path $Script:DeployRoot 'Logs'
$Script:StateFile  = Join-Path $Script:DeployRoot 'state.json'
$Script:TsJsonFile = Join-Path $Script:DeployRoot 'tailscale.json'

$configPath = Join-Path $Script:RepoDir 'core\Config.psm1'
if (Test-Path $configPath) {
    try {
        Import-Module $configPath -DisableNameChecking -Force
        $wd = Get-WDConfig
        if ($wd) {
            $Script:DeployRoot = $wd.DeployRoot
            $Script:RepoDir    = $wd.RepoDir
            $Script:LogDir     = $wd.LogDir
            $Script:StateFile  = $wd.StateFile
            $Script:TsJsonFile = $wd.TailscaleJson
        }
    } catch {
        Write-Warning "Config.psm1 import failed; using fallback paths. $($_.Exception.Message)"
    }
}

if (-not $OutDir) { $OutDir = $Script:LogDir }
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Section {
    param([System.Text.StringBuilder]$Sb, [string]$Title)
    [void]$Sb.AppendLine('')
    [void]$Sb.AppendLine('=' * 78)
    [void]$Sb.AppendLine("  $Title")
    [void]$Sb.AppendLine('=' * 78)
}

function Add-StateSection {
    param([System.Text.StringBuilder]$Sb)
    Write-Section $Sb '1. state.json'
    if (-not (Test-Path $Script:StateFile)) {
        [void]$Sb.AppendLine('  state.json NOT FOUND')
        return
    }
    try {
        $state = Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        [void]$Sb.AppendLine(("  CurrentStage      : {0}" -f $state.CurrentStage))
        [void]$Sb.AppendLine(("  DeployComplete    : {0}" -f $state.DeployComplete))
        [void]$Sb.AppendLine(("  RebootCount       : {0}" -f $state.RebootCount))
        [void]$Sb.AppendLine(("  CompletedStages   : {0}" -f ($state.CompletedStages -join ', ')))
        [void]$Sb.AppendLine(("  FailedStages      : {0}" -f ($state.FailedStages -join ', ')))
        [void]$Sb.AppendLine(("  LastError         : {0}" -f $state.LastError))
        [void]$Sb.AppendLine(("  LastErrorStage    : {0}" -f $state.LastErrorStage))
        [void]$Sb.AppendLine(("  LastErrorTime     : {0}" -f $state.LastErrorTimestamp))
        if ($state.PSObject.Properties.Name -contains 'StageExtras' -and $state.StageExtras) {
            [void]$Sb.AppendLine('  StageExtras:')
            foreach ($p in $state.StageExtras.PSObject.Properties) {
                [void]$Sb.AppendLine(("    {0,-45} {1}" -f $p.Name, $p.Value))
            }
        }
    } catch {
        [void]$Sb.AppendLine("  Parse failed: $($_.Exception.Message)")
    }
}

function Add-TailscaleJsonSection {
    param([System.Text.StringBuilder]$Sb)
    Write-Section $Sb '2. tailscale.json (orchestrator <-> monitor handshake)'
    if (Test-Path $Script:TsJsonFile) {
        [void]$Sb.AppendLine((Get-Content $Script:TsJsonFile -Raw -Encoding UTF8))
    } else {
        [void]$Sb.AppendLine('  tailscale.json NOT FOUND')
    }
}

function Add-TaskResumeLogSection {
    param([System.Text.StringBuilder]$Sb, [int]$Tail = 80)
    Write-Section $Sb "3. task_resume.log (last $Tail lines)"
    $f = Join-Path $Script:LogDir 'task_resume.log'
    if (-not (Test-Path $f)) {
        [void]$Sb.AppendLine("  $f NOT FOUND")
        return
    }
    $info = Get-Item $f
    [void]$Sb.AppendLine("  File: $($info.FullName)")
    [void]$Sb.AppendLine(("  Size: {0} bytes, last write: {1}" -f $info.Length, $info.LastWriteTime))
    [void]$Sb.AppendLine('')
    Get-Content $f -Tail $Tail -Encoding UTF8 | ForEach-Object { [void]$Sb.AppendLine($_) }
}

function Add-LatestStageLogSection {
    param([System.Text.StringBuilder]$Sb, [int]$Tail = 80)
    Write-Section $Sb "4. Most recent per-stage log (last $Tail lines)"
    $stageLog = Get-ChildItem -Path $Script:LogDir -Filter '*_*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^bootstrap\.log|^early\.log|^session\.log|^task_' } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
    if (-not $stageLog) {
        [void]$Sb.AppendLine('  No per-stage logs found.')
        return
    }
    [void]$Sb.AppendLine("  File: $($stageLog.FullName)")
    [void]$Sb.AppendLine(("  Size: {0} bytes, last write: {1}" -f $stageLog.Length, $stageLog.LastWriteTime))
    [void]$Sb.AppendLine('')
    Get-Content $stageLog.FullName -Tail $Tail -Encoding UTF8 | ForEach-Object { [void]$Sb.AppendLine($_) }
}

function Add-TailscaleDaemonSection {
    param([System.Text.StringBuilder]$Sb)
    Write-Section $Sb '5. Tailscale daemon state (live)'
    $tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
    if (-not (Test-Path $tsExe)) {
        [void]$Sb.AppendLine('  tailscale.exe not installed.')
        return
    }
    try {
        $statusJson = & $tsExe status --json 2>$null
        if (-not $statusJson) {
            [void]$Sb.AppendLine('  tailscale status --json returned nothing.')
            return
        }
        $st = $statusJson | ConvertFrom-Json
        $selfHost = ''
        $selfIPs  = ''
        if ($st.Self) {
            $selfHost = $st.Self.HostName
            $selfIPs  = ($st.Self.TailscaleIPs -join ',')
        }
        [void]$Sb.AppendLine(("  BackendState : {0}" -f $st.BackendState))
        [void]$Sb.AppendLine(("  SelfHost     : {0}" -f $selfHost))
        [void]$Sb.AppendLine(("  SelfIPs      : {0}" -f $selfIPs))
        [void]$Sb.AppendLine(("  Version      : {0}" -f $st.Version))
    } catch {
        [void]$Sb.AppendLine("  Error: $($_.Exception.Message)")
    }
}

function Add-DeployedVersionSection {
    param([System.Text.StringBuilder]$Sb)
    Write-Section $Sb '6. Deployed code version'
    $versionFile = Join-Path $Script:RepoDir 'VERSION'
    if (Test-Path $versionFile) {
        [void]$Sb.AppendLine((Get-Content $versionFile -Raw -Encoding UTF8).TrimEnd())
    } else {
        [void]$Sb.AppendLine('  VERSION file not present (deployed code predates version stamping).')
    }
}

# ---------------------------------------------------------------------------
# Action: Status
# ---------------------------------------------------------------------------
function Invoke-StatusAction {
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $suffix = if ($Reason) { '-' + ($Reason -replace '[^A-Za-z0-9._-]', '_') } else { '' }
    $outFile = Join-Path $OutDir "auto-snapshot-$ts$suffix.txt"

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("WinDeploy status snapshot - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    if ($Reason) { [void]$sb.AppendLine("Reason: $Reason") }

    Add-StateSection           -Sb $sb
    Add-TailscaleJsonSection   -Sb $sb
    Add-TaskResumeLogSection   -Sb $sb
    Add-LatestStageLogSection  -Sb $sb
    Add-TailscaleDaemonSection -Sb $sb
    Add-DeployedVersionSection -Sb $sb

    $sb.ToString() | Set-Content -Path $outFile -Encoding UTF8 -Force
    Write-Host "Status snapshot written to: $outFile" -ForegroundColor Green

    # Surface the path so the Monitor module can pick it up. Stored under
    # $LogDir\latest-snapshot.txt so the monitor doesn't have to enumerate.
    try {
        $outFile | Set-Content -Path (Join-Path $Script:LogDir 'latest-snapshot.path') -Encoding UTF8 -Force
    } catch {
        Write-Warning "Could not update latest-snapshot.path pointer: $($_.Exception.Message)"
    }
    return $outFile
}

# ---------------------------------------------------------------------------
# Stage plugins (Diagnose / Repair)
# Add new stages by extending $Script:StagePlugins with a hashtable containing
# Diagnose / Repair scriptblocks. Each scriptblock receives no args; it can
# read $Script:* paths declared at the top of this file.
# ---------------------------------------------------------------------------
$Script:StagePlugins = @{
    'InstallTailscale' = @{
        Diagnose = {
            $tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
            Write-Host "=== InstallTailscale diagnostic ===" -ForegroundColor Cyan

            if (-not (Test-Path $tsExe)) {
                Write-Host '  tailscale.exe NOT INSTALLED' -ForegroundColor Yellow
            } else {
                try {
                    $statusJson = & $tsExe status --json 2>$null
                    if ($statusJson) {
                        $st = $statusJson | ConvertFrom-Json
                        $diagHost = ''
                        $diagIPs  = ''
                        $diagLoggedIn = $false
                        if ($st.Self) {
                            $diagHost = $st.Self.HostName
                            $diagIPs  = ($st.Self.TailscaleIPs -join ',')
                            $diagLoggedIn = ($st.Self.UserID -ne 0)
                        }
                        [PSCustomObject]@{
                            BackendState = $st.BackendState
                            AuthURL      = $st.AuthURL
                            SelfHost     = $diagHost
                            SelfIPs      = $diagIPs
                            LoggedIn     = $diagLoggedIn
                            Version      = $st.Version
                        } | Format-List | Out-String | Write-Host
                    } else {
                        Write-Host '  tailscale status --json returned nothing.' -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            $svc = Get-Service Tailscale -ErrorAction SilentlyContinue
            if ($svc) {
                Write-Host "Tailscale service: Status=$($svc.Status), StartType=$($svc.StartType)"
            } else {
                Write-Host 'Tailscale service: NOT REGISTERED' -ForegroundColor Yellow
            }

            # Deployed Tailscale.ps1 marker check
            $deployedTs = Join-Path $Script:RepoDir 'core\Tailscale.ps1'
            if (Test-Path $deployedTs) {
                $markers = @(Select-String -Path $deployedTs -Pattern 'tsCapture|controlplane' -EA SilentlyContinue).Count
                $mtime   = (Get-Item $deployedTs).LastWriteTime
                Write-Host ""
                Write-Host "Deployed Tailscale.ps1 mtime: $mtime, markers: $markers"
                if ($markers -lt 5) {
                    Write-Host '  OLD code is deployed. Run -Action Repair -Stage InstallTailscale to refresh.' -ForegroundColor Yellow
                }
            }

            # Latest InstallTailscale log tail
            $log = Get-ChildItem -Path $Script:LogDir -Filter 'InstallTailscale_*.log' -EA SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($log) {
                Write-Host ""
                Write-Host "Latest log: $($log.FullName) ($($log.Length) bytes)"
                Get-Content $log.FullName -Tail 25
            }
        }

        Repair = {
            Write-Host '=== InstallTailscale repair ===' -ForegroundColor Cyan

            Write-Host '[1/5] Stopping WinDeploy-Resume task...'
            try {
                $task = Get-ScheduledTask -TaskName 'WinDeploy-Resume' -EA Stop
                if ($task.State -eq 'Running') {
                    Stop-ScheduledTask -TaskName 'WinDeploy-Resume'
                    Write-Host '      Task stopped.' -ForegroundColor Green
                } else {
                    Write-Host "      Task state: $($task.State) (already not running)." -ForegroundColor Green
                }
            } catch {
                Write-Host "      WinDeploy-Resume not found: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            Write-Host '[2/5] Killing orphaned Orchestrator/Tailscale processes...'
            $candidates = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
                          Where-Object { $_.CommandLine -match 'Orchestrator\.ps1|Tailscale\.ps1' }
            foreach ($p in $candidates) {
                try {
                    Stop-Process -Id $p.ProcessId -Force -EA Stop
                    Write-Host "      Killed PID $($p.ProcessId)" -ForegroundColor Green
                } catch { }
            }
            $tsProcs = Get-Process -Name 'tailscale' -EA SilentlyContinue |
                       Where-Object { $_.Path -notlike '*tailscale-ipn.exe' }
            foreach ($p in $tsProcs) {
                try {
                    Stop-Process -Id $p.Id -Force -EA Stop
                    Write-Host "      Killed tailscale.exe PID $($p.Id)" -ForegroundColor Green
                } catch { }
            }

            Write-Host '[3/5] Downloading latest Tailscale.ps1 from main...'
            $rawUrl = 'https://raw.githubusercontent.com/karolperkowski/win_dell/main/core/Tailscale.ps1'
            $dest   = Join-Path $Script:RepoDir 'core\Tailscale.ps1'
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
            } catch {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
            try {
                Invoke-WebRequest -Uri $rawUrl -OutFile $dest -UseBasicParsing -EA Stop
                Write-Host "      Downloaded $((Get-Item $dest).Length) bytes." -ForegroundColor Green
            } catch {
                Write-Host "      Download failed: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }

            Write-Host '[4/5] Verifying new code is in place...'
            $markers = @(Select-String -Path $dest -Pattern 'tsCapture|controlplane' -EA SilentlyContinue).Count
            if ($markers -lt 5) {
                Write-Host "      Expected ~13 markers, got $markers. Download may be stale." -ForegroundColor Red
                return $false
            }
            Write-Host "      Verified ($markers markers)." -ForegroundColor Green

            Write-Host '[5/5] Restarting WinDeploy-Resume...'
            try {
                Start-ScheduledTask -TaskName 'WinDeploy-Resume' -EA Stop
                Write-Host '      Task started.' -ForegroundColor Green
            } catch {
                Write-Host "      Failed to start: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
            return $true
        }
    }
}

function Invoke-StageAction {
    param([string]$ActionName, [string]$StageName)

    if (-not $StageName) {
        Write-Error "$ActionName requires -Stage. Supported: $($Script:StagePlugins.Keys -join ', ')"
        exit 2
    }
    if (-not $Script:StagePlugins.ContainsKey($StageName)) {
        Write-Error "No plugin for stage '$StageName'. Supported: $($Script:StagePlugins.Keys -join ', ')"
        exit 2
    }
    $plugin = $Script:StagePlugins[$StageName]
    if (-not $plugin.ContainsKey($ActionName)) {
        Write-Error "Plugin for '$StageName' does not implement '$ActionName'."
        exit 2
    }
    & $plugin[$ActionName]
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Action) {
    'Status'   { [void](Invoke-StatusAction) }
    'Diagnose' { Invoke-StageAction -ActionName 'Diagnose' -StageName $Stage }
    'Repair'   { Invoke-StageAction -ActionName 'Repair'   -StageName $Stage }
}
