#Requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy Monitor - Live deployment progress (CLI/TUI).

.DESCRIPTION
    Launched at logon by the WinDeploy-Monitor scheduled task.
    Polls state.json every 3 seconds. Shows stage status, metrics, live log tail.
    When InstallTailscale is the current stage, displays the auth URL.
    Auto-exits 60 seconds after DeployComplete = true.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

# ---------------------------------------------------------------------------
# Early logger
# ---------------------------------------------------------------------------
$Script:_rawLog   = 'C:\ProgramData\WinDeploy\Logs\early.log'
$Script:_crashLog = 'C:\ProgramData\WinDeploy\Logs\monitor_crash.log'

function Append-Log {
    param([string]$Path, [string]$Text)
    try {
        $dir = Split-Path $Path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
    } catch {}
}

function Write-Early {
    param([string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    try { Append-Log $Script:_rawLog "$line`r`n" } catch {}
}

$Script:_scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path $MyInvocation.MyCommand.Path -Parent
} else {
    'C:\ProgramData\WinDeploy\repo\core'
}

Write-Early "=== Monitor.ps1 started (PID $PID) ==="
Write-Early "Running as   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# Load shared constants
$Script:_cfgPath = Join-Path $Script:_scriptDir 'Config.psm1'
$Script:_wd = $null
if (Test-Path $Script:_cfgPath) {
    Import-Module $Script:_cfgPath -DisableNameChecking -Force
    if (Get-Command Get-WDConfig -ErrorAction SilentlyContinue) {
        $Script:_wd = Get-WDConfig
    }
}

$DEPLOY_ROOT  = if ($Script:_wd) { $Script:_wd.DeployRoot    } else { 'C:\ProgramData\WinDeploy' }
$STATE_FILE   = if ($Script:_wd) { $Script:_wd.StateFile     } else { "$DEPLOY_ROOT\state.json" }
$SESSION_LOG  = "$DEPLOY_ROOT\Logs\session.log"
$MONITOR_LOG  = "$DEPLOY_ROOT\Logs\task_monitor.log"
$TS_JSON      = if ($Script:_wd) { $Script:_wd.TailscaleJson } else { "$DEPLOY_ROOT\tailscale.json" }
$STAGE_ORDER  = if ($Script:_wd) { @($Script:_wd.StageOrder) } else { @('PowerSettings','Debloat','WinTweaks','InstallDellSupportAssist','InstallDellPowerManager','InstallTailscale','WindowsUpdate','Cleanup') }
$STAGE_LABELS = if ($Script:_wd) { $Script:_wd.StageLabels   } else { @{} }
$REFRESH_SEC  = 3
$CLOSE_DELAY  = 60

Append-Log $MONITOR_LOG ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] Monitor started. PID:$PID User:$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`r`n")

# Keep display and system awake
try {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' `
             -Name 'SleepGuard' -Namespace 'WinDeploy' -ErrorAction Stop
    $esFlags = [System.Convert]::ToUInt32('80000003', 16)
    [WinDeploy.SleepGuard]::SetThreadExecutionState($esFlags) | Out-Null
} catch {}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-StateProp {
    param($State, [string]$Name, $Default = $null)
    if ($null -eq $State) { return $Default }
    $val = $State.PSObject.Properties[$Name]
    if ($null -eq $val) { return $Default }
    $v = $val.Value
    if ($null -eq $v) { return $Default }
    return $v
}

function Read-StateFile {
    if (-not (Test-Path $STATE_FILE)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($STATE_FILE, [System.Text.Encoding]::UTF8)
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Read-TailscaleJson {
    if (-not (Test-Path $TS_JSON)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($TS_JSON, [System.Text.Encoding]::UTF8)
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Get-SessionLogTail {
    param([int]$Lines = 8)
    if (-not (Test-Path $SESSION_LOG)) { return @() }
    try {
        $fs = [System.IO.FileStream]::new($SESSION_LOG, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $all = $reader.ReadToEnd() -split "`n" | Where-Object { $_.Trim() }
        } finally { $fs.Dispose() }
        if ($all.Count -gt $Lines) { return $all[-$Lines..-1] }
        return $all
    } catch { return @() }
}

function Get-StageLabel ([string]$Name) {
    if ($STAGE_LABELS -and $STAGE_LABELS[$Name]) { return $STAGE_LABELS[$Name] }
    return $Name
}

# ---------------------------------------------------------------------------
# TUI Drawing — builds plain text, writes once per refresh via Clear-Host
# ---------------------------------------------------------------------------

function Build-Screen {
    $state = Read-StateFile
    $ts    = Read-TailscaleJson

    $completed  = @(Get-StateProp $state 'CompletedStages' @())
    $failed     = @(Get-StateProp $state 'FailedStages' @())
    $current    = Get-StateProp $state 'CurrentStage' ''
    $complete   = Get-StateProp $state 'DeployComplete' $false
    $reboots    = Get-StateProp $state 'RebootCount' 0
    $timestamps = Get-StateProp $state 'StageTimestamps' @{}
    $lastErr    = Get-StateProp $state 'LastError' ''
    $lastErrStg = Get-StateProp $state 'LastErrorStage' ''

    $nComplete = $completed.Count
    $nTotal    = $STAGE_ORDER.Count
    $pct = if ($nTotal -gt 0) { [Math]::Round(($nComplete / $nTotal) * 100) } else { 0 }

    # Elapsed
    $elapsed = '--:--:--'
    $bootAt  = Get-StateProp $state 'BootstrappedAt' ''
    if ($bootAt) {
        try {
            $span = (Get-Date) - [datetime]$bootAt
            $elapsed = '{0:d2}:{1:d2}:{2:d2}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
        } catch {}
    }

    # Progress bar (ASCII)
    $barWidth = 50
    $filled   = [Math]::Floor($barWidth * $pct / 100)
    $empty    = $barWidth - $filled
    $bar      = ('#' * $filled) + ('-' * $empty)

    $sb = [System.Text.StringBuilder]::new(2048)

    # Header
    [void]$sb.AppendLine('')
    if ($complete) {
        [void]$sb.AppendLine('  WINDEPLOY - Deployment complete')
    } else {
        [void]$sb.AppendLine('  WINDEPLOY - Deployment in progress')
    }
    [void]$sb.AppendLine("  $env:COMPUTERNAME")
    [void]$sb.AppendLine('')

    # Metrics
    [void]$sb.AppendLine("  Elapsed: $elapsed    Reboots: $reboots    Stage: $nComplete / $nTotal ($pct%)")
    [void]$sb.AppendLine('')

    # Progress bar
    [void]$sb.AppendLine("  [$bar]")
    [void]$sb.AppendLine('')

    # Stages
    [void]$sb.AppendLine('  STAGES')
    [void]$sb.AppendLine('  ' + ('-' * 52))

    foreach ($stageName in $STAGE_ORDER) {
        $label = (Get-StageLabel $stageName).PadRight(28)

        if ($stageName -in $completed) {
            $timeStr = ''
            if ($timestamps -and $timestamps.PSObject -and $timestamps.PSObject.Properties[$stageName]) {
                try { $timeStr = ([datetime]$timestamps.$stageName).ToString('HH:mm:ss') } catch {}
            }
            [void]$sb.AppendLine("  [+] $label $timeStr")
        } elseif ($stageName -in $failed) {
            [void]$sb.AppendLine("  [X] $label FAILED")
        } elseif ($stageName -eq $current -and -not $complete) {
            [void]$sb.AppendLine("  [>] $label Running...")
        } else {
            [void]$sb.AppendLine("  [ ] $label")
        }
    }

    [void]$sb.AppendLine('')

    # Tailscale auth URL
    $showTs = ($current -eq 'InstallTailscale') -or ($ts -and $ts.AuthUrl -and -not $ts.Registered)
    if ($showTs -and $ts -and $ts.AuthUrl) {
        [void]$sb.AppendLine('  TAILSCALE AUTH')
        [void]$sb.AppendLine('  ' + ('-' * 52))
        if ($ts.Registered) {
            [void]$sb.AppendLine("  Registered as: $($ts.MachineName)")
        } else {
            [void]$sb.AppendLine('  Open this URL in a browser:')
            [void]$sb.AppendLine("  $($ts.AuthUrl)")
            [void]$sb.AppendLine('  Waiting for scan...')
        }
        [void]$sb.AppendLine('')
    }

    # Error
    if ($lastErr) {
        [void]$sb.AppendLine('  LAST ERROR')
        [void]$sb.AppendLine('  ' + ('-' * 52))
        [void]$sb.AppendLine("  Stage: $lastErrStg")
        [void]$sb.AppendLine("  $lastErr")
        [void]$sb.AppendLine('')
    }

    # Recent activity
    [void]$sb.AppendLine('  RECENT ACTIVITY')
    [void]$sb.AppendLine('  ' + ('-' * 52))

    $logLines = Get-SessionLogTail -Lines 6
    foreach ($line in $logLines) {
        [void]$sb.AppendLine("  $($line.Trim())")
    }

    [void]$sb.AppendLine('')

    # Footer
    $now = Get-Date -Format 'HH:mm:ss'
    if ($complete) {
        [void]$sb.AppendLine("  Updated $now  |  Deployment complete  |  Closing in $Script:closeCountdown s")
    } else {
        [void]$sb.AppendLine("  Updated $now  |  Refreshing every ${REFRESH_SEC}s  |  Ctrl+C to hide")
    }

    return @{ Text = $sb.ToString(); Complete = $complete }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$Host.UI.RawUI.WindowTitle = 'WinDeploy Monitor'

Clear-Host

$Script:closeCountdown = $CLOSE_DELAY

try {
    try { [Console]::CursorVisible = $false } catch {}

    while ($true) {
        try {
            $screen = Build-Screen
            Clear-Host
            Write-Host $screen.Text
            $done = $screen.Complete
        } catch {
            Append-Log $Script:_crashLog ("[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] Draw error: $($_.Exception.Message)`r`n")
        }

        if ($done) {
            $Script:closeCountdown -= $REFRESH_SEC
            if ($Script:closeCountdown -le 0) {
                Write-Host "`n  Monitor closing. Deployment is complete."
                break
            }
        }

        Start-Sleep -Seconds $REFRESH_SEC
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
    # Reset sleep guard
    try { [WinDeploy.SleepGuard]::SetThreadExecutionState([System.Convert]::ToUInt32('80000000', 16)) | Out-Null } catch {}
}
